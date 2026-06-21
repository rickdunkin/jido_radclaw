defmodule JidoClaw.RouteComposer do
  @moduledoc """
  The single-run composer loop (AR-2 §4; §14 Phase 2c — the run is now a pure
  function of durable state: composer deltas live in the parent's append-only
  `WorkflowEvent` log, state is re-projectable from that log, and the composer is
  a **supervised** process that rebuilds-from-log and resumes after a crash).

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
  (a restart re-dispatch / 2d recovery) dedupes to the existing child instead of
  double-running. The parent reaches a terminal status the moment the loop
  finishes — `finish/2` appends that terminal *before* it notifies.

  ## Durable composer state (Phase 2c)

  Composer state (`live`/`artifacts`/`ran`/`premises`/`prev_route`/`wave_index`)
  is now a projection of the parent's `WorkflowEvent` log. Each wave appends its
  deltas — `route_composed`/`wave_started` pre-launch (atomically, under the SAME
  FOR-UPDATE parent-terminal guard as the fold-path commit, via
  `JidoClaw.RouteComposer.Commit.start_wave/3`, so a cancel landing between waves
  can never leak a wave's start markers onto an already-terminal parent), then
  (atomically, with the `ComposerArtifact` ref
  `:pending → :active` flip) `wave_completed` +
  `signals_published`/`signals_retracted`/`artifacts_produced` on the fold path
  (`JidoClaw.RouteComposer.Commit.commit_wave/4`). Both fence the parent's *durable*
  state against a between-waves cancel; the wave's child-run launch is created
  afterward by `ReactorRunner` without a parent-terminal check, so a cancel in that
  narrow window still spawns an in-flight child whose fold is fenced at
  `commit_wave/4` (same as the accepted `async_nolink` "wave survives a kill") —
  fully closing that window is deferred Phase 4 work. The loop derives those content
  deltas by **diffing** pre/post `Fold` state, so the durable log equals the
  in-memory fold by construction (the equivalence invariant
  `JidoClaw.RouteComposer.Projection.project(seed, log) == in-memory`). `init/1`
  rebuilds from the log via that projection and resumes — a supervised composer
  that crashes mid-route restarts (`:transient`) and continues; a fresh run (log =
  `[run_started]`) projects to the seed unchanged. The five in-loop terminals are
  the semantically-named `route_*` kinds (`route_converged` → `:completed`; the
  four failures → `:failed`), all projecting onto the existing `WorkflowRun`
  statuses. Boot-time crash recovery (the `WorkflowRecovery` scan + child-wave
  re-launch) stays Phase 2d.

  ## In-memory state (a projection of the durable log)

  `catalog`, `live` (signal topics), `artifacts` (the provenance store `name →
  %{producer => ref}` — Phase 2b: opaque `ComposerArtifact` refs, the values
  encrypted at rest and resolved only at the wave boundary), `ran`, `premises`,
  `prev_route`, `wave_index`, the `parent_run_id` + the reloaded `parent` struct
  (the carrier for non-terminal appends), plus the run identity (`tenant`, `actor`,
  `context`), bounds (`max_waves`, the durable wall-clock `deadline_at_ms`,
  `wave_timeout_ms`), and `rebuild_attempts` (the resume retry counter). The
  evolving slice is rebuilt from the durable log on init/restart by
  `JidoClaw.RouteComposer.Projection`; `available` is **derived** from `artifacts`
  each tick, never stored.

  ## Driving / notification

  The loop ticks via `handle_continue(:tick, …)`. `finish/2` stamps the terminal
  + summary, **appends the parent's `route_*` terminal event first** (reload-guarded:
  `route_converged` → `:completed`, the four failure kinds → `:failed`), then —
  **only when there is a sync caller** (`maybe_notify/2`) — sends
  `{:route_composer, ref, {:done, summary}}` to `notify`, or
  `{:route_composer, ref, {:terminalize_failed, reason}}` if that durable write
  failed (so the caller never sees a falsely-successful `:done`). A **supervised**
  run has no `notify`; its durable terminal is the source of truth, so a **failed**
  terminal append is logged loudly (`log_supervised_terminal_failure/2`) — the
  parent is left `:running` for 2d boot recovery, not silently swallowed (the sync
  path surfaces the same failure via `maybe_notify/2`; a supervised run has nobody
  to tell). It returns
  `{:stop, :normal, state}` so a finished composer terminates rather than lingering
  (and, under `:transient`, is not restarted). The thin `run_sync/1` helper
  (`create_parent_run/1` → `start_composer/2` **unlinked** + `Process.monitor` +
  a bounded `receive`) is the test/CLI entry: a composer crash surfaces as a
  handled `:DOWN`, and on timeout/crash/start-failure the now-ownerless
  `:running` parent is terminalized live. Per wave the GenServer **blocks**
  inside `ReactorRunner.run/3` — acceptable for a single-run spike; Phase 4 moves
  wave execution to a `Task` + `handle_info` so the GenServer stays live across a
  gate park.

  ## Sensitive artifacts (Phase 2b)

  Artifact values no longer live inline anywhere durable: each wave's values are
  AshCloak-encrypted in `JidoClaw.Orchestration.ComposerArtifact` and every other
  surface carries only an opaque `art_<hex>` ref (resolved + decrypted solely at
  the wave boundary by `ArtifactContext`). A run launched with
  `sanitize_sensitive_context: true` (which then REQUIRES a bounded
  `:deadline_ms`, C2) marks every wave, so the subagent's derived durable output
  is sanitized at all six sinks — real `diff`/`approved-plan` values may now flow.

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
  alias JidoClaw.RouteComposer.Commit
  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Loop
  alias JidoClaw.RouteComposer.Projection, as: ComposerProjection
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.RouteComposer.WaveBuilder
  alias JidoClaw.Security.SensitiveScrub

  # The supervised lifecycle's named singletons (Phase 2c), started in
  # `JidoClaw.Application`'s always-on core group.
  @registry JidoClaw.RouteComposer.Registry
  @supervisor JidoClaw.RouteComposer.Supervisor

  @default_max_waves 20
  @default_timeout_ms 60_000
  @default_run_name "route_composer"

  # Per-wave wall-clock kill deadline (AR-2 Phase 2b C3) — a composer wave that
  # runs longer than this is killed and the child wave fails. ~5 min default.
  @default_wave_timeout_ms 300_000

  # Conservative ceiling for an orphaned subagent's own lifetime (its turn /
  # LLM / tool timeouts), added on top of the run deadline + one wave timeout to
  # size the marker-row TTL (C5). A fixed constant, NOT T_wave. ~10 min.
  @orphan_drain_ms 600_000

  # Rebuild-on-restart retry budget (Phase 2c): a transient parent-reload /
  # event-load error (DB blip) is retried a capped number of times with capped
  # exponential backoff before the composer stops `:normal` — leaving the parent
  # `:running` for 2d boot recovery, NOT crash-looping the supervised child.
  @max_rebuild_attempts 5
  @rebuild_backoff_ms 100
  @rebuild_backoff_max_ms 2_000

  # Dedupe-hit observe poll interval (Phase 2c): a restart re-dispatch may bind a
  # still-running in-flight child; the composer polls its terminal at this cadence
  # up to `wave_timeout_ms`.
  @observe_poll_ms 50

  # Terminal error kinds whose `:error` is scrubbed for a marked (sensitive) run:
  # the abnormal-path generic `:run_failed` plus the four loop `route_*` failures.
  # `:route_converged` is excluded — its payload is the opaque result subset.
  @scrubbable_error_kinds [
    :run_failed,
    :route_not_converged,
    :route_deadlocked,
    :route_budget_exhausted,
    :route_failed
  ]

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
  `:max_waves` (default `#{@default_max_waves}`), `:deadline_at_ms` (the durable
  wall-clock budget from the parent config, threaded by `start_composer/2` — C1),
  `:sanitize_sensitive_context` (AR-2 Phase 2b marker), `:wave_timeout_ms`
  (per-wave kill deadline, default `#{@default_wave_timeout_ms}`). The composer
  ticks immediately, so the parent run MUST
  already be committed (`create_parent_run/1`) before this is called — a wave
  could otherwise fire against an uncommitted parent. Used by 2c's supervised
  lifecycle (`ensure_started/2`), single-owner per `parent_run_id` via the
  `JidoClaw.RouteComposer.Registry`; `run_sync/1` uses the unlinked, unnamed
  `start_composer/2` instead.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    parent_run_id = Keyword.fetch!(opts, :parent_run_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(parent_run_id))
  end

  defp via_tuple(parent_run_id), do: {:via, Registry, {@registry, parent_run_id}}

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
    marked = Keyword.get(opts, :sanitize_sensitive_context, false)
    deadline_ms = Keyword.get(opts, :deadline_ms)

    with :ok <- validate_sensitive_deadline(marked, deadline_ms) do
      # The SOLE wall-clock read for this run (C1, P2-1): a durable
      # `config["deadline_at_ms"]` (unix-ms integer, JSONB-safe) the loop's
      # `past_deadline?` and 2d recovery both read — never a monotonic recompute.
      # Marked runs also stamp the durable `sanitize_sensitive_context` flag (P1b)
      # so `append_parent_terminal/5` can scrub a marked failure reason from a
      # reloaded parent (the live GenServer marker never reaches that write).
      config = parent_config(deadline_ms, marked)

      genesis =
        Ash.transact([WorkflowRun, WorkflowEvent], fn ->
          with {:ok, parent} <-
                 WorkflowRun.create(%{name: name, workflow_type: "composer", config: config},
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
  end

  # A marked (sensitive) composer run MUST carry a bounded `:deadline_ms` (C2) —
  # the retention ceiling's source of truth — else it is rejected at launch.
  defp validate_sensitive_deadline(true, ms) when is_integer(ms) and ms > 0, do: :ok

  defp validate_sensitive_deadline(true, _ms),
    do: {:error, {:start_failed, :deadline_required_for_sensitive_run}}

  defp validate_sensitive_deadline(false, _ms), do: :ok

  # `%{"deadline_at_ms" => unix_ms}` when a bounded deadline is set (else absent;
  # one `System.os_time(:millisecond)` read), plus `"sanitize_sensitive_context"
  # => true` for a marked run (P1b) — a boolean-in-JSONB that round-trips
  # cleanly. Both keys are read back from the reloaded parent.
  defp parent_config(ms, marked), do: maybe_mark(deadline_config(ms), marked)

  defp deadline_config(ms) when is_integer(ms) and ms > 0,
    do: %{"deadline_at_ms" => System.os_time(:millisecond) + ms}

  defp deadline_config(_ms), do: %{}

  defp maybe_mark(config, true), do: Map.put(config, "sanitize_sensitive_context", true)
  defp maybe_mark(config, false), do: config

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
    case GenServer.start(__MODULE__, build_start_opts(opts, parent)) do
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
  Find-or-start the **supervised** composer for `parent`, single-owner per
  `parent_run_id` (Phase 2c). Looks the run up in `JidoClaw.RouteComposer.Registry`;
  on a miss, starts a `restart: :transient` child under
  `JidoClaw.RouteComposer.Supervisor` (collapsing `{:already_started, pid}` for the
  start race) — mirroring `VFS.Workspace.start_fresh/2` /
  `CodeServer.ensure_project_runtime/1`. The composer exits `{:stop, :normal}` on
  every terminal, so `:transient` means "crash → restart → `init` rebuilds +
  resumes; normal terminal → no restart." Supervised runs have no sync caller, so
  `:notify`/`:ref` are omitted (the durable terminal is the source of truth).
  """
  @spec ensure_started(keyword(), WorkflowRun.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts, %WorkflowRun{} = parent) do
    case Registry.lookup(@registry, parent.id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> start_supervised_composer(build_start_opts(opts, parent), parent.id)
    end
  end

  defp start_supervised_composer(start_opts, parent_run_id) do
    child_spec = %{
      id: {__MODULE__, parent_run_id},
      start: {__MODULE__, :start_link, [start_opts]},
      restart: :transient
    }

    # Collapse the start race: `{:already_started, pid}` (a concurrent caller won)
    # is success; `{:ok, pid}` and a real `{:error, _}` both pass through.
    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # Thread the STORED durable deadline (C1, P2-1) from the reloaded :running
  # parent so `init/1` reads it back — no second wall-clock read, no monotonic
  # recompute (`nil` when the run is unbounded) — plus the `:parent_run_id`.
  # Shared by `start_composer/2` (unlinked) and `ensure_started/2` (supervised) so
  # sensitive-run TTL/deadline behavior cannot drift across the two launch paths.
  defp build_start_opts(opts, %WorkflowRun{} = parent) do
    opts
    |> Keyword.put(:parent_run_id, parent.id)
    |> Keyword.put(:deadline_at_ms, parent.config["deadline_at_ms"])
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
    # The durable wall-clock deadline read STRAIGHT from the parent config
    # (C1, P2-1) — never a monotonic recompute. nil ⇒ unbounded.
    deadline_at_ms = Keyword.get(opts, :deadline_at_ms)
    marked = Keyword.get(opts, :sanitize_sensitive_context, false)
    wave_timeout_ms = Keyword.get(opts, :wave_timeout_ms, @default_wave_timeout_ms)

    # The SEED state (Phase 2c): the static fields + the seeded `live`/`artifacts`/
    # `premises`. `handle_continue(:rebuild)` reloads the parent and folds the
    # durable event log onto this seed via `ComposerProjection.project/2` — a fresh
    # run (log = `[run_started]`) projects to the seed unchanged; a crashed-and-
    # restarted run resumes from the rebuilt state. `notify`/`ref` are optional —
    # a supervised run has no sync caller (the durable terminal is the truth).
    state = %{
      catalog: Keyword.fetch!(opts, :catalog),
      live: MapSet.new(Keyword.get(opts, :live, [])),
      artifacts: Keyword.get(opts, :artifacts, %{}),
      ran: MapSet.new(),
      premises: Keyword.get(opts, :premises, %{}),
      prev_route: [],
      wave_index: 0,
      parent_run_id: Keyword.fetch!(opts, :parent_run_id),
      parent: nil,
      tenant: Keyword.fetch!(opts, :tenant),
      actor: Keyword.fetch!(opts, :actor),
      context:
        seed_wave_context(
          Keyword.get(opts, :context, %{}),
          marked,
          deadline_at_ms,
          wave_timeout_ms
        ),
      max_waves: Keyword.get(opts, :max_waves, @default_max_waves),
      deadline_at_ms: deadline_at_ms,
      sanitize_sensitive_context: marked,
      wave_timeout_ms: wave_timeout_ms,
      notify: Keyword.get(opts, :notify),
      ref: Keyword.get(opts, :ref),
      rebuild_attempts: 0,
      history: [],
      terminal: nil,
      reason: nil,
      summary: nil
    }

    {:ok, state, {:continue, :rebuild}}
  end

  # ---------------------------------------------------------------------------
  # The tick loop + rebuild-from-log resume (Phase 2c)
  # ---------------------------------------------------------------------------

  # `handle_continue(:rebuild)` runs once after init and resumes from the durable
  # log; `:tick` turns the crank. `handle_info(:rebuild_retry)` (below) is the
  # `Process.send_after` re-arm on a transient rebuild failure — it arrives as an
  # info message, NOT a continue, so it needs its own head; both drive `do_rebuild/1`.
  @impl GenServer
  def handle_continue(:rebuild, state), do: do_rebuild(state)

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

  @impl GenServer
  def handle_info(:rebuild_retry, state), do: do_rebuild(state)

  defp do_rebuild(state) do
    case load_parent_and_events(state) do
      # Reloaded parent already terminal → don't resume a finished run.
      {:terminal, _parent} ->
        {:stop, :normal, state}

      {:ok, parent, events} ->
        rebuilt =
          ComposerProjection.project(%{state | parent: parent, rebuild_attempts: 0}, events)

        {:noreply, rebuilt, {:continue, :tick}}

      {:error, reason} ->
        retry_rebuild_or_stop(state, reason)
    end
  end

  defp load_parent_and_events(state) do
    with {:ok, %WorkflowRun{} = parent} <- reload_parent(state) do
      if Projection.terminal_status?(parent.status) do
        {:terminal, parent}
      else
        load_events(state, parent)
      end
    end
  end

  defp reload_parent(state) do
    case WorkflowRun.by_id(state.parent_run_id, tenant: state.tenant, actor: state.actor) do
      {:ok, %WorkflowRun{} = parent} -> {:ok, parent}
      {:ok, nil} -> {:error, :parent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_events(state, parent) do
    case WorkflowEvent.for_run(state.parent_run_id, tenant: state.tenant, actor: state.actor) do
      {:ok, events} -> {:ok, parent, events}
      {:error, reason} -> {:error, reason}
    end
  end

  # A transient parent-reload / event-load error (DB blip) must not crash a
  # `:transient` child into a restart loop. Retry a capped number of times with
  # capped exponential backoff; if still failing, log loudly and stop `:normal` —
  # leaving the parent `:running` for 2d boot recovery, NOT terminalizing a
  # recoverable run. (The supervisor's `max_restarts` is a backstop, not the
  # design.)
  defp retry_rebuild_or_stop(state, reason) do
    if state.rebuild_attempts < @max_rebuild_attempts do
      Process.send_after(self(), :rebuild_retry, rebuild_backoff(state.rebuild_attempts))

      Logger.warning(
        "[RouteComposer] rebuild attempt #{state.rebuild_attempts + 1} failed for parent " <>
          "#{state.parent_run_id} (#{inspect(reason)}); retrying"
      )

      {:noreply, %{state | rebuild_attempts: state.rebuild_attempts + 1}}
    else
      Logger.error(
        "[RouteComposer] rebuild failed for parent #{state.parent_run_id} after " <>
          "#{state.rebuild_attempts} attempts (#{inspect(reason)}); leaving parent :running for recovery"
      )

      {:stop, :normal, state}
    end
  end

  defp rebuild_backoff(attempt) do
    min(@rebuild_backoff_ms * Integer.pow(2, attempt), @rebuild_backoff_max_ms)
  end

  # Seed the per-wave reactor context with the conservative `RequestCorrelation`
  # TTL ceiling (C5): a marked run (which C2 guarantees has a bounded deadline)
  # needs an orphaned late-writing subagent's marker row to outlive realistic
  # late writes. `deadline_at_ms + T_wave + orphan_drain`, converted to a
  # `DateTime` (the field type is `:utc_datetime_usec`). Unmarked runs keep the
  # resource's default TTL.
  defp seed_wave_context(context, true, deadline_at_ms, wave_timeout_ms)
       when is_integer(deadline_at_ms) do
    expires_at_ms = deadline_at_ms + wave_timeout_ms + @orphan_drain_ms

    Map.put(
      context,
      :request_correlation_expires_at,
      DateTime.from_unix!(expires_at_ms, :millisecond)
    )
  end

  defp seed_wave_context(context, _marked, _deadline_at_ms, _wave_timeout_ms), do: context

  # ---------------------------------------------------------------------------
  # The wave
  # ---------------------------------------------------------------------------

  defp run_wave(dispatch, display, state) do
    stages = Enum.map(dispatch, &Map.fetch!(state.catalog, &1))

    case WaveBuilder.build_wave(stages, wave_index: state.wave_index) do
      {:ok, reactor} ->
        run_built_wave(reactor, stages, dispatch, display, state)

      # build_wave failure: no reactor ran, so there is no run to record.
      {:error, reason} ->
        finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # Resolve + decrypt the wanted artifacts into `:extra_context` (Phase 2b: the
  # only place a decrypted value re-enters live execution), then append the
  # pre-launch `route_composed` + `wave_started` markers (Phase 2c) under the
  # FOR-UPDATE parent-terminal guard (`Commit.start_wave/3`) — both BEFORE
  # `run_reactor`, so `wave_started` commits before the child run exists (2d
  # detects a pre-creation crash from it). A resolve/decrypt failure OR a failed
  # pre-launch append terminates the wave cleanly via `finish_failed` (no reactor
  # ran / the wave must not silently launch un-recorded), the same shape as the
  # `build_wave` failure clause. A `{:error, :parent_terminal}` from the guard stops
  # cleanly WITHOUT launching the wave or creating a child run — consistent with the
  # existing `commit_wave` `:parent_terminal` arm.
  #
  # NOTE — residual window (deferred Phase 4): `:parent_terminal` here fires only
  # when the parent was ALREADY terminal while `start_wave/3` held the lock. A cancel
  # landing AFTER `start_wave/3` commits but BEFORE `run_reactor` creates the child
  # still spawns an in-flight child (`ReactorRunner` does no parent-terminal check) —
  # its fold is fenced at `commit_wave/4`, the same accepted `async_nolink` "wave
  # survives a kill". Closing it needs composer cancellation / a child-create
  # terminal coupling, out of this follow-up's scope.
  defp run_built_wave(reactor, stages, dispatch, display, state) do
    with {:ok, extra_context} <-
           ArtifactContext.build(stages, state.artifacts, state.tenant, state.actor),
         :ok <- record_wave_start(dispatch, display, state) do
      reactor
      |> run_reactor(extra_context, state)
      |> handle_wave_result(dispatch, display, state)
    else
      # The run ended externally (operator cancel between waves): stop cleanly,
      # don't re-terminalize and don't launch the wave — consistent with the
      # `commit_wave` `:parent_terminal` arm in `handle_wave_value/5`.
      {:error, :parent_terminal} -> {:stop, :normal, state}
      {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # A launch-dedupe hit re-binds an already-seen wave. It cannot occur in a fresh
  # linear run (each `wave_index` runs exactly once), but the deterministic
  # `composer:<parent>:<wave_index>` key makes it reachable on a **restart
  # re-dispatch** (a live composer crash does NOT kill its in-flight wave — the
  # wave runs `async_nolink` and survives to finish durably), so the contract is
  # total: a `:completed` child folds its durable emission (recovering a dropped
  # fold); a still-`:running`/`:pending`/`:awaiting_approval` child is **observed**
  # (bounded read-only poll, not failed — Phase 2c) then re-branched; a terminal
  # `:failed`/`:cancelled`/`:abandoned` is a failed wave. This clause must precede
  # the generic `{:ok, value, run}` one (the existing-run tuple matches both).
  defp handle_wave_result({:ok, {:existing_run, _id}, run}, dispatch, display, state) do
    case run.status do
      :completed ->
        handle_wave_value(decode_emissions(run.result), run, dispatch, display, state)

      status when status in [:running, :pending, :awaiting_approval] ->
        observe_existing_child(run, dispatch, display, state)

      _terminal ->
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

  # The durable commit path (Phase 2c): compute the pure fold, derive the wave's
  # content deltas by DIFFING pre/post `Fold` state (so the durable log equals the
  # in-memory fold by construction — incl. a paired-verdict flip that retracts a
  # live signal, captured as `signals_retracted`), then atomically commit
  # `wave_completed` + content + `activate_for_wave` via `Commit.commit_wave/4`.
  # Only on `:ok` do we fold into memory and continue.
  defp handle_wave_value({:ok, emissions}, run, dispatch, display, state) do
    next_fold = Fold.fold(state, emissions)
    deltas = wave_deltas(state, next_fold, dispatch)

    case Commit.commit_wave(state.parent, state.wave_index, deltas, auth_opts(state)) do
      :ok ->
        next = record_wave(next_fold, dispatch, display, run, emissions)
        {:noreply, next, {:continue, :tick}}

      # The run ended externally (an operator cancel landed while the wave
      # returned): stop cleanly, don't re-terminalize (the terminal append already
      # no-ops a terminal parent).
      {:error, :parent_terminal} ->
        {:stop, :normal, state}

      # A commit leg failed: terminalize the parent `route_failed` — do NOT
      # fold/record/continue from memory as if the durable write had landed.
      {:error, reason} ->
        finish_failed(reason, run, dispatch, display, state)
    end
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
      idempotency_key: "composer:#{state.parent_run_id}:#{state.wave_index}",
      # A composer wave carries no definition_hash and isn't standalone-
      # replayable (the parent log is the replay unit), and its inputs include
      # the decrypted `:extra_context` — so omit the at-rest replay_inputs copy
      # entirely (A3/A4, P1). NOT `replay_inputs: nil` — AshCloak would encrypt
      # a present nil into ciphertext-of-nil; the key is omitted.
      omit_replay_inputs: true,
      # AR-2 Phase 2b: mark the wave sensitive (Theme B sinks sanitize the
      # subagent's derived durable output) and bound its wall-clock lifetime
      # (C3 — a hung wave is killed → child :failed).
      sanitize_sensitive_context: state.sanitize_sensitive_context,
      execution_timeout: state.wave_timeout_ms
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
  # Durable wave records (Phase 2c)
  # ---------------------------------------------------------------------------

  # Pre-launch markers, appended in order to the parent log BEFORE the wave's
  # reactor runs: `route_composed` (the merged display route + premises + live/
  # available snapshot, JSON-safe) then `wave_started` (wave_index, stages, the
  # canonical route/catalog hashes). Both go through `Commit.start_wave/3` — the
  # SAME FOR-UPDATE parent-terminal guard as the fold-path `commit_wave/4` — so a
  # cancel landing between waves can never leak these markers onto an already-terminal
  # parent (the wave's child-run launch is unfenced — see `run_built_wave/5`).
  # `{:error, :parent_terminal}` propagates so the
  # caller stops cleanly (the run already ended); any other failed append becomes
  # `{:error, {:wave_start_append_failed, _}}` so the caller terminalizes — the
  # wave never launches un-recorded.
  defp record_wave_start(dispatch, display, state) do
    markers = [
      route_composed: route_composed_payload(display, state),
      wave_started: wave_started_payload(dispatch, display, state)
    ]

    case Commit.start_wave(state.parent, markers, auth_opts(state)) do
      :ok -> :ok
      {:error, :parent_terminal} = halt -> halt
      {:error, reason} -> {:error, {:wave_start_append_failed, reason}}
    end
  end

  defp route_composed_payload(display, state) do
    json_safe(%{
      route: display.route,
      waves: display.waves,
      held: display.held,
      dropped: display.dropped,
      triggered_by: display.triggered_by,
      size: display.size,
      live: state.live,
      available: Fold.available(state.artifacts),
      premises: state.premises
    })
  end

  defp wave_started_payload(dispatch, display, state) do
    %{
      wave_index: state.wave_index,
      stages: dispatch,
      route_hash: canonical_hash(Enum.sort(display.route)),
      catalog_hash: canonical_hash(Enum.sort_by(state.catalog, &elem(&1, 0)))
    }
  end

  # The wave's content deltas, derived by DIFFING pre/post `Fold` state — the
  # construction that makes `ComposerProjection.project(seed, log)` equal the
  # in-memory fold. Signals are sorted lists (JSON-safe + deterministic);
  # `signals_retracted` captures a paired-verdict flip (NOT assumed empty);
  # artifacts are the new/changed `{name, producer, ref}` triples (bare ref).
  defp wave_deltas(state, next_fold, dispatch) do
    %{
      stages: dispatch,
      signals_published: signals_diff(next_fold.live, state.live),
      signals_retracted: signals_diff(state.live, next_fold.live),
      artifacts_produced: artifacts_diff(state.artifacts, next_fold.artifacts)
    }
  end

  defp signals_diff(from, subtract) do
    from
    |> MapSet.difference(subtract)
    |> Enum.sort()
  end

  defp artifacts_diff(old_store, new_store) do
    for {name, producers} <- new_store,
        {producer, entry} <- producers,
        get_in(old_store, [name, producer]) != entry do
      %{name: name, producer: producer, ref: bare_ref(entry)}
    end
  end

  defp bare_ref({:ref, ref}), do: ref
  defp bare_ref(other), do: other

  # Canonical sha256 hex over a deterministic term — robust if the hashes later
  # gain semantic weight; NOT `:erlang.phash2` (`feedback_canonical_fingerprint_term`).
  # In 2c they are correlation / catalog-drift-detection metadata only.
  defp canonical_hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # JSON-safe-ify a composer event payload: MapSet → sorted list, atom keys/values
  # → strings (e.g. `dropped`'s `:off_path`/`:unsatisfiable_input`), recursively.
  # The projection reads tolerantly (string keys). Load-bearing — a MapSet or
  # novel-atom payload fails to persist or round-trips wrong
  # (`feedback_pin_types_at_ash_persistence_boundaries`).
  defp json_safe(%MapSet{} = set) do
    set
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(&json_safe/1)
  end

  defp json_safe(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {json_safe_key(k), json_safe(v)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp json_safe(other), do: other

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: to_string(key)

  defp auth_opts(state), do: [tenant: state.tenant, actor: state.actor]

  # ---------------------------------------------------------------------------
  # Dedupe-hit observe (Phase 2c) — restart re-dispatch of a still-running child
  # ---------------------------------------------------------------------------

  # Bounded read-only poll of an in-flight existing child until it terminates or
  # `wave_timeout_ms` elapses (2b's per-wave T_wave bound), then re-branch:
  # `:completed` folds + commits its durable emission; any other terminal, or the
  # observe timeout, is a failed wave (conservative; 2d's fresh-wave_index
  # re-dispatch + gate-park handling extend this).
  defp observe_existing_child(run, dispatch, display, state) do
    case await_existing_child(run, state) do
      {:ok, %WorkflowRun{status: :completed} = done} ->
        handle_wave_value(decode_emissions(done.result), done, dispatch, display, state)

      {:ok, %WorkflowRun{} = other} ->
        finish_failed(
          {:existing_run_not_completed, other.status},
          other,
          dispatch,
          display,
          state
        )

      {:error, reason} ->
        finish_failed(reason, run, dispatch, display, state)
    end
  end

  defp await_existing_child(run, state) do
    poll_existing_child(run, state, System.monotonic_time(:millisecond) + state.wave_timeout_ms)
  end

  defp poll_existing_child(run, state, deadline) do
    case WorkflowRun.by_id(run.id, tenant: state.tenant, actor: state.actor) do
      {:ok, %WorkflowRun{status: status} = reloaded} ->
        cond do
          Projection.terminal_status?(status) ->
            {:ok, reloaded}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, {:observe_timeout, status}}

          true ->
            Process.sleep(@observe_poll_ms)
            poll_existing_child(run, state, deadline)
        end

      other ->
        {:error, {:observe_reload_failed, other}}
    end
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
  # Durable terminal append FIRST, then conditional notify (Phase 2a/2c). The
  # `kind` stays the bare symbol (`:converged`/`:not_converged`/…) — existing tests
  # assert `summary.terminal == :converged` and `terminal_summary_subset/1` stores
  # `Atom.to_string(summary.terminal)`; only the durable EVENT kind changes (to
  # `route_*`). The append happens inside `parent_terminal_notify/4`, so a
  # supervised run (no `notify`) still writes its terminal; `maybe_notify/2` then
  # sends only when there is a sync caller.
  defp finish(terminal, state) do
    {kind, reason} = classify_terminal(terminal)
    summary = summary(kind, reason, state)
    payload = parent_terminal_notify(kind, reason, summary, state)
    maybe_notify(state, payload)
    log_supervised_terminal_failure(payload, state)
    {:stop, :normal, %{state | terminal: kind, reason: reason, summary: summary}}
  end

  defp maybe_notify(%{notify: nil}, _payload), do: :ok

  defp maybe_notify(%{notify: notify, ref: ref}, payload) do
    send(notify, {:route_composer, ref, payload})
    :ok
  end

  # A supervised run (no sync caller) whose durable terminal append FAILED would
  # otherwise stop `:normal` silently — the parent stays `:running` with no owner
  # and no visible error (the sync path surfaces this via `maybe_notify/2`; a
  # supervised run has nobody to tell). Log loudly so the stuck parent is
  # operator-visible (and recoverable by the 2d boot scan). Still stop `:normal` —
  # NOT crash-loop the shared `:transient` supervisor on a DB blip (the
  # `retry_rebuild_or_stop` stance).
  defp log_supervised_terminal_failure({:terminalize_failed, reason}, %{notify: nil} = state) do
    Logger.error(
      "[RouteComposer] terminal append failed for parent #{state.parent_run_id} " <>
        "(#{inspect(reason)}); parent left :running for recovery"
    )
  end

  defp log_supervised_terminal_failure(_payload, _state), do: :ok

  defp parent_terminal_notify(:converged, _reason, summary, state) do
    state.parent_run_id
    |> append_parent_terminal(
      :route_converged,
      %{result: terminal_summary_subset(summary)},
      state.tenant,
      state.actor
    )
    |> notify_payload(summary)
  end

  defp parent_terminal_notify(kind, reason, summary, state) do
    state.parent_run_id
    |> append_parent_terminal(
      route_terminal_kind(kind),
      %{error: format_terminal_error(kind, reason)},
      state.tenant,
      state.actor
    )
    |> notify_payload(summary)
  end

  # The composer terminal symbol → its durable `route_*` event kind (`:converged`
  # is handled above → `:route_converged`); these four all project onto `:failed`.
  defp route_terminal_kind(:not_converged), do: :route_not_converged
  defp route_terminal_kind(:deadlock), do: :route_deadlocked
  defp route_terminal_kind(:budget_exhausted), do: :route_budget_exhausted
  defp route_terminal_kind(:failed), do: :route_failed

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
      artifacts: unwrap_refs(state.artifacts),
      ran: state.ran,
      wave_index: state.wave_index,
      history: Enum.reverse(state.history)
    }
  end

  # The summary's `artifacts` is display/notify-only (never re-resolved), so it
  # keeps the historical bare-ref shape: P2 tags the in-memory fold store as
  # `{:ref, ref}`, so unwrap each tagged ref back to the bare string here (seeds
  # stay bare). The durable parent `result` (`terminal_summary_subset/1`) omits
  # `artifacts` entirely, so it is unaffected.
  defp unwrap_refs(store) do
    Map.new(store, fn {name, producers} ->
      {name, Map.new(producers, fn {producer, entry} -> {producer, unwrap_ref(entry)} end)}
    end)
  end

  defp unwrap_ref({:ref, ref}), do: ref
  defp unwrap_ref(entry), do: entry

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
          scrubbed = scrub_terminal_payload(kind, payload, parent)

          case WorkflowLog.append(parent, kind, scrubbed, tenant: tenant, actor: actor) do
            {:ok, _event} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      other ->
        {:error, {:reload_failed, other}}
    end
  end

  # When the reloaded parent carries the durable Phase 2b marker, an error-bearing
  # terminal's reason string is replaced with the type-preserving placeholder
  # before the durable append — covering the abnormal-path `:run_failed`
  # (`format_terminalize_reason/1`) AND the four loop `route_*` failures
  # (`format_terminal_error/2`), both of which funnel here. `:route_converged` is
  # left alone — its payload is the opaque `terminal_summary_subset/1` (no artifact
  # values). Coarse by design (a marked budget_exhausted/timeout reason is also
  # redacted), consistent with the whole-write-when-marked policy; the run
  # `status: :failed` still conveys the failure.
  defp scrub_terminal_payload(kind, payload, %WorkflowRun{
         config: %{"sanitize_sensitive_context" => true}
       })
       when kind in @scrubbable_error_kinds,
       do: Map.replace(payload, :error, SensitiveScrub.redacted_text())

  defp scrub_terminal_payload(_kind, payload, _parent), do: payload

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

  # A json-safe subset for the converged parent's `result` column — never
  # artifact values (Phase 2b ref-stores them; the summary's `artifacts` are
  # opaque refs, and only `terminal`/`wave_index`/`final_route` are projected
  # here anyway).
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

  # Wall-clock against the durable `deadline_at_ms` (C1) — the live loop and 2d
  # recovery read the identical stored unix-ms value across a reboot. (Phase 2a's
  # monotonic deadline is gone; a monotonic clock is meaningless after restart.)
  defp past_deadline?(%{deadline_at_ms: nil}), do: false

  defp past_deadline?(%{deadline_at_ms: deadline_at_ms}),
    do: System.os_time(:millisecond) >= deadline_at_ms

  defp budget_reason(state) do
    if past_deadline?(state),
      do: {:deadline, state.deadline_at_ms},
      else: {:max_waves, state.max_waves}
  end
end
