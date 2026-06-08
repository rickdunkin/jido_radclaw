defmodule JidoClaw.Orchestration.Reactors.ProjectRegistration do
  @moduledoc """
  First `Ash.Reactor` workflow: a Project + Workspace registration saga.

  Registers a `JidoClaw.Projects.Project`, then a tenant-scoped
  `JidoClaw.Workspaces.Workspace` FK-linked to it. Both steps declare a
  durable `undo` via the resources' additive `:reactor_undo` destroy actions,
  so a downstream failure rolls the earlier row back through Reactor's saga
  undo — visible in the event log as `step_undone`.

  `tenant`/`actor` are inherited from the `Reactor.run/4` context that
  `JidoClaw.Orchestration.ReactorRunner` seeds (the Ash create-step reads
  `context[:tenant]`/`context[:actor]`), and each step's domain is inferred
  from its resource via `Ash.Resource.Info.domain/1`, so this cross-domain
  saga (Projects + Workspaces) needs no per-step plumbing.

  `JidoClaw.Orchestration.ReactorMiddleware` is the sole event producer for
  the run.
  """

  use Ash.Reactor

  middlewares do
    middleware(JidoClaw.Orchestration.ReactorMiddleware)
  end

  input(:github_full_name)
  input(:project_name)
  input(:workspace_name)
  input(:workspace_path)

  create :register_project, JidoClaw.Projects.Project, :create do
    inputs(%{name: input(:project_name), github_full_name: input(:github_full_name)})
    undo_action(:reactor_undo)
    undo(:always)
  end

  create :register_workspace, JidoClaw.Workspaces.Workspace, :register do
    inputs(%{
      name: input(:workspace_name),
      path: input(:workspace_path),
      project_id: result(:register_project, [:id])
    })

    undo_action(:reactor_undo)
    undo(:always)
  end

  return(:register_workspace)
end
