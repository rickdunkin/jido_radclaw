defmodule JidoClaw.Tools.KillAgent do
  @moduledoc false
  use JidoClaw.Tools.Action,
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

  alias JidoClaw.Error
  alias JidoClaw.Tools.SwarmScope

  @impl true
  def run(%{agent_id: "all"}, context) do
    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context) do
      tracker_state = agent_tracker().get_state(scope_opts)
      children = Enum.reject(tracker_state.agents, fn {id, _entry} -> id == "main" end)

      stopped =
        Enum.count(children, fn {id, _entry} ->
          jido_runtime().stop_agent(id) == :ok
        end)

      {:ok, %{stopped: stopped, message: "Stopped #{stopped} child agent(s)."}}
    end
  end

  def run(params, context) do
    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         {:ok, _entry} <- SwarmScope.scoped_agent(agent_tracker(), params.agent_id, scope_opts) do
      case jido_runtime().stop_agent(params.agent_id) do
        :ok ->
          {:ok, %{agent_id: params.agent_id, status: "stopped"}}

        {:error, :not_found} ->
          {:error, Error.not_found(:agent, params.agent_id)}
      end
    end
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, JidoClaw.AgentTracker)
  end
end
