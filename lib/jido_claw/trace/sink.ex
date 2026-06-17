defmodule JidoClaw.Trace.Sink do
  @moduledoc """
  Behaviour for the durable-write target of `JidoClaw.Trace.Collector`.

  The Collector holds an `(event, trace_snapshot)` pair at its persist
  point; a sink's single `write/2` callback mirrors exactly that pair, so
  swapping the sink needs no new shape and no rewrite of the careful
  `JidoClaw.Trace.Persistence` logic.

  Implementations:

    * `JidoClaw.Trace.Sink.Postgres` (default) — delegates to
      `JidoClaw.Trace.Persistence.append/2`, preserving every existing
      durability guarantee (sync/async, out-of-order `last_seq` guard,
      crash-proof writes).
    * `JidoClaw.Trace.Sink.InMemory` (tests) — records writes in a bounded
      in-process list for assertions.

  The sink is selected via `config :jido_claw, :trace, sink:` and resolved
  once at Collector init (`Collector.resolve_sink/1` falls back to Postgres
  on a bad value), so `write/2` must be safe to call on every ingested,
  non-sampled-out event.
  """

  @doc """
  Durably record one trace event against its trace snapshot.

  Called by the Collector for every ingested event when `persist?` is
  true. Returns `:ok`; an implementation must not raise (the Collector
  does not guard the call).
  """
  @callback write(JidoClaw.Trace.Event.t(), JidoClaw.Trace.t()) :: :ok
end
