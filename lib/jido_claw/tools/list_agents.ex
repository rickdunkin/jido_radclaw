defmodule JidoClaw.Tools.ListAgents do
  use Jido.Action,
    name: "list_agents",
    description: "List all running child agents with their status, template, and basic info.",
    schema: []

  @impl true
  def run(_params, _context) do
    agents = JidoClaw.Jido.list_agents()

    if agents == [] do
      {:ok, %{agents: "No child agents running.", count: 0}}
    else
      lines =
        Enum.map(agents, fn {id, pid} ->
          status = if Process.alive?(pid), do: "running", else: "stopped"
          "#{id} | #{status} | pid=#{inspect(pid)}"
        end)

      {:ok, %{agents: Enum.join(lines, "\n"), count: length(agents)}}
    end
  end
end
