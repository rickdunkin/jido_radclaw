defmodule JidoClaw.Web.ApprovalsLiveTest do
  @moduledoc """
  Direct-socket test (per `dashboard_live_test.exs`) of the `/approvals`
  inbox: an approve `handle_event` routes through `Cases.decide/4` and resumes
  the paused run to completion.
  """
  # async: false — setup wipes the global :gate_test_markers named ETS table
  # (TestIrreversibleWrite.reset/0) and the approve path's after_approved
  # hook writes to and reads behavior() from that same shared table; the
  # marker-asserting gate cohort stays sync.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.NeedsInput
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.ToolApprovals
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Web.ApprovalsLive
  alias Phoenix.HTML.Safe

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gates-live")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  defp open_tool_call(tenant) do
    scope = %{tenant_id: tenant, actor: actor_for(tenant)}
    {:pending, gate} = ToolApprovals.request(scope, "git_commit", %{message: "x"})
    gate
  end

  test "render shows the gate DSL's typed fields (title, label, widgets)", %{
    tenant: tenant,
    actor: actor
  } do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "render-ws-#{uniq}", workspace_path: "/tmp/render-ws-#{uniq}"}

    {:ok, {:paused, case_id}, _run} =
      ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor)

    {:ok, gate} = AgentCase.by_id(case_id, tenant: tenant, actor: actor)

    html =
      %{
        __changed__: %{},
        gates: [gate],
        flash: %{}
      }
      |> ApprovalsLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    # DSL-seeded title + the declared :comment textarea with its label.
    assert html =~ "Approve irreversible write (test)"
    assert html =~ "Comment"
    assert html =~ ~s(<textarea name="fields[comment]")
    assert html =~ "Abandon run"
  end

  test "approve handle_event resumes the paused run", %{tenant: tenant, actor: actor} do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "live-ws-#{uniq}", workspace_path: "/tmp/live-ws-#{uniq}"}

    {:ok, {:paused, case_id}, run} =
      ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor)

    # A web actor carries a uuid user_id (recorded as decided_by_id).
    web_actor = %{user_id: Ecto.UUID.generate(), tenant_id: tenant}
    socket = build_socket(web_actor)

    assert {:noreply, updated} = ApprovalsLive.handle_event("approve", %{"id" => case_id}, socket)
    # Inbox reloaded to empty after the decision.
    assert updated.assigns.gates == []

    {:ok, completed} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)
    assert completed.status == :completed
  end

  test "renders a tool-call case with its tool name and no Abandon button", %{tenant: tenant} do
    gate = open_tool_call(tenant)

    html =
      %{__changed__: %{}, gates: [gate], flash: %{}}
      |> ApprovalsLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    # ToolCallGate DSL title + the tool name; a run-less case offers no Abandon.
    assert html =~ "Approve tool call"
    assert html =~ "git_commit"
    assert html =~ ~s(value="approve")
    refute html =~ "Abandon run"
  end

  test "renders a tool-call case's agent_template and arguments from details", %{tenant: tenant} do
    scope = %{tenant_id: tenant, actor: actor_for(tenant), agent_template: "coder"}
    {:pending, gate} = ToolApprovals.request(scope, "git_commit", %{message: "ship it"})

    html =
      %{__changed__: %{}, gates: [gate], flash: %{}}
      |> ApprovalsLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "template:"
    assert html =~ "coder"
    assert html =~ "args:"
  end

  test "approve handle_event on a tool-call case decides it and clears the inbox", %{
    tenant: tenant
  } do
    gate = open_tool_call(tenant)
    web_actor = %{user_id: Ecto.UUID.generate(), tenant_id: tenant}
    socket = build_socket(web_actor)

    assert {:noreply, updated} = ApprovalsLive.handle_event("approve", %{"id" => gate.id}, socket)
    assert updated.assigns.gates == []

    {:ok, decided} = AgentCase.by_id(gate.id, tenant: tenant, actor: web_actor)
    assert decided.status == :approved
  end

  defp build_socket(actor) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_actor: actor,
        gates: [],
        gates_refresh_pending: false,
        flash: %{}
      }
    }
  end

  # Item 7 PR-4: the needs-input surface — question + required answer box,
  # the injection promise ONLY when injectable, no Abandon; the decide event
  # maps the answer box to the decision comment, and a blank answer flashes
  # the server's :answer_required refusal.
  describe "needs-input gates (item 7 PR-4)" do
    setup do
      %{tenant_id: tenant, session: session} = seed_full(tenant_label: "gates-live-ni")
      {:ok, ni_tenant: tenant, ni_actor: actor_for(tenant), ni_session: session}
    end

    defp raise_needs_input_case(ctx, overrides) do
      scope =
        Map.merge(
          %{
            tenant_id: ctx.ni_tenant,
            actor: ctx.ni_actor,
            session_uuid: ctx.ni_session.id,
            session_id: ctx.ni_session.external_id,
            workflow_run_id: nil,
            template_name: "coder",
            step_name: "v-step",
            vendor?: true
          },
          Map.new(overrides)
        )

      {:ok, agent_case} = NeedsInput.raise_case(scope, "Which database should I use?")
      agent_case
    end

    defp render_gates(gates) do
      %{__changed__: %{}, gates: gates, flash: %{}}
      |> ApprovalsLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "renders question + answer box + injection promise; no Abandon", ctx do
      gate = raise_needs_input_case(ctx, [])
      html = render_gates([gate])

      assert html =~ "Which database should I use?"
      assert html =~ ~s(<textarea name="answer")
      # Injectable (vendor + session-keyed): the resume_hint's claim promise
      # renders ("claims it once" is hint-only — the gate title/description
      # render on EVERY needs-input case).
      assert html =~ "claims it once"
      refute html =~ "Abandon run"
    end

    test "a non-injectable case renders the answer box WITHOUT the injection promise", ctx do
      gate = raise_needs_input_case(ctx, vendor?: false)
      html = render_gates([gate])

      assert html =~ ~s(<textarea name="answer")
      refute html =~ "claims it once"
    end

    test "decide maps the answer box to the decision comment", ctx do
      gate = raise_needs_input_case(ctx, [])
      web_actor = %{user_id: Ecto.UUID.generate(), tenant_id: ctx.ni_tenant}
      socket = build_socket(web_actor)

      assert {:noreply, updated} =
               ApprovalsLive.handle_event(
                 "decide",
                 %{"case_id" => gate.id, "decision" => "approve", "answer" => "Use postgres"},
                 socket
               )

      assert updated.assigns.gates == []

      {:ok, decided} = AgentCase.by_id(gate.id, tenant: ctx.ni_tenant, actor: ctx.ni_actor)
      assert decided.status == :approved
      assert decided.decision_comment == "Use postgres"
    end

    test "a blank-answer approve flashes the :answer_required refusal; case stays pending",
         ctx do
      gate = raise_needs_input_case(ctx, [])
      web_actor = %{user_id: Ecto.UUID.generate(), tenant_id: ctx.ni_tenant}
      socket = build_socket(web_actor)

      assert {:noreply, updated} =
               ApprovalsLive.handle_event(
                 "decide",
                 %{"case_id" => gate.id, "decision" => "approve", "answer" => "   "},
                 socket
               )

      assert Phoenix.Flash.get(updated.assigns.flash, :error) =~ "needs an answer"

      {:ok, reloaded} = AgentCase.by_id(gate.id, tenant: ctx.ni_tenant, actor: ctx.ni_actor)
      assert reloaded.status == :pending
    end
  end
end
