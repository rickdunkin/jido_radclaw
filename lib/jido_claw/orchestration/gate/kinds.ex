defmodule JidoClaw.Orchestration.Gate.Kinds do
  @moduledoc """
  The single source of the gate-kind vocabulary.

  Shared by the gate DSL's `kind` enum (`JidoClaw.Orchestration.Gate.Dsl`)
  and the `AgentCase.kind` `one_of` constraint, so the two can never drift.

  All four kinds have live producers: `:irreversible_write` (the safety gate
  on the system path, `JidoClaw.Orchestration.Reactors.SafetyGate`), `:plan`
  (the composer's plan-approval gate, `JidoClaw.Orchestration.Reactors.PlanGate`),
  `:tool_call` (the per-tool-call approval flow,
  `JidoClaw.Orchestration.ToolApprovals`), and `:review_stall` (the composer's
  stalled-fix-loop release decision, camus C1-4 — raised parent-bound and
  child-less by `JidoClaw.RouteComposer`'s stall park, decided through the
  kind-dispatched `Cases.decide/4` branch).

  ## Vocabulary notes (recorded decisions, next-ten #6)

  Adjacent vocabulary this list deliberately does NOT grow yet:

    * traycer TR3-2 `superseded` — a future *terminal* for a case overtaken by
      a newer one (argus's `:review` kind would join `@kinds` alongside it).
    * pad PD3-3 lineage badges — display-only decoration on surfaces, never a
      kind or status.
    * bosun BO2-6 retry vocabulary + attempt-cap escalation — reference-only;
      the shipped slice is the waived-findings debt ledger
      (`Cases.waived_findings_ledger/2`), not a retry state machine.
    * orca OQ-1, decided: severity stays descriptive (`info|warning|error`,
      findings-win conservatism intact); the release decision lives on the
      `:review_stall` gate as per-finding waive records, all-or-reject.
  """

  @kinds [:tool_call, :plan, :irreversible_write, :review_stall]

  @doc "Every legal gate kind."
  @spec all() :: [atom()]
  def all, do: @kinds
end
