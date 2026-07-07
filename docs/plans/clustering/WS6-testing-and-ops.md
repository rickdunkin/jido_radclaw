# WS6 — Testing & ops

*Builds: a real multi-node test harness, the seven cross-BEAM integration
proofs, lease observability, deployment config, and the small gate fixes.
Depends on: all (validates them). The last clustering workstream — WS1–WS5 and
WS4a have shipped; WS6 closes the program. Phased into four sequential,
commit-ready units (see Phasing).*

> **What this owns.** Lease/fence/reclaim correctness is the kind of thing that
> only shows up across real BEAM nodes, and no multi-node test harness exists
> yet. WS6 stands one up, produces the cross-BEAM proofs the shipped
> workstreams left as explicit IOUs (`cancellation_routing_test.exs:9`,
> `run_terminator_test.exs:12`, `cron/owner_test.exs:7`,
> `core/cluster/leader_test.exs:3`), documents the deploy config to actually
> run clustered, and sweeps the small doc-vs-code gaps.

## Phasing

Four phases, worked in succession, each a commit-ready unit. The split is
risk-shaped: the harness carries all the unknown-unknowns (distribution
bootstrap, the sandbox/shared-DB problem, peer app boot, CI wiring), so
Phase 1 lands it with exactly one proof — the cheapest one that forces every
infrastructure decision but has no timing window. The timing-sensitive
machinery (node kills, lease expiry) arrives in Phase 2 once the harness is
proven; the four remaining subsystem proofs ride it in Phase 3; observability
and ops docs close in Phase 4. Because the phases run back-to-back, it's fine
for scaffolding to land in an earlier phase that only pays off later — don't
contort a phase boundary to avoid that.

| Phase | Delivers                                                                                   | Proofs produced                                                                                              |
| ----- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| 1     | `:peer` harness: distribution bootstrap, peer app boot + config push, shared cluster DB, tag/CI wiring | fence race (WS1)                                                                                              |
| 2     | kill + lease-expiry machinery, DB-polling helpers                                          | reclaim across nodes (WS1+WS3); stale-fence halt (WS1)                                                        |
| 3     | per-subsystem scenario choreography                                                        | cross-node cancel (WS5); leader election (WS4); user-cron failover (WS4a); composer reclaim (WS2+WS3)         |
| 4     | lease telemetry, dashboard ownership columns, deploy docs + flip checklist, embedding-counter gate fix | —                                                                                                             |

