# Features Worth Borrowing from Alp River

Exploration notes — not a plan, not a commitment. Inventory **2026-06-06**.

Source: `~/workspace/claws/alp-river` — **Alp River** (author: Alper Ortac; MIT; v1.2.5;
72 commits, 2026-04-26 → 2026-06-05, single author). It is a **Claude Code plugin**, not an
Elixir library: ~3,740 lines of markdown agent definitions (48 of them), ~1,870 lines of
Python+Bash hooks, a 420-line `WORKFLOW.md` doctrine, 7 doctrine files, and 9 persona files.
Tagline: "a river of agents, composed to the task." It is a **multi-agent workflow
methodology** — a deterministic router (`hooks/route.py`) composes the exact pipeline of
specialized sub-agents a task needs, grows it as the task reveals itself, reviews in
parallel, and self-heals.

> **Read this with [`../squidie/REACTOR-ADOPTION.md`](../squidie/REACTOR-ADOPTION.md) and
> [`../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md)
> open.** Per the project owner, the Squidie work (adopt Reactor as the workflow engine +
> the durable event-log envelope) is the **immediate next feature**. This document is
> written through that lens: what about Alp River should *inform* the Squidie build, what
> *builds on top of it afterward*, and what is *independent* — deliberately so that nothing
> here is mistaken for a reason to delay or reshape Squidie.

## Determination (TL;DR)

**Alp River is not a competitor to the Reactor direction — it is the methodology layer that
sits *above* the engine Squidie is about to build. Ship Squidie unchanged. Fold in exactly
one thing now (gate semantics). Everything else either builds on the new engine afterward or
is independent of it.**

Alp River and Squidie/Reactor solve **different layers**:

- **Squidie/Reactor** is the *durable execution substrate*: a bounded, **declared** DAG
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

| Alp River capability | Relationship to the Squidie work | Recommendation |
| --- | --- | --- |
| **Gate / lock semantics** (while/until, abandon-terminal, stale-approval retraction) | **Informs** Squidie Phase 2 (human-gate DSL, `REACTOR-ADOPTION.md` §4.5) | **FOLD-IN now** (AR-1) |
| **Signal-driven route composer** (the crown jewel) | **Builds on** Reactor — the dynamic layer above the engine | **BUILD-ON next** (AR-2) |
| **Reviewer fan-out + shared contract** | **Builds on** Reactor — a concrete first workflow | **BUILD-ON** (AR-3) |
| **Self-heal fixer loop** | **Builds on** Reactor's `recurse`/iterative steps | **BUILD-ON** (AR-4) |
| **Central doctrine injection into sub-agents** | **Independent** of the engine — pure prompt assembly | **INDEPENDENT** (AR-5) |
| **Psychology / persona layer** | **Independent** — pure prompt assembly | **INDEPENDENT** (AR-6) |
| **Confidence-tagging convention** | **Independent** — output/prompt convention | **INDEPENDENT** (AR-7) |
| **Conversation-type triage** (talk/sketch/code/system) | **Independent** front door; folds into AR-2 if built | **INDEPENDENT** (AR-8) |
| Hook substrate, `.md`/`.py` artifacts, render-card UX, compaction/reinject | Re-implement or already covered | **SKIP** (§4) |

## Why not "adopt as a dependency"

Unlike every other exploration in this folder (gust, hermes, squidie, jidoka are Elixir),
Alp River is a **Claude Code plugin** — markdown agents + Python/Bash hooks orchestrated by
the Claude Code harness. There is **nothing to add to `mix.exs`**. Every borrow is
**pattern-level**: re-implement the *concept* in Elixir/Jido/Ash/Reactor. The good news is
that the concepts map astonishingly well onto substrate jido_radclaw **already has but
under-uses** — `Jido.Signal.Bus` (today observability-only), YAML-defined skills/pipelines
with `depends_on` DAGs, the Ash `ApprovalGate` resource (today zero callers), `ToolContext`
child-forwarding, and the `Reviewer` worker with Zoi structured outputs.

A second, quieter advantage: Alp River's own orchestrator is **an LLM following 420 lines of
prose** (`WORKFLOW.md`). Only the *route composition* is deterministic (`route.py` is a pure
function the LLM calls). A jido_radclaw port can make the **whole composer** a real GenServer
+ pure function — strictly more reliable than the source.

## How to read this document

Recommendation axis: **FOLD-IN** (inform the Squidie build now) / **BUILD-ON** (the feature
after Squidie; needs the engine) / **INDEPENDENT** (orthogonal to the engine) / **SKIP**.
Per entry: **Recommendation**, **Where** (Alp River cites), **jido_radclaw gap**,
**Relationship to Squidie**, **Adoption sketch**. Alp-River cites are accurate to the file;
jido_radclaw cites were verified by subagent sweep of `lib/`.

---

## §1 — Fold into the Squidie work now

### AR-1. Gate & lock semantics — inform the human-gate DSL (Squidie Phase 2 / §4.5)

**Recommendation**: FOLD-IN. The single thing here that should touch the Squidie build *as
it happens*, because designing the gate DSL twice is the waste to avoid.

**Where** (Alp River): `WORKFLOW.md` `## Locks` and `## Gates`. A **lock** is a scheduling
gate in frontmatter — `{while: '#sig', until: '#sig'}`, three states (inactive / held /
released), multiple locks **AND** together (`hooks/route.py:101-107` `_active_locks`,
`:163-169` the held-set computation). Three concrete gates ship:

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

**jido_radclaw gap**: `JidoClaw.Orchestration.ApprovalGate` (`create/approve/reject`) and
`WorkflowRun.await_approval`/`resume` **exist but have zero callers** anywhere in `lib/` —
scaffolded, never wired. Squidie's `REACTOR-ADOPTION.md` §4.5 is *about to design* the
human-gate Spark DSL "declaring the *kind* of decision (`tool_call`, `plan`,
`irreversible_write`, …)" with `after_approved/2` / `after_rejected/2` hooks.

