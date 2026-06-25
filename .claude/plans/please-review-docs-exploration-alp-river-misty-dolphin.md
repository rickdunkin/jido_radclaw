# Finish AR-3 — Reviewer Contract content + schema enrichment + confidence tagging

## Context

AR-3 ("Reviewer fan-out + a shared Reviewer Contract", `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md:388`)
is **PARTIAL**. The 4-lens fan-out is already built: the composer catalog
(`lib/jido_claw/route_composer/catalog.ex:131-179`) instantiates the single
`reviewer` worker template as four risk-gated lenses (security / quality /
correctness / architecture), each emitting `findings:<lens>` / `clean:<lens>` and
dispatched as one parallel Kahn wave. The shared-contract **mechanism** already
rides AR-5 (the `reviewer` template maps to the `reviewer_min` doctrine slice,
auto-injected into every sub-agent turn).

What's missing is the contract's **content**: `priv/defaults/doctrine/reviewer_min.md`
is a 6-line placeholder that literally says *"A fuller review contract may be
supplied separately."* The concrete-consequence bar, the anti-double-flag rule,
and the VERDICT/FINDINGS/ACTION_NEEDED shape are unwritten, and the structured
verdict schema carries no confidence tag or location.

**Decisions taken (confirmed with the user):**
- **Schema enrichment, not prose-only.** Enrich `reviewer_verdict/0` with the
  literal shape (per-finding `confidence` + `location`, top-level `action_needed`),
  in addition to authoring the prose contract.
- **Fold confidence tagging in now.** Add the `likely`/`unsure` per-finding tag and
  its reporting threshold as part of AR-3 (this also lands AR-7's core for the
  reviewer surface).

**Intended outcome:** every reviewer lens shares one enforced, single-sourced
contract — a clear verdict, findings that each name a concrete observable
consequence with a confidence tag and a location, an explicit action list, and the
anti-double-flag / concrete-consequence discipline — delivered through the existing
AR-5 doctrine seam with no new plumbing, and `mix precommit` green.

## Critical constraint discovered during review (drove two design choices)

The composer stores the `findings` artifact through
`JidoClaw.Orchestration.ComposerArtifact.Envelope.normalize/1`
(`lib/jido_claw/orchestration/composer_artifact/envelope.ex:91`), which is the
**shared no-novel-atom normalizer** also used inline by `DefaultMapper`
(`default_mapper.ex:167`). It `inspect/1`s every atom **value** (proven by the
existing test assertion `:nested_value` → `":nested_value"`,
`default_mapper_test.exs:125`). Therefore an **atom-valued** Zoi enum
(`Zoi.enum(likely: "likely")` parses to the atom `:likely`) would be stored as the
string `":likely"` — colon and all — not `"likely"`. (The existing `severity` field
has this exact latent wart; its mapper test masks it by feeding string values.)

Consequences, baked into the plan below:
1. **Stored finding fields use string-valued enums.** `severity` and `confidence`
   become `Zoi.enum(["info","warning","error"])` / `Zoi.enum(["likely","unsure"])`,
   which parse to **strings** (confirmed: `Zoi.enum(["red"])` → `{:ok, "red"}`,
   `deps/zoi/lib/zoi.ex:1956`). They pass through `normalize/1` unchanged, so the
   stored artifact reads `"error"`/`"likely"`. `overall` stays an **atom** enum — it
   drives signal logic via the mapper's dual-form `@verdicts`/`approve?` and is
   never written to an artifact. Converting `severity` to a string enum is safe: no
   `lib/` code matches finding `severity`/`confidence` as an atom (swept).
2. **The mapper test must exercise atom-keyed parsed output**, not only string maps,
   so it actually covers the normalize path.

## Approach

Two doctrine slices (principled split by *reach*) + one enriched schema + three
worker descriptions realigned to it + the doctrine template-map update + tests.
The split exists because `reviewer_min` is shared by **four** read-only judges —
`reviewer`, `sketch_reviewer`, `system_verifier`, **and `verifier`** — but
`verifier` uses a *different* output schema (`verdict: :pass/:fail` + `confidence`
+ `reasoning`, `lib/jido_claw/agent/workers/verifier.ex:27-31`), so the
field-shape contract must not be injected into it.

