# JidoClaw System Architecture

## Overview

JidoClaw is an AI agent orchestration platform built on Elixir/OTP, the Jido framework, and Ash Framework 3.0. It provides a multi-interface, multi-tenant, multi-provider agent runtime with swarm orchestration, sandboxed code execution (Forge), persistent memory, DAG-based skill workflows, structured reasoning strategies, VFS-backed file operations, persistent shell sessions, database-backed accounts and projects, and full observability.

```
                    ┌─────────────────────────────────────────────┐
                    │              User Interfaces                 │
                    ├──────────┬──────────┬──────────┬────────────┤
                    │ CLI REPL │ REST API │ WebSocket│ Channels   │
                    │          │ (OpenAI) │   RPC    │ Discord/TG │
                    └────┬─────┴────┬─────┴────┬─────┴─────┬──────┘
                         │          │          │           │
                    ┌────▼──────────▼──────────▼───────────▼──────┐
                    │           JidoClaw.Agent (Main)              │
                    │   27 tools · ReAct loop · swarm spawn       │
                    ├─────────────────────────────────────────────┤
                    │       Reasoning Strategies (jido_ai)        │
                    │   ReAct · CoT · CoD · ToT · GoT · AoT ·    │
                    │   TRM · Adaptive                            │
                    ├─────────────────────────────────────────────┤
                    │           LLM Providers (req_llm)            │
                    │   Ollama · Anthropic · OpenAI · Google       │
                    │   Groq · xAI · OpenRouter                   │
                    ├─────────────────────────────────────────────┤
                    │           Infrastructure                     │
                    │   Ash · Forge · jido_shell · jido_vfs ·      │
                    │   jido_signal · Cloak Vault                  │
                    └─────────────────────────────────────────────┘
```

## Supervision Tree

```
JidoClaw.Supervisor (rest_for_one)
│
├── InfraSupervisor (one_for_one, nested)
│   ├── Registry (SessionRegistry)         — unique session lookup
│   ├── Registry (TenantRegistry)          — unique tenant lookup
│   ├── Task.Supervisor (TaskSupervisor)   — general async tasks
│   ├── JidoClaw.Repo                      — Ash/Ecto database connection
│   ├── JidoClaw.Security.Vault            — Cloak encryption vault
│   ├── Phoenix.PubSub (JidoClaw.PubSub)   — real-time event fanout
│   └── Jido.Signal.Bus (JidoClaw.SignalBus) — jido_claw.* event routing
│
├── Forge Engine (sandboxed execution)
│   ├── Registry (Forge.SessionRegistry)   — forge session lookup
│   ├── DynamicSupervisor (Forge.HarnessSupervisor) — harness processes
│   ├── DynamicSupervisor (Forge.ExecSessionSupervisor) — exec sessions
│   ├── JidoClaw.Forge.Manager             — forge lifecycle
│   └── Forge.SandboxInit OR Forge.Sandbox.Local — sandbox backend (conditional)
│
├── Orchestration
│   └── JidoClaw.Orchestration.RunSummaryFeed — workflow event streaming
│
├── Code Server
│   ├── Registry (CodeServer.RuntimeRegistry) — runtime lookup
│   └── DynamicSupervisor (CodeServer.RuntimeSupervisor) — runtime processes
│
├── Core Services
│   ├── Finch (JidoClaw.Finch)             — HTTP connection pools
│   ├── JidoClaw.Telemetry                 — 20+ metric definitions
│   ├── JidoClaw.Stats                     — session counters (GenServer)
│   ├── JidoClaw.BackgroundProcess.Registry — OS process tracking
│   ├── JidoClaw.Platform.Approval         — tool approval workflow
│   ├── DynamicSupervisor (SessionSupervisor) — global session fallback
│   ├── JidoClaw.Jido                      — Jido agent runtime
│   ├── JidoClaw.Messaging                 — room-based messaging runtime
│   │   ├── RoomSupervisor                 — per-room GenServers
│   │   ├── AgentSupervisor                — per-room agent runners
│   │   └── Registries (Rooms, Agents, Bridges)
│   ├── JidoClaw.Tenant.Supervisor         — per-tenant subtree factory
│   ├── JidoClaw.Tenant.Manager            — tenant lifecycle (GenServer)
│   ├── JidoClaw.Solutions.Store           — fingerprint-based caching
│   ├── JidoClaw.Solutions.Reputation      — solution trust scoring
│   ├── JidoClaw.Memory                    — ETS + JSON memory (GenServer)
│   ├── JidoClaw.Skills                    — cached YAML skill registry (GenServer)
│   ├── JidoClaw.Network.Supervisor        — agent-to-agent networking
│   ├── JidoClaw.AgentTracker              — per-agent stat accumulator
│   ├── JidoClaw.Display                   — terminal display coordinator
│   └── JidoClaw.Shell.SessionManager      — persistent shell sessions (jido_shell)
│
├── Web Gateway (conditional: mode in [:gateway, :both])
│   └── JidoClaw.Web.Endpoint             — Phoenix HTTP/WS/LiveView
│
├── Clustering (conditional: cluster_enabled = true)
│   ├── :pg (process groups)
│   └── Cluster.Supervisor (libcluster)
│
├── MCP Server (conditional: serve_mode = :mcp)
│   └── Jido.MCP.Server (stdio transport)
│
└── Discord (dynamic, started post-boot when DISCORD_BOT_TOKEN is set)
    ├── Nostrum (Discord gateway)
    └── JidoClaw.Channel.DiscordConsumer
```

