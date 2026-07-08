# Item 9 — Structured premises: acceptance criteria + lint (ouroboros OB1-2)

## Context

Next-ten queue item 9 (`docs/plans/unadopted-next-ten/README.md:882-926`) — the
queue's keystone entry. Today the AR-9 premises pipe carries launch
*assumptions* (`path`, `est_size`, clarify keys), not criteria; certificate
`specification` is transient LLM-relayed free text; skill
`verification_criteria` is a hardcoded YAML list that is **completely inert**
(`inject_produces_instruction/2` ignores produces content). Item 8 (clarify
loop) shipped 2026-07-07 and is this item's producer-side prerequisite — done.

The change: typed optional premises keys (`acceptance_criteria`,
`evaluation_principles`, `exit_conditions`) written by the clarify loop and
triage, a pure deterministic `Premises.Lint` ported from ouroboros GradeGate
(blockers loop back into clarify; findings ride the plan-gate payload), and
consumers on both ends (reviewer-lens tasks, `verify_certificate`, the skill
knob). Riders: orca OR2-5/OQ-2 (quality-gate vocabulary fold + reserved AC-id
linkage) and OpenHelm OH1-3 (cron outcome contract — **operator decided:
REQUIRED at creation** for agent-created jobs). Operator also decided: **wire
the inert skill `verification_criteria` knob**.

Source repos (all present):
- `~/workspace/research/ouroboros` — freshly cloned; read at pin via
  `git -C ~/workspace/research/ouroboros show e905a41c:src/ouroboros/auto/grading.py`
  (HEAD has moved to `98d3d66d`; never checkout — `git show` only).
  Attribution: `Q00/ouroboros @ e905a41c, MIT`. Extracted copy already at
  `<scratchpad>/ouroboros_grading.py`.
- `~/workspace/research/pms/orca` @ `2520b31` (MIT) — `validate_task_quality`
  in `apps/desktop/src-tauri/src/briefing.rs:552-617`, meaningfulness bank at
  `:546-550`.
- `~/workspace/research/pms/OpenHelm` @ `2facabaa` (**BUSL-1.1** — adopt the
  *shape* only, three field names + validation rules; no code transcription;
  attribution as inspiration).

## Step 0 — PORT-OB1-2.md + SIGN-OFF (blocking; before any lint code)

