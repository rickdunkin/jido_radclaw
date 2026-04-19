# v0.4.3 — Auto-selection & Feedback

## Context

v0.4.1 shipped a heuristic `Classifier`, a `Telemetry.with_outcome/4` wrapper, and an Ash-backed `reasoning_outcomes` resource. v0.4.2 shipped user-strategy aliases, `RunPipeline` composition, and telemetry coverage across `:react_stub` + `:certificate_verification` + `:pipeline_run` execution kinds. Rows are flowing into `reasoning_outcomes`, but nothing consumes them yet.

v0.4.3 closes that loop. `reason(strategy: "auto")` becomes the **single** history-aware selector in the product: there is one story, not two competing auto-selectors. The key design choice is that `auto` drives the selection and `reasoning_outcomes.strategy` always stores the **concrete winner** (`cot`, `tot`, …), so `Statistics.best_strategies_for/2` learns from real winners and can feed itself. `adaptive` is accepted as a deprecated compatibility alias that normalizes to `auto` at the tool boundary; it is **not** made recommendable by the classifier. At the same time, `reasoning_outcomes` gets the session/agent attribution columns the ROADMAP promised, and the REPL gets a `/strategies stats` view over the dataset.

Explicitly deferred (per ROADMAP.md:145-150): the pre-existing `/strategy state.strategy → handle_message/2` disconnect belongs in v0.4.4.

## Design decisions

1. **Single selector.** `reason(strategy: "auto")` is the only history-aware selector. No separate `AutoReason` tool.
2. **`adaptive` → `auto` at the tool boundary.** `adaptive` stays valid as an input so old prompts and built-in docs don't break; `Reason.run/2` normalizes it to `"auto"` before dispatch. `Classifier.recommend/2` continues to reject `adaptive` from its candidate list — we do **not** expand `adaptive`'s `prefers` metadata. (Rationale: `Jido.AI.Reasoning.Adaptive` runs its own internal selection, so letting the classifier pick it means two selectors compete for the same decision.)
3. **Exclude `react` from `auto` candidates.** `react` writes `execution_kind: :react_stub` rows, but history queries filter on `:strategy_run`. Worse, the react branch hands back a structured-prompt scaffold rather than a real runner result — useless as an auto pick. `AutoSelect` passes `exclude: ["react"]` to `Classifier.recommend/2`; the classifier's general recommendation (used by `/classify` and other direct callers) keeps react in the pool.
4. **Persist the concrete winner.** After `AutoSelect` picks, `reasoning_outcomes.strategy` holds the resolved strategy (`"cot"`, `"tot"`, …). The fact that selection was automatic lives in `metadata: %{selection_mode: "auto"}` plus `diagnostics` (heuristic rank, tie-break flag). This keeps `best_strategies_for/2` learning from real winners.
5. **Forge attribution uses a string, not a UUID.** Runtime forge sessions are keyed by a string `session_id` (see `forge/persistence.ex:18` — `name: session_id`); only the Ash row has a UUID PK. v0.4.3 adds `reasoning_outcomes.forge_session_key :string`, not a `:uuid` column. A separate nullable UUID FK can be added later once Forge can thread the DB UUID through `tool_context` directly.
6. **Windowed history — either/or, no merging.** `AutoSelect` queries `Statistics.best_strategies_for(task_type, since: 30d_ago)`. If the recent window has `>= @min_history_samples` total samples across returned rows, use recent. Otherwise **discard recent entirely** and re-query with `since: nil` for all-time. Merging per-strategy aggregates is fuzzy and double-counts; either/or keeps semantics clean.
7. **Update the Ash resource first; generate the migration.** Use `mix ash.codegen add_session_agent_to_reasoning_outcomes` rather than hand-maintaining both the migration and `custom_indexes`.
8. **`auto` becomes the canonical surfaced selector; `adaptive` is marked deprecated.** `/strategies`, help text, and the `Reason` tool schema doc all surface `auto` as the recommended choice. `adaptive`'s registry description changes to "Deprecated — alias for `auto`." Users see the right story without a breaking change.