## Data Layer

JidoClaw uses Ash Framework 3.0 with PostgreSQL (via `ash_postgres`) for persistent structured data. The database is separate from the ETS/JSON stores used for memory, solutions, and skills.

```
JidoClaw.Repo (AshPostgres.Repo)
│
├── JidoClaw.Accounts (Ash Domain)
│   ├── User                — AshAuthentication-managed users
│   ├── Token               — auth tokens (magic links, password resets)
│   └── ApiKey              — API key authentication for REST/WS
│
├── JidoClaw.Folio (Ash Domain)
│   ├── Project             — user projects (name, outcome, notes, status)
│   ├── Action              — actions within projects
│   └── InboxItem           — inbox system
│
├── JidoClaw.Security (Ash Domain)
│   └── SecretRef           — encrypted secret references (Cloak Vault)
│
├── JidoClaw.Orchestration (Ash Domain)
│   ├── WorkflowRun         — persistent workflow execution state
│   ├── WorkflowStep        — individual step within a run
│   └── ApprovalGate        — human-in-the-loop approval points
│
└── JidoClaw.Forge (Ash Domain)
    ├── Session             — forge execution sessions
    ├── ExecSession         — exec session tracking
    ├── Checkpoint          — execution checkpoints
    └── Event               — forge events
```

## Tool Architecture (27 tools)

```
JidoClaw.Agent
│
├── File I/O (4)          — ReadFile, WriteFile, EditFile, ListDirectory
│   └── VFS-backed: local paths use File.*, remote paths (github://, s3://, git://) use jido_vfs
│
├── Search (1)            — SearchCode (regex across codebase)
│
├── Shell (1)             — RunCommand
│   └── jido_shell-backed: persistent sessions, working dir + env vars persist between calls
│
├── Git (3)               — GitStatus, GitDiff, GitCommit
│
├── Project (1)           — ProjectInfo
│
├── Swarm (5)             — SpawnAgent, ListAgents, GetAgentResult, SendToAgent, KillAgent
│   └── Templates: coder, test_runner, reviewer, docs_writer, researcher, refactorer
│
├── Skills (1)            — RunSkill
│   └── DAG-aware: skills with depends_on use PlanWorkflow (parallel phases)
│   └── Sequential: skills without depends_on use SkillWorkflow (FSM-based)
│
├── Memory (2)            — Remember, Recall
│
├── Solutions (4)         — StoreSolution, FindSolution, NetworkShare, NetworkStatus
│
├── Reasoning (1)         — Reason
│   └── Strategies: react, cot, cod, tot, got, aot, trm, adaptive
│   └── Delegates to Jido.AI.Actions.Reasoning.RunStrategy
│
├── Scheduling (3)        — ScheduleTask, UnscheduleTask, ListScheduledTasks
│
└── Browser (1)           — BrowseWeb
```

## Reasoning Strategies

```
JidoClaw.Reasoning.StrategyRegistry
│
├── react    → Jido.AI.Reasoning.ReAct           — Reason + Act loop (native)
├── cot      → Jido.AI.Reasoning.ChainOfThought  — Step-by-step reasoning
├── cod      → Jido.AI.Reasoning.ChainOfDraft    — Concise reasoning, minimal tokens
├── tot      → Jido.AI.Reasoning.TreeOfThoughts  — Multi-branch exploration
├── got      → Jido.AI.Reasoning.GraphOfThoughts — Non-linear concept connections
├── aot      → Jido.AI.Reasoning.AlgorithmOfThoughts — Algorithmic search
├── trm      → Jido.AI.Reasoning.TRM             — Recursive decomposition
└── adaptive → Jido.AI.Reasoning.Adaptive         — Auto-selects best strategy

User controls via:
  /strategy <name>    — switch active strategy
  /strategies         — list all strategies
  reason tool         — invoke specific strategy per-call
```

