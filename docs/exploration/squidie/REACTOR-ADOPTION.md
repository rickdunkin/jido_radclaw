# Adopting Reactor as JidoClaw's Workflow Engine

*(with the Squidie-borrowed durable envelope)*

Architecture direction — not a commitment. Baseline **2026-06-04**. Builds on
[`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) and the
[`T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](T1-1-WORKFLOW-EVENT-LOG-PLAN.md).

---

## Status reconciliation — 2026-06-10 (Phases 0–5 complete)

*Re-verified against the tree, `mix.lock`, and the Squidie/SquidSonar checkouts
2026-06-11: everything below still holds. Only dep drift: `ash` is now locked at
3.27.8 (`reactor` unchanged at 1.0.2, still non-optional via ash). Upstream
Squidie shipped 0.2.0 on 2026-06-10 — inventory impact recorded in
[`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md)'s 0.2.0 note; nothing
in it changes this plan.*

Phases 0–3 are **implemented and tested**, including the items the original
phase commits claimed but deferred; **Phase 4 (definition fingerprint +
replay, T1-3) shipped 2026-06-09** — see §4.7's implementation note for what
diverged from the sketch; **Phase 5 (read-models + graph viz: T2-1, T2-2,
T2-3, T3-1/T3-2) shipped 2026-06-10** — see the Phase 5 block below. What
shipped beyond the durable spine:

- **§4.11 claim/fencing data model + behavior** — `claimed_by` / `claim_expires_at` /
  `claim_token` columns + the two **global** (`all_tenants?: true`) scan
  indexes landed on `WorkflowRun` (2026-06-10), and the Pooler/Lease
  *implementation* (`:claim_next`, heartbeat/renew, reclaim, `:pg` leader — the
  multi-node story) **has since shipped in full** as the clustering workstream
  (WS1–WS5 + WS4a, 2026-06-27..30 — `docs/plans/clustering/`; see §4.11 below).
  **Kill-based single-node live-run cancellation shipped separately 2026-06-10**
  (next bullet), and WS5 made it cross-node-correct.
- **Live-run cancellation (2026-06-10)** — every `Reactor.run` (both
  chokepoints: `ReactorRunner.execute` and `GateResume.run_reactor`, so
  `Replay`/`WorkflowRecovery`/cron inherit) now executes in a registered
  killable task (`RunExecution.run_killable/4`: `RunRegistry` +
  `RunTaskSupervisor`, registration **before** `Reactor.run`, duplicate
  registration → `{:already_running, pid}` without touching the run).
  `Cancellation.cancel/2` routes: terminal → `:already_terminal`; parked
  `:awaiting_approval` → **delegates to `Cases.abandon/3`** (ends
  `:abandoned`, not `:cancelled`); live `:pending`/`:running` →
  **durable-decision-first** — `run_cancelled` + pending-case cancellation in
  one transaction (`WorkflowLog.terminate_cancelling_cases/4`), *then* the
  tenant-checked `Process.exit(pid, :kill)`, never a kill after a failed
  append (a completion race reloads to a clean `:already_terminal`). The
  caller side maps a killed/late-appending executor to
  `{:error, :cancelled, run}` via reload-first finalize. Accepted
  limitations: already-started async-step work may run to completion into
  the void (nothing new schedules — a workflow kill switch, not a side-effect
  interrupt), and the executor outlives a dead caller (`async_nolink`;
  terminals land via middleware, skipped caller-side bookkeeping is reaped by
  recovery's dangling-gate/stranded branches). Surface is **dashboard-only**
  (`WorkflowsLive` Cancel button + `data-confirm`), matching the
  replay-overrides precedent — no CLI/MCP cancel. Review follow-ups: the
  cancel-before-register race is also closed on the **resume** path
  (`ReactorMiddleware` hard-stops a resume whose `run_resumed` append fails
  against a terminal run), `Cases.abandon/3` now emits the `{:run_abandoned,
  …}` run-lifecycle broadcast (dashboard refresh for parked-run cancels), and
  the parked-run delegation carries `decided_by_id` for audit parity.
- **Step projection (T1-1 #3)** — `WorkflowStep` is tenant-scoped (the
  `WorkflowEvent` policy shape) and projected from enriched `step_*` events
  (YAML name + `step_type` + JSON-safe output summary) inside the append
  transaction, via identity-keyed upserts under a savepoint (best-effort:
  never rolls back the append). The dashboard run view expands per-run steps.
- **T1-2 per-step `retry:` / `compensate:` / `irreversible:`** — YAML surface
  → compiler validation → Reactor `max_retries` + the `compensate/4 → :retry`
  policy on `AgentStep`/`IterativeStep`; `can?/2` derives capability per step;
  `irreversible: true` rides into `step_*` payloads for the Phase-4 replay
  gates.
- **T2-5 gate Spark DSL** — `JidoClaw.Orchestration.Gate.Dsl`
  (+ `HumanGate` base, `Gate.Info`, select-options verifier), with **all
  three kinds declared** (`tool_call`, `plan`, `irreversible_write`); only
  `irreversible_write` has a live producer. `GateStep` derives `kind` solely
  from the DSL; `Gate.Kinds` single-sources the enum shared with
  `AgentCase.kind`.
- **T1-4 `AgentCaseEvent`** — the immutable per-case timeline (per-case `seq`
  under `FOR UPDATE`, unique `(agent_case_id, seq)` fence), appended in the
  same transaction as every case transition (opened/approved/rejected/
  cancelled/abandoned/retracted).
- **AR-1 gate lifecycle** — operator `abandon` (`run_abandoned` →
  `:abandoned`, **only** from `:awaiting_approval`; the projection guard
  refuses live runs) and stale-approval `retract` (`approval_retracted`:
  `:running → :awaiting_approval`, case reopened with decision data cleared,
  fenced on no-`run_resumed`-after-`approval_resolved` under the per-run
  lock). `Cases.decide/4` gained the `resume: false` commit-only seam that
  makes the pre-resume window real; the live re-plan trigger arrives with the
  future `plan`-gate producer. *(The retract half was removed 2026-07-02 —
  vestigial, no production caller; the composer's signal-axis retraction
  superseded it.)*
- **§4.8 recovery fixes** — dangling gate now reconciles to **`:failed`**
  with the full audit (`run_recovered` + `run_failed` + case cancelled, one
  transaction); the `:running`+checkpoint branch is re-keyed on the recorded
  `approval_resolved` event (no decision → fail-with-audit, never
  blind-resume).
- **Checkpoint encryption (Decision 2 fast-follow)** — `resume_checkpoint`
  is AshCloak-encrypted at rest (`encrypted_resume_checkpoint`); presence
  checks read the encrypted column; only `GateResume` decrypts; terminal
  clears force true SQL NULL (never ciphertext-of-nil).
- **Trace overlay** — the middleware emits `[:jido_claw, :workflow, :event]`
  via `JidoClaw.Trace.emit/3` on every run-lifecycle hook.

**Phase 5 (2026-06-10) — read-models + graph viz, with what diverged:**

- **T2-3 cron idempotency** — landed as a generic `:idempotency_key` opt on
  `ReactorRunner.run/3` (read-first → create → `:unique_run_idempotency`
  violation backstop → `{:ok, {:existing_run, id}, run}` with **zero** launch
  work on a hit), NOT the sketched upsert-in-`WorkflowRunner` — the caller
  must distinguish created-vs-existing to skip execution. Keys derive only
  from explicit firing provenance: `Cron.Worker.execute_job/2` stamps
  `fire: {:scheduled, next_run}` on a **local dispatch copy** (never stored
  GenServer state), `WorkflowRunner` derives
  `cron:<job_id>:<iso8601 window>`; manual triggers and non-worker callers
  always run keyless. The unique index is tenant-prefixed with NULLS
  DISTINCT.
- **T2-1 deadlines** — pure `JidoClaw.Orchestration.Deadline`
  (Squidie-faithful validation/math: required positive `within`, optional
  non-negative `due_soon < within` / `escalate_after`, inclusive bounds,
  undeclared thresholds unreachable) at run **and** step level,
  explicit-declaration only. Units are **seconds** (Squidie's ms is an
  internal unit; this YAML is human/LLM-edited). Run policy rides
  `config["deadline"]` through all three launch sites (cron, `RunSkill`,
  `Replay` — skill replays carry the freshly re-resolved `skill.deadline`,
  module replays preserve the original's); step policy rides the
  `irreversible:` rails into projected `WorkflowStep.deadline`; iterative
  deadlines are loop-level only (declared on the generator). Evidence is
  `%{status, due_at, due_soon_at, escalate_at, overdue_by_ms}` with an
  always-present non-negative `overdue_by_ms` (deliberately not Squidie's
  signed `remaining_ms`); terminal anchors freeze at `completed_at`.
  Deadlines are **excluded from the definition fingerprint** (observability,
  not execution semantics — a deadline-only YAML edit replays un-forced).
  Dashboard gets Deadline badge columns + a 30s lateness-refresh timer;
  `workflow_status` gains an additive `deadline` key.
- **T2-2 actor-visibility** — `JidoClaw.Orchestration.Visibility`
  (`run_view/3`, `step_view/3`, `redact_error/2`; scopes
  `:operator | :auditor`, always explicit, with an explicit `now`).
  `WorkflowRun.result`/`error` + `WorkflowStep.output`/`error` flipped
  `public?(false)` (AshAdmin payload visibility is gone — accepted; the
  dashboard's per-run "Reveal payloads" toggle is the replacement surface).
  LLM/MCP surfaces are permanently operator-scoped: the legacy
  `run_to_map` key set + `deadline`, key-filtered result summary, and
  redact-**before**-truncate errors; operator step views carry **no output
  key at all**. The auditor scope (reveal) returns full payloads still
  `Transcript`/`Patterns`-scrubbed — defense in depth, because the run/step
  columns store RAW values (only event payloads are redacted at append).
- **T3-1/T3-2 graph viz** — `JidoClaw.Web.Components.GraphLayout` ported
  from SquidSonar (Apache-2.0 attribution; deadline/recovery node-height
  variants deleted), a `StepGraph` adapter, and a CSS-positioned-div
  `workflow_graph/1` component behind a Graph/Table toggle (graph default).
  Divergences from the sketch: edges come from a new **durable
  `WorkflowStep.depends_on` column** (the compiler-stamped
  `depends_on ∪ consumes` union; in **dag mode only**, the synthetic
  collect additionally stamps its named-step list) rather than being derived
  from `sequence` — the sequence chain is only the fallback when no step
  declares an edge; sequential and iterative runs stamp nothing (sequential
  skills are unnamed by construction — any named step routes to dag) and
  take that fallback, chaining through the collect. The collect row projects
  with `sequence 0`, so the adapter ranks it last to keep its incoming
  edges forward (the layout drops back-edges). The second sketched adapter
  (AgentTracker spawn lineage) was not built. Nodes carry metadata only —
  never payloads (composes with T2-2).

**Accepted limitations (deliberate, recorded):**

- An `iterative` skill projects as **one** `WorkflowStep` row (`step_type:
  "iterative"`) — its inner generator/evaluator turns are invisible to
  Reactor `event/3`. The hand-rolled `iterate/5` loop stays (no `map`/
  `recurse` rewrite).
- The async step-timeline `Writer` + barrier (§4.3) remains deferred —
  appends are synchronous under the per-run `FOR UPDATE` lock, which is
  strictly safer at current scale.
- A gate step's row stays `:running` after resume (the halted step is
  dropped from the plan and never re-runs; `{:run_halt, _}` is unmapped).
- Dashboard lateness is timer-refreshed (30s re-render), not event-pushed —
  deadline thresholds cross without any event, so a small poll is the honest
  mechanism.

**Next-phase scope:** the §4.11 lease *implementation* **has since shipped**
(the clustering workstream WS1–WS5 + WS4a, 2026-06-27..30 — `docs/plans/clustering/`);
what remains NOT started is the async step-timeline `Writer`. (Live-run cancellation
shipped 2026-06-10, made cross-node-correct by WS5 — see the status bullet above.)

---

**Premise (from the project owner):** this is greenfield under heavy development.
There is **no concern for compatibility layers, data migration, or backwards
compatibility.** The existing skill-DAG drivers (`IterativeWorkflow`,
`PlanWorkflow`, `SkillWorkflow`) and the thin `WorkflowRun` status machine can be
**replaced outright** by a better long-term design. The goal is correctness and
completeness of capability, not preservation of what's there.

## TL;DR — the target

**One execution engine wrapped in one durable envelope.**

- **Engine:** Reactor / `Ash.Reactor` (`reactor 1.0.2`, already a non-optional dep of
  `ash` — 3.27.8 in today's lock — **zero new dependencies**, and `runic` is *not* needed). Reactor owns
  the DAG, concurrency, saga compensation and **opt-in** durable undo (declared per
  step — §4.6), step retry/backoff, and the pause/resume primitive.
- **Envelope:** the concepts borrowed from Squidie — an append-only **event log**
  (system of record), **status-as-projection**, **crash recovery**, **human gates**
  (durable halt/resume), **replay** (definition fingerprinting), and **read-models**
  (deadlines, actor-visibility redaction, cron idempotency).
- **Everything that is a "workflow" runs through this** — developer-authored
  orchestration *and* LLM-authored skills (compiled to Reactor via `Reactor.Builder`).
  The bespoke skill drivers are retired.
- **What stays out:** the agent's ReAct loop and the swarm. Those are dynamic and
  unbounded; Reactor is for bounded, declared pipelines.

The rest of this document is the why and the how.

---

## 1. The two layers

```
┌───────────────────────────────────────────────────────────────────────┐
│  DURABLE ENVELOPE  (borrowed from Squidie, implemented Ash-native)      │
│                                                                         │
│   WorkflowRun (status = projection)   WorkflowEvent log (system of      │
│                                        record, append-only)             │
│   AgentCase + AgentCaseEvent          Recovery reconciler (boot)        │
│   (human decisions)                   Replay + definition fingerprint   │
│   Read-models: deadlines,             Cron idempotency (run identity)   │
│   actor-visibility redaction                                            │
│                                                                         │
│        ▲ events            ▲ halt/resume         ▲ fingerprint/run_id   │
│        │                    │                      │                     │
│   ┌────┴──────────────── Reactor.Middleware ───────┴──────────────┐     │
│   │  (the single seam: every step/run transition → an event)      │     │
│   └────────────────────────────┬─────────────────────────────────┘     │
├────────────────────────────────┼────────────────────────────────────────┤
│  EXECUTION KERNEL (Reactor)     │                                        │
│                                 ▼                                        │
│   Reactor.run/4 → DAG resolution, async/max_concurrency, timeout         │
│   compensate + undo (saga)   step max_retries/:retry (backoff)           │
│   {:halt} pause/resume        Ash.Reactor steps (create/update/destroy/  │
│                               action/bulk_*/transaction) w/ durable undo │
└───────────────────────────────────────────────────────────────────────┘
        ▲                                   ▲
        │ declared as Ash.Reactor modules   │ compiled from YAML via Reactor.Builder
   developer-authored workflows        LLM-authored skills
```

The envelope never reaches into the kernel's execution; it observes (via middleware),
persists (events), and drives lifecycle (run / halt / resume / replay). The kernel
never knows about tenancy, dashboards, or audit — it just runs steps.

## 2. What Reactor provides natively (verified) — and its one gap

Verified against `reactor 1.0.2` docs in-tree:

| Capability | Detail |
| --- | --- |
| Dependency-resolving DAG | Steps declare `argument`s; Reactor derives execution order. |
| Concurrency | `Reactor.run/4` opts: `async?` (default true), `max_concurrency`, `timeout`, `max_iterations`. |
| Saga: compensation | `compensate/4` runs on a step error; can return `:retry`, `{:continue, val}`, or roll back. |
| Saga: undo | `undo/4` rolls back **already-successful** steps when a later step fails the run. |
| Retry + backoff | `compensate` → `:retry`, capped by `step.max_retries`; backoff patterns documented. |
| Pause/resume | A step/guard returns `{:halt, …}`; `Reactor.run` returns the halted reactor; resume by re-running with that struct (completed steps are **not** re-run). |
| Lineage | `Reactor.run/4` takes a `run_id`; `fully_reversible?` keeps the completed reactor for later reversal. |
| Hook seam | `Reactor.Middleware` — `init/1`, `event/3` (per step/run transition), `complete/2`, `error/2`, `halt/1`, plus `[:reactor, :step, …]` telemetry. |
| Programmatic build | `Reactor.Builder` (`new`, `add_input`, `add_step`, `return`) — explicitly for **dynamic** construction (the docs cite React-Flow-style UIs). |
| Compositional steps | `map` (iterate), `switch` (branch), `compose` (embed a sub-reactor), `recurse`, `group`, `around`, `collect`, … |
| Ash-aware steps | `Ash.Reactor`: `create`/`update`/`destroy`/`action`/`read_one`/`bulk_*`, transaction grouping, and **declarable per-step `undo`**. |

**The one gap:** Reactor runs **in-memory**. There is no built-in journal that survives
a VM crash, and a halted reactor is only as durable as you make it. That gap is exactly
what the envelope fills — and it's the reason we still want the Squidie concepts even
after adopting Reactor.

## 3. How each borrowed concept maps to Reactor

| Concept (FEATURES doc) | Relationship | Resolution |
| --- | --- | --- |
| T1-1 event log | **wraps** | A `Reactor.Middleware` emits a `WorkflowEvent` per transition → the log *is* Reactor's journal + status source. |
| T1-2 retry policy | **subsumed** | Use Reactor's `max_retries`/`:retry`/backoff. Don't port Squidie's module. |
| S-1 saga/compensation | **subsumed** | Reactor `compensate`+`undo`; `Ash.Reactor` gives **declarable**, durable per-action undo (opt-in — §4.6). |
| DAG / dependency resolution | **subsumed** | Reactor resolves it. Skills compile to Reactor; drivers retired. |
| T1-3 fingerprint / replay | **wraps** | Hash the reactor definition at `run_started`; `run_id` for lineage; irreversible markers gate auto-resume. |
| T1-4 case + event model | **wraps** | The human-decision domain layer around a halted reactor. |
| T2-5 human-gate DSL | **wraps** | Maps onto `{:halt}` → persist → resume. |
| T2-1 deadlines | **orthogonal** | Read-model over event-log timestamps. |
| T2-2 actor-visibility redaction | **orthogonal** | Projection-layer concern. |
| T2-3 cron idempotency | **orthogonal** | Run-identity gate *in front of* `Reactor.run`. |
| T2-4 lease/fencing | **✅ shipped (§4.11)** | Borrowed from gust — durable claim + fence token; shipped as the clustering workstream (WS1–WS5+WS4a, 2026-06-27..30). |

## 4. Component design

### 4.1 `WorkflowRun` — status is a projection

`WorkflowRun` stays as the durable handle for a run (id, tenant, name, workflow ref,
inputs, lineage, timestamps), but **`status` is computed from the event log**, not
mutated. Greenfield means there is no dual-write phase to retire — status goes straight
to projection: fold the run's events (`run_started`/`run_resumed` → `:running`,
`run_completed/failed/cancelled` → terminal, an unresolved `approval_requested` →
`:awaiting_approval`, a *resolved* gate → `:running` on approve / the `after_rejected`
outcome on reject (§4.5), etc.) into a status. (`run_recovered` is **provenance**, not a status of
its own — it annotates *why* an accompanying `run_failed` terminal was reached; see
§4.8.) `run_halted` is **provenance too**: it records *that* the reactor paused, but the
pause *status* is `:awaiting_approval`, projected from the unresolved `approval_requested`
the gate step writes synchronously (§4.5) — **not** from `run_halted` (there is no
`:halted` status in the enum). Workflow reactors pause **only** at approval gates (§4.3),
so a `run_halted` with no matching unresolved `approval_requested` is a forbidden non-gate
halt: it moves nothing, leaving the run `:running` for its caller — failing that, the
recovery reconciler (§4.8) — to finalize with `run_failed`. Materialize this as a **projection-owned `status` column** — written **only** by
the projection, never by hand, and updated **in the same synchronous transaction** as each
status-authority event append (§4.3) so the column never lags the log for readers like
recovery and `:claim_next`. (A pure Ash calculation/aggregate is *not* sufficient: §4.11's
claim path needs a real, indexable column — the `(status, claim_expires_at)` index and
`:claim_next`'s `FOR UPDATE SKIP LOCKED` can't operate on a runtime-computed value. A
calculation may *derive* the stored column, but `status` itself must be a column.)

Because status is *projected* from them, the **status-authority events it folds**
(`run_started`/`run_resumed`, `approval_requested`/`approval_resolved`, and the terminals
`run_completed/failed/cancelled`) must be **durably persisted — and the materialized
`status` column updated in the same transaction — before the run returns or advances**;
they are not fire-and-forget observability. `run_halted` rides the **same synchronous,
durable path** (a once-per-run lifecycle event, not async timeline) but is **not**
status-authority — it is provenance and updates no status (per the fold rules above). §4.3
puts all of these on the synchronous write path; only the high-volume per-step timeline is
eventually-durable.

`run_id` passed to `Reactor.run/4` **is** the `WorkflowRun.id`, tying the two together.

### 4.2 `WorkflowEvent` — the append-only system of record

As specified in the T1-1 plan: tenant-scoped, append-only (`:read` + `:append`, no
update/destroy) — shipped on plain `use Ash.Resource` + the two hand-written tenant
policies rather than the sketched `use JidoClaw.Resource`, because that macro
force-injects `bypass action(:by_id_global)`, which doesn't compile for a resource with
no global-id read (isolation semantics are identical) — with a DB-enforced **unique**
`(workflow_run_id, seq)` index — the uniqueness *fence*, not monotonicity itself; `seq` is allocated by the
append helper under a per-run lock (callers never supply it), which is what makes it
monotonic and gap-free (T1-1). `payload`/`metadata` are redacted by a **recursive**,
key-aware redactor (`Redaction.Transcript`, **not** `Patterns.redact/1` — which only scans
binaries and no-ops on the event maps; T1-1). Entry vocabulary (Reactor-shaped):

`run_started` · `run_resumed` · `step_started` · `step_completed` · `step_failed` ·
`step_retried` · `step_compensated` · `step_undone` · `approval_requested` ·
`approval_resolved` · `run_halted` · `run_completed` · `run_failed` · `run_cancelled` ·
`run_recovered`

### 4.3 The event-log producer — `JidoClaw.Workflow.Middleware`

A single `Reactor.Middleware` is the **primary** producer — it emits the run/step
lifecycle stream (the targeted non-middleware writers in §4.4 and §4.5 are the deliberate
exceptions). Every run wires it in
(via the `middlewares` DSL section, or `Reactor.Builder.add_middleware/2` for compiled
skills). The callbacks split into two durability classes — and the split is forced by
the Reactor API, not a preference:

**Run-lifecycle callbacks (fire once per run → synchronous + durable; status-authority
except `run_halted`, which is provenance):**

- `init/1` → stamp tenant/actor/run_id into the Reactor context; append `run_started`
  **only on the initial start.** `init/1` *also* fires on every resume of a halted
  reactor (`Executor.Hooks.init` runs for both `:pending` and `:halted`), so guard on
  `context.__reactor__.initial_state == :pending` to avoid a duplicate `run_started`, and
  append `run_resumed` on the `:halted` branch instead. This makes `init/1` the **single
  producer** of `run_resumed`: every resume (gate-decision *and* boot recovery) just
  re-runs the reactor and passes provenance through context — callers never append
  `run_resumed` themselves.
- `halt/1` → append `run_halted` — **provenance that the reactor paused, not a status of
  its own** (there is no `:halted` status; the pause status `:awaiting_approval` is projected
  from the unresolved `approval_requested`, §4.1). `halt/1` receives only the
  Reactor context — *not* the halt value or which step halted (those arrive via the async
  `event/3` as `{:run_halt, value}`) — and it fires for **every** halt source, unable to tell
  a gate apart from a timeout (see "Halts are gate-only" below) — so it is **not** the home
  for the authoritative `approval_requested` + `AgentCase` write; the approval step does that
  synchronously before halting (§4.5).
- `complete/2` → append `run_completed`.
- `error/2` → append `run_failed`.

Each of these fires **once per run** (or per halt), *not* on the per-step hot path. The
status-authority ones (`init`/`complete`/`error`, plus the gate step's
`approval_requested`/`approval_resolved`) **synchronously append their event *and* update
the projection-owned `status` column (§4.1) — in one transaction — before the callback
returns**, i.e. before `Reactor.run/4` hands the result or the halted reactor back to the
caller. (`halt/1` is the exception: it appends `run_halted` on the same synchronous, durable
path but updates **no** status — the column is already `:awaiting_approval` from the gate's
synchronous `approval_requested` (§4.5), and `run_halted` is provenance (§4.1).) The event append alone is not
enough now that `status` is a materialized column read by recovery and `:claim_next`
(§4.11): if the column lagged its event, a claimer/reconciler could act on a stale status,
so the barrier covers both writes atomically. (Per-step timeline events don't change
run-level status, so they never touch the column and stay on the async path.) That
ack/barrier is what makes status-as-projection (§4.1) sound: the events *and* the status
they imply are durable before anything downstream can observe the run as done or paused. (`run_cancelled` comes from the
explicit cancel action; `run_recovered` — provenance, paired with a terminal `run_failed`
— comes from the boot reconciler. All are durable writes, not middleware callbacks.)

**Halts are gate-only.** Reactor can halt for several reasons and only one is an approval
gate. The gate step returning `{:halt, case_id}` is the intended one. But the run-level
`timeout` firing also halts (`executor.ex:153` → `Hooks.halt` → a `run_halted`), as does
*any* step returning `{:halt, value}` (`step_runner.ex:223` → `Hooks.halt` → a `run_halted`);
and exhausting `max_iterations` returns `{:halted, reactor}` **without** firing `Hooks.halt`
at all (`executor.ex:100`), so it emits *no* `run_halted`. Since `halt/1` gets only context
and cannot tell these apart, the envelope **forbids every non-gate halt** for workflow
reactors and neutralizes each at the source: run them with `timeout: :infinity` and
`max_iterations: :infinity` (**both are the Reactor defaults** — a deadline is the read-model
§4.9, never a run-level halt), and let **only** the approval-gate step return `{:halt, …}`.
The safety net for anything that slips through: the code that calls `Reactor.run/4` treats a
halted return as a *legitimate* pause **only** when the gate step's synchronously-written
`approval_requested` exists for this run (§4.5 step 1). A halted return with no such event —
or a `{:halted, reactor}` from `max_iterations` — is a non-gate halt and is finalized with
`run_failed` immediately, never parked at `:running`. So the only `run_halted` that ever
pairs with a live, resumable checkpoint is an approval gate's, which is exactly what §4.5
and §4.8 assume.

**Per-step timeline (high-volume, on the hot path → async):**

- `event/3` → one append per step transition (`{:run_start,…}` → `step_started`,
  `{:run_complete,…}` → `step_completed`, `{:run_error,…}` → `step_failed`,
  `{:run_retry,…}` → `step_retried`, plus the compensate/undo events →
  `step_compensated` / `step_undone`).

**Hard constraint:** `Reactor.Middleware.event/3` *blocks the reactor* (the behaviour
docs say to do anything expensive in another process). So the step-timeline path must
**not** synchronously write to Postgres: the middleware `cast`s a compact event struct
to a per-node `WorkflowEvent.Writer` GenServer (or `Task`-backed batch writer) that
persists asynchronously, keeping step latency off the DB and giving natural batching.
The trade-off — *eventually* durable, since a crash in the sub-second cast→write window
can drop the last step event — is acceptable **only for the step timeline**, which is
**best-effort observability**: a dropped step event leaves the timeline incomplete after a
crash but never corrupts status or recovery, since those fold the synchronous spine, not the
step timeline. (It is *not* guaranteed reconstructable — the lost `step_*` fact has no other
durable source unless the §7 resume checkpoint is promoted to record step outputs, which is
the unproven path, not the plan of record.) It is **not** acceptable for the run-lifecycle
events above (the synchronous lifecycle spine — the status-authority subset among them is
what the projection folds into `status`), which is exactly why those take the
synchronous path. For side-effect facts that must be crash-atomic with their mutation,
use §4.4.

**Ordering across the two paths.** The single per-run `seq` (§4.2, T1-1) orders the log
*as persisted* — i.e. in **commit** order, not occurrence order. Because the
run-lifecycle spine is written synchronously while the step timeline is `cast` to the async
`Writer`, a `step_completed` still queued in the Writer could otherwise be allocated a
`seq` *after* the synchronously written `run_completed` for the same run — contradicting
"the terminal is a run's last event" and corrupting any reader that folds by `seq`. Two
rules close this: (1) the `Writer` preserves **per-run FIFO**, so a run's step events
commit in the order they occurred; (2) a synchronous run-lifecycle append (`complete/2`,
`error/2`, `halt/1`) acts as a **barrier** — it flushes that run's pending step events
from the Writer before allocating its own `seq` and committing, so the terminal/halt
event always holds the run's maximum `seq` and no step event can sequence after it. Net:
the synchronous spine is the **ordering authority**; the step timeline is **best-effort
observability** that may *trail* the spine within a run but never crosses the run's
terminal. (This is also why `seq` is allocated by the append helper under a per-run lock,
never supplied by callers — §4.2, T1-1.)

### 4.4 Atomic side-effect + audit via `Ash.Reactor` transactions

For steps where "did this side effect actually commit?" must be answerable after a
crash (irreversible writes, external-effect bookkeeping, idempotency keys), don't rely
on the async middleware. Instead, model the step as an `Ash.Reactor` action and append
the authoritative fact **inside the same DB transaction** as the mutation — either by
grouping the action step and a `WorkflowEvent.append` step in an `Ash.Reactor`
transaction block, or via an `after_action` hook on the Ash action — which runs *inside*
the transaction. (`after_transaction` runs *after* commit/rollback, **outside** the
transaction per the Ash action lifecycle, so reserve it for non-atomic follow-up, never
the atomic audit write.) The side effect and its durable record then commit together or
not at all. **This eliminates drift between a side effect and its audit record** — there
is no separate async append to fall out of sync.

So the event log has three write paths by design: the middleware's **synchronous**
run-lifecycle appends (§4.3 — once per run, the lifecycle spine), the middleware's
**async** per-step timeline (cheap, high-volume, eventually durable), and
**in-transaction appends** for the small set of authoritative side-effect facts
(crash-atomic). All write to the same table; the projection reads them.

### 4.5 Human gates — `{:halt}` → persist → resume

This is the cleanest marriage. A human-approval step **halts** the reactor. Then:

1. The approval **step itself** synchronously creates the `AgentCase` (T1-4) with its
   typed `details` payload and appends `approval_requested` — ideally both in one
   transaction (§4.4) — *before* it returns `{:halt, case_id}`. This makes the
   authoritative gate fact durable by construction, not dependent on the async
   middleware: the halt value + step are visible only through the async `event/3`
   (`{:run_halt, value}`), and `halt/1` receives just context, so neither middleware
   callback is a safe home for it. The middleware's `halt/1` then appends the run-level
   `run_halted`.
2. The reactor's resumable state is **persisted** (see §7 for *how* — this is the one
   hard problem). Since step 1 commits the case *before* this checkpoint exists, a crash
   in between leaves a case with no resumable run; the boot reconciler (§4.8) closes that
   orphaned case when it fails the run.
3. The operator decides through the human-gate DSL (T2-5) — a Spark DSL declaring the
   *kind* of decision (`tool_call`, `plan`, `irreversible_write`, …), its fields, and
   `after_approved/2` / `after_rejected/2` hooks.
4. On decision: append `approval_resolved` **together with the resulting status
   transition, in one transaction** — it's status-authority (like `approval_requested` it
   updates the materialized `status` column, §4.1, so the column never lags the decision),
   and the target value is **defined, never left at `:awaiting_approval`**: **approve →
   `:running`** (the run is resuming; if the process crashes after this commit but
   before/within `Reactor.run/4`, boot recovery finds a `:running` run with a clean
   checkpoint and resumes it — §4.8 — re-injecting the decision recorded in
   `approval_resolved`); **reject → whatever `after_rejected` yields**, normally a terminal
   (`:cancelled`/`:failed`). Then **resume** by re-running the reactor.
   Reactor re-validates the *full* declared input set on every run and drops anything not
   declared (`Executor.Init.validate_inputs/2`, `init.ex:53`), so a partial
   `%{approval: decision}` would fail — re-supply the **original inputs** and inject the
   decision through **context** (deep-merged, not validated):
   `Reactor.run(reactor, original_inputs, %{approval: decision})`. Source `original_inputs`
   from a **private, unredacted checkpoint** (encrypted field or retained halted state) —
   *not* the `run_started` event payload, which is a redacted audit copy stored as
   string-keyed JSON. Reactor validates against the declared input *names*, which are atoms
   (`Reactor.Input.name :: atom`; `init.ex:53`), so payload keys would need normalizing
   back to those atoms and redacted values can't be replayed. Completed steps don't re-run.

Reactor supplies the pause/resume primitive; the envelope supplies the durability and
the decision domain it lacks.

> **Design input — Alp River AR-1.** The decision-kind list in step 3 (`tool_call` / `plan` /
> `irreversible_write`) already lines up with Alp River's working gate taxonomy
> ([`../alp-river/FEATURES-WORTH-BORROWING.md`](../alp-river/FEATURES-WORTH-BORROWING.md) AR-1:
> plan-approval / tool-call / safety-irreversible), where a `while/until` lock is precisely a
> declarative `{:halt}` guard with multiple guards AND-ing on one step. Borrow its two
> lifecycle rules **verbatim** while designing the DSL *here*, rather than bolting them on
> later: **`abandon` is a run-terminal** (it drops every stage still held behind the abandoned
> gate instead of waiting forever for an `until` that never fires — maps onto
> `after_rejected → terminal`, step 4), and **stale-approval retraction** (a
> *pre-implementation* re-plan removes the approval signal so the revised plan must re-earn it
> — the §4.8 decision-recorded-vs-unresolved branch already leans on exactly this distinction).

### 4.6 Retry, compensation, undo

All native to Reactor (§2). Guidance: prefer `Ash.Reactor` actions over hand-rolled
steps wherever a workflow touches resources, so undo *can* be a durable action rather
than an in-memory closure that dies with the VM. **Durable undo is opt-in, not
automatic:** an `Ash.Reactor` action step defaults to `undo: :never` and rolls back only
if you declare both an `undo_action` and `undo: :always | :outside_transaction` (Ash
Reactor guide, "Handling failure"). Declare them on every side-effectful step you want
reversible; an undeclared step is irreversible (§4.7). Reserve hand-rolled
compensate/undo for genuinely external effects (HTTP calls, shell side effects via
Forge), and make those idempotent so a partial replay is safe.

### 4.7 Fingerprint + replay (T1-3)

At `run_started`, hash the reactor definition (module source digest, or for compiled
skills the digest of the source YAML) into the event payload. A `WorkflowRun.replay`
action recomputes the hash and refuses on mismatch (or requires `force: true`). Steps
carry `irreversible: true` / `compensatable: false` markers; replay and post-crash
auto-resume are gated on them. `Ash.Reactor` resource mutations are side-effectful by
nature → default them to irreversible unless they declare a durable undo.

**Implementation note (shipped 2026-06-09).** The sketch above survived with
five deliberate divergences:

- **Skills hash a canonical semantic term, not YAML text.**
  `Skills.parse_skill_file/1` doesn't retain raw text, tests/tools build
  `%JidoClaw.Skills{}` structs directly, and a compiled `%Reactor{}` can't be
  hashed (`Builder.new/1` stamps a fresh `make_ref()` per compile). So
  `JidoClaw.Orchestration.DefinitionFingerprint.for_skill/1` hashes a
  normalized term mirroring compiler semantics (mode via `execution_mode/1`,
  compiler defaults applied, `depends_on`/`consumes` order preserved — it's
  prompt-semantic — `description` excluded), encoded with
  `term_to_binary({:v1, …}, [:deterministic])`. Module reactors use
  `module_info(:md5)`. Comment/whitespace/description edits don't trip the
  gate; semantic edits do.
- **Replay is a module function, not an Ash action** —
  `JidoClaw.Orchestration.Replay.replay/2` (the `Cases.decide/4` precedent),
  one envelope: `{:ok, run}` whenever a replay run exists (inspect status),
  `{:error, reason}` for refusals/pre-run failures. The hash also lands as a
  `definition_hash` column on `WorkflowRun` (plus the `run_started` payload).
- **Original inputs are durably stored** — the checkpoint is cleared on every
  terminal, so replay needed its own blob: `replay_inputs`
  (AshCloak-encrypted `encrypted_replay_inputs`), written at create, never
  cleared, decoded only by `Replay` (`[:safe]`, after the definition is
  re-resolved so its atoms are interned).
- **Replay re-resolves skills from DISK** (`Skills.load_skill/2`, matched on
  the `name:` field under `config["project_dir"]`) — the boot-time cache
  would mask exactly the on-disk edit the gate exists to catch. Module
  identities are fenced to the `JidoClaw.Orchestration.Reactors.` prefix
  before `String.to_existing_atom/1`.
- **The irreversible gate scans executed `step_*` event payloads**
  (`irreversible == true` on `step_started/completed/failed`) — declaration
  alone doesn't refuse; *execution* does. Override `allow_irreversible: true`.
  Surfaces: dashboard button (both overrides) + MCP `replay_workflow` tool
  (**no** override params — operator-only levers stay on the dashboard).

Post-review fix (same day): the iterative loop step now carries
`irreversible` OR-aggregated from its generator/evaluator roles (and the
generator's declared `retry` budget actually threads onto the loop), so the
replay irreversible gate covers iterative skills too. Correspondingly, the
iterative fingerprint hashes the resolved loop semantics — gen/eval role
maps, generator retry, OR'd irreversible, `max_iterations` — rather than the
raw step list (compensate / evaluator retry / step order are runtime-inert
there, so fingerprint-inert).

### 4.8 Recovery reconciler (boot)

Reactor's in-memory run dies with the node, so recovery still matters. On boot, scan
non-terminal `WorkflowRun`s by **projected status** (`status in [:pending, :running,
:awaiting_approval]`) as the system reconciler — **with `authorize?: false`**, since this
is a cross-tenant scan and `multitenancy(:bypass)` drops only the tenant *filter*, not the
read *policy* (`JidoClaw.Resource` requires `tenant_id == actor(:tenant_id)` and bypasses
authz only for `:by_id_global`).

Per run, branch on **whether a human decision is still outstanding** — recovery must
**never resume an unresolved gate.** Reactor resume re-runs the retained halted struct, and
a halted step is **dropped from the plan with its halt value stored as its result**
(`executor/sync.ex:99`; proven by `executor_test.exs:129` — re-running a halted reactor
completes using the halt value, and the halted step never re-runs). So blindly resuming an
`:awaiting_approval` run would sail **past** the gate as if it had produced a value, with no
decision taken. Branch on the projected status, which already encodes resolution (§4.1:
unresolved gate → `:awaiting_approval`, resolved → `:running`):

- **`:awaiting_approval` + checkpoint exists** → **leave it parked.** Not stranded — it is
  correctly waiting for a human and its `AgentCase` is still open; recovery does nothing to
  it. Resumption comes only from the operator's approve/reject (§4.5), **never** from boot
  recovery.
- **`:awaiting_approval` + no checkpoint** → §4.5 commits the `AgentCase` +
  `approval_requested` *before* the halted struct is returned (`executor.ex` halt handling),
  so a crash there leaves a case with no resumable checkpoint. Fail-with-audit **and** resolve
  the dangling gate: append `run_recovered` + the terminal `run_failed` + `approval_resolved`
  (cancelled-by-recovery) + cancel/fail the open `AgentCase` with a case event — else the
  operator inbox shows an approval that can never resume.
- **`:running`/`:pending` + clean checkpoint + a recorded `approval_resolved`** → the
  **decision-already-recorded** case (§4.5 step 4): the operator decided, the gate flipped the
  run to `:running` and recorded `approval_resolved`, then the process crashed before/within the
  resuming `Reactor.run/4`. Key this branch on the recorded `approval_resolved`, **not on the
  checkpoint alone**: a checkpoint is created only by the gate step (§4.5 step 2), so a
  checkpoint with no `approval_resolved` is a halt that never resolved into a decision — a
  forbidden non-gate halt (§4.3) that somehow left state — with nothing to re-inject, so it is
  **fail-with-audit** (the no-checkpoint branch below), never a blind resume past the gate.
  With a recorded decision in hand: resume the reactor, **re-injecting the recorded decision through context**
  (`Reactor.run(reactor, original_inputs, %{approval: decision})` — the gate's downstream
  steps read the decision from context, *not* from the halted step's stored result, which is
  the halt value). Don't append `run_resumed` here — middleware `init/1` owns it on the
  `:halted` resume (§4.3); pass provenance (e.g. `recovered: true`) through context.
- **`:running`/`:pending` + no checkpoint** (mid-step VM crash, no gate) → **append**
  `run_recovered` (provenance) **and** the terminal `run_failed`; the projection folds
  `run_failed` to `:failed` (status is projected, §4.1 — recovery never mutates `status`
  directly).

Write each recovery batch — for the dangling-gate case that's `run_recovered` + `run_failed`
+ `approval_resolved` + `AgentCase` cancellation + case event — **in one transaction**: the
reconciler scans only *non-terminal* runs, so once `run_failed` lands, a crash before case
cleanup would orphan the case forever (the alternative is an idempotent sweep for
terminal-failed runs with unresolved gates). **Default for any no-checkpoint case:
fail-with-audit**, because a crashed reactor's in-memory undo stack is gone — you cannot
safely auto-compensate a half-finished run after reboot. Auto-resume is opt-in per workflow
and gated on idempotency + irreversible markers.

Emit `[:jido_claw, :orchestration, :recovered]` so recovery is visible. (In a clustered
deployment, lease expiry — §4.11 — handles dead-node recovery continuously; the boot
reconciler is the single-node restart case.)

### 4.9 Deadlines + actor-visibility (read-models, orthogonal)

Pure projections over the event log — independent of Reactor. Deadlines (T2-1) compute
`on_time/due_soon/overdue` from `started_at`. Actor-visibility (T2-2) redacts step
inputs/outputs/errors by scope (`:operator`/`:auditor`) before any surface renders them
— directly serving the leakage-hygiene threat model, since Reactor step payloads will
carry LLM-generated content.

### 4.10 Cron idempotency (producer-side, T2-3)

Sits *in front of* `Reactor.run`: derive a deterministic run identity
(`cron:<job_id>:<window>`) and upsert the `WorkflowRun` so a double-delivered cron tick
returns the existing run instead of starting a second reactor.

### 4.11 Distributed work-claiming (when clustered) — borrowed from gust

> ✅ **SHIPPED IN FULL (2026-06-27..30).** What follows was the *plan*; it landed as the
> clustering workstream **WS1–WS5 + WS4a** — `orchestration/workflow_lease.ex` (claim / renew /
> `claim_next`), `.../workflow_lease/{middleware,sidecar}.ex` (renew + stale-fence halt),
> `orchestration/reclaim_pooler.ex` (the Pooler, WS3), `core/cluster/leader.ex` (`:pg` leader,
> WS4), `platform/cron/owner.ex` (clustered cron, WS4a), and cross-node cancel (WS5). The port
> applied the tune-ups below (60s/15s lease, `:pg` leader) and re-derived the lease around the
> AR-2 composer unit (WS2). The authoritative "what landed where" record is
> [`../../plans/clustering/`](../../plans/clustering/README.md); only WS6 (multi-node test
> harness + ops) remains.

Today jido_radclaw is single-node, so a run executes in-process and §4.8's boot reconciler
suffices. For the clustered-tailnet future (argus), durable multi-node claiming is the
mechanism — and the **gust** project ships a clean, verified reference implementation
(see [`../gust/FEATURES-WORTH-BORROWING.md`](../gust/FEATURES-WORTH-BORROWING.md) §G1-1;
this upgrades T2-4 from "deferred" to a concrete plan). The shape, in Ash/Reactor idiom:

- **Claim fields on `WorkflowRun`**: `claimed_by` (node), `claim_expires_at`, `claim_token`
  (UUID fence). Indexes on `(status, claim_expires_at)` and `(claimed_by)`. Land these with
  the rest of `WorkflowRun` now (greenfield — no later migration).
- **`:claim_next`** — an Ash action selecting one claimable run (`status == :pending OR
  (status == :running AND claim_expires_at < now)`, oldest first; `:pending` is the
  existing "created, not yet running" status — there is no separate `:enqueued` state) via
  `Ash.Query.lock("FOR UPDATE SKIP LOCKED")`, then stamping node + lease + a fresh token.
  `SKIP LOCKED` makes concurrent pollers across nodes race-free.
- **`:renew`** — update `claim_expires_at` only where `(id, claim_token)` match; `{0, …}` →
  the caller lost the claim.
- **`Pooler` GenServer** (per node) — poll + PubSub-trigger → `:claim_next` → start the
  run's Reactor under a `DynamicSupervisor`.
- **`Reactor.Middleware.Lease`** — renew on a timer; **halt the reactor if renew reports a
  stale token** (a zombie worker self-terminates without double-completing the run).
- **Leader election** (for singleton work like the cron scheduler) — a held
  `pg_try_advisory_lock` (gust's approach) **or** `libcluster` + `:pg`/`:global` (already
  conditionally in-tree). Prefer `:pg` to avoid gust's session-bound-lock partition failure
  mode.

Tune lease/renew **up** from gust's 15s/5s to ~60s/15s and add **step-level idempotency
keys** — double-calling an LLM/tool is costly. Lease expiry then becomes the multi-node
complement to §4.8: a dead node's runs become reclaimable after the lease lapses (bounded
recovery window = lease length), while the boot reconciler handles single-node restarts.
*(Original guidance: defer implementation until clustering is real; land the data model now.)*
**Both done — the data model landed 2026-06-10 and the implementation shipped 2026-06-27..30
(WS1–WS5 + WS4a); see the SHIPPED banner at the top of this section.**

## 5. Skills on Reactor (compiling YAML → `Reactor.Builder`)

The LLM-authored surface stays YAML (LLMs and humans edit flat files in `.jido/skills/`);
**only the execution backend changes.** At load time, a `JidoClaw.Skills.Compiler` turns
a skill definition into a Reactor via `Reactor.Builder`:

- Each skill step → `Builder.add_step/…`. A step that "invokes the agent/LLM/tool" wraps
  the relevant `Jido.Action` (or a sub-agent spawn) as the step's implementation.
- `depends_on` → `argument`s referencing prior step results (`{:result, step_name}`),
  giving the DAG for free.
- Execution modes map onto Reactor's compositional steps: **sequential** → linear arg
  chain; **dag** → arg-derived DAG; **iterative** → Reactor `map`/`recurse`; branching →
  `switch`; sub-skills → `compose`.
- Optional `retry:` / `compensate:` / `irreversible:` per-step metadata translate to
  Reactor step options and undo references.
- The `JidoClaw.Workflow.Middleware` is added to every compiled skill, so skills get the
  same event log / status / recovery / human-gate machinery as developer-authored
  workflows — for free, uniformly.

Result: **one engine, one envelope, two front-ends** (Ash.Reactor modules for code-first
workflows; compiled YAML for LLM-first skills). The three bespoke drivers and the
`WorkflowRunner` dispatch seam are deleted.

Open design point: whether the compiler targets `Reactor.Builder` structs at runtime, or
generates `Ash.Reactor` modules. Builder-at-runtime fits the "LLM edits YAML, reload
without recompile" loop better; lean that way.

## 6. Where Reactor does NOT belong

The **agent ReAct loop** and the **swarm** are dynamic — the next tool call depends on
the last result in a way that isn't a declared DAG. Don't force them into Reactor. A
*skill* (a declared multi-step plan, even one whose steps invoke the LLM) is a good
Reactor fit; the open-ended agent loop is not. Sub-agent spawns can appear *as steps
inside* a skill-reactor (e.g. a `map` step fanning out workers), but the agent's own
reasoning loop stays as-is.

## 7. The one hard problem — durable halt-state

Cross-restart resume of a *paused* reactor is the only genuinely hard part. The halted
reactor struct can contain non-serializable state (async task refs, closures), so
naively persisting it and rehydrating after a VM restart is fragile.

Two strategies — **decide this early, it shapes the human-gate design:**

- **(A) Persist the halted struct.** Serialize the reactor on halt, store it (a blob on
  `WorkflowRun`, or its own row), rehydrate on resume. Simplest conceptually; fragile if
  any step state isn't serializable. Mitigate by halting **only** at clean boundaries
  (the approval step takes plain-data args) and running gate reactors `async?: false` so
  there's no live task state at the halt point.
- **(B) Reconstruct from the event log.** Don't serialize the struct. The event log
  records inputs + completed-step results — but only as a **redacted, string-keyed audit
  copy**, so a faithful rebuild needs a separate unredacted checkpoint holding the real
  replay *state*: both the **original inputs** *and* the **completed-step outputs /
  intermediate results** (Reactor keeps those internally to satisfy downstream steps —
  `store_intermediate_results/2` in `async.ex` — and only surfaces them to middleware via
  the redacted `{:run_complete, result}` event), all with keys normalized to the declared
  atom input names. On resume, **rebuild** the reactor via `Reactor.Builder` and replay so
  the completed steps are skipped, then run from the gate forward with the decision
  injected. Appealing — it sidesteps serialization and keeps the **event log as the
  audit/status source of truth** (the replay state lives in the checkpoint) — but it rests
  on a capability
  Reactor does **not** expose today: there is no public API to seed completed-step
  results into a freshly built reactor or to mark steps already-done. `Reactor.run/4`
  resumes only by re-running a **retained halted struct** (`reactor.ex`, `run/4` accepts
  a struct whose `state` is `:pending | :halted`) — which is strategy (A)'s mechanism,
  not (B)'s. (B) therefore requires *building* a custom skip-completed mechanism (e.g.
  compiling each completed step as a stub that returns its recorded result, or driving
  Reactor internals), which is unproven. Treat it as a **prototype risk**, not a decided
  path.

Recommendation: **(A) is the lower-risk default** — it uses Reactor's actual resume
primitive (re-run the retained halted struct). Prototype **(B)** against one real gate to
learn whether a clean skip-completed mechanism is even feasible *before* betting the
human-in-the-loop design on it; if it proves awkward, (A) with the clean-boundary
discipline is the fallback. Either way, build the gate machinery against *one* gate
end-to-end first.

## 8. Phased adoption path

Each phase is independently shippable and verifiable.

**Phase 0 — Envelope foundations.** `WorkflowEvent` resource + async `Writer` +
status-as-projection on `WorkflowRun`. No Reactor yet — even the current code can append
events. *Done when:* events persist with monotonic seq, status projects correctly,
tenant isolation is tested.

**Phase 1 — First Reactor workflow end-to-end.** Implement one developer-authored,
side-effectful flow as an `Ash.Reactor` (candidate: the cron→workflow path, or a
"branch + commit + open PR" operation). Wire `JidoClaw.Workflow.Middleware`. Prove the
audit trail + atomic in-transaction append (§4.4). *Done when:* a real run produces a
complete, correct event timeline and a forced step failure triggers compensation/undo
that's visible in the log.

**Phase 2 — Human gate (halt → persist → resume).** Build `AgentCase` + `AgentCaseEvent`
+ the human-gate Spark DSL on **one** gate (e.g. `irreversible_write`) — folding in Alp
River AR-1's gate lifecycle (`abandon`→terminal, stale-approval retraction) per §4.5.
Implement the chosen §7 resume strategy. *Done when:* a run halts at the gate, survives an app
restart, and resumes correctly on approval; rejection routes through `after_rejected`.

**Phase 3 — Skills on Reactor.** Build the `Skills.Compiler` (YAML → `Reactor.Builder`),
map all execution modes, attach the middleware, and **delete** `IterativeWorkflow` /
`PlanWorkflow` / `SkillWorkflow` / the `WorkflowRunner` dispatch. *Done when:* every
existing skill runs through Reactor with identical-or-better behavior and the old drivers
are gone.

**Phase 4 — Replay, fingerprint, recovery.** ✅ **Shipped** (recovery landed with
Phases 0–3; fingerprint + replay 2026-06-09 — see §4.7's implementation note).
Definition fingerprint at `run_started`; `Replay.replay/2` with mismatch +
irreversible gates; boot reconciler (resume decision-already-recorded runs, **leave
unresolved gates parked**, else fail-with-audit — §4.8). *Done when:* a stranded
`:running` run reconciles on boot (test proves it), an `:awaiting_approval` run with
a checkpoint is left parked (not resumed), and replay refuses a changed definition —
all three are test-pinned (`workflow_recovery_test.exs`, `replay_test.exs`).

**Phase 5 — Read-models.** ✅ **Shipped 2026-06-10** (plus the T3-1/T3-2 graph
viz per the reconciliation note — see the status banner's Phase 5 block for
what diverged). Deadlines, actor-visibility redaction, cron idempotency over
the event log. *Done when:* the dashboard shows lateness, payloads are
scope-redacted by default, and a double cron tick yields one run — all three
are test-pinned (`deadline_test.exs` + dashboard render pins,
`visibility_test.exs` + the MCP security pins, `reactor_runner_test.exs` /
`workflow_runner_test.exs` / `worker_fire_provenance_test.exs`).

## 9. Open questions / decisions to make

1. **Halt-state strategy (§7):** persist-struct (A — uses Reactor's real resume
   primitive) vs reconstruct-from-events (B — depends on a skip-completed mechanism
   Reactor doesn't expose today, so prototype it, don't pre-commit). Highest-leverage
   decision; settle it in Phase 2.
2. **Skill compiler target:** runtime `Reactor.Builder` structs vs generated
   `Ash.Reactor` modules. Leaning Builder for the no-recompile edit loop.
3. **How skills express compensation/undo** in YAML for the (few) side-effectful steps —
   reference an action module? inline? Most skill steps need neither.
4. **Event log vs `JidoClaw.Trace`** (the jidoka T1-1 in-flight trace surface): keep both
   — Trace = ephemeral in-flight overlay, `WorkflowEvent` = durable system of record. The
   middleware can feed both. Decide whether the middleware emits Trace telemetry directly
   or Trace's collector subscribes to workflow events.
5. **Sub-agent transcripts:** how `Conversations.SubagentTranscript` and per-agent
   compaction interact when a sub-agent runs *as a Reactor step* inside a skill.
6. **Multitenancy in the Reactor context:** confirm tenant_id/actor propagate cleanly
   through `Reactor.run`'s `context` into every step and the middleware.
7. **Back-pressure:** the async event `Writer` under a high-`max_concurrency` reactor —
   batching/overflow policy.

## 10. Dependency posture

- **No new dependencies.** `reactor 1.0.2` is already pulled (non-optional) by
  `ash` (3.27.8 in today's lock); `Ash.Reactor` is the extension. `spark`, `multigraph`, `splode`,
  `telemetry` (Reactor's deps) are all already present.
- **`runic` is not needed** and should not be added — Reactor fills the role Squidie used
  Runic for (dependency-readiness planning), natively and stably (Runic is alpha).
- This is the decisive advantage over adopting Squidie itself: we get a more capable,
  Ash-native engine with **zero** dependency cost and no raw-Ecto/term-blob persistence
  universe.

## Appendix — key APIs referenced

- `Reactor.run/4` — `inputs`, `context`, opts: `run_id`, `async?`, `max_concurrency`,
  `timeout`, `max_iterations`, `fully_reversible?`. Returns `{:ok, result}`,
  `{:error, …}`, or a halted reactor.
- `Reactor.Builder` — `new/0`, `add_input/2`, `add_step/…`, `add_middleware/2`,
  `return/2`. For dynamic/compiled construction.
- `Reactor.Middleware` — `init/1`, `event/3` (**blocks the reactor**), `complete/2`,
  `error/2`, `halt/1`, `get_process_context/0`, `set_process_context/1`.
- `Ash.Reactor` steps — `create`, `update`, `destroy`, `action`, `read_one`, `bulk_*`,
  transaction grouping; each action step supports a declarable **`undo`**.
- Saga callbacks — `Reactor.Step.compensate/4` (`:retry` capped by `max_retries`),
  `Reactor.Step.undo/4`.
- Pause — a step returning `{:halt, value}`.

Authoritative docs: `mix usage_rules.search_docs "<term>" -p reactor` and
`-p ash` (the `dsl-ash-reactor` reference), or hexdocs `reactor` + the Ash Reactor guide.
