# WS2 — Composer lease (= AR-2 Phase 6)

*Builds: the lease re-derived around the composer's multi-wave unit. Depends on:
WS1. Implements: AR-2 §10.1 / Phase 6.*

> **This workstream IS AR-2 Phase 6.** AR-2 deferred its Phase 6 "Cluster lease
> (G1-1, §10.1)" with *"Deferred until clustering is real"*
> (`AR-2-COMPOSER-PLAN.md:1053`). WS2 is that phase, now scheduled. The full
> design already exists in **AR-2 §10.1** (`:875-904`) — this doc adapts it to the
> WS1 substrate and records what changed since AR-2 was written (the composer is
> now built).

## Why the composer needs its own lease unit

gust's lease assumes **run = one `Reactor.run`** (`AR-2-COMPOSER-PLAN.md:877`). The
composer breaks that: a composed run is a **loop spanning N waves**, with state
(`live` / `artifacts` / `ran` / `premises`) living *between* reactor executions.
So the lease unit is the **parent (composer) run**, not the wave (`:879`):

- The **Pooler claims the parent `WorkflowRun`** (WS1 `:claim_next`).
- The composer **renews the parent's lease across waves** and **halts on a stale
  fence** (`claim_token` mismatch) (`:881-884`).
- Each wave is a child run with its own deterministic idempotency key
  `composer:<parent_run_id>:<wave_index>` — wave boundaries multiply reclaim
  surface, so the step-level idempotency keys §4.11 calls *optional* are
  **mandatory** here (`:886-890`). **Already shipped** (the key is set today,
  `reactor_runner.ex` + composer Phase 2), so reclaim re-deriving a wave gets back
  `{:ok, {:existing_run, _}, _}` and folds the finished wave instead of
  re-running it.

## Reuse / current state

The composer is **already built** — AR-2 Phases 0–5 shipped (see git history;
`lib/jido_claw/route_composer/route_composer.ex`). WS2 layers lease renewal onto
a live GenServer, it does not build the composer:

- **`RouteComposer` GenServer, supervised + registered.** Runs under
  `JidoClaw.RouteComposer.Supervisor` (DynamicSupervisor) and registers in
  `JidoClaw.RouteComposer.Registry` keyed by `parent_run_id`
  (`application.ex:160-165`). That registry key is exactly what "find-or-start the
  owner for a run" and "single live owner per route" require (`AR-2:374-378`) —
  and it is the natural place to own the parent lease renewal.
- **Composer state projects from the parent event log** (AR-2 §6, shipped Phase
  2): `route_composed` / `wave_started` / `wave_completed` / `signals_retracted`
  / `stages_invalidated` / `artifacts_*`. A reclaiming node **rebuilds state and
  resumes mid-route** by folding this log — strictly better than gust's blind
  re-run (`AR-2:885-886`). This is what makes composer reclaim (WS3) tractable.
- **Waves already run through `ReactorRunner.run/3`** (`route_composer.ex:1146`
  for gate waves, `:1328` for worker waves), so they inherit WS1's `Lease`
  middleware for free at the *wave* level; WS2 adds the *parent* lease on top.

## Design

### Parent renewal lives in an off-process sidecar (Approach A)

The hard constraint that shapes the design: the `RouteComposer` GenServer runs its
wave loop **synchronously** — each worker wave calls `ReactorRunner.run/3` and
**blocks there** (up to `wave_timeout_ms`, default 300 s) while the lease is only
60 s. A self-timer inside the GenServer mailbox cannot fire mid-wave, so it could
not keep a long wave's lease alive. So **renewal is driven from an off-process
sidecar** (decided with the user), exactly as WS1 already heartbeats child runs:

- **Reuse the WS1 `Sidecar`** for the parent. The `RouteComposer` GenServer is the
  sidecar's "executor": the sidecar renews the parent lease every `renew_seconds`
  independently of the GenServer mailbox (no mid-wave gap), and on a stale fence
  (`renew/2 → {:ok, 0}`) it `Process.exit(composer, :kill)`s.
- The composer **self-claims at genesis** (D1b): `create_parent_run/1` stamps the
  parent `nil → fresh token` *inside* the genesis transaction, between
  `WorkflowRun.create` (`:pending`) and the `run_started` append — mirroring WS1's
  `:pending`-claim invariant (`middleware.ex`). Claiming *after* `run_started` flips
  the row `:running` would, on a crash-in-the-gap, leave a `:running + nil
  claim_token` row — a shape `:claimable` does **not** select — i.e. permanently
  stranded. Claiming first leaves either **nothing** (rolled back) or **`:running +
  claimed`** (reclaimable on expiry).
- The composer is the right *renewal* owner because it is alive and heartbeating
  even while the loop is parked for days on a human gate (`AR-2:893-895`); the
  sidecar is the right *renewal mechanism* because it survives the synchronous wave.

### `:kill` → `:transient` restart → held-token preflight

