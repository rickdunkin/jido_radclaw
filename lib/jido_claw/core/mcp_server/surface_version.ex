defmodule JidoClaw.MCPServer.SurfaceVersion do
  @moduledoc """
  The served-surface stability contract (pad PD1-1): one deliberate version
  string for everything JidoClaw serves over MCP — tool names, resource URIs,
  templates, and their output fields. Clients pin against THIS, not the app
  version: the app can ship daily; the surface only moves when the contract
  does.

  Bump rules:

    * **MAJOR** — remove/rename/retype a served tool, resource, or output
      field (anything an existing client could break on); for the error-code
      registry (`JidoClaw.MCPServer.ErrorCodes`): removals, renames, and
      family moves.
    * **MINOR** — additive: a new tool, resource, or optional output field;
      for the error-code registry: code additions.

  A bump lands in the SAME diff as the golden-fixture regen
  (`test/fixtures/mcp_surface/served_surface.json`) — the golden test
  set-compares every enumeration surface (including the registry's
  `error_codes_by_family` block), so the surface cannot drift without a
  deliberate version decision.

  Also the single-sourced app-version accessor (`app_version/0` — the
  `EndpointConfig` idiom) for the version-bearing surfaces: `server_info/0`,
  `jido://_meta/version`, `jido://bootstrap`, and the `project_info` tool.

  ## Changelog

    * v1.3 (2026-07-12) — MINOR, additive (pad PD1-2): tool-result errors
      from the public server carry a SECOND text content item — `content[1]`
      of the raw error response — with the canonical JSON envelope
      `{"code","message","details"}`; `content[0]` keeps the legacy inspect
      text byte-identical. Codes come from the closed
      `JidoClaw.MCPServer.ErrorCodes` registry (unregistered codes arrive as
      `tool_error` + `details.unregistered_code` — present exactly when the
      fallback fired); new typed hint details
      (`expected`/`got`, `available`/`available_truncated`); new lookup codes
      (`absolute_glob_not_allowed`, `glob_outside_project`, `unknown_skill`)
      and workflow codes (`skill_run_failed`, `skill_cancelled`);
      `details.retry` is retry-policy ELIGIBILITY (the exec gate's class
      predicate — never a record of an executed in-call retry), and the
      three-state definition is SERVED (`ErrorCodes.retry_semantics/0` —
      bootstrap `error_contract.retry_semantics` + the extended stability
      sentence); `server_instructions` now serves the error-contract
      stability sentence; `jido://bootstrap` gains the additive
      `error_contract` key. Tier-1 wrap provenance is WITNESSED through the
      forked `Jido.Exec` (a per-call ref stamped only on the wrap of a raw
      canonical envelope, detached at the boundary on exact ref identity) —
      junk-shaped native errors that merely LOOK like the wrap (hand-built
      `ExecutionFailureError`s carrying `code`+`details`, colliding
      non-exception structs, near-envelope maps) classify as
      `execution_error` with authoritative retry, never the nested code
      (junk-input-only delta; nothing shipped between). Tools, URIs, and
      templates unchanged.
    * v1.2 (2026-07-07) — MINOR: run views served by `workflow_status`,
      `jido.runs`, `jido://bootstrap`, and `inspect_workflow` gain the additive
      `claimed_by` + `claim_expires_at` ownership fields (WS6 lease
      observability, via `Visibility.run_view/3`). Both are raw/frozen claim
      columns — on a terminal run, the last-claim value, never live lease
      state; pair with `status`. Tools, URIs, and templates unchanged.
    * v1.1 (2026-07-07) — MINOR: the `jido://workflows/catalog` and
      `jido://workflows/{name}` stage payloads gain the additive `"executor"`
      field (`null | "in_process" | "forge:<kind>"` — the item 7 PR-4
      per-stage executor override, rendered via `Stage.to_map/1`). Tools,
      URIs, and templates unchanged.
    * v1.0 (2026-07-05) — 26 tools; `jido://workflows/catalog` +
      `jido://workflows/{name}` template + `jido://_meta/version` +
      `jido://bootstrap`; `server_info` version = app version; `project_info`
      gains `app_version`.
  """

  @current "1.3"

  @doc "The current served-surface version."
  @spec current() :: String.t()
  def current, do: @current

  @doc "The running app version (`Application.spec/2`, never a hand-rolled literal)."
  @spec app_version() :: String.t()
  def app_version, do: to_string(Application.spec(:jido_claw, :vsn) || "dev")
end
