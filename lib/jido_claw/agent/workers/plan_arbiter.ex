defmodule JidoClaw.Agent.Workers.PlanArbiter do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_plan_arbiter",
    description:
      "Adjudicates several competing implementation plans and their critiques for a " <>
        "multi-plan run: steelmans each plan, then writes a decision memo naming one verdict " <>
        "(adopt/hybrid/revise_first), the selection, and the tie-break rung that decided it. " <>
        "Your summary IS the decision-memo artifact — it must name the verdict, the " <>
        "selection, and (for hybrid/revise_first) the graft seams or blocking critiques, " <>
        "self-contained. Read-only; a selector, not a critic.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      # AR-9: the decision-memo shape. `verdict` + `tie_break_rung` are STRING
      # enums (persisted-adjacent — `Envelope.normalize/1` would store an atom
      # enum as `":adopt"`); `status`/`confidence` stay atom enums (never
      # persisted). NO `overall` (the lens-nil mapper rule — see `PlanDrafter`).
      # The `decision-memo` stage artifact is the summary fallback, so the memo
      # summary must be self-contained.
      schema:
        Zoi.object(%{
          summary: Zoi.string(),
          status: Zoi.enum([:completed, :partial, :blocked]),
          confidence: Zoi.enum([:low, :medium, :high]),
          assessments:
            Zoi.array(
              Zoi.object(
                %{
                  lens: Zoi.string(),
                  steelman: Zoi.string(),
                  strengths: Zoi.string(),
                  blockers: Zoi.string()
                },
                coerce: true
              )
            ),
          # The exact ladder tokens from the `tie_break` doctrine slice — the
          # prose and the schema name the same rungs.
          tie_break_rung:
            Zoi.enum(["correctness", "grounding", "simpler-first", "validation-rollback", "cost"]),
          selection: Zoi.string(),
          verdict: Zoi.enum(["adopt", "hybrid", "revise_first"]),
          # "none" for adopt; the graft seams / blocking critiques otherwise.
          revision_directive: Zoi.string(),
          signals: Zoi.optional(Zoi.array(Zoi.string())),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
