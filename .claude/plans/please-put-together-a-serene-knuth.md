# v0.4.2 — User Strategies, Pipeline Composition, Certificate Telemetry

## Context

v0.4.1 shipped the reasoning foundations: heuristic classifier, `reasoning_outcomes` persistence via `Telemetry.with_outcome/4`, system-prompt auto-sync. It deliberately reserved columns (`base_strategy`, `pipeline_name`, `pipeline_stage`, `certificate_verdict`, `certificate_confidence`) and one unused execution kind (`:certificate_verification`) for this milestone, so the data layer is already in place.

v0.4.2 closes the 0.4.1 debt (certificate telemetry) and unlocks two user-facing capabilities: user-defined reasoning strategies loaded from `.jido/strategies/*.yaml`, and sequential pipeline composition via a new `RunPipeline` tool. v0.4.3 (auto-selection, history-aware classifier, `/strategies stats`) is out of scope; it consumes the data this milestone produces.

**Scope clarification vs. the roadmap text.** Two narrowings, applied to `docs/ROADMAP.md` in commit 1:

1. "Brand-new named strategies" is narrowed to "new named aliases with their own `prefers`/description/display_name, routed to one of the 8 existing reasoning modules". Custom prompt templates (which live in `deps/jido_ai/`) are out of scope for 0.4.2.
2. **Pipelines chain non-react strategies only.** `RunPipeline` fail-fasts any stage whose strategy resolves to `react` (alias-aware). The roadmap's "CoT for planning → ReAct for execution" example is reframed as "agent invokes `run_pipeline` for the CoT-or-richer planning chain, then the agent's native ReAct loop acts on the final output" — i.e., ReAct stays the agent's own loop, not a pipeline stage. The current `Reason` react path is a structured-prompt stub that isn't useful mid-pipeline; routing it there would produce a stub prompt as stage output, not an actual ReAct execution.

**Build order.** certificate wrap → user strategies → pipelines, smallest to largest. Each is independently shippable; three commits/PRs.

---

## Cross-cutting preliminaries (do before sections A–C)

P1. **Fix token extraction to match `jido_ai`, including error results** — `Telemetry.extract_tokens/1` (lines 219-226 in `lib/jido_claw/reasoning/telemetry.ex`) has two bugs:
   - **Key names**: looks for `prompt_tokens`/`completion_tokens`, but `jido_ai` usage maps use `input_tokens`/`output_tokens` (confirmed in `deps/jido_ai/lib/jido_ai/actions/helpers.ex:143`). Every existing row has `nil` tokens.
   - **Error-side accounting**: only matches `{:ok, %{usage: ...}}`. But `jido_ai`'s `RunStrategy` can return `{:error, %{usage: usage}}` on partial-failure paths (`deps/jido_ai/lib/jido_ai/actions/reasoning/run_strategy.ex:263`). Failed pipeline stages and failed cert parses lose their token accounting.

   Fix both: extract `input_tokens`/`output_tokens` with fallbacks to `prompt_tokens`/`completion_tokens`, and match both `{:ok, %{usage: _}}` and `{:error, %{usage: _}}`. Tangential to 0.4.2 proper but cert/pipeline rows need it, so it lands here.

P2. **Clarify `base_strategy` semantics globally** — Once aliases exist, `strategy` stores the user-facing name (possibly an alias), and `base_strategy` stores the resolved built-in (`cot`, `tot`, etc.). This applies uniformly:
- **Alias run resolving to a non-react base**: `strategy = "fast_reviewer"`, `base_strategy = "cot"`.
- **Pipeline stage using alias (non-react base)**: same as above, plus `pipeline_name`/`pipeline_stage`.
- **Pipeline stage using a built-in name**: `strategy = "cot"`, `base_strategy = "cot"` (explicit, not nil — simplifies queries).
- **Cert**: `strategy = "cot"`, `base_strategy = "cot"`, `execution_kind = :certificate_verification`.
- **React run (direct or alias)**: currently the react branch in `Reason.run_strategy/3` (line 53) is unwrapped, so no row is written. Section B #8 below wraps it with `Telemetry.with_outcome/4` emitting `execution_kind: :react_stub` (the value already reserved in 0.4.1's `ExecutionKind` enum), so `strategy = user_name`, `base_strategy = "react"` rows land coherently. Without that wrap, alias→react produces no telemetry and P2's story has a hole.