## Forge Engine (Sandboxed Execution)

```
JidoClaw.Forge
│
├── Manager (GenServer)
│   ├── Harness lifecycle (create, start, stop, destroy)
│   ├── Session tracking via Forge.SessionRegistry
│   └── Coordinates with sandbox backend
│
├── Harness
│   ├── Execution context for sandboxed runs
│   ├── Resource provisioning (ContextBuilder, ResourceProvisioner)
│   └── Step-by-step execution (StepHandler)
│
├── Sandbox Backends
│   ├── Forge.Sandbox.Local    — local OS process isolation (default)
│   └── Forge.Sandbox.Docker   — Docker container isolation (optional)
│
├── Runners
│   ├── Shell       — shell command execution
│   ├── Workflow    — multi-step workflow execution
│   ├── ClaudeCode  — Claude Code subprocess
│   └── Custom      — user-defined runners
│
├── Resources (Ash-backed)
│   ├── Session      — forge session state
│   ├── ExecSession  — exec session tracking
│   ├── Checkpoint   — execution snapshots for resume
│   └── Event        — forge event log
│
├── Persistence      — checkpoint/resume across restarts
├── Bootstrap        — initial setup for forge environments
└── PubSub           — forge-specific event fanout
```

## Orchestration

```
JidoClaw.Orchestration
│
├── WorkflowRun (Ash Resource)
│   ├── Persistent state machine for multi-step workflows
│   └── Tracks: status, steps, results, timestamps
│
├── WorkflowStep (Ash Resource)
│   ├── Individual step within a workflow run
│   └── Tracks: step name, status, input, output
│
├── ApprovalGate (Ash Resource)
│   ├── Human-in-the-loop approval points
│   └── Blocks workflow execution until approved/rejected
│
├── RunPubSub
│   └── PubSub coordination for workflow state changes
│
└── RunSummaryFeed (GenServer, started in supervision tree)
    └── Streams workflow events for display/logging
```

## Security

```
JidoClaw.Security
│
├── Vault (Cloak.Vault)
│   ├── AES-GCM encryption for secrets at rest
│   └── Key derivation from environment
│
├── SecretRef (Ash Resource)
│   └── Encrypted reference to secrets stored in database
│
└── Redaction Pipeline
    ├── Patterns          — regex patterns for sensitive data (API keys, tokens, passwords)
    ├── LogRedactor       — strips secrets from log output
    ├── PromptRedaction   — strips secrets from LLM prompts
    ├── ChannelRedaction  — strips secrets from channel messages (Discord, etc.)
    └── UIRedaction       — strips secrets from terminal/LiveView display
```

## VFS Architecture

```
JidoClaw.VFS.Resolver (path routing)
│
├── Local paths        → File.read/write/ls (zero overhead)
│
├── github://owner[@ref]/repo/path
│   └── Jido.VFS.Adapter.GitHub (GITHUB_TOKEN env)
│
├── s3://bucket/key
│   └── Jido.VFS.Adapter.S3 (AWS credentials)
│
└── git://repo-path//file-path
    └── Jido.VFS.Adapter.Git (local git access)

Used by: ReadFile, WriteFile, ListDirectory tools
```

## Shell Session Architecture

```
JidoClaw.Shell.SessionManager (GenServer)
│
├── Manages sessions per workspace_id
│   └── workspace_id → session_id mapping
│
├── Session lifecycle
│   ├── Created on first run_command for a workspace
│   ├── Persists working directory between commands
│   ├── Persists environment variables between commands
│   ├── Auto-recreates dead sessions transparently
│   └── Destroyed via stop_session/1
│
├── Command execution
│   ├── Subscribe to session events
│   ├── Fire command via ShellSessionServer.run_command/2
│   ├── Collect {:output, chunk} messages until :command_done
│   ├── Truncate output at 10KB
│   └── Return {:ok, %{output: ..., exit_code: ...}}
│
└── Fallback: System.cmd when SessionManager is not running (tests, etc.)
```

## Skill Execution — DAG vs Sequential

```
Skills with depends_on annotations:
  PlanWorkflow (DAG)
  │
  ├── assign_step_names/1      — normalize YAML steps to named atoms
  ├── compute_phases/1         — topological sort (Kahn-style depth grouping)
  │   └── validate_deps/2      — verify all depends_on targets exist
  ├── execute_phases/3         — Enum.reduce_while over phases
  │   └── execute_phase/4      — Task.async_stream (parallel within phase)
  │       └── execute_step/4   — StepAction.run (spawn agent → ask → collect)
  │
  Example: full_review
    Phase 0: [run_tests, review_code]  ← parallel
    Phase 1: [synthesize]              ← depends on both

Skills without depends_on:
  SkillWorkflow (FSM)
  │
  └── Jido.Composer.Workflow.Machine
      step_1 → step_2 → ... → done (sequential)
```

