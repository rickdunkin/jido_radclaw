defmodule JidoClaw.Orchestration.WorkflowStep do
  @moduledoc """
  Per-step read model of a `WorkflowRun` — one row per logical (YAML-named)
  step, projected from the run's `step_*` `WorkflowEvent`s by
  `WorkflowEvent.Changes.Allocate`. The dashboard step view reads these rows;
  the append-only event log stays the source of truth.

  Like `WorkflowEvent`, deliberately does **not** use the `JidoClaw.Resource`
  macro — that macro always injects `bypass action(:by_id_global)`, which
  fails to compile for a resource with no `:by_id_global` action. Steps are
  only ever read run-scoped, so this is a plain `use Ash.Resource` plus the
  two non-bypass tenant policies.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  postgres do
    table("workflow_steps")
    repo(JidoClaw.Repo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:create)
    define(:start)
    define(:complete)
    define(:fail)
    define(:skip)
    define(:record_started)
    define(:record_completed)
    define(:record_failed)
    define(:for_run, args: [:workflow_run_id])
    define(:read, action: :read)
    define(:destroy, action: :destroy)
  end

  actions do
    defaults([:read, :destroy])

    read :for_run do
      description("List one run's steps in sequence order.")
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      prepare(build(sort: [sequence: :asc, name: :asc]))
      filter(expr(workflow_run_id == ^arg(:workflow_run_id)))
    end

    # -- Projection upserts (WorkflowEvent.Changes.Allocate only) ------------
    #
    # Dedicated, identity-keyed upserts rather than the user-facing
    # create/start/complete/fail: `:record_started` is best-effort, so a
    # completed/failed event may arrive with NO step row (these create it
    # directly), and a retried step re-entering `:record_started` must clear
    # the prior attempt's terminal fields (`start` doesn't). Identity-based
    # upsert means a retry can never hit a unique-violation.

    create :record_started do
      description("Projection upsert: a step (re-)started; clears prior-attempt fields.")
      upsert?(true)
      upsert_identity(:unique_step_per_run)
      accept([:name, :step_type, :sequence, :workflow_run_id, :started_at])
      change(set_attribute(:status, :running))
      change(set_attribute(:output, nil))
      change(set_attribute(:error, nil))
      change(set_attribute(:completed_at, nil))
    end

    create :record_completed do
      description("Projection upsert: a step completed (row created if started was missed).")
      upsert?(true)
      upsert_identity(:unique_step_per_run)
      accept([:name, :step_type, :sequence, :workflow_run_id, :output, :completed_at])
      change(set_attribute(:status, :completed))
      change(set_attribute(:error, nil))
    end

    create :record_failed do
      description("Projection upsert: a step failed (row created if started was missed).")
      upsert?(true)
      upsert_identity(:unique_step_per_run)
      accept([:name, :step_type, :sequence, :workflow_run_id, :error, :completed_at])
      change(set_attribute(:status, :failed))
    end

    create :create do
      description("Create a new pending step within a workflow run.")
      primary?(true)
      accept([:name, :step_type, :config, :sequence, :workflow_run_id])
      change(set_attribute(:status, :pending))
    end

    update :start do
      description("Transition a workflow step to running and stamp started_at.")
      primary?(true)
      accept([])
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :complete do
      description("Mark a workflow step completed and record its output.")
      accept([])
      argument(:output, :map)
      change(set_attribute(:status, :completed))
      change(set_attribute(:output, arg(:output)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :fail do
      description("Mark a workflow step failed and record the error.")
      accept([])
      argument(:error, :string)
      change(set_attribute(:status, :failed))
      change(set_attribute(:error, arg(:error)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :skip do
      description("Mark a workflow step as skipped.")
      accept([])
      change(set_attribute(:status, :skipped))
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

    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end

  identities do
    # Identity for the projection upserts — one row per logical (run, name)
    # step. Ash adds the multitenancy attribute to the upsert keys, matching
    # the tenant-prefixed unique index AshPostgres generates.
    identity(:unique_step_per_run, [:workflow_run_id, :name])
  end
end
