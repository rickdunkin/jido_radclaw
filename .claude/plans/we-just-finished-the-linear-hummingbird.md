# AR-4 Review Fixes — Guarantee silent-converge signals + harden producers

## Context

The AR-4 self-heal fixer loop just shipped, and a code review raised one **[P1]**:

> **The fixer can omit the mandatory `code-written` signal and skip baseline re-review.**

**The finding is validated.** The loop's re-review set is derived *solely* from the
signals the fixer actually emitted (`fix_rerun_set/3` → `domain_touched_stages/3`,
`route_composer.ex:2072`/`2098`). `quality-reviewer` and `correctness-reviewer` both
subscribe to `code-written` (`catalog.ex:156`/`168`), so a fix that re-touches code should
force *both* code-domain lenses to re-review (the "baseline re-review"). But nothing
enforces `code-written` in code — `OutputSchema.fixer_result/0` validates `signals` only as
a string list (`output_schema.ex:46`); the "always emit `code-written`" rule lives only as
prose. If a real LLM fixer omits it (verified: `signals: ["auth-surface"]` maps cleanly),
only the *flagged* lens re-runs (via `open_flagged_stages/1`); a clean lens like correctness
is never re-invalidated, so the run **converges with a fix-introduced regression undetected**.

**Same root cause reaches the production producers.** While verifying, I found the production
`Researcher` and `Coder` (which backs both `implementer` and `test-author`) lack a `signals`
field, so a real `Catalog.all()` run emits none of its trigger signals — only stubs do (the
AR-4 plan itself notes "the production Coder emits nothing"). Grounding the severity in the
loop's terminal rule (`loop.ex:84-90`: `held>0 → :deadlock`, else `lenses_clean? → :converged`,
where `lenses_clean?` is **vacuously true** when no lens-carrying stage is in `ran`):

| omitted signal | producer | terminal on omission | severity |
| --- | --- | --- | --- |
| `plan-ready` | planner (**no lens**) | not held, `lenses_clean?` vacuous → **`:converged`** | **silent false-converge** |
| `code-written` | implementer / fixer (no lens) | not held, vacuous (or only the flagged lens re-runs) → **`:converged`** | **silent false-converge** |
| `tests-ready` | test-author | implementer stays **held** → **`:deadlock`** | honest, surfaced |

So `plan-ready` and `code-written` omissions converge *silently* (the implementer case is
worst: zero reviewers fire → "clean" with no review); `tests-ready` omission deadlocks
*honestly*. The fixer P1 is one instance of the silent class.

**Decisions (confirmed with the user, refined through review):** enforce the
silent-converge signals via **auto-injection** (a producer that completes definitionally
emitted its completion signal — implied, not optional self-report), inject **exactly the
signals whose omission silently converges** (`plan-ready` + `code-written`, *not* the
honestly-deadlocking `tests-ready` nor the conditional domain signals), and take the
**broader scope**: give the producers a `signals` field so a real run self-reports too.

**Outcome:** neither the fixer (the P1) nor the planner/implementer can silently
false-converge by omitting a completion signal; `tests-ready` and the conditional signals
are self-reported through the new fields. `mix precommit` green is the bar.

---

## Design

### 1. Completion-signal injection (the guarantee — resolves the P1 + the silent-converge class)

Inject **only the signals whose omission silently converges** into the emitting producer's
emission, **before the fold**, idempotently:

```elixir
# The two completion signals whose omission yields a SILENT :converged (loop.ex:84-90):
# a no-lens producer that runs but doesn't emit them is not `held`, so `lenses_clean?`
# is vacuously true. `tests-ready` is excluded (omission → honest :deadlock, and a
# blocked test-author must NOT auto-release the implementer's lock). The conditional
# domain signals (scope-shift / auth-surface / significant-build) are excluded too —
# the loop can't infer what a producer chose to touch, so those stay self-reported.
@completion_signals ["plan-ready", "code-written"]

# Shadow `emissions` at the TOP of handle_wave_value({:ok, emissions}, ...),
# before Fold.fold (route_composer.ex:1310):
defp enforce_completion_signals(emissions, state) do
  Enum.map(emissions, fn %StageEmission{stage: name, signals: sigs} = e ->
    with {:ok, stage} <- Map.fetch(state.catalog, name),
         [_ | _] = inject <- completion_signals_for(stage),
         true <- on_live_route?(stage, state.live) do
      %{e | signals: Enum.uniq(sigs ++ inject)}
    else
      _ -> e
    end
  end)
end

# Role-based, never a hardcoded template name. `lens: nil` makes "non-reviewer"
# explicit (the user's polish point); `rv != true` excludes the reverse-verify
# loop; `publishes ∩ @completion_signals` selects exactly what the stage declares.
defp completion_signals_for(%Stage{unit: {:worker_template, _}, reverse_verify: rv, lens: nil, publishes: pub})
     when rv != true,
     do: Enum.filter(@completion_signals, &(&1 in pub))

defp completion_signals_for(%Stage{}), do: []
```

Maps exactly onto the silent-converge producers and excludes everything else:

