defmodule JidoClaw.Orchestration.Reactors.ProjectRegistrationTest do
  @moduledoc """
  End-to-end proof of the first `Ash.Reactor` under the event-log envelope:

    * the success path records the full `run_started -> step_* -> run_completed`
      timeline and projects to `:completed`;
    * a forced mid-run failure rolls the earlier saga step back — the keystone:
      `step_failed -> step_undone -> run_failed`, with the project row actually
      gone and no workspace persisted;
    * a missing required input fails before the middleware runs, yet the
      runner's `finalize` backstop still fails the run (no `:pending` strand);
    * a missing `:tenant`/`:actor` opt returns the pre-run envelope with no run.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.ProjectRegistration
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Projects.Project
  alias JidoClaw.Workspaces.Workspace

  setup do
    tenant = seed_tenant("reactor")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "happy path" do
    test "registers project + workspace and records the full timeline", ctx do
      %{tenant: tenant, actor: actor} = ctx
      inputs = valid_inputs()

      assert {:ok, %Workspace{} = workspace, run} =
               ReactorRunner.run(ProjectRegistration, inputs, tenant: tenant, actor: actor)

      assert run.status == :completed

      # The two rows exist and are FK-linked.
      {:ok, project} = Project.get_by_github_full_name(inputs.github_full_name, actor: actor)
      assert workspace.project_id == project.id

      events = events_for(run, ctx)
      kinds = Enum.map(events, & &1.kind)

      assert [:run_started | _] = kinds
      assert [:run_completed | _] = Enum.reverse(kinds)
      # Dedup: the runner auto-wires ReactorMiddleware, but ProjectRegistration
      # already declares it — the membership check prevents a double wire.
      assert Enum.count(kinds, &(&1 == :run_started)) == 1
      assert :step_completed in step_kinds(events, ":register_project")
      assert :step_completed in step_kinds(events, ":register_workspace")

      # The materialized column equals the seq-ordered fold.
      assert Projection.project_status(events) == :completed
    end
  end

  describe "forced failure -> compensation/undo (keystone)" do
    test "workspace failure rolls the project back; logs step_undone then run_failed", ctx do
      %{tenant: tenant, actor: actor} = ctx
      # `Workspace.name` is `allow_nil? false`, so a nil reaches the step (Reactor
      # validates input presence, not value) and the create changeset errors
      # *after* the project step has already succeeded.
      inputs = %{valid_inputs() | workspace_name: nil}

      assert {:error, _reason, run} =
               ReactorRunner.run(ProjectRegistration, inputs, tenant: tenant, actor: actor)

      assert run.status == :failed

      # Project row rolled back via the saga undo; no workspace persisted.
      {:ok, projects} = Project.read(actor: actor)
      refute Enum.any?(projects, &(&1.github_full_name == inputs.github_full_name))
      assert {:ok, []} = Workspace.list(tenant: tenant, actor: actor)

      events = events_for(run, ctx)
      kinds = Enum.map(events, & &1.kind)

      assert :run_started in kinds
      assert :step_failed in step_kinds(events, ":register_workspace")
      assert :step_undone in step_kinds(events, ":register_project")
      assert [:run_failed | _] = Enum.reverse(kinds)
    end
  end

  describe "missing required input -> no :pending strand (backstop)" do
    test "validation fails before init/1; finalize still fails the run", ctx do
      %{tenant: tenant, actor: actor} = ctx
      inputs = Map.delete(valid_inputs(), :github_full_name)

      assert {:error, _reason, run} =
               ReactorRunner.run(ProjectRegistration, inputs, tenant: tenant, actor: actor)

      # init/1 never fired (no run_started), but the runner's finalize backstop
      # appended the terminal — the run is not stranded in :pending.
      assert run.status == :failed
      assert Enum.map(events_for(run, ctx), & &1.kind) == [:run_failed]
    end
  end

  describe "missing required opt -> pre-run envelope" do
    test "omitting :tenant/:actor returns {:error, :missing_required_opt, nil}", ctx do
      assert {:error, :missing_required_opt, nil} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(), [])

      assert {:error, :missing_required_opt, nil} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(), actor: ctx.actor)
    end
  end

  defp valid_inputs do
    uniq = System.unique_integer([:positive])

    %{
      github_full_name: "o/r-#{uniq}",
      project_name: "proj-#{uniq}",
      workspace_name: "ws-#{uniq}",
      workspace_path: "/tmp/ws-#{uniq}"
    }
  end

  defp events_for(run, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    events
  end

  # Event kinds whose payload names the given reactor node — the value the
  # middleware records via `inspect(node.name)`.
  defp step_kinds(events, node_name) do
    events
    |> Enum.filter(&(&1.payload["step"] == node_name))
    |> Enum.map(& &1.kind)
  end
end
