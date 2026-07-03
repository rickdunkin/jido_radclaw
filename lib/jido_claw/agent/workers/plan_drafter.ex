defmodule JidoClaw.Agent.Workers.PlanDrafter do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_plan_drafter",
    description:
      "Drafts ONE competing implementation plan under the bias named in its stage task, for a " <>
        "multi-plan run. Your summary IS the plan — make it a complete, self-contained " <>
        "implementation plan. You are one of several parallel drafters; a separate arbiter " <>
        "selects across the competing plans, and a separate planner finalizes — never emit " <>
        "plan-ready; only emit scope-shift when the task or wave context explicitly asks for it.",
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
      # AR-9: deliberately LEAN — no `findings` and, load-bearing, no `overall`
      # (a lens-nil stage whose typed output carried `overall` would trip
      # `DefaultMapper`'s `{:reviewer_without_lens, _}` wave failure). Zoi drops
      # unknown keys, so the `plan:<lens>` stage artifact ALWAYS resolves via the
      # summary fallback (`result.result`) — the summary IS the plan.
      schema:
        Zoi.object(%{
          summary: Zoi.string(),
          # Required (Zoi default) — a blocked lens drafter is refused at the
          # mapper (`refuse_blocked_producer/2`) and route-fails the wave loudly,
          # like the finalizer planner.
          status: Zoi.enum([:completed, :partial, :blocked]),
          confidence: Zoi.enum([:low, :medium, :high]),
          # `scope-shift` self-report only (matched against the stage's
          # `publishes` strings) — a lens stage never earns a completion signal.
          signals: Zoi.optional(Zoi.array(Zoi.string())),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
