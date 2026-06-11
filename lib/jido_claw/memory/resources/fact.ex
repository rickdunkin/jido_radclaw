defmodule JidoClaw.Memory.Fact do
  @moduledoc """
  Searchable memory tier — bitemporal, scope-keyed, hybrid-retrieved.

  Every `remember` / `memory.save` / `consolidator promote` /
  `migrate_from_legacy` write lands here. Facts are NOT rendered into
  the prompt; the model reaches them through the `recall` tool, which
  delegates to `JidoClaw.Memory.Retrieval.search/2` →
  `JidoClaw.Memory.HybridSearchSql.run/1`.

  ## Bitemporal model

  Two pairs:

    * `valid_at` / `invalid_at` — world time. `invalid_at IS NULL` means
      the row is currently true.
    * `inserted_at` / `expired_at` — system time. `expired_at IS NULL`
      means the row is the live representation in the database.

  Both `valid_at` and `inserted_at` are writable so `:import_legacy`
  can preserve the source row's original timestamps. The `:record`
  action defaults both to `now()`.

  ## Generated columns

  * `content_hash` — `digest(content, 'sha256')` via `pgcrypto`. Used
    by `unique_active_promoted_content_per_scope_*` so the consolidator
    can't double-promote the same content under one scope.
  * `search_vector` — weighted tsvector built from
    `label || content || tags` for FTS pool of hybrid retrieval.
  * `lexical_text` — lower-cased concat of the same fields, indexed
    via `gin_trgm_ops` for the lexical pool (substring + similarity).

  All three are emitted as `GENERATED ALWAYS AS (...) STORED` columns
  in the migration; Ash declares them `generated?: true, writable?: false`
  so the resource layer never tries to write them.

  ## Source precedence

  Source-rank for retrieval (most authoritative first, plan §3.13
  lines 1041–1042):

    1. `:user_save` — user pressed `/memory save`
    2. `:consolidator_promoted` — frontier model promoted from a cluster
    3. `:imported_legacy` — migrated from `.jido/memory.json`
    4. `:model_remember` — agent called the `remember` tool

  `:imported_legacy` outranks `:model_remember` so curated v0.5 memory
  isn't immediately shadowed by a fresh model self-write at the same
  `(scope, label)`.

  Trust-score defaults at `:record` time: 0.4 for `:model_remember`,
  0.7 for `:user_save` (set by `JidoClaw.Memory.remember_*` callers,
  not the action). `:consolidator_promoted` typically lifts trust to
  0.85+; `:promote` accepts the new score.

  ## Bitemporal invalidate-and-replace

  `:record` runs `invalidate_prior_active_label` as a `before_action`
  hook: when a Fact already exists at `(scope, label)` with
  `invalid_at IS NULL`, that row is updated to `invalid_at = now()` +
  `expired_at = now()` *inside the same transaction*. The new row
  carries the new `valid_at = now()` (or supplied) and
  `invalid_at = NULL`. The 4 partial unique identities make this a
  hard invariant: two active rows at the same `(tenant, scope, label)`
  is a write-time conflict, not just a query convention.
  """

  use JidoClaw.Resource, domain: JidoClaw.Memory.Domain, primary_read_warning?: false

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias JidoClaw.Memory.Resources.ScopeFilter
  alias JidoClaw.Memory.ScopeFk
  alias JidoClaw.Repo
  alias JidoClaw.Security.CrossTenantFk
  alias JidoClaw.Security.Redaction.Memory, as: MemoryRedaction

  @scope_kinds [:user, :workspace, :project, :session]
  @sources [:model_remember, :user_save, :consolidator_promoted, :imported_legacy]
  @embedding_statuses [:pending, :processing, :ready, :failed, :disabled]

  postgres do
    table("memory_facts")
    repo(JidoClaw.Repo)

    # Index names must fit Postgres's 63-char limit. AshPostgres composes
    # `<table>_<identity>_index` so the long promoted-content identities
    # need an explicit shortening map.
    identity_index_names(
      unique_active_promoted_content_per_scope_user: "mf_promoted_user_idx",
      unique_active_promoted_content_per_scope_workspace: "mf_promoted_ws_idx",
      unique_active_promoted_content_per_scope_project: "mf_promoted_proj_idx",
      unique_active_promoted_content_per_scope_session: "mf_promoted_sess_idx"
    )

    identity_wheres_to_sql(
      unique_active_label_per_scope_user:
        "label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL",
      unique_active_label_per_scope_workspace:
        "label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL",
      unique_active_label_per_scope_project:
        "label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL",
      unique_active_label_per_scope_session:
        "label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL",
      unique_active_promoted_content_per_scope_user:
        "source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL",
      unique_active_promoted_content_per_scope_workspace:
        "source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL",
      unique_active_promoted_content_per_scope_project:
        "source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL",
      unique_active_promoted_content_per_scope_session:
        "source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL",
      unique_import_hash: "import_hash IS NOT NULL"
    )

    custom_indexes do
      index([:tenant_id, :scope_kind, :valid_at])
      index([:tenant_id, :source, :inserted_at])
      index([:search_vector], using: "gin", all_tenants?: true)
      index([:tenant_id, :embedding_status])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:record, action: :record)
    define(:import_legacy, action: :import_legacy)
    define(:promote, action: :promote)
    define(:invalidate_by_id, action: :invalidate_by_id)
    define(:invalidate_by_label, action: :invalidate_by_label)
    define(:for_consolidator, action: :for_consolidator)
    define(:transition_embedding_status, action: :transition_embedding_status)
    define(:list, action: :read)
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)

      accept([
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :label,
        :content,
        :tags,
        :source,
        :trust_score,
        :written_by,
        :valid_at,
        :embedding,
        :embedding_status
      ])

      # Suppresses `HintBackfillWorker` registration so callers nested
      # inside an outer `Ash.transact` (e.g. the consolidator's publish
      # path) can dispatch hints themselves after the outer transaction
      # commits. See `JidoClaw.Memory.Fact.hint_backfill/1`.
      argument(:skip_backfill_hint?, :boolean, default: false)

      change(JidoClaw.Memory.Changes.ValidateScopeFk)
      change({__MODULE__.Changes.ValidateCrossTenant, []})
      change({__MODULE__.Changes.RedactContent, []})
      change({__MODULE__.Changes.ResolveInitialEmbeddingStatus, []})
      change({__MODULE__.Changes.InvalidatePriorActiveLabel, []})
      change({__MODULE__.Changes.HintBackfillWorker, []})

      change(
        {JidoClaw.Audit.Producers.MemoryWrite,
         [event_kind: :memory_write, target_kind: :memory_fact]}
      )
    end

    create :import_legacy do
      accept([
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :label,
        :content,
        :tags,
        :trust_score,
        :written_by,
        :embedding,
        :embedding_status,
        :import_hash
      ])

      argument(:inserted_at, :utc_datetime_usec, allow_nil?: true)
      argument(:valid_at, :utc_datetime_usec, allow_nil?: true)

      upsert?(true)
      upsert_identity(:unique_import_hash)
      upsert_fields([])

      change({__MODULE__.Changes.AcceptLegacyTimestamps, []})
      change({__MODULE__.Changes.FixSourceImportedLegacy, []})
      change(JidoClaw.Memory.Changes.ValidateScopeFk)
      change({__MODULE__.Changes.ValidateCrossTenant, []})
      change({__MODULE__.Changes.RedactContent, []})
      change({__MODULE__.Changes.ResolveInitialEmbeddingStatus, []})
    end

    update :promote do
      accept([:trust_score])
      argument(:promoted_at, :utc_datetime_usec, allow_nil?: true)
      require_atomic?(false)

      change({__MODULE__.Changes.MarkPromoted, []})

      change(
        {JidoClaw.Audit.Producers.MemoryWrite,
         [event_kind: :memory_write, target_kind: :memory_fact]}
      )
    end

    update :invalidate_by_id do
      accept([])
      argument(:reason, :string, allow_nil?: true)
      require_atomic?(false)

      change(JidoClaw.Memory.Changes.MarkInvalidated)

      change(
        {JidoClaw.Audit.Producers.MemoryWrite,
         [event_kind: :memory_write, target_kind: :memory_fact]}
      )
    end

    update :invalidate_by_label do
      accept([])
      argument(:source, :atom, allow_nil?: false)
      argument(:reason, :string, allow_nil?: true)
      require_atomic?(false)

      validate({__MODULE__.Validations.SourceForInvalidateByLabel, []})
      change(JidoClaw.Memory.Changes.MarkInvalidated)

      change(
        {JidoClaw.Audit.Producers.MemoryWrite,
         [event_kind: :memory_write, target_kind: :memory_fact]}
      )
    end

    read :for_consolidator do
      argument(:scope_kind, :atom, allow_nil?: false, constraints: [one_of: @scope_kinds])
      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:since_inserted_at, :utc_datetime_usec, allow_nil?: true)
      argument(:since_id, :uuid, allow_nil?: true)
      argument(:limit, :integer, allow_nil?: true, default: 500)

      argument(:sources, {:array, :atom},
        allow_nil?: false,
        default: [:model_remember, :user_save, :imported_legacy],
        constraints: [items: [one_of: @sources]]
      )

      prepare({__MODULE__.Preparations.ForConsolidator, []})
    end

    update :transition_embedding_status do
      accept([
        :embedding,
        :embedding_status,
        :embedding_attempt_count,
        :embedding_next_attempt_at,
        :embedding_last_error
      ])

      require_atomic?(false)
    end

    read :by_id do
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_id_global do
      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :scope_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @scope_kinds)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :workspace_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :label, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :content, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :tags, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :source, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @sources)
    end

    attribute :trust_score, :float do
      allow_nil?(false)
      public?(true)
      default(0.4)
    end

    attribute :written_by, :string do
      allow_nil?(true)
      public?(true)
    end

    # Bitemporal — world time
    attribute :valid_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    attribute :invalid_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    # Bitemporal — system time
    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    attribute :expired_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    # Embeddings state machine — mirrors Solutions.Solution.
    attribute :embedding, :vector do
      allow_nil?(true)
      public?(true)
      constraints(dimensions: 1024)
    end

    attribute :embedding_status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: @embedding_statuses)
    end

    attribute :embedding_attempt_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :embedding_next_attempt_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :embedding_last_error, :string do
      allow_nil?(true)
      public?(true)
    end

    # Idempotent legacy import key — partial unique.
    attribute :import_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    # Generated columns — populated by Postgres `GENERATED ALWAYS AS (...) STORED`.
    attribute :content_hash, :binary do
      allow_nil?(true)
      public?(false)
      writable?(false)
      generated?(true)
    end

    attribute :search_vector, AshPostgres.Tsvector do
      allow_nil?(true)
      public?(false)
      writable?(false)
      generated?(true)
    end

    attribute :lexical_text, :string do
      allow_nil?(true)
      public?(false)
      writable?(false)
      generated?(true)
    end

    attribute :promoted_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :updated_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      default(&DateTime.utc_now/0)
      writable?(true)
    end
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end

  identities do
    identity(
      :unique_active_label_per_scope_user,
      [:tenant_id, :scope_kind, :user_id, :label],
      where: expr(not is_nil(label) and is_nil(invalid_at) and not is_nil(user_id))
    )

    identity(
      :unique_active_label_per_scope_workspace,
      [:tenant_id, :scope_kind, :workspace_id, :label],
      where: expr(not is_nil(label) and is_nil(invalid_at) and not is_nil(workspace_id))
    )

    identity(
      :unique_active_label_per_scope_project,
      [:tenant_id, :scope_kind, :project_id, :label],
      where: expr(not is_nil(label) and is_nil(invalid_at) and not is_nil(project_id))
    )

    identity(
      :unique_active_label_per_scope_session,
      [:tenant_id, :scope_kind, :session_id, :label],
      where: expr(not is_nil(label) and is_nil(invalid_at) and not is_nil(session_id))
    )

    identity(
      :unique_active_promoted_content_per_scope_user,
      [:tenant_id, :scope_kind, :user_id, :content_hash],
      where:
        expr(
          source == :consolidator_promoted and is_nil(invalid_at) and
            not is_nil(content_hash) and not is_nil(user_id)
        )
    )

    identity(
      :unique_active_promoted_content_per_scope_workspace,
      [:tenant_id, :scope_kind, :workspace_id, :content_hash],
      where:
        expr(
          source == :consolidator_promoted and is_nil(invalid_at) and
            not is_nil(content_hash) and not is_nil(workspace_id)
        )
    )

    identity(
      :unique_active_promoted_content_per_scope_project,
      [:tenant_id, :scope_kind, :project_id, :content_hash],
      where:
        expr(
          source == :consolidator_promoted and is_nil(invalid_at) and
            not is_nil(content_hash) and not is_nil(project_id)
        )
    )

    identity(
      :unique_active_promoted_content_per_scope_session,
      [:tenant_id, :scope_kind, :session_id, :content_hash],
      where:
        expr(
          source == :consolidator_promoted and is_nil(invalid_at) and
            not is_nil(content_hash) and not is_nil(session_id)
        )
    )

    identity(:unique_import_hash, [:import_hash], where: expr(not is_nil(import_hash)))
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.AcceptLegacyTimestamps do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      changeset
      |> apply_argument(:inserted_at, :inserted_at)
      |> apply_argument(:valid_at, :valid_at)
    end

    defp apply_argument(cs, arg, attr) do
      case Changeset.get_argument(cs, arg) do
        nil -> cs
        value -> Changeset.force_change_attribute(cs, attr, value)
      end
    end
  end

  defmodule Changes.FixSourceImportedLegacy do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.force_change_attribute(changeset, :source, :imported_legacy)
    end
  end

  defmodule Changes.ValidateCrossTenant do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    # ex_dna:disable-for-next-line
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        CrossTenantFk.validate(cs, [
          {:workspace_id, JidoClaw.Workspaces.Workspace, JidoClaw.Workspaces},
          {:session_id, JidoClaw.Conversations.Session, JidoClaw.Conversations},
          # User and Project lack tenant_id columns — see plan §0.5.2.
          {:user_id, :no_tenant_column, nil},
          {:project_id, :no_tenant_column, nil}
        ])
      end)
    end
  end

  defmodule Changes.RedactContent do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        case Changeset.get_attribute(cs, :content) do
          nil ->
            cs

          content when is_binary(content) ->
            redacted = MemoryRedaction.redact_fact!(content)
            Changeset.force_change_attribute(cs, :content, redacted)

          _ ->
            cs
        end
      end)
    end
  end

  defmodule Changes.ResolveInitialEmbeddingStatus do
    @moduledoc """
    Mirror of Solutions.Solution.Changes.ResolveInitialEmbeddingStatus —
    if the caller already pinned a terminal status (e.g. import_legacy
    carrying :ready or :disabled), respect it. Otherwise resolve from
    the workspace's embedding_policy. Facts on `:user` or `:project`
    scope (no workspace ancestor) default to `:disabled`.
    """
    use Ash.Resource.Change

    alias JidoClaw.Authorization.Actor
    alias JidoClaw.Workspaces.Workspace

    @impl Ash.Resource.Change
    # ex_dna:disable-for-next-line
    def change(changeset, _opts, context) do
      actor = Map.get(context, :actor)

      Changeset.before_action(changeset, fn cs ->
        case Changeset.get_attribute(cs, :embedding_status) do
          status when status in [:ready, :failed, :disabled, :processing] ->
            cs

          _ ->
            workspace_id = Changeset.get_attribute(cs, :workspace_id)
            resolve_status_from_policy(cs, workspace_id, actor)
        end
      end)
    end

    defp resolve_status_from_policy(cs, nil, _actor) do
      Changeset.force_change_attribute(cs, :embedding_status, :disabled)
    end

    defp resolve_status_from_policy(cs, workspace_id, actor) do
      tenant_id = cs.tenant || Changeset.get_attribute(cs, :tenant_id)

      # Internal callers may reach here without an actor.
      # Workspace.by_id is policy-protected, so fall back to a
      # tenant-bound system actor that satisfies the
      # `tenant_id == ^actor(:tenant_id)` policy without granting
      # cross-tenant access.
      effective_actor =
        actor ||
          (tenant_id && Actor.system(tenant_id))

      result =
        if tenant_id do
          opts = [tenant: tenant_id]

          opts =
            if effective_actor, do: Keyword.put(opts, :actor, effective_actor), else: opts

          Workspace.by_id(workspace_id, opts)
        else
          Workspace.by_id_global(workspace_id)
        end

      case result do
        {:ok, %{embedding_policy: :disabled}} ->
          Changeset.force_change_attribute(cs, :embedding_status, :disabled)

        {:ok, %{embedding_policy: :default}} ->
          Changeset.force_change_attribute(cs, :embedding_status, :pending)

        _ ->
          cs
      end
    end
  end

  defmodule Changes.InvalidatePriorActiveLabel do
    @moduledoc """
    When a Fact already exists at `(tenant, scope, label)` with
    `invalid_at IS NULL`, mark it `invalid_at = now()` + `expired_at =
    now()` *inside the same transaction* so the new row's partial
    unique identity has room to land.

    The concurrent-writer race is bounded by the partial unique
    identity itself: if two writers both pass this pre-check and try
    to insert, the loser is rejected by Postgres at commit time.
    `JidoClaw.Memory.do_remember/4` classifies that violation via
    `JidoClaw.Core.AshErrors.unique_violation?/2` and retries once —
    the retry invalidates the winner's fresh row, so the outcome is
    last-writer-wins rather than a silently dropped value. A second
    consecutive duplicate is logged and skipped idempotently.
    """
    use Ash.Resource.Change

    alias JidoClaw.Memory.Fact

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        tenant_id = cs.tenant || Changeset.get_attribute(cs, :tenant_id)

        with label when is_binary(label) <- Changeset.get_attribute(cs, :label),
             scope_kind = Changeset.get_attribute(cs, :scope_kind),
             {:ok, fk_id} <- Fact.scope_fk_for(cs, scope_kind),
             true <- is_binary(tenant_id) do
          Fact.invalidate_prior_active_label(
            tenant_id,
            scope_kind,
            fk_id,
            label
          )
        end

        cs
      end)
    end
  end

  defmodule Changes.HintBackfillWorker do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Memory.Fact

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      if Changeset.get_argument(changeset, :skip_backfill_hint?) do
        changeset
      else
        Changeset.after_transaction(changeset, fn _cs, result ->
          case result do
            {:ok, %{embedding_status: :pending, id: id}} ->
              Fact.hint_backfill(id)

            _ ->
              :ok
          end

          result
        end)
      end
    end
  end

  defmodule Changes.MarkPromoted do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        promoted_at =
          Changeset.get_argument(cs, :promoted_at) || DateTime.utc_now()

        cs
        |> Changeset.force_change_attribute(:source, :consolidator_promoted)
        |> Changeset.force_change_attribute(:promoted_at, promoted_at)
      end)
    end
  end

  defmodule Validations.SourceForInvalidateByLabel do
    @moduledoc false
    use Ash.Resource.Validation

    @impl Ash.Resource.Validation
    def validate(changeset, _opts, _context) do
      case Changeset.get_argument(changeset, :source) do
        :model_remember ->
          :ok

        :user_save ->
          :ok

        :all ->
          :ok

        other ->
          {:error,
           field: :source,
           message: "invalid_source_for_invalidate_by_label",
           vars: [supplied: other]}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inline preparations
  # ---------------------------------------------------------------------------

  defmodule Preparations.ForConsolidator do
    @moduledoc """
    Watermarked, scope-filtered read for the consolidator.

    Returns rows where `(inserted_at, id) > (since_inserted_at,
    since_id)` so the consolidator can resume from its last published
    watermark deterministically. When `since_inserted_at` is nil, all
    rows for the scope are returned.

    Filters by the `:sources` argument (default
    `[:model_remember, :user_save, :imported_legacy]`) so the
    consolidator only sees rows it's allowed to promote.
    `:consolidator_promoted` is excluded by default — those are
    already canonicalised.
    """
    use Ash.Resource.Preparation
    require Ash.Query

    alias JidoClaw.Memory.Fact

    @impl Ash.Resource.Preparation
    def prepare(query, _opts, _context) do
      kind = Query.get_argument(query, :scope_kind)
      fk = Query.get_argument(query, :scope_fk_id)
      since_at = Query.get_argument(query, :since_inserted_at)
      since_id = Query.get_argument(query, :since_id)
      limit = Query.get_argument(query, :limit)
      sources = Query.get_argument(query, :sources)

      query
      |> Fact.apply_scope_filter(kind, fk)
      |> Fact.apply_since_filter(since_at, since_id)
      |> Fact.apply_sources_filter(sources)
      |> Query.sort(inserted_at: :asc, id: :asc)
      |> Query.limit(limit)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the foreign-key id for `scope_kind` from `changeset`.

  Returns `{:ok, id}` when the attribute is set, `:missing` when it is `nil`,
  or `:missing` for unknown `scope_kind`. Public because Ash `change`
  modules in the same file reference it before the resource compiles.
  """
  @spec scope_fk_for(Ash.Changeset.t(), atom()) :: {:ok, term()} | :missing
  def scope_fk_for(changeset, :user) do
    nullable_attr(changeset, :user_id)
  end

  def scope_fk_for(changeset, :workspace) do
    nullable_attr(changeset, :workspace_id)
  end

  def scope_fk_for(changeset, :project) do
    nullable_attr(changeset, :project_id)
  end

  def scope_fk_for(changeset, :session) do
    nullable_attr(changeset, :session_id)
  end

  def scope_fk_for(_, _), do: :missing

  defp nullable_attr(changeset, attr) do
    case Changeset.get_attribute(changeset, attr) do
      nil -> :missing
      id -> {:ok, id}
    end
  end

  @doc """
  Mark prior `(tenant, scope, label)` active rows invalid + expired so
  the new row's partial unique identity has room to land. Runs as raw
  SQL inside the action's transaction so the read-then-write race is
  bounded by Postgres row locks.
  """
  @spec invalidate_prior_active_label(String.t(), atom(), String.t(), String.t()) :: :ok
  def invalidate_prior_active_label(tenant_id, scope_kind, fk_id, label) do
    {fk_column, fk_value} = scope_column_and_value(scope_kind, fk_id)

    sql = """
    UPDATE memory_facts
       SET invalid_at = now(),
           expired_at = now()
     WHERE tenant_id = $1
       AND scope_kind = $2
       AND #{fk_column} = $3
       AND label = $4
       AND invalid_at IS NULL
    """

    Repo.query!(sql, [tenant_id, Atom.to_string(scope_kind), fk_value, label])
    :ok
  end

  defp scope_column_and_value(:user, fk), do: {"user_id", ScopeFk.uuid_dump(fk)}
  defp scope_column_and_value(:workspace, fk), do: {"workspace_id", ScopeFk.uuid_dump(fk)}
  defp scope_column_and_value(:project, fk), do: {"project_id", ScopeFk.uuid_dump(fk)}
  defp scope_column_and_value(:session, fk), do: {"session_id", ScopeFk.uuid_dump(fk)}

  @doc """
  Narrow `query` to rows whose `scope_kind` and FK match `kind`/`fk`.

  Delegates to `JidoClaw.Memory.Resources.ScopeFilter.apply/3`. Public
  because read-action preparation blocks defined in this file invoke
  it before the resource is fully compiled.
  """
  defdelegate apply_scope_filter(query, kind, fk), to: ScopeFilter, as: :apply

  @doc """
  Narrow `query` to rows newer than `since_at`, optionally tie-breaking on
  `since_id` for stable cursor pagination. A `nil` `since_at` skips the
  filter.
  """
  @spec apply_since_filter(Ash.Query.t(), DateTime.t() | nil, String.t() | nil) :: Ash.Query.t()
  def apply_since_filter(query, nil, _), do: query

  def apply_since_filter(query, since_at, nil) do
    Query.filter(query, inserted_at > ^since_at)
  end

  def apply_since_filter(query, since_at, since_id) do
    Query.filter(
      query,
      inserted_at > ^since_at or (inserted_at == ^since_at and id > ^since_id)
    )
  end

  @doc """
  Narrow `query` to facts whose `source` is in `sources`. `nil` and `[]`
  skip the filter.
  """
  @spec apply_sources_filter(Ash.Query.t(), [atom()] | nil) :: Ash.Query.t()
  def apply_sources_filter(query, nil), do: query
  def apply_sources_filter(query, []), do: query

  def apply_sources_filter(query, sources) when is_list(sources) do
    Query.filter(query, source in ^sources)
  end

  @doc """
  Notify `JidoClaw.Embeddings.BackfillWorker` that the fact row at `id`
  is ready for embedding. Best-effort send — drops silently if the
  worker is not running. Used both by the `:record` action's
  `after_transaction` hook and by callers that suppressed that hook
  via `skip_backfill_hint?: true` and need to dispatch themselves
  after their own outer transaction commits.
  """
  @spec hint_backfill(String.t()) :: :ok
  def hint_backfill(id) when is_binary(id) do
    worker = JidoClaw.Embeddings.BackfillWorker
    if Process.whereis(worker), do: send(worker, {:hint_pending_memory_fact, id})
    :ok
    # Best-effort worker hint — never break the caller's write path.
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  end
end
