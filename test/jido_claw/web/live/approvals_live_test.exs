defmodule JidoClaw.Web.ApprovalsLiveTest do
  @moduledoc """
  Direct-socket test (per `dashboard_live_test.exs`) of the `/approvals`
  inbox: an approve `handle_event` routes through `Cases.decide/4` and resumes
  the paused run to completion.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
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
end
