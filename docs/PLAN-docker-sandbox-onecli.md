# Plan: Docker Sandbox + OneCLI Integration

Replace the Forge's `SpriteClient.Fake` backend with Docker Sandboxes for real
OS-level isolation, and integrate OneCLI as a credential/policy proxy so Forge
sessions never hold raw API keys.

---

## Background

### Current State

The Forge sandbox engine uses a pluggable `SpriteClient` behaviour
(`lib/jido_claw/forge/sprite_client/behaviour.ex`) with 7 callbacks. The only
implementation is `SpriteClient.Fake`, which executes commands via `System.cmd`
in temp directories on the host. There is no isolation boundary.

The active implementation is selected via application config:

```elixir
# config.exs or runtime.exs
config :jido_claw, :forge_sprite_client, JidoClaw.Forge.SpriteClient.Fake
```

### Target State

- **Docker Sandbox** (`sbx` CLI) replaces `Fake` as the production sprite
  backend. Each Forge session gets its own microVM with a dedicated Docker
  daemon, filesystem, and network.
- **OneCLI** runs as a sidecar and proxies all outbound HTTP from sandboxes.
  Credentials are injected per-request at the proxy layer; agents never see
  raw API keys.
- **`SpriteClient.Fake`** remains available for dev/test (no Docker required).

### Reference Implementations

- **nanoclaw** (`~/workspace/claws/nanoclaw`) — Docker container runner with
  OneCLI integration via `@onecli-sh/sdk`. Uses CLI spawning (not a Docker
  SDK), sentinel-marker stdout parsing, and filesystem-based IPC.
- **Docker Sandboxes docs** — https://docs.docker.com/ai/sandboxes/

---

## Part 1: Docker Sandbox SpriteClient

### 1.1 Prerequisites

| Requirement | Details |
|---|---|
| Docker Desktop >= 4.40 | Required for `sbx` CLI and microVM support |
| `sbx` CLI installed | `sbx login` completed, `sbx` on PATH |
| Host platform | macOS or Linux (Windows untested) |

Add a startup check in `application.ex` that logs a warning (not a crash) if
`sbx` is not found and the configured sprite client is `DockerSandbox`.

### 1.2 New Module: `SpriteClient.DockerSandbox`

Create `lib/jido_claw/forge/sprite_client/docker_sandbox.ex`.

```
defmodule JidoClaw.Forge.SpriteClient.DockerSandbox
  @behaviour JidoClaw.Forge.SpriteClient.Behaviour
```

#### Struct

```elixir
defstruct [:sandbox_name, :workspace_dir, :sprite_id]
```

- `sandbox_name` — the `sbx` sandbox name (unique per session)
- `workspace_dir` — host path mounted into the sandbox
- `sprite_id` — Forge-assigned ID (passed through from Manager)

#### Callback Mapping

| Callback | Implementation |
|---|---|
| `create/1` | Create workspace dir in configured base path. Run `sbx create --name forge-{sprite_id} {workspace_dir}`. Return `{:ok, %DockerSandbox{...}, sprite_id}`. |
| `exec/3` | `System.cmd("sbx", ["exec", sandbox_name, "sh", "-c", command])`. Return `{stdout, exit_code}`. Respect `:timeout` opt via `Task.async` + `Task.yield`. |
| `spawn/4` | `Port.open({:spawn_executable, sbx_path}, [:binary, :exit_status, args: ["exec", sandbox_name, command | args]])`. Return `{:ok, port}`. |
| `write_file/3` | Direct `File.write!/2` to workspace dir (filesystem passthrough means host writes are visible inside sandbox at the same absolute path). |
| `read_file/2` | Direct `File.read/1` from workspace dir. Same passthrough. |
| `inject_env/2` | Write env vars to `{workspace_dir}/.forge_env` as `export K=V` lines. Prefix `exec` commands with `source .forge_env &&` or pass via `sbx exec -e K=V` flags. |
| `destroy/2` | `System.cmd("sbx", ["rm", "--force", sandbox_name])`. Clean up workspace dir with `File.rm_rf/1`. |
| `impl_module/0` | Return `__MODULE__`. |

#### Configuration

```elixir
# config/runtime.exs (production)
config :jido_claw, :forge_sprite_client, JidoClaw.Forge.SpriteClient.DockerSandbox

# Docker Sandbox settings
config :jido_claw, :forge_docker_sandbox,
  workspace_base: System.get_env("FORGE_WORKSPACE_BASE", "/tmp/jidoclaw_forge"),
  sandbox_image: System.get_env("FORGE_SANDBOX_IMAGE", "ubuntu:24.04"),
  extra_mounts: [],           # [{host_path, container_path, :ro | :rw}]
  default_timeout_ms: 120_000
```

