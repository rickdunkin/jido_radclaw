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

  ## Lifecycle & retention

  `child_count/1` counts only `:running` non-main entries, so the spawn
  cap is a *concurrency* limit, not a cumulative one. Terminal
  (`:done`/`:error`) entries are retained for observability (swarm
  status, display summaries, history) until a periodic sweep expires
  them: once a terminal entry is older than the terminal TTL, the sweep
  first stops the idle child process (deduplicated across sweeps), and
  only evicts the entry once its pid is dead. Two invariants hold:

    1. A live runtime agent always has a tracker entry — scoped tools
       prove tenant ownership through the entry before touching the
       runtime, so expiry stops the child first and never evicts a
       live pid.
    2. An entry is `:running` only while its pid is alive and
       monitored — `mark_running/2` validates pid identity + liveness,
       and both terminal writers (`mark_complete` + `:DOWN`) transition
       only from `:running`, so a finished entry can never silently
       consume the spawn cap with nothing left to complete it.
    3. A `:running` entry's *orchestrator* (the supervised task driving
       the run, attached via `attach_orchestrator/2`) is monitored too —
       if it dies without writing a terminal status, its `:DOWN` forces
       the entry to `:error` so an orchestration kill can never strand
       the entry `:running` (consuming the spawn cap) behind a live,
       idle agent the terminal-only sweep would never collect. The
       orchestrator's own `mark_complete` cast always arrives before its
       `:DOWN` (same sender, same receiver), so a normal exit never
       reads as "orchestrator died". Accepted residuals: the tool
       process dying between `register` and the task's
       `attach_orchestrator` (a microsecond window inside one tool call
       — the whole call fails with it); a superseded orchestrator's
       late `mark_complete` landing on a re-engaged entry (benign:
       wrong-but-terminal beats stuck-`:running`; the dangerous inverse
       — a stale `:DOWN` erroring a fresh engagement — is closed by
       demonitor+flush on re-attach and terminal-entry reactivation,
       while an already-running entry keeps its current orchestrator
       armed until the replacement attaches); and the already-running
       swap window itself — between `mark_running/2` and the new task's
       attach, the old orchestrator dying forces the entry `:error`
       while the new dispatch proceeds, whose later `mark_complete` is
       then discarded by the from-`:running`-only guard, so its
       terminal status (and the result status the tracker reports) can
       be lost. Rare, and accepted because it still beats leaving the
       live task unmonitored (a strand); a full fix needs per-run
       generations on terminal writes, or rejecting `send_to_agent`
       while a run is in flight — both deliberately out of scope.

  Config (code defaults, read per call):
  `:agent_tracker_sweep_interval_ms` (60s),
  `:agent_tracker_terminal_ttl_ms` (30min),
  `:agent_tracker_stop_retry_ms` (5min).
  """

  use GenServer

  require Logger

  defmodule AgentEntry do
    @moduledoc false
    @type t :: %__MODULE__{}
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

  @spec start_link(keyword()) :: GenServer.on_start()
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
  @spec register(String.t(), pid(), term(), term(), keyword()) ::
          :ok | {:error, :agent_id_taken}
  def register(id, pid, template, task \\ nil, opts \\ []) do
    scope = scope_from_opts(opts)
    GenServer.call(__MODULE__, {:register, id, pid, template, task, scope})
  end

  @doc "Record a tool call for an agent."
  @spec track_tool(String.t(), String.t()) :: :ok
  def track_tool(agent_id, tool_name) do
    GenServer.cast(__MODULE__, {:track_tool, agent_id, tool_name})
  end

  @doc "Add token usage for an agent."
  @spec track_tokens(String.t(), non_neg_integer()) :: :ok
  def track_tokens(agent_id, count) when is_integer(count) and count >= 0 do
    GenServer.cast(__MODULE__, {:track_tokens, agent_id, count})
  end

  @doc "Mark an agent as completed."
  @spec mark_complete(String.t(), :done | :error) :: :ok
  def mark_complete(id, status \\ :done) when status in [:done, :error] do
    GenServer.cast(__MODULE__, {:mark_complete, id, status})
  end

  @doc """
  Re-activate an agent entry for a follow-up dispatch (`send_to_agent`).

  Flips a terminal entry back to `:running` — making it count toward the
  spawn cap and show as running again — but **only** when the entry
  exists, its tracked pid equals `expected_pid` (the pid the caller is
  about to dispatch to), and that pid is alive (alive ⟹ its monitor ref
  is still armed, so a later death always lands in a `:DOWN` terminal
  transition). Anything else returns `{:error, :not_found}` with no
  mutation: a dead terminal entry stays terminal and sweepable — never
  resurrect what the monitor can't watch.

  Success says which of two very different things happened, because the
  caller's failure handling must differ:

    * `{:ok, :reactivated}` — this call flipped a terminal entry back to
      `:running`. Nothing else will ever complete it, so the caller owns
      forcing it back terminal if its dispatch never starts.
    * `{:ok, :already_running}` — no-op: an in-flight orchestration
      still owns the entry and its orchestrator monitor stays armed
      until the replacement task attaches. The caller must leave the
      entry untouched if its own dispatch fails to start.
  """
  @spec mark_running(String.t(), pid()) ::
          {:ok, :reactivated | :already_running} | {:error, :not_found}
  def mark_running(id, expected_pid) when is_binary(id) and is_pid(expected_pid) do
    GenServer.call(__MODULE__, {:mark_running, id, expected_pid})
  end

  @doc """
  Attach the orchestration process driving an agent's current run.

  Called by the supervised orchestration task (`spawn_agent` /
  `send_to_agent`) as its first statement, so the tracker monitors the
  process responsible for eventually calling `mark_complete/2`. If that
  process dies without writing a terminal status, its `:DOWN` forces the
  entry to `:error` — the backstop for uncatchable kills the task's own
  try/catch can't see. Re-attaching replaces (demonitor + flush) any
  previous orchestrator ref. A synchronous call: the task must not start
  real work until the monitor is armed. No-op for untracked ids;
  attaching an already-dead pid yields an immediate `:DOWN` (`:noproc`),
  which still forces the terminal transition.
  """
  @spec attach_orchestrator(String.t(), pid()) :: :ok
  def attach_orchestrator(id, pid) when is_binary(id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:attach_orchestrator, id, pid})
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
  @spec get_state(keyword()) :: %{
          agents: %{optional(String.t()) => AgentEntry.t()},
          order: [String.t()]
        }
  def get_state(opts \\ []) do
    GenServer.call(__MODULE__, {:get_state, opts})
  end

  @doc """
  Return stats for a single agent.

  When scope opts are supplied, a real agent in another tenant/session returns
  `nil`, making "wrong tenant" indistinguishable from "unknown id" at public
  boundaries.
  """
  @spec get_agent(String.t(), keyword()) :: AgentEntry.t() | nil
  def get_agent(id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_agent, id, opts})
  end

  @doc """
  Return count of currently `:running` non-main agents, optionally filtered
  by tenant/session/workspace scope. Terminal (`:done`/`:error`) entries are
  retained for observability but do not count toward the spawn cap.
  """
  @spec child_count(keyword()) :: non_neg_integer()
  def child_count(opts \\ []) do
    GenServer.call(__MODULE__, {:child_count, opts})
  end

  @doc "Reset tracker state (e.g. between conversations)."
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok, %{agents: %{}, order: [], monitors: %{}, orchestrators: %{}, stopping: %{}},
     {:continue, :setup}}
  end

  @impl GenServer
  def handle_continue(:setup, state) do
    JidoClaw.SignalBus.subscribe("jido_claw.tool.*")
    JidoClaw.SignalBus.subscribe("jido_claw.agent.*")

    Process.send_after(self(), :sweep_terminal, sweep_interval_ms())

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
  @spec handle_telemetry_event([atom()], map(), map(), term()) :: :ok | nil
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
        _metadata,
        _config
      ) do
    # The :start handler above is the single source of truth for tool-call
    # counts — one increment per call. The :stop event stays attached (for
    # symmetry and any future duration tracking) but must NOT re-count, or
    # every tool call would be tallied twice. Timeouts route to :exception,
    # not :stop, so they are already counted once by :start.
    :ok
  end

  def handle_telemetry_event(_, _, _, _), do: :ok

  @impl GenServer
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

    ordered_ids =
      state.order
      |> Enum.reverse()
      |> Enum.filter(&Map.has_key?(agents, &1))

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
      |> Enum.count(fn {id, entry} -> id != "main" and entry.status == :running end)

    {:reply, count, state}
  end

  def handle_call({:update_request_id, id, rid}, _from, state) do
    {:reply, :ok, update_agent(state, id, fn entry -> %{entry | request_id: rid} end)}
  end

  def handle_call({:mark_running, id, expected_pid}, _from, state) do
    case Map.get(state.agents, id) do
      %AgentEntry{pid: ^expected_pid, status: status} = entry ->
        if Process.alive?(expected_pid) do
          activation = if status == :running, do: :already_running, else: :reactivated
          {:reply, {:ok, activation}, reactivate_entry(state, id, entry)}
        else
          {:reply, {:error, :not_found}, state}
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:attach_orchestrator, id, pid}, _from, state) do
    if Map.has_key?(state.agents, id) do
      state = demonitor_orchestrator(state, id)
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | orchestrators: Map.put(state.orchestrators, ref, id)}}
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
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
    {:noreply, complete_entry(state, id, status)}
  end

  def handle_cast(:reset, _state) do
    {:noreply, %{agents: %{}, order: [], monitors: %{}, orchestrators: %{}, stopping: %{}}}
  end

  # Process crash detection. Orchestrator refs first: an orchestration task
  # that died without writing a terminal status forces `:error` (no-op from
  # the from-`:running`-only guard when its `mark_complete` cast — which
  # always precedes the `:DOWN` from the same sender — already landed).
  # Agent-server refs keep their existing crash semantics.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.orchestrators, ref) do
      {agent_id, orchestrators} when is_binary(agent_id) ->
        state = %{state | orchestrators: orchestrators}

        {:noreply,
         complete_entry(state, agent_id, :error, "orchestrator died: #{inspect(reason)}")}

      {nil, _} ->
        case Map.pop(state.monitors, ref) do
          {nil, _} ->
            {:noreply, state}

          {agent_id, monitors} ->
            state = %{state | monitors: monitors, stopping: Map.delete(state.stopping, agent_id)}
            {:noreply, complete_entry(state, agent_id, :error, inspect(reason))}
        end
    end
  end

  def handle_info(:sweep_terminal, state) do
    state = sweep_terminal(state)
    Process.send_after(self(), :sweep_terminal, sweep_interval_ms())
    {:noreply, state}
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

  # At most one orchestrator ref exists per agent id (attach replaces).
  defp find_orchestrator_ref(state, id) do
    Enum.find_value(state.orchestrators, fn {ref, agent_id} ->
      if agent_id == id, do: ref
    end)
  end

  # Drop the orchestrator monitor for `id`, if any. `[:flush]` purges an
  # already-queued `:DOWN`, so a stale (dead, superseded) orchestrator can
  # never error a freshly attached/re-engaged entry.
  defp demonitor_orchestrator(state, id) do
    case find_orchestrator_ref(state, id) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        %{state | orchestrators: Map.delete(state.orchestrators, ref)}
    end
  end

  # Flip an entry back to `:running` for a follow-up dispatch (no-op when
  # already running) and cancel any pending expiry stop for it. Liveness and
  # pid identity are validated by the caller (`{:mark_running, ...}`). Only
  # a *terminal* reactivation drops the previous orchestrator ref — that ref
  # is stale (its run already wrote a terminal status), and dropping it
  # keeps a dying superseded orchestrator from erroring the fresh
  # engagement. An already-running entry keeps its **live** orchestrator
  # monitored until the replacement task attaches (`attach_orchestrator`
  # does the demonitor+flush swap) — dropping it here, before the
  # replacement is known to have started, would leave the in-flight run
  # unmonitored if that start fails.
  defp reactivate_entry(state, id, %AgentEntry{status: :running}) do
    %{state | stopping: Map.delete(state.stopping, id)}
  end

  defp reactivate_entry(state, id, _terminal_entry) do
    state
    |> demonitor_orchestrator(id)
    |> update_agent(id, fn e -> %{e | status: :running, finished_at: nil, error: nil} end)
    |> Map.update!(:stopping, &Map.delete(&1, id))
  end

  # Shared terminal transition for both writers (`mark_complete` cast and
  # `:DOWN`). Transitions only from `:running`, so a late writer can never
  # clobber an already-terminal entry in either direction, and the display
  # gets exactly one completion event per run.
  defp complete_entry(state, id, status, error \\ nil) do
    case Map.get(state.agents, id) do
      %AgentEntry{status: :running} = entry ->
        completed = %{
          entry
          | status: status,
            finished_at: System.monotonic_time(:millisecond),
            error: error
        }

        state = %{
          state
          | agents: Map.put(state.agents, id, completed),
            stopping: Map.delete(state.stopping, id)
        }

        notify_display({:agent_completed, id, status})
        state

      _ ->
        state
    end
  end

  # Expiry is stop-idle-child-then-evict: only dead pids are ever evicted,
  # so a live runtime agent always keeps its tracker entry (scoped tools
  # prove ownership through it). Live expired entries get a deduplicated
  # stop request and are evicted by a later sweep once the pid is down.
  defp sweep_terminal(state) do
    now = System.monotonic_time(:millisecond)
    ttl = terminal_ttl_ms()

    expired =
      Enum.filter(state.agents, fn {id, entry} ->
        id != "main" and entry.status in [:done, :error] and
          is_integer(entry.finished_at) and now - entry.finished_at >= ttl
      end)

    {dead, alive} =
      Enum.split_with(expired, fn {_id, entry} ->
        not (is_pid(entry.pid) and Process.alive?(entry.pid))
      end)

    state
    |> evict_entries(Enum.map(dead, &elem(&1, 0)))
    |> request_stops(alive, now)
  end

  defp evict_entries(state, []), do: state

  defp evict_entries(state, ids) do
    id_set = MapSet.new(ids)

    {evicted_refs, kept_refs} =
      Enum.split_with(state.monitors, fn {_ref, id} -> MapSet.member?(id_set, id) end)

    {evicted_orch_refs, kept_orch_refs} =
      Enum.split_with(state.orchestrators, fn {_ref, id} -> MapSet.member?(id_set, id) end)

    Enum.each(evicted_refs ++ evicted_orch_refs, fn {ref, _id} ->
      Process.demonitor(ref, [:flush])
    end)

    %{
      state
      | agents: Map.drop(state.agents, ids),
        order: Enum.reject(state.order, &MapSet.member?(id_set, &1)),
        monitors: Map.new(kept_refs),
        orchestrators: Map.new(kept_orch_refs),
        stopping: Map.drop(state.stopping, ids)
    }
  end

  defp request_stops(state, [], _now), do: state

  defp request_stops(state, alive_expired, now) do
    retry_ms = stop_retry_ms()

    Enum.reduce(alive_expired, state, fn {id, entry}, acc ->
      case Map.get(acc.stopping, id) do
        requested_at when is_integer(requested_at) and now - requested_at < retry_ms ->
          acc

        requested_at ->
          if is_integer(requested_at) do
            elapsed = now - requested_at

            Logger.warning(
              "[AgentTracker] expired agent #{id} still alive #{elapsed}ms after stop request; re-requesting stop"
            )
          end

          start_stop_task(id, entry.pid)
          %{acc | stopping: Map.put(acc.stopping, id, now)}
      end
    end)
  end

  # Stop by pid, not id: `Jido.stop_agent/2` accepts pids directly, and the
  # monitored pid is authoritative even when a registry id lookup would miss.
  defp start_stop_task(id, pid) do
    runtime = jido_runtime()
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> run_stop(runtime, id, pid) end)
  end

  defp run_stop(runtime, id, pid) do
    case runtime.stop_agent(pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.debug("[AgentTracker] expired agent #{id} was already gone at stop time")

      other ->
        Logger.warning(
          "[AgentTracker] stop request for expired agent #{id} returned #{inspect(other)}"
        )
    end
  catch
    kind, reason ->
      Logger.warning(
        "[AgentTracker] stop request for expired agent #{id} #{kind}: #{inspect(reason)}"
      )
  end

  defp sweep_interval_ms do
    case Application.get_env(:jido_claw, :agent_tracker_sweep_interval_ms, 60_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 60_000
    end
  end

  defp terminal_ttl_ms do
    case Application.get_env(:jido_claw, :agent_tracker_terminal_ttl_ms, 1_800_000) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> 1_800_000
    end
  end

  defp stop_retry_ms do
    case Application.get_env(:jido_claw, :agent_tracker_stop_retry_ms, 300_000) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> 300_000
    end
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
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

  @impl GenServer
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
