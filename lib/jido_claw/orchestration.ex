defmodule JidoClaw.Orchestration do
  @moduledoc """
  Ash Domain for the Orchestration subsystem — workflow runs, steps, and approval gates.

  Persists the state machine that coordinates multi-step agent workflows,
  including each `WorkflowRun`, its `WorkflowStep` children, and any human
  `ApprovalGate` checkpoints. Surfaced in AshAdmin so operators can audit
  and intervene in active runs.
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
    resource(JidoClaw.Orchestration.ApprovalGate)
  end
end