#### Sandbox Naming Convention

```
forge-{sprite_id}
```

Use the Forge-assigned `sprite_id` (already unique per session via
`:erlang.unique_integer`). This makes it easy to map sandbox <-> session
and clean up orphans.

### 1.3 Orphan Cleanup

Add a `cleanup_orphaned_sandboxes/0` function called from
`Forge.Manager.init/1`:

```elixir
def cleanup_orphaned_sandboxes do
  {output, 0} = System.cmd("sbx", ["ls", "--format", "json"])
  sandboxes = Jason.decode!(output)

  sandboxes
  |> Enum.filter(& String.starts_with?(&1["name"], "forge-"))
  |> Enum.each(fn sb ->
    System.cmd("sbx", ["rm", "--force", sb["name"]])
  end)
end
```

Only run this when the configured sprite client is `DockerSandbox`.

### 1.4 Supervision Tree Changes

In `lib/jido_claw/application.ex`, replace the hardcoded `SpriteClient.Fake`
child with a conditional:

```elixir
# Current (line 56):
JidoClaw.Forge.SpriteClient.Fake,

# Replace with:
forge_sprite_child(),
```

```elixir
defp forge_sprite_child do
  case Application.get_env(:jido_claw, :forge_sprite_client) do
    JidoClaw.Forge.SpriteClient.DockerSandbox -> {__MODULE__.ForgeSandboxInit, []}
    _ -> JidoClaw.Forge.SpriteClient.Fake
  end
end
```

`ForgeSandboxInit` is a simple `Task` that validates the `sbx` binary exists
and runs orphan cleanup. It does not need to stay running.

### 1.5 Session Lifecycle Consideration

Docker Sandboxes persist after the agent exits and reconnect when the same
workspace path is used again. Two strategies:

**Strategy A — Ephemeral (match current Forge model):**
- `create/1` → `sbx create` + `sbx up`
- `destroy/2` → `sbx rm --force`
- Simple, no state management. Sandbox is gone when session ends.

