---
type: subsystem
description: The single normalizer for probabilistic judge output — infra ≠ verdict ≠ inconclusive, schema drift fails closed, infra rides its own budget.
sources:
  - lib/jido_claw/orchestration/verdict.ex
  - lib/jido_claw/route_composer/emit/default_mapper.ex
  - lib/jido_claw/route_composer/stage_emission.ex
  - lib/jido_claw/skills/steps/iterative_step.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Verdict Normalizer (infra ≠ verdict ≠ inconclusive)

## What & why

`JidoClaw.Orchestration.Verdict` is the single normalizer every probabilistic judge
output passes through, separating "the judge decided" from "the machinery failed" from
"nobody can know" — the conflation of those three was camus's "#1 cause of runaway
loops". Port provenance: camus C1-3 @ `53da91b3` (MIT), next-ten #4.

## Invariants & contracts

- Three exits: `{:verdict, %Verdict{}}` (`clean? = approve AND zero findings` —
  findings-win), `{:infra, reason}` (empty/non-map/drifted-enum/self-contradicting
  output — **schema drift fails CLOSED to infra**, never a verdict, never clean), and
  `{:inconclusive, reason}` (produced by the deterministic verify — refusals + the
  composer's `"uncertified_green"` reclassification; consumers fold it into the infra
  lane).
- `normalize/2` is total over arbitrary input — it is also the executor seam's
  deposit-tool contract (next-ten #7).
- Infra retries on the SEPARATE per-stage `infra_cap` budget: it never consumes
  `rerun_cap`, never reads clean, never summons the fixer with empty feedback.
  Exhaustion terminalizes `:route_review_infra_failed` (disposition
  `"review_infra_failed"`, outranking fix/verify_failed at the budget gate).
- The five trust-boundary laws + the event-sourced durability checklist live in
  `docs/TRUST-BOUNDARIES.md` (camus C2-8) — the review rubric for orchestration/gate
  changes.

## Mechanics

- **Field coverage**: Review-kind validation is **routing-critical only** (`overall`,
  findings list-ness, finding map-ness, `severity`) — prose fields pass through
  unvalidated, and Zoi still enforces the full schema on the LLM path.
- **Consumer dispatch**: `DefaultMapper` dispatches on **lens presence, not output
  shape** — an infra'd reviewer becomes an emission with no signals/artifacts and
  `outcome: {:infra, reason}` (`StageEmission.outcome`, fail-closed decode on the DB
  trust boundary), which the composer never folds into `ran`.
- **Budget**: the per-stage `infra_cap` defaults to 2 ⇒ 3 attempts (camus's
  INFRA_RETRIES) and is persisted in parent config so a restart keeps a caller's
  override; retries ride durable `:stage_infra` events.
- **Lane A** (unusable verdict): the marker is welded into the wave commit — stage
  names only, no reasons (redaction posture).
- **Lane B** (a **lens-only** cohort's wave-execution error, incl. the
  recovered-failed-child dedupe arm and — post-review P1 — the dedupe-hit observe
  arms: observed-failed / observe-timeout / observe-reload, where the composer still
  has no trustworthy verdict for the lens even though the immediate failure came from
  observation/recovery machinery): appended with `closed_wave_index` so a restart
  rebuilds past the failed wave instead of deduping onto the corpse. Mixed/producer
  cohorts keep the loud `route_failed`; an observed worker `:cancelled`/`:abandoned`
  stays an operator decision, never infra.
- **IterativeStep**: evaluator output goes through `normalize(:iterative_eval, _)` — a
  garbled/tokenless verdict (or an evaluator `AgentRunner` error) re-runs the
  **evaluator only** on `infra_retries` (default 2) without burning an iteration.

## Config & telemetry

`:composer` Trace events (bounded reasons, `run_id`-indexed, tenant-stamped —
post-review P2 attached the channel in the collector and made the timeline reachable
via `Trace.list({:tenant, …})`) + the `jido_claw.composer.infra.total` counter.
`Observe`/`WorkflowView` treat any `closed_wave_index`-bearing event as closing its
wave.

## Residuals & accepted risks

None recorded beyond the lane design itself; the deliberate asymmetries (mixed/producer
cohorts stay loud `route_failed`, observed cancel/abandon stays an operator decision)
are design decisions, not gaps.

## Source map

- `lib/jido_claw/orchestration/verdict.ex` — `normalize/2`, the three exits
- `lib/jido_claw/route_composer/emit/default_mapper.ex` — lens-presence dispatch
- `lib/jido_claw/route_composer/stage_emission.ex` — `outcome`, fail-closed decode
- `lib/jido_claw/skills/steps/iterative_step.ex` — `normalize(:iterative_eval, _)`,
  evaluator-only re-runs
- `docs/TRUST-BOUNDARIES.md` — the five laws + durability checklist
