defmodule JidoClaw.Orchestration.WorkflowEvent do
  @moduledoc """
  Append-only audit log for `WorkflowRun`. One immutable row per run/step
  transition; `WorkflowRun.status` is a projection of this log, written
  only by the append path (`Changes.Allocate`).

  Deliberately does **not** use the `JidoClaw.Resource` macro — that macro
  always injects `bypass action(:by_id_global)`, which fails to compile for
  a resource with no `:by_id_global` action. Events are only ever read
  run-scoped (`:for_run`), never by global id, so this ships a plain
  `use Ash.Resource` plus the two non-bypass tenant policies.

  `seq` is monotonic and gap-free **per run**, allocated solely by
  `Changes.Allocate` under a per-run `FOR UPDATE` lock; callers never supply
  it. The unique `(workflow_run_id, seq)` index is the backstop.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias JidoClaw.Orchestration.WorkflowEvent.Changes.Allocate

  # Only run-scoped reads + the append create — no `:by_id_global`, so omit
  # the bypass and hand-write the two standard tenant policies.
  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  postgres do
    table("workflow_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      # Uniqueness fence (optimistic concurrency) + the range/sort index for
      # `:for_run`. NOT monotonicity — that is the append helper's job.
      index([:workflow_run_id, :seq], unique: true)
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:append)
    define(:for_run, args: [:workflow_run_id])
    define(:list, action: :read)
  end

  actions do
    defaults([:read])

    create :append do
      description("Append one immutable event to a run's log; the sole seq allocator.")
      primary?(true)
      transaction?(true)
      # `:seq` is forced by Allocate; `:tenant_id` is set from the tenant: opt
      # by Ash. Neither is accepted from callers.
      accept([:workflow_run_id, :kind, :payload, :metadata, :occurred_at])
      change(Allocate)
    end

    read :for_run do
      description("List one run's events in seq order.")
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      prepare(build(sort: [seq: :asc]))
      filter(expr(workflow_run_id == ^arg(:workflow_run_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :seq, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)

      constraints(
        one_of: [
          :run_started,
          :run_resumed,
          :step_started,
          :step_completed,
          :step_failed,
          :step_retried,
          :step_compensated,
          :step_undone,
          :approval_requested,
          :approval_resolved,
          :approval_retracted,
          :run_halted,
          :run_completed,
          :run_failed,
          :run_cancelled,
          :run_abandoned,
          :run_recovered,
          # AR-2 Composer (Phase 2c) — the durable composer delta log. None are a
          # DB check constraint (an Ash app-level `one_of`, stored as text, like
          # `WorkflowRun.status`), so no migration. The projection
          # (`JidoClaw.RouteComposer.Projection`) folds every kind; the loop
          # produces the additive 5 + the 5 in-loop terminals (+ `signals_retracted`
          # on a paired-verdict flip). The rest are defined + folded + unit-tested
          # now; their producers are Phase 4 gates / AR-4 reruns.
          #
          # Additive — wave deltas (parent stays `:running`; NOT status-authority).
          :route_composed,
          :wave_started,
          :wave_completed,
          :signals_published,
          :artifacts_produced,
          :wave_paused,
          :wave_resumed,
          # Subtractive — wave deltas (parent stays `:running`; NOT status-authority).
          :signals_retracted,
          :stages_invalidated,
          :artifacts_invalidated,
          # Parent-terminal — the composer's own terminal vocabulary. Status-authority
          # (see `WorkflowEvent.Projection`): the four failure kinds + not-converged
          # → `:failed`, converged → `:completed`, reject/abandon → `:cancelled`.
          :route_converged,
          :route_not_converged,
          :route_deadlocked,
          :route_budget_exhausted,
          :route_failed,
          :route_rejected,
          :route_abandoned
        ]
      )
    end

    attribute :payload, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    # Attribute-level default (not a before_action default, which runs after
    # validation and would trip allow_nil?(false) on an omitted value).
    attribute :occurred_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    timestamps()
  end

  relationships do
    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end
end
