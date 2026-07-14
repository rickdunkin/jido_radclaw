# JIDO.md — Self-Knowledge for JidoClaw

This file is read by the Jido agent at session start. It describes the platform,
available tools, agent templates, skills, and conventions.

---

## Project

- **Name**: JidoClaw
- **Type**: Elixir/OTP
- **Version**: 0.6.4
- **Frameworks**: Phoenix (with LiveView), Ecto, Absinthe/GraphQL, Bandit HTTP adapter, Jido AI Agent Framework
- **Entry points**:
  - `lib/jido_claw/application.ex` — OTP supervision tree
  - `lib/jido_claw/cli/main.ex` — Escript CLI entrypoint
  - `lib/jido_claw/cli/repl.ex` — Interactive REPL loop
  - `lib/jido_claw/web/router.ex` — Phoenix HTTP/WS routes
  - `lib/jido_claw/web/graphql/schema.ex` — GraphQL read surface (/gql)
  - `config/config.exs` — Application configuration

---

## Architecture

JidoClaw is an AI agent platform built on BEAM/OTP with the Jido framework.

### Core Layers

```
CLI (REPL) ──> Agent Engine ──> LLM Provider (Ollama/Anthropic/OpenAI/etc.)
   |                |
   |                ├── Tools (35): file ops, git, search, shell, memory, swarm, browser, reasoning, scheduling, lua
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
├── JidoClaw.InfraSupervisor (one_for_one)
│   ├── Registry (SessionRegistry, TenantRegistry, …)
│   ├── JidoClaw.Repo (Postgres)
│   ├── JidoClaw.Security.Vault
│   ├── Phoenix.PubSub
│   ├── Jido.Signal.Bus (event routing)
│   └── Trace persistence + collector
├── JidoClaw.Forge.Supervisor (sandboxed execution)
├── Finch (HTTP pools)
├── JidoClaw.Telemetry
├── JidoClaw.Stats
├── JidoClaw.BackgroundProcess.Registry
├── DynamicSupervisor (sessions)
├── JidoClaw.Jido (agent runtime)
├── JidoClaw.TenantRuntimeSupervisor
│   ├── JidoClaw.Tenant.Supervisor (per-tenant: DynamicSupervisor, Cron.Scheduler)
│   └── JidoClaw.Tenant.Manager
├── JidoClaw.Skills (cached registry)
├── JidoClaw.Network.Supervisor
├── JidoClaw.AgentTracker
├── JidoClaw.Display
├── JidoClaw.Shell.Supervisor (VFS, profiles, shell sessions)
└── JidoClaw.Web.Endpoint (Phoenix — gateway/both modes)
```

### Signal Namespace

All internal events use `jido_claw.*`:
- `jido_claw.tool.complete` — tool execution finished
- `jido_claw.agent.spawned` — child agent created

### Multi-Tenancy

Each tenant gets isolated:
- DynamicSupervisor for sessions
- Cron scheduler
- Separate config and memory

---

## Agent Templates

Use `spawn_agent` with a template name to create a child agent. Each template
has a fixed tool set and iteration limit optimized for its task.

### `coder`
- **Description**: Full-capability coding agent with all tools
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, fetch_output, git_status, git_diff, git_commit, project_info
- **Max iterations**: 25

### `docs_writer`
- **Description**: Writes documentation and comments
- **Tools**: read_file, write_file, search_code
- **Max iterations**: 15

### `fixer`
- **Description**: Resolves open review findings, then self-reports the domains it touched
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, fetch_output, git_status, git_diff, git_commit, project_info
- **Max iterations**: 25

### `plan_arbiter`
- **Description**: Adjudicates the competing plans + critiques into a decision memo (read-only)
- **Tools**: read_file, search_code
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `plan_challenger`
- **Description**: Critiques ONE competing plan — blockers/concerns/strengths for the arbiter (read-only)
- **Tools**: read_file, search_code
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `plan_drafter`
- **Description**: Drafts ONE competing implementation plan under a stage-named bias (read-only)
- **Tools**: read_file, search_code, list_directory, project_info, browse_web, search_web
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `refactorer`
- **Description**: Refactors code with full tool access
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, fetch_output, git_status, git_diff, git_commit, project_info
- **Max iterations**: 25

