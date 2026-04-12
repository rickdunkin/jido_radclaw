defmodule JidoClaw.Tools.SpawnAgent do
  use Jido.Action,
    name: "spawn_agent",
    description:
      "Spawn a child agent from a template to work on a task. Available templates: coder, test_runner, reviewer, docs_writer, researcher, refactorer, verifier. The child agent works independently and results can be collected with get_agent_result.",
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

  @impl true
  def run(params, context) do
    template_name = params.template
    task = params.task
    tag = Map.get(params, :tag) || "#{template_name}_#{:erlang.unique_integer([:positive])}"

    # Get project_dir from tool context if available
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()

    case JidoClaw.Agent.Templates.get(template_name) do
      {:ok, template} ->
        case JidoClaw.Jido.start_agent(template.module, id: tag) do
          {:ok, pid} ->
            # Register with AgentTracker for live swarm display
            JidoClaw.AgentTracker.register(tag, pid, template_name, task)

            # Send task async - don't block the main agent
            spawn(fn ->
              try do
                template.module.ask_sync(pid, task,
                  timeout: 120_000,
                  tool_context: %{project_dir: project_dir}
                )

                JidoClaw.AgentTracker.mark_complete(tag, :done)
              rescue
                _ -> JidoClaw.AgentTracker.mark_complete(tag, :error)
              catch
                _, _ -> JidoClaw.AgentTracker.mark_complete(tag, :error)
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

          {:error, reason} ->
            {:error, "Failed to spawn agent: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
