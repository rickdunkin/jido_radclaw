defmodule JidoClaw.Agent.Workers.Verifier do
  @moduledoc false
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_verifier",
    description: """
    Interactive verification agent combining code review with execution capabilities.
    Can read code, run commands (tests, builds, servers), and verify artifacts.
    Return a structured verdict (`pass`/`fail`), confidence (`low`/`medium`/`high`), and short reasoning.
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
    tool_timeout_ms: 60_000,
    compaction: [mode: :off],
    output: %{
      schema:
        Zoi.object(%{
          verdict: Zoi.enum([:pass, :fail]),
          confidence: Zoi.enum([:low, :medium, :high]),
          reasoning: Zoi.string()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
