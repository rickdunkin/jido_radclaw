defmodule JidoClaw.Gates.ReviewStallGate do
  @moduledoc """
  The `:review_stall` gate (camus C1-4, next-ten #6) — the human release
  decision when a composer fix loop STOPPED (a stuck/oscillating finding or an
  exhausted re-review budget) while the deterministic verify authority holds a
  **green, certified** `clean:<verify-lens>`.

  Raised by `JidoClaw.RouteComposer`'s stall park: the composer parent stays
  `:running` (no `approval_requested` — an `:awaiting_approval` composer row is
  recovery's dangling-gate arm), the pending run-bound `AgentCase` is the
  durable park representation, and the decision flows through the
  kind-dispatched branch of `JidoClaw.Orchestration.Cases.decide/4`. Approve
  requires **every** surviving finding explicitly waived (key + severity +
  optional note — the BO2-6 debt-ledger records on the case's `:approved`
  timeline event; orca OQ-1 as decided) and completes the run
  `:route_done_with_findings`; anything less is refused
  (`{:error, :incomplete_waiver}`), and reject terminalizes `fix_failed` as
  today. The per-finding waive controls are surface-rendered from
  `details["findings"]`, not DSL fields. The hooks keep the `HumanGate` no-op
  defaults — the composer's terminalization is the must-happen work, never a
  best-effort hook.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:review_stall)
    title("Review stalled — decide the surviving findings")

    description(
      "The fix loop stopped with review findings still open, but the " <>
        "deterministic verify is green and certified. Waive every surviving " <>
        "finding to complete the run as done-with-findings (recorded as " <>
        "deferred debt), or reject to fail it as fix_failed."
    )

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
