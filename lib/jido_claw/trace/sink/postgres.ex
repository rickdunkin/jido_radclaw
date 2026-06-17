defmodule JidoClaw.Trace.Sink.Postgres do
  @moduledoc """
  Default `JidoClaw.Trace.Sink` — durable Postgres writes via
  `JidoClaw.Trace.Persistence`.

  This adapter is intentionally a one-line delegate: it owns no process
  and rides the already-supervised `Persistence` GenServer, so the default
  trace-persistence path is byte-for-byte unchanged from before the
  sink abstraction existed. All of Persistence's guarantees (sync/async
  mode, FIFO ordering, the `last_seq` out-of-order upsert guard, the
  atom→string boundary, the crash-proof rescue) apply unchanged.
  """

  @behaviour JidoClaw.Trace.Sink

  alias JidoClaw.Trace.Event
  alias JidoClaw.Trace.Persistence

  @impl JidoClaw.Trace.Sink
  @spec write(Event.t(), JidoClaw.Trace.t()) :: :ok
  def write(%Event{} = event, %JidoClaw.Trace{} = trace), do: Persistence.append(event, trace)
end
