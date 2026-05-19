defmodule JidoClaw.Tools.SendToAgent do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "send_to_agent",
    description: "Send a follow-up message to a running child agent.",
    category: "swarm",
    tags: ["swarm", "write"],
    output_schema: [
      agent_id: [type: :string, required: true],
      status: [type: :string, required: true],
      message: [type: :string, required: true]
    ],
    schema: [
      agent_id: [type: :string, required: true, doc: "The agent ID to send to"],
      message: [type: :string, required: true, doc: "The message to send"]
    ]

  alias JidoClaw.Error

  @impl true
  def run(params, context) do
    case jido_runtime().whereis(params.agent_id) do
      nil ->
        {:error, Error.not_found(:agent, params.agent_id)}

      pid ->
        send_to_agent(pid, params, context)
    end
  end

  defp send_to_agent(pid, params, context) do
    case template_for_agent(params.agent_id) do
      {:ok, template} ->
        child_tool_context =
          JidoClaw.ToolContext.child(Map.get(context, :tool_context), params.agent_id)

        request_id = JidoClaw.register_child_correlation(child_tool_context)

        spawn(fn ->
          try do
            template.module.ask_sync(pid, params.message,
              timeout: 120_000,
              request_id: request_id,
              tool_context: child_tool_context
            )
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        {:ok,
         %{
           agent_id: params.agent_id,
           status: "message_sent",
           message: "Message sent to agent '#{params.agent_id}'"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp template_for_agent(agent_id) do
    case agent_tracker().get_agent(agent_id) do
      %{template: template_name} when is_binary(template_name) ->
        case templates().get(template_name) do
          {:ok, template} ->
            {:ok, template}

          {:error, reason} ->
            {:error,
             Error.execution_error(
               "Template '#{template_name}' for agent '#{agent_id}' is unavailable.",
               phase: :template_lookup,
               details: %{
                 template: template_name,
                 agent_id: agent_id,
                 reason: inspect(reason)
               }
             )}
        end

      nil ->
        {:error,
         Error.execution_error(
           "Agent '#{agent_id}' is running but is not registered in AgentTracker.",
           phase: :tracker_lookup,
           details: %{agent_id: agent_id, reason: :not_registered}
         )}

      other ->
        {:error,
         Error.execution_error("Agent '#{agent_id}' has invalid tracker metadata.",
           phase: :tracker_lookup,
           details: %{agent_id: agent_id, metadata: inspect(other)}
         )}
    end
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, JidoClaw.AgentTracker)
  end

  defp templates do
    Application.get_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)
  end
end
