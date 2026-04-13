defmodule JidoClaw.Heartbeat do
  @moduledoc """
  Periodic heartbeat writer. Writes `.jido/heartbeat.md` every 60 seconds
  with agent status, uptime, stats, and system info.
  """

  use GenServer
  require Logger

  @interval_ms 60_000
  @filename "heartbeat.md"

  # -- Public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)

    state = %{
      project_dir: project_dir,
      started_at: DateTime.utc_now()
    }

    schedule_tick()
    {:ok, state, {:continue, :write}}
  end

  @impl true
  def handle_continue(:write, state) do
    write_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    write_heartbeat(state)
    schedule_tick()
    {:noreply, state}
  end

  # -- Private --

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval_ms)
  end

  defp write_heartbeat(state) do
    path = Path.join([state.project_dir, ".jido", @filename])
    now = DateTime.utc_now()
    uptime_secs = DateTime.diff(now, state.started_at)

    stats =
      try do
        JidoClaw.Stats.get()
      rescue
        e in [RuntimeError, ErlangError, ArgumentError] ->
          Logger.debug("[Heartbeat] Stats unavailable: #{Exception.message(e)}")
          %{messages: 0, tokens: 0, tool_calls: 0, agents_spawned: 0}
      end

    cron_count =
      try do
        length(JidoClaw.Cron.Scheduler.list_jobs("default"))
      rescue
        e in [RuntimeError, ErlangError, ArgumentError] ->
          Logger.debug("[Heartbeat] Cron count unavailable: #{Exception.message(e)}")
          0
      end

    memory_mb = div(:erlang.memory(:total), 1_048_576)
    process_count = :erlang.system_info(:process_count)

    content = """
    # JidoClaw Heartbeat

    **Status:** alive
    **Timestamp:** #{DateTime.to_iso8601(now)}
    **Uptime:** #{format_uptime(uptime_secs)}

    ## Session Stats
    - **Messages:** #{stats.messages}
    - **Tool calls:** #{stats.tool_calls}
    - **Tokens used:** #{stats.tokens}
    - **Agents spawned:** #{stats.agents_spawned}

    ## Cron
    - **Active jobs:** #{cron_count}

    ## System
    - **Memory:** #{memory_mb} MB
    - **BEAM processes:** #{process_count}
    - **OTP:** #{:erlang.system_info(:otp_release)}
    - **Elixir:** #{System.version()}
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  rescue
    e ->
      Logger.warning("[Heartbeat] Failed to write: #{Exception.message(e)}")
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_uptime(seconds) when seconds < 3600 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end

  defp format_uptime(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    "#{h}h #{m}m #{s}s"
  end
end
