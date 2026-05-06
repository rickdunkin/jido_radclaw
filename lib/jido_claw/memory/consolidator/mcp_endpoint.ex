defmodule JidoClaw.Memory.Consolidator.MCPEndpoint do
  @moduledoc """
  Per-run Bandit endpoint that fronts the consolidator's MCP server
  on a loopback port.

  Each `start_link/1` call spawns a fresh listener bound to
  `127.0.0.1:0` (kernel-assigned port). The harness gets the URL
  `http://127.0.0.1:<port>/run/<run_id>` and speaks MCP JSON-RPC
  through it. `stop/1` tears the listener down at run cleanup.
  """

  @doc """
  Start a Bandit listener for the supplied `run_id`. Returns
  `{:ok, %{pid:, port:, url:}}`.
  """
  @spec start_link(String.t()) :: {:ok, %{pid: pid(), port: pos_integer(), url: String.t()}}
  def start_link(run_id) when is_binary(run_id) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {JidoClaw.Memory.Consolidator.Plug, []},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    port = bound_port(pid)
    url = "http://127.0.0.1:#{port}/run/#{run_id}"
    {:ok, %{pid: pid, port: port, url: url}}
  end

  @doc "Stop a Bandit endpoint started with `start_link/1`."
  @spec stop(map()) :: :ok
  def stop(%{pid: pid}) when is_pid(pid) do
    try do
      Supervisor.stop(pid, :normal, 5_000)
      :ok
    catch
      _, _ -> :ok
    end
  end

  def stop(_), do: :ok

  defp bound_port(pid) do
    case ThousandIsland.listener_info(pid) do
      {:ok, {_addr, port}} -> port
      {_addr, port} -> port
    end
  end
end
