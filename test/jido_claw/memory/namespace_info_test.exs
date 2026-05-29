defmodule JidoClaw.Memory.NamespaceInfoTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Memory
  alias JidoClaw.Memory.Block
  alias JidoClaw.Workspaces.Resolver

  setup do
    tenant_id = seed_tenant("nsinfo")

    {:ok, ws} =
      Resolver.ensure_workspace(
        tenant_id,
        "/tmp/nsinfo_test_#{System.unique_integer([:positive])}",
        []
      )

    {:ok, tenant_id: tenant_id, workspace: ws}
  end

  describe "namespace_info/1" do
    test "resolves a workspace scope, labels the namespace, and counts blocks", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      for label <- ["style_guide", "conventions"] do
        assert {:ok, _} =
                 Block.write(
                   %{
                     scope_kind: :workspace,
                     workspace_id: ws.id,
                     label: label,
                     value: "v-#{label}",
                     source: :user
                   },
                   tenant: tenant_id,
                   actor: actor_for(tenant_id)
                 )
      end

      result = Memory.namespace_info(%{tenant_id: tenant_id, workspace_uuid: ws.id})

      assert %{namespace: "workspace:" <> _, blocks_count: 2, scope: %{scope_kind: :workspace}} =
               result

      assert result.namespace == "workspace:#{ws.id}"
    end

    test "returns nil when the scope is unresolvable (no tenant)" do
      assert Memory.namespace_info(%{}) == nil
    end

    test "returns nil for non-map input" do
      assert Memory.namespace_info(nil) == nil
    end
  end
end
