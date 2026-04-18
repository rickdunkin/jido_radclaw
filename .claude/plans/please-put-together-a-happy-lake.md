# v0.4.1 — Reasoning Foundations

## Context

v0.3 shipped VFS integration; reasoning is the next roadmap milestone. `lib/jido_claw/reasoning/` has a static registry of 8 strategies (`strategy_registry.ex`) and recently-added semi-formal certificate templates (`certificates.ex`, commit `957d0ae`), but:

- Strategies are always user-specified — no complexity analysis, no auto-selection, no historical data.
- There's no telemetry or persistence for strategy outcomes.
- `.jido/system_prompt.md` is written once from `priv/defaults/system_prompt.md` and never updated, so updates to the bundled default never reach existing users.

Phase **0.4.1** ships three foundations: system prompt auto-sync, a pure heuristic classifier, and a DB-backed outcome store with telemetry wrapping around strategy calls. 0.4.2 (user-defined strategies, pipeline composition, `verify_certificate` telemetry wrap) and 0.4.3 (auto-selection + feedback loop + CLI surfaces) build on these. Each sub-phase is independently shippable.

Confirmed scope: **phase 0.4.1 only**; tracking store is **Ash/PostgreSQL**; sync conflict resolution is **stamp + sidecar file**, with the stamp held *outside* the prompt file itself.

---

## Shared startup path (and app-start ordering fix)

**Two problems need to be fixed together:**

### Problem 1 — pre-existing: `project_dir` drifts from app-managed services

`lib/jido_claw/application.ex:131,135,138,141` starts `Solutions.Store`, `Memory`, `Skills`, and `Network.Supervisor` with `project_dir()` resolved from `Application.get_env(:jido_claw, :project_dir, File.cwd!())` (line 160). But the two non-MCP entry points parse `project_dir` from argv **after** starting the app:

- `lib/mix/tasks/jidoclaw.ex:23` — `Mix.Task.run("app.start")` before arg parsing.
- `lib/jido_claw/cli/main.ex:21` — `Application.ensure_all_started(:jido_claw)` before arg parsing.

If a user runs `jido /some/other/path`, the app's children initialize against `File.cwd!()` while the REPL uses `/some/other/path`. Pre-existing drift, unrelated to prompt sync — but Track A must fix it because `Startup.ensure_project_state/1` would inherit the same confusion otherwise.

**Fix (Track A):** Parse `project_dir` from argv **before** `app.start` / `ensure_all_started` and set it explicitly:

```elixir
# In both entry points:
project_dir = resolve_project_dir_from_argv(args)
Application.put_env(:jido_claw, :project_dir, project_dir)
# THEN start the app
```

MCP entry points have no arg to resolve — just `Application.put_env(:jido_claw, :project_dir, File.cwd!())` before start. Explicit is better than relying on the `File.cwd!()` fallback.

### Problem 2 — `Prompt.sync/1` must run across every agent entry point

| Entry point | File `.jido/` bootstrap today? | Injects system prompt onto agent pid? |
|---|---|---|
| `CLI.Repl.start/1` (`lib/jido_claw/cli/repl.ex:44,100`) | yes (inline) | yes (line 100–102: `Prompt.build/1` → `Jido.AI.set_system_prompt/2`) |
| `JidoClaw.chat/3` (`lib/jido_claw.ex:28`) | **no** | **no** — agent runs with whatever default, not `.jido/system_prompt.md` |
| `mix jidoclaw --mcp` (`lib/mix/tasks/jidoclaw.ex:10`) | no | n/a (MCP is a tool server — no agent pid to inject into) |
| `jido --mcp` escript (`lib/jido_claw/cli/main.ex:36`) | no | n/a |

**Fix:** two helpers in a new `lib/jido_claw/startup.ex`.

