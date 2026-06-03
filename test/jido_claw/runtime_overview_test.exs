defmodule JidoClaw.RuntimeOverviewTest do
  use JidoClaw.TenantCase, async: false

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
  end
end
