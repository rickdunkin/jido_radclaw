defmodule JidoClaw.RouteComposer do
  @moduledoc """
  The single-run composer loop (AR-2 §4; §14 Phase 2a — durable parent-run
  lineage over the still-**in-memory** composer state).

  A `GenServer` that turns the Alp River crank: **seed → `compose_route` →
  `merge_sticky` → dispatch the next unrun wave → run it on Reactor → fold the
  emitted signals/artifacts → recompose → converge.** Each wave is built into a
  `%Reactor{}` by `JidoClaw.RouteComposer.WaveBuilder` and run through the
  shipped `JidoClaw.Orchestration.ReactorRunner`, so every increment inherits the
  durable execution envelope (each wave persists its `WaveCollect` return to the
  child `WorkflowRun.result`).

  ## Parent-run lineage (Phase 2a)

  Every composer run is a first-class parent `WorkflowRun` (`workflow_type:
  "composer"`). The split launch is durable-genesis-first:
  `create_parent_run/1` creates the parent and appends its own `run_started`
  (flipping `:pending → :running` via the shipped status authority — the parent
  never executes through `ReactorMiddleware`) in one transaction; only then does
  `start_composer/2` start the GenServer. Each wave runs as a **child**
  `WorkflowRun` linked by `parent_run_id` and keyed by the deterministic
  idempotency key `composer:<parent_run_id>:<wave_index>`, so a re-derived wave
  (2d recovery) dedupes to the existing child instead of double-running. The
  parent reaches a terminal status (`:completed` on convergence, `:failed`
  otherwise) the moment the loop finishes — `finish/2` appends that terminal
  *before* it notifies. **Composer state (`live`/`artifacts`/`ran`/`prev_route`/
  `wave_index`) still lives only in GenServer memory** — the durable event
  log/projection and crash recovery are Phase 2c/2d.

  ## State (in-memory)

  `catalog`, `live` (signal topics), `artifacts` (the provenance store `name →
  %{producer => value}`), `ran`, `premises`, `prev_route`, `wave_index`, the
  `parent_run_id`, plus the run identity (`tenant`, `actor`, `context`) and
  bounds (`max_waves`, `deadline`). `available` is **derived** from `artifacts`
  each tick, never stored.

  ## Driving / notification

  The loop ticks via `handle_continue(:tick, …)`. `finish/2` stamps the terminal
  + summary, **appends the parent's terminal event first** (reload-guarded:
  `run_completed` on convergence → `:completed`, `run_failed` otherwise →
  `:failed`), then sends `{:route_composer, ref, {:done, summary}}` to `notify`
  for **every** terminal — or `{:route_composer, ref, {:terminalize_failed,
  reason}}` if that durable write failed (so the caller never sees a
  falsely-successful `:done`). It returns `{:stop, :normal, state}` so a finished
  composer terminates rather than lingering. The thin `run_sync/1` helper
  (`create_parent_run/1` → `start_composer/2` **unlinked** + `Process.monitor` +
  a bounded `receive`) is the test/CLI entry: a composer crash surfaces as a
  handled `:DOWN`, and on timeout/crash/start-failure the now-ownerless
  `:running` parent is terminalized live. Per wave the GenServer **blocks**
  inside `ReactorRunner.run/3` — acceptable for a single-run spike; Phase 4 moves
  wave execution to a `Task` + `handle_info` so the GenServer stays live across a
  gate park.

  ## Scope forks (Phase 1)

  Forward-only: the self-heal rerun loop (AR-4) is out of scope, so a ran lens
  with open `findings:<lens>` terminates `:not_converged` (it does not re-fire a
  fixer). Worker-only waves: `WaveBuilder` rejects non-`{:worker_template, _}`
  units, so the public loop is fixture-catalog-only.
  """

  use GenServer

  require Logger

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.ArtifactContext
  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Loop
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.RouteComposer.WaveBuilder

  @default_max_waves 20
  @default_timeout_ms 60_000
  @default_run_name "route_composer"

  @type terminal ::
          :converged | :not_converged | :deadlock | :budget_exhausted | :failed

  @type history_entry :: %{
          index: non_neg_integer(),
          stages: [String.t()],
          child_run_id: term(),
          route: [String.t()],
          held_before: %{optional(String.t()) => [String.t()]},
          emissions: [%{stage: String.t(), signals: [String.t()], artifacts: map()}],
          failed: boolean()
        }

  @type summary :: %{
          terminal: terminal(),
          reason: term() | nil,
          parent_run_id: String.t() | nil,
          final_route: [String.t()],
          final_live: MapSet.t(String.t()),
          artifacts: %{optional(String.t()) => %{optional(String.t()) => term()}},
          ran: MapSet.t(String.t()),
          wave_index: non_neg_integer(),
          history: [history_entry()]
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a composer GenServer for an **already-created** parent run.

  Required opts: `:catalog`, `:tenant`, `:actor`, `:notify`, `:ref`,
  `:parent_run_id`. Optional: `:live` / `:artifacts` / `:premises` (seed state),
  `:context` (the scope map merged into each wave's Reactor context),
  `:max_waves` (default `#{@default_max_waves}`), `:deadline_ms` (wall-clock
  budget from start). The composer ticks immediately, so the parent run MUST
  already be committed (`create_parent_run/1`) before this is called — a wave
  could otherwise fire against an uncommitted parent. Used by 2c's supervised
  lifecycle; `run_sync/1` uses the unlinked `start_composer/2` instead.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Durable genesis of a composer parent run (Phase 2a).

  In one `Ash.transact`, creates a `WorkflowRun` (`workflow_type: "composer"`,
  genesis `:pending`) and appends its own `run_started` — reusing the shipped
  status authority (`next_status(:pending, :run_started) → :running`), so no
  composer-specific start kind is needed and the parent never runs through
  `ReactorMiddleware`. Reloads to the `:running` parent (the `create` struct is
  still `:pending`). Required opts: `:tenant`, `:actor`; `:name` overrides the
  run name (default `#{inspect(@default_run_name)}`).

  Returns `{:ok, running_parent}` or `{:error, {:start_failed, reason}}`. If the
  reload fails *after* `run_started` committed, the parent is already `:running`
  and ownerless, so it is terminalized before the error is surfaced.
  """
  @spec create_parent_run(keyword()) :: {:ok, WorkflowRun.t()} | {:error, {:start_failed, term()}}
  def create_parent_run(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)
    name = Keyword.get(opts, :name, @default_run_name)

    genesis =
      Ash.transact([WorkflowRun, WorkflowEvent], fn ->
        with {:ok, parent} <-
               WorkflowRun.create(%{name: name, workflow_type: "composer"},
                 tenant: tenant,
                 actor: actor
               ),
             {:ok, _event} <-
               WorkflowLog.append(parent, :run_started, %{}, tenant: tenant, actor: actor) do
          parent
        end
      end)

    case genesis do
      {:ok, parent} -> reload_running_parent(parent, tenant, actor)
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  @doc """
  Start the (unlinked) composer GenServer for `parent`, threading
  `parent_run_id: parent.id` into `opts`. On a start failure the parent already
  exists and is `:running` with no crank-turner, so it is terminalized
  (`:composer_start_failed`) before `{:error, {:start_failed, reason}}` is
  returned. `run_sync/1` then `Process.monitor`s the returned pid.
  """
  @spec start_composer(keyword(), WorkflowRun.t()) ::
          {:ok, pid()} | {:error, {:start_failed, term()}}
  def start_composer(opts, %WorkflowRun{} = parent) do
    start_opts = Keyword.put(opts, :parent_run_id, parent.id)

    case GenServer.start(__MODULE__, start_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        terminalize_parent(
          parent,
          {:composer_start_failed, reason},
          Keyword.fetch!(opts, :tenant),
          Keyword.fetch!(opts, :actor)
        )

        {:error, {:start_failed, reason}}
    end
  end

  @doc """
  Create a parent run, start an **unlinked + monitored** composer, and block on
  its terminal — the test/CLI entry. Returns `{:ok, summary}` on a terminal the
  composer reached itself (the parent's terminal event already committed), or one
  of the error envelopes below.

  Opts are passed through to `start_composer/2` (minus `:timeout`); `:timeout`
  (default `#{@default_timeout_ms}` ms) bounds the wait. The composer is
  **unlinked** (`GenServer.start/3`) + `Process.monitor`ed, so a hard crash
  surfaces as a handled `:DOWN` rather than propagating into the caller.

    * `{:error, :timeout}` — the budget elapsed; the composer is killed and the
      now-ownerless `:running` parent is terminalized (`error: "composer_timeout"`).
      The in-flight wave runs under `async_nolink`, survives the kill, and
      finishes durably "into the void" — true mid-wave cancellation is out of
      scope for this spike.
    * `{:error, {:start_failed, reason}}` — `create_parent_run/1` or
      `start_composer/2` failed; the parent (if it reached `:running`) is
      terminalized.
    * `{:error, {:crashed, reason}}` — the composer died abnormally before
      `finish/2`; the parent is terminalized as a crash.
    * `{:error, {:terminalize_failed, reason}}` — the loop reached a terminal but
      its parent-terminal write failed; surfaced rather than a false `:done`.
  """
  @spec run_sync(keyword()) ::
          {:ok, summary()}
          | {:error, :timeout}
          | {:error, {:start_failed, term()}}
          | {:error, {:crashed, term()}}
          | {:error, {:terminalize_failed, term()}}
  def run_sync(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, parent} <- create_parent_run(opts),
         notify_ref = make_ref(),
         start_opts = run_sync_start_opts(opts, notify_ref),
         {:ok, pid} <- start_composer(start_opts, parent) do
      monitor_ref = Process.monitor(pid)
      await_terminal(parent, pid, notify_ref, monitor_ref, timeout, tenant, actor)
    end
  end

  defp run_sync_start_opts(opts, notify_ref) do
    opts
    |> Keyword.drop([:timeout])
    |> Keyword.merge(notify: self(), ref: notify_ref)
  end

  # The composer is unlinked + monitored: a `{:done, _}` notify means it appended
  # its own terminal in finish/2; a `{:terminalize_failed, _}` means that write
  # failed; an abnormal `:DOWN` (before finish/2) or a timeout leaves the parent
  # `:running`, so terminalize it live. A `:DOWN :normal` is the composer's own
  # `{:stop, :normal}` *after* it already sent the notify — finish/2 sends before
  # stopping, so the matching `{:done, _}` is enqueued first and wins; the `when
  # reason != :normal` guard keeps that benign DOWN from being read as a crash.
  defp await_terminal(parent, pid, notify_ref, monitor_ref, timeout, tenant, actor) do
    receive do
      {:route_composer, ^notify_ref, {:done, summary}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, summary}

      {:route_composer, ^notify_ref, {:terminalize_failed, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:terminalize_failed, reason}}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} when reason != :normal ->
        terminalize_parent(parent, {:composer_crashed, reason}, tenant, actor)
        {:error, {:crashed, reason}}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        terminalize_parent(parent, :composer_timeout, tenant, actor)
        {:error, :timeout}
    end
  end

  # Reload the just-created parent: the `create` struct is still `:pending`, but
  # `run_started` committed in the same transaction, so the DB row is `:running`.
  defp reload_running_parent(parent, tenant, actor) do
    case WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = running} ->
        {:ok, running}

      other ->
        # run_started committed → the parent is :running and ownerless.
        # Terminalize before surfacing the error so we never leak a
        # perpetually-:running parent.
        terminalize_parent(parent, :composer_reload_failed, tenant, actor)
        {:error, {:start_failed, {:reload_failed, other}}}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      catalog: Keyword.fetch!(opts, :catalog),
      live: MapSet.new(Keyword.get(opts, :live, [])),
      artifacts: Keyword.get(opts, :artifacts, %{}),
      ran: MapSet.new(),
      premises: Keyword.get(opts, :premises, %{}),
      prev_route: [],
      wave_index: 0,
      parent_run_id: Keyword.fetch!(opts, :parent_run_id),
      tenant: Keyword.fetch!(opts, :tenant),
      actor: Keyword.fetch!(opts, :actor),
      context: Keyword.get(opts, :context, %{}),
      max_waves: Keyword.get(opts, :max_waves, @default_max_waves),
      deadline: deadline_at(Keyword.get(opts, :deadline_ms)),
      notify: Keyword.fetch!(opts, :notify),
      ref: Keyword.fetch!(opts, :ref),
      history: [],
      terminal: nil,
      reason: nil,
      summary: nil
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl GenServer
  def handle_continue(:tick, state) do
    available = Fold.available(state.artifacts)
    result = Router.compose_route(state.catalog, state.live, available, state.ran)
    display = Router.merge_sticky(state.catalog, state.prev_route, result)
    dispatch = Loop.dispatch_cohort(display, state.ran)

    cond do
      is_nil(dispatch) -> finish(Loop.terminal(display, state), state)
      over_budget?(state) -> finish({:budget_exhausted, budget_reason(state)}, state)
      true -> run_wave(dispatch, display, state)
    end
  end

  # ---------------------------------------------------------------------------
  # The wave
  # ---------------------------------------------------------------------------

  defp run_wave(dispatch, display, state) do
    stages = Enum.map(dispatch, &Map.fetch!(state.catalog, &1))

    case WaveBuilder.build_wave(stages, wave_index: state.wave_index) do
      {:ok, reactor} ->
        extra_context = ArtifactContext.build(stages, state.artifacts)

        reactor
        |> run_reactor(extra_context, state)
        |> handle_wave_result(dispatch, display, state)

      # build_wave failure: no reactor ran, so there is no run to record.
      {:error, reason} ->
        finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # A launch-dedupe hit re-binds an already-seen wave. It cannot occur in 2a's
  # linear single-process loop (each `wave_index` runs exactly once), but the
  # deterministic `composer:<parent>:<wave_index>` key makes it reachable for 2d
  # recovery re-drives, so the contract is kept total now: a `:completed`
  # existing child folds its durable emission; any other status is a failed wave
  # (the full status-branch table — `:awaiting_approval` park, live `:running`
  # observe — is 2c/2d). This clause must precede the generic `{:ok, value, run}`
  # one (the existing-run tuple matches both).
  defp handle_wave_result({:ok, {:existing_run, _id}, run}, dispatch, display, state) do
    if run.status == :completed do
      handle_wave_value(decode_emissions(run.result), run, dispatch, display, state)
    else
      finish_failed({:existing_run_not_completed, run.status}, run, dispatch, display, state)
    end
  end

  # `decode_emissions` is run INSIDE the body (not as a `with`/pipeline leg) so a
  # bad-wave-return error still carries the live `run` to `finish_failed` — a
  # leg failure would drop the child_run_id.
  defp handle_wave_result({:ok, value, run}, dispatch, display, state) do
    handle_wave_value(decode_emissions(value), run, dispatch, display, state)
  end

  # run_reactor failure: `run` is the (possibly nil, on a pre-run error) child
  # WorkflowRun whose id the failed-wave history entry surfaces.
  defp handle_wave_result({:error, reason, run}, dispatch, display, state) do
    finish_failed(reason, run, dispatch, display, state)
  end

  defp handle_wave_value({:ok, emissions}, run, dispatch, display, state) do
    next =
      state
      |> Fold.fold(emissions)
      |> record_wave(dispatch, display, run, emissions)

    {:noreply, next, {:continue, :tick}}
  end

  defp handle_wave_value({:error, reason}, run, dispatch, display, state),
    do: finish_failed(reason, run, dispatch, display, state)

  # Record the attempted-but-failed wave (empty emissions, `failed: true`,
  # surfacing `child_run_id`) before stamping the `:failed` terminal, so the
  # summary can point at which stages failed and at the child run.
  defp finish_failed(reason, run, dispatch, display, state) do
    next = record_wave(state, dispatch, display, run, [], true)
    finish({:failed, reason}, next)
  end

  # Struct path, ungated; blocks until the wave completes (`async?: true` only
  # parallelizes the wave's independent steps). `ReactorRunner.run/3` returns
  # error envelopes, never raises. The wave is a child of the composer parent
  # (`:parent_run_id`) and carries the deterministic
  # `composer:<parent>:<wave_index>` launch idempotency key (Phase 2a) — so a
  # re-derived wave dedupes to the existing child (handled by `handle_wave_result`)
  # rather than double-running.
  defp run_reactor(reactor, extra_context, state) do
    ReactorRunner.run(reactor, %{extra_context: extra_context},
      tenant: state.tenant,
      actor: state.actor,
      async?: true,
      name: "route_composer:wave_#{state.wave_index}",
      context: state.context,
      parent_run_id: state.parent_run_id,
      idempotency_key: "composer:#{state.parent_run_id}:#{state.wave_index}"
    )
  end

  # `WaveCollect` always returns a string-keyed json-safe map, so the live
  # `{:ok, value, _run}` return is string-keyed here (per-emission atom/string
  # tolerance is `StageEmission.from_map/1`'s job).
  defp decode_emissions(%{"emissions" => emissions}) when is_list(emissions) do
    {:ok, Enum.map(emissions, &StageEmission.from_map/1)}
  end

  defp decode_emissions(other), do: {:error, {:bad_wave_return, other}}

  # Append the wave to history and advance the per-turn state this owns:
  # `wave_index + 1` and `prev_route` = the merged display route (so the next
  # tick's `merge_sticky` carries the right sticky baseline). Records BOTH a
  # successful wave (called after the fold advances live/artifacts/ran, so it
  # reads the pre-bump `wave_index`) and a failed wave (`emissions: []`,
  # `failed: true`, and a nil-tolerant `child_run_id` — a build-wave failure has
  # no run, while a decode/run failure does — so the `:failed` summary can still
  # name the attempted stages and point at the child run). The
  # `wave_index == length(history)` invariant holds for failures too (the failed
  # wave *was* attempted).
  defp record_wave(state, dispatch, display, run, emissions, failed? \\ false) do
    entry = %{
      index: state.wave_index,
      stages: dispatch,
      child_run_id: run && run.id,
      route: display.route,
      held_before: display.held,
      emissions: Enum.map(emissions, &emission_entry/1),
      failed: failed?
    }

    # Prepend (newest-first); `summary/3` reverses to the oldest-first history
    # the caller reads.
    %{
      state
      | wave_index: state.wave_index + 1,
        prev_route: display.route,
        history: [entry | state.history]
    }
  end

  defp emission_entry(%StageEmission{} = emission) do
    %{stage: emission.stage, signals: emission.signals, artifacts: emission.artifacts}
  end

  # ---------------------------------------------------------------------------
  # Termination
  # ---------------------------------------------------------------------------

  # Append the parent's terminal event FIRST, then notify (Phase 2a, P1): the
  # `:done` summary the caller receives matches durable state, `run_sync/1` tests
  # never race the DB write, and a terminal-write failure surfaces as
  # `{:terminalize_failed, _}` instead of hiding behind a `:done` the caller
  # already saw. Existing event kinds keep the parent correctly terminal —
  # `:converged` → `run_completed` (→ `:completed`), every other terminal →
  # `run_failed` (→ `:failed`). (2c swaps these for the semantically-named
  # `route_*` kinds, all projecting onto the same statuses.)
  defp finish(terminal, state) do
    {kind, reason} = classify_terminal(terminal)
    summary = summary(kind, reason, state)

    send(
      state.notify,
      {:route_composer, state.ref, parent_terminal_notify(kind, reason, summary, state)}
    )

    {:stop, :normal, %{state | terminal: kind, reason: reason, summary: summary}}
  end

  defp parent_terminal_notify(:converged, _reason, summary, state) do
    state.parent_run_id
    |> append_parent_terminal(
      :run_completed,
      %{result: terminal_summary_subset(summary)},
      state.tenant,
      state.actor
    )
    |> notify_payload(summary)
  end

  defp parent_terminal_notify(kind, reason, summary, state) do
    state.parent_run_id
    |> append_parent_terminal(
      :run_failed,
      %{error: format_terminal_error(kind, reason)},
      state.tenant,
      state.actor
    )
    |> notify_payload(summary)
  end

  defp notify_payload(:ok, summary), do: {:done, summary}
  defp notify_payload({:error, reason}, _summary), do: {:terminalize_failed, reason}

  defp classify_terminal({:budget_exhausted, reason}), do: {:budget_exhausted, reason}
  defp classify_terminal({:failed, reason}), do: {:failed, reason}
  defp classify_terminal(kind) when is_atom(kind), do: {kind, nil}

  defp summary(kind, reason, state) do
    %{
      terminal: kind,
      reason: reason,
      parent_run_id: state.parent_run_id,
      final_route: state.prev_route,
      final_live: state.live,
      artifacts: state.artifacts,
      ran: state.ran,
      wave_index: state.wave_index,
      history: Enum.reverse(state.history)
    }
  end

  # ---------------------------------------------------------------------------
  # Parent-terminal writes (Phase 2a)
  # ---------------------------------------------------------------------------

  # The reload-guarded parent-terminal primitive (P2), modelled on
  # `ReactorRunner.ensure_failed/3`: reload by id, append the terminal ONLY from
  # a non-terminal status; an already-terminal reload is `:ok` (success), so a
  # `finish`-vs-timeout race never double-writes. The status check is required —
  # `WorkflowLog.append/4` errors on an already-terminal parent (the projection's
  # `:illegal` transition rolls it back), so a raw append is NOT a harmless
  # no-op. Returns `:ok` or `{:error, reason}`; never raises (the Ash code
  # interface returns tagged tuples, not exceptions).
  defp append_parent_terminal(parent_run_id, kind, payload, tenant, actor) do
    case WorkflowRun.by_id(parent_run_id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = parent} ->
        if Projection.terminal_status?(parent.status) do
          :ok
        else
          case WorkflowLog.append(parent, kind, payload, tenant: tenant, actor: actor) do
            {:ok, _event} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      other ->
        {:error, {:reload_failed, other}}
    end
  end

  # Failure-path terminalizer for the abnormal launch / run_sync paths
  # (reload/start/timeout/crash). Writes `run_failed` with a formatted reason
  # string into the `:string` `error` column. On these paths the ROOT-CAUSE error
  # wins (the caller returns it), so a terminalize failure here is logged loudly —
  # a parent left `:running` must be visible, never masked — and `:ok` is returned
  # so the caller proceeds to surface its original error.
  defp terminalize_parent(%WorkflowRun{} = parent, reason, tenant, actor) do
    case append_parent_terminal(
           parent.id,
           :run_failed,
           %{error: format_terminalize_reason(reason)},
           tenant,
           actor
         ) do
      :ok ->
        :ok

      {:error, write_error} ->
        Logger.error(
          "[RouteComposer] failed to terminalize parent #{parent.id} " <>
            "(reason: #{inspect(reason)}): #{inspect(write_error)} — parent may remain :running"
        )

        :ok
    end
  end

  # A json-safe subset for the converged parent's `result` column — NEVER artifact
  # values (those are still inline in child results in 2a; 2b ref-stores them).
  defp terminal_summary_subset(summary) do
    %{
      "terminal" => Atom.to_string(summary.terminal),
      "wave_index" => summary.wave_index,
      "final_route" => summary.final_route
    }
  end

  # The `run_failed` error string is formatted from the {terminal, reason} PAIR,
  # not `reason` alone (P3): `:not_converged`/`:deadlock` carry a nil reason, so
  # `Reason.format(reason)` would store the literal `"nil"`.
  defp format_terminal_error(:budget_exhausted, {:max_waves, max}),
    do: "budget_exhausted: max_waves=#{max}"

  defp format_terminal_error(:budget_exhausted, {:deadline, deadline}),
    do: "budget_exhausted: deadline=#{deadline}"

  defp format_terminal_error(:failed, reason), do: "failed: #{Reason.format(reason)}"
  defp format_terminal_error(kind, _reason), do: Atom.to_string(kind)

  # Abnormal-path reason → error string. Every caller passes a bare atom
  # (`:composer_timeout` / `:composer_reload_failed`) or a `{atom, inner}` tuple
  # (`{:composer_crashed, _}` / `{:composer_start_failed, _}`), so these two
  # clauses are exhaustive (a third catch-all is provably dead). A bare atom
  # drops its leading colon (`:composer_timeout` → `"composer_timeout"`, the
  # stored string the recovery tests assert); a tuple formats its inner reason.
  defp format_terminalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_terminalize_reason({tag, inner}) when is_atom(tag),
    do: "#{tag}: #{Reason.format(inner)}"

  # ---------------------------------------------------------------------------
  # Bounds
  # ---------------------------------------------------------------------------

  defp over_budget?(state) do
    state.wave_index >= state.max_waves or past_deadline?(state)
  end

  defp past_deadline?(%{deadline: nil}), do: false
  defp past_deadline?(%{deadline: deadline}), do: now_ms() >= deadline

  defp budget_reason(state) do
    if past_deadline?(state), do: {:deadline, state.deadline}, else: {:max_waves, state.max_waves}
  end

  defp deadline_at(nil), do: nil
  defp deadline_at(ms) when is_integer(ms) and ms > 0, do: now_ms() + ms

  defp now_ms, do: System.monotonic_time(:millisecond)
end
