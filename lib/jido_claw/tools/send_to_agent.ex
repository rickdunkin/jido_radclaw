defmodule JidoClaw.Tools.SendToAgent do
  @moduledoc false
  use Jido.Action,
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

  alias JidoClaw.Agent.Templates

  @impl true
  def run(params, context) do
    case JidoClaw.Jido.whereis(params.agent_id) do
      nil ->
        {:error, "Agent '#{params.agent_id}' not found."}

      pid ->
        # Look up the template to get the agent module for ask_sync
        # Extract template name from the agent_id prefix
        template_name =
          params.agent_id
          |> String.split("_")
          |> List.first()

        child_tool_context =
          JidoClaw.ToolContext.child(Map.get(context, :tool_context), params.agent_id)

        request_id = JidoClaw.register_child_correlation(child_tool_context)

        # Send async via the agent module's ask
        spawn(fn ->
          try do
            case Templates.get(template_name) do
              {:ok, template} ->
                template.module.ask_sync(pid, params.message,
                  timeout: 120_000,
                  request_id: request_id,
                  tool_context: child_tool_context
                )

              {:error, _} ->
                JidoClaw.Agent.ask_sync(pid, params.message,
                  timeout: 120_000,
                  request_id: request_id,
                  tool_context: child_tool_context
                )
            end
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
    end
  end
end
