defmodule JidoClaw.Orchestration.WorkflowRun do
  @moduledoc false
  use JidoClaw.Resource, domain: JidoClaw.Orchestration

  postgres do
    table("workflow_runs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :status])
      index([:tenant_id, :completed_at])
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
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Create a new workflow run in pending status.")
      primary?(true)
      accept([:name, :workflow_type, :config, :retry_of_id, :user_id, :project_id, :metadata])
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
      accept([:status, :started_at, :completed_at, :result, :error])
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
    has_many(:approval_gates, JidoClaw.Orchestration.ApprovalGate)
    has_many(:events, JidoClaw.Orchestration.WorkflowEvent)
  end
end
