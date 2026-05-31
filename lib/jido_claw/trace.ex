defmodule JidoClaw.Trace do
  @moduledoc """
  Unified per-request trace surface for JidoClaw.

  `JidoClaw.Trace` is a bounded in-memory projection over Jido/Jido.AI
  telemetry plus JidoClaw-specific lifecycle events (hooks, guardrails,
  memory, workflows, subagents, handoffs, MCP, structured output,
  schedules, compaction, reasoning). Every LiveView, the CLI REPL, the
  MCP server, and the certificate verifier consume the same projection
  so a single `request_id` answers the same way everywhere.

  The Trace surface does **not** replace `JidoClaw.Conversations.Message`
  or `JidoClaw.Reasoning.Resources.Outcome` — those remain the durable
  record-of-truth for messages and reasoning telemetry. The Trace is the
  in-flight view that links them via `request_id`.

  ## Emitting events

  Use `emit/3` to publish a JidoClaw-native event. The wrapper stamps
  `:category` and `:source` into metadata and forwards through
  `Jido.Observe.emit_event/3` so `Jido.Tracing.Context` correlation IDs
  (`jido_trace_id`, `jido_span_id`, `jido_parent_span_id`) ride along
  automatically.

      JidoClaw.Trace.emit(:reasoning, %{
        event: :start,
        phase: :strategy,
        name: "react",
        request_id: request_id
      }, %{duration_ms: 0})

  > #### Argument order {: .warning}
  >
  > Jidoka's `emit/3` is `(category, metadata, measurements)`, while
  > `Jido.Observe.emit_event/3` is `(event_prefix, measurements,
  > metadata)`. The wrapper swaps them for you. Mixing this up would
  > land caller-supplied `:event`/`:phase`/`:name`/`:request_id` keys
  > in measurements instead of metadata and normalize every emit to
  > `%Event{event: :event}` — a silent footgun.

  ## Querying

  `latest/2`, `for_request/3`, and `list/2` accept either a `pid`,
  a string `agent_id`, a `%Jido.Agent{}`, or `{:request, request_id}` /
  `{:tenant, tenant_id}`. Pass `tenant_id:` in `opts` for a strict
  filter that excludes traces belonging to other tenants before the
  "latest" pick — see the module docs for `JidoClaw.Trace.Collector`.
  """

  alias JidoClaw.Trace.{Collector, Event}
  alias JidoClaw.Trace.Limit, as: TraceLimit
  alias JidoClaw.Trace.Resources.TraceEvent
  alias JidoClaw.Trace.Resources.TraceRun

  @agent_id_key :__jido_claw_agent_id__

  @type t :: %__MODULE__{
          trace_id: String.t() | nil,
          run_id: String.t() | nil,
          request_id: String.t() | nil,
          agent_id: term(),
          tenant_id: String.t() | nil,
          status: atom() | nil,
          started_at_ms: integer() | nil,
          completed_at_ms: integer() | nil,
          events: [Event.t()],
          summary: map()
        }

  @type target ::
          pid()
          | String.t()
          | Jido.Agent.t()
          | {:request, String.t()}
          | {:tenant, String.t()}

  defstruct [
    :trace_id,
    :run_id,
    :request_id,
    :agent_id,
    :tenant_id,
    :status,
    :started_at_ms,
    :completed_at_ms,
    events: [],
    summary: %{}
  ]

  @doc """
  Returns the canonical context key used to tag a tool invocation with
  the JidoClaw agent id. Tools propagate this on `tool_context` so the
  collector can attribute events to a particular agent when the raw
  telemetry omits it.
  """
  @spec agent_id_key() :: atom()
  def agent_id_key, do: @agent_id_key

  @doc """
  Emit a JidoClaw-native trace event.

  Stamps `:category` and `:source` into `metadata`, then routes through
  `Jido.Observe.emit_event/3` which merges any active
  `Jido.Tracing.Context` correlation IDs.

  Argument order matches Jidoka: `(category, metadata, measurements)`
  — opposite to `Jido.Observe.emit_event/3`, which is
  `(event_prefix, measurements, metadata)`. The wrapper translates.
  """
  @spec emit(atom(), map()) :: :ok
  @spec emit(atom(), map(), map()) :: :ok
  def emit(category, metadata, measurements \\ %{})

  def emit(category, metadata, measurements)
      when is_atom(category) and is_map(metadata) and is_map(measurements) do
    metadata =
      metadata
      |> Map.put_new(:category, category)
      |> Map.put_new(:source, :jido_claw)

    Jido.Observe.emit_event([:jido_claw, category, :event], measurements, metadata)
  end

  @doc """
  Returns the latest trace for a target.

  When `tenant_id:` is supplied, the candidate set is filtered to that
  tenant **before** picking the latest — a tenant-A query never falls
  through to a tenant-B trace. A mismatch returns `{:error, :not_found}`
  (same shape as "no trace"; this is intentional, to avoid leaking
  trace existence across tenants).
  """
  @spec latest(target(), keyword()) :: {:ok, t()} | {:error, term()}
  def latest(target, opts \\ []) do
    target
    |> target_ref()
    |> Collector.latest(opts)
    |> wrap_trace_result()
  end

  @doc """
  Returns the trace associated with `request_id`.

  Strict tenant filter as for `latest/2`. Falls back to Postgres
  (`trace_runs` + `trace_events`) when the in-memory ring no longer
  holds the trace.
  """
  @spec for_request(target(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_request(target, request_id, opts \\ []) when is_binary(request_id) do
    target
    |> target_ref()
    |> Collector.for_request(request_id, opts)
    |> wrap_trace_result()
    |> case do
      {:ok, _} = ok -> ok
      {:error, _} -> rehydrate_from_postgres(request_id, opts)
    end
  end

  @doc """
  Paginated read over `trace_runs` (durable history).

  Accepts the same shape as Ash keyset pagination: `page: [limit: 50]`.
  Use `tenant_id:` for a tenant-scoped read.
  """
  @spec history(keyword()) :: {:ok, [t()]} | {:error, term()}
  def history(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id)
    page = Keyword.get(opts, :page, limit: 50)
    ash_opts = if tenant_id, do: [tenant: tenant_id, page: page], else: [page: page]

    case TraceRun.recent(ash_opts) do
      {:ok, %Ash.Page.Keyset{results: runs}} -> {:ok, Enum.map(runs, &durable_run_to_trace/1)}
      {:ok, runs} when is_list(runs) -> {:ok, Enum.map(runs, &durable_run_to_trace/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists retained traces for a target.

  `target` is typically an `agent_id` or `{:tenant, tenant_id}`. When
  `tenant_id:` is supplied via `opts`, it overrides the target's
  tenant scope.
  """
  @spec list(target(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(target, opts \\ []) do
    target
    |> target_ref()
    |> Collector.list(opts)
    |> case do
      {:ok, traces} -> {:ok, Enum.map(traces, &wrap_trace/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns normalized events for a trace or trace target.
  """
  @spec events(t() | target(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def events(trace_or_target, opts \\ [])

  def events(%__MODULE__{} = trace, opts) do
    {:ok, maybe_limit(trace.events, Keyword.get(opts, :limit))}
  end

  def events(target, opts) do
    with {:ok, trace} <- latest(target, opts) do
      events(trace, opts)
    end
  end

  @doc """
  Derives coarse spans from a trace or trace target.

  Spans are bucketed by `(category, llm_call_id|tool_call_id|name)` so a
  multi-event LLM/tool/workflow shows up as a single row.
  """
  @spec spans(t() | target(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def spans(trace_or_target, opts \\ [])

  def spans(%__MODULE__{} = trace, opts) do
    spans =
      trace.events
      |> Enum.group_by(&span_key/1)
      |> Enum.map(fn {_key, events} -> build_span(events) end)
      |> Enum.sort_by(fn span -> span.started_at_ms || 0 end)
      |> maybe_limit(Keyword.get(opts, :limit))

    {:ok, spans}
  end

  def spans(target, opts) do
    with {:ok, trace} <- latest(target, opts) do
      spans(trace, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # target_ref/1 — extends Jidoka's resolver with {:request, _} and
  # {:tenant, _} forms. The new clauses sit BEFORE the generic pid/binary
  # handling so a tagged tuple is never misread as a JidoClaw agent id.
  # ---------------------------------------------------------------------------

  defp target_ref({:request, request_id}) when is_binary(request_id),
    do: %{request_id: request_id}

  defp target_ref({:tenant, tenant_id}) when is_binary(tenant_id),
    do: %{tenant_id: tenant_id}

  defp target_ref(%Jido.Agent{id: agent_id, state: state}) do
    %{
      agent_id: agent_id,
      request_id: Map.get(state || %{}, :last_request_id)
    }
  end

  defp target_ref(target) do
    case agent_server_state(target) do
      {:ok, %{agent: %Jido.Agent{id: agent_id, state: state}}} ->
        %{
          agent_id: agent_id,
          request_id: Map.get(state || %{}, :last_request_id)
        }

      _ ->
        if is_binary(target), do: %{agent_id: target}, else: %{}
    end
  end

  defp agent_server_state(target) do
    Jido.AgentServer.state(target)
  rescue
    _error -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp maybe_limit(values, limit), do: TraceLimit.take(values, limit)

  defp wrap_trace_result({:ok, trace}), do: {:ok, wrap_trace(trace)}
  defp wrap_trace_result({:error, reason}), do: {:error, reason}

  defp rehydrate_from_postgres(request_id, opts) do
    tenant_id = Keyword.get(opts, :tenant_id)
    ash_opts = if tenant_id, do: [tenant: tenant_id], else: []

    case TraceRun.by_request(request_id, ash_opts) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, run} ->
        case enforce_tenant_match(run, tenant_id) do
          :ok -> {:ok, rehydrate_trace(run, ash_opts)}
          :error -> {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp enforce_tenant_match(_run, nil), do: :ok
  defp enforce_tenant_match(%{tenant_id: tid}, tid), do: :ok
  defp enforce_tenant_match(_run, _tenant_id), do: :error

  defp rehydrate_trace(run, ash_opts) do
    events =
      case TraceEvent.for_trace(run.trace_id, ash_opts) do
        {:ok, rows} -> Enum.map(rows, &durable_event_to_struct/1)
        _ -> []
      end

    %__MODULE__{
      trace_id: run.trace_id,
      run_id: run.run_id,
      request_id: run.request_id,
      agent_id: run.agent_id,
      tenant_id: run.tenant_id,
      status: maybe_atom(run.status),
      started_at_ms: run.started_at_ms,
      completed_at_ms: run.completed_at_ms,
      events: events,
      summary: run.summary || %{}
    }
  end

  defp durable_run_to_trace(run) do
    %__MODULE__{
      trace_id: run.trace_id,
      run_id: run.run_id,
      request_id: run.request_id,
      agent_id: run.agent_id,
      tenant_id: run.tenant_id,
      status: maybe_atom(run.status),
      started_at_ms: run.started_at_ms,
      completed_at_ms: run.completed_at_ms,
      events: [],
      summary: run.summary || %{}
    }
  end

  defp durable_event_to_struct(row) do
    %Event{
      # NULL-coerce pre-migration rows so the rehydrated struct always
      # satisfies the `pos_integer()` type (never `nil`).
      schema_version: row.schema_version || 1,
      seq: row.seq,
      at_ms: row.at_ms,
      source: maybe_atom(row.source),
      category: maybe_atom(row.category),
      event: maybe_atom(row.event),
      phase: maybe_atom(row.phase),
      name: row.name,
      status: maybe_atom(row.status),
      duration_ms: row.duration_ms,
      request_id: row.request_id,
      run_id: row.run_id,
      trace_id: row.trace_id,
      span_id: row.span_id,
      parent_span_id: row.parent_span_id,
      measurements: row.measurements || %{},
      metadata: row.metadata || %{}
    }
  end

  defp maybe_atom(nil), do: nil
  defp maybe_atom(value) when is_atom(value), do: value

  defp maybe_atom(value) when is_binary(value) do
    # Persistence rows store atoms as strings. We use to_existing_atom
    # because the source/category/event/phase/status atoms are
    # referenced in code (event_shape/2, event_status/3, etc.) and
    # therefore always loaded by the time we rehydrate. Unknown atoms
    # fall back to the string so downstream callers can still see the
    # raw value.
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp wrap_trace(%__MODULE__{} = trace), do: trace

  defp wrap_trace(trace) when is_map(trace) do
    fields = [
      :trace_id,
      :run_id,
      :request_id,
      :agent_id,
      :tenant_id,
      :status,
      :started_at_ms,
      :completed_at_ms,
      :events,
      :summary
    ]

    struct(__MODULE__, Map.take(trace, fields))
  end

  defp span_key(%Event{} = event) do
    metadata = event.metadata || %{}

    id =
      metadata[:llm_call_id] ||
        metadata[:tool_call_id] ||
        metadata[:child_request_id] ||
        metadata[:conversation_id] ||
        event.name ||
        event.event

    {event.category, id}
  end

  defp build_span(events) do
    events = Enum.sort_by(events, & &1.seq)
    first = List.first(events)
    last = events |> Enum.reverse() |> List.first()

    %{
      source: first.source,
      category: first.category,
      name: first.name,
      status: span_status(events) || last.status,
      started_at_ms: first.at_ms,
      completed_at_ms: terminal_time(events),
      duration_ms: span_duration(events),
      request_id: first.request_id,
      run_id: first.run_id,
      trace_id: first.trace_id,
      event_count: length(events),
      events: Enum.map(events, & &1.event)
    }
  end

  defp span_status(events) do
    Enum.find_value(Enum.reverse(events), fn event ->
      if event.status in [:completed, :failed, :cancelled, :interrupted] do
        event.status
      end
    end)
  end

  defp terminal_time(events) do
    Enum.find_value(Enum.reverse(events), fn event ->
      if event.status in [:completed, :failed, :cancelled, :interrupted] do
        event.at_ms
      end
    end)
  end

  defp span_duration(events) do
    Enum.find_value(Enum.reverse(events), & &1.duration_ms) ||
      case {List.first(events), terminal_time(events)} do
        {%Event{at_ms: started_at}, completed_at}
        when is_integer(completed_at) and completed_at >= started_at ->
          completed_at - started_at

        _ ->
          nil
      end
  end
end
