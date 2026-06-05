# Features Worth Borrowing from Squidie (+ SquidSonar, Rift)

Exploration notes — not a plan, not a commitment. Inventory **2026-06-04**.

Sources, primary author Cristiano Carvalho. Squidie and SquidSonar are from the
`dark-trench` GitHub org (org confirmed in both their Hex metadata and their local
checkouts' `origin`). Rift's *package metadata* also points there (`rift/mix.exs:12`
→ `dark-trench/rift`), but the local checkout's `origin` is `ccarvalho-eng/rift`
(`rift/.git/config:9`) — a personal fork/move, so "from dark-trench" holds for the
metadata, not for this checkout:

- `~/workspace/claws/squidie` — **Squidie 0.1.3**, "Durable workflow runtime for Elixir applications." ~27k LOC. 637 commits since 2026-04-27 (born as **Squid Mesh**), Hex-published **2026-06-01** (v0.1.0), renamed to Squidie **2026-06-03** (v0.1.2). Deps: `jido ~> 2.0`, `runic ~> 0.1.0-alpha`, `spark ~> 2.7`, `ecto_sql ~> 3.13`.
- `~/workspace/claws/squid_sonar` — **SquidSonar 0.1.7**, "Embeddable runtime dashboard for Squidie." ~3k LOC. An embeddable Phoenix LiveView **ops dashboard / control surface** you mount in a host app — *not* read-only: alongside inspect/graph/explain it exposes run controls (cancel/resume/approve/reject/replay) via `SquidSonar.Runs` (`runs.ex:43-96`) wired to LiveView events (`run_live.ex:48-120`). Deps: `phoenix ~> 1.8.1`, `phoenix_live_view ~> 1.1`, `squidie ~> 0.1.2`.
- `~/workspace/claws/rift` — **Rift 0.1.0 (ARCHIVED)**, "Phoenix LiveView ops inbox for human workflow decisions." ~3.7k LOC. Example app: host declares *case types*, users open cases via forms, each case starts one Squidie run, operators review in an inbox. Raw Ecto (`Rift.Repo`).

## Determination (TL;DR)

**Do not adopt any of the three as a dependency. Borrow patterns selectively.**

| Project | As a dependency | What to take |
| --- | --- | --- |
| Squidie | ❌ No | The event-sourced run-log architecture + a few small portable modules (retry policy, deadline, fingerprint/replay gates, redaction list) |
| SquidSonar | ❌ No — jido_radclaw already has a dashboard | The workflow-graph layout algorithm only (copy, don't dep) |
| Rift | ❌ No — archived, raw Ecto, requires Squidie | The case + immutable-event-log model and the human-gate DSL idea |

Squidie is genuinely well-engineered — append-only journal, projection-rebuildable Jido agents, optimistic-concurrency fencing, saga compensation, lease/heartbeat workers. It is the durable workflow engine that jido_radclaw's `orchestration/` subsystem only *pretends* to be. But the integration cost is wrong for this codebase (see below), and its single most valuable idea is portable without the dependency.

## Why not adopt Squidie as a dependency

1. **Ash-vs-raw-Ecto is structural, not cosmetic.** Squidie owns its tables (`squidie_journal_threads`, `squidie_journal_entries`, `squidie_journal_checkpoints`) as three raw `Ecto.Schema` modules (`lib/squidie/persistence/journal_*.ex`) and stores payloads as opaque `:erlang.term_to_binary` blobs under a custom `:squidie_ecto_term_v1` codec (`lib/squidie/runtime/journal/storage/ecto.ex:352`, `:371`). All run state would be invisible to the machinery jido_radclaw is built on — Ash policies, attribute multitenancy, paper-trail, archival, AshAdmin. You'd run two parallel persistence universes in one Postgres.
2. **Purpose mismatch.** Squidie's primary surface is *developer-authored, compiled* Spark workflow modules. It *does* have a runtime-authored spec path (`Squidie.start_spec/3,4`, validated against a host-owned action registry — `squidie.ex:193-238`), so it is not strictly compiled-only — but that path is still not jido_radclaw's model (*YAML skills that LLMs and humans edit at runtime* in `.jido/skills/`, plus an agent swarm), and Squidie **deliberately rejects replay of runtime-spec runs** (`{:error, {:invalid_replay_source, :runtime_spec}}`, `runtime/journal/replay.ex:84-85`) — i.e. the editable-definition case our skills live in is exactly the one its replay machinery refuses. Adopting Squidie would either duplicate the skill-DAG engine (`lib/jido_claw/workflows/plan_workflow.ex`) or force skills behind a recompile boundary.
3. **Scale mismatch.** 27k LOC of distributed lease/fencing/multi-worker infrastructure for a single-operator, single-node, tailnet tool. You'd carry the complexity (and an alpha `runic` dep) without needing the distribution. (See [project threat model].)
4. **Maturity.** Days-old on Hex by its current name, single primary author, riding an alpha transitive dep (`runic 0.1.0-alpha`). Fine to learn from; risky as load-bearing core infrastructure.
5. **It would replace-or-duplicate, not complement.** jido_radclaw already has a (weak) orchestration subsystem *and* a skill-DAG engine. Squidie doesn't slot beside them; it overlaps both.

## The one architectural lesson

jido_radclaw's orchestration **mutates a `status` column directly** (`lib/jido_claw/orchestration/workflow_run.ex:47-96`). There is no journal, no replay, no recovery. A BEAM crash mid-run strands the row in `:running` forever — the in-memory skill driver dies and nothing reconciles the row. Squidie's core insight is the fix: **derive run/step status from an append-only event log, not by mutating a column.** That's T1-1 below, and it has a companion implementation plan: [`T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](T1-1-WORKFLOW-EVENT-LOG-PLAN.md).

## Reactor is the execution kernel; these concepts are the durable envelope

**Update (2026-06-04, post-exploration):** after this inventory was written we worked
through how these borrows interact with **Ash Reactor** (`reactor 1.0.2`, already a
non-optional dependency of `ash 3.27.7` — no new deps required). The conclusion
reframes the whole inventory:

> Reactor is the **execution engine** (DAG, concurrency, saga compensation + undo,
> step retry/backoff, pause/resume). The Squidie-borrowed concepts are the **durable
> envelope** around it (append-only event log, status projection, crash recovery,
> human gates, replay, read-models). They stack — they don't compete.

The decided direction is to make **Reactor the single workflow engine** and compile
the YAML skill surface down to Reactor (via `Reactor.Builder`), retiring the bespoke
skill-DAG drivers. The full target architecture and phased plan live in
[`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md). Where entries below say "keep the skill
DAG," read that as superseded by the Reactor doc. The revisions this implies are
folded into T1-1, T1-2, and S-1 below.

## How to read this document

Unlike the hermes/jidoka inventories (which track *our adoption status over time* against competing platforms), this one is a fresh **library-adoption** assessment. The axis that matters is the recommendation, not a date-stamped status:

- **ADOPT-AS-DEP** — worth depending on the upstream package for this.
- **BORROW-PATTERN** — the design is worth reimplementing natively in Ash/Jido idiom.
- **SKIP** — not worth it (redundant, over-built for a single-operator tool, or mismatched).

Tiers are scoped to **this** codebase: Tier 1 = clear gap + high leverage; Tier 2 = useful, more design; Tier 3 = polish. A "Skip / Already Covered" section follows.

Per entry: **Recommendation**, **Where** (source file:line), **What**, **Gap in jido_radclaw**, **Why it matters**, **Adoption sketch** (jido_radclaw idiom — OTP, Ash, Jido, Phoenix). Borrowing means translating, not transplanting.

> Note on cites: dates, git history, the `runic` dep, and the term-codec opacity were verified directly. The remaining Squidie/SquidSonar/Rift `file:line` references come from a deep read of each tree and are accurate to within a few lines; treat them as "start here," not as gospel.

---

## Tier 1 — High Impact

### T1-1. Append-only workflow event log → derive status from it

**Recommendation**: BORROW-PATTERN (high impact). Companion plan: [`T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](T1-1-WORKFLOW-EVENT-LOG-PLAN.md).

**Where**: `lib/squidie/runtime/journal.ex`, `lib/squidie/runtime/dispatch_protocol.ex:21-138` (the 18-entry vocabulary — including `:live_wakeup_emitted` — with required-field validation), `:336-349` (automatic redaction of sensitive metadata keys before persist), `lib/squidie/runtime/agent_recovery.ex:32-62` (two-window recovery: drain planned-but-unscheduled, then apply completed-but-unapplied).

**What**: Every workflow state transition is an append-only fact in a journal (`run_started`, `runnables_planned`, `attempt_scheduled`, `attempt_claimed`, `attempt_completed`, `runnable_applied`, `run_terminal`, …). The "current state" of a run is a *pure projection* of its facts — the `WorkflowAgent`/`DispatchAgent` Jido agents hold no inherent durability and rebuild from the log on demand. Each append is fenced with `expected_rev` for optimistic concurrency.

**Gap in jido_radclaw**: `WorkflowRun` is a status machine that mutates a column in place (`workflow_run.ex:47-96`). `WorkflowStep` and `ApprovalGate` resources exist but are barely wired — `WorkflowRunner` never creates a single step row (`workflow_runner.ex:120-147`) and never calls `await_approval`. There is no event log, no replay, no recovery. Crash mid-run = stranded `:running` row.

**Why it matters**: This is the highest-leverage borrow in the inventory. An append-only event log (a) fixes the crash-stranding bug via a boot-time reconcile pass, (b) finally populates the step timeline the dashboard wants, (c) is the substrate every other Tier-1/2 Squidie borrow builds on (fingerprinting, retry history, deadlines, recovery), and (d) gives a durable audit trail aligned with the leakage-hygiene threat model.

**Adoption sketch**: New append-only Ash resource `JidoClaw.Orchestration.WorkflowEvent` (`workflow_run_id`, helper-allocated `seq`, `kind`, `payload`, `metadata`, `occurred_at`) under `use JidoClaw.Resource` so it inherits tenant scoping + policies. Adopt Squidie's entry-kind vocabulary (trimmed to jido_radclaw's reality and shaped to Reactor's transitions — see Reactor doc §4.2: `run_started`, `run_resumed`, `step_started/completed/failed/retried`, `step_compensated/undone`, `approval_requested/resolved`, `run_halted`, `run_completed/failed/cancelled`, `run_recovered`). Scrub payload/metadata before persist with a **recursive, key-aware** redactor — **not** `Patterns.redact/1`, which only regex-scans *binaries* and passes maps straight through untouched (`patterns.ex:44-51`), so handing it an event payload map redacts nothing. Use `JidoClaw.Security.Redaction.Transcript.redact/2` (walks maps/lists, scrubs string leaves via `Patterns`, replaces values under sensitive key names). Widen its key set: `Transcript` defers to `Redaction.Env.sensitive_key?/1`, whose *suffix-only* rule (`_KEY`/`_TOKEN`/`_SECRET`/…) catches `api_key`/`access_token` but **misses the bare keys** `password`, `secret`, `token`, `authorization`, `credential` that event payloads carry — add those, cross-referenced against Squidie's list at `dispatch_protocol.ex:336-349` (`access_token`, `api_key`, `authorization`, `claim_token`, `credential`, `password`, `private_key`, `refresh_token`, `secret`, `token`).

**Reactor-aware revision**: with Reactor as the engine, the **primary** event producer is a `Reactor.Middleware` (one append per step/run lifecycle transition; §4.4/§4.5 add deliberate non-middleware writers) rather than per-driver dual-writes — see [`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md) §"The event-log producer". Two consequences: (1) status becomes a **pure projection** of events from day one (greenfield — no dual-write phase needed); (2) for side-effectful `Ash.Reactor` action steps, the authoritative "side effect committed" fact can be appended **inside the same DB transaction** as the mutation, eliminating dual-write drift. Note `Reactor.Middleware.event/3` blocks the reactor, so the high-volume *per-step* timeline appends hand off to an async writer — but the run-lifecycle events are written **synchronously and durably**: `run_started`/`run_resumed`/`run_halted`/terminals via the middleware's run-lifecycle callbacks (`init`/`halt`/`complete`/`error`), and `approval_requested`/`approval_resolved` by the gate step / decision flow (in-transaction). All but `run_halted` are **status-authority** (they fold into the materialized status column); `run_halted` rides the same synchronous path as durable provenance but moves no status (Reactor doc §4.1) — so status stays durable (§4.1/§4.3). The boot reconciler **reconciles** non-terminal runs whose run is no longer live: resume only a recorded decision, leave unresolved gates parked, and fail stranded/no-decision runs (Reactor doc §4.8). Full phasing in the companion plan + the Reactor doc.

---

### T1-2. Retry policy with backoff

**Recommendation**: ~~BORROW-PATTERN (port verbatim, ~100 LOC)~~ → **REVISED to SKIP — use Reactor's native retry.** Reactor steps already have `max_retries` + a `compensate` callback that returns `:retry`, with backoff (verified in the reactor 1.0.2 error-handling guide). Once Reactor is the engine, porting Squidie's `RetryPolicy` module is redundant. The Squidie module was only valuable *absent* an execution engine; Reactor supplies it. Keep the *idea* (declarative per-step retry) — take Reactor's implementation, not Squidie's.

**Where**: `lib/squidie/runtime/retry_policy.ex` (`:40-43` resolves `:retry | :exhausted | :no_retry` from the attempt number against `[max_attempts: N, backoff: [type: :exponential, min: ms, max: ms]]`).

**What**: A pure module: a step declares a retry policy; given the current attempt count, the module decides whether to retry and how long to wait. Exponential/linear backoff with floor/ceiling.

**Gap in jido_radclaw**: Workflow steps have no retry semantics at all. The drivers (`IterativeWorkflow`/`PlanWorkflow`/`SkillWorkflow`) run once and either succeed or fail the run.

**Why it matters**: LLM/tool steps are exactly the flaky-by-nature work retries exist for (provider 429s, transient tool failures, network). The algorithm fits on a postcard — there is no reason to take a dep for it, and no reason *not* to have it.

**Adoption sketch**: Use Reactor's step-level `max_retries` + `compensate`/`:retry`. Skills express retry as optional per-step `retry:` metadata in their YAML, which the skill→Reactor compiler ([`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md) §"Skills on Reactor") translates into Reactor step options. `step_retried` lifecycle facts still land in the T1-1 event log via the middleware. Future: gate retries on the provider error classifier (hermes T1-4) so only `retryable?` reasons retry — wire that into the `compensate` callback.

---

### T1-3. Workflow/skill fingerprinting + replay safety gates

**Recommendation**: BORROW-PATTERN.

**Where**: `lib/squidie/runtime/journal/replay.ex:108-152` (validates the persisted definition fingerprint against the current one; blocks replay of irreversible steps unless `allow_irreversible: true`).

**What**: Each compiled workflow has a stable fingerprint (hash of steps + transitions + retries). `replay/2` refuses to relaunch a run if the definition changed since it first ran, and refuses to replay across steps marked `irreversible: true` / `compensatable: false` unless an operator explicitly overrides.

**Gap in jido_radclaw**: `WorkflowRun` has a `retry_of_id` column (`workflow_run.ex:161`) but no replay machinery and no notion of "the skill changed between run and retry" or "this step can't be safely re-run."

**Why it matters**: Skills are editable YAML that LLMs rewrite. Replaying a run after the skill file changed could silently execute different semantics. And re-running a step that, say, sent an email or pushed a commit is a real-world footgun. These two gates are cheap safety properties.

**Adoption sketch**: Hash the resolved skill YAML at run start; persist it in the `run_started` event payload. A `WorkflowRun.replay` Ash action recomputes the hash and refuses on mismatch (or warns + requires `force: true`). Add `irreversible:` / `compensatable:` markers to skill step metadata; gate replay on them.

---

### T1-4. Human-decision case + immutable event-log model

**Recommendation**: BORROW-PATTERN (high impact — from Rift).

**Where**: `rift/PLAN.md:14-18` (layering rationale), `:82-92` ("a case is exactly one workflow run"); `rift/lib/rift/cases/case.ex:30-45` (the `rift_cases` schema), `rift/lib/rift/cases/event.ex` (the immutable `rift_case_events` log, 13 event types), `rift/lib/rift/cases.ex:91` (open-case-in-a-transaction with the first event).

**What**: A *case* wraps one workflow run with a human-decision domain layer: a JSON `details` map of the submitted request, a `status` cache (10 states: `draft/open/running/waiting_for_approval/approved/rejected/cancelled/failed/side_effect_failed/completed`), and an **immutable append-only event timeline** (`case_opened`, `workflow_started`, `case_approved`, `case_rejected`, `case_cancelled`, `side_effect_completed`, `side_effect_failed`, `system_note`, …).

**Gap in jido_radclaw**: `ApprovalGate` (`approval_gate.ex`) is *just* `pending → approved | rejected` with one `comment` string and no history. There is no durable record of "what did the agent try to do at 02:00, and what did I approve/reject and when."

**Why it matters**: For an autonomous agent that acts while you sleep, the audit timeline is the product. A single-operator tool still wants to answer "what happened, in what order, who decided what." This is the right shape to grow `ApprovalGate` into.

**Adoption sketch**: Grow `ApprovalGate` into a pair: `JidoClaw.Orchestration.AgentCase` (belongs_to `WorkflowRun`; `type`, `subject`, `details` map, `status`, `state` map) + `AgentCaseEvent` (immutable `case_id`, `actor_id`, `type`, `data`, `inserted_at`). Each lifecycle action persists the state change **and** an event in one Ash transaction. Drop Rift's multi-actor scaffolding (`visible_to_originator`, `team`, `assignee_ref`/claim-assign, read-receipts) — single operator. This naturally rides on the T1-1 event log (an `AgentCaseEvent` is a specialization of the run-event idea applied to human gates).

---

## Tier 2 — Medium Impact

### T2-1. Deadline read-model

**Recommendation**: BORROW-PATTERN (~100-290 LOC port).

**Where**: `lib/squidie/runtime/deadline.ex:25-30` (computes `:on_time | :due_soon | :overdue | :escalated` from `[within: ms, due_soon: ms, escalate_after: ms]` + a `started_at`). Explicitly *evidence*, not a cancellation primitive.

**What**: A step/run declares a deadline policy; the read-model reports lateness status for dashboards and escalation, without itself killing anything.

**Gap in jido_radclaw**: Nothing equivalent. A long-running agent step has no "this is taking too long" signal.

**Why it matters**: Cheap operator-facing evidence ("this run is overdue") for the dashboard and for cron/escalation hooks. The non-cancelling design is fine — keep cancellation a separate, explicit action.

**Adoption sketch**: Port as a small module or an Ash calculation over the T1-1 event log's `started_at`. Surface in the workflow read projection (`workflow_view.ex`).

### T2-2. Actor-visibility read-model redaction

**Recommendation**: BORROW-PATTERN (threat-model aligned).

**Where**: `lib/squidie/read_model/visibility.ex` + `docs/actor_visibility.md` (a host policy callback returns `:external | :operator | :auditor`; the read model is redacted server-side before serialization).

**What**: Run inputs/outputs/error payloads are redacted by default and only revealed to an elevated actor scope. Redaction happens in the projection layer, before the data reaches any surface.

**Gap in jido_radclaw**: Run `result`/`error` maps are `public?: true` on `WorkflowRun` (`workflow_run.ex:151-159`); `config` is `public?(false)` (`:145-149`), so it's the two LLM-facing payload maps (`result`/`error`) that leak. Those payloads can carry secrets or injected content; the dashboard renders them.

**Why it matters**: Directly serves the leakage-hygiene threat model — keep LLM-generated payloads off the dashboard by default, reveal only to an `:auditor` scope. jido_radclaw already has the redaction toolkit (`security/redaction/`); this is the *projection-layer scope* discipline to pair with it.

**Adoption sketch**: A visibility scope on the workflow read projection; default `:operator` sees metadata + status, `:auditor` sees payloads. For the actual scrubbing use the **recursive** `Redaction.Transcript.redact/2` — the run `result`/`error`/inputs are maps, and both `Redaction.Patterns.redact/1` and `Redaction.UiRedaction.redact/1` only scan binaries and pass maps through unchanged (`patterns.ex:44-51`, `ui_redaction.ex:7-8`), so on a payload map they redact nothing (same trap as T1-1; widen the sensitive-key set the same way).

### T2-3. Cron idempotency / return-existing-run

**Recommendation**: BORROW-PATTERN (small, high-hygiene).

**Where**: `lib/squidie/runtime/schedule_identity.ex` (derives a deterministic run identity from signal-id / intended firing window; `idempotency: :return_existing_run` returns the existing run instead of double-firing).

**What**: A duplicate cron delivery for the same intended window deterministically resolves to the run that already exists, rather than starting a second one.

**Gap in jido_radclaw**: `WorkflowRunner.create_and_start/4` (`workflow_runner.ex:89-118`) creates a fresh `WorkflowRun` on every tick with no dedupe. A double-delivered cron tick = two runs.

**Why it matters**: Cron at-least-once delivery + retries make duplicate firings a real possibility; idempotent run identity is cheap insurance against double side effects.

**Adoption sketch**: Derive a deterministic key `cron:<job_id>:<window>` and add a unique index / upsert in `WorkflowRunner`; on conflict, return the existing run.

### T2-4. Lease/fencing claim discipline for workers

**Recommendation**: BORROW-PATTERN (future-proofing; not needed today).

**Where**: `lib/squidie/runtime/journal/executor.ex:140-371` (claim fenced by `claim_id` + `claim_token_hash`; heartbeat extends `lease_until`; completion with a stale token is rejected).

**What**: A worker atomically claims one unit of work with a fencing token and a lease; a heartbeat extends the lease; if the worker dies the lease expires and the work becomes claimable again; a late completion from a fenced-out worker is refused.

**Gap in jido_radclaw**: Drivers run in-memory in the calling process. If the swarm ever spawns multiple workers against the same run, there is no fencing — two workers could race a step.

**Why it matters**: Today jido_radclaw is single-node single-worker, so this is genuinely not urgent. But the swarm is designed to spawn many agents; if workflow execution ever fans across them, fencing prevents double-execution. Worth knowing the shape.

**Adoption sketch**: A `WorkflowAttempt` Ash resource (`claim_id`, `claim_token_hash`, `lease_until`) + an atomic claim action with optimistic version. Defer until multi-worker execution is real.

### T2-5. Spark DSL for declaring human-gate kinds

**Recommendation**: BORROW-PATTERN (pairs with T1-4 — from Rift).

**Where**: `rift/lib/rift/case_type.ex:73` (`use Rift.CaseType`), `case_type/dsl.ex`, `case_type/spark_extension.ex` (two sections: scalar `case_type` opts + a nested typed `fields` section), `case_type.ex:13` (8 field types), `case_type.ex:41-56` (lifecycle hooks).

**What**: Declare a *kind* of human decision once — stable atom id, title/description, optional workflow binding, typed input fields (text/select/textarea/…), and lifecycle hooks (`after_approved`, `after_rejected`, …). The DSL describes the *presentation* of a transactional human interaction — something Ash resources (which describe persistence) don't give you.

**Gap in jido_radclaw**: `ApprovalGate` is one undifferentiated shape with a `reason` string. There is no taxonomy of approval moments (tool-call approval vs. plan approval vs. irreversible-write approval) and no declarative field metadata for rendering them.

**Why it matters**: An agent needs distinct, well-described human checkpoints with the right fields and the right follow-up. A small Spark DSL is idiomatic here (jido_radclaw already runs Spark via Ash) and turns ad-hoc gates into a declared catalog.

**Adoption sketch**: `JidoClaw.HumanGates.<Kind>` modules via a Spark DSL (`gate do type …; fields do …; end end`) with `after_approved/2`/`after_rejected/2` that emit a `jido_claw.orchestration.gate_decided` signal the suspended workflow resumes from. **Collapse Rift's resolver indirection** (`{:resolver, :field}` + `build_payload/2`) — Rift needs it because it never sees host data; jido_radclaw *is* the host and can call `JidoClaw.*` directly.

---

## Tier 3 — Polish

### T3-1. Workflow-graph layout algorithm

**Recommendation**: BORROW-PATTERN (copy, don't dep — from SquidSonar; low urgency).

**Where**: `squid_sonar/lib/squid_sonar_web/workflow_graph_layout.ex` (~254 LOC, pure functions): topo order by input position (`:38-50`), longest-path column assignment (`:61-77`, Bellman-Ford-style relaxation), parent-preferring greedy row assignment (`:79-130`), dog-leg orthogonal edge routing (`:193-213`). Rendered as CSS-positioned divs (not SVG) in `core_components.ex:553-619`.

**What**: A hand-rolled Sugiyama-lite DAG layout that turns `{nodes, edges}` into pixel positions for a layered graph, rendered as absolutely-positioned HTML so it themes via CSS variables.

**Gap in jido_radclaw**: `WorkflowsLive` (`web/live/workflows_live.ex`) is a plain HTML table. No graph visualization for run→step lineage or the agent-handoff/swarm tree.

**Why it matters**: A clean ~250 LOC pure-functional module that would visualize the T1-1 step timeline or the swarm tree. Nice-to-have, not load-bearing — borrow once a dashboard tab actually needs it.

**Adoption sketch**: Copy as `JidoClaw.Web.Components.GraphLayout`, drop Squidie's deadline/recovery node-height variants, feed it from two adapters (one over `WorkflowStep` rows deriving edges from `sequence`, one over the `AgentTracker` spawn lineage). The upstream module is `@moduledoc false` and coupled to Squidie's node shape — copy + adapt, don't depend.

### T3-2. CSS-positioned-div graph rendering

**Recommendation**: BORROW-PATTERN (only if T3-1 is taken).

**Where**: `squid_sonar/lib/squid_sonar_web/components/core_components.ex:790-799` (`workflow_node_style/1`, `workflow_segment_style/1`, `workflow_port_style/1`).

**What**: Renders nodes/edges as absolutely-positioned HTML elements rather than SVG, keeping theming consistent and avoiding SVG/HTML interop. Trade-off: no cheap zoom/pan.

**Why it matters**: If you adopt T3-1, adopt the rendering style with it — it slots into jido_radclaw's existing LiveView theming with no SVG machinery.

---

## Skip / Already Covered

- **S-1. Saga / compensation → use Ash Reactor (now the whole engine, not just the saga).** Squidie's compensation walker (`runtime/journal/compensation.ex:149-172`, reverse-order compensatable-step scheduling) is elegant, but **Reactor is already in the dep tree (`reactor 1.0.2` via `ash 3.27.7`), is Ash-native, and supports `compensate` + `undo` directly.** Crucially, `Ash.Reactor` action steps (`create`/`update`/`destroy`/`action`/`bulk_*`) support **declarable, durable per-step `undo`** — when you opt in (it defaults to `undo: :never`; durable rollback requires declaring an `undo_action` plus `undo: :always | :outside_transaction`), reversal is a *durable* action (e.g. a destroy's undo is a recreate), not an in-memory closure that evaporates on a VM crash. That opt-in durable undo is still strictly better than Squidie's walker for our threat model. Don't reimplement compensation; model side-effectful workflows as `Ash.Reactor` and declare undo on the steps that need it. See [`REACTOR-ADOPTION.md`](REACTOR-ADOPTION.md) §4.6.
- **S-2. Cron triggers → already more capable.** jido_radclaw's cron subsystem (`platform/cron/{dispatcher,scheduler,worker}.ex`) on `crontab` + `time_zone_info` with tenant scoping and `target` routing is more capable than Squidie's "declare cron intent, host enqueues" model. (Take only the T2-3 idempotency idea.)
- **S-3. Dynamic work / fan-out → swarm covers it.** `Squidie.schedule_dynamic_work/3` (bounded fan-out from inside a step with an action-registry allowlist) duplicates what the swarm + sub-agent spawning already does in spirit. Revisit only if you ever expose dynamic-graph editing in the dashboard.
- **S-4. Storage-adapter abstraction → SKIP.** `runtime/journal/storage.ex` exists so Squidie can be backend-portable. jido_radclaw is single-deployment Ash+Postgres; the abstraction is pure overhead here.
- **S-5. Tool adapters → SKIP.** `lib/squidie/tools/*` normalizes `{:ok, Result} | {:error, Error}` around HTTP. jido_radclaw has ~31 `Jido.Action` tools with their own conventions.
- **S-6. Observability / telemetry → SKIP.** Squidie ships no public telemetry contract (`docs/observability.md`). jido_radclaw already has `Trace`, the signal bus, the LiveView dashboard, and `AgentTracker`.
- **S-7. SquidSonar wholesale → SKIP.** It's a dashboard for *Squidie*; jido_radclaw has its own (`web/live/*`, `workflow_view.ex`, `inspection.ex`). It also pulls `:squidie` and targets Elixir 1.17. Take only T3-1.
- **S-8. Rift router-macro / resolver / live_auth / multi-actor scaffolding → SKIP.** `Rift.Router` embeddable macro, `Rift.Resolver` host-context behaviour, `Rift.LiveAuth` operator/originator split, claim/assign/team, `rift_case_reads` receipts, `mix rift.install` raw-Ecto migration generator — all multi-tenant-SaaS / multi-operator scaffolding. jido_radclaw is the single-operator host and uses Ash codegen for migrations. Keep only T1-4 + T2-5.

---

## Dependency & compatibility notes

- **`runic 0.1.0-alpha`** is the concerning transitive dep if you ever vendored Squidie code. Net-new to jido_radclaw's tree: `runic`, `flow`, `gen_stage`. Already present: `multigraph`, `uniq`. Inside Squidie, Runic's role is narrow — `RunicPlanner` (`workflow/runic_planner.ex`) uses it only as a dependency-readiness solver; a homegrown topo-sort could replace it. If you ever lift a Squidie module, lift the source and skip Runic.
- **Elixir version**: Squidie targets `~> 1.18` (CI on 1.19/OTP 28); jido_radclaw is on 1.20/OTP 29 ([toolchain]). The constraint is permissive and nothing in Squidie's own code uses APIs removed in 1.20 — Runic-alpha is the wildcard. Not verified at runtime.
- **Jido version**: Squidie wants `jido ~> 2.0`; jido_radclaw overrides to `~> 2.1`. Compatible. (The old `memento` blocker no longer applies — see [toolchain].)
- **Persistence opacity**: Squidie's journal payloads are `term_to_binary` blobs (`storage/ecto.ex:352`), not SQL-queryable columns. This is the crux of "don't adopt as dep" — confirmed by direct read.

## Appendix — Squidie public API surface (`lib/squidie.ex`)

For reference, the host-app surface a dependency would expose:

| Function | Purpose |
| --- | --- |
| `start/2-4`, `start_spec/3-4` | Start a run (compiled workflow / runtime-authored spec) |
| `start_child_run/4-5` | Idempotent child run from inside a step |
| `execute_next/1` | Claim + execute one visible attempt (host-worker entrypoint) |
| `inspect_run/2`, `inspect_run_graph/2`, `explain_run/2` | Read-only snapshot / graph / operator explanation |
| `list_runs/2` | Redacted run summaries |
| `cancel/2`, `resume/1-3`, `approve/3`, `reject/3` | Lifecycle control |
| `replay/2` | Fresh run from a prior run's trigger+input (irreversible-gated) |
| `preview_dynamic_work/3`, `record_dynamic_work/3`, `schedule_dynamic_work/3` | Bounded dynamic fan-out |
| `apply_signal/2` | CloudEvents-style command envelope |
| `config/0-1`, `config!/0-1` | Config loading with required-key validation |

<!-- Links: [project threat model], [toolchain] refer to memory notes in this repo's exploration context. -->
