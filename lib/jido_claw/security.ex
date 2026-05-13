defmodule JidoClaw.Security do
  @moduledoc """
  Ash Domain for the Security subsystem — secret references and vault metadata.

  Backs the `SecretRef` resource that lets the rest of the application refer
  to secrets by stable handles without leaking the underlying values. Actual
  secret material lives in `JidoClaw.Security.Vault`; this domain only stores
  references and lifecycle metadata.
  """

  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Security.SecretRef)
  end
end