| Stage | `publishes ∩ @completion_signals` | injected |
| --- | --- | --- |
| planner | `["plan-ready"]` | plan-ready (gates plan-gate / safety-gate / system-executor) |
| implementer | `["code-written"]` | code-written (triggers quality + correctness) |
| fixer | `["code-written"]` | code-written (the P1 — drives the baseline re-review) |
| test-author | `[]` (publishes `tests-ready`, not in the set) | none — self-reports (omission → honest `:deadlock`) |
| reviewers | — (`lens != nil`) | none |
| sketch-build / -exec / system-executor | `[]` (publish only `scope-shift`) | none (data-edge ordered / signal-free) |

**Why before `Fold.fold` (durably safe — verified):** recovery rebuilds state *purely* by
projecting the parent's durable `WorkflowEvent` log (`Projection.project/2`), never by
re-reading child emissions. A signal injected into `emissions` before `route_composer.ex:1310`
flows into `next_fold.live` → becomes a `signals_published` delta via `wave_deltas/3` (`:1479`,
a pre/post `live` diff) → is welded into `commit_wave` → restored on restart. The *same*
`emissions` feed `decide_rerun/2`, so the fixer's domain-touched re-review set sees
`code-written` too. One point fixes live state, durability, the never-ran summon, AND the
re-review derivation.

Idempotent (`Enum.uniq`) → a no-op when the model already emitted the signal, so every
existing test stays green. **Blocked/partial producers self-guard:** an injected completion
signal whose stage produced no output artifact (a blocked planner emits no `plan`, a blocked
implementer no `diff`) leaves the downstream stage *drop-unsatisfiable* on its required input
(the router drops it) — exactly how reviewers already gate on `diff` — so injection never
advances an empty producer. (`tests-ready` is deliberately *not* injected precisely because
the implementer's required input is `plan`, not `tests`, so a blocked test-author would not
be self-guarded — its honest `:deadlock` is the correct outcome.) `status` is not even on
`StageEmission`, so no status-gating is needed.

### 2. Producer `signals` fields + model steering (self-report; the only path for `tests-ready`)

Injection covers the silent-converge baselines; the producers must still self-report — it is
their contract, it is the **only** way `tests-ready` and `scope-shift` are emitted, and the
user asked for it. Give the two producer schemas a `signals` field (modeled on
`fixer_result/0`), **optional** so a transient omission of an *injected* signal falls back to
injection rather than a validation failure, and so the shared schema's other consumer is
untouched:

- **`output_schema.ex`** — factor the shared builder fields into a private `builder_fields/0`:
  - `builder_result/0 = Zoi.object(builder_fields())` — unchanged shape; **stays the
    SystemExecutor schema** (its "NO signals field / data-edge-ordered" contract stays true).
  - new `coder_result/0 = Zoi.object(Map.put(builder_fields(), :signals,
    Zoi.optional(Zoi.array(Zoi.string()))))` — the Coder schema. Factoring (vs a copy) avoids
    the ExSlop clone gate (project memory).
- **`coder.ex`** — `output:` schema `builder_result()` → `coder_result()`. Drives `code-written`
  (implementer, also injected) and **`tests-ready`** (test-author — *only* via this field) +
  conditional `scope-shift`.
- **`researcher.ex`** — add `signals: Zoi.optional(Zoi.array(Zoi.string()))` to the inline
  `Zoi.object` (`:24-38`; `Zoi.optional` in the map form is the existing `artifacts/0` pattern).

**Model steering (the user's point — optional fields alone won't steer the model):** update the
`description:` of `Coder` (`coder.ex:13`) and `Researcher` to state they return a `signals`
list, and reconcile/extend their **doctrine slices** to instruct populating it — emphasizing
`tests-ready` for the test-author role (its only emission path) and `scope-shift` when the
change outgrows the plan. The catalog `task` prose already nudges each emit
(`:81`/`:115`/`:125`); keep it (belt-and-suspenders with injection).

### 3. Doc / comment reconciliation (no stale invariant text)

Reconcile the now-false "the production Coder emits nothing" / "builder_result is shared by
Coder and SystemExecutor" statements: `output_schema.ex` moduledoc + `builder_result/0` doc,
`fixer.ex` moduledoc (the "a coder fixer could not drive explicit_signals" rationale —
`coder_result` now can, so the fixer's first-class justification narrows to its **own doctrine
contract** + domain self-report), `catalog.ex` implementer/planner task notes (their completion
signal is loop-guaranteed), and a clear "why" comment on the injection helper. Leave
SystemExecutor's "NO signals field" comments (`worker_output_schemas_test.exs:297`,
`system_executor.ex`) intact — they stay true.

---

## Changes by file

**Production:**
- `lib/jido_claw/route_composer/route_composer.ex` — `@completion_signals`,
  `completion_signals_for/1`, `enforce_completion_signals/2`, its call atop
  `handle_wave_value({:ok, emissions}, …)`, rationale comment; reconcile touched moduledoc
  notes. (Reuses `on_live_route?/2` `:2150`; mirrors the `fixer_stage?/1` role-predicate style.)
