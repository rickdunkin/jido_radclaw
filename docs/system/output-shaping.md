---
type: subsystem
description: Format-aware compression of verbose tool output — compress the green, never the red; always reversible via ref-stored full captures.
sources:
  - lib/jido_claw/tools/output_shaper.ex
  - lib/jido_claw/tools/output_redaction.ex
  - lib/jido_claw/tools/output_limit.ex
  - lib/jido_claw/tools/fetch_output.ex
  - lib/jido_claw/conversations/resources/tool_output.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Output Shaping

## What & why

Verbose tool output (`run_command`, `git_diff`) is compressed format-aware by
`JidoClaw.Tools.OutputShaper` so success noise stops flooding model context while
failures stay verbatim. The stage sits between `OutputRedaction` and `OutputLimit` in
the shared `Tools.Action` pipeline; shaping is always reversible because the full
capture is stored and retrievable.

## Invariants & contracts

- **Compress the green, never the red**: `mix test`/`mix compile` success noise becomes
  counts, failure/warning blocks stay verbatim, unknown formats get head+tail.
- **Reversibility**: the full captured output is ref-stored and retrievable via
  `fetch_output`; anything exceeding `OutputLimit`'s 32KB inline cap — an oversized
  shaped/all-signal body — is bounded by head+tail elision with the ref footer intact,
  never ref-less truncated.
- **Scoping**: the `fetch_output` read is always tenant-scoped and ALSO
  **session-scoped** (S-M2) on session-meaningful surfaces (`serve_mode != :mcp` with a
  resolved `session_uuid`) via `ToolOutput.by_ref_scoped` — a session resolves only its
  OWN rows, blocking a same-tenant cross-session peek.
- **ANSI at the root**: stripping lives in `OutputRedaction`
  (`Security.Redaction.Ansi.strip/1`, applied before both value redaction and key
  classification), so an escape-split secret (`sk-ant-\e[0m…`) or split sensitive key
  (`api_\e[0mkey`) is reassembled and caught for every tool and every path before the
  shaper sees the text — the shaper's own strip is belt-and-suspenders.
- Disabled ⇒ byte-identical legacy truncation; no-tenant calls pass through unshaped;
  streaming runs are never shaped.

## Mechanics

- **Capture + refs**: the full captured output (up to 512KB; `truncated` flagged
  beyond) is stored tenant-scoped in `Conversations.ToolOutput` under an unguessable
  ref — `JidoClaw.Refs.mint/1`, 12 random bytes → 24 hex, single-sourced with the
  `art_…` composer-artifact refs (O-L2).
- **Session-scope arms**: system/cron-minted (`session_id: nil`) refs stay reachable
  from any session (the `is_nil` filter arm), and under `:mcp` the boot scope stays
  tenant-wide (the documented REPL-minted-ref drill-in flow).
- **Slice clipping**: `fetch_output` clips oversized slices to the 32KB cap
  (direction-aware) and reports honest `clipped`/`selected_lines` metadata.
- **Capture request**: `run_command` requests the larger capture from `SessionManager`
  via the `:capture_bytes` opt only when `OutputShaper.shapeable?/3` holds — the same
  predicate on capture and shaping sides.
- **External MCP proxy results** (`mcp_<server>_<tool>`) take a parallel **generic**
  path (`mcp_shapeable?/2` → `safe_shape_mcp/3`): above the inline cap (or for any
  unencodable term) the whole result is pretty-serialized, capture-capped with
  tail-preserving elision, ref-stored, and collapsed to a bounded `:output` wrapper
  with the spec-standard `isError` lifted (the model's only failure signal); below the
  cap the structured result passes through. Format-aware parsing stays
  `run_command`/`git_diff`-only.

## Config & telemetry

Config under `:output_shaping` (`enabled?: false` in test.exs ⇒ byte-identical legacy
truncation). Telemetry on `[:jido_claw, :tool, :shaping]` plus `:output` Trace events.

## Residuals & accepted risks

Accepted at review time — documented, not fixed:

- **(S-M3)** streamed `run_command` chunks reach the OPERATOR's own terminal
  un-redacted — the model-facing copy IS redacted, and the threat model is
  model-input / durable-sink hygiene, not the operator's local echo (streaming runs are
  never shaped).
- **(S-L2)** the memory-consolidator's internal tools bypass the shared `Tools.Action`
  pipeline — internal-only, and ingest redacts at the sink.
- **(O-L1)** the composer's `ensure_parent_live` child-create reload can briefly fail
  OPEN (`route_composer.ex`), but the wave fold stays fenced at `commit_wave` (the
  token CAS), so no unfenced write survives.

## Source map

- `lib/jido_claw/tools/output_shaper.ex` — format detection, `shapeable?/3`,
  `safe_shape_mcp/3`
- `lib/jido_claw/tools/output_redaction.ex` — the redaction root incl. the ANSI
  pre-pass
- `lib/jido_claw/security/redaction/ansi.ex` — `strip/1`
- `lib/jido_claw/tools/output_limit.ex` — 32KB inline cap, ref-footer-preserving
  elision
- `lib/jido_claw/tools/fetch_output.ex` — stored-ref retrieval, direction-aware
  clipping
- `lib/jido_claw/conversations/resources/tool_output.ex` — `by_ref_scoped` (S-M2),
  the `is_nil` system-ref arm
