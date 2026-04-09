defmodule JidoClaw.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Load .env file if present (project root or cwd)
    load_dotenv()

    # Record boot time for uptime tracking
    Application.put_env(:jido_claw, :started_at, System.monotonic_time(:second))

    # Register Ollama as a custom provider in ReqLLM
    ReqLLM.Providers.register(JidoClaw.Providers.Ollama)

    children =
      List.flatten([
        core_children(),
        platform_children(),
        gateway_children(),
        cluster_children(),
        mcp_children()
      ])

    opts = [strategy: :one_for_one, name: JidoClaw.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Start Nostrum (Discord) only when token is configured — it's runtime: false
    # so it won't auto-start, we start it manually after .env is loaded.
    # Config must be applied here at runtime because config.exs evaluates at
    # compile time before .env is available.
    # Nostrum must start FIRST (initializes the ConsumerGroup :pg scope),
    # then the consumer joins the group. Shard sessions wait 5s for consumers.
    if discord_token = System.get_env("DISCORD_BOT_TOKEN") do
      Application.put_env(:nostrum, :token, discord_token)
      Application.put_env(:nostrum, :gateway_intents, :all)
      Application.put_env(:nostrum, :num_shards, :auto)

      case Application.ensure_all_started(:nostrum) do
        {:ok, _} ->
          case Supervisor.start_child(JidoClaw.Supervisor, JidoClaw.Channel.DiscordConsumer) do
            {:ok, _} -> Logger.warning("[JidoClaw] Discord adapter started")
            {:error, reason} -> Logger.warning("[JidoClaw] Discord consumer failed to start: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[JidoClaw] Discord failed to start: #{inspect(reason)}")
      end
    end

    result
  end

  # -- Core: always started --
  defp core_children do
    [
      # Registries
      {Registry, keys: :unique, name: JidoClaw.SessionRegistry},
      {Registry, keys: :unique, name: JidoClaw.TenantRegistry},

      # Database
      JidoClaw.Repo,

      # Encryption vault
      JidoClaw.Security.Vault,

      # Forge sandbox execution engine
      {Registry, keys: :unique, name: JidoClaw.Forge.SessionRegistry},
      {DynamicSupervisor, name: JidoClaw.Forge.SpriteSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: JidoClaw.Forge.ExecSessionSupervisor, strategy: :one_for_one},
      JidoClaw.Forge.Manager
    ] ++ forge_sprite_children() ++ [

      # PubSub for real-time events
      {Phoenix.PubSub, name: JidoClaw.PubSub},

      # Orchestration workflow feed
      JidoClaw.Orchestration.RunSummaryFeed,

      # Code Server runtime management
      {Registry, keys: :unique, name: JidoClaw.CodeServer.RuntimeRegistry},
      {DynamicSupervisor, name: JidoClaw.CodeServer.RuntimeSupervisor, strategy: :one_for_one},

      # Finch HTTP pools
      {Finch, name: JidoClaw.Finch},

      # Signal bus
      {Jido.Signal.Bus, name: JidoClaw.SignalBus},

      # Telemetry
      JidoClaw.Telemetry,

      # Stats
      JidoClaw.Stats,

      # Background process tracking
      JidoClaw.BackgroundProcess.Registry,

      # Tool approval
      JidoClaw.Tools.Approval,

      # Global session supervisor (fallback for non-tenant sessions)
      {DynamicSupervisor, name: JidoClaw.SessionSupervisor, strategy: :one_for_one},

      # Jido agent runtime
      JidoClaw.Jido,

      # Messaging runtime (rooms, agents, bridges — powered by jido_messaging)
      JidoClaw.Messaging,

      # Multi-tenancy
      JidoClaw.Tenant.Supervisor,
      JidoClaw.Tenant.Manager,

      # Solutions engine
      {JidoClaw.Solutions.Store, [project_dir: project_dir()]},
      {JidoClaw.Solutions.Reputation, [project_dir: project_dir()]},

      # Persistent memory
      {JidoClaw.Memory, [project_dir: project_dir()]},

      # Cached skill registry
      {JidoClaw.Skills, [project_dir: project_dir()]},

      # Network
      {JidoClaw.Network.Supervisor, [project_dir: project_dir()]},

      # Agent tracking (per-agent stats for swarm display)
      JidoClaw.AgentTracker,

      # Display coordinator (spinner, status bar, swarm box)
      JidoClaw.Display,

      # Shell session manager (jido_shell + Host backend for real command execution)
      JidoClaw.Shell.SessionManager
    ]
  end

  defp project_dir do
    Application.get_env(:jido_claw, :project_dir, File.cwd!())
  end

  # -- Forge sprite client: conditional on config --
  defp forge_sprite_children do
    case Application.get_env(:jido_claw, :forge_sprite_client) do
      JidoClaw.Forge.SpriteClient.DockerSandbox ->
        [JidoClaw.Forge.SandboxInit]

      _ ->
        [JidoClaw.Forge.SpriteClient.Fake]
    end
  end

  # -- Platform: no extra children needed --
  # Default tenant is created by Tenant.Manager via handle_info(:create_default_tenant)
  defp platform_children do
    []
  end

  # -- Gateway: Phoenix HTTP/WS server --
  defp gateway_children do
    mode = Application.get_env(:jido_claw, :mode, :both)

    if mode in [:gateway, :both] do
      [JidoClaw.Web.Endpoint]
    else
      []
    end
  end

  # -- Clustering: libcluster --
  defp cluster_children do
    if Application.get_env(:jido_claw, :cluster_enabled, false) do
      topologies = JidoClaw.Cluster.topology()

      [
        %{id: :pg_jido_claw, start: {:pg, :start_link, [:jido_claw]}},
        {Cluster.Supervisor, [topologies, [name: JidoClaw.ClusterSupervisor]]}
      ]
    else
      []
    end
  end

  # -- MCP server (powered by jido_mcp) --
  defp mcp_children do
    case Application.get_env(:jido_claw, :serve_mode) do
      :mcp -> Jido.MCP.Server.server_children(JidoClaw.MCPServer, transport: :stdio)
      _ -> []
    end
  end

  # -- .env file loading --
  defp load_dotenv do
    # Check cwd first, then project dir
    paths = [
      Path.join(File.cwd!(), ".env"),
      Path.join([File.cwd!(), ".jido", ".env"])
    ]

    Enum.find_value(paths, fn path ->
      case File.read(path) do
        {:ok, content} ->
          parse_dotenv(content)
          Logger.debug("[JidoClaw] Loaded env from #{path}")
          true

        _ ->
          nil
      end
    end)
  end

  defp parse_dotenv(content) do
    content
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)

      cond do
        line == "" -> :skip
        String.starts_with?(line, "#") -> :skip
        true ->
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              key = String.trim(key)
              value = value |> String.trim() |> strip_quotes()
              # Only set if not already in environment (env vars take precedence)
              if System.get_env(key) == nil do
                System.put_env(key, value)
              end

            _ ->
              :skip
          end
      end
    end)
  end

  defp strip_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1..-2//1)

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)

      true ->
        value
    end
  end
end
