defmodule JidoClaw.Conversations.RequestCorrelation.Cache do
  @moduledoc """
  GenServer-owned ETS table mirroring active `RequestCorrelation` rows.

  The Recorder hits this on every `ai.tool.started` / `ai.tool.result`
  / `ai.llm.response` signal to resolve the dispatching scope from the
  signal's `request_id`. ETS lookups stay constant-time even at high
  signal volume.

  ## Pattern

  Mirrors `JidoClaw.Tenant.Manager`: this GenServer is the owner of the
  `:jido_claw_request_correlations` table; writes
  (`put`/`delete`/`delete_for_session`/`clear`) go through `GenServer.call`,
  while `lookup/1` reads the ETS table directly client-side (no GenServer
  round-trip on the hot read path). The owner also maintains a session-to-IDs
  index so ephemeral teardown can evict cache-only fallback entries in O(k)
  for that conversation rather than scanning the global table. A bounded
  ten-minute deleted-session tombstone also rejects a late rehydrate that read
  Postgres before cleanup but reaches this serialized writer after the purge.

  If the GenServer crashes the supervisor restarts it and the table is
  re-created. The Recorder's lookup path falls back to a Postgres read
  on a cache miss, so a brief restart drop is invisible to callers.

  ## Stored shape

      :ets.insert(table, {request_id, %{
        session_id: <uuid>,
        tenant_id: <string>,
        workspace_id: <uuid> | nil,
        user_id: <uuid> | nil,
        # Durable compaction identity + sub-agent flag, mirrored from the
        # RequestCorrelation row so the Recorder can stamp messages.agent_id
        # / messages.subagent without a DB round-trip.
        agent_id: <string> | nil,
        subagent: <boolean>,
        # AR-2 Phase 2b: `true` for a composer subagent's marked turn, mirrored
        # from the row so the Recorder/Audit sink gates resolve it without a DB
        # round-trip.
        sanitize_sensitive_context: <boolean>,
        # Optional telemetry merged in by the Recorder when
        # `ai.llm.response` / `ai.request.completed` lands.
        run_id: <string> | nil,
        model: <string> | nil,
        input_tokens: <integer> | nil,
        output_tokens: <integer> | nil,
        latency_ms: <integer> | nil
      }})
  """

  use GenServer

  @table :jido_claw_request_correlations
  @deleted_session_ttl_ms 600_000
  @max_deleted_sessions 10_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), map()) :: :ok
  def put(request_id, scope) when is_binary(request_id) and is_map(scope) do
    GenServer.call(__MODULE__, {:put, request_id, scope})
  end

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(request_id) when is_binary(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, scope}] -> {:ok, scope}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @spec delete(String.t()) :: :ok
  def delete(request_id) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:delete, request_id})
  end

  @spec delete_for_session(String.t()) :: :ok
  def delete_for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:delete_for_session, session_id})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok,
     %{
       table: table,
       by_session: %{},
       deleted_sessions: %{},
       deleted_session_order: :queue.new(),
       reject_puts_until: nil
     }}
  end

  @impl GenServer
  def handle_call({:put, request_id, scope}, _from, state) do
    state = expire_deleted_sessions(state, monotonic_ms())

    if reject_put?(state, scope) do
      # Cache writes are advisory. Rejecting a stale rehydrate still leaves the
      # durable lookup path authoritative and prevents a deleted stateless
      # conversation from being resurrected in ETS.
      {:reply, :ok, state}
    else
      previous_scope = lookup_scope(state.table, request_id)
      by_session = remove_from_session_index(state.by_session, request_id, previous_scope)
      :ets.insert(state.table, {request_id, scope})
      by_session = add_to_session_index(by_session, request_id, scope)
      {:reply, :ok, %{state | by_session: by_session}}
    end
  end

  @impl GenServer
  def handle_call({:delete, request_id}, _from, state) do
    scope = lookup_scope(state.table, request_id)
    :ets.delete(state.table, request_id)
    by_session = remove_from_session_index(state.by_session, request_id, scope)
    {:reply, :ok, %{state | by_session: by_session}}
  end

  @impl GenServer
  def handle_call({:delete_for_session, session_id}, _from, state) do
    now = monotonic_ms()
    fresh_state = expire_deleted_sessions(state, now)
    request_ids = Map.get(fresh_state.by_session, session_id, MapSet.new())
    Enum.each(request_ids, &:ets.delete(fresh_state.table, &1))

    purged_state = %{
      fresh_state
      | by_session: Map.delete(fresh_state.by_session, session_id)
    }

    {:reply, :ok, remember_deleted_session(purged_state, session_id, now)}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | by_session: %{}}}
  end

  defp lookup_scope(table, request_id) do
    case :ets.lookup(table, request_id) do
      [{^request_id, scope}] -> scope
      [] -> nil
    end
  end

  defp add_to_session_index(by_session, request_id, scope) do
    case session_id(scope) do
      session_id when is_binary(session_id) ->
        Map.update(by_session, session_id, MapSet.new([request_id]), &MapSet.put(&1, request_id))

      _ ->
        by_session
    end
  end

  defp remove_from_session_index(by_session, request_id, scope) do
    case session_id(scope) do
      session_id when is_binary(session_id) ->
        case Map.get(by_session, session_id) do
          nil ->
            by_session

          request_ids ->
            remaining = MapSet.delete(request_ids, request_id)

            if MapSet.size(remaining) == 0 do
              Map.delete(by_session, session_id)
            else
              Map.put(by_session, session_id, remaining)
            end
        end

      _ ->
        by_session
    end
  end

  defp session_id(scope) when is_map(scope), do: Map.get(scope, :session_id)

  defp session_id(_scope), do: nil

  # A resolver may read a durable correlation just before the cleanup
  # transaction deletes it, then enqueue its Cache.put *after* the post-commit
  # purge. The tombstone turns delete_for_session into a serialization fence:
  # puts before it are removed; puts after it are rejected for the durable
  # correlation TTL. The map and queue are hard-bounded. If cardinality reaches
  # the cap, cache writes fail closed globally for one TTL while lookups keep
  # using existing entries/Postgres fallback.
  defp remember_deleted_session(%{reject_puts_until: until} = state, _session_id, now)
       when is_integer(until) and now < until,
       do: %{state | reject_puts_until: max(until, now + @deleted_session_ttl_ms)}

  defp remember_deleted_session(state, session_id, now) do
    cond do
      Map.has_key?(state.deleted_sessions, session_id) ->
        state

      map_size(state.deleted_sessions) < @max_deleted_sessions ->
        expires_at = now + @deleted_session_ttl_ms

        %{
          state
          | deleted_sessions: Map.put(state.deleted_sessions, session_id, expires_at),
            deleted_session_order:
              :queue.in({expires_at, session_id}, state.deleted_session_order)
        }

      true ->
        %{
          state
          | deleted_sessions: %{},
            deleted_session_order: :queue.new(),
            reject_puts_until: now + @deleted_session_ttl_ms
        }
    end
  end

  defp expire_deleted_sessions(%{reject_puts_until: until} = state, now)
       when is_integer(until) and now >= until do
    %{state | reject_puts_until: nil, deleted_sessions: %{}, deleted_session_order: :queue.new()}
  end

  defp expire_deleted_sessions(%{reject_puts_until: until} = state, now)
       when is_integer(until) and now < until,
       do: state

  defp expire_deleted_sessions(state, now) do
    case :queue.out(state.deleted_session_order) do
      {{:value, {expires_at, session_id}}, rest} when expires_at <= now ->
        state = %{
          state
          | deleted_sessions: Map.delete(state.deleted_sessions, session_id),
            deleted_session_order: rest
        }

        expire_deleted_sessions(state, now)

      _not_expired_or_empty ->
        state
    end
  end

  defp reject_put?(%{reject_puts_until: until}, _scope) when is_integer(until), do: true

  defp reject_put?(state, scope) do
    case session_id(scope) do
      session_id when is_binary(session_id) -> Map.has_key?(state.deleted_sessions, session_id)
      _ -> false
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
