defmodule JidoClaw.Application do
  # The {id, start, restart, type} maps are OTP child_spec descriptors, an
  # enforced framework contract rather than incidental domain duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  OTP `Application` callback for JidoClaw.

  Boots the supervision tree in groups — core infrastructure (Repo, Vault,
  PubSub, SignalBus, Forge engine, agent runtime, shell sessions, network),
  the platform layer, the optional Phoenix gateway, libcluster, and the MCP
  stdio server — selected by the `:mode`, `:cluster_enabled`, and
  `:serve_mode` runtime config. Also loads `.env` files, registers the
  Ollama provider, and dynamically starts Nostrum (Discord) when a token
  is present.
  """

  use Application
  require Logger

  alias JidoClaw.Core.DependencyPatches
  alias JidoClaw.Cron.Owner, as: CronOwner
  alias JidoClaw.Embeddings.BootGuard
  alias JidoClaw.MCP.Consumer, as: MCPConsumer
  alias JidoClaw.Orchestration.Verify.Git, as: VerifyGit
  alias JidoClaw.Security.Redaction.LogRedactor
  alias JidoClaw.Security.RuntimeSecrets
  alias JidoClaw.Security.VaultConfig
  alias JidoClaw.Web.GatewayExposure

  @external_test_secrets ~w(
    ANTHROPIC_API_KEY
    BRAVE_SEARCH_API_KEY
    DISCORD_BOT_TOKEN
    GITHUB_TOKEN
    GOOGLE_API_KEY
    GROQ_API_KEY
    JIDOCLAW_EXTRA_ALLOWED_ENV_VARS
    OLLAMA_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    VOYAGE_API_KEY
    XAI_API_KEY
  )

  @impl Application
  def start(_type, _args) do
    sanitize_external_test_environment()
    DependencyPatches.ensure_loaded!()

    # In MCP mode, stdout is reserved for JSON-RPC — redirect all logging to stderr.
    if Application.get_env(:jido_claw, :serve_mode) == :mcp do
      redirect_logger_to_stderr()
    end

    LogRedactor.install!()

    # Test boots disable dotenv ingestion so a developer's real credentials
    # can never arm external adapters during the suite. Explicit parser tests
    # still call load_dotenv/0 directly.
    if Application.get_env(:jido_claw, :load_dotenv, true), do: load_dotenv()

    # PHX_HOST exposure must apply here, after load_dotenv/0 —
    # config/runtime.exs evaluates before Application.start/2 runs, so it
    # can never see .env-supplied values.
    GatewayExposure.configure!()

    RuntimeSecrets.ensure_configured!()
    VaultConfig.ensure_configured!()

    # Boot guard: refuse to start when the only embedding provider's
    # credential is missing. Bypassed when the `--setup` arm has set
    # `:first_run_setup_pending` so the wizard can capture the key.
    BootGuard.assert_voyage_key_or_raise!()

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

    opts = [strategy: :one_for_one, name: JidoClaw.Supervisor, max_restarts: 10, max_seconds: 30]
    result = Supervisor.start_link(children, opts)

    # Start Nostrum (Discord) only when token is configured — it's runtime: false
    # so it won't auto-start, we start it manually after .env is loaded.
    # Config must be applied here at runtime because config.exs evaluates at
    # compile time before .env is available.
    # Nostrum must start FIRST (initializes the ConsumerGroup :pg scope),
    # then the consumer joins the group. Shard sessions wait 5s for consumers.
    # Skipped in MCP mode — Discord would pollute stdio.
    maybe_start_discord()

    result
  end

  defp maybe_start_discord do
    if Application.get_env(:jido_claw, :skip_discord) do
      :ok
    else
      case System.get_env("DISCORD_BOT_TOKEN") do
        nil ->
          :ok

        token ->
          Application.put_env(:nostrum, :token, token)
          Application.put_env(:nostrum, :gateway_intents, :all)
          Application.put_env(:nostrum, :num_shards, :auto)

          start_nostrum()
      end
    end
  end

  @doc false
  @spec sanitize_external_test_environment() :: :ok
  def sanitize_external_test_environment do
    if Application.get_env(:jido_claw, :sanitize_external_env, false) do
      Enum.each(System.get_env(), fn {name, _value} ->
        if external_test_env?(name), do: System.delete_env(name)
      end)

      Application.delete_env(:nostrum, :token)
      Application.delete_env(:jido_browser, :brave_api_key)

      # runtime.exs also refuses to arm OneCLI in :test. Clear the resolved
      # application config here as a second boundary in case a precompiled or
      # test-host override populated it before this boot callback.
      Application.put_env(:jido_claw, :onecli,
        enabled: false,
        gateway_url: nil,
        ca_cert_path: nil,
        agent_tokens: []
      )

      Application.put_env(:jido_claw, :forge_sandbox, JidoClaw.Forge.Runner.HostShell)
      Application.delete_env(:jido_claw, :forge_docker_sandbox)
      Application.put_env(:ex_aws, :access_key_id, "test-disabled-access-key")
      Application.put_env(:ex_aws, :secret_access_key, "test-disabled-secret-key")
      Application.put_env(:ex_aws, :security_token, "test-disabled-session-token")

      Application.put_env(
        :ex_aws,
        :http_client,
        JidoClaw.Test.NoExternalExAwsHttpClient
      )
    end

    :ok
  end

  defp external_test_env?(name) do
    name in @external_test_secrets or
      String.starts_with?(name, [
        "AWS_",
        "ONECLI_",
        "FORGE_ONECLI_",
        "FORGE_SANDBOX",
        "FORGE_WORKSPACE_"
      ])
  end

  defp start_nostrum do
    with :ok <- ensure_nostrum_started(),
         :ok <- start_discord_consumer() do
      Logger.warning("[JidoClaw] Discord adapter started")
    end
  end

  defp ensure_nostrum_started do
    case Application.ensure_all_started(:nostrum) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[JidoClaw] Discord failed to start: #{inspect(reason)}")
        {:error, :nostrum}
    end
  end

  defp start_discord_consumer do
    case Supervisor.start_child(JidoClaw.Supervisor, JidoClaw.Channel.DiscordConsumer) do
      {:ok, _} ->
        :ok

      {:ok, _, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[JidoClaw] Discord consumer failed to start: #{inspect(reason)}")
        {:error, :consumer}
    end
  end

  # -- Core: always started --
  defp core_children do
    infra_children = [
      # FIRST in the core children so it terminates LAST on shutdown
      # (supervisors stop children in reverse start order): its
      # `terminate/2` is the VM-shutdown sweep over every still-registered
      # runner CLI, and it must outlive the Forge tree whose sessions
      # register with it (docs/system/forge-session-resume.md).
      JidoClaw.Forge.ChildTracker,
      {Registry, keys: :unique, name: JidoClaw.SessionRegistry},
      {Registry, keys: :unique, name: JidoClaw.TenantRegistry},
      {Registry, keys: :unique, name: JidoClaw.Memory.Consolidator.RunRegistry},
      # Executor-seam PR-2: deposit-ref → per-step Deposit box (the vendor
      # executor's structured-output channel). Same shape as RunRegistry.
      {Registry, keys: :unique, name: JidoClaw.Skills.Steps.ForgeExecutor.DepositRegistry},
      JidoClaw.Agent.Handoff.Registry,
      {Task.Supervisor, name: JidoClaw.TaskSupervisor},
      {Task.Supervisor, name: JidoClaw.Memory.Consolidator.TaskSupervisor},
      {Task.Supervisor, name: JidoClaw.Audit.TaskSupervisor},
      JidoClaw.Repo,
      JidoClaw.Security.Vault,
      {Phoenix.PubSub, name: JidoClaw.PubSub},
      # Killable workflow execution (RunExecution): the run-id → executor-pid
      # registry and the task supervisor the executor tasks run under. Started
      # AFTER Repo/Vault/PubSub deliberately — supervisor shutdown is reverse
      # start order, and executor tasks are DB-heavy and broadcast via PubSub,
      # so they must be torn down before those services on app shutdown.
      {Registry, keys: :unique, name: JidoClaw.Orchestration.RunRegistry},
      {Task.Supervisor, name: JidoClaw.Orchestration.RunTaskSupervisor},
      # WS5 cross-node cancellation: the per-node receiver that turns a routed
      # remote kill (`Cancellation` cast) into a local `RunExecution.kill_local/2`.
      # Reactive-only/stateless (no timer/DB/PubSub) — inert until a remote cast
      # arrives, so it is NOT `cluster_enabled`-gated: always-on in every serve
      # mode and on every node (the single-node local cancel path resolves
      # `:local` and never casts here, but the process is still present). Adjacent
      # to RunRegistry, which `kill_local/2` looks up through; inside
      # infra_children so it tears down before Repo/PubSub on shutdown.
      JidoClaw.Orchestration.RunTerminator,
      # WS1 workflow lease: the run-id → lease-sidecar registry and the task
      # supervisor the heartbeat sidecars run under. All modes (inert until a run
      # launches and claims) — no `cluster_enabled` gate; the reclaim Pooler that
      # WOULD be cluster-gated is WS3. Same placement rationale as RunRegistry:
      # after Repo/Vault/PubSub, so DB-heavy sidecars tear down before them.
      {Registry, keys: :unique, name: JidoClaw.Orchestration.LeaseRegistry},
      {Task.Supervisor, name: JidoClaw.Orchestration.LeaseTaskSupervisor},
      # Verify authority filesystem captures run behind a VM-wide ceiling.
      # A timed-out FIFO open stays supervised (killing its BEAM owner does not
      # cancel the dirty-I/O syscall), so max_children is the cross-run resource
      # exhaustion fence rather than a throughput-only setting.
      {Task.Supervisor,
       name: JidoClaw.Orchestration.VerifyCaptureTaskSupervisor,
       max_children: VerifyGit.capture_concurrency()},
      # AR-2 composer supervised lifecycle (Phase 2c): the parent-run-id → composer
      # GenServer registry + the DynamicSupervisor its `:transient` children run
      # under. `max_restarts: 10`/`max_seconds: 30` matches the root supervisor's
      # intensity (DynamicSupervisor defaults to 3/5) — the restart-intensity
      # backstop for the rebuild-on-restart resume, not the design.
      {Registry, keys: :unique, name: JidoClaw.RouteComposer.Registry},
      {DynamicSupervisor,
       name: JidoClaw.RouteComposer.Supervisor,
       strategy: :one_for_one,
       max_restarts: 10,
       max_seconds: 30},
      # partition_count: 1 is REQUIRED for the Recorder's flush/1 barrier
      # to give per-request ordering. The Recorder's "all prior signals
      # processed" guarantee depends on per-sender FIFO from a single
      # bus partition. See Conversations.Recorder doc and the §G
      # acceptance gate "Bus restart resubscribe" / "Assistant ordering".
      {Jido.Signal.Bus, name: JidoClaw.SignalBus, partition_count: 1},
      JidoClaw.Conversations.RequestCorrelation.Cache,
      # Trace.Persistence + Trace.Sink.InMemory MUST start before
      # Trace.Collector: the Collector attaches telemetry handlers in init/1
      # and may immediately fan events out to whichever sink is configured.
      # Order: Persistence → Sink.InMemory → Collector — so anything the
      # Collector may write to on first event is already started for BOTH
      # sinks (the default Postgres sink rides Persistence; Sink.InMemory is
      # an idle bounded GenServer until selected via config).
      JidoClaw.Trace.Persistence,
      JidoClaw.Trace.Sink.InMemory,
      JidoClaw.Trace.Collector,
      JidoClaw.Conversations.Recorder,
      JidoClaw.Conversations.RequestCorrelation.Sweeper,
      # Hourly trace retention: prunes trace_runs/trace_events older than
      # trace[:retention_days]. Only needs Repo; no ordering constraint.
      JidoClaw.Trace.RetentionSweeper,
      # Hourly prototype retention (AR-8b-2 C3): opt-in TTL sweep of stale
      # `.prototypes/<uuid>/` dirs. Always started, inert when disabled
      # (`prototype_retention[:max_age_days]` nil by default). Filesystem +
      # WorkflowRun reference check; no ordering constraint beyond Repo.
      JidoClaw.VFS.PrototypeRetentionSweeper,
      JidoClaw.Audit.SignalListener
    ]

    List.flatten([
      # Infrastructure
      supervisor_child(JidoClaw.InfraSupervisor, infra_children, :one_for_one),

      # Forge sandbox execution engine
      supervisor_child(JidoClaw.Forge.Supervisor, forge_children(), :rest_for_one),

      # Code Server runtime management
      supervisor_child(JidoClaw.CodeServer.Supervisor, code_server_children(), :rest_for_one),

      # Finch HTTP pools
      {Finch, name: JidoClaw.Finch},

      # Embeddings — RatePacer must start AFTER Finch (Voyage HTTP)
      # and BackfillWorker must start AFTER RatePacer + Repo.
      JidoClaw.Embeddings.RatePacer,
      JidoClaw.Embeddings.BackfillWorker,

      # Telemetry
      JidoClaw.Telemetry,

      # Stats
      JidoClaw.Stats,

      # Password sign-in throttling lives outside the controller process so
      # concurrent requests share one per-node sliding window.
      JidoClaw.Web.AuthRateLimiter,
      JidoClaw.Web.SetupStatusCache,
      JidoClaw.Security.ToolApproval.MountConfigCache,

      # Supervised heartbeat writer for .jido/heartbeat.md.
      heartbeat_child(),

      # Background process tracking
      JidoClaw.BackgroundProcess.Registry,

      # Global session supervisor (fallback for non-tenant sessions)
      {DynamicSupervisor, name: JidoClaw.SessionSupervisor, strategy: :one_for_one},

      # Jido agent runtime
      JidoClaw.Jido,

      # Messaging runtime (rooms, agents, bridges — powered by jido_messaging)
      JidoClaw.Messaging,

      # Multi-tenancy
      supervisor_child(JidoClaw.TenantRuntimeSupervisor, tenant_children(), :rest_for_one),

      # Memory consolidator MCP server (always-on, scoped per-run
      # via the Bandit-fronted Plug.Router). The transport-internal
      # `start: true` is what Anubis's supervisor reads — a
      # top-level start option is silently ignored.
      {JidoClaw.Memory.Consolidator.MCPServer, transport: {:streamable_http, [start: true]}},

      # Executor-seam PR-2 deposit MCP server (always-on, scoped per-step via
      # the Bandit-fronted DepositPlug — the consolidator server's exact
      # pattern, including the transport-internal `start: true`). Internal
      # server: NOT part of the served-surface golden (JidoClaw.MCPServer only).
      {JidoClaw.Skills.Steps.ForgeExecutor.DepositServer,
       transport: {:streamable_http, [start: true]}},

      # Boot-time initializer: ensure the "system" tenant and
      # register platform cron jobs (memory consolidator tick).
      # Transient so a failure here surfaces loudly without
      # cascading into the rest of the supervision tree.
      %{
        id: JidoClaw.Memory.Consolidator.SystemJobsInitializer,
        start: {JidoClaw.Memory.Consolidator.SystemJobsInitializer, :start_link, [[]]},
        type: :worker,
        restart: :transient
      },

      # Boot-time workflow recovery: reconcile runs stranded non-terminal by
      # a crash. Self-gates off unless this node owns workflow execution
      # (single-node, non-MCP, non-clustered). Transient so a failure surfaces
      # without cascading. Runs after Repo (InfraSupervisor, above).
      %{
        id: JidoClaw.Orchestration.WorkflowRecovery,
        start: {JidoClaw.Orchestration.WorkflowRecovery, :start_link, [[]]},
        type: :worker,
        restart: :transient
      },

      # WS3 reclaim Pooler starts only AFTER the synchronous boot-recovery
      # barrier above. Its claims are fenced, but recovery's single-node sweep
      # intentionally is not; ordering removes the old heuristic overlap based
      # on `initial_delay_ms`. In MCP/cluster mode recovery is a synchronous
      # no-op, so the pool still starts normally in every mode.
      JidoClaw.Orchestration.ReclaimPooler,

      # WS4a cluster-wide user-cron owner: the leader loads/schedules every
      # non-disabled cron_jobs row for every active tenant; followers run none.
      # Placed after TenantRuntimeSupervisor (Tenant.Manager / cron_sup infra)
      # and co-located with the boot-reconcilers above. Serve-mode/test gated
      # (absent under :mcp; the suite starts its own under start_supervised).
      cron_owner_children(),

      # Solutions engine — Store + Reputation GenServers retired
      # in v0.6.1; Solutions live in Postgres now (see
      # JidoClaw.Solutions.Solution and JidoClaw.Solutions.Reputation
      # resources). Persistence is handled by the new BackfillWorker
      # added above.

      # Persistent memory — v0.6.3 replaces the GenServer + ETS + JSON
      # store with the Postgres-backed `JidoClaw.Memory.Domain`. No
      # supervised process: the API at `JidoClaw.Memory` is a thin
      # module of code-interface calls.

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

      # Doom-loop guard windows, keyed per {tenant, session, agent} —
      # in-memory and PER NODE (see the LoopGuard moduledoc). Present on
      # every surface (MCP serve mode included: MCP-driven turns are a
      # guarded target).
      JidoClaw.Agent.LoopGuard.Store,

      # External MCP tool consumption (JidoClaw.MCP.Consumer). After
      # AgentTracker — the `:prepared` rehydrate reads it to re-attach live
      # tracked agents. Serve-mode/test gated (absent under :mcp; stdio is
      # reserved for JSON-RPC there).
      mcp_consumer_children(),

      # Display coordinator (spinner, status bar, swarm box)
      JidoClaw.Display,

      # VFS/Profile/ServerRegistry/SessionManager dependency chain.
      supervisor_child(JidoClaw.Shell.Supervisor, shell_children(), :rest_for_one)
    ])
  end

  # External MCP consumer — gated off in MCP serve mode (stdio is JSON-RPC) and
  # in test (the suite starts its own under `start_supervised`); present in
  # `:cli`/`:gateway`/`:both`. The pure `Consumer.start?/2` keeps the gate
  # testable without mutating global runtime config.
  defp mcp_consumer_children do
    if MCPConsumer.start?(
         Application.get_env(:jido_claw, :serve_mode),
         Application.get_env(:jido_claw, :mcp_consumer_enabled?, true)
       ) do
      [MCPConsumer]
    else
      []
    end
  end

  # WS4a user-cron owner — gated off in MCP serve mode (stdio is JSON-RPC) and
  # in test (the suite starts its own under start_supervised). Present otherwise
  # (`:cli`/`:gateway`/`:both`). The pure `Owner.start?/2` keeps the gate
  # testable; the Owner's `init/1` self-gate is the belt-and-suspenders.
  defp cron_owner_children do
    enabled? =
      :jido_claw
      |> Application.get_env(:cron_owner, [])
      |> Keyword.get(:enabled?, true)

    if CronOwner.start?(Application.get_env(:jido_claw, :serve_mode), enabled?) do
      [CronOwner]
    else
      []
    end
  end

  defp supervisor_child(id, children, strategy) do
    %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: strategy, name: id]]},
      type: :supervisor
    }
  end

  defp heartbeat_child do
    %{
      id: JidoClaw.Heartbeat,
      start: {JidoClaw.Heartbeat, :start_link, [[project_dir: project_dir()]]},
      type: :worker,
      restart: :transient
    }
  end

  defp forge_children do
    List.flatten([
      {Registry, keys: :unique, name: JidoClaw.Forge.SessionRegistry},
      {DynamicSupervisor, name: JidoClaw.Forge.HarnessSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: JidoClaw.Forge.ExecSessionSupervisor, strategy: :one_for_one},
      forge_sandbox_children(),
      JidoClaw.Forge.Manager
    ])
  end

  defp code_server_children do
    [
      {Registry, keys: :unique, name: JidoClaw.CodeServer.RuntimeRegistry},
      {DynamicSupervisor, name: JidoClaw.CodeServer.RuntimeSupervisor, strategy: :one_for_one}
    ]
  end

  defp tenant_children do
    [
      JidoClaw.Tenant.Supervisor,
      JidoClaw.Tenant.Manager
    ]
  end

  defp shell_children do
    [
      # VFS workspace registry + supervisor must start before SessionManager so
      # SessionManager.start_new_session/3 can call Workspace.ensure_started/2.
      {Registry, keys: :unique, name: JidoClaw.VFS.WorkspaceRegistry},
      JidoClaw.VFS.WorkspaceSupervisor,

      # Profile manager must start before SessionManager so
      # SessionManager.start_new_session/3 can read the active env. The
      # read-only ETS mirror avoids a ProfileManager ↔ SessionManager
      # call cycle on the session-bootstrap path.
      {JidoClaw.Shell.ProfileManager, [project_dir: project_dir(), ets_mirror: true]},

      # SSH server registry must start before SessionManager so SSH routing
      # lookups can resolve; a registry crash restarts only SessionManager.
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
        [JidoClaw.Forge.Runner.HostShell]
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
      if Node.self() == :nonode@nohost do
        Logger.warning(
          "[JidoClaw] Clustering is enabled but Erlang distribution is not started — " <>
            "no nodes can connect. Start the BEAM with --name/--sname and a " <>
            "non-default distribution cookie (see README \"Clustering\")."
        )
      end

      topologies = JidoClaw.Cluster.topology()

      [
        # `:pg` scope + the leader-election GenServer restart TOGETHER under a
        # `:rest_for_one` sub-supervisor: a `:pg` crash restarts BOTH in order
        # (Leader re-inits → fresh join + monitor), so the Leader can never be
        # left holding a stale monitor ref against a restarted scope; a Leader
        # crash restarts only the Leader. The root supervisor is `:one_for_one`,
        # which would not give this coupling. libcluster's `Cluster.Supervisor`
        # stays an independent sibling (it manages Node connections, not the
        # `:pg` scope; the scope registers globally as `:jido_claw` regardless
        # of which supervisor starts it).
        supervisor_child(
          JidoClaw.Cluster.LeadershipSupervisor,
          [
            %{id: :pg_jido_claw, start: {:pg, :start_link, [:jido_claw]}},
            JidoClaw.Cluster.Leader
          ],
          :rest_for_one
        ),
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
      :mcp ->
        [
          # Resolve the MCP-mode default tool_context BEFORE the MCP
          # server starts publishing tools. The Solutions tools call
          # MCPScope.with_default/1 which falls back to the value stashed
          # at :jido_claw_mcp_default_scope.
          %{
            id: JidoClaw.MCPScope.Initializer,
            start: {JidoClaw.MCPScope.Initializer, :start_link, [[]]},
            type: :worker,
            restart: :transient
          },
          {JidoClaw.MCPServer, [transport: :stdio]}
        ]

      _ ->
        []
    end
  end

  @doc """
  Load `.env` files into the environment at boot.

  Walks `project_dir/.jido/.env`, `project_dir/.env`, `cwd/.jido/.env`,
  `cwd/.env` in that order. Each file is parsed with unset-only writes,
  so earlier (more specific) paths take precedence.
  """
  @spec load_dotenv() :: :ok
  def load_dotenv do
    project_dir = Application.get_env(:jido_claw, :project_dir) || File.cwd!()
    cwd = File.cwd!()

    # Order: most-specific → least-specific. Each parser uses unset-only
    # writes (parse_dotenv only writes when System.get_env returns nil),
    # so earlier paths take precedence over later ones.
    paths =
      Enum.uniq([
        Path.join([project_dir, ".jido", ".env"]),
        Path.join(project_dir, ".env"),
        Path.join([cwd, ".jido", ".env"]),
        Path.join(cwd, ".env")
      ])

    Enum.each(paths, fn path ->
      case File.read(path) do
        {:ok, content} ->
          parse_dotenv(content)
          Logger.debug("[JidoClaw] Loaded env from #{path}")

        _ ->
          :ok
      end
    end)
  end

  defp parse_dotenv(content) do
    content
    |> String.split("\n")
    |> Enum.each(&parse_dotenv_line/1)
  end

  defp parse_dotenv_line(line) do
    line = String.trim(line)

    cond do
      line == "" -> :skip
      String.starts_with?(line, "#") -> :skip
      true -> put_env_if_unset(line)
    end
  end

  defp put_env_if_unset(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        value =
          value
          |> String.trim()
          |> strip_quotes()

        # env vars take precedence over .env entries
        if System.get_env(key) == nil, do: System.put_env(key, value)

      _ ->
        :skip
    end
  end

  @doc """
  Redirect the default `:logger` handler to `:standard_error`.

  Called from the `mix jidoclaw` task so framework log output does not
  contaminate stdout (which the CLI uses for the REPL/MCP transport).
  """
  @spec redirect_logger_to_stderr() :: :ok | {:error, term()}
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
