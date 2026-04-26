# JidoClaw Roadmap

## Current State: v0.5.4

Single-agent and swarm runtime working. 27 tools, REPL with boot sequence, multi-provider LLM support, persistent sessions, DAG-based skills, solutions engine, agent-to-agent networking, multi-tenancy scaffolding, MCP server mode, unified VFS across file tools and shell (v0.3), user-defined reasoning strategies and sequential pipelines (v0.4.2), history-aware `strategy: "auto"` with LLM tie-breaker and strategy-outcome learning (v0.4.3), shared `StrategyTestHelper` (v0.4.4), custom prompt templates in user strategies (v0.4.5), YAML-defined pipeline compositions (v0.4.6), `max_context_bytes` cap for `accumulate`-mode pipelines (v0.4.7), custom command registry with `jido status|memory|solutions` sub-commands (v0.5.1), per-workspace environment profiles with `/profile` REPL command + status-bar indicator (v0.5.2), remote command execution against declared SSH targets with profile-aware env and structured connection errors (v0.5.3), and real-time streaming of host/VFS/SSH command output to `Display` with `stream_to_display:` opt-in plus `force:` → `backend:` consolidation in `RunCommand` (v0.5.4).

Ash Framework 3.0 + PostgreSQL data layer with 7 domains (Accounts, Folio, Forge, GitHub, Orchestration, Projects, Security). Phoenix LiveView web dashboard with authentication. Shell sessions use jido_shell with a custom `BackendHost` for real host command execution with CWD/env persistence.

---

## v0.2 — Stabilization & Polish

**Status: Complete**

