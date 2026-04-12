defmodule JidoClaw.Session.Worker do
  @moduledoc """
  GenServer per session. Manages message history, JSONL persistence,
  and agent interaction for a single conversation.

  ## Agent Binding

  Each session can be bound to an agent process via `set_agent/3`. The worker
  monitors the agent with `Process.monitor/1` and transitions to `:agent_lost`
  status if the agent crashes. This enables crash-aware session management —
  callers can inspect `get_info/2` to detect orphaned sessions and restart
  agents as needed.

  ## Lifecycle

      :active → :agent_lost (agent crashes)
      :active → :hibernated (idle timeout, 5 min)
  """
  use GenServer
  require Logger

  @idle_timeout 300_000

  defstruct [
    :id,
    :tenant_id,
    :agent_pid,
    :agent_ref,
    :created_at,
    :last_active,
    messages: [],
    status: :active
  ]

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def add_message(tenant_id, session_id, role, content) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.cast(name, {:add_message, role, content})
  end

  def get_messages(tenant_id, session_id) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, :get_messages)
  end

  def get_info(tenant_id, session_id) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, :get_info)
  end

  @doc "Bind an agent process to this session. Monitors the agent for crash detection."
  def set_agent(tenant_id, session_id, agent_pid) when is_pid(agent_pid) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:set_agent, agent_pid})
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)

    messages = load_from_jsonl(tenant_id, session_id)

    state = %__MODULE__{
      id: session_id,
      tenant_id: tenant_id,
      created_at: DateTime.utc_now(),
      last_active: DateTime.utc_now(),
      messages: messages
    }

    JidoClaw.Telemetry.emit_session_start(%{tenant_id: tenant_id, session_id: session_id})
    {:ok, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:add_message, role, content}, state) do
    message = %{
      role: to_string(role),
      content: content,
      timestamp: System.system_time(:millisecond)
    }

    new_state = %{state | messages: state.messages ++ [message], last_active: DateTime.utc_now()}

    append_to_jsonl(state.tenant_id, state.id, message)

    JidoClaw.Telemetry.emit_session_message(%{
      tenant_id: state.tenant_id,
      session_id: state.id,
      role: role
    })

    {:noreply, new_state, @idle_timeout}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state, @idle_timeout}
  end

  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.id,
      tenant_id: state.tenant_id,
      agent_pid: state.agent_pid,
      message_count: length(state.messages),
      created_at: state.created_at,
      last_active: state.last_active,
      status: state.status
    }

    {:reply, info, state, @idle_timeout}
  end

  @impl true
  def handle_call({:set_agent, agent_pid}, _from, state) do
    # Demonitor previous agent if one was bound
    if state.agent_ref, do: Process.demonitor(state.agent_ref, [:flush])

    ref = Process.monitor(agent_pid)
    new_state = %{state | agent_pid: agent_pid, agent_ref: ref}
    {:reply, :ok, new_state, @idle_timeout}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{agent_ref: ref, agent_pid: pid} = state) do
    Logger.warning("[Session] #{state.id} agent #{inspect(pid)} died: #{inspect(reason)}")
    new_state = %{state | agent_pid: nil, agent_ref: nil, status: :agent_lost}
    {:noreply, new_state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("[Session] #{state.id} idle timeout, hibernating")
    {:noreply, %{state | status: :hibernated}, :hibernate}
  end

  @impl true
  def terminate(_reason, state) do
    duration = DateTime.diff(DateTime.utc_now(), state.created_at, :millisecond)

    JidoClaw.Telemetry.emit_session_stop(
      %{tenant_id: state.tenant_id, session_id: state.id},
      duration
    )

    :ok
  end

  # -- JSONL Persistence --

  defp jsonl_dir(tenant_id) do
    Path.join([File.cwd!(), ".jido", "sessions", tenant_id])
  end

  defp jsonl_path(tenant_id, session_id) do
    Path.join(jsonl_dir(tenant_id), "#{session_id}.jsonl")
  end

  defp load_from_jsonl(tenant_id, session_id) do
    path = jsonl_path(tenant_id, session_id)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line, keys: :atoms) do
            {:ok, msg} -> [msg]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp append_to_jsonl(tenant_id, session_id, message) do
    dir = jsonl_dir(tenant_id)
    File.mkdir_p!(dir)
    path = jsonl_path(tenant_id, session_id)
    line = Jason.encode!(message) <> "\n"
    File.write!(path, line, [:append])
  end
end
