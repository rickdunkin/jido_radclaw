# AR-2 Composer — Phase 4: Human gates in the composer

*Implements `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` §9 + §14 Phase 4. Builds on the shipped Phases 0–3.*

## Context

Phases 0–3 shipped a working, durable, signal-driven composer: the pure router
(`Router.compose_route/4`), the supervised loop GenServer, the durable envelope
(parent `WorkflowRun` `workflow_type: "composer"` + an append-only `WorkflowEvent`
log + state-as-projection), crash recovery, and the triage front door
(`code`/`system` turns enter the loop). **But on the built-in catalog a run gets as
far as `planner`, then dead-ends:** the `plan-gate` stage (`unit: {:gate, "plan"}`,
`catalog.ex:71-79`) cannot be built — `WaveBuilder.validate_units/1`
(`wave_builder.ex:45-50`) hard-rejects every non-`{:worker_template,_}` unit, and the
loop test pins this exact gap (`composer_loop_test.exs:131-160` asserts
`{:unsupported_unit, "plan-gate", {:gate, "plan"}}`). The implementer's lock
(`%{while: "plan-ready", until: "plan-approved"}`, `catalog.ex:99-102`) waits forever
on a `plan-approved` signal no stage produces.

Phase 4 makes the plan gate **run**: a gate stage executes as a human-approval
checkpoint that holds the implementer, parks the composer durably, resumes on the
operator's decision, and — on reject/abandon — takes the route terminal instead of
stranding. It also lands the **rerun/invalidation primitive** so an approval can be
re-earned after a re-plan. The entire AR-1 gate machinery (`GateStep`, `GateResume`,
`Cases`, `Gate.Kinds`) and the durable composer vocabulary (every event kind incl.
`wave_paused`/`wave_resumed`/`route_rejected`/`route_abandoned`/`stages_invalidated`
is **already defined and folded in both projections** — Phase 4 adds the **producers**,
not schema) already exist; Phase 4 wires them together.

**Scope boundary (confirmed):** `Reactors.SafetyGate`, the system-specific stages, and
the system reverse-verify loop belong to **AR-8c** (`AR-8c-SYSTEM-PATH.md`, a separate
doc with its own phases that "depends on Phase 4 landing first"). Phase 4 builds the
**`plan` gate only**. The cluster lease (§10.1) stays Phase 6.

### Decisions locked for this plan

- **Rerun primitive is IN Phase 4** (sub-phase 4e). The done-when item "resume
  re-earns approval on re-plan" requires re-firing the planner+plan-gate, which needs
  the `stages_invalidated` rerun primitive (shared with AR-4 self-heal / AR-8c). We
  build the primitive + the re-plan use here.
- **Approval UX: summary now, full plan later.** `Reactors.PlanGate` puts a short,
  redaction-safe summary in the gate `details`; Phase 4 is driven/verified via tests +
  `Cases.decide/4`. Rendering the full (encrypted) plan in `/approvals` + `/gates` is
  the observe/MCP phase (Phase 5). Preserves P1 (no plaintext plan at rest outside the
  encrypted artifact store).
- **Park via `{:noreply}`, NOT a Task rearchitecture.** A gate wave's
  `ReactorRunner.run/3` returns **promptly** at the `GateStep` halt (one DB write, no
  LLM) as `{:ok, {:paused, case_id}, run}`; the composer parks by returning
  `{:noreply, parked_state}` from `handle_continue` and is then an idle, live GenServer
  that wakes on `handle_info`. Nothing executes during the park, so "stays live across
  a gate park" needs no off-process execution. **The moduledoc note at
  `route_composer.ex:90-93` is corrected, not implemented.**
- **A gate runs as its own single-stage wave** (a *module* reactor, not a struct), and
  the loop **peels** a gate out of any mixed Kahn cohort (the router does not guarantee
  a gate is alone in its level — the shipped catalog co-locates `plan-gate` +
  `test-author` + `implementer`).

## Why a gate cannot be a dynamic struct (the constraint that shapes 4a)

`ReactorRunner`'s checkpoint encoder does `Keyword.fetch!(opts, :reactor_module)`
(`reactor_runner.ex:698`); a struct reactor has `reactor_module == nil`
(`reactor_runner.ex:244`), so a gated struct fails to checkpoint, and `GateResume` only
re-materializes modules under `@allowed_module_prefix
"Elixir.JidoClaw.Orchestration.Reactors."` (`gate_resume.ex:84`). So a gate wave **must**
dispatch a named module reactor under `Reactors.*`. `ReactorRunner.run/3` already accepts
a module and sets `reactor_module` from it — no runner change needed.

---