## Approach

### 1. Classifier: consume `opts[:history]`; keep `adaptive` excluded; add `:exclude` opt

**File: `lib/jido_claw/reasoning/classifier.ex:100-120`**

- **Keep** the `Enum.reject(&(&1.name == "adaptive"))` filter at line 104. The block comment gets updated to explain *why* it stays (adaptive is reachable via `reason(strategy: "auto" | "adaptive")`, not via classifier recommendation).
- Add a new `opts[:exclude]` list that rejects candidate names in addition to the existing `adaptive` filter. This is what `AutoSelect` uses to keep `react` out of the auto pool without changing the classifier's default behavior for `/classify` and other direct callers. Default `[]`.
- Fold `opts[:history]` into the score. Shape matches `Statistics.best_strategies_for/2`: `[%{strategy, success_rate, avg_duration_ms, samples}]`.
- Scoring: **additive**, `final = heuristic + success_rate * @history_weight` when the strategy appears in history with `samples >= @min_history_samples`. Proposed constants: `@history_weight 0.3`, `@min_history_samples 5`. Unsampled strategies score on heuristics alone.
- `confidence = min(1.0, score)`; additive bonus saturates at 1.0 naturally.
- Add a `:ranked` return option — `recommend(profile, return: :ranked, history: h)` → `{:ok, [{name, score}, ...]}` — so `AutoSelect` can inspect the gap between top-2 without re-scoring. Default return stays the existing 3-tuple.

### 2. Classifier: do NOT grant `adaptive` new `prefers` metadata; mark it deprecated in the registry description

**File: `lib/jido_claw/reasoning/strategy_registry.ex:99-105`**

