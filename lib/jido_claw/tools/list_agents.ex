defmodule JidoClaw.Tools.ListAgents do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "list_agents",
    description: "List all running child agents with their status, template, and basic info.",
    category: "swarm",
    tags: ["swarm", "read"],
    output_schema: [
      agents: [type: :string, required: true],
      count: [type: :integer, required: true]
    ],
    schema: []

  alias JidoClaw.Tools.SwarmScope

  @impl Jido.Action
  def run(_params, context) do
    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         {:ok, view} <- JidoClaw.SwarmView.list(scope_opts) do
      if view.agents == [] do
        {:ok, %{agents: "No child agents running.", count: 0}}
      else
        lines =
          Enum.map(view.agents, fn agent ->
            "#{agent.agent_id} | #{agent.status} | #{agent.template || "unknown"}"
          end)

        {:ok, %{agents: Enum.join(lines, "\n"), count: length(view.agents)}}
      end
    end
  end
end