Phase 4 has no dependency on Phases 1–3 (the proofs poll the DB, never
telemetry — events are node-local, so a peer's events never reach the test
node's handlers). It can be pulled forward if a dashboard view of `claimed_by`
would help debug the peer tests; it sits last because the flip checklist is
most honestly written after the proofs pass.

## Phase 1 — the `:peer` harness, proven by the fence race

Today there is **no real multi-node testing**. The one clustering test
simulates the cross-node path single-node via a `MockHarness` GenServer that
isn't in the local registry, forcing the `:pg` fallback
(`test/jido_claw/forge/clustering_test.exs`). That's fine for exercising
fallback *logic*, but it cannot test lease reclaim, fence races, or "kill a
node, watch a peer take over" — the WS1/WS3 correctness claims.

**Harness choice: `:peer`** (decided). OTP-native multi-node test nodes
(`:peer.start_link/1`), no new dependency; the toolchain is OTP 29
(`[[project_toolchain_mise_latest]]`), so `:peer` is available and is the
modern replacement for `:slave`. `LocalCluster` would add a test dep for what
`:peer` does natively. The existing mock stays for fast unit coverage of the
fallback logic — it is not the integration proof.

### Design points

- **Distribution bootstrap.** `mix test` runs a non-distributed node. Harness
  setup must ensure epmd is running (`epmd -daemon`) and start distribution on
  demand (`Node.start/2` with a per-run unique sname, so parallel CI jobs and
  stray dev runs never collide).
- **Cluster formation.** Don't use the `:gossip` default in tests — it raises
  without a shared secret (`core/cluster.ex:166-193`) and multicast is
  unreliable in CI. Boot peers with `cluster_enabled: true` plus either the
  `:epmd` strategy with the peer names as static hosts, or no libcluster at
  all and explicit `Node.connect/1` — `:pg` propagates over whatever
  distribution exists.
- **Peer app boot + config push.** Peers do not inherit the origin's
  application env. Push config via `:peer.call`/`:rpc`
  (`Application.put_env/3`) *before*
  `Application.ensure_all_started(:jido_claw)`: the shared DB connection
  (below), `cluster_enabled: true`, `serve_mode` not `:mcp` (MCP mode skips
  run execution, `application.ex`), Discord/gateway off.
- **Fixture modules live in `test/support/`.** Modules defined inline in
  `.exs` files (the `OkReactor` pattern, `workflow_lease_test.exs`) exist only
  on the test node. Anything a *peer* must execute — fixture reactors,
  blocking steps — must be compiled onto the code path peers load
  (`test/support/` via `elixirc_paths(:test)`, `mix.exs:52`).
- **The Ecto sandbox is the hard part.** `Ecto.Adapters.SQL.Sandbox`
  ownership cannot span BEAMs — a peer can never join the test node's sandbox
  connection, so the shared-sandbox pattern the single-BEAM lease tests rely
  on (`workflow_lease_test.exs` moduledoc) is out. Run the cluster suite as
  its **own `mix test --only cluster` invocation** behind an env flag (say
  `JIDOCLAW_CLUSTER_TEST=1`) that `config/test.exs` uses to switch the Repo
  pool from `Ecto.Adapters.SQL.Sandbox` to the regular pool and key the
  database name to `jido_claw_cluster_test` — the exact `MIX_TEST_PARTITION`
  keying precedent already in that file (`config/test.exs:156`;
  `scripts/test-partitioned.sh` header). The `mix test` alias's
  `ash.setup --quiet` creates/migrates the DB on first use, same as partition
  DBs. Clean between tests by truncation (per-test unique tenants alone leave
  rows behind).
- **Tag + CI wiring.** `@moduletag :cluster`, excluded by default in
  `test_helper.exs` beside `:docker_sandbox` and `:slow`. That automatically
  keeps the suite out of `mix test`, `precommit`, and
  `scripts/test-partitioned.sh` partitions (shared-DB tests can't run in
  parallel shards). Runs on demand:
  `JIDOCLAW_CLUSTER_TEST=1 mix test --only cluster` (a mix alias can package
  the pair).

### Proof: fence race (WS1)

Seed one claimable run in the shared DB; two peers race the WS1 claim
(`claim_next`, `SKIP LOCKED`); exactly one wins; the loser never executes (no
second lease stamp, no duplicate execution events in the parent log). No kill,
no expiry, no timing window — the race is decided by the DB, which is exactly
why it's the Phase 1 proof: it forces every harness decision (boot, shared DB,
concurrent claim) while staying immune to the flakiness that haunts
timing-dependent scenarios.

## Phase 2 — lease lifecycle proofs (kill + expiry machinery)

What Phase 2 adds to the harness: killing a node mid-run, **real** shortened
lease windows, and DB-polling helpers.

**Kill semantics.** The kill must be abrupt enough to leave a *stale* lease —
a graceful application shutdown that releases the lease cleanly proves
nothing. Use `:peer.stop/1` if it halts without clean app shutdown, else an
`:rpc` `:erlang.halt/0`; assert the lease row survives the death before
waiting on reclaim.

**Lease timing on peers.** The single-BEAM tests park the auto-renew timer
(`renew_seconds: 86_400`) and drive the sidecar through the
`{:lease_tick, from}` seam (`workflow_lease_test.exs` moduledoc). A peer can't
be driven through an in-BEAM seam so conveniently — push short *real* windows
to peers instead (expiry in a few seconds, renew cadence comfortably inside
it) and poll for state transitions.

**Flakiness watch.** Multi-node lease tests are `async: false` and
timing-sensitive. Per `[[project_suite_flaky_tests]]`, async:false
singleton/resource tests already move run-to-run under load — verify these in
isolation, use generous lease windows relative to renew cadence, and never
wall-clock-sleep: poll the DB for the claimed/reclaimed state. A
`BlockingStep` fixture that waits on a flag row gives a deterministic
"mid-execution" window without sleeps.

The proofs:

- **Reclaim across real nodes** — peer A claims and starts a run; kill A; peer
  B reclaims after lease expiry and resumes/re-runs it correctly (WS1 + WS3).
- **Stale-fence halt across nodes** — force-reclaim a run B is actively
  executing (the `BlockingStep` window); B's `WorkflowLease.Middleware` halts
  it without a double terminal (WS1).