- `prefers` stays empty (see design decision #2).
- Update `description` to: `"Deprecated — alias for 'auto'. Selects a strategy automatically based on history and heuristics."` so `/strategies` and any callers listing the registry get the right message without a breaking change.

### 3. New module: `JidoClaw.Reasoning.AutoSelect`

**New file: `lib/jido_claw/reasoning/auto_select.ex`**

```elixir
@spec select(String.t(), keyword()) ::
        {:ok, String.t(), float(), TaskProfile.t(), map()}
```

Steps:
1. `Classifier.profile(prompt, opts)` → `TaskProfile`.
2. Windowed history (either/or, no merging):
   - Query `Statistics.best_strategies_for(profile.task_type, execution_kind: :strategy_run, since: DateTime.add(now, -@recent_window_days, :day))`.
   - Let `recent_total = Enum.sum_by(rows, & &1.samples)`.
   - If `recent_total >= @min_history_samples`, use `recent_rows`.
   - Otherwise **discard recent** and re-query with `since: nil` → use that result (may still be empty, which is fine — unsampled strategies score on heuristics alone).
3. `Classifier.recommend(profile, history: history, exclude: ["react"], return: :ranked)` → ranked candidates. Excluding react here is what makes the feedback loop honest — see design decision #3.
4. If `abs(top1_score - top2_score) < @tiebreak_threshold` (propose `0.05`) AND `opts[:llm_tiebreak] != false`, call `LLMTiebreaker.choose(prompt, top2_candidates, opts)`.
5. Return `{:ok, strategy, confidence, profile, diagnostics}` where `diagnostics = %{heuristic_rank, history_samples, history_window: :recent | :all_time | :empty, tie_broken_by_llm?, alternatives, selection_mode: "auto"}`. Diagnostics flow into `Telemetry.with_outcome/4`'s `:metadata` key.

Test hooks: `opts[:skip_history]` and `opts[:llm_tiebreak]: false` for deterministic unit tests.

### 4. New module: `JidoClaw.Reasoning.LLMTiebreaker`

**New file: `lib/jido_claw/reasoning/llm_tiebreak.ex`**

Takes a prompt + 2-3 candidate strategy names, returns `{:ok, chosen_name}` or `{:error, reason}`.
- Build a short structured prompt listing each candidate's `display_name`/`description` (from `StrategyRegistry.list/0`).
- Use the project's configured Jido.AI call path (mirror whatever `Jido.AI.Actions.Reasoning.RunStrategy` resolves for the configured model).
- Short timeout (~10s). On timeout/error, AutoSelect falls back to top heuristic.
- Telemetry: `[:jido_claw, :reasoning, :tiebreak, :invoked | :chose | :failed]`.

### 5. `Reason` tool: accept `"auto"` and `"adaptive"`; normalize

**File: `lib/jido_claw/tools/reason.ex`**

- Update schema doc (line 28) to lead with `auto`: `"Strategy: auto (recommended — history-aware selection), react, cot, cod, tot, got, aot, trm, adaptive (deprecated — alias for auto), or a user-defined alias"`.
- Update the moduledoc (lines 2-9) to mention `auto` as the canonical selector and `adaptive` as a deprecated alias.
- Add a normalization step at the top of `run/2` **before** `StrategyRegistry.valid?/1`:
  - If `params.strategy in ["auto", "adaptive"]`, call `AutoSelect.select(params.prompt, context_opts)` → `{:ok, concrete_strategy, confidence, profile, diagnostics}`, then delegate to the existing `run_strategy(concrete_strategy, prompt, context)`.
  - The existing `StrategyRegistry.valid?/1` branch handles everything else unchanged.
- Threading: when dispatching from the auto path, pass `profile: profile, metadata: Map.put(diagnostics, :selection_mode, "auto")` into the `Telemetry.with_outcome/4` opts so the row carries the concrete strategy with "this was an auto pick" context.
- Move the shared telemetry-opts builder into a small private helper so the auto path and the existing react/non-react paths stay DRY.
- `reasoning_outcomes.strategy` ends up storing the resolved concrete strategy — **never** "auto" or "adaptive".

### 6. `RunPipeline`: reject `auto` and `adaptive` the same way it rejects `react`

**File: `lib/jido_claw/tools/run_pipeline.ex:172-191`**

`validate_stage/2` already rejects `react`-resolving strategies. Add an analogous check: if `strategy in ["auto", "adaptive"]`, error with a message explaining that pipelines chain **concrete** strategies, not selectors — pick a concrete strategy per stage. Prevents an "auto" stage from re-introducing LLM-driven selection inside the composition loop.

### 7. `forge_session_key` + `agent_id` plumbing

**Ash resource first: `lib/jido_claw/reasoning/resources/outcome.ex`**

- Add `attribute :forge_session_key, :string, allow_nil?: true, public?: true`.
- Add `attribute :agent_id, :string, allow_nil?: true, public?: true`.
- Add both to the `:record` action's `accept` list.
- Add `custom_indexes` entries: `index([:forge_session_key])`, `index([:agent_id, :started_at])`.
- Remove the "Deferred columns (0.4.3)" moduledoc note.

**Migration:** `mix ash.codegen add_session_agent_to_reasoning_outcomes` — generates migration + resource snapshot from the resource diff. No hand-maintained migration.

**Telemetry: `lib/jido_claw/reasoning/telemetry.ex`**

- Add `:forge_session_key` and `:agent_id` to the `@type opts` and documentation.
- Thread them through `persist/8` → `Outcome.record/1` alongside the existing `:workspace_id` / `:project_dir`.

**Tool context threading:**

Entry points that build `tool_context` all gain `agent_id` (nil-safe) and `forge_session_key` (nil except on forge-adjacent paths):

- `lib/jido_claw/cli/repl.ex:~L152` — REPL owns the `"main"` agent; pass `agent_id: "main"` (add to `state` at init so tests and future entry points can swap it).
- `lib/jido_claw.ex:~L59` — pass `agent_id: session_id`, **not** `"main"`. The agent is resolved/started under `id: session_id` at line 46, so that's its runtime identity. Misattribution here is the biggest blast-radius risk in the whole change; this line is the fix.
- `lib/jido_claw/tools/spawn_agent.ex:~L52` — child gets `agent_id: tag` (the `template_name_unique_int` string already computed by the spawn helper).
- `lib/jido_claw/tools/send_to_agent.ex:~L31-47` — same treatment, two problems to fix here:
  1. `child_tool_context/2` currently only builds `%{project_dir, workspace_id}` — extend it to include `agent_id: params.agent_id` (the recipient agent) and `forge_session_key` (passed through from caller context).
  2. The fallback `ask_sync` call at line 47 drops `tool_context` entirely. Include `tool_context: child_tool_context` there too, otherwise follow-up messages on child agents silently lose attribution.
- `lib/jido_claw/workflows/step_action.ex` — accept `agent_id` from workflow context; propagate into `tool_context`.

**Tool-side consumption — extract from context, forward to `Telemetry.with_outcome/4`:**

- `lib/jido_claw/tools/reason.ex` — both telemetry call sites (react ~L77-87, non-react ~L121-131).
- `lib/jido_claw/tools/run_pipeline.ex` — per-stage call site ~L214-232 (include in `opts`, not `metadata`).
- `lib/jido_claw/tools/verify_certificate.ex` — its telemetry call site.

**Forge-side population (best-effort in v0.4.3):** when a reasoning call happens inside a forge session, the forge runner should set `forge_session_key` in the `tool_context` it hands to the tool. If this plumbing doesn't land in v0.4.3, rows stay nil on that column — the column exists, the write path accepts it, and forge populates it opportunistically. No hard blocker for v0.4.3 to ship without forge integration.

### 8. `Statistics.summary/0` enrichment

**File: `lib/jido_claw/reasoning/statistics.ex:76-105`**

Current shape (line 83-87) only returns `samples` + `ok_count` per strategy — no `success_rate`, no `avg_duration_ms`, no ordering. The proposed `/strategies stats` output needs those.

Extend the strategies branch of `summary/0` to compute `success_rate` and `avg_duration_ms` (mirror the `best_strategies_for/2` select/post-process pattern from line 43-68) and sort by `success_rate desc, samples desc`. Same for task_types if we want to show ok% per task type, or leave task_types as samples-only if that's fine for the CLI.

Keep `summary/0`'s arity + return key shape, just enrich the per-row maps. If the existing shape has callers we need to protect, add `summary_enriched/0` instead — verify by grepping for `Statistics.summary` before choosing.

### 9. `/strategies stats` CLI command

**File: `lib/jido_claw/cli/commands.ex` (near existing `/strategies` handler at ~L558-603)**

Add `def handle("/strategies stats", state)` — a separate exact-match clause. Render `Statistics.summary()` using the same ANSI style as `/classify` (commands.ex:605-647): bold section headers, `▸` rows, dim "no data" fallback. Show per-strategy (samples, success rate %, avg duration ms) and per-task-type (samples, optionally ok%). Read-only; returns `{:ok, state}` unchanged.

### 10. Surface `auto` in user-facing discovery

The registry handles concrete dispatchable strategies; `auto` is a selector verb, not a strategy. Rather than force it into `StrategyRegistry.@strategies` (which would add a sentinel `module: nil` entry and special-case every consumer), inject it at the display layer.

**File: `lib/jido_claw/cli/commands.ex` — `/strategies` handler (~L558-577)**

At the top of the existing `/strategies` render, prepend a synthetic `auto` row:

```
▸ auto         Automatic selection — picks the best strategy per prompt (history + heuristics)
```

using the same formatting as registry entries. Then render the registry list as today; `adaptive`'s updated description will already read "Deprecated — alias for 'auto'" after the §2 change.

**File: `lib/jido_claw/core/config.ex`**

Grep confirmed this module holds the strategy whitelist consumed by config validation (`.jido/config.yaml`'s `strategy` key). Add `"auto"` to the accepted values so users can set `strategy: auto` as their default. Verify by searching for the strategy whitelist constant at implementation time; if the whitelist just proxies `StrategyRegistry.valid?/1`, then `Reason`'s normalization already covers this (since `valid?/1` is bypassed for `"auto"` / `"adaptive"` at the tool boundary) and we add `"auto"` explicitly to whatever list powers user-facing docs/help instead.

**Help text** (likely `lib/jido_claw/cli/branding.ex` or wherever `/help` renders):

Verify which module emits the help strategy list; add `auto` as the recommended default in the relevant help section. If there's no existing strategy mention in help text, skip — `/strategies` is the canonical surface and now lists `auto` at the top.

## Critical files

**New:**
- `lib/jido_claw/reasoning/auto_select.ex`
- `lib/jido_claw/reasoning/llm_tiebreak.ex`
- `priv/repo/migrations/*_add_session_agent_to_reasoning_outcomes.exs` (generated by `mix ash.codegen`)
- `priv/resource_snapshots/...` (regenerated by codegen)
- Tests: `test/jido_claw/reasoning/auto_select_test.exs`, `llm_tiebreak_test.exs`

**Modified:**
- `lib/jido_claw/reasoning/classifier.ex` — history scoring, `:exclude` opt, `:ranked` return, comment update
- `lib/jido_claw/reasoning/strategy_registry.ex` — `adaptive`'s description marked deprecated
- `lib/jido_claw/reasoning/resources/outcome.ex` — two new attributes + indexes + accept list + docs
- `lib/jido_claw/reasoning/telemetry.ex` — opts + persist passthrough
- `lib/jido_claw/reasoning/statistics.ex` — enrich `summary/0` with success_rate + avg_duration_ms
- `lib/jido_claw/tools/reason.ex` — normalize `"adaptive"` → `"auto"`, auto branch, DRY telemetry opts, moduledoc/schema-doc surface `auto`
- `lib/jido_claw/tools/run_pipeline.ex` — reject `auto`/`adaptive` stages; forward agent_id/forge_session_key
- `lib/jido_claw/tools/verify_certificate.ex` — forward agent_id/forge_session_key
- `lib/jido_claw/tools/spawn_agent.ex` — child agent_id in context
- `lib/jido_claw/tools/send_to_agent.ex` — include agent_id + forge_session_key; fix fallback's missing tool_context
- `lib/jido_claw/cli/repl.ex` — agent_id = "main" in state + tool_context
- `lib/jido_claw.ex` — `agent_id: session_id` (not `"main"`)
- `lib/jido_claw/workflows/step_action.ex` — agent_id threading
- `lib/jido_claw/cli/commands.ex` — `/strategies stats` handler + synthetic `auto` row in `/strategies`
- `lib/jido_claw/core/config.ex` — accept `"auto"` in strategy whitelist (verify whether it proxies `StrategyRegistry.valid?/1` first)
- `lib/jido_claw/cli/branding.ex` (or help module, TBD) — mention `auto` in help text if help surfaces strategies
- Existing tests: `classifier_test.exs`, `reason_test.exs`, `run_pipeline_test.exs`, `outcome_test.exs`, `telemetry_test.exs`, `statistics_test.exs`, `commands_test.exs`

## Existing code to reuse

- `JidoClaw.Reasoning.Statistics.best_strategies_for/2` — windowed history query already supports `:since` and `:execution_kind` (statistics.ex:34-70). `AutoSelect` consumes it as-is.
- `JidoClaw.Reasoning.Classifier.recommend_for/2` — `AutoSelect` delegates to `profile/2` + the new `recommend/2` with `:ranked` so there's no duplicated profile→recommend logic.
- `JidoClaw.Reasoning.StrategyRegistry.plugin_for/1`, `atom_for/1`, `list/0` — reused verbatim for resolution and LLM-tiebreak prompt construction.
- `JidoClaw.Reasoning.Telemetry.with_outcome/4` — extend opts, don't replace.
- `JidoClaw.CLI.Commands`'s `/classify` handler (commands.ex:605-647) — formatting idiom for `/strategies stats`.

## Scoring constants (first pass — tune in tests)

```elixir
# classifier.ex
@history_weight 0.3          # success_rate contribution to final score
@min_history_samples 5       # below this, strategy scores on heuristics alone

# auto_select.ex
@tiebreak_threshold 0.05     # score delta below which LLM tie-break fires
@recent_window_days 30       # history window before falling back to all-time
```

## Verification

**Unit:**
- `classifier_test.exs` — history boost applies above `@min_history_samples`; below the threshold, heuristics alone; `adaptive` stays rejected from recommendations; `:exclude` opt drops named candidates; `:ranked` return shape is stable.
- `auto_select_test.exs` — stubbed `Statistics` + stubbed `LLMTiebreaker`: history-only path, tie-break path, tie-break-disabled path, LLM-failure fallback, windowed either/or (recent with enough samples → uses recent; recent sparse → falls back to all-time, never merges); `react` never appears as an auto pick even when history has `:strategy_run` rows for other strategies.
- `llm_tiebreak_test.exs` — happy path, timeout/error, structured prompt shape.
- `reason_test.exs` — `strategy: "auto"` dispatches via `AutoSelect` and writes a `reasoning_outcomes` row whose `strategy` column is the **concrete** winner (not `"auto"`) and whose `metadata.selection_mode == "auto"`. Same assertion for `strategy: "adaptive"`.
- `run_pipeline_test.exs` — a stage with `strategy: "auto"` or `"adaptive"` fails validation with a clear error, same shape as the existing react rejection.
- `outcome_test.exs` — `:record` accepts and persists `forge_session_key` + `agent_id`; indexes present.
- `telemetry_test.exs` — `with_outcome` opts carry new keys; `nil` when absent.
- `statistics_test.exs` — `summary/0` returns per-strategy rows with `success_rate` + `avg_duration_ms` + sort order.
- `commands_test.exs` — `/strategies stats` renders enriched summary; empty-dataset fallback text; `/strategies` output lists `auto` as the first row and shows `adaptive` as deprecated.

**Integration:**
- `mix ash.codegen add_session_agent_to_reasoning_outcomes` generates a clean migration; `mix ecto.migrate` runs; `mix test` green after `ash.setup --quiet`.
- REPL: `/classify plan a refactor`, `/strategies`, `/strategies stats` — visual check of output style vs existing commands.
- REPL chat turn → `SELECT strategy, agent_id, workspace_id, metadata FROM reasoning_outcomes ORDER BY started_at DESC LIMIT 5;` — confirm `agent_id = "main"` and `metadata.selection_mode` exists where auto was invoked.
- `JidoClaw.chat("default", "my_session", "…")` → confirm row has `agent_id = "my_session"` (the `session_id`, not `"main"`).
- Spawn a sub-agent via `spawn_agent`, have it reason, confirm its row has the child tag as `agent_id`.
- Issue a follow-up via `send_to_agent` to the spawned child, have it reason again, confirm the second row **also** has the child tag (catches the fallback-path tool_context regression).
- `reason(strategy: "auto")` with a tied-strategy prompt (e.g., something the heuristic scores two strategies close on) — confirm LLM tie-break fires, `metadata.tie_broken_by_llm?` is true.

**Compile/lint:**
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`

## Out of scope (deferred to v0.4.4 per ROADMAP.md:141-150)

- Wiring `state.strategy` into `handle_message/2` (pre-existing `/strategy` disconnect).
- YAML-defined pipeline compositions.
- `max_context_bytes` cap for `accumulate` pipeline context mode.
- Custom prompt templates in user strategies.
- Forge runners actively populating `forge_session_key` in tool_context (column + plumbing land here; population can land whenever forge integrates, doesn't block v0.4.3).
