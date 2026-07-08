# WS6 Phase 3 — subsystem proofs (implementation plan)

## Context

WS6 (`docs/plans/clustering/WS6-testing-and-ops.md`) is the last clustering workstream.
Phases 1–2 shipped (commits `9e485107`, `e581e308`): the `:peer` multi-node harness
(`ClusterCase`, `PeerHarness`, `PollHelpers`, `RunFixtures`, `scripts/test-cluster.sh`,
shared `jido_claw_cluster_test` DB behind `JIDOCLAW_CLUSTER_TEST=1`) plus four proofs
(fence race, reclaim-across-nodes, stale-fence halt, gated resume).

Phase 3 delivers the remaining cross-BEAM subsystem proofs — the IOUs the shipped
workstreams left: cross-node cancel (WS5), leader election (WS4), user-cron failover
(WS4a), composer reclaim (WS2+WS3). **Operator decisions at plan review** (log these
in the WS6 doc's Deviations `### Phase 3` when implementation starts):

1. All four proofs in this one plan (composer sized medium — near-drop-in single-BEAM
   templates exist).
2. The composer proof is **doubled**: BOTH kill points — gate-park AND mid-worker-wave
   — as two separate modules (the WS6 doc sketched one proof; operator chose maximal
   coverage of both resume paths).
3. The WS3 rolling-deploy-overlap rider (`WS3-reclaim-and-recovery.md:225-229`,
   unclaimed by Phase 2) is folded in as a fifth proof.

Six new one-test modules under `test/jido_claw/cluster/` + small `test/support`
fixtures. **No production code changes planned** — every seam exists. (Phase 2
precedent: a proof may surface a real fresh-BEAM production bug; fix forward and log
it in Deviations.)

## Constraints (operator-set)

- Complete only when `mix precommit` passes AND the cluster suite is green
  (`mise exec -- scripts/test-cluster.sh`).
- Greenfield; no compat concerns. No commits — everything stays unstaged; finish
  commit-ready (files-to-stage + suggested message).
- No deferrals. Deviations logged in `WS6-testing-and-ops.md` `## Deviations` →
  new `### Phase 3` heading, as they happen.

## Harness facts the proofs build on (shipped, Phases 1–2)

- `use JidoClaw.ClusterCase, async: false, peer_overrides: [...]` boots exactly 2
  peers in `setup_all`; per-test setup truncates the shared DB and seeds a fresh
  tenant/actor (`%{tenant:, actor:, ctx:, peers:, nodes:, node_a:, node_b:}`).
  `peer_overrides` are WHOLE-KEY `:jido_claw` app-env replacements, merged over the
  harness defaults (`cluster_enabled: true, cluster_strategy: :none, skip_discord:
  true` + full origin env snapshot — so `config/test.exs` gates reach peers unless
  overridden).
- `PeerHarness.call/5` (`:erpc`), `await/2` (25ms bounded poll), `kill_peer/1`
  (abrupt `:peer.stop`, lease left stale, blocks until nodedown).
- `PollHelpers` (always import locally): `await_run!/3`, `await_kind!/4`,
  `await_executor_gone!/3`, `await_reclaim!/3` (drives `reclaim_once` until exactly 1
  claim per pass — **flunks on >1**, see Proof 6's caveat).
- `LeaseHelpers`: `reload_global/1`, `kinds/2`, `seed_run/1,2`, `expire_claim!/2`,
  `rotate_token!/2`, `backdate_inserted!/2`.
- `RunFixtures` (peer-side named MFAs, spawn-unlinked): `launch_blocking/1`,
  `launch_gated/1`.
- Conventions: **one kill per module**; a local `import Mod, only:` REPLACES the
  using-quote's import of that module (re-list everything used); telemetry/PubSub/ETS
  are node-local — cross-node evidence is the shared DB or `:erpc` probes only; never
  bare-sleep; anything a peer executes is a named MFA in `test/support/`; kill-proof
  modules copy the `neutralize_leaked_executor_on_exit` private helper (truncation
  clears rows, not processes).
- Short-lease override set (kill/expiry proofs):
  `workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]`.

---

## Proof 1 — cross-node cancel (WS5)

**File**: `test/jido_claw/cluster/cross_node_cancel_test.exs`. No kill, no overrides
(`RunTerminator` is ungated/always-on, `application.ex:167`; no lease expiry
involved). Closes the IOUs at `cancellation_routing_test.exs:8-9`,
`run_terminator_test.exs:11-12`, `run_terminator.ex:24-26` (real cross-BEAM cast
*delivery*).

**Choreography** (one test):
1. `call(node_b, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)` → `{:ok, run_id}`
   (returns only after `step_started` is durable).
2. `await_run!(run_id, &(&1.claimed_by == to_string(node_b) and &1.status == :running))`;
   assert executor alive on B: `call(node_b, RunExecution, :lookup, [run_id])` →
   `{:ok, _pid, _tenant}`.
3. Cancel **on node A** (the non-owner):
   `call(node_a, Cancellation, :cancel, [run_id, [tenant: tenant, actor: actor,
   reason: "cross-node proof"]], 30_000)` → `{:ok, %{status: :cancelled}}`.
   (Path: `cancellation.ex:97` — durable `run_cancelled` append first, then
   `resolve_kill_target(claimed_by, self, Cluster.nodes())` → `{:remote, node_b}` →
   `GenServer.cast({RunTerminator, node_b}, {:kill, run_id, tenant_id})` →
   `RunExecution.kill_local/2`, tenant-pinned.)
4. `await_executor_gone!(node_b, run_id)` — the delivery/promptness proof.
5. Final: status `:cancelled`; exactly one `:run_cancelled` in `kinds`, no
   `:run_failed`; `claimed_by` still node B (lease frozen at terminal);
   `call(node_a, ReclaimPooler, :reclaim_once, [])` → `0` (cancelled ∉ `:claimable`).
6. `neutralize_leaked_executor_on_exit` guard for the regression case.

## Proof 2 — leader election (WS4)

**File**: `test/jido_claw/cluster/leader_election_test.exs`. One test, one kill, no
overrides. Closes the IOU at `leader_test.exs:2-8`. The fence-race smoke already
proves cross-BEAM *agreement*; the novel content is **re-election on a real
leader-node death** (genuine remote `node(pid)` over `:pg` — impossible single-BEAM).

**Choreography**:
1. `await` until both peers return the same non-nil
   `call(n, JidoClaw.Cluster, :leader, [])`; assert exactly one
   `call(n, JidoClaw.Cluster, :leader?, [])` is true. Compute `leader_node`
   dynamically (lowest-name-wins, but never hardcode which peer).
2. `kill_peer(leader_peer)` (find the `%{node:, server:}` entry by node name).
3. `await` (~30s bound) until the survivor reports `leader() == survivor` and
   `leader?() == true` (`:pg` leave → `recompute/2` is event-driven).

## Proof 3 — healthy lease never reclaimed (the WS3 rider)

**File**: `test/jido_claw/cluster/healthy_lease_not_reclaimed_test.exs`. No kill.
**Overrides**: short-lease set + `reclaim_pooler: [enabled?: true,
poll_interval_ms: 500, initial_delay_ms: 0]` — with the pooler LOOP live on the
peers, B continuously polls exactly like a freshly-booted/rejoining production node
(the OpenHelm scenario), rather than the test hand-driving `reclaim_once`.

**Choreography**: `launch_blocking` on A (A's sidecar auto-renews every 1s under the
override) → capture the run's first `claim_expires_at` (t0) → await, via a DB-clock
probe (new `PollHelpers.await_db_clock_past!/2`, `SELECT now() > $1` polled through
`PeerHarness.await/2` — never wall-clock), until the DB clock is past t0 + margin
(we've outlived a full original lease window while B's pooler polled throughout) →
assert: run still `:running`, `claimed_by` still A, `claim_token` unchanged,
`claim_expires_at` now in the future (renewal advanced it), `kinds` contains no
`:run_recovered`/`:run_failed`. `neutralize_leaked_executor_on_exit`.

## Proof 4 — user-cron exactly-once failover (WS4a)

**File**: `test/jido_claw/cluster/cron_failover_test.exs`. One test, one kill (the
leader). Closes the IOUs at `owner_test.exs:6-8` / `owner.ex:81-85`.
**Overrides**: `[cron_owner: [enabled?: true], cron_workflow_runner:
JidoClaw.Cluster.CronProbeRunner]` — `config/test.exs:36` forces the Owner off and
peers inherit it (verified: `serve_mode` is nil in test, so `enabled?` is the only
blocker). No lease overrides.

**New fixture — `JidoClaw.Cluster.CronProbeRunner`**
(`test/support/jido_claw/cluster/cron_probe_runner.ex`): a `:cron_workflow_runner`
stub (the documented dispatch seam, `dispatcher.ex:76-85`) recording one durable
node-attributed `WorkflowRun` row **per fire** — created directly through the
`WorkflowRun.create/2` code interface with explicit required attrs (`name` is
`allow_nil?(false)`) and a **truly per-fire unique key** (the probe bypasses
`WorkflowRunner.run/1`, so it inherits none of its read-first/dedupe — a reused key
would surface as a raw Ash unique-identity error; a unique suffix removes the case
instead of reimplementing recover-race in a fixture):
`%{name: "cron-probe:<job_id>:<window>:<node>", workflow_type: "cron-probe",
idempotency_key: "cron-probe:<job_id>:<window>:<node>:<unique_integer>",
metadata: %{node:, window:}}`, opts
`tenant: state.tenant_id, actor: Actor.system(state.tenant_id)`. (NOT
`LeaseHelpers.seed_run` — it takes only `ctx` + optional name and cannot set the
key, `lease_helpers.ex:40`.) Every fire is a visible row attributed to its node via
`metadata.node` — a fire from a wrong node can never be masked (unlike the real
`cron:<job>:<window>` key, whose unique index dedupes cross-node). Mirror
`WorkflowRunner.run/1`'s argument/return contract (`workflow_runner.ex:92-136` —
read job_id/window/tenant from the worker state).

**Choreography**:
1. Establish the leader (Proof 2 step 1); name `leader` / `follower`.
2. Seed a fast user job from the test node:
   `JidoClaw.Cron.Job.upsert(%{job_id: ..., task: ..., mode: :main,
   target: :workflow, workflow_name: ..., schedule_kind: :every,
   schedule_value: "1000"}, tenant:, actor:)` (`job.ex:54`; `:every` takes ms —
   crontab granularity is minutes).
3. Drive the **initial** load explicitly:
   `call(leader, JidoClaw.Cron.Owner, :reconcile, [], 30_000)` and the same on the
   follower (`leader_changed` never fires for the initial election; the periodic tick
   is 30s — `owner.ex:30-34`).
4. Ownership: `call(leader, Cron.Scheduler, :list_jobs, [tenant])` contains the
   job; the follower's (post-reconcile) is empty — a deliberate no-op, not merely
   unrun. (`ClusterCase` seeds `tenant` as the STRING id from
   `TenantCase.seed_tenant/1`, and `list_jobs/1` takes a `String.t()` — never
   `tenant.id`.)
5. Await firing: ≥2 probe rows; every row's `metadata.node` is `leader`.
6. Snapshot the pre-kill probe rows (ids/count) — the concrete cutoff for step 8 —
   then `kill_peer(leader)`. Do **not** reconcile the survivor — the automatic
   `leader_changed` → reconcile path (`owner.ex:299`) IS the WS4a failover claim.
7. Await failover (~45s bound: election + telemetry reconcile + next 1s tick, 30s
   periodic tick as documented worst-case backstop): survivor `leader?` true;
   survivor `list_jobs` contains the job; a NEW probe row appears whose
   `metadata.node` is the survivor.
8. No-double-fire — **node-partition assertions, not window grouping**: each worker
   computes its `:every` window from its own `DateTime.utc_now()`
   (`worker.ex:317`), so two wrongly-live workers would fire the same real interval
   under DIFFERENT window timestamps — exact-window grouping cannot detect that.
   Assert instead against the step-6 snapshot: (a) zero follower-node rows exist at
   kill time (the whole pre-kill population is the leader's), and (b) every row NOT
   in the pre-kill snapshot is the survivor's (no killed-leader rows among newly
   observed rows — an id-set difference, not a timestamp comparison). The window
   stays in the key only for row uniqueness/debuggability.

## Proof 5 — composer reclaim across nodes, gate-park variant (WS2+WS3)

**File**: `test/jido_claw/cluster/composer_reclaim_gate_park_test.exs`. One test, one
kill. **Overrides**: the short-lease set.

Kill while durably parked at a gate: proves rebuild-from-log, wave-0 fold (never
re-run), **cross-node re-park**, live gate decision on the reclaiming node, converge
on B. Deterministic — the park is a durable DB state, no timing window, and **no
flag-row fixture is needed** (contra the Phase 2 deviation's prediction — log this).

**Fixtures** (new):
- `RunFixtures.launch_composer/2` (peer-side MFA): takes `ctx` + a catalog key atom;
  builds the catalog PEER-SIDE via `JidoClaw.RouteComposer.TestFixtures` (no struct
  shipping); `RouteComposer.create_parent_run/1` + `ensure_started/2`
  (`route_composer.ex:412,:728`), opts mirroring `run_sync/1`'s construction
  (`:1014`); returns `{:ok, parent_run_id}`. **Ctx-shape caveat**: `ClusterCase`'s
  `ctx.ctx` is only `%{tenant:, actor:}`, while `TestFixtures.base_opts/1` expects a
  `ctx.context` key — the launcher builds its opts manually (or normalizes with
  `context: %{}`) rather than passing the cluster ctx into `base_opts/1`, else
  `KeyError`.
- A peer-callable stub-env installer (new function beside
  `TestFixtures.phase1_template_override/1`, `fixtures.ex:326`): performs the
  `:agent_templates_override` / `:step_agent_server` / `:route_composer_stub_outputs`
  `Application.put_env` calls the single-BEAM gate tests do in `setup` — invoked ON
  each peer via `call/4` at test start (per-test `put_env` on the origin never
  reaches peers; `peer_overrides` can't carry runtime-built structs). Parameterize
  the agent-server module per peer (Proof 6 needs A≠B). **It must also create the
  `StubStore` ETS table** (`StubWorker.ask/3` writes through `StubStore.put/2`,
  which does NOT create the table — `composer_stubs.ex:23`; the single-BEAM tests
  call `StubStore.setup()` in `setup`, `composer_durable_test.exs:57`), and because
  the table dies with its owning process (`composer_stubs.ex:47-52` — a bare `:erpc`
  call would own it transiently), the installer spawns a long-lived unlinked holder
  process on the peer that runs `StubStore.setup()` and sleeps, returning only after
  a readiness handshake (the `RunFixtures` launcher pattern). Both peers need it —
  B especially, whose post-reclaim waves run StubWorker on B's node-local ETS.

**Choreography**:
1. Install stub env on both peers (plain `StubAgentServer` both sides);
   `call(node_a, RunFixtures, :launch_composer, [ctx.ctx, :gate_fixture], 30_000)`
   using `TestFixtures.gate_fixture_catalog/0` (`fixtures.ex:574` — linear
   `planner → plan-gate → implementer`, validator-clean, LLM-free).
2. Await the durable mid-route state: `:wave_completed` (wave 0) and `:wave_paused`
   in `kinds`; gate child `:awaiting_approval`; parent `:running`, claimed by A.
3. `kill_peer(peer_a)`; assert the stale parent lease survived (Phase 2 Proof A
   pattern: `:running`, token unchanged).
4. `await_reclaim!(node_b, parent_run_id)` (exactly one claimable row here — the
   parent; the gate child is leaseless). Reclaim path:
   `WorkflowRecovery.reclaim_composer/1` (`workflow_recovery.ex:537`) — parked gate
   child doesn't block `restartable?` (`:701`) → `ensure_started` on B →
   `do_rebuild` (`route_composer.ex:1466`) → wave 0 folds into `ran` →
   `derive_park` (`:3561`) → `re_enter_park`.
5. Await the re-park: `:wave_paused` count reaches 2; parent
   `claimed_by == to_string(node_b)` (the column is a string — match the existing
   cluster tests' shape).
6. Decide the gate ON node B (`call(node_b, Cases, :decide, [case_id, :approve, %{},
   [tenant: tenant, actor: actor]])` — decision signals are node-local and the parked
   composer lives on B). **Case discovery: the gate `AgentCase` is opened on the gate
   CHILD run, not the parent** (`gate_step.ex:59`) — read `case_id` from the durable
   `:wave_paused` event payload (`%{wave_index:, agent_case_id:, child_run_id:}`,
   `route_composer.ex:3015-3017`); `AgentCase.pending_for_run_tree(parent_id)`
   (`agent_case.ex:339`) or resolving the gate child at `composer:<parent>:1` are
   the fallbacks. Composer resumes → implementer wave runs on B → converges.
7. RESUME-not-RESTART asserts: exactly one `:run_started` (same parent id);
   `:wave_completed` payload `wave_index: 0` exactly once; exactly one wave-0 child
   at key `composer:<parent>:0`; **exactly one gate child at key
   `composer:<parent>:1`** (gate waves are idempotency-keyed too,
   `route_composer.ex:1783`) and **both `:wave_paused` payloads reference the same
   `agent_case_id` + `child_run_id`** (the re-park re-attached to the SAME gate —
   a duplicated gate child can't slip through); **exactly one completed post-gate
   implementer child (key `composer:<parent>:2`) with
   `claimed_by == to_string(node_b)`** — the resumed wave genuinely ran on B, same
   child-level proof shape as Proof 6; exactly one `:route_converged`, no
   `:route_failed`; parent `claimed_by == to_string(node_b)`.

Watch-outs: no `verify`-unit stages (need a real working tree); the gate child is
leaseless so only the PARENT lease drives reclaim timing.

## Proof 6 — composer reclaim across nodes, mid-worker-wave variant (WS2+WS3)

**File**: `test/jido_claw/cluster/composer_reclaim_midwave_test.exs`. One test, one
kill. **Overrides**: the short-lease set.

Kill while a WORKER wave's child is in flight: proves the reclaim-specific
child-step cross-node — corpse child token-rotated + failed, wave re-dispatched under
a **fresh wave index**, route converges on B (`reclaim_pooler_test.exs:256` is the
single-BEAM template; `handle_wave_result/4` rule 2, `route_composer.ex:1935`).

**Fixture needs beyond Proof 5**:
- A minimal **linear 2-stage worker catalog** (planner → implementer, no gate, no
  parallel waves) — add to `TestFixtures` unless an existing linear worker-only
  catalog fits (check first; `phase1_catalog`'s parallel reviewer wave is the thing
  to avoid).
- A **new template-selective blocking agent server** (beside the other stubs in
  `composer_stubs.ex`) — neither existing server fits this shape:
  `GatedAgentServer` blocks the FIRST `await_completion/2` (that would be wave 0's
  planner) and `BlockingAgentServer` blocks EVERY call, so either stalls wave 0
  before the "wave 0 completed" checkpoint. The new server lets the planner
  complete (delegating to `StubAgentServer` behavior) and blocks forever ONLY the
  configured template's request (blocked template named via app env). **This needs
  one explicit fixture change to make the decision input exist**: today the
  `StubStore` entry stores only `status`/`result`/`meta` (`composer_stubs.ex:87`)
  and `await_completion/2` opts carry no template (`agent_runner.ex:555`) — so
  `StubWorker.ask/3`, which already selects canned output BY agent template, must
  also stamp that template into the stored entry (an extra key is invisible to the
  existing readers), or write a parallel `request_id -> template` ETS entry; the
  selective blocker then decides by store lookup. Installed on peer A only via the
  per-peer stub-env installer; peer B gets plain `StubAgentServer` so the
  re-dispatched wave COMPLETES.

**Choreography**:
1. Install divergent stub env (A blocking, B plain); `launch_composer` on A with the
   linear catalog.
2. Await the durable in-flight state: `:wave_completed` (wave 0) present, second
   `:wave_started` present, wave-1 child at key `composer:<parent>:1` exists and is
   `:running` claimed by A.
3. `kill_peer(peer_a)`; assert BOTH parent and wave-1 child leases survived stale.
4. Drive reclaim on B with a **tailored poll, not `await_reclaim!`** — two claimable
   rows exist (parent + corpse child) and claim order is not guaranteed:
   `await(fn -> call(node_b, ReclaimPooler, :reclaim_once, []); reload_global(parent).claimed_by == to_string(node_b) end, 30_000)`-style
   (tolerate any per-pass count; both orders are correct — parent-first handles the
   child inside `reclaim_children/3`, child-first fails it via `reconcile_one/1` and
   the next pass claims the parent).
5. Await convergence on B: rebuilt composer folds wave 0, dedupe-hits the failed
   wave-1 child → re-dispatches its stages under a fresh wave index → B's plain stub
   completes them → `:route_converged`.
6. Asserts: wave-0 events exactly once + exactly one child at key `:0`; corpse child
   at key `:1` terminal `:failed` (don't over-pin its audit kinds — the two claim
   orders leave different trails); a FRESH completed child exists for the re-run
   stages (key `:2`) with `claimed_by == to_string(node_b)`; exactly one
   `:route_converged`, no `:route_failed` on the parent; parent
   `claimed_by == to_string(node_b)`.

This is the riskiest module (the WS6 doc's warning applies here, not to Proof 5). If
it fights back in ways that demand production changes beyond a discovered-bug fix,
stop and surface options rather than improvising scope (per the operator's
no-deferrals + interview rules).

---

## Cross-cutting implementation notes

- Module skeleton: `use JidoClaw.ClusterCase, async: false` (+ overrides); local
  imports re-list everything used from `PeerHarness`/`PollHelpers`/`LeaseHelpers`;
  `alias JidoClaw.Cluster.RunFixtures` where used.
- Implementation order = the proof order above (ascending complexity; the cheap
  no-kill modules 1–3 shake out any harness friction first).
- Precommit gotchas (`[[project_precommit_newcode_gotchas]]`): no bare `rescue`
  (reach), no explicit `try` (credo strict), no comment line beginning with the word
  "step" (ExSlop wrap trap), `mix format`. New test/support modules face
  compile_check/credo/dialyzer/reach; cluster `.exs` files load-compile during
  precommit's test phase even though tag-excluded.
- New `PollHelpers.await_db_clock_past!/2` follows the existing helper conventions
  (flunk-with-state on timeout, built on `PeerHarness.await/2`).
- IOU comment hygiene — update the now-delivered IOU comments to point at the new
  proofs: `cancellation_routing_test.exs:8-9`, `run_terminator_test.exs:11-12`,
  `run_terminator.ex:24-26`, `leader_test.exs:2-8`, `owner_test.exs:6-8`,
  `owner.ex:81-85` (comment-only touches to the two lib files).
- WS6 doc: add `### Phase 3` under `## Deviations`, opening with the three
  operator-decided entries (all-four-in-one-plan; composer doubled to two kill-point
  modules; WS3 rider folded in) and the forced entry (no flag-ROW/DB fixture — the
  gate park needs no blocker at all, and the mid-wave window rides a new
  template-selective blocking agent server on peer A, since neither existing
  blocking server can let wave 0 pass), then log further deviations as they happen.
- `docs/system/`: no page covers the cluster harness (Phases 1–2 precedent), so
  `system_docs.check` demands nothing — unless a production file gains a real change
  (comment-only IOU updates don't count), in which case update its subsystem page in
  the same change.

## Verification

1. Per-module while developing:
   `mise exec -- scripts/test-cluster.sh test/jido_claw/cluster/<file>.exs`
2. Full cluster suite (Phases 1–3 together): `mise exec -- scripts/test-cluster.sh`
   — run at least twice; timing-adjacent async:false suites move under load
   (`[[project_suite_flaky_tests]]`: verify in isolation before blaming a change).
3. Full gate, bare, in background, read the tail
   (`[[feedback_no_pipe_on_gate_commands]]`): `mise exec -- mix precommit`
4. Sanity: default `mix test` still excludes `:cluster` (new modules invisible to it).

## Files

New:
- `test/jido_claw/cluster/cross_node_cancel_test.exs`
- `test/jido_claw/cluster/leader_election_test.exs`
- `test/jido_claw/cluster/healthy_lease_not_reclaimed_test.exs`
- `test/jido_claw/cluster/cron_failover_test.exs`
- `test/jido_claw/cluster/composer_reclaim_gate_park_test.exs`
- `test/jido_claw/cluster/composer_reclaim_midwave_test.exs`
- `test/support/jido_claw/cluster/cron_probe_runner.ex`

Modified:
- `test/support/jido_claw/cluster/run_fixtures.ex` — `launch_composer/2`
- `test/support/jido_claw/cluster/poll_helpers.ex` — `await_db_clock_past!/2`
- `test/support/jido_claw/route_composer/fixtures.ex` — peer-callable stub-env
  installer (per-peer agent-server param); minimal linear worker catalog if none fits
- `test/support/jido_claw/route_composer/composer_stubs.ex` — the new
  template-selective blocking agent server + `StubWorker.ask/3` stamping its matched
  template into the stored `StubStore` entry (Proof 6's decision input)
- `docs/plans/clustering/WS6-testing-and-ops.md` — Deviations `### Phase 3`
- IOU comment updates: `test/jido_claw/orchestration/cancellation_routing_test.exs`,
  `test/jido_claw/orchestration/run_terminator_test.exs`,
  `lib/jido_claw/orchestration/run_terminator.ex`,
  `test/jido_claw/core/cluster/leader_test.exs`,
  `test/jido_claw/cron/owner_test.exs`, `lib/jido_claw/platform/cron/owner.ex`
