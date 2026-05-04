defmodule JidoClaw.Session.Worker do
  @moduledoc """
  GenServer per session. Manages message history (Postgres-backed),
  agent binding, and per-session telemetry for a single conversation.

  ## Persistence

  Phase 2 retired the legacy `.jido/sessions/<tenant>/*.jsonl` writer.
  Messages now flow through `JidoClaw.Conversations.Message` rows in
  Postgres, written via `Conversations.Message.append!/1`. The
  worker's in-memory `state.messages` mirrors the persisted history
  for fast `get_messages/2` access; on cold start, it hydrates from
  Postgres via `Message.for_session/1`.

  ## session_uuid lifecycle

  The worker can't write `Conversations.Message` rows until the parent
  `Conversations.Session` row has been created (UUID FK target). At
  start, `session_uuid` is `nil`; the dispatcher sets it via
  `set_session_uuid/3` after `Conversations.Resolver.ensure_session/5`.
  The setter ALSO hydrates `state.messages` from Postgres synchronously,
  so subsequent `:get_messages` / `:get_info` calls reflect any prior
  history immediately.

  Until `set_session_uuid` runs, `add_message/4` returns
  `{:error, :session_uuid_unset}`.

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

  alias JidoClaw.Conversations.Message

  @idle_timeout 300_000

  defstruct [
    :id,
    :tenant_id,
    :session_uuid,
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

  def add_message(tenant_id, session_id, role, content, request_id \\ nil) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:add_message, role, content, request_id})
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

  @doc """
  Set the `Conversations.Session` UUID for this worker.

  Idempotent: passing the same UUID twice is a no-op. Calling with a
  different UUID raises (re-pointing a worker mid-flight is a bug).

  Hydrates `state.messages` from Postgres on first call, so
  `get_messages/2` reflects pre-existing history immediately.
  """
  def set_session_uuid(tenant_id, session_id, session_uuid) when is_binary(session_uuid) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:set_session_uuid, session_uuid})
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    session_uuid = Keyword.get(opts, :session_uuid)

    state = %__MODULE__{
      id: session_id,
      tenant_id: tenant_id,
      session_uuid: session_uuid,
      created_at: DateTime.utc_now(),
      last_active: DateTime.utc_now(),
      messages: []
    }

    JidoClaw.Telemetry.emit_session_start(%{tenant_id: tenant_id, session_id: session_id})
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{session_uuid: nil} = state) do
    # Worker started without a session_uuid — wait for set_session_uuid to
    # arrive before loading. This is the normal boot path.
    {:noreply, state, @idle_timeout}
  end

  def handle_continue(:load, state) do
    messages = load_messages(state.session_uuid)
    {:noreply, %{state | messages: messages}, @idle_timeout}
  end

  @impl true
  def handle_call(
        {:add_message, _role, _content, _request_id},
        _from,
        %{session_uuid: nil} = state
      ) do
    {:reply, {:error, :session_uuid_unset}, state, @idle_timeout}
  end

  def handle_call({:add_message, role, content, request_id}, _from, state) do
    case Message.append(%{
           session_id: state.session_uuid,
           role: role,
           content: content,
           request_id: request_id,
           metadata: %{}
         }) do
      {:ok, message} ->
        new_state = %{
          state
          | messages: state.messages ++ to_view(message),
            last_active: DateTime.utc_now()
        }

        JidoClaw.Telemetry.emit_session_message(%{
          tenant_id: state.tenant_id,
          session_id: state.id,
          role: role
        })

        {:reply, :ok, new_state, @idle_timeout}

      {:error, reason} ->
        Logger.warning("[Session] #{state.id} add_message failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state, @idle_timeout}
  end

  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.id,
      tenant_id: state.tenant_id,
      session_uuid: state.session_uuid,
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
  def handle_call({:set_session_uuid, uuid}, _from, %{session_uuid: nil} = state) do
    messages = load_messages(uuid)
    {:reply, :ok, %{state | session_uuid: uuid, messages: messages}, @idle_timeout}
  end

  def handle_call({:set_session_uuid, uuid}, _from, %{session_uuid: uuid} = state) do
    {:reply, :ok, state, @idle_timeout}
  end

  def handle_call({:set_session_uuid, other}, _from, state) do
    Logger.error(
      "[Session] #{state.id} attempted to re-point session_uuid from #{state.session_uuid} to #{other}"
    )

    {:reply, {:error, :session_uuid_already_set}, state, @idle_timeout}
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_messages(session_uuid) do
    case Message.for_session(session_uuid) do
      {:ok, rows} -> Enum.flat_map(rows, &to_view/1)
      _ -> []
    end
  rescue
    e ->
      Logger.warning("[Session] message hydration raised: #{Exception.message(e)}")
      []
  end

  # Map a Conversations.Message row → the legacy in-memory shape so
  # JidoClaw.history/2 callers (and the REPL view) keep their existing
  # `[%{role: String.t(), content: String.t(), timestamp: integer()}]`
  # contract. Returns `[view]` for chat roles and `[]` for tool/reasoning
  # rows so the in-memory cache stays chat-only.
  defp to_view(%{role: role, content: content, inserted_at: inserted_at})
       when role in [:user, :assistant, :system] do
    [
      %{
        role: Atom.to_string(role),
        content: content,
        timestamp: DateTime.to_unix(inserted_at, :millisecond)
      }
    ]
  end

  defp to_view(_), do: []
end
