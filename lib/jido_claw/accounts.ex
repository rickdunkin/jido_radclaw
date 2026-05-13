defmodule JidoClaw.Accounts do
  @moduledoc """
  Ash Domain for user accounts, authentication tokens, and API keys.

  Aggregates the `User`, `Token`, and `ApiKey` resources that back the
  AshAuthentication-driven login, magic-link, and API-key flows. Exposed in
  AshAdmin so operators can manage credentials from the web admin UI.
  """

  use Ash.Domain, otp_app: :jido_claw, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Accounts.Token)
    resource(JidoClaw.Accounts.User)
    resource(JidoClaw.Accounts.ApiKey)
  end
end
