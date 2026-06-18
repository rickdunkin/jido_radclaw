defmodule JidoClaw.MCP.Client do
  @moduledoc """
  Behaviour fronting the `Jido.MCP` transport/client stack.

  The single seam between `JidoClaw.MCP` and the `jido_mcp` dependency:
  `JidoClaw.MCP.Client.Live` delegates to `Jido.MCP.*` in production,
  `JidoClaw.MCP.Client.Stub` drives the suite without a real transport.

  Implementations **normalize response shapes at this boundary** so the rest
  of the subsystem never pattern-matches the dep's `%{status:, data:, raw:}`
  envelope: `list_tools/2` yields a bare `{:ok, [tool_map]}` and `call_tool/3`
  yields a bare `{:ok, data}`.
  """

  @typedoc "A configured endpoint id (the atomized server name)."
  @type endpoint_id :: atom()

  @typedoc "A remote tool descriptor map (MCP `tools/list` entry)."
  @type tool :: map()

  @doc """
  Register an endpoint with the client pool.

  An already-registered endpoint (a Consumer restart re-running prep against a
  pool that survived) is treated as `:ok` so discovery still proceeds.
  """
  @callback register_endpoint(Jido.MCP.Endpoint.t()) :: :ok | {:error, term()}

  @doc "Block until the endpoint's client has completed MCP initialization (bounded)."
  @callback await_endpoint_ready(endpoint_id(), timeout()) :: :ok | {:error, term()}

  @doc """
  Stop and restart an already-registered endpoint's client (a real recycle).

  Re-`register_endpoint/1` alone can't recover an alive-but-stuck client (its
  server was unreachable at boot init), so the crash re-prep + re-discovery
  paths refresh a failed endpoint before retrying discovery.
  """
  @callback refresh_endpoint(endpoint_id()) :: :ok | {:error, term()}

  @doc "Discover the endpoint's tools (bounded), normalized to a bare tool list."
  @callback list_tools(endpoint_id(), timeout()) :: {:ok, [tool()]} | {:error, term()}

  @doc "Invoke a remote tool, normalized to a bare `{:ok, data}` result."
  @callback call_tool(endpoint_id(), String.t(), map()) :: {:ok, term()} | {:error, term()}
end