## Sub-phase 4a — Gate-producer reactor + WaveBuilder gate support

Make `{:gate, "plan"}` buildable and runnable to its halt. **Independently testable**
(no loop changes): drive `Reactors.PlanGate` straight through `ReactorRunner.run/3`
(initial pause) + `Cases.decide/4`/`GateResume.resume/2` (completion), asserting the
child `result` shape and the `ComposerArtifact` row.

**New: `JidoClaw.Orchestration.Reactors.PlanGate`** (`lib/jido_claw/orchestration/reactors/plan_gate.ex`).
Model on `test/support/jido_claw/reactors/gated_test_reactor.ex` (the keystone template)
and the shipped `reactors/project_registration.ex`. `use Ash.Reactor`,
`middleware(JidoClaw.Orchestration.ReactorMiddleware)`, **named `Reactor.Step` modules
only** (checkpoint serializability, Decision 1). Structure:
- `input(:plan_ref)` (the `plan` artifact's opaque store ref — **not** the value, see
  "Plan plumbing" below), `input(:wave_index)`, `input(:stage_name)`, `input(:artifact_name)`,
  `input(:signal_name)`. `tenant`/`actor`/`workflow_run`/`approval` arrive via **context**
  (`ReactorRunner` seeds the first three; `GateResume` re-seeds them + `approval: :approve`,
  `gate_resume.ex:151-158`).
- `step :approval_gate, {JidoClaw.Orchestration.GateStep, gate_module: JidoClaw.Gates.PlanGate,
  step_name: "plan-gate", details: %{summary: "Approve the implementation plan before execution"}}`
  — the gate kind comes from `Gates.PlanGate`'s DSL `kind(:plan)` (`plan_gate.ex:16`), not an
  option. `details` is a short summary only — **never the plan text** (it lands in the
  `AgentCase` jsonb; P1). (Drop the `:prepare` pre-step from the template — the plan is
  already an input, so no pre-gate data step is load-bearing; `GateStep` itself writes
  nothing reject-orphaning.)
- `step :emit, EmitApprovedPlan do ... wait_for(:approval_gate) end` → `return(:emit)`.

**New step `JidoClaw.Orchestration.Reactors.PlanGate.EmitApprovedPlan`** (sibling module in
the same file). Reads `context[:approval]` (the bare atom `:approve` — Reactor has no
`argument … context:` form, so read it in `run/3`; `wait_for` guarantees it's present
post-resume). Logic reuses the **exact** `WaveCollect` artifact-persist path
(`steps/wave_collect.ex:94-116`):
- **Resolve the RAW plan value** from `plan_ref` via `ComposerArtifact.resolve_value/2`
  (`composer_artifact.ex:334-335`, returns `{:ok, term()}` — the decrypted artifact, the same
  resolver `ArtifactContext` calls at `artifact_context.ex:131`). **Do NOT use
  `ArtifactContext.build/4`** — it caps each value to 4 KB / 16 KB total and renders markdown
  (`artifact_context.ex:47-48,112,139`), so storing its output as `approved-plan` would persist a
  lossy rendering, not the artifact.
- `ComposerArtifact.store_pending(%{ref: gen_ref(), name: artifact_name, producer: stage_name,
  term: <raw resolved plan value>, child_run_id: child.id, parent_run_id: child.parent_run_id,
  wave_index: wave_index}, ...)` — an encrypted `:pending` row, promoted to `:active` by the
  composer's `Commit.commit_wave/4` on fold (same division of labor as a worker wave; do NOT
  activate inside the reactor).
- Return the **same JSON-safe envelope `WaveCollect` returns** so `decode_emissions/1` needs
  **zero changes**: `%{"wave_index" => wave_index, "emissions" => [%{"stage" => stage_name,
  "signals" => [signal_name], "artifacts" => %{artifact_name => ref}}]}`. String keys throughout
  (json-safe for `WorkflowRun.result`, verified against `reactor_middleware.ex:502-515` +
  `decode_emissions/1` `route_composer.ex:1168-1172` + `StageEmission.from_map/1`).
- **Idempotent across crash-mid-resume (Decision 7):** before inserting, reuse-by-lineage —
  filter `ComposerArtifact.pending_for_wave(child.parent_run_id, wave_index)`
  (`composer_artifact.ex:189-200`) for `{child_run_id, name, producer}`; reuse the existing
  ref if present, else `store_pending`. Prevents a leaked pending row per resume crash.