**Relationship to Squidie**: Alp River is a working, thought-through design of exactly that
DSL's decision-kinds and lifecycle. The `while/until` lock **is** a Reactor `{:halt}` guard
made declarative; its AND-together composition is "multiple guards on one step." Its
`abandon → terminal` maps onto Squidie's `after_rejected → terminal` (§4.5 step 4). Its
**stale-approval retraction** is a concrete semantic Squidie's gate design has *not* yet
addressed — and §4.8's recovery already distinguishes "decision recorded" from "unresolved
gate," so the retraction rule slots in cleanly.

**Adoption sketch**: when building Squidie Phase 2, model the human-gate DSL's decision-kind
enum on Alp River's gate types (plan-approval, safety/irreversible, tool-call), and adopt the
two lifecycle rules verbatim: `abandon` cancels held downstream steps; a pre-implementation
re-plan retracts `#plan-approved`. Cost is near-zero (it's a design input, not new code) and
it prevents shipping a gate model that later needs the abandon/retraction semantics bolted on.

---

## §2 — The feature after Squidie: the dynamic composer layer

These need the engine. Build them **on** Reactor + the event-log envelope, after Squidie
Phases 0–3 land.

### AR-2. Deterministic signal-driven route composer — the crown jewel

**Recommendation**: BUILD-ON. The highest-value idea in the repo, and the one that fills the
gap Squidie's §6 leaves open.

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

**jido_radclaw gap**: reasoning is **entirely static, upfront-plan-picking** (verified across
the whole `reasoning/` tree). `Classifier.recommend/2` (`reasoning/classifier.ex:142-183`)
picks **one** of 8 hard-coded single-shot algorithms via heuristics + an optional LLM
tie-break (`reasoning/auto_select.ex:172-214`) — never a step list. `PipelineStore` holds
**static linear chains** (`reasoning/pipeline_store.ex`); `RunPipeline.execute/4` is a fixed
`Enum.reduce_while` over a pre-loaded `stages` list (`tools/run_pipeline.ex:234-273`). The two
reasoning signals emitted (`reasoning.classified` / `reasoning.outcome_recorded`,
`reasoning/telemetry.ex:230,302`) are **write-only audit beacons** — no subscriber consumes
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
  dynamic-construction path Squidie §5 already uses to compile skills). The composer is the
  dynamic layer; **Reactor executes the bounded increments** — same boundary as §6, with the
  deterministic composer standing where §6 puts the ReAct loop.
