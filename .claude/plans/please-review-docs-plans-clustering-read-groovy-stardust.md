# WS-4 — Leader Election + Singleton Audit — Implementation Plan

## Context

The clustering effort (`docs/plans/clustering/README.md`) makes multi-node workflow
execution correct. **WS1 (lease core) and WS3 (reclaim & recovery) have shipped** —
*run execution* is now cluster-safe via a DB claim-lease. WS-4 closes the *other*
half: **the always-on singletons that start on every node and would multi-fire under
clustering**, and the **leader-election primitive** they gate on. No prior doc built
leader election; the exploration docs only flagged the cron scheduler
(`REACTOR-ADOPTION.md:681-684`).

Two findings from the codebase audit reshape WS-4 vs. its sketch
(`docs/plans/clustering/WS4-leader-election-and-singletons.md`):

1. **The only cron replicated by the always-on supervision tree is the
   memory-consolidator tick**, seeded on *every* node by
   `Memory.Consolidator.SystemJobsInitializer` (`application.ex:264-269` →
   `Cron.Scheduler.start_system_jobs/0`) as a `mode: :system_job` cron job. User cron
   jobs are node-local and ad-hoc (`Cron.Scheduler.schedule/2`); persisted user jobs are
   loaded by **each CLI REPL** (`repl.ex:315`) — so two clustered *CLI* nodes can load and
   fire the *same* user job, while gateway-only clustered nodes load no user cron at all.
   ⇒ The cron fire-gate is **scoped to `:system_job` ticks** (the always-on-tree case):
   it stops the consolidator's per-node multi-fire without regressing single-CLI or
   follower-scheduled user jobs (a blanket gate would silence those). The multi-CLI-node
   user-job replication is the pre-existing **WS4a** gap (deliverable #7). The consolidator
   scheduler tick the doc lists separately *is* a `:system_job`, so one gate covers both.
2. **All the "needs-gating"/"optional" singletons are already idempotent or
   DB-coordinated** (`SKIP LOCKED` row-leases, advisory locks, idempotency keys), so
   leader-gating is *waste-reduction + first-line gating*, **not** the load-bearing
   correctness fix (the lease was — already shipped). `:pg` leadership is
   eventually-consistent, so a **brief two-leaders window** is possible while membership
   converges (a healing netsplit). That is harmless *today* because every gated unit is
   independently safe (advisory lock / `SKIP LOCKED` / idempotency key) — which is what
   justifies gating the sweepers too — but it means the leader gate **must not be relied
   on as the sole guard for a non-idempotent unit**. WS-4 therefore records a standing
   invariant (§3): **every system cron job must stay idempotent, row-claimed, or
   DB-leased**; the gate only reduces how often the safe-by-construction work runs.

**Intended outcome:** flipping `cluster_enabled: true` no longer N-fires the consolidator
on every node (the leader fires it; its advisory lock stays the correctness backstop) and
stops redundant cross-node sweeps/backfill — while single-node behavior stays
**byte-identical** (`leader?()` is trivially `true` with one node) and user cron is
**untouched**.

Per the user's direction: **no deferrals** — the one unit too large for WS-4
(clustered *user*-cron ownership) becomes its own design doc (`WS4a`, deliverable
#7); and **the plan is not complete until `mix precommit` passes** (8-step gate,
see "Definition of done").

---

## Scope (what ships)

| # | Deliverable | Kind |
|---|---|---|
| 1 | `JidoClaw.Cluster.Leader` — `:pg` leader-election GenServer (`leader?/0`, pure `elect/1`, telemetry) | new module |
| 2 | `JidoClaw.Cluster` — add `monitor_group/1` + `leader?/0` façade (with module-swap test seam) | edit |
| 3 | Supervision — `:rest_for_one` sub-supervisor wrapping `:pg` + `Cluster.Leader` in `cluster_children/0` | edit |
| 4 | Cron fire-gate — gate **`:system_job`** ticks on the leader (`Cron.Worker`) | edit |
| 5 | Sweeper/backfill leader-gates — `Trace.RetentionSweeper`, `RequestCorrelation.Sweeper`, `VFS.PrototypeRetentionSweeper`, `Embeddings.BackfillWorker` (scan loop) | edits |
| 6 | Singleton audit — verify every `core_children` classification; update the WS-4 doc table | doc |
| 7 | `WS4a-clustered-cron-ownership.md` — separate design doc for the pre-existing user-cron gap | new doc |
| 8 | `.reach.exs` — add `Cluster.Leader` to the `behaviour_candidate` ignore list if it trips | edit (if needed) |
| 9 | Tests — leader (pure + simulated `:pg`), cron `:system_job` gate, 4 sweeper/backfill gates | new tests |

---

## Design

### 1. Leader election — `JidoClaw.Cluster.Leader` (new) + `JidoClaw.Cluster` façade

**Algorithm: lowest node-name wins.** Deterministic and stateless — every node
computes the same leader from the same `:pg` membership via `Enum.min/1`, no consensus
protocol needed. Re-election is automatic: when the lowest node leaves the group, the
next-lowest becomes leader on the next membership message. (First-joiner was the
alternative; rejected — it needs durable join-order state for no real benefit here.)

**Why `:pg`, not a held advisory lock** (per `WS4-...md:13-21`, `REACTOR-ADOPTION.md:681-684`):
gust's `pg_try_advisory_lock` + `Process.sleep(:infinity)` leader stalls *all*
leader-only work globally if the leader's TCP survives but the node is unreachable
(`gust/…:144`). `:pg` membership has no such partition-stall. Reuse the existing
`:pg` scope `:jido_claw` via the `JidoClaw.Cluster` wrapper (`core/cluster.ex:8,53-83`).

**New module `lib/jido_claw/core/cluster/leader.ex`** — modeled on
`Orchestration.ReclaimPooler` (`reclaim_pooler.ex`: `use GenServer`, `name: __MODULE__`,
config-accessor style, inline telemetry, big moduledoc):

- **State is a small struct** — `defstruct [:ref, :self_node, :leader, :members, :members_fun]`
  with a `@type t` (like `Cron.Worker`'s state struct, `worker.ex:44-88`), so specs and tests
  stay tight and `recompute/2` reads/writes named fields, not an open map.
- **Pure, directly-testable core (no production backdoor):**
  - `elect/1` — `elect([]) -> nil`; `elect(nodes) -> Enum.min(nodes)`.
  - `recompute(%__MODULE__{} = state, members) :: {%__MODULE__{}, changed? :: boolean()}` —
    the membership reducer: sets `state.members` / `state.leader = elect(members)` and reports
    whether the leader changed. `handle_info`/`init` call `recompute(state, members_fun.())`;
    tests call `elect/1` and `recompute/2` directly with **synthetic node-name lists** — a
    single BEAM can't make `node(pid)` return a remote name, so node-name-list pure fns (not
    a `{:simulate}` `handle_call` into the live process) are how multi-node selection is tested.
- **`init/1`**: defensive `:ignore` if `cluster_enabled` is false (the `ReclaimPooler`
  `:ignore` idiom, `reclaim_pooler.ex:59-67`). Else: `Cluster.join(@group)`,
  `{ref, _} = Cluster.monitor_group(@group)`, `self_node = Cluster.local_node()`,
  `{state, _} = recompute(%__MODULE__{ref: ref, self_node: self_node, members_fun: members_fun}, members_fun.())`.
  The `:members_fun` opt (default `&pg_member_nodes/0`) is the **clean DI seam**: a test
  starts the Leader with a fun returning controlled node lists, then drives `handle_info` to
  exercise recompute + emit — no prod-only `handle_call` clause.
- **`handle_info({ref, action, _group, _pids}, %{ref: ref} = state) when action in [:join, :leave]`**:
  `{state, changed?} = recompute(state, state.members_fun.())`; if `changed?`, log +
  `emit_leader_changed/2`; `{:noreply, state}`. (Same-variable `ref` in head + state
  enforces the monitor-ref match.) `:pg.monitor/2` delivers `{Ref, join|leave, Group, [pid]}`
  on OTP 25+ (OTP 29 confirmed, `[[project_toolchain_mise_latest]]`).
- **`handle_call(:leader?, _, s)`** → `{:reply, s.leader == s.self_node, s}`;
  **`handle_call(:leader, _, s)`** → `{:reply, s.leader, s}` (dashboard/debug).
- **`leader?/0`** (real impl: single-node fast path + bounded call):
  ```
  @leader_call_timeout 1_000

  def leader? do
    if cluster_enabled?() do
      case GenServer.whereis(__MODULE__) do
        nil  -> false                              # not up yet / crashed → fail CLOSED
        _pid -> safe_call(:leader?, false)
      end
    else
      true                                         # single node ⇒ trivially the leader
    end
  end

  defp safe_call(msg, default) do
    GenServer.call(__MODULE__, msg, @leader_call_timeout)
  catch
    :exit, _ -> default                            # timeout / no-proc → fail closed
  end
  ```
  Explicit **1s** timeout (not GenServer's 5s default) — `leader?/0` rides cron/sweeper
  ticks, so a wedged leader must fail closed fast, never block a tick. Fail-closed is safe
  for every caller (a skipped tick re-arms). Single-node never touches `:pg`/a process.
- `pg_member_nodes/0` (the default `members_fun`) = `Cluster.members(@group) |> Enum.map(&node/1) |> Enum.uniq()`.
- Telemetry: `[:jido_claw, :cluster, :leader_changed]`, `%{count: 1}`,
  `%{leader:, previous:, members:}` — inline, matching `ReclaimPooler.emit_reclaimed/1`
  (`reclaim_pooler.ex:123-134`). Logger prefix `"[Cluster.Leader] …"`.

**Edit `lib/jido_claw/core/cluster.ex`** — two additions next to the existing `:pg`
wrappers (`cluster.ex:53-83`):
- `monitor_group/1` → `:pg.monitor(@pg_scope, group)` (`@spec monitor_group(term()) :: {reference(), [pid()]}`).
- **`leader?/0` façade** — the public "am I the leader?" API every gated singleton
  calls: `def leader?, do: leader_module().leader?()` where
  `defp leader_module, do: Application.get_env(:jido_claw, :cluster_leader_module, JidoClaw.Cluster.Leader)`.
  One seam, one API: tests stub leadership with a single
  `Application.put_env(:jido_claw, :cluster_leader_module, StubLeader)`. The single-node
  fast path lives in `Cluster.Leader.leader?/0` (the real impl), so a stub fully
  controls test behavior.

**Config:** none required — election is parameter-free and the Leader has no tunables.
No `config/*.exs` changes. (The `cluster_leader_module` seam defaults in code; tests set
it via `put_env`.)

### 2. Supervision wiring — `application.ex`

`:pg` and the leader must restart **together**: the root supervisor is `:one_for_one`
(`application.ex:70`), so a sibling `Cluster.Leader` after the `:pg` child would keep a
**stale monitor ref + membership** if the `:pg` scope process crashed and restarted (it
would not rejoin/re-monitor). Wrap both in a small **`:rest_for_one`** sub-supervisor in
`cluster_children/0` (`application.ex:433-452`) via the existing `supervisor_child/3`
helper (`application.ex:337-343`):

```elixir
topologies = JidoClaw.Cluster.topology()

[
  supervisor_child(
    JidoClaw.Cluster.LeadershipSupervisor,
    [
      %{id: :pg_jido_claw, start: {:pg, :start_link, [:jido_claw]}},
      JidoClaw.Cluster.Leader
    ],
    :rest_for_one
  ),
  {Cluster.Supervisor, [topologies, [name: JidoClaw.ClusterSupervisor]]}
]
```

`:rest_for_one` semantics: a `:pg` crash restarts `:pg` **and** `Leader` in order (Leader
re-inits → fresh join + monitor); a `Leader` crash restarts only `Leader` (re-joins +
re-monitors). libcluster's `Cluster.Supervisor` stays an independent sibling (it manages
Node connections, not the `:pg` scope), and the scope is still registered globally as
`:jido_claw` regardless of which supervisor starts it.

Single-node (`cluster_enabled: false`): `cluster_children/0` returns `[]`, so neither the
scope nor the Leader starts and `Cluster.leader?()` returns `true` via the fast path — the
load-bearing reason single-node stays byte-identical. The gated singletons live in
`core_children` (start *before* `cluster_children`); fine, because `leader?()` is consulted
at *tick time* (well after boot) and fails closed during the boot window.

### 3. Cron `:system_job` fire-gate — `Cron.Worker`

Gate the **matching-tick clause** (`worker.ex:159`) — the single dispatch point, before
`execute_job/2` emits start telemetry:

```elixir
def handle_info({:tick, window}, %{status: :active, next_run: window} = state) do
  if leader_gated?(state) and not JidoClaw.Cluster.leader?() do
    {:noreply, schedule_next(state)}            # off-leader replicated tick: re-arm, don't fire
  else
    state = execute_job(state, {:scheduled, window})
    {:noreply, after_fire(state)}               # unchanged path
  end
end

defp leader_gated?(%{mode: :system_job}), do: true
defp leader_gated?(_), do: false
```

- **Scoped to `:system_job`** (the only replicated jobs): user `:agent`/`:workflow`/`:mfa`
  jobs short-circuit `leader_gated?/1` → fire as today (no leader call, no regression).
- Swallow path re-arms via `schedule_next/1` (the existing re-arm helper), so when
  leadership moves the new leader's worker fires on the next cron boundary —
  **no leadership listener needed; failover is automatic**.
- Manual `trigger/2` (`worker.ex:138`) is **never** gated (operator override).
- Single-node: `leader?()` → `true` → else branch → byte-identical.
- **Defense-in-depth / standing invariant:** the leader gate is *first-line*, not a
  guarantee — the brief two-leaders window during `:pg` convergence can fire a `:system_job`
  on two nodes. So **every system cron job must stay idempotent / row-claimed / DB-leased**;
  the consolidator's `pg_try_advisory_lock` (`Memory.Consolidator.LockOwner`, `lock_owner.ex`)
  is the model, and `:workflow` ticks also carry the `cron:<job>:<window>` idempotency key
  (`workflow_runner.ex:131-136`). Record this invariant where system jobs are registered
  (`Cron.Scheduler.start_system_jobs/0`).
- **Recurring-only caveat:** the off-leader swallow re-arms via `schedule_next/1`, which is
  correct for `:cron`/`:every`. Every `:system_job` today is recurring (`:cron`). A future
  **one-shot** (`{:at, _}`) system job would hit `schedule_next/1`'s elapsed-`:at` →
  *disable* path on a follower (`worker.ex:269`) — wrong (a follower must not disable a
  one-shot it never ran). Introducing a one-shot system job would require the swallow path
  to re-arm a bounded re-check instead of disabling. Out of scope now (no such job exists);
  recorded so the pattern isn't assumed safe for one-shots.

### 4. Sweeper / backfill leader-gates

**Principle: gate *periodic* work; never gate *manual/forced* paths** (mirrors cron's
ungated `trigger/2`). At the top of each periodic `handle_info`, `if JidoClaw.Cluster.leader?()`
do the existing work; else skip and re-arm the normal next tick. Single-node →
`leader?()` true → byte-identical. Files + anchors:

- `lib/jido_claw/trace/retention_sweeper.ex` — gate `handle_info(:sweep, …)` (hourly).
- `lib/jido_claw/conversations/request_correlation/sweeper.ex` — gate `handle_info(:sweep, …)` (60s).
- `lib/jido_claw/vfs/prototype_retention_sweeper.ex` — gate its periodic sweep tick.
- `lib/jido_claw/embeddings/backfill_worker.ex` — gate **only the periodic
  `handle_info(:scan, …)`** (`backfill_worker.ex:115-118`). **Leave `handle_cast(:tick)`
  ungated** — `tick/0` (`backfill_worker.ex:88`) is a manual force-scan/test seam that
  existing tests drive (`backfill_worker_test.exs:173`); treat it like cron's `trigger/2`
  (operator/test intent always runs), so gating it would force a rewrite of those tests for
  no benefit. **Also leave the PubSub hint-path** (`{:hint_pending, id}` → `claim_by_id`,
  `backfill_worker.ex:120`) active: it's targeted + `FOR UPDATE SKIP LOCKED`-safe, and the
  audit's intent is to cut redundant *polling* (`WS4-...md:36`) — the scan. The leader's
  scan still sweeps rows a follower would have hint-claimed.

The leader check wraps the *work*, not the scheduling: a **follower** re-arms the normal
next tick and does nothing else; the **leader** runs the existing path unchanged, including
the full-batch immediate-drain / re-sweep behavior each sweeper already has.

### 5. Singleton audit (verify + doc)

The classification is confirmed against the code (the three exploration passes did the
legwork). Net result: **the lease (shipped) was the only correctness-critical gap; every
remaining singleton is already safe.** Update the audit table in
`docs/plans/clustering/WS4-leader-election-and-singletons.md` with:
- Verified `application.ex` line anchors (the tree grew: `core_children` spans ~136-320;
  `cluster_children/0` 432-452; `owns_recovery?/0` now at `workflow_recovery.ex:627-631`).
- The two corrections from Context (consolidator scheduler tick = a `:system_job`, so
  covered by the cron gate; the only cron replicated by the *always-on tree* is the
  consolidator — user jobs replicate only across CLI nodes, the WS4a gap).
- Mark which singletons WS-4 leader-gates (cron `:system_job`, the 3 sweepers, backfill
  scan) vs. leaves per-node-by-design (`RatePacer`, `AgentTracker`/`Stats`/`Display`/
  `Network.Supervisor`, trace `Collector`/`Recorder`/`Persistence`, `MCPServer`/`Endpoint`).
- A note that a brief two-leaders window during `:pg` convergence is harmless because
  every gated unit is independently idempotent/locked.

The audit's *machine-checked* assertion is the cron `:system_job` regression test (§Test
plan) — the genuine needs-gating item — not a brittle "assert every classification"
meta-test.

