defmodule JidoClaw.MCP.AgentAPIStub do
  @moduledoc false

  # Narrow reconciliation fault-injection seam. Any callback absent from the
  # per-test map delegates to the real Jido.AI API.

  @spec register_tool(pid(), module(), keyword()) :: term()
  def register_tool(pid, module, opts),
    do:
      resolve(:register_tool, [pid, module, opts], fn ->
        Jido.AI.register_tool(pid, module, opts)
      end)

  @spec unregister_tool(pid(), String.t(), keyword()) :: term()
  def unregister_tool(pid, name, opts),
    do:
      resolve(:unregister_tool, [pid, name, opts], fn ->
        Jido.AI.unregister_tool(pid, name, opts)
      end)

  @spec has_tool?(pid(), String.t()) :: term()
  def has_tool?(pid, name),
    do: resolve(:has_tool?, [pid, name], fn -> Jido.AI.has_tool?(pid, name) end)

  @spec list_tools(pid()) :: term()
  def list_tools(pid), do: resolve(:list_tools, [pid], fn -> Jido.AI.list_tools(pid) end)

  defp resolve(key, args, fallback) do
    case Application.get_env(:jido_claw, :mcp_agent_api_stub, %{}) do
      %{^key => fun} when is_function(fun) -> apply(fun, args)
      %{^key => value} -> value
      _missing -> fallback.()
    end
  end
end
