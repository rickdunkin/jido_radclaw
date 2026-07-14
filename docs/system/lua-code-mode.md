---
type: subsystem
description: Read-only server-side Lua for cross-run queries — sandboxed VM with budgets, seven host bindings, non-retryable envelopes.
sources:
  - lib/jido_claw/tools/lua_query.ex
  - lib/jido_claw/tools/lua_docs.ex
  - lib/jido_claw/tools/lua/bindings.ex
  - lib/jido_claw/tools/lua/runner.ex
  - lib/jido_claw/tools/lua/policy.ex
verified: 2026-07-12
verified_sha: "57f61037"
---

# Lua Code-Mode Queries

## What & why

`lua_query` + `lua_docs` (amber AM-1 + jidoka V2-7; registered on BOTH tool surfaces)
run a short **read-only** Lua script server-side so cross-run filter/join/aggregate
happens in the sandbox — intermediate rows never enter model context. Port provenance:
the runner hardening + VM budgets are the jidoka port @ `9469dc09` (Apache-2.0), with
`max_parallel_calls` dropped.

## Invariants & contracts

- **Every binding is read-only**: `assert_read_only!/0` runs per eval — a future write
  binding must clear it deliberately and join the approval require-list; the
  `lua_query`/`lua_docs` pair itself is deliberately NOT require-listed.
- Two checks are deliberately **post-eval** because in-script `pcall` can swallow host
  raises: budget refusal (latched in `CallTrace.refused?/1` →
  `:lua_call_budget_exceeded` even over a "successful" eval) and the aggregate
  `max_result_bytes` bound (`:lua_result_too_large` — load-bearing: `OutputLimit` caps
  string leaves only, nothing else bounds a big structured result).
- All `:lua_*` envelopes are non-retryable at both retry layers
  (`details.retry: false`; `:lua_timeout` deliberately so — the same script + same
  caps re-times-out). Missing tenant stays a bare `:tenant_required` (the
  `workflow_status` precedent).

## Mechanics

Seven host bindings in `JidoClaw.Tools.Lua.Bindings` — the single source; `lua_docs`
renders from it:

- `jido.runs` — `WorkflowView.runs/2`, honest `:runs_unavailable`
- `jido.run` — single-run snapshot
- `jido.events` — byte-bounded event feed
- `jido.cases` — pending approvals, fixed-field projection
- `jido.solutions` — **lexical-only**: passes the `resolve_embedding?: false` Matcher
  opt so a sandbox read can never trigger Voyage egress
- `jido.output` — stored-ref slices via the shared `Tools.OutputRef`, inheriting
  fetch_output's S-M2 session scoping exactly
- `jido.debt` — the waived-findings ledger (`Cases.waived_findings_ledger/2`)

Every callback threads the post-`Lua.encode!` VM state back.

`JidoClaw.Tools.Lua.Runner` lifts LuaEval's task-isolation hardening (unlinked task +
watchdog + heap kill + deadline gate) and adds the lua-1.0 VM budgets
(`max_instructions`, `max_string_bytes` — the VM is a from-scratch pure-Elixir
implementation, NOT Luerl) under `JidoClaw.Tools.Lua.Policy` clamps. `print`/`debug`
are sandboxed post-`Lua.new` — the default sandbox misses them, and `print` writes
model text to host `IO.puts`.

## Config & telemetry

Config under `:lua` (caps only — **no `enabled?`**: registration is the switch, clamps
make bad values safe; no test.exs entry — tests pass explicit opts). Telemetry counter
`jido_claw.lua_eval.total` + `:guardrail` Trace events (one terminal `:eval` per run +
a discrete `:budget_refused`).

## Residuals & accepted risks

None recorded; the deliberate edges (post-eval checks, non-retryable timeout, the
not-require-listed pair) are design decisions with their rationale above.

## Source map

- `lib/jido_claw/tools/lua_query.ex` — the query tool
- `lib/jido_claw/tools/lua_docs.ex` — docs rendered from the bindings source
- `lib/jido_claw/tools/lua/bindings.ex` — the seven bindings, `assert_read_only!/0`
- `lib/jido_claw/tools/lua/runner.ex` — task isolation, VM budgets, post-eval checks
- `lib/jido_claw/tools/lua/policy.ex` — clamps
- `lib/jido_claw/tools/lua/call_trace.ex` — `refused?/1` latch
