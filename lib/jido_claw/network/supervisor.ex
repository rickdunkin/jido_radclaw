defmodule JidoClaw.Network.Supervisor do
  @moduledoc """
  Supervisor for the network layer.

  Starts and supervises `JidoClaw.Network.Node` under a `:one_for_one`
  strategy. Restart opts are forwarded to the node on start_link.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {JidoClaw.Network.Node, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