- **Plan plumbing (ref, not value).** The composer passes the `plan` artifact's **ref**
  (`plan_ref`), resolved from `state.artifacts["plan"]` (`%{producer => {:ref, ref}}`); the emit
  step resolves the raw value in `run/3` (above). The gate stage declares `input: %{required:
  ["plan"]}` (`catalog.ex:76`); in the base catalog `plan` has the single producer `planner`, so
  one ref — multiple producers for a gate input is out of scope (deterministic pick or error).
  Passing the **ref** (not the value) also keeps the plan value out of the encrypted checkpoint
  (`{reactor, inputs}`): only the ref is checkpointed, the value resolved fresh on each run — the
  stronger P1 posture, and free here since the emit step resolves raw anyway.

**New: `JidoClaw.RouteComposer.GateReactors`** (`lib/jido_claw/route_composer/gate_reactors.ex`).
A fixed compile-time map `gate-name → {module, approval_signal}` —
`%{"plan" => {Reactors.PlanGate, "plan-approved"}}`. The closed seam that bounds atom
creation (never `String.to_atom` the catalog-sourced gate name; mirrors `GateResume`'s
allowlist). `resolve/1`, `signal/1`, `known?/1` (the last mirrors `Templates.exists?/1`).
The approval signal lives here, not `hd(publishes)` — `publishes` carries `scope-shift` too.

**Changed: `WaveBuilder.build_wave/2`** (`wave_builder.ex`). Replace the hard `{:gate,_}`
reject with a classify-branch: a **solo** gate stage → `{:ok, {:module_reactor, module, inputs}}`
(via `GateReactors.resolve/1`, inputs from the stage's `name`/`output`/the resolved signal);
a worker-only cohort → the unchanged struct path; a gate **mixed** with workers or >1 gate →
`{:error, {:gate_must_be_solo_wave, names}}`. Return type widens to add the `{:module_reactor,…}`
case.

**Changed: `Catalog`** (`catalog.ex`). (a) After the worker-template check `:170-173`, add the
parallel compile-time guard: every `{:gate, name}` must `GateReactors.known?(name)`, else raise.
(b) **Extend the `plan-gate` stage's `publishes`** from `["plan-approved", "scope-shift"]` to
`["plan-approved", "plan-rejected", "plan-abandoned", "scope-shift"]`. `plan-rejected` /
`plan-abandoned` are **composer-synthesized** (the gate reactor emits only `plan-approved`; reject
cancels before the emit step — §9 step 5/6), but declaring them in the gate's publish contract is
what (i) keeps the catalog coherent once the planner opts into `subscribes: ["plan-rejected"]`
(4e) — `CatalogValidator` rejects a subscription with no declared publisher (`catalog_validator.ex:239`)
— and (ii) lets the composer fold a synthesized `plan-rejected`/`plan-abandoned` as-if-from
`plan-gate` past the emission ⊆ `publishes` coherence check. Publishes need no subscriber, so adding
them in 4a is coherent even before 4e adds the planner subscription. `CatalogValidator` otherwise
needs no change (it accepts `:gate` units and exempts them from the `task` requirement). Flip the
boundary test (`composer_loop_test.exs:131-160`) from "asserts failure" toward the gate now building.

*Done when:* a `Reactors.PlanGate` run pauses at the gate, an approve→resume yields the
`{"emissions"=>…}` envelope + an `:active`-promotable `ComposerArtifact`, the catalog
compiles with the gate-existence guard, precommit green.

---

## Sub-phase 4b — Loop park / wake / approve (the happy path)

The composer parks on a gate, wakes on the operator's decision, folds `plan-approved`, and
releases the held implementer. **All in `route_composer.ex`** unless noted.

- **Peel the gate cohort.** Add `Loop.split_solo_gate/2` (`loop.ex`, pure) used just above
  `run_wave` in `handle_continue(:tick)` (`:886-890`): if the dispatch cohort mixes a gate with
  workers, dispatch the gate alone this turn; the independent workers re-compose next tick (no
  intra-level edges, `wave_builder.ex:8-10`). Preserves linear progress; keeps the shipped
  catalog runnable.
- **Module-reactor dispatch.** Teach `run_wave`/`run_built_wave` (`:991-1037`) the
  `{:module_reactor, module, gate_inputs}` shape: run `record_wave_start` (so
  `route_composed`+`wave_started` land pre-launch under the FOR-UPDATE fence), resolve the
  `plan_ref` from `state.artifacts["plan"]` and merge it into `gate_inputs` (`WaveBuilder` builds
  the rest — `wave_index`/`stage_name`/`artifact_name`/`signal_name` — but has no store access, so
  the loop supplies `plan_ref`), then run `module` through a `run_reactor/3` variant (identical
  opts — `parent_run_id`, the `composer:<parent>:<wave_index>` key, `sanitize_sensitive_context`,
  `execution_timeout`, `omit_replay_inputs`). A gate wave needs **no** `:extra_context` (it stores
  the raw plan from the ref, §4a; it feeds no worker), so the formatting/cap path is skipped.
- **Park clause** — a new `handle_wave_result({:ok, {:paused, case_id}, run}, …)` head,
  ordered **before** the generic `{:ok, value, run}` head (`:1086`): subscribe-once to the gates
  topic (`RunPubSub.subscribe_gates()`, on first park), append **`wave_paused`** (payload
  `%{wave_index, agent_case_id, child_run_id}` — the convenience source 4d's `derive_park` prefers,
  though it can recover without it) via `Commit.start_wave/3` under its parent-terminal fence, store
  `parked: %{wave_index, case_id, child_run_id, dispatch, display}` in state, and return `{:noreply,
  parked}`. **Do NOT** bump `wave_index`, `record_wave`, or re-append the start markers — the wave
  isn't done.
  - **`wave_paused`-append failure: retry the marker, keep the parent `:running` — do NOT tear
    down a validly-parked gate, do NOT `finish_failed`.** Unlike `record_wave_start` (which runs
    *before* the child exists), at the park point the child has **legitimately parked** (an
    `AgentCase` is open + the child is `:awaiting_approval`) — an operator could decide it right now.
    The append failure means only that the *durable marker* didn't land, not that the gate is
    invalid; so terminalizing the parent (orphaning the case) or tearing the gate down (discarding a
    valid pending approval) are both wrong. Explicit branches:
    - *Transient append error* → **retry the `wave_paused` append with bounded backoff**, mirroring
      `retry_rebuild_or_stop` (`route_composer.ex:944-961`): `Process.send_after(self(),
      {:retry_wave_paused, ctx}, backoff)` + `{:noreply, state}` (a new `handle_info`, sibling to
      `:rebuild_retry`). On a later success → park normally.
    - *Retries exhausted* → **park in-memory anyway**: set `parked`, subscribe to gates, `{:noreply,
      parked}`, and **log loudly** that the durable marker is missing. The live composer still wakes
      on the decision; the parent stays `:running` (recoverable); the open case is a valid pending
      approval, **never orphaned**. Crash recovery derives the park **without** `wave_paused` (4d's
      `derive_park` falls back to `wave_started(N)` + an `:awaiting_approval` child + no
      `wave_completed(N)`), so the missing marker costs nothing on reboot.
    - *`:parent_terminal` (parent cancelled externally during the append)* → this is the **only**
      branch that tears the child gate down (the parent IS terminal, so the case would be a real
      orphan): `WorkflowLog.terminate_cancelling_cases(child, [{:run_failed, …}], reason)`
      (`workflow_log.ex:157`), then `{:stop, :normal}`. If *that* teardown also errors, stop
      `:normal` and leave it for recovery's terminal-parent child reconciliation (which cancels the
      dangling case) — never a busy-loop.
