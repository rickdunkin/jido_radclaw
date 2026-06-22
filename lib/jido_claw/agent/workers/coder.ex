defmodule JidoClaw.Agent.Workers.Coder do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_coder",
    description:
      "Full-capability coding agent. Reads, writes, edits files, runs commands, manages git, and searches code. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `notes` for caveats.",
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
          notes: Zoi.string(),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
