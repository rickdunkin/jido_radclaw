defmodule JidoClaw.Tools.NetworkStatus do
  @moduledoc """
  Tool that checks the agent network connection status and peer count.
  """

  use Jido.Action,
    name: "network_status",
    description: "Check the agent network connection status and peer count.",
    schema: []

  @impl true
  def run(_params, _context) do
    status = JidoClaw.Network.Node.status()

    formatted =
      """
      Network Status: #{status.status}
      Agent ID: #{status.agent_id || "none"}
      Peers: #{status.peer_count}
      """
      |> String.trim()

    {:ok,
     %{status: formatted, connected: status.status == :connected, peer_count: status.peer_count}}
  end
end
