defmodule JidoClaw.Cron.SchedulerIdempotencyTest do
  @moduledoc """
  WS4a — the per-job reconcile primitives `JidoClaw.Cron.Owner` drives:

    * `schedule_persisted/2` is idempotent (a benign `{:already_started, _}` race
      is `:ok`, no duplicate worker);
    * `changed?/2` is `{:ok, false}` for an unchanged row, `{:ok, true}` for a
      config edit, and `{:error, _}` for an unbuildable row (so converge keeps
      the working worker);
    * `local_user_cron_workers/0` lists user workers and excludes `"system"`;
    * `trigger/2` reports `{:error, :not_found}` for an absent worker;
    * re-`upsert`ing a disabled `job_id` clears `disabled_at` (re-enable), so
      `for_tenant` surfaces it again.

  `async: false`: owns live cron workers in the shared registry, and setup
  asserts `{:ok, _} = Manager.ensure_tenant(...)` — the Tenant.Manager
  singleton writes the row (and boots the tenant runtime that
  `Scheduler.schedule` needs) from its own process, which errors under async
  owner mode and propagates to the match. Also touches the fixed shared
  `"system"` tenant.
  `[[project_suite_flaky_tests]]`: verify in isolation, not under `--seed 0`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Cron.Worker
  alias JidoClaw.Tenant.Manager

  setup do
    tenant = seed_tenant("sched-idem")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant}
  end

  defp upsert(tenant, attrs) do
    {:ok, row} =
      Job.upsert(
        Enum.into(attrs, %{task: "t", mode: :main, target: :agent}),
        tenant: tenant,
        actor: actor_for(tenant)
      )

    row
  end

  defp worker_alive?(tenant, id) do
    is_pid(GenServer.whereis({:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant, id}}}))
  end

  describe "schedule_persisted/2" do
    test "is idempotent — a second call does not duplicate the worker", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "x", schedule_kind: :every, schedule_value: "86400000"})
      on_exit(fn -> Scheduler.unschedule(tenant, "x") end)

      assert :ok = Scheduler.schedule_persisted(tenant, row)
      assert :ok = Scheduler.schedule_persisted(tenant, row)
      assert worker_alive?(tenant, "x")
    end

    test "skips an unbuildable row with {:error, _}", %{tenant: tenant} do
      # target: :mfa with a present-but-unknown module builds only at schedule time.
      row =
        upsert(tenant, %{
          job_id: "bad",
          schedule_kind: :every,
          schedule_value: "86400000",
          target: :mfa,
          mfa_module: "JidoClaw.Cron.NoSuchModule",
          mfa_function: "f"
        })

      assert {:error, _} = Scheduler.schedule_persisted(tenant, row)
      refute worker_alive?(tenant, "bad")
    end
  end

  describe "changed?/2" do
    test "false when unchanged, true after a schedule edit", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "c", schedule_kind: :every, schedule_value: "86400000"})
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "c") end)

      worker = Worker.get_state(tenant, "c")
      assert {:ok, false} = Scheduler.changed?(row, worker)

      edited = upsert(tenant, %{job_id: "c", schedule_kind: :every, schedule_value: "60000"})
      assert {:ok, true} = Scheduler.changed?(edited, worker)
    end

    test "{:error, _} for an unbuildable row (keeps the working worker)", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "k", schedule_kind: :every, schedule_value: "86400000"})
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "k") end)
      worker = Worker.get_state(tenant, "k")

      bogus =
        upsert(tenant, %{
          job_id: "k",
          schedule_kind: :every,
          schedule_value: "86400000",
          target: :mfa,
          mfa_module: "JidoClaw.Cron.NoSuchModule",
          mfa_function: "f"
        })

      assert {:error, _} = Scheduler.changed?(bogus, worker)
    end
  end

  describe "local_user_cron_workers/0 and trigger/2" do
    test "lists user workers, excludes system, and trigger reports :not_found", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "lu", schedule_kind: :every, schedule_value: "86400000"})
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "lu") end)

      {:ok, _} = Manager.ensure_tenant("system")
      sys_id = "sys-#{System.unique_integer([:positive])}"

      {:ok, ^sys_id, _} =
        Scheduler.schedule("system",
          id: sys_id,
          mode: :system_job,
          schedule: {:every, 86_400_000},
          mfa: {JidoClaw.Cron.TestSupport, :always_fail, []}
        )

      on_exit(fn -> Scheduler.unschedule("system", sys_id) end)

      workers = Scheduler.local_user_cron_workers()
      assert {tenant, "lu"} in workers
      refute Enum.any?(workers, fn {t, _id} -> t == "system" end)

      assert {:error, :not_found} = Scheduler.trigger(tenant, "ghost")
    end
  end

  describe "outcome contract hydration + reconcile (item 9 — OH1-3)" do
    @spec_wire %{
      "end_state" => "the digest email is sent",
      "check" => "the send API returned 200",
      "stop_bound" => "stop after 2 failed attempts"
    }

    test "schedule_persisted hydrates the normalized contract into worker state",
         %{tenant: tenant} do
      row =
        upsert(tenant, %{
          job_id: "oc",
          schedule_kind: :every,
          schedule_value: "86400000",
          metadata: %{"outcome_spec" => @spec_wire}
        })

      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "oc") end)

      assert Worker.get_state(tenant, "oc").outcome_spec == @spec_wire
    end

    test "a contract-less row hydrates nil (byte-identical dispatch)", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "ocn", schedule_kind: :every, schedule_value: "86400000"})
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "ocn") end)

      assert is_nil(Worker.get_state(tenant, "ocn").outcome_spec)
    end

    test "changed?/2: a contract edit restarts; an unchanged contract doesn't",
         %{tenant: tenant} do
      row =
        upsert(tenant, %{
          job_id: "occ",
          schedule_kind: :every,
          schedule_value: "86400000",
          metadata: %{"outcome_spec" => @spec_wire}
        })

      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "occ") end)
      worker = Worker.get_state(tenant, "occ")

      assert {:ok, false} = Scheduler.changed?(row, worker)

      edited =
        upsert(tenant, %{
          job_id: "occ",
          schedule_kind: :every,
          schedule_value: "86400000",
          metadata: %{"outcome_spec" => %{@spec_wire | "check" => "the message id was logged"}}
        })

      assert {:ok, true} = Scheduler.changed?(edited, worker)
    end
  end

  describe "re-enable on upsert" do
    test "re-upserting a disabled job_id clears disabled_at and re-surfaces it", %{tenant: tenant} do
      row = upsert(tenant, %{job_id: "re", schedule_kind: :every, schedule_value: "86400000"})
      {:ok, _} = Job.disable(row, tenant: tenant, actor: actor_for(tenant))

      {:ok, disabled} = Job.by_job_id("re", tenant: tenant, actor: actor_for(tenant))
      assert %DateTime{} = disabled.disabled_at

      reupserted =
        upsert(tenant, %{job_id: "re", schedule_kind: :every, schedule_value: "86400000"})

      assert is_nil(reupserted.disabled_at)

      {:ok, jobs} = Job.for_tenant(tenant: tenant, actor: actor_for(tenant))
      assert Enum.any?(jobs, &(&1.job_id == "re"))
    end
  end
end
