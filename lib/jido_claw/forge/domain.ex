defmodule JidoClaw.Forge.Domain do
  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Forge.Resources.Session)
    resource(JidoClaw.Forge.Resources.ExecSession)
    resource(JidoClaw.Forge.Resources.Checkpoint)
    resource(JidoClaw.Forge.Resources.Event)
  end
end
