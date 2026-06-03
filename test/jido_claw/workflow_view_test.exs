defmodule JidoClaw.WorkflowViewTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.WorkflowStatus
  alias JidoClaw.WorkflowView

  setup do
    tenant_a = seed_tenant("workflow-view-a")
    tenant_b = seed_tenant("workflow-view-b")
    {:ok, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  test "list/1 and workflow_status hide runs from other tenants", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b
  } do
    {:ok, run_a} =
      WorkflowRun.create(%{name: "visible", workflow_type: "audit"},
        tenant: tenant_a,
        actor: actor_for(tenant_a)
      )

    {:ok, run_b} =
      WorkflowRun.create(%{name: "hidden", workflow_type: "audit"},
        tenant: tenant_b,
        actor: actor_for(tenant_b)
      )

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant_a})
    assert Enum.map(view.active_runs, & &1.run_id) == [run_a.id]

    assert {:error, :not_found} = WorkflowView.snapshot(run_b.id, %{tenant_id: tenant_a})

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant_a}})
    assert status["active_count"] == 1
    assert Enum.map(status["active_runs"], & &1["run_id"]) == [run_a.id]
  end

  test "tenant scope is required" do
    assert {:error, :tenant_required} = WorkflowView.list(%{})
    assert {:error, %{code: :tenant_required}} = WorkflowStatus.run(%{}, %{tool_context: %{}})
  end
end