This makes "which built-in served this row?" a single column and drops the earlier draft's "first-stage wins" notion.

P3. **Update roadmap language** — Edit `docs/ROADMAP.md` v0.4.2 section to describe the actual deliverable: "user-defined aliases with custom `prefers` metadata" and note the 0.4.3 door for fully custom prompt templates. Lands in commit 1 alongside the cert wrap.

---

## A. Certificate telemetry wrap

### Files to modify

1. **`lib/jido_claw/reasoning/telemetry.ex`**
   - Extend `@type opts` (lines 21-29) with `certificate_verdict: String.t() | nil` and `certificate_confidence: float() | nil`.
   - Add `extract_certificate_fields/1` helper mirroring `extract_tokens/1` (line 219). Matches `{:ok, %{certificate_verdict: v, certificate_confidence: c}}` on the fun's result; returns `{v, c}`, else `{nil, nil}`.
   - In `persist/9` attrs (lines 166-186), add `certificate_verdict`/`certificate_confidence` keys, preferring opts (test-override path) and falling back to extracted values.
   - Apply P1 token-key fix in the same change.

2. **`lib/jido_claw/tools/verify_certificate.ex`**
   - Refactor `run_reasoning/2` (lines 118-134) to call `Telemetry.with_outcome/4` with `"cot"` as the first positional `strategy_name` arg, `prompt` as second, and opts `[execution_kind: :certificate_verification, base_strategy: "cot", workspace_id: ws_id, project_dir: proj]`. (`certificate_verdict`/`certificate_confidence` flow back through the fun's ok-tuple map, not via opts, per A.1's `extract_certificate_fields/1`.)
   - **Fun happy path**: runner returns `{:ok, result}`, extract output, parse via `Certificates.parse_certificate/1`, return `{:ok, %{output, certificate, certificate_verdict, certificate_confidence, usage: Map.get(result, :usage, %{})}}`. The outer `run/2` (line 58) unpacks `certificate` from the result (replacing the current two-stage pipe that only surfaces `output_str`).
   - **Fun error path (parse failure or runner error)**: return `{:error, %{reason: reason, usage: usage}}` so P1's error-side extraction captures tokens for the failed row. Then `run_reasoning/2` unwraps back to `{:error, reason}` before `run/2` applies its existing user-facing error formatting at lines 87-106 — no change to the outer error-surfacing behavior.
   - Keep the existing `runner` override via `context[:reasoning_runner]` for testability.

### Tests

3. **`test/jido_claw/reasoning/telemetry_test.exs`** — add cases: cert fields persist when returned by fun, opts override fun-returned values, and (P1 fix) `input_tokens`/`output_tokens` are captured.

4. **`test/jido_claw/tools/verify_certificate_test.exs`** — add an integration `describe` block using Ecto sandbox + `:reasoning_telemetry_sync` that asserts one `reasoning_outcomes` row per cert run with `execution_kind: :certificate_verification`, `strategy: "cot"`, `base_strategy: "cot"`, verdict/confidence populated.

### Roadmap

5. **`docs/ROADMAP.md`** — update v0.4.2 section text per P3 (narrow "brand-new named strategies" language). Same commit as A.

---

## B. User-defined strategies

User strategies are **metadata-only overlays**: each YAML declares a named alias with its own `prefers` metadata that routes to one of the 8 built-in modules via a required `base` field. No custom prompt templates.

### Files to create

6. **`lib/jido_claw/reasoning/strategy_store.ex`** — new GenServer mirroring `JidoClaw.Skills` (`lib/jido_claw/platform/skills.ex`). Public API: `start_link/1`, `list/0`, `get/1`, `all/0`, `reload/0`. Struct: `%StrategyStore{name, base, description, prefers, display_name}`. Loads via `YamlElixir.read_from_file/1` in `handle_continue(:load, state)`.

   **Deterministic ordering.** `File.ls/1` returns filesystem-order; wrap with `Enum.sort/1` before parsing so "first-loaded wins" on name collision is reproducible across environments.

   **YAML schema:**
   ```yaml
   name: deep_debug              # required; non-empty; no "/"
   base: react                    # required; must be one of the 8 built-in names
   display_name: "Deep Debug"     # optional
   description: "..."             # optional
   prefers:
     task_types: [debugging]
     complexity: [complex, highly_complex]
   ```

   **Validation (lenient — warn and skip):**
   - Unknown `base` → skip, warn.
   - `name` collision with a built-in → built-in wins, skip with warning. Defer `mode: override` to 0.4.3.
   - `name` collision between two user files → lexicographic-first wins (thanks to `Enum.sort/1`), warn on second.
   - `prefers.task_types`/`prefers.complexity` cast via whitelist-to-atom helpers matching `TaskType` / `Complexity` values. Never `String.to_atom/1` on user input.
   - Malformed YAML → warn, skip file, continue.

