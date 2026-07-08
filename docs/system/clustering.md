---
type: subsystem
description: Multi-node topologies, the DB-lease run-ownership model, lease telemetry, and the cluster_enabled flip checklist.
sources:
  - lib/jido_claw/core/cluster.ex
  - lib/jido_claw/application.ex
  - lib/jido_claw/orchestration/workflow_lease.ex
  - lib/jido_claw/orchestration/reclaim_pooler.ex
  - lib/jido_claw/orchestration/workflow_recovery.ex
  - lib/jido_claw/orchestration/workflow_lease/middleware.ex
  - lib/jido_claw/orchestration/workflow_lease/sidecar.ex
  - config/config.exs
verified: 2026-07-07
---

# Clustering

## What & why

Multi-node execution is **off by default** (`cluster_enabled: false`); the
libcluster + `:pg` baseline ships and works when enabled. This page is how to
run clustered safely: the topologies, the durable run-ownership (lease) model
that makes multi-node *workflow execution* correct, the `cluster_enabled` flip
checklist, and the lease observability (telemetry + ownership columns) that
closed WS6. Design history, the workstream ledger, and the deferral matrix stay
in [docs/plans/clustering/README.md](../plans/clustering/README.md).

## Invariants & contracts

- **Off by default, gated twice**: `cluster_enabled: false`
  (`config/config.exs:186`), and the libcluster children start only when
  enabled AND Erlang distribution is up — `application.ex:483-491` warns on
  `:nonode@nohost` (no nodes can connect without `--name`/`--sname` and a
  non-default distribution cookie).
- **`:gossip` raises without a shared secret** (`gossip_secret!/0`,
  `core/cluster.ex:210-237`): without one, discovery heartbeats are plaintext
  and any host on the multicast segment gets discovered and connect-attempted.
- **The trust model is layered** (aligned with README "Clustering"): the gossip
  secret *encrypts* discovery heartbeats (libcluster uses AES-CBC with no MAC —
  encryption, NOT authentication); the Erlang **distribution cookie gates
  cluster membership**; per-peer Ed25519 signatures authenticate network
  *messages*. Secret and cookie must both be set and non-default before a node
  touches a shared segment.
- **The lease discipline**: a run's owner is durable and fenced — the execution
  winner CAS-**stamps** `claimed_by`/`claim_token`/`claim_expires_at`
  (status-guarded to pending/running), a token-fenced **renew** heartbeats it,
  reclaim **rotates** the token (rotation fences the zombie: its next renew
  matches 0 rows and the sidecar kills the executor before it can write a
  terminal), and the always-on claim-gated `ReclaimPooler` re-claims expired
  leases in every serve mode. Lease expiry is stamped and compared on the DB
  clock, never app time.
- **The load-bearing gotcha**: boot recovery **turns itself off under
  clustering** (`owns_recovery?`, `workflow_recovery.ex:780-784`) — lease-expiry
  reclaim replaces the boot reconciler. This is why WS1+WS3 are a hard
  precondition of the flip: with the flag on and no lease/reclaim, interrupted
  runs would strand silently.

### The `cluster_enabled` flip checklist

Preconditions for setting `cluster_enabled: true`:

1. **WS1 (lease) and WS3 (reclaim) landed** — hard gate. Both shipped; the row
   survives as the record of *why*: the flip disables boot recovery (see "The
   load-bearing gotcha" here and in
   [docs/plans/clustering/README.md](../plans/clustering/README.md)), so
   without lease-expiry reclaim nothing recovers interrupted runs.
2. **WS4 leader election present** (or every cron audited idempotent) — shipped
   (`JidoClaw.Cluster.Leader`; `:system_job` ticks are leader-gated with an
   idempotency-key backstop).
3. **A shared, reachable Postgres** — one database for all nodes, not per-node:
   the lease columns, the reclaim selector, and the event log are the
   coordination substrate.
