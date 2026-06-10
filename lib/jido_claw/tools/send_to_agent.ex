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

  require Logger

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

        # Fallible setup (correlation registration touches Postgres) runs
        # BEFORE the tracker gate, so a raise here leaves the entry untouched.
        request_id = JidoClaw.register_child_correlation(child_tool_context)

        dispatch(pid, params, template, child_tool_context, request_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(pid, params, template, child_tool_context, request_id) do
    agent_id = params.agent_id

    # mark_running is the last gate before dispatch: it re-activates a
    # terminal entry (follow-up to a finished agent) only while the tracked
    # pid matches the dispatch target and is still alive — so a `:running`
    # entry always has an armed monitor behind it, and an expired/dead agent
    # reads as not_found instead of being resurrected.
    case agent_tracker().mark_running(agent_id, pid) do
      :ok ->
        agent_tracker().update_request_id(agent_id, request_id)

        spawn(fn ->
          try do
            SubagentTranscript.record_task(child_tool_context, request_id, params.message)

            outcome =
              SubagentTranscript.run(
                template.module,
                pid,
                params.message,
                request_id,
                child_tool_context
              )

            status = SubagentTranscript.record_result(child_tool_context, request_id, outcome)
            agent_tracker().mark_complete(agent_id, status)
          catch
            # An orchestration crash must not strand the re-activated entry
            # `:running` (it would consume the spawn cap until the child dies).
            kind, reason ->
              agent_tracker().mark_complete(agent_id, :error)

              Logger.warning(
                "[SendToAgent] follow-up orchestration for #{agent_id} #{kind}: #{inspect(reason)}"
              )
          end
        end)

        {:ok,
         %{
           agent_id: agent_id,
           status: "message_sent",
           message: "Message sent to agent '#{agent_id}'"
         }}

      {:error, :not_found} ->
        {:error, Error.not_found(:agent, agent_id)}
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
