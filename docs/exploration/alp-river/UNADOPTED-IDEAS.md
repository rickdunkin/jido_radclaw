# Unadopted Alp River Ideas — Standing & Triggers

Companion to [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) (V1) and
[`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md). Those two are the
inventory and adoption record; this doc rolls up only the **live remainder** — ideas Alp
River surfaced that were never implemented here and were *deferred or put on watch*, not
rejected. For each: where it stands in the code today, whether it's worth adopting now,
and the trigger that would change that verdict. Entries the inventories closed as SKIP
with no deferral (hook substrate, run-state recovery, briefs/render-card, `/audit`,
reconcile-from-tree, Anchor lines) are not repeated here — they're settled.

Compiled **2026-07-02**, against alp-river v1.3.3 `7088685` and the same-day V1
source-drift note + V2 delta audit (all in-tree standings re-verified that day). Verdicts
are weighted by the shipped composer being the adoption surface — most items are catalog/
composer increments, and the single-operator deployment keeps every demand-gated item far.
Ordered by trigger proximity — nearest first.

| # | Idea | Source entry | Adopt now? | Trigger distance |
| --- | --- | --- | --- | --- |
| 1 | Per-stage model/effort tiering (wire the seam) | V1 §4 + V2 §4 | Not alone — nearest; rides #2 or first cost/quality pressure | AR-9 shipping, or judge-stage quality pain at uniform `:fast` |
| 2 | Multi-plan + plan-arbiter (judge-panel plan wave) | V2 AR-9 | Not yet — the next substantive composer increment | Wanting a composer increment; recurring plan-shape failures on significant builds |
| 3 | Hand `premises` to stage agents | V2 §4 refinement | No — rider | Any composer increment (bundle in) |
| 4 | Shipping tail (`ship-gate` → `ship-executor`) | V2 AR-10 | No (its footnoted `git push` sibling: **shipped 2026-07-02**) | Ship/commit/PR asks after composed runs becoming routine |
| 5 | `code-doctrine` slice + `docs/` READ_MAP | V1 AR-5 open borders | No | Next doctrine authoring pass, or recurring producer-quality feedback |
| 6 | Artifact handles (refs instead of inline stage inputs) | V2 AR-11 | No — telemetry-gated | Prompt-cost evidence: large many-consumer artifacts dominating sub-agent cost |
| 7 | Milestone loop (verified increments on big builds) | V1 §4 | No — pain-gated | Composed builds outgrowing the single end-review pass |
| 8 | `.jido/` YAML catalog overlay + watcher | V1 AR-2 deferred tail (gust G3-2) | No — demand-gated | Needing catalog changes without recompiling (per-project stages) |
| 9 | Idle-based hang detection (activity watchdog) | V2 §4 refinement | No — evidence-gated | Hangs routinely eating the full wave timeout |

---

## 1. Per-stage model/effort tiering — wire the seam (V1 §4, updated V2 §4)

**Standing**: half-built since AR-2 — `%Stage{}` carries `model`/`effort` fields (marked
"for later phases") but `WaveBuilder` never reads them, so all 13 worker templates run
uniformly at `:fast` (re-verified 2026-07-02). The source meanwhile re-tiered to
fable/sonnet/haiku at 1.3.3 and runs its arbiter at `fable`/`max`.

**Now?** Not as a standalone item — but it's first in line, because it's the cheapest
entry here (the fields exist; the work is the `WaveBuilder` spawn-time override seam) and
two triggers point at it.

**Trigger**: AR-9 shipping (its arbiter is the designed first consumer — V2 AR-9 sketch
step 6), or observed judge-stage quality/cost pressure at uniform `:fast` (reviewers and
gates deserving a higher tier than mechanical producers). Whichever fires first.

## 2. Multi-plan + plan-arbiter — the judge-panel plan wave (V2 AR-9)

**Standing**: opened as a full entry in V2 (2026-07-02) after V1's drift note declined it
("noted, not recommended here"). The composer's plan phase is strictly single-plan —
`planner` (`catalog.ex:79`) → the human `plan-gate` (`catalog.ex:100`), with `plan-rejected`
re-firing the planner. Every substrate piece exists (AR-3's lens-instantiation pattern,
stage-first personas, the emission ⊆ `publishes` coherence check that makes the source's
convention-enforced sole-publisher invariant structural here, welded wave commits for the
atomic co-publish); nothing is built.

**Now?** Not yet — it's the next *substantive* composer increment, deliberately opt-in
(armed only on wide-design-space significant builds; ~2–3× planning cost when armed).
Adopt when a composer increment is next wanted, not on a calendar.

**Trigger**: wanting the next composer increment, or evidence that first-plan *shape* is
the recurring risk — approved plans on significant builds repeatedly scope-shifting or
riding the `plan-rejected` re-plan edge. When it fires, follow the V2 AR-9 sketch
(lens-scoped `plan:<lens>` stages → critique-only challengers → arbiter → the existing
human gate) and pull #1 and #3 in with it.

## 3. Hand `premises` to stage agents (V2 §4 refinement)

**Standing**: the composer has carried `premises` as first-class state since its first
phase (`c7a428af`), and every stage must declare `scope-shift` ∈ `publishes`
(`catalog_validator.ex:34`) — but stages self-report premise breaks *blind*: the premise
list is never threaded into the stage task context (no `premises` in
`wave_builder.ex`/`agent_runner.ex`, rg-verified). The source hands each stage the
premises so breaks are reported against an explicit list (`WORKFLOW.md` ### The loop).

**Now?** No — it's a rider, not a feature: a small prompt-threading change with no
standalone justification.

**Trigger**: any composer increment (bundle it in — #2 being the likeliest vehicle). If
scope-shift self-reports prove noisy or miss real breaks before then, that's the same
trigger arriving early.

## 4. Shipping tail — ship-gate → ship-executor (V2 AR-10)

**Standing**: opened in V2 (2026-07-02). The `code` path converges with a dirty working
tree; shipping is a conversation-axis follow-up (`git_commit`, approval-gated) and the
16-stage catalog has no ship stage. The source's tail (triage `#ship-requested` marker →
convergence-emitted `#ship-ready` → sticky ship-gate picking main vs branch+draft-PR →
locked executor → `#shipped`) maps onto three existing parts; the one real design question
is double-gating (resolved in the V2 entry toward the ship gate pre-minting the tool
approval for the executor's exact fingerprint).

**Now?** No — ergonomics plus a durable `shipped` terminal, not new safety. (The one
*now* item its analysis surfaced — the missing `git push` approval pattern — was
independent of the borrow and **shipped 2026-07-02**; see the footnote.)

**Trigger**: ship/commit/PR asks immediately after composed code runs becoming a routine
pattern — the moment the conversational follow-up is boilerplate, the route-level tail
pays for itself.

## 5. `code-doctrine` slice + `docs/` READ_MAP (V1 AR-5 open borders)

**Standing**: AR-5's seam shipped and now carries 8 slices (`priv/defaults/doctrine/`:
`base`, `artifacts`, `emit_signals`, `reviewer_min`, `reviewer_contract`,
`fixer_contract`, `system_verify`, `confidence_tagging` — verified 2026-07-02), but the
two open borders V1 named are still open: no `code-doctrine` slice (the source authors
`doctrine/code-doctrine.md` once and injects it into every producer — coder, fixer,
implementer), and "project docs" remains JIDO.md only (no `READ_MAP`-style per-template
`docs/` slices).