- **Wake** — a new `handle_info({:gate_resolved, run_id, info}, state)` (beside `:894`): ignore
  unless `run_id == parked.child_run_id`; **reload the child and branch on STATUS, never on
  `info.decision`** (the status is the truth):
  - `:completed` (approve resolved + resumed) → append **`wave_resumed`**, then fold via the
    existing `handle_wave_value(decode_emissions(child.result), …)` (`:1102`) — which appends
    `wave_completed` + content (`signals_published` carrying `plan-approved`, `artifacts_produced`
    carrying the `approved-plan` ref) and promotes the gate's `:pending` artifact via
    `commit_wave`'s `activate_for_wave` — then `{:continue, :tick}`. The next `compose_route`
    sees `plan-approved` live → the implementer's lock is inactive → it dispatches.
  - `:running`/`:pending`/`:awaiting_approval` (approve broadcast landed **before** `GateResume`
    finished — `cases.ex:281-284`) → bounded `observe_existing_child`/`poll_existing_child`
    (`:1337-1378`) to terminal, then re-branch. **This closes the broadcast-before-resume race:
    fold from `:completed`, never from the broadcast** (else the implementer releases against an
    unwritten `plan-approved`).
  - `:cancelled`/`:abandoned` → 4c.

*Done when:* a `code`-path run on a catalog with a plan gate holds the implementer wave, the
gate parks (`wave_paused` durable), `Cases.decide(:approve)` resumes it, `plan-approved` folds,
the implementer runs, and the route converges; precommit green. Correct the
`route_composer.ex:90-93` moduledoc note (park-via-`{:noreply}`, not Task).

---

## Sub-phase 4c — Reject / abandon → terminal (no strand)

