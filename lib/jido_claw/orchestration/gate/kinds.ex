defmodule JidoClaw.Orchestration.Gate.Kinds do
  @moduledoc """
  The single source of the gate-kind vocabulary.

  Shared by the gate DSL's `kind` enum (`JidoClaw.Orchestration.Gate.Dsl`)
  and the `AgentCase.kind` `one_of` constraint, so the two can never drift.
  Only `:irreversible_write` has a live producer today; `:tool_call` and
  `:plan` are declared ahead of their producers (the tool-approval and
  plan-approval flows).
  """

  @kinds [:tool_call, :plan, :irreversible_write]

  @doc "Every legal gate kind."
  @spec all() :: [atom()]
  def all, do: @kinds
end