```elixir
defmodule JidoClaw.Startup do
  @moduledoc "Project-local state + agent bootstrapping. Call from every entry point."

  # File bootstrapping — idempotent. IO, so failures surface.
  # Returns the prompt sync result so callers can print a notice inline.
  @spec ensure_project_state(String.t()) ::
          {:ok, prompt_sync: :noop | :overwritten | :sidecar_written | :stamp_only}
          | {:error, term()}
  def ensure_project_state(project_dir)

  # Agent prompt injection — call after agent_pid is known.
  # Single canonical place for `Prompt.build/1` + `Jido.AI.set_system_prompt/2`.
  # Emits `[:jido_claw, :agent, :prompt_injected]` telemetry with %{bytes: byte_size(prompt)}
  # so tests can assert without depending on an unavailable get-prompt API.
  @spec inject_system_prompt(pid(), String.t()) :: :ok | {:error, term()}
  def inject_system_prompt(pid, project_dir)
end
```

The `{:error, term()}` branch in `ensure_project_state/1` matches `Prompt.sync/1`'s public contract and the reality that file IO can fail; callers must handle it.

### Call sites (all updated in Track A)

- `lib/mix/tasks/jidoclaw.ex:10` and `:22` — **new**: parse argv → `Application.put_env(:jido_claw, :project_dir, resolved)` → then `Mix.Task.run("app.start")`. MCP branch sets cwd before start. Both branches end with `Startup.ensure_project_state(resolved)`.
- `lib/jido_claw/cli/main.ex:11` and `:20` — same pattern for escript.
- `lib/jido_claw/cli/repl.ex:44-47` — replace the three inline `ensure` calls with `Startup.ensure_project_state/1`; pattern-match `{:ok, prompt_sync: :sidecar_written}` to print a one-line notice inline before the `IO.gets` loop starts. Replace the inline prompt injection at line 100–102 with `Startup.inject_system_prompt/2`.
- `lib/jido_claw.ex:28` — call `Startup.ensure_project_state(File.cwd!())` at the top of `chat/3`. After `agent_pid` is obtained (existing lines 36-48), call `Startup.inject_system_prompt(agent_pid, File.cwd!())`. **Behavior change**: `chat/3` agents now pick up `.jido/system_prompt.md` content (they previously did not). Acceptable because REPL already does this; the two entry points should converge.

### Notice path

`CLI.Repl.start/1` is a blocking `IO.gets` loop (`repl.ex:154`) with no signal-handling mailbox. The earlier "REPL subscribes to signal" idea is scrapped — `ensure_project_state/1` returns `{:ok, prompt_sync: :sidecar_written}` and the REPL prints the one-liner synchronously before the input loop starts. The signal is retained purely for non-CLI observers (LiveView, future dashboards).

---

## Item 5 — `.jido/system_prompt.md` auto-sync

### Metadata lives outside the prompt file

`Prompt.load_base_prompt/1` (`lib/jido_claw/agent/prompt.ex:124`) feeds file bytes directly to the LLM. Any stamp written into the prompt file would appear in every model call.

Store the stamp in a sidecar file `.jido/.system_prompt.sync`:

```yaml
# Managed by JidoClaw. Do not edit.
default_sha: 8f3a2c...   # SHA-256 of the bundled default that was last written / acknowledged
body_sha: 8f3a2c...      # SHA-256 of .jido/system_prompt.md at stamp time
```

No `version` field (the repo reports `@version "0.3.0"` at `lib/jido_claw.ex:19`; it would drift). SHA comparison alone is sufficient.

### Files

Modify:
- `lib/jido_claw/agent/prompt.ex` — add `sync/1`, `current_default_sha/0`. `ensure/1` keeps its current "write default if missing" behavior; additionally writes the sync sidecar on first run.
- `lib/jido_claw/cli/commands.ex` — `/upgrade-prompt` REPL command.
- `lib/jido_claw/cli/branding.ex:137` — add `/classify` and `/upgrade-prompt` to help text.
- `test/jido_claw/prompt_test.exs` (existing `async: false`) — extend with `describe "sync/1"`.

