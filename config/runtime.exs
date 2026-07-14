import Config

# This file is TOTAL — configure-only, never raising, no fallible parses. A
# prod-built escript evaluates runtime.exs BEFORE `main/1` runs (even with
# `app: nil`), so any raise here would break the bare-binary
# `jidoclaw --third-party-licenses` guarantee. Enforcement lives at
# APPLICATION STARTUP instead (after dotenv loading, which this file
# evaluates too early to see anyway):
#   - SECRET_KEY_BASE / TOKEN_SIGNING_SECRET presence + quality:
#     JidoClaw.Security.RuntimeSecrets.ensure_configured!/0
#   - CLOAK_KEY / CLOAK_KEY_FILE loading + base64/length validation:
#     JidoClaw.Security.VaultConfig.ensure_configured!/0 (a cipher block
#     here would be redundant today and hazardous as a raw passthrough —
#     base64 encodings of 16/24-byte AES keys are themselves 24/32 bytes,
#     so a raw value would silently select a DIFFERENT key)
#   - POOL_SIZE parsing: JidoClaw.Repo.init/2 (raw string passes through)
# For releases this is timing-equivalent — a release boots the app
# immediately, so fail-fast holds.

# --- Forge Docker Sandbox ---
# Set FORGE_SANDBOX=docker to use Docker Sandboxes instead of
# the default host-shell backend. The host-shell backend is not a sandbox.
if config_env() != :test and System.get_env("FORGE_SANDBOX") == "docker" do
  config :jido_claw, :forge_sandbox, JidoClaw.Forge.Sandbox.Docker

  # FORGE_SANDBOX_TIMEOUT_MS was removed outright: its `default_timeout_ms`
  # key had no consumer (Docker sandbox calls without an explicit timeout
  # use :infinity), and its String.to_integer was a config-eval raise.
  config :jido_claw, :forge_docker_sandbox,
    workspace_base: System.get_env("FORGE_WORKSPACE_BASE", "/tmp/jidoclaw_forge"),
    default_agent: System.get_env("FORGE_SANDBOX_AGENT", "shell")
end

# --- OneCLI Credential Proxy ---
# Set FORGE_ONECLI_ENABLED=true to route sandbox outbound HTTP through OneCLI.
# OneCLI must be running as a sidecar (Docker container or binary). Test is an
# explicit hard stop: runtime.exs is evaluated after config/test.exs, and an
# inherited shell flag must never re-arm the proxy in a test BEAM.
if config_env() != :test and System.get_env("FORGE_ONECLI_ENABLED") == "true" do
  config :jido_claw, :onecli,
    enabled: true,
    gateway_url: System.get_env("ONECLI_GATEWAY_URL", "http://host.docker.internal:10255"),
    ca_cert_path: System.get_env("ONECLI_CA_CERT_PATH"),
    agent_tokens:
      System.get_env("ONECLI_AGENT_TOKENS", "")
      |> String.split(",", trim: true)
end

# --- Secrets (all envs: set-if-present; enforcement is RuntimeSecrets') ---
if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :jido_claw, JidoClaw.Web.Endpoint, secret_key_base: secret_key_base
end

if token_signing_secret = System.get_env("TOKEN_SIGNING_SECRET") do
  config :jido_claw, token_signing_secret: token_signing_secret
end

# --- Production overrides ---
if config_env() == :prod do
  if database_url = System.get_env("DATABASE_URL") do
    # POOL_SIZE rides through as a RAW string — JidoClaw.Repo.init/2 parses
    # it (chaining super/2) and raises there, at Repo startup, on junk.
    config :jido_claw, JidoClaw.Repo,
      url: database_url,
      pool_size: System.get_env("POOL_SIZE", "10")
  end

  # check_origin / bind address are NOT set here: the base config is
  # loopback + localhost-pinned origins in every env, and PHX_HOST opt-in
  # exposure is applied by JidoClaw.Web.GatewayExposure at app start (after
  # .env loads — this file evaluates too early to see it, and it would be
  # overridden anyway). Without PHX_HOST, prod binds 127.0.0.1 on purpose.
end
