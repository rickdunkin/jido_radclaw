defmodule JidoClaw.CodeServer do
  require Logger

  @doc "Ensure a project runtime is started for the given project path."
  def ensure_project_runtime(project_path) when is_binary(project_path) do
    case Registry.lookup(JidoClaw.CodeServer.RuntimeRegistry, project_path) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_runtime(project_path)
    end
  end

  @doc "Start a conversation within a project runtime."
  def start_conversation(project_path, opts \\ []) do
    with {:ok, _pid} <- ensure_project_runtime(project_path) do
      conv_id = Keyword.get(opts, :id, "conv_#{:erlang.unique_integer([:positive])}")
      {:ok, conv_id}
    end
  end

  @doc "Send a user message to a conversation."
  def send_user_message(project_path, conv_id, message, opts \\ []) do
    with {:ok, _pid} <- ensure_project_runtime(project_path) do
      Logger.debug("[CodeServer] Message to #{conv_id}: #{String.slice(message, 0, 100)}")

      Phoenix.PubSub.broadcast(
        JidoClaw.PubSub,
        "code_server:#{project_path}:#{conv_id}",
        {:user_message, message, opts}
      )

      :ok
    end
  end

  @doc "Subscribe to conversation events."
  def subscribe(project_path, conv_id, _pid \\ self()) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, "code_server:#{project_path}:#{conv_id}")
  end

  @doc "Stop a conversation."
  def stop_conversation(project_path, conv_id) do
    Phoenix.PubSub.broadcast(
      JidoClaw.PubSub,
      "code_server:#{project_path}:#{conv_id}",
      {:stop_conversation, conv_id}
    )

    :ok
  end

  defp start_runtime(project_path) do
    spec = {JidoClaw.CodeServer.Runtime, project_path}

    case DynamicSupervisor.start_child(JidoClaw.CodeServer.RuntimeSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end
end
