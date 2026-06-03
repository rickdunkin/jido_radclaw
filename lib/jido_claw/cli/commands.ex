defmodule JidoClaw.CLI.Commands do
  @moduledoc """
  Slash command handler for the REPL.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.Branding
  alias JidoClaw.CLI.Commands.SolutionsStats
  alias JidoClaw.CLI.Formatter
  alias JidoClaw.CLI.Setup, as: CLISetup
  alias JidoClaw.Cron.Job, as: CronJob
  alias JidoClaw.Cron.Scheduler, as: CronScheduler
  alias JidoClaw.Cron.Worker, as: CronWorker
  alias JidoClaw.Display.StatusBar
  alias JidoClaw.Display.SwarmBox
  alias JidoClaw.Memory.Block, as: MemoryBlock
  alias JidoClaw.Memory.ConsolidationRun
  alias JidoClaw.Memory.Consolidator
  alias JidoClaw.Memory.Scope, as: MemoryScope
  alias JidoClaw.Reasoning.Statistics, as: ReasoningStatistics
  alias JidoClaw.Reasoning.StrategyRegistry
  alias JidoClaw.RuntimeOverview
  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.SessionManager, as: ShellSessionManager
  alias JidoClaw.Solutions.Matcher, as: SolutionsMatcher
  alias JidoClaw.SwarmView
  alias JidoClaw.Tenant.Manager, as: TenantManager
  alias JidoClaw.Workspaces.PolicyTransitions
  alias JidoClaw.Workspaces.Workspace

  def handle("/help", state) do
    IO.puts(Branding.help_text())
    {:ok, state}
  end

  def handle("/quit", state) do
    live = JidoClaw.Stats.get()
    elapsed = System.monotonic_time(:second) - state.started_at
    stats = Map.put(live, :elapsed, Formatter.format_elapsed(elapsed))
    IO.puts(Branding.goodbye(stats))
    :quit
  end

  def handle("/exit", state), do: handle("/quit", state)

  def handle("/clear", state) do
    IO.write("\e[2J\e[H")
    {:ok, state}
  end

  def handle("/reset", state) do
    actor = Actor.system(state.tenant_id)

    JidoClaw.reset_handoff(
      state.tenant_id,
      state.session_id,
      state.session_uuid,
      actor
    )

    IO.puts("  \e[2mHandoff ownership cleared. Next turn goes to main.\e[0m")
    {:ok, state}
  end

  def handle("/status", state) do
    alias JidoClaw.Config

    provider = Config.provider_label(state.config)
    live = JidoClaw.Stats.get()
    overview = runtime_overview(state)
    swarm = overview.swarm

    IO.puts("")

    # Status bar
    bar = JidoClaw.Display.render_status_bar()
    IO.puts(bar)

    IO.puts("")
    IO.puts("  \e[1mJIDOCLAW Status\e[0m")
    IO.puts("  \e[33m⚙\e[0m  model       \e[1m#{state.model}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  provider    \e[1m#{provider}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  cwd         \e[1m#{state.cwd}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  messages    \e[1m#{live.messages}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  tool calls  \e[1m#{live.tool_calls}\e[0m")

    IO.puts("  \e[33m⚙\e[0m  tokens      \e[1m#{StatusBar.format_tokens(live.tokens)}\e[0m")

    IO.puts(
      "  \e[33m⚙\e[0m  agents      \e[1m#{swarm.running_count} running / #{live.agents_spawned} total\e[0m"
    )

    IO.puts("  \e[33m⚙\e[0m  forge       \e[1m#{overview.forge.active_count} active\e[0m")

    IO.puts("  \e[33m⚙\e[0m  workflows   \e[1m#{overview.workflows.active_count} active\e[0m")

    elapsed = System.monotonic_time(:second) - state.started_at
    IO.puts("  \e[33m⚙\e[0m  uptime      \e[1m#{Formatter.format_elapsed(elapsed)}\e[0m")

    # Show per-agent breakdown if any children exist
    if swarm.agents != [] do
      IO.puts("")
      IO.puts(SwarmBox.render_header(swarm, terminal_cols()))
      IO.puts(SwarmBox.render_agents(swarm))
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/model " <> model_str, state) do
    model = String.trim(model_str)
    IO.puts("  \e[33m⚙\e[0m  Switching model to \e[1m#{model}\e[0m")
    IO.puts("  \e[2m(Model change takes effect on next query)\e[0m")
    {:ok, %{state | model: model}}
  end

  def handle("/model", state) do
    IO.puts("  Current model: \e[1m#{state.model}\e[0m")
    IO.puts("  Usage: /model <provider:model>")
    IO.puts("  \e[2mSee /models for available models\e[0m")
    {:ok, state}
  end

  def handle("/models", state) do
    alias JidoClaw.Config

    provider = Config.provider(state.config)
    provider_key = if Config.cloud?(state.config), do: "ollama_cloud", else: provider
    models = Config.default_models_for_provider(provider_key)

    IO.puts("")
    IO.puts("  \e[1mAvailable Models\e[0m  \e[2m(#{provider_key})\e[0m")
    IO.puts("")

    if models == [] do
      IO.puts("  \e[2mNo models listed for provider '#{provider_key}'.\e[0m")
    else
      print_model_list(models, state.model)
    end

    IO.puts("")
    IO.puts("  \e[2mSwitch: /model <provider:model>\e[0m")

    IO.puts(
      "  \e[2mAll providers: ollama, ollama_cloud, anthropic, openai, google, groq, xai, openrouter\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  def handle("/models " <> provider_key, state) do
    alias JidoClaw.Config
    key = String.trim(provider_key)
    models = Config.default_models_for_provider(key)

    IO.puts("")
    IO.puts("  \e[1mAvailable Models\e[0m  \e[2m(#{key})\e[0m")
    IO.puts("")

    if models == [] do
      IO.puts("  \e[2mNo models listed for provider '#{key}'.\e[0m")
    else
      print_model_list(models, state.model)
    end

    IO.puts("")
    IO.puts("  \e[2mSwitch: /model <provider:model>\e[0m")
    IO.puts("")
    {:ok, state}
  end

  def handle("/agents", state) do
    swarm = swarm_view(state)

    IO.puts("")

    if swarm.agents == [] do
      IO.puts("  \e[1mSwarm Dashboard\e[0m")
      IO.puts("  \e[2mNo child agents running.\e[0m")
    else
      IO.puts(SwarmBox.render_header(swarm, terminal_cols()))
      IO.puts(SwarmBox.render_agents(swarm))
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/skills", state) do
    skills = JidoClaw.Skills.all()

    IO.puts("")
    IO.puts("  \e[1mAvailable Skills\e[0m")

    if skills == [] do
      IO.puts("  \e[2mNo skills found. Add YAML files to .jido/skills/\e[0m")
    else
      Enum.each(skills, &print_skill_entry/1)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/memory search " <> query, state) do
    q = String.trim(query)
    tc = memory_tool_context(state)
    results = JidoClaw.Memory.recall(q, tool_context: tc)

    IO.puts("")
    IO.puts("  \e[1mMemory Search: #{q}\e[0m")

    if results == [] do
      IO.puts("  \e[2mNo memories found.\e[0m")
    else
      Enum.each(results, fn mem ->
        IO.puts("  \e[33m▸\e[0m \e[1m[#{mem.type}]\e[0m \e[1m#{mem.key}\e[0m")
        IO.puts("    \e[2m#{mem.content}\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/memory save " <> rest, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [key, content] ->
        tc = memory_tool_context(state)

        JidoClaw.Memory.remember_from_user(
          %{key: key, content: content, type: "fact"},
          tc
        )

        IO.puts("  \e[32m✓\e[0m  Saved memory: \e[1m#{key}\e[0m")

      _ ->
        IO.puts("  \e[31mUsage: /memory save <key> <content>\e[0m")
    end

    {:ok, state}
  end

  def handle("/memory forget " <> rest, state) do
    {label, source} = parse_forget_args(String.trim(rest))
    tc = memory_tool_context(state)

    JidoClaw.Memory.forget(label, tool_context: tc, source: source)

    IO.puts("  \e[32m✓\e[0m  Forgot: \e[1m#{label}\e[0m \e[2m(source: #{source})\e[0m")
    {:ok, state}
  end

  def handle("/memory blocks edit " <> label, state) do
    label = String.trim(label)

    case memory_scope(state) do
      {:ok, scope} ->
        edit_block_at_scope(scope, label)

      _ ->
        IO.puts("  \e[31mNo session scope — start a session first.\e[0m")
    end

    {:ok, state}
  end

  def handle("/memory blocks history " <> label, state) do
    label = String.trim(label)

    case memory_scope(state) do
      {:ok, scope} -> render_block_history(scope, label)
      _ -> IO.puts("  \e[31mNo session scope — start a session first.\e[0m")
    end

    {:ok, state}
  end

  def handle("/memory blocks", state) do
    case memory_scope(state) do
      {:ok, scope} -> render_scope_blocks(scope)
      _ -> IO.puts("  \e[31mNo session scope — start a session first.\e[0m")
    end

    {:ok, state}
  end

  def handle("/memory consolidate" <> _, state) do
    case memory_scope(state) do
      {:ok, scope} ->
        IO.puts("")
        IO.puts("  \e[2mConsolidating memory for #{scope.scope_kind} scope…\e[0m")

        case Consolidator.run_now(scope, override_min_input_count: true) do
          {:ok, run} ->
            IO.puts(
              "  \e[32m✓\e[0m  succeeded — facts_added=#{run.facts_added}, blocks_written=#{run.blocks_written}, blocks_revised=#{run.blocks_revised}"
            )

          {:error, :scope_busy} ->
            IO.puts("  \e[33m⚠\e[0m  consolidation already running for this scope")

          {:error, reason} ->
            IO.puts("  \e[31m✗\e[0m  consolidation failed: #{reason}")
        end

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  scope unresolved: #{inspect(reason)}")
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/memory status" <> _, state) do
    case memory_scope(state) do
      {:ok, scope} ->
        case ConsolidationRun.history_for_scope(
               %{
                 scope_kind: scope.scope_kind,
                 scope_fk_id: MemoryScope.primary_fk(scope),
                 limit: 10
               },
               tenant: scope.tenant_id,
               actor: Actor.system(scope.tenant_id)
             ) do
          {:ok, runs} -> render_run_history(runs)
          {:error, err} -> IO.puts("  \e[31m✗\e[0m  history fetch failed: #{inspect(err)}")
        end

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  scope unresolved: #{inspect(reason)}")
    end

    {:ok, state}
  end

  def handle("/memory", state) do
    tc = memory_tool_context(state)
    memories = JidoClaw.Memory.list_recent(tc, 20)

    IO.puts("")
    IO.puts("  \e[1mPersistent Memory\e[0m")

    if memories == [] do
      IO.puts("  \e[2mNo memories stored yet.\e[0m")
    else
      IO.puts("  \e[2m#{length(memories)} memories (most recent first)\e[0m")
      IO.puts("")

      Enum.each(memories, fn mem ->
        date = String.slice(mem.updated_at, 0, 10)
        IO.puts("  \e[33m▸\e[0m \e[1m[#{mem.type}]\e[0m \e[1m#{mem.key}\e[0m  \e[2m#{date}\e[0m")
        IO.puts("    \e[2m#{mem.content}\e[0m")
      end)
    end

    IO.puts("")

    IO.puts(
      "  \e[2mCommands: /memory blocks  /memory search <q>  /memory save <key> <content>  /memory forget <label> [--source model|user|all]\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  def handle("/solutions search " <> query, state) do
    q = String.trim(query)

    results =
      case session_scope(state) do
        {:ok, tenant_id, workspace_uuid} ->
          SolutionsMatcher.find_solutions(q,
            tenant_id: tenant_id,
            workspace_id: workspace_uuid,
            limit: 10
          )

        :missing ->
          []
      end

    IO.puts("")
    IO.puts("  \e[1mSolutions Search: #{q}\e[0m")

    if results == [] do
      IO.puts("  \e[2mNo solutions found.\e[0m")
    else
      IO.puts("  \e[2m#{length(results)} result(s)\e[0m")
      IO.puts("")
      Enum.each(results, &print_solution_result/1)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/solutions", state) do
    stats =
      case session_scope(state) do
        {:ok, tenant_id, workspace_uuid} ->
          SolutionsStats.fetch(tenant_id, workspace_uuid)

        :missing ->
          %{total: 0, by_language: %{}, by_framework: %{}}
      end

    IO.puts("")
    IO.puts("  \e[1mSolution Store\e[0m")
    IO.puts("  \e[33m⚙\e[0m  stored      \e[1m#{Map.get(stats, :total, 0)}\e[0m")

    by_lang = Map.get(stats, :by_language, %{})

    if map_size(by_lang) > 0 do
      langs = Enum.map_join(by_lang, ", ", fn {lang, n} -> "#{lang}: #{n}" end)
      IO.puts("  \e[33m⚙\e[0m  languages   \e[1m#{langs}\e[0m")
    end

    by_fw = Map.get(stats, :by_framework, %{})

    if map_size(by_fw) > 0 do
      fws = Enum.map_join(by_fw, ", ", fn {fw, n} -> "#{fw}: #{n}" end)
      IO.puts("  \e[33m⚙\e[0m  frameworks  \e[1m#{fws}\e[0m")
    end

    IO.puts("")
    IO.puts("  \e[2mCommands: /solutions search <query>\e[0m")
    IO.puts("")
    {:ok, state}
  end

  def handle("/network connect", state) do
    case JidoClaw.Network.Node.connect() do
      :ok ->
        IO.puts("  \e[32m✓\e[0m  Connected to agent network")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Failed to connect: #{inspect(reason)}")
    end

    {:ok, state}
  end

  def handle("/network disconnect", state) do
    :ok = JidoClaw.Network.Node.disconnect()
    IO.puts("  \e[32m✓\e[0m  Disconnected from agent network")

    {:ok, state}
  end

  def handle("/network peers", state) do
    peers = JidoClaw.Network.Node.peers()

    IO.puts("")
    IO.puts("  \e[1mNetwork Peers\e[0m")

    if peers == [] do
      IO.puts("  \e[2mNo peers connected.\e[0m")
    else
      IO.puts("  \e[2m#{length(peers)} peer(s)\e[0m")
      IO.puts("")

      Enum.each(peers, fn peer ->
        IO.puts("  \e[33m▸\e[0m \e[1m#{peer}\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/network", state) do
    status = JidoClaw.Network.Node.status()

    IO.puts("")
    IO.puts("  \e[1mNetwork Status\e[0m")
    IO.puts("  \e[33m⚙\e[0m  status      \e[1m#{Map.get(status, :status, :not_running)}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  agent_id    \e[1m#{Map.get(status, :agent_id) || "—"}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  peers       \e[1m#{Map.get(status, :peer_count, 0)}\e[0m")
    IO.puts("")
    IO.puts("  \e[2mCommands: /network connect  /network disconnect  /network peers\e[0m")
    IO.puts("")
    {:ok, state}
  end

  def handle("/setup", state) do
    new_config = CLISetup.run(state.cwd)
    new_model = JidoClaw.Config.model(new_config)
    {:ok, %{state | config: new_config, model: new_model}}
  end

  def handle("/config", state), do: handle("/setup", state)

  def handle("/gateway", state) do
    port = Branding.gateway_port()
    mode = Application.get_env(:jido_claw, :mode, :both)

    IO.puts("")
    IO.puts("  \e[1mGateway Status\e[0m")
    IO.puts("  \e[33m⚙\e[0m  mode        \e[1m#{mode}\e[0m")
    IO.puts("  \e[33m⚙\e[0m  port        \e[1m#{port}\e[0m")

    if mode in [:gateway, :both] do
      IO.puts("  \e[33m⚙\e[0m  health      \e[1mhttp://localhost:#{port}/health\e[0m")

      IO.puts(
        "  \e[33m⚙\e[0m  api         \e[1mhttp://localhost:#{port}/v1/chat/completions\e[0m"
      )

      IO.puts("  \e[33m⚙\e[0m  dashboard   \e[1mhttp://localhost:#{port}/dashboard\e[0m")
      IO.puts("  \e[33m⚙\e[0m  websocket   \e[1mws://localhost:#{port}/ws\e[0m")
    else
      IO.puts("  \e[2m  Gateway not running (mode: #{mode})\e[0m")
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/tenants", state) do
    tenants = TenantManager.list_tenants()

    IO.puts("")
    IO.puts("  \e[1mTenants\e[0m")

    if tenants == [] do
      IO.puts("  \e[2mNo tenants.\e[0m")
    else
      Enum.each(tenants, &print_tenant_row/1)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/cron add " <> rest, state) do
    case parse_cron_add(rest) do
      {:ok, id, schedule, task} -> add_cron_job(state, id, schedule, task)
      :error -> print_cron_add_usage(state)
    end
  end

  def handle("/cron remove " <> id, state) do
    id = String.trim(id)
    CronScheduler.unschedule("default", id)
    actor = Actor.system("default")

    case CronJob.by_job_id(id, tenant: "default", actor: actor) do
      {:ok, job} -> _ = CronJob.remove(job, tenant: "default", actor: actor)
      _ -> :ok
    end

    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Removed job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron trigger " <> id, state) do
    id = String.trim(id)
    CronScheduler.trigger("default", id)
    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Triggered job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron disable " <> id, state) do
    id = String.trim(id)
    CronWorker.disable("default", id)
    actor = Actor.system("default")

    case CronJob.by_job_id(id, tenant: "default", actor: actor) do
      {:ok, job} -> _ = CronJob.disable(job, tenant: "default", actor: actor)
      _ -> :ok
    end

    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Disabled job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron", state) do
    jobs = CronScheduler.list_jobs("default")

    IO.puts("")
    IO.puts("  \e[1mCron Jobs\e[0m")

    if jobs == [] do
      IO.puts("  \e[2mNo scheduled jobs. Use /cron add or ask the agent to schedule one.\e[0m")
    else
      Enum.each(jobs, &print_cron_job/1)
    end

    IO.puts("")

    IO.puts(
      "  \e[2mCommands: /cron add | /cron remove <id> | /cron trigger <id> | /cron disable <id>\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  def handle("/channels", state) do
    channels = JidoClaw.Channel.Supervisor.list_channels("default")

    IO.puts("")
    IO.puts("  \e[1mChannel Adapters\e[0m")

    if channels == [] do
      IO.puts("  \e[2mNo channels connected.\e[0m")
      IO.puts("  \e[2mConfigure: DISCORD_BOT_TOKEN, TELEGRAM_BOT_TOKEN\e[0m")
    else
      Enum.each(channels, &print_channel_row/1)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/strategies stats", state) do
    %{strategies: strategies, task_types: task_types} =
      ReasoningStatistics.summary()

    IO.puts("")
    IO.puts("  \e[1mStrategy Statistics\e[0m")
    IO.puts("")

    if strategies == [] do
      IO.puts("  \e[2mNo reasoning outcomes recorded yet.\e[0m")
    else
      Enum.each(strategies, fn %{
                                 strategy: name,
                                 samples: n,
                                 success_rate: sr,
                                 avg_duration_ms: dur
                               } ->
        pct = Float.round(sr * 100, 1)
        dur_ms = Float.round(dur, 0) |> trunc()

        IO.puts("  \e[32m▸\e[0m \e[1m#{name}\e[0m")

        IO.puts("    \e[2msamples=#{n}  success=#{pct}%  avg=#{dur_ms}ms\e[0m")
      end)
    end

    IO.puts("")
    IO.puts("  \e[1mBy Task Type\e[0m")
    IO.puts("")

    if task_types == [] do
      IO.puts("  \e[2mNo task-type data yet.\e[0m")
    else
      Enum.each(task_types, fn %{task_type: tt, samples: n, success_rate: sr} ->
        pct = Float.round(sr * 100, 1)
        IO.puts("  \e[33m▸\e[0m \e[1m#{tt}\e[0m  \e[2msamples=#{n}  success=#{pct}%\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/strategies", state) do
    strategies = StrategyRegistry.list()
    current = state.strategy

    IO.puts("")
    IO.puts("  \e[1mReasoning Strategies\e[0m")
    IO.puts("")

    # auto is a selector verb, not a registry entry — inject it at the top
    # of the list so /strategies leads with the recommended default.
    auto_active = if current == "auto", do: " \e[32m← active\e[0m", else: ""
    IO.puts("  \e[33m▸\e[0m \e[1mauto\e[0m#{auto_active}")

    IO.puts(
      "    \e[2mAutomatic selection — picks the best strategy per prompt (history + heuristics)\e[0m"
    )

    Enum.each(strategies, fn %{name: name, description: desc} = entry ->
      active = if name == current, do: " \e[32m← active\e[0m", else: ""
      label = strategy_label(entry)
      IO.puts("  \e[33m▸\e[0m \e[1m#{label}\e[0m#{active}")
      IO.puts("    \e[2m#{desc}\e[0m")
    end)

    IO.puts("")
    IO.puts("  \e[2mSwitch: /strategy <name>  ·  Stats: /strategies stats\e[0m")
    IO.puts("")
    {:ok, state}
  end

  def handle("/strategy " <> name_str, state) do
    name = String.trim(name_str)

    if name == "auto" or StrategyRegistry.valid?(name) do
      IO.puts("  \e[32m✓\e[0m  Reasoning preference set to \e[1m#{name}\e[0m")
      IO.puts("  \e[2m(The agent will see this preference on the next query)\e[0m")
      {:ok, %{state | strategy: name}}
    else
      IO.puts("  \e[31m✗\e[0m  Unknown strategy: \e[1m#{name}\e[0m")

      available =
        ["auto" | StrategyRegistry.list() |> Enum.map(& &1.name)]
        |> Enum.join(", ")

      IO.puts("  \e[2mAvailable: #{available}\e[0m")

      {:ok, state}
    end
  end

  def handle("/strategy", state) do
    current = state.strategy
    IO.puts("  Current preference: \e[1m#{current}\e[0m")
    IO.puts("  Usage: /strategy <name>")
    IO.puts("  \e[2mSee /strategies for all available strategies\e[0m")
    {:ok, state}
  end

  def handle("/profile " <> rest, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      ["list"] -> list_profiles(state)
      ["current"] -> print_profile_current(state)
      ["switch", name] -> switch_profile(state, String.trim(name))
      _ -> print_profile_usage(state)
    end
  end

  def handle("/profile", state), do: print_profile_current(state)

  def handle("/workspace " <> rest, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      ["embedding", policy] ->
        set_workspace_policy(state, :embedding, String.trim(policy))

      ["consolidation", policy] ->
        set_workspace_policy(state, :consolidation, String.trim(policy))

      _ ->
        print_workspace_usage(state)
    end
  end

  def handle("/workspace", state), do: print_workspace_usage(state)

  def handle("/servers " <> rest, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      ["list"] -> list_servers(state)
      ["current"] -> list_servers(state)
      ["test", name] -> test_server(state, String.trim(name))
      _ -> print_servers_usage(state)
    end
  end

  def handle("/servers", state), do: list_servers(state)

  def handle("/classify " <> prompt, state) do
    alias JidoClaw.Reasoning.Classifier

    prompt = String.trim(prompt)

    if prompt == "" do
      IO.puts("  \e[31mUsage:\e[0m /classify <prompt>")
      {:ok, state}
    else
      {:ok, strategy, confidence, profile} = Classifier.recommend_for(prompt)

      JidoClaw.SignalBus.emit("jido_claw.reasoning.classified", %{
        task_type: profile.task_type,
        complexity: profile.complexity,
        recommended_strategy: strategy,
        confidence: confidence
      })

      IO.puts("")
      IO.puts("  \e[1mClassification\e[0m")
      IO.puts("  \e[33m⚙\e[0m  task_type   \e[1m#{profile.task_type}\e[0m")
      IO.puts("  \e[33m⚙\e[0m  complexity  \e[1m#{profile.complexity}\e[0m")
      IO.puts("  \e[33m⚙\e[0m  domain      \e[1m#{profile.domain || "—"}\e[0m")
      IO.puts("  \e[33m⚙\e[0m  target      \e[1m#{profile.target || "—"}\e[0m")
      IO.puts("  \e[33m⚙\e[0m  word_count  \e[1m#{profile.word_count}\e[0m")
      IO.puts("")
      IO.puts("  \e[1mRecommendation\e[0m")
      IO.puts("  \e[32m▸\e[0m  strategy    \e[1m#{strategy}\e[0m")
      IO.puts("  \e[32m▸\e[0m  confidence  \e[1m#{Float.round(confidence, 2)}\e[0m")
      IO.puts("")
      {:ok, state}
    end
  end

  def handle("/classify", state) do
    IO.puts("  Usage: /classify <prompt>")

    IO.puts(
      "  \e[2mPrints the task profile and recommended reasoning strategy (no execution).\e[0m"
    )

    {:ok, state}
  end

  def handle("/upgrade-prompt", state) do
    alias JidoClaw.Agent.Prompt

    case Prompt.upgrade(state.cwd) do
      {:ok, %{backup: backup}} ->
        IO.puts("  \e[32m✓\e[0m  Upgraded .jido/system_prompt.md to the new default")
        IO.puts("  \e[2m   Previous version saved to #{Path.basename(backup)}\e[0m")
        {:ok, state}

      {:error, :no_sidecar} ->
        IO.puts("  \e[33m⚠\e[0m  No pending upgrade — .jido/system_prompt.md.default not found")

        IO.puts(
          "  \e[2m   A sidecar appears only when the bundled default differs from your local copy.\e[0m"
        )

        {:ok, state}

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Upgrade failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle("/" <> unknown, state) do
    IO.puts("  \e[31mUnknown command: /#{unknown}\e[0m  (try /help)")
    {:ok, state}
  end

  # -- Session-scope helper --
  # Reads tenant_id + workspace_uuid from the REPL state struct (set
  # during `ensure_persisted_session/3` at REPL start). Returns
  # `:missing` when persistence wasn't reachable at boot (degraded
  # mode — see repl.ex:506).
  defp session_scope(%{tenant_id: tenant_id, workspace_uuid: workspace_uuid})
       when is_binary(tenant_id) and is_binary(workspace_uuid) do
    {:ok, tenant_id, workspace_uuid}
  end

  defp session_scope(_state), do: :missing

  # -- Memory helpers --

  # Builds a tool_context map for Memory calls from REPL state. Empty
  # map when state is degraded (Memory write paths bail out cleanly).
  defp memory_tool_context(state) do
    %{
      tenant_id: Map.get(state, :tenant_id),
      user_id: Map.get(state, :user_id),
      workspace_uuid: Map.get(state, :workspace_uuid),
      session_uuid: Map.get(state, :session_uuid)
    }
  end

  defp swarm_view(state) do
    runtime_overview(state).swarm
  end

  defp runtime_overview(state) do
    scope = %{
      tenant_id: state.tenant_id,
      session_id: state.session_id,
      session_uuid: Map.get(state, :session_uuid),
      workspace_uuid: Map.get(state, :workspace_uuid),
      workspace_id: Map.get(state, :workspace_uuid)
    }

    case RuntimeOverview.snapshot(scope) do
      {:ok, overview} ->
        overview

      {:error, _} ->
        empty_runtime_overview(Map.get(state, :tenant_id))
    end
  end

  defp empty_runtime_overview(tenant_id) do
    %RuntimeOverview{
      tenant_id: tenant_id,
      swarm: %SwarmView{tenant_id: tenant_id, generated_at: DateTime.utc_now()},
      forge: %JidoClaw.ForgeView{tenant_id: tenant_id, generated_at: DateTime.utc_now()},
      workflows: %JidoClaw.WorkflowView{tenant_id: tenant_id, generated_at: DateTime.utc_now()},
      uptime: %{seconds: 0, agents_spawned: 0},
      generated_at: DateTime.utc_now()
    }
  end

  defp render_run_history([]) do
    IO.puts("")
    IO.puts("  \e[2mNo consolidation runs recorded for this scope.\e[0m")
    IO.puts("")
  end

  defp render_run_history(runs) do
    IO.puts("")
    IO.puts("  \e[1mConsolidation Runs\e[0m  \e[2m(most recent first)\e[0m")
    IO.puts("")

    Enum.each(runs, fn run ->
      icon =
        case run.status do
          :succeeded -> "\e[32m✓\e[0m"
          :skipped -> "\e[33m∅\e[0m"
          :failed -> "\e[31m✗\e[0m"
        end

      ts = DateTime.to_iso8601(run.started_at)
      err = if run.error in [nil, ""], do: "", else: "  \e[2m— #{run.error}\e[0m"

      IO.puts(
        "  #{icon}  #{ts}  \e[1m#{run.status}\e[0m  facts=#{run.facts_added}/#{run.facts_invalidated}  blocks=#{run.blocks_written}#{err}"
      )
    end)

    IO.puts("")
  end

  defp memory_scope(state) do
    MemoryScope.resolve(memory_tool_context(state))
  end

  defp primary_fk(%{scope_kind: :user, user_id: id}), do: id
  defp primary_fk(%{scope_kind: :workspace, workspace_id: id}), do: id
  defp primary_fk(%{scope_kind: :project, project_id: id}), do: id
  defp primary_fk(%{scope_kind: :session, session_id: id}), do: id

  # Parse `<label>` or `<label> --source model|user|all`.
  defp parse_forget_args(input) do
    case String.split(input, "--source", parts: 2) do
      [label] ->
        {String.trim(label), :user_save}

      [label, source_part] ->
        source =
          source_part
          |> String.trim()
          |> case do
            "model" -> :model_remember
            "user" -> :user_save
            "all" -> :all
            _ -> :user_save
          end

        {String.trim(label), source}
    end
  end

  defp format_short_date(%DateTime{} = dt), do: dt |> DateTime.to_iso8601() |> String.slice(0, 10)
  defp format_short_date(other) when is_binary(other), do: String.slice(other, 0, 10)
  defp format_short_date(_), do: ""

  defp terminal_cols do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 120
    end
  end

  # -- Cron Helpers --

  defp parse_cron_add(input) do
    # Format: <id> "<schedule>" <task...>
    case Regex.run(~r/^(\S+)\s+"([^"]+)"\s+(.+)$/s, String.trim(input)) do
      [_, id, schedule, task] -> {:ok, id, schedule, String.trim(task)}
      nil -> :error
    end
  end

  defp format_cron_schedule({:cron, expr}), do: "cron: #{expr}"

  defp format_cron_schedule({:every, ms}) when ms >= 86_400_000,
    do: "every #{div(ms, 86_400_000)}d"

  defp format_cron_schedule({:every, ms}) when ms >= 3_600_000, do: "every #{div(ms, 3_600_000)}h"
  defp format_cron_schedule({:every, ms}) when ms >= 60_000, do: "every #{div(ms, 60_000)}m"
  defp format_cron_schedule({:every, ms}), do: "every #{div(ms, 1000)}s"
  defp format_cron_schedule({:at, dt}), do: "at: #{DateTime.to_iso8601(dt)}"
  defp format_cron_schedule(other), do: inspect(other)

  defp format_relative_time(dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> "now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "#{div(diff, 86_400)}d"
    end
  end

  defp cron_unit_ms("s"), do: 1_000
  defp cron_unit_ms("m"), do: 60_000
  defp cron_unit_ms("h"), do: 3_600_000
  defp cron_unit_ms("d"), do: 86_400_000
  defp cron_unit_ms(_), do: 60_000

  defp persistable_schedule({:cron, expr}), do: {:cron, expr}
  defp persistable_schedule({:every, ms}), do: {:every, Integer.to_string(ms)}

  defp strategy_label(%{name: name, display_name: display})
       when is_binary(display) and display != "" do
    "#{display} (#{name})"
  end

  defp strategy_label(%{name: name}), do: name

  # -- Profile helpers --

  defp list_profiles(state) do
    alias JidoClaw.Shell.ProfileManager

    current = ProfileManager.current(state.session_id)
    names = ProfileManager.list()

    IO.puts("")
    IO.puts("  \e[1mEnvironment Profiles\e[0m")
    IO.puts("")

    Enum.each(names, fn name ->
      active = if name == current, do: " \e[32m← active\e[0m", else: ""

      {key_count, label} =
        case ProfileManager.get(name) do
          {:ok, env} -> {map_size(env), if(name == "default", do: "base", else: "override")}
          {:error, _} -> {0, "—"}
        end

      IO.puts("  \e[33m▸\e[0m \e[1m#{name}\e[0m#{active}  \e[2m#{key_count} keys (#{label})\e[0m")
    end)

    IO.puts("")
    IO.puts("  \e[2mSwitch: /profile switch <name>  ·  Show: /profile current\e[0m")
    IO.puts("")
    {:ok, state}
  end

  defp print_profile_current(state) do
    alias JidoClaw.Security.Redaction.Env, as: EnvRedaction
    alias JidoClaw.Shell.ProfileManager

    current = ProfileManager.current(state.session_id)
    env = ProfileManager.active_env(state.session_id)

    IO.puts("")
    IO.puts("  \e[1mActive Profile\e[0m  \e[1m#{current}\e[0m")
    IO.puts("")

    if map_size(env) == 0 do
      IO.puts("  \e[2mNo variables in this profile.\e[0m")
    else
      env
      |> Enum.sort()
      |> Enum.each(fn {k, v} ->
        redacted = EnvRedaction.redact_value(k, v)
        IO.puts("  \e[33m⚙\e[0m  \e[1m#{k}\e[0m=#{redacted}")
      end)
    end

    IO.puts("")
    IO.puts("  \e[2mUsage: /profile list  ·  /profile switch <name>\e[0m")
    IO.puts("")
    {:ok, state}
  end

  defp switch_profile(state, name) do
    alias JidoClaw.Shell.ProfileManager

    case ProfileManager.switch(state.session_id, name) do
      {:ok, ^name} ->
        IO.puts("  \e[32m✓\e[0m  Switched to profile \e[1m#{name}\e[0m")
        IO.puts("  \e[2m(New shell commands will use the profile's env)\e[0m")
        JidoClaw.Display.set_profile(name)
        {:ok, %{state | profile: name}}

      {:error, :unknown_profile} ->
        IO.puts("  \e[31m✗\e[0m  Unknown profile: \e[1m#{name}\e[0m")

        available = ProfileManager.list() |> Enum.join(", ")

        IO.puts("  \e[2mAvailable: #{available}\e[0m")
        {:ok, state}

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Switch failed: \e[1m#{inspect(reason)}\e[0m")
        {:ok, state}
    end
  end

  defp print_profile_usage(state) do
    IO.puts("  Usage: /profile [list | current | switch <name>]")
    {:ok, state}
  end

  # -- Workspace policy helpers --

  defp set_workspace_policy(state, :embedding, policy_str) do
    apply_workspace_policy(state, :embedding, parse_policy(policy_str), policy_str)
  end

  defp set_workspace_policy(state, :consolidation, policy_str) do
    apply_workspace_policy(state, :consolidation, parse_policy(policy_str), policy_str)
  end

  defp apply_workspace_policy(state, _kind, :error, raw) do
    IO.puts("  \e[31m✗\e[0m  '#{raw}' is not a valid policy. Use one of: default, disabled.")

    {:ok, state}
  end

  defp apply_workspace_policy(state, kind, {:ok, policy}, _raw) do
    case state.workspace_uuid do
      nil ->
        IO.puts(
          "  \e[33m⚠\e[0m  workspace persistence isn't available — policy not applied. " <>
            "Restart the REPL once the database is reachable."
        )

        {:ok, state}

      uuid when is_binary(uuid) ->
        commit_workspace_policy(state, kind, policy, uuid)
    end
  end

  defp commit_workspace_policy(state, kind, policy, uuid) do
    actor = Actor.system(state.tenant_id)

    with {:ok, workspace} <-
           Workspace.by_id(uuid, tenant: state.tenant_id, actor: actor),
         {:ok, _} <- apply_policy_action(workspace, kind, policy, state.tenant_id, actor) do
      IO.puts(
        "  \e[32m✓\e[0m  workspace #{kind} policy set to \e[1m#{Atom.to_string(policy)}\e[0m"
      )

      maybe_apply_embedding_transition(kind, workspace, policy)
      {:ok, state}
    else
      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Failed to set workspace policy: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp maybe_apply_embedding_transition(:embedding, workspace, policy),
    do: apply_embedding_transition(workspace, policy)

  defp maybe_apply_embedding_transition(_, _, _), do: :ok

  defp apply_policy_action(workspace, :embedding, policy, tenant, actor),
    do:
      Workspace.set_embedding_policy(workspace, policy,
        tenant: tenant,
        actor: actor
      )

  defp apply_policy_action(workspace, :consolidation, policy, tenant, actor),
    do:
      Workspace.set_consolidation_policy(workspace, policy,
        tenant: tenant,
        actor: actor
      )

  defp parse_policy("default"), do: {:ok, :default}
  defp parse_policy("disabled"), do: {:ok, :disabled}
  defp parse_policy(_), do: :error

  defp print_workspace_usage(state) do
    IO.puts("  Usage:")
    IO.puts("    /workspace embedding <default|disabled>")
    IO.puts("    /workspace consolidation <default|disabled>")
    {:ok, state}
  end

  # Apply the §1.4 row-status fix-up table for embedding policy
  # transitions. Synchronous bounded UPDATE only; very large
  # workspaces should consider migrating in batches (deferred to
  # v0.7+).
  defp apply_embedding_transition(workspace, new_policy) do
    PolicyTransitions.apply_embedding(workspace.id, new_policy)
  end

  # -- Servers helpers --

  defp list_servers(state) do
    rows =
      ServerRegistry.list()
      |> Enum.map(fn name ->
        case ServerRegistry.get(name) do
          {:ok, entry} -> build_server_row(name, entry, state.cwd)
          {:error, :not_found} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    IO.puts("")
    IO.puts("  \e[1mDeclared Servers\e[0m")
    IO.puts("")

    if rows == [] do
      IO.puts("  \e[2mNo servers declared in .jido/config.yaml\e[0m")
      IO.puts("")
      {:ok, state}
    else
      name_w = column_width(rows, :name, "name")
      target_w = column_width(rows, :target, "user@host:port")
      auth_w = column_width(rows, :auth, "auth")
      status_w = column_width(rows, :status, "status")

      header =
        "    " <>
          String.pad_trailing("name", name_w) <>
          "  " <>
          String.pad_trailing("user@host:port", target_w) <>
          "  " <>
          String.pad_trailing("auth", auth_w) <>
          "  " <>
          String.pad_trailing("status", status_w) <>
          "  " <> "env"

      IO.puts("  \e[2m#{header}\e[0m")

      Enum.each(rows, fn row ->
        name_padded = String.pad_trailing(row.name, name_w)
        target_padded = String.pad_trailing(row.target, target_w)
        auth_padded = String.pad_trailing(row.auth, auth_w)
        status_padded = String.pad_trailing(row.status, status_w)
        colored_name = "\e[1m#{name_padded}\e[0m"
        colored_status = colorize_server_status(row.status_atom, status_padded)

        IO.puts(
          "  \e[33m▸\e[0m " <>
            colored_name <>
            "  " <>
            target_padded <>
            "  " <> auth_padded <> "  " <> colored_status <> "  " <> row.env_label
        )
      end)

      IO.puts("")
      IO.puts("  \e[2mTest: /servers test <name>\e[0m")
      IO.puts("")
      {:ok, state}
    end
  end

  defp build_server_row(name, entry, project_dir) do
    target = "#{entry.user}@#{entry.host}:#{entry.port}"
    auth = Atom.to_string(entry.auth_kind)
    {status_atom, status_str} = compute_server_status(entry, project_dir)
    env_count = map_size(entry.env)

    env_label =
      case env_count do
        1 -> "1 env var"
        n -> "#{n} env vars"
      end

    %{
      name: name,
      target: target,
      auth: auth,
      status: status_str,
      status_atom: status_atom,
      env_label: env_label
    }
  end

  defp compute_server_status(%{auth_kind: :default}, _project_dir), do: {:unchecked, "unchecked"}

  defp compute_server_status(%{auth_kind: :password} = entry, _project_dir) do
    case ServerRegistry.resolve_secrets(entry) do
      {:ok, _} -> {:ok, "ok"}
      {:error, {:missing_env, _}} -> {:missing_env, "missing_env"}
    end
  end

  defp compute_server_status(%{auth_kind: :key_path, key_path: kp}, project_dir) do
    resolved = ServerRegistry.resolve_key_path(kp, project_dir)

    case File.read(resolved) do
      {:ok, _} -> {:ok, "ok"}
      {:error, :enoent} -> {:missing_key, "missing_key"}
      {:error, _} -> {:unreadable_key, "unreadable_key"}
    end
  end

  defp colorize_server_status(:ok, padded), do: "\e[32m#{padded}\e[0m"

  defp colorize_server_status(status, padded)
       when status in [:missing_env, :missing_key, :unreadable_key],
       do: "\e[31m#{padded}\e[0m"

  defp colorize_server_status(:unchecked, padded), do: "\e[33m#{padded}\e[0m"
  defp colorize_server_status(_, padded), do: padded

  defp column_width(rows, key, header) do
    data_max =
      rows
      |> Enum.map(&(Map.fetch!(&1, key) |> String.length()))
      |> Enum.max(fn -> 0 end)

    max(data_max, String.length(header))
  end

  defp test_server(state, name) do
    case ShellSessionManager.run(
           state.session_id,
           "echo ok",
           5_000,
           project_dir: state.cwd,
           backend: :ssh,
           server: name
         ) do
      {:ok, _} ->
        IO.puts("  \e[32m✓\e[0m  \e[1m#{name}\e[0m reachable")
        {:ok, state}

      {:error, message} ->
        IO.puts("  \e[31m✗\e[0m  \e[1m#{name}\e[0m: #{message}")
        {:ok, state}
    end
  end

  defp print_servers_usage(state) do
    IO.puts("  Usage: /servers [list | current | test <name>]")
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # /memory blocks edit <label>
  # ---------------------------------------------------------------------------

  defp edit_block_at_scope(scope, label) do
    case JidoClaw.Memory.list_blocks_for_scope_chain(scope) do
      [] ->
        IO.puts("  \e[33m⚠\e[0m  no blocks visible at the active scope")

      blocks ->
        case Enum.find(blocks, &(&1.label == label)) do
          nil ->
            IO.puts("  \e[33m⚠\e[0m  no block with label \e[1m#{label}\e[0m at the active scope")

          block ->
            edit_and_save_block(scope, block)
        end
    end
  end

  defp edit_and_save_block(scope, block) do
    do_edit_block(scope, block, block.value)
  end

  defp do_edit_block(scope, block, initial) do
    case open_in_editor(initial, label_to_filename(block.label)) do
      {:ok, new_value} ->
        cond do
          new_value == block.value ->
            IO.puts("  \e[2m   No changes detected.\e[0m")

          byte_size(new_value) > block.char_limit ->
            IO.puts(
              "  \e[31m✗\e[0m  Block exceeds char_limit (#{byte_size(new_value)} > #{block.char_limit}). Re-opening editor..."
            )

            do_edit_block(scope, block, new_value)

          true ->
            apply_block_edit(scope, block, new_value)
        end

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Editor failed: #{inspect(reason)}")
    end
  end

  defp apply_block_edit(scope, block, new_value) do
    same_scope? = same_scope?(scope, block)

    result =
      if same_scope? do
        MemoryBlock.revise(block, %{value: new_value}, actor: Actor.system(scope.tenant_id))
      else
        attrs = %{
          scope_kind: scope.scope_kind,
          user_id: scope.user_id,
          workspace_id: scope.workspace_id,
          project_id: scope.project_id,
          session_id: scope.session_id,
          label: block.label,
          description: block.description,
          value: new_value,
          char_limit: block.char_limit,
          pinned: block.pinned,
          position: block.position,
          source: :user_save,
          written_by: "cli"
        }

        MemoryBlock.write(attrs,
          tenant: scope.tenant_id,
          actor: Actor.system(scope.tenant_id)
        )
      end

    case result do
      {:ok, written} ->
        kind = if same_scope?, do: "revised", else: "override created"
        IO.puts("  \e[32m✓\e[0m  block #{kind} (id=#{written.id})")

      {:error, err} ->
        IO.puts("  \e[31m✗\e[0m  Block write failed: #{inspect(err)}")
    end
  end

  defp same_scope?(scope, block) do
    scope.scope_kind == block.scope_kind and
      primary_fk(scope) == block_primary_fk(block)
  end

  defp block_primary_fk(%{scope_kind: :user, user_id: id}), do: id
  defp block_primary_fk(%{scope_kind: :workspace, workspace_id: id}), do: id
  defp block_primary_fk(%{scope_kind: :project, project_id: id}), do: id
  defp block_primary_fk(%{scope_kind: :session, session_id: id}), do: id
  defp block_primary_fk(_), do: nil

  defp open_in_editor(initial_content, suffix) do
    [editor | extra_args] =
      (System.get_env("EDITOR") || "vi")
      |> String.split(~r/\s+/, trim: true)
      |> case do
        [] -> ["vi"]
        parts -> parts
      end

    tmp_dir = System.tmp_dir!()
    tmp_path = Path.join(tmp_dir, "jido_block_#{System.unique_integer([:positive])}_#{suffix}")

    try do
      File.write!(tmp_path, initial_content)

      case System.cmd(editor, Enum.concat(extra_args, [tmp_path]), into: IO.stream(:stdio, :line)) do
        {_, 0} ->
          File.read(tmp_path)

        {_, exit_code} ->
          {:error, {:editor_exit, exit_code}}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp label_to_filename(label) when is_binary(label) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_.-]+/, label, "_")
    "#{safe}.md"
  end

  defp label_to_filename(_), do: "block.md"

  # -- /models helpers --

  defp print_model_list(models, current_model) do
    alias JidoClaw.Config

    Enum.each(models, fn model ->
      desc = Config.model_description(model)
      active = if model == current_model, do: " \e[32m← active\e[0m", else: ""
      IO.puts("  \e[33m▸\e[0m \e[1m#{model}\e[0m  \e[2m#{desc}\e[0m#{active}")
    end)
  end

  # -- /skills helpers --

  defp print_skill_entry(skill) do
    IO.puts("  \e[33m▸\e[0m \e[1m#{skill.name}\e[0m — #{skill.description}")
    Enum.each(skill.steps, &print_skill_step/1)
  end

  defp print_skill_step(step) do
    template = Map.get(step, :template)
    task = Map.get(step, :task)
    IO.puts("    \e[2m→ #{template}: #{task}\e[0m")
  end

  # -- /memory blocks helpers --

  defp render_block_history(scope, label) do
    case MemoryBlock.history_for_label(
           scope.scope_kind,
           primary_fk(scope),
           label,
           tenant: scope.tenant_id,
           actor: Actor.system(scope.tenant_id)
         ) do
      {:ok, revisions} -> print_block_revisions(label, revisions)
      {:error, err} -> IO.puts("  \e[31mError: #{inspect(err)}\e[0m")
    end
  end

  defp print_block_revisions(label, revisions) do
    IO.puts("")
    IO.puts("  \e[1mBlock History: #{label}\e[0m")

    if revisions == [] do
      IO.puts("  \e[2mNo history for this label.\e[0m")
    else
      Enum.each(revisions, &print_block_revision/1)
    end

    IO.puts("")
  end

  defp print_block_revision(block) do
    ts = format_short_date(block.inserted_at)
    IO.puts("  \e[33m▸\e[0m \e[1m#{ts}\e[0m \e[2m(#{block.source})\e[0m")
    IO.puts("    \e[2m#{block.value}\e[0m")
  end

  defp render_scope_blocks(scope) do
    chain =
      MemoryScope.chain(scope)
      |> Enum.map(&%{scope_kind: elem(&1, 0), fk_id: elem(&1, 1)})

    case MemoryBlock.for_scope_chain(chain,
           tenant: scope.tenant_id,
           actor: Actor.system(scope.tenant_id)
         ) do
      {:ok, blocks} -> print_scope_blocks(blocks)
      {:error, err} -> IO.puts("  \e[31mError: #{inspect(err)}\e[0m")
    end
  end

  defp print_scope_blocks(blocks) do
    IO.puts("")
    IO.puts("  \e[1mScope Blocks\e[0m")

    if blocks == [] do
      IO.puts("  \e[2mNo blocks for this scope.\e[0m")
    else
      IO.puts("  \e[2m#{length(blocks)} block(s)\e[0m")
      IO.puts("")
      Enum.each(blocks, &print_scope_block/1)
    end

    IO.puts("")
  end

  defp print_scope_block(b) do
    IO.puts("  \e[33m▸\e[0m \e[1m#{b.label}\e[0m \e[2m(#{b.scope_kind}, pos=#{b.position})\e[0m")

    IO.puts("    \e[2m#{b.value}\e[0m")
  end

  # -- /solutions helpers --

  defp print_solution_result(%{solution: sol}) do
    lang = if sol.language, do: " \e[36m[#{sol.language}]\e[0m", else: ""
    preview = sol.solution_content |> String.slice(0, 80) |> String.replace("\n", " ")
    IO.puts("  \e[33m▸\e[0m \e[1m#{sol.id}\e[0m#{lang}")
    IO.puts("    \e[2m#{preview}\e[0m")
  end

  # -- /tenants helpers --

  defp print_tenant_row(t) do
    status_color = if t.status == :active, do: "\e[32m", else: "\e[33m"
    IO.puts("  \e[33m▸\e[0m \e[1m#{t.name}\e[0m (#{t.id})  #{status_color}#{t.status}\e[0m")
  end

  # -- /cron add helpers --

  defp add_cron_job(state, id, schedule, task) do
    schedule_tuple = parse_cron_schedule(schedule)
    opts = [id: id, task: task, schedule: schedule_tuple, mode: :main]

    case CronScheduler.schedule("default", opts) do
      {:ok, ^id, _pid} -> persist_cron_job(id, task, schedule, schedule_tuple)
      {:error, reason} -> print_cron_schedule_error(reason)
    end

    {:ok, state}
  end

  defp parse_cron_schedule("every " <> _ = schedule) do
    case Regex.run(~r/^every\s+(\d+)\s*(s|m|h|d)$/i, schedule) do
      [_, amount, unit] ->
        ms = String.to_integer(amount) * cron_unit_ms(String.downcase(unit))
        {:every, ms}

      nil ->
        {:cron, schedule}
    end
  end

  defp parse_cron_schedule(schedule), do: {:cron, schedule}

  defp persist_cron_job(id, task, schedule, schedule_tuple) do
    {kind, value} = persistable_schedule(schedule_tuple)

    persist_attrs = %{
      job_id: id,
      task: task,
      mode: :main,
      schedule_kind: kind,
      schedule_value: value
    }

    case CronJob.upsert(persist_attrs, tenant: "default", actor: Actor.system("default")) do
      {:ok, _} -> print_cron_persist_ok(id, task, schedule)
      {:error, err} -> print_cron_persist_warn(err)
    end
  end

  defp print_cron_persist_ok(id, task, schedule) do
    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Scheduled '\e[1m#{id}\e[0m': \"#{task}\" (#{schedule})")
    IO.puts("  \e[2mPersisted to cron_jobs\e[0m")
    IO.puts("")
  end

  defp print_cron_persist_warn(err) do
    IO.puts("")
    IO.puts("  \e[33m⚠\e[0m Scheduled but persistence failed: #{inspect(err)}")
    IO.puts("")
  end

  defp print_cron_schedule_error(reason) do
    IO.puts("")
    IO.puts("  \e[31m✗\e[0m Failed to schedule: #{inspect(reason)}")
    IO.puts("")
  end

  defp print_cron_add_usage(state) do
    IO.puts("")
    IO.puts("  \e[33mUsage:\e[0m /cron add <id> \"<schedule>\" <task description>")

    IO.puts(
      "  \e[2mExample: /cron add daily-tests \"0 9 * * *\" Run mix test and report results\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  defp print_cron_job(job) do
    status_icon = cron_status_icon(job.status)
    schedule_str = format_cron_schedule(job.schedule)
    next_str = if job.next_run, do: " next: #{format_relative_time(job.next_run)}", else: ""

    IO.puts("  #{status_icon} \e[1m#{job.id}\e[0m  #{schedule_str}#{next_str}")

    IO.puts(
      "    \e[2m\"#{job.task}\"\e[0m  #{cron_target_label(job)}failures: #{job.failure_count}"
    )
  end

  defp cron_target_label(%{target: :workflow, workflow_name: name}), do: "workflow: #{name}  "
  defp cron_target_label(%{target: target}) when not is_nil(target), do: "target: #{target}  "
  defp cron_target_label(_), do: ""

  defp cron_status_icon(:active), do: "\e[32m●\e[0m"
  defp cron_status_icon(:disabled), do: "\e[31m✗\e[0m"
  defp cron_status_icon(:stuck), do: "\e[33m⚠\e[0m"
  defp cron_status_icon(_), do: "\e[2m○\e[0m"

  # -- /channels helpers --

  defp print_channel_row(ch) do
    status_color = if ch.status == :connected, do: "\e[32m", else: "\e[33m"
    IO.puts("  \e[33m▸\e[0m \e[1m#{ch.platform}\e[0m  #{status_color}#{ch.status}\e[0m")
  end
end
