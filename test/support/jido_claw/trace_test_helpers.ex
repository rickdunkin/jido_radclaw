defmodule JidoClaw.TraceTestHelpers do
  @moduledoc """
  Test helpers for `JidoClaw.Trace` and its collaborators.

  The Collector ingests telemetry via `handle_info/2`, so an emit
  followed by an assertion can race the GenServer mailbox unless the
  test drains it. `sync_collector/0` and `sync_persistence/0` are
  `GenServer.call/2` barriers — by the time they return, every prior
  `{:telemetry_event, ...}` cast has been processed (FIFO mailbox).

  All trace tests are `async: false` because the Collector is a
  process-global singleton — concurrent tests would see each other's
  events.
  """

  @doc """
  Emit a `[:jido, :ai, :request, :start]` event with the given
  metadata. Falls back to a generated `agent_id` and `request_id` so
  callers can pass `%{}` for a quick smoke event.
  """
  @spec emit_request_start(map()) :: :ok
  def emit_request_start(metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put_new(:agent_id, "trace-helper-#{unique()}")
      |> Map.put_new(:request_id, "req-#{unique()}")

    :telemetry.execute([:jido, :ai, :request, :start], %{}, metadata)
    :ok
  end

  @doc """
  Emit a `[:jido, :ai, :tool, :complete]` event for a named tool.
  """
  @spec emit_tool_complete(map()) :: :ok
  def emit_tool_complete(metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put_new(:tool_name, "noop_tool")
      |> Map.put_new(:request_id, "req-#{unique()}")
      |> Map.put_new(:tool_call_id, "tool-#{unique()}")

    :telemetry.execute([:jido, :ai, :tool, :complete], %{duration_ms: 1}, metadata)
    :ok
  end

  @doc """
  Drain the Collector's telemetry mailbox. Returns `:ok` after every
  prior `:telemetry_event` cast has been handled.
  """
  @spec sync_collector() :: :ok
  def sync_collector do
    GenServer.call(JidoClaw.Trace.Collector, :__sync__)
  end

  @doc """
  Drain the Persistence mailbox. Returns `:ok` after every prior
  `{:append, ...}` cast has been handled.
  """
  @spec sync_persistence() :: :ok
  def sync_persistence do
    GenServer.call(JidoClaw.Trace.Persistence, :__sync__)
  end

  @doc """
  Drain the InMemory sink's mailbox. Returns `:ok` after every prior
  `{:write, ...}` cast has been handled. The collector barrier alone is
  not enough when `sink: Trace.Sink.InMemory` — its `write/2` is an async
  cast one hop past the collector.
  """
  @spec sync_sink() :: :ok
  def sync_sink do
    GenServer.call(JidoClaw.Trace.Sink.InMemory, :__sync__)
  end

  @doc """
  Drain the global Collector, then the Persistence writer.

  Call this in a shared-sandbox trace test's `on_exit` **before**
  `Ecto.Adapters.SQL.Sandbox.stop_owner/1`. The Collector is a process-
  global singleton that borrows the shared sandbox connection for its
  best-effort durable tenant lookup (`durable_tenant/1` →
  `RequestCorrelation.lookup/1`) during ingest. A test that emits
  Collector-ingested telemetry without its own `sync_collector/0` (e.g. an
  emit-and-`assert_receive` reasoning test) leaves that lookup query in
  flight; stopping the owner then races it and logs a "still using a
  connection from owner" warning. Draining the Collector first guarantees
  it is idle, and draining Persistence flushes any sink write it queued.
  """
  @spec drain_trace_processes() :: :ok
  def drain_trace_processes do
    _ = sync_collector()
    _ = sync_persistence()
    :ok
  end

  defp unique, do: System.unique_integer([:positive])
end
