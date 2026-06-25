defmodule JidoClaw.Orchestration.Gate.Kinds do
  @moduledoc """
  The single source of the gate-kind vocabulary.

  Shared by the gate DSL's `kind` enum (`JidoClaw.Orchestration.Gate.Dsl`)
  and the `AgentCase.kind` `one_of` constraint, so the two can never drift.

  All three kinds have live producers: `:irreversible_write` (the safety gate
  on the system path, `JidoClaw.Orchestration.Reactors.SafetyGate`), `:plan`
  (the composer's plan-approval gate, `JidoClaw.Orchestration.Reactors.PlanGate`),
  and `:tool_call` (the per-tool-call approval flow,
  `JidoClaw.Orchestration.ToolApprovals`).
  """

  @kinds [:tool_call, :plan, :irreversible_write]

  @doc "Every legal gate kind."
  @spec all() :: [atom()]
  def all, do: @kinds
end
