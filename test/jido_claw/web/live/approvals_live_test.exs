defmodule JidoClaw.Web.ApprovalsLiveTest do
  @moduledoc """
  Direct-socket test (per `dashboard_live_test.exs`) of the `/approvals`
  inbox: an approve `handle_event` routes through `Cases.decide/4` and resumes
  the paused run to completion.
  """
  use JidoClaw.TenantCase

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Web.ApprovalsLive

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gates-live")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
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
