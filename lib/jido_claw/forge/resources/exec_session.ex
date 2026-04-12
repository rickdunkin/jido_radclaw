defmodule JidoClaw.Forge.Resources.ExecSession do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("forge_exec_sessions")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      primary?(true)
      accept([:sequence, :command, :session_id, :metadata])
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :complete do
      accept([])
      argument(:result_status, :atom, allow_nil?: false)
      argument(:output, :string)
      argument(:exit_code, :integer)
      change(set_attribute(:status, arg(:result_status)))
      change(set_attribute(:output, arg(:output)))
      change(set_attribute(:exit_code, arg(:exit_code)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :running, :completed, :failed, :cancelled])
    end

    attribute :command, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :exit_code, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :output, :string do
      allow_nil?(true)
      public?(false)
    end

    attribute :output_size_bytes, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :duration_ms, :integer do
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
    belongs_to :session, JidoClaw.Forge.Resources.Session do
      allow_nil?(false)
      public?(true)
    end
  end
end
