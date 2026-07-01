# Features Worth Borrowing from Alp River

Exploration notes — not a plan, not a commitment. Inventory **2026-06-06**, re-audited
**2026-06-11** against alp-river v1.2.6 and the post-Reactor jido_radclaw tree (see the
status section).

Source: `~/workspace/claws/alp-river` — **Alp River** (author: Alper Ortac; MIT; v1.2.6;
73 commits, 2026-04-26 → 2026-06-06, single author). It is a **Claude Code plugin**, not an
Elixir library: ~3,740 lines of markdown agent definitions (48 of them), ~2,150 lines of
Python+Bash hooks (excluding tests), a 429-line `WORKFLOW.md` doctrine, 8 doctrine files,
and 9 persona files.
Tagline: "a river of agents, composed to the task." It is a **multi-agent workflow
methodology** — a deterministic router (`hooks/route.py`) composes the exact pipeline of
specialized sub-agents a task needs, grows it as the task reveals itself, reviews in
parallel, and self-heals.

> **Read this with [`../squidie/REACTOR-ADOPTION.md`](../squidie/REACTOR-ADOPTION.md) and
> [`../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md)
> open.** When this was written, the Squidie work (adopt Reactor as the workflow engine +
> the durable event-log envelope) was the **immediate next feature**, and the document is
> written through that lens: what about Alp River should *inform* the Squidie build, what
> *builds on top of it afterward*, and what is *independent* — deliberately so that nothing
> here is mistaken for a reason to delay or reshape Squidie. **The Squidie work has since
> shipped** (Phases 0–5, 2026-06-08..10) — with this document's one fold-in (AR-1) folded
> in as recommended. The lens stands; outcomes are annotated inline below.

## Status reconciliation — 2026-07-01 (AR-2's cluster-lease tail has since shipped)

**This section supersedes every "cluster lease deferred / parked until clustering" claim
below (including the 2026-06-27 header).** AR-2's Phase-6 **cluster lease** (gust G1-1) — the
one deferred tail that was about durable multi-node claiming — **shipped in full** as the
clustering workstream **WS1–WS5 + WS4a** (2026-06-27..30, [`../../plans/clustering/`](../../plans/clustering/README.md)),
re-derived around the composer unit (WS2 renews the parent composer across waves and gate
pauses; WS3 rebuilds composer state from the event log and resumes mid-route). Cross-node
cancel (gust G3-1) shipped with it (WS5). **The only AR-2 tail still open** is the *optional*
`.jido/` YAML catalog overlay + debounced watcher (gust G3-2) — the composer catalog shipped
as compile-time `%Stage{}` code, not YAML-on-disk, so gust G3-3's disk-of-truth reconciliation
stays mooted. See [`../gust/FEATURES-WORTH-BORROWING.md`](../gust/FEATURES-WORTH-BORROWING.md)
§G1-1 for the component-by-component record.

## Status reconciliation — 2026-06-27 (AR-7 shipped in full; only AR-2's deferred tails remain)

**This section supersedes the "only AR-7's pervasive extension remains" claims in the
2026-06-26 reconciliation and every entry below.** The Alp River source-audit baseline is
unchanged; only jido_radclaw's implementation has moved. AR-7 was the last open *independent*
borrow.

- **AR-7 (confidence-tagging) — DONE** (2026-06-27). The pervasive convention now ships as a
  standalone reach-all doctrine slice. `priv/defaults/doctrine/confidence_tagging.md` (registered
  in `JidoClaw.Doctrine` as the 8th slice) defines the `likely`/`unsure` evidence tag as a
  **per-claim or per-finding** marker — set in a finding's own `confidence` field where one
  exists, otherwise tagged inline in prose (`[likely]`/`[unsure]`) — plus the rule that a worker
  with an *overall* confidence field on another scale (`low`/`medium`/`high`) keeps that scale and
  never emits `likely`/`unsure` into it, and the **source-URL requirement** for web-sourced
  claims. It reaches the **10 non-reviewer** sub-agent templates (`coder`, `fixer`, `refactorer`,
  `docs_writer`, `researcher`, `test_runner`, `verifier`, `sketch_build`, `sketch_build_exec`,
  `system_executor`); the reviewer family (`reviewer`, `sketch_reviewer`, `system_verifier`) is
  **excluded** because its `reviewer_contract` slice already carries the equivalent per-finding tag
  (avoiding the content-overlap smell). Enforcement is honest about its two tiers: the tag is
  **structurally enforced** (a required Zoi string enum) on exactly one non-reviewer surface —
  `researcher` findings, which gained a per-finding `confidence` + the source-URL-in-`references`
  rule (the reviewer family already had theirs from AR-3) — and is a **prompt-enforced
  convention** on the other nine workers' prose output (`summary`/`notes`/`reasoning`), whose
  schemas have no per-claim list to attach a field to. The `verifier` receives the doctrine prose
  only (its flat `verdict`/`confidence`/`reasoning` schema is unchanged — the deliberate "verifier
  has a different schema" boundary), and the main agent is untouched (AR-7 stays on the sub-agent
  doctrine seam, consistent with AR-3/AR-5/AR-6 — `priv/defaults/system_prompt.md` is not edited).
  `mix precommit` green.

**Remaining live backlog**: only AR-2's explicitly-deferred tails (cluster lease, YAML catalog
overlay). Every *independent* prompt-layer borrow (AR-3, AR-5, AR-6, AR-7) and the
composer/review/self-heal/triage stack (AR-2, AR-3, AR-4, AR-8) has shipped.

## Status reconciliation — 2026-06-26 (AR-6 shipped; AR-7 partial — its pervasive extension since shipped 2026-06-27)

**This section supersedes the "AR-6 remains / NOT STARTED" claims in the 2026-06-25
reconciliation and the entry below.** The Alp River source-audit baseline is unchanged; only
jido_radclaw's implementation has moved. AR-6 was the last not-started *independent* borrow.

- **AR-6 (personas) — DONE** (2026-06-26). `JidoClaw.Persona` (`lib/jido_claw/persona.ex`) is a
  priv-file-backed persona registry — 9 personas in `priv/defaults/persona/*.md` (cynic, skeptic,
  detective, defender, optimist, pragmatist, teacher, user-advocate, craftsperson) — injected as a
  `## PSYCHOLOGY: <Name>` block through the AR-5 `Agent.SubagentPrompt` seam (`build/2` → `build/3`).
  The borrow's one structural improvement over the source: personas resolve **stage-first** (the
  catalog stage name) with a **template-name fallback**, so the four reviewer *stages* over the
  single `reviewer` template get **distinct** voices (security→defender, quality→craftsperson,
  correctness→skeptic, architecture→pragmatist) — template-only keying (how Doctrine keys) would
  collapse them to one. Advisory-only: the renderer **single-sources** the mandatory conflict rule
  ("your role contract is mandatory; persona is advisory voice; on conflict the role and the
  codebase win") onto every block, so it can never drift. The composer stage travels on a
  **dedicated `catalog_stage_name` option** set only by `WaveBuilder` (never the overloaded
  `step_name`, which doubles as the YAML/skill-step label) — threaded through
  `AgentStep`/`AgentRunner` → `Startup.inject_subagent_prompt/4` (which also adds `stage:` to the
  `[:jido_claw, :agent, :prompt_injected]` telemetry). Section-gated by a new `config :jido_claw,
  :psychology` (with `:doctrine` still the **master** injection gate — psychology off never
  re-enables injection, psychology only toggles the one section). Reaches exactly the AR-5 seam's
  three sub-agent paths (initial spawn, skill/composer step, follow-up turn); the main agent and
  handoff-routed workers get **neither** doctrine nor persona — AR-5's boundary, unchanged. 8 of 9
  personas are selected; `user-advocate` ships and renders but is intentionally unused (no
  `design/ux-prototyper` analog in this catalog). No per-project overrides (v1 non-goal).
  `mix precommit` green.

**Remaining live backlog** *(at this 2026-06-26 snapshot; AR-7's pervasive extension has since
shipped 2026-06-27 — see the reconciliation above)*: AR-7's pervasive confidence-tagging extension
(its reviewer-surface core shipped in AR-3), plus AR-2's explicitly-deferred tails (cluster lease,
YAML catalog overlay).

## Status reconciliation — 2026-06-25 (AR-2 / AR-3 / AR-4 / AR-5 / AR-8 shipped; AR-6 since shipped 2026-06-26, AR-7 since done 2026-06-27)

**This section supersedes the forward-looking claims in the 2026-06-11 reconciliation below**
(notably its "None of AR-2 … AR-8 has landed" line — true when written, now stale). The Alp
River source-audit baseline is unchanged; only jido_radclaw's implementation has moved.
Verified by a per-item in-tree sweep on 2026-06-25.

Since 2026-06-11 the BUILD-ON/INDEPENDENT backlog this document framed as "next" has largely
shipped:

- **AR-2 (the composer) — DONE** (planned scope). The deterministic signal-driven route
  composer shipped Phases 0–5 (`012f17fe`..`1eedf44f`, 2026-06-18..22): `JidoClaw.RouteComposer`
  is a supervised subsystem live on the real turn path via `JidoClaw.FrontDoor.decide/2` — the
  five-step pure `compose_route` + Kahn waves, each wave built via `Reactor.Builder` and run
  through `ReactorRunner`; a durable composer event-log/projection with an AshCloak-encrypted
  `ComposerArtifact` ref-store (resolving the Phase-2 blocker); crash recovery; human gates in
  the composer (Phase 4); and MCP observe (`inspect_workflow` + the `jido://workflows/catalog`
  resource). 222 composer test cases, zero skips. What's left is exactly what the plan parked:
  the Phase-6 cluster lease (gust G1-1) and the optional YAML catalog overlay (gust G3-2). (The
  AR-4 fixer workflow that reused the rerun primitive has since shipped — see AR-4 below.)
- **AR-5 (doctrine injection) — DONE** (`9127b2a7`, 2026-06-22). `JidoClaw.Doctrine` registry +
  per-template slice map, injected into spawned, skill-step, and follow-up sub-agents (the exact
  main-agent-only gap it targeted), with the duplicated worker schemas single-sourced in
  `Agent.Workers.OutputSchema`.
- **AR-8 (conversation-type triage) — DONE** (`5f702d48`..`1994eee6`, 2026-06-23..25). Grew well
  past the original "cheap Classifier upgrade": an always-on triage seed publishing one of
  talk/sketch/code/system per turn, all four paths wired into the live turn — including the
  sketch path (AR-8b), sketch graduation + `:docker` exec tier (AR-8b-2), and the system path
  (AR-8c). Sole caveat: the Docker exec tier's real-OS isolation is verified only in manual
  `@docker_sandbox` tests (excluded from CI by design).
- **AR-1 (gate semantics) — the open tail this document tracked is now CLOSED.** AR-2 Phase 4
  (composer human gates) gave the `plan` gate and the `tool_call` gate live producers and made
  stale-approval retraction **automatic** in the composer (`route_composer.ex`
  `retract_stale_approval`), so AR-1's "only `irreversible_write` has a producer / retraction is
  operator-initiated" tail no longer holds. (See the amended AR-1 outcome note for the two
  residuals: the now-vestigial case-axis `Cases.retract`, and two stale in-code/in-doc claims.)
- **AR-3 (reviewer fan-out + contract) — DONE** (`2026-06-25`). The fan-out was already built (the
  composer catalog instantiates the one `reviewer` template as four risk-gated lenses — security,
  quality, correctness, architecture — dispatched as a parallel wave with lens-scoped findings);
  the shared-contract **content** now ships too. Two doctrine slices, split by *reach*:
  `reviewer_min` (expanded from the placeholder to field-agnostic universal judging discipline —
  the concrete-consequence bar, the anti-double-flag rule — reaching all four read-only judges) and
  the new `reviewer_contract` (the VERDICT/FINDINGS/ACTION_NEEDED shape + confidence tagging,
  reaching only the three `reviewer_verdict/0` workers). The `reviewer_verdict/0` schema gained a
  per-finding `confidence` (`likely`/`unsure`) + `location` and a top-level `action_needed`. This
  also lands **AR-7's core** on the reviewer surface (see below).
- **AR-4 (self-heal fixer loop) — DONE** (the literal version, later on 2026-06-25). The `fixer`
  became a first-class worker, and the composer's two-phase loop wires review → fix → re-review on
  the `code` path: the domain-touched RE_RUN_SET (flagged ∪ domain-touched ∩ ran) with never-ran
  lens summoning, and a distinct `:route_fix_failed` terminal on cap exhaustion. (The AR-8c
  system-path reverse-verify loop is its sibling — a different feature.)
- **AR-6 (personas) — NOT STARTED** *(true at this 2026-06-25 snapshot; **since shipped
  2026-06-26** — see the reconciliation above)*. No code; AR-5 left no pre-wired `## PSYCHOLOGY`
  seam, so it remained a clean greenfield add on top of the now-existing doctrine registry.
- **AR-7 (confidence-tagging) — PARTIAL** *(true at this 2026-06-25 snapshot; the pervasive
  extension **since shipped 2026-06-27** — see the reconciliation above)*. Its core — the
  `likely`/`unsure` per-finding tag and the reporting threshold — shipped folded into AR-3 on the
  reviewer surface (the `reviewer_contract` slice + the schema `confidence` field). The *pervasive*
  convention (codebase-wide claim tagging on `researcher` / web-sourced agents, the source-URL
  requirement) was still not started at this snapshot.

**Remaining live backlog** *(at this 2026-06-25 snapshot; AR-6 has since shipped 2026-06-26 and
AR-7 since 2026-06-27)*: AR-6 (personas), AR-7 (extend confidence-tagging past the reviewer
surface) — plus AR-2's explicitly-deferred tails (cluster lease, YAML catalog overlay).

## Status reconciliation — 2026-06-11 (Squidie shipped; AR-1 landed)

**jido_radclaw drift since 2026-06-06 that touches entries below**: the Squidie/Reactor
work this document deferred to **shipped in full** — Phases 0–5, 2026-06-08..10
(`REACTOR-ADOPTION.md` § "Status reconciliation" is the ledger). The workflow engine is now
a durable, event-sourced Reactor runtime: `WorkflowRun.status` is a pure projection of an
append-only `WorkflowEvent` log (the stranding bug is gone), YAML skills compile to
`%Reactor{}` via `JidoClaw.Skills.Compiler`/`Reactor.Builder`, `ReactorMiddleware` is the
sole event producer, human gates durably halt/resume via `GateStep`/`GateResume`, and
`WorkflowRecovery` reconciles stranded runs at boot. Consequences for this document:

- **AR-1 is done.** Both lifecycle rules shipped inside Reactor Phase 2, labeled "AR-1" in
  the code and the Squidie docs — which now cite this document back (`REACTOR-ADOPTION.md`
  §4.5 carries a "Design input — Alp River AR-1" blockquote). See AR-1's outcome note for
  the one remaining tail (the automatic re-plan retraction trigger).
- **The three static workflow drivers this document cites were deleted in Phase 3**
  (`PlanWorkflow`, `IterativeWorkflow`, `StepAction`). Parallel-phase semantics are now
  native Reactor DAG topology (`skills/compiler.ex`), the generator/evaluator loop survives
  as `Skills.Steps.IterativeStep`, and produces-injection lives in
  `AgentRunner.inject_produces_instruction/2`. Affected cites updated inline (AR-3/4/5, §4).
- **None of AR-2 … AR-8 has landed** (re-verified by sweep 2026-06-11): the reasoning layer
  is untouched by the Reactor migration — `Classifier` still picks one static strategy,
  `PipelineStore`/`RunPipeline` still run static chains, the two reasoning signals are still
  write-only, and there is still no composer, no reviewer fan-out, no doctrine injection, no
  personas, no triage front door. The BUILD-ON items are **unblocked**; AR-2 (the composer)
  is now the natural next feature. *(Superseded as of 2026-06-25 — see the reconciliation above:
  AR-2, AR-3, AR-4, AR-5, and AR-8 have since shipped and AR-1's tail closed, with AR-7's core
  folded into AR-3; AR-6 has since shipped too (2026-06-26) and AR-7's pervasive extension
  (2026-06-27), leaving only AR-2's explicitly-deferred tails open.)*

**Alp River drift since the inventory**: one commit (2026-06-06, v1.2.5 → **1.2.6**): a
deterministic **`/audit` self-scorecard** (`hooks/audit.py`, scoring five health categories
— a command, *not* a hook; `route.py` remains the only deterministic decision-maker in the
orchestration loop), a **memory-conventions doctrine** (`doctrine/MEMORY-CONVENTIONS.md`,
doctrine count 7 → 8) with `/reflect` extended to propose-then-approve memory writes,
explicit **silent-failure patterns** added to the correctness reviewer, and a new
`## Instruction-to-hook` WORKFLOW section ("an instruction you keep repeating to agents
should become a deterministic hook") — WORKFLOW.md 420 → 429 lines, hooks (excl. tests)
1,871 → 2,148 lines. Nothing in 1.2.6 changes a determination below; the instruction-to-hook
practice is the same determinism-over-prose philosophy AR-2 already captures.

## Determination (TL;DR)

**Alp River is not a competitor to the Reactor direction — it is the methodology layer that
sits *above* the engine Squidie built. The original call — ship Squidie unchanged, fold in
exactly one thing (gate semantics), everything else builds on the new engine afterward or is
independent — played out exactly: Squidie shipped (Phases 0–5) with AR-1 folded into
Phase 2. The BUILD-ON/INDEPENDENT backlog has since shipped in full — as of 2026-06-27:
AR-2, AR-3, AR-4, AR-5, AR-6, AR-7, and AR-8 done (AR-7's reviewer-surface core folded into
AR-3, its pervasive extension shipped 2026-06-27); only AR-2's explicitly-deferred tails remain.**

Alp River and Squidie/Reactor solve **different layers**:

- **Squidie/Reactor** (shipped 2026-06-08..10) is the *durable execution substrate*: a bounded, **declared** DAG
  (Reactor) wrapped in an append-only event log, status-as-projection, crash recovery, and
  human gates. Its scope note draws a hard line — `REACTOR-ADOPTION.md` §6: declared DAGs run
  on Reactor; "the agent ReAct loop and the swarm are dynamic … Don't force them into
  Reactor." Bounded-and-declared on one side, free-form-LLM-loop on the other.
- **Alp River** fills the **middle ground that line leaves open**: a workflow that is *neither*
  a fully pre-declared DAG *nor* a free-form ReAct loop, but a **deterministically composed**
  pipeline that grows from signals as the task reveals what it needs. The route is a *pure
  function* of state (`hooks/route.py`), not an LLM's whim — legible, recomposable, and gated,
  without the unpredictability of open-ended ReAct.

That is the headline insight: **the "dynamic, not-a-declared-DAG" space Squidie consigns to
the free-form agent loop can instead be a deterministic, signal-composed loop** — and Alp
River is a mature, working reference for it.

| Alp River capability | Relationship to the Squidie work | Status (2026-06-27) |
| --- | --- | --- |
| **Gate / lock semantics** (while/until, abandon-terminal, stale-approval retraction) | **Informed** Squidie Phase 2 (human-gate DSL, `REACTOR-ADOPTION.md` §4.5) | **DONE** — Phase 2; tail closed by AR-2 Phase 4 (AR-1) |
| **Signal-driven route composer** (the crown jewel) | **Builds on** Reactor — the dynamic layer above the engine | **DONE** — Phases 0–5 (AR-2) |
| **Reviewer fan-out + shared contract** | **Builds on** Reactor — a concrete first workflow | **DONE** — 4-lens fan-out + authored contract content (AR-3) |
| **Self-heal fixer loop** | **Builds on** Reactor's `recurse`/iterative steps | **DONE** — first-class fixer + domain-touched RE_RUN_SET + summoning + `:route_fix_failed` (AR-4) |
| **Central doctrine injection into sub-agents** | **Independent** of the engine — pure prompt assembly | **DONE** (AR-5) |
| **Psychology / persona layer** | **Independent** — pure prompt assembly | **DONE** — stage-first `## PSYCHOLOGY` injection through the AR-5 seam (AR-6) |
| **Confidence-tagging convention** | **Independent** — output/prompt convention | **DONE** — reviewer-surface core folded into AR-3; pervasive `confidence_tagging` slice (10 non-reviewer templates) + `researcher` per-finding tag (AR-7) |
| **Conversation-type triage** (talk/sketch/code/system) | **Independent** front door; folds into AR-2 if built | **DONE** — all four paths, folded into AR-2 (AR-8) |
| Hook substrate, `.md`/`.py` artifacts, render-card UX, compaction/reinject | Re-implement or already covered | **SKIP** (§4) |

## Why not "adopt as a dependency"

Unlike every other exploration in this folder (gust, hermes, squidie, jidoka are Elixir),
Alp River is a **Claude Code plugin** — markdown agents + Python/Bash hooks orchestrated by
the Claude Code harness. There is **nothing to add to `mix.exs`**. Every borrow is
**pattern-level**: re-implement the *concept* in Elixir/Jido/Ash/Reactor. The good news is
that the concepts map astonishingly well onto substrate jido_radclaw **already has but
under-uses** — `Jido.Signal.Bus` (still observability-only), YAML-defined skills with
`depends_on` DAGs (since Phase 3 compiled straight to Reactor), the human-gate machinery
(bare scaffolding at the time; shipped for real with Reactor Phase 2 — see AR-1's outcome
note), `ToolContext` child-forwarding, and the `Reviewer` worker with Zoi structured outputs.

A second, quieter advantage: Alp River's own orchestrator is **an LLM following ~430 lines of
prose** (`WORKFLOW.md`). Only the *route composition* is deterministic (`route.py` is a pure
function the LLM calls). A jido_radclaw port can make the **whole composer** a real GenServer
+ pure function — strictly more reliable than the source.

## How to read this document

Recommendation axis: **FOLD-IN** (inform the Squidie build — done; the one FOLD-IN shipped)
/ **BUILD-ON** (needs the engine — which now exists) / **INDEPENDENT** (orthogonal to the
engine) / **SKIP**. Per entry: **Recommendation**, **Where** (Alp River cites),
**jido_radclaw gap**, **Relationship to Squidie**, **Adoption sketch**. Alp-River cites are
accurate to the file (re-checked against v1.2.6); jido_radclaw cites were verified by
subagent sweep of `lib/` and re-verified 2026-06-11 after the Reactor migration — stale
cites updated inline.

---

## §1 — Fold into the Squidie work now

### AR-1. Gate & lock semantics — inform the human-gate DSL (Squidie Phase 2 / §4.5)

**Recommendation**: FOLD-IN — **done; shipped with Reactor Phase 2 (2026-06-08)**. The
single thing here that needed to touch the Squidie build *as it happened*, because designing
the gate DSL twice was the waste to avoid — and it did; see the outcome note at the end of
this entry.

**Where** (Alp River): `WORKFLOW.md` `## Locks` and `### Gates` (under `## Pipeline`). A
**lock** is a scheduling gate in frontmatter — `{while: '#sig', until: '#sig'}`, three
states (inactive / held / released), multiple locks **AND** together
(`hooks/route.py:101-107` `_active_locks`, `:163-171` the held-set computation). Three
concrete gates ship:

- **plan-approval** `{while:#plan-ready, until:#plan-approved}` — unconditional on every code/
  system build; no code starts against an unapproved plan.
- **safety** `{while:#destructive-op, until:#safety-approved}` — holds a destructive system
  step until the user clears it.
- **TDD** `{while:#needs-tests, until:#tests-ready}` — holds the implementer until red tests
  are validated.

A **gate** is "a stage whose output is a user decision" (rendered via `AskUserQuestion`), and
two lifecycle rules are the load-bearing part: **`abandon` is a run-terminal** (drops any
stage still held behind the abandoned gate, rather than waiting forever for an `until` that
will never fire — `WORKFLOW.md` `## Gates`), and **stale-approval retraction** (a
pre-implementation re-plan removes `#plan-approved` from the live set so the revised plan must
*re-earn* approval — `WORKFLOW.md` `## Convergence`).

**jido_radclaw gap** *(as written 2026-06-06 — since closed; see the outcome note)*:
`JidoClaw.Orchestration.ApprovalGate` (`create/approve/reject`) and
`WorkflowRun.await_approval`/`resume` **exist but have zero callers** anywhere in `lib/` —
scaffolded, never wired. Squidie's `REACTOR-ADOPTION.md` §4.5 is *about to design* the
human-gate Spark DSL "declaring the *kind* of decision (`tool_call`, `plan`,
`irreversible_write`, …)" with `after_approved/2` / `after_rejected/2` hooks.

**Relationship to Squidie**: Alp River is a working, thought-through design of exactly that
DSL's decision-kinds and lifecycle. The `while/until` lock **is** a Reactor `{:halt}` guard
made declarative; its AND-together composition is "multiple guards on one step." Its
`abandon → terminal` maps onto Squidie's `after_rejected → terminal` (§4.5 step 4). Its
**stale-approval retraction** is a concrete semantic Squidie's gate design had *not* yet
addressed (it since has — by adopting exactly this rule) — and §4.8's recovery already
distinguishes "decision recorded" from "unresolved gate," so the retraction rule slots in
cleanly.

**Adoption sketch**: when building Squidie Phase 2, model the human-gate DSL's decision-kind
enum on Alp River's gate types (plan-approval, safety/irreversible, tool-call), and adopt the
two lifecycle rules verbatim: `abandon` cancels held downstream steps; a pre-implementation
re-plan retracts `#plan-approved`. Cost is near-zero (it's a design input, not new code) and
it prevents shipping a gate model that later needs the abandon/retraction semantics bolted on.

**Outcome (shipped Reactor Phase 2, 2026-06-08; verified in-tree 2026-06-11)**: adopted as
recommended — `REACTOR-ADOPTION.md` §4.5 carries a "Design input — Alp River AR-1"
blockquote, and its §8 Phase 2 line reads "folding in Alp River AR-1's gate lifecycle
(`abandon`→terminal, stale-approval retraction) per §4.5". In the tree: the gate Spark DSL
(`Orchestration.Gate.Dsl` + `HumanGate`) declares exactly this entry's decision-kind
taxonomy (`:tool_call | :plan | :irreversible_write`, single-sourced in `Gate.Kinds`);
**abandon is a run-terminal** (`Orchestration.Cases.abandon` → `run_abandoned` →
`:abandoned`, every pending case dropped, only legal from `:awaiting_approval`); and
**stale-approval retraction** is `Cases.retract` (`approval_retracted`: case reopened with
decision data cleared, run parked back at `:awaiting_approval`, race-fenced against
`run_resumed` under the per-run lock) — both carry "AR-1" comments in the code.

**Tail update (2026-06-25): the open tail is now CLOSED.** AR-2 Phase 4 (composer human gates,
`ed483619`, 2026-06-22) gave both the `plan` gate (`gates/plan_gate.ex` → `Reactors.PlanGate`,
dispatched via `route_composer/gate_reactors.ex` → `wave_builder.ex`) and the `tool_call` gate
(the conversation-axis `Orchestration.ToolApprovals` producer) live producers, and made
stale-approval retraction **automatic**: the composer detects a post-approval scope-shift and
retracts the `plan-approved` *signal* (`route_composer.ex` `stale_approval?` →
`retract_stale_approval`, tested in `composer_durable_test.exs`), re-gating so the revised plan
must re-earn approval — a faithful realization of Alp River's "remove `#plan-approved` from the
live set" lock. Two residuals remain: (1) the *case-axis* `Cases.retract` named just above is now
**vestigial** — test-only, with no live caller and no operator surface, because the shipped
automatic path retracts the signal and re-gates (minting a fresh case) rather than reopening the
existing case; and (2) two stale claims should be reconciled — `gate/kinds.ex`'s moduledoc still
asserts only `:irreversible_write` has a producer (now false on two counts), and the paragraph
immediately above still describes the tail as open.

---

## §2 — The feature after Squidie: the dynamic composer layer

These need the engine — **which now exists** (Reactor Phases 0–5 shipped 2026-06-08..10).
Build them **on** Reactor + the event-log envelope; nothing blocks them anymore.

### AR-2. Deterministic signal-driven route composer — the crown jewel

**Recommendation**: BUILD-ON — **DONE (Phases 0–5, 2026-06-18..22)**; see the status update at
the end of this entry. The highest-value idea in the repo, and the one that fills the gap
Squidie's §6 leaves open.

**Where** (Alp River): `hooks/route.py` — `compute_route(catalog, live, available,
already_run)` is a **pure function** returning an ordered route + parallel `waves` + `held` +
`dropped` + `size`. The algorithm (`route.py:155-187`): (1) **trigger** — a stage joins if
*any* signal it `subscribes` to is live (OR-membership, family-prefix aware, `:94-98`); (2)
**route-filter** — drop a triggered stage whose `routes` exclude the live path (`:123-132`);
(3) **drop-unsatisfiable** — drop a stage whose required `input` artifacts can't be produced
(`:135-153`); (4) **lock** — hold a stage with an active `while/until` lock (`:101-107`); (5)
**topo-sort** the survivors by the `input`/`output` precedence DAG into Kahn-algorithm
**waves** (each wave a parallel cohort, `:55-91`). Two graphs over one stage
(`doctrine/CATALOG.md`): **data** (`input`/`output` = the order DAG, AND) and **signals**
(`subscribes`/`publishes` = membership, OR). The controlled signal vocabulary is
`doctrine/SIGNALS.md`; stage definitions carry it in frontmatter (`agents/triage.md:6-36` is
the seed stage that publishes the path + early signals). The orchestrator loop
(`WORKFLOW.md` `## Pipeline`) is thin: **route → render → run the next wave → update live/
available/ran → recompose**, to **convergence** (router returns empty route + empty `held`
and every review lens is clean).

**jido_radclaw gap** *(re-verified 2026-06-11 — the Reactor migration did not touch the
reasoning layer)*: reasoning is **entirely static, upfront-plan-picking** (verified across
the whole `reasoning/` tree). `Classifier.recommend/2` (`reasoning/classifier.ex:142-181`)
picks **one** of the 8 registry strategies (7 concrete single-shot algorithms + `adaptive`)
via heuristics + an optional LLM tie-break (`reasoning/auto_select.ex:172-217`) — never a
step list. `PipelineStore` holds
**static linear chains** (`reasoning/pipeline_store.ex`); `RunPipeline.execute/4` is a fixed
`Enum.reduce_while` over a pre-loaded `stages` list (`tools/run_pipeline.ex:234-273`). The two
reasoning signals emitted (`reasoning.classified` / `reasoning.outcome_recorded`,
`reasoning/telemetry.ex:234,306`) are **write-only audit beacons** — no subscriber consumes
them to add/remove a stage. There is **no composer**: nothing inspects an intermediate result
to grow the route. (The reasoning subagent's verdict: a composer "would need a new layer
between `Classifier.profile` and `RunPipeline.execute` that owns a mutable `stages`
accumulator with signal-driven hooks" — which is precisely `route.py`.)

**Relationship to Squidie**: this is the synthesis. Squidie §6 bifurcates the world into
declared-DAG (→ Reactor) and free-form-loop (→ untouched ReAct). The composer is a **third
mode**: dynamic *but deterministic*. The clean architecture:

- A `JidoClaw.Reasoning.Composer` GenServer owns `live` / `available` / `ran` and calls a pure
  `compose_route/1` (the Elixir port of `route.py`) each step.
- Each composed **wave** runs as a Reactor (built via `Reactor.Builder`, exactly the
  dynamic-construction path the shipped `Skills.Compiler` already uses to compile skills —
  `skills/compiler.ex`, per Squidie §5). The composer is the
  dynamic layer; **Reactor executes the bounded increments** — same boundary as §6, with the
  deterministic composer standing where §6 puts the ReAct loop.
- The composer emits into the **same `WorkflowEvent` log** (T1-1, shipped). And the elegant
  part: `live`/`available`/`ran` is itself **projectable from the event log** — the same
  status-as-projection pattern Squidie built (§4.1). Alp River already reconstructs this
  state after compaction (`hooks/reinject-canonical-state.sh`); jido_radclaw gets it durably
  for free from the envelope. `Jido.Signal.Bus` becomes the *ephemeral live transport*;
  `WorkflowEvent` is the *durable record*.

So the composer doesn't fight the Squidie design — it **reuses its event-log/projection model
and its Reactor-per-increment execution**, and it occupies the architectural slot Squidie
intentionally left empty.

**Why it needs Squidie first** *(prerequisite now satisfied)*: a multi-wave composed run has
the *same stranding bug* T1-1 fixed; it should record into the same log and run each wave as
a Reactor. Build the durable engine first, then the composer on top — not in parallel, not
instead. The engine shipped 2026-06-08..10; the composer is buildable now.

**Adoption sketch** *(unblocked — Phase 3 shipped)*: (1) extend the skill/worker catalog with
`routes` + `subscribes`/`publishes` metadata (the catalog *concept* from `CATALOG.md`, as Ash
data or compiled YAML — not the `.md`/`gen-catalog.py` artifacts); (2) port `route.py`'s five
steps as a pure Elixir function with tests mirroring `hooks/tests/test_route.py`; (3) the
composer loop recomputes each step, runs each wave via `Reactor.Builder`, folds published
signals back; (4) convergence = empty route + clean lenses. Keep the agent ReAct loop and the
swarm **out** (Squidie §6 boundary holds). Scope this as its own exploration doc when it's
next — it is a feature, not a patch.

**Cross-reference ([gust](../gust/FEATURES-WORTH-BORROWING.md), added 2026-06-11)**: three
gust borrows interact with the composer; the AR-2 exploration doc should own the first.

- **G1-1 (lease/fence, `REACTOR-ADOPTION.md` §4.11 — ✅ SHIPPED in full, WS1–WS5+WS4a, 2026-06-27..30)**
  assumes *run = one `Reactor.run`*; a composed run is a composer loop spanning N waves.
  Re-derive the lease around that unit (the Pooler starts *composers*; the composer renews
  across waves and halts on a stale fence). The payoff is mutual: the lease makes the
  composer cluster-correct, and because `live`/`available`/`ran` projects from the
  `WorkflowEvent` log (the sketch above), a reclaiming node rebuilds composer state and
  **resumes mid-route** — strictly better than gust's blind re-run. Wave boundaries
  multiply reclaim surface (step-level idempotency keys stop being optional), and the
  lease must define the gate park/resume cycle (no lease while `:awaiting_approval`;
  re-claim on resume) — a question gust never faced (it has no gates).
- **G2-1's open tail** (workflow-defs-as-MCP-resources + richer observe) converges here:
  the catalog is exactly what `jido://workflows/…` resources should expose, and
  `workflow_status` should learn composer state (wave, held, dropped, live signals) —
  ship as one piece.
- **G3-2/G3-3** hang on sketch step (1)'s open storage choice: YAML-on-disk → gust's
  debounced-watcher pattern applies; Ash-data-mirrored-from-files → un-moots gust's
  disk-of-truth reconciliation.

(Conceptual rhyme, no code: the composer's Kahn waves are the dynamic version of gust's
static stage cohorts — the one place gust's *shape* survives while its executor doesn't.)

**Status update (2026-06-25): DONE — Phases 0–5 shipped (2026-06-18..22), live on the real turn
path.** `JidoClaw.RouteComposer` is a supervised subsystem reached from
`JidoClaw.FrontDoor.decide/2` (both the core turn and the REPL): the five-step pure
`compose_route` + Kahn waves (`route_composer/router.ex`), each wave built via `Reactor.Builder`
(`route_composer/wave_builder.ex`) and run through `ReactorRunner`; a durable composer
event-log/projection with an AshCloak-encrypted `ComposerArtifact` ref-store (resolving the
Phase-2 blocker); crash recovery (`WorkflowRecovery` resumes a `:running` composer parent); human
gates in the composer (Phase 4, which also closed AR-1's tail); and MCP observe (Phase 5 —
`inspect_workflow` + `workflow_status` learn composer state; the `jido://workflows/catalog`
resource is registered). 222 composer test cases, zero skips; clean compile. Detailed plan docs:
`AR-2-COMPOSER-PLAN.md`, `AR-2-PHASE-2-DURABLE-ENVELOPE.md`. **Formerly deferred — now shipped
(2026-07-01 update):** the Phase-6 cluster lease (gust G1-1) landed in full as the clustering
workstream WS1–WS5 + WS4a (2026-06-27..30), re-derived around the composer unit (WS2/WS3).
**Still deferred:** only the optional `.jido/` YAML catalog overlay + debounced watcher (gust
G3-2; G3-3's DB mirror stays mooted — the catalog shipped as compile-time `%Stage{}` code, not
YAML-on-disk). (The AR-4 self-heal fixer workflow that reused the rerun primitive has since
shipped.) Per-stage
model/effort tiering: the `Stage` struct carries the fields, but the end-to-end spawn-time
override seam was not confirmed wired.

### AR-3. Reviewer fan-out + a shared Reviewer Contract

**Recommendation**: BUILD-ON — **DONE** (the 4-lens fan-out and the shared contract's authored
content both ship). A concrete, high-value first workflow to run on the new engine.

**Where** (Alp River): 15+ specialized review lenses (correctness, quality, architecture,
security, performance, accessibility, design-consistency, ux, consistency, structure, reuse,
naming-clarity, assumptions, acceptance, plan-adherence), each a thin agent file that **cites
a shared contract** rather than restating it — `agents/correctness-reviewer.md:18` ("Follows
the Reviewer Contract in your DOCTRINE block"). The contract (`doctrine/reviewer-contract.md`)
is the single source of the VERDICT/FINDINGS/ACTION_NEEDED shape, the confidence-tag reporting
threshold, the **concrete-consequence bar** ("name a concrete observable consequence … 'this
could be cleaner' does not clear it"), and the **anti-double-flag rule** (don't flag an issue
a guard/framework default outside the diff already handles). All lenses share `@diff` as
input, so they dispatch as **one parallel wave** (`WORKFLOW.md` worked routes).

**jido_radclaw gap**: a **single** `Reviewer` worker (`agent/workers/reviewer.ex`), producing
one flat `findings[]` list. It *does* emit a structured Zoi verdict (`overall ∈ approve/
request_changes/comment`) — so the substrate for a contract exists — but there is no multi-
lens fan-out and **the contract lives nowhere** (it's implicit in a one-line `:description`).
Parallel fan-out is native now — the skill compiler wires DAG steps `async?: true`
(`skills/compiler.ex`; `PlanWorkflow` and its hand-rolled parallel phases were deleted in
Phase 3) — but no skill ever instantiates the same reviewer twice (re-verified 2026-06-11).

**Relationship to Squidie**: now that Reactor has landed, "review `@diff`" is naturally a
Reactor parallel / `map` step — one step per lens, all reading the diff, collected into a
fixer step.
Squidie gives the **engine** + the Zoi structured-output substrate; Alp River gives the
**content** — which lenses, the shared contract, the reporting thresholds. The risk-gated
lenses (security on `#auth-surface`) compose only when those signals are live, tying directly
into AR-2.

**Adoption sketch**: define the lens set as reviewer templates sharing one **injected**
Reviewer Contract (via AR-5); compile "review the diff" to a Reactor `map`/parallel wave;
feed findings to AR-4's fixer. Start with 3–4 lenses (correctness, security, quality,
structure), not all 15.

**Status update (2026-06-25): DONE — the fan-out was built and the shared contract's *content* now
ships.** The composer catalog (`route_composer/catalog.ex`) instantiates the single `reviewer`
worker as **four risk-gated lenses** — `security` (subscribes `auth-surface`), `quality` and
`correctness` (subscribe `code-written`), `architecture` (subscribes `significant-build`) — each
emitting lens-scoped `findings:<lens>`/`clean:<lens>` and dispatched as one parallel Kahn wave
(exactly the sketch's "start with 3–4 lenses"); `lens` is a first-class `Stage` field. The
shared-contract **mechanism** rides AR-5; its **content** is now two doctrine slices, split by
*reach* (the principled split: `reviewer_min` is shared by **four** read-only judges — `reviewer`,
`sketch_reviewer`, `system_verifier`, **and `verifier`** — but `verifier` uses a different output
schema, so the field-shape half must not reach it):

- `priv/defaults/doctrine/reviewer_min.md` (expanded from the placeholder) — field-agnostic
  **universal judging discipline**: judge only what you can see, keep correctness vs. style
  separate, the **concrete-consequence bar** ("name a concrete observable consequence … 'this could
  be cleaner' does not clear it"), and the **anti-double-flag rule** (don't flag what a guard/
  framework default outside the diff already handles). Reaches all four judges.
- `priv/defaults/doctrine/reviewer_contract.md` (new) — the **structured-verdict shape**
  (`overall`/`summary`/`action_needed`, each finding `severity`/`confidence`/`location`/
  `description`) plus the `likely`/`unsure` confidence definitions and the reporting threshold.
  Reaches only the three `reviewer_verdict/0` workers.

The `Agent.Workers.OutputSchema.reviewer_verdict/0` schema was enriched to match: a per-finding
`confidence` (`likely`/`unsure`) + `location`, and a top-level `action_needed`. `severity`/
`confidence` are **string** enums so the stored `findings` artifact round-trips clean through
`ComposerArtifact.Envelope.normalize/1` (an atom enum would persist as `":error"`); `overall` stays
an atom enum (mapper control, never stored). No mapper change — new finding keys ride the existing
`coerce/1`. This also lands **AR-7's core** on the reviewer surface. `mix precommit` green.
**Closed by AR-4 (2026-06-25):** `action_needed` now persists as a durable artifact (the code-path
reviewers added it to their `output`, picked up from the typed output by the mapper's `dynamic/2`)
because the self-heal fixer consumes it via `review-action`, and `code`-path findings now feed an
automatic fixer (the AR-4 self-heal loop).

### AR-4. Self-heal fixer loop — review → fix → re-review until clean

**Recommendation**: BUILD-ON (with AR-3) — **DONE** (the literal version: a first-class
`fixer` worker, a domain-touched RE_RUN_SET with never-ran summoning, and a distinct
`:route_fix_failed` terminal). See the status update at the end of this entry.

**Where** (Alp River): `agents/fixer.md` — input `@findings`, output `@diff`, and the smart
bit: it emits a **RE_RUN_SET** = the union of *{gates that flagged a finding it fixed}* ∪
*{gates whose domain its edits touched}* (`fixer.md:35-42`; e.g. editing a UI file while
fixing a correctness bug re-runs the visual lens even though visual didn't flag it). Lenses
re-run after the fixer until all are clean (`WORKFLOW.md` `## Convergence`).

**jido_radclaw gap** (closed): the generator/evaluator retry loop survives as
`Skills.Steps.IterativeStep` (`skills/steps/iterative_step.ex`, ported from the retired
`IterativeWorkflow` in Phase 3) as a generic analog, but the lens self-heal loop is now its
own thing — reviewer findings on the `code` path feed an automatic fixer and a
review-fan-out → fix → targeted-re-review loop (shipped 2026-06-25; see the status update
below).

**Relationship to Squidie**: maps onto Reactor's `recurse`/iterative compositional steps —
which the shipped skill compiler already uses for skills' `:iterative` execution mode. The
self-heal loop is a recursing Reactor: review wave → fixer (if findings) → recompute the
re-run set → converge.

**Adoption sketch**: a `recurse` Reactor whose body is {review wave → fixer → re-run touched
lenses}, terminating when every lens is clean. Port the domain-touched RE_RUN_SET logic — it's
what keeps the loop both complete (re-checks side-effects of a fix) and cheap (re-runs only
affected lenses).

**Status update (2026-06-25): DONE — the literal version, on the `code` path.** The `fixer` is
now a first-class worker (`Agent.Workers.Fixer`, its own `fixer` template + `fixer_result/0`
schema with a `signals` field + `fixer_contract` doctrine slice) so it can self-report the
domains its edits touched. The composer's two-phase loop (`route_composer.ex` `decide_rerun/2`)
re-fires review → fix → re-review: **Hook R** (a forward reviewer flagged) snapshot-replaces the
fixer's out-of-band `review-feedback`/`review-action`; **Hook F** (the fixer completed) computes
the **RE_RUN_SET = (flagged ∪ domain-touched) ∩ ran** — domain-touched derived by inverting the
catalog `subscribes`/`lens` via the shared one-directional `SignalMatch` — and invalidates those
reviewers, while a never-ran lens whose domain signal the fixer just emitted is **summoned** by
the now-live signal (the headline Alp River example: editing an auth file re-runs the security
lens even though it never flagged). The markers are WELDED into the wave commit (atomic with
`wave_completed`, so a crash can't re-project "fixer ran" without its re-review trigger).
Exhaustion past the per-stage rerun cap with findings still open surfaces as a distinct
`:route_fix_failed` terminal (the forward twin of AR-8c's `:route_verify_failed`,
`result.disposition: "fix_failed"`). Findings ride the SIGNAL out-of-band (producerless
`review-feedback`/`review-action`), so the data graph stays acyclic. Scope is the `code` path
only — `sketch-review` stays report-only (no fixer → the surviving `:not_converged`-on-findings
case) and `system` keeps its own reverse-verify loop. `action_needed` now persists (the AR-3
deferral, closed because the fixer consumes it).

---

## §3 — Independent of the engine (prompt-layer borrows, land anytime)

These are pure prompt/output assembly. They need **neither** Reactor nor the composer and can
be picked up opportunistically without touching the Squidie roadmap. AR-5 is the enabler AR-3's
shared contract, AR-6's persona layer, and AR-7's pervasive confidence-tagging slice all ride
(shipped 2026-06-25 / 2026-06-26 / 2026-06-27).

### AR-5. Central doctrine injection into sub-agents

**Recommendation**: INDEPENDENT — **DONE (2026-06-22)**. The highest-leverage prompt-layer
borrow; it is now the live substrate AR-3's contract, AR-6's personas, and AR-7's pervasive
confidence-tagging slice all ride.

**Where** (Alp River): `hooks/user-context-injector.sh` — a `PreToolUse(Agent)` hook that
prepends four blocks to **every sub-agent's** prompt: `## DOCTRINE` (per-agent slices from
`doctrine/`, gated by a `DOCTRINE_MAP`, `:163-191`), `## USER_CONTEXT` (MEMORY.md + linked
files, `:309-337`), `## PROJECT_CONTEXT` (`docs/` slices per a `READ_MAP`, `:339-399`), and
`## PSYCHOLOGY` (AR-6). Agents stay thin by **citing** "your DOCTRINE block" instead of
carrying the rules inline — the contract is single-sourced (`doctrine/code-doctrine.md`,
`reviewer-contract.md`, `confidence-tagging.md` are each authored once and injected into the
agents that cite them).

**jido_radclaw gap** *(re-verified 2026-06-11)*: **no central doctrine injection.** The
`Prompt` builder (`agent/prompt.ex:298-329`) assembles a rich prompt — but **only for the
main agent** (`Startup.inject_system_prompt` is called from the REPL/handoff paths, never
from `SpawnAgent` or the skill compiler's `AgentStep`/`AgentRunner` path that replaced
`StepAction`). Spawned workers receive **only** their compile-time `:description` + the task
string + `ToolContext` scope keys. Consequence: doctrine text is **duplicated literally**
across 5 workers' `:description` strings (the artifacts schema is copy-pasted into
Coder/Researcher/Refactorer/DocsWriter/TestRunner), and the Reviewer's contract exists
only as a one-liner.

**Relationship to Squidie**: fully orthogonal — no engine involvement.

**Adoption sketch**: extend `ToolContext.child/3` + the spawn path so a sub-agent's prompt is
assembled from (a) a `JidoClaw.Doctrine` registry (Elixir-side text/EEx: reviewer-contract,
code-doctrine, confidence-tagging), gated per-template by a doctrine map; (b) the existing
Memory blocks (`Prompt.blocks_section/1` — already built for the main agent, reuse it); (c)
project docs. This is the Elixir analog of the hook, de-dupes the worker descriptions, and
makes AR-3's Reviewer Contract a real single-sourced artifact.

**Status update (2026-06-25): DONE (2026-06-22).** `JidoClaw.Doctrine` is a priv-file-backed
slice registry (`base`, `artifacts`, `reviewer_min`, `system_verify`) with a per-template slice
map (`@template_slices`); `Agent.SubagentPrompt.build/2` assembles role + `## DOCTRINE` + the
reused Memory blocks (`PromptSections.blocks_section/1`) + JIDO.md, injected via
`Startup.inject_subagent_prompt/3` on **all three sub-agent paths** — initial spawn
(`tools/spawn_agent.ex`), skill-step worker (`skills/steps/agent_runner.ex`), and follow-up turn
(`tools/send_to_agent.ex`) — closing the exact main-agent-only gap this entry named. The
duplicated worker schemas are single-sourced in `Agent.Workers.OutputSchema`. Config-gated,
best-effort, tested. **Open borders (not AR-5 failures):** AR-3 has since filled `reviewer_min`
(no longer a placeholder) and added the `reviewer_contract` slice carrying the confidence tag — so
AR-7's reviewer-surface core now rides the seam, **AR-6 has since added the `## PSYCHOLOGY`
persona section through it** (2026-06-26), and **AR-7 has since added the standalone
`confidence_tagging` slice** (2026-06-27, reaching the 10 non-reviewer templates); what's left
unauthored is only a `code-doctrine` slice, and "project docs" is JIDO.md only (no `docs/`
READ_MAP). The seam is the live substrate AR-6's personas and AR-7's pervasive tagging now ride.

### AR-6. Psychology / persona layer

**Recommendation**: INDEPENDENT — **DONE (2026-06-26)**. Cheap and genuinely novel, as forecast —
shipped in about a day on top of AR-5. See the status update at the end of this entry.

**Where** (Alp River): `psychology/*.md` — 9 personas (cynic, skeptic, detective, defender,
optimist, pragmatist, teacher, user-advocate, craftsperson), each a 5-line
Belief/Drive/Default-move/Voice/**Conflict-rule** block (`psychology/skeptic.md`,
`cynic.md`). `psychology/agent-map.json` assigns one per agent (skeptic→plan-challenger,
defender→security-reviewer, cynic→fixer, detective→investigators). The safety valve is the
**conflict rule**, identical in every persona: "role contract is mandatory; persona is
advisory voice; on conflict the role and the codebase win." Per-project overrides via
`alpRiver.psychologyOverrides`.

**jido_radclaw gap**: **none exists** — an exhaustive grep for persona/disposition/skeptic/
optimist returned zero hits. Agents are purely role-defined by `:description` + tool subset.

**Relationship to Squidie**: orthogonal.

**Adoption sketch**: a `JidoClaw.Agent.Persona` set (a handful of short texts) + a
template→persona map, injected through the AR-5 seam as a `## PSYCHOLOGY` block. Advisory-only,
with the role-wins conflict rule carried verbatim. Differentiates how sub-agents reason
(a skeptic plan-challenger probes assumptions; a cynic fixer asks what to delete) for very
little code.

**Status update (2026-06-26): DONE.** `JidoClaw.Persona` (`lib/jido_claw/persona.ex`) is a
priv-file-backed registry — 9 personas in `priv/defaults/persona/*.md` — rendered as a
`## PSYCHOLOGY: <Name>` block and injected through the AR-5 seam: `Agent.SubagentPrompt.build/2` →
`build/3` splices it **after** `## DOCTRINE` (mandatory contract first, advisory voice second). One
deliberate improvement over the sketch above: resolution is **stage-first** (the catalog stage
name) with a **template-name fallback**, because the four reviewer lenses are four catalog *stages*
over the single `reviewer` template — so template-only keying (the sketch's plain "template→persona
map", how Doctrine keys) would collapse them to one voice; per-stage keying gives defender /
craftsperson / skeptic / pragmatist. The stage travels on a **dedicated `catalog_stage_name`
option** set only by `WaveBuilder` — not the overloaded `step_name` (which doubles as the arbitrary
YAML/skill-step label), so a skill step that happens to be *named* like a stage does **not** inherit
the stage persona (it falls through to the template). The conflict rule is **single-sourced** in the
renderer (`@conflict_rule`, appended to every block) rather than repeated per-file as in the source,
so the role-wins safety valve can never drift. Section-gated by a new `config :jido_claw,
:psychology` — `:doctrine` stays the **master** injection gate (psychology off never re-enables
injection; it only toggles the one section). Reaches the AR-5 seam's three sub-agent paths (initial
spawn `tools/spawn_agent.ex`, skill/composer step `skills/steps/agent_runner.ex`, follow-up turn
`tools/send_to_agent.ex`); the main agent and handoff-routed workers get neither doctrine nor
persona — AR-5's boundary, unchanged. 8 of 9 personas are selected (`user-advocate` ships and
renders but is intentionally unused — no `design/ux-prototyper` analog in this catalog); no
per-project overrides (v1 non-goal). `mix precommit` green.

### AR-7. Confidence-tagging as a pervasive convention

**Recommendation**: INDEPENDENT (ships as a doctrine slice via AR-5) — **DONE** (the
reviewer-surface core shipped folded into AR-3, 2026-06-25; the pervasive convention shipped
2026-06-27). See the status update at the end of this entry.

**Where** (Alp River): `doctrine/confidence-tagging.md` — every finding carries `[likely]`
(evidence-based: code read, official docs, observed) or `[unsure]` (judgment, single-source,
inferred); both still hedge. `reviewer-contract.md:9-11` adds reporting thresholds: `[likely]`
unconditionally, `[unsure]` only at high impact (correctness/security/data risk), plus the
concrete-consequence bar. Web-sourced agents must include the source URL.

**jido_radclaw gap**: confidence exists in only 3 narrow typed slots — `Researcher` and
`Verifier` workers (`confidence ∈ low|medium|high`) and the `verify_certificate` tool (a
0.0–1.0 float). There is **no codebase-wide claim-tagging convention** and no system-prompt
instruction to mark assumptions or distinguish observed-vs-inferred.

**Relationship to Squidie**: orthogonal; pairs with AR-3 (it *is* part of the reviewer
contract) and AR-5 (it ships as a doctrine slice).

**Adoption sketch** *(updated to what shipped 2026-06-27)*: add a standalone reach-all
`confidence_tagging` doctrine slice (inline `[likely]`/`[unsure]` prose tagging + the source-URL
rule) injected via AR-5 into the 10 non-reviewer templates; the reviewer family already carries the
equivalent through `reviewer_contract` (AR-3), so it is excluded. Give the one non-reviewer surface
with a findings list — **`researcher`** — a required per-finding `confidence` tag (reusing its
`references` field for source URLs). The **`verifier`** and the producer workers receive the
doctrine prose only, with **no** schema change: the verifier keeps its distinct
`verdict`/`confidence`/`reasoning` shape (the deliberate "verifier has a different schema"
boundary), and the producers have no per-claim list to attach a field to. (This corrects the
original sketch, which had proposed extending the Reviewer/Researcher/**Verifier** output schemas —
the verifier schema was deliberately left unchanged; machine-checking every claim everywhere would
mean inventing a findings list on schemas that have none, which is out of scope.)

**Status update (2026-06-25): PARTIAL — the reviewer-surface core shipped folded into AR-3**
*(snapshot; superseded by the 2026-06-27 update below)*. The
`Agent.Workers.OutputSchema.reviewer_verdict/0` schema now carries a per-finding `confidence` tag
(`likely`/`unsure`), and the new `reviewer_contract` doctrine slice defines both tags (evidence-based
vs. judgment/single-source/inferred) and the reporting threshold (every `likely`; an `unsure` only at
high impact — correctness/security/data risk) plus the concrete-consequence bar — injected into the
three `reviewer_verdict/0` workers. What remained at this snapshot was the **pervasive** convention:
no codebase-wide `[likely]`/`[unsure]` tagging beyond reviewer findings, `researcher` still carried
only its own `low|medium|high` confidence (no per-claim tag, no source-URL requirement for
web-sourced claims), and there was no standalone reach-all `confidence-tagging` slice. The three
narrow typed slots called out in 2026-06-11 (Researcher/Verifier `low|medium|high`,
`verify_certificate` float) were otherwise unchanged. It was cheap to extend once the tag, the
threshold prose, and the AR-5 seam all existed — done 2026-06-27 (see the update below).

**Status update (2026-06-27): DONE — the pervasive convention shipped as a standalone reach-all
slice.** `priv/defaults/doctrine/confidence_tagging.md` is the 8th `JidoClaw.Doctrine` slice,
authored deliberately distinct from `reviewer_contract.md`: where the contract frames a *structured
finding field*, this slice frames *inline `[likely]`/`[unsure]` claim-tagging in prose* and adds the
**source-URL rule** the contract lacks — it has to cover both forms because most of its reach is
prose-only while `researcher` also has a structured per-finding field. It scopes the tag to
**per-claim/per-finding** use and explicitly tells a worker with an *overall* confidence field on a
different scale (`researcher`'s and `verifier`'s `low|medium|high`) to keep that scale and never emit
`likely`/`unsure` into it — so the slice can never nudge the LLM into a value those fields reject. It
reaches the **10 non-reviewer** sub-agent templates (`coder`, `fixer`, `refactorer`, `docs_writer`,
`researcher`, `test_runner`, `verifier`, `sketch_build`, `sketch_build_exec`, `system_executor`)
through the existing AR-5 `## DOCTRINE` section; the reviewer family (`reviewer`, `sketch_reviewer`,
`system_verifier`) is **excluded** because `reviewer_contract` already carries the equivalent
per-finding tag (no engine or composer change — it rides the AR-5 doctrine seam). The enforcement is
**honest about its two tiers**: the `likely`/`unsure` tag is **structurally enforced** (a required
Zoi string enum) on exactly one non-reviewer surface — `researcher` findings, which gained a
per-finding `confidence` + the source-URL-in-`references` rule (mirroring the AR-3 reviewer
precedent; the top-level `low|medium|high` confidence is kept as the orthogonal overall axis) — plus
the reviewer family's findings already (AR-3); for the other nine non-reviewer workers it is a
**prompt-enforced convention** on their prose output (`summary`/`notes`/`reasoning`), whose schemas
are producer/verdict shapes with no per-claim list to attach a field to. Machine-checking everywhere
would mean inventing a findings/claims list on those nine schemas — deliberately out of scope (the
"verifier prose-only" decision generalized). The `verifier` receives the doctrine prose only (its
flat `verdict`/`confidence`/`reasoning` schema is unchanged — the deliberate "verifier has a
different schema" boundary), and the main agent is **untouched** (AR-7 stays on the sub-agent
doctrine seam, consistent with AR-3/AR-5/AR-6 — `priv/defaults/system_prompt.md` is not edited).
`mix precommit` green.

### AR-8. Conversation-type triage (talk / sketch / code / system)

**Recommendation**: INDEPENDENT front door; folds into AR-2 if/when that lands — **DONE (all
four paths; folded into AR-2 as the triage seed, 2026-06-23..25)**. See the status update at the
end of this entry.

**Where** (Alp River): `WORKFLOW.md` `### Seed and path` (under `## Pipeline`) +
`agents/triage.md` — an always-on
seed stage publishes exactly **one path**, defined by *what it leaves behind*: **talk** (no
artifact — answer inline), **sketch** (throwaway in `.prototypes/`), **code** (a reviewed
change), **system** (a verified machine change). The path is sticky but re-evaluated each turn
(`talk` flips to `code` on "do it").

**jido_radclaw gap**: the `Classifier` picks a reasoning *algorithm* (cot/tot/got/…), not a
conversation *type* — there is no "discuss vs build vs operate-the-machine" front door that
decides whether to enter a workflow at all.

**Relationship to Squidie**: mostly orthogonal — a front-door router deciding *which* workflow
runs (the workflow then runs on whatever engine). Conceptually it is the **seed stage of
AR-2's composer**, so if the composer is built this folds in there; standalone it's a cheap
`Classifier` upgrade that keeps "talk" requests out of the heavyweight path.

**Adoption sketch**: extend `Classifier` (or add a triage stage) to emit a path + early
signals; the `talk` path stays inline, `code`/`system` enter the engine. If AR-2 lands, this
becomes the composer's `triage` seed.

**Status update (2026-06-25): DONE — all four paths shipped (2026-06-23..25), folded into AR-2 as
the triage seed.** An always-on, fail-safe triage classifier (`triage.ex`, coerces any failure to
`talk`) emits one of `talk/sketch/code/system` (`triage/verdict.ex`) each turn; `FrontDoor.decide/2`
routes on it (live at `lib/jido_claw.ex` and the REPL), and the catalog `triage` stage is the
`{:seed, "triage"}` with `routes: [talk, sketch, code, system]`. Sticky-but-re-evaluated
(re-classifies each turn against a recent-turn window; "talk flips to code on 'do it'"). **talk**
stays inline (no composer, no artifact); **code** is the normal reviewed-change engine route
(planner → plan-gate → test-author/implementer → 4 reviewers → fixer); **sketch** (AR-8b) is a
hard-isolated `.prototypes/<id>/` throwaway, with cross-run **graduation** (AR-8b-2 C1–C3,
summary-only) and a `:docker` sandbox **exec tier** (AR-8b-2 F2 — `RunCommand`↔Forge bridge,
no-egress + global-config isolation); **system** (AR-8c) is a verified machine change gated by the
always-on `SafetyGate` (`:irreversible_write`) with an executor⇄verifier reverse-verify loop and a
distinct `:route_verify_failed` terminal. Plan docs: `AR-8b-SKETCH-PATH.md`,
`AR-8b-2-GRADUATION.md`, `AR-8b-2-F2-EXEC-TIER.md`, `AR-8c-SYSTEM-PATH.md`. **Sole caveat:** the
Docker exec tier's real-OS isolation (no-egress, mount round-trip) is proven only in manual
`@docker_sandbox`-tagged tests, excluded from CI by design. Explicit non-goals remain open by
design (per-tool approval overlay for the exec tier; auto-merging a graduated prototype).

---

## §4 — Skip / already covered

- **The hook substrate + `.md`/`.py`/`.json` artifacts** (`route.py`, `gen-catalog.py`, the
  bash injectors, the markdown agent format) → **re-implement, don't port.** The *catalog
  concept* (frontmatter → machine-readable stage index; `hooks/gen-catalog.py` →
  `generated/catalog.json`) transfers to AR-2; the Python/Bash/markdown *artifacts* are
  Claude-Code-harness-specific.
- **Compaction / `reinject-canonical-state.sh`** → **SKIP.** jido_radclaw's
  `Reasoning.Compactor` is more sophisticated (per-`Identity` keying, `RequestTransformer`,
  persisted snapshots — `reasoning/compactor.ex`). Alp River's reinject hook is a weaker
  cousin; the composer-state-from-event-log idea in AR-2 supersedes it.
- **Reconcile-from-tree recovery** (`WORKFLOW.md` `## Recovery`) → **mostly covered.** Squidie's
  event-log recovery (`REACTOR-ADOPTION.md` §4.8, shipped as `WorkflowRecovery`) is the
  durable, general version; for code
  edits, git + the working tree already provide the reconcile substrate. Take only the *idea*
  that a side-effecting stage reconciles from its durable trace rather than re-running blind —
  which Squidie §4.8 already encodes.
- **Render-card / card-only narration / status surface** (`WORKFLOW.md` `## Pipeline` step 2) →
  **SKIP.** That is Claude-Code-REPL UX; jido_radclaw has its own `Display` + the Phoenix
  LiveView dashboard.
- **Model + effort tiering per stage** (`WORKFLOW.md` `## Model Tiering`: opus/sonnet/haiku +
  medium/high/max) → **note, minor.** jido_radclaw already has model selection, but the 7
  workers run uniformly at `:fast` (no per-role escalation). Per-stage model+effort is a small
  refinement worth folding into AR-2's catalog metadata, not a standalone borrow.
- **Milestone loop** (`WORKFLOW.md` `## Milestone loop`) → **future follow-on of AR-2/AR-3.**
  Large builds as verified increments maps onto Reactor compositional steps + the gate
  machinery (both shipped); not separate substrate.
- **Input/Output template contracts** (`WORKFLOW.md` `## Input Template Contract`) →
  **partially covered.** Zoi structured outputs + the skill runner's `produces`-injection
  (`AgentRunner.inject_produces_instruction/2`, `skills/agent_runner.ex:205-209` — carried
  over from the retired `StepAction` in Phase 3) already cover most of it. The verbatim-relay
  discipline (never paraphrase a predecessor's output) is worth adopting as an orchestrator
  convention if AR-2 is built.

---

## The three layers, side by side

| Layer | Squidie / Reactor (shipped 2026-06-08..10) | Alp River | jido_radclaw today |
| --- | --- | --- | --- |
| Execute a bounded **declared** DAG | **Reactor** (DAG, concurrency, saga, halt/resume) | defers to the harness | **shipped** — `Skills.Compiler` → Reactor (static drivers deleted) |
| **Durability** (log, status, recovery, gates) | **the envelope** (`WorkflowEvent`, projection, reconciler, human gates) | ephemeral signal state + reinject hook | **shipped** — event log + projection + recovery (stranding bug fixed) |
| **Dynamic composition** of the stage set | *out of scope* (§6 → free-form ReAct) | **the signal router** (`route.py`) — the gap-filler | **shipped** — `RouteComposer` composes waves from live signals (AR-2) |
| **Multi-agent quality** (review fan-out, self-heal) | — | **15 lenses + contract + fixer** | **shipped** — 4-lens fan-out + authored shared contract (AR-3) + the self-heal fixer loop with domain-touched RE_RUN_SET (AR-4) |
| **Prompt assembly** (doctrine, persona, context) | — | **injector hook** (doctrine/persona/context) | **doctrine + reviewer contract/confidence + persona + pervasive confidence-tagging shipped** to sub-agents (AR-5, AR-3, AR-6, AR-7) |

The top two rows are Squidie — **shipped 2026-06-08..10**. The bottom three are Alp River — and
as of **2026-06-27** they are no longer hypothetical: the composer (AR-2), review fan-out + the
shared contract (AR-3), doctrine injection (AR-5), the self-heal fixer loop (AR-4), the persona
layer (AR-6), and AR-7's confidence-tagging (reviewer core in AR-3, the pervasive
`confidence_tagging` slice 2026-06-27) are all shipped; only AR-2's deferred tails remain.

## Sequencing recommendation

*(Progress through 2026-06-25 annotated inline.)*

1. **Ship Squidie unchanged — done (Phases 0–5, 2026-06-08..10).** Reactor + the durable
   envelope (T1-1 event log, status-as-projection, recovery) shipped unchanged by this
   document, exactly as intended.
2. **Fold AR-1 into Squidie Phase 2 — done; tail since closed.** The gate taxonomy +
   abandon/retraction lifecycle shipped inside Phase 2 as a design input, credited as "AR-1" in
   code and docs. The former tail — the `plan`/`tool_call` gate producers and the automatic
   re-plan retraction trigger — **closed in AR-2 Phase 4 (2026-06-22)**.
3. **Build the composer (AR-2) — DONE (Phases 0–5, 2026-06-18..22).** The deterministic signal
   layer shipped on the engine, reusing the event-log/projection model, with its own plan docs
   (`AR-2-COMPOSER-PLAN.md`, `AR-2-PHASE-2-DURABLE-ENVELOPE.md`). Deferred tails: the gust §4.11
   cluster lease and the optional YAML catalog overlay.
4. **AR-3 (reviewer fan-out) + AR-4 (self-heal)** — **both done.** AR-3: the 4-lens fan-out shipped
   on the composer; the shared Reviewer Contract content + confidence tagging landed 2026-06-25,
   folding in AR-7's reviewer-surface core. **AR-4 done (2026-06-25)** — the literal self-heal loop
   (first-class fixer + domain-touched RE_RUN_SET + never-ran summoning + the `:route_fix_failed`
   terminal) built on the rerun primitive already in place.
5. **AR-5 → AR-6/AR-7, and AR-8** — **AR-5 done (2026-06-22)** and **AR-8 done (2026-06-23..25,
   folded into AR-2's triage seed)**; **AR-6 done (2026-06-26)** — the persona layer riding the
   AR-5 doctrine seam; **AR-7 done** — its reviewer-surface core folded into AR-3 (2026-06-25) and
   its pervasive `confidence_tagging` slice shipped on the same seam (2026-06-27), the last
   not-started independent borrow. **All the cheap greenfield prompt-layer wins are now shipped.**

## Bottom line

Alp River is the most architecturally relevant project in this folder *and* the one most
easily misread as a reason to pivot. It is not. It is the **methodology layer that sits above
the engine Squidie built**: the deterministic composer for the dynamic middle ground Squidie
deliberately leaves to free-form ReAct, plus the multi-agent review, self-heal,
doctrine-injection, and persona content to run on top. As of **2026-06-27** the whole backlog
has shipped: Squidie (Phases 0–5) and the gate semantics (AR-1, tail since closed), then
**the composer itself (AR-2, Phases 0–5), reviewer fan-out + the shared Reviewer Contract (AR-3),
doctrine injection (AR-5), the four-path triage front door (AR-8), the self-heal fixer loop
(AR-4), the persona layer (AR-6), and the pervasive confidence-tagging convention (AR-7, core in
AR-3 + the standalone slice 2026-06-27)**. What remains is only AR-2's explicitly-deferred tails
(the cluster lease and the optional YAML catalog overlay).
