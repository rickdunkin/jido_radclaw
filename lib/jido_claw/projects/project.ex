defmodule JidoClaw.Projects.Project do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("projects")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:get_by_github_full_name, action: :read, get_by: [:github_full_name])
    define(:update, action: :update)
  end

  actions do
    create :create do
      accept([:name, :github_full_name, :default_branch, :settings])
    end

    read :read do
      primary?(true)
    end

    update :update do
      accept([:name, :default_branch, :settings])
    end

    destroy(:destroy)
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 255, trim?: true)
    end

    attribute :github_full_name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 3, max_length: 255, trim?: true)
    end

    attribute :default_branch, :string do
      allow_nil?(false)
      public?(true)
      default("main")
      constraints(min_length: 1, max_length: 255, trim?: true)
    end

    attribute :settings, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_github_full_name, [:github_full_name])
  end
end
