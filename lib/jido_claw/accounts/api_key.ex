defmodule JidoClaw.Accounts.ApiKey do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("api_keys")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      argument(:user_id, :uuid, allow_nil?: false)
      change(manage_relationship(:user_id, :user, type: :append_and_remove))

      change(
        {AshAuthentication.Strategy.ApiKey.GenerateApiKey, prefix: :jidoclaw, hash: :api_key_hash}
      )
    end

    update :revoke do
      description("Revoke an API key by setting revoked_at.")
      require_atomic?(false)
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
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
    uuid_primary_key(:id)

    attribute :api_key_hash, :binary do
      allow_nil?(false)
      sensitive?(true)
      public?(false)
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :user, JidoClaw.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end

  calculations do
    calculate(
      :valid,
      :boolean,
      expr(is_nil(revoked_at) and (is_nil(expires_at) or expires_at > now()))
    )
  end

  identities do
    identity(:unique_api_key_hash, [:api_key_hash])
  end
end
