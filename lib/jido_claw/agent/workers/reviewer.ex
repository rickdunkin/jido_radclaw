defmodule JidoClaw.Agent.Workers.Reviewer do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_reviewer",
    description:
      "Reviews code changes for bugs, style issues, and correctness. Read-only access with git diff capabilities. Return a structured review (`overall`, short `summary`, an `action_needed` line, and a list of `findings`, each with `severity` info/warning/error, `confidence` likely/unsure, `location`, and `description`).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema: OutputSchema.reviewer_verdict(),
      retries: 1,
      on_validation_error: :repair
    }
end
