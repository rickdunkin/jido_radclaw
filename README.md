# JidoClaw

[![Elixir](https://img.shields.io/badge/Elixir-1.17%2B-blueviolet?logo=elixir)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27%2B-blue)](https://www.erlang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub issues](https://img.shields.io/github/issues/robertohluna/jido_claw)](https://github.com/robertohluna/jido_claw/issues)
[![GitHub tag](https://img.shields.io/github/v/tag/robertohluna/jido_claw?label=version)](https://github.com/robertohluna/jido_claw/tags)
[![Tests](https://img.shields.io/github/actions/workflow/status/robertohluna/jido_claw/ci.yml?label=tests)](https://github.com/robertohluna/jido_claw/actions)
[![30 Tools](https://img.shields.io/badge/tools-30-orange)](docs/ARCHITECTURE.md)
[![8 Providers](https://img.shields.io/badge/providers-8-blue)](docs/ARCHITECTURE.md)
[![7 Skills](https://img.shields.io/badge/skills-7-green)](docs/ARCHITECTURE.md)

> Full-stack AI agent platform built on the Jido framework for Elixir/OTP — CLI, web dashboard, sandbox execution, workflow orchestration, GitHub automation, and desktop app

```
     ██╗██╗██████╗  ██████╗  ██████╗██╗      █████╗ ██╗    ██╗
     ██║██║██╔══██╗██╔═══██╗██╔════╝██║     ██╔══██╗██║    ██║
     ██║██║██║  ██║██║   ██║██║     ██║     ███████║██║ █╗ ██║
██   ██║██║██║  ██║██║   ██║██║     ██║     ██╔══██║██║███╗██║
╚█████╔╝██║██████╔╝╚██████╔╝╚██████╗███████╗██║  ██║╚███╔███╔╝
 ╚════╝ ╚═╝╚═════╝  ╚═════╝  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
        自 動  ·  autonomous
```

JidoClaw is a full-stack AI agent orchestration platform built natively on the [Jido](https://github.com/agentjido/jido) framework for Elixir/OTP. It combines a CLI REPL, LiveView web dashboard, sandboxed code execution (Forge), persistent workflow orchestration with approval gates, a hierarchical GitHub issue bot, GTD task management, encrypted secret storage, and desktop app packaging — all in one Elixir application. Where closed platforms lock you into hosted infrastructure, JidoClaw runs anywhere Elixir runs: your laptop, a single VPS, or a distributed BEAM cluster.

## Platform Overview

| Layer | What It Does |
|-------|-------------|
| **CLI REPL** | Interactive terminal agent with 30 tools, swarm orchestration, live display |
| **Web Dashboard** | LiveView UI — dashboard, forge terminal, workflows, agents, projects, settings, GTD |
| **Forge** | Sandboxed code execution engine with 4 runner types (shell, claude_code, workflow, custom) |
| **Orchestration** | Persistent workflow engine with state machine, approval gates, retry lineage |
| **GitHub Bot** | Hierarchical multi-agent pipeline — triage → parallel research → PR generation |
| **Folio GTD** | Getting Things Done task management — inbox capture, context/energy tracking |
| **Security** | AES-256-GCM encryption at rest, multi-layer secret redaction (logs, prompts, UI, PubSub) |
| **Desktop App** | Tauri + Burrito packaging — native binary with embedded Phoenix server |
| **Data Layer** | Ash Framework 3.0 + PostgreSQL — resources, authentication, admin panel |

## Why JidoClaw?

- **BEAM-native**: Lightweight processes, fault tolerance, hot code reload — no Kubernetes required for multi-agent workloads
- **Full-stack**: CLI, REST API, WebSocket, LiveView dashboard, desktop app — one codebase, every interface
- **Multi-interface**: CLI REPL, REST API (OpenAI-compatible), WebSocket RPC, Discord, Telegram
- **Multi-provider**: Ollama (local + cloud), Anthropic, OpenAI, Google, Groq, xAI, OpenRouter — 8 providers, 35+ models
- **Multi-tenant**: Per-tenant supervision trees isolate resources and prevent cascading failures across teams
- **Sandboxed execution**: Forge runs code in isolated sprite containers with session lifecycle, concurrency limits, and streaming output
- **Workflow orchestration**: Persistent state machine with approval gates — human-in-the-loop for critical operations
- **GitHub automation**: Hierarchical agent pipeline processes issues end-to-end — triage, research, patch, PR
- **Security-first**: Encrypted secrets at rest, redaction filters on every output channel, API key authentication
- **Swarm orchestration**: The LLM decides when to spawn child agents — `spawn_agent`, `list_agents`, `send_to_agent`, `kill_agent` are first-class tools
- **30 built-in tools**: File ops, git, shell, code search, memory, solution caching, network sharing, swarm management, AI reasoning, cron scheduling
- **8 reasoning strategies**: ReAct, Chain-of-Thought, Chain-of-Draft, Tree-of-Thought, Graph-of-Thought, Atom-of-Thought, TRM, Adaptive — switchable per-session via `/strategy`
- **Virtual filesystem**: `github://`, `s3://`, `git://` URI schemes for transparent remote file access alongside local paths
- **Persistent shell sessions**: jido_shell-backed sessions preserve working directory and env vars across commands per workspace
- **DAG skill execution**: Skills with `depends_on` annotations execute in parallel phases via `Task.async_stream` — independent steps run concurrently
- **Cron scheduling**: Schedule recurring tasks via agent tools or CLI — persisted to `.jido/cron.yaml`, survives restarts, auto-disable on failure
- **Heartbeat monitoring**: `.jido/heartbeat.md` updated every 60s with agent status, uptime, stats, and system health
- **Live swarm display**: Real-time agent tree with per-agent stats, tool tracking, token counts, and animated spinners
- **Observable**: 20+ telemetry events, Phoenix LiveDashboard, structured logging
- **Extensible**: Custom agents, skills, channel adapters, tool approval workflows — all defined in YAML

## Live Swarm Display

JidoClaw renders a fully live terminal UI as your agent works — no external TUI library, just pure ANSI escape codes that work in any modern terminal.

### Status Bar

A persistent top line updates continuously with model, provider, token usage, a progress bar, cost, elapsed time, and active agent count. Segments are dropped automatically on narrow terminals.

```
 ⚕ qwen3-coder:32b │ ollama │ 24.1K/128K │ [██████░░░░] 19% │ $0.00 │ 3m │ 3 agents
```

### Thinking Spinner

While the agent waits for an LLM response, an animated kaomoji cycles through expressions:

```
  (◕‿◕) thinking...
  (◕ᴗ◕) thinking...
  (◔‿◔) thinking...
```

### Tool Execution

Tool calls render inline as they happen — arguments on invocation, result summary on completion:

```
  ⟳ edit_file path="lib/foo.ex"
  ✓ edit_file
    foo.ex
    - old_line
    + new_line
```

Rich previews are shown for common tools: file edits display inline diffs, reads show file path and line count, shell commands show exit code and tail output.

### Swarm Box

When child agents are active, a live summary box appears above the agent list:

```
 ┌─ SWARM ─────────────────────────────────────────────────┐
 │  3 agents  │  2 running  1 done  │  8.2K tokens  $0.00  │
 └────────────────────────────────────────────────────────┘
  ✓ @test-runner-1 [test_runner] done │ 3.1K │ $0.00 │ 4 calls │ run_command, read_file
  ● @reviewer-1 [reviewer] running │ 2.8K │ $0.00 │ 3 calls │ git_diff, read_file
  ● @refactorer-1 [refactorer] running │ 2.3K │ $0.00 │ 2 calls │ search_code, read_file
```

Each row tracks: agent name, template type, status, tokens consumed, cost, tool call count, and the names of tools called so far.

### Mode Transitions

The display starts in single-agent mode — spinner plus inline tool calls. When `spawn_agent` is called, it automatically switches to swarm mode and renders the agent tree. Once all child agents finish, it reverts to single-agent mode.

### Implementation

- Built on two OTP GenServers (`AgentTracker` and `Display`) in the main supervision tree
- Event-driven: the display reacts to `jido_claw.tool.*` and `jido_claw.agent.*` signals flowing through the SignalBus
- Per-agent state tracked in `AgentTracker`: tokens, cost, tool call count, tool names, status, elapsed time
- The `/status` and `/agents` commands surface the same data as the live display

## Quick Start

### Installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/robertohluna/jido_claw/main/install.sh | bash
```

Then run `jido` — it drops you into a setup wizard on first launch. Pick your LLM provider, configure API keys, choose your model, and you're in the REPL.

### Manual Setup

```bash
git clone https://github.com/robertohluna/jido_claw.git
cd jido_claw
mix deps.get && mix compile

# Create and migrate the database
mix ash.setup

# Start the REPL (runs setup wizard on first launch)
mix jidoclaw

# Or with HTTP + WebSocket gateway + web dashboard
JIDOCLAW_MODE=both mix jidoclaw
```

The web dashboard is available at `http://localhost:4000`. On first launch, the setup wizard checks prerequisites and guides you through provider/model configuration.

### First Boot

```
     ██╗██╗██████╗  ██████╗  ██████╗██╗      █████╗ ██╗    ██╗
     ...
        自 動  ·  autonomous

  v0.4.0 · elixir 1.17.3 · otp 27

  ⚙  workspace   my-project
  ⚙  project     elixir
  ⚙  provider    ollama cloud
  ⚙  model       nemotron-3-super:cloud
  ⚙  strategy    react
  ⚙  tools       30 loaded
  ⚙  templates   6 agent types
  ✓  skills      7 loaded
  ✓  agents      6 custom
  ✓  JIDO.md     loaded
  ✓  memory      12.4KB
  ✓  database    connected
  ✓  forge       ready (50 slots)

  ──────────────────────────────────────────────

  Type a message to start. /help for commands. Ctrl+C to quit.

jidoclaw>
```

## Data Layer — Ash Framework + PostgreSQL

JidoClaw uses [Ash Framework 3.0](https://ash-hq.org) as its resource layer, backed by PostgreSQL via AshPostgres.

### Domains & Resources

| Domain | Resources | Purpose |
|--------|-----------|---------|
| **Accounts** | User, Token, ApiKey | Authentication (password + magic link), API key management |
| **Projects** | Project | Project registry with GitHub repo linking |
| **Security** | SecretRef | Encrypted secret storage (AES-256-GCM via Cloak) |
| **Forge** | Session, ExecSession, Checkpoint, Event | Sandbox session audit trail |
| **Orchestration** | WorkflowRun, WorkflowStep, ApprovalGate | Persistent workflow state machine |
| **GitHub** | IssueAnalysis | Issue triage and analysis records |
| **Folio** | InboxItem, Action, Project | GTD task management |

### Authentication

Built on AshAuthentication with two strategies:

- **Password**: Email/password with hashed credentials, token-based sign-in
- **Magic Link**: Passwordless email authentication

API endpoints are protected via Bearer token or `x-api-key` header, validated against the ApiKey resource.

### Admin Panel

AshAdmin is mounted at `/admin` — browse and manage all resources through a web interface.

## Forge — Sandbox Execution Engine

Forge is a generic parallel sandbox execution engine that runs code in isolated sprite containers.

### Runner Types

| Runner | Purpose | Concurrency Limit |
|--------|---------|-------------------|
| `shell` | Shell command execution | 20 |
| `claude_code` | Claude CLI with `--output-format stream-json`, `--dangerously-skip-permissions` | 10 |
| `workflow` | Data-driven step engine (`:exec`, `:prompt`, `:condition`, `:call`, `:noop`) with `{{var}}` interpolation | 10 |
| `custom` | User-defined function runner | 10 |

**Total capacity: 50 concurrent sessions**

### Session Lifecycle

```
starting → bootstrapping → initializing → ready → running → stopping
                                            ↓
                                      needs_input
```

Sessions are tracked via OTP Registry, monitored for crashes, and persisted to PostgreSQL for audit.

### Usage

```elixir
# Start a shell session
{:ok, handle} = JidoClaw.Forge.start_session("my-task", runner: :shell)

# Execute commands
{:ok, output} = JidoClaw.Forge.exec(handle, "echo hello")

# Run an iteration loop
JidoClaw.Forge.run_loop(handle, max_iterations: 10)

# Resume / cancel / checkpoint
JidoClaw.Forge.resume(handle)
JidoClaw.Forge.cancel(handle)
JidoClaw.Forge.create_checkpoint(handle, "before-deploy")

# Run a workflow
{:ok, handle} = JidoClaw.Forge.start_session("deploy", runner: :workflow, config: %{
  steps: [
    %{type: :exec, command: "mix test"},
    %{type: :exec, command: "mix release"},
    %{type: :prompt, message: "Deploy to production?"}
  ]
})
```

### Sprite Client

Forge abstracts container management through a SpriteClient behaviour with 8 callbacks (`create/1`, `exec/3`, `spawn/4`, `write_file/3`, `read_file/2`, `inject_env/2`, `destroy/2`):

- **Live**: Real sprite containers (via [sprites-ex](https://github.com/mikehostetler/sprites-ex)) for production
- **Fake**: Agent-backed, temp directory + `System.cmd` for dev/test — no containers needed

### Streaming

Output is coalesced at 50ms intervals with a 64KB buffer (1MB max output) to prevent UI flooding. All output passes through the security redaction gate before reaching PubSub subscribers.

## Orchestration — Workflow Engine

Persistent workflow engine with AshStateMachine lifecycle and human-in-the-loop approval gates.

### Workflow States

```
pending → running → completed
              ↓
        awaiting_approval → completed
              ↓                ↓
           cancelled        failed
```

### Approval Gates

Critical workflow steps can require human approval before proceeding:

```elixir
# Workflow pauses at approval gate
# Approver reviews and decides
Ash.update!(gate, %{decision: :approved, approver_id: user.id})
# Workflow resumes
```

### Retry Lineage

Failed workflows can be retried — each retry links back to the original via `retry_of_id`, maintaining full lineage.

### Step Handlers

| Handler | Purpose |
|---------|---------|
| `CommitAndPR` | Git commit + pull request creation |
| `ForgeExec` | Delegates to Forge for sandboxed execution |
| `AgentTask` | Delegates to Jido agent runtime |

### Run Summary Feed

A GenServer aggregates workflow status with a 50-entry completion ring buffer, broadcasting updates via PubSub on each transition.

## GitHub Issue Bot

Hierarchical multi-agent pipeline that processes GitHub issues end-to-end.

### Pipeline

```
Webhook (issues.opened / issues.edited / issue_comment.created)
  → HMAC-SHA256 verification
    → Coordinator Agent
      ├── Triage Agent (keyword + label classification)
      ├── Research Coordinator (4 parallel agents via Task.async_stream)
      │   ├── Code Search Agent
      │   ├── Reproduction Agent
      │   ├── Root Cause Agent
      │   └── PR Search Agent
      └── PR Coordinator (3-attempt retry with quality gate)
          ├── Patch Agent (generates fix)
          ├── Quality Agent (reviews patch)
          └── PR Submit Agent (creates PR)
```

### Webhook Setup

Configure your GitHub App to send `issues` and `issue_comment` events to `/webhooks/github`. Payloads are verified via HMAC-SHA256 using `Plug.Crypto.secure_compare/2`.

```bash
export GITHUB_WEBHOOK_SECRET=your-webhook-secret
export GITHUB_APP_PRIVATE_KEY=...
```

## Folio — GTD Task Management

Getting Things Done workflow with inbox capture, clarification, and context-aware action tracking.

### GTD Flow

```
Capture → Inbox → Clarify → Actionable?
                              ├── Yes → Action (next, waiting, someday)
                              └── No  → Discard / Reference
```

### Action Tracking

Actions support context (`@phone`, `@computer`, `@office`), energy level (`low`, `normal`, `high`), time estimates, due dates, and waiting-for tracking.

### Access

Available through the LiveView UI at `/folio` and as AI agent tools for natural language task management.

## Security

### Encrypted Secrets

Secrets are encrypted at rest using AES-256-GCM via Cloak Vault:

```elixir
# Store an encrypted secret
Ash.create!(JidoClaw.Security.SecretRef, %{
  name: "github_token",
  encrypted_value: "ghp_xxxxxxxxxxxx",
  scope: "project:my-app"
})
```

### Multi-Layer Redaction

Every output channel is filtered for secrets:

| Layer | What It Catches |
|-------|----------------|
| **Log Redactor** | Logger filter strips secrets before they hit log files |
| **Prompt Redaction** | Strips secrets before sending to LLM providers |
| **Channel Redaction** | PubSub messages are sanitized |
| **UI Redaction** | Display output is filtered |

### Pattern Detection

9 regex patterns detect: API keys (OpenAI `sk-`, Anthropic `sk-ant-`), Bearer tokens, JWTs, GitHub PATs (`ghp_`, `github_pat_`), AWS access keys (`AKIA`), generic secrets, private keys, and connection strings.

## Web Dashboard

LiveView-powered dark-themed web interface at `http://localhost:4000`.

### Pages

| Route | Page | Purpose |
|-------|------|---------|
| `/` | Dashboard | Agent status, recent runs, platform stats |
| `/forge` | Forge Terminal | Interactive sandbox terminal (xterm.js) |
| `/workflows` | Workflows | Workflow runs, step status, approval UI |
| `/agents` | Agents | Agent configuration, templates, issue bot toggle |
| `/projects` | Projects | Project list, GitHub repo linking |
| `/settings` | Settings | User settings, API key management |
| `/folio` | Folio | GTD inbox, actions, projects |
| `/setup` | Setup Wizard | Prerequisite checks, credential validation |
| `/sign-in` | Sign In | Authentication |
| `/admin` | Admin Panel | AshAdmin resource browser |
| `/live-dashboard` | LiveDashboard | Phoenix telemetry metrics |

### Authentication

Session-based auth with `on_mount` hooks:

- `:live_user_required` — redirects unauthenticated users to sign-in
- `:live_user_optional` — allows anonymous access
- `:live_no_user` — sign-in/setup pages only

## Desktop App

JidoClaw can be packaged as a native desktop application using Tauri (frontend shell) + Burrito (Elixir binary packaging).

### How It Works

1. Burrito compiles JidoClaw into a self-contained native binary
2. On launch, the sidecar detects `BURRITO_TARGET` or `JIDOCLAW_DESKTOP=true`
3. An available port is found via `:gen_tcp.listen(0, ...)`
4. Phoenix starts as an embedded server with `check_origin: false`
5. Tauri opens a webview pointing at `localhost:{port}`

```bash
# Build native binary
mix release

# Or set env for development
JIDOCLAW_DESKTOP=true mix phx.server
```

## Setup Wizard

On first launch (or at `/setup`), the wizard checks:

| Check | What | Required |
|-------|------|----------|
| Elixir | Version ≥ 1.17 | Yes |
| PostgreSQL | Running, accessible | Yes |
| Git | Installed | Yes |
| Node.js | Version ≥ 18 | Yes |
| Ollama | Running locally | No (cloud providers available) |
| API Keys | Valid format, reachable | At least one provider |

## Supported Providers & Models

JidoClaw supports 8 LLM providers out of the box via [req_llm](https://hex.pm/packages/req_llm). Run `/setup` anytime to switch providers.

### Ollama (Local)

Run models on your own hardware. No API key needed.

| Model | Size | Context | Notes |
|-------|------|---------|-------|
| **`nemotron-3-super:latest`** | **120B MoE (12B active)** | **256K** | **Default — best accuracy/efficiency** |
| `qwen3.5:35b` | 35B | 128K | Lightweight local model |
| `qwen3-coder-next:latest` | — | 128K | Code-focused |
| `qwen3-next:80b` | 80B | 128K | Strong reasoning |
| `devstral-small-2:24b` | 24B | 128K | Code-focused, efficient |
| `nemotron-cascade-2:30b` | 30B MoE (3B active) | 128K | Lightweight MoE |
| `glm-4.7-flash:latest` | — | 128K | Fast inference |
| `qwen3:32b` | 32B | 128K | Solid general-purpose |

### Ollama Cloud

Access massive models without local hardware. Requires `OLLAMA_API_KEY`.

| Model | Size | Context | Notes |
|-------|------|---------|-------|
| **`nemotron-3-super:cloud`** | **120B MoE (12B active)** | **256K** | **Recommended — best agentic performance** |
| `qwen3-coder:480b` | 480B | 256K | Massive code model |
| `deepseek-v3.1:671b` | 671B | 128K | Largest available |
| `qwen3.5:72b` | 72B | 128K | Strong general-purpose |
| `llama4-maverick:latest` | MoE | 1M | Million-token context |
| `qwen3-next:80b` | 80B | 128K | Strong reasoning |
| `kimi-k2.5:latest` | — | 128K | Multimodal |
| `nemotron-cascade-2:30b` | 30B MoE | 128K | Budget option |

### Cloud Providers

| Provider | API Key | Top Models | Context |
|----------|---------|------------|---------|
| **Anthropic** | `ANTHROPIC_API_KEY` | Claude Sonnet 4, Opus 4.6, Haiku 4.5 | 200K |
| **OpenAI** | `OPENAI_API_KEY` | GPT-4.1, GPT-4.1-mini, o3, o4-mini | 200K–1M |
| **Google** | `GOOGLE_API_KEY` | Gemini 2.5 Flash, Gemini 2.5 Pro | 1M |
| **Groq** | `GROQ_API_KEY` | Llama 3.3 70B, DeepSeek R1 Distill | 128K |
| **xAI** | `XAI_API_KEY` | Grok 3, Grok 3 Mini | 131K |
| **OpenRouter** | `OPENROUTER_API_KEY` | 200+ models via unified API | varies |

## Architecture

```
JidoClaw.Supervisor
├── JidoClaw.Repo (PostgreSQL via AshPostgres)
├── JidoClaw.Security.Vault (AES-256-GCM encryption)
├── Registry (SessionRegistry, TenantRegistry)
├── Phoenix.PubSub
├── Finch (HTTP pools)
├── Jido.Signal.Bus (jido_claw.* events)
├── JidoClaw.Telemetry (20+ metrics)
├── JidoClaw.Stats (session counters)
├── JidoClaw.BackgroundProcess.Registry
├── JidoClaw.Tool.Approval
├── JidoClaw.Messaging (jido_messaging runtime — rooms, agents, bridges)
│
├── Forge Engine
│   ├── Registry (SessionRegistry)
│   ├── SpriteSupervisor (DynamicSupervisor)
│   ├── ExecSessionSupervisor (DynamicSupervisor)
│   ├── Forge.Manager (GenServer — concurrency control)
│   └── SpriteClient.Fake (dev/test sprite stub)
│
├── Orchestration
│   └── RunSummaryFeed (GenServer — workflow status aggregator)
│
├── Code Server
│   ├── Registry (RuntimeRegistry)
│   └── RuntimeSupervisor (DynamicSupervisor)
│
├── JidoClaw.SessionSupervisor (DynamicSupervisor)
├── JidoClaw.Jido (agent runtime)
├── JidoClaw.Tenant.Supervisor
│   └── per tenant:
│       ├── Session.Supervisor (DynamicSupervisor)
│       ├── Channel.Supervisor (DynamicSupervisor)
│       ├── Cron.Supervisor (DynamicSupervisor)
│       └── Tool.Supervisor (Task.Supervisor)
├── JidoClaw.Tenant.Manager
├── JidoClaw.Solutions.Store + Reputation
├── JidoClaw.Memory (persistent memory — ETS-backed, supervised)
├── JidoClaw.Skills (cached skill registry — GenServer, parsed once at boot)
├── JidoClaw.Shell.SessionManager (persistent shell sessions per workspace)
├── JidoClaw.Network.Supervisor
├── JidoClaw.Web.Endpoint (Phoenix — port 4000)
└── Cluster.Supervisor (libcluster, optional)
```

### Ash Domains

| Domain | Module | Resources |
|--------|--------|-----------|
| Accounts | `JidoClaw.Accounts` | User, Token, ApiKey |
| Projects | `JidoClaw.Projects` | Project |
| Security | `JidoClaw.Security` | SecretRef |
| Forge | `JidoClaw.Forge.Domain` | Session, ExecSession, Checkpoint, Event |
| Orchestration | `JidoClaw.Orchestration` | WorkflowRun, WorkflowStep, ApprovalGate |
| GitHub | `JidoClaw.GitHub` | IssueAnalysis |
| Folio | `JidoClaw.Folio` | InboxItem, Action, Project |

### OTP Process Overview

| Process | Type | Purpose | Supervised By |
|---------|------|---------|---------------|
| `JidoClaw.Repo` | Ecto.Repo | PostgreSQL connection pool | Application |
| `JidoClaw.Security.Vault` | Cloak.Vault | AES-256-GCM encryption key management | Application |
| `JidoClaw.Memory` | GenServer | Persistent cross-session memory (ETS + JSON file) | Application |
| `JidoClaw.Skills` | GenServer | Cached skill registry — parses YAML once at boot, serves from state | Application |
| `JidoClaw.Shell.SessionManager` | GenServer | Persistent shell sessions per workspace (jido_shell-backed) | Application |
| `JidoClaw.Messaging` | Supervisor | jido_messaging runtime (rooms, agents, bridges) | Application |
| `JidoClaw.Forge.Manager` | GenServer | Session registry, concurrency limits (50 total) | Application |
| `JidoClaw.Forge.SpriteSession` | GenServer | Per-session state machine (per session) | SpriteSupervisor |
| `JidoClaw.Orchestration.RunSummaryFeed` | GenServer | Workflow run status aggregator (50-entry ring buffer) | Application |
| `JidoClaw.CodeServer.Runtime` | GenServer | Per-project conversation runtime | RuntimeSupervisor |
| `Session.Worker` | GenServer | Per-session state, message history, agent binding with crash monitoring | Tenant Session.Supervisor |

### Session–Agent Binding

Each CLI or API session is backed by a `Session.Worker` GenServer. When an agent is started for a session, the worker binds to it via `Worker.set_agent/3`, which calls `Process.monitor/1` on the agent PID. If the agent crashes, the worker receives `{:DOWN, ...}` and transitions to `:agent_lost` status — enabling crash-aware session recovery.

```
Session.Worker ──monitor──> Agent PID
     │                          │
     │   {:DOWN, ref, ...}      │ (crash)
     ◄──────────────────────────┘
     │
     └──> status: :agent_lost
```

### Skill Workflow Engine

Skills support two execution modes, selected automatically based on whether steps declare `depends_on`:

**Sequential (FSM)** — Steps without `depends_on` run through `jido_composer`'s workflow FSM:

```
:step_1 ──:ok──> :step_2 ──:ok──> :step_3 ──:ok──> :done
   │                │                │
   └──:error──>     └──:error──>     └──:error──> :failed
```

**Parallel (DAG)** — Steps with `depends_on` annotations are topologically sorted into phases and executed via `Task.async_stream`. Independent steps within a phase run concurrently:

```
Phase 0: [research]           ← no dependencies, runs alone
Phase 1: [implement]          ← depends_on: research
Phase 2: [run_tests, review]  ← both depend on implement, run in parallel
Phase 3: [synthesize]         ← depends on run_tests + review
```

Each step spawns a templated agent, runs `ask_sync/2`, and collects the result. The DAG executor validates all dependency references at plan time and fails fast on cycles or missing refs.

## Interfaces

### CLI REPL

Interactive terminal agent with 30 tools and swarm orchestration.

```
jidoclaw> explain the authentication flow in this codebase
  (◕‿◕) thinking...
  ⟳ search_code query="auth"
  ✓ search_code
  ⟳ read_file path="lib/auth/guardian.ex"
  ✓ read_file

  The authentication flow uses Guardian for JWT...

jidoclaw> /agents      # list running child agents
jidoclaw> /skills      # list available skills
jidoclaw> /models      # list models for current provider
jidoclaw> /strategy    # show current reasoning strategy
jidoclaw> /strategies  # list all 8 reasoning strategies
jidoclaw> /status      # show config and stats
jidoclaw> /setup       # reconfigure provider/model
jidoclaw> /help        # full command list
```

### REST API (OpenAI-compatible)

```bash
# Health check
curl http://localhost:4000/health

# Chat completion (API key required)
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-api-key" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }'

# Streaming
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-api-key" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

### WebSocket RPC

Connect to `ws://localhost:4000/ws` and join `rpc:lobby`:

```json
{"topic": "rpc:lobby", "event": "gateway.status", "payload": {}}
{"topic": "rpc:lobby", "event": "sessions.list", "payload": {}}
{"topic": "rpc:lobby", "event": "sessions.create", "payload": {"tenant_id": "default", "session_id": "my-session"}}
{"topic": "rpc:lobby", "event": "sessions.sendMessage", "payload": {"tenant_id": "default", "session_id": "my-session", "content": "Hello!"}}
```

### LiveDashboard

Real-time metrics at `http://localhost:4000/live-dashboard` — session counts, provider latency, tool execution, VM stats.

## Tools (30)

| Category | Tools |
|----------|-------|
| **File Ops** | `read_file`, `write_file`, `edit_file`, `list_directory`, `search_code`, `project_info` |
| **Git** | `git_status`, `git_diff`, `git_commit` |
| **Shell** | `run_command` (persistent sessions via jido_shell) |
| **Swarm** | `spawn_agent`, `get_agent_result`, `list_agents`, `send_to_agent`, `kill_agent` |
| **Skills** | `run_skill` (sequential FSM or parallel DAG) |
| **Memory** | `remember`, `recall` |
| **Solutions** | `store_solution`, `find_solution` |
| **Network** | `network_share`, `network_status` |
| **Scheduling** | `schedule_task`, `unschedule_task`, `list_scheduled_tasks` |
| **Reasoning** | `reason` (8 strategies: react, cot, cod, tot, got, aot, trm, adaptive) |
| **Browser** | `browse` |

File tools support VFS URI schemes: `github://owner/repo/path`, `s3://bucket/key`, `git://repo/path` — transparent remote file access alongside local paths.

## Swarm Orchestration

Agent spawning is a first-class tool — the LLM calls `spawn_agent` when it decides it needs parallel workers. Each child agent is a real OTP process tracked by the Orchestrator with live stats: tokens, cost, tool calls, status.

### Agent Templates (built-in)

| Template | Capabilities | Max Iterations | Use Case |
|----------|-------------|----------------|----------|
| `coder` | Full R/W + commands | 25 | Coding, bug fixes, features |
| `test_runner` | Read + run_command | 15 | Test execution, verification |
| `reviewer` | Read + git | 15 | Code review, auditing |
| `docs_writer` | Read + write | 15 | Documentation |
| `researcher` | Read-only | 15 | Codebase analysis |
| `refactorer` | Full R/W + commands | 25 | Refactoring |

### Custom Agents (`.jido/agents/`)

Define domain-specific agents in YAML:

```yaml
name: security_auditor
description: Finds OWASP Top 10 vulnerabilities
template: reviewer
model: :capable
max_iterations: 20
system_prompt: |
  You are a security auditor. Focus on injection, auth bypass,
  hardcoded secrets, SSRF, path traversal...
tools:
  - read_file
  - search_code
  - git_diff
```

Ships with 6 custom agents: `security_auditor`, `architect`, `performance_analyst`, `bug_hunter`, `api_designer`, `onboarder`.

### Skills (`.jido/skills/`)

Multi-step orchestrated workflows:

| Skill | Execution | Steps | Purpose |
|-------|-----------|-------|---------|
| `full_review` | **DAG** | test_runner + reviewer (parallel) → synthesize | Test + review concurrently |
| `refactor_safe` | Sequential | reviewer → refactorer → test_runner | Review, refactor, verify |
| `explore_codebase` | Sequential | researcher → docs_writer | Deep exploration, generate docs |
| `security_audit` | Sequential | researcher → reviewer | Vulnerability scanning |
| `implement_feature` | **DAG** | research → implement → test + review (parallel) → synthesize | Full feature lifecycle |
| `debug_issue` | Sequential | researcher → test_runner → coder → test_runner | Systematic debugging |
| `onboard_dev` | Sequential | researcher → docs_writer | New developer onboarding |

Live swarm panel during execution:

```
┌─ SWARM ─────────────────────────────────────────────────┐
│  3 agents  │  2 running  1 done  │  8.2K tokens  $0.00  │
└────────────────────────────────────────────────────────┘
 ✓ @test-runner-1 [test_runner] done │ 3.1K │ 4 calls
 ● @reviewer-1 [reviewer] running │ 2.8K │ 3 calls
 ● @refactorer-1 [refactorer] running │ 2.3K │ 2 calls
```

## Reasoning Strategies

JidoClaw supports 8 AI reasoning strategies from `jido_ai`, switchable per-session via `/strategy <name>`:

| Strategy | Module | Best For |
|----------|--------|----------|
| **`react`** (default) | `Jido.AI.Reasoning.ReAct` | Tool-using agents — observe, think, act loop |
| `cot` | `Jido.AI.Reasoning.ChainOfThought` | Step-by-step logical reasoning |
| `cod` | `Jido.AI.Reasoning.ChainOfDraft` | Iterative draft refinement |
| `tot` | `Jido.AI.Reasoning.TreeOfThought` | Branching exploration of solution paths |
| `got` | `Jido.AI.Reasoning.GraphOfThought` | Non-linear reasoning with cross-connections |
| `aot` | `Jido.AI.Reasoning.AtomOfThought` | Atomic decomposition of complex problems |
| `trm` | `Jido.AI.Reasoning.TRM` | Task-oriented reasoning with planning |
| `adaptive` | `Jido.AI.Reasoning.Adaptive` | Auto-selects strategy based on task type |

The `reason` tool exposes these strategies to the agent itself — it can invoke deeper reasoning mid-task:

```
jidoclaw> analyze the concurrency model in this codebase
  ⟳ reason strategy="tot" prompt="enumerate all concurrency patterns..."
  ✓ reason
    Tree-of-Thought analysis with 3 branches...
```

## Virtual Filesystem (VFS)

File tools transparently support remote paths via `jido_vfs`:

```
jidoclaw> read the README from the jido repo
  ⟳ read_file path="github://agentjido/jido/README.md"
  ✓ read_file

jidoclaw> list files in our S3 deployment bucket
  ⟳ list_directory path="s3://my-deploy-bucket/releases/"
  ✓ list_directory
```

| Scheme | Adapter | Auth |
|--------|---------|------|
| `github://owner/repo[@ref]/path` | `Jido.VFS.Adapter.GitHub` | `GITHUB_TOKEN` env or app config |
| `s3://bucket/key` | `Jido.VFS.Adapter.S3` | `AWS_REGION` env + standard AWS credentials |
| `git://repo-path//file-path` | `Jido.VFS.Adapter.Git` | Local git repo access |
| Local paths | `File.*` | No auth needed |

## Platform Features

### Multi-Tenancy

Each tenant gets an isolated supervision subtree with its own session, channel, cron, and tool supervisors. A failure in one tenant's subtree does not affect others.

```elixir
{:ok, tenant} = JidoClaw.create_tenant(name: "acme")
{:ok, response} = JidoClaw.chat("acme", "session_1", "Hello!")
JidoClaw.tenants()
```

### Channel Adapters

Connect your agent to Discord and Telegram:

```bash
export DISCORD_BOT_TOKEN=your-bot-token
export DISCORD_GUILD_ID=your-guild-id
export TELEGRAM_BOT_TOKEN=your-bot-token
```

Adapters implement `JidoClaw.Channel.Behaviour` — add Slack, IRC, or any platform by implementing 5 callbacks.

### Cron Scheduling

```elixir
JidoClaw.Cron.Scheduler.schedule("default",
  schedule: {:cron, "0 9 * * MON"},
  task: "Generate weekly code review report",
  mode: :isolated
)
```

Auto-disables after 3 consecutive failures. Stuck detection at 2 hours.

### Tool Approval

```elixir
config :jido_claw, tool_approval_mode: :on_miss  # :off | :on_miss | :always
```

### Persistent Memory

Cross-session knowledge stored in `.jido/memory.json`:

```
jidoclaw> /memory                     # list all memories
jidoclaw> /memory search auth         # search by keyword
jidoclaw> /memory save "pattern" ...  # save a memory
jidoclaw> /memory forget ...          # delete a memory
```

### Clustering

Optional multi-node support via libcluster:

```elixir
config :jido_claw,
  cluster_enabled: true,
  cluster_strategy: :gossip  # :gossip | :kubernetes | :epmd
```

## Canopy Workspace Integration

JidoClaw works as an **agent runtime** inside [Canopy](https://github.com/Miosa-osa/canopy) workspaces — the open-source workspace agent harness protocol for AI agent systems. If JidoClaw is the agent, Canopy is the office.

Canopy provides a standardized folder structure (`SYSTEM.md`, skills, agents, context layers) that any AI agent can read and operate within. JidoClaw is designed to be a first-class Canopy citizen:

- **Workspace discovery**: JidoClaw reads Canopy's `SYSTEM.md` at boot and adapts its behavior to the workspace context
- **Shared agent configs**: Agent templates and skill definitions defined in the Canopy workspace are available to JidoClaw's swarm system
- **Tiered context loading**: Canopy's hierarchical context layers map to JidoClaw's `.jido/JIDO.md` self-knowledge system — optimizing token usage
- **Multi-agent orchestration**: JidoClaw's swarm tools (`spawn_agent`, `send_to_agent`) work alongside Canopy's 168+ pre-built agents and 114+ reusable skills
- **No vendor lock-in**: Both Canopy and JidoClaw are MIT-licensed, infrastructure-free, and work with any LLM provider

Running outside Canopy, JidoClaw is a fully self-contained local platform — Canopy integration is opt-in.

## Agent Harness Compatibility

JidoClaw can also be used as an **agent runtime backend** inside agent harnesses and orchestration tools. The Jido ecosystem includes [JidoHarness](https://github.com/agentjido/jido_harness) — a normalized protocol for connecting CLI AI coding agents — with adapters for:

- **[jido_claude](https://github.com/agentjido/jido_claude)** — Claude Code adapter
- **[jido_codex](https://github.com/agentjido/jido_codex)** — OpenAI Codex CLI adapter
- **[jido_gemini](https://github.com/agentjido/jido_gemini)** — Google Gemini CLI adapter

Other harnesses and orchestration frameworks that can integrate with JidoClaw's OpenAI-compatible REST API:

- **[PaperClip](https://github.com/nicholasgasior/paperclip)** — lightweight agent harness
- Any OpenAI-compatible client — JidoClaw's `/v1/chat/completions` endpoint works with any tool that speaks the OpenAI chat API

Because JidoClaw exposes a standard OpenAI-compatible HTTP API, it can serve as a drop-in backend for any agent harness, coding assistant, or automation tool that supports custom API endpoints.

## Configuration

### Project Config (`.jido/config.yaml`)

```yaml
provider: ollama
model: "ollama:nemotron-3-super:cloud"
strategy: react
max_iterations: 25
timeout: 120000
```

```yaml
# Anthropic Claude
provider: anthropic
model: "anthropic:claude-sonnet-4-20250514"
```

```yaml
# OpenAI
provider: openai
model: "openai:gpt-4.1"
```

```yaml
# OpenRouter (200+ models)
provider: openrouter
model: "openrouter:anthropic/claude-sonnet-4"
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `JIDOCLAW_MODE` | `both` | Runtime mode: `cli`, `gateway`, or `both` |
| `JIDOCLAW_ENCRYPTION_KEY` | — | 32-byte hex key for Cloak Vault (AES-256-GCM) |
| `JIDOCLAW_DESKTOP` | — | Set to `true` for desktop sidecar mode |
| `JIDOCLAW_PORT` | — | Override port for desktop mode |
| `GITHUB_WEBHOOK_SECRET` | — | HMAC secret for GitHub webhook verification |
| `OLLAMA_API_KEY` | — | Ollama Cloud API key |
| `ANTHROPIC_API_KEY` | — | Anthropic API key |
| `OPENAI_API_KEY` | — | OpenAI API key |
| `GOOGLE_API_KEY` | — | Google Gemini API key |
| `GROQ_API_KEY` | — | Groq API key |
| `XAI_API_KEY` | — | xAI Grok API key |
| `OPENROUTER_API_KEY` | — | OpenRouter API key |
| `DISCORD_BOT_TOKEN` | — | Discord bot token |
| `DISCORD_GUILD_ID` | — | Discord guild ID |
| `TELEGRAM_BOT_TOKEN` | — | Telegram bot token |
| `GITHUB_TOKEN` | — | GitHub API token (for `github://` VFS paths) |
| `AWS_REGION` | `us-east-1` | AWS region (for `s3://` VFS paths) |
| `CANOPY_WORKSPACE_URL` | — | Canopy workspace URL |
| `CANOPY_API_KEY` | — | Canopy workspace API key |

### `.jido/` Directory Structure

```
.jido/
├── JIDO.md              # Auto-generated self-knowledge (agent reads this at boot)
├── config.yaml          # Provider, model, timeouts (git-ignored)
├── agents/              # Custom agent definitions (YAML)
│   ├── security_auditor.yaml
│   ├── architect.yaml
│   ├── performance_analyst.yaml
│   ├── bug_hunter.yaml
│   ├── api_designer.yaml
│   └── onboarder.yaml
├── skills/              # Multi-step skill workflows (YAML)
│   ├── full_review.yaml
│   ├── refactor_safe.yaml
│   ├── explore_codebase.yaml
│   ├── security_audit.yaml
│   ├── implement_feature.yaml
│   ├── debug_issue.yaml
│   └── onboard_dev.yaml
├── memory.json          # Persistent memory (git-ignored)
├── sessions/            # Session logs (git-ignored)
└── solutions.json       # Solution fingerprint cache
```

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `jido_claw.session.start` | system_time | tenant_id, session_id |
| `jido_claw.session.stop` | duration | tenant_id, session_id |
| `jido_claw.session.message` | count | tenant_id, session_id, role |
| `jido_claw.provider.request.start` | system_time | model |
| `jido_claw.provider.request.stop` | duration | model |
| `jido_claw.tool.execute.start` | system_time | tool_name |
| `jido_claw.tool.execute.stop` | duration | tool_name |
| `jido_claw.cron.job.start` | system_time | job_id, tenant_id |
| `jido_claw.tenant.create` | count | tenant_id |
| `jido_claw.channel.message.inbound` | count | adapter |

## Project Structure

```
lib/jido_claw/
├── application.ex              # OTP supervision tree
├── repo.ex                     # AshPostgres.Repo
├── memory.ex                   # Persistent memory GenServer (ETS + JSON, supervised)
├── skills.ex                   # Cached skill registry GenServer (parsed once at boot)
├── accounts.ex                 # Ash.Domain — users, auth, API keys
├── accounts/
│   ├── user.ex                 # User resource (password + magic link auth)
│   ├── token.ex                # AshAuthentication token resource
│   ├── api_key.ex              # API key resource
│   └── secrets.ex              # Auth secret provider
├── projects.ex                 # Ash.Domain — project registry
├── projects/
│   └── project.ex              # Project resource
├── security.ex                 # Ash.Domain — encrypted secrets
├── security/
│   ├── vault.ex                # Cloak.Vault (AES-256-GCM)
│   ├── secret_ref.ex           # Encrypted secret resource (AshCloak)
│   └── redaction/              # 4 redaction filters (log, prompt, channel, UI)
│       ├── patterns.ex         # 9 regex patterns for secret detection
│       ├── log_redactor.ex     # Logger filter
│       ├── prompt_redaction.ex # LLM prompt sanitizer
│       ├── channel_redaction.ex # PubSub message filter
│       └── ui_redaction.ex     # Display output filter
├── forge.ex                    # Forge facade (start_session, exec, run_loop, resume, cancel, checkpoint)
├── forge/
│   ├── manager.ex              # Concurrency control GenServer (50 total, per-runner limits)
│   ├── sprite_session.ex       # Per-session state machine GenServer
│   ├── runner.ex               # Runner behaviour (init, run_iteration, apply_input, handle_output, terminate)
│   ├── runners/
│   │   ├── shell.ex            # Shell command execution
│   │   ├── claude_code.ex      # Claude CLI with stream-json output
│   │   ├── workflow.ex         # Data-driven step engine with {{var}} interpolation
│   │   └── custom.ex           # User-defined function runner
│   ├── sprite_client.ex        # Container abstraction dispatcher
│   ├── sprite_client/
│   │   ├── behaviour.ex        # 8 callbacks (create, exec, spawn, write_file, read_file, inject_env, destroy)
│   │   ├── live.ex             # Real sprite containers
│   │   └── fake.ex             # Agent-backed dev/test stub
│   ├── domain.ex               # Ash.Domain — session audit
│   ├── resources/
│   │   ├── session.ex          # forge_sessions table (10-state phase enum)
│   │   ├── exec_session.ex     # forge_exec_sessions table
│   │   ├── checkpoint.ex       # forge_checkpoints table
│   │   └── event.ex            # forge_events table
│   ├── bootstrap.ex            # Sprite initialization steps
│   ├── persistence.ex          # Fire-and-forget Ash persistence
│   ├── pubsub.ex               # Redaction-gated PubSub
│   ├── streaming/
│   │   └── chunk_coalescer.ex  # 50ms coalescing, 64KB buffer, 1MB max
│   ├── step_handler.ex         # Behaviour for :call workflow steps
│   └── error.ex                # 5 typed exceptions with classify/1
├── orchestration.ex            # Ash.Domain — workflows
├── orchestration/
│   ├── workflow_run.ex         # AshStateMachine (6 states, retry lineage)
│   ├── workflow_step.ex        # Step status, output, timing (5 states)
│   ├── approval_gate.ex        # Approver, decision, timestamp
│   ├── run_pubsub.ex           # Workflow event broadcasting
│   ├── run_summary_feed.ex     # Status aggregator GenServer (50-entry ring buffer)
│   └── step_handlers/
│       ├── behaviour.ex        # Step handler behaviour
│       ├── commit_and_pr.ex    # Git commit + PR creation
│       ├── forge_exec.ex       # Delegates to Forge
│       └── agent_task.ex       # Delegates to Jido agent
├── github.ex                   # Ash.Domain — issue analysis
├── github/
│   ├── issue_analysis.ex       # github_issue_analyses table
│   ├── webhook_signature.ex    # HMAC-SHA256 with secure_compare
│   ├── webhook_pipeline.ex     # Routes issues.opened, issues.edited, issue_comment.created
│   ├── issue_comment_client.ex # Req.post to GitHub API
│   └── agents/
│       ├── coordinator_agent.ex      # Top-level: triage → research → PR
│       ├── triage_agent.ex           # Keyword + label classification
│       ├── research_coordinator.ex   # 4 parallel Task.async workers
│       └── pull_request_coordinator.ex # 3-attempt retry with quality gate
├── folio.ex                    # Ash.Domain — GTD
├── folio/
│   ├── inbox_item.ex           # Capture/process/discard workflow
│   ├── action.ex               # Next/waiting/someday with context, energy, time_estimate
│   └── project.ex              # GTD projects with has_many :actions
├── code_server.ex              # Project runtime facade
├── code_server/
│   └── runtime.ex              # Per-project GenServer
├── setup/
│   ├── prerequisite_checker.ex # Checks Elixir, PostgreSQL, Git, Ollama, Node.js
│   ├── credential_validator.ex # Validates API keys + Ollama local
│   └── wizard.ex               # Setup orchestrator (computes ready?)
├── desktop/
│   ├── sidecar.ex              # Burrito/Tauri detection, endpoint reconfiguration
│   └── port_finder.ex          # Available port detection via gen_tcp
├── agent/
│   ├── agent.ex                # Main Jido agent (30 tools)
│   ├── identity.ex             # Agent identity
│   ├── prompt.ex               # System prompt builder
│   └── templates.ex            # Agent template registry (6 types)
├── cli/
│   ├── branding.ex             # ASCII art, boot sequence, spinner
│   ├── commands.ex             # Slash command router
│   ├── main.ex                 # Escript entry point
│   └── repl.ex                 # Interactive REPL loop
├── platform/
│   ├── messaging.ex            # jido_messaging runtime (rooms, agents, bridges)
│   ├── session/
│   │   └── worker.ex           # GenServer-per-session + agent binding + crash monitoring
│   ├── channel/                # Platform adapters (Discord, Telegram)
│   ├── cron/                   # Per-agent scheduling
│   └── tenant/                 # Multi-tenant supervision
├── network/                    # Agent-to-agent networking
├── reasoning/
│   └── strategy_registry.ex    # Maps 8 strategy names to Jido.AI.Reasoning.* modules
├── shell/
│   └── session_manager.ex      # Persistent shell sessions per workspace (jido_shell)
├── vfs/
│   └── resolver.ex             # VFS path routing (github://, s3://, git://, local)
├── tools/                      # 30 tool implementations (including reason, browse)
├── workflows/
│   ├── skill_workflow.ex       # jido_composer FSM engine for sequential skills
│   ├── plan_workflow.ex        # DAG executor for parallel skill phases
│   └── step_action.ex          # Jido.Action wrapping agent spawn + ask_sync
├── solutions/                  # Solution fingerprinting + reputation
├── background_process/         # OS process tracking + output buffer
├── providers/                  # LLM provider abstraction (Ollama)
├── tool/                       # Tool approval system
└── web/
    ├── endpoint.ex             # Phoenix endpoint
    ├── router.ex               # API + webhook + LiveView routes
    ├── web.ex                  # Phoenix web module macros
    ├── live_user_auth.ex       # LiveView on_mount auth hooks
    ├── components/
    │   ├── core_components.ex  # flash_group, button, stat_card, status_badge
    │   ├── layouts.ex          # App + root layouts
    │   └── layouts/
    │       ├── root.html.heex  # Root HTML (dark theme, CSS custom properties)
    │       └── app.html.heex   # App shell (sticky nav, 7 nav links)
    ├── live/
    │   ├── dashboard_live.ex   # Agent status, recent runs, stats
    │   ├── forge_live.ex       # Forge terminal (xterm.js)
    │   ├── workflows_live.ex   # Workflow runs, approval UI
    │   ├── agents_live.ex      # Agent config, templates
    │   ├── projects_live.ex    # Project list, import
    │   ├── settings_live.ex    # User settings, API keys
    │   ├── folio_live.ex       # GTD inbox/actions/projects
    │   ├── setup_live.ex       # Setup wizard UI
    │   └── sign_in_live.ex     # Authentication
    ├── controllers/
    │   ├── health_controller.ex # Health check
    │   ├── chat_controller.ex   # OpenAI-compatible chat
    │   └── webhook_controller.ex # GitHub webhook handler
    ├── channels/               # WebSocket RPC
    └── plugs/
        └── api_key_auth.ex     # Bearer/x-api-key authentication
```

## Dependencies

| Category | Package | Purpose |
|----------|---------|---------|
| Data layer | `ash`, `ash_postgres`, `ash_authentication`, `ash_authentication_phoenix` | Resource framework, PostgreSQL, auth |
| Data extensions | `ash_admin`, `ash_json_api`, `ash_paper_trail`, `ash_archival` | Admin panel, JSON:API, audit trail, soft delete |
| Data types | `ash_cloak`, `ash_state_machine`, `ash_typescript` | Encryption, state machines, TypeScript types |
| Database | `ecto_sql`, `postgrex` | PostgreSQL adapter |
| Encryption | `cloak` | AES-256-GCM encryption at rest |
| Agent engine | `jido` | OTP supervisor, agent lifecycle |
| AI reasoning | `jido_ai` | LLM integration, ReAct loop |
| Actions | `jido_action` | Tool/action system |
| Events | `jido_signal` | Event bus, pub/sub |
| MCP | `jido_mcp` | MCP server protocol |
| Memory | `jido_memory` | Persistent cross-session memory (ETS + JSON) |
| Browser | `jido_browser` | Browser automation tools |
| Shell | `jido_shell` | Sandboxed shell execution (VFS-backed) |
| Filesystem | `jido_vfs` | Virtual filesystem abstraction |
| Skills | `jido_skill` | Skill registry for cross-ecosystem discoverability |
| Composition | `jido_composer` | Workflow FSM engine — powers skill execution pipeline |
| Messaging | `jido_messaging` | Inter-agent message routing (rooms, agents, bridges) — supervised at boot |
| LLM providers | `req_llm` | Provider abstraction (Ollama, Anthropic, OpenAI, Google, Groq, xAI, OpenRouter) |
| Web | `phoenix`, `phoenix_live_view`, `bandit` | HTTP/WS/LiveView gateway |
| Observability | `telemetry`, `phoenix_live_dashboard` | Metrics and dashboard |
| Scheduling | `crontab` | Cron expressions |
| Cluster discovery | `libcluster` | Node discovery |
| Data | `jason`, `yaml_elixir` | Serialization |
| HTTP | `finch` | LLM API calls |
| Discord | `nostrum` (optional) | Discord bot adapter |
| Desktop | `burrito` | Native binary packaging |

## v0.5.0 — Full-Stack Platform

This release transforms JidoClaw from a CLI-only agent platform into a full-stack platform:

| Change | Before | After |
|--------|--------|-------|
| **Data layer** | ETS + JSON files only | Ash Framework 3.0 + PostgreSQL (7 domains, 15+ resources) |
| **Authentication** | None | Password + Magic Link via AshAuthentication, API key auth |
| **Security** | No encryption | AES-256-GCM encrypted secrets, 4-layer redaction (logs, prompts, PubSub, UI) |
| **Sandbox execution** | None | Forge engine — 4 runner types, 50 concurrent sessions, sprite containers |
| **Workflows** | Skills only (ephemeral) | Persistent state machine with approval gates, retry lineage |
| **GitHub automation** | None | Hierarchical agent pipeline — triage → 4 parallel research → PR with quality gate |
| **Task management** | None | Folio GTD — inbox, actions with context/energy, projects |
| **Web UI** | LiveDashboard only | 8 LiveView pages — dashboard, forge terminal, workflows, agents, projects, settings, GTD, setup |
| **Desktop** | CLI only | Tauri + Burrito native app with embedded Phoenix server |
| **Admin** | None | AshAdmin at `/admin` for all resources |

## v0.4.0 — Reasoning, VFS, Shell, DAG Skills

| Change | Before | After |
|--------|--------|-------|
| **Reasoning** | ReAct loop only (hardcoded) | 8 pluggable strategies via `StrategyRegistry` + `reason` tool |
| **VFS** | Local filesystem only | `github://`, `s3://`, `git://` URI routing via `jido_vfs` adapters |
| **Shell** | Stateless `System.cmd` per call | Persistent `jido_shell` sessions per workspace (cwd + env preserved) |
| **DAG skills** | Sequential FSM only | `depends_on` annotations → topological sort → parallel phases via `Task.async_stream` |
| **Tool count** | 27 tools | 30 tools (consolidated, added `reason` + `browse`) |

### v0.3.0 OTP Architecture

The previous release hardened the OTP supervision tree:

| Change | Before | After |
|--------|--------|-------|
| **Memory** | Lazily started in REPL, unsupervised | Supervised GenServer in Application, started at boot |
| **Skills** | Re-parsed YAML from disk on every call | GenServer caches parsed skills at boot, serves from state |
| **Session–Agent binding** | `:agent_pid` field existed but was never set | `Worker.set_agent/3` monitors agent, detects crashes → `:agent_lost` |
| **Messaging** | `jido_messaging` dep declared but unused | `JidoClaw.Messaging` supervisor started at boot (rooms, agents, bridges) |
| **Skill execution** | Hand-rolled `Enum.reduce_while` loop | `jido_composer` workflow FSM with proper state transitions |

### Component Interaction Map

| Component | Uses | When | How |
|-----------|------|------|-----|
| `Prompt.build/1` | `Skills.all/0` | Session start | Fetches cached skill names for system prompt |
| `Prompt.build/1` | `Memory.list_recent/1` | Session start | Injects known context into prompt |
| `RunSkill` tool | `Skills.get/1` | Agent calls `run_skill` | Looks up cached skill definition |
| `RunSkill` tool | `SkillWorkflow.run/3` or `PlanWorkflow.run/3` | Agent calls `run_skill` | Routes to FSM (sequential) or DAG (parallel) based on `depends_on` |
| `SkillWorkflow` | `StepAction` | Each FSM step | Spawns templated agent, runs `ask_sync` |
| `PlanWorkflow` | `Task.async_stream` | Each DAG phase | Runs independent steps concurrently |
| `REPL` | `Worker.set_agent/3` | Session creation | Binds agent PID to session for monitoring |
| `Worker` | `Process.monitor/1` | Agent bound | Detects agent crash → `:agent_lost` status |
| `Forge.Manager` | `Registry` + `MapSet` | Session start | Enforces per-runner concurrency limits |
| `WebhookPipeline` | `CoordinatorAgent` | Webhook received | Dispatches hierarchical agent pipeline |
| `Persistence` | `Ash.create!` | Session events | Fire-and-forget audit logging |

### Execution Flow

The full cycle from user input to displayed response:

```
1. INPUT
   IO.gets() → REPL.handle_message/2       [repl.ex:142]
   ├─ Worker.add_message(:user, msg)        [repl.ex:144]  persist to JSONL
   ├─ Display.start_thinking()              [repl.ex:150]  show spinner
   └─ Agent.ask(pid, msg)                   [repl.ex:152]  ASYNC — returns handle

2. REACT LOOP (inside jido_ai — iterates until done)
   ┌──────────────────────────────────────────────────────────────┐
   │  LLM call with 30 tool schemas          [agent.ex:5-36]    │
   │    ↓                                                        │
   │  Parse response ── has tool_calls? ─── NO ──→ DONE (text)  │
   │    │ YES                                                    │
   │    ↓                                                        │
   │  For each tool_call:                                        │
   │    Tool.run(params, context)   ← Jido.Action dispatch      │
   │    └─ {:ok, result} or {:error, reason}                     │
   │    ↓                                                        │
   │  Append tool results to conversation                        │
   │    ↓                                                        │
   │  Loop ──────── iteration < 25? ─── NO ──→ DONE (forced)    │
   │         YES ──→ back to LLM call                            │
   └──────────────────────────────────────────────────────────────┘

3. LIVE DISPLAY (concurrent with ReAct loop)
   poll_with_tool_display(handle)            [repl.ex:188]
   └─ Every 600ms:
      ├─ AgentServer.status(pid)             [repl.ex:217]  snapshot agent state
      │  └─ Extract tool_calls from snapshot
      │     ├─ NEW call  → Display.tool_start(name, args)
      │     └─ DONE call → Display.tool_complete(name, result)
      └─ Agent.await(handle, timeout: 600)   [repl.ex:191]  check if finished

4. TOOL EXECUTION (called BY the ReAct loop, not after it)
   Each tool is a Jido.Action with run(params, context):
   ├─ read_file   → File.read + return content
   ├─ run_command  → System.cmd + return output
   ├─ spawn_agent  → start_agent + spawn(ask_sync) → return immediately
   ├─ run_skill    → SkillWorkflow FSM (see below)
   ├─ remember     → Memory.remember (ETS + JSON)
   └─ ...30 total, each returns {:ok, result} to the loop

5. SKILL WORKFLOW (when LLM calls run_skill tool)
   RunSkill.run/2                            [run_skill.ex:29]
   ├─ Skills.get(name)                       [run_skill.ex:34]   cached GenServer lookup
   └─ SkillWorkflow.run(skill)               [skill_workflow.ex:28]
      ├─ Build FSM: :step_1 →:ok→ :step_2 →:ok→ :done
      │                  └:error→ :failed
      └─ execute_loop:
         ├─ StepAction.run(template, task)   [step_action.ex:22]
         │  ├─ Jido.start_agent(template)    spawn child OTP process
         │  ├─ template.ask_sync(pid, task)  BLOCKING — nested ReAct loop
         │  └─ return result text
         ├─ Machine.apply_result(result)     store in FSM context
         ├─ Machine.transition(:ok)          advance to next state
         └─ recurse until Machine.terminal?

6. SWARM (when LLM calls spawn_agent — parallel, non-blocking)
   SpawnAgent.run/2                          [spawn_agent.ex:12]
   ├─ Jido.start_agent(template)             [spawn_agent.ex:22]
   ├─ AgentTracker.register(id, pid)         [spawn_agent.ex:25]
   └─ spawn(fn →                             [spawn_agent.ex:28]  fire-and-forget
        template.ask_sync(pid, task)          nested ReAct loop in background
        AgentTracker.mark_complete(id)
      end)
   └─ return {:ok, %{agent_id, status: "spawned"}}   immediately

   LLM later calls get_agent_result(id) → Jido.Await.completion(pid) → blocks until done

7. RESPONSE
   ReAct loop finishes → poll receives {:ok, result}
   ├─ Formatter.print_answer(answer)         [repl.ex:164]  render to terminal
   ├─ Worker.add_message(:assistant, answer) [repl.ex:165]  persist to JSONL
   ├─ update_stats()                         [repl.ex:166]  token/message counters
   └─ loop(state)                            [repl.ex:137]  back to IO.gets()
```

### Timeouts & Terminal Conditions

| Boundary | Timeout | What Happens |
|----------|---------|--------------|
| Main agent ReAct loop | 25 iterations | Forced stop, returns last LLM text |
| Individual tool call | 30s | Killed by Jido.AI framework |
| Skill step (`ask_sync`) | 180s | Step fails, FSM transitions to `:failed` |
| DAG step (parallel) | 300s | Phase fails, workflow aborts |
| REPL poll cycle | 600ms | Re-polls, displays new tool calls |
| Session idle | 5 min | Worker hibernates, status → `:hibernated` |
| Forge session | Configurable | Manager tracks, cleanup on crash via DOWN monitor |
| Workflow approval gate | No timeout | Waits indefinitely for human approval |

## Development

```bash
mix deps.get          # Install dependencies
mix compile           # Compile
mix ash.setup         # Create database + run migrations
mix test              # Run tests
mix format            # Format code
iex -S mix            # IEx with app loaded
JIDOCLAW_MODE=both iex -S mix   # Dev with gateway + dashboard
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on pull requests, code style, and the development workflow.

---

## Built on Jido

JidoClaw is powered by the [Jido](https://github.com/agentjido/jido) autonomous agent framework for Elixir/OTP, created by [Mike Hostetler](https://github.com/agentjido). Jido (自動 — Japanese for "automatic/autonomous") provides the foundational agent runtime, action system, signal routing, and AI reasoning strategies that JidoClaw builds on top of.

The Jido ecosystem:

| Package | Purpose |
|---------|---------|
| [jido](https://github.com/agentjido/jido) | Core agent framework — immutable agents, `cmd/2`, directives, OTP runtime |
| [jido_ai](https://github.com/agentjido/jido_ai) | AI runtime — LLM orchestration, ReAct/CoT/ToT/Adaptive reasoning strategies |
| [jido_signal](https://github.com/agentjido/jido_signal) | CloudEvents-compliant event bus, routing, dispatching |
| [jido_action](https://github.com/agentjido/jido_action) | Structured, validated actions that auto-convert to LLM tool schemas via `to_tool()` |
| [jido_shell](https://github.com/agentjido/jido_shell) | Virtual workspace shell — VFS, sandboxed execution, streaming output |
| [jido_mcp](https://github.com/agentjido/jido_mcp) | Model Context Protocol server integration |
| [jido_memory](https://github.com/agentjido/jido_memory) | Persistent cross-session memory |
| [jido_vfs](https://github.com/agentjido/jido_vfs) | Virtual filesystem abstraction |
| [jido_skill](https://github.com/agentjido/jido_skill) | Multi-step skill definitions and orchestration |
| [jido_composer](https://github.com/agentjido/jido_composer) | Agent composition and workflow orchestration |
| [jido_messaging](https://github.com/agentjido/jido_messaging) | Inter-agent message routing |
| [jido_cluster](https://github.com/agentjido/jido_cluster) | Distributed BEAM clustering for multi-node agent systems |

Jido's design philosophy: agents are immutable data structures with a single command function (`cmd/2`). State changes are pure data transformations, side effects are described as directives executed by the OTP runtime. Inspired by Elm/Redux — predictable, testable, composable.

## License

MIT
