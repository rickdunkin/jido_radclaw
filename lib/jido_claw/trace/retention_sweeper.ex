defmodule JidoClaw.Trace.RetentionSweeper do
  @moduledoc """
  Periodic worker that deletes `trace_runs`/`trace_events` rows older
  than the configured retention window.

  Every event with `persist?: true` (the prod default) writes durable rows
  via `JidoClaw.Trace.Persistence`, and nothing else prunes them — without
  this worker the tables grow without bound. Hourly tick; each tick deletes
  at most one batch (1_000 runs + their events) via
  `TraceRun.sweep_expired/1`. Each batch runs as a single transaction
  (locked selection + both deletes); a failure rolls the whole batch back
  and waits for the next tick to retry. When a full batch was CLEANLY
  deleted the sweeper immediately reschedules to drain the backlog (`more?`
  is true only in that case — see `sweep_expired/1` — so a
  persistently-failing batch never hot-loops).

  Retention keys on `updated_at` (last activity), not `inserted_at`: the
  Persistence writer refreshes it on every event, so an old-but-active trace
  survives while a stale one ages out.

  Config: `config :jido_claw, trace: [retention_days: N]`, read at tick time
  so runtime flips take effect within an hour. A `nil` / non-integer /
  non-positive value disables sweeping (the tick no-ops and reschedules).

  ## Why a separate GenServer

  Same split as `RequestCorrelation.Sweeper`: bulk Postgres maintenance that
  may take seconds must not share a process with anything latency-sensitive,
  and a singleton under `InfraSupervisor` is restart-safe.
  """

  use GenServer
  require Logger

  alias JidoClaw.Trace.Resources.TraceRun

  @tick_ms :timer.hours(1)

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
    case sweep() do
      {:ok, _deleted, true} ->
        # Full batch cleanly deleted — there might be more. Don't wait for
        # the next tick.
        send(self(), :sweep)

      _ ->
        schedule_next()
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    case retention_days() do
      days when is_integer(days) and days > 0 ->
        TraceRun.sweep_expired(DateTime.add(DateTime.utc_now(), -days, :day))

      _disabled ->
        {:ok, 0, false}
    end

    # Background sweeper GenServer — any sweep failure must reschedule
    # cleanly so the next tick can retry. Crashing here would stall trace
    # retention entirely.
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[Trace.RetentionSweeper] sweep raised: #{Exception.message(e)}")
      {:ok, 0, false}
  catch
    kind, payload ->
      Logger.warning("[Trace.RetentionSweeper] sweep #{kind}: #{inspect(payload)}")
      {:ok, 0, false}
  end

  defp retention_days do
    Keyword.get(Application.get_env(:jido_claw, :trace, []), :retention_days)
  end

  defp schedule_next do
    Process.send_after(self(), :sweep, @tick_ms)
  end
end
