defmodule JidoClaw.Orchestration.RunExecution do
  @moduledoc """
  The single killable-execution seam: every `Reactor.run/4` under the
  `WorkflowRun` envelope goes through `run_killable/4`, which executes the
  reactor inside a registered `Task` so `JidoClaw.Orchestration.Cancellation`
  can find the executor pid (`lookup/1`) and `Process.exit(pid, :kill)` it.
  Both execution chokepoints — `ReactorRunner.execute` (fresh launches,
  including `Replay`) and `GateResume.run_reactor` (operator approve and boot
  recovery) — use it, so every live run is killable.

  The caller blocks on `Task.yield(task, yield_timeout)` (default `:infinity`),
  so the public API stays synchronous and never raises: a normal return
  surfaces as `{:reactor, result}`, a killed/crashed executor as
  `{:exit, reason}`, and a registration conflict as `{:duplicate, pid}`. A
  bounded `:yield_timeout` (AR-2 Phase 2b, per-wave) that elapses kills the
  executor (`Task.shutdown/2`) and surfaces `{:exit, :timeout}` — unless the
  task completes in the yield→kill gap, in which case the real result wins.

  ## Registration

  The task registers itself in `JidoClaw.Orchestration.RunRegistry` (unique
  key: the run-id string; value: the tenant id, checked by `Cancellation`
  before killing) **before** calling `Reactor.run`, so an immediate cancel
  finds the pid. The Registry auto-cleans the entry when the task dies.

  A `{:error, {:already_registered, pid}}` means a live executor already owns
  this run id — the task returns a conflict sentinel **without running the
  reactor** (never a second, unkillable executor for the same run). Fresh
  launches can't realistically collide (every launch creates a run with a
  fresh uuid); the guard exists for resume races on the *same* run id, e.g.
  an operator approve racing boot recovery.

  ## Cancel-before-register race

  Cancellation is durable-decision-first: `run_cancelled` is appended before
  any kill. If the cancel lands before the executor task registers, the kill
  is skipped (`lookup/1` misses) but the late task's `run_started` append is
  an illegal transition from `:cancelled`, so `Reactor.run` returns
  `{:error, _}` before any reactor work runs — the durable decision wins
  against registration timing. The resume leg works the same way: the late
  task's `run_resumed` append fails and `ReactorMiddleware` hard-stops on the
  terminal reload before any downstream step.

  ## Orphaned async work (accepted limitation)

  Reactor schedules async steps via `Task.Supervisor.async_nolink` against a
  global PartitionSupervisor keyed on the executor pid, so killing the
  executor orphans **already-started** async-step work — a spawned sub-agent,
  shell command, or external side effect may run to completion into the void.
  Nothing *new* schedules after the kill. Killing the executor is a kill
  switch for the workflow, not a guaranteed interrupt of every side effect.

  ## Caller-death semantics (deliberate)

  The executor task is `async_nolink`, so it survives the death of the
  process blocked in `Task.yield` — in-flight work now finishes durably
  instead of dying with its caller (a feature for cron). Durable terminals
  still land via `ReactorMiddleware` regardless. What a dead caller skips is
  caller-side finalize bookkeeping: gate-checkpoint persistence (the run
  parks `:awaiting_approval` with no checkpoint → recovery's dangling-gate
  branch reaps it at next boot) and the pre-init `:pending` backstop (→
  recovery's stranded branch) — the same recovery classes that covered caller
  death before this seam existed. No owner-monitor.
  """

  require Logger

  @registry JidoClaw.Orchestration.RunRegistry
  @task_supervisor JidoClaw.Orchestration.RunTaskSupervisor

  # Internal marker the task returns instead of running a second executor for
  # an already-registered run id. Distinguishable from every Reactor.run
  # return shape ({:ok, _} / {:error, _} / {:halted, _}).
  @registration_conflict :__registration_conflict__

  @doc """
  Run `runnable` (a reactor module or `%Reactor{}` struct) inside a
  registered, killable task and block until it finishes or dies.

  `opts` must carry `:run_id` (the registry key, passed through to
  `Reactor.run`) and may carry `:tenant_id` — which is popped off here as
  RunExecution-local registry metadata and **never** reaches `Reactor.run`:
  the executor's state is `struct!/2`-strict on option keys
  (`deps/reactor/lib/reactor/executor/state.ex:68`) and an unknown key would
  raise. All remaining opts (`:async?`, `:timeout`, `:max_iterations`, …)
  pass verbatim.

  Returns:

    * `{:reactor, result}` — `Reactor.run/4`'s own return value.
    * `{:exit, reason}` — the executor died (a cancel kill, or a raise inside
      the reactor surfacing as `{exception, stacktrace}`).
    * `{:duplicate, pid}` — a live executor already owns this run id; the
      reactor was **not** run.
  """
  @spec run_killable(Reactor.t() | module(), map(), map(), keyword()) ::
          {:reactor, term()} | {:exit, term()} | {:duplicate, pid()}
  def run_killable(runnable, inputs, context, opts) do
    {tenant_id, opts} = Keyword.pop(opts, :tenant_id)
    # `:yield_timeout` is RunExecution-local (the per-wave kill deadline, AR-2
    # Phase 2b C3) — popped here so it never reaches Reactor.run (struct!-strict
    # on opt keys). Default `:infinity` ⇒ byte-identical to every prior caller.
    {yield_timeout, reactor_opts} = Keyword.pop(opts, :yield_timeout, :infinity)
    run_id = Keyword.fetch!(reactor_opts, :run_id)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        # Register BEFORE Reactor.run so an immediate cancel finds the pid;
        # the Registry drops the entry automatically when this task dies.
        case Registry.register(@registry, to_string(run_id), tenant_id) do
          {:ok, _owner} ->
            Reactor.run(runnable, inputs, context, reactor_opts)

          {:error, {:already_registered, pid}} ->
            {@registration_conflict, pid}
        end
      end)

    # Bounded yield + shutdown (`yield_timeout: :infinity` ⇒ `Task.yield` never
    # returns nil, so `Task.shutdown` is never reached — unchanged for every
    # existing caller). `$callers` propagation from async_nolink keeps Ecto
    # sandbox allowances working in tests.
    case Task.yield(task, yield_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {@registration_conflict, pid}} -> {:duplicate, pid}
      # Completed — via `yield` OR the shutdown race (the task finished between
      # the yield deadline and the kill). A wave whose child run actually
      # completed must fold as completed, never as a false timeout (P1-3).
      {:ok, result} -> {:reactor, result}
      {:exit, reason} -> {:exit, reason}
      # Genuinely killed at the deadline — `Task.shutdown` returned nil.
      nil -> {:exit, :timeout}
    end
  end

  @doc """
  Look up the live executor for `run_id`. Returns `{:ok, pid, tenant_id}`
  (the tenant id the executor registered with — `Cancellation` verifies it
  against the run before killing) or `:error` when no executor is live.
  """
  @spec lookup(String.t()) :: {:ok, pid(), term()} | :error
  def lookup(run_id) do
    case Registry.lookup(@registry, to_string(run_id)) do
      [{pid, tenant_id}] -> {:ok, pid, tenant_id}
      [] -> :error
    end
  end

  @doc """
  Kill the local executor for `run_id` iff the registry value (the tenant the
  executor registered with) matches `tenant_id` — a defensive cross-tenant
  guard. A tenant mismatch logs a warning and does **not** kill; a registry
  miss is a no-op (the cancel already landed durably). The single source of
  truth for the tenant-pinned local kill, called by both the local cancel path
  (`Cancellation.kill_if_live/1`'s `:local` branch) and the per-node
  `RunTerminator` (the remote-routed branch). Always `:ok`.
  """
  @spec kill_local(String.t(), term()) :: :ok
  def kill_local(run_id, tenant_id) do
    case lookup(run_id) do
      {:ok, pid, ^tenant_id} ->
        Process.exit(pid, :kill)
        :ok

      {:ok, pid, other_tenant} ->
        Logger.warning(
          "[RunExecution] registry tenant mismatch for run #{run_id}: " <>
            "registered #{inspect(other_tenant)}, run has #{inspect(tenant_id)} — " <>
            "not killing #{inspect(pid)}"
        )

        :ok

      :error ->
        :ok
    end
  end
end