Create:
- `lib/jido_claw/startup.ex` (above).

### Decision table — `Prompt.sync/1`

Inputs on each call: on-disk body SHA, sidecar `default_sha` and `body_sha` (if present), bundled `@current_default_sha`, whether `.jido/system_prompt.md.default` sidecar file exists, its SHA if present.

| Sidecar sync present? | Body unmodified vs. stored body SHA? | Stored default = bundled? | `.default` file present & matches bundled? | Action |
|---|---|---|---|---|
| yes | yes | yes | — | no-op |
| yes | yes | no | — | overwrite `.jido/system_prompt.md` with bundled, rewrite sync, log `:info`, return `:overwritten` |
| yes | no (user edits) | yes | — | re-stamp only the body SHA (user sits on latest default), return `:stamp_only` |
| yes | no (user edits) | no | yes (already offered) | no-op — don't re-notify, return `:noop` |
| yes | no (user edits) | no | no | write `.default` sidecar, emit signal, return `:sidecar_written` |
| missing | — | — | — | compute body vs bundled; if match → write sync with matching shas silently (migrate pre-0.4 user); if diverge → write `.default` sidecar + sync stamped to what's on disk |

The new `:noop` row for "sidecar already exists and matches current bundled default" (thanks to feedback) prevents re-notification on every REPL start while a user sits on an unresolved upgrade.

Atomic writes: `File.write/2` to temp path + `File.rename/2`.

### `/upgrade-prompt` command

Moves `.jido/system_prompt.md` to `.jido/system_prompt.md.bak`, renames `.default` into place, updates `.system_prompt.sync` to reflect the now-current default and body. Refuses (readable error) if no sidecar.

### Public API

```elixir
@spec sync(String.t()) ::
        {:ok, :noop | :overwritten | :sidecar_written | :stamp_only}
        | {:error, term()}

@spec current_default_sha() :: String.t()
```

### Tests (all `async: false`, file-level)

- Sync file parse/write roundtrip; malformed YAML treated as missing.
- Every row of the decision table, including the new "sidecar already offered" noop.
- Expose `__sync_with__/3` (injectable default bytes + SHA) to simulate a changed bundled default without macro mocking.
- `/upgrade-prompt` with and without sidecar.

---

## Item 1 — Heuristic classifier (no auto-wiring)

0.4.1 ships the classifier module + a `/classify <prompt>` debugging command. `AutoReason` tool and `Reason strategy: "auto"` wiring are 0.4.3.

### Files

Create:
- `lib/jido_claw/reasoning/task_profile.ex` — struct + `@type t`.
- `lib/jido_claw/reasoning/classifier.ex` — pure functions.
- `test/jido_claw/reasoning/classifier_test.exs` (`async: true`).
- `test/fixtures/classifier_prompts/*.md` — golden regression prompts.

Modify:
- `lib/jido_claw/reasoning/strategy_registry.ex` — add `prefers: %{task_types: [...], complexity: [...]}` per strategy; add `prefers_for/1`. Existing API unchanged.
- `lib/jido_claw/cli/commands.ex` — `/classify <prompt>` command.
- `lib/jido_claw/cli/branding.ex:137` — help text.

### Struct (with explicit type)

```elixir
defmodule JidoClaw.Reasoning.TaskProfile do
  @type task_type ::
          :planning | :debugging | :refactoring | :exploration
          | :verification | :qa | :open_ended

  @type complexity :: :simple | :moderate | :complex | :highly_complex

  @type t :: %__MODULE__{
          prompt_length: non_neg_integer(),
          word_count: non_neg_integer(),
          domain: String.t() | nil,
          target: String.t() | nil,
          task_type: task_type(),
          complexity: complexity(),
          has_code_block: boolean(),
          has_constraints: non_neg_integer(),
          has_enumeration: boolean(),
          mentions_multiple_files: boolean(),
          error_signal: boolean(),
          keyword_buckets: %{optional(atom()) => non_neg_integer()}
        }

  defstruct [
    :prompt_length, :word_count, :domain, :target,
    :task_type, :complexity, :has_code_block, :has_constraints,
    :has_enumeration, :mentions_multiple_files, :error_signal, :keyword_buckets
  ]
end
```