House rule (`docs/exploration/README.md`): BORROW-PATTERN mechanism
translation requires a signed-off port map — **plan approval does NOT
constitute sign-off**. Write `docs/exploration/ouroboros/PORT-OB1-2.md`
(anatomy per PORT-OB1-1 precedent: header with both SHAs, what-the-source-does,
side-by-side shapes, behaviors table preserved/changed/dropped, edge cases
anchored to ouroboros's own tests, sign-off gate), then **pause and get
explicit operator sign-off** before writing `Premises.Lint`.

The map must pin these mapping decisions (already designed, sign-off ratifies):

| GradeGate element | Port decision |
| --- | --- |
| VAGUE_TERMS (9 words, `grading.py:23-33`) | verbatim, word-boundary, case-insensitive |
| _OBSERVABLE_HINTS (22 substrings, `:34-57`) | verbatim pre-filter |
| 11 `observable_patterns` regexes (`:485-497`) | verbatim (Elixir `Regex`) |
| missing/vague/untestable AC findings (`:234-264`) | findings (→ plan-gate warnings); missing-AC fires **only when a clarify ledger existed**. **Policy pinned: ALL AC-quality checks (missing/vague/untestable/meaningless/empty-list) are findings-only — never blockers, never a clarify re-open.** Blockers are exclusively the ledger-derived safety set below |
| >9 ACs advisory (`:275-289`) | verbatim; excluded from grade |
| grade C/B/A (`:387-418`) | blockers→`:c`, findings→`:b`, else `:a` (scores are derived-from-counts, observational — **dropped**, documented) |
| `high_ambiguity_score` >0.20 blocker, suppressed when degraded (`:213-223`) | ported as a **clarify-mode-only blocker**; belt-and-braces (clarify pass gate already holds ≤0.2 — reconcile thresholds in map); gate mode demotes it to a finding |
| `ledger_open_gap` (BLOCKED stays blocker even degraded, `:291-340`) | ported on the clarify lane only (needs `:ledger` opt) |
| `high_risk_assumptions` terms credential/"api key"/production/payment/legal/medical (`:556-571`) | ported over ledger `assumed` items' text; blocker → clarify re-open |
| `missing_goal` / `seed_goal_mismatch` (`:194-205,:421-441`) | **dropped** (no ledger goal section; intent has its own precedence chain) |
| `missing_constraints`/`missing_non_goals` | **dropped** (no such premises keys/producers) |
| final-report pattern family (`:501-520`) | **dropped** (ouroboros-specific) |
| template auto-repairer (`seed_repairer.py`) | **skipped** per queue (our loop has a human) |
| orca `validate_task_quality` fold | meaningless-AC bank (`todo/tbd/na/none/acceptancecriteria` normalized) + ≥1-AC-when-key-present, both as **findings**; the repair-once-then-fail-loud FLOW maps structurally — the clarify loop's own rounds are the repair, the human plan gate is the fail-loud (no lint-triggered re-open for AC quality); relevant-files check **dropped** (no structured plan tasks exist — camus C3-5's `acceptance` field never landed; planner output is free text, `catalog.ex:102-132`) |
| AC identity (orca OQ-2 reserve) | 1-based index ids `AC1`, `AC2`, … — documented contract; premises compose once at launch so indexes are stable |
| one-shot surfaces | blockers **demote to findings** (never a new refusal lane — #8's never-park posture); plan gate remains the human backstop |

## Design (validated; corrections from review folded in)

**New modules** (beside `premises_context.ex`):
- `lib/jido_claw/route_composer/premises.ex` — typed-key vocabulary;
  `normalize/1` write-boundary (malformed producer value → drop key + Trace,
  fail-open, total); read accessors `criteria/1 → [binary] | []`,
  `principles/1`, `exit_conditions/1`, `criteria_with_ids/1 → [{"AC1", text}]`.
- `lib/jido_claw/route_composer/premises/lint.ex` — pure, with an **explicit
  mode API**: `run(premises, mode: :clarify, ledger: …)` may emit blockers
  (the ledger-dependent checks — high_risk_assumptions, ledger_open_gap,
  missing-AC — plus blocker-class premises checks like
  `high_ambiguity_score`); `run(premises, mode: :gate)` **can never return
  blockers** — blocker-class checks are demoted to findings in gate mode
  (premises still carry `"ambiguity_score"` from clarify, so without the mode
  split a gate-side re-lint could mint a blocker the wiring has no consumer
  for). An invalid/missing `:mode` **fails closed to gate behavior** — a
  future caller can never get clarify blockers by default. **Test pins:
  gate-mode (and unknown-mode) lint never returns blockers.** Returns
  `%{grade: :a|:b|:c, blockers: [...], findings: [...], advisories: [...]}`
  with **map entries** `%{code: binary, message: binary, target: binary}` —
  never tuples (the report must survive a JSONB boundary). A companion
  `Lint.to_details/1` emits the bounded, redactor-safe, **string-keyed,
  namespaced** persistence form:
  `%{"premises_lint" => %{"grade" => "b", "findings" => [%{"code" => …,
  "message" => …, "target" => …}], "advisories" => [...]}}` (counts capped,
  messages clipped), and `%{}` for a clean report.

**Producers**:
- Clarify scorer (`front_door/clarify/scorer.ex:173-206` Zoi + `:309-324`
  normalize): optional `acceptance_criteria` (array of strings),
  `evaluation_principles` (**array of JSON objects** —
  `Zoi.array(Zoi.object(%{"name" => string, "description" => string,
  "weight" => number}))`; normalize clamps `weight` to `0..1` and drops
  non-map/non-numeric entries), `exit_conditions` (array of strings). State
  carries them
  (`clarify/state.ex`, incl. `metadata["pending_clarify"]` round-trip);
  `compose_premises/2` (`clarify.ex:296-303`) `put_present`s them.
- Triage: `acceptance_criteria` ONLY — extract explicitly-stated criteria,
  never invent (schema `triage/schema.ex:19-55`, struct + `from_map`/`to_map`
  in `triage/verdict.ex` — **round-trip invariant must hold**, prompt section
  in `triage/prompt.ex`). Merged in `build_premises/5`
  (`front_door.ex:979-984`) BEFORE the clarify merge (clarify wins); whole map
  routed through `Premises.normalize/1`.

**Renderer** (`premises_context.ex`): typed-aware — dedicated numbered
`### Acceptance criteria` section (AC ids) + legible principles/exit_conditions;
typed keys excluded from the generic `- **key**:` lines; typed sections
participate in the SAME whole-block byte budget (clip values, cap AC count,
fold under `@block_byte_budget`, `scope-shift` instruction always last).
**Absent typed keys → byte-identical output** (pin with test).

**Lint wiring — front door (blockers)**: the block-decision lives in
`compose_from_clarify/3` (`front_door.ex:334`), NOT `finish_launch` — every
surviving blocker derives from clarify-minted data, so grade `:c` is
impossible on a triage-only launch, and `{:clarify, resp}` already exists
natively there. On block: seed ledger items from blockers (idempotent by
question text, `user_input_required: true`), persist (result-checked writes),
return `{:clarify, resp}`. **Bounded by the existing round cap**: at cap,
proceed per #8 semantics (hold for ack / degraded compose) — never loop
forever. Sketch/talk unaffected; one-shot demotes blockers to findings.

**Lint wiring — plan-gate payload (warnings)**: `run_gate_wave/5`
(`route_composer.ex:1745-1761`) re-derives
`Premises.Lint.run(state.premises, mode: :gate)` (pure, no new persistence —
structurally blocker-free) and merges `Lint.to_details(report)` into
`gate_inputs[:lint]` (`%{}` when clean). The payload is **namespaced under
`"premises_lint"`** so the merge can never collide with `summary`/
`gate_title`/`gate_description`/`fields` — pin that survival with a test.
`PlanGate` AND `SafetyGate` reactors (both dispatched only via `run_gate_wave`
— verified) gain `input(:lint)` + `argument(:extra_details, input(:lint))` on
the `:approval_gate` step. **GateStep change required**
(`orchestration/gate_step.ex:54-80` currently ignores arguments): merge
`arguments[:extra_details]` (map) into details —
`Presentation.details |> Map.merge(options details) |> Map.merge(runtime_extra_details(arguments))`;
no-arg or empty → `%{}` → byte-identical `AgentCase.details` (JSONB `:map`
field — only string-keyed JSON-safe values ever enter it). GateResume replays
the frozen struct + inputs from the checkpoint (verified
`gate_resume.ex:216-269`; the halted gate step is dropped at halt) — no resume
hazard.

**Consumers**:
- Reviewer-lens task strings (`catalog.ex:303-346`, 4 stages): append a
  criteria-aware clause ("when run premises carry acceptance criteria, verify
  each and cite AC ids in findings"). VerifyStage is command-based — no
  verifier-lens change (verified).
- `verify_certificate`: `:acceptance_criteria` as an optional-preserved
  ToolContext key (the `forge_session_key` pattern, `tool_context.ex:113-120`;
  NOT in `@policy_controlled_keys` — always forwarded). Seeding path:
  `run_reactor/3` (`route_composer.ex:~2530`) puts it into the wave context
  from `Premises.criteria/1` only when non-empty → `AgentRunner.resolve_scope/2`
  (`agent_runner.ex:672-694` — fixed pick-list, ADD the key at `:692`) →
  `ToolContext.build`. The tool (`tools/verify_certificate.ex:60-73`) appends a
  deterministic "Acceptance criteria (from run premises)" block (AC ids) to
  `specification` before `Certificates.template_for/2`. Absent → byte-identical.
  Criteria bytes are engine-threaded, never LLM-relayed.
- Skill knob (operator: wire it): `inject_produces_instruction/2`
  (`agent_runner.ex:600-620`) renders `produces["verification_criteria"]` when
  a non-empty list; `iterative_step.ex` `run_evaluator/5` (`:205-221`) folds
  the criteria into the evaluator context (augment `evaluator.task` before
  `ContextBuilder.build_task/4`).
- Cron (operator: REQUIRED at creation) — **the contract must be LIVE at
  fire time, not just persisted**:
  - New `JidoClaw.Cron.OutcomeSpec` — the single canonicalizer:
    `normalize/1` (string-keyed `%{"end_state" => …, "check" => …,
    "stop_bound" => …}` | nil — no atom/string drift across the JSONB
    boundary), `validate/1` (creation rules: all non-empty, ≤500 chars,
    `check` ≠ `end_state` case-insensitive — OpenHelm shape), and
    `render_block/1` (the one deterministic contract-text renderer both
    dispatch arms reuse).
  - `tools/schedule_task.ex` gains `end_state`/`check`/`stop_bound`
    **required** params, validated + normalized via `OutcomeSpec`, persisted
    as `Job.metadata["outcome_spec"]` (`:metadata` already accept-listed — no
    resource change, no migration). **No direct live-schedule path from the
    tool** — the flow stays row-driven (persist → `CronOwner.notify_changed/1`,
    `schedule_task.ex:121` → owner reconcile via `schedule_persisted/2`,
    `owner.ex:411`), preserving leader ownership under clustering; the first
    live worker picks the contract up through reconcile +
    `build_persistent_opts/1`.
  - `Cron.Scheduler.build_persistent_opts/1` (`scheduler.ex:67-84`) hydrates
    `outcome_spec: OutcomeSpec.normalize(job.metadata["outcome_spec"])` into
    worker opts; `fingerprint_from_opts/1` + `worker_fingerprint/1`
    (`scheduler.ex:249+`) BOTH gain the normalized key so `changed?/2`
    restarts a worker whose contract was edited (and doesn't false-restart an
    unchanged one).
  - `Cron.Worker` defstruct + `@type` (`worker.ex:44-88`) gain
    `outcome_spec: nil`; init picks it from opts.
  - `Cron.Dispatcher` (`dispatcher.ex:53-75`): both `run_agent` arms send
    `state.task` plus `OutcomeSpec.render_block(state.outcome_spec)` ("[Outcome
    contract — the run succeeds ONLY if this is met] End state: … / Check: … /
    Stop bound: …") when present; absent → byte-identical. MFA arm untouched
    (system jobs exempt).
  - `Orchestration.WorkflowRunner.extra_context/1`
    (`workflow_runner.ex:143-145`) appends the same `render_block/1` output
    for `:workflow` targets (shared renderer — no duplicated block text).
  - Enforcement lives in the tool only; operator CLI
    (`cli/commands.ex:1691`) and the migration task stay exempt (their jobs
    simply carry no contract). Tool not on the MCP served surface — no
    SurfaceVersion bump. Do NOT edit `system_prompt.md` (byte-identical sync
    trap); guide the model via the tool `description:`/param `doc:` strings.

**Telemetry**: counter `jido_claw.premises_lint.total` (grade tags) beside
`emit_clarify` (`core/telemetry.ex:~321`); Trace `:guardrail` events on
blockers/loop-back (the `front_door.ex:438-453` pattern).

## Commit slicing (queue: "2 commits — keys + lint / consumers")

### Commit 1 — PORT map, typed keys, renderer, lint, gate/front-door wiring, docs

Create: `docs/exploration/ouroboros/PORT-OB1-2.md` (⚠ sign-off pause),
`lib/jido_claw/route_composer/premises.ex`, `…/premises/lint.ex`,
`docs/system/structured-premises.md`,
`test/jido_claw/route_composer/premises_test.exs`,
`…/premises/lint_test.exs`, `test/jido_claw/orchestration/gate_step_test.exs`
(new — pins the `extra_details` merge + no-arg byte-identity).

Modify: `clarify/scorer.ex` (+schema/normalize), `clarify/state.ex`
(+fields/round-trip), `clarify.ex` (compose_premises), `triage/schema.ex`,
`triage/verdict.ex`, `triage/prompt.ex`, `front_door.ex` (build_premises merge
+ normalize + clarify-lane lint gate w/ round-cap guard),
`premises_context.ex` (typed sections + budget), `gate_step.ex` (f-1 merge),
`reactors/plan_gate.ex` + `reactors/safety_gate.ex` (`input(:lint)` +
argument), `route_composer.ex` (`run_gate_wave` lint merge),
`core/telemetry.ex`, `docs/system/ambiguity-clarify.md` (bump `verified:` —
mandatory, clarify touched), `docs/system/README.md` (index), `AGENTS.md`
(Key Patterns bullet → page pointer).

Suggested message: `feat: structured premises — typed acceptance-criteria keys + deterministic premises lint (ouroboros OB1-2, orca OR2-5 fold)`

### Commit 2 — consumers, eval case, reconciles

Create: `lib/jido_claw/platform/cron/outcome_spec.ex` (the canonicalizer:
`normalize/1` / `validate/1` / `render_block/1`) + its unit test.

Modify: `catalog.ex` (4 reviewer tasks), `agent_runner.ex` (`resolve_scope`
key + `inject_produces_instruction` rendering), `tool_context.ex`
(optional-preserve), `tools/verify_certificate.ex` (criteria append),
`skills/steps/iterative_step.ex` (evaluator fold), `route_composer.ex`
(`run_reactor` context seeding), `tools/schedule_task.ex` +
`platform/cron/scheduler.ex` + `platform/cron/worker.ex` +
`platform/cron/dispatcher.ex` + `orchestration/workflow_runner.ex` (the
outcome-contract thread: persist → owner reconcile → hydrate → fingerprint →
fire-time append; row-driven, never a tool-side live schedule),
eval `:prompt` seed case in `test/jido_claw/eval/prompt_cases_test.exs`
(pins AC rendering into a subagent prompt — the gepa "AC = labeled eval-task
candidate" producer).

Reconcile docs (the queue's own habit — corrections mirrored to sources):
ouroboros OB1-2 **Status: ADOPTED** + corrections; orca OR2-5 (item-9 half
lands; OQ-2 answered: index-id linkage) ; gepa GP1-3/OQ-2 provenance note;
OpenHelm OH1-3 note (required-at-creation adopted); queue README item-9
done-note with corrections (e.g. "C3-5 acceptance field never landed —
plan-task lint has no substrate; lint blockers are clarify-lane-only by
construction; GateStep grew the runtime extra_details merge").

Suggested message: `feat: premises consumers — reviewer AC citations, certificate criteria threading, skill verification_criteria live, cron outcome contract (OB1-2 consumers, OH1-3)`

## Existing tests that MUST change

- `premises_context_test.exs` — typed sections + explicit byte-identical pin
  (existing generic pins stay green unchanged).
- `clarify/scorer_test.exs` — new schema fields.
- `reactors/plan_gate_test.exs` — gate inputs gain `lint: %{}` (new required
  input); grep composer/gate fixtures (`test/support/**/fixtures.ex`,
  `human_gates_test`, `gate_lifecycle_test`) for manual PlanGate/SafetyGate
  input construction — anything not going through `run_gate_wave` needs `:lint`.
- Triage verdict round-trip test (locate via `grep -rn "to_map" test/`) —
  new field must round-trip; clarify `pending_clarify` persistence tests.
- `catalog_test.exs` if it pins reviewer task strings.
- `tool_context_shape_test.exs` — the golden optional-key contract already
  pins `forge_session_key` (`:54`); the optional-preserved
  `acceptance_criteria` must update/pin that shape too.
- `schedule_task_test.exs` — every call gains the triple + validation cases.
- **Cron execution tests (fire-time behavior, not just tool validation)**:
  hydration verified through the PUBLIC seams (`build_persistent_opts/1` is
  private) — extend `test/jido_claw/cron/scheduler_idempotency_test.exs`
  (`:46` pattern): `Scheduler.schedule_persisted/2` + `Worker.get_state/2`
  prove the worker state carries the normalized `outcome_spec`;
  `Scheduler.changed?/2` proves restart-on-contract-edit and stability when
  unchanged. Dispatcher test (both agent arms' task text carries the contract
  block; absent → byte-identical); workflow-runner test (extra context
  carries the block).
- Gate-details survival pin: `summary`/`gate_title` intact after a
  `premises_lint`-bearing merge (in the new `gate_step_test.exs`).
- `eval/prompt_cases_test.exs` — reviewer-prompt case may pin task strings.

## Precommit hazards (from repo memory + review)

Run everything via `mise exec -- mix …`; run gates BARE in background (never
`| tail` — masks exit codes). Hazards: credo strict `@spec` on all new public
fns; AliasUsage; ExSlop EXS3004 (never start a wrapped comment line with the
word "step"); dialyzer wants `Zoi.schema()` not `Zoi.t()` in specs; reach gate
(no bare rescue — pattern-match `normalize/1` total); `mix
jidoclaw.system_docs.check` (new page needs frontmatter + Source map + README
index + AGENTS.md pointer, bidirectional; ambiguity-clarify.md `verified:`
bump); `mix jidoclaw.jido_md.check` — if `schedule_task`'s description string
drifts the committed `.jido/JIDO.md` table, regenerate via
`JidoClaw.JidoMd.generate/1`; flaky async:false suites (MCPServer, Prompt,
PipelineStore, MultiSandbox) — verify failures in ISOLATION before blaming.

## Verification

1. Unit: lint battery (vague/observable/untestable/advisory/grade + the mode
   split — gate mode never returns blockers), premises normalize/accessors,
   renderer byte-identity + budget, GateStep merge, verdict + clarify-state
   round-trips.
2. Flow: eval `:prompt` case proves ACs render into a subagent prompt;
   composer test proves plan-gate `AgentCase.details` carries the namespaced
   `premises_lint` warnings (and stays byte-identical when clean); clarify-lane
   test proves a high-risk-assumption blocker re-opens a round below cap and
   demotes at cap; `verify_certificate` test proves the criteria block lands in
   the certificate prompt engine-side; cron fire-time tests prove the outcome
   contract reaches the dispatched agent task / workflow extra context (and
   that a contract edit reconciles the running worker).
3. `mise exec -- mix precommit` — **the item is not complete until it passes**
   (run bare, in background, read the tail).
4. Deviations log: record every deviation in
   `docs/plans/unadopted-next-ten/README.md` item-9 done-note (+ PORT map if
   semantics-affecting) as they happen.

Nothing gets committed — finish commit-ready and end with the two staged-file
lists + suggested messages above.
