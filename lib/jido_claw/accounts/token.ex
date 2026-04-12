defmodule JidoClaw.Accounts.Token do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tokens")
    repo(JidoClaw.Repo)
  end

  token do
    domain(JidoClaw.Accounts)
  end

  actions do
    defaults([:read, :destroy])
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key?(true)
      allow_nil?(false)
      sensitive?(true)
      public?(true)
    end

    attribute :subject, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    attribute :purpose, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :extra_data, :map do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
