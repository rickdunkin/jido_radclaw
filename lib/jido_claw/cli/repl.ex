defmodule JidoClaw.CLI.Repl do
  @moduledoc """
  The main REPL loop: reads input, routes to agent or commands, displays output.
  """

  alias JidoClaw.{Agent, AgentTracker, Config, Display, Session, Session.Worker, Startup, Stats}
  alias JidoClaw.CLI.{Branding, Commands, Formatter, Setup}
  alias JidoClaw.Reasoning.StrategyRegistry

  defstruct [
    :agent_pid,
    :agent_id,
    :config,
    :cwd,
    :model,
    :session_id,
    :started_at,
    # strategy is populated at REPL init from Config.strategy/1 — not
    # defaulted here so we don't silently shadow .jido/config.yaml.
    :strategy,
    stats: %{messages: 0, tokens: 0}
  ]

  def start(project_dir) do
    # First-time setup wizard
    config =
      if Setup.needed?(project_dir) do
        Setup.run(project_dir)
      else
        Config.load(project_dir)
      end

    model = Config.model(config)

    # Override jido_ai model aliases so :fast resolves to user's configured model
    Application.put_env(:jido_ai, :model_aliases, %{fast: model, capable: model})

    # Resolve the configured strategy against the registry so typos / stale
    # entries in .jido/config.yaml fall back to "auto" instead of silently
    # propagating into every agent turn via prepare_user_message/2.
    configured_strategy = Config.strategy(config)
    strategy = resolve_strategy(configured_strategy)

    # Boot sequence
    mode = Application.get_env(:jido_claw, :mode, :both)

    Branding.boot_sequence(project_dir,
      provider: Config.provider_label(config),
      model: model_name(model),
      strategy: strategy,
      tools_count: length(JidoClaw.Agent.tool_modules()),
      gateway: mode in [:gateway, :both]
    )

    if strategy != configured_strategy do
      IO.puts(
        "  \e[33m⚠\e[0m  strategy    \e[1m#{configured_strategy}\e[0m is not a known strategy \e[2m— falling back to \e[1mauto\e[0m\e[2m. Check .jido/config.yaml.\e[0m"
      )

      IO.puts("")
    end

    # Ensure JIDO.md, system prompt, and default skills; reconcile prompt sync.
    prompt_sync =
      case Startup.ensure_project_state(project_dir) do
        {:ok, result} ->
          Keyword.fetch!(result, :prompt_sync)

        {:error, reason} ->
          IO.puts(
            "  \e[33m⚠\e[0m  prompt sync failed: \e[1m#{inspect(reason)}\e[0m \e[2m— continuing with existing .jido/ state\e[0m"
          )

          IO.puts("")
          :noop
      end

    if prompt_sync == :sidecar_written do
      IO.puts(
        "  \e[33m↻\e[0m  prompt      \e[1mupgrade available\e[0m \e[2m— review .jido/system_prompt.md.default, then /upgrade-prompt\e[0m"
      )

      IO.puts("")
    end

    # Check provider connectivity
    provider_name = Config.provider_label(config)
    api_key_env = Config.api_key_env(config)

    case Config.check_provider(config) do
      :ok ->
        IO.puts("  \e[32m✓\e[0m  Connected to #{provider_name}")
        IO.puts("")

      {:error, :unauthorized} ->
        IO.puts("  \e[31m✗\e[0m  #{provider_name}: invalid API key")
        IO.puts("  \e[2m   Check #{api_key_env} or run /setup to reconfigure\e[0m")
        IO.puts("")

      {:error, :unreachable} ->
        IO.puts("  \e[33m⚠\e[0m  #{provider_name} not reachable")
        IO.puts("  \e[2m   Check your connection or run /setup to reconfigure\e[0m")
        IO.puts("")
    end

    # Check Discord status — gateway connection is async, so poll briefly
    if System.get_env("DISCORD_BOT_TOKEN") do
      case Process.whereis(Nostrum.ConsumerGroup) do
        nil ->
          IO.puts("  \e[31m✗\e[0m  Discord bot failed to start")
          IO.puts("")

        _pid ->
          bot_user = poll_discord_ready(10, 500)

          case bot_user do
            %{username: name} ->
              IO.puts("  \e[32m✓\e[0m  Discord bot online as \e[1m#{name}\e[0m")
              IO.puts("")

            nil ->
              IO.puts("  \e[31m✗\e[0m  Discord bot failed to connect")

              IO.puts(
                "  \e[2m   Check your DISCORD_BOT_TOKEN and that privileged intents are enabled\e[0m"
              )

              IO.puts("")
          end
      end
    end

    # Start agent
    case JidoClaw.Jido.start_agent(Agent, id: "main") do
      {:ok, pid} ->
        case Startup.inject_system_prompt(pid, project_dir) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts("  \e[33m⚠\e[0m  System prompt injection failed: #{inspect(reason)}")
        end

        session_id = Session.new_session_id()

        # Ensure a Session.Worker GenServer is running for this CLI session
        {:ok, _session_pid} = Session.Supervisor.ensure_session("default", session_id)

        # Bind agent process to session for crash tracking
        Worker.set_agent("default", session_id, pid)

        # Register main agent with tracker and configure display
        AgentTracker.register("main", pid, nil, nil)

        context_window =
          case Config.model_info(config) do
            {:ok, %{limits: %{context_window: cw}}} -> cw
            _ -> 131_072
          end

        Display.configure(model_name(model), Config.provider_label(config), context_window)

        # Load persistent cron jobs
        case JidoClaw.Cron.Scheduler.load_persistent_jobs("default", project_dir) do
          {:ok, 0} -> :ok
          {:ok, n} -> IO.puts("  \e[32m✓\e[0m  cron        \e[1m#{n} jobs loaded\e[0m")
        end

        # Start heartbeat writer
        JidoClaw.Heartbeat.start_link(project_dir: project_dir)

        state = %__MODULE__{
          agent_pid: pid,
          agent_id: "main",
          config: config,
          cwd: project_dir,
          model: model,
          session_id: session_id,
          started_at: System.monotonic_time(:second),
          strategy: strategy
        }

        loop(state)

      {:error, reason} ->
        Formatter.print_error("Failed to start agent: #{inspect(reason)}")
    end
  end

  defp loop(state) do
    Display.enter_input_mode()

    case IO.gets("\e[36mjidoclaw>\e[0m ") do
      :eof ->
        IO.puts(Branding.goodbye(goodbye_stats(state)))

      {:error, _} ->
        IO.puts(Branding.goodbye(goodbye_stats(state)))

      input ->
        line = String.trim(input)

        cond do
          line == "" ->
            loop(state)

          String.starts_with?(line, "/") ->
            case Commands.handle(line, state) do
              {:ok, new_state} -> loop(new_state)
              :quit -> :ok
            end

          true ->
            new_state = handle_message(line, state)
            loop(new_state)
        end
    end
  end

  defp handle_message(message, state) do
    # Route through Session.Worker GenServer (telemetry + JSONL persistence).
    # Save the *raw* message here so session history captures what the user
    # typed, not the hinted variant seen by the agent.
    Worker.add_message("default", state.session_id, :user, message)
    Stats.track_message(:user)

    # Reset display mode and start thinking spinner via Display
    Display.reset_mode()
    Display.exit_input_mode()
    Display.start_thinking()

    prepared = prepare_user_message(message, state.strategy)

    case Agent.ask(state.agent_pid, prepared,
           timeout: 120_000,
           tool_context: %{
             project_dir: state.cwd,
             workspace_id: state.session_id,
             agent_id: state.agent_id
           }
         ) do
      {:ok, handle} ->
        result = poll_with_tool_display(handle, state.agent_pid, MapSet.new())

        # Ensure spinner is stopped
        Display.stop_thinking()

        case result do
          {:ok, answer} when is_binary(answer) ->
            Formatter.print_answer(answer)
            Worker.add_message("default", state.session_id, :assistant, answer)
            update_stats(state)

          {:ok, answer} ->
            text = extract_text(answer)
            Formatter.print_answer(text)
            Worker.add_message("default", state.session_id, :assistant, text)
            update_stats(state)

          {:error, reason} ->
            Formatter.print_error("#{inspect(reason)}")
            state
        end

      {:error, reason} ->
        Display.stop_thinking()
        Formatter.print_error("#{inspect(reason)}")
        state
    end
  end

  # Poll for request completion, displaying tool calls as they appear.
  # seen_ids is a MapSet of {tool_call_id, stage} tuples already displayed.
  defp poll_with_tool_display(handle, agent_pid, seen_ids) do
    new_seen = display_new_tool_calls(agent_pid, seen_ids)

    case Agent.await(handle, timeout: 600) do
      {:ok, result} ->
        # Final sweep to catch any completions logged after the last poll
        display_new_tool_calls(agent_pid, new_seen)
        {:ok, result}

      {:error, :timeout} ->
        poll_with_tool_display(handle, agent_pid, new_seen)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, "Request failed"}
  catch
    :exit, {:timeout, _} ->
      poll_with_tool_display(handle, agent_pid, seen_ids)

    :exit, reason ->
      {:error, inspect(reason)}
  end

  # Read the current pending_tool_calls from the agent status snapshot and
  # print any tool starts/completions not yet in seen_ids.
  # Returns the updated seen_ids MapSet.
  defp display_new_tool_calls(agent_pid, seen_ids) do
    case Jido.AgentServer.status(agent_pid) do
      {:ok, %{snapshot: snapshot}} ->
        tool_calls = Map.get(snapshot, :tool_calls, [])

        Enum.reduce(tool_calls, seen_ids, fn tc, acc ->
          id = tc_field(tc, :id)
          name = tc_field(tc, :name)
          args = tc_args(tc)
          completed = tc_field(tc, :status) == :completed

          acc =
            if name != "" and not MapSet.member?(acc, {id, :started}) do
              Stats.track_tool_call("main", name)
              Display.tool_start("main", name, args)
              MapSet.put(acc, {id, :started})
            else
              acc
            end

          if completed and not MapSet.member?(acc, {id, :completed}) and name != "" do
            # Extract tool result for rich display preview
            result = tc_result(tc)
            Display.tool_complete("main", name, result)
            MapSet.put(acc, {id, :completed})
          else
            acc
          end
        end)

      _ ->
        seen_ids
    end
  end

  defp tc_field(tc, key) when is_map(tc) do
    Map.get(tc, key, Map.get(tc, Atom.to_string(key), ""))
  end

  defp tc_args(tc) when is_map(tc) do
    args = Map.get(tc, :arguments, Map.get(tc, "arguments", %{}))
    if is_map(args), do: args, else: %{}
  end

  defp tc_result(tc) when is_map(tc) do
    result = Map.get(tc, :result, Map.get(tc, "result", nil))
    if is_map(result), do: result, else: nil
  end

  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(%{answer: answer}) when is_binary(answer), do: answer
  defp extract_text(%{last_answer: answer}) when is_binary(answer), do: answer
  defp extract_text(other), do: inspect(other)

  @doc false
  # Normalize an arbitrary strategy name (from .jido/config.yaml or a typo)
  # against the registry. "auto" is always valid (selector, not a registry
  # entry); anything else must be a known built-in or user alias. Unknown
  # values fall back to "auto" so the agent-facing hint can never inject a
  # nonexistent strategy into the prompt.
  def resolve_strategy("auto"), do: "auto"

  def resolve_strategy(name) when is_binary(name) do
    if StrategyRegistry.valid?(name), do: name, else: "auto"
  end

  def resolve_strategy(_), do: "auto"

  @doc false
  # Prepend a reasoning-preference hint to the agent-facing message when the
  # REPL has a non-react strategy active. react is the agent's native loop —
  # no hint needed. auto gets a hint pointing at reason(strategy: "auto")
  # so history-aware selection kicks in for complex queries. Any other
  # concrete strategy (cot/tot/etc.) names itself in the hint so the agent
  # invokes reason(strategy: "<name>") on queries that benefit.
  #
  # Public (via @doc false) so the REPL test suite can assert on the string
  # without needing to drive the full handle_message flow.
  def prepare_user_message(message, "react"), do: message

  def prepare_user_message(message, "auto") do
    "[Reasoning preference: auto — invoke reason(strategy: \"auto\") for queries that benefit from structured reasoning; history-aware selection will pick a concrete strategy.]\n\n" <>
      message
  end

  def prepare_user_message(message, strategy) when is_binary(strategy) do
    "[Reasoning preference: #{strategy} — invoke reason(strategy: \"#{strategy}\") for queries that benefit from structured reasoning.]\n\n" <>
      message
  end

  defp update_stats(state) do
    Stats.track_message(:assistant)
    stats = %{state.stats | messages: state.stats.messages + 1}
    %{state | stats: stats}
  end

  defp goodbye_stats(state) do
    live = Stats.get()
    elapsed = System.monotonic_time(:second) - state.started_at

    cost =
      case Config.model_info(state.config) do
        {:ok, model_meta} -> Config.estimated_cost(live.tokens, model_meta)
        _ -> nil
      end

    %{
      messages: live.messages,
      tokens: live.tokens,
      tool_calls: live.tool_calls,
      agents_spawned: live.agents_spawned,
      elapsed: format_elapsed(elapsed),
      estimated_cost: cost
    }
  end

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_elapsed(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_elapsed(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp poll_discord_ready(0, _interval), do: nil

  defp poll_discord_ready(attempts, interval) do
    case Code.ensure_loaded(Nostrum.Cache.Me) do
      {:module, _} ->
        case Nostrum.Cache.Me.get() do
          nil ->
            Process.sleep(interval)
            poll_discord_ready(attempts - 1, interval)

          user ->
            user
        end

      _ ->
        nil
    end
  end

  defp model_name(model) do
    case String.split(model, ":", parts: 2) do
      [_, name] -> name
      _ -> model
    end
  end
end
