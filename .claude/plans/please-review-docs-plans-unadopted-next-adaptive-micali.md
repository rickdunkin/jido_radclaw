# Plan: Deterministic eval harness, minimal slice (unadopted-next-five, item 5)

## Context

Item 5 of `docs/plans/unadopted-next-five/README.md` (lines 240–261) — the last
item of the program, sourced from jidoka UNADOPTED-IDEAS #1 / rollup V2-5. Its
trigger ("the next material rewrite of the doctrine slices") was fired by items
3+4: a new arbiter persona (the 10th), two new doctrine slices (`tie_break`,
`code_doctrine` — registry now 11), and the arbiter decision-memo's
prose-half/schema-half field contract. The harness pins this prompt-as-data
surface so future edits fail loudly instead of drifting silently.

**Scope guard (from the README): a harness plus a first case set, not an eval
program.** Lift `Jidoka.Eval.Case`'s shape — spec + request + assertions run
against fake or live capabilities (source on disk:
`/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/eval/{case,run}.ex`,
`eval.ex`). Design intent preserved verbatim from jidoka's moduledoc: *adds no
new runtime path* — the runner only calls existing production functions.

**User decisions (locked):** harness lives in **`lib/jido_claw/eval/`**; runner
supports the **composer-wave kind** in addition to prompt + schema; seed set
**includes prose↔schema coherence cases**; existing tests
(`doctrine_test.exs`, `persona_test.exs`, `worker_output_schemas_test.exs`,
`composer_loop_test.exs`, `subagent_prompt_test.exs`) stay **untouched**.
Nothing committed/staged; done only when `mix precommit` passes. Greenfield —
no compatibility shims.

## Part 1 — Harness core: `lib/jido_claw/eval/`

Three new modules, plain **`defstruct` (not Zoi)**: the jidoka Case validated
its sub-parts via `Zoi.lazy` refs to `Agent.Spec`/`Turn.Request`, which have no
analogue here — our `request` is an intentionally heterogeneous kind-keyed map,
so Zoi would buy nothing while importing the keyword-form dialyzer trap and
schema-helper ceremony. The real invariants (non-empty id, kind ∈ 4, status ∈
3) are a few guarded clauses.

### `JidoClaw.Eval.Case` — `lib/jido_claw/eval/case.ex`
Fields: `id`, `kind` (`:prompt | :schema | :composer | :coherence`),
`request :: map()`, `assertions :: map()` (default `%{}`), `metadata` (default
`%{}`). Functions (jidoka parity): `new/2`, `new!/2` (raises
`ArgumentError`), `from_input/2` (accepted input: `%Case{}` | keyword | map).
Top-level attrs accept **both atom and string keys** (jidoka ergonomics);
`kind` accepts the four atoms or their exact string forms via explicit
per-value mapping — never `String.to_atom/1`.
Errors: `{:invalid_eval_kind, k}`, `{:invalid_eval_case_id, id}`,
non-map request. `from_input/2` **re-validates a `%Case{}` through `new/2`**
(jidoka revalidates too; with a plain defstruct a caller can hand-build an
invalid case, so struct input must not skip validation). Default id via
`JidoClaw.Refs.mint("eval_")` (`lib/jido_claw/refs.ex:22`); injectable
`:id_generator` opt so tests stay deterministic. `kind` is a field (not
per-kind request structs).

### `JidoClaw.Eval.Run` — `lib/jido_claw/eval/run.ex`
Fields: `case_id`, `kind`, `status` (`:passed | :failed | :error`), `result`,
`error`, `assertions` (list, default `[]`), `observations` (map), `metadata`.
Assertion record (identical to jidoka `run.ex:24`):
`%{name: atom, status: :passed | :failed, expected: term, actual: term}`
(expected/actual optional). `statuses/0`, `new/1`, `new!/1`.

### `JidoClaw.Eval` — `lib/jido_claw/eval.ex` (the runner)
`run_case(case_input, opts \\ []) :: {:ok, Run.t()} | {:error, term()}` =
`Case.from_input → execute → evaluate → build_run`. `execute` wrapped in
try/rescue so a broken case yields a `status: :error` Run, not a crash
(`# credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise`,
precedent `subagent_prompt.ex:104`). **Unknown assertion keys fail loudly**
(deliberate deviation from jidoka's silent skip — this harness exists to catch
drift, and a typo like `artifact_equal` must not shrink the assertion set and
pass): each unknown key emits a failed record
`%{name: :unknown_assertion, status: :failed, expected: <known keys for the
kind>, actual: key}`. All-pass → `:passed`; any fail → `:failed`; execute
error → `:error` with normalized error map. Per-kind `observations` (prompt bytes;
valid/invalid counts; terminal/ran/artifact names; token count).

