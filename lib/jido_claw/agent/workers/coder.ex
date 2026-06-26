defmodule JidoClaw.Agent.Workers.Coder do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_coder",
    description:
      "Full-capability coding agent. Reads, writes, edits files, runs commands, manages git, and searches code. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), `notes` for caveats, and `signals` — the completion/domain signals your stage publishes (`code-written` when you implemented code, `tests-ready` when you authored the failing tests, plus `scope-shift` if the change outgrew the plan).",
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
      schema: OutputSchema.coder_result(),
      retries: 1,
      on_validation_error: :repair
    }
end
