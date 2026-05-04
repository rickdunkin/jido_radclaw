defmodule JidoClaw.Solutions.Solution do
  @moduledoc """
  Tenant- and workspace-scoped solution row.

  Replaces the legacy `%JidoClaw.Solutions.Solution{}` struct + ETS
  +JSONL `Solutions.Store` GenServer. Persisted to Postgres with:

    * full-text `tsvector` (Postgres FTS, GIN-indexed)
    * `embedding` (pgvector, 1024-d, partial HNSW per `embedding_model`)
    * `lexical_text` for trigram similarity (GIN-indexed via
      `gin_trgm_ops`)

  ## Soft delete enforcement

  Soft delete is enforced **per action** via
  `prepare(build(filter: [is_nil(deleted_at)]))` rather than a
  resource-level `base_filter`. Reason: `:with_deleted` reads need to
  see deleted rows, and a `base_filter` would force them to bypass via
  `unrestrict/1`, which adds friction. Per-action filter is explicit
  and testable. Hybrid retrieval is implemented by
  `JidoClaw.Solutions.HybridSearchSql.run/1` (called directly by the
  Matcher), and its CTE SQL repeats `AND deleted_at IS NULL` in every
  pool — same predicate, hand-coded.

  ## Cross-tenant FK invariant

  `:store` and `:import_legacy` run a `before_action` hook that fetches
  the parent Workspace inside the create transaction and refuses to
  insert when:

    * `tenant_id != workspace.tenant_id`, OR
    * `session_id` is set AND `session.workspace_id != workspace_id`

  The double check matters: same-tenant rows attached to a
  wrong-workspace session would otherwise pass the tenant-only
  validation and silently misattribute. `created_by_user_id` is
  intentionally NOT validated against an Accounts.User row — Users are
  untenanted by design.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Solutions.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  alias JidoClaw.Security.Redaction.Transcript
  alias JidoClaw.Workspaces.Workspace, as: WorkspaceResource
  alias JidoClaw.Conversations.Session, as: SessionResource

  postgres do
    table("solutions")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :problem_signature])
      index([:tenant_id, :workspace_id])
      index([:tenant_id, :language, :framework])
      index([:tenant_id, :agent_id])
      index([:tenant_id, :sharing])
      index([:tenant_id, :trust_score])
      index([:tenant_id, :embedding_status])
      index([:search_vector], using: "gin")
    end
  end

  code_interface do
    define(:store, action: :store)
    define(:import_legacy, action: :import_legacy)

    define(:by_signature,
      action: :by_signature,
      args: [
        :signature,
        :workspace_id,
        :tenant_id,
        :local_visibility,
        :cross_workspace_visibility
      ]
    )

    define(:stats, action: :stats, args: [:tenant_id, :workspace_id])
    define(:update_trust, action: :update_trust)
    define(:update_verification, action: :update_verification)
    define(:update_verification_and_trust, action: :update_verification_and_trust)
    define(:soft_delete, action: :soft_delete)
    define(:transition_embedding_status, action: :transition_embedding_status)
    define(:with_deleted, action: :with_deleted)
  end

  actions do
    defaults([:destroy])

    read :read do
      primary?(true)
      prepare(build(filter: [is_nil: :deleted_at]))
    end

    create :store do
      primary?(true)

      # Embedding fields are accepted so callers (test fixtures, legacy
      # importers, and any path that already has a precomputed vector)
      # can supply them up-front. `Changes.ResolveInitialEmbeddingStatus`
      # respects an explicit `:embedding_status` and only resolves from
      # workspace policy when the caller didn't provide one.
      accept([
        :problem_signature,
        :solution_content,
        :language,
        :framework,
        :runtime,
        :agent_id,
        :tags,
        :verification,
        :trust_score,
        :sharing,
        :workspace_id,
        :session_id,
        :created_by_user_id,
        :tenant_id,
        :embedding,
        :embedding_status,
        :embedding_model
      ])

      change({__MODULE__.Changes.RedactSolutionContent, []})
      change({__MODULE__.Changes.ValidateCrossTenantFk, []})
      change({__MODULE__.Changes.ResolveInitialEmbeddingStatus, []})
      change({__MODULE__.Changes.HintBackfillWorker, []})
    end

    create :import_legacy do
      accept([
        :problem_signature,
        :solution_content,
        :language,
        :framework,
        :runtime,
        :agent_id,
        :tags,
        :verification,
        :trust_score,
        :sharing,
        :workspace_id,
        :session_id,
        :created_by_user_id,
        :tenant_id,
        :deleted_at,
        :embedding,
        :embedding_status,
        :embedding_model
      ])

      argument(:id, :uuid, allow_nil?: true)
      argument(:inserted_at, :utc_datetime_usec, allow_nil?: true)
      argument(:updated_at, :utc_datetime_usec, allow_nil?: true)

      change({__MODULE__.Changes.AcceptLegacyTimestamps, []})
      change({__MODULE__.Changes.RedactSolutionContent, []})
      change({__MODULE__.Changes.ValidateCrossTenantFk, []})
      change({__MODULE__.Changes.ResolveInitialEmbeddingStatus, []})
    end

    read :by_signature do
      argument(:signature, :string, allow_nil?: false)
      argument(:workspace_id, :uuid, allow_nil?: false)
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:local_visibility, {:array, :atom}, default: [:local, :shared, :public])
      argument(:cross_workspace_visibility, {:array, :atom}, default: [:public])

      prepare(build(filter: [is_nil: :deleted_at]))

      filter(
        expr(
          tenant_id == ^arg(:tenant_id) and problem_signature == ^arg(:signature) and
            ((workspace_id == ^arg(:workspace_id) and sharing in ^arg(:local_visibility)) or
               (workspace_id != ^arg(:workspace_id) and
                  sharing in ^arg(:cross_workspace_visibility)))
        )
      )

      prepare(build(sort: [trust_score: :desc, updated_at: :desc]))
    end

    read :stats do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:workspace_id, :uuid, allow_nil?: false)

      prepare(build(filter: [is_nil: :deleted_at]))
      filter(expr(tenant_id == ^arg(:tenant_id) and workspace_id == ^arg(:workspace_id)))
    end

    read :with_deleted do
      description("Replay/audit read that does NOT filter out soft-deleted rows.")
    end

    update :update_trust do
      accept([:trust_score])
      require_atomic?(false)
    end

    update :update_verification do
      accept([:verification])
      require_atomic?(false)
    end

    update :update_verification_and_trust do
      accept([:verification])
      require_atomic?(false)
      change({__MODULE__.Changes.RecomputeTrustScore, []})
      change({__MODULE__.Changes.RecordReputationOutcome, []})
    end

    update :soft_delete do
      accept([])
      require_atomic?(false)
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :transition_embedding_status do
      accept([
        :embedding,
        :embedding_status,
        :embedding_model,
        :embedding_attempt_count,
        :embedding_next_attempt_at,
        :embedding_last_error
      ])

      require_atomic?(false)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :problem_signature, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :solution_content, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :language, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :framework, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :runtime, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :agent_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tags, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :verification, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :trust_score, :float do
      allow_nil?(false)
      public?(true)
      default(0.0)
    end

    attribute :sharing, :atom do
      allow_nil?(false)
      public?(true)
      default(:local)
      constraints(one_of: [:local, :shared, :public])
    end

    # Phase 0 scope FKs
    attribute :workspace_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :created_by_user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    # Embedding state machine
    attribute :embedding, :vector do
      allow_nil?(true)
      public?(true)
      constraints(dimensions: 1024)
    end

    attribute :embedding_status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :processing, :ready, :failed, :disabled])
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

    attribute :embedding_model, :string do
      allow_nil?(true)
      public?(true)
    end

    # Generated columns — populated by Postgres `GENERATED ALWAYS AS (...) STORED`.
    # The Ash-emitted migration is hand-edited in priv/repo/migrations/* to
    # add the GENERATED clauses. Without that, both columns are plain types
    # and FTS / lexical search silently never match.
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

    # Soft delete
    attribute :deleted_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :workspace, WorkspaceResource do
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :session, SessionResource do
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :created_by, JidoClaw.Accounts.User do
      source_attribute(:created_by_user_id)
      define_attribute?(false)
      attribute_writable?(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Inline change modules — small enough not to warrant their own files,
  # large enough to keep out of the actions block.
  # ---------------------------------------------------------------------------

  defmodule Changes.RedactSolutionContent do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        case Ash.Changeset.get_attribute(cs, :solution_content) do
          nil ->
            cs

          content when is_binary(content) ->
            redacted = Transcript.redact(content, json_aware_keys: [])
            Ash.Changeset.force_change_attribute(cs, :solution_content, redacted)

          _ ->
            cs
        end
      end)
    end
  end

  defmodule Changes.AcceptLegacyTimestamps do
    @moduledoc """
    Bridge action arguments → attributes for `id`, `inserted_at`,
    `updated_at` on `:import_legacy`. Ash forbids `accept`-ing
    primary keys and timestamps, but the migration task needs to
    preserve the legacy values so re-running the migration is
    idempotent.
    """
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      changeset
      |> apply_argument(:id, :id)
      |> apply_argument(:inserted_at, :inserted_at)
      |> apply_argument(:updated_at, :updated_at)
    end

    defp apply_argument(cs, arg, attr) do
      case Ash.Changeset.get_argument(cs, arg) do
        nil -> cs
        value -> Ash.Changeset.force_change_attribute(cs, attr, value)
      end
    end
  end

  defmodule Changes.ValidateCrossTenantFk do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        tenant_id = Ash.Changeset.get_attribute(cs, :tenant_id)
        workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)
        session_id = Ash.Changeset.get_attribute(cs, :session_id)

        cs
        |> validate_workspace_tenant(workspace_id, tenant_id)
        |> validate_session_scope(session_id, workspace_id, tenant_id)
      end)
    end

    defp validate_workspace_tenant(cs, nil, _tenant_id), do: cs

    defp validate_workspace_tenant(cs, workspace_id, tenant_id) do
      case Ash.get(WorkspaceResource, workspace_id, domain: JidoClaw.Workspaces) do
        {:ok, %{tenant_id: ^tenant_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant}} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id,
            message: "cross_tenant_fk_mismatch",
            vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant]
          )

        {:error, _} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id,
            message: "workspace_not_found"
          )
      end
    end

    defp validate_session_scope(%{errors: errors} = cs, _, _, _) when errors != [], do: cs
    defp validate_session_scope(cs, nil, _workspace_id, _tenant_id), do: cs

    defp validate_session_scope(cs, session_id, workspace_id, tenant_id) do
      case Ash.get(SessionResource, session_id, domain: JidoClaw.Conversations) do
        {:ok, %{tenant_id: ^tenant_id, workspace_id: ^workspace_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant, workspace_id: parent_workspace}} ->
          Ash.Changeset.add_error(cs,
            field: :session_id,
            message: "cross_tenant_fk_mismatch",
            vars: [
              supplied_tenant: tenant_id,
              supplied_workspace: workspace_id,
              parent_tenant: parent_tenant,
              parent_workspace: parent_workspace
            ]
          )

        {:error, _} ->
          Ash.Changeset.add_error(cs,
            field: :session_id,
            message: "session_not_found"
          )
      end
    end
  end

  defmodule Changes.ResolveInitialEmbeddingStatus do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        # If the caller already set embedding_status (e.g. import_legacy
        # carrying :ready or :disabled), respect it. Otherwise resolve
        # from the Workspace's embedding_policy.
        case Ash.Changeset.get_attribute(cs, :embedding_status) do
          status when status in [:ready, :failed, :disabled, :processing] ->
            cs

          _ ->
            workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)
            resolve_status_from_policy(cs, workspace_id)
        end
      end)
    end

    defp resolve_status_from_policy(cs, nil), do: cs

    defp resolve_status_from_policy(cs, workspace_id) do
      case Ash.get(WorkspaceResource, workspace_id, domain: JidoClaw.Workspaces) do
        {:ok, %{embedding_policy: :disabled}} ->
          Ash.Changeset.force_change_attribute(cs, :embedding_status, :disabled)

        {:ok, %{embedding_policy: policy}} when policy in [:default, :local_only] ->
          Ash.Changeset.force_change_attribute(cs, :embedding_status, :pending)

        _ ->
          # Workspace not found or unknown policy — leave at default.
          cs
      end
    end
  end

  defmodule Changes.HintBackfillWorker do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      # Use after_transaction so we only hint the worker AFTER the
      # transaction commits — running the hint inside after_action could
      # signal on a row that's about to be rolled back.
      Ash.Changeset.after_transaction(changeset, fn _cs, result ->
        case result do
          {:ok, %{embedding_status: :pending, id: id}} ->
            send_hint_safely(id)

          _ ->
            :ok
        end

        result
      end)
    end

    defp send_hint_safely(id) do
      worker = JidoClaw.Embeddings.BackfillWorker

      try do
        if Process.whereis(worker), do: send(worker, {:hint_pending, id})
        :ok
      rescue
        _ -> :ok
      end
    end
  end

  defmodule Changes.RecomputeTrustScore do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        # The :verification attribute is being set; combine the data
        # currently on the row with the new verification map and
        # recompute trust via Trust.compute/2 with the agent's reputation
        # threaded through as :agent_reputation.
        record = cs.data
        new_verification = Ash.Changeset.get_attribute(cs, :verification)
        merged = %{record | verification: new_verification}

        agent_rep_score =
          case JidoClaw.Solutions.Reputation.get(record.tenant_id, record.agent_id || "unknown") do
            {:ok, nil} -> 0.5
            {:ok, %{score: score}} -> score
            _ -> 0.5
          end

        score =
          JidoClaw.Solutions.Trust.compute(merged, agent_reputation: agent_rep_score)

        Ash.Changeset.force_change_attribute(cs, :trust_score, score)
      end)
    end
  end

  defmodule Changes.RecordReputationOutcome do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_transaction(changeset, fn _cs, result ->
        with {:ok, solution} <- result,
             %{tenant_id: tenant_id, agent_id: agent_id, verification: verification}
             when is_binary(tenant_id) and is_binary(agent_id) <- solution do
          status = verification_status(verification)
          maybe_record(status, tenant_id, agent_id)
        end

        result
      end)
    end

    defp verification_status(%{"status" => s}) when is_binary(s), do: s
    defp verification_status(%{status: s}) when is_binary(s), do: s
    defp verification_status(_), do: nil

    defp maybe_record("passed", tenant_id, agent_id),
      do: JidoClaw.Solutions.Reputation.record_success(tenant_id, agent_id)

    defp maybe_record("failed", tenant_id, agent_id),
      do: JidoClaw.Solutions.Reputation.record_failure(tenant_id, agent_id)

    defp maybe_record(_other, _tenant_id, _agent_id), do: :ok
  end
end
