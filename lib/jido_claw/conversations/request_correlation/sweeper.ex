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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # Leader-gate the periodic prune: the DELETE is idempotent on every node,
    # so the gate only cuts cross-node-redundant work. A follower skips the
    # prune and re-arms the normal next tick; failover is automatic.
    if JidoClaw.Cluster.leader?() do
      case sweep() do
        {:ok, count} when count >= @full_batch ->
          # Full batch — there might be more. Don't wait for the next tick.
          send(self(), :sweep)

        _ ->
          schedule_next()
      end
    else
      schedule_next()
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    RequestCorrelation.sweep_expired()
    # Background sweeper GenServer — any sweep failure must reschedule
    # cleanly so the next tick can drain. Crashing here would stall the
    # entire correlation expiry pipeline.
  rescue
    # reach:disable-next-line bare_rescue
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
