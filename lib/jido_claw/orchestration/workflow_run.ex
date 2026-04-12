defmodule JidoClaw.Orchestration.WorkflowRun do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("workflow_runs")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :workflow_type, :config, :retry_of_id, :user_id, :project_id, :metadata])
      change(set_attribute(:status, :pending))
    end

    update :start do
      accept([])
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :await_approval do
      accept([])
      change(set_attribute(:status, :awaiting_approval))
    end

    update :resume do
      accept([])
      change(set_attribute(:status, :running))
    end

    update :complete do
      accept([])
      argument(:result, :map)
      change(set_attribute(:status, :completed))
      change(set_attribute(:result, arg(:result)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :fail do
      accept([])
      argument(:error, :string)
      change(set_attribute(:status, :failed))
      change(set_attribute(:error, arg(:error)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :cancel do
      accept([])
      change(set_attribute(:status, :cancelled))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    read :list_active do
      filter(expr(status in [:pending, :running, :awaiting_approval]))
    end

    read :by_project do
      argument(:project_id, :uuid, allow_nil?: false)
      filter(expr(project_id == ^arg(:project_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

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
        one_of: [:pending, :running, :awaiting_approval, :completed, :failed, :cancelled]
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
    has_many(:steps, JidoClaw.Orchestration.WorkflowStep)
    has_many(:approval_gates, JidoClaw.Orchestration.ApprovalGate)
  end
end
