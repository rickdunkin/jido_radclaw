defmodule JidoClaw.Solutions.NetworkFacadeTest do
  @moduledoc """
  Regression coverage for `NetworkFacade.find_local/2` (Finding 5).

  Locks in:

    * Cross-workspace `:local` rows return `:not_found` even when the
      caller knows the UUID — the workspace_id pin closes the
      pre-fix broadcast leak.
    * Cross-workspace `:public` rows are admitted across workspaces
      within the same tenant.
    * Same-workspace `:shared` and `:local` rows return `{:ok, sol}`.
    * Cross-tenant rows are always `:not_found`.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Solutions.NetworkFacade

  setup do
    tenant_id = unique_tenant_id()
    ws_a = workspace_fixture(tenant_id, embedding_policy: :disabled)
    ws_b = workspace_fixture(tenant_id, embedding_policy: :disabled)
    {:ok, tenant_id: tenant_id, ws_a: ws_a, ws_b: ws_b}
  end

  describe "find_local/2 — cross-workspace scope" do
    test "cross-workspace :local row returns :not_found",
         %{tenant_id: tenant_id, ws_a: ws_a, ws_b: ws_b} do
      sol = solution_fixture(tenant_id, ws_b.id, "ws-b private content", sharing: :local)
      node_state = %{tenant_id: tenant_id, workspace_id: ws_a.id}

      assert NetworkFacade.find_local(sol.id, node_state) == :not_found
    end

    test "cross-workspace :shared row returns :not_found (only :public crosses)",
         %{tenant_id: tenant_id, ws_a: ws_a, ws_b: ws_b} do
      sol = solution_fixture(tenant_id, ws_b.id, "ws-b shared content", sharing: :shared)
      node_state = %{tenant_id: tenant_id, workspace_id: ws_a.id}

      assert NetworkFacade.find_local(sol.id, node_state) == :not_found
    end

    test "cross-workspace :public row returns {:ok, _}",
         %{tenant_id: tenant_id, ws_a: ws_a, ws_b: ws_b} do
      sol = solution_fixture(tenant_id, ws_b.id, "ws-b public content", sharing: :public)
      node_state = %{tenant_id: tenant_id, workspace_id: ws_a.id}

      assert {:ok, returned} = NetworkFacade.find_local(sol.id, node_state)
      assert returned.id == sol.id
    end
  end

  describe "find_local/2 — same-workspace scope" do
    test "same-workspace :local row returns {:ok, _}",
         %{tenant_id: tenant_id, ws_a: ws_a} do
      sol = solution_fixture(tenant_id, ws_a.id, "local row in ws-a", sharing: :local)
      node_state = %{tenant_id: tenant_id, workspace_id: ws_a.id}

      assert {:ok, returned} = NetworkFacade.find_local(sol.id, node_state)
      assert returned.id == sol.id
    end

    test "same-workspace :shared row returns {:ok, _}",
         %{tenant_id: tenant_id, ws_a: ws_a} do
      sol = solution_fixture(tenant_id, ws_a.id, "shared row in ws-a", sharing: :shared)
      node_state = %{tenant_id: tenant_id, workspace_id: ws_a.id}

      assert {:ok, returned} = NetworkFacade.find_local(sol.id, node_state)
      assert returned.id == sol.id
    end
  end

  describe "find_local/2 — cross-tenant" do
    test "row in another tenant returns :not_found",
         %{ws_a: ws_a} do
      other_tenant = unique_tenant_id()
      other_ws = workspace_fixture(other_tenant, embedding_policy: :disabled)
      sol = solution_fixture(other_tenant, other_ws.id, "other-tenant content", sharing: :public)

      node_state = %{tenant_id: ws_a.tenant_id, workspace_id: ws_a.id}
      assert NetworkFacade.find_local(sol.id, node_state) == :not_found
    end
  end
end
