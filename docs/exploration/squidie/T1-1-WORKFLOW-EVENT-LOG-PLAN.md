# T1-1 Workflow Event Log Plan

Planning note for borrowing Squidie's single most valuable idea into jido_radclaw:
**derive workflow-run status from an append-only event log instead of mutating a
status column.** This document is narrower than `FEATURES-WORTH-BORROWING.md` — it is
the focused spec for the **`WorkflowEvent` resource + append helper + recovery
reconciler**, the durable foundation the rest of the envelope builds on. It defines
what "done" means and the phased work to get there.

Baseline date: 2026-06-04.

> **Status (2026-06-09): COMPLETE, including the deferred completion-bar
> items.** The durable spine shipped in the Phase 0–3 commits; the follow-up
> pass closed the gaps that had been claimed-but-skipped:
>
> - **Completion-bar #3 (step rows)** — `WorkflowStep` is now tenant-scoped
>   and projected from `step_*` events in the append transaction
>   (identity-keyed upserts, savepoint-fenced best-effort; the dashboard step
>   view renders). The middleware enriches `step_*` payloads with the YAML
>   step name, `step_type`, an `irreversible` marker, and a JSON-safe output
>   summary.
> - **Resource mechanism (sketch divergence)** — `WorkflowEvent` and the
>   `WorkflowStep` projection ship on plain `use Ash.Resource` plus the two
>   hand-written tenant policies, **not** the Phase-1 sketch's
>   `use JidoClaw.Resource`: that macro force-injects
>   `bypass action(:by_id_global)`, which fails to compile for a resource
>   with no global-id read (the `ReputationImport` precedent). Attribute
>   multitenancy and the tenant-match policies are unchanged.
> - **Recovery §4.8 divergences** — dangling gates reconcile to `:failed`
>   with `run_recovered` + `run_failed` (+ the case cancelled, one
>   transaction), and the decision-recorded branch is re-keyed on the
>   recorded `approval_resolved` event (forbidden no-decision pairs
>   fail-with-audit).
> - **New event kinds** — `run_abandoned` (operator abandon, terminal
>   `:abandoned`) and `approval_retracted` (stale-approval retraction,
>   `:running → :awaiting_approval`) joined the vocabulary, both
>   status-authority; `AgentCaseEvent` is the per-case immutable timeline.
> - **Deliberately still deferred:** the async step-timeline `Writer` +
>   barrier (§4.3) — synchronous appends under the per-run `FOR UPDATE` lock
>   stay; an `iterative` skill projects as one step row. (The Phase 4/5
>   items this bullet originally deferred have since shipped:
>   fingerprint/replay 2026-06-09, deadlines + cron idempotency +
>   actor-visibility redaction 2026-06-10.)
>
> See `REACTOR-ADOPTION.md` § "Status reconciliation" for the full ledger.

