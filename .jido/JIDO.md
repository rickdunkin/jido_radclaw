# JIDO.md — Self-Knowledge for JidoClaw

This file is read by the Jido agent at session start. It describes the platform,
available tools, agent templates, skills, and conventions.

---

## Project

- **Name**: JidoClaw
- **Type**: Elixir/OTP
- **Version**: 0.3.0
- **Root**: /Users/rhl/Desktop/JidoClaw
- **Frameworks**: Phoenix 1.7+ (with LiveView), Bandit HTTP adapter, Jido AI Agent Framework
- **Entry points**:
  - `lib/jido_claw/application.ex` — OTP supervision tree
  - `lib/jido_claw/main.ex` — Escript CLI entrypoint
  - `lib/jido_claw/repl.ex` — Interactive REPL loop
  - `lib/jido_claw/web/router.ex` — Phoenix HTTP/WS routes
  - `config/config.exs` — Application configuration

---

## Architecture

JidoClaw is an AI agent platform built on BEAM/OTP with the Jido framework.

### Core Layers

```
CLI (REPL) ──> Agent Engine ──> LLM Provider (Ollama/Anthropic/OpenAI/etc.)
   |                |
   |                ├── Tools (33): file ops, git, search, shell, memory, swarm, browser, reasoning, scheduling
   |                ├── Skills: multi-step orchestrated workflows
   |                └── Solutions: fingerprint-based solution caching
   |
HTTP/WS (Phoenix) ──> Same agent engine, multi-tenant
   |
Channels (Discord) ──> Per-channel agent sessions
```

### Supervision Tree

```
JidoClaw.Supervisor (one_for_one)
├── Registry (SessionRegistry, TenantRegistry)
├── Phoenix.PubSub
├── Finch (HTTP pools)
├── Jido.Signal.Bus (event routing)
├── JidoClaw.Telemetry
├── JidoClaw.Stats
├── JidoClaw.BackgroundProcess.Registry
├── JidoClaw.Tool.Approval
├── DynamicSupervisor (sessions)
├── JidoClaw.Jido (agent runtime)
├── JidoClaw.Tenant.Supervisor
│   └── Per-tenant: DynamicSupervisor, Cron.Scheduler
├── JidoClaw.Tenant.Manager
├── JidoClaw.Solutions.Store
├── JidoClaw.Solutions.Reputation
├── JidoClaw.Network.Supervisor
└── JidoClaw.Web.Endpoint (Phoenix)
```

### Signal Namespace

All internal events use `jido_claw.*`:
- `jido_claw.tool.complete` — tool execution finished
- `jido_claw.agent.spawned` — child agent created
- `jido_claw.memory.saved` — memory entry persisted

### Multi-Tenancy

Each tenant gets isolated:
- DynamicSupervisor for sessions
- Cron scheduler
- Separate config and memory

---

## Agent Templates

Use `spawn_agent` with a template name to create a child agent.

### `coder`
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, git_status, git_diff, git_commit, project_info
- **Max iterations**: 25
- **Use for**: Writing new code, fixing bugs, implementing features, modifying existing files
- **Strength**: Full read/write/execute capability — the workhorse for any coding task

### `test_runner`
- **Tools**: read_file, run_command, search_code
- **Max iterations**: 15
- **Use for**: Running test suites, verifying changes, checking coverage, reproducing failures
- **Strength**: Read-only file access prevents accidental modifications during testing

### `reviewer`
- **Tools**: read_file, git_diff, git_status, search_code
- **Max iterations**: 15
- **Use for**: Code review, finding bugs, checking style, auditing recent changes
- **Strength**: Git-aware — can see exactly what changed and review in context

### `docs_writer`
- **Tools**: read_file, write_file, search_code
- **Max iterations**: 15
- **Use for**: Writing documentation, README files, module docs, inline comments
- **Strength**: Can read existing code to understand it, then write accurate docs

### `researcher`
- **Tools**: read_file, search_code, list_directory, project_info, browse_web, search_web
- **Max iterations**: 15
- **Use for**: Codebase exploration, architecture analysis, dependency mapping, web research (discover with search_web, read with browse_web)
- **Strength**: Read-only exploration of the codebase and public web research

### `refactorer`
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, git_status, git_diff, git_commit, project_info
- **Max iterations**: 25
- **Use for**: Large-scale refactoring, code restructuring, renaming across files
- **Strength**: Full capability like coder, but prompted specifically for safe refactoring patterns

---

