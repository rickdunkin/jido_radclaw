# AR-2 — Deterministic Signal-Driven Route Composer

*Architecture direction — not a commitment.*

Builds on [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) (AR-2 is coined
there), [`../squidie/REACTOR-ADOPTION.md`](../squidie/REACTOR-ADOPTION.md) (the engine this
sits above), [`../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md`](../squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md)
(the event-log envelope), and [`../gust/FEATURES-WORTH-BORROWING.md`](../gust/FEATURES-WORTH-BORROWING.md)
(the lease/observe borrows that hang off the composer).

> **What this doc owns.** Alp River's AR-2 entry says of the composer: *"Scope this as its
> own exploration doc when it's next — it is a feature, not a patch,"* and *"the AR-2
> exploration doc should own"* the gust cross-references. This is that doc. It designs the
> composer **and** reconciles the three gust borrows that converge on it (G1-1 lease unit,
> G2-1 catalog-as-resources/observe, G3-2/G3-3 catalog storage). It does **not** re-design the
> shipped Reactor envelope (Squidie, done), the gate DSL (AR-1, done), or AR-3/AR-4 (the first
> workflows that *run on* the composer — referenced in §12, designed elsewhere).

## Status / where this sits

- **The engine exists.** Reactor + the durable envelope shipped (Squidie Phases 0–5,
  2026-06-08..10): `WorkflowRun.status` projects from an append-only `WorkflowEvent` log,
  YAML skills compile to `%Reactor{}` via `JidoClaw.Skills.Compiler`, `ReactorRunner.run/3`
  is the single front door, human gates halt/resume durably (AR-1 gate taxonomy +
  abandon/retraction shipped in Phase 2), and `WorkflowRecovery` reconciles stranded runs at
  boot. The composer **reuses all of this** — it adds no execution substrate.
- **The reasoning layer is still static** — the Reactor migration never touched it.
  `Classifier.recommend/2` (`reasoning/classifier.ex:142-181`) picks **one** strategy by
  pure scoring; `PipelineStore` holds static linear chains and `RunPipeline.execute/4`
  (`tools/run_pipeline.ex:234-273`) is a fixed `Enum.reduce_while` over a pre-materialized
  list. The two reasoning signals (`reasoning/telemetry.ex:234,306`) are **write-only** —
  nothing subscribes. **There is no composer**: nothing inspects an intermediate result to
  grow the route. This is the gap AR-2 fills.
- **The gust data model landed, behavior deferred.** `WorkflowRun` already carries
  `claimed_by` / `claim_expires_at` / `claim_token` + two global scan indexes
  (`workflow_run.ex:328-341`, `:65-72`) with **zero callers** — lease *columns* exist; lease
  *behavior* waits for clustering (§10.1).

## TL;DR — the target

**A deterministic, signal-composed pipeline for the dynamic-but-bounded middle ground Squidie
§6 hands to free-form ReAct.** The route is a *pure function of durable state*
(`compose_route/4`, the Elixir port of Alp River's `route.py`), not an LLM's whim — legible,
recomposable, gated, and crash-recoverable, without the unpredictability of an open-ended
loop. Each composed **wave** runs as a Reactor (built with `Reactor.Builder`, exactly as
`Skills.Compiler` already does), so every increment inherits the shipped envelope. The composer
is the *dynamic layer*; **Reactor executes the bounded increments**.

The headline insight (from AR-2): the "dynamic, not-a-declared-DAG" space Squidie §6 consigns
to the free-form agent loop **can instead be a deterministic, signal-composed loop** — and Alp
River is a mature, working reference for it. The rest of this document is the *how*: the
algorithm port (§3), the loop (§4), the durability fork (§6), and the gust borrows that
complete it (§10).

## How to read this document

Each section is **design** (the recommended shape + rationale), **reuse** (the existing module
it builds on, cited by `path:line`), or **decision** (a fork, with a recommendation and the
alternative). The genuinely-unresolved choices are collected in §15. The crown jewel is §3 (the
pure router) — self-contained, fully testable in isolation, and the natural first phase (§14,
Phase 0). Internal cross-refs use **§N**; sibling docs are **"Squidie §4.5"** / **"gust G1-1"**
/ **"AR-1"**.

---

## §1 — The third execution mode

Squidie §6 draws a hard line: *"The agent ReAct loop and the swarm are dynamic … Don't force
them into Reactor. A skill (a declared multi-step plan …) is a good Reactor fit; the open-ended
agent loop is not."* That bifurcates the world into two modes:

1. **Declared DAG** → Reactor (bounded, typed, saga/halt-resume). Shipped.
2. **Free-form loop** → the agent's ReAct loop + swarm (unbounded). Untouched, correctly so.

The composer is a **third mode** between them: **dynamic but deterministic**. The *set* of
stages is not known up front (it grows as signals reveal what the task needs), yet each
recomposition is a *pure function* of accumulated state — so the run is legible, reproducible,
and recoverable in a way a free-form loop never is. It is not a competitor to Reactor; it is a
controller that *emits bounded Reactor runs* and folds their results into the next decision.

It occupies the slot the static reasoning layer cannot reach: `Classifier` picks **one**
strategy at the top and never revises; `RunPipeline` walks a **fixed** list. The composer
inspects each wave's output and **re-derives the remaining route** — adding a security lens when
`auth-surface` goes live, holding the implementer behind a TDD gate until `tests-ready`,
dropping a reviewer whose required `diff` no producer will emit. None of the existing reasoning
modules are replaced (§12); the composer sits *beside* them as a new front for code/system work
(§8).

### §1a — Why a new `JidoClaw.RouteComposer`, not `Jido.Composer`

`jido_composer ~> 0.3` is already a direct runtime dependency (`mix.exs:159`), providing
`Jido.Composer.{Workflow, Orchestrator, Node, HumanNode, ApprovalGate}` — *"composable agent
topologies … Workflow (deterministic FSM) and Orchestrator (LLM-driven ReAct loop) … HITL gates
and durable checkpoint/resume are first-class"* (its moduledoc). It is **unused in-tree** (no
`Jido.Composer` reference anywhere in `lib/`), because jido_radclaw already standardized its
execution substrate on **Reactor** (Squidie) and its human gates on the **AR-1 gate DSL** — both
with the shipped durable envelope. Adopting `Jido.Composer.Workflow` for waves would stand up a
*fourth* orchestration surface (alongside Reactor, the static reasoning pipelines, and the agent
loop) with its own competing checkpoint/resume/HITL.

The composer's novelty is the **deterministic signal-driven router** (§3) — which neither
`Jido.Composer.Workflow` (a static FSM with declared transitions, not signal-composed) nor
`Orchestrator` (an LLM loop, not deterministic) provides. So we **reuse Reactor to execute
waves and add the router on top**, and we name the new code `JidoClaw.RouteComposer` (struct
`JidoClaw.RouteComposer.Stage`, GenServer `JidoClaw.RouteComposer`) to avoid the namespace and
conceptual collision with the dependency.

## §2 — The model: two graphs over one catalog

Every composable unit ("stage") carries two independent graphs (Alp River
`doctrine/CATALOG.md`):

- **Data graph** — `input` / `output` artifacts. The **precedence DAG** (a producer is
  ordered before its consumer). `input.required` is **AND** (a stage needs *all* of them; a
  missing one drops the stage). *"The one rule never bent."* The DAG is **acyclic** — a catalog
  whose producer→consumer graph has a cycle is rejected at load (§3.2 step 5), never composed into a
  runnable wave.
- **Signal graph** — `subscribes` / `publishes` topics. **Membership**, pub/sub. `subscribes`
  is **OR** (any live subscribed signal triggers the stage). `publishes` is **never read by
  the router** — route growth happens only when the loop folds *actually-emitted* signals into
  the live set between waves (no optimistic expansion through declared `publishes`).

Two namespaces, never conflated: **signals** live in `live` (a topic set); **artifacts** live in a
separate durable **provenance-keyed artifact store** (`name → producer → value/ref`, their values
for execution — §4/§7), and the routing name-set `available` §3 reads is **derived** from it: a
`name` is available iff the store holds **≥1 non-tombstoned producer entry** for it (so invalidating
one producer of a co-produced `name` — AR-3's per-lens `findings` — never strips the `name` while
another producer still has it, §6/§7). A signal sitting in `available` does not release a lock, and
vice versa (Alp River tests 93 & 128). Atop these two graphs sits a third gate — **locks** (§9).

### Catalog stage — the contract

A stage is **metadata over an existing executable unit** (a worker template or a skill), *not*
a new executor:

```elixir
%JidoClaw.RouteComposer.Stage{
  name: "security-reviewer",                  # string key
  unit: {:worker_template, "reviewer"},       # template NAME — AgentRunner.run/4 → Templates.get;
                                              #   or {:skill, "review"}, or {:gate, "plan"} → named reactor (§9). NOT a module (see note).
  task: "Review the diff for auth-surface, secrets, and permission changes; " <>
          "flag findings, else emit clean:security.",  # the stage-specific instruction
                                              #   (§5) — makes security-reviewer ≠ quality-reviewer
                                              #   off ONE generic `reviewer` template; not a router input
  routes: ["code", "sketch"],                 # validated subset of ["talk","sketch","code","system"]; MANDATORY
  input:  %{required: ["diff"], optional: ["reuse-map"]},
  output: ["findings"],
  subscribes: ["auth-surface", "secrets", "perms-change"],
  publishes:  ["findings:security", "clean:security", "scope-shift"],  # NOT read by compose_route; the emission contract (§7)
  emit: :default,                             # typed worker output → %StageEmission{} (§7); optional —
                                              #   :default maps `output` + the worker verdict (overall/findings →
                                              #   clean:<lens> | findings:<lens>, §7) to artifacts + signals; or
                                              #   {:mapper, "security_findings"} names a registered mapper
  lock: [%{while: "needs-tests", until: "tests-ready"}],  # optional (§9); a router hold — NEVER executes
  guard: :sticky,                             # optional; only merge_sticky reads it
  lens:  "security",                          # optional; the review-lens identity (§4 convergence / §7 verdict),
                                              #   NOT a router input. Present on a review-lens stage so the emit
                                              #   mapper forms clean:<lens>/findings:<lens> AND the loop enumerates
                                              #   "every review lens in `ran`" by an explicit field, not by parsing
                                              #   stage names or reverse-parsing signal suffixes
  model: :opus, effort: :high                 # spawn-time tiering override (§12); not a router input
}
```

**`unit` is a template name, not a module.** The reusable runner `AgentRunner.run/4`
(`skills/steps/agent_runner.ex:50-53`) takes a `template_name` string and resolves it through
`Templates.get/1` against the string-keyed registry (`agent/templates.ex:43` — `"coder"`,
`"reviewer"`, …). So a worker stage is `{:worker_template, "reviewer"}`; routing a bare module
would need a new wrapper and is avoided.

**`task` is the stage's instruction — the execution input `compose_route` never reads.**
`AgentRunner.run/4` takes `(template_name, task, step_name, context)` with `task` **required**
(`agent_runner.ex:52`), and `Skills.Compiler` already sources it per step (`task: Map.get(step,
:task)`, `compiler.ex:429`). It is what makes `security-reviewer` and `quality-reviewer` — both
`{:worker_template, "reviewer"}` over the *one* generic `reviewer` template (`templates.ex:54`,
statically `model: :fast`) — meaningfully distinct: the **lens instruction**, not the template,
carries the difference. The composer threads `stage.task` plus the formatted artifact
`:extra_context` (§5) into the step; the per-lens verdict the convergence test reads (§4) is the
`emit` mapper's derivation over that lens's typed output (§7). A `{:skill, name}` unit needs no
`task` (the skill carries its own steps); its runner seam is §5.

