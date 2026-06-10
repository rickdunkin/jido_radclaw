defmodule JidoClaw.Orchestration.WorkflowRun do
  @moduledoc """
  The durable envelope of one reactor execution: status (a projection of the
  `WorkflowEvent` log), result/error, the encrypted resume checkpoint, the
  replay columns (`definition_hash` + encrypted `replay_inputs` +
  `retry_of_id` provenance — see `JidoClaw.Orchestration.Replay`), and the
  (data-model-only) claim/fencing columns for the deferred multi-node lease.

  Hand-rolls `use Ash.Resource` + the standard 13-line tenant policy block
  (rather than `use JidoClaw.Resource`) so the `AshCloak` extension can be
  declared — the macro does not forward `extensions:`, and teaching it to
  would touch every tenant-scoped resource (the `WorkflowEvent`/`SecretRef`
  precedent).
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  policies do
    bypass action([:by_id_global, :list_non_terminal_global]) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  # Encryption-at-rest for the resume checkpoint (Decision 2 fast-follow): the
  # blob holds UNREDACTED reactor inputs/results. AshCloak renames the column
  # to `encrypted_resume_checkpoint` and exposes `resume_checkpoint` as a
  # decrypting calculation; `set_checkpoint`'s accepted attribute is rewritten
  # into an argument + encrypt change. Presence checks read the encrypted
  # column directly (the calculation is `%Ash.NotLoaded{}` unless loaded);
  # only `GateResume`'s decode path loads/decrypts. Terminal clears write
  # `encrypted_resume_checkpoint: nil` directly — encrypting `nil` would store
  # ciphertext-of-nil, not SQL NULL, and break every presence check.
  #
  # `replay_inputs` (Phase 4) gets the same treatment for the same reason —
  # it holds the run's unredacted original inputs — but a different lifecycle:
  # written once at create, NEVER cleared (the terminal `clear_checkpoint`
  # force-clear touches only `encrypted_resume_checkpoint`). Only
  # `Replay`'s decode path loads/decrypts it.
  cloak do
    vault(JidoClaw.Security.Vault)
    attributes([:resume_checkpoint, :replay_inputs])
  end

  postgres do
    table("workflow_runs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :status])
      index([:tenant_id, :completed_at])

      # Claim/fencing scan indexes (§4.11 data model — implementation
      # deferred). Deliberately global, NOT tenant-prefixed: the future
      # `:claim_next` lease scanner is a system-level cross-tenant poller
      # (like recovery's `list_non_terminal_global`), and AshPostgres would
      # otherwise auto-prefix attribute-multitenant indexes with `tenant_id`.
      index([:status, :claim_expires_at], all_tenants?: true)
      index([:claimed_by], all_tenants?: true)
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:create)
    define(:list, action: :read)
    define(:destroy, action: :destroy)
    define(:list_active)
    define(:list_by_project, action: :by_project)
    define(:list_non_terminal_global)
    define(:by_id, action: :read, get_by: [:id])
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:set_checkpoint, action: :set_checkpoint)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Create a new workflow run in pending status.")
      primary?(true)

      accept([
        :name,
        :workflow_type,
        :config,
        :definition_hash,
        :replay_inputs,
        :retry_of_id,
        :user_id,
        :project_id,
        :metadata
      ])

      change(set_attribute(:status, :pending))
    end

    # Projection-owned status write — the ONLY writer of `status` and its
    # stamps. Called solely by `WorkflowEvent.Changes.Allocate` in the append
    # transaction. It carries no status precondition because legality is
    # enforced upstream by `WorkflowEvent.Projection.next_status/2` before this
    # action is ever reached. `public?(false)` keeps it out of code_interface
    # and Ash API extensions (e.g. AshAdmin); the change invokes it via
    # `Ash.Changeset.for_update/3` + `Ash.update`.
    update :set_status do
      description("Internal projection write of status + stamps from the event log.")
      public?(false)
      # The clear_checkpoint function change below cannot be expressed
      # atomically; this action only ever runs inside the append transaction
      # under the per-run FOR UPDATE lock, so atomicity comes from the caller.
      require_atomic?(false)
      accept([:status, :started_at, :completed_at, :result, :error])

      # Terminal checkpoint clear (Decision 7): force the REAL encrypted
      # column to true SQL NULL — deliberately NOT the cloaked
      # `:resume_checkpoint` argument, whose encrypt rewrite would store
      # ciphertext-of-nil and break every presence check. An argument +
      # force_change (not `accept`) because the `encrypted_resume_checkpoint`
      # attribute only exists after AshCloak's transformer runs — accept-list
      # validation happens earlier in the compile pipeline.
      argument(:clear_checkpoint, :boolean, default: false)

      change(fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :clear_checkpoint) do
          Ash.Changeset.force_change_attribute(changeset, :encrypted_resume_checkpoint, nil)
        else
          changeset
        end
      end)
    end

    # Private write of the durable resume checkpoint blob. Called by
    # `ReactorRunner.finalize` on a legitimate gate halt, *after* the gate
    # step's in-txn `approval_requested` has flipped the run to
    # `:awaiting_approval`. No status precondition: the column is a plain
    # `:binary` blob (the encoded checkpoint envelope), cleared centrally by
    # the projection on every terminal (Decision 7).
    update :set_checkpoint do
      description("Internal write of the durable resume checkpoint blob on gate pause.")
      public?(false)
      accept([:resume_checkpoint])
    end

    read :list_active do
      description("List workflow runs that have not yet reached a terminal state.")
      filter(expr(status in [:pending, :running, :awaiting_approval]))
    end

    read :list_non_terminal_global do
      description("Cross-tenant scan of non-terminal runs for boot recovery.")
      multitenancy(:bypass)
      filter(expr(status in [:pending, :running, :awaiting_approval]))
    end

    read :by_id_global do
      description("Cross-tenant lookup of one run by id (policy-bypassed).")
      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_project do
      description("List workflow runs belonging to a project.")
      argument(:project_id, :uuid, allow_nil?: false)
      filter(expr(project_id == ^arg(:project_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :workflow_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)

      constraints(
        one_of: [
          :pending,
          :running,
          :awaiting_approval,
          :completed,
          :failed,
          :cancelled,
          :abandoned
        ]
      )
    end

    attribute :config, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :result, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :error, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :retry_of_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    # Fingerprint of the workflow definition at launch (Phase 4): sha256 hex of
    # a skill's canonical semantic term, or a module's BEAM md5 hex — see
    # `JidoClaw.Orchestration.DefinitionFingerprint`. Replay's definition gate
    # refuses when the freshly recomputed fingerprint differs (skills are
    # LLM-edited YAML; re-running changed semantics silently is the footgun).
    attribute :definition_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    # Durable resume checkpoint: a single `:erlang.term_to_binary` blob (the
    # two-layer envelope encoded by `ReactorRunner.encode_checkpoint/3` and
    # decoded only by `GateResume`), NOT an Elixir map. Present *only* while a
    # run is `:awaiting_approval` or `:running` (resume in flight); every
    # terminal clears it via the projection (Decision 7). Encrypted at rest by
    # the `cloak` block above (the stored column is
    # `encrypted_resume_checkpoint`; this declaration becomes a decrypting
    # calculation) — it holds unredacted reactor inputs/results.
    attribute :resume_checkpoint, :binary do
      allow_nil?(true)
      public?(false)
    end

    # Durable replay inputs (Phase 4): `term_to_binary({version, inputs,
    # extra_context})` encoded by `ReactorRunner` at create and decoded only by
    # `JidoClaw.Orchestration.Replay` — an all-data, `[:safe]`-decodable blob
    # preserving atom keys. Unlike `resume_checkpoint` it is NEVER cleared:
    # replay needs the original inputs after the run is terminal, which is
    # exactly when the checkpoint is gone. Encrypted at rest by the `cloak`
    # block above (stored column: `encrypted_replay_inputs`).
    attribute :replay_inputs, :binary do
      allow_nil?(true)
      public?(false)
    end

    # §4.11 claim/fencing data model: which node owns the run, until when,
    # and the fencing token a claimant must present. Columns land now
    # (greenfield — no later migration); the Pooler/Lease implementation
    # (`:claim_next`, heartbeat, reclaim) is deliberately deferred. All three
    # stay nil until that ships.
    attribute :claimed_by, :string do
      allow_nil?(true)
      public?(false)
    end

    attribute :claim_expires_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :claim_token, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to(:user, JidoClaw.Accounts.User,
      define_attribute?: false,
      attribute_writable?: true,
      allow_nil?: true
    )

    belongs_to(:project, JidoClaw.Projects.Project,
      define_attribute?: false,
      attribute_writable?: true,
      allow_nil?: true
    )

    has_many(:steps, JidoClaw.Orchestration.WorkflowStep)
    has_many(:agent_cases, JidoClaw.Orchestration.AgentCase)
    has_many(:events, JidoClaw.Orchestration.WorkflowEvent)
  end
end