### 6. Separate design doc — `WS4a-clustered-cron-ownership.md`

Authored as deliverable #7 (the unit too large for WS-4, per "no deferrals → its own
doc"). Captures the **pre-existing** gap WS-4 deliberately does not touch: user cron is
node-local and only CLI-loaded, so under clustering it neither multi-fires (WS-4's
concern) nor runs exactly-once cluster-wide. Outline (its own phases):
- **Problem (two faces):** (a) persisted user jobs are loaded by **each CLI REPL**
  (`repl.ex:315`), so multiple clustered CLI nodes load + fire the *same* job — multi-fire,
  safe today only for `:workflow` targets via the `cron:<job>:<window>` key; (b)
  gateway-only clustered nodes load **no** user cron at all, and ad-hoc `schedule/2`
  workers are node-local — so a job's firing depends on which node holds its worker.
- **Target:** the leader owns *all* persisted cron jobs cluster-wide; followers run none;
  the DB `cron_jobs` row is the source of truth; failover reloads on the new leader.
- **Phases:** (P1) load-all-persisted-jobs-on-leader + a leadership-change listener
  (start on gain / stop on loss); (P2) ad-hoc scheduling on a follower persists to DB and
  hands ownership to the leader; (P3) tests incl. WS6 `:peer` failover.
