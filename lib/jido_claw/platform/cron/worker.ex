defmodule JidoClaw.Cron.Worker do
  @moduledoc """
  GenServer per scheduled job. Supports `:at`, `:every`, and `:cron` schedule
  types. `:cron` expressions are interpreted in the job's `:timezone` (default
  `"Etc/UTC"`) via `JidoClaw.Cron.NextRun`.

  Auto-disables after 3 consecutive failures. A permanent config error on a
  `:cron` schedule (invalid expression / unknown timezone) disables the job
  immediately and persists `disabled_at`, so the bad row is not reloaded on
  restart.

  `:at` is a one-shot: it fires at most once, then disables and persists
  `disabled_at`. An `:at` whose instant has already passed at init/reload is
  skipped (disabled without firing) — a missed one-shot must not fire at
  boot. Manual `trigger/2` remains an operator override that executes
  regardless of disabled status.

  Timer ticks carry the `%DateTime{}` window they were armed for
  (`{:tick, window}`), and a tick only fires when its window equals the
  current `next_run` — a duplicate or stale tick is swallowed without
  executing or re-arming. This binds each scheduled dispatch (and the
  workflow idempotency key derived from its provenance) to the armed window,
  so a double-delivered tick can never launch a second run early.

  Dispatch is synchronous — a tick blocks this GenServer until the target
  returns — so there is intentionally no stuck-detection watchdog; a real one
  would require async dispatch and is deferred.
  """
  # Cron worker GenServer: dispatch + persistence rescues are deliberate
  # never-crash boundaries — a hung target or transient DB error must
  # become an error tuple / debug log, not a worker crash.
  # reach:disable-for-this-file bare_rescue
  use GenServer
  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Dispatcher
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.NextRun
  alias JidoClaw.Telemetry

  @max_failures 3

  defstruct [
    :id,
    :tenant_id,
    :agent_id,
    :schedule,
    :task,
    :mode,
    :target,
    :workflow_name,
    :workflow_input,
    :mfa,
    timezone: "Etc/UTC",
    status: :active,
    failure_count: 0,
    last_run: nil,
    last_result: nil,
    next_run: nil,
    created_at: nil,
    # Firing provenance, stamped ONLY on the local dispatch copy inside
    # execute_job/2 ({:scheduled, window} | :manual, where window is the
    # armed window the timer message carried — never mutable state). Always
    # nil in stored GenServer state — a manual trigger must never inherit
    # (and consume) a scheduled window's workflow idempotency key.
    fire: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          tenant_id: String.t() | nil,
          agent_id: String.t(),
          schedule: term(),
          task: term(),
          mode: atom(),
          target: atom(),
          workflow_name: String.t() | nil,
          workflow_input: term(),
          mfa: mfa() | nil,
          timezone: String.t(),
          status: :active | :disabled,
          failure_count: non_neg_integer(),
          last_run: DateTime.t() | nil,
          last_result: term(),
          next_run: DateTime.t() | nil,
          created_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec trigger(String.t(), String.t()) :: :ok
  def trigger(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.cast(name, :trigger)
  end

  @spec disable(String.t(), String.t()) :: :ok
  def disable(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.cast(name, :disable)
  end

  @spec get_state(String.t(), String.t()) :: t()
  def get_state(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}
    GenServer.call(name, :get_state)
  end

  @impl GenServer
  def init(opts) do
    state =
      schedule_next(%__MODULE__{
        id: Keyword.fetch!(opts, :id),
        tenant_id: Keyword.fetch!(opts, :tenant_id),
        agent_id: Keyword.get(opts, :agent_id, "main"),
        schedule: Keyword.fetch!(opts, :schedule),
        task: Keyword.get(opts, :task),
        mode: Keyword.get(opts, :mode, :main),
        target: Keyword.get(opts, :target, :agent),
        workflow_name: Keyword.get(opts, :workflow_name),
        workflow_input: Keyword.get(opts, :workflow_input),
        mfa: Keyword.get(opts, :mfa),
        timezone: Keyword.get(opts, :timezone, "Etc/UTC"),
        created_at: DateTime.utc_now()
      })

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:trigger, state) do
    {:noreply, execute_job(state, :manual)}
  end

  def handle_cast(:disable, state) do
    Logger.info("[Cron] Disabled job #{state.id}")
    persist_disabled(state)
    {:noreply, %{state | status: :disabled}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # The repeated `window` is the equality constraint: the tick fires only when
  # the message's armed window equals the current `next_run` (the message
  # carries the very struct stored in state, so pattern equality holds). This
  # binds the dispatch provenance — and the idempotency key derived from it —
  # to the window the timer was armed for, never to a freshly advanced one.
  @impl GenServer
  def handle_info({:tick, window}, %{status: :active, next_run: window} = state) do
    if leader_gated?(state) and not JidoClaw.Cluster.leader?() do
      # Off-leader replicated :system_job tick: re-arm WITHOUT firing. The
      # leader fires this tick; this follower just keeps its timer alive. When
      # leadership moves, the new leader's worker fires on the next cron
      # boundary — failover is automatic, no leadership listener needed.
      #
      # Recurring-only: schedule_next/1 here is correct for :cron/:every (every
      # :system_job today is recurring). A future one-shot {:at, _} system job
      # would hit schedule_next/1's elapsed-:at disable path on a follower
      # (wrong — a follower must not disable a one-shot it never ran); that
      # would require a bounded re-check instead. No such job exists today.
      {:noreply, schedule_next(state)}
    else
      state = execute_job(state, {:scheduled, window})
      {:noreply, after_fire(state)}
    end
  end

  # Stale/duplicate window, or a disabled worker: swallow WITHOUT executing
  # or re-arming — the matching-tick clause is the only re-arm point, so the
  # timer for the current next_run (if active) is already in flight.
  # NOTE: dispatch is synchronous, so a hung target blocks this process; a real
  # stuck-detection watchdog would need async dispatch and is deferred.
  def handle_info({:tick, _window}, state) do
    {:noreply, state}
  end

  # -- Private --

  # Only platform `:system_job` ticks gate on the cluster leader — they are the
  # always-on jobs the supervision tree replicates on every node (the memory
  # consolidator tick). User `:agent`/`:workflow`/`:mfa` jobs short-circuit and
  # fire on every node as today (no leader call, no regression). A manual
  # `trigger/2` is never gated (it bypasses this clause entirely — operator
  # override). The gate is FIRST-LINE only: the brief two-leaders window during
  # `:pg` convergence can still fire a `:system_job` on two nodes, so every
  # system job must stay idempotent / row-claimed / DB-leased independently
  # (see `JidoClaw.Cluster.Leader`).
  defp leader_gated?(%{mode: :system_job}), do: true
  defp leader_gated?(_state), do: false

  # `fire` is the firing provenance ({:scheduled, window} from a timer tick,
  # :manual from trigger/2). It rides a LOCAL dispatch copy only — every state
  # update below derives from the original `state`, so provenance never
  # persists into stored GenServer state (`get_state/2` always shows
  # `fire: nil`). `WorkflowRunner` derives the launch idempotency key from it.
  defp execute_job(state, fire) do
    meta = telemetry_meta(state)
    Telemetry.emit_cron_start(meta)
    start_time = System.monotonic_time()

    result =
      try do
        Dispatcher.dispatch(%{state | fire: fire})
      rescue
        e ->
          Telemetry.emit_cron_exception(meta, :error)
          {:error, Exception.message(e)}
      end

    duration = System.monotonic_time() - start_time
    Telemetry.emit_cron_stop(meta, duration)
    record_run(state)

    case result do
      :ok ->
        %{state | last_run: DateTime.utc_now(), last_result: :ok, failure_count: 0}

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
          persist_disabled(state)
        end

        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: {:error, reason},
            failure_count: new_count,
            status: new_status
        }

      _other ->
        # System jobs may return arbitrary terms; treat anything
        # non-{:error, _} as success for telemetry/back-off.
        %{state | last_run: DateTime.utc_now(), last_result: :ok, failure_count: 0}
    end
  end

  # Shared metadata for every cron telemetry event of one tick. `dispatch_target`
  # is the *effective* path (`Dispatcher.dispatch_target/1`), so a :system_job
  # whose `target` defaults to :agent still reports `dispatch_target: :mfa`.
  defp telemetry_meta(state) do
    %{
      job_id: state.id,
      tenant_id: state.tenant_id,
      mode: state.mode,
      target: state.target,
      dispatch_target: Dispatcher.dispatch_target(state)
    }
  end

  # Post-dispatch re-arm policy for the matching-tick clause. Scheduled ticks
  # stop once disabled; manual trigger/2 deliberately bypasses this (operator
  # intent always runs, see handle_cast(:trigger, ...)).

  # Already disabled by execute_job (3-failure auto-disable): don't re-arm,
  # and clear the consumed window — execute_job sets status without touching
  # next_run, and a dangling next_run would advertise a tick that never comes.
  defp after_fire(%{status: :disabled} = state), do: %{state | next_run: nil}

  # A one-shot :at fires exactly once, then disables (in-memory + persisted)
  # and never re-arms. Recurring :cron/:every re-arm as before.
  defp after_fire(%{schedule: {:at, _dt}} = state) do
    Logger.info("[Cron] One-shot :at job #{state.id} fired; disabling")
    persist_disabled(state)
    %{state | status: :disabled, next_run: nil}
  end

  defp after_fire(state), do: schedule_next(state)

  # Every arm sends {:tick, window} carrying the SAME DateTime struct stored
  # in next_run, so handle_info can equality-match message against state and
  # swallow duplicate/stale ticks.
  defp schedule_next(%{schedule: {:at, %DateTime{} = dt}} = state) do
    now = DateTime.utc_now()

    case DateTime.compare(dt, now) do
      :lt ->
        # Elapsed one-shot at init/reload: must NOT fire at boot. Persist
        # disabled_at so for_tenant excludes the row on the next reload.
        Logger.info("[Cron] Skipping elapsed one-shot :at job #{state.id}; disabling")
        persist_disabled(state)
        %{state | status: :disabled, next_run: nil}

      _ ->
        delay = max(DateTime.diff(dt, now, :millisecond), 0)
        Process.send_after(self(), {:tick, dt}, delay)
        %{state | next_run: dt}
    end
  end

  defp schedule_next(%{schedule: {:every, ms}} = state) when is_integer(ms) do
    next = DateTime.add(DateTime.utc_now(), ms, :millisecond)
    Process.send_after(self(), {:tick, next}, ms)
    %{state | next_run: next}
  end

  defp schedule_next(%{schedule: {:cron, expression}} = state) do
    case NextRun.compute_next_cron_utc(expression, state.timezone) do
      {:ok, dt} ->
        delta = DateTime.diff(dt, DateTime.utc_now(), :millisecond)

        if delta < 0 do
          Logger.warning(
            "[Cron] Job #{state.id} computed a next run in the past (#{delta}ms); firing in 1s"
          )
        end

        Process.send_after(self(), {:tick, dt}, max(delta, 1000))
        %{state | next_run: dt}

      {:error, reason} ->
        # :invalid_expression | :unknown_timezone | :calc_error are all
        # deterministic, permanent config errors. Disable and persist
        # disabled_at so for_tenant excludes the bad row on the next boot.
        Logger.error(
          "[Cron] Disabling job #{state.id}: cannot compute next run (#{inspect(reason)})"
        )

        persist_disabled(state)
        %{state | status: :disabled}
    end
  end

  defp schedule_next(state), do: state

  # Best-effort persistence — a transient DB error shouldn't crash
  # the worker. Eventual consistency is acceptable: if persist fails
  # this run, the next failure will retry. Crashing is strictly worse.
  defp persist_disabled(state) do
    actor = Actor.system(state.tenant_id)

    case Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      {:ok, job} ->
        case Job.disable(job, tenant: state.tenant_id, actor: actor) do
          {:ok, _} -> :ok
          err -> Logger.warning("[Cron] disable persistence failed: #{inspect(err)}")
        end

      {:error, _} ->
        # Job not in Postgres — system jobs aren't persisted in v0.6.4.
        :ok
    end
  rescue
    e -> Logger.warning("[Cron] disable persistence raised: #{Exception.message(e)}")
  end

  # Best-effort durability counters. Increments run_count / stamps
  # last_run_at on the persisted row after every tick — for any persisted
  # job (agent/workflow/mfa, including persisted :system_job rows). Jobs
  # with no DB row (the in-memory memory-consolidator) are skipped via the
  # {:error, _} branch. A transient DB error must never crash the worker.
  defp record_run(state) do
    actor = Actor.system(state.tenant_id)

    case Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      {:ok, job} ->
        case Job.record_run(job, tenant: state.tenant_id, actor: actor) do
          {:ok, _} -> :ok
          err -> Logger.debug("[Cron] record_run persistence failed: #{inspect(err)}")
        end

      {:error, _} ->
        :ok
    end
  rescue
    e -> Logger.debug("[Cron] record_run raised: #{Exception.message(e)}")
  end
end
