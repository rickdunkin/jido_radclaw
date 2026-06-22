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

### Parent renewal lives in the `RouteComposer` GenServer

With WS1 decision D1(b) (self-claim on launch), the launching node claims the
parent and the `RouteComposer` GenServer renews it on a timer for as long as it
is alive — **across waves and across gate pauses**. This is the right owner: the
GenServer is alive and heartbeating even while the loop is suspended waiting on a
releasing signal (`AR-2:893-895`).

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
`{0, _}` (another node reclaimed and rotated the token) means this composer is a
zombie: it stops its loop and shuts down its GenServer without writing further
parent events, so the reclaiming node's rebuilt state is authoritative.

## Decisions

- **D1 — renewal cadence vs WS1 default.** The composer parent can be `:running`
  for a long time (multi-wave + day-long gate pauses), so the ~60s/15s WS1 tuning
  applies unchanged; the GenServer renew timer is the same machinery as a single
  run's `Lease` middleware, just hosted by the composer instead of the executor
  task.
- **D2 — what reclaim resumes.** Committed by AR-2 §6: rebuild from the log,
  re-`compose_route`, resume from the next wave, never resuming a wave parked on
  an unresolved gate. WS3 owns the reclaim trigger; WS2 owns that the composer can
  *be* reclaimed (its state is log-derived, which Phase 2 already guarantees).

## Test plan

- **Parent renew across waves** — a composer running ≥2 waves renews the parent
  lease on schedule; `claim_expires_at` advances each tick.
- **Renew across gate pause** — a composer parked on a child gate keeps the parent
  lease alive (the parent never expires while the node is up).
- **Stale-fence halt** — rotate the parent's `claim_token` mid-run; the composer
  stops cleanly and writes no further parent events.
- **Reclaim re-folds, never re-runs** — a wave with a completed child run is
  re-derived after reclaim and folded from `{:existing_run, _}`, not re-executed
  (relies on the shipped idempotency key).

Real cross-node composer reclaim is a WS6 multi-node test; WS2 lands with
single-node renewal + fence tests.

## Cross-references

- **AR-2 §10.1** — `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md:875-904` (the
  authoritative design this implements).
- **AR-2 Phase 6** — `:1053` (the deferral this closes).
- **AR-2 §6** — durable envelope + composer-state projection (the reclaim
  substrate, shipped Phase 2).
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — the `:claim_next`/`:renew`/`Lease`
  primitives this builds on. WS3 ([WS3-reclaim-and-recovery.md](WS3-reclaim-and-recovery.md))
  — the dead-node reclaim trigger and composer state rebuild.
