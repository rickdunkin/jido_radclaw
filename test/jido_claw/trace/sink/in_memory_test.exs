defmodule JidoClaw.Trace.Sink.InMemoryTest do
  # Touches the supervised singleton sink — no concurrent access.
  use ExUnit.Case, async: false

  alias JidoClaw.Trace.Event
  alias JidoClaw.Trace.Sink
  alias JidoClaw.Trace.Sink.InMemory

  setup do
    :ok = InMemory.reset()
    on_exit(fn -> InMemory.reset() end)
    :ok
  end

  defp event(seq) do
    %Event{
      seq: seq,
      at_ms: seq,
      source: :jido_claw,
      category: :hook,
      event: :start,
      measurements: %{},
      metadata: %{}
    }
  end

  defp trace(trace_id), do: %JidoClaw.Trace{trace_id: trace_id}

  test "write/2 round-trips through all/0 (insertion order) and written/1 (per trace_id)" do
    :ok = InMemory.write(event(1), trace("t-1"))
    :ok = InMemory.write(event(2), trace("t-2"))
    :ok = InMemory.write(event(3), trace("t-1"))
    :ok = InMemory.sync()

    assert Enum.map(InMemory.all(), fn {e, _t} -> e.seq end) == [1, 2, 3]
    assert Enum.map(InMemory.written("t-1"), fn {e, _t} -> e.seq end) == [1, 3]
    assert Enum.map(InMemory.written("t-2"), fn {e, _t} -> e.seq end) == [2]
  end

  test "is bounded at max_entries — only the newest entries are retained" do
    :ok = InMemory.reset(max_entries: 3)

    for i <- 1..5, do: InMemory.write(event(i), trace("t"))
    :ok = InMemory.sync()

    # 5 written, cap 3 → the 3 newest (seqs 3,4,5) survive, oldest evicted.
    assert Enum.map(InMemory.all(), fn {e, _t} -> e.seq end) == [3, 4, 5]
  end

  test "reset/0 clears recorded entries" do
    :ok = InMemory.write(event(1), trace("t"))
    :ok = InMemory.sync()
    assert InMemory.all() != []

    :ok = InMemory.reset()
    assert InMemory.all() == []
  end

  test "both sinks export the write/2 callback" do
    assert Code.ensure_loaded?(Sink.Postgres) and function_exported?(Sink.Postgres, :write, 2)
    assert Code.ensure_loaded?(InMemory) and function_exported?(InMemory, :write, 2)
  end
end
