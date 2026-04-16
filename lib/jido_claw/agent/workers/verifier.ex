defmodule JidoClaw.Agent.Workers.Verifier do
  use Jido.AI.Agent,
    name: "jido_claw_verifier",
    description: """
    Interactive verification agent combining code review with execution capabilities.
    Can read code, run commands (tests, builds, servers), and verify artifacts.
    End every evaluation with VERDICT: PASS or VERDICT: FAIL.
    """,
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.VerifyCertificate
    ],
    model: :fast,
    max_iterations: 20,
    streaming: false,
    tool_timeout_ms: 60_000
end
