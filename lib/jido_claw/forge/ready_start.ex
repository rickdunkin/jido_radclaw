defmodule JidoClaw.Forge.ReadyStart do
  @moduledoc false
  # AR-8b-2 F2 (1.2): the race-safe combined `subscribe → start_session →
  # await-ready → status-assert` entrypoint behind `Forge.start_session_ready/3`.
  #
  # Modelled on `JidoClaw.Memory.Consolidator.RunServer.drive_harness/4` +
  # `await_ready/3`: subscribe to `Forge.PubSub` BEFORE `Manager.start_session`
  # (so the `{:ready, session_id}` broadcast can't be missed in the same scheduler
  # quantum), run the wait inside a short-lived `Task.Supervisor.async_nolink`
  # task (a helper crash can't take down the long-lived caller), and MONITOR the
  # started pid so a `{:DOWN, …, {:runner_init_failed, _}}`/provision crash
  # returns immediately rather than on timeout.
  #
  # Three F2 differences from `run_server` (all load-bearing):
  #
  #   1. Leave the session ALIVE on success (the front door uses it). The task
  #      self-stops only on its FAILURE paths.
  #   2. The CALLER mints + owns the `session_id` and passes it in (it is the
  #      `forge_session_key`, D5). The parent-side `Task.yield`/`Task.shutdown`
  #      backstop is sized LONGER than the task's internal await, so the task
  #      normally self-resolves first; on any abandon the caller issues an
  #      UNCONDITIONAL `Forge.stop_session/2` — `Manager` serializes start/stop
  #      through one GenServer, so a stop enqueued after a mid-flight start still
  #      finds + terminates the child (closes the orphan window).
  #   3. Ready AND usable: after the `:ready` broadcast, a `Forge.status/1` check
  #      asserts the SAME four conditions as
  #      `AgentRunner.validate_sandbox_scope(:docker)` (backend ==
  #      `expected_backend`, `state: :ready`, `sandbox_status: :ready`, `:default
  #      in sandboxes`). A `{:ready, …}` broadcast alone does NOT guarantee the
  #      `:default` sandbox is provisioned, so a miss is treated as a launch
  #      failure (→ degrade) — the session is guaranteed-usable by the bridge
  #      before the composer is seeded (closes D7 Window 2).

  alias JidoClaw.Forge
  alias JidoClaw.Forge.Manager
  alias JidoClaw.Forge.PubSub

  # Matches `run_server`'s `bootstrap_timeout/1`. Tunable: too short spuriously
  # degrades, too long stalls the ack.
  @default_await_timeout_ms 60_000

  # The parent-side backstop sits THIS much beyond the task's internal await, so
  # the task normally self-resolves (success or self-cleaned failure) before the
  # parent would ever `Task.shutdown` it.
  @parent_backstop_ms 5_000

  # Production always asserts the real Docker backend; a `StubSandbox`-backed test
  # session passes `expected_backend: StubSandbox` to exercise the full
  # subscribe→start→await→status-assert path without a Docker daemon.
  @default_expected_backend JidoClaw.Forge.Sandbox.Docker

  @doc """
  Start `session_id` with `spec` and return only once the session is `:ready`
  AND usable, or on a bounded failure. Returns `{:ok, session_id}` (session left
  alive) | `{:error, reason}` (any partial session torn down).

  Options:
    * `:await_timeout_ms` (default `#{@default_await_timeout_ms}`)
    * `:expected_backend` (default `#{inspect(@default_expected_backend)}`) — the
      backend module the post-ready status check asserts.
  """
  @spec start(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(session_id, spec, opts \\ []) when is_binary(session_id) and is_map(spec) do
    await_timeout = Keyword.get(opts, :await_timeout_ms, @default_await_timeout_ms)
    expected_backend = Keyword.get(opts, :expected_backend, @default_expected_backend)

    task =
      Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, fn ->
        drive(session_id, spec, await_timeout, expected_backend)
      end)

    case Task.yield(task, await_timeout + @parent_backstop_ms) || Task.shutdown(task) do
      {:ok, {:ok, ^session_id}} ->
        {:ok, session_id}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        # The task crashed (async_nolink): unconditionally stop, the started
        # session must never outlive a failed call.
        unconditional_stop(session_id)
        {:error, {:ready_start_crashed, reason}}

      nil ->
        # The parent backstop fired with the task still wedged mid-flight: kill it
        # and unconditionally stop — `Manager` serializes the stop after any
        # in-flight start finishes registering.
        unconditional_stop(session_id)
        {:error, :ready_start_abandoned}
    end
  end

  defp drive(session_id, spec, await_timeout, expected_backend) do
    :ok = PubSub.subscribe(session_id)

    try do
      case Manager.start_session(session_id, spec) do
        {:ok, %{pid: pid}} ->
          drive_started(session_id, pid, await_timeout, expected_backend)

        {:error, reason} ->
          # Start failed: nothing registered, but a stop is a harmless no-op and
          # closes the "registers just after the failure" window.
          unconditional_stop(session_id)
          {:error, reason}
      end
    after
      PubSub.unsubscribe(session_id)
    end
  end

  defp drive_started(session_id, pid, await_timeout, expected_backend) do
    case await_ready(session_id, pid, await_timeout) do
      :ok -> assert_usable(session_id, expected_backend)
      {:error, reason} -> stop_and_error(session_id, reason)
    end
  end

  # After the `:ready` broadcast, confirm the session is USABLE by the bridge
  # (D7 Window 2): a deferred-sandbox session can broadcast `:ready` with no
  # `:default` sandbox provisioned. A miss is a launch failure → degrade.
  defp assert_usable(session_id, expected_backend) do
    case Forge.status(session_id) do
      {:ok, status} ->
        case usable_status(status, expected_backend) do
          :ok -> {:ok, session_id}
          {:error, reason} -> stop_and_error(session_id, reason)
        end

      {:error, reason} ->
        stop_and_error(session_id, {:status_unavailable, reason})
    end
  end

  defp usable_status(
         %{
           sandbox_module: backend,
           state: :ready,
           sandbox_status: :ready,
           sandboxes: sandboxes
         },
         backend
       ) do
    if :default in sandboxes, do: :ok, else: {:error, :sandbox_not_provisioned}
  end

  defp usable_status(%{sandbox_module: backend}, expected) when backend != expected,
    do: {:error, {:wrong_backend, backend}}

  defp usable_status(_status, _expected), do: {:error, :session_not_ready}

  # Mirrors `run_server`'s `await_ready/3`: monitor the started pid so a
  # provision/runner-init crash returns immediately (not on timeout).
  defp await_ready(session_id, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:ready, ^session_id} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, {:runner_init_failed, reason}} ->
        {:error, {:runner_init_failed, reason}}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:harness_down, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :await_ready_timeout}
    end
  end

  defp stop_and_error(session_id, reason) do
    unconditional_stop(session_id)
    {:error, reason}
  end

  defp unconditional_stop(session_id) do
    Forge.stop_session(session_id)
    :ok
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
