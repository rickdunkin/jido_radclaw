# AR-9 program, unit 2: multi-plan wave + plan-arbiter (PR-3 + PR-4) + item-4 code-doctrine slice

## Context

`docs/plans/unadopted-next-five/README.md` item 3 is the AR-9 judge-panel plan wave
(alp-river V2 AR-9, sketch at `docs/exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md:142-166`).
PR-1 (tiering seam) and PR-2 (premises threading) landed 2026-07-02 and sit in the
working tree. This unit is the remainder: **PR-3** (the plan wave — arming, lens
planners, challengers, arbiter, gate wiring) + **PR-4** (the arbiter stage declares
`model: :capable, effort: :high` — the tiering seam's designed first declarer),
plus **item 4** (the `code-doctrine` slice riding this unit's doctrine authoring
pass; READ_MAP half stays explicitly deferred per the README).

**User-locked decisions** (asked and answered 2026-07-02):

1. **Arbiter flow = "Design P — planner finalizes"**: the arbiter is a pure
   adjudicator emitting only a `decision-memo` artifact (verdict
   `adopt|hybrid|revise_first` INSIDE the memo — no verdict-driven routing); the
   existing single `planner` stage always finalizes the `plan` from the memo (+ the
   competing plans and critiques as optional inputs). The planner stays the SOLE
   producer of `plan` in both modes, so the human-reject → re-plan machinery is
   untouched.
2. **Item 4 in scope** (code-doctrine slice; READ_MAP deferred).
3. **Arming = triage judgment only**, conjunction with `significant-build`
   enforced in front-door code; armed runs seed `multi-plan` INSTEAD OF
   `plan-needed`; no config kill-switch.
4. **Three lenses**: smallest-shippable / risk-first / reuse-first.

**Three recorded deviations from the V2 sketch** (dated corrections in the docs
step, same pattern as PR-1's spawn-time correction):

- (a) sketch step 5's "arbiter → gate on Adopt" becomes planner-finalizes
  (decision 1) — hybrid/revise_first do NOT ride `plan-rejected`; the memo carries
  the verdict and the planner finalizes on all three.
- (b) "the gate presents the memo" is dropped — threading dynamic memo details
  would touch 5 shared-gate-infra files (`GateStep` reads `details` from
  compile-time options, shared with `SafetyGate`) for redundant value: the human
  approves the *finalized* plan, and the memo remains an inspectable composer
  artifact. The plan-gate stage stays byte-identical.
- (c) sketch step 2's "over the existing planner template" is replaced by a
  dedicated **`plan_drafter`** template (user plan-review finding): the
  `researcher` role text and the `emit_signals` doctrine slice both instruct
  emitting `plan-ready` when a plan is drafted, and emitted signals are strictly
  checked against the stage's `publishes` — a real LLM following the stale
  instruction on a lens stage would route-fail the wave. The lens stages therefore
  run a template whose prompt surface never mentions `plan-ready`, and the
  `plan-drafted:<lens>` advisory signal is **removed entirely** — lens stages
  publish only `scope-shift`; sequencing is artifact-driven.

**Constraints**: greenfield (no migration/compat concerns). Nothing committed — all
changes stay unstaged. Done = `mix precommit` passes (run bare, never piped; report
exact exit + counts). No deferrals beyond the named READ_MAP half.

## Verified mechanics (design agents + direct reads + user plan review, 2026-07-02) — composer-core diffs: ZERO

- `Router.drop_unsatisfiable` (router.ex:165-185) is graph-aware (`produced_set`
  counts in-route producers) and recomputed per compose. One armed seed-compose
  yields the pipeline as Kahn levels `[lens×3] → [challengers×3] → [plan-arbiter]
  → [planner]`; the loop dispatches one cohort per tick.
- `Graph.kahn` builds ordering edges from `required ++ optional` inputs when the
  producer is in-route; absent optional producers create no edge (graph.ex:69-77).
  The planner's new optional inputs order it after the arbiter when armed; inert
  unarmed. **No lens/challenger/arbiter signals are needed anywhere** — sequencing
  is artifact-driven; all seven new stages publish only `scope-shift`.
- `DefaultMapper`: the reviewer path keys on typed `overall ∈ @verdicts`
  (default_mapper.ex:99-119) — **new worker schemas must NOT carry an `overall`
  key** (lens-nil + overall ⇒ `{:reviewer_without_lens, name}` wave failure).
  `output_artifacts` resolves each declared output name via typed key →
  `StepResult.artifacts[name]` → `coerce(result.result)` (:143-161), and
  `result.result = Output.extract_result(typed)` = the worker **summary**
  (reasoning/output.ex:47-48). Zoi drops unknown keys (Tidewave-verified), so on a
  real run `plan:<lens>` / `critique:<lens>` / `decision-memo` ALWAYS resolve to
  the worker's summary — **each summary must be the self-contained artifact**, and
  test stubs must be schema-shaped (no dynamic artifact keys) so tests exercise
  the same fallback path. Emitted signals must be ⊆ stage `publishes` or the wave
  fails; absent `signals` ⇒ `[]`. `refuse_blocked_producer` applies to all new
  lens-nil stages (blocked ⇒ loud wave failure).
- Template role text and doctrine slices are part of the signal contract: a
  template whose prompt surface names a signal (researcher/`emit_signals` name
  `plan-ready`) must only run on stages that declare it — hence the dedicated
  `plan_drafter` template for lens stages (deviation c).
- Challenger critiques must not ride `findings:`/`clean:` families — the fixer
  subscribes bare `findings` (family-prefix match); the `critique:<lens>` family
  avoids it. Challengers/arbiter/lens planners are `lens: nil` ⇒ invisible to
  `Loop.lenses_clean?` and validator invariant 8.
- `gate_input_producers` is **provenance-derived** (route_composer.ex:2970-2977);
  armed human-reject rerun set = `{planner}` only (lens planners produce
  `plan:<lens>`, arbiter produces `decision-memo` — never `plan`). Replan
  machinery, rerun caps, and `resolve_gate_input_ref` (single `plan` producer)
  untouched.
- `enforce_completion_signals` is role-based: the finalizer planner keeps its
  `plan-ready` injection at Kahn level 4 exactly as at level 1; lens planners /
  challengers / arbiter publish no completion signal ⇒ no injection.
- Recovery is config-authoritative (`decode_config_catalog` re-validates the
  serialized catalog); `Stage.to_map/from_map` already round-trips `model`/`effort`.
- `composer_private` templates are already excluded from spawn/handoff enumeration
  (verified: spawn_agent.ex/handoff.ex list only the 7 public templates) — **no
  spawn-surface or `.jido/system_prompt.md` updates**. `forward_context: :none` +
  native read tools is proven by the system templates (system_executor runs
  RunCommand inside composer waves).
- `run_sync` default `max_waves` = 20; armed adopt ≈ 7-8 waves (use
  `max_waves: 15` in e2e fixtures). Blast radius of one failed stage in a 3-stage
  wave = whole wave fails → terminal `:route_failed` — identical to today's
  3-reviewer wave; accepted.

## Implementation steps

Order matters only for red-first discipline; everything lands as one working-tree
unit (the three registries + catalog are compile-/drift-guard-coupled and must be
consistent at every `mix test` run: `catalog.ex` raises at compile if a
`{:worker_template, _}` is unregistered, and the doctrine/persona drift guards
require `template_names() == Templates.names()`).

### Step 1 — three new worker templates + registration ripple

All three are schema-only modules like reviewer.ex/verifier.ex (no defps,
`@moduledoc false`, alias `OutputSchema`), `model: :fast` (the STAGE carries the
tier), `max_iterations: 15`, `streaming: false`, `tool_timeout_ms: 30_000`,
`compaction: [mode: :auto]`, `output: %{schema: ..., retries: 1,
on_validation_error: :repair}`.

**`lib/jido_claw/agent/workers/plan_drafter.ex`** (new — deviation c): name
`"jido_claw_plan_drafter"`; same tools as `researcher` (the drafting precedent);
description: "Drafts ONE competing implementation plan under the bias named in its
stage task, for a multi-plan run. Your summary IS the plan — make it a complete,
self-contained implementation plan. You are one of several parallel drafters; a
separate arbiter selects across the competing plans, and a separate planner
finalizes — never emit plan-ready; only emit scope-shift when the task or wave
context explicitly asks for it." (Wording keeps the PR-2 premises block coherent
— `PremisesContext` instructs `scope-shift` from `extra_context`, not the task.)
Schema (lean — no `findings`, no `overall`):

```elixir
Zoi.object(%{
  summary: Zoi.string(),                                # becomes the plan:<lens> artifact (summary fallback)
  status: Zoi.enum([:completed, :partial, :blocked]),   # atom — never persisted; blocked-producer refusal reads it
  confidence: Zoi.enum([:low, :medium, :high]),
  signals: Zoi.optional(Zoi.array(Zoi.string())),       # scope-shift self-report only
  artifacts: OutputSchema.artifacts()
})
```

**`lib/jido_claw/agent/workers/plan_challenger.ex`** (new): name
`"jido_claw_plan_challenger"`; `tools: [JidoClaw.Tools.ReadFile,
JidoClaw.Tools.SearchCode]`; description: "Critiques ONE proposed implementation
plan (critique-only): surfaces blockers, concerns, and strengths for a downstream
arbiter to weigh. Your summary IS the critique artifact — self-contained. Never
approves or picks a plan. Read-only." Schema — **no `overall`, no `findings`**:

```elixir
Zoi.object(%{
  summary: Zoi.string(),                                # becomes the critique:<lens> artifact
  status: Zoi.enum([:completed, :partial, :blocked]),
  confidence: Zoi.enum([:low, :medium, :high]),
  blockers: Zoi.array(Zoi.string()),
  concerns: Zoi.array(Zoi.string()),
  strengths: Zoi.array(Zoi.string()),
  signals: Zoi.optional(Zoi.array(Zoi.string())),
  artifacts: OutputSchema.artifacts()
})
```

**`lib/jido_claw/agent/workers/plan_arbiter.ex`** (new): name
`"jido_claw_plan_arbiter"`; `tools: [JidoClaw.Tools.ReadFile,
JidoClaw.Tools.SearchCode]` (spot-check grounding claims); description:
"Adjudicates several competing implementation plans and their critiques ...
steelmans each plan, then writes a decision memo naming one verdict
(adopt/hybrid/revise_first), the selection, and the tie-break rung that decided
it. Your summary IS the decision-memo artifact — it must name the verdict, the
selection, and (for hybrid/revise_first) the graft seams or blocking critiques,
self-contained. Read-only; a selector, not a critic."

```elixir
Zoi.object(%{
  summary: Zoi.string(),                                # becomes the decision-memo artifact — self-contained
  status: Zoi.enum([:completed, :partial, :blocked]),
  confidence: Zoi.enum([:low, :medium, :high]),
  assessments:
    Zoi.array(Zoi.object(%{
      lens: Zoi.string(),
      steelman: Zoi.string(),
      strengths: Zoi.string(),
      blockers: Zoi.string()
    }, coerce: true)),
  tie_break_rung:
    Zoi.enum(["correctness", "grounding", "simpler-first", "validation-rollback", "cost"]),
  selection: Zoi.string(),
  verdict: Zoi.enum(["adopt", "hybrid", "revise_first"]),   # STRING enums — Envelope round-trip rule
  revision_directive: Zoi.string(),                          # "none" for adopt; seams/blockers otherwise
  signals: Zoi.optional(Zoi.array(Zoi.string())),
  artifacts: OutputSchema.artifacts()
})
```

**Registration** (all in the same change):

- `lib/jido_claw/agent/templates.ex` — three entries mirroring the system-template
  shape: `%{module: ..., description: ..., model: :fast, forward_context: :none,
  sandbox: :none, composer_private: true}`.
- `lib/jido_claw/persona.ex` — `@template_persona`: `"plan_drafter" =>
  "detective"` (planner-class voice; lens is task bias, not persona),
  `"plan_challenger" => "skeptic"`, `"plan_arbiter" => "arbiter"`; moduledoc
  counts 13→16.
- `lib/jido_claw/doctrine.ex` — `@template_slices`: `"plan_drafter" => [:base,
  :artifacts, :confidence_tagging]` (**no `:emit_signals`** — that slice names
  `plan-ready`, which a lens stage must never emit), `"plan_challenger" => [:base,
  :artifacts, :challenger_contract, :confidence_tagging]`, `"plan_arbiter" =>
  [:base, :artifacts, :tie_break, :confidence_tagging]`.

**Tests (red first)**: `templates_test.exs` count bumps 13→16 + refactor the
composer-private checks **table-driven**: iterate `Templates.list()` entries where
`composer_private?/1`, asserting the shared invariants (resolvable,
`external_tools?/1` false, excluded from the public `@valid_names` loop), with
per-template field pins kept separate — so the next private template doesn't
re-grow bespoke blocks. `worker_output_schemas_test.exs` describe blocks per
worker (string-keyed `Output.parse` round-trip; `parsed.verdict == "adopt"` string
/ `parsed.status == :completed` atom; reject missing required fields for EACH new
schema — `summary`, `status`, `confidence`, `artifacts`, plus the arbiter-only
fields (`verdict`, `tie_break_rung`, `selection`, `revision_directive`,
`assessments`) and the challenger lists — aligning the tests with the fixture
shape guarantees; reject out-of-enum verdict; challenger + drafter regression
`refute Map.has_key?(parsed, :overall)`; drafter regression: parse drops an
unknown `"plan:smallest-shippable"` key — pins the summary-fallback reality the
stubs rely on).

### Step 2 — arbiter persona (the 10th) + stage-persona entries

**`priv/defaults/persona/arbiter.md`** (new; exactly four sections, no
frontmatter, matching the existing terse register):

```markdown
## Belief
Every serious plan is right about something. The best path is often a graft, not a winner.

## Drive
Decide. One plan forward, and the reason it won.

## Default move
Steelman each plan at its strongest, then weigh them on one ordered scale. Name the seam where a graft joins.

## Voice
Judicial. Weighs competing strengths out loud, then commits to a single call.
```

`lib/jido_claw/persona.ex`: add `arbiter` to `@persona_names` (the
`@external_resource` loop covers it); `@stage_persona` gains all 7 new stages —
the three `planner-<lens>` → `"detective"` (same as the base `planner` stage),
the three `challenger-<lens>` → `"skeptic"`, `"plan-arbiter"` → `"arbiter"`;
moduledoc "9 uniform persona files" → 10.

**Tests (red first)**: `persona_test.exs` — `render_for("plan-arbiter",
"plan_arbiter") =~ "## PSYCHOLOGY: Arbiter"` + `Persona.render("arbiter")`
non-empty (drift guards and the every-persona-renders loop cover the rest once
registries are consistent).

### Step 3 — doctrine slices: tie-break + challenger contract (+ Step 6's code-doctrine)

**`priv/defaults/doctrine/tie_break.md`** (new), anchor `## Plan arbitration` —
selector-not-critic discipline; steelman-first; the tie-break ladder with the
**exact enum token per rung** (aligns schema and prose — user finding):

```
1. `correctness` — correctness / request-fit: does it do what was asked, correctly;
2. `grounding` — anchored in the real codebase, not speculation;
3. `simpler-first` — the least machinery that works;
4. `validation-rollback` — validation / rollback: can it be checked and undone;
5. `cost` — token / time cost.
```

"Record the deciding rung in `tie_break_rung` using exactly one of those tokens;
higher wins — never drop to a lower rung while a higher one separates the plans."
Verdict semantics (`adopt` — one plan goes forward as written / `hybrid` — graft
with every seam named / `revise_first` — name the blocking critiques the redraft
must resolve); closes with: the memo is read by the planner that writes the final
plan and preserved as a run artifact — make the selection, deciding rung, and
seams/blockers explicit and self-contained in the summary; you do not publish the
plan yourself. **No "emit your completion signal" language** — the arbiter emits
no gating signal (artifact-driven sequencing).

**`priv/defaults/doctrine/challenger_contract.md`** (new), anchor
`## Plan critique (critique only)` — critique ONE plan drafted under a stated
bias; never rewrite/pick/approve (a separate arbiter selects); three lists with
the quality bar: blockers (unsafe/unworkable as written, each with a concrete
consequence), concerns (real non-disqualifying risks), strengths (steelmanning is
part of the job); "two real blockers beat eight noisy ones"; never publish a
plan-approval signal.

`lib/jido_claw/doctrine.ex`: `@tie_break_priv` + `@challenger_contract_priv` (+
`@external_resource` lines) + `@slices` entries, wired per Step 1's
`@template_slices`.

**Tests (red first)**: `doctrine_test.exs` — add both keys to the `slice/1`
non-empty list and the `list/0` exact set; new `for_template` tests:
`plan_arbiter` =~ "Plan arbitration"/"Runtime artifacts"/"Confidence tagging",
refute "Review discipline"; `plan_challenger` =~ "Plan critique", refute
"Reviewer Contract"; `plan_drafter` =~ "Runtime artifacts", **refute the
emit-signals anchor** ("Emitted signals") — pins deviation (c)'s reason.
`subagent_prompt_test.exs` — `build("plan_arbiter", ctx, "plan-arbiter")` asserts
`## PSYCHOLOGY: Arbiter` + `## DOCTRINE` + "Plan arbitration" reach the assembled
prompt; a `plan_drafter` case asserting its doctrine **omits** "plan-ready".

### Step 4 — triage arming field + front-door seeding swap

Mirror the `intent_confirmed?` precedent exactly:

- `lib/jido_claw/triage/verdict.ex`: struct default `multi_plan?: false`, type
  `boolean()`, `from_map` coercion `get(out, :multi_plan) == true`.
- `lib/jido_claw/triage/schema.ex`: `"multi_plan" => Zoi.optional(Zoi.boolean())`.
- `lib/jido_claw/triage/prompt.ex`: new advisory section after `## est_size` —
  set true ONLY on a significant build whose DESIGN SPACE is wide (several
  materially different architectural approaches, not stylistic variants); wide
  design space is the positive signal; never the default.
- `lib/jido_claw/front_door.ex` (code/system `seed_live` clause only; sketch/
  exec/degraded clauses and `build_premises` and `@signal_topics` unchanged —
  `multi-plan` is seeded literally, never mapped, so the conjunction can't be
  bypassed via the signals list):

```elixir
defp seed_live({:plain, _scope, _premises}, %Verdict{path: path} = verdict),
  do: Enum.uniq(["request-received", to_string(path), planning_seed(verdict)] ++ mapped_signals(verdict))

defp planning_seed(verdict), do: if(armed?(verdict), do: "multi-plan", else: "plan-needed")

# The ONE place arming is decided (triage-only, no kill-switch).
defp armed?(%Verdict{multi_plan?: true, signals: signals}), do: :significant_build in signals
defp armed?(_verdict), do: false
```

**Tests (red first)**: triage verdict/schema tests (`multi_plan` defaults false;
coerces only literal true — mirror `intent_confirmed?`/atom-safe tests);
`front_door_test.exs` with the TriageStub canned-verdict pattern — **all three
conjunction cells**: armed verdict (path :code, `multi_plan?: true`, signals incl.
`:significant_build`) seeds `multi-plan` and NOT `plan-needed`; `multi_plan?`
without `significant_build` seeds `plan-needed` (arming denied); and
`significant_build` without `multi_plan?` seeds `plan-needed` (the other half —
user finding).

### Step 5 — catalog: 7 new stages + planner edit + triage publishes

`lib/jido_claw/route_composer/catalog.ex`. All new stages: `routes: ["code",
"system"]` (match the finalizer planner), `lens: nil`, `publishes:
["scope-shift"]` ONLY (invariant 2; no advisory signals — artifact-driven
sequencing, deviation c). Compile-time validation (CatalogValidator + template
existence) enforces coherence. Task strings avoid artifact-key/signal mechanics —
the worker's summary IS the artifact.

Three lens planners over `plan_drafter` (per lens ∈ smallest-shippable |
risk-first | reuse-first; task biases: "the least code that ships real value" /
"attack the hardest unknowns before the easy work" / "lean on existing modules
and patterns over new code"):

```elixir
"planner-<lens>" => %Stage{
  name: "planner-<lens>",
  unit: {:worker_template, "plan_drafter"},
  task: "Draft the <bias> implementation plan for the confirmed intent — <bias detail>. Yours is one of several competing plans; an arbiter selects.",
  routes: ["code", "system"],
  subscribes: ["multi-plan"],
  input: %{required: ["intent"], optional: []},
  output: ["plan:<lens>"],
  publishes: ["scope-shift"]
},
```

Three challengers over `plan_challenger`:

```elixir
"challenger-<lens>" => %Stage{
  name: "challenger-<lens>",
  unit: {:worker_template, "plan_challenger"},
  task: "Critique ONLY the <lens> plan — surface blockers, concerns, and strengths for the arbiter; never approve or select.",
  routes: ["code", "system"],
  subscribes: ["multi-plan"],
  input: %{required: ["plan:<lens>"], optional: []},
  output: ["critique:<lens>"],
  publishes: ["scope-shift"]
},
```

The arbiter (PR-4: first tier declarer; task uses the enum tokens):

```elixir
"plan-arbiter" => %Stage{
  name: "plan-arbiter",
  unit: {:worker_template, "plan_arbiter"},
  task:
    "Select or graft the best plan across the three plans and their critiques — steelman " <>
      "each; tie-break correctness > grounding > simpler-first > validation-rollback > " <>
      "cost; write a decision memo naming one verdict (adopt|hybrid|revise_first), the " <>
      "selection, and the deciding rung.",
  model: :capable,
  effort: :high,
  routes: ["code", "system"],
  subscribes: ["multi-plan"],
  input: %{required: ["plan:smallest-shippable", "plan:risk-first", "plan:reuse-first",
                      "critique:smallest-shippable", "critique:risk-first", "critique:reuse-first"],
           optional: []},
  output: ["decision-memo"],
  publishes: ["scope-shift"]
},
```

Planner (finalizer) edit — `"multi-plan"` appended LAST in subscribes (unarmed
`triggered_by` stays `"plan-needed"`; armed-reject still matches `"plan-rejected"`
first); optional inputs include the **critiques** so "redraft per the critiques"
is honest (user finding — `ArtifactContext` forwards only named inputs):

```elixir
subscribes: ["plan-needed", "plan-rejected", "multi-plan"],
input: %{required: ["intent"],
         optional: ["decision-memo",
                    "plan:smallest-shippable", "plan:risk-first", "plan:reuse-first",
                    "critique:smallest-shippable", "critique:risk-first", "critique:reuse-first"]},
task:
  "Draft an implementation plan from the confirmed intent; emit plan-ready. With a " <>
    "decision-memo present, reproduce the adopted plan faithfully, graft per a hybrid " <>
    "memo, or redraft per the critiques on revise_first.",
```

Triage stage: add `"multi-plan"` to `publishes` (invariant 3 — every subscribed
topic needs a declared publisher; not in `@signal_topics`, never auto-seeded).
Plan-gate: **byte-identical, no edit**. Update the catalog moduledoc's stage
narrative if it enumerates stages.

**Tests (red first)**: `catalog_test.exs` — starter catalog validates clean
(compile gate); pin each new stage's contract in the existing "stage is pinned"
style; `plan-arbiter` pins `model: :capable, effort: :high`; the whole-catalog
to_map/from_map round-trip auto-covers the tier. `router_test.exs` — armed seed
(`["request-received","code","multi-plan","significant-build"]`, ran `triage`,
available `request`/`intent`) composes `[[3 lens], [3 challengers],
["plan-arbiter"], ["planner"]]` in ONE pure compose; unarmed seed keeps the
planner at level 0 with the 7 new stages untriggered (byte-identity guard).

### Step 6 — item-4 `code-doctrine` slice (severable)

The source's actual `doctrine/code-doctrine.md` text is not in-tree (only the
pattern: "authored once, injected into every producer"); author fresh.

**`priv/defaults/doctrine/code_doctrine.md`** (new), anchor `## Code craft` —
five bullets: match what's there (conventions/naming/structure; no new style,
dependency, or abstraction where the existing one works); don't refactor around
the task; handle the error paths (guard real inputs, never swallow errors
silently); no dead weight (no commented-out code, unused bindings, debug prints);
leave it verifiable (prefer test-exercisable code; changed behavior keeps tests
truthful).