- **Reuse:** `Cron.Scheduler`, `Cron.Job.for_tenant`, the WS-4 leader's `leader?/0` +
  `leader_changed` telemetry as the failover trigger.

### 7. `.reach.exs` (if needed)

A new plain GenServer with `init/1`/`handle_info/2`/`handle_call/3` may trip the
`behaviour_candidate` smell (the sweepers are already on that ignore list,
`.reach.exs:128-133`). If `mix reach.check --smells --strict` flags `Cluster.Leader`,
add it to that list with a one-line justification. (The cron/sweeper edits don't change
their existing smell status.)

---

## Files to create / modify

**Create**
- `lib/jido_claw/core/cluster/leader.ex` — the election GenServer.
- `docs/plans/clustering/WS4a-clustered-cron-ownership.md` — separate design doc.
- `test/jido_claw/core/cluster/leader_test.exs`
- `test/jido_claw/platform/cron/worker_leader_gate_test.exs` (or extend the existing cron worker test)
- `test/jido_claw/cluster/singleton_gate_test.exs` — the sweeper/backfill gate tests (or co-locate per module)

**Modify**
- `lib/jido_claw/core/cluster.ex` — `monitor_group/1` + `leader?/0` façade.
- `lib/jido_claw/application.ex` — `:rest_for_one` `LeadershipSupervisor` (`:pg` + `Cluster.Leader`) in `cluster_children/0` (`:445-448`).
- `lib/jido_claw/platform/cron/worker.ex` — `:system_job` fire-gate (~`:159`).
- `lib/jido_claw/trace/retention_sweeper.ex`, `.../conversations/request_correlation/sweeper.ex`,
  `.../vfs/prototype_retention_sweeper.ex`, `.../embeddings/backfill_worker.ex` — tick gates.
