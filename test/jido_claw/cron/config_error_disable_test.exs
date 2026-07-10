defmodule JidoClaw.Cron.ConfigErrorDisableTest do
  @moduledoc """
  A `:cron` schedule that `NextRun` cannot resolve — unknown timezone or
  invalid expression — is a permanent config error. The worker disables itself
  AND persists `disabled_at` (via `Worker.persist_disabled/1`), so
  `Cron.Job.for_tenant` excludes the bad row on the next boot (converges in one
  cycle rather than re-disabling every restart).

  The durable-claim misconfiguration (a non-persisted user job under
  clustering — `:durable_fire_claim_required`) is the same config-error
  class, but with no durable row to stamp: it is refused at init, and the
  defensive tick branch disables in memory only.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  defp wait_until_disabled(job_id, tenant, attempts \\ 50) do
    result =
      Enum.reduce_while(1..attempts, nil, fn _, _ ->
        case Job.by_job_id(job_id, tenant: tenant, actor: actor_for(tenant)) do
          {:ok, %{disabled_at: %DateTime{}} = row} ->
            {:halt, row}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    result || flunk("disabled_at never set within #{attempts * 20}ms")
  end

  setup do
    tenant = seed_tenant("cron-config-error")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant}
  end

  test "an unknown timezone disables the worker and persists disabled_at", %{tenant: tenant} do
    {:ok, job} =
      Job.upsert(
        %{
          job_id: "bad-tz",
          schedule_kind: :cron,
          schedule_value: "0 9 * * *",
          timezone: "Not/AZone",
          mode: :main,
          task: "noop"
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    assert :ok = Scheduler.schedule_persisted(tenant, job)

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "bad-tz") end)

    row = wait_until_disabled("bad-tz", tenant)
    assert %DateTime{} = row.disabled_at
  end

  test "an invalid cron expression disables the worker and persists disabled_at",
       %{tenant: tenant} do
    {:ok, job} =
      Job.upsert(
        %{
          job_id: "bad-expr",
          schedule_kind: :cron,
          schedule_value: "totally invalid",
          mode: :main,
          task: "noop"
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    assert :ok = Scheduler.schedule_persisted(tenant, job)

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "bad-expr") end)

    row = wait_until_disabled("bad-expr", tenant)
    assert %DateTime{} = row.disabled_at
  end

  describe "durable-claim misconfiguration (:durable_fire_claim_required)" do
    setup %{tenant: tenant} do
      prev_cluster = Application.fetch_env(:jido_claw, :cluster_enabled)
      prev_runner = Application.fetch_env(:jido_claw, :cron_workflow_runner)
      prev_leader = Application.fetch_env(:jido_claw, :cluster_leader_module)
      Application.put_env(:jido_claw, :cron_workflow_runner, CapturingRunner)
      Application.put_env(:jido_claw, :config_error_disable_test_pid, self())
      # The defensive-branch tick must reach the CLAIM (leader path); without
      # the stub, cluster_enabled=true + no :pg scope reads as follower.
      Application.put_env(:jido_claw, :cluster_leader_module, JidoClaw.ClusterLeaderStub)
      Application.put_env(:jido_claw, :cluster_leader_stub_result, true)

      on_exit(fn ->
        restore(:cluster_enabled, prev_cluster)
        restore(:cron_workflow_runner, prev_runner)
        restore(:cluster_leader_module, prev_leader)
        Application.delete_env(:jido_claw, :cluster_leader_stub_result)
        Application.delete_env(:jido_claw, :config_error_disable_test_pid)
      end)

      {:ok, tenant: tenant}
    end

    test "a non-persisted user job is refused at init under clustering", %{tenant: tenant} do
      Application.put_env(:jido_claw, :cluster_enabled, true)
      job_id = "unclaimable-#{System.unique_integer([:positive])}"

      {:ok, ^job_id, _pid} = schedule_user_job(tenant, job_id)

      assert %{status: :disabled, next_run: nil} = Cron.Worker.get_state(tenant, job_id)
    end

    test "a :system_job stays exempt from the init refusal", %{tenant: tenant} do
      Application.put_env(:jido_claw, :cluster_enabled, true)
      job_id = "sysjob-exempt-#{System.unique_integer([:positive])}"

      {:ok, ^job_id, _pid} =
        Scheduler.schedule(tenant,
          id: job_id,
          mode: :system_job,
          schedule: {:every, 86_400_000},
          mfa: {Kernel, :send, [self(), :never_sent_here]}
        )

      on_exit(fn -> _ = Scheduler.unschedule(tenant, job_id) end)

      assert %{status: :active, next_run: %DateTime{}} = Cron.Worker.get_state(tenant, job_id)
    end

    test "the defensive tick branch disables in memory without re-arming", %{tenant: tenant} do
      # Armed normally (cluster off at init), then the flag flips: the tick's
      # claim fails with the permanent :durable_fire_claim_required — the
      # worker must disable in memory, not retry the claim forever.
      job_id = "flag-flip-#{System.unique_integer([:positive])}"
      {:ok, ^job_id, pid} = schedule_user_job(tenant, job_id)

      assert %{status: :active, next_run: %DateTime{} = window} =
               Cron.Worker.get_state(tenant, job_id)

      Application.put_env(:jido_claw, :cluster_enabled, true)
      send(pid, {:tick, window})

      assert %{status: :disabled, next_run: nil, fire_claim_attempts: 0} =
               Cron.Worker.get_state(tenant, job_id)

      refute_receive {:runner_ran, _state}, 300
    end
  end

  defmodule CapturingRunner do
    @moduledoc false
    @spec run(term()) :: :ok
    def run(state) do
      send(
        Application.fetch_env!(:jido_claw, :config_error_disable_test_pid),
        {:runner_ran, state}
      )

      :ok
    end
  end

  defp schedule_user_job(tenant, job_id) do
    result =
      Scheduler.schedule(tenant,
        id: job_id,
        target: :workflow,
        workflow_name: "explore_codebase",
        schedule: {:every, 86_400_000}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, job_id) end)
    result
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
  defp restore(key, :error), do: Application.delete_env(:jido_claw, key)
end
