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

  Contract 3: `Scheduler.load_persistent_jobs/2` rehydrates `:mfa` from
  the persisted `mfa_module`/`mfa_function`/`mfa_args` columns so a
  reloaded system job ticks under its original MFA.
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

  describe "Contract 1: worker auto-disable persists disabled_at" do
    test "3 failures auto-disable a job and persist disabled_at" do
      tenant = seed_tenant("disable")
      {:ok, _} = Manager.ensure_tenant(tenant)

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
      {:ok, _} = Manager.ensure_tenant(tenant)

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

  describe "Contract 3: reload restores MFA from Postgres" do
    test "system_job reloaded from Postgres ticks under its persisted MFA" do
      tenant = seed_tenant("reload_mfa")
      {:ok, _} = Manager.ensure_tenant(tenant)

      {:ok, _job} =
        Job.upsert(
          %{
            job_id: "reload-mfa-test",
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

      # The reload path is the ONLY way the Worker gets MFA here.
      # No explicit mfa: in Scheduler.schedule/2.
      assert {:ok, 1} = Scheduler.load_persistent_jobs(tenant, ".")

      on_exit(fn -> _ = Scheduler.unschedule(tenant, "reload-mfa-test") end)

      # (1) Worker state carries the reloaded MFA.
      state = Cron.Worker.get_state(tenant, "reload-mfa-test")
      assert state.mfa == {JidoClaw.Cron.TestSupport, :always_fail, []}

      # (2) Triggering a tick actually invokes always_fail/0 (not a
      # rescued MatchError from nil MFA). Both shapes produce
      # {:error, _} so we check the exact reason.
      Cron.Worker.trigger(tenant, "reload-mfa-test")

      eventually(fn ->
        state = Cron.Worker.get_state(tenant, "reload-mfa-test")
        state.last_result == {:error, :forced}
      end)
    end
  end

  defp eventually(fun, deadline_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
