defmodule JidoClaw.Eval.ComposerCaseTest do
  @moduledoc """
  X1 (unadopted-next-five item 5): the arbiter decision-memo contract through a
  REAL armed composer run, packaged as a `:composer` eval case. The runner is
  live either way — the fake half is the caller's env arming (the composer stub
  templates/outputs + `StubAgentServer`), exactly the `composer_loop_test`
  armed setup. Non-async (`TenantCase`): mutates global app env and runs async
  Reactor steps under a shared sandbox.
  """

  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Eval
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.armed_template_override(StubWorker)
    )

    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.armed_stub_outputs(TestFixtures.armed_adopt_arbiter())
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
      seed_full(tenant_label: "evalx1")

    context = %{
      tenant_id: tenant,
      session_id: "evalx1-sess",
      session_uuid: session.id,
      workspace_id: "evalx1-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  test "X1: armed adopt — memo + finalized plan artifacts through a real gated wave", ctx do
    # Subscribe BEFORE starting the run: :gate_requested is a one-shot
    # broadcast, not replayed.
    RunPubSub.subscribe_gates()

    eval_case = %{
      id: "x1-armed-adopt-memo",
      kind: :composer,
      request: %{
        catalog: Catalog.all(),
        live: TestFixtures.armed_seed_live(),
        artifacts: TestFixtures.armed_seed_artifacts(),
        ran: ["triage"],
        max_waves: 15
      },
      assertions: %{
        terminal: :converged,
        ran: "implementer",
        artifact_contains: [{"decision-memo", "plan-arbiter", "verdict: adopt"}],
        artifact_equals: [
          {"plan", "planner", "PLAN (final): adopt Plan A, smallest-shippable."}
        ]
      }
    }

    task =
      Task.async(fn ->
        Eval.run_case(eval_case,
          tenant: ctx.tenant,
          actor: actor_for(ctx.tenant),
          context: ctx.context,
          timeout: 30_000
        )
      end)

    assert_receive {:gate_requested, child_id, %{agent_case_id: case_id}}, 15_000
    await_paused_then_approve(child_id, case_id, ctx)

    assert {:ok, run} = Task.await(task, 30_000)
    settle_run_registry(2_000)

    assert run.status == :passed,
           "X1 failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    assert run.observations.terminal == :converged
    assert "decision-memo" in run.observations.artifact_names
  end

  test "malformed artifact assertion items fail the run per-item instead of crashing it", ctx do
    RunPubSub.subscribe_gates()

    eval_case = %{
      id: "x1-malformed-assertions",
      kind: :composer,
      request: %{
        catalog: Catalog.all(),
        live: TestFixtures.armed_seed_live(),
        artifacts: TestFixtures.armed_seed_artifacts(),
        ran: ["triage"],
        max_waves: 15
      },
      assertions: %{
        terminal: :converged,
        artifact_contains: ["not-a-triple"],
        artifact_equals: [{"plan", "planner"}]
      }
    }

    task =
      Task.async(fn ->
        Eval.run_case(eval_case,
          tenant: ctx.tenant,
          actor: actor_for(ctx.tenant),
          context: ctx.context,
          timeout: 30_000
        )
      end)

    assert_receive {:gate_requested, child_id, %{agent_case_id: case_id}}, 15_000
    await_paused_then_approve(child_id, case_id, ctx)

    assert {:ok, run} = Task.await(task, 30_000)
    settle_run_registry(2_000)

    assert run.status == :failed

    invalid = Enum.filter(run.assertions, &(&1.name == :invalid_assertion_value))

    assert match?([_, _], invalid),
           "expected exactly two :invalid_assertion_value records, got: " <>
             inspect(run.assertions, pretty: true)

    assert Enum.any?(
             invalid,
             &(&1.expected == :artifact_contains and &1.actual == "not-a-triple")
           )

    assert Enum.any?(
             invalid,
             &(&1.expected == :artifact_equals and &1.actual == {"plan", "planner"})
           )

    assert Enum.any?(run.assertions, &(&1.name == :terminal and &1.status == :passed)),
           "expected the :terminal assertion to pass, got: #{inspect(run.assertions, pretty: true)}"
  end

  # Wait for the parent's durable `wave_paused` marker (the composer subscribes
  # to the gates topic before appending it, so a decision broadcast after it
  # cannot be missed), then approve the gate case. Adapted from
  # composer_loop_test's parent_of/await_wave_paused pair, collapsed into one
  # bounded-poll flow.
  defp await_paused_then_approve(child_id, case_id, ctx) do
    opts = [tenant: ctx.tenant, actor: actor_for(ctx.tenant)]
    {:ok, child} = WorkflowRun.by_id(child_id, opts)

    paused? =
      Enum.reduce_while(1..500, false, fn _, _ ->
        {:ok, events} = WorkflowEvent.for_run(child.parent_run_id, opts)

        if Enum.any?(events, &(&1.kind == :wave_paused)) do
          {:halt, true}
        else
          Process.sleep(20)
          {:cont, false}
        end
      end)

    assert paused?, "wave_paused never appeared for parent #{child.parent_run_id}"
    assert {:ok, _} = Cases.decide(case_id, :approve, %{}, opts)
  end

  # Best-effort drain: give the orphaned wave executor time to deregister so a
  # late durable write cannot cross the sandbox teardown; never asserts.
  defp settle_run_registry(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.repeatedly(fn -> Registry.count(RunRegistry) end), :ok, fn count,
                                                                                        _ ->
      if count == 0 or System.monotonic_time(:millisecond) >= deadline do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, :ok}
      end
    end)
  end
end
