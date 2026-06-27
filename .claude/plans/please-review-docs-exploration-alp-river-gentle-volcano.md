# AR-7 — Confidence-tagging as a pervasive convention

## Context

AR-7 is the last open tail of the Alp River borrow backlog
(`docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` §AR-7, lines 656-689). Its
**reviewer-surface core already shipped** folded into AR-3: `reviewer_verdict/0` carries a
per-finding `confidence` (`likely`/`unsure`) string enum, and `priv/defaults/doctrine/reviewer_contract.md`
documents the tags + reporting threshold — reaching the three reviewer-family templates
(`reviewer`, `sketch_reviewer`, `system_verifier`).

What remains is the **pervasive** convention: there is no codebase-wide `[likely]`/`[unsure]`
claim-tagging beyond reviewer findings, `researcher` carries only a coarse top-level
`low|medium|high` confidence (no per-claim tag, no source-URL requirement for web-sourced
claims), and there is no standalone reach-all `confidence_tagging` doctrine slice. AR-7 closes
that with a single reach-all doctrine slice plus a structural per-finding tag on the one
non-reviewer surface that has a findings list (`researcher`). It rides the existing AR-5
doctrine seam — no engine or composer changes.

**Enforcement is honest about its two tiers** — this is *not* "every claim is machine-checked."
Of the **10** non-reviewer reach templates, the `likely`/`unsure` tag is **structurally enforced**
(a required Zoi enum) on exactly **one** — `researcher` findings — plus the reviewer family's
findings already (AR-3). For the other **nine** non-reviewer workers the slice is a
**prompt-enforced convention** on their prose output (`summary`/`notes`/`reasoning`) — their
schemas are producer/verdict shapes with no per-claim list to attach a field to. Machine-checking
everywhere would mean inventing a findings/claims list on those nine schemas; that is deliberately
out of scope (it is the "verifier prose-only" decision generalized).

**Decisions locked with the user:**
- **Reach** — the new slice reaches the **10 non-reviewer** sub-agent templates. The reviewer
  family already carries the equivalent via `reviewer_contract`, so it is excluded (avoids
  duplicating the contract and the content-overlap smell).
- **Main agent** — untouched. AR-7 stays on the sub-agent doctrine seam, consistent with
  AR-3/AR-5/AR-6; `priv/defaults/system_prompt.md` is **not** edited (no `.jido` re-copy).
- **Verifier** — receives the doctrine prose only; its flat `verdict`/`confidence`/`reasoning`
  schema is **not** changed (respects the deliberate "verifier has a different schema" boundary).

## Scope

| Surface | Change |
| --- | --- |
| New doctrine slice | `priv/defaults/doctrine/confidence_tagging.md` |
| Slice registry | `lib/jido_claw/doctrine.ex` — register + map to 10 templates |
| Researcher schema | `lib/jido_claw/agent/workers/researcher.ex` — per-finding `confidence` + description |
| Tests | `doctrine_test.exs`, `worker_output_schemas_test.exs` (+ fixture sweep) |
| Backlog doc | `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` — flip AR-7 PARTIAL → DONE (full sweep) |

Out of scope (by decision): the main-agent `system_prompt.md`, any verifier schema change, the
`verify_certificate` float (an unrelated trust-score), and any `DefaultMapper`/`Envelope` change
(researcher findings are not persisted as artifacts — its `planner` stage `output:` is `["plan"]`).

## Changes

### 1. New slice — `priv/defaults/doctrine/confidence_tagging.md`

Author deliberately **distinct** from `reviewer_contract.md` (which frames a *structured finding
field*); this slice frames *inline claim-tagging in prose* + the source-URL rule (which the
contract lacks). It must cover both forms because most of the 10 reach templates are prose-only
while `researcher` also has a structured per-finding field:

```markdown
## Confidence tagging

Mark each claim you make by its evidence basis:

- `likely` — you confirmed it: you read the code, ran it and observed the
  behavior, or have an authoritative source.
- `unsure` — it rests on inference, a single unconfirmed source, or a guess you
  have not verified. Say what would confirm it.

Use `likely`/`unsure` as a **per-claim or per-finding** evidence tag only. If a
finding in your output has its own `confidence` field, set it there. Otherwise tag
the claim inline in your prose — a summary, a note, your reasoning — as `[likely]`
or `[unsure]`. If your schema instead has an *overall* confidence field on a
different scale (for example `low`/`medium`/`high`), keep that field on its own
scale — never put `likely`/`unsure` in it — and tag your individual prose claims
inline. Default to `unsure` when you have not actually checked; a confident tone is
not evidence.

**Source your web claims.** Any claim drawn from a web page or search result must
carry its source URL beside it, so it can be re-checked.

**What to report.** Always surface `likely` claims that matter. Surface an `unsure`
claim only when it is decision-relevant — it changes what to do or flags a real
risk. Drop low-stakes guesses rather than padding your output.
```

This resolves the schema collision (P1): the tag is scoped to **per-claim/per-finding** use, and
the slice explicitly tells a worker with an *overall* `confidence` field on another scale
(`researcher`'s and `verifier`'s `low|medium|high`) to keep that scale and never emit
`likely|unsure` into it — so the slice can never nudge the LLM into a value those fields reject.
The header `## Confidence tagging` and `Source your web claims` are unique strings (neither
appears in `reviewer_contract.md`), so they serve as the test anchors below.

### 2. Register the slice — `lib/jido_claw/doctrine.ex`

Mirror the established 7-slice idiom exactly (this is the existing pattern, not a new clone):

- Add `@confidence_tagging_priv Path.join([__DIR__, "..", "..", "priv", "defaults", "doctrine", "confidence_tagging.md"])` (use `Path.join`, never `Path.expand` — `ExSlop.PathExpandPriv` bans it; doctrine.ex:11).
- Add `@external_resource @confidence_tagging_priv`.
- Add `confidence_tagging: String.trim(File.read!(@confidence_tagging_priv))` to `@slices` (doctrine.ex:68-76).
- Add `:confidence_tagging` to the **10 non-reviewer** entries of `@template_slices` (doctrine.ex:87-123):
  `coder`, `fixer`, `refactorer`, `docs_writer`, `researcher`, `test_runner`, `verifier`,
  `sketch_build`, `sketch_build_exec`, `system_executor`. **Leave the 3 reviewer-family
  entries** (`reviewer`, `sketch_reviewer`, `system_verifier`) **unchanged.** Update the
  block comment (lines 78-86) to note the new slice and why the reviewer family is excluded.

No change to `SubagentPrompt`, `Startup.inject_subagent_prompt`, or the three injection paths —
the slice flows through the existing `## DOCTRINE` section via `Doctrine.for_template/1`.

### 3. Researcher schema + description — `lib/jido_claw/agent/workers/researcher.ex`

Add a **required, string-enum** per-finding `confidence` inside the existing `findings` object
(researcher.ex:38-48), mirroring `OutputSchema.reviewer_verdict/0`'s string-enum precedent
(output_schema.ex:137-138 — string, not atom, so it round-trips clean if findings are ever
promoted to a stage `output:`):

```elixir
findings:
  Zoi.array(
    Zoi.object(
      %{
        topic: Zoi.string(),
        detail: Zoi.string(),
        references: Zoi.array(Zoi.string()),
        confidence: Zoi.enum(["likely", "unsure"])
      },
      coerce: true
    )
  ),
```

- Keep the top-level `confidence: Zoi.enum([:low, :medium, :high])` (researcher.ex:37) — it is a
  different axis (overall confidence in the plan/research), orthogonal to the per-claim evidence
  tag. The description must make the distinction explicit.
- The source-URL requirement reuses the **existing** `references` field (no new field) — enforced
  by prose (the doctrine slice + the description), since "web claim ⇒ non-empty URL" is not
  expressible as a static Zoi constraint.
- Update the `:description` (researcher.ex:7-8) so the LLM's output contract names both: each
  finding gets a `confidence` of `likely` (verified) / `unsure` (inferred or single source), and
  `references` carries source URLs for web-sourced claims.

