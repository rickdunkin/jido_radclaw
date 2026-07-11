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
    extensions: [AshAdmin.Domain, AshGraphql.Domain]

  admin do
    show?(true)
  end

  # Read-only GraphQL queries (argus P1) — runs only; steps/events/cases
  # arrive with slice 1 alongside their consumers. No mutations by design.
  graphql do
    queries do
      get(JidoClaw.Orchestration.WorkflowRun, :workflow_run, :read)
      list(JidoClaw.Orchestration.WorkflowRun, :recent_workflow_runs, :recent)
    end
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
