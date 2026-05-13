defmodule JidoClaw.Reasoning.Domain do
  @moduledoc false
  use Ash.Domain,
    otp_app: :jido_claw

  resources do
    resource(JidoClaw.Reasoning.Resources.Outcome)
  end
end