> **Scope.** This plan assumes the decision recorded in
> [`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md): **Reactor is the workflow engine**, a
> `Reactor.Middleware` is the **primary** event producer (non-middleware writers in §4.4/§4.5 are deliberate exceptions), and the bespoke skill-DAG drivers
> (`IterativeWorkflow`, `PlanWorkflow`, `SkillWorkflow`) plus the `WorkflowRunner`
> dispatch seam are **being deleted**, not instrumented. The project is greenfield with
> no backwards-compat concern, so status is a **projection of the event log from day
> one** — there is no dual-write phase. Read *this* doc for the event-log resource and
> recovery; read the Reactor doc for how the producer and engine wire up (§4.3 producer,
> §4.8/§7 recovery & resume).

## Why

`JidoClaw.Orchestration.WorkflowRun` mutates its `status` column in place
(`lib/jido_claw/orchestration/workflow_run.ex:47-96`). Today's producer,
`WorkflowRunner.run/1`, is synchronous and in-process: it starts the run,
dispatches to an in-memory driver, then finalizes
(`lib/jido_claw/orchestration/workflow_runner.ex:57-69`). If the BEAM dies (or the
run process crashes) between `WorkflowRun.start` and `finalize_complete/finalize_fail`,
**the row is stranded in `:running` forever** — nothing reconciles it on reboot.
Reactor replaces this producer, but the failure mode is identical for *any* in-memory
engine (Reactor runs in-memory too — Reactor doc §2), which is why the durable event
log + recovery matter regardless of engine.

Three secondary gaps fall out of the same root cause:

- `WorkflowStep` rows are **never created** — the run is finalized but no step
  timeline is written (`workflow_runner.ex:120-147`). The step table and the
  dashboard's step view are dead scaffolding.
- There is **no audit trail** of what happened during a run, in what order.
- There is **no recovery, replay, or retry** substrate to build on.

An append-only event log fixes the stranding bug directly and is the substrate the
other Squidie borrows (T1-2 retry, T1-3 fingerprint/replay, T2-1 deadline) need.

## Summary

Add one append-only Ash resource, `JidoClaw.Orchestration.WorkflowEvent`, make run
status a **projection** of it, and let the **Reactor middleware** be its **primary** producer:

1. **Event log + projection** — the `WorkflowEvent` resource; `WorkflowRun.status`
   computed from events, never mutated by hand (no dual-write — greenfield). Ships the
   audit trail.
2. **Primary producer = Reactor middleware** — `JidoClaw.Workflow.Middleware` (a
   `Reactor.Middleware`) appends one event per run/step transition. Run-lifecycle events
   (`run_started`/`run_resumed`/`run_halted`/terminals via the middleware's run-lifecycle
   callbacks, plus `approval_requested`/`approval_resolved` written synchronously by the gate step / decision flow) are
   written **synchronously and durably** — all status-authority **except** `run_halted`,
   which shares the synchronous path but is durable provenance, not status (Reactor doc
   §4.1); the high-volume per-step
   timeline
   goes through an **async writer**; crash-atomic side-effect facts append **inside
   `Ash.Reactor` transactions**. (See Reactor doc §4.3 — this replaces the old
   "drivers emit step events" idea; the drivers are being deleted.)
3. **Recovery** — a boot-time reconciler **resumes only runs whose decision is already
   recorded** (clean checkpoint + a resolved gate), **leaves unresolved gates parked**
   (still awaiting the human — resuming them would skip the gate), and turns genuinely
   stranded non-terminal runs into an explicit, audited terminal state.
   *This is the original bug fix.*
4. **Replay + fingerprint** — definition hash at `run_started`; replay gates on
   mismatch + irreversible markers (T1-3).

Each item is independently shippable. These map onto Phases 0, 0/1, 4, and 4 of
[`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md) respectively — that doc sequences this
work alongside the engine adoption.

## Completion Bar

T1-1 can be called done (through recovery) when all of the following hold:

1. `JidoClaw.Orchestration.WorkflowEvent` exists as an append-only,
   tenant-scoped Ash resource with a DB-enforced **unique** `(workflow_run_id, seq)`
   index (a uniqueness/optimistic-concurrency fence — *not* monotonicity by itself;
   the unique index rejects duplicate `seq` but cannot prevent gaps or out-of-order
   values). Monotonic, gap-free `seq` is the **append helper's** job: callers never
   supply `seq`; the helper allocates it inside a per-run-serialized DB operation
   (Phase 1).
2. The Reactor middleware persists an event for every run/step transition with
   redacted payload/metadata — status-authority events **synchronously/durably, updating
   the materialized `status` column in the same transaction**, and the per-step timeline
   via the async writer (Reactor doc §4.1/§4.3).
3. `WorkflowStep` rows are projected from `step_*` events for at least one real Reactor
   workflow (or the first compiled skill), so the dashboard's step view is no longer
   empty.
4. A boot-time reconciler exists that **reconciles** every non-terminal run with no live
   execution by its projected status (Phase 3): resume **only** a run with a clean checkpoint
   *and* a recorded `approval_resolved` (the decision-already-recorded case); **leave an
   unresolved gate parked** (`:awaiting_approval` + checkpoint — still awaiting the human,
   never resumed past the gate); and for a stranded or no-decision run append `run_recovered`
   + a terminal `run_failed` (which the projection folds to `:failed` — recovery never mutates
   `status`). Proven by tests that (a) strand a `:running` row and assert it reconciles to
   `:failed`, and (b) strand an `:awaiting_approval` run with a checkpoint and assert it is
   left untouched.
5. Tenant isolation is proven: a tenant cannot read another tenant's events.
6. `mix jidoclaw.compile_check`, `mix format --check-formatted`, `mix credo`,
   and `mix test` all pass. (Per AGENTS.md the gate is `jidoclaw.compile_check`,
   not `compile --warnings-as-errors`.)