**Strategy B — Pooled (optimize for reuse):**
- `create/1` → check for existing stopped sandbox, `sbx restart` or `sbx create`
- `destroy/2` → `sbx stop` (don't remove)
- Periodic reaper removes sandboxes idle for > N minutes.
- Faster warm-start for repeat sessions.

Recommend **Strategy A** initially for simplicity. Strategy B can be added
later as an optimization behind a config flag.

### 1.6 Streaming Output

For long-running commands, `spawn/4` returns an Elixir `Port`. The caller
(`SpriteSession`) already reads from the port and emits PubSub events via
`Forge.PubSub.broadcast/2`. No changes needed to the streaming pipeline.

For `exec/3`, consider using `Port` internally (instead of `System.cmd`) when
the `:stream` option is set, to avoid blocking the SpriteSession process on
long commands.

### 1.7 Files to Create/Modify

| File | Action |
|---|---|
| `lib/jido_claw/forge/sprite_client/docker_sandbox.ex` | **Create** — new SpriteClient implementation (~200 LOC) |
| `lib/jido_claw/application.ex` | **Modify** — conditional sprite client child (lines 52-56) |
| `lib/jido_claw/forge/manager.ex` | **Modify** — call orphan cleanup in `init/1` |
| `config/runtime.exs` | **Modify** — add Docker Sandbox config block |
| `test/jido_claw/forge/sprite_client/docker_sandbox_test.exs` | **Create** — unit tests (~150 LOC) |
| `test/jido_claw/forge/integration/docker_sandbox_integration_test.exs` | **Create** — integration tests requiring Docker (~100 LOC) |

**Estimated total: ~500 LOC production, ~250 LOC test**

---

## Part 2: OneCLI Integration

### 2.1 What OneCLI Does

OneCLI is a Rust-based HTTP gateway that sits between agent containers and
external APIs. It:

1. Intercepts outbound HTTP via standard `HTTP_PROXY`/`HTTPS_PROXY` env vars
2. Validates requests against per-agent policy rules (allow/deny/rate-limit)
3. Decrypts and injects stored credentials (API keys, tokens) per-request
4. Logs all external API calls for audit

Agents make normal HTTP requests. The proxy is transparent — no code changes
inside the sandbox.

### 2.2 Prerequisites

| Requirement | Details |
|---|---|
| OneCLI running | Docker container or binary, default port 10254 (admin) / 10255 (gateway) |
| CA certificate | OneCLI's MITM cert for HTTPS interception, mounted into sandboxes |
| Agent tokens | Pre-created in OneCLI dashboard or via admin API |

### 2.3 Deployment: OneCLI Sidecar

Add OneCLI to the project's Docker Compose (or document standalone setup):

```yaml
# docker-compose.yml (or docker-compose.override.yml)
services:
  onecli:
    image: onecli/onecli:latest
    ports:
      - "10254:10254"   # Admin dashboard
      - "10255:10255"   # Gateway proxy
    volumes:
      - onecli_data:/data
    restart: unless-stopped

volumes:
  onecli_data:
```

OneCLI stores its encrypted vault and config in `/data`. The dashboard at
`http://localhost:10254` is used for initial setup of secrets and policies.

### 2.4 Integration Point: SpriteClient.DockerSandbox

OneCLI integration lives entirely in the `create/1` callback. When creating a
sandbox, inject proxy configuration so all outbound traffic routes through
OneCLI.

Add a private function `onecli_env/1` to `DockerSandbox`:

```elixir
defp onecli_env(sprite_id) do
  config = Application.get_env(:jido_claw, :onecli, [])
  gateway_url = Keyword.get(config, :gateway_url)

  if gateway_url do
    token = resolve_agent_token(sprite_id, config)

    %{
      "HTTP_PROXY" => gateway_url,
      "HTTPS_PROXY" => gateway_url,
      "PROXY_AUTHORIZATION" => "Bearer #{token}",
      "NODE_EXTRA_CA_CERTS" => "/usr/local/share/ca-certificates/onecli.crt",
      "SSL_CERT_FILE" => "/usr/local/share/ca-certificates/onecli.crt"
    }
  else
    %{}
  end
end
```

In `create/1`, merge these env vars into the sandbox environment and mount the
CA certificate:

```elixir
def create(spec) do
  sprite_id = "#{:erlang.unique_integer([:positive])}"
  workspace_dir = Path.join(workspace_base(), "forge-#{sprite_id}")
  File.mkdir_p!(workspace_dir)

  sandbox_name = "forge-#{sprite_id}"
  onecli_config = Application.get_env(:jido_claw, :onecli, [])
  ca_cert_path = Keyword.get(onecli_config, :ca_cert_path)

  # Build sbx create args
  args = ["create", "--name", sandbox_name, workspace_dir]

  # Add extra mounts (including OneCLI CA cert)
  args = if ca_cert_path && File.exists?(ca_cert_path) do
    args ++ ["--mount", "#{ca_cert_path}:/usr/local/share/ca-certificates/onecli.crt:ro"]
  else
    args
  end

  case System.cmd("sbx", args, stderr_to_stdout: true) do
    {_output, 0} ->
      # Inject OneCLI proxy env into the sandbox
      env = Map.merge(Map.get(spec, "env", %{}), onecli_env(sprite_id))
      client = %__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir, sprite_id: sprite_id}

      if map_size(env) > 0, do: inject_env(client, env)

      {:ok, client, sprite_id}

    {error_output, code} ->
      {:error, {:sbx_create_failed, code, error_output}}
  end
end
```

### 2.5 Agent Token Strategy

OneCLI assigns credentials per-agent identity. Two approaches:

**Approach A — Static token pool (simple, start here):**

Pre-create a set of OneCLI agent identities with appropriate policies. Store
tokens in JidoClaw config. Assign round-robin to Forge sessions.

```elixir
config :jido_claw, :onecli,
  gateway_url: "http://host.docker.internal:10255",
  ca_cert_path: "/path/to/onecli-ca.crt",
  agent_tokens: [
    "oc_forge_agent_1_token",
    "oc_forge_agent_2_token",
    # ...
  ]
```

```elixir
defp resolve_agent_token(_sprite_id, config) do
  tokens = Keyword.get(config, :agent_tokens, [])
  Enum.random(tokens)
end
```

**Approach B — Dynamic provisioning (future):**

Call the OneCLI admin API to create/destroy agent identities per Forge session.
This gives true per-session isolation and cleanup. Requires hitting
`http://localhost:10254/api/agents` with Finch/Req.

```elixir
defp resolve_agent_token(sprite_id, config) do
  admin_url = Keyword.get(config, :admin_url, "http://localhost:10254")
  admin_key = Keyword.get(config, :admin_api_key)

  {:ok, %{body: body}} = Req.post!("#{admin_url}/api/agents",
    json: %{name: "forge-#{sprite_id}", policies: default_policies()},
    headers: [{"authorization", "Bearer #{admin_key}"}]
  )

  body["token"]
end
```

Recommend **Approach A** to start. Approach B adds ~80 LOC and a dependency on
OneCLI's admin API stability.

### 2.6 Policy Configuration

Configure these policies in the OneCLI dashboard for Forge agent identities:

| Policy | Purpose |
|---|---|
| Allow `api.anthropic.com` | Anthropic LLM calls |
| Allow `api.openai.com` | OpenAI LLM calls |
| Allow `generativelanguage.googleapis.com` | Google AI calls |
| Allow `api.groq.com` | Groq LLM calls |
| Allow `api.x.ai` | xAI LLM calls |
| Allow `openrouter.ai` | OpenRouter LLM calls |
| Allow `localhost:11434` / Ollama host | Local Ollama inference |
| Allow `api.github.com` | GitHub API (for GitHub bot) |
| Rate limit | e.g. 100 req/min per agent to prevent runaway loops |
| Deny all other hosts | Default deny for anything not explicitly allowed |

Store the corresponding API keys as secrets in OneCLI's vault, mapped to each
allowed host.

### 2.7 Interaction with Existing Security

JidoClaw already has `JidoClaw.Security.Vault` (Cloak AES-256-GCM) and
`JidoClaw.Security.SecretRef` (Ash resource) for encrypted secret storage.

With OneCLI:
- **LLM API keys** move from JidoClaw's vault to OneCLI's vault. OneCLI
  handles injection.
- **JidoClaw's vault** continues to manage non-HTTP secrets (database
  credentials, signing keys, user tokens).
