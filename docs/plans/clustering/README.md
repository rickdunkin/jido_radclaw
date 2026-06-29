# Plan: Clustering — Make Multi-Node Workflow Execution Real

*Architecture direction + phased adoption — not a commitment.*

Land the deferred clustering behavior so JidoClaw can run as a multi-node
cluster without double-executing, losing, or stranding workflow runs. The
infrastructure (libcluster + `:pg`) already exists and is off by default; this
plan builds the *behavior* every prior doc deferred "until clustering is real."

---

## The thesis: it all converges on one feature

Four separate exploration docs deferred a clustering feature. They are **four
descriptions of the same mechanism** — a durable, DB-as-source-of-truth
claim-lease on `WorkflowRun`:

- **gust G1-1** — "Distributed run-claiming: lease + fence token + `SKIP LOCKED`
  + advisory-lock leader" (`docs/exploration/gust/FEATURES-WORTH-BORROWING.md:88-178`).
- **Squidie REACTOR §4.11** — "Distributed work-claiming (when clustered)": the
  Ash/Reactor re-expression that *shipped its data model*
  (`docs/exploration/squidie/REACTOR-ADOPTION.md:659-690`).
- **Squidie T2-4** — "Lease/fencing claim discipline for workers"
  (`docs/exploration/squidie/FEATURES-WORTH-BORROWING.md:280-294`). Its separate
  `WorkflowAttempt` resource sketch is **obsolete** — the shipped model folded
  claim state onto `WorkflowRun`.
- **AR-2 §10.1 / Phase 6** — the *same* lease, re-derived so the unit of claim is
  the **parent composer run** (which spans N waves) rather than one `Reactor.run`
  (`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md:875-904`, `:1053`).

The lease *mechanism* is small (gust calls it "~100 lines"). The cost is the
envelope around it: how runs launch, a singleton audit the docs under-scope, the
recovery hand-off, and real multi-node tests. This plan splits that into six
workstreams (below).

## The load-bearing gotcha

Boot recovery **turns itself off** the moment clustering is enabled:

```elixir
# lib/jido_claw/orchestration/workflow_recovery.ex:468-472
defp owns_recovery? do
  recovery_enabled?() and
    Application.get_env(:jido_claw, :serve_mode) != :mcp and
    Application.get_env(:jido_claw, :cluster_enabled, false) != true   # ← off when clustered
end
```

The design intent is that **lease-expiry reclaim replaces the boot reconciler**
under clustering (continuous dead-node recovery vs single-node restart). But the
lease doesn't exist — so flipping `cluster_enabled: true` today silently strands
every interrupted run with nothing to recover it. **This makes the lease a hard
prerequisite for safe multi-node, not an enhancement** (WS1 + WS3).

---

## Background

### What already ships (the clustering baseline)

Clustering is more built-out than the docs' tone suggests. It is **OFF by
default** (`config/config.exs:186`, `cluster_enabled: false`) but the plumbing
works when enabled:

| Area | Status | Where |
|---|---|---|
| libcluster (gossip/k8s/epmd) + `:pg` scope, conditional on `cluster_enabled` | ✅ shipped | `application.ex:411-431`, `core/cluster.ex` |
| Forge cross-node session discovery + atomic claim | ✅ shipped (`:pg` + `pg_advisory_xact_lock`) | `forge/persistence.ex`, `forge/harness.ex`, `forge/manager.ex` |
| Embedding cross-node dispatch budget (Postgres UPSERT counter) | ✅ shipped (active even single-node) | `embeddings/rate_pacer.ex` |
| Embedding backfill claim + row-lease (`FOR UPDATE SKIP LOCKED`) | ✅ shipped — **the reference pattern for WS1** | `embeddings/backfill_worker.ex:5,19,178-190` |
| Memory consolidator cross-node lock (session `pg_try_advisory_lock`) | ✅ shipped | `memory/consolidator/lock_owner.ex`, `memory/scope.ex:217-225` |
| `WorkflowRun` claim/lease **mechanism** (self-claim on launch + token CAS + renew-fence + both terminal fences + `claim_next`/`claim_run` primitives) | ✅ **WS1 + WS3 shipped** — the columns now have a live consumer: the always-on `ReclaimPooler` → `WorkflowRecovery.reclaim/1` (every serve mode, incl. `:mcp`) | `orchestration/workflow_lease.ex`, `orchestration/reclaim_pooler.ex`, `workflow_lease/{middleware,sidecar}.ex`, `workflow_run.ex` |
| Run-level launch-dedupe key (`composer:<parent>:<wave>`, `cron:<job>:<window>`) — **launch-dedupe, not step-idempotency**; a composer parent carries none, so a partially-run reactor is failed (not re-run) on reclaim | ✅ shipped | `reactor_runner.ex:243-328` |

