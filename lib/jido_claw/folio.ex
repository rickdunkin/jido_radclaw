defmodule JidoClaw.Folio do
  @moduledoc """
  Ash Domain for the Folio subsystem — inbox items, actions, and projects.

  Folio captures incoming work (inbox items), the discrete actions taken on
  them, and the projects that group them together. This domain wires the
  underlying resources into AshAdmin for inspection and manual triage.
  """

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
