---
type: surface
description: The served MCP surface — 26 tools, four jido:// resources, the surface-version stability contract and its golden guard.
sources:
  - lib/jido_claw/core/mcp_server.ex
  - lib/jido_claw/core/mcp_server/surface_version.ex
  - lib/jido_claw/core/mcp_server/resources
  - test/jido_claw/core/mcp_server/served_surface_golden_test.exs
  - test/fixtures/mcp_surface/served_surface.json
verified: 2026-07-07
verified_sha: "2a0bb4c6"
---

# MCP Server Surface

## What & why

`JidoClaw.MCPServer` serves the platform over MCP stdio for Claude Code, Cursor, and
other MCP-compatible editors: 26 tools + four `jido://` resources. The `.mcp.json`
quickstart and the anubis patch notes stay in AGENTS.md (MCP Server Mode); this page is
the full surface: what is exposed, what is deliberately MCP-only, and the stability
contract clients pin against. The *consuming* direction is
[mcp-consumption](mcp-consumption.md).

## Invariants & contracts

- **MCP-only by design**: `inspect_workflow`, `workflow_events`, and `replay_workflow`
  are on no in-REPL agent's tool list; `replay_workflow` additionally exposes no
  `force`/`allow_irreversible` overrides — replay-gate overrides are dashboard-only.
- **Version facts are single-sourced**: `app_version` comes from
  `SurfaceVersion.app_version/0` over `Application.spec/2`, and `server_info/0` is
  hand-defined to carry the same — never a hand-rolled literal (the old "0.2.0" rot
  lesson).
- **The stability contract**: `JidoClaw.MCPServer.SurfaceVersion` is what clients pin
  against — bump rules + changelog live in its moduledoc, and the golden
  `served_surface_golden_test.exs` set-compares tool names / static resource URIs /
  template URIs / the version string per enumeration surface against the committed
  `test/fixtures/mcp_surface/served_surface.json`, so a surface change without a
  deliberate bump fails precommit.
- **Honesty over fabricated zeros**: an unresolved MCP scope reads
  `available: false` with a reason, and a failed read inside a resolved tenant flips
  that block's `*_available: false` flag — the deliberate inversion of the dashboard
  rollup's degrade-to-zero.

## Mechanics

**Exposed tools** (26): `read_file`, `write_file`, `edit_file`, `list_directory`,
`search_code`, `run_command`, `fetch_output`, `git_status`, `git_diff`, `git_commit`,
`project_info`, `run_skill`, `store_solution`, `find_solution`, `network_share`,
`network_status`, `agent_status`, `inspect_agent`, `swarm_status`, `forge_status`,
`workflow_status`, `inspect_workflow`, `replay_workflow`, `workflow_events`,
`lua_query`, `lua_docs`. `workflow_events` returns a run's raw, byte-paginated
`WorkflowEvent` feed (G2-1a). `inspect_workflow` reads a single composer run's live
route / waves / held / dropped / live signals + gate-block state; `workflow_status` is
the tenant rollup.

**Exposed resources** (AR-2 Phase 5, §10.2):

- `jido://workflows/catalog` — the deterministic route-composer catalog (every
  composable stage: unit, routes, inputs/outputs, subscribes/publishes, locks) as
  `application/json`, so a client can *discover* the composable surface, not just
  trigger it.
- `jido://workflows/<stage>` (G2-1b) — the per-stage drill-down: an anubis `component`
  template resource (`jido://workflows/{name}`, listed under
  `resources/templates/list`, single-sourcing `Stage.to_map/1` so a stage read is
  byte-identical to the catalog's entry; unknown stage ⇒ resource not-found).
- Both workflow payloads gained the additive stage `"executor"` field in **v1.1**
  (`null | "in_process" | "forge:<kind>"` — the item 7 PR-4 per-stage executor
  override; every shipped stage serves `null`). Additive served-output field ⇒ a
  MINOR bump per the `SurfaceVersion` rules.
- `jido://_meta/version` (pad PD1-1, next-ten #6) — the served-surface version facts:
  `app_version`, `surface_version`, and `tool_count`.
- `jido://bootstrap` (PD2-1, slim) — one-read client orientation: versions + sorted
  tool names + a bounded tenant snapshot (identity, pending-gates count,
  `active_runs`/`recent_completions` as `Visibility.run_view` rows capped at 5 with
  `*_overflow_count` from a cap+1 read — ≥1 means "more exist", never a total).
- Run views served by `workflow_status`, `jido.runs`, `jido://bootstrap`, and
  `inspect_workflow` gained the additive `claimed_by` + `claim_expires_at` ownership
  fields in **v1.2** (WS6 lease observability, via `Visibility.run_view/3`). Both are
  raw/frozen claim columns — on a terminal run, the last-claim value, never live
  lease state; pair with `status`. Additive served-output fields ⇒ MINOR.

## Config & telemetry

Served when `:serve_mode` is `:mcp` (`mix jidoclaw --mcp`; Gateway and Discord are
skipped in this mode). Requires PostgreSQL running and `mix ecto.setup` run at least
once. The golden test + `SurfaceVersion` bump rules are the change-control mechanism.

## Residuals & accepted risks

The anubis_mcp 1.6.2 runtime patch (Peri validation rescue + argument atomization)
remains documented in AGENTS.md's Known limitations — it is a dependency workaround,
not a surface property; remove once `jido_mcp` emits Peri-compatible schemas or stops
routing those descriptors through Anubis's pre-dispatch validation.

## Source map

- `lib/jido_claw/core/mcp_server.ex` — the served tool set, `server_info/0`
- `lib/jido_claw/core/mcp_server/surface_version.ex` — the stability contract,
  `app_version/0`, bump rules
- `lib/jido_claw/core/mcp_server/resources/` — catalog, per-stage template,
  meta-version, bootstrap resources
- `test/jido_claw/core/mcp_server/served_surface_golden_test.exs` — the golden guard
- `test/fixtures/mcp_surface/served_surface.json` — the committed surface