4. **Cluster secret + topology on every node**, and a non-default distribution
   cookie (`RELEASE_COOKIE` / `--cookie`).
5. **MCP-mode nodes are execution nodes too**: `serve_mode: :mcp` skips
   Gateway/Discord and *boot recovery* (`owns_recovery?`), NOT run execution —
   `run_skill` launches workflows (`ReactorRunner.run`) and the always-on
   claim-gated `ReclaimPooler` covers every serve mode
   (`reclaim_pooler.ex:23`). A clustered MCP node therefore needs the same
   shared Postgres, secret/topology, and lease/reclaim coverage as any node.
   (This corrects the WS6 sketch's item 5, which claimed MCP mode "skips run
   execution".)

## Mechanics

- **Topology dispatch** (`topology/0`, `core/cluster.ex:141-181`) on
  `:cluster_strategy`: `:gossip` (the default AND the unknown-strategy
  fallback) multicasts on `gossip_port` with the required secret; `:kubernetes`
  uses DNS mode over the `k8s_*` keys; `:epmd` connects the static
  `cluster_nodes` list; `:none` returns no topology.
- **Env var at call time** (`core/cluster.ex:206-209`): the gossip secret reads
  app env first (test seam), then `JIDOCLAW_CLUSTER_SECRET` at call time —
  `.env` loads before `cluster_children/0` builds the topology, so dotenv
  values work where `runtime.exs` would be too early.
- **Supervision wiring** (`application.ex:483-518`): when enabled, the `:pg`
  scope and the `Cluster.Leader` GenServer start together under a
  `:rest_for_one` `LeadershipSupervisor` (a `:pg` crash restarts both in order,
  so the Leader never holds a stale monitor ref against a restarted scope);
  libcluster's `Cluster.Supervisor` is an independent sibling.
- **Run ownership**: `WorkflowLease.stamp/4` is the CAS row-claim (reached only
  by the execution winner via `Lease.Middleware.init/1`); `renew/2` the fenced
  heartbeat the per-run `Sidecar` task loops (`fence_decision/3` is pure and
  fail-closed — a transient DB error retries inside the lease window, then
  kills); `claim_next/1` / `claim_run/1` rotate the token under `FOR UPDATE`
  locks (the oldest-first scan uses SKIP LOCKED; the by-id reclaim re-checks
  the full `:claimable` predicate under the lock). `ReclaimPooler.reclaim_once/0`
  drains `claim_next/1` to `:none` each poll, routing every claim through
  `WorkflowRecovery.reclaim/2` for the per-run disposition (restart, re-park,
  fail with audit).
- **Node identity** is `WorkflowLease.node_identity/0`, which delegates through
  `Cluster.local_node/0` (`workflow_lease.ex:107-109`) — the project seam;
  call sites never stringify `Node.self()` directly.

## Config & telemetry

Config keys (all `config :jido_claw, ...`):

- `cluster_enabled` (default `false`) / `cluster_strategy` (default `:gossip`)
  — `config/config.exs:186-187`.
- `cluster_secret` or the `JIDOCLAW_CLUSTER_SECRET` env var (gossip; required);
  `gossip_port` (default 45_892); `cluster_nodes` (epmd hosts);
  `k8s_node_basename` / `k8s_selector` / `k8s_namespace` (kubernetes).
- `workflow_lease`: `lease_seconds` (60), `renew_seconds` (15),
  `pending_grace_seconds` (default = `lease_seconds` — the no-fresh-pending-
  steal guard for the create→stamp gap).
- `reclaim_pooler`: `poll_interval_ms` (15_000), `initial_delay_ms` (5_000),
  `enabled?` (default true; false in test).

**Lease lifecycle telemetry** — five node-local events, all measurement
`%{count: 1}`, registered in `JidoClaw.Telemetry.metrics/0` with
`measurement: :count` (the name-inferred `:total` would never fire). No lease
token ever rides metadata — fence credentials stay out of telemetry. Telemetry
is per-BEAM (node-local), which is exactly why the WS6 cluster proofs poll the
DB instead of asserting on events.

| Event (`[:jido_claw, :orchestration, _]`) | Fires | Metadata |
| --- | --- | --- |
| `:claimed` | `Lease.Middleware` won the CAS stamp at execution start (before the sidecar arms) | `run_id`, `tenant_id`, `workflow_type`, `node` |
| `:renewed` | each successful sidecar heartbeat (~every `renew_seconds` per live run — accepted volume) | `run_id`, `tenant_id`, `node` |
| `:reclaimed` | `ReclaimPooler` claimed an expired/aged-orphan lease | `run_id`, `tenant_id`, `prior_status`, `workflow_type` |
| `:fenced_out` | an executor was fenced — `reason: :stolen` (renew found the token rotated), `:lapsed` (renew errors past the lease window), `:claim_lost` (the middleware CAS refused) | `run_id`, `tenant_id`, `node`, `reason` |
| `:recovered` | recovery/reclaim decided a run's disposition | `run_id`, `tenant_id`, `prior_status`, `branch` |

**`:claim_lost` means "claim refused", not "another node fenced us"**:
`stamp/4` returns `{:ok, :lost}` both for a lost cross-node CAS *and* for a
terminal/parked row's status-guard miss — never read the tagged metric as a
pure cross-node fence count.

**Ownership columns (WS6, surface v1.2)**: the `/workflows` dashboard gains
Owner + Lease expires columns (the expiry is blanked on terminal rows — a
frozen claim is not a live lease), and `Visibility.run_view/3`'s base map gains
`claimed_by` / `claim_expires_at`, inherited by `workflow_status`, `jido.runs`,
`jido://bootstrap`, and the headless CLI run views, and declared on
`inspect_workflow`'s output schema. The observe surfaces expose the
**raw/frozen** columns: a terminal run's `claim_expires_at` is the frozen
last-claim value, never live lease state — pair it with `status`.

## Residuals & accepted risks

- **Composer hung-wave watchdog (C-M3) — consciously deferred**: a wave with
  `execution_timeout: :infinity` that never returns blocks the composer
  GenServer while its sidecar keeps renewing the lease (no stuck-wave
  detection). Revisit if a stuck wave actually bites.
- **Cron-worker stuck-detection — consciously deferred**: cron dispatch is
  synchronous, so a hung target blocks the worker; a watchdog needs async
  dispatch first.
- **Sidecar untrappable kill** (`workflow_lease/sidecar.ex:29-35`): an
  untrappable `Process.exit(sidecar, :kill)` skips the fail-closed guard and
  would leave the executor running unleased. Nothing issues such a kill except
  `LeaseTaskSupervisor` shutdown (where the executor is terminating too).

## Source map

- `lib/jido_claw/core/cluster.ex:141` — `topology/0` strategy dispatch
- `lib/jido_claw/core/cluster.ex:210` — `gossip_secret!/0` (raise-without-secret)
- `lib/jido_claw/application.ex:483` — `cluster_children/0` wiring
- `lib/jido_claw/orchestration/workflow_lease.ex` — stamp/renew/claim primitives, `fenced_reason/1`
- `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — the claim at execution start (+ `claimed`/`fenced_out` emits)
- `lib/jido_claw/orchestration/workflow_lease/sidecar.ex` — the heartbeat loop (+ `renewed`/`fenced_out` emits)
- `lib/jido_claw/orchestration/reclaim_pooler.ex` — the always-on claim→dispatch loop (+ `reclaimed` emit)
- `lib/jido_claw/orchestration/workflow_recovery.ex:780` — `owns_recovery?/0` (the gotcha)
- `config/config.exs:186` — `cluster_enabled`/`cluster_strategy` defaults
- `test/jido_claw/cluster/` — the `:peer` multi-node proofs (`scripts/test-cluster.sh`)
