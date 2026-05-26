defmodule JidoClaw.Agent.Workers.Coder do
  @moduledoc false
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_coder",
    description:
      "Full-capability coding agent. Reads, writes, edits files, runs commands, manages git, and searches code. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), `notes` for caveats, and `artifacts` (an object with optional `url`/`port`/`files` — use `{}` if none).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.EditFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitCommit,
      JidoClaw.Tools.ProjectInfo
    ],
    model: :fast,
    max_iterations: 25,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :off],
    output: %{
      schema:
        Zoi.object(%{
          status: Zoi.enum([:completed, :partial, :blocked]),
          summary: Zoi.string(),
          files_changed: Zoi.array(Zoi.string()),
          notes: Zoi.string(),
          artifacts:
            Zoi.object(
              %{
                url: Zoi.string() |> Zoi.optional(),
                port: Zoi.string() |> Zoi.optional(),
                files: Zoi.string() |> Zoi.optional()
              },
              unrecognized_keys: :preserve
            )
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