## Phase 3 — subsystem proofs

Four proofs riding the proven harness, in rough ascending order of scenario
complexity. Each is mostly test code, but each has its own choreography.

- **Cross-node cancel** — cancel on A a run owned by B; B's executor is killed
  promptly via the terminator route, `run_cancelled` already durable (WS5; the
  IOU at `run_terminator_test.exs:12`).
- **Leader election** — exactly one leader across peers; re-elects on leader
  death (WS4; the IOU at `core/cluster/leader_test.exs:3`).
- **User-cron exactly-once failover** — two peers; exactly one runs a given
  user job (the leader's `Cron.Owner`); kill the leader, assert the survivor's
  Owner reloads within the election + reconcile window and continues firing,
  with no double-fire (WS4a; the IOU at `cron/owner_test.exs:7`). Pairs
  naturally with leader election — same kill-the-leader machinery.
- **Composer reclaim across nodes** — kill a node mid-composer-route; a peer
  rebuilds state from the parent log and resumes mid-route (WS2 + WS3). **The
  riskiest single scenario** (killing at a specific point in a route, then
  asserting the rebuilt route continues rather than restarts): if it fights
  back, split it into its own unit rather than letting it block the other
  three.

## Phase 4 — observability + ops

No dependency on the other phases; sits last so the flip checklist documents a
proven system.

### Lease observability

- Add lease telemetry events (claimed / renewed / reclaimed / fenced-out)
  beside the existing `[:jido_claw, :orchestration, :recovered]`
  (`workflow_recovery.ex:460-466`). Today `workflow_lease.ex` and its
  middleware emit none. These get single-BEAM unit tests — the Phase 2/3
  proofs deliberately poll the DB instead (telemetry is node-local; a peer's
  events never reach the test node's handlers).
- Surface `claimed_by` / `claim_expires_at` in the workflow dashboard so an
  operator can see *which node owns a run* — gust's stated payoff of a
  DB-backed lease ("the dashboard can show who owns a run",
  `gust/…:127-128`). This pairs with the AR-2 §10.2 observe surface
  (`workflow_status` / `WorkflowView`). **Caution**: new WorkflowsLive assigns
  must be added to the hand-built render maps in 3 test files
  (`[[project_workflowslive_render_assigns_triad]]`), or the KeyErrors only
  surface in the full precommit test phase.

### Deployment config & the `cluster_enabled` flip checklist

The topologies exist (`core/cluster.ex:97-160`) but running clustered needs:

- **Gossip secret.** The default `:gossip` strategy **raises without a shared
  secret** (`core/cluster.ex:166-193`, `gossip_secret!/0`) —
  `JIDOCLAW_CLUSTER_SECRET` / `:cluster_secret` must be set on every node, or
  pick `:kubernetes` / `:epmd`.
- **Topology choice.** `:cluster_strategy` (default `:gossip`,
  `config.exs:187`). Document gossip (multicast, dev/LAN) vs kubernetes (DNS)
  vs epmd (static hosts).
- **The flip checklist** — a documented precondition list for setting
  `cluster_enabled: true`:
  1. WS1 (lease) **and** WS3 (reclaim) have landed — otherwise recovery is
     silently off (README §gotcha). **Hard gate.** (Both shipped; the row
     survives as the record of *why* it's a gate.)
  2. WS4 leader election present (or cron audited idempotent).
  3. A shared, reachable Postgres (already required; confirm not per-node).
  4. Cluster secret / topology configured on every node.
  5. `serve_mode` is not `:mcp` on the execution nodes (MCP mode skips
     Gateway + run execution, `application.ex`).

### Small gate fix (the WS0 leftover)

- **Embedding counter `:cluster_enabled` gap.** The cross-node embedding
  budget counter runs **unconditionally** (`embeddings/rate_pacer.ex`, called
  at `backfill_worker.ex:314-315`), but `PLAN-v0.6-memory.md:1731-1734`
  designed it to engage only "when clustering is enabled." The code is
  **harmless and correct single-node** (a one-row UPSERT per dispatch, as the
  doc itself notes at `:1816-1818`). **Recommendation: update the doc to match
  the code** (unconditional is fine and simpler) rather than add a gate — but
  record the decision explicitly so the discrepancy isn't re-discovered as a
  bug. Trivial either way.

## Deferred beyond all phases

Two README-tracked items live under WS6's umbrella but are consciously
unscheduled (the README's deferral rows): the **composer hung-wave watchdog**
(a wave with `execution_timeout: :infinity` that never returns blocks the
composer GenServer while its sidecar keeps renewing the lease; C-M3,
`route_composer.ex`) and **cron-worker stuck-detection** (dispatch is
synchronous, so a hung target blocks the worker; a watchdog needs async
dispatch, `cron/worker.ex`). Neither blocks closing the clustering program;
revisit if a stuck wave/worker actually bites.

## Cross-references

- Current mock harness — `test/jido_claw/forge/clustering_test.exs`.
- Single-BEAM lease/reclaim coverage the proofs extend —
  `test/jido_claw/orchestration/workflow_lease_test.exs`,
  `workflow_recovery_test.exs`, `reclaim_pooler_test.exs`; helpers in
  `JidoClaw.Orchestration.LeaseHelpers`.
- The cross-BEAM IOUs — `cancellation_routing_test.exs:9`,
  `run_terminator_test.exs:12`, `cron/owner_test.exs:7`,
  `core/cluster/leader_test.exs:3`, `platform/cron/owner.ex:85`,
  `orchestration/run_terminator.ex:25`.
- Topology + secret — `core/cluster.ex:97-193`; config `config.exs:186-187`.
- Partition-keyed test DBs (the shared-DB precedent) — `config/test.exs:156`;
  `scripts/test-partitioned.sh` header.
- Embedding counter — `embeddings/rate_pacer.ex`; design
  `PLAN-v0.6-memory.md:1731-1834`.
- Observe surface — AR-2 §10.2 (`AR-2-COMPOSER-PLAN.md:906-926`); gust
  DB-backed payoff `gust/FEATURES-WORTH-BORROWING.md:127-128`.
- Validates: WS1–WS5, WS4a.

## Deviations

*Logged as they happen during implementation, per the AGENTS.md "Planning &
Implementation Conventions": what the plan assumed / what the code revealed / what was
chosen and why / what to revisit — marking whether the choice was operator-decided
(surfaced as options first) or forced (one sensible path, taken and logged). Empty
until Phase 1 starts; this workstream is the convention's first user.*

### Phase 1

- **Longnames pinned to `@127.0.0.1`, not snames** *(operator-decided at plan
  review)*. The doc's "Distribution bootstrap" point assumed "a per-run unique
  sname". Implementation uses longnames pinned to the loopback address
  (`jc_origin_<os-pid>_<unique>@127.0.0.1`, `jc_peer<i>_<suffix>@127.0.0.1`)
  — same per-run-uniqueness intent, but immune to the macOS/CI hostname
  resolution flakiness snames inherit (an sname resolves via the machine's
  hostname, which changes with DHCP/VPN and sometimes doesn't resolve at all).
  Nothing to revisit; `:peer`'s `host`/`longnames` options carry it directly.
- **`TenantCase` helpers are called qualified from `ClusterCase`'s own setup,
  not imported into the `using` block** *(forced: one sensible path)*. The
  implementation plan sketched `import TenantCase (seed_tenant/1, actor_for/1)`
  inside `using`. But test modules never call those lexically (the template's
  `setup` does the seeding), and a wholly-unused `import` warns — which
  `mix jidoclaw.compile_check` (empty allowlist) turns into a gate failure.
  `ClusterCase` aliases `JidoClaw.TenantCase` and calls the helpers in its own
  `setup`; the `using` quote imports only what test bodies actually use
  (`PeerHarness.call/await`, the `LeaseHelpers` seeders). The deliberate
  "plain functions, never `use TenantCase`" rule (its setup starts a sandbox
  owner, which explodes on the regular pool) is unchanged.
- **The peer-cleanup wrapper is `catch`-only, not `rescue` + `catch`** *(forced:
  one sensible path)*. The plan prescribed `try ... rescue ... catch kind,
  reason` for `PeerHarness.cleanup_on_failure/2`; the reach smell gate rejects
  a bare `rescue` (and credo strict rejects the explicit `try`). A two-arg
  `catch` already covers all three classes — `:error` (raises) included — and
  `:erlang.raise(kind, reason, __STACKTRACE__)` re-raises faithfully, so the
  plan's actual requirement (any failure class stops already-started peers,
  original class + stacktrace preserved) holds with less machinery. The
  TRUNCATE statement in `ClusterCase.truncate_all!/0` keeps its interpolation
  under an inline `# reach:disable-next-line ecto_interpolated_repo_query`
  (identifiers cannot be parameterized; names come from `pg_tables` and are
  quoted).

### Phase 2

- **No new flag-row `BlockingStep` reactor** *(forced: one sensible path)*.
  The phase sketch called for "a `BlockingStep` fixture that waits on a flag
  row"; the existing `BlockingTestReactor` (sleep-infinity) + polling the
  durable `step_started` event already gives the deterministic no-sleep
  mid-execution window, and no Phase 2 proof ever releases the blocked step —
  all three end via node death, fence-kill, or a gate park. The releasable
  flag-row fixture is deferred until a proof needs staged release (Phase 3
  composer choreography, likely).
- **Proof A asserts fail-with-audit, not resume** *(operator-decided at plan
  review)*. The sketch said "peer B reclaims … and resumes/re-runs it
  correctly"; shipped WS3 never re-executes a plain reactor on reclaim — it
  terminalizes `:failed` with the `run_recovered` + `run_failed` audit pair
  (boot-parity Q1, `workflow_recovery.ex`). True resume is proven by Proof C
  now and the composer proof in Phase 3.
- **Proof C (gated resume across nodes) added** *(operator-decided at plan
  review)* beyond the sketch's two proofs — closes the `human_gates_test.exs`
  IOU ("a separate-BEAM resume is a follow-up").
- **Proof B's "force-reclaim" is staged** *(forced)*: `rotate_token!` (the
  documented reclaimer-steal seed) followed by a REAL `reclaim_once` on the
  other peer. Racing a genuine cross-node claim against a healthy 1s renew
  cadence is inherently flaky; the production sequence (rotate → fence-kill →
  reclaim disposition) is preserved end-to-end — only the rotation is seeded.
- **`kill_peer/1` rides `:peer.stop/1`** *(forced)*, not an `:rpc`
  `:erlang.halt/0` (the sketch offered either): with
  `connection: :standard_io` and no `:shutdown` option, `:peer.stop/1` closes
  the stdio control port and the peer self-halts via `erlang:halt()` — abrupt
  (no `Application.stop`, nothing releases the lease), a supported API, and it
  already blocks until nodedown. Proof A asserts the stale lease survived the
  death, so a graceful `:shutdown` option added to the harness later fails
  loudly rather than silently rotting the premise.
- **Proof C found a real WS3 recovery bug — `GateResume` gained a
  module-sweep retry** *(forced by discovery; the plan's "no production
  changes" premise did not survive contact with the proof)*. On a fresh BEAM
  (a reclaiming peer — equally a fresh boot-recovery BEAM under mix), the
  checkpoint's inner `binary_to_term(_, [:safe])` raised `ArgumentError`:
  `[:safe]` refuses atoms the VM has not interned, and `resolve_module/1`'s
  `Code.ensure_loaded?` covers the gate-reactor module but NOT the halted
  struct's transitive machinery. A throwaway cross-node probe pinned exactly
  one missing atom out of 157 — `:ash_notification_agent`,
  `Ash.Reactor.Notifications`' agent key, which rides every halted context
  (its `agent_stop/1` keeps the key as `[]`) and is interned only once that
  module loads, i.e. only after a reactor has actually run on that BEAM. Fix:
  on the first inner-decode `ArgumentError`, `GateResume` loads every loaded
  application's compiled modules (best-effort, idempotent, embedded-mode
  semantics) and retries the `[:safe]` decode once; a second refusal is
  genuine corruption (`:corrupt_checkpoint_inner`). The `[:safe]` posture is
  retained. The same-VM suite cannot regression-test this (atoms cannot be
  un-interned), so Proof C is the regression test. The other `[:safe]` sites
  were checked and keep their decode paths: `Replay`'s blob is data-shaped
  with the definition resolved first, and the composer artifact envelope is
  primitive-only by contract.
- **Cluster-suite import mechanics, refined** *(forced)*: a proof module's
  local `import Mod, only:` REPLACES the `using`-quote's import of the same
  module (last directive wins), so each local list carries everything that
  module uses — while imports injected by the `using` quote are exempt from
  the per-`{name, arity}` unused-import warning (verified empirically with a
  scratch probe), so the shared quote stays as-is even though no proof module
  uses all of it.