The gate child carries **no emission** on reject (cancelled before the emit step) or abandon
(never resumed), so the composer synthesizes the terminal from the child's status — reusing
machinery that **already exists** (today only crash-synthesis reaches it). This sub-phase ships the
**committed default** (reject/abandon → terminal); 4e then layers the optional reject→re-plan
branch on top, so the *final* behavior is: abandon always terminalizes, and reject terminalizes
**unless the 4e reject opt-in applies** (a stage `subscribes: ["plan-rejected"]`).

- In the 4b wake handler, the `:cancelled` and `:abandoned` child branches call the existing
  `finish({:rejected, {:child_cancelled, child.id}})` / `finish({:abandoned, {:child_abandoned,
  child.id}})` (`:1075-1079`) → `route_rejected`/`route_abandoned` → parent `:cancelled` +
  `result.disposition` (already wired: `classify_terminal` `:1488-1489`, `parent_terminal_notify`
  `:1447-1457`, status projection lift `workflow_event/projection.ex:212-213`). The held route
  drops with the parent. **(4e interposes** on the `:cancelled` branch a check for the reject
  opt-in: if a stage subscribes to `plan-rejected`, take the re-plan branch instead of this
  terminal; `:abandoned` has no opt-in and always terminalizes.)
- **Extract `terminalize_gate_disposition/3`** called by BOTH the live wake path and the
  dedupe-hit `:cancelled`/`:abandoned` clause (`:1075-1079`) so the live and crash-recovery
  paths cannot drift.
- **Refactor `observe_existing_child`** (`:1342-1349`): its non-`:completed` arm currently fails
  every terminal generically — wrong for a gate child whose `:cancelled`/`:abandoned` is a
  legitimate operator decision. Parameterize so a *gate* child routes those to the disposition
  terminal, while a *worker* child keeps the conservative `finish_failed`.
- **Residual cancel window** (`route_composer.ex:1016-1022`, `commit.ex:31-39`): single-node, the
  single-live-owner-per-`parent_run_id` invariant (the `:unique` Registry) means the composer is
  the only terminalizer while alive, and it never launches a wave after `finish`. Add a
  parent-terminal re-check in the module-reactor/worker launch path as a belt-and-suspenders
  fence; full closure under *concurrent* terminalization rides the Phase 6 cluster lease (§10.1).

*Done when:* a `Cases.decide(:reject)` and a `Cases.abandon` each take the parent terminal
(`:cancelled` + `result.disposition` `:rejected`/`:abandoned`), dropping the held route, with the
parent never left `:running`; precommit green.

---

## Sub-phase 4d — Recovery: wake-after-gate

A composer killed while parked must restart and resume the gate — today `WorkflowRecovery`
leaves a parked-child parent `:running` for the *next* boot (`workflow_recovery.ex:333-334`),
the deferred "durable wake-after-gate-decision" gap.

- **`WorkflowRecovery.resume_composer/1`** (`:319-344`): split children into *parked-gate*
  (`:awaiting_approval` + pending case) vs *other-non-terminal*. Restart the supervised composer
  when the only non-terminal child is a parked gate (a still-running **worker** child still blocks
  restart — that's the executorless-corpse danger the old `all_children_terminal?/3` guard rightly
  feared). Restart is safe because the restarted composer **re-parks without re-dispatching** the
  gate wave.
- **Re-derive the park from the log — robustly, NOT requiring `wave_paused`.** In `do_rebuild/1`
  (`:896`), after `ComposerProjection.project/2`, add `derive_park/1`. The **authoritative** park
  source is a `wave_started(N)` whose child is `:awaiting_approval` and which has **no
  `wave_completed(N)`** (a seq scan mirroring `Cases.ensure_not_resumed/3`, `cases.ex:536-558`);
  `wave_paused(N)` (when present) supplies the `agent_case_id`/`child_run_id` shortcut, but its
  **absence does not hide the park** — this is what makes the rare "marker-append exhausted" park
  (above) recoverable. The `child_run_id`/`agent_case_id` are otherwise recovered by the
  `composer:<parent>:N` idempotency key + `AgentCase.pending_for_run`. Then `re_enter_park/2`
  reloads the child and branches on status — reusing the **same** wake/fold/disposition code
  (4b/4c): `:awaiting_approval` → re-subscribe + re-park (subscribe **then** re-read, to close the
  decision-landed-during-subscribe window); `:completed`/`:cancelled`/`:abandoned` (decided while
  down) → fold/terminalize.

*Done when:* a run killed while parked on a plan gate, then decided (approve OR reject) while
down, resumes correctly on `WorkflowRecovery.reconcile_all()` (folds + releases, or terminalizes);
a still-parked gate re-parks; precommit green. Model the test on `craft_parked_child/2`
(`composer_durable_test.exs:850-876`).

