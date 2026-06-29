defmodule JidoClaw.Orchestration.ReclaimPoolerTest do
  @moduledoc """
  WS3 — Reclaim & Recovery. Drives `ReclaimPooler.reclaim_once/0` directly inside the
  Ecto sandbox (the live poll loop is `enabled?: false` in test, like
  `WorkflowRecovery.reconcile_all/0`), and the lower lease primitives `claim_run/1` /
  `release_with_cooldown/3` where a scenario needs them in isolation.

  `async: false` (`TenantCase`): expired leases / rotated tokens / aged `inserted_at`
  are seeded via the shared `LeaseHelpers` raw-SQL seeders, real composers restart
  under the singleton Registry/DynamicSupervisor, and the composer fixtures + reclaim
  drive async Reactor steps under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  import JidoClaw.Orchestration.LeaseHelpers

  import JidoClaw.RouteComposer.TestFixtures,
    only: [recoverable_parent: 1, craft_child: 4, commit_wave0: 3]

  alias JidoClaw.Orchestration.ReclaimPooler
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  @registry JidoClaw.RouteComposer.Registry
  @supervisor JidoClaw.RouteComposer.Supervisor
  @lease_registry JidoClaw.Orchestration.LeaseRegistry
  @run_registry JidoClaw.Orchestration.RunRegistry

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(StubWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end

      # Sweep any composer left under the supervisor (terminate_child, not kill — a
      # :transient child would otherwise be restarted by a kill), then any leaked
      # executor/sidecar tasks.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor) do
        DynamicSupervisor.terminate_child(@supervisor, pid)
      end

      for sup <- [
            JidoClaw.Orchestration.RunTaskSupervisor,
            JidoClaw.Orchestration.LeaseTaskSupervisor
          ],
          pid <- Task.Supervisor.children(sup) do
        Process.exit(pid, :kill)
      end

      drain_run_registry(2_000)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "reclaim")

    context = %{
      tenant_id: tenant,
      session_id: "reclaim-sess",
      session_uuid: session.id,
      workspace_id: "reclaim-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  # ── Component 2: the safe selector (no fresh-pending steal) ─────────────────

  describe "safe selector" do
    test "a fresh :pending+nil-token run is not claimable; aged past the grace it is (P1)", ctx do
      run = seed_run(ctx, "fresh-pending")

      # Within the genesis grace → NOT claimable (the create→stamp gap the always-on
      # Pooler must not steal).
      assert :none = WorkflowLease.claim_next()
      assert reload_global(run.id).status == :pending

      # Aged past the grace → the genesis orphan is reclaimable + failed (no
      # checkpoint, never started).
      backdate_inserted!(run.id, WorkflowLease.pending_grace_seconds() + 60)
      assert 1 == ReclaimPooler.reclaim_once()
      assert reload_global(run.id).status == :failed
    end

    test "eligibility is bounded: not before claim_expires_at, claimable just after (P3)", ctx do
      future = seed_run(ctx, "future")
      set_status!(future.id, "running")
      future_token = Ash.UUID.generate()
      set_claim!(future.id, future_token, 600)
      # No sooner than claim_expires_at.
      assert :none = WorkflowLease.claim_next()

      # Just past expiry (−2s clears the app-clock-vs-DB-clock skew band on one host).
      expired = seed_run(ctx, "expired")
      set_status!(expired.id, "running")
      set_claim!(expired.id, Ash.UUID.generate(), -2)
      assert {:ok, claimed} = WorkflowLease.claim_next()
      assert claimed.id == expired.id

      # The future-expiry run was never a candidate.
      assert :none = WorkflowLease.claim_next()
      assert reload_global(future.id).claim_token == future_token
    end
  end

  # ── Component 3: plain-run reclaim (boot-parity, Q1) ────────────────────────

  describe "plain-run reclaim" do
    test "an expired :running run with no checkpoint is failed; a future-expiry one is untouched",
         ctx do
      stranded = seed_run(ctx, "stranded")
      set_status!(stranded.id, "running")
      set_claim!(stranded.id, Ash.UUID.generate(), -120)

      fresh = seed_run(ctx, "fresh")
      set_status!(fresh.id, "running")
      fresh_token = Ash.UUID.generate()
      set_claim!(fresh.id, fresh_token, 600)

      assert 1 == ReclaimPooler.reclaim_once()
      assert reload_global(stranded.id).status == :failed
      assert reload_global(fresh.id).status == :running
      assert reload_global(fresh.id).claim_token == fresh_token
    end

    test "intra-node task death: a fenced+expired :running run is reclaimed without a node restart",
         ctx do
      {launcher, run_id, _executor} = launch_blocking(ctx)

      # Fence the live executor (a reclaimer rotated the token): the sidecar tick
      # kills it WITHOUT writing a terminal, leaving the run :running + stranded —
      # the "no owner-monitor" gap the Pooler closes.
      reclaimer_token = Ash.UUID.generate()
      rotate_token!(run_id, reclaimer_token)
      assert [{sidecar, _meta}] = Registry.lookup(@lease_registry, run_id)
      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 0}}, 5_000
      assert {:error, :fenced, %WorkflowRun{status: :running}} = Task.await(launcher, 5_000)

      # Expire the lease; the Pooler reclaims the stranded :running run (no boot reboot).
      set_claim!(run_id, reclaimer_token, -120)
      assert 1 == ReclaimPooler.reclaim_once()
      assert reload_global(run_id).status == :failed
    end
  end

  # ── claim_run/1: rotation fence + TOCTOU re-check ───────────────────────────

  describe "claim_run/1 rotation + TOCTOU" do
    test "rotates a corpse's token: the old token renews 0 + an old-token terminal trips fence B (P1)",
         ctx do
      child = seed_run(ctx, "corpse")
      assert {:ok, _} = WorkflowLog.append(child, :run_started, %{}, scope(ctx))
      old_token = Ash.UUID.generate()
      set_claim!(child.id, old_token, -120)

      assert {:ok, rotated} = WorkflowLease.claim_run(child.id)
      assert rotated.claim_token != old_token

      # A reconnecting zombie holding old_token: its heartbeat renew returns 0 (fenced)…
      assert {:ok, 0} = WorkflowLease.renew(child.id, old_token)
      assert {:ok, 1} = WorkflowLease.renew(child.id, rotated.claim_token)

      # …and an old-token status-authority terminal is rejected in-txn (fence B).
      assert {:error, _} =
               WorkflowLog.append(
                 child,
                 :run_completed,
                 %{},
                 Keyword.put(scope(ctx), :claim_fence_token, old_token)
               )

      assert reload_global(child.id).status == :running
    end

    test "leaves a child that renewed (future expiry) after load: under-lock re-check returns :lost (P1 TOCTOU)",
         ctx do
      child = seed_run(ctx, "renewed")
      set_status!(child.id, "running")
      token = Ash.UUID.generate()
      set_claim!(child.id, token, -120)

      # The child renews its lease (same token, future expiry) between the parent's
      # child-load and our claim — the TOCTOU `stamp/4`'s token+status CAS would miss.
      assert {:ok, 1} = WorkflowLease.renew(child.id, token)

      # claim_run re-checks EXPIRY under the lock → now live → :lost, untouched.
      assert :lost = WorkflowLease.claim_run(child.id)
      reloaded = reload_global(child.id)
      assert reloaded.claim_token == token
      assert reloaded.status == :running
    end
  end

  # ── Component 4: composer reclaim (lease-aware + zombie-fencing children) ────

  describe "composer reclaim" do
    test "node-death: an expired corpse wave child is claim-rotated + failed, then the route resumes",
         ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)

      {:ok, _} =
        WorkflowLog.append(
          parent,
          :wave_started,
          %{wave_index: 0, stages: ["planner"]},
          scope(ctx)
        )

      corpse = craft_child(parent, ctx, 0, :running)
      corpse_token = Ash.UUID.generate()
      set_claim!(corpse.id, corpse_token, -120)
      set_claim!(parent.id, Ash.UUID.generate(), -120)

      ReclaimPooler.reclaim_once()

      # The wave-0 corpse was claim-rotated (its old token is fenced) + failed.
      failed = reload_global(corpse.id)
      assert failed.status == :failed
      assert failed.claim_token != corpse_token
      assert {:ok, 0} = WorkflowLease.renew(corpse.id, corpse_token)

      # The composer restarted (token rotated through `build_start_opts`) and the route
      # converged (a fresh wave-0 child re-dispatched, rule 2).
      assert :completed = await_status(parent.id, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "an aged :pending+nil-token wave child is claimed+failed (not skipped), so the composer restarts (P2)",
         ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)

      {:ok, _} =
        WorkflowLog.append(
          parent,
          :wave_started,
          %{wave_index: 0, stages: ["planner"]},
          scope(ctx)
        )

      # A leaseless aged :pending+nil-token wave child (crashed before `Middleware`
      # stamped it): driven through claim_run/1's FULL predicate (clause 2), not a
      # pre-filter to expired-lease only — else it would be skipped and permanently
      # block `restartable?/3`.
      orphan = craft_child(parent, ctx, 0, :pending)
      backdate_inserted!(orphan.id, WorkflowLease.pending_grace_seconds() + 60)
      set_claim!(parent.id, Ash.UUID.generate(), -120)

      ReclaimPooler.reclaim_once()

      assert reload_global(orphan.id).status == :failed
      assert :completed = await_status(parent.id, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "live-child defer: a reclaimed parent with a live-lease child is not restarted; the lease is released (P1)",
         ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)

      live_child = craft_child(parent, ctx, 0, :running)
      live_token = Ash.UUID.generate()
      set_claim!(live_child.id, live_token, 600)
      set_claim!(parent.id, Ash.UUID.generate(), -120)

      # One drain: the parent is claimed once, deferred (the live child blocks
      # restart), and NOT re-claimed within the same drain (the cooldown release
      # pushed its expiry to ~poll_interval).
      assert 1 == ReclaimPooler.reclaim_once()

      assert [] == Registry.lookup(@registry, parent.id)
      assert reload_global(parent.id).status == :running
      # The live child was left untouched (not rotated, not failed).
      assert reload_global(live_child.id).claim_token == live_token
      assert reload_global(live_child.id).status == :running
      # Cooled down → not claimable again right now (no spin).
      assert :none = WorkflowLease.claim_next()
    end

    test "live-child defer then resume: after the live child completes, a later sweep restarts + folds",
         ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      child0 = craft_child(parent, ctx, 0, :running)
      live_token = Ash.UUID.generate()
      set_claim!(child0.id, live_token, 600)
      set_claim!(parent.id, Ash.UUID.generate(), -120)

      assert 1 == ReclaimPooler.reclaim_once()
      assert [] == Registry.lookup(@registry, parent.id)

      # The durably-`async_nolink`-completing child finishes + folds wave 0.
      {:ok, _} =
        WorkflowLog.append(reload_global(child0.id), :run_completed, %{result: %{}}, scope(ctx))

      commit_wave0(parent, child0, ctx)

      # The next poll (simulated by re-expiring the cooled-down parent) finds the child
      # terminal → restartable → restart + fold + converge.
      set_claim!(parent.id, Ash.UUID.generate(), -120)
      assert 1 == ReclaimPooler.reclaim_once()
      assert :completed = await_status(parent.id, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "live reclaim evicts a STALE LOCAL composer + restarts it with the rotated token (P2)",
         ctx do
      # A parked-gate composer is idle-alive AND restartable (its only non-terminal
      # child is the parked gate), still registered holding the genesis token T1 — the
      # exact "stale local owner" the live reclaim path swallowed pre-fix.
      {parent, _case_id} = park_gate_composer(ctx)
      [{old_pid, _}] = Registry.lookup(@registry, parent.id)
      t1 = reload_global(parent.id).claim_token
      assert GenServer.call(old_pid, :get_claim_token) == t1

      # Expire the parent lease (T1 kept) so the always-on Pooler claims + rotates it.
      set_claim!(parent.id, t1, -120)

      # reclaim_once: claim_next rotates T1 → T2, reclaim → restartable (parked child) →
      # ensure_started EVICTS the stale T1 composer + restarts with T2. Pre-fix the
      # stale T1 composer was returned as-is, so the rotated token never reached a live
      # process (recovery falsely reported `:composer` success and stalled).
      assert 1 == ReclaimPooler.reclaim_once()

      refute Process.alive?(old_pid)
      t2 = reload_global(parent.id).claim_token
      assert t2 != t1

      # The rotated token reached a LIVE process: a NEW composer is registered +
      # re-parked holding T2 (route convergence then follows a gate decision, which is
      # off this test's path — the P2 fix is "the rotated token runs in a live owner").
      await_wave_paused_count(parent.id, ctx, 2)
      assert [{new_pid, _}] = Registry.lookup(@registry, parent.id)
      assert new_pid != old_pid
      assert GenServer.call(new_pid, :get_claim_token) == t2
      assert reload_global(parent.id).status == :running
    end
  end

  # ── Always-on in every mode (boot complementary) ────────────────────────────

  describe "always-on, both modes" do
    test "cluster on → boot recovery self-disables, but the Pooler still reclaims", ctx do
      stranded = seed_run(ctx, "clustered")
      set_status!(stranded.id, "running")
      set_claim!(stranded.id, Ash.UUID.generate(), -120)

      with_cluster_enabled(true, fn ->
        # Boot recovery is gated off under clustering…
        assert :ok = WorkflowRecovery.run([])
        assert reload_global(stranded.id).status == :running

        # …the Pooler is not gated on serve_mode/cluster and reclaims regardless.
        assert 1 == ReclaimPooler.reclaim_once()
        assert reload_global(stranded.id).status == :failed
      end)
    end

    test "single-node boot + reclaim overlap idempotently: ≤1 terminal, the re-reconcile is a no-op",
         ctx do
      stranded = seed_run(ctx, "overlap")
      set_status!(stranded.id, "running")
      set_claim!(stranded.id, Ash.UUID.generate(), -120)

      # Reclaim fails it…
      assert 1 == ReclaimPooler.reclaim_once()
      assert reload_global(stranded.id).status == :failed

      # …and a boot reconcile of the now-terminal run is a no-op (the FOR UPDATE +
      # :illegal terminal-on-terminal guard), not a second terminal or a crash.
      assert :ok = WorkflowRecovery.reconcile_all()
      assert reload_global(stranded.id).status == :failed
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]

  defp converging_outputs do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )
  end

  # Start a supervised composer on the gate fixture and block until it PARKS at the
  # plan gate (idle-alive + restartable) — the live "stale local owner" the WS3 P2
  # reclaim path must evict.
  defp park_gate_composer(ctx) do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.gate_fixture_stub_outputs()
    )

    RunPubSub.subscribe_gates()

    opts = [
      catalog: TestFixtures.gate_fixture_catalog(),
      live: TestFixtures.gate_fixture_seed_live(),
      artifacts: TestFixtures.gate_fixture_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      max_waves: 10
    ]

    {:ok, parent} = RouteComposer.create_parent_run(opts)
    {:ok, _pid} = RouteComposer.ensure_started(opts, parent)

    assert_receive {:gate_requested, _child_id, %{agent_case_id: case_id}}, 15_000
    await_wave_paused_count(parent.id, ctx, 1)
    {parent, case_id}
  end

  defp await_wave_paused_count(parent_id, ctx, n, tries \\ 500) do
    count = Enum.count(kinds(parent_id, ctx), &(&1 == :wave_paused))

    cond do
      count >= n ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_wave_paused_count(parent_id, ctx, n, tries - 1)

      true ->
        flunk("expected #{n} wave_paused event(s) for #{parent_id}, saw #{count}")
    end
  end

  defp await_status(run_id, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(run_id, target, deadline)
  end

  defp await_status_loop(run_id, target, deadline) do
    status = reload_global(run_id).status

    cond do
      status == target ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(50)
        await_status_loop(run_id, target, deadline)
    end
  end

  defp drain_run_registry(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    drain_loop(deadline)
  end

  defp drain_loop(deadline) do
    cond do
      Registry.count(@run_registry) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        drain_loop(deadline)
    end
  end
end
