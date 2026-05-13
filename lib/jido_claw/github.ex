defmodule JidoClaw.GitHub do
  @moduledoc """
  Ash Domain for the GitHub integration subsystem.

  Hosts resources for GitHub-driven workflows such as issue analysis, with
  the agents and webhook pipeline under `JidoClaw.GitHub.*` producing the
  data the resources here persist. Exposed via AshAdmin for operator
  inspection.
  """

  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.GitHub.IssueAnalysis)
  end
end