**Atom-safety note (greenfield, but the discipline holds).** Stage names, **route paths**,
signal topics, and artifact names **all stay strings** — never `String.to_atom/1` on
catalog-or-YAML-sourced values. (This is why §3.2's route-filter intersects string sets, not
atom sets — a `"code"` live topic must match a `"code"` route.) The only atoms in the hot path
are the fixed `@step_ids` pool the compiler already uses (`skills/compiler.ex`) and the closed
`guard`/`model`/`effort` enums.

## §3 — `compose_route/4`: the pure function (the crown jewel)

A faithful Elixir port of Alp River `hooks/route.py:155-187`. **Pure, deterministic, zero
I/O** — same `(catalog, live, available, ran)` ⇒ same result. This is the entire decision layer;
everything else (§4) is plumbing around it.

### §3.1 — Signature & return shape

```elixir
@type result :: %{
        route:        [String.t()],            # topo-sorted stage names (flatten(waves) == route)
        waves:        [[String.t()]],          # Kahn levels — each a parallel cohort
        size:         String.t(),              # label: "empty"|XS|S|M|L|XL|XXL (NOT a count)
        triggered_by: %{String.t() => String.t()},  # in-route stage -> the live signal that triggered it
        dropped:      %{String.t() => :off_path | :unsatisfiable_input},
        held:         %{String.t() => [String.t()]}  # held stage -> list of unmet `until` signals
      }

@spec compose_route(catalog :: map, live :: MapSet.t(), available :: MapSet.t(), ran :: MapSet.t()) :: result
```

**Invariants the test port must lock down**: `route` and `held` keys are **disjoint** (held
stages are removed before topo-sort); `held` is **always present** (`%{}` when nothing locked)
and its values are **lists of `until` names** (never a `"deadlock"` sentinel);
**`flatten(waves) == route`**; identical input ⇒ identical result (frontiers alpha-sorted);
`triggered_by` is keyed **only** on in-route stages.

### §3.2 — The five steps (execution order; `route.py` line refs)

1. **Trigger** (`_trigger`, `:110-120`). For each stage **not in `ran`**, find the first
   `subscribes` topic that matches `live` (OR-membership, declaration order, family-prefix
   aware via `matches?/2`). Record `{stage => matching_signal}` → `triggered_by`.
2. **Route-filter** (`_on_live_path`, `:123-132`). `live_paths = MapSet.intersection(live,
   MapSet.new(["talk","sketch","code","system"]))`. If empty (pre-triage seed) → no-op, keep
   all. Else keep a triggered stage iff its `routes` (**path strings**) intersect `live_paths`.
   Dropped here ⇒ `:off_path`. *(Strings on both sides — an atom `routes` would never match a
   string `live` topic.)*
3. **Drop-unsatisfiable** (`_drop_unsatisfiable`, `:135-152`). **Fixed-point loop**:
   `produced = ∪ outputs of currently-kept stages`; drop any kept stage with a `required` input
   not in `available` and not in `produced`; repeat until no drops (removing a stage removes its
   outputs → cascade). **Optional inputs are never consulted here.**
