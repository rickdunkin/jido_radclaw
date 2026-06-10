defmodule JidoClaw.Tools.NetworkShare do
  @moduledoc """
  Tool that shares a solution with the agent network for other agents to discover and use.
  """

  use JidoClaw.Tools.Action,
    name: "network_share",
    description: "Share a solution with the agent network for other agents to discover and use.",
    category: "solutions",
    tags: ["solutions", "write"],
    output_schema: [
      solution_id: [type: :string, required: true],
      status: [type: :string, required: true],
      reason: [type: :string]
    ],
    schema: [
      solution_id: [
        type: :string,
        required: true,
        doc: "ID of the solution to share"
      ]
    ]

  alias JidoClaw.Tools.MCPScope

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:network_share, params, context, fn _enriched ->
      case JidoClaw.Network.Node.broadcast_solution(params.solution_id) do
        :ok ->
          {:ok, %{solution_id: params.solution_id, status: "shared"}}

        {:error, :not_connected} ->
          {:ok,
           %{
             solution_id: params.solution_id,
             status: "not_shared",
             reason: "network not connected"
           }}

        {:error, :not_running} ->
          {:ok,
           %{
             solution_id: params.solution_id,
             status: "not_shared",
             reason: "network not running"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end
end
