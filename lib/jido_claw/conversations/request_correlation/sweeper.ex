defmodule JidoClaw.Conversations.RequestCorrelation.Sweeper do
  @moduledoc """
  Periodic worker that deletes expired `RequestCorrelation` rows.

  Runs `RequestCorrelation.sweep_expired/0` every 60 seconds. The
  underlying read action (`:expired`) is bounded to 1_000 rows per
  tick (see `request_correlation.ex` `sweep_expired/0`); when the
  result indicates a full batch the sweeper immediately reschedules
  to drain the backlog rather than waiting for the next tick.

  ## Why a separate GenServer

  The Cache GenServer's job is fast in-memory mirror lookups; the
  Sweeper's job is bulk Postgres maintenance that may take seconds.
  Mixing them would block lookups during sweeps. The plan also names
  this as a separate process under `InfraSupervisor`.
  """

  use GenServer
  require Logger

  alias JidoClaw.Conversations.RequestCorrelation

  @tick_ms 60_000
  @full_batch 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep() do
      {:ok, count} when count >= @full_batch ->
        # Full batch — there might be more. Don't wait for the next tick.
        send(self(), :sweep)

      _ ->
        schedule_next()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    RequestCorrelation.sweep_expired()
  rescue
    e ->
      Logger.warning("[RequestCorrelation.Sweeper] sweep raised: #{Exception.message(e)}")
      {:ok, 0}
  catch
    kind, payload ->
      Logger.warning("[RequestCorrelation.Sweeper] sweep #{kind}: #{inspect(payload)}")
      {:ok, 0}
  end

  defp schedule_next do
    Process.send_after(self(), :sweep, @tick_ms)
  end
end
