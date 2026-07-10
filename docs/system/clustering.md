---
type: subsystem
description: Multi-node topologies, the DB-lease run-ownership model, lease telemetry, and the cluster_enabled flip checklist.
sources:
  - lib/jido_claw/core/cluster.ex
  - lib/jido_claw/application.ex
  - lib/jido_claw/orchestration/workflow_lease.ex
  - lib/jido_claw/orchestration/workflow_run.ex
  - lib/jido_claw/orchestration/workflow_event/projection.ex
  - lib/jido_claw/orchestration/workflow_log.ex
  - lib/jido_claw/orchestration/gate_resume.ex
  - lib/jido_claw/orchestration/gate_disposition.ex
  - lib/jido_claw/orchestration/reactor_runner.ex
  - lib/jido_claw/orchestration/reactor_middleware.ex
  - lib/jido_claw/orchestration/cancellation.ex
  - lib/jido_claw/orchestration/reclaim_pooler.ex
  - lib/jido_claw/orchestration/workflow_recovery.ex
  - lib/jido_claw/orchestration/workflow_lease/middleware.ex
  - lib/jido_claw/orchestration/workflow_lease/sidecar.ex
  - lib/jido_claw/cron/resources/job.ex
  - lib/jido_claw/platform/cron/owner.ex
  - lib/jido_claw/platform/cron/scheduler.ex
  - lib/jido_claw/platform/cron/worker.ex
  - lib/jido_claw/network/protocol.ex
  - lib/jido_claw/network/node.ex
  - lib/jido_claw/agent/identity.ex
  - config/config.exs
verified: 2026-07-10
verified_sha: "b2cae5cd"
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
  cluster membership**; per-peer Ed25519 signatures authenticate the complete
  canonical network envelope (version, id, type, sender, timestamp, payload).
  Receivers enforce a five-minute freshness window and retain a bounded replay
  cache keyed by authenticated sender plus message id, so one peer cannot suppress
  another peer's same-id message and exact relabelling/replay is rejected.
  Identity files distinguish absence from corruption, validate the Ed25519 keypair
  and derived id, reject symlinks, and are written mode-0600 via atomic rename;
  loads also tighten legacy file/directory modes to 0600/0700 and fail if chmod
  cannot be enforced. Corrupt storage can no longer silently rotate the node principal. Secret and
  cookie must both be set and non-default before a node
  touches a shared segment.
- **The lease discipline**: a run's owner is durable and fenced — the execution
  winner CAS-**stamps** `claimed_by`/`claim_token`/`claim_expires_at`
  (status-guarded to pending/running), a token/nonterminal-status/established-
  park-fenced **renew** heartbeats it,
  reclaim **rotates** the token (rotation fences the zombie: its next renew
  matches 0 rows and the sidecar kills the executor before it can write a
  terminal), and the always-on claim-gated `ReclaimPooler` re-claims expired
  leases in every serve mode. Lease expiry is stamped and compared on the DB
  clock, never app time.
- **A terminal revokes the credential in-transaction**: every terminal
  projection clears `claim_token` + `claim_expires_at` while preserving
  `claimed_by` for cancellation routing and audit. A disconnected owner may
  miss the kill cast, but its next heartbeat matches zero rows and its sidecar
  kills the executor; terminal rows can never renew forever.
- **Self-authored terminals stop their heartbeat first**: reactor workers and
  composer parents perform a token-checked graceful sidecar handshake
  immediately before their own terminal append. This prevents their terminal
  token revocation from being misread as an external fence in the
  commit-to-process-return window. Sidecar cleanup is diagnostic rather than
  terminal authority: either strict stop error means the sidecar is already
  dead/dying, so the token-fenced terminal append still runs and the cleanup
  failure emits `:sidecar_stop_failed`. Operator cancellation and live recovery
  do not use the handshake, so a partitioned executor is still killed on its
  next refused renewal.
- **Gate resume is owned before preflight**: checkpoint persistence holds the
  run row lock, re-checks `:awaiting_approval` + the held token, writes the
  encrypted checkpoint, and releases the expiry to NULL in one transaction.
  Renewal refuses an awaiting row once that checkpoint exists, so a sidecar
  tick queued behind the row lock cannot restore a future expiry after the park.
  An ordinary approval transaction records the decision/event and rotates a
  live resume lease atomically; immediate resume reuses that exact token rather
  than opening a decision-to-claim gap. Expired checkpoint-less
  `:awaiting_approval` rows are also claimable, so a crash after the status flip
  cannot strand a run. Live reclaim reuses the already-rotated `claim_next/1`
  token; boot recovery may CAS-force a fresh token despite a future expiry
  because its startup barrier proves the prior BEAM dead. A losing resume never
  decrypts and can never terminalize the winner on a preflight error.