- The composer emits into the **same `WorkflowEvent` log** (T1-1). And the elegant part:
  `live`/`available`/`ran` is itself **projectable from the event log** — the same
  status-as-projection pattern Squidie is building (§4.1). Alp River already reconstructs this
  state after compaction (`hooks/reinject-canonical-state.sh`); jido_radclaw gets it durably
  for free from the envelope. `Jido.Signal.Bus` becomes the *ephemeral live transport*;
  `WorkflowEvent` is the *durable record*.

So the composer doesn't fight the Squidie design — it **reuses its event-log/projection model
and its Reactor-per-increment execution**, and it occupies the architectural slot Squidie
intentionally left empty.

**Why it needs Squidie first**: a multi-wave composed run has the *same stranding bug* T1-1
fixes; it should record into the same log and run each wave as a Reactor. Build the durable
engine first, then the composer on top — not in parallel, not instead.

**Adoption sketch**: after Squidie Phase 3, (1) extend the skill/worker catalog with
`routes` + `subscribes`/`publishes` metadata (the catalog *concept* from `CATALOG.md`, as Ash
data or compiled YAML — not the `.md`/`gen-catalog.py` artifacts); (2) port `route.py`'s five
steps as a pure Elixir function with tests mirroring `hooks/tests/test_route.py`; (3) the
composer loop recomputes each step, runs each wave via `Reactor.Builder`, folds published
signals back; (4) convergence = empty route + clean lenses. Keep the agent ReAct loop and the
swarm **out** (Squidie §6 boundary holds). Scope this as its own exploration doc when it's
next — it is a feature, not a patch.

### AR-3. Reviewer fan-out + a shared Reviewer Contract

**Recommendation**: BUILD-ON. A concrete, high-value first workflow to run on the new engine.

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
`PlanWorkflow` can run parallel phases (`workflows/plan_workflow.ex:272-314`) but no skill
ever instantiates the same reviewer twice.

**Relationship to Squidie**: once Reactor lands, "review `@diff`" is naturally a Reactor
parallel / `map` step — one step per lens, all reading the diff, collected into a fixer step.
Squidie gives the **engine** + the Zoi structured-output substrate; Alp River gives the
**content** — which lenses, the shared contract, the reporting thresholds. The risk-gated
lenses (security on `#auth-surface`) compose only when those signals are live, tying directly
into AR-2.

**Adoption sketch**: define the lens set as reviewer templates sharing one **injected**
Reviewer Contract (via AR-5); compile "review the diff" to a Reactor `map`/parallel wave;
feed findings to AR-4's fixer. Start with 3–4 lenses (correctness, security, quality,
structure), not all 15.

### AR-4. Self-heal fixer loop — review → fix → re-review until clean

**Recommendation**: BUILD-ON (with AR-3).

**Where** (Alp River): `agents/fixer.md` — input `@findings`, output `@diff`, and the smart
bit: it emits a **RE_RUN_SET** = the union of *{gates that flagged a finding it fixed}* ∪
*{gates whose domain its edits touched}* (`fixer.md:33-40`; e.g. editing a UI file while
fixing a correctness bug re-runs the visual lens even though visual didn't flag it). Lenses
re-run after the fixer until all are clean (`WORKFLOW.md` `## Convergence`).

**jido_radclaw gap**: `IterativeWorkflow` has a generator/evaluator retry loop
(`workflows/iterative_workflow.ex`) — the closest analog — but reviewer findings do **not**
feed an automatic fixer, and there is no review-fan-out → fix → targeted-re-review.

**Relationship to Squidie**: maps onto Reactor's `recurse`/iterative compositional steps —
which Squidie §5 already plans to use for skills' "iterative" execution mode. The self-heal
loop is a recursing Reactor: review wave → fixer (if findings) → recompute the re-run set →
converge.

**Adoption sketch**: a `recurse` Reactor whose body is {review wave → fixer → re-run touched
lenses}, terminating when every lens is clean. Port the domain-touched RE_RUN_SET logic — it's
what keeps the loop both complete (re-checks side-effects of a fix) and cheap (re-runs only
affected lenses).

---

## §3 — Independent of the engine (prompt-layer borrows, land anytime)

These are pure prompt/output assembly. They need **neither** Reactor nor the composer and can
be picked up opportunistically without touching the Squidie roadmap. AR-5 is the enabler for
AR-6, AR-7, and AR-3's shared contract.

### AR-5. Central doctrine injection into sub-agents

**Recommendation**: INDEPENDENT. The highest-leverage prompt-layer borrow; unblocks AR-3/6/7.

**Where** (Alp River): `hooks/user-context-injector.sh` — a `PreToolUse(Agent)` hook that
prepends four blocks to **every sub-agent's** prompt: `## DOCTRINE` (per-agent slices from
`doctrine/`, gated by a `DOCTRINE_MAP`, `:163-191`), `## USER_CONTEXT` (MEMORY.md + linked
files, `:309-337`), `## PROJECT_CONTEXT` (`docs/` slices per a `READ_MAP`, `:339-399`), and
`## PSYCHOLOGY` (AR-6). Agents stay thin by **citing** "your DOCTRINE block" instead of
carrying the rules inline — the contract is single-sourced (`doctrine/code-doctrine.md`,
`reviewer-contract.md`, `confidence-tagging.md` are each authored once and injected into the
agents that cite them).