## Data Flow

### CLI Message Flow

```
User Input
  │
  ▼
JidoClaw.Repl.loop/1
  │
  ├── Slash command? ──▶ JidoClaw.Commands.handle/2 ──▶ Response
  │     ├── /models [provider]   — list available LLM models
  │     ├── /strategy <name>     — switch reasoning strategy
  │     ├── /solutions search    — search solution store
  │     ├── /network             — agent network status
  │     └── ... (25+ commands)
  │
  └── Message ──▶ Session.Worker.add_message/4 (persist)
                 │
                 ▼
              JidoClaw.Agent.ask/3
                 │
                 ▼
              Jido.AI ReAct Loop
                 │
                 ├── LLM call (req_llm → provider)
                 │
                 ├── Tool call? ──▶ Execute Jido.Action
                 │   │               │
                 │   │               ├── read_file → VFS.Resolver (local or remote)
                 │   │               ├── run_command → Shell.SessionManager (persistent session)
                 │   │               ├── spawn_agent (creates OTP process)
                 │   │               ├── run_skill → PlanWorkflow (DAG) or SkillWorkflow (FSM)
                 │   │               ├── reason → RunStrategy (cot/tot/adaptive/...)
                 │   │               ├── schedule_task, unschedule_task, list_scheduled_tasks
                 │   │               └── remember, recall (persistent memory)
                 │   │
                 │   └── Feed result back to LLM ──▶ Loop
                 │
                 └── Final answer ──▶ Formatter.print_answer/1
                                      │
                                      ▼
                                   Terminal Output
```

### HTTP API Flow

```
HTTP Request
  │
  ▼
Phoenix.Router
  │
  ├── GET /health ──▶ HealthController ──▶ 200 OK
  │
  ├── POST /v1/chat/completions ──▶ ChatController (API key auth)
  │     ├── Find/create session
  │     ├── Route to JidoClaw.Agent
  │     ├── Stream or wait for response
  │     └── Return OpenAI-compatible JSON
  │
  ├── POST /webhooks/github ──▶ WebhookController (HMAC verified)
  │
  ├── /auth/* ──▶ AuthController (sign-in, sign-out)
  │
  ├── LiveView (authenticated)
  │   ├── /              — DashboardLive
  │   ├── /dashboard     — DashboardLive
  │   ├── /forge         — ForgeLive
  │   ├── /workflows     — WorkflowsLive
  │   ├── /agents        — AgentsLive
  │   ├── /projects      — ProjectsLive
  │   ├── /settings      — SettingsLive
  │   └── /folio         — FolioLive
  │
  ├── LiveView (public)
  │   ├── /sign-in       — SignInLive
  │   └── /setup         — SetupLive
  │
  ├── /admin ──▶ AshAdmin (requires auth)
  │
  └── /live-dashboard ──▶ Phoenix LiveDashboard (dev only)
```

### Swarm Flow

```
User: "Review and refactor the auth module"
  │
  ▼
Main Agent (JidoClaw.Agent)
  │
  ├── LLM decides: "I need a reviewer and a refactorer"
  │
  ├── spawn_agent(template: "reviewer", task: "Review auth module")
  │   └── Creates OTP process: WorkerReviewer (pid1)
  │       ├── Tools: read_file, git_diff, search_code
  │       └── Runs independently (PARALLEL with pid2)
  │
  ├── spawn_agent(template: "refactorer", task: "Refactor auth module")
  │   └── Creates OTP process: WorkerRefactorer (pid2)
  │       ├── Tools: read_file, write_file, edit_file, run_command...
  │       └── Runs independently (PARALLEL with pid1)
  │
  ├── get_agent_result(pid1) → Review findings
  ├── get_agent_result(pid2) → Refactoring result
  │
  └── Synthesize results → Final answer to user
```

## Solutions Engine

