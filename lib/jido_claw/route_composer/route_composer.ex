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
  inside `ReactorRunner.run/3` — fine because nothing long-running executes
  inside it: a worker wave returns when its (stubbed/real) subagents finish, and
  a **gate** wave returns *promptly* at the `GateStep` halt (one DB write, no
  LLM) as `{:ok, {:paused, case_id}, run}`. The composer then **parks** by
  returning `{:noreply, parked}` from `handle_continue` and becomes an idle, live
  GenServer that wakes on `handle_info({:gate_resolved, …})` (Phase 4) — nothing
  executes during the park, so "stays live across a gate park" needs no
  off-process `Task` rearchitecture.

  ## Sensitive artifacts (Phase 2b)

  Artifact values no longer live inline anywhere durable: each wave's values are
  AshCloak-encrypted in `JidoClaw.Orchestration.ComposerArtifact` and every other
  surface carries only an opaque `art_<hex>` ref (resolved + decrypted solely at
  the wave boundary by `ArtifactContext`). A run launched with
  `sanitize_sensitive_context: true` (which then REQUIRES a bounded
  `:deadline_ms`, C2) marks every wave, so the subagent's derived durable output
  is sanitized at all six sinks — real `diff`/`approved-plan` values may now flow.

  ### Sensitive-park deadline (O-M2)

  A marked run parks on a gate like any other, but — because it carries a bounded
  `deadline_at_ms` — its park is time-boxed: `park_gate`/recovery re-park arm a
  `Process.send_after` timer keyed by a distinct `deadline_ref` identity, and once
  the durable deadline is genuinely past the run auto-abandons (child
  `run_abandoned` + case cancellation via the fenced
  `GateDisposition.deadline_abandon_parked_child/3`, then the parent finishes
  `:abandoned`), keeping a secret-bearing run inside its retention bound
  even when a human never decides. A decision that durably committed first wins
  the gate (`{:decided, _}` routes through the normal resolution path); the run
  still terminates at the next tick's deadline budget check. A NORMAL (unmarked)
  run has no such timer and waits on its gate **indefinitely by design**.

  ## Rerun consumers

  The rerun/invalidation **primitive** (Phase 4e — `stages_invalidated` with an
  optional `closed_wave_index`, `signals_retracted`, `artifacts_invalidated`, the
  per-stage rerun cap) now has THREE consumers: the plan-gate re-plan (reject
  opt-in + stale-approval retraction), the AR-8c reverse-verify loop, and the AR-4
  self-heal **fixer** loop (review → fix → re-review). AR-4 computes its rerun
  decision PRE-commit (`decide_rerun/2`) and WELDS the markers into the wave commit
  (the crash-window fix), while the verify + stale-approval paths keep their
  post-commit append (`maybe_rerun_after_findings/2`). So on a `code` path WITH a
  fixer, an open `findings:<lens>` re-fires the fixer — re-reviewing the touched
  and newly-summoned lenses — until every lens is clean (`:converged`) or the
  per-stage cap trips with findings still open (`:fix_failed`). `Loop.terminal`'s
  `:not_converged`-on-open-`findings:<lens>` survives only where NO fixer shares
  the lens's route: the `sketch-review` path (report-only).

  The fixer's re-review derivation reads the SAME `emissions` that
  `enforce_completion_signals/2` injects `@completion_signals` into BEFORE the fold,
  so the baseline `code-written` is guaranteed even if the LLM fixer omits it —
  closing the silent-converge gap where a fix-introduced regression in a never-flagged
  lens (e.g. correctness) would otherwise go un-re-reviewed.
  """

  use GenServer

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.CanonicalHash
  alias JidoClaw.Gates.ReviewStallGate
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cancellation
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.Gate
  alias JidoClaw.Orchestration.GateDisposition
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.ReviewIndependence
  alias JidoClaw.Orchestration.RunPubSub
  # The camus C1-3 normalizer — NOT JidoClaw.Triage.Verdict (different
  # subsystem; never alias both in one module).
  alias JidoClaw.Orchestration.Verdict
  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Orchestration.Verify.Evidence
  alias JidoClaw.Orchestration.Verify.Evidence.ACExtractor
  alias JidoClaw.Orchestration.Verify.Evidence.Assertions
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.ArtifactContext
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.Commit
  alias JidoClaw.RouteComposer.FindingKey
  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Loop
  alias JidoClaw.RouteComposer.Premises
  alias JidoClaw.RouteComposer.Premises.Lint
  alias JidoClaw.RouteComposer.PremisesContext
  alias JidoClaw.RouteComposer.Projection, as: ComposerProjection
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.SignalMatch
  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.RouteComposer.WaveBuilder
  alias JidoClaw.Security.Redaction.Transcript
  alias JidoClaw.Security.SensitiveScrub
  alias JidoClaw.Telemetry

  # The supervised lifecycle's named singletons (Phase 2c), started in
  # `JidoClaw.Application`'s always-on core group.
  @registry JidoClaw.RouteComposer.Registry
  @supervisor JidoClaw.RouteComposer.Supervisor

  # Deadline for the `:get_claim_token` ownership handshake in `ensure_started/2`
  # (WS3 P2). A live owner answers immediately (idle/parked) or once its current
  # wave returns; a call that exits (dead/stale registry entry) is treated as a
  # non-owner and evicted.
  @owner_call_timeout 5_000

  @default_max_waves 20
  @default_timeout_ms 60_000
  @default_run_name "route_composer"

  # AR-4: the completion signals whose OMISSION yields a SILENT `:converged`
  # (`Loop.terminal/2`): a no-lens producer that ran but didn't emit them is not
  # `held`, so `lenses_clean?` is vacuously true and the run converges with no
  # review (the implementer case) or before any work (the planner case). The
  # composer INJECTS these into the emitting producer's emission before the fold
  # (`enforce_completion_signals/2`), so a real LLM omission can't false-converge.
  #
  # Deliberately EXCLUDED: `tests-ready` (its omission by a COMPLETED test-author →
  # an HONEST `:deadlock` — the implementer stays held on its `until: tests-ready`
  # lock) and the conditional domain signals (`scope-shift` / `auth-surface` /
  # `significant-build` — the loop can't infer what a producer chose to touch).
  # Those stay self-reported via the producer `signals` fields. A BLOCKED
  # test-author no longer reaches that lock — it route-fails at the mapper
  # (`DefaultMapper.refuse_blocked_producer/2`), so `:deadlock` now covers only the
  # completed-but-`tests-ready`-omitted case.
  @completion_signals ["plan-ready", "code-written"]

  # Per-stage rerun cap (Phase 4e): a stage may be invalidated + re-fired at most
  # this many times before the run takes the `route_budget_exhausted` terminal —
  # the bound on a non-progressing re-plan loop (reused by AR-4/AR-8c reruns).
  @default_rerun_cap 2

  # Per-stage infra retry cap (camus C1-3, its INFRA_RETRIES): a lens stage whose
  # judge produced no usable verdict is re-offered at most this many times —
  # `count > cap` trips on the 4th attempt, so 3 attempts total, matching camus —
  # before the run takes the `review_infra_failed` terminal. A SEPARATE budget
  # from `rerun_cap`: an untrustworthy judge must never burn the fix loop's
  # findings-driven budget (nor terminalize as `fix_failed`).
  @default_infra_retry_cap 2

  # Per-wave wall-clock kill deadline (AR-2 Phase 2b C3) — a composer wave that
  # runs longer than this is killed and the child wave fails. ~5 min default.
  @default_wave_timeout_ms 300_000

  # Conservative ceiling for an orphaned subagent's own lifetime (its turn /
  # LLM / tool timeouts), added on top of the run deadline + one wave timeout to
  # size the marker-row TTL (C5). A fixed constant, NOT T_wave. ~10 min.
  @orphan_drain_ms 600_000

  # Review-stall gate details bounds (camus C1-4): at most this many decrypted
  # finding entries land on `AgentCase.details["findings"]` (the rest are an
  # explicit `findings_overflow_count`), and every string field in an entry is
  # truncated to the field cap AFTER redaction (redact-before-truncate — a
  # truncated secret could bisect out of pattern reach).
  @stall_findings_cap 20
  @stall_field_cap 400

  # The C3-2 operator hint rendered on the review-stall gate surfaces.
  @stall_resume_hint "The deterministic verify is green and certified — only review " <>
                       "findings remain. Waive every listed finding (key + severity + " <>
                       "optional note) and approve to complete this run as " <>
                       "done_with_findings (recorded as deferred debt); reject to fail " <>
                       "it as fix_failed."

  # Rebuild-on-restart retry budget (Phase 2c): a transient parent-reload /
  # event-load error (DB blip) is retried a capped number of times with capped
  # exponential backoff before the composer stops `:normal` — leaving the parent
  # `:running` for 2d boot recovery, NOT crash-looping the supervised child.
  @max_rebuild_attempts 5
  @rebuild_backoff_ms 100
  @rebuild_backoff_max_ms 2_000

  # Park-marker (`wave_paused`) append retry budget (Phase 4b): a transient
  # append failure at the park point is retried with the same capped backoff as
  # the rebuild path before the composer parks in-memory anyway (the parent stays
  # `:running`, the open case is a valid pending approval — recovery derives the
  # park from `wave_started` even without the marker). NEVER tears a validly-parked
  # gate down (only an externally-cancelled `:parent_terminal` does that).
  @max_wave_paused_attempts 5

  # Dedupe-hit observe poll interval (Phase 2c): a restart re-dispatch may bind a
  # still-running in-flight child; the composer polls its terminal at this cadence
  # up to `wave_timeout_ms`.
  @observe_poll_ms 50

  # Terminal error kinds whose `:error` is scrubbed for a marked (sensitive) run:
  # the abnormal-path generic `:run_failed` plus the loop `route_*` failures —
  # including AR-8c `:route_verify_failed` (its findings-derived error string is
  # sensitive; the scrub replaces ONLY `:error`, so the non-sensitive
  # `result.disposition: "verify_failed"` survives). `:route_converged` is
  # excluded — its payload is the opaque result subset.
  @scrubbable_error_kinds [
    :run_failed,
    :route_not_converged,
    :route_deadlocked,
    :route_budget_exhausted,
    :route_verify_failed,
    # AR-4: the fix-failed error string is the findings-derived exhausted lenses
    # (sensitive); the scrub replaces ONLY `:error`, so `result.disposition:
    # "fix_failed"` survives — exactly like `:route_verify_failed`.
    :route_fix_failed,
    # Camus C1-3: the review-infra error string names the exhausted stages
    # (coarse-scrubbed like its siblings); `result.disposition:
    # "review_infra_failed"` survives.
    :route_review_infra_failed,
    # Item 5: the tampered error string carries the bounded integrity detail
    # (coarse-scrubbed for a marked run); `result.disposition:
    # "verify_tampered"` + the opaque `report_ref` survive.
    :route_verify_tampered,
    :route_failed
  ]

  # The composer's durable scope subset (Phase 3b). `parent_config/3` persists
  # exactly these keys (JSON-safe) and `build_start_opts/2` restores them
  # RE-ATOMIZED — `AgentRunner.resolve_scope/2` reads atom keys
  # (`context[:session_uuid]`, `[:workspace_id]`, `[:project_dir]`, …), so a
  # string-keyed restored context would silently hit the `workspace_id →
  # "wf_<tag>"` / `project_dir → File.cwd!()` fallbacks. The fixed whitelist is
  # the only place a stored string key becomes an atom (no `String.to_atom/1` on
  # arbitrary input). Live `actor`/pids are deliberately NOT persisted — recovery
  # supplies its own (the established system-actor pattern).
  @persisted_context_keys ~w(
    project_dir tenant_id session_id session_uuid
    workspace_id workspace_uuid user_id agent_id agent_template
    forge_session_key
  )a

  @type terminal ::
          :converged
          | :done_with_findings
          | :not_converged
          | :deadlock
          | :budget_exhausted
          | :verify_failed
          | :verify_tampered
          | :fix_failed
          | :review_infra_failed
          | :failed
          | :rejected
          | :abandoned

  @type history_entry :: %{
          index: non_neg_integer(),
          stages: [String.t()],
          child_run_id: term(),
          route: [String.t()],
          held_before: %{optional(String.t()) => [String.t()]},
          emissions: [
            %{
              stage: String.t(),
              signals: [String.t()],
              artifacts: map(),
              outcome: StageEmission.outcome()
            }
          ],
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
  `:parent_run_id`. Optional: `:live` / `:artifacts` / `:premises` / `:ran` (seed
  state — `:ran` pre-marks stages as already-run, e.g. `["triage"]` for the
  Option-A front-door seed), `:context` (the scope map merged into each wave's
  Reactor context — persisted JSON-safe in the parent config and restored
  re-atomized at recovery, Phase 3b),
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
      # Slice 2 (OB1-3): the once-at-launch AC-assertion extraction — BEFORE
      # the transact (an LLM call never rides a DB transaction), persisted in
      # the parent config below so the LLM stays out of the per-wave fold and
      # a restart restores the same assertions.
      opts = maybe_extract_ac_assertions(opts)

      # The SOLE wall-clock read for this run (C1, P2-1): a durable
      # `config["deadline_at_ms"]` (unix-ms integer, JSONB-safe) the loop's
      # `past_deadline?` and 2d recovery both read — never a monotonic recompute.
      # Marked runs also stamp the durable `sanitize_sensitive_context` flag (P1b)
      # so `append_parent_terminal/5` can scrub a marked failure reason from a
      # reloaded parent (the live GenServer marker never reaches that write). 2d
      # adds the serialized `catalog` + bounds + seed `premises` so a node reboot
      # can reconstruct the launch inputs (`build_start_opts/2`).
      config = parent_config(opts, deadline_ms, marked)

      # WS2 genesis self-claim (D1b): generate the lease token OUTSIDE the txn so it
      # survives the rollback boundary for the post-commit struct-set + start_opts
      # freeze. It is stamped INSIDE the txn (`claim_genesis/2`) on the still-:pending
      # row, mirroring WS1's `:pending`-claim invariant.
      claim_token = Ash.UUID.generate()

      genesis =
        Ash.transact([WorkflowRun, WorkflowEvent, ComposerArtifact], fn ->
          with {:ok, parent} <-
                 WorkflowRun.create(%{name: name, workflow_type: "composer", config: config},
                   tenant: tenant,
                   actor: actor
                 ),
               # WS2: stamp the parent's lease nil → fresh token BEFORE `run_started`
               # flips it :running. The raw stamp UPDATE joins this Ash.transact
               # connection, so it sees the uncommitted :pending row. Claiming AFTER
               # `run_started` would leave a crash-in-the-gap as `:running + nil
               # claim_token` — a shape `:claimable` does NOT select (permanently
               # stranded); claiming HERE leaves either nothing (rolled back) or
               # `:running + claimed` (reclaimable on expiry).
               :ok <- claim_genesis(parent, claim_token),
               {:ok, _event} <-
                 WorkflowLog.append(parent, :run_started, %{}, tenant: tenant, actor: actor),
               # AFTER create + run_started (order matters, H11b): the seed rows'
               # parent FK + lineage read-your-writes the just-created parent. The
               # genesis seed `live`/`artifacts` events let `do_rebuild` reconstruct
               # them at recovery (no `live`/`artifacts` opts then); at launch they
               # fold idempotently onto the init seed (union / overwrite).
               :ok <- append_genesis_seed(parent, opts, tenant, actor) do
            parent
          end
        end)

      case genesis do
        # Thread the held token onto the reloaded struct so `build_start_opts/2` and
        # the reload-failure `terminalize_parent` both carry the genesis token.
        {:ok, parent} ->
          reload_running_parent(%{parent | claim_token: claim_token}, tenant, actor)

        {:error, reason} ->
          {:error, {:start_failed, reason}}
      end
    end
  end

  # WS2 genesis self-claim helper: stamp the parent's lease nil → `token` (the CAS
  # genesis case). `{:ok, :claimed}` is the only success; anything else rolls the
  # whole genesis back (no half-baked row). The `{:error, :lease_lost}` sentinel is
  # NOT matched outside the transact (the outer `case` stays generic) — routing a
  # specific atom through Ash.transact's polymorphic error channel would let
  # Dialyzer erase it (`project_ash_transact_dialyzer_error_channel`).
  defp claim_genesis(%WorkflowRun{id: id}, token) do
    case WorkflowLease.stamp(id, token, nil) do
      {:ok, :claimed} -> :ok
      {:ok, :lost} -> {:error, :lease_lost}
      {:error, reason} -> {:error, reason}
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
  # cleanly. 2d also threads (when present in opts) the serialized `catalog`
  # (`Catalog.to_map/1`, self-contained / drift-proof), `max_waves`,
  # `wave_timeout_ms`, and the seed `premises` (closing the pre-first-wave
  # durability gap — `route_composed` only carries premises *after* the first
  # wave). Every key is read back by `build_start_opts/2` at recovery.
  defp parent_config(opts, ms, marked) do
    ms
    |> deadline_config()
    |> maybe_mark(marked)
    |> maybe_put_catalog(Keyword.get(opts, :catalog))
    |> maybe_put("max_waves", Keyword.get(opts, :max_waves))
    |> maybe_put("wave_timeout_ms", Keyword.get(opts, :wave_timeout_ms))
    # Conditional-put (the present-nil rule): a restarted composer must keep the
    # caller's `infra_cap: 1` / `rerun_cap: 1`, not silently reset to the
    # default — item 6's stall/exhaustion trigger reads `rerun_cap`, so that
    # boundary must be restart-stable too (the former gap, now closed).
    |> maybe_put("infra_cap", Keyword.get(opts, :infra_cap))
    |> maybe_put("rerun_cap", Keyword.get(opts, :rerun_cap))
    # Item 5: the per-run verify-command override (scalar/argv/map — JSON-safe
    # by shape, validated at resolve time inside the verify stage).
    # Conditional-put so a restart keeps the caller's override.
    |> maybe_put("verify_override", Keyword.get(opts, :verify_override))
    # Slice 2 (OB1-3): the launch-extracted AC assertions (string-keyed maps,
    # JSON-safe by construction) — the `verify_override` precedent.
    |> maybe_put("ac_assertions", Keyword.get(opts, :ac_assertions))
    |> maybe_put_premises(Keyword.get(opts, :premises))
    |> maybe_put_context(Keyword.get(opts, :context))
  end

  # Extraction runs only when the launch premises carry acceptance criteria
  # and the caller did not inject `:ac_assertions` directly (tests / the
  # restart path, where config already holds them). Failure or an empty
  # extraction ⇒ Trace + no key — the run proceeds without slice 2
  # (fail-open, the scorer-failure precedent).
  defp maybe_extract_ac_assertions(opts) do
    with false <- Keyword.has_key?(opts, :ac_assertions),
         [_ | _] = pairs <- Premises.criteria_with_ids(Keyword.get(opts, :premises)) do
      case ACExtractor.extract(pairs) do
        {:ok, assertions} ->
          trace_ac_extraction(%{
            event: :ac_assertions_extracted,
            criteria: length(pairs),
            assertions: length(assertions)
          })

          if assertions == [], do: opts, else: Keyword.put(opts, :ac_assertions, assertions)

        {:error, reason} ->
          trace_ac_extraction(%{
            event: :ac_extract_failed,
            reason: String.slice(inspect(reason), 0, 200)
          })

          opts
      end
    else
      _present_or_no_criteria -> opts
    end
  end

  defp trace_ac_extraction(payload), do: JidoClaw.Trace.emit(:composer, payload)

  defp deadline_config(ms) when is_integer(ms) and ms > 0,
    do: %{"deadline_at_ms" => System.os_time(:millisecond) + ms}

  defp deadline_config(_ms), do: %{}

  defp maybe_mark(config, true), do: Map.put(config, "sanitize_sensitive_context", true)
  defp maybe_mark(config, false), do: config

  defp maybe_put_catalog(config, nil), do: config
  defp maybe_put_catalog(config, catalog), do: Map.put(config, "catalog", Catalog.to_map(catalog))

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  # Seed premises go through the same `json_safe/1` boundary
  # `route_composed_payload/2` uses, so atom values / stray structs never reach
  # JSONB (`feedback_pin_types_at_ash_persistence_boundaries`).
  defp maybe_put_premises(config, nil), do: config
  defp maybe_put_premises(config, premises), do: Map.put(config, "premises", json_safe(premises))

  # Persist the durable scope subset (Phase 3b): take only the whitelisted keys,
  # then push them through the same `json_safe/1` boundary premises use (which
  # stringifies atom keys), so a node reboot can rebuild wave scope. Live
  # `actor`/pids are excluded by the whitelist, so they never reach JSONB. A
  # caller with no context (the minimal `create_parent_run` path) stores nothing.
  defp maybe_put_context(config, context) when is_map(context) do
    case Map.take(context, @persisted_context_keys) do
      subset when map_size(subset) == 0 -> config
      subset -> Map.put(config, "context", json_safe(subset))
    end
  end

  defp maybe_put_context(config, _context), do: config

  # Record the seed `live`/`artifacts` the same way a wave records its deltas, so
  # `do_rebuild` rebuilds them by folding the genesis events (recovery passes no
  # seed opts). Seed `artifacts` are ref-stored (P1 — config/state carry only
  # refs): one `signals_published` (sorted live) then one `artifacts_produced`
  # (the seed store flattened to ref triples). Both are guarded on a non-empty
  # seed, so the minimal `create_parent_run(tenant:, actor:)` callers append
  # nothing (H5b). Any seed-insert / append failure flows the existing
  # `{:error, reason}` channel → `{:start_failed, reason}` (H11a).
  defp append_genesis_seed(parent, opts, tenant, actor) do
    with :ok <- append_genesis_signals(parent, Keyword.get(opts, :live, []), tenant, actor),
         :ok <-
           append_genesis_artifacts(parent, Keyword.get(opts, :artifacts, %{}), tenant, actor) do
      append_genesis_ran(parent, Keyword.get(opts, :ran, []), tenant, actor)
    end
  end

  # Option (A) — seed `triage ∈ ran` as a genesis `wave_completed(wave_index: -1)`,
  # so the composer's trigger step skips the (non-executable `{:seed, _}`) triage
  # stage and never asks `WaveBuilder` to build a seed stage. The projection's
  # `wave_completed` fold unions the stages into `ran` and advances
  # `wave_index = max(0, -1 + 1) = 0`, so the first real wave is still wave 0.
  # `wave_completed` is non-status-authority (`commit.ex:14-24`), appended after
  # `run_started` flips `:running`, so it is transaction-legal. At recovery (no
  # `:ran` opt) the genesis event alone rebuilds `ran` identically (Phase 3b),
  # preserving projection-equivalence.
  defp append_genesis_ran(_parent, [], _tenant, _actor), do: :ok

  defp append_genesis_ran(parent, ran, tenant, actor) do
    append_genesis_event(
      parent,
      :wave_completed,
      %{wave_index: -1, stages: Enum.sort(ran)},
      tenant,
      actor
    )
  end

  defp append_genesis_signals(parent, live, tenant, actor) do
    case Enum.sort(live) do
      [] ->
        :ok

      signals ->
        append_genesis_event(parent, :signals_published, %{signals: signals}, tenant, actor)
    end
  end

  defp append_genesis_artifacts(_parent, artifacts, _tenant, _actor)
       when map_size(artifacts) == 0,
       do: :ok

  defp append_genesis_artifacts(parent, artifacts, tenant, actor) do
    case store_seed_rows(parent, artifacts, tenant, actor) do
      {:ok, []} ->
        :ok

      {:ok, triples} ->
        append_genesis_event(parent, :artifacts_produced, %{artifacts: triples}, tenant, actor)

      {:error, _reason} = error ->
        error
    end
  end

  # Flatten the seed store (`name → producer → value`, H14) to ref triples,
  # `store_pending`-ing each value as a **seed** row (`child_run_id: nil`,
  # `producer:`, `wave_index: -1`, `term: value`) so the value lives encrypted at
  # rest (P1) and the genesis `artifacts_produced` carries only the bare ref.
  defp store_seed_rows(parent, artifacts, tenant, actor) do
    seed_pairs(artifacts)
    |> Enum.reduce_while({:ok, []}, fn {name, producer, value}, {:ok, acc} ->
      case store_seed_row(parent, name, producer, value, tenant, actor) do
        {:ok, ref} -> {:cont, {:ok, [artifact_triple(name, producer, ref) | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, triples} -> {:ok, Enum.reverse(triples)}
      {:error, _reason} = error -> error
    end
  end

  defp seed_pairs(artifacts) do
    for {name, producers} <- artifacts, {producer, value} <- producers do
      {name, producer, value}
    end
  end

  defp store_seed_row(parent, name, producer, value, tenant, actor) do
    attrs = %{
      ref: generate_ref(),
      name: name,
      producer: producer,
      term: value,
      child_run_id: nil,
      parent_run_id: parent.id,
      wave_index: -1
    }

    case ComposerArtifact.store_pending(attrs, tenant: tenant, actor: actor) do
      {:ok, %ComposerArtifact{ref: ref}} -> {:ok, ref}
      {:error, reason} -> {:error, {:seed_artifact_store_failed, name, reason}}
    end
  end

  defp generate_ref, do: JidoClaw.Refs.mint("art_")

  defp append_genesis_event(parent, kind, payload, tenant, actor) do
    case WorkflowLog.append(parent, kind, payload, tenant: tenant, actor: actor) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
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
    case GenServer.start(__MODULE__, build_start_opts(opts, parent)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        terminalize_parent(
          parent,
          {:composer_start_failed, reason},
          Keyword.fetch!(opts, :tenant),
          Keyword.fetch!(opts, :actor),
          parent.claim_token
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

  On a **hit**, the registered composer is returned ONLY if it is still the current
  owner — it holds `parent.claim_token` by exact identity (`ensure_current_owner/3`).
  A stale owner (left when a live reclaim's `claim_next` rotated the parent token —
  WS3 P2) or a dead/stale registry entry is evicted and restarted so the reclaimed
  token reaches a live process; otherwise recovery would hand back a composer holding
  the OLD token and the rotated token would never run (the swallowed-reclaim bug).

  `opts[:terminalize_on_failure?]` (default `false`) is **opt-in** orphan cleanup
  (Phase 3b / R3-P1): the **front door** passes `true` so a `create_parent_run`
  success + failed start yields a clean terminal parent behind its "couldn't
  start" ack. **Boot recovery omits it** and leaves a transiently-unstartable
  parent `:running` so the next boot retries — never fail a recoverable route.
  """
  @spec ensure_started(keyword(), WorkflowRun.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts, %WorkflowRun{} = parent) do
    case Registry.lookup(@registry, parent.id) do
      [{pid, _value}] -> ensure_current_owner(pid, opts, parent)
      [] -> start_or_terminalize(opts, parent)
    end
  end

  # A registered composer is the current owner ONLY if it still holds the run's
  # (possibly just-reclaimed) token, by exact identity. A stale owner — left when
  # `claim_next` rotated the parent token (P2) — or a dead/stale registry entry
  # (call exits) is evicted and restarted so the reclaimed token reaches a live
  # process. Launch (miss) and boot/unleased (nil==nil) are no-ops. `terminate_child`
  # is synchronous (old pid dead on return), so the caller sees the new pid at once.
  defp ensure_current_owner(pid, opts, parent) do
    if current_owner?(pid, parent.claim_token) do
      {:ok, pid}
    else
      _ = DynamicSupervisor.terminate_child(@supervisor, pid)
      await_deregistered(parent.id)
      start_or_terminalize(opts, parent)
    end
  end

  # Ownership is EXACT equality `held == incoming`, NOT the nil-permissive fence
  # helper `token_mismatch?/2`: a binary reclaim token against a nil/old held token
  # must NOT count as the current owner (that is the swallowed-reclaim bug). Only a
  # nil incoming matches a nil held owner (unleased idempotency); a binary incoming
  # requires the live owner to return that exact binary. A call that exits (dead or
  # stale registry entry) is a non-owner → evict (the `VFS.Workspace` precedent).
  defp current_owner?(pid, incoming_token) do
    GenServer.call(pid, :get_claim_token, @owner_call_timeout) == incoming_token
  catch
    :exit, _ -> false
  end

  defp start_or_terminalize(opts, parent) do
    case start_supervised_composer(build_start_opts(opts, parent), parent.id) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} = error -> maybe_terminalize_orphan(opts, parent, reason, error)
    end
  end

  # Registry frees the via-tuple key async after `terminate_child`; wait (bounded)
  # before restarting so `start_supervised_composer`'s `{:already_started, pid}`
  # collapse can't hand back the dead pid. Mirrors the test `await_deregistered/2`.
  defp await_deregistered(parent_id, tries \\ 200) do
    cond do
      Registry.lookup(@registry, parent_id) == [] ->
        :ok

      tries > 0 ->
        Process.sleep(10)
        await_deregistered(parent_id, tries - 1)

      true ->
        :ok
    end
  end

  # Opt-in: terminalize a created-but-unstartable parent (front door only). Boot
  # recovery (default `false`) leaves it `:running` for the next boot's retry. The
  # original `error` passes through either way (the caller surfaces it).
  defp maybe_terminalize_orphan(opts, parent, reason, error) do
    if Keyword.get(opts, :terminalize_on_failure?, false) do
      terminalize_parent(
        parent,
        {:composer_start_failed, reason},
        Keyword.fetch!(opts, :tenant),
        Keyword.fetch!(opts, :actor),
        parent.claim_token
      )
    end

    error
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

  @doc """
  Decode a serialized `config["catalog"]` for a composer launch/resume:

    * `{:ok, catalog}` — present and coherent (`CatalogValidator` clean). `config`
      is authoritative, so this wins over any opts catalog.
    * `:absent` — no serialized catalog (the minimal `create_parent_run` lifecycle
      path); the caller MAY fall back to an opts catalog.
    * `:invalid` — present but un-decodable (atom-unsafe tag) OR incoherent
      (structural/semantic). `config` is authoritative, so an invalid one is NOT
      overridden by a possibly-stale opts catalog — it behaves like "no start".
  """
  @spec decode_config_catalog(term()) :: {:ok, %{String.t() => Stage.t()}} | :absent | :invalid
  def decode_config_catalog(nil), do: :absent

  def decode_config_catalog(serialized) do
    case Catalog.from_map(serialized) do
      nil ->
        :invalid

      catalog when map_size(catalog) == 0 ->
        # A zero-stage catalog decodes + validates vacuously clean but can only
        # false-converge (no stage to dispatch) — fail closed, same as malformed.
        :invalid

      catalog ->
        if CatalogValidator.validate(catalog) == [], do: {:ok, catalog}, else: :invalid
    end
  end

  # Reconstruct the composer's launch inputs from the durable parent `config`
  # (Phase 2d), so a cold-boot recovery (`ensure_started/2` with no
  # catalog/seed/bounds opts) resumes with the same inputs the launch had — the
  # config is **authoritative**, with opts as the fallback for the minimal
  # `create_parent_run(tenant:, actor:)` lifecycle-test path (config carries no
  # catalog there, H12). Shared by `start_composer/2` (unlinked) and
  # `ensure_started/2` (supervised) so sensitive-run TTL/deadline behavior cannot
  # drift across the two launch paths.
  #
  #   * `:deadline_at_ms` — the STORED durable wall-clock budget (C1, P2-1;
  #     `nil` when unbounded), never a recompute.
  #   * `:catalog` — `decode_config_catalog(config["catalog"])`: a valid config
  #     catalog wins (config-authoritative / drift-proof); **absent** → opts
  #     fallback (the minimal-launch path); **invalid** (un-decodable or
  #     incoherent) → refuse, no stale-opts fallback (behaves like "no start").
  #   * `:premises` — restore the seed premises from config (the pre-first-wave
  #     gap; `route_composed` only carries premises once waves run).
  #   * `:max_waves` / `:wave_timeout_ms` — config-then-opts-then-default (the
  #     TTL ceiling in `seed_wave_context` depends on `wave_timeout_ms`, H23).
  #   * `:sanitize_sensitive_context` — **the critical P1 fix (H23)**: a recovered
  #     sensitive run MUST keep its marker (else its waves write plaintext), so
  #     read it from config — safe for launch too (config was set from the launch
  #     marker at genesis).
  #   * `:context` — restore the durable scope subset RE-ATOMIZED (Phase 3b /
  #     R2-P1/R3-P1): `json_safe/1` stringified the keys at persist time, but
  #     `AgentRunner.resolve_scope/2` reads atoms, so `restore_context/1` maps the
  #     fixed whitelist back to atom keys. Run on BOTH launch and recovery (config
  #     is authoritative), so a recovered run keeps the SAME VFS/session scope
  #     (incl. `workspace_id`) rather than the `"wf_<tag>"` fallback.
  #
  # `live`/`artifacts` are NOT restored here: they ride opts at launch and are
  # absent at recovery, where the genesis events rebuild them in `do_rebuild`.
  defp build_start_opts(opts, %WorkflowRun{config: config} = parent) do
    opts
    |> Keyword.put(:parent_run_id, parent.id)
    # WS2: FREEZE the parent's lease token into the supervised child spec so it
    # survives a `:transient` restart (the held token must come from the frozen
    # start_opts, never a re-read of the row — a restarted zombie that re-read the
    # row would renew the RECLAIMER's token and steal the claim back). The reload
    # path (recovery / WS3 reclaim) carries the persisted/claim_next token through
    # the same seam. `nil` (a `loop_state` raw-state tick) ⇒ unleased.
    |> Keyword.put(:claim_token, parent.claim_token)
    |> Keyword.put(:deadline_at_ms, config["deadline_at_ms"])
    |> put_start_catalog(config["catalog"])
    |> Keyword.put(:premises, config_then_opts(config, opts, :premises, %{}))
    |> Keyword.put(:max_waves, config_then_opts(config, opts, :max_waves, @default_max_waves))
    |> Keyword.put(
      :wave_timeout_ms,
      config_then_opts(config, opts, :wave_timeout_ms, @default_wave_timeout_ms)
    )
    |> Keyword.put(
      :infra_cap,
      config_then_opts(config, opts, :infra_cap, @default_infra_retry_cap)
    )
    |> Keyword.put(:rerun_cap, config_then_opts(config, opts, :rerun_cap, @default_rerun_cap))
    # Item 5: config-then-opts (nil when neither — the resolve chain then walks
    # config.yaml → auto-detect). A nil put is harmless here: init's own
    # default for the key is nil.
    |> Keyword.put(:verify_override, config_then_opts(config, opts, :verify_override, nil))
    # Slice 2 (OB1-3): the persisted AC assertions (string-keyed maps — the
    # JSONB round-trip preserves them byte-identically). nil ⇒ slice 2 off.
    |> Keyword.put(:ac_assertions, config_then_opts(config, opts, :ac_assertions, nil))
    |> Keyword.put(:sanitize_sensitive_context, config["sanitize_sensitive_context"] == true)
    |> Keyword.put(:context, start_context(config["context"], opts[:context]))
  end

  # Config-then-opts-then-default: the persisted config key is the json_safe
  # string form of the launch opt key, so one resolver serves every restored
  # bound/override.
  defp config_then_opts(config, opts, key, default),
    do: config[Atom.to_string(key)] || opts[key] || default

  # Re-atomize the persisted (string-keyed) context subset back to the atom keys
  # `AgentRunner.resolve_scope/2` reads. Maps ONLY the fixed whitelist (no
  # `String.to_atom/1` on arbitrary input), dropping absent keys. Only ever called
  # with a persisted map — `start_context/2` handles the absent-context (`nil`) case
  # upstream (empty map / opts fallback) before delegating here.
  defp restore_context(context) when is_map(context) do
    @persisted_context_keys
    |> Enum.flat_map(fn key ->
      case context[Atom.to_string(key)] do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Map.new()
  end

  # Config is authoritative (recovery carries no opts context): restore the persisted,
  # re-atomized subset when present. When config has no "context" — the minimal
  # `create_parent_run(tenant:, actor:)`-then-start-with-context launch path, which
  # persists no subset — fall back to the caller's opts context (mirroring the
  # `config[...] || opts[...]` shape the sibling bounds already use), so an explicit
  # launch `:context` is honored rather than clobbered to %{}.
  defp start_context(nil, opts_context) when is_map(opts_context), do: opts_context
  defp start_context(nil, _opts_context), do: %{}
  defp start_context(config_context, _opts_context), do: restore_context(config_context)

  # Three-way config-authoritative catalog resolution (`decode_config_catalog/1`):
  # a valid config catalog wins; `:absent` falls back to any opts catalog (the
  # minimal-launch lifecycle path); `:invalid` (un-decodable or incoherent)
  # refuses — NO stale-opts fallback.
  #
  # `start_opts` is built FROM `opts`, so a direct `start_composer/2` /
  # `ensure_started/2` caller may ALREADY have seeded a (valid) `:catalog`. That
  # makes `:invalid` actively DELETE the key, not merely decline to add one —
  # returning `start_opts` unchanged would leave the stale opts catalog in place
  # and let `init/1` launch on it (a config-authoritative-contract violation).
  # With the key stripped, `init/1`'s `Keyword.fetch!(opts, :catalog)` raises →
  # `{:start_failed, _}` rather than starting a composer on a corrupt config or a
  # possibly-stale opts catalog (the inverse of the present-nil trap,
  # `project_tool_context_present_nil_map_get_trap`: here we remove the key so the
  # fetch fails closed).
  defp put_start_catalog(start_opts, serialized) do
    case decode_config_catalog(serialized) do
      {:ok, catalog} -> Keyword.put(start_opts, :catalog, catalog)
      # minimal-launch lifecycle path
      :absent -> put_opts_catalog(start_opts)
      # authoritative-but-corrupt → strip any stale opts catalog, fail closed
      :invalid -> Keyword.delete(start_opts, :catalog)
    end
  end

  # The `:absent` minimal-launch path (config carries no catalog): keep an opts
  # catalog if the caller supplied one, but only PUT a resolved key — never
  # `catalog: nil` (which would defeat `init/1`'s `Keyword.fetch!`), so a launch
  # with no catalog anywhere still raises → `{:start_failed, _}`.
  defp put_opts_catalog(start_opts) do
    case start_opts[:catalog] do
      nil -> start_opts
      catalog -> Keyword.put(start_opts, :catalog, catalog)
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
    * `{:error, :stopped_without_terminal}` — the composer stopped cleanly without
      delivering a terminal to this caller (a lease fence/reclaim, an external
      cancel, a zombie restart, or a left-`:running`-for-recovery stop). The parent
      is intentionally untouched here — re-read it if the cause matters.
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
          | {:error, :stopped_without_terminal}
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

  # The composer is unlinked + monitored, so it reaches this caller four ways:
  #   * a `{:done, _}` notify — it appended its own terminal in finish/2;
  #   * a `{:terminalize_failed, _}` notify — that terminal write failed;
  #   * an abnormal `:DOWN` (died before finish/2) or a timeout — the parent is left
  #     `:running`, so terminalize it live;
  #   * a benign `:DOWN :normal` with NO preceding notify — a no-notify
  #     `{:stop, :normal}` arm (a lease fence/reclaim, the parent already terminal, a
  #     zombie restart, or a stop that left the parent `:running` for recovery). This
  #     one MUST NOT terminalize: the parent is already terminal or owned by another
  #     node, so a live terminalize would be wrong (a stale-token one is a fenced
  #     no-op anyway) — return `:stopped_without_terminal` promptly instead.
  # When finish/2 DID notify, it sends before it stops, so Erlang's signal-ordering
  # guarantee enqueues the `{:done, _}`/`{:terminalize_failed, _}` ahead of the
  # `:DOWN :normal`; clause 1/2 is tried first and wins — the benign-DOWN clause
  # fires only when no notify preceded the clean stop.
  defp await_terminal(parent, pid, notify_ref, monitor_ref, timeout, tenant, actor) do
    receive do
      {:route_composer, ^notify_ref, {:done, summary}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, summary}

      {:route_composer, ^notify_ref, {:terminalize_failed, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:terminalize_failed, reason}}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} when reason != :normal ->
        terminalize_parent(parent, {:composer_crashed, reason}, tenant, actor, parent.claim_token)
        {:error, {:crashed, reason}}

      {:DOWN, ^monitor_ref, :process, ^pid, :normal} ->
        {:error, :stopped_without_terminal}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        terminalize_parent(parent, :composer_timeout, tenant, actor, parent.claim_token)
        {:error, :timeout}
    end
  end

  # Reload the just-created parent: the `create` struct is still `:pending`, but
  # `run_started` committed in the same transaction, so the DB row is `:running`.
  defp reload_running_parent(parent, tenant, actor) do
    case WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = running} ->
        # Composer parents never ride ReactorMiddleware (the reactor-run start
        # announcer), so the lifecycle `run_started` is broadcast here — the
        # first post-commit point after the mint `Ash.transact` (every producer
        # entrance funnels through `create_parent_run/1`; boot recovery never
        # re-mints). Shielded: a raising PubSub must not fail the committed
        # mint (`notify_best_effort/3`).
        notify_best_effort("run_started", running.id, fn ->
          RunPubSub.broadcast_run_started(running)
        end)

        {:ok, running}

      other ->
        # run_started committed → the parent is :running and ownerless.
        # Terminalize before surfacing the error so we never leak a
        # perpetually-:running parent. WS2: thread the genesis token (carried on the
        # struct from create_parent_run) so the fence accepts this owner's terminal.
        terminalize_parent(parent, :composer_reload_failed, tenant, actor, parent.claim_token)
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
      # Pre-run `ran` (Option A): a launch seeds `ran: ["triage"]` so the composer
      # starts as-if-triage-ran. At recovery opts carry no `:ran` and the genesis
      # `wave_completed(-1)` event rebuilds it identically via the projection.
      ran: MapSet.new(Keyword.get(opts, :ran, [])),
      premises: Keyword.get(opts, :premises, %{}),
      prev_route: [],
      wave_index: 0,
      parent_run_id: Keyword.fetch!(opts, :parent_run_id),
      parent: nil,
      # WS2: the frozen lease token (nil ⇒ unleased — every runtime lease behavior
      # is gated on `is_binary(claim_token)`, so a nil-token tick is byte-identical
      # to the pre-WS2 path: no preflight, no sidecar, no marker/terminal fence).
      claim_token: Keyword.get(opts, :claim_token),
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
      # Gate park (Phase 4): `parked` holds `%{wave_index, case_id, child_run_id,
      # dispatch, display}` while the composer is parked on a gate (else nil), and
      # `gates_subscribed` is the once-only `RunPubSub.subscribe_gates/0` flag so a
      # restart/re-park doesn't double-subscribe.
      parked: nil,
      gates_subscribed: false,
      # Review-stall park (camus C1-4, next-ten #6): a SIBLING park slot —
      # never the child-based `parked` above (all child-park consumers stay
      # untouched). Set while the composer is parked on its own run-bound
      # `:review_stall` case: `%{case_id, fingerprint, lenses, result,
      # details}` (else nil), with its own deadline-timer pair below.
      stall_parked: nil,
      # Sensitive-park deadline (O-M2): a `:sanitize_sensitive_context` run with a
      # durable `deadline_at_ms` arms a park-time timer so it can't outlive its
      # secret-retention bound while gate-parked (normal runs wait indefinitely).
      # `deadline_ref` is a distinct `make_ref/0` identity the handler match-guards
      # against a stale fire; `timer_ref` is the `Process.send_after` handle to
      # cancel. Both nil unless armed. The `stall_*` pair is the review-stall
      # park's parallel timer identity (the two parks never coexist, but shared
      # fields would let a stale fire from one dispose the other).
      deadline_ref: nil,
      timer_ref: nil,
      stall_deadline_ref: nil,
      stall_timer_ref: nil,
      # Rerun primitive (Phase 4e): `rerun_counts` is the per-stage invalidation
      # tally the rerun cap reads (rebuilt from the log by `ComposerProjection`),
      # `rerun_cap` the ceiling before `route_budget_exhausted`.
      rerun_counts: %{},
      rerun_cap: Keyword.get(opts, :rerun_cap, @default_rerun_cap),
      # Infra retry primitive (camus C1-3): `infra_counts` is the per-stage
      # no-usable-verdict tally (rebuilt from `stage_infra` events by
      # `ComposerProjection`), `infra_cap` the ceiling before
      # `review_infra_failed` — persisted in the parent config so a restart
      # keeps a caller's override.
      infra_counts: %{},
      infra_cap: Keyword.get(opts, :infra_cap, @default_infra_retry_cap),
      # Camus C1-5 (next-ten #6): per-lens finding-identity rounds — `%{lens =>
      # %{round, prior_keys, current_keys, seen_prior, current_marks,
      # prior_marks}}`, rebuilt from the welded `finding_keys` markers by
      # `ComposerProjection`. The stuck/oscillation stall predicates read it.
      finding_rounds: %{},
      # Item 5 (deterministic verify authority): `tampered_stages` is the
      # per-stage tamper record (rebuilt from `stage_tampered` markers — the
      # tick terminalizes `:verify_tampered` ahead of every other branch);
      # `observed_head`/`sealed_head` are the engine's wave-boundary HEAD
      # observations (first `head_observed` = baseline, a later change =
      # seal); `verified_integrity` is the last green verify's certificate
      # (`verify_certified` fold, cleared when the verify stage is
      # invalidated); `verify_override` the per-run command override.
      tampered_stages: %{},
      observed_head: nil,
      sealed_head: nil,
      verified_integrity: nil,
      verify_override: Keyword.get(opts, :verify_override),
      # Item 10 (OB1-3): `evidence_breaches` is the per-stage fabrication
      # breach ledger (rebuilt from `evidence_classified` events by
      # `ComposerProjection` — the OpenHelm "counted, breach-visible" rider);
      # `wave_porcelain` and `wave_file_fingerprints` are the dispatch-time
      # untracked-inclusive status/content evidence the files-reconcile checks
      # at fold — in-memory ONLY (a mid-wave crash/recovery loses them, and the
      # files kind then skips that wave: can't verify ⇒ trust, never the
      # permissive fallback).
      evidence_breaches: %{},
      wave_porcelain: nil,
      wave_file_fingerprints: nil,
      # A rebuilt `wave_started(N)` with no matching completion means any
      # dispatch-time evidence from the original execution was lost. Keep the
      # durable open-wave identity so re-dispatch may bind its existing child
      # without manufacturing a post-edit "before" snapshot. Once the wave
      # index advances, the marker no longer applies and fresh capture resumes.
      recovered_open_wave_index: nil,
      # Slice 2 (OB1-3): the launch-extracted, config-persisted AC assertions
      # (nil ⇒ slice 2 off for the run) — verified deterministically against
      # the tree at every producer-wave fold, violations riding the same
      # evidence findings path.
      ac_assertions: Keyword.get(opts, :ac_assertions),
      terminal: nil,
      reason: nil,
      summary: nil
    }

    # Item 7 PR-3 (camus C1-1): the review-independence launch fence — refuse
    # BEFORE any wave (never a verdict, the review.sh posture). Both the front
    # door (`start_composer/2`) and boot recovery (`ensure_started/2`) pass
    # through init, so a recovered run re-checks its rebuilt catalog too; the
    # front door terminalizes on `{:error, _}` while boot recovery leaves the
    # parent `:running` for a later retry (the invalid-catalog precedent).
    # `state.context[:project_dir]` may be nil here (restored/fallback-empty
    # context) — `check_route/2` is nil-total, so a project-dir-less launch
    # reads no config and is byte-identical to today.
    case ReviewIndependence.check_route(state.catalog, state.context[:project_dir]) do
      :ok -> {:ok, state, {:continue, :rebuild}}
      {:error, reason} -> {:stop, reason}
    end
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
    # Item 5: tamper outranks EVERY other terminal branch — `:not_converged`/
    # deadlock/max-wave/deadline logic must never mask a detected cover-up
    # (VERIFY_OATH: the remedy is a human look, never a retry or a fixer).
    case tampered_terminal(state) do
      {:tampered, reason} -> finish({:verify_tampered, reason}, state)
      nil -> tick(state)
    end
  end

  defp tick(state) do
    available = Fold.available(state.artifacts)
    result = Router.compose_route(state.catalog, state.live, available, state.ran)
    display = Router.merge_sticky(state.catalog, state.prev_route, result)
    dispatch = Loop.dispatch_cohort(display, state.ran)

    cond do
      is_nil(dispatch) ->
        finish_terminal(Loop.terminal(display, state), state)

      over_budget?(state) ->
        finish_budget(state)

      true ->
        # Peel a solo gate out of a mixed Kahn cohort (Phase 4b), then DEFER a
        # verify stage sharing its cohort (item 5 — verify runs last, after
        # the reviewers in its Kahn level have emitted): the router does not
        # guarantee either is alone in its level.
        dispatch
        |> Loop.split_solo_gate(state.catalog)
        |> Loop.defer_solo_verify(state.catalog)
        |> run_wave(display, state)
    end
  end

  # The earliest durable tamper record wins (sorted for determinism); its
  # `{reason, report_ref}` detail rides the terminal.
  defp tampered_terminal(%{tampered_stages: tampered}) when map_size(tampered) > 0 do
    {stage, {reason, report_ref}} = Enum.min_by(tampered, fn {stage, _detail} -> stage end)
    {:tampered, {stage, reason, report_ref}}
  end

  defp tampered_terminal(_state), do: nil

  # Item 5 convergence-time integrity re-check (law 4): before `:converged`
  # lands on a run holding a live `clean:<verify-lens>`, re-derive the
  # MODE-SPECIFIC integrity tuple and compare against the certified
  # `verified_integrity` — an external edit/HEAD move mid-run or during
  # post-crash downtime (or an UNREADABLE capture: no convergence on state we
  # cannot name) retracts the green and re-verifies instead of converging.
  defp finish_terminal(:converged, state) do
    case stale_verified_cleans(state) do
      [] -> finish(:converged, state)
      [{stage, signal} | _rest] -> retract_and_reverify(stage, signal, state)
    end
  end

  # Item 6 (camus C1-5): an all-ran route with open findings whose fix loop
  # was STOPPED — Hook R suppressed the fixer re-fire on a stall or an
  # exhausted re-review budget, so the route ran dry — is a fix-loop terminal,
  # not a mislabeled `:not_converged`. This reclassification is ALSO where
  # verify-less routes early-halt on a stall (the stall stop needs no verify
  # stage; only C1-4's done-with-findings gate does). The fixer-less
  # `sketch-review` path never suppresses (no fixer on the live route, round
  # never exceeds 1), so its report-only `:not_converged` survives unchanged.
  defp finish_terminal(:not_converged, state) do
    case fix_stop_lenses(state) do
      [] -> finish(:not_converged, state)
      lenses -> finish_fixish({:fix_failed, lenses}, state)
    end
  end

  defp finish_terminal(terminal, state), do: finish(terminal, state)

  # The budget stop, with the `{:fix_failed, lenses}` product re-routed through
  # the C1-4 gate check (`finish_fixish/2`) — the second of the two fix-loop
  # stop producers (the first is the `:not_converged` reclassification above).
  # Every other budget terminal keeps the direct `finish/2`.
  defp finish_budget(state) do
    case budget_terminal(state) do
      {:fix_failed, _lenses} = terminal -> finish_fixish(terminal, state)
      terminal -> finish(terminal, state)
    end
  end

  # The live `clean:<lens>` signals of verify-unit stages whose certified
  # integrity no longer holds (or was never certified — the defensive
  # backstop: a live green with no `verified_integrity` fails closed).
  defp stale_verified_cleans(state) do
    Enum.reject(live_verify_cleans(state), fn {name, _signal} ->
      verified_integrity_holds?(state, name)
    end)
  end

  defp verified_integrity_holds?(%{verified_integrity: nil}, _stage), do: false

  defp verified_integrity_holds?(%{verified_integrity: vi} = state, stage) do
    vi.stage == stage and integrity_matches?(vi, verify_project_dir(state))
  end

  defp integrity_matches?(_vi, nil), do: false

  defp integrity_matches?(%{mode: :working_tree} = vi, dir) do
    git = Verify.git()
    head = git.head(dir)
    digest = git.diff_digest(dir)

    is_binary(head) and is_binary(digest) and head == vi.head and digest == vi.tree_digest
  end

  defp integrity_matches?(%{mode: :sealed} = vi, dir) do
    git = Verify.git()
    head = git.head(dir)
    porcelain = git.porcelain(dir)

    is_binary(head) and is_binary(porcelain) and head == vi.head and
      String.trim(porcelain) == ""
  end

  defp integrity_matches?(_vi, _dir), do: false

  defp verify_project_dir(%{context: context}) when is_map(context) do
    case context[:project_dir] do
      dir when is_binary(dir) and dir != "" -> dir
      _absent -> nil
    end
  end

  defp verify_project_dir(_state), do: nil

  # Retract the stale green + invalidate the verify stage (welded, mirrored
  # via the projection's own fold so `project == in-memory` holds), then
  # re-tick — the next dispatch re-offers verify. A failed append terminalizes
  # (house rule: never converge on a green the log no longer backs, and never
  # busy-loop the re-check).
  defp retract_and_reverify(stage, signal, state) do
    markers = [
      signals_retracted: %{signals: [signal]},
      stages_invalidated: %{stages: [stage]}
    ]

    case Commit.append_markers(state.parent, markers, commit_opts(state)) do
      :ok ->
        {:noreply, ComposerProjection.apply_markers(state, markers), {:continue, :tick}}

      {:error, halt} when halt in [:parent_terminal, :parent_fenced] ->
        {:stop, :normal, state}

      {:error, reason} ->
        finish({:failed, {:verify_recheck_append_failed, reason}}, state)
    end
  end

  # WS3 P2: the ownership probe `ensure_started/2` uses to tell a current owner
  # (still holds the run's possibly-just-reclaimed token) from a stale one left
  # behind when `claim_next` rotated the parent token. Answered immediately when the
  # composer is idle/parked, or once its in-flight wave returns.
  @impl GenServer
  def handle_call(:get_claim_token, _from, state), do: {:reply, state.claim_token, state}

  @impl GenServer
  def handle_info(:rebuild_retry, state), do: do_rebuild(state)

  # Gate wake (Phase 4b): an operator decided a gate. Ignore unless it is OUR
  # parked child; otherwise reload the child and branch on its STATUS — never on
  # `info.decision` — the durable status is the truth. This closes the
  # broadcast-before-resume race (`cases.ex:281-284`): the approve broadcast can
  # land before `GateResume` finishes, so a non-terminal child is observed to
  # terminal before folding, and the fold always reads a `:completed` child.
  def handle_info({:gate_resolved, run_id, _info}, state) do
    cond do
      match?(%{child_run_id: ^run_id}, state.parked) ->
        resolve_parked_gate(state)

      # Review-stall wake (camus C1-4): the stall case is run-bound to the
      # PARENT (no child), so `Cases.decide/4`'s kind-dispatched branch
      # broadcasts the parent's own id. Branch on the reloaded case's durable
      # STATUS — never on `info.decision` (the child-park posture above).
      is_map(state.stall_parked) and run_id == state.parent_run_id ->
        resolve_review_stall(state)

      true ->
        {:noreply, state}
    end
  end

  # Retry a transient `wave_paused` append (Phase 4b) — ONLY while still parked on
  # that exact child. A decision (approve/reject/abandon) clears `parked` to nil (or
  # re-parks on a later gate); a delayed retry firing into a resolved park would deref
  # a nil park in `wave_paused_payload/1` and crash. Mirrors the `:gate_resolved` guard.
  def handle_info({:retry_wave_paused, child_run_id, attempt}, state) do
    if match?(%{child_run_id: ^child_run_id}, state.parked) do
      attempt_wave_paused(state, attempt)
    else
      {:noreply, state}
    end
  end

  # Sensitive-park deadline fired (O-M2). Only dispose when the timer's identity
  # (`deadline_ref` + `child_run_id`) still matches the CURRENT park AND the durable
  # `deadline_at_ms` is genuinely past (a bare timer can fire after the gate resolved,
  # after a LATER park, or before an extended deadline — never abandon the wrong
  # case). The durable deadline is authoritative; the timer is only the wake.
  #
  # The deadline is a hard bound on the RUN, not a retroactive invalidator of
  # committed gate decisions: a decision that durably committed before this
  # message is processed wins the GATE (`dispose_park_deadline`'s fenced
  # primitive refuses `{:decided, _}` and routes through `resolve_parked_gate`),
  # and the RUN still terminates at the very next tick via `over_budget?/1`'s
  # `past_deadline?` — so the retention bound holds to within one fold.
  def handle_info({:park_deadline, deadline_ref, child_run_id, case_id}, state) do
    if park_deadline_match?(state, deadline_ref, child_run_id) and past_deadline?(state) do
      dispose_park_deadline(state, child_run_id, case_id)
    else
      {:noreply, state}
    end
  end

  # Sensitive-run review-stall park deadline (camus C1-4, the O-M2 posture on
  # the SIBLING park): same identity + durable-deadline double-guard as the
  # child-park handler above — the timer is only the wake, the durable
  # `deadline_at_ms` is authoritative, and a stale fire (case resolved, later
  # re-park, re-arm) is ignored.
  def handle_info({:stall_park_deadline, deadline_ref, case_id}, state) do
    if stall_deadline_match?(state, deadline_ref, case_id) and past_deadline?(state) do
      dispose_stall_park_deadline(state, case_id)
    else
      {:noreply, state}
    end
  end

  # The composer subscribes to the GLOBAL gates topic, so it also receives gate
  # events for OTHER runs (a `{:gate_requested, _}` it never acts on, and a
  # `{:gate_resolved, _}` for some other run's child the clause above already
  # filtered out). Drop any unmatched message rather than letting GenServer's
  # default handler log it as unexpected.
  def handle_info(_message, state), do: {:noreply, state}

  defp do_rebuild(state) do
    case load_parent_and_events(state) do
      # Reloaded parent already terminal → don't resume a finished run.
      {:terminal, _parent} ->
        {:stop, :normal, state}

      {:ok, parent, events} ->
        rebuilt =
          %{state | parent: parent, rebuild_attempts: 0}
          |> ComposerProjection.project(events)
          |> mark_recovered_open_wave(events)

        # WS2: preflight the held lease BEFORE resuming. `state` (pre-projection) is
        # threaded so a transient-error retry preserves `rebuild_attempts` (the
        # projection resets it to 0).
        lease_preflight_and_resume(rebuilt, state, events)

      {:error, reason} ->
        retry_rebuild_or_stop(state, reason)
    end
  end

  # WS2 master compatibility switch: lease behavior is gated on a binary held token.
  # A real launch always claims (genesis is unconditional), so it runs leased; a nil
  # token (a `loop_state/3` raw-state tick or any path bypassing `create_parent_run`)
  # ⇒ the byte-identical unleased path (no preflight, no sidecar).
  #
  # Preflight `renew/2` on the FROZEN start_opts token (never `parent.claim_token`):
  #   * `{:ok, 1}` → still owner → start the heartbeat sidecar, then resume.
  #   * `{:ok, 0}` → the row token was rotated by a reclaiming node → this is a
  #     zombie (a fence-kill restart, or a cross-node steal) → `{:stop, :normal}`
  #     writing NO parent events, so the reclaiming node's rebuilt state stays
  #     authoritative.
  #   * `{:error, _}` → a transient DB blip → the existing capped rebuild backoff
  #     (on the ORIGINAL state, so the attempt counter is honored).
  defp lease_preflight_and_resume(%{claim_token: token} = rebuilt, original, events)
       when is_binary(token) do
    case WorkflowLease.renew(rebuilt.parent_run_id, token) do
      {:ok, 1} -> start_parent_sidecar_and_resume(rebuilt, events)
      {:ok, 0} -> {:stop, :normal, rebuilt}
      {:error, reason} -> retry_rebuild_or_stop(original, reason)
    end
  end

  defp lease_preflight_and_resume(rebuilt, _original, events), do: resume_or_tick(rebuilt, events)

  # Start the parent heartbeat sidecar (WS2 Approach A): the RouteComposer GenServer
  # is the sidecar's "executor" — the sidecar renews the parent lease every
  # `renew_seconds` OFF-PROCESS, so a wave blocked synchronously in `ReactorRunner.run/3`
  # (up to `wave_timeout_ms`, far longer than the 60s lease) never lets the lease lapse,
  # and on a stale fence the sidecar `Process.exit(composer, :kill)`s. `start_sidecar/4`
  # blocks ≤5s for the readiness handshake — acceptable inside `do_rebuild` (already DB
  # work). On a start failure, mirror `Middleware.suspend_or_fail_closed/4`, KEEPING
  # `state.claim_token` either way (the durable fences + restart preflight rely on the
  # held token): under clustering → fail closed `{:stop, :normal}` (a heartbeat-less
  # composer would let the lease lapse and another node reclaim; the parent stays
  # `:running + claimed` for WS3); single-node → `degrade_gate/2` SUSPENDS the claim
  # (NULL expiry, keep token) so the always-on Pooler cannot reclaim this live,
  # heartbeat-less composer, then proceeds DEGRADED — but ONLY when the suspend took;
  # a lost/failed suspend fails closed `{:stop, :normal}` (the still-stamped row is
  # left for a legitimate dead-owner reclaim/boot). NOT `retry_rebuild_or_stop` —
  # `do_rebuild` resets `rebuild_attempts` to 0 on each successful reload, so a
  # post-reload retry never trips the cap (infinite loop); the bounded retry lives in
  # the Sidecar's registration, this is only the backstop.
  defp start_parent_sidecar_and_resume(state, events) do
    case WorkflowLease.start_sidecar(self(), state.parent_run_id, state.tenant, state.claim_token) do
      :ok ->
        resume_or_tick(state, events)

      {:error, reason} ->
        sidecar_fail_or_degrade(state, events, reason)
    end
  end

  defp sidecar_fail_or_degrade(state, events, reason) do
    if cluster_enabled?() do
      Logger.error(
        "[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} " <>
          "(#{inspect(reason)}); stopping under clustering — parent left :running + claimed for reclaim"
      )

      {:stop, :normal, state}
    else
      # Single-node: suspend the held claim (NULL expiry, keep the token) so the
      # always-on Pooler cannot reclaim a live, heartbeat-less composer, and only
      # proceed degraded when the suspend took. A lost/failed suspend ⇒ fail closed
      # (stop): no live executor remains, so the later Pooler reclaim of the still-
      # stamped row is a legitimate dead-owner reclaim, not the P1 live-reclaim hazard.
      case WorkflowLease.degrade_gate(state.parent_run_id, state.claim_token) do
        :degrade ->
          Logger.warning(
            "[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} " <>
              "(#{inspect(reason)}); degraded (single-node), suspended claim + proceeding with no heartbeat"
          )

          resume_or_tick(state, events)

        :fail_closed ->
          Logger.error(
            "[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} " <>
              "(#{inspect(reason)}); claim suspend lost/failed — stopping (parent left :running + claimed for reclaim/boot)"
          )

          {:stop, :normal, state}
      end
    end
  end

  defp cluster_enabled?, do: Application.get_env(:jido_claw, :cluster_enabled, false)

  # On rebuild, resume a parked gate WITHOUT re-dispatching it (Phase 4d): if the
  # log shows an open gate wave (`wave_started(N)` for a gate, no
  # `wave_completed(N)`, a child at `composer:<parent>:N`), re-enter the park and
  # branch on the child's status; otherwise turn the crank normally. This is what
  # makes "durable wake-after-gate-decision" work — a restart re-parks (or folds /
  # terminalizes a decided-while-down gate) instead of re-dispatching the wave.
  defp resume_or_tick(state, events) do
    case derive_park(state, events) do
      nil -> {:noreply, state, {:continue, :tick}}
      park -> re_enter_park(park, state)
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

  defp mark_recovered_open_wave(state, events) do
    wave_index = state.wave_index

    if wave_event?(events, :wave_started, wave_index) and
         not wave_event?(events, :wave_completed, wave_index) do
      %{state | recovered_open_wave_index: wave_index}
    else
      %{state | recovered_open_wave_index: nil}
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
      # A solo gate wave (Phase 4b): dispatch its named gate-producer reactor
      # module, which halts at the `GateStep` and parks the composer.
      {:ok, {:module_reactor, module, gate_inputs}} ->
        run_gate_wave(module, gate_inputs, dispatch, display, state)

      # A solo verify wave (item 5): a NON-halting module reactor — the engine
      # runs the checks and the result folds like a worker wave.
      {:ok, {:verify_reactor, module, verify_inputs}} ->
        run_verify_wave(module, verify_inputs, dispatch, display, state)

      {:ok, %Reactor{} = reactor} ->
        run_built_wave(reactor, stages, dispatch, display, state)

      # build_wave failure: no reactor ran, so there is no run to record.
      {:error, reason} ->
        finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # A verify wave (item 5) — the `run_gate_wave/5` shape minus the
  # artifact-input resolution (the verify reactor reads the working tree, not
  # the store) and minus the park (it never halts). The loop merges the
  # run-scoped inputs: the check cwd from the persisted scope, the
  # engine-observed `sealed_head` (mode auto-select), and the per-run command
  # override. Completes into the generic `handle_wave_result` fold.
  defp run_verify_wave(module, verify_inputs, dispatch, display, state) do
    with :ok <- record_wave_start(dispatch, display, state),
         :ok <- ensure_parent_live(state) do
      inputs =
        Map.merge(verify_inputs, %{
          project_dir: verify_project_dir(state),
          sealed_head: state.sealed_head,
          verify_override: state.verify_override
        })

      module
      |> run_verify_reactor(inputs, state)
      |> handle_wave_result(dispatch, display, state)
    else
      {:error, :parent_terminal} -> {:stop, :normal, state}
      # WS2: another owner has the parent (token rotated) — stop clean, write
      # nothing, launch nothing.
      {:error, :parent_fenced} -> {:stop, :normal, state}
      {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # Same envelope opts as `run_gate_reactor/3` (`async?: false`, deterministic
  # `composer:<parent>:<wave_index>` key — a restart re-dispatch dedupes +
  # observes the existing child rather than re-running the checks).
  defp run_verify_reactor(module, inputs, state) do
    ReactorRunner.run(module, inputs,
      tenant: state.tenant,
      actor: state.actor,
      async?: false,
      name: "route_composer:verify_#{state.wave_index}",
      context: state.context,
      parent_run_id: state.parent_run_id,
      idempotency_key: "composer:#{state.parent_run_id}:#{state.wave_index}",
      omit_replay_inputs: true,
      sanitize_sensitive_context: state.sanitize_sensitive_context,
      execution_timeout: state.wave_timeout_ms
    )
  end

  # A gate wave (Phase 4b). Resolve the gate's required-input ref from the store
  # (the loop has store access; the builder does not), append the pre-launch
  # markers under the FOR-UPDATE fence, then run the named gate reactor through
  # `ReactorRunner.run/3` (`async?: false` — the runner pins the halted struct
  # serializable, Decision 1). It returns promptly at the `GateStep` halt as
  # `{:ok, {:paused, case_id}, run}`; `handle_wave_result` parks on it. No
  # `:extra_context` (the gate stores the raw plan from its ref, feeds no worker),
  # so the formatting/cap path is skipped — which intentionally excludes the
  # AR-9 premises block too (a human gate doesn't self-report `scope-shift`).
  # A `:parent_terminal` from the fence stops cleanly without launching; any
  # other pre-launch error fails the wave.
  defp run_gate_wave(module, gate_inputs, dispatch, display, state) do
    gate_stage = Map.fetch!(state.catalog, hd(dispatch))

    with {:ok, plan_ref} <- resolve_gate_input_ref(gate_stage, state),
         :ok <- record_wave_start(dispatch, display, state),
         :ok <- ensure_parent_live(state) do
      inputs =
        gate_inputs
        |> Map.put(:plan_ref, plan_ref)
        |> Map.put(:lint, gate_lint(state.premises))

      module
      |> run_gate_reactor(inputs, state)
      |> handle_wave_result(dispatch, display, state)
    else
      {:error, :parent_terminal} -> {:stop, :normal, state}
      # WS2: another owner has the parent (token rotated) — stop clean, write
      # nothing, launch nothing.
      {:error, :parent_fenced} -> {:stop, :normal, state}
      {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # Item 9: re-derive the premises lint for the gate payload (pure, no new
  # persistence; `:gate` mode is structurally blocker-free). `%{}` when clean,
  # so a lint-less gate's `AgentCase.details` stays byte-identical; non-empty
  # reports ride namespaced under `"premises_lint"` (`Lint.to_details/1`).
  defp gate_lint(premises) do
    report = Lint.run(premises, mode: :gate)
    Telemetry.emit_premises_lint(report.grade, :gate)
    Lint.to_details(report)
  end

  # Resolve the bare store ref of the gate's single required input (the `plan`
  # for `plan-gate`) from the provenance store. The base catalog gives a gate
  # input one producer; multiple producers is out of scope, so pick the
  # lexicographically-first deterministically. A missing input is a clean wave
  # failure (the router's drop-unsatisfiable should never dispatch a gate whose
  # input is absent, so this is a backstop).
  defp resolve_gate_input_ref(%Stage{input: %{required: [name | _]}}, state) do
    case Map.get(state.artifacts, name) do
      producers when is_map(producers) and map_size(producers) > 0 ->
        {_producer, entry} = Enum.min_by(producers, &elem(&1, 0))
        {:ok, bare_ref(entry)}

      _absent ->
        {:error, {:gate_input_missing, name}}
    end
  end

  defp resolve_gate_input_ref(%Stage{name: name}, _state),
    do: {:error, {:gate_input_absent, name}}

  # The gate reactor's launch — same envelope opts as `run_reactor/3` but
  # `async?: false` (checkpoint serializability) and no `:extra_context`. The
  # deterministic `composer:<parent>:<wave_index>` key makes a re-derived gate
  # wave dedupe to the existing (parked or decided) child.
  defp run_gate_reactor(module, inputs, state) do
    ReactorRunner.run(module, inputs,
      tenant: state.tenant,
      actor: state.actor,
      async?: false,
      name: "route_composer:gate_#{state.wave_index}",
      context: state.context,
      parent_run_id: state.parent_run_id,
      idempotency_key: "composer:#{state.parent_run_id}:#{state.wave_index}",
      omit_replay_inputs: true,
      sanitize_sensitive_context: state.sanitize_sensitive_context,
      execution_timeout: state.wave_timeout_ms
    )
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
    with {:ok, artifact_context} <-
           ArtifactContext.build(stages, state.artifacts, state.tenant, state.actor),
         :ok <- record_wave_start(dispatch, display, state),
         :ok <- ensure_parent_live(state) do
      # Item 10 (OB1-3 decision 5 + signed fingerprint amendment): capture the
      # dispatch-time porcelain snapshot and bounded fingerprints for its
      # already-dirty paths AFTER the wave-start markers commit, right before
      # the workers run, and ONLY on evidence-eligible producer waves.
      state = maybe_capture_wave_porcelain(state, dispatch)

      reactor
      |> run_reactor(compose_extra_context(state.premises, artifact_context), state)
      |> handle_wave_result(dispatch, display, state)
    else
      # The run ended externally (operator cancel between waves): stop cleanly,
      # don't re-terminalize and don't launch the wave — consistent with the
      # `commit_wave` `:parent_terminal` arm in `handle_wave_value/5`.
      {:error, :parent_terminal} -> {:stop, :normal, state}
      # WS2: another owner reclaimed the parent (token rotated, in `record_wave_start`
      # or the `ensure_parent_live` re-check) — stop clean, write/launch nothing.
      {:error, :parent_fenced} -> {:stop, :normal, state}
      {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
    end
  end

  # AR-9 (alp-river #3): every worker wave's `:extra_context` opens with the
  # rendered premises block, then the artifact context. Empty premises render
  # `""` and are rejected, so a premises-less run's extra_context stays
  # byte-identical to the artifact context alone. Recovery is free: the durable
  # `config["premises"]` is restored into `state.premises` by
  # `build_start_opts`, and this reads state at wave time.
  defp compose_extra_context(premises, artifact_context) do
    [PremisesContext.render(premises), artifact_context]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Belt-and-suspenders parent-terminal re-check in the launch path (Phase 4c):
  # `record_wave_start`'s FOR-UPDATE guard catches a cancel that landed BEFORE the
  # markers; this catches one landing in the residual window AFTER the markers
  # commit but BEFORE `run_reactor` creates the child (the child create is
  # unfenced). A best-effort narrowing only — a reload blip proceeds (the wave's
  # fold is still fenced at `commit_wave/4`); full closure under CONCURRENT
  # terminalization rides the Phase 6 cluster lease (§10.1).
  defp ensure_parent_live(state) do
    case WorkflowRun.by_id(state.parent_run_id, tenant: state.tenant, actor: state.actor) do
      {:ok, %WorkflowRun{status: status, claim_token: current}} ->
        # WS2: also fence the post-marker / pre-child-create reclaim window — a node
        # that rotated the token here ⇒ `:parent_fenced` (caught by `run_built_wave`'s
        # else). A reload blip (`_other`) still proceeds (the wave's fold is fenced at
        # `commit_wave/4`). Order: terminal first (a true end), then the token fence.
        cond do
          Projection.terminal_status?(status) -> {:error, :parent_terminal}
          token_mismatch?(state.claim_token, current) -> {:error, :parent_fenced}
          true -> :ok
        end

      _other ->
        :ok
    end
  end

  # Nil-safe held-vs-row token mismatch: only a leased run (binary held token)
  # against a claimed row (binary current token) can be fenced. An unleased run or
  # a never-claimed row is never fenced (byte-identical to pre-WS2).
  defp token_mismatch?(held, current) when is_binary(held) and is_binary(current),
    do: current != held

  defp token_mismatch?(_held, _current), do: false

  # A gate wave halted at its `GateStep` (Phase 4b): the run promptly returned
  # `{:ok, {:paused, case_id}, run}` (one DB write, no LLM). PARK — subscribe to
  # the gates topic, append the durable `wave_paused` marker, hold the dispatch
  # context, and return `{:noreply, parked}`. The composer is now an idle, live
  # GenServer that wakes on `handle_info({:gate_resolved, …})`. This clause must
  # precede the generic `{:ok, value, run}` one.
  defp handle_wave_result({:ok, {:paused, case_id}, run}, dispatch, display, state) do
    park_gate(case_id, run, dispatch, display, state)
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

      # Phase 2d rule 2: a recovered child already `:failed` re-dispatches its
      # stages under a FRESH `wave_index`. The failed wave never appended a
      # `wave_completed`, so its stages aren't in `ran`; the re-tick re-composes
      # them and dispatches under `composer:<parent>:<N+1>` — a key MISS → a
      # genuinely fresh run (its own genuine failure then surfaces as
      # `{:error, _, run}` → `finish_failed`, so this never loops; repeated
      # mid-recovery crashes walk `wave_index` forward, bounded by `max_waves`).
      # The old `:failed` child is a harmless orphan, told apart by `wave_index`.
      # This differs DELIBERATELY from `observe_existing_child`'s non-completed
      # terminal (H8) — but post-review P1 narrowed the difference: lens-only
      # cohorts ride Lane B on BOTH sides now, so what remains distinct is the
      # mixed/producer else (there `finish_failed`, here the plain wave-index
      # bump — a stale corpse from a prior crash re-dispatches under a fresh
      # key rather than failing the route) and the just-now-vs-stale framing.
      #
      # Camus C1-3 Lane B, third entry point: a lens-only cohort's failed child
      # means the composer crashed AFTER the child failed but BEFORE
      # `stage_infra` was appended — the plain bump would bypass `infra_counts`
      # and end as generic budget exhaustion. Route it through the same infra
      # helper; there is no live `reason` here, so pass `run.error ||
      # :failed_child` for trace/fallback consistency with the live arms.
      :failed ->
        if lens_only_dispatch?(dispatch, state.catalog) do
          wave_infra_failed(run.error || :failed_child, run, dispatch, display, state)
        else
          {:noreply, %{state | wave_index: state.wave_index + 1}, {:continue, :tick}}
        end

      # A gate-decided-then-crash (Phase 2d/4c): the gate's decision already drove
      # the child to a terminal before the composer could observe it. Routed through
      # the SAME `terminalize_gate_disposition/3` the live wake path uses (so the
      # two cannot drift) → `route_rejected`/`route_abandoned` → `:cancelled` +
      # disposition. (Phase 4e interposes the reject re-plan opt-in here too.)
      :cancelled ->
        terminalize_gate_disposition(:rejected, run, state)

      :abandoned ->
        terminalize_gate_disposition(:abandoned, run, state)
    end
  end

  # `decode_emissions` is run INSIDE the body (not as a `with`/pipeline leg) so a
  # bad-wave-return error still carries the live `run` to `finish_failed` — a
  # leg failure would drop the child_run_id.
  defp handle_wave_result({:ok, value, run}, dispatch, display, state) do
    handle_wave_value(decode_emissions(value), run, dispatch, display, state)
  end

  # run_reactor failure: `run` is the (possibly nil, on a pre-run error) child
  # WorkflowRun whose id the failed-wave history entry surfaces. A lens-only
  # cohort's execution failure is camus's exec-failure class — the judge never
  # produced a verdict — so it rides the infra lane (Lane B); a mixed/producer
  # cohort keeps the loud `route_failed` (the shared `wave_failed/5` gate).
  defp handle_wave_result({:error, reason, run}, dispatch, display, state) do
    wave_failed(reason, run, dispatch, display, state)
  end

  # The durable commit path (Phase 2c; AR-4 self-heal; camus C1-3 Lane A). First
  # INJECT the guaranteed completion signals into the producers' emissions
  # (`enforce_completion_signals/2` — the silent-converge fix, applied BEFORE the
  # fold so it flows into live state, the durable `signals_published` delta, the
  # never-ran summon, AND the fixer's re-review derivation in one place; it only
  # touches lens-nil producers, so infra'd reviewers are untouched). Then
  # PARTITION on the emission `outcome`: only verdict emissions fold —
  # `Fold.fold_ran` adds every folded stage to `ran`, so an infra'd stage staying
  # OUT of the fold (and out of `wave_completed.stages`, keeping durable ≡
  # in-memory) is what makes its publishes stay unsatisfied and the next tick
  # re-offer it (a fresh wave, fresh idempotency key). Derive the wave's content
  # deltas by DIFFING pre/post `Fold` state (so the durable log equals the
  # in-memory fold by construction — incl. a paired-verdict flip that retracts a
  # live signal, captured as `signals_retracted`), compute the AR-4 self-heal
  # rerun decision as a PURE function of the folded state over the VERDICT
  # emissions only (`decide_rerun/2` — an infra'd reviewer emitted nothing this
  # wave), and WELD the `stage_infra` markers + rerun markers into the SAME
  # `commit_wave` transaction (the crash-window fix: a "fixer ran"
  # `wave_completed` can never land without its re-review trigger; an infra'd
  # wave can never re-project without its `infra_counts` bump). The `stage_infra`
  # payload carries stage names ONLY — no reasons (redaction posture) and no
  # `closed_wave_index` (this wave's `wave_completed` advances the index). Only
  # on `:ok` do we mirror those markers in memory (`ComposerProjection.apply_markers/2`,
  # the projection's own fold), emit the infra trace/telemetry (durable-then-
  # notify), and continue — full emissions (incl. infra'd ones, with `outcome`)
  # go to history for legibility. The AR-8c verify loop + stale-approval stay on
  # their existing POST-commit path (`maybe_rerun_after_findings`), reading the
  # verdict emissions only.
  defp handle_wave_value({:ok, raw_emissions}, run, dispatch, display, state) do
    # Item 5, BEFORE the ok/infra split: a verify emission carrying its
    # `clean:<lens>` with nil/invalid certification is RECLASSIFIED to
    # `{:inconclusive, "uncertified_green"}` — the committed invariant is
    # `clean:<lens>` ∈ signals ⇔ a `:verify_certified` marker in the SAME wave
    # commit; an uncertified green never reaches the parent log (`Fold.fold`
    # would publish its signal blindly). The already-stored report stays
    # reachable via the NON-ROUTING `verify_report_recorded` marker.
    {emissions, report_markers} =
      raw_emissions
      |> enforce_completion_signals(state)
      |> reclassify_uncertified_greens(state)

    {verdict_emissions, non_ok_emissions} = Enum.split_with(emissions, &(&1.outcome == :ok))

    # Tampered is extracted BEFORE the infra lane (it must not bump
    # `infra_counts` — VERIFY_OATH: never retried, never fed to the fixer).
    {tampered_emissions, infra_emissions} =
      Enum.split_with(non_ok_emissions, &match?({:tampered, _reason}, &1.outcome))

    infra_stages = Enum.map(infra_emissions, & &1.stage)
    tampered_stages = Enum.map(tampered_emissions, & &1.stage)
    next_fold = Fold.fold(state, verdict_emissions)
    deltas = wave_deltas(state, next_fold, dispatch, infra_stages ++ tampered_stages)

    # Camus C1-5: the finding-identity markers fold FIRST into a temporary
    # state so `decide_rerun`'s stall/no-re-review suppression reads THIS
    # round's keys (round N vs N-1 is decided at the wave that produced round
    # N). Only `next_fold` — never `keyed_fold` — receives the full marker
    # batch post-commit, so the round shift is applied exactly once.
    #
    # Item 10 (OB1-3): the evidence RECORD markers (artifacts, signal pair,
    # the evidence `finding_keys` round, the `evidence_classified` ledger)
    # join the temp fold too — `rereview_exhausted_lenses` reads `state.live`
    # for `findings:evidence` and the stall predicates read the evidence
    # round, so a FIRST breach with the fixer already rerun-capped must be
    # visible to suppression THIS wave (the camus C1-5 fold-first
    # discipline). The RE-FIRE markers (feedback production + the fixer
    # `stages_invalidated`) are then gated on the SAME fully-keyed fold
    # `decide_rerun` reads — #6's whole-Hook-R-suppression-on-a-stop rule:
    # the honest breach facts always weld; only the doomed fix dispatch is
    # suppressed.
    finding_markers = finding_keys_markers(verdict_emissions)
    evidence_record = evidence_record_markers(verdict_emissions, run, state)

    keyed_fold =
      ComposerProjection.apply_markers(
        next_fold,
        finding_markers ++ evidence_record.markers
      )

    evidence_refire = evidence_refire_markers(evidence_record, keyed_fold)
    {rerun_markers, _rerun_only_apply} = decide_rerun(keyed_fold, verdict_emissions)

    markers =
      infra_markers(infra_stages) ++
        tampered_markers(tampered_emissions) ++
        report_markers ++
        finding_markers ++
        evidence_weld_markers(evidence_record, evidence_refire) ++
        certified_markers(verdict_emissions, state) ++
        head_observation_markers(next_fold, state) ++
        rerun_markers

    case Commit.commit_wave(
           state.parent,
           state.wave_index,
           deltas,
           markers,
           commit_opts(state)
         ) do
      :ok ->
        emit_infra_observability(infra_outcomes(infra_emissions), :output, state)
        emit_tampered_observability(tampered_emissions, state)
        emit_evidence_observability(evidence_record, state)

        next =
          record_wave(
            ComposerProjection.apply_markers(next_fold, markers),
            dispatch,
            display,
            run,
            emissions
          )

        maybe_rerun_after_findings(next, verdict_emissions)

      # The run ended externally (an operator cancel landed while the wave
      # returned): stop cleanly, don't re-terminalize (the terminal append already
      # no-ops a terminal parent).
      {:error, :parent_terminal} ->
        {:stop, :normal, state}

      # WS2: a reclaiming node rotated the parent token while this wave returned —
      # stop clean, write nothing, so the new owner's fold of this wave is canonical.
      {:error, :parent_fenced} ->
        {:stop, :normal, state}

      # A commit leg failed: terminalize the parent `route_failed` — do NOT
      # fold/record/continue from memory as if the durable write had landed.
      {:error, reason} ->
        finish_failed(reason, run, dispatch, display, state)
    end
  end

  # Wave decode / `:bad_wave_return` failure — Lane B's second entry point: a
  # lens-only cohort rides the infra lane, anything else stays `route_failed`.
  defp handle_wave_value({:error, reason}, run, dispatch, display, state) do
    wave_failed(reason, run, dispatch, display, state)
  end

  # Record the attempted-but-failed wave (empty emissions, `failed: true`,
  # surfacing `child_run_id`) before stamping the `:failed` terminal, so the
  # summary can point at which stages failed and at the child run.
  defp finish_failed(reason, run, dispatch, display, state) do
    next = record_wave(state, dispatch, display, run, [], true)
    finish({:failed, reason}, next)
  end

  # ---------------------------------------------------------------------------
  # Camus C1-3 — the infra lane
  # ---------------------------------------------------------------------------

  # The shared lens-vs-producer gate for a failed wave: a lens-only cohort
  # rides the infra lane (Lane B), anything else keeps the loud `route_failed`.
  # Serves the live reactor-run failure, the decode/`:bad_wave_return` failure,
  # and the dedupe-hit observe arms (observed just-now-`:failed`, observe
  # timeout, observe reload failure). For those observe arms the immediate
  # failure came from observation/recovery machinery, but the composer still
  # has no trustworthy verdict for the lens — so they are DELIBERATELY review
  # infra, the fail-closed posture of `docs/TRUST-BOUNDARIES.md` (post-review
  # P1: routing them to `finish_failed` conflated infra with a real verdict
  # failure purely on failure timing relative to a restart).
  defp wave_failed(reason, run, dispatch, display, state) do
    if lens_only_dispatch?(dispatch, state.catalog) do
      wave_infra_failed(reason, run, dispatch, display, state)
    else
      finish_failed(reason, run, dispatch, display, state)
    end
  end

  # Lane B (wave-execution-error infra), five entry points: a live reactor-run
  # failure, a decode/`:bad_wave_return` failure, and the two dedupe-hit
  # observe arms (observed non-completed terminal / observe error) — all four
  # through the shared `wave_failed/5` gate — plus the recovered-failed-child
  # dedupe arm, which gates on `lens_only_dispatch?/2` itself (its else is the
  # plain wave-index bump, not `finish_failed`). Appends the durable
  # `stage_infra` marker WITH
  # `closed_wave_index` (load-bearing, the reject-parked-gate precedent: the
  # failed wave never wrote `wave_completed`, so without it a restart rebuilds
  # the old `wave_index` and the relaunch dedupes onto the failed child via
  # `composer:<parent>:<wave_index>`), records a failed history entry, mirrors
  # the marker in memory, and continues to `:tick` — each retry is a fresh wave
  # under a fresh idempotency key. Ordering avoids a double-advance:
  # `record_wave` bumps to `idx + 1` first, so `apply_markers`'
  # `max(current, idx + 1)` is idempotent. A failed marker append terminalizes
  # loudly (house rule: commit-failure terminalizes); `:parent_terminal` /
  # `:parent_fenced` stop clean like every other durable write path.
  defp wave_infra_failed(reason, run, dispatch, display, state) do
    markers = [stage_infra: %{stages: dispatch, closed_wave_index: state.wave_index}]

    case Commit.append_markers(state.parent, markers, commit_opts(state)) do
      :ok ->
        reason_string = Verdict.format_reason({:wave_execution_failed, reason})
        emit_infra_observability(Enum.map(dispatch, &{&1, reason_string}), :wave_error, state)

        next =
          state
          |> record_wave(dispatch, display, run, [], true)
          |> then(&ComposerProjection.apply_markers(&1, markers))

        {:noreply, next, {:continue, :tick}}

      {:error, halt} when halt in [:parent_terminal, :parent_fenced] ->
        {:stop, :normal, state}

      {:error, append_reason} ->
        finish_failed({:infra_marker_append_failed, append_reason}, run, dispatch, display, state)
    end
  end

  # A cohort is infra-eligible when EVERY dispatched stage is a lens stage (its
  # judge is what failed). Mixed cohorts and producer waves keep today's loud
  # `route_failed` — a producer's execution failure is not a judge problem.
  defp lens_only_dispatch?(dispatch, catalog) do
    dispatch != [] and
      Enum.all?(dispatch, fn name ->
        match?({:ok, %Stage{lens: lens}} when is_binary(lens), Map.fetch(catalog, name))
      end)
  end

  # Lane A's durable marker: stage names only — no reasons (redaction posture)
  # and no `closed_wave_index` (the same commit's `wave_completed` advances the
  # index).
  defp infra_markers([]), do: []
  defp infra_markers(stages), do: [stage_infra: %{stages: stages}]

  # ---------------------------------------------------------------------------
  # Camus C1-5 — finding identity + stall detection (next-ten #6)
  # ---------------------------------------------------------------------------

  # One durable `finding_keys` marker per reviewer round, WELDED into the wave
  # commit (the `verify_certified` precedent): findings persist as encrypted
  # `ComposerArtifact` refs the projection never decrypts, so the cross-wave
  # identity must ride its own bounded marker for the rebuild to fold. Keys +
  # enum marks only — never titles/bodies (redaction posture). A clean round
  # carries `keys: []` (the round must still advance for oscillation).
  defp finding_keys_markers(verdict_emissions) do
    # Wire-shaped finding-marks contract (mapper → emission → marker → fold);
    # a struct would ripple the emission decode boundary.
    # reach:disable-next-line fixed_shape_map
    for %StageEmission{stage: stage, finding_marks: %{lens: lens, keys: keys, marks: marks}} <-
          verdict_emissions do
      {:finding_keys, finding_keys_payload(stage, lens, keys, marks)}
    end
  end

  # The wire-shaped `finding_keys` marker payload (marker → fold →
  # projection) — ONE construction site so the reviewer and evidence rounds
  # can't drift apart.
  defp finding_keys_payload(stage, lens, keys, marks) do
    # reach:disable-next-line fixed_shape_map
    %{stage: stage, lens: lens, keys: keys, marks: marks}
  end

  # ---------------------------------------------------------------------------
  # Item 10 (OB1-3) — the evidence floor consumer
  # ---------------------------------------------------------------------------

  # The templates whose producer emissions the evidence floor classifies —
  # eligibility is decided HERE from the catalog (stage name → unit/template),
  # never by the mapper (which stays dumb and copies fields).
  @evidence_producer_templates ["coder", "fixer"]

  # The RECORD half: classify every eligible producer emission of this wave
  # against the durable transcript + the wave git diff, and derive the always-
  # welded markers — the aggregated artifacts, the signal pair, the evidence
  # `finding_keys` round, and the `evidence_classified` breach ledger. The
  # whole wave aggregates into ONE artifact set under producer `"evidence"`
  # (active-artifact uniqueness is `{parent_run_id, name, producer}`, and two
  # `finding_keys` markers for one lens in one wave would double-shift the
  # projection's finding round) — per-stage attribution rides each finding's
  # location/description and the ledger's per-stage entries. Fail-open end to
  # end: any gather/classify/store fault degrades to a no-marker result with a
  # Trace note, never a wave failure. A never-flagged clean run returns no
  # markers at all — its fold stays byte-identical.
  defp evidence_record_markers(verdict_emissions, run, state) do
    case evidence_eligible(verdict_emissions, state.catalog) do
      [] -> evidence_no_record()
      eligible -> classify_evidence(eligible, run, state)
    end
  rescue
    # The floor is advisory (findings-only, never a gate): a consumer fault
    # must never convert a completed wave into a failure.
    # reach:disable-next-line bare_rescue
    error ->
      JidoClaw.Trace.emit(:composer, %{
        event: :evidence_skipped,
        reason: :consumer_fault,
        detail: String.slice(Exception.message(error), 0, 200),
        parent_run_id: state.parent_run_id
      })

      evidence_no_record()
  end

  # The evidence consumer's per-wave record — ONE construction site so the
  # no-record/breach/clear arms can't drift (`markers` is always
  # `produced ++ routing`, the pinned weld halves; `ac` is the slice-2
  # verification result, nil when the run carries no assertions).
  defp evidence_record(produced, routing, breach?, classifications, ac) do
    %{
      produced: produced,
      routing: routing,
      markers: produced ++ routing,
      breach?: breach?,
      classifications: classifications,
      ac: ac
    }
  end

  defp evidence_no_record, do: evidence_record([], [], false, [], nil)

  defp evidence_eligible(verdict_emissions, catalog) do
    Enum.filter(verdict_emissions, &evidence_producer_stage?(catalog, &1.stage))
  end

  defp evidence_producer_stage?(catalog, name) do
    case Map.get(catalog, name) do
      %Stage{lens: nil, unit: {:worker_template, template}} ->
        template in @evidence_producer_templates

      _other ->
        false
    end
  end

  defp classify_evidence(eligible, run, state) do
    ctx = evidence_ctx(state)

    classifications =
      for emission <- eligible do
        observations = Evidence.gather(emission.request_id, ctx)
        {emission, observations, Evidence.classify(emission.evidence, observations)}
      end

    trace_containment(ctx, classifications, state)

    ac = ac_verification(state)

    discrepancies =
      Enum.flat_map(classifications, fn {emission, _observations, classification} ->
        Evidence.discrepancies(emission.stage, classification)
      end) ++ Enum.map(ac_violated(ac), &ac_discrepancy/1)

    cond do
      discrepancies != [] ->
        evidence_breach_record(classifications, discrepancies, ac, run, state)

      MapSet.member?(state.live, "findings:evidence") ->
        evidence_clear_record(classifications, ac)

      true ->
        %{evidence_no_record() | classifications: classifications, ac: ac}
    end
  end

  # Slice 2 (OB1-3): verify the launch-extracted AC assertions against the
  # tree at the same producer-wave fold point, feeding violations into the
  # SAME discrepancy → findings → Hook R path as the claim kinds. Identity:
  # the title carries the (launch-cached, so stable) assertion sentence; the
  # location is the extractor's file_hint — a violation always has one
  # (contradiction requires scanned files, which require a hint) — with the
  # stable synthetic `evidence:ac:<id>` token as the defensive fallback.
  # NEVER the emitting stage name, which flips coder→fixer across waves and
  # would churn the FindingKey (decision 3's no-churn rule; deviation from
  # the plan's "else stage name", logged in the queue README). Runs inside
  # `evidence_record_markers`'s rescue — any fault degrades to no
  # discrepancies, never a wave failure. Returns nil (no assertions on the
  # run) or `%{total, violated}` — full result maps in `violated`, so the
  # discrepancy/report consumers keep the assertion text while the ledger
  # payload projects ids only.
  defp ac_verification(%{ac_assertions: [_ | _] = assertions} = state) do
    results = Assertions.verify(assertions, verify_project_dir(state))
    violated = Enum.reject(results, & &1.verified)

    JidoClaw.Trace.emit(:composer, %{
      event: :ac_assertion_result,
      total: length(results),
      violated: length(violated),
      parent_run_id: state.parent_run_id
    })

    %{total: length(results), violated: violated}
  end

  defp ac_verification(_state), do: nil

  defp ac_violated(nil), do: []
  defp ac_violated(%{violated: violated}), do: violated

  defp ac_discrepancy(result) do
    # The same wire-shaped discrepancy triple `Evidence.discrepancies/2`
    # emits (findings/1 is the shared synthesis path).
    # reach:disable-next-line fixed_shape_map
    %{
      title: "#{result.ac_id} assertion failed: #{result.assertion}",
      location: result.file_hint || "evidence:ac:#{result.ac_id}",
      description:
        String.slice(
          "#{result.reason} (tier #{result.tier}; acceptance criterion #{result.ac_id})",
          0,
          900
        )
    }
  end

  # A breach: store the THREE encrypted artifacts (the `VerifyStage`
  # precedent — `findings` is the union across breaching stages,
  # `action_needed` the fixer directive, `evidence-report` the per-stage
  # diagnosis the next review wave reads), then derive the routing markers.
  # Every flip welds BOTH signal deltas (the clean↔findings pairing is
  # `Fold.add_signal/2` behavior for normal emissions — welded markers only
  # union, so the retraction must be explicit).
  defp evidence_breach_record(classifications, discrepancies, ac, run, state) do
    findings = Evidence.findings(discrepancies)

    with {:ok, findings_ref} <- store_evidence_artifact("findings", findings, run, state),
         {:ok, action_ref} <-
           store_evidence_artifact(
             "action_needed",
             Evidence.action_needed(discrepancies),
             run,
             state
           ),
         {:ok, report_ref} <-
           store_evidence_artifact(
             "evidence-report",
             evidence_report(classifications, ac),
             run,
             state
           ) do
      produced =
        [
          artifacts_produced: %{
            artifacts: [
              artifact_triple("findings", "evidence", findings_ref),
              artifact_triple("action_needed", "evidence", action_ref),
              artifact_triple("evidence-report", "evidence", report_ref)
            ]
          }
        ]

      keys =
        findings
        |> Enum.map(&FindingKey.key/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      routing = evidence_breach_routing(keys, classifications, ac, state)

      evidence_record(produced, routing, true, classifications, ac)
    else
      {:error, reason} ->
        JidoClaw.Trace.emit(:composer, %{
          event: :evidence_skipped,
          reason: :artifact_store_failed,
          detail: String.slice(inspect(reason), 0, 200),
          parent_run_id: state.parent_run_id
        })

        %{evidence_no_record() | classifications: classifications, ac: ac}
    end
  end

  defp evidence_breach_routing(keys, classifications, ac, state) do
    marks =
      Enum.map(keys, fn key ->
        # Wire-shaped finding-mark (the reviewer marker shape) — engine
        # findings are certain, so confidence pins "likely" (a steady trend).
        # reach:disable-next-line fixed_shape_map
        %{key: key, severity: "error", confidence: "likely"}
      end)

    [signals_published: %{signals: ["findings:evidence"]}] ++
      evidence_clean_retraction(state) ++
      [
        finding_keys: finding_keys_payload("evidence", "evidence", keys, marks),
        evidence_classified: evidence_classified_payload(classifications, ac)
      ]
  end

  defp evidence_clean_retraction(state) do
    if MapSet.member?(state.live, "clean:evidence"),
      do: [signals_retracted: %{signals: ["clean:evidence"]}],
      else: []
  end

  # The clearing re-check: a classified wave with NO breach while
  # `findings:evidence` is live — the deterministic re-check came back
  # unflagged (clean, skipped, or masked-only: can't-verify ⇒ trust), so the
  # flip retracts. `keys: []` still welds the `finding_keys` round (a clean
  # round must advance — oscillation detection needs it).
  defp evidence_clear_record(classifications, ac) do
    routing = [
      signals_published: %{signals: ["clean:evidence"]},
      signals_retracted: %{signals: ["findings:evidence"]},
      finding_keys: finding_keys_payload("evidence", "evidence", [], []),
      evidence_classified: evidence_classified_payload(classifications, ac)
    ]

    evidence_record([], routing, false, classifications, ac)
  end

  # The RE-FIRE half, gated on the SAME fully-keyed fold `decide_rerun` reads
  # (this wave's evidence round + live signals already applied): on a stop —
  # a stalled evidence key, or a fixer whose re-review budget can't cover the
  # dispatch — suppress the fix dispatch entirely (#6's discipline); the
  # record markers still stand and the run terminalizes via
  # `fix_stop_lenses/1`. `keyed_fold` also carries the freshly stored
  # evidence artifacts, which `review_feedback/2` (`build_feedback` reads
  # `state.artifacts`) resolves into the fixer's
  # `review-feedback[evidence]`/`review-action[evidence]` feed.
  defp evidence_refire_markers(%{breach?: false}, _keyed_fold) do
    %{feedback: [], invalidation: []}
  end

  defp evidence_refire_markers(_record, keyed_fold) do
    if suppress_fix_dispatch?(keyed_fold) do
      %{feedback: [], invalidation: []}
    else
      {feedback_markers, _put} = review_feedback(keyed_fold, ["evidence"])

      %{
        feedback: feedback_markers,
        invalidation: fixer_reinvalidation_markers(keyed_fold)
      }
    end
  end

  # The pinned weld order: evidence `artifacts_produced` → feedback
  # invalidation/production → signals + `finding_keys` + the ledger →
  # `stages_invalidated`.
  defp evidence_weld_markers(record, refire) do
    record.produced ++ refire.feedback ++ record.routing ++ refire.invalidation
  end

  defp store_evidence_artifact(name, value, run, state) do
    ComposerArtifact.store_wave_artifact(name, "evidence", value, run, state.wave_index,
      tenant: state.tenant,
      actor: state.actor
    )
  end

  defp evidence_ctx(state) do
    repo = verify_project_dir(state)
    after_porcelain = capture_wave_porcelain(state)

    fingerprint_paths =
      state.wave_porcelain
      |> Evidence.snapshot_paths()
      |> MapSet.union(Evidence.snapshot_paths(after_porcelain))

    %{
      session_id: state.context[:session_uuid],
      tenant: state.tenant,
      actor: state.actor,
      before_porcelain: state.wave_porcelain,
      after_porcelain: after_porcelain,
      before_file_fingerprints: state.wave_file_fingerprints,
      after_file_fingerprints: capture_wave_file_fingerprints(repo, fingerprint_paths),
      repo: repo
    }
  end

  # The dispatch-time / fold-time untracked-inclusive snapshot (decision 5).
  # Nil-total and rescue-guarded: a missing project_dir, a git failure, or a
  # seam stub without `porcelain_all/1` all degrade to nil — the files kind
  # then skips (can't verify ⇒ trust), never a wave failure.
  defp capture_wave_porcelain(state) do
    case verify_project_dir(state) do
      nil -> nil
      dir -> Verify.git().porcelain_all(dir)
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> nil
  end

  # Signed 2026-07-09 OB1-3 amendment: a status line cannot prove a second
  # edit to an already-dirty path, so producer waves also capture bounded,
  # symlink-safe content/type/mode fingerprints. This is additive proof only:
  # an old custom git seam, a crossed bound, or an unreadable path returns nil
  # and the existing status result stands unchanged.
  defp capture_wave_file_fingerprints(repo, paths)
       when is_binary(repo) and is_struct(paths, MapSet) do
    git = Verify.git()

    if function_exported?(git, :path_fingerprints, 3) do
      git.path_fingerprints(repo, MapSet.to_list(paths), on_error: :omit)
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp capture_wave_file_fingerprints(_repo, _paths), do: nil

  # Only producer waves capture a before-snapshot; a non-producer wave clears
  # it so a stale snapshot from an earlier wave can never feed a later fold.
  defp maybe_capture_wave_porcelain(state, dispatch) do
    producer_wave? = Enum.any?(dispatch, &evidence_producer_stage?(state.catalog, &1))

    cond do
      producer_wave? and state.recovered_open_wave_index == state.wave_index ->
        # The original baseline was process-local. Re-capturing now would
        # compare post-child state to itself on a completed-child dedupe hit
        # and falsely accuse a real edit. Missing before evidence deliberately
        # drives the files kind to its conservative skip posture.
        %{state | wave_porcelain: nil, wave_file_fingerprints: nil}

      producer_wave? ->
        porcelain = capture_wave_porcelain(state)

        %{
          state
          | wave_porcelain: porcelain,
            wave_file_fingerprints:
              capture_wave_file_fingerprints(
                verify_project_dir(state),
                Evidence.snapshot_paths(porcelain)
              )
        }

      true ->
        %{state | wave_porcelain: nil, wave_file_fingerprints: nil}
    end
  end

  # Containment (camus C1-6c, Trace-warning-only in v1): paths that changed
  # this wave but were claimed by no stage — `(after ∖ before) ∖ claimed`.
  # Count only (redaction posture — paths live nowhere outside the encrypted
  # report).
  defp trace_containment(ctx, classifications, state) do
    with before_snapshot when is_binary(before_snapshot) <- ctx.before_porcelain,
         after_snapshot when is_binary(after_snapshot) <- ctx.after_porcelain do
      changed = Evidence.changed_paths(before_snapshot, after_snapshot)

      claimed =
        for {emission, _observations, _classification} <- classifications,
            is_map(emission.evidence),
            path <- Map.get(emission.evidence, :files_touched, []),
            into: MapSet.new(),
            do: String.trim_leading(String.trim(path), "./")

      unclaimed = MapSet.difference(changed, claimed)

      if MapSet.size(unclaimed) > 0 do
        JidoClaw.Trace.emit(:composer, %{
          event: :evidence_containment,
          unclaimed_count: MapSet.size(unclaimed),
          stages: Enum.map(classifications, fn {emission, _o, _c} -> emission.stage end),
          parent_run_id: state.parent_run_id
        })
      end

      :ok
    else
      _no_snapshot -> :ok
    end
  end

  # The bounded redaction-posture ledger payload (one AGGREGATE event per
  # classified wave): per-stage status counts and the breach flag — never
  # command strings, paths, or log tails (those live only in the encrypted
  # artifacts). The `ac` section rides whenever AC assertions were verified
  # on a welded record — breach AND clear paths, the honest record — as
  # uniq'd violated ids only ("AC1"; the extractor may emit several
  # assertions per AC), never assertion text; an AC-less run omits the key
  # so existing events stay byte-identical.
  defp evidence_classified_payload(classifications, ac) do
    payload = %{
      classifications:
        Enum.map(classifications, fn {emission, _observations, classification} ->
          %{
            stage: emission.stage,
            request_id: emission.request_id,
            counts: classification.counts,
            statuses: evidence_kind_statuses(classification),
            breach: Enum.any?(classification.claims, &(&1.status == :unsupported))
          }
        end)
    }

    case ac do
      %{total: total, violated: violated} ->
        ids =
          violated
          |> Enum.map(& &1.ac_id)
          |> Enum.uniq()

        # Wire-shaped ledger section (marker → fold → projection).
        # reach:disable-next-line fixed_shape_map
        Map.put(payload, :ac, %{total: total, violated: ids})

      nil ->
        payload
    end
  end

  defp evidence_kind_statuses(classification) do
    classification.claims
    |> Enum.group_by(& &1.kind)
    |> Map.new(fn {kind, claims} -> {kind, Enum.frequencies_by(claims, & &1.status)} end)
  end

  # The per-stage diagnosis the next review wave reads (`evidence-report`,
  # encrypted): verdicts, per-claim statuses, and skip reasons — plus the AC
  # section when assertions violated (the artifact is encrypted, so full
  # assertion text + reason are fine here; only ids ride the ledger payload).
  defp evidence_report(classifications, ac) do
    sections =
      Enum.map(classifications, fn {emission, observations, classification} ->
        header =
          "## evidence: #{emission.stage} — #{classification.verdict} " <>
            "(engine-verified against the tool transcript and the wave git diff)"

        skips = evidence_skip_lines(observations)

        claims =
          Enum.map(classification.claims, fn claim ->
            "- [#{claim.status}] #{claim.kind}: #{claim.value} — #{claim.detail}"
          end)

        Enum.join([header] ++ skips ++ claims, "\n")
      end)

    Enum.join(sections ++ ac_report_section(ac), "\n\n")
  end

  defp ac_report_section(%{total: total, violated: [_ | _] = violated}) do
    header =
      "## evidence: acceptance criteria — #{length(violated)} of #{total} assertions " <>
        "violated (engine-verified against the project tree)"

    lines =
      Enum.map(violated, fn result ->
        "- [violated] #{result.ac_id}: #{result.assertion} — #{result.reason}"
      end)

    [Enum.join([header | lines], "\n")]
  end

  defp ac_report_section(_none_violated), do: []

  defp evidence_skip_lines(observations) do
    for {half, {:skip, reason}} <- [
          {"transcript", observations.tool_rows},
          {"wave diff", observations.changed_paths}
        ] do
      "- (#{half} unavailable: #{reason})"
    end
  end

  # Durable-then-notify (the infra-observability shape): one Trace + one
  # telemetry count per classified emission, plus skip notes for the degraded
  # halves. Emitted only after `commit_wave` succeeded.
  defp emit_evidence_observability(%{classifications: []}, _state), do: :ok

  defp emit_evidence_observability(record, state) do
    Enum.each(record.classifications, fn {emission, observations, classification} ->
      JidoClaw.Trace.emit(:composer, %{
        event: :evidence_classified,
        stage: emission.stage,
        verdict: classification.verdict,
        counts: classification.counts,
        parent_run_id: state.parent_run_id
      })

      :telemetry.execute([:jido_claw, :evidence], %{count: 1}, %{
        verdict: classification.verdict
      })

      if Enum.any?(classification.claims, &(&1.status == :unsupported)) do
        :telemetry.execute([:jido_claw, :evidence, :breach], %{count: 1}, %{
          stage: emission.stage
        })
      end

      Enum.each(evidence_skip_reasons(observations), fn {half, reason} ->
        JidoClaw.Trace.emit(:composer, %{
          event: :evidence_skipped,
          stage: emission.stage,
          half: half,
          reason: reason,
          parent_run_id: state.parent_run_id
        })
      end)
    end)

    ac_breach_telemetry(record.ac)
  end

  # The AC arm of the breach counter: once per wave with violations, tagged
  # with the validator-reserved synthetic stage (`"evidence:ac"` — invariant
  # 12 keeps a real stage from ever aliasing it).
  defp ac_breach_telemetry(%{violated: [_ | _]}) do
    :telemetry.execute([:jido_claw, :evidence, :breach], %{count: 1}, %{stage: "evidence:ac"})
  end

  defp ac_breach_telemetry(_none_violated), do: :ok

  defp evidence_skip_reasons(observations) do
    for {half, {:skip, reason}} <- [
          {:transcript, observations.tool_rows},
          {:files, observations.changed_paths}
        ],
        do: {half, reason}
  end

  # The fix-loop stop reasons, combined into ONE shared lens list so BOTH
  # consumers — Hook R (skip the fixer re-fire) and the tick's
  # `finish_terminal(:not_converged, …)` reclassification — read the same
  # decision and can never disagree:
  #
  #   (a) re-review budget exhausted (`rereview_exhausted_lenses/1`) — a
  #       forward-lens reviewer with `findings:<lens>` live and a fixer on the
  #       live route whose `rerun_counts` is already AT the cap (`>=
  #       rerun_cap`: the NEXT Hook-F invalidation would trip `count > cap`,
  #       so firing the fixer would land a fix its flagged lens can never
  #       re-review — the no-fix-without-re-review-budget rule). Distinct
  #       from `exhausted_fix_lenses/1`'s `> cap` post-trip classifier.
  #   (b) stalled (`stall_evidence/1`) — a stuck or oscillating finding key.
  defp fix_stop_lenses(state) do
    (rereview_exhausted_lenses(state) ++ stalled_lenses(state))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp suppress_fix_dispatch?(state), do: fix_stop_lenses(state) != []

  defp rereview_exhausted_lenses(state) do
    if fixer_on_live_route?(state) do
      catalog_exhausted =
        for {name, %Stage{lens: lens} = stage} <- state.catalog,
            is_binary(lens),
            not verify_authority_stage?(stage),
            on_live_route?(stage, state.live),
            MapSet.member?(state.live, "findings:#{lens}"),
            Map.get(state.rerun_counts, name, 0) >= state.rerun_cap,
            do: lens

      catalog_exhausted ++ evidence_rereview_exhausted(state)
    else
      []
    end
  end

  # Item 10 (OB1-3): the reserved engine lens has no catalog stage and no
  # rerun counter of its own — its re-check is deterministic and free (every
  # producer wave), so its re-review budget IS the fixer's rerun count (each
  # evidence re-fire invalidates the fixer). `>=` mirrors the catalog
  # pre-trip condition above; `>` in `evidence_exhausted_fix/1` mirrors
  # `exhausted_fix_lenses/1`'s post-trip classifier.
  defp evidence_rereview_exhausted(state) do
    if MapSet.member?(state.live, "findings:evidence") and
         fixer_rerun_count(state) >= state.rerun_cap,
       do: ["evidence"],
       else: []
  end

  defp fixer_rerun_count(state) do
    case fixer_name(state) do
      name when is_binary(name) -> Map.get(state.rerun_counts, name, 0)
      nil -> 0
    end
  end

  defp stalled_lenses(state), do: Enum.map(stall_evidence(state), & &1.lens)

  # Stuck/oscillation evidence over the folded `finding_rounds`, restricted to
  # FORWARD review lenses (verify-authority stages excluded — the engine
  # verify / reverse-verify families have their own budgets and terminals).
  # Per lens with `round >= 2`:
  #
  #   stuck       = current ∩ prior                    (same key, consecutive)
  #   oscillating = current ∩ (seen_prior \ prior)     (vanished ≥1 round, back)
  #
  # Un-keyable findings never enter `finding_rounds` (FindingKey's nil — the
  # camus fail-safe), so they can never stall-match. `trend` is ADVISORY only.
  defp stall_evidence(state) do
    forward = review_lenses(state)

    for {lens, entry} <- Map.get(state, :finding_rounds, %{}),
        MapSet.member?(forward, lens),
        entry.round >= 2,
        stuck = MapSet.intersection(entry.current_keys, entry.prior_keys),
        oscillating =
          MapSet.intersection(
            entry.current_keys,
            MapSet.difference(entry.seen_prior, entry.prior_keys)
          ),
        MapSet.size(stuck) > 0 or MapSet.size(oscillating) > 0 do
      %{
        lens: lens,
        round: entry.round,
        stuck: Enum.sort(stuck),
        oscillating: Enum.sort(oscillating),
        trend: key_trends(MapSet.union(stuck, oscillating), entry)
      }
    end
  end

  defp forward_review_lenses(catalog) do
    for {_name, %Stage{lens: lens} = stage} <- catalog,
        is_binary(lens),
        not verify_authority_stage?(stage),
        into: MapSet.new(),
        do: lens
  end

  # Item 10 (OB1-3): the review-lens universe = catalog forward lenses ∪ the
  # reserved `"evidence"` lens iff it has ever been active on this run (an
  # `evidence` finding round exists) — so stuck/oscillating fabrication keys
  # stall exactly like reviewer findings, and a run that never breached scans
  # byte-identically.
  defp review_lenses(state) do
    base = forward_review_lenses(state.catalog)

    if Map.has_key?(Map.get(state, :finding_rounds, %{}), "evidence"),
      do: MapSet.put(base, "evidence"),
      else: base
  end

  # `%{key => :falling | :steady}`: falling when the reviewer's confidence in
  # the key dropped likely → unsure across the stall ("lean ACCEPT — probably
  # stale"); steady otherwise ("lean REFINE"). Advisory only — never routing.
  defp key_trends(keys, entry) do
    Map.new(keys, fn key ->
      prior = mark_confidence(entry.prior_marks, key)
      current = mark_confidence(entry.current_marks, key)
      trend = if prior == "likely" and current == "unsure", do: :falling, else: :steady
      {key, trend}
    end)
  end

  defp mark_confidence(marks, key) do
    Enum.find_value(marks, fn
      %{key: ^key, confidence: confidence} -> confidence
      _mark -> nil
    end)
  end

  # ---------------------------------------------------------------------------
  # Item 5 — deterministic verify: tamper markers, certification, sealed heads
  # ---------------------------------------------------------------------------

  # The evidence-preserving tamper record (payload bounded: stage + bounded
  # reason + the report ref — log tails live only inside the encrypted
  # report). The ref rides THIS marker, never `artifacts_produced` — a tamper
  # report must not look routable via `Fold.available/1`; `commit_wave`'s
  # wave-scoped pending→active promotion still activates the row.
  defp tampered_markers(emissions) do
    for %StageEmission{stage: stage, outcome: {:tampered, reason}} = emission <- emissions do
      {:stage_tampered, %{stage: stage, reason: reason, report_ref: report_ref(emission)}}
    end
  end

  defp report_ref(%StageEmission{artifacts: artifacts}) do
    case Map.get(artifacts, "verify-report") do
      ref when is_binary(ref) -> ref
      _absent -> nil
    end
  end

  # Fail closed BEFORE the durable green (law 4): a verify emission whose
  # `clean:<lens>` carries no valid certification becomes an inconclusive
  # infra retry — signals/artifacts stripped (a non-`:ok` emission is never
  # folded), report reachability preserved via `verify_report_recorded`.
  defp reclassify_uncertified_greens(emissions, state) do
    {reclassified, marker_lists} =
      Enum.map_reduce(emissions, [], fn emission, marker_lists ->
        if uncertified_green?(emission, state) do
          stripped = %{
            emission
            | signals: [],
              artifacts: %{},
              outcome: {:inconclusive, "uncertified_green"},
              certification: nil
          }

          {stripped, [report_recorded_markers(emission) | marker_lists]}
        else
          {emission, marker_lists}
        end
      end)

    {reclassified, List.flatten(Enum.reverse(marker_lists))}
  end

  defp uncertified_green?(
         %StageEmission{outcome: :ok, certification: nil} = emission,
         state
       ) do
    case verify_clean_signal(state.catalog, emission.stage) do
      signal when is_binary(signal) -> signal in emission.signals
      nil -> false
    end
  end

  defp uncertified_green?(%StageEmission{}, _state), do: false

  defp report_recorded_markers(emission) do
    case report_ref(emission) do
      nil ->
        []

      ref ->
        [
          verify_report_recorded: %{
            stage: emission.stage,
            report_ref: ref,
            reason: "uncertified_green"
          }
        ]
    end
  end

  # The compact green certificate, welded into the SAME commit as the
  # `clean:<lens>` publish (shas/digests are not secrets): folded to
  # `verified_integrity`, so the convergence-time re-check never decrypts the
  # report.
  defp certified_markers(verdict_emissions, state) do
    for %StageEmission{certification: %{} = cert} = emission <- verdict_emissions,
        signal = verify_clean_signal(state.catalog, emission.stage),
        is_binary(signal),
        signal in emission.signals do
      {:verify_certified,
       %{
         stage: emission.stage,
         head: cert.head,
         tree_digest: cert.tree_digest,
         mode: Atom.to_string(cert.mode)
       }}
    end
  end

  # The `clean:<lens>` signal a verify-unit stage publishes, or nil for any
  # other stage (the canonical predicate every item-5 consumer routes through).
  defp verify_clean_signal(catalog, name) do
    case Map.get(catalog, name) do
      %Stage{unit: {:verify, _unit}, lens: lens} when is_binary(lens) -> "clean:#{lens}"
      _other -> nil
    end
  end

  # Engine head observation at the wave boundary (C1-6b — runs with a verify
  # stage + a project_dir only): weld `head_observed` on the FIRST observation
  # (the durable baseline — an in-memory-only baseline could be laundered by a
  # crash + external move before recovery) and on every observed change. A
  # move while a `clean:<verify-lens>` is live also welds the retraction +
  # re-verify markers into the SAME txn (no stale green survives the commit).
  # An unreadable capture welds nothing — the convergence-time re-check is the
  # backstop that refuses to converge on unverifiable state.
  defp head_observation_markers(next_fold, state) do
    with true <- has_verify_stage?(state.catalog),
         dir when is_binary(dir) <- verify_project_dir(state),
         sha when is_binary(sha) <- Verify.git().head(dir) do
      head_markers(sha, next_fold, state.observed_head)
    else
      _unobservable -> []
    end
  end

  defp head_markers(sha, _next_fold, nil), do: [head_observed: %{head: sha}]

  defp head_markers(sha, next_fold, observed) when sha != observed do
    [head_observed: %{head: sha}] ++ moved_head_retractions(next_fold)
  end

  defp head_markers(_sha, _next_fold, _observed), do: []

  defp moved_head_retractions(next_fold) do
    case live_verify_cleans(next_fold) do
      [] ->
        []

      cleans ->
        {stages, signals} = Enum.unzip(cleans)

        [
          signals_retracted: %{signals: Enum.sort(signals)},
          stages_invalidated: %{stages: Enum.sort(stages)}
        ]
    end
  end

  # Verify-unit stages whose `clean:<lens>` is currently live, as
  # `{stage, signal}` pairs. Works over the full state AND a `Fold.fold`
  # result (both carry `:catalog` + `:live`).
  defp live_verify_cleans(state) do
    for {name, %Stage{unit: {:verify, _unit}, lens: lens}} <- state.catalog,
        is_binary(lens),
        MapSet.member?(state.live, "clean:#{lens}"),
        do: {name, "clean:#{lens}"}
  end

  defp has_verify_stage?(catalog) do
    Enum.any?(catalog, fn {_name, %Stage{unit: unit}} -> match?({:verify, _name}, unit) end)
  end

  # One loud trace per tampered stage, POST-commit (durable-then-notify). The
  # bounded reason rides the trace channel; tails stay in the encrypted report.
  # Trace ONLY — the `jido_claw.verify.total` counter is the reactor's single
  # bump per engine verify (telemetry.ex), and this path also re-runs on a
  # restart's dedupe-observe re-fold, where the reactor never fired.
  defp emit_tampered_observability(emissions, state) do
    Enum.each(emissions, fn %StageEmission{stage: stage, outcome: {:tampered, reason}} ->
      JidoClaw.Trace.emit(
        :composer,
        %{
          event: :verify_tampered,
          run_id: state.parent_run_id,
          parent_run_id: state.parent_run_id,
          stage: stage,
          reason: reason,
          wave_index: state.wave_index,
          tenant_id: state.tenant
        },
        %{count: 1}
      )
    end)
  end

  # The observability projection of the non-`:ok` emissions (tampered was
  # extracted upstream). `handle_wave_value`'s split, `infra_stages`, and
  # `infra_markers` fold BOTH `{:infra, _}` and `{:inconclusive, _}` (item 5's
  # deterministic verify produces it — refusals + the uncertified-green
  # reclassification) into the infra lane by stage name, so this consumer folds
  # both too — the "consumers fold `{:inconclusive, _}` into the infra lane"
  # contract (the `IterativeStep` precedent). Matching `{:infra, _}` alone would
  # `FunctionClauseError` on an inconclusive emission AFTER `commit_wave` already
  # wrote its marker.
  defp infra_outcomes(infra_emissions) do
    Enum.map(infra_emissions, fn %StageEmission{stage: stage, outcome: {kind, reason}}
                                 when kind in [:infra, :inconclusive] ->
      {stage, reason}
    end)
  end

  # One trace + one counter per infra'd stage, fired POST-commit (durable-then-
  # notify). Called before `record_wave` bumps the index, so `wave_index` names
  # the infra'd wave. The bounded `reason` string rides the trace channel only,
  # never the durable `stage_infra` payload; `run_id` is included because the
  # trace collector indexes by `:run_id`/`:request_id`, and `tenant_id`
  # (post-review P2) because the `by_run` index has no public reader — the
  # tenant stamp is what makes the per-run timeline reachable
  # (`Trace.list({:tenant, …})`) and tenant-scopes the durable sink rows.
  defp emit_infra_observability(stage_reasons, lane, state) do
    Enum.each(stage_reasons, fn {stage, reason} ->
      Telemetry.emit_composer_infra(lane, stage)

      JidoClaw.Trace.emit(
        :composer,
        %{
          event: :review_infra,
          run_id: state.parent_run_id,
          parent_run_id: state.parent_run_id,
          stage: stage,
          reason: reason,
          wave_index: state.wave_index,
          lane: lane,
          tenant_id: state.tenant
        },
        %{count: 1}
      )
    end)
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
      context: seed_criteria_context(state),
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

  # Item 9: thread the run's acceptance criteria into the worker-wave context
  # ONLY when premises carry them — `AgentRunner.resolve_scope/2` picks the
  # key into `ToolContext`, where `verify_certificate` appends the criteria
  # block engine-side (never LLM-relayed). Absent criteria leave the context
  # byte-identical; gate/verify waves keep the bare context (no tool scope).
  defp seed_criteria_context(state) do
    case Premises.criteria(state.premises) do
      [] -> state.context
      criteria -> Map.put(state.context, :acceptance_criteria, criteria)
    end
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

  # `outcome` rides into history (camus C1-3) so an infra'd stage's entry is
  # legible — the entry would otherwise silently drop it.
  defp emission_entry(%StageEmission{} = emission) do
    %{
      stage: emission.stage,
      signals: emission.signals,
      artifacts: emission.artifacts,
      outcome: emission.outcome
    }
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

    case Commit.start_wave(state.parent, markers, commit_opts(state)) do
      :ok -> :ok
      {:error, :parent_terminal} = halt -> halt
      # WS2: propagate the token-fence so the caller's else stops clean (the wave
      # never launches un-recorded under a stale claim).
      {:error, :parent_fenced} = halt -> halt
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

  # Canonical sha256 hex over a deterministic term (`CanonicalHash` — never
  # `:erlang.phash2`, `feedback_canonical_fingerprint_term`); in 2c these are
  # correlation / catalog-drift-detection metadata only.
  defp wave_started_payload(dispatch, display, state) do
    %{
      wave_index: state.wave_index,
      stages: dispatch,
      route_hash: CanonicalHash.sha256_term(Enum.sort(display.route)),
      catalog_hash: CanonicalHash.sha256_term(Enum.sort_by(state.catalog, &elem(&1, 0)))
    }
  end

  # The wave's content deltas, derived by DIFFING pre/post `Fold` state — the
  # construction that makes `ComposerProjection.project(seed, log)` equal the
  # in-memory fold. Signals are sorted lists (JSON-safe + deterministic);
  # `signals_retracted` captures a paired-verdict flip (NOT assumed empty);
  # artifacts are the new/changed `{name, producer, ref}` triples (bare ref).
  # `non_completed_stages` — the infra'd (camus C1-3) AND tampered (item 5)
  # stages — are subtracted from `wave_completed.stages`: neither was folded
  # into `ran` (only `infra_stages` additionally get `:stage_infra` markers;
  # tampered stages get `:stage_tampered`), so recording either as completed
  # would make the durable rebuild diverge from the in-memory fold — a rebuild
  # folding a tampered stage into `ran` would dedupe onto the corpse instead
  # of terminalizing.
  defp wave_deltas(state, next_fold, dispatch, non_completed_stages) do
    %{
      stages: dispatch -- non_completed_stages,
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
      artifact_triple(name, producer, bare_ref(entry))
    end
  end

  # The `artifacts_produced` marker entry shape (bare ref), single-sourced across
  # the wave-delta diff, the genesis seed rows, and the AR-8c verify-feedback
  # marker (the projection folds it back into the tagged `{:ref, ref}` store).
  defp artifact_triple(name, producer, ref), do: %{name: name, producer: producer, ref: ref}

  defp bare_ref({:ref, ref}), do: ref
  defp bare_ref(other), do: other

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

  # WS2: `auth_opts` + the held lease token, for the PARENT-targeting `Commit.*`
  # marker/fold writes (all target `state.parent`). The token engages the durable
  # token-fence in `Commit.guarded_wave_txn/4`, so a stale owner's markers roll
  # back instead of corrupting the reclaimer's log. nil token (unleased) ⇒
  # byte-identical to `auth_opts` (`WorkflowLog.append`'s `fence_context(nil)` adds
  # no context key; the fence is nil-safe). NOT used for the non-parent
  # `auth_opts` append in `teardown_parked_gate` (a parent token on a child write
  # would mis-fence).
  defp commit_opts(state),
    do: Keyword.put(auth_opts(state), :claim_fence_token, state.claim_token)

  # ---------------------------------------------------------------------------
  # Gate park / wake (Phase 4)
  # ---------------------------------------------------------------------------

  # Park on a gate halt: subscribe-once to the gates topic (so the operator's
  # decision wakes us), then append the durable `wave_paused` marker. `parked` is
  # set BEFORE the append so the composer wakes even if the marker append is mid-
  # retry. Do NOT bump `wave_index` / `record_wave` / re-append the start markers —
  # the wave is not done.
  defp park_gate(case_id, child, dispatch, display, state) do
    state = ensure_gates_subscribed(state)

    park = %{
      wave_index: state.wave_index,
      case_id: case_id,
      child_run_id: child.id,
      dispatch: dispatch,
      display: display
    }

    %{state | parked: park}
    |> arm_park_deadline()
    |> attempt_wave_paused(0)
  end

  # Append `wave_paused` under the parent-terminal fence, with the retry/exhaust/
  # teardown branches (Phase 4b): the gate is VALIDLY parked here (open case +
  # `:awaiting_approval` child), so a failed marker append must never terminalize
  # the parent nor tear the gate down — only an externally-cancelled
  # `:parent_terminal` tears it down (the parent IS terminal, so the case would be
  # a real orphan). Otherwise retry (transient) or park-in-memory-anyway (exhausted):
  # the live composer still wakes on the decision, the parent stays `:running`
  # (recoverable), and recovery derives the park from `wave_started` even without
  # the marker.
  defp attempt_wave_paused(%{parked: park} = state, attempt) do
    case Commit.append_markers(
           state.parent,
           [wave_paused: wave_paused_payload(park)],
           commit_opts(state)
         ) do
      :ok ->
        {:noreply, state}

      {:error, :parent_terminal} ->
        teardown_parked_gate(state)

      # WS2: a fence is NOT a parent terminal — another owner reclaimed this still-
      # `:running` parent. Stop clean and leave the gate `AgentCase` OPEN (do NOT
      # tear it down) so the reclaiming node re-parks it. This is the deliberate
      # divergence from the `:parent_terminal` arm above.
      {:error, :parent_fenced} ->
        {:stop, :normal, state}

      {:error, reason} when attempt < @max_wave_paused_attempts ->
        Logger.warning(
          "[RouteComposer] wave_paused append attempt #{attempt + 1} failed for parent " <>
            "#{state.parent_run_id} (#{inspect(reason)}); retrying"
        )

        Process.send_after(
          self(),
          {:retry_wave_paused, park.child_run_id, attempt + 1},
          rebuild_backoff(attempt)
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "[RouteComposer] wave_paused append exhausted for parent #{state.parent_run_id} " <>
            "(#{inspect(reason)}); parked in-memory, durable marker missing — recovery derives " <>
            "the park from wave_started"
        )

        {:noreply, state}
    end
  end

  # The ONLY teardown path: the parent was cancelled externally during the park,
  # so the open gate case is a real orphan. Dispose it through the FENCED
  # aggregate primitive (run lock first + status re-check, so a raced operator
  # decision is never bulldozed). A raced reject/abandon (`{:decided,
  # :cancelled/:abandoned}`) already converged the pair itself; a raced APPROVE
  # (`{:decided, :running}`) did NOT — it is resuming the child under a parent
  # nobody will ever fold, so it is converged here (`converge_raced_teardown`).
  # Always stop `:normal` — disposition/cancel failures are left for recovery's
  # terminal-parent reconciliation (`WorkflowRecovery`'s `:parked` /
  # `:decision_recorded` branches) — never a busy-loop.
  defp teardown_parked_gate(%{parked: park} = state) do
    park.child_run_id
    |> GateDisposition.fail_orphaned_parked_child(
      "composer parent terminal during gate park",
      auth_opts(state)
    )
    |> converge_raced_teardown(park.child_run_id, state)

    {:stop, :normal, state}
  end

  # A raced approve won the disposition fence and is resuming the child under
  # the terminal parent: cancel it — `Cancellation.cancel/2` is the centralized
  # stop-a-running-run producer (durable `run_cancelled` first, then kills the
  # mid-resume executor, cross-node included). `:already_terminal` means the
  # resume finished before the cancel landed — its side effects already ran
  # (the accepted sub-millisecond residual; `Cases.decide/4`'s approve refusal
  # minimizes entry into this window).
  defp converge_raced_teardown({:error, {:decided, :running}}, child_run_id, state) do
    case Cancellation.cancel(child_run_id, auth_opts(state)) do
      {:ok, _run} ->
        :ok

      {:error, :already_terminal} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RouteComposer] teardown cancel of raced child #{child_run_id} failed: " <>
            "#{inspect(reason)}; leaving for recovery"
        )
    end
  end

  defp converge_raced_teardown(_other, _child_run_id, _state), do: :ok

  defp ensure_gates_subscribed(%{gates_subscribed: true} = state), do: state

  defp ensure_gates_subscribed(state) do
    RunPubSub.subscribe_gates()
    %{state | gates_subscribed: true}
  end

  # The wake decision: reload the parked child and branch on its terminal STATUS
  # (the truth), polling a not-yet-terminal child (approve broadcast landed before
  # `GateResume` finished) to terminal first. Reused by recovery's `re_enter_park`.
  # `:failed` gets an EXPLICIT arm — left to the reload-blip catch-all it would
  # keep the parent parked forever (see `terminalize_failed_gate_child`).
  defp resolve_parked_gate(%{parked: park} = state) do
    case WorkflowRun.by_id(park.child_run_id, tenant: state.tenant, actor: state.actor) do
      {:ok, %WorkflowRun{status: :completed} = child} ->
        fold_resumed_gate(child, state)

      {:ok, %WorkflowRun{status: status} = child}
      when status in [:running, :pending, :awaiting_approval] ->
        observe_then_resolve(child, state)

      {:ok, %WorkflowRun{status: :cancelled} = child} ->
        terminalize_gate_disposition(:rejected, child, state)

      {:ok, %WorkflowRun{status: :abandoned} = child} ->
        terminalize_gate_disposition(:abandoned, child, state)

      {:ok, %WorkflowRun{status: :failed} = child} ->
        terminalize_failed_gate_child(child, state)

      other ->
        # Reload failed (a DB blip): stay parked and leave it for recovery's
        # re_enter_park on the next boot — the decision is durable, so it is never
        # lost; we just can't observe it right now.
        Logger.warning(
          "[RouteComposer] parked-child reload failed for parent #{state.parent_run_id} " <>
            "(#{inspect(other)}); staying parked for recovery"
        )

        {:noreply, state}
    end
  end

  # The approve broadcast can land before `GateResume.resume/2` finishes
  # (`cases.ex:281-284`), so a child seen `:running`/`:awaiting_approval` is polled
  # to terminal before we fold — the fold ALWAYS reads `:completed`, never the
  # broadcast (else the implementer releases against an unwritten `plan-approved`).
  defp observe_then_resolve(child, %{parked: park} = state) do
    case await_existing_child(child, state) do
      {:ok, %WorkflowRun{status: :completed} = done} ->
        fold_resumed_gate(done, state)

      {:ok, %WorkflowRun{status: :cancelled} = done} ->
        terminalize_gate_disposition(:rejected, done, state)

      {:ok, %WorkflowRun{status: :abandoned} = done} ->
        terminalize_gate_disposition(:abandoned, done, state)

      {:ok, %WorkflowRun{} = other} ->
        finish_failed(
          {:gate_resume_not_terminal, other.status},
          other,
          park.dispatch,
          park.display,
          state
        )

      {:error, reason} ->
        finish_failed(reason, child, park.dispatch, park.display, state)
    end
  end

  # Approve resolved: append `wave_resumed` (provenance), clear the park, then fold
  # the child's durable emission through the SAME `handle_wave_value` path a worker
  # wave uses — appending `wave_completed` + content and promoting the gate's
  # `:pending` `approved-plan` to `:active` via `commit_wave`'s `activate_for_wave`,
  # then `{:continue, :tick}`. The next `compose_route` sees `plan-approved` live →
  # the implementer's lock is inactive → it dispatches. `wave_index` is unchanged
  # (the park never bumped it), so `commit_wave` keys on the gate's own wave index.
  defp fold_resumed_gate(child, %{parked: park} = state) do
    cleared = clear_park(state)

    case Commit.append_markers(
           cleared.parent,
           [wave_resumed: wave_resumed_payload(park)],
           commit_opts(cleared)
         ) do
      :ok ->
        handle_wave_value(
          decode_emissions(child.result),
          child,
          park.dispatch,
          park.display,
          cleared
        )

      {:error, :parent_terminal} ->
        {:stop, :normal, cleared}

      # WS2: a reclaiming node rotated the token while we resumed — stop clean and
      # write nothing, leaving the gate's fold to the new owner.
      {:error, :parent_fenced} ->
        {:stop, :normal, cleared}

      {:error, reason} ->
        finish_failed(reason, child, park.dispatch, park.display, cleared)
    end
  end

  # Reject/abandon → the parent's disposition terminal (Phase 4c). Reused by the
  # live wake path AND the dedupe-hit `:cancelled`/`:abandoned` clause so the live
  # and crash-recovery paths cannot drift. `route_rejected`/`route_abandoned`
  # project onto `:cancelled` + `result.disposition`, dropping the held route.
  #
  # Phase 4e reject opt-in: when the catalog has a `plan-rejected` subscriber, a
  # reject from a PARKED gate RE-PLANS (re-earns approval) instead of terminating;
  # abandon never re-plans, and a reject with no parked context (dedupe-hit) takes
  # the committed default.
  defp terminalize_gate_disposition(:rejected, child, %{parked: park} = state)
       when is_map(park) do
    gate_stage = Map.fetch!(state.catalog, hd(park.dispatch))

    # AR-8c (B6): the re-plan opt-in is catalog-GLOBAL (`any_subscriber?` scans the
    # whole catalog, where the planner always subscribes `plan-rejected`), so a
    # rejected SAFETY-gate would otherwise re-fire the planner. Narrow it to the
    # *parked gate itself publishing the re-plan signal*: the plan-gate publishes
    # `plan-rejected` → unchanged re-plan; the safety-gate does not → its reject
    # takes the `else` branch (cancel — the user declined the change), never loops
    # back to planning.
    if "plan-rejected" in gate_stage.publishes and any_subscriber?(state.catalog, "plan-rejected") do
      replan_after_reject(park, gate_stage, clear_park(state))
    else
      finish({:rejected, {:child_cancelled, child.id}}, clear_park(state))
    end
  end

  defp terminalize_gate_disposition(:rejected, child, state),
    do: finish({:rejected, {:child_cancelled, child.id}}, clear_park(state))

  defp terminalize_gate_disposition(:abandoned, child, state),
    do: finish({:abandoned, {:child_abandoned, child.id}}, clear_park(state))

  # An approved-then-FAILED gate child (`GateResume.fail_with_audit` appends
  # `run_failed` after `approval_resolved` on a corrupt checkpoint / missing
  # approved case / resume crash): the gate can never make progress, so the
  # parent terminalizes `route_failed`. This must be an EXPLICIT arm in both
  # resolvers — `:failed` falling into their reload-blip catch-alls keeps the
  # parent parked with no wake ever coming (the decision broadcast resolves to
  # the same `:failed` read), stranding a sensitive run past its retention
  # deadline across restarts.
  defp terminalize_failed_gate_child(child, %{parked: park} = state) do
    finish_failed({:child_failed, child.id}, child, park.dispatch, park.display, state)
  end

  defp wave_paused_payload(park) do
    %{wave_index: park.wave_index, agent_case_id: park.case_id, child_run_id: park.child_run_id}
  end

  defp wave_resumed_payload(park) do
    %{wave_index: park.wave_index, agent_case_id: park.case_id, child_run_id: park.child_run_id}
  end

  # ---------------------------------------------------------------------------
  # Sensitive-park deadline (O-M2)
  #
  # Deadline semantics for a delayed timer (decided): the deadline is a hard
  # bound on the RUN, not a retroactive invalidator of committed gate decisions.
  # `Cases.decide/4` commits case + child transitions in one transaction and
  # only THEN broadcasts, so a `{:park_deadline, …}` message already in the
  # mailbox can be processed after a decision durably committed. Such a fire is
  # STALE: the disposal reloads the child FIRST and routes a decided child
  # through the normal gate-resolution path (fold an approval, reject-terminal a
  # reject) instead of bulldozing the parent `route_abandoned`. The RUN still
  # terminates at the very next tick — `over_budget?/1` includes
  # `past_deadline?` and `budget_reason/1` yields `{:deadline, deadline_at_ms}`
  # — so the sensitive-retention bound holds to within one fold. Retroactively
  # discarding a committed approval (comparing the decision timestamp to
  # `deadline_at_ms`) is rejected by design: it would abandon a parent whose
  # approved child is legitimately running/resuming (the C-H1 orphan shape) and
  # mix timestamp authorities, buying only one tick of earlier termination.
  # ---------------------------------------------------------------------------

  @park_deadline_reason "sensitive-context gate deadline exceeded"

  # Arm a park-time deadline timer ONLY for a sensitive-marked run carrying a
  # durable `deadline_at_ms` (a normal run waits on the gate indefinitely by
  # design). `Process.send_after` returns the timer handle, so the identity that
  # guards a stale fire must be a SEPARATE `make_ref/0` carried IN the message. An
  # already-past deadline gives `max(…, 0) = 0` → fires next and disposes at once.
  defp arm_park_deadline(
         %{
           sanitize_sensitive_context: true,
           deadline_at_ms: deadline_at_ms,
           parked: %{child_run_id: child_run_id, case_id: case_id}
         } = state
       )
       when is_integer(deadline_at_ms) do
    deadline_ref = make_ref()
    delay = max(deadline_at_ms - System.os_time(:millisecond), 0)

    timer_ref =
      Process.send_after(self(), {:park_deadline, deadline_ref, child_run_id, case_id}, delay)

    %{state | deadline_ref: deadline_ref, timer_ref: timer_ref}
  end

  defp arm_park_deadline(state), do: state

  # Clear the park AND cancel any armed deadline timer — the single park-exit point
  # (used at every `parked → nil` site). Idempotent: cancelling a nil or
  # already-fired timer is a harmless no-op.
  defp clear_park(%{timer_ref: timer_ref} = state) do
    cancel_park_timer(timer_ref)
    %{state | parked: nil, deadline_ref: nil, timer_ref: nil}
  end

  defp cancel_park_timer(nil), do: :ok
  defp cancel_park_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  # The fired timer's `deadline_ref` + `child_run_id` must match the CURRENT park
  # slot. A mismatch means the gate resolved, a later gate re-parked (fresh
  # `deadline_ref`), or a re-arm superseded this one — ignore the stale fire.
  defp park_deadline_match?(%{parked: park, deadline_ref: deadline_ref}, fired_ref, child_run_id) do
    is_map(park) and not is_nil(deadline_ref) and deadline_ref == fired_ref and
      park.child_run_id == child_run_id
  end

  defp park_deadline_match?(_state, _fired_ref, _child_run_id), do: false

  # Deadline reached while parked: dispose the child + its pending case(s)
  # through the FENCED aggregate primitive (`GateDisposition` — run lock FIRST
  # in the global run → case → events order, status re-check on the LOCKED row,
  # case cancellations + child `run_abandoned` in one transaction), and branch
  # on its classified outcome. A decision committed before this message was
  # processed (approve → `:running`/`:completed`, reject → `:cancelled`,
  # abandon → `:abandoned`, failed resume → `:failed`) surfaces as
  # `{:decided, status}` with nothing written — the fire is STALE: route through
  # the normal gate-resolution path, never bulldoze the parent (the run itself
  # still terminates at the next tick's `past_deadline?` budget check; see the
  # section comment). A read/write blip: the sensitive-retention TTL wins — the
  # parent still terminalizes (best-effort; a pair the blip left un-disposed is
  # closed later by recovery's terminal-parent branch).
  defp dispose_park_deadline(state, child_run_id, _case_id) do
    case GateDisposition.deadline_abandon_parked_child(
           child_run_id,
           @park_deadline_reason,
           auth_opts(state)
         ) do
      {:ok, :disposed} ->
        finish({:abandoned, {:child_abandoned, child_run_id}}, clear_park(state))

      {:error, {:decided, _status}} ->
        resolve_parked_gate(state)

      {:error, reason} ->
        finish_past_deadline_child(state, child_run_id, reason)
    end
  end

  # The TTL-wins terminal: warn that the child pair could not be disposed, then
  # finish the PARENT `:abandoned` via the composer's own terminal path (which
  # also clears the park + cancels the already-fired timer). The un-disposed
  # parked-child + open-case pair stays CONSISTENT and is closed by recovery's
  # terminal-parent reconciliation (`WorkflowRecovery`'s `:parked` branch).
  defp finish_past_deadline_child(state, child_run_id, reason) do
    Logger.warning(
      "[RouteComposer] park-deadline child-terminal skipped for #{child_run_id} " <>
        "(#{inspect(reason)}); parent still terminalizes"
    )

    finish({:abandoned, {:child_abandoned, child_run_id}}, clear_park(state))
  end

  # ---------------------------------------------------------------------------
  # Camus C1-4 — review-stall park / done_with_findings (next-ten #6)
  #
  # A fix-loop stop (`{:fix_failed, lenses}` from either producer: the
  # `:not_converged` reclassification or the budget path) on a route whose
  # deterministic verify is GREEN AND CERTIFIED is a human release decision,
  # not a terminal: the composer parks CHILD-LESS on a run-bound
  # `:review_stall` case (the parent stays `:running` — an
  # `:awaiting_approval` composer row is recovery's dangling-gate arm) and
  # terminalizes from the case's durable status: approved ⇒
  # `:done_with_findings` (`:completed` + disposition), rejected ⇒
  # `fix_failed` as today, abandoned ⇒ `:abandoned`. Recovery needs ZERO new
  # code: a rebuild ends in a tick, re-derives the stop from folded state,
  # and `enter_or_resolve_review_stall/2` resolves the case by fingerprint —
  # the same function the live wake uses.
  # ---------------------------------------------------------------------------

  @stall_park_deadline_reason "sensitive-context review-stall deadline exceeded"

  # The C1-4 gate check on a fix-loop stop. The stall observability fires here
  # for BOTH exits — the stop itself is the event; like
  # `emit_tampered_observability/2`, a recovery rebuild re-derives the stop and
  # re-fires (accepted double-count on a crash, monotonic counters).
  defp finish_fixish({:fix_failed, lenses} = terminal, state) do
    emit_stall_observability(lenses, state)

    if verify_green_certified?(state) do
      enter_or_resolve_review_stall(lenses, state)
    else
      finish(terminal, state)
    end
  end

  # The gate trigger: a verify stage exists, its `clean:<verify-lens>` is
  # live, and every live green's certified integrity still holds
  # (`stale_verified_cleans/1` fails closed on a missing/unverifiable
  # certificate). Verify-less routes and red/uncertified verifies keep
  # today's `fix_failed` — the C1-5 stall already early-halted them.
  defp verify_green_certified?(state) do
    has_verify_stage?(state.catalog) and live_verify_cleans(state) != [] and
      stale_verified_cleans(state) == []
  end

  # Raise-or-resolve, idempotent by fingerprint: a pending case (raised before
  # a crash) re-parks without a duplicate open (the
  # `agent_cases_pending_fingerprint_index` fence); a decided-while-down case
  # terminalizes NOW through the same resolver the live wake uses; none opens
  # one. Any read/build error is the fail-safe `fix_failed` — the evidence is
  # durable, and a park we cannot represent must not strand the run.
  defp enter_or_resolve_review_stall(lenses, state) do
    with {:ok, park} <- build_stall_park(lenses, state),
         {:ok, cases} <- AgentCase.by_fingerprint(park.fingerprint, auth_opts(state)) do
      case cases do
        [%AgentCase{status: :pending} = agent_case | _rest] ->
          {:noreply, stall_park(state, %{park | case_id: agent_case.id})}

        [%AgentCase{} = agent_case | _rest] ->
          resolve_review_stall(stall_park(state, %{park | case_id: agent_case.id}))

        [] ->
          raise_stall_case(park, lenses, state)
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[RouteComposer] review-stall raise failed for parent #{state.parent_run_id} " <>
            "(#{inspect(reason)}); fail-safe fix_failed"
        )

        finish({:fix_failed, lenses}, state)
    end
  end

  # Open the run-bound case (case + `:opened` timeline event in one
  # transaction, NO run event — the parent must stay `:running`), then
  # broadcast the gate-requested notification AFTER the `:ok` commit
  # (durable-then-notify; a skipped notify never skips the write — recovery
  # resolves by fingerprint) and park.
  defp raise_stall_case(park, lenses, state) do
    attrs = %{
      workflow_run_id: state.parent_run_id,
      step_name: "review-stall",
      fingerprint: park.fingerprint,
      details: park.details
    }

    case WorkflowLog.case_open_runbound(state.parent, attrs, auth_opts(state)) do
      {:ok, agent_case} ->
        RunPubSub.broadcast_gate_requested(state.parent_run_id, state.tenant, agent_case.id)
        {:noreply, stall_park(state, %{park | case_id: agent_case.id})}

      {:error, reason} ->
        Logger.warning(
          "[RouteComposer] review-stall case open failed for parent #{state.parent_run_id} " <>
            "(#{inspect(reason)}); fail-safe fix_failed"
        )

        finish({:fix_failed, lenses}, state)
    end
  end

  # Enter the stall park: subscribe-once to the gates topic and arm the
  # sensitive-run deadline (a parked composer is idle and never reaches
  # `past_deadline?/1` on its own).
  defp stall_park(state, park) do
    state = ensure_gates_subscribed(state)
    arm_stall_park_deadline(%{state | stall_parked: park})
  end

  # The stall wake decision: reload the case and branch on its DURABLE status
  # (never the broadcast payload — the child-park posture). The composer is
  # the single status-authority writer for the parent: approved ⇒
  # `:done_with_findings`, rejected ⇒ `fix_failed`, abandoned ⇒ `:abandoned`,
  # cancelled ⇒ defensively `fix_failed` (findings-win), pending/reload blip ⇒
  # stay parked (the decision is durable; recovery re-resolves).
  defp resolve_review_stall(%{stall_parked: park} = state) when is_map(park) do
    case AgentCase.by_id(park.case_id, auth_opts(state)) do
      {:ok, %AgentCase{status: :approved}} ->
        finish({:done_with_findings, park.result}, clear_stall_park(state))

      {:ok, %AgentCase{status: :rejected}} ->
        finish({:fix_failed, park.lenses}, clear_stall_park(state))

      {:ok, %AgentCase{status: :abandoned}} ->
        finish({:abandoned, {:review_stall_abandoned, park.case_id}}, clear_stall_park(state))

      {:ok, %AgentCase{status: :cancelled}} ->
        finish({:fix_failed, park.lenses}, clear_stall_park(state))

      {:ok, %AgentCase{status: :pending}} ->
        {:noreply, state}

      other ->
        Logger.warning(
          "[RouteComposer] review-stall case reload failed for parent " <>
            "#{state.parent_run_id} (#{inspect(other)}); staying parked"
        )

        {:noreply, state}
    end
  end

  # Sensitive-run stall-park deadline (the O-M2 pair on the sibling park):
  # armed only for a marked run with a durable `deadline_at_ms`; a normal run
  # waits on its stall gate indefinitely by design.
  defp arm_stall_park_deadline(
         %{
           sanitize_sensitive_context: true,
           deadline_at_ms: deadline_at_ms,
           stall_parked: %{case_id: case_id}
         } = state
       )
       when is_integer(deadline_at_ms) do
    deadline_ref = make_ref()
    delay = max(deadline_at_ms - System.os_time(:millisecond), 0)
    timer_ref = Process.send_after(self(), {:stall_park_deadline, deadline_ref, case_id}, delay)

    %{state | stall_deadline_ref: deadline_ref, stall_timer_ref: timer_ref}
  end

  defp arm_stall_park_deadline(state), do: state

  # The single stall-park exit point (every `stall_parked → nil` site).
  defp clear_stall_park(state) do
    cancel_park_timer(state.stall_timer_ref)
    %{state | stall_parked: nil, stall_deadline_ref: nil, stall_timer_ref: nil}
  end

  defp stall_deadline_match?(
         %{stall_parked: park, stall_deadline_ref: armed_ref},
         fired_ref,
         case_id
       ) do
    is_map(park) and not is_nil(armed_ref) and armed_ref == fired_ref and
      park.case_id == case_id
  end

  # Deadline reached while stall-parked: abandon the pending case through the
  # kind-dispatched `Cases.abandon/3` (flip + timeline event + broadcast, no
  # `run_abandoned` — the parent is `:running` and the composer writes its own
  # terminal). An already-decided case (`:not_pending`) is the stale-fire
  # analogue of `{:decided, _}` — route through the normal resolver. Any other
  # failure: the sensitive-retention TTL wins — the parent still terminalizes
  # `:abandoned` (the `finish_past_deadline_child/3` posture; the pending case
  # is left for the operator surfaces, which refuse decisions on a terminal
  # parent's stall by the composer simply being gone).
  defp dispose_stall_park_deadline(%{stall_parked: %{case_id: case_id}} = state, case_id) do
    abandon_attrs = %{cancellation_reason: @stall_park_deadline_reason}

    case Cases.abandon(case_id, abandon_attrs, auth_opts(state)) do
      {:ok, _abandoned} ->
        finish({:abandoned, {:review_stall_deadline, case_id}}, clear_stall_park(state))

      {:error, :not_pending} ->
        resolve_review_stall(state)

      {:error, reason} ->
        Logger.warning(
          "[RouteComposer] review-stall deadline abandon failed for case #{case_id} " <>
            "(#{inspect(reason)}); parent still terminalizes"
        )

        finish({:abandoned, {:review_stall_deadline, case_id}}, clear_stall_park(state))
    end
  end

  # Build everything the park needs: the decrypted + redacted + bounded
  # finding entries (the gate's operator display), the finding keys (waive
  # completeness), the fingerprint, the terminal result payload (keys + counts
  # only — never bodies), and the case details. The raise-time decrypt here is
  # a DOCUMENTED second controlled decrypt site beside `ArtifactContext`
  # (see that moduledoc): values flow only into the redacted-bounded case
  # details, never back into live execution.
  defp build_stall_park(lenses, state) do
    with {:ok, tagged} <- stall_findings(lenses, state) do
      entries = redacted_finding_entries(tagged)

      # Pinned coupling: the top-level waive-required list IS the per-finding
      # keys (un-keyable findings are excluded from stall detection and are
      # not waive-required, but stay listed for the operator).
      keys =
        entries
        |> Enum.map(& &1["key"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      fingerprint =
        CanonicalHash.sha256_term({:review_stall_v1, state.parent_run_id, keys})

      evidence = stall_evidence(state)
      stall = Enum.map(evidence, &Map.take(&1, [:lens, :round, :stuck, :oscillating]))
      trend = merged_trend(evidence)
      total = length(entries)
      {shown, overflow} = Enum.split(entries, @stall_findings_cap)
      severity_counts = Enum.frequencies_by(entries, &(&1["severity"] || "unknown"))
      head = certified_head(state)

      result = %{
        disposition: "done_with_findings",
        finding_keys: keys,
        findings_deferred_count: total,
        severity_counts: severity_counts,
        lenses: lenses,
        certified_head: head,
        stall: stall,
        trend: trend
      }

      details =
        ReviewStallGate
        |> Gate.Presentation.details()
        |> Map.merge(%{
          "lenses" => lenses,
          "finding_keys" => keys,
          "findings" => shown,
          "findings_overflow_count" => length(overflow),
          "findings_deferred_count" => total,
          "severity_counts" => severity_counts,
          "stall" => json_safe(stall),
          "trend" => json_safe(trend),
          "certified_head" => head,
          "resume_hint" => @stall_resume_hint
        })

      {:ok,
       %{
         case_id: nil,
         fingerprint: fingerprint,
         lenses: lenses,
         result: result,
         details: details
       }}
    end
  end

  # The surviving findings of every stopped forward lens, as
  # `{stage, lens, finding}` triples — resolved from the provenance store's
  # `findings` artifact per reviewer stage (sorted for determinism). A stage
  # with no stored findings contributes none; a resolve failure fails the
  # whole build (the caller's fail-safe `fix_failed`).
  defp stall_findings(lenses, state) do
    for(
      {name, %Stage{lens: lens} = stage} <- state.catalog,
      is_binary(lens),
      lens in lenses,
      not verify_authority_stage?(stage),
      do: {name, lens}
    )
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {stage, lens}, {:ok, acc} ->
      case stage_findings(stage, lens, state) do
        {:ok, tagged} -> {:cont, {:ok, [tagged | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> flatten_stall_findings()
  end

  # Per-stage lists collected newest-first (prepend); reverse + flatten
  # restores the sorted stage order.
  defp flatten_stall_findings({:ok, collected}), do: {:ok, List.flatten(Enum.reverse(collected))}
  defp flatten_stall_findings({:error, _reason} = error), do: error

  defp stage_findings(stage, lens, state) do
    case get_in(state.artifacts, ["findings", stage]) do
      nil ->
        {:ok, []}

      {:ref, ref} ->
        case ComposerArtifact.resolve_value(ref, auth_opts(state)) do
          {:ok, findings} when is_list(findings) ->
            {:ok, Enum.map(findings, &{stage, lens, &1})}

          {:ok, _other} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:findings_resolve_failed, stage, reason}}
        end

      inline when is_list(inline) ->
        {:ok, Enum.map(inline, &{stage, lens, &1})}

      _other ->
        {:ok, []}
    end
  end

  # Key FIRST (identity comes from the raw finding, matching the marks
  # computed at emission), then redact the whole entry list, then bound each
  # string field — redact-before-truncate, so truncation can never bisect a
  # secret into a survivable fragment.
  defp redacted_finding_entries(tagged) do
    tagged
    |> Enum.map(fn {stage, lens, finding} ->
      %{
        "key" => FindingKey.key(finding),
        "stage" => stage,
        "lens" => lens,
        "title" => finding_field(finding, :title),
        "severity" => finding_field(finding, :severity),
        "confidence" => finding_field(finding, :confidence),
        "location" => finding_field(finding, :location),
        "description" => finding_field(finding, :description)
      }
    end)
    |> Transcript.redact()
    |> Enum.map(&bound_entry/1)
  end

  defp bound_entry(entry) do
    Map.new(entry, fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, @stall_field_cap)}
      pair -> pair
    end)
  end

  # Atom key wins (live Zoi output), else the string key (envelope round-trip)
  # — the FindingKey.field/2 tolerance.
  defp finding_field(finding, key) when is_map(finding) do
    case Map.get(finding, key) do
      nil -> Map.get(finding, Atom.to_string(key))
      value -> value
    end
  end

  defp finding_field(_finding, _key), do: nil

  # The per-key trend maps of every stall-evidence entry, merged — advisory
  # only (`:falling` = confidence dropped likely → unsure across the stall).
  defp merged_trend(evidence) do
    Enum.reduce(evidence, %{}, fn entry, acc -> Map.merge(acc, entry.trend) end)
  end

  defp certified_head(%{verified_integrity: %{head: head}}) when is_binary(head), do: head
  defp certified_head(_state), do: nil

  # One counter per stop reason per lens (stall evidence ⇒ `:stuck` /
  # `:oscillating`; a budget-only lens ⇒ `:exhausted`) + one bounded
  # `:composer` Trace event — hex keys only, tenant-stamped (the
  # `emit_infra_observability` posture).
  defp emit_stall_observability(lenses, state) do
    evidence = stall_evidence(state)
    evidence_lenses = MapSet.new(evidence, & &1.lens)

    Enum.each(evidence, fn entry ->
      if entry.stuck != [], do: Telemetry.emit_composer_stall(:stuck, entry.lens)

      if entry.oscillating != [],
        do: Telemetry.emit_composer_stall(:oscillating, entry.lens)
    end)

    Enum.each(lenses, fn lens ->
      if not MapSet.member?(evidence_lenses, lens),
        do: Telemetry.emit_composer_stall(:exhausted, lens)
    end)

    JidoClaw.Trace.emit(
      :composer,
      %{
        event: :fix_stopped,
        run_id: state.parent_run_id,
        parent_run_id: state.parent_run_id,
        lenses: lenses,
        stalled:
          json_safe(Enum.map(evidence, &Map.take(&1, [:lens, :round, :stuck, :oscillating]))),
        wave_index: state.wave_index,
        tenant_id: state.tenant
      },
      %{count: 1}
    )
  end

  # ---------------------------------------------------------------------------
  # Recovery: wake-after-gate (Phase 4d)
  # ---------------------------------------------------------------------------

  # Re-derive a parked gate from the rebuilt state + durable log, WITHOUT
  # requiring `wave_paused`. The authoritative signal is a `wave_started(N)` for a
  # **gate** dispatch with no `wave_completed(N)` and a materialized child at
  # `composer:<parent>:N` — `N` is the rebuilt `wave_index` (the last
  # `wave_completed` advanced it to the parked wave). `wave_paused(N)`, when
  # present, only supplies the `agent_case_id` shortcut; its ABSENCE never hides
  # the park (so the rare "marker-append exhausted" park is still recoverable). A
  # worker wave that crashed (`wave_started(N)` for a worker) returns nil here →
  # the normal tick re-dispatches it (the dedupe-hit path handles the corpse).
  defp derive_park(state, events) do
    n = state.wave_index

    with true <- wave_event?(events, :wave_started, n),
         false <- wave_event?(events, :wave_completed, n),
         stages when is_list(stages) <- wave_started_stages(events, n),
         true <- gate_dispatch?(stages, state.catalog),
         {:ok, %WorkflowRun{} = child} <- load_wave_child(state, n) do
      build_recovery_park(state, n, child, stages, events)
    else
      _no_park -> nil
    end
  end

  defp build_recovery_park(state, n, child, stages, events) do
    # Re-compose the display from the rebuilt state (the same shape the live tick
    # produces); the dispatch is the AUTHORITATIVE stored `wave_started` stages.
    available = Fold.available(state.artifacts)
    result = Router.compose_route(state.catalog, state.live, available, state.ran)
    display = Router.merge_sticky(state.catalog, state.prev_route, result)

    %{
      wave_index: n,
      case_id: recovered_case_id(events, n),
      child_run_id: child.id,
      dispatch: stages,
      display: display
    }
  end

  # Re-enter a parked gate on rebuild, reusing the SAME wake/fold/disposition code
  # the live path uses (4b/4c): an `:awaiting_approval` child is re-parked
  # (subscribe THEN re-read, to close the decision-landed-during-subscribe
  # window); a decided-while-down child is folded / terminalized.
  defp re_enter_park(park, state) do
    resolve_recovered_gate(%{state | parked: park}, true)
  end

  defp resolve_recovered_gate(state, first?) do
    case WorkflowRun.by_id(state.parked.child_run_id, tenant: state.tenant, actor: state.actor) do
      # First read: subscribe, then re-read — a decision landing between the read
      # and the subscribe would otherwise be missed.
      {:ok, %WorkflowRun{status: :awaiting_approval}} when first? ->
        resolve_recovered_gate(ensure_gates_subscribed(state), false)

      # Genuinely still parked (now subscribed): re-arm the sensitive-park deadline
      # (O-M2 — if already past deadline the `max(…, 0)` delay fires it immediately),
      # re-append `wave_paused`, and wait.
      {:ok, %WorkflowRun{status: :awaiting_approval}} ->
        attempt_wave_paused(arm_park_deadline(state), 0)

      {:ok, %WorkflowRun{status: :completed} = child} ->
        fold_resumed_gate(child, state)

      {:ok, %WorkflowRun{status: :cancelled} = child} ->
        terminalize_gate_disposition(:rejected, child, state)

      {:ok, %WorkflowRun{status: :abandoned} = child} ->
        terminalize_gate_disposition(:abandoned, child, state)

      {:ok, %WorkflowRun{status: :failed} = child} ->
        terminalize_failed_gate_child(child, state)

      # Decided-then-resuming while down (rare — reconcile usually finishes the
      # resume first): observe to terminal, then fold/terminalize.
      {:ok, %WorkflowRun{status: status} = child} when status in [:running, :pending] ->
        observe_then_resolve(child, state)

      _other ->
        # Reload failed — stay parked (subscribed); recovery retries next boot.
        {:noreply, ensure_gates_subscribed(state)}
    end
  end

  defp load_wave_child(state, n) do
    WorkflowRun.by_idempotency_key("composer:#{state.parent_run_id}:#{n}",
      tenant: state.tenant,
      actor: state.actor
    )
  end

  # An event of `kind` for wave index `n` (the kind is pinned by the repeated
  # variable). Recovery reads DB-reloaded events, so every payload is
  # string-keyed (JSONB round-trip) — no atom-key tolerance needed here.
  defp wave_event?(events, kind, n) do
    Enum.any?(events, fn
      %{kind: ^kind, payload: payload} -> event_wave_index(payload) == n
      _event -> false
    end)
  end

  defp wave_started_stages(events, n) do
    Enum.find_value(events, fn
      %{kind: :wave_started, payload: payload} ->
        if event_wave_index(payload) == n, do: payload["stages"] || []

      _event ->
        nil
    end)
  end

  defp recovered_case_id(events, n) do
    Enum.find_value(events, fn
      %{kind: :wave_paused, payload: payload} ->
        if event_wave_index(payload) == n, do: payload["agent_case_id"]

      _event ->
        nil
    end)
  end

  defp event_wave_index(payload) when is_map(payload) do
    case payload["wave_index"] do
      n when is_integer(n) -> n
      _other -> nil
    end
  end

  defp event_wave_index(_payload), do: nil

  # ---------------------------------------------------------------------------
  # Rerun / invalidation primitive + re-plan (Phase 4e)
  # ---------------------------------------------------------------------------

  # Re-plan after a gate reject (the §15.8 opt-in): in one fenced transaction fold
  # `plan-rejected` + invalidate the re-run set, carrying `closed_wave_index` (the
  # rejected gate's wave) so the re-fire gets a FRESH launch key PAST the cancelled
  # gate child (without this advance the re-dispatched planner would dedupe to the
  # cancelled gate and terminate — the High finding). Then mirror the deltas in
  # memory and re-tick: the next compose re-fires the planner → re-gate → re-park →
  # re-approve.
  defp replan_after_reject(park, gate_stage, state) do
    rerun_set = replan_rerun_set(state, gate_stage)

    markers = [
      signals_published: %{signals: ["plan-rejected"]},
      stages_invalidated: %{stages: rerun_set, closed_wave_index: park.wave_index}
    ]

    case Commit.append_markers(state.parent, markers, commit_opts(state)) do
      :ok ->
        next = apply_reject_replan(state, rerun_set, park.wave_index)
        {:noreply, next, {:continue, :tick}}

      {:error, :parent_terminal} ->
        {:stop, :normal, state}

      # WS2: a reclaiming node owns the parent now — stop clean, write nothing.
      {:error, :parent_fenced} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        # The re-plan markers didn't land durably → fall back to the committed
        # default (terminate as rejected) rather than diverge from the log.
        finish({:rejected, {:replan_append_failed, park.child_run_id}}, state)
    end
  end

  # The POST-commit rerun dispatcher (AR-8c verify + Phase 4e stale-approval) —
  # the AR-4 self-heal hooks are computed PRE-commit and welded into the wave
  # (`decide_rerun/2`), so this handles only the two paths that keep their
  # post-commit append:
  #
  #   * `open_verify_loop?` — a `reverse_verify: true` stage (the system-verifier)
  #     just emitted `findings:<lens>`: re-fire BOTH it and its upstream producer
  #     (the executor) so the change is re-applied + re-verified (AR-8c);
  #   * `stale_approval?` — the plan-gate stale-approval retraction (Phase 4e),
  #     provably false on the `system` path (no `plan-approved`).
  #
  # Disjoint from the AR-4 hooks: a reviewer wave is never `reverse_verify`, and
  # `implementer_ran?` is true at any reviewer/fixer tick (so stale-approval is
  # false there). A forward-lens CODE reviewer's open findings now re-fire the
  # FIXER (AR-4, welded above) — only the fixer-less `sketch-review` path keeps the
  # `:not_converged`-on-findings terminal.
  defp maybe_rerun_after_findings(state, emissions) do
    cond do
      open_verify_loop?(state, emissions) -> rerun_verify_loop(state, emissions)
      stale_approval?(state, emissions) -> retract_stale_approval(state)
      true -> {:noreply, state, {:continue, :tick}}
    end
  end

  # ---------------------------------------------------------------------------
  # AR-4 self-heal: completion-signal injection (the silent-converge guarantee)
  # ---------------------------------------------------------------------------

  # Inject each producer's guaranteed completion signal into its emission BEFORE
  # the fold. A producer that RAN (its emission is in this wave) definitionally
  # emitted its completion signal — `plan-ready` for the planner, `code-written`
  # for the implementer/fixer — so we treat that signal as implied, not an optional
  # self-report the LLM might drop and thereby SILENTLY false-converge
  # (`@completion_signals`). One injection point fixes live state, the durable
  # `signals_published` delta (`wave_deltas/3` diffs pre/post `live`), the never-ran
  # summon, AND `decide_rerun/2`'s re-review derivation — all read these same,
  # now-injected `emissions`.
  #
  # Idempotent (`Enum.uniq`): a no-op when the model already emitted the signal, so
  # every existing test stays green. A blocked non-reviewer producer never reaches
  # here: `DefaultMapper.refuse_blocked_producer/2` refuses it (`{:error,
  # {:producer_blocked, _}}`) so `WaveCollect` route-fails the wave BEFORE this
  # injection (and the fold) ever runs — a blocked planner can't get `plan-ready`
  # injected onto a `plan` fabricated from its blocked `summary`, nor a blocked
  # implementer `code-written` onto a fabricated `diff`. (`status` rides the
  # producer's typed output, read at the mapper; `:partial`/`:completed` producers
  # proceed normally.)
  defp enforce_completion_signals(emissions, state) do
    Enum.map(emissions, fn %StageEmission{stage: name, signals: sigs} = emission ->
      with {:ok, stage} <- Map.fetch(state.catalog, name),
           [_ | _] = inject <- completion_signals_for(stage),
           true <- on_live_route?(stage, state.live) do
        %{emission | signals: Enum.uniq(sigs ++ inject)}
      else
        _ -> emission
      end
    end)
  end

  # The completion signals a stage is GUARANTEED to emit by virtue of having run:
  # exactly `@completion_signals ∩ publishes` for a non-reviewer, non-reverse-verify
  # worker-template producer. Role-based, never a hardcoded template name — `lens:
  # nil` is the explicit "non-reviewer" marker, `rv != true` excludes the
  # reverse-verify loop, and `publishes ∩ @completion_signals` selects exactly what
  # the stage declares (planner → `plan-ready`; implementer / fixer → `code-written`;
  # test-author → `[]`, since it publishes `tests-ready`, not in the set; reviewers
  # and gates/seeds → `[]`). Mirrors the `fixer_stage?/1` role-predicate style.
  defp completion_signals_for(%Stage{
         unit: {:worker_template, _},
         reverse_verify: rv,
         lens: nil,
         publishes: pub
       })
       when rv != true,
       do: Enum.filter(@completion_signals, &(&1 in pub))

  defp completion_signals_for(%Stage{}), do: []

  # ---------------------------------------------------------------------------
  # AR-4 self-heal: the pure, pre-commit rerun decision (welded into the wave)
  # ---------------------------------------------------------------------------

  # The two-phase self-heal decision, computed on the FOLDED state BEFORE the wave
  # commit and WELDED into it (the crash-window fix — these markers ride the SAME
  # `commit_wave` transaction as `wave_completed`, so "fixer ran" can never land
  # without its re-review trigger). Two mutually-exclusive hooks (a wave is either
  # a reviewer wave or the fixer wave) + a no-op:
  #
  #   * Hook F — the fixer completed this wave: invalidate the re-review set
  #     ((flagged ∪ domain-touched) ∩ ran) so the touched lenses re-review. The
  #     fixer's emitted domain signals are already folded live (the fold ran
  #     before this), so any never-ran subscriber is SUMMONED by the router next
  #     tick — no marker needed for that.
  #   * Hook R — a forward-lens reviewer flagged open `findings:<lens>` this wave:
  #     snapshot-replace the fixer's out-of-band feedback (so it sees exactly this
  #     round's open findings), and re-fire the fixer iff it already ran (a
  #     re-flag; on the first finding the fixer ∉ `ran` and fires naturally — the
  #     `∩ ran` makes that invalidation a no-op).
  #
  # Returns `{markers, apply_fn}`: the durable `[{kind, payload}]` batch + the
  # in-memory mirror. `apply_fn` routes through `ComposerProjection.apply_markers/2`
  # — the projection's OWN fold — so the in-memory mutation mirrors every welded
  # marker BY CONSTRUCTION (`project == in-memory`). Deliberately welds no
  # `signals_retracted` (that belongs to stale-approval, which keeps its own
  # post-commit path). Disjoint from the AR-8c verify loop (a reviewer wave is
  # never `reverse_verify`) and stale-approval (`implementer_ran?` is true at any
  # reviewer/fixer tick).
  defp decide_rerun(state, emissions) do
    markers =
      cond do
        fixer_completed?(state, emissions) -> hook_f_markers(state, emissions)
        open_fix_finding?(state, emissions) -> hook_r_markers(state, emissions)
        true -> []
      end

    {markers, fn folded -> ComposerProjection.apply_markers(folded, markers) end}
  end

  # Hook F markers: invalidate the re-review set (the re-firing reviewers). Empty
  # when nothing in-`ran` is touched (then convergence falls out next tick).
  # Item 5: a verify stage in the set with a live `clean:<lens>` ALSO gets that
  # green retracted in the same welded batch — the laundered-green guard (no
  # stale green visible between the fixer wave and the re-verify; the
  # `stages_invalidated` fold additionally clears `verified_integrity`).
  defp hook_f_markers(state, emissions) do
    case fix_rerun_set(state, emissions) do
      [] ->
        []

      rerun_set ->
        invalidation = [stages_invalidated: %{stages: rerun_set}]

        case verify_clean_retractions(state, rerun_set) do
          [] -> invalidation
          retractions -> retractions ++ invalidation
        end
    end
  end

  defp verify_clean_retractions(state, rerun_set) do
    signals =
      for {name, signal} <- live_verify_cleans(state), name in rerun_set, do: signal

    case signals do
      [] -> []
      signals -> [signals_retracted: %{signals: Enum.sort(signals)}]
    end
  end

  # Hook R markers, in canonical fold order: `artifacts_invalidated` (clear the
  # prior round's feedback) → `artifacts_produced` (this round's flagged feed) →
  # `stages_invalidated` (re-fire the fixer iff it already ran).
  #
  # Item 6 (camus C1-4/C1-5): when a fix-loop stop reason holds — the flagged
  # lens's re-review budget can't cover a re-fired fix, or the finding is
  # stalled — the ENTIRE hook is suppressed: the fixer re-invalidation is
  # never even recorded (no rerun count burned, no wasted fixer wave) and no
  # feedback is swapped for a fixer that will never fire. The route then runs
  # dry and `finish_terminal(:not_converged, …)` reclassifies through the
  # SAME `fix_stop_lenses/1`, so the two sides cannot disagree. `state` here
  # is the keyed fold (this wave's `finding_keys` markers already applied),
  # so round N vs N-1 is decided at the wave that produced round N.
  defp hook_r_markers(state, emissions) do
    if suppress_fix_dispatch?(state) do
      []
    else
      flagged = open_fix_finding_stages(state, emissions)
      {feedback_markers, _put} = review_feedback(state, flagged)
      feedback_markers ++ fixer_reinvalidation_markers(state)
    end
  end

  defp fixer_reinvalidation_markers(state) do
    case fixer_name(state) do
      name when is_binary(name) ->
        if MapSet.member?(state.ran, name),
          do: [stages_invalidated: %{stages: [name]}],
          else: []

      nil ->
        []
    end
  end

  # The fixer completed this wave: a fixer stage on the live route whose NAME is in
  # the emissions (one emission entry per stage that ran this wave).
  defp fixer_completed?(state, emissions) do
    emitted = emitted_stage_names(emissions)

    Enum.any?(state.catalog, fn {name, stage} ->
      fixer_stage?(stage) and on_live_route?(stage, state.live) and MapSet.member?(emitted, name)
    end)
  end

  # A forward-lens reviewer STAGE emitted its own (still-open) `findings:<lens>`
  # this wave, AND a fixer shares its live route — so a re-review loop is actually
  # possible. The sketch-review path has no fixer on its route, so its findings
  # take the surviving `:not_converged` (report-only) terminal, unchanged.
  defp open_fix_finding?(state, emissions) do
    open_fix_finding_stages(state, emissions) != [] and fixer_on_live_route?(state)
  end

  # The lens-carrying, non-reverse_verify reviewer stages on the live route that
  # emitted their own still-open `findings:<lens>` THIS wave — keyed off the
  # emitting stage NAME (unique), the lens derived only to check the signal.
  defp open_fix_finding_stages(state, emissions) do
    emitted = emitted_stage_names(emissions)

    for {name, %Stage{lens: lens} = stage} <- state.catalog,
        forward_lens_stage?(stage),
        MapSet.member?(emitted, name),
        on_live_route?(stage, state.live),
        MapSet.member?(state.live, "findings:#{lens}"),
        do: name
  end

  # The AR-4 re-review set: (flagged ∪ domain-touched) reviewer STAGES ∩ ran.
  # Flagged = reviewers with a currently-open `findings:<lens>`; domain-touched =
  # reviewers on the fixer's route whose `subscribes` matches a signal the fixer
  # emitted (so a fix that wanders into a lens's domain re-runs it even though it
  # never flagged). A never-ran lens whose domain signal the fixer just emitted is
  # excluded by `∩ ran` here and SUMMONED by the now-live signal instead.
  defp fix_rerun_set(state, emissions) do
    {fixer_name, fixer_stage} = completed_fixer(state, emissions)
    emitted_signals = stage_emitted_signals(emissions, fixer_name)

    (open_flagged_stages(state) ++ domain_touched_stages(state, fixer_stage, emitted_signals))
    |> MapSet.new()
    |> MapSet.intersection(state.ran)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # Lens-carrying, non-reverse_verify reviewer stages on the live route whose
  # `findings:<lens>` is CURRENTLY open (regardless of which wave emitted it).
  defp open_flagged_stages(state) do
    for {name, %Stage{lens: lens} = stage} <- state.catalog,
        forward_lens_stage?(stage),
        on_live_route?(stage, state.live),
        MapSet.member?(state.live, "findings:#{lens}"),
        do: name
  end

  # The never-ran summon's `∩ ran` companion: lens-carrying, non-reverse_verify
  # reviewer stages on the FIXER's route whose `subscribes` matches a fixer-emitted
  # signal (via the shared one-directional matcher).
  defp domain_touched_stages(_state, nil, _emitted_signals), do: []

  defp domain_touched_stages(state, %Stage{routes: fixer_routes}, emitted_signals) do
    for {name, %Stage{subscribes: subs} = stage} <- state.catalog,
        forward_lens_stage?(stage),
        routes_overlap?(stage.routes, fixer_routes),
        Enum.any?(subs, &SignalMatch.matches?(&1, emitted_signals)),
        do: name
  end

  # A fixer stage: a non-reverse_verify worker that subscribes the `findings`
  # family base (it re-fires on ANY open review finding). Identified by ROLE — the
  # `findings` subscription — not a hardcoded template name, so a user catalog with
  # a differently-named fixer template still works.
  defp fixer_stage?(%Stage{unit: {:worker_template, _}, reverse_verify: rv, subscribes: subs}),
    do: rv != true and "findings" in subs

  defp fixer_stage?(%Stage{}), do: false

  defp forward_lens_stage?(%Stage{lens: lens, reverse_verify: rv}),
    do: is_binary(lens) and rv != true

  defp fixer_on_live_route?(state), do: not is_nil(fixer_name(state))

  defp fixer_name(state) do
    Enum.find_value(state.catalog, fn {name, stage} ->
      if fixer_stage?(stage) and on_live_route?(stage, state.live), do: name
    end)
  end

  defp completed_fixer(state, emissions) do
    emitted = emitted_stage_names(emissions)

    Enum.find_value(state.catalog, {nil, nil}, fn {name, stage} ->
      if fixer_stage?(stage) and on_live_route?(stage, state.live) and
           MapSet.member?(emitted, name),
         do: {name, stage}
    end)
  end

  defp emitted_stage_names(emissions),
    do: MapSet.new(emissions, fn %StageEmission{stage: stage} -> stage end)

  defp stage_emitted_signals(emissions, stage_name) do
    Enum.find_value(emissions, [], fn
      %StageEmission{stage: ^stage_name, signals: sigs} -> sigs
      _emission -> nil
    end)
  end

  # A stage participates in the current live route iff its `routes` intersect the
  # live PATH signals (talk/sketch/code/system are folded into `live`). This
  # route/stage scoping keeps a `code`-run fix loop off the `sketch` reviewers,
  # which reuse the `correctness` lens — identity is the stage name + this check.
  defp on_live_route?(%Stage{routes: routes}, live),
    do: Enum.any?(routes, &MapSet.member?(live, &1))

  defp routes_overlap?(a, b), do: Enum.any?(a, &(&1 in b))

  # AR-4: snapshot-replace the fixer's `review-feedback` (← findings) +
  # `review-action` (← action_needed) for the CURRENTLY flagged reviewers.
  defp review_feedback(state, flagged_stages) do
    build_feedback(
      state,
      flagged_stages,
      [{"findings", "review-feedback"}, {"action_needed", "review-action"}],
      true
    )
  end

  # The shared out-of-band feedback builder (AR-8c verify + AR-4 self-heal): for
  # each `producer` stage, copy its source artifact ref into a producerless
  # feedback artifact (producer-keyed) the loop injects on re-fire. `name_map` is
  # the `[{source_artifact, feedback_artifact}]` mapping; `replace?` snapshot-
  # replaces (`artifacts_invalidated` for every existing feedback producer first)
  # — set for AR-4's multi-round, multi-producer feed so a since-cleaned lens never
  # leaves stale feedback; false for AR-8c's single, overwriting producer (whose
  # markers/`artifacts_put` then match its pre-AR-4 shape exactly). Returns
  # `{markers, artifacts_put}` — the markers welded (AR-4) or appended (AR-8c), the
  # tagged `artifacts_put` the AR-8c in-memory mirror still uses.
  defp build_feedback(state, producers, name_map, replace?) do
    feedback_names = Enum.map(name_map, fn {_src, fb} -> fb end)
    invalidated = if replace?, do: existing_feedback_markers(state, feedback_names), else: []
    entries = feedback_entries(state, producers, name_map)
    {invalidated ++ produced_markers(entries), feedback_artifacts_put(entries)}
  end

  # Each `{feedback_name, producer, ref}` the producers' source refs resolve to; a
  # missing source ref is simply skipped (a blind re-fire, still correct).
  defp feedback_entries(state, producers, name_map) do
    for producer <- producers,
        {source, feedback} <- name_map,
        ref = feedback_ref(state, source, producer),
        is_binary(ref),
        do: {feedback, producer, ref}
  end

  defp feedback_ref(state, source, producer) do
    case get_in(state.artifacts, [source, producer]) do
      nil -> nil
      entry -> bare_ref(entry)
    end
  end

  defp produced_markers([]), do: []

  defp produced_markers(entries) do
    [
      artifacts_produced: %{
        artifacts: Enum.map(entries, fn {n, p, r} -> artifact_triple(n, p, r) end)
      }
    ]
  end

  # One `artifacts_invalidated` marker deleting every EXISTING producer of the
  # feedback names — the snapshot-clear that makes AR-4's feed iteration-scoped
  # (`projection.ex` prunes a now-empty name map, keeping `available` correct).
  defp existing_feedback_markers(state, feedback_names) do
    entries =
      for name <- feedback_names,
          {producer, _entry} <- Map.get(state.artifacts, name, %{}),
          do: %{name: name, producer: producer}

    case entries do
      [] -> []
      _ -> [artifacts_invalidated: %{artifacts: entries}]
    end
  end

  defp feedback_artifacts_put(entries) do
    Enum.reduce(entries, %{}, fn {name, producer, ref}, acc ->
      Map.update(acc, name, %{producer => {:ref, ref}}, &Map.put(&1, producer, {:ref, ref}))
    end)
  end

  # A `reverse_verify: true` stage in this wave's emissions that emitted an open
  # `findings:<lens>` signal (the verification failed).
  defp open_verify_loop?(state, emissions) do
    not is_nil(open_verify_stage(state, emissions))
  end

  defp open_verify_stage(state, emissions) do
    Enum.find_value(emissions, fn %StageEmission{stage: name, signals: sigs} ->
      stage = Map.get(state.catalog, name)

      if match?(%Stage{reverse_verify: true}, stage) and
           Enum.any?(sigs, &String.starts_with?(&1, "findings:")),
         do: stage
    end)
  end

  # The reverse-verify re-fire (AR-8c): the rerun set is exactly
  # `replan_rerun_set(state, verifier)` = `{verifier} ∪ {producers of the
  # verifier's single required input} ∩ ran` = `{system-verifier, system-executor}`.
  # Both leave `ran`; on the next tick the executor re-triggers on its still-live
  # `plan-ready` (its lock stays released — `safety-approved` is never retracted,
  # so the human is NOT re-gated on retry), re-produces `system-change`, and the
  # verifier (ordered after by the data edge) re-checks. Bounded by the per-stage
  # `rerun_cap` (`over_budget?` → `budget_terminal` → `:verify_failed`).
  defp rerun_verify_loop(state, emissions) do
    verifier = open_verify_stage(state, emissions)
    rerun_set = replan_rerun_set(state, verifier)
    {extra_markers, artifacts_put} = verify_feedback(state, verifier)

    invalidate_stages(state, rerun_set,
      extra_markers: extra_markers,
      artifacts_put: artifacts_put
    )
  end

  # Informed re-fire (C3): copy the verifier's just-produced `findings` ref into
  # the out-of-band `verify-feedback` input (producer = verifier name) so the
  # executor reads the prior findings in its task on re-fire (`verify-feedback`
  # has NO catalog producer, so it adds no precedence edge — cycle-free). Routed
  # through the SHARED `build_feedback/4` (single-sourced with AR-4's
  # `review_feedback/2`) in single-producer, NON-replacing mode — the SAME single
  # overwriting producer it always had, so its `artifacts_produced` marker (bare
  # ref) and tagged `{:ref, ref}` `artifacts_put` mirror are byte-identical to the
  # pre-AR-4 shape, and `Projection.project == in-memory` still holds. No findings
  # artifact → empty entries → a blind re-fire (no marker), still correct.
  defp verify_feedback(state, %Stage{name: verifier_name}) do
    build_feedback(state, [verifier_name], [{"findings", "verify-feedback"}], false)
  end

  # Shared rerun emitter (C4): emit `stages_invalidated` (+ `opts[:extra_markers]`)
  # under the parent-terminal fence, then mirror in memory (`ran` difference +
  # `bump_rerun_counts` + `opts[:artifacts_put]`). NO `closed_wave_index` (the
  # verify-loop reruns are generic completed-wave reruns — the wave's
  # `wave_completed` already advanced the index). Routes ONLY the new verify-loop
  # path; the two plan-gate emitters (`replan_after_reject`,
  # `retract_stale_approval`) keep their exact-payload shapes. The in-memory mirror
  # matches `Projection.apply_event(:stages_invalidated)` + the `artifacts_produced`
  # fold exactly (the projection-equivalence invariant).
  defp invalidate_stages(state, rerun_set, opts) do
    extra_markers = Keyword.get(opts, :extra_markers, [])
    artifacts_put = Keyword.get(opts, :artifacts_put, %{})
    markers = [stages_invalidated: %{stages: rerun_set}] ++ extra_markers

    case Commit.append_markers(state.parent, markers, commit_opts(state)) do
      :ok ->
        {:noreply, apply_invalidation(state, rerun_set, artifacts_put), {:continue, :tick}}

      {:error, :parent_terminal} ->
        {:stop, :normal, state}

      # WS2: a reclaiming node owns the parent now — stop clean, write nothing.
      {:error, :parent_fenced} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        # The markers didn't land durably → don't diverge from the log; continue
        # with the (unchanged) state and let the next tick re-attempt.
        {:noreply, state, {:continue, :tick}}
    end
  end

  defp apply_invalidation(state, rerun_set, artifacts_put) do
    %{
      state
      | ran: MapSet.difference(state.ran, MapSet.new(rerun_set)),
        rerun_counts: bump_rerun_counts(state.rerun_counts, rerun_set),
        artifacts: merge_artifacts(state.artifacts, artifacts_put)
    }
  end

  # Two-level merge matching `Projection.produce_artifact/2` (per-producer
  # `Map.put` into the name map), so the in-memory store equals the projection.
  defp merge_artifacts(store, put) do
    Enum.reduce(put, store, fn {name, producers}, acc ->
      Map.update(acc, name, producers, &Map.merge(&1, producers))
    end)
  end

  defp stale_approval?(state, emissions) do
    MapSet.member?(state.live, "plan-approved") and
      signal_emitted?(emissions, "scope-shift") and
      not implementer_ran?(state)
  end

  # Stale-approval retraction (§4): a wave folded a premise-break (`scope-shift`)
  # while `plan-approved` is live and the implementer (the stage locked
  # `until: plan-approved`) has NOT run — so the approved plan is stale. Retract
  # `plan-approved` (`signals_retracted`) + invalidate the re-run set (here the
  # gate DID complete, so it is in the set) and re-tick → re-plan → re-gate →
  # re-approve. NO `closed_wave_index` (a generic completed-wave rerun — the gate's
  # `wave_completed` already advanced the index). UNCHANGED by AR-8c (kept on its
  # own exact-payload emitter, not routed through `invalidate_stages`).
  defp retract_stale_approval(state) do
    case plan_gate_stage_struct(state.catalog) do
      %Stage{} = gate_stage ->
        rerun_set = replan_rerun_set(state, gate_stage)

        markers = [
          signals_retracted: %{signals: ["plan-approved"]},
          stages_invalidated: %{stages: rerun_set}
        ]

        commit_stale_retraction(state, rerun_set, markers)

      nil ->
        {:noreply, state, {:continue, :tick}}
    end
  end

  defp commit_stale_retraction(state, rerun_set, markers) do
    case Commit.append_markers(state.parent, markers, commit_opts(state)) do
      :ok ->
        {:noreply, apply_stale_retraction(state, rerun_set), {:continue, :tick}}

      {:error, :parent_terminal} ->
        {:stop, :normal, state}

      # WS2: a reclaiming node owns the parent now — stop clean, write nothing.
      {:error, :parent_fenced} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        # The retraction didn't land — proceed with the (stale) approval rather
        # than terminate; the next premise-break re-attempts.
        {:noreply, state, {:continue, :tick}}
    end
  end

  # The in-`ran` subset of {the gate's input producer(s), the gate}. For a reject
  # the gate parked but never completed (∉ `ran`) → just the input producer(s)
  # (the planner); for a stale approval the gate DID complete (∈ `ran`) → both.
  defp replan_rerun_set(state, %Stage{name: gate_name} = gate_stage) do
    gate_stage
    |> gate_input_producers(state)
    |> MapSet.new()
    |> MapSet.put(gate_name)
    |> MapSet.intersection(state.ran)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp gate_input_producers(%Stage{input: %{required: [name | _]}}, state) do
    case Map.get(state.artifacts, name) do
      producers when is_map(producers) -> Map.keys(producers)
      _absent -> []
    end
  end

  defp gate_input_producers(%Stage{}, _state), do: []

  # Mirror the durable reject-replan deltas in memory (the equivalence invariant):
  # `plan-rejected` live, the re-run set dropped from `ran`, `wave_index` advanced
  # past the rejected gate wave, the rerun counts bumped.
  defp apply_reject_replan(state, rerun_set, closed_wave_index) do
    %{
      state
      | live: MapSet.put(state.live, "plan-rejected"),
        ran: MapSet.difference(state.ran, MapSet.new(rerun_set)),
        wave_index: max(state.wave_index, closed_wave_index + 1),
        rerun_counts: bump_rerun_counts(state.rerun_counts, rerun_set)
    }
  end

  # Mirror the durable stale-retraction deltas in memory: `plan-approved` dropped
  # from `live`, the re-run set from `ran`, the rerun counts bumped. `wave_index`
  # is untouched (no `closed_wave_index` — the gate's `wave_completed` advanced it).
  defp apply_stale_retraction(state, rerun_set) do
    %{
      state
      | live: MapSet.delete(state.live, "plan-approved"),
        ran: MapSet.difference(state.ran, MapSet.new(rerun_set)),
        rerun_counts: bump_rerun_counts(state.rerun_counts, rerun_set)
    }
  end

  defp bump_rerun_counts(counts, stages) do
    Enum.reduce(stages, counts, fn stage, acc -> Map.update(acc, stage, 1, &(&1 + 1)) end)
  end

  defp signal_emitted?(emissions, signal) do
    Enum.any?(emissions, fn %StageEmission{signals: signals} -> signal in signals end)
  end

  # The implementer (the stage held `until: plan-approved`) — "has it run?". When
  # the catalog has no such stage, treat as "ran" (don't retract).
  defp implementer_ran?(state) do
    case plan_gate_locked_stage(state.catalog) do
      nil -> true
      name -> MapSet.member?(state.ran, name)
    end
  end

  defp plan_gate_locked_stage(catalog) do
    Enum.find_value(catalog, fn {name, %Stage{lock: locks}} ->
      if Enum.any?(locks, &(&1.until == "plan-approved")), do: name
    end)
  end

  defp plan_gate_stage_struct(catalog) do
    Enum.find_value(catalog, fn {_name, %Stage{unit: unit} = stage} ->
      if match?({:gate, "plan"}, unit), do: stage
    end)
  end

  defp any_subscriber?(catalog, signal) do
    Enum.any?(catalog, fn {_name, %Stage{subscribes: subs}} -> signal in subs end)
  end

  # ---------------------------------------------------------------------------
  # Dedupe-hit observe (Phase 2c) — restart re-dispatch of a still-running child
  # ---------------------------------------------------------------------------

  # Bounded read-only poll of an in-flight existing child until it terminates or
  # `wave_timeout_ms` elapses (2b's per-wave T_wave bound), then re-branch:
  # `:completed` folds + commits its durable emission. A `:cancelled`/`:abandoned`
  # terminal is gate-aware (Phase 4c): for a **gate** dispatch it is a legitimate
  # operator decision → the disposition terminal (via the SHARED
  # `terminalize_gate_disposition/3`), while for a **worker** dispatch it stays
  # the conservative `finish_failed` — an operator decision is never infra, so
  # retrying would override the operator. Any other non-completed terminal and
  # the observe errors (timeout / reload failure) go through `wave_failed/5`
  # (post-review P1): a lens-only cohort rides Lane B — the composer has no
  # trustworthy verdict for the lens even though the immediate failure came
  # from observation/recovery machinery — while mixed/producer cohorts keep
  # the loud `finish_failed`.
  defp observe_existing_child(run, dispatch, display, state) do
    case await_existing_child(run, state) do
      {:ok, %WorkflowRun{status: :completed} = done} ->
        handle_wave_value(decode_emissions(done.result), done, dispatch, display, state)

      {:ok, %WorkflowRun{status: status} = other} when status in [:cancelled, :abandoned] ->
        observe_terminal(status, other, dispatch, display, state)

      # The reloaded child (not the stale `run`) rides through, so a failed
      # history entry carries the right `child_run_id`.
      {:ok, %WorkflowRun{} = other} ->
        wave_failed(
          {:existing_run_not_completed, other.status},
          other,
          dispatch,
          display,
          state
        )

      {:error, reason} ->
        wave_failed(reason, run, dispatch, display, state)
    end
  end

  # A gate child's observed `:cancelled`/`:abandoned` is an operator decision →
  # the disposition terminal; a worker child's is a genuine failure → fail the
  # wave conservatively.
  defp observe_terminal(status, child, dispatch, display, state) do
    if gate_dispatch?(dispatch, state.catalog) do
      terminalize_gate_disposition(disposition_for(status), child, state)
    else
      finish_failed({:existing_run_not_completed, status}, child, dispatch, display, state)
    end
  end

  defp disposition_for(:cancelled), do: :rejected
  defp disposition_for(:abandoned), do: :abandoned

  # True when `dispatch` is a solo `{:gate, _}` stage.
  defp gate_dispatch?([name], catalog),
    do: match?(%Stage{unit: {:gate, _unit}}, Map.get(catalog, name))

  defp gate_dispatch?(_dispatch, _catalog), do: false

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

  # All five terminals share one shape — append the (kind-specific) event +
  # payload under the lease fence, tear the Forge session down on the ORIGINAL
  # `kind`, and notify. `terminal_event/3` data-drives the only two things that
  # vary: the durable event kind and its payload.
  defp parent_terminal_notify(kind, reason, summary, state) do
    {event_kind, payload} = terminal_event(kind, reason, summary)

    result =
      append_parent_terminal(
        state.parent_run_id,
        event_kind,
        payload,
        state.tenant,
        state.actor,
        state.claim_token
      )

    maybe_teardown_forge_session(result, kind, state)
    notify_payload(result, summary)
  end

  # `{event_kind, payload}` per terminal kind. The disposition-carrying cases are
  # SPECIFIC clauses; the generic failure kind is an EXPLICIT default (last) — kept
  # distinct so the specific/fallback line never blurs (the default lifts only
  # `:error`, no disposition).
  #
  #   * `:converged` → `route_converged` + the summary subset.
  #   * `:rejected`/`:abandoned` (Phase 2d) → the cancelled-family event carrying a
  #     STRING disposition in `result` (NOT `error`, H10 — JSONB-safe; the projection
  #     lifts `result.disposition` via `terminal_lifting_result(:cancelled, …)`).
  #   * `:verify_failed` (AR-8c) / `:fix_failed` (AR-4) → a `:failed`-WITH-disposition
  #     append: `:error` carries the scrubbable reason, `result.disposition` the
  #     non-sensitive operator-query marker.
  defp terminal_event(:converged, _reason, summary),
    do: {:route_converged, %{result: terminal_summary_subset(summary)}}

  # Camus C1-4: the approved review-stall release — a COMPLETED-family
  # terminal whose `result` is the park's disposition payload (keys + counts +
  # severity histogram + stall evidence, NEVER finding bodies — those live
  # only on the gate case + the ledger; the pinned redaction posture). Kept
  # OUT of `@scrubbable_error_kinds` like `:route_converged` (no `:error` key
  # at all).
  defp terminal_event(:done_with_findings, result, _summary),
    do: {:route_done_with_findings, %{result: json_safe(result)}}

  defp terminal_event(kind, _reason, _summary) when kind in [:rejected, :abandoned],
    do: {route_cancelled_kind(kind), %{result: %{disposition: Atom.to_string(kind)}}}

  defp terminal_event(:verify_failed, reason, _summary),
    do:
      {:route_verify_failed,
       %{
         error: format_terminal_error(:verify_failed, reason),
         result: %{disposition: "verify_failed"}
       }}

  defp terminal_event(:fix_failed, reason, _summary),
    do:
      {:route_fix_failed,
       %{error: format_terminal_error(:fix_failed, reason), result: %{disposition: "fix_failed"}}}

  # Camus C1-3: the judge-never-produced-a-trustworthy-verdict terminal — a
  # `:failed`-WITH-disposition append like its verify/fix siblings.
  defp terminal_event(:review_infra_failed, reason, _summary),
    do:
      {:route_review_infra_failed,
       %{
         error: format_terminal_error(:review_infra_failed, reason),
         result: %{disposition: "review_infra_failed"}
       }}

  # Item 5 (VERIFY_OATH): the tampered terminal — never retried, never fed to
  # the fixer. `result` carries the disposition plus the opaque verify-report
  # ref, so the evidence is reachable from the parent even when a marked run's
  # error string is scrubbed.
  defp terminal_event(:verify_tampered, {stage, detail, report_ref}, _summary),
    do:
      {:route_verify_tampered,
       %{
         error: format_terminal_error(:verify_tampered, {stage, detail, report_ref}),
         result: verify_tampered_result(report_ref)
       }}

  # Explicit default (the former catch-all): a generic failure kind — lift `:error`
  # only, no disposition.
  defp terminal_event(kind, reason, _summary),
    do: {route_terminal_kind(kind), %{error: format_terminal_error(kind, reason)}}

  defp verify_tampered_result(report_ref) when is_binary(report_ref),
    do: %{disposition: "verify_tampered", report_ref: report_ref}

  defp verify_tampered_result(_absent), do: %{disposition: "verify_tampered"}

  # AR-8b-2 F2 (5.6 / D3 — the review's headline gap): tear the exec Forge session
  # down on EVERY terminal, not just `:converged`. `:converged → complete_session`
  # (lands `:completed`); every other terminal → `stop_session` (lands
  # `:cancelled` — the throwaway ended without converging). The bridge taint
  # teardown covers only manufactured timeout/output-limit failures, so a normal
  # "ran but the reviewer requested changes" sketch (`:not_converged`) would
  # otherwise leave the microVM ALIVE.
  #
  # Fires ONLY on a clean terminal append (`:ok`): a FAILED append leaves the
  # parent `:running`/recoverable, so tearing down the microVM there would strand
  # a retry. Guards a non-empty binary key BEFORE touching Forge: every non-exec
  # route has none → no-op, NEVER `forge().stop_session(nil)`. Best-effort +
  # idempotent (a later call no-ops on an already-gone session); the teardown
  # result must NOT flow into `notify_payload/2` — a cleanup `{:error, _}`
  # becoming `{:terminalize_failed, _}` would misreport the run's outcome and
  # leave the parent `:running`.
  defp maybe_teardown_forge_session(:ok, terminal, state) do
    case forge_key(state) do
      key when is_binary(key) and key != "" -> do_forge_teardown(terminal, key)
      _ -> :ok
    end
  end

  defp maybe_teardown_forge_session(_not_ok, _terminal, _state), do: :ok

  # `:done_with_findings` joins `:converged`'s complete_session — the run DID
  # complete (green, certified verify; findings waived as deferred debt), so
  # its Forge session lands `:completed`, not the throwaway `:cancelled`.
  defp do_forge_teardown(kind, key) when kind in [:converged, :done_with_findings],
    do: best_effort(fn -> forge().complete_session(key) end)

  defp do_forge_teardown(_other, key), do: best_effort(fn -> forge().stop_session(key) end)

  # Read the `forge_session_key` from the composer's persisted context (the
  # `@persisted_context_keys` subset, so it survives restart); a non-exec run has
  # none ⇒ the helper no-ops before calling Forge.
  defp forge_key(%{context: context}) when is_map(context), do: context[:forge_session_key]
  defp forge_key(_state), do: nil

  defp best_effort(fun) do
    fun.()
    :ok
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  # The Forge facade seam (5.0), the SAME app-env key the bridge + front door use,
  # so `JidoClaw.Test.ForgeStub` drives all composer teardown in tests.
  defp forge, do: Application.get_env(:jido_claw, :forge_facade, JidoClaw.Forge)

  # The composer terminal symbol → its durable `route_*` event kind (`:converged`
  # is handled above → `:route_converged`); these four all project onto `:failed`.
  defp route_terminal_kind(:not_converged), do: :route_not_converged
  defp route_terminal_kind(:deadlock), do: :route_deadlocked
  defp route_terminal_kind(:budget_exhausted), do: :route_budget_exhausted
  defp route_terminal_kind(:failed), do: :route_failed

  # The cancelled-family symbol → its durable `route_*` event kind; both project
  # onto `:cancelled` (with the disposition lifted), via `@route_cancelled_kinds`.
  defp route_cancelled_kind(:rejected), do: :route_rejected
  defp route_cancelled_kind(:abandoned), do: :route_abandoned

  defp notify_payload(:ok, summary), do: {:done, summary}
  defp notify_payload({:error, reason}, _summary), do: {:terminalize_failed, reason}

  defp classify_terminal({:budget_exhausted, reason}), do: {:budget_exhausted, reason}
  defp classify_terminal({:failed, reason}), do: {:failed, reason}
  # Camus C1-4: done-with-findings carries the park's result payload as its
  # reason (disposition + keys + counts — `terminal_event/3` lifts it whole).
  defp classify_terminal({:done_with_findings, result}), do: {:done_with_findings, result}
  # AR-8c: verify-failed carries the exhausted lenses as its reason.
  defp classify_terminal({:verify_failed, reason}), do: {:verify_failed, reason}
  # Item 5: tampered carries `{stage, bounded_detail, report_ref}`.
  defp classify_terminal({:verify_tampered, reason}), do: {:verify_tampered, reason}
  # AR-4: fix-failed carries the exhausted forward lenses as its reason.
  defp classify_terminal({:fix_failed, reason}), do: {:fix_failed, reason}
  # Camus C1-3: review-infra-failed carries the infra-exhausted stages as its reason.
  defp classify_terminal({:review_infra_failed, reason}), do: {:review_infra_failed, reason}
  # Phase 2d gate-decided-then-crash terminals (carry a disposition reason).
  defp classify_terminal({:rejected, reason}), do: {:rejected, reason}
  defp classify_terminal({:abandoned, reason}), do: {:abandoned, reason}
  defp classify_terminal(kind) when is_atom(kind), do: {kind, nil}

  defp summary(kind, reason, state) do
    base = %{
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

    # Item 10 (OB1-3): breach-visible rollup (the OpenHelm rider) — added
    # only when a breach was ever counted, so clean-run summaries stay
    # byte-identical.
    case Map.get(state, :evidence_breaches, %{}) do
      breaches when map_size(breaches) > 0 -> Map.put(base, :evidence_breaches, breaches)
      _none -> base
    end
  end

  # The summary's `artifacts` is display/notify-only (never re-resolved), so it
  # keeps the historical bare-ref shape: P2 tags the in-memory fold store as
  # `{:ref, ref}`, so unwrap each tagged ref back to the bare string here (a
  # folded/recovered seed is also a tagged ref and unwraps to its ref string; an
  # untagged minimal-launch seed passes through). The durable parent `result`
  # (`terminal_summary_subset/1`) omits `artifacts` entirely, so it is unaffected.
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
  defp append_parent_terminal(parent_run_id, kind, payload, tenant, _actor, claim_token) do
    lifecycle_actor = Actor.system(tenant)

    case WorkflowRun.by_id(parent_run_id, tenant: tenant, actor: lifecycle_actor) do
      {:ok, %WorkflowRun{} = parent} ->
        append_loaded_parent_terminal(
          parent,
          kind,
          payload,
          tenant,
          lifecycle_actor,
          claim_token
        )

      other ->
        {:error, {:reload_failed, other}}
    end
  end

  defp append_loaded_parent_terminal(parent, kind, payload, tenant, actor, claim_token) do
    if Projection.terminal_status?(parent.status) do
      :ok
    else
      scrubbed = scrub_terminal_payload(kind, payload, parent)

      # WS2: the `route_*` terminals (and the abnormal-path `run_failed`) are
      # status-authority, so threading the held token engages `Allocate.claim_fenced?`
      # (fence B) — a stale owner's terminal rolls back rather than clobbering the
      # reclaimed parent. nil token ⇒ no fence context ⇒ byte-identical.
      # Sidecar teardown is best-effort; the durable token-fenced append below
      # is the terminal authority. A strict stop error means the sidecar is
      # already dead/dying, so skipping this append would only strand the run.
      :ok = WorkflowLease.stop_sidecar_best_effort(parent.id, claim_token)

      case WorkflowLog.append(parent, kind, scrubbed,
             tenant: tenant,
             actor: actor,
             claim_fence_token: claim_token
           ) do
        {:ok, _event} ->
          # Post-commit (`WorkflowEvent` is `transaction?(true)`), covering
          # BOTH callers — loop terminals via `parent_terminal_notify/4` and
          # the abnormal-path `run_failed` via `terminalize_parent/5`. The
          # already-terminal `:ok` short-circuit above deliberately does NOT
          # broadcast (the finish-vs-timeout double-fire guard). Shielded: a
          # raising PubSub must not fail the persisted terminal.
          notify_best_effort("parent-terminal", parent.id, fn ->
            broadcast_parent_terminal(parent, kind, tenant, actor)
          end)

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # The best-effort notification shield (durable-then-notify): a post-commit
  # lifecycle broadcast must never undo or veto durable truth.
  # `Phoenix.PubSub.broadcast/3` RAISES while its registry is briefly down
  # (`{:ok, _} = Registry.meta(...)` inside the dep), so discarding the
  # returned tuple is not enough — catch raises/exits/throws at this
  # boundary too, log every non-`:ok` outcome, and always return `:ok`.
  # Public for direct unit coverage (the `read_error_reason/1` precedent).
  @spec notify_best_effort(String.t(), term(), (-> :ok | {:error, term()})) :: :ok
  def notify_best_effort(label, run_id, fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> log_notify_failure(label, run_id, :returned, reason)
    end
  catch
    kind, payload -> log_notify_failure(label, run_id, kind, payload)
  end

  defp log_notify_failure(label, run_id, source, payload) do
    Logger.warning(
      "[RouteComposer] best-effort #{label} broadcast failed for #{run_id} " <>
        "(#{source}): #{inspect(payload)} — durable state unaffected"
    )

    :ok
  end

  # Announce a committed parent terminal on the run topics (durable-then-notify:
  # the append above already returned `{:ok, _}`, and the caller runs this
  # under `notify_best_effort/3`, so no raise here can touch it). The
  # projection maps the appended kind to the status it committed
  # (single-sourced; `:unknown` logs loudly and skips). The wire kind is the
  # status FAMILY event (`:run_completed`/`:run_failed`/`:run_cancelled`) —
  # zero new shapes on `orchestration:run:*`; subscribers refetch and read
  # the disposition from the run row.
  defp broadcast_parent_terminal(parent, kind, tenant, actor) do
    case Projection.route_terminal_status(kind) do
      {:ok, status} ->
        reloaded = reload_for_broadcast(parent, tenant, actor)
        RunPubSub.broadcast_run_terminal(reloaded, wire_kind(status), status)

      :unknown ->
        Logger.error(
          "[RouteComposer] no lifecycle broadcast family for terminal kind " <>
            "#{inspect(kind)} (parent #{parent.id}) — terminal persisted, event skipped"
        )

        :ok
    end
  end

  # Committed terminal status → the five-kind wire family. `:route_abandoned`
  # rides `:run_cancelled`, not `:run_abandoned` — it PROJECTS to `:cancelled`,
  # and the broadcast kind must agree with the durable status the payload
  # carries. Exhaustive over `route_terminal_status/1`'s success statuses.
  defp wire_kind(:completed), do: :run_completed
  defp wire_kind(:failed), do: :run_failed
  defp wire_kind(:cancelled), do: :run_cancelled

  # Reload once so the event carries the fresh `completed_at`; a freak reload
  # failure degrades to the pre-append snapshot — the explicit `status`
  # argument keeps the event truthful either way (`broadcast_run_terminal/3`'s
  # own rule).
  defp reload_for_broadcast(parent, tenant, actor) do
    case WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _degraded -> parent
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
  # WS2: callers thread the held token (`parent.claim_token`) — these parents are
  # NOT all unclaimed launch-failures. `await_terminal` terminalizes a parent that
  # actively ran (crash/timeout), and `start_composer`/`maybe_terminalize_orphan`/
  # `reload_running_parent` all act on a parent `create_parent_run` already claimed.
  # A `nil` `claim_fence_token` would bypass the Ash fence and let a stale node
  # clobber a reclaimed parent's terminal. Harmless where held == row (immediate
  # launch failures); correctness-relevant on the run_sync crash/timeout paths.
  defp terminalize_parent(%WorkflowRun{} = parent, reason, tenant, actor, claim_token) do
    case append_parent_terminal(
           parent.id,
           :run_failed,
           %{error: format_terminalize_reason(reason)},
           tenant,
           actor,
           claim_token
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
    base = %{
      "terminal" => Atom.to_string(summary.terminal),
      "wave_index" => summary.wave_index,
      "final_route" => summary.final_route
    }

    # Item 10 (OB1-3): the durable breach count rollup — present only when a
    # breach was counted (clean-run results stay byte-identical).
    case Map.get(summary, :evidence_breaches) do
      breaches when is_map(breaches) -> Map.put(base, "evidence_breaches", breaches)
      _none -> base
    end
  end

  # The `run_failed` error string is formatted from the {terminal, reason} PAIR,
  # not `reason` alone (P3): `:not_converged`/`:deadlock` carry a nil reason, so
  # `Reason.format(reason)` would store the literal `"nil"`.
  defp format_terminal_error(:budget_exhausted, {:max_waves, max}),
    do: "budget_exhausted: max_waves=#{max}"

  defp format_terminal_error(:budget_exhausted, {:deadline, deadline}),
    do: "budget_exhausted: deadline=#{deadline}"

  defp format_terminal_error(:budget_exhausted, {:rerun_cap, cap}),
    do: "budget_exhausted: rerun_cap=#{cap}"

  defp format_terminal_error(:failed, reason), do: "failed: #{Reason.format(reason)}"

  # AR-8c: the reason is the list of reverse-verify lenses still open at the trip.
  defp format_terminal_error(:verify_failed, lenses) when is_list(lenses),
    do: "verify_failed: lenses=#{Enum.join(lenses, ",")}"

  # AR-4: the reason is the list of forward (self-heal) lenses still open at the trip.
  defp format_terminal_error(:fix_failed, lenses) when is_list(lenses),
    do: "fix_failed: lenses=#{Enum.join(lenses, ",")}"

  # Camus C1-3: the reason is the list of stages whose infra count tripped the cap.
  defp format_terminal_error(:review_infra_failed, stages) when is_list(stages),
    do: "review_infra_failed: stages=#{Enum.join(stages, ",")}"

  # Item 5: the stage + the bounded integrity detail (kinds + check names —
  # log tails live only inside the encrypted report).
  defp format_terminal_error(:verify_tampered, {stage, detail, _report_ref}),
    do: "verify_tampered: stage=#{stage} #{detail}"

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
    state.wave_index >= state.max_waves or past_deadline?(state) or rerun_capped?(state) or
      infra_capped?(state)
  end

  # A stage invalidated more than `rerun_cap` times is a non-progressing re-plan
  # loop (an oscillation guard) → the `route_budget_exhausted` terminal (Phase 4e).
  defp rerun_capped?(state) do
    Enum.any?(state.rerun_counts, fn {_stage, count} -> count > state.rerun_cap end)
  end

  # A stage infra'd more than `infra_cap` times never produced a trustworthy
  # verdict → the `review_infra_failed` terminal (camus C1-3). Mirrors
  # `rerun_capped?/1` over the separate `infra_counts` budget.
  defp infra_capped?(state) do
    Enum.any?(state.infra_counts, fn {_stage, count} -> count > state.infra_cap end)
  end

  # Wall-clock against the durable `deadline_at_ms` (C1) — the live loop and 2d
  # recovery read the identical stored unix-ms value across a reboot. (Phase 2a's
  # monotonic deadline is gone; a monotonic clock is meaningless after restart.)
  defp past_deadline?(%{deadline_at_ms: nil}), do: false

  defp past_deadline?(%{deadline_at_ms: deadline_at_ms}),
    do: System.os_time(:millisecond) >= deadline_at_ms

  defp budget_reason(state) do
    cond do
      rerun_capped?(state) -> {:rerun_cap, state.rerun_cap}
      past_deadline?(state) -> {:deadline, state.deadline_at_ms}
      true -> {:max_waves, state.max_waves}
    end
  end

  # AR-8c: a rerun-cap trip on a reverse-verify stage whose findings are STILL
  # live is a *verification* failure, not a generic budget stop. The check is
  # `rerun_counts` + `live` based, NOT `ran` based — critical, because the cap
  # trips VIA the same invalidation that just removed the verifier from `ran`, so
  # any `ran`-membership check is false at the trip tick. `budget_reason/1` stays
  # pure (it classifies the *cause*); this is the orthogonal "is a reverse-verify
  # lens open?" axis.
  # A rerun-cap trip with findings STILL live is a *verification* (AR-8c) or
  # *self-heal* (AR-4) failure, not a generic budget stop. The two are disjoint —
  # `reverse_verify` partitions verify stages from forward reviewers — so
  # `budget_terminal/1` distinguishes them cleanly; anything else is a true budget
  # stop. All `rerun_counts` + `live` based (NOT `ran`): the cap trips VIA the same
  # invalidation that just removed the stage from `ran`.
  defp budget_terminal(state) do
    cond do
      # Camus C1-3, FIRST: a judge that never produced a trustworthy verdict
      # outranks findings-derived exhaustion — the run must terminalize as a
      # review-infrastructure failure, never `fix_failed`/`verify_failed`.
      infra_capped?(state) ->
        {:review_infra_failed, infra_exhausted_stages(state)}

      rerun_capped?(state) and verify_exhausted?(state) ->
        {:verify_failed, exhausted_verify_lenses(state)}

      rerun_capped?(state) and fix_exhausted?(state) ->
        {:fix_failed, exhausted_fix_lenses(state)}

      true ->
        {:budget_exhausted, budget_reason(state)}
    end
  end

  # The stages whose infra count tripped the cap — sorted for a deterministic
  # terminal error string.
  defp infra_exhausted_stages(state) do
    for({stage, count} <- state.infra_counts, count > state.infra_cap, do: stage)
    |> Enum.sort()
  end

  defp verify_exhausted?(state), do: exhausted_verify_lenses(state) != []

  defp fix_exhausted?(state), do: exhausted_fix_lenses(state) != []

  # The lenses of verification-authority stages — `reverse_verify: true`
  # (AR-8c) OR a `{:verify, _}` unit (item 5's deterministic verify) — that hit
  # their rerun cap with `findings:<lens>` STILL live: the loop gave up while
  # verification was failing. Keyed on `rerun_counts` + `live` (NOT `ran`): the
  # cap-tripping invalidation just removed the stage from `ran`. If it had
  # passed, `clean:<lens>` would have replaced `findings:<lens>` and the loop
  # would have converged, so it would not be capped with findings live.
  defp exhausted_verify_lenses(state) do
    for {name, %Stage{lens: lens} = stage} <- state.catalog,
        verify_authority_stage?(stage),
        is_binary(lens),
        Map.get(state.rerun_counts, name, 0) > state.rerun_cap,
        MapSet.member?(state.live, "findings:#{lens}"),
        do: lens
  end

  defp verify_authority_stage?(%Stage{reverse_verify: true}), do: true
  defp verify_authority_stage?(%Stage{unit: {:verify, _name}}), do: true
  defp verify_authority_stage?(%Stage{}), do: false

  # AR-4: the FORWARD twin of `exhausted_verify_lenses/1` — the lenses of
  # self-heal reviewer stages that hit their rerun cap with `findings:<lens>`
  # STILL live (the reviewers kept rejecting the fix). Excludes BOTH
  # verification-authority families (reverse_verify AND the `{:verify, _}`
  # unit — a red engine verify exhausting its budget is `verify_failed`, never
  # `fix_failed`). Keyed off the unique STAGE (`rerun_counts[name] > cap`) so
  # it is participation-scoped: an off-route stage (e.g. `sketch-review` on a
  # `code` run) never re-ran, so its `rerun_counts` is 0 and it is never
  # reported. Disjoint from the verify set.
  defp exhausted_fix_lenses(state) do
    catalog_exhausted =
      for {name, %Stage{lens: lens} = stage} <- state.catalog,
          not verify_authority_stage?(stage),
          is_binary(lens),
          Map.get(state.rerun_counts, name, 0) > state.rerun_cap,
          MapSet.member?(state.live, "findings:#{lens}"),
          do: lens

    catalog_exhausted ++ evidence_exhausted_fix(state)
  end

  # Item 10 (OB1-3): the evidence twin — a live `findings:evidence` with the
  # fixer's own rerun count PAST the cap rides the `{:fix_failed, lenses}`
  # terminal by name (see `evidence_rereview_exhausted/1` for the budget
  # rationale).
  defp evidence_exhausted_fix(state) do
    if MapSet.member?(state.live, "findings:evidence") and
         fixer_rerun_count(state) > state.rerun_cap,
       do: ["evidence"],
       else: []
  end
end
