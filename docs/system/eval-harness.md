---
type: subsystem
description: Deterministic eval cases run against production functions only — prompt/schema/composer/coherence kinds, loud unknown-assertion failures.
sources:
  - lib/jido_claw/eval.ex
  - lib/jido_claw/eval/case.ex
  - lib/jido_claw/eval/run.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Deterministic Eval Harness

## What & why

`JidoClaw.Eval.{Case,Run}` package `{kind, request, assertions}` cases that pin the
platform's LLM-facing surfaces (prompts, output schemas, composer routes, doctrine
coherence) deterministically — so a prompt or schema regression fails a test, not a
production run.

## Invariants & contracts

- Cases run via `JidoClaw.Eval.run_case/2` against **production functions only** — no
  new runtime path.
- The fake↔live seam is the caller's app-env arming + `run_case` opts
  (`tenant`/`actor`/`context`/`timeout`), never a test module named in lib.
- Unknown assertion keys fail loudly: an `:unknown_assertion` record fails the run — a
  deliberate deviation from jidoka's silent skip. A malformed assertion value/item
  fails via `:invalid_assertion_value`, an evaluator raise via `:assertion_raised`.

## Mechanics

Four kinds, each bound to a production function:

- `:prompt` — the assembled `SubagentPrompt.build/3`
- `:schema` — a worker's `strategy_opts()[:output]` via `Jido.AI.Output.parse/2`
- `:composer` — `RouteComposer.run_sync/1` through the real gate dance
- `:coherence` — doctrine-slice prose ↔ per-token schema probes (the
  prose-half/schema-half field contracts)

## Config & telemetry

No app config; arming is per-call (app-env + opts). No dedicated telemetry — runs
surface through test output.

## Residuals & accepted risks

None recorded.

## Source map

- `lib/jido_claw/eval.ex` — `run_case/2`, kind dispatch
- `lib/jido_claw/eval/case.ex` — case packaging
- `lib/jido_claw/eval/run.ex` — assertion evaluation, failure records
- `test/jido_claw/eval/` — seed cases pinning the post-AR-9 prompt surface
- `test/jido_claw/eval_test.exs` — harness unit tests