---

## Sub-phase 4e — The rerun/invalidation primitive + re-plan ("re-earns approval")

The primitive that lets a stage be dropped from `ran` and re-fire — Alp River's "drop the stage
from `already_run`" (`WORKFLOW.md ## Convergence`). General (AR-4 self-heal + AR-8c reverse-verify
reuse it); Phase 4's **use** is the re-plan. All event kinds already fold in both projections;
this adds the **producers** + the bounds.

- **`stages_invalidated` producer** — `invalidate_stages/2` removes a RE_RUN_SET from `ran` and
  appends a durable subtractive `stages_invalidated` event (folds as a `ran` difference,
  `route_composer/projection.ex:103-105`), via `Commit.start_wave/3`'s fenced-append shape, so the
  fold replays the **net** `ran`.
- **`wave_index` must advance on re-fire — `stages_invalidated` alone does NOT.** Only
  `wave_completed` advances `wave_index` in the projection (`route_composer/projection.ex:75`), and
  the launch key is `composer:<parent>:<wave_index>` (`route_composer.ex:1150`). So re-firing a
  stage at an un-advanced `wave_index` would **dedupe to the prior child** at that index. This is
  benign for a stage whose prior wave *completed* (its `wave_completed` already advanced the index),
  but **fatal for the parked-then-rejected gate**: its wave (index N) never wrote `wave_completed`,
  so `wave_index` is still N, and a re-dispatched planner at N dedupes to the **cancelled gate
  child** → terminates instead of re-planning (the High finding). **Fix — a CONDITIONAL advance,
  not an unconditional one:** the `stages_invalidated` payload carries an **optional**
  `closed_wave_index` (the parked-but-never-completed wave being closed); the projection (+ the
  in-memory loop) advances `wave_index = max(current, closed_wave_index + 1)` **only when that field
  is present**. The reject-parked-gate path sets it (`closed_wave_index: N`); a **generic rerun
  after a completed wave omits it** (its `wave_completed` already advanced the index), so normal
  AR-4/AR-8c reruns do **not** skip launch keys or burn the `max_waves` budget. *(Alternative the
  reviewer suggested: an empty-stages `wave_completed(N)` "gate-wave-closed" marker via `commit_wave`,
  reusing the existing advance rule; rejected as the primary because a `wave_completed` for a
  non-folded rejected wave is semantically muddy and reads as "folded" in recovery.)* No new event
  kind either way.
- **`artifacts_invalidated` producer** — tombstone a `{name, producer}` store entry (folds at
  `projection.ex:98-101`) when an artifact is retracted without an immediate rerun, so its
  consumers re-drop as unsatisfiable. Carries `{name, producer}` (provenance-keyed — a co-produced
  `name` leaves `available` only when its **last** producer is tombstoned).
- **`signals_retracted` for `plan-approved`** — today the only producer is `Fold`'s paired-verdict
  flip (`fold.ex:60-74`); add an explicit retraction so a stale `plan-approved` leaves `live`
  durably and recovery's fold never resurrects it.
