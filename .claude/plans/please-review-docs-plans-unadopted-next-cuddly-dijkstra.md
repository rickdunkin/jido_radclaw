# Plan: Item 8 — Ambiguity clarify loop (ouroboros OB1-1 + orca OR2-5 rider)

## Context

Triage's `ambiguous` early signal is fully wired for detection and consumed by nothing:
defined (`lib/jido_claw/triage/prompt.ex:53`), enum'd (`triage/schema.ex:26`),
normalized (`triage/verdict.ex:50`), mapped (`front_door.ex:95`), published
(`route_composer/catalog.ex:88`) — no subscriber, no reader. The platform's most
expensive failure mode is composing a significant build on a misread ask; this item adds
the missing response: when triage flags an ambiguous `code`/`system` ask, the front door
enters a bounded conversation-axis clarify loop (score → ask one question at a time →
fold answers → re-score) instead of composing, then composes with the answers folded into premises —
or with an honest `degraded: true` + `unresolved_slots` labeling when the operator
overrides or the loop caps out. Detection already ships; only the response is missing
(queue doc `docs/plans/unadopted-next-ten/README.md:807-845`).

Scoring semantics are ported **verbatim** from ouroboros (attribution:
`Q00/ouroboros @ e905a41c, MIT` — source verified at
`~/workspace/research/ouroboros`, HEAD == pin). The per-question ledger shape and
readiness vocabulary come from the orca OR2-5 rider. **Done means `mix precommit`
passes.** Greenfield: no data/path compatibility concerns. Nothing gets committed.

## Ratified decisions (operator interview 2026-07-07 + review findings fold-in)