- `docs/plans/clustering/WS4-leader-election-and-singletons.md` — verified audit table.
- `.reach.exs` — `behaviour_candidate` entry for `Cluster.Leader` (only if it trips).

---

## Test plan (simulated single-BEAM; real `:peer` is WS6)

Real cross-BEAM election is **WS6's** deliverable (its test plan already lists WS4 leader
election); WS-4 tests its own logic single-BEAM, matching how WS1/WS3 shipped. All files
`async: false` (they toggle global `cluster_enabled` / `cluster_leader_module` app-env;
restore in `on_exit`). `[[project_suite_flaky_tests]]`: verify these in **isolation**,
not under `--seed 0`.

**`leader_test.exs`**
- `elect/1` pure: `[:c@h,:a@h,:b@h] → :a@h`; `[:only@h] → :only@h`; `[] → nil`.
- `leader?/0` single-node: `cluster_enabled: false` (default), no process → `true`.
- `leader?/0` clustered, process absent: `cluster_enabled: true`, Leader not started →
  `false` (fail-closed).
- Pure selection/reducer (synthetic node names, no live process): `elect([:c@h,:a@h,:b@h]) == :a@h`;
  `recompute/2` from `[:a@h, :b@h]` (self `:b@h`, leader `:a@h`) then `[:b@h]` flips `:b@h`
  to leader and returns `changed? == true`; a membership change that doesn't move the leader
  returns `changed? == false`.
