defmodule JidoClaw.Stats do
  @moduledoc """
  GenServer that accumulates session-level statistics.

  Tracks message counts, token usage, tool call invocations,
  and agent spawns for the current REPL session.
  """

  use GenServer
  require Logger

  alias JidoClaw.SignalBus

  defstruct messages: 0,
            tokens: 0,
            tool_calls: 0,
            agents_spawned: 0,
            solutions_stored: 0,
            solutions_found: 0,
            network_shares: 0,
            started_at: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment the message count for a given role (:user | :assistant)."
  @spec track_message(:user | :assistant) :: :ok
  def track_message(_role) do
    GenServer.cast(__MODULE__, :track_message)
  end

  @doc "Increment the tool call counter. Optionally associates with an agent_id."
  @spec track_tool_call(String.t()) :: :ok
  def track_tool_call(name) when is_binary(name) do
    track_tool_call("main", name)
  end

  @spec track_tool_call(String.t(), String.t()) :: :ok
  def track_tool_call(agent_id, name) when is_binary(agent_id) and is_binary(name) do
    GenServer.cast(__MODULE__, {:track_tool_call, agent_id, name})
  end

  @doc "Add token usage to the running total."
  @spec track_tokens(non_neg_integer()) :: :ok
  def track_tokens(count) when is_integer(count) and count >= 0 do
    GenServer.cast(__MODULE__, {:track_tokens, count})
  end

  @doc "Increment the spawned-agent counter."
  @spec track_agent_spawn(term()) :: :ok
  def track_agent_spawn(template) do
    GenServer.cast(__MODULE__, {:track_agent_spawn, template})
  end

  @doc "Increment the solutions stored counter."
  @spec track_solution_stored() :: :ok
  def track_solution_stored do
    GenServer.cast(__MODULE__, :track_solution_stored)
  end

  @doc "Increment the solutions found counter."
  @spec track_solution_found() :: :ok
  def track_solution_found do
    GenServer.cast(__MODULE__, :track_solution_found)
  end

  @doc "Increment the network shares counter."
  @spec track_network_share() :: :ok
  def track_network_share do
    GenServer.cast(__MODULE__, :track_network_share)
  end

  @doc "Return a snapshot of the current stats."
  @spec get() :: %{
          messages: non_neg_integer(),
          tokens: non_neg_integer(),
          tool_calls: non_neg_integer(),
          agents_spawned: non_neg_integer(),
          solutions_stored: non_neg_integer(),
          solutions_found: non_neg_integer(),
          network_shares: non_neg_integer(),
          uptime_seconds: non_neg_integer()
        }
  def get do
    GenServer.call(__MODULE__, :get)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    SignalBus.subscribe("jido_claw.tool.*")
    SignalBus.subscribe("jido_claw.agent.*")
    SignalBus.subscribe("jido_claw.memory.*")
    SignalBus.subscribe("jido_claw.skill.*")
    {:ok, %__MODULE__{started_at: System.monotonic_time(:second)}}
  end

  @impl GenServer
  def handle_cast(:track_message, state) do
    {:noreply, %{state | messages: state.messages + 1}}
  end

  def handle_cast({:track_tool_call, agent_id, name}, state) do
    SignalBus.emit("jido_claw.tool.complete", %{agent_id: agent_id, name: name})
    # Also update AgentTracker for per-agent stats
    JidoClaw.AgentTracker.track_tool(agent_id, name)
    {:noreply, %{state | tool_calls: state.tool_calls + 1}}
  end

  def handle_cast({:track_tokens, count}, state) do
    {:noreply, %{state | tokens: state.tokens + count}}
  end

  def handle_cast({:track_agent_spawn, template}, state) do
    SignalBus.emit("jido_claw.agent.spawned", %{template: inspect(template)})
    {:noreply, %{state | agents_spawned: state.agents_spawned + 1}}
  end

  def handle_cast(:track_solution_stored, state) do
    {:noreply, %{state | solutions_stored: state.solutions_stored + 1}}
  end

  def handle_cast(:track_solution_found, state) do
    {:noreply, %{state | solutions_found: state.solutions_found + 1}}
  end

  def handle_cast(:track_network_share, state) do
    {:noreply, %{state | network_shares: state.network_shares + 1}}
  end

  # Signal handlers — these receive signals from OTHER emitters (not self).
  # Stats itself emits signals in handle_cast, so we only log here to avoid double-counting.
  @impl GenServer
  def handle_info({:signal, %{type: type} = signal}, state) do
    Logger.debug("[Stats] Signal received: #{type} — #{inspect(Map.get(signal, :data, %{}))}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    uptime = System.monotonic_time(:second) - state.started_at

    snapshot = %{
      messages: state.messages,
      tokens: state.tokens,
      tool_calls: state.tool_calls,
      agents_spawned: state.agents_spawned,
      solutions_stored: state.solutions_stored,
      solutions_found: state.solutions_found,
      network_shares: state.network_shares,
      uptime_seconds: uptime
    }

    {:reply, snapshot, state}
  end
end
