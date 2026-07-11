defmodule JidoClaw.Memory.NamespaceInfoTest do
  use JidoClaw.TenantCase, async: true

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

    test "blocks_count counts label-DEDUPED rows across the chain, not raw rows", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      {:ok, session} = seed_session(tenant_id, ws.id)
      actor = actor_for(tenant_id)

      # The SAME label at two chain scopes (session overrides workspace — one
      # deduped row) plus one unique label: 3 raw rows, 2 distinct labels. A
      # raw row count would report 3.
      for attrs <- [
            %{scope_kind: :workspace, workspace_id: ws.id, label: "style_guide", value: "ws"},
            %{scope_kind: :session, session_id: session.id, label: "style_guide", value: "sess"},
            %{scope_kind: :workspace, workspace_id: ws.id, label: "conventions", value: "c"}
          ] do
        assert {:ok, _} =
                 Block.write(Map.put(attrs, :source, :user), tenant: tenant_id, actor: actor)
      end

      result =
        Memory.namespace_info(%{
          tenant_id: tenant_id,
          session_uuid: session.id,
          workspace_uuid: ws.id
        })

      assert %{namespace: "session:" <> _, blocks_count: 2, scope: %{scope_kind: :session}} =
               result
    end

    test "returns nil when the scope is unresolvable (no tenant)" do
      assert Memory.namespace_info(%{}) == nil
    end

    test "returns nil for non-map input" do
      assert Memory.namespace_info(nil) == nil
    end
  end
end
