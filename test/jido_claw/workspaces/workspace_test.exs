defmodule JidoClaw.Workspaces.WorkspaceTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Workspaces.Resolver
  alias JidoClaw.Workspaces.Workspace

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "register/1" do
    test "creates a CLI-style workspace with the default :disabled policies" do
      attrs = %{
        tenant_id: "default",
        path: "/tmp/proj-#{System.unique_integer([:positive])}",
        name: "demo",
        user_id: nil
      }

      assert {:ok, ws} = Workspace.register(attrs)
      assert ws.tenant_id == "default"
      assert ws.user_id == nil
      assert ws.embedding_policy == :disabled
      assert ws.consolidation_policy == :disabled
      assert ws.archived_at == nil
      assert ws.metadata == %{}
    end

    test "respects explicit :default for embedding_policy and consolidation_policy" do
      tenant = "default"
      path = "/tmp/policy-#{System.unique_integer([:positive])}"

      assert {:ok, ws} =
               Workspace.register(%{
                 tenant_id: tenant,
                 path: path,
                 name: "demo",
                 embedding_policy: :default,
                 consolidation_policy: :default
               })

      assert ws.embedding_policy == :default
      assert ws.consolidation_policy == :default
    end

    test "policies are independent — flipping one doesn't move the other" do
      tenant = "default"
      path = "/tmp/policy-indep-#{System.unique_integer([:positive])}"

      {:ok, ws} = Workspace.register(%{tenant_id: tenant, path: path, name: "demo"})
      assert ws.embedding_policy == :disabled
      assert ws.consolidation_policy == :disabled

      {:ok, ws2} = Workspace.set_embedding_policy(ws, :default)
      assert ws2.embedding_policy == :default
      assert ws2.consolidation_policy == :disabled

      {:ok, ws3} = Workspace.set_consolidation_policy(ws2, :local_only)
      assert ws3.embedding_policy == :default
      assert ws3.consolidation_policy == :local_only
    end
  end

  describe "partial-unique identities" do
    test "the same path under one tenant for two CLI rows raises" do
      tenant = "default"
      path = "/tmp/cli-collision-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Workspace.register(%{tenant_id: tenant, path: path, name: "a"})
      # Direct register/1 without resolver-supplied upsert_identity falls
      # back to a plain insert; the partial-unique :unique_user_path_cli
      # index rejects the duplicate.
      assert {:error, _} = Workspace.register(%{tenant_id: tenant, path: path, name: "b"})
    end
  end

  describe "resolver upsert preservation (Decision 10)" do
    test "policies set on initial register are not overwritten on idempotent resolver call" do
      tenant = "default"
      path = "/tmp/policy-preserve-#{System.unique_integer([:positive])}"

      {:ok, first} =
        Resolver.ensure_workspace(tenant, path,
          embedding_policy: :default,
          consolidation_policy: :default
        )

      assert first.embedding_policy == :default
      assert first.consolidation_policy == :default

      # Second call with default :disabled — must NOT reset the user-set
      # values because :register's upsert_fields is restricted to
      # [:updated_at] only.
      {:ok, second} = Resolver.ensure_workspace(tenant, path)

      assert second.id == first.id
      assert second.embedding_policy == :default
      assert second.consolidation_policy == :default
    end
  end
end