**jido_radclaw gap**: **no central doctrine injection.** The `Prompt` builder
(`agent/prompt.ex:300-315`) assembles a rich prompt — but **only for the main agent**
(`Startup.inject_system_prompt` is called from the REPL/handoff paths, never from
`SpawnAgent` or `StepAction`). Spawned workers receive **only** their compile-time
`:description` + the task string + `ToolContext` scope keys. Consequence: doctrine text is
**duplicated literally** across 5 workers' `:description` strings (the artifacts schema is
copy-pasted into Coder/Refactorer/DocsWriter/TestRunner), and the Reviewer's contract exists
only as a one-liner.

**Relationship to Squidie**: fully orthogonal — no engine involvement.

**Adoption sketch**: extend `ToolContext.child/3` + the spawn path so a sub-agent's prompt is
assembled from (a) a `JidoClaw.Doctrine` registry (Elixir-side text/EEx: reviewer-contract,
code-doctrine, confidence-tagging), gated per-template by a doctrine map; (b) the existing
Memory blocks (`Prompt.blocks_section/1` — already built for the main agent, reuse it); (c)
project docs. This is the Elixir analog of the hook, de-dupes the worker descriptions, and
makes AR-3's Reviewer Contract a real single-sourced artifact.

### AR-6. Psychology / persona layer

**Recommendation**: INDEPENDENT. Cheap, genuinely novel, ~a day on top of AR-5.

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

### AR-7. Confidence-tagging as a pervasive convention

**Recommendation**: INDEPENDENT (ships as a doctrine slice via AR-5).

**Where** (Alp River): `doctrine/confidence-tagging.md` — every finding carries `[likely]`
(evidence-based: code read, official docs, observed) or `[unsure]` (judgment, single-source,
inferred); both still hedge. `reviewer-contract.md:5-11` adds reporting thresholds: `[likely]`
unconditionally, `[unsure]` only at high impact (correctness/security/data risk), plus the
concrete-consequence bar. Web-sourced agents must include the source URL.

**jido_radclaw gap**: confidence exists in only 3 narrow typed slots — `Researcher` and
`Verifier` workers (`confidence ∈ low|medium|high`) and the `verify_certificate` tool (a
0.0–1.0 float). There is **no codebase-wide claim-tagging convention** and no system-prompt
instruction to mark assumptions or distinguish observed-vs-inferred.

**Relationship to Squidie**: orthogonal; pairs with AR-3 (it *is* part of the reviewer
contract) and AR-5 (it ships as a doctrine slice).

**Adoption sketch**: add a `confidence-tagging` doctrine slice injected into citing agents;
extend the Reviewer/Researcher/Verifier output schemas to carry the tag + reporting threshold.
Cheap once AR-5 exists.

### AR-8. Conversation-type triage (talk / sketch / code / system)

**Recommendation**: INDEPENDENT front door; folds into AR-2 if/when that lands.

