defmodule JidoClaw.Tools.ScheduleTaskTest do
  @moduledoc """
  Coverage for the T2-5 `target` / `workflow` params on the
  `schedule_task` tool: strict target parsing (no silent fallback),
  skill-existence validation before scheduling, and that a valid
  workflow job persists with `target: :workflow` + `workflow_name`.

  Scheduling uses a 1-day interval so the started worker never ticks during
  the test (its first tick is ~1 day out, independent of wall-clock time).
  """
  # async: false — setup writes through the `Tenant.Manager` singleton
  # (`ensure_tenant/1`), an out-of-chain GenServer that needs the shared
  # sandbox; under owner-mode it raises DBConnection.OwnershipError.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tools.ScheduleTask

  @far_future "every 1d"

  # Item 9 (OH1-3): the outcome contract is REQUIRED at creation — every
  # persisting call carries the triple.
  @contract %{
    end_state: "the report file exists for today",
    check: "ls reports/ shows a file named after today's date",
    stop_bound: "after 2 failed attempts, report the failure and stop"
  }

  setup do
    tenant = seed_tenant("schedule-task")
    {:ok, _} = Manager.ensure_tenant(tenant)

    ctx = %{
      tool_context: %{tenant_id: tenant, actor: actor_for(tenant), project_dir: File.cwd!()}
    }

    {:ok, tenant: tenant, ctx: ctx}
  end

  defp with_contract(params), do: Map.merge(@contract, params)

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

    params =
      with_contract(%{
        id: id,
        task: "nightly explore",
        schedule: @far_future,
        target: "workflow",
        workflow: "explore_codebase"
      })

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
    params = with_contract(%{id: id, task: "say hi", schedule: @far_future, target: "agent"})

    assert {:ok, _result} = ScheduleTask.run(params, ctx)
    on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)

    {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
    assert row.target == :agent
    assert is_nil(row.workflow_name)
  end

  test "a 5-field but uncomputable cron errors and persists no row", %{tenant: tenant, ctx: ctx} do
    id = "bad-cron-#{System.unique_integer([:positive])}"
    # 5 fields (so it clears the field-count guard) but every field is out of
    # range — the rewired NextRun cron branch rejects it.
    params = %{id: id, task: "x", schedule: "99 99 99 99 99"}

    assert {:error, wire} = ScheduleTask.run(params, ctx)
    assert wire.message =~ "invalid cron expression"

    assert {:error, _} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
  end

  describe "timezone param" do
    test "a valid IANA timezone persists on the row", %{tenant: tenant, ctx: ctx} do
      id = "tz-job-#{System.unique_integer([:positive])}"

      params =
        with_contract(%{
          id: id,
          task: "morning",
          schedule: @far_future,
          timezone: "America/New_York"
        })

      assert {:ok, %{result: result}} = ScheduleTask.run(params, ctx)
      on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)
      assert result =~ "America/New_York"

      {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
      assert row.timezone == "America/New_York"
    end

    test "an invalid timezone errors before scheduling", %{ctx: ctx} do
      params = %{task: "x", schedule: @far_future, timezone: "Not/AZone"}

      assert {:error, wire} = ScheduleTask.run(params, ctx)
      assert wire.message =~ "Invalid timezone"
    end

    test "an omitted timezone defaults to Etc/UTC", %{tenant: tenant, ctx: ctx} do
      id = "tz-default-#{System.unique_integer([:positive])}"
      params = with_contract(%{id: id, task: "noop", schedule: @far_future})

      assert {:ok, _} = ScheduleTask.run(params, ctx)
      on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)

      {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
      assert row.timezone == "Etc/UTC"
    end
  end

  describe "outcome contract (item 9 — OH1-3, required at creation)" do
    test "a missing contract field errors and persists no row", %{tenant: tenant, ctx: ctx} do
      id = "no-contract-#{System.unique_integer([:positive])}"
      params = %{id: id, task: "daily digest", schedule: @far_future}

      assert {:error, wire} = ScheduleTask.run(params, ctx)
      assert wire.message =~ "end_state"
      assert {:error, _} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
    end

    test "check == end_state (case-insensitive) errors", %{ctx: ctx} do
      params =
        with_contract(%{
          task: "x",
          schedule: @far_future,
          end_state: "The digest is sent",
          check: "the digest is sent"
        })

      assert {:error, wire} = ScheduleTask.run(params, ctx)
      assert wire.message =~ "must differ"
    end

    test "an over-long field errors", %{ctx: ctx} do
      params =
        with_contract(%{
          task: "x",
          schedule: @far_future,
          stop_bound: String.duplicate("s", 501)
        })

      assert {:error, wire} = ScheduleTask.run(params, ctx)
      assert wire.message =~ "500"
    end

    test "a valid contract persists string-keyed under metadata", %{tenant: tenant, ctx: ctx} do
      id = "contract-#{System.unique_integer([:positive])}"
      params = with_contract(%{id: id, task: "daily digest", schedule: @far_future})

      assert {:ok, %{result: result}} = ScheduleTask.run(params, ctx)
      on_exit(fn -> _ = Scheduler.unschedule(tenant, id) end)
      assert result =~ "Outcome contract recorded"

      # The row is the source of truth (row-driven flow — the first live
      # worker hydrates through reconcile; that seam is pinned in
      # scheduler_idempotency_test.exs).
      {:ok, row} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))

      assert row.metadata["outcome_spec"] == %{
               "end_state" => @contract.end_state,
               "check" => @contract.check,
               "stop_bound" => @contract.stop_bound
             }
    end
  end
end
