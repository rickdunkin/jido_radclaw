# AR-9 program, unit 1: tiering seam (PR-1) + premises threading (PR-2)

## Context

`docs/plans/unadopted-next-five/README.md` item 3 is the AR-9 judge-panel plan wave
(alp-river V2 AR-9), which explicitly pulls in two riders: alp-river unadopted #1
(per-stage model/effort tiering) and #3 (hand premises to stage agents). The doc
suggests 4 PRs; this unit covers **PR-1 + PR-2 only** — the two S-sized seams that are
behavior-neutral by default and that the plan wave (PR-3/PR-4, next unit) consumes.

**Scope decisions** (asked; no response within 60s — proceeding on my recommendations,
redirect at approval if wrong):

1. **Scope**: PR-1 + PR-2 as one unit. PR-3/PR-4 + the item-4 doctrine slice become the
   next unit with its own plan.
2. **Effort knob**: wire `effort` end-to-end as `llm_opts: [reasoning_effort: e]`
   (ReqLLM-canonical; providers translate or ignore — today's ollama models ignore it).
3. **Telemetry rider**: include the optional per-stage prompt-size telemetry (severable
   step 7).

**Why the design below (key discovery).** The README's PR-1 sketch says "WaveBuilder
reads the `%Stage{}` model/effort fields at spawn time" — but there is **no spawn-time
model seam**: worker model is compile-time (`use JidoClaw.Agent.Defaults, model: :fast`
→ `strategy_opts()[:model]` wins at server init, `deps/jido_ai/.../react/strategy.ex:2219`),
and `ask/3` silently drops a `:model` opt. The only per-turn seam jido_ai provides is a
`request_transformer` returning `%{model: ..., llm_opts: ...}` overrides
(`deps/jido_ai/.../react/request_transformer.ex:14-38` documents per-turn model selection;
runner applies via `Jido.AI.resolve_model/1`, `runner.ex:378-396`). That seam is already
occupied by `JidoClaw.Reasoning.Compactor.RequestTransformer` — which is fine:
`Compactor.existing_transformer_collision?/1` treats its own module as non-foreign
(`compactor.ex:692-698`), `install_overrides` *adds* to `tool_context` rather than
replacing it (`compactor.ex:700-718`), and the transformer already reads app keys out of
`runtime_context` (= the ask's `tool_context` enriched, `runner.ex:102,815-824`). So the
tier rides `tool_context` under a dedicated namespaced key and is applied by the **one
transformer the app already owns** (extended in place — renaming ripples compactor
tests/docs for zero behavior).

**Safety property (worded precisely)**: runtime behavior is unchanged **today** because
no catalog stage declares `model`/`effort`. Once a stage declares `effort`, provider
behavior may change even while `:fast`/`:capable` resolve to the same model —
`reasoning_effort` is a canonical ReqLLM option (`deps/req_llm/lib/req_llm/provider/options.ex:129`).
A `model:` declaration alone stays additionally inert until the operator re-points
`:capable` (`config.exs:163`). Default premises are `%{}` → empty render →
byte-identical prompts.

*Plan-review findings (4) incorporated 2026-07-02: renderer totality, wider docs sweep
(code moduledocs + V1/plan docs + AGENTS.md), this effort-caveat wording, bounded-inspect cap.*

**Constraints**: greenfield (no migration/compat concerns). Nothing gets committed —
all changes stay unstaged. Done = `mix precommit` passes (run directly, never piped).

---

## PR-1 — per-stage model/effort tiering seam

### Step 1 — WaveBuilder conditionally carries tier into AgentStep options

Modify `lib/jido_claw/route_composer/wave_builder.ex` `add_stage_step/3` (:146-164):
append tier keys to the existing options list **only when non-nil** (the present-nil
`Map.get` trap — conditionally-put on write, test the real builder output):

```elixir
options = [template: ..., task: ..., ...existing...] ++ tier_opts(stage)

defp tier_opts(%Stage{model: nil, effort: nil}), do: []
defp tier_opts(%Stage{model: model, effort: effort}),
  do: Enum.reject([model: model, effort: effort], fn {_k, v} -> is_nil(v) end)
```

Tests (red first) in `test/jido_claw/route_composer/wave_builder_test.exs`:
- non-tiered stage → `refute Keyword.has_key?(options, :model)` / `:effort` (byte-identity guard);
- `TestFixtures.stage(..., model: :capable, effort: :high)` → both present;
- model-only / effort-only → only that key present.

### Step 2 — AgentStep forwards tier; AgentRunner threads it into tool_context + ask opts

- `lib/jido_claw/skills/steps/agent_step.ex` `run/3` (:51-72): read optional
  `:model`/`:effort` from options, pass as a new trailing keyword to
  `AgentRunner.run/6` (nil halves rejected). Saga-cleanup call (:134) stays `run/4`.
- `lib/jido_claw/skills/steps/agent_runner.ex`:
  - `run/5` → `run/6` with trailing `tier \\ []` (only `agent_step.ex:72` uses arity 5;
    iterative_step.ex:188/225 + all tests use arity 4 — no caller breaks). Update `@spec`.
  - After the existing `:agent_template` put (:69-70): `maybe_put_tier(tool_context, tier_map)`
    — puts `%{model: m, effort: e}` (non-nil halves only) under
    `RequestTransformer.stage_tier_key()`; **unchanged map when tier is empty**.
  - `run_step_async/7` (:247): `ask_opts = [request_id: ..., tool_context: ...] ++ transformer_opt(tool_context)`
    where `transformer_opt/1` returns `[request_transformer: JidoClaw.Reasoning.Compactor.RequestTransformer]`
    iff the tier key is present, else `[]`. (Guarantees the transformer runs even when
    compaction is `:off`/skipped; same module ⇒ no Compactor collision. Sync/stub path
    carries the tier in tool_context but adds no transformer opt — composer waves use
    real `ask/3` workers; note in a comment.)

Test support: extend `test/support/echo_ask_stub.ex` to also report its received opts
(mirror `EchoStub`'s send-to-target pattern; default target `self()` keeps existing
tests green).

Tests (red first) in `test/jido_claw/skills/steps/agent_runner_test.exs`:
- non-tiered run → opts have **no** `:request_transformer`, tool_context has **no** tier key;
- tiered `run/6` `[model: :capable, effort: :high]` → transformer opt present, tier map
  under `stage_tier_key()` in tool_context.

### Step 3 — Extend `Compactor.RequestTransformer` to apply the tier

Modify `lib/jido_claw/reasoning/compactor/request_transformer.ex`:
- add `@stage_tier_key :__jido_claw_stage_tier__` + public `stage_tier_key/0`
  (mirrors `runtime_context_key/0`);
- in `transform_request/4`, compute `tier_overrides(Map.get(runtime_context, @stage_tier_key))`
  → `%{}` | `%{model: m}` | `%{llm_opts: [reasoning_effort: e]}` | both — and merge into
  the returned overrides (disjoint keys with the compaction `:messages` override);
- moduledoc: this is now the app's single **composed** transformer (compaction + stage
  tiering), and the `@stage_tier_key` contract.

No tier key ⇒ returns exactly today's `{:ok, %{}}` / `{:ok, %{messages: ...}}` — all
existing compactor tests stay green.

Tests (red first) in `test/jido_claw/reasoning/compactor/request_transformer_test.exs`
(pure `transform_request/4` calls): tier without snapshot → `{:ok, %{model: :capable,
llm_opts: [reasoning_effort: :high]}}`; tier + snapshot → `:messages` AND tier keys;
model-only / effort-only halves; **no tier → unchanged behavior** (regression guard).

Plus a **compactor-preserves-tier regression test** in
`test/jido_claw/reasoning/compactor/compactor_test.exs` covering the live composition
point (AgentRunner pre-sets the transformer, then `Compactor.maybe_compact/3` runs):
action with `request_transformer: RequestTransformer` AND
`tool_context[RequestTransformer.stage_tier_key()]` set → `maybe_compact/3` returns ok
(no `:existing_transformer_collision`) and the rewritten params **preserve the tier key**
while adding any snapshot key — pins the "same module ⇒ no collision, install_overrides
adds rather than replaces" claim the seam relies on.

### Step 4 — Composer-level integration test (tier reaches the worker)

No stub change needed: the tier rides `tool_context`, and the existing
`:route_composer_capture_context` hook (`composer_stubs.ex:100-105`) already exposes it.
Test alongside `composer_loop_test.exs`: catalog with one tiered stage → run a wave →
captured tool_context for that stage carries the tier map; a non-tiered stage's doesn't.

---

## PR-2 — premises threading into stage task context

### Step 5 — New `JidoClaw.RouteComposer.PremisesContext`

Create `lib/jido_claw/route_composer/premises_context.ex` with `render(term()) :: String.t()`
— **total over any term**, because `create_parent_run/1` persists `:premises` through
`json_safe/1` (`route_composer.ex:481`) and state restores the durable value directly
(`:1037`) before `run_built_wave/5` (`:1487`) calls the renderer: a list/string/malformed
durable value must render, not FunctionClauseError-crash the wave.
- `nil` / empty map / **any non-map term (catch-all)** → `""` (fail-open to no premises
  block — same blind self-reporting as today, never a crashed wave);
- non-empty map → `"### Premises"` + deterministic sorted `- **key**: value` lines + one
  instruction line: if your work contradicts a premise, **include `scope-shift` in your
  `signals` output** (matches the worker Zoi schemas' typed `signals` field — don't
  suggest a direct SignalBus action);
- non-binary values (front_door premises include nested maps, `front_door.ex:673-687`)
  coerced via **bounded** `inspect(value, limit: ..., printable_limit: ...)` — bound at
  the source, don't build a huge string first;
- then one small UTF-8-safe **byte** cap helper of deliberately different shape/name from
  `ArtifactContext`'s (idiomatic solution first; differentiate naming/shape to satisfy
  the ExSlop clone check — never let clone-avoidance pick the algorithm).