`required` (Zoi default) matches the reviewer precedent and actually enforces the convention;
`retries: 1` + `on_validation_error: :repair` (already present) recover transient omissions.

### 4. Tests

**`test/jido_claw/doctrine_test.exs`** (closed-set assertions — these fail until updated):
- Add `:confidence_tagging` to the `slice/1` known-keys loop (lines 13-21).
- Add `:confidence_tagging` to the `list/0` exact sorted set (lines 32-40) — sorted position is
  after `:base`, before `:emit_signals`.
- In `for_template/1`: add `assert doctrine =~ "Confidence tagging"` to the non-reviewer cases
  that already exist (`coder`, `fixer`, `verifier`, `sketch_build_exec`, `system_executor`); add
  a new `researcher` case asserting the slice + `Source your web claims`; add
  `refute doctrine =~ "Confidence tagging"` to the three reviewer-family cases (`reviewer`,
  `sketch_reviewer`, `system_verifier`) to prove the exclusion. The reviewer family keeps its
  existing `=~ "likely"` (from `reviewer_contract`) — that is why the anchor is the unique
  header string, not `"likely"`.
- The registry-drift guard (lines 133-143) checks template **keys**, not slice contents — adding
  a slice to existing template lists does **not** trip it; no change needed there.

**`test/jido_claw/agent/workers/worker_output_schemas_test.exs`** (researcher describe, ~lines 105-160):
- **Required edit:** the existing researcher happy-path fixture builds a finding without
  `confidence` — add `"confidence" => "likely"` to it, else it regresses to `{:error, _}` once the
  field is required. Assert `finding.confidence == "likely"` (string).
- Add a required-field rejection test mirroring the reviewer idiom (lines 265-279): a finding
  **missing** `confidence` → `assert {:error, _} = Output.parse(output_for(Researcher), %{...})`.

**Fixture sweep (verification step, not a guaranteed edit):** grep `test/` for other researcher
findings fixtures (e.g. composer/integration tests that construct a researcher output map) and add
the per-finding `confidence`. Hermetic composer stubs bypass Zoi (researcher.ex:35) and are
unaffected.

### 5. Close the AR-7 backlog entry — `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md`

This change *completes* AR-7, so the doc must be reconciled — and a **full sweep**, not just the
one status line (every restatement of "AR-7 partial / not started / only AR-7 remains" goes stale
otherwise). `grep -n "AR-7" docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` and flip each
hit. The known locations (line numbers approximate, re-grep before editing):

- **The §AR-7 entry (≈656-689):** change the recommendation line from `PARTIAL` to `DONE`, and
  append a dated **Status update (2026-06-27): DONE** note describing what shipped (the
  `confidence_tagging` slice reaching the 10 non-reviewer templates; `researcher`'s per-finding
  `likely`/`unsure` tag + source-URL-in-`references` rule; verifier prose-only; main agent
  untouched), mirroring the prose style of the AR-6 status update (≈634-654).
- **The §AR-7 "Adoption sketch" sentence (≈675-677)** — "extend the Reviewer/Researcher/Verifier
  output schemas to carry the tag" — must be rewritten **directly**, not just superseded by a
  status line below it: it now contradicts the locked **verifier prose-only** boundary. Reword to
  what actually shipped — `researcher` gains the per-finding tag; `verifier` and the producers
  receive the doctrine slice but **no** schema change — so the sketch can't be read as still
  prescribing a verifier schema extension.
- **Status-reconciliation headers (≈27, ≈59) + their "remaining live backlog" lines (≈56-57,
  ≈118-120):** AR-7's pervasive extension is no longer remaining. Follow the doc's established
  stacking pattern — add a **new 2026-06-27 reconciliation section at the top that supersedes the
  2026-06-26 (AR-6) one** and records AR-7 DONE, rather than backfilling June 26. After it, the
  only remaining live backlog is AR-2's deferred tails (cluster lease, YAML catalog overlay).