```
JidoClaw.Solutions
│
├── Solution struct
│   ├── id, problem_signature, solution_content, language, framework
│   ├── tags, verification, trust_score (0.0-1.0), sharing (:local/:shared/:public)
│   └── inserted_at, updated_at
│
├── Fingerprint (pure functional)
│   ├── SHA-256 signature from normalized(description + language + framework)
│   ├── Domain extraction (web, database, api, cli, devops, testing)
│   ├── Target extraction (auth, routing, deployment, caching, ...)
│   ├── Search term tokenization (stopword removal, Jaccard similarity)
│   └── match_score/2: weighted combination (domain 0.20, target 0.15, error_class 0.10,
│       ecosystem 0.25, search_terms 0.30)
│
├── Store (GenServer + ETS + JSON)
│   ├── store_solution/1, find_by_id/1, find_by_signature/1
│   ├── search/2 (BM25-inspired relevance scoring)
│   ├── update_trust/2, delete/1, stats/0
│   └── Persistence: .jido/solutions.json
│
├── Matcher
│   ├── Combines Fingerprint.match_score (0.6) + trust_score (0.4)
│   └── Returns ranked results with match type (:exact, :similar, :partial)
│
├── Trust (pure functional)
│   ├── 4-component weighted: verification 35%, completeness 25%, freshness 25%, reputation 15%
│   └── Handles both atom and string-keyed maps
│
└── Reputation (GenServer + ETS + JSON)
    ├── Per-agent reputation tracking
    ├── Records: accepted, rejected, shared solutions
    └── Persistence: .jido/reputation.json (created on first use)
```

## Network Architecture

```
JidoClaw.Network
│
├── Node (GenServer)
│   ├── Ed25519 identity (JidoClaw.Agent.Identity)
│   ├── PubSub-based peer communication (topic: "jido:network")
│   ├── Peer tracking (list of agent_id strings)
│   └── Solution broadcasting
│
├── Protocol (pure functional)
│   ├── Message types: share, request, response, ping, pong
│   ├── Ed25519 signing: JSON-encode payload → sign → base64
│   ├── Verification: re-encode payload → verify signature
│   └── Convenience: share_message, request_message, response_message
│
└── Identity (Ed25519)
    ├── generate_keypair/0 → {public_key, private_key}
    ├── sign/2, verify/3, sign_solution/2, verify_solution/3
    ├── derive_agent_id/1 → "jido_" <> first_7_base64_chars
    └── Persistence: .jido/identity.json (0o600 perms, created on first use)
```

## GitHub Integration

```
JidoClaw.GitHub
│
├── WebhookPipeline       — processes incoming GitHub webhook events
├── WebhookSignature      — HMAC signature verification
├── IssueAnalysis         — AI-powered issue analysis
├── IssueCommentClient    — posts analysis results back to GitHub
└── Agents/               — specialized agents for GitHub tasks
```

## Provider Architecture

```
JidoClaw.Config
  │
  ├── .jido/config.yaml (user config)
  │   └── provider: "ollama" | "anthropic" | "openai" | ...
  │
  ├── @providers map (defaults per provider)
  │   └── base_url, api_key_env, default_model
  │
  ├── Model catalog
  │   ├── default_models_for_provider/1 — curated model lists per provider
  │   ├── model_description/1 — short descriptions (context window, notes)
  │   └── Default: ollama:nemotron-3-super:cloud (120B MoE, 256K ctx)
  │
  ├── Strategy support
  │   ├── strategy/1 accessor (default: "react")
  │   └── strategy_descriptions/0
  │
  └── Provider connectivity check
       ├── ollama: GET {base_url}/api/tags
       ├── anthropic, openai, google, groq, xai, openrouter: API key validation
       └── Returns :ok | {:error, :unauthorized} | {:error, :unreachable}
```

## Configuration Cascade

```
1. config/config.exs                    (compile-time defaults)
   ├── LLMDB model catalog
   ├── Model aliases (:fast, :capable, :thinking)
   ├── LLM defaults (temperature, max_tokens, timeout)
   └── Platform config (mode, port, clustering)

2. .jido/config.yaml                    (user overrides, runtime)
   ├── provider, model, strategy
   ├── max_iterations, timeout
   └── provider-specific settings

3. .env / Environment variables         (secrets, runtime)
   ├── OLLAMA_API_KEY, ANTHROPIC_API_KEY, etc.
   ├── GITHUB_TOKEN (for VFS github:// paths)
   ├── AWS_REGION (for VFS s3:// paths)
   ├── DISCORD_BOT_TOKEN
   └── CANOPY_WORKSPACE_URL

4. Application.put_env at boot          (dynamic)
   └── model_aliases overridden from config.yaml
```

## CLI Commands (25+)

