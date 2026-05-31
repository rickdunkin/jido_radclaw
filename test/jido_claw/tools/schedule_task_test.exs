defmodule JidoClaw.Tools.ScheduleTaskTest do
  @moduledoc """
  Coverage for the T2-5 `target` / `workflow` params on the
  `schedule_task` tool: strict target parsing (no silent fallback),
  skill-existence validation before scheduling, and that a valid
  workflow job persists with `target: :workflow` + `workflow_name`.

  Scheduling uses a far-future daily cron so the started worker never
  ticks during the test.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tools.ScheduleTask

  @far_future "0 4 * * *"

  setup do
    tenant = seed_tenant("schedule-task")
    {:ok, _} = Manager.ensure_tenant(tenant)

    ctx = %{
      tool_context: %{tenant_id: tenant, actor: actor_for(tenant), project_dir: File.cwd!()}
    }

    {:ok, tenant: tenant, ctx: ctx}
  end

  test "target: workflow without a workflow skill name errors before scheduling", %{ctx: ctx} do
    params = %{task: "nightly explore", schedule: @far_future, target: "workflow"}

    assert {:error, wire} = ScheduleTask.run(params, ctx)
    assert wire.message =~ "workflow"
  end

  test "target: workflow with an unknown skill errors", %{ctx: ctx} do
    params = %{
      task: "x",
      schedule: @far_future,
      target: "workflow",
      workflow: "no_such_skill"
    }

    assert {:error, wire} = ScheduleTask.run(params, ctx)
    assert wire.message =~ "not found"
  end

  test "an unrecognised target errors rather than silently scheduling an agent job", %{ctx: ctx} do
    params = %{task: "x", schedule: @far_future, target: "workflwo"}

    assert {:error, wire} = ScheduleTask.run(params, ctx)
    assert wire.message =~ "Invalid target"
  end

  test "valid target: workflow persists a row with target + workflow_name + input",
       %{tenant: tenant, ctx: ctx} do
    id = "wf-job-#{System.unique_integer([:positive])}"

    params = %{
      id: id,
      task: "nightly explore",
      schedule: @far_future,
      target: "workflow",
      workflow: "explore_codebase"
    }

    assert {:ok, %{result: result}} = ScheduleTask.run(params, ctx)
    on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)
    assert result =~ "workflow"

    {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
    assert row.target == :workflow
    assert row.workflow_name == "explore_codebase"
    assert row.workflow_input == %{"context" => "nightly explore"}
  end

  test "legacy target: agent persists an agent row unchanged", %{tenant: tenant, ctx: ctx} do
    id = "agent-job-#{System.unique_integer([:positive])}"
    params = %{id: id, task: "say hi", schedule: @far_future, target: "agent"}

    assert {:ok, _result} = ScheduleTask.run(params, ctx)
    on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)

    {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
    assert row.target == :agent
    assert is_nil(row.workflow_name)
  end
end