Four genuinely distinct `execute` clauses (ExSlop clone-check safe), calling
only production functions — **lib never names a test module**:

| kind | production call | request keys | result |
|---|---|---|---|
| `:prompt` | `JidoClaw.Agent.SubagentPrompt.build/3` (`subagent_prompt.ex:31`) | `template`, `tool_context`, `stage` (default nil) | `%{content: String.t()}` |
| `:schema` | `Jido.AI.Output.parse(Keyword.fetch!(m.strategy_opts(), :output), sample)` (pattern: `worker_output_schemas_test.exs:37`) | `module`, `sample` | `%{parsed: {:ok,_}\|{:error,_}, ...}` |
| `:composer` | `JidoClaw.RouteComposer.run_sync/1` (`route_composer.ex:935`) → `{:ok, summary}` (type `:299`) | `catalog`, `live`, `artifacts`, `ran`, `max_waves` (static) — merged with `tenant`/`actor`/`context`/`timeout` from `run_case` **opts** | `%{summary: summary}` |
| `:coherence` | `JidoClaw.Doctrine.slice/1` + per-token `Output.parse` probes | `slice`, `module`, `field` (path into the string-keyed sample), `tokens`, `non_token`, `base_sample` | `%{prose, token_results, non_token_result}` |

Assertion vocabulary (small, jidoka-spirited):
- `:prompt` — `contains` (string|list), `not_contains`, `equals`.
- `:schema` — `valid` (sample|list; default `[request.sample]`), `invalid`
  (sample|list), `field_equals` (`[{path, value}]`). **Parsed output has ATOM
  keys** (`parsed.overall`, `finding.severity` — see
  `worker_output_schemas_test.exs:285-291`): paths are atoms + integer list
  indices, walked via `get_in` with integers mapped to `Access.at/1`
  (e.g. `[:findings, 0, :confidence]`).
- `:composer` — `terminal` (atom), `ran` (string|list; `summary.ran` is a
  MapSet), `artifact_contains` / `artifact_equals`
  (`[{name, producer, value}]`): `summary.artifacts[name][producer]` holds a
  **ref**, resolved **lazily per assertion** via
  `JidoClaw.Orchestration.ComposerArtifact.resolve_value(ref, tenant:, actor:)`
  (`composer_artifact.ex:334`) with tenant/actor threaded from `run_case` opts
  — the one documented impure evaluator.
- `:coherence` — `prose_contains_tokens`, `schema_accepts_tokens`,
  `schema_rejects_non_token`. `prose_contains_tokens` checks the **backticked
  form** `` "`" <> token <> "`" `` — every canonical token is backticked in
  the doctrine files (verified `tie_break.md:14-18,25-27`,
  `confidence_tagging.md:5-7`), and raw substring matching would weakly pass
  on prose like "token / time cost". `put_path/3` mutates the **string-keyed**
  input sample (supports `["findings", 0, "confidence"]`).

