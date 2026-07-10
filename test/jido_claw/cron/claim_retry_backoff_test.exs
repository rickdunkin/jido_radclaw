defmodule JidoClaw.Cron.ClaimRetryBackoffTest do
  @moduledoc """
  Capped exponential backoff for failed durable fire claims.

  A dead database used to be polled at a flat 1s per worker; claim failures
  now back off exponentially (1s → 30s cap) while the armed window is
  retained. The counter tracks only consecutive claim FAILURES — any
  non-error tick outcome resets it — and follower leadership polling keeps
  its flat cadence (a capped backoff there would add up to 30s of dispatch
  latency after a leadership handoff; pinned by the existing
  `worker_leader_gate_test.exs` retained-window test).
  """
  use JidoClaw.TenantCase, async: false

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
      send(Application.fetch_env!(:jido_claw, :claim_backoff_test_pid), {:runner_ran, state})
      :ok
    end
  end

  setup do
    tenant = seed_tenant("cron-claim-backoff")
    {:ok, _} = Manager.ensure_tenant(tenant)

    prev_runner = Application.fetch_env(:jido_claw, :cron_workflow_runner)
    Application.put_env(:jido_claw, :cron_workflow_runner, CapturingRunner)
    Application.put_env(:jido_claw, :claim_backoff_test_pid, self())

    on_exit(fn ->
      case prev_runner do
        {:ok, value} -> Application.put_env(:jido_claw, :cron_workflow_runner, value)
        :error -> Application.delete_env(:jido_claw, :cron_workflow_runner)
      end

      Application.delete_env(:jido_claw, :claim_backoff_test_pid)
    end)

    {:ok, tenant: tenant}
  end

  test "claim_retry_delay/1 grows exponentially and caps at 30s" do
    assert Cron.Worker.claim_retry_delay(0) == 1_000
    assert Cron.Worker.claim_retry_delay(1) == 2_000
    assert Cron.Worker.claim_retry_delay(2) == 4_000
    assert Cron.Worker.claim_retry_delay(4) == 16_000
    assert Cron.Worker.claim_retry_delay(5) == 30_000
    assert Cron.Worker.claim_retry_delay(20) == 30_000
    # min(attempt, 20) is the Integer.pow overflow guard.
    assert Cron.Worker.claim_retry_delay(1_000) == 30_000
  end

  test "a failed durable claim increments the counter and retains the window", ctx do
    actor = actor_for(ctx.tenant)
    job_id = "claim-fail-#{System.unique_integer([:positive])}"

    {:ok, job} =
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

    # Destroy the durable row: every claim now fails (NotFound) through the
    # transient-claim-failure lane, without breaking the SQL sandbox.
    {:ok, row} = Job.by_job_id(job_id, tenant: ctx.tenant, actor: actor)
    :ok = Job.remove(row, tenant: ctx.tenant, actor: actor)

    send(pid, {:tick, window})

    assert %{status: :active, next_run: ^window, fire_claim_attempts: 1} =
             Cron.Worker.get_state(ctx.tenant, job_id)

    send(pid, {:tick, window})

    assert %{status: :active, next_run: ^window, fire_claim_attempts: 2} =
             Cron.Worker.get_state(ctx.tenant, job_id)

    refute_receive {:runner_ran, _state}, 100
  end

  test "a claimed outcome resets the claim-retry counter", ctx do
    job_id = "claim-reset-#{System.unique_integer([:positive])}"

    {:ok, ^job_id, pid} =
      Scheduler.schedule(ctx.tenant,
        id: job_id,
        mode: :system_job,
        schedule: @far_future,
        mfa: {Sink, :ping, [self()]}
      )

    on_exit(fn -> _ = Scheduler.unschedule(ctx.tenant, job_id) end)

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(ctx.tenant, job_id)

    # Model a prior claim-failure streak, then let a tick claim + dispatch.
    :sys.replace_state(pid, fn state -> %{state | fire_claim_attempts: 4} end)

    send(pid, {:tick, window})
    assert_receive :ping, 5_000

    assert %{fire_claim_attempts: 0} = Cron.Worker.get_state(ctx.tenant, job_id)
  end
end
