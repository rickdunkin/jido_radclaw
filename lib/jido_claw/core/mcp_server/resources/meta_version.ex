defmodule JidoClaw.MCPServer.Resources.MetaVersion do
  @moduledoc """
  MCP resource serving the version facts of the served surface (PD1-1):
  `jido://_meta/version` → app version + surface-contract version + published
  tool count.

  A client reads this once to decide compatibility: `surface_version` is the
  stability contract (`JidoClaw.MCPServer.SurfaceVersion` — bump rules in its
  moduledoc), `app_version` is the running release, `tool_count` a cheap
  drift tripwire. Registered by exact `uri/0` like the catalog resource;
  `read/2` returns `{:ok, map}` and the jido_mcp runtime JSON-encodes it.
  """
  @behaviour Jido.MCP.Server.Resource

  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.SurfaceVersion

  @uri "jido://_meta/version"

  @impl Jido.MCP.Server.Resource
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl Jido.MCP.Server.Resource
  @spec name() :: String.t()
  def name, do: "meta_version"

  @impl Jido.MCP.Server.Resource
  @spec description() :: String.t()
  def description,
    do:
      "Version facts of the served MCP surface: app_version (running release), " <>
        "surface_version (the stability contract clients pin against), tool_count."

  @impl Jido.MCP.Server.Resource
  @spec mime_type() :: String.t()
  def mime_type, do: "application/json"

  @impl Jido.MCP.Server.Resource
  @spec read(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def read(@uri, _frame) do
    {:ok,
     %{
       "app_version" => SurfaceVersion.app_version(),
       "surface_version" => SurfaceVersion.current(),
       "tool_count" => length(MCPServer.served_tool_names())
     }}
  end

  def read(_uri, _frame), do: {:error, :not_found}
end
