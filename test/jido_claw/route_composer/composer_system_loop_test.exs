defmodule JidoClaw.RouteComposer.ComposerSystemLoopTest do
  @moduledoc """
  AR-8c — the system path end-to-end through the real supervised composer (stub
  workers, no LLM): the always-on safety gate, the reverse-verify loop
  (`findings:system` re-fires `{system-executor, system-verifier}`), the
  `:route_verify_failed` terminal when the cap is exhausted, and the safety-gate
  reject (which cancels, NOT re-plans — the B6 narrowing).

  Non-async (`TenantCase`): mutates global app env + the singleton
  Registry/DynamicSupervisor, and runs async Reactor steps under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker

  @supervisor JidoClaw.RouteComposer.Supervisor

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.system_loop_template_override(SystemLoopWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.system_loop_stub_outputs()
    )

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)
      Application.delete_env(:jido_claw, :route_composer_system_verify_fails)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end

      for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor) do
        DynamicSupervisor.terminate_child(@supervisor, pid)
      end

      drain_run_registry(2_000)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "sysloop")

    context = %{
      tenant_id: tenant,
      session_id: "sysloop-sess",
      session_uuid: session.id,
      workspace_id: "sysloop-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  describe "reverse-verify loop (AR-8c)" do
    test "findings:system once then clean:system → both stages invalidated, then converges",
         ctx do
      # The verifier fails exactly once, then passes.
      Application.put_env(:jido_claw, :route_composer_system_verify_fails, 1)
      {parent, case_id} = park_safety_gate(ctx)

      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      ks = kinds(parent.id, ctx)
      assert :route_converged in ks
      refute :route_verify_failed in ks

      # The reverse-verify loop fired once: BOTH stages invalidated, NO
      # closed_wave_index (a generic completed-wave rerun).
      inv = stages_invalidated_event(parent.id, ctx)
      assert Enum.sort(inv.payload["stages"]) == ["system-executor", "system-verifier"]
      refute Map.has_key?(inv.payload, "closed_wave_index")
    end

    test "the verifier always fails + rerun_cap exhausted → route_verify_failed (NOT budget_exhausted)",
         ctx do
      # Always fail; cap below the fail count so the loop exhausts. This directly
      # guards the P1 trip-after-exhaustion fix: at the trip tick the verifier is no
      # longer in `ran` (the cap-tripping invalidation removed it), so the terminal
      # is keyed on rerun_counts + live, not ran.
      Application.put_env(:jido_claw, :route_composer_system_verify_fails, 99)
      {parent, case_id} = park_safety_gate(ctx, rerun_cap: 1)

      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :failed = await_status(parent.id, ctx, :failed, 30_000)

      ks = kinds(parent.id, ctx)
      assert :route_verify_failed in ks
      refute :route_budget_exhausted in ks

      reloaded = reload(parent.id, ctx)
      assert reloaded.status == :failed
      assert reloaded.result["disposition"] == "verify_failed"
      assert String.starts_with?(reloaded.error, "verify_failed: lenses=system")
    end
  end

  describe "safety-gate reject (AR-8c / B6)" do
    test "reject → :cancelled (disposition rejected) and does NOT re-fire the planner", ctx do
      {parent, case_id} = park_safety_gate(ctx)

      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)
      assert :cancelled = await_status(parent.id, ctx, :cancelled, 30_000)

      ks = kinds(parent.id, ctx)
      assert :route_rejected in ks
      assert reload(parent.id, ctx).result["disposition"] == "rejected"
      # The safety-gate does NOT publish `plan-rejected`, so B6's narrowed
      # condition takes the cancel branch — NO re-plan (no stages_invalidated), and
      # the executor never ran.
      refute :stages_invalidated in ks
      refute :route_converged in ks
      refute executor_started?(parent.id, ctx)
    end
  end

  # --- helpers ---

  defp system_opts(ctx, extra) do
    Keyword.merge(
      [
        catalog: TestFixtures.system_verify_loop_fixture_catalog(),
        live: TestFixtures.system_loop_seed_live(),
        artifacts: TestFixtures.system_loop_seed_artifacts(),
        ran: TestFixtures.system_loop_seed_ran(),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        max_waves: 20
      ],
      extra
    )
  end

  # Start a supervised composer on the system fixture and block until it parks at
  # the safety gate (durable `wave_paused`). Subscribing to gates BEFORE
  # `ensure_started` catches the `{:gate_requested}` broadcast.
  defp park_safety_gate(ctx, extra \\ []) do
    RunPubSub.subscribe_gates()
    opts = system_opts(ctx, extra)
    {:ok, parent} = RouteComposer.create_parent_run(opts)
    {:ok, _pid} = RouteComposer.ensure_started(opts, parent)

    assert_receive {:gate_requested, _child_id, %{agent_case_id: case_id}}, 15_000
    await_wave_paused(parent.id, ctx)
    {parent, case_id}
  end

  defp stages_invalidated_event(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    Enum.find(events, &(&1.kind == :stages_invalidated))
  end

  defp executor_started?(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)

    Enum.any?(events, fn e ->
      e.kind == :wave_started and "system-executor" in (e.payload["stages"] || [])
    end)
  end

  defp kinds(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    Enum.map(events, & &1.kind)
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: ctx.actor)
    parent
  end

  defp await_wave_paused(parent_id, ctx, tries \\ 500) do
    cond do
      Enum.any?(kinds(parent_id, ctx), &(&1 == :wave_paused)) ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_wave_paused(parent_id, ctx, tries - 1)

      true ->
        flunk("expected a wave_paused event for parent #{parent_id}")
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
