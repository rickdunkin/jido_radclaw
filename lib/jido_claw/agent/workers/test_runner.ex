defmodule JidoClaw.Agent.Workers.TestRunner do
  use Jido.AI.Agent,
    name: "jido_claw_test_runner",
    description:
      "Runs tests and reports results. Read-only access to files with command execution for running test suites.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000
end
