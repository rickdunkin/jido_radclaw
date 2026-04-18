defmodule JidoClaw.Reasoning.Domain do
  use Ash.Domain,
    otp_app: :jido_claw

  resources do
    resource(JidoClaw.Reasoning.Resources.Outcome)
  end
end