Replay + fingerprint (T1-3, Phase 4) is explicitly *not* required for "done" — it is a
follow-up.

## Current Baseline (verified)

The current orchestration code — the seam Reactor replaces:

- **`WorkflowRun`** — `use JidoClaw.Resource` (tenant-scoped, policies, AshPostgres).
  Status enum `[:pending, :running, :awaiting_approval, :completed, :failed, :cancelled]`
  (`workflow_run.ex:141`). `has_many :steps` + `:approval_gates`
  (`workflow_run.ex:214-215`). Multitenancy attribute on `tenant_id`; has a
  `by_id_global` read with `multitenancy(:bypass)` (`workflow_run.ex:103-108`). Stays as
  the durable run handle; its `status` becomes a projection.
- **`WorkflowStep`** — plain `use Ash.Resource` (note: **not** the tenant-scoped
  `JidoClaw.Resource` wrapper). create/start/complete/fail/skip actions exist;
  nothing calls `create`. Will be populated by the step-event projector (Phase 2).
- **`ApprovalGate`** — create/approve/reject; `WorkflowRunner` never awaits it. Grows
  into `AgentCase` + `AgentCaseEvent` under the Reactor human-gate work (Reactor doc
  §4.5 / FEATURES T1-4) — out of scope for this doc.
- **`WorkflowRunner` + the three drivers** — the current sole producer, driven by
  `Cron.Dispatcher` for `target: :workflow` jobs (`platform/cron/dispatcher.ex:37`).
  `create_and_start/4` (`workflow_runner.ex:89-118`) creates fresh runs with **no
  dedupe/fingerprint**; `do_execute_and_finalize/5` dispatches to `IterativeWorkflow` /
  `PlanWorkflow` (DAG) / `SkillWorkflow` and finalizes (`:130-147`). **This seam is
  deleted** by the Reactor adoption — the **primary** event producer becomes the
  middleware, not this dispatcher.
- **Base macro** — `JidoClaw.Resource` (`lib/jido_claw/resource.ex`) emits the
  standard tenant policy and `use Ash.Resource, data_layer: AshPostgres.DataLayer`.
  Its read policy references a `tenant_id` attribute, so any resource using it must
  declare `tenant_id` + `multitenancy`.
- **Redaction** — `lib/jido_claw/security/redaction/patterns.ex` (and siblings)
  scrub secrets; reuse for event payloads.
- **Migrations** — Ash codegen: `mix ash.codegen <name>` then `mix ecto.migrate`
  (aliases: `mix.exs` `setup: ["deps.get", "ash.setup"]`).

## Phase 1 — `WorkflowEvent` resource + projection

**New resource** `JidoClaw.Orchestration.WorkflowEvent` (the `kind` vocabulary matches
the Reactor-shaped set in Reactor doc §4.2):

```elixir
defmodule JidoClaw.Orchestration.WorkflowEvent do
  @moduledoc false
  use JidoClaw.Resource, domain: JidoClaw.Orchestration

  postgres do
    table("workflow_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      # Uniqueness fence (optimistic concurrency) — NOT monotonicity. The unique
      # index rejects a duplicate (workflow_run_id, seq) but cannot prevent gaps or
      # out-of-order seq; monotonic allocation is the append helper's job (below).
      # It also serves range/sort queries on (workflow_run_id, seq), so no separate
      # non-unique index is needed.
      index([:workflow_run_id, :seq], unique: true)
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  # Append-only: read + a single create. No update, no destroy.
  actions do
    defaults([:read])

    create :append do
      primary?(true)
      # NOTE: `seq` is deliberately NOT accepted — callers must not supply it.
      # The append helper allocates `seq` inside a per-run-serialized transaction
      # (advisory lock on workflow_run_id, or SELECT … FOR UPDATE on the run row)
      # and sets it internally, so a caller cannot inject an out-of-order or
      # duplicate value. The unique (workflow_run_id, seq) index is the backstop.
      accept([:workflow_run_id, :kind, :payload, :metadata, :occurred_at])
    end

    read :for_run do
      argument(:workflow_run_id, :uuid, allow_nil?: false)
      prepare(build(sort: [seq: :asc]))
      filter(expr(workflow_run_id == ^arg(:workflow_run_id)))
    end

    # NOTE: recovery does NOT scan this table by kind — a completed run still has
    # `run_started`/`step_*` events, so a kind filter cannot identify non-terminal
    # *runs*. The boot reconciler queries `WorkflowRun` by projected status instead
    # (Phase 3), with `authorize?: false`: `multitenancy(:bypass)` drops only the
    # tenant *filter*, not the read *policy* (`JidoClaw.Resource` requires
    # `tenant_id == actor(:tenant_id)` and bypasses authz only for `:by_id_global` —
    # `lib/jido_claw/resource.ex:44-56`). Use `:for_run` to fold one run's events.
  end

  attributes do
    uuid_primary_key(:id)
    attribute :tenant_id, :string, allow_nil?: false, public?: true
    attribute :seq, :integer, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :run_started, :run_resumed,
          :step_started, :step_completed, :step_failed, :step_retried,
          :step_compensated, :step_undone,
          :approval_requested, :approval_resolved,
          :run_halted, :run_completed, :run_failed, :run_cancelled, :run_recovered
        ]
      ]

    attribute :payload, :map, default: %{}, public?: true
    attribute :metadata, :map, default: %{}, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :workflow_run, JidoClaw.Orchestration.WorkflowRun do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end
  end
end
```

