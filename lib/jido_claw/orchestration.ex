defmodule JidoClaw.Orchestration do
  @moduledoc """
  Ash Domain for the Orchestration subsystem — workflow runs, events, steps,
  and human approval gates (`AgentCase`).

  Persists the state machine that coordinates multi-step agent workflows,
  including each `WorkflowRun`, its append-only `WorkflowEvent` log,
  `WorkflowStep` children, and any human `AgentCase` approval gates. Surfaced
  in AshAdmin so operators can audit and intervene in active runs.
  """

  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Orchestration.WorkflowRun)
    resource(JidoClaw.Orchestration.WorkflowEvent)
    resource(JidoClaw.Orchestration.WorkflowStep)
    resource(JidoClaw.Orchestration.AgentCase)
    resource(JidoClaw.Orchestration.AgentCaseEvent)
    resource(JidoClaw.Orchestration.ComposerArtifact)
  end
end