### `researcher`
- **Description**: Explores and analyzes codebase structure, and researches the web (read-only)
- **Tools**: read_file, search_code, list_directory, project_info, browse_web, search_web
- **Max iterations**: 15

### `reviewer`
- **Description**: Reviews code changes for bugs and style issues (read-only)
- **Tools**: read_file, git_diff, fetch_output, git_status, search_code
- **Max iterations**: 15

### `sketch_build`
- **Description**: Builds a throwaway prototype in an isolated sandbox (file tools only)
- **Tools**: read_file, write_file, list_directory, search_code, read_real_file, search_real_code, list_real_directory
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `sketch_build_exec`
- **Description**: Builds AND runs a throwaway prototype in a Docker-isolated sandbox
- **Tools**: read_file, write_file, list_directory, search_code, read_real_file, search_real_code, list_real_directory, run_command, fetch_output
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `sketch_reviewer`
- **Description**: Reviews a throwaway prototype in the sandbox (read-only, file tools)
- **Tools**: read_file, list_directory, search_code, read_real_file, search_real_code, list_real_directory
- **Max iterations**: 15
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `system_executor`
- **Description**: Applies an approved change to the machine/environment (full mutating tools)
- **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, fetch_output, git_status, git_diff
- **Max iterations**: 25
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `system_verifier`
- **Description**: Verifies a system/environment change took on the real machine (read + run)
- **Tools**: read_file, search_code, list_directory, run_command, fetch_output, git_status, git_diff
- **Max iterations**: 20
- **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

### `test_runner`
- **Description**: Runs tests and reports results (read-only)
- **Tools**: read_file, run_command, fetch_output, search_code
- **Max iterations**: 15

### `verifier`
- **Description**: Interactive verification — reads code, runs tests/commands. Returns a structured verdict (`pass`/`fail`), confidence (`low`/`medium`/`high`), and short reasoning.
- **Tools**: read_file, search_code, git_diff, git_status, run_command, fetch_output, list_directory, verify_certificate
- **Max iterations**: 20

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

Skills are multi-step workflows that orchestrate agents. Run a skill
with the `run_skill` tool or the `/skill <name>` REPL command.

### Built-in Skills

- `debug_issue` — Systematic debugging — investigate, reproduce, fix, verify
- `explore_codebase` — Deep codebase exploration and documentation
- `full_review` — Run tests and code review in parallel, then synthesize findings
- `implement_feature` — Full feature implementation lifecycle — research, code, then test and review in parallel
- `iterative_feature` — Implement a feature with iterative refinement — generate, verify, repeat until passing
- `onboard_dev` — Generate comprehensive onboarding documentation for new developers
- `refactor_safe` — Review code, refactor, then verify with tests
- `security_audit` — Comprehensive security audit — scan project structure, then deep-dive in parallel
- `sfr_review` — Code review with semi-formal reasoning certificate
- `verified_feature` — Implement a feature with semi-formal pre-verification

Steps run sequentially by default. When steps carry `name` and `depends_on`
fields, the skill executes as a DAG — independent steps run in parallel,
dependent steps wait for their prerequisites. When a skill declares
`mode: iterative`, its generator step and evaluator step loop until the
evaluator passes the result or `max_iterations` is reached.

### Custom Skills

Create `.jido/skills/<name>.yaml` with this format:

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

The `name` field must be a valid UTF-8 string of at most 256 bytes — a
skill whose name violates the rule is excluded at load with a per-file
error log, and lookups report it as unknown.

The output of previous steps is available as context for subsequent steps.
The `synthesis` field is the final prompt used to summarize all step outputs
into a single result.

Available template names: `coder`, `docs_writer`, `fixer`, `refactorer`, `researcher`, `reviewer`, `test_runner`, `verifier`
Composer-internal (not spawnable): `plan_arbiter`, `plan_challenger`, `plan_drafter`, `sketch_build`, `sketch_build_exec`, `sketch_reviewer`, `system_executor`, `system_verifier`

---

## Tools (35 total)

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

### Lua Code-Mode
| Tool | Description |
|------|-------------|
| `lua_query` | Run a short read-only Lua script server-side over runs/events/cases/solutions/outputs |
| `lua_docs` | Render the documentation for the Lua sandbox host bindings |

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

Persistent memory survives across sessions, stored tenant-scoped in the
platform's Postgres database.

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
- Agents: one module per worker in `lib/jido_claw/agent/workers/`
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
