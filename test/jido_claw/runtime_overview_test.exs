defmodule JidoClaw.RuntimeOverviewTest do
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Orchestration.ToolApprovals
  alias JidoClaw.RuntimeOverview

  test "snapshot/1 requires tenant scope" do
    assert {:error, :tenant_required} = RuntimeOverview.snapshot(%{})
  end

  test "snapshot/1 composes tenant-scoped projection views" do
    tenant_id = seed_tenant("runtime-overview")

    assert {:ok, overview} = RuntimeOverview.snapshot(%{tenant_id: tenant_id})
    assert overview.tenant_id == tenant_id
    assert overview.swarm.tenant_id == tenant_id
    assert overview.forge.tenant_id == tenant_id
    assert overview.workflows.tenant_id == tenant_id
    assert overview.approvals.pending_count == 0
  end

  test "snapshot/1 counts pending approval cases" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "overview-approvals")

    scope = %{
      tenant_id: tenant_id,
      session_uuid: session.id,
      session_id: session.external_id,
      actor: actor_for(tenant_id)
    }

    assert {:pending, _} = ToolApprovals.request(scope, "git_commit", %{message: "x"})

    assert {:ok, overview} = RuntimeOverview.snapshot(%{tenant_id: tenant_id})
    assert overview.approvals.pending_count == 1
  end
end
