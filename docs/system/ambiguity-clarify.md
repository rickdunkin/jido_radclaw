---
type: subsystem
description: The bounded clarify loop — score → ask → fold → re-score before composing an ambiguous build; degraded labeling when it can't.
sources:
  - lib/jido_claw/front_door/clarify.ex
  - lib/jido_claw/front_door/clarify/score.ex
  - lib/jido_claw/front_door/clarify/ledger.ex
  - lib/jido_claw/front_door/clarify/state.ex
  - lib/jido_claw/front_door/clarify/formatter.ex
  - lib/jido_claw/front_door/clarify/scorer.ex
  - lib/jido_claw/front_door.ex
  - lib/jido_claw/triage/verdict.ex
  - lib/jido_claw/conversations/resources/session.ex
  - lib/jido_claw.ex
  - lib/jido_claw/cli/run_command.ex
  - docs/exploration/ouroboros/PORT-OB1-1.md
verified: 2026-07-10
---

# Ambiguity Clarify Loop

## What & why

The platform's most expensive failure mode is composing a significant build on a
misread ask. Triage's `ambiguous` early signal was fully wired for detection and
consumed by nothing; this subsystem (queue item 8 — ouroboros OB1-1 with the orca
OR2-5 ledger/readiness rider) adds the response. When triage flags an ambiguous
`code`/`system` ask on an attended surface, the front door enters a bounded
conversation-axis loop — score the ask's clarity, ask one question at a time,
fold the answers, re-score — instead of composing, and then composes with the answers
folded into premises. When it can't (operator override, round cap, unattended
surface), it composes anyway with an honest `degraded: true` +
`unresolved_slots` labeling — a labeled partial product, never a dead end and
never a silent guess. Scoring semantics are ported verbatim from
`Q00/ouroboros @ e905a41c` (MIT); the PORT map with all deliberate divergences
is `docs/exploration/ouroboros/PORT-OB1-1.md`.

## Invariants & contracts

- **Trigger** (OQ-4, signal-gated): `:ambiguous in signals ∧ path in
  [:code, :system]`. Sketch is never gated — it is the clarify-by-doing lane.
  No size gate in v1.
- **Pass gate** (ported): effective ambiguity ≤ 0.2 (inclusive) AND every
  dimension clarity ≥ its floor (goal 0.75 / constraints 0.65 /
  success-criteria 0.70 / context 0.60) AND **2 consecutive qualifying
  rounds**; any non-qualifying signal (weak score, scorer failure) resets the
  streak.
- **Anti-gaming floor** (ported): effective ambiguity =
  `max(llm_score, 0.05·open + 0.10·conflicting + 0.05·(assumed/total))` — the
  LLM cannot under-report ambiguity below what code can count. Both LLM
  channels (its per-dimension clarities via the formula, and its own overall
  number) are max'd too.
- **Hold-for-accept at the cap**: at the round cap, unresolved
  `user_input_required: true` items HOLD for the explicit "proceed with
  defaults" ack — never auto-compose past a required unknown. Only-assumable
  items auto-compose degraded. `user_input_required` coerces **fail-closed**:
  only a literal `false` is assumable.
- **Infra ≠ verdict**: a scorer failure never reads as clarified — state is
  kept, the user gets a bounded ack (override-only from the 2nd consecutive
  failure), and the deterministic override phrase works with the scorer down.
  Failure includes contract violations, not just transport: a malformed
  object (`:malformed_object`), a result whose ledger, normalized, would
  wipe a non-empty prior ledger (`:ledger_wiped` — `new_ask` exempt, the
  pivot path discards the ledger by design), and a non-qualifying result
  with zero open items (`:no_open_questions`) all ride the infra lanes.
  Open/one-shot fail open to the standard composer; continue serves the
  failure ack WITHOUT folding, so the accumulated ledger and the
  consecutive-failure escalation survive. Never a question-less round.