- [x] Codebase reorganization (cli/, agent/, core/, platform/, tools/)
- [x] System prompt externalized to `.jido/system_prompt.md`
- [x] jido_shell integration via `BackendHost` (real host commands + persistent sessions)
- [x] Swarm runtime (spawn_agent, list_agents, get_agent_result, send_to_agent, kill_agent)
- [x] Skills system (YAML-defined, DAG + sequential workflows)
- [x] Live swarm display (AgentTracker + Display GenServers)
- [x] Full test suite green (772 tests, 0 failures)
- [x] Session persistence end-to-end verification (DB-backed session claims, advisory locks, checkpoint/resume)
- [x] Scheduling tools (schedule_task, unschedule_task, list_scheduled_tasks)
- [x] MCP server mode validation with Claude Code (validated — anubis_mcp 1.1.1 with a schema-validation shim for jido_mcp's JSON-Schema tool descriptors)

---

## v0.2.5 — Ash Framework + Phoenix Web Dashboard

**Status: Complete**

This milestone was not in the original roadmap but was delivered between v0.2 and v0.3.

### Ash Framework 3.0 Integration

Replaced the planned `jido_ecto` approach with `ash_postgres` directly. 12 migrations, 16+ Ash resources across 7 domains:

| Domain        | Resources                               |
| ------------- | --------------------------------------- |
| Accounts      | User, Token, ApiKey                     |
| Folio         | Project, Action, InboxItem              |
| Forge         | Session, Event, Checkpoint, ExecSession |
| GitHub        | IssueAnalysis                           |
| Orchestration | WorkflowRun, WorkflowStep, ApprovalGate |
| Projects      | Project                                 |
| Security      | SecretRef                               |

### Phoenix LiveView Web Dashboard

Full-stack web application with:

- 8+ LiveViews: Dashboard, Forge, Setup, Workflows, Sign-in, Folio, Agents, Settings, Projects
- Authentication via `ash_authentication` + `ash_authentication_phoenix`
- Admin UI via `ash_admin`
- Router, endpoint, layouts, error handling

### What Remained File-Based

Memory (`JidoClaw.Memory`) and Solutions Store (`JidoClaw.Solutions.Store`) intentionally kept on ETS + JSON for CLI simplicity.

---

## v0.3 — VFS Integration for File Tools

**Status: Complete**

Mount the project directory into jido_shell's VFS so file tools (`ReadFile`, `WriteFile`, `EditFile`, `ListDirectory`) and shell commands share a single mount-point namespace. Delivered:

- Per-workspace `JidoClaw.VFS.Workspace` GenServer owning the mount table (default `/project` mount + config-declared extras from `.jido/config.yaml`'s `vfs.mounts` key).
- Dual-session `SessionManager`: a `BackendHost` session for real host commands (`git`, `mix`, pipes, redirects) plus a `Jido.Shell.Backend.Local` VFS session for the sandbox built-ins (`cat`, `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`). A command classifier routes automatically; `run_command backend: "host" | "vfs"` overrides it.
- `JidoClaw.VFS.Resolver` gains a `:workspace_id` option; file tools thread `workspace_id` through `tool_context` so absolute paths under a workspace mount flow through `Jido.Shell.VFS` and paths outside any mount fall back to `File.*`.
- Config-driven mounts for `/scratch`, `/upstream`, `/artifacts`, … with adapter-option translation (Local, InMemory, GitHub, S3, Git). Default `/project` is fail-fast; extras are fail-soft (warn and continue).
- Agent can `cat /project/mix.exs` and `cat /upstream/mix.exs` in the same workflow. Workspace + shell state now persist across multi-step skills and spawned sub-agents.

### Out of scope (deferred)

- `SearchCode` remote support.
- GitHub/S3 writes from the shell command surface.
- VFS-aware diffing across adapters.
- Persisting the mount table across node restarts (→ v0.6).

---

## v0.4 — Reasoning & Strategy Improvements

**Status: Complete**

Originally planned as four sub-phases. The fourth was split into four point releases (v0.4.4–v0.4.7) during 0.4.4 planning, each independently reviewable and revertible. v0.4.1 through v0.4.7 complete.

### v0.4.1 — Reasoning Foundations

**Status: Complete**

Three foundations for downstream auto-selection and performance-guided routing. Delivered:

- **System prompt auto-sync.** New `JidoClaw.Startup` module unifies `.jido/` bootstrap and system-prompt injection across all four agent entry points (REPL, `JidoClaw.chat/3`, `mix jidoclaw --mcp`, `jido --mcp` escript). `Prompt.sync/1` reconciles on-disk `.jido/system_prompt.md` against the bundled default via SHA comparison, stamped in sidecar `.jido/.system_prompt.sync` (metadata lives outside the prompt body so it never reaches the LLM). When the bundled default diverges from an edited user prompt, `.jido/system_prompt.md.default` is written alongside for review and `/upgrade-prompt` promotes it in place (with `.bak`). Entry points parse `project_dir` from argv _before_ `app.start`/`ensure_all_started` so app-managed services (`Memory`, `Skills`, `Solutions.Store`, `Network.Supervisor`) initialize against the correct directory.
- **Heuristic classifier.** `JidoClaw.Reasoning.Classifier` builds a `TaskProfile` from prompt text — 7 task types (`planning`, `debugging`, `refactoring`, `exploration`, `verification`, `qa`, `open_ended`) and 4 complexity buckets (`simple`/`moderate`/`complex`/`highly_complex`) — via keyword bucketing + structural signals (error-signal terms, code blocks, numbered enumeration, multi-file mentions, constraint markers). `recommend/2` scores strategies against the registry's new `prefers` metadata, with position-weighted task-type match + complexity match + signal bonuses. `/classify <prompt>` REPL command emits `jido_claw.reasoning.classified`. `adaptive` is excluded from recommendations in 0.4.1 pending end-to-end wiring.
- **Strategy performance tracking.** New `JidoClaw.Reasoning.Domain` + `reasoning_outcomes` Ash resource with four typed enums (`ExecutionKind`, `TaskType`, `Complexity`, `OutcomeStatus`) and denormalized profile snapshot for single-scan aggregation. `Telemetry.with_outcome/4` wraps strategy calls, emits `[:jido_claw, :reasoning, :strategy, :start|:stop]` telemetry, persists an outcome row asynchronously via `Task.Supervisor`, and publishes `jido_claw.reasoning.classified` (when classifying internally) + `jido_claw.reasoning.outcome_recorded` signals. `Reason.run_strategy/3`'s non-react branch is wrapped; the react clause is a structured-prompt template and stays unwrapped. `Statistics` aggregation scaffold ready for 0.4.3's feedback loop. `verify_certificate` telemetry wrap is deferred to 0.4.2.

### Out of scope (deferred)

- User-defined strategies (`.jido/strategies/` YAML) → 0.4.2
- Pipeline composition + `RunPipeline` → 0.4.2
- `verify_certificate` telemetry wrap with `:certificate_verification` kind → 0.4.2
- `AutoReason` tool + `Reason strategy: "auto"` → 0.4.3
- `Statistics.best_strategies_for/2` feeding `Classifier.recommend/2` history → 0.4.3
- `/strategies stats` CLI surface → 0.4.3
- LLM tie-breaker for close-scoring heuristic candidates → 0.4.3
- Re-enable `adaptive` in classifier recommendations → 0.4.3
- Thread `forge_session_id` / `agent_id` through `tool_context`; backfill `reasoning_outcomes` columns → 0.4.3
- Wire `/strategy` state into `handle_message/2` (pre-existing disconnect) → 0.4.3

### v0.4.2 — User Strategies & Pipeline Composition

**Status: Complete**

Metadata-aliased user strategies plus sequential pipeline composition, with telemetry coverage extended across react-stub and certificate-verification execution kinds. Delivered:

- **User-defined strategy aliases.** New `JidoClaw.Reasoning.StrategyStore` GenServer loads `.jido/strategies/*.yaml` on boot. Each file declares a named alias with a required `base` field routing to one of the 8 built-in reasoning modules (`react`, `cot`, `cod`, `tot`, `got`, `aot`, `trm`, `adaptive`) plus optional `display_name`/`description`/`prefers.task_types`/`prefers.complexity` metadata. Validation is lenient — unknown `base`, built-in name collisions, malformed YAML, and unknown task-type/complexity values all warn-and-skip instead of crashing; built-ins always win on name collision, and user-vs-user collisions resolve deterministically to the lexicographically-first filename (files are sorted before parsing so ordering is reproducible across filesystems). `StrategyRegistry.atom_for/1` resolves alias → base atom transparently for downstream dispatch; `valid?/1` accepts both built-ins and user aliases. Metadata-only overlays — custom prompt templates live in `deps/jido_ai/` and stay out of scope.
- **Pipeline composition.** New `JidoClaw.Tools.RunPipeline` tool chains non-react strategies sequentially, feeding each stage's output into the next. Stages accept `strategy` (required; alias-aware), `context_mode` (`"previous"` default or `"accumulate"`), and `prompt_override` (wins unconditionally when present). Fail-fast: any stage whose strategy resolves (alias-aware) to `:react` errors with a pointer to the agent's native ReAct loop, since the current `Reason` react path is a structured-prompt stub. Each stage writes a `reasoning_outcomes` row via `Telemetry.with_outcome/4` with `execution_kind: :pipeline_run`, zero-padded `pipeline_stage` (e.g., `"001/003"` for correct text sort), `pipeline_name`, `base_strategy` set to the resolved built-in, and `metadata.stage_index`/`stage_total` integers for numeric consumers. Usage counters merge across stages; mid-pipeline errors persist earlier rows normally and the failing stage row is written with `status: :error`.
- **Telemetry coverage completion.** `verify_certificate` wraps its CoT call with `execution_kind: :certificate_verification`, populating `certificate_verdict`/`certificate_confidence` on the outcome row. `Reason`'s react branch now wraps with `execution_kind: :react_stub` so alias→react dispatch still produces a telemetry row with coherent `base_strategy` accounting (the underlying call remains a structured-prompt scaffold). `Telemetry.extract_tokens/1` reads `:input_tokens`/`:output_tokens` first (`jido_ai`'s canonical keys per `deps/jido_ai/lib/jido_ai/actions/helpers.ex`) with `:prompt_tokens`/`:completion_tokens` fallback for legacy providers, and captures tokens on `{:error, %{usage: _}}` partial-failure paths in addition to`{:ok, _}`results.`ExecutionKind`enum now values:`:strategy_run`, `:react_stub`, `:certificate_verification`, `:pipeline_run`.

### Out of scope (deferred)

- YAML-defined pipeline compositions (inline stages only in 0.4.2) → 0.4.4
- `max_context_bytes` cap for `accumulate` context mode (unbounded today; token-budget footgun on long pipelines) → 0.4.4 if users hit it
- Custom prompt templates in user strategies → revisit in 0.4.4 if demand surfaces

### v0.4.3 — Auto-selection & Feedback

**Status: Complete**

Closes the feedback loop opened by 0.4.1's telemetry + classifier work: `strategy: "auto"` becomes a real, learnable choice, and accumulated `reasoning_outcomes` data steers future runs. Delivered:

- **History-aware auto-selection.** New `JidoClaw.Reasoning.AutoSelect` module is the single entry point behind `reason(strategy: "auto")`. Profiles the prompt via `Classifier`, queries `Statistics.best_strategies_for/2` for a recent-window history (30-day, `:strategy_run` only) with all-time fallback when the recent window is sparse (either/or, not merged), and folds aggregated success-rate into the heuristic score via `opts[:history]`. The outcome row stores the **base** strategy name (cot/tot/etc., never "auto"/"adaptive" and never a user alias) so `Statistics` learns on a stable vocabulary; `metadata.alias_name` preserves the alias when one wins for lossless diagnostics; `metadata.selection_mode = "auto"` flags the row. `adaptive` is repositioned as a deprecated alias for `auto` (silently normalized at the tool boundary) rather than re-enabled in the candidate pool — `Jido.AI.Reasoning.Adaptive` runs its own inner selection, and letting the classifier pick it would produce two selectors competing for the same decision.
- **LLM tie-breaker.** New `JidoClaw.Reasoning.LLMTiebreaker` fires when the top two heuristic candidates score within 0.05 of each other. Cap of 3 candidates in the tie-breaker prompt to keep token cost bounded. Tie-breaker failures fall back to the heuristic top pick without surfacing the error; test hooks (`tiebreak_module:`, `llm_tiebreak: false`, `history: [...]`, `skip_history: true`) allow deterministic substitution in unit tests.
- **Base-level alias exclusion.** `Classifier.recommend/2` gains an `:exclude_bases` option (list of atoms); `AutoSelect` passes `[:react, :adaptive]` so user aliases whose `base:` resolves to react or adaptive can't slip into the auto pool. Prevents a `react`-based alias from crashing `Jido.AI.Actions.Reasoning.RunStrategy` (`:react` isn't a valid enum value there) and an `adaptive`-based alias from silently reintroducing the nested selector the rest of 0.4.3 is built to eliminate.
- **REPL `/strategy` now influences chat turns.** Project-wide default shifts from `"react"` to `"auto"`. The REPL struct gains a `:strategy` field populated at init from `Config.strategy(config)`, normalized through `Repl.resolve_strategy/1` (unknown values fall back to `"auto"` with a boot-time warning pointing at `.jido/config.yaml`). `handle_message/2` prepends a one-line reasoning-preference hint to the agent-facing message — but not to the JSONL session history, so history stays clean — nudging the model toward `reason(strategy: "<name>")` on queries that benefit while keeping the agent's native ReAct loop intact. `/strategy <name>` updates the state struct through the same validator; the command's copy was softened to "Reasoning preference" (from "Switched reasoning strategy") to honor hint-not-dispatch semantics honestly.
- **`/strategies stats` CLI surface.** Backed by `Statistics.summary/0`, prints per-strategy and per-task-type aggregates (sample count, success rate, average duration) so users can inspect what `auto` is learning.
- **Tool-context attribution.** Migration `add_session_agent_to_reasoning_outcomes` adds the columns; `Reason.base_telemetry_opts/2` threads `workspace_id`, `project_dir`, `agent_id`, and `forge_session_key` from `tool_context` into every outcome row so rows attribute to their originating session/agent.
- **Strict compile green.** `mix.exs` sets `elixirc_options: [ignore_module_conflict: true]` to silence the intentional redefinitions in `lib/jido_claw/core/` (the `Anubis.Server.Handlers.Tools` schema-validation shim and the three `Jido.Shell.*` extensions). Header comments on each patch file cross-reference the flag.
- **System prompt parity.** Both the bundled default (`priv/defaults/system_prompt.md`) and the active project copy (`.jido/system_prompt.md`) now lead the strategy table with `auto`, drop the `adaptive` advertisement (still accepted as a deprecated alias; just no longer recommended), and swap residual `adaptive` recommendations throughout the decision framework and quick-reference table to `auto`.

