defmodule JidoClaw.Test.CapturingAgent do
  @moduledoc """
  Test-only GenServer standing in for a Jido agent pid on the signal-call
  paths JidoClaw uses to configure a running agent:

    * `ai.react.set_system_prompt` → forwards `{:injected_prompt, prompt}`
    * `ai.react.context.modify`    → forwards `{:context_modify, data}`
    * any other signal             → forwards `{:signal, type, data}`

  Mirrors the real call chain (`Jido.AI.set_system_prompt/2` /
  `JidoClaw.Conversations.ContextRestore.restore/4` →
  `Jido.AgentServer.call/3` → `GenServer.call(pid, {:signal, signal})`,
  replying `{:ok, _}`). A plain GenServer is sufficient — those paths only do
  a signal call; they do not require a real Jido agent.
  """

  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_call(
        {:signal, %{type: "ai.react.set_system_prompt", data: %{system_prompt: prompt}}},
        _from,
        test_pid
      ) do
    send(test_pid, {:injected_prompt, prompt})
    {:reply, {:ok, %{}}, test_pid}
  end

  def handle_call(
        {:signal, %{type: "ai.react.context.modify", data: data}},
        _from,
        test_pid
      ) do
    send(test_pid, {:context_modify, data})
    {:reply, {:ok, %{}}, test_pid}
  end

  def handle_call({:signal, %{type: type, data: data}}, _from, test_pid) do
    send(test_pid, {:signal, type, data})
    {:reply, {:ok, %{}}, test_pid}
  end
end