**Fake↔live seam** (jidoka's capabilities-in-opts, translated): the runner is
identical either way; the caller's environment decides. `:prompt` — ambient app
env `:jido_claw, :psychology` (off in `config/test.exs:50`; feature tests
opt in via put_env + on_exit, async: false; `:doctrine` off in test does NOT
matter — that gate lives in `Startup.inject_subagent_prompt`, `build/3` always
emits doctrine) + hermetic `tool_context: %{project_dir: <tmp dir>}` (no
tenant ⇒ `Scope.resolve` → no DB, no Block tier; no JIDO.md in tmp dir).
`:schema`/`:coherence` — pure. `:composer` — the calling test arms
`:agent_templates_override`, `:route_composer_stub_outputs`,
`:step_agent_server` (exactly `composer_loop_test.exs:37-57`); unarmed = live.

### Harness unit tests — `test/jido_claw/eval_test.exs` (async: true, DB-free)
Mirrors jidoka's `eval_test.exs` using pure `:schema`/`:coherence` kinds:
pass mapping (valid Reviewer sample → `:passed`, all assertion records
`:passed`); fail mapping (sample missing a field under `valid:` → `:failed`
with `expected`/`actual`); normalization + id (`:id_generator` injection,
`{:invalid_eval_kind, _}`, empty-id error, `new!` raises); Run validation
(`statuses/0`, invalid status, `new!` raises); error mapping (a `:schema` case
with `module: JidoClaw.Doctrine` — no `strategy_opts/0` — → `status: :error`);
unknown assertion key → run `:failed` with an `:unknown_assertion` record
naming the key (the fail-loudly deviation); `%Case{}` re-validation through
`from_input/2` (a hand-built invalid struct is rejected). Use
`assert match?(pat, x), "msg"` where a message is wanted (never
`assert pat = x, "msg"`).

## Part 2 — Seed cases (10), pinning the post-AR-9 surface

All sample maps **inline in the `*_test.exs` files** (reach `fixed_shape_map`
avoidance — the `worker_output_schemas_test` precedent). Anchors below are
verified against the current priv/lib text. Where an existing test already pins
an anchor (`subagent_prompt_test.exs` pins coder "Runtime artifacts", Defender,
Arbiter+"Plan arbitration"), the seed cases deliberately pin the **not-yet-
pinned** post-AR-9 content instead; the two persona pins that do overlap in
spirit use different data pairs.

### File A — `test/jido_claw/eval/prompt_cases_test.exs`
`use ExUnit.Case, async: false` (mutates `:psychology` env). Setup: tmp
`project_dir` (+ `on_exit` rm_rf) and psychology snapshot/put_env/on_exit —
both mirroring `subagent_prompt_test.exs:14-21,68-81`. Four `:prompt` cases
run via `JidoClaw.Eval.run_case/1`, asserting `run.status == :passed` (print
`run.assertions` on failure):

1. **coder prompt** (`template: "coder"`, nil stage): contains `"# Role"`,
   `"## DOCTRINE"`, `"Code craft"` (`code_doctrine.md:1` — new, unpinned at
   this altitude), `"Confidence tagging"` (`confidence_tagging.md:1`),
   `"## PSYCHOLOGY: Craftsperson"` (template fallback, `persona.ex:62`);
   not_contains `"Review discipline"`.
2. **reviewer prompt, stage-first** (`template: "reviewer"`,
   `stage: "architecture-reviewer"`): contains `"Reviewer Contract"`
   (`reviewer_contract.md:1`), the four finding-field names in their
   **backticked** form (`` `severity` ``/`` `confidence` ``/`` `location` ``/
   `` `description` ``, `reviewer_contract.md:12-20` — the prose half of the
   4-field contract; the list is a **file-local** `@reviewer_finding_fields`
   in this module, duplicated as a one-liner in File B for S1 rather than a
   cross-module helper), `"action_needed"`, `"## PSYCHOLOGY: Pragmatist"`
   (stage wins over the Skeptic template fallback, `persona.ex:40` vs `:65` —
   a distinguishing pair no existing test pins); not_contains
   `"Confidence tagging"` (the reviewer family is excluded from that slice,
   `doctrine.ex`).
3. **plan_drafter prompt, lens stage** (`template: "plan_drafter"`,
   `stage: "planner-smallest-shippable"`): contains
   `"## PSYCHOLOGY: Detective"` (the AR-9 lens-planner voice,
   `persona.ex:50`), `"## DOCTRINE"`, `"Runtime artifacts"`.
4. **plan_arbiter prompt** (`template: "plan_arbiter"`,
   `stage: "plan-arbiter"`): contains `"Plan arbitration"`, `"Tie-break
   ladder"` (`tie_break.md:1,11`), all five rung tokens + all three verdict
   tokens (same canonical lists as C1/C2 — pins them reaching the assembled
   prompt), `"## PSYCHOLOGY: Arbiter"` (the 10th persona).

### File B — `test/jido_claw/eval/schema_coherence_cases_test.exs` (async: true, pure)
File B defines two file-local sample builders (`defp reviewer_sample/0`,
`defp memo_sample/0` — string-keyed, shaped like
`worker_output_schemas_test.exs:271-283,598-617`, the reach-safe inline
precedent) shared by S1/S2 and as the `base_sample:` of C1–C3, plus its own
one-line `@reviewer_finding_fields`.

5. **S1 reviewer verdict schema** (`:schema`, `module: Reviewer`,
   `sample: reviewer_sample()`);
   `field_equals: [{[:overall], :approve}, {[:findings, 0, :severity], "info"},
   {[:findings, 0, :confidence], "likely"}]` (the atom-vs-STRING Envelope
   round-trip split, `output_schema.ex:127-146`); `invalid:` = one sample per
   dropped `@reviewer_finding_fields` member (schema half of the 4-field
   contract).
6. **S2 arbiter memo schema** (`:schema`, `module: PlanArbiter`,
   `sample: memo_sample()`);
   `field_equals: [{[:verdict], "adopt"}, {[:tie_break_rung], "correctness"},
   {[:status], :completed}]`; `invalid:` = out-of-enum verdict `"maybe"` +
   rung `"vibes"` (`plan_arbiter.ex:49-52`).
7. **C1 tie-break rung coherence** (`:coherence`): `slice: :tie_break`,
   `module: PlanArbiter`, `field: ["tie_break_rung"]`,
   `base_sample: memo_sample()`, `tokens:
   ~w(correctness grounding simpler-first validation-rollback cost)`,
   `non_token: "vibes"` — verified identical in `tie_break.md:14-18` and the
   Zoi enum (`plan_arbiter.ex:50`). All three coherence assertions.
8. **C2 verdict coherence** (`:coherence`): same slice/module,
   `field: ["verdict"]`, `base_sample: memo_sample()`,
   `tokens: ~w(adopt hybrid revise_first)`,
   `non_token: "maybe"` (`tie_break.md:25-27` ↔ `plan_arbiter.ex:52`).
9. **C3 likely/unsure coherence** (`:coherence`):
   `slice: :confidence_tagging`, `module: Reviewer`,
   `field: ["findings", 0, "confidence"]`, `base_sample: reviewer_sample()`,
   `tokens: ~w(likely unsure)`, `non_token: "maybe"`
   (`confidence_tagging.md:5-7` ↔ `output_schema.ex` finding confidence — a
   confirmed closed enum; do NOT route this through Researcher without first
   confirming its confidence field is an enum).

### File C — `test/jido_claw/eval/composer_case_test.exs`
`use JidoClaw.TenantCase, async: false` (mutates env; shared sandbox).
10. **X1 armed adopt memo e2e** (`:composer`): the arbiter decision-memo
    contract through a real wave. Setup mirrors
    `composer_loop_test.exs:37-57,431-478`: `StubStore.setup()`, arm
    `TestFixtures.armed_template_override(StubWorker)` +
    `TestFixtures.armed_stub_outputs(TestFixtures.armed_adopt_arbiter())` +
    `step_agent_server: StubAgentServer` (all with on_exit restore), seed via
    `seed_full` / `actor_for` (public in `TenantCase`,
    `tenant_case.ex:86,155`). Case request:
    `%{catalog: Catalog.all(), live: TestFixtures.armed_seed_live(),
    artifacts: TestFixtures.armed_seed_artifacts(), ran: ["triage"],
    max_waves: 15}`. Ordering matters: **`RunPubSub.subscribe_gates()` FIRST**
    (`:gate_requested` is a one-shot broadcast, not replayed —
    `composer_loop_test.exs:448` subscribes before starting), THEN
    `Task.async(fn -> run_case(case, tenant:, actor:, context:, timeout:
    30_000) end)` → `assert_receive {:gate_requested, ...}` → await-paused
    poll → `Cases.decide(case_id, :approve, ...)` → await Task.
    Assertions: `terminal: :converged`, `ran: "implementer"`,
    `artifact_contains: [{"decision-memo", "plan-arbiter", "verdict: adopt"}]`,
    `artifact_equals: [{"plan", "planner",
    "PLAN (final): adopt Plan A, smallest-shippable."}]` (anchors verified at
    `composer_loop_test.exs:526,531` / `fixtures.ex` `armed_adopt_arbiter`).
    The helpers `parent_of`/`await_wave_paused`/`drain_run_registry` are
    file-local defps in `composer_loop_test.exs:975-1010` — write **adapted,
    reshaped** equivalents in File C (inline in the flow or simplified), not
    verbatim copies (ExSlop contiguous-clone risk).

## Doc reconciliation (whole entries, not just status lines — program rule)

These are original-design exploration docs: manual entry-by-entry edits.

1. `docs/exploration/jidoka/UNADOPTED-IDEAS.md` item #1 (table row :9 + entry
   :22-28): flip to adopted/DONE 2026-07-03; rewrite Standing (harness now at
   `lib/jido_claw/eval/`, four kinds), Now?/Trigger (fired by items 3+4).
   Record the stub-list note: both this entry's and V2-5's stub lists are
   accurate-but-partial subsets of `test/support/` (all seven files exist),
   and the shipped harness consumes **none of them directly** — it calls
   production functions; the composer case arms the existing composer stubs
   via app env.
