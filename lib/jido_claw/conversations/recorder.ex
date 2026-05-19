defmodule JidoClaw.Conversations.Recorder do
  @moduledoc """
  GenServer that subscribes to `ai.*` topics on `JidoClaw.SignalBus` and
  writes the corresponding `Conversations.Message` rows.

  ## Signals consumed

    * `ai.tool.started` — write a `:tool_call` row
    * `ai.tool.result` — write a `:tool_result` row, linked to the
      corresponding `:tool_call` via `parent_message_id`
    * `ai.llm.response` — extract `thinking_content` from the result
      tuple and write a `:reasoning` row when non-empty; also learn
      the `call_id → request_id` mapping so a previously-buffered
      `ai.usage` telemetry payload can be merged in
    * `ai.usage` — per-call token / model usage. The directive path
      emits `ai.usage` BEFORE `ai.llm.response` and without
      `request_id` in metadata; we buffer such payloads by `call_id`
      and drain them when the matching `ai.llm.response` arrives. The
      React path emits `ai.usage` with `request_id` already in
      metadata and is dispatched immediately.
    * `ai.request.completed` / `ai.request.failed` — terminal signals;
      delete the matching `RequestCorrelation` row + Cache entry; reply
      to any pending `flush(request_id)` calls

  Most signals carry a `request_id` (in `signal.data.metadata.request_id`
  for tool signals, `signal.data.request_id` for terminal signals);
  the Recorder uses it to look up the dispatching scope from the
  `RequestCorrelation.Cache` (with Postgres fallback). `ai.usage` is
  the exception — see the buffering note above.

  ## Telemetry handler

  In addition to bus signals, the Recorder attaches a
  `:telemetry.attach_many/4` handler at boot for
  `[:jido, :ai, :llm, :complete]` and `[:jido, :ai, :llm, :error]`.
  These events carry `metadata.request_id` and
  `measurements.duration_ms` and are the canonical source of
  per-LLM-call latency. The handler maps `duration_ms → :latency_ms`
  and merges into the durable `RequestCorrelation` row via
  `RequestCorrelation.record_telemetry/2`.

  ## Flush barrier (`flush/2`)

  The dispatcher (`JidoClaw.chat/4`, REPL, channel adapters) calls
  `Recorder.flush(request_id)` after `Agent.ask_sync` returns and
  before writing the assistant message. The call blocks until the
  Recorder has finished processing the request's terminal signal,
  which guarantees:

    * every `:tool_call` / `:tool_result` / `:reasoning` row for that
      `request_id` has been committed to Postgres
    * those rows have `sequence < assistant_row.sequence`

  Per BEAM semantics, the Recorder's mailbox is processed FIFO from a
  single sender (the bus PID). With `partition_count: 1` on the bus,
  every signal for one agent invocation is delivered in emission order
  from the same sender, so processing the terminal signal implies all
  prior request signals have already been processed.

  Implementation: a `waiters` map (`request_id => [from]`) and a
  bounded `recent_completed` LRU; the call replies immediately if the
  request already terminated, otherwise blocks until the terminal
  signal is processed.

  ## Relationship to `JidoClaw.Trace`

  Recorder writes the **durable record-of-truth** for messages — every
  `:tool_call`, `:tool_result`, `:reasoning`, and assistant row is a
  permanent `Conversations.Message` row.

  `JidoClaw.Trace` consumes the same `ai.*` telemetry stream into a
  bounded in-memory projection (plus optional Postgres persistence in
  `trace_runs` / `trace_events`) for the in-flight view that
  LiveViews, the REPL, MCP, and the certificate verifier all share.
  The two writers do not overlap — `Trace` is correlation/replay; the
  Recorder is durable conversation state.

  ## Bus restart resilience

  `init/1` returns `{:ok, state, {:continue, :setup}}`. `setup` resolves
  the bus PID via `Bus.whereis/2`; if the bus isn't up yet
  (`{:error, :not_found}`), it schedules a 250ms `:retry_setup` send.
  When the resolved bus crashes, the `:DOWN` handler schedules the
  same retry. Either path eventually re-subscribes. The agent loop
  keeps emitting signals during downtime — they're dropped, which is
  fine because the dispatcher never emits a terminal signal until
  after the Recorder has reattached (worst case the flush call times
  out and the dispatcher proceeds with a logged warning).
  """

  use GenServer
  use JidoClaw.NoClone
  require Logger

  alias Jido.Signal.Bus
  alias JidoClaw.Conversations.{Message, RequestCorrelation, ToolTranscript}
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Core.MapKeys

  @topics [
    "ai.tool.started",
    "ai.tool.result",
    "ai.llm.response",
    "ai.usage",
    "ai.request.completed",
    "ai.request.failed"
  ]

  @recent_completed_max 512
  @call_buffer_max 256
  @retry_after_ms 250
  @telemetry_handler_id {__MODULE__, :latency}
  @telemetry_events [
    [:jido, :ai, :llm, :complete],
    [:jido, :ai, :llm, :error]
  ]

  defstruct bus_pid: nil,
            subscriptions: [],
            waiters: %{},
            recent_completed: :queue.new(),
            recent_completed_set: MapSet.new(),
            # call_id => telemetry_map; populated when `ai.usage` arrives
            # without a `request_id` and drained when the matching
            # `ai.llm.response` resolves it.
            pending_usage: %{},
            pending_usage_q: :queue.new(),
            # call_id => request_id; learned from `ai.llm.response`.
            call_to_request: %{},
            call_to_request_q: :queue.new()

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Block until the Recorder has finished processing the terminal signal
  for `request_id`, or until `timeout` ms elapse.

  Returns `:ok` on success, `{:error, :timeout}` if the timeout fires
  before the terminal signal arrives. Importantly, this does NOT
  exit the caller process on timeout — a raw `GenServer.call` would,
  which would crash the dispatcher and surface as `EXIT` to whatever
  supervises it. Wrapping in try/catch lets the dispatcher decide what
  to do — and the right call here is to log + continue with the
  assistant write, because dropping the agent's response is worse than
  a rare ordering miss.
  """
  @spec flush(String.t(), timeout()) :: :ok | {:error, :timeout}
  def flush(request_id, timeout \\ 30_000) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:flush, request_id}, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[Recorder.flush] timeout for request_id=#{request_id}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      Logger.warning("[Recorder.flush] Recorder not running, request_id=#{request_id}")
      {:error, :timeout}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_setup(state)}
  end

  @impl true
  def handle_info(:retry_setup, state) do
    {:noreply, do_setup(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Process.send_after(self(), :retry_setup, @retry_after_ms)
    {:noreply, %{state | bus_pid: nil, subscriptions: []}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = signal}, state) do
    {:noreply, handle_signal(signal, state)}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:flush, request_id}, from, state) do
    if MapSet.member?(state.recent_completed_set, request_id) do
      {:reply, :ok, state}
    else
      waiters = Map.update(state.waiters, request_id, [from], &[from | &1])
      {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    # Best-effort detach. The defensive detach in `do_setup/1` is the
    # actual contract — a dirty exit (no terminate/2) cannot leave a
    # stale handler bound to a dead function reference because
    # `do_setup/1` always detaches by id before re-attaching.
    :telemetry.detach(@telemetry_handler_id)
    :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Setup / subscription
  # ---------------------------------------------------------------------------

  defp do_setup(state) do
    attach_latency_handler()

    case Bus.whereis(JidoClaw.SignalBus) do
      {:ok, bus_pid} ->
        subs = Enum.map(@topics, &subscribe_topic/1)
        Process.monitor(bus_pid)
        %{state | bus_pid: bus_pid, subscriptions: subs}

      {:error, _} ->
        Process.send_after(self(), :retry_setup, @retry_after_ms)
        state
    end
  end

  defp subscribe_topic(topic) do
    case JidoClaw.SignalBus.subscribe(topic) do
      {:ok, sub_id} -> {topic, sub_id}
      _ -> {topic, nil}
    end
  end

  # Attach a single telemetry handler that captures per-LLM-call
  # latency from the standard `[:jido, :ai, :llm, :complete]` and
  # `:error` events. Detach the handler-id first so a prior dirty
  # boot can't leave stale state bound to a dead function reference.
  defp attach_latency_handler do
    :telemetry.detach(@telemetry_handler_id)

    :telemetry.attach_many(
      @telemetry_handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      nil
    )
  end

  @doc false
  def handle_telemetry(_event, measurements, metadata, _config) do
    request_id = MapKeys.coalesce_field(metadata, :request_id)
    duration = MapKeys.coalesce_field(measurements, :duration_ms)

    if is_binary(request_id) and is_integer(duration) and duration > 0 do
      try do
        case RequestCorrelation.record_telemetry(request_id, %{latency_ms: duration}) do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end

        case Cache.lookup(request_id) do
          {:ok, scope} when is_map(scope) ->
            Cache.put(request_id, Map.put(scope, :latency_ms, duration))

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Signal dispatch
  # ---------------------------------------------------------------------------

  defp handle_signal(%{type: "ai.tool.started"} = signal, state) do
    safe_handle(fn -> record_tool_call(signal) end, "ai.tool.started")
    state
  end

  defp handle_signal(%{type: "ai.tool.result"} = signal, state) do
    safe_handle(fn -> record_tool_result(signal) end, "ai.tool.result")
    state
  end

  defp handle_signal(%{type: "ai.llm.response"} = signal, state) do
    safe_handle(fn -> record_reasoning(signal) end, "ai.llm.response")
    safe_handle(fn -> record_telemetry(signal) end, "ai.llm.response.telemetry")
    learn_call_request(signal, state)
  end

  defp handle_signal(%{type: "ai.usage"} = signal, state) do
    handle_usage(signal, state)
  end

  defp handle_signal(%{type: "ai.request.completed"} = signal, state) do
    safe_handle(fn -> record_telemetry(signal) end, "ai.request.completed.telemetry")
    request_id = MapKeys.coalesce_field(signal.data, :request_id)
    finalize_request(request_id, state)
  end

  defp handle_signal(%{type: "ai.request.failed"} = signal, state) do
    safe_handle(fn -> record_telemetry(signal) end, "ai.request.failed.telemetry")
    request_id = MapKeys.coalesce_field(signal.data, :request_id)
    finalize_request(request_id, state)
  end

  defp handle_signal(_, state), do: state

  # ---------------------------------------------------------------------------
  # ai.usage / call_id correlation
  # ---------------------------------------------------------------------------

  defp handle_usage(%{data: data}, state) do
    telemetry = extract_telemetry(data)
    request_id = metadata_request_id(data) || MapKeys.field(data, :request_id)
    call_id = MapKeys.field(data, :call_id)

    cond do
      telemetry == %{} ->
        state

      is_binary(request_id) ->
        # React path: request_id already in metadata. Dispatch
        # immediately.
        merge_telemetry(request_id, telemetry)
        state

      is_binary(call_id) and is_binary(Map.get(state.call_to_request, call_id)) ->
        # `ai.llm.response` already resolved this call_id to a
        # request_id (out-of-order or strategy-specific orderings).
        rid = Map.fetch!(state.call_to_request, call_id)
        merge_telemetry(rid, telemetry)
        state

      is_binary(call_id) ->
        # Directive path: `ai.usage` is cast before `ai.llm.response`,
        # so we don't yet know the request_id. Buffer by call_id and
        # drain when the matching `ai.llm.response` arrives.
        buffer_usage(state, call_id, telemetry)

      true ->
        state
    end
  end

  defp learn_call_request(%{data: data}, state) do
    request_id = metadata_request_id(data) || MapKeys.field(data, :request_id)
    call_id = MapKeys.field(data, :call_id)

    if is_binary(request_id) and is_binary(call_id) do
      state
      |> remember_call_request(call_id, request_id)
      |> drain_pending_usage(call_id, request_id)
    else
      state
    end
  end

  defp buffer_usage(state, call_id, telemetry) do
    # If the call_id already has a buffered payload, merge the new
    # telemetry on top so token deltas accumulate correctly. This is
    # rare in practice (usage signals are emitted once per call) but
    # cheap to handle right.
    case Map.get(state.pending_usage, call_id) do
      nil ->
        pending_usage = Map.put(state.pending_usage, call_id, telemetry)
        pending_q = :queue.in(call_id, state.pending_usage_q)
        evict_buffer(%{state | pending_usage: pending_usage, pending_usage_q: pending_q}, :usage)

      existing ->
        merged = Map.merge(existing, telemetry)
        %{state | pending_usage: Map.put(state.pending_usage, call_id, merged)}
    end
  end

  defp remember_call_request(state, call_id, request_id) do
    case Map.get(state.call_to_request, call_id) do
      ^request_id ->
        state

      _ ->
        ctr = Map.put(state.call_to_request, call_id, request_id)
        ctr_q = :queue.in(call_id, state.call_to_request_q)
        evict_buffer(%{state | call_to_request: ctr, call_to_request_q: ctr_q}, :ctr)
    end
  end

  defp drain_pending_usage(state, call_id, request_id) do
    case Map.pop(state.pending_usage, call_id) do
      {nil, _} ->
        state

      {telemetry, rest} ->
        merge_telemetry(request_id, telemetry)
        # The queue still references the call_id — let the LRU
        # eviction path drop it on its next pass; rebuilding the
        # queue here would be O(n).
        %{state | pending_usage: rest}
    end
  end

  defp merge_telemetry(_request_id, telemetry) when telemetry == %{}, do: :ok

  defp merge_telemetry(request_id, telemetry) when is_binary(request_id) do
    case RequestCorrelation.record_telemetry(request_id, telemetry) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    case Cache.lookup(request_id) do
      {:ok, scope} when is_map(scope) ->
        Cache.put(request_id, Map.merge(scope, telemetry))

      _ ->
        :ok
    end
  end

  defp evict_buffer(state, :usage) do
    if map_size(state.pending_usage) > @call_buffer_max do
      case :queue.out(state.pending_usage_q) do
        {{:value, evicted}, q1} ->
          %{
            state
            | pending_usage: Map.delete(state.pending_usage, evicted),
              pending_usage_q: q1
          }

        _ ->
          state
      end
    else
      state
    end
  end

  defp evict_buffer(state, :ctr) do
    if map_size(state.call_to_request) > @call_buffer_max do
      case :queue.out(state.call_to_request_q) do
        {{:value, evicted}, q1} ->
          %{
            state
            | call_to_request: Map.delete(state.call_to_request, evicted),
              call_to_request_q: q1
          }

        _ ->
          state
      end
    else
      state
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call
  # ---------------------------------------------------------------------------

  defp record_tool_call(%{data: data}) do
    request_id = metadata_request_id(data)
    tool_call_id = MapKeys.field(data, :call_id)
    tool_name = MapKeys.field(data, :tool_name) || ""
    arguments = MapKeys.field(data, :arguments)

    with {:ok, scope} <- resolve_scope(request_id) do
      envelope = ToolTranscript.envelope(arguments)
      content = ToolTranscript.summarize_args(tool_name, arguments)

      attrs = %{
        session_id: scope.session_id,
        request_id: request_id,
        role: :tool_call,
        content: content,
        metadata: %{
          tool_name: tool_name,
          arguments: envelope
        },
        tool_call_id: tool_call_id
      }

      attempt_append(attrs, scope.tenant_id, actor_for(scope))
    end
  end

  # ---------------------------------------------------------------------------
  # Tool result
  # ---------------------------------------------------------------------------

  defp record_tool_result(%{data: data}) do
    request_id = metadata_request_id(data)
    tool_call_id = MapKeys.field(data, :call_id)
    tool_name = MapKeys.field(data, :tool_name) || ""
    raw_result = MapKeys.field(data, :result)

    with {:ok, scope} <- resolve_scope(request_id) do
      envelope = ToolTranscript.envelope(raw_result)

      parent =
        if is_binary(request_id) and is_binary(tool_call_id) do
          case Message.tool_call_parent(scope.session_id, request_id, tool_call_id,
                 tenant: scope.tenant_id,
                 actor: actor_for(scope)
               ) do
            {:ok, [%{id: id} | _]} -> id
            _ -> nil
          end
        else
          nil
        end

      content = ToolTranscript.result_summary(tool_name, raw_result)

      attrs = %{
        session_id: scope.session_id,
        request_id: request_id,
        role: :tool_result,
        content: content,
        metadata: %{
          tool_name: tool_name,
          result: envelope
        },
        tool_call_id: tool_call_id,
        parent_message_id: parent
      }

      attempt_append(attrs, scope.tenant_id, actor_for(scope))
    end
  end

  # ---------------------------------------------------------------------------
  # Reasoning
  # ---------------------------------------------------------------------------

  defp record_reasoning(%{data: data}) do
    request_id = metadata_request_id(data)
    thinking = thinking_content(data)

    cond do
      is_nil(request_id) ->
        :skip

      is_nil(thinking) or thinking == "" ->
        :skip

      true ->
        with {:ok, scope} <- resolve_scope(request_id) do
          attrs = %{
            session_id: scope.session_id,
            request_id: request_id,
            role: :reasoning,
            content: thinking,
            metadata: %{}
          }

          attempt_append(attrs, scope.tenant_id, actor_for(scope))
        end
    end
  end

  defp thinking_content(%{result: {:ok, %{thinking_content: tc}, _effects}})
       when is_binary(tc),
       do: tc

  defp thinking_content(%{result: {:ok, %{thinking_content: tc}}})
       when is_binary(tc),
       do: tc

  defp thinking_content(%{result: {:ok, %{"thinking_content" => tc}, _effects}})
       when is_binary(tc),
       do: tc

  defp thinking_content(_), do: nil

  # ---------------------------------------------------------------------------
  # Terminal signals
  # ---------------------------------------------------------------------------

  defp finalize_request(nil, state), do: state

  defp finalize_request(request_id, state) do
    safe_handle(
      fn ->
        Cache.delete(request_id)
      end,
      "ai.request.terminal"
    )

    state
    |> clear_resolved_buffers(request_id)
    |> reply_waiters(request_id)
    |> mark_completed(request_id)
  end

  # Drop any `pending_usage` and `call_to_request` entries whose
  # `call_id` resolved to this `request_id`. Avoids unbounded growth
  # on orphaned LLM calls — the LRU cap is the floor; this is the
  # principled cleanup.
  defp clear_resolved_buffers(state, request_id) do
    resolved_calls =
      state.call_to_request
      |> Enum.filter(fn {_call, rid} -> rid == request_id end)
      |> Enum.map(fn {call, _} -> call end)

    case resolved_calls do
      [] ->
        state

      calls ->
        ctr = Map.drop(state.call_to_request, calls)
        pu = Map.drop(state.pending_usage, calls)
        %{state | call_to_request: ctr, pending_usage: pu}
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry merge into RequestCorrelation
  # ---------------------------------------------------------------------------

  defp record_telemetry(%{data: data}) do
    request_id = metadata_request_id(data) || MapKeys.field(data, :request_id)
    telemetry = extract_telemetry(data)

    cond do
      not is_binary(request_id) ->
        :ok

      telemetry == %{} ->
        :ok

      true ->
        merge_telemetry(request_id, telemetry)
    end
  end

  defp extract_telemetry(data) do
    metadata = MapKeys.field(data, :metadata) || %{}
    usage = MapKeys.field(data, :usage) || %{}
    {result_usage, result_model} = telemetry_from_result(MapKeys.field(data, :result))

    sources = %{
      data: data,
      metadata: metadata,
      usage: usage,
      result_usage: result_usage,
      result_model: result_model
    }

    %{}
    |> maybe_put(:run_id, telemetry_run_id(sources))
    |> maybe_put(:model, telemetry_model(sources))
    |> maybe_put(:input_tokens, telemetry_input_tokens(sources))
    |> maybe_put(:output_tokens, telemetry_output_tokens(sources))
    |> maybe_put(:latency_ms, telemetry_latency_ms(sources))
  end

  defp telemetry_run_id(%{metadata: metadata, data: data}) do
    MapKeys.field(metadata, :run_id) || MapKeys.field(data, :run_id)
  end

  defp telemetry_model(%{
         metadata: metadata,
         data: data,
         usage: usage,
         result_model: result_model
       }) do
    MapKeys.field(metadata, :model) || MapKeys.field(data, :model) ||
      MapKeys.field(usage, :model) || result_model
  end

  defp telemetry_input_tokens(%{
         metadata: metadata,
         data: data,
         usage: usage,
         result_usage: result_usage
       }) do
    MapKeys.field(metadata, :input_tokens) ||
      MapKeys.field(data, :input_tokens) ||
      MapKeys.field(usage, :input_tokens) ||
      MapKeys.field(result_usage, :input_tokens)
  end

  defp telemetry_output_tokens(%{
         metadata: metadata,
         data: data,
         usage: usage,
         result_usage: result_usage
       }) do
    MapKeys.field(metadata, :output_tokens) ||
      MapKeys.field(data, :output_tokens) ||
      MapKeys.field(usage, :output_tokens) ||
      MapKeys.field(result_usage, :output_tokens)
  end

  defp telemetry_latency_ms(%{metadata: metadata, data: data}) do
    duration_ms = MapKeys.field(metadata, :duration_ms) || MapKeys.field(data, :duration_ms)
    MapKeys.field(metadata, :latency_ms) || MapKeys.field(data, :latency_ms) || duration_ms
  end

  defp telemetry_from_result({:ok, payload, _effects}) when is_map(payload),
    do: {MapKeys.field(payload, :usage) || %{}, MapKeys.field(payload, :model)}

  defp telemetry_from_result({:ok, payload}) when is_map(payload),
    do: {MapKeys.field(payload, :usage) || %{}, MapKeys.field(payload, :model)}

  defp telemetry_from_result(_), do: {%{}, nil}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reply_waiters(state, request_id) do
    {pending, waiters} = Map.pop(state.waiters, request_id, [])
    Enum.each(pending, &GenServer.reply(&1, :ok))
    %{state | waiters: waiters}
  end

  defp mark_completed(state, request_id) do
    if MapSet.member?(state.recent_completed_set, request_id) do
      state
    else
      queue = :queue.in(request_id, state.recent_completed)
      set = MapSet.put(state.recent_completed_set, request_id)

      if MapSet.size(set) > @recent_completed_max do
        case :queue.out(queue) do
          {{:value, evicted}, queue1} ->
            %{state | recent_completed: queue1, recent_completed_set: MapSet.delete(set, evicted)}

          _ ->
            %{state | recent_completed: queue, recent_completed_set: set}
        end
      else
        %{state | recent_completed: queue, recent_completed_set: set}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scope resolution
  # ---------------------------------------------------------------------------

  defp resolve_scope(nil), do: :error

  @no_clone true
  defp resolve_scope(request_id) do
    case Cache.lookup(request_id) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        case RequestCorrelation.lookup(request_id) do
          {:ok, row} ->
            scope = %{
              session_id: row.session_id,
              tenant_id: row.tenant_id,
              workspace_id: row.workspace_id,
              user_id: row.user_id
            }

            Cache.put(request_id, scope)
            {:ok, scope}

          _ ->
            :error
        end
    end
  rescue
    e ->
      Logger.warning("[Recorder] scope lookup failed: #{Exception.message(e)}")
      :error
  end

  # ---------------------------------------------------------------------------
  # Append helpers
  # ---------------------------------------------------------------------------

  defp attempt_append(attrs, tenant_id, actor) do
    opts = [tenant: tenant_id]
    opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts

    case Message.append(attrs, opts) do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        if duplicate_key?(err) do
          Logger.debug("[Recorder] duplicate key (idempotent skip): #{inspect(err)}")
        else
          Logger.warning("[Recorder] append failed: #{inspect(err)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("[Recorder] append failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[Recorder] append raised: #{Exception.message(e)}")
      :ok
  end

  # Build a per-call Ash actor from a resolved scope. The scope shape
  # is identical from the cache and DB-fallback paths (`session_id`,
  # `tenant_id`, `workspace_id`, `user_id`). Used at every internal
  # write boundary so policies that filter by `tenant_id` don't drop
  # the recorder's writes.
  defp actor_for(%{tenant_id: tenant_id, user_id: user_id}) when is_binary(tenant_id) do
    %{user_id: user_id, tenant_id: tenant_id}
  end

  defp actor_for(_), do: nil

  defp duplicate_key?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn err ->
      is_struct(err) and
        (Map.get(err, :__struct__) == Ash.Error.Changes.InvalidAttribute or
           Map.get(err, :__struct__) == Ash.Error.Invalid)
        |> Kernel.&&(true)
    end) and
      errors
      |> Enum.map(&inspect/1)
      |> Enum.any?(
        &String.contains?(&1, [
          "unique_session_sequence",
          "unique_live_tool_row",
          "unique_import_hash"
        ])
      )
  end

  defp duplicate_key?(_), do: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_handle(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("[Recorder] #{label} raised: #{Exception.message(e)}")
  catch
    kind, payload -> Logger.warning("[Recorder] #{label} #{kind}: #{inspect(payload)}")
  end

  defp metadata_request_id(data) do
    metadata = MapKeys.field(data, :metadata) || %{}
    MapKeys.field(metadata, :request_id)
  end
end
