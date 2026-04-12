defmodule JidoClaw.Folio.Action do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Folio,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("folio_actions")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :title,
        :notes,
        :context,
        :energy,
        :time_estimate,
        :due_date,
        :project_id,
        :user_id
      ])

      change(set_attribute(:status, :next))
    end

    update :complete do
      accept([])
      change(set_attribute(:status, :completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :defer do
      accept([])
      change(set_attribute(:status, :someday))
    end

    update :wait do
      accept([])
      argument(:waiting_for, :string)
      change(set_attribute(:status, :waiting))
      change(set_attribute(:waiting_for, arg(:waiting_for)))
    end

    read :next_actions do
      filter(expr(status == :next))
    end

    read :waiting do
      filter(expr(status == :waiting))
    end

    read :by_context do
      argument(:context, :string, allow_nil?: false)
      filter(expr(context == ^arg(:context) and status == :next))
    end

    read :by_project do
      argument(:project_id, :uuid, allow_nil?: false)
      filter(expr(project_id == ^arg(:project_id)))
    end

    read :by_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :notes, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :context, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :energy, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: [:low, :medium, :high])
    end

    attribute :time_estimate, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:next)
      constraints(one_of: [:next, :waiting, :someday, :completed])
    end

    attribute :waiting_for, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :due_date, :date do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end
end
