defmodule JidoClaw.Orchestration.AgentCase do
  @moduledoc """
  The operator-facing record of a single human approval gate on a
  `WorkflowRun`.

  When a gate-bearing reactor reaches a `JidoClaw.Orchestration.GateStep`, the
  step opens an `AgentCase` (status `:pending`) in the same transaction as the
  run's `approval_requested` event (`WorkflowLog.gate_open/3`). The run then
  halts `:awaiting_approval`. An operator approves or rejects the case through
  `JidoClaw.Orchestration.Cases.decide/4` — the single decision point shared by
  the code API, the CLI (`/gates`), and the web dashboard (`/approvals`).

  Run-level gate *facts* live in the append-only `WorkflowEvent` log; this row
  is the durable, queryable operator record (the inbox source, the decision
  audit). Each case transition additionally appends an immutable
  `AgentCaseEvent` timeline row in the same transaction (opened / approved /
  rejected / cancelled / abandoned / retracted).

  ## Concurrency fence

  Two operators can both read a `:pending` case and race to decide it. The
  real fence lives in `JidoClaw.Orchestration.Cases`: each decision commit
  reloads this row `FOR UPDATE` inside its transaction and re-checks the status
  on the fresh, locked struct before writing, so the loser blocks on the row
  lock, reads the winner's committed status, and rolls back. The
  `change filter(expr(status == :pending))` the `:approve`/`:reject`/`:cancel`
  actions carry is an **in-memory precondition**, NOT a DB-side
  `UPDATE … WHERE status = 'pending'` — for *record* updates in
  ash_postgres 2.9 the captured UPDATE keys on `id`/`tenant_id` only. It still
  rejects a *freshly-loaded* non-pending struct (the idempotency guard for a
  sequential duplicate `decide`), but it cannot fence a concurrent stale-loaded
  decider on its own; the `FOR UPDATE` reload is what closes that race.

  ## Single gate per run

  This slice supports one gate per run. Multi-gate identification (reading the
  halted step name to disambiguate) is a documented follow-up.

  ## Tool-call cases (run-less)

  The same row also backs the **conversation-axis** tool-approval gate
  (`kind: :tool_call`), which has no `WorkflowRun`. Those rows are created by
  `JidoClaw.Orchestration.ToolApprovals` via the `:open_tool_call` action with
  `workflow_run_id == nil`, keyed by a `fingerprint` of `{tenant, session,
  tool, args}`. `:approve`/`:reject` flow through the same
  `JidoClaw.Orchestration.Cases.decide/4` path; a partial unique index
  (`agent_cases_pending_fingerprint_index`) guarantees at most one pending case
  per fingerprint so concurrent identical calls collapse to one ticket. The
  approval is single-use (`:consume` stamps `consumed_at` on the approved row)
  and rejections are deny-once (`:consume_rejection` stamps the rejected row),
  so an identical call later re-pends rather than reusing a spent decision. The
  `:create` action stays workflow-strict (`validate(present(:workflow_run_id))`)
  while `:open_tool_call` requires `fingerprint`/`tool_name` instead.
  """

  use JidoClaw.Resource, domain: JidoClaw.Orchestration

  alias JidoClaw.Orchestration.Gate

  postgres do
    table("agent_cases")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :status])
      index([:workflow_run_id, :status])

      # At most one *pending* tool-call case per fingerprint per tenant — the
      # named partial unique index the producer's race-loser re-read keys on
      # (`AshErrors.unique_violation?/2` matches the constraint-name fragment).
      index([:tenant_id, :fingerprint],
        unique: true,
        where: "status = 'pending'",
        name: "agent_cases_pending_fingerprint_index"
      )

      # Plain lookup index for the by-fingerprint classification read.
      index([:tenant_id, :fingerprint])
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
    define(:by_id, action: :read, get_by: [:id])
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:pending_for_run, args: [:workflow_run_id])
    define(:approved_for_run, args: [:workflow_run_id], get?: true)
    define(:pending_for_tenant)
    define(:approve)
    define(:reject)
    define(:cancel)
    define(:abandon)
    define(:reopen)

    # Tool-call (run-less) case API.
    define(:open_tool_call)
    define(:consume)
    define(:consume_rejection)
    define(:by_fingerprint, args: [:fingerprint])
    define(:pending_for_session, args: [:session_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Open a pending approval gate for a step in a workflow run.")
      primary?(true)

      accept([
        :workflow_run_id,
        :step_name,
        :kind,
        :gate_module,
        :details
      ])

      # `workflow_run_id` is now nullable at the column level (tool-call cases
      # have no run), so the workflow create stays strict here.
      validate(present(:workflow_run_id))

      change(set_attribute(:status, :pending))
    end

    # Open a run-less tool-call approval case (the conversation-axis gate).
    # Distinct from `:create`: no run, fingerprint/tool_name required.
    create :open_tool_call do
      description("Open a pending tool-call approval case (no workflow run).")

      accept([
        :step_name,
        :details,
        :fingerprint,
        :tool_name,
        :session_id
      ])

      # Nullable columns + a partial unique index would not protect NULL
      # fingerprints, so the producer contract is enforced here.
      validate(present(:fingerprint))
      validate(present(:tool_name))

      change(set_attribute(:kind, :tool_call))
      change(set_attribute(:gate_module, JidoClaw.Gates.ToolCallGate))
      change(set_attribute(:status, :pending))
    end

    # Decision write — approve. The `filter` change is an in-memory precondition
    # (it does NOT compile to a DB-side `WHERE` for record updates in
    # ash_postgres 2.9), so it rejects a freshly-loaded non-pending struct (the
    # sequential-duplicate idempotency guard) but is NOT the concurrency fence.
    # The fence is the `FOR UPDATE` reload-and-recheck in `Cases` (same model as
    # `:consume` below).
    update :approve do
      description("Approve a pending case; records decision metadata.")
      accept([:decision_comment, :decided_by_id])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :approved))
      change(set_attribute(:decision, :approve))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    update :reject do
      description("Reject a pending case; records decision metadata.")
      accept([:decision_comment, :decided_by_id])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :rejected))
      change(set_attribute(:decision, :reject))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    # Recovery cancels a pending case stranded by a crash between the
    # `gate_open` commit and checkpoint persist (the "dangling gate" branch).
    update :cancel do
      description("Cancel a pending case (boot recovery of a dangling gate).")
      accept([:cancellation_reason])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :cancelled))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    # Operator-initiated abandon of a parked gate (AR-1): deliberately giving
    # up on the run ≠ crash-reaped (`cancel`) ≠ gate-reject. Fenced like the
    # decisions: `commit_abandon` re-reads the pending cases fresh under the
    # per-run `FOR UPDATE` lock (the `filter` here stays an in-memory
    # precondition).
    update :abandon do
      description("Abandon a pending case (operator gave up on the parked run).")
      accept([:cancellation_reason, :decided_by_id])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :abandoned))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    # Stale-approval retraction (AR-1): a recorded-but-not-yet-acted approval
    # is withdrawn pre-resume, so the reopened case carries NO stale decision
    # data. Lock-fenced in `commit_retract` (the case row is reloaded
    # `FOR UPDATE` and re-checked `:approved` before this runs); the `filter`
    # here is an in-memory precondition, and the event-log half of the race
    # fence lives in `Cases.retract/3`.
    update :reopen do
      description("Reopen an approved case whose approval was retracted pre-resume.")
      accept([])
      change(filter(expr(status == :approved)))
      change(set_attribute(:status, :pending))
      change(set_attribute(:decision, nil))
      change(set_attribute(:decided_at, nil))
      change(set_attribute(:decision_comment, nil))
      change(set_attribute(:decided_by_id, nil))
    end

    # Single-use claim on an approved tool-call case. The `filter` change is
    # an in-memory precondition (it does NOT compile to a DB-side `WHERE` for
    # record updates in ash_postgres 2.9; the captured UPDATE keys on
    # `id`/`tenant_id` only). The real concurrency fence is the producer's
    # `FOR UPDATE` re-read in `JidoClaw.Orchestration.ToolApprovals` — the same
    # row-lock idiom `Cases.lock_run/3` uses — which serializes concurrent
    # retries so exactly one consumes the approval and the next identical call
    # re-pends. An approval thus grants ONE attempt, not one successful effect.
    update :consume do
      description("Consume an approved tool-call case (single-use approval).")
      accept([])
      change(filter(expr(status == :approved and is_nil(consumed_at))))
      change(set_attribute(:consumed_at, &DateTime.utc_now/0))
    end

    # Deny-once claim on a rejected tool-call case. Same fencing model as
    # `:consume`: the producer's `FOR UPDATE` re-read is the concurrency fence,
    # so the next identical call re-pends rather than reusing a stale denial.
    update :consume_rejection do
      description("Consume a rejected tool-call case (deny-once).")
      accept([])
      change(filter(expr(status == :rejected and is_nil(consumed_at))))
      change(set_attribute(:consumed_at, &DateTime.utc_now/0))
    end

    read :by_id_global do
      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :pending_for_run do
      description("Pending cases for a run (single-gate today, list for safety).")
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      filter(expr(workflow_run_id == ^arg(:workflow_run_id) and status == :pending))
    end

    read :approved_for_run do
      description("The approved case for a run — the durable decision GateResume reads.")
      get?(true)
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      filter(expr(workflow_run_id == ^arg(:workflow_run_id) and status == :approved))
    end

    read :pending_for_tenant do
      description("All pending cases for the actor's tenant — the operator inbox.")
      prepare(build(sort: [inserted_at: :asc]))
      filter(expr(status == :pending))
    end

    read :by_fingerprint do
      description("Tenant's cases for a fingerprint, newest first — the producer classifier.")
      argument(:fingerprint, :string, allow_nil?: false)
      prepare(build(sort: [inserted_at: :desc]))
      filter(expr(fingerprint == ^arg(:fingerprint)))
    end

    read :pending_for_session do
      description("Pending tool-call cases for a session — the awaiting-approval status probe.")
      argument(:session_id, :uuid, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and status == :pending))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :step_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      # Single-sourced from the gate DSL's kind enum so the two never drift.
      constraints(one_of: Gate.Kinds.all())
    end

    # The gate module (`use JidoClaw.Orchestration.HumanGate`) whose
    # `after_approved`/`after_rejected` notifications fire on the decision path.
    attribute :gate_module, :atom do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :approved, :rejected, :cancelled, :abandoned])
    end

    # Operator-visible context for the decision (must be redactor-safe — it is
    # surfaced in the CLI/web inbox).
    attribute :details, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :decision, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: [:approve, :reject])
    end

    # Nullable: the CLI decides unauthenticated (a system actor, no user id).
    attribute :decided_by_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :decision_comment, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :cancellation_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    # Conversations.Session UUID FK for tool-call cases — the runtime external
    # session id lives in `details` only. Mirrors the ToolOutput pattern: a
    # plain nullable column paired with a `belongs_to :session` that does not
    # define its own attribute.
    attribute :session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    # SHA-256 of the canonical `{tenant, session, tool, args}` term — the
    # tool-call dedup/approval key. Nullable (workflow cases have none);
    # `:open_tool_call` enforces presence so the partial unique index bites.
    attribute :fingerprint, :string do
      allow_nil?(true)
      public?(true)
    end

    # The gated tool's registered name (tool-call cases only).
    attribute :tool_name, :string do
      allow_nil?(true)
      public?(true)
    end

    # Stamped when a tool-call decision is spent: single-use approval
    # (`:consume`) or deny-once rejection (`:consume_rejection`).
    attribute :consumed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    # Nullable at the column level so run-less tool-call cases can exist; the
    # `:create` action's `validate(present(:workflow_run_id))` keeps the
    # workflow path strict.
    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(true)
      public?(true)
    end

    # Conversations.Session FK for tool-call cases. ToolOutput pattern exactly:
    # the explicit `attribute :session_id` above is the column; this defines no
    # attribute of its own, stays writable, and is nullable.
    belongs_to :session, JidoClaw.Conversations.Session do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end

    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end
end