- **`reviewer_min.md` (expanded) → universal judging discipline**, reaches all four
  judges. Field-agnostic: judge only what you can see, keep correctness vs. style
  separate, state a clear verdict, the **concrete-consequence bar**, the
  **anti-double-flag rule**, no padding / no style-as-bugs / no speculation. (Keeps
  a heading containing "Review discipline" for test continuity.)
- **`reviewer_contract.md` (new) → the structured-verdict shape + confidence**,
  reaches only the three `reviewer_verdict/0` workers (`reviewer`,
  `sketch_reviewer`, `system_verifier`). Names `overall`/`findings`/`action_needed`,
  the per-finding fields, the `likely`/`unsure` definitions, and the reporting
  threshold.

**No mapper logic change.** `DefaultMapper.reviewer_verdict/3`
(`default_mapper.ex:74-83`) only inspects `overall` (approve?) and `findings == []`,
then passes the whole findings list through `coerce/1`. New finding keys ride along.
**Clean-approve behavior is preserved exactly:** it emits the `clean:<lens>` signal
**and** an empty `%{"findings" => []}` artifact (the stage's `output: ["findings"]`
is merged after the empty verdict artifacts — `default_mapper.ex:55`; asserted at
`default_mapper_test.exs:46`). This plan introduces no mapper behavior change.

## Files & changes

### 1. Schema — `lib/jido_claw/agent/workers/output_schema.ex`

Enrich `reviewer_verdict/0` (lines 38-54). New fields are **required** (Zoi object
keys are required by default; `Zoi.optional/1` is the opt-out, already used for
`artifacts` at lines 25-27) so the contract is enforced; a single repair attempt
(`retries: 1, on_validation_error: :repair`) can recover a transient omission. Use the
**keyword-list `Zoi.object([...])` form** so the generated JSON schema preserves
property order (matching the prose contract for the LLM — the reviewer confirmed via
Tidewave that keyword lists preserve `propertyOrdering`); verify parse parity with
the existing map form during implementation:

```elixir
def reviewer_verdict do
  Zoi.object(
    [
      overall: Zoi.enum([:approve, :request_changes, :comment]),
      summary: Zoi.string(),
      action_needed: Zoi.string(),
      findings:
        Zoi.array(
          Zoi.object(
            [
              severity: Zoi.enum(["info", "warning", "error"]),
              confidence: Zoi.enum(["likely", "unsure"]),
              location: Zoi.string(),
              description: Zoi.string()
            ],
            coerce: true
          )
        )
    ]
  )
end
```

Key points: `severity`/`confidence` are **string** enums (parse to clean strings,
store without the `:` prefix); `overall` stays an **atom** enum (mapper control,
unstored). Sentinels documented in the contract prose: `action_needed: "none"` on a
clean approve; `location` may name a file/area when a finding is not line-specific.

### 2. New slice — `priv/defaults/doctrine/reviewer_contract.md`

Authored content (draft to refine during implementation), adapted from Alp River's
`doctrine/reviewer-contract.md` + `confidence-tagging.md` to jido_radclaw's field
set and verb set (approve/request_changes/comment, not pass/fail/warn):

```markdown
## Reviewer Contract (structured verdict)

Your structured output is the contract every reviewer lens shares.

**Verdict (`overall`).** `approve` when the change is sound and nothing clears the
concrete-consequence bar; `request_changes` when at least one finding must be
addressed before the change is safe to keep; `comment` for non-blocking
observations worth surfacing. An `approve` with an empty `findings` list signals a
clean lens.

**Findings.** Each finding carries:
- `severity` — `info` | `warning` | `error`.
- `confidence` — `likely` (evidence-based: code you read, official docs, observed
  behavior) or `unsure` (judgment, single-source, or inferred). Both still hedge.
- `location` — the `path:line` the finding is about (the file or area when it is
  not line-specific).
- `description` — the concrete consequence and why it matters, stated plainly.

Order `likely` findings before `unsure`, and keep the list tight — surface the few
that matter, never pad to a count.

**Reporting threshold.** Report every `likely` finding. Report an `unsure` finding
only when its impact is high — correctness, security, or data risk. Drop
speculative low-impact `unsure` items.

**Action needed (`action_needed`).** State the specific fix(es) the change needs,
or `none` when the verdict is `approve` with no blocking findings.
```

