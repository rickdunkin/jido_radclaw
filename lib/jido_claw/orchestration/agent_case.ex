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
  audit). A separate `AgentCaseEvent` timeline table is a deferred follow-up.

  ## Concurrency fence

  Two operators can both read a `:pending` case and race to decide it. The
  `:approve`/`:reject`/`:cancel` actions each carry a
  `change filter(expr(status == :pending))`, which compiles to a DB-side
  `UPDATE … WHERE status = 'pending'`: exactly one writer flips the row, the
  loser's update matches zero rows and returns a stale-record `{:error, _}`.
  This is both the idempotency guard (a duplicate `decide` is a clean error)
  and the multi-approver race fence — enforced in the database, not over
  in-memory loaded data.

  ## Single gate per run

  This slice supports one gate per run. Multi-gate identification (reading the
  halted step name to disambiguate) is a documented follow-up.
  """

  use JidoClaw.Resource, domain: JidoClaw.Orchestration

  postgres do
    table("agent_cases")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :status])
      index([:workflow_run_id, :status])
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

      change(set_attribute(:status, :pending))
    end

    # Decision write — approve. The `filter` change is the DB-side concurrency
    # fence: only a still-`:pending` row flips, so a duplicate/concurrent
    # decide loses cleanly with a stale-record error (idempotent).
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
      constraints(one_of: [:irreversible_write])
    end

    # The gate behaviour module (`JidoClaw.Orchestration.Gates` impl) whose
    # `after_approved`/`after_rejected` notifications fire on the decision path.
    attribute :gate_module, :atom do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :approved, :rejected, :cancelled])
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

    timestamps()
  end

  relationships do
    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end
end
