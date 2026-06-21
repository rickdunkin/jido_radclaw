defmodule JidoClaw.RouteComposer.ComposerDurableTest do
  @moduledoc """
  AR-2 Phase 2c — the composer as a pure function of durable state. Drives the
  real loop (stub workers, no LLM) and asserts the durable delta log per wave, the
  `route_*` terminal kinds, the commit-failure branch, the rebuild-on-restart
  retry budget, and the supervised lifecycle (single-owner, restart-after-terminal,
  notify-less terminal, and kill-mid-route resume via the dedupe-hit observe path).

  Non-async (`TenantCase`): mutates global app env + the singleton
  Registry/DynamicSupervisor, and runs async Reactor steps under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.BlockingAgentServer
  alias JidoClaw.RouteComposer.TestSupport.GatedAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  @supervisor JidoClaw.RouteComposer.Supervisor
  @registry JidoClaw.RouteComposer.Registry

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

      drain_run_registry(2_000)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "durable")

    context = %{
      tenant_id: tenant,
      session_id: "durable-sess",
      session_uuid: session.id,
      workspace_id: "durable-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  # --- Shared run helpers ---

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

  defp run_sync(ctx), do: RouteComposer.run_sync(Keyword.put(base_opts(ctx), :timeout, 30_000))

  defp converging_outputs do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )
  end

  defp kinds(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    Enum.map(events, & &1.kind)
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    parent
  end

  # A loop state built through the real `init/1` (so it can't drift from the seed
  # shape), with `parent` set to the caller's reloaded run. Lets a test drive a raw
  # `handle_continue(:tick, …)` against a chosen durable parent. `overrides` win over
  # the seed base (e.g. a bogus `tenant`, `max_waves: 0`).
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

  # ===========================================================================
  # The durable delta log + route_* terminals
  # ===========================================================================

  describe "durable delta log (via run_sync)" do
    test "writes route_composed → wave_started → wave_completed per wave + route_converged",
         ctx do
      converging_outputs()

      assert {:ok, summary} = run_sync(ctx)
      # The summary keeps the BARE symbol; only the durable event kind is route_*.
      assert summary.terminal == :converged

      ks = kinds(summary.parent_run_id, ctx)
      assert hd(ks) == :run_started
      # route_converged is the terminal — the final event in the log.
      assert hd(Enum.reverse(ks)) == :route_converged

      # Four executed waves, each: route_composed → wave_started → wave_completed.
      markers = Enum.filter(ks, &(&1 in [:route_composed, :wave_started, :wave_completed]))

      assert markers ==
               List.flatten(List.duplicate([:route_composed, :wave_started, :wave_completed], 4))

      # Content deltas landed; the parent reached the durable terminal.
      assert :signals_published in ks
      assert :artifacts_produced in ks
      assert reload(summary.parent_run_id, ctx).status == :completed
    end

    test "a findings reviewer → route_not_converged (→ :failed); summary stays :not_converged",
         ctx do
      Application.put_env(
        :jido_claw,
        :route_composer_stub_outputs,
        TestFixtures.phase1_stub_outputs(TestFixtures.phase1_findings_reviewer())
      )

      assert {:ok, summary} = run_sync(ctx)
      assert summary.terminal == :not_converged

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_not_converged in ks
      refute :route_converged in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.error == "not_converged"
    end

    test "a wave failure → route_failed (→ :failed)", ctx do
      bad =
        put_in(TestFixtures.phase1_stub_outputs(), ["researcher", "signals"], ["bogus-signal"])

      Application.put_env(:jido_claw, :route_composer_stub_outputs, bad)

      assert {:ok, summary} = run_sync(ctx)
      assert summary.terminal == :failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_failed in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert String.starts_with?(parent.error, "failed:")
    end
  end

  # ===========================================================================
  # Commit failure in the loop
  # ===========================================================================

  test "a commit_wave failure terminalizes route_failed without leaking :active refs", ctx do
    converging_outputs()

    # Manually splice create → inject a conflicting :pending → start, so wave 0's
    # activate_for_wave promotes TWO pendings for {plan, planner, wave 0},
    # violating the active-key index → commit_wave rolls back → route_failed.
    {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)

    {:ok, dummy_child} =
      WorkflowRun.create(%{name: "dummy", workflow_type: "reactor", parent_run_id: parent.id},
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    {:ok, _conflict} =
      ComposerArtifact.store_pending(
        %{
          ref: "art_conflict",
          name: "plan",
          producer: "planner",
          term: "x",
          child_run_id: dummy_child.id,
          wave_index: 0,
          parent_run_id: parent.id
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    notify_ref = make_ref()

    {:ok, _pid} =
      RouteComposer.start_composer(
        Keyword.merge(base_opts(ctx), notify: self(), ref: notify_ref),
        parent
      )

    assert_receive {:route_composer, ^notify_ref, {:done, summary}}, 30_000
    assert summary.terminal == :failed

    failed = reload(parent.id, ctx)
    assert failed.status == :failed
    assert String.starts_with?(failed.error, "failed:")

    # No :active rows leaked — the whole wave commit rolled back.
    assert {:ok, []} =
             ComposerArtifact.active_for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)

    refute :wave_completed in kinds(parent.id, ctx)
  end

  # ===========================================================================
  # Post-review lifecycle gaps (Phase 2b/2c follow-up)
  # ===========================================================================

  describe "post-cancel + supervised terminal-append gaps" do
    # Covers the cancel-already-durable-at-tick-start case (the guard catches it
    # before any write). The narrower residual window — a cancel landing AFTER
    # start_wave commits but BEFORE run_reactor creates the child — is a deferred
    # Phase 4 limitation (see run_built_wave/5) and is intentionally NOT asserted
    # here: in that window an in-flight child IS created, fenced only at commit_wave.
    test "a tick on an already-cancelled parent appends no markers, spawns no child", ctx do
      converging_outputs()

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)

      # An operator cancel landed between waves: the parent is durably terminal.
      {:ok, _} =
        WorkflowLog.append(parent, :run_cancelled, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert reload(parent.id, ctx).status == :cancelled

      before = kinds(parent.id, ctx)
      state = loop_state(parent, ctx, [])

      # One raw tick: Commit.start_wave's FOR-UPDATE guard sees the terminal parent
      # BEFORE any marker append or child-run creation → stop cleanly.
      assert {:stop, :normal, _} = RouteComposer.handle_continue(:tick, state)

      # No route_composed/wave_started markers appended to the terminal parent.
      assert kinds(parent.id, ctx) == before

      # No child run created: start_wave halted the tick before run_reactor.
      {:ok, %{child_runs: kids}} =
        Ash.load(reload(parent.id, ctx), :child_runs, tenant: ctx.tenant, actor: ctx.actor)

      assert kids == []
    end

    test "a supervised terminal-append failure is logged loudly, leaving the parent :running",
         ctx do
      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert reload(parent.id, ctx).status == :running

      # Supervised (notify: nil) state whose terminal append will fail: a bogus
      # tenant makes the terminal reload miss → {:terminalize_failed, _}, a
      # deterministic stand-in for a transient terminal-write failure. max_waves: 0
      # sends the first tick straight to a budget_exhausted finish (no wave runs).
      state = loop_state(parent, ctx, tenant: Ecto.UUID.generate(), max_waves: 0)

      log =
        capture_log(fn ->
          assert {:stop, :normal, _} = RouteComposer.handle_continue(:tick, state)
        end)

      assert log =~ "terminal append failed for parent #{parent.id}"

      # The defect's consequence, now operator-visible: the parent is stuck :running.
      assert reload(parent.id, ctx).status == :running
    end
  end

  # ===========================================================================
  # Rebuild-on-restart retry budget
  # ===========================================================================

  test "a rebuild that keeps failing retries up to the cap then stops :normal (no tight loop)",
       ctx do
    # A parent_run_id that resolves to nothing in this tenant → reload_parent
    # errors every attempt → capped retries → stop :normal (parent left for
    # recovery), never crash-looping.
    log =
      capture_log(fn ->
        {:ok, pid} =
          GenServer.start(RouteComposer,
            catalog: TestFixtures.phase1_catalog(),
            tenant: ctx.tenant,
            actor: ctx.actor,
            parent_run_id: Ecto.UUID.generate()
          )

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      end)

    assert log =~ "rebuild attempt 1 failed"
    assert log =~ "after 5 attempts"
  end

  # ===========================================================================
  # Supervised lifecycle
  # ===========================================================================

  describe "supervised lifecycle" do
    test "ensure_started is single-owner per parent_run_id", ctx do
      # A blocked first wave keeps the composer alive across both (synchronous,
      # back-to-back) ensure_started calls.
      Application.put_env(:jido_claw, :step_agent_server, BlockingAgentServer)
      converging_outputs()

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)

      assert {:ok, pid1} = RouteComposer.ensure_started(base_opts(ctx), parent)
      assert {:ok, pid2} = RouteComposer.ensure_started(base_opts(ctx), parent)

      assert pid1 == pid2
      assert [{^pid1, _}] = Registry.lookup(@registry, parent.id)
    end

    test "a restart-after-terminal stops :normal (terminal_status? guard)", ctx do
      # A parent already terminal → init rebuilds, sees the terminal, stops :normal
      # without re-terminalizing or ticking.
      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)

      {:ok, _} =
        WorkflowLog.append(parent, :route_converged, %{result: %{}},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      assert reload(parent.id, ctx).status == :completed

      kinds_before = kinds(parent.id, ctx)

      assert {:ok, pid} = RouteComposer.ensure_started(base_opts(ctx), parent)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # No new events — the finished run was not touched.
      assert kinds(parent.id, ctx) == kinds_before
    end

    test "a supervised run (no notify) still writes its durable terminal and sends nothing",
         ctx do
      converging_outputs()

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert {:ok, _pid} = RouteComposer.ensure_started(base_opts(ctx), parent)

      # Poll the parent to its durable terminal (no notify channel to await on).
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # Nothing was sent to this process (the supervised run has no sync caller).
      refute_received {:route_composer, _ref, _payload}
    end

    test "kill mid-route → transient restart → rebuild → resume via dedupe-hit observe", ctx do
      converging_outputs()
      Application.put_env(:jido_claw, :step_agent_server, GatedAgentServer)
      Application.put_env(:jido_claw, :route_composer_gate_pid, self())
      Application.put_env(:jido_claw, :route_composer_gate_armed, true)

      {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
      assert {:ok, pid1} = RouteComposer.ensure_started(base_opts(ctx), parent)

      # Wave 0 (planner) is now blocked in the gate; the composer is mid-route.
      assert_receive {:wave_gate, exec_pid}, 10_000

      # Kill the composer; its in-flight wave (async_nolink) survives.
      cref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^cref, :process, ^pid1, :killed}, 5_000

      # The supervisor restarts it; the restart re-dispatches wave 0 and finds the
      # still-:running child (dedupe hit) → observe. Releasing the gate completes
      # the child, the observe poll folds it, and the run resumes to convergence.
      send(exec_pid, :proceed)

      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # ≤1 active per {run, name, producer}: the recovered fold promoted refs once.
      assert {:ok, actives} =
               ComposerArtifact.active_for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)

      keys = Enum.map(actives, &{&1.name, &1.producer})
      assert keys == Enum.uniq(keys)
    end
  end

  # --- helpers ---

  defp await_status(parent_id, ctx, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(parent_id, ctx, target, deadline)
  end

  defp await_status_loop(parent_id, ctx, target, deadline) do
    status = reload(parent_id, ctx).status

    cond do
      status == target ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(50)
        await_status_loop(parent_id, ctx, target, deadline)
    end
  end

  defp drain_run_registry(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    drain_loop(deadline)
  end

  defp drain_loop(deadline) do
    cond do
      Registry.count(RunRegistry) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        drain_loop(deadline)
    end
  end
end
