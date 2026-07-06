defmodule JidoClaw.MCPServer.SurfaceVersion do
  @moduledoc """
  The served-surface stability contract (pad PD1-1): one deliberate version
  string for everything JidoClaw serves over MCP — tool names, resource URIs,
  templates, and their output fields. Clients pin against THIS, not the app
  version: the app can ship daily; the surface only moves when the contract
  does.

  Bump rules:

    * **MAJOR** — remove/rename/retype a served tool, resource, or output
      field (anything an existing client could break on).
    * **MINOR** — additive: a new tool, resource, or optional output field.

  A bump lands in the SAME diff as the golden-fixture regen
  (`test/fixtures/mcp_surface/served_surface.json`) — the golden test
  set-compares every enumeration surface, so the surface cannot drift without
  a deliberate version decision.

  Also the single-sourced app-version accessor (`app_version/0` — the
  `EndpointConfig` idiom) for the version-bearing surfaces: `server_info/0`,
  `jido://_meta/version`, `jido://bootstrap`, and the `project_info` tool.

  ## Changelog

    * v1.0 (2026-07-05) — 26 tools; `jido://workflows/catalog` +
      `jido://workflows/{name}` template + `jido://_meta/version` +
      `jido://bootstrap`; `server_info` version = app version; `project_info`
      gains `app_version`.
  """

  @current "1.0"

  @doc "The current served-surface version."
  @spec current() :: String.t()
  def current, do: @current

  @doc "The running app version (`Application.spec/2`, never a hand-rolled literal)."
  @spec app_version() :: String.t()
  def app_version, do: to_string(Application.spec(:jido_claw, :vsn) || "dev")
end
