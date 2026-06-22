# WS4 — Leader election + singleton audit

*Builds: a `:pg`-based leader election, and a multi-node-safety pass over every
always-on process. Depends on: WS1 (loosely — sequence after). This is the
iceberg the docs under-scope.*

> **What this owns.** The lease (WS1) makes *run execution* cluster-safe. But many
> always-on singletons start on **every node** and would multi-fire under
> clustering. The exploration docs only call out the cron scheduler
> (`REACTOR-ADOPTION.md:681-684`). WS4 builds the leader-election they reference
> **and** audits the full singleton surface — the part no prior doc enumerated.

## Component 1 — Leader election (`:pg`, not advisory-lock)

For singleton work that should run on exactly one node, build a leader-election
module. **Use `:pg`, not a held advisory lock** (`REACTOR-ADOPTION.md:681-684`):
gust's leader is a session-bound `pg_try_advisory_lock` held open by
`Process.sleep(:infinity)`, which **stalls all leader-only work globally** if the
leader's TCP survives but the node is unreachable (`gust/…:144`). We deliberately
do not inherit that failure mode (README §non-goals).

Reuse what's in-tree: `JidoClaw.Cluster` already wraps the `:pg` scope `:jido_claw`
(`core/cluster.ex:53-83`, started at `application.ex:425`). A leader module
elects via `:pg` membership of a well-known group (lowest node, or first-joiner),
re-elects on membership change, and exposes `leader?/0` for singletons to gate on.

## Component 2 — The singleton audit

Every child in `core_children` (`application.ex:136-294`) starts on **every
node**. Classify each: **safe** (idempotent or already cross-node-coordinated),
**wasteful-but-safe** (correct, but does redundant work N times), or
**needs-gating** (incorrect under N nodes). Findings from the current tree:

| Singleton | Where | Under N nodes | Action |
|---|---|---|---|
| `Embeddings.BackfillWorker` | `application.ex:207` | **Wasteful-but-safe** — N pollers, but `FOR UPDATE SKIP LOCKED` + the `embedding_next_attempt_at` row-lease (`backfill_worker.ex:178-190`) prevent double-processing | Optional: leader-gate to cut redundant polling. Not required for correctness. |
| `Embeddings.RatePacer` | `application.ex:206` | **Safe** — per-node token bucket + a *shared* Postgres counter (`rate_pacer.ex`); per-node is correct by design | None |
| Memory consolidator (cron + `SystemJobsInitializer`) | `application.ex:243-248`, `cron/scheduler.ex:248` | **Safe** — N-scheduled, but the session `pg_try_advisory_lock` (`lock_owner.ex`) means only one node wins per scope | Optional: leader-gate the *scheduler* to cut redundant ticks. Lock already makes it correct. |
| `Cron.Worker` (per tenant) | `cron/scheduler.ex:165-181`, `cron/worker.ex` | **Mixed** — fires on every node. Workflow-target ticks are idempotency-keyed (`cron:<job>:<window>`, safe); a non-idempotent tick target would multi-fire | **Needs-gating**: leader-gate cron firing (or assert every `Cron.Dispatcher` target is idempotent — `cron/dispatcher.ex:29-64`) |
| `Trace.RetentionSweeper` | `application.ex:187` | **Wasteful-but-safe** — idempotent `DELETE … older than` on every node | Optional: leader-gate |
| `RequestCorrelation.Sweeper` | `application.ex:184` | **Wasteful-but-safe** — idempotent prune | Optional: leader-gate |
| `AgentTracker`, `Stats`, `Display`, `Network.Supervisor` | `application.ex:282-285` | **Safe** — node-local presence/UI state, per-node correct | None |
| `Memory.Consolidator.MCPServer`, web `Endpoint` | `application.ex:237`, gateway | **Safe** — per-node servers behind a load balancer | None |
| Trace `Collector`/`Recorder`/`Persistence` | `application.ex:180-183` | **Safe** — per-node telemetry capture; writes are tenant/run-scoped | None |

**Headline:** the lease (WS1) is the only *correctness*-critical gap. Most
singletons are already safe because the codebase consistently uses
`SKIP LOCKED` + row-leases (embeddings), advisory locks (consolidator), and
idempotency keys (cron→workflow). The genuine **needs-gating** item is
**non-idempotent cron targets**; the rest is **optional waste reduction** via the
leader. This is good news — the prior cross-node hygiene (`[[project_clustering_state]]`)
paid off — but it must be *verified*, not assumed, which is the bulk of WS4's
effort.

## Component 3 — Gate the needs-gating set

- **Cron**: either run the per-tenant `Cron.Worker` schedulers only on the leader,
  or audit every `Cron.Dispatcher` target (`cron/dispatcher.ex`) for idempotency
  and leave firing distributed. Recommendation: leader-gate the scheduler — it's
  simpler than proving every current and future cron target idempotent, and the
  workflow path's idempotency key is then a belt-and-suspenders backstop against
  leader flapping (`gust/…:147-149`).
- **Optional waste reduction**: leader-gate the sweepers and the consolidator
  scheduler tick. Low priority — they're already safe.

## Out of scope (recorded, per gust's noted gaps)

- **Work-stealing / graceful-drain between live nodes** — gust only does dead-node
  recovery and flags this gap (`gust/…:145`). A draining node's in-flight runs are
  recovered by WS3's lease-expiry path (after the lease lapses), not handed off
  live. A drain-on-shutdown protocol (release claims so peers pick them up
  immediately) is a future enhancement, not this plan.

## Test plan

- **Leader election** — in a simulated multi-member `:pg` group, exactly one node
  reports `leader?/0`; killing the leader re-elects another.
- **Singleton classification regression** — a test that asserts the audit's
  needs-gating items are leader-gated (e.g. cron scheduler does not start its
  workers off-leader when clustered).
- **Idempotency backstop** — a cron→workflow tick fired on two nodes produces one
  run (the `cron:<job>:<window>` key dedupes) — guards the leave-distributed
  alternative.

## Cross-references

- Leader-election approach — `REACTOR-ADOPTION.md:681-684` (`:pg` preferred);
  gust's partition failure to avoid — `gust/FEATURES-WORTH-BORROWING.md:144`.
- Reuse patterns: `core/cluster.ex` (`:pg` wrapper), `lock_owner.ex` (advisory
  lock), `rate_pacer.ex` (shared counter), `backfill_worker.ex` (claim + row-lease).
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — the run lease (a *separate*
  concern: run claiming needs no leader; only singletons do).
