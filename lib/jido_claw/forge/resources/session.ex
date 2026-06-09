defmodule JidoClaw.Forge.Resources.Session do
  @moduledoc """
  Durable Forge session row.

  ## Global `:unique_name` identity

  The `:unique_name` identity is `all_tenants?: true` (and the `:start`
  action deliberately omits `tenant_id` from `accept`/`upsert_fields` —
  AshPostgres sets it from the `tenant:` option on insert, so a colliding
  upsert can never steal tenant ownership). The global index is **required**
  by `JidoClaw.Forge.Persistence.find_session_global/1`, which resolves a
  session by name with no tenant in hand (the Harness only knows the
  session_id).

  This is safe **only because `name` is globally unique by construction** —
  every name source is a freshly generated UUID (`Ecto.UUID.generate/0`):
  `JidoClaw.Memory.Consolidator.RunServer` mints `forge_session_id`, and
  `JidoClaw.Forge.wake/1` reuses an already-UUID name. There is no
  human/short-name caller. Same reasoning as the in-repo precedents
  `JidoClaw.Trace.Resources.TraceRun` (`unique_trace_id`) and
  `JidoClaw.Trace.Resources.TraceEvent` (`(trace_id, seq)`), both of which
  document global identities for globally-unique-by-construction keys.
  """
  use JidoClaw.Resource, domain: JidoClaw.Forge.Domain, global_actions: [:by_name_global]

  postgres do
    table("forge_sessions")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :workspace_id, :phase])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:start)
    define(:update_phase)
    define(:mark_failed)
    define(:complete)
    define(:cancel)
    define(:set_sandbox_id)
    define(:list_active)
    define(:by_name, action: :by_name, args: [:name], get?: true)
    define(:by_name_global, action: :by_name_global, args: [:name], get?: true)
    define(:read, action: :read)
    define(:destroy, action: :destroy)
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      description("Start or resume a Forge session, upserting by unique name.")
      primary?(true)
      accept([:name, :workspace_id, :runner_type, :runner_config, :spec, :metadata, :started_at])

      upsert?(true)
      upsert_identity(:unique_name)

      upsert_fields([
        :workspace_id,
        :runner_type,
        :runner_config,
        :spec,
        :started_at,
        :phase,
        :completed_at,
        :last_error,
        :execution_count,
        :last_activity_at
      ])

      change(set_attribute(:phase, :created))
      change(set_attribute(:completed_at, nil))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:execution_count, 0))
      change(set_attribute(:last_activity_at, nil))
    end

    update :update_phase do
      description("Transition a session to a new lifecycle phase.")
      primary?(true)
      accept([])
      argument(:phase, :atom, allow_nil?: false)
      change(set_attribute(:phase, arg(:phase)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :mark_failed do
      description("Mark a session failed and record the last error.")
      accept([])
      argument(:error, :string)
      change(set_attribute(:phase, :failed))
      change(set_attribute(:last_error, arg(:error)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :complete do
      description("Mark a session completed and stamp completed_at.")
      accept([])
      change(set_attribute(:phase, :completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :cancel do
      description("Cancel an in-flight session.")
      accept([])
      change(set_attribute(:phase, :cancelled))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :set_sandbox_id do
      description("Attach a sandbox identifier to a session.")
      accept([])
      argument(:sandbox_id, :string, allow_nil?: false)
      change(set_attribute(:sandbox_id, arg(:sandbox_id)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    read :list_active do
      description("List sessions in any non-terminal phase.")

      filter(
        expr(
          phase in [
            :created,
            :provisioning,
            :bootstrapping,
            :ready,
            :running,
            :needs_input,
            :resuming
          ]
        )
      )
    end

    read :by_name do
      get?(true)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end

    read :by_name_global do
      get?(true)
      multitenancy(:bypass)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :workspace_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :phase, :atom do
      allow_nil?(false)
      public?(true)
      default(:created)

      constraints(
        one_of: [
          :created,
          :provisioning,
          :bootstrapping,
          :ready,
          :running,
          :needs_input,
          :completed,
          :failed,
          :cancelled,
          :resuming
        ]
      )
    end

    attribute :runner_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :runner_config, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :spec, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :sandbox_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :execution_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :last_error, :string do
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

    attribute :last_activity_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_name, [:name], all_tenants?: true)
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :workspace, JidoClaw.Workspaces.Workspace do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    has_many(:exec_sessions, JidoClaw.Forge.Resources.ExecSession)
    has_many(:events, JidoClaw.Forge.Resources.Event)
    has_many(:checkpoints, JidoClaw.Forge.Resources.Checkpoint)
  end
end
