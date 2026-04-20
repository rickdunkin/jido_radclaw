# v0.4.4 — Pipeline & Strategy Polish

## Context

Three items deferred from v0.4.2/0.4.3 plus one test-helper cleanup surfaced during 0.4.3 are now ready to ship. Each delivers a focused improvement to the reasoning subsystem landed earlier in v0.4.x:

1. **YAML pipelines** extend the metadata-overlay precedent from `.jido/strategies/` to multi-stage compositions, so users can declare reusable chains (e.g., `plan_then_analyze`) alongside their custom strategy aliases.
2. **`max_context_bytes`** closes the unbounded-growth footgun flagged in the 0.4.2 `RunPipeline` moduledoc (`accumulate` mode has no cap today, so long pipelines can blow the context window silently).
3. **Custom prompt templates** elevate user strategies beyond the metadata-only overlays v0.4.2 shipped, so aliases can carry their own `system`/`generation`/`evaluation` prompts and not just tuned `prefers` metadata.
4. **Test helper consolidation** removes a five-way duplicated `with_user_strategy/2` helper that copied itself across every test module touching `StrategyStore`.

Shipping decision (confirmed with user): **split into four point releases** — v0.4.4 (helpers) → v0.4.5 (custom prompts) → v0.4.6 (YAML pipelines) → v0.4.7 (max_context_bytes). Each is independently reviewable and revertible; matches the 0.4.x micro-release cadence. `docs/ROADMAP.md` will be updated as part of v0.4.4 to reflect the new split.

Sequencing rationale:
- **v0.4.4 first** unblocks clean tests for every subsequent release (all of them add new helper call sites).
- **v0.4.5 next** sets the "validated YAML → struct" precedent v0.4.6 will mirror and surfaces lessons before they're duplicated.
- **v0.4.6 after v0.4.5** so pipeline tests can exercise an alias-with-custom-prompts end-to-end.
- **v0.4.7 last** because its cap feature naturally attaches to the YAML pipeline schema landing in v0.4.6.

---

## v0.4.4 — `StrategyTestHelper`

**Goal:** Collapse five identical `with_user_strategy/2` helpers into a shared `test/support/` module.

**Files**

- `mix.exs` — add `elixirc_paths/1` branching:
  - `defp elixirc_paths(:test), do: ["lib", "test/support"]`
  - `defp elixirc_paths(_), do: ["lib"]`
  - reference from `project/0` alongside existing `elixirc_options`.
- `test/support/strategy_test_helper.ex` — new module `JidoClaw.Reasoning.StrategyTestHelper`. v0.4.4 exports only `with_user_strategy/2` (identical body to existing helpers: write YAML to `.jido/strategies/`, `StrategyStore.reload()`, try/after cleanup with `File.rm` + reload; use `System.unique_integer([:positive])` for unique filenames). The parallel `with_user_pipeline/2` is deferred to v0.4.6, which lands `PipelineStore` — adding the helper now would depend on a module that doesn't exist yet.
  - Module doc calls out `async: false` invariant: the supervised `StrategyStore` is a named singleton; parallel tests mutating its state race.
- Five call-site edits (remove the inline `defp`, add `import JidoClaw.Reasoning.StrategyTestHelper` at the top of the module):
  - `test/jido_claw/reasoning/classifier_test.exs` (def at :258, 1 call at :218)
  - `test/jido_claw/reasoning/auto_select_test.exs` (def at :311, 3 calls at :209/244/278)
  - `test/jido_claw/reasoning/strategy_registry_test.exs` (def at :12, 6 calls at :73/87/99/111/128/140)
  - `test/jido_claw/tools/reason_test.exs` (def at :31, 3 calls at :98/117/200)
  - `test/jido_claw/tools/run_pipeline_test.exs` (inside-describe def at ~:368, 2 calls at :386/412) — note: this fifth copy was missed in the roadmap's "four" count and caught during Phase-1 exploration.