### Out of scope (deferred)

- YAML-defined pipeline compositions (inline stages are still the only form) → 0.4.4
- `max_context_bytes` cap for `accumulate` context mode → 0.4.4
- Custom prompt templates in user strategies → 0.4.4
- Collapse the four duplicated `with_user_strategy/2` helpers in the test suite into a shared module → 0.4.4 cleanup

### v0.4.4 — `StrategyTestHelper`

**Status: Complete**

Collapses five duplicated `with_user_strategy/2` helpers into a shared `test/support/` module so every subsequent 0.4.x release adds call sites to one place, not five. Delivered:

- **`JidoClaw.Reasoning.StrategyTestHelper`** — new shared module exporting `with_user_strategy/2` (write YAML to `.jido/strategies/`, reload the supervised `StrategyStore`, run the body, clean up on exit). Module doc calls out the `async: false` invariant — the store is a named singleton and parallel tests would race its state. A sibling `with_user_pipeline/2` helper lands alongside `PipelineStore` in v0.4.6 (adding it now would depend on a module that doesn't exist yet).
- **`mix.exs` `elixirc_paths/1`** — branches `test/support/` into `:test` only, so `test/support/` never compiles under `:prod`/`:dev`.
- **Five call-site refactors** — `test/jido_claw/reasoning/{classifier,auto_select,strategy_registry}_test.exs` and `test/jido_claw/tools/{reason,run_pipeline}_test.exs` all drop their inline `defp with_user_strategy/2` and pick up `import JidoClaw.Reasoning.StrategyTestHelper`. No behavior change — the refactor preserves exact semantics.

### v0.4.5 — Custom Prompt Templates

**Status: Complete**

Elevates user strategies beyond the metadata-only overlays v0.4.2 shipped so aliases can carry their own `system`/`generation`/`evaluation` prompts (plus `connection`/`aggregation` for GoT) and not just tuned `prefers` metadata. Delivered:

- **`prompts:` key in `.jido/strategies/*.yaml`.** Optional top-level map whose sub-keys (`system`, `generation`, `evaluation`, `connection`, `aggregation`) are validated at load time against a per-base accepted-key matrix sourced from `Jido.AI.Actions.Reasoning.RunStrategy`'s `@strategy_state_keys` (`deps/jido_ai/lib/jido_ai/actions/reasoning/run_strategy.ex:108-133`). The matrix: `cot`/`cod` accept `system`; `tot` accepts `generation`+`evaluation`; `got` accepts `generation`+`connection`+`aggregation`; `trm`/`aot`/`react`/`adaptive` accept none (hard-reject if any known key appears).
- **5 KB per-field cap** aligned with `Jido.AI.Validation.@max_prompt_length`. Oversized or non-string values → whole-file skip with a warning. Empty strings → drop-the-key ("unset"). Unknown sub-keys (e.g. typo `sytem`) → warn-and-drop that key; file kept if others are valid.
- **`StrategyRegistry.prompts_for/1`** returns the raw prompts map (atom-keyed); **`run_strategy_params_for/1`** returns a map keyed by RunStrategy schema names (`:system_prompt`, `:generation_prompt`, etc.) ready to merge into runner params.
- **`Reason.run_runner_strategy/5`, `Reason.run_auto/2`, `RunPipeline.run_stage/4`** all merge `run_strategy_params_for(strategy_name)` into their `run_params` before calling the runner. Prompts travel with the alias; built-ins and aliases without `prompts:` pass no extra keys (runner falls back to compile-time defaults).

### v0.4.6 — YAML-Defined Pipeline Compositions

**Status: Complete**

Users declare reusable pipelines in `.jido/pipelines/*.yaml`. `RunPipeline` gains a `pipeline_ref` parameter; inline `stages` still works and wins when both supplied. Delivered:

- **`JidoClaw.Reasoning.PipelineValidator`** — extracts `normalize_stage/1`/`normalize_stages/1` and `validate_stage/2`/`validate_stages/1`/`resolves_to_react?/1` out of `RunPipeline` as public functions so YAML and inline callers share one normalize+validate pair. Error-message strings preserved for grep-based consumer compatibility.
- **`JidoClaw.Reasoning.PipelineStore`** — new GenServer mirroring `StrategyStore` (loading, lenient per-file error handling, lexicographic dedup, exit-safe lookup). Started under `core_children/0` next to `StrategyStore`. Pipeline struct carries `name`, `description`, `stages` (already normalized at load time).
- **`RunPipeline.run/2`** branches by `is_list(params[:stages])` — robust to whether `Jido.Action` leaves absent optional keys as key-absent or nil-valued. Inline stages wins unconditionally over `pipeline_ref` (inline empty/malformed fails on the inline path; never silently falls through). Caller-supplied `pipeline_name` always wins over YAML `name` for telemetry correlation. Stages loaded from YAML are re-validated at invocation time (catches a strategy that was deleted between load and run).
- **`StrategyTestHelper.with_user_pipeline/2`** — mirror of `with_user_strategy/2` targeting `.jido/pipelines/` and `PipelineStore.reload/0`.
- **`Startup.ensure_pipelines_dir/1`** — creates `.jido/pipelines/` alongside `.jido/strategies/` at boot.

### v0.4.7 — `max_context_bytes` Cap

**Status: Complete**

Bounds the composed-prompt size in `accumulate` mode. Drops oldest whole stages (never mid-body truncation). Fails fast if even the newest prior-stage output alone exceeds the cap. Delivered:

- **`max_context_bytes`** accepted at two levels:
  - Top-level `RunPipeline` tool param (pipeline-wide default).
  - Per-stage key (overrides the pipeline-wide value for that stage).
  - YAML-declared pipelines carry top-level + per-stage `max_context_bytes`; the invocation-time param wins when both are supplied.
- **`compose_and_cap/5`** returns `{:ok, final_prompt, cap_meta}` on success and `{:error, reason, classification_prompt, cap_meta}` on failure. The classification prompt is the irreducible would-be request (`initial + newest-prior-stage + elision_notice`), driving an accurate `prompt_length` on the failing-stage outcome row.
- **Cap failures routed back through `Telemetry.with_outcome/4`** with `fn -> {:error, reason} end` so the full lifecycle fires (start/stop telemetry, `jido_claw.reasoning.classified` signal, persisted `:error` row). No new Telemetry API.
- **Elision notice bytes pre-reserved in the budget** — the notice (`[N earlier stage outputs elided to fit max_context_bytes]`) is appended AFTER dropping but its size counts against the cap, so `byte_size(final_prompt) <= cap` holds exactly once drops occurred.
- **Outcome-row metadata keys** (all in `reasoning_outcomes.metadata` JSONB; no schema changes): `accumulated_context_bytes_pre_cap`, `accumulated_context_bytes_post_cap` (success only), `dropped_stage_indexes`, and on failure `failure_reason`.
- **`previous` mode + any cap → one-line warning at run start, continue uncapped** (caps only make sense in accumulate mode).

---

## v0.5 — Advanced Shell Integration

**Status: In Progress**

Build on the jido_shell `BackendHost` foundation. Split into four point releases mirroring the v0.4.x cadence — each touches a different subsystem (registry → config → session → display) and is independently reviewable and revertible. No blocking dependencies between them; natural order is 1→2→3→4 so later items benefit from earlier ones, but any can ship in isolation.

Scoping note: `Jido.Shell.Backend.SSH` is already fully implemented in `deps/jido_shell/lib/jido_shell/backend/ssh.ex` (~446 LOC), and transport events already broadcast to subscribed pids. v0.5 is mostly JidoClaw-side wiring, not new protocol work.

### v0.5.1 — Custom Command Registry

**Status: Complete**

Register JidoClaw-specific commands (e.g., `jido status`, `jido memory search`) as jido_shell commands, accessible from the persistent session.

- **Extensibility hook in `Jido.Shell.Command.Registry`.** The upstream registry is a static hard-coded map of 14 built-ins (`deps/jido_shell/lib/jido_shell/command/registry.ex`). Delivered as a runtime patch at `lib/jido_claw/core/jido_shell_registry_patch.ex` that redefines the registry to union `:extra_commands` with the built-ins (built-ins win on name collision). Delete the patch when `jido_shell` ships a release with a compatible `:extra_commands` hook and we upgrade the dep.
- **JidoClaw command module** at `lib/jido_claw/shell/commands/jido.ex` — single `Jido.Shell.Command` module exposing `jido status` (agents, forge sessions, uptime, active profile), `jido memory search <query>`, and `jido solutions find <fingerprint>` as sub-commands. Active-profile output in `jido status` was delivered in v0.5.2 alongside `ProfileManager` — the command threads `state.workspace_id` into the status snapshot so each shell session sees its own active profile.
- **Registration via compile-time config** — `config :jido_shell, :extra_commands, %{"jido" => JidoClaw.Shell.Commands.Jido}` in `config/config.exs`. Resolved before `SessionManager` boots, so the classifier sees the full extension set on the first command it routes.

### v0.5.2 — Environment Profiles

**Status: Complete**

Named env var sets (dev, staging, prod) switchable per workspace session. Delivered:

- **`profiles:` key in `.jido/config.yaml`** — map of name → env var map. Values are string-coerced (integers tolerated); non-string-non-integer values rejected per-key with a warn-and-skip. The magic name `"default"` within `profiles:` is first-class: it defines the baseline every profile inherits from, is always switchable (even absent from YAML), and `list/0` pins it first. There is no separate `active_profile:` config key.
- **`JidoClaw.Shell.ProfileManager` GenServer** — singleton keyed by workspace, loaded from `.jido/config.yaml` at boot. Owns `profiles`, `default_env`, and `active_by_workspace: %{workspace_id => profile_name}`. `switch/2` doesn't require a live shell session — new sessions inherit the recorded active profile at lazy-start via `SessionManager.start_new_session/3`. Registered *before* `Shell.SessionManager` under `:rest_for_one` so a SessionManager crash doesn't wipe `active_by_workspace`. Emits `jido_claw.shell.profile_switched` with `%{workspace_id, from, to, key_count, reason}` on every real switch; redundant switches (same name) short-circuit with no signal.
- **Drop+merge at the session boundary.** Profile switch preserves ad hoc `env VAR=value` mutations: `keys_to_drop = keys_owned_by(A) -- keys_owned_by(B)`, `new_state_env = state.env |> Map.drop(keys_to_drop) |> Map.merge(new_overlay)`. Only keys owned by the old profile and not by the new one are dropped; ad-hoc-only keys survive.
- **`SessionManager.update_env/3`** — atomic across both host + VFS sessions with host rollback on VFS failure. `{:error, :vfs_update_failed, :ok | :stuck, reason}` reports rollback status. No-op returning `:ok` when no sessions exist for the workspace, so `switch/2` still succeeds and records intent before any shell command.
- **`Jido.Shell.ShellSession.update_env/2` + `ShellSessionServer` handler** — added as runtime patches at `lib/jido_claw/core/jido_shell_session_*_patch.ex` (same pattern as `jido_shell_registry_patch.ex` from v0.5.1). No session rebuild on switch — rebuild would lose history, cancel in-flight commands, and silently break cwd. Delete both patches when `jido_shell` ships a compatible `update_env/2` and we upgrade the dep.
- **REPL `/profile` command** — `/profile list`, `/profile current`, `/profile switch <name>`, bare `/profile` (alias for current). `/profile switch` updates `Display.set_profile/1` and the REPL struct's new `:profile` field; `/profile current` redacts values via `Security.Redaction.Env`.
- **`JidoClaw.Security.Redaction.Env`** — key-name-based redactor complementing `Redaction.Patterns`. Masks values for keys ending in `_KEY|_TOKEN|_SECRET|_PASSWORD|_PASS|_PAT` (case-insensitive), specific names (`AWS_SECRET_*`, `AWS_SESSION_TOKEN`, `DATABASE_URL`, `DB_URL`), and connection URLs (`scheme://user:pass@host/db` → `scheme://user:[REDACTED]@host/db`). Falls through to `Patterns.redact/1` for embedded API keys. Documented false negatives: `SESSION_ID`, `USER_ID`, `CLIENT_ID` not masked — over-redacting identifiers is worse than under-redacting for a dev tool.
- **Reload fallback.** `reload/0` computes transitions against the old state before replacing it so removed-profile keys remain computable. Workspaces whose active profile was removed fall back to `"default"` with a `reason: "profile_removed"` signal and a warning log. Best-effort per workspace: a failed transition doesn't block the others.
- **Display indicator.** `Display.StatusBar.profile_segment/1` renders a yellow `⚑ <name>` segment when the active profile ≠ default; returns `nil` otherwise so the bar stays unchanged for non-profile users.

### v0.5.3 — SSH Backend Support

**Status: Complete**

Remote command execution on dev/staging servers via the existing `Jido.Shell.Backend.SSH`. Work is pure JidoClaw-side wiring; the backend is already complete in `deps/jido_shell/`. Delivered:

- **`servers:` key in `.jido/config.yaml`** — declared SSH targets (`name`, `host`, `user`, `port`, `key_path` / `password_env`, `cwd`, `env`, `shell`, `connect_timeout`). Parsed by `JidoClaw.Shell.ServerRegistry` with per-entry warn-and-skip validation. Key paths resolve relative to `project_dir` unless absolute or `~`-prefixed. Passwords come from env vars via `password_env:` (empty env vars treated as missing).
- **`SessionManager` SSH session cache** — ssh sessions keyed by `{workspace_id, server_name}` alongside the existing host + VFS sessions. Lazy-connect on the first `run_command backend: "ssh", server: "staging"`; reuse thereafter. Connect failures are not cached, so the next call retries.
- **`run_command` override** — new `backend: "host" | "vfs" | "ssh"` string-typed schema param (Nimble enum-safe; the module's `on_before_validate_params/1` coerces legacy atom callers to strings, and `run/2` converts back to an internal atom via explicit case). `backend: "ssh"` requires the `server` param and refuses to fall back to `System.cmd` when `SessionManager` is unavailable. Classifier is not extended — SSH is always an explicit opt-in.
- **Structured errors** — `JidoClaw.Shell.SSHError.format/2` maps connect refused/nxdomain/timeout/ehostunreach, authentication rejection, key-read failures, command timeouts, output-limit-exceeded, and missing-env-var into user-facing `SSH to <name> failed: <reason>` strings with host/port/user/path interpolated from the server entry.
- **Profile integration** — SSH sessions respect the active profile's env. On `/profile switch`, the SessionManager recomputes effective env as `server.env |> Map.merge(profile_env)` and pushes it via `ShellSession.update_env/2` — server-declared vars survive the switch; an SSH write failure evicts the cached session (no rollback of host/VFS) so the next command reconnects with fresh env.
- **Reload diff** — `ServerRegistry.reload/0` returns `{added, changed, removed}` without touching SessionManager (avoids a SR↔SM deadlock on the routing hot path); the caller invokes `SessionManager.invalidate_ssh_sessions/1` explicitly.
- **Call timeout budgeting** — when `backend: :ssh`, the `GenServer.call` timeout includes the server's `connect_timeout` so a slow handshake doesn't trip the outer call before the backend can return its own `start_failed` error.

### Out of scope (deferred)

- **Passphrase-protected private keys** — requires an upstream jido_shell hook. v0.5.3 supports unencrypted `key_path`, `password_env`, and fall-through to the user's ssh-agent / default key discovery. Point `key_path` at an encrypted key and the connect surfaces as an authentication or connection failure; the user's recourse is to add the key to `ssh-agent` and leave `key_path` unset.
- `/servers` REPL command (list, test connectivity, show auth mode) → v0.5.3.1.
- `jido status` SSH session count segment → v0.5.3.1.
- Automatic reconnect on dropped sessions → revisit if users hit it.
- Classifier extension for SSH (auto-route based on path prefix) — SSH stays explicit.
- Consolidate `force:` → `backend:` in RunCommand and remove the legacy alias → v0.5.4 (delivered).
- SSH jump-host / bastion chains.
- Interactive/TTY-allocating sessions (`ssh -t`) — command-mode only.
- Key management UI / secret-store integration for SSH credentials (users place keys on disk, config points at them).
- Streaming SSH output to `Display` → v0.5.4 (delivered).

### v0.5.4 — Streaming Output to Display + `force:` → `backend:` Consolidation

**Status: Complete**

Wires `jido_shell` transport events directly into `JidoClaw.Display` for real-time output rendering during long-running commands, and clears the two items v0.5.3 explicitly deferred (`force:` consolidation + streaming SSH output). Delivered:

- **`force:` → `backend:` consolidation.** Hard-removed `force:` from `RunCommand`'s schema and from `SessionManager.resolve_target/3`; precedence is now simply `backend: :ssh` (with `server`) > `backend: :host` > `backend: :vfs` > classifier-routed default. Tests migrated type-aware: `RunCommand` callers use the string-typed `backend: "host"` (public tool API), and direct `SessionManager` callers use the atom-typed `backend: :host`. The legacy-alias parity test and the `force:`-vs-`backend:` precedence test were deleted (their assertions are no longer meaningful). Acceptance gate: `grep -rn "force:" lib/ test/` returns zero matches.
- **`stream_to_display: true` param on `RunCommand`.** Schema-level boolean, default `false`. Two early-exit guards before the streaming path is wired up: (1) under MCP `serve_mode` the flag is silently dropped so Display's raw ANSI writes don't corrupt JSON-RPC framing on stdio; (2) when `SessionManager` is unregistered the System.cmd fallback ignores streaming entirely (there are no shell-session events for Display to subscribe to). `agent_id` resolves from `tool_context` (defaulting to `"main"`) and is forwarded alongside `tool_name: "run_command"` to `SessionManager`.
- **Stream lifecycle owned end-to-end inside `SessionManager`.** Both `handle_local_run/6` and `handle_ssh_run/6` wrap their inner execution in `with_optional_stream/3`, which: resolves the final `session_id`, calls `Display.start_stream/3` (synchronous so the entry is registered before the first transport event can land), subscribes the Display pid to `Jido.Shell.ShellSessionServer`, runs the command + collector, and in a `try/after` block always unsubscribes Display + casts `Display.end_stream/1`. Handles the case where `Display.start_stream/3` returns `{:error, :stream_still_draining}` (next streaming command after a back-to-back persistent-session reuse) by transparently falling through to non-streaming mode for that command. Captured-result return is preserved.
- **Display streaming state.** New `streaming_sessions: %{session_id => entry}` map keyed by the resolved jido_shell session id (`<workspace>:host`, `:vfs`, or `:ssh:<server>`). Each entry tracks `agent_id`, `tool_name`, `bytes_streamed`, `line_buffer`, `dropped_warned?`, plus a `done?`/`end_requested?` flag pair: terminal events flip `done?`; `end_stream/1` flips `end_requested?`; the entry is reaped only once both are true. The pair makes ordering edge-cases between the unsubscribe and the cast safe without depending on Erlang FIFO subtleties.
- **Per-event handlers in `Display`.** `{:command_started, line}` prints a banner (`[<agent_id>] <tool_name>: $ <line>`) and clears any pending kaomoji spinner; `{:output, chunk}` writes raw bytes via `IO.binwrite/1` (single-stream mode preserves CR/ANSI naturally for progress bars; multi-stream mode prefixes complete lines with `[<agent_id>] ` and buffers partial-line tails up to a 64 KB cap before emit-and-reset); `:command_done` flushes any partial line; `{:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: n}}}` renders dim `[exit n]` (matching SessionManager's `{:ok, %{exit_code: n}}` re-route); other `{:error, _}` shapes render red `! <Exception.message(err)>`; `:command_cancelled` renders dim `[cancelled]`; `{:command_crashed, reason}` renders red `[backend crashed: <inspect reason>]`. Stragglers for a removed `session_id` hit the catch-all and drop silently.
- **OutputLimiter cap rewrite in `BackendHost`.** Replaced the fixed `@max_output_bytes` constant with `max_output_bytes/1` (50 KB non-streaming, 10 MB streaming, with a test-only override knob). Overflow semantics shifted from `{:ok, :output_truncated}` (silent in-band truncation marker) to `{:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}, context: %{emitted_bytes:, max_output_bytes:}}}` via `Jido.Shell.Backend.OutputLimiter.check/3` — same shape SSH and Local emit. Over-limit chunks are no longer emitted. Existing callers passing explicit `:output_limit` still win (e.g. SessionManager's per-SSH-command cap).
- **Three-cap streaming awareness in `SessionManager`.** Backend emission cap (50 KB → 10 MB), SSH `output_limit:` (1 MB → 10 MB), and Local/VFS `execution_context.limits.max_output_bytes` (unset → 10 MB) all flip on the new `streaming?` flag. The agent-facing capture echo stays small: `finalize_output/2` returns a 50 KB streaming preview (vs. 10 KB non-streaming) with an explicit `... (output truncated; full output streamed live)` note so the model context can't be blown out by a multi-MB build log. Live-render fidelity is full up to the per-cap ceiling.
- **Backpressure (warn-and-drop-oldest).** Display's `{:output, _}` handler peeks at its own `:message_queue_len`; over a 1000-message watermark it does a selective `receive` to drain up to 500 pending output chunks for the affected stream (no other event types) and emits a one-shot yellow `[<agent_id>] [output dropped to keep up — captured result is preview only]` line per stream. The captured-output cap is unchanged; this only adjusts what renders live.
- **StatusBar streaming segment.** New cyan `⟲ streaming` (or `⟲ streaming (n)` for multiple concurrent streams) optional segment between progress and cost. Drops via the existing `trim_optional/4` on narrow terminals, so non-streaming UX is unchanged.
- **Drive-by: `throttled_swarm_render` state-threading fix.** The throttle gate was reading `last_render` without ever writing it back, leaving the gate permanently open. `throttled_swarm_render/1` now returns `{updated_state, :ok | :throttled}` and bumps `last_render` on the rendered branch; `render_swarm_update/1` returns updated state; both call sites (`:agent_completed`, `:status_bar_tick`) thread state through.

### Out of scope (deferred)

Items still deferred from v0.5.3 — flagged here for visibility, not picked up by v0.5.4:

- `/servers` REPL command (list, test connectivity, show auth mode) → v0.5.3.1.
- `jido status` SSH session count segment → v0.5.3.1.
- Automatic reconnect on dropped SSH sessions — revisit if users hit it.
- Classifier extension for SSH (auto-route based on path prefix) — SSH stays explicit.
- Passphrase-protected SSH private keys — requires upstream `jido_shell` hook.
- SSH jump-host / bastion chains.
- Interactive/TTY-allocating sessions (`ssh -t`) — command-mode only.
- Key management UI / secret-store integration for SSH credentials.
- **Truly concurrent multi-agent streaming.** `SessionManager.run/4` is a `GenServer.call` that synchronously runs the command inside the SessionManager process, so two agents calling `run_command` serialize globally. v0.5.4's streaming code is correct under this constraint; lifting the serialization to allow truly interleaved live chunks from simultaneous commands is a separate milestone.

---

## v0.6 — Memory & Solutions Database Migration

**Status: Planned**

### Why

Application metadata (users, sessions, forge, orchestration) is already in PostgreSQL via Ash. Two subsystems remain on ETS + JSON files:

- **Memory** (`JidoClaw.Memory`): ETS + `.jido/memory.json`
- **Solutions Store** (`JidoClaw.Solutions.Store`): ETS + `.jido/solutions.json`

This works for single-node CLI usage but doesn't scale for search, multi-tenancy, or audit requirements.

### Phase 1: Memory Backend Swap

Replace `JidoClaw.Memory` (ETS + `.jido/memory.json`) with Ash resource-backed storage.

```
Before: Memory GenServer → ETS table → JSON file
After:  Memory GenServer → Ash Resource → PostgreSQL
```

- Migrate memory schema to Ash resources with Ecto changesets
- Full-text search via PostgreSQL FTS (replaces naive string matching)
- Cross-session memory with timestamps and types

### Phase 2: Solutions Store Migration

Replace `JidoClaw.Solutions.Store` (ETS + `.jido/solutions.json`) with Ash resource-backed store.

- Solution fingerprint indexing via composite indexes
- BM25-style search as a SQL query instead of in-memory scan
- Reputation ledger with atomic increments
- Trust score history (trending, not just current value)

### Phase 3: Remaining Persistence Gaps

- Session message history in database (replace JSONL files — session metadata is already in `forge_sessions`)
- Append-only audit log of all tool calls and decisions
- Multi-tenant data isolation (per-tenant schemas or row-level security)

### Fallback

Keep JSON file persistence as the default for CLI-only usage. Database persistence is opt-in for server deployments via config:

```yaml
# .jido/config.yaml
persistence:
  backend: ecto # or "file" (default)
  database_url: 'postgres://...'
```

---

## v0.7 — Burrito Packaging

**Status: Planned**

Single native binary distribution. Replaces escript (which has tzdata/runtime issues).

```elixir
# mix.exs
releases: [
  jido: [
    steps: [:assemble, &Burrito.wrap/1],
    burrito: [targets: [
      macos_aarch64: [os: :darwin, cpu: :aarch64],
      macos_x86_64: [os: :darwin, cpu: :x86_64],
      linux_x86_64: [os: :linux, cpu: :x86_64]
    ]]
  ]
]
```

- Cross-compile for macOS arm64/x86_64, Linux x86_64
- Self-contained — no Elixir/Erlang installation required
- Auto-update mechanism via GitHub releases

---

## Future Considerations

### Remaining File-to-Database Migration Opportunities

| Capability              | Current                            | With Ash/PostgreSQL                |
| ----------------------- | ---------------------------------- | ---------------------------------- |
| Memory persistence      | JSON file, FTS via string matching | PostgreSQL FTS, indexed queries    |
| Solution search         | In-memory Jaccard + BM25           | SQL-based BM25, composite indexes  |
| Multi-tenant isolation  | Process-level (ETS per tenant)     | Database-level (schemas/RLS)       |
| Audit trail             | None (telemetry is volatile)       | Append-only event log              |
| Reputation tracking     | JSON file                          | Atomic DB operations, history      |
| Cluster coordination    | `:pg` only                         | Shared DB state, distributed locks |
| Session message history | JSONL files                        | Structured DB with search          |

Note: Agent state recovery and session metadata are already in PostgreSQL via Forge resources.

### Other Jido Ecosystem Libraries to Watch

| Library            | Status | Potential Use                                          |
| ------------------ | ------ | ------------------------------------------------------ |
| **jido_discovery** | TBD    | Agent/service discovery in distributed deployments     |
| **jido_workflow**  | TBD    | Advanced workflow patterns beyond current Composer FSM |

---

## Build Order

```
v0.2 (done) → v0.2.5 (done) → v0.3 (done) → v0.4.1..v0.4.7 (done) → v0.5.1..v0.5.4 (Shell) → v0.6 (Memory/Solutions DB) → v0.7 (Burrito)
```

The v0.4.x cadence was intentional: each point release shipped one focused change to the reasoning subsystem, keeping every PR independently reviewable and revertible.

v0.6 memory/solutions migration is gated on actual need — don't migrate the remaining file-based stores until the current approach is a proven bottleneck.