Register it in `JidoClaw.Orchestration` (`lib/jido_claw/orchestration.ex:19-23`)
and add `has_many :events` to `WorkflowRun`.

**Append helper — the sole allocator of `seq`** — a small module (or code-interface
wrapper). Callers pass `(run, kind, payload)`; the helper allocates `seq` itself, **never
the caller** (the `:append` action does not accept `:seq`). It allocates inside a
**per-run-serialized** DB operation — a Postgres advisory lock keyed on `workflow_run_id`,
or `SELECT … FOR UPDATE` on the parent run row, taken in the same transaction — so
concurrent appends for one run serialize and `seq` is gap-free and strictly increasing in
commit order. The unique `(workflow_run_id, seq)` index is the backstop, not the primary
mechanism (mirrors Squidie's `expected_rev` fencing, but the lock removes the read-then-
write race rather than relying on conflict-retry). For **status-authority** kinds the helper
also updates the materialized `WorkflowRun.status` column **in the same transaction**
(Reactor doc §4.1/§4.3), so a reader never sees the event without the status it implies;
per-step timeline kinds only append.

The helper is also the **per-run serialization point** the async writer relies on for
ordering (see the durability-boundary risk below): step-timeline appends for one run go
through it in FIFO order, and a synchronous terminal/halt append **flushes that run's
pending step events before it commits**, so the terminal always holds the run's maximum
`seq` and no step event can be sequenced after it.

```elixir
# helper allocates seq under a per-run lock, in the same txn as the status update
WorkflowEvent.append(run, :run_started, payload, tenant: t, actor: a)
```

Scrub `payload`/`metadata` inside the helper, before persist, with a **recursive,
key-aware** redactor — **not** `JidoClaw.Security.Redaction.Patterns.redact/1`, which only
regex-scans *binaries* and passes any non-binary (i.e. a map) straight through unchanged
(`lib/jido_claw/security/redaction/patterns.ex:44-51`). Event payloads/metadata are maps,
so `Patterns.redact/1` on them is a **no-op** — secrets persist verbatim. Use the existing
recursive scrubber `JidoClaw.Security.Redaction.Transcript.redact/2`
(`security/redaction/transcript.ex`): it walks maps/lists, scrubs string leaves through
`Patterns`, and replaces values under sensitive **key names** with `"[REDACTED]"`. One
gap to close: `Transcript` decides sensitivity via `Redaction.Env.sensitive_key?/1`, whose
*suffix-only* rule (`_KEY`/`_TOKEN`/`_SECRET`/`_PASSWORD`/`_PASS`/`_PAT`) matches
`api_key`/`access_token`/`refresh_token`/`private_key` but **misses the bare keys**
`password`, `secret`, `token`, `authorization`, `credential` — exactly the shape an event
map carries. Add those bare names to the event redactor's key set, cross-referenced against
Squidie's list (`squidie/lib/squidie/runtime/dispatch_protocol.ex:336-349`: `access_token`,
`api_key`, `authorization`, `claim_token`, `credential`, `password`, `private_key`,
`refresh_token`, `secret`, `token`).

