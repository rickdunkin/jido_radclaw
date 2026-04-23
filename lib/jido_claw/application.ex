defmodule JidoClaw.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # In MCP mode, stdout is reserved for JSON-RPC — redirect all logging to stderr.
    if Application.get_env(:jido_claw, :serve_mode) == :mcp do
      redirect_logger_to_stderr()
    end

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

    opts = [strategy: :rest_for_one, name: JidoClaw.Supervisor, max_restarts: 10, max_seconds: 30]
    result = Supervisor.start_link(children, opts)

    # Start Nostrum (Discord) only when token is configured — it's runtime: false
    # so it won't auto-start, we start it manually after .env is loaded.
    # Config must be applied here at runtime because config.exs evaluates at
    # compile time before .env is available.
    # Nostrum must start FIRST (initializes the ConsumerGroup :pg scope),
    # then the consumer joins the group. Shard sessions wait 5s for consumers.
    # Skipped in MCP mode — Discord would pollute stdio.
    unless Application.get_env(:jido_claw, :skip_discord) do
      if discord_token = System.get_env("DISCORD_BOT_TOKEN") do
        Application.put_env(:nostrum, :token, discord_token)
        Application.put_env(:nostrum, :gateway_intents, :all)
        Application.put_env(:nostrum, :num_shards, :auto)

        case Application.ensure_all_started(:nostrum) do
          {:ok, _} ->
            case Supervisor.start_child(JidoClaw.Supervisor, JidoClaw.Channel.DiscordConsumer) do
              {:ok, _} ->
                Logger.warning("[JidoClaw] Discord adapter started")

              {:error, reason} ->
                Logger.warning("[JidoClaw] Discord consumer failed to start: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.warning("[JidoClaw] Discord failed to start: #{inspect(reason)}")
        end
      end
    end

    result
  end

  # -- Core: always started --
  defp core_children do
    infra_children = [
      {Registry, keys: :unique, name: JidoClaw.SessionRegistry},
      {Registry, keys: :unique, name: JidoClaw.TenantRegistry},
      {Task.Supervisor, name: JidoClaw.TaskSupervisor},
      JidoClaw.Repo,
      JidoClaw.Security.Vault,
      {Phoenix.PubSub, name: JidoClaw.PubSub},
      {Jido.Signal.Bus, name: JidoClaw.SignalBus}
    ]

    [
      # Infrastructure (nested supervisor — if these crash, rest_for_one restarts dependents)
      %{
        id: JidoClaw.InfraSupervisor,
        start:
          {Supervisor, :start_link,
           [infra_children, [strategy: :one_for_one, name: JidoClaw.InfraSupervisor]]},
        type: :supervisor
      },

      # Forge sandbox execution engine
      {Registry, keys: :unique, name: JidoClaw.Forge.SessionRegistry},
      {DynamicSupervisor, name: JidoClaw.Forge.HarnessSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: JidoClaw.Forge.ExecSessionSupervisor, strategy: :one_for_one},
      JidoClaw.Forge.Manager
    ] ++
      forge_sandbox_children() ++
      [
        # Orchestration workflow feed
        JidoClaw.Orchestration.RunSummaryFeed,

        # Code Server runtime management
        {Registry, keys: :unique, name: JidoClaw.CodeServer.RuntimeRegistry},
        {DynamicSupervisor, name: JidoClaw.CodeServer.RuntimeSupervisor, strategy: :one_for_one},

        # Finch HTTP pools
        {Finch, name: JidoClaw.Finch},

        # Telemetry
        JidoClaw.Telemetry,

        # Stats
        JidoClaw.Stats,

        # Background process tracking
        JidoClaw.BackgroundProcess.Registry,

        # Tool approval
        JidoClaw.Platform.Approval,

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

        # Cached user-defined reasoning strategies (.jido/strategies/*.yaml)
        {JidoClaw.Reasoning.StrategyStore, [project_dir: project_dir()]},

        # Cached user-defined pipelines (.jido/pipelines/*.yaml)
        {JidoClaw.Reasoning.PipelineStore, [project_dir: project_dir()]},

        # Network
        {JidoClaw.Network.Supervisor, [project_dir: project_dir()]},

        # Agent tracking (per-agent stats for swarm display)
        JidoClaw.AgentTracker,

        # Display coordinator (spinner, status bar, swarm box)
        JidoClaw.Display,

        # VFS workspace registry + supervisor (must start BEFORE SessionManager so
        # SessionManager.start_new_session/3 can call Workspace.ensure_started/2).
        {Registry, keys: :unique, name: JidoClaw.VFS.WorkspaceRegistry},
        JidoClaw.VFS.WorkspaceSupervisor,

        # Profile manager — must start BEFORE SessionManager so
        # SessionManager.start_new_session/3 can read the active env, and
        # so a SessionManager crash under :rest_for_one doesn't wipe the
        # active-by-workspace map. `ets_mirror: true` enables the
        # read-only table SessionManager uses to avoid a GenServer
        # call into ProfileManager on the session-bootstrap path —
        # breaking the PM ↔ SM mutual-call cycle.
        {JidoClaw.Shell.ProfileManager, [project_dir: project_dir(), ets_mirror: true]},

        # SSH server registry — parses `.jido/config.yaml` servers: list.
        # Must start BEFORE SessionManager so SSH routing lookups can
        # resolve; under :rest_for_one, a registry crash restarts
        # SessionManager too, clearing any stale SSH session cache.
        {JidoClaw.Shell.ServerRegistry, [project_dir: project_dir()]},

        # Shell session manager (jido_shell + Host backend for real command execution)
        JidoClaw.Shell.SessionManager
      ]
  end

  defp project_dir do
    Application.get_env(:jido_claw, :project_dir, File.cwd!())
  end

  # -- Forge sandbox: conditional on config --
  defp forge_sandbox_children do
    case Application.get_env(:jido_claw, :forge_sandbox) do
      JidoClaw.Forge.Sandbox.Docker ->
        [JidoClaw.Forge.SandboxInit]

      _ ->
        [JidoClaw.Forge.Sandbox.Local]
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
      # Bypass Jido.MCP.Server.server_children/2 — upstream still prepends
      # Anubis.Server.Registry to the child list, which was a process in
      # anubis 0.17 but is a behaviour in 1.1. The server's generated
      # child_spec/1 calls Anubis.Server.Supervisor.start_link, which starts
      # the registry internally.
      :mcp -> [{JidoClaw.MCPServer, [transport: :stdio]}]
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
        line == "" ->
          :skip

        String.starts_with?(line, "#") ->
          :skip

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

  @doc false
  def redirect_logger_to_stderr do
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error},
      level: :all,
      filter_default: :log
    })
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