- **Re-plan trigger — catalog-driven, reusing `subscribes` (no new `Stage` field):**
  - *Reject opt-in (§15.8):* on a gate **reject**, if any stage `subscribes` to `plan-rejected`
    (and isn't rerun-capped), in one transaction fold `plan-rejected` + emit `stages_invalidated`
    removing the RE_RUN_SET (just the planner — the gate was never in `ran`) **with
    `closed_wave_index: N`** (N = the rejected gate's wave index, advancing `wave_index` past it —
    without this the re-dispatch dedupes to the cancelled gate child), then `{:continue, :tick}` →
    planner re-fires (`plan-needed` still live) at the fresh `wave_index` → plan-gate re-fires +
    re-parks → re-approve. Otherwise the 4c committed default (terminate) holds. The planner gains
    `subscribes: ["plan-needed", "plan-rejected"]` in the built-in catalog to opt in (its publisher
    is the `plan-gate` stage's extended `publishes`, 4a — keeps the catalog
    `CatalogValidator`-coherent).
  - *Stale-approval retraction (§4):* on folding a premise-break (`scope-shift`) while
    `plan-approved` is live and the implementer has not run, retract `plan-approved`
    (`signals_retracted`) + invalidate {planner, plan-gate} (`stages_invalidated`), and — only in
    the narrow pre-resume window — `Cases.retract/3` (`cases.ex:216-236`, refuses
    `:already_resumed`); then re-tick → re-plan → re-gate → re-approve.
  - The RE_RUN_SET (what `stages_invalidated` *removes from `ran`*) is the **in-`ran` subset** of
    {the gate's `input` producer(s), the gate}: for a **reject** the gate parked but never completed,
    so it's **not** in `ran` → RE_RUN_SET = just the planner (the gate re-fires on the re-emitted
    `plan-ready` once `closed_wave_index` has advanced past its rejected wave); for a
    **stale-approval** the gate *did* complete → RE_RUN_SET = {planner, plan-gate}. A stage that was
    never in `ran` re-fires without invalidation and **must not count against its rerun cap**
    (it never completed); `plan-gate` may still appear in the event for traceability but is not a
    `ran` removal on the reject path.
- **Bounds (reuse the existing budget terminal).** Extend `over_budget?`/`budget_reason`
  (`route_composer.ex:888`) with a **per-stage rerun cap** (run config, default 2) and an
  **oscillation guard** (a re-fire whose re-produced artifact hash is unchanged is surfaced, not
  retried). Hitting either takes the parent terminal as `route_budget_exhausted` → `:failed`
  (already wired) carrying the bound it hit.
- Update the Phase-1 scope-fork moduledoc note (`route_composer.ex:105-110`): the rerun
  *primitive* now exists; the AR-4 *fixer* workflow (review→fix→re-review) that uses it for
  findings remains a separate workflow (§12) — Phase 4's use is re-plan only, so
  `Loop.terminal`'s `:not_converged`-on-open-findings is unchanged.

*Done when:* a rejected plan with the opt-in re-plans and re-earns approval (converges); a
post-approval `scope-shift` retracts `plan-approved` and forces re-gating; the rerun cap /
oscillation guard terminate a non-progressing loop as `route_budget_exhausted`; a retracted
`plan-approved` and an invalidated stage both stay gone across a crash rebuild (subtractive deltas
folded, not resurrected); precommit green.

---

## New / changed files

| File | Change |
| --- | --- |
| `lib/jido_claw/orchestration/reactors/plan_gate.ex` | **NEW** — `Reactors.PlanGate` + `EmitApprovedPlan` step (4a) |
| `lib/jido_claw/route_composer/gate_reactors.ex` | **NEW** — fixed `{:gate,name}→{module,signal}` resolver (4a) |
| `lib/jido_claw/route_composer/wave_builder.ex` | gate-wave branch `{:module_reactor,…}`; drop the `{:gate,_}` hard reject (4a) |
| `lib/jido_claw/route_composer/catalog.ex` | gate-name existence compile guard; `plan-gate` `publishes` += `plan-rejected`/`plan-abandoned` (4a); planner `subscribes` += `plan-rejected` opt-in (4e) |
| `lib/jido_claw/route_composer/loop.ex` | `split_solo_gate/2` peel (4b) |
| `lib/jido_claw/route_composer/route_composer.ex` | park clause, wake `handle_info`, module-reactor dispatch, `terminalize_gate_disposition`, `observe_existing_child` refactor, `derive_park`/`re_enter_park`, rerun producers, rerun-cap/oscillation bounds, moduledoc fixes (4b–4e) |
| `lib/jido_claw/orchestration/workflow_recovery.ex` | parked-gate-child restart (4d) |
| `lib/jido_claw/route_composer/commit.ex` | reuse `start_wave/3`/`commit_wave/4` for `wave_paused`/`wave_resumed`/`stages_invalidated`/`signals_retracted` appends (extend, don't fork) |
| `lib/jido_claw/route_composer/projection.ex` | `stages_invalidated` handler advances `wave_index = max(current, closed_wave_index+1)` **only when the optional `closed_wave_index` is present** (4e — the conditional re-fire fresh-key fix) |
| **Reused unchanged** | `fold.ex`, `stage_emission.ex`, `steps/wave_collect.ex`, `artifact_context.ex`, `orchestration/composer_artifact.ex`, `cases.ex`, `gate_step.ex`, `gate_resume.ex`, `reactor_runner.ex`, `orchestration/workflow_event{,/projection}.ex` |
| Tests | `test/jido_claw/route_composer/composer_loop_test.exs` (flip boundary, add gate-converge), `composer_durable_test.exs` (park/resume/reject/abandon/recovery/re-plan), `test/support/.../composer_stubs.ex` + `fixtures.ex` (gate-bearing fixture catalog) |

## Verification (end-to-end)

Run via `mise exec -- mix` (toolchain memory). Tests are hermetic — a gate stage is a real
`Reactors.PlanGate` (deterministic `GateStep` + emit step, **no LLM**), so it needs no stub; the
gate is driven by calling `Cases.decide/4`/`Cases.abandon/3` directly. Worker stages around it use
the existing `:route_composer_stub_outputs` + `StubWorker`/`StubAgentServer` harness
(`composer_stubs.ex`, `fixtures.ex`).

1. **4a unit:** drive `Reactors.PlanGate` through `ReactorRunner.run/3` → assert `{:ok, {:paused,
   case_id}, run}` with `run.status == :awaiting_approval`; then **`Cases.decide(case_id,
   :approve)` alone** drives the child to `:completed` (it calls `GateResume.resume/2` internally by
   default, `cases.ex:275-289` — do **not** also call `GateResume.resume` or the child
   double-resumes; pass `resume: false` only if a test wants to drive the resume by hand). Assert
   `child.result` is the `{"emissions"=>[…"plan-approved"…]}` envelope and the `approved-plan`
   `ComposerArtifact` row holds the **raw** plan value (not a 4 KB-capped rendering) and is
   `:active`-promotable.
2. **4b/4c integration:** start a composer on a gate-bearing fixture catalog (planner + plan-gate +
   implementer, implementer locked `until: plan-approved`); assert the implementer is **held** and
   the parent appends `wave_paused`; then `Cases.decide(:approve)` → assert `wave_resumed` +
   `wave_completed`, the implementer runs, `route_converged` → `:completed`. Separately assert
   `:reject` and `abandon` each yield `:cancelled` + the right `result.disposition`.
3. **4d recovery:** craft a parked composer (parent `:running`, a `wave_paused` event, a parked
   child via `craft_parked_child/2`), with **no live GenServer**; decide the gate; run
   `WorkflowRecovery.reconcile_all()` → assert the composer restarts and folds/terminalizes
   correctly; and a *still-parked* gate re-parks (parent stays `:running`). **Plus the
   `wave_paused`-missing case:** craft the same parked state **without** a `wave_paused` event
   (only `wave_started(N)` + the `:awaiting_approval` child) → assert `derive_park` still finds the
   park and recovery resumes correctly (proves the marker is non-load-bearing).
4. **Park-marker failure cleanup (4b):** stub `Commit.start_wave/3` to fail the `wave_paused` append
   once → assert the live composer **retries** and parks (no orphaned approval, parent stays
   `:running`); on forced retry-exhaustion assert it parks in-memory + logs + stays `:running`
   (case still pending, not cancelled). For the `:parent_terminal` branch, set the parent terminal
   then drive a park → assert the child gate's pending case is cancelled (`terminate_cancelling_cases`)
   and `{:stop, :normal}`.
5. **4e re-plan:** reject with the opt-in → assert `stages_invalidated` removes **just the planner**
   (carrying `closed_wave_index`), `wave_index` advances past the rejected gate, the planner
   re-fires and the plan-gate re-parks (a **second** `wave_paused`), re-approve → converge; assert a
   completed-wave rerun's `stages_invalidated` omits `closed_wave_index` (no key skip); assert the
   per-stage rerun cap terminates a forced loop as `route_budget_exhausted`; assert a retracted
   `plan-approved` stays gone across a rebuild (`ComposerProjection.project(seed, log)` == in-memory
   net state).
6. **`mise exec -- mix precommit`** green after 4e (run it bare in the background and read the tail
   — never pipe through `tail`, which masks the exit code).

## Risks / watch-outs

- **Precommit gates** (`mix.exs:251-260`): `jidoclaw.compile_check` (zero non-allowlisted warnings;
  allowlist is empty), `format`, `reach.check --arch --smells --strict`, `credo --strict`,
  `dialyzer`, `test`. New map literals can trip reach's `fixed_shape_map` smell — prefer the
  `%StageEmission{}` struct / the `.reach.exs` ignore precedents; the parked-state map and event
  payloads are candidates. New helpers need `@spec` (credo Specs) and Dialyzer totality.
- **The WorkflowsLive render-assigns triad** is unrelated here, but any new composer state surfaced
  to the dashboard would need it — Phase 4 adds none (observe is Phase 5).
- **Flaky async-singleton tests** (MCPServer/Prompt/PipelineStore/MultiSandbox): if one flakes,
  re-verify in isolation, not at `--seed 0`.
- **Idempotency of the emit step** (4a) and the **subscribe-then-read** ordering on wake/recovery
  (4b/4d) are the two correctness hot spots — the broadcast-before-resume race (`cases.ex:281-284`)
  is closed by folding from the child's `:completed` status, never the broadcast.
- **P1:** the gate reactor checkpoints only the plan **ref** (not the value — §4a), so the plan
  value never enters the encrypted checkpoint; it is resolved fresh from `ComposerArtifact` on each
  run. Keep the full plan out of the gate `details` too (operator UX is a summary until Phase 5) —
  `details` lands verbatim in the `AgentCase` jsonb.
