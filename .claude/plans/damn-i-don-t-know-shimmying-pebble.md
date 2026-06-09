# Finish Phases 0–3: implement the claimed-but-skipped items

## Context

A review of `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` against the four
"done" commits (Phase 0 event log, Phase 1 first reactor, Phase 2 human gates, Phase 3
skills-on-Reactor) found that the **durable spine is solid** (redaction trap avoided +
key-set widened, `seq` under a `FOR UPDATE` lock, status materialized in-txn, gate-only
halt guard, Strategy-A persist-the-halted-struct, the stranding bug fixed and tested) —
but several items that were **claimed as part of those phases were silently deferred or
diverged from spec**, mostly with honest moduledoc notes, a few with no marker at all.

The goal of this plan: **actually complete Phases 0–3** before starting the next phase.
This is greenfield — no compatibility layers, no data migrations to preserve, free to
redo work in a better shape. Phase 4 (replay/fingerprint) and Phase 5 (deadlines,
actor-visibility read-model, cron idempotency, graph layout) remain **out of scope** —
they are genuinely future phases, not claimed-done work.

### Decisions locked (from the user)

1. **Gate definition → build the real Spark DSL** (`Spark.Dsl.Extension`), not the
   current plain behaviour. This would be the **first Spark DSL defined in the repo**.
2. **Define all three gate kinds now** — `tool_call`, `plan`, `irreversible_write` —
   even though only `irreversible_write` has a live producer today.
3. **Dangling-gate recovery → `run_failed` + full audit** (`run_recovered` + `run_failed`
   + cancel the open case → status `:failed`), not the current `run_cancelled` → `:cancelled`.

### Explicit non-goals (verified considered, deliberately excluded)

- **Phase 4/5 items**: definition fingerprint/replay, deadline read-model, cron
  idempotency, graph-layout visualization. Future phases.
- **Actor-visibility read-model (T2-2)**: `WorkflowRun.result`/`error` stay `public?: true`
  for now — that redaction *scope* is Phase 5. (The dashboard doesn't render the raw
  `result` map today; `WorkflowView` exposes only a whitelisted summary.) Tracked, not fixed here.
- **Branching (`switch`) / sub-skills (`compose`)**: no YAML surface expresses them and the
  old drivers never had them — aspirational §5 mappings, not a regression.
- **Async step-timeline `Writer` + barrier (§4.3)**: documented deferral; synchronous appends
  under the per-run `FOR UPDATE` lock are strictly safer and not in the T1-1 completion bar.
  WS3 below adds step-row writes to that same synchronous path — acceptable now; the async
  Writer remains a future optimization.
- **`iterative` → Reactor `map`/`recurse`**: keep the existing hand-rolled `iterate/5` loop
  (`skills/steps/iterative_step.ex`) — behavior is correct. Consequence: an iterative skill
  projects as **one** `WorkflowStep` row (its inner turns are invisible to Reactor `event/3`).
  Accepted limitation; recorded via `step_type: "iterative"`.

---

## Build order

Dependency-honoring sequence (each tier is independently shippable + verifiable):

```
WS2 → WS1 → (one middleware pass: WS3-prep + WS10) → WS3 → WS4 → WS6 → WS5 → WS7 → WS8 → WS9 → WS11
```

Rationale: tenancy migration (WS2) precedes the projector (WS3) that writes tenant-scoped
rows; the `step_payload` enrichment WS3 needs lives in the same file as the Trace emit
(WS10), so do them together; the Spark DSL (WS6) precedes AR-1 (WS7) whose hooks live on
gate modules; `AgentCaseEvent` (WS5) precedes AR-1 (abandon appends a case event); recovery
(WS8) shares the terminal-kind vocabulary with abandon; AshCloak (WS9) is last among
`WorkflowRun`-touching work because it renames the checkpoint column everything else reads.

---

## Tier 0 — data-model foundations

### WS2 — Migrate `WorkflowStep` to tenant-scoping

**Why:** `lib/jido_claw/orchestration/workflow_step.ex` is plain `use Ash.Resource` with
**no `tenant_id`, no multitenancy, no authorizer, no policies** — and is currently
**orphaned** (zero callers create a row). The Phase 0/T1-1 completion bar required step rows
to be projected and tenant-consistent; WS3 will write them, so they must be tenant-scoped first.

