defmodule JidoClaw.Agent.Workers.Researcher do
  use Jido.AI.Agent,
    name: "jido_claw_researcher",
    description:
      "Explores and analyzes codebase structure, dependencies, and patterns. Read-only access for deep codebase investigation.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.ProjectInfo
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000
end
