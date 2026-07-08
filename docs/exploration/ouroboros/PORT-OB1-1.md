# PORT-OB1-1 — Ambiguity clarify loop (semantics map)

Implements [OB1-1 — The ambiguity-gated clarification loop](FEATURES-WORTH-BORROWING.md#ob1-1-the-ambiguity-gated-clarification-loop--sharpen-the-ask-before-composing),
with the [orca OR2-5](../pms/orca/FEATURES-WORTH-BORROWING.md) ledger/readiness
shapes as a rider. Source: `Q00/ouroboros @ e905a41c` (MIT, © 2025 Q00), read
firsthand at `~/workspace/research/ouroboros` (HEAD == pin, verified
2026-07-07). Target: jido_radclaw @ `d4c7c197` + this change. Date: 2026-07-07.

## What the source actually does

Ouroboros refuses to generate its central Seed artifact until the ask is
measurably clear. The mechanism, in their terms:

1. **Scoring** (`src/ouroboros/bigbang/ambiguity.py`): an LLM scores the
   interview context on fixed dimensions (temp 0.1, JSON-only), each dimension
   getting a `clarity_score ∈ [0,1]` (clamped at parse). Overall
   `ambiguity = 1 − Σ(clarity_i × weight_i)` (`:697-713`). Greenfield uses 3
   dimensions (goal 0.40 / constraints 0.30 / success-criteria 0.30);
   brownfield adds context clarity and rebalances (0.35/0.25/0.25/0.15)
   (`:45-54`). The scoring prompt tolerates deliberate deferral: "Do NOT
   penalise the clarity score for intentionally deferred items" (`:509-511`).
2. **The gate** (`:201-248`): Seed generation is permitted only when
   `ambiguity ≤ 0.2` (`AMBIGUITY_THRESHOLD`, boundary inclusive) AND every
   required dimension meets its floor (goal 0.75 / constraint 0.65 /
   success-criteria 0.70 / brownfield-context 0.60,
   `qualifies_for_seed_completion`).
3. **The streak** (`mcp/tools/authoring_handlers.py:306-336`): auto-completion
   requires **2 consecutive qualifying rounds**
   (`AUTO_COMPLETE_STREAK_REQUIRED`); any non-qualifying signal (scorer error,
   weak re-score, non-qualifying answer) resets the streak to 0
   (`_reset_stale_completion_streak`).
4. **The anti-gaming floor** (`auto/grading.py:523-547`):
   `deterministic_floor(ledger) = 0.05·open + 0.10·conflicting +
   0.05·(assumption_only/total_required)`, clamped `[0,1]`; the pipeline takes
   `max(llm_reported_score, deterministic_floor)` so the LLM cannot
   under-report ambiguity below what code can objectively count.
5. **Degraded exit** (`auto/ledger_seed.py:315-335`): a timed-out/capped
   interview still produces a Seed, with `ambiguity_score` **inflated to
   ≥ 0.6** and `unresolved_slots` surfaced in metadata — a labeled partial
   product, never a dead end.
6. Interview rounds ask **one question at a time**, driven by ledger gaps; the
   `auto` variant runs up to 12 rounds with a synthetic answerer (it has no
   human; we do).

The orca OR2-5 rider contributes the per-question ledger row —
`{question, why_it_matters, risk_if_unanswered,
recommended_default_assumption, user_input_required, status, user_answer}`,
status ∈ `open | answered | assumed | conflicting` — and the readiness
vocabulary `ready_for_tasks | ready_with_assumptions |
blocked_needs_user_input`, with the explicit accept-assumptions gate
(unresolved `user_input_required` items block acceptance unless the operator
opts into the recommended defaults).

## Side-by-side shapes

| Ouroboros (source) | jido_radclaw (planned) | Divergence note |
| --- | --- | --- |
| `AMBIGUITY_THRESHOLD = 0.2`, floors 0.75/0.65/0.70/0.60, brownfield weights 0.35/0.25/0.25/0.15, greenfield 0.40/0.30/0.30, `SCORING_TEMPERATURE = 0.1`, streak 2 (`ambiguity.py:35-57`) | Module attrs on `JidoClaw.FrontDoor.Clarify.Score` with attribution comment; same values | Verbatim. Greenfield constants ported documented-but-unused (decision 3: brownfield-always). |
| `overall = round(1 − Σ clarity·weight, 4)` (`ambiguity.py:697-713`) | `Score.ambiguity/1` over the 4 clarity floats | Verbatim formula; clamping of each clarity to [0,1] happens in `Score` (their parse layer clamps, `test_parse_response_clamps_scores`). |
| `qualifies_for_seed_completion`: `score ≤ 0.2 AND all floors met` (`ambiguity.py:216-248`) | `Score.qualifies?/2` (threshold ∧ 4 floors) | Verbatim, boundary-inclusive (≤ / ≥). |
| Streak: 2 consecutive qualifying scores; any non-qualifying signal resets (`authoring_handlers.py:306-336`) | `Clarify.State` `streak` counter with the same reset rule; scorer failure counts as non-qualifying for the streak but keeps state | Verbatim rule. Round 2 of our streak is a **recap-confirm round** (restate updated intent + assumptions) rather than a fabricated question — divergence (c). |
| `deterministic_floor(ledger)` = 0.05·open + 0.10·conflicting + 0.05·(assumption/total), clamp [0,1]; `max(llm, floor)` (`grading.py:523-547`) | `Score.deterministic_floor/1` over `Ledger.counts/1`; `Score.effective_ambiguity/2 = max/2` | Formula verbatim; counted over **our ledger items** (open/conflicting/assumed statuses), not their required-sections ledger — divergence (b). |
| Interview: 1 question per round, `auto` cap 12 (synthetic answerer) | 1 question per round (the first open ledger item), round cap 12 (`:clarify_round_cap`) | Verbatim cadence + cap: every fold re-scores and re-orders the ledger, so each answer shapes the next question. |
| Degraded seed: `ambiguity_score = max(score, 0.6)` + `unresolved_slots` (`ledger_seed.py:315-335`) | Compose with premises `"degraded" => true` + `"unresolved_slots"`; the score is **reported honestly**, never inflated | Divergence (a): we have a first-class degraded label, so score inflation as a signal-carrier is unnecessary. |
| `generate_clarification_questions` — a parallel questions list derived from the breakdown (`ambiguity.py:715+`) | `next_questions` folded into the ledger — **open items ARE the questions** | Divergence (d): no parallel field to drift from the ledger. |
| Greenfield/brownfield mode switch per project | Brownfield 4-dim **always**; context clarity scored over the whole conversation evidence (user + assistant/worker turns); repo-discoverable gaps marked assumable, never blocking | Divergence (e), operator decision 3. |
| Convergence: backend claim ∧ structural ledger completeness; premature-closure invariant | Gate = score qualification + streak only; ledger `open_required?/1` drives hold-vs-degraded at cap | Simplified: our ledger has no section taxonomy; the accept-assumptions gate (OR2-5) covers the "backend says done but gaps remain" case. |
| `auto/answerer.py` synthetic answerer | None — the human answers; `:one_shot` surfaces skip rounds and compose degraded | Dropped (we have a human; unattended surfaces never park questions — decision 5). |

## Behaviors table

**Preserved exactly**

| Behavior | Source | Reason |
| --- | --- | --- |
| `ambiguity = 1 − Σ(clarity × weight)` | `ambiguity.py:697-713` | The core metric; fidelity is the point. |
| Pass gate `≤ 0.2` AND all four floors, boundaries inclusive | `ambiguity.py:201-248` | One strong dimension must not mask a weak one. |
| 2-consecutive-qualifying-rounds streak; any non-qualifying score resets it | `authoring_handlers.py:306-336` | One lucky score must not compose a build. |
| `deterministic_floor` coefficients (0.05/0.10/0.05) + clamp + `max(llm, floor)` | `grading.py:523-547` | The anti-self-grading floor is the sharpest piece of the port. |
| Scoring temperature 0.1 | `ambiguity.py:56-57` | Reproducible scoring. |
| Deferral tolerance clause in the scorer prompt | `ambiguity.py:509-511` | Deliberate deferrals are not ambiguity. |
| Brownfield weight set + all four floors | `ambiguity.py:39-54` | Verbatim constants, pinned by tests. |
| One question per round; round cap 12 | interview cadence + the `auto` round cap (`interview_driver.py`) | Sequential asks let every answer re-fold the ledger and shape the next question; denser rounds would forfeit exactly that. |
| Degraded exit is a labeled product, never a dead end | `ledger_seed.py:315-335` | The partial-product posture. |

**Deliberately changed**

| Behavior | Source → ours | Reason |
| --- | --- | --- |
| (a) Degraded score inflated to ≥ 0.6 → honest score + `"degraded" => true` + `"unresolved_slots"` premises | `ledger_seed.py:324` | We have a first-class degraded label; inflating a measurement to smuggle a flag is the kind of conflation TRUST-BOUNDARIES exists to prevent. |
| (b) Floor counts required-sections ledger → counts our OR2-5 ledger items | `grading.py:523-547` | We have no section taxonomy; open/conflicting/assumed item statuses are the direct analogue. |
| (c) Streak round 2 asks another question → recap-confirm round (restate updated intent + assumptions) | `authoring_handlers.py` | With a qualifying score there is no honest question left; fabricating one to satisfy the streak would be gaming our own gate. |
| (d) `next_questions` separate from the ledger → open ledger items ARE the questions | `ambiguity.py:715+` | No parallel field to drift. |
| (e) Greenfield/brownfield switch → brownfield-always; repo-discoverable gaps assumable | mode flag | Operator decision 3: this platform always operates on an existing repo + conversation evidence. |
| Cap semantics: auto-completes at cap → hold-for-accept when `user_input_required` items remain open; degraded compose only when all open items are assumable | `auto` pipeline | Operator decision 2 + OR2-5's accept-assumptions gate: never auto-compose past a required unknown. |

**Dropped**

| Behavior | Source | Reason |
| --- | --- | --- |
| Synthetic answerer | `auto/answerer.py` | We have a human; `:one_shot` surfaces compose degraded instead. |
| Adaptive token-doubling retry on truncation | `ambiguity.py:366-478` | Our scorer rides `json_repair: true` + the infra-lane failure handling; one bounded call per round. |
| Section-taxonomy ledger + premature-closure invariant | `auto/ledger.py:448`, `interview_driver.py:751-797` | Replaced by the OR2-5 item statuses + hold-for-accept. |
| Seed generation itself | `bigbang/` | Our compose path is the composer launch; answers fold into premises/seed artifact. |
| "Perspective Panel" prompt trick | `interview.py:946` | Single-model prompt theater; adds nothing over the rubric. |

## Edge cases (anchored to source tests)

| Ouroboros test | Our planned equivalent | Expected behavior (both sides) |
| --- | --- | --- |
| `test_is_ready_for_seed_at_threshold` | `ScoreTest`: gate boundary at exactly 0.2 | 0.2 passes (≤, inclusive); 0.2001 fails. |
| `test_component_score_clamps_score` / `test_parse_response_clamps_scores` | `ScoreTest`: clarity clamp | Out-of-range clarity from the LLM clamps to [0,1], never propagates raw. |
| `test_calculate_overall_perfectly_clear` / `_completely_ambiguous` / `_mixed_scores` | `ScoreTest`: formula at all-1.0 / all-0.0 / mixed | all-1.0 ⇒ 0.0; all-0.0 ⇒ 1.0; mixed matches Σ by hand. |
| `test_score_parse_error_after_retries` (their retry exhaust) | `ScorerTest`: malformed object (non-map, junk `clarity`, junk `ledger`) ⇒ `{:error, :malformed_object}`; a result whose ledger, normalized, would WIPE a non-empty prior ledger ⇒ `{:error, :ledger_wiped}` (`new_ask` exempt — the pivot path discards the ledger by design); never raises; mid-loop ⇒ state kept + bounded failure ack (infra ≠ verdict) | Their pipeline errors the round; ours keeps state — the accumulated ledger included — and never reads failure as clarified. |
| `test_score_uses_reproducible_temperature` | `ScorerTest`: knob forwarding (temp 0.1) | Temperature pinned at 0.1 on every scorer call. |
| `test_ambiguity_score_elevated_for_degraded_seed` (`test_ledger_seed.py:234`) | Integration: degraded compose carries `"degraded" => true` + `"unresolved_slots"` premises | Same information, different carrier — divergence (a). |
| `test_complete_ledger_marks_seed_non_degraded` | Integration: clean compose (streak 2, no open items) carries no degraded keys, drops `:ambiguous` from seeded topics | A clean pass is plain green. |
| Streak reset on non-qualifying signal (`_reset_stale_completion_streak` callers) | `StateTest` + integration: qualifying → non-qualifying → qualifying needs 2 more rounds | A stored streak survives only qualifying signals. |
| (no source analogue — this plan's review findings) | Open-turn persist failure ⇒ fail open to standard composer; launch failure keeps pending state (re-send retries compose); redaction at lane entry on all three paths with sticky sensitive OR into `mark_sensitive`; clear `pending_clarify` only after `{:ok, parent}`; oscillation marker cleared on clarified compose; a live pending on a `:one_shot` turn is cleared, never continued (main cron reuses its session) | New, house-specific trust-boundary behaviors — recorded here so the reviewer sees they are additions, not source semantics. |
| (no source analogue — the 2026-07-08 remediation review) | The deterministic override is **strict-affirmative**: the contiguous token run "proceed with defaults" AND every remaining token from a small affirmative allowlist — negations, mixed content, and novel phrasings fall through to the scorer, which can still classify `override` with full context (a false decline costs one scorer round; a false fire composes against the user's intent). A non-qualifying score with **zero open ledger items** is infra (`:no_open_questions`): open/one-shot fail open to the standard composer, continue rides the bounded failure ack WITHOUT folding (the accumulated ledger and failure escalation are preserved) — never a question-less round. Continue-turn folds **merge-preserve**: the result ledger wins by normalized question key, and prior items the scorer dropped are re-appended BEFORE the pass gate and the fold read the ledger — a partial drop can neither lose accumulated Q/A nor lower the deterministic floor (a full wipe stays `:ledger_wiped` infra). Belt-and-braces: the question-round formatter falls back to the recap when no open item exists. | New, house-specific fail-closed guards — additions, not source semantics. |

## Sign-off gate

The five operator decisions were ratified in the 2026-07-07 interview and are
recorded in the implementation plan (trigger scope `ambiguous ∧ code|system`;
hold-for-accept cap semantics; brownfield-4-dim always with
conversation-evidence context scoring; explicit per-call-site
`clarify: :loop | :one_shot` surface capability with kind-derived fallback;
one-shot degraded-compose that never continues a live pending state).
Divergences (a)–(e) above are deliberate and each carries its reason.
Sign-off: the 2026-07-07 revision of this block claimed explicit sign-off,
but that conflated sign-off with implementation-plan approval — no separate
sign-off act happened (2026-07-08 review finding). Explicit sign-off on this
amended map: granted by the operator 2026-07-08 (on review of the amendment
diff, incl. the `new_ask` wipe-guard exemption); further amended the same day
with the fold-time merge-preservation guard (partial ledger drops), sign-off
granted 2026-07-08 with the fix-approach decision (merge-preserve over
reject-as-infra). Code follows this map. After shipping,
`docs/system/ambiguity-clarify.md` cites this map as port provenance.