2. `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` V2-5 (:104-110,
   plus any summary lines referencing it): PARTIAL → ADOPTED; note the shape
   adaptation (no `Agent.Spec`/`Turn.Request` altitude here → kind-keyed
   requests: prompt/schema/composer/coherence) and defstruct-over-Zoi.
3. `docs/plans/unadopted-next-five/README.md` item 5 (table row :27 +
   §240-261): ✅ DONE + progress note recording deviations from the entry's
   own claims, in the established style of items 1–4: (a) four kinds, incl. a
   coherence kind the entry didn't name; (b) defstruct not Zoi; (c) the
   fake-capability halves are consumed via env arming, not imported;
   (d) 10 seed cases across 3 files + harness unit tests; (e) unknown
   assertion keys fail loudly — a deliberate deviation from jidoka's
   silent-skip parity, since this harness's purpose is drift-catching.
4. `AGENTS.md`: one Key Patterns bullet — `JidoClaw.Eval.{Case,Run}` package
   `{kind, request, assertions}` run via `JidoClaw.Eval.run_case/2` against
   production functions only (prompt assembly / worker schema / composer wave /
   prose↔schema coherence); fake↔live seam is app-env + opts, never a test
   module in lib; seed cases in `test/jido_claw/eval/`.

## Files touched

