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
    bypass action([
             :by_id_global,
             :list_non_terminal_global,
             :referencing_prototype_global,
             :claimable
           ]) do
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

      # Composer lineage (AR-2 Phase 2a): parent → child-runs + recovery scan.
      index([:tenant_id, :parent_run_id])

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
    define(:claimable, args: [:pending_cutoff])
    define(:by_id, action: :read, get_by: [:id])
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:by_idempotency_key, args: [:idempotency_key], get?: true)
    define(:set_checkpoint, action: :set_checkpoint)

    define(:list_referencing_prototype_global,
      action: :referencing_prototype_global,
      args: [:prototype_id]
    )
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
        :idempotency_key,
        :parent_run_id,
        :user_id,
        :project_id,
        :metadata
      ])

      change(set_attribute(:status, :pending))
      change(__MODULE__.Changes.ValidateCrossTenant)
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

    read :by_idempotency_key do
      description("Tenant-scoped lookup of the run owning a launch idempotency key.")
      get?(true)
      argument(:idempotency_key, :string, allow_nil?: false)
      filter(expr(idempotency_key == ^arg(:idempotency_key)))
    end

    # AR-8b-2 C3 retention-sweep guard: is a prototype dir still needed by a
    # live run? The only process that reads `.prototypes/<id>/` after launch is
    # an in-flight sketch run, whose parent carries
    # `config["premises"]["prototype_id"]` and stays non-terminal for the
    # worker's lifetime. Cross-tenant (the sweeper is system-level); bracket
    # access compiles to native JSONB (`#>>`) — guarded by a self-verifying SQL
    # test. `config` is `public?(false)`, which does not block an in-resource
    # action filter (the `set_status` private-attribute precedent). `limit: 1` —
    # `reference_state/1` only needs existence. No GIN index: `multitenancy(:bypass)`
    # drops the tenant predicate, so the existing `[:status, :claim_expires_at]`
    # index (leading `status`, `all_tenants?: true`) serves the status filter and
    # `limit: 1` stops at the first hit.
    read :referencing_prototype_global do
      description(
        "Cross-tenant non-terminal runs whose premises reference a prototype_id (C3 sweep guard)."
      )

      multitenancy(:bypass)
      argument(:prototype_id, :string, allow_nil?: false)
      prepare(build(limit: 1))

      filter(
        expr(
          status in [:pending, :running, :awaiting_approval] and
            config["premises"]["prototype_id"] == ^arg(:prototype_id)
        )
      )
    end

    # §4.11 lease reclaim scan (WS1; WS3 production caller): a `:pending`/`:running`
    # run whose lease lapsed, or an aged never-claimed `:pending` run; oldest-first.
    # Cross-tenant system scan by `WorkflowLease.claim_next/1` + `claim_run/1`
    # (policy-bypassed + `multitenancy(:bypass)`, like `list_non_terminal_global`).
    # WS3 Component 2: the genesis clause (never-claimed `:pending`+nil-token) gains an
    # age cutoff so the always-on Pooler can't steal a just-created run in the
    # create→lease-stamp gap (boot never races live launches; the Pooler does). It
    # rides the `:pending_cutoff` `argument` (a runtime grace a static filter can't
    # carry; `read_claimable/0` computes `now() - pending_grace_seconds`).
    read :claimable do
      description("Cross-tenant lease-expired or aged-pending-unclaimed runs (WS3 reclaim scan).")
      public?(false)
      multitenancy(:bypass)
      argument(:pending_cutoff, :utc_datetime_usec, allow_nil?: false)
      prepare(build(sort: [inserted_at: :asc]))

      # C-M5: the expired-lease clause compares against the DB clock via a raw
      # `fragment("? < now()", ...)` (SQL `now()`, no bound param) — NOT Ash `now()`
      # (an app-clock param), closing the whole cross-node skew window. The
      # `:pending_cutoff` clause stays app-clock (see `WorkflowLease` for the note).
      filter(
        expr(
          (status in [:pending, :running] and not is_nil(claim_expires_at) and
             fragment("? < now()", claim_expires_at)) or
            (status == :pending and is_nil(claim_token) and
               inserted_at < ^arg(:pending_cutoff))
        )
      )
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

    # Payload visibility (T2-2): `result`/`error` are `public?(false)` so no
    # Ash API extension (AshAdmin included — accepted consequence; the
    # dashboard's per-run "Reveal payloads" toggle is the replacement surface)
    # exposes raw payloads. Still written by the projection's `set_status`
    # accept (the `set_checkpoint` private-attribute precedent) and readable
    # on loaded structs — every struct reader routes through
    # `JidoClaw.Orchestration.Visibility`.
    attribute :result, :map do
      allow_nil?(true)
      public?(false)
    end

    attribute :error, :string do
      allow_nil?(true)
      public?(false)
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

    # Launch idempotency (T2-3): a caller-supplied dedupe key — today only
    # scheduled cron ticks set one (`"cron:<job_id>:<iso8601 next_run>"`), so a
    # double-delivered tick resolves to the existing run instead of starting a
    # second reactor. Manual triggers and all other launch paths leave it nil
    # (always run); the `:unique_run_idempotency` identity below keeps NULLs
    # distinct so nil-key runs coexist freely.
    attribute :idempotency_key, :string do
      allow_nil?(true)
      public?(false)
      default(nil)
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

    # §4.11 claim/fencing data model: node owner (`claimed_by`), expiry
    # (`claim_expires_at`), fencing token (`claim_token`). SHIPPED (WS1–WS5):
    # DB-clock stamped/renewed by `WorkflowLease`, CAS-rotated on reclaim
    # (`claim_next`/`claim_run`), read by `:claimable`. All three are nil only while
    # a run is UNLEASED (byte-identical to pre-lease: no preflight/sidecar/fence).
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

    # Composer lineage (AR-2 Phase 2a): a parent `WorkflowRun` whose every wave is
    # a child linked here. Lets Ash define `parent_run_id` (no
    # `define_attribute?(false)`); `Changes.ValidateCrossTenant` cross-tenant-guards it.
    belongs_to(:parent_run, __MODULE__, allow_nil?: true, attribute_writable?: true)

    has_many(:child_runs, __MODULE__, destination_attribute: :parent_run_id)
    has_many(:steps, JidoClaw.Orchestration.WorkflowStep)
    has_many(:agent_cases, JidoClaw.Orchestration.AgentCase)
    has_many(:events, JidoClaw.Orchestration.WorkflowEvent)
  end

  identities do
    # Launch-dedupe identity for `ReactorRunner`'s read-first → create →
    # unique-violation backstop. `nils_distinct?` is the Ash default but is
    # explicit here because the semantics are load-bearing: almost every run
    # has a NULL key, and they must never collide. Attribute multitenancy
    # auto-prefixes the generated unique index with `tenant_id`.
    identity(:unique_run_idempotency, [:idempotency_key], nils_distinct?: true)
  end
end