- **Functional state is result-checked**: `pending_clarify` writes never ride
  `safe_write/1`. An open-turn persist failure fails OPEN to the standard
  composer (never show questions the next turn can't correlate); a
  continue-turn persist failure still serves the round (stale state
  self-heals via re-fold), loudly.
- **Compose ordering**: `start_composer` first; `pending_clarify` is cleared
  only on `{:ok, parent}` (the `consume_candidate` precedent). A launch
  failure keeps the loop live so the re-send retries the compose. Cleanup
  failures never prevent `after_launch/4`.
- **Redaction at lane entry**: every incoming message (open, continue, AND
  one-shot) passes `redact_with_count/1` before scoring and before any
  persist; scorer history is redacted at the scorer boundary too. A nonzero
  count sets a sticky `sensitive` bit that ORs into `mark_sensitive/2` at
  compose — answers can introduce secrets after triage's `:secrets` signal
  was decided.
- **Honest signals**: `:ambiguous` drops from the composed verdict's signals
  on a clean compose (resolved) and stays on a degraded one. Catalog and
  `mapped_signals/1` untouched.
- **Surfaces are explicit**: `chat/4`'s `clarify: :loop | :one_shot` opt
  (kind-derived fallback: `:cron`/`:api` ⇒ `:one_shot`). A `:one_shot`
  surface composes immediately with degraded labeling and **never continues a
  live pending loop** — main cron reuses its session, and the next scheduled
  task must not read as an answer (a live pending on a one-shot turn is
  cleared, loudly).

## Mechanics

### Port provenance

`Q00/ouroboros @ e905a41c` (MIT, © 2025 Q00) → jido_radclaw @ `d4c7c197`+.
Constants (`Clarify.Score`): brownfield weights 0.35/0.25/0.25/0.15, floors
0.75/0.65/0.70/0.60, threshold 0.2, streak 2, scoring temperature 0.1, the
`1 − Σ(clarity·weight)` formula, and the deterministic floor coefficients —
all verbatim from `bigbang/ambiguity.py:35-57,697-713` and
`auto/grading.py:523-547`, pinned by `score_test.exs`. The interview cadence
is kept too: one question per round (every fold re-scores and re-orders the
ledger, so each answer shapes the next question), round cap 12 — the `auto`
pipeline's. Deliberate divergences (honest `degraded` premises vs their
score-inflation-to-0.6; our ledger statuses feeding the floor; the streak-1
recap-confirm round; questions folded into the ledger; brownfield-always) are
tabled in the PORT map. Greenfield 3-dim weights are ported
documented-but-unused (`Score.greenfield_weights/0`).

### The loop

`FrontDoor.decide/2` loads the session once, then checks
`Clarify.load_pending/2` BEFORE triage. A live pending state on a `:loop`
surface routes the turn to `Clarify.continue/5` — no triage call. Otherwise
(none / expired / one-shot-cleared) the turn runs today's
`triage_and_route/3`, whose composer branch forks: `Clarify.trigger?/1` ⇒ the
clarify lane, else the byte-identical `standard_composer/5`.

- **Open turn**: one scorer call over (redacted original, empty ledger,
  history). Qualifying first score ⇒ the recap-confirm round (streak 1 of 2 —
  no fabricated question); else a question round (the single most load-bearing
  open item — every fold re-orders what to ask next — with why-it-matters +
  recommended default, the round X/N header, the override instruction). State
  persists first; the ack only shows on `{:ok, _}`.