- **Redaction filters** (`Security.Redaction.*`) remain active on all output
  channels as a defense-in-depth layer. Even though agents won't have raw
  keys, the redaction layer guards against any credential leakage from
  JidoClaw's own config or logs.

### 2.8 Configuration

```elixir
# config/runtime.exs
config :jido_claw, :onecli,
  enabled: System.get_env("ONECLI_ENABLED", "false") == "true",
  gateway_url: System.get_env("ONECLI_GATEWAY_URL", "http://host.docker.internal:10255"),
  admin_url: System.get_env("ONECLI_ADMIN_URL", "http://localhost:10254"),
  ca_cert_path: System.get_env("ONECLI_CA_CERT_PATH"),
  agent_tokens: System.get_env("ONECLI_AGENT_TOKENS", "")
                |> String.split(",", trim: true)
```

When `enabled: false`, `onecli_env/1` returns `%{}` and no proxy config is
injected. Sandboxes make direct outbound requests (same as today).

### 2.9 Files to Create/Modify

| File | Action |
|---|---|
| `lib/jido_claw/forge/sprite_client/docker_sandbox.ex` | **Modify** — add `onecli_env/1` and CA cert mount to `create/1` (~70 LOC) |
| `config/runtime.exs` | **Modify** — add `:onecli` config block |
| `docker-compose.yml` or `docs/SETUP.md` | **Create/Modify** — OneCLI sidecar setup instructions |

**Estimated total: ~70 LOC on top of Part 1**

---

## Implementation Order

### Phase 1: Docker Sandbox SpriteClient

1. Create `SpriteClient.DockerSandbox` with all 7 callbacks
2. Add conditional child in `application.ex`
3. Add orphan cleanup to Manager
4. Add config to `runtime.exs`
5. Write unit tests (mock `sbx` CLI) and integration tests
6. Verify all 4 existing runners (Shell, ClaudeCode, Workflow, Custom) work
   unchanged on top of the new backend

### Phase 2: OneCLI Sidecar

1. Deploy OneCLI container (Docker Compose or standalone)
2. Configure secrets and agent identities in OneCLI dashboard
3. Set up policies for allowed hosts and rate limits

### Phase 3: OneCLI Integration

1. Add `onecli_env/1` and CA cert mounting to `DockerSandbox.create/1`
2. Add `:onecli` config block
3. Test end-to-end: Forge session -> sandbox -> OneCLI proxy -> LLM API
4. Verify credential redaction still works on all output channels

### Phase 4: Hardening

1. Add telemetry events for sandbox create/destroy/exec timing
2. Add `sbx` health check to `setup/doctor.ex` (if it exists)
3. Implement Strategy B (pooled sandboxes) if cold start latency is a problem
4. Implement dynamic OneCLI agent provisioning (Approach B) if static pool
   is insufficient

---

## Risk & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| `sbx` CLI not installed | Forge won't start sessions | Startup warning + fallback to Fake in dev |
| Sandbox cold start latency | Slower session creation | Strategy B (pooled) as Phase 4 optimization |
| OneCLI unavailable | Outbound HTTP from sandboxes fails | `onecli.enabled` config flag; disable = direct access |
| No Elixir OneCLI SDK | Must call admin API with raw HTTP | Simple Req calls; SDK could be extracted later |
| `sbx` CLI changes | Breaking changes to args/output | Pin Docker Desktop version; wrap CLI calls in single module |
| Filesystem passthrough path differences | `write_file`/`read_file` break | Sandboxes mount at same absolute path by default; test on both macOS and Linux |
