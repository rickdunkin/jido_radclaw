defmodule JidoClaw.Agent.Workers.Reviewer do
  use Jido.AI.Agent,
    name: "jido_claw_reviewer",
    description:
      "Reviews code changes for bugs, style issues, and correctness. Read-only access with git diff capabilities.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000
end