| Command | Purpose |
|---------|---------|
| `/help` | Show all commands |
| `/quit` `/exit` | Exit with session stats |
| `/clear` | Clear terminal |
| `/status` | Session info (model, provider, uptime, stats) |
| `/model <m>` | Switch LLM model |
| `/models [provider]` | List available models for a provider |
| `/strategy <name>` | Switch reasoning strategy |
| `/strategies` | List all reasoning strategies |
| `/agents` | Show running swarm agents |
| `/skills` | List available skills |
| `/memory` | List persistent memories |
| `/memory search <q>` | Search memories |
| `/memory save <k> <v>` | Save a memory |
| `/memory forget <k>` | Delete a memory |
| `/solutions` | Solution store stats |
| `/solutions search <q>` | Search stored solutions |
| `/network` | Network status |
| `/network connect` | Connect to peer network |
| `/network disconnect` | Disconnect from network |
| `/network peers` | List connected peers |
| `/setup` `/config` | Configuration wizard |
| `/gateway` | Gateway status |
| `/tenants` | List tenants |
| `/cron` | List cron jobs |
| `/cron add` | Add a cron job |
| `/cron remove` | Remove a cron job |
| `/cron trigger` | Manually trigger a job |
| `/cron disable` | Disable a job |
| `/channels` | List channel adapters |

## Events

JidoClaw uses two distinct event systems. Do not conflate them.

### Jido Signals (via SignalBus.emit)

Routed through `Jido.Signal.Bus` (JidoClaw.SignalBus). Subscribers receive events in-process. Used for internal coordination between subsystems.

| Signal | Emitted By | Purpose |
|--------|-----------|---------|
| `jido_claw.tool.complete` | Stats | Tool execution finished |
| `jido_claw.agent.spawned` | Stats | Child agent created |
| `jido_claw.memory.saved` | Memory | Memory entry persisted |
| `jido_claw.solution.stored` | Solutions.Store | Solution cached |
| `jido_claw.solution.deleted` | Solutions.Store | Solution removed |
| `jido_claw.reputation.updated` | Solutions.Reputation | Agent reputation changed |
| `jido_claw.network.connected` | Network.Node | Joined peer network |
| `jido_claw.network.disconnected` | Network.Node | Left peer network |
| `jido_claw.network.solution_shared` | Network.Node | Solution broadcast to peers |

### Telemetry Metrics (via :telemetry.execute)

Standard Erlang telemetry for metrics, dashboards, and observability. Consumed by `JidoClaw.Telemetry` metric definitions and Phoenix LiveDashboard.

| Event | Purpose |
|-------|---------|
| `[:jido_claw, :session, :start]` | Session created |
| `[:jido_claw, :session, :stop]` | Session ended (with duration) |
| `[:jido_claw, :session, :message]` | Message sent in session |
| `[:jido_claw, :provider, :request, :start]` | LLM request started |
| `[:jido_claw, :provider, :request, :stop]` | LLM request completed (with duration) |
| `[:jido_claw, :provider, :request, :error]` | LLM request failed |
| `[:jido_claw, :tool, :execute, :start]` | Tool execution started |
| `[:jido_claw, :tool, :execute, :stop]` | Tool execution completed (with duration) |
| `[:jido_claw, :tool, :execute, :error]` | Tool execution failed |
| `[:jido_claw, :cron, :job, :start]` | Cron job started |
| `[:jido_claw, :cron, :job, :stop]` | Cron job completed (with duration) |
| `[:jido_claw, :cron, :job, :error]` | Cron job failed |
| `[:jido_claw, :tenant, :create]` | Tenant created |
| `[:jido_claw, :tenant, :destroy]` | Tenant destroyed |
| `[:jido_claw, :tenant, :count]` | Tenant count gauge |
| `[:jido_claw, :channel, :message, :inbound]` | Channel message received |
| `[:jido_claw, :channel, :message, :outbound]` | Channel message sent |

## Display System

```
JidoClaw.Display (GenServer)
│
├── Mode: :single
│   ├── Kaomoji spinner (150ms tick)
│   ├── Tool call/result lines (⟳ / ✓)
│   └── Rich previews (diffs, file info, exit codes)
│
└── Mode: :swarm (activates on first spawn_agent)
    ├── Swarm box header (agent count, running/done, tokens)
    ├── Per-agent status lines (● running / ✓ done / ✗ error)
    └── Agent tree with tool tracking

JidoClaw.AgentTracker (GenServer)
│
├── Per-agent state: tokens, tool_calls, tool_names, status, started_at
├── Process monitoring: {:DOWN} → marks agent as :error
├── SignalBus subscriber: jido_claw.tool.*, jido_claw.agent.*
└── Notifies Display on state changes
```

## Multi-Tenancy Model

