defmodule JidoClaw.Trace.Persistence do
  @moduledoc """
  Serialized async writer for `trace_runs` + `trace_events`.

  The Collector casts `{:append, event, trace_snapshot}` here on every
  event. A singleton GenServer with FIFO mailbox ordering guarantees
  that earlier-seq writes for the same `trace_id` commit before later
  ones — under burst load they queue against a single mailbox, but
  ordering is preserved.

  The `last_seq` column on `trace_runs` plus the `upsert_condition`
  guard makes the contract robust even if a future change shards
  Persistence by `trace_id`: an older snapshot whose `last_seq` is
  smaller than the persisted row's `last_seq` becomes a
  `:skipped_upsert` no-op rather than overwriting a newer terminal
  state.

  ## Synchronous mode (tests)

  Set `config :jido_claw, :trace, persist_sync?: true` to swap the
  cast for a call — the writer blocks the caller until the row hits
  Postgres. Required by `JidoClaw.Trace.Persistence`-touching tests
  that assert on row contents immediately after the emit.

  ## Atom values at the persistence boundary

  `%JidoClaw.Trace.Event{}` keeps atoms for `:source`, `:category`,
  `:event`, `:phase`, `:status`. They're converted to strings here
  via `Atom.to_string/1` so the columns can hold values from future
  trace categories without a migration.
  """

  use GenServer
  require Logger

  alias JidoClaw.Trace.{Event, Resources.TraceEvent, Resources.TraceRun}

  @doc "Starts the trace persistence writer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persist an event + trace snapshot.

  In the default async mode the call returns `:ok` immediately and the
  write runs on the Persistence GenServer. With
  `persist_sync?: true` configured, the call blocks until the write
  commits — used by tests.

  Defensive: if the Persistence process is not yet (or no longer)
  registered we drop the event with a debug log. The in-memory ring
  is unaffected, so this only loses the durable copy of an in-flight
  emission during a restart window.
  """
  @spec append(Event.t(), JidoClaw.Trace.t()) :: :ok
  def append(%Event{} = event, %JidoClaw.Trace{} = trace) do
    if persist_sync?() do
      case Process.whereis(__MODULE__) do
        nil ->
          Logger.debug("[Trace.Persistence] sync append dropped — process not registered")
          :ok

        _pid ->
          GenServer.call(__MODULE__, {:append, event, trace})
      end
    else
      case Process.whereis(__MODULE__) do
        nil ->
          Logger.debug("[Trace.Persistence] async append dropped — process not registered")
          :ok

        _pid ->
          GenServer.cast(__MODULE__, {:append, event, trace})
      end
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:append, event, trace}, _from, state) do
    do_persist(event, trace)
    {:reply, :ok, state}
  end

  # Test-only mailbox sync barrier.
  def handle_call(:__sync__, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:append, event, trace}, state) do
    do_persist(event, trace)
    {:noreply, state}
  end

  defp do_persist(%Event{} = event, %JidoClaw.Trace{} = trace) do
    case TraceRun.upsert_run(run_attrs(event, trace), tenant: trace.tenant_id) do
      {:ok, _} ->
        persist_event(event, trace)

      {:error, reason} ->
        Logger.warning("[Trace.Persistence] run upsert failed: #{inspect(reason)}")
    end

    # trace persistence write must never crash the serialized writer GenServer
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[Trace.Persistence] persistence raised: #{Exception.message(e)}")
  end

  defp persist_event(%Event{} = event, %JidoClaw.Trace{} = trace) do
    case TraceEvent.append_event(event_attrs(event, trace), tenant: trace.tenant_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Trace.Persistence] event append failed: #{inspect(reason)}")
    end
  end

  defp run_attrs(%Event{seq: seq}, %JidoClaw.Trace{} = trace) do
    %{
      trace_id: trace.trace_id,
      tenant_id: trace.tenant_id,
      request_id: trace.request_id,
      run_id: trace.run_id,
      agent_id: maybe_string(trace.agent_id),
      status: maybe_string(trace.status),
      started_at_ms: trace.started_at_ms,
      completed_at_ms: trace.completed_at_ms,
      summary: trace.summary || %{},
      incoming_last_seq: seq
    }
  end

  defp event_attrs(%Event{} = event, %JidoClaw.Trace{} = trace) do
    %{
      tenant_id: trace.tenant_id,
      trace_id: event.trace_id,
      seq: event.seq,
      at_ms: event.at_ms,
      schema_version: event.schema_version || Event.schema_version(),
      source: Atom.to_string(event.source),
      category: Atom.to_string(event.category),
      event: Atom.to_string(event.event),
      phase: maybe_string(event.phase),
      name: event.name,
      status: maybe_string(event.status),
      duration_ms: event.duration_ms,
      request_id: event.request_id,
      run_id: event.run_id,
      span_id: event.span_id,
      parent_span_id: event.parent_span_id,
      measurements: event.measurements || %{},
      metadata: event.metadata || %{}
    }
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_string(value) when is_binary(value), do: value
  defp maybe_string(value), do: to_string(value)

  defp persist_sync? do
    Application.get_env(:jido_claw, :trace, [])
    |> Keyword.get(:persist_sync?, false)
  end
end
