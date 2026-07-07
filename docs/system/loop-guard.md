---
type: subsystem
description: Doom-loop detection in the shared tool pipeline — identical-call halts, failure-signature recovery, per-key call budgets.
sources:
  - lib/jido_claw/agent/loop_guard.ex
  - lib/jido_claw/agent/loop_guard/store.ex
  - lib/jido_claw/tools/action.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Loop Guard (doom-loop detection)

## What & why

`JidoClaw.Agent.LoopGuard` detects and interrupts doom loops — an agent re-running the
same tool call, re-hitting the same failure, or burning unbounded calls — from inside
the shared `Tools.Action` pipeline. Port provenance: osa OS1-2 @ `f60e933b`
(Apache-2.0) — detection thresholds, halt texts, and the suggestion table are verbatim;
the integration is rewritten for this pipeline.

## Invariants & contracts

- Runs AFTER the approval gate: a pre-execution `check/4` blocks a doomed call before
  it runs, and a post-normalize `observe_result/5` reads the canonical
  `%{code, message, details}`. `approval_*`/`doom_loop` codes are skip-listed —
  non-executions never count.
- The halt envelope `{:error, %{code: :doom_loop, message: …, details: %{retry: false,
  trigger: …}}}` is non-retryable at BOTH retry layers (the ForgeBridge precedent;
  details key `:trigger`, never `:reason`), proven by an Exec/Turn-driven contract
  test. 3-tuple results keep their effects.
- A clean success of tool T clears only **T's** failure signatures — a deliberate
  deviation from OSA's documented clear-all, which would mask the edit-fail → read-ok →
  edit-fail repair loop.
- The facade fails open (`try/rescue` + `catch :exit` → pass-through): a budget guard
  must never break a tool call. No-tenant/no-session calls pass through unguarded (the
  OutputShaper posture).

## Mechanics

Three mechanisms per `{tenant, session, agent}` key (`Reasoning.Compactor.Identity`;
state in `LoopGuard.Store`, in-memory **per node** — clustered cron `:agent` jobs fire
on every node, so the worst-case budget scales with node count):

1. **Identical-call runs**: a trailing run of ≥4 identical `{tool, sha256(args)}` calls
   in the last 8 halts immediately, success-agnostic — the 4th call never executes.
2. **Failure signatures**: any failure signature (`{tool, first-100-chars}`; typed
   classification — `{:error, _}` tuples, run_command's `{:ok, %{exit_code: n}}` with
   `n != 0`, or the MCP proxies' re-surfaced `{:ok, %{"isError" => true}}` domain
   failures, never error-string sniffing) reaching 3 in the last 20 error results
   triggers a staged response: a recovery directive appended to the field the LLM reads
   (`message`, `output` for the nonzero-exit OK shape, or an appended `content` text
   item for the MCP isError shape) twice, then a halt.
3. **Call budget**: 100 executed calls per key cap the budget — the 101st is blocked,
   with a one-time log+Trace warn at 80% (never injected into results).

Halts are sticky for `halt_ttl_ms` (5 min), then the key resets fresh; idle keys expire
after `idle_ttl_ms` (30 min).

## Config & telemetry

Config under `:loop_guard` (`enabled?: false` in test). Telemetry counter
`jido_claw.loop_guard.total` plus `:guardrail` Trace events — the channel's first
producer.

## Residuals & accepted risks

Feed-boundary residuals (documented + test-pinned): `Jido.Exec`/`Turn` wrap AROUND
`run/2`, so param-validation failures, Exec/Turn timeouts, and raised exceptions bypass
observation (under-detection), and an output-schema validation failure after `{:ok, _}`
records a **false success** — neutralized cross-tool by per-tool clearing, with
same-tool identical-args repeats still caught pre-execution; the residual is
varied-args output-validation loops only.

## Source map

- `lib/jido_claw/agent/loop_guard.ex` — facade: `check/4`, `observe_result/5`, halt
  envelope construction, fail-open wrapper
- `lib/jido_claw/agent/loop_guard/store.ex` — per-key in-memory state, halt/idle TTLs
- `lib/jido_claw/tools/action.ex` — pipeline seam (approval gate → loop guard →
  normalize → redact → shape → cap)
- `test/jido_claw/agent/loop_guard_test.exs` — thresholds, the Exec/Turn contract
  test, feed-boundary pins
