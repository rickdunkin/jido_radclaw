# WS1 — Lease core (the keystone)

*Builds: the durable `WorkflowRun` claim-lease. Depends on: nothing. Blocks:
WS2, WS3, WS4, WS5.*

> **What this owns.** The `:claim_next` / `:renew` actions, the `Pooler`, and
> `Reactor.Middleware.Lease` — the mechanism gust G1-1 and Squidie §4.11
> converge on, applied to a *single* `WorkflowRun` (the composer-spanning unit is
> WS2; dead-node reclaim semantics are WS3). See
> [README §coverage matrix](README.md#coverage-matrix--every-explicitly-deferred-clustering-item).

## The target

A run's owner is durable and fenced. One node claims a run, stamps its node name
+ a lease expiry + a fresh fence token, renews on a timer while it executes, and
**halts itself** if the token it holds no longer matches the row (someone else
reclaimed it). A dead node's runs become reclaimable after the lease lapses
(bounded recovery window = lease length). `FOR UPDATE SKIP LOCKED` makes
concurrent claim-pollers across nodes race-free.

This is the gust mechanism (`gust/FEATURES-WORTH-BORROWING.md:100-119`) in
Ash/Reactor idiom (`REACTOR-ADOPTION.md:659-690`).

## Reuse / current state

The data model is **done** and the claim pattern **already exists in-repo** —
this is implementation, not greenfield design:

- **Claim columns + global indexes already shipped** (currently dead, zero
  callers): `claimed_by` / `claim_expires_at` / `claim_token`
  (`workflow_run.ex:333-346`) and the two `all_tenants?: true` scan indexes
  `(status, claim_expires_at)` and `(claimed_by)` (`workflow_run.ex:73-74`).
- **The exact claim pattern is already live in `BackfillWorker`**
  (`embeddings/backfill_worker.ex:178-190`): a `FOR UPDATE SKIP LOCKED` claim that
  stamps a row-level lease (`embedding_next_attempt_at = now() + interval`) and
  reclaims rows whose lease expired (`:19-23`). WS1 is generalizing this proven
  pattern to `WorkflowRun`. **Read it first** — it answers most "how" questions.
- **Idempotency keys are shipped.** `ReactorRunner.run/3` already supports
  at-most-once launch per key (`reactor_runner.ex:68-79`, hit →
  `{:ok, {:existing_run, id}, run}` at `:256,:328`). §4.11 calls these "optional";
  under clustering they are mandatory (wave boundaries multiply reclaim surface,
  AR-2 §10.1 `:886-890`) — but they already exist, so this is free.
- **Run execution seam exists.** Every run already executes inside a registered
  killable task (`RunExecution.run_killable/4`, `run_execution.ex:96`), registered
  in the node-local `JidoClaw.Orchestration.RunRegistry` (`application.ex:153`).
  The Pooler starts claimed runs through this same seam.
- **`:create` already accepts the FK fields** (`workflow_run.ex:104-116` includes
  `:parent_run_id`, `:idempotency_key`, `:retry_of_id`) — composer envelope schema
  is already in place (AR-2 Phase 2 shipped).

## Design

### Component 1 — `:claim_next` (Ash read+update on `WorkflowRun`)

Select one claimable run under a row lock, oldest first, and stamp ownership:

```
status == :pending OR (status == :running AND claim_expires_at < now())
  |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
  |> limit(1), oldest first
  → stamp claimed_by: node, claim_expires_at: now + lease, claim_token: fresh uuid
```

`:pending` is jido_radclaw's "created, not yet running" status — there is **no
separate `:enqueued` state** as in gust (`REACTOR-ADOPTION.md:670-673`). `SKIP
LOCKED` is the cross-node race fence (`gust/…:103-104`).

**Critical divergence from gust — do NOT stamp `status`.** gust's claim sets
`status: :running` in the same update (`gust/…:102-103`). jido_radclaw's `status`
is **projection-owned**: the only writer is `set_status`, called solely by
`WorkflowEvent.Changes.Allocate` inside the append transaction
(`workflow_run.ex:122-135`). So `:claim_next` stamps **only the three claim
columns**; the existing `run_started` event flips `:pending → :running` through
the projection. A claim of an already-`:running` (expired) run is a *reclaim* and
leaves `status` untouched — WS3 owns what the reclaiming node then does. This
keeps the event log the single source of truth for lifecycle and avoids a second,
racing status writer.

The claim columns are `public?(false)` (`workflow_run.ex:335,340,345`); the action
is internal, invoked via `Ash.Changeset`/`Ash.update` like `set_status`.

### Component 2 — `:renew` (fenced update)

```
update_all claim_expires_at: now + lease
  WHERE id == ^id AND claim_token == ^token
  → {1, [row]} = still ours;  {0, []} = lost the claim (someone rotated the token)
```

The `(id, claim_token)` match **is the fence** (`gust/…:107-109`). A `{0, _}`
return is the signal to halt (Component 3). Same projection-ownership rule: renew
touches only `claim_expires_at`, never `status`.

### Component 3 — `Reactor.Middleware.Lease`

A Reactor middleware injected alongside the shipped `ReactorMiddleware`
(`reactor_runner.ex` injects middleware on every run). It:

- starts a renew timer in its `init/1` (interval = renew period),
- calls `:renew` on each tick,
- on a `{0, _}` (stale fence) result, **halts the reactor** so the zombie
  self-terminates without double-completing (`REACTOR-ADOPTION.md:679-680`;
  gust's `dag_worker.ex` `:stop`s itself, `gust/…:110-113`).

This is the "stale-completion refusal" T2-4 wants (`squidie/…:286`): a fenced-out
executor stops before its terminal append, and even if it raced to append, the
projection's status barrier rejects a terminal from a non-owning generation.

The renew timer is per-run and node-local; it lives with the executor task, not a
central process.

### Component 4 — `Pooler` (per-node GenServer)

Per `REACTOR-ADOPTION.md:677-678`: a per-node GenServer that polls (+ is
PubSub-triggered on new-run notifications) → `:claim_next` → starts the claimed
run's reactor under a `DynamicSupervisor`, threading the `claim_token` into the
`Lease` middleware. Slots into the orchestration child group next to
`RunRegistry` / `RunTaskSupervisor` (`application.ex:153-154`), gated on
`cluster_enabled` (or always-on with a single-node fast path — see decision D2).

Mirror the `BackfillWorker` loop shape (`backfill_worker.ex:101-158`):
`schedule_scan` timer + `:hint_pending` PubSub messages → claim → dispatch.

### Tuning

Up from gust's 15s/5s to **~60s lease / 15s renew** (`REACTOR-ADOPTION.md:686`),
because double-calling an LLM/tool is expensive and a slow step must not outlive
its lease. Config keys under `:jido_claw, :workflow_lease` (`lease_seconds`,
`renew_seconds`), defaults in `config/config.exs`.

## Decisions

### D1 — The launch-path fork *(the big one)*

Runs launch **in-process and synchronously today**: callers invoke
`ReactorRunner.run/3` directly (`run_skill.ex:64`, `route_composer.ex:1146,1328`,
`replay.ex:251`, `gate_resume.ex:162`, `workflow_runner.ex:95`), which executes
immediately via `run_killable/4`. There is no claim before execution. WS1 must
pick how the lease relates to this:

- **(a) Pooler-only launch.** Callers create runs `:pending` and return; the
  Pooler claims and starts them. Clean lease semantics (every run is claimed
  before it runs), but refactors all ~6 call sites, adds poll latency, and
  changes the synchronous contract several callers rely on (the composer runs
  waves and folds results inline).
- **(b) Self-claim on launch** *(recommended)*. A direct launch claims its own run
  (stamps `claimed_by`/token, starts the `Lease` renew) as part of `run/3`; the
  Pooler only picks up runs that are `:pending` *unclaimed* or `:running`
  *expired* (the dead-node/reclaim set). Smaller blast radius, preserves the
  synchronous contract, and the composer's per-parent registry
  (`application.ex:160`) is a natural renewal owner. The Pooler becomes a
  *recovery/overflow* claimer, not the only door.

**Recommendation: (b).** It treats the lease as ownership-tracking layered onto
the existing launch path rather than a new dispatch architecture, and it keeps
single-node behavior byte-identical when nothing ever expires. Resolve before
coding — it shapes every other component.

### D2 — Pooler always-on vs `cluster_enabled`-gated

Recommended: the **claim/renew/fence is always active** (so single-node runs
carry an owner + lease, making WS3's reclaim uniform), but the **Pooler's
reclaim-poll** is the part that matters only when clustered. Keep the renew
machinery unconditional (cheap: one fenced `update_all` per interval) and gate
only the cross-node reclaim sweep. This mirrors how the embedding counter and
consolidator lock run unconditionally today (README baseline table).

### D3 — token plaintext vs hashed

Shipped model uses a plaintext `:uuid` `claim_token` directly on `WorkflowRun`
(`workflow_run.ex:343`). T2-4's hashed `claim_token_hash` on a separate
`WorkflowAttempt` is **obsolete** (`squidie/…:292`); do not revive it. Note: the
T1-1 redaction set already lists `claim_token` as sensitive
(`T1-1-WORKFLOW-EVENT-LOG-PLAN.md:318`), so it is scrubbed from any event payload —
keep it out of payloads regardless.

## Test plan

- **`:claim_next` race** — N concurrent claimers, one row: exactly one wins, the
  rest get the next rows or none (`FOR UPDATE SKIP LOCKED`). Reuse the
  `BackfillWorker` claim tests as a template.
- **Fence** — `:renew` with a rotated token returns `{0, _}`; with the held token
  returns `{1, _}`.
- **Lease middleware halt** — a run whose token is rotated mid-execution halts at
  the next renew tick and writes no terminal.
- **Reclaim selection** — a `:running` run with `claim_expires_at` in the past is
  selected by `:claim_next`; one with a future expiry is skipped.
- **Status untouched** — `:claim_next` and `:renew` never change `status` (the
  projection-ownership invariant); a claimed run still flips status only via
  `run_started`.
- **Single-node identity** — with `cluster_enabled: false`, behavior is unchanged
  (no expirations, no reclaim sweeps firing).

Multi-node tests (real reclaim across BEAM nodes) are WS6; WS1 lands with
single-node + concurrent-transaction tests.

## Open questions

- The exact `:claim_next` ordering tiebreak under contention (oldest
  `inserted_at`? priority?) — start with oldest-first, matching gust.
- Whether the Pooler is per-node-singleton or can run N per node (recommend
  one per node, like `BackfillWorker`).
- PubSub trigger topic for "new pending run" so the Pooler doesn't rely on poll
  latency for the common case.

## Cross-references

- gust G1-1 — `docs/exploration/gust/FEATURES-WORTH-BORROWING.md:88-178` (the
  mechanism + gust source `path:line` for each component).
- Squidie §4.11 — `docs/exploration/squidie/REACTOR-ADOPTION.md:659-690`.
- Squidie T2-4 — `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md:280-294`.
- Reference implementation in-repo — `lib/jido_claw/embeddings/backfill_worker.ex`.
- Next: [WS2](WS2-composer-lease.md) (composer unit), [WS3](WS3-reclaim-and-recovery.md)
  (reclaim semantics), [WS5](WS5-cross-node-cancellation.md) (uses `claimed_by`).
