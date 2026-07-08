# PORT-OB1-2 — Structured premises: acceptance criteria + lint (semantics map)

Implements [OB1-2 — Structured premises: acceptance criteria + a deterministic spec linter](FEATURES-WORTH-BORROWING.md#ob1-2-structured-premises--acceptance-criteria--a-deterministic-spec-linter),
with the [orca OR2-5](../pms/orca/FEATURES-WORTH-BORROWING.md) deterministic
quality-gate fold and the [OpenHelm OH1-3](../pms/openhelm/FEATURES-WORTH-BORROWING.md)
outcome-contract *shape* as riders. Primary source: `Q00/ouroboros @ e905a41c`
(MIT, © 2025 Q00) — HEAD has moved to `98d3d66d`; all reads are at the pin via
`git show e905a41c:src/ouroboros/auto/grading.py` (never checked out). Rider
sources: orca @ `2520b31` (MIT, `apps/desktop/src-tauri/src/briefing.rs`);
OpenHelm @ `2facabaa` (**BUSL-1.1** — the three field names + validation rules
are adopted as *shape/inspiration only*, no code transcription). Target:
jido_radclaw @ `96dfaadd` + this change. Date: 2026-07-08. This map covers the
**deterministic lint port** (queue item 9 step 2); the typed premises keys,
renderer, and consumers around it are house design, recorded in the
implementation plan rather than here.

## What the source actually does

Ouroboros's `GradeGate` (`auto/grading.py:109-418`) is a deterministic,
LLM-free gate that prevents under-specified Seeds from running in auto mode.
The mechanism, in their terms:

1. **Vagueness scan** (`:474-476`): each acceptance criterion is scanned for 9
   `VAGUE_TERMS` ("easy", "intuitive", "robust", "scalable", "better",
   "improve", "optimized", "user-friendly", "seamless"; `:23-33`) as
   word-boundary regex matches over the lowercased text → a
   `vague_acceptance_criteria` finding per hit (`:244-254`).
2. **Observability scan** (`:479-498`): a criterion must first contain at
   least one of 22 `_OBSERVABLE_HINTS` substrings (`:34-57` — cheap
   pre-filter), then match at least one of 11 `observable_patterns` regexes
   (`:485-497` — "`cmd` prints…", "…returns … stdout/file/exit code…",
   "test … passes", "exit code 0", "GET … returns 200", etc.). Failing either
   → an `untestable_acceptance_criteria` finding (`:255-264`). A separate
   final-report clause (`:501-520`) whitelists their auto-pipeline's
   "Final report includes …" phrasing when all 5 required fields are present
   and not contradicted.
3. **Structural checks**: empty AC list → `missing_acceptance_criteria`
   finding (`:234-243`); missing constraints / non-goals → findings
   (`:224-233`, `:345-354`); empty/mismatched goal → **blockers**
   (`:194-205`, token-overlap match `:421-471`).
4. **Ledger-derived safety blockers**: `high_ambiguity_score` when the seed's
   LLM-reported ambiguity > 0.20 (suppressed under `ledger_only`/
   `safe_default` closure or degraded seeds; `:206-223`); `ledger_open_gap`
   per unresolved required section — demoted to a finding on degraded seeds
   EXCEPT `LedgerStatus.BLOCKED` gaps (human input required), which stay
   blockers even degraded (`:291-340`, the §I6 safety contract);
   `high_risk_assumptions` when any active assumption-class entry
   (`ASSUMPTION` or `AUTO_FILL_INFERENCE` source, status not
   WEAK/CONFLICTING/BLOCKED, section ≠ non_goals) contains one of 6 risky
   terms — "credential", "api key", "production", "payment", "legal",
   "medical" (`:556-571`).
5. **Advisory lane** (`:275-289`): > 9 acceptance criteria →
   `over_fragmented_criteria`, collected separately so it never flips the
   grade or scores ("frugality is goal-subordinate; we surface waste, we do
   not block a runnable seed on it").
6. **Grading** (`:387-418`): blockers ⇒ C; else findings or any score
   threshold miss ⇒ B; else A. `may_run = (grade == A)`. Scores (coverage /
   ambiguity / testability / execution_feasibility / risk) are arithmetic
   derivations from finding/blocker counts (`:370-379`, `:574-575`).
7. **Repair loop** (`seed_repairer.py`): B-grade seeds get an automated
   template repair pass, then re-grade.

The orca rider (`briefing.rs:552-617`) is the same posture at task-draft
level: a deterministic `validate_task_quality` requiring ≥ 1 task, a
"meaningful spec" check — normalize to lowercase ASCII alphanumerics and
reject the vacuous bank `todo | tbd | na | none | acceptancecriteria`
(`:539-549`) — and per-task relevant-files presence; one repair re-prompt,
then fail loud.

The OpenHelm rider is a *shape*: agent-created scheduled jobs must declare
`endState` / `check` / `stopBound` at **creation** time (all three non-empty,
bounded length, `check` must differ from `endState`) — creation, not review
time, is the enforcement point.

## Side-by-side shapes

| Ouroboros (source) | jido_radclaw (planned) | Divergence note |
| --- | --- | --- |
| `VAGUE_TERMS` — 9 words (`grading.py:23-33`), word-boundary regex, lowercased input (`:474-476`) | Module attribute on `JidoClaw.RouteComposer.Premises.Lint` with attribution comment; same 9 words, `\b`-bounded, case-insensitive | Verbatim. |
| `_OBSERVABLE_HINTS` — 22 substrings (`:34-57`), plain `in` pre-filter (`:481-482`) | Same 22 substrings, `String.contains?/2` over downcased text | Verbatim pre-filter. |
| 11 `observable_patterns` regexes (`:485-497`) | The same 11 patterns as Elixir `Regex` literals (case-insensitive via pre-downcased input, as source) | Verbatim translation; Python `re` → PCRE is 1:1 for these patterns (alternations, `\b`, `.+`, bounded quantifiers; the lookahead in the pytest pattern carries over). |
| `missing_acceptance_criteria` / `vague_…` / `untestable_…` findings (`:234-264`) | Findings (→ plan-gate warnings). `missing_acceptance_criteria` fires **only when a clarify loop ran** — detected as the `:ledger` opt (`mode: :clarify`, compose time) OR the `"ambiguity_score"` premises fingerprint (the gate re-lint has no ledger; the clarify lane always composes that key) — a triage-only launch without ACs is the normal case, not a spec defect *(fingerprint mechanism added at implementation, 2026-07-08)*. **Policy pinned: ALL AC-quality checks (missing / vague / untestable / meaningless / empty-list) are findings-only — never blockers, never a clarify re-open.** Blockers are exclusively the ledger-derived safety set below | Same finding codes and per-index `target` strings (`acceptance_criteria[N]` → our `ACn` ids, see identity row). Severity semantics collapse: we keep `code`/`message`/`target`, drop `severity`/`repair_instruction` (no auto-repairer to consume them). |
| `over_fragmented_criteria` advisory, > 9 ACs, excluded from grade (`:275-289`) | Verbatim: separate `advisories` list, never affects `grade` | Verbatim, including the 9 threshold. |
| Grade A/B/C + `may_run` (`:387-418`) | `grade: :c` when blockers ≠ [], `:b` when findings ≠ [], else `:a`. No `may_run` (the consumer decides per lane) | Scores (coverage/ambiguity/testability/…) are derived-from-counts, observational — **dropped**; the grade collapses to the count rule, which is what their `_result` reduces to for our inputs (score thresholds only fire when findings exist, except via ledger-summary paths we don't port). Documented drop. |
| `high_ambiguity_score` > 0.20 blocker, suppressed under ledger-primary closure / degraded (`:206-223`) | Ported as a **clarify-mode-only blocker** over premises `"ambiguity_score"` (the #8 effective score — already `max(llm, deterministic_floor)`). Belt-and-braces: #8's pass gate already holds ≤ 0.2, so on a clean pass it cannot fire; same 0.20 boundary, exclusive (> 0.20 blocks, ≤ 0.20 passes — matches both source sites). Gate mode (`mode: :gate`) demotes it to a finding | Threshold reconciliation: source compares `> 0.20`; #8's pass gate admits `≤ 0.2`. Identical boundary — no gap. Suppression-when-degraded carries over: degraded premises (`"degraded" => true`) demote it to a finding even in clarify mode (source `:214`). |
| `ledger_open_gap` blocker; degraded ⇒ finding EXCEPT BLOCKED gaps, which stay blockers (`:291-340`) | Clarify-lane only (needs the `:ledger` opt): an **unresolved** ledger item (status `open`/`conflicting`) with `user_input_required: true` → `ledger_open_gap` blocker; unresolved non-required items → findings. Degraded premises demote all of them to findings — see behaviors table for why our BLOCKED analogue does not survive degraded | Our ledger has item statuses, not required sections: `user_input_required: true` unresolved items are the BLOCKED analogue (human answer outstanding); other unresolved items map to MISSING/WEAK. Divergence (B) below covers the degraded case. |
| `high_risk_assumptions` — 6 risky terms over active assumption-class entry values (`:556-571`) | Clarify-lane only: substring scan (case-insensitive, same 6 terms) over each `"assumed"`-status ledger item's **assumed content** — `recommended_default_assumption`, falling back to the item's `question` when the default is blank (total-function guard; an assumed item always has at least its question as content). One blocker when count > 0, matching source (single finding regardless of count) | `assumed` status ≡ active assumption-class source (their WEAK/CONFLICTING/BLOCKED exclusions map to our `open`/`conflicting`/`answered` statuses simply not being `assumed`; `answered` = evidence-backed, excluded as source `answer`-class is). No non-goals section exists to exempt. Blocker → clarify re-open (below cap). |
| `missing_goal` / `seed_goal_mismatch` (`:194-205`, `:421-471`) | **Dropped** — no ledger goal section exists (PORT-OB1-1 dropped the section taxonomy); intent has its own precedence chain upstream of premises | Documented drop; the token-overlap matcher goes with it. |
| `missing_constraints` / `missing_non_goals` findings (`:224-233`, `:345-354`) | **Dropped** — no such premises keys and no producer writes them | Documented drop. |
| Final-report pattern family (`:58-64`, `:501-520`) | **Dropped** — ouroboros-auto-pipeline-specific phrasing whitelist | Documented drop; our criteria never carry their report contract. |
| `seed_repairer.py` template auto-repair | **Skipped** per queue decision — our loop has a human (clarify rounds below cap, the plan gate above) | The orca fold's repair-once-then-fail-loud FLOW maps structurally instead: the clarify loop's own rounds are the repair, the human plan gate is the fail-loud. |
| Scores dict + `_score_threshold` (`:370-379`, `:574-575`) | **Dropped** (see grade row) | Observational arithmetic over counts; nothing consumes it here. |
| orca `validate_task_quality`: meaningless-spec bank + ≥ 1 task (`briefing.rs:552-575`) | Folded as findings: `meaningless_acceptance_criteria` per AC whose normalization (lowercase, strip non-alphanumerics) lands in the bank `todo/tbd/na/none/acceptancecriteria`; `empty_acceptance_criteria` when the key is present but `[]` | Same normalization; both findings-only per the pinned policy. Relevant-files check **dropped** — no structured plan tasks exist (camus C3-5's `acceptance` field never landed; planner output is free text, `catalog.ex:102-132`). |
| orca task-id targeting (`task_id`/`field` per issue) | AC identity: 1-based index ids `AC1`, `AC2`, … (`Premises.criteria_with_ids/1`) — the documented contract for orca OQ-2's criterion-mapped review linkage | Premises compose once at launch, so indexes are stable for the run's lifetime. |
| OpenHelm `endState`/`check`/`stopBound` required at creation | `JidoClaw.Cron.OutcomeSpec`: `end_state`/`check`/`stop_bound` **required** on the `schedule_task` tool (agent-created jobs), all non-empty, ≤ 500 chars, `check` ≠ `end_state` case-insensitive | Shape-only adoption (BUSL-1.1): field names + validation rules, no code read into the port. Operator CLI + system/migration jobs exempt (they carry no contract). |
| GradeGate runs pre-generation + post-generation (`grade_ledger`/`grade_seed`) | One lint, two modes: `run(premises, mode: :clarify, ledger: …)` at clarify-compose time (may emit blockers → re-open a round below cap); `run(premises, mode: :gate)` re-derived at plan-gate build (structurally blocker-free — blocker-class checks demote to findings). Invalid/missing mode **fails closed to gate behavior** | The mode split is load-bearing: premises still carry `"ambiguity_score"` at gate time, and a gate-side blocker would have no consumer. Pinned by test: gate-mode and unknown-mode lint never return blockers. |
| `GradeFinding` dataclass (code/severity/message/target/repair_instruction) | Map entries `%{code: binary, message: binary, target: binary}` — never tuples (must survive a JSONB boundary); `Lint.to_details/1` emits the bounded, string-keyed, namespaced persistence form under `"premises_lint"` | Severity + repair_instruction dropped with the repairer. |

## Behaviors table

**Preserved exactly**

| Behavior | Source | Reason |
| --- | --- | --- |
| The 9 vague terms, word-boundary, case-insensitive | `grading.py:23-33,474-476` | The bank IS the check; fidelity is the point. |
| The 22 observable hints as a substring pre-filter | `grading.py:34-57,481-482` | Two-stage check: hints alone never pass (pinned by their `…_not_keywords` test). |
| The 11 observable regexes, verbatim | `grading.py:485-497` | Command-shaped wording must not bypass concrete observability (their vacuous-command tests). |
| Vague and untestable checks are independent — one criterion can fire both | `grading.py:244-264` | Per-criterion, per-check findings with per-index targets. |
| > 9 ACs → advisory only; never flips grade, absent for ≤ 9 | `grading.py:275-289` | "Surface waste, don't halt on it" — their advisory contract test pins grade A alongside the advisory. |
| Blockers ⇒ C; findings ⇒ B; clean ⇒ A | `grading.py:387-418` | The gate's decision rule (via the count-collapse noted above). |
| `high_ambiguity_score` boundary: > 0.20 blocks | `grading.py:214` | Matches #8's ≤ 0.2 pass gate exactly; no boundary gap. |
| Degraded suppresses `high_ambiguity_score` | `grading.py:214` (degraded arm) | A deliberately-labeled partial product must not re-block on the label's cause. |
| `high_risk_assumptions`: the 6 terms, substring, case-insensitive, active-assumption-class only, single blocker | `grading.py:556-571` | The §I6-class safety check — the one lint check that must reach a human even degraded (see changed (B) for the carrier). |
| Meaningless-spec normalization + bank (orca) | `briefing.rs:539-549` | Verbatim fold: lowercase → strip non-alphanumerics → reject the 5-entry bank. |
| Outcome contract required at creation, not review (OpenHelm shape) | OH1-3 inventory | Creation is the enforcement point; a fired job with no contract is unreviewable. |

**Deliberately changed**

| Behavior | Source → ours | Reason |
| --- | --- | --- |
| (A) `missing_acceptance_criteria` severity "high" finding, always → finding fired **only when a clarify ledger existed** | `grading.py:234-243` | Every ouroboros seed is *supposed* to carry ACs; most of our launches (triage-only, no clarify) legitimately carry none. Firing on those would make grade `:b` the noise floor and train operators to ignore the lint. When a clarify loop ran, criteria were extractable — absence is then a real signal. |
| (B) BLOCKED ledger gaps stay blockers even degraded → degraded demotes ALL ledger-derived blockers except none (the ack IS the human confirmation) | `grading.py:291-340` | Ouroboros's degraded path is an unattended deadline exit — a BLOCKED gap surviving it means NO human ever confirmed, so it must terminate. Our #8 cap semantics never auto-compose past a required unknown: the hold-for-ack gate parks until the operator explicitly acks "proceed with defaults". A degraded compose with open required items therefore only exists AFTER that ack — which is precisely the "resolve via human confirmation" their repair instruction demands. Re-blocking post-ack would loop the operator against their own decision. The §I6 intent (a human must see it) is preserved by a stronger carrier (a hard park, not a gradable blocker). |
| (C) Blockers terminate the auto pipeline → blockers re-open a clarify round (below cap), demote per #8 at cap, and demote to findings on `:one_shot` surfaces | pipeline semantics | We have a human in the loop; termination is their substitute for one. Below the round cap, a blocker seeds ledger items (idempotent by normalized question text, `user_input_required: true`) and returns `{:clarify, resp}` — the answer path. At cap, #8's hold-for-ack/degraded machinery takes over (bounded, never loops forever). One-shot surfaces never park (#8's posture): blockers demote to findings and ride the plan-gate payload — the human backstop moves to the gate. |
| (D) `grade_seed` reads seed.metadata.ambiguity_score → lint reads premises `"ambiguity_score"` (already the effective `max(llm, floor)` score) | `grading.py:214` | #8 composes the effective score into premises; re-deriving the floor here would double-count. Same anti-under-reporting property, single source. |
| (E) Findings feed the auto-repairer → findings ride the plan-gate payload as namespaced warnings (`"premises_lint"` under `AgentCase.details`) | `seed_repairer.py` | The human gate is the repairer. Bounded/capped/clipped at the JSONB boundary; clean report ⇒ `%{}` ⇒ byte-identical gate details. |
| (F) `severity` + `repair_instruction` per finding → dropped fields | `grading.py:67-84` | Severity only fed their score arithmetic (dropped); repair instructions only fed the repairer (skipped). `code`/`message`/`target` is the surviving consumer contract. |
| (G) orca's one-repair-re-prompt-then-fail-loud → structural mapping, not a lint loop | `briefing.rs` flow | The clarify loop's own rounds are the repair; the plan gate is the fail-loud. AC-quality findings never trigger a lint-side re-prompt (pinned policy: findings-only). |

**Dropped**

| Behavior | Source | Reason |
| --- | --- | --- |
| `missing_goal` / `seed_goal_mismatch` blockers + token-overlap goal matcher | `grading.py:194-205,421-471` | No ledger goal section (PORT-OB1-1 dropped the section taxonomy); intent precedence lives upstream. A goal-shaped lint over premises would be checking a field nothing writes. |
| `missing_constraints` / `missing_non_goals` findings | `grading.py:224-233,345-354` | No such premises keys, no producers. Adding keys to satisfy a lint would invert the dependency. |
| Final-report observability whitelist | `grading.py:58-64,501-520` | Their auto-pipeline's report contract; no analogue rides our criteria. |
| Scores dict (coverage/ambiguity/testability/execution_feasibility/risk) + `_score_threshold` | `grading.py:135-144,370-379,574-575` | Derived arithmetic over counts, observational only; grade collapses to the count rule for our inputs. Nothing here consumes scores. |
| `grade_ledger` (pre-generation gate over the section ledger) | `grading.py:115-145` | Section taxonomy dropped in OB1-1; the clarify pass gate + deterministic floor already govern pre-compose quality. |
| Template auto-repairer | `seed_repairer.py` | Queue decision: repair output reads as boilerplate; our loop has a human. |
| `closure_mode` suppression plumbing (`ledger_only`/`safe_default`) | `grading.py:206-213` | An artifact of their interview/grade split; our lint runs inside the compose path where #8's pass gate already embodies the closure decision. Degraded suppression (the half that matters) is preserved. |
| orca relevant-files checks | `briefing.rs:585-611` | No structured plan tasks exist to carry file lists (camus C3-5's `acceptance` field never landed; planner output is free text, `catalog.ex:102-132`). |
| `may_run` / `can_repair` result fields | `grading.py:95-96` | Lane-specific consumption decisions replace them (clarify re-open vs gate warnings). |

## Edge cases (anchored to source tests)

Source tests live at `tests/unit/auto/test_ledger_grading_answerer.py` (pin
`e905a41c`; line refs below).

| Ouroboros test | Our planned equivalent | Expected behavior (both sides) |
| --- | --- | --- |
| `test_grade_gate_accepts_observable_seed_with_ready_ledger` (`:234`) | `LintTest`: "`habit list` prints stable stdout containing created habits" | Passes both scans; no findings; grade `:a`. |
| `test_grade_gate_requires_observable_acceptance_behavior_not_keywords` (`:285`) | `LintTest`: "The command uses clean architecture" / "The API is maintainable" | Hints alone don't pass — both fire `untestable_acceptance_criteria` (2 findings), grade `:b`. |
| `test_grade_gate_rejects_vacuous_coding_command_acceptance_criteria` (`:322`) | `LintTest`: "The command exits" / "The command reports success" / "The command passes" | Command-shaped wording without a concrete observation → 3 untestable findings with per-index targets (ours: `AC1`–`AC3`), grade `:b`. |
| `test_grade_gate_rejects_vague_acceptance_criteria` (`:385`) | `LintTest`: "The CLI should be easy and user-friendly" | ≥ 1 `vague_acceptance_criteria` finding ("easy" + "user-friendly" hits), grade `:b`. |
| `test_grade_gate_accepts_exit_status_and_http_status_criteria` (`:1338`) | `LintTest`: "CLI exits 0 on success", "GET /health returns 200" | Both observable, grade `:a`. |
| `test_grade_gate_flags_over_fragmented_acceptance_criteria` (`:2818`) | `LintTest`: 10 clean observable ACs | `over_fragmented_criteria` advisory present; grade stays `:a` (advisories never flip grade). |
| `test_grade_gate_no_over_fragmentation_flag_for_normal_seed` (`:2843`) | `LintTest`: 1 clean AC | No advisory. |
| `test_grade_gate_blocks_high_ambiguity_seed` (`:1436`) | `LintTest`: premises `"ambiguity_score" => 0.45`, `mode: :clarify` | `high_ambiguity_score` blocker, grade `:c`. Gate mode: same premises → finding, grade `:b` — **never a blocker** (mode-split pin, no source analogue). |
| `test_grade_gate_ledger_only_suppresses_high_ambiguity_blocker` (`:2669`) — nearest degraded-suppression analogue | `LintTest`: `"ambiguity_score" => 0.45, "degraded" => true`, `mode: :clarify` | Suppressed as a blocker (finding instead) — the degraded arm of source `:214`. |
| `test_grade_gate_blocks_high_risk_auto_fill_inference` (`:1408`) | `LintTest`: ledger with an `assumed` item whose default reads "Use production credential for deployment" | `high_risk_assumptions` blocker (clarify mode + ledger), grade `:c`. |
| `test_grade_gate_ignores_inactive_high_risk_assumptions` (`:1385`) | `LintTest`: same text on an `open` (or `conflicting`) item | No high-risk blocker — only `assumed` items are scanned (their inactive-status exclusion). |
| `test_grade_seed_allows_safe_product_delete_assumptions` (`:1313`) | `LintTest`: assumed item "Users can delete their own tasks after confirmation" | No risky term ⇒ no blocker, grade `:a`. |
| `test_grade_gate_rejects_unresolved_ledger_even_with_clean_seed` (`:274`) | `LintTest`: clean ACs + an unresolved `user_input_required: true` ledger item, clarify mode | `ledger_open_gap` blocker, grade `:c`; with `"degraded" => true` premises → finding (changed (B): the ack already happened). |
| (no source analogue — the pinned policy) | `LintTest`: missing/vague/untestable/meaningless/empty-list AC checks in clarify mode | ALL findings-only — a lint run whose only hits are AC-quality checks NEVER returns blockers, in any mode. |
| (no source analogue — orca fold, `briefing.rs:539-549`) | `LintTest`: ACs "TODO", "tbd", "N/A", "Acceptance criteria" | Each normalizes into the bank → `meaningless_acceptance_criteria` finding per item; present-but-empty list → `empty_acceptance_criteria` finding. |
| (no source analogue — mode fail-closed) | `LintTest`: `mode: :gate`, unknown mode, missing mode | Never a blocker in the result, whatever the premises/ledger carry; unknown/missing mode behaves exactly as `:gate`. |
| (no source analogue — JSONB boundary) | `LintTest`: `to_details/1` | String-keyed, namespaced under `"premises_lint"`, counts capped + messages clipped; clean report ⇒ `%{}`. |

## Sign-off gate

Decisions this map pins (ratifying the reviewed plan; flagging anything here
reopens it):

1. **Findings-only AC quality**: every AC-quality check (missing / vague /
   untestable / meaningless / empty-list) is a finding — never a blocker,
   never a clarify re-open. Blockers are exclusively the ledger-derived
   safety set: `high_risk_assumptions`, `ledger_open_gap`,
   `high_ambiguity_score` (clarify mode only).
2. **Mode split, fail-closed**: `mode: :clarify` may emit blockers;
   `mode: :gate` (and any unknown/missing mode) structurally cannot.
3. **Degraded demotion incl. the BLOCKED analogue** (changed (B)): the #8
   hold-for-ack park is the human-confirmation carrier, so a post-ack
   degraded compose demotes ALL ledger-derived blockers; ouroboros's
   keep-BLOCKED-even-degraded is deliberately not carried.
4. **Blocker → clarify re-open below cap only** (changed (C)); at cap, #8's
   semantics own the exit; one-shot surfaces demote blockers to findings.
5. **Drops**: goal checks, constraints/non-goals findings, final-report
   whitelist, scores, `grade_ledger`, auto-repairer, orca relevant-files.
6. **AC identity**: 1-based `AC1`, `AC2`, … index ids; stable because
   premises compose once at launch.
7. **High-risk scan content**: `assumed` items only; text =
   `recommended_default_assumption`, falling back to `question` when blank.
8. **OpenHelm rider**: shape-only (BUSL-1.1) — three field names + creation
   validation rules; required on the `schedule_task` tool path only.

Sign-off: **granted by the operator 2026-07-08** (explicit sign-off act on
this map, separate from implementation-plan approval, ratifying decisions
1–8 above). Code follows this map. After shipping,
`docs/system/structured-premises.md` cites this map as port provenance.
