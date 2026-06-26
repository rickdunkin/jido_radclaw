# AR-4 — Self-Heal Fixer Loop (literal version)

## Context

`docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` tracks eight borrows from Alp River.
Seven have shipped or are partial; **AR-4 — the self-heal fixer loop (review → fix → re-review
until clean)** is the last not-started one with real behavior. Today the `RouteComposer` is
**forward-only**: a reviewer that flags `findings:<lens>` runs the `fixer` stage at most once
(blind, with no findings), the reviewers never re-review, and the run terminates `:not_converged`
(`loop.ex:82-88`, `route_composer.ex:112-119`). The substrate AR-4 needs already exists and is
exercised by two sibling loops — the AR-8c reverse-verify loop and the plan-gate re-plan — both of
which reuse the `stages_invalidated` "drop-from-`ran`" rerun primitive (`invalidate_stages/3`,
`route_composer.ex:2009`).

This plan implements the **literal** AR-4 (chosen over the minimal signal-driven version): the
**fixer self-reports which domains its edits touched**, a domain→lens mapping decides which
reviewers re-run, **and a lens that never ran is summoned** when a fix wanders into its domain
(Alp River's headline example: editing a UI file re-runs the visual lens even though it never
flagged). Exhaustion surfaces as a **distinct `:route_fix_failed` terminal** (mirroring AR-8c's
`:route_verify_failed`), so an operator can tell "the reviewers kept rejecting the fix" from "ran
out of waves."

**Outcome:** a `code`-path run whose review wave flags findings now loops review → fix →
re-review (re-running touched lenses, summoning newly-touched ones) until every lens is clean
(`:route_converged`) or the per-stage rerun cap trips with findings still open
(`:route_fix_failed`). Scope is the `code` path only — `sketch` is report-only (no fixer) and
`system` has its own reverse-verify loop.

**Size note:** this is a large, cohesive unit (a new first-class `fixer` worker + schema +
doctrine contract, catalog data-flow changes, a two-phase composer loop with domain-touched
RE_RUN_SET + never-ran summoning, a new durable terminal across 3 files, ~5 moduledoc
reconciliations, and ~12 test files). It is structured into **4 phases**, each independently
compilable and testable, culminating in `mix precommit` green. Nothing is deferred.

---

## Design overview

### Data-flow (the exact AR-8c analog)

The fixer is the **producer**, the reviewers are the **judges** — structurally identical to
AR-8c's executor⇄verifier, so we mirror it:

| | AR-8c (shipped) | AR-4 (this plan) |
| --- | --- | --- |
| judge reads producer's output via **normal input** | verifier inputs `system-change` | reviewer optional-inputs `fix` |
| producer reads judge's findings **out-of-band** (producerless → no cycle) | executor opt-inputs `verify-feedback` | fixer opt-inputs `review-feedback` |
| judge re-fires producer via **invalidation** (not an edge) | `stages_invalidated {executor,verifier}` | `stages_invalidated {fixer, touched reviewers}` |

**Why findings must reach the fixer out-of-band:** if the fixer declared `findings` as a real
input, `graph.ex:69-77` (edges from `required ++ optional`) would add `reviewer→fixer` edges;
combined with the `fixer→reviewer` edge (reviewer inputs `fix`) that is a 2-cycle, which
`CatalogValidator` invariant 10 (`Graph.kahn` over the whole catalog) rejects **at compile time**
(`catalog.ex:306` raises). So findings ride a **producerless** optional input the loop populates
at invalidation time — exactly how `verify-feedback` stays cycle-free (`graph.ex:19-24` confirms a
producerless optional input creates no edge).

