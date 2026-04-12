defmodule JidoClaw.Accounts.User do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("users")
    repo(JidoClaw.Repo)
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(JidoClaw.Accounts.Token)
      signing_secret(JidoClaw.Secrets)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)
    end

    add_ons do
      confirmation :confirm_new_user do
        monitor_fields([:email])
        confirm_on_create?(true)
        confirm_on_update?(false)
        confirmed_at_field(:confirmed_at)
        require_interaction?(true)
        auto_confirm_actions([:sign_in_with_magic_link, :reset_password_with_token])
        sender(JidoClaw.Accounts.User.Senders.SendNewUserConfirmationEmail)
      end

      log_out_everywhere do
        apply_on_password_change?(true)
      end
    end

    strategies do
      password :password do
        identity_field(:email)
        hashed_password_field(:hashed_password)
        hash_provider(AshAuthentication.BcryptProvider)
        confirmation_required?(true)

        resettable do
          sender(JidoClaw.Accounts.User.Senders.SendPasswordResetEmail)
          request_password_reset_action_name(:request_password_reset_token)
          password_reset_action_name(:reset_password_with_token)
        end
      end

      magic_link :magic_link do
        identity_field(:email)
        require_interaction?(true)
        sender(JidoClaw.Accounts.User.Senders.SendMagicLinkEmail)
        request_action_name(:request_magic_link)
        sign_in_action_name(:sign_in_with_magic_link)
      end

      api_key :api_key do
        api_key_relationship(:valid_api_keys)
      end
    end
  end

  actions do
    defaults([:read])

    read :get_by_subject do
      description("Get a user by their AshAuthentication subject claim.")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    read :sign_in_with_password do
      description("Sign in a user with their email and password.")
      get?(true)
      argument(:email, :ci_string, allow_nil?: false)
      argument(:password, :string, allow_nil?: false, sensitive?: true)
      prepare(AshAuthentication.Strategy.Password.SignInPreparation)
    end

    read :sign_in_with_token do
      description("Sign in a user with a short-lived sign-in token.")
      get?(true)
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      prepare(AshAuthentication.Strategy.Password.SignInWithTokenPreparation)
    end

    read :get_by_email do
      description("Look up a user by their email address.")
      get?(true)
      argument(:email, :ci_string, allow_nil?: false)
      filter(expr(email == ^arg(:email)))
    end

    read :sign_in_with_magic_link do
      description("Sign in a user with a magic link token.")
      get?(true)
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      prepare(AshAuthentication.Strategy.MagicLink.SignInPreparation)
    end

    read :sign_in_with_api_key do
      description("Sign in a user with an API key.")
      get?(true)
      argument(:api_key, :string, allow_nil?: false, sensitive?: true)
      prepare(AshAuthentication.Strategy.ApiKey.SignInPreparation)
    end

    create :register_with_password do
      description("Register a new user with email and password.")
      accept([:email])
      argument(:password, :string, allow_nil?: false, sensitive?: true)
      argument(:password_confirmation, :string, allow_nil?: false, sensitive?: true)
      validate(AshAuthentication.Strategy.Password.PasswordConfirmationValidation)
      change(AshAuthentication.Strategy.Password.HashPasswordChange)
      change(AshAuthentication.GenerateTokenChange)
    end

    update :change_password do
      description("Change a user's password.")
      require_atomic?(false)
      argument(:current_password, :string, allow_nil?: false, sensitive?: true)
      argument(:password, :string, allow_nil?: false, sensitive?: true)
      argument(:password_confirmation, :string, allow_nil?: false, sensitive?: true)
      validate(AshAuthentication.Strategy.Password.PasswordConfirmationValidation)
      validate(AshAuthentication.Strategy.Password.CurrentPasswordValidation)
      change(AshAuthentication.Strategy.Password.HashPasswordChange)
    end

    action :request_password_reset_token do
      description("Send a user a password reset token.")
      argument(:email, :ci_string, allow_nil?: false)
      run(AshAuthentication.Strategy.Password.RequestPasswordReset)
    end

    update :reset_password_with_token do
      description("Reset a user's password with a token.")
      require_atomic?(false)
      argument(:reset_token, :string, allow_nil?: false, sensitive?: true)
      argument(:password, :string, allow_nil?: false, sensitive?: true)
      argument(:password_confirmation, :string, allow_nil?: false, sensitive?: true)
      validate(AshAuthentication.Strategy.Password.ResetTokenValidation)
      validate(AshAuthentication.Strategy.Password.PasswordConfirmationValidation)
      change(AshAuthentication.Strategy.Password.HashPasswordChange)
      change(AshAuthentication.GenerateTokenChange)
    end

    action :request_magic_link do
      description("Send a user a magic link.")
      argument(:email, :ci_string, allow_nil?: false)
      run(AshAuthentication.Strategy.MagicLink.Request)
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(JidoClaw.Accounts.Checks.RegistrationAllowed)
    end

    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :hashed_password, :string do
      allow_nil?(true)
      sensitive?(true)
      public?(false)
    end

    attribute :confirmed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    has_many :valid_api_keys, JidoClaw.Accounts.ApiKey do
      filter(expr(valid == true))
    end
  end

  identities do
    identity(:unique_email, [:email])
  end
end