- **Boot recovery is a barrier**: `WorkflowRecovery.start_link/1` completes its
  single-node scan before returning; `ReclaimPooler` starts after it. The scan
  retries recognized database-connection failures with capped exponential
  backoff and no exhaustion while application startup remains closed.
  Recognized failures include Ash-wrapped connection errors whose splode leaf
  carries the rescued exception as a formatted string — matched on the exact
  `"** (DBConnection.ConnectionError)"` banner prefix
  (`Core.AshErrors.connection_error?/1`), never a loose substring, so a
  stringified Postgrex schema error stays loud. It cannot
  degrade open: a prior-runtime `:running` row with a nil expiry is outside the
  live reclaimer's selector. Non-infrastructure exceptions remain loud and abort
  boot rather than entering the retry lane. The scan
  re-reads each candidate before classification, and caseless-park cleanup uses
  `GateDisposition`'s under-lock status fence, so a stale parked snapshot cannot
  cancel a concurrently approved run. Live reclaim also threads its rotated
  token into recovery terminals: if that reclaimer stalls past its lease and a
  successor rotates again, the stale `run_recovered`/`run_failed` batch rolls
  back instead of terminalizing the new owner's run. Boot's recovery terminals
  remain unfenced under the barrier's sole-owner premise.
- **The load-bearing gotcha**: boot recovery **turns itself off under
  clustering** (`owns_recovery?`, `workflow_recovery.ex:858-862`) — lease-expiry
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
2. **WS4 leader election + durable cron fire claims present** — shipped.
   Every scheduled tick is leader-gated; persisted user agent/workflow/MFA jobs
   atomically advance `cron_jobs.last_fire_at` only while the row is enabled and
   its definition-generation token matches the worker, so the brief two-leaders
   window and stale-worker/config-update window both have a DB fence rather than
   relying on eventual `:pg` convergence. Re-enable is itself a definition
   write: `:enable` rotates the token, so the next reconcile REPLACES a
   still-alive auto-disabled worker with a fresh armed generation — never
   resumed in-place (a future enable surface should call
   `Owner.notify_changed/1` after the write, like `/cron disable` does, rather
   than wait on the periodic tick). Accepted operator-initiated residual: a
   manual trigger already queued or racing the enable may execute its side
   effect once — the rotated token fences its persisted outcome write
   (`stale_cron_definition` → retire the stale copy), not the execution
   itself. In-memory system jobs retain their
   target-specific lock/idempotency requirement and consume follower-side missed
   boundaries instead of replaying them after a leadership handoff.
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
- **Completion authority runs last**: middleware normalization is
  `[Lease | custom] ++ [ReactorMiddleware]`. Lease claim still precedes all
  work, but custom completion hooks finish before `run_completed` is appended;
  a later hook cannot return an error after the run was already durably green.
- **Cron fire ownership**: every scheduled worker tick first checks leadership.
  Only a persisted worker retains the same due window on a follower; its later
  dispatch is still protected by a durable claim. Non-persisted recurring jobs
  advance to their next boundary and non-persisted one-shots are discarded, so
  a follower cannot sequentially replay an old due window after becoming leader.
  A persisted cron/`:at` job executes `Job.claim_scheduled_fire`, whose single
  filtered SQL update makes the exact UTC window single-winner. Persisted
  `:every` jobs instead execute `Job.claim_interval_fire`: PostgreSQL's one
  statement clock supplies both `last_fire_at` and the `now - interval` cutoff,
  so a fast caller clock cannot stamp future state and skewed nodes cannot both
  win. Both actions require an enabled row and the worker's exact definition
  token. Duplicate claims advance the local schedule without dispatch;
  disabled/definition-mismatched workers retire. Claim/storage errors fail
  closed and retry the same window with capped exponential backoff (1s
  doubling to a 30s cap; any non-error tick outcome resets the streak) —
  follower leadership polling keeps its flat 1s cadence so a handoff is
  noticed promptly. A non-persisted user job under clustering can never claim
  (`:durable_fire_claim_required`): refused at worker init, with a defensive
  in-memory disable if the flag flips after hydration. `record_success` /
  `record_failure` and worker-originated disable writes carry the same definition
  token, so an old in-flight result cannot reset, increment, or disable a newly
  upserted definition. Only a successfully persisted third failure disables the
  matching worker/row.
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
  `enabled?` (default true; false in test). Initial delay is restart/warm-up
  pacing; synchronous application child ordering, not this timer, separates
  boot recovery from live reclaim.
