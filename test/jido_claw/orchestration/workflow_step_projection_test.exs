defmodule JidoClaw.Orchestration.WorkflowStepProjectionTest do
  @moduledoc """
  WS2/WS3/WS10: a real compiled skill through `ReactorRunner` projects one
  tenant-scoped `WorkflowStep` row per logical step (from the enriched
  `step_*` events), the dashboard step view loads them, and the run lifecycle
  emits `[:jido_claw, :workflow, :event]` Trace telemetry.

  `async?: true` skills spawn agents that write durable rows, so this owns a
  shared sandbox (`TenantCase`, `async: false`).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Web.WorkflowsLive

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

    %{tenant_id: tenant, workspace: workspace, session: session} = seed_full(tenant_label: "wsp")
    {:ok, tenant: tenant, workspace: workspace, session: session}
  end

  test "a dag skill projects one step row per step with name/type/sequence/output", ctx do
    {_value, run} = run_skill(dag_skill(), ctx)

    {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))

    by_name = Map.new(steps, &{&1.name, &1})

    # 3 named agent steps + the synthetic collect step.
    assert map_size(by_name) == 4
    assert %{"run_tests" => t, "review_code" => r, "synthesize" => s} = by_name

    for step <- [t, r, s] do
      assert step.status == :completed
      assert step.step_type == "agent"
      assert step.tenant_id == ctx.tenant
      assert %DateTime{} = step.started_at
      assert %DateTime{} = step.completed_at
      # The JSON-safe output summary from the step_completed payload.
      assert is_map(step.output)
      assert is_binary(step.output["result"])
    end

    # Positional sequence parsed from the Reactor ids (:step_1..:step_3).
    assert Enum.sort([t.sequence, r.sequence, s.sequence]) == [1, 2, 3]

    collect = by_name[":__collect__"]
    assert collect.step_type == "collect"
    assert collect.status == :completed
  end

  test "a tenant cannot read another tenant's step rows", ctx do
    {_value, run} = run_skill(dag_skill(), ctx)

    tenant_b = seed_tenant("wsp-b")
    actor_b = actor_for(tenant_b)

    assert {:ok, []} = WorkflowStep.for_run(run.id, tenant: tenant_b, actor: actor_b)
    assert {:ok, [_ | _]} = WorkflowStep.for_run(run.id, scope(ctx))
  end

  test "the dashboard step view loads a run's steps on toggle", ctx do
    {_value, run} = run_skill(dag_skill(), ctx)

    socket = build_socket(actor_for(ctx.tenant))

    assert {:noreply, expanded} =
             WorkflowsLive.handle_event("toggle_steps", %{"id" => run.id}, socket)

    assert expanded.assigns.expanded_run_id == run.id
    assert expanded.assigns.steps_error == nil
    assert length(expanded.assigns.steps) == 4
    assert Enum.any?(expanded.assigns.steps, &(&1.name == "run_tests"))

    # Toggling again collapses.
    assert {:noreply, collapsed} =
             WorkflowsLive.handle_event("toggle_steps", %{"id" => run.id}, expanded)

    assert collapsed.assigns.expanded_run_id == nil
    assert collapsed.assigns.steps == []
  end

  test "concurrent named step events project rows without poisoning appends", ctx do
    {:ok, run} =
      WorkflowRun.create(%{name: "concurrent-steps"},
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

    distinct =
      for i <- 1..6 do
        Task.async(fn ->
          WorkflowLog.append(
            run,
            :step_started,
            %{step: ":step_#{i}", name: "s#{i}", step_type: "agent"},
            scope(ctx)
          )
        end)
      end

    # Four concurrent events for ONE logical step — the identity upsert must
    # serialize under the run lock, never duplicate or unique-violate.
    shared =
      for _ <- 1..4 do
        Task.async(fn ->
          WorkflowLog.append(
            run,
            :step_started,
            %{step: ":step_9", name: "shared", step_type: "agent"},
            scope(ctx)
          )
        end)
      end

    results = Task.await_many(distinct ++ shared, 15_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # Every append survived the projection (seq gap-free), and the rows are
    # one-per-logical-step.
    seqs = results |> Enum.map(fn {:ok, e} -> e.seq end) |> Enum.sort()
    assert seqs == Enum.to_list(2..11)

    {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))
    names = steps |> Enum.map(& &1.name) |> Enum.sort()
    assert names == Enum.sort(["shared" | Enum.map(1..6, &"s#{&1}")])
  end

  test "the run lifecycle emits [:jido_claw, :workflow, :event] trace telemetry", ctx do
    handler_id = "wf-trace-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:jido_claw, :workflow, :event],
      fn _event, measurements, metadata, _config ->
        send(parent, {:wf_trace, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {_value, run} = run_skill(dag_skill(), ctx)
    run_id = run.id

    assert_receive {:wf_trace, _meas, %{event: :run_started, status: :running, run_id: ^run_id}},
                   5_000

    assert_receive {:wf_trace, meas,
                    %{event: :run_completed, status: :completed, run_id: ^run_id} = meta},
                   5_000

    assert meta.tenant_id == ctx.tenant
    assert meta.name == "wsp_dag"
    assert is_integer(meas.duration_ms)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp dag_skill do
    %JidoClaw.Skills{
      name: "wsp_dag",
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
  end

  defp run_skill(skill, ctx) do
    {:ok, reactor} = Compiler.compile(skill)

    scope = %{
      tenant_id: ctx.tenant,
      session_id: "wsp-sess",
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

  defp build_socket(actor) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_actor: actor,
        runs: [],
        runs_error: nil,
        expanded_run_id: nil,
        steps: [],
        steps_error: nil,
        flash: %{}
      }
    }
  end

  defp scope(%{tenant: tenant}), do: [tenant: tenant, actor: actor_for(tenant)]
end