```
JidoClaw.Tenant.Supervisor
  │
  ├── Tenant "default" (auto-created at boot)
  │   ├── SessionSupervisor → Session.Worker(session_1), Session.Worker(session_2)
  │   ├── ChannelSupervisor → Channel.Worker(discord), Channel.Worker(telegram)
  │   ├── CronSupervisor → Cron.Worker(job_1), Cron.Worker(job_2)
  │   └── ToolSupervisor → Task.Supervisor for tool execution
  │
  ├── Tenant "acme" → isolated subtree
  └── Tenant "bigcorp" → isolated subtree
```

Each tenant has its own isolated supervision subtree. A crash in one tenant does not affect others.

## `.jido/` Directory

```
.jido/
├── JIDO.md              # Self-knowledge (auto-generated, injected into system prompt)
├── config.yaml          # User config (provider, model, strategy, timeouts) [gitignored]
├── system_prompt.md     # Rendered system prompt snapshot
├── heartbeat.md         # Agent heartbeat state [gitignored]
├── memory.json          # Persistent memory [gitignored]
├── solutions.json       # Solution fingerprint cache [gitignored]
├── cron.yaml            # Cron job definitions [gitignored]
├── identity.json        # Ed25519 keypair, 0o600 perms (created on first network use)
├── reputation.json      # Agent reputation data (created on first use)
├── sessions/            # JSONL session logs [gitignored]
├── agents/              # Custom agent definitions (YAML, committed)
│   ├── api_designer.yaml
│   ├── architect.yaml
│   ├── bug_hunter.yaml
│   ├── onboarder.yaml
│   ├── performance_analyst.yaml
│   └── security_auditor.yaml
├── skills/              # Multi-step workflows (YAML, supports DAG depends_on, committed)
│   ├── full_review.yaml
│   ├── refactor_safe.yaml
│   ├── explore_codebase.yaml
│   ├── security_audit.yaml
│   ├── implement_feature.yaml
│   ├── iterative_feature.yaml
│   ├── debug_issue.yaml
│   └── onboard_dev.yaml
└── .gitignore
```

## Boot Sequence

```
1. Application.start
   ├── Load .env file (if present — project root or .jido/.env)
   ├── Record boot time for uptime tracking
   ├── Register Ollama provider in ReqLLM
   └── Start supervision tree (rest_for_one):
       ├── InfraSupervisor (Registries, TaskSupervisor, Repo, Vault, PubSub, SignalBus)
       ├── Forge engine (SessionRegistry, HarnessSupervisor, ExecSessionSupervisor, Manager, Sandbox)
       ├── Orchestration (RunSummaryFeed)
       ├── Code Server (RuntimeRegistry, RuntimeSupervisor)
       ├── Finch HTTP pools
       ├── Core services (Telemetry, Stats, Approval, Jido, Shell.SessionManager, etc.)
       ├── Messaging runtime (JidoClaw.Messaging)
       ├── Tenancy (Supervisor + Manager → creates "default" tenant)
       ├── Solutions engine (Store + Reputation)
       ├── Memory GenServer (loads .jido/memory.json into ETS)
       ├── Skills GenServer (parses .jido/skills/*.yaml, caches in state)
       ├── Network supervisor
       ├── AgentTracker + Display
       └── Discord (dynamic post-boot if DISCORD_BOT_TOKEN is set)

2. Repl.start (CLI mode)
   ├── Check Setup.needed? → run wizard if first time
   ├── Config.load (merge defaults + .jido/config.yaml)
   ├── Override :jido_ai model_aliases
   ├── Branding.boot_sequence (ASCII art, system info, strategy)
   ├── JidoMd.ensure (generate .jido/JIDO.md if missing)
   ├── Skills.ensure_defaults (copy built-in skills with DAG annotations)
   ├── Config.check_provider (connectivity test)
   ├── Start main Agent (JidoClaw.Jido.start_agent)
   ├── Inject system prompt (Prompt.build — includes reasoning strategy context)
   ├── Create Session.Worker
   ├── Bind agent to session
   └── Enter REPL loop

3. Web.Endpoint (gateway mode)
   └── Phoenix starts on configured port (default: 4000)
       ├── LiveView routes (dashboard, forge, workflows, agents, projects, settings, folio)
       ├── API routes (health, chat completions, webhooks)
       ├── Auth routes (sign-in, sign-out)
       ├── AshAdmin panel (/admin)
       └── LiveDashboard (/live-dashboard, dev only)
```

## Module Namespace Convention

`JidoClaw.<Subsystem>.<Module>` — key subsystems:

