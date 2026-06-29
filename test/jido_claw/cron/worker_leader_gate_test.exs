defmodule JidoClaw.Cron.WorkerLeaderGateTest do
  @moduledoc """
  WS4 — the cron `:system_job` leader fire-gate (`Cron.Worker.leader_gated?/1`).

  The genuine needs-gating item from the singleton audit: `:system_job` ticks
  are the only jobs the always-on supervision tree replicates on every node, so
  under clustering they must fire on the leader only. This pins:

    * a `:system_job` scheduled tick is **swallowed + re-armed** off-leader
      (no fire, not disabled), and **fires** on-leader;
    * a manual `trigger/2` of a `:system_job` is **never** gated (operator
      override);
    * a user job (`target: :workflow`) **fires regardless** of leadership —
      the gate is scoped to `:system_job`, so single-node behavior and user
      cron stay byte-identical.

  Leadership is stubbed through the `:cluster_leader_module` seam, so no `:pg`
  scope is needed. `async: false`: toggles global app-env (the stub module +
  its result + the workflow-runner capture). `[[project_suite_flaky_tests]]`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.ClusterLeaderStub
  alias JidoClaw.Cron
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

  test "off-leader: a :system_job scheduled tick is swallowed and re-armed (not fired)", ctx do
    set_leader(false)
    {job_id, pid} = schedule_system_job(ctx.tenant)

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)
    send(pid, {:tick, window})

    refute_receive :ping, 300

    # Re-armed, not disabled: still active with an advanced next_run (the gate's
    # schedule_next/1 branch, NOT the stale-tick swallow which leaves next_run).
    %{status: :active, next_run: %DateTime{} = next} = Cron.Worker.get_state(ctx.tenant, job_id)
    assert DateTime.compare(next, window) == :gt
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

  test "off-leader: a user :workflow job fires (not gated)", ctx do
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

    assert_receive {:runner_ran, _state}, 5_000
  end
end
