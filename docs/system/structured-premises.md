---
type: subsystem
description: Typed premises keys (acceptance criteria / principles / exit conditions), the deterministic premises lint, and the consumers that make criteria live — plus the cron outcome contract.
sources:
  - lib/jido_claw/route_composer/premises.ex
  - lib/jido_claw/route_composer/premises/lint.ex
  - lib/jido_claw/route_composer/premises_context.ex
  - lib/jido_claw/route_composer/route_composer.ex
  - lib/jido_claw/route_composer/catalog.ex
  - lib/jido_claw/front_door.ex
  - lib/jido_claw/front_door/clarify.ex
  - lib/jido_claw/front_door/clarify/scorer.ex
  - lib/jido_claw/front_door/clarify/state.ex
  - lib/jido_claw/front_door/clarify/ledger.ex
  - lib/jido_claw/triage/schema.ex
  - lib/jido_claw/triage/verdict.ex
  - lib/jido_claw/triage/prompt.ex
  - lib/jido_claw/orchestration/gate_step.ex
  - lib/jido_claw/orchestration/reactors/plan_gate.ex
  - lib/jido_claw/orchestration/reactors/safety_gate.ex
  - lib/jido_claw/tools/verify_certificate.ex
  - lib/jido_claw/tool_context.ex
  - lib/jido_claw/skills/steps/agent_runner.ex
  - lib/jido_claw/skills/steps/iterative_step.ex
  - lib/jido_claw/platform/cron/outcome_spec.ex
  - lib/jido_claw/platform/cron/scheduler.ex
  - lib/jido_claw/platform/cron/worker.ex
  - lib/jido_claw/platform/cron/dispatcher.ex
  - lib/jido_claw/orchestration/workflow_runner.ex
  - lib/jido_claw/tools/schedule_task.ex
  - docs/exploration/ouroboros/PORT-OB1-2.md
verified: 2026-07-08
---

# Structured Premises

## What & why

Queue item 9 (ouroboros OB1-2 with the orca OR2-5 quality-gate fold and the
OpenHelm OH1-3 outcome-contract shape). Before it, the AR-9 premises pipe
carried launch *assumptions* only (`path`, `est_size`, clarify keys);
certificate `specification` was transient LLM-relayed free text; skill
`verification_criteria` was a hardcoded inert YAML list; scheduled jobs
carried no success contract. This subsystem gives success criteria a durable,
typed, machine-checkable carrier and wires consumers on both ends — so what
"done" means is established at launch, linted deterministically, visible at
the human gate, cited by reviewers, threaded into the verification
certificate, and (for cron) required at creation. Lint semantics are ported
from `Q00/ouroboros @ e905a41c` (MIT) `auto/grading.py`; the signed-off port
map with every divergence is `docs/exploration/ouroboros/PORT-OB1-2.md`.

## Invariants & contracts

- **Three typed optional premises keys** (`JidoClaw.RouteComposer.Premises`):
  `"acceptance_criteria"` (list of criterion strings),
  `"evaluation_principles"` (`%{"name","description","weight" ∈ 0..1}`
  maps), `"exit_conditions"` (list of strings). Everything else in premises
  stays free-form.
- **AC identity = 1-based index ids** `AC1`, `AC2`, … (orca OQ-2's reserved
  linkage): premises compose once at launch, so the ids are stable for the
  run's lifetime. `Premises.criteria_with_ids/1` is the one id mint; the
  renderer, reviewer task clauses, and `verify_certificate` all cite the same
  ids.
- **`Premises.normalize/1` is the write boundary** (`build_premises/5` routes
  the whole merged map through it): a malformed typed value drops its key —
  Trace'd (`guardrail: "premises"`), fail-open, the launch proceeds. Read
  accessors are tolerant over arbitrary durable state (junk ⇒ `[]`).
