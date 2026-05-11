defmodule JidoClaw.Cron.PersistentDisableTest do
  @moduledoc """
  Pins the auto-disable + reload-skip contract for `Cron.Job` rows.

  Contract 1: a worker that fails 3 times consecutively persists
  `disabled_at` to the row via `Worker.persist_disabled/1`. Driven by
  `JidoClaw.Cron.TestSupport.always_fail/0` so we never touch the agent
  runtime.

  Contract 2: rows with `disabled_at` set are excluded by
  `Cron.Job.for_tenant`, so `Cron.Scheduler.load_persistent_jobs/2` does
  not bring up workers for them.

  These contracts are split because `Scheduler.build_persistent_opts/1`
  drops `mfa_module`/`mfa_function`/`mfa_args` — system jobs lose their
  MFA on reload, so a single-test "fail then reload" approach can't drive
  failure post-reload. Splitting sidesteps that.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler

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

  describe "Contract 1: worker auto-disable persists disabled_at" do
    test "3 failures auto-disable a job and persist disabled_at" do
      tenant = seed_tenant("disable")
      {:ok, _} = JidoClaw.Tenant.Manager.ensure_tenant(tenant)

      {:ok, _job} =
        Job.upsert(
          %{
            job_id: "fail-test",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :system_job,
            mfa_module: "JidoClaw.Cron.TestSupport",
            mfa_function: "always_fail",
            mfa_args: %{}
          },
          tenant: tenant,
          actor: actor_for(tenant)
        )

      {:ok, "fail-test", _pid} =
        Scheduler.schedule(tenant,
          id: "fail-test",
          mode: :system_job,
          schedule: {:every, 60_000},
          mfa: {JidoClaw.Cron.TestSupport, :always_fail, []}
        )

      on_exit(fn -> _ = Scheduler.unschedule(tenant, "fail-test") end)

      for _ <- 1..3, do: Cron.Worker.trigger(tenant, "fail-test")

      row = wait_until_disabled("fail-test", tenant)
      assert %DateTime{} = row.disabled_at
    end
  end

  describe "Contract 2: disabled rows are skipped by scheduler reload" do
    test "rows with disabled_at set are not loaded by scheduler reload" do
      tenant = seed_tenant("excluded")
      {:ok, _} = JidoClaw.Tenant.Manager.ensure_tenant(tenant)

      {:ok, job} =
        Job.upsert(
          %{
            job_id: "skip-me",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant,
          actor: actor_for(tenant)
        )

      {:ok, _} = Job.disable(job, tenant: tenant, actor: actor_for(tenant))

      {:ok, count} = Scheduler.load_persistent_jobs(tenant, ".")
      assert count == 0

      worker_via =
        {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant, "skip-me"}}}

      refute GenServer.whereis(worker_via)
    end
  end
end