The killed composer is restarted by `RouteComposer.Supervisor`; on rebuild it
**preflights the token it holds** — frozen in its start_opts, *not* re-read from the
row. If `renew/2` returns `{:ok, 0}` the row's token was rotated by the reclaiming
node → the restarted process is a zombie → `{:stop, :normal}` writing **no parent
events**, so the reclaiming node's rebuilt state stays authoritative. `{:ok, 1}` →
still owner → restart the sidecar and resume. The **`build_start_opts` token freeze
is load-bearing**: a restarted zombie that re-read the row would renew the
*reclaimer's* token and steal the claim back.

### Durable token-fence (defense in depth)

The kill→restart→preflight path is the primary halt; the durable token-fence is the
secondary defense, so even a not-yet-killed zombie cannot corrupt the new owner's
log. `Allocate`'s WS1 fence B (`claim_fenced?`) covers only **status-authority**
writes (the `route_*` terminals are status-authority, so threading the held token
there fences a stale terminal for free). The composer's **non-status-authority
markers** (`wave_completed` / content / lifecycle) are not covered by fence B, so
WS2 adds a parallel token-fence in `Commit.guarded_wave_txn/4`: under the same
FOR-UPDATE lock, a held-token-vs-row-token mismatch returns the bare atom
`:parent_fenced` (success channel, remapped to `{:error, :parent_fenced}`) **before
any append**. The composer treats `:parent_fenced` as "another owner has the parent
— stop clean, write nothing, **tear nothing down**" — distinct from
`:parent_terminal` ("the run truly ended"), which at the two gate-park Commit sites
tears the gate `AgentCase` down. A fence must leave the gate **open** for the
reclaiming node to re-park.

### The master compatibility switch

Every runtime lease behavior is gated on **`is_binary(state.claim_token)`** (mirrors
WS1's no-token middleware clause). A real launch always claims (genesis is
unconditional, inside the txn), so it always runs leased. A **nil** token — a
`loop_state/3` raw-state tick or any path that bypasses `create_parent_run` — ⇒ the
byte-identical unleased path: no preflight, no sidecar, no marker/terminal fence.
This keeps every existing composer test unchanged.

### Token lifecycle (the WS3-load-bearing invariant)

| Phase | Token behavior |
|---|---|
| **Fresh launch** | `create_parent_run/1` stamps the parent `nil → fresh token` *before* the GenServer ticks; the token rides `build_start_opts → init → state.claim_token`. |
| **Local restart** (crash, same node) | `:transient` restart reuses the **frozen start_opts token**; preflight `renew/2 → {:ok, 1}` (row token unchanged single-node) → resume + restart sidecar. |
| **WS3 reclaim** (other node) | The dispatcher starts the composer from the token `claim_next` returned; same start_opts seam. *(WS2 builds the seam; WS3 wires the dispatcher.)* |
| **Fence-kill restart** | Held token ≠ rotated row token → preflight `renew/2 → {:ok, 0}` → `{:stop, :normal}`, no events. |

> The invariant WS3 depends on: **a fresh lease ⇒ a live owner; an expired lease ⇒
> a reclaimable owner**, regardless of how long a legitimate wave runs (the
> off-process renewal is what makes "regardless of how long" true).

### Lease-handoff registration race

`LeaseRegistry` is `:unique`. On an ordinary crash-restart with the same token, the
supervisor can restart the composer (and its sidecar) before the old sidecar
processes its `:DOWN` and unregisters, so the new sidecar's `Registry.register`
hits `{:already_registered, _}`. Fixed **in `Sidecar.run/5`**: bounded-retry
registration on `:already_registered` (~10 × 50 ms, well inside the 5 s readiness
deadline, before the monitor-arm/ready handshake) before exiting. This is a
deliberate WS1 touch — it is the generic lease-*handoff* race WS3's reclaim hits
too, so it belongs in the shared sidecar, not a composer-side busy-poll. The
composer's `start_sidecar` failure is **not** routed through `retry_rebuild_or_stop`
(`do_rebuild` resets `rebuild_attempts: 0` on every successful reload, so a
post-reload retry would never trip the cap → infinite loop); the Sidecar retry is
the fix, the composer's degrade/stop is only the backstop.

### The gate/lease interaction gust never faced

A wave parked at `:awaiting_approval` (child) while the parent is `:running`
(AR-2 §6) introduces **no second lease** (`AR-2:891-900`):

- The only claim is the **parent's**, and the owning node keeps it renewed across
  the gate pause.
- **No release-on-park.** A human approval may take days; a live renewal covers
  it, and a release-on-park would only churn. A `:running` parent with no
  claimant is *exactly* the orphan the lease exists to prevent. (Contrast: a
  parked *single-Reactor* run holds no lease and is re-claimed by `GateResume` on
  whichever node resumes — WS3. The composer parent is different because its
  GenServer stays alive.)
- **Reclaim is purely the dead-node path:** lease expiry → another node reclaims,
  rebuilds state from the parent log, resumes mid-route, **re-parking if the gate
  is still open** (WS3).

### Halt on stale fence

