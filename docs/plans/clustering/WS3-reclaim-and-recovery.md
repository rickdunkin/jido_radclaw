# WS3 — Reclaim & recovery hand-off

*Builds: dead-node reclaim, and the reconciliation of boot-recovery with
clustering. Depends on: WS1 (claim selector), WS2 (composer state rebuild). Closes
the load-bearing gotcha.*

> **Status: shipped.** `JidoClaw.Orchestration.ReclaimPooler` (the per-node
> claim→dispatch loop) + `WorkflowRecovery.reclaim/1` / `reconcile_one/1` (the
> live-reclaim entries) + the safe `:claimable` selector (Component 2) + the
> lease-aware, zombie-fencing composer child-step (Component 4). The Pooler is
> **always-on in every serve mode** (incl. `:mcp`) and both single- and multi-node.

> **Post-ship review (P1/P2 fixes).** The always-on Pooler exposed two issues the
> single-node degrade path created, now fixed: **(P1)** a single-node "degrade
> without heartbeat" (middleware sidecar fail, composer parent sidecar fail) no
> longer leaves a stamped-but-unrenewed lease that lapses into reclaim of a *live*
> executor — it now **suspends** the claim via `WorkflowLease.degrade_gate/2`
> (`suspend_claim/2`: NULL `claim_expires_at`, **keep** `claim_token`) ⇒
> unreclaimable + boot-recovery-only, and proceeds degraded **only when the suspend
> took**; a lost/failed suspend **fails closed** (abort/stop), the row left for
> reclaim/boot. **(P2)** a live reclaim that rotates the parent token no longer has
> the rotated token swallowed by a stale local composer: `RouteComposer.ensure_started/2`
> now validates ownership by **exact token identity** (`:get_claim_token` handshake)
> and evicts + restarts a stale owner so the rotated token reaches a live process.