So "make clustering real" is **not** about building libcluster. It is about
making multi-node *workflow execution* correct, and auditing the always-on
singletons that would otherwise multi-fire.

### What's deferred (the scope of this plan)

The lease *behavior* and everything that depends on it. Enumerated in the
coverage matrix below; designed across WS1–WS6.

### What this plan does *not* do (non-goals)

- **BEAM-distribution bootstrap / node discovery beyond libcluster.** Gossip/k8s/
  epmd topologies already exist (`core/cluster.ex:97-160`); operationalizing a
  real deployment (DNS, secrets, orchestration) is ops work, not in scope here
  beyond the config notes in WS6.
- **Work-stealing / graceful-drain between *live* nodes.** gust only does
  dead-node recovery and explicitly notes this gap
  (`gust/FEATURES-WORTH-BORROWING.md:145`). We inherit dead-node-only reclaim;
  live-node rebalancing is a future item (WS4 records it as out-of-scope).
- **Federated/distributed memory across nodes** beyond what `:pg` + Postgres
  already provide — an explicit v0.6 non-goal (`docs/plans/v0.6/README.md:701`).
- **A second leader-lock partition failure mode.** We deliberately do **not**
  port gust's session-bound advisory-lock leader (it stalls cron globally on a
  partition); WS4 uses `:pg` instead, per `REACTOR-ADOPTION.md:681-684`.

### Reference research

This plan synthesizes the clustering deferrals across the gust, squidie, and
alp-river (AR-2) exploration docs, reconciled against the current codebase. The
single-feature convergence and the recovery gotcha were established by a
codebase audit (see the per-WS "Reuse / current state" sections for `path:line`
evidence).

---

## Workstream summary

```
WS1   Lease core              :claim_next + :renew actions, Pooler, Lease middleware   [keystone]
WS2   Composer lease          AR-2 Phase 6 / §10.1 — renew parent across waves         (needs WS1)
WS3   Reclaim & recovery      lease-expiry reclaim; close the owns_recovery? gotcha     (needs WS1, WS2)
WS4   Leader election + audit :pg leader election; classify every always-on singleton  (needs WS1)
WS5   Cross-node cancellation route the kill to the owning node                         (needs WS1)
WS6   Testing & ops           multi-node test harness, deploy config, gate fixes        (cross-cutting)
```

Each workstream is independently reviewable and is sized to ship as its own
point release (a few may split further during implementation planning). They are
**not strictly linear** — WS2, WS4, and WS5 can proceed in parallel once WS1
lands; WS3 needs WS1 (and WS2 for composer runs); WS6 is woven throughout.

**Recommended sequence:** WS1 → WS3 (closes the recovery gotcha) → WS2 + WS4 +
WS5 in parallel → WS6 throughout, finalized last. WS1 is the keystone everything
depends on; do not enable `cluster_enabled` in any real deployment until at least
WS1 + WS3 have landed (see the gotcha above).

| WS | Doc | Size | Depends on |
|---|---|---|---|
| WS1 | [WS1-lease-core.md](WS1-lease-core.md) | L (~1–2 releases) | — |
| WS2 | [WS2-composer-lease.md](WS2-composer-lease.md) | M | WS1 |
| WS3 | [WS3-reclaim-and-recovery.md](WS3-reclaim-and-recovery.md) | M | WS1, WS2 |
| WS4 | [WS4-leader-election-and-singletons.md](WS4-leader-election-and-singletons.md) | M–L | WS1 |
| WS4a | [WS4a-clustered-cron-ownership.md](WS4a-clustered-cron-ownership.md) | M | WS4 |
| WS5 | [WS5-cross-node-cancellation.md](WS5-cross-node-cancellation.md) | S–M | WS1 |
| WS6 | [WS6-testing-and-ops.md](WS6-testing-and-ops.md) | M | all |

---

## Coverage matrix — every explicitly-deferred clustering item

The goal of this plan is that **nothing previously deferred falls through.** Each
row is a clustering deferral found in a prior doc, mapped to the workstream that
owns it.

