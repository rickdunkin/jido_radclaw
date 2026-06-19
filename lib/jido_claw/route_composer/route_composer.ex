defmodule JidoClaw.RouteComposer do
  @moduledoc """
  The single-run composer loop (AR-2 §4, Phase 1 — the §14 "single-run loop"
  spike with **in-memory** composer state).

  A `GenServer` that turns the Alp River crank: **seed → `compose_route` →
  `merge_sticky` → dispatch the next unrun wave → run it on Reactor → fold the
  emitted signals/artifacts → recompose → converge.** Each wave is built into a
  `%Reactor{}` by `JidoClaw.RouteComposer.WaveBuilder` and run through the
  shipped `JidoClaw.Orchestration.ReactorRunner`, so every increment inherits the
  durable execution envelope (each wave persists its `WaveCollect` return to the
  child `WorkflowRun.result`).

  ## State (in-memory)

  `catalog`, `live` (signal topics), `artifacts` (the provenance store `name →
  %{producer => value}`), `ran`, `premises`, `prev_route`, `wave_index`, plus the
  run identity (`tenant`, `actor`, `context`) and bounds (`max_waves`,
  `deadline`). `available` is **derived** from `artifacts` each tick, never
  stored.

  ## Driving / notification

  The loop ticks via `handle_continue(:tick, …)`. `finish/2` stamps the terminal
  + summary, sends `{:route_composer, ref, {:done, summary}}` to `notify` for
  **every** terminal (convergence *and* failures), and returns `{:stop, :normal,
  state}` so a finished composer terminates rather than lingering (it is
  unsupervised in Phase 1). The thin `run_sync/1` helper (`start_link` with
  `notify: self()` + a bounded `receive`) is the test/CLI entry. Per wave the
  GenServer **blocks** inside `ReactorRunner.run/3` — acceptable for a single-run
  spike; Phase 4 moves wave execution to a `Task` + `handle_info` so the
  GenServer stays live across a gate park.

  ## Scope forks (Phase 1)

  Forward-only: the self-heal rerun loop (AR-4) is out of scope, so a ran lens
  with open `findings:<lens>` terminates `:not_converged` (it does not re-fire a
  fixer). Worker-only waves: `WaveBuilder` rejects non-`{:worker_template, _}`
  units, so the public loop is fixture-catalog-only.
  """

  use GenServer

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.RouteComposer.ArtifactContext
  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Loop
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.RouteComposer.WaveBuilder

  @default_max_waves 20
  @default_timeout_ms 60_000

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
  Start a composer.

  Required opts: `:catalog`, `:tenant`, `:actor`, `:notify`, `:ref`. Optional:
  `:live` / `:artifacts` / `:premises` (seed state), `:context` (the scope map
  merged into each wave's Reactor context), `:max_waves` (default
  `#{@default_max_waves}`), `:deadline_ms` (wall-clock budget from start). The
  composer ticks immediately and notifies `notify` with `{:route_composer, ref,
  {:done, summary}}` on its single terminal.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Start a composer with `notify: self()` and block on its terminal — the
  test/CLI entry. Returns `{:ok, summary}` or `{:error, :timeout}`.

  Links the composer (a hard crash propagates); a `:failed` terminal is a
  graceful stop carrying the summary, not a crash. Opts are passed through to
  `start_link/1` (minus `:notify` / `:ref`); `:timeout` (default
  `#{@default_timeout_ms}` ms) bounds the wait.

  On timeout the composer is unlinked and killed, so it leaks no orphaned
  crank-turning process and runs **no further waves** — but the wave already in
  flight is **not** cancelled: it runs under `async_nolink`
  (`JidoClaw.Orchestration.RunExecution`), survives the composer's death, and
  finishes durably "into the void" (its child `WorkflowRun` terminal still
  lands). True mid-wave cancellation is out of scope for this Phase-1 spike.
  """
  @spec run_sync(keyword()) :: {:ok, summary()} | {:error, :timeout}
  def run_sync(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    ref = make_ref()

    start_opts =
      opts
      |> Keyword.drop([:timeout])
      |> Keyword.merge(notify: self(), ref: ref)

    {:ok, pid} = start_link(start_opts)

    receive do
      {:route_composer, ^ref, {:done, summary}} -> {:ok, summary}
    after
      timeout ->
        # Unlink before kill so the timed-out crank-turner leaves no orphan and
        # its death can't propagate into a caller that already moved on. The
        # in-flight wave (async_nolink) is unaffected and finishes durably.
        Process.unlink(pid)
        Process.exit(pid, :kill)
        {:error, :timeout}
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

    with {:ok, reactor} <- WaveBuilder.build_wave(stages, wave_index: state.wave_index),
         extra_context = ArtifactContext.build(stages, state.artifacts),
         {:ok, value, run} <- run_reactor(reactor, extra_context, state) do
      # `decode_emissions` is run INSIDE the body (not as a `with` leg) so a
      # bad-wave-return error still carries the live `run` to `finish_failed`
      # (a `with`-leg failure would route through the run-less `{:error, reason}`
      # clause and drop the child_run_id).
      handle_wave_value(decode_emissions(value), run, dispatch, display, state)
    else
      # build_wave failure: no reactor ran, so there is no run to record.
      {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
      # run_reactor failure: `run` is the (possibly nil, on a pre-run error)
      # child WorkflowRun whose id the failed-wave history entry surfaces.
      {:error, reason, run} -> finish_failed(reason, run, dispatch, display, state)
    end
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
  # parallelizes the wave's independent steps). No `idempotency_key` — each wave
  # always runs. `ReactorRunner.run/3` returns error envelopes, never raises.
  defp run_reactor(reactor, extra_context, state) do
    ReactorRunner.run(reactor, %{extra_context: extra_context},
      tenant: state.tenant,
      actor: state.actor,
      async?: true,
      name: "route_composer:wave_#{state.wave_index}",
      context: state.context
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

  defp finish(terminal, state) do
    {kind, reason} = classify_terminal(terminal)
    summary = summary(kind, reason, state)
    send(state.notify, {:route_composer, state.ref, {:done, summary}})
    {:stop, :normal, %{state | terminal: kind, reason: reason, summary: summary}}
  end

  defp classify_terminal({:budget_exhausted, reason}), do: {:budget_exhausted, reason}
  defp classify_terminal({:failed, reason}), do: {:failed, reason}
  defp classify_terminal(kind) when is_atom(kind), do: {kind, nil}

  defp summary(kind, reason, state) do
    %{
      terminal: kind,
      reason: reason,
      final_route: state.prev_route,
      final_live: state.live,
      artifacts: state.artifacts,
      ran: state.ran,
      wave_index: state.wave_index,
      history: Enum.reverse(state.history)
    }
  end

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
