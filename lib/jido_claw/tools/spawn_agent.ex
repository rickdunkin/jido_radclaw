defmodule JidoClaw.Tools.SpawnAgent do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "spawn_agent",
    description:
      "Spawn a child agent from a template to work on a task. Available templates: coder, test_runner, reviewer, docs_writer, researcher, refactorer, verifier. The child agent works independently and results can be collected with get_agent_result.",
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
        doc:
          "Agent template name (coder, test_runner, reviewer, docs_writer, researcher, refactorer, verifier)"
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

  alias JidoClaw.Agent.Templates
  alias JidoClaw.AgentTracker
  alias JidoClaw.Error

  @impl true
  def run(params, context) do
    template_name = params.template
    task = params.task

    with :ok <- enforce_spawn_limits(context),
         {:ok, tag} <- agent_id_for(template_name, params) do
      spawn_from_template(template_name, task, tag, context)
    end
  end

  defp spawn_from_template(template_name, task, tag, context) do
    case templates().get(template_name) do
      {:ok, template} ->
        case jido_runtime().start_agent(template.module, id: tag) do
          {:ok, pid} ->
            register_spawned_agent(pid, template, template_name, task, tag, context)

          {:error, reason} ->
            {:error,
             Error.execution_error("Failed to spawn agent.",
               phase: :spawn,
               details: %{reason: inspect(reason), template: template_name}
             )}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_spawned_agent(pid, template, template_name, task, tag, context) do
    visibility = Map.get(template, :forward_context, :public)

    child_tool_context =
      JidoClaw.ToolContext.child(Map.get(context, :tool_context), tag, visibility)
      |> Map.put(:swarm_depth, swarm_depth(context) + 1)

    request_id = JidoClaw.register_child_correlation(child_tool_context)

    case agent_tracker().register(tag, pid, template_name, task, request_id: request_id) do
      :ok ->
        spawn(fn ->
          try do
            case template.module.ask_sync(pid, task,
                   timeout: 120_000,
                   request_id: request_id,
                   tool_context: child_tool_context
                 ) do
              {:ok, _result} -> agent_tracker().mark_complete(tag, :done)
              {:error, _reason} -> agent_tracker().mark_complete(tag, :error)
              _other -> agent_tracker().mark_complete(tag, :done)
            end
          rescue
            _ -> agent_tracker().mark_complete(tag, :error)
          catch
            _, _ -> agent_tracker().mark_complete(tag, :error)
          end
        end)

        {:ok,
         %{
           agent_id: tag,
           template: template_name,
           description: template.description,
           status: "spawned",
           message:
             "Agent '#{tag}' spawned with template '#{template_name}'. Use get_agent_result to collect the result when done."
         }}

      {:error, :agent_id_taken} ->
        {:error, agent_id_taken_error(tag)}
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

  defp enforce_spawn_limits(context) do
    current_children = agent_tracker().child_count()
    child_limit = max_children()
    current_depth = swarm_depth(context)
    depth_limit = max_depth()

    cond do
      current_children >= child_limit ->
        {:error,
         Error.execution_error(
           "Maximum concurrent child agents reached (#{current_children}/#{child_limit}).",
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
    context
    |> get_in([:tool_context, :swarm_depth])
    |> case do
      depth when is_integer(depth) and depth >= 0 -> depth
      _ -> 0
    end
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, AgentTracker)
  end

  defp templates do
    Application.get_env(:jido_claw, :agent_templates, Templates)
  end
end
