defmodule JidoClaw.Memory.ScopeTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Memory.Scope
  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "resolve/1" do
    test "errors when tenant_id is missing" do
      assert {:error, :tenant_required} = Scope.resolve(%{tenant_id: nil})
      assert {:error, :tenant_required} = Scope.resolve(%{tenant_id: ""})
      assert {:error, :tenant_required} = Scope.resolve(%{})
    end

    test "errors when no FK is populated" do
      assert {:error, :scope_kind_unresolvable} =
               Scope.resolve(%{tenant_id: "default"})
    end

    test "derives :workspace from workspace_uuid" do
      {:ok, ws} =
        Resolver.ensure_workspace(
          "default",
          "/tmp/scope_ws_#{System.unique_integer([:positive])}",
          []
        )

      tc = %{tenant_id: "default", workspace_uuid: ws.id}

      assert {:ok, scope} = Scope.resolve(tc)
      assert scope.scope_kind == :workspace
      assert scope.workspace_id == ws.id
      assert scope.tenant_id == "default"
    end
  end

  describe "chain/1" do
    test "returns most-specific-first chain for :workspace scope" do
      scope = %{
        tenant_id: "default",
        scope_kind: :workspace,
        user_id: nil,
        workspace_id: "ws-123",
        project_id: nil,
        session_id: nil
      }

      assert Scope.chain(scope) == [{:workspace, "ws-123"}]
    end

    test "drops levels below the scope_kind" do
      # A :workspace scope shouldn't surface :session-level rows in its chain
      scope = %{
        tenant_id: "default",
        scope_kind: :workspace,
        user_id: "user-1",
        workspace_id: "ws-1",
        project_id: nil,
        session_id: nil
      }

      chain = Scope.chain(scope)
      refute Enum.any?(chain, fn {kind, _} -> kind in [:session, :project] end)
      assert {:workspace, "ws-1"} in chain
      assert {:user, "user-1"} in chain
    end
  end

  describe "lock_key/3" do
    test "returns a positive bigint within signed 63-bit range" do
      key = Scope.lock_key("default", :workspace, "abc")
      assert is_integer(key)
      assert key >= 0
      assert key <= Bitwise.bsl(1, 63) - 1
    end

    test "deterministic for the same input" do
      assert Scope.lock_key("t", :workspace, "fk") == Scope.lock_key("t", :workspace, "fk")
    end

    test "differs across tenants" do
      assert Scope.lock_key("t1", :workspace, "fk") != Scope.lock_key("t2", :workspace, "fk")
    end
  end
end
