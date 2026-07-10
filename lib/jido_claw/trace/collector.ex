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
  require Logger

  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Core.ConfigValue
  alias JidoClaw.Security.SensitiveScrub
  alias JidoClaw.Trace.Event
  alias JidoClaw.Trace.Limit, as: TraceLimit
  alias JidoClaw.Trace.Policy
  alias JidoClaw.Trace.Sanitize, as: TraceSanitize
  alias JidoClaw.Trace.Sink.Postgres, as: SinkPostgres

  @handler_id "jido-claw-trace-collector"

  @default_max_traces 100
  @default_max_events_per_trace 300
  @default_policy Policy.default()

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
    [:jido_claw, :reasoning, :event],
    [:jido_claw, :composer, :event]
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
            by_tenant: %{},
            policy: @default_policy,
            sink: SinkPostgres

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
          by_tenant: map(),
          policy: Policy.t(),
          sink: module()
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
  @spec handle_telemetry([atom()], map(), map(), term()) :: :ok | tuple()
  def handle_telemetry(event_name, measurements, metadata, _config)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:telemetry_event, event_name, measurements, metadata})
    end
  end

  @impl GenServer
  def init(_opts) do
    attach_handlers()
    config = Application.get_env(:jido_claw, :trace, [])

    fields =
      Map.merge(trace_config(config), %{
        policy: Policy.from_config(config),
        sink: resolve_sink(config)
      })

    {:ok, struct(__MODULE__, fields)}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @impl GenServer
  def handle_call({:latest, ref, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id)

    candidate_trace =
      case Map.get(ref, :request_id) do
        request_id when is_binary(request_id) ->
          trace_by_request(state, request_id)

        _ ->
          state
          |> candidates(ref)
          |> filter_by_tenant(tenant_id)
          |> List.last()
      end

    trace = enforce_tenant(candidate_trace, tenant_id)
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

  @impl GenServer
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

  defp trace_config(config) do
    %{
      enabled?: config_value(config, :enabled?, true),
      max_traces:
        ConfigValue.positive_integer(
          config_value(config, :max_traces, @default_max_traces),
          @default_max_traces
        ),
      max_events_per_trace:
        ConfigValue.positive_integer(
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

  defp record_event(state, event_name, measurements, metadata) do
    seq = state.seq + 1

    case normalize_event(state.policy, seq, event_name, measurements, metadata) do
      nil ->
        %{state | seq: seq}

      %Event{} = event ->
        key = trace_key(event)

        # Deterministic per-trace sampling: a dropped key still bumps `seq`
        # (keeping it monotonic for the UPSERT/UUID contracts) but never
        # touches the ring or the sink. Recomputed each event — no drop-cache.
        if Policy.keep_trace?(state.policy, key) do
          ingest_event(state, event, key, seq)
        else
          %{state | seq: seq}
        end
    end
  end

  defp ingest_event(state, event, key, seq) do
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
    |> maybe_write_sink(event, trace)
  end

  defp normalize_event(policy, seq, event_name, measurements, metadata) do
    case event_shape(event_name, metadata) do
      {:ok, source, category, event} ->
        request_id = string_value(metadata, :request_id)
        run_id = string_value(metadata, :run_id) || request_id

        trace_id =
          string_value(metadata, :jido_trace_id) ||
            string_value(metadata, :trace_id) ||
            run_id ||
            request_id ||
            Ash.UUID.generate()

        span_id = string_value(metadata, :jido_span_id) || string_value(metadata, :span_id)

        parent_span_id =
          string_value(metadata, :jido_parent_span_id) ||
            string_value(metadata, :parent_span_id)

        # AR-2 Phase 2b (P1a): resolve the sensitivity marker ONCE and gate EVERY
        # metadata-derived column on it (not just the two `:map` columns). On a
        # confident `:marked`, the trusted `request_id` is the only metadata ID
        # the marker was registered under, so collapse the other ID columns to it
        # and drop the rest of the derived sinks. `:unmarked`/`:unknown` pass
        # through unchanged.
        marker = marker_for(request_id)
        raw_phase = atom_value(metadata, :phase) || atom_value(metadata, :stage)

        %Event{
          seq: seq,
          at_ms: event_time_ms(measurements, metadata),
          source: source,
          category: category,
          event: event,
          phase: redact_phase(marker, raw_phase),
          name: redact_name(marker, event_name_label(category, metadata)),
          status: event_status(category, event, metadata),
          duration_ms: duration_ms(measurements),
          request_id: request_id,
          run_id: collapse_to_request(marker, run_id, request_id),
          trace_id: collapse_to_request(marker, trace_id, request_id),
          span_id: redact_span_id(marker, span_id),
          parent_span_id: redact_span_id(marker, parent_span_id),
          measurements: redact_map(marker, TraceSanitize.payload(policy, measurements)),
          metadata: redact_map(marker, TraceSanitize.payload(policy, metadata))
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
    events =
      events
      |> Enum.reverse()
      |> then(&[event | &1])
      |> Enum.reverse()
      |> Enum.take(-max_events)

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
    # Tenant attribution begins with only the globally unique request id.
    # credo:disable-for-next-line AshCredo.Check.Warning.AuthorizeFalse
    case RequestCorrelation.lookup(request_id, authorize?: false) do
      {:ok, %{tenant_id: tid}} when is_binary(tid) and tid != "" -> tid
      _ -> nil
    end

    # tenant lookup is best-effort attribution; any DB fault means "no tenant"
  rescue
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # AR-2 Phase 2b sink (vi) — `request_id` is the trusted correlation key the
  # marker was registered under; every OTHER column is derived from raw
  # `metadata` and is a potential content sink (P1a). `marker_for/1` resolves the
  # marker ONCE (cache → durable, via `marker_status/1`) and the per-column
  # redactors below branch on it. A `nil` request_id is `:unmarked` (most
  # workflow/output telemetry carries none, and a marked subagent ALWAYS has a
  # registered request_id by C4).
  #
  # Digest only on a confident `:marked`. `:unknown` (absent/faulting row)
  # PASSES — a deliberate deviation from the doc's fail-closed-on-unknown:
  # (a) C4 guarantees a marked subagent ALWAYS has a durable correlation row
  # (the turn aborts on a write failure), so `:marked` is reliably resolvable
  # during its life AND the conservative C5 `expires_at` window (which catches
  # orphan late-writes via the durable fallback) — fail-closed adds nothing for
  # marked data; (b) the trace system extracts structural fields (`agent_id`,
  # `run_id`) FROM `metadata`, and most legitimate non-composer telemetry
  # carries a `request_id` whose correlation row has simply expired (600s TTL),
  # so digesting `:unknown` would shred general observability. The residual
  # gap — a marked span arriving AFTER its C5 ceiling — is beyond the designed
  # orphan-drain retention.
  defp marker_for(nil), do: :unmarked
  defp marker_for(request_id), do: marker_status(request_id)

  # The two `:map` columns (`metadata`/`measurements`) → a type-valid redacted
  # map; `name` (arbitrary metadata string content) → the redacted-text
  # placeholder; `phase` (atom) → nil. Redact only on a confident `:marked`.
  defp redact_map(:marked, _payload), do: SensitiveScrub.redacted_map()
  defp redact_map(_marker, payload), do: payload

  defp redact_name(:marked, _name), do: SensitiveScrub.redacted_text()
  defp redact_name(_marker, name), do: name

  defp redact_phase(:marked, _phase), do: nil
  defp redact_phase(_marker, phase), do: phase

  # `trace_id`/`run_id` collapse to the trusted `request_id` on a marked span —
  # their metadata-derived values are tainted. Trace assembly keys on
  # `request_id` first (`trace_key/1`), so grouping stays coherent and the span
  # is never stranded.
  defp collapse_to_request(:marked, _value, request_id), do: request_id
  defp collapse_to_request(_marker, value, _request_id), do: value

  # `span_id`/`parent_span_id` are DROPPED entirely on a marked span. They are
  # metadata-derived (read straight from `metadata`, with no internal provenance
  # distinguishing a framework-generated id from injected content), so a shape
  # gate is NOT a real trust boundary — a sensitive value that happens to be
  # hex/UUID-shaped (a hash, a hex token) would slip through into `trace_events`.
  # Only the registered `request_id` is trusted; trace assembly keys on it (not
  # span_id, see `trace_key/1`), so dropping these costs only intra-trace span
  # nesting for marked composer turns, never grouping.
  defp redact_span_id(:marked, _span_id), do: nil
  defp redact_span_id(_marker, span_id), do: span_id

  # `:marked | :unmarked | :unknown`. Cache-first (live turns hit ETS); the
  # durable fallback catches a marked subagent's orphan late-writes after its
  # cache entry was cleared on request completion (within the C5 ceiling). An
  # absent row or a faulting read is `:unknown`.
  defp marker_status(request_id) do
    case Cache.lookup(request_id) do
      {:ok, %{sanitize_sensitive_context: true}} -> :marked
      {:ok, %{sanitize_sensitive_context: false}} -> :unmarked
      _miss_or_no_key -> durable_marker_status(request_id)
    end
  end

  defp durable_marker_status(request_id) do
    # Late marker recovery begins with only the globally unique request id.
    # credo:disable-for-next-line AshCredo.Check.Warning.AuthorizeFalse
    case RequestCorrelation.lookup(request_id, authorize?: false) do
      {:ok, %{sanitize_sensitive_context: true}} -> :marked
      {:ok, %{sanitize_sensitive_context: false}} -> :unmarked
      _absent -> :unknown
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
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
    if key in order do
      order
    else
      order
      |> Enum.reverse()
      |> then(&[key | &1])
      |> Enum.reverse()
    end
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

  defp maybe_write_sink(state, event, trace) do
    if persist?() do
      state.sink.write(event, trace)
    end

    state
  end

  # `persist?()` stays a LIVE per-event read (not snapshotted at init) so a
  # test can flip `persist?: false` via `put_env` without restarting the
  # Collector — snapshotting it would reintroduce sandbox-leak writes.
  defp persist? do
    Keyword.get(Application.get_env(:jido_claw, :trace, []), :persist?, true)
  end

  # Resolve + validate the configured sink once at init. The `is_atom` guard
  # runs first so a non-module value (e.g. `sink: "oops"`) can't crash
  # `Code.ensure_loaded?/1`; any invalid value logs and falls back to the
  # default Postgres sink, so a bad `:sink` never crashes the Collector.
  defp resolve_sink(config) do
    sink = config_value(config, :sink, SinkPostgres)

    if is_atom(sink) and Code.ensure_loaded?(sink) and function_exported?(sink, :write, 2) do
      sink
    else
      Logger.warning(
        "[Trace.Collector] invalid :sink #{inspect(sink)} — falling back to #{inspect(SinkPostgres)}"
      )

      SinkPostgres
    end
  end
end
