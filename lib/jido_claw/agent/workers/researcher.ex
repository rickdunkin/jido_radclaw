defmodule JidoClaw.Agent.Workers.Researcher do
  @moduledoc false
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_researcher",
    description:
      "Explores and analyzes codebase structure, dependencies, and patterns. Read-only access for deep codebase investigation. Return a structured result with a top-line `summary`, `confidence` (`low`/`medium`/`high`), a list of `findings` (each with a `topic`, `detail`, and `references` — file paths or symbols), and `artifacts` (an object with optional `url`/`port`/`files` — use `{}` if none).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.ProjectInfo
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :off],
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
