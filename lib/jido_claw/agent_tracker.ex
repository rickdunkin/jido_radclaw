defmodule JidoClaw.AgentTracker do
  @moduledoc """
  Per-agent stat accumulator. Tracks tokens, tool calls, status, and cost
  for every agent (main + children). Subscribes to the SignalBus for
  tool and agent lifecycle events. Monitors child agent processes.

  ## Relationship to `JidoClaw.Trace`

  AgentTracker maintains **per-agent rollups** — totals and current
  status used by the swarm/display UI. `JidoClaw.Trace` maintains the
  **per-request event timeline** for the same telemetry stream. The
  two views answer different questions: AgentTracker says "how is
  this agent doing overall", Trace says "what happened during request
  R". Both attach to the same `[:jido, :ai, :tool, :execute, *]`
  events; telemetry is multi-listener, so they don't conflict.
  """

  use GenServer

  defmodule AgentEntry do
    @moduledoc false
    defstruct [
      :id,
      :pid,
      :template,
      :task,
      :tenant_id,
      :session_id,
      :session_uuid,
      :workspace_id,
      :workspace_uuid,
      :parent_agent_id,
      :started_at,
      :finished_at,
      :error,
      :last_tool,
      :request_id,
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

  @doc """
  Register an agent for tracking. Monitors the pid for crash detection.

  Accepts an optional keyword list:

    * `:request_id` — initial Jido.AI request id for this agent. Stored
      so request-scoped `await_completion` callers (Tools.GetAgentResult)
      can read the request map at `state.requests[request_id]` instead of
      falling back to `:last_answer`.
    * `:tenant_id`, `:session_id`, `:session_uuid`, `:workspace_id`,
      `:workspace_uuid`, `:parent_agent_id` — ownership scope used by public
      projections and tenant-facing swarm tools before they touch the global
      runtime registry.
  """
  def register(id, pid, template, task \\ nil, opts \\ []) do
    scope = scope_from_opts(opts)
    GenServer.call(__MODULE__, {:register, id, pid, template, task, scope})
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

  @doc """
  Update the tracked `:request_id` for an agent. Called by `send_to_agent`
  after each follow-up turn so `get_agent_result` reads the latest request's
  typed output, not the initial spawn's. No-op if the agent is not tracked.
  """
  @spec update_request_id(String.t(), String.t()) :: :ok
  def update_request_id(id, request_id) when is_binary(id) and is_binary(request_id) do
    GenServer.call(__MODULE__, {:update_request_id, id, request_id})
  end

  @doc """
  Return tracker state (agents map + order).

  `get_state/0` is the trusted local/admin shape. Tenant-facing callers must
  pass `tenant_id: ...` (and optional session/workspace filters); unscoped
  entries are excluded from scoped reads.
  """
  def get_state(opts \\ []) do
    GenServer.call(__MODULE__, {:get_state, opts})
  end

  @doc """
  Return stats for a single agent.

  When scope opts are supplied, a real agent in another tenant/session returns
  `nil`, making "wrong tenant" indistinguishable from "unknown id" at public
  boundaries.
  """
  def get_agent(id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_agent, id, opts})
  end

  @doc "Return count of non-main agents, optionally filtered by tenant/session/workspace scope."
  def child_count(opts \\ []) do
    GenServer.call(__MODULE__, {:child_count, opts})
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
  def handle_call({:register, id, pid, template, task, scope}, _from, state) do
    if Map.has_key?(state.agents, id) do
      {:reply, {:error, :agent_id_taken}, state}
    else
      entry = %AgentEntry{
        id: id,
        pid: pid,
        template: template,
        task: task,
        request_id: scope.request_id,
        tenant_id: scope.tenant_id,
        session_id: scope.session_id,
        session_uuid: scope.session_uuid,
        workspace_id: scope.workspace_id,
        workspace_uuid: scope.workspace_uuid,
        parent_agent_id: scope.parent_agent_id,
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
  end

  def handle_call({:get_state, opts}, _from, state) do
    agents = filter_agents(state.agents, opts)
    ordered_ids = state.order |> Enum.reverse() |> Enum.filter(&Map.has_key?(agents, &1))
    {:reply, %{agents: agents, order: ordered_ids}, state}
  end

  def handle_call({:get_agent, id, opts}, _from, state) do
    entry =
      state.agents
      |> Map.get(id)
      |> filter_agent(opts)

    {:reply, entry, state}
  end

  def handle_call({:child_count, opts}, _from, state) do
    count =
      state.agents
      |> filter_agents(opts)
      |> Enum.count(fn {id, _} -> id != "main" end)

    {:reply, count, state}
  end

  def handle_call({:update_request_id, id, rid}, _from, state) do
    {:reply, :ok, update_agent(state, id, fn entry -> %{entry | request_id: rid} end)}
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

  defp scope_from_opts(opts) do
    %{
      request_id: Keyword.get(opts, :request_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      session_id: Keyword.get(opts, :session_id),
      session_uuid: Keyword.get(opts, :session_uuid),
      workspace_id: Keyword.get(opts, :workspace_id),
      workspace_uuid: Keyword.get(opts, :workspace_uuid),
      parent_agent_id: Keyword.get(opts, :parent_agent_id)
    }
  end

  defp filter_agents(agents, []), do: agents

  defp filter_agents(agents, opts) when is_list(opts) do
    agents
    |> Enum.filter(fn {_id, entry} -> scoped_entry?(entry, opts) end)
    |> Map.new()
  end

  defp filter_agent(nil, _opts), do: nil
  defp filter_agent(entry, []), do: entry
  defp filter_agent(entry, opts), do: if(scoped_entry?(entry, opts), do: entry)

  defp scoped_entry?(entry, opts) do
    Enum.all?(scope_keys(), fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> false
        {:ok, ""} -> false
        {:ok, value} -> Map.get(entry, key) == value
        :error -> true
      end
    end)
  end

  @doc """
  Canonical ownership scope keys used to **filter** tenant-facing reads
  (`scoped_entry?/2`). The overloaded runtime `:workspace_id` is
  intentionally absent — swarm ownership keys on the durable
  `:workspace_uuid` instead. `JidoClaw.SwarmView` and
  `JidoClaw.Tools.SwarmScope` delegate here so the set is defined once.

  This governs filtering only. `scope_from_opts/1` and the `AgentEntry`
  shape still carry registration metadata (`:request_id`, and the
  vestigial `:workspace_id`) that is not an ownership key.
  """
  @spec scope_keys() :: [atom()]
  def scope_keys do
    [:tenant_id, :session_id, :session_uuid, :workspace_uuid, :parent_agent_id]
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