**Where** (Alp River): `WORKFLOW.md` `## Seed and path` + `agents/triage.md` — an always-on
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

---

## §4 — Skip / already covered

- **The hook substrate + `.md`/`.py`/`.json` artifacts** (`route.py`, `gen-catalog.py`, the
  bash injectors, the markdown agent format) → **re-implement, don't port.** The *catalog
  concept* (frontmatter → machine-readable stage index) transfers to AR-2; the Python/Bash/
  markdown *artifacts* are Claude-Code-harness-specific.
- **Compaction / `reinject-canonical-state.sh`** → **SKIP.** jido_radclaw's
  `Reasoning.Compactor` is more sophisticated (per-`Identity` keying, `RequestTransformer`,
  persisted snapshots — `reasoning/compactor.ex`). Alp River's reinject hook is a weaker
  cousin; the composer-state-from-event-log idea in AR-2 supersedes it.
- **Reconcile-from-tree recovery** (`WORKFLOW.md` `## Recovery`) → **mostly covered.** Squidie's
  event-log recovery (`REACTOR-ADOPTION.md` §4.8) is the durable, general version; for code
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
  machinery once those land; not separate substrate.
- **Input/Output template contracts** (`WORKFLOW.md` `## Input Template Contract`) →
  **partially covered.** Zoi structured outputs + `StepAction`'s `produces`-injection
  (`workflows/step_action.ex:223-243`) already cover most of it. The verbatim-relay discipline
  (never paraphrase a predecessor's output) is worth adopting as an orchestrator convention if
  AR-2 is built.

---

## The three layers, side by side

| Layer | Squidie / Reactor (next feature) | Alp River | jido_radclaw today |
| --- | --- | --- | --- |
| Execute a bounded **declared** DAG | **Reactor** (DAG, concurrency, saga, halt/resume) | defers to the harness | static skill drivers (being deleted) |
| **Durability** (log, status, recovery, gates) | **the envelope** (`WorkflowEvent`, projection, reconciler, human gates) | ephemeral signal state + reinject hook | mutated `status` column → stranding bug |
| **Dynamic composition** of the stage set | *out of scope* (§6 → free-form ReAct) | **the signal router** (`route.py`) — the gap-filler | `Classifier` picks **1** static plan |
| **Multi-agent quality** (review fan-out, self-heal) | — | **15 lenses + contract + fixer** | single `Reviewer`, no contract |
| **Prompt assembly** (doctrine, persona, context) | — | **injector hook** (doctrine/persona/context) | main-agent only; workers get `:description` |

The top two rows are Squidie. The bottom three are Alp River — and they **stack on top of**
the Squidie substrate, they don't compete with it.

## Sequencing recommendation

1. **Ship Squidie unchanged.** Reactor + the durable envelope (T1-1 event log, status-as-
   projection, recovery) is the foundation everything below needs. Nothing in this document
   changes that plan or its phases.
2. **Fold AR-1 into Squidie Phase 2** (human-gate DSL) as a *design input* — the gate
   taxonomy + abandon/retraction lifecycle. Near-zero cost; avoids designing the gate model
   twice.
3. **Then build the composer (AR-2)** as the next feature — the deterministic signal layer
   above the engine, reusing the event-log/projection model. Give it its own exploration doc.
4. **AR-3 (reviewer fan-out) + AR-4 (self-heal)** are the first concrete workflows to run on
   the engine — alongside or just after the composer.
5. **AR-5 → AR-6/AR-7, and AR-8** are independent prompt-layer wins; land them opportunistically
   whenever convenient. AR-5 first (it enables the others).

## Bottom line

Alp River is the most architecturally relevant project in this folder *and* the one most
easily misread as a reason to pivot. It is not. It is the **methodology layer that sits above
the engine Squidie is about to build**: the deterministic composer for the dynamic middle
ground Squidie deliberately leaves to free-form ReAct, plus the multi-agent review, self-heal,
doctrine-injection, and persona content to run on top. **Do Squidie first**, fold in the gate
semantics (AR-1) while you're in the human-gate code, then build the composer (AR-2) and its
workflows (AR-3/AR-4) on the foundation it leaves you — and pick up the prompt-layer borrows
(AR-5/6/7/8) whenever there's a spare afternoon.
