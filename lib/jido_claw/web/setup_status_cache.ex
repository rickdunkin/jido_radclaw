defmodule JidoClaw.Web.SetupStatusCache do
  @moduledoc """
  Coalesces and caches the setup wizard's subprocess/network/database probes.

  Probes run outside this GenServer under `JidoClaw.TaskSupervisor`, so one
  slow diagnostic never blocks cache control messages or serializes callers
  behind an unbounded `handle_call/3`. All callers waiting on the same stale
  value share one probe. A hard deadline returns the last known good result
  when one exists, otherwise an explicit error; the timed-out task is stopped
  and the cache remains responsive.
  """

  use GenServer

  require Logger

  @default_ttl_ms 60_000
  @default_min_refresh_ms 10_000
  @default_probe_timeout_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch, do: GenServer.call(__MODULE__, :fetch, call_timeout())

  @spec refresh() :: {:ok, map()} | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :refresh, call_timeout())

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       status: nil,
       checked_at: nil,
       last_attempt_at: nil,
       last_error: nil,
       probe: nil,
       waiters: []
     }}
  end

  @impl GenServer
  def handle_call(request, from, %{probe: probe} = state)
      when request in [:fetch, :refresh] and not is_nil(probe) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(request, from, state) when request in [:fetch, :refresh] do
    now = System.monotonic_time(:millisecond)
    max_age = request_max_age(request)

    cond do
      cached_for?(state, now, max_age) ->
        {:reply, {:ok, state.status}, state}

      recent_attempt?(state, now) ->
        {:reply, fallback(state), state}

      true ->
        begin_probe(state, from, now)
    end
  end

  def handle_call(:reset, _from, state) do
    state = cancel_probe(state, :reset)
    {:reply, :ok, %{state | status: nil, checked_at: nil, last_attempt_at: nil, last_error: nil}}
  end

  @impl GenServer
  def handle_info({ref, result}, %{probe: %{task: %Task{ref: ref}} = probe} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(probe.timer)
    {:noreply, finish_probe(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{probe: %{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, finish_probe(state, {:error, {:probe_exit, reason}})}
  end

  def handle_info({:probe_timeout, ref}, %{probe: %{task: %Task{ref: ref}} = probe} = state) do
    _ = Task.shutdown(probe.task, :brutal_kill)
    {:noreply, finish_probe(state, {:error, :probe_timeout})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp begin_probe(state, from, now) do
    timeout_ms = config(:probe_timeout_ms, @default_probe_timeout_ms)
    task = Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, &run_probe/0)
    timer = Process.send_after(self(), {:probe_timeout, task.ref}, timeout_ms)

    {:noreply,
     %{
       state
       | probe: %{task: task, timer: timer},
         waiters: [from],
         last_attempt_at: now
     }}
  end

  defp run_probe do
    case wizard_impl().run() do
      status when is_map(status) -> {:ok, status}
      other -> {:error, {:invalid_probe_result, other}}
    end
  end

  defp finish_probe(state, {:ok, status}) when is_map(status) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, status}))

    %{
      state
      | status: status,
        checked_at: System.monotonic_time(:millisecond),
        last_error: nil,
        probe: nil,
        waiters: []
    }
  end

  defp finish_probe(state, {:error, reason}) do
    Logger.warning("[SetupStatusCache] setup probe failed: #{inspect(reason)}")
    failed = %{state | last_error: reason, probe: nil, waiters: []}
    reply = fallback(failed)
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    failed
  end

  defp finish_probe(state, other),
    do: finish_probe(state, {:error, {:invalid_task_result, other}})

  defp cancel_probe(%{probe: nil} = state, _reason), do: state

  defp cancel_probe(%{probe: probe} = state, reason) do
    cancel_timer(probe.timer)
    _ = Task.shutdown(probe.task, :brutal_kill)
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
    %{state | probe: nil, waiters: []}
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp cached_for?(%{status: nil}, _now, _max_age), do: false

  defp cached_for?(%{checked_at: checked_at}, now, max_age) when is_integer(checked_at),
    do: now - checked_at < max_age

  defp cached_for?(_state, _now, _max_age), do: false

  defp recent_attempt?(%{last_attempt_at: nil}, _now), do: false

  defp recent_attempt?(%{last_attempt_at: attempted_at}, now),
    do: now - attempted_at < config(:min_refresh_ms, @default_min_refresh_ms)

  defp fallback(%{status: status}) when is_map(status), do: {:ok, status}
  defp fallback(%{last_error: nil}), do: {:error, :setup_status_unavailable}
  defp fallback(%{last_error: reason}), do: {:error, reason}

  defp request_max_age(:fetch), do: config(:ttl_ms, @default_ttl_ms)
  defp request_max_age(:refresh), do: config(:min_refresh_ms, @default_min_refresh_ms)

  defp call_timeout do
    config(:probe_timeout_ms, @default_probe_timeout_ms) + 2_000
  end

  defp config(key, default) do
    value =
      :jido_claw
      |> Application.get_env(:setup_status_cache, [])
      |> Keyword.get(key, default)

    if is_integer(value) and value > 0, do: value, else: default
  end

  defp wizard_impl,
    do: Application.get_env(:jido_claw, :setup_wizard_impl, JidoClaw.Setup.Wizard)
end
