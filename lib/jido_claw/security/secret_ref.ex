defmodule JidoClaw.Security.SecretRef do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Security,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("secret_refs")
    repo(JidoClaw.Repo)
  end

  cloak do
    vault(JidoClaw.Security.Vault)
    attributes([:encrypted_value])
  end

  code_interface do
    define(:create)
    define(:update)
    define(:get_by_name, action: :by_name)
    define(:list_by_category, action: :by_category)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :category, :encrypted_value, :user_id])
    end

    update :update do
      primary?(true)
      accept([:encrypted_value])
    end

    read :by_name do
      argument(:name, :string, allow_nil?: false)
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(name == ^arg(:name) and user_id == ^arg(:user_id)))
    end

    read :by_category do
      argument(:category, :string, allow_nil?: false)
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(category == ^arg(:category) and user_id == ^arg(:user_id)))
    end
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :category, :string do
      allow_nil?(false)
      public?(true)
      default("general")
    end

    attribute :encrypted_value, :binary do
      allow_nil?(false)
      sensitive?(true)
      public?(false)
    end

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to(:user, JidoClaw.Accounts.User,
      define_attribute?: false,
      attribute_writable?: true
    )
  end

  identities do
    identity(:unique_name_per_user, [:name, :user_id])
  end
end
