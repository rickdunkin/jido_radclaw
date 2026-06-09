defmodule JidoClaw.Gates.PlanGate do
  @moduledoc """
  The `:plan` gate — a human approval checkpoint on an agent's *plan* before
  it begins executing (the review-the-approach-not-each-step flow).

  Declared-but-unproduced: no reactor wires this kind yet. The plan-approval
  producer (plan presented → approved → batch execution, with stale-approval
  retraction on re-plan via `Cases.retract/2`) is future work; the kind ships
  now so the vocabulary, `AgentCase.kind` column, and approval surfaces are
  ready for it.
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
