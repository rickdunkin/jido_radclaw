# Features Worth Borrowing from Claude Code Dynamic Workflows

Exploration notes — not a plan, not a commitment. Inventory **2026-07-07**. Source: the
Anthropic engineering post ["A harness for every task: dynamic workflows in Claude
Code"](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code)
(Thariq Shihipar & Sid Bidasaria, published ~2026-06/07: "last week, we released"), the
[official docs page](https://code.claude.com/docs/en/workflows), and **firsthand
operation of the `Workflow` tool surface in this project's own Claude Code harness**
(2026-07-07, Fable 5 session). Provenance is the inverse of nono's "read but not
executed": **operated but not read** — no engine source exists to pin, so subject-side
claims cite the published post/docs and the tool's own contract as exercised; camus
pinned the same primitives at "Claude Code ≥2.1.154". jido_radclaw @ `501fb9fc`; cites
on our side are firsthand reads of the tree, accurate to within a few lines. The working
tree carries in-flight clustering WS6 work; none of the seams cited here are touched by
it. **First non-repo subject in the corpus**: identity pins to URL + date + harness
version instead of a sha; a re-review re-operates the tool surface and re-reads the docs
page. Threat-model weighting as usual for this project (personal, tailnet-only):
LLM-misbehavior containment and leakage hygiene over external-attacker hardening.

Companion docs this interacts with: `docs/exploration/camus/` (**a product built on this
subject** — three dynamic workflows totaling ~3.2k LOC of `agent()`/`budget`/journal-resume
JS; its engine-half verdict "composer + Reactor already superset it" extends from camus's
*use* of the feature to the feature itself, and its judgment-layer borrows — verdict
normalizer, verify authority, honest statuses — are the shipped machinery several
entries below lean on), `docs/exploration/amber/` (AM-1 code-mode pair → shipped as
`lua_query`/`lua_docs`; DW-1 builds directly on that adoption), `docs/exploration/squidie/`
(the Reactor + durable-envelope adoption — why the subject's durability half is Already
Covered), `docs/exploration/jidoka/` (origin of the Lua Policy/CallTrace internals and of
the tool-approval gate DW-2's OQ-1 leans on), `docs/exploration/gust/` (vocabulary
precedent for runtime-vs-engine verdicts: "an Airflow competitor, not a Reactor
competitor"), and `docs/exploration/pms/` OpenHelm OH2-1 (charge-before-call automation
budget ledger — DW-4's corpus sibling).

**Origin note**: this inventory came out of an operator-initiated review of the blog
post plus a two-question design conversation ("could our Lua sandbox serve instead of
JS?" / "could an agent dynamically create a Reactor flow?"), single session — not an
explore-repo fan-out. The conversation's design synthesis (the three-layer program,
Tier 1) is recorded in the entries rather than a separate design doc.

**Revision (2026-07-07, same day as the initial inventory)**: all three open questions
decided by operator interview, same session — **OQ-1 → gate every inline run**;
**OQ-2 → deterministic-by-default bindings**; **OQ-3 → pulled forward into the DW-2
slice** (gated-struct checkpoint/resume ships with inline definitions,
fingerprint-keyed). DW-1/DW-2, the graph, and the first wave updated in place; DW-7's
`docs/TRUST-BOUNDARIES.md` citation shipped with the same change (see its Status line).

## Determination (TL;DR)

**Nothing to adopt as a dependency — it isn't one — and the architectural comparison
lands in our favor.** The subject's orchestration script does double duty as control
flow *and* durability unit: resume works by re-executing a deterministic script against
journaled `agent()` results, which is why its runtime bans `Date.now()`/`Math.random()`.
That is the architecture you build when you don't have a durable workflow engine.
jido_radclaw already splits those concerns — Reactor holds control flow (guards, sagas,
native `map`, runtime step emission), the `WorkflowRun` envelope holds durability — so
importing the script-shaped model would mean bolting a second, weaker durability story
onto the side of a stronger one. What the subject *does* have is a capability our stack
lacks: **the model authors the harness per task**. The haul is a three-layer program
that grafts exactly that capability onto the existing engine (inline definitions through
the compiler that was already built for LLM-authored YAML; a fan-out construct the
Reactor dep already ships; Lua as the sandboxed computation layer between steps — the
operator-flagged headline, valuable to *committed* skills before any dynamic authoring
exists), plus two standalone items (a per-run token budget pool; the quarantine practice
hardened into a machine-checked invariant). The pattern catalog is otherwise Already
Covered, usually by stronger mechanisms.

| Part of the subject | As a dependency | What to take |
| --- | --- | --- |
| JS orchestration runtime (`agent()`/`pipeline()`/`parallel()`) | No — harness artifact; no JS runtime in a BEAM escript | Nothing as a runtime; the *role* lands as Lua-computed glue (DW-1) + a fan-out step kind (DW-3) |
| Dynamic authoring (model writes the harness per task) | — | The authoring seam, re-expressed as inline skill definitions through the existing compiler (DW-2) |
| Journal-resume + determinism bans | No | Nothing — the envelope supersedes it; TRACK a step-result memo for long flows (DW-6) |
| `budget.total/spent()/remaining()` shared token pool | — | The mechanism, per `WorkflowRun` (DW-4; OH2-1's sibling) |
| Pattern catalog (classify / fan-out / adversarial / tournament / loop / quarantine) | — | Mostly Already Covered; tournament TRACKed (DW-8); quarantine hardened into an enforced invariant (DW-5) |
| Failure-mode taxonomy (agentic laziness / self-preferential bias / goal drift) | — | Vocabulary garnish for `docs/TRUST-BOUNDARIES.md` and system docs (DW-7) |

### Why not a script-shaped orchestrator (and why not JS)

1. **It's a harness artifact, not a library** — camus's "Why not adopt" §1 extends
   verbatim: the primitives are Claude Code internals with no seam to embed. On our side
   there is additionally no JS runtime at all; embedding one means a NIF (quickjs) or a
   subprocess dependency for a role our stack already fills.
2. **The script's double duty is the tell.** Control flow and durability ride the same
   artifact: resume = re-execute the deterministic script, skipping journaled `agent()`
   calls. Our durability is event-sourced at step granularity
   (`JidoClaw.Orchestration.ReactorRunner` — durable `WorkflowRun` + event log +
   recovery; `lib/jido_claw/orchestration/reactor_runner.ex:1-26`). Adopting their model
   would create a second durability mechanism parallel to the envelope, and a worse one:
   whole-script determinism obligations instead of per-step journaling. Their
   determinism bans exist to serve their resume model; ours doesn't need them (an
   incomplete step re-runs; completed steps never re-execute).
3. **Lua-as-the-orchestrator specifically fails on duty cycle.** The sandbox is
   engineered as a short, bounded, synchronous, read-only eval:
   `JidoClaw.Tools.Lua.Policy` defaults 1,500 ms timeout (hard-clamped ≤5,000), 12 host
   calls (≤25), 6 KB script, 32 KB result, 10M instructions
   (`lib/jido_claw/tools/lua/policy.ex:30-38`), every `jido.*` call inline in one eval
   task. An orchestration script that spawns agents and waits minutes violates every cap
   by orders of magnitude; supporting it means rebuilding the Runner's whole lifecycle
   posture (watchdog, heap kill, deadline gate —
   `lib/jido_claw/tools/lua/runner.ex:11-16`) for a different duty cycle, *and* adding
   the write binding (`agent()`) that `assert_read_only!/0` deliberately fences.
   The Lua VM is the right runtime for the *computation* seat (DW-1), not the
   orchestrator's.
4. **Honest deficits on our side** (they don't change the verdict; they seed entries):
   the subject has cached-prefix resume where our skill replay is whole-run (DW-6), and
   a shared token pool where all our budgets are count-denominated (DW-4).

## How to read this document

Same vocabulary as the rest of the corpus, scoped to this codebase: **BORROW-PATTERN**
(re-implement the mechanism on our stack), **BUILD-ON** (extends a shipped adoption),
**ALREADY-COVERED** (must cite the local equivalent), **TRACK** (watch, with a named
trigger), **SKIP**, and *garnish* (vocabulary/doc-level lift, no mechanism). Tier 1 is
the three-layer dynamic-flows program in dependency order; Tier 2 is standalone
mechanism borrows; Tier 3 is garnishes and watches. Entries are `DW-n`. Per-entry
fields follow the house anatomy; every **Gap** claim was verified against the tree on
2026-07-07. Subject-side cites of the tool contract are marked *(operated 2026-07-07)*.

## Tier 1 — the dynamic-flows program

### DW-1. Lua as the computation layer between steps (`reduce:` / `when:` glue)

**Recommendation**: BORROW-PATTERN / BUILD-ON AM-1. Operator-flagged headline: valuable
to committed skills today, independent of DW-2/DW-3.

**Where in the subject**: the orchestration script's inter-agent data shaping — dedup
and merge between stages, deriving fan-out item lists from prior results, routing on
classifier output; the blog's own barrier discipline says cross-item dedup/merge is the
one legitimate reason stages synchronize *(blog "Helpful patterns"; Workflow tool
contract, operated 2026-07-07)*.

**What**: run the data shaping between agent steps in a sandboxed script instead of in
an agent's context or the orchestrator's prompt: filter/join/aggregate one step's
structured output before the next step or the synthesis prompt consumes it, decide
routing, compute fan-out item lists. In their runtime this is plain JS between
`agent()` calls; the intermediate rows never enter model context.

**Gap in jido_radclaw** (verified 2026-07-07): compiled skills have **no computation
between steps**. The only inter-step transforms are prompt *formatting*
(`AgentStep` reconstructs upstream `%StepResult{}`s via `Workflows.ContextBuilder`,
`lib/jido_claw/skills/steps/agent_step.ex:5-10`) and the terminal `CollectStep`'s
result-map assembly — any actual filter/dedup/derive today costs another agent step
(tokens, nondeterminism) or doesn't happen. Meanwhile both halves of the mechanism
already exist unwired: the in-tree Lua sandbox is precisely a bounded evaluator over
structured data (AM-1's shipped `lua_query`, whose charter is "intermediate rows never
enter model context" — `lib/jido_claw/tools/lua/`), and Reactor ships native
conditionals we don't expose — `guards:` is a first-class option on
`Builder.add_step` (`deps/reactor/lib/reactor/builder/step.ex:52-56`), with
`guard`/`where` DSL entities (`deps/reactor/lib/reactor/dsl/guard.ex`, `where.ex`).

**Why it matters**: this is the subject's genuinely good idea made better by our trust
model. Their script holds intermediate state in the orchestrator's runtime; ours would
compute it in a sandboxed, budgeted, call-traced VM whose results land in the durable
step events. Deterministic and token-free where the alternative is another LLM hop; the
existing Policy caps (short evals over structured data) *fit* this duty cycle, unlike
the orchestrator seat (Determination §3). Strictly read-only over run data — no
`assert_read_only!/0` change, no approval-surface change, the whole
budget/policy/tracing apparatus applies unchanged.

**Adoption sketch**: two YAML step fields (or one `lua:` step kind), compiled by
`Skills.Compiler`:
- `reduce:` — a Lua script evaluated via `Lua.Runner` with a read-only bindings view
  over the step's wired upstream `%StepResult{}`s; its return value becomes the step's
  result (a pure-computation step) or the derived argument for a downstream step (the
  DW-3 item list). Reuse `Lua.Bindings`' single-source pattern for the exposed view.
- `when:` — same evaluation shape, boolean result, lowered onto Reactor's native
  `guards:` at `Builder.add_step` (skip semantics come free from the engine).
Result lands in `step_*` event payloads like any step. Caps: default Policy is likely
fine; if real reducers need more than 32 KB results, raise per-step within the clamp
ceilings, never unbounded. Determinism (OQ-2, **decided 2026-07-07**): the bindings view ships
**deterministic-by-default** — upstream results exposed through sorted-key iteration
helpers so the easy path is order-stable (`pairs()` order is undefined in Lua) — plus
arrays/sorted-keys guidance in the `lua_docs` rendering; hard output enforcement
deliberately waits for DW-6's trigger.

### DW-2. Inline skill definitions — the dynamic-authoring seam

**Recommendation**: BORROW-PATTERN. Decision-complete: OQ-1 and OQ-3 resolved
2026-07-07 — launch is gated per-run, and mid-flow gate support is pulled into this
slice (see sketch).

**Where in the subject**: the core thesis — "Claude can now write its own harness on
the fly, custom-built for the task at hand"; scripts are authored per-task, persisted,
resumable, shareable as templates *(blog; Workflow tool contract, operated 2026-07-07:
`script` inline / `scriptPath` / saved `name` invocation forms)*.

**What**: the agent authors the orchestration *definition* at runtime instead of
choosing from a fixed catalog. Their form is a JS program; the capability, separated
from their architecture, is "model-authored workflow definitions, validated and
executed by the engine."

**Gap in jido_radclaw** (verified 2026-07-07): the compiler was **built for exactly
this and the tool surface doesn't expose it**. `Skills.Compiler`'s moduledoc opens
"Compile an LLM-authored YAML skill" and its whole design is untrusted-author-shaped —
positional atom ids so YAML never mints atoms, `StepIds.max()` cap, up-front
duplicate/missing-dep/cycle/metadata validation returning clean `{:error, _}`
(`lib/jido_claw/skills/compiler.ex:2-4,14-20,62-69`). But `run_skill` resolves **names
only** against the boot-time cache (`lib/jido_claw/tools/run_skill.ex:56` →
`JidoClaw.Skills.get/2`, `lib/jido_claw/platform/skills.ex:288-292`). A file-mediated
path technically exists today (`write_file` into `.jido/skills/` → `Skills.reload/0`
(`platform/skills.ex:300-304`) → `run_skill`) but is unwitnessed end-to-end and
side-steps nothing — the YAML on disk is still the trust object. The in-house precedent
for inline-vs-named is already written: `run_pipeline` accepts inline `stages:` with
strict precedence (inline wins; bad inline never silently falls through to the ref —
`lib/jido_claw/tools/run_pipeline.ex:15-25`).

**Why it matters**: a dynamic harness per task — the subject's whole pitch — for the
cost of a tool parameter, with every existing guarantee intact: durable envelope,
event timeline, dashboard, per-tool approval gates inside agent steps, template tool
scoping, deterministic verify where declared. The trust delta is real and nameable
(operator-committed YAML → LLM-authored data) and the mitigations are all standing:
the step-kind vocabulary is **closed** (the agent emits data; only the compiler
constructs Reactors — the executor seam's refuse-unknown-backend discipline applied to
orchestration), validation refuses loudly, and `DefinitionFingerprint` already hashes
definitions (`run_skill` stamps `definition_hash` today).

**Adoption sketch**: a `definition:` param on `run_skill` (map, same schema as the YAML,
same `StepNormalizer`/`Compiler` path), precedence rules per the `run_pipeline`
precedent, `DefinitionFingerprint` over the normalized definition, `name` required in
the definition for display. Gating (OQ-1, **decided**: gate every inline run): a
param-pattern trigger on `run_skill` when `definition:` is present — fingerprint-keyed
durable `AgentCase`, operator decides in `/gates`/`/approvals`, approvals single-use
exactly per the gate's existing semantics (each run asks; TOFU-per-fingerprint is the
named follow-up only if the interrupts prove annoying). Mid-flow gates (OQ-3,
**decided**: pulled forward): this slice also delivers gated-**struct**
checkpoint/resume — closing `ReactorRunner`'s flagged future item — with the
resume-allowlist identity, module-name-keyed today, gaining a struct arm keyed on
`definition_hash` (the fingerprint IS the struct-world checkpoint identity), so an
inline flow can carry `GateStep`s from day one. Persist the definition in run
config/`replay_inputs` so
replay's definition-hash gate has a stable object to compare (the on-disk fresh-read
path, `platform/skills.ex:393-407`, doesn't apply to inline runs — replay must read the
stored copy).

### DW-3. `fan_out:` — dynamic map-over-a-runtime-list in skills

**Recommendation**: BORROW-PATTERN (mostly *expose-the-dep*: evaluate Reactor's native
`map` before building anything).

**Where in the subject**: `pipeline(items, ...)`/`parallel(...)` over lists produced by
earlier stages; the migration use case (item per callsite/test/module) and
loop-until-dry accumulation *(blog "Migrations", "Helpful patterns"; Workflow tool
contract, operated 2026-07-07: 4,096-item stage cap, concurrency `min(16, cores-2)`,
1,000-agent lifetime cap — their bounds vocabulary is worth keeping in view)*.

**What**: a step that expands over a list *known only at runtime* — one agent step per
item from a prior step's output — then converges into a downstream step.

**Gap in jido_radclaw** (verified 2026-07-07): the skill vocabulary is a **static** DAG
(plus the single `IterativeStep` loop): step count is fixed at compile, so
fan-out-and-synthesize / generate-and-filter / tournament shapes aren't expressible.
Every needed engine primitive already exists below the vocabulary line: Reactor's step
contract returns `{:ok, value, [Step.t()]}` — runtime step emission is first-class
(`deps/reactor/lib/reactor/step.ex:54-58`); Reactor 1.0.2 ships a native **`map`** DSL
entity (iterable source, nested steps, `batch_size: 100`, `strict_ordering?`,
`allow_async?`, guards — `deps/reactor/lib/reactor/dsl/map.ex:6-40`) plus `switch`,
`recurse`, and `group` (`deps/reactor/lib/reactor/dsl/`); and the dynamic-construction
pattern is proven in-tree — `RouteComposer.WaveBuilder` builds waves at runtime drawing
from the same `StepIds` atom pool the compiler uses
(`lib/jido_claw/skills/compiler.ex:80-83`).

**Why it matters**: this is the one real engine-vocabulary addition the dynamic-flows
program needs; DW-1 and DW-2 without it cover only fixed-shape harnesses. Bounded by
construction: ids come from the `StepIds` pool, so the existing cap doubles as the
fan-out ceiling (their 4,096/1,000 caps, our `StepIds.max()` — same idea, already
enforced).

**Adoption sketch**: spike first on lowering a `fan_out:` skill step onto Reactor's
native `map` from `Builder` (the DSL entity exists; confirm the programmatic
construction path for non-DSL reactors — if `Builder` lacks a map equivalent, hand-roll
via `{:ok, value, [Step.t()]}` emission with ids drawn from `StepIds`). YAML shape:
`fan_out: {over: <upstream step or DW-1 reduce>, template: ..., task: ...}` with an
implicit gather feeding `CollectStep` (or the named downstream step). Design question
to settle in the spike: result aggregation for emitted steps (Reactor `map`'s `return`
field vs. an explicit gather step). Composes with DW-1 (the `over:` list is typically
reduce-derived) and carries DW-8's bracket shape when that trigger fires.

## Tier 2 — standalone mechanism borrows

### DW-4. Per-run shared token budget pool

**Recommendation**: BORROW-PATTERN. Corpus sibling: pms/OpenHelm **OH2-1**
(charge-before-call automation budget ledger) — same family, theirs charges before the
call, the subject's checks a shared pool mid-loop; take the union.

**Where in the subject**: `budget.total` / `budget.spent()` / `budget.remaining()` — a
turn-level token target set by user directive, shared across the main loop and all
workflow agents, enforced as a **hard ceiling** (`agent()` throws once spent ≥ total),
with loop-until-budget as a first-class pattern *(Workflow tool contract, operated
2026-07-07; blog "Token usage budgets")*.

**What**: one pool per run, debited by every agent turn under it, consultable by
orchestration control flow, terminal-loud on exhaustion.

**Gap in jido_radclaw** (verified 2026-07-07): every orchestration budget is
**count-denominated** — `Skills.Steps.RetryBudget`, `IterativeStep` iteration caps, the
composer's `rerun_cap`/`infra_cap`, LoopGuard's per-key call budget, Lua's
`max_calls`. The only token-denominated mechanism anywhere is the embeddings
`RatePacer` (`lib/jido_claw/embeddings/rate_pacer.ex:64,189-206`) — rate limiting, not
a run budget. A runaway swarm is bounded in *loops* but not in *spend*.

**Why it matters**: cost is the orthogonal axis LoopGuard doesn't cover, and dynamic
flows (DW-2/DW-3) widen the exposure — a model-authored fan-out is exactly the shape
that deserves a hard ceiling. OpenHelm's v1 anti-pattern (users disabled automation for
burning tokens) is the cautionary datapoint already in the corpus.

**Adoption sketch**: pool on `WorkflowRun` (target in `config`, spent as a counter
updated through a single fenced writer — the GateDisposition aggregate-writer
discipline, lock order run→case→events). `AgentRunner` debits actual usage post-turn;
`IterativeStep`/`fan_out` consult `remaining` before dispatch. Exhaustion is its own
loud terminal in the budget lane — never folded into a verdict lane
(`docs/TRUST-BOUNDARIES.md` review applies). Config: per-run override → skill YAML →
tenant default.

### DW-5. Quarantine as a machine-checked invariant

**Recommendation**: BORROW-PATTERN, do-now class — cheapest item on the list and the
most threat-model-aligned.

**Where in the subject**: the triage-workflow quarantine pattern — "barring the agents
that read untrusted public content from taking high-privilege actions, which are
instead done by the agents in charge of acting on the information" *(blog "Triaging at
scale")*.

**What**: structural privilege separation between untrusted-content *readers* and
high-privilege *actors*, as an architecture rule rather than per-case judgment.

**Gap in jido_radclaw** (verified 2026-07-07): the **practice exists; the rule
doesn't**. Templates already separate by judgment — `researcher` (the untrusted-ingest
worker: `BrowseWeb`/`SearchWeb`) carries a strictly read-only toolset
(`lib/jido_claw/agent/workers/researcher.ex:11-18`); sketch workers are file-tools-only
by documented design (`sketch_build.ex:4-8`); `system_verifier` is composer-private
with no external MCP tools (`system_verifier.ex:13`). But nothing *fails* if a future
template combines `BrowseWeb` with write/exec/spawn — the invariant lives in heads and
comments. The documented MCP-consumption residual (description-borne injection reaches
the prompt before any gate — `docs/system/mcp-consumption.md`) makes reader/actor
separation the structural mitigation for precisely the class the approval gate can't
catch.

**Why it matters**: this project's threat model *is* LLM-misbehavior plus leakage
hygiene. The check costs an afternoon and converts the corpus-wide lesson (pad PD1-1's
enforcement-rot; our own MCP server once advertising a stale version) into prevention:
declared-but-unenforced invariants rot.

**Adoption sketch**: a precommit check in the `system_prompt.check`/`jido_md.check`
family. Classify registered tools into **untrusted-ingest** (`BrowseWeb`, `SearchWeb`,
external `mcp_*` proxies — fail-closed for unknown `mcp_`-prefixed names, matching the
consumption doc's posture) and **effect** (write/exec/spawn/git/handoff) classes;
assert no worker template carries both; exceptions allowlisted with inline
justification. The main agent is the documented standing exception (conversation-axis,
approval-gated, LoopGuard-bounded). Set-compare style and failure voice per the
existing checks.

### DW-6. Step-result memo (cached-prefix resume)

**Recommendation**: TRACK. Trigger: a real dynamic flow (post-DW-2/DW-3) long enough
that whole-run replay visibly burns agent-step re-execution — or DW-4 landing makes
re-spend measurable.

**Where in the subject**: resume semantics — the longest unchanged prefix of `agent()`
calls returns journaled results instantly; only edited/new calls run live *(Workflow
tool contract, operated 2026-07-07)*.

**What / Gap** (verified 2026-07-07): our replay is **whole-run** — `retry_of_id`
provenance, `replay_inputs`, and the definition-hash gate comparing current on-disk
skill against the recorded hash via a deliberate fresh-disk read
(`lib/jido_claw/platform/skills.ex:393-407`). Completed steps re-execute on replay.
Correct, durable, and simpler than their model — but strictly coarser.

**Why TRACK, not borrow now**: at current skill lengths the coarseness is cheap, and a
memo adds a cache-correctness surface (keying on `(definition_hash, step_id,
input_hash)`, invalidation on template/tool changes) that shouldn't be paid
speculatively. Record the shape; adopt when the trigger fires.

## Tier 3 — garnishes and watches

### DW-7. The failure-mode taxonomy as documentation vocabulary

**Recommendation**: garnish (doc-level lift, no mechanism). **Status (2026-07-07):
ADOPTED (TRUST-BOUNDARIES half)** — the preamble now names the three modes with their
machinery mapping (rode the OQ-resolution/cross-link change); the `docs/system/` "why"
paragraphs still ride each page's next touch.

**What**: the blog's three names — **agentic laziness** (declaring done at partial
coverage), **self-preferential bias** (preferring one's own output when judging it),
**goal drift** (fidelity loss across turns/compaction) — are crisp labels for the
"why" behind invariants we already enforce: agentic laziness → the honest-terminals
family (`FindingKey` identity, stall detection, all-or-reject waivers,
`done_with_findings` amber); self-preferential bias → `ReviewIndependence`'s
cross-vendor fence (camus C1-1) and fresh-context judge stages; goal drift → scoped
per-agent compaction plus fresh-context workers with schema'd handoffs.

**Adoption**: the `docs/TRUST-BOUNDARIES.md` preamble citation landed 2026-07-07 with
the cross-link pass; the terminal-statuses and executor-seam pages' "why" paragraphs
still pick the terms up on their next touch — not worth a dedicated change.

### DW-8. Tournament / pairwise-judgment shapes

**Recommendation**: TRACK. Trigger: a real ranking/taste workload (support-queue
severity sort, design/naming selection, eval grading at scale).

**What / Why**: the subject's sorting guidance — comparative judgment is more reliable
than absolute scoring; hold the bracket in deterministic control flow, keep only the
running order in context *(blog "Sorting", "Tournament")*. No skill shape expresses
pairwise brackets today. Composes cleanly once DW-1 + DW-3 exist (reducers compute
pairings and carry bracket state; `fan_out:` runs a round's comparisons); the eval
harness (`JidoClaw.Eval`) is the natural first consumer.

## Skip / Already Covered

- **JS orchestration runtime as a dependency** — SKIP: harness artifact (camus "Why not
  adopt" §1); no JS runtime in this BEAM app, and DW-1/DW-3 fill the role.
- **Journal-resume + determinism bans** — SKIP/superseded: squidie's envelope is
  event-sourced at step granularity (`ReactorRunner`); their bans serve a resume model
  we don't have. The narrow live remainder is DW-6.
- **Adversarial verification** — ALREADY-COVERED, stronger: `Orchestration.Verdict`
  (schema drift fails closed to infra, findings-win), `ReviewIndependence` (cross-
  *vendor*, a stronger axis than their cross-context), and the deterministic Verify
  authority (exit-code verdict, never an LLM relay — TRUST-BOUNDARIES law 2). Nothing
  in the subject verifies deterministically.
- **Loop-until-done** — ALREADY-COVERED: `IterativeStep` + `rerun_cap`/`infra_cap`.
  The subject's loops have no infra≠verdict split — the conflation camus's inventory
  called the "#1 cause of runaway loops." Their pattern would re-import a fixed bug.
- **Agentic-laziness countermeasures** — ALREADY-COVERED: cross-wave `FindingKey`
  identity, stall/oscillation detection, all-or-reject waivers,
  `:route_done_with_findings` amber (docs/system/terminal-statuses.md). Their "35 of 50
  findings addressed" example is the exact scenario these exclude.
- **Goal drift / compaction loss** — ALREADY-COVERED by different means: scoped
  per-agent compaction with persisted snapshots (`Reasoning.Compactor`), and the
  swarm's fresh-context workers with Zoi-schema'd structured handoffs — the structural
  mitigation the blog gestures at.
- **Model/intelligence routing** — ALREADY-COVERED: the AR-9 stage-tier seam
  (`Compactor.RequestTransformer` per-turn `model`/`reasoning_effort` overrides). A
  classifier feeding that seam is possible later without engine change.
- **Worktree-per-mutating-agent** — ALREADY-COVERED by different means: Forge
  sandbox-first isolation + the executor seam's hardwired read-only/isolated vendor
  sessions. No present gap; revisit only if DW-3 fan-out ever dispatches parallel
  *fixers* against one tree.
- **Prompted token budgets ("use 10k tokens")** — SKIP as mechanism (advisory
  prompt-parsing); DW-4 is the enforced version.
- **`/loop` + `/goal` pairing** — SKIP: harness UX; cron scheduling +
  `schedule_task`/`IterativeStep` cover the recurring/completion niche on our side.
- **Saving/sharing workflows via skill dirs** — ALREADY-COVERED: committed
  `.jido/skills/*.yaml` with the `jido_md.check`/`system_prompt.check` surface guards;
  their "treat shared workflows as templates, not verbatim scripts" note transfers
  as-is to skill YAML.
- **Quarantine as practice** — ALREADY-COVERED per-template
  (`researcher.ex:11-18`, sketch workers, `system_verifier`); the enforcement delta is
  DW-5.

## Open questions — all decided 2026-07-07 (operator interview, same session)

- **OQ-1 (gates DW-2) — DECIDED: gate every inline run.** A param-pattern trigger on
  `run_skill` when `definition:` is present; each run opens a fingerprint-keyed
  `AgentCase`; single-use approvals exactly per the gate's existing semantics. Zero new
  trust machinery, matches the default-on posture for `mcp_*` tools and the
  LLM-misbehavior threat model. Trust-on-first-use per fingerprint (a durable approval
  record — a deliberate deviation from single-use) is the **named follow-up** only if
  the launch interrupts prove annoying in practice.
- **OQ-2 (DW-1) — DECIDED: deterministic-by-default bindings.** DW-1's bindings view
  exposes upstream step results through sorted-key iteration helpers so the easy path
  is order-stable (`pairs()` order is undefined in Lua), with arrays/sorted-keys
  guidance in the `lua_docs` rendering. No hard rejection of reducer output — boundary
  enforcement deliberately waits for DW-6's trigger, since replay is whole-run today.
- **OQ-3 (DW-2 + gates) — DECIDED: pulled forward into the DW-2 slice.** Gated-struct
  checkpoint/resume ships with inline definitions rather than waiting on a trigger:
  the resume-allowlist identity (module-name-keyed today —
  `lib/jido_claw/orchestration/reactor_runner.ex:29-36`, flagged there as a separate
  future item) gains a struct arm keyed on `definition_hash` — the fingerprint being
  the struct-world checkpoint identity. Consequence accepted with eyes open: DW-2
  grows from a tool-parameter slice to a mid-sized engine slice, and dynamic flows
  carry `GateStep`s from day one instead of living workflow-axis-ungated.

## Cross-references and dependencies

```
AM-1 (shipped: lua_query/lua_docs) ──► DW-1 (Lua reduce:/when: glue) ──┬─► DW-3 (fan_out over reduce-derived lists)
                                                                       └─► DW-8 (tournament brackets; TRACK)
squidie T1-* (shipped: envelope) ──► DW-2 (inline defs + mid-flow gates; OQ-1/OQ-3 decided 2026-07-07)
jidoka (tool-approval gate) ────────┘                    └──► DW-6 (prefix-resume memo; TRACK)
OH2-1 (pms/OpenHelm budget ledger) ──► DW-4 (per-run token pool) — orthogonal; composes with DW-3 loops
DW-5 (quarantine check) — standalone, do-now
DW-7 (taxonomy vocabulary) — standalone garnish
```

**Suggested first wave**: **DW-5** (afternoon-sized, threat-model-aligned, zero design
risk) and a **DW-1 slice scoped to committed skills** (`reduce:` first; `when:` second
once the guards lowering is proven). DW-2 is decision-complete (OQs 1+3, 2026-07-07)
but grew to a mid-sized slice — launch gating plus gated-struct checkpoint/resume — so
sequence it after the DW-1 slice proves the Lua lowering.
DW-3 starts as a spike on Reactor's native `map` from `Builder`. DW-4 rides the first
real swarm-cost pain or the argus FLOW §8 work, whichever lands first.

**Collision notes** (against work in flight, 2026-07-07): clustering WS6 phases 2–4 are
active — no seam overlap with any entry. The deferred RouteComposer `Rerun` extraction
shares the `StepIds`/WaveBuilder neighborhood with DW-3 — sequence them consciously.
DW-4's shape should be reconciled with argus FLOW §8's doom-loop-budget thinking and
OH2-1 rather than designed fresh.

## Bottom line

1. **DW-1 is the keeper regardless of everything else**: Lua as the sandboxed,
   budgeted, token-free computation layer between steps — AM-1's charter extended to
   orchestration, useful to committed skills before any dynamic authoring exists.
2. **The architectural finding is a fence, not a feature**: their script double-duties
   as control flow + durability unit; ours splits them. Borrow the authoring
   capability (DW-2, via the compiler that was already built for LLM-authored YAML);
   never import the script-shaped durability model.
3. **DW-5 now**: the quarantine practice is already in the templates — make it a
   precommit invariant before a future template quietly violates it.
4. **DW-3 is the one engine-vocabulary gap** between us and the subject's pattern
   catalog, and the dep already ships the primitive (`Reactor.Dsl.Map`, runtime step
   emission) — expose, don't build.