Reuse `JidoClaw.Solutions.Fingerprint.extract_domain/1` + `extract_target/1`.

### Heuristic

- `task_type` — keyword majority vote across buckets; `:debugging` if `error_signal`; fallback `:open_ended`.
- `complexity` — 0–100 score: `prompt_length/10` + `10 × constraint_count` + `15 × has_code_block` + `10 × mentions_multiple_files` + `20 × has_enumeration`. Buckets `<20 :simple`, `20–50 :moderate`, `50–80 :complex`, `>80 :highly_complex`.

### Purity

`Classifier.profile/2` stays pure — no signals, no IO. Signal emission (`jido_claw.reasoning.classified`) moves to the `/classify` command handler and `Telemetry.with_outcome/4`. Matches `Solutions.Fingerprint`'s structure.

### API

```elixir
defmodule JidoClaw.Reasoning.Classifier do
  @spec profile(String.t(), keyword()) :: TaskProfile.t()
  @spec recommend(TaskProfile.t(), keyword()) ::
          {:ok, String.t(), float()} | {:error, term()}
  @spec recommend_for(String.t(), keyword()) ::
          {:ok, String.t(), float(), TaskProfile.t()}
end
```

`opts[:history]` accepted but unused in 0.4.1; 0.4.3 will feed stats into it.

**`"adaptive"` is excluded from `recommend/2` in 0.4.1.** It delegates to `Jido.AI.Reasoning.Adaptive` which isn't fully wired end-to-end, and `/strategy` itself is cosmetic today (`/strategy <name>` at `commands.ex:578` sets `state.strategy`, but `handle_message/2` at `repl.ex:194` never reads it — pre-existing; 0.4.3 wires it alongside `AutoReason`). Recommending `adaptive` now would be a regression. Re-enable in 0.4.3.

### `/classify <prompt>`

Prints profile + recommended strategy + confidence. No execution. Emits `jido_claw.reasoning.classified` signal for observability.

### Tests (`async: true`)

- Golden fixtures: debugging stack trace → `:debugging` + `react`; planning prompt with numbered questions → `:planning` + `tot`; simple "what is X?" → `:qa` + `cot`.
- Deterministic tie-breaking.
- Assertion: `recommend/2` never returns `adaptive`.
- `recommend/2` accepts but ignores `opts[:history]` in 0.4.1 (explicit test).

---

## Item 3 — Strategy performance tracking (Ash + telemetry)

### Files

Create:
- `lib/jido_claw/reasoning/domain.ex` — Ash domain (mirror `lib/jido_claw/forge/domain.ex`).
- `lib/jido_claw/reasoning/resources/outcome.ex` — `reasoning_outcomes` resource.
- `lib/jido_claw/reasoning/execution_kind.ex` — `Ash.Type.Enum` `[:strategy_run, :react_stub, :certificate_verification]`.
- `lib/jido_claw/reasoning/task_type.ex` — enum with classifier task types.
- `lib/jido_claw/reasoning/complexity.ex` — enum with four levels.
- `lib/jido_claw/reasoning/outcome_status.ex` — enum `[:ok, :error, :timeout]`.
- `lib/jido_claw/reasoning/telemetry.ex` — `with_outcome/4` + async writer.
- `lib/jido_claw/reasoning/statistics.ex` — aggregation scaffold (hot path is 0.4.3).
- `priv/repo/migrations/YYYYMMDDHHMMSS_create_reasoning_outcomes.exs` — **generated via `mix ash.codegen`**, not hand-written.
- `priv/resource_snapshots/repo/reasoning_outcomes/...` — generated.
- `test/jido_claw/reasoning/outcome_test.exs` (`async: false`).
- `test/jido_claw/reasoning/telemetry_test.exs` (`async: false`).
- `test/jido_claw/reasoning/statistics_test.exs` (`async: false`).

