defmodule JidoClaw.Orchestration.WorkflowStep do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("workflow_steps")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :step_type, :config, :sequence, :workflow_run_id])
      change(set_attribute(:status, :pending))
    end

    update :start do
      accept([])
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :complete do
      accept([])
      argument(:output, :map)
      change(set_attribute(:status, :completed))
      change(set_attribute(:output, arg(:output)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :fail do
      accept([])
      argument(:error, :string)
      change(set_attribute(:status, :failed))
      change(set_attribute(:error, arg(:error)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :skip do
      accept([])
      change(set_attribute(:status, :skipped))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :step_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :running, :completed, :failed, :skipped])
    end

    attribute :config, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :output, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :error, :string do
      allow_nil?(true)
      public?(true)
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
    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(false)
      public?(true)
    end
  end
end
