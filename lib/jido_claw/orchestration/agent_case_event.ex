defmodule JidoClaw.Orchestration.AgentCaseEvent do
  @moduledoc """
  Append-only audit timeline for one `AgentCase` — the per-case event log
  T1-4's thesis called the product ("for an agent that acts while you sleep,
  the audit timeline *is* the product"). One immutable row per case
  transition: opened, approved, rejected, cancelled, abandoned, retracted.

  Every append happens **inside the same transaction** as the case-status
  flip it records (`WorkflowLog.gate_open/3`, `Cases.commit_approve/5` /
  `commit_reject/5` / abandon / retract, and the cancel paths) — the case row
  and its timeline can never disagree.

  Mirrors `WorkflowEvent`'s shape: deliberately a plain `use Ash.Resource`
  (the `JidoClaw.Resource` macro injects a `bypass action(:by_id_global)`
  that fails to compile without that action) plus the two hand-written
  tenant policies. `seq` is monotonic and gap-free **per case**, allocated
  solely by `Changes.Allocate` under a per-case `FOR UPDATE` lock; the unique
  `(agent_case_id, seq)` index is the DB-enforced fence.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias JidoClaw.Orchestration.AgentCaseEvent.Changes.Allocate

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  postgres do
    table("agent_case_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      # Uniqueness fence (optimistic concurrency) + the range/sort index for
      # `:for_case`. NOT monotonicity — that is the allocator's job.
      index([:agent_case_id, :seq], unique: true)
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:append)
    define(:for_case, args: [:agent_case_id])
    define(:list, action: :read)
  end

  actions do
    defaults([:read])

    create :append do
      description("Append one immutable event to a case's timeline; the sole seq allocator.")
      primary?(true)
      transaction?(true)
      # `:seq` is forced by Allocate; `:tenant_id` is set from the tenant: opt
      # by Ash. Neither is accepted from callers.
      accept([:agent_case_id, :type, :data, :occurred_at])
      change(Allocate)
    end

    read :for_case do
      description("List one case's events in seq order.")
      argument(:agent_case_id, :uuid, allow_nil?: false)
      prepare(build(sort: [seq: :asc]))
      filter(expr(agent_case_id == ^arg(:agent_case_id)))
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

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)

      constraints(
        one_of: [
          :opened,
          :approved,
          :rejected,
          :cancelled,
          :abandoned,
          :retracted
        ]
      )
    end

    attribute :data, :map do
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
    belongs_to :agent_case, JidoClaw.Orchestration.AgentCase do
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