Modify:
- `config/config.exs` — register `JidoClaw.Reasoning.Domain` in `ash_domains`.
- `config/test.exs` — `config :jido_claw, :reasoning_telemetry_sync, true` for synchronous outcome writes in tests.
- `lib/jido_claw/tools/reason.ex` — wrap **only** the non-react `run_strategy/3` clause at line 75. The `"react"` clause at line 53 is a structured prompt template, not a real strategy execution; do NOT wrap.

### `verify_certificate` — explicitly NOT wrapped in 0.4.1

**Decision (single source of truth):** `lib/jido_claw/tools/verify_certificate.ex` is **not** wrapped in telemetry in 0.4.1. The enum `execution_kind` is still defined (so the DB column + codegen are correct from day one), but the `:certificate_verification` value is only populated starting 0.4.2, when verify_certificate integration lands alongside user strategies. Rationale:
- Avoids two behavior shifts in one phase.
- `verify_certificate.ex` forces `:cot` internally for a verification purpose — semantically distinct from general strategy runs. Wrapping it correctly requires the filter in `Statistics.best_strategies_for/2` to be battle-tested first, which is the 0.4.2/0.4.3 motivation.
- Tests in 0.4.1 reference `:strategy_run` only; `:certificate_verification` gets a placeholder assertion ("value is accepted by the enum") so the data model's readiness is verified without any runtime producer.

### Data model — cross-reference fields

`tool_context` today carries only `%{project_dir, workspace_id}`, confirmed at `lib/jido_claw.ex:59` and `lib/jido_claw/cli/repl.ex:194`. Tools read via `get_in(context, [:tool_context, :workspace_id])` (e.g., `lib/jido_claw/tools/read_file.ex:39-40`, `lib/jido_claw/tools/run_command.ex:56`).

0.4.1 captures only what exists:
- `workspace_id :string` (nullable)
- `project_dir :string` (nullable)

Deferred to 0.4.3 (documented as TODO in the resource docstring):
- `forge_session_id :uuid` — needs `tool_context` plumbing from `Forge.Session`.
- `agent_id :string` — needs `tool_context` plumbing through the swarm.

### Resource schema

Identity:
- `strategy :string` (not enum — 0.4.2 overlays introduce arbitrary names)
- `execution_kind :ExecutionKind` enum, required
- `base_strategy :string` (nullable; 0.4.2)
- `pipeline_name :string` / `pipeline_stage :string` (nullable; 0.4.2)

Profile snapshot (denormalized for single-scan aggregation):
- `task_type :TaskType` enum
- `complexity :Complexity` enum
- `domain :string` (nullable)
- `target :string` (nullable)
- `prompt_length :integer`

Outcome:
- `status :OutcomeStatus` enum
- `duration_ms :integer` (nullable)
- `tokens_in :integer` / `tokens_out :integer` (nullable)
- `certificate_verdict :string` (nullable; 0.4.2+)
- `certificate_confidence :float` (nullable; 0.4.2+)

Cross-ref (0.4.1 capture):
- `workspace_id :string` (nullable)
- `project_dir :string` (nullable)

Free-form:
- `metadata :map` default `%{}`
- `started_at :utc_datetime_usec`
- `completed_at :utc_datetime_usec` (nullable)

Custom indexes:
- `(strategy, task_type)`
- `(execution_kind, task_type)` — primary filter for statistics
- `(workspace_id, started_at)`
- `(status, task_type)`

Actions: `:read`, `:destroy`, `create :record` (primary), `read :by_task_type` with args `:task_type`, `:since`, `:execution_kind` (default `:strategy_run`).

Code interface: `record`, `list_by_task_type`.

Reference pattern: `lib/jido_claw/forge/resources/event.ex`.

