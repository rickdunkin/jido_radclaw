defmodule JidoClaw.Orchestration.WorkflowLease.Sidecar do
  @moduledoc """
  The per-run lease heartbeat — a `Task` (not a GenServer) started by
  `WorkflowLease.start_sidecar/4` under `LeaseTaskSupervisor`.

  `run/5` **registers, arms the monitor, then signals ready** (so "ready" means
  fully armed — no window where the executor dies before the `:DOWN` watch
  exists), then loops renewing the lease. The whole loop is wrapped so that
  **any unexpected death is fail-closed**: a bug or unhandled message kills the
  executor before the sidecar exits, so an *arbitrary* sidecar death — not only
  a renew failure — stops the now-unmonitored run.

  ## The loop

    * `{:DOWN, ref, …}` for the executor → stop (normal teardown).
    * `{:lease_tick, from}` (a test seam) → `renew/2`, reply `{:lease_ticked,
      result}`, then act on it.
    * `after renew_seconds` → `renew/2`, then act.

  `act/2` runs the pure `WorkflowLease.fence_decision/3`: `:renewed` loops
  (resetting the last-ok clock); `:kill` `Process.exit(executor, :kill)`s and
  stops; `{:retry, ms}` loops on a shorter timer **without** resetting last-ok,
  so a streak of transient DB errors still fails closed once the lease window
  elapses.

  ## Residual (accepted, WS1)

  An *untrappable* `Process.exit(sidecar, :kill)` skips the rescue and would
  leave the executor running unleased. Nothing issues such a kill except
  `LeaseTaskSupervisor` shutdown (where the executor is terminating too); a
  targeted external kill of a sidecar is a WS3 reclaim concern.
  """

  alias JidoClaw.Orchestration.WorkflowLease

  @registry JidoClaw.Orchestration.LeaseRegistry

  # Lease-handoff registration retry (WS2): the `:unique` `LeaseRegistry` frees a
  # key the instant the prior owner exits/unregisters, but on an ordinary
  # crash-restart with the SAME token the supervisor can restart the executor (and
  # this sidecar) before the prior sidecar has processed its `:DOWN` and
  # unregistered — so `Registry.register` transiently hits `:already_registered`.
  # Bounded-retry on that one error (~10 × 50 ms, well inside the 5 s readiness
  # deadline) before failing. Lives here, not in a caller busy-poll, because it is
  # the generic lease-handoff race the WS3 reclaim path hits too.
  @register_max_attempts 10
  @register_retry_ms 50

  @typep state :: %{
           executor: pid(),
           run_id: String.t(),
           tenant_id: term(),
           token: String.t(),
           ref: reference(),
           last_ok: integer()
         }

  @doc """
  The sidecar entrypoint. `caller_pid` awaits the readiness handshake;
  `executor_pid` is what the loop monitors and (on a fence) kills.
  """
  @spec run(pid(), pid(), String.t(), term(), String.t()) :: :ok | no_return()
  def run(caller_pid, executor_pid, run_id, tenant_id, token) do
    case register_with_retry(run_id, executor_pid, token, @register_max_attempts) do
      {:ok, _owner} ->
        # Arm the monitor BEFORE signalling ready — no miss-the-`:DOWN` window.
        ref = Process.monitor(executor_pid)
        send(caller_pid, {:lease_ready, run_id})

        state = %{
          executor: executor_pid,
          run_id: run_id,
          tenant_id: tenant_id,
          token: token,
          ref: ref,
          last_ok: monotonic_now()
        }

        guard(executor_pid, fn -> loop(state, renew_interval()) end)

      {:error, reason} ->
        # No ready signal → start_sidecar/4 surfaces `{:sidecar_down, _}`.
        exit({:lease_register_failed, reason})
    end
  end

  # Bounded-retry registration on the transient lease-handoff `:already_registered`
  # ONLY (the prior sidecar is mid-`:DOWN`), BEFORE the monitor-arm / ready
  # handshake so those invariants are untouched. Any other register error — or
  # `:already_registered` after the attempt budget is spent (a genuinely
  # pre-owned key) — fails immediately, exactly the pre-WS2 behavior.
  defp register_with_retry(run_id, executor_pid, token, attempts_left) do
    case Registry.register(@registry, run_id, %{executor: executor_pid, token: token}) do
      {:ok, _owner} = ok ->
        ok

      {:error, {:already_registered, _pid}} when attempts_left > 1 ->
        Process.sleep(@register_retry_ms)
        register_with_retry(run_id, executor_pid, token, attempts_left - 1)

      {:error, _reason} = error ->
        error
    end
  end

  # Any unexpected loop death (a bug, an unhandled message) kills the executor
  # before propagating — so arbitrary sidecar death is fail-closed, not just
  # renew failures. The rescue is DELIBERATELY bare: the fail-closed contract is
  # "any exception type means the heartbeat is gone, so the now-unmonitored
  # executor must die" — narrowing it would let an unforeseen exception class
  # leave a leased executor running unmonitored.
  defp guard(executor_pid, fun) do
    fun.()
  rescue
    # reach:disable-next-line bare_rescue
    error ->
      Process.exit(executor_pid, :kill)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      Process.exit(executor_pid, :kill)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec loop(state(), pos_integer()) :: :ok
  defp loop(%{ref: ref, executor: executor} = state, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^executor, _reason} ->
        :ok

      {:lease_tick, from} ->
        result = renew(state)
        send(from, {:lease_ticked, result})
        act(state, result)
    after
      timeout ->
        act(state, renew(state))
    end
  end

  defp act(state, result) do
    lease_ms = WorkflowLease.lease_seconds() * 1_000

    case WorkflowLease.fence_decision(result, monotonic_now() - state.last_ok, lease_ms) do
      :renewed ->
        loop(%{state | last_ok: monotonic_now()}, renew_interval())

      :kill ->
        Process.exit(state.executor, :kill)
        :ok

      {:retry, ms} ->
        # Shorter timer, last_ok deliberately NOT reset — a transient-error
        # streak still fails closed once the lease window elapses.
        loop(state, ms)
    end
  end

  defp renew(%{run_id: run_id, token: token}), do: WorkflowLease.renew(run_id, token)

  defp renew_interval, do: WorkflowLease.renew_seconds() * 1_000

  defp monotonic_now, do: System.monotonic_time(:millisecond)
end
