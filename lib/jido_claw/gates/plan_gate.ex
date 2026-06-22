defmodule JidoClaw.Gates.PlanGate do
  @moduledoc """
  The `:plan` gate — a human approval checkpoint on an agent's *plan* before
  it begins executing (the review-the-approach-not-each-step flow).

  Wired by `JidoClaw.Orchestration.Reactors.PlanGate` (AR-2 §14 Phase 4): the
  composer dispatches a `{:gate, "plan"}` stage as that single-stage gate
  reactor, which `GateStep`s on this module — the case `kind` is sourced from
  the `kind(:plan)` DSL below. Approve resumes and emits `plan-approved`
  (releasing the held implementer); reject/abandon take the route terminal;
  stale-approval retraction on re-plan rides `Cases.retract/3`. The hooks keep
  the `HumanGate` no-op defaults — the composer's durable park/wake is the
  must-happen work, never a best-effort hook.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:plan)
    title("Approve plan")
    description("The agent proposes a plan and wants approval before executing it.")

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
