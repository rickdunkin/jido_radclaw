defmodule JidoClaw.Session.Worker do
  @moduledoc """
  GenServer per session. Manages message history (Postgres-backed),
  agent binding, and per-session telemetry for a single conversation.

  ## Persistence

  Phase 2 retired the legacy `.jido/sessions/<tenant>/*.jsonl` writer.
  Messages now flow through `JidoClaw.Conversations.Message` rows in
  Postgres, written via `Conversations.Message.append/2`. The
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

  ## Actor

  `state.actor` carries the latest Ash authorization actor supplied
  through `set_actor/3` (typically by `Session.Supervisor.ensure_session/3`).
  Worker is keyed by `(tenant_id, session_id)` so `tenant_id` cannot drift
  between turns; the policy enforced as of v0.6.4 only checks `tenant_id`.
  If a future policy enforces user_id matching, the safer pattern is
  per-call actor passing rather than the state-stored shape used here.
  """
  # GenServer per-session worker: hydration, cache lookups, and handoff
  # rehydration are best-effort recoveries that must never crash the
  # worker — a raise becomes a warning log and a degraded read.
  # reach:disable-for-this-file bare_rescue
  use GenServer
  require Logger

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Conversations.Session, as: ConversationsSession

  @idle_timeout 300_000

  defstruct [
    :id,
    :tenant_id,
    :session_uuid,
    :actor,
    :agent_pid,
    :agent_ref,
    :created_at,
    :last_active,
    messages: [],
    status: :active
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Append a message row.

  `opts` may carry `:agent_id` / `:subagent` overrides that win over the
  identity looked up from the `RequestCorrelation` row — used for the
  handoff `:system` row, which is written during main's turn but must be
  stamped with the *target worker's* compaction identity.
  """
  @spec add_message(String.t(), String.t(), atom(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def add_message(tenant_id, session_id, role, content, request_id \\ nil, opts \\ []) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:add_message, role, content, request_id, opts})
  end

  @spec get_messages(String.t(), String.t()) :: [map()]
  def get_messages(tenant_id, session_id) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, :get_messages)
  end

  @spec get_info(String.t(), String.t()) :: map()
  def get_info(tenant_id, session_id) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, :get_info)
  end

  @doc "Bind an agent process to this session. Monitors the agent for crash detection."
  @spec set_agent(String.t(), String.t(), pid()) :: :ok
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
  @spec set_session_uuid(String.t(), String.t(), String.t()) ::
          :ok | {:error, :session_uuid_already_set}
  def set_session_uuid(tenant_id, session_id, session_uuid) when is_binary(session_uuid) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:set_session_uuid, session_uuid})
  end

  @doc """
  Update the worker's authorization actor.

  Called from `Session.Supervisor.ensure_session/3` when an
  already-running worker is reused — the most recent caller's actor
  wins. Internal trust path; never accept actor from end-user input.
  """
  @spec set_actor(String.t(), String.t(), term()) :: :ok
  def set_actor(tenant_id, session_id, actor) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    GenServer.call(name, {:set_actor, actor})
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    session_uuid = Keyword.get(opts, :session_uuid)
    actor = Keyword.get(opts, :actor)

    state = %__MODULE__{
      id: session_id,
      tenant_id: tenant_id,
      session_uuid: session_uuid,
      actor: actor,
      created_at: DateTime.utc_now(),
      last_active: DateTime.utc_now(),
      messages: []
    }

    JidoClaw.Telemetry.emit_session_start(%{tenant_id: tenant_id, session_id: session_id})
    {:ok, state, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, %{session_uuid: nil} = state) do
    # Worker started without a session_uuid — wait for set_session_uuid to
    # arrive before loading. This is the normal boot path.
    {:noreply, state, @idle_timeout}
  end

  def handle_continue(:load, state) do
    messages = load_messages(state.session_uuid, state.tenant_id, state.actor)
    {:noreply, %{state | messages: messages}, @idle_timeout}
  end

  @impl GenServer
  def handle_call(
        {:add_message, _role, _content, _request_id, _opts},
        _from,
        %{session_uuid: nil} = state
      ) do
    {:reply, {:error, :session_uuid_unset}, state, @idle_timeout}
  end

  def handle_call({:add_message, role, content, request_id, opts}, _from, state) do
    request_attrs = lookup_request_attrs(request_id)

    attrs =
      %{
        session_id: state.session_uuid,
        role: role,
        content: content,
        request_id: request_id,
        metadata: %{}
      }
      |> Map.merge(request_attrs)
      |> apply_identity_overrides(opts)

    case Message.append(attrs, append_opts(state)) do
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

  @impl GenServer
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

  @impl GenServer
  def handle_call({:set_agent, agent_pid}, _from, state) do
    # Demonitor previous agent if one was bound
    if state.agent_ref, do: Process.demonitor(state.agent_ref, [:flush])

    ref = Process.monitor(agent_pid)
    new_state = %{state | agent_pid: agent_pid, agent_ref: ref}
    {:reply, :ok, new_state, @idle_timeout}
  end

  @impl GenServer
  def handle_call({:set_session_uuid, uuid}, _from, %{session_uuid: nil} = state) do
    messages = load_messages(uuid, state.tenant_id, state.actor)
    _ = seed_handoff_from_metadata(state.tenant_id, state.id, uuid, state.actor)
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

  def handle_call({:set_actor, actor}, _from, state) do
    {:reply, :ok, %{state | actor: actor}, @idle_timeout}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{agent_ref: ref, agent_pid: pid} = state) do
    Logger.warning("[Session] #{state.id} agent #{inspect(pid)} died: #{inspect(reason)}")
    new_state = %{state | agent_pid: nil, agent_ref: nil, status: :agent_lost}
    {:noreply, new_state, @idle_timeout}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.debug("[Session] #{state.id} idle timeout, hibernating")
    {:noreply, %{state | status: :hibernated}, :hibernate}
  end

  @impl GenServer
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

  defp load_messages(session_uuid, tenant_id, actor) when is_binary(tenant_id) do
    actor = actor || Actor.system(tenant_id)

    # Primary view only — sub-agent rows are excluded from the chat-visible
    # in-memory cache (they belong to their own per-agent compaction slices).
    case Message.for_session_primary(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, rows} -> Enum.flat_map(rows, &to_view/1)
      _ -> []
    end
  rescue
    e ->
      Logger.warning("[Session] message hydration raised: #{Exception.message(e)}")
      []
  end

  defp load_messages(_session_uuid, _, _), do: []

  defp append_opts(%__MODULE__{tenant_id: tenant_id, actor: actor}) do
    base = [tenant: tenant_id]
    if actor, do: Keyword.put(base, :actor, actor), else: base
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

  # Pull the durable compaction identity (`agent_id`, `subagent`) plus the
  # per-request telemetry merged into the RequestCorrelation row by the
  # Recorder. Cache hits cover the in-flight path; the durable lookup
  # fallback covers the post-finalize path where the cache has been
  # cleared on `ai.request.completed`. Identity is stamped at register
  # time, so it is present on the cache hit even before telemetry merges.
  defp lookup_request_attrs(nil), do: %{}

  defp lookup_request_attrs(request_id) when is_binary(request_id) do
    case safe_cache_lookup(request_id) do
      {:ok, scope} when is_map(scope) ->
        attrs = request_attrs_subset(scope)
        # Telemetry merges into the row AFTER the scope is first cached, so a
        # cache hit may carry identity but not yet telemetry — fill telemetry
        # from the durable row in that case (identity from the cache wins).
        if has_telemetry?(scope), do: attrs, else: Map.merge(durable_attrs(request_id), attrs)

      _ ->
        durable_attrs(request_id)
    end
  end

  defp lookup_request_attrs(_), do: %{}

  defp safe_cache_lookup(request_id) do
    Cache.lookup(request_id)
  rescue
    _ in [ArgumentError] -> :error
  end

  defp durable_attrs(request_id) do
    # The legacy add-message envelope exposes request identity, not an actor.
    # credo:disable-for-next-line AshCredo.Check.Warning.AuthorizeFalse
    case RequestCorrelation.lookup(request_id, authorize?: false) do
      {:ok, row} -> request_attrs_subset(row)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp has_telemetry?(map) do
    Enum.any?([:run_id, :model, :input_tokens, :output_tokens, :latency_ms], fn k ->
      not is_nil(Map.get(map, k))
    end)
  end

  defp request_attrs_subset(source) do
    Enum.reduce(
      [:agent_id, :subagent, :run_id, :model, :input_tokens, :output_tokens, :latency_ms],
      %{},
      fn k, acc ->
        case Map.get(source, k) do
          nil -> acc
          v -> Map.put(acc, k, v)
        end
      end
    )
  end

  # Caller-supplied `:agent_id` / `:subagent` win over the looked-up
  # identity (handoff `:system` row uses this to stamp the target worker).
  defp apply_identity_overrides(attrs, opts) do
    attrs
    |> override(:agent_id, Keyword.get(opts, :agent_id))
    |> override(:subagent, Keyword.get(opts, :subagent))
  end

  defp override(attrs, _key, nil), do: attrs
  defp override(attrs, key, value), do: Map.put(attrs, key, value)

  # Re-hydrate the handoff registry from the durable session metadata
  # when the worker first learns its session_uuid. The original handoff
  # message is lost across restarts; we install a placeholder owner with
  # preamble_consumed?: true so the first post-restart turn just lands
  # on the worker raw. Stale templates clear metadata + log.
  defp seed_handoff_from_metadata(tenant_id, runtime_session_id, session_uuid, actor)
       when is_binary(tenant_id) and is_binary(runtime_session_id) and is_binary(session_uuid) do
    actor = actor || Actor.system(tenant_id)

    case ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, %{metadata: %{"current_agent_template" => template_name}} = session}
      when is_binary(template_name) ->
        case Templates.get(template_name) do
          # AR-8c: a composer-private template (the `system_*` flag) must NOT be
          # transiently re-installed as a handoff owner from durable metadata —
          # the metadata mirror is not a path that can bypass the safety gate. So
          # treat it as stale, exactly like an unresolvable template.
          {:ok, template} ->
            if Templates.composer_private?(template_name) do
              clear_stale_template(session, runtime_session_id, template_name, tenant_id, actor)
            else
              install_rehydrated_owner(
                tenant_id,
                runtime_session_id,
                session_uuid,
                template_name,
                template
              )
            end

          {:error, _} ->
            clear_stale_template(session, runtime_session_id, template_name, tenant_id, actor)
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[Session] handoff hydration raised: #{Exception.message(e)}")
      :ok
  end

  defp seed_handoff_from_metadata(_, _, _, _), do: :ok

  defp install_rehydrated_owner(
         tenant_id,
         runtime_session_id,
         session_uuid,
         template_name,
         template
       ) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: Handoff.rehydrated_marker(),
        to_template: template_name,
        to_module: template.module,
        message: Handoff.rehydrated_marker()
      })

    :ok =
      HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff, preamble_consumed?: true)

    :ok
  end

  defp clear_stale_template(session, runtime_session_id, template_name, tenant_id, actor) do
    Logger.warning(
      "[Session] #{runtime_session_id} stale current_agent_template '#{template_name}' — clearing metadata"
    )

    _ =
      ConversationsSession.set_current_agent_template(session, nil,
        tenant: tenant_id,
        actor: actor
      )

    :ok
  end
end
