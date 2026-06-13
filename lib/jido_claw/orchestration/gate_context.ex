defmodule JidoClaw.Orchestration.GateContext do
  @moduledoc """
  The argument passed to a gate's `after_approved/1` / `after_rejected/1`
  notification hooks.

  Deliberately **decoupled from `Reactor.context()`**: the reject path builds
  no reactor context at all, and the approve path runs the hook *outside* the
  resume's reactor context (post-commit, best-effort — Decision 8). A small
  explicit struct gives both decision paths one stable hook contract carrying
  the durable run, the decided `AgentCase`, the decision, and the tenant/actor
  scope.
  """

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowRun

  @enforce_keys [:run, :agent_case, :tenant]
  defstruct [:run, :agent_case, :decision, :tenant, :actor]

  @typedoc """
  `run` is `nil` for a run-less tool-call gate (the conversation-axis
  approval); the workflow gate hooks carry the durable `%WorkflowRun{}`.
  """
  @type t :: %__MODULE__{
          run: WorkflowRun.t() | nil,
          agent_case: AgentCase.t(),
          decision: :approve | :reject | nil,
          tenant: String.t(),
          actor: term()
        }
end
