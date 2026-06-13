defmodule JidoClaw.Gates.ToolCallGate do
  @moduledoc """
  The `:tool_call` gate — a human approval checkpoint before the agent
  executes a sensitive tool invocation (shell command, network mutation,
  credential use).

  The producer is `JidoClaw.Orchestration.ToolApprovals`, driven by the
  wrapper-level policy `JidoClaw.Security.ToolApproval`: a require-listed (or
  param-pattern-triggered) tool call opens a **run-less** `AgentCase` (kind
  `:tool_call`) keyed by a `{tenant, session, tool, args}` fingerprint, and the
  tool returns a non-retryable `approval_pending` error the LLM relays to the
  operator. Approvals are single-use; rejections are deny-once. Operators decide
  through the same surfaces as workflow gates (REPL `/gates`, web `/approvals`),
  routed through `JidoClaw.Orchestration.Cases.decide/4`'s run-less branch.

  This module supplies only the operator-facing presentation
  (`title`/`description`/`fields`, surfaced in the inbox) and the default no-op
  `after_approved`/`after_rejected` hooks — there is no reactor and no run, so
  the hooks receive a `%GateContext{run: nil}`.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:tool_call)
    title("Approve tool call")
    description("The agent wants to execute a sensitive tool invocation.")

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