**How:** Mirror the **`WorkflowEvent`** shape exactly (`workflow_event.ex:19-54`): plain
`use Ash.Resource` + a `multitenancy do strategy(:attribute); attribute(:tenant_id);
global?(false) end` block + a `tenant_id :string` attribute + a `belongs_to :tenant`
(`define_attribute?(false)`) + the two hand-written tenant policies. **Do not** use
`JidoClaw.Resource` — its macro injects `bypass action(:by_id_global)`, which won't compile
without that action (documented at `workflow_event.ex:7-12`).

**Watch:** this is "authorizer + multitenancy + two policies + every call site now threads
`tenant:`/`actor:`," not just a column. The resource has no callers today, so the sweep is
small — but grep `WorkflowStep.` before estimating.

### WS1 — Claim/fencing data model on `WorkflowRun`

**Why:** The §4.11 "land the data model **now** (greenfield — no later migration)" item was
moved past with no marker — adding it later would force exactly the migration the doc tried
to avoid. Implementation (Pooler/Lease) stays deferred; only the columns + indexes land.

**How:** Add to `lib/jido_claw/orchestration/workflow_run.ex`: `claimed_by :string`,
`claim_expires_at :utc_datetime_usec`, `claim_token :uuid` (all nullable, `public?(false)`),
plus `custom_indexes` `[:status, :claim_expires_at]` and `[:claimed_by]`. **Index scope is
deliberate: global, NOT tenant-prefixed** — the future `:claim_next` lease scanner is a
system-level cross-tenant poller (like recovery's `list_non_terminal_global`). AshPostgres
auto-prefixes attribute-multitenant indexes unless told otherwise
(`ash_postgres/migration_generator/operation.ex:133`), so declare both with
**`all_tenants?: true`**. No actions, no behavior. **Bundle this edit with the
WS9 decision about WorkflowRun's resource declaration** (both touch the same file) — see WS9.

---

## Tier 1 — middleware event enrichment (one pass over `reactor_middleware.ex`)

### WS3-prep — Enrich `step_payload/1`

**Why:** `reactor_middleware.ex:230` emits only `%{step: inspect(step.name)}`, where
`step.name` is the **positional** id (`:step_1`), and discards the YAML step name + the step
result. WS3's projector needs the human name and output.

**How:** The YAML name is already threaded into impl options by the compiler
(`step_name: Map.get(step, :name)`, `compiler.ex:260`) and Reactor stores impl as
`{module, options}` on the step struct (`reactor/lib/reactor/step.ex:34`). Read
`step.impl → {_mod, opts} → opts[:step_name]` and include it plus, for `:step_completed`,
a JSON-safe summary of the result. Keep positional id as a fallback.

**Also in this pass — `map_event` clauses for compensate-driven retries:** WS4's retry policy
fires through `compensate/4 → :retry`, and Reactor emits **`:compensate_retry` /
`{:compensate_retry, reason}`** for that path (`step_runner.ex:279-292`) — but `map_event`
today maps only `:run_retry` to `:step_retried` (`reactor_middleware.ex:220-221`), and the
catch-all `:ignore` would silently drop them. Add clauses mapping both `:compensate_retry`
shapes → `:step_retried` now (inert until WS4 lands; without them WS4's retry verification
can't see its own events).

### WS10 — Wire `JidoClaw.Trace.emit(:workflow, …)`

**Why:** The Trace collector already attaches `[:jido_claw, :workflow, :event]`
(`trace/collector.ex:100`) but **nothing emits it** — the new middleware feeds only the
`WorkflowEvent` DB log + `RunPubSub`, so the live in-flight workflow overlay is dark
(open-question #4, effectively a regression vs the old path).

**How:** In the run-lifecycle hooks (`init`/`complete`/`error`/`halt`,
`reactor_middleware.ex:93-199`), add `JidoClaw.Trace.emit(:workflow, metadata, measurements)`
mirroring the verified shape in `tools/handoff.ex:339-374` (`event`, `status`, `name`,
`run_id`, `tenant_id`, plus `%{duration_ms: …}`). Thread `run.id` into metadata so events
correlate. Pure addition — same file/hooks as WS3-prep, so do both in one pass.

---

## Tier 2 — step projection + per-step metadata

### WS3 — Project `WorkflowStep` rows from `step_*` events

**Why:** T1-1 completion-bar item #3 ("WorkflowStep rows projected from step events so the
dashboard step view is no longer empty") was never done — `step_*` events hit the log but no
projector creates rows; `projection.ex` is run-status only.

**How:** Add an `after_action` branch in `WorkflowEvent.Changes.Allocate`
(`workflow_event/changes/allocate.ex`, alongside `maybe_update_status/2`) keyed on `step_*`
kinds — in-transaction so it rides the per-run `FOR UPDATE` lock (gap-free, consistent),
threading `tenant: changeset.tenant` exactly as the status path does. Record `step_type`
(`agent`/`iterative`/`collect`). Then surface the rows: add a per-run detail view or a
`steps` column to `web/live/workflows_live.ex` (today list-only) loading the existing
`WorkflowRun has_many :steps`.

**Step identity + dedicated projection actions (explicit design, not reuse):**
- Declare an **Ash `identity` on `(workflow_run_id, name)`** — this generates the unique
  index *and* is the idiomatic `upsert_identity` target; nothing enforces step identity
  today. Note Ash **adds the multitenancy attribute to non-`all_tenants?` identity upsert
  keys**, lining up with the tenant-prefixed unique index — correct here, but confirm with
  `mix ash_postgres.generate_migrations --check` plus one **runtime** upsert test (don't
  trust the snapshot alone).
- Add **dedicated upsert projection actions** — **all three** (`:record_started`,
  `:record_completed`, `:record_failed`) declare `upsert? true, upsert_identity
  :unique_step_per_run`, rather than reusing the user-facing `create/start/complete/fail`
  (`workflow_step.ex:33`). Because `:record_started` is best-effort (below), a
  completed/failed event may arrive with **no step row** — so `:record_completed`/
  `:record_failed` must be able to **create the row directly**, and a retried step
  re-entering `:record_started` must **clear stale `error`/`completed_at`** from the prior
  attempt, which `start` doesn't do.
- **UPSERT via the identity, never blind-insert** — once WS4 enables retries, a retried step
  emits multiple `step_started`/`step_failed` for the same logical step. Test WS3 against a
  retrying step, not just `max_retries: 0`.

**Failure semantics (explicit decision):** the step-row write is a **read-model, best-effort**
— it must **log and never roll back the event append** (mirroring the middleware's
best-effort step timeline, `reactor_middleware.ex:232`). Rescuing the Elixir exception is
**not sufficient**: any SQL error aborts the surrounding Postgres transaction (poisoned until
rollback), which would kill the event append anyway. So: (a) make the write
deterministic-safe by construction — identity-based upsert (no unique-violation class),
parent run FK guaranteed in-txn, pre-validated attrs; and (b) wrap it in an explicit
**savepoint** (`SAVEPOINT`/`ROLLBACK TO SAVEPOINT` via the repo) so a surprise SQL error
can't poison the append transaction. Failures log + remain repairable by replaying `step_*`
events. Only the status projection keeps rollback-on-error semantics (`allocate.ex:117`).

**Watch (this is the highest-coupling change in the plan):**
- **Hard-blocked on WS3-prep** — keying on the positional `:step_1` instead of the YAML name
  is wrong; land the enrichment first.
- It runs inside the most concurrency-sensitive transaction in the system; test under
  concurrent appends.

### WS4 — Per-step `retry:` / `compensate:` / `irreversible:` metadata

**Why:** §5 / T1-2 said skill steps express these in YAML and the compiler translates them to
Reactor step options. The compiler hardcodes `max_retries: 0` (`compiler.ex:277` + iterative
`:166-175`) and emits no undo/irreversible — so retry (the flaky-LLM-call use case) and the
saga story never reach skills.

**How:**
- **Allowlist first** — add `:retry`, `:compensate`, `:irreversible` to
  `StepNormalizer @canonical_keys` (`workflows/step_normalizer.ex:41-49`); unknown keys are
  **silently dropped**, so without this the values never reach the compiler.
- **`retry` → `max_retries` is NOT sufficient by itself.** Reactor retries **only** when
  `run/3` returns `:retry`/`{:retry, reason}` or `compensate/4` returns `:retry` — a plain
  `{:error, reason}` is terminal regardless of `max_retries` (verified:
  `reactor/lib/reactor/step.ex:54-58` run/compensate result types;
  `reactor/lib/reactor/executor/step_runner.ex:192-212,279-292` — only `:retry` returns hit
  the retry path). `AgentRunner.run/4` fails as `{:error, binary}`, so the compiler change
  alone is inert. Implement the retry **policy** in `AgentStep.compensate/4`: when the step's
  `retry:` option > 0, return `:retry` (Reactor caps attempts via `max_retries`
  automatically); otherwise `{:error, reason}`. Thread `retry:` → `max_retries` through
  `compiler.ex add_step/4` (replace the literal `0`) and the iterative path.
  **Value surface: non-negative integers only** — reject anything else at compile time with a
  clear compiler error (consistent with the existing cycle/missing-target rejections). Do NOT
  expose `:infinity` through YAML: it would arrive as the string `"infinity"` (coercion
  invites `String.to_atom` misuse), and unbounded retries on LLM/tool steps are a spend
  footgun regardless.
  Future: gate the `:retry` decision on a provider error classifier (only retryable reasons).
- **`compensate:` / `irreversible:`** — implement `compensate/4` + `undo/4` on
  `skills/steps/agent_step.ex`, reading the flags from the impl keyword added in
  `step_options/2` (`compiler.ex:255-262`). **Critical arity:** `use Reactor.Step` dispatches
  these as **`module.compensate(reason, arguments, context, options)`** and
  **`module.undo(value, arguments, context, options)`** — **options LAST, 4-arg**
  (`reactor/lib/reactor/step.ex:292-307`), *not* the `(step, …)` behaviour signature.
- **Capability is per-step via a `can?/2` override, not blanket module exports.** The
  generated default is `can?(_step, cap) = function_exported?(__MODULE__, cap, 4)`
  (`step.ex:361`) — so exporting `undo/4` would make **every** agent step report
  undo-capable, and a no-op `:ok` undo is operationally different from "no undo exists"
  (undo stack, `fully_reversible?`, Phase-4 replay gates). `can?/2` is **overridable**
  (`defoverridable can?: 2`, `step.ex:381`) and receives the step struct with
  `impl: {module, options}` — so override it on `AgentStep`, keyed on the step's options:
  `:compensate` ⇢ `retry > 0 or compensate: declared`; `:undo` ⇢ `compensate: declared and
  not irreversible: true`. A step with **neither flag reports no capability** (Reactor skips
  the callbacks entirely). `compensate:` references a cleanup task run best-effort via
  `AgentRunner` (then `:ok` = compensated); `irreversible: true` additionally rides into the
  step options + `step_*` event payloads as durable metadata for Phase-4 replay gates. Test
  the capability matrix, not just one positive case.

---

## Tier 3 — the gate Spark DSL (precedes AR-1)

### WS6 — Gate Spark DSL + all three kinds

**Why:** Phase 2 claimed a human-gate Spark DSL (T2-5); it shipped as a plain behaviour with
an **untyped** field map and a single hardcoded kind. Decision: build the real DSL + all three
kinds.

**How** (all APIs verified against spark 2.7.0):

- **`lib/jido_claw/orchestration/gate/field.ex`** — a `%Field{name, type, label, options,
  required?}` struct (`type ∈ text|select|textarea|number|boolean`).
- **`lib/jido_claw/orchestration/gate/dsl.ex`** — `use Spark.Dsl.Extension, sections: [@gate],
  verifiers: [...]`. A `%Spark.Dsl.Section{name: :gate}` with `schema:` (`kind`
  `{:one_of, [:tool_call, :plan, :irreversible_write]}` required, `title` required,
  `description`, `workflow`) and a nested `%Spark.Dsl.Section{name: :fields}` holding a
  `%Spark.Dsl.Entity{name: :field, target: Field, args: [:name], identifier: :name}` (the
  `identifier` gives Spark-enforced field-name uniqueness). Field-type enum is `{:one_of, …}`
  (`spark/lib/spark/options/options.ex:149`); `options` is `{:list, :string}`.
- **`lib/jido_claw/orchestration/human_gate.ex`** — the consumer base, `use Spark.Dsl,
  default_extensions: [extensions: [Gate.Dsl]]`, with `handle_before_compile/1` injecting
  `@behaviour JidoClaw.Orchestration.Gates` + best-effort arity-1 `after_approved/1` /
  `after_rejected/1` defaults + `defoverridable`. **The hooks stay plain behaviour callbacks**
  (they are code — `apply(mod, fun, [ctx])`, `cases.ex:198` — not declarative data). `kind/0`
  is dropped (derived from the DSL).
- **`lib/jido_claw/orchestration/gate/info.ex`** — `use Spark.InfoGenerator, extension:
  Gate.Dsl, sections: [:gate]` for `gate_kind!/1`, `gate_title!/1`, etc.; a `fields/1` helper
  via `Spark.Dsl.Extension.get_entities(mod, [:gate, :fields])`.
- **`lib/jido_claw/orchestration/gate/verifiers/validate_select_options.ex`** — a
  `Spark.Dsl.Verifier` asserting `type: :select` fields have non-empty `options:` (the one
  cross-field rule the schema can't express). **No transformer needed** — kinds are read on
  demand, not registered.
- **Three kind modules** (`lib/jido_claw/gates/{tool_call,plan,irreversible_write}_gate.ex`)
  each `use HumanGate` with a `gate do … end`. Only `irreversible_write` gets a live producer
  (a reactor wiring `GateStep` before its write); the others are declared-but-unproduced.
- **Slim the `Gates` behaviour to the two hooks** (`gates.ex:24-39`): **remove the
  `kind/0`, `field_metadata/0`, and `presentation/0` callbacks** — the DSL supersedes all
  three as data. Leaving `@callback kind()` in place while gate modules stop defining it
  means missing-callback warnings on every migrated gate, and `jidoclaw.compile_check`
  fails on warnings. Greenfield: the behaviour keeps only `after_approved/1` /
  `after_rejected/1`.
- **Wiring:** widen `AgentCase.kind` `one_of` to all three (`agent_case.ex:154-158`); in
  `gate_step.ex:41-42` **remove the `:kind` option entirely** and derive kind exclusively
  from `Gate.Info.gate_kind!(gate_module)` — a caller-supplied `:kind` could silently
  diverge from the DSL declaration. Seed `details` from `Gate.Info.gate_title!/1` +
  `fields/1`. Render typed fields in `web/live/approvals_live.ex` (today flat at
  `{gate.kind}`). Keep the DSL `kind` enum and `AgentCase.kind` `one_of` in lockstep
  (ideally derive both from one source).
- **Migrate** `test/support/jido_claw/gates/test_irreversible_write.ex` (the only existing
  consumer) to the new base.

---

## Tier 4 — case audit log + gate lifecycle + recovery

### WS5 — `AgentCaseEvent` immutable per-case event log

**Why:** T1-4's thesis ("for an agent that acts while you sleep, the audit timeline *is* the
product") shipped as a single `AgentCase` row with decision columns; the separate immutable
timeline was deferred (`agent_case.ex:15`).

**How:** New append-only resource `lib/jido_claw/orchestration/agent_case_event.ex` mirroring
`WorkflowEvent` (tenant-scoped via the WorkflowEvent pattern; `:read` + `:append` only;
per-case `seq` allocator under a `FOR UPDATE` lock; `case_id`, `type`, `data`, `occurred_at`;
a **DB-enforced unique `(agent_case_id, seq)` fence** mirroring `WorkflowEvent`'s). **Register
it in the `JidoClaw.Orchestration` domain** (`orchestration.ex:21`) — easy to forget, fails at
runtime not compile. Append at the existing single-transaction choke-points:
`WorkflowLog.gate_open/3` (opened), `Cases.commit_approve/5` / `commit_reject/5`
(approved/rejected), **and the cancel/abandon/retract paths** (each appends its case event in
the same transaction as the case-status flip). **Add `AgentCaseEvent` to each
`Ash.transact([AgentCase, WorkflowEvent], …)` resource list** (`cases.ex:124,142`;
`workflow_log.ex:104`) — otherwise the append runs on a separate connection and the atomicity
invariant breaks with no compile error.

### WS7 — AR-1 gate lifecycle: `abandon` + stale-approval retraction

**Why:** §4.5 said to "borrow AR-1 verbatim while designing the DSL **here**, not bolt on
later." Both live only in the exploration docs — zero code.

**Scope constraint (both features): no live-process cancellation this phase.** There is no
mechanism to stop an executing `Reactor.run` (that's the §4.11 lease/fencing *implementation*,
deliberately deferred) — so a transition from a state with a live reactor would mark the DB
terminal/paused while downstream effects keep executing. Both `abandon` and `retract` are
therefore **constrained to states with no live reactor by construction** (the reactor halted
at the gate and returned). Widening them to in-flight runs is explicitly future work, gated
on lease/cancellation semantics.

**How — `abandon` (operator-initiated run-terminal):** Allowed **only from
`:awaiting_approval`** (the parked-gate state — reactor halted, nothing executing). Add a
**distinct `run_abandoned` event kind** (operator deliberately giving up ≠ crash-reaped ≠
gate-reject). This is the "change five places together or it silently breaks" hazard — all of:
1. `WorkflowEvent.kind` `one_of` (`workflow_event.ex:100-118`),
2. `Projection @status_authority_kinds` (`projection.ex:32-40`),
3. `Projection.next_status/2` (**`:awaiting_approval` → `:abandoned` only** — not from any
   non-terminal; the catch-all returns `:illegal` and rolls back the append, which is the
   guard against abandoning a live run),
4. `Projection.status_attrs/3` (→ `:abandoned`, `completed_at`, `resume_checkpoint: nil`),
5. `WorkflowRun.status` `one_of` (+`:abandoned`) **and** `AgentCase.status` `one_of`
   (+`:abandoned`).
Add `Cases.abandon/…` (parallel to `decide/4`, which is guarded `when decision in
[:approve, :reject]`), dropping every pending case for the run (DB pending-fence per case).
Wire both operator surfaces: a button + handler in `web/live/approvals_live.ex` and a
`/gates abandon` branch in `cli/commands/approvals.ex`.

**How — stale-approval retraction (its own design spike):** a pre-implementation re-plan must
retract a recorded approval so the revised plan re-earns it. This is a **new legal transition**
the strict model has no representation for: today `approval_resolved` (approve) goes straight
to `:running` (`projection.ex:79`). Add an `approval_retracted` event + the transition
`:running --approval_retracted--> :awaiting_approval` (flip the `AgentCase` back to
`:pending`, **clearing `decision`, `decided_at`, `decision_comment`, and `decided_by_id`** so
the reopened case carries no stale decision data) and a `Cases.retract/…`. **Race-fence it to
the pre-resume window** (approval recorded, reactor not yet re-running): (a) the `AgentCase`
flip uses a DB-side `status == :approved` filter fence (same pattern as the pending fence),
and (b) the retract append verifies — under the same per-run `FOR UPDATE` event lock every
append takes — that **no `run_resumed` event exists after the `approval_resolved`**; if one
does, the reactor is live and retraction is refused (`{:error, :already_resumed}`).

**Make the window real, not just theoretical:** `Cases.dispatch(:approve, …)` commits and
**immediately** calls `GateResume.resume/2` (`cases.ex:100-109`), so today the pre-resume
window is microseconds and externally unusable. Add a **commit-only seam**: a `resume:`
option on `Cases.decide/4` (default `true`) so callers — tests now, the future plan-gate
producer's approve-then-batch-resume flow later — can commit a decision without resuming.
Build the mechanism + tests through that seam; the live trigger (re-plan detection) arrives
with the `plan`-gate producer (future), like the `tool_call`/`plan` kinds themselves.

### WS8 — Recovery fixes + missing tests

**Why:** Two §4.8 divergences in the recovery that shipped, plus untested dangerous edges.

**How:**
- **Dangling-gate → `:failed` + full audit** (decision #3). Replace
  `terminate_cancelling_cases(:run_cancelled, …)` (`workflow_recovery.ex:152-162`) with the
  `run_recovered` + `run_failed` pair (+ cancel the open case + an `AgentCaseEvent`) in **one
  transaction**. **Reuse the existing recovery vocabulary** (`append_recovery/2`,
  `workflow_log.ex:69-79`) — extend `terminate_cancelling_cases` to take the
  `[{:run_recovered,…},{:run_failed,…}]` list rather than spending a new kind. (`run_abandoned`
  from WS7 is *only* for operator abandon, not recovery.) `run_failed` legally folds
  `:awaiting_approval → :failed` directly and clears the checkpoint.
- **Re-key the decision-recorded branch** on the recorded `approval_resolved` event, not on
  `:running` + checkpoint presence alone (`workflow_recovery.ex:114`). It's functionally safe
  today (defers to `GateResume`'s approved-`AgentCase` lookup, the transactional sibling of
  `approval_resolved`), but the spec was emphatic — make it explicit, and add the missing test
  for the forbidden `:running` + checkpoint + **no** decision path (must fail-with-audit, never
  blind-resume past the gate).
- **Add the two other missing tests:** the non-gate-halt → `run_failed` (`:unexpected_halt`)
  branch in `reactor_runner.ex` (present in code, untested), and strengthen the parked-gate
  test to assert the **absence** of new `run_failed`/`approval_resolved` events (not just the
  positive invariants).

---

## Tier 5 — encryption + doc reconciliation (last)

### WS9 — Encrypt `resume_checkpoint` at rest

**Why:** Phase 2 "Decision 2 fast-follow" (`workflow_run.ex:166-167`): the checkpoint holds
**unredacted** reactor inputs/results as a plaintext `:binary` — the most threat-model-relevant
open item.

**How:** Reuse the established AshCloak + `JidoClaw.Security.Vault` precedent
(`security/secret_ref.ex:7,15-18`): `extensions: [AshCloak]` + `cloak do
vault(JidoClaw.Security.Vault); attributes([:resume_checkpoint]) end`. **Hand-roll
`use Ash.Resource` on `WorkflowRun`** (inline the 13-line policy block from `resource.ex:44-56`,
keeping the `by_id_global` bypass) rather than teaching `JidoClaw.Resource` to forward
`extensions:` — lower blast radius, follows the `WorkflowEvent`/`SecretRef` precedent. (Bundle
this WorkflowRun-declaration change with WS1's column additions — one decision about that file.)

**Watch — this is secretly bigger than "add an extension"** (AshCloak renames the column to
`encrypted_resume_checkpoint` and adds a *calculation* named `resume_checkpoint`; its
`rewrite_actions` strips the attr from `accept` lists and replaces it with an
argument + encrypt change — `ash_cloak/transformers/set_up_encryption.ex:33-100`):

- **Nil semantics (verified):** `AshCloak.do_encrypt` runs
  `value |> :erlang.term_to_binary() |> vault.encrypt!()` (`ash_cloak.ex:84-90`) — so
  encrypting `nil` stores **ciphertext-of-nil, not SQL `NULL`**. Every terminal
  checkpoint-clear (`projection.ex:110,119,123` via `set_status`) must **force
  `encrypted_resume_checkpoint: nil` directly** (bypassing the rewritten encrypt argument);
  otherwise "checkpoint present" checks read ciphertext as presence and recovery
  misclassifies every terminal run.
- **Writes:** `set_checkpoint` (`workflow_run.ex:68`) keeps its API — AshCloak's rewrite turns
  the accepted attribute into an argument routed through the encrypt change. Verify
  `set_status`'s nil-clear path is split out per the bullet above.
- **Presence checks read the encrypted column, no decrypt.** Update **all three consumers**
  that test checkpoint presence: recovery `classify/1` (`workflow_recovery.ex:107-120` —
  pattern-matches in function heads; the calculation is `%Ash.NotLoaded{}` unless loaded, so
  it would silently misclassify every run), `Cases.guard_resumable/1` (`cases.ex:97`), and
  `GateResume.resume/2` (`gate_resume.ex:90`). Match on `encrypted_resume_checkpoint`
  presence; **only `GateResume`'s decode path loads/decrypts** the calculation.
- `handle_gate_pause` (`reactor_runner.ex:303-310`) also touches the column.

### WS11 — Reconcile the exploration docs

**Why:** Some deferrals had honest moduledoc notes; others (claim fields, AR-1, Trace) had
none. Keep the tracking honest.

**How:** Update `docs/exploration/squidie/REACTOR-ADOPTION.md` + `T1-1-WORKFLOW-EVENT-LOG-PLAN.md`
to mark Phases 0–3 items as done, note the accepted limitations recorded above (iterative =
one step row; async Writer still deferred; T2-2 actor-visibility = Phase 5), and leave Phases
4–5 clearly flagged as the next-phase scope.

---

## Verification

Per workstream, add/extend tests under `test/jido_claw/orchestration/` and
`test/jido_claw/skills/` mirroring the existing suites. Key end-to-end checks:

- **WS1:** assert the three columns + two indexes exist (Ash resource introspection / a
  migration test); no behavior to exercise yet.
- **WS2/WS3:** run a real compiled skill through `ReactorRunner`; assert one `WorkflowStep`
  row per step with correct `status`/`sequence`/`output`/`tenant_id`, a tenant can't read
  another tenant's steps, and a **retrying** step upserts (no duplicate rows). Confirm the
  dashboard step view renders (LiveView test or the browser via the running app).
- **WS4:** a skill step with `retry: 2` actually re-executes on failure end-to-end (assert
  `step_retried` events + a later success — this proves the `compensate/4 → :retry` policy,
  not just the `max_retries` plumbing); a step with `retry: 0`/absent fails terminally on
  first error (no retry); `retry: "infinity"`/negative/non-integer is rejected at compile
  time. **Capability matrix via `can?/2`:** `retry: 2` → `:compensate` true; no flags →
  both `:compensate` and `:undo` false (no capability, not a no-op); `compensate:` declared
  → `:undo` true; `compensate:` + `irreversible: true` → `:undo` false and the marker
  appears in `step_*` event payloads.
- **WS6:** a gate module compiles through the Spark DSL; `Gate.Info.gate_kind!/1` +
  `fields/1` return the declared data; the `ValidateSelectOptions` verifier rejects a
  `:select` field with no options at compile time; the approvals UI renders typed fields.
- **WS5/WS7:** approve/reject/abandon each append the right `AgentCaseEvent` + run event in
  one transaction; `abandon` from `:awaiting_approval` reaches `:abandoned` and drops pending
  cases, while `abandon` against a `:running` run is **refused** (illegal transition rolls
  back); retraction (exercised via the `resume: false` commit-only seam) moves
  `:running → :awaiting_approval`, re-opens the case **with `decision`/`decided_at`/
  `decision_comment`/`decided_by_id` cleared**, and is **refused with `:already_resumed`**
  when a `run_resumed` event postdates the `approval_resolved`.
- **WS8:** the three new tests (forbidden no-decision path, non-gate-halt → `run_failed`,
  parked-gate negative assertions) pass; a stranded dangling-gate run reconciles to
  **`:failed`** with `run_recovered` + `run_failed` + a cancelled case.
- **WS9:** the checkpoint column is ciphertext at rest (inspect via Tidewave
  `execute_sql_query`); a gate halt → **app restart** → operator approval still resumes
  correctly (proves recovery's `classify/1` survives the column rename — the critical
  regression risk).
- **WS10:** a workflow run produces `[:jido_claw, :workflow, :event]` Trace events visible via
  `JidoClaw.Trace.spans/2` / the inspection surface.

**Gate (must all pass before the phase is "done"):**
`mix jidoclaw.compile_check` · `mix format --check-formatted` · `mix credo` · `mix test` ·
`mix ash_postgres.generate_migrations --check` (this plan changes many Ash resources +
generated snapshots — assert no codegen drift).
(Per AGENTS.md the compile gate is `jidoclaw.compile_check`, not `--warnings-as-errors`.)
Verify suspect singleton/async tests in isolation, not under `--seed 0` (known flaky set).