Targeting (`doctrine.ex` `@template_slices`): add `:code_doctrine` to **coder**
(implementer + test-author both ride it), **fixer**, **refactorer**. Excluded
with reasons: sketch_build/sketch_build_exec (throwaway tracer-bullets — craft
fights their speed purpose), system_executor (machine/config changes, not
application code), docs_writer/researcher/plan_drafter/plan_arbiter/
plan_challenger (write no code).

**Tests (red first)**: `doctrine_test.exs` — `:code_doctrine` in `slice/1` +
`list/0` (final exact set, 11 slices: artifacts, base, challenger_contract,
code_doctrine, confidence_tagging, emit_signals, fixer_contract,
reviewer_contract, reviewer_min, system_verify, tie_break); coder/fixer/
refactorer `for_template` =~ "Code craft"; reviewer/researcher refute it.

### Step 7 — composer e2e tests (stubs + fixtures)

**Stubs are FULLY schema-shaped** (user findings, both rounds: Zoi drops unknown
keys on real runs, and the stub path stamps `meta.output.status: :validated`
bypassing Zoi — so stubs must carry exactly the fields the real schemas produce:
every required field with an empty/default value, and NO dynamic artifact keys).
The e2e **asserts each stored artifact equals the canned summary** (pins the
summary-fallback path). No `signals` keys anywhere — a canned `plan-ready` on the
shared researcher map would be undeclared on any future drafter reuse, but the
governing reason is determinism: `scope-shift` IS declared on all seven new
stages, and a canned one would trigger real rescope behavior mid-e2e; the
finalizer's `plan-ready` is loop-injected, so no stub needs a signal:

```elixir
# bind the base drafter shape first — the per-stage overrides below merge from it
drafter_stub = %{
  "summary" => "PLAN (lens draft): a competing plan.",
  "status" => "completed",
  "confidence" => "high",
  "artifacts" => %{}
}

%{
  "researcher" => %{                    # the finalizer planner only — full researcher shape
    "summary" => "PLAN (final): adopt Plan A, smallest-shippable.",
    "status" => "completed",
    "confidence" => "high",
    "findings" => [],
    "artifacts" => %{}
  },
  "plan_drafter" => drafter_stub,       # template-key fallback for lens stages
  # per-stage overrides (distinct plans, so the finalizer-context assertion can
  # prove three meaningfully different plans arrive). Each override is built by
  # MERGING the base "plan_drafter" stub with the distinct summary —
  # `Map.put(drafter_stub, "summary", "PLAN A: ...")` — so overrides stay fully
  # schema-shaped by construction and can never drift back to partial shapes:
  {"plan_drafter", "smallest-shippable"} => Map.put(drafter_stub, "summary", "PLAN A: minimal viable slice."),
  {"plan_drafter", "risk-first"} => Map.put(drafter_stub, "summary", "PLAN B: de-risk the hard part first."),
  {"plan_drafter", "reuse-first"} => Map.put(drafter_stub, "summary", "PLAN C: reuse the existing pipeline."),
  "plan_challenger" => %{               # serves all 3 challenger stages — full shape
    "summary" => "CRITIQUE: blockers/concerns/strengths.",
    "status" => "completed",
    "confidence" => "high",
    "blockers" => [],
    "concerns" => ["over-scoped"],
    "strengths" => ["reuses tested code"],
    "artifacts" => %{}
  },
  "plan_arbiter" => %{                  # full memo shape
    "summary" =>
      "DECISION MEMO — verdict: adopt. Selected Plan A (smallest-shippable). Tie-break: correctness.",
    "status" => "completed",
    "confidence" => "high",
    "assessments" => [],
    "tie_break_rung" => "correctness",
    "selection" => "smallest-shippable",
    "verdict" => "adopt",
    "revision_directive" => "none",
    "artifacts" => %{}
  }
}
```

