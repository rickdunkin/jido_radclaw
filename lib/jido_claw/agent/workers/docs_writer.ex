defmodule JidoClaw.Agent.Workers.DocsWriter do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_docs_writer",
    description:
      "Writes documentation, module docs, function specs, and inline comments. Reads existing code and writes updated files. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `kinds` (one or more of `moduledoc`/`typespec`/`readme`/`guide`/`inline_comment`/`other`).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema:
        Zoi.object(%{
          status: Zoi.enum([:completed, :partial, :blocked]),
          summary: Zoi.string(),
          files_changed: Zoi.array(Zoi.string()),
          kinds:
            Zoi.array(
              Zoi.enum(
                moduledoc: "moduledoc",
                typespec: "typespec",
                readme: "readme",
                guide: "guide",
                inline_comment: "inline_comment",
                other: "other"
              )
            ),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