4. **Locks → held** (`_active_locks`, `:101-107`; held `:163-171`). A lock entry is **active
   (held)** iff `matches?(while, live)` **and** `not matches?(until, live)` — reading `live`
   **only, never `available`**. A stage is **held if *any* of its lock entries is active, and
   runnable only when *every* active entry has released** (this is what Alp River calls "locks
   AND together"). Remove held stages from the runnable set, then **re-run drop-unsatisfiable**
   over the remainder (a held producer's consumers drop as unsatisfiable). `held[stage] =
   [until of each still-active entry]`.
5. **Topo-sort** (`_toposort`, `:55-91`). Kahn by levels over the runnable set. Edges from
   `required + optional` inputs, but **only when the producer is in-route** (absent optional
   producer ⇒ no edge, never a drop; present ⇒ an ordering edge even if the artifact isn't in
   `available`). Each frontier alpha-sorted (determinism); each frontier *is* a wave. **Cycles are a
   catalog-load error, not a runtime trailing wave.** `route.py`'s guard appends leftovers
   (`names - seen`) as a trailing wave under the comment *"(data graph is acyclic)"* — harmless in a
   router that only *advises* an LLM, but for a composer that **executes** the wave that trailing
   cohort would be runnable with `required` inputs no earlier wave produced — "the one rule never
   bent" (§2), violated. The precedence DAG is *static* catalog metadata (input/output names), so a
   cycle is detected once, at **catalog-load**: a catalog whose full producer→consumer graph has a
   cycle is **rejected** there, and no cyclic set can reach the router. The Kahn
   `len(seen) < len(names)` guard is retained only as a defensive **route error** (surfaced, parent
   `:failed`) — never a silently-runnable wave.

`dropped` (`:174-179`): a triggered stage absent from the route is `:off_path` (step 2) or
`:unsatisfiable_input`; a held stage is in `held`, **never** `dropped`.

```elixir
# family-prefix match — backs BOTH trigger and lock matching (route.py:94-98).
# One-directional: a base subscription matches a qualified live topic, but NOT vice versa.
defp matches?(sub, live) do
  Enum.any?(live, fn topic -> topic == sub or String.starts_with?(topic, sub <> ":") end)
end
```

`size_label/1` (`:37-43`): `0 → "empty"`, `1 → "XS"`, `2-3 → "S"`, `4-6 → "M"`, `7-10 → "L"`,
`11-15 → "XL"`, `16+ → "XXL"`.

### §3.3 — `merge_sticky/3` (separate post-pass, `route.py:190-207`)

Not part of `compose_route`. Called after, with the previous turn's route names: a
`guard: :sticky` stage that ran on a prior turn stays in the route even after its triggering
signal goes quiet (asymmetric safety). Re-toposorts `route ∪ kept`, adds a `sticky_kept` key;
does not recompute `triggered_by` / `dropped` / `held`.

**This is a *display*-route operation, and the loop must treat it as one.** Because `compose_route`'s
trigger step skips every stage in `ran` (§3.2 step 1), its own `route`/`waves` never contain an
already-run stage — but `merge_sticky` deliberately re-adds sticky stages that *did* run on a prior
turn. So the merged `route` is the **display/persistence** route (what the next turn carries as
`prev_route`, what the UX renders), **not** a dispatch list: the loop derives the runnable cohort by
filtering each merged wave to `stage not in ran` before it executes or tests convergence (§4). This
is exactly the source's *"run the next **not-yet-run** stage in route order"* (Alp River
`WORKFLOW.md` `## Pipeline` step 3) — folding `merge_sticky` straight into `hd(waves)` would re-run a
sticky stage and never converge.

### §3.4 — Test port

Port Alp River's `hooks/tests/test_route.py` (**~130 cases**) 1:1 to ExUnit — the acceptance
spec for §3. Buckets: core routing, wave scheduling, lock/held (TC-U01..U21), family-prefix, and
a representative **fixture catalog** for the gate/TDD/plan-approval edge cases (GAP-1..4 are the
highest-value). CLI-boundary tests port to the loop's input-validation seam (§4), not the pure
function.

## §4 — The composer loop

A `JidoClaw.RouteComposer` GenServer (per run) owns **`live`** (signal topics, seeded
`request-received`), **`artifacts`** (the durable **provenance-keyed** artifact store —
`name → %{producer_stage => value/ref}`, seeded with the `request` artifact, so co-producers like
AR-3's per-lens `findings` don't clobber, §7), **`ran`** (executed stage names — *mutable*, see
invalidation below), and **`premises`** (assumptions the route was built on). The routing name-set
**`available`** §3 reads is **derived** from `artifacts` each turn (a `name` iff ≥1 non-tombstoned
producer entry, §2/§7), not owned independently. It runs the Alp River pipeline
(`WORKFLOW.md` `## Pipeline`): **route → run the next wave → fold results → recompose →
converge.**

```
seed live (request-received) / artifacts (request) / ran (∅)
loop:
  available = names_with_active_producer(artifacts)            # DERIVED: a name iff ≥1 non-tombstoned producer (§2/§7)
  result    = compose_route(catalog, live, available, ran)     # §3 — pure; route/waves never hold a `ran` stage (trigger skips `ran`)
  display   = merge_sticky(catalog, prev_route, result)        # §3.3 — re-adds already-run sticky stages: the DISPLAY route
  dispatch  = [w -- ran  for w in display.waves  if w -- ran != []]  # each wave minus `ran`: the runnable cohorts
  if dispatch == []:                                           # nothing UNRUN to run (NOT display.route == [] — sticky leftovers keep that non-empty)
    if display.held == %{} and lenses_clean?:  HALT — converged
    else:  BLOCKED — `held` waits on an `until` signal (§9); record wave_paused, parent stays
           :running, suspend until a releasing signal lands, then recompose. (A held set no stage
           can ever release => deadlock, surfaced — not a busy-wait.)
  wave    = hd(dispatch)                                       # first wave with an unrun member, filtered to not-in-`ran`
  outcome = run_wave(wave, artifacts)                          # §5 — wave reactor; a gated wave (§9) may park → suspend until GateResume, then recompose
  {live, artifacts, ran, premises} = fold(outcome)             # §7 — typed StageEmission; `available` is DERIVED from the store, not folded
  prev_route = display.route                                   # the merged DISPLAY route — sticky persists across turns
```

- **One `compose_route` call per turn is the recompose.** Growth is driven by `fold/1` adding
  emitted signals/artifacts to `live`/`artifacts` (and so to the derived `available`) and the next
  `compose_route` seeing them.
- **Dispatch route vs display route.** `compose_route`'s own `route` never holds a `ran` stage
  (trigger skips `ran`, §3.2 step 1), but `merge_sticky` (§3.3) re-adds already-run sticky stages —
  so the merged result is the **display** route (rendered, and carried forward as `prev_route`),
  while the **dispatch** cohort is each merged wave filtered to `stage not in ran`. Both the
  execution step and the convergence test key on the *dispatch* set, never the raw merged `route`:
  testing `route == []` would never fire (a sticky leftover keeps it non-empty → no convergence) and
  `hd(waves)` would re-run that leftover. This is the source's *"run the next not-yet-run stage in
  route order"* (`WORKFLOW.md` `## Pipeline`), mechanized for the wave model.
- **`ran` is mutable — explicit invalidation for reruns.** Because trigger (§3.2 step 1) skips
  any stage in `ran`, a once-run lens would never re-trigger. AR-4 self-heal (§12) and the
  system-verifier reverse-loop need reruns, so the loop **removes the to-rerun stages from
  `ran`** on the triggering event — exactly Alp River's *"drop the stage from `already_run`"*
  primitive (`WORKFLOW.md` `## Convergence`). The rerun set is the fixer's RE_RUN_SET (§12) or
  the verifier's own re-fire. **Each such removal is a durable subtractive event** —
  `stages_invalidated` (§6) — so the composer-state fold replays the *net* `ran` and a crash never
  resurrects a stale completion that should have re-fired. *(Decision in §15: explicit invalidation
  vs a `{stage, generation}` run-identity key; explicit invalidation matches the source and is
  recommended.)*
- **Convergence**: empty **dispatch set** (no unrun stage to run — *not* `route == []`, which a
  sticky leftover keeps non-empty; the dispatch-vs-display split above) **and** empty `held` **and**
  every **review-lens stage** in `ran` has emitted its **`clean:<lens>`** verdict (equivalently: no
  open `findings:<lens>` for any lens that ran). A review-lens stage is one carrying an explicit
  **`lens` field** (§2) — that field, not the stage name or a reverse-parse of the signal suffix, is
  what the loop enumerates as "the lenses that ran" and what the `emit` mapper binds to form
  `clean:<lens>` / `findings:<lens>`. A *global* `clean` topic can't carry "security clean,
  correctness still flagged," so the verdict is **per-lens** — the family the `emit` mapper derives
  from the reviewer's `overall`/`findings` (§7/§12), not a `clean` boolean the reviewer doesn't have. A non-empty `held`
  is *never* convergence — it is the **blocked** state: the route
  waits on a lock's `until` signal (§9). **Locks never execute**; the composer records the block
  (`wave_paused`, parent `:running`, §6), suspends, and recomposes when a **gate-producer** (§9)
  or other stage emits the `until` — or, on a gate **reject** or **abandon**, the held route drops
  and the parent goes terminal (§9). A `held` set no
  stage can ever release is a **deadlock**, surfaced (not a busy-wait). Two further bounds keep the
  loop spending only while it progresses. **Oscillation**: a `scope-shift` (or any signal) that
  re-fires without resolving is surfaced, not retried. **A spend ceiling**: deadlock + exact-
  oscillation detection alone do *not* bound an LLM rerun loop — a fixer↔reviewer cycle (§12 AR-4) can
  emit *distinct* findings or diffs each turn and never exactly oscillate — so the composer carries a
  deterministic budget in run config: a **`max_waves`** cap, a **per-stage rerun cap** (how many times
  one lens may be dropped from `ran` and re-fired, §4), and an optional **composer deadline** (the
  whole-run analog of `ReactorRunner`'s per-wave `:deadline`). Hitting any bound takes the parent
  terminal as **`:failed`** via a `route_budget_exhausted` composer event (§6) that carries the bound
  it hit in the run's `error` attribute — a protective resource-limit stop, *not* an operator
  `:cancelled` + disposition (that pair is reject/abandon, §9) — rather than looping on the operator's
  spend.
- **Stale-approval retraction** (§9): a `live`-set removal of `plan-approved` on a
  pre-implementation re-plan, so the revised plan re-earns it — durably a `signals_retracted` event
  (§6), so recovery's fold doesn't fold the stale `plan-approved` straight back into `live`.
- **Lifecycle — one GenServer per parent run, supervised and registered.** Each `RouteComposer`
  starts under a `DynamicSupervisor` and registers in a `:unique` `Registry` keyed by
  **`parent_run_id`**, in the orchestration child group that already boots
  `JidoClaw.Orchestration.RunRegistry` + `RunTaskSupervisor` (`application.ex:153-154`). That key is
  what lets boot recovery (§6) and dead-node reclaim (§10.1) **find-or-start** the owner for a run,
  what the lease renews against, and what enforces a **single live owner per route** (a second start
  for the same `parent_run_id` is an observe, not a fork). A `transient` restart lets a crashed
  composer rebuild from the durable log (§6) rather than vanish; a `:normal` exit on a terminal does
  not restart.

## §5 — Per-wave execution on Reactor (reuse + one new opt)

Each wave is **a `%Reactor{}` built as `Skills.Compiler` builds a skill** and handed to the
shipped front door:

- Build via `Reactor.Builder` — `Builder.new` → `add_input(:extra_context)` → one
  `Builder.add_step/5` per stage (`async?: true`, `max_retries:` from the catalog — **except a
  skill-stage wrapper, which forces `max_retries: 0`**, §5) → a terminal
  collect step. This is `Skills.Compiler.build_graph/3` with the stage list supplied by the
  composer; factor a small `build_wave/2` if the existing path can't be reused verbatim. **The
  per-wave terminal collect (a new `WaveCollect`) holds the typed `%StepResult{}` list in memory
  to run the stages' `emit` mappers** — *not* `Skills.Result.build/3`, which collapses results to
  text (`skills/result.ex:36`) and would discard the typed output those mappers read (§7). Its
  **durable terminal return (Phase 2 on), though, is a JSON-safe **map** wrapping the per-stage
  emissions — `%{"emissions" => [<StageEmission map>, …], "wave_index" => n}`, each emission a
  `signals` list + artifact *refs* — never the `%StepResult{}`/`%StageEmission{}` struct, never inline
  values, **and never a bare list.** The outer map is mandatory, not cosmetic: this return lands in
  `WorkflowRun.result`, an Ash `:map` attribute (`workflow_run.ex:245`) the projection casts
  `payload.result` into (`projection.ex:145`), and `Ash.Type.Map.cast_input/2` **rejects a bare
  list** (`[%{…}]` → `{:error, "is invalid"}`), so a list-shaped return would never persist. (The
  struct/inline-value exclusions are the separate `json_safe?/1` constraint:
  `ReactorMiddleware.complete/2` collapses any struct/tuple to `%{}`, `reactor_middleware.ex:209,470`.)
  That JSON-safe terminal output is what makes a finished wave
  durably self-describing, so the fold (§7) is replayable from it after a crash (§6).
- A stage's `unit` selects an existing step impl: `{:worker_template, name}` →
  `Skills.Steps.AgentStep` / `AgentRunner` (fed `stage.task` + the formatted artifact
  `:extra_context`, §2); a fixer/iterate stage → `Skills.Steps.IterativeStep` (the AR-4 substrate,
  §12); a `{:gate, name}` gate-producer → the named `Reactors.*` module (§9). A `{:skill, name}` unit
  **runs the named skill as its own nested child run via `ReactorRunner` + `parent_run_id`** — a true
  **grandchild**: its `parent_run_id` FK is **the wave child run id** (read from the step's
  `context.workflow_run`, `reactor_runner.ex:281`), *not* the composer parent, so a skill run nests
  under its wave rather than flattening into a sibling of it. Its `StageEmission` (§7) maps from that
  child run's durable result. **Its deterministic idempotency key is
  `composer:<composer_parent_run_id>:<wave_index>:skill:<stage_name>`** — this namespaces under the
  **composer parent** (the id the wave key uses, §6/§10.1), deliberately distinct from the wave-child
  FK above; the two "parents" are not the same run. The key makes the launch **dedup-safe**: a wave
  re-drive or recovery re-deriving it gets back `{:ok, {:existing_run, _}, _}` and folds the
  **finished** skill instead of launching a duplicate (`run_wave` status-branches as for a wave, §5).
  **It does not, though, give a *failed* skill an in-wave retry:** `run/3` reads the key **before** it
  builds or executes (`reactor_runner.ex:240`), so a wrapper-step retry under the catalog's
  `max_retries` (§5) would just get the *failed* run back, never re-run. The skill wrapper step
  therefore runs **`max_retries: 0`** — transient faults are the *skill's own* reactor saga to retry
  internally (the skill carries its own per-step `max_retries`); the wrapper adds none. **An overall
  skill failure is, by default, terminal for the route:** the failed grandchild fails the wrapper step
  → the wave child fails, and `run_wave`'s `:failed` branch surfaces it / synthesizes the parent
  terminal (→ parent `:failed`, §6). It does **not** reuse the §4 drop-from-`ran` rerun primitive —
  that re-fires a *completed* stage re-checked after a fix (AR-4), whereas a failed skill never reached
  `wave_completed`, so it was never in `ran` to drop. (**Deferred, §15.12:** a *retryable* stage
  failure — the wrapper rescues the nested failure into a failure-marked emission so the wave does
  **not** hard-fail, and the composer re-schedules the stage in a later wave under a fresh `wave_index`
  (the new run linked via the shipped `:retry_of_id`, `reactor_runner.ex:265`), bounded by the §4
  per-stage rerun cap → terminal at the cap. More resilient, but it needs that soft-failure mechanism;
  terminal-by-default is the first cut.) **Reactor's `compose` seam is *not* viable for skill stages in the
  pinned engine (reactor 1.0.2),** on two counts the runtime confirms: (1) `Skills.Compiler.compile/1`
  yields a runtime `%Reactor{}` *struct* (`compiler.ex:89`), but `Reactor.Builder.Compose.compose/5`
  has a single `when is_atom(inner_reactor)` clause (`compose.ex:56`) — only a *module* reactor
  composes, and handing it the struct raises `FunctionClauseError` (the public `Builder.compose/4`
  guard admits a struct, then the delegation fails); (2) a compiled skill terminates in `CollectStep`
  → `Skills.Result.build/3`, a JSON-safe **text** map (`results` is a joined transcript,
  `result.ex:36`), not the typed `%StepResult{}` collection an `emit` mapper reads. Embedding via
  `compose` (§15.10) becomes the alternative only once *both* a struct/module-aware compose and a
  typed-result compiler mode exist — neither does today.
- **Required inputs are injected via `:extra_context`.** Within one reactor, `AgentStep`/
  `ContextBuilder` wires upstream `StepResult`s as Reactor args — but per-wave reactors are
  *separate*, so those in-memory edges don't span waves. The composer supplies each wave's
  needed artifacts (every emission under the names its stages' `input` lists reference — across
  producers, §7) through the wave reactor's `:extra_context` input. This needs a **new artifact
  formatter/adapter**: `ContextBuilder.build_task/4` (`context_builder.ex:120`) does *not* read
  artifacts — it rejects empties and joins four pre-formatted strings, so the composer must
  serialize the selected artifacts into the `extra_context` string itself.
  (`ContextBuilder.format_artifact_context/3` is the in-reactor analog, but it folds over one
  reactor's `%StepResult{}` list keyed on YAML `consumes`/`produces` — it neither spans waves nor
  reads the composer's cross-wave store.) (§7 details the store; environmental artifacts like a working-tree `diff` may be
  reconstructed at execution rather than stored — Squidie §4.8's reconcile-from-trace idea.)
- Run via `ReactorRunner.run/3` (`orchestration/reactor_runner.ex` — accepts a `%Reactor{}`
  struct directly, injects `ReactorMiddleware`, creates the tracked `WorkflowRun`, returns
  `{:ok | :error, value, run}`), **with one new opt — `:parent_run_id`** (§6). **Ungated** waves
  run as struct reactors and get the durable envelope for free (event log, status projection,
  step events, recovery). **Gated** waves are the exception — see §9.
- **`run_wave` branches on the idempotency hit — a re-launched wave is *not* assumed fresh.** Each
  wave launches under the deterministic key `composer:<parent_run_id>:<wave_index>` (§6/§10.1), so a
  reclaim, retry, or recompose that re-derives an already-seen wave gets back
  `{:ok, {:existing_run, child_id}, child}` **with nothing executed** (`reactor_runner.ex:56-69,296`).
  `run_wave` therefore dispatches on the *existing child's status*: `:completed`
  → fold its durable emission, don't re-run (§7); `:awaiting_approval` → the gated wave is mid-pause,
  park (§9); `:running` → **(live runtime only)** observe/await, never double-drive a live executor;
  `:failed`/`:cancelled`/`:abandoned` → terminal handling (synthesize the parent terminal or surface
  the failure, §6/§9). **Recovery reuses this table for every status *except* `:running`:** at boot a
  `:running` child has *no* live executor (the BEAM that drove it died), so "observe/await" would
  wait on a corpse — recovery's `:running`-child reconciliation is in §6.

The composer is the dynamic layer; Reactor executes the bounded increments — the **same boundary
as Squidie §6**, with the deterministic composer standing where §6 puts the ReAct loop.

## §6 — Durability: the envelope-granularity decision *(the key fork)*

A multi-wave run has the *same stranding risk* the event-log envelope (T1-1) fixed for single
reactors — it must record durably and be recoverable. The question is **what the durable unit
is**.

**Recommendation: a first-class composed-route envelope = a parent `WorkflowRun` whose event
log carries composer event kinds, with each wave run as a child `WorkflowRun` linked by
`parent_run_id`.** Rationale:

- **Composer state projects from the parent's event log** — `live` / `available` / `artifacts`
  / `ran` / `premises` are reconstructable by folding composer events (with a finished child
  wave's own emission as the durable backstop for a fold a crash dropped, §7), the **status-as-
  projection** pattern Squidie §4.1 built. A rebooting/reclaiming node rebuilds state and
  **resumes mid-route** — strictly better than gust's blind re-run. (`Jido.Signal.Bus` is the
  *ephemeral* transport for observers; `WorkflowEvent` is the *durable* record — §7.)
- **Each wave reuses `ReactorRunner`** (a wave = one `Reactor.run`, the unit the front door and
  recovery already handle) — **with one addition**: a `:parent_run_id` opt.
  Ash-idiomatically this is a nullable self-relationship on `WorkflowRun` — `belongs_to :parent_run,
  WorkflowRun, allow_nil?: true, attribute_writable?: true` + `has_many :child_runs` + an index on
  `parent_run_id`. The **`allow_nil?` is mandatory**, not stylistic:
  `test/jido_claw/style/belongs_to_allow_nil_test.exs` regresses on *every* `belongs_to` under
  `lib/jido_claw/` that omits it; `attribute_writable?: true` lets the FK be set at create. The
  `:create` action must also gain **`:parent_run_id` in its `accept` list** (`workflow_run.ex:101-112`
  — absent today). **And because the FK is writable on a tenant-scoped resource** (`WorkflowRun` is
  attribute-multitenant on `tenant_id`, `workflow_run.ex:75-77`), the `:create` change must
  cross-tenant-guard it — otherwise a child run in tenant A can be created pointing at a parent in
  tenant B. The guard is the repo's established `JidoClaw.Security.CrossTenantFk.validate/2`
  (`cross_tenant_fk.ex:51`) run in a `before_action`, with spec
  `[{:parent_run_id, JidoClaw.Orchestration.WorkflowRun, JidoClaw.Orchestration}]`; `WorkflowRun`
  already exposes the policy-bypassed `by_id_global` (`workflow_run.ex:89,174`) the validator loads
  the parent through, so the self-relationship drops in with no new lookup action. (A composite
  `(tenant_id, parent_run_id) → (tenant_id, id)` database FK is the stricter DB-level alternative; the
  validator matches the in-repo precedent.) These are the schema adds the wave path needs.

**Parent launch — the composer is its own status authority.** The parent run does **not** execute
through Reactor, so `ReactorMiddleware.init/1` — which appends `run_started` and flips `:pending →
:running` (`reactor_middleware.ex:151`) — never runs for it. A parent left `:pending` reads as
"never started" and one sitting `:running` with no checkpoint reads as "stranded"; today's recovery
**fails both** (`workflow_recovery.ex:39-42`, `classify/1` `:133`). So the loop is entered through a
named launch helper (`RouteComposer.start_run/N`): it creates the parent with
**`workflow_type: "composer"`** (genesis `:pending`) and **appends `run_started` itself** — reusing
the existing status-authority kind (`next_status(:pending, :run_started) → :running`,
`projection.ex:101`), so no composer-specific start kind is needed — flipping the parent to
`:running` in the same transaction *before* the first `compose_route`. Recovery (below) classifies on
`workflow_type` **first**, so a healthy `:running` composer parent is never mistaken for a stranded
reactor run.

This requires extending two closed sets (plus the recovery consumer):

- `WorkflowEvent.kind` (`orchestration/workflow_event.ex:95-119`, currently 17 kinds) with
  composer kinds. **The set is deliberately *both* additive and subtractive** — composer state is
  rebuilt by folding the parent log (next bullet), so every state *removal* needs its own durable
  delta or the fold silently resurrects it (the retraction/rerun semantics in §4 are central, not a
  retrofit). Proposed:
  - **additive** — `route_composed` (a read-model snapshot of the composed decision —
    route/waves/held/dropped/triggered_by **+ the `premises` the route was composed under** + the
    `live` and derived-`available` inputs it ran under; `premises` lives here and rebuilds
    *latest-wins*, while the `available` copy is a legibility snapshot, **not** a durable delta —
    `available` is derived from the artifact store (§2/§7), so its only durable movement is the
    `artifacts_produced` / `artifacts_invalidated` events below, never `route_composed`),
    `wave_started` (the **durable wave-correlation record** — `wave_index` +
    stages + route/catalog hash — written to the parent log *before* the child launches, see below),
    `wave_completed` (the **fold-applied marker**, see below; also the durable record of *which*
    stages entered `ran`), **`wave_paused` / `wave_resumed`** (gate park/resume — see below),
    `signals_published`, `artifacts_produced`;
  - **subtractive** — **`signals_retracted`** (topics removed from `live` — the §4 stale-approval
    `plan-approved` retraction and any signal invalidation), **`stages_invalidated`** (stages removed
    from `ran` for rerun — the §4/AR-4 RE_RUN_SET and the system-verifier re-fire), and
    **`artifacts_invalidated`** (a producer's output tombstoned when an artifact is retracted
    *without* an immediate rerun, so its consumers re-drop as unsatisfiable). **It carries
    `{name, producer_stage}`, never a bare `name`:** the store is provenance-keyed
    (`name → producer → ref`, §7) and co-producers may share a `name` (AR-3's per-lens `findings`),
    so invalidating one lens's `findings` tombstones **only that producer's** entry — and because the
    routing set `available` is *derived* from the store (a `name` present iff ≥1 non-tombstoned
    producer entry remains, §2/§7), the `name` leaves `available` only when its **last** active
    producer is tombstoned. **Invalidation is a tombstone, not a physical delete** — the value behind the ref
    stays in the artifact store, because recovery's fold-replay re-derives a missed fold from a
    completed child result *plus* the store (below; §7) and old child results / audit views hold refs
    into it, so deleting on invalidation would strand those refs. Pruning ref targets is a separate
    retention concern, off the routing path.
    A re-fired stage gets a fresh `wave_index`, so the fold sees `wave_completed(gen-1)` →
    `stages_invalidated` → `wave_completed(gen-2)` and the *net* `ran` is correct; a retract-without-
    rerun has no later re-add, so it stays gone;
  - **parent-terminal** — `route_converged` / `route_rejected` / `route_abandoned` (§9) **and
    `route_budget_exhausted`** (§4 spend bound), *new event kinds* that **project onto the existing
    `WorkflowRun.status` closed set** — they do **not** widen the lifecycle enum (next bullet).
- `WorkflowEvent.Projection` (`next_status/2`, `status_attrs/3`, `project_status/1`) so the
  parent run's status folds from composer events **and** so composer state (live/artifacts/ran,
  with `available` derived from `artifacts`) projects for recovery — the **composer-state fold replays additive *and*
  subtractive deltas in `seq` order** (`signals_published`/`artifacts_produced` add;
  `signals_retracted`/`stages_invalidated`/`artifacts_invalidated` remove), so a rebuilt set is the
  *net*, exactly as `project_status/1` folds the status-authority kinds. The parent-terminal kinds
  map onto **existing** statuses,
  never a new `:rejected` (the `one_of` (`workflow_run.ex:214`), the `@terminal` set, and every
  terminal consumer stay unchanged — only `next_status/2`/`status_attrs/3` gain clauses): from
  `:running`, `route_converged → :completed`; **`route_rejected` and `route_abandoned` →
  `:cancelled`** carrying a `result.disposition` of `:rejected` / `:abandoned`. **These two need
  their *own* `status_attrs/3` clauses that lift `result` from the payload** — they must **not**
  delegate to the shipped `status_attrs(:run_cancelled, _payload, …)` clause, which ignores its
  payload (`projection.ex:157`) and would silently drop the disposition; the model is
  `status_attrs(:run_completed, …)` (`projection.ex:141`), which *does* lift `result`. And
  **`route_budget_exhausted → :failed`** carrying the exhausted bound in the run's `error` attribute,
  *not* a disposition — a budget stop is a protective failure, not an operator cancel (`:failed` is
  already in `@terminal`, `projection.ex:51`, so this too adds only a `next_status/2` clause, no new
  status). `:cancelled` (not
  `:abandoned`) is the honest *parent* status — `:abandoned` is defined as giving up a **parked**
  run (`projection.ex:82`), and the parent is never parked (it stays `:running` across the child
  pause, §6); the disposition preserves the reject-vs-abandon distinction in the log.
- `WorkflowRecovery` gains a parent-run branch — **dispatched by `workflow_type: "composer"`**
  (above), ahead of the shipped `(status, checkpoint)` reactor branches: rebuild state from the log
  (folding additive + subtractive deltas, so the *net* `live`/`ran`/`available` is restored),
  re-`compose_route`, resume from the next wave — never resuming a wave parked on an unresolved gate
  (§4.8 applies per wave). **The parent branch reconciles its child waves *before* it reads their
  status**, because a child wave is an ordinary reactor run and at boot a `:running` child has no
  executor — the live `:running → observe/await` branch (§5) does not apply at recovery. So each
  non-terminal child is first driven through the shipped `(status, checkpoint)` reactor branches: an
  ungated `:running` child (no checkpoint) is **stranded → `:failed`** (`workflow_recovery.ex:125,133`);
  a gated `:running` child (checkpoint + a recorded `approval_resolved`) **resumes via `GateResume`**;
  a dangling/parked gate is handled as shipped. A wave whose child ended `:failed` **never wrote
  `wave_completed`**, so its stages are absent from the rebuilt `ran`, and the re-`compose_route`
  re-derives them and dispatches them under a **fresh `wave_index`** — the prior generation's
  `:failed` child a harmless orphan told apart by `wave_index`. So a wave crashed mid-execution is
  **re-run, never awaited-on-a-corpse and never silently failed**. A wave is **durably complete at its
  own child `run_completed`** (whose JSON-safe
  emission the projection folds, §7), so a child wave that finished but whose parent
  `wave_completed` fold marker never landed (a crash in that window) is reconciled by
  **replaying the fold** from the completed child run's emission + the artifact store, matched to
  its wave by `wave_index` (the correlation contract below) — not lost.

**The wave-correlation contract.** The identity is a **`wave_index`** — the monotonic per-parent
recompose counter (one wave runs per turn, §4) the composer **precomputes before launch**, so it
needs no `child_run_id` to exist yet. (`ReactorRunner.run/3` creates the child run row and steps
straight into execution with no seam between — `reactor_runner.ex:245,292` — so the child id is
unknown until the run returns; the correlation cannot hang off it.) The composer therefore
**appends `wave_started`** to the *parent* log **before** calling `run/3` — carrying `wave_index`,
the wave's `stages`, and the `route_hash` / `catalog_hash` it was composed under — then launches
the child with that identity threaded through **the two columns the child run already persists** —
`:parent_run_id` (the one new `run/3` opt, §5) plus the deterministic **idempotency key**
`composer:<parent_run_id>:<wave_index>` (the existing `run/3` seam, set from Phase 2 for
correlation; §10.1's reclaim use is the deferred part). No `wave_index`-in-`config` and no second
opt — `run_config/4` (`reactor_runner.ex:457`) carries only `reactor`/`definition_kind`/
`project_dir`/`deadline`. For an un-folded wave (no `wave_completed` binding the child id yet)
recovery reconstructs that key from each `wave_started`'s `wave_index` and looks the child up by it
(the shipped `idempotency_key` dedupe index), joining child→wave even mid-execution. **A `wave_started`
whose key resolves to *no* child run is the pre-creation crash** — the BEAM died after the parent
appended `wave_started` but before `run/3` created the child row (`reactor_runner.ex:245`); recovery
**re-launches that wave under the same `composer:<parent>:<wave_index>` key**, which `run/3` now
materializes fresh and idempotently (had a child been created, the dedupe index would return it
instead, not double-run). Appending a parent failure is the conservative alternative; re-launch is
preferred — the wave is recoverable and the key makes it safe. On return it appends
**`wave_completed`** — the **fold-applied marker** (below), now
also binding the known `child_run_id`. `signals_published`, `artifacts_produced`, and the terminal
`route_*` events all carry the same `wave_index`. So recovery can, per wave: (a) order generations
and tell reruns apart (a re-fired stage gets a fresh `wave_index`, §4); (b) read **fold status**
from the **`wave_completed`** marker — *not* the content events: an empty-emission wave (no
signals, no artifacts, or empty lists) legitimately writes neither `signals_published` nor
`artifacts_produced`, so presence-of-content can't mean "folded"; the dedicated marker, appended in
the **one fold transaction** with the (possibly empty) content events (§7), is the authority, and a
`:completed` child with no `wave_completed` for its `wave_index` is the replay case above; (c) spot
a **terminal gate child** — one that went `:cancelled` (reject) / `:abandoned` (abandon) whose
`wave_index` carries no `route_rejected` / `route_abandoned` yet — and synthesize the parent
terminal. The idempotency key is *derived from* this identity, not its only home; a split-phase
runner (`create_wave_run` → `wave_started` → execute) is the alternative if the child id must be
durable pre-launch (§15.9).

**Parent status during a child-wave gate pause**: the *child*
wave owns the `approval_requested` event and the checkpoint. If the *parent* were set to
`:awaiting_approval` with no checkpoint of its own, today's recovery (§4.8 branch 2:
`:awaiting_approval` + no checkpoint → *fail-with-audit, dangling gate*) would mis-terminate it.
**So the parent stays `:running` across a child pause**; the wait state is surfaced through the
composer projection (`wave_paused` → projection marks the route "blocked on case X"), and
`wave_resumed` clears it. The parent goes terminal only on `route_converged` (→ `:completed`), a
**gate stop** (`route_rejected` / `route_abandoned` → `:cancelled` + disposition, §9), or failure.

**Alternative (cheaper, weaker): per-wave runs only, no parent.** Composer state lives in
GenServer memory; zero new event kinds/projection. But a crash loses composer state (resume =
blind re-run), the dashboard can't show "the route," and the lease (§10.1) has nothing to claim.
Note this drops only *composer*-state durability — each wave still runs through `ReactorRunner` and
persists its `WaveCollect` return to the child `WorkflowRun.result`, so even the spike must keep
sensitive artifact values out of that return (§14 Phase 1 / §15.3). Acceptable only as a throwaway
Phase-1 spike (§14); the first-class envelope is the Phase-2 target.

## §7 — Signals & artifacts: the emission contract

**Recommendation: the composer routes off durable state, not off the bus.** Each stage produces
a typed **`StageEmission`** captured from the worker's structured output *before* any
text-collapse:

```elixir
%JidoClaw.RouteComposer.StageEmission{
  stage:     "security-reviewer",
  signals:   ["findings:security"],              # the per-lens verdict — this lens FOUND something, so it
                                                 #   ALSO produces the `findings` artifact below; a clean lens
                                                 #   emits "clean:security" with NO findings artifact instead
                                                 #   (the two verdicts are mutually exclusive — folding one
                                                 #   retracts the other + tombstones its artifact, §7 fold).
                                                 #   Validated ⊆ stage.publishes — exact declared topics only
  artifacts: %{"findings" => <ref>}              # flat: keyed by THIS stage's output names (one producer => no clobber);
                                                 #   a store ref once durable. Inline values ONLY in the Phase-1 spike AND
                                                 #   only over non-sensitive fixtures — the wave's ReactorRunner persists this
                                                 #   into the child WorkflowRun.result either way (§14 Phase 1 / §15.3)
}
```

- **Where it comes from.** `AgentRunner` already captures typed output in `%StepResult{}`, but
  `Skills.Result`/`CollectStep` collapse it to `{label, text}` (`skills/result.ex:36`). So the
  wave's `WaveCollect` step (§5) holds the typed `%StepResult{}` list and runs each stage's
  **`emit` mapper** — the `Stage` field (§2): `:default`, or a named `{:mapper, _}`, validated at
  catalog-load, ignored by Phase 0 — to turn typed output → `signals` + `artifacts` (for a
  reviewer-shaped output, `:default` derives the **per-lens verdict**: `overall: :approve` with no
  findings → `clean:<lens>`, else `findings:<lens>`, §4/§12), persisting
  artifact *values* to the store and emitting their **refs** so its terminal return is JSON-safe
  (§5). **A `{:skill, _}` stage is the exception to that input shape:** it runs as a nested child run
  (§5), so `WaveCollect` holds no `%StepResult{}` for it — its `emit` mapper instead reads the child's
  **`WorkflowRun.result` map**, the text-collapsed `Skills.Result.build/3` shape
  (`results`/`message`/`steps_completed`, `result.ex:36`). `:default` (a reviewer-verdict derivation
  over *typed* output) therefore does **not** apply to a skill stage; it must name an explicit
  `{:mapper, _}` over that result-map shape (or carry a thin adapter step that lifts the skill result
  into the `StageEmission` shape). **Emitted signals are validated ⊆ `stage.publishes` against the
  *exact* topics it declares.** `security-reviewer` declares `["findings:security", "clean:security",
  "scope-shift"]` (§2), so it may emit those three and **nothing else**. There is **no global family
  blessing**: `findings:<lens>` / `clean:<lens>` / `risk:<area>` name the controlled *vocabulary* (how
  topics are formed), **not** a wildcard a stage inherits — blessing the family globally would let a
  buggy security-stage mapper emit `clean:quality` and pass, the exact publisher-coherence violation
  the check exists to catch. A stage *parameterized* by lens binds its lens locally — its `lens`
  field (§2) — and validates `findings:<its-bound-lens>` against that binding; it never gets a free
  pass on the open family.
  (`scope-shift` is not an exception either — it is **mandatory in every stage's `publishes`**, so it
  is already an exact declared topic that any stage *may* raise but none *must* emit.) Emissions are
  *code*-produced (an `emit` mapper or a gate-producer), so an undeclared signal is a **mapper/catalog
  invariant violation, not noise** — and silently dropping one is unsafe: a dropped `findings:security`
  (or `plan-rejected`, `scope-shift`) would let the route **converge as clean when it is not** (§4
  reads the *absence* of an open `findings:<lens>` as convergence). So coherence is enforced at two
  points, the strict form of Alp River's `check_catalog` publisher check: **(load time)** a catalog
  whose `emit` mapper can produce a signal outside the stage's declared `publishes` is **rejected**
  when the catalog loads (§2); **(runtime)** an emission that still reaches an undeclared topic **fails
  the wave** — a loud, surfaced error — never a quiet drop.
- **The fold** (`fold/1`, §4) merges every wave-emission's `signals` into `live` and indexes its
  `artifacts` into the **provenance-keyed artifact store** as `store[name][stage] = ref` (so two
  lenses both emitting `findings` (AR-3) coexist without clobbering; the *values* those refs point at
  were persisted by `WaveCollect`, resolved back for the next wave's `:extra_context`, §5). The
  routing set **`available` is *derived* from the store** — a `name` present iff it has ≥1
  non-tombstoned producer entry (§2) — so adding the emission's `artifacts` to the store *is* the
  `available` update, and an `artifacts_invalidated {name, producer}` (§6) drops a `name` from
  routing only when it tombstones that name's last active producer. It records
  `ran`, and in **one transaction** persists the `wave_completed` **fold-applied marker** plus the
  turn's content events — additive `signals_published` / `artifacts_produced` **and** any subtractive
  `signals_retracted` / `stages_invalidated` / `artifacts_invalidated` that turn's recompose implies
  (§6) — the marker, not the content events, is what recovery reads as "folded," so an empty emission
  (no signals/artifacts, no deltas) is still unambiguously folded. Synchronous, deterministic, no async race — and it gives the write-only
  reasoning signals their first real consumer.
- **Paired verdicts are last-writer-wins per lens, not additive.** `clean:<lens>` and
  `findings:<lens>` are **mutually exclusive** in `live` (§4 convergence reads `clean:<lens>` **and**
  the *absence* of an open `findings:<lens>`), so the fold does **not** simply union a verdict:
  folding `clean:<lens>` **retracts** any live `findings:<lens>` for that lens (durably a
  `signals_retracted`, §6) **and tombstones** that lens's now-stale `findings` artifact
  (`artifacts_invalidated`, routing index only, §6); folding a later `findings:<lens>` retracts a live
  `clean:<lens>`. Without this, a re-run lens that turned clean would leave its old `findings:<lens>`
  in `live` and the route would **never converge**. No new machinery — the fold *applies* the
  existing subtractive deltas (§4/§6) for the verdict family.
- **In-memory vs durable.** The `%StepResult{}` and `%StageEmission{}` *structs* are in-memory
  mapper I/O only — neither survives `json_safe?/1` (`reactor_middleware.ex:470` rejects every
  struct). The durable form of an emission is its **JSON-safe map**: `signals` (strings) +
  artifact **refs** (never inline values, §15.3), written in two places that must agree — the
  wave's `WaveCollect` terminal return (→ the child run's `run_completed` payload and
  `WorkflowRun.result`, §5) **and** the parent's `wave_completed` fold marker + `signals_published`
  / `artifacts_produced` content events (§6, one transaction). Because a finished child wave already
  carries its emission durably, the fold is **replayable**: a crash after the child `run_completed`
  lands but before the parent's `wave_completed` is written loses nothing — recovery re-derives the
  fold from the child result + the artifact store (§6). Artifact *values* live only in the ref-addressable store (encrypted/ref,
  §15.3), never in an event payload or result column. A live wave return is atom-keyed while a
  JSONB-round-tripped persisted map comes back **string-keyed**, so a **`StageEmission.from_map/1`**
  normalizes both into one shape before the fold reads it — the same atom/string tolerance
  `WorkflowEvent.Projection` already applies (`payload[:result] || payload["result"]`,
  `projection.ex:19`).
- **`Jido.Signal.Bus`** (`core/signal_bus.ex`) stays the *ephemeral* transport: the composer
  *publishes* `route_composed`/`wave_*` to it for live UX, but never *consumes* the bus to make
  a routing decision.

The controlled vocabulary (Alp River `doctrine/SIGNALS.md` — families `findings:<lens>` and its
paired verdict `clean:<lens>` (§4 convergence), `risk:<area>`, `domain:<x>`, lifecycle, and
`scope-shift`, mandatory in every stage's `publishes` declaration — not in every emission) is the
*naming scheme*: a stage's `publishes` lists **exact topics** drawn from it (e.g. `findings:security`),
and emission validation is against those exact topics, never the open family (above). It ships with
the catalog (§2), validated at catalog-load time.

## §8 — The seed: conversation-type triage (AR-8)

An always-on **triage** seed publishes exactly **one path** per turn — `talk` (answer inline) /
`sketch` (throwaway) / `code` (a reviewed change) / `system` (a verified machine change) — plus
early signals and one advisory `est-size`. Sticky but re-evaluated every turn (`talk` → `code`
on "do it").

This is **AR-8**, folded in here as the composer's seed stage. The cheap standalone version is a
`Classifier` upgrade (it picks a reasoning *algorithm*, not a conversation *type*); the full
version is the seed `Stage` whose output is the path signal the route-filter (§3.2 step 2) keys
on. **`talk` never enters the composer** (stays inline); `code`/`system` seed `live` and enter
the loop. It is the front door that decides *whether to compose at all* — and why the composer is
additive to the static reasoning layer (§12), not a replacement.

## §9 — Human gates in the composer (AR-1 reuse) *(locks hold; gate-producers run)*

A lock (§3.2 step 4) is a **router-level hold, not an executable step — locks never run.** A
`%{while: "plan-pending", until: "plan-approved"}` entry removes its consumer from the runnable
route (held if *any* entry is active, runnable when *all* active entries release) and waits for
the `until` signal to land in `live`. What *produces* that `until` is a separate stage — for a
human approval, a **gate-producer**, which is where AR-1 plugs in: `Cases.abandon` makes
`abandon` run-terminal and `Cases.retract` (`approval_retracted`) is the §4 stale-approval
retraction. The decision-kind taxonomy is single-sourced in `Gate.Kinds`
(`:tool_call | :plan | :irreversible_write`); the composer's plan-approval and safety
gate-producers map onto `:plan` and `:irreversible_write`.

**The constraint that forces the shape — a gated wave cannot be a dynamic struct.** The shipped
gate path checkpoints the reactor by **module name** and fences resume to it: a struct reactor
"never halts (no `GateStep`) … gated-struct support … is a separate future item"
(`reactor_runner.ex:28-36`); `safe_encode_checkpoint` does `Keyword.fetch!(opts,
:reactor_module)` (`:638`); and `GateResume` only re-materializes modules under
`@allowed_module_prefix "Elixir.JidoClaw.Orchestration.Reactors."` (`gate_resume.ex:84`). A
dynamically-built `%Reactor{}` wave with a `GateStep` would halt but **could not be resumed**.

**Recommendation: gate-producers are pre-defined named reactor modules.** Implement the small
fixed set (plan-approval, safety) as modules under `JidoClaw.Orchestration.Reactors.*` (e.g.
`Reactors.PlanGate`, `Reactors.SafetyGate`), referenced from a stage's `unit` as `{:gate, "plan"}`
(§2). **The gate-producer — not the held lock — runs as a wave.** It is an ordinary runnable route
member (triggered by, e.g., `plan-ready`; never itself held); `ReactorRunner.run/3` resolves the
module → struct, the checkpoint carries the `reactor_module`, and resume satisfies the existing
fence. Ungated work stays dynamic struct waves (§5); only the gate-producer needs a named module.
*(Alternative, deferred to §15: extend the checkpoint identity so a dynamic wave struct is
rebuildable on resume — e.g. key on `{parent_run_id, wave_index, catalog_hash}` → `build_wave`.
More general, but it reworks the gate-resume fence; not first-cut.)*

**The gate-producer's internal contract — `GateStep` halts; a downstream step emits.** A named gate
reactor is **`GateStep` plus a downstream emit/return step**, because `GateStep` alone emits nothing
routable: it returns `{:halt, agent_case_id}` (`gate_step.ex:66`) and, on approval, `GateResume`
injects the decision as **`context[:approval]`** (`gate_resume.ex:157`) — it produces no signal or
artifact itself. So `Reactors.PlanGate` orders, **after** the `GateStep` (via `wait_for`, per
`gate_step.ex`'s own moduledoc), a terminal step that **reads `context[:approval]`**, writes the
`approved-plan` **artifact ref** to the store, and **returns the `StageEmission` map**
(`signals: ["plan-approved"]` + `artifacts: %{"approved-plan" => <ref>}`, the JSON-safe shape §7's
fold reads). That downstream step is what makes step 4's "the gate-producer's `%StageEmission{}`
carries `plan-approved`" *true*: omit it and the reactor still resumes cleanly but emits nothing —
the held implementer's `until: plan-approved` never lands and the parent strands in **blocked**. The
emit step must be **idempotent** (a crash mid-resume re-runs the durable downstream steps —
`gate_step.ex` Decision 7 caveat). On **reject** the reactor is cancelled *before* that downstream
step runs (no emission — Decision 9), which is exactly why the composer synthesizes `plan-rejected`
itself (step 5) rather than reading it from the child.

The flow then maps cleanly onto the shipped path and the §4 **blocked** branch:

1. The plan is ready; the route holds the implementer (`until: plan-approved`) and runs the
   **gate-producer** wave (`Reactors.PlanGate`).
2. Its `GateStep` opens an `AgentCase`; the child wave run parks at `:awaiting_approval` (the
   parent stays `:running`, §6). The composer records `wave_paused` and suspends — the §4 blocked
   state, **not** convergence and **not** a crash.
3. The operator decides via the existing surfaces (`/gates`, `/approvals`, `Cases.decide/4`).
4. **On approval**, `GateResume` re-runs the gate reactor with the decision injected through
   context; the gate-producer's **downstream emit step** (the contract above) reads that
   `context[:approval]` and returns a `%StageEmission{}` carrying `signals: ["plan-approved"]`. **The
   composer folds `plan-approved` from the gate child's `run_completed` emission — never from the
   gate-resolution broadcast.** `Cases.decide/4` broadcasts *before* it resumes: `broadcast_resolved`
   (`cases.ex:281`) then `finalize_approve → GateResume.resume` (`cases.ex:284,569`), so the gate
   child is still `:running` when the broadcast lands and its `plan-approved` emission does not exist
   yet — folding on the broadcast would release the held implementer against an unwritten approval.
   So the composer keys on the gate child's **`:completed`** status (the §5 status-branch — `:running`
   → observe/await, `:completed` → fold its durable emission) and reads the emitted result; only then
   does the next `compose_route` release the held implementer, and it runs. (Reject/abandon are the
   opposite case — steps 5–6: `Cases.reject`/`abandon` take the child **terminal before** broadcasting
   (`cases.ex:291-298`), so observing that broadcast and reading the already-terminal child is correct.)
5. **On rejection**, `Cases.reject` takes the *child* gate wave to `:cancelled` and does **not**
   resume — no resume, no upstream undo (`cases.ex:28-36`, Decision 9). That child carries no
   `%StageEmission{}`, so the held implementer's `until: plan-approved` would never land and the
   parent would strand in **blocked** forever. The composer therefore treats a gate rejection as
   an emission of its own: it observes the decision on the same gates surface its approval resume
   already watches (durably, the child's `run_cancelled` carries the `agent_case_id` that
   distinguishes a rejection from a crash-reaped cancel), folds **`plan-rejected`** into `live`,
   and applies the **rejection effect**. The **committed default** takes the parent **terminal as
   `:cancelled` with `result.disposition: :rejected`** (the `route_rejected` composer kind records
   it, §6 — *no* new `:rejected` status), dropping the held implementer and the rest of the
   route with it; reject *prevents* the downstream work (matching `Cases.reject`'s
   no-undo/Decision-9 semantics), never left `:running`. The **re-plan** alternative is
   catalog-opt-in (§15): a planner stage that `subscribes: ["plan-rejected"]` is removed from
   `ran` (the §4 invalidation primitive) so the route re-derives a revised plan and re-gates —
   bounded by the §4 oscillation guard (a `plan-rejected` that re-fires without the plan changing
   is surfaced, not retried).
6. **On abandon**, `Cases.abandon` is the operator giving up on the *parked* gate entirely (legal
   only from `:awaiting_approval`); it takes the *child* gate wave to `:abandoned` via
   `run_abandoned` (`cases.ex:38-52`), broadcast on the same gates surface and carrying the
   `agent_case_id`. The composer observes it exactly as it does a reject, folds **`plan-abandoned`**,
   and applies the parallel effect: the parent goes **terminal as `:cancelled` with
   `result.disposition: :abandoned`** (the `route_abandoned` kind, §6), the held route dropping
   with it — `:cancelled`, not `:abandoned`, because the parent is never itself parked (§6), so
   the parked-run `:abandoned` status doesn't apply; the disposition keeps the distinction. (No
   re-plan branch — abandon is the operator walking away, not a request to revise.)

**The one AR-1 tail-end this lands: the `plan`-gate *producer*** (the `Reactors.PlanGate` above),
whose absence today keeps the automatic re-plan retraction trigger from firing — the composer is
its natural home.

## §10 — The gust borrows that hang off the composer

### §10.1 — G1-1: the lease, re-derived around the composer unit

gust's lease assumes **run = one `Reactor.run`** (`REACTOR-ADOPTION.md` §4.11). The composer
breaks that — **a composed run is a loop spanning N waves**, with state living *between* reactor
executions — so the lease unit is the **parent (composer) run**, not the wave:

- The **Pooler starts composers** (claims the parent `WorkflowRun` via `:claim_next`,
  `FOR UPDATE SKIP LOCKED`). The composer **renews the parent's lease across waves** and
  **halts on a stale fence** (`claim_token` mismatch). Columns already exist
  (`workflow_run.ex:328-341`); only behavior is new.
- **Mutual payoff.** Composer state projects from the parent's event log (§6), so a reclaiming
  node **rebuilds state and resumes mid-route**. But **wave boundaries multiply reclaim
  surface**, so the step-level **idempotency keys** §4.11 calls optional become **mandatory** —
  reuse the shipped `idempotency_key` seam on `ReactorRunner.run/3` (Squidie §4.10) per wave,
  derived `composer:<parent_run_id>:<wave_index>` **from the `wave_started` correlation id** (§6) —
  the identity lives in the durable event, not only in this key.
- **The gate/lease interaction gust never faced**: a wave parked at `:awaiting_approval` (child)
  while the parent is `:running` (§6) introduces **no second lease** — the only claim is the
  parent's, and the owning node **keeps it renewed across waves *and* across a gate pause** (the
  suspended composer GenServer is alive and heartbeating even while the loop waits on a releasing
  signal). **No release-on-park**: a human approval may take days, which a live renewal covers and
  a release-on-park would only churn — a `:running` parent with no claimant is exactly the orphan
  the lease exists to prevent. Reclaim is purely the **dead-node** path — lease expiry → another
  node reclaims, rebuilds state from the parent log (§6), and resumes mid-route, re-parking if the
  gate is still open. Lease expiry handles dead-node reclaim continuously; the boot reconciler is
  the single-node restart case.

**Deferred until clustering is real** (per §4.11) — single-node crash-correctness (boot recovery,
§6) ships first and stands alone; this section is the design the lease must satisfy so the
Phase-2 envelope doesn't foreclose it.

### §10.2 — G2-1: catalog as MCP resources + composer-aware status

The catalog is exactly what a `jido://workflows/…` resource should expose, and the MCP library
already supports resources (`Jido.MCP.Server.Resource`:
`deps/jido_mcp/lib/jido_mcp/server/resource.ex`); `core/mcp_server.ex` declares `tools:` only
today (no `jido://` URI exists yet). **One constraint shapes the URI design:**
`Runtime.register_resource/2` registers a single **exact** `module.uri()` string (`runtime.ex:17-25`)
and the behaviour exposes a fixed `uri/0` (`resource.ex:8`) — there is **no server-side
resource-template (RFC 6570) support**, so a literal `jido://workflows/<id>` *family* with a variable
segment cannot be registered as one resource. Two pieces, shipped together:

- **Catalog as a resource** — expose the whole composable surface at a single
  **`jido://workflows/catalog`** resource (a new `resources:` entry on `MCPServer` — one `Resource`
  module whose `read/2` serves the catalog as JSON), the shape that fits the exact-`uri()` constraint
  and still lets a client *discover* the catalog rather than only trigger it. Per-item
  `jido://workflows/<id>` addressing is deferred to upstream resource-template support — or a
  generated module per catalog item if discrete URIs are later needed (§15.11).
- **Composer-aware `workflow_status`** — extend the tool (`tools/workflow_status.ex` →
  `WorkflowView`) so a composer run reports **wave / held / dropped / live-signals**;
  `WorkflowView.snapshot/2` already exists for a single run (unwired) — wire it and teach it
  composer state. Keep gust's divergence: destructive controls stay **dashboard-only**.

### §10.3 — G3-2 / G3-3: catalog storage choice *(decision)*

**Recommendation: built-in catalog as a compile-time map + a `.jido/` YAML overlay** — mirror
`StrategyRegistry` (`@strategies` map) + `StrategyStore`/`PipelineStore` (YAML overlay via the
shared `YamlStore` GenServer). A thin metadata layer keyed to existing workers/skills, no DB
mirror.

- **G3-2 (debounced file-watch) — dev-only by default.** A `file_system` watcher debounces
  `.jido/composer/*.yaml` changes and drives the catalog cache's `reload/0` (the
  `Skills.reload/0` pattern, `platform/skills.ex:296-299`). **Caveat:** `file_system`
  is **not** a direct dep — it's transitive through `credo`, which is `only: [:dev, :test],
  runtime: false` (`mix.exs:137`), so it is **not guaranteed present in a prod release**. Treat
  the watcher as a **dev-time convenience** (like Phoenix's code reloader). If runtime hot-reload
  in prod is wanted, **promote `file_system` to a direct runtime dep** (§16).
- **G3-3 (disk-of-truth reconciliation) stays mooted** — file is canonical, boot re-parse *is*
  the reconciliation; no DB mirror to reconcile. (The *Ash-data-mirrored* alternative would
  un-moot G3-3 and add a reconciler — only worth it if the catalog later needs DB-queryable
  metadata. Not now.)

## §11 — Where the composer does NOT belong (scope boundary)

Squidie §6 holds: **the agent's own ReAct loop and the swarm stay out.** The composer composes
*bounded stages* (worker/skill units), each of which may *internally* invoke an LLM — but the
**composition** is a pure function, not an LLM's next-token choice. A sub-agent spawn can appear
*as a stage* (a wave fanning out workers — the AR-3 substrate); the agent's open-ended reasoning
loop does not become a composed route. Bounded-and-dynamic on the composer's side;
unbounded-and-free-form on the agent's. (And, per §1a, this is also why we don't reach for
`Jido.Composer.Orchestrator` — that *is* the LLM loop, which already lives in the agent layer.)

## §12 — First workflows on top: AR-3 / AR-4 / model tiering

- **AR-3 — reviewer fan-out + shared Reviewer Contract.** "Review `@diff`" is a single wave of N
  lens stages, all reading `diff` (injected via `:extra_context`, §5) and differentiated by their
  `stage.task` lens instruction **and `stage.lens` identity** (§2/§5) over the one generic `reviewer` template, collected into a
  fixer. Substrate exists (`Reviewer` worker + `async?: true` steps); what's missing is multiple
  lenses, the per-lens verdict, and the single-sourced contract (an AR-5 doctrine slice). **The
  reviewer's shipped schema is `overall`/`summary`/`findings`** (`reviewer.ex:19-37`), *not* a
  `clean` boolean — so the per-lens verdict is the `emit` mapper's job (§7): `overall: :approve` with
  no findings → **`clean:<lens>`**, else → **`findings:<lens>`**, which is exactly the signal
  convergence reads (§4). Risk-gated lenses (security on `auth-surface`) compose only when their
  signal is live — *the composer in action*.
- **AR-4 — self-heal fixer loop.** review wave → fixer (if findings) → re-run the touched lenses
  → converge. Maps onto `Skills.Steps.IterativeStep` plus the §4 recompose; the fixer's
  domain-touched **RE_RUN_SET** is exactly the set the loop removes from `ran` (§4) to re-trigger
  — re-checking a lens whose *domain* a fix touched even if it didn't flag the finding.
- **Per-stage model + effort tiering** (Alp River `## Model Tiering`). Catalog metadata
  (`model` opus/sonnet/haiku, `effort` medium/high/max, model-gated), not a router input — but
  **more than metadata: it needs a spawn-time override seam.** `AgentRunner.run/4` resolves the
  template and starts the subagent with **no model override** (`agent_runner.ex:52-62`), and every
  template is statically `model: :fast` (`templates.ex:43-80`), so per-stage tiering can't ride the
  template. The seam is a per-spawn `model`/`effort` override carried from the `Stage` and threaded
  through `AgentRunner` into `JidoClaw.Jido.start_subagent` (and the worker's `ask/3` run opts) — a
  small `AgentRunner` extension, named here so it isn't mistaken for free catalog metadata. The 7
  workers run uniformly at `:fast` today; a high-value refinement riding the catalog.

## §13 — Reuse map

| Composer needs | Reuse (path) | New? |
| --- | --- | --- |
| Per-wave DAG construction | `Reactor.Builder` via `Skills.Compiler.build_graph/3` | factor `build_wave/2` |
| Run a wave + envelope | `ReactorRunner.run/3` | reuse **+ `:parent_run_id` opt** |
| Worker / iterative steps | `Skills.Steps.{AgentStep,AgentRunner,IterativeStep}` (template-name units, fed `stage.task`) | reuse **+ spawn-time `model`/`effort` override** (§12) |
| Typed per-wave collection | (vs `Skills.Result` text-collapse, `result.ex:36`) | **new `WaveCollect`** (typed `%StepResult{}` in memory; durable return a JSON-safe **map** wrapping the emission list — `%{emissions, wave_index}`, never a bare list since `WorkflowRun.result` is `:map`; `json_safe?/1` drops structs) |
| Emitted signals/artifacts | `%StepResult{}` typed output | **new `StageEmission`** + the `Stage.emit` mapper field, validated ⊆ `publishes`; **`StageEmission.from_map/1`** normalizes atom-keyed live + string-keyed persisted maps (`projection.ex:19` precedent) |
| Cross-wave data passing | `:extra_context` input (vs `build_task`, which only joins strings, `context_builder.ex:120`) | **new artifact formatter** + **provenance-keyed** store (`name → producer → value`) |
| Durable log + projection | `WorkflowEvent` (`:95-119`) + `WorkflowEvent.Projection` | **extend** (additive **and subtractive** composer kinds — `signals_retracted`/`stages_invalidated`/`artifacts_invalidated`, §6) |
| Run record + status + lineage | `WorkflowRun` (status projection, claim cols) | **extend** — `belongs_to :parent_run, allow_nil?: true, attribute_writable?: true` (style test mandates `allow_nil?`) + `:parent_run_id` in the `:create` accept list (cross-tenant-guarded via `CrossTenantFk.validate/2`, §6) + index; parent launched as `workflow_type: "composer"` appending its own `run_started` (§6); child↔wave correlation rides the existing `composer:<parent>:<wave_index>` idempotency key |
| Crash recovery | `WorkflowRecovery` | **extend** (parent branch dispatched by `workflow_type: "composer"`; parent stays `:running` on child pause; **child waves reconciled before the parent reads status — a boot `:running` child is stranded, not observed (§5/§6)**; a `wave_started` with no child row re-launches under the same key; child↔wave correlation by `wave_index`; fold replay branches on the re-launched child's `{:existing_run, _}` status, §5; terminal-gate synthesis) |
| Human gates | `GateStep`/`Cases`/`Gate.Kinds` (AR-1) | reuse; **gate-producers = named `Reactors.*` modules** (§9, `unit: {:gate, _}`); locks never run; wire `plan` producer; reject/abandon fold `plan-rejected`/`plan-abandoned` → parent `:cancelled` + disposition (§9, no new status) |
| Catalog storage + hot-reload | `StrategyRegistry` + `YamlStore`; `Skills.reload/0`; `file_system` (**dev-only/promote**) | new catalog, proven pattern |
| Observe over MCP | `Jido.MCP.Server.Resource` (exact-`uri()` only — no templates); `workflow_status` + `WorkflowView.snapshot/2` | **extend** — single `jido://workflows/catalog` resource (§10.2) |
| Cluster lease | `WorkflowRun` claim columns + `:pg`/`libcluster` | deferred (§10.1) |

The pure router (§3), the `RouteComposer` GenServer (§4), the catalog (§2), and the
`StageEmission`/artifact-store/`WaveCollect` trio (§7) are the genuinely new modules; the rest
extends or reuses shipped code.

## §14 — Phased adoption path

Each phase ends **green** (`mix precommit` passes) and is independently valuable.

- **Phase 0 — Catalog + `compose_route/4` (pure, fully tested).** The `Stage` struct + built-in
  catalog map + `compose_route/4` + `merge_sticky/3` + `matches?/2` + `size_label/1`, with the
  ~130-case test port (§3.4). No execution. *Done when:* the ported suite passes, the function is
  pure, precommit green. **The crown jewel and natural first ship** — zero engine risk.
- **Phase 1 — Single-run loop (spike, per-wave runs).** The `RouteComposer` GenServer: seed →
  compose → run wave (incl. `WaveCollect` + `StageEmission` fold + artifact store) → recompose →
  converge, against a fixture catalog. In-memory **composer** state (§6 *alternative*) — **but the
  waves still run through `ReactorRunner` (§5), which is not state-free:** `ReactorMiddleware.complete/2`
  persists the `WaveCollect` terminal return into the child run's `WorkflowRun.result`
  (`reactor_middleware.ex:209-231`). A Phase-1 wave carrying **inline** artifact values (§7) would
  write them as **plaintext JSONB** before the §15.3 encryption decision lands — so Phase 1 uses
  **non-sensitive fixture artifacts only** (it already runs against a fixture catalog): no real
  `diff`/`approved-plan` secrets flow through a persisting wave until §15.3 is resolved. (A
  non-persisting runner is the alternative, but forking the front door for a spike isn't worth it.)
  *Done when:* a code-path route composes and runs end-to-end, passing fixture `diff`/`approved-plan`
  across waves; precommit green.
- **Phase 2 — Durable composer envelope.** Parent `WorkflowRun` launched as
  `workflow_type: "composer"` (appending its own `run_started`, §6) + `belongs_to :parent_run`
  (`allow_nil?: true`, accept-listed, cross-tenant-guarded §6) + composer event kinds **including the subtractive
  `signals_retracted` / `stages_invalidated`** (and the `wave_started` correlation record, §6) +
  composer-state projection (additive **and** subtractive deltas, incl. artifacts);
  `WorkflowRecovery` rebuilds (dispatching on `workflow_type`) and resumes mid-route. **Blocked by §15.3 (artifact storage/encryption):** the durable
  projection must store artifact **refs or AshCloak-encrypted values** — never plaintext
  diffs/approved-plans in `artifacts_produced` event payloads **or the `WaveCollect` terminal
  return** (which lands in the child run's `WorkflowRun.result`, §5/§7) — so resolve that decision
  first. *Done when:* a killed mid-route run resumes from the next wave on reboot (the fold
  replayed from completed child runs by `wave_index`, §6/§7), a gate decided-then-crashed before
  its parent terminal synthesizes `route_rejected` / `route_abandoned` on recovery, **a retracted
  `plan-approved` and an invalidated lens both stay gone across the rebuild (subtractive deltas
  folded, not resurrected)**, an empty-emission wave still records `wave_completed` and is not
  re-folded, sensitive artifact values never appear as plaintext JSONB, and precommit is green.
- **Phase 3 — Triage seed (AR-8).** talk/sketch/code/system front door; `talk` inline,
  `code`/`system` enter the loop. *Done when:* a `talk` turn never enters the composer and "do it"
  flips it to `code`; precommit green.
- **Phase 4 — Gates in the composer.** The named `Reactors.PlanGate`/`SafetyGate` modules (§9);
  held waves park/resume with the parent `:running`; **reject/abandon fold
  `plan-rejected`/`plan-abandoned` → parent `:cancelled` + `result.disposition`** (§9/§15.8, no new
  status), never a strand; the `plan`-gate producer + automatic stale-approval retraction. *Done
  when:* the plan gate holds the implementer wave, resume re-earns approval on re-plan, and both a
  rejection and an abandon take the parent terminal (`:cancelled` + disposition) instead of leaving
  it `:running`; precommit green.
- **Phase 5 — Observe over MCP (G2-1, §10.2).** Catalog as a single `jido://workflows/catalog`
  resource (exact-`uri()`, no templates, §10.2) + composer-aware `workflow_status`. *Done when:* a
  client can discover the catalog and read live route/wave/held state; precommit green.
- **Phase 6 — Cluster lease (G1-1, §10.1).** *Deferred until clustering is real.*

AR-3/AR-4 (§12) are the first concrete workflows and land alongside Phase 1+ as fixture catalogs.

## §15 — Open questions / decisions to make

1. **Envelope granularity (§6)** — first-class parent envelope (recommended) vs per-wave-only.
   *The* architectural decision; Phase 2 commits it — including the **additive + subtractive delta
   model** that makes the fold reconstruct the *net* `live`/`ran`/`available`, so retraction & rerun
   are first-class rather than retrofits (§6).
2. **Gated-wave identity (§9)** — named `Reactors.*` modules for gates (recommended, first-cut)
   vs extending the checkpoint identity to rebuild dynamic wave structs on resume (general, but
   reworks the `gate_resume` fence). Revisit if gates need to be catalog-dynamic.
3. **Artifact store shape + encryption (§7) — blocks Phase 2 (§14).** The store is
   **provenance-keyed** (`name → producer → value/ref`, decided — §7); still open: in-DB values vs
   refs to a blob store, and **encryption** for sensitive artifacts (the `approved-plan`/diff may
   carry secrets — reuse the AshCloak pattern that already protects
   `resume_checkpoint`/`replay_inputs`). Guardrail so the open part can't leak: Phase 2 persists
   **refs or AshCloak-encrypted values**, never plaintext in event payloads **or the `WaveCollect`
   terminal return** (→ `WorkflowRun.result`, §5/§7). Also open: which
   artifacts are *stored* values vs *reconstructed* from the environment (a working-tree `diff`)?
   Resolve before Phase 2.
4. **`ran` invalidation vs run-identity (§4)** — explicit removal-from-`ran` (recommended, matches
   the source), durably recorded as a **`stages_invalidated`** subtractive event so recovery replays
   the *net* `ran` (§6), vs a `{stage, generation}` key. Affects how the projection replays reruns.
5. **Catalog storage (§10.3)** — compile-time map + YAML overlay (recommended) vs Ash-data mirror
   (un-moots G3-3). Shapes the `Stage` source; resolve at Phase 0.
6. **Composer ↔ `PipelineStore`/`RunPipeline`** — long-term, does the composer subsume static
   pipelines? Keep coexisting for now (dynamic mode vs fixed-chain mode).
7. **Signal vocabulary scope (§7)** — port the full `SIGNALS.md` families or start minimal and
   grow per workflow? Recommendation: minimal, validated at load, grown by AR-3.
8. **Gate-stop effect + status mapping (§9/§6)** — a gate **reject** or **abandon** must resolve
   the held route, never leave the parent `:running`. Committed: both take the parent terminal as
   **`:cancelled` + `result.disposition`** (`:rejected` / `:abandoned`) — the `route_rejected` /
   `route_abandoned` kinds project onto the existing status set, *not* a new `:rejected`
   (recommended over widening the `one_of`, `workflow_run.ex:214`). The open fork is the
   reject-only **re-plan** opt-in (a planner subscribing to `plan-rejected`, oscillation-guarded).
   Phase 4 commits it.
9. **Wave-launch correlation mechanism (§6)** — precompute the `wave_index` and append
   `wave_started` *before* `run/3` (recommended — no runner change; the child self-identifies by
   the `composer:<parent>:<wave_index>` idempotency key it already persists, and binds
   `child_run_id` on `wave_completed`) vs a split-phase runner (`create_wave_run` → `wave_started`
   → `execute`), or a new `:wave_index`/`:run_metadata` opt + `run_config/4` overlay if an explicit
   `wave_index` field (or the child id) must be durable pre-launch. Precompute is committed; Phase 2
   commits it.
10. **Skill-as-stage execution seam (§5)** — a `{:skill, name}` unit run as its own nested child run
    via `ReactorRunner` + `parent_run_id` (recommended — a grandchild nested under its wave child run,
    at the cost of a deeper run hierarchy) vs embedding the compiled skill in the wave via
    Reactor's `compose` seam (one shared child run, but **blocked in reactor 1.0.2**: `compose/5`
    takes only a module, not the `%Reactor{}` struct `Skills.Compiler` produces — a struct raises
    `FunctionClauseError` — and a compiled skill terminates in a text-collapsed result, not the typed
    `%StepResult{}` an `emit` mapper reads, §5). The compose path opens up only with both a
    struct/module-aware compose and a typed-result compiler mode; revisit then. Resolve when the first
    skill-stage lands.
11. **Observe-surface URI shape (§10.2)** — a single `jido://workflows/catalog` resource
    (recommended — fits jido_mcp's exact-`uri()` registration, `runtime.ex:17`) vs a generated module
    per catalog item vs an upstream resource-template (RFC 6570) extension for a
    `jido://workflows/<id>` family. Phase 5 commits it.
12. **Failed-skill-stage policy (§5)** — terminal-by-default (recommended first cut: a failed nested
    skill fails its wave → parent `:failed`, consistent with the `run_wave` `:failed` branch and the
    budget terminal §6) vs a **retryable stage failure** (the wrapper rescues the nested failure into a
    failure-marked emission so the wave does **not** hard-fail, and the composer re-schedules the stage
    in a later wave under a fresh `wave_index` — the new run linked via `:retry_of_id` — bounded by the
    §4 per-stage rerun cap → terminal at the cap). The retryable path is more resilient but needs the
    soft-failure mechanism (a wrapper that converts a nested `{:error, _}` into an `{:ok,
    failed-emission}`); resolve when skill stages and the self-heal loop (AR-4) land together.

## §16 — Dependency posture

**No new dependencies for the core.** Reactor / Ash / `jido_mcp` / `jido_composer` are in-tree
(the composer reuses Reactor + the envelope, not `Jido.Composer` — §1a). The **one conditional
new direct dep**: `file_system`, *only if* runtime catalog hot-reload in prod is wanted (§10.3) —
it's currently dev/test-transitive via `credo` (`runtime: false`), so a dev-only watcher needs
nothing, but a prod runtime watcher must promote it. The composer is pattern-level borrowing from
Alp River (a Claude Code plugin — nothing to add for *it*) re-implemented in
Elixir/Jido/Ash/Reactor, and it *reduces* surface by giving the write-only reasoning signals
their first real consumer.

## Bottom line

The composer is the methodology layer **above** the engine Squidie built: it claims the
dynamic-but-deterministic middle ground §6 leaves to free-form ReAct, by reusing — not forking —
the shipped substrate (Reactor per wave, the event-log envelope, the AR-1 gates). The crown jewel
is a pure, fully-testable function (§3) that ships first and alone (Phase 0). The load-bearing
engineering details: **locks never execute** — a held route
is the *blocked* state, and a separate **gate-producer** (a named reactor module, §9) emits the
lock's `until` signal; the artifact store is **provenance-keyed** so AR-3's per-lens `findings`
don't clobber; each stage carries a **`task` instruction** so N lenses share the one generic
`reviewer` template yet stay distinct, and the **per-lens verdict** (`clean:<lens>` vs
`findings:<lens>`, the emit mapper's derivation over the reviewer's `overall`/`findings`) is what
convergence reads (§2/§4/§7); the emission **mapper is a `Stage` field** (§2/§7) and an emission durable only
as a **JSON-safe map of signals + artifact refs** (the `%StepResult{}`/`%StageEmission{}` structs
are in-memory — `json_safe?/1` drops them — §5/§7); the composer needs a new
**artifact formatter** because `ContextBuilder.build_task` only joins strings (§5); `parent_run_id`
is a real relationship and `wave_started` the **precomputed** wave-correlation record (`wave_index`
+ stages + route/catalog hash; the child id binds later on `wave_completed`, the fold-applied
marker) that recovery folds, replays, and synthesizes terminals on (§6); the durable composer event
set is **additive *and* subtractive** — `signals_retracted` / `stages_invalidated` record every
`live`/`ran` *removal* so the fold reconstructs the *net* state and a crash never resurrects a
retracted `plan-approved` or a lens invalidated for rerun (§4/§6); the parent run **launches as
`workflow_type: "composer"`, appending its own `run_started`** (it never runs through
`ReactorMiddleware`, so recovery dispatches on that type, §6) and stays `:running`
through a child gate pause and exits a gate **reject/abandon** to a `:cancelled` terminal (with a
`:rejected`/`:abandoned` disposition, never a new status) rather than a strand (§6/§9); and the
**artifact-encryption decision blocks Phase 2** (§14/§15.3). The three gust borrows the docs flagged as "shared" all hang off the composer and are
designed here (§10). Build it on the foundation the engine left
behind — pure router first, durable envelope second, gates and observe on top, cluster lease when
clustering is real.

## Appendix — key APIs referenced

- `JidoClaw.Orchestration.ReactorRunner.run/3` — `orchestration/reactor_runner.ex:229-230`
  (`@spec run(module() | Reactor.t(), map(), keyword())`; accepts a `%Reactor{}`; returns
  `{:ok | :error, value, run}`, **or `{:ok, {:existing_run, id}, run}` on an `idempotency_key` hit —
  nothing executed** (`:56-69,296`), the branch `run_wave`/recovery handles by child status
  (§5/§6); opts `async?`, `definition_hash`, `deadline`, `idempotency_key`, **+ proposed
  `:parent_run_id`**). Note `reactor_runner.ex:28-36`: struct reactors are **ungated**.
- `Reactor.Builder` — `new/1`, `add_input/3`, `add_step/5`, `add_middleware/2`, `return/2`;
  driven by `JidoClaw.Skills.Compiler` (`skills/compiler.ex`).
- `JidoClaw.Skills.Steps.{AgentStep, AgentRunner, IterativeStep}` — `AgentRunner.run/4`
  (`agent_runner.ex:50`) takes a **template-name string** + a **required `task`** → `Templates.get`
  (`templates.ex:43`, every template static `model: :fast`). The composer feeds `stage.task`; per-
  stage tiering needs a spawn-time `model`/`effort` override seam (§12) the template can't carry.
- `JidoClaw.Agent.Workers.Reviewer` — output schema `overall`/`summary`/`findings`
  (`reviewer.ex:19-37`); the per-lens `clean:<lens>` / `findings:<lens>` verdict (§4 convergence) is
  the `emit` mapper's derivation (§7/§12), **not** a schema change.
- `JidoClaw.Skills.Result.build/3` — `skills/result.ex:36` (the **text-collapse** the per-wave
  `WaveCollect` must avoid).
- `JidoClaw.Orchestration.WorkflowEvent` (kinds `:95-119`) + `WorkflowEvent.Projection`
  (`next_status/2`, `status_attrs/3`, `project_status/1`) — the log + projection to extend.
- `JidoClaw.Orchestration.WorkflowRun` — status projection (`:set_status`, `:124-149`); claim
  columns (`:328-341`); `:create` accept list (`:101-112`). Add `belongs_to :parent_run`
  (`allow_nil?: true` — mandatory per `test/jido_claw/style/belongs_to_allow_nil_test.exs` —
  `attribute_writable?: true`) + `:parent_run_id` to the accept list (cross-tenant-guarded via
  `CrossTenantFk.validate/2`, `cross_tenant_fk.ex:51` — `WorkflowRun` already has the `by_id_global`
  it needs, §6). The composer parent launches as
  `workflow_type: "composer"` and appends its own `run_started`
  (`projection.ex:101`: `next_status(:pending, :run_started) → :running`) — it never executes through
  `ReactorMiddleware` (`reactor_middleware.ex:151`).
- `JidoClaw.Orchestration.{GateStep, GateResume, Cases}` + `Gate.Kinds` — the AR-1 gate
  machinery; resume fences on `@allowed_module_prefix "Elixir.JidoClaw.Orchestration.Reactors."`
  (`gate_resume.ex:84`), `safe_encode_checkpoint` requires `:reactor_module`
  (`reactor_runner.ex:638`).
- `Jido.MCP.Server.Resource` (`deps/jido_mcp/lib/jido_mcp/server/resource.ex`) +
  `core/mcp_server.ex` + `tools/workflow_status.ex` / `WorkflowView.snapshot/2` — the observe
  surface (§10.2).
- Alp River source under `~/workspace/claws/alp-river/`: `hooks/route.py` (algorithm),
  `hooks/tests/test_route.py` (test spec), `doctrine/{CATALOG,SIGNALS}.md` (contracts),
  `WORKFLOW.md` (the loop).
