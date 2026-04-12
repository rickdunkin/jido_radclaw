defmodule JidoClaw.Tools.NetworkShare do
  @moduledoc """
  Tool that shares a solution with the agent network for other agents to discover and use.
  """

  use Jido.Action,
    name: "network_share",
    description: "Share a solution with the agent network for other agents to discover and use.",
    schema: [
      solution_id: [
        type: :string,
        required: true,
        doc: "ID of the solution to share"
      ]
    ]

  @impl true
  def run(params, _context) do
    case JidoClaw.Network.Node.broadcast_solution(params.solution_id) do
      :ok ->
        {:ok, %{solution_id: params.solution_id, status: "shared"}}

      {:error, :not_connected} ->
        {:ok,
         %{solution_id: params.solution_id, status: "not_shared", reason: "network not connected"}}

      {:error, :not_running} ->
        {:ok,
         %{solution_id: params.solution_id, status: "not_shared", reason: "network not running"}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
