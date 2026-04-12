defmodule JidoClaw.Projects do
  use Ash.Domain, otp_app: :jido_claw, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Projects.Project)
  end
end
