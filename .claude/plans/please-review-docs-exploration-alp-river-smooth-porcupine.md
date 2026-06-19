# AR-2 Composer — Phase 1: Single-Run Loop (in-memory spike)

## Context

`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` designs a deterministic, signal-driven
route composer that sits *above* the shipped Reactor envelope. **Phase 0 already shipped** (commit
`012f17f`): the pure decision layer under `lib/jido_claw/route_composer/` — the `Stage` struct,
`Router.compose_route/4` + `merge_sticky/3` + `size_label/1`, `Graph.kahn/2`, a compile-time-validated
10-stage `Catalog`, and `CatalogValidator`. It is pure data + a pure function; **there is no process,
no execution, and no state.**

**Phase 1 (this plan)** is the §14 "single-run loop (spike, per-wave runs)" — the §6 *alternative*
(in-memory composer state, no durable parent envelope). It builds the `JidoClaw.RouteComposer`
GenServer that turns the crank: **seed → `compose_route` → `merge_sticky` → dispatch the next unrun
wave → run it on Reactor → fold the emitted signals/artifacts → recompose → converge.** Each wave is
built into a `%Reactor{}` and run through the existing `ReactorRunner.run/3`, so every increment
inherits the shipped execution envelope. This is the first phase where the composer *does* something —
it gives the write-only reasoning signals their first real consumer and proves the loop end-to-end
against a fixture catalog.

**Done when** (per §14): a code-path route composes and runs end-to-end through multiple waves,
passing fixture `plan` / `approved-plan` / `diff` artifacts across waves, growing the route from an
emitted signal, releasing a held (locked) stage, and converging on clean review verdicts — and
**`mix precommit` is green**.

Two scope forks were confirmed with the user:
- **Forward-only.** The self-heal rerun loop (AR-4: review→fix→re-review via `ran`-invalidation) is
  **out of Phase 1** and becomes its own phased design doc next. Phase 1 still demonstrates the
  headline dynamic behavior (signal-driven route *growth*), just not reruns.
- **Locks exercised via a plain producer.** Gate *producers* are Phase 4, but a plain worker stage
  emits the `until` signal that releases a held stage — which also yields the `approved-plan` artifact
  the done-criterion names. This exercises the loop's held→released path and deadlock-surfacing
  without any gate machinery.

## Scope & boundaries

**In Phase 1:**
- `JidoClaw.RouteComposer` GenServer with **in-memory** state (`live`, `artifacts` store, `ran`,
  `premises`, `prev_route`, `wave_index`); `available` is *derived* from the artifact store, never stored.
- The loop, with convergence + blocked/deadlock detection + a spend ceiling (`max_waves`, optional
  wall-clock `deadline`).
- Per-wave execution: a focused `build_wave/2`, a `WaveCollect` terminal step, run via `ReactorRunner.run/3`.
- The emission contract for **`emit: :default` only**: `StageEmission` + `from_map/1`, the `:default`
  mapper (reviewer-verdict derivation + explicit emitted-signals + `output`→artifact mapping), the
  provenance-keyed artifact store, the cross-wave `:extra_context` formatter, and the fold (incl.
  paired-verdict last-writer-wins).
- Worker-only waves: `build_wave/2` accepts only `{:worker_template, _}` units; a `{:gate,_}` /
  `{:seed,_}` / `{:skill,_}` unit in a wave is rejected with a loud error (gates/seed/skill are later
  phases), so the public loop is fixture-catalog-only in Phase 1.
- Catalog-load hardening: `CatalogValidator` rejects a `emit: :default` + `lens` stage that doesn't
  declare **both** `clean:<lens>` and `findings:<lens>` in `publishes` — a strict-mapper authoring
  error fails at load, not mid-wave.
- An explicit composer result/history shape (terminal + per-wave history) the integration test asserts against.
- A Phase-1 fixture catalog + stub workers; pure unit tests + one DB-backed integration test.

**Deferred to their designed phases (not Phase 1 gaps):**
- Durable parent `WorkflowRun` envelope, composer event kinds, projection, crash recovery, the
  `:parent_run_id` opt, artifact encryption/refs → **Phase 2** (§6/§15.3). Phase 1 uses **inline,
  non-sensitive fixture artifacts only** because every wave still persists its `WaveCollect` return to
  the child `WorkflowRun.result` as plaintext JSONB.