> **Post-ship review (P1 follow-up — stamp-error fail-close + reclaim re-arm).** The
> genesis-shaped stamp-error degrade in `Lease.Middleware` was *also* claim-blind: a
> `GateResume`/boot-recovery **re-stamp** of an already-claimed run (`:running` +
> checkpoint + `approval_resolved`, or a gate-parked-then-approved run) that hits a
> transient `stamp/4` `{:error, _}` would, single-node, proceed DEGRADED while the row
> still held the PRIOR token and the resume held a FRESH one — lapsing into reclaim of
> a *live* executor **and** stranding it behind fences A/B (which reject the fresh
> executor's own terminal). Fixed: the stamp-error path is now **claim-aware**
> (`stamp_error_degrade/4`). Only a **genesis** (`nil`-prior) stamp-error still degrades
> single-node (byte-identical); an **already-claimed** re-stamp **fails closed in both
> modes** — no executor runs, and finalize's fence A (prior ≠ fresh held token) leaves
> the run `:running` with NO terminal, to be re-resumed from the checkpoint by
> reclaim/boot. Before failing closed it **re-arms** the prior claim's expiry
> (`WorkflowLease.release_for_reclaim/2`, a `now() + reclaim_cooldown` token-fenced
> push, single-sourced with `WorkflowRecovery`'s release-on-defer) so a NULL-expiry
> sidecar-degrade residual (`{prior, NULL, :running}`, which `:claimable` excludes) is
> **Pooler-reclaimable, not boot-recovery-only**. The cooldown (not `now()`) is
> load-bearing — this fail-close can itself run inside a Pooler `reclaim → GateResume`
> drain, so a `now()` re-arm would hot-loop. The **composer parent needs no analogue**:
> it stamps only at genesis and re-*renews* (not re-stamps) on resume, and its
> sidecar-degrade already re-arms via `renew`.

> **What this owns.** Making lease-expiry the continuous dead-node recovery path,
> and fixing the fact that enabling clustering today *silently disables*
> stranded-run recovery (README §"the load-bearing gotcha").
>
> **Mandate broadened (WS1 hand-off).** WS1 shipped the lease *mechanism* but no
> consumer of `WorkflowLease.claim_next/1`, because there is **no general
> "reconstruct a reactor from a stored `WorkflowRun` and run it" seam** (runs
> execute in-process holding their reactor). So WS3 now also owns: **(1) the
> Pooler** (the per-node claim→dispatch loop, formerly WS1 Component 4) **and its
 always-on gating** (formerly WS1 D2 — **decided: always-on**, in every serve mode
> incl. `:mcp`); **(2) the dispatch routing** a claimed orphan needs — which, under
> Q1, requires **no reactor-reconstruction seam**: a stranded plain run is *failed*
> (re-run needs step-level idempotency, deferred), and a composer parent rebuilds via
> WS2; **(3) the production trigger** for WS1's already-shipped-but-dormant
> `claim_next/1`
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
   lapses; the always-on `ReclaimPooler` claims and resumes them. Handles the
   **continuous multi-node dead-node** case (and the single-node "no owner-monitor"
   intra-node task-death gap), with a bounded recovery window = lease length.
   **Shipped — this is WS3.**

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

### Boot ≠ reclaim: the governing insight

Boot recovery and live reclaim are **different paths with different liveness
assumptions, and must not share child-disposition logic verbatim.**

- **Boot** runs once when the BEAM has just restarted, so *nothing from the prior
  runtime is live* — every non-terminal run is dead by construction, decidable from
  DB state alone, with no surviving executor to fence.
- **Live reclaim** runs continuously *alongside live launches and executors* — a
  lease expiry proves only *that one run's* owner died, not its neighbours', and a
  still-alive zombie (a partition) may need actively fencing.

The unifying rule WS3 adopts: **the lease is the liveness oracle.** A run (parent
*or* child) is dead — and reclaimable — **iff its lease has expired (or it is an
aged, never-claimed `:pending` row — the one leaseless case)**; and the act of
claiming it **rotates its token**, which fences any surviving zombie (its stale-token
renew returns 0 → its sidecar self-kills, and any terminal it attempts trips
fence B).

### Reclaim drives the existing reconciliation

When the Pooler's `claim_next/1` returns a run it reclaimed (token already rotated),
it routes the run through `WorkflowRecovery.reclaim/1`, then resumes it:

- **Plain reactor run** — reconcile by `(status, checkpoint)`: an ungated `:running`
  reclaim with no checkpoint is stranded → **fail** (boot-parity, Q1). The
  idempotency key is *launch-dedupe, not step-idempotency*, so re-running a
  partially-executed reactor double-executes side effects regardless of any key —
  there is no safe re-run today (the re-run seam is deferred until step-level
  idempotency exists). A `:running` reclaim that carries a checkpoint **and** a
  recorded `approval_resolved` event resumes via `GateResume(recovered: true)` **on
  the reclaiming node** (the "`GateResume` re-claims on whichever node resumes"
  point). A parked `:awaiting_approval` run is *not* in the reclaim set at all
  (`:claimable` selects only `:pending`/`:running`).
- **Composer parent** (`workflow_type: "composer"`) — the **reclaim-specific
  child-step**: for each non-terminal child, drive it through `claim_run/1`'s full
  `:claimable` predicate under a `FOR UPDATE` lock; a claimable (expired/aged) child
  is **token-rotated** (fencing a surviving zombie child) + failed, while a
  live-lease child and a parked gate are **left** for `restartable?/3` to defer on.
  Then rebuild state from the parent log and resume mid-route (WS2 / AR-2 §6). On a
  deferred restart the parent lease is released on a `poll_interval` **cooldown** (not
  `now()`) so it re-claims on the next poll, never within the same drain. (Boot's
  fail-*all*-children path is unchanged and used only at boot, where its premise —
  nothing live — holds.)

### `owns_recovery?` unchanged; the Pooler is always-on

The fix is **not** to re-enable the boot sweep under clustering (it would race live
owners), and **not** to gate the Pooler the way the boot sweep is gated. Instead:

- **Boot sweep (`owns_recovery?`)** stays single-node / non-MCP / non-clustered
  (**unchanged**) because it is *unguarded* — it blind-fails every non-terminal run,
  so concurrent owners would race.
- **Reclaim Pooler (`owns_reclaim?` = `reclaim_enabled?`)** carries **no**
  serve-mode/cluster conditions: every claim is a `FOR UPDATE SKIP LOCKED` +
  token-CAS, so it is safe everywhere precisely *because* it is claim-gated. MCP
  launches workflows too (`run_skill` → `ReactorRunner.run`), so it must be covered.

The two are **complementary**, not mutually exclusive: the `FOR UPDATE` +
the `:illegal` terminal-on-terminal guard make any single-node overlap idempotent
(≤ one terminal; a second attempt is a no-op), and the Pooler's `initial_delay_ms`
lets the boot one-shot win the first sweep.

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
- **D2 — resume vs fail for stranded `:running` (decided: fail).** Reuse
  `WorkflowRecovery`'s classification: a checkpoint **+ a recorded `approval_resolved`
  event** resumes via `GateResume`; **no checkpoint → fail** (NOT re-run). The
  idempotency key is launch-dedupe, not step-idempotency, so a partially-run reactor
  cannot be safely re-run — the re-run seam is deferred until step-level idempotency
  lands (no current workstream). **No reactor-reconstruction seam is needed.**

## Test plan

- **Reclaim selector** — an expired `:running` run is claimable; the reclaiming
  node runs the correct reconciliation branch for its `(status, checkpoint)`.
- **Composer reclaim** — a composer parent whose owner "died" (lease expired)
  rebuilds state from the log and resumes from the next wave (folding completed
  waves, not re-running them).
- **Always-on, both modes** — `cluster_enabled: true` → boot off, reclaim on;
  `false` → both may touch one stranded run, with ≤1 terminal (the second attempt
  hits the `:illegal` terminal-on-terminal guard, a no-op). The Pooler runs in every
  serve mode, including `:mcp`.
- **No fresh-pending steal** — a just-created `:pending`+nil-token run is not
  claimable within the genesis grace (Component 2's age cutoff); aged past it, it is.
- **Child token rotation fences a zombie** — a reclaimed corpse child's token is
  rotated, so a reconnecting zombie's stale-token renew returns 0 and any terminal it
  attempts trips fence B.
- **Bounded window** — a run is reclaimable no sooner than its lease expiry and no
  later than expiry + one poll interval (asserted with a clock-skew grace band:
  eligibility is app-clock, expiry DB-stamped).

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
