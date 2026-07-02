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

  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.GatedAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker

  # WS3: the composer crash-recovery crafting fixtures now live in `TestFixtures`
  # (shared with `reclaim_pooler_test`). `append_event/4`, `reload/2`, `generate_ref/0`
  # stay local — they are used pervasively by this file's other helpers.
  import JidoClaw.RouteComposer.TestFixtures,
    only: [
      base_opts: 1,
      recoverable_parent: 1,
      recoverable_parent: 2,
      craft_child: 4,
      commit_wave0: 3
    ]

  # WS3 P2: the raw-SQL token rotation + cross-tenant reload seeders (shared with the
  # lease/reclaim suites) drive the stale-owner scenarios ensure_started/2 now evicts.
  import JidoClaw.Orchestration.LeaseHelpers, only: [rotate_token!: 2, reload_global: 1]

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

  defp run_sync(ctx), do: RouteComposer.run_sync(Keyword.put(base_opts(ctx), :timeout, 30_000))

  # AR-4: a run on the self-heal fixture with the driven worker (quality flags once
  # then cleans). The caller arms the worker override + `:route_composer_review_flag_on`.
  defp run_sync_self_heal(ctx) do
    RouteComposer.run_sync(
      catalog: TestFixtures.self_heal_fixture_catalog(),
      live: TestFixtures.self_heal_seed_live(),
      artifacts: TestFixtures.self_heal_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      max_waves: 20,
      timeout: 30_000
    )
  end

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

    test "AR-4: a flagged review wave self-heals to route_converged (the durable twin)", ctx do
      # The durable counterpart to the inverted forward-only test: an open finding
      # on a fixer-bearing CODE path loops review → fix → re-review to
      # route_converged, with a welded stages_invalidated marker (NO
      # closed_wave_index) re-reviewing the touched lenses.
      Application.put_env(
        :jido_claw,
        :agent_templates_override,
        TestFixtures.phase1_template_override(SystemLoopWorker)
      )

      Application.put_env(
        :jido_claw,
        :route_composer_stub_outputs,
        TestFixtures.self_heal_stub_outputs()
      )

      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})
      on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_review_flag_on) end)

      assert {:ok, summary} = run_sync_self_heal(ctx)
      assert summary.terminal == :converged

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_converged in ks
      refute :route_not_converged in ks
      assert :stages_invalidated in ks

      {:ok, events} =
        WorkflowEvent.for_run(summary.parent_run_id, tenant: ctx.tenant, actor: ctx.actor)

      inv = Enum.find(events, &(&1.kind == :stages_invalidated))
      assert Enum.sort(inv.payload["stages"]) == ["correctness-reviewer", "quality-reviewer"]
      refute Map.has_key?(inv.payload, "closed_wave_index")

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :completed
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

    # AR-4 P1: a blocked non-reviewer producer is refused at the mapper
    # (`DefaultMapper.refuse_blocked_producer/2`) → the wave route-fails instead of
    # fabricating its named artifact from the blocked `summary` and advancing the
    # downstream consumer (or silently converging with no lens having run).
    test "a blocked implementer → route_failed (→ :failed), never advancing the reviewers", ctx do
      blocked = put_in(TestFixtures.phase1_stub_outputs(), ["coder", "status"], "blocked")
      Application.put_env(:jido_claw, :route_composer_stub_outputs, blocked)

      assert {:ok, summary} = run_sync(ctx)
      assert summary.terminal == :failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_failed in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert String.starts_with?(parent.error, "failed:")
    end

    test "a blocked planner → route_failed (→ :failed), never advancing the implementer", ctx do
      blocked = put_in(TestFixtures.phase1_stub_outputs(), ["researcher", "status"], "blocked")
      Application.put_env(:jido_claw, :route_composer_stub_outputs, blocked)

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
  # Launch context contract (Phase 3 P2)
  # ===========================================================================

  test "start_composer honors an explicit :context on a minimal parent (P2)", ctx do
    converging_outputs()
    Application.put_env(:jido_claw, :route_composer_capture_context, self())
    on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_context) end)

    {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
    # documents why the bug bit: a minimal parent persists no "context" subset.
    refute Map.has_key?(parent.config, "context")

    notify_ref = make_ref()

    {:ok, _pid} =
      RouteComposer.start_composer(
        Keyword.merge(base_opts(ctx), notify: self(), ref: notify_ref),
        parent
      )

    assert_receive {:wave_context, "researcher", tc}, 30_000
    # The explicit opts :context is honored, not clobbered to the "wf_<tag>" fallback.
    assert tc.workspace_id == ctx.context.workspace_id
    assert tc.project_dir == ctx.context.project_dir
    assert tc.session_uuid == ctx.context.session_uuid

    # Wait for the terminal so the unlinked composer doesn't outlive the test against
    # the shared sandbox (the notify/ref idiom from the commit-failure test above).
    assert_receive {:route_composer, ^notify_ref, {:done, summary}}, 30_000
    assert summary.terminal == :converged
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
      # A composer PARKED on a gate is idle-alive, so a second ensure_started with
      # the SAME (held) token returns the live owner via the ownership probe (WS3 P2)
      # rather than starting a duplicate — the single-owner invariant. (A composer
      # actively running a wave would be busy, not idle; the park is the clean idle
      # state that lets the probe resolve.)
      {parent, _case_id} = start_and_park_gate(ctx)
      [{pid1, _}] = Registry.lookup(@registry, parent.id)

      assert {:ok, pid2} = RouteComposer.ensure_started(base_opts(ctx), parent)

      assert pid1 == pid2
      assert [{^pid1, _}] = Registry.lookup(@registry, parent.id)
    end

    test "ensure_started WITHOUT :terminalize_on_failure? leaves an unstartable parent :running (R4-P2)",
         ctx do
      # Boot recovery's default: a malformed config catalog makes init fail-closed
      # (put_start_catalog strips the key → Keyword.fetch!(:catalog) raises →
      # GenServer.start errors). With NO :terminalize_on_failure? opt the parent is
      # left :running for the next boot's retry — never fail a recoverable route.
      parent = malformed_catalog_parent(ctx, %{"bad" => %{}})
      assert reload(parent.id, ctx).status == :running

      capture_log(fn ->
        assert {:error, _reason} = RouteComposer.ensure_started(base_opts(ctx), parent)
      end)

      assert reload(parent.id, ctx).status == :running
      assert Registry.lookup(@registry, parent.id) == []
    end

    test "ensure_started WITH :terminalize_on_failure? cleans the orphan to terminal (R3-P1)",
         ctx do
      # The front-door opt-in (inverse of the above): the same forced start failure,
      # but `terminalize_on_failure?: true` terminalizes the created-but-unstartable
      # parent so no lingering :running run sits behind a "couldn't start" ack.
      parent = malformed_catalog_parent(ctx, %{"bad" => %{}})
      assert reload(parent.id, ctx).status == :running

      capture_log(fn ->
        assert {:error, _reason} =
                 RouteComposer.ensure_started(
                   Keyword.put(base_opts(ctx), :terminalize_on_failure?, true),
                   parent
                 )
      end)

      assert reload(parent.id, ctx).status == :failed
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
  # WS3 P1 — single-node parent-sidecar failure SUSPENDS the claim (NULL expiry,
  # token kept) so the always-on Pooler can't reclaim a live, heartbeat-less
  # composer, then proceeds degraded only when the suspend took.
  # ===========================================================================

  describe "WS3 P1 single-node parent-sidecar degrade" do
    @tag :capture_log
    test "a parent sidecar that can't arm suspends the claim + still converges", ctx do
      converging_outputs()
      parent = recoverable_parent(ctx)

      # Permanently pre-own the parent's lease key so its heartbeat sidecar can
      # never arm (the middleware fail-closed sub-case, applied to the composer
      # parent) → the single-node degrade path fires.
      {:ok, _} = Registry.register(@lease_registry, parent.id, :blocker)

      assert {:ok, _pid} = RouteComposer.ensure_started(base_opts(ctx), parent)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      # The degrade suspended the claim: NULL expiry (unreclaimable), token retained
      # (the terminal fence still matched). The route converged unleased regardless.
      reloaded = reload_global(parent.id)
      assert is_nil(reloaded.claim_expires_at)
      assert reloaded.claim_token == parent.claim_token
      assert :route_converged in kinds(parent.id, ctx)
    end
  end

  # ===========================================================================
  # WS3 P2 — ensure_started/2 returns a registered composer ONLY if it still holds
  # the run's (possibly just-reclaimed) token by EXACT identity; a stale owner left
  # when claim_next rotated the token is evicted + restarted so the rotated token
  # reaches a live process (the swallowed-reclaim bug).
  # ===========================================================================

  describe "WS3 P2 token-validating ensure_started" do
    test "handle_call(:get_claim_token) replies with state.claim_token", ctx do
      {parent, _case_id} = start_and_park_gate(ctx)
      [{pid, _}] = Registry.lookup(@registry, parent.id)
      assert GenServer.call(pid, :get_claim_token) == parent.claim_token
    end

    test "stale (rotated) token → the owner is evicted + restarted with the rotated token", ctx do
      {parent, _case_id} = start_and_park_gate(ctx)
      [{old_pid, _}] = Registry.lookup(@registry, parent.id)
      assert GenServer.call(old_pid, :get_claim_token) == parent.claim_token

      # A live reclaim rotated the parent token (claim_next), leaving this local
      # composer stale (it still holds the OLD token).
      token_b = Ash.UUID.generate()
      rotate_token!(parent.id, token_b)
      run_b = reload_global(parent.id)
      assert run_b.claim_token == token_b

      # Recovery's minimal opts (config-authoritative catalog), the production seam.
      assert {:ok, new_pid} = RouteComposer.ensure_started(recovery_opts(ctx), run_b)
      assert new_pid != old_pid
      refute Process.alive?(old_pid)

      # The rotated token reached a LIVE process — the new composer re-parks holding
      # token_b (pre-fix the stale old-token composer was returned as-is).
      await_wave_paused_count(parent.id, ctx, 2)
      assert [{^new_pid, _}] = Registry.lookup(@registry, parent.id)
      assert GenServer.call(new_pid, :get_claim_token) == token_b
    end

    test "strict identity: nil==nil keeps the owner; held nil + incoming binary evicts", ctx do
      {parent_nil, _case_id} = park_unleased_gate(ctx)
      [{pid, _}] = Registry.lookup(@registry, parent_nil.id)
      assert GenServer.call(pid, :get_claim_token) == nil

      # Both nil (unleased idempotency) → the same owner, no eviction.
      assert {:ok, ^pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent_nil)
      assert Process.alive?(pid)

      # Held nil + a binary reclaim token → EVICT. This is the case the nil-permissive
      # fence helper (`token_mismatch?/2`) would have wrongly KEPT; exact equality
      # (nil != binary) evicts so the reclaim token reaches a live process.
      token_b = Ash.UUID.generate()
      rotate_token!(parent_nil.id, token_b)
      run_b = reload_global(parent_nil.id)

      assert {:ok, new_pid} = RouteComposer.ensure_started(recovery_opts(ctx), run_b)
      assert new_pid != pid
      refute Process.alive?(pid)
      await_wave_paused_count(parent_nil.id, ctx, 2)
      assert GenServer.call(new_pid, :get_claim_token) == token_b
    end
  end

  # ===========================================================================
  # Gate park / wake / reject / abandon (Phase 4b/4c) — supervised composer on
  # the gate-bearing fixture, driven by Cases.decide/4 + Cases.abandon/3.
  # ===========================================================================

  describe "gate park / wake (Phase 4b/4c)" do
    test "approve: wave_paused (implementer held) → wave_resumed + wave_completed → converges",
         ctx do
      {parent, case_id} = start_and_park_gate(ctx)

      # Parked durably: wave_paused landed, the implementer is held (no
      # implementer wave_started), and the gate wave is not yet completed.
      parked_kinds = kinds(parent.id, ctx)
      assert :wave_paused in parked_kinds
      refute :wave_resumed in parked_kinds
      refute implementer_started?(parent.id, ctx)

      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      ks = kinds(parent.id, ctx)
      assert :wave_resumed in ks
      assert :route_converged in ks
      # The held implementer released and ran (its diff is an :active artifact).
      assert implementer_started?(parent.id, ctx)
      assert "approved-plan" in active_names(parent, ctx)
      assert "diff" in active_names(parent, ctx)
    end

    test "reject → parent :cancelled + disposition rejected, the held route dropped", ctx do
      {parent, case_id} = start_and_park_gate(ctx)

      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)

      assert :route_rejected in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).result["disposition"] == "rejected"
      # The route dropped with the parent — the implementer never ran, never converged.
      refute :route_converged in kinds(parent.id, ctx)
      refute implementer_started?(parent.id, ctx)
    end

    test "abandon → parent :cancelled + disposition abandoned", ctx do
      {parent, case_id} = start_and_park_gate(ctx)

      assert {:ok, _} = Cases.abandon(case_id, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)

      assert :route_abandoned in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).result["disposition"] == "abandoned"
      refute :route_converged in kinds(parent.id, ctx)
    end
  end

  # ===========================================================================
  # Stale `wave_paused` retry guard (Phase 4 P1) — a delayed retry that fires
  # after the gate resolves must be dropped, never deref a nil park and crash.
  # ===========================================================================

  describe "stale wave_paused retry (Phase 4 P1)" do
    test "a retry firing into a resolved park is dropped, not deref'd into a crash", ctx do
      # The literal current-bug condition: the gate resolved (parked → nil) while a
      # transient `wave_paused` retry was still queued. The fix turns the handler into
      # a guarded 3-tuple, so the obsolete 2-tuple the buggy handler matched now falls
      # through to the catch-all and is dropped.
      {parent, _case_id} = start_and_park_gate(ctx)
      [{pid, _}] = Registry.lookup(@registry, parent.id)

      # Gate resolved out from under an in-flight retry.
      :sys.replace_state(pid, &%{&1 | parked: nil})
      # The OLD 2-tuple shape the buggy handler matched — a 3-tuple would never reach
      # the buggy clause, so only the 2-tuple reproduces the literal crash.
      send(pid, {:retry_wave_paused, 3})
      # Barrier: a sys call is served AFTER the info message (strict mailbox order),
      # so its return proves the retry was processed. Against the buggy code the
      # composer crashed on `nil.wave_index` and this exits; against the fix it survives.
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "a foreign-child retry is guarded out — no spurious second wave_paused", ctx do
      # Locks the new child-id guard (and the stale-retry-for-gate-A-while-parked-on-B
      # case): a 3-tuple retry whose child id is NOT our parked child must not re-append.
      {parent, case_id} = start_and_park_gate(ctx)
      [{pid, _}] = Registry.lookup(@registry, parent.id)

      # A foreign child's retry (the new 3-tuple shape), sent (test → composer) BEFORE
      # the decision broadcast (also test → composer, synchronous in `Cases.decide`),
      # so mailbox order has the composer handle the retry while still parked.
      send(pid, {:retry_wave_paused, Ecto.UUID.generate(), 3})

      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # Exactly one wave_paused: the foreign retry matched no parked child and was a
      # no-op. Without the guard it would re-append against the real park (→ 2).
      assert wave_paused_count(parent.id, ctx) == 1
    end
  end

  # ===========================================================================
  # Rerun / re-plan (Phase 4e) — reject opt-in, stale-approval, rerun cap.
  # ===========================================================================

  describe "re-plan (Phase 4e)" do
    test "reject with the opt-in re-plans (just the planner, advancing past the gate) and converges",
         ctx do
      {parent, case_id} =
        park_gate_on(
          ctx,
          TestFixtures.gate_replan_fixture_catalog(),
          TestFixtures.gate_fixture_stub_outputs()
        )

      # Reject the first gate → the opt-in re-plans (the planner re-fires).
      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)

      # stages_invalidated removed JUST the planner (the gate parked → never in ran)
      # and carried closed_wave_index = the rejected gate's wave (advancing the index
      # so the re-dispatch gets a FRESH launch key, not the cancelled gate child).
      assert_receive {:gate_requested, _child2, %{agent_case_id: case_id2}}, 15_000
      await_wave_paused_count(parent.id, ctx, 2)

      inv = stages_invalidated_event(parent.id, ctx)
      assert inv.payload["stages"] == ["planner"]
      assert inv.payload["closed_wave_index"] == 1

      # Re-approve the re-fired gate → converges.
      assert {:ok, _} =
               Cases.decide(case_id2, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "a post-approval scope-shift retracts plan-approved, re-gates, and re-earns approval",
         ctx do
      {parent, case_id} =
        park_gate_on(
          ctx,
          TestFixtures.stale_approval_fixture_catalog(),
          TestFixtures.stale_approval_stub_outputs()
        )

      # Approve → the rescoper runs + emits scope-shift while the implementer is held
      # → plan-approved retracted + {planner, plan-gate} invalidated → re-gate.
      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert_receive {:gate_requested, _child2, %{agent_case_id: case_id2}}, 15_000
      await_wave_paused_count(parent.id, ctx, 2)
      assert :signals_retracted in kinds(parent.id, ctx)

      # The stale-approval rerun set is a completed-wave rerun — NO closed_wave_index.
      inv = stages_invalidated_event(parent.id, ctx)
      assert Enum.sort(inv.payload["stages"]) == ["plan-gate", "planner"]
      refute Map.has_key?(inv.payload, "closed_wave_index")

      # Re-approve → the rescoper does not re-fire (stays in ran) → converges.
      assert {:ok, _} =
               Cases.decide(case_id2, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "the per-stage rerun cap terminates a non-progressing loop as route_budget_exhausted",
         ctx do
      # rerun_cap: 0 → the first reject's re-plan invalidates the planner (count 1 >
      # 0), and the next tick's over_budget? trips → route_budget_exhausted.
      {parent, case_id} =
        park_gate_on(
          ctx,
          TestFixtures.gate_replan_fixture_catalog(),
          TestFixtures.gate_fixture_stub_outputs(),
          rerun_cap: 0
        )

      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert :failed = await_status(parent.id, ctx, :failed, 30_000)
      assert :route_budget_exhausted in kinds(parent.id, ctx)
      assert String.starts_with?(reload(parent.id, ctx).error, "budget_exhausted: rerun_cap=")
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

    test "7a: killed while parked, NOT decided → recovery restarts + re-parks (Phase 4d)", ctx do
      {parent, case_id} = start_and_park_gate(ctx)
      paused_before = wave_paused_count(parent.id, ctx)
      kill_supervised(parent.id)

      assert :ok = WorkflowRecovery.reconcile_all()

      # The restarted composer re-derived the park and RE-PARKED (a fresh
      # wave_paused) WITHOUT re-dispatching the gate wave — the parent stays
      # :running and the gate child stays :awaiting_approval. (Pre-4d the parked
      # gate would have BLOCKED restart.)
      await_wave_paused_count(parent.id, ctx, paused_before + 1)
      assert reload(parent.id, ctx).status == :running
      assert [{_pid, _}] = Registry.lookup(@registry, parent.id)
      assert reload_child(parent, ctx).status == :awaiting_approval

      # The re-parked composer is subscribed + functional: approve → converges.
      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "7b: killed while parked, APPROVED while down → recovery folds + converges", ctx do
      {parent, case_id} = start_and_park_gate(ctx)
      kill_supervised(parent.id)

      # Decide while there is no live composer: the gate child resumes to :completed.
      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :wave_resumed in kinds(parent.id, ctx)
      assert :route_converged in kinds(parent.id, ctx)
    end

    test "7c: killed while parked, REJECTED while down → recovery terminalizes :cancelled", ctx do
      {parent, case_id} = start_and_park_gate(ctx)
      kill_supervised(parent.id)

      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)
      assert :route_rejected in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).result["disposition"] == "rejected"
    end

    test "7d: derive_park finds the park via wave_started even with NO wave_paused", ctx do
      # The marker is non-load-bearing: craft a parked-gate state with wave_started(1)
      # but NO wave_paused, and recovery must still find + re-enter the park.
      parent = gate_recoverable_parent(ctx)
      child0 = craft_child(parent, ctx, 0, :completed)
      commit_wave0(parent, child0, ctx)
      append_wave_started(parent, 1, ["plan-gate"], ctx)
      {gate_child, _gate} = craft_gate_child(parent, ctx, 1)
      assert wave_paused_count(parent.id, ctx) == 0

      assert :ok = WorkflowRecovery.reconcile_all()

      # derive_park found it via wave_started(1) (no wave_paused) → re-parked.
      await_wave_paused_count(parent.id, ctx, 1)
      assert reload(parent.id, ctx).status == :running
      assert reload(gate_child.id, ctx).status == :awaiting_approval
    end

    test "7e: killed while parked, approve+resume FAILED while down → recovery terminalizes :failed",
         ctx do
      {parent, case_id} = start_and_park_gate(ctx)
      kill_supervised(parent.id)

      # An approval landed while down but its resume FAILED (`GateResume.
      # fail_with_audit`): craft the failure durably — case :approved, gate child
      # (wave 1) :awaiting_approval → :running → :failed. Recovery's re-entered
      # park must terminalize the parent route_failed, not re-park forever on the
      # :failed child.
      {:ok, gate} = AgentCase.by_id(case_id, tenant: ctx.tenant, actor: ctx.actor)
      {:ok, _approved} = AgentCase.approve(gate, %{}, tenant: ctx.tenant, actor: ctx.actor)
      [child] = wave_children(parent, ctx, 1)

      {:ok, _} =
        append_event(
          child,
          :approval_resolved,
          %{agent_case_id: case_id, decision: :approve},
          ctx
        )

      {:ok, _} =
        append_event(child, :run_failed, %{error: "gate resume failed: corrupt blob"}, ctx)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :failed = await_status(parent.id, ctx, :failed, 30_000)
      assert :route_failed in kinds(parent.id, ctx)
      refute :route_abandoned in kinds(parent.id, ctx)
    end

    test "7f: a parked gate pair under a TERMINAL composer parent is closed by recovery",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)

      # The parent terminalized while the child + pending case survived — the
      # shape the composer's best-effort paths can leave behind a partial
      # failure (the O-M2 TTL-wins blip; teardown_parked_gate's error path).
      # Without reconciliation the case stays open and DECIDABLE forever behind
      # a route that already ended.
      {:ok, _} = append_event(parent, :route_abandoned, %{reason: "ttl"}, ctx)
      assert reload(parent.id, ctx).status == :cancelled
      assert reload(child.id, ctx).status == :awaiting_approval

      assert :ok = WorkflowRecovery.reconcile_all()

      # The orphaned pair is closed atomically: child failed (checkpoint cleared
      # by the projection), case cancelled — no dangling decidable approval.
      assert reload(child.id, ctx).status == :failed
      assert {:ok, []} = AgentCase.pending_for_run(child.id, tenant: ctx.tenant, actor: ctx.actor)
      {:ok, closed} = AgentCase.by_id(gate.id, tenant: ctx.tenant, actor: ctx.actor)
      assert closed.status == :cancelled
    end

    test "7g: a raced-approved :running child under a TERMINAL composer parent is failed, never re-resumed",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)

      # The raced approve committed durably (case :approved, child
      # :awaiting_approval → :running) before the parent terminalized — the
      # window teardown's cancel can miss (kill/crash between). Recovery's
      # `:decision_recorded` classification must NOT re-resume it: the route
      # already ended, so re-running the gate's downstream steps would
      # re-execute side effects with nobody to fold the output.
      {:ok, _approved} = AgentCase.approve(gate, %{}, tenant: ctx.tenant, actor: ctx.actor)

      {:ok, _} =
        append_event(
          child,
          :approval_resolved,
          %{agent_case_id: gate.id, decision: :approve},
          ctx
        )

      {:ok, _} = append_event(parent, :route_abandoned, %{reason: "ttl"}, ctx)
      assert reload(parent.id, ctx).status == :cancelled
      assert reload(child.id, ctx).status == :running

      assert :ok = WorkflowRecovery.reconcile_all()

      # Converged via the recovery audit pair. `:run_recovered` is the
      # load-bearing non-resume discriminator: a real resume attempt appends
      # only `run_failed` (`GateResume.fail_with_audit`), never
      # `run_recovered` — status alone is ambiguous with the dummy checkpoint.
      assert reload(child.id, ctx).status == :failed
      child_kinds = kinds(child.id, ctx)
      assert :run_recovered in child_kinds
      assert :run_failed in child_kinds
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

    test "a recovered sensitive run keeps BOTH its restored scope and its marker, and converges",
         ctx do
      # Phase 3b makes the composer's `context` durable, which CHANGES this case:
      # a recovered sensitive run now restores its session scope (so the marked
      # `register_child_correlation` succeeds) AND its marker (config-driven, the
      # original H23/P1 fix) — so it CONVERGES with sanitization intact, instead of
      # failing closed for a lost scope (the pre-3b limitation this test used to
      # assert). We prove the marker SURVIVED recovery by its durable correlation
      # row: a wave's `RequestCorrelation` is `sanitize_sensitive_context: true`
      # (an unmarked recovered run — the other recovery tests — would write false).
      converging_outputs()
      parent = recoverable_parent(ctx, sanitize_sensitive_context: true, deadline_ms: 60_000)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
      assert :route_converged in kinds(parent.id, ctx)

      # The marker survived recovery: at least one wave correlation row is marked
      # (the discriminator that isolates the surviving marker now that scope is
      # restored and the run no longer fails closed).
      {:ok, correlations} = RequestCorrelation.read(tenant: ctx.tenant, actor: ctx.actor)
      assert Enum.any?(correlations, & &1.sanitize_sensitive_context)
    end

    test "recovery restores the persisted scope re-atomized, incl workspace_id (R2-P1/R3-P1/R3-P2)",
         ctx do
      # The persist+restore round-trip: create_parent_run serialized `context`
      # (JSON-safe, string-keyed) into config; recovery (no :context opt) restores
      # it RE-ATOMIZED, so a recovered wave keeps the SAME VFS/session scope rather
      # than the `wf_<tag>` / `File.cwd!()` fallback.
      converging_outputs()
      Application.put_env(:jido_claw, :route_composer_capture_context, self())
      on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_context) end)

      parent = recoverable_parent(ctx)

      # Persist side: config carries the string-keyed scope subset incl workspace_id.
      stored = reload(parent.id, ctx).config["context"]
      assert stored["workspace_id"] == ctx.context.workspace_id
      assert stored["project_dir"] == ctx.context.project_dir
      assert stored["session_uuid"] == ctx.context.session_uuid

      # Restore side: the recovered wave worker's tool_context carries the SAME
      # scope (re-atomized), proving build_start_opts restored it from config.
      assert :ok = WorkflowRecovery.reconcile_all()
      assert_receive {:wave_context, "researcher", tc}, 30_000
      assert tc.workspace_id == ctx.context.workspace_id
      assert tc.project_dir == ctx.context.project_dir
      assert tc.session_uuid == ctx.context.session_uuid

      assert :completed = await_status(parent.id, ctx, :completed, 30_000)
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

  describe "sensitive-park deadline (O-M2)" do
    test "a marked run past its deadline auto-abandons the parked child (pending case → Cases.abandon) and terminalizes the parent",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)
      ref = make_ref()
      state = parked_deadline_state(parent, ctx, child, gate.id, ref)

      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:park_deadline, ref, child.id, gate.id}, state)

      # Child terminalized (never left :awaiting_approval); its pending case abandoned.
      assert reload(child.id, ctx).status == :abandoned
      assert {:ok, []} = AgentCase.pending_for_run(child.id, tenant: ctx.tenant, actor: ctx.actor)

      # Parent finished via the composer's own :abandoned terminal (route_abandoned →
      # :cancelled with disposition "abandoned").
      assert :route_abandoned in kinds(parent.id, ctx)
      parent_final = reload(parent.id, ctx)
      assert parent_final.status == :cancelled
      assert parent_final.result["disposition"] == "abandoned"
    end

    test "a genuinely case-less parked child is terminalized via the direct child-terminal append",
         ctx do
      parent = gate_recoverable_parent(ctx)

      # :awaiting_approval WITHOUT a gate case (run_started → approval_requested, no
      # gate_open) — the recovery edge where recovered_case_id is nil AND no case exists.
      running = craft_child(parent, ctx, 0, :running)
      {:ok, _} = append_event(running, :approval_requested, %{}, ctx)
      child = reload(running.id, ctx)
      assert child.status == :awaiting_approval
      assert {:ok, []} = AgentCase.pending_for_run(child.id, tenant: ctx.tenant, actor: ctx.actor)

      ref = make_ref()
      state = parked_deadline_state(parent, ctx, child, nil, ref)

      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:park_deadline, ref, child.id, nil}, state)

      assert reload(child.id, ctx).status == :abandoned
      assert reload(parent.id, ctx).status == :cancelled
    end

    test "a stale :park_deadline (no park, or a mismatched deadline_ref) is ignored — no wrong abandon",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)

      # No park: any :park_deadline is a no-op.
      no_park =
        loop_state(parent, ctx,
          sanitize_sensitive_context: true,
          deadline_at_ms: System.os_time(:millisecond) - 1_000
        )

      assert {:noreply, ^no_park} =
               RouteComposer.handle_info({:park_deadline, make_ref(), child.id, gate.id}, no_park)

      # Parked, but the fired ref doesn't match the current deadline_ref → ignored,
      # and the parked child is NOT abandoned.
      state = parked_deadline_state(parent, ctx, child, gate.id, make_ref())

      assert {:noreply, ^state} =
               RouteComposer.handle_info({:park_deadline, make_ref(), child.id, gate.id}, state)

      assert reload(child.id, ctx).status == :awaiting_approval
    end

    test "a committed APPROVAL beats a raced park-deadline: the stale fire folds the gate, never abandons",
         ctx do
      # THE P1 race: `Cases.decide(:approve)` commits case + child transitions in
      # one transaction and only THEN broadcasts — a `{:park_deadline, …}` timer
      # message already in the mailbox is processed after the commit. The disposal
      # must observe the decided child and route through the normal gate-resolution
      # fold; the pre-fix code saw no pending case, mis-fired `run_abandoned` at a
      # non-parked child, and abandoned the parent — losing the approval.
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)
      ref = make_ref()
      state = gate_deadline_state(parent, ctx, child, gate.id, ref)

      # Craft the committed approval durably (a crafted child's dummy checkpoint
      # cannot truly resume, so no `Cases.decide(:approve)`): case :pending →
      # :approved, child :awaiting_approval → :running → :completed carrying the
      # real plan-gate result envelope (ref-stored approved-plan).
      {:ok, _approved} = AgentCase.approve(gate, %{}, tenant: ctx.tenant, actor: ctx.actor)

      {:ok, _} =
        append_event(
          child,
          :approval_resolved,
          %{agent_case_id: gate.id, decision: :approve},
          ctx
        )

      {:ok, plan_ref} =
        ComposerArtifact.store_wave_artifact(
          "approved-plan",
          "plan-gate",
          "PLAN: build the auth feature",
          child,
          0,
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      envelope = %{
        "wave_index" => 0,
        "emissions" => [
          %{
            "stage" => "plan-gate",
            "signals" => ["plan-approved"],
            "artifacts" => %{"approved-plan" => plan_ref}
          }
        ]
      }

      {:ok, _} = append_event(child, :run_completed, %{result: envelope}, ctx)

      # The stale fire folds the approval (wave_resumed + wave_completed), never
      # bulldozes the parent.
      assert {:noreply, next, {:continue, :tick}} =
               RouteComposer.handle_info({:park_deadline, ref, child.id, gate.id}, state)

      refute :route_abandoned in kinds(parent.id, ctx)
      assert :wave_resumed in kinds(parent.id, ctx)
      assert :wave_completed in kinds(parent.id, ctx)
      assert reload(child.id, ctx).status == :completed

      # The run-level backstop (the documented deadline semantics): the decision
      # wins the GATE, but the RUN stays bounded — the very next tick terminalizes
      # via the deadline BUDGET path, not route_abandoned.
      assert {:stop, :normal, _final} = RouteComposer.handle_continue(:tick, next)
      assert :route_budget_exhausted in kinds(parent.id, ctx)
      refute :route_abandoned in kinds(parent.id, ctx)
    end

    test "a committed REJECT beats a raced park-deadline: route_rejected, never route_abandoned",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)
      ref = make_ref()
      state = gate_deadline_state(parent, ctx, child, gate.id, ref)

      # A real operator reject commits before the (already-mailboxed) timer message
      # is processed — reject never resumes, so `Cases.decide/4` works on a crafted
      # child directly: child :awaiting_approval → :cancelled.
      assert {:ok, _} = Cases.decide(gate.id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert reload(child.id, ctx).status == :cancelled

      # The stale fire terminalizes through the DISPOSITION path: the fixture's
      # plan-gate publishes plan-rejected but nothing subscribes it, so no re-plan —
      # route_rejected (the pre-fix code mis-terminalized this route_abandoned).
      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:park_deadline, ref, child.id, gate.id}, state)

      refute :route_abandoned in kinds(parent.id, ctx)
      assert :route_rejected in kinds(parent.id, ctx)
      parent_final = reload(parent.id, ctx)
      assert parent_final.status == :cancelled
      assert parent_final.result["disposition"] == "rejected"

      # The child is never illegally re-terminalized (no run_abandoned after
      # run_cancelled).
      assert reload(child.id, ctx).status == :cancelled
      refute :run_abandoned in kinds(child.id, ctx)
    end

    test "an approved-then-FAILED resume beats a raced park-deadline: route_failed, never stranded parked",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)
      ref = make_ref()
      state = gate_deadline_state(parent, ctx, child, gate.id, ref)

      # An approval committed but the resume FAILED before the (already-mailboxed)
      # timer message is processed (`GateResume.fail_with_audit` — corrupt blob /
      # missing approved case): case :approved, child :awaiting_approval →
      # :running → :failed.
      {:ok, _approved} = AgentCase.approve(gate, %{}, tenant: ctx.tenant, actor: ctx.actor)

      {:ok, _} =
        append_event(
          child,
          :approval_resolved,
          %{agent_case_id: gate.id, decision: :approve},
          ctx
        )

      {:ok, _} =
        append_event(child, :run_failed, %{error: "gate resume failed: corrupt blob"}, ctx)

      assert reload(child.id, ctx).status == :failed

      # The stale fire must TERMINALIZE the parent (route_failed): the reload-blip
      # catch-all would keep it parked with the timer already consumed — no wake
      # ever coming — stranding the sensitive run past its retention deadline.
      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:park_deadline, ref, child.id, gate.id}, state)

      assert :route_failed in kinds(parent.id, ctx)
      refute :route_abandoned in kinds(parent.id, ctx)
      assert reload(parent.id, ctx).status == :failed
    end

    test "an UNMARKED run keeps its gate park past its deadline (no timer armed)", ctx do
      # A non-sensitive run may carry a deadline, but its park is NOT time-boxed — a
      # parked composer never ticks, so the deadline is unenforced while parked. The
      # deadline (1.5s) is comfortably after the wave-0 gate dispatch (parks first),
      # and the wait carries the check past it — a MARKED run would have abandoned.
      # (resolve-before-deadline is the mirror happy path; the deadline_ref
      # match-guard in handle_info — tested above — is the real defense, timer
      # cancellation at the park-exit is belt-and-suspenders.)
      {parent, _case_id} =
        park_gate_on(
          ctx,
          TestFixtures.gate_fixture_catalog(),
          TestFixtures.gate_fixture_stub_outputs(),
          deadline_ms: 1_500
        )

      Process.sleep(1_500)
      # The parent stays :running across the child gate park (§6) — NOT :cancelled;
      # no `route_abandoned` fired, so the deadline armed no park timer.
      assert reload(parent.id, ctx).status == :running
      refute :route_abandoned in kinds(parent.id, ctx)
    end
  end

  describe "terminal-parent teardown convergence (P1)" do
    test "teardown cancels a child whose raced approve flipped it :running under the terminal parent",
         ctx do
      parent = gate_recoverable_parent(ctx)
      {child, gate} = craft_gate_child(parent, ctx, 0)

      # The raced approve committed durably before the composer processed its
      # teardown (case :approved, child :awaiting_approval → :running) — the
      # `{:decided, :running}` outcome teardown used to discard, leaving the
      # child resuming under a parent nobody will ever fold.
      {:ok, _approved} = AgentCase.approve(gate, %{}, tenant: ctx.tenant, actor: ctx.actor)

      {:ok, _} =
        append_event(
          child,
          :approval_resolved,
          %{agent_case_id: gate.id, decision: :approve},
          ctx
        )

      assert reload(child.id, ctx).status == :running

      # The parent terminalized externally during the park.
      {:ok, _} = append_event(parent, :route_abandoned, %{reason: "external cancel"}, ctx)
      assert reload(parent.id, ctx).status == :cancelled

      # Drive the public seam: a parked composer retrying its wave_paused
      # marker hits the parent-terminal fence in `Commit.append_markers` →
      # `teardown_parked_gate`. Pre-fix the disposition's `{:decided,
      # :running}` was discarded and the child stayed :running.
      state = parked_teardown_state(reload(parent.id, ctx), ctx, child, gate.id)

      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:retry_wave_paused, child.id, 1}, state)

      # Converged: the raced resume is durably cancelled (`Cancellation.cancel`
      # kills any mid-resume executor; the crafted child has none), and the
      # parent's terminal stands untouched.
      assert reload(child.id, ctx).status == :cancelled
      assert :run_cancelled in kinds(child.id, ctx)
      assert reload(parent.id, ctx).status == :cancelled
    end
  end

  # A hand-built parked composer state (through the real `init/1`, so it can't drift
  # from the seed shape) pointed at `child`, marked + already PAST its deadline, with
  # a known `deadline_ref` — so a `{:park_deadline, …}` handle_info deterministically
  # disposes without a running GenServer or timer timing (O-M2). `extra` overrides
  # the `loop_state` seed (e.g. the gate catalog for decided-child paths).
  defp parked_deadline_state(parent, ctx, child, case_id, deadline_ref, extra \\ []) do
    overrides =
      Keyword.merge(
        [sanitize_sensitive_context: true, deadline_at_ms: System.os_time(:millisecond) - 1_000],
        extra
      )

    state = loop_state(parent, ctx, overrides)

    %{
      state
      | parked: %{
          wave_index: 0,
          case_id: case_id,
          child_run_id: child.id,
          dispatch: ["plan-gate"],
          display: []
        },
        deadline_ref: deadline_ref
    }
  end

  # The raced-decision variants resolve through paths that read `state.catalog`
  # (`Map.fetch!` on the parked "plan-gate" dispatch in the fold/disposition
  # branches) — `loop_state`'s phase1 default catalog has NO "plan-gate" key and
  # would KeyError, so thread the gate fixture catalog + matching seeds. The fold
  # path also records the wave off the park's DISPLAY (`record_wave` reads
  # `display.route`/`display.held`), so compose a real display from the built
  # state the same way recovery's `build_recovery_park` does — the abandon-path
  # tests' `[]` placeholder would BadMapError.
  defp gate_deadline_state(parent, ctx, child, case_id, deadline_ref) do
    state =
      parked_deadline_state(parent, ctx, child, case_id, deadline_ref,
        catalog: TestFixtures.gate_fixture_catalog(),
        live: TestFixtures.gate_fixture_seed_live(),
        artifacts: TestFixtures.gate_fixture_seed_artifacts()
      )

    available = Fold.available(state.artifacts)
    result = Router.compose_route(state.catalog, state.live, available, state.ran)
    display = Router.merge_sticky(state.catalog, state.prev_route, result)

    %{state | parked: %{state.parked | display: display}}
  end

  # A hand-built parked composer state for the teardown seam
  # (`{:retry_wave_paused, …}` → attempt_wave_paused → parent-terminal fence →
  # teardown_parked_gate): only the park identity matters — the teardown/cancel
  # path never reads the catalog or the park's display, so `loop_state`'s
  # phase1 defaults suffice (no deadline/sensitive marking either — this is not
  # the O-M2 shape).
  defp parked_teardown_state(parent, ctx, child, case_id) do
    state = loop_state(parent, ctx, [])

    %{
      state
      | parked: %{
          wave_index: 0,
          case_id: case_id,
          child_run_id: child.id,
          dispatch: ["plan-gate"],
          display: []
        }
    }
  end

  # --- recovery crafting helpers ---
  # (`recoverable_parent/2`, `craft_child/4`, `commit_wave0/3` are imported from
  # `TestFixtures` — shared with `reclaim_pooler_test`.)

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

  # A recoverable gate-fixture parent: config carries the serialized gate fixture
  # catalog + bounds (so recovery decodes it) and genesis records the seed.
  defp gate_recoverable_parent(ctx, extra \\ []) do
    {:ok, parent} = RouteComposer.create_parent_run(Keyword.merge(gate_fixture_opts(ctx), extra))
    parent
  end

  # A parked gate child at `wave_index`: :awaiting_approval + a (dummy) checkpoint
  # + a pending `:plan` AgentCase. Modeled on the former `craft_parked_child/2`,
  # but `kind: :plan` (the gate kind) and at a chosen wave. The dummy checkpoint
  # is fine for the re-park path (re_enter_park subscribes + waits; it never
  # decodes the checkpoint).
  defp craft_gate_child(parent, ctx, wave_index) do
    child = craft_child(parent, ctx, wave_index, :running)

    {:ok, gate} =
      WorkflowLog.gate_open(
        child,
        %{
          workflow_run_id: child.id,
          step_name: "plan-gate",
          kind: :plan,
          gate_module: JidoClaw.Gates.PlanGate,
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

  defp generate_ref, do: JidoClaw.Refs.mint("art_")

  # --- Phase-4 gate helpers ---

  defp gate_fixture_opts(ctx), do: gate_opts(ctx, TestFixtures.gate_fixture_catalog())

  defp gate_opts(ctx, catalog, extra \\ []) do
    Keyword.merge(
      [
        catalog: catalog,
        live: TestFixtures.gate_fixture_seed_live(),
        artifacts: TestFixtures.gate_fixture_seed_artifacts(),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        max_waves: 10
      ],
      extra
    )
  end

  defp start_and_park_gate(ctx) do
    park_gate_on(
      ctx,
      TestFixtures.gate_fixture_catalog(),
      TestFixtures.gate_fixture_stub_outputs()
    )
  end

  # Start a supervised composer on `catalog`/`stub_outputs` and block until it parks
  # at the plan gate (durable `wave_paused`). Subscribing to gates BEFORE
  # `ensure_started` catches the `{:gate_requested}` broadcast; `await_wave_paused`
  # then guarantees the composer subscribed (it subscribes before appending the
  # marker) before the caller decides — closing the subscribe-before-decision race.
  defp park_gate_on(ctx, catalog, stub_outputs, extra_opts \\ []) do
    Application.put_env(:jido_claw, :route_composer_stub_outputs, stub_outputs)
    RunPubSub.subscribe_gates()
    opts = gate_opts(ctx, catalog, extra_opts)
    {:ok, parent} = RouteComposer.create_parent_run(opts)
    {:ok, _pid} = RouteComposer.ensure_started(opts, parent)

    assert_receive {:gate_requested, _child_id, %{agent_case_id: case_id}}, 15_000
    await_wave_paused(parent.id, ctx)
    {parent, case_id}
  end

  # The WS3 reclaim/boot seam: minimal opts (no catalog/seed), so `build_start_opts`
  # reconstructs everything config-authoritatively — mirrors
  # `WorkflowRecovery.start_recovered_composer/3`.
  defp recovery_opts(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  # Start a parked gate composer with its genesis lease STRIPPED, so it runs
  # UNLEASED (nil held token) — the WS3 P2 strict-identity nil cases.
  defp park_unleased_gate(ctx) do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.gate_fixture_stub_outputs()
    )

    RunPubSub.subscribe_gates()
    opts = gate_opts(ctx, TestFixtures.gate_fixture_catalog())
    {:ok, parent} = RouteComposer.create_parent_run(opts)
    null_claim!(parent.id)
    parent_nil = reload_global(parent.id)
    {:ok, _pid} = RouteComposer.ensure_started(opts, parent_nil)

    assert_receive {:gate_requested, _child_id, %{agent_case_id: case_id}}, 15_000
    await_wave_paused(parent.id, ctx)
    {parent_nil, case_id}
  end

  # Strip a run's whole claim (token + expiry + owner) — the unleased shape no lease
  # primitive produces (`release_with_cooldown`/`suspend_claim` keep the token).
  defp null_claim!(run_id) do
    JidoClaw.Repo.query!(
      "UPDATE workflow_runs SET claim_token = NULL, claim_expires_at = NULL, claimed_by = NULL WHERE id = $1",
      [Ecto.UUID.dump!(run_id)]
    )
  end

  defp stages_invalidated_event(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    Enum.find(events, &(&1.kind == :stages_invalidated))
  end

  defp await_wave_paused(parent_id, ctx), do: await_wave_paused_count(parent_id, ctx, 1)

  defp wave_paused_count(parent_id, ctx) do
    Enum.count(kinds(parent_id, ctx), &(&1 == :wave_paused))
  end

  defp await_wave_paused_count(parent_id, ctx, n, tries \\ 500) do
    cond do
      wave_paused_count(parent_id, ctx) >= n ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_wave_paused_count(parent_id, ctx, n, tries - 1)

      true ->
        flunk("expected #{n} wave_paused event(s) for parent #{parent_id}")
    end
  end

  # Terminate the supervised composer (terminate_child, so the :transient child is
  # not restarted) and wait until it deregisters — simulating "no live composer"
  # for a recovery test.
  defp kill_supervised(parent_id) do
    case Registry.lookup(@registry, parent_id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(@supervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> :ok
        end

      [] ->
        :ok
    end

    await_deregistered(parent_id)
  end

  defp await_deregistered(parent_id, tries \\ 200) do
    cond do
      Registry.lookup(@registry, parent_id) == [] ->
        :ok

      tries > 0 ->
        Process.sleep(10)
        await_deregistered(parent_id, tries - 1)

      true ->
        :ok
    end
  end

  # The parent's currently-parked (`:awaiting_approval`) gate child.
  defp reload_child(parent, ctx) do
    {:ok, %WorkflowRun{child_runs: kids}} =
      Ash.load(reload(parent.id, ctx), :child_runs, tenant: ctx.tenant, actor: ctx.actor)

    Enum.find(kids, &(&1.status == :awaiting_approval))
  end

  defp implementer_started?(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)

    Enum.any?(events, fn e ->
      e.kind == :wave_started and "implementer" in (e.payload["stages"] || [])
    end)
  end

  defp active_names(parent, ctx) do
    {:ok, actives} =
      ComposerArtifact.active_for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)

    Enum.map(actives, & &1.name)
  end

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