- Triage seed (AR-8) → **Phase 3**. Phase 1 seeds `request-received` + the `code` path directly
  (standing in for triage), and `planner` subscribes the seed `request-received`.
- Gate-producer modules, gate park/resume, reject/abandon → **Phase 4**.
- MCP observe surface → **Phase 5**; cluster lease → **Phase 6**.
- Self-heal rerun / `ran`-invalidation / per-stage rerun cap / oscillation guard → **separate AR-4
  design doc** (the confirmed fork).
- Per-stage `model`/`effort` tiering → **§12**. `AgentRunner.run/4` has no override seam
  (`agent_runner.ex:50`); Phase 1 carries `stage.model`/`stage.effort` but does **not** thread them
  (stages run at the template's static `:fast`).
- Named `{:mapper, _}` registry → lands when a stage needs custom derivation (AR-3+). Phase 1
  recognizes the `{:mapper, _}` branch but returns a loud `{:error, :mapper_not_registered}` (the
  fixture uses `:default` exclusively).

## New modules

Mostly under `lib/jido_claw/route_composer/` (the shared `StepIds` utility lands under
`lib/jido_claw/workflows/`). Each new public function needs a `@spec` and each module a `@moduledoc`
(precommit is strict — see checklist).

| Module | Responsibility | Key reuse (path:line) |
| --- | --- | --- |
| `RouteComposer` (GenServer) | Owns in-memory state; drives the loop tick (`handle_continue`); runs each wave; folds; classifies terminal; notifies caller. | `Router.compose_route/4` + `merge_sticky/3` (`router.ex:69,95`); `ReactorRunner.run/3` (`reactor_runner.ex:229`) |
| `RouteComposer.Loop` (pure) | Pure loop decisions: `dispatch_cohort/2` (first merged wave minus `ran`), `terminal/2` (`:converged` / `:not_converged` / `:deadlock` / `:budget_exhausted`), `lenses_clean?/3`. Tested without the process. | reads `Router` result + `Stage.lens` (`stage.ex:79`) |
| `JidoClaw.Workflows.StepIds` | Shared compile-time atom pool (`:step_1..:step_256`) for Reactor step/arg names — never `String.to_atom` a stage name. `fetch/1 :: {:ok, atom} \| {:error, :out_of_bounds}` + `max/0` so an oversized wave is an error tuple, not a function-clause crash. Neutral home (the `Workflows` namespace already holds `StepResult`/`ContextBuilder`) so `Skills.Compiler` and `WaveBuilder` both depend *down* onto it. | extracted from `Compiler` `@step_ids` (`compiler.ex:85,502`); `Compiler` refactored to consume it |
| `RouteComposer.WaveBuilder` | `build_wave/2`: one Kahn level → `{:ok, %Reactor{}}` \| `{:error, _}`. Flat parallel batch of `AgentStep`s each reading only `:extra_context` (no intra-wave edges), terminating in `WaveCollect`. **Rejects non-`{:worker_template,_}` units loudly** (gate/seed/skill are later phases; `AgentStep` requires `template:`, `agent_step.ex:52`). | mirrors `Compiler.build_graph/3` (`compiler.ex:349`); `Reactor.Builder` `new/add_input/add_step/return`; `Argument.from_input/from_result` |
| `RouteComposer.Steps.WaveCollect` | Terminal step. Holds the typed `%StepResult{}` list, runs each stage's emit mapper, returns a **json-safe** `%{"emissions" => […], "wave_index" => n}` map. | contrast `CollectStep`/`Result.build/3` which text-collapse (`collect_step.ex:27`, `result.ex:36`) — must NOT do that |
| `RouteComposer.StageEmission` | Struct `%{stage, signals, artifacts}` + `from_map/1` normalizing atom- and string-keyed maps. | atom/string tolerance like `Projection` (`projection.ex:19`) |
| `RouteComposer.Emit.DefaultMapper` | `map/2`: `%StepResult{}` + stage-meta → `%StageEmission{}`. Reviewer verdict + explicit signals + `output`→artifacts; validates emitted signals ⊆ `publishes` (loud fail). | reads `%StepResult{typed_output}` (`step_result.ex`); Reviewer schema `overall`/`findings` (`reviewer.ex:19`) |
| `RouteComposer.ArtifactContext` | `build/2`: the wave's stages + the provenance store → the `:extra_context` string (every artifact named in the wave's `input`, across producers). | NEW — `ContextBuilder.format_artifact_context/3` is single-reactor only (`context_builder.ex:75`) |
| `RouteComposer.Fold` | `fold/2`: emissions + state → next state (signals→`live`, artifacts→store, names→`ran`, paired-verdict retraction); `available/1` derives from the store. | — |