- `workflow_recovery`: `enabled?` (default true), `retry_initial_ms` (250), and
  `retry_max_ms` (5,000). Retry count is deliberately unbounded in the
  single-node owner mode; only the sleep interval is capped.

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

Sidecar cleanup failures additionally emit
`[:jido_claw, :orchestration, :sidecar_stop_failed]` with run id and a bounded
failure class; the terminal append remains authoritative.

**`:claim_lost` means "claim refused", not "another node fenced us"**:
`stamp/4` returns `{:ok, :lost}` both for a lost cross-node CAS *and* for a
terminal/parked row's status-guard miss — never read the tagged metric as a
pure cross-node fence count.

**Ownership columns (WS6, surface v1.2)**: the `/workflows` dashboard gains
Owner + Lease expires columns (the expiry is NULL on terminal rows because the
terminal projection revokes the lease), and `Visibility.run_view/3`'s base map gains
`claimed_by` / `claim_expires_at`, inherited by `workflow_status`, `jido.runs`,
`jido://bootstrap`, and the headless CLI run views, and declared on
`inspect_workflow`'s output schema. The observe surfaces expose the
raw ownership columns: `claimed_by` remains as historical owner provenance;
`claim_token` is never exposed and `claim_expires_at` is cleared at terminal.

## Residuals & accepted risks

- **Network signature v2 is a coordinated-upgrade boundary**: the old
  payload-only signature is rejected fail-closed. Mixed-version nodes therefore
  cannot exchange solution-network messages during a rolling upgrade; drain and
  upgrade that cluster together. Workflow distribution/lease traffic is separate.
- **The network replay cache is process-local**: a `Network.Node` restart accepts
  a still-fresh, correctly signed message again. Durable replay suppression would
  require a shared persistence/expiry policy and is deferred under the opt-in,
  trusted-peer network model.
- **Composer hung-wave watchdog (C-M3) — consciously deferred**: a wave with
  `execution_timeout: :infinity` that never returns blocks the composer
  GenServer while its sidecar keeps renewing the lease (no stuck-wave
  detection). Revisit if a stuck wave actually bites.
- **Cron-worker stuck-detection — consciously deferred**: cron dispatch is
  synchronous, so a hung target blocks the worker; a watchdog needs async
  dispatch first.
- **Sidecar untrappable kill** (`workflow_lease/sidecar.ex:29-35`): an
  untrappable `Process.exit(sidecar, :kill)` skips the fail-closed guard and
  would normally leave the executor running unleased. The one deliberate use is
  `stop_sidecar/2`'s token-matched terminal-phase fallback: no further steps can
  launch, it waits for the matching `:DOWN`, and the immediately-following DB
  terminal append still enforces the claim-token fence. Outside that narrow
  path, only `LeaseTaskSupervisor` shutdown issues such a kill (while the
  executor is terminating too).

## Source map

- `lib/jido_claw/core/cluster.ex:141` — `topology/0` strategy dispatch
- `lib/jido_claw/core/cluster.ex:210` — `gossip_secret!/0` (raise-without-secret)
- `lib/jido_claw/application.ex:483` — `cluster_children/0` wiring
- `lib/jido_claw/orchestration/workflow_lease.ex` — stamp/renew/claim primitives, `fenced_reason/1`
- `lib/jido_claw/orchestration/workflow_event/projection.ex` + `workflow_run.ex` — terminal token revocation
- `lib/jido_claw/orchestration/workflow_log.ex` + `gate_resume.ex` + `gate_disposition.ex` — locked checkpoint persistence and one-winner resume/disposition fences
- `lib/jido_claw/orchestration/reactor_runner.ex` + `reactor_middleware.ex` — lease-first / durable-completion-last middleware order
- `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — the claim at execution start (+ `claimed`/`fenced_out` emits)
- `lib/jido_claw/orchestration/workflow_lease/sidecar.ex` — the heartbeat loop (+ `renewed`/`fenced_out` emits)
- `lib/jido_claw/orchestration/reclaim_pooler.ex` — the always-on claim→dispatch loop (+ `reclaimed` emit)
- `lib/jido_claw/orchestration/workflow_recovery.ex:858` — `owns_recovery?/0` (the gotcha)
- `lib/jido_claw/cron/resources/job.ex` + `platform/cron/{owner,scheduler,worker}.ex` — leader gate, durable fire claim, persistent failure streak
- `config/config.exs:186` — `cluster_enabled`/`cluster_strategy` defaults
- `test/jido_claw/cluster/` — the `:peer` multi-node proofs (`scripts/test-cluster.sh`)