**Test plan**
- Existing tests (classifier/auto_select/strategy_registry/reason/run_pipeline) all continue to pass unchanged. No new test cases needed — the refactor preserves exact semantics.
- Verify `mix compile --warnings-as-errors` with the new `elixirc_paths/1` (prod/dev mustn't pick up `test/support/`).

**Risks**
- `elixirc_paths/1` interacts with `elixirc_options: [ignore_module_conflict: true]` (`mix.exs:21`) — mechanical add but in the same region. PR description should call out both lines.
- Any test module losing `async: false` during the refactor would introduce flakes. Preserve it everywhere.

---

## v0.4.5 — Custom Prompt Templates

**Goal:** Let `.jido/strategies/*.yaml` declare prompt template overrides and thread them through to `Jido.AI.Actions.Reasoning.RunStrategy`.

**Prompt support matrix (authoritative — from `deps/jido_ai/.../run_strategy.ex:108-133`):**

| Base | Accepted prompt keys |
|---|---|
| `cot` | `system` |
| `cod` | `system` |
| `tot` | `generation`, `evaluation` |
| `got` | `generation`, `connection`, `aggregation` |
| `trm` | (none — runner accepts no prompt-template options) |
| `aot` | (none — `examples` is a list, not a template; out of scope) |
| `react` | (none — tool's react branch is a structured-prompt stub, bypasses `RunStrategy`) |
| `adaptive` | (none — deprecated alias, no custom path) |

Note the correction from the earlier sketch: `cod` supports `system` (runner state keys include `:system_prompt` — `run_strategy.ex:109`), `got` supports three distinct template keys (`generation`, `connection`, `aggregation`). `tot` does NOT accept `system`.

Unsupported-combo behavior: **hard-reject at load time** — skip the whole YAML file with a warning naming the invalid key+base. Consistent with `StrategyStore`'s lenient-per-file precedent; keeps silent-no-op bugs out of the tracker.

**Files**

- `lib/jido_claw/reasoning/strategy_store.ex`
  - Add `:prompts` to `defstruct` (line 33); update `@type t()` at line 35.
  - Extend `validate/1` (line 168) with a new private `parse_prompts/2` that takes `(prompts_map, base)`:
    - Accepts optional top-level `prompts:` map. Valid sub-keys: `system`, `generation`, `evaluation`, `connection`, `aggregation`.
    - Each value must be a non-empty string; drop empty strings as "unset."
    - Enforce per-field cap of **5 KB** (matches `Jido.AI.Validation.@max_prompt_length` at `deps/jido_ai/.../validation.ex:13` — stays consistent with upstream convention). Warn-and-skip the whole file if any field exceeds.
    - Per-base whitelist: apply the matrix above. Any key not in the base's accepted set → whole-file skip with a warning naming the unsupported combo (e.g., `"prompts.system not supported on base 'tot'"`).
    - Bases with no accepted keys (`trm`, `aot`, `react`, `adaptive`) with any `prompts:` entry → whole-file skip.
    - Unknown sub-keys (e.g., typo `sytem`) → warn, drop the key, keep the file if other keys are valid.
  - Default `prompts: %{}` when absent.
- `lib/jido_claw/reasoning/strategy_registry.ex`
  - New accessor: `prompts_for(name :: String.t()) :: map() | nil`. Built-ins return `nil`; aliases return their map (`%{}` when empty).
  - Use the same `user_strategy/1` exit-safe pattern as `prefers_for/1` (line 178).
- `lib/jido_claw/tools/reason.ex`
  - `run_runner_strategy/5` (line 157): after building `run_params`, merge `StrategyRegistry.prompts_for(strategy_name) || %{}` into `run_params`, mapping atom sub-keys to their RunStrategy-schema names (`system` → `:system_prompt`, `generation` → `:generation_prompt`, `evaluation` → `:evaluation_prompt`, `connection` → `:connection_prompt`, `aggregation` → `:aggregation_prompt`). Absent prompts don't add the key — the runner falls back to compile-time defaults.
  - `run_auto/2` (line 68): same merge against the alias name chosen by `AutoSelect` (when it resolves to a user alias with prompts).
- `lib/jido_claw/tools/run_pipeline.ex`
  - `run_stage/3` (line 264): same merge against the stage's `user_strategy` name. Prompts travel with the alias, not the base.

**New signature**
```elixir
StrategyRegistry.prompts_for(String.t()) :: %{optional(:system | :generation | :evaluation | :connection | :aggregation) => binary()} | nil
```

**Test plan** (extend `test/jido_claw/reasoning/strategy_store_test.exs` and `test/jido_claw/tools/reason_test.exs`)
- Golden: `base: cot` with `prompts.system: "You are a mathy CoT"` → `StrategyStore.get/1` returns struct with `:prompts` populated → `Reason.run` passes `system_prompt:` to the runner (use a stub runner that captures params).
- Golden: `base: cod` with `prompts.system` → `system_prompt:` forwarded.
- Golden: `base: tot` with `prompts.generation` + `prompts.evaluation` → both forwarded.
- Golden: `base: got` with `prompts.generation` + `prompts.connection` + `prompts.aggregation` → all three forwarded.
- Edge: `base: tot` with `prompts.system` → whole file skipped (system not in tot's accepted set).
- Edge: `base: got` with `prompts.evaluation` → whole file skipped.
- Edge: `base: trm` or `base: aot` or `base: react` with any `prompts:` entry → whole file skipped.
- Edge: `prompts.system` > 5 KB → whole file skipped.
- Edge: unknown sub-key `prompts.sytem` (typo) alongside valid `prompts.system` → file kept, typo dropped with warning.

**Risks**
- **C1 (pre-design catch, revised):** the accepted-key matrix is per-base, not cot/tot-only. Getting this matrix wrong rejects valid CoD/GoT configs. Extract the matrix into a module attribute on `StrategyStore` so it's in one place; include a comment pointing at `run_strategy.ex:108-133` as the source of truth.
- `AutoSelect` path: if `Reason.run_auto/2` doesn't merge prompts, aliases with prompts only work when invoked directly. Include this path in the test matrix.
- Cap choice (5 KB) is deliberately aligned with `Jido.AI.Validation.@max_prompt_length` — document this in the moduledoc so future readers don't assume it's arbitrary.

---

## v0.4.6 — YAML-Defined Pipeline Compositions

**Goal:** Users declare reusable pipelines in `.jido/pipelines/*.yaml`. `RunPipeline` gains a `pipeline_ref` parameter that loads stages from disk; inline `stages` still works (and wins when both supplied).

**YAML schema**
```yaml
name: plan_then_explore
description: CoT plan → ToT explore → CoD summary
stages:
  - strategy: cot
  - strategy: tot
    context_mode: accumulate
  - strategy: cod
    prompt_override: "Summarize the above..."
```

No templating engine in v0.4.6 — `prompt_override` remains a literal string (matches current inline behavior).

**Files**

- `lib/jido_claw/reasoning/pipeline_validator.ex` — new module. Extract BOTH `normalize_stage/1`/`normalize_stages/1` AND `validate_stage/2`/`validate_stages/1`/`resolves_to_react?/1` out of `run_pipeline.ex:110-200` as public functions. YamlElixir hands `PipelineStore` string-keyed maps, so without normalization extracted alongside validation, YAML-loaded pipelines would fail `validate_stage/2`'s atom-key pattern match. Both inline callers and `PipelineStore` reuse the full normalize → validate pair.
- `lib/jido_claw/reasoning/pipeline_store.ex` — new GenServer, mirrors `StrategyStore` (loading, lenient error handling, lexicographic dedup, exit-safe lookup). Struct: `%Pipeline{name, description, stages: [stage_map]}` where `stages` is already normalized (atom-keyed) by load time. API:
  - `start_link/1`, `list/0`, `get/1`, `all/0`, `reload/0`
  - Load-time flow: `YamlElixir.read_from_file/1` → `PipelineValidator.normalize_stages/1` → `PipelineValidator.validate_stages/1`. Any failure in either step → skip the whole file with a warning.
- `lib/jido_claw/tools/run_pipeline.ex`
  - Schema changes: `pipeline_ref: [type: :string, required: false]`; flip `stages` to `required: false`. The `:list` schema type rejects non-list `stages` at the `Jido.Action` boundary before `run/2` runs, so shape-level garbage (`"oops"`) never reaches the precedence branch.
  - `run/2` (line 80): branch by **presence of the `stages` key**, not by value shape — so a present-but-malformed `stages` fails fast via `PipelineValidator` instead of silently falling through to `pipeline_ref`. Pseudocode:
    ```
    cond do
      Map.has_key?(params, :stages) ->
        # explicit inline override — normalize + validate; fail if malformed/empty
        with {:ok, normalized} <- PipelineValidator.normalize_stages(params.stages),
             :ok               <- PipelineValidator.validate_stages(normalized) do
          execute(...)
        end
      is_binary(params[:pipeline_ref]) ->
        case PipelineStore.get(params.pipeline_ref) do
          {:ok, %Pipeline{stages: stages}} -> execute(...)
          {:error, :not_found}             -> {:error, "unknown pipeline '#{ref}'"}
        end
      true ->
        {:error, "must supply pipeline_ref or stages"}
    end
    ```
    Enforces: (a) inline wins by branch order; (b) `%{stages: [], pipeline_ref: "foo"}` fails on empty-inline via `validate_stages/1`'s existing non-empty rule, never falling through to the ref; (c) `%{stages: [bad_stage], pipeline_ref: "foo"}` fails on the bad stage's normalization/validation, not on a silent pipeline_ref lookup.

    **Characterization step (first commit of this PR):** Before writing the precedence logic, add the pipeline-ref-only regression test listed in the test plan below and run it against the existing `RunPipeline.run/2` with a one-line probe (`IO.inspect(Map.has_key?(params, :stages), label: "has stages")`) to determine empirically whether `Jido.Action` leaves absent optional `stages` as key-absent or nil-valued. Then write the final guard:
    - If key-absent → keep `Map.has_key?(params, :stages)` as the branch condition.
    - If nil-valued → switch to `is_list(params[:stages]) and params[:stages] != []` (naturally excludes nil).

    Delete the probe and this note from the final commit. The regression test stays — it locks the behavior regardless of which shape `Jido.Action` chose.
  - Delegate normalization + validation to `PipelineValidator` for both branches. For the YAML branch, stages are already normalized+validated at load time — re-validate at invocation time so stale state (strategy deleted between load and run) still errors cleanly. Normalization on pre-normalized maps is a no-op (atoms stay atoms).
  - Update `@moduledoc`: document (1) the presence-based precedence of inline stages over `pipeline_ref`, and (2) that caller-supplied `pipeline_name` always wins over YAML `name` (YAML `name` is the lookup key only).
- `lib/jido_claw/application.ex`
  - Add `{JidoClaw.Reasoning.PipelineStore, [project_dir: project_dir()]}` to `core_children/0` immediately below `StrategyStore` (line 141).
- `lib/jido_claw/startup.ex` — if it ensures `.jido/strategies/` exists at boot, add `.jido/pipelines/` alongside. (Verify during implementation; not confirmed in Phase 1.)
- `test/support/strategy_test_helper.ex` — add `with_user_pipeline/2` (mirror of `with_user_strategy/2` pointing at `.jido/pipelines/` and `PipelineStore.reload/0`).

**New signatures**
```elixir
PipelineStore.list() :: [String.t()]
PipelineStore.get(String.t()) :: {:ok, %Pipeline{}} | {:error, :not_found}
PipelineStore.all() :: [%Pipeline{}]
PipelineStore.reload() :: :ok

# All four are promoted from private in run_pipeline.ex to public in PipelineValidator.
PipelineValidator.normalize_stage(stage :: map()) :: {:ok, map()} | {:error, String.t()}
PipelineValidator.normalize_stages([map()]) :: {:ok, [map()]} | {:error, String.t()}
PipelineValidator.validate_stage(stage :: map(), idx :: pos_integer()) :: :ok | {:error, String.t()}
PipelineValidator.validate_stages([map()]) :: :ok | {:error, String.t()}
```

**Test plan** (new `test/jido_claw/reasoning/pipeline_store_test.exs`; extend `run_pipeline_test.exs`)
- Golden (store): YAML file (string-keyed by YamlElixir) with 2 stages → `PipelineStore.get/1` returns struct with atom-keyed stages — i.e., normalization actually runs. Add an explicit assertion on `stage.strategy` being read by atom key.
- Golden (tool): `RunPipeline.run(%{pipeline_ref: "foo", pipeline_name: "run1", prompt: "…"}, ctx)` executes stages from disk.
- Edge: inline `stages: [valid]` + `pipeline_ref: "missing"` both supplied → runs the inline stages successfully (does NOT return `{:error, "unknown pipeline 'missing'"}`). This test directly enforces the branch-order contract.
- Edge: only `pipeline_ref` supplied with non-existent name → `{:error, "unknown pipeline 'missing'"}`.
- Edge: only `pipeline_ref` supplied for an existing YAML pipeline (no `stages` key in params at all) → pipeline executes successfully. This regression test pins down `Jido.Action`'s handling of absent optional keys — if the pipeline-ref-only path ever silently falls through to "must supply pipeline_ref or stages," this test will catch it.
- Edge: neither supplied → `{:error, "must supply pipeline_ref or stages"}`.
- Edge: YAML stage with `strategy: auto` → whole file skipped, warning logged, `PipelineStore.get/1` returns `{:error, :not_found}`.
- Edge: YAML stage with `strategy: react` (or react-based alias) → whole file skipped.
- Edge: caller-supplied `pipeline_name: "override"` with `pipeline_ref: "foo"` → telemetry uses `"override"`, not `"foo"`.
- Assert `PipelineStore`-touching tests use `async: false` (named singleton).

**Risks**
- **R1 (pre-design catch):** stage validation at load time AND invocation time are both needed. Load-time catches bad YAML early; invocation-time catches post-load strategy deletion. Don't remove the inline path's validation even though `PipelineStore` also validates.
- **R2 (pre-design catch):** caller-supplied `pipeline_name` must win for telemetry correlation. Document + test explicitly.
- PipelineValidator extraction must preserve existing error message format (the moduledoc at `run_pipeline.ex:13-28` advertises specific strings; consumers may grep for them).
- `.jido/pipelines/` directory creation at boot — if `Startup` doesn't already ensure the strategies dir, skip creating pipelines dir too (keep behavior parallel).

---

## v0.4.7 — `max_context_bytes` Cap

**Goal:** Bound the composed-prompt size in `accumulate` mode. Drop oldest whole stages (never mid-body truncate). Fail fast if the newest stage alone exceeds the cap.

**Files**

- `lib/jido_claw/tools/run_pipeline.ex`
  - Schema: add `max_context_bytes: [type: :pos_integer, required: false]` as a top-level tool param (pipeline-level default).
  - `normalize_stage/1` (line 127 — after v0.4.6 this lives in `PipelineValidator`): accept optional `max_context_bytes` per stage (positive integer; string or atom key). Reject non-positive integers with a clear error.
  - **Keep cap evaluation OUTSIDE `Telemetry.with_outcome/4`, but route cap failures BACK THROUGH `with_outcome/4` with a pre-error `fun`.** This preserves the full telemetry lifecycle (start/stop events, `jido_claw.reasoning.classified` signal, persisted row) asserted in `test/jido_claw/reasoning/telemetry_test.exs:32-61, 140+` without adding a new API. No "deferred prompt" complexity and no side-stepping of the classified-signal emission.

    `compose_and_cap/5` returns on BOTH paths with enough data to classify:
    - `{:ok, final_prompt, cap_meta}` — success. Caller calls `with_outcome(strategy, final_prompt, merge_cap_meta(opts, cap_meta), fn -> run_stage(...) end)`.
    - `{:error, reason, classification_prompt, cap_meta}` — failure. `classification_prompt` is the *irreducible would-be request* AFTER dropping all droppable earlier stages: `initial_prompt + newest_stage_header_and_body + elision_notice`. It is NOT the full pre-cap composed string (that would inflate `prompt_length` with bytes that never would have been sent). `cap_meta.accumulated_context_bytes_pre_cap` holds the uncapped size for observability. Caller calls `with_outcome(strategy, classification_prompt, merge_failure_meta(opts, cap_meta, reason), fn -> {:error, reason} end)`. `with_outcome/4` already handles `{:error, _}` fn returns correctly (`telemetry.ex:81`) — classifies the irreducible prompt (accurate `prompt_length`), fires start/stop with `status: :error`, emits the classified signal when no profile pre-supplied, and persists the failure row with `metadata.failure_reason` and cap metadata. `duration_ms` comes out as the tiny classify-and-emit overhead; close enough to zero to be honest.

    Pipeline loop's halt branch still returns the same `{:error, formatted_message}` it does today — caller-visible contract unchanged; moduledoc's `:error`-row guarantee (`run_pipeline.ex:41-43`) preserved.
  - New `compose_and_cap/5` helper (replaces/wraps `compose_prompt/3`'s accumulate clause):
    - Resolve effective cap: stage-level wins over pipeline-level; `nil` = uncapped (current behavior).
    - `previous` mode + any cap → log a one-line warning at run start that cap is accumulate-only; continue without capping.
    - Build the elision notice string FIRST (its byte count is deterministic: `"\n\n[<N> earlier stage outputs elided to fit max_context_bytes]"` where `N` is known at drop time — reserve worst-case byte budget upfront using the final `N` after dropping).
    - Drop oldest-stage entries (whole entry: header + body) in order, tracking `dropped_stage_indexes`. At each step re-compute expected size as `byte_size(composed_remaining) + byte_size(notice_with_current_N)`. Stop when that total `<= cap`.
    - If even `initial_prompt + newest_stage_header_and_body + notice` exceeds cap → return `{:error, reason, classification_prompt, cap_meta}` where `reason` is the formatted message `"stage #{idx}: max_context_bytes (#{cap}) exceeded by initial prompt + most-recent stage output alone"` and `classification_prompt` is the irreducible would-be request *after all droppable earlier stages have already been removed*: `initial_prompt + newest_stage_header_and_body + notice`. Upstream rows are already persisted `:ok`; the caller routes this error tuple through `Telemetry.with_outcome(strategy, classification_prompt, merged_opts, fn -> {:error, reason} end)` to persist the failing stage's `:error` row with an accurate `prompt_length`. The full uncapped size lives in `cap_meta.accumulated_context_bytes_pre_cap` for observability; it is NOT the classification prompt.
    - Append the notice AFTER dropping. The notice byte count was pre-reserved, so the final `byte_size(final_prompt) <= cap` holds.
  - Thread cap observations into the stage's telemetry `opts[:metadata]` when cap applied:
    - `accumulated_context_bytes_pre_cap` (int — size of un-capped composed prompt)
    - `accumulated_context_bytes_post_cap` (int — size of final prompt including notice)
    - `dropped_stage_indexes` (list of ints)
    - No new `reasoning_outcomes` columns — `metadata` is a free-form Ash attribute (`lib/jido_claw/reasoning/resources/outcome.ex:210`).
- `lib/jido_claw/reasoning/pipeline_store.ex` (extends v0.4.6)
  - Parser: accept top-level `max_context_bytes:` and per-stage `max_context_bytes:`. Reject non-positive integers (file-level warn-and-skip).
- `lib/jido_claw/reasoning/pipeline_validator.ex` (extends v0.4.6)
  - Validate `max_context_bytes: pos_integer | nil` on both top-level and per-stage.
- `lib/jido_claw/reasoning/telemetry.ex` — **no API changes.** `with_outcome/4` already supports the failure path correctly when the caller passes a `fn` that returns `{:error, reason}`; all that's needed is for `RunPipeline` to supply the right `prompt` (the pre-cap attempted string) and stuff cap/failure metadata into `opts[:metadata]`.

**Capping helper**
```elixir
# Private in RunPipeline. Returns BOTH paths with enough data to classify
# via Telemetry.with_outcome/4.
#
# - {:ok, final_prompt, cap_meta}: success. final_prompt is what actually
#   goes to the LLM. cap_meta is empty when no cap applied, populated with
#   :accumulated_context_bytes_pre_cap, :accumulated_context_bytes_post_cap,
#   :dropped_stage_indexes when it is.
# - {:error, reason, classification_prompt, cap_meta}: cap failed.
#   classification_prompt is the irreducible would-be request AFTER
#   dropping all droppable earlier stages:
#     initial_prompt + newest_stage_header_and_body + elision_notice
#   NOT the full pre-cap composed string (which would inflate prompt_length
#   with bytes that never would have been sent anyway). The uncapped size
#   lives separately in cap_meta.accumulated_context_bytes_pre_cap.
compose_and_cap(
  stage :: map(),
  initial_prompt :: String.t(),
  acc :: %{outputs: list()},
  stage_cap :: nil | pos_integer,
  pipeline_cap :: nil | pos_integer
) :: {:ok, String.t(), map()} | {:error, String.t(), String.t(), map()}
```

**Test plan** (extend `test/jido_claw/tools/run_pipeline_test.exs` AND `test/jido_claw/reasoning/telemetry_test.exs`)

In `run_pipeline_test.exs`:
- Golden: 3-stage accumulate, each ~400 bytes, `max_context_bytes: 1000` → stage 3 sees initial + stage 2 only; stage 1 dropped. Outcome row metadata has `dropped_stage_indexes: [1]` and both byte counts.
- Golden: `byte_size(final_prompt) <= max_context_bytes` holds when drops occurred — explicitly assert the final prompt fits inside the cap *including* the elision notice.
- Edge: stage 2 output alone is 5 KB, cap is 2 KB → stage 3 returns `{:error, "stage 3: max_context_bytes (2000) exceeded by initial prompt + most-recent stage output alone"}`. Earlier stage rows persist `:ok`; the failing stage row persists `:error` (verify via direct Ash query — this is the contract from `run_pipeline.ex:41-43`).
- Edge: failing stage row carries `metadata.failure_reason`, `metadata.accumulated_context_bytes_pre_cap`, and `metadata.dropped_stage_indexes` (the cap metadata flows through even on failure).
- Edge: `context_mode: "previous"` + `max_context_bytes: 500` → cap ignored (documented behavior), one warning logged.
- Edge: top-level cap only, no stage-level cap → applies to all accumulate stages.
- Edge: stage cap overrides top-level cap.
- Edge: 0 or negative integer → schema rejects at invocation; YAML load → whole-file skip.
- Trailing elision notice present in composed prompt when drops occurred.

In `telemetry_test.exs` (new assertions for cap-failure path):
- A cap-failure stage (reached via `RunPipeline` with a too-small cap) still fires both `[:jido_claw, :reasoning, :strategy, :start]` and `[:jido_claw, :reasoning, :strategy, :stop]` telemetry events, with `status: :error` on the stop metadata. This is a regression lock on the `with_outcome/4` lifecycle assertions at `telemetry_test.exs:32-61`.
- A cap-failure stage still emits `jido_claw.reasoning.classified` (when no profile is caller-supplied) — locks the behavior asserted at `telemetry_test.exs:140+`.
- The classified signal's `task_type` and `prompt_length` reflect the **irreducible would-be request** (post-drop `initial + newest_stage + notice`), not `""` and not the full pre-cap string — i.e., `compose_and_cap`'s error-tuple carries `classification_prompt` through to `with_outcome`, and `prompt_length` matches `byte_size(classification_prompt)` not `accumulated_context_bytes_pre_cap`.

**Risks**
- **C3 (pre-design catch):** mid-body truncation is tempting but wrong UX — the LLM just saw a stage complete and expects its full output. Drop whole stages or fail.
- **Notice in budget (user P2):** the elision notice's bytes must count against `max_context_bytes`, or the final prompt silently exceeds the cap. Reserve the notice size upfront in `compose_and_cap/5`.
- **Telemetry contract (multiple P1 iterations):** cap failures must emit the full `with_outcome/4` lifecycle — start/stop telemetry, `jido_claw.reasoning.classified` signal, and a persisted row with a meaningful `prompt_length`. The design achieves this by keeping composition outside `with_outcome/4` AND routing failures *back through* `with_outcome/4` with `fn -> {:error, reason} end`. No new Telemetry API is introduced. `compose_and_cap/5` must return the attempted prompt on the error path so the caller can classify it; its 4-tuple error shape enforces this by type.
- `byte_size/1` vs token count: v0.4.7 uses byte_size only (per roadmap name). Token counting would require wiring jido_ai's tokenizer — out of scope.
- Pipeline-level default doesn't apply when `RunPipeline` is invoked with inline `stages` and no top-level `max_context_bytes`. Document this; it's the expected behavior for backwards compat.

---

## Documentation & Release Bookkeeping

- **`mix.exs` version bump** (critical housekeeping — currently `@version "0.3.0"` at `mix.exs:4`, stale through the entire v0.4.x series): bump to `"0.4.4"` in the v0.4.4 PR, then `"0.4.5"`, `"0.4.6"`, `"0.4.7"` in each subsequent release's PR. Include this in every PR's changeset so each point-release tag corresponds to a real `@version`.
- **`docs/ROADMAP.md`** (in v0.4.4 PR): split v0.4.4 entry into four point-release sections (v0.4.4 through v0.4.7). Each keeps the current content as the delivery summary for that release. Update the "Build Order" footer (line 284) to reflect the new cadence. Update the "Current State" header (line 3) as each release ships.
- **`AGENTS.md`**: at the `Module Namespace Convention` table (~line 95), extend `reasoning/` description from "Strategy registry, certificate templates" to "Strategy registry + pipeline store, certificate templates" (lands in v0.4.6). Add a line under `.jido/` directory section (~line 108) noting `.jido/strategies/*.yaml` and `.jido/pipelines/*.yaml` conventions, pointing at module docs rather than duplicating the YAML schema.
- **`CLAUDE.md`**: untouched (currently a 1-line stub pointing at AGENTS.md).

---

## Critical Files

- `lib/jido_claw/tools/run_pipeline.ex` — touched in v0.4.5/0.4.6/0.4.7
- `lib/jido_claw/reasoning/strategy_store.ex` — touched in v0.4.5
- `lib/jido_claw/reasoning/strategy_registry.ex` — touched in v0.4.5
- `lib/jido_claw/tools/reason.ex` — touched in v0.4.5
- `lib/jido_claw/application.ex` — touched in v0.4.6
- `lib/jido_claw/reasoning/pipeline_store.ex` — new in v0.4.6
- `lib/jido_claw/reasoning/pipeline_validator.ex` — new in v0.4.6
- `mix.exs` — touched in v0.4.4 (`elixirc_paths/1`)
- `test/support/strategy_test_helper.ex` — new in v0.4.4, extended in v0.4.6

## Reused Utilities

- `System.unique_integer([:positive])` — helper filename collision avoidance (existing pattern in every current `with_user_strategy/2`).
- `YamlElixir.read_from_file/1` — pipeline parser reuses the strategy parser's choice (`lib/jido_claw/reasoning/strategy_store.ex:147`).
- `JidoClaw.Reasoning.Telemetry.with_outcome/4` — every new metadata field in v0.4.7 attaches through existing opts keyword.
- `JidoClaw.Reasoning.StrategyRegistry.atom_for/1` — pipeline validator reuses the alias-resolution path (line 127 of strategy_registry.ex).
- `JidoClaw.Reasoning.StrategyStore`-style GenServer skeleton — `PipelineStore` is a near-1:1 port (init/handle_continue/handle_call structure, lenient file parsing, lexicographic dedup, exit-safe lookup pattern at line 194).

## Verification

### Per-release gate
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test` — all green (the suite was 772 tests at v0.4.3)

### v0.4.4 end-to-end
- Delete all inline `defp with_user_strategy/2` bodies; confirm test suite still passes.
- `mix compile` on both `:test` and `:prod` envs — confirm `test/support/` only compiles under `:test`.

### v0.4.5 end-to-end
- Create `.jido/strategies/mathy.yaml` with `base: cot, prompts.system: "You are a rigorous mathematician"`.
- REPL: `/strategy mathy` then issue a prompt; verify via tidewave `execute_sql_query` that the `reasoning_outcomes` row has `strategy: "mathy"`, `base_strategy: "cot"`.
- Create `.jido/strategies/broken.yaml` with `base: tot, prompts.system: "…"` (system is not in tot's accepted set per the matrix) — verify boot-time warning and `StrategyStore.get("broken")` returns `{:error, :not_found}`.

### v0.4.6 end-to-end
- Create `.jido/pipelines/plan_then_summarize.yaml` with a 2-stage CoT→CoD chain.
- From REPL, invoke `run_pipeline` tool with `pipeline_ref: "plan_then_summarize"` — verify stages execute in order, `reasoning_outcomes` rows have `pipeline_name: "plan_then_summarize"`, `pipeline_stage: "001/002"` and `"002/002"`.

### v0.4.7 end-to-end
- Craft a pipeline with three deliberately long stages (e.g., each stage emits 500 bytes) and `max_context_bytes: 1000`.
- Run it; tidewave-query the latest 3 `reasoning_outcomes` rows — the third's `metadata` jsonb should contain `dropped_stage_indexes: [1]` plus both byte counts.
- Run the same pipeline with `max_context_bytes: 100` — final stage errors with the "exceeded by initial prompt + most-recent stage output alone" message; first two rows remain `:ok`.
