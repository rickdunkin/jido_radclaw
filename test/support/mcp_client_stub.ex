defmodule JidoClaw.MCP.Client.Stub do
  @moduledoc """
  Test `JidoClaw.MCP.Client` — no real transport.

  Each callback resolves against `Application.get_env(:jido_claw, :mcp_stub, %{})`
  keyed by callback name. A value may be:

    * a function (applied to the callback args) — for capturing args / dynamic
      responses, e.g. `call_tool: fn _id, name, args -> ... end`;
    * a literal — returned as-is, e.g. `register_endpoint: {:error, {:endpoint_already_registered, :s}}`;
    * absent — a sensible default (`:ok` / `{:ok, []}` / `{:ok, %{}}`).

  Drive it from `async: false` tests that `put_env`/restore in setup.
  """

  @behaviour JidoClaw.MCP.Client

  @impl JidoClaw.MCP.Client
  def register_endpoint(endpoint), do: resolve(:register_endpoint, [endpoint], :ok)

  @impl JidoClaw.MCP.Client
  def await_endpoint_ready(endpoint_id, timeout),
    do: resolve(:await_endpoint_ready, [endpoint_id, timeout], :ok)

  @impl JidoClaw.MCP.Client
  def list_tools(endpoint_id, timeout),
    do: resolve(:list_tools, [endpoint_id, timeout], {:ok, []})

  @impl JidoClaw.MCP.Client
  def call_tool(endpoint_id, tool_name, arguments),
    do: resolve(:call_tool, [endpoint_id, tool_name, arguments], {:ok, %{}})

  defp resolve(key, args, default) do
    case Application.get_env(:jido_claw, :mcp_stub, %{}) do
      %{^key => fun} when is_function(fun) -> apply(fun, args)
      %{^key => value} -> value
      _absent -> default
    end
  end
end