- **Determination TL;DR (≈169-171), the capability table row (≈198), the AR-5 entry's forward
  references (≈556-557, ≈603-607), the "three layers" table (≈781), the bottom line (≈786-787,
  ≈815-826), and the sequencing item 5 (≈809-813):** each currently says AR-7 is partial / "only
  AR-7's pervasive extension remains" — reconcile to done.

(This mirrors how AR-6's completion was reconciled across the whole doc on 2026-06-26; follow that
precedent for tone and placement. Cross-check no present-tense "not started / still will" claim
about AR-7 survives.)

## Reuse (existing patterns to follow, not reinvent)

- **Slice registration idiom** — the 7 existing slices in `lib/jido_claw/doctrine.ex` (priv attr +
  `@external_resource` + `@slices` + `@template_slices`). Add the 8th identically.
- **String-enum-for-confidence precedent** — `OutputSchema.reviewer_verdict/0`
  (`lib/jido_claw/agent/workers/output_schema.ex:127-146`) and its rationale comment (lines 104-126).
- **Doctrine reach/exclusion test idiom** — `test/jido_claw/doctrine_test.exs` `for_template/1`
  `assert`/`refute =~` cases (the verifier case at lines 78-85 is the closest model for
  "gets a slice, but not the reviewer contract").
- **Schema parse + required-field test idiom** — `worker_output_schemas_test.exs` reviewer cases
  (happy path 240-263, required-field rejection 265-279), via
  `Jido.AI.Output.parse(output_for(Module), %{string-keyed map})`.

## Risks & notes

- **Clone gate (`reach.check --smells --strict`, ExSlop/ExDNA).** Operates on Elixir AST. The 8th
  `@..._priv`/`@slices`/`@template_slices` entry is the established idiom (7 already pass) — safe.
  The markdown slice is not AST-scanned, but author its prose distinct from `reviewer_contract.md`
  anyway (different framing: inline tags + source-URL) to avoid a content-duplication smell.
- **Two confidence axes on `researcher`** (top-level `low/medium/high` vs per-finding
  `likely/unsure`). Deliberate — keep both; the description must distinguish them so the LLM does
  not conflate them.
- **Persistence-safety.** String enum (not atom) for the per-finding tag, per the
  `Envelope.normalize/1` rule — even though researcher findings are not persisted today
  (`planner` stage `output:` is `["plan"]`), string keeps it safe if that ever changes.
- **`system_prompt.check` precommit gate** is untouched — it only validates the Tool Catalog, and
  AR-7 adds no tool. Safe.

## Verification

1. **Full gate (the bar for "complete"):** `mix precommit` — runs, in order, `jidoclaw.compile_check`
   (clean compile, empty allowlist), `jidoclaw.system_prompt.check`, `deps.unlock --unused`,
   `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict`,
   `dialyzer --format short`, `test`. All must pass. Run `mix format` first.
2. **Targeted tests while iterating:**
   - `mix test test/jido_claw/doctrine_test.exs`
   - `mix test test/jido_claw/agent/workers/worker_output_schemas_test.exs`
3. **Manual spot-check (Tidewave `project_eval` only — AGENTS.md mandates Tidewave for evaluating
   code / querying the DB; shell/Mix is reserved for non-eval gates like `mix test`/`mix precommit`):**
   - `JidoClaw.Doctrine.for_template("researcher")` and `("verifier")` contain `"Confidence tagging"`.
   - `JidoClaw.Doctrine.for_template("reviewer")` does **not** contain `"Confidence tagging"` (but
     still contains `"Reviewer Contract"`).
   - `Jido.AI.Output.parse` of the researcher schema accepts a finding with
     `"confidence" => "likely"` (as a **string**) and rejects a finding missing `confidence` or
     using an atom — the exact contract confirmed via Tidewave during planning.
4. **Doc-sweep check:** `grep -n "AR-7" docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md`
   returns no surviving "partial / not started / only AR-7 … remains" claim; AR-7 reads DONE
   everywhere it is mentioned.
