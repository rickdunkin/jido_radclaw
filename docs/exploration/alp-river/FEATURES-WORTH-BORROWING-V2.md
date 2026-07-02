# Features Worth Borrowing from Alp River — V2 (the v1.2.6 → v1.3.3 delta)

Exploration notes — not a plan, not a commitment. Inventory **2026-07-02**, against
alp-river **v1.3.3** `7088685` (52 agents / ~4,060 lines, ~2,606 hook lines excl. tests,
`WORKFLOW.md` 515 lines, 11 doctrine files, 10 personas) and the post-clustering
jido_radclaw tree (composer + WS1–WS5/WS4a shipped; all jido_radclaw cites in this doc
verified in-tree 2026-07-02).

> **Companion to [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) (V1) — read
> that first.** V1 is now a **closed ledger**: every entry it opened (AR-1..AR-8) has
> shipped, and its 2026-07-02 source-drift note re-stamped the source at v1.3.3 with
> "determinations unchanged" — deliberately declining to open new entries. This V2 gives
> the delta's *unadopted* candidates the full entry treatment V1's format defines
> (**Recommendation / Where / jido_radclaw gap / Relationship / Adoption sketch**, same
> FOLD-IN / BUILD-ON / INDEPENDENT / SKIP axis), continues V1's AR numbering (AR-9..AR-11),
> and records one delta item the drift note missed entirely (AR-11, the 1.3.0 plan-handle
> extension). Nothing here reopens a shipped V1 entry. The standing-and-triggers rollup of
> everything still unadopted across V1+V2 is [`UNADOPTED-IDEAS.md`](UNADOPTED-IDEAS.md).

## Determination (TL;DR)

The v1.2.6 → v1.3.3 delta contains **one substantive new borrow** (multi-plan
adjudication, AR-9), **one small ergonomic borrow with a real safety observation attached**
(the shipping tail, AR-10), and **one token-economy note** (artifact handles, AR-11).
Everything else in the delta is either already covered by what AR-2 shipped — in two cases
(premises, hang deadlines) the composer carried the durable/general version before or as
the source converged on it — or stays under V1 §4's SKIP verdicts. §4 below walks the rest
item by item.

