defmodule JidoClaw.CLI.Repl do
  @moduledoc """
  The main REPL loop: reads input, routes to agent or commands, displays output.
  """

  # CLI top-level loop: every rescue here is a deliberate "never crash the REPL"
  # boundary — fetch/poll/persistence faults degrade to nil/error/{nil,nil,nil}
  # so the user sees a warning, not a stack trace.
  # reach:disable-for-this-file bare_rescue

  alias JidoClaw.{Agent, AgentTracker, Config, Display, Session.Worker, Startup, Stats}
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.{Branding, Commands, Formatter, Setup}
  alias JidoClaw.Conversations.Recorder
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Conversations.SessionId
  alias JidoClaw.Cron.Scheduler, as: CronScheduler
  alias JidoClaw.Reasoning.Compactor.Identity, as: CompactionIdentity
  alias JidoClaw.Reasoning.StrategyRegistry
  alias JidoClaw.Shell.ProfileManager
  alias JidoClaw.Workspaces.PolicyTransitions
  alias JidoClaw.Workspaces.Workspace
  alias Nostrum.Cache.Me

  defstruct [
    :agent_pid,
    :agent_id,
    :config,
    :cwd,
    :model,
    :session_id,
    # Phase 0 — UUID FK targets resolved at boot from the persisted
    # Workspace and Session rows; threaded into every tool_context build
    # so reasoning telemetry (and later Memory/Audit) can attach to real
    # FK targets instead of opaque strings.
    :session_uuid,
    :workspace_uuid,
    :tenant_id,
    :started_at,
    # strategy is populated at REPL init from Config.strategy/1 — not
    # defaulted here so we don't silently shadow .jido/config.yaml.
    :strategy,
    # profile reflects the ProfileManager-tracked active name for this
    # workspace. Populated at boot via resolve_profile/1; updated by
    # /profile switch.
    :profile,
    stats: %{messages: 0, tokens: 0}
  ]

  def start(project_dir) do
    config = ensure_config(project_dir)
    model = Config.model(config)

    # Override jido_ai model aliases so :fast resolves to user's configured model
    Application.put_env(:jido_ai, :model_aliases, %{fast: model, capable: model})

    {configured_strategy, strategy} = resolve_configured_strategy(config)

    print_boot_sequence(project_dir, config, model, strategy)
    maybe_warn_strategy_fallback(configured_strategy, strategy)
    sync_project_state(project_dir)
    announce_provider_status(config)
    announce_discord_status()

    case JidoClaw.Jido.start_agent(Agent, id: "main") do
      {:ok, pid} ->
        state = boot_repl_session(pid, project_dir, config, model, strategy)
        loop(state)

      {:error, reason} ->
        Formatter.print_error("Failed to start agent: #{inspect(reason)}")
    end
  end

  defp ensure_config(project_dir) do
    if Setup.needed?(project_dir) do
      Setup.run(project_dir)
    else
      Config.load(project_dir)
    end
  end

  # Resolve the configured strategy against the registry so typos / stale
  # entries in .jido/config.yaml fall back to "auto" instead of silently
  # propagating into every agent turn via prepare_user_message/2.
  defp resolve_configured_strategy(config) do
    configured = Config.strategy(config)
    {configured, resolve_strategy(configured)}
  end

  defp maybe_warn_strategy_fallback(strategy, strategy), do: :ok

  defp maybe_warn_strategy_fallback(configured, _strategy) do
    IO.puts(
      "  \e[33m⚠\e[0m  strategy    \e[1m#{configured}\e[0m is not a known strategy \e[2m— falling back to \e[1mauto\e[0m\e[2m. Check .jido/config.yaml.\e[0m"
    )

    IO.puts("")
  end

  defp print_boot_sequence(project_dir, config, model, strategy) do
    mode = Application.get_env(:jido_claw, :mode, :both)

    Branding.boot_sequence(project_dir,
      provider: Config.provider_label(config),
      model: model_name(model),
      strategy: strategy,
      tools_count: length(JidoClaw.Agent.tool_modules()),
      gateway: mode in [:gateway, :both]
    )
  end

  # Ensure JIDO.md, system prompt, and default skills; reconcile prompt sync.
  defp sync_project_state(project_dir) do
    case Startup.ensure_project_state(project_dir) do
      {:ok, result} ->
        maybe_announce_prompt_upgrade(Keyword.fetch!(result, :prompt_sync))

      {:error, reason} ->
        IO.puts(
          "  \e[33m⚠\e[0m  prompt sync failed: \e[1m#{inspect(reason)}\e[0m \e[2m— continuing with existing .jido/ state\e[0m"
        )

        IO.puts("")
    end
  end

  defp maybe_announce_prompt_upgrade(:sidecar_written) do
    IO.puts(
      "  \e[33m↻\e[0m  prompt      \e[1mupgrade available\e[0m \e[2m— review .jido/system_prompt.md.default, then /upgrade-prompt\e[0m"
    )

    IO.puts("")
  end

  defp maybe_announce_prompt_upgrade(_), do: :ok

  defp announce_provider_status(config) do
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
  end

  # Discord gateway connection is async, so poll briefly before declaring failure.
  defp announce_discord_status do
    case System.get_env("DISCORD_BOT_TOKEN") do
      nil -> :ok
      _token -> announce_discord_consumer_group()
    end
  end

  defp announce_discord_consumer_group do
    case Process.whereis(Nostrum.ConsumerGroup) do
      nil -> announce_discord_failed_start()
      _pid -> announce_discord_connection(poll_discord_ready(10, 500))
    end
  end

  defp announce_discord_failed_start do
    IO.puts("  \e[31m✗\e[0m  Discord bot failed to start")
    IO.puts("")
  end

  defp announce_discord_connection(%{username: name}) do
    IO.puts("  \e[32m✓\e[0m  Discord bot online as \e[1m#{name}\e[0m")
    IO.puts("")
  end

  defp announce_discord_connection(nil) do
    IO.puts("  \e[31m✗\e[0m  Discord bot failed to connect")

    IO.puts("  \e[2m   Check your DISCORD_BOT_TOKEN and that privileged intents are enabled\e[0m")

    IO.puts("")
  end

  defp boot_repl_session(pid, project_dir, config, model, strategy) do
    session_id = SessionId.new()
    tenant_id = "default"

    ensure_session_worker!(tenant_id, session_id)

    # Phase 0 — resolve durable Workspace + Session rows so the
    # tool_context threaded into every Agent.ask carries
    # workspace_uuid + session_uuid. CLI runs unauthenticated so
    # user_id is nil; the partial-unique :unique_user_path_cli
    # identity keeps these rows from colliding with web/RPC rows.
    {workspace_uuid, session_uuid, session_record} =
      ensure_persisted_session(tenant_id, project_dir, session_id)

    # Phase 2 — wire the Worker to the persisted session UUID so
    # Worker.add_message can write Conversations.Message rows.
    # This also hydrates state.messages from Postgres if any prior
    # rows exist for this session.
    maybe_set_worker_session_uuid(tenant_id, session_id, session_uuid)

    # Inject the system prompt after the Session row exists so the
    # frozen-snapshot path can read `metadata["prompt_snapshot"]`
    # and the Anthropic prompt cache stays warm across turns.
    inject_system_prompt_with_warning(pid, project_dir, session_record)

    # Bind agent process to session for crash tracking
    bind_agent_to_worker(tenant_id, session_id, pid)

    AgentTracker.register("main", pid, nil, nil,
      tenant_id: tenant_id,
      session_id: session_id,
      session_uuid: session_uuid,
      workspace_uuid: workspace_uuid
    )

    configure_display_from_config(config, model)

    Display.set_scope(%{
      tenant_id: tenant_id,
      session_id: session_id,
      session_uuid: session_uuid,
      workspace_uuid: workspace_uuid
    })

    profile = resolve_profile(session_id)
    Display.set_profile(profile)

    load_cron_jobs(project_dir)

    %__MODULE__{
      agent_pid: pid,
      agent_id: "main",
      config: config,
      cwd: project_dir,
      model: model,
      session_id: session_id,
      session_uuid: session_uuid,
      workspace_uuid: workspace_uuid,
      tenant_id: tenant_id,
      started_at: System.monotonic_time(:second),
      strategy: strategy,
      profile: profile
    }
  end

  # Hard-match so a failing supervisor crashes the boot rather than silently
  # regressing the session worker.
  defp ensure_session_worker!(tenant_id, session_id) do
    {:ok, _session_pid} =
      JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id,
        actor: Actor.system(tenant_id)
      )

    :ok
  end

  defp maybe_set_worker_session_uuid(_tenant_id, _session_id, nil), do: :ok
  defp maybe_set_worker_session_uuid(_tenant_id, _session_id, false), do: :ok

  defp maybe_set_worker_session_uuid(tenant_id, session_id, session_uuid) do
    Worker.set_session_uuid(tenant_id, session_id, session_uuid)
  end

  defp inject_system_prompt_with_warning(pid, project_dir, session_record) do
    case Startup.inject_system_prompt(pid, project_dir, session_record) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts("  \e[33m⚠\e[0m  System prompt injection failed: #{inspect(reason)}")
    end
  end

  defp bind_agent_to_worker(tenant_id, session_id, pid) do
    Worker.set_agent(tenant_id, session_id, pid)
  end

  defp configure_display_from_config(config, model) do
    context_window =
      case Config.model_info(config) do
        {:ok, %{limits: %{context: cw}}} -> cw
        _ -> 131_072
      end

    Display.configure(model_name(model), Config.provider_label(config), context_window)
  end

  defp load_cron_jobs(project_dir) do
    case CronScheduler.load_persistent_jobs("default", project_dir) do
      {:ok, 0} -> :ok
      {:ok, n} -> IO.puts("  \e[32m✓\e[0m  cron        \e[1m#{n} jobs loaded\e[0m")
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
    request_id = Ecto.UUID.generate()

    Stats.track_message(:user)

    Display.reset_mode()
    Display.exit_input_mode()
    Display.start_thinking()

    actor = Actor.system(state.tenant_id)
    session_record = fetch_session_record(state, actor)

    {routed_pid, routed_template, routed_agent_id, first_post_handoff?, owner} =
      HandoffRouter.resolve_session_owner(
        state.tenant_id,
        state.session_id,
        state.session_uuid,
        state.agent_pid,
        actor,
        project_dir: state.cwd,
        session_record: session_record,
        default_agent_id: state.agent_id
      )

    # Register correlation AFTER routing (so the stamped compaction identity
    # reflects the resolved owner) but BEFORE the user-message append, so the
    # Recorder can resolve scope for any tool signal that fires during this
    # turn even if it races ahead of the dispatcher's add_message.
    if state.session_uuid do
      JidoClaw.register_correlation(
        request_id,
        state.session_uuid,
        state.tenant_id,
        state.workspace_uuid,
        nil,
        agent_id: CompactionIdentity.resolve(routed_template, routed_agent_id, state.session_id),
        subagent: false
      )
    end

    # 1. Build preamble BEFORE writing the current user message to
    #    Session.Worker, so the recent-history window excludes this turn.
    preamble =
      if first_post_handoff? do
        HandoffRouter.build_preamble(state.tenant_id, state.session_id, owner)
      else
        ""
      end

    # 2. Persist the *raw* user message — durable history reflects what the user
    #    typed, not the strategy-prepared or preambled variant.
    Worker.add_message(state.tenant_id, state.session_id, :user, message, request_id)

    prepared_raw = prepare_user_message(message, state.strategy)

    tool_context =
      JidoClaw.ToolContext.build(%{
        project_dir: state.cwd,
        tenant_id: state.tenant_id,
        session_id: state.session_id,
        session_uuid: state.session_uuid,
        workspace_id: state.session_id,
        workspace_uuid: state.workspace_uuid,
        agent_id: routed_agent_id,
        agent_template: routed_template,
        subagent: false
      })

    prepared_with_preamble = preamble <> prepared_raw

    # Handoff routing is an ownership *transfer*, not a freshly-built child
    # context: the same conversation's `tool_context` is routed to the owning
    # worker as-is. Full-context continuity is the defining purpose of handoff,
    # so the `forward_context` visibility policy (spawn / follow-up /
    # workflow-step) deliberately does NOT apply here.
    case Agent.ask(routed_pid, prepared_with_preamble,
           timeout: 120_000,
           request_id: request_id,
           tool_context: tool_context
         ) do
      {:ok, handle} ->
        result = poll_with_tool_display(handle, routed_pid, routed_template, MapSet.new())

        Display.stop_thinking()

        # Barrier: assistant row must come AFTER tool/reasoning rows.
        _ = Recorder.flush(request_id)

        HandoffRouter.mark_preamble_consumed_on_success(
          state.tenant_id,
          state.session_id,
          routed_template,
          first_post_handoff?,
          result
        )

        case result do
          {:ok, answer} when is_binary(answer) ->
            Formatter.print_answer(answer)
            Worker.add_message(state.tenant_id, state.session_id, :assistant, answer, request_id)
            update_stats(state)

          {:ok, answer} ->
            text = extract_text(answer)
            Formatter.print_answer(text)
            Worker.add_message(state.tenant_id, state.session_id, :assistant, text, request_id)
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

  defp fetch_session_record(%{session_uuid: nil}, _actor), do: nil

  defp fetch_session_record(%{session_uuid: uuid, tenant_id: tenant_id}, actor)
       when is_binary(uuid) do
    case ConversationsSession.by_id(uuid, tenant: tenant_id, actor: actor) do
      {:ok, session} -> session
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_session_record(_state, _actor), do: nil

  # Poll for request completion, displaying tool calls as they appear.
  # seen_ids is a MapSet of {tool_call_id, stage} tuples already displayed.
  defp poll_with_tool_display(handle, agent_pid, agent_label, seen_ids) do
    new_seen = display_new_tool_calls(agent_pid, agent_label, seen_ids)

    case Agent.await(handle, timeout: 600) do
      {:ok, result} ->
        # Final sweep to catch any completions logged after the last poll
        display_new_tool_calls(agent_pid, agent_label, new_seen)
        {:ok, result}

      {:error, :timeout} ->
        poll_with_tool_display(handle, agent_pid, agent_label, new_seen)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, "Request failed"}
  catch
    :exit, {:timeout, _} ->
      poll_with_tool_display(handle, agent_pid, agent_label, seen_ids)

    :exit, reason ->
      {:error, inspect(reason)}
  end

  # Read the current pending_tool_calls from the agent status snapshot and
  # print any tool starts/completions not yet in seen_ids.
  # Returns the updated seen_ids MapSet.
  defp display_new_tool_calls(agent_pid, agent_label, seen_ids) do
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
              Stats.track_tool_call(agent_label, name)
              Display.tool_start(agent_label, name, args)
              MapSet.put(acc, {id, :started})
            else
              acc
            end

          if completed and not MapSet.member?(acc, {id, :completed}) and name != "" do
            # Extract tool result for rich display preview
            result = tc_result(tc)
            Display.tool_complete(agent_label, name, result)
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
    result = Map.get(tc, :result, Map.get(tc, "result"))
    if is_map(result), do: result, else: nil
  end

  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(%{answer: answer}) when is_binary(answer), do: answer
  defp extract_text(%{last_answer: answer}) when is_binary(answer), do: answer
  defp extract_text(other), do: inspect(other)

  @doc """
  Test seam: normalize an arbitrary strategy name (from `.jido/config.yaml`
  or a typo) against the registry.

  `"auto"` is always valid (selector, not a registry entry); anything else
  must be a known built-in or user alias. Unknown values fall back to
  `"auto"` so the agent-facing hint can never inject a nonexistent
  strategy into the prompt.
  """
  def resolve_strategy("auto"), do: "auto"

  def resolve_strategy(name) when is_binary(name) do
    if StrategyRegistry.valid?(name), do: name, else: "auto"
  end

  def resolve_strategy(_), do: "auto"

  @doc """
  Test seam: return the `ProfileManager`-tracked active profile for a
  workspace.

  Defaults to `"default"` when `ProfileManager` isn't running (e.g.
  under test harnesses that don't boot the full supervision tree) or the
  workspace has no recorded switch. Mirrors `resolve_strategy/1`'s
  "never crash, always produce a reasonable default" contract.
  """
  def resolve_profile(workspace_id) when is_binary(workspace_id) do
    case Process.whereis(ProfileManager) do
      nil -> "default"
      _pid -> ProfileManager.current(workspace_id)
    end
  catch
    :exit, _ -> "default"
  end

  def resolve_profile(_), do: "default"

  @doc """
  Test seam: prepend a reasoning-preference hint to the agent-facing
  message when the REPL has a non-react strategy active.

  `"react"` is the agent's native loop — no hint needed. `"auto"` gets a
  hint pointing at `reason(strategy: "auto")` so history-aware selection
  kicks in for complex queries. Any other concrete strategy
  (`cot`/`tot`/etc.) names itself in the hint so the agent invokes
  `reason(strategy: "<name>")` on queries that benefit. Exposed for the
  REPL test suite so assertions can hit the exact string.
  """
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
      elapsed: Formatter.format_elapsed(elapsed),
      estimated_cost: cost
    }
  end

  defp poll_discord_ready(0, _interval), do: nil

  defp poll_discord_ready(attempts, interval) do
    case Code.ensure_loaded(Me) do
      {:module, _} ->
        case Me.get() do
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

  # Resolve durable Workspace + Session rows for the REPL boot. Falls
  # back to {nil, nil, nil} when the persistence layer is unreachable
  # so the REPL still starts in degraded mode (e.g. test harness
  # without a running database) rather than crashing.
  defp ensure_persisted_session(tenant_id, project_dir, session_id) do
    with {:ok, workspace} <-
           JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir),
         {:ok, _} <- maybe_apply_workspace_policies(workspace, project_dir),
         {:ok, session} <-
           JidoClaw.Conversations.Resolver.ensure_session(
             tenant_id,
             workspace.id,
             :repl,
             session_id,
             project_dir: project_dir
           ) do
      {workspace.id, session.id, session}
    else
      {:error, reason} ->
        IO.puts(
          "  \e[33m⚠\e[0m  workspace/session persistence failed: \e[1m#{inspect(reason)}\e[0m"
        )

        {nil, nil, nil}
    end
  rescue
    e ->
      IO.puts(
        "  \e[33m⚠\e[0m  workspace/session persistence raised: \e[1m#{Exception.message(e)}\e[0m"
      )

      {nil, nil, nil}
  end

  # Apply embedding/consolidation policies from config.yaml when the
  # config carries them and the workspace doesn't have a non-:disabled
  # value set. The "skip if already set non-:disabled and config says
  # :disabled" rule lets `/workspace embedding` win over the wizard:
  # users who tuned via REPL command and re-ran the wizard wouldn't
  # want the wizard to undo their change.
  defp maybe_apply_workspace_policies(workspace, project_dir) do
    config_map = JidoClaw.Config.load(project_dir)

    embedding =
      config_map
      |> Map.get("embedding_policy")
      |> normalize_policy()

    consolidation =
      config_map
      |> Map.get("consolidation_policy")
      |> normalize_policy()

    workspace =
      workspace
      |> apply_policy_if_needed(:embedding_policy, embedding)
      |> apply_policy_if_needed(:consolidation_policy, consolidation)

    {:ok, workspace}
  end

  defp normalize_policy("default"), do: :default
  defp normalize_policy("disabled"), do: :disabled
  defp normalize_policy(p) when p in [:default, :disabled], do: p
  defp normalize_policy(_), do: nil

  defp apply_policy_if_needed(workspace, _attr, nil), do: workspace

  defp apply_policy_if_needed(workspace, :embedding_policy, new_policy) do
    cond do
      workspace.embedding_policy != :disabled and new_policy == :disabled ->
        # Don't undo a non-:disabled policy when the wizard says
        # :disabled — the user may have tuned via /workspace embedding.
        workspace

      workspace.embedding_policy == new_policy ->
        workspace

      true ->
        case Workspace.set_embedding_policy(workspace, new_policy) do
          {:ok, w} ->
            PolicyTransitions.apply_embedding(w.id, new_policy)
            w

          _ ->
            workspace
        end
    end
  end

  defp apply_policy_if_needed(workspace, :consolidation_policy, new_policy) do
    cond do
      workspace.consolidation_policy != :disabled and new_policy == :disabled ->
        workspace

      workspace.consolidation_policy == new_policy ->
        workspace

      true ->
        case Workspace.set_consolidation_policy(workspace, new_policy) do
          {:ok, w} -> w
          _ -> workspace
        end
    end
  end
end
