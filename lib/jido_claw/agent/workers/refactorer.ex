defmodule JidoClaw.Agent.Workers.Refactorer do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_refactorer",
    description:
      "Refactors code for improved structure, readability, and performance. Full tool access for comprehensive codebase restructuring. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `improvements` (bullets of what got better — structure, readability, perf, etc.).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.EditFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitCommit,
      JidoClaw.Tools.ProjectInfo
    ],
    model: :fast,
    max_iterations: 25,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema:
        Zoi.object(%{
          status: Zoi.enum([:completed, :partial, :blocked]),
          summary: Zoi.string(),
          files_changed: Zoi.array(Zoi.string()),
          improvements: Zoi.array(Zoi.string()),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
