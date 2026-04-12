defmodule JidoClaw.Accounts do
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
