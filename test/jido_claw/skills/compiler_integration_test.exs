defmodule JidoClaw.Skills.CompilerIntegrationTest do
  @moduledoc """
  End-to-end: compile a skill and run the resulting `%Reactor{}` through the
  full `ReactorRunner` + `ReactorMiddleware` + `WorkflowEvent` envelope with
  EchoStub agents, for all three modes.

  Asserts the three properties the migration must preserve:

    * **scope propagation** — every spawned child agent's `tool_context`
      receives the full scope (tenant_id, actor, session_uuid, workspace_uuid)
      and a **shared** `workspace_id` across steps.
    * **result accumulation + persistence** — `steps_completed` equals the
      agent-step count (not 1 for sequential, not inflated by `:__collect__`),
      and `WorkflowRun.result` is the build_result map.
    * **broadcast timing** — a subscriber sees `run_started` only once status is
      `:running`, then `run_completed`.

  `async?: true` runs steps on the `Reactor.TaskSupervisor` and `AgentRunner`
  always writes durable rows, so this owns a shared sandbox (`TenantCase`,
  `async: false`).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Test.EchoStub

  setup do
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "echo_test" => %{
        module: EchoStub,
        description: "test-only echo template",
        model: :fast,
        max_iterations: 1
      }
    })

    Application.put_env(:jido_claw, :echo_stub_target, self())

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} = seed_full(tenant_label: "skci")
    RunPubSub.subscribe_all()

    {:ok, tenant: tenant, workspace: workspace, session: session}
  end

  test "sequential: all steps accumulate, share workspace_id, carry full scope", ctx do
    skill = %JidoClaw.Skills{
      name: "seq_smoke",
      synthesis: "summary",
      steps: [
        %{"template" => "echo_test", "task" => "a"},
        %{"template" => "echo_test", "task" => "b"},
        %{"template" => "echo_test", "task" => "c"}
      ]
    }

    {value, run} = run_skill(skill, ctx)

    # steps_completed is the agent-step count (3), NOT 1, NOT inflated by collect.
    assert value.steps_completed == 3
    assert run.result["steps_completed"] == 3

    tcs = collect_tool_contexts(3)
    assert [_, _, _] = tcs
    assert_full_scope(tcs, ctx)

    assert_run_lifecycle(run.id)
  end

  test "dag: parallel + dependent steps all run, accumulate, carry full scope", ctx do
    skill = %JidoClaw.Skills{
      name: "dag_smoke",
      synthesis: "summary",
      steps: [
        %{"name" => "run_tests", "template" => "echo_test", "task" => "test"},
        %{"name" => "review_code", "template" => "echo_test", "task" => "review"},
        %{
          "name" => "synthesize",
          "template" => "echo_test",
          "task" => "combine",
          "depends_on" => ["run_tests", "review_code"]
        }
      ]
    }

    {value, run} = run_skill(skill, ctx)

    assert value.steps_completed == 3
    assert run.result["steps_completed"] == 3

    tcs = collect_tool_contexts(3)
    assert [_, _, _] = tcs
    assert_full_scope(tcs, ctx)

    assert_run_lifecycle(run.id)
  end

  test "iterative: gen/eval loop caps at max_iterations, results accumulate", ctx do
    skill = %JidoClaw.Skills{
      name: "iter_smoke",
      mode: "iterative",
      max_iterations: 1,
      synthesis: "summary",
      steps: [
        %{
          "name" => "implement",
          "role" => "generator",
          "template" => "echo_test",
          "task" => "build"
        },
        %{"name" => "verify", "role" => "evaluator", "template" => "echo_test", "task" => "check"}
      ]
    }

    {value, run} = run_skill(skill, ctx)

    # gen + eval (EchoStub never passes; max_iterations: 1) → 2 results.
    assert value.steps_completed == 2
    assert run.result["steps_completed"] == 2

    tcs = collect_tool_contexts(2)
    assert [_, _] = tcs
    assert_full_scope(tcs, ctx)

    assert_run_lifecycle(run.id)
  end

  test "the event timeline projects to :completed and includes the __collect__ step", ctx do
    skill = %JidoClaw.Skills{
      name: "tl_smoke",
      synthesis: "s",
      steps: [%{"template" => "echo_test", "task" => "a"}]
    }

    {_value, run} = run_skill(skill, ctx)
    _ = collect_tool_contexts(1)

    {:ok, events} =
      WorkflowEvent.for_run(run.id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    kinds = Enum.map(events, & &1.kind)

    assert run.status == :completed
    assert match?([:run_started | _], kinds)
    assert match?([:run_completed | _], Enum.reverse(kinds))
    # one agent step + the synthetic collect step each emit a started/completed pair.
    assert Enum.count(kinds, &(&1 == :step_started)) == 2
    assert Enum.count(kinds, &(&1 == :step_completed)) == 2
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_skill(skill, ctx) do
    {:ok, reactor} = Compiler.compile(skill)

    scope = %{
      tenant_id: ctx.tenant,
      session_id: "rt-sess",
      session_uuid: ctx.session.id,
      workspace_id: "shared-ws",
      workspace_uuid: ctx.workspace.id,
      project_dir: File.cwd!()
    }

    assert {:ok, value, run} =
             ReactorRunner.run(reactor, %{extra_context: ""},
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               name: skill.name,
               async?: true,
               context: scope
             )

    {value, run}
  end

  defp assert_full_scope(tcs, ctx) do
    Enum.each(tcs, fn tc ->
      assert tc.tenant_id == ctx.tenant
      assert tc.actor == actor_for(ctx.tenant)
      assert tc.session_uuid == ctx.session.id
      assert tc.workspace_uuid == ctx.workspace.id
      # shared across every step (not a per-step "wf_<tag>" fallback).
      assert tc.workspace_id == "shared-ws"
    end)
  end

  # Broadcast timing: run_started arrives carrying :running (never :pending),
  # then run_completed.
  defp assert_run_lifecycle(run_id) do
    assert_receive {:run_started, ^run_id, %{status: :running}}, 5_000
    assert_receive {:run_completed, ^run_id, %{status: :completed}}, 5_000
  end

  defp collect_tool_contexts(n) do
    for _ <- 1..n do
      receive do
        {:echo_stub, :tool_context, tc} -> tc
      after
        5_000 -> flunk("did not receive #{n} tool_context messages")
      end
    end
  end
end
