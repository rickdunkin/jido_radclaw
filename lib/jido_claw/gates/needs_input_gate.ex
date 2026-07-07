defmodule JidoClaw.Gates.NeedsInputGate do
  @moduledoc """
  The `:needs_input` gate (item 7 PR-4, camus C1-1 sketch (e)) — an executor
  step's runner asked a question mid-run (a `:needs_input` iteration status)
  that only an operator can answer.

  The producer is `JidoClaw.Orchestration.NeedsInput`, driven by
  `JidoClaw.Skills.Steps.ForgeExecutor`: the STEP still errors (the run rides
  its existing failure lanes — no composer park; the full park is gated on an
  interactive-runner producer), and the pending case is the durable question
  record + the answer channel. The operator's ANSWER rides `decision_comment`
  (`/gates approve <id> <answer>` / the web answer box — deliberately no DSL
  fields); approve makes it claimable ONCE by the stage's next attempt within
  the producer's answer TTL (the ToolApprovals single-use model), where a
  vendor step injects it into the prompt. Reject records refusal (never
  consumed; a later ask opens a fresh case). A reused pending case keeps its
  ORIGINAL question — first-question-wins (retries may rephrase the same
  ask). The hooks keep the `HumanGate` no-op defaults (the ReviewStallGate
  posture): nothing resumes on decide; the next attempt claims lazily.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:needs_input)
    title("Agent needs input — answer to unblock the next attempt")

    description(
      "An executor step's agent asked a question it cannot proceed without. " <>
        "Approve with your answer (the decision comment IS the answer — " <>
        "single-use, consumed by the stage's next attempt), or reject to " <>
        "record that no answer will be given."
    )
  end
end