The static data DAG stays acyclic: `implementer → {reviewers, fixer}` and `fixer → reviewers`
(via `fix`). At **runtime** the fixer always runs in a wave by itself (the signal-trigger
sequencing keeps it out of the reviewers' wave — see "two-phase loop"), so the `fixer→reviewer`
edge never co-schedules a stale review; it exists only so a re-running reviewer may *read* the
`fix` artifact via `ArtifactContext` (`wanted_names = required ∪ optional`).

### The fixer becomes a first-class worker

Today `fixer` reuses `{:worker_template, "coder"}`, whose `builder_result/0` schema has **no
`signals` field** — so it cannot emit signals through `DefaultMapper` (verified: the production
Coder emits nothing; only stub fixtures carry a `"signals"` key). The literal AR-4 needs the
fixer to **emit domain signals** (`auth-surface`/`significant-build`) it self-reports, and to
carry its **own doctrine contract** (doctrine is keyed by template name, `doctrine.ex:99`). Both
force a dedicated template. This is bounded — two compile/CI guards pin the addition to a fixed
file set.

### The fixer-declared RE_RUN_SET

"Fixer reports touched domains" is realized idiomatically (matching how `triage` and the
`implementer` fixture already work): the fixer **emits the domain signals** for what it touched in
its `signals` output field. From the fixer's emission the loop derives:

- **flagged lenses** = the open `findings:<lens>` signals (the reviewers that rejected).
- **domain-touched lenses** = lens stages whose `subscribes` matches a signal the fixer emitted
  (`code-written` → quality+correctness; `auth-surface` → security; `significant-build` →
  architecture). Derived by inverting the catalog `subscribes`/`lens` — **no new map**.
- **RE_RUN_SET** = (flagged ∪ domain-touched) ∩ `ran` → invalidated so they re-review.
- **never-ran lenses** whose domain signal the fixer just emitted are **summoned for free**: the
  signal is now live and the router triggers any subscriber not in `ran` (no invalidation).

### Terminal

A fix loop that trips the per-stage `rerun_cap` with `findings:<lens>` still open terminalizes as
the new `:fix_failed` → durable `:route_fix_failed` (projects onto `WorkflowRun` `:failed` with
`disposition: "fix_failed"`), mirroring `:verify_failed`. The two are disjoint by the
`reverse_verify` split, so `budget_terminal/1` distinguishes them cleanly.

---

## The two-phase loop (the novel mechanics — detail)

Today the post-fold dispatcher `maybe_rerun_after_findings/2` (`route_composer.ex:1930`) runs
`open_verify_loop?` / `stale_approval?` and performs a **separate** durable append. AR-4 adds its
**two** new branches as a **pure**, pre-commit `decide_rerun(folded_state, emissions) → {markers,
apply_fn}` whose markers are **welded into the wave commit** (see "Durability"); the existing verify
and stale branches **stay on their current post-commit path, unchanged** (their pre-existing window
is out of AR-4's scope — AR-4 must not introduce a *new* one, not re-architect the shipped paths):

```
# decide_rerun — pure, computed BEFORE commit_wave; AR-4 branches only
cond do
  fixer_completed?(state, emissions)   -> hook_f_markers(state, emissions)   # Hook F
  open_fix_finding?(state, emissions)  -> hook_r_markers(state, emissions)   # Hook R
  true                                 -> {[], & &1}                         # no-op (incl. verify/stale waves)
end
# then, post-commit (unchanged): maybe_rerun_after_findings handles verify + stale
```

A wave is either a reviewer wave or the fixer wave, so Hook R and Hook F are mutually exclusive per
tick, and both are disjoint from verify (`reverse_verify: true`) and stale (`not implementer_ran?`,
false at any reviewer tick). AR-4's welded markers are exactly `stages_invalidated` /
`artifacts_produced` / `artifacts_invalidated` (all already projected) — **no `signals_retracted`**
(that belongs to stale-approval, which keeps its own path). The one new durable kind is
`:route_fix_failed`.

**Hook R — a forward-lens reviewer *stage* emitted open `findings:<lens>` this wave**
(`open_fix_finding?` keys off the **emitting stage** in `emissions` — a `lens`-carrying,
non-`reverse_verify` stage whose own `findings:<its lens>` is open — AND a `fixer` shares that
stage's live route; never a bare lens string — see "Route/stage scoping"):
1. **Iteration-scope the feedback** (fixes P1-stale): first `artifacts_invalidated` every existing
   `review-feedback` / `review-action` producer, then `artifacts_produced` the *currently*-flagged
   stages' `findings` / `action_needed` refs. The store merge is additive per producer
   (`projection.ex:104` `produce_artifact`; `route_composer.ex:2039` `merge_artifacts`), so without
   the invalidate a fix two rounds later would still receive a since-cleaned lens's stale feedback.
   `artifacts_invalidated` deletes `store[name][producer]` precisely (`projection.ex:197`), so the
   fixer always sees exactly the round's open findings. Generalizes `verify_feedback/2`
   (`route_composer.ex:1982`) to a multi-producer, snapshot-replaced feed.
2. If the fixer is already in `ran` (a *re-flag* after a prior fix), invalidate it
   (`stages_invalidated {fixer}`) so it re-fires; on the first finding the fixer is not yet in
   `ran` and fires naturally — the `∩ ran` makes the invalidation a no-op there.

**Hook F — the fixer completed this wave** (`fixer_completed?` = the fixer stage *name* is in
`emissions`):
1. Compute RE_RUN_SET = (flagged reviewer **stages** ∪ domain-touched reviewer **stages**) ∩ `ran`
   and `invalidate_stages` them (they re-review next tick). Domain-touched = the lens-carrying,
   non-`reverse_verify` stages **on the fixer's live route** whose `subscribes` matches a signal
   the fixer emitted (via the shared signal matcher — see "Signal matcher"). Identity is the
   **stage name** (unique), never the lens string.
2. The fixer's emitted domain signals are already folded live (fold runs before this hook), so any
   never-ran subscriber is summoned by the router next tick — no action needed here.

**Worked trace** (quality flags; the fix touches auth, which never ran):

| Tick | wave | result | hook |
| --- | --- | --- | --- |
| T1 | quality+correctness reviewers | `findings:quality`, `clean:correctness` | **Hook R**: inject quality's findings → `review-feedback`; fixer ∉ `ran` (no-op invalidate) |
| T2 | fixer (alone — `findings:quality` live, reviewers ∈ `ran`) | reads `diff`+`review-feedback`; emits `signals:["code-written","auth-surface"]`; produces `fix` | **Hook F**: RE_RUN_SET = flagged `{quality}` ∪ domain-touched `{quality,correctness (code-written), security (auth-surface)}` ∩ `ran` = `{quality,correctness}`; invalidate them. `auth-surface` now live |
| T3 | quality+correctness (re-fired) + security (**summoned** by `auth-surface`) | all read `diff`+`fix`; all emit `clean:<lens>` → fold retracts `findings:quality` | none |
| T4 | — (nothing triggers) | `dispatch == nil` → `Loop.terminal` → `lenses_clean?` → **`:converged`** | — |

If T3 re-flags instead → Hook R re-fires the fixer (now ∈ `ran`) → T4 fixer → T5 re-review, bounded
by `rerun_cap` (default 2); on exhaustion `budget_terminal/1` → `:fix_failed`.

**Convergence falls out for free**: `Loop.terminal`/`lenses_clean?` are unchanged — once a
re-fired reviewer emits `clean:<lens>`, the fold's paired-verdict invariant retracts
`findings:<lens>` and the run converges.

### Durability & correctness refinements (from review)

**Hook markers are committed atomically with the wave (fixes the crash window).** Today
`handle_wave_value/5` commits the wave (`commit_wave`) and *then* appends the rerun markers in a
**separate** transaction (`route_composer.ex:1293`). A crash in that window re-projects "fixer ran"
(`wave_completed`) with **no** re-review trigger (no `stages_invalidated`) — the reviewers stay in
`ran`, findings stay open, and the next tick terminalizes spuriously. AR-4 closes this by computing
its hook as a **pure decision** — `decide_rerun(folded_state, emissions) → {markers, apply_fn}` —
*before* the commit and **welding `markers` into the single `commit_wave` transaction** (extend
`Commit.commit_wave` to accept trailing plain-event markers). The feedback `artifacts_produced`
markers are **ref-pointers to the wave's own artifacts** (e.g. `review-feedback` points at the
reviewer wave's just-produced `findings` refs): they create/activate **no second artifact row** —
only the wave's own artifacts go through `commit_wave`'s pending→active activation step.

**The welded append order is canonical** (the projection folds in `seq` order, so order is
load-bearing): `wave_completed` → the wave's content events → the AR-4 hook markers, and **within
Hook R `artifacts_invalidated` → `artifacts_produced` → `stages_invalidated`**. If
`artifacts_produced` preceded `artifacts_invalidated`, the stale-clear would delete the *current*
feedback for a producer flagged in both rounds; if a hook marker preceded `wave_completed`, the
wave-add could re-add a just-invalidated stage. Pin this order in `commit_wave` and assert it in a
projection test.

**`apply_fn` must mirror *every* welded marker (the projection-equivalence invariant).** The
in-memory mutation applied on the unified `:ok` must reproduce exactly what the projection folds
from the same markers, or `Projection.project == in-memory` breaks. For AR-4's marker set that is:
`stages_invalidated` → `ran` difference + `rerun_counts` bump (`apply_invalidation/3`);
`artifacts_produced` → store merge; `artifacts_invalidated` → store prune (mirroring
`invalidate_artifact/2`). Implement `apply_fn` as a **generic "fold this marker batch into memory"**
helper (ideally reusing the projection's own per-event logic) so it can never drift from the welded
markers. This is also why AR-4 does **not** weld `signals_retracted`: its only producer is
stale-approval, which keeps its existing path (welding it would *also* require mirroring
`plan-approved` deletion, as `apply_stale_retraction/2` does — out of AR-4's scope). The hooks are
additionally **idempotent** (`∩ ran` empties after the first apply; feedback is
invalidate-then-produce), so a recovery-side re-evaluation of the last wave is a safe fallback if
`commit_wave` cannot cleanly carry the extra markers.

**Route/stage scoping (not bare lens names).** The catalog reuses the `correctness` lens on both
the `code` path (`catalog.ex:156`) and the `sketch` path (`catalog.ex:236`), so a bare
`findings:<lens>` string and whole-catalog-by-lens iteration are ambiguous. Every AR-4 helper —
`open_fix_finding?`, `fixer_completed?`, the domain-touched derivation, and `exhausted_fix_lenses/1`
— keys off the **emitting stage name** (unique) plus the **current live route** (`routes ∩ live`,
`ran`, `rerun_counts`), deriving the lens string only to build/check the `findings:<lens>` signal.
(`exhausted_fix_lenses` is already participation-scoped because `rerun_counts > cap` is nonzero only
for stages that actually re-ran, but it still keys its output off the unique stage.)

**Signal matcher (shared, one-directional).** The domain-touched check ("does this reviewer's
`subscribes` match a fixer-emitted signal?") needs the router's **one-directional** family-prefix
predicate `Router.matches?/2` (private, `router.ex:292`) — **not** `CatalogValidator.family_match?/2`
(which is **bidirectional**, `catalog_validator.ex:89`). Extract the one-directional predicate into a
tiny shared public function used by both the router and the AR-4 helpers (single-source + tested),
rather than duplicating it (which would also risk the ExSlop clone gate).

---

## Implementation phases

### Phase 1 — Fixer as a first-class worker + catalog data-flow

*Goal: the fixer is a dedicated template that can emit domain signals and carries its own
contract; the catalog wires the AR-8c-style data-flow. No loop behavior yet.*

1. **New worker** `lib/jido_claw/agent/workers/fixer.ex` — `use JidoClaw.Agent.Defaults` (NOT bare
   `use Jido.AI.Agent`; enforced by `recorder_plugin_coverage_test.exs`), copy `Coder`'s mutating
   tool list/model, `output: %{schema: OutputSchema.fixer_result(), retries: 1,
   on_validation_error: :repair}`.
2. **New schema** `OutputSchema.fixer_result/0` (`output_schema.ex`) — MAP form (project rule:
   keyword form trips dialyzer). Builder-like fields + a `signals` field that drives emission:
   ```elixir
   Zoi.object(%{
     status: Zoi.enum([:completed, :partial, :blocked]),   # atom enum OK — never stored
     summary: Zoi.string(),
     files_changed: Zoi.array(Zoi.string()),
     notes: Zoi.string(),
     signals: Zoi.array(Zoi.string()),                     # STRINGS — fed to validate_publishes
     artifacts: artifacts()
   })
   ```
   `signals` must be strings (the mapper's `explicit_signals/1` matches them against the
   `publishes` *strings*). It is never persisted (not in `stage.output`), so no `Envelope.normalize`
   concern. `status` stays an atom enum because the `fix` artifact resolves to `summary` text only.
3. **Register the template** (`templates.ex` `@templates`): `"fixer" => %{module:
   JidoClaw.Agent.Workers.Fixer, description: "...", model: :fast}`.
4. **Doctrine contract**: new `priv/defaults/doctrine/fixer_contract.md` (model on
   `reviewer_contract.md`): the `status`/`signals` output shape + the discipline "resolve the open
   findings against the diff; always emit `code-written`; **also emit the domain signal for any
   domain you touched** (`auth-surface` for auth/permissions/secrets, `significant-build` for
   architectural changes) so the right lenses re-review." Four edits in `doctrine.ex` mirroring an
   existing slice (`@..._priv` path via `Path.join([__DIR__, ...])` — never `Path.expand`;
   `@external_resource`; `@slices` entry; `@template_slices "fixer" => [:base, :artifacts,
   :fixer_contract]`). The `@template_slices` entry is **mandatory** — `doctrine_test.exs:116`
   asserts `template_names() == Templates.names()`.
5. **Catalog data-flow** (`catalog.ex`):
   - **Fixer stage** (`:180-189`): `unit: {:worker_template, "fixer"}`; `input: %{required:
     ["diff"], optional: ["review-feedback", "review-action"]}` (both producerless —
     loop-injected: `review-feedback` carries the flagged lenses' `findings`, `review-action`
     their `action_needed` directives); `output: ["fix"]` (unchanged); `publishes:
     ["code-written", "scope-shift", "auth-surface", "significant-build"]`; reword `task` to
     instruct findings-resolution + domain self-report.
   - **Four reviewers** (`:131-178`): `input: %{required: ["diff"], optional: ["fix"]}` and
     `output: ["findings", "action_needed"]`. The `action_needed` output **closes the AR-3
     deferral** — and is justified because the fixer now consumes it (via `review-action`):
     persisting it needs only the `output` edit; `DefaultMapper.output_artifacts/3` picks it up
     from the typed output via `dynamic/2`, no mapper change. Leave `subscribes`/`publishes`/`lens`
     untouched (verdict-publishes invariant 8 already satisfied).
   - Do **not** touch `sketch-review` or `system-verifier`.

**Verify Phase 1**: `mix compile` clean (catalog compile-guards pass); `worker_output_schemas_test`
+ `doctrine_test` green; a new catalog-validator negative test asserting the
producer-backed-`findings` variant *would* cycle (pins why the feed is out-of-band); a
**`default_mapper_test`** pinning the two subtle resolutions — (a) the fixer's `output: ["fix"]`
resolves via the `output_value/3` fallback (`default_mapper.ex:112`) to the fixer `summary` text
since `fixer_result/0` has no `fix` field (same fallback the implementer's `diff` already relies
on), and (b) `action_needed` persists from the reviewer's typed output via `dynamic/2`.

### Phase 2 — The two-phase loop + RE_RUN_SET + summoning

*Goal: review → fix → re-review → converge actually loops, durably.*

1. **Shared signal matcher** — extract `Router.matches?/2`'s one-directional family-prefix predicate
   into a small public function; call it from the router and the AR-4 helpers (single-source).
2. **The two hooks** in `route_composer.ex` (the "Rerun / invalidation" block, ~`:1917-2111`): add
   `open_fix_finding?` / `fixer_completed?` predicates keyed off emitting **stage names** + the live
   route (per "Route/stage scoping"), folded into one **pure** `decide_rerun(folded_state, emissions)
   → {markers, apply_fn}` covering both hooks:
   - **Hook R** markers: `artifacts_invalidated` (stale `review-feedback`/`review-action` producers)
     → `artifacts_produced` (current flagged set) → `stages_invalidated {fixer}` when the fixer ∈ `ran`.
   - **Hook F** markers: `stages_invalidated` ((flagged ∪ domain-touched reviewer stages) ∩ `ran`).
   - Domain-touched derivation: a pure helper inverting the catalog via the shared matcher (stages on
     the fixer's route whose `subscribes` matches a fixer-emitted signal), ∪ flagged stages, ∩ `ran`.
3. **Weld the markers into the wave commit** (fixes the crash window): extend `Commit.commit_wave`
   with an **explicit typed hook-markers parameter** (not smuggled into `@type deltas`) appended in
   the **same** transaction after the wave content (the feedback markers are ref-pointers to the
   wave's own artifacts — no extra activation), and apply `apply_fn` on `:ok`.
   `apply_fn` is a **generic marker-batch→memory** helper mirroring every welded kind
   (`stages_invalidated`, `artifacts_produced`, `artifacts_invalidated`) so `Projection.project ==
   in-memory` holds by construction. Generalize `verify_feedback/2` into the shared multi-producer
   feedback helper (also dodges an ExSlop clone). **Leave the AR-8c verify loop and stale-approval on
   their existing post-commit path** (lower blast radius; their pre-existing window is out of AR-4
   scope) — AR-4 only adds its own welded branches.
4. No `closed_wave_index` on any AR-4 `stages_invalidated` (generic completed-wave reruns);
   `rerun_counts`/cap bookkeeping stays automatic.

**Verify Phase 2**: new E2E self-heal converge test + never-ran-summon test + a **stale-feedback**
test (lens A flags→cleans, lens B flags a later round; assert the fixer's `review-feedback` no
longer carries A) green; convergence asserted on durable event kinds (`:route_converged`, the
`stages_invalidated` payload, no `closed_wave_index`) per the `composer_system_loop_test.exs`
template.

### Phase 3 — The `:route_fix_failed` terminal

*Goal: exhaustion is an honest, distinct operator signal.*

All mechanical mirrors of the shipped `:verify_failed` path:
1. `route_composer.ex`: add `:fix_failed` to `@type terminal` (`:221`); `:route_fix_failed` to
   `@scrubbable_error_kinds` (`:197`); a `budget_terminal/1` branch (`:2627`) — `rerun_capped? and
   fix_exhausted?` → `{:fix_failed, exhausted_fix_lenses(state)}`; `fix_exhausted?` +
   `exhausted_fix_lenses/1` (the `reverse_verify != true` twin of `exhausted_verify_lenses/1`,
   keyed on `rerun_counts + live`, disjoint from the verify set); `classify_terminal({:fix_failed,
   r})`; a `parent_terminal_notify(:fix_failed, …)` clause appending `:route_fix_failed` +
   `result: %{disposition: "fix_failed"}` before the generic catch-all;
   `format_terminal_error(:fix_failed, lenses)`.
2. `orchestration/workflow_event.ex`: add `:route_fix_failed` to the event-kind `one_of`
   (app-level text — **no migration**).
3. `orchestration/workflow_event/projection.ex`: add `:route_fix_failed` to `@route_terminal_kinds`
   (keep it OUT of `@route_failed_kinds` so it lifts the disposition); `next_status(_,
   :route_fix_failed) → :failed`; `status_attrs`/`terminal_lifting_fix_failed` (mirror
   `terminal_lifting_verify_failed`).

**Verify Phase 3**: exhaustion test (reviewer always rejects, low `rerun_cap`) → `:failed`,
`:route_fix_failed in kinds`, `reload.result["disposition"] == "fix_failed"`, `error` starts
`"fix_failed: lenses=…"`; a projection test for `:route_fix_failed`.

### Phase 4 — Doc reconciliation + invert forward-only tests + precommit

1. **Reconcile stale "forward-only / self-heal deferred" claims** (the user cares about no stale
   invariant text): `route_composer.ex:112-119` (Scope forks — AR-4 is now the 3rd consumer of the
   rerun primitive), `:1917-1929` (the `maybe_rerun_after_findings` header — narrow the
   `:not_converged` claim to *fixer-less* paths), `loop.ex:12-17` (`terminal/2` moduledoc — open
   findings terminate `:not_converged` only with **no fixer on the path**), `stage.ex:38-44`
   (`reverse_verify` doc), `catalog.ex:11-12` (the loop is no longer "a later phase"; the mechanism
   is `stages_invalidated` + the out-of-band feed, not the `code-written` edge). Keep
   `sketch-review`'s "report-only — no fixer" as the canonical surviving `:not_converged`-on-findings
   case.
2. **Invert the forward-only tests**: `composer_loop_test.exs:517` and its durable twin
   `composer_durable_test.exs:167` assert `findings → :not_converged`. Re-point both to the new
   self-heal fixture (findings-then-clean → **converges**); the "open findings → failure" coverage
   moves to the Phase-3 exhaustion test. Keep `phase1_catalog`'s structural wave tests unchanged
   (a fixer would ripple `@all_stages`).
3. Run **full `mix precommit`** (never piped through `tail`) until green.

---

## Files to modify

**New:**
- `lib/jido_claw/agent/workers/fixer.ex`
- `priv/defaults/doctrine/fixer_contract.md`
- `test/jido_claw/route_composer/composer_self_heal_loop_test.exs`

**Production edits:**
- `lib/jido_claw/agent/workers/output_schema.ex` — `fixer_result/0`
- `lib/jido_claw/agent/templates.ex` — `@templates["fixer"]`
- `lib/jido_claw/doctrine.ex` — `fixer_contract` slice + `@template_slices["fixer"]`
- `lib/jido_claw/route_composer/catalog.ex` — fixer + reviewer stages (+ moduledoc)
- `lib/jido_claw/route_composer/route_composer.ex` — the pure `decide_rerun` (both hooks),
  route/stage-scoped predicates, domain-touched derivation, shared multi-producer feedback helper,
  `:fix_failed` terminal, moduledoc reconciliations
- `lib/jido_claw/route_composer/commit.ex` — `commit_wave` takes the hook markers as an **explicit
  typed parameter** (a 5th arg or a clearly-named option with its own `@type` — NOT folded into
  `@type deltas`, which stays wave-content only, `commit.ex:67`), appended after `wave_completed` +
  content in canonical `seq` order (Hook R: `artifacts_invalidated` → `artifacts_produced` →
  `stages_invalidated`); only the wave's own artifacts get the activation step (`commit.ex:154`)
- `lib/jido_claw/route_composer/router.ex` — extract the one-directional `matches?` into a shared
  public predicate
- `lib/jido_claw/orchestration/workflow_event.ex` — `:route_fix_failed` kind
- `lib/jido_claw/orchestration/workflow_event/projection.ex` — `:route_fix_failed` projection
- `lib/jido_claw/route_composer/loop.ex`, `lib/jido_claw/route_composer/stage.ex` — moduledoc only

**Tests/fixtures:**
- `test/support/jido_claw/route_composer/fixtures.ex` — add `self_heal_fixture_catalog/0` +
  seeds/stub-outputs; **reuse** `phase1_template_override/1` (don't author a 3rd override — clone
  gate)
- `test/support/jido_claw/route_composer/composer_stubs.ex` — extend `SystemLoopWorker` with a
  counter-driven reviewer clause + a fixer clause emitting `signals` (don't add a 3rd cloned
  `ask/3`)
- `test/jido_claw/route_composer/{composer_loop_test,composer_durable_test,loop_test,projection_test,catalog_test,catalog_validator_test,default_mapper_test}.exs`
- `test/jido_claw/agent/workers/worker_output_schemas_test.exs`, `test/jido_claw/doctrine_test.exs`
- a projection test for `:route_fix_failed`

---

## Reused substrate (do not reinvent)

- `apply_invalidation/3` (`route_composer.ex:2028`) — the in-memory `ran`-difference / `rerun_counts`
  bump; `decide_rerun`'s `apply_fn` composes it with the store merge/prune (the `artifacts_*` mirrors
  above) into one generic marker-batch→memory step that mirrors **every** welded marker, so
  projection-equivalence holds. (The durable markers ride the welded `commit_wave`, not a separate
  append — see "Durability".)
- `verify_feedback/2` (`:1982`) — generalize into the shared multi-producer out-of-band feedback
  helper (now also issuing `artifacts_invalidated` for the prior round's producers).
- `artifacts_invalidated` / `invalidate_artifact` (`projection.ex:109,197`) — per-producer store
  delete with empty-name pruning; the mechanism that keeps the fixer's feedback iteration-scoped.
- `@default_rerun_cap 2` / `over_budget?` / `rerun_capped?` (`:159`, `:2594`, `:2600`) — the
  oscillation bound, reused verbatim.
- The fold's paired-verdict last-writer-wins (`fold.ex:60-74`) — gives convergence for free.
- `ArtifactContext.build/4` (`wanted_names = required ∪ optional`) — renders `fix` to reviewers and
  `review-feedback` to the fixer; **no change needed** (single-producer artifacts, no latest-wins).
- The catalog `subscribes`/`lens` fields — the domain→lens map, derived not duplicated.
- Doctrine path: `WaveBuilder → AgentStep → AgentRunner` (stamps `agent_template`, calls
  `Startup.inject_subagent_prompt`) → `SubagentPrompt.build` → `Doctrine.for_template("fixer")`.

---

## Precommit risk register (`mix precommit` must be green)

- **Dialyzer / `@type terminal`**: adding `:fix_failed` touches the terminal union and its
  pattern-match sites (`classify_terminal`, `parent_terminal_notify`, `format_terminal_error`,
  `budget_terminal`). All mirror the existing `:verify_failed` clauses — mechanical, but every site
  must be added or dialyzer flags non-exhaustiveness.
- **ExSlop/ExDNA clone gate** (`min_mass 30`, contiguous, project memory): the top risk. Mitigate by
  (a) the **shared** multi-producer feedback helper + the shared signal matcher instead of near-clones
  of `verify_feedback`/`Router.matches?`; (b) one `decide_rerun` covering both hooks; (c) **reusing**
  `phase1_template_override/1` and **extending** `SystemLoopWorker` rather than adding a 3rd cloned
  `ask/3`/override.
- **Commit-flow change is shipped-code surgery** (`commit.ex` `commit_wave` + `handle_wave_value`):
  welding markers into the wave transaction touches a path AR-8c and the plan-gate also reach. Keep
  the blast radius small — weld **only** AR-4's new branches, leave verify/stale on their existing
  append; keep the activation step applying **only** to the wave's own artifacts (the feedback
  markers are ref-pointers, not new rows); and make `apply_fn` mirror every welded marker kind so
  projection-equivalence holds. Re-run `composer_durable_test`/`projection_test` to prove no
  regression in the shipped loops.
- **`String.to_atom`**: none — every new name (`fix`, `review-feedback`, `auth-surface`,
  `significant-build`, `action_needed`) is a string literal flowing through string-keyed stores and
  `dynamic/2`'s `to_string/1`.
- **Catalog validator**: walked clean — invariant 7 (self-dep: `["diff"] ∩ ["findings",
  "action_needed"]/["fix"] = ∅`), invariant 8 (verdict publishes unchanged), invariant 2
  (`scope-shift` kept), invariant 10 (acyclic — guaranteed only because findings are out-of-band;
  the negative test pins this).
- **Doctrine drift guard** + **catalog template-exists guard**: both satisfied by registering
  `"fixer"` in `@templates` *and* `@template_slices` together.
- **Credo/reach strict**: any new error/format string copies `format_terminal_error/2`'s shape;
  use `IO.iodata_to_binary` for any list-built string (project memory). Run the **full** precommit.

---

## Verification (definition of done)

1. **`mix precommit` green** — the binding bar (strict compile, format, credo, reach strict,
   dialyzer, full test). The plan is not complete until this passes.
2. **E2E self-heal converge** (new `composer_self_heal_loop_test.exs`, modeled on
   `composer_system_loop_test.exs:78-96`): a stub reviewer returns `findings:quality` once then
   `clean:quality`; assert the run reaches `:completed`/`:route_converged`, a `stages_invalidated`
   event invalidated the touched reviewers (and the fixer on a 2nd iteration) with **no**
   `closed_wave_index`, and `clean:quality` ended live with `findings:quality` retracted.
3. **Never-ran summon**: a stub fixer emits `auth-surface` (auth not previously live); assert
   `security-reviewer` runs for the first time *after* the fix and the run converges only once it
   is clean.
4. **Exhaustion → `:route_fix_failed`** (modeled on `composer_system_loop_test.exs:98-118`):
   reviewer always rejects, `rerun_cap: 1`; assert `:failed`, `:route_fix_failed in kinds`, NOT
   `:route_budget_exhausted`, `disposition == "fix_failed"`.
5. **Inverted forward-only tests** (`composer_loop_test.exs:517`, `composer_durable_test.exs:167`)
   now assert convergence after a fix.
6. **Crash recovery through a fix wave / the wave↔hook window** (`composer_durable_test.exs`, mirror
   the kill→restart case): kill the composer **immediately after a fixer wave**, restart, and assert
   recovery still re-reviews and converges — proving the welded `decide_rerun` markers landed
   atomically with `wave_completed` (no "fixer ran, no re-review trigger" half-state) and that
   `stages_invalidated`/`rerun_counts`/injected feedback re-project correctly.
7. **Stale-feedback isolation** (Phase 2): lens A flags then cleans, lens B flags a later round;
   assert the fixer's `review-feedback`/`review-action` carry only the round's open producers (A's
   stale feedback was `artifacts_invalidated`).
8. **Route/stage scoping** (unit): with the `correctness` lens present on both code and sketch
   stages, assert the helpers key off the emitting **stage** + live route — a `code`-run fix loop
   touches only the code reviewers, and `exhausted_fix_lenses/1` never reports an off-route stage.
9. **Manual smoke (optional)**: drive a real `code`-path turn via `mix jidoclaw` and confirm
   (Tidewave `inspect_workflow` / the `WorkflowEvent` log) the review→fix→re-review waves and a
   converged terminal.