The parent renew uses WS1 `:renew` fenced on `(parent_run_id, claim_token)`. A
`{:ok, 0}` (another node reclaimed and rotated the token) means this composer is a
zombie. The **sidecar** sees it on its next tick → `fence_decision → :kill` →
`Process.exit(composer, :kill)`; the `:transient` restart then preflights the same
held token, gets `{:ok, 0}`, and `{:stop, :normal}`s without writing further parent
events, so the reclaiming node's rebuilt state is authoritative.

## Decisions

- **D1 — off-process sidecar (Approach A), not a GenServer timer.** A GenServer
  self-timer cannot fire while the loop is blocked synchronously in
  `ReactorRunner.run/3` (up to 300 s) — so it could not keep a long wave's 60 s
  lease alive. Renewal therefore rides the WS1 `Sidecar` (a `Task`), which renews
  off the composer's mailbox. The ~60s/15s WS1 tuning applies unchanged (the parent
  can be `:running` for multi-wave + day-long gate pauses). *(An earlier draft put
  the timer in the GenServer; the synchronous-wave constraint ruled it out.)*
- **D2 — what reclaim resumes.** Committed by AR-2 §6: rebuild from the log,
  re-`compose_route`, resume from the next wave, never resuming a wave parked on
  an unresolved gate. WS3 owns the reclaim trigger; WS2 owns that the composer can
  *be* reclaimed (its state is log-derived, which Phase 2 already guarantees) and
  that its parent lease stays live while it runs.

## Test plan

Tests drive renewal through the sidecar's `{:lease_tick, from}` seam (the prod
auto-renew is parked at `renew_seconds: 86_400` in test config — renewal is
**sidecar-driven on demand**, *not* "advances each tick" on a wall-clock timer).
`async: false` + the shared sandbox so the composer and its off-process sidecar
share one connection.

- **Genesis self-claim** — after `create_parent_run/1` the row has a binary
  `claim_token`, `claimed_by == node_identity()`, `claim_expires_at ≈ now+60 s`.
- **Parent renew across waves** — a supervised composer running ≥2 stub waves; look
  up the parent sidecar in `LeaseRegistry` by `parent_run_id`, drive a
  `{:lease_tick, self()}`, assert `{:lease_ticked, {:ok, 1}}` and `claim_expires_at`
  advanced.
- **Renew across gate pause** — a composer parked on a child gate keeps the parent
  lease alive (drive the sidecar tick during the park → `{:ok, 1}`, expiry
  advances) — proving off-process renewal during a synchronous-loop park.
- **Fence → kill → restart → preflight → stop** — rotate the parent's `claim_token`
  out from under the live owner; the sidecar tick → `{:ok, 0}` → kill → restart →
  preflight `{:ok, 0}` → `{:stop, :normal}`, no new parent events, row token
  unchanged.
- **Ordinary crash-restart, same token** — kill the composer **without** rotating
  the token; it restarts, preflight `{:ok, 1}`, re-registers its sidecar, resumes to
  terminal (exercises the registration retry integration-level).
- **Sidecar registration retry (deterministic)** — pre-own the `LeaseRegistry` key
  with a temporary blocker that unregisters after ~100 ms; `start_sidecar/4` returns
  `:ok` and the sidecar then owns the key (in `workflow_lease_test.exs`).
- **Durable marker fence** — a mismatched `claim_fence_token` on
  `Commit.commit_wave`/`append_markers` → `{:error, :parent_fenced}`; matching/`nil`
  → `:ok`. Composer-level: a stale wave commit yields `:parent_fenced` →
  `{:stop, :normal}`, no marker appended.
- **Terminal fence** — drive the status-authority fence B through the public
  `WorkflowLog.append(parent, :route_converged, …, claim_fence_token: stale)`: a
  mismatched token is rejected with status unchanged; a matching token lands.
- **Reclaim re-folds, never re-runs** — a wave with a completed child run is
  re-derived after a rebuild and folded from `{:existing_run, _}`, not re-executed
  (relies on the shipped idempotency key).
- **Unleased compatibility** — a `claim_token: nil` composer runs with no
  preflight/sidecar/fence (existing behavior intact).

Real cross-node composer reclaim is a WS6 multi-node test; WS2 lands with
single-node renewal + fence + halt + restart tests.

> **README size:** WS2 is **M** (was S–M) given the durable-fence ripple (the
> nine `:parent_fenced` arms + the `commit_opts` threading + the terminal-fence
> reach across `append_parent_terminal` / `terminalize_parent`).

## Cross-references

- **AR-2 §10.1** — `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md:875-904` (the
  authoritative design this implements).
- **AR-2 Phase 6** — `:1053` (the deferral this closes).
- **AR-2 §6** — durable envelope + composer-state projection (the reclaim
  substrate, shipped Phase 2).
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — the `:claim_next`/`:renew`/`Lease`
  primitives this builds on. WS3 ([WS3-reclaim-and-recovery.md](WS3-reclaim-and-recovery.md))
  — the dead-node reclaim trigger and composer state rebuild.
