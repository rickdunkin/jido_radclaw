import Config

# --- Forge Docker Sandbox ---
# Set FORGE_SANDBOX=docker to use Docker Sandboxes instead of
# the default Local (local temp directory) sandbox.
if System.get_env("FORGE_SANDBOX") == "docker" do
  config :jido_claw, :forge_sandbox, JidoClaw.Forge.Sandbox.Docker

  config :jido_claw, :forge_docker_sandbox,
    workspace_base: System.get_env("FORGE_WORKSPACE_BASE", "/tmp/jidoclaw_forge"),
    default_agent: System.get_env("FORGE_SANDBOX_AGENT", "shell"),
    default_timeout_ms:
      String.to_integer(System.get_env("FORGE_SANDBOX_TIMEOUT_MS", "120000"))
end

# --- OneCLI Credential Proxy ---
# Set FORGE_ONECLI_ENABLED=true to route sandbox outbound HTTP through OneCLI.
# OneCLI must be running as a sidecar (Docker container or binary).
if System.get_env("FORGE_ONECLI_ENABLED") == "true" do
  config :jido_claw, :onecli,
    enabled: true,
    gateway_url:
      System.get_env("ONECLI_GATEWAY_URL", "http://host.docker.internal:10255"),
    ca_cert_path: System.get_env("ONECLI_CA_CERT_PATH"),
    agent_tokens:
      System.get_env("ONECLI_AGENT_TOKENS", "")
      |> String.split(",", trim: true)
end

# --- Production overrides ---
if config_env() == :prod do
  if key = System.get_env("CLOAK_KEY") do
    config :jido_claw, JidoClaw.Security.Vault,
      ciphers: [
        default:
          {Cloak.Ciphers.AES.GCM,
           tag: "AES.GCM.V1", key: Base.decode64!(key), iv_length: 12}
      ]
  end

  if database_url = System.get_env("DATABASE_URL") do
    config :jido_claw, JidoClaw.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  end

  if secret_key_base = System.get_env("SECRET_KEY_BASE") do
    config :jido_claw, JidoClaw.Web.Endpoint,
      secret_key_base: secret_key_base
  end
end
