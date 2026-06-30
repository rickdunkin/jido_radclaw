# WS4a — Clustered user-cron ownership (implementation plan)

## Context

WS4 (shipped) made the *always-on-tree* cron case cluster-safe: the memory-consolidator
`:system_job` tick is leader-gated, so it fires exactly once cluster-wide. WS4a closes the
orthogonal gap WS4 left untouched — **persisted *user* cron jobs** (`mode: :main |
:isolated`, `target: :agent | :workflow | :mfa`), which today have **no single owner under
clustering**:

- **Multi-fire across CLI nodes.** User cron is loaded only by the CLI REPL boot
  (`repl.ex` `load_cron_jobs/1`, tenant `"default"` hardcoded). Two clustered CLI nodes each
  boot a `Cron.Worker` for the same job → both fire it. Safe *today only* for `target:
  :workflow` (the `cron:<job>:<window>` idempotency key dedupes the launch); an `:agent`/`:mfa`
  job multi-fires the turn/MFA once per node.
- **No-fire on gateway-only nodes / stranded ad-hoc jobs.** A `:gateway`/`:both` node runs no
  REPL, so it loads no user cron. Ad-hoc jobs created at runtime by `schedule_task`
  (`Cron.Scheduler.schedule/2`) live only in the node-local `TenantRegistry` of whichever node
  ran the agent turn — no cluster-wide exactly-once (or even at-least-once).