**Modified:** `JidoClaw.Skills.Compiler` (consume `JidoClaw.Workflows.StepIds` instead of its private
pool — clean de-duplication, greenfield, its tests guard the refactor) and
`JidoClaw.RouteComposer.CatalogValidator` (in-scope load-time verdict-publishes hardening; see Decisions).

## The loop

State (GenServer): `%{catalog, live (MapSet), artifacts (store), ran (MapSet), premises, prev_route,
wave_index, tenant, actor, max_waves, deadline, notify}`. `available` is derived each tick.

```
init: seed live (e.g. ["request-received","code"]),
      artifacts (%{"request" => %{"seed" => …}}),     # provenance shape from the start (see store, below)
      ran ∅, prev_route [], wave_index 0, history []  →  {:ok, state, {:continue, :tick}}

handle_continue(:tick):
  available = Fold.available(state)                                   # names with ≥1 producer (§2/§7)
  result    = Router.compose_route(catalog, live, available, ran)     # §3 pure; route never holds a ran stage
  display   = Router.merge_sticky(catalog, prev_route, result)        # §3.3 display route (re-adds sticky ran)
  dispatch  = Loop.dispatch_cohort(display, ran)                      # first (wave -- ran) that is non-empty
  cond:
    dispatch == nil      -> finish(Loop.terminal(display, state), state)  # :converged | :not_converged | :deadlock
    over_budget?(state)  -> finish(:budget_exhausted, state)              # max_waves / deadline
    true                 -> run_wave(dispatch, display, state)

run_wave(dispatch, display, state):
  stages = Enum.map(dispatch, &Map.fetch!(catalog, &1))              # waves carry NAME strings (router.ex:44)
  with {:ok, rx}        <- WaveBuilder.build_wave(stages, wave_index: wave_index),  # rejects non-worker units
       ctx               = ArtifactContext.build(stages, artifacts),  # §5 cross-wave :extra_context (capped)
       {:ok, val, run}  <- ReactorRunner.run(rx, %{extra_context: ctx},
                             tenant: tenant, actor: actor, async?: true,
                             name: "route_composer:wave_#{wave_index}"),  # struct path, ungated; BLOCKS
       {:ok, emissions} <- decode_emissions(val) do                  # StageEmission.from_map/1, guarded
    next = state |> Fold.fold(emissions) |> record_wave(display, run, emissions)
    {:noreply, next, {:continue, :tick}}
  else
    {:error, reason}       -> finish({:failed, reason}, state)        # build_wave / decode failure
    {:error, reason, _run} -> finish({:failed, reason}, state)        # ReactorRunner error envelope (never raises)
  end
```

**`ReactorRunner.run/3` returns error envelopes; it does not raise** (`reactor_runner.ex:118-135`):
`{:error, reason, run|nil}` on a failed/cancelled wave or a pre-run failure, and a `WaveCollect` mapper
error (e.g. an undeclared signal) surfaces through it too. Every fallible call in the wave path —
`build_wave/2`, `run/3`, `StageEmission.from_map/1` — is handled in the `with/else` and converted to a
**notified `:failed` terminal**, never an unhandled crash (a crash would leave `run_sync/1`'s `receive`
hanging). `run_sync/1` also takes a timeout and links the composer so a hard crash still propagates.

**Terminal classification (`Loop.terminal/2`)** when no unrun cohort remains:
- `held == %{}` **and** `lenses_clean?` → **`:converged`** (composer result `:completed`).
- `held == %{}` **and not** `lenses_clean?` → **`:not_converged`** — a ran lens still has an open
  `findings:<lens>` and, with self-heal/rerun deferred (forward-only), nothing will resolve it. An
  explicit **terminal failure**, never a fall-through or a spin. (When AR-4 lands, this case instead
  drops the touched lens from `ran` and re-fires the fixer.)