### Files to modify

7. **`lib/jido_claw/reasoning/strategy_registry.ex`** — make all five public functions (`plugin_for/1`, `atom_for/1`, `list/0`, `valid?/1`, `prefers_for/1`) merge-aware with built-ins-first precedence.

   **`plugin_for/1` react contract fix**: the current built-in entry returns `{:ok, Jido.AI.Reasoning.ReAct}` (line 91-98), but the docstring says "or nil for react" — a stale comment. Settle on one consistent contract: **always return the module** (`{:ok, Jido.AI.Reasoning.ReAct}` for both direct `"react"` and react aliases). `Reason.run_strategy/3` routes react via the user-facing name, not via `plugin_for/1`, so no caller actually depends on the `nil` case. Fix the docstring to match.

   **Process lookup safety.** `GenServer.call/2` to a non-started named process exits the caller — `rescue` won't catch it. Pattern:
   ```elixir
   defp user_strategy(name) do
     case GenServer.whereis(JidoClaw.Reasoning.StrategyStore) do
       nil -> nil
       _pid ->
         try do
           case JidoClaw.Reasoning.StrategyStore.get(name) do
             {:ok, entry} -> entry
             _ -> nil
           end
         catch
           :exit, _ -> nil
         end
     end
   end
   ```
   - `plugin_for/1`: built-in → direct; alias → resolve base → return base's module. If resolved base is `"react"`, return `{:ok, nil}` (matches current react contract).
   - `atom_for/1`: alias → return base's atom. (`:react` for react-aliased; callers already ignore this path per `Reason.run_strategy/3` react special-case.)
   - `prefers_for/1`: alias → user's `prefers` (the whole point of overlays).
   - `list/0`: built-ins ++ user strategies, sorted by name. User entries use `display_name` when present (see #17 for render).
   - `valid?/1`: either set.

8. **`lib/jido_claw/tools/reason.ex`** — teach `run_strategy/3` to dispatch on resolved-base, not user-facing name. Add a `resolve_to_base/1` private that returns `{user_name, base_name}`.
   - If `base_name == "react"` — which covers **both** the direct call `strategy: "react"` *and* any user alias whose `base` resolves to `react` — route to the existing react-structured-prompt branch (line 53) with `strategy: user_name` in the returned map, **but wrap the branch in `Telemetry.with_outcome/4`** with `user_name` as the first positional arg and opts `[execution_kind: :react_stub, base_strategy: "react", workspace_id: ..., project_dir: ...]`. The wrap is essentially free (the fun just returns the structured prompt `{:ok, %{...}}`) and closes the P2 data hole for both cases.
   - For non-react bases, call `StrategyRegistry.atom_for/1` (returns the base atom for aliases) and pass `base_strategy: base_name` to `Telemetry.with_outcome/4`. Populate `base_strategy` for *every* call (including non-alias — value equals `strategy`), per P2.

9. **`lib/jido_claw/application.ex`** — under `core_children/0`, add `{JidoClaw.Reasoning.StrategyStore, [project_dir: project_dir()]}` right after the `JidoClaw.Skills` child (line 138).

10. **`lib/jido_claw/startup.ex`** — in `ensure_project_state/1`, add a `safe_bootstrap(:strategies, ...)` step that (a) `File.mkdir_p!(Path.join([project_dir, ".jido", "strategies"]))`, then (b) guards the reload so it doesn't crash when the app isn't running (e.g., tests that call `ensure_project_state/1` directly):
    ```elixir
    case Process.whereis(JidoClaw.Reasoning.StrategyStore) do
      nil -> :ok
      _pid -> JidoClaw.Reasoning.StrategyStore.reload()
    end
    ```
    This closes the cold-boot cache-race — `Application.start` fires before `ensure_project_state/1`, so the store's initial load may see an empty or nonexistent dir; the post-mkdir reload ensures any YAML on disk is picked up before first use, without making `ensure_project_state/1` depend on the app being started.

11. **`lib/jido_claw/cli/commands.ex`** — update the `/strategies` handler (lines 558-575) to render `display_name` when present, with the machine name always visible (the machine name is what users type in `/strategy <name>`). Format: `▸ Deep Debug (deep_debug)` when `display_name` is set; `▸ deep_debug` otherwise. Without this change, `display_name` is dead data.

### Tests

12. **`test/jido_claw/reasoning/strategy_store_test.exs`** (new, `async: false`) — YAML happy path; unknown `base` rejected; whitelist atom normalization; built-in-collision skipped; user-vs-user collision deterministic after sort; malformed YAML tolerated; `reload/0` picks up changes.

13. **`test/jido_claw/reasoning/strategy_registry_test.exs`** (new or extend) — `async: false`. User-strategy module/atom resolution; `prefers_for/1` returns user-supplied map; registry falls back to built-ins when store is down (`StrategyStore` stopped in `setup`).

14. **`test/jido_claw/reasoning/classifier_test.exs`** — **must flip to `async: false`** (currently `async: true` at line 2). A named `StrategyStore` makes classifier state global across tests. Add a case verifying a user alias with explicit `prefers` outscores built-ins for a matching profile.

15. **`test/jido_claw/tools/reason_test.exs`** (create if missing — the file does not currently exist under `test/jido_claw/tools/`) — cover: react-aliased strategy dispatches to the react branch with the user-facing name in the output map; the react branch writes a `reasoning_outcomes` row with `execution_kind: :react_stub` and `base_strategy: "react"` (direct and aliased); non-react alias writes a row with `base_strategy` set to the resolved built-in.

---

## C. Pipeline composition

### Files to create

16. **`lib/jido_claw/tools/run_pipeline.ex`** — `use Jido.Action`, schema:
    ```elixir
    schema: [
      pipeline_name: [type: :string, required: true],
      prompt: [type: :string, required: true],
      stages: [type: {:list, :map}, required: true]
    ],
    output_schema: [
      pipeline_name: [type: :string, required: true],
      stages: [type: {:list, :map}, required: true],
      final_output: [type: :string, required: true],
      usage: [type: :map]
    ]
    ```
    Inline stages only in 0.4.2; YAML pipelines deferred to 0.4.3.

    **Stage-map key normalization.** Elixir callers may pass `%{strategy: "cot"}` (atom keys); tool invocations routed through JSON may give `%{"strategy" => "cot"}` (string keys). Add a `normalize_stage/1` private that coerces to a known shape — either always atom keys or always string keys (pick one; atom keys are idiomatic for internal use). All validation and composition then reads that normalized form. Applies to `strategy`, `context_mode`, `prompt_override`.

    **Pre-execution validation (fail-fast, no LLM calls yet; runs on normalized stages):**
    - `stages` must be a non-empty list. `required: true` does not guarantee non-empty — explicitly reject `[]` with a descriptive error.
    - Each stage must have a `strategy` key that `StrategyRegistry.valid?/1` accepts.
    - If any stage's strategy resolves (alias-aware) to `"react"`, reject with a clear message pointing to the native agent loop. Stub prompts aren't meaningful mid-pipeline.

    **Runner injection for testability.** Accept `context[:reasoning_runner]` override, mirroring `VerifyCertificate.run_reasoning/2:119`. Tests stub the runner; production uses `Jido.AI.Actions.Reasoning.RunStrategy`.

    **Pipeline stage formatting.** `pipeline_stage` is `:string`, and text-sort of `"10/12"` sorts before `"2/12"`. Zero-pad to 3 digits: `"001/012"`. In addition, persist structured `{stage_index, stage_total}` in the outcome's `metadata` map (a JSON column on `reasoning_outcomes`) so numeric ordering is explicit and UIs can read the integers directly without parsing the string. Both together — future-proofs without a schema change.

    **Execution loop:**
    ```
    Enum.with_index(stages, 1)
    |> Enum.reduce_while({:ok, %{outputs: [], last: initial_prompt, usage: %{}}},
      fn {stage, idx}, {:ok, acc} ->
        stage_prompt = compose_prompt(stage, initial_prompt, acc)
        user_strat = stage["strategy"]
        {:ok, base_atom} = StrategyRegistry.atom_for(user_strat)
        base_name = Atom.to_string(base_atom)

        wrap_opts = [
          execution_kind: :pipeline_run,
          base_strategy: base_name,
          pipeline_name: pipeline_name,
          pipeline_stage: zero_pad(idx, total),
          workspace_id: ws_id,
          project_dir: proj,
          metadata: %{stage_index: idx, stage_total: total}  # (see P4 below)
        ]

        case Telemetry.with_outcome(user_strat, stage_prompt, wrap_opts,
               fn -> run_stage(runner, base_atom, stage_prompt) end) do
          {:ok, res} -> {:cont, {:ok, append(acc, idx, user_strat, res)}}
          {:error, r} -> {:halt, {:error, {idx, user_strat, r}}}
        end
      end)
    ```

    P4 note: `Telemetry.with_outcome/4` doesn't currently accept a `:metadata` opt — `persist/9` hardcodes `metadata: %{}` at line 183. Extend the wrapper to merge caller-supplied metadata into that map. Low-risk, keeps pipelines from needing a second write path.

    **Context modes:**
    - `"previous"` (default): stage N receives `initial_prompt` + immediate prior stage output.
    - `"accumulate"`: stage N receives all prior stage outputs joined with stage headers. Document token-budget footgun in the tool doc; consider a cap in 0.4.3 if it bites.
    - `prompt_override`: wins unconditionally.

    **Failure:** first `{:error, _}` halts; earlier rows persist normally (the async writer fired already); a row for the failing stage is written with `status: :error` by `with_outcome/4`.

    **Return shape:**
    ```elixir
    {:ok, %{
      pipeline_name: ...,
      stages: [%{stage: idx, strategy: user_name, output: str, status: :ok}, ...],
      final_output: last_output,
      usage: %{input_tokens: sum, output_tokens: sum}
    }}
    ```

### Files to modify

17. **`lib/jido_claw/reasoning/telemetry.ex`** — extend `@type opts` with `metadata: map()`, and in `persist/9` merge caller-supplied metadata into the hardcoded `metadata: %{}` at line 183. Final write: `Map.merge(default_metadata, caller_metadata)` — default provides fallback keys, caller wins on collision. Needed by pipelines (see #16) and cheap.

18. **`lib/jido_claw/reasoning/execution_kind.ex`** — extend enum to `[:strategy_run, :react_stub, :certificate_verification, :pipeline_run]`. **No SQL migration** — column is `:text` with no CHECK constraint (verified in `priv/repo/migrations/20260418000139_create_reasoning_outcomes.exs:19`).

19. **`lib/jido_claw/reasoning/resources/outcome.ex`** — add `index([:pipeline_name, :pipeline_stage])` in the `postgres` block's `custom_indexes`. 0.4.3's aggregations consume this.

20. **`priv/repo/migrations/<timestamp>_add_pipeline_index.exs`** (new) — auto-generated by `mix ash_postgres.generate_migrations`. Commit any `priv/resource_snapshots/` changes too.

21. **Tool-count synchronization — `agent.ex:6`, `cli/repl.ex:36`, `cli/branding.ex:43`, `priv/defaults/system_prompt.md:11`** — these four display/document the total tool count and **have already drifted from each other** (per finding #5 in review). Do not blindly increment.

    **Concrete refactor**: in `lib/jido_claw/agent/agent.ex` the tool list is currently a literal list passed to `use Jido.Agent` (line ~36, after the module doc). Extract it to a module attribute and expose a helper:
    ```elixir
    @tools [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      # ... existing entries + JidoClaw.Tools.RunPipeline
    ]

    use Jido.AI.Agent, tools: @tools, # ... other opts unchanged

    @doc "Canonical tool module list. Used by REPL banner + branding for accurate counts."
    def tool_modules, do: @tools
    ```
    Then `cli/repl.ex:36` and `cli/branding.ex:43` compute `length(JidoClaw.Agent.tool_modules())` at render time — future tool additions update automatically. `agent.ex:6` module doc and `priv/defaults/system_prompt.md:11` remain hardcoded-but-recounted strings (both static text). All four show the same number after this change. Centralizing further (e.g., a single `tool_count/0` helper) is out of scope.

22. **`priv/defaults/system_prompt.md`** — document `run_pipeline`. Rename the reasoning-tools section header from 1 → 2 tools. Add decision-framework bullet ("multi-stage reasoning → `run_pipeline`") and a row to the Quick Reference table. `Prompt.sync/1` will produce `.jido/system_prompt.md.default` sidecars on next boot for modified projects — intended. Bundle the tool-count recount from #21 into the same edit.

### Tests

23. **`test/jido_claw/tools/run_pipeline_test.exs`** (new) — `compose_prompt/3` unit coverage for `previous`/`accumulate`/`prompt_override`; fail-fast on empty `stages: []`, unknown stage strategy, and react-resolving stage (including via alias); 2-stage integration with `:reasoning_telemetry_sync` asserts two rows with zero-padded `pipeline_stage` ("001/002", "002/002"), `base_strategy` matching the resolved built-in, `execution_kind: :pipeline_run`, and `metadata` containing `stage_index`/`stage_total`; mid-pipeline error persists earlier rows + the failing row with `status: :error`.

24. **`test/jido_claw/reasoning/telemetry_test.exs`** — add a case for the new `metadata` opt (caller wins on collision); add a case asserting the react-stub wrap writes a row with `execution_kind: :react_stub` when `Reason` is called with a react-resolving strategy.

---

## Key patterns to reuse (verified in Phase 1)

- `JidoClaw.Skills` GenServer lifecycle (`lib/jido_claw/platform/skills.ex`) — mirror init → continue → lazy load → `reload/0`.
- `Telemetry.with_outcome/4` (`lib/jido_claw/reasoning/telemetry.ex:46`) — extend opts for cert fields + `:metadata`; no signature change.
- `YamlElixir.read_from_file/1` + graceful `Logger.warning` per `Skills.parse_skill_file/1`.
- Runner injection via `context[:reasoning_runner]` (per `VerifyCertificate.run_reasoning/2:119`) — apply same pattern to `RunPipeline`.

---

## Verification

### Compile + unit
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test test/jido_claw/reasoning/telemetry_test.exs
mix test test/jido_claw/reasoning/strategy_store_test.exs
mix test test/jido_claw/reasoning/strategy_registry_test.exs
mix test test/jido_claw/reasoning/classifier_test.exs
mix test test/jido_claw/tools/reason_test.exs
mix test test/jido_claw/tools/verify_certificate_test.exs
mix test test/jido_claw/tools/run_pipeline_test.exs
mix test
```

### Migration
```
mix ash_postgres.generate_migrations
mix ecto.migrate
```

### DB smoke (via `mcp__tidewave__execute_sql_query`)
```sql
SELECT strategy, base_strategy, execution_kind,
       pipeline_name, pipeline_stage, metadata->>'stage_index' AS stage_idx,
       certificate_verdict, certificate_confidence,
       tokens_in, tokens_out, status
FROM reasoning_outcomes
ORDER BY started_at DESC
LIMIT 20;
```
Expect:
- Cert rows: `execution_kind='certificate_verification'` + verdict/confidence + non-null `tokens_in`/`tokens_out` (including on parse-failure rows per A.2's error-side usage passthrough).
- Pipeline rows: `execution_kind='pipeline_run'` + `pipeline_name` + zero-padded `pipeline_stage` + numeric `stage_idx` from `metadata` + non-null tokens (including on mid-pipeline failures).
- React-stub rows: `execution_kind='react_stub'` + `base_strategy='react'` (for both direct react calls and react-aliased calls). **Tokens expected to be `nil`** — the react branch returns a structured prompt with no `usage` map; this is not a bug.
- Non-react-alias rows: `strategy != base_strategy` (e.g., `strategy='fast_reviewer'`, `base_strategy='cot'`) + non-null tokens.
- General `:strategy_run` rows (direct built-in invocation): `strategy == base_strategy` + non-null tokens.

### REPL exercise (`iex -S mix`)
```elixir
# A: Certificate
JidoClaw.Tools.VerifyCertificate.run(
  %{code: "def add(a,b), do: a+b", specification: "Adds two numbers"}, %{})

# B: User strategies — one react-based, one non-react to demonstrate strategy != base_strategy
File.mkdir_p!(".jido/strategies")
File.write!(".jido/strategies/deep_debug.yaml", """
name: deep_debug
base: react
display_name: "Deep Debug"
description: "Aggressive debugging"
prefers:
  task_types: [debugging]
  complexity: [complex, highly_complex]
""")
File.write!(".jido/strategies/fast_reviewer.yaml", """
name: fast_reviewer
base: cot
display_name: "Fast Reviewer"
description: "CoT tuned for quick code review"
prefers:
  task_types: [qa, verification]
  complexity: [simple, moderate]
""")
JidoClaw.Reasoning.StrategyStore.reload()
JidoClaw.Reasoning.StrategyRegistry.plugin_for("deep_debug")     # {:ok, Jido.AI.Reasoning.ReAct}
JidoClaw.Reasoning.StrategyRegistry.plugin_for("fast_reviewer")  # {:ok, Jido.AI.Reasoning.ChainOfThought}
JidoClaw.Reasoning.StrategyRegistry.prefers_for("deep_debug")    # %{task_types: [:debugging], ...}
JidoClaw.Tools.Reason.run(%{strategy: "deep_debug", prompt: "why is x broken?"}, %{})
# → dispatched via react branch; writes reasoning_outcomes row with
#   execution_kind=:react_stub, strategy="deep_debug", base_strategy="react", tokens=nil
JidoClaw.Tools.Reason.run(%{strategy: "fast_reviewer", prompt: "Review: def add(a,b), do: a+b"}, %{})
# → dispatched via RunStrategy with :cot; writes reasoning_outcomes row with
#   execution_kind=:strategy_run, strategy="fast_reviewer", base_strategy="cot", tokens populated

# C: Pipeline (CoT planning → ToT exploration). React stays the agent's own loop;
# pipelines reject any react-resolving stage. To act on the pipeline output,
# let the agent call run_pipeline and then act via its native ReAct loop.
JidoClaw.Tools.RunPipeline.run(%{
  pipeline_name: "plan_then_explore",
  prompt: "Design a caching layer",
  stages: [
    %{"strategy" => "cot", "context_mode" => "previous"},
    %{"strategy" => "tot", "context_mode" => "previous"}
  ]
}, %{})
```

---

## Commit plan

1. **`feat: wrap verify_certificate in reasoning telemetry; fix token extraction`**
   Sections: P1, P2 (docs-only for now), P3, A. Updates `docs/ROADMAP.md`, `telemetry.ex`, `verify_certificate.ex`, tests. Tiny, closes 0.4.1 debt.

2. **`feat: user-defined reasoning strategies via .jido/strategies/*.yaml`**
   Sections: B. New `StrategyStore` GenServer, registry delegation, `Reason.run_strategy/3` alias-aware dispatch, `/strategies` CLI display_name support, startup hook, classifier-test async fix. No migration.

3. **`feat: RunPipeline tool for sequential strategy composition`**
   Sections: C. New tool, `ExecutionKind` + `:pipeline_run`, `:metadata` opt on telemetry wrapper, pipeline index migration, system-prompt update, tool-count **recount and synchronize** across `agent.ex`/`repl.ex`/`branding.ex`/`system_prompt.md`, tests.

Each PR green on `mix test` and `mix compile --warnings-as-errors`.

---

## Risks & notes

- **Prompt composition tokens** — `"accumulate"` mode is unbounded. Document the footgun; revisit with a `max_context_bytes` cap in 0.4.3 if users hit it.
- **Async test discipline** — any test exercising `StrategyRegistry`, `Classifier`, or `Reason` against user strategies must run `async: false`. `classifier_test.exs` is the one existing case that must flip; flag in PR #2.
- **System-prompt sidecar noise** — prompt edit in PR #3 will produce a single `.jido/system_prompt.md.default` for projects with modified prompts. Intended.
- **Tool count drift** — four places (`agent.ex`, `repl.ex`, `branding.ex`, `priv/defaults/system_prompt.md`) already out of sync. PR #3's `@tools` refactor (item 21) brings `repl.ex` and `branding.ex` onto a dynamic count; the two static strings stay hardcoded-but-recounted. Further centralization (e.g., a `Tool.count/0` helper or generating the system-prompt tool table at boot) is out of scope.
