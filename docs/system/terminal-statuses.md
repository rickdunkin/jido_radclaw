---
type: subsystem
description: Cross-wave finding identity, stuck/oscillating stall detection, the review_stall park, and the done_with_findings completed-family disposition.
sources:
  - lib/jido_claw/route_composer/finding_key.ex
  - lib/jido_claw/route_composer/fold.ex
  - lib/jido_claw/route_composer/route_composer.ex
  - lib/jido_claw/orchestration/cases.ex
  - lib/jido_claw/orchestration/visibility.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Honest Terminal Statuses + Stall Detection

## What & why

A review loop that can't converge must neither spin forever nor lie green. Findings get
a durable cross-wave identity so the composer can *see* a stall (a finding surviving
its own fix round, or flapping in and out), stop the fix loop, and park for a human
decision — and the resulting completion is marked as "completed · findings", never
plain green. Port provenance: camus C1-4 + C1-5, next-ten #6.

## Invariants & contracts

- Reviewer findings carry a cross-wave identity: a required short `title` +
  `JidoClaw.RouteComposer.FindingKey`, welded per reviewer round into the wave commit
  as a `:finding_keys` marker — the marker IS the durable identity (findings persist as
  encrypted `ComposerArtifact` rows the projection never decrypts). Un-keyable findings
  are excluded — never a fabricated identity.
- `fix_stop_lenses/1` (stall evidence ++ re-review-budget exhaustion — never dispatch a
  fix its flagged lens has no budget to re-review) suppresses ALL of Hook R.
- On a **green AND certified** verify (`verify_green_certified?/1`) the composer parks
  at a `:review_stall` gate instead of terminalizing: a **parent-stays-`:running`,
  child-less park** raising a durable run-bound `AgentCase`.
- Approve requires **per-finding waive records covering every surviving key**
  (all-or-reject, `{:error, :incomplete_waiver}` — orca OQ-1 as decided); reject ⇒
  `fix_failed`. Approval terminalizes `:route_done_with_findings` — the
  **completed-family** disposition every surface marks, never plain green; verbatim
  finding bodies never ride the result (redaction posture).
- Verify-less/red routes keep today's terminals (a red-verify stall lands
  `fix_failed`).

## Mechanics

- **Key derivation**: `{:v1, normalized-location-file, downcased-title}` through
  `Core.CanonicalHash.sha256_term/1` — title downcased, file NOT. A clean round welds
  `keys: []` to advance the lens round. The marker carries hex keys + enum
  severity/confidence marks only.
- **Stall detection** in the fold: **stuck** = a key survives its own fix round;
  **oscillating** = a key reappears after absence.
- **The park case**: fingerprint over the sorted keyable keys; raise-time decrypt →
  `Transcript.redact` → per-field bounds on the case details; camus C3-2 `resume_hint`
  included; deadline TTL abandons, committed-decision-beats-deadline. Decided through
  kind-dispatched `Cases.decide/4`/`abandon/3` branches — never
  `GateStep`/`GateResume`.
- **Waiver validation** happens PRE-transaction (the `Ash.transact`-wraps-errors-opaque
  precedent); waive records land on the case's `:approved` timeline event.
- The result carries `result.disposition = "done_with_findings"` +
  keys/counts/severity histogram/trend/certified head.
- **Surfaces**: `Visibility.run_view` carries `disposition`/`findings_deferred_count`
  (every downstream surface inherits), the web badge renders amber
  "completed · findings", `WorkflowView` rolls up `findings_deferred` over its
  recent-completions window, CLI text/JSON mark the disposition (headless exit stays
  0).
- **The waived-debt ledger** is `Cases.waived_findings_ledger/2` (a filter over gate
  decisions — no new table) + the `jido.debt` Lua binding.
- **Recovery** re-derives the park from the rebuilt state and resolves by fingerprint
  with zero recovery-code changes.
- The adjacent disposition vocabulary (traycer TR3-2 `superseded`, pad PD3-3 lineage
  badges, bosun BO2-6 retry verbs) is deliberately named-not-built in the `Gate.Kinds`
  moduledoc.

## Config & telemetry

Telemetry: `jido_claw.composer.stall.total` (per-lens :stuck/:oscillating/:exhausted)
+ one bounded `:composer` `:fix_stopped` Trace event (hex keys only).

## Residuals & accepted risks

None recorded; the deliberate scope edges (verify-less/red routes keep their terminals,
adjacent vocabulary named-not-built) are design decisions.

## Source map

- `lib/jido_claw/route_composer/finding_key.ex` — key derivation, un-keyable exclusion
- `lib/jido_claw/route_composer/fold.ex` — stuck/oscillating detection,
  `fix_stop_lenses/1`
- `lib/jido_claw/route_composer/route_composer.ex` — the `:review_stall` park,
  `verify_green_certified?/1`
- `lib/jido_claw/orchestration/cases.ex` — kind-dispatched decide/abandon, waiver
  completeness, `waived_findings_ledger/2`
- `lib/jido_claw/orchestration/visibility.ex` — `run_view` disposition fields
