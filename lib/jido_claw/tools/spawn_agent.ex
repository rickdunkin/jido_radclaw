defmodule JidoClaw.Tools.SpawnAgent do
  @moduledoc false

  # Compile-time snapshot of the public template set: this module recompiles
  # (and the LLM-facing strings re-render) whenever Templates changes.
  @spawnable_inline Enum.join(JidoClaw.Agent.Templates.spawnable_names(), ", ")

  use JidoClaw.Tools.Action,
    name: "spawn_agent",
    description:
      "Spawn a child agent from a template to work on a task. Available templates: #{@spawnable_inline}. The child agent works independently and results can be collected with get_agent_result.",
    category: "swarm",
    tags: ["swarm", "write"],
    output_schema: [
      agent_id: [type: :string, required: true],
      template: [type: :string, required: true],
      description: [type: :string, required: true],
      status: [type: :string, required: true],
      message: [type: :string, required: true]
    ],
    schema: [
      template: [
        type: :string,
        required: true,
        doc: "Agent template name (#{@spawnable_inline})"
      ],
      task: [
        type: :string,
        required: true,
        doc: "The task description for the child agent to work on"
      ],
      tag: [
        type: :string,
        required: false,
        doc: "Optional unique ID for this agent (auto-generated if not provided)"
      ]
    ]

  require Logger

  alias JidoClaw.Agent.Templates
  alias JidoClaw.AgentTracker
  alias JidoClaw.Conversations.SubagentTranscript
  alias JidoClaw.Error
  alias JidoClaw.Tools.SwarmScope

  @impl Jido.Action
  def run(params, context) do
    template_name = params.template
    task = params.task

    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         :ok <- enforce_spawn_limits(context, scope_opts),
         {:ok, tag} <- agent_id_for(template_name, params) do
      spawn_from_template(template_name, task, tag, context, scope_opts)
    end
  end

  defp spawn_from_template(template_name, task, tag, context, scope_opts) do
    # AR-8b / AR-8b-2 F2 / AR-8c: a composer-private template — sandboxed
    # (`:prototype`/`:docker`, no `.prototypes/` scope here → would write the real
    # tree) OR explicitly `composer_private` (the AR-8c `sandbox: :none` system
    # workers, which must only run past the safety gate via the wave-builder) —
    # is never spawnable by the LLM-exposed swarm tool. Resolve through the same
    # `templates()` provider that launches it, then gate on that RESOLVED map via
    # `composer_private_template?/1`: re-resolving the name against the canonical
    # registry would let an overridden `:agent_templates` provider launch a
    # private template the name-based guard never saw (AR-8c review fix).
    case templates().get(template_name) do
      {:ok, template} ->
        if Templates.composer_private_template?(template) do
          {:error, composer_private_error(template_name)}
        else
          do_spawn_from_template(template, template_name, task, tag, context, scope_opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_spawn_from_template(template, template_name, task, tag, context, scope_opts) do
    case jido_runtime().start_subagent(template.module, id: tag) do
      {:ok, subagent_pid} ->
        register_spawned_agent(
          subagent_pid,
          template,
          template_name,
          task,
          tag,
          context,
          scope_opts
        )

      {:error, reason} ->
        {:error,
         Error.execution_error("Failed to spawn agent.",
           phase: :spawn,
           details: %{reason: inspect(reason), template: template_name}
         )}
    end
  end

  defp register_spawned_agent(
         subagent_pid,
         template,
         template_name,
         task,
         tag,
         context,
         scope_opts
       ) do
    visibility = Map.get(template, :forward_context, :public)

    # `child/3` resets :agent_template to nil; set it explicitly (the contract
    # at ToolContext.child/2) so the per-template approval policy and durable
    # compaction identity see the spawning template. Before register_child_
    # correlation so the correlation row resolves from the same context.
    base_tool_context =
      context
      |> Map.get(:tool_context)
      |> JidoClaw.ToolContext.child(tag, visibility)
      |> Map.put(:agent_template, template_name)

    child_tool_context =
      Map.put(base_tool_context, :swarm_depth, swarm_depth(context) + 1)

    case JidoClaw.register_child_correlation(child_tool_context) do
      {:ok, request_id} ->
        tracker_opts = Keyword.put(scope_opts, :request_id, request_id)

        case agent_tracker().register(tag, subagent_pid, template_name, task, tracker_opts) do
          :ok ->
            start_orchestration(
              subagent_pid,
              template,
              template_name,
              task,
              tag,
              child_tool_context,
              request_id
            )

          {:error, :agent_id_taken} ->
            # The sub-agent started but the tracker never adopted it — reclaim
            # it, mirroring the start_orchestration failure branch: an untracked
            # agent is invisible to the TTL sweep and would leak alive forever.
            _ = jido_runtime().stop_agent(subagent_pid)
            {:error, agent_id_taken_error(tag)}
        end

      # Marked registration failed (AR-2 Phase 2b C4) — stop the freshly-spawned
      # worker (it has no durable marker row) rather than orchestrate an
      # un-sanitized turn. Same reclaim as the `:agent_id_taken` branch.
      {:error, reason} ->
        _ = jido_runtime().stop_agent(subagent_pid)

        {:error,
         Error.execution_error("Failed to register agent correlation.",
           phase: :spawn,
           details: %{reason: inspect(reason), template: template_name}
         )}
    end
  end

  # The orchestration runs in a supervised task, never a bare spawn: the
  # first statement arms the tracker's orchestrator monitor (backstop for
  # uncatchable kills), and the try/catch is the primary terminal writer for
  # orchestration crashes. Both converge on the from-`:running`-only
  # transition, so a double-fire is a harmless no-op.
  defp start_orchestration(
         subagent_pid,
         template,
         template_name,
         task,
         tag,
         child_tool_context,
         request_id
       ) do
    start_result =
      Task.Supervisor.start_child(task_supervisor(), fn ->
        agent_tracker().attach_orchestrator(tag, self())

        # Bounded: register the spawning template's allowlisted external MCP
        # proxies onto the sub-agent before its turn runs. Blocks only this
        # task, never the caller/Consumer. Best-effort (`:skipped` with no
        # Consumer; `:partial`/`:timeout` just means a tool-less turn).
        _ = mcp().ensure_attached(subagent_pid, template_name, 8_000)

        # AR-5: inject the doctrine system prompt onto the worker before its turn
        # runs — the first system prompt spawn workers receive. Best-effort + gated;
        # runs inside the Task so it never blocks the caller, before the first
        # SubagentTranscript.run.
        _ =
          JidoClaw.Startup.inject_subagent_prompt(
            subagent_pid,
            template_name,
            child_tool_context
          )

        try do
          SubagentTranscript.record_task(child_tool_context, request_id, task)

          outcome =
            SubagentTranscript.run(
              template.module,
              subagent_pid,
              task,
              request_id,
              child_tool_context
            )

          # Persist the terminal row BEFORE marking the tracker complete, so
          # get_agent_result / inspection never observe a completed tracker
          # racing missing durable history.
          status = SubagentTranscript.record_result(child_tool_context, request_id, outcome)
          agent_tracker().mark_complete(tag, status)
        catch
          # An orchestration crash must not strand the entry `:running` (it
          # would consume the spawn cap until the child dies).
          kind, reason ->
            agent_tracker().mark_complete(tag, :error)

            Logger.warning("[SpawnAgent] orchestration for #{tag} #{kind}: #{inspect(reason)}")
        end
      end)

    case start_result do
      {:ok, _task_pid} ->
        {:ok,
         %{
           agent_id: tag,
           template: template_name,
           description: template.description,
           status: "spawned",
           message:
             "Agent '#{tag}' spawned with template '#{template_name}'. Use get_agent_result to collect the result when done."
         }}

      {:error, reason} ->
        # No orchestration will ever drive this entry: force it terminal and
        # reclaim the just-started sub-agent so neither consumes the spawn cap.
        agent_tracker().mark_complete(tag, :error)
        _ = jido_runtime().stop_agent(subagent_pid)

        {:error,
         Error.execution_error("Failed to start agent orchestration.",
           phase: :spawn,
           details: %{reason: inspect(reason), template: template_name, agent_id: tag}
         )}
    end
  end

  defp agent_id_for(template_name, params) do
    case Map.get(params, :tag) do
      tag when is_binary(tag) and byte_size(tag) > 0 ->
        with :ok <- ensure_agent_id_available(tag) do
          {:ok, tag}
        end

      _ ->
        {:ok, generated_agent_id(template_name)}
    end
  end

  defp generated_agent_id(template_name) do
    "#{template_name}_#{Ecto.UUID.generate()}"
  end

  defp ensure_agent_id_available(tag) do
    cond do
      agent_tracker().get_agent(tag) != nil ->
        {:error, agent_id_taken_error(tag)}

      jido_runtime().whereis(tag) != nil ->
        {:error, agent_id_taken_error(tag)}

      true ->
        :ok
    end
  end

  defp agent_id_taken_error(tag) do
    Error.validation_error("Agent ID '#{tag}' is already in use.",
      field: :tag,
      value: tag,
      details: %{reason: :agent_id_taken}
    )
  end

  defp composer_private_error(template_name) do
    Error.execution_error(
      "Template '#{template_name}' is composer-private (sandboxed) and cannot be spawned directly.",
      phase: :spawn,
      details: %{reason: :composer_private, template: template_name}
    )
  end

  defp enforce_spawn_limits(context, scope_opts) do
    current_children = agent_tracker().child_count(scope_opts)
    child_limit = max_children()
    current_depth = swarm_depth(context)
    depth_limit = max_depth()

    cond do
      current_children >= child_limit ->
        {:error,
         Error.execution_error(
           "Maximum concurrent child agents for this scope reached (#{current_children}/#{child_limit}).",
           phase: :spawn_limit,
           details: %{reason: :max_children, limit: child_limit, current: current_children}
         )}

      current_depth >= depth_limit ->
        {:error,
         Error.execution_error(
           "Maximum swarm depth reached (#{current_depth}/#{depth_limit}).",
           phase: :spawn_limit,
           details: %{reason: :max_depth, limit: depth_limit, depth: current_depth}
         )}

      true ->
        :ok
    end
  end

  defp max_children do
    case Application.get_env(:jido_claw, :spawn_agent_max_children, 8) do
      max when is_integer(max) and max >= 0 -> max
      _ -> 8
    end
  end

  defp max_depth do
    case Application.get_env(:jido_claw, :spawn_agent_max_depth, 1) do
      max when is_integer(max) and max >= 0 -> max
      _ -> 1
    end
  end

  defp swarm_depth(context) do
    case get_in(context, [:tool_context, :swarm_depth]) do
      depth when is_integer(depth) and depth >= 0 -> depth
      _ -> 0
    end
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp task_supervisor do
    Application.get_env(:jido_claw, :task_supervisor, JidoClaw.TaskSupervisor)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, AgentTracker)
  end

  defp templates do
    Application.get_env(:jido_claw, :agent_templates, Templates)
  end

  # Kept apart from the sibling Application.get_env/3 seams above: three
  # byte-identical seams clustered across this and send_to_agent.ex trip the
  # cross-file duplicate-clone gate; split, the shared block stays under it.
  defp mcp do
    Application.get_env(:jido_claw, :mcp_facade, JidoClaw.MCP)
  end
end
