defmodule JidoClaw.Tools.MCPScopeTest do
  @moduledoc """
  Coverage for the §8.2 `MCPScope.wrap/4` helper.

  Locks in:

    * Outside MCP serve mode → pass-through (no Message rows).
    * Under MCP serve mode → tool_call/tool_result row pair tied to
      the same per-call `(request_id, tool_call_id)` and the
      result row's `parent_message_id` points at the call row.
    * Two distinct invocations produce two distinct id pairs.
    * With explicit override IDs, a second call with the same IDs
      hits the `unique_live_tool_row` identity and is treated
      idempotently.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Conversations.{Message, Resolver}
  alias JidoClaw.Tools.MCPScope

  setup do
    prior_serve_mode = Application.get_env(:jido_claw, :serve_mode)
    prior_scope = Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)

    on_exit(fn ->
      restore_app_env(:serve_mode, prior_serve_mode)
      restore_app_env(:jido_claw_mcp_default_scope, prior_scope)
    end)

    tenant_id = unique_tenant_id()
    ws = workspace_fixture(tenant_id, embedding_policy: :disabled)

    {:ok, session} =
      Resolver.ensure_session(tenant_id, ws.id, :mcp, "mcp_test_#{unique_id()}")

    scope = %{
      tenant_id: tenant_id,
      workspace_uuid: ws.id,
      workspace_id: ws.id,
      session_uuid: session.id,
      session_id: session.external_id,
      project_dir: "/tmp",
      agent_id: "main"
    }

    {:ok, tenant_id: tenant_id, workspace: ws, session: session, scope: scope}
  end

  describe "wrap/4 outside MCP serve mode" do
    test "is a pass-through and writes no Message rows", %{scope: scope, session: session} do
      Application.delete_env(:jido_claw, :serve_mode)

      result =
        MCPScope.wrap(:test_tool, %{x: 1}, %{tool_context: scope}, fn _enriched ->
          {:ok, %{a: 1}}
        end)

      assert result == {:ok, %{a: 1}}
      assert {:ok, []} = Message.for_session(session.id, tenant: session.tenant_id)
    end
  end

  describe "wrap/4 under MCP serve mode" do
    test "appends a tool_call + tool_result row tied to the same request",
         %{scope: scope, session: session} do
      Application.put_env(:jido_claw, :serve_mode, :mcp)
      Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, scope)

      result =
        MCPScope.wrap(:demo_tool, %{path: "x"}, %{tool_context: scope}, fn _enriched ->
          {:ok, %{ok: true}}
        end)

      assert result == {:ok, %{ok: true}}

      {:ok, rows} = Message.for_session(session.id, tenant: session.tenant_id)
      assert length(rows) == 2

      [call, result_row] = Enum.sort_by(rows, & &1.sequence)
      assert call.role == :tool_call
      assert result_row.role == :tool_result
      assert call.request_id == result_row.request_id
      assert call.tool_call_id == result_row.tool_call_id
      assert result_row.parent_message_id == call.id
      assert call.metadata["tool_name"] == "demo_tool" or call.metadata[:tool_name] == "demo_tool"
    end

    test "two invocations produce two distinct id pairs",
         %{scope: scope, session: session} do
      Application.put_env(:jido_claw, :serve_mode, :mcp)
      Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, scope)

      MCPScope.wrap(:demo, %{a: 1}, %{tool_context: scope}, fn _ -> {:ok, %{}} end)
      MCPScope.wrap(:demo, %{a: 2}, %{tool_context: scope}, fn _ -> {:ok, %{}} end)

      {:ok, rows} = Message.for_session(session.id, tenant: session.tenant_id)
      assert length(rows) == 4

      tool_calls = Enum.filter(rows, &(&1.role == :tool_call))
      ids = Enum.map(tool_calls, & &1.request_id)
      assert length(Enum.uniq(ids)) == 2
    end

    test "explicit override IDs make repeated calls idempotent",
         %{scope: scope, session: session} do
      Application.put_env(:jido_claw, :serve_mode, :mcp)
      Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, scope)

      override_request = Ecto.UUID.generate()
      override_call = Ecto.UUID.generate()

      ctx = %{
        tool_context: scope,
        mcp_request_id: override_request,
        mcp_tool_call_id: override_call
      }

      MCPScope.wrap(:demo, %{}, ctx, fn _ -> {:ok, %{}} end)
      MCPScope.wrap(:demo, %{}, ctx, fn _ -> {:ok, %{}} end)

      {:ok, rows} = Message.for_session(session.id, tenant: session.tenant_id)

      tool_calls = Enum.filter(rows, &(&1.role == :tool_call))
      tool_results = Enum.filter(rows, &(&1.role == :tool_result))

      assert length(tool_calls) == 1
      assert length(tool_results) == 1
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
