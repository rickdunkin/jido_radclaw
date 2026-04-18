# JidoClaw Roadmap

## Current State: v0.4.1

Single-agent and swarm runtime working. 27 tools, REPL with boot sequence, multi-provider LLM support, persistent sessions, DAG-based skills, solutions engine, agent-to-agent networking, multi-tenancy scaffolding, MCP server mode, and unified VFS across file tools and shell (v0.3 shipped).

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

**Status: In Progress**

Three sub-phases, each independently shippable. 0.4.1 complete; 0.4.2 and 0.4.3 planned.

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

**Status: Planned**

- User-defined strategy YAML in `.jido/strategies/` (overlays on built-ins and brand-new named strategies)
- Pipeline composition (e.g., CoT for planning → ReAct for execution) via `RunPipeline`; `base_strategy`/`pipeline_name`/`pipeline_stage` columns in `reasoning_outcomes` already reserved
- Wrap `verify_certificate` in telemetry with `execution_kind: :certificate_verification`

### v0.4.3 — Auto-selection & Feedback

**Status: Planned**

- `AutoReason` tool + `Reason strategy: "auto"` wiring
- `Classifier.recommend/2` consumes `Statistics.best_strategies_for/2` history via `opts[:history]` (accepted but ignored today)
- `/strategies stats` CLI surface backed by `Statistics.summary/0`
- LLM tie-breaker for close-scoring heuristic candidates
- Re-enable `adaptive` in classifier recommendations
- Thread `forge_session_id` / `agent_id` through `tool_context`
- Wire `/strategy state.strategy` into `handle_message/2`

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
v0.2 (done) → v0.2.5 (done) → v0.3 (VFS) → v0.4 (Reasoning) → v0.5 (Shell) → v0.6 (Memory/Solutions DB) → v0.7 (Burrito)
```

v0.6 memory/solutions migration is gated on actual need — don't migrate the remaining file-based stores until the current approach is a proven bottleneck.
