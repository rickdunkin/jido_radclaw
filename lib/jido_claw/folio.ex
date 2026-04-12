defmodule JidoClaw.Folio do
  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Folio.InboxItem)
    resource(JidoClaw.Folio.Action)
    resource(JidoClaw.Folio.Project)
  end
end
