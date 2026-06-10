import Config

# --- Forge Docker Sandbox ---
# Set FORGE_SANDBOX=docker to use Docker Sandboxes instead of
# the default host-shell backend. The host-shell backend is not a sandbox.
if System.get_env("FORGE_SANDBOX") == "docker" do
  config :jido_claw, :forge_sandbox, JidoClaw.Forge.Sandbox.Docker

  config :jido_claw, :forge_docker_sandbox,
    workspace_base: System.get_env("FORGE_WORKSPACE_BASE", "/tmp/jidoclaw_forge"),
    default_agent: System.get_env("FORGE_SANDBOX_AGENT", "shell"),
    default_timeout_ms: String.to_integer(System.get_env("FORGE_SANDBOX_TIMEOUT_MS", "120000"))
end

# --- OneCLI Credential Proxy ---
# Set FORGE_ONECLI_ENABLED=true to route sandbox outbound HTTP through OneCLI.
# OneCLI must be running as a sidecar (Docker container or binary).
if System.get_env("FORGE_ONECLI_ENABLED") == "true" do
  config :jido_claw, :onecli,
    enabled: true,
    gateway_url: System.get_env("ONECLI_GATEWAY_URL", "http://host.docker.internal:10255"),
    ca_cert_path: System.get_env("ONECLI_CA_CERT_PATH"),
    agent_tokens:
      System.get_env("ONECLI_AGENT_TOKENS", "")
      |> String.split(",", trim: true)
end

# --- Production overrides ---
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.

      Generate one with `mix phx.gen.secret`.
      """

  token_signing_secret =
    System.get_env("TOKEN_SIGNING_SECRET") ||
      raise """
      environment variable TOKEN_SIGNING_SECRET is missing.

      Generate one with `mix phx.gen.secret`.
      """

  if key = System.get_env("CLOAK_KEY") do
    config :jido_claw, JidoClaw.Security.Vault,
      ciphers: [
        default:
          {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(key), iv_length: 12}
      ]
  end

  if database_url = System.get_env("DATABASE_URL") do
    config :jido_claw, JidoClaw.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  end

  # check_origin / bind address are NOT set here: the base config is
  # loopback + localhost-pinned origins in every env, and PHX_HOST opt-in
  # exposure is applied by JidoClaw.Web.GatewayExposure at app start (after
  # .env loads — this file evaluates too early to see it, and it would be
  # overridden anyway). Without PHX_HOST, prod binds 127.0.0.1 on purpose.
  config :jido_claw, JidoClaw.Web.Endpoint, secret_key_base: secret_key_base

  config :jido_claw, token_signing_secret: token_signing_secret
else
  if secret_key_base = System.get_env("SECRET_KEY_BASE") do
    config :jido_claw, JidoClaw.Web.Endpoint, secret_key_base: secret_key_base
  end

  if token_signing_secret = System.get_env("TOKEN_SIGNING_SECRET") do
    config :jido_claw, token_signing_secret: token_signing_secret
  end
end
