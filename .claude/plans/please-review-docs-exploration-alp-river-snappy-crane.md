# AR-2 Composer — Phase 0: Catalog + `compose_route/4` (pure, fully tested)

## Context

`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` designs a **deterministic, signal-driven route
composer** — a third execution mode between the shipped Reactor DAG engine and the free-form agent
loop. The composer grows a route as durable state reveals what a task needs, but every recomposition
is a **pure function of accumulated state**, so the run is legible, reproducible, and recoverable.

The crown jewel (AR-2 §3) is `compose_route/4` — a faithful Elixir port of Alp River's
`hooks/route.py` (`~/workspace/claws/alp-river/hooks/route.py`). It is **pure, deterministic, zero
I/O**, fully testable in isolation, and carries **zero engine risk**. **Phase 0** ships exactly this
layer — the `Stage` struct, a built-in catalog, the catalog validator, and the router + its test port
— and nothing that executes. It is the natural first ship per AR-2 §14 (the static reasoning layer
today has no composer at all: `Classifier.recommend/2` picks one strategy and never revises).

**Greenfield**: no data/path migration concerns. **Done = `mix precommit` green** (the hard bar).
Everything stays unstaged; no commits.

### Decisions locked (clarifying Q&A)

1. **Test scope** → port the **~54 synthetic-catalog router tests** (core routing, wave scheduling,
   lock/held TC-U01–U14, family-prefix) **+ re-express the 4 GAP lock/gate scenarios** against the
   jido_radclaw catalog. **Skip** the 76 real-Alp-catalog tests, the ~62 `gen-catalog` compiler tests,
   and the 7 CLI tests (CLI → Phase 1 per §3.4).