- `held != %{}` (nothing runnable can ever emit a held `until`) → **`:deadlock`** (surfaced; not a
  busy-wait). In forward-only Phase 1 the lock-via-producer fixture keeps the releasing producer
  *runnable*, so the held→released cycle resolves while dispatch is still non-empty — this branch fires
  only on a genuinely stuck catalog.
- A `:blocked` state (held waiting on an `until` an async gate will later emit) is a **Phase 4** concept;
  in Phase 1 a dispatch-empty + non-empty `held` is a deadlock.

**`lenses_clean?/3`**: every stage in `ran` carrying a `lens` field has `clean:<lens>` in `live`
(equivalently no open `findings:<lens>`). The fold's paired-verdict invariant guarantees exactly one
of the pair is live per lens.

**Bounds**: `max_waves` (essential loop backstop) and an optional wall-clock `deadline`. Hitting either
→ `:budget_exhausted`. Per-stage rerun cap + oscillation guard are moot without reruns → land with AR-4.

**Driving / notification**: the loop ticks via `handle_continue(:tick, …)`. `finish/2` stamps the
terminal + summary onto state, sends `{:route_composer, ref, {:done, summary}}` to `notify` for
**every** terminal — convergence *and* failures (the summary's `terminal` field is `:converged` /
`:not_converged` / `:deadlock` / `:budget_exhausted` / `:failed`) — and **returns `{:stop, :normal,
final_state}`** so a finished composer terminates rather than lingering idle (it is unsupervised in
Phase 1, so a non-stopping callback would leak one process per `run_sync/1`). The thin `run_sync/1`
helper (`start_link` with `notify: self()`, a bounded `receive`) is the test/CLI entry. Per wave the
GenServer blocks inside `run/3` (acceptable for a single-run spike; Phase 4 moves wave execution to a
`Task` + `handle_info` so the GenServer stays live across a gate park).

## Composer result / history shape

The GenServer accumulates an explicit history as it runs, so the integration test asserts against a
defined shape rather than reconstructing it. `record_wave/3` appends one history entry **and advances
the per-turn state it owns — `wave_index = wave_index + 1` and `prev_route = display.route`** (so the
next tick's `merge_sticky` carries the right sticky baseline and the wave names/final route don't go
stale); `finish/2` stamps the terminal:

```elixir
%{
  terminal: :converged | :not_converged | :deadlock | :budget_exhausted | :failed,
  reason: term() | nil,                          # bound hit / failure reason; nil on :converged
  final_route: [String.t()],                     # the last display route
  final_live: MapSet.t(String.t()),
  artifacts: %{name => %{producer => value}},     # the final provenance store
  ran: MapSet.t(String.t()),
  wave_index: non_neg_integer(),
  history: [
    %{index: n, stages: [name], child_run_id: id, route: [name],
      held_before: %{name => [until]}, emissions: [%{stage, signals, artifacts}]}
  ]
}
```

`held_before` snapshots `display.held` at dispatch time (so the test can assert `implementer` was held
on the wave the approver ran), and `child_run_id` comes from the `run` that the wave's
`ReactorRunner.run/3` returns (so the test can read back each child `WorkflowRun.result`).

## The emission contract (`emit: :default`)

**`DefaultMapper.map(%StepResult{}, stage_meta)`** where `stage_meta = %{name, emit, lens, output,
publishes}` (the minimal projection `WaveBuilder` threads into `WaveCollect`):

1. **Reviewer verdict** — if `typed_output` is reviewer-shaped (`overall ∈ {:approve,
   :request_changes, :comment}`, tolerant of atom/string keys): `overall == :approve` **and** empty
   `findings` → emit `clean:<lens>`; else → emit `findings:<lens>` + a `findings` artifact. A
   reviewer-shaped stage with no `lens` is a coherence error (surfaced).