## Custom Agents

Define custom agents in `.jido/agents/<name>.yaml`. These extend the built-in templates
with domain-specific system prompts, tool restrictions, and behavioral constraints.

```yaml
name: security_auditor
description: Finds security vulnerabilities and OWASP Top 10 issues
template: reviewer
system_prompt: |
  You are a security auditor. Focus exclusively on:
  - SQL injection, XSS, CSRF vulnerabilities
  - Hardcoded secrets or credentials
  - Insecure deserialization
  - Broken auth/access control
  - Missing input validation
  Report findings with severity (CRITICAL/HIGH/MEDIUM/LOW), file:line, and remediation.
max_iterations: 20
```

See `.jido/agents/` for pre-built examples.

---

## Skills

Skills are multi-step workflows that orchestrate agents sequentially.
Run with `run_skill` tool or `/skill <name>` command.

### Built-in Skills

| Skill | Steps | Purpose |
|-------|-------|---------|
| `full_review` | test_runner -> reviewer | Run tests and review changes, synthesize findings |
| `refactor_safe` | reviewer -> refactorer -> test_runner | Review, refactor, verify nothing broke |
| `explore_codebase` | researcher -> docs_writer | Deep exploration, produce project overview |
| `security_audit` | researcher -> reviewer | Scan for vulnerabilities and security issues |
| `implement_feature` | researcher -> coder -> test_runner -> reviewer | Full feature lifecycle |
| `debug_issue` | researcher -> test_runner -> coder -> test_runner | Investigate, reproduce, fix, verify |
| `onboard_dev` | researcher -> docs_writer | Generate onboarding documentation |

### Custom Skills

Create `.jido/skills/<name>.yaml`:

```yaml
name: my_skill
description: What this skill does
steps:
  - template: researcher
    task: "Explore the auth module and identify all entry points"
  - template: coder
    task: "Implement the changes based on the research findings"
  - template: test_runner
    task: "Run the full test suite and verify nothing is broken"
synthesis: "Summarize what was done and any remaining issues"
```

---

## Tools (33 total)

### File Operations
| Tool | Description |
|------|-------------|
| `read_file` | Read file contents with optional line range |
| `write_file` | Create or overwrite files |
| `edit_file` | Edit specific sections of a file |
| `list_directory` | List directory contents recursively |
| `search_code` | Ripgrep-based code search across the project |
| `project_info` | Get project metadata (type, deps, structure) |

### Shell & Git
| Tool | Description |
|------|-------------|
| `run_command` | Execute shell commands with timeout |
| `git_status` | Repository status |
| `git_diff` | Show staged and unstaged changes |
| `git_commit` | Create commits with messages |
| `fetch_output` | Retrieve the full stored output behind an output_ref |

### Swarm Orchestration
| Tool | Description |
|------|-------------|
| `spawn_agent` | Create a child agent from a template |
| `get_agent_result` | Wait for and retrieve a spawned agent's result |
| `list_agents` | List all running agents |
| `send_to_agent` | Send a message to a running agent |
| `kill_agent` | Terminate an agent |
| `handoff` | Transfer conversation ownership to a specialized worker template |

### Memory & Solutions
| Tool | Description |
|------|-------------|
| `remember` | Store persistent memory (fact, pattern, decision, preference) |
| `recall` | Search memories by query |
| `store_solution` | Cache a solution with a fingerprint |
| `find_solution` | Find cached solutions matching a fingerprint |
| `forget` | Remove or invalidate stored memory entries |

### Skills & Network
| Tool | Description |
|------|-------------|
| `run_skill` | Execute a multi-step skill workflow |
| `network_share` | Share solutions on the JidoClaw network |
| `network_status` | Check network connectivity |

### Browser
| Tool | Description |
|------|-------------|
| `browse_web` | Fetch and read web pages using a headless browser |
| `search_web` | Search the web via Brave Search; returns ranked results (title, URL, snippet) |

### Reasoning
| Tool | Description |
|------|-------------|
| `reason` | Apply a structured reasoning strategy to a complex problem |
| `run_pipeline` | Chain multiple reasoning strategies sequentially |
| `verify_certificate` | Verify code using semi-formal reasoning certificates |

### Scheduling
| Tool | Description |
|------|-------------|
| `schedule_task` | Schedule a recurring task (cron or interval) |
| `unschedule_task` | Remove a scheduled task by ID |
| `list_scheduled_tasks` | List all scheduled tasks with status |

---

