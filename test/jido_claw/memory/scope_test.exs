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
    test "returns a signed 64-bit integer" do
      key = Scope.lock_key("default", :workspace, "abc")
      assert is_integer(key)
      assert key >= -Bitwise.bsl(1, 63)
      assert key <= Bitwise.bsl(1, 63) - 1
    end

    test "deterministic for the same input" do
      assert Scope.lock_key("t", :workspace, "fk") == Scope.lock_key("t", :workspace, "fk")
    end

    test "differs across tenants" do
      assert Scope.lock_key("t1", :workspace, "fk") != Scope.lock_key("t2", :workspace, "fk")
    end

    test "differs across scope_kinds" do
      assert Scope.lock_key("t", :workspace, "fk") != Scope.lock_key("t", :session, "fk")
    end

    test "uses the SHA-256 64-bit prefix (full bigint range)" do
      # Sample many keys; if we were still phash2-masked to 27 bits,
      # we'd never see values above 2^27. Verify we actually use the
      # full signed-64 range.
      keys =
        for i <- 1..1000 do
          Scope.lock_key("t", :workspace, "fk-#{i}")
        end

      max_abs = Enum.max(Enum.map(keys, &abs/1))
      assert max_abs > Bitwise.bsl(1, 32)
    end
  end

  describe "primary_fk/1" do
    test "selects the FK matching scope_kind" do
      assert Scope.primary_fk(%{scope_kind: :session, session_id: "s"}) == "s"
      assert Scope.primary_fk(%{scope_kind: :project, project_id: "p"}) == "p"
      assert Scope.primary_fk(%{scope_kind: :workspace, workspace_id: "w"}) == "w"
      assert Scope.primary_fk(%{scope_kind: :user, user_id: "u"}) == "u"
    end
  end
end