2. **Explicit signals** — read the producer's declared emitted-signal list under **either**
   `typed_output[:signals]` **or** `typed_output["signals"]`. The same atom/string tolerance applies to
   the verdict keys in step 1 and the artifact-name lookups in step 3 — typed output is atom-keyed live
   but string-keyed once it round-trips JSON (the `projection.ex:19` precedent), so every lookup must
   try both. This is the Phase-1 `:default` convention for non-reviewer producers (planner emits
   `plan-ready`, implementer emits `code-written`/`auth-surface`). *(Real non-stub producers like
   `Coder`/`Researcher` have no `signals` field; wiring them to emit signals without one — a named
   mapper or a worker-schema field — is an AR-3/§12 concern, called out so it isn't a hidden gap.)*
3. **Artifacts** — map each `stage.output` name to a value pulled from `typed_output` / `artifacts` /
   `result` (in that precedence), coerced json-safe (inline, non-sensitive — Phase 1).
4. **Validate ⊆ `publishes`** — every emitted signal must be a declared `publishes` topic. A signal
   outside `publishes` (or a malformed verdict) returns `{:error, …}`, which `WaveCollect` propagates
   as a wave failure. **Never silent-drop**: a dropped `findings:<lens>` would let the loop converge as
   clean when it is not. (The verdict-family declarations are *also* enforced at catalog-load — see
   Decisions — so this runtime check is defense-in-depth, not the first line.)

**`Fold.fold(emissions, state)`**: union signals into `live`; index artifacts as
`store[name][producer] = value`; union stage names into `ran`. **Paired-verdict last-writer-wins**:
folding `clean:<lens>` retracts any live `findings:<lens>` and vice-versa (so a re-reviewed lens that
flips clears the stale signal and convergence stays reachable). `Fold.available/1` =
`MapSet.new(Map.keys(store))` (a name with ≥1 producer).

## Per-wave execution

- **`build_wave/2`** (`WaveBuilder`): builds via `with` (each `Builder` call returns `{:ok, reactor}`,
  exactly as `Compiler.build_graph/3` does, `compiler.ex:349`) — `add_input(:extra_context)` → one
  `add_step` per stage → add `WaveCollect` → `Builder.return(WaveCollect_id)` (a literal pipeline would
  break on the `{:ok, _}` tuples). **First it validates every unit is `{:worker_template, _}`** and
  returns `{:error, {:unsupported_unit, name, unit}}` otherwise — a `{:gate,_}`/`{:seed,_}`/`{:skill,_}`
  stage would otherwise raise in `AgentStep`'s `Keyword.fetch!(options, :template)` (`agent_step.ex:52`).
  Each stage step is `{AgentStep, opts}` with
  `opts` mirroring `Compiler.step_options/2` (`compiler.ex:426`) — `template:` (from
  `{:worker_template, name}`), `task: stage.task`, `step_name: stage.name`, `context_format: :deps`,
  `upstream: []`, `consumes: []` — and args `[Argument.from_input(:extra_context, :extra_context)]`
  **only** (no `from_result` edges: same-Kahn-level stages are independent; all cross-wave data arrives
  via `:extra_context`). Step names come from `StepIds.fetch/1`, with `build_wave/2` checking
  `length(stages) <= StepIds.max()` up front and returning `{:error, :wave_too_large}` rather than
  crashing (a wave is one Kahn level, so this is a backstop). `WaveCollect` depends on every stage
  step via `Argument.from_result(step_id, step_id)` and carries `stage_meta: %{step_id => meta}` +
  `wave_index:` in its options.
- **`WaveCollect.run/3`** (`use Reactor.Step`, `@impl`): for each `step_id → %StepResult{}`, run the
  stage's emit mapper; on success return `%{"wave_index" => n, "emissions" => [%{"stage" =>, "signals"
  => […], "artifacts" => %{name => value}}]}`. **Json-safe only** — never return a `%StageEmission{}`/
  `%StepResult{}`/tuple (`ReactorMiddleware.json_safe?/1` would collapse the whole return to `%{}`,
  `reactor_middleware.ex:471`). The structs stay in-memory; the composer rehydrates via
  `StageEmission.from_map/1` from the live `{:ok, value, _run}` return. A mapper error → `{:error, _}`
  → the wave fails loudly. (`emit: {:mapper, _}` and an iterative `[gen,eval]` shape return explicit
  loud errors — out of Phase-1 fixture scope.)
- **`ReactorRunner.run/3`** runs the struct wave ungated (no `GateStep` → never halts, the
  "Ungated struct support" path, `reactor_runner.ex:28`), auto-wires `ReactorMiddleware`, and **blocks**
  until the wave completes (`async?: true` only parallelizes the wave's independent steps). `tenant:`
  and `actor:` are **required** (`reactor_runner.ex:238`); pass a stable `name:`; **omit
  `idempotency_key`** so each wave always runs.

## Cross-wave artifacts

The provenance store is `%{artifact_name => %{producer_stage => value}}` (co-producers never clobber).
`ArtifactContext.build(stages, store)` collects every artifact named in the wave's stages' `input`
(required ∪ optional), renders each present artifact's producer→value entries into a markdown block,
and joins them — the single `:extra_context` string the wave reactor receives. Missing optionals are
simply absent; a missing *required* input is the router's drop decision, not the formatter's. **Each
rendered value is truncated to a per-value byte cap (with an elision marker), and the whole string to a
total cap** — even for the spike, unbounded artifact text flowing into `:extra_context` is a spend and
debuggability hazard.

## The Phase-1 fixture catalog + stub workers

A validator-clean fixture catalog (test support, alongside `JidoClaw.RouteComposer.TestFixtures`,
`test/support/jido_claw/route_composer/fixtures.ex`) mirroring the real code-path shape but **gate-free**.
`planner` subscribes the **seed signal `request-received`** (not `plan-needed`): there is no triage stage
in Phase 1 to publish `plan-needed`, and `CatalogValidator`'s only seed signal is `request-received`
(`catalog_validator.ex:54`), so an orphan `plan-needed` subscription would fail validation (invariant 3).
Reviewer stages **declare both `clean:<lens>` and `findings:<lens>` in `publishes`** (matching the real
`Catalog`, `catalog.ex:102`) so the strict ⊆-publishes check passes for either verdict.

Concrete flow (each stage `routes: ["code"]`, `emit: :default`):

| Stage | unit | subscribes | input.req | output | publishes | lock |
| --- | --- | --- | --- | --- | --- | --- |
| `planner` | `{:worker_template,"researcher"}` | `request-received` | `request` | `plan` | `plan-ready`,`scope-shift` | — |
| `approver` | `{:worker_template,"verifier"}` | `plan-ready` | `plan` | `approved-plan` | `plan-approved`,`scope-shift` | — |
| `implementer` | `{:worker_template,"coder"}` | `plan-ready` | `plan` (opt `approved-plan`) | `diff` | `code-written`,`auth-surface`,`scope-shift` | `{while: plan-ready, until: plan-approved}` |
| `quality-reviewer` (lens `quality`) | `{:worker_template,"reviewer"}` | `code-written` | `diff` | `findings` | `clean:quality`,`findings:quality`,`scope-shift` | — |
| `security-reviewer` (lens `security`) | `{:worker_template,"reviewer"}` | `auth-surface` | `diff` | `findings` | `clean:security`,`findings:security`,`scope-shift` | — |

Seed `live = ["request-received","code"]`, `artifacts = %{"request" => %{"seed" => "…"}}`
(provenance shape from the start). Loop:
**W0** planner → `plan-ready` + `plan`. **W1** approver runs while implementer is *held* by the lock →
`plan-approved` + `approved-plan`; recompose releases the lock. **W2** implementer (now runnable,
`approved-plan` threaded in via `:extra_context`) → `code-written` + `auth-surface` + `diff`. **W3**
quality-reviewer (`code-written`) **and** security-reviewer (`auth-surface`, joins *only because*
implementer emitted it — the growth demonstration) run in one parallel wave → `clean:quality` +
`clean:security`. **Converge.** This crosses `plan`/`approved-plan`/`diff` across waves, releases a
held lock, grows the route from a signal, runs a parallel wave, and converges clean.

**Stub workers**: register per-template stubs via `:agent_templates_override` (template name → stub
agent module). **Each stub module must export `ask/3`** — `AgentRunner` captures `typed_output` only on
the async path, gated on `function_exported?(module, :ask, 3)` (`agent_runner.ex:122-130`); an
`ask_sync`-only stub falls to the sync path that leaves `typed_output: nil` (`agent_runner.ex:154-160`),
so `DefaultMapper` would see no `signals`/`overall`. Mirror `test/support/echo_ask_stub.ex` (which
exports `ask/3` for exactly this). Pair it with a fake `:step_agent_server`. **Keying must be request-id based, not FIFO** — W3 runs two
reviewer steps concurrently, so a global pop-a-queue stub would race: the `ask/3` stub stamps
`request_id => canned_request` (choosing the canned output by inspecting the task/template it is handed),
and the fake `await_completion/2` reads `request_id` from its `result_path`/`status_path` opts
(`agent_runner.ex:176-181`) to return *that* request's `%{status: :completed, result: <request map>}`
(so `Output.typed_request_output/1` yields the canned typed output, `agent_runner.ex:182-200`). Mirrors
the `ValidatedFakeAgentServer` pattern in `agent_runner_test.exs`. Canned typed outputs: producers carry
`%{"signals" => […], "<output>" => "…"}`; reviewers carry `%{"overall" => "approve", "findings" => []}`.
No real LLM — precommit stays hermetic.

## Key decisions resolved

- **`clean:<lens>` / `findings:<lens>` must be in `publishes` — enforced at catalog-load (in scope).**
  The `:default` mapper derives both verdict families and the runtime ⊆-publishes check is strict (loud
  wave failure, no silent drop). Because a missing declaration is a catalog *authoring* error, not a
  runtime condition, `CatalogValidator` gains a load-time check: a `emit: :default` + `lens` stage must
  declare **both** `clean:<lens>` and `findings:<lens>` in `publishes`. This fails the build, not a
  mid-wave run. Safe for the real `Catalog` (its reviewers already comply; non-lens `:default` stages
  are unaffected). The runtime check stays as defense-in-depth. Add the new rule to the
  `CatalogValidator` moduledoc invariant list so the doc doesn't go stale.
- **`StepIds` lives in `JidoClaw.Workflows`, not `RouteComposer`.** It is a generic Reactor atom-pool
  utility that **`Skills.Compiler` will depend on**, so placing it under `RouteComposer` would reverse
  ownership (the skills compiler pointing *up* into the composer). Home it at `JidoClaw.Workflows.StepIds`
  (beside `StepResult`/`ContextBuilder`); both `Skills.Compiler` and `RouteComposer.WaveBuilder` depend
  *down* onto it. Single source for the cap + the "never `String.to_atom` a stage name" invariant.
- **GenServer not yet supervised.** Phase 1 starts the composer ad hoc (`run_sync/1`); Phase 2 wires a
  `DynamicSupervisor` + unique `Registry` keyed by `parent_run_id` (the established
  `RunRegistry`/`RunTaskSupervisor` idiom, `application.ex:153`) once a durable run gives a stable key.
- **`reach.check` `behaviour_candidate`.** A new plain GenServer may false-positive this `--smells`
  check; the established remedy is adding the module to the ignore-list in `.reach.exs` (precedent:
  `CodeServer.Runtime`, `RequestCorrelation.Sweeper`, `Trace.RetentionSweeper`). Add `RouteComposer`
  there if it fires.

## Verification

**Pure unit tests** (`use ExUnit.Case, async: true`, no DB):
- `DefaultMapper` — clean vs findings verdict; explicit `signals`; `output`→artifact mapping;
  ⊆-publishes violation fails; reviewer-without-lens errors; atom- and string-keyed `typed_output`
  behave identically.
- `CatalogValidator` (new rule) — a `emit: :default` + `lens` stage that omits `clean:<lens>` or
  `findings:<lens>` from `publishes` is flagged at load; a stage declaring both passes.
- `Fold` — signals into `live`; artifact provenance indexing (co-producers coexist); `ran` union;
  paired-verdict retraction (clean↔findings); `available/1` derivation.
- `ArtifactContext` — pulls required+optional names across producers; omits missing optionals.
- `StageEmission.from_map/1` — atom-keyed and string-keyed maps normalize identically.
- `Loop` — `dispatch_cohort/2` (filters `ran`, skips empty waves, picks first non-empty);
  `terminal/2` (`:converged` / `:not_converged` (open findings, no rerun) / `:deadlock` /
  `:budget_exhausted`); `lenses_clean?/3`.
- `WaveBuilder.build_wave/2` — produces a `%Reactor{}` with the expected inputs/steps/return
  (assert structure; no run needed); rejects a non-worker unit and an oversized wave with `{:error, _}`.
- `StepIds` — `fetch/1` returns `{:ok, atom}` in range and `{:error, :out_of_bounds}` past `max/0`.

**Integration test** (`use JidoClaw.TenantCase, async: false` — it mutates global app env
(`:agent_templates_override`, `:step_agent_server`) and runs async Reactor steps, so non-async is
explicit, not incidental; seeds tenant, sandbox shared; stub workers): drive
`RouteComposer.run_sync/1` over the fixture catalog and assert — converges; `plan`/`approved-plan`/
`diff` each crossed waves (present in the final store with the right producers); `security-reviewer`
ran **only because** `auth-surface` was emitted (route growth); `implementer` was held then released
(observable via wave ordering / the held snapshot); the final `live` carries `clean:quality` +
`clean:security`; `wave_index` advanced as expected. Also assert each wave's child `WorkflowRun.result`
holds the json-safe emission map (proves the persistence boundary). A second variant — a reviewer stub
returning findings — asserts the loop terminates `:not_converged` (no fixer/rerun in forward-only
Phase 1), not a spin or hang.

**Manual / Tidewave** (optional sanity): drive the loop in `project_eval` over the fixture catalog and
inspect the terminal summary + per-wave `WorkflowRun` rows.

**Precommit gate** — `mix precommit` runs, in order: `jidoclaw.compile_check` (clean recompile,
**zero non-allowlisted warnings — allowlist is empty**), `jidoclaw.system_prompt.check`,
`deps.unlock --unused`, `format --check-formatted`, `reach.check --arch --smells --strict`,
`credo --strict`, `dialyzer`, `test`. Checklist for the new code:
- **No warnings**: every public fn `@spec`; `@moduledoc` (or `@moduledoc false`); `@impl Reactor.Step`
  on `WaveCollect.run/3`; no unused vars/aliases; no unreachable clauses.
- **Credo strict**: no `# TODO`/`# FIXME` (fails the gate); cyclomatic/perceived complexity ≤ 11;
  nesting ≤ 3; line length ≤ 120; comments rationale-only (ExSlop narrator/obvious-comment checks);
  `Design.AliasUsage` (deeper-than-2 aliases need the documented `# credo:disable-for-next-line`).
