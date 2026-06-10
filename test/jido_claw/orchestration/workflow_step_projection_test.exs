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
  alias JidoClaw.Test.SecretErrorStub
  alias JidoClaw.Web.WorkflowsLive
  alias Phoenix.Component
  alias Phoenix.HTML.Safe

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

    # The fixture's per-step deadline rode compiler -> middleware -> Allocate
    # end-to-end (normalized at compile, string-keyed on jsonb read).
    assert t.deadline == %{"within" => 300, "due_soon" => 60}
    assert is_nil(r.deadline)

    # depends_on rode the same rails (T3-1): the declared union on synthesize,
    # the column default on edge-less steps (the middleware omits []).
    assert s.depends_on == ["run_tests", "review_code"]
    assert t.depends_on == []
    assert r.depends_on == []

    collect = by_name[":__collect__"]
    assert collect.step_type == "collect"
    assert collect.status == :completed
    # The synthetic collect lists every NAMED step, so it never renders
    # isolated in the DAG graph.
    assert collect.depends_on == ["run_tests", "review_code", "synthesize"]
  end

  test "static metadata (deadline) projects from a started-less step_completed", ctx do
    {:ok, run} =
      WorkflowRun.create(%{name: "deadline-late-row"},
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

    # No step_started ever fired for this step — the completed event alone
    # must create the row WITH its static deadline metadata.
    {:ok, _} =
      WorkflowLog.append(
        run,
        :step_completed,
        %{
          step: ":step_1",
          name: "late",
          step_type: "agent",
          deadline: %{within: 120},
          output: %{"result" => "ok"}
        },
        scope(ctx)
      )

    {:ok, [step]} = WorkflowStep.for_run(run.id, scope(ctx))
    assert step.name == "late"
    assert step.status == :completed
    assert is_nil(step.started_at)
    assert step.deadline == %{"within" => 120}
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
    assert Enum.count(expanded.assigns.steps) == 4
    assert Enum.any?(expanded.assigns.steps, &(&1.name == "run_tests"))

    # Toggling again collapses.
    assert {:noreply, collapsed} =
             WorkflowsLive.handle_event("toggle_steps", %{"id" => run.id}, expanded)

    assert collapsed.assigns.expanded_run_id == nil
    assert collapsed.assigns.steps == []
  end

  test "deadline badges render in the runs table and the steps sub-table (T2-1)", ctx do
    {_value, run} = run_skill(dag_skill(), ctx)

    # Forge an overdue active run: 60s policy, started 5 minutes ago
    # (set_status corruption-sim precedent — bypasses the event log).
    {:ok, late} =
      WorkflowRun.create(%{name: "late-run", config: %{deadline: %{within: 60}}},
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    {:ok, late} =
      late
      |> Ash.Changeset.for_update(
        :set_status,
        %{status: :running, started_at: DateTime.add(DateTime.utc_now(), -300, :second)},
        tenant: ctx.tenant,
        authorize?: false
      )
      |> Ash.update()

    {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))

    html =
      render_workflows_html(%{
        runs: [run, late],
        expanded_run_id: run.id,
        steps: steps,
        steps_view: :table
      })

    # The overdue run renders a red badge carrying the lateness amount.
    assert html =~ "badge-red"
    assert html =~ ~r/overdue \+\d+[smh]/

    # The deadlined step completed inside its 300s window — frozen on-time
    # (green), while policy-less rows render the em-dash placeholder.
    assert html =~ "on time"
    assert html =~ "—"
  end

  test "expand prebuilds step_graph; the Graph/Table toggle flips steps_view (T3-2)", ctx do
    {_value, run} = run_skill(dag_skill(), ctx)

    socket = build_socket(actor_for(ctx.tenant))

    assert {:noreply, expanded} =
             WorkflowsLive.handle_event("toggle_steps", %{"id" => run.id}, socket)

    # Graph is the default view; the layout was prebuilt from the step rows
    # (4 nodes; the declared + collect edges produced segments).
    assert expanded.assigns.steps_view == :graph
    assert %{nodes: nodes, segments: segments} = expanded.assigns.step_graph
    assert Enum.count(nodes) == 4
    assert segments != []

    # The graph render shows metadata-only node boxes incl. the friendly
    # collect label.
    graph_html =
      render_workflows_html(%{
        runs: [run],
        expanded_run_id: run.id,
        steps: expanded.assigns.steps,
        step_graph: expanded.assigns.step_graph
      })

    assert graph_html =~ "collect"
    assert graph_html =~ "run_tests"

    # Explicit literal matching flips the view; junk values are ignored
    # (never String.to_atom on params).
    assert {:noreply, table} =
             WorkflowsLive.handle_event("set_steps_view", %{"view" => "table"}, expanded)

    assert table.assigns.steps_view == :table

    assert {:noreply, back} =
             WorkflowsLive.handle_event("set_steps_view", %{"view" => "graph"}, table)

    assert back.assigns.steps_view == :graph

    assert {:noreply, ignored} =
             WorkflowsLive.handle_event("set_steps_view", %{"view" => "evil_atom"}, back)

    assert ignored.assigns.steps_view == :graph

    # Collapse resets the graph and the view choice.
    assert {:noreply, collapsed} =
             WorkflowsLive.handle_event("toggle_steps", %{"id" => run.id}, back)

    assert collapsed.assigns.step_graph == nil
    assert collapsed.assigns.steps_view == :graph
  end

  test "reveal toggles exactly one run to auditor scope; refresh preserves it (T2-2)", ctx do
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "echo_test" => %{
        module: EchoStub,
        description: "test-only echo template",
        model: :fast,
        max_iterations: 1
      },
      "secret_test" => %{
        module: SecretErrorStub,
        description: "test-only secret-error template",
        model: :fast,
        max_iterations: 1
      }
    })

    secret = SecretErrorStub.secret()

    skill = %JidoClaw.Skills{
      name: "wsp_reveal",
      synthesis: "s",
      steps: [
        %{"name" => "leak", "template" => "secret_test", "task" => "fail with a secret"},
        %{"name" => "ok", "template" => "echo_test", "task" => "succeed"}
      ]
    }

    {:ok, reactor} = Compiler.compile(skill)

    # The leak step errors, failing the run; the ok step completes with output.
    assert {:error, _reason, run} =
             ReactorRunner.run(reactor, %{extra_context: ""},
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               name: skill.name,
               async?: true,
               context: %{tenant_id: ctx.tenant, project_dir: File.cwd!()}
             )

    {:ok, other} =
      WorkflowRun.create(%{name: "unrevealed"},
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))
    # Table view: the reveal pins assert table cells (error/output columns).
    base = %{runs: [run, other], expanded_run_id: run.id, steps: steps, steps_view: :table}

    # Operator: no secret anywhere (here the truncation cut even the
    # [REDACTED] marker — the Reactor error dump is long and the secret sits
    # past 200 chars; redact-before-truncate ordering is unit-pinned in
    # VisibilityTest), no Output column, no payload content.
    operator_html = render_workflows_html(base)
    refute operator_html =~ secret
    refute operator_html =~ ">Output</th>"
    refute operator_html =~ "echoed"
    assert operator_html =~ "Reveal payloads"
    refute operator_html =~ "Hide payloads"

    # Reveal event toggles membership for exactly that run.
    socket = build_socket(actor_for(ctx.tenant))

    assert {:noreply, revealed_socket} =
             WorkflowsLive.handle_event("reveal", %{"id" => run.id}, socket)

    assert MapSet.member?(revealed_socket.assigns.reveal_runs, run.id)

    # Auditor render: Output column + payload content appear and the now
    # UNTRUNCATED error shows the scrub marker at the secret's position —
    # never the secret itself. The other run's button stays "Reveal payloads".
    auditor_html = render_workflows_html(Map.put(base, :reveal_runs, MapSet.new([run.id])))
    refute auditor_html =~ secret
    assert auditor_html =~ "[REDACTED:API_KEY]"
    assert auditor_html =~ ">Output</th>"
    assert auditor_html =~ "echoed"
    assert auditor_html =~ "Hide payloads"
    assert auditor_html =~ "Reveal payloads"

    # Toggle off restores operator scope.
    assert {:noreply, hidden_socket} =
             WorkflowsLive.handle_event("reveal", %{"id" => run.id}, revealed_socket)

    refute MapSet.member?(hidden_socket.assigns.reveal_runs, run.id)

    # The 30s refresh re-fetches data but preserves reveal + expansion state.
    primed =
      Component.assign(revealed_socket,
        expanded_run_id: run.id,
        replay_blocked: %{run.id => %{reason: :irreversible}}
      )

    assert {:noreply, refreshed} =
             WorkflowsLive.handle_info(:refresh_deadlines, primed)

    assert MapSet.member?(refreshed.assigns.reveal_runs, run.id)
    assert refreshed.assigns.expanded_run_id == run.id
    assert refreshed.assigns.replay_blocked == %{run.id => %{reason: :irreversible}}
    assert Enum.any?(refreshed.assigns.runs, &(&1.id == run.id))
    assert Enum.any?(refreshed.assigns.steps, &(&1.name == "leak"))
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
    seqs =
      results
      |> Enum.map(fn {:ok, e} -> e.seq end)
      |> Enum.sort()

    assert seqs == Enum.to_list(2..11)

    {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))

    names =
      steps
      |> Enum.map(& &1.name)
      |> Enum.sort()

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
        %{
          "name" => "run_tests",
          "template" => "echo_test",
          "task" => "test",
          "deadline" => %{"within" => 300, "due_soon" => 60}
        },
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
        replay_blocked: %{},
        reveal_runs: MapSet.new(),
        steps_view: :graph,
        step_graph: nil,
        flash: %{}
      }
    }
  end

  # Render the full page template from a hand-built assigns map (the
  # replay_test render_workflows precedent), with overridable view state.
  defp render_workflows_html(overrides) do
    %{
      __changed__: %{},
      flash: %{},
      runs: [],
      runs_error: nil,
      expanded_run_id: nil,
      steps: [],
      steps_error: nil,
      replay_blocked: %{},
      reveal_runs: MapSet.new(),
      steps_view: :graph,
      step_graph: nil
    }
    |> Map.merge(overrides)
    |> WorkflowsLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp scope(%{tenant: tenant}), do: [tenant: tenant, actor: actor_for(tenant)]
end
