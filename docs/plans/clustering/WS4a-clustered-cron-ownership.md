# WS4a — Clustered user-cron ownership

*Builds: exactly-once cluster-wide ownership of **persisted user cron jobs**.
Depends on: WS4 (the leader + `leader?/0` + `leader_changed` telemetry).
Spun out of WS4 per "no deferrals → its own doc."*

> **Status: design (not yet built).** WS4 closed the *always-on-tree* cron case
> (the `:system_job` consolidator tick — leader-gated). WS4a closes the
> **orthogonal** case WS4 deliberately did not touch: user cron jobs, which are
> node-local and CLI-loaded, so under clustering they neither multi-fire via the
> always-on tree (WS4's concern) nor run exactly-once cluster-wide.

## Why this is *not* WS4

WS4's cron gate is scoped to `mode: :system_job` ticks (`Cron.Worker.leader_gated?/1`)
precisely because a **blanket** cron gate would silence two legitimate
single-node behaviors: a lone CLI node's user jobs, and follower-scheduled
ad-hoc jobs. User-cron correctness under clustering is a *scheduling-ownership*
problem (who loads/owns the worker), not a *fire-gating* problem (the WS4 shape).
Different mechanism, different workstream.

## Problem — two faces

1. **Multi-fire across CLI nodes.** Persisted `cron_jobs` rows are loaded and
   scheduled by **each CLI REPL** at startup
   (`CronScheduler.load_persistent_jobs("default", project_dir)`, `repl.ex:315`).
   Two clustered CLI nodes therefore each boot a `Cron.Worker` for the *same*
   job and both fire it. This is safe **today only** for `target: :workflow`
   rows, where the `cron:<job>:<window>` idempotency key dedupes the launch to a
   single `WorkflowRun`. A `target: :agent` or `target: :mfa` user job would
   multi-fire — run the chat turn / MFA once per CLI node.
2. **No-fire on gateway-only nodes.** A `mode: :gateway` clustered node runs **no**
   CLI REPL, so it loads **no** user cron at all. Ad-hoc jobs created at runtime
   via `Cron.Scheduler.schedule/2` live only in the node-local
   `TenantRegistry`/`InstanceSupervisor` that created them. So whether a given
   user job fires at all depends on which node happens to hold its worker — there
   is no cluster-wide guarantee of exactly-once, or even at-least-once, execution.

Net: user cron has **no single owner** under clustering. The DB has the rows
(`cron_jobs`), but the *scheduling* of those rows is scattered across whichever
CLI nodes happen to be up, and ad-hoc jobs are stranded on their creating node.

## Target

- The **leader owns all persisted cron jobs cluster-wide**: it loads and schedules
  every non-disabled `cron_jobs` row; **followers schedule none**.
- The `cron_jobs` row is the **source of truth** (it already is for persistence;
  this makes it authoritative for *scheduling* too).
- **Failover reloads on the new leader**: when leadership moves, the new leader
  loads the persisted jobs and the old leader stops its workers — driven off the
  WS4 `leader_changed` signal, so there is no second election mechanism.
- **Single-node is byte-identical**: with one node, `leader?/0` is trivially
  `true`, so that node loads + owns all jobs exactly as the CLI REPL does today.

## Phases

- **P1 — Leader owns persisted jobs + a leadership-change listener.**
  Move persisted-job loading off the per-REPL path and behind the leader: a
  supervised owner that, on **leadership gain**, calls
  `load_persistent_jobs/2` (reusing `Cron.Job.for_tenant` + `Scheduler.schedule/2`)
  for every tenant; on **leadership loss**, unschedules those workers. Subscribe
  to the WS4 `[:jido_claw, :cluster, :leader_changed]` telemetry (or a thin
  PubSub re-broadcast of it) as the failover trigger. The REPL's eager
  `load_persistent_jobs` call (`repl.ex:315`) is removed or made leader-conditional
  so two CLI nodes no longer double-load. Single-node: the owner is always leader,
  so it loads everything at boot — unchanged behavior.

- **P2 — Ad-hoc scheduling on a follower persists + hands off.**
  `Cron.Scheduler.schedule/2` on a follower must **persist** the job to `cron_jobs`
  (if not already persisted) and route ownership to the leader rather than booting
  a node-local worker that only the follower can see. Options to weigh in the
  P2 design: persist-then-signal-leader-to-reload, or a leader-side `schedule`
  RPC. The invariant: after `schedule/2` returns, the job is durable and the
  leader (not the follower) runs it.

- **P3 — Tests, including WS6 `:peer` failover.**
  Single-BEAM: leadership-change listener loads on gain / unschedules on loss
  (stub leadership via the WS4 `:cluster_leader_module` seam). Cross-BEAM under
  WS6's `:peer` harness: two nodes, exactly one runs a given user job; kill the
  leader and assert the survivor reloads and continues firing (no gap beyond the
  election window, no double-fire).

## Reuse

- `Cron.Scheduler.load_persistent_jobs/2`, `Cron.Job.for_tenant`,
  `Cron.Scheduler.schedule/2` / `unschedule/2` — the existing load/schedule
  surface; P1 changes *who/when* calls them, not the primitives.
- The WS4 leader: `JidoClaw.Cluster.leader?/0` for the gate, and
  `[:jido_claw, :cluster, :leader_changed]` telemetry as the failover trigger
  (start-on-gain / stop-on-loss). No new election.
- The `cron:<job>:<window>` idempotency key remains a belt-and-suspenders
  backstop for `:workflow` targets during the brief two-leaders convergence
  window (the same standing invariant WS4 records for `:system_job`s).

## Cross-references

- WS4 ([WS4-leader-election-and-singletons.md](WS4-leader-election-and-singletons.md))
  — the leader + `:system_job` gate this builds on; the audit's correction #1
  names this gap.
- WS6 — the multi-node `:peer` harness P3's failover test needs.
- Out of scope (WS4 non-goal): work-stealing / graceful-drain between live nodes;
  a draining node's runs are recovered by WS3's lease-expiry path.