2. **Catalog content** → a **representative starter catalog** authored as a compile-time Elixir map.
3. **Catalog validation** → a **full `check_catalog` port** (`~/workspace/claws/alp-river/hooks/check_catalog.py`)
   as a validator, **plus** cycle detection (AR-2's addition, §3.2 step 5) **plus** the structural
   and self-dependency checks below (review follow-ups).
4. **Module home** → top-level **`JidoClaw.RouteComposer.*`** in `lib/jido_claw/route_composer/`.

### Out of scope (later phases)

No execution: **no GenServer, no Reactor/wave runner, no emit mappers, no artifact store, no
signal/telemetry emission**. No YAML overlay / `YamlStore` / file-watch (deferred, §10.3). No real
47-stage Alp catalog, no `gen-catalog` compiler (jido_radclaw authors the catalog directly in Elixir
— sigil-stripping / `input_template` extraction don't apply; the validator's structural checks below
**replace** that lost compile-time normalization). Phases 1–6 untouched.

---

## Module layout

| File | Module | Purpose |
| --- | --- | --- |
| `lib/jido_claw/route_composer/stage.ex` | `JidoClaw.RouteComposer.Stage` | The composable-unit struct (§2 of the doc) |
| `lib/jido_claw/route_composer/catalog.ex` | `JidoClaw.RouteComposer.Catalog` | Built-in compile-time `@catalog` + accessors + **compile-time coherence guard** |
| `lib/jido_claw/route_composer/catalog_validator.ex` | `JidoClaw.RouteComposer.CatalogValidator` | `validate/1` — structural + `check_catalog` + cycle/self-dep checks |
| `lib/jido_claw/route_composer/graph.ex` | `JidoClaw.RouteComposer.Graph` | Shared **public** `kahn/2` (Kahn-by-levels topo + `{:error, undrained}` cycle signal) — used by Router AND CatalogValidator (a `defp` can't span modules) |
| `lib/jido_claw/route_composer/router.ex` | `JidoClaw.RouteComposer.Router` | `compose_route/4`, `merge_sticky/3`, `size_label/1` (the pure router) |
| `test/support/jido_claw/route_composer/fixtures.ex` | `JidoClaw.RouteComposer.TestFixtures` | `stage/1`, `lock_catalog/1`, named synthetic catalogs + assertion helpers |
| `test/jido_claw/route_composer/router_test.exs` | — | ~54 ported router tests + 4 GAP scenarios |
| `test/jido_claw/route_composer/catalog_validator_test.exs` | — | Validator coherence/structural/self-dep tests |
| `test/jido_claw/route_composer/catalog_test.exs` | — | Starter-catalog accessors + `validate(Catalog.all()) == []` |

`JidoClaw.RouteComposer` (the GenServer, §1a/§4) is **reserved for Phase 1** — Phase 0 keeps the pure
function in `…Router` so the eventual GenServer calls it unchanged.

Pattern anchors: `reasoning/strategy_registry.ex:28-176` (compile-time `@map` + accessors),
`reasoning/task_profile.ex` (struct), `reasoning/compactor/config.ex` (`## Fields` moduledoc),
`test/jido_claw/reasoning/classifier_test.exs:271-295` (table-driven test generation), `mix.exs:48-49`
(`elixirc_paths(:test)` includes `test/support`).

---

## 1. `JidoClaw.RouteComposer.Stage`

`defstruct` + `@type t` (no TypedStruct). Fields from AR-2 §2; **bare names only** (no Alp-River
`@`/`?`/`#` sigils — that was `gen-catalog`'s job, not ported). Strings stay strings (atom-safety);
the only atoms are the `emit` value and the closed `guard`/`model`/`effort` enums **and the `unit`
tag**.

```elixir
# unit gains a :seed tag for the always-on triage seed, which is NOT a worker template
# (review follow-up #3 — a {:worker_template, "triage"} reference would be a Phase-1 trap).
@type unit ::
        {:seed, String.t()}
        | {:worker_template, String.t()}
        | {:skill, String.t()}
        | {:gate, String.t()}
@type emit :: :default | {:mapper, String.t()}

defstruct [
  :name, :unit, :task, :lens, :guard, :model, :effort,   # bare-atom (nil-default) fields first
  emit: :default,
  routes: [],
  input: %{required: [], optional: []},
  output: [],
  subscribes: [],
  publishes: [],
  lock: []
]
```

- `input` is `%{required: [String.t()], optional: [String.t()]}`; `lock` is
  `[%{while: String.t(), until: String.t()}]`; `guard` is `:sticky | nil`.
- Defaults reproduce the `S()` factory's conditional-key behavior in struct form — the router reads
  every field directly, no `Map.get`.
- The router never reads `task`/`lens`/`emit`/`model`/`effort` (later phases) — Phase 0 carries them
  as data; the validator checks `task` presence (adapted invariant 6). Moduledoc per `config.ex`.

---

## 2. `JidoClaw.RouteComposer.Catalog` — the representative starter catalog

A compile-time `@catalog` map `%{String.t() => Stage.t()}`, authored in Elixir — the
`StrategyRegistry` map layer *without* the `StrategyStore` overlay (deferred; the layers are
independent, `strategy_registry.ex:244-273`). Pure accessors mirroring `strategy_registry.ex`:
`all/0`, `get/1` → `Stage.t() | nil`, `names/0`, `valid?/1` — each `@spec`'d/`@doc`'d.

**Compile-time coherence guard (review follow-up #5 — fail fast, not just a test).** At the top of
the module body, after `@catalog`, run the validator at **compile time** and **raise** if it isn't
clean, so an incoherent catalog breaks the build (caught by `jidoclaw.compile_check`), not just a
test:

```elixir
case JidoClaw.RouteComposer.CatalogValidator.validate(@catalog) do
  [] -> :ok
  problems -> raise "RouteComposer starter catalog is incoherent: " <> inspect(problems)
end

# Optional Phase-1-readiness (review follow-up): the starter catalog references REAL worker
# templates, so catch typos at compile time. Kept OUT of the pure validate/1 — existence lives
# only here, via Templates.exists?/1 (agent/templates.ex:115).
for {name, %Stage{unit: {:worker_template, t}}} <- @catalog,
    not JidoClaw.Agent.Templates.exists?(t) do
  raise "RouteComposer stage #{name} references unknown worker template #{inspect(t)}"
end
```

(Compile deps `Catalog → CatalogValidator` and `Catalog → Agent.Templates` only; neither references
`Catalog`, so no cycle. **`validate/1` stays pure** — template/skill/gate *existence* is checked only
in this `Catalog` guard, never in the validator. `@after_compile` is the fallback if inline ordering
misbehaves.)

**The starter catalog — a coherent code/system pipeline.** Every consumed signal, required artifact,
and lock `while`/`until` has a declared producer (review follow-up #1 — the earlier sketch's
`plan-ready`/`plan`/lock signals were orphans and would have failed the validator). Seeds:
`@seed_signals ["request-received"]`, `@seed_artifacts ["request"]`.

| stage | unit | routes | subscribes | required in | output | key publishes | lock |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `triage` | `{:seed,"triage"}` | all 4 | `request-received` | `request` | `intent` | `code` `system` `plan-needed` `needs-tests` `significant-build` `auth-surface` `scope-shift` | — |
| `planner` | `{:worker_template,"researcher"}` | code system | `plan-needed` | `intent` | `plan` | `plan-ready` `scope-shift` | — |
| `plan-gate` | `{:gate,"plan"}` | code system | `plan-ready` | `plan` | `approved-plan` | `plan-approved` `scope-shift` | — |
| `test-author` | `{:worker_template,"coder"}` | code | `needs-tests` | `plan` | `tests` | `tests-ready` `scope-shift` | — |
| `implementer` | `{:worker_template,"coder"}` | code | `plan-ready` | `plan` | `diff` | `code-written` `scope-shift` | `[{while: needs-tests, until: tests-ready}, {while: plan-ready, until: plan-approved}]` |
| `security-reviewer` | `{:worker_template,"reviewer"}` | code | `auth-surface` | `diff` | `findings` | `findings:security` `clean:security` `scope-shift` | — |
| `quality-reviewer` | `{:worker_template,"reviewer"}` | code | `code-written` | `diff` | `findings` | `findings:quality` `clean:quality` `scope-shift` | — |
| `correctness-reviewer` | `{:worker_template,"reviewer"}` | code | `code-written` | `diff` | `findings` | `findings:correctness` `clean:correctness` `scope-shift` | — |
| `architecture-reviewer` | `{:worker_template,"reviewer"}` | code | `significant-build` | `diff` | `findings` | `findings:architecture` `clean:architecture` `scope-shift` | — |
| `fixer` | `{:worker_template,"coder"}` | code | `findings` | `diff` | `fix` | `code-written` `scope-shift` | — |

Every `{:worker_template,_}` row also carries a non-empty **`task`** (the lens/step instruction, §2
— e.g. `security-reviewer`'s `task` = *"Review the diff for auth-surface, secrets, and permission
changes; flag findings, else emit clean:security."*); the table omits the `task` column for width.
`{:seed,_}`/`{:gate,_}` rows carry **no** `task` (validator-exempt, §3 invariant 6). Without each
worker `task` the compile-time guard would fail (review follow-up #1).

Producer trace (why it validates clean): signals `plan-needed`/`needs-tests`/`significant-build`/
`auth-surface`←`triage`, `plan-ready`←`planner`, `tests-ready`←`test-author`, `plan-approved`←
`plan-gate`, `code-written`←`implementer`+`fixer`, `findings`←reviewers (bidirectional family-match
of `findings` against `findings:security` etc.); artifacts `intent`←`triage`, `plan`←`planner`,
`diff`←`implementer`. Worker templates referenced (`coder`/`reviewer`/`researcher`) **exist**
(`agent/templates.ex`); `{:seed,_}`/`{:gate,_}` are reserved shapes (inert in Phase 0). The plan-gate
lock is `{while: plan-ready, until: plan-approved}` (matches Alp River), so the implementer is gated
the moment a plan is ready until it's approved.

**Acyclic + no self-dependency.** Data edges: `triage→planner→{plan-gate,test-author,implementer}`,
`implementer→{reviewers,fixer}` — a DAG. The review→fix→re-review loop is **dynamic** (Phase 4+:
signals + drop-from-`ran`), expressed via the `findings` / `code-written` **signal** edges, **not**
data edges — so no reviewer↔fixer data cycle. No stage requires-and-outputs the same artifact (fixer:
in `diff`, out `fix`). Both are enforced by the validator (#2/#8 below), not just discipline.

This catalog backs **GAP-1/2/4** (the two-lock `implementer`) and **GAP-3** (the `significant-build`
axis → `architecture-reviewer` present while the `needs-tests` axis → `test-author` is absent). The
**minimal** lock fixtures for TC-U01–U14 live in `TestFixtures.lock_catalog/1` (Alp River's
single-`impl` style), which the router tests call directly and which need not be validator-clean.

---

## 3. `JidoClaw.RouteComposer.CatalogValidator` — structural + `check_catalog` port

`validate(catalog) :: [String.t()]` — problem strings (`[]` = clean), **sorted by stage name**.
A dedicated module (keeps per-function complexity under Credo's limit; also lets `Catalog` call it at
compile time). Constants as plain list attributes wrapped in `MapSet.new/1` at runtime (no literal
`MapSet` attributes — Dialyzer opacity, `trace/policy.ex:79-82`).

**Group 0 — structural well-formedness (review follow-up #4 — replaces the skipped `gen-catalog`
normalizer; runs FIRST, since the semantic checks assume a well-formed shape).** For each entry:
`stage.name == map_key`; `routes`/`output`/`subscribes`/`publishes` are lists of binaries; `input`
is `%{required: [binary], optional: [binary]}`; every `lock` entry is `%{while: binary, until:
binary}`; `unit` is a known-tag 2-tuple `{:seed|:worker_template|:skill|:gate, binary}`. (Shape only
— the validator does **not** resolve template/skill/gate *existence*; that's execution-time, Phase
1+.) A malformed entry yields a problem string instead of crashing the router later. **`validate/1`
short-circuits (review follow-up #3): if group 0 finds any problem, it returns those and SKIPS groups
1–8 + cycle** — a malformed `input`/`lock` would otherwise crash the coherence/cycle checks
themselves.

**Groups 1–8 — coherence** (`check_catalog.py:47-83` + AR-2/review additions):

| # | invariant | jido_radclaw |
| --- | --- | --- |
| 1 | `routes` present, non-empty, ⊆ PATHS | verbatim (`PATHS = ~w(talk sketch code system)`) |
| 2 | `scope-shift` ∈ `publishes` | verbatim |
| 3 | `milestone-scope` ∈ {local, both} | **N/A** — no such field |
| 4 | every `subscribes` is a seed signal or family-published | port (bidirectional `family_match?`) |
| 5 | every **required** input is a seed artifact or in ∪ outputs | verbatim |
| 6 | required-input stage, not exempt, has a prompt | **adapt** → a `{:worker_template,_}` stage with required input, not in `@template_exempt ["triage"]`, must have non-empty `task`; `{:seed,_}`/`{:skill,_}`/`{:gate,_}` units carry their own steps → **exempt** |
| 7 | every `lock` `while`/`until` is a seed or family-published | verbatim |
| 8 | **(review follow-up #2) self-dependency** | a stage with `required ∩ output ≠ ∅` is a problem — cycle detection alone **cannot** catch this (the toposort discards the self-pred edge, `route.py:67`), so it needs its own invariant + test |
| + | **(AR-2 §3.2 step 5) cycle detection** | reject a catalog whose producer→consumer **data** graph has a cycle |

`family_match?/2` is **BIDIRECTIONAL** (`p == sub or starts_with?(p, sub<>":") or starts_with?(sub,
p<>":")`, `check_catalog.py:38-44`) and **deliberately distinct** from the router's one-directional
`matches?/2` — **do not share one matcher** (the test pins the difference). Cycle detection calls
**`JidoClaw.RouteComposer.Graph.kahn(stages, all_names)`** and reports a problem on `{:error,
undrained}` — the **same** shared module the router's toposort uses (a `defp` can't span modules,
review follow-up #2), so there is one edge-construction implementation, not a duplicated block. Note
self-dependency (#8) is **separate** from cycle detection — `Graph.kahn` discards the self-pred edge
(`route.py:67`), so a self-loop never surfaces as a cycle and needs its own invariant.

---

## 4. `JidoClaw.RouteComposer.Router` — the pure router

A 1:1 port of `route.py` `compute_route` → `compose_route` (`already_run` → `ran`). **Public**:
`compose_route/4`, `merge_sticky/3`, `size_label/1`. All else private; each public fn `@spec`'d;
module `@moduledoc`'d.

### Result shape (AR-2 §3.1 — atom keys, atom drop-reasons)

```elixir
@type drop_reason :: :off_path | :unsatisfiable_input          # Python "off-path"/"unsatisfiable-input"
@type result :: %{
        route: [String.t()],                 # topo-sorted; flatten(waves) == route
        waves: [[String.t()]],               # Kahn levels — each a parallel cohort
        size: String.t(),                    # "empty"|XS|S|M|L|XL|XXL — a label, not a count
        triggered_by: %{String.t() => String.t()},     # in-route stage -> triggering live signal
        dropped: %{String.t() => drop_reason()},
        held: %{String.t() => [String.t()]}  # held stage -> unmet `until` signals (always present)
      }
```

### The five steps (`route.py` order; cite line refs in comments)

1. **trigger** (`:110-120`) — for each stage **not in `ran`**, first `subscribes` topic matching
   `live` (OR-membership, declaration order, family-prefix via `matches?/2`) → `triggered_by`.
2. **route-filter** (`:123-132`) — `live_paths = MapSet.intersection(live, MapSet.new(@paths))`;
   empty (pre-triage) ⇒ no-op; else keep iff `routes ∩ live_paths ≠ ∅`. Dropped ⇒ `:off_path`.
   **String sets both sides.**
3. **drop-unsatisfiable** (`:135-152`) — **fixed-point loop**: `produced = ∪ outputs of kept`; drop
   any kept stage with a `required` input not in `available` and not in `produced`; repeat until
   stable. **Optional inputs never consulted here.**
4. **locks → held** (`:101-107`, `:171`) — active iff `matches?(while, live) and not matches?(until,
   live)` — **`live` only, never `available`**. Held if **any** entry active. Remove held, then
   **re-run drop-unsatisfiable**. `held[stage] = [until of each still-active entry]`.
5. **topo-sort** (`:55-91`) — via **`Graph.kahn(stages, runnable)`** (the shared module): Kahn by
   levels, edges from `required + optional` inputs **only when the producer is in-route**, each
   frontier **alpha-sorted**; each frontier *is* a wave.

`dropped` (`:174-179`) iterates the **full `triggered`** set; held stages are **never** in `dropped`.
`triggered_by` is keyed **only on in-route stages**.

### Helpers & backstop

- `matches?/2` (private, `:94-98`) — **one-directional** family prefix:
  `topic == sub or String.starts_with?(topic, sub <> ":")` over `live`.
- `size_label/1` (public, tested directly, `:37-43`) — multi-clause guard fn:
  `<=0→"empty"`, `<=1→"XS"`, `<=3→"S"`, `<=6→"M"`, `<=10→"L"`, `<=15→"XL"`, else `"XXL"`.
- **Cycle backstop**: the validator rejects cycles at load, so `Graph.kahn` should never return
  `{:error, _}`; if it does, `compose_route` **raises** `ArgumentError` naming the undrained stages —
  **not** route.py's silent trailing wave (AR-2 §3.2 step 5: *"never a silently-runnable wave"*).
- **Credo decomposition**: the Kahn toposort lives in `Graph` (`producers/2` → `precedence_edges/2`
  → `kahn/2`, the last public), shared with the validator — which also keeps each fn under
  `max_complexity: 11` / `max_nesting: 3`. Because `Graph.kahn/2` is **public**, it carries a real
  `@doc` + `@spec` over a named result type:
  `@type kahn_result :: {:ok, [String.t()], [[String.t()]]} | {:error, [String.t()]}` (sorted
  `order`, `waves` on success; the undrained stage names on a cycle).

### `merge_sticky/3` (separate post-pass, `:190-207`) — **DISPLAY route, not dispatch route**

Keep `prev_names` stages that are `guard: :sticky` and **no longer** in `result.route`; if none, return
`result` unchanged; else re-toposort `route ∪ kept`, override `route`/`waves`/`size`, add `:sticky_kept`.
`held`/`dropped`/`triggered_by` carried over **unchanged**. Tolerant of a `prev_name` absent from the
catalog.

> **Module-doc warning to carry forward (review smaller-note / AR-2 §3.3).** `compose_route`'s own
> route never holds a `ran` stage (trigger skips `ran`), but `merge_sticky` deliberately re-adds
> already-run sticky stages — so the merged route is the **display/persistence** route, **not** a
> dispatch list. The Phase-1 loop must filter each merged wave to `stage not in ran` before it
> executes or tests convergence; folding `merge_sticky` straight into `hd(waves)` would re-run a
> sticky stage and **never converge**. This is documented on `merge_sticky/3` now so the distinction
> isn't lost when the loop is built.

---

## 5. Test port (DRY — table-driven + shared fixtures)

`test/support/jido_claw/route_composer/fixtures.ex` (`JidoClaw.RouteComposer.TestFixtures`,
`import`ed): `stage/1` (the `S()` factory — keyword opts → `%Stage{}`), `lock_catalog/1`
(`test_route.py:344-358`), `synthetic_catalog/0` (the 8-stage `CATALOG`, `test_route.py:36-81`), and **shared
assertion helpers** (`compose/3` wrapping `Router.compose_route`, `assert_in_route/2`,
`assert_held/3`).

**Structure for the clone gate (review follow-up #6).** I will **not** rely on "ExDNA scans `lib/`
only" — `.credo.exs` includes `test/` and runs ExDNA + reach `CloneConsistency`. Instead, keep the
port **structurally DRY**: route every fixture through `TestFixtures`, and **generate** the uniform
buckets table-driven (a `@cases` list + one `for row <- @cases do test "#{row.name}" do … unquote …
end`, per `classifier_test.exs:271-295`) — one named ExUnit case per row (full failure isolation) with
no duplicated block. Reserve explicit `test` blocks for genuinely distinct multi-assertion scenarios.
The real check is `mix precommit`; the escape hatch if a smell still false-positives is
`# reach:disable-for-this-file`.

### `router_test.exs` (`use ExUnit.Case, async: true` — pure, no GenServer)

Port the **~54 synthetic tests**, grouped by `describe`, table-driven where uniform:

- **core routing** (`test_route.py:88-164`, ~11) — OR-trigger, AND-required drop, topo order, optional-
  orders-never-drops, routes filter off-path, no-path-skips-filter, multi-path, size-label-from-count
  (the `size` key is the *label*, not the raw count), grow/shrink, sticky persistence, determinism.
- **wave scheduling** (`:167-199`, ~5) — flatten==route, independent-share-wave, producer/consumer
  split, single=one-wave, empty=empty.
- **locks & held** (TC-U01–U14, `:366-555`, 14, table-driven over `lock_catalog/1`) — held-absent,
  route/held disjoint, release-on-until, inactive-when-while-absent, two-locks both/one/none,
  family-prefix while & until, held-payload-is-list (never `"deadlock"`), held-drops-downstream,
  held-key-always-present, cheap-path. (TC-U15–U21 are gen-catalog/check_catalog — excluded; the
  check_catalog ones move to the validator suite.)
- **family-prefix** — the one-directional `matches?/2` cases.
- **`merge_sticky/3`** — `sticky_kept` added, `held`/`dropped` carried over, no-op when none sticky.
- **`size_label/1`** — the threshold table (`(1)→XS`, `(2)→S`, `(5)→M`, …).

### GAP scenarios (4) — against `Catalog.all()` (the real starter catalog)

Re-target Alp River's GAP-1–4 (`test_route.py:2277-2384`, originally against its real catalog) at the
starter catalog's two-lock `implementer` + the lens axes:

- **GAP-1** — `live={code, plan-ready, needs-tests}`, `available={plan}` ⇒ implementer **held**, unmet
  lists **both** `tests-ready` and `plan-approved`.
- **GAP-2** — `live={code, plan-ready}`, `available={plan, plan-approved}` (stale **artifact**, not a
  live signal) ⇒ implementer **held**, `plan-approved` unmet (locks read `live` only).
- **GAP-3** — `live={code, significant-build, code-written}`, `available={diff}` ⇒
  `architecture-reviewer` (+ quality/correctness) in route, `test-author` (needs-tests axis) **absent**.
- **GAP-4** — `live={code, plan-ready, plan-approved:auto}`, `available={plan}` ⇒ implementer **in
  route**, not held (family-prefix release).

### `catalog_validator_test.exs` + `catalog_test.exs`

- **`validate(Catalog.all()) == []`** (also enforced at compile time, §2).
- One test per **firing** invariant: bad `routes`, missing `scope-shift`, unsatisfiable required input,
  orphan `subscribes`, orphan lock `while`/`until`, worker stage with required input but empty `task`,
  **self-dependency** (`required ∩ output ≠ ∅`), a **cyclic** catalog, and each **structural**
  malformation (name≠key, non-list field, bad `input` shape, bad `lock` shape, unknown `unit` tag).
- `family_match?` (bidirectional) vs `matches?` (one-directional) pinned.
- `Catalog` accessors: `get/1`, `names/0`, `valid?/1`.

---

## 6. `mix precommit` checklist (the "done" bar)

`precommit` (`mix.exs:251`, `:test`): `jidoclaw.compile_check` → `system_prompt.check` →
`deps.unlock --unused` → `format --check-formatted` → `reach.check --arch --smells --strict` →
`credo --strict` → `dialyzer` → `test`.

- **Warning-clean compile** — allowlist is empty (`compile_check.ex:30`); every warning fatal. The
  starter-catalog compile-time guard (§2) surfaces an incoherent catalog **here**.
- **Specs + docs + complexity** — `@moduledoc` per module, `@spec` per public fn, lines ≤ 120,
  cyclomatic/perceived ≤ 11, nesting ≤ 3 (drives the toposort + validator decomposition).
- **No slop** — no narrator/step/obvious comments, no `# TODO`. The validator assembles problem
  strings with `Enum.map_join/3` (or `IO.iodata_to_binary/1`), **never** `Enum.reduce` + `<>` (the
  ExSlop `StringConcatInReduce` ↔ reach `StringBuilding` double-flag; memory
  `project_credo_reach_string_building`).
- **Dialyzer** — precise `@type result`/`@spec`s; `MapSet.t(String.t())` typespecs; constant sets via
  `MapSet.new(@list_attr)` at runtime.
- **Clone gates** — handled by the DRY test structure above, **not** by assuming scan scope.
- **No new deps** — Phase 0 needs none → `deps.unlock --unused` green.

---

## Verification (end-to-end)

1. **Ported suite** — `mix test test/jido_claw/route_composer/` → router + validator + catalog tests
   pass (the ~54 + 4 GAP + validator/structural/self-dep cases are the acceptance spec for §3).
2. **Single-test iteration** — `mix test …/router_test.exs:<line>` while porting.
3. **Compile-time guard** — temporarily break the starter catalog (drop a producer) and confirm
   `mix compile` **fails** with the coherence message (then revert) — proves fail-fast, not just a test.
4. **Purity / determinism** (Tidewave `project_eval`):
   `Router.compose_route(Catalog.all(), MapSet.new(["code","plan-ready"]), MapSet.new(["plan"]), MapSet.new([]))`
   twice → identical; and `CatalogValidator.validate(Catalog.all())` → `[]`.
5. **Cross-check vs source** (optional): run `python3 ~/workspace/claws/alp-river/hooks/tests/test_route.py`
   and compare a few `compute_route` outputs to the Elixir port on the same synthetic catalogs.
6. **The hard bar** — `mix precommit` green.

---

## Key reuse references

- Port source: `~/workspace/claws/alp-river/hooks/{route.py, check_catalog.py, tests/test_route.py}`,
  `…/doctrine/{CATALOG,SIGNALS}.md`.
- Patterns: `reasoning/strategy_registry.ex:28-176`, `reasoning/task_profile.ex`,
  `reasoning/compactor/config.ex`, `test/jido_claw/reasoning/classifier_test.exs:271-295`,
  `test/support/jido_claw/`, `mix.exs:48-49`.
- Precommit: `mix.exs:251`, `lib/mix/tasks/jidoclaw.compile_check.ex:30`, `.credo.exs`, `.reach.exs`.
- Memory: `project_precommit_zero_findings`, `project_credo_reach_string_building`,
  `project_exslop_duplicate_clone_seams`, `feedback_permanent_test_over_spot_check`.
