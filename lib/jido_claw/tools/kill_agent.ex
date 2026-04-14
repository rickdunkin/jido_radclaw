defmodule JidoClaw.Tools.KillAgent do
  use Jido.Action,
    name: "kill_agent",
    description: "Stop a running child agent. Use 'all' as agent_id to stop all child agents.",
    category: "swarm",
    tags: ["swarm", "write"],
    output_schema: [
      agent_id: [type: :string],
      status: [type: :string],
      stopped: [type: :integer],
      message: [type: :string]
    ],
    schema: [
      agent_id: [
        type: :string,
        required: true,
        doc: "The agent ID to stop, or 'all' to stop all agents"
      ]
    ]

  @impl true
  def run(%{agent_id: "all"}, _context) do
    agents = JidoClaw.Jido.list_agents()
    # Don't kill the main agent
    children = Enum.reject(agents, fn {id, _pid} -> id == "main" end)

    Enum.each(children, fn {id, _pid} ->
      JidoClaw.Jido.stop_agent(id)
    end)

    {:ok, %{stopped: length(children), message: "Stopped #{length(children)} child agent(s)."}}
  end

  def run(params, _context) do
    case JidoClaw.Jido.stop_agent(params.agent_id) do
      :ok ->
        {:ok, %{agent_id: params.agent_id, status: "stopped"}}

      {:error, :not_found} ->
        {:error, "Agent '#{params.agent_id}' not found."}

      {:error, reason} ->
        {:error, "Failed to stop agent: #{inspect(reason)}"}
    end
  end
end
