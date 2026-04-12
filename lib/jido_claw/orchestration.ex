defmodule JidoClaw.Orchestration do
  use Ash.Domain,
    otp_app: :jido_claw,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(JidoClaw.Orchestration.WorkflowRun)
    resource(JidoClaw.Orchestration.WorkflowStep)
    resource(JidoClaw.Orchestration.ApprovalGate)
  end
end
