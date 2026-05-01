defmodule JidoClaw.Workspaces.ResolverTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "ensure_workspace/3 — cross-tenant isolation" do
    test "the same path under two unauthenticated tenants creates two distinct rows" do
      path = "/tmp/cross-tenant-#{System.unique_integer([:positive])}"

      assert {:ok, t1_ws} = Resolver.ensure_workspace("tenant_a", path)
      assert {:ok, t2_ws} = Resolver.ensure_workspace("tenant_b", path)

      assert t1_ws.id != t2_ws.id
      assert t1_ws.tenant_id == "tenant_a"
      assert t2_ws.tenant_id == "tenant_b"
      assert t1_ws.user_id == nil
      assert t2_ws.user_id == nil
      assert t1_ws.path == t2_ws.path
    end

    test "idempotent reuse within a tenant returns the same row id" do
      path = "/tmp/idempotent-#{System.unique_integer([:positive])}"

      assert {:ok, first} = Resolver.ensure_workspace("default", path)
      assert {:ok, second} = Resolver.ensure_workspace("default", path)

      assert first.id == second.id
    end

    test "path normalization — relative paths resolve to the same row as the absolute equivalent" do
      cwd = File.cwd!()
      relative = "."

      assert {:ok, abs_ws} = Resolver.ensure_workspace("default", cwd)
      assert {:ok, rel_ws} = Resolver.ensure_workspace("default", relative)

      assert abs_ws.id == rel_ws.id
      assert abs_ws.path == cwd
    end
  end

  describe "ensure_workspace/3 — name derivation" do
    test "derives :name from Path.basename when not supplied" do
      path = "/tmp/derived-name-#{System.unique_integer([:positive])}/foo"
      assert {:ok, ws} = Resolver.ensure_workspace("default", path)
      assert ws.name == "foo"
    end

    test "respects explicit :name over basename" do
      path = "/tmp/explicit-name-#{System.unique_integer([:positive])}/foo"
      assert {:ok, ws} = Resolver.ensure_workspace("default", path, name: "Custom Name")
      assert ws.name == "Custom Name"
    end
  end
end