Per-stage override mechanism (test-support only — `tool_context` carries
`:agent_template` but not the stage name, verified agent_runner.ex:77): extend
`StubWorker.ask/3`'s lookup with `{template, task_fragment}` tuple keys.
**Matching must be deterministic and loud** (the fragment stands in for stage
identity): when any `{template, _}` tuple keys exist for the resolved template,
exactly ONE fragment must match the task — zero or multiple matches `raise`
(never silently fall back or pick one, which would feed the wrong plan to the
mapper and quietly weaken the e2e). Only when NO tuple keys exist for the
template does the lookup fall back to the plain template key — so plain-keyed
existing tests are untouched.

The revise_first variant differs ONLY in the arbiter map (summary/verdict/
directive) — and routes IDENTICALLY (the assertion that pins "no verdict-driven
routing").

**Parser+mapper weld tests** (user finding — the e2e stubs enter AFTER parsing,
so pin the real parser + mapper together): in the DefaultMapper test file
(alongside existing mapper tests; create if absent), for each new worker shape —
`Output.parse(output_for(Worker), sample)` → build the `%StepResult{}` the way
`agent_runner` does (`result` = summary) → `DefaultMapper.map/2` with a literal
stage meta → assert the emission's `plan:<lens>` / `critique:<lens>` /
`decision-memo` artifact **equals the parsed summary**, and no signals are
emitted. Depends only on Step 1's workers (stage metas are literals).

**Tests (red first)**, real `Catalog.all()` + template override extended to the
three new templates, `max_waves: 15`:

- `composer_loop_test.exs`: armed adopt e2e — armed seed (mimic front-door: live
  incl. `multi-plan` + `significant-build`, no `plan-needed`) → 4 planning waves
  → gate parks → `Cases.decide(:approve)` → implementer/reviewers → converge;
  assert `decision-memo`/`plan:<lens>`/`critique:<lens>` artifacts present with
  the right producers AND **values equal to the producing stage's canned
  summary** (the three plan:<lens> values distinct, per the overrides); `plan`
  produced by `"planner"`. Second test: the finalizer's captured task/context
  (`:route_composer_capture_context`/`_task` hooks) carries the decision-memo
  section plus all three DISTINCT plan:<lens> summaries and the critique:<lens>
  sections; the revise_first variant routes identically. Third: a blocked lens
  planner (`"status" => "blocked"`) ⇒ `:route_failed`.
- `composer_durable_test.exs`: armed human-reject — `Cases.decide(:reject)` ⇒
  `stages_invalidated` payload `stages == ["planner"]` (rerun set excludes lens/
  challengers/arbiter), then re-gate → approve → converge.

### Step 8 — docs reconciliation (whole-entry sweeps)

Primary (this unit's inventory entries — flip every now-false claim, not just
status lines):

- `docs/plans/unadopted-next-five/README.md` item 3: PR-3/PR-4 **DONE 2026-07-02**
  blockquote in the established style, including corrections to the entry's own
  claims: (a) planner-finalizes replaced sketch step 5's arbiter→gate (no
  verdict-driven routing; hybrid/revise_first do NOT ride `plan-rejected`); (b)
  the gate presents the finalized plan, memo stays an inspectable artifact; (c)
  lens planners run a dedicated `plan_drafter` template, not the researcher —
  the researcher's role/doctrine name `plan-ready`, undeclared on lens stages
  under strict emit checking; no `plan-drafted:<lens>` signals exist; (d) the
  PR-1/PR-2 note's "no catalog stage declares a tier yet" is now historical.
  Item 4: slice DONE, READ_MAP still deferred; "mirroring the existing 8 slices"
  → current count.
