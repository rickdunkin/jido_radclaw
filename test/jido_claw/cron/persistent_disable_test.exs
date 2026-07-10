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

  Contract 4: a one-shot `:at` row whose instant has already passed is
  skipped at reload — the worker disables itself in init WITHOUT firing
  (a missed one-shot must never fire at boot), persists `disabled_at`,
  and the row is excluded from the next reload. A still-future `:at`
  row arms normally. Uses the same `:cron_workflow_runner` app-env
  capture seam as `WorkerFireProvenanceTest` to refute boot-time fires.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  defmodule CapturingRunner do
    @moduledoc false
    @spec run(term()) :: :ok
    def run(state) do
      send(
        Application.fetch_env!(:jido_claw, :persistent_disable_test_pid),
        {:runner_ran, state}
      )

      :ok
    end
  end

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

      {:ok, job} =
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

      assert :ok = Scheduler.schedule_persisted(tenant, job)

      on_exit(fn -> _ = Scheduler.unschedule(tenant, "fail-test") end)

      for _ <- 1..3, do: Cron.Worker.trigger(tenant, "fail-test")

      row = wait_until_disabled("fail-test", tenant)
      assert %DateTime{} = row.disabled_at
      assert row.failure_count == 3
    end

    test "the consecutive failure streak survives worker restart and disables on failure 3" do
      tenant = seed_tenant("disable-restart")
      {:ok, _} = Manager.ensure_tenant(tenant)

      {:ok, job} =
        Job.upsert(
          %{
            job_id: "fail-restart",
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

      assert :ok = Scheduler.schedule_persisted(tenant, job)
      on_exit(fn -> _ = Scheduler.unschedule(tenant, "fail-restart") end)

      for _ <- 1..2, do: Cron.Worker.trigger(tenant, "fail-restart")

      eventually(fn ->
        match?(
          {:ok, %{failure_count: 2, disabled_at: nil}},
          Job.by_job_id("fail-restart", tenant: tenant, actor: actor_for(tenant))
        )
      end)

      assert :ok = Scheduler.unschedule(tenant, "fail-restart")

      {:ok, reloaded_job} =
        Job.by_job_id("fail-restart", tenant: tenant, actor: actor_for(tenant))

      assert :ok = Scheduler.schedule_persisted(tenant, reloaded_job)
      assert Cron.Worker.get_state(tenant, "fail-restart").failure_count == 2

      Cron.Worker.trigger(tenant, "fail-restart")
      row = wait_until_disabled("fail-restart", tenant)
      assert row.failure_count == 3
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

  describe "Contract 4: one-shot :at rows on scheduler reload" do
    setup do
      previous = Application.fetch_env(:jido_claw, :cron_workflow_runner)
      Application.put_env(:jido_claw, :cron_workflow_runner, CapturingRunner)
      Application.put_env(:jido_claw, :persistent_disable_test_pid, self())

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:jido_claw, :cron_workflow_runner, value)
          :error -> Application.delete_env(:jido_claw, :cron_workflow_runner)
        end

        Application.delete_env(:jido_claw, :persistent_disable_test_pid)
      end)

      :ok
    end

    test "an elapsed :at row is skipped and disabled at reload, never fired" do
      tenant = seed_tenant("at_elapsed")
      {:ok, _} = Manager.ensure_tenant(tenant)

      past = DateTime.add(DateTime.utc_now(), -3_600, :second)

      {:ok, _job} =
        Job.upsert(
          %{
            job_id: "at-elapsed",
            schedule_kind: :at,
            schedule_value: DateTime.to_iso8601(past),
            target: :workflow,
            workflow_name: "explore_codebase"
          },
          tenant: tenant,
          actor: actor_for(tenant)
        )

      # Count is 1: the worker DOES start, then self-disables in init —
      # the same idle-zombie semantics as a :cron config error.
      assert {:ok, 1} = Scheduler.load_persistent_jobs(tenant, ".")

      on_exit(fn -> _ = Scheduler.unschedule(tenant, "at-elapsed") end)

      # The elapsed one-shot never executed at boot.
      refute_receive {:runner_ran, _state}, 300

      state = Cron.Worker.get_state(tenant, "at-elapsed")
      assert state.status == :disabled
      assert state.next_run == nil

      # disabled_at persisted, so the next reload excludes the row.
      row = wait_until_disabled("at-elapsed", tenant)
      assert %DateTime{} = row.disabled_at

      assert {:ok, 0} = Scheduler.load_persistent_jobs(tenant, ".")
    end

    test "a still-future :at row arms normally at reload" do
      tenant = seed_tenant("at_future")
      {:ok, _} = Manager.ensure_tenant(tenant)

      # Comfortably future so slow CI can never cross the firing boundary;
      # truncated to :second because the ISO8601 string round-trip is the
      # worker's source of truth for next_run equality.
      dt =
        DateTime.utc_now()
        |> DateTime.add(86_400, :second)
        |> DateTime.truncate(:second)

      {:ok, _job} =
        Job.upsert(
          %{
            job_id: "at-future",
            schedule_kind: :at,
            schedule_value: DateTime.to_iso8601(dt),
            target: :workflow,
            workflow_name: "explore_codebase"
          },
          tenant: tenant,
          actor: actor_for(tenant)
        )

      assert {:ok, 1} = Scheduler.load_persistent_jobs(tenant, ".")

      on_exit(fn -> _ = Scheduler.unschedule(tenant, "at-future") end)

      assert %{status: :active, next_run: ^dt} = Cron.Worker.get_state(tenant, "at-future")

      refute_receive {:runner_ran, _state}, 300
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
