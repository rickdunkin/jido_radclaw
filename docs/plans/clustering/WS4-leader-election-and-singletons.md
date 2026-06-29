# WS4 — Leader election + singleton audit

*Builds: a `:pg`-based leader election, and a multi-node-safety pass over every
always-on process. Depends on: WS1 (loosely — sequence after). This is the
iceberg the docs under-scope.*

> **Status: SHIPPED.** Leader election (`JidoClaw.Cluster.Leader`) + the
> `JidoClaw.Cluster.leader?/0` façade are live; the cron `:system_job` tick, the
> three retention sweepers, and the embeddings backfill scan are leader-gated;
> the singleton audit below is verified against the current tree. The one unit
> too large for WS-4 — clustered **user**-cron ownership — became its own design
> doc, [WS4a-clustered-cron-ownership.md](WS4a-clustered-cron-ownership.md).

> **What this owns.** The lease (WS1) makes *run execution* cluster-safe. But many
> always-on singletons start on **every node** and would multi-fire under
> clustering. The exploration docs only call out the cron scheduler
> (`REACTOR-ADOPTION.md:681-684`). WS4 builds the leader-election they reference
> **and** audits the full singleton surface — the part no prior doc enumerated.

## Component 1 — Leader election (`:pg`, not advisory-lock) — SHIPPED

`JidoClaw.Cluster.Leader` (`lib/jido_claw/core/cluster/leader.ex`) is a `:pg`-based
leader-election GenServer. **`:pg`, not a held advisory lock**
(`REACTOR-ADOPTION.md:681-684`): gust's leader is a session-bound
`pg_try_advisory_lock` held open by `Process.sleep(:infinity)`, which **stalls all
leader-only work globally** if the leader's TCP survives but the node is
unreachable (`gust/…:144`). `:pg` membership has no such partition-stall.

- **Algorithm: lowest node-name wins** — deterministic and stateless. Every node
  computes the same leader from the same `:pg` membership via `Enum.min/1`
  (`elect/1`); re-election is automatic on the next membership message when the
  lowest node leaves. (First-joiner was rejected — it needs durable join-order
  state for no benefit.)
- **Reuses the `:jido_claw` `:pg` scope** via `JidoClaw.Cluster` (`core/cluster.ex`),
  which gained `monitor_group/1` and the `leader?/0` façade (the
  `:cluster_leader_module` test seam). The Leader joins a well-known
  `:cluster_leader` group, monitors it, and `recompute/2`s the leader on each
  join/leave, emitting `[:jido_claw, :cluster, :leader_changed]` only when the
  leader actually moves.
- **`leader?/0` fails closed + fast** — single node (`cluster_enabled: false`) ⇒
  trivially `true`, no `:pg`/process touched (this is what keeps single-node
  byte-identical); clustered ⇒ a 1s-bounded call that returns `false` if the
  Leader is absent/wedged, so a wedged leader never blocks a cron/sweeper tick.
- **Supervision** — `:pg` + `Cluster.Leader` restart **together** under a
  `:rest_for_one` `JidoClaw.Cluster.LeadershipSupervisor` in `cluster_children/0`
  (`application.ex:456-459`): a `:pg` crash restarts both in order (Leader
  re-inits → fresh join + monitor, never a stale ref); a Leader crash restarts
  only the Leader. libcluster's `Cluster.Supervisor` stays an independent sibling.

## Component 2 — The singleton audit (verified)

Every child in `core_children` (`application.ex:136-319`) starts on **every
node**. Classify each: **safe** (idempotent or already cross-node-coordinated),
**wasteful-but-safe** (correct, but does redundant work N times), or
**needs-gating** (incorrect under N nodes). Verified against the current tree;
the **WS-4** column records what shipped.