New: `lib/jido_claw/eval/case.ex`, `lib/jido_claw/eval/run.ex`,
`lib/jido_claw/eval.ex`, `test/jido_claw/eval_test.exs`,
`test/jido_claw/eval/prompt_cases_test.exs`,
`test/jido_claw/eval/schema_coherence_cases_test.exs`,
`test/jido_claw/eval/composer_case_test.exs`.
Edited (docs only): the four reconciliation targets above. No existing lib or
test file changes.

## Gate traps (from project memory — apply during implementation)

- Zero credo/reach findings required; reach also scans `test/support` in
  :test env (we add nothing there; samples stay inline in test files).
- ExSlop: keep the four `execute`/evaluator clauses structurally distinct; no
  verbatim helper copies from `composer_loop_test.exs`.
- No trivial-forwarder defps; build lists with `Enum.flat_map`, strings with
  iodata (no `acc ++ [x]` / `<>`-around-join ping-pong).
- Rescue-without-reraise needs the disable comment (precedent
  `subagent_prompt.ex:104`).
- `MemoryExportTest` is a known full-suite capture_log flake — not a
  regression.
- Run gates bare — never piped through tail/head/grep; report exact exit
  codes/counts.

## Implementation order (verify per step)

1. `Case` + `Run` structs → `mix compile --warnings-as-errors`.
2. `JidoClaw.Eval` runner → compile clean.
3. Harness unit tests → `mix test test/jido_claw/eval_test.exs`.
4. File B (schema + coherence cases) → green.
5. File A (prompt cases) → green.
6. File C (composer memo e2e) → green (needs Postgres).
7. Doc reconciliation edits (§ above).
8. **Full `mix precommit`** — must pass (format, compile_check, credo strict
   zero, reach zero, ExSlop, dialyzer, full suite). Fix anything it surfaces;
   re-run until clean. Report exact verdict lines.

## Risks / notes

- `strategy_opts()[:output]` is a `%Jido.AI.Output{}` per the Defaults macro
  (`worker_output_schemas_test.exs` moduledoc) — confirm at first runner
  compile; if the accessor shape differs, mirror the existing test exactly.
- Composer-kind runtime: X1 rides the proven armed-wave path; if the
  await-paused/decide dance proves racy in the eval wrapper, fall back to the
  exact `composer_loop_test.exs` sequencing (it is deterministic there).
- Case count is 10 — top of the README's "~6–10".
- Prompt cases assert through `run.status`; make failures readable by
  including the failing assertion records in the ExUnit failure message.