Tests (red first): `test/jido_claw/route_composer/premises_context_test.exs` — empty/nil
→ `""`; **non-map premises (list, binary, integer) → `""` without raising**; sorted
deterministic output with header + instruction line; nested-map value bounded, doesn't
crash; oversized value respects the byte cap on a multibyte boundary.

### Step 6 — Compose premises into the per-wave `:extra_context`

Modify `lib/jido_claw/route_composer/route_composer.ex` `run_built_wave/5` (:1487-1505):
build `[PremisesContext.render(state.premises), artifact_context]`, reject `""`, join
with `"\n\n"`, pass to `run_reactor/3`. Comment that gate waves (`run_gate_wave`, :1411)
intentionally exclude premises (human gates don't self-report `scope-shift`).

Empty premises ⇒ `extra_context == artifact_context` byte-identically. Recovery path is
free: `build_start_opts` already restores `config["premises"]` into state (:827), and the
seam reads `state.premises` at wave time.

Test support: extend `StubWorker.ask/3` (`composer_stubs.ex:76`) with a **parallel**
task-capture hook — bind the currently-ignored `task`, send `{:wave_task, template, task}`
when `:route_composer_capture_task` is a pid. Do not alter the existing
`{:wave_context, ...}` tuple. (If ExSlop flags the near-clone of `maybe_capture_context/2`,
fold both into one `maybe_send/2` helper — but then migrate both call sites, no delegate.)

Tests (red first), composer integration: parent seeded with `premises: %{"risk" => "low"}`
(the `recoverable_parent/2` extra-opts path, `fixtures.ex:838-844`) → worker wave →
`assert_receive {:wave_task, _, task}` with `task =~ "### Premises"` and `=~ "risk"`;
companion default-premises run → `refute task =~ "### Premises"` (byte-identity guard).

---

## Step 7 — OPTIONAL/SEVERABLE: per-stage prompt-size telemetry (AR-11 evidence rider)

In `agent_step.ex` after `full_task` assembly (:70), gated on `catalog_stage_name`
(composer stages only, skill steps silent):

```elixir
:telemetry.execute([:jido_claw, :composer, :stage_prompt],
  %{bytes: byte_size(full_task)}, %{stage: catalog_stage_name, template: template})
```

(The README suggests wave_builder, but the real assembled prompt only exists in
AgentStep.) Mirrors existing `:telemetry.execute/3` usage (`front_door.ex:863`).
Test: attach handler, run a wave, assert event fires with `bytes > 0` + stage metadata.
Drop this whole step without affecting PR-1/PR-2 if it causes any friction.

---

## Step 8 — documentation reconciliation (part of the unit, whole-entry sweeps)

Sweep **repo-wide, not just docs/** — restatements live in code moduledocs, AGENTS.md,
and every doc generation: `rg -n "never reads|unwired|spawn-time|no premises threading|never threaded" lib/ docs/ AGENTS.md`

- `docs/plans/unadopted-next-five/README.md` item 3: add a PR-1/PR-2 progress blockquote
  mirroring items 1–2's DONE style, **including the two corrections to the entry's own
  claims**: PR-1 lands via the per-turn `request_transformer` seam, not a "WaveBuilder
  spawn-time override" (no such seam exists); PR-2 threads at
  `route_composer.ex`/`PremisesContext`, not `wave_builder.ex`/`agent_runner.ex`.
- `docs/exploration/alp-river/UNADOPTED-IDEAS.md` #1 (partial: seam wired, arbiter
  consumer pending PR-3/4; fix "WaveBuilder never reads them") and #3 (done; fix the
  "never threaded" claim + location). Sweep table rows too (:20, :22).
- `docs/exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md`: §4 "Model re-tiering" and
  "Premises" bullets, the AR-9 entry's "unwired" claims (:128-131, :161), §4:290, :312-315,
  and the closing ":336 unwired per-stage tiering seam" — all flip to wired/threaded with
  honest wording (sketch step 6 becomes "the arbiter stage *declares* a tier via the
  wired seam").
- **`lib/jido_claw/route_composer/stage.ex:49` moduledoc** — ":model/:effort — spawn-time
  tiering overrides for later phases (§12); never read by the router" → reword to the real
  mechanism: read by `WaveBuilder` at wave build, applied per-turn via the composed
  request transformer; "never read by the router" stays true and stays.
- **`docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md:539` (V1)** — still claims
  the seam is not wired; correct with a dated note (V1 is a closed ledger — annotate,
  don't rewrite history).
- **`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md:1018`** — describes the old
  spawn-time design; add a dated correction pointing at the transformer mechanism.
- **`AGENTS.md:87`** — describes `Compactor.RequestTransformer` as compaction-only;
  update to the composed transformer (compaction + per-stage tiering). AGENTS.md **does**
  change (contrary to the earlier verify-only expectation).

---

## Verification

1. Per step: run the new/changed test file directly, red → green
   (`mix test test/jido_claw/route_composer/wave_builder_test.exs`, etc.). Confirm each
   regression-guard test actually failed before its code change where applicable.
2. Byte-identity guards green: non-tiered ask opts (no transformer/tier key), empty-premises
   `refute task =~ "### Premises"`, all existing compactor + wave_builder + artifact_context
   + composer_loop tests untouched-green.
3. `mix precommit` — run bare, read its own verdict lines, report exact exit/test counts.
   Known flake: `MemoryExportTest` (capture_log race in full suite) — rerun in isolation
   if it trips; do not chase.
4. Nothing staged/committed; all changes remain unstaged in the working tree.

## Risks → gates

- **credo strict**: moduledocs + specs on new public funcs; alias `RequestTransformer` in
  AgentRunner; keep helpers small.
- **reach**: no trivial-forwarder defps (each helper does real conditional work);
  test/support is scanned too — capture hooks mirror already-passing patterns.
- **ExSlop clones**: PremisesContext shape deliberately ≠ ArtifactContext's trio;
  watch `maybe_capture_task` vs `maybe_capture_context` (fold if flagged).
- **dialyzer**: `run/6` spec with `keyword()`; transformer overrides use only the
  behaviour's declared optional keys.
- **Tool-error retryability / Zoi rules**: not touched (no new schemas, no new tool errors).

## Files touched

| File | Change |
| --- | --- |
| `lib/jido_claw/route_composer/wave_builder.ex` | conditional tier opts |
| `lib/jido_claw/skills/steps/agent_step.ex` | forward tier; (opt.) telemetry |
| `lib/jido_claw/skills/steps/agent_runner.ex` | run/6, tier→tool_context, transformer ask-opt |
| `lib/jido_claw/reasoning/compactor/request_transformer.ex` | stage_tier_key + tier overrides |
| `lib/jido_claw/route_composer/premises_context.ex` | **new** renderer |
| `lib/jido_claw/route_composer/route_composer.ex` | compose premises into extra_context |
| `lib/jido_claw/route_composer/stage.ex` | moduledoc: spawn-time claim → wired mechanism |
| `test/support/echo_ask_stub.ex`, `test/support/jido_claw/route_composer/composer_stubs.ex` | capture hooks |
| new/extended tests | wave_builder, agent_runner, request_transformer, premises_context, composer integration |
| `docs/plans/unadopted-next-five/README.md`, `docs/exploration/alp-river/UNADOPTED-IDEAS.md`, `docs/exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md`, `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md`, `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md`, `AGENTS.md` | whole-entry + repo-wide claim reconciliation |
