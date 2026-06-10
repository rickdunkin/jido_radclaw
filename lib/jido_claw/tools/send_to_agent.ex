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

  alias JidoClaw.Conversations.SubagentTranscript
  alias JidoClaw.Error
  alias JidoClaw.Tools.SwarmScope

  @impl Jido.Action
  def run(params, context) do
    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         {:ok, entry} <- SwarmScope.scoped_agent(agent_tracker(), params.agent_id, scope_opts) do
      case jido_runtime().whereis(params.agent_id) do
        nil ->
          {:error, Error.not_found(:agent, params.agent_id)}

        pid ->
          send_to_agent(pid, params, context, entry)
      end
    end
  end

  defp send_to_agent(pid, params, context, entry) do
    case template_for_agent(params.agent_id, entry) do
      {:ok, template} ->
        # Re-apply the template's forward_context on every follow-up so a
        # child can't be re-widened mid-conversation.
        visibility = Map.get(template, :forward_context, :public)

        child_tool_context =
          JidoClaw.ToolContext.child(Map.get(context, :tool_context), params.agent_id, visibility)

        request_id = JidoClaw.register_child_correlation(child_tool_context)

        agent_tracker().update_request_id(params.agent_id, request_id)

        spawn(fn ->
          SubagentTranscript.record_task(child_tool_context, request_id, params.message)

          outcome =
            SubagentTranscript.run(
              template.module,
              pid,
              params.message,
              request_id,
              child_tool_context
            )

          _ = SubagentTranscript.record_result(child_tool_context, request_id, outcome)
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

  defp template_for_agent(agent_id, entry) do
    case entry do
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
