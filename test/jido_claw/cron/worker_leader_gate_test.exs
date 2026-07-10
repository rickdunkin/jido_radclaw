defmodule JidoClaw.Cron.WorkerLeaderGateTest do
  @moduledoc """
  WS4 — the cron `:system_job` leader fire-gate (`Cron.Worker.leader_gated?/1`).

  The genuine needs-gating item from the singleton audit: `:system_job` ticks
  are the only jobs the always-on supervision tree replicates on every node, so
  under clustering they must fire on the leader only. This pins:

    * a non-persisted `:system_job` scheduled boundary is consumed off-leader,
      so it cannot replay after that follower becomes leader;
    * a manual `trigger/2` of a `:system_job` is **never** gated (operator
      override);
    * a non-persisted user job also advances off-leader, while a persisted job
      may retain the exact window because its DB claim is the split-brain fence.

  Leadership is stubbed through the `:cluster_leader_module` seam, so no `:pg`
  scope is needed. `async: false`: toggles global app-env (the stub module +
  its result + the workflow-runner capture). `[[project_suite_flaky_tests]]`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.ClusterLeaderStub
  alias JidoClaw.Cron
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  # Natural first tick is ~1 day out; every tick here is driven explicitly.
  @far_future {:every, 86_400_000}

  defmodule Sink do
    @moduledoc false
    @spec ping(pid()) :: :ok
    def ping(pid) do
      send(pid, :ping)
      :ok
    end
  end

  defmodule CapturingRunner do
    @moduledoc false
    @spec run(term()) :: :ok
    def run(state) do
      send(Application.fetch_env!(:jido_claw, :leader_gate_test_pid), {:runner_ran, state})
      :ok
    end
  end

  setup do
    tenant = seed_tenant("cron-leader-gate")
    {:ok, _} = Manager.ensure_tenant(tenant)

    prev_module = Application.fetch_env(:jido_claw, :cluster_leader_module)
    prev_runner = Application.fetch_env(:jido_claw, :cron_workflow_runner)

    Application.put_env(:jido_claw, :cluster_leader_module, ClusterLeaderStub)
    Application.put_env(:jido_claw, :cron_workflow_runner, CapturingRunner)
    Application.put_env(:jido_claw, :leader_gate_test_pid, self())

    on_exit(fn ->
      restore(:cluster_leader_module, prev_module)
      restore(:cron_workflow_runner, prev_runner)
      Application.delete_env(:jido_claw, :leader_gate_test_pid)
      Application.delete_env(:jido_claw, :cluster_leader_stub_result)
    end)

    {:ok, tenant: tenant}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
  defp restore(key, :error), do: Application.delete_env(:jido_claw, key)

  defp set_leader(result),
    do: Application.put_env(:jido_claw, :cluster_leader_stub_result, result)

  defp schedule_system_job(tenant) do
    job_id = "sysjob-#{System.unique_integer([:positive])}"

    {:ok, ^job_id, pid} =
      Scheduler.schedule(tenant,
        id: job_id,
        mode: :system_job,
        schedule: @far_future,
        mfa: {Sink, :ping, [self()]}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, job_id) end)
    {job_id, pid}
  end

  test "a follower consumes a non-persisted system window instead of replaying it as leader",
       ctx do
    set_leader(false)
    {job_id, pid} = schedule_system_job(ctx.tenant)

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)
    send(pid, {:tick, window})

    refute_receive :ping, 300

    assert %{status: :active, next_run: %DateTime{} = next_window} =
             Cron.Worker.get_state(ctx.tenant, job_id)

    assert DateTime.compare(next_window, window) == :gt

    # Sequential handoff: the old follower is now leader, but the stale
    # boundary no longer matches its state and must not execute.
    set_leader(true)
    send(pid, {:tick, window})
    refute_receive :ping, 300

    send(pid, {:tick, next_window})
    assert_receive :ping, 5_000
  end

  test "on-leader: a :system_job scheduled tick fires", ctx do
    set_leader(true)
    {job_id, pid} = schedule_system_job(ctx.tenant)

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)
    send(pid, {:tick, window})

    assert_receive :ping, 5_000
  end

  test "manual trigger/2 of a :system_job is never gated (fires off-leader)", ctx do
    set_leader(false)
    {job_id, _pid} = schedule_system_job(ctx.tenant)

    Cron.Worker.trigger(ctx.tenant, job_id)

    assert_receive :ping, 5_000
  end

  test "off-leader: a non-persisted user job advances without firing", ctx do
    set_leader(false)
    job_id = "userjob-#{System.unique_integer([:positive])}"

    {:ok, ^job_id, pid} =
      Scheduler.schedule(ctx.tenant,
        id: job_id,
        target: :workflow,
        workflow_name: "explore_codebase",
        schedule: @far_future
      )

    on_exit(fn -> _ = Scheduler.unschedule(ctx.tenant, job_id) end)

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)
    send(pid, {:tick, window})

    refute_receive {:runner_ran, _state}, 300

    assert %{next_run: next_window} = Cron.Worker.get_state(ctx.tenant, job_id)
    assert DateTime.compare(next_window, window) == :gt
  end

  test "off-leader: a persisted job retains its DB-claimable window", ctx do
    set_leader(false)
    job_id = "persisted-userjob-#{System.unique_integer([:positive])}"
    actor = actor_for(ctx.tenant)

    assert {:ok, job} =
             Job.upsert(
               %{
                 job_id: job_id,
                 task: "audit",
                 target: :workflow,
                 workflow_name: "explore_codebase",
                 schedule_kind: :every,
                 schedule_value: "86400000",
                 mode: :main
               },
               tenant: ctx.tenant,
               actor: actor
             )

    assert :ok = Scheduler.schedule_persisted(ctx.tenant, job)
    on_exit(fn -> _ = Scheduler.unschedule(ctx.tenant, job_id) end)

    pid =
      GenServer.whereis({:via, Registry, {JidoClaw.TenantRegistry, {:cron, ctx.tenant, job_id}}})

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)
    send(pid, {:tick, window})

    refute_receive {:runner_ran, _state}, 300
    assert %{status: :active, next_run: ^window} = Cron.Worker.get_state(ctx.tenant, job_id)
  end
end
