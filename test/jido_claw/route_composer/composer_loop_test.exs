defmodule JidoClaw.RouteComposer.ComposerLoopTest do
  @moduledoc """
  End-to-end: drive the single-run composer loop over the Phase-1 fixture
  catalog with stub workers, asserting the headline §14 behaviors — a code-path
  route composes and runs across multiple waves, passing `plan` /
  `approved-plan` / `diff` across waves, growing the route from an emitted signal
  (`security-reviewer` joins only because `auth-surface` was emitted), releasing
  a held (locked) stage, and converging on clean review verdicts.

  Non-async (`TenantCase`): it mutates global app env (`:agent_templates_override`,
  `:step_agent_server`, `:route_composer_stub_outputs`) and runs async Reactor
  steps under a shared sandbox so spawned step workers see seeded rows.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.BlockingAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  @all_stages ~w(planner approver implementer quality-reviewer security-reviewer)

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
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "composer")

    context = %{
      tenant_id: tenant,
      session_id: "composer-sess",
      session_uuid: session.id,
      workspace_id: "composer-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  defp run(ctx, opts \\ []) do
    RouteComposer.run_sync(
      catalog: TestFixtures.phase1_catalog(),
      live: TestFixtures.phase1_seed_live(),
      artifacts: TestFixtures.phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: Keyword.get(opts, :max_waves, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
  end

  # AR-2 Phase 3b — the Option-A front-door seed (`triage ∈ ran`) on the gate-free
  # triage-seeded fixture catalog.
  defp run_triage_seeded(ctx, opts \\ []) do
    RouteComposer.run_sync(
      catalog: TestFixtures.triage_seeded_fixture_catalog(),
      live: TestFixtures.triage_seed_live(),
      artifacts: TestFixtures.triage_seed_artifacts(),
      ran: TestFixtures.triage_seed_ran(),
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: Keyword.get(opts, :max_waves, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
  end

  test "Option-A seed: triage ∈ ran, converges, and triage is never dispatched", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run_triage_seeded(ctx)
    assert summary.terminal == :converged

    # triage is in `ran` (the genesis seed), but never appears in a dispatched wave.
    assert MapSet.member?(summary.ran, "triage")
    refute Enum.any?(summary.history, &("triage" in &1.stages))

    # Wave 0 == [planner] proves intent/plan-needed were seeded correctly (planner
    # requires `intent` + subscribes `plan-needed`, both triage's declared outputs).
    assert hd(summary.history).stages == ["planner"]

    # The genesis wave_completed(wave_index: -1, stages: ["triage"]) is in the log.
    {:ok, events} =
      WorkflowEvent.for_run(summary.parent_run_id,
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    genesis =
      Enum.find(events, fn e ->
        e.kind == :wave_completed and e.payload["wave_index"] == -1
      end)

    assert genesis, "expected a genesis wave_completed(-1) event"
    assert genesis.payload["stages"] == ["triage"]
  end

  test "built-in catalog: the triage seed reconciles, then halts at the unbuilt plan-gate", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    # The real catalog can't converge until Phase 4 (plan-gate is a {:gate,_} unit
    # WaveBuilder rejects). Pin the exact Phase-3/Phase-4 boundary: reconciliation
    # works (no triage/{:seed,_} error), planner runs, then the gate halts it.
    assert {:ok, summary} =
             RouteComposer.run_sync(
               catalog: Catalog.all(),
               live: ["request-received", "code", "plan-needed"],
               artifacts: %{
                 "request" => %{"seed" => "Build it"},
                 "intent" => %{"triage" => "Build it"}
               },
               ran: ["triage"],
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               max_waves: 10,
               timeout: 30_000
             )

    assert summary.terminal == :failed
    # planner ran (wave 0), then plan-gate ({:gate,"plan"}) is the unsupported unit.
    assert MapSet.member?(summary.ran, "planner")
    assert match?({:unsupported_unit, "plan-gate", {:gate, "plan"}}, summary.reason)
  end

  test "composes a code-path route end-to-end and converges clean", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)
    assert summary.terminal == :converged

    # plan / approved-plan / diff each crossed waves — present with the right producers.
    assert get_in(summary.artifacts, ["plan", "planner"])
    assert get_in(summary.artifacts, ["approved-plan", "approver"])
    assert get_in(summary.artifacts, ["diff", "implementer"])

    # every stage ran, and convergence carries both clean verdicts.
    assert MapSet.equal?(summary.ran, MapSet.new(@all_stages))
    assert MapSet.member?(summary.final_live, "clean:quality")
    assert MapSet.member?(summary.final_live, "clean:security")

    # four waves: planner, approver (implementer held), implementer, both reviewers.
    assert summary.wave_index == 4
    assert match?([_, _, _, _], summary.history)

    # Phase 2a: the run is a first-class composer parent (root, terminal
    # :completed at convergence), and every wave is a child linked by
    # parent_run_id + the deterministic composer:<parent>:<wave_index> key.
    parent_id = summary.parent_run_id
    assert is_binary(parent_id)

    assert {:ok, parent} =
             WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    assert parent.workflow_type == "composer"
    assert parent.status == :completed
    refute is_nil(parent.started_at)
    assert is_nil(parent.parent_run_id)

    for entry <- summary.history do
      assert {:ok, child} =
               WorkflowRun.by_id(entry.child_run_id,
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant)
               )

      assert child.parent_run_id == parent_id
      assert child.idempotency_key == "composer:#{parent_id}:#{entry.index}"
    end
  end

  test "the implementer is held while the approver runs, then released", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)

    [w0, w1, w2, w3] = summary.history

    assert w0.stages == ["planner"]

    # W1: approver runs while implementer is held on its `until: plan-approved`.
    assert w1.stages == ["approver"]
    assert Map.has_key?(w1.held_before, "implementer")
    assert "plan-approved" in w1.held_before["implementer"]

    # W2: the lock released, implementer now runs.
    assert w2.stages == ["implementer"]

    # W3: both reviewers in one parallel wave — security-reviewer joined ONLY
    # because implementer emitted auth-surface (route growth from a signal).
    assert Enum.sort(w3.stages) == ["quality-reviewer", "security-reviewer"]
  end

  test "each wave's child WorkflowRun.result holds the json-safe emission map", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)

    for entry <- summary.history do
      assert {:ok, child} =
               WorkflowRun.by_id(entry.child_run_id,
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant)
               )

      assert is_map(child.result)
      assert child.result["wave_index"] == entry.index
      assert is_list(child.result["emissions"])
    end
  end

  test "a reviewer returning findings terminates :not_converged (forward-only, no rerun)", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs(TestFixtures.phase1_findings_reviewer())
    )

    assert {:ok, summary} = run(ctx)

    assert summary.terminal == :not_converged
    assert MapSet.member?(summary.final_live, "findings:quality")
    refute MapSet.member?(summary.final_live, "clean:quality")
    # still terminates — not a spin or hang — with every stage having run once.
    assert MapSet.equal?(summary.ran, MapSet.new(@all_stages))

    # Phase 2a: a :not_converged terminal takes the parent to :failed, with the
    # terminal (not the nil reason) as the error string.
    assert {:ok, parent} =
             WorkflowRun.by_id(summary.parent_run_id,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant)
             )

    assert parent.status == :failed
    assert parent.error == "not_converged"
  end

  test "a wave failure records a failed history entry surfacing child_run_id", ctx do
    # An undeclared signal (∉ planner.publishes) fails DefaultMapper.map →
    # WaveCollect → ReactorRunner returns {:error, reason, run}: a deterministic
    # wave failure that still produced a child WorkflowRun.
    bad = put_in(TestFixtures.phase1_stub_outputs(), ["researcher", "signals"], ["bogus-signal"])
    Application.put_env(:jido_claw, :route_composer_stub_outputs, bad)

    assert {:ok, summary} = run(ctx)
    assert summary.terminal == :failed
    assert [entry] = summary.history
    assert entry.failed
    assert entry.stages == ["planner"]
    # the wave's reactor ran; its child run id is surfaced for actionability.
    assert entry.child_run_id

    # Phase 2a: a :failed terminal takes the parent to :failed, error prefixed.
    assert {:ok, parent} =
             WorkflowRun.by_id(summary.parent_run_id,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant)
             )

    assert parent.status == :failed
    assert String.starts_with?(parent.error, "failed:")
  end

  test "run_sync times out, kills the unlinked composer, and terminalizes the parent to :failed",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :step_agent_server, BlockingAgentServer)

    test_pid = self()
    task = Task.async(fn -> send(test_pid, {:run_sync, run(ctx, timeout: 400)}) end)

    # The composer is now UNLINKED (run_sync uses GenServer.start + monitor), so
    # capture it by its $initial_call — not the task's link set — and monitor it
    # to observe the kill.
    composer = await_composer_process()
    cref = Process.monitor(composer)

    # Core: the timeout fires (wave blocked 600ms > 400ms) and the composer is
    # *killed*, not left turning the crank.
    assert_receive {:run_sync, {:error, :timeout}}, 3_000
    assert_receive {:DOWN, ^cref, :process, ^composer, :killed}, 3_000
    Task.await(task)

    # Phase 2a: the now-ownerless :running parent is terminalized live to :failed
    # with the STORED STRING (error is a :string column, so it is "composer_timeout",
    # never the inspected ":composer_timeout") — not left :running.
    parent = composer_parent_run(ctx)
    assert parent.status == :failed
    assert parent.error == "composer_timeout"

    # Hygiene: the in-flight wave runs under async_nolink and outlives the
    # composer; wait for its durable write so nothing writes under a torn-down
    # sandbox after the test returns.
    drain_run_registry(2_000)
  end

  test "run_sync surfaces a start failure and terminalizes the parent to :failed", ctx do
    # No :catalog → the composer's init/1 raises → GenServer.start returns
    # {:error, _} → start_composer terminalizes the just-created :running parent.
    # (capture_log swallows the deliberate proc_lib crash report.)
    capture_log(fn ->
      assert {:error, {:start_failed, _reason}} =
               RouteComposer.run_sync(
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant),
                 timeout: 1_000
               )
    end)

    parent = composer_parent_run(ctx)
    assert parent.status == :failed
  end

  # Bounded poll of the live process table for the freshly-started composer (its
  # `$initial_call` is `{RouteComposer, :init, 1}`). run_sync/1 now starts it
  # UNLINKED (GenServer.start), so it is no longer in the caller's link set — but
  # it is a live process from just after `create_parent_run/1` commits until the
  # 400ms kill, and async:false means it is the only composer alive, so scanning
  # by initial call is deterministic.
  defp await_composer_process(tries \\ 200) do
    case Enum.find(Process.list(), &composer?/1) do
      nil when tries > 0 ->
        Process.sleep(5)
        await_composer_process(tries - 1)

      nil ->
        flunk("composer process not found within poll window")

      pid ->
        pid
    end
  end

  # The single composer parent run in this test's (per-test) tenant — the
  # `workflow_type: "composer"` root run. async:false + a fresh tenant per test
  # means there is exactly one.
  defp composer_parent_run(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant, actor: actor_for(ctx.tenant))
    Enum.find(runs, &(&1.workflow_type == "composer"))
  end

  defp composer?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$initial_call") == {RouteComposer, :init, 1}
      _ -> false
    end
  end

  # Best-effort bounded poll until the orphaned wave executor deregisters from
  # RunRegistry (count → 0), i.e. its durable write landed. async:false means
  # the composer's wave is the only live run, so count == 0 ⟺ the write is done.
  # Best-effort: returns after the bound without asserting, so this hygiene drain
  # can never itself flake the test.
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
