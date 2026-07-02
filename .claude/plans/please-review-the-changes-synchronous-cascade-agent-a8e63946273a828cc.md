# AR-2 Route Composer + Orchestration Observability — Review Findings

Read-only review of commits 2026-06-20 → 2026-07-01. Findings ranked by severity.
Full details returned in the assistant message; this file is the durable record.

## High
(none — no correctness/security defects rising to high were confirmed)

## Medium
- M1 inspect_workflow/diagnostics do an UNBOUNDED WorkflowEvent.for_run (full-log
  load) on every MCP call — workflow_view.ex:186, diagnostics.ex:347. Contrast the
  deliberately byte-paginated workflow_events. Long composer logs → memory/latency.
- M2 Composer parent deadline (deadline_at_ms) is only enforced inside
  handle_continue(:tick) via over_budget?/past_deadline?; a run parked on a human
  gate never re-ticks, so it can sit :running past its wall-clock deadline
  indefinitely. No deadline timer (route_composer.ex ~1291-1307, park path ~1846).

## Low
- L1 ensure_parent_live reload blip (`_other -> :ok`) proceeds to launch the wave
  (documented residual child-create window). route_composer.ex:1483.
- L2 art_ refs are 48 bits of randomness (composer_artifact.ex:373); tenant filter
  makes cross-tenant collisions moot, but intra-tenant birthday-bound is modest.
- L3 AGENTS.md says "24 tools"; publish list length should be re-counted (doc nit).

## Load-bearing facts VERIFIED (not defects)
- Tenant scoping: every MCP observability read uses tenant-scoped WorkflowRun.by_id
  + WorkflowEvent.for_run (tenant:/actor:); by_id_global is recovery-only. MCP tenant
  is the fixed boot scope, not a client param. Cross-tenant read → :not_found.
- P1 leak closure: only 2 decrypt sites (ArtifactContext wave boundary,
  EmitApprovedPlan), both tenant-scoped; observability carries names+refs only.
- Loop termination bounded: max_waves (each tick) + per-stage rerun_cap (fixer/verify).
- Projection determinism: seq-ordered set ops; Kahn frontiers alpha-sorted.
- Crash recovery: at-most-once launch dedupe on composer:<parent>:<wave_index>;
  recovery restarts only when children terminal (or gate, Phase 4d).
- Gate double-approve: FOR UPDATE reload + change filter(status==:pending) fence.
- Byte-pagination: +1 sentinel, ≥1 event kept, next_seq=last-kept-seq (no silent
  drop / no infinite loop / no mid-event data loss — truncated events marked).
- enforce_completion_signals injects only publishes∩@completion_signals (no
  validate_publishes bypass).
