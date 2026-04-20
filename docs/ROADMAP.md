# JidoClaw Roadmap

## Current State: v0.4.7

Single-agent and swarm runtime working. 27 tools, REPL with boot sequence, multi-provider LLM support, persistent sessions, DAG-based skills, solutions engine, agent-to-agent networking, multi-tenancy scaffolding, MCP server mode, unified VFS across file tools and shell (v0.3), user-defined reasoning strategies and sequential pipelines (v0.4.2), history-aware `strategy: "auto"` with LLM tie-breaker and strategy-outcome learning (v0.4.3), shared `StrategyTestHelper` (v0.4.4), custom prompt templates in user strategies (v0.4.5), YAML-defined pipeline compositions (v0.4.6), and `max_context_bytes` cap for `accumulate`-mode pipelines (v0.4.7).

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
- [x] MCP server mode validation with Claude Code (validated — patched anubis_mcp 0.17.1 stdio transport + tools handler)

---

## v0.2.5 — Ash Framework + Phoenix Web Dashboard

**Status: Complete**

This milestone was not in the original roadmap but was delivered between v0.2 and v0.3.

### Ash Framework 3.0 Integration

Replaced the planned `jido_ecto` approach with `ash_postgres` directly. 12 migrations, 16+ Ash resources across 7 domains:

| Domain | Resources |
|---|---|
| Accounts | User, Token, ApiKey |
| Folio | Project, Action, InboxItem |
| Forge | Session, Event, Checkpoint, ExecSession |
| GitHub | IssueAnalysis |
| Orchestration | WorkflowRun, WorkflowStep, ApprovalGate |
| Projects | Project |
| Security | SecretRef |

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
- Dual-session `SessionManager`: a `BackendHost` session for real host commands (`git`, `mix`, pipes, redirects) plus a `Jido.Shell.Backend.Local` VFS session for the sandbox built-ins (`cat`, `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`). A command classifier routes automatically; `run_command force: :host | :vfs` overrides it.
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

- **System prompt auto-sync.** New `JidoClaw.Startup` module unifies `.jido/` bootstrap and system-prompt injection across all four agent entry points (REPL, `JidoClaw.chat/3`, `mix jidoclaw --mcp`, `jido --mcp` escript). `Prompt.sync/1` reconciles on-disk `.jido/system_prompt.md` against the bundled default via SHA comparison, stamped in sidecar `.jido/.system_prompt.sync` (metadata lives outside the prompt body so it never reaches the LLM). When the bundled default diverges from an edited user prompt, `.jido/system_prompt.md.default` is written alongside for review and `/upgrade-prompt` promotes it in place (with `.bak`). Entry points parse `project_dir` from argv *before* `app.start`/`ensure_all_started` so app-managed services (`Memory`, `Skills`, `Solutions.Store`, `Network.Supervisor`) initialize against the correct directory.
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
- **Telemetry coverage completion.** `verify_certificate` wraps its CoT call with `execution_kind: :certificate_verification`, populating `certificate_verdict`/`certificate_confidence` on the outcome row. `Reason`'s react branch now wraps with `execution_kind: :react_stub` so alias→react dispatch still produces a telemetry row with coherent `base_strategy` accounting (the underlying call remains a structured-prompt scaffold). `Telemetry.extract_tokens/1` reads `:input_tokens`/`:output_tokens` first (jido_ai's canonical keys per `deps/jido_ai/lib/jido_ai/actions/helpers.ex`) with `:prompt_tokens`/`:completion_tokens` fallback for legacy providers, and captures tokens on `{:error, %{usage: _}}` partial-failure paths in addition to `{:ok, _}` results. `ExecutionKind` enum now values: `:strategy_run`, `:react_stub`, `:certificate_verification`, `:pipeline_run`.

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
- **Strict compile green.** `mix.exs` sets `elixirc_options: [ignore_module_conflict: true]` to silence the intentional redefinitions in `lib/jido_claw/core/anubis_*_patch.ex`. Header comments on both patch files cross-reference the flag. Temporary — remove alongside the patches when `jido_mcp` upgrades to `anubis_mcp ~> 1.0`.
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

**Status: Planned**

Build on the jido_shell `BackendHost` foundation:

- **Custom command registry**: Register JidoClaw-specific commands (e.g., `jido status`, `jido memory search`) as jido_shell commands, accessible from the persistent session
- **SSH backend support**: Remote command execution on dev/staging servers via `Backend.SSH`
- **Streaming output to display**: Wire jido_shell transport events directly into Display for real-time output rendering during long-running commands
- **Environment profiles**: Named env var sets (dev, staging, prod) that can be switched per session

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
  backend: ecto  # or "file" (default)
  database_url: "postgres://..."
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

| Capability | Current | With Ash/PostgreSQL |
|---|---|---|
| Memory persistence | JSON file, FTS via string matching | PostgreSQL FTS, indexed queries |
| Solution search | In-memory Jaccard + BM25 | SQL-based BM25, composite indexes |
| Multi-tenant isolation | Process-level (ETS per tenant) | Database-level (schemas/RLS) |
| Audit trail | None (telemetry is volatile) | Append-only event log |
| Reputation tracking | JSON file | Atomic DB operations, history |
| Cluster coordination | `:pg` only | Shared DB state, distributed locks |
| Session message history | JSONL files | Structured DB with search |

Note: Agent state recovery and session metadata are already in PostgreSQL via Forge resources.

### Other Jido Ecosystem Libraries to Watch

| Library | Status | Potential Use |
|---|---|---|
| **jido_discovery** | TBD | Agent/service discovery in distributed deployments |
| **jido_workflow** | TBD | Advanced workflow patterns beyond current Composer FSM |

---

## Build Order

```
v0.2 (done) → v0.2.5 (done) → v0.3 (done) → v0.4.1..v0.4.7 (done) → v0.5 (Shell) → v0.6 (Memory/Solutions DB) → v0.7 (Burrito)
```

The v0.4.x cadence was intentional: each point release shipped one focused change to the reasoning subsystem, keeping every PR independently reviewable and revertible.

v0.6 memory/solutions migration is gated on actual need — don't migrate the remaining file-based stores until the current approach is a proven bottleneck.
