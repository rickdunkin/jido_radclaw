defmodule JidoClaw.MCPServer.Resources.WorkflowStage do
  @moduledoc """
  Per-stage MCP template resource: read ONE composer-stage definition by URI
  (`jido://workflows/triage`) — the drill-down sibling of the static
  `jido://workflows/catalog` resource (G2-1b).

  An anubis `component` with `uri_template: "jido://workflows/{name}"`
  (RFC-6570 Level 1), registered on `JidoClaw.MCPServer` via `component/2` —
  NOT the jido_mcp `publish:` map, whose DSL has no template concept. Anubis
  lists it under `resources/templates/list` and routes a matching
  `resources/read` directly to `read/2` with the parsed vars
  (`%{"params" => %{"name" => …}}`), bypassing jido_mcp's exact-URI bridge;
  static resources match first, so the catalog URI is unaffected.

  The payload single-sources `Stage.to_map/1`, so the drill-down is
  byte-identical to the same entry of the catalog resource's `stages` map. An
  unknown stage returns `Error.resource(:not_found, …)` — anubis's template
  fallback then re-surfaces it as its own `resources/read` not-found (same
  `:resource_not_found` reason on the wire).
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "jido://workflows/{name}",
    name: "workflow_stage",
    mime_type: "application/json"

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.Stage

  @impl Anubis.Server.Component.Resource
  @spec read(map(), Frame.t()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def read(%{"params" => %{"name" => name}}, frame) do
    case Catalog.get(name) do
      %Stage{} = stage ->
        {:reply, Response.json(Response.resource(), %{"stage" => Stage.to_map(stage)}), frame}

      nil ->
        {:error, Error.resource(:not_found, %{uri: "jido://workflows/#{name}"}), frame}
    end
  end
end
