# JidoClaw Roadmap

## Current State: v0.3.0

Single-agent and swarm runtime working. 27 tools, REPL with boot sequence, multi-provider LLM support, persistent sessions, DAG-based skills, solutions engine, agent-to-agent networking, multi-tenancy scaffolding, MCP server mode.

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

## v0.3 — Memory & Solutions Database Migration

**Status: In Progress**

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

## v0.4 — VFS Integration for File Tools

**Status: Planned**

Mount the project directory into jido_shell's VFS so file tools (`ReadFile`, `WriteFile`, `ListDirectory`) can work through the unified VFS layer. Enables:

- Same shell session handles both file ops and command execution
- Multi-mount workspaces:
  ```
  /project   → Jido.VFS.Adapter.Local (real filesystem)
  /scratch   → Jido.VFS.Adapter.InMemory (temp workspace)
  /upstream  → Jido.VFS.Adapter.GitHub (upstream repo)
  /artifacts → Jido.VFS.Adapter.S3 (build outputs)
  ```
- Agent can `cat /project/mix.exs` and `cat /upstream/mix.exs` in the same workflow
- VFS-aware diffing across adapters

---

## v0.5 — Burrito Packaging

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

## v0.6 — Advanced Shell Integration

**Status: Planned**

Build on the jido_shell `BackendHost` foundation:

- **Custom command registry**: Register JidoClaw-specific commands (e.g., `jido status`, `jido memory search`) as jido_shell commands, accessible from the persistent session
- **SSH backend support**: Remote command execution on dev/staging servers via `Backend.SSH`
- **Streaming output to display**: Wire jido_shell transport events directly into Display for real-time output rendering during long-running commands
- **Environment profiles**: Named env var sets (dev, staging, prod) that can be switched per session

---

## v0.7 — Reasoning & Strategy Improvements

**Status: Planned**

- Strategy auto-selection based on task complexity analysis
- Strategy composition (e.g., CoT for planning + ReAct for execution)
- Strategy performance tracking (which strategies work best for which task types)
- User-defined strategy configurations in `.jido/strategies/`

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
v0.2 (done) → v0.2.5 (done) → v0.3 (memory/solutions DB) → v0.4 (VFS) → v0.5 (Burrito) → v0.6 (Shell) → v0.7 (Reasoning)
```

v0.3 memory/solutions migration is gated on actual need — don't migrate the remaining file-based stores until the current approach is a proven bottleneck.
