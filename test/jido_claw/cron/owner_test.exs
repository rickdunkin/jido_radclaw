defmodule JidoClaw.Cron.OwnerTest do
  @moduledoc """
  WS4a — the cluster-wide user-cron owner (`JidoClaw.Cron.Owner`).

  Single-BEAM coverage of the reconcile/notify/trigger contract, driving
  leadership through the `:cluster_leader_module` stub (no live `:pg`). The
  cross-BEAM `:peer` failover proof is WS6's
  `JidoClaw.Cluster.CronFailoverTest`.

  Pins:

    * leader loads every non-disabled row; reconcile is idempotent (no churn);
    * follower drops every user worker, but a `:system_job` worker survives;
    * prune on remove/disable; restart on config change; keep on invalid config;
    * `:enable` rotates the definition token, so reconcile REPLACES a
      still-alive auto-disabled worker with a fresh armed generation;
    * inactive-tenant prune; read-failure leaves workers (unknown ≠ empty);
    * the boot-race recovery (periodic re-check without a `leader_changed` event)
      and the telemetry-driven reconcile;
    * `notify_changed` converges on the leader and routes (not schedules) on a
      follower;
    * `trigger` reconciles-then-fires, and fails closed when desired state is
      unknown.

  `async: false`: toggles global app-env (the stub + its result) and owns live
  cron workers in the shared registry. `[[project_suite_flaky_tests]]`: verify
  in isolation, not under `--seed 0`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.ClusterLeaderStub
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Owner
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Cron.Worker
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tenants.Tenant

  # Far enough that the periodic tick never fires mid-test; every reconcile is
  # driven explicitly. The scheduled workers' own first tick is ~1 day out.
  @interval 3_600_000
  @day_ms "86400000"

  setup do
    tenant = seed_tenant("cron-owner")
    {:ok, _} = Manager.ensure_tenant(tenant)

    prev_module = Application.fetch_env(:jido_claw, :cluster_leader_module)
    Application.put_env(:jido_claw, :cluster_leader_module, ClusterLeaderStub)

    on_exit(fn ->
      restore(:cluster_leader_module, prev_module)
      Application.delete_env(:jido_claw, :cluster_leader_stub_result)
      Application.delete_env(:jido_claw, :cluster_leader_stub_node)
    end)

    {:ok, tenant: tenant}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
  defp restore(key, :error), do: Application.delete_env(:jido_claw, key)

  defp set_leader(result),
    do: Application.put_env(:jido_claw, :cluster_leader_stub_result, result)

  # Start the Owner with the test gate forced on (config disables it) and a
  # far-future periodic interval, plus any injected read seams.
  defp start_owner(opts \\ []) do
    start_supervised!({Owner, Keyword.merge([interval: @interval, enabled?: true], opts)})
  end

  defp seed_job(tenant, id, opts \\ []) do
    attrs =
      Enum.into(opts, %{
        job_id: id,
        task: "t",
        mode: :main,
        target: :agent,
        schedule_kind: :every,
        schedule_value: @day_ms
      })

    {:ok, _} = Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))
  end

  defp worker_pid(tenant, id) do
    GenServer.whereis({:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant, id}}})
  end

  defp worker_alive?(tenant, id), do: is_pid(worker_pid(tenant, id))

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

  # Copied from JidoClaw.Cron.PersistentDisableTest — poll the durable row
  # until the worker's auto-disable write lands, returning the disabled row.
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

  describe "leader reconcile" do
    test "loads every non-disabled row; reconcile is idempotent (no churn)", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "a")
      seed_job(tenant, "b")

      start_owner()
      :ok = Owner.reconcile()

      assert worker_alive?(tenant, "a")
      assert worker_alive?(tenant, "b")
      on_exit(fn -> for id <- ~w(a b), do: Scheduler.unschedule(tenant, id) end)

      pid_a = worker_pid(tenant, "a")

      # A second reconcile with no change must not restart (same pid).
      :ok = Owner.reconcile()
      assert worker_pid(tenant, "a") == pid_a
    end

    test "restart-on-change: a config edit restarts the worker with the new schedule",
         %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "c", schedule_kind: :every, schedule_value: @day_ms)
      start_owner()
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "c") end)

      pid1 = worker_pid(tenant, "c")
      assert is_pid(pid1)

      # Re-upsert the same id with a changed schedule.
      seed_job(tenant, "c", schedule_kind: :every, schedule_value: "60000")
      :ok = Owner.reconcile()

      pid2 = worker_pid(tenant, "c")
      assert is_pid(pid2)
      assert pid2 != pid1
      assert Worker.get_state(tenant, "c").schedule == {:every, 60_000}
    end

    test "enable after auto-disable replaces the still-alive disabled worker", %{tenant: tenant} do
      set_leader(true)

      seed_job(tenant, "en",
        target: :mfa,
        mfa_module: "JidoClaw.Cron.TestSupport",
        mfa_function: "always_fail"
      )

      start_owner()
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "en") end)

      pid1 = worker_pid(tenant, "en")
      assert is_pid(pid1)

      # Three consecutive manual-trigger failures auto-disable the row. No
      # reconcile in between: pruning would drop the worker and mask the
      # retained-worker window this test exists to pin.
      for _ <- 1..3, do: Worker.trigger(tenant, "en")
      row = wait_until_disabled("en", tenant)

      # The bug window: the worker survives its own auto-disable in place,
      # alive but inert.
      assert worker_pid(tenant, "en") == pid1
      assert Worker.get_state(tenant, "en").status == :disabled

      {:ok, enabled} = Job.enable(row, %{}, tenant: tenant, actor: actor_for(tenant))
      :ok = Owner.reconcile()

      # Re-armed by REPLACEMENT, never resumed in-place: enable rotated the
      # definition token, so `Scheduler.changed?/2` sees a new fingerprint and
      # reconcile swaps in a fresh worker hydrated from the enabled generation.
      pid2 = worker_pid(tenant, "en")
      assert is_pid(pid2)
      assert pid2 != pid1

      state = Worker.get_state(tenant, "en")
      assert state.status == :active
      assert %DateTime{} = state.next_run
      assert state.definition_token == enabled.definition_token
    end

    test "invalid-config keeps the running worker", %{tenant: tenant} do
      set_leader(true)
      # A valid :mfa row brings up a worker.
      seed_job(tenant, "m",
        target: :mfa,
        mfa_module: "JidoClaw.Cron.TestSupport",
        mfa_function: "always_fail"
      )

      start_owner()
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "m") end)

      pid1 = worker_pid(tenant, "m")
      assert is_pid(pid1)

      # Re-upsert the same id with a present-but-unknown module: the action
      # accepts it (resolve_module fails only at build time), so changed?/2
      # returns {:error, _} and the original worker is KEPT.
      seed_job(tenant, "m",
        target: :mfa,
        mfa_module: "JidoClaw.Cron.NoSuchModule",
        mfa_function: "always_fail"
      )

      :ok = Owner.reconcile()
      assert worker_pid(tenant, "m") == pid1
    end

    test "prunes a worker whose row was removed", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "keep")
      seed_job(tenant, "drop")
      start_owner()
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "keep") end)

      assert worker_alive?(tenant, "drop")

      {:ok, row} = Job.by_job_id("drop", tenant: tenant, actor: actor_for(tenant))
      :ok = Job.remove(row, tenant: tenant, actor: actor_for(tenant))
      :ok = Owner.reconcile()

      refute worker_alive?(tenant, "drop")
      assert worker_alive?(tenant, "keep")
    end

    test "prunes a worker whose row was disabled", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "d")
      start_owner()
      :ok = Owner.reconcile()
      assert worker_alive?(tenant, "d")

      {:ok, row} = Job.by_job_id("d", tenant: tenant, actor: actor_for(tenant))
      {:ok, _} = Job.disable(row, tenant: tenant, actor: actor_for(tenant))
      :ok = Owner.reconcile()

      refute worker_alive?(tenant, "d")
    end

    test "inactive-tenant prune: a suspended tenant's workers are pruned", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "s")
      start_owner()
      :ok = Owner.reconcile()
      assert worker_alive?(tenant, "s")

      {:ok, row} = Tenant.by_id(tenant)
      {:ok, _} = Tenant.suspend(row)
      :ok = Owner.reconcile()

      refute worker_alive?(tenant, "s")
    end
  end

  describe "follower reconcile" do
    test "drops every user worker; a :system_job worker survives", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "u")
      start_owner()
      :ok = Owner.reconcile()
      assert worker_alive?(tenant, "u")

      # A platform system_job worker under the reserved "system" tenant.
      {:ok, _} = Manager.ensure_tenant("system")
      sys_id = "sysjob-#{System.unique_integer([:positive])}"

      {:ok, ^sys_id, _} =
        Scheduler.schedule("system",
          id: sys_id,
          mode: :system_job,
          schedule: {:every, 86_400_000},
          mfa: {JidoClaw.Cron.TestSupport, :always_fail, []}
        )

      on_exit(fn -> Scheduler.unschedule("system", sys_id) end)

      set_leader(false)
      :ok = Owner.reconcile()

      refute worker_alive?(tenant, "u")
      assert worker_alive?("system", sys_id)
    end
  end

  describe "read-failure leaves workers (unknown desired ≠ empty)" do
    test "a per-tenant job-read error does not prune", %{tenant: tenant} do
      set_leader(true)
      # Bring up a worker directly so one is running independent of the Owner.
      seed_job(tenant, "r")
      {:ok, row} = Job.by_job_id("r", tenant: tenant, actor: actor_for(tenant))
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "r") end)
      assert worker_alive?(tenant, "r")

      # jobs_fun fails ⇒ desired set UNKNOWN ⇒ converge is never called ⇒ keep.
      start_owner(jobs_fun: fn _ -> {:error, :boom} end)
      :ok = Owner.reconcile()

      assert worker_alive?(tenant, "r")
    end

    test "a tenant-enumeration error touches nothing", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "r2")
      {:ok, row} = Job.by_job_id("r2", tenant: tenant, actor: actor_for(tenant))
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "r2") end)
      assert worker_alive?(tenant, "r2")

      start_owner(tenants_fun: fn -> {:error, :boom} end)
      :ok = Owner.reconcile()

      assert worker_alive?(tenant, "r2")
    end
  end

  describe "boot-race / no leader_changed event" do
    test "a leader that booted as a follower loads on a later reconcile", %{tenant: tenant} do
      seed_job(tenant, "late")

      # Boot as a follower: loads nothing.
      set_leader(false)
      start_owner()
      :ok = Owner.reconcile()
      refute worker_alive?(tenant, "late")

      # Becomes leader; the periodic re-check (simulated by an explicit reconcile)
      # recovers without any leader_changed event.
      set_leader(true)
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "late") end)

      assert worker_alive?(tenant, "late")
    end

    test "a leader_changed telemetry event drives a reconcile", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "tele")
      start_owner()
      on_exit(fn -> Scheduler.unschedule(tenant, "tele") end)

      :telemetry.execute(
        [:jido_claw, :cluster, :leader_changed],
        %{count: 1},
        %{leader: Node.self(), previous: nil, members: [Node.self()]}
      )

      eventually(fn -> worker_alive?(tenant, "tele") end)
    end
  end

  describe "notify_changed (single-node / leader-local sync)" do
    test "converges the tenant after an upsert and after a remove", %{tenant: tenant} do
      set_leader(true)
      start_owner()
      on_exit(fn -> Scheduler.unschedule(tenant, "n") end)

      seed_job(tenant, "n")
      :ok = Owner.notify_changed(tenant)
      assert worker_alive?(tenant, "n")

      {:ok, row} = Job.by_job_id("n", tenant: tenant, actor: actor_for(tenant))
      :ok = Job.remove(row, tenant: tenant, actor: actor_for(tenant))
      :ok = Owner.notify_changed(tenant)
      refute worker_alive?(tenant, "n")
    end

    test "a follower routes (does not schedule locally); a later leader reconcile backstops",
         %{tenant: tenant} do
      set_leader(false)
      start_owner()
      seed_job(tenant, "f")
      on_exit(fn -> Scheduler.unschedule(tenant, "f") end)

      # Follower: the cast is guarded (if leader?) on the handler side, so nothing
      # is scheduled locally.
      :ok = Owner.notify_changed(tenant)
      refute worker_alive?(tenant, "f")

      # The durable row + a later leader reconcile is the guarantee.
      set_leader(true)
      :ok = Owner.reconcile()
      assert worker_alive?(tenant, "f")
    end
  end

  describe "trigger (reconcile-then-fire / fail-closed)" do
    setup do
      prev_runner = Application.fetch_env(:jido_claw, :cron_workflow_runner)
      Application.put_env(:jido_claw, :cron_workflow_runner, __MODULE__.CapturingRunner)
      Application.put_env(:jido_claw, :cron_owner_test_pid, self())

      on_exit(fn ->
        restore(:cron_workflow_runner, prev_runner)
        Application.delete_env(:jido_claw, :cron_owner_test_pid)
      end)

      :ok
    end

    test "fires a job whose worker is not yet running (reconcile schedules it first)",
         %{tenant: tenant} do
      seed_job(tenant, "t1", target: :workflow, workflow_name: "explore_codebase")
      on_exit(fn -> Scheduler.unschedule(tenant, "t1") end)

      # Boot as a follower so no worker is scheduled at boot.
      set_leader(false)
      start_owner()
      :ok = Owner.reconcile()
      refute worker_alive?(tenant, "t1")

      # Trigger via the leader (Cluster.leader/0 points at the local Owner); the
      # trigger's own reconcile schedules the worker before firing it.
      set_leader(true)
      assert :ok = Owner.trigger(tenant, "t1")
      assert_receive {:ran, _state}, 2_000
      assert worker_alive?(tenant, "t1")
    end

    test "an absent job returns {:error, :not_found} and fires nothing", %{tenant: tenant} do
      set_leader(true)
      start_owner()
      :ok = Owner.reconcile()

      assert {:error, :not_found} = Owner.trigger(tenant, "ghost")
      refute_receive {:ran, _state}, 200
    end

    test "fails closed when the tenant-row read fails (no fire of a stale worker)",
         %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "t2", target: :workflow, workflow_name: "explore_codebase")
      # tenant_fun is only used by the trigger/notify path, so boot's default
      # tenants_fun/jobs_fun still schedule the worker.
      start_owner(tenant_fun: fn _ -> {:error, :boom} end)
      :ok = Owner.reconcile()
      on_exit(fn -> Scheduler.unschedule(tenant, "t2") end)
      assert worker_alive?(tenant, "t2")

      assert {:error, :desired_unknown} = Owner.trigger(tenant, "t2")
      refute_receive {:ran, _state}, 200
      # The stale worker is left alone (not fired, not dropped).
      assert worker_alive?(tenant, "t2")
    end

    test "fails closed when the job read fails (no fire of a stale worker)", %{tenant: tenant} do
      set_leader(true)
      seed_job(tenant, "t3", target: :workflow, workflow_name: "explore_codebase")
      {:ok, row} = Job.by_job_id("t3", tenant: tenant, actor: actor_for(tenant))

      # A failing jobs_fun makes boot/reconcile a no-op (desired unknown), so we
      # bring up the stale worker directly, then trigger.
      start_owner(jobs_fun: fn _ -> {:error, :boom} end)
      :ok = Owner.reconcile()
      :ok = Scheduler.schedule_persisted(tenant, row)
      on_exit(fn -> Scheduler.unschedule(tenant, "t3") end)

      assert {:error, :desired_unknown} = Owner.trigger(tenant, "t3")
      refute_receive {:ran, _state}, 200
      assert worker_alive?(tenant, "t3")
    end

    test "fails closed with {:error, :not_leader} when this node is no longer leader",
         %{tenant: tenant} do
      seed_job(tenant, "t4", target: :workflow, workflow_name: "explore_codebase")
      on_exit(fn -> Scheduler.unschedule(tenant, "t4") end)

      # leader/0 still points {Owner, node} at the local Owner (so trigger routes
      # here), but leader?/0 is false — the demotion race between routing and the
      # call landing. The handler must refuse to fire a job it no longer owns.
      set_leader(false)
      start_owner()
      :ok = Owner.reconcile()
      refute worker_alive?(tenant, "t4")

      assert {:error, :not_leader} = Owner.trigger(tenant, "t4")
      refute_receive {:ran, _state}, 200
    end
  end

  describe "leadership moved between routing and handling (demotion race)" do
    test "a {:reconcile_tenant} call on a non-leader schedules nothing", %{tenant: tenant} do
      set_leader(false)
      start_owner()
      seed_job(tenant, "rt")

      # notify_changed/1 takes the cast branch when leader?/0 is false, so this
      # call handler is only reachable directly — simulating a node demoted after
      # the notify routed but before the call landed. The row exists, but a
      # demoted node must schedule no worker it no longer owns.
      assert :ok = GenServer.call(Owner, {:reconcile_tenant, tenant})
      refute worker_alive?(tenant, "rt")
    end

    test "notify_changed catches a dead/slow Owner call and returns :ok", %{tenant: tenant} do
      set_leader(true)

      # A stand-in registered under the real Owner name that stops without
      # replying, so notify_changed/1's bounded call exits — the try/catch must
      # swallow it and still return :ok (the row is durable; the tick backstops).
      # No start_owner/0 here: it would clash on the registered name.
      start_supervised!(__MODULE__.DeadOwner)

      assert :ok = Owner.notify_changed(tenant)
    end
  end

  defmodule CapturingRunner do
    @moduledoc false
    @spec run(term()) :: :ok
    def run(state) do
      send(Application.fetch_env!(:jido_claw, :cron_owner_test_pid), {:ran, state})
      :ok
    end
  end

  defmodule DeadOwner do
    @moduledoc false
    # Stand-in registered under the real Owner name whose {:reconcile_tenant}
    # handler stops without replying, so notify_changed/1's bounded call exits —
    # exercising the F2 try/catch. :temporary + a {:shutdown, _} reason keeps the
    # ExUnit supervisor from restarting it or logging a crash report.
    use GenServer, restart: :temporary

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: JidoClaw.Cron.Owner)

    @impl GenServer
    def init(:ok), do: {:ok, :ok}

    @impl GenServer
    def handle_call({:reconcile_tenant, _tenant_id}, _from, state) do
      {:stop, {:shutdown, :test}, state}
    end
  end
end
