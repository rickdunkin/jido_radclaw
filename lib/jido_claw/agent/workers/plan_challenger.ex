defmodule JidoClaw.Agent.Workers.PlanChallenger do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_plan_challenger",
    description:
      "Critiques ONE proposed implementation plan (critique-only): surfaces blockers, " <>
        "concerns, and strengths for a downstream arbiter to weigh. Your summary IS the " <>
        "critique artifact — self-contained. Never approves or picks a plan. Read-only.",
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
      # AR-9: the three critique lists ride the lean producer base. NO `overall`
      # (the lens-nil mapper rule — see `PlanDrafter`) and NO `findings` (the
      # fixer subscribes the bare `findings` family; a challenger critique must
      # never summon it). The `critique:<lens>` artifact is the summary fallback.
      schema:
        Zoi.object(%{
          summary: Zoi.string(),
          status: Zoi.enum([:completed, :partial, :blocked]),
          confidence: Zoi.enum([:low, :medium, :high]),
          blockers: Zoi.array(Zoi.string()),
          concerns: Zoi.array(Zoi.string()),
          strengths: Zoi.array(Zoi.string()),
          signals: Zoi.optional(Zoi.array(Zoi.string())),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