### `Telemetry.with_outcome/4`

```elixir
@spec with_outcome(String.t(), String.t(), keyword(), (-> result)) :: result
      when result: {:ok, map()} | {:error, term()}
def with_outcome(strategy_name, prompt, opts, fun)
```

Opts:
- `:execution_kind` (required; `:strategy_run` in 0.4.1)
- `:workspace_id`, `:project_dir` (passed by caller after reading from `tool_context`)
- `:profile` (optional pre-computed `TaskProfile`)

Behaviors:
- Computes `TaskProfile` if not provided.
- Emits `[:jido_claw, :reasoning, :strategy, :start]` / `:stop` telemetry with `execution_kind`, `strategy`, `task_type`, `status` metadata.
- Async write via `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> Outcome.record(...) end)`. `JidoClaw.TaskSupervisor` is already in the supervision tree.
- Sync write when `Application.get_env(:jido_claw, :reasoning_telemetry_sync, false)` — test only.
- Rescue + `Logger.debug` on write failure. Never `:warning` or higher.
- Emits `jido_claw.reasoning.outcome_recorded` after successful persistence.

Call-site shape from `Reason.run_strategy/3` (non-react branch) — note the corrected `get_in` access, not `context[:key]`:

```elixir
defp run_strategy(strategy_name, prompt, context) do
  workspace_id = get_in(context, [:tool_context, :workspace_id])
  project_dir  = get_in(context, [:tool_context, :project_dir])
  {:ok, strategy_atom} = StrategyRegistry.atom_for(strategy_name)
  run_params = %{strategy: strategy_atom, prompt: prompt, timeout: 60_000}

  Telemetry.with_outcome(
    strategy_name,
    prompt,
    [execution_kind: :strategy_run,
     workspace_id: workspace_id,
     project_dir: project_dir],
    fn -> Jido.AI.Actions.Reasoning.RunStrategy.run(run_params, %{}) end
  )
  |> case do
    {:ok, result} -> {:ok, %{...}}  # existing extract_output logic
    {:error, reason} -> {:error, format_error(strategy_name, reason)}
  end
end
```

### `Statistics` (scaffold only)

```elixir
@spec best_strategies_for(task_type :: atom(), opts :: keyword()) ::
        [%{strategy: String.t(), success_rate: float(),
           avg_duration_ms: integer(), samples: integer()}]

@spec summary() :: %{strategies: [map()], task_types: [map()]}
```

- Uses Ecto directly for `GROUP BY`.
- Default filter: `execution_kind = :strategy_run`; opt in to `:all` explicitly.
- No ETS cache yet (not on hot path in 0.4.1).

### Signals

All follow `jido_claw.<subsystem>.<event>` per AGENTS.md:
- `jido_claw.reasoning.classified` — `/classify` and `Telemetry.with_outcome/4` when it classifies internally.
- `jido_claw.reasoning.outcome_recorded` — after async DB write success.
- `jido_claw.agent.prompt_sidecar_available` — `Prompt.sync/1` when sidecar is newly written.

### Tests

- `outcome_test.exs` (`async: false`) — `Ecto.Adapters.SQL.Sandbox`. Verify `record/1` persists all fields including all four enums; `list_by_task_type/2` filters by `task_type` and `execution_kind` (default `:strategy_run`).
- `telemetry_test.exs` (`async: false`, with `reasoning_telemetry_sync: true`) — subscribe to `[:jido_claw, :reasoning, :strategy, :stop]`; call `with_outcome/4` with ok- and error-returning funs; verify event fires and row exists; verify `workspace_id`/`project_dir` round-trip; verify `execution_kind` from opts reaches the row.
- `statistics_test.exs` (`async: false`) — insert mixed-`execution_kind` synthetic rows; assert `best_strategies_for/2` filters to `:strategy_run` by default and respects `:all`.

---

## Sequencing

Three tracks, three PRs. Largely independent.

