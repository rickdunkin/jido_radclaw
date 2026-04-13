defmodule JidoClaw.Orchestration.ApprovalGate do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("approval_gates")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:create)
    define(:approve)
    define(:reject)
    define(:list_pending_for_run, action: :pending_for_run)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:step_name, :reason, :workflow_run_id, :requested_by_id])
      change(set_attribute(:status, :pending))
    end

    update :approve do
      accept([])
      argument(:approver_id, :uuid, allow_nil?: false)
      argument(:comment, :string)
      change(set_attribute(:status, :approved))
      change(set_attribute(:approver_id, arg(:approver_id)))
      change(set_attribute(:comment, arg(:comment)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    update :reject do
      accept([])
      argument(:approver_id, :uuid, allow_nil?: false)
      argument(:comment, :string)
      change(set_attribute(:status, :rejected))
      change(set_attribute(:approver_id, arg(:approver_id)))
      change(set_attribute(:comment, arg(:comment)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    read :pending_for_run do
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      filter(expr(workflow_run_id == ^arg(:workflow_run_id) and status == :pending))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :step_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :approved, :rejected])
    end

    attribute :approver_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :requested_by_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :comment, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to(:requester, JidoClaw.Accounts.User,
      source_attribute: :requested_by_id,
      define_attribute?: false,
      attribute_writable?: true
    )

    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(false)
      public?(true)
    end
  end
end
