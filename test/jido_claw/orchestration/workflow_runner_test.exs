defmodule JidoClaw.Orchestration.WorkflowRunnerTest do
  @moduledoc """
  Pins the `WorkflowRunner` — the first `WorkflowRun` producer — driven
  by a stubbed executor (`:cron_workflow_executor`) so the workflow
  drivers don't actually run:

    * success → row reaches `:completed` with a result; `:run_started` +
      `:run_completed` broadcast; the executor receives a shared
      `"cron:<job>:<run>"` workspace_id (in both the opt and scope);
    * executor error → row `:failed` with the error + `:run_failed`;
    * executor that *raises* → still `:failed`, never stranded `:running`;
    * unexpected executor return → still `:failed`, never stranded `:running`;
    * unknown skill → `{:error, _}` and no run row created.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowRunner

  defmodule StubExecutor do
    @moduledoc false
    def dispatch(_skill, _extra, _project_dir, opts) do
      send(
        Application.fetch_env!(:jido_claw, :workflow_runner_test_pid),
        {:executor_called, opts}
      )

      case Application.fetch_env!(:jido_claw, :workflow_runner_executor_response) do
        {:raise, message} -> raise message
        other -> other
      end
    end
  end

  setup do
    tenant = seed_tenant("wfrunner")

    previous = %{
      executor: Application.fetch_env(:jido_claw, :cron_workflow_executor),
      response: Application.fetch_env(:jido_claw, :workflow_runner_executor_response),
      test_pid: Application.fetch_env(:jido_claw, :workflow_runner_test_pid)
    }

    Application.put_env(:jido_claw, :cron_workflow_executor, StubExecutor)
    Application.put_env(:jido_claw, :workflow_runner_test_pid, self())

    on_exit(fn ->
      restore_env(:cron_workflow_executor, previous.executor)
      restore_env(:workflow_runner_executor_response, previous.response)
      restore_env(:workflow_runner_test_pid, previous.test_pid)
    end)

    RunPubSub.subscribe_all()
    {:ok, tenant: tenant}
  end

  test "success drives the run to :completed, broadcasts, and shares the cron workspace_id",
       %{tenant: tenant} do
    unique_id = "wfrun-#{System.unique_integer([:positive])}"

    Application.put_env(
      :jido_claw,
      :workflow_runner_executor_response,
      {:ok, [{"explore", "found things"}]}
    )

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{"context" => "go"}
    }

    assert :ok = WorkflowRunner.run(state)

    assert_receive {:executor_called, opts}
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    assert String.starts_with?(workspace_id, "cron:#{unique_id}:")
    scope = Keyword.fetch!(opts, :scope_context)
    assert scope.workspace_id == workspace_id

    assert_receive {:run_started, run_id, %{cron_job_id: ^unique_id, status: :running}}

    assert_receive {:run_completed, ^run_id,
                    %{cron_job_id: ^unique_id, status: :completed, result: result}}

    assert is_map(result)

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :completed
    assert is_map(run.result)
  end

  test "executor error drives the run to :failed and broadcasts run_failed",
       %{tenant: tenant} do
    unique_id = "wfrun-#{System.unique_integer([:positive])}"

    Application.put_env(
      :jido_claw,
      :workflow_runner_executor_response,
      {:error, "boom step failed"}
    )

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{}
    }

    assert {:error, "boom step failed"} = WorkflowRunner.run(state)

    assert_receive {:run_started, run_id, %{cron_job_id: ^unique_id}}
    assert_receive {:run_failed, ^run_id, %{cron_job_id: ^unique_id, error: "boom step failed"}}

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :failed
    assert run.error == "boom step failed"
  end

  test "executor that raises still drives the run to :failed (never stranded :running)",
       %{tenant: tenant} do
    unique_id = "wfrun-#{System.unique_integer([:positive])}"
    Application.put_env(:jido_claw, :workflow_runner_executor_response, {:raise, "kaboom"})

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{}
    }

    assert {:error, reason} = WorkflowRunner.run(state)
    assert reason =~ "kaboom"

    assert_receive {:run_started, run_id, _info}
    assert_receive {:run_failed, ^run_id, %{cron_job_id: ^unique_id}}

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :failed
  end

  test "unexpected executor return drives the run to :failed (never stranded :running)",
       %{tenant: tenant} do
    unique_id = "wfrun-#{System.unique_integer([:positive])}"
    Application.put_env(:jido_claw, :workflow_runner_executor_response, :ok)

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{}
    }

    assert {:error, reason} = WorkflowRunner.run(state)
    assert reason =~ "unexpected_executor_return"

    assert_receive {:run_started, run_id, _info}
    assert_receive {:run_failed, ^run_id, %{cron_job_id: ^unique_id, error: ^reason}}

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :failed
    assert run.error == reason
  end

  test "unknown skill returns an error and creates no run row", %{tenant: tenant} do
    unique_id = "wfrun-missing-#{System.unique_integer([:positive])}"

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "does_not_exist_skill",
      workflow_input: %{}
    }

    assert {:error, _reason} = WorkflowRunner.run(state)

    refute_received {:run_started, _id, _info}

    {:ok, runs} = WorkflowRun.list(tenant: tenant, actor: actor_for(tenant))
    refute Enum.any?(runs, fn run -> run.config["cron_job_id"] == unique_id end)
  end

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
end
