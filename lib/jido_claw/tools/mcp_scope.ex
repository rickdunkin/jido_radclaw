defmodule JidoClaw.Tools.MCPScope do
  @moduledoc """
  Inject a default `tool_context` into the three Solutions tools when
  invoked over MCP stdio.

  MCP invocations from external clients (Claude Code, Cursor) hand
  tools a JSON arg map and **no** `tool_context` — without explicit
  handling, every MCP solutions call would fail loudly with the
  "missing scope" error path from `StoreSolution`/`FindSolution`/
  `VerifyCertificate`.

  The MCP server resolves a single workspace at startup from its
  `cwd` (single-user, no auth, by definition), stores the
  `(tenant_id, workspace_uuid)` pair under
  `:jido_claw_mcp_default_scope` in the application env, and these
  tools call `with_default/2` to inject those defaults when the
  caller doesn't supply a tool_context.

  Multi-tenant MCP is out of scope — the protocol has no mechanism
  to distinguish callers.
  """

  @doc """
  Returns the `context` map with `:tool_context` populated from the
  MCP-mode default scope when missing.

  When called outside MCP mode (no default scope registered),
  passes `context` through unchanged.
  """
  @spec with_default(map() | nil) :: map()
  def with_default(context) when is_map(context) do
    case Map.get(context, :tool_context) do
      tc when is_map(tc) and map_size(tc) > 0 ->
        # Caller already supplied scope — respect it.
        context

      _ ->
        case mcp_default_scope() do
          nil -> context
          scope -> Map.put(context, :tool_context, scope)
        end
    end
  end

  def with_default(nil), do: %{tool_context: mcp_default_scope() || %{}}

  defp mcp_default_scope do
    Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)
  end
end
