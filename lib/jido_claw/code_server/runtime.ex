defmodule JidoClaw.CodeServer.Runtime do
  @moduledoc false
  use GenServer
  require Logger

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(project_path) do
    GenServer.start_link(__MODULE__, project_path,
      name: {:via, Registry, {JidoClaw.CodeServer.RuntimeRegistry, project_path}}
    )
  end

  @impl GenServer
  def init(project_path) do
    Logger.info("[CodeServer.Runtime] Started for #{project_path}")
    {:ok, %{project_path: project_path, conversations: %{}, started_at: DateTime.utc_now()}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
