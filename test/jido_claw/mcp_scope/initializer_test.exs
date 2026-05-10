defmodule JidoClaw.MCPScope.InitializerTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.Session
  alias JidoClaw.MCPScope.Initializer

  setup do
    # Reset env BEFORE the test runs — a previous test (or a stale
    # boot from `mix jidoclaw --mcp` in dev) can leave a value that
    # masks a regression.
    Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  test "ensure_default_scope/0 creates a kind: :mcp Session and stashes scope" do
    :ok = Initializer.ensure_default_scope()

    scope = Application.fetch_env!(:jido_claw, :jido_claw_mcp_default_scope)
    assert is_binary(scope.session_uuid)
    assert is_binary(scope.session_id)
    assert is_binary(scope.workspace_uuid)
    assert scope.tenant_id == "default"

    {:ok, session} = Session.by_id(scope.session_uuid, tenant: scope.tenant_id)
    assert session.kind == :mcp
    assert session.external_id == scope.session_id
  end
end