| Deferred item | Source | Covered by |
|---|---|---|
| Distributed run-claiming (lease + fence + `SKIP LOCKED`) | gust G1-1 (`gust/FEATURES-WORTH-BORROWING.md:88-178`) | ✅ **WS1 shipped** |
| `claim_next` (selector; shipped as a raw-SQL CAS primitive, not an Ash action — unit-tested, WS3-triggered) | REACTOR §4.11 (`REACTOR-ADOPTION.md:670-674`) | ✅ **WS1 shipped** |
| `renew` (fenced by `(id, claim_token)`; raw-SQL, not an Ash action) | REACTOR §4.11 (`:675-676`) | ✅ **WS1 shipped** |
| `Pooler` GenServer (claim loop → DynamicSupervisor) | REACTOR §4.11 (`:677-678`) | **WS3** (no reactor-reconstruction seam in WS1) |
| `Reactor.Middleware.Lease` (renew sidecar + halt on stale token) | REACTOR §4.11 (`:679-680`) | ✅ **WS1 shipped** |
| Lease tuning (60s/15s) + mandatory step idempotency keys | REACTOR §4.11 (`:686-690`); AR-2 §10.1 (`:887-890`) | **WS1** (keys already shipped) |
| "Lease/fencing for multi-worker execution" (out of scope) | T1-1 (`T1-1-WORKFLOW-EVENT-LOG-PLAN.md:512-513`) | **WS1** |
| "Lease/fencing claim discipline for workers" (still deferred) | T2-4 (`squidie/FEATURES-WORTH-BORROWING.md:280-294`) | **WS1** |
| Stale-completion refusal from a fenced-out worker | T2-4 (`:286`) | **WS1** |
| **Cluster lease re-derived around the composer unit** | **AR-2 §10.1 / Phase 6** (`AR-2-COMPOSER-PLAN.md:875-904`, `:1053`) | **WS2** |
| Composer renews parent across waves + gate pause; no release-on-park | AR-2 §10.1 (`:891-900`) | **WS2** |
| Lease behavior across gate park/resume (`GateResume` re-claims on resuming node) | gust cross-ref (`gust/…:176-177`) | **WS2**, **WS3** |
| Lease-expiry → continuous dead-node recovery (replaces boot reconciler when clustered) | REACTOR §4.11 (`:687-689`); T1-1 (`:432-434`); §4.8 (`:641-643`) | **WS3** |
| Single-node intra-node **task-death** (the executor task dies but the node stays up — "No owner-monitor"; today only a node *restart* triggers recovery) | codebase (`run_execution.ex` "Caller-death semantics … No owner-monitor") | **WS3** (the reclaim mandate spans dead-node **and** intra-node task-death) |
| `owns_recovery?` disabled under clustering with no replacement | codebase (`workflow_recovery.ex:468-472`) | **WS3** |
| Leader election for singletons (cron scheduler) — prefer `:pg` over advisory-lock | REACTOR §4.11 (`:681-684`) | ✅ **WS4 shipped** (`JidoClaw.Cluster.Leader`) |
| Avoid gust's session-bound leader-lock partition failure | gust (`:144`) | ✅ **WS4 shipped** (`:pg` membership, not a held lock) |
| Cluster-correct cancellation (current kill switch is single-node only) | T2-4 (`:294`); gust (`:119-122`) | **WS5** |
| Work-stealing / graceful-drain between live nodes | gust (`:145`) | **WS4** (recorded as non-goal/future) |
| Cron firing not idempotent against leader flapping | gust (`:147-149`) | ✅ **WS4 shipped** — `:system_job` ticks leader-gated; idempotency-key backstop |
| Clustered **user**-cron ownership (CLI-loaded → multi-fire / gateway → no-fire) | codebase (`repl.ex:315`, `cron/scheduler.ex`) | **WS4a** (spun out of WS4) |
| Embedding cross-node counter ignores `:cluster_enabled` (doc-vs-code gap) | doc said gated (`PLAN-v0.6-memory.md:1731-1734`), code unconditional | **WS6** (trivial) |
| Multi-node test harness (only single-node mock exists) | codebase (`test/jido_claw/forge/clustering_test.exs`) | **WS6** |

If you find a deferral not on this list, it belongs in one of the six WS docs —
add the row here when you do.

---

## Related docs

- `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` — §6 (durable envelope), §10.1
  (the composer lease, = WS2), Phase 6 (`:1053`). The composer (Phases 0–5) is
  **already built** (`lib/jido_claw/route_composer/route_composer.ex`).
- `docs/exploration/squidie/REACTOR-ADOPTION.md` — §4.11 (the lease data model +
  deferred implementation), §4.8 (the boot reconciler the lease complements).
- `docs/exploration/squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md` — the event-log
  envelope recovery rebuilds from; lease listed out-of-scope (`:512-513`).
- `docs/exploration/gust/FEATURES-WORTH-BORROWING.md` — G1-1, the source mechanism
  with gust `path:line` references for every component.
- Memory: `[[project_clustering_state]]`, `[[project_workflow_engine_reactor]]`.
