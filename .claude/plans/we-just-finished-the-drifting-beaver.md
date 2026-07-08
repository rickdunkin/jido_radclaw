# Plan: Clarify-loop review remediation (P1 override negation, P2 empty-ledger park, PORT sign-off)

## Context

The item-8 clarify loop (plan `please-review-docs-plans-unadopted-next-cuddly-dijkstra.md`,
uncommitted working tree) got a code review with two findings and one open question. I
verified both findings against the source first-hand — **both are real** — and the
operator confirmed the sign-off question (2026-07-08 interview): the PORT map sign-off
WAS conflated with plan approval, and explicit sign-off will be granted now on the
amended map. **Done means `mix precommit` passes** (exact exit code + counts reported;
rotating-flake policy per memory).

## Verified findings

**P1 — CONFIRMED.** `Formatter.override?/1` (`formatter.ex:31-37`) is downcase +
whitespace-collapse + `String.contains?("proceed with defaults")`, and `continue/5`
checks it BEFORE the scorer (`clarify.ex:142`) → `{:compose, override_spec(state)}`.
So **"do not proceed with defaults" composes a run against the user's explicit
refusal**. Adjacent gap, same mechanism: a mixed message ("proceed with defaults but
skip the tests") hard-overrides and silently drops the extra content — only the
scorer path folds-then-overrides (`clarify.ex:185-186`).

**P2 — CONFIRMED.** `Scorer.normalize/1` (`scorer.ex:275-300`) is total over junk:
an empty/partial map or non-map unwraps to a `{:ok, ...}` "success" with all-zero
clarity (ambiguity 1.0, non-qualifying) and `ledger: []` — **pinned by
`scorer_test.exs:94`**, directly contradicting `PORT-OB1-1.md:114` ("malformed
object ⇒ `{:error, _}`"). Downstream, `open/4` (`clarify.ex:119`) and
`route_folded/4` (`clarify.ex:210-212`) serve a question round whose
`question_block([])` renders **"(none)"** (`formatter.ex:144`) — an unanswerable
round the user can be parked in until the cap of 12 (exit 3 per round on the
one-shot CLI). Bonus hazard found while verifying: `State.fold_score/4` REPLACES the
ledger with the result's (`state.ex:81`), so a mid-loop empty-ledger result **wipes
the accumulated Q/A** (digest/transcript/premises lost at compose).

**Open question — RESOLVED by operator.** No separate explicit sign-off happened;
`PORT-OB1-1.md:130`'s claim is inaccurate. Operator chose: amend the map in this fix,
correct line 130, and grant explicit sign-off on the amended map (AGENTS.md was
already updated by the operator to make plan-approval-≠-sign-off explicit).

## Fix design

### P1 — strict-affirmative deterministic override (fail-closed polarity)

Rewrite `override?/1`: normalize (downcase, strip punctuation → spaces via
`~r/[^a-z0-9']+/u`, tokenize), then require BOTH:

1. the contiguous token run `["proceed", "with", "defaults"]`
   (`Enum.chunk_every(tokens, 3, 1, :discard)` membership), and
2. every remaining token ∈ a small affirmative allowlist (module attr), starter:
   `~w(ok okay yes yeah yep sure fine alright great good sounds please thanks thank
   you go ahead now just anyway and do it that's thats right lets let's)`.

**Any unknown token — negations, mixed content, novel phrasing — falls through to
the scorer**, which folds answers first and can still classify `:override` with full
context. This is the repo's unknown-⇒-gated polarity: a false decline costs one
scorer call; a false fire launches a run against user intent. Scorer-down worst case:
the failure ack already advertises the exact phrase (`scorer_failure_ack`), so the
escape valve stays deterministic. Existing pinned affirmatives keep passing
("  Proceed   WITH defaults, please", "ok — proceed\nwith defaults"); curly-quote
"don't" degrades safely (token "t" not allowlisted → scorer).

Prompt hardening (`scorer.ex` `@system` classification section): a negated or
conditional form ("do not proceed with defaults") is NEVER `"override"` — classify
as `"answers"`.

Sweep stale restatements of the substring semantics (`rg` for substring/contains
claims): `formatter.ex:25-29` docstring, `docs/system/ambiguity-clarify.md:119`.

### P2 — malformed scorer output is infra, never a "(none)" round

**Scorer layer** (`scorer.ex` — makes `PORT-OB1-1.md:114` true): after
`unwrap_object`, validate before normalizing; thread `args[:ledger]` in:

- not a map, or `object["clarity"]` not a map, or `object["ledger"]` not a list ⇒
  `{:error, :malformed_object}`
- prior ledger non-empty AND result ledger empty **after `Ledger.normalize/1`** ⇒
  `{:error, :ledger_wiped}` (the fold-wipe guard — "maintain the full ledger" is the
  scorer's own contract). Post-normalization matters: a non-empty raw list whose
  items all lack `question` normalizes to `[]` and must still trip the guard.

Both ride the existing infra lanes: open ⇒ fail open to standard composer; continue
⇒ `{:failure, ...}` state-kept ack. Rewrite `scorer_test.exs:94` (currently pins the
opposite) red→green.

**Decision layer** (`clarify.ex` — a non-qualifying score with zero open items never
becomes a question round; the scorer prompt gains: if your scores don't qualify, the
ledger MUST contain ≥1 open item naming the blocking gap):

- `open/4` AND `score_once_for_slots/4` (one-shot): result non-qualifying AND
  `Ledger.open_items(result.ledger) == []` ⇒ `{:error, :no_open_questions}` →
  existing fail-open to standard composer on both lanes. One-shot gets the guard
  too because the alternative compose is semantically incoherent — `degraded: true`
  + `readiness: "ready_for_tasks"` + no `unresolved_slots` from the same
  scorer-failure class (review follow-up, 2026-07-08). `open_clarify` AND
  `one_shot_clarify` (front_door.ex:255-258, :270-277) pattern-match that reason to
  emit telemetry outcome `:empty_ledger` (others stay `:scorer_failed`).
- `continue_scored/5` fold branch: same condition ⇒ infra **without folding**
  (`failed = State.record_failure(state, now)` + `scorer_failure_ack`), preserving
  the accumulated ledger and the consecutive-failure escalation (folding first would
  zero `scorer_failures` and wipe the ledger). The `:override`-classified branch
  needs no guard (explicit override composes degraded honestly; wipe guard covers
  the destructive case).

**Formatter belt-and-braces** (`formatter.ex`): `questions/3` matches
`Ledger.open_items |> Enum.take(1)` — `[]` falls back to `recap(state)` (actionable,
never "(none)"); delete the now-dead `question_block([])` clause (`numbered([])`
stays — `hold/1` is guarded by `open_required?` one line above its only call site).

### Sign-off + docs

- `docs/exploration/ouroboros/PORT-OB1-1.md`: update the `:114` edge row to the now-true
  contract (`:malformed_object` / `:ledger_wiped` ⇒ infra lanes); extend the
  house-specific behaviors row (`:119`) with the three new guards (strict-affirmative
  override; non-qualifying+empty-open ⇒ infra; question-round recap fallback);
  correct the Sign-off block (`:130`): the 2026-07-07 line conflated sign-off with
  plan approval — explicit sign-off granted 2026-07-08 on this amended map.
- **Blocking gate**: after amending the map (before the code steps land as final),
  present the amended map diff to the operator and collect the explicit sign-off
  reply — the literal act AGENTS.md now requires.
- `docs/system/ambiguity-clarify.md`: override mechanics (strict shape + fallback to
  scorer), the new infra lanes, telemetry outcome `:empty_ledger`, residual note
  (novel affirmative phrasings need the scorer; scorer-down requires the advertised
  exact phrase), bump `verified:`. AGENTS.md bullet needs no edit (its claims are
  unchanged); `mix jidoclaw.system_docs.check` enforces the pairing.

## Implementation steps

1. **Amend PORT map** (rows + sign-off correction) → present diff → **operator's
   explicit sign-off on the map** (blocking).
2. **P1 red→green**: formatter override matrix tests (negations "do not/don't/never
   proceed with defaults" AND the shortest natural form "no, proceed with defaults";
   mixed "proceed with defaults but skip the tests" refute; existing affirmatives +
   new "yes please proceed with defaults!" assert) → rewrite `override?/1` → scorer
   prompt line.
3. **P2 scorer red→green**: rewrite `scorer_test.exs:94` to `{:error,
   :malformed_object}`; add non-map object, clarity-junk, ledger-junk, raw-`[]`
   `:ledger_wiped`, normalizes-to-empty `:ledger_wiped` (prior non-empty + result
   items all lacking `question`), and empty-prior+empty-result-passes cases →
   `validate/2` step (ledger check post-`Ledger.normalize/1`).
4. **P2 decision layer red→green**: `open/4` + `score_once_for_slots/4` +
   `continue_scored/5` guards; `questions/3` recap fallback (unit test refutes
   "(none)"); front_door `:empty_ledger` telemetry matches (open + one-shot).
5. **Integration tests** (`front_door_clarify_test.exs`, existing arming pattern):
   (a) negated override with scorer up ⇒ question round, no run; with scorer down ⇒
   failure ack, no run; (b) open turn non-qualifying empty-ledger ⇒ standard
   composer, no pending persisted, `:empty_ledger` telemetry; (c) continue turn
   non-qualifying empty-open result ⇒ failure ack, prior ledger PRESERVED in
   reloaded pending, failures escalate to override-only, deterministic override then
   composes degraded with the ORIGINAL ledger's `unresolved_slots`; (d) one-shot
   surface + non-qualifying empty-ledger ⇒ standard composer (no clarify premises,
   no incoherent degraded-empty compose), `:empty_ledger` telemetry.
6. **Docs** (system page + verified bump) and the substring-claim sweep.
7. **Gate**: `mix precommit` — full, unpiped; report exact exit code + test counts
   verbatim. One unrelated rotating-flake timing test ⇒ single re-run per memory.
8. Record the sign-off-conflation lesson in auto-memory (feedback type).

## Files touched

- `lib/jido_claw/front_door/clarify/formatter.ex` — override rewrite, questions
  fallback, docstrings
- `lib/jido_claw/front_door/clarify/scorer.ex` — validate step, prompt lines
- `lib/jido_claw/front_door/clarify.ex` — open/continue empty-ledger guards
- `lib/jido_claw/front_door.ex` — `:empty_ledger` telemetry outcome (small match)
- `test/jido_claw/front_door/clarify/{formatter,scorer}_test.exs`,
  `test/jido_claw/front_door_clarify_test.exs`
- `docs/exploration/ouroboros/PORT-OB1-1.md`, `docs/system/ambiguity-clarify.md`

## Verification

1. Each new/changed test shown red against current code, then green (memory rule).
2. Targeted: `mix test test/jido_claw/front_door/clarify test/jido_claw/front_door_clarify_test.exs`.
3. `mix precommit` — full gate green; exact exit code + counts reported verbatim.

## Risks / notes

- Allowlist strictness is deliberate (fail-closed): unlisted-but-affirmative
  phrasings cost one scorer round; documented as a residual on the system page.
- `numbered([])`'s "(none)" remains as an unreachable defensive branch for `hold/1`
  (guarded by `open_required?` at its only call site) — noted, not load-bearing.
- Ledger-marking gaming residual from the original plan is unchanged by this fix.

## Deviations

(recorded here as they happen, per AGENTS.md)

- **`new_ask` exempt from the `:ledger_wiped` guard** (forced correction,
  surfaced in the 2026-07-08 sign-off interview and ratified with the map).
  The plan assumed the wipe guard applies to every scorer result whose
  normalized ledger is empty against a non-empty prior. The code revealed a
  branch the plan didn't examine: a `new_ask` classification discards the
  ledger by design (`continue_scored` clears state and re-triages), so an
  empty ledger there destroys nothing — and refusing it turns a valid pivot
  into a `:ledger_wiped` infra failure the user can't escape (temp 0.1 makes
  a re-send repeat it; the override valve would compose the OLD ask they
  pivoted away from). Chosen: the wipe check skips
  `classification ∈ [:new_ask, "new_ask"]`; pinned by a scorer test. No new
  hole: a misclassified `new_ask` clears the loop regardless of ledger
  content, guard or no guard.
- **Partial-drop preservation added post-gate** (reviewer follow-up,
  2026-07-08 — new scope the plan didn't cover). The plan's wipe guard only
  caught the empty-after-normalize case; a NON-empty replacement ledger
  still passed validation and `State.fold_score/4` replaced the prior ledger
  wholesale, so a result carrying one new item silently dropped earlier
  answered/open items — and, second-order, dropping open items lowered the
  deterministic floor (a gaming vector). Options surfaced per the interview
  rule (merge-preserve vs reject-as-infra); operator chose merge-preserve
  and granted sign-off on the matching PORT-map row amendment. Implemented
  as `Ledger.merge_preserved/2` applied in `Clarify.continue_scored/5`
  BEFORE the gate + fold (both read the merged ledger); full-wipe stays
  `:ledger_wiped` infra. Residual: a rephrased question duplicates instead
  of replacing (documented on the system page).
