defmodule JidoClaw.Memory do
  @moduledoc """
  Public API for the v0.6.3 Memory subsystem.

  Replaces the v0.5.x `JidoClaw.Memory` GenServer + jido_memory ETS
  store + `.jido/memory.json` JSON dump with thin Ash code-interface
  calls into `JidoClaw.Memory.Domain`. No supervised process; this
  module is callable from anywhere the Repo is up.

  ## Two write entry points

    * `remember_from_model/2` — agent called the `remember` tool.
      Trust score 0.4, source `:model_remember`.
    * `remember_from_user/2` — user pressed `/memory save`.
      Trust score 0.7, source `:user_save`.

  Both end up in `Memory.Fact`. Block-tier writes go through
  `JidoClaw.Memory.Block.write/1` directly (driven by the
  consolidator + the `/memory blocks edit` CLI flow).

  ## Read entry point

    * `recall/2` — wraps `JidoClaw.Memory.Retrieval.search/2`.
      Returns the legacy `%{key, content, type, created_at, updated_at}`
      shape so existing `tools/recall.ex` and `cli/presenters.ex`
      formatters keep working without changes.

  ## Forget

    * `forget/2` — wraps `Memory.Fact.invalidate_by_label`. The
      default `:source` is `:user_save`. Pass `:all` to invalidate
      every active row at the label regardless of source.

  ## Always-`:ok` write contract

  All write functions return `:ok` even on persistence failures,
  surfacing errors via Logger. The legacy GenServer's contract was
  always-`:ok`; tools/remember.ex and cli/commands.ex rely on this
  so a transient DB hiccup never tears down an in-progress session.
  """

  require Logger
  require Ash.Query

  # Ash CRUD + Postgrex faults the Block scope-chain read can hit; narrowing
  # keeps unexpected bugs surfacing instead of silently swallowed by `[]`.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Memory.{Block, Fact, Retrieval, Scope}

  @doc """
  Save a Fact attributable to the model. Returns `:ok` always.

  Resolves the scope from `tool_context` per
  `JidoClaw.Memory.Scope.resolve/1`. Drops the write with a Logger
  warning when the tenant is missing or the scope is unresolvable —
  intentionally non-fatal so a tool call doesn't crash mid-stream.
  """
  @spec remember_from_model(map(), map()) :: :ok
  def remember_from_model(attrs, tool_context) when is_map(attrs) and is_map(tool_context) do
    do_remember(attrs, tool_context, source: :model_remember, trust_score: 0.4)
  end

  @doc """
  Save a Fact attributable to the user. Returns `:ok` always.
  """
  @spec remember_from_user(map(), map()) :: :ok
  def remember_from_user(attrs, tool_context) when is_map(attrs) and is_map(tool_context) do
    do_remember(attrs, tool_context, source: :user_save, trust_score: 0.7)
  end

  @doc """
  Search Memory with the legacy entry shape.

  Returns `[%{key, content, type, created_at, updated_at}]` so the
  existing recall/CLI formatters work without changes.

  Required `opts`:

    * `:tool_context` — map with at least `:tenant_id`.

  Optional `opts`:

    * `:limit` — max results (default 10).
  """
  @spec recall(String.t(), keyword()) :: [map()]
  def recall(query, opts \\ []) when is_binary(query) do
    case Keyword.get(opts, :tool_context) do
      nil ->
        []

      tool_context when is_map(tool_context) ->
        opts
        |> Keyword.put(:query, query)
        |> Keyword.put(:tool_context, tool_context)
        |> Retrieval.search()
        |> Enum.map(&fact_to_legacy_entry/1)
    end
  end

  @doc """
  Invalidate Facts at a `(scope, label)`.

  `opts`:

    * `:tool_context` — required, supplies tenant + scope.
    * `:source`       — `:user_save` (default) | `:model_remember` |
                        `:all`. `:all` invalidates every active row
                        at that label regardless of source — used
                        by `/memory forget --source all`.
  """
  @spec forget(String.t(), keyword()) :: :ok
  def forget(label, opts \\ []) when is_binary(label) do
    tool_context = Keyword.get(opts, :tool_context)
    source = Keyword.get(opts, :source, :user_save)

    case Scope.resolve(tool_context || %{}) do
      {:ok, scope} ->
        actor = actor_for(tool_context || %{}, scope.tenant_id)

        sources =
          case source do
            :all -> [:user_save, :model_remember, :consolidator_promoted, :imported_legacy]
            other -> [other]
          end

        Enum.each(sources, &invalidate_at_label(scope, label, &1, actor))
        :ok

      _ ->
        Logger.warning(
          "[Memory.forget] scope unresolvable for label=#{inspect(label)} — skipping"
        )

        :ok
    end
  end

  @doc """
  Compatibility shim — list the most-recent active Facts at the
  resolved scope, projected to the legacy entry shape.

  Returns `[]` when `tool_context` is `nil` or scope-unresolvable.
  Used by the legacy prompt builder while v0.6.3a ships;
  v0.6.3b's `prompt.ex` rewrite replaces this with a Block-tier
  render.

  Implementation: `recall("")` delegates to `Retrieval.search/1` which
  short-circuits empty queries to a recency scan.
  """
  @spec list_recent(map() | nil, integer()) :: [map()]
  def list_recent(tool_context, limit \\ 20)
  def list_recent(nil, _limit), do: []

  def list_recent(tool_context, limit) when is_map(tool_context) do
    recall("", tool_context: tool_context, limit: limit)
  end

  @doc """
  Render the active Block-tier rows for a scope chain, deduped by
  label with the most-specific scope winning.

  Used by the frozen-snapshot prompt builder. Resolved scope records
  carry every populated ancestor FK; we walk
  `Memory.Scope.chain/1` (most-specific first) to build the
  scope-chain query and rank.

  Returns a list ordered most-general → most-specific so the prompt
  reader sees broad context first, then session-specific overrides.
  Errors and missing rows surface as `[]` so the prompt builder
  never crashes.
  """
  @spec list_blocks_for_scope_chain(Scope.scope_record()) :: [Block.t()]
  def list_blocks_for_scope_chain(scope) when is_map(scope) do
    chain = Scope.chain(scope)

    rank =
      chain
      |> Enum.with_index()
      |> Map.new(fn {{kind, fk}, i} -> {{kind, fk}, i} end)

    chain_maps = Enum.map(chain, fn {kind, fk} -> %{scope_kind: kind, fk_id: fk} end)

    case Block.for_scope_chain(chain_maps,
           tenant: scope.tenant_id,
           actor: Actor.system(scope.tenant_id)
         ) do
      {:ok, blocks} ->
        blocks
        |> Enum.group_by(& &1.label)
        |> Enum.map(fn {_label, group} ->
          Enum.min_by(group, fn b ->
            Map.get(rank, {b.scope_kind, scope_fk_for_block(b)}, 999)
          end)
        end)
        |> Enum.sort_by(
          fn b -> Map.get(rank, {b.scope_kind, scope_fk_for_block(b)}, 999) end,
          :desc
        )

      _ ->
        []
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      []
  catch
    :exit, _ -> []
  end

  defp scope_fk_for_block(%{scope_kind: :session, session_id: id}), do: id
  defp scope_fk_for_block(%{scope_kind: :project, project_id: id}), do: id
  defp scope_fk_for_block(%{scope_kind: :workspace, workspace_id: id}), do: id
  defp scope_fk_for_block(%{scope_kind: :user, user_id: id}), do: id

  @doc """
  Resolve the memory namespace for a `tool_context`-like map.

  Returns `%{namespace, blocks_count, scope}` — the prompt-visible
  namespace label (`"<scope_kind>:<primary_fk>"`), the count of
  label-deduped Block-tier rows in the scope chain, and the resolved
  scope record — or `nil` when the scope is unresolvable (e.g. missing
  tenant). Sources `JidoClaw.Inspection.Summary.memory`.

  Reuses `Scope.resolve/1` (loads ancestor FKs) and
  `list_blocks_for_scope_chain/1`, which reads as `Actor.system/1`
  internally — so `blocks_count` is scope-complete. Returns a bare
  map/`nil`, consistent with the nil-friendly Memory read API.
  """
  @spec namespace_info(map()) ::
          %{namespace: String.t(), blocks_count: non_neg_integer(), scope: Scope.scope_record()}
          | nil
  def namespace_info(tool_context) when is_map(tool_context) do
    case Scope.resolve(tool_context) do
      {:ok, scope} ->
        %{
          namespace: namespace_label(scope),
          blocks_count: length(list_blocks_for_scope_chain(scope)),
          scope: scope
        }

      {:error, _} ->
        nil
    end
  end

  def namespace_info(_), do: nil

  defp namespace_label(%{scope_kind: kind} = scope),
    do: "#{kind}:#{Scope.primary_fk(scope) || "none"}"

  # ---------------------------------------------------------------------------
  # Internal write path
  # ---------------------------------------------------------------------------

  defp do_remember(attrs, tool_context, opts, attempt \\ 1) do
    attrs = MapKeys.normalize_keys(attrs, :atom_existing)

    with {:ok, scope} <- Scope.resolve(tool_context),
         actor = actor_for(tool_context, scope.tenant_id),
         create_attrs = build_create_attrs(attrs, scope, opts),
         {:ok, _fact} <- record_fact(create_attrs, scope, actor) do
      :ok
    else
      {:error, %Ash.Error.Invalid{} = err} ->
        handle_invalid_write(err, attrs, tool_context, opts, attempt)

      {:error, reason} ->
        Logger.warning("[Memory] write failed: #{inspect(reason)}")
        :ok
    end
  end

  # Two writers racing the same (scope, label) both pass
  # InvalidatePriorActiveLabel's pre-check; the loser hits the partial
  # unique index at commit. One retry turns that into last-writer-wins
  # (the loser's retry invalidates the winner's fresh row) instead of
  # silently dropping the newer value. A second consecutive duplicate
  # is skipped idempotently, preserving the always-:ok contract.
  defp handle_invalid_write(err, attrs, tool_context, opts, attempt) do
    cond do
      duplicate_key?(err) and attempt == 1 ->
        Logger.debug("[Memory] duplicate key — retrying once (last-writer-wins)")
        do_remember(attrs, tool_context, opts, 2)

      duplicate_key?(err) ->
        Logger.debug("[Memory] duplicate key (idempotent skip): #{inspect(err)}")
        :ok

      true ->
        Logger.warning("[Memory] write failed: #{inspect(err)}")
        :ok
    end
  end

  # Seam for the retry-path tests: the SQL sandbox never commits, so a
  # real commit-time unique violation is unreproducible there. Tests
  # swap in a stateful double (see FactTest).
  defp record_fact(create_attrs, scope, actor) do
    recorder = Application.get_env(:jido_claw, :memory_fact_recorder, Fact)
    recorder.record(create_attrs, tenant: scope.tenant_id, actor: actor)
  end

  defp build_create_attrs(attrs, scope, opts) do
    label = Map.get(attrs, :key)
    content = Map.get(attrs, :content)
    type = Map.get(attrs, :type) || "fact"

    tags =
      case type do
        binary when is_binary(binary) -> [binary]
        _ -> []
      end

    %{
      scope_kind: scope.scope_kind,
      user_id: scope[:user_id],
      workspace_id: scope[:workspace_id],
      project_id: scope[:project_id],
      session_id: scope[:session_id],
      label: label,
      content: content,
      tags: tags,
      source: Keyword.fetch!(opts, :source),
      trust_score: Keyword.fetch!(opts, :trust_score),
      written_by: Map.get(attrs, :written_by)
    }
  end

  # Index-name fragments — ash_postgres reports the *index* name, not
  # the identity name. The four active-label identities use default
  # names (memory_facts_unique_active_label_per_scope_<scope>_index);
  # the promoted identities map to shortened mf_promoted_*_idx via
  # identity_index_names on the resource. mf_promoted_/unique_import_hash
  # are defensive: those identities are unreachable via remember_*.
  @duplicate_index_fragments [
    "unique_active_label_per_scope_",
    "mf_promoted_",
    "unique_import_hash"
  ]

  defp duplicate_key?(err), do: AshErrors.unique_violation?(err, @duplicate_index_fragments)

  # ---------------------------------------------------------------------------
  # Internal forget / list helpers — case-by-case scope dispatch since
  # Ash.Query.filter/2 doesn't compose ORs across runtime values
  # (we'd need import Ash.Expr + multi-step reduce, more code for less
  # clarity).
  # ---------------------------------------------------------------------------

  defp invalidate_at_label(scope, label, source, actor) do
    Enum.each(facts_at_label(scope, label, source, actor), fn fact ->
      case Fact.invalidate_by_id(fact, %{reason: "user_forget_#{source}"},
             tenant: scope.tenant_id,
             actor: actor
           ) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Logger.warning("[Memory.forget] invalidate failed: #{inspect(err)}")
      end
    end)
  end

  defp facts_at_label(%{scope_kind: :user} = scope, label, source, actor) do
    Fact.query_to_list(%{}, actor: actor, tenant: scope.tenant_id)
    |> Ash.Query.filter(
      scope_kind == :user and
        user_id == ^scope.user_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read(actor: actor, tenant: scope.tenant_id)
    |> read_or_empty()
  end

  defp facts_at_label(%{scope_kind: :workspace} = scope, label, source, actor) do
    Fact.query_to_list(%{}, actor: actor, tenant: scope.tenant_id)
    |> Ash.Query.filter(
      scope_kind == :workspace and
        workspace_id == ^scope.workspace_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read(actor: actor, tenant: scope.tenant_id)
    |> read_or_empty()
  end

  defp facts_at_label(%{scope_kind: :project} = scope, label, source, actor) do
    Fact.query_to_list(%{}, actor: actor, tenant: scope.tenant_id)
    |> Ash.Query.filter(
      scope_kind == :project and
        project_id == ^scope.project_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read(actor: actor, tenant: scope.tenant_id)
    |> read_or_empty()
  end

  defp facts_at_label(%{scope_kind: :session} = scope, label, source, actor) do
    Fact.query_to_list(%{}, actor: actor, tenant: scope.tenant_id)
    |> Ash.Query.filter(
      scope_kind == :session and
        session_id == ^scope.session_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read(actor: actor, tenant: scope.tenant_id)
    |> read_or_empty()
  end

  defp read_or_empty({:ok, facts}), do: facts

  defp read_or_empty({:error, err}) do
    Logger.warning("[Memory.forget] facts_at_label read failed: #{inspect(err)}")
    []
  end

  defp actor_for(tool_context, tenant_id) when is_map(tool_context) do
    Map.get(tool_context, :actor) || Actor.system(tenant_id)
  end

  # ---------------------------------------------------------------------------
  # Legacy entry-shape projection
  # ---------------------------------------------------------------------------

  defp fact_to_legacy_entry(%Fact{} = fact) do
    type =
      case fact.tags do
        [t | _] when is_binary(t) -> t
        _ -> "fact"
      end

    %{
      key: fact.label || short_id(fact.id),
      content: fact.content,
      type: type,
      created_at: format_timestamp(fact.inserted_at),
      updated_at: format_timestamp(fact.updated_at || fact.inserted_at)
    }
  end

  defp fact_to_legacy_entry(%{} = wrapped) when is_map_key(wrapped, :fact) do
    fact_to_legacy_entry(wrapped.fact)
  end

  defp fact_to_legacy_entry(other), do: other

  defp short_id(uuid) when is_binary(uuid) do
    String.slice(uuid, 0, 8)
  end

  defp short_id(_), do: ""

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(nil), do: ""
  defp format_timestamp(_), do: ""
end
