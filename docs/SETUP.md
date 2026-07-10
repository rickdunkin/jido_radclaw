# JidoClaw Setup Guide

## Prerequisites

- **Elixir** 1.17+ (`elixir --version`)
- **Erlang/OTP** 27+ (`erl -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'`)
- **Git** (for `git_status`, `git_diff`, `git_commit` tools)
- An LLM provider (Ollama local, Ollama Cloud, Anthropic, OpenAI, Google, Groq, xAI, or OpenRouter)

### Installing Elixir

**macOS:**
```bash
brew install elixir
```

**Linux (Ubuntu/Debian):**
```bash
# Via asdf (recommended)
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.0
asdf install elixir 1.17.3-otp-27
asdf global erlang 27.0
asdf global elixir 1.17.3-otp-27
```

**Or use the installer script** which handles dependencies automatically:
```bash
curl -fsSL https://raw.githubusercontent.com/robertohluna/jido_claw/main/install.sh | bash
```

## Installation

### Option 1: Installer Script (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/robertohluna/jido_claw/main/install.sh | bash
```

This compiles JidoClaw as an escript and places it in your PATH.

### Option 2: From Source

```bash
git clone https://github.com/robertohluna/jido_claw.git
cd jido_claw
mix deps.get
mix compile
```

Run directly:
```bash
mix jidoclaw
```

Or build the escript:
```bash
mix escript.build
./jidoclaw
```

## First Run

On first launch, JidoClaw runs a setup wizard:

```
? Select your LLM provider:
  1. Ollama (local)
  2. Ollama Cloud
  3. Anthropic
  4. OpenAI
  5. Google
  6. Groq
  7. xAI
  8. OpenRouter

? Enter your API key (if required):
? Select a model:
```

This creates `.jido/config.yaml` in your project directory with your choices.

## LLM Provider Setup

### Ollama (Local) -- No API Key

Install Ollama from [ollama.com](https://ollama.com), then pull a model:

```bash
ollama pull nemotron-3-super
ollama serve  # if not already running
```

JidoClaw connects to `http://localhost:11434` by default.

### Ollama Cloud

Set your API key:
```bash
export OLLAMA_API_KEY=your-key-here
```

Or add to `.env` in your project root (copy from `.env.example`):
```bash
cp .env.example .env
# Edit .env and set OLLAMA_API_KEY
```

Default model: `nemotron-3-super:cloud` (120B MoE, 256K context)

### Anthropic

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### OpenAI

```bash
export OPENAI_API_KEY=sk-...
```

### Google

```bash
export GOOGLE_API_KEY=...
```

### Groq / xAI / OpenRouter

```bash
export GROQ_API_KEY=gsk_...
export XAI_API_KEY=xai-...
export OPENROUTER_API_KEY=sk-or-...
```

## Configuration

### `.jido/config.yaml`

Created by the setup wizard. You can edit directly or run `/setup` in the REPL:

```yaml
max_iterations: 25
model: "ollama:nemotron-3-super:cloud"
provider: ollama
timeout: 120000
```

| Key | Default | Description |
|-----|---------|-------------|
| `provider` | `ollama` | LLM provider |
| `model` | `ollama:nemotron-3-super:cloud` | Provider:model string |
| `max_iterations` | `25` | Max agent reasoning steps per task |
| `timeout` | `120000` | Task timeout in ms |

### `.jido/` Directory

JidoClaw creates a `.jido/` directory in your project root:

```
.jido/
├── config.yaml          # Your config (gitignored)
├── JIDO.md              # Self-knowledge document (auto-generated)
├── system_prompt.md     # Agent system prompt
├── memory.json          # Legacy v0.5 memory export (gitignored) — live memory is in Postgres
├── agents/              # Custom agent definitions (YAML)
│   ├── security_auditor.yaml
│   ├── architect.yaml
│   └── ...
├── skills/              # Custom skill workflows (YAML)
│   ├── full_review.yaml
│   ├── implement_feature.yaml
│   └── ...
├── sessions/            # Session history (gitignored)
├── cron.yaml            # Persistent scheduled jobs (gitignored)
├── heartbeat.md         # Agent heartbeat status (gitignored)
└── solutions.json       # Solution cache (gitignored)
```

Files that are safe to commit: `JIDO.md`, `system_prompt.md`, `agents/`, `skills/`, `.gitignore`

Files gitignored (per-user/runtime): `config.yaml`, `memory.json`, `sessions/`, `cron.yaml`, `heartbeat.md`, `solutions.json`

## Running Modes

### REPL + HTTP Gateway (default)

```bash
mix jidoclaw
# or
./jidoclaw
```

Starts the interactive REPL, plus Phoenix on port 4000 with:
- The app dashboard at `/dashboard` (LiveView)
- REST API at `/v1/chat/completions` (OpenAI-compatible)
- WebSocket RPC at `/ws`
- Phoenix LiveDashboard at `/live-dashboard` (dev only)
- Health check at `/health`

The browser `/setup` diagnostic page runs local binary, database, and provider
checks, so it is available only to a signed-in user listed in
`JIDOCLAW_ADMIN_EMAILS`. Results are cached for 60 seconds and manual rechecks are
limited to once per 10 seconds.

The gateway binds `127.0.0.1` by default. To reach it from another machine (e.g. over Tailscale), set `PHX_HOST=<host>[,<host2>]` in `.env` or the environment — this rebinds `0.0.0.0` and pins WebSocket origins to those hosts (append `:port` only when fronting with a proxy on a non-gateway port; bracket IPv6 addresses). To enable the `/admin` panel and browser `/setup` diagnostics, allowlist emails with `JIDOCLAW_ADMIN_EMAILS=you@example.com` — signed-in users who aren't allowlisted get a 404 (signed-out users are redirected to `/sign-in`).

### MCP Server (stdio)

```bash
mix jidoclaw --mcp
```

Runs JidoClaw as an MCP server over stdio for Claude Code, Cursor, and other
MCP clients — the gateway and Discord are skipped in this mode. To suppress
the gateway in other contexts, set the app config `config :jido_claw, mode: :cli`
(the test suite does this); there is no environment-variable mode switch.

## Verifying Installation

After starting JidoClaw, you should see:

```
  ✓  Connected to ollama
```

If you see connection errors:
- **Ollama local**: Make sure `ollama serve` is running
- **Cloud providers**: Check your API key is set correctly
- Run `/setup` to reconfigure

Test basic functionality:
```
jidoclaw> what files are in this directory?
jidoclaw> /status
jidoclaw> /help
```

## Troubleshooting

### `mix deps.get` fails

Make sure you have Hex and rebar installed:
```bash
mix local.hex --force
mix local.rebar --force
```

### Compilation warnings about missing optional deps

Some optional VFS adapters (S3, GitHub) require additional config. These warnings are safe to ignore if you don't use those features.

### Agent times out

Increase the timeout in `.jido/config.yaml`:
```yaml
timeout: 300000  # 5 minutes
```

Or increase max iterations for complex tasks:
```yaml
max_iterations: 50
```

### Ollama connection refused

```bash
# Check if ollama is running
curl http://localhost:11434/api/tags

# Start it
ollama serve
```

### API key invalid

```
  ✗  anthropic: invalid API key
```

Verify your key is exported:
```bash
echo $ANTHROPIC_API_KEY
```

Run `/setup` to reconfigure.
