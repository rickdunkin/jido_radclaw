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

  alias JidoClaw.Memory.{Fact, Retrieval, Scope}

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
        sources =
          case source do
            :all -> [:user_save, :model_remember, :consolidator_promoted, :imported_legacy]
            other -> [other]
          end

        Enum.each(sources, &invalidate_at_label(scope, label, &1))
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

  # ---------------------------------------------------------------------------
  # Internal write path
  # ---------------------------------------------------------------------------

  defp do_remember(attrs, tool_context, opts) do
    with {:ok, scope} <- Scope.resolve(tool_context),
         create_attrs = build_create_attrs(attrs, scope, opts),
         {:ok, _fact} <- Fact.record(create_attrs) do
      :ok
    else
      {:error, %Ash.Error.Invalid{} = err} ->
        if duplicate_key?(err) do
          Logger.debug("[Memory] duplicate key (idempotent skip): #{inspect(err)}")
        else
          Logger.warning("[Memory] write failed: #{inspect(err)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("[Memory] write failed: #{inspect(reason)}")
        :ok

      :error ->
        Logger.warning("[Memory] scope unresolvable, dropping write")
        :ok
    end
  end

  defp build_create_attrs(attrs, scope, opts) do
    label = Map.get(attrs, :key) || Map.get(attrs, "key")
    content = Map.get(attrs, :content) || Map.get(attrs, "content")

    type =
      Map.get(attrs, :type) || Map.get(attrs, "type") || "fact"

    tags =
      case type do
        nil -> []
        binary when is_binary(binary) -> [binary]
        _ -> []
      end

    %{
      tenant_id: scope.tenant_id,
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
      written_by: Map.get(attrs, :written_by) || Map.get(attrs, "written_by")
    }
  end

  defp duplicate_key?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn err ->
      msg = inspect(err)

      String.contains?(msg, [
        "unique_active_label_per_scope_",
        "unique_active_promoted_content_per_scope_",
        "unique_import_hash"
      ])
    end)
  end

  defp duplicate_key?(_), do: false

  # ---------------------------------------------------------------------------
  # Internal forget / list helpers — case-by-case scope dispatch since
  # Ash.Query.filter/2 doesn't compose ORs across runtime values
  # (we'd need import Ash.Expr + multi-step reduce, more code for less
  # clarity).
  # ---------------------------------------------------------------------------

  defp invalidate_at_label(scope, label, source) do
    facts_at_label(scope, label, source)
    |> Enum.each(fn fact ->
      case Fact.invalidate_by_id(fact, %{reason: "user_forget_#{source}"}) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Logger.warning("[Memory.forget] invalidate failed: #{inspect(err)}")
      end
    end)
  end

  defp facts_at_label(%{scope_kind: :user} = scope, label, source) do
    Fact
    |> Ash.Query.filter(
      tenant_id == ^scope.tenant_id and scope_kind == :user and
        user_id == ^scope.user_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read!()
  end

  defp facts_at_label(%{scope_kind: :workspace} = scope, label, source) do
    Fact
    |> Ash.Query.filter(
      tenant_id == ^scope.tenant_id and scope_kind == :workspace and
        workspace_id == ^scope.workspace_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read!()
  end

  defp facts_at_label(%{scope_kind: :project} = scope, label, source) do
    Fact
    |> Ash.Query.filter(
      tenant_id == ^scope.tenant_id and scope_kind == :project and
        project_id == ^scope.project_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read!()
  end

  defp facts_at_label(%{scope_kind: :session} = scope, label, source) do
    Fact
    |> Ash.Query.filter(
      tenant_id == ^scope.tenant_id and scope_kind == :session and
        session_id == ^scope.session_id and label == ^label and is_nil(invalid_at) and
        source == ^source
    )
    |> Ash.read!()
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
    uuid |> String.slice(0, 8)
  end

  defp short_id(_), do: ""

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(nil), do: ""
  defp format_timestamp(_), do: ""
end
