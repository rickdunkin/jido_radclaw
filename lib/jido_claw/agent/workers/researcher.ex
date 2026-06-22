defmodule JidoClaw.Agent.Workers.Researcher do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_researcher",
    description:
      "Explores and analyzes codebase structure, dependencies, and patterns, and researches the web (discover with search_web, read with browse_web). Read-only access for deep codebase and web investigation. Return a structured result with a top-line `summary`, `confidence` (`low`/`medium`/`high`), and a list of `findings` (each with a `topic`, `detail`, and `references` — file paths or symbols).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.ProjectInfo,
      JidoClaw.Tools.BrowseWeb,
      JidoClaw.Tools.SearchWeb
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema:
        Zoi.object(%{
          summary: Zoi.string(),
          confidence: Zoi.enum([:low, :medium, :high]),
          findings:
            Zoi.array(
              Zoi.object(
                %{
                  topic: Zoi.string(),
                  detail: Zoi.string(),
                  references: Zoi.array(Zoi.string())
                },
                coerce: true
              )
            ),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
