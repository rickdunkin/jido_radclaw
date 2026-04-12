defmodule JidoClaw.Forge.Resources.Session do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("forge_sessions")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :runner_type, :runner_config, :spec, :metadata, :started_at])
    end

    create :start do
      accept([:name, :runner_type, :runner_config, :spec, :metadata, :started_at])

      upsert?(true)
      upsert_identity(:unique_name)

      upsert_fields([
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
      accept([])
      argument(:phase, :atom, allow_nil?: false)
      change(set_attribute(:phase, arg(:phase)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :mark_failed do
      accept([])
      argument(:error, :string)
      change(set_attribute(:phase, :failed))
      change(set_attribute(:last_error, arg(:error)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :complete do
      accept([])
      change(set_attribute(:phase, :completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :cancel do
      accept([])
      change(set_attribute(:phase, :cancelled))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :set_sandbox_id do
      accept([])
      argument(:sandbox_id, :string, allow_nil?: false)
      change(set_attribute(:sandbox_id, arg(:sandbox_id)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    read :list_active do
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
  end

  attributes do
    uuid_primary_key(:id)

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
    identity(:unique_name, [:name])
  end

  relationships do
    has_many(:exec_sessions, JidoClaw.Forge.Resources.ExecSession)
    has_many(:events, JidoClaw.Forge.Resources.Event)
    has_many(:checkpoints, JidoClaw.Forge.Resources.Checkpoint)
  end
end
