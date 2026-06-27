defmodule JidoClaw.Agent.Workers.Researcher do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_researcher",
    description:
      "Explores and analyzes codebase structure, dependencies, and patterns, and researches the web (discover with search_web, read with browse_web). Read-only access for deep codebase and web investigation. Return a structured result with a top-line `summary`, a `status` (`completed`/`partial`/`blocked` — emit `blocked` when you cannot draft a usable plan), an overall `confidence` (`low`/`medium`/`high` — your confidence in the research as a whole, NOT a per-claim tag), a list of `findings` (each with a `topic`, a `detail`, `references` — file paths or symbols, plus the source URL for any web-sourced claim — and a per-finding `confidence` of `likely` when you verified the finding (read the code, observed the behavior, or have an authoritative source) or `unsure` when it rests on inference or a single unconfirmed source), and `signals` — the signals your stage publishes (`plan-ready` when the plan is drafted, plus `scope-shift` if the request outgrew its premises).",
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
          # AR-4 P1: REQUIRED `status` (Zoi keys are required by default), matching
          # the already-required `status` on `coder_result/0`/`fixer_result/0`/
          # `builder_result/0`. A blocked `planner` (a researcher) reporting
          # `status: :blocked` is refused at the mapper
          # (`DefaultMapper.refuse_blocked_producer/2`) and route-fails the wave
          # instead of fabricating a `plan` from `summary` + advancing the
          # implementer on the injected `plan-ready`. Required (not optional) closes
          # that hole at the schema layer; `on_validation_error: :repair` recovers a
          # transient omission. A non-planner researcher reporting `completed` is
          # harmless. The hermetic composer stubs bypass Zoi, so they are unaffected.
          status: Zoi.enum([:completed, :partial, :blocked]),
          confidence: Zoi.enum([:low, :medium, :high]),
          findings:
            Zoi.array(
              Zoi.object(
                %{
                  topic: Zoi.string(),
                  detail: Zoi.string(),
                  references: Zoi.array(Zoi.string()),
                  # AR-7: the per-finding evidence tag — REQUIRED (Zoi default), the
                  # prose half being the `confidence_tagging` doctrine slice. A
                  # STRING enum (not atom), mirroring `OutputSchema.reviewer_verdict/0`
                  # (output_schema.ex:137-138): if findings are ever promoted to a
                  # stage `output:` artifact, `ComposerArtifact.Envelope.normalize/1`
                  # `inspect/1`s atom values into `":likely"` — strings round-trip
                  # clean. Orthogonal to the top-level `low|medium|high` confidence
                  # (overall, not per-claim); `on_validation_error: :repair` recovers
                  # a transient omission.
                  confidence: Zoi.enum(["likely", "unsure"])
                },
                coerce: true
              )
            ),
          # AR-4: the `planner` stage (a `researcher`) self-reports `plan-ready` /
          # `scope-shift` through this list (`DefaultMapper.explicit_signals/1`
          # matches it against the stage's `publishes` strings). Optional — a
          # transient omission of the loop-INJECTED `plan-ready` falls back to
          # injection, and the field is backward-compatible for a non-planner
          # researcher. `Zoi.optional` in the map form mirrors `artifacts/0`.
          signals: Zoi.optional(Zoi.array(Zoi.string())),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