1. **Trigger scope**: `:ambiguous in verdict.signals and verdict.path in [:code, :system]`.
   Sketch is never gated (it's the clarify-by-doing lane). Signal-gated start (OQ-4) —
   no size gate in v1.
2. **Cap semantics — hold-for-accept**: at round cap, stop generating new question
   rounds. Unresolved `user_input_required: true` items ⇒ HOLD with an explicit
   accept-assumptions ack ("say 'proceed with defaults' to compose anyway") — never
   auto-compose past a required unknown. Cap with only assumable items open ⇒
   auto-compose degraded.
3. **Dimensions — brownfield 4-dim always** (goal 0.35 / constraints 0.25 /
   success-criteria 0.25 / context 0.15; floors 0.75/0.65/0.70/0.60). **Context clarity
   is scored over the whole conversation evidence** — user turns AND assistant/
   worker-produced content; repo-discoverable gaps are marked assumable
   (`user_input_required: false`, default like "discoverable from repo"), never blocking
   questions. Greenfield 3-dim constants ported as documented-but-unused.
4. **Surface capability — explicit, not kind-only** (review finding): `JidoClaw.chat/4`
   gains a `clarify: :loop | :one_shot` opt threaded into `front_door_ctx` as
   `clarify_surface`. In-repo call sites set it explicitly: OpenAI-compat
   `chat_controller.ex` ⇒ `:one_shot` (mints `api_#{unique_integer}` per call —
   verified `:49,:79`), cron `dispatcher.ex` ⇒ `:one_shot` (both arms — note the
   corrected premise: isolated cron mints a fresh session per tick, but **main cron
   reuses `state.agent_id`**, `dispatcher.ex:62-63`, so its session IS stable and must
   still never loop), `web_rpc` / discord / REPL / `run_command` ⇒ `:loop`. Absent opt
   ⇒ kind-derived fallback (`:cron`/`:api` ⇒ `:one_shot`, else `:loop`) so bare
   `chat/3` programmatic callers (default `kind: :api`, `jido_claw.ex:61`) never park
   questions; a stable external client opts into `:loop` explicitly. Documented in
   `chat/4`'s opts doc.
5. **Unattended (`:one_shot`) behavior — degraded-compose**: skip question rounds,
   compose immediately with `degraded: true` + `unresolved_slots` (one scorer call for
   slots/score; scorer failure ⇒ compose as today). **A live `pending_clarify` on a
   `:one_shot` turn is never continued** — it is cleared (loud Trace) and the message
   flows through normal triage (review finding: main cron's stable session must not
   treat the next scheduled task as an answer). `nil` session (unloadable) ⇒ fail open
   to today's composer path.

## Ported semantics (the PORT-map payload)

- Ambiguity = `1 − Σ(clarity_i × weight_i)`; **pass gate** = ambiguity ≤ 0.2 AND every
  dimension clarity ≥ its floor AND 2 consecutive qualifying rounds (streak; any
  non-qualifying score resets it). Source: `bigbang/ambiguity.py:34-57,201-248,697-713`,
  streak `mcp/tools/authoring_handlers.py:306-336`.
- **Deterministic anti-gaming floor**: `0.05·open + 0.10·conflicting +
  0.05·(assumed/total)`, clamped [0,1]; effective ambiguity = `max(llm_score, floor)`
  (`auto/grading.py:523-547`). Scoring temperature 0.1. Deferral tolerance clause ported
  ("do NOT penalise intentionally deferred items", `ambiguity.py:509-511`).
- **Interview cadence kept**: one question per round — every fold re-scores and
  re-orders the ledger, so each answer shapes the next question — with round cap 12,
  the `auto` pipeline's cap.
- **Deliberate divergences** (recorded in the PORT map's behaviors table):
  (a) degraded compose surfaces `"degraded" => true` premises instead of inflating the
  score to ≥ 0.6 (`ledger_seed.py:324`); (b) floor counts our ledger items, not their
  required-sections ledger; (c) streak round 2 is a recap-confirm round (restate updated
  intent + assumptions) rather than a fabricated question; (d) `next_questions` folded
  into the ledger — open items ARE the questions (no parallel field to drift);
  (e) brownfield-always per operator decision.
- **Ledger item (orca OR2-5)**: `{question, why_it_matters, risk_if_unanswered,
  recommended_default_assumption, user_input_required, status, user_answer}`, status ∈
  `open | answered | assumed | conflicting` (string enums). Readiness vocab:
  `ready_for_tasks | ready_with_assumptions | blocked_needs_user_input`.

## Loop mechanics (behavioral spec)

- **Open turn** (trigger fires, `:loop` surface): one scorer call over
  (original message, empty ledger, history) → scores + ledger. **Persist state with an
  explicit result check — `set_pending_clarify` is NOT routed through `safe_write/1`**
  (`front_door.ex:573` swallows failures; fine for observability keys, wrong for
  functional state). Write `{:ok, _}` ⇒ return questions ack; write failure ⇒ **fail
  open to standard composer** (never show questions the next turn can't correlate).
  Scorer failure on open ⇒ fail open to today's composer path.
- **Continue turns** (live pending state, `:loop` surface): deterministic
  override-phrase check FIRST (normalized match on "proceed with defaults" — works while
  the scorer is down), then one scorer call classifying `answers | override | new_ask` +
  folding answers into the ledger + re-scoring. Then: streak ≥ 2 ⇒ compose clean;
  qualifying but streak == 1 ⇒ recap-confirm round; non-qualifying under cap ⇒ next
  question round (the top open item); at cap ⇒ hold-for-accept or degraded compose per
  decision 2. `new_ask` ⇒ clear state, fall through to fresh triage (the pivot escape).
  Continue-turn re-persist failure ⇒ still serve the round (stale state self-heals — the
  next fold sees the message plus history) with a loud Trace + `:persist_failed`
  telemetry.
- **Redaction & sensitivity (review finding)**: the scorer prompt carries a hard rule —
  clarify questions ask about *choices and intent*, never secret *values* (credentials,
  tokens, keys). Every incoming message is passed through
  `Security.Redaction.Patterns.redact_with_count/1` (plain `redact/1` reports no hits,
  `security/redaction/patterns.ex:53`; `Patterns` already aliased in `front_door.ex:61`)
  **at clarify-lane entry — open, continue, AND the one-shot degraded path (it builds
  seed/premises too) — before scoring and before ledger persist**, so persisted
  `user_answer`s, the Q/A digest, and the seed transcript are all built from redacted
  material. A nonzero redaction count sets a sticky `"sensitive" => true` in state;
  compose ORs it into `mark_sensitive` (today `sensitive?` comes only from the ORIGINAL
  verdict's `:secrets` signal, `front_door.ex:216` — answers can introduce secrets after
  triage).
- **Override** ⇒ compose; `degraded: true` + `unresolved_slots` only when open items
  actually remain (override after a qualifying score with zero open items composes clean).
- **Scorer failure mid-loop (infra ≠ verdict)**: never reads as clarified — keep state,
  reply a bounded "couldn't process that answer; re-send or say 'proceed with defaults'"
  ack; after 2 consecutive failures the ack offers only the deterministic override phrase.
- **Compose enrichment**: intent = scorer `updated_intent` (fallback stored verdict
  intent/original message); request-seed artifact = original message + full (redacted)
  Q/A transcript appended; premises gain `"clarifications"` (pre-rendered digest string
  ≤ ~560B — `PremisesContext` inspect-renders non-binaries, so pre-render),
  `"ambiguity_score"`, `"readiness"`, plus `"degraded" => true` + `"unresolved_slots"`
  (list of short strings) on the degraded path. `:ambiguous` dropped from the composed
  verdict's signals on clean compose (resolved), kept on degraded (honest) — catalog and
  `mapped_signals/1` untouched.
- **Compose ordering (review finding)**: `start_composer` FIRST; **clear
  `pending_clarify` only on `{:ok, parent}`** — the prototype-graduation precedent
  (`consume_candidate` fires only after successful launch, `front_door.ex:772-779`).
  Launch failure keeps the state live: the error ack invites a re-send, which re-enters
  the loop (streak preserved, re-qualifies, compose retried); TTL backstops abandonment.
  A failed clear AFTER a successful launch is a loud-logged, Trace'd, TTL-bounded
  residual (documented) — and cleanup failures (clear pending / clear marker) **never
  prevent `after_launch/4`** from running (transition recording + prototype-candidate
  consumption must not be skippable by a metadata write failure).
- **Oscillation marker (review finding)**: clarified compose bypasses the oscillation
  guard by design, but the guard's proceed path is also where `oscillation_prompted_at`
  gets cleared (`front_door.ex:788-812`) — so `compose_from_clarify` **explicitly clears
  the marker** on successful launch (same write the guard uses), with a test proving a
  stale marker can't suppress a later real debounce.
- **TTL**: pending state expires after 1h (knob); expired ⇒ lazily cleared, message falls
  through to normal triage.

## Implementation steps

### Step 0 — PORT map + sign-off gate (before any code)

`docs/exploration/ouroboros/PORT-OB1-1.md` — the repo's first PORT map, anatomy per
`docs/exploration/README.md:111-135`: header (entry link, both shas, date), source
mechanism summary, side-by-side shapes, behaviors table (preserved / deliberately
changed / dropped — the divergences above), edge cases anchored to ouroboros's own tests
(`tests/unit/bigbang/test_ambiguity.py`, `test_ledger_seed.py`) plus this plan's
review-finding behaviors (persist-failure fail-open, redaction/sensitivity OR,
clear-after-launch, marker clear, one-shot-never-continues), sign-off gate listing the
ratified decisions. Present to operator; code starts on sign-off.

### Step 1 — pure core (TDD)

New modules under `lib/jido_claw/front_door/clarify/`:

- **`clarify/score.ex`** (`JidoClaw.FrontDoor.Clarify.Score`, pure) — ported constants
  (module attrs, attribution comment; both weight sets, floors, threshold 0.2, streak 2,
  temp 0.1), `deterministic_floor/1`, `effective_ambiguity/2` (= `max/2`),
  `qualifies?/2` (threshold ∧ 4 floors), `readiness/1`.
- **`clarify/ledger.ex`** (pure) — item normalization (string keys/enums,
  `user_input_required` present-nil coercion), `counts/1`
  (`%{open, conflicting, assumed, total}`), `open_items/1`, `open_required?/1`.
- **`clarify/state.ex`** (pure) — struct + `to_metadata/1` / `from_metadata/1`
  (string-keyed JSON-safe map; verdict stored via new `Verdict.to_map/1` wire form),
  `expired?/2` (takes `now` — reuse the existing `:front_door_clock` seam,
  `front_door.ex:910-911`; no new clock seam), round/streak/failure transitions.
  State keys: `original_message`, `verdict` (wire map), `ledger`, `clarity` (4 floats),
  `llm_ambiguity`, `updated_intent`, `rounds_shown`, `streak`, `scorer_failures`,
  `sensitive` (bool, sticky), `created_at`/`updated_at` (ISO8601 strings).
- **`clarify/formatter.ex`** (pure, IO.iodata) — `questions/3` (numbered, with
  why-it-matters + recommended default + "round X/N" + override instruction),
  `recap/1`, `hold/1`, `scorer_failure_ack/1`, `digest/1` (bounded Q/A premise string).
- **`lib/jido_claw/triage/verdict.ex`** — add `to_map/1`, the inverse of `from_map/1`
  emitting **wire strings** (`:significant_build` ⇒ `"significant-build"`;
  `to_string/1` would silently drop hyphenated signals on reload). Round-trip test.

### Step 2 — persistence

`lib/jido_claw/conversations/resources/session.ex`: `:set_pending_clarify` update action
(arg `:pending`, `allow_nil?: true`) reusing `Changes.SetMetadataKey, key:
"pending_clarify"` (the `pending_prototype` precedent, `session.ex:214-219`) +
`code_interface` define. **Front-door wrapper `persist_pending/3` returns the real Ash
result (no `safe_write`)**; `clear_pending/2` likewise result-checked (clear failures
loud-logged). Reloaded-path test (encode→decode→`from_metadata` — the JSONB round-trip
memory rule).

### Step 3 — scorer (the LLM boundary)

**`clarify/scorer.ex`** — mirrors `JidoClaw.Triage.LLM` (`triage/llm.ex`): one tool-less
`Jido.AI.generate_object/3`; knobs `:clarify_model` (default `:capable`), temp 0.1,
`max_tokens ~2000`, `timeout 30_000`, `:clarify_generate` fn seam;
`ReqLLM.Response.unwrap_object(resp, json_repair: true)`; never raises (rescue → error).
Watch the ExSlop clone gate — `gen/0`/`model/0` are the 3rd sibling of the
`Triage.LLM`/`PrototypeSummary` get_env idiom; keep non-contiguous/shaped differently.

Zoi schema (**map form only**, string enums): `classification`
(`answers|override|new_ask`), `clarity` (4 floats, clamped [0,1] in `Score`),
`ambiguity` (float), `updated_intent` (optional string), `ledger` (array of the OR2-5
item shape). Prompt: untrusted-data BEGIN/END framing (the `PrototypeSummary` pattern,
`front_door/prototype_summary.ex:57-76`); brownfield rubric verbatim; classification
contract; ledger contract incl. the repo-discoverable-⇒-assumable rule (decision 3) and
the **never-ask-for-secret-values rule**; deferral-tolerance clause; input carries
`original_message` + serialized prior ledger + the latest message (already redacted at
lane entry) explicitly (history is supplementary — the 6-turn window must not clip the
original ask).

### Step 4 — orchestrator + front door

**`clarify.ex`** (`JidoClaw.FrontDoor.Clarify`) — `trigger?/1`, `load_pending/2`
(`:none | {:live, state} | {:expired, state}`; pattern-match `%{metadata:
%{"pending_clarify" => %{} = raw}}` — present-nil trap), `open/4`, `continue/5`
(directives: `{:questions,…} | {:hold,…} | {:compose, spec} | :new_ask`),
`score_once_for_slots/4` (one-shot degraded path). Redaction (`redact_with_count/1`)
applied at lane entry — open, continue, and one-shot — before scoring/persist; sticky
`sensitive` bit maintained here.

**`lib/jido_claw/front_door.ex`** restructure (`decide/2`, :119-159) — non-clarify turns
byte-identical:

1. `load_session` moves to the top; pending-check runs **before** triage — but honored
   only on a `:loop` surface: `:none`/`:expired` ⇒ today's flow (expired lazily
   cleared); `{:live, _}` on a `:one_shot` surface ⇒ clear + Trace + today's flow.
2. Extract today's body into `triage_and_route/3`; the composer branch
   (`:140-152`) moves verbatim into `standard_composer/5`.
3. Composer branch gains the guard: composer? ∧ `Clarify.trigger?` ⇒ `clarify_lane`
   (`:one_shot` surface ⇒ degraded one-shot compose; scorer failure or open-turn
   persist failure ⇒ `standard_composer` fail-open).
4. `continue_clarify/4` maps directives; `{:compose, spec}` ⇒ `compose_from_clarify`:
   re-read `pending_graduation` + `hydrate_graduation` at compose time — **relevance
   basis is the clarified intent** (`spec.verdict.intent` = `updated_intent`, falling
   back to the stored original ask), never the confirm-turn message: `pending_graduation`
   derives relevance from `present(verdict.intent) || message` (`front_door.ex:595`),
   and a confirm turn like "yes, that's right" would false-negative a relevant
   prototype → `start_composer` with the enriched seed/verdict/premises (sensitivity
   OR'd) → on `{:ok, _}`: cleanup (clear pending, clear oscillation marker) and
   **`after_launch/4`** (its `consume_candidate` clears a graduated prototype,
   `:742,:775`), with cleanup failures logged/Trace'd but never preventing
   `after_launch/4`; on error: keep pending (retry-able), return the bounded error ack.
5. `start_composer/5` → `/6` with trailing `clarify_premises \\ %{}` merged last in
   `build_premises` (`:689-693`) — `Map.merge(m, %{})` keeps existing callers identical.
6. `persist_path` on open turn only (triage ran); continue turns skip it; `new_ask`
   gets it via the fall-through. Clarify branches mirror the composer branch's
   handoff-preamble consumption at both callers.

### Step 5 — callers + exit contract

- `lib/jido_claw.ex`: `chat/4` opts gain `clarify: :loop | :one_shot` (docs at `:90`
  block), threaded as `clarify_surface` into `front_door_ctx` (:369-380) with the
  kind-derived fallback; `{:clarify, resp}` case at :382-411 — persist assistant
  message, mark preamble consumed, `shape_clarify_ack/2` (detailed: `%{route: :clarify,
  status: :pending, run_id: nil, message: msg}`; default `{:ok, msg}` — web/discord/
  cron shapes untouched).
- Call sites: `web/controllers/chat_controller.ex` (both arms) ⇒ `clarify: :one_shot`;
  `platform/cron/dispatcher.ex` (both arms) ⇒ `clarify: :one_shot`;
  `web/channels/rpc_channel.ex` + `platform/channel/discord.ex` + `cli/run_command.ex`
  ⇒ `clarify: :loop`.
- `lib/jido_claw/cli/repl.ex:554-587`: ctx marks `:loop`; `{:clarify, resp}` case
  mirroring the composer branch (stop_thinking → print → preamble → persist → state).
- `lib/jido_claw/cli/run_command.ex`: `Result.route` gains `:clarify`; new `outcome_for`
  clause ⇒ **exit 3, outcome `:clarify_pending`** (the OQ-4 "human input needed"
  family; without the clause a detailed clarify ack is a FunctionClauseError). JSON
  envelope needs no new field.

### Step 6 — telemetry + knobs

- `lib/jido_claw/core/telemetry.ex`: `counter("jido_claw.clarify.total", tags: [:event,
  :outcome])` + `emit_clarify/2` (the `emit_needs_input` pattern, :292-299). Events
  cover open/round/hold/compose/degraded/override/new_ask/expired/scorer_failed/
  persist_failed/one_shot_cleared.
- `Trace.emit(:guardrail, %{guardrail: "clarify", …})` per round; SignalBus emission per
  the `emit_oscillation/2` precedent (`front_door.ex:876-892`).
- `config/config.exs`: `:clarify_model` (`:capable`), `:clarify_round_cap` (12),
  `:clarify_ttl_ms` (1h), `:clarify_generate` seam. App-env only in v1 (no
  `.jido/config.yaml` section — demand-gated).

### Step 7 — docs + reconciliation (machine-enforced)

- `docs/system/ambiguity-clarify.md` (mechanics, config, telemetry, residuals, PORT-map
  provenance cite) + AGENTS.md Key Patterns bullet + `docs/system/README.md` index —
  `mix jidoclaw.system_docs.check` enforces the pairing.
- Queue README item-8 DONE note (`docs/plans/unadopted-next-ten/README.md:807`) with
  corrections, house style.
- `docs/exploration/ouroboros/FEATURES-WORTH-BORROWING.md`: first Status pass — add the
  Status legend + OB1-1 ADOPTED line, reconcile the whole entry.
  `docs/exploration/pms/orca/FEATURES-WORTH-BORROWING.md`: OR2-5 Status PARTIAL (ledger/
  readiness shapes landed here; quality-gate half waits on item 9).
- Deviations recorded as they happen under `## Deviations` in this plan file.

## Test plan

- **Pure units**: `test/jido_claw/front_door/clarify/{score,ledger,state,formatter}_test.exs`
  — floor formula (zeros, coefficients, clamp), `max(llm, floor)`, gate boundaries
  (0.2/floors at-and-under), constants pinned against the ouroboros values, readiness
  three-way; ledger normalization/counts; state JSONB round-trip + TTL boundary +
  streak/round/failure transitions + sticky sensitive bit; formatter shapes (round X/N,
  override instruction, hold, failure acks, digest byte bound). Verdict
  `to_map/from_map` round-trip incl. hyphenated signals.
- **Scorer seam**: canned `:clarify_generate` — happy parse, malformed object, error,
  raise (never raises out), BEGIN/END markers present, knobs forwarded.
- **Front-door integration** (`test/jido_claw/front_door_clarify_test.exs`, the
  `front_door_test.exs:16-60` arming pattern: TriageStub + FrontDoorComposerStub +
  canned scorer + `:front_door_clock`): trigger gating (ambiguous+code/system ⇒ clarify;
  ambiguous+sketch ⇒ standard; code sans ambiguous ⇒ standard with identical seeded
  topics; talk ⇒ inline); open persists state, no run created; multi-turn pass flow
  (answers → recap streak-1 → confirm streak-2 → compose: premises keys, `:ambiguous`
  absent from seeded topics, intent = updated_intent, transcript in seed artifact,
  pending cleared, oscillation marker cleared); override deterministic +
  scorer-classified (degraded only with open items; clean when none); cap ⇒ hold with
  required item / degraded with only assumable; `new_ask` pivot; TTL expiry; scorer
  failure mid-loop (hold, failure count, 2nd failure ⇒ override-only ack, deterministic
  override still works); open-turn scorer failure ⇒ standard composer; **open-turn
  persist failure ⇒ standard composer** (write seam forced to fail); **launch failure
  keeps pending state and a re-send retries the compose**; redaction: an answer carrying
  a token ⇒ persisted ledger/digest/seed redacted + launch marked sensitive (and the
  same on the one-shot path); **pending_prototype + clarify pass ⇒ graduation still
  fires** (relevance from clarified intent, not the confirm-turn message); one-shot
  surface ⇒ immediate degraded compose, and a live pending on a one-shot turn is cleared
  and never treated as an answer (the main-cron case); nil session fail-open; stale
  oscillation marker cannot suppress a later real debounce; telemetry handler assertions.
- **Callers**: `chat/4` default + detailed shapes + `clarify:` opt threading; REPL
  clarify turn; run_command exit 3 / `:clarify_pending` / JSON envelope.

## Verification

1. Red→green on the new tests as each step lands (regression-test-first for the
   `Verdict.to_map` wire-form trap).
2. `mix precommit` — full gate (format, compile_check, credo/reach strict zero, full
   suite, system_docs/jido_md/system_prompt checks). Report exact exit code + counts;
   known rotating-flake policy applies (one unrelated timing test ⇒ re-run, per memory).
3. Live smoke (operator-visible, optional): `mix jidoclaw`, send an intentionally vague
   build ask ("make the thing faster"), observe the question round; answer; observe
   compose ack; `Tidewave`/`lua_query` check of the run's premises.

## Risks / notes

- Failed `clear_pending` after a successful launch: loud log/Trace, TTL-bounded
  residual (documented in the system page).
- Ledger-marking gaming (LLM resolving its own items) is bounded by the deterministic
  floor but not eliminated — same residual ouroboros carries; documented in the system
  page residuals.
- Scorer is one call per round at `:capable` — cost is signal-gated per OQ-4; the
  `significant-build ∧ no-criteria` extra trigger stays evidence-gated.
- Continue-turn persist failure serves the round on stale state (self-healing via
  re-fold) — deliberate, Trace'd, documented.

## Deviations

- **`start_composer/6`'s 6th arg carries `{premises, sensitive?}`, not premises
  alone** (forced correction). The plan named the new trailing param
  `clarify_premises \\ %{}`, but its own redaction finding requires the sticky
  sensitivity bit to OR into `mark_sensitive/2`, which is computed inside
  `finish_launch` — so the 6th arg is a small `clarify` map
  (`%{premises:, sensitive?:}`, default `%{}`); premises still merge LAST in
  `build_premises/5` and pre-clarify callers stay byte-identical. Relatedly,
  `finish_launch` was already at credo's max arity (8), so the
  `intent`/`base_intent` derivation moved INSIDE it (it already receives
  `message` + `graduation`) instead of adding a 9th param.
- **Compose specs carry an `origin` field** (`:streak | :cap | :override |
  :one_shot`, small addition): the front door's compose telemetry
  (`:clean/:degraded/:override/:one_shot_degraded`) needs the exit's origin,
  which `degraded?` alone can't distinguish.
- **One-shot composes are ALWAYS `degraded: true`** (interpretation, per
  decision 5's verbatim text): the surface skipped the loop, so even a
  single qualifying score never earns the clean label (the loop's clean
  compose requires the 2-round streak). `unresolved_slots` still only rides
  when non-empty. The override-composes-clean rule stays scoped to the loop,
  where confirmation actually happened.
- **The open turn can be a recap round** (interpretation): when the very
  FIRST score already qualifies (triage said ambiguous, the scorer disagrees),
  the open ack is the recap-confirm round (streak 1 of 2) rather than a
  fabricated question round — divergence (c) applied at open, not just
  mid-loop.
- **No dedicated REPL clarify test** (logged gap, matching repo precedent):
  `Repl.handle_message/2` is private and has no test harness for the existing
  COMPOSER branch either; the clarify branch shares one
  `render_front_door_ack/4` helper with it, so parity is structural. Caller
  coverage lands at the `chat/4` (shapes + opt threading) and `run_command`
  (exit 3) levels instead.
- **`user_input_required` absent/junk coerces to `true`** (fail-closed choice
  within the plan's "present-nil coercion" note): only a literal `false`
  reads as assumable, so a sloppy scorer omission HOLDS at the cap instead of
  auto-assuming past a possibly-required unknown (decision 2's posture).
- **Scorer history is redacted at the scorer boundary too**: the lane redacts
  the current turn's message, but history rides into the scorer prompt and a
  faithful model could quote an older turn's secret into a ledger item the
  lane would then persist — so `Scorer.render_history/1` redacts each entry
  (triage's own history exposure is unchanged; this guards the clarify lane's
  PERSISTED derivatives).
- **`composer_ack/4` consolidated into `shaped_ack/5`** (reach-driven): adding
  `shape_clarify_ack`'s detailed map made the `%{route, status, run_id,
  message}` literal the 3rd repeated shape (`reach --smells` repeated-map
  threshold), so jido_claw.ex now has ONE construction site for both routes —
  behavior identical, shapes pinned by the existing + new ack tests.