**Now?** No — the producers work; a code-doctrine slice is content authoring, not
mechanism, and the READ_MAP half is speculative until per-template project-doc needs show
up.

**Trigger**: the next doctrine authoring pass (cheapest moment to write the slice), or
recurring code-quality feedback to producer workers that a single-sourced slice would
standardize — the same "duplicated guidance" smell that justified AR-5 originally.

## 6. Artifact handles — refs instead of inline stage inputs (V2 AR-11)

**Standing**: noted in V2 (2026-07-02) — the 1.3.0 plan-handle extension V1's drift note
missed. Composer artifacts are durable and ref-addressed (`ComposerArtifact`, `art_…`
refs) but "resolved only at the wave boundary" and inlined into stage prompts
(`route_composer.ex:62`); a large plan reaching test-author + implementer + four
reviewers + fixer pays its bytes into each prompt. The lazy analog exists only on the
tool-output axis (`fetch_output`).

**Now?** No — telemetry-gated by its own entry: measure before building, and carry the
source's carve-out reasoning (version-pinned consumers stay inline) if built.

**Trigger**: prompt-cost telemetry showing large many-consumer artifacts dominating
sub-agent prompt cost on composed runs.

## 7. Milestone loop — verified increments on big builds (V1 §4)

**Standing**: still "future follow-on of AR-2/AR-3", unbuilt. The source's version has
matured considerably since V1 filed it (per-milestone EARLY pass with milestone-scoped
lenses, the HARD `@diff`/`#code-written` withhold so the end-review wave fires exactly
once, boundary re-holds of the TDD chain, tier-growth re-gate via stale-approval
retraction, forward-only re-split — `WORKFLOW.md` ## Milestone loop), which makes the
eventual port better-specified, not more urgent. The mapping V1 named still holds:
Reactor compositional steps + the shipped gate machinery, no new substrate.

**Now?** No — pain-gated.

**Trigger**: composed significant builds routinely producing diffs big enough that the
single end-of-route review wave arrives too late or too large to fix cheaply — the
fixer loop thrashing on XXL diffs would be the concrete symptom.

## 8. `.jido/` YAML catalog overlay + debounced watcher (V1 AR-2 deferred tail / gust G3-2)

**Standing**: the last explicitly-deferred AR-2 tail (V1's 2026-07-01 reconciliation:
everything else, including the cluster lease, shipped). The catalog is compile-time
`%Stage{}` code; no YAML-on-disk overlay, no watcher. Gust G3-3's disk-of-truth
reconciliation stays mooted *because* of this choice.

**Now?** No — demand-gated, and the single-operator deployment generates no demand:
catalog changes today are code changes by the same person who'd write the YAML.

**Trigger**: needing catalog changes without recompiling — per-project custom stages, or
a second operator profile whose stage set diverges. Adopting it un-moots G3-3 (the gust
doc owns that dependency).

## 9. Idle-based hang detection — activity watchdog (V2 §4 refinement)

**Standing**: the hang problem is covered by wall-clock bounds — the per-wave kill
deadline (`@default_wave_timeout_ms 300_000`, `route_composer.ex:213-215`), the durable
run `deadline_at_ms`, and the O-M2 park deadline. What the source added in the delta is
*earlier* detection: a transcript-mtime freeze check (~120s of no output → `TaskStop`)
alongside the absolute deadline, so a dead stage dies in ~2 minutes instead of eating the
full wall-clock budget.

**Now?** No — a progress-heartbeat liveness channel is real machinery for latency-only
payoff, and there's no evidence hangs are occurring at all, let alone routinely running
out the full wave timeout.

**Trigger**: observed hangs routinely consuming the full 300s wave timeout (the
`:wave_timeout` terminal showing up in run records with stages that produced nothing) —
latency pain that a ~120s idle kill would roughly halve.

---

**Minor footnotes** (tracked here so the inventories stay clean):

- **`git push` approval pattern** — **shipped 2026-07-02**. Not the one-liner the
  first note guessed: an unresolved git subcommand was benign (not opaque), so the
  gate needed real detection — a `pushes?` invocation fact in
  `ShellCommand.Git` mirroring `commits?`, a `:git_push` effect kind, and the
  `{:effect, :git_push}` require-pattern in `tool_approval.ex`. `run_command
  "git push"` (and its shell dressings) now pends like commit.
- **AR-1 residuals** — **both resolved 2026-07-02**: `gates/plan_gate.ex` now points
  retraction at the composer's signal-axis path, and the vestigial `Cases.retract/3`
  was deleted whole (with `commit_retract/5`, `ensure_not_resumed/3`, the
  `:approval_retracted` durable kind + projection arms, `AgentCase.reopen`, and the
  `:retracted` timeline kind — zero production callers). The citation sweep touched
  four files, not the three this note originally counted (`gate_disposition.ex`,
  `agent_case.ex`, `workflow_event/projection.ex`, plus `workflow_log.ex`'s passing
  mention).
- **More review lenses** (`simplicity-reviewer` et al.) — content adds over the shipped
  4-lens fan-out; add opportunistically when a review gap shows, don't plan. The
  simplicity lens overlaps the harness-level `/simplify` skill and the `quality` lens.
- **Persona v1 non-goals** — per-project persona overrides and the shipped-but-unused
  `user-advocate` stay by design; trigger would be per-project voice tuning demand or a
  `ux-prototyper`-analog stage joining the catalog. The `arbiter` persona rides #2.
- **Verbatim-relay discipline** (V1 §4 "worth adopting as an orchestrator convention if
  AR-2 is built") — settled **by construction**, recorded here since V1 never dispositioned
  it: the composer relays artifacts mechanically (resolved from `ComposerArtifact` at the
  wave boundary), so no LLM ever paraphrases a predecessor's output on the composed path.
