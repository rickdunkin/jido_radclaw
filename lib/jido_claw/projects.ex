defmodule JidoClaw.Projects do
  @moduledoc """
  Ash Domain for the Projects subsystem.

  Hosts the `Project` resource that represents a working directory or
  repository tracked by JidoClaw. Surfaced in AshAdmin to allow operators
  to view and manage projects through the web UI.
  """

  use Ash.Domain, otp_app: :jido_claw, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Projects.Project)
  end
end