- **Producers never invent**: triage extracts ONLY explicitly-stated criteria
  (prompt-forbidden invention; `acceptance_criteria` on the verdict, wire
  round-trip pinned); the clarify scorer distills criteria from what the user
  stated or confirmed, re-emitting full lists per round (the fold keeps the
  prior round's list when a result omits one). Triage criteria merge BEFORE
  the clarify keys — a clarify loop's richer criteria win.
- **The lint is pure, total, and mode-split** (`Premises.Lint`):
  `run(premises, mode: :clarify, ledger:)` may emit blockers;
  `run(premises, mode: :gate)` — and ANY unknown/missing mode, fail-closed —
  **structurally cannot**. Blockers are exclusively the ledger-derived safety
  set (`high_risk_assumptions`, `ledger_open_gap`, `high_ambiguity_score`);
  ALL acceptance-criteria quality checks (missing / empty / vague /
  untestable / meaningless) are findings-only in every mode, and the >9-AC
  advisory never flips the grade (blockers ⇒ `:c`, findings ⇒ `:b`, else
  `:a`).
- **Degraded demotes all blockers** (map decision (B)): a compose whose
  premises carry `"degraded" => true` only exists after #8's hold-for-ack ack
  or at the round cap — the human confirmation ouroboros's §I6 wants — so
  re-blocking it would loop the operator against their own decision.
- **Blocker → clarify re-open below the cap only** (map decision (C)):
  `Clarify.lint_gate/2` seeds an idempotent confirm question
  (`Ledger.append_missing/2`, normalized-question-text key) and re-opens a
  round; at the cap #8's semantics own the exit; `:one_shot` never parks and
  skips the clarify-side lint (the gate re-lint still covers premises-borne
  checks).
- **The gate payload is namespaced and bounded**: `run_gate_wave/5` re-lints
  premises in `:gate` mode and merges `Lint.to_details/1` —
  `%{"premises_lint" => %{"grade", "findings", "advisories"}}`, string-keyed,
  counts capped, messages clipped + redacted — into the gate reactor's
  `input(:lint)`; `GateStep` merges the runtime `:extra_details` argument
  LAST over the DSL + option details. A clean report is `%{}` ⇒
  `AgentCase.details` byte-identical; the namespace makes a collision with
  `summary`/`gate_title`/`gate_description`/`fields` impossible (pinned).
- **Criteria are engine-threaded to the certificate, never LLM-relayed**:
  `run_reactor/3` seeds `:acceptance_criteria` into the wave context only
  when non-empty → `AgentRunner.resolve_scope/2` picks it →
  `ToolContext.build/1` preserves it (optional-preserved, NOT
  policy-controlled) → `verify_certificate` appends a deterministic
  "Acceptance criteria (from run premises)" block (AC ids) to
  `specification` before the certificate template renders. Absent ⇒
  byte-identical.
- **Renderer byte-identity**: absent typed keys render byte-identically to
  the pre-item-9 premises block; typed sections participate in the same
  whole-block byte budget (AC count capped, values clipped, trailing
  sections fold behind markers, the `scope-shift` instruction always last).
- **Cron outcome contract is required at creation** (OH1-3, operator
  decision): the `schedule_task` tool requires `end_state`/`check`/
  `stop_bound` (all non-empty, ≤ 500 chars, `check` ≠ `end_state`
  case-insensitive — `Cron.OutcomeSpec.validate/1`), persisted string-keyed
  as `Job.metadata["outcome_spec"]`. Enforcement lives in the tool only —
  the operator CLI and system/migration jobs are exempt (their jobs carry no
  contract). The contract is **live at fire time**, not just persisted:
  scheduler hydration + fingerprint (a contract edit restarts the worker;
  an unchanged one doesn't), and both dispatcher agent arms /
  `WorkflowRunner.extra_context/1` append the SAME `render_block/1` text.
  MFA (system) jobs are untouched.

## Mechanics

### The write path

`FrontDoor.build_premises/5` merges: base (`path`/`est_size`) → launch
extras → triage `acceptance_criteria` (when non-empty) → `graduated_from` →
clarify premises (LAST — richer criteria win) → `Premises.normalize/1`.
The clarify scorer's structured output gains the three typed fields
(Zoi-optional; value-normalized at the boundary with the same rules the
write boundary applies); `Clarify.State` persists them under
`metadata["pending_clarify"]` and `compose_premises/2` puts only non-empty
lists (a run that distilled nothing must not stamp `[]` — the
present-but-empty lint finding is reserved for producers that CLAIM the
key).

### The lint

Ported checks (see the map for the row-by-row source anchors):

| check | class | fires |
| --- | --- | --- |
| `vague_acceptance_criteria` | finding | 9-term bank, word-boundary, case-insensitive |
| `untestable_acceptance_criteria` | finding | 22-hint pre-filter AND none of the 11 observable regexes |
| `meaningless_acceptance_criteria` | finding | orca bank over lowercase-alphanumeric normalization (`todo/tbd/na/none/acceptancecriteria`, empty) |
| `missing_acceptance_criteria` | finding | key absent AND a clarify loop ran (the `:ledger` opt, or the `"ambiguity_score"` premises fingerprint at gate time) |
| `empty_acceptance_criteria` | finding | key present, list empty |
| `over_fragmented_criteria` | advisory | > 9 criteria; never flips the grade |
| `high_ambiguity_score` | blocker-class | `"ambiguity_score"` > 0.20 (matches #8's ≤ 0.2 pass gate exactly); degraded demotes |
| `ledger_open_gap` | blocker-class | unresolved `user_input_required` ledger item (non-required unresolved ⇒ finding); degraded demotes |
| `high_risk_assumptions` | blocker-class | 6 risky terms over `assumed` items' defaults (question fallback); single blocker; degraded demotes |

Blocker-class entries land in `blockers` only when `mode: :clarify` AND not
degraded; otherwise they demote to findings. Entries are
`%{code:, message:, target:}` maps (never tuples); `to_details/1` emits the
bounded string-keyed JSONB form (≤ 16 entries, messages clipped at 240B and
`Patterns.redact/1`-scrubbed) or `%{}` when clean.

### The gate payload

`run_gate_wave/5` → `gate_lint/1` (pure re-derive + telemetry) →
`gate_inputs[:lint]` → `PlanGate`/`SafetyGate` `input(:lint)` →
`argument(:extra_details, input(:lint))` on the `:approval_gate` step →
`GateStep` merges `Presentation.details |> Map.merge(option details)
|> Map.merge(runtime extra_details)`. GateResume replays the frozen inputs
from the checkpoint; the halted gate step is dropped at halt — no resume
hazard.

### Consumers

- **Reviewer lenses** (`catalog.ex`, the 4 review-family stage tasks): a
  criteria-aware clause — when run premises carry acceptance criteria,
  verify each and cite AC ids in findings. VerifyStage is command-based; the
  verify authority takes no criteria (its verdict is the exit code).
- **`verify_certificate`**: the tool appends the deterministic criteria
  block to `specification` before `Certificates.template_for/2`; the bytes
  come from `ToolContext` (engine-threaded), so a worker can neither forge
  nor omit them.
- **Skill knob (now live)**: `inject_produces_instruction/2` renders
  `produces["verification_criteria"]` (non-empty list) into the worker
  instruction, and `IterativeStep.run_evaluator/5` folds the same criteria
  into the evaluator's task — the previously-inert YAML knob now shapes both
  sides of the produce/evaluate loop.
- **Premises block** (`PremisesContext`): dedicated `### Acceptance
  criteria` (AC-id-numbered) / `### Evaluation principles` /
  `### Exit conditions` sections between the generic bullets and the
  `scope-shift` instruction; typed keys never render as generic bullets.

### The cron outcome contract (OH1-3 rider)

`Cron.OutcomeSpec` is the single canonicalizer: `normalize/1` (string-keyed
`%{"end_state","check","stop_bound"}` | nil — no atom/string drift),
`validate/1` (creation rules), `render_block/1` (the one deterministic
contract-text renderer). Flow stays row-driven (persist →
`CronOwner.notify_changed/1` → owner reconcile → `schedule_persisted/2`) —
no tool-side live schedule, preserving leader ownership under clustering.
`Scheduler.build_persistent_opts/1` hydrates the normalized spec into worker
opts; `fingerprint_from_opts/1` + `worker_fingerprint/1` both carry it so
`changed?/2` restarts an edited worker and leaves an unchanged one alone.
Both `Dispatcher.run_agent` arms append `render_block/1` to the task;
`WorkflowRunner.extra_context/1` appends the same block for `:workflow`
targets. Absent spec ⇒ byte-identical everywhere. The CLI exemption is
explicit, not incidental: `/cron add` sets `metadata: %{}` on its upsert, so
re-adding an agent-created job id deterministically clears the stored
contract instead of riding Ash default-application-on-conflict subtleties
(pinned in `commands_cron_test.exs` and `job_test.exs`).

## Config & telemetry

- No new config knobs: the lint has no thresholds to tune (ported constants),
  and the cron contract's rules live in `OutcomeSpec.validate/1`.
- Counter `jido_claw.premises_lint.total`, tags `[:grade, :mode]` — one per
  lint run (`:clarify` at compose time, `:gate` per gate wave).
- The clarify counter gains the `:lint_block` event (a blocker re-open, via
  `serve_round`); `Premises.normalize/1` key drops Trace as
  `:guardrail` / `guardrail: "premises"` / `event: :typed_key_dropped`.

## Residuals & accepted risks

- **Ledger-derived findings don't reach the gate payload**: the gate re-lint
  has no ledger, so a high-risk assumption demoted at the cap (or on
  one-shot) surfaces via the honest premises labeling
  (`degraded`/`unresolved_slots`/`clarifications` digest) rather than as a
  labeled `premises_lint` finding. Accepted: the plan gate still shows the
  premises-borne warnings, and the clarifications digest carries the
  assumption Q/A.
- **The high-risk re-open relies on the scorer folding the confirmation**:
  the seeded confirm question re-opens the round, but the original `assumed`
  item stops firing only when the scorer folds the user's confirmation into
  it (assumed → answered). A scorer that never folds it re-blocks each
  compose until the round cap — bounded, never infinite.
- **Criteria quality is advisory by design**: vague/untestable/meaningless
  criteria ride to the human plan gate as warnings; nothing auto-repairs
  them (the ouroboros template repairer was deliberately skipped — our loop
  has a human on both ends).
- **Cron contract text is prompt-trusted**: `render_block/1` output rides
  the dispatched agent task verbatim (500-char caps bound it). The tool's
  arg validation is the creation fence; the contract is guidance to the
  agent, not an engine-verified postcondition (that would be the verify
  authority's territory, out of scope here).

## Source map

- `lib/jido_claw/route_composer/premises.ex` — typed keys, normalize, accessors, AC ids
- `lib/jido_claw/route_composer/premises/lint.ex` — the ported lint + `to_details/1`
- `lib/jido_claw/route_composer/premises_context.ex` — typed sections, budgets
- `lib/jido_claw/route_composer/route_composer.ex` — `gate_lint/1` (run_gate_wave), `seed_criteria_context/1` (run_reactor)
- `lib/jido_claw/route_composer/catalog.ex` — reviewer-lens criteria clauses
- `lib/jido_claw/front_door.ex` — `build_premises/5` merge + normalize, the lint-gate branch in `compose_from_clarify/3`
- `lib/jido_claw/front_door/clarify.ex` — `lint_gate/2`, blocker question seeding
- `lib/jido_claw/front_door/clarify/scorer.ex` / `state.ex` / `ledger.ex` — typed-field producer plumbing + `append_missing/2`
- `lib/jido_claw/triage/schema.ex` / `verdict.ex` / `prompt.ex` — extraction-only triage criteria
- `lib/jido_claw/orchestration/gate_step.ex` — the runtime `:extra_details` merge
- `lib/jido_claw/orchestration/reactors/plan_gate.ex` / `safety_gate.ex` — `input(:lint)`
- `lib/jido_claw/tools/verify_certificate.ex` + `lib/jido_claw/tool_context.ex` + `lib/jido_claw/skills/steps/agent_runner.ex` — the certificate criteria thread + the live skill knob
- `lib/jido_claw/skills/steps/iterative_step.ex` — evaluator criteria fold
- `lib/jido_claw/platform/cron/outcome_spec.ex` / `scheduler.ex` / `worker.ex` / `dispatcher.ex` + `lib/jido_claw/orchestration/workflow_runner.ex` + `lib/jido_claw/tools/schedule_task.ex` — the cron outcome contract thread
- `test/jido_claw/route_composer/premises/lint_test.exs` — the ported battery (source-test anchors in the map)
- `docs/exploration/ouroboros/PORT-OB1-2.md` — the signed-off port semantics map
