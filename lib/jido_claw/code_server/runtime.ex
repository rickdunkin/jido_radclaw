defmodule JidoClaw.CodeServer.Runtime do
  use GenServer
  require Logger

  def start_link(project_path) do
    GenServer.start_link(__MODULE__, project_path,
      name: {:via, Registry, {JidoClaw.CodeServer.RuntimeRegistry, project_path}}
    )
  end

  @impl true
  def init(project_path) do
    Logger.info("[CodeServer.Runtime] Started for #{project_path}")
    {:ok, %{project_path: project_path, conversations: %{}, started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
