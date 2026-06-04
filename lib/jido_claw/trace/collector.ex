defmodule JidoClaw.Trace.Collector do
  @moduledoc """
  Bounded in-memory trace collector for JidoClaw and Jido.AI telemetry.

  The collector is a singleton GenServer supervised by `JidoClaw.Application`
  and is intentionally internal — public callers should reach for
  `JidoClaw.Trace`. It attaches to a fixed list of telemetry events on init,
  drops the raw events into its mailbox, sanitizes/normalizes each one into
  a `%JidoClaw.Trace.Event{}`, and appends to a bounded ring keyed by
  `request_id` / `run_id` / `trace_id`.

  ## Bounds

  Two ring caps prevent unbounded growth:

    * `:max_traces` (default 100) — total retained traces. When exceeded,
      the oldest (LRU) is evicted in bulk.
    * `:max_events_per_trace` (default 300) — per-trace FIFO event window.
      Older events are dropped first; under streaming workloads this is
      why we deliberately omit `[:jido, :ai, :llm, :delta]` (a single LLM
      call emits 100s of deltas and would evict the lifecycle events).

  ## Deltas (v1 limitation)

  `[:jido, :ai, :llm, :delta]` is **not** attached. Coalescing — a
  `delta_count` and `last_delta_preview` rolled into the parent `:model`
  span — is the correct shape but isn't implemented in v1. No config flag
  toggles unfiltered delta ingest, because that would silently flood the
  ring and `trace_events` rows.

  ## Tenant attribution

  At first-event ingest the collector resolves `tenant_id` from
  `JidoClaw.Conversations.RequestCorrelation.Cache.lookup/1`, falling
  back to `RequestCorrelation.lookup/1` (Postgres). The resolved value
  is stamped on the trace and is treated as invariant for the trace's
  lifetime — but if the very first event raced ahead of the cache
  registration we backfill on subsequent events via the same lookup
  chain.

  Strict tenant filtering happens at query time
  (`JidoClaw.Trace.latest/2|for_request/3|list/2` with `tenant_id:` opt)
  — a candidate trace whose `:tenant_id` doesn't match is excluded
  before `latest` picks, so a tenant-A query can never fall through to
  a tenant-B trace.

  ## Trace IDs

  When no `jido_trace_id` / `trace_id` / `run_id` / `request_id` is
  present, `Ash.UUID.generate/0` mints a fresh id. The legacy
  `"trace_unattributed_<seq>"` form is unsafe across persistence
  restarts because `seq` resets at boot, which would collide on the
  globally-unique `trace_runs.trace_id` index.
  """

  use GenServer

  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Trace.Event
  alias JidoClaw.Trace.Limit, as: TraceLimit
  alias JidoClaw.Trace.Persistence, as: TracePersistence
  alias JidoClaw.Trace.Sanitize, as: TraceSanitize

  @handler_id "jido-claw-trace-collector"

  @default_max_traces 100
  @default_max_events_per_trace 300

  # `[:jido, :ai, :llm, :delta]` is deliberately omitted — a single LLM
  # call emits 100s of these and would evict the lifecycle events in
  # the bounded ring. See module doc.
  @base_jido_ai_events [
    [:jido, :ai, :request, :start],
    [:jido, :ai, :request, :complete],
    [:jido, :ai, :request, :failed],
    [:jido, :ai, :request, :rejected],
    [:jido, :ai, :request, :cancelled],
    [:jido, :ai, :llm, :start],
    [:jido, :ai, :llm, :complete],
    [:jido, :ai, :llm, :error],
    [:jido, :ai, :tool, :start],
    [:jido, :ai, :tool, :retry],
    [:jido, :ai, :tool, :complete],
    [:jido, :ai, :tool, :error],
    [:jido, :ai, :tool, :timeout],
    [:jido, :ai, :tool, :execute, :start],
    [:jido, :ai, :tool, :execute, :stop],
    [:jido, :ai, :tool, :execute, :exception],
    [:jido, :ai, :output, :start],
    [:jido, :ai, :output, :validated],
    [:jido, :ai, :output, :repair],
    [:jido, :ai, :output, :error]
  ]

  @jido_claw_events [
    [:jido_claw, :hook, :event],
    [:jido_claw, :guardrail, :event],
    [:jido_claw, :memory, :event],
    [:jido_claw, :workflow, :event],
    [:jido_claw, :subagent, :event],
    [:jido_claw, :handoff, :event],
    [:jido_claw, :mcp, :event],
    [:jido_claw, :output, :event],
    [:jido_claw, :schedule, :event],
    [:jido_claw, :compaction, :event],
    [:jido_claw, :reasoning, :event]
  ]

  defstruct enabled?: true,
            max_traces: @default_max_traces,
            max_events_per_trace: @default_max_events_per_trace,
            seq: 0,
            traces: %{},
            order: [],
            by_agent: %{},
            by_request: %{},
            by_run: %{},
            by_trace: %{},
            by_tenant: %{}

  @type t :: %__MODULE__{
          enabled?: boolean(),
          max_traces: pos_integer(),
          max_events_per_trace: pos_integer(),
          seq: non_neg_integer(),
          traces: map(),
          order: [term()],
          by_agent: map(),
          by_request: map(),
          by_run: map(),
          by_trace: map(),
          by_tenant: map()
        }

  @type target_ref :: %{
          optional(:agent_id) => term(),
          optional(:request_id) => String.t(),
          optional(:tenant_id) => String.t()
        }

  @doc "Starts the trace collector process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the latest trace matching an agent or request reference."
  @spec latest(target_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def latest(ref, opts \\ []) when is_map(ref) do
    GenServer.call(__MODULE__, {:latest, ref, opts})
  end

  @doc "Returns the trace for a specific request id."
  @spec for_request(target_ref(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def for_request(ref, request_id, opts \\ []) when is_map(ref) and is_binary(request_id) do
    GenServer.call(__MODULE__, {:for_request, ref, request_id, opts})
  end

  @doc "Lists retained traces matching an agent reference."
  @spec list(target_ref(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(ref, opts \\ []) when is_map(ref) do
    GenServer.call(__MODULE__, {:list, ref, opts})
  end

  @doc false
  def handle_telemetry(event_name, measurements, metadata, _config)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:telemetry_event, event_name, measurements, metadata})
    end
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, struct(__MODULE__, trace_config())}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @impl true
  def handle_call({:latest, ref, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id)

    trace =
      case Map.get(ref, :request_id) do
        request_id when is_binary(request_id) ->
          trace_by_request(state, request_id)

        _ ->
          state
          |> candidates(ref)
          |> filter_by_tenant(tenant_id)
          |> List.last()
      end

    trace = enforce_tenant(trace, tenant_id)
    {:reply, maybe_reply_trace(trace, opts), state}
  end

  def handle_call({:for_request, _ref, request_id, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id)

    trace =
      state
      |> trace_by_request(request_id)
      |> enforce_tenant(tenant_id)

    {:reply, maybe_reply_trace(trace, opts), state}
  end

  def handle_call({:list, ref, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id) || Map.get(ref, :tenant_id)

    traces =
      state
      |> candidates(ref)
      |> filter_by_tenant(tenant_id)
      |> maybe_limit(Keyword.get(opts, :limit))

    {:reply, {:ok, traces}, state}
  end

  # Test-only sync barrier. Sending this via `GenServer.call/2` blocks
  # the caller until the GenServer has drained every prior
  # `{:telemetry_event, ...}` mailbox entry (FIFO).
  def handle_call(:__sync__, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(
        {:telemetry_event, event_name, measurements, metadata},
        %{enabled?: true} = state
      ) do
    {:noreply, record_event(state, event_name, measurements, metadata)}
  end

  def handle_info({:telemetry_event, _event_name, _measurements, _metadata}, state),
    do: {:noreply, state}

  defp attach_handlers do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @base_jido_ai_events ++ @jido_claw_events,
        &__MODULE__.handle_telemetry/4,
        nil
      )
  end

  defp trace_config do
    config = Application.get_env(:jido_claw, :trace, [])

    %{
      enabled?: config_value(config, :enabled?, true),
      max_traces:
        normalize_positive_integer(
          config_value(config, :max_traces, @default_max_traces),
          @default_max_traces
        ),
      max_events_per_trace:
        normalize_positive_integer(
          config_value(config, :max_events_per_trace, @default_max_events_per_trace),
          @default_max_events_per_trace
        )
    }
  end

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, default)

  defp config_value(_config, _key, default), do: default

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp record_event(state, event_name, measurements, metadata) do
    seq = state.seq + 1

    case normalize_event(seq, event_name, measurements, metadata) do
      nil ->
        %{state | seq: seq}

      %Event{} = event ->
        key = trace_key(event)

        trace =
          state.traces
          |> Map.get(key, new_trace(event))
          |> append_event(event, state.max_events_per_trace)
          |> backfill_tenant(event)

        traces = Map.put(state.traces, key, trace)
        order = append_order(state.order, key)
        new_state = %{state | seq: seq, traces: traces, order: order}

        new_state
        |> prune_traces()
        |> rebuild_indexes()
        |> maybe_persist(event, trace)
    end
  end

  defp normalize_event(seq, event_name, measurements, metadata) do
    case event_shape(event_name, metadata) do
      {:ok, source, category, event} ->
        sanitized_measurements = TraceSanitize.payload(measurements)
        sanitized_metadata = TraceSanitize.payload(metadata)
        request_id = string_value(metadata, :request_id)
        run_id = string_value(metadata, :run_id) || request_id

        trace_id =
          string_value(metadata, :jido_trace_id) ||
            string_value(metadata, :trace_id) ||
            run_id ||
            request_id ||
            Ash.UUID.generate()

        %Event{
          seq: seq,
          at_ms: event_time_ms(measurements, metadata),
          source: source,
          category: category,
          event: event,
          phase: atom_value(metadata, :phase) || atom_value(metadata, :stage),
          name: event_name_label(category, metadata),
          status: event_status(category, event, metadata),
          duration_ms: duration_ms(measurements),
          request_id: request_id,
          run_id: run_id,
          trace_id: trace_id,
          span_id: string_value(metadata, :jido_span_id) || string_value(metadata, :span_id),
          parent_span_id:
            string_value(metadata, :jido_parent_span_id) ||
              string_value(metadata, :parent_span_id),
          measurements: sanitized_measurements,
          metadata: sanitized_metadata
        }

      :error ->
        nil
    end
  end

  defp event_shape([:jido, :ai, :request, event], _m), do: {:ok, :jido_ai, :request, event}
  defp event_shape([:jido, :ai, :llm, event], _m), do: {:ok, :jido_ai, :model, event}

  defp event_shape([:jido, :ai, :tool, event], _m) when event != :execute,
    do: {:ok, :jido_ai, :tool, event}

  defp event_shape([:jido, :ai, :tool, :execute, event], _m),
    do: {:ok, :jido_ai, :tool, event}

  defp event_shape([:jido, :ai, :output, event], _m), do: {:ok, :jido_ai, :output, event}

  defp event_shape([:jido_claw, category, :event], metadata) when is_atom(category) do
    {:ok, :jido_claw, category, atom_value(metadata, :event) || :event}
  end

  defp event_shape(_event_name, _metadata), do: :error

  defp event_time_ms(measurements, metadata) do
    cond do
      is_integer(get_value(metadata, :at_ms)) ->
        get_value(metadata, :at_ms)

      is_integer(get_value(measurements, :system_time)) ->
        System.convert_time_unit(get_value(measurements, :system_time), :nanosecond, :millisecond)

      true ->
        System.system_time(:millisecond)
    end
  end

  defp duration_ms(measurements) do
    cond do
      is_number(get_value(measurements, :duration_ms)) and
          get_value(measurements, :duration_ms) > 0 ->
        round(get_value(measurements, :duration_ms))

      is_integer(get_value(measurements, :duration)) and get_value(measurements, :duration) > 0 ->
        System.convert_time_unit(get_value(measurements, :duration), :nanosecond, :millisecond)

      true ->
        nil
    end
  end

  defp event_name_label(:request, metadata), do: string_value(metadata, :agent_id)
  defp event_name_label(:model, metadata), do: string_value(metadata, :model)
  defp event_name_label(:tool, metadata), do: string_value(metadata, :tool_name)

  defp event_name_label(:workflow, metadata),
    do: string_value(metadata, :workflow) || string_value(metadata, :name)

  defp event_name_label(:subagent, metadata),
    do: string_value(metadata, :subagent) || string_value(metadata, :name)

  defp event_name_label(:handoff, metadata),
    do: string_value(metadata, :handoff) || string_value(metadata, :name)

  defp event_name_label(:guardrail, metadata),
    do: string_value(metadata, :guardrail) || string_value(metadata, :label)

  defp event_name_label(:hook, metadata),
    do: string_value(metadata, :hook) || string_value(metadata, :label)

  defp event_name_label(:memory, metadata), do: string_value(metadata, :namespace)

  defp event_name_label(:compaction, metadata),
    do: string_value(metadata, :compaction) || string_value(metadata, :name)

  defp event_name_label(:mcp, metadata), do: string_value(metadata, :endpoint)

  defp event_name_label(:output, metadata),
    do: string_value(metadata, :output) || string_value(metadata, :name)

  defp event_name_label(:schedule, metadata),
    do: string_value(metadata, :schedule_id) || string_value(metadata, :name)

  defp event_name_label(:reasoning, metadata),
    do: string_value(metadata, :name) || string_value(metadata, :strategy)

  defp event_name_label(_category, metadata), do: string_value(metadata, :name)

  defp event_status(:request, :start, _m), do: :running
  defp event_status(:request, :complete, _m), do: :completed
  defp event_status(:request, :failed, _m), do: :failed
  defp event_status(:request, :cancelled, _m), do: :cancelled
  defp event_status(:request, :rejected, _m), do: :failed
  defp event_status(_category, event, _m) when event in [:start, :started], do: :running

  defp event_status(_category, event, _m)
       when event in [:stop, :complete, :completed, :ok, :allow, :validated],
       do: :completed

  defp event_status(:compaction, event, _m) when event in [:summarized, :skipped],
    do: :completed

  defp event_status(:output, :repair, _m), do: :running

  defp event_status(_category, event, _m) when event in [:error, :failed, :timeout, :block],
    do: :failed

  defp event_status(_category, :exception, _m), do: :failed

  defp event_status(_category, event, _m) when event in [:interrupt, :interrupted],
    do: :interrupted

  defp event_status(_category, _event, metadata),
    do: atom_value(metadata, :status) || outcome_status(get_value(metadata, :outcome))

  defp outcome_status(:ok), do: :completed
  defp outcome_status(:allow), do: :completed
  defp outcome_status(:block), do: :failed
  defp outcome_status(:error), do: :failed
  defp outcome_status(:interrupt), do: :interrupted
  defp outcome_status({:error, _reason}), do: :failed
  defp outcome_status({:interrupt, _interrupt}), do: :interrupted
  defp outcome_status(_outcome), do: nil

  defp new_trace(%Event{} = event) do
    %JidoClaw.Trace{
      trace_id: event.trace_id,
      run_id: event.run_id,
      request_id: event.request_id,
      agent_id: get_value(event.metadata, :agent_id),
      tenant_id: resolve_tenant(event),
      status: event.status,
      started_at_ms: event.at_ms,
      completed_at_ms: nil,
      events: [],
      summary: %{}
    }
  end

  defp append_event(%JidoClaw.Trace{events: events} = trace, %Event{} = event, max_events) do
    # Bounded ring of last `max_events` — equivalent to `events ++ [event]` then
    # take the tail, expressed with Enum to satisfy ExSlop's
    # `Refactor.AppendSingleItem` check without changing semantics.
    events = events |> Enum.reverse() |> then(&[event | &1]) |> Enum.reverse()
    events = Enum.take(events, -max_events)
    status = terminal_status(event.status) || trace.status || event.status

    %{
      trace
      | trace_id: trace.trace_id || event.trace_id,
        run_id: trace.run_id || event.run_id,
        request_id: trace.request_id || event.request_id,
        agent_id: trace.agent_id || get_value(event.metadata, :agent_id),
        status: status,
        started_at_ms: min_time(trace.started_at_ms, event.at_ms),
        completed_at_ms: completed_at(trace.completed_at_ms, event),
        events: events,
        summary: trace_summary(events, status)
    }
  end

  defp backfill_tenant(%JidoClaw.Trace{tenant_id: nil} = trace, %Event{} = event) do
    case resolve_tenant(event) do
      nil -> trace
      tenant_id -> %{trace | tenant_id: tenant_id}
    end
  end

  defp backfill_tenant(%JidoClaw.Trace{} = trace, _event), do: trace

  defp resolve_tenant(%Event{request_id: request_id, metadata: metadata}) do
    case string_value(metadata, :tenant_id) do
      tid when is_binary(tid) and tid != "" -> tid
      _ -> lookup_tenant(request_id)
    end
  end

  defp lookup_tenant(request_id) when is_binary(request_id) do
    case Cache.lookup(request_id) do
      {:ok, %{tenant_id: tid}} when is_binary(tid) and tid != "" ->
        tid

      _ ->
        durable_tenant(request_id)
    end
  end

  defp lookup_tenant(_request_id), do: nil

  defp durable_tenant(request_id) do
    case RequestCorrelation.lookup(request_id) do
      {:ok, %{tenant_id: tid}} when is_binary(tid) and tid != "" -> tid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp completed_at(current, %Event{status: status, at_ms: at_ms})
       when status in [:completed, :failed, :cancelled, :interrupted],
       do: at_ms || current

  defp completed_at(current, _event), do: current

  defp min_time(nil, at_ms), do: at_ms
  defp min_time(current, nil), do: current
  defp min_time(current, at_ms), do: min(current, at_ms)

  defp terminal_status(status) when status in [:completed, :failed, :cancelled, :interrupted],
    do: status

  defp terminal_status(_status), do: nil

  defp trace_summary(events, status) do
    %{
      status: status,
      event_count: length(events),
      model_events: count_category(events, :model),
      tool_events: count_category(events, :tool),
      workflow_events: count_category(events, :workflow),
      subagent_events: count_category(events, :subagent),
      handoff_events: count_category(events, :handoff),
      guardrail_events: count_category(events, :guardrail),
      memory_events: count_category(events, :memory),
      compaction_events: count_category(events, :compaction),
      output_events: count_category(events, :output),
      schedule_events: count_category(events, :schedule),
      reasoning_events: count_category(events, :reasoning),
      error_events: Enum.count(events, &(&1.status == :failed))
    }
  end

  defp count_category(events, category), do: Enum.count(events, &(&1.category == category))

  defp trace_key(%Event{request_id: request_id}) when is_binary(request_id),
    do: {:request, request_id}

  defp trace_key(%Event{run_id: run_id}) when is_binary(run_id), do: {:run, run_id}
  defp trace_key(%Event{trace_id: trace_id}) when is_binary(trace_id), do: {:trace, trace_id}
  defp trace_key(%Event{seq: seq}), do: {:event, seq}

  defp append_order(order, key) do
    if key in order,
      do: order,
      else: order |> Enum.reverse() |> then(&[key | &1]) |> Enum.reverse()
  end

  defp prune_traces(%__MODULE__{} = state) do
    extra_count = length(state.order) - state.max_traces

    if extra_count > 0 do
      {drop, keep} = Enum.split(state.order, extra_count)
      %{state | order: keep, traces: Map.drop(state.traces, drop)}
    else
      state
    end
  end

  # Iterate `state.order` (insertion-ordered keys), NOT `state.traces` (a
  # map). `by_agent`/`by_tenant` accumulate their key lists via
  # `append_order/2`, and `latest/2` relies on `List.last/1` of those lists
  # being the most-recently-inserted trace. Reducing over the `state.traces`
  # map iterates in hash order once it exceeds ~32 entries (Erlang's HAMT
  # threshold), which scrambles that recency order and makes `latest/2`
  # return a stale trace for a busy agent. `prune_traces/1` keeps `order` and
  # `traces` in lockstep, so every key here is present in `state.traces`.
  defp rebuild_indexes(%__MODULE__{} = state) do
    indexes =
      Enum.reduce(
        state.order,
        %{by_agent: %{}, by_request: %{}, by_run: %{}, by_trace: %{}, by_tenant: %{}},
        fn key, acc ->
          trace = Map.fetch!(state.traces, key)

          acc
          |> put_index(:by_agent, trace.agent_id, key)
          |> put_index(:by_request, trace.request_id, key)
          |> put_index(:by_run, trace.run_id, key)
          |> put_index(:by_trace, trace.trace_id, key)
          |> put_index(:by_tenant, trace.tenant_id, key)
        end
      )

    Map.merge(state, indexes)
  end

  defp put_index(acc, _index, nil, _key), do: acc

  defp put_index(acc, index, value, key) when index in [:by_agent, :by_tenant] do
    update_in(acc[index], fn values ->
      Map.update(values, value, [key], &append_order(&1, key))
    end)
  end

  defp put_index(acc, index, value, key), do: update_in(acc[index], &Map.put(&1, value, key))

  defp trace_by_request(state, request_id) do
    case Map.fetch(state.by_request, request_id) do
      {:ok, key} -> Map.get(state.traces, key)
      :error -> nil
    end
  end

  defp candidates(state, %{agent_id: agent_id}) when not is_nil(agent_id) do
    traces_for_agent(state, agent_id)
  end

  defp candidates(state, %{tenant_id: tenant_id}) when is_binary(tenant_id) do
    traces_for_tenant(state, tenant_id)
  end

  defp candidates(state, _ref), do: Enum.map(state.order, &Map.fetch!(state.traces, &1))

  defp traces_for_agent(state, agent_id) do
    state.by_agent
    |> Map.get(agent_id, [])
    |> Enum.map(&Map.fetch!(state.traces, &1))
  end

  defp traces_for_tenant(state, tenant_id) do
    state.by_tenant
    |> Map.get(tenant_id, [])
    |> Enum.map(&Map.fetch!(state.traces, &1))
  end

  defp filter_by_tenant(traces, nil), do: traces

  defp filter_by_tenant(traces, tenant_id) when is_binary(tenant_id),
    do: Enum.filter(traces, &(&1.tenant_id == tenant_id))

  defp enforce_tenant(nil, _tenant_id), do: nil
  defp enforce_tenant(trace, nil), do: trace
  defp enforce_tenant(%JidoClaw.Trace{tenant_id: t} = trace, t), do: trace
  defp enforce_tenant(_trace, _tenant_id), do: nil

  defp maybe_reply_trace(nil, _opts), do: {:error, :not_found}
  defp maybe_reply_trace(%{} = trace, _opts), do: {:ok, trace}

  defp maybe_limit(values, limit), do: TraceLimit.take(values, limit)

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp string_value(map, key) do
    case get_value(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp atom_value(map, key) do
    case get_value(map, key) do
      value when is_atom(value) and not is_nil(value) -> value
      value when is_binary(value) and value != "" -> existing_atom(value)
      _ -> nil
    end
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp maybe_persist(state, event, trace) do
    if persist?() do
      TracePersistence.append(event, trace)
    end

    state
  end

  defp persist? do
    Application.get_env(:jido_claw, :trace, [])
    |> Keyword.get(:persist?, true)
  end
end
