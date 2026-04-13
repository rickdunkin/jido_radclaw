defmodule JidoClaw.Folio.Project do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Folio,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("folio_projects")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:create)
    define(:complete)
    define(:defer)
    define(:reactivate)
    define(:list_active, action: :active)
    define(:list_by_user, action: :by_user)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :outcome, :notes, :user_id])
      change(set_attribute(:status, :active))
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

    update :reactivate do
      accept([])
      change(set_attribute(:status, :active))
    end

    read :active do
      filter(expr(status == :active))
    end

    read :by_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :outcome, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :notes, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:active)
      constraints(one_of: [:active, :someday, :completed])
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

  relationships do
    belongs_to(:user, JidoClaw.Accounts.User,
      define_attribute?: false,
      attribute_writable?: true
    )

    has_many :actions, JidoClaw.Folio.Action do
      destination_attribute(:project_id)
    end
  end
end
