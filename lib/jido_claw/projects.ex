defmodule JidoClaw.Projects do
  @moduledoc """
  Ash Domain for the Projects subsystem.

  Hosts the `Project` resource that represents a working directory or
  repository tracked by JidoClaw. Surfaced in AshAdmin to allow operators
  to view and manage projects through the web UI.
  """

  use Ash.Domain, otp_app: :jido_claw, extensions: [AshAdmin.Domain, AshGraphql.Domain]

  admin do
    show?(true)
  end

  # Read-only GraphQL queries (argus P1) — no mutations by design; writes
  # stay on the existing surfaces (REPL, MCP, LiveView, AshAdmin).
  graphql do
    queries do
      get(JidoClaw.Projects.Project, :project, :read)
      list(JidoClaw.Projects.Project, :projects, :alphabetical)
    end
  end

  resources do
    resource(JidoClaw.Projects.Project)
  end
end
