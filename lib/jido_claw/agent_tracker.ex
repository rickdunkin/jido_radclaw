defmodule JidoClaw.AgentTracker do
  @moduledoc """
  Per-agent stat accumulator. Tracks tokens, tool calls, status, and cost
  for every agent (main + children). Subscribes to the SignalBus for
  tool and agent lifecycle events. Monitors child agent processes.
  """

  use GenServer
  require Logger

  defmodule AgentEntry do
    @moduledoc false
    defstruct [
      :id,
      :pid,
      :template,
      :task,
      :started_at,
      :finished_at,
      :error,
      :last_tool,
      status: :running,
      tokens: 0,
      tool_calls: 0,
      tool_names: MapSet.new()
    ]
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register an agent for tracking. Monitors the pid for crash detection."
  def register(id, pid, template, task \\ nil) do
    GenServer.call(__MODULE__, {:register, id, pid, template, task})
  end

  @doc "Record a tool call for an agent."
  def track_tool(agent_id, tool_name) do
    GenServer.cast(__MODULE__, {:track_tool, agent_id, tool_name})
  end

  @doc "Add token usage for an agent."
  def track_tokens(agent_id, count) when is_integer(count) and count >= 0 do
    GenServer.cast(__MODULE__, {:track_tokens, agent_id, count})
  end

  @doc "Mark an agent as completed."
  def mark_complete(id, status \\ :done) when status in [:done, :error] do
    GenServer.cast(__MODULE__, {:mark_complete, id, status})
  end

  @doc "Return the full tracker state (agents map + order)."
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Return stats for a single agent."
  def get_agent(id) do
    GenServer.call(__MODULE__, {:get_agent, id})
  end

  @doc "Return count of non-main agents."
  def child_count do
    GenServer.call(__MODULE__, :child_count)
  end

  @doc "Reset tracker state (e.g. between conversations)."
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{agents: %{}, order: [], monitors: %{}}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    JidoClaw.SignalBus.subscribe("jido_claw.tool.*")
    JidoClaw.SignalBus.subscribe("jido_claw.agent.*")

    :telemetry.attach(
      "agent-tracker-tool-stop",
      [:jido, :ai, :tool, :execute, :stop],
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    :telemetry.attach(
      "agent-tracker-tool-start",
      [:jido, :ai, :tool, :execute, :start],
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    {:noreply, state}
  end

  @doc false
  def handle_telemetry_event(
        [:jido, :ai, :tool, :execute, :start],
        _measurements,
        metadata,
        _config
      ) do
    agent_id = metadata[:agent_id]
    tool_name = metadata[:tool_name]

    if agent_id && tool_name && to_string(agent_id) != "main" do
      track_tool(to_string(agent_id), to_string(tool_name))
    end
  end

  def handle_telemetry_event(
        [:jido, :ai, :tool, :execute, :stop],
        _measurements,
        metadata,
        _config
      ) do
    agent_id = metadata[:agent_id]
    tool_name = metadata[:tool_name]

    if agent_id && to_string(agent_id) != "main" do
      # Also track via tool name for completions (redundant but ensures count)
      if tool_name, do: track_tool(to_string(agent_id), to_string(tool_name))
    end
  end

  def handle_telemetry_event(_, _, _, _), do: :ok

  @impl true
  def handle_call({:register, id, pid, template, task}, _from, state) do
    entry = %AgentEntry{
      id: id,
      pid: pid,
      template: template,
      task: task,
      started_at: System.monotonic_time(:millisecond)
    }

    ref = Process.monitor(pid)

    state = %{
      state
      | agents: Map.put(state.agents, id, entry),
        order: [id | state.order],
        monitors: Map.put(state.monitors, ref, id)
    }

    notify_display({:agent_registered, id, entry})

    {:reply, :ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, %{agents: state.agents, order: Enum.reverse(state.order)}, state}
  end

  def handle_call({:get_agent, id}, _from, state) do
    {:reply, Map.get(state.agents, id), state}
  end

  def handle_call(:child_count, _from, state) do
    count =
      state.agents
      |> Enum.count(fn {id, _} -> id != "main" end)

    {:reply, count, state}
  end

  @impl true
  def handle_cast({:track_tool, agent_id, tool_name}, state) do
    state =
      update_agent(state, agent_id, fn entry ->
        %{
          entry
          | tool_calls: entry.tool_calls + 1,
            tool_names: MapSet.put(entry.tool_names, tool_name),
            last_tool: tool_name
        }
      end)

    notify_display({:agent_tool, agent_id, tool_name})
    {:noreply, state}
  end

  def handle_cast({:track_tokens, agent_id, count}, state) do
    state =
      update_agent(state, agent_id, fn entry ->
        %{entry | tokens: entry.tokens + count}
      end)

    {:noreply, state}
  end

  def handle_cast({:mark_complete, id, status}, state) do
    state =
      update_agent(state, id, fn entry ->
        %{entry | status: status, finished_at: System.monotonic_time(:millisecond)}
      end)

    notify_display({:agent_completed, id, status})
    {:noreply, state}
  end

  def handle_cast(:reset, _state) do
    {:noreply, %{agents: %{}, order: [], monitors: %{}}}
  end

  # Process crash detection
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {agent_id, monitors} ->
        state = %{state | monitors: monitors}

        state =
          update_agent(state, agent_id, fn entry ->
            %{
              entry
              | status: :error,
                finished_at: System.monotonic_time(:millisecond),
                error: inspect(reason)
            }
          end)

        notify_display({:agent_completed, agent_id, :error})
        {:noreply, state}
    end
  end

  # Signal bus events — we log but don't double-count since Stats handles global counters
  def handle_info({:signal, %{type: _type}}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp update_agent(state, agent_id, fun) do
    case Map.get(state.agents, agent_id) do
      nil -> state
      entry -> %{state | agents: Map.put(state.agents, agent_id, fun.(entry))}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("agent-tracker-tool-stop")
    :telemetry.detach("agent-tracker-tool-start")
    :ok
  end

  defp notify_display(message) do
    case GenServer.whereis(JidoClaw.Display) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
