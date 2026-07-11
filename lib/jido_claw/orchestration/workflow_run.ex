# WorkflowRun is the orchestration aggregate's single declarative schema: splitting
# its tightly-coupled policies, actions, encrypted attributes, and relationships into
# fragments would make the projection and lease invariants harder to audit.
# credo:disable-for-this-file AshCredo.Check.Refactor.LargeResource
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
    extensions: [AshCloak, AshGraphql.Resource]

  policies do
    bypass action([
             :by_id_global,
             :list_non_terminal_global,
             :referencing_prototype_global,
             :claimable
           ]) do
      authorize_if(always())
    end

    bypass actor_attribute_equals(:kind, :system) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(JidoClaw.Authorization.Checks.ActorTenantActive)
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(
        expr(
          tenant_id == ^actor(:tenant_id) and
            exists(
              JidoClaw.Tenants.Tenant,
              id == parent(tenant_id) and status == :active
            )
        )
      )
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

  # Read-only GraphQL exposure (argus P1). Field exposure is a positive
  # allowlist (`show_fields`): the AshCloak-encrypted columns
  # (`resume_checkpoint`/`replay_inputs` and their decrypting calculations),
  # the lease credentials (`claim_token`/`claimed_by`/`claim_expires_at`),
  # and the raw `result`/`error`/`config` payloads are all absent by
  # construction — a new field stays off the API until deliberately listed.
  # `disposition`/`findings_deferred_count` ride along so the camus C1-4
  # "never plain green" rule reaches GraphQL from day one. Derived
  # filter/sort inputs are disabled (fixed-shape surface; `:recent` owns
  # ordering).
  graphql do
    type(:workflow_run)
    derive_filter?(false)
    derive_sort?(false)

    show_fields([
      :id,
      :name,
      :workflow_type,
      :status,
      :disposition,
      :findings_deferred_count,
      :started_at,
      :completed_at,
      :inserted_at,
      :updated_at,
      :project
    ])
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
    define(:list_recent, action: :recent)
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
      # The terminal cleanup function change below cannot be expressed
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
      argument(:revoke_claim, :boolean, default: false)

      change(fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :clear_checkpoint) do
          Ash.Changeset.force_change_attribute(changeset, :encrypted_resume_checkpoint, nil)
        else
          changeset
        end
      end)

      # Every terminal revokes the executor's lease credential in the SAME
      # projection transaction as the status flip. Preserve `claimed_by` for
      # post-commit cancellation routing/audit, but clear the token and expiry so
      # a partitioned sidecar cannot renew a terminal run indefinitely.
      change(fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :revoke_claim) do
          changeset
          |> Ash.Changeset.force_change_attribute(:claim_token, nil)
          |> Ash.Changeset.force_change_attribute(:claim_expires_at, nil)
        else
          changeset
        end
      end)
    end

    # Private write of the durable resume checkpoint blob. Production callers
    # route through `WorkflowLog.persist_gate_checkpoint/4`, which holds the run
    # row lock and re-checks `:awaiting_approval` + the lease token before invoking
    # this low-level action. The column is cleared centrally by the projection on
    # every terminal (Decision 7).
    update :set_checkpoint do
      description("Internal write of the durable resume checkpoint blob on gate pause.")
      public?(false)
      # The function change that releases `claim_expires_at` is protected by
      # `WorkflowLog.persist_gate_checkpoint/3`'s transaction + FOR UPDATE lock.
      require_atomic?(false)
      accept([:resume_checkpoint])

      # A fully-established park owns no live executor. Release the lease expiry
      # in the same locked transaction as the checkpoint write; GateResume's
      # `claim_resume/3` changes NULL/expired back to a fresh lease exactly once.
      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :claim_expires_at, nil)
      end)
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

    # GraphQL `recentWorkflowRuns` list action: newest first with an id
    # tie-break for deterministic pages, bounded by a validated `limit`
    # (over-cap is an honest validation error, never a silent clamp).
    # Primary `:read` stays untouched; tenant scoping + the active-tenant
    # EXISTS come from the standard read policy — `:recent` joins no bypass.
    read :recent do
      description("Most recent workflow runs for the GraphQL surface.")

      argument :limit, :integer do
        allow_nil?(false)
        default(50)
        constraints(min: 1, max: 200)
      end

      prepare(build(limit: arg(:limit), sort: [inserted_at: :desc, id: :desc]))
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
    # run whose lease lapsed, an awaiting gate whose lease lapsed before its
    # checkpoint was persisted, or an aged never-claimed `:pending` run; oldest-first.
    # Cross-tenant system scan by `WorkflowLease.claim_next/1` + `claim_run/1`
    # (policy-bypassed + `multitenancy(:bypass)`, like `list_non_terminal_global`).
    # WS3 Component 2: the genesis clause (never-claimed `:pending`+nil-token) gains an
    # age cutoff so the always-on Pooler can't steal a just-created run in the
    # create→lease-stamp gap (boot never races live launches; the Pooler does). It
    # rides the `:pending_cutoff` `argument` (a runtime grace a static filter can't
    # carry; `read_claimable/0` computes `now() - pending_grace_seconds`).
    read :claimable do
      description(
        "Cross-tenant lease-expired, dangling-gate, or aged-pending-unclaimed runs (WS3 reclaim scan)."
      )

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
            (status == :awaiting_approval and is_nil(encrypted_resume_checkpoint) and
               not is_nil(claim_expires_at) and fragment("? < now()", claim_expires_at)) or
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

    # Typed enum (argus P1): was `:atom` + `one_of` — ash_graphql maps plain
    # atoms to GraphQL String, so the typed `WorkflowRunStatus` needs a real
    # `Ash.Type.Enum`. Same text storage, same atom values in Elixir; the
    # value set lives in `WorkflowRun.Status.values/0`.
    attribute :status, __MODULE__.Status do
      allow_nil?(false)
      public?(true)
      default(:pending)
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

    # Explicitly public: timestamps default `public?: false`, and the GraphQL
    # `show_fields` allowlist can only expose fields that are public — a
    # deliberate shared Ash public-interface change (argus P1).
    timestamps(public?: true)
  end

  # Shared-derivation seam (argus P1): both calculations delegate to the
  # `Visibility` functions `run_view/3` already uses, so the terminal
  # disposition semantics cannot fork between the operator projection and
  # GraphQL. Not filterable/sortable: they derive from the private `result`
  # JSONB per-row in Elixir — there is nothing for the data layer to push
  # down, and the GraphQL surface is fixed-shape anyway.
  calculations do
    calculate :disposition, :string, __MODULE__.Calculations.Disposition do
      public?(true)
      filterable?(false)
      sortable?(false)
    end

    calculate :findings_deferred_count, :integer, __MODULE__.Calculations.FindingsDeferredCount do
      public?(true)
      filterable?(false)
      sortable?(false)
    end
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

    # `public?: true` so the GraphQL type can traverse run → project (the
    # `WorkflowStep.workflow_run` precedent); `project_id` itself stays off
    # the allowlist — clients read the nested object, not the raw FK.
    belongs_to(:project, JidoClaw.Projects.Project,
      define_attribute?: false,
      attribute_writable?: true,
      allow_nil?: true,
      public?: true
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