| Directory        | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `accounts/`      | Ash domain: User, Token, ApiKey (AshAuthentication)  |
| `agent/`         | Main agent, prompt builder, templates, workers       |
| `cli/`           | REPL, commands, branding, setup, formatter           |
| `code_server/`   | Runtime management for code execution                |
| `core/`          | SignalBus, Stats, Telemetry                          |
| `desktop/`       | Desktop sidecar (port finder)                        |
| `display/`       | Terminal display coordinator                         |
| `folio/`         | Ash domain: Project, Action, InboxItem               |
| `forge/`         | Sandboxed execution (runners, sandbox backends)      |
| `github/`        | Webhook pipeline, issue analysis, comment client     |
| `network/`       | Agent-to-agent networking (Ed25519, PubSub peers)    |
| `orchestration/` | Persistent workflow state machine (Ash-backed)       |
| `platform/`      | Session, Tenant, Channel, Cron, BackgroundProcess    |
| `projects/`      | Project context                                      |
| `providers/`     | Custom LLM provider implementations (Ollama)         |
| `reasoning/`     | Strategy registry (maps names to jido_ai modules)    |
| `security/`      | Cloak Vault, SecretRef, redaction pipeline            |
| `setup/`         | First-run setup wizard                               |
| `shell/`         | Persistent shell session manager (jido_shell)        |
| `solutions/`     | Solution fingerprinting, trust scoring, reputation   |
| `tools/`         | All 27 Jido.Action tool modules                      |
| `vfs/`           | VFS path resolver (GitHub, S3, Git, local)           |
| `web/`           | Phoenix endpoint, controllers, LiveView, auth        |
| `workflows/`     | Workflow execution (plan, skill, iterative, context)  |

## Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Runtime | Elixir 1.17+ / OTP 27+ | BEAM VM, lightweight processes, fault tolerance |
| Agent framework | Jido 2.1+ | Agent lifecycle, actions, signals, composition |
| AI runtime | jido_ai 2.0+ | LLM orchestration, 8 reasoning strategies |
| LLM abstraction | req_llm 1.6+ | Multi-provider support (7 providers) |
| Data framework | Ash 3.0+ | Declarative resources, domains, authentication |
| Database | PostgreSQL + ash_postgres | Persistent structured data |
| Auth | ash_authentication | Token-based auth, magic links, password resets |
| Encryption | Cloak + bcrypt_elixir | At-rest encryption, password hashing |
| Shell runtime | jido_shell | Persistent shell sessions, command chaining |
| Filesystem | jido_vfs | VFS abstraction (GitHub, S3, Git, local) |
| HTTP server | Phoenix 1.7+ / Bandit | REST API, WebSocket, LiveView, LiveDashboard |
| LiveView | phoenix_live_view 1.0+ | Real-time web UI (9 LiveView modules) |
| Admin | ash_admin | Auto-generated admin panel |
| PubSub | Phoenix.PubSub | Real-time event fanout |
| HTTP client | Finch | Connection pooling for LLM API calls |
| Configuration | yaml_elixir | YAML parsing for .jido/ configs |
| Serialization | Jason | JSON encoding/decoding |
| Scheduling | crontab | Cron expression parsing |
| Clustering | libcluster | Multi-node discovery |
| Discord | Nostrum (optional) | Discord bot adapter |
| Telemetry | telemetry + telemetry_metrics | Observability instrumentation |
| Display | AgentTracker + Display GenServers | Per-agent stats, swarm visualization |
| Messaging | jido_messaging | Room-based messaging, agent bridges |
| Workflows | jido_composer 0.3+ | FSM-based skill orchestration |
| Browser | jido_browser 2.0+ | Headless browser automation |
| Graphs | libgraph (custom fork) | DAG computation for skill phases |

## Jido Ecosystem Dependencies

| Dependency | Version | Role in JidoClaw |
|-----------|---------|-----------------|
| **jido** | ~> 2.1 | Core agent runtime, DynamicSupervisor, agent lifecycle |
| **jido_ai** | ~> 2.0 | LLM orchestration, 8 reasoning strategies, `ask_sync` |
| **jido_action** | ~> 2.0 | All 27 tools are `Jido.Action` modules |
| **jido_signal** | ~> 2.0 | Event bus for `jido_claw.*` signals |
| **jido_shell** | main | Persistent shell sessions for RunCommand tool |
| **jido_vfs** | main | VFS abstraction for file tools (GitHub, S3, Git) |
| **jido_memory** | main | ETS store backend for persistent memory |
| **jido_mcp** | main | MCP server for Claude Code / Cursor integration |
| **jido_browser** | ~> 2.0 | `browse_web` tool |
| **jido_composer** | ~> 0.3 | Workflow FSM for sequential skill orchestration |
| **jido_messaging** | main | Room-based messaging runtime |
| **jido_skill** | main | Skill metadata discoverability |
