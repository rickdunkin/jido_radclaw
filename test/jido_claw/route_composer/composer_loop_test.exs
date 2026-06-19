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

  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
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
  end

  test "run_sync unlinks and kills the composer on timeout, then drains the in-flight wave",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :step_agent_server, BlockingAgentServer)

    parent = self()
    task = Task.async(fn -> send(parent, {:run_sync, run(ctx, timeout: 400)}) end)

    # Capture the linked composer before the 400ms kill.
    composer = await_linked_composer(task.pid)
    cref = Process.monitor(composer)

    # Core: the timeout fires (wave blocked 600ms > 400ms) and the composer is
    # *killed*, not left turning the crank. On the unfixed code the composer
    # stays alive → no :killed DOWN → the second assert_receive times out.
    assert_receive {:run_sync, {:error, :timeout}}, 3_000
    assert_receive {:DOWN, ^cref, :process, ^composer, :killed}, 3_000
    Task.await(task)

    # Hygiene: the in-flight wave runs under async_nolink and outlives the
    # composer; wait for its durable write so nothing writes under a torn-down
    # sandbox after the test returns.
    drain_run_registry(2_000)
  end

  # Bounded poll of `task_pid`'s links for the freshly `start_link`ed composer
  # (its `$initial_call` is `{RouteComposer, :init, 1}`). The composer is started
  # at the top of `run_sync/1` (t≈0) and lives until the 400ms kill, so the
  # capture window is wide and deterministic.
  defp await_linked_composer(task_pid, tries \\ 200) do
    links =
      case Process.info(task_pid, :links) do
        {:links, pids} -> pids
        nil -> []
      end

    case Enum.find(links, &composer?/1) do
      nil when tries > 0 ->
        Process.sleep(5)
        await_linked_composer(task_pid, tries - 1)

      nil ->
        flunk("composer not linked to task within poll window")

      pid ->
        pid
    end
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
