defmodule JidoClaw.Trace.Sink.InMemory do
  @moduledoc """
  In-memory `JidoClaw.Trace.Sink` for tests.

  A singleton GenServer that records each `{event, trace}` write in a
  **bounded** flat list (newest-first; capped at `max_entries`, default
  #{10_000}). The cap matters because the process is unconditionally
  supervised and config-selectable — if it is ever selected in a
  long-running process the bound prevents unbounded growth.

  ## API

    * `write/2` — the `Sink` callback; an async cast (tests must drain it
      with the `:__sync__` barrier before asserting).
    * `all/0` — every recorded entry in insertion order.
    * `written/1` — recorded entries for one `trace_id`, in insertion order.
    * `reset/1` — clear state and reset the cap. `reset/0` restores the
      default cap; `reset(max_entries: n)` shrinks it for a bounded-eviction
      test directly on the supervised singleton (no second `start_link`).

  The write `handle_cast` is crash-proof: a pathological payload logs and
  is dropped rather than taking the singleton down.
  """

  use GenServer
  require Logger

  @behaviour JidoClaw.Trace.Sink

  alias JidoClaw.Trace.Event

  @default_max_entries 10_000

  @doc "Starts the in-memory trace sink."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl JidoClaw.Trace.Sink
  @spec write(Event.t(), JidoClaw.Trace.t()) :: :ok
  def write(%Event{} = event, %JidoClaw.Trace{} = trace) do
    GenServer.cast(__MODULE__, {:write, event, trace})
  end

  @doc "Returns every recorded `{event, trace}` entry in insertion order."
  @spec all() :: [{Event.t(), JidoClaw.Trace.t()}]
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Returns recorded entries for `trace_id`, in insertion order."
  @spec written(String.t()) :: [{Event.t(), JidoClaw.Trace.t()}]
  def written(trace_id) when is_binary(trace_id),
    do: GenServer.call(__MODULE__, {:written, trace_id})

  @doc """
  Clears recorded entries and resets the cap.

  `reset/0` restores the default cap; `reset(max_entries: n)` sets a new
  cap (used to drive bounded-eviction tests on the supervised singleton).
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []), do: GenServer.call(__MODULE__, {:reset, opts})

  @doc "Test-only sync barrier — drains prior `write/2` casts (FIFO)."
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :__sync__)

  @impl GenServer
  def init(opts), do: {:ok, %{entries: [], max: max_entries(opts)}}

  @impl GenServer
  def handle_call(:all, _from, state), do: {:reply, Enum.reverse(state.entries), state}

  def handle_call({:written, trace_id}, _from, state) do
    matching =
      state.entries
      |> Enum.reverse()
      |> Enum.filter(fn {_event, trace} -> trace.trace_id == trace_id end)

    {:reply, matching, state}
  end

  def handle_call({:reset, opts}, _from, state),
    do: {:reply, :ok, %{state | entries: [], max: max_entries(opts)}}

  def handle_call(:__sync__, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast({:write, event, trace}, state) do
    # Bounded, newest-first: single take-on-prepend (distinct from the
    # Collector's double-reverse bounded-take).
    {:noreply, %{state | entries: Enum.take([{event, trace} | state.entries], state.max)}}

    # an in-memory test sink must never crash on a pathological payload
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[Trace.Sink.InMemory] write raised: #{Exception.message(e)}")
      {:noreply, state}
  end

  defp max_entries(opts) do
    case Keyword.get(opts, :max_entries, @default_max_entries) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_entries
    end
  end
end