- Emit-on-change via the `:members_fun` DI seam: start the Leader with a fun returning a
  controlled node list, drive a real `:pg`-shaped `handle_info` join/leave that flips
  leadership, and assert `[:jido_claw, :cluster, :leader_changed]` fires once (attached
  telemetry handler) — and does **not** fire when membership changes without flipping the
  leader.
- `:pg` wiring: start `:pg.start_link(:jido_claw)` in `setup` (handle
  `{:error, {:already_started, pid}}`, teardown in `on_exit`) — the `clustering_test.exs`
  idiom — start the Leader (default `members_fun`), assert it joins `@group` and survives a
  real join/leave (single-BEAM ⇒ leader resolves to the local node; cross-node distinction
  is WS6).
- Restart coupling (P1b): under a `:rest_for_one` test supervisor over `[:pg, Leader]`,
  killing the `:pg` scope process restarts both in order and the Leader re-joins `@group` +
  re-monitors (assert leadership still resolvable / no stale ref); killing only the Leader
  restarts just the Leader.

**`worker_leader_gate_test.exs`** (stub leadership via
`Application.put_env(:jido_claw, :cluster_leader_module, StubLeader)`; use
`mfa: {TestSink, :ping, [self()]}` to observe firing):
- `:system_job` scheduled tick, stub `leader? → false`: **no** `:ping`; `next_run`
  advanced (re-armed).
