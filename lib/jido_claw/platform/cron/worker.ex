defmodule JidoClaw.Cron.Worker do
  @moduledoc """
  GenServer per scheduled job. Supports :at, :every, and :cron schedule types.
  Auto-disables after 3 consecutive failures. Stuck detection at 2 hours.
  """
  use GenServer
  require Logger

  @max_failures 3
  @stuck_threshold_ms 2 * 60 * 60 * 1000

  defstruct [
    :id,
    :tenant_id,
    :agent_id,
    :schedule,
    :task,
    :mode,
    status: :active,
    failure_count: 0,
    last_run: nil,
    last_result: nil,
    next_run: nil,
    created_at: nil
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def trigger(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.cast(name, :trigger)
  end

  def disable(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.cast(name, :disable)
  end

  def get_state(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.call(name, :get_state)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      agent_id: Keyword.get(opts, :agent_id, "main"),
      schedule: Keyword.fetch!(opts, :schedule),
      task: Keyword.fetch!(opts, :task),
      mode: Keyword.get(opts, :mode, :main),
      created_at: DateTime.utc_now()
    }

    state = schedule_next(state)
    {:ok, state}
  end

  @impl true
  def handle_cast(:trigger, state) do
    {:noreply, execute_job(state)}
  end

  def handle_cast(:disable, state) do
    Logger.info("[Cron] Disabled job #{state.id}")
    {:noreply, %{state | status: :disabled}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:tick, %{status: :active} = state) do
    state = execute_job(state)
    state = schedule_next(state)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    {:noreply, state}
  end

  def handle_info(:check_stuck, state) do
    if state.last_run && state.status == :running do
      elapsed = DateTime.diff(DateTime.utc_now(), state.last_run, :millisecond)

      if elapsed > @stuck_threshold_ms do
        Logger.warning("[Cron] Job #{state.id} appears stuck (#{elapsed}ms)")
        {:noreply, %{state | status: :stuck}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # -- Private --

  defp execute_job(state) do
    JidoClaw.Telemetry.emit_cron_start(%{job_id: state.id, tenant_id: state.tenant_id})
    start_time = System.monotonic_time()

    result =
      try do
        case state.mode do
          :main ->
            JidoClaw.chat(state.tenant_id, state.agent_id, state.task)

          :isolated ->
            session_id = "cron_#{state.id}_#{System.system_time(:second)}"
            JidoClaw.chat(state.tenant_id, session_id, state.task)
        end
      rescue
        e ->
          JidoClaw.Telemetry.emit_cron_exception(%{job_id: state.id}, :error)
          {:error, Exception.message(e)}
      end

    duration = System.monotonic_time() - start_time
    JidoClaw.Telemetry.emit_cron_stop(%{job_id: state.id, tenant_id: state.tenant_id}, duration)

    case result do
      {:ok, _} ->
        %{state | last_run: DateTime.utc_now(), last_result: :ok, failure_count: 0}

      {:error, reason} ->
        new_count = state.failure_count + 1

        Logger.warning(
          "[Cron] Job #{state.id} failed (#{new_count}/#{@max_failures}): #{inspect(reason)}"
        )

        new_status = if new_count >= @max_failures, do: :disabled, else: state.status

        if new_status == :disabled do
          Logger.error("[Cron] Job #{state.id} auto-disabled after #{@max_failures} failures")
        end

        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: {:error, reason},
            failure_count: new_count,
            status: new_status
        }
    end
  end

  defp schedule_next(%{schedule: {:at, %DateTime{} = dt}} = state) do
    delay = max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), :tick, delay)
    %{state | next_run: dt}
  end

  defp schedule_next(%{schedule: {:every, ms}} = state) when is_integer(ms) do
    Process.send_after(self(), :tick, ms)
    next = DateTime.add(DateTime.utc_now(), ms, :millisecond)
    %{state | next_run: next}
  end

  defp schedule_next(%{schedule: {:cron, expression}} = state) do
    case Crontab.CronExpression.Parser.parse(expression) do
      {:ok, cron} ->
        case Crontab.Scheduler.get_next_run_date(cron) do
          {:ok, next_dt} ->
            naive = next_dt
            dt = DateTime.from_naive!(naive, "Etc/UTC")
            delay = max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 1000)
            Process.send_after(self(), :tick, delay)
            %{state | next_run: dt}

          _ ->
            Logger.error("[Cron] Failed to compute next run for #{state.id}")
            state
        end

      {:error, reason} ->
        Logger.error("[Cron] Invalid cron expression for #{state.id}: #{inspect(reason)}")
        %{state | status: :disabled}
    end
  end

  defp schedule_next(state), do: state
end
