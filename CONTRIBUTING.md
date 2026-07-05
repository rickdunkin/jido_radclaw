# Contributing to JidoClaw

JidoClaw is built on the [Jido](https://github.com/agentjido/jido) framework ecosystem for Elixir/OTP. Contributions are welcome — bug fixes, new tools, provider integrations, channel adapters, skills, and documentation improvements.

## Prerequisites

- Elixir >= 1.17
- Erlang/OTP >= 27
- Git
- Ollama (recommended for local development — `brew install ollama && ollama serve`)

## Getting Started

```bash
git clone https://github.com/agentjido/jido_claw.git
cd jido_claw
mix deps.get
mix compile
mix test
mix jidoclaw   # runs the REPL (triggers setup wizard on first run)
```

## Development Workflow

1. Branch from `main`: `git checkout -b feat/your-feature`
2. Write tests first (TDD encouraged)
3. Run `mix format` before every commit
4. Keep commits atomic with descriptive messages (`feat:`, `fix:`, `refactor:`, `docs:`)
5. Open a PR against `main` with a clear description of what and why

```bash
mix test                                # full suite
mix test test/jido_claw/foo_test.exs    # single file
mix test --failed                       # re-run failures
mix format                              # format all files
mix format --check-formatted            # CI check
mix compile --warnings-as-errors        # strict compile
```

## Code Style

- Formatting: `mix format` — enforced, no exceptions
- Module namespace: `JidoClaw.<Subsystem>.<Module>`
- Signal strings: `jido_claw.<subsystem>.<event>` (never `jido_cli`)
- All public modules must have `@moduledoc`
- All public functions must have `@doc`
- Prefer pattern matching over conditionals
- Use `GenServer` for stateful processes; avoid raw process primitives

```elixir
# Good
def handle_message(%{type: :text, body: body}, state), do: ...
def handle_message(%{type: :image, url: url}, state), do: ...

# Avoid
def handle_message(msg, state) do
  if msg.type == :text do ... else ... end
end
```

## Architecture

JidoClaw follows an OTP supervision tree pattern. See the README for the full architecture diagram.

### Key Modules

| Module | Responsibility |
|--------|---------------|
| `JidoClaw.Application` | OTP entry point, supervision tree, .env loading |
| `JidoClaw.Agent` | Main AI agent — 35 tools, swarm orchestration |
| `JidoClaw.CLI.Repl` | Interactive CLI loop — setup, boot, input/output |
| `JidoClaw.Config` | Multi-provider config from `.jido/config.yaml` (`core/config.ex`) |
| `JidoClaw.CLI.Setup` | First-time setup wizard (provider, model, API key) |
| `JidoClaw.Session.Worker` | Per-session GenServer with JSONL persistence |
| `JidoClaw.Tenant.Manager` | Multi-tenant lifecycle management |
| `JidoClaw.Skills` | YAML-based multi-step skill orchestration |
| `JidoClaw.Agent.Templates` | Agent template registry (16 built-in) |
| `JidoClaw.CLI.Branding` | ASCII art, boot sequence, spinners, help text |
| `JidoClaw.CLI.Formatter` | Output formatting, diff rendering, tool display |
| `JidoClaw.JidoMd` | Auto-generates `.jido/JIDO.md` self-knowledge |
| `JidoClaw.SignalBus` | Internal event routing (`jido_claw.*` namespace) |
| `JidoClaw.AgentTracker` | Per-agent stat accumulation, process monitoring, SignalBus subscriber |
| `JidoClaw.Display` | Terminal display coordinator — spinner, tool calls, swarm box, status bar |
| `JidoClaw.Display.StatusBar` | Width-adaptive status bar renderer (pure functions) |
| `JidoClaw.Display.SwarmBox` | Swarm tree box renderer with per-agent lines (pure functions) |
| `JidoClaw.Web.Endpoint` | Phoenix HTTP/WS gateway |

### Jido Framework Integration

JidoClaw uses the full Jido ecosystem:

| Package | How JidoClaw Uses It |
|---------|---------------------|
| `jido` | Agent lifecycle, OTP runtime, `cmd/2` pattern |
| `jido_ai` | LLM orchestration, ReAct tool-calling loop, model aliases |
| `jido_action` | All 35 registered tools are `Jido.Action` modules with schema validation |
| `jido_signal` | Signal bus for internal events (`jido_claw.tool.complete`, etc.) |
| `jido_mcp` | MCP server protocol for external tool integration |
| `jido_shell` | Sandboxed shell execution for `run_command` tool |
| `jido_vfs` | Virtual filesystem abstraction |
| `jido_skill` | Skill definition primitives |
| `jido_composer` | Agent composition patterns |
| `jido_messaging` | Inter-agent message routing |
| `req_llm` | Provider abstraction — Ollama, Anthropic, OpenAI, Google, Groq, xAI |

### `.jido/` Directory

The `.jido/` directory is the project-level configuration that ships with the repo (except git-ignored items):

```
.jido/
├── JIDO.md              # Self-knowledge (committed; guarded by mix jidoclaw.jido_md.check)
├── config.yaml          # Provider, model, timeouts (git-ignored)
├── agents/              # Custom agent definitions (YAML, committed)
├── skills/              # Multi-step skill workflows (YAML, committed)
└── sessions/            # Session logs (git-ignored)
```

Persistent memory and solutions live in Postgres (Ash domains), not in
`.jido/` JSON files.

## Extension Points

### Adding a Tool

1. Create `lib/jido_claw/tools/your_tool.ex`
2. Use `Jido.Action` with a schema:

```elixir
defmodule JidoClaw.Tools.YourTool do
  use Jido.Action,
    name: "your_tool",
    description: "What this tool does",
    schema: [
      param: [type: :string, required: true, doc: "Description"]
    ]

  def run(%{param: value}, _context) do
    {:ok, %{result: value}}
  end
end
```

3. Add to the tools list in `lib/jido_claw/agent/agent.ex`
4. Add a test in `test/jido_claw/tools/your_tool_test.exs`

### Adding an Agent Template

1. Create `lib/jido_claw/agent/workers/your_role.ex`:

```elixir
defmodule JidoClaw.Agent.Workers.YourRole do
  use JidoClaw.Agent.Defaults,
    name: "your_role",
    description: "What this agent specializes in",
    model: :fast,
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode
      # ... only the tools this role needs
    ]
end
```

2. Register in `lib/jido_claw/agent/templates.ex`
3. Regenerate or hand-update the committed `.jido/JIDO.md` — its template
   sections are derived from the registry, and `mix jidoclaw.jido_md.check`
   (part of `mix precommit`) fails until the committed file matches

### Adding a Slash Command

1. Add a `handle/2` clause in `lib/jido_claw/cli/commands.ex`:

```elixir
def handle("/your_command", state) do
  # Do the thing
  {:ok, state}
end
```

2. Update the help text in `lib/jido_claw/cli/branding.ex`

### Adding an LLM Provider

1. Add provider config to `@providers` map in `lib/jido_claw/core/config.ex`
2. Add to `available_providers/0` and `default_models_for_provider/1`
3. Add model descriptions to `@model_descriptions`
4. Add connectivity check in `check_provider/1`
5. Add API key mapping in `lib/jido_claw/cli/setup.ex` (`api_key_env_for/1`)
6. Register models in `config/config.exs` LLMDB catalog
7. Update `.env.example`

### Adding a Channel Adapter

1. Create `lib/jido_claw/platform/channel/your_adapter.ex`
2. Implement `JidoClaw.Channel.Behaviour` — five callbacks:

```elixir
defmodule JidoClaw.Channel.YourAdapter do
  @behaviour JidoClaw.Channel.Behaviour

  @impl true
  def init(config), do: ...
  def send_message(session_id, message, state), do: ...
  def receive_message(raw, state), do: ...
  def format_response(response, state), do: ...
  def terminate(reason, state), do: ...
end
```

### Adding a Skill

Create `.jido/skills/your_skill.yaml`:

```yaml
name: your_skill
description: What this skill does
steps:
  - template: researcher
    task: "Research phase — describe what to investigate"
  - template: coder
    task: "Implementation phase — describe what to build"
  - template: test_runner
    task: "Verification phase — describe what to test"
synthesis: "Summarize what was done and any remaining issues"
```

To include it as a built-in default, add the YAML content to `@default_skills` in `lib/jido_claw/platform/skills.ex` (and update the committed `.jido/JIDO.md` skills list — `mix jidoclaw.jido_md.check` guards it).

### Customizing the Display

The display system uses pure renderer modules for layout. To add a new display element:

1. Create a pure module in `lib/jido_claw/display/` with render functions that return ANSI strings
2. Call the renderer from `JidoClaw.Display` GenServer in the appropriate `handle_cast` or `handle_info`
3. New tool result previews go in `render_tool_result_preview/2` in `display.ex`

Key files:
- `lib/jido_claw/display.ex` — GenServer coordinator
- `lib/jido_claw/display/status_bar.ex` — status bar layout
- `lib/jido_claw/display/swarm_box.ex` — swarm tree layout
- `lib/jido_claw/agent_tracker.ex` — per-agent state

### Adding a Custom Agent

Create `.jido/agents/your_agent.yaml`:

```yaml
name: your_agent
description: What this agent specializes in
template: reviewer    # base template (coder, reviewer, researcher, etc.)
model: :capable
max_iterations: 20
system_prompt: |
  You are a [role]. Focus on:
  - Specific task 1
  - Specific task 2
  Report findings with severity and file:line references.
tools:
  - read_file
  - search_code
```

## Testing

- Test files live in `test/jido_claw/`
- Test module names mirror source: `JidoClaw.Foo` -> `JidoClaw.FooTest`
- Cover happy path, error path, and edge cases
- Use ExUnit assertions (`assert`, `refute`, `assert_receive`, etc.)

```bash
mix test                                # full suite
mix test test/jido_claw/foo_test.exs    # single file
mix test --failed                       # re-run failures only
```

## Deployment

### As an Escript (standalone binary)

```bash
mix escript.build
./jidoclaw
```

### As a Docker Container

```dockerfile
FROM elixir:1.17-alpine
WORKDIR /app
COPY . .
RUN mix deps.get && mix compile
CMD ["mix", "jidoclaw"]
```

### Inside Canopy

JidoClaw runs as the agent runtime inside [Canopy](https://github.com/Miosa-osa/canopy) workspaces. Set `CANOPY_WORKSPACE_URL` and `CANOPY_API_KEY` to connect.

## Code of Conduct

Be respectful and constructive. Critique code, not people. This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
