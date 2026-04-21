defmodule JidoClaw.CLI.Commands do
  @moduledoc """
  Slash command handler for the REPL.
  """

  alias JidoClaw.CLI.Branding

  def handle("/help", state) do
    IO.puts(Branding.help_text())
    {:ok, state}
  end

  def handle("/quit", state) do
    live = JidoClaw.Stats.get()
    elapsed = System.monotonic_time(:second) - state.started_at
    stats = Map.put(live, :elapsed, format_elapsed(elapsed))
    IO.puts(Branding.goodbye(stats))
    :quit
  end

  def handle("/exit", state), do: handle("/quit", state)

  def handle("/clear", state) do
    IO.write("\e[2J\e[H")
    {:ok, state}
  end

  def handle("/status", state) do
    alias JidoClaw.Config

    provider = Config.provider_label(state.config)
    live = JidoClaw.Stats.get()
    tracker = JidoClaw.AgentTracker.get_state()
    children = tracker.agents |> Enum.reject(fn {id, _} -> id == "main" end)
    running = Enum.count(children, fn {_, a} -> a.status == :running end)

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

    IO.puts(
      "  \e[33m⚙\e[0m  tokens      \e[1m#{JidoClaw.Display.StatusBar.format_tokens(live.tokens)}\e[0m"
    )

    IO.puts(
      "  \e[33m⚙\e[0m  agents      \e[1m#{running} running / #{live.agents_spawned} total\e[0m"
    )

    elapsed = System.monotonic_time(:second) - state.started_at
    IO.puts("  \e[33m⚙\e[0m  uptime      \e[1m#{format_elapsed(elapsed)}\e[0m")

    # Show per-agent breakdown if any children exist
    if length(children) > 0 do
      IO.puts("")
      IO.puts(JidoClaw.Display.SwarmBox.render_header(tracker.agents, terminal_cols()))
      IO.puts(JidoClaw.Display.SwarmBox.render_agents(tracker.agents, tracker.order))
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
      Enum.each(models, fn model ->
        desc = Config.model_description(model)
        active = if model == state.model, do: " \e[32m← active\e[0m", else: ""
        IO.puts("  \e[33m▸\e[0m \e[1m#{model}\e[0m  \e[2m#{desc}\e[0m#{active}")
      end)
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
      Enum.each(models, fn model ->
        desc = Config.model_description(model)
        active = if model == state.model, do: " \e[32m← active\e[0m", else: ""
        IO.puts("  \e[33m▸\e[0m \e[1m#{model}\e[0m  \e[2m#{desc}\e[0m#{active}")
      end)
    end

    IO.puts("")
    IO.puts("  \e[2mSwitch: /model <provider:model>\e[0m")
    IO.puts("")
    {:ok, state}
  end

  def handle("/agents", state) do
    tracker = JidoClaw.AgentTracker.get_state()
    children = tracker.agents |> Enum.reject(fn {id, _} -> id == "main" end)

    IO.puts("")

    if children == [] do
      IO.puts("  \e[1mSwarm Dashboard\e[0m")
      IO.puts("  \e[2mNo child agents running.\e[0m")
    else
      IO.puts(JidoClaw.Display.SwarmBox.render_header(tracker.agents, terminal_cols()))
      IO.puts(JidoClaw.Display.SwarmBox.render_agents(tracker.agents, tracker.order))
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
      Enum.each(skills, fn skill ->
        IO.puts("  \e[33m▸\e[0m \e[1m#{skill.name}\e[0m — #{skill.description}")

        Enum.each(skill.steps, fn step ->
          template = Map.get(step, "template") || Map.get(step, :template)
          task = Map.get(step, "task") || Map.get(step, :task)
          IO.puts("    \e[2m→ #{template}: #{task}\e[0m")
        end)
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/memory search " <> query, state) do
    q = String.trim(query)
    results = JidoClaw.Memory.recall(q)

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
        JidoClaw.Memory.remember(key, content)
        IO.puts("  \e[32m✓\e[0m  Saved memory: \e[1m#{key}\e[0m")

      _ ->
        IO.puts("  \e[31mUsage: /memory save <key> <content>\e[0m")
    end

    {:ok, state}
  end

  def handle("/memory forget " <> key, state) do
    JidoClaw.Memory.forget(String.trim(key))
    IO.puts("  \e[32m✓\e[0m  Forgot: \e[1m#{String.trim(key)}\e[0m")
    {:ok, state}
  end

  def handle("/memory", state) do
    memories = JidoClaw.Memory.list_recent(20)

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
      "  \e[2mCommands: /memory search <q>  /memory save <key> <content>  /memory forget <key>\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  def handle("/solutions search " <> query, state) do
    q = String.trim(query)
    results = JidoClaw.Solutions.Store.search(q)

    IO.puts("")
    IO.puts("  \e[1mSolutions Search: #{q}\e[0m")

    if results == [] do
      IO.puts("  \e[2mNo solutions found.\e[0m")
    else
      IO.puts("  \e[2m#{length(results)} result(s)\e[0m")
      IO.puts("")

      Enum.each(results, fn sol ->
        lang = if sol.language, do: " \e[36m[#{sol.language}]\e[0m", else: ""
        preview = sol.solution_content |> String.slice(0, 80) |> String.replace("\n", " ")
        IO.puts("  \e[33m▸\e[0m \e[1m#{sol.id}\e[0m#{lang}")
        IO.puts("    \e[2m#{preview}\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/solutions", state) do
    stats = JidoClaw.Solutions.Store.stats()

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
    case JidoClaw.Network.Node.disconnect() do
      :ok ->
        IO.puts("  \e[32m✓\e[0m  Disconnected from agent network")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Failed to disconnect: #{inspect(reason)}")
    end

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
    new_config = JidoClaw.CLI.Setup.run(state.cwd)
    new_model = JidoClaw.Config.model(new_config)
    {:ok, %{state | config: new_config, model: new_model}}
  end

  def handle("/config", state), do: handle("/setup", state)

  def handle("/gateway", state) do
    port = JidoClaw.CLI.Branding.gateway_port()
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
    tenants = JidoClaw.Tenant.Manager.list_tenants()

    IO.puts("")
    IO.puts("  \e[1mTenants\e[0m")

    if tenants == [] do
      IO.puts("  \e[2mNo tenants.\e[0m")
    else
      Enum.each(tenants, fn t ->
        status_color = if t.status == :active, do: "\e[32m", else: "\e[33m"
        IO.puts("  \e[33m▸\e[0m \e[1m#{t.name}\e[0m (#{t.id})  #{status_color}#{t.status}\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/cron add " <> rest, state) do
    case parse_cron_add(rest) do
      {:ok, id, schedule, task} ->
        project_dir = state.cwd

        schedule_tuple =
          if String.starts_with?(schedule, "every ") do
            case Regex.run(~r/^every\s+(\d+)\s*(s|m|h|d)$/i, schedule) do
              [_, amount, unit] ->
                ms = String.to_integer(amount) * cron_unit_ms(String.downcase(unit))
                {:every, ms}

              nil ->
                {:cron, schedule}
            end
          else
            {:cron, schedule}
          end

        opts = [id: id, task: task, schedule: schedule_tuple, mode: :main]

        case JidoClaw.Cron.Scheduler.schedule("default", opts) do
          {:ok, ^id, _pid} ->
            JidoClaw.Cron.Persistence.add_job(project_dir, %{
              id: id,
              task: task,
              schedule: schedule,
              mode: "main"
            })

            IO.puts("")
            IO.puts("  \e[32m✓\e[0m Scheduled '\e[1m#{id}\e[0m': \"#{task}\" (#{schedule})")
            IO.puts("  \e[2mPersisted to .jido/cron.yaml\e[0m")
            IO.puts("")

          {:error, reason} ->
            IO.puts("")
            IO.puts("  \e[31m✗\e[0m Failed to schedule: #{inspect(reason)}")
            IO.puts("")
        end

        {:ok, state}

      :error ->
        IO.puts("")
        IO.puts("  \e[33mUsage:\e[0m /cron add <id> \"<schedule>\" <task description>")

        IO.puts(
          "  \e[2mExample: /cron add daily-tests \"0 9 * * *\" Run mix test and report results\e[0m"
        )

        IO.puts("")
        {:ok, state}
    end
  end

  def handle("/cron remove " <> id, state) do
    id = String.trim(id)
    JidoClaw.Cron.Scheduler.unschedule("default", id)
    JidoClaw.Cron.Persistence.remove_job(state.cwd, id)
    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Removed job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron trigger " <> id, state) do
    id = String.trim(id)
    JidoClaw.Cron.Scheduler.trigger("default", id)
    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Triggered job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron disable " <> id, state) do
    id = String.trim(id)
    JidoClaw.Cron.Worker.disable("default", id)
    IO.puts("")
    IO.puts("  \e[32m✓\e[0m Disabled job '\e[1m#{id}\e[0m'")
    IO.puts("")
    {:ok, state}
  end

  def handle("/cron", state) do
    jobs = JidoClaw.Cron.Scheduler.list_jobs("default")

    IO.puts("")
    IO.puts("  \e[1mCron Jobs\e[0m")

    if jobs == [] do
      IO.puts("  \e[2mNo scheduled jobs. Use /cron add or ask the agent to schedule one.\e[0m")
    else
      Enum.each(jobs, fn job ->
        status_icon =
          case job.status do
            :active -> "\e[32m●\e[0m"
            :disabled -> "\e[31m✗\e[0m"
            :stuck -> "\e[33m⚠\e[0m"
            _ -> "\e[2m○\e[0m"
          end

        schedule_str = format_cron_schedule(job.schedule)
        next_str = if job.next_run, do: " next: #{format_relative_time(job.next_run)}", else: ""

        IO.puts("  #{status_icon} \e[1m#{job.id}\e[0m  #{schedule_str}#{next_str}")
        IO.puts("    \e[2m\"#{job.task}\"\e[0m  failures: #{job.failure_count}")
      end)
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
      Enum.each(channels, fn ch ->
        status_color = if ch.status == :connected, do: "\e[32m", else: "\e[33m"
        IO.puts("  \e[33m▸\e[0m \e[1m#{ch.platform}\e[0m  #{status_color}#{ch.status}\e[0m")
      end)
    end

    IO.puts("")
    {:ok, state}
  end

  def handle("/strategies stats", state) do
    %{strategies: strategies, task_types: task_types} =
      JidoClaw.Reasoning.Statistics.summary()

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
    strategies = JidoClaw.Reasoning.StrategyRegistry.list()
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

    if name == "auto" or JidoClaw.Reasoning.StrategyRegistry.valid?(name) do
      IO.puts("  \e[32m✓\e[0m  Reasoning preference set to \e[1m#{name}\e[0m")
      IO.puts("  \e[2m(The agent will see this preference on the next query)\e[0m")
      {:ok, %{state | strategy: name}}
    else
      IO.puts("  \e[31m✗\e[0m  Unknown strategy: \e[1m#{name}\e[0m")

      available =
        ["auto" | JidoClaw.Reasoning.StrategyRegistry.list() |> Enum.map(& &1.name)]
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

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_elapsed(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_elapsed(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

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
      diff < 86400 -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "#{div(diff, 86400)}d"
    end
  end

  defp cron_unit_ms("s"), do: 1_000
  defp cron_unit_ms("m"), do: 60_000
  defp cron_unit_ms("h"), do: 3_600_000
  defp cron_unit_ms("d"), do: 86_400_000
  defp cron_unit_ms(_), do: 60_000

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
    alias JidoClaw.Shell.ProfileManager
    alias JidoClaw.Security.Redaction.Env, as: EnvRedaction

    current = ProfileManager.current(state.session_id)
    env = ProfileManager.active_env(state.session_id)

    IO.puts("")
    IO.puts("  \e[1mActive Profile\e[0m  \e[1m#{current}\e[0m")
    IO.puts("")

    cond do
      map_size(env) == 0 ->
        IO.puts("  \e[2mNo variables in this profile.\e[0m")

      true ->
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
end