- `:system_job` scheduled tick, stub `leader? → true`: `:ping` received.
- Manual `trigger/2` of a `:system_job`, stub `leader? → false`: `:ping` received
  (operator override).
- User job (`mode: :main`, `target: :agent`/`:workflow`), stub `leader? → false`: fires
  (not gated) — single-node identity preserved.

**`singleton_gate_test.exs`** — per gated sweeper/backfill, stub `leader? → false` ⇒
the sweep/scan does no DB work + re-arms; `leader? → true` ⇒ it runs. (DB-touching cases
`use JidoClaw.TenantCase` for shared-sandbox visibility, `async: false`.)

---

## Definition of done — `mix precommit` (run via `mise exec -- mix`)

The plan is complete only when the **8-step** gate is green
(`mix.exs:251-260`). Run gates **bare in the background** and read the output tail — never
pipe to `tail` (`[[feedback_no_pipe_on_gate_commands]]`):

1. `jidoclaw.compile_check` — **zero warnings** (allowlist is empty by design). New module
   fully `@spec`'d, no unused vars/aliases, `@impl GenServer` (not `@impl true` — credo
   `ImplTrue`).
2. `jidoclaw.system_prompt.check` — untouched (no new tool/skill).
3. `deps.unlock --unused` — no dep changes.
4. `format --check-formatted` — `mix format` the new/edited files.
5. `reach.check --arch --smells --strict` — add the `behaviour_candidate` entry for
   `Cluster.Leader` if it trips; new test/support stubs must not trip smells
   (`[[project_precommit_newcode_gotchas]]`).