- `lib/jido_claw/agent/workers/output_schema.ex` — `builder_fields/0` + `coder_result/0`; doc reconciliation.
- `lib/jido_claw/agent/workers/coder.ex` — `coder_result()` schema + `description:` mentions `signals`.
- `lib/jido_claw/agent/workers/researcher.ex` — optional `signals` field + `description:` mentions it.
- `lib/jido_claw/agent/workers/fixer.ex` — moduledoc rationale reconciliation.
- `lib/jido_claw/route_composer/catalog.ex` — implementer/planner task notes (light).
- `lib/jido_claw/doctrine.ex` (+ any coder/researcher `priv/defaults/doctrine/*` slice) — instruct populating `signals`.

**Tests / fixtures:**
- `test/support/jido_claw/route_composer/composer_stubs.ex` — make the hardcoded fixer clause
  (`:279-284`) read `Application.get_env(:jido_claw, :route_composer_fixer_signals,
  ["code-written","auth-surface"])`, mirroring the reviewer/verifier env pattern (counter-free,
  non-contiguous → no clone-gate trip).
- `test/jido_claw/route_composer/composer_self_heal_loop_test.exs` —
  - **P1 regression:** fixer signals `["auth-surface"]` (omit `code-written`) → the single Hook-F
    `stages_invalidated.payload["stages"]` STILL includes `correctness-reviewer` and the run
    converges (the injection proof — absent without the fix). Add the key to `on_exit`.
  - **Implementer injection:** override `:route_composer_stub_outputs` so `coder` emits
    `signals: []` → `quality-reviewer` + `correctness-reviewer` ∈ `summary.ran`.
  - **Planner injection:** stub `researcher` emits `signals: []` → the run advances past planning
    (not a vacuous terminal) — the corrected-overclaim guard.
- `test/jido_claw/agent/workers/worker_output_schemas_test.exs` — assert `coder_result` parses
  `signals: ["code-written"]`/`["tests-ready"]` as strings and Researcher parses
  `signals: ["plan-ready"]`; keep the no-`signals` Coder/SystemExecutor samples green.
- `test/jido_claw/route_composer/default_mapper_test.exs` — a coder/builder-shaped output with
  `signals: ["tests-ready"]` maps the signal (mirrors the fixer mapper test); omission → `[]`.

---

## Precommit risk register (`mix precommit` must be green)

- **ExSlop/ExDNA clone gate** (top risk): `builder_fields/0` factoring (no `coder_result`
  near-clone); the fixer-signals stub knob is counter-free and non-contiguous from the
  reviewer/verifier clauses.
- **No terminal/Dialyzer union work** — no terminal symbol added; `completion_signals_for/1` /
  `enforce_completion_signals/2` are total. Low Dialyzer risk.
- **No `String.to_atom`** — every signal name is a string literal through string-keyed stores /
  `Zoi.array(Zoi.string())`.
- **Shared-schema blast radius** — `builder_result/0` keeps SystemExecutor's exact shape; only
  `Coder` moves to `coder_result/0`; an *optional* field is backward-compatible elsewhere.
- **Catalog validator** — untouched; every injected signal is already in its stage's `publishes`,
  so injection never produces an undeclared signal.
- **Credo/reach strict** — the helper is a simple `Enum.map`; no list-built strings. Run the
  **full** `mix precommit`, never piped through `tail` (project memory).

---

## Verification (definition of done)

1. **`mix precommit` green** — strict compile, format, credo, reach strict, dialyzer, full test.
2. **P1 regression** — fixer emits `["auth-surface"]` (no `code-written`): Hook-F still
   re-invalidates `correctness-reviewer`, run converges. Confirm it FAILS on `main`.
3. **Implementer injection** — stub coder emits `signals: []`: quality + correctness still run.
4. **Planner injection** — stub researcher emits `signals: []`: the run advances past planning
   (no vacuous `:converged`) — the corrected overclaim covered by a real guarantee.
5. **`tests-ready` self-report** — `coder_result` carries `tests-ready` through the mapper, and a
   test-author that emits it releases the implementer lock (while omission honestly `:deadlock`s,
   per `loop.ex` — *not* injected).
6. **Schema contracts** — `worker_output_schemas_test` confirms `coder_result`/Researcher accept
   `signals` strings while no-`signals` samples (incl. SystemExecutor) stay valid.
7. **Mapper** — `default_mapper_test` confirms a builder/coder-shaped `signals` flows through
   `explicit_signals/1`, omission → `[]`.
8. **Existing AR-4 suite unchanged** — converge / summon / stale-feedback / scoping / exhaustion
   stay green (injection idempotent).
9. **Optional real-catalog E2E** — drive `Catalog.all()` on the code path with stubs emitting
   only the self-reported `tests-ready` (planner/implementer/fixer emit nothing, relying on
   injection), park+approve the plan-gate (model on `composer_system_loop_test.exs`), and assert
   planner → test-author → implementer → reviewers → fixer → `:route_converged`. Capstone proof;
   split to a follow-up only if the gate orchestration outgrows this pass.