| Singleton | Where | Under N nodes | WS-4 |
|---|---|---|---|
| `Cron.Worker` `:system_job` ticks | `cron/worker.ex` (`leader_gated?/1`), `cron/scheduler.ex:242` (`start_system_jobs/0`) | **Needs-gating** — the only cron the *always-on tree* replicates on every node (the memory-consolidator tick). Workflow-target ticks are idempotency-keyed (`cron:<job>:<window>`); a non-idempotent target would multi-fire | **LEADER-GATED** — `:system_job` ticks fire on the leader only; off-leader they re-arm. The consolidator's `pg_try_advisory_lock` stays the correctness backstop |
| `Embeddings.BackfillWorker` (periodic `:scan`) | `application.ex:228`, `backfill_worker.ex` | **Wasteful-but-safe** — N pollers, but `FOR UPDATE SKIP LOCKED` + the `embedding_next_attempt_at` row-lease prevent double-processing | **LEADER-GATED** (scan only) — cuts redundant cross-node polling. The hint-path (`{:hint_pending, _}`) + manual `tick/0` stay ungated |
| `Trace.RetentionSweeper` | `application.ex:203` | **Wasteful-but-safe** — idempotent `DELETE … older than` on every node | **LEADER-GATED** — `:sweep` runs on the leader only |
| `RequestCorrelation.Sweeper` | `application.ex:200` | **Wasteful-but-safe** — idempotent prune | **LEADER-GATED** — `:sweep` runs on the leader only |
| `VFS.PrototypeRetentionSweeper` | `application.ex:208` | **Wasteful-but-safe** — fail-safe, idempotent dir GC (opt-in; off by default) | **LEADER-GATED** — `:sweep` runs on the leader only |
| `Embeddings.RatePacer` | `application.ex:227` | **Safe** — per-node token bucket + a *shared* Postgres counter (`rate_pacer.ex`); per-node is correct by design | Per-node by design |
| `AgentTracker`, `Stats`, `Display`, `Network.Supervisor` | `application.ex:306,234,315,303` | **Safe** — node-local presence/UI state, per-node correct | Per-node by design |
| `Memory.Consolidator.MCPServer`, web `Endpoint` | `application.ex:258`, gateway | **Safe** — per-node servers behind a load balancer | Per-node by design |
| Trace `Collector`/`Recorder`/`Persistence` | `application.ex:196-199` | **Safe** — per-node telemetry capture; writes are tenant/run-scoped | Per-node by design |

**Two audit corrections vs. the original sketch:**

1. **The only cron replicated by the always-on tree is the memory-consolidator
   tick** — seeded on *every* node by `SystemJobsInitializer` →
   `start_system_jobs/0` (`cron/scheduler.ex:242`) as a `mode: :system_job` cron.
   The "consolidator scheduler tick" the sketch listed *separately* **is** that
   same `:system_job`, so **one gate covers both**. User cron jobs are node-local
   and only loaded by each **CLI REPL** (`repl.ex:315`) — under clustering they
   neither multi-fire via the always-on tree nor run exactly-once cluster-wide.
   That pre-existing gap is **WS4a**, deliberately untouched here (gating it
   blanket would silence single-CLI and follower-scheduled user jobs).
2. **Every "needs-gating"/"optional" singleton is already idempotent or
   DB-coordinated** (`SKIP LOCKED` row-leases, advisory locks, idempotency keys),
   so leader-gating is **waste-reduction + first-line gating**, not the
   load-bearing correctness fix — the lease (WS1) was, and already shipped.

**Headline:** the lease (WS1) was the only *correctness*-critical gap. Most
singletons are already safe because the codebase consistently uses
`SKIP LOCKED` + row-leases (embeddings), advisory locks (consolidator), and
idempotency keys (cron→workflow). The prior cross-node hygiene
(`[[project_clustering_state]]`) paid off — verified, not assumed.

## Component 3 — Gate the needs-gating set (shipped)