- **Continue turns**: the deterministic override check runs FIRST — it must
  work while the scorer is down. It is **strict-affirmative**: downcase +
  tokenize (punctuation splits), then require the contiguous token run
  "proceed with defaults" AND every remaining token from a small affirmative
  allowlist ("ok", "yes", "please", …). Anything else — negations ("do not
  proceed with defaults"), mixed content ("proceed with defaults but skip
  the tests"), novel phrasings — falls through to the scorer, which folds
  answers first and can still classify `override` with full context. Then
  one scorer call classifies `answers | override | new_ask`, folds answers
  into the ledger, and re-scores. The fold **merge-preserves**
  (`Ledger.merge_preserved/2`): the result ledger wins by normalized
  question key, and prior items the scorer dropped are re-appended BEFORE
  the pass gate and the fold read it — a partial drop can neither lose the
  accumulated Q/A nor lower the deterministic floor (a full wipe is
  `:ledger_wiped` infra at the scorer boundary). Routing: streak ≥ 2 ⇒ compose clean; qualifying streak 1 ⇒
  recap round; non-qualifying under cap ⇒ next question round; at cap ⇒ hold
  (required open) or degraded compose (only assumable). `new_ask` clears the
  loop and falls through to fresh triage — which may open a NEW loop for the
  new ask.
- **Override** composes clean only after a qualifying score (streak ≥ 1) with
  zero unresolved items; anything else carries the degraded labeling.
- **The premises lint gate** (item 9 — OB1-2, `PORT-OB1-2.md`): every
  `:loop` compose passes `Clarify.lint_gate/2` BEFORE launching —
  `Premises.Lint.run(premises, mode: :clarify, ledger:)` over the accumulated
  ledger. A **blocker** (exclusively the ledger-derived safety set:
  `high_risk_assumptions` over `assumed` items' defaults, `ledger_open_gap`
  for unresolved `user_input_required` items, the belt-and-braces
  `high_ambiguity_score`) below the round cap re-opens a clarify round
  instead of composing (`serve_round(:lint_block, …)`) — `high_risk` seeds an
  idempotent `user_input_required` confirm question
  (`Ledger.append_missing/2`, keyed on normalized question text). Degraded
  premises demote ALL blockers to findings (the hold-for-ack ack IS the
  human confirmation), at the cap #8's own hold/degraded semantics own the
  exit, and `:one_shot` skips the clarify-side lint entirely — so the gate
  can never loop forever or park an unattended surface. AC-quality findings
  never block anywhere; they ride the plan-gate payload via the `:gate`-mode
  re-lint. Full lint semantics → `docs/system/structured-premises.md`.
- **Compose enrichment**: intent = scorer `updated_intent` (fallback: stored
  verdict intent, then the original ask); the request-seed artifact is the
  original message + the full redacted Q/A transcript; premises gain
  `"clarifications"` (a pre-rendered digest ≤ 560B — `PremisesContext`
  inspect-renders non-binaries), `"ambiguity_score"` (float), `"readiness"`
  (`ready_for_tasks | ready_with_assumptions | blocked_needs_user_input`),
  the typed keys the scorer distilled (`"acceptance_criteria"` /
  `"evaluation_principles"` / `"exit_conditions"` — non-empty lists only,
  item 9), plus `"degraded" => true` and non-empty `"unresolved_slots"` on
  the degraded path. Clarify premises merge LAST in `build_premises/5`, and
  the whole merged map exits through `Premises.normalize/1` (fail-open typed
  key validation).
- **Graduation composes**: `pending_prototype` relevance is re-derived at
  compose time from the CLARIFIED intent, never the confirm-turn message
  ("yes, that's right" has no topic tokens). A clarified compose bypasses the
  oscillation guard by design but explicitly clears the
  `oscillation_prompted_at` marker (the guard's proceed path is where it
  normally clears), so a stale marker can't suppress a later real debounce.

### State & persistence

`Clarify.State` persists as a string-keyed wire map under
`metadata["pending_clarify"]` via the Session's atomic-`jsonb_set`
`:set_pending_clarify` action (nil deletes — the lazy clears). The verdict
crosses the boundary through `Verdict.to_map/1` / `from_map/1` — wire strings
via inverse whitelists, never `to_string/1` (which would silently drop
hyphenated signals like `significant-build` on reload). Keys:
`original_message`, `verdict`, `ledger` (OR2-5 items: question /
why_it_matters / risk_if_unanswered / recommended_default_assumption /
user_input_required / status ∈ `open|answered|assumed|conflicting` /
user_answer), `clarity` (4 floats), `llm_ambiguity`, `updated_intent`, the
typed premises lists (`acceptance_criteria` / `evaluation_principles` /
`exit_conditions` — item 9; the fold keeps the prior round's list when a
later scorer result omits one, the `updated_intent` rule), `rounds_shown`,
`streak`, `scorer_failures`, `sensitive`, `created_at`/`updated_at`
(ISO8601). TTL (default 1h) runs off last activity; expired or junk state
lazily clears into normal triage. The real-JSONB round trip is pinned in
`session_test.exs`.

### The scorer

`Clarify.Scorer` mirrors `Triage.LLM`: one tool-less
`Jido.AI.generate_object/3` (`json_repair: true` unwrap), never raises. The
unwrapped object is validated BEFORE normalization: a non-map, junk
`clarity`, or junk `ledger` is `{:error, :malformed_object}`, and a result
whose ledger, normalized, would wipe a non-empty prior ledger is
`{:error, :ledger_wiped}` (`new_ask` exempt) — never a fabricated all-zero
"success" the loop would serve as an unanswerable round. The
prompt carries the verbatim ouroboros brownfield rubric + deferral clause,
the classification and ledger contracts (incl. most-load-bearing-first
ordering — the first open item is the next question asked — repo-discoverable
⇒ assumable, and the never-ask-for-secret-VALUES rule), and frames everything —
original ask, latest message, serialized prior ledger, redacted history —
inside one UNTRUSTED-EVIDENCE BEGIN/END block. The original message and prior
ledger ride explicitly, so the 6-turn history window can never clip the ask.

### Surfaces & exit contract

In-repo routed call sites set `clarify:` explicitly: cron `dispatcher` (both
arms — main cron's session is stable but unattended) ⇒ `:one_shot`;
`rpc_channel`, `discord`, `run_command`, and the REPL ⇒ `:loop`. Bare
`chat/4` calls with `kind: :api` also derive `:one_shot`. The OpenAI-compatible
`chat_controller` now selects the separate zero-tool stateless-completion path,
which bypasses triage/clarify/composer entirely so a request cannot launch work
whose ephemeral scope it immediately tears down. Routed `chat/4` returns clarify
acks as plain `{:ok, binary}` by default; `composer_ack: :detailed` yields
`%{route: :clarify, status: :pending, run_id: nil, message: msg}`. The
one-shot CLI runner maps that to **exit 3, outcome `:clarify_pending`** (the
OQ-4 human-input family); the printed session id is what `--session` needs to
answer the questions.

## Config & telemetry

- `config :jido_claw, :clarify_model, :capable` — direct model spec
  (`:triage_model` semantics); `:capable` because the trigger is rare and the
  ledger quality is the product.
- `config :jido_claw, :clarify_round_cap, 12` — question rounds (one question
  each) before hold/degraded; the source `auto` pipeline's cap.
- `config :jido_claw, :clarify_ttl_ms, 3_600_000` — pending-state expiry off
  last activity.
- `:clarify_generate` — the test-only generate seam (mirrors
  `:triage_generate`). App-env only in v1; a `.jido/config.yaml` section is
  demand-gated.
- Counter `jido_claw.clarify.total`, tags `[:event, :outcome]` — events
  `:open/:round/:hold/:compose/:scorer_failed/:persist_failed/:new_ask/
  :expired/:one_shot_cleared/:lint_block` (item 9's blocker re-open rides
  `serve_round`); compose outcomes
  `:clean/:degraded/:override/:one_shot_degraded/:launch_failed`. The
  `:open` event's failure outcomes distinguish `:empty_ledger` (the
  `:no_open_questions` contract violation, on both the loop-open and
  one-shot lanes) from `:scorer_failed` (every other scorer failure). Every
  emit also rides a `Trace` `:guardrail` event (`guardrail: "clarify"`) and
  a `jido_claw.triage.clarify` SignalBus signal (the `emit_oscillation/2`
  precedent). The lint itself counts on
  `jido_claw.premises_lint.total` (tags `[:grade, :mode]` — see
  `docs/system/structured-premises.md`).

## Residuals & accepted risks

- **Failed clear after a successful launch**: the run started but
  `pending_clarify` wouldn't delete — loud-logged, Trace'd
  (`:persist_failed`/`:clear_after_launch`), and TTL-bounded: the next turns
  read the stale loop until expiry. Accepted; the write is a single atomic
  `jsonb_set` delete, so the window is a DB-outage class.
- **Ledger-marking gaming**: the LLM resolves its own items (marks them
  answered/assumed), so the deterministic floor bounds but does not eliminate
  self-grading — the same residual ouroboros carries. The floor + the
  dimension floors + the streak are the mitigation.
- **Continue-turn persist failure serves on stale state**: deliberate — the
  next fold sees the un-persisted answer in history and re-folds. Trace'd via
  `:persist_failed`.
- **A rephrased question duplicates instead of replacing**: the fold's
  merge-preservation matches prior items by normalized question text; a
  scorer that rephrases a question (rather than echoing it) defeats the key
  match, so the merge keeps both the old and the new item. Accepted
  polarity: duplication is noise (a redundant entry, a slightly higher
  floor), loss is harm.
- **Novel affirmative phrasings cost one scorer round**: the deterministic
  override fires only on the exact phrase decorated by allowlisted
  affirmatives; an unlisted-but-affirmative wrapper ("go for it, proceed
  with defaults") falls to the scorer's `override` classification instead.
  With the scorer down, the escape valve therefore requires the advertised
  exact phrase — the failure ack spells it out. Deliberate fail-closed
  polarity: a false decline costs one scorer round, a false fire composes a
  run against the user's intent.
- **Scorer cost**: one `:capable` call per round, signal-gated per OQ-4. The
  `significant-build ∧ no-criteria` extra trigger stays evidence-gated
  (add only if misses show up).

## Source map

- `lib/jido_claw/front_door/clarify.ex` — the decision layer: trigger, load,
  open/continue/one-shot, compose specs
- `lib/jido_claw/front_door/clarify/score.ex` — ported constants + formulas
- `lib/jido_claw/front_door/clarify/ledger.ex` — OR2-5 item normalization +
  projections
- `lib/jido_claw/front_door/clarify/state.ex` — durable state, streak/failure
  transitions, TTL
- `lib/jido_claw/front_door/clarify/formatter.ex` — acks, override phrase,
  digest/transcript
- `lib/jido_claw/front_door/clarify/scorer.ex` — the LLM boundary (+ the
  item-9 typed premises fields)
- `lib/jido_claw/front_door.ex:119` — decide/2 routing, the clarify lane,
  compose_from_clarify (the item-9 lint gate), result-checked persistence
- `lib/jido_claw/triage/verdict.ex` — `to_map/1`, the pending-state wire form
- `lib/jido_claw/conversations/resources/session.ex` — `:set_pending_clarify`
- `lib/jido_claw.ex` — `clarify:` opt threading + `{:clarify, resp}` shaping
- `lib/jido_claw/cli/run_command.ex` — exit 3 / `:clarify_pending`
- `test/jido_claw/front_door_clarify_test.exs` — the integration surface
- `docs/exploration/ouroboros/PORT-OB1-1.md` — the port semantics map