## Build & Test

| Command | Purpose |
|---------|---------|
| `mix compile` | Compile the project |
| `mix test` | Run the full test suite |
| `mix test test/path/to/test.exs` | Run a specific test file |
| `mix test --failed` | Re-run only failing tests |
| `mix format` | Format all source files |
| `mix format --check-formatted` | Verify formatting (CI) |
| `mix deps.get` | Fetch dependencies |

---

## Memory

Persistent memory survives across sessions. Stored in `.jido/memory.json` (git-ignored).

**Memory types**: `fact`, `pattern`, `decision`, `preference`

**Tools**:
- `remember("auth uses Guardian JWT", type: "pattern")`
- `recall("auth")` — returns matching entries

---

## Display System

The REPL has a live display system powered by two GenServers in the supervision tree:

- **`JidoClaw.AgentTracker`** — Per-agent stat accumulator. Tracks tokens, tool calls, tool names, status, elapsed time for every agent (main + children). Monitors child processes for crash detection. Subscribes to `jido_claw.tool.*` and `jido_claw.agent.*` signals.

- **`JidoClaw.Display`** — Central terminal display coordinator. Two modes:
  - **Single mode**: Kaomoji thinking spinner (◕‿◕) + inline tool call/result lines with rich previews (diffs, file info, exit codes)
  - **Swarm mode**: Activates on first `spawn_agent`. Shows swarm box with per-agent tree, status icons, token counts, tool tracking

**Pure renderer modules** (no state, just return ANSI strings):
- `JidoClaw.Display.StatusBar` — Width-adaptive status bar: `⚕ model │ provider │ tokens/ctx │ [████░░] 19% │ $0.00 │ 3m │ 3 agents`
- `JidoClaw.Display.SwarmBox` — Swarm tree box with per-agent lines: `✓ @reviewer-1 [reviewer] done │ 3.1K │ 4 calls │ git_diff, read_file`

---

## Conventions

- Module naming: `JidoClaw.<Subsystem>.<Module>` (e.g., `JidoClaw.Tools.ReadFile`)
- Tools: one module per tool in `lib/jido_claw/tools/`
- Agents: one module per worker in `lib/jido_claw/agents/`
- Tests mirror lib: `test/jido_claw/tools/read_file_test.exs`
- Signal strings: `jido_claw.<subsystem>.<event>` (never `jido_cli`)
- Config: `.jido/config.yaml` for user settings, `config/config.exs` for app defaults

---

## Rules

- Always run tests after making changes
- Use `search_code` before modifying a function to find all call sites
- Use `git_diff` before committing to review what changed
- Keep commits atomic: one logical change per commit
- Prefer editing existing files over creating new ones
- Read the file before editing it — never write blind
- When a task is ambiguous, `recall` memory before asking the user
- Signal strings must use `jido_claw.*` namespace, never `jido_cli.*`

---

## Configuration

Managed by `.jido/config.yaml`. Key settings:

| Key | Default | Description |
|-----|---------|-------------|
| `provider` | `ollama` | LLM provider (ollama, anthropic, openai, google, groq, xai, openrouter) |
| `model` | `ollama:nemotron-3-super:cloud` | Provider:model string |
| `max_iterations` | `25` | Max agent reasoning steps per task |
| `timeout` | `120000` | Task timeout in milliseconds |

Run `/setup` to reconfigure interactively.

### Supported Providers

| Provider | API Key Env | Top Models | Context |
|----------|-------------|------------|---------|
| Ollama (local) | — | nemotron-3-super, qwen3.5:35b, qwen3-coder-next | 128-256K |
| Ollama Cloud | `OLLAMA_API_KEY` | **nemotron-3-super:cloud** (recommended), qwen3-coder:480b, deepseek-v3.1:671b | 128K-1M |
| Anthropic | `ANTHROPIC_API_KEY` | Claude Sonnet 4, Opus 4.6, Haiku 4.5 | 200K |
| OpenAI | `OPENAI_API_KEY` | GPT-4.1, o3, o4-mini | 200K-1M |
| Google | `GOOGLE_API_KEY` | Gemini 2.5 Flash, 2.5 Pro | 1M |
| Groq | `GROQ_API_KEY` | Llama 3.3 70B, DeepSeek R1 Distill | 128K |
| xAI | `XAI_API_KEY` | Grok 3, Grok 3 Mini | 131K |
| OpenRouter | `OPENROUTER_API_KEY` | Any model via unified API | varies |
