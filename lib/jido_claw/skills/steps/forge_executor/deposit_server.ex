defmodule JidoClaw.Skills.Steps.ForgeExecutor.DepositServer do
  @moduledoc """
  Static MCP server for the vendor-executor deposit lane (executor-seam PR-2).

  A single always-on server registered at app boot, reached through a per-step
  `JidoClaw.MCP.ScopedEndpoint` that mints a deposit-ref URL segment and
  stamps `:executor_deposit_ref` into `frame.assigns` (the consolidator
  server's exact shape). Internal server — deliberately NOT part of the
  served-surface golden, which enumerates `JidoClaw.MCPServer` only.
  """

  use Jido.MCP.Server,
    name: "jido_deposit",
    version: "1.0.0",
    publish: %{
      tools: [JidoClaw.Skills.Steps.ForgeExecutor.Tools.SubmitStructuredOutput]
    }
end