6. `credo --strict` — `@spec`s, `AliasUsage`, `ImplTrue`. No new Ash resource, so no
   `LargeResource`/AshCredo visibility issues (`[[project_ashcredo_visibility]]`).
7. `dialyzer --format short` — valid spec types (`node()`, `boolean()`,
   `{reference(), [pid()]}`); the `GenServer.call` catch is dialyzer-clean.
8. `test` — new tests pass; existing cron/app-boot/clustering tests unaffected (single-node
   `leader?()` → true keeps them byte-identical; Leader only starts when clustered).

**Manual smoke (optional, via Tidewave `project_eval`):** with `cluster_enabled: false`,
`JidoClaw.Cluster.leader?()` returns `true` and the consolidator/sweepers behave exactly
as before; `JidoClaw.Cluster.Leader.elect([:b@x, :a@x])` returns `:a@x`.

---

## Out of scope (recorded)

- **Clustered *user*-cron ownership** → `WS4a` (deliverable #7), not WS-4.
- **Real cross-BEAM `:peer` tests** → WS6 (owns the multi-node harness; its plan lists
  WS4 leader election).
- **Work-stealing / graceful-drain between live nodes** → README non-goal; a draining
  node's runs are recovered by WS3's lease-expiry path.
- **Per-tool MCP approval, etc.** — unrelated.