- **Track A** (~1.5 days): `JidoClaw.Startup` (both helpers) + `Prompt.sync/1` + `/upgrade-prompt` + branding help + tests + patch all four entry points (repl, chat/3, cli/main.ex, mix/tasks/jidoclaw.ex) + **pre-start `project_dir` resolution fix** for both escript and mix-task entry points. Verification includes the app-start ordering check. `chat/3` behavior change (agents now receive `.jido/system_prompt.md`) is verified via `[:jido_claw, :agent, :prompt_injected]` telemetry.
- **Track B** (~1 day): `TaskProfile` (with `@type t`) + `Classifier` + `/classify` + registry `prefers` metadata + `adaptive` exclusion + tests. No dependencies.
- **Track C** (~1.5 days): domain + 4 enums + `Outcome` + migration + `Telemetry.with_outcome/4` + wrap `Reason.run_strategy/3` (non-react only) + statistics scaffold + tests. `verify_certificate.ex` explicitly NOT touched in 0.4.1. Critical path is the migration: run `mix ash.codegen`, verify snapshot lands before module compile.

Coupling: Track C uses `TaskProfile` from Track B. If B merges first, C imports. If concurrent, coordinate on Track B's PR landing first.

---

## Out of scope for 0.4.1 (deferred)

- User-defined strategy YAML (`.jido/strategies/`) → 0.4.2
- Pipeline composition + `RunPipeline` → 0.4.2
- `verify_certificate.ex` telemetry wrapping with `:certificate_verification` → 0.4.2
- `AutoReason` + `Reason strategy: "auto"` → 0.4.3
- `Statistics.best_strategies_for/2` → `Classifier.recommend/2` history → 0.4.3
- `/strategies stats` CLI surface → 0.4.3
- LLM tie-breaker in `Classifier` → 0.4.3
- Re-include `adaptive` in classifier recommendations → 0.4.3
- Thread `forge_session_id` / `agent_id` through `tool_context`; backfill Outcome columns → 0.4.3
- `Statistics` ETS cache → when 0.4.3 puts it on a hot path
- Wire `/strategy state.strategy` into `handle_message/2` (pre-existing disconnect at `repl.ex:194`) → 0.4.3

---

## Verification

### Track A

1. Modify `.jido/system_prompt.md` in a dev project, restart REPL → `:noop`; sidecar sync file updated if pre-existing; no print.
2. Touch `priv/defaults/system_prompt.md`, recompile, restart REPL → `.default` sidecar appears; notice printed once; original user file untouched.
3. Restart again — no re-notification (new "sidecar already offered" noop).
4. Run `/upgrade-prompt` → sidecar promoted; `.bak` created; sync stamp refreshed.
5. **App-start ordering**: `mix jidoclaw /tmp/other-proj` (with a different `.jido/` set up) → check `Application.get_env(:jido_claw, :project_dir)` is `/tmp/other-proj`, and child processes like `JidoClaw.Memory` report their configured `project_dir` as `/tmp/other-proj` (via `:sys.get_state/1` or a module accessor). Confirms the pre-existing drift is fixed.
6. **`chat/3` prompt injection** (behavior change): test via telemetry, not a get-prompt API (no such API exists in current deps). In `iex -S mix`, attach to `[:jido_claw, :agent, :prompt_injected]`:
   ```elixir
   :telemetry.attach("p", [:jido_claw, :agent, :prompt_injected],
     fn _, %{bytes: n}, _, _ -> send(self(), {:prompt_bytes, n}) end, nil)
   JidoClaw.chat("default", "check", "hi")
   assert_receive {:prompt_bytes, n} when n > 0
   ```
   Plus: write a recognizable marker to `.jido/system_prompt.md`, start a new session via `chat/3`, and issue a prompt that asks the model to echo the first line — confirm the marker appears in the response. (Non-deterministic; use as a smoke check, not a CI assertion.)