**Status is a projection from day one.** There is nothing to dual-write against
(greenfield), so do not mutate `WorkflowRun.status` by hand. `status` folds the run's
events into a value (Reactor doc §4.1), materialized as a **projection-owned `status`
column** written **only** by the projection (a pure calculation/aggregate won't back
§4.11's `(status, claim_expires_at)` claim index/lock — Reactor doc §4.1). The **primary** producer is the Reactor
middleware (Reactor doc §4.3); this doc specifies the resource + append helper that the
middleware (and the in-transaction side-effect appends) call into. The append helper is
the seam both producers share.

**Migration**: `mix ash.codegen add_workflow_event_log && mix ecto.migrate`.

**Tests**: append produces ascending `seq`; concurrent appends don't collide
(unique index + retry); a Reactor run produces `run_started → … → run_completed`
(or `… → run_failed`); a tenant can't read another tenant's events via `for_run`.

## Phase 2 — Step events populate `WorkflowStep`

The Reactor middleware emits `step_started`/`step_completed`/`step_failed`/`step_retried`
(and `step_compensated`/`step_undone`) per step transition via the async writer (Reactor
doc §4.3). Add a thin projector that upserts `WorkflowStep` rows from those events, using
the existing `WorkflowStep.create/start/complete/fail` actions (already defined, currently
unused). Because the events are appended *as steps transition* — not reconstructed from a
return value after the fact — a crash mid-run still leaves a partial, accurate step
timeline, which is the whole point.

Start with one real Reactor workflow (the Phase 1 candidate in the Reactor doc — e.g. the
cron→workflow path or a "branch + commit + open PR" flow); the DAG topology maps cleanly
to `WorkflowStep` rows with `sequence` derived from event order.

Flag: `WorkflowStep` uses plain `use Ash.Resource`, not the tenant-scoped
`JidoClaw.Resource`. Decide whether to migrate it to the wrapper for consistency, or
leave it (it's a child of a tenant-scoped run). Recommend migrating for uniform
tenant policy. *(Resolved 2026-06 the other way: it stays plain — and `WorkflowEvent`
is plain too — because the wrapper force-injects a `bypass action(:by_id_global)` that
doesn't compile for resources without that read; both hand-write the standard tenant
policies, with attribute multitenancy as usual.)*

**Tests**: a Reactor run creates one `WorkflowStep` per step with correct
status/sequence/output; a step failure records `step_failed` + a failed `WorkflowStep`.

## Phase 3 — Boot-time recovery (the bug fix)

Add `JidoClaw.Orchestration.WorkflowRecovery`, run once at application start
(a `Task` child in the supervision tree, after `Repo`). Reactor's in-memory run dies
with the node (Reactor doc §2), so recovery still matters under Reactor exactly as it
did under the drivers.

Algorithm (per Reactor doc §4.8/§7):

1. Scan all non-terminal runs across tenants by **projected status** (`status in
   [:pending, :running, :awaiting_approval]`) on `WorkflowRun` — *not* by scanning
   `WorkflowEvent` kinds (a completed run still has `run_started`/`step_*` events). Run it
   with **`authorize?: false`**: this is a cross-tenant system scan, and
   `multitenancy(:bypass)` drops only the tenant *filter*, not the read *policy*
   (`JidoClaw.Resource` requires `tenant_id == actor(:tenant_id)` and bypasses authz only
   for `:by_id_global` — `lib/jido_claw/resource.ex:44-56`).
2. For each, branch on **whether a human decision is still outstanding** — recovery must
   **never resume an unresolved gate.** Reactor's resume re-runs the retained halted struct,
   and a halted step is **dropped from the plan with its halt value stored as its result**
   (`reactor/lib/reactor/executor/sync.ex:99`; proven by `executor_test.exs:129`, where
   re-running a halted reactor completes using the halt value and the halted step never
   re-runs). So blindly resuming an `:awaiting_approval` run would sail **past** the gate as
   if it had produced a value — with no decision taken. The branch is therefore on the
   *projected status*, which already encodes resolution (Reactor doc §4.1: an unresolved
   `approval_requested` projects to `:awaiting_approval`; a resolved gate projects to
   `:running`):
   - **`:awaiting_approval` + checkpoint exists** → **leave it parked.** This run is *not*
     stranded; it is correctly waiting for a human, and its operator-inbox `AgentCase` is
     still open. Recovery does nothing to it (optionally re-arms a deadline read-model).
     Resumption happens only when the operator approves/rejects (Reactor doc §4.5), **never**
     from boot recovery.
   - **`:awaiting_approval` + no checkpoint** → the crash hit *between* the gate committing
     its `AgentCase` + `approval_requested` and the checkpoint persisting (Reactor doc §4.5
     step 2). The case is real but unresumable → fail-with-audit **and** resolve the dangling
     gate: append `run_recovered` (provenance) + the terminal `run_failed` + `approval_resolved`
     (cancelled-by-recovery) + cancel/fail the pending `AgentCase` with a case event, so the
     operator inbox doesn't show an approval that can never resume. Write this whole batch in
     **one transaction**: the reconciler scans only non-terminal runs, so a crash after
     `run_failed` but before case cleanup would orphan the case permanently (alternatively,
     an idempotent follow-up sweep for terminal-failed runs with unresolved gates).
   - **`:running`/`:pending` + clean checkpoint + a recorded `approval_resolved`** → the
     **decision-already-recorded** case: the operator approved/rejected, the gate flipped the run
     to `:running` and recorded `approval_resolved` (Reactor doc §4.5 step 4), but the process
     crashed before/within the resuming `Reactor.run/4`. Key the branch on the recorded
     `approval_resolved`, **not on the checkpoint alone** — a checkpoint with no decision is a
     non-gate halt that should never have happened (Reactor doc §4.3 forbids them), with nothing
     to re-inject, so it falls through to fail-with-audit like the no-checkpoint case below.
     With the decision in hand: resume the reactor, **re-injecting the recorded decision through
     context** (`Reactor.run(reactor, original_inputs, %{approval: decision})` — *not* as a
     fresh input; the gate's downstream steps must read the decision from context, since the
     halted step's "result" is the halt value, not the decision). The middleware's `init/1`
     appends `run_resumed` automatically on the `:halted` branch (Reactor doc §4.3), so recovery
     does **not** append it itself; pass provenance (e.g. `recovered: true`) via context.
   - **`:running`/`:pending` + no checkpoint** (mid-step VM crash, no gate involved) →
     **append** `run_recovered` (provenance) **and** the terminal `run_failed`; the projection
     folds `run_failed` to `:failed`.

Recovery policy for the no-checkpoint case — default to **fail-with-audit**, not
auto-resume:

- Appending `run_recovered` + `run_failed` (payload `%{reason: "recovered after restart",
  prior_status: …}`) is the safe default — **never call a direct status-mutation action
  like the old `WorkflowRun.fail`; status is a projection (Phase 1), so recovery records
  facts and lets the projection move the run to `:failed`.** Re-running may repeat
  non-idempotent side effects (email sent, commit pushed), and a crashed reactor's
  in-memory undo stack is gone, so you cannot safely auto-compensate a half-finished run
  after reboot.
- Auto-resume / re-enqueue is **opt-in per workflow** and gated on T1-3 irreversible
  markers (a follow-up). Don't auto-resume until idempotency is declared.

Emit a `[:jido_claw, :orchestration, :recovered]` telemetry/Trace event per
reconciled run so the recovery is visible in the dashboard. (In a clustered deployment,
lease expiry — Reactor doc §4.11 — handles dead-node recovery continuously; this boot
reconciler is the single-node restart case.)

**Tests**: insert a `:running` `WorkflowRun` with no terminal event, run the
reconciler, assert status **projects** to `:failed` and both a `run_recovered` and a
`run_failed` event exist; assert terminal runs are untouched; assert it's tenant-blind
(reconciles every tenant's stranded runs). **Gate cases** (once the human-gate machinery
lands — Reactor doc §4.5): (a) **parked gate must survive** — strand an `:awaiting_approval`
run *with* a checkpoint, run the reconciler, and assert it is **left untouched**: still
`:awaiting_approval`, its `AgentCase` still open, **no** `run_failed`/`approval_resolved`
appended, and it remains resumable on a later operator decision (recovery must not bypass
the pending gate); (b) **dangling gate must be cleaned** — strand an `:awaiting_approval`
run with an open gate and **no** checkpoint, run the reconciler, and assert `run_recovered`
+ `run_failed` + `approval_resolved` are appended, the pending `AgentCase` is
cancelled/failed, and a case event is recorded — no inbox approval left unresumable.

## Phase 4 — Replay gates + cron idempotency (follow-up, optional)

> **Shipped:** T1-3 fingerprint + replay 2026-06-09 (see `REACTOR-ADOPTION.md` §4.7's
> implementation note); T2-3 cron idempotency 2026-06-10 (a generic `:idempotency_key`
> opt on `ReactorRunner.run/3` — see the FEATURES T2-3 shipped note).

Status is already a projection from Phase 1 — there is no dual-write to retire here.

- Add T1-3: hash the resolved skill YAML / reactor definition at `run_started`; a
  `WorkflowRun.replay` action recomputes and refuses on mismatch. Add `irreversible:` /
  `compensatable:` markers gating replay and Phase-3 auto-resume.
- Add T2-3 cron idempotency: deterministic `cron:<job_id>:<window>` run key + unique
  index so a double-delivered tick returns the existing run.

## Risks & decisions

- **Durability boundary (the key one)**: status is projected from the event log, so the
  *status-authority* events it folds (`run_started`/`run_resumed`/terminals, plus
  `approval_requested`/`approval_resolved`) must be durably persisted — **and the
  materialized `status` column updated in the same transaction** — **before the run returns
  or advances**, written synchronously (not via the async writer; Reactor doc §4.1/§4.3).
  `run_halted` shares that synchronous, durable path but is **provenance, not
  status-authority** — it updates no status column (Reactor doc §4.1). Only the high-volume
  per-step timeline is eventually-durable. Get this wrong (a terminal event
  lost in the async window) and the reconciler would fail a run that actually completed.
- **`seq` allocation**: the append helper is the **sole** allocator — `seq` is assigned
  inside a per-run-serialized DB operation (advisory lock on `workflow_run_id` or
  `SELECT … FOR UPDATE` on the run row), never accepted from callers and never generated in
  application memory. The DB unique `(workflow_run_id, seq)` index is the backstop, not the
  primary mechanism. ("DB-enforced *monotonic*" overstated it — the index enforces
  *uniqueness*; the lock is what makes allocation monotonic and gap-free.)
- **Total ordering under the mixed sync/async writers**: the single per-run `seq` reflects
  **commit** order, not occurrence order. Because the run-lifecycle spine is written
  synchronously while the step timeline is `cast` to an async writer, a `step_completed`
  still queued in the writer could otherwise be allocated a `seq` *after* the synchronously
  written `run_completed` — contradicting "the terminal is a run's last event." Resolve it
  with the helper's per-run barrier: (1) the async writer preserves **per-run FIFO** so a
  run's step events commit in occurrence order; (2) the synchronous terminal/halt append
  **flushes that run's pending step events before it commits**, guaranteeing the terminal
  holds the maximum `seq`. The step timeline is therefore **best-effort observability that
  may trail the lifecycle spine within a run but never crosses the run's terminal**; the
  synchronously written spine is the ordering authority. (A crash in the `cast`→write window
  can still drop a trailing step event — acceptable because the timeline is **best-effort
  observability, not status authority**: the loss leaves it incomplete after a crash but
  cannot corrupt status or recovery, which fold the synchronous spine. It is *not* guaranteed
  reconstructable — the lost `step_*` fact has no other durable source unless the resume
  checkpoint is promoted to record step outputs (Reactor doc §7), which is the unproven path.)
- **Recovery aggressiveness**: fail-with-audit is intentionally conservative.
  Revisit only with explicit per-skill idempotency (T1-3).
- **`WorkflowStep` tenancy**: resolve the plain-`Ash.Resource` inconsistency in
  Phase 2.
- **Durable halt-state (Reactor doc §7)**: cross-restart resume of a *paused* reactor is
  the genuinely hard part — decide the resume strategy there (the persist-struct vs
  reconstruct-from-events question) before building the human gate.

## Out of scope

- **The engine replacement itself** — retiring the skill-DAG drivers and compiling
  skills to Reactor lives in [`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md), not here.
  This doc scopes only the event-log resource + recovery.
- **Human gates / `AgentCase`** — the case + immutable-event model and the human-gate
  DSL (FEATURES T1-4 / T2-5, Reactor doc §4.5) build *on* this event log but are their
  own work.
- **Lease/fencing for multi-worker execution** (T2-4 / Reactor doc §4.11) — land the
  data model with `WorkflowRun`; defer implementation until clustering is real.
- **Saga / compensation** — native to Reactor (`compensate` + opt-in `undo`); see
  `FEATURES-WORTH-BORROWING.md` S-1 and Reactor doc §4.6. Not a hand-rolled walker.
- **The cron subsystem** — stays as-is (more capable than Squidie's; take only the
  T2-3 idempotency idea).
