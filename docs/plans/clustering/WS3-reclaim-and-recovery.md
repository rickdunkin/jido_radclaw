# WS3 — Reclaim & recovery hand-off

*Builds: dead-node reclaim, and the reconciliation of boot-recovery with
clustering. Depends on: WS1 (claim selector), WS2 (composer state rebuild). Closes
the load-bearing gotcha.*

> **What this owns.** Making lease-expiry the continuous dead-node recovery path,
> and fixing the fact that enabling clustering today *silently disables*
> stranded-run recovery (README §"the load-bearing gotcha").
>
> **Mandate broadened (WS1 hand-off).** WS1 shipped the lease *mechanism* but no
> consumer of `WorkflowLease.claim_next/1`, because there is **no general
> "reconstruct a reactor from a stored `WorkflowRun` and run it" seam** (runs
> execute in-process holding their reactor). So WS3 now also owns: **(1) the
> Pooler** (the per-node claim→dispatch loop, formerly WS1 Component 4) **and its
> always-on-vs-`cluster_enabled` gating** (formerly WS1 D2); **(2) the
> reconstruction/dispatch seam** a claimed orphan needs to actually run; **(3)
> the production trigger** for WS1's already-shipped-but-dormant `claim_next/1`
> and the runner/append fence branches. The reclaim mandate spans **both**
> clustering dead-node reclaim **and** single-node intra-node task-death (the
> "No owner-monitor" gap — a run whose in-process executor task dies without the
> node restarting; see README §coverage matrix).

## The two recovery mechanisms

There are two, and they are **complementary, not redundant**
(`REACTOR-ADOPTION.md:661-662,687-689`; `T1-1-WORKFLOW-EVENT-LOG-PLAN.md:432-434`):

1. **Boot reconciler** — `WorkflowRecovery` reconciles runs left non-terminal by a
   crash, at node boot. Handles the **single-node restart** case. Shipped.
2. **Lease-expiry reclaim** — a dead node's runs become claimable once their lease
   lapses; another node claims and resumes them. Handles the **continuous
   multi-node dead-node** case, with a bounded recovery window = lease length.
   **Deferred — this is WS3.**

## The gotcha, precisely

`WorkflowRecovery` self-gates **off** when clustering is on:

```elixir
# lib/jido_claw/orchestration/workflow_recovery.ex:468-472
defp owns_recovery? do
  recovery_enabled?() and
    Application.get_env(:jido_claw, :serve_mode) != :mcp and
    Application.get_env(:jido_claw, :cluster_enabled, false) != true   # ← off when clustered
end
```

This is *correct* intent — in a cluster a boot-time sweep can't assume a
`:running` run is stranded (another live node may own it). But it leaves a hole:
**the lease-expiry path that's supposed to replace it doesn't exist.** Today,
`cluster_enabled: true` = no stranded-run recovery at all. WS3 fills the hole, and
only then is flipping the flag safe.

## Reuse / current state

- **The reclaim *selector* is WS1's `:claim_next`.** Its second clause —
  `status == :running AND claim_expires_at < now()` — **is** the dead-node
  reclaim trigger. WS3 doesn't add a new scanner; it defines what the claiming
  node *does* with a reclaimed run.
- **The per-status reconciliation logic already exists.** `WorkflowRecovery`
  already classifies non-terminal runs by `(status, checkpoint)` and drives each
  branch (stranded `:running` → `:failed`; gated `:awaiting_approval` + checkpoint
  → `GateResume`; dangling gate → reap). WS3 reuses this classification, triggered
  by reclaim instead of boot.
- **Composer state rebuild is WS2 / AR-2 §6.** A reclaimed composer parent rebuilds
  `live`/`ran`/`available`/`premises` from the parent event log and resumes
  mid-route. That machinery is shipped (Phase 2); WS3 just invokes it on reclaim.

## Design

### Reclaim drives the existing reconciliation