- **reach `--smells`**: scope a `behaviour_candidate`/`fixed_shape_map` false-positive via the
  `.reach.exs` ignore-list (precedent above) — `route_composer` is in no `--arch` layer, so arch is a
  non-issue.
- **No Ash resource** in Phase 1 → the AshCredo gauntlet and `belongs_to_allow_nil_test.exs` don't
  apply (those bite Phase 2's `parent_run` relationship).

## Files

**New** (`lib/jido_claw/route_composer/`): `route_composer.ex` (GenServer), `loop.ex`,
`wave_builder.ex`, `steps/wave_collect.ex`, `stage_emission.ex`, `emit/default_mapper.ex`,
`artifact_context.ex`, `fold.ex`. **New** (`lib/jido_claw/workflows/`): `step_ids.ex`
(`JidoClaw.Workflows.StepIds`).
**New tests**: `test/jido_claw/route_composer/{default_mapper,fold,artifact_context,stage_emission,loop,wave_builder}_test.exs`,
`test/jido_claw/workflows/step_ids_test.exs` (mirrors its `lib/` home), and
`test/jido_claw/route_composer/composer_loop_test.exs` (integration). Fixture catalog + stub workers
added to `test/support/jido_claw/route_composer/fixtures.ex` (or a sibling support module).
**Modified**: `lib/jido_claw/skills/compiler.ex` (consume `JidoClaw.Workflows.StepIds`);
`lib/jido_claw/route_composer/catalog_validator.ex` (load-time verdict-publishes hardening, in scope);
and `.reach.exs` (ignore-list entry if `behaviour_candidate` fires).

**Commit plan** (slicing guidance only — do **not** commit; leave everything unstaged). Two logical
commits when implementation lands and precommit is green: (1) `feat: composer Phase 1 substrate —
StepIds, WaveBuilder, WaveCollect, StageEmission, DefaultMapper, ArtifactContext, Fold` + their unit
tests; (2) `feat: composer Phase 1 loop — RouteComposer GenServer + Loop + fixture integration test`.