| Delta item (v1.2.6 → v1.3.3) | Verdict | Entry |
| --- | --- | --- |
| **Multi-plan exploration + `plan-arbiter`** (1.2.13) | **BUILD-ON** (AR-2/3/5/6 substrate) — the one substantive new borrow; opt-in arming, not urgent | AR-9 |
| **Shipping tail** (`ship-gate`/`ship-executor`, 1.2.17/1.3.2) | **BUILD-ON, small** — route-level ship flow over the already-gated git tools; surfaces that `git push` is ungated today | AR-10 |
| **Artifact handles** (1.3.0 — missed by V1's drift note) | **NOTE, minor** — adopt only on prompt-cost evidence | AR-11 |
| Premises (4th loop-state piece) | **covered** — composer state has carried `premises` since AR-2 Phase 1; one refinement flagged | §4 |
| Background dispatch + mtime/deadline watchdog | **covered** — wave/run/park deadlines; idle-based early kill noted as a refinement | §4 |
| Durable run-state recovery (1.3.0/1.3.2) | **SKIP stands** (adjudicated in V1's drift note) | §4 |
| Briefs / render-card / card-only narration | **SKIP stands** (V1 §4) | §4 |
| Model re-tiering (fable/sonnet/haiku) | **already tracked** — the unwired `%Stage{}` seam; AR-9 is its natural first consumer | §4 |
| `simplicity-reviewer`, `/audit` 8 categories, arbiter persona, `## Anchor` lines | content-level / rides AR-9 / skip | §4 |

---

## §1 — The one substantive new borrow

### AR-9. Multi-plan exploration + plan-arbiter — a judge-panel plan wave

**Recommendation**: BUILD-ON (the shipped AR-2 composer + AR-3's lens-instantiation
pattern + the AR-5/AR-6 prompt seams). **Worth adopting; opt-in and not urgent** — armed
only on wide-design-space significant builds. This is the entry V1's drift note declined
to open ("noted, not recommended here"); on inspection the substrate fit is unusually
good, and the port would be *structurally safer than the source* (see Relationship).

**Where** (Alp River): `doctrine/multi-plan.md` + `agents/plan-arbiter.md`; cross-refs in
`WORKFLOW.md` `### Gates` ("on a multi-plan run the per-plan challengers run critique-only
and `plan-arbiter` is the in-route publisher instead, on its Adopt verdict") and
`## Milestone loop` ("a second, orthogonal choice the orchestrator makes off that same
`#significant-build` signal"). The shape:

- **Arming** (`multi-plan.md` ## Arming rule): multi-plan runs iff `#significant-build` is
  live AND the orchestrator judges the design space wide — several *materially different*
  architectural approaches, not stylistic variants. "Multi-plan is never the default; wide
  design space is the positive signal that arms it." A narrow space runs today's
  single-plan path unchanged.
- **Lens fan-out** (## Lens starter set / ## The lens injection mechanism): 2–3 parallel
  `code-planner` spawns, each under a named bias — **smallest-shippable / risk-first /
  dead-simple / reuse-first**. The lens rides as a **data input** (an optional
  `?planning-lens` slot filled per spawn), NOT psychology — the source's persona map keys
  per agent-*name*, so N same-name spawns cannot get distinct personas; "the per-spawn
  variation has to be a data input."
- **Critique-only challengers** (## Critique-only versus terminal challenger): one
  `plan-challenger` per plan with `<CRITIQUE_ONLY>` set — emits
  BLOCKERS/CONCERNS/STRENGTHS, omits the approval picker, never publishes
  `#plan-approved`. The **construction invariant** — on an armed run the arbiter MUST be
  the SOLE `#plan-approved` publisher — is, in the source's own words,
  "**CONVENTION-enforced, not statically checkable**": catalog-wise both challenger modes
  are the same stage, so only the orchestrator's fan-out discipline guarantees it.
- **The arbiter** (`agents/plan-arbiter.md`; model `fable`, effort `max` — their top
  tier): a **"selector, not a critic"** — steelmans each plan, finds complementary
  strengths, picks or grafts. Explicit tie-break ordering: **correctness/request-fit >
  grounding > simpler-first > validation/rollback > token/time cost**. Three verdicts:
  **Adopt** (the only one that publishes `#plan-approved`), **Hybrid** and **Revise-first**
  (backward edges via the Revision Contract — the grafted/revised plan re-earns approval).
- **Atomic co-publish** (## Atomic co-publish contract): `#critiques-ready` +
  `@competing-plans` + `@plan-critiques` must enter `live`/`available` in ONE recompose,
  else the arbiter composes input-less and drops as unsatisfiable. These are the first
  **orchestrator-sourced** seed values in their catalog (## Seed rationale).

**jido_radclaw gap** (verified 2026-07-02): the composer's plan phase is strictly
single-plan — one `planner` stage (`route_composer/catalog.ex:79`, over the `researcher`
template) → the human `plan-gate` (`catalog.ex:100`, `{:gate, "plan"}`), with the Phase-4e
`plan-rejected` edge re-firing the planner on rejection. No arbiter, no multi-plan, no
lens-parameterized planner anywhere in `lib/` (rg sweep). The arming-signal substrate
exists (`significant-build` is already a catalog signal gating the `architecture` lens);
the persona registry has 9 personas, no arbiter (the source added it as its 10th).

**Relationship to the shipped stack**: everything it needs exists, and two of the source's
weakest points get structurally stronger in the port:

- **Lens fan-out = AR-3's pattern, reapplied.** N lens-parameterized planner *stages* over
  one template is exactly how the catalog instantiates four reviewer lenses over the
  single `reviewer` template (`lens` is a first-class `%Stage{}` field), and lens-scoped
  outputs (`plan:<lens>`, mirroring `findings:<lens>`/`clean:<lens>`) keep N competing
  plans from colliding on one artifact name — `SignalMatch` is already family-prefix
  aware. The source's "lens can't ride psychology" constraint doesn't even bind here
  (AR-6 personas resolve **stage-first** via `catalog_stage_name`, so N planner stages
  *could* carry distinct personas) — but follow the source anyway: a lens is task bias,
  so thread it as stage `task`/input data; personas stay advisory voice.
- **The convention-enforced invariant becomes structural.** Distinct catalog stages mean
  the critique-only challenger stages simply never declare `plan-approved` in
  `publishes`, and the only `plan-approved` producer stays the gate reactor
  (`gates/plan_gate.ex`) — the composer's emission ⊆ `publishes` coherence check (see the
  `plan-gate` notes in `catalog.ex`) then enforces at the catalog layer what the source
  can only enforce by orchestrator discipline. The same pattern V1 celebrated for AR-2:
  the port is strictly more reliable than the source.
- **The atomic co-publish contract is native.** Wave commits are already atomic — signals
  and artifacts fold together in one `commit_wave` (the token-CAS fence; AR-4's rerun
  markers are welded into the same commit) — so "the trigger never fires before its batch
  is available" needs no new mechanism.
- **The human gate stays where AR-1 put it — a deliberate strengthening.** In the source
  the arbiter itself asks the user (its `ARBITER_DECISION` picker) and its Adopt publishes
  `#plan-approved`. In the port the arbiter is a worker whose decision memo *feeds the
  existing plan-gate*: Adopt ⇒ the gate presents the winning plan + memo for the normal
  human approve (the gate reactor remains the sole `plan-approved` emitter); Hybrid /
  Revise-first map onto the existing `plan-rejected` → planner re-fire edge, with the
  arbiter's graft seams / blocking critiques as the revision directive. No new gate kind,
  no `Gate.Kinds` change.
- **First consumer of the unwired tiering seam.** The source runs the arbiter at its top
  tier (`fable`/`max`). `%Stage{}` already carries `model`/`effort` fields that
  `WaveBuilder` never reads (V1 §4, re-verified 2026-07-02) — the arbiter stage is the
  natural first wiring of that seam (arbiter high-tier, lens planners standard).

**Cost, honestly**: an armed run pays roughly 2–3× the planning phase (N planners + N
critique-only challenger runs + one arbiter) before the gate. The single-plan path already
supports human reject → re-plan, so the marginal value concentrates narrowly: significant
builds where the first plan's *shape* — not its details — is the risk. That is why opt-in
arming is load-bearing, and why this is "adopt when a composer increment is next wanted,"
not a now item.

**Adoption sketch**:

1. **Arming signal**: triage (or the composer) publishes `multi-plan` only when
   `significant-build` is live AND a wide-design-space judgment holds — plausibly a new
   triage output field, mirroring how `est-size` ships as advisory in the source. Never
   the default.
2. **Catalog**: 2–3 lens planner stages (`planner-smallest-shippable`,
   `planner-risk-first`, `planner-reuse-first`) subscribing `multi-plan`, each over the
   existing planner template with the lens folded into the stage `task`, emitting
   lens-scoped `plan:<lens>` artifacts + `plan-drafted:<lens>` signals; the existing
   `planner` stays the single-plan default (the two modes kept disjoint by signals).
3. **Critique stages**: one critique-only challenger per lens (reuse the `reviewer`
   template with a plan-critique task, or a thin `plan_challenger` worker) emitting
   `critique:<lens>` — never `plan-approved`, structurally.
4. **Arbiter**: a new `plan_arbiter` worker template + Zoi decision-memo schema (per-plan
   steelman, complementary strengths, tie-break rung, selection, verdict enum
   `adopt|hybrid|revise_first` — **string** enum, per the Envelope round-trip rule) + an
   `arbiter` persona file (the source's 10th) + a doctrine slice carrying the tie-break
   ordering verbatim (via AR-5).
5. **Wire**: planners (one parallel Kahn wave) → challengers (second wave) → arbiter →
   the existing plan-gate presenting the memo; Hybrid/Revise-first ride `plan-rejected`.
6. Wire `%Stage{}` `model`/`effort` in `WaveBuilder` for the arbiter stage (the tiering
   seam's first consumer).

---

## §2 — Small borrow

### AR-10. The shipping tail — ship-gate + ship-executor at convergence

**Recommendation**: BUILD-ON (AR-2), **small**. Route-level ship ergonomics plus a durable
`shipped` terminal in the run record — and the analysis surfaces one real conversation-axis
observation (ungated `git push`) that is worth acting on *independently* of the borrow.

**Where** (Alp River): `WORKFLOW.md` `## Shipping`; `agents/ship-gate.md` /
`agents/ship-executor.md` (added 1.2.17; ship-to-main default 1.3.2, commit `09766a5`);
`agents/triage.md:51`. Opt-in and in-session only: triage publishes `#ship-requested`
**only when the request explicitly asks** to ship / release / open a PR — a marker
alongside `code`, never its own path. The tail is a **convergence appendix**, not a
woven-in stage: at convergence (empty route + empty held + all lenses clean) with
`#ship-requested` live, the orchestrator emits `#ship-ready` (a HARD REQUIRED
orchestrator-emit, seeded in SEED_SIGNALS), which re-populates the route with `ship-gate`
(`guard: sticky`; subscribes `#ship-ready`; output `@ship-verdict` — a user decision
naming the exact forward git/gh commands and the recovery for each target) and holds
`ship-executor` on its `{while: '#ship-ready', until: '#ship-approved'}` lock. Two
targets: **main** (one commit, push to `origin/<base>`, no PR — the 1.3.2 default) or
**branch** (feature branch, `git push -u`, `gh pr create --draft`). The executor
preflights `git remote get-url origin` (and `gh auth status` for the branch target)
before any local mutation, composes ONE conventional commit for the session's work, and
publishes `#shipped`; true convergence is only after the route empties again.

**jido_radclaw gap** (verified 2026-07-02): the composer's `code` path converges after the
fix/re-review loop with the working tree dirty; the catalog (16 stages) has no ship stage.
Shipping happens on the conversation axis afterward: the operator asks, and the
`git_commit` tool (in `ToolApproval.default_require/0`) plus the `run_command`
`git commit` param-pattern gate the commit. GitHub PR machinery exists
(`PullRequestCoordinator`) but nothing route-level composes a ship step. **The
observation**: the approval patterns cover `git commit` (and crontab / git-config
injection) but there is **no `git push` pattern** (`security/tool_approval.ex`, rg
verified) — so remote publication via `run_command "git push"` is ungated on the
conversation axis today. That gap is fixable with a one-line pattern add regardless of
whether this borrow ships; the route-level ship gate would additionally give the composed
flow a proper human checkpoint on publication.

**Relationship to the shipped stack**: maps onto three existing parts — a triage marker
signal (`ship-requested`, exactly like the path + early-signal emissions triage already
makes), the gate family (`{:gate, "ship"}` alongside plan/safety — AR-1's decision-kind
taxonomy already has the shape), and an executor stage whose worker calls the
already-gated git tools. **The one real design question is double-gating**: a route-level
ship gate (human picks main vs branch+PR) followed by the tool-approval gate on
`git_commit` would prompt the operator twice for one intent. Options: (a) the ship gate's
approval pre-mints the tool approval for the exact canonical fingerprint the executor will
produce (the ToolApprovals producer already keys on `{tenant, session, tool, args}`;
single-use `:consume` semantics fit) — the first case where a workflow-axis gate and the
conversation-axis gate deliberately compose; (b) accept the double prompt (annoying but
safe); (c) exempt the executor from the tool gate — rejected, that weakens the
conversation-axis floor. (a) is the honest design.

**Adoption sketch**: (1) triage emits `ship-requested` on explicit ship/release/PR asks;
(2) the catalog adds `ship-gate` (`{:gate, "ship"}`, subscribing a composer-emitted
`ship-ready` — the convergence-time emit is the one new composer touch) and
`ship-executor` (a thin worker over `git_commit` + `run_command` `git push` /
`gh pr create --draft`, publishing `shipped`); (3) resolve double-gating per (a); (4)
independently of all of the above, consider adding a `git push` require-pattern to
`ToolApproval` — the cheapest piece and arguably the most valuable.

---

## §3 — Note

### AR-11. Artifact handles — artifacts on disk, handles in context

**Recommendation**: NOTE, minor — record the idea; adopt only if telemetry shows large
many-consumer artifacts (the plan, big diffs) dominating sub-agent prompt cost. Logged
here mostly because **V1's 2026-07-02 drift note missed it**: the 1.3.0 commit is
"durable run-state recovery **and plan-handle extension**" (`06712b4`), and the note
covered only the first half.

**Where** (Alp River): `WORKFLOW.md` `### Artifact handles` (under Input Template
Contract). When one large `<APPROVED_PLAN>` must reach many consumers, the orchestrator
has it written to disk ONCE (`.alp-river/artifacts/plan-<slug>.md` — the producer performs
the write) and hands each consumer a **read-imperative handle** ("Read the verbatim
<APPROVED_PLAN> at <path> — its bytes ARE the artifact") instead of paying the bytes into
every fill. The details are careful: a **union gate** (offload only when the block exceeds
~1500 chars AND (the parallel review wave carries >1 plan-consuming reviewer OR
`#significant-build` is live)); a **single owner** of the threshold (the orchestrator
measures; the producer never re-measures); **three inline carve-outs, each with a
reason** — `plan-adherence-reviewer` needs the exact version pinned at implementer spawn
(an overwrite-in-place file cannot guarantee it), `plan-arbiter` reads N distinct
competing plans one shared file cannot serve, `safety-gate` is a solo consumer so the
indirection buys nothing; and **boundary-only overwrites** under the milestone loop
(never swap the file under a reading consumer). `input_template` does not change — the
handle is a fill-time choice.

**jido_radclaw coverage**: half-covered by better machinery on a different axis. Composer
artifacts are already durable and ref-addressed (AshCloak-encrypted `ComposerArtifact`
rows, `art_…` refs single-sourced with `Refs.mint/1`) — but they are "resolved only at the
wave boundary" and **inlined** into stage prompts (`route_composer.ex:62`), so a large
plan reaching test-author + implementer + four reviewers + fixer pays its bytes into each
sub-agent prompt. The lazy half exists on the *tool-output* axis (`fetch_output` resolves
a ref on demand, tenant- and session-scoped per S-M2) but has no stage-input analog.

**Adoption sketch (if ever)**: above a size threshold, `WaveBuilder`/`AgentRunner` thread
the `art_…` ref plus a read-imperative line instead of the inline body, backed by a
read-only composer-artifact fetch tool scoped with the same discipline as `fetch_output`
(session scoping; the artifact is encrypted at rest, so the fetch is the decrypt
boundary). Carry the source's carve-out reasoning: any version-pinned consumer (a
plan-adherence-style check, if one ever ships) stays inline. The trade is prompt bytes vs.
one tool round-trip per consumer — measure before building.

---

## §4 — Covered by the shipped composer, or SKIP stands

- **Premises (the 4th loop-state piece)** → **covered — the composer already carries it.**
  `premises` is first-class composer state (`route_composer.ex:32` —
  `live`/`artifacts`/`ran`/`premises`/`prev_route`/`wave_index`), in the tree since the
  composer's first phase (AR-2 Phase 1, `c7a428af`, 2026-06-18..22 — before or as the
  source's delta grew the same piece): seeded via start opts, projected latest-wins from
  the event log (`projection.ex:177-180`), with premise-break self-reporting *enforced by
  the catalog validator* — every stage must declare `scope-shift` ∈ `publishes`
  (`catalog_validator.ex:34`) — and consumed by the automatic stale-approval retraction
  (`route_composer.ex:2894-2898`). Convergent evolution, not a gap. **One residual
  refinement**: Alp River *hands each stage the premises* so breaks are reported against
  an explicit list ("each stage is handed these and reports breaks", `WORKFLOW.md`
  ### The loop); here stages self-report `scope-shift` without seeing the premise list
  (no premises threading in `wave_builder.ex`/`agent_runner.ex` [likely — rg sweep]).
  Threading premises into the stage task context would ground the self-reports —
  note-tier, bundle with the next composer increment.
- **Background dispatch + mtime/deadline watchdog** → **covered.** The hang problem the
  source solves with background Agent dispatch + a transcript-mtime freeze check (~120s)
  + an absolute wall-clock deadline (+ `TaskStop`, missing-output recovery) is handled
  here by the per-wave kill deadline (`@default_wave_timeout_ms 300_000`,
  `route_composer.ex:213-215`, AR-2 Phase 2b C3), the durable run-level `deadline_at_ms`,
  and the O-M2 sensitive-park deadline — with recovery riding the event log rather than
  reconcile-from-tree. The genuinely new bit is *activity-based early detection* (kill at
  ~120s idle instead of waiting out the wall clock); a progress-heartbeat variant would
  shave hang latency but adds a liveness channel — not worth it absent evidence of hangs
  routinely eating the full wave timeout. The "orchestrator keeps cranking while a stage
  runs in the background" half is Claude-Code-harness-loop-specific: the composer is a
  GenServer that runs waves synchronously by design.
- **Durable run-state recovery (1.3.0/1.3.2)** → **SKIP stands** — already adjudicated in
  V1's drift note: the event-log projection + WS3 rebuild-and-resume is the durable,
  general version of the source's per-turn disk snapshot + SessionStart recovery hook
  (whose own doc is honest that the snapshot is best-effort and the real backstop is
  route-recomputation plus reconcile-from-tree).
- **Briefs / render-card / card-only narration** → **SKIP stands** (V1 §4): Claude-Code
  REPL UX; `Display` + the LiveView dashboard own this surface here.
- **Model re-tiering (fable/sonnet/haiku since 1.3.3)** → **already tracked**: V1 §4
  carries it; the `%Stage{}` `model`/`effort` fields remain unwired (`WaveBuilder` never
  reads them, re-verified 2026-07-02). AR-9's arbiter is the natural first consumer — see
  that entry, sketch step 6.
- **`simplicity-reviewer` (15th lens)** → content-level, no entry. AR-3 deliberately
  started with 4 of the source's lenses; a simplicity lens is a cheap catalog + persona
  add if wanted, and partially overlaps the harness-level `/simplify` skill and the
  `quality` lens. Add opportunistically, don't plan.
- **`/audit` eight health categories (was five at 1.2.6)** → skip, as at v1.2.6: a
  deterministic self-scorecard *command* in the source; jido_radclaw's audit surface is
  the harness-level `audit` skill. No borrow.
- **`arbiter` persona (10th) + `## Anchor` lines** → rides AR-9. The persona file lands
  with the arbiter worker if AR-9 ships; the Anchor-line format is a source-side styling
  choice AR-6's renderer doesn't need (the conflict rule is already single-sourced in the
  renderer, a stronger version of what Anchor lines standardize).

## Bottom line

The delta validates more than it teaches: the source spent 18 commits converging on
durability and state-tracking the composer already had in stronger form (run-state
snapshots vs. the event log; premises vs. the composer's since-Phase-1 premises).
What it does teach is concentrated in **AR-9** — a judge-panel plan wave whose port would
be structurally safer than the original (catalog-enforced sole-publisher invariant, native
atomic co-publish, the human gate unchanged) and which doubles as the first consumer of
the unwired per-stage tiering seam. **AR-10** is a small ergonomic tail on parts that all
exist — and its analysis yields one immediately actionable observation (`git push` has no
approval pattern today) that stands on its own. **AR-11** is a recorded idea awaiting cost
evidence. None of it is urgent; all of it is now written down.