### 3. Expanded slice — `priv/defaults/doctrine/reviewer_min.md`

Replace the placeholder with field-agnostic universal discipline (keep a "Review
discipline" heading). Draft:

```markdown
## Review discipline

You are judging a change, not rewriting it. Judge only what the diff or code in
front of you actually shows — never assume behavior you cannot see, and never flag
code you do not understand (ask or skip; do not speculate). Keep correctness
concerns separate from style ones, and state a clear verdict.

**Concrete-consequence bar.** A finding clears the bar to report only when you can
name a concrete, observable consequence — a wrong result, an unhandled error path,
a contract mismatch, a security or data-loss risk. "This could be cleaner", naming
taste, and strength-of-argument preferences do not clear it; they are out of scope,
not low-severity findings.

**Do not double-flag.** Do not flag an issue that a guard, middleware, validation,
or framework default *outside* the diff already fully handles before the touched
code runs. (A defect in the code you are reviewing still counts when that code is
reachable around or before the upstream defense.)

Two real findings beat eight noisy ones. Be concise.
```

(`.md` slices are **not** touched by `mix format` — `.formatter.exs:20` inputs are
`.ex`/`.exs`/config only — so hand-wrap to ~80 columns to match the sibling slices.)

### 4. Doctrine registry — `lib/jido_claw/doctrine.ex`

- Add `@reviewer_contract_priv` (mirror the existing `@reviewer_min_priv`
  `Path.join` block, lines 14-21), `@external_resource @reviewer_contract_priv`
  (after line 35), and `reviewer_contract:` in `@slices` (after line 41).
- In `@template_slices` (lines 50-71), append `:reviewer_contract` to the three
  `reviewer_verdict/0` templates; **leave `verifier` on `[:base, :reviewer_min]`**:
  - `"reviewer" => [:base, :reviewer_min, :reviewer_contract]`
  - `"sketch_reviewer" => [:base, :reviewer_min, :reviewer_contract]`
  - `"system_verifier" => [:base, :reviewer_min, :reviewer_contract, :system_verify]`
- Update the explanatory comments (lines 46-49, 65-69) to describe the split.

`Doctrine.for_template/1` / `slice/1` and the whole AR-5 injection path
(`Agent.SubagentPrompt.build/2`, `Startup.inject_subagent_prompt/3`) need **no
change**. `template_names()` is unchanged (same 12 keys), so the drift guards hold.

### 5. Worker descriptions — realign to the enriched shape

Extend the `description:` one-liner in the three `reviewer_verdict/0` workers (it is
also the `# Role` line) to mention `confidence`, `location`, and `action_needed`:
- `lib/jido_claw/agent/workers/reviewer.ex:7-8`
- `lib/jido_claw/agent/workers/sketch_reviewer.ex:19`
- `lib/jido_claw/agent/workers/system_verifier.ex:20`

(`verifier.ex` untouched — different schema.)

### 6. Tests & test-support

- **`test/jido_claw/doctrine_test.exs`**
  - Add `:reviewer_contract` to the slice-key list (line 13) and the `list/0` sorted
    expectation (line 24 → `[:artifacts, :base, :reviewer_contract, :reviewer_min,
    :system_verify]`).
  - `reviewer` / `sketch_reviewer` / `system_verifier` blocks (lines 37-51, 69-76):
    keep `=~ "Review discipline"` (+ system_verifier's `=~ "System verification
    discipline"`); add `=~ "Reviewer Contract"` and a confidence marker (`=~
    "likely"`); update test names/comments.
  - **Add a `verifier` test**: `=~ "Review discipline"` but `refute =~ "Reviewer
    Contract"` and `refute =~ "Runtime artifacts"`.
- **`test/jido_claw/agent/workers/worker_output_schemas_test.exs`** — for Reviewer
  / SketchReviewer / SystemVerifier (lines 155-202, 263-297): add `action_needed`
  (top-level) and per-finding `confidence` + `location` to the payloads; **change
  the severity assertions from atom to string** (`finding.severity == "info"`/`==
  "error"`, lines 168, 200, 291 — now string enums) and add
  `finding.confidence == "likely"`, `finding.location == ...`, `parsed.action_needed
  == ...`. Clean-approve payloads add `action_needed: "none"` (no per-finding
  fields — empty findings).
- **`test/jido_claw/route_composer/default_mapper_test.exs`** (the EXISTING mapper
  test — note: at `route_composer/`, not `route_composer/emit/`):
  - Keep the clean-approve case and its `%{"findings" => []}` assertion (line 46) —
    behavior preserved.
  - **Add** a case with **atom-keyed parsed-shape** typed output and a fully enriched
    finding (string enum values), asserting the stored `findings` artifact comes out
    as clean strings: `%{"severity" => "error", "confidence" => "likely", "location"
    => "lib/foo.ex:12", "description" => ...}` — this is the regression guard for the
    normalize/round-trip constraint above.
- **Test-support stubs** (raw canned `typed_output`, bypass schema validation, so
  they won't fail — update for realism per review):
  `test/support/jido_claw/route_composer/fixtures.ex:243,247-252`
  (`phase1_clean_reviewer`/`phase1_findings_reviewer`) and
  `test/support/jido_claw/route_composer/composer_stubs.ex:229-235` — add `summary`,
  `action_needed`, and per-finding `confidence` + `location` (string values).

## Out of scope (not deferrals — separate items / pre-existing)

- **AR-4 self-heal fixer loop.** The findings→fixer *signal* wiring already exists
  (the `fixer` stage subscribes `findings`, `catalog.ex:186`); the review→fix→
  re-review *loop* (RE_RUN_SET) is AR-4, NOT STARTED. AR-3 is complete without it.
  (Consequently `action_needed` is enforced in the verdict but **not** added to the
  reviewer stages' `output` list — nothing consumes it until AR-4 wires the fixer;
  keeping `output: ["findings"]` avoids speculative catalog churn. So AR-3 enforces
  `action_needed` in the verdict but does **not** persist it as a durable artifact;
  giving AR-4 a durable action list later means adding `action_needed` to each
  reviewer stage's `output` + a `publishes` mapping, a deliberate AR-4 change.)
- **`verifier`'s own confidence axis** (`:low/:medium/:high`) — untouched.
- **Pervasive AR-7** (confidence tags on `researcher` / web-sourced agents) — the
  reviewer-finding tag is AR-7's core folded into AR-3; extending it is a later step.
- **Per-lens criteria** already live in each stage's `task` string
  (`catalog.ex:135-137` etc.) — left as-is.

## Verification

1. **Compile** (recompiles `Doctrine` via `@external_resource`):
   `mix compile --warnings-as-errors`.
2. **Targeted tests:**
   - `mix test test/jido_claw/doctrine_test.exs`
   - `mix test test/jido_claw/agent/workers/worker_output_schemas_test.exs`
   - `mix test test/jido_claw/route_composer/default_mapper_test.exs`
   - `mix test test/jido_claw/startup_subagent_prompt_test.exs` (regression — should
     stay green; it does not pin reviewer body text).
3. **Manual eyeball via Tidewave** (`project_eval`):
   - `JidoClaw.Doctrine.for_template("reviewer")` shows base + discipline + Reviewer
     Contract; `for_template("verifier")` shows base + discipline only.
   - Parse a full sample through the worker's compiled output (note: `Output.parse/2`
     wants a `%Jido.AI.Output{}`, not a raw Zoi schema):
     `Jido.AI.Output.parse(JidoClaw.Agent.Workers.Reviewer.strategy_opts()[:output],
     full_sample)` returns `{:ok, _}` with the enriched fields and `severity`/
     `confidence` as **strings**; a payload missing `confidence` returns `{:error, _}`.
4. **Completion gate — full `mix precommit` with zero findings** (compile_check +
   format + credo + reach strict + tests; per project rule, run the whole gate, not
   compile+test alone). Watch: the 5th `@…_priv` attribute in `doctrine.ex` mirrors
   four existing single-line attributes (low ExSlop-clone risk, confirm). Do not pipe
   precommit through `tail`.

The plan is **not complete until `mix precommit` passes.** Nothing is committed —
all changes remain unstaged.
```