- `docs/exploration/alp-river/UNADOPTED-IDEAS.md`: table rows #2/#5 + entry #2
  (shipped, with deviations a-c) + entry #5 (slice half done) + #1/#3 standing
  lines ("no catalog stage declares a tier" → arbiter declares; "13 templates ...
  uniformly :fast" → 16, arbiter stage runs :capable) + ":99 16-stage catalog"
  → 23.
- `docs/exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md`: TL;DR AR-9 row;
  gap paragraph (":90 strictly single-plan", ":92 no arbiter/no multi-plan/no
  lens-parameterized planner", ":95 9 personas, no arbiter"); ":128-133 first
  declarer" claims; adoption sketch steps annotated shipped-with-deviations
  (incl. step 2's `plan-drafted:<lens>` signals — not adopted); ":196 (16
  stages)" → 23; ":329 arbiter persona rides AR-9" → shipped; ":255 AR-11
  plan-arbiter reads N plans" now describes a real stage.
- `AGENTS.md:87`: "all 13 worker templates" → 16; "No catalog stage declares a
  tier yet, so behavior is unchanged today" → the `plan-arbiter` stage now
  declares `model: :capable, effort: :high` (PR-4).
- `lib/jido_claw/persona.ex` moduledoc counts (9→10 personas, 13→16 templates);
  `lib/jido_claw/route_composer/stage.ex` `:model`/`:effort` moduledoc "no
  declarer yet" phrasing if present.

Adjacent (dated one-line annotations, not rewrites — V1 is a closed ledger):
sweep `rg -n "13 worker|16 stages|9 persona|no catalog stage declares|multi-plan|plan-arbiter|8 slices|single-plan" lib/ docs/ AGENTS.md test/` and annotate every
now-false restatement — known hits: `FEATURES-WORTH-BORROWING.md` (V1)
:12/:50-59/:131/:737/:754/:771/:923, `AR-2-COMPOSER-PLAN.md:1029`,
`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` :129/:408-417, ouroboros/
camus FEATURES "AR-9 pending" lines.

## Precommit-risk register

- **Envelope/Zoi**: verdict + tie_break_rung are STRING enums (persisted-adjacent);
  status/confidence stay atom enums (never artifact names) — mirrors researcher.
  Map-form `Zoi.object(%{...})` only; nested objects `coerce: true`.
- **ExSlop clones**: all three new workers are schema-only (no defps), like
  reviewer.ex; doctrine additions are module attributes, not defps. Watch the
  three near-identical worker modules — schemas differ enough (drafter is lean,
  challenger has the three lists, arbiter the memo fields) that no contiguous
  defp clone family exists.
- **reach**: registration adds data entries only; no forwarder defps; stub
  outputs are map literals in existing fixture files (reach scans test/support).
- **credo strict**: `@moduledoc false` on the workers (house style);
  front_door/persona/doctrine moduledoc updates where counts change; no TODOs.
- **Drift guards**: templates/doctrine/persona registries + the 7 catalog stages
  + `@stage_persona` keys must be consistent at every test run — land Steps 1-3+5
  before running the full suite (single working-tree unit).
- **Undeclared-signal trap**: NO canned `signals` keys in any stub map; all seven
  new stages publish only `scope-shift`; the finalizer's `plan-ready` is
  loop-injected.
- **forward_context: :none** on composer-private templates is proven by
  system_executor; fallback to `:public` if wave context regresses (still
  composer-private).
- Known flake: `MemoryExportTest` (capture_log race in full suite) — rerun in
  isolation if it trips; do not chase.

## Verification

1. Red-first per step: run each new/changed test file directly, confirm red for
   the right reason, then green after the step's code change.
2. Byte-identity guards green: unarmed router compose (7 stages untriggered,
   planner level 0), unarmed front-door seeding (`plan-needed`), existing
   catalog/loop/durable/persona/doctrine tests untouched-green.
3. `mix precommit` — run bare, read its own verdict lines, report exact exit code
   and test counts verbatim.
4. `git status --short` — nothing staged, no commits; the pre-existing untracked
   `docs/exploration/{gepa,osa,osa-claude-code,optimal-engine}/` dirs stay
   untouched.

## Files touched

| File | Change |
| --- | --- |
| `lib/jido_claw/agent/workers/plan_drafter.ex`, `plan_challenger.ex`, `plan_arbiter.ex` | **new** schema-only workers |
| `lib/jido_claw/agent/templates.ex` | 3 composer-private entries |
| `lib/jido_claw/persona.ex` | `arbiter` persona name, 3 template + 7 stage entries, moduledoc counts |
| `lib/jido_claw/doctrine.ex` | 3 new slices registered + targeting (drafter/arbiter/challenger/coder/fixer/refactorer) |
| `priv/defaults/persona/arbiter.md` | **new** persona |
| `priv/defaults/doctrine/tie_break.md`, `challenger_contract.md`, `code_doctrine.md` | **new** slices |
| `lib/jido_claw/triage/{verdict,schema,prompt}.ex` | `multi_plan?` field + arming rule |
| `lib/jido_claw/front_door.ex` | `planning_seed/1` + `armed?/1` conjunction guard |
| `lib/jido_claw/route_composer/catalog.ex` | 7 new stages, planner edit, triage publishes |
| `test/support/jido_claw/route_composer/{composer_stubs,fixtures}.ex` | fully schema-shaped armed stub outputs, `{template, task_fragment}` per-stage override lookup, template override extension |
| tests: `templates_test`, `worker_output_schemas_test`, `persona_test`, `doctrine_test`, `subagent_prompt_test`, `catalog_test`, `router_test`, `composer_loop_test`, `composer_durable_test`, `front_door_test`, triage tests | per-step red-first additions + count updates |
| `docs/plans/unadopted-next-five/README.md`, `docs/exploration/alp-river/{UNADOPTED-IDEAS,FEATURES-WORTH-BORROWING-V2,FEATURES-WORTH-BORROWING,AR-2-COMPOSER-PLAN}.md`, `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`, ouroboros/camus FEATURES, `AGENTS.md` | whole-entry reconciliation + dated annotations |
