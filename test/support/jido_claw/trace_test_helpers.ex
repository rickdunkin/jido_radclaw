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

  defp unique, do: System.unique_integer([:positive])
end