7. `mix jidoclaw --mcp` → sync fires silently; `.jido/.system_prompt.sync` written; no stdout noise (stdout stays clean for MCP JSON-RPC).
8. `jido --mcp` (escript) → same.

### Track B

1. `mix jidoclaw` → `/classify "Fix the NullPointerException in UserService.create"` → `:debugging` + `react`.
2. `/classify "Plan a migration from Ecto to Ash for the Accounts domain"` → `:planning` + `tot`.
3. `mix test test/jido_claw/reasoning/classifier_test.exs` green.
4. `Classifier.recommend/2` never returns `adaptive` (tested).

### Track C

1. `mix ash.codegen --check` clean (migration + snapshot in sync).
2. `mix ecto.setup && mix test test/jido_claw/reasoning/` green.
3. `mix jidoclaw` → trigger a `reason` tool call with strategy `cot` → Tidewave: `SELECT strategy, execution_kind, status, task_type, workspace_id, project_dir FROM reasoning_outcomes ORDER BY started_at DESC LIMIT 1;` → row has `execution_kind = 'strategy_run'` and populated `workspace_id`/`project_dir`.
4. Force strategy failure → row has `status = 'error'`, `completed_at` populated.
5. `JidoClaw.Reasoning.Statistics.best_strategies_for(:qa)` returns only `:strategy_run` rows.
6. **verify_certificate unchanged** — no new `reasoning_outcomes` rows from it in 0.4.1 (regression check).

### Integration

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix test` — new tests green, 0 regressions against existing 772.

---

## Critical files

- `lib/jido_claw/agent/prompt.ex` — `ensure/1`, `build/1`, `load_base_prompt/1:124`, `@default_system_prompt` at compile time (line 13, `@external_resource` already declared).
- `lib/jido_claw.ex:28-89` — `chat/3` entry point; needs `Startup.ensure_project_state/1` + `Startup.inject_system_prompt/2` (behavior change).
- `lib/jido_claw/cli/repl.ex:44-47,100-102` — REPL file bootstrap + prompt injection; both collapse into `Startup` helpers.
- `lib/jido_claw/cli/repl.ex:154,194` — blocking `IO.gets` loop; no signal handling (inline notice approach).
- `lib/jido_claw/cli/main.ex:11,20,36-44` — escript entry; move argv parse before `Application.ensure_all_started/1`, `put_env(:project_dir)` first; add `Startup.ensure_project_state/1` (both normal and `--mcp` branches).
- `lib/mix/tasks/jidoclaw.ex:10,22` — mix task; same pattern; `put_env(:project_dir)` before `Mix.Task.run("app.start")` in both branches; add `Startup.ensure_project_state/1`.
- `lib/jido_claw/application.ex:131,135,138,141,159-161` — reference only; `project_dir()` helper reads app env. After Track A, that env is explicitly set before app start, so the `File.cwd!()` fallback at line 160 only ever fires as a safety net.
- `lib/jido_claw/cli/commands.ex:578-594` — `/strategy` (reference only).
- `lib/jido_claw/cli/branding.ex:137` — help text.
- `lib/jido_claw/reasoning/strategy_registry.ex` — add `prefers` + `prefers_for/1`.
- `lib/jido_claw/tools/reason.ex:53,75` — line 53 react stub (NOT wrapped); line 75 real strategy (wrapped).
- `lib/jido_claw/tools/read_file.ex:39-40` — reference for `get_in(context, [:tool_context, ...])` access.
- `lib/jido_claw/solutions/fingerprint.ex` — SHA-256 idiom + `extract_domain/1` + `extract_target/1` to reuse.
- `lib/jido_claw/forge/domain.ex` — reference for new `JidoClaw.Reasoning.Domain`.
- `lib/jido_claw/forge/resources/event.ex` — reference for `Outcome` resource.
- `test/jido_claw/prompt_test.exs` — existing `async: false`; extend with `describe "sync/1"`.
- `test/jido_claw/forge/context_builder_test.exs` — reference for Ash/Ecto sandbox test shape.
