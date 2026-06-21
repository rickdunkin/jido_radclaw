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

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Commit
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

  # ===========================================================================
  # Crash recovery (Phase 2d) — cold boot: a crafted :running parent (+
  # children/events) with NO live composer process, then reconcile_all/0.
  # ===========================================================================

  describe "crash recovery (Phase 2d)" do
    test "1: a killed mid-route run resumes from the next wave on reboot", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      child0 = craft_child(parent, ctx, 0, :completed)
      # Wave 0's durable fold (planner ran, published plan-ready, produced the
      # plan), so the resumed composer skips wave 0 and dispatches wave 1.
      commit_wave0(parent, child0, ctx)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "2: a wave_started with no child re-launches wave 0 under the same key (rule 1)", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      # Crash AFTER wave_started committed but BEFORE the child run was created.
      append_wave_started(parent, 0, ["planner"], ctx)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # Exactly one wave-0 child materialized under composer:<parent>:0.
      assert match?([_], wave_children(parent, ctx, 0))

      # The genesis seed events rebuilt live/artifacts (recovery passed no seed
      # opts): the first composed route saw the seed signal + artifact.
      rc = first_route_composed(parent.id, ctx)
      assert "request-received" in rc.payload["live"]
      assert "request" in rc.payload["available"]
    end

    test "3: a child recovered to :failed re-dispatches under a fresh wave_index (rule 2)", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      append_wave_started(parent, 0, ["planner"], ctx)
      # A :running wave-0 child recovery will fail (stranded → :failed).
      failed = craft_child(parent, ctx, 0, :running)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # The original wave-0 child stays :failed (a harmless orphan), and a fresh
      # wave-1 child materialized (rule 2's fresh wave_index).
      assert reload(failed.id, ctx).status == :failed
      assert wave_children(parent, ctx, 1) != []

      assert_unique_actives(parent, ctx)
    end

    test "4: subtractive deltas survive the rebuild", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      # Publish two inert signals, retract one — the net must survive the rebuild.
      {:ok, _} =
        append_event(parent, :signals_published, %{signals: ["keep-sig", "drop-sig"]}, ctx)

      {:ok, _} = append_event(parent, :signals_retracted, %{signals: ["drop-sig"]}, ctx)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      # The resumed composer's first composed route reflects the NET live:
      # keep-sig present (additive survived), drop-sig absent (subtractive survived).
      rc = first_route_composed(parent.id, ctx)
      assert "keep-sig" in rc.payload["live"]
      refute "drop-sig" in rc.payload["live"]
    end

    test "5: orphaned :pending artifacts never block re-launch nor surface", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)
      append_wave_started(parent, 0, ["planner"], ctx)
      failed = craft_child(parent, ctx, 0, :running)

      # WaveCollect inserted a :pending plan for wave 0 before the crash (no
      # wave_completed → never activated): an orphan that must not block re-launch.
      orphan_ref = generate_ref()

      {:ok, _} =
        ComposerArtifact.store_pending(
          %{
            ref: orphan_ref,
            name: "plan",
            producer: "planner",
            term: "ORPHAN PLAN",
            child_run_id: failed.id,
            parent_run_id: parent.id,
            wave_index: 0
          },
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      # No unique violation (the run converged) and ≤1 active per {name, producer}.
      assert_unique_actives(parent, ctx)

      # The orphan was never promoted (still :pending) and is not among the actives.
      assert {:ok, orphan} =
               ComposerArtifact.resolve_ref(orphan_ref, tenant: ctx.tenant, actor: ctx.actor)

      assert orphan.state == :pending
      refute orphan_ref in active_refs(parent, ctx)
    end

    test "6a: a gate-rejected-then-crash child synthesizes route_rejected", ctx do
      parent = recoverable_parent(ctx)
      append_wave_started(parent, 0, ["planner"], ctx)
      # No Phase-2 gate producers yet, so craft the child terminal directly.
      craft_child(parent, ctx, 0, :cancelled)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)
      assert :route_rejected in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).result["disposition"] == "rejected"
    end

    test "6b: a gate-abandoned-then-crash child synthesizes route_abandoned", ctx do
      parent = recoverable_parent(ctx)
      append_wave_started(parent, 0, ["planner"], ctx)
      craft_child(parent, ctx, 0, :abandoned)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)
      assert :route_abandoned in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).result["disposition"] == "abandoned"
    end

    test "7: a parked gate child blocks restart (forward-safety pin)", ctx do
      parent = recoverable_parent(ctx)
      {parked, _gate} = craft_parked_child(parent, ctx)

      assert :ok = WorkflowRecovery.reconcile_all()

      # The parked child stays :awaiting_approval (the :parked no-op), so the
      # "all children terminal" guard fails → the composer is NOT started.
      assert reload(parent.id, ctx).status == :running
      assert Registry.lookup(@registry, parent.id) == []
      assert reload(parked.id, ctx).status == :awaiting_approval

      assert {:ok, [_pending]} =
               AgentCase.pending_for_run(parked.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "8: seed premises survive a pre-first-wave crash", ctx do
      converging_outputs()
      # A genesis-only crash (no route_composed marker yet) with a non-empty seed
      # premises — recovery must restore it from config, not the lost in-memory opts.
      parent = recoverable_parent(ctx, premises: %{"risk" => "low", "scope" => "auth"})

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      # The resumed composer's FIRST route_composed carries the seed premises.
      rc = first_route_composed(parent.id, ctx)
      assert rc.payload["premises"] == %{"risk" => "low", "scope" => "auth"}
    end

    test "a recovered sensitive run keeps its marker and fails closed without a scope (H23/P1)",
         ctx do
      # The critical P1 fix: build_start_opts must restore `sanitize_sensitive_context`
      # from config on recovery. We prove the LIVE marker survived by its observable
      # effect: a marked wave's `register_child_correlation` REQUIRES a session scope,
      # which recovery does not restore (context isn't durable). So a recovered
      # sensitive run FAILS CLOSED at its first wave rather than running an
      # un-sanitized turn. A LOST marker would instead make the correlation
      # infallible (unmarked → cache-only) and the run would CONVERGE — exactly the
      # same setup the unmarked recovery tests above ride to `:completed`. So
      # `:failed` here (vs their `:completed`) isolates the surviving marker.
      converging_outputs()
      parent = recoverable_parent(ctx, sanitize_sensitive_context: true, deadline_ms: 60_000)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :failed = await_status(parent.id, ctx, :failed, 30_000)
      assert :route_failed in kinds(parent.id, ctx)
      # Failed at the FIRST wave's correlation (no wave ever completed) ...
      refute :wave_completed in kinds(parent.id, ctx)
      # ... and the marked terminal scrub (config-driven) redacted the reason.
      assert reload(parent.id, ctx).error == "[composer-sensitive:redacted]"
    end

    test "a malformed config catalog leaves the parent :running and starts no composer", ctx do
      parent = malformed_catalog_parent(ctx, %{"bad" => %{}})

      log =
        capture_log(fn ->
          assert :ok = WorkflowRecovery.reconcile_all()
        end)

      # Deterministic discriminator: ONLY the un-recoverable branch logs this (fails
      # without the fix, where recoverable_catalog? returns true → resume → no such log).
      assert log =~ "no recoverable catalog"

      # Corroborating second signal: a restarted composer would append route_converged
      # ASYNCHRONOUSLY, so an immediate read is racy — use a BOUNDED settle (reuse the
      # suite's poll cadence, ~500ms) so the buggy path has time to misbehave, then
      # assert it never converged and the parent stays :running.
      refute converged_within?(parent.id, ctx, 500)
      assert reload(parent.id, ctx).status == :running
    end

    test "a malformed config catalog with a valid opts catalog still fails closed", ctx do
      # The launch seam (not recovery): `build_start_opts/2` starts FROM opts, so a
      # direct `ensure_started/2`/`start_composer/2` caller may carry a VALID
      # `:catalog`. A corrupt `config["catalog"]` is authoritative and must NOT
      # fall back to that opts catalog — `:invalid` STRIPS the key so init fails
      # closed, instead of launching a composer on the stale opts catalog (which,
      # left in place, would converge to :completed).
      parent = malformed_catalog_parent(ctx, %{"bad" => %{}})

      # base_opts carries a VALID phase1 catalog; config["catalog"] is corrupt.
      capture_log(fn ->
        assert {:error, _reason} = RouteComposer.ensure_started(base_opts(ctx), parent)
      end)

      # No composer ran on the stale opts catalog: no wave ever launched and the
      # parent never converged.
      refute :wave_started in kinds(parent.id, ctx)
      refute converged_within?(parent.id, ctx, 500)
    end
  end

  # --- recovery crafting helpers ---

  # A recoverable parent: create_parent_run with the full base_opts, so config
  # carries the serialized catalog + bounds and genesis records the seed
  # live/artifacts events. `extra_opts` adds e.g. premises / the sensitive marker.
  defp recoverable_parent(ctx, extra_opts \\ []) do
    {:ok, parent} = RouteComposer.create_parent_run(Keyword.merge(base_opts(ctx), extra_opts))
    parent
  end

  # A :running composer parent whose `config["catalog"]` is malformed — it decodes
  # atom-safe to a default `%Stage{}` but is NOT validator-clean, so the recovery
  # guard must classify it un-recoverable. `recoverable_parent/2` always serializes
  # a VALID catalog, so craft this one directly: create :pending → run_started →
  # :running (the parent axis of craft_child/4 + drive_child/3).
  defp malformed_catalog_parent(ctx, bad_catalog) do
    {:ok, parent} =
      WorkflowRun.create(
        %{
          name: "malformed-composer",
          workflow_type: "composer",
          config: %{"catalog" => bad_catalog}
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    {:ok, _} = append_event(parent, :run_started, %{}, ctx)
    reload(parent.id, ctx)
  end

  # Create a wave child under the deterministic composer:<parent>:<wave> launch
  # key and drive it to `status` via its own event log.
  defp craft_child(parent, ctx, wave_index, status) do
    {:ok, child} =
      WorkflowRun.create(
        %{
          name: "wave-#{wave_index}",
          workflow_type: "reactor",
          parent_run_id: parent.id,
          idempotency_key: "composer:#{parent.id}:#{wave_index}"
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    drive_child(child, status, ctx)
  end

  defp drive_child(child, :pending, _ctx), do: child

  defp drive_child(child, :running, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    reload(child.id, ctx)
  end

  defp drive_child(child, :completed, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :run_completed, %{result: %{}}, ctx)
    reload(child.id, ctx)
  end

  defp drive_child(child, :cancelled, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :run_cancelled, %{}, ctx)
    reload(child.id, ctx)
  end

  # `run_abandoned` is legal only from :awaiting_approval (projection guard), so
  # park the child via approval_requested first.
  defp drive_child(child, :abandoned, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :approval_requested, %{}, ctx)
    {:ok, _} = append_event(child, :run_abandoned, %{}, ctx)
    reload(child.id, ctx)
  end

  # A parked gate child: :awaiting_approval + a checkpoint + a pending AgentCase
  # (so recovery classifies it :parked → no-op, leaving it non-terminal).
  defp craft_parked_child(parent, ctx) do
    child = craft_child(parent, ctx, 0, :running)

    {:ok, gate} =
      WorkflowLog.gate_open(
        child,
        %{
          workflow_run_id: child.id,
          step_name: "plan-gate",
          kind: :irreversible_write,
          gate_module: JidoClaw.Gates.IrreversibleWriteGate,
          details: %{}
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    {:ok, _} =
      WorkflowRun.set_checkpoint(
        reload(child.id, ctx),
        %{resume_checkpoint: :erlang.term_to_binary(:cp)},
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    {reload(child.id, ctx), gate}
  end

  # Commit wave 0's durable fold (the dropped-fold recovery shape): store the plan
  # as a :pending row that Commit.commit_wave activates, alongside wave_completed
  # + the content deltas.
  defp commit_wave0(parent, child, ctx) do
    plan_ref = generate_ref()

    {:ok, _} =
      ComposerArtifact.store_pending(
        %{
          ref: plan_ref,
          name: "plan",
          producer: "planner",
          term: "PLAN: build the auth feature",
          child_run_id: child.id,
          parent_run_id: parent.id,
          wave_index: 0
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    deltas = %{
      stages: ["planner"],
      signals_published: ["plan-ready"],
      signals_retracted: [],
      artifacts_produced: [%{name: "plan", producer: "planner", ref: plan_ref}]
    }

    :ok = Commit.commit_wave(parent, 0, deltas, tenant: ctx.tenant, actor: ctx.actor)
  end

  defp append_event(run, kind, payload, ctx),
    do: WorkflowLog.append(run, kind, payload, tenant: ctx.tenant, actor: ctx.actor)

  # wave_started is a no-op for the projection (correlation metadata), so a minimal
  # payload suffices; it documents "the composer started this wave before crashing".
  defp append_wave_started(parent, wave_index, stages, ctx),
    do: append_event(parent, :wave_started, %{wave_index: wave_index, stages: stages}, ctx)

  defp wave_children(parent, ctx, wave_index) do
    {:ok, %{child_runs: kids}} =
      Ash.load(reload(parent.id, ctx), :child_runs, tenant: ctx.tenant, actor: ctx.actor)

    Enum.filter(kids, &(&1.idempotency_key == "composer:#{parent.id}:#{wave_index}"))
  end

  defp first_route_composed(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)

    events
    |> Enum.sort_by(& &1.seq)
    |> Enum.find(&(&1.kind == :route_composed))
  end

  defp active_refs(parent, ctx) do
    {:ok, actives} =
      ComposerArtifact.active_for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)

    Enum.map(actives, & &1.ref)
  end

  defp assert_unique_actives(parent, ctx) do
    {:ok, actives} =
      ComposerArtifact.active_for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)

    keys = Enum.map(actives, &{&1.name, &1.producer})
    assert keys == Enum.uniq(keys)
  end

  defp generate_ref, do: "art_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # --- helpers ---

  # A small bounded poll: true iff `:route_converged` appears in the parent's log
  # within `timeout` ms, else false on timeout. Gives a (buggy-path) restarted
  # composer time to false-converge before the caller asserts it did NOT.
  defp converged_within?(parent_id, ctx, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    converged_loop(parent_id, ctx, deadline)
  end

  defp converged_loop(parent_id, ctx, deadline) do
    cond do
      :route_converged in kinds(parent_id, ctx) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        converged_loop(parent_id, ctx, deadline)
    end
  end

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