- **Cron** — the fire-gate is **scoped to `:system_job` ticks**
  (`Cron.Worker.leader_gated?/1`), the always-on-tree case: it stops the
  consolidator's per-node multi-fire without regressing single-CLI or
  follower-scheduled user jobs (which a blanket gate would silence). Off-leader,
  the tick re-arms via `schedule_next/1`, so failover is automatic — the new
  leader fires on the next boundary, no leadership listener needed. Manual
  `trigger/2` is never gated (operator override).
- **Waste reduction** — the three sweepers + the backfill scan are leader-gated
  too; their `SKIP LOCKED`/idempotent design already made them safe, so the gate
  only cuts redundant cross-node work.

### Standing invariant (defense-in-depth)

`:pg` leadership is **eventually-consistent**, so a brief **two-leaders window**
is possible while membership converges (a healing netsplit). The leader gate is
therefore **first-line, not a guarantee**: **every system cron job must stay
idempotent / row-claimed / DB-leased**, and every gated sweep must stay
idempotent — the gate only reduces how often the safe-by-construction work runs.
This invariant is recorded at the registration site
(`Cron.Scheduler.start_system_jobs/0`). A future **one-shot** (`{:at, _}`) system
job would also need the off-leader swallow to re-arm a bounded re-check instead
of `schedule_next/1`'s elapsed-`:at` disable path (today every `:system_job` is
recurring; recorded in `Cron.Worker`).

## Out of scope (recorded, per gust's noted gaps)

- **Work-stealing / graceful-drain between live nodes** — gust only does dead-node
  recovery and flags this gap (`gust/…:145`). A draining node's in-flight runs are
  recovered by WS3's lease-expiry path (after the lease lapses), not handed off
  live. A drain-on-shutdown protocol (release claims so peers pick them up
  immediately) is a future enhancement, not this plan.

## Test plan (shipped, single-BEAM)

Real cross-BEAM `:peer` election is **WS6**'s deliverable; WS-4 tests its own
logic single-BEAM (matching how WS1/WS3 shipped). All gate tests are
`async: false`; `[[project_suite_flaky_tests]]` — verify in isolation.

- **Leader election** (`test/jido_claw/core/cluster/leader_test.exs`) — pure
  `elect/1`/`recompute/2` over synthetic node-name lists; `leader?/0` single-node
  (`true`) + clustered-process-absent (fail-closed `false`); real `:pg` join/leave
  via the `:members_fun` DI seam asserting `leader_changed` fires once on a flip
  and not otherwise; `:rest_for_one` restart coupling of `:pg` + Leader.
- **Cron `:system_job` gate** (`test/jido_claw/cron/worker_leader_gate_test.exs`,
  the audit's *machine-checked* assertion) — off-leader swallow + re-arm,
  on-leader fire, manual `trigger/2` never gated, user `:workflow` job not gated.
- **Sweeper/backfill gates** — co-located in each unit's existing test
  (`retention_sweeper_test.exs`, `prototype_retention_sweeper_test.exs`,
  `backfill_worker_test.exs`) + a new `request_correlation/sweeper_test.exs`:
  stub `leader? → false` ⇒ the sweep/scan does no work; `→ true` ⇒ it runs. All
  stub leadership via `JidoClaw.ClusterLeaderStub` (the `:cluster_leader_module`
  seam).

## Cross-references

- Leader-election approach — `REACTOR-ADOPTION.md:681-684` (`:pg` preferred);
  gust's partition failure to avoid — `gust/FEATURES-WORTH-BORROWING.md:144`.
- Reuse patterns: `core/cluster.ex` (`:pg` wrapper), `lock_owner.ex` (advisory
  lock), `rate_pacer.ex` (shared counter), `backfill_worker.ex` (claim + row-lease).
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — the run lease (a *separate*
  concern: run claiming needs no leader; only singletons do).
- WS4a ([WS4a-clustered-cron-ownership.md](WS4a-clustered-cron-ownership.md)) —
  the pre-existing clustered **user**-cron ownership gap WS-4 does not touch.
- WS6 — owns the multi-node `:peer` harness; its plan lists cross-BEAM leader
  election as a deliverable.