**Target:** the **leader owns all persisted cron jobs cluster-wide** — it loads/schedules
every non-disabled `cron_jobs` row for every active tenant; **followers schedule none**. The
`cron_jobs` row is the **source of truth for scheduling**, not just persistence. Leadership
change reloads on the new leader (off WS4's `leader_changed` signal — no second election).
**Single-node keeps the same ownership/firing semantics** as today (the lone node is trivially
`leader?/0 == true`, loading + owning everything as the REPL does) — *except* the two documented
improvements: re-using a `job_id` now **updates** the job (the worker is restarted to match, and a
previously-disabled job is re-enabled), and list views read **persisted rows** (see design notes).

This plan delivers all three doc phases (P1+P2+P3) in one workstream. The only piece too
large for WS4a — the cross-BEAM `:peer` failover proof — stays in **WS6** (the harness owner),
consistent with how WS1/WS3/WS4 all shipped single-BEAM; WS4a adds the corresponding row to
WS6's test plan.

> **v2** — revised after review. Six findings folded in: config-fingerprint reconcile (no
> stale workers), `Cluster.leader/0` facade + stub, list-views read persisted rows, a
> `:cron_owner` test gate, all-status tenant enumeration, and `/cron disable` routing. See the
> per-section ⮕ notes.

---

## Design decisions (resolved)

1. **Hybrid reconcile, not event-only.** A supervised `JidoClaw.Cron.Owner` GenServer
   converges running user-cron workers to the desired DB state via an idempotent `reconcile/0`
   driven by **three** triggers: **boot** (`handle_continue`), **`[:jido_claw, :cluster,
   :leader_changed]` telemetry** (prompt failover — WS4a is the *first* subscriber), and a
   **periodic tick** (~30 s, configurable) that is **load-bearing, not insurance**. The tick is
   required by a real **boot race**: the root supervisor is `:one_for_one` and
   `cluster_children()` (the `Leader`) starts *after* `core_children()` (where the Owner lives),
   so the Owner's boot reconcile on a clustered node sees `leader?/0` fail closed to `false`
   (Leader not up) — and `leader_changed` **never fires for the initial election**
   (`leader.ex` discards the seeding `recompute`'s `changed?`). Without the periodic re-check, a
   leader that boots first would never load. (Single-node has no race: `leader?/0` is `true`
   with no process.) Polling also matches the codebase idiom — every other leadership consumer
   polls `leader?/0`.

2. **Owner excludes `:mcp` serve mode and is test-gated.** ⮕ *Finding 4.* The Owner self-gates
   to `:ignore` when serve mode is `:mcp` (mirrors `WorkflowRecovery`) **or** when
   `config :jido_claw, :cron_owner, enabled?: false`. `config/test.exs` sets `enabled?: false`
   (mirroring `reclaim_pooler`/`workflow_recovery`/MCP-consumer), so the boot singleton can't
   collide with `start_supervised`-started Owners in tests or touch the SQL sandbox outside the
   test owner. A pure `start?/2` predicate (serve_mode, enabled?) keeps the gate testable.

3. **Cross-tenant enumeration over the authoritative resource — all statuses.** ⮕ *Finding 5.*
   `Cron.Job` is `global?(false)` with no cross-tenant list, so the Owner enumerates tenants via
   **`JidoClaw.Tenants.Tenant.list/0`** (untenanted, `authorize always`) and **rejects only the
   reserved `"system"` tenant** (its sole job is the WS4-managed consolidator, not even persisted
   to `cron_jobs`). It enumerates **every** non-system tenant **regardless of status**; the
   *desired* set is empty for any tenant that is not `:active`, so a tenant suspended *after* it
   had running cron still gets its local workers **pruned** (active-only enumeration would strand
   them). `Tenant.Manager.ensure_tenant/2` is called only for tenants with ≥1 desired job, so
   dormant tenants get no instance forced. **The Owner manages *user jobs only*: it filters
   `mode == :system_job` from *both* the desired set (`for_tenant` permits the mode) and the
   running set**, so a persisted `:system_job` row mistakenly written under a non-`"system"`
   tenant is unsupported and skipped — system jobs are owned by the always-on tree + WS4's worker
   gate, never the Owner. (Symmetric filtering avoids the otherwise-reschedule-every-tick churn a
   one-sided filter would cause.)

   ⮕ *Finding 2 — one authoritative status source.* WS4a treats the **Postgres
   `Tenants.Tenant` row** as the single source of truth for tenant lifecycle/status (it's already
   the FK source of truth, and `tenants/domain.ex` documents Postgres as authoritative). The ETS
   `Tenant.Manager` status is a node-local cache the Owner does **not** consult. Note
   `Tenant.Manager.suspend_tenant/1`/`resume_tenant/1` update only the ETS struct
   (`manager.ex:156–159`), not the row — but they have **zero callers in lib/test today**, so
   there is no reachable divergence. Recorded one-line follow-up: *if* either is ever wired to a
   real operator path, it must also persist `Tenants.Tenant.status` (e.g. via `Tenants.Tenant`'s
   suspend/resume actions) so the Owner observes it. Not needed for WS4a.

4. **Config-fingerprint reconcile — the worker always matches the row.** ⮕ *Finding 1.* Making
   the DB authoritative means a row edit must restart a stale worker. Reconcile compares each
   desired job's **config fingerprint** — `{schedule(=hydrate(kind,value)), task, mode, target,
   workflow_name, workflow_input, mfa, timezone}` (the `Cron.Worker` struct's config fields,
   excluding runtime `status`/`failure_count`/`next_run`/`last_run`/`last_result`) — against the
   running worker's state. **Unchanged ⇒ leave** (idempotent — no churn on the 30 s tick);
   **changed ⇒ unschedule + reschedule**; **missing ⇒ schedule**; **absent from desired ⇒
   prune**; **unbuildable desired config ⇒ keep the running worker** (the fingerprint returns
   `{:error, _}`, so we never `unschedule` before a reschedule that would fail). This
   subsumes the old "`already_started` ⇒ success" hack and makes re-`upsert`ing an
   existing `job_id` a **working update** — including re-enabling a job that had auto-disabled,
   since `:upsert` now clears `disabled_at` (today the tool errors on a duplicate id because
   `schedule/2` runs before `Job.upsert`). That behavior change is intentional and strictly more
   intuitive given the source-of-truth model.

5. **One ownership-notify path; followers never run user workers.** ⮕ *Findings 3, 6.* The
   write tools/commands become **DB-write-then-`notify_changed`**: mutate the `cron_jobs` row
   (`upsert`/`remove`/`disable`), then `Cron.Owner.notify_changed(tenant_id)`. On the leader
   (incl. single-node) this *synchronously* reconciles that tenant; on a follower it casts
   `{:reconcile_tenant, tenant_id}` to the leader node and starts **no** local worker. Because
   followers hold no user workers, **list views must read persisted rows, not local workers** —
   otherwise a follower `schedule_task` then immediately reports "no tasks." The periodic
   reconcile is the lost-cast backstop.

---

## Phase 1 — Leader owns persisted jobs + leadership listener

### New file: `lib/jido_claw/platform/cron/owner.ex` — `JidoClaw.Cron.Owner`

Permanent GenServer (registered `JidoClaw.Cron.Owner`; cross-node addressable as
`{JidoClaw.Cron.Owner, node}`).

**Public API** (each with `@spec`): `start_link/1`; `reconcile/0` (synchronous
`GenServer.call`, returns `:ok` — tests assert post-state deterministically);
`notify_changed/1` and `trigger/2` (Phase 2).

**Callbacks** (`@impl` per `leader.ex`'s convention):
- `init/1` — `:ignore` when `start?/2` is false (`:mcp` mode or `:cron_owner enabled?: false`);
  else **detach-then-attach** the `leader_changed` telemetry handler under a stable id
  (`"jido-claw-cron-owner"`) using a named module fn `&__MODULE__.handle_leader_changed/4` (not
  an anon fn — avoids telemetry's local-handler warning; detach-first tolerates a restart that
  skipped `terminate/2`); `{:ok, state, {:continue, :boot}}`.
- `handle_continue(:boot, …)` — first `reconcile`, then arm the periodic timer.
- `handle_info(:reconcile_tick, …)` — `reconcile`; re-arm.
- `handle_cast(:reconcile, …)` — from the telemetry handler (any leader change → reconcile).
- `handle_call({:reconcile_tenant, t}, …)` — Phase-2 **leader-local** sync per-tenant reconcile
  (what `notify_changed/1` calls on the leader); replies `:ok`. ⮕ *Finding 2*
- `handle_cast({:reconcile_tenant, t}, …)` — Phase-2 **remote** path (follower→leader cast);
  guarded by `if Cluster.leader?()` (ignore if leadership moved since the cast was sent).
- `handle_call({:trigger, t, id}, …)` — Phase-2 manual trigger, **leader-side only**; runs
  **`reconcile_tenant(t)` first, and triggers only if it returned `:ok`** — on `{:error,
  :desired_unknown}` it replies that error and **does NOT fire** (⮕ *Finding P2 — fail closed*).
  Reconciling before *every* trigger makes the result **deterministic across the disable→prune
  window**: when desired state is known, the worker set exactly matches the enabled set, so an
  enabled job — even one just persisted, or post-failover — fires, while a disabled/absent job
  returns `{:error, :not_found}`; when the desired-state read *failed* we refuse to fire a possibly-
  stale (disabled/removed) worker rather than violate the "enabled jobs only" rule. Reached by a
  **bounded `GenServer.call`** from `trigger/2` (local on the leader, or to `{__MODULE__,
  leader_node}` from a follower) — a `call`, **not** a cast, since trigger has no reconcile backstop
  of its own.
- `handle_call(:reconcile, …)` — sync full reconcile (tests/callers).
- `terminate/2` — detach the handler.
- `handle_leader_changed/4` — telemetry callback; `GenServer.cast(__MODULE__, :reconcile)`.

**Reconcile core** (best-effort: try/rescue + `Logger`, never crash the Owner — matches
`load_persistent_jobs/2`'s log-and-continue idiom). ⮕ *Finding 1:* both reads return
`{:ok,_}|{:error,_}`; **a read error SKIPS (leaves workers running) — only an *intentional*
empty desired set (follower/inactive) prunes.** `converge/2` is therefore only ever called with a
*known* desired set:
```
reconcile():                                     # full sweep: boot / periodic tick / leader_changed
  if not Cluster.leader?() do
    drop_local_user_workers()                    # ⮕ #P1 follower: LOCAL-only prune — NO Postgres dependency,
                                                 #   so a DEMOTED leader sheds its workers even if tenant listing fails
  else
    case Tenants.Tenant.list() do                # leader enumerates loaded rows
      {:error, reason} -> log(reason)            # can't enumerate → DO NOTHING (unknown desired ≠ empty; never prune)
      {:ok, tenants}   ->
        tenants |> Enum.reject(& &1.id == "system") |> Enum.each(&reconcile_row/1)
    end
  end

# Per-tenant entry — used by notify_changed/1 and trigger/2, which carry only a tenant_id STRING.
# ⮕ *Finding P3:* fetch the row first; a tenant-read error is also `:desired_unknown` so trigger
# fails closed (never treat an unknown/inactive tenant as active).
reconcile_tenant(tenant_id):                     # returns :ok | {:error, :desired_unknown}
  if tenant_id == "system", do: (return :ok)     # never Owner-managed
  case Tenants.Tenant.by_id(tenant_id) do        # tenant.ex:53 code_interface
    {:error, _} -> {:error, :desired_unknown}    # tenant row unreadable → fail closed
    {:ok, row}  -> reconcile_row(row)
  end

reconcile_row(row):                              # LEADER-only; returns :ok | {:error, :desired_unknown}
  if row.status != :active do
    converge(row.id, []); :ok                    # inactive tenant: intentional empty → prune all
  else
    case Job.for_tenant(tenant: row.id, actor: Actor.system(row.id)) do   # non-disabled rows
      {:ok, jobs}      -> converge(row.id, Enum.reject(jobs, & &1.mode == :system_job)); :ok  # user jobs only
      {:error, reason} -> log(reason); {:error, :desired_unknown}   # job read failed → leave workers; UNKNOWN
    end
  end
# The periodic/notify loop ignores these returns (best-effort); only Owner.trigger/2 consumes
# `reconcile_tenant/1`'s (⮕ Finding P2) — it must NOT fire when desired state could not be confirmed.

drop_local_user_workers():                       # ⮕ #P1 — local runtime state only (no DB)
  Scheduler.local_user_cron_workers()            # scan TenantRegistry for {:cron, t, id}; reject tenant "system"
  |> Enum.each(fn {t, id} -> Scheduler.unschedule(t, id) end)

converge(t, desired_jobs):
  running = Scheduler.list_jobs(t) |> Enum.reject(& &1.mode == :system_job)   # defensive
  if desired_jobs != [], do: Tenant.Manager.ensure_tenant(t)                  # only when scheduling
  # add or restart-on-change
  Enum.each(desired_jobs, fn job ->
    case Enum.find(running, & &1.id == job.job_id) do
      nil -> Scheduler.schedule_persisted(t, job)          # missing → start (logs+skips if unbuildable)
      ws  -> case Scheduler.changed?(job, ws) do
               {:ok, true}      -> Scheduler.unschedule(t, job.job_id); Scheduler.schedule_persisted(t, job)
               {:ok, false}     -> :ok                     # unchanged → idempotent
               {:error, reason} -> log(reason)             # ⮕ #1 row now invalid → KEEP the working worker
             end
    end
  end)
  # prune: running ∉ desired  (handles removed, disabled, follower-drop, inactive-tenant)
  desired_ids = MapSet.new(desired_jobs, & &1.job_id)
  Enum.each(running, fn ws ->
    unless MapSet.member?(desired_ids, ws.id), do: Scheduler.unschedule(t, ws.id)
  end)
```
The follower path does **not** go through `converge`/Postgres at all — `drop_local_user_workers/0`
prunes every locally-running user worker straight from `TenantRegistry` (⮕ #P1), so a node that
loses leadership sheds its workers even when the DB is unreachable.

### `lib/jido_claw/platform/cron/scheduler.ex` — additions ⮕ *Finding 1*
- `schedule_persisted/2 :: (String.t(), %Job{}) -> :ok | {:error, term()}` — public per-job form
  of `try_schedule_job/2` (reuses `build_persistent_opts/1`). Idempotent: treats `{:error,
  {:already_started, _}}` from `schedule/2` as `:ok` (a benign race with a concurrent reconcile;
  the fingerprint pass owns *changes*).
- `desired_fingerprint/1 :: %Job{} -> {:ok, term()} | {:error, reason}` — wraps
  `build_persistent_opts/1` and projects the config fields (above) into a comparable term.
  Returns `{:error, _}` for an **unbuildable** row (e.g. `:workflow` with nil `workflow_name`,
  `:mfa`/`:system_job` with a missing/unknown module — `scheduler.ex:64,94`).
- `changed?/2 :: (%Job{}, %Cron.Worker{}) -> {:ok, boolean()} | {:error, reason}` — compares
  `desired_fingerprint(job)` against the worker's projected state. ⮕ *Finding 1:* propagating
  the `{:error, _}` lets `converge/2` **leave the running worker alone** rather than `unschedule`
  it before a reschedule that would fail (a row edited into an invalid config must not drop a
  working worker). (Keep `try_schedule_job/2`/`load_persistent_jobs/2` for the non-reconcile
  callers; reconcile uses the per-job form so it reads `for_tenant` once and drives add + restart
  + prune from one list.)
- `local_user_cron_workers/0 :: () -> [{tenant_id, job_id}]` — ⮕ *Finding P1.* `Registry.select`
  over `JidoClaw.TenantRegistry` for `{:cron, t, id}` keys, **rejecting tenant `"system"`** (where
  the only `:system_job` worker lives). Pure local runtime state — **no Postgres** — so the
  follower-drop path works even when the DB is unreachable. Backs `drop_local_user_workers/0`.
- `trigger/2` — add a `GenServer.whereis` worker-existence check before the `Worker.trigger/2`
  cast; return `:ok | {:error, :not_found}` (was an unconditional `:ok` — fire-and-forget). Lets
  `Cron.Owner.trigger/2` report an honest result. ⮕ *Finding P1*

### `lib/jido_claw/application.ex` — register the Owner
Add `JidoClaw.Cron.Owner` to `core_children/0` **after** `JidoClaw.TenantRuntimeSupervisor`
(`:252`, so `Tenant.Manager`/`cron_sup` infra exist), co-located with the `SystemJobsInitializer`
/`WorkflowRecovery` boot-reconcilers (`:264`–`:280`). Prefer a pure `cron_owner_children/0` helper
gating on `start?/2` (mirrors `mcp_consumer_children/0`) so the supervision-level gate stays
testable; the Owner's `init/1` self-gate is the belt-and-suspenders.

### `config/test.exs` — disable the boot singleton ⮕ *Finding 4*
Add `config :jido_claw, :cron_owner, enabled?: false` beside the existing `workflow_recovery` /
`reclaim_pooler` test gates. Owner tests start it explicitly via `start_supervised!`.

### `lib/jido_claw/cli/repl.ex` — remove the eager per-REPL load
Delete the `load_cron_jobs(project_dir)` call in `boot_repl_session/5` (`:248`) and the unused
`load_cron_jobs/1` (`:314`). The Owner owns loading. ⮕ *#P2 cold-start:* `Tenant.Manager` creates
the `"default"` Postgres row **asynchronously** (`handle_info(:create_default_tenant)`,
`manager.ex:66`), so the Owner's boot reconcile could race it. To preserve today's synchronous
single-node load (no cold-start gap for the primary tenant), the Owner's boot path calls
**`Tenant.Manager.ensure_tenant("default")`** (which already syncs the Postgres row *and* starts
runtime, `manager.ex:97` — one call, no separate row persist) **before** its first leader reconcile. Tenants whose
rows are created *concurrently* with boot load on the next periodic tick or `notify_changed` — a
bounded, deliberate relaxation of the REPL's eager load, not an unbounded gap. Boot line
`"✓ cron N jobs loaded"` is dropped; the Owner may `Logger.info` a count. **Greenfield: remove, no shim.**

---

## Phase 2 — Ad-hoc scheduling persists + hands off to the leader

Invariant: after the tool/command returns, the job is **durable**, and the **leader** (never the
follower) runs it — promptly via the `notify_changed` signal, or by the next periodic reconcile if
the signal didn't land. (On a follower, `notify_changed/1` is a fire-and-forget cast that succeeds
even with no reachable leader; the durable row + reconcile backstop is the guarantee, not
synchronous cross-node scheduling. ⮕ *Finding P2*)

### `lib/jido_claw/core/cluster.ex` + the stub — add the `leader/0` facade ⮕ *Finding 2*
`Cluster.leader/0` does **not** exist today (only `Cluster.Leader.leader/0`, `leader.ex:203`).
Add `def leader, do: leader_module().leader()` beside `leader?/0` (`:110`). Extend the
`:cluster_leader_module` contract: `JidoClaw.ClusterLeaderStub` gains `leader/0` returning
`Application.get_env(:jido_claw, :cluster_leader_stub_node, Node.self())`.

### `lib/jido_claw/platform/cron/owner.ex` — `notify_changed/1`
```
notify_changed(t):
  if Cluster.leader?():
    case GenServer.whereis(__MODULE__) do                    # ⮕ #1 Owner is absent in :mcp / disabled in test
      nil  -> Logger.debug("[Cron.Owner] not running; row persisted, reconcile deferred"); :ok
      _pid -> GenServer.call(__MODULE__, {:reconcile_tenant, t})   # leader-local SYNC
    end                                                      #   (preserves single-node "worker exists on return")
  else:
    case Cluster.leader() do
      nil  -> :ok                                            # no leader yet → periodic reconcile backstops
      node -> GenServer.cast({__MODULE__, node}, {:reconcile_tenant, t})   # cast is safe even if the remote Owner is absent
    end
```
(Single-node: `leader?/0` true → sync local reconcile = same effect as today's direct
`Scheduler.schedule`. Reconcile is per-tenant via the same `converge/2`.)

### Write tools/commands — DB-write-then-notify (⮕ *Findings 1, 6*)
- `tools/schedule_task.ex`: reorder `schedule_and_persist/1` (`:99`) to **persist first**
  (`Job.upsert`, `:132`), then `Cron.Owner.notify_changed(tenant_id)`; **drop** the direct
  `Scheduler.schedule/2` (`:110`). ⮕ *Finding P2 — "persist first" is only relative to
  *scheduling*; validation stays first:* `run/2`'s `with` already parses target/schedule/timezone
  before `schedule_and_persist`, so an invalid schedule still errors **without** persisting. Keep
  that. Re-using a `job_id` now updates the row → reconcile's
  fingerprint pass restarts the worker (intentional). **Because `:upsert` clears `disabled_at`
  (⮕ re-enable #2), re-scheduling a *disabled* id re-enables it** — otherwise `for_tenant` keeps
  filtering it out (`is_nil(disabled_at)`) and it would never restart. Return success even if no
  leader is reachable (row is durable; reconcile schedules it later).
- `tools/unschedule_task.ex` (`:24`): keep `remove_persistent/3` (`Job.remove`); **replace** the
  direct `Scheduler.unschedule/2` (`:33`) with `notify_changed/1`. Collapse the result-tuple
  matching to the single path.
- `cli/commands.ex`: route `/cron add` (`:548`, **keeping its `parse_cron_schedule`/`NextRun`
  validation *before* `CronJob.upsert` — `commands.ex:1625`; invalid schedules must error without
  persisting, locked by `commands_cron_test.exs:49` ⮕ P2**), `/cron remove` (`:552`→drop `unschedule`, keep
  `CronJob.remove`, add notify), and **`/cron disable` (`:577`→drop `CronWorker.disable`, keep
  `CronJob.disable`, add notify)** through DB-write-then-`notify_changed`. **`/cron trigger`
  (`:568`) routes through `Cron.Owner.trigger/2 :: (tenant, id) -> :ok | {:error, reason}`** — a
  **bounded `GenServer.call`** to the leader (local on the leader, or to `{Owner, leader_node}`
  from a follower; caller catches exits → `{:error, :unavailable}`, `{:error, :no_leader}` when the
  leader is unknown, and `{:error, :desired_unknown}` when the leader couldn't read desired state to
  confirm the job is enabled — ⮕ P2 *fail closed*). The CLI prints "Triggered" **only on `:ok`**, a real error
  otherwise. **Not a cast** (⮕ #P1) — trigger has no reconcile backstop, so a dropped message must
  never masquerade as success. `Scheduler.trigger/2` also gains a `GenServer.whereis`
  worker-existence check before the `Worker.trigger/2` cast, returning `{:error, :not_found}` when
  absent (today it's fire-and-forget, always `:ok`). The leader-side handler **reconciles the
  tenant before triggering**, so the outcome is row-driven, not dependent on a worker's prune
  timing. Manual fire stays ungated.
  **Intentional semantic change (⮕ P2):** today `Cron.Worker` treats manual trigger as an
  *override that fires even a disabled job* (`worker.ex:12,137`), and there's a brief
  auto-disable→prune window where such a worker still exists. WS4a's reconcile-then-trigger
  collapses both into one deterministic rule — **trigger fires only an *enabled* job**; a disabled
  (pruned) job returns `{:error, :not_found}`, so re-schedule (which re-enables, ⮕ #2) to run it. A
  row-backed dispatch that fires disabled rows directly stays an explicit non-goal (would duplicate
  `Dispatcher` outside a worker).

### List views — read persisted rows ⮕ *Findings 3, 4*
`Scheduler.list_jobs/1` reads node-local workers; on a follower that is always `[]`, so a
follower could `schedule_task` and then report "No scheduled tasks." Change the read surfaces to
the `cron_jobs` rows (the truth):
- **New read `Cron.Job.for_tenant_all`** — same as `for_tenant` but **without** the
  `is_nil(disabled_at)` filter. `for_tenant` excludes disabled rows (`job.ex:157`), so after
  `/cron disable` a job would *vanish* from the list. List views use `for_tenant_all`; the
  Owner's desired-state read stays `for_tenant` (non-disabled only). ⮕ *Finding 3*
- `tools/list_scheduled_tasks.ex` (`:23`) and `cli/commands.ex` `/cron` list (`:607`,
  `print_cron_job/1`) render from rows: `task`, schedule, `mode`, `target`, `workflow_name`,
  `timezone`, `last_run_at`, `run_count`, and **enabled/disabled** from `disabled_at`.
  **⮕ *Finding 4* — intentional behavior change, NOT byte-identical:** the worker-only `next_run`
  and `failure_count` (`list_scheduled_tasks.ex:29`) are not persisted. `next_run` *may* be
  recomputed from the schedule via `Cron.NextRun` for display (optional); `failure_count` is
  dropped in favor of the persisted enabled/disabled state. Update the tool description + the
  list-view tests to the row-backed shape (don't assert the old worker fields).

---

## Phase 3 — Tests (single-BEAM) + WS6 hand-off

### New: `test/jido_claw/cron/owner_test.exs` — `use JidoClaw.TenantCase, async: false`
Reuse the WS4 gate-test harness (`worker_leader_gate_test.exs`): install
`JidoClaw.ClusterLeaderStub` via `:cluster_leader_module`, flip `:cluster_leader_stub_result`
per test (and `:cluster_leader_stub_node` for the new `leader/0`); start the Owner with
`start_supervised!({Owner, [interval: <far_future>]})` and drive `Owner.reconcile/0` explicitly;
fixtures via `seed_tenant`, `Tenant.Manager.ensure_tenant`, `Job.upsert` (e.g.
`mfa_module: "JidoClaw.Cron.TestSupport"` for `always_fail`); assert worker presence through the
`:via` tuple `{:via, Registry, {JidoClaw.TenantRegistry, {:cron, t, id}}}`. Cases:
- **leader → loads**; reconcile **again** → idempotent (same set, no churn, no crash).
- **follower → drops** every user worker; a `mode: :system_job` worker (seeded under `"system"`)
  **survives** (Owner skips `"system"` + the defensive `:system_job` filter).
- **prune on remove/disable**: after a load, `Job.remove`/`Job.disable` one row; reconcile drops
  only that worker.
- **restart-on-change (⮕ #1)**: load a job; `Job.upsert` the same id with a changed
  schedule/task; reconcile → the worker is restarted and `get_state` reflects the new config
  (and a different pid).
- **inactive-tenant prune (⮕ #5)**: load under an active tenant; flip the tenant to
  `:suspended`/`:terminating`; reconcile → its workers are pruned even though it's no longer in
  the active set.
- **read-failure does NOT prune (⮕ #1)**: with workers running, force the desired-read to
  `{:error, _}` (via a DI seam on the read fn, or a deliberately broken read) and reconcile →
  the existing workers **survive** (unknown ≠ empty). Mirror for a `Tenants.Tenant.list/0`
  failure → no tenant is touched. (Structure `reconcile_entry/2` so the read result is
  injectable, à la the Leader's `members_fun` seam, to make this testable single-BEAM.)
- **invalid-config keeps the worker (⮕ #1)**: load a valid `:mfa` job
  (`mfa_module: "JidoClaw.Cron.TestSupport"`); `Job.upsert` the same id with an **unknown mfa
  module** (a present-but-bogus string — the action accepts it; `resolve_module` fails only at
  schedule/build time); reconcile → `changed?/2` returns `{:error, _}` and the **original worker
  is still running** (same pid), not dropped. (The nil-`workflow_name` variant is *not*
  upsert-constructible — `job.ex:108` validates it — so it would need a raw corrupt-row fixture;
  prefer the unknown-module case.)
- **boot-race / no event**: stub `false`, reconcile (loads nothing); stub `true`, reconcile →
  loads (proves the periodic re-check recovers without a `leader_changed` event).
- **telemetry-driven**: emit `[:jido_claw, :cluster, :leader_changed]` (raw `:telemetry.execute`,
  per `telemetry_test.exs`/`leader_test.exs`) → poll for the reconcile's worker-set change.
- **P2 single-node**: `notify_changed` after `upsert`/`remove`/`disable` converges the set
  (leader-local sync). Follower-routing decision (`notify_changed` chooses the cast branch when
  stub `false`) asserted at the routing level (real cross-node delivery is the WS6 proof).
- **trigger reconcile-then-fire (⮕ P2)**: persist a job row **without** a running worker, then
  `Cron.Owner.trigger/2` → it fires (the leader-side reconcile schedules it first); a genuinely
  absent/disabled id returns `{:error, :not_found}`.
- **trigger fails closed on unknown desired (⮕ P2/P3)**: leave a **stale local worker** for a
  disabled/removed job, force the pre-trigger read to `{:error, _}` (the DI seam) — covering **both**
  the tenant-row read (`Tenants.Tenant.by_id`) and the job read (`Job.for_tenant`) — then
  `Cron.Owner.trigger/2` → returns `{:error, :desired_unknown}` and **does not fire** the stale
  worker (would otherwise violate "enabled jobs only").

### `Cluster.leader/0` + idempotency coverage
- Extend `leader_test.exs` / `cluster_test.exs` for the new `Cluster.leader/0` facade (single-node
  → `Node.self()`; clustered-absent → `nil`; seam → stub).
- Extend `persistent_disable_test.exs` (or a small `scheduler_idempotency_test.exs`):
  `schedule_persisted/2` twice → success, no duplicate; `changed?/2` true on a config edit, false
  otherwise.
- **re-enable on upsert (⮕ #2)**: `Job.disable` a row, `Job.upsert` the same `job_id`, assert
  `disabled_at == nil`, then the Owner schedules it on reconcile (proves the `upsert_fields` +
  `set_attribute` combination actually clears the flag, against the omitted-field-preserved default).

### List-view tests
Update `list_scheduled_tasks` / `/cron` tests to assert the row-backed output (and that a job
shows even when no local worker is running — the follower case, simulated by not scheduling).

### Existing-test updates (Owner disabled in test)
With `:cron_owner, enabled?: false`, the write tools/commands persist the row but **no worker
starts** unless a test starts the Owner. So tests that assert a local worker after `/cron add` /
`schedule_task` must change to the new contract — e.g. `test/jido_claw/cli/commands_cron_test.exs`
(`:84` asserts `/cron add` creates a local worker): either assert the **persisted row** (the new
truth), or `start_supervised!(JidoClaw.Cron.Owner)` + `Cron.Owner.reconcile()` and then assert
the worker. Audit `schedule_task`/`unschedule_task` tool tests for the same assumption. (This is
the test-surface of the persist-then-notify behavior change, not a regression.) The **invalid-cron
tests** (`commands_cron_test.exs:49`) must stay green unchanged — validation runs *before* persist,
so an invalid schedule still errors without leaving a durable row (⮕ P2).

### Cross-BEAM proof → WS6
Add to `docs/plans/clustering/WS6-testing-and-ops.md` "Test plan": **"User-cron exactly-once
failover — two `:peer` nodes, exactly one runs a given user job; kill the leader, assert the
survivor's Owner reloads within the election + reconcile window and continues firing, no
double-fire."** Only WS4a behavior not provable single-BEAM; rides WS6's (not-yet-built) harness,
exactly as WS1/WS3/WS4's cross-BEAM proofs do — surfaced and tracked, not silently dropped.

---

## Critical files

**New**
- `lib/jido_claw/platform/cron/owner.ex` — `Cron.Owner` (reconcile + listener + `notify_changed`)
- `test/jido_claw/cron/owner_test.exs`

**Modified**
- `lib/jido_claw/platform/cron/scheduler.ex` — `schedule_persisted/2`, `changed?/2`
- `lib/jido_claw/cron/resources/job.ex` — add `for_tenant_all` read (display, incl. disabled); clear `disabled_at` on `:upsert` so (re)scheduling re-enables — **both** add `:disabled_at` to the action's `upsert_fields` whitelist (`job.ex:73` — omitted fields are otherwise preserved on conflict) **and** a `change set_attribute(:disabled_at, nil)` so the value is actually written (⮕ list-view #3, re-enable #2)
- `lib/jido_claw/core/cluster.ex` — add `leader/0` facade (⮕ #2)
- `test/support/jido_claw/cluster_leader_stub.ex` — add `leader/0` (⮕ #2)
- `lib/jido_claw/application.ex` — register `Cron.Owner` (`:mcp`/`enabled?`-gated)
- `config/test.exs` — `:cron_owner, enabled?: false` (⮕ #4)
- `lib/jido_claw/cli/repl.ex` — remove `load_cron_jobs/1` + its `:248` call
- `lib/jido_claw/tools/schedule_task.ex` — persist-then-`notify_changed`
- `lib/jido_claw/tools/unschedule_task.ex` — remove-then-`notify_changed`
- `lib/jido_claw/tools/list_scheduled_tasks.ex` — read persisted rows (⮕ #3)
- `lib/jido_claw/cli/commands.ex` — route `/cron add|remove|disable` through `notify_changed` **and `/cron trigger` through `Cron.Owner.trigger/2`**; keep `/cron add` schedule validation before persist; `/cron` list reads rows (⮕ list #3, disable #6, trigger/validate P2)
- `docs/plans/clustering/WS6-testing-and-ops.md` — add the user-cron failover row
- `docs/plans/clustering/WS4a-clustered-cron-ownership.md` — flip status design → in-progress/done

## Reuse
- `Cron.Scheduler.{schedule,unschedule,list_jobs,build_persistent_opts,load_persistent_jobs}` (`scheduler.ex`)
- `Cron.Job.for_tenant` (`cron/resources/job.ex:157`); `Cron.Worker` state struct (config fields for `changed?/2`, `worker.ex:44`)
- `Tenants.Tenant.list/0` (`tenants/resources/tenant.ex:97`, all statuses) + `Tenants.Tenant.by_id/1` (`:53`, per-tenant path); `Tenant.Manager.ensure_tenant/2`; `InstanceSupervisor.cron_sup/1`
- `Cluster.leader?/0` (`core/cluster.ex:110`) + **new** `Cluster.leader/0` → `Cluster.Leader.{leader?,leader}/0` (`core/cluster/leader.ex:185,203`)
- `[:jido_claw, :cluster, :leader_changed]` telemetry (`leader.ex:231`, metadata `%{leader, previous, members}`)
- Test seams: `ClusterLeaderStub` + `:cluster_leader_module`; `TenantCase` (`seed_tenant`/`actor_for`, shared sandbox); `Cron.TestSupport.always_fail/0`
- The `cron:<job>:<window>` idempotency key stays the belt-and-suspenders backstop for `:workflow` targets during the brief two-leaders convergence window.

---

## Verification (not done until `mix precommit` passes)

**Automated**
- `mise exec -- mix test test/jido_claw/cron/owner_test.exs` + the scheduler-idempotency / `leader/0` / list-view tests — verify new `async: false` files **in isolation**, not under `--seed 0` (suite-flaky note).
- `mise exec -- mix test` — full suite green.

**Manual single-node** (same ownership/firing semantics + REPL-load removal; expect the intentional update/list-view changes, not byte-identical output) ⮕ *note: `schedule_task` accepts only `agent`/`workflow`, never MFA*
- `mise exec -- mix jidoclaw`; `schedule_task` an `every 1m` **agent** job; confirm it fires; quit + relaunch → the Owner (not the REPL) reloads it (logs / `list_scheduled_tasks`). Then re-`schedule_task` the same id with a new schedule → confirm the worker restarts with the new timing (⮕ #1).

**Drive reconcile live** (Tidewave `project_eval`)
- Stub follower (`:cluster_leader_module → ClusterLeaderStub`, `:cluster_leader_stub_result false`), `Cron.Owner.reconcile()` → user workers drop; flip `true`, reconcile → reload. Reset env after.

**Precommit gate** (run bare in background, read the tail — never pipe through `tail`, it masks the exit code)
- `mise exec -- mix format`
- `mise exec -- mix jidoclaw.compile_check` (no warnings; allowlist empty)
- credo-strict: `@spec` on every public Owner/Scheduler fn, `@impl` per `leader.ex`, alias multiply-used modules, no `behaviour_candidate`/ExSlop smells
- dialyzer (Owner is a plain GenServer — **no** Ash resource, so the AshCredo-visibility trap is N/A; no Zoi schema)
- the full `mix test` phase

---

## Out of scope (recorded, not silently deferred)
- **Cross-BEAM `:peer` failover test** → WS6 (harness owner); WS4a adds the test-plan row. Mechanism fully proven single-BEAM here.
- **Work-stealing / graceful live-node drain** — WS4 non-goal; a draining node's runs are recovered by WS3's lease-expiry path; its user-cron workers reload on the new leader via this Owner.
- **Per-tenant cron `:bypass` list action** — not needed; `Tenants.Tenant.list/0` + `Job.for_tenant` reuse existing reads. Revisit only if tenant count makes N per-tenant reads per tick a measured cost.
- **List-view overlay of the leader's live `next_run`** across nodes — rows + `last_run_at`/`run_count` suffice; cross-node runtime overlay is a future nicety.
