defmodule JidoClaw.Workspaces.WorkspaceTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Workspaces.Resolver

  setup do
    %{tenant_id: seed_tenant("ws-test")}
  end

  describe "register/1" do
    test "creates a CLI-style workspace with the default :disabled policies", %{
      tenant_id: tenant_id
    } do
      attrs = %{
        path: "/tmp/proj-#{System.unique_integer([:positive])}",
        name: "demo",
        user_id: nil
      }

      assert {:ok, ws} = Workspace.register(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert ws.tenant_id == tenant_id
      assert ws.user_id == nil
      assert ws.embedding_policy == :disabled
      assert ws.consolidation_policy == :disabled
      assert ws.archived_at == nil
      assert ws.metadata == %{}
    end

    test "respects explicit :default for embedding_policy and consolidation_policy", %{
      tenant_id: tenant_id
    } do
      path = "/tmp/policy-#{System.unique_integer([:positive])}"

      assert {:ok, ws} =
               Workspace.register(
                 %{
                   path: path,
                   name: "demo",
                   embedding_policy: :default,
                   consolidation_policy: :default
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert ws.embedding_policy == :default
      assert ws.consolidation_policy == :default
    end

    test ":local_only is rejected at the attribute layer for both policies", %{
      tenant_id: tenant_id
    } do
      assert {:error, _} =
               Workspace.register(
                 %{
                   path: "/tmp/local-only-#{System.unique_integer([:positive])}",
                   name: "demo",
                   embedding_policy: :local_only
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert {:error, _} =
               Workspace.register(
                 %{
                   path: "/tmp/local-only-c-#{System.unique_integer([:positive])}",
                   name: "demo",
                   consolidation_policy: :local_only
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )
    end

    test "policies are independent — flipping one doesn't move the other", %{
      tenant_id: tenant_id
    } do
      path = "/tmp/policy-indep-#{System.unique_integer([:positive])}"

      {:ok, ws} =
        Workspace.register(%{path: path, name: "demo"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert ws.embedding_policy == :disabled
      assert ws.consolidation_policy == :disabled

      {:ok, ws2} =
        Workspace.set_embedding_policy(ws, :default,
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert ws2.embedding_policy == :default
      assert ws2.consolidation_policy == :disabled

      {:ok, ws3} =
        Workspace.set_consolidation_policy(ws2, :default,
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert ws3.embedding_policy == :default
      assert ws3.consolidation_policy == :default
    end
  end

  describe "partial-unique identities" do
    test "the same path under one tenant for two CLI rows raises", %{tenant_id: tenant_id} do
      path = "/tmp/cli-collision-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Workspace.register(%{path: path, name: "a"},
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      # Direct register/1 without resolver-supplied upsert_identity falls
      # back to a plain insert; the partial-unique :unique_user_path_cli
      # index rejects the duplicate.
      assert {:error, _} =
               Workspace.register(%{path: path, name: "b"},
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )
    end
  end

  describe "resolver upsert preservation (Decision 10)" do
    test "policies set on initial register are not overwritten on idempotent resolver call", %{
      tenant_id: tenant_id
    } do
      path = "/tmp/policy-preserve-#{System.unique_integer([:positive])}"

      {:ok, first} =
        Resolver.ensure_workspace(tenant_id, path,
          embedding_policy: :default,
          consolidation_policy: :default
        )

      assert first.embedding_policy == :default
      assert first.consolidation_policy == :default

      # Second call with default :disabled — must NOT reset the user-set
      # values because :register's upsert_fields is restricted to
      # [:updated_at] only.
      {:ok, second} = Resolver.ensure_workspace(tenant_id, path)

      assert second.id == first.id
      assert second.embedding_policy == :default
      assert second.consolidation_policy == :default
    end
  end
end