When a node's `:claim_next` returns a run it reclaimed (an expired `:running`
run), it routes the run through the **same `WorkflowRecovery` reconciliation
branches** the boot reconciler uses, then resumes it:

- **Plain reactor run** — reconcile by `(status, checkpoint)`: an ungated
  `:running` reclaim with no checkpoint is stranded → re-run (idempotency key makes
  this safe); a gated `:awaiting_approval` reclaim with a checkpoint resumes via
  `GateResume` **on the reclaiming node** (this is the "`GateResume` re-claims on
  whichever node resumes" point, gust cross-ref `gust/…:176-177`).
- **Composer parent** (`workflow_type: "composer"`) — rebuild state from the parent
  log and resume mid-route (WS2 / AR-2 §6), re-parking if a child gate is still
  open.

### Re-frame `owns_recovery?` as claim-driven under clustering

The fix is **not** to re-enable the boot sweep under clustering (it would race
live owners). Instead:

- **Single-node (`cluster_enabled: false`):** boot reconciler runs as today
  (unchanged).
- **Clustered (`cluster_enabled: true`):** recovery becomes **claim-driven** — the
  Pooler's reclaim sweep (WS1 D2) continuously picks up expired runs and routes
  them through the reconciliation branches. The boot reconciler stays off; the
  reclaim sweep replaces it.

So `owns_recovery?` keeps gating the *boot sweep*, and WS3 adds the *reclaim sweep*
as the clustered-mode equivalent. The two never both run on the same run (boot
sweep only when `cluster_enabled: false`; reclaim only when `true`).

### Bounded window + telemetry

A dead node's runs are unrecoverable for at most one lease length (~60s, WS1
tuning). Emit lease/reclaim telemetry alongside the existing
`[:jido_claw, :orchestration, :recovered]` event (`workflow_recovery.ex:460-466`)
so reclaim is observable: claimed / renewed / reclaimed / fenced-out counts.

## Decisions

- **D1 — reclaim eligibility for gated runs.** A parked `:awaiting_approval`
  *single* run holds no lease (nothing is renewing it), so it is *not* in the
  `:running AND expired` reclaim set — it is recovered by `GateResume` on resume
  (the operator's approval lands on some node, which claims + resumes). Confirm
  this matches the shipped park semantics: a parked run is durable in the DB with
  no live owner, by design. The **composer parent** is the exception (it *does*
  hold a lease across the pause — WS2), so a dead-node composer parent IS
  reclaimed.
- **D2 — re-run vs resume for stranded `:running`.** Reuse `WorkflowRecovery`'s
  existing decision (checkpoint present → resume; absent → re-run under
  idempotency key). No new policy.

## Test plan

- **Reclaim selector** — an expired `:running` run is claimable; the reclaiming
  node runs the correct reconciliation branch for its `(status, checkpoint)`.
- **Composer reclaim** — a composer parent whose owner "died" (lease expired)
  rebuilds state from the log and resumes from the next wave (folding completed
  waves, not re-running them).
- **No double-recovery** — with `cluster_enabled: true`, the boot reconciler does
  not run; with `false`, the reclaim sweep does not run. Exactly one path per mode.
- **Bounded window** — a run is reclaimable no sooner than its lease expiry and no
  later than expiry + one poll interval.

Cross-node "kill a node, watch another reclaim its runs" is the WS6 multi-node
integration test.

## Cross-references

- `workflow_recovery.ex:468-472` (the gate), `:460-466` (telemetry).
- Squidie §4.8 (boot reconciler) + §4.11 (lease complement) —
  `REACTOR-ADOPTION.md:641-643,687-689`.
- T1-1 — `T1-1-WORKFLOW-EVENT-LOG-PLAN.md:432-434` (same complementary framing).
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — the `:claim_next` reclaim selector.
  WS2 ([WS2-composer-lease.md](WS2-composer-lease.md)) — composer state rebuild on
  reclaim.
