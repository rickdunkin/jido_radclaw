defmodule JidoClaw.RouteComposer.ComposerLeaseTest do
  @moduledoc """
  WS2 — the lease re-derived around the parent composer run (AR-2 Phase 6).

  Covers the genesis self-claim, off-process sidecar renewal (across a
  synchronously-blocked wave and across a gate park), the stale-fence
  kill → `:transient` restart → held-token preflight → clean `:normal` stop, an
  ordinary same-token crash-restart resume, the durable marker + terminal token
  fences, and the unleased (nil-token) compatibility path.

  `async: false` + the shared sandbox (`TenantCase`): the supervised composer, its
  off-process lease sidecar, and the async wave executors all live off the test
  process and must share the one sandbox connection (mirrors
  `workflow_lease_test.exs`). The prod auto-renew timer is parked
  (`renew_seconds: 86_400` in test config), so renewal is driven on demand through
  the sidecar's `{:lease_tick, from}` seam.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Commit
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.GatedAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  @supervisor JidoClaw.RouteComposer.Supervisor
  @registry JidoClaw.RouteComposer.Registry
  @lease_registry JidoClaw.Orchestration.LeaseRegistry

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
      Application.delete_env(:jido_claw, :route_composer_gate_armed)
      Application.delete_env(:jido_claw, :route_composer_gate_pid)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end

      # Sweep any composer left under the supervisor (terminate_child, not kill —
      # a :transient child would otherwise be restarted by a kill).
      for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor) do
        DynamicSupervisor.terminate_child(@supervisor, pid)
      end

      # Backstop: kill any parent sidecar leaked by an assertion failure before its
      # composer's :DOWN tore it down (mirrors workflow_lease_test.exs:55-63).
      for pid <- Task.Supervisor.children(JidoClaw.Orchestration.LeaseTaskSupervisor) do
        Process.exit(pid, :kill)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "lease-composer")

    context = %{
      tenant_id: tenant,
      session_id: "lease-sess",
      session_uuid: session.id,
      workspace_id: "lease-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  # ===========================================================================
  # 1. Genesis self-claim
  # ===========================================================================

  describe "genesis self-claim" do
    test "create_parent_run/1 stamps the parent lease at genesis", ctx do
      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)

      row = reload_global(parent.id)
      assert is_binary(row.claim_token)
      assert row.claimed_by == WorkflowLease.node_identity()
      assert %DateTime{} = row.claim_expires_at
      # ~now + lease_seconds (60 in test config) — a live, future lease.
      assert DateTime.diff(row.claim_expires_at, DateTime.utc_now(), :second) in 1..120

      # The returned struct carries the token so build_start_opts / terminalize_parent
      # both thread the held token.
      assert parent.claim_token == row.claim_token
      # run_started still flipped :running (claim is non-status-authority).
      assert row.status == :running
    end

    test "a fresh launch is leased; the genesis claim survives a crash as :running + claimed",
         ctx do
      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      row = reload_global(parent.id)

      # The shape WS3 reclaim selects: :running with a non-nil claim token (never the
      # permanently-stranded :running + nil crack a post-run_started claim would risk).
      assert row.status == :running
      assert is_binary(row.claim_token)
    end
  end

  # ===========================================================================
  # 2 & 3. Off-process renewal (blocked wave / gate park)
  # ===========================================================================

  describe "off-process renewal" do
    test "the sidecar renews the parent lease while a wave blocks the loop synchronously", ctx do
      # The CORE WS2 property: the GenServer is blocked in ReactorRunner.run for the
      # whole wave (a self-timer could not fire), yet the off-process sidecar renews.
      converging_outputs()
      arm_gate(ctx)

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert {:ok, _pid} = RouteComposer.ensure_started(base_opts(ctx), parent)

      # Wave 0 is now blocked synchronously inside the wave executor.
      assert_receive {:wave_gate, exec_pid}, 10_000

      sidecar = await_parent_sidecar(parent.id)
      # Force a soon expiry so the renew visibly advances it (both stamp + renew use
      # `now() + lease_seconds`, so without this the delta is sub-tick).
      set_expiry!(parent.id, 2)
      before = reload_global(parent.id).claim_expires_at

      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 1}}, 5_000

      after_expiry = reload_global(parent.id).claim_expires_at
      assert DateTime.compare(after_expiry, before) == :gt

      # Release the wave → the composer runs the rest of the route to convergence
      # (proving renewal held across a multi-wave run).
      send(exec_pid, :proceed)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
    end

    test "the sidecar renews the parent lease while the composer is parked on a gate", ctx do
      {parent, _case_id} = park_on_gate(ctx)

      sidecar = await_parent_sidecar(parent.id)
      set_expiry!(parent.id, 2)
      before = reload_global(parent.id).claim_expires_at

      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 1}}, 5_000

      after_expiry = reload_global(parent.id).claim_expires_at
      assert DateTime.compare(after_expiry, before) == :gt
    end
  end

  # ===========================================================================
  # 4. Stale fence → kill → restart → preflight → stop :normal
  # ===========================================================================

  describe "stale-fence halt" do
    test "rotating the parent token kills the composer; the restart preflights and stops :normal",
         ctx do
      converging_outputs()
      arm_gate(ctx)

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert {:ok, pid1} = RouteComposer.ensure_started(base_opts(ctx), parent)
      assert_receive {:wave_gate, exec_pid}, 10_000

      # The composer is mid-wave-0; the start markers already landed. Snapshot the
      # parent log so we can prove the zombie writes nothing past here.
      kinds_at_rotation = kinds(parent.id, ctx)

      # A reclaimer rotates the token out from under the live owner.
      reclaimer_token = Ash.UUID.generate()
      rotate_token!(parent.id, reclaimer_token)

      # Drive the sidecar heartbeat: renew with the FROZEN (now-stale) token renews 0
      # rows → fence_decision → kill.
      cref = Process.monitor(pid1)
      sidecar = await_parent_sidecar(parent.id)
      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 0}}, 5_000
      assert_receive {:DOWN, ^cref, :process, ^pid1, :killed}, 5_000

      # Drain the orphaned (async_nolink) wave so the sandbox connection frees.
      send(exec_pid, :proceed)

      # The :transient restart preflights the held token → {:ok, 0} (the row token was
      # rotated) → {:stop, :normal}; :transient does NOT restart a :normal stop, so the
      # registry settles empty (no crash loop).
      assert await_no_composer(parent.id)

      # The zombie wrote NO new parent events, and never re-stamped the token.
      assert kinds(parent.id, ctx) == kinds_at_rotation
      reloaded = reload_global(parent.id)
      assert reloaded.claim_token == reclaimer_token
      assert reloaded.status == :running
    end

    test "an ordinary crash-restart (same token) preflights {:ok, 1} and resumes to convergence",
         ctx do
      converging_outputs()
      arm_gate(ctx)

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert {:ok, pid1} = RouteComposer.ensure_started(base_opts(ctx), parent)
      assert_receive {:wave_gate, exec_pid}, 10_000

      claim_before = reload_global(parent.id)
      assert is_binary(claim_before.claim_token)

      # Kill WITHOUT rotating the token — an ordinary crash.
      cref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^cref, :process, ^pid1, :killed}, 5_000

      # The restart re-dispatches wave 0, finds the still-running child (dedupe-hit
      # observe); releasing it lets the run resume to convergence — proving the
      # preflight renew returned {:ok, 1} (a {:ok, 0} would have stopped it).
      send(exec_pid, :proceed)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # Convergence proves the frozen token passed restart preflight without a
      # rotation. The terminal projection now revokes that credential while
      # retaining owner provenance, so a stale sidecar cannot renew green.
      terminal = reload_global(parent.id)
      assert is_nil(terminal.claim_token)
      assert is_nil(terminal.claim_expires_at)
      assert terminal.claimed_by == claim_before.claimed_by
    end
  end

  # ===========================================================================
  # 5. Durable marker token-fence
  # ===========================================================================

  describe "durable marker fence (Commit)" do
    test "append_markers is token-fenced: matching/nil land, a mismatch is :parent_fenced", ctx do
      parent = claimed_parent(ctx)
      token = parent.claim_token

      assert :ok =
               Commit.append_markers(
                 parent,
                 [signals_published: %{signals: ["a"]}],
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: token
               )

      # nil held token (unleased) → no fence.
      assert :ok =
               Commit.append_markers(
                 parent,
                 [signals_published: %{signals: ["b"]}],
                 tenant: ctx.tenant,
                 actor: ctx.actor
               )

      # A stale held token → fenced before any append.
      assert {:error, :parent_fenced} =
               Commit.append_markers(
                 parent,
                 [signals_published: %{signals: ["c"]}],
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: Ash.UUID.generate()
               )
    end

    test "commit_wave is fenced on the same chokepoint (no wave_completed on a mismatch)", ctx do
      parent = claimed_parent(ctx)

      deltas = %{
        stages: ["x"],
        signals_published: [],
        signals_retracted: [],
        artifacts_produced: []
      }

      assert {:error, :parent_fenced} =
               Commit.commit_wave(parent, 0, deltas, [],
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: Ash.UUID.generate()
               )

      refute :wave_completed in kinds(parent.id, ctx)

      # The matching token lands the wave_completed.
      assert :ok =
               Commit.commit_wave(parent, 0, deltas, [],
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: parent.claim_token
               )

      assert :wave_completed in kinds(parent.id, ctx)
    end

    test "a stale-token wave start fences the composer → {:stop, :normal}, no markers", ctx do
      converging_outputs()
      {:ok, created} = RouteComposer.create_parent_run(base_opts(ctx))
      parent = reload(created.id, ctx)
      before = kinds(parent.id, ctx)

      stale = Ash.UUID.generate()
      refute stale == parent.claim_token

      # A leased state whose held token no longer matches the row. The first durable
      # write of the tick (record_wave_start → Commit.start_wave) fences before any
      # marker or child-run is created.
      state = %{loop_state(parent, ctx, []) | claim_token: stale}

      assert {:stop, :normal, _state} = RouteComposer.handle_continue(:tick, state)

      # No route_composed / wave_started landed on the reclaimed parent.
      assert kinds(parent.id, ctx) == before
      # No child run was created (the fence halted before run_reactor).
      {:ok, %{child_runs: kids}} =
        Ash.load(reload(parent.id, ctx), :child_runs, tenant: ctx.tenant, actor: ctx.actor)

      assert kids == []
    end
  end

  # ===========================================================================
  # 6. Terminal token-fence (status-authority fence B, public seam)
  # ===========================================================================

  describe "terminal fence (fence B)" do
    test "a stale-token parent terminal is rejected with status unchanged; the current one lands",
         ctx do
      parent = claimed_parent(ctx)
      token = parent.claim_token

      rotated = Ash.UUID.generate()
      rotate_token!(parent.id, rotated)

      # The stale (old) owner's terminal → rejected in-transaction, parent stays :running.
      assert {:error, _} =
               WorkflowLog.append(parent, :route_converged, %{result: %{}},
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: token
               )

      assert reload_global(parent.id).status == :running

      # The current owner's token → the terminal lands.
      assert {:ok, _} =
               WorkflowLog.append(parent, :route_converged, %{result: %{}},
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 claim_fence_token: rotated
               )

      assert reload_global(parent.id).status == :completed
    end
  end

  # ===========================================================================
  # 7. Unleased (nil-token) compatibility
  # ===========================================================================

  describe "unleased compatibility" do
    test "a nil-token tick runs the wave with no fence and starts no sidecar", ctx do
      converging_outputs()
      {:ok, created} = RouteComposer.create_parent_run(base_opts(ctx))
      parent = reload(created.id, ctx)

      # A raw `loop_state` tick carries no claim_token → the byte-identical unleased
      # path. The wave commits with `commit_opts(nil)` (no fence context).
      state = loop_state(parent, ctx, [])
      assert is_nil(state.claim_token)

      assert {:noreply, _next, {:continue, :tick}} = RouteComposer.handle_continue(:tick, state)

      ks = kinds(parent.id, ctx)
      assert :wave_started in ks
      assert :wave_completed in ks

      # loop_state bypasses do_rebuild, so no parent sidecar was ever started.
      assert Registry.lookup(@lease_registry, parent.id) == []
    end
  end

  # ===========================================================================
  # 8. Sync caller (run_sync) observes a clean fence stop, not a false :timeout
  # ===========================================================================

  describe "run_sync clean-stop protocol" do
    test "a parent-fence at wave commit surfaces :stopped_without_terminal, not a timeout", ctx do
      converging_outputs()
      arm_gate(ctx)

      test_pid = self()

      # A GENEROUS run_sync timeout: longer than the wave-gate setup window, so a
      # slow machine cannot race the budget against startup. The discriminator below
      # is "did the reply arrive shortly after :proceed", NOT a short run_sync timeout
      # — so nothing races the ≤10s startup-to-wave-gate window.
      task =
        Task.async(fn ->
          send(
            test_pid,
            {:run_sync, RouteComposer.run_sync(Keyword.put(base_opts(ctx), :timeout, 15_000))}
          )
        end)

      # Wave 0 is blocked in the executor; its start markers already landed under the
      # still-valid genesis token.
      assert_receive {:wave_gate, exec_pid}, 10_000

      parent = composer_parent_run(ctx)
      kinds_at_rotation = kinds(parent.id, ctx)

      # A reclaimer rotates the token out from under the live owner.
      reclaimer_token = Ash.UUID.generate()
      rotate_token!(parent.id, reclaimer_token)

      # Release the wave: it completes (child-run write lands), returns to the
      # composer, and handle_wave_value's commit_wave (fenced via commit_opts) sees
      # the rotated row token → :parent_fenced → {:stop, :normal} with NO notify. The
      # fixed await_terminal observes the benign :DOWN :normal and replies promptly.
      send(exec_pid, :proceed)

      # Deterministic + race-free: the FIXED build replies within ms of :proceed (the
      # 5s window passes easily); a BROKEN build blocks in await_terminal until the
      # 15s run_sync timeout, so no reply arrives inside 5s → assert_receive fails
      # fast (~5s).
      assert_receive {:run_sync, {:error, :stopped_without_terminal}}, 5_000
      Task.await(task)

      # WS2 "write nothing": the fenced zombie appended no parent event past the
      # rotation, and the reclaimer's row (token + :running) is untouched.
      assert kinds(parent.id, ctx) == kinds_at_rotation
      reloaded = reload_global(parent.id)
      assert reloaded.status == :running
      assert reloaded.claim_token == reclaimer_token
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp base_opts(ctx) do
    [
      catalog: TestFixtures.phase1_catalog(),
      live: TestFixtures.phase1_seed_live(),
      artifacts: TestFixtures.phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      max_waves: 10
    ]
  end

  defp gate_opts(ctx) do
    [
      catalog: TestFixtures.gate_fixture_catalog(),
      live: TestFixtures.gate_fixture_seed_live(),
      artifacts: TestFixtures.gate_fixture_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      max_waves: 10
    ]
  end

  defp converging_outputs do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )
  end

  defp arm_gate(ctx) do
    Application.put_env(:jido_claw, :step_agent_server, GatedAgentServer)
    Application.put_env(:jido_claw, :route_composer_gate_pid, self())
    Application.put_env(:jido_claw, :route_composer_gate_armed, true)
    ctx
  end

  # Start a supervised gate-fixture composer and block until it parks at the plan
  # gate (durable `wave_paused`). Modeled on composer_durable_test's park_gate_on.
  defp park_on_gate(ctx) do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.gate_fixture_stub_outputs()
    )

    RunPubSub.subscribe_gates()
    opts = gate_opts(ctx)
    {:ok, parent} = RouteComposer.create_parent_run(opts)
    {:ok, _pid} = RouteComposer.ensure_started(opts, parent)

    assert_receive {:gate_requested, _child_id, %{agent_case_id: case_id}}, 15_000
    await_wave_paused(parent.id, ctx)
    {parent, case_id}
  end

  # A committed, leased parent run (genesis self-claim), reloaded so it carries the
  # stamped claim_token. No GenServer is started — used by the unit-level fence tests.
  defp claimed_parent(ctx) do
    {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
    reload_global(parent.id)
  end

  # A loop state built through the real init/1 (claim_token defaults to nil), parent
  # set to the caller's reloaded run. Mirrors composer_durable_test's loop_state.
  defp loop_state(parent, ctx, overrides) do
    base = [
      catalog: TestFixtures.phase1_catalog(),
      live: TestFixtures.phase1_seed_live(),
      artifacts: TestFixtures.phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      parent_run_id: parent.id
    ]

    {:ok, state, _continue} = RouteComposer.init(Keyword.merge(base, overrides))
    %{state | parent: parent}
  end

  defp reload_global(run_id) do
    {:ok, %WorkflowRun{} = run} = WorkflowRun.by_id_global(run_id)
    run
  end

  defp reload(run_id, ctx) do
    {:ok, run} = WorkflowRun.by_id(run_id, tenant: ctx.tenant, actor: ctx.actor)
    run
  end

  # run_sync/1 creates its own parent internally, so find it by its
  # `workflow_type: "composer"` root run. async: false + a fresh tenant per test
  # means there is exactly one (mirrors composer_loop_test.exs:672).
  defp composer_parent_run(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant, actor: ctx.actor)
    Enum.find(runs, &(&1.workflow_type == "composer"))
  end

  defp kinds(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)

    Enum.map(events, & &1.kind)
  end

  # Poll the LeaseRegistry for the parent sidecar (registered during do_rebuild,
  # before the first tick, so it is present by the time a wave runs / a gate parks).
  defp await_parent_sidecar(parent_id, tries \\ 200) do
    case Registry.lookup(@lease_registry, parent_id) do
      [{pid, _meta}] ->
        pid

      [] when tries > 0 ->
        Process.sleep(10)
        await_parent_sidecar(parent_id, tries - 1)

      [] ->
        flunk("no parent lease sidecar registered for #{parent_id}")
    end
  end

  # True once the composer is absent from its registry and stays absent (a :normal
  # stop is not restarted by the :transient supervisor). Requires a short streak of
  # empty reads to skip the transient post-kill / pre-restart gap.
  defp await_no_composer(parent_id, tries \\ 300, streak \\ 0) do
    cond do
      streak >= 5 ->
        true

      tries <= 0 ->
        flunk("composer #{parent_id} did not settle gone (still registered)")

      true ->
        Process.sleep(10)
        empty? = Registry.lookup(@registry, parent_id) == []
        await_no_composer(parent_id, tries - 1, if(empty?, do: streak + 1, else: 0))
    end
  end

  defp await_status(parent_id, ctx, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(parent_id, ctx, target, deadline)
  end

  defp await_status_loop(parent_id, ctx, target, deadline) do
    status = reload(parent_id, ctx).status

    cond do
      status == target -> status
      System.monotonic_time(:millisecond) >= deadline -> status
      true -> Process.sleep(50) && await_status_loop(parent_id, ctx, target, deadline)
    end
  end

  defp await_wave_paused(parent_id, ctx, tries \\ 500) do
    cond do
      :wave_paused in kinds(parent_id, ctx) ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_wave_paused(parent_id, ctx, tries - 1)

      true ->
        flunk("expected a wave_paused event for parent #{parent_id}")
    end
  end

  # -- raw SQL seeding (the workflow_lease_test backdating precedent) --

  defp rotate_token!(run_id, token) do
    Repo.query!("UPDATE workflow_runs SET claim_token = $1 WHERE id = $2", [
      Ecto.UUID.dump!(token),
      Ecto.UUID.dump!(run_id)
    ])
  end

  # Force the lease expiry to `now() + seconds`, preserving the token — so a
  # subsequent renew (`now() + lease_seconds`) visibly advances it.
  defp set_expiry!(run_id, seconds) do
    Repo.query!(
      "UPDATE workflow_runs SET claim_expires_at = now() + ($1 || ' seconds')::interval WHERE id = $2",
      [to_string(seconds), Ecto.UUID.dump!(run_id)]
    )
  end
end
