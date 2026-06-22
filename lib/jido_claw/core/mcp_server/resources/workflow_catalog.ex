defmodule JidoClaw.MCPServer.Resources.WorkflowCatalog do
  @moduledoc """
  MCP resource exposing the deterministic route-composer catalog as JSON
  (AR-2 Phase 5, §10.2).

  Registered by an exact `uri/0` string (`jido://workflows/catalog`) — no
  RFC-6570 template — so an MCP client can *discover* the composable surface
  (every stage the composer can schedule), not just trigger it. `read/2` returns
  `{:ok, map}`; the jido_mcp runtime auto-`Response.json`-encodes a map
  (`Jido.MCP.Server.Runtime.resource_response/1`), so this never builds an
  Anubis `{:reply, %Response{}, frame}` triple itself.

  The payload is `Catalog.to_map(Catalog.all())` — the same JSON-safe,
  string-keyed `%{name => stage_map}` the composer persists in its parent
  config — so it reflects whatever `Catalog.all/0` returns (a future YAML
  overlay would surface automatically).
  """
  @behaviour Jido.MCP.Server.Resource

  alias JidoClaw.RouteComposer.Catalog

  @uri "jido://workflows/catalog"

  @impl Jido.MCP.Server.Resource
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl Jido.MCP.Server.Resource
  @spec name() :: String.t()
  def name, do: "workflow_catalog"

  @impl Jido.MCP.Server.Resource
  @spec description() :: String.t()
  def description,
    do:
      "The route-composer catalog: every composable stage (unit, routes, inputs/outputs, " <>
        "subscribes/publishes, locks) the deterministic composer can schedule."

  @impl Jido.MCP.Server.Resource
  @spec mime_type() :: String.t()
  def mime_type, do: "application/json"

  @impl Jido.MCP.Server.Resource
  @spec read(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def read(@uri, _frame), do: {:ok, %{"stages" => Catalog.to_map(Catalog.all())}}
  def read(_uri, _frame), do: {:error, :not_found}
end
