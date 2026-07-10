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

  A follower retries that exact window only for a persisted worker whose
  eventual dispatch is protected by the durable row claim. Non-persisted jobs
  consume the missed boundary (recurring jobs advance; one-shots are
  discarded), preventing a stale follower window from replaying after a later
  leadership handoff.

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

  # Durable-claim retry backoff (claim failures ONLY — follower leadership
  # polling keeps its own flat cadence so a handoff is noticed within
  # @leader_recheck_ms, never up to the claim cap).
  @claim_retry_initial_ms 1_000
  @claim_retry_max_ms 30_000
  @leader_recheck_ms 1_000

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
    :definition_token,
    # Item 9 (OH1-3): the normalized outcome contract (`Cron.OutcomeSpec.t`)
    # or nil; the dispatcher appends its rendered block at fire time.
    outcome_spec: nil,
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
    fire: nil,
    # Persisted user jobs participate in the DB-backed fire claim and durable
    # outcome streak. In-memory system jobs retain their own idempotency fence.
    persisted?: false,
    # Consecutive durable-claim failures for the CURRENT window — drives the
    # capped exponential claim-retry backoff; reset by every non-error tick
    # outcome (claimed/duplicate/stale/completed window).
    fire_claim_attempts: 0
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
          definition_token: Ecto.UUID.t() | nil,
          outcome_spec: JidoClaw.Cron.OutcomeSpec.t() | nil,
          timezone: String.t(),
          status: :active | :disabled,
          failure_count: non_neg_integer(),
          last_run: DateTime.t() | nil,
          last_result: term(),
          next_run: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          persisted?: boolean(),
          fire_claim_attempts: non_neg_integer()
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
    base = %__MODULE__{
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
      definition_token: Keyword.get(opts, :definition_token),
      outcome_spec: Keyword.get(opts, :outcome_spec),
      timezone: Keyword.get(opts, :timezone, "Etc/UTC"),
      persisted?: Keyword.get(opts, :persisted?, false),
      failure_count: Keyword.get(opts, :failure_count, 0),
      created_at: DateTime.utc_now()
    }

    state =
      if unclaimable_under_clustering?(base) do
        # Permanent configuration error, knowable right here: a non-persisted
        # user job can never win a durable fire claim under clustering
        # (claim_scheduled_fire fails closed on every tick). Refuse to arm —
        # the job is nonpersisted, so there is no durable row to disable;
        # in-memory disable is the whole remedy (config-error shape).
        Logger.error(
          "[Cron] Refusing to arm job #{base.id}: a non-persisted user job " <>
            "cannot claim a durable fire under clustering"
        )

        %{base | status: :disabled, next_run: nil}
      else
        schedule_next(base)
      end

    {:ok, state}
  end

  # Mirrors claim_scheduled_fire/2's fail-closed clause for non-persisted
  # user jobs; `:system_job` keeps its own idempotency fence and is exempt.
  defp unclaimable_under_clustering?(%{persisted?: false, mode: mode})
       when mode != :system_job do
    Application.get_env(:jido_claw, :cluster_enabled, false) == true
  end

  defp unclaimable_under_clustering?(_state), do: false

  @impl GenServer
  def handle_cast(:trigger, state) do
    {:noreply, execute_job(state, :manual)}
  end

  def handle_cast(:disable, state) do
    Logger.info("[Cron] Disabled job #{state.id}")
    persist_disabled(state, :operator)
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
    if JidoClaw.Cluster.leader?() do
      case claim_scheduled_fire(state, window) do
        :claimed ->
          state = execute_job(state, {:scheduled, window})
          {:noreply, after_fire(state)}

        :duplicate ->
          Logger.debug("[Cron] Suppressed duplicate scheduled fire #{state.id} at #{window}")
          {:noreply, after_fire(state)}

        :stale_definition ->
          # The durable row was disabled or upserted after this worker was
          # hydrated. Stop locally without dispatch/retry; Owner reconciliation
          # removes it or replaces it with the new generation.
          Logger.info("[Cron] Retired stale worker #{state.id} before scheduled dispatch")
          {:noreply, %{state | status: :disabled, next_run: nil, fire_claim_attempts: 0}}

        {:error, :durable_fire_claim_required} ->
          # Permanent configuration error, not a transient claim failure —
          # normally refused at init (unclaimable_under_clustering?/1); this
          # defensive branch covers a cluster flag flipped after hydration.
          # No durable row exists to disable, so disable in memory: no
          # dispatch, no re-arm.
          Logger.error(
            "[Cron] Disabling job #{state.id}: a non-persisted user job " <>
              "cannot claim a durable fire under clustering"
          )

          {:noreply, %{state | status: :disabled, next_run: nil, fire_claim_attempts: 0}}

        {:error, reason} ->
          # Fail closed on an unavailable durable claim: do not dispatch a
          # possibly-duplicate side effect, and retain this window for a
          # capped-exponential retry.
          Logger.warning(
            "[Cron] Fire claim failed for #{state.id} at #{window}: #{inspect(reason)}"
          )

          {:noreply, retry_claim_tick(state, window)}
      end
    else
      # Only a persisted row may retain this exact boundary: its eventual
      # dispatch still has a durable single-winner claim. A replicated/in-memory
      # worker has no such fence, so retaining the window would let a follower
      # replay it sequentially after becoming leader. Consume that missed
      # boundary and arm the next recurring one (or discard a one-shot).
      {:noreply, after_follower_window(state, window)}
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

  # Every SCHEDULED tick is leader-gated; manual trigger/2 bypasses this clause
  # and remains an explicit operator override. The gate is first-line only: a
  # brief two-leaders window is fenced for persisted user jobs by
  # `claim_scheduled_fire/2`; in-memory system jobs must retain their own
  # idempotency/DB-lock guard (the consolidator advisory lock precedent).
  defp after_follower_window(%{persisted?: true} = state, window),
    do: retry_leader_tick(state, window)

  defp after_follower_window(%{schedule: {:at, _dt}} = state, _window) do
    Logger.info("[Cron] Discarded non-durable one-shot #{state.id} on follower")
    %{state | status: :disabled, next_run: nil}
  end

  defp after_follower_window(state, _window), do: schedule_next(state)

  # Follower leadership polling: deliberately FLAT — a capped claim backoff
  # here would add up to @claim_retry_max_ms of dispatch latency after every
  # leadership handoff.
  defp retry_leader_tick(state, window) do
    Process.send_after(self(), {:tick, window}, @leader_recheck_ms)
    state
  end

  # Failed durable claims back off exponentially (a dead DB polled at a flat
  # 1s hammers the pool); the counter is per-window work, reset by any
  # non-error tick outcome.
  defp retry_claim_tick(state, window) do
    Process.send_after(self(), {:tick, window}, claim_retry_delay(state.fire_claim_attempts))
    %{state | fire_claim_attempts: state.fire_claim_attempts + 1}
  end

  @doc false
  # Public for direct unit coverage of growth + cap; not an API.
  @spec claim_retry_delay(non_neg_integer()) :: pos_integer()
  def claim_retry_delay(attempt) do
    min(
      @claim_retry_initial_ms * Integer.pow(2, min(attempt, 20)),
      max(@claim_retry_initial_ms, @claim_retry_max_ms)
    )
  end

  # Persisted scheduled jobs claim their logical window by atomically advancing
  # `Cron.Job.last_fire_at`. Manual triggers never call this function. Directly
  # scheduled ephemeral jobs remain allowed single-node; clustered user jobs
  # fail closed unless they have a durable row.
  defp claim_scheduled_fire(%{mode: :system_job, persisted?: false}, _window), do: :claimed

  defp claim_scheduled_fire(%{persisted?: false} = _state, _window) do
    if Application.get_env(:jido_claw, :cluster_enabled, false) do
      {:error, :durable_fire_claim_required}
    else
      :claimed
    end
  end

  # `:every` is a cadence, not a caller-authored wall-clock boundary. The
  # durable action accepts only its interval and uses PostgreSQL's statement
  # clock for both the cutoff and `last_fire_at`; `window` remains local
  # dispatch provenance only.
  defp claim_scheduled_fire(%{schedule: {:every, ms}} = state, _window)
       when is_integer(ms) and ms > 0 do
    actor = Actor.system(state.tenant_id)

    with {:ok, job} <- Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      case Job.claim_interval_fire(job, ms, state.definition_token,
             tenant: state.tenant_id,
             actor: actor
           ) do
        {:ok, _claimed} ->
          :claimed

        {:error, reason} ->
          case Job.ClaimIntervalFire.classify_failure(
                 job.id,
                 state.tenant_id,
                 state.definition_token,
                 ms
               ) do
            :stale_definition -> :stale_definition
            :duplicate -> :duplicate
            :retry -> {:error, reason}
          end
      end
    end
  rescue
    error -> {:error, {:claim_raised, Exception.message(error)}}
  end

  defp claim_scheduled_fire(state, window) do
    actor = Actor.system(state.tenant_id)
    cutoff = prior_fire_cutoff(state.schedule, window)

    with {:ok, job} <- Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor),
         {:ok, _claimed} <-
           Job.claim_scheduled_fire(job, window, cutoff, state.definition_token,
             tenant: state.tenant_id,
             actor: actor
           ) do
      :claimed
    else
      {:error, reason} -> classify_fire_claim_failure(state, cutoff, reason)
    end
  rescue
    error -> {:error, {:claim_raised, Exception.message(error)}}
  end

  defp prior_fire_cutoff(_schedule, window),
    do: DateTime.add(window, -1, :microsecond)

  defp classify_fire_claim_failure(state, cutoff, original) do
    actor = Actor.system(state.tenant_id)

    case Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      {:ok, %{disabled_at: disabled_at}} when not is_nil(disabled_at) ->
        :stale_definition

      {:ok, %{definition_token: token}} when token != state.definition_token ->
        :stale_definition

      {:ok, %{last_fire_at: %DateTime{} = last}} ->
        if DateTime.compare(last, cutoff) == :gt, do: :duplicate, else: {:error, original}

      _ ->
        {:error, original}
    end
  end

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

    case result do
      :ok ->
        record_success(state)

      {:ok, _} ->
        record_success(state)

      {:error, reason} ->
        record_failure(state, reason)

      _other ->
        # System jobs may return arbitrary terms; treat anything
        # non-{:error, _} as success for telemetry/back-off.
        record_success(state)
    end
  end

  defp record_success(%{persisted?: false} = state) do
    %{state | last_run: DateTime.utc_now(), last_result: :ok, failure_count: 0}
  end

  defp record_success(state) do
    case update_persisted_outcome(state, :success) do
      {:ok, row} ->
        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: :ok,
            failure_count: row.failure_count
        }

      {:error, reason} ->
        # Do not invent a durable reset. The next outcome retries against the
        # row. A definition-token mismatch retires this stale worker now;
        # ordinary storage errors keep the current generation active.
        Logger.warning("[Cron] success persistence failed for #{state.id}: #{inspect(reason)}")

        state
        |> then(&%{&1 | last_run: DateTime.utc_now(), last_result: :ok})
        |> retire_if_stale_definition()
    end
  end

  defp record_failure(%{persisted?: false} = state, reason) do
    new_count = state.failure_count + 1
    status = if new_count >= @max_failures, do: :disabled, else: state.status
    log_failure(state.id, reason, new_count, status)
    if status == :disabled, do: persist_disabled(state)

    %{
      state
      | last_run: DateTime.utc_now(),
        last_result: {:error, reason},
        failure_count: new_count,
        status: status
    }
  end

  defp record_failure(state, reason) do
    case update_persisted_outcome(state, :failure) do
      {:ok, row} ->
        status = if row.disabled_at, do: :disabled, else: :active
        log_failure(state.id, reason, row.failure_count, status)

        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: {:error, reason},
            failure_count: row.failure_count,
            status: status
        }

      {:error, persistence_error} ->
        # Crucially stay active: a failed disable write cannot strand an enabled
        # DB row behind an idle local worker. The next failure retries from the
        # durable count (and a restart reloads that same count).
        Logger.warning(
          "[Cron] failure persistence failed for #{state.id}: #{inspect(persistence_error)}"
        )

        state
        |> then(&%{&1 | last_run: DateTime.utc_now(), last_result: {:error, reason}})
        |> retire_if_stale_definition()
    end
  end

  defp update_persisted_outcome(state, outcome) do
    actor = Actor.system(state.tenant_id)

    with {:ok, job} <- Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      case outcome do
        :success ->
          Job.record_success(job, state.definition_token,
            tenant: state.tenant_id,
            actor: actor
          )

        :failure ->
          Job.record_failure(job, state.definition_token,
            tenant: state.tenant_id,
            actor: actor
          )
      end
    end
  rescue
    error -> {:error, {:outcome_raised, Exception.message(error)}}
  end

  defp retire_if_stale_definition(state) do
    actor = Actor.system(state.tenant_id)

    case Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      {:ok, %{definition_token: token}} when token != state.definition_token ->
        %{state | status: :disabled, next_run: nil}

      {:ok, %{disabled_at: disabled_at}} when not is_nil(disabled_at) ->
        %{state | status: :disabled, next_run: nil}

      _current_or_unreadable ->
        state
    end
  rescue
    _error -> state
  end

  defp log_failure(job_id, reason, count, status) do
    Logger.warning("[Cron] Job #{job_id} failed (#{count}/#{@max_failures}): #{inspect(reason)}")

    if status == :disabled do
      Logger.error("[Cron] Job #{job_id} auto-disabled after #{@max_failures} failures")
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
  # intent always runs, see handle_cast(:trigger, ...)). A completed window
  # (dispatched or suppressed-duplicate) ends any claim-retry streak — the
  # backoff counter tracks only consecutive claim failures.
  defp after_fire(state), do: rearm_after_fire(%{state | fire_claim_attempts: 0})

  # Already disabled by execute_job (3-failure auto-disable): don't re-arm,
  # and clear the consumed window — execute_job sets status without touching
  # next_run, and a dangling next_run would advertise a tick that never comes.
  defp rearm_after_fire(%{status: :disabled} = state), do: %{state | next_run: nil}

  # A one-shot :at fires exactly once, then disables (in-memory + persisted)
  # and never re-arms. Recurring :cron/:every re-arm as before.
  defp rearm_after_fire(%{schedule: {:at, _dt}} = state) do
    Logger.info("[Cron] One-shot :at job #{state.id} fired; disabling")
    persist_disabled(state)
    %{state | status: :disabled, next_run: nil}
  end

  defp rearm_after_fire(state), do: schedule_next(state)

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
  defp persist_disabled(state, mode \\ :worker)

  defp persist_disabled(state, mode) do
    actor = Actor.system(state.tenant_id)

    case Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
      {:ok, job} ->
        result =
          case mode do
            :operator ->
              Job.disable(job, tenant: state.tenant_id, actor: actor)

            :worker ->
              Job.disable_generation(job, state.definition_token,
                tenant: state.tenant_id,
                actor: actor
              )
          end

        case result do
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
end
