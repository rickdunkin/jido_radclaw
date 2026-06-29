defmodule JidoClaw.Orchestration.WorkflowRecovery do
  @moduledoc """
  Boot-time reconciler for runs stranded by a crash.

  A run drives synchronously in-process: if the BEAM dies between `run_started`
  and a terminal event, the run's projected status is stuck non-terminal
  forever with nothing to advance it. On boot this Task scans every
  non-terminal run and reconciles each. **The no-gate stranding fix is the
  original bug fix.**

  ## Gate-aware branches

  A `resume_checkpoint` is written **only** after a run reaches
  `:awaiting_approval`, so the legal `(status, checkpoint)` pairs are
  constrained. Each run is classified and handled:

    * `:awaiting_approval` **+ checkpoint** → **parked**: correctly waiting on a
      human *iff* the pending `AgentCase` still exists — then a no-op (the case
      is open for an operator to decide). If the case is missing
      (deleted/corrupt), the park can never be decided (no inbox row → no
      decision → no terminal, forever), so it is cancelled (`run_cancelled`); a
      transient lookup error is left for the next boot.
    * `:awaiting_approval` **+ no checkpoint** → **dangling gate** (crash between
      the `gate_open` commit and the checkpoint persist): fail the run with the
      full recovery audit (`run_recovered` + `run_failed`) and cancel the
      pending `AgentCase` (+ its `:cancelled` timeline event), in one
      transaction. A crash-reaped gate is a *failure* — `run_cancelled` is
      reserved for deliberate operator decisions.
    * `:running` **+ checkpoint** → re-keyed on the **recorded
      `approval_resolved` event** (§4.8): only when one exists in the run's
      log is this **decision already recorded** (approve committed
      `approval_resolved` → `:running`, then crashed before/within resume) —
      `GateResume.resume(recovered: true)` re-runs the durable downstream
      steps. `init/1` appends `run_resumed`; the gate's `after_approved` hook
      is **skipped** (Decision 8); downstream steps must be idempotent
      (Decision 7 caveat). With **no** `approval_resolved` in the log the
      pair is forbidden — fail-with-audit, never blind-resume past a gate.
      A transient log-read error is left for the next boot.
    * `:running` **+ no checkpoint** → genuinely stranded → `run_recovered` +
      `run_failed`.
    * `:pending` **+ no checkpoint** → never started → `run_recovered` +
      `run_failed`.
    * `:pending` **+ checkpoint** → an impossible/corrupt pair (a checkpoint is
      only ever written after `:awaiting_approval`) → fail-with-audit and a
      `Logger.warning`; **never** resumed.
    * `workflow_type: "composer"` **+ `:running`** → **rebuilt + resumed**
      (Phase 2d): an AR-2 composer parent sits `:running` for the whole route
      with no checkpoint. Its serialized launch catalog is decoded **and
      validated** from `config` (absent, atom-unsafe, **or** structurally-
      incoherent — all un-recoverable, leaving the parent `:running`); its
      non-terminal children are reconciled through the reactor branches above;
      and — when every still-non-terminal child is a **parked gate** (Phase 4d:
      `:awaiting_approval` + a pending case; a still-running **worker** child
      still blocks restart) — the supervised `JidoClaw.RouteComposer` is
      restarted, whose own `init`/`do_rebuild` folds the durable log and either
      resumes mid-route OR re-enters the gate park (`derive_park` re-parks the
      gate WITHOUT re-dispatching, then folds/terminalizes on the operator's
      decision). A non-gate non-terminal child, or a transient blip, leaves the
      parent `:running` to retry next boot — never failing a recoverable route.
      Composer parents are
      reconciled **before** the other runs (their children excluded from the rest
      of the scan), so the composer never re-dispatches a wave onto an
      executorless child (H6b). Any *other* composer status falls through to the
      status-based branches above, so a never-started `:pending` composer is
      still failed (H20).

  No branch clears a checkpoint by hand — every terminal clears it centrally in
  the projection (Decision 7).

  ## Single-node ownership

  `core_children/0` boots in *every* surface (MCP, gateway, and future
  cluster nodes), so an ungated reconciler could mark a run `:failed` while
  another live BEAM is still executing it. Recovery therefore runs only when
  this process is the sole owner of workflow execution: `:workflow_recovery`
  is enabled (default true; **false in test**), `:serve_mode` is not `:mcp`,
  and clustering is off. Boot recovery is explicitly the single-node restart
  mechanism (Reactor doc §4.8); multi-node reclaim is the lease/fencing work
  (§4.11) `reclaim/1` now drives below.

  ## Boot recovery vs live reclaim (WS3)

  Two entrypoints, two liveness premises — they must **not** share child-disposition
  logic verbatim:

    * `run/1` → `reconcile_all/0` — the **boot** one-shot. Runs once when the BEAM
      has just restarted, so *nothing from the prior runtime is live*: every
      non-terminal run is dead by construction, decidable from DB state alone, and
      `reconcile_children/3` fails *all* non-terminal children (no surviving
      executor to fence, no token to rotate). Single-node, non-MCP, non-clustered
      (`owns_recovery?/0`) precisely because it is **unguarded** — concurrent owners
      would race.
    * `reclaim/1` — the **live-reclaim** entry, driven continuously by the always-on
      `JidoClaw.Orchestration.ReclaimPooler` *alongside* live launches and executors.
      A lease expiry proves only *that one run's* owner died, not its neighbours',
      and a still-alive zombie (a partition) may need fencing. The unifying rule:
      **the lease is the liveness oracle** — a run (parent *or* child) is reclaimable
      **iff its lease has expired, or it is an aged never-claimed `:pending` row** —
      and the act of claiming it **rotates its token**, which fences any survivor.
      The composer child-step (`reclaim_children/3`) therefore claim-rotates + fails
      only *claimable* (expired/aged) children and LEAVES live-lease ones, where boot
      fails them all.

  Boot and reclaim are **complementary**: the Pooler is expiry-gated and touches only
  provably-dead runs (safe in every mode), the `FOR UPDATE` (`lock_run`) + `:illegal`
  terminal-on-terminal guard makes any single-node overlap idempotent, and the
  Pooler's `initial_delay_ms` lets the boot one-shot win the first sweep.
  """

  use Task

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.GateResume
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer

  @dangling_gate_reason "recovered: dangling gate"
  @parked_orphan_reason "recovered: parked gate, pending case missing"

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  Reconcile stranded runs when this node owns workflow execution; no-op
  otherwise. The boot entrypoint.
  """
  @spec run(keyword()) :: :ok
  def run(_opts) do
    if owns_recovery?() do
      reconcile_all()
    else
      :ok
    end
  end

  @doc """
  Scan every non-terminal run across all tenants and reconcile each. Driven
  directly by tests inside the sandbox (boot recovery is disabled in test).
  """
  @spec reconcile_all() :: :ok
  def reconcile_all do
    case WorkflowRun.list_non_terminal_global() do
      {:ok, runs} ->
        reconcile_partitioned(runs)

      {:error, reason} ->
        Logger.warning("[WorkflowRecovery] non-terminal scan failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Reclaim ONE run the `ReclaimPooler` just claimed (its token already rotated by
  `WorkflowLease.claim_next/1`, fencing any surviving zombie owner).

  A `:running` composer parent takes the reclaim-specific child-step
  (`reclaim_composer/1`: claim-rotate + fail expired children, leave live-lease ones
  and parked gates, restart via the shared tail or release-on-defer). Every other
  run is a plain reactor run reconciled through `reconcile_one/1` — boot-parity
  under Q1 (a stranded `:running` no-checkpoint run is failed, not re-run: the
  idempotency key is launch-dedupe, not step-idempotency, so a partially-executed
  reactor cannot be safely re-run today).
  """
  @spec reclaim(WorkflowRun.t()) :: :ok
  def reclaim(%WorkflowRun{workflow_type: "composer", status: :running} = run) do
    reclaim_composer(run)
    :ok
  end

  def reclaim(run) do
    reconcile_one(run)
    :ok
  end

  @doc """
  Reconcile ONE already-claimed run through the shared status/checkpoint
  classification — the live-reclaim per-run entry, mirroring boot's `reconcile_run/1`
  (the private classifier the boot scan loops). The caller has already rotated the
  run's token (so a surviving zombie is fenced); this only classifies + drives the
  disposition (fail-stranded / `GateResume` / parked no-op / …). Returns the branch's
  outcome via `emit/2` telemetry; the value is incidental (callers are side-effecting).
  """
  @spec reconcile_one(WorkflowRun.t()) :: term()
  def reconcile_one(run), do: reconcile_run(run)

  # Composer parents are reconciled FIRST (Phase 2d): a parent's children must be
  # reconciled (and the composer restarted) before the `others` loop touches them,
  # or a restarted composer would re-dispatch a wave and observe an executorless
  # corpse for ~T_wave (H6b). The composer branch returns the child ids it
  # handled; those are excluded from `others` so a child isn't reconciled twice
  # (which would log a stale-`:running` `:illegal` double-reconcile warning).
  defp reconcile_partitioned(runs) do
    {composers, others} = Enum.split_with(runs, &composer_parent?/1)

    handled =
      Enum.reduce(composers, MapSet.new(), fn run, acc ->
        MapSet.union(acc, reconcile_branch(:composer, run))
      end)

    others
    |> Enum.reject(&MapSet.member?(handled, &1.id))
    |> Enum.each(&reconcile_run/1)
  end

  # The exact condition `classify/1` maps to `:composer` — a `:running` composer
  # parent. A `:pending`/`:awaiting_approval` composer is NOT one (it falls
  # through to the status-based branches, so a never-started composer still
  # fails, H20).
  defp composer_parent?(%WorkflowRun{workflow_type: "composer", status: :running}), do: true
  defp composer_parent?(_run), do: false

  # Classify on (status, checkpoint presence) and dispatch. Nothing is live at
  # boot, so the branch is decidable from DB state alone (no event fold).
  # Presence is the ENCRYPTED column (a real attribute, always selected) — the
  # `resume_checkpoint` calculation is `%Ash.NotLoaded{}` on a plain read,
  # which `not is_nil/1` would misclassify as "present" on every run.
  defp reconcile_run(run), do: reconcile_branch(classify(run), run)

  # AR-2 composer parents (`workflow_type: "composer"`) sit `:running` for the
  # whole route with no checkpoint, so the status heads below would mis-classify
  # one as `:stranded → :failed` at boot. Dispatched on `workflow_type` +
  # `:running` FIRST, this head routes a live composer parent into the real 2d
  # rebuild+resume branch (`reconcile_branch(:composer, run)` →
  # `resume_composer/1`) instead of letting reactor recovery clobber the valid
  # parent state. Scoped to `:running` ONLY: a `:pending` or
  # `:awaiting_approval` composer row falls through to the status heads below, so
  # a never-started `:pending` composer is still correctly failed (the recovery
  # contract holds for the whole `workflow_type`, not bypassed for it).
  defp classify(%WorkflowRun{workflow_type: "composer", status: :running}), do: :composer

  defp classify(%WorkflowRun{status: :awaiting_approval, encrypted_resume_checkpoint: cp})
       when not is_nil(cp),
       do: :parked

  defp classify(%WorkflowRun{status: :awaiting_approval, encrypted_resume_checkpoint: nil}),
    do: :dangling_gate

  defp classify(%WorkflowRun{status: :running, encrypted_resume_checkpoint: cp})
       when not is_nil(cp),
       do: :decision_recorded

  defp classify(%WorkflowRun{status: :pending, encrypted_resume_checkpoint: cp})
       when not is_nil(cp),
       do: :corrupt_pending

  defp classify(%WorkflowRun{}), do: :stranded

  # Parked: correctly waiting on a human iff the pending case still exists. A
  # missing case means the park can never be decided (no inbox row), so it is
  # cancelled to reach a terminal — the projection clears the checkpoint
  # (Decision 7). A transient lookup error is left for the next boot.
  defp reconcile_branch(:parked, run) do
    tenant = run.tenant_id
    actor = Actor.system(tenant)

    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, [_ | _]} ->
        emit(run, :parked)

      {:ok, []} ->
        run
        |> WorkflowLog.append(:run_cancelled, %{reason: @parked_orphan_reason},
          tenant: tenant,
          actor: actor
        )
        |> finish(run, :parked_orphaned)

      {:error, reason} ->
        Logger.warning(
          "[WorkflowRecovery] parked-case lookup failed for run #{run.id}: #{inspect(reason)}"
        )
    end
  end

  # Dangling gate: the full recovery audit — `run_recovered` (provenance) +
  # the terminal `run_failed`, PLUS the orphaned pending case cancelled (with
  # its `:cancelled` timeline event), all in one transaction via the shared
  # WorkflowLog helper (the same choreography the runner's gate-pause failure
  # path uses). `run_failed` legally folds `:awaiting_approval -> :failed` and
  # clears the checkpoint. A crash-reaped gate is a *failure*, not an operator
  # cancel — `run_cancelled` is reserved for deliberate decisions.
  defp reconcile_branch(:dangling_gate, run) do
    run
    |> WorkflowLog.terminate_cancelling_cases(
      [
        {:run_recovered, %{reason: @dangling_gate_reason, prior_status: run.status}},
        {:run_failed, %{error: @dangling_gate_reason}}
      ],
      @dangling_gate_reason,
      tenant: run.tenant_id,
      actor: Actor.system(run.tenant_id)
    )
    |> finish(run, :dangling_gate)
  end

  # `:running` + checkpoint: resume ONLY on the recorded `approval_resolved`
  # event — the explicit decision key, not the (status, checkpoint) pair alone.
  # No recorded decision -> forbidden pair -> fail-with-audit, never
  # blind-resume past the gate. A transient log-read error is left for the
  # next boot (like the parked-case lookup).
  defp reconcile_branch(:decision_recorded, run) do
    tenant = run.tenant_id
    actor = Actor.system(tenant)

    case decision_recorded?(run, tenant, actor) do
      {:ok, true} ->
        resume_recorded_decision(run)

      {:ok, false} ->
        Logger.warning(
          "[WorkflowRecovery] forbidden state: :running run #{run.id} carries a checkpoint " <>
            "but no approval_resolved event — failing, not resuming"
        )

        fail_stranded(run, :running_checkpoint_no_decision)

      {:error, reason} ->
        Logger.warning(
          "[WorkflowRecovery] decision lookup failed for run #{run.id}: #{inspect(reason)}"
        )
    end
  end

  # Impossible/corrupt pair — never resume; fail with an audit trail and a loud
  # warning. The terminal clears the bogus checkpoint (Decision 7).
  defp reconcile_branch(:corrupt_pending, run) do
    Logger.warning(
      "[WorkflowRecovery] impossible state: :pending run #{run.id} carries a checkpoint — failing, not resuming"
    )

    fail_stranded(run, :corrupt_pending)
  end

  # Genuinely stranded (the original bug fix): run_recovered + run_failed.
  defp reconcile_branch(:stranded, run), do: fail_stranded(run, :stranded)

  # Composer parent (Phase 2d — the real rebuild+resume branch): reconcile the
  # parent's non-terminal children through the reactor branches above, then —
  # ONLY when every child is terminal — restart the supervised `RouteComposer`,
  # whose own `init`/`do_rebuild` folds the durable log and resumes mid-route.
  # Returns the set of child ids reconciled here (excluded from the `others`
  # loop by `reconcile_partitioned/1`). The parent stays `:running` throughout —
  # resume is mid-route, not a terminal, and an un-recoverable/parked/transient
  # case leaves it `:running` to retry next boot (never failing a recoverable
  # route).
  defp reconcile_branch(:composer, run) do
    if recoverable_catalog?(run) do
      resume_composer(run)
    else
      # Absent OR un-decodable/incoherent serialized catalog (a public-`create`
      # parent, or a corrupt `config["catalog"]`) → un-recoverable. NEVER
      # `ensure_started`: a composer started on a structurally-degenerate catalog
      # would silently false-converge the corrupt-config run to `:completed` (an
      # empty composed route → nothing to dispatch → vacuous convergence),
      # mutating the parent instead of leaving it `:running`. Decode-AND-validate
      # (via `RouteComposer.decode_config_catalog`), not presence-only: a
      # present-but-bad catalog must not slip through. Leave `:running`.
      Logger.warning(
        "[WorkflowRecovery] composer parent #{run.id} has no recoverable catalog; leaving :running"
      )

      emit(run, :composer)
      MapSet.new()
    end
  end

  # Delegates to the shared `RouteComposer.decode_config_catalog/1`: recoverable
  # iff `{:ok, _}` — the serialized catalog both decodes (atom-safe) AND validates
  # coherent (`CatalogValidator` clean). `:absent` (no `config["catalog"]`) and
  # `:invalid` (un-decodable OR structurally-incoherent) are both un-recoverable.
  # (`run.config["catalog"]` is nil-safe via `Access`; a nil config → `:absent`.)
  defp recoverable_catalog?(run) do
    match?({:ok, _}, RouteComposer.decode_config_catalog(run.config["catalog"]))
  end

  defp resume_composer(run) do
    tenant = run.tenant_id
    actor = Actor.system(tenant)
    handled = reconcile_children(run, tenant, actor)

    if restartable?(run, tenant, actor) do
      start_recovered_composer(run, tenant, actor)
    else
      # A still-running/transient WORKER child remains non-terminal: do NOT start —
      # a restarted composer would re-dispatch that wave, hit the executorless
      # corpse, and `observe_existing_child` would poll until `wave_timeout_ms`
      # then fail the parent. Leave `:running` + retry next boot. (A **parked gate**
      # child does NOT block restart — Phase 4d: the restarted composer's
      # `derive_park` re-parks it WITHOUT re-dispatching.)
      Logger.info(
        "[WorkflowRecovery] composer parent #{run.id} has a non-terminal non-gate child; " <>
          "leaving :running for the next boot"
      )

      emit(run, :composer)
    end

    handled
  end

  # ── WS3 live reclaim (Component 4) ──────────────────────────────────────────
  # The reclaim-specific composer parent path. Mirrors `resume_composer/1`'s
  # restart decision (reusing `restartable?/3` + `start_recovered_composer/3`), but
  # swaps boot's fail-ALL-children `reconcile_children/3` for the lease-aware
  # `reclaim_children/3` (claim-rotate + fail only EXPIRED children, leave live-lease
  # ones), and on a deferred restart performs the token-fenced cooldown release
  # instead of just logging. Drives one parent (no `others` exclusion — the Pooler
  # processes one claimed run per `claim_next`), so it returns `:ok`, not a child-id
  # set. The parent's token was rotated by `claim_next`; `start_recovered_composer/3`
  # freezes it into the restarted composer's start_opts (`build_start_opts/2`), whose
  # `lease_preflight_and_resume` renews it → `{:ok, 1}` → resume.
  defp reclaim_composer(run) do
    tenant = run.tenant_id
    actor = Actor.system(tenant)

    if recoverable_catalog?(run) do
      reclaim_children(run, tenant, actor)

      if restartable?(run, tenant, actor) do
        start_recovered_composer(run, tenant, actor)
      else
        # A non-claimable non-terminal child remains (a live-lease worker, or a
        # fresh-pending child within grace): `restartable?/3` defers. Release the
        # parent lease on a `poll_interval` COOLDOWN (not `now()`) so it is
        # re-claimable on the next poll, never within this drain (which would
        # hot-loop). The durably-`async_nolink`-completing child is folded on the
        # eventual restart — no lost work, no double-exec.
        release_on_defer(run)
        emit(run, :composer)
      end
    else
      # Absent/un-decodable catalog → un-recoverable (mirrors the boot branch): a
      # composer on a degenerate catalog would false-converge. Leave `:running` +
      # release the lease on a cooldown so a later sweep retries.
      Logger.warning(
        "[WorkflowRecovery] reclaimed composer parent #{run.id} has no recoverable catalog; " <>
          "leaving :running"
      )

      release_on_defer(run)
      emit(run, :composer)
    end
  end

  # Drive EVERY non-terminal child through `WorkflowLease.claim_run/1`'s full
  # `:claimable` predicate under a `FOR UPDATE` lock — NOT a pre-filter to
  # expired-lease only. Two load-bearing properties:
  #   * a claimable child (expired lease OR aged never-claimed `:pending`) has its
  #     token ROTATED (fencing a surviving zombie child) and is reconciled to
  #     `:failed` via the shared `reconcile_one/1`;
  #   * an aged `:pending`+nil-token wave child (crashed before `Middleware` stamped
  #     it) is caught by clause 2 and failed HERE, rather than skipped and then
  #     permanently blocking `restartable?/3` (which rejects any non-terminal non-gate
  #     child).
  # A non-claimable child (live lease, fresh-pending within grace, or a leaseless
  # parked `:awaiting_approval` gate — `:claimable` excludes that status) is LEFT for
  # `restartable?/3` to defer on (parked gates don't block; a live worker does).
  defp reclaim_children(run, tenant, actor) do
    case load_child_runs(run, tenant, actor) do
      {:ok, children} ->
        children
        |> Enum.filter(&non_terminal?/1)
        |> Enum.each(&reclaim_child/1)

      :error ->
        :ok
    end
  end

  defp reclaim_child(child) do
    case WorkflowLease.claim_run(child.id) do
      {:ok, rotated} ->
        reconcile_one(rotated)

      :lost ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[WorkflowRecovery] child claim failed for #{child.id}: #{inspect(reason)}; leaving"
        )
    end
  end

  # Token-fenced cooldown release on defer: push the (rotated) parent token's expiry
  # to `now() + poll_interval` so the parent is re-claimable on the NEXT poll, not
  # within this `reclaim_once/0` drain. Delegates to the shared
  # `WorkflowLease.release_for_reclaim/2` (single-sourced with the lease middleware's
  # stamp-error re-arm — same cooldown, same best-effort `{:ok, 0}`/error swallow).
  # A nil token (unleased path) has nothing to release.
  defp release_on_defer(%WorkflowRun{claim_token: token} = run) when is_binary(token) do
    WorkflowLease.release_for_reclaim(run.id, token)
  end

  defp release_on_defer(_run), do: :ok

  # Reconcile every NON-TERMINAL child through the shipped reactor branches
  # (children are `workflow_type: "reactor"`): a `:running` no-checkpoint child →
  # `:stranded` → `:failed`; a gated `:running` + recorded decision →
  # `GateResume`; a parked `:awaiting_approval` + pending case → `:parked` (no-op,
  # the human still owns the gate). Returns the set of child ids touched.
  defp reconcile_children(run, tenant, actor) do
    case load_child_runs(run, tenant, actor) do
      {:ok, children} ->
        children
        |> Enum.filter(&non_terminal?/1)
        |> Enum.reduce(MapSet.new(), fn child, acc ->
          reconcile_run(child)
          MapSet.put(acc, child.id)
        end)

      :error ->
        MapSet.new()
    end
  end

  # Re-read the children AFTER reconciliation and decide whether the composer is
  # safe to restart (Phase 4d): YES iff every still-non-terminal child is a
  # **parked gate** (`:awaiting_approval` + a pending `AgentCase`) — the restarted
  # composer re-parks those without re-dispatching. A still-running/transient
  # WORKER child (the executorless-corpse danger the old all-terminal guard
  # feared) blocks the restart. A reload failure is "not safe" — don't start,
  # retry next boot.
  defp restartable?(run, tenant, actor) do
    case load_child_runs(run, tenant, actor) do
      {:ok, children} ->
        children
        |> Enum.reject(&Projection.terminal_status?(&1.status))
        |> Enum.all?(&parked_gate_child?(&1, tenant, actor))

      :error ->
        false
    end
  end

  # A parked gate: `:awaiting_approval` with an open pending `AgentCase` (the
  # `:parked` no-op left it that way). Anything else non-terminal blocks restart.
  defp parked_gate_child?(%WorkflowRun{status: :awaiting_approval} = child, tenant, actor) do
    match?({:ok, [_ | _]}, AgentCase.pending_for_run(child.id, tenant: tenant, actor: actor))
  end

  defp parked_gate_child?(_child, _tenant, _actor), do: false

  defp start_recovered_composer(run, tenant, actor) do
    # No `catalog:` opt — `build_start_opts/2` reconstructs it config-
    # authoritatively (Step 3). A transient supervisor blip leaves the parent
    # `:running` for the next boot (H19 — never fail a recoverable route).
    case RouteComposer.ensure_started([tenant: tenant, actor: actor], run) do
      {:ok, _pid} ->
        emit(run, :composer)

      {:error, reason} ->
        Logger.warning(
          "[WorkflowRecovery] failed to start recovered composer #{run.id}: " <>
            "#{inspect(reason)}; leaving :running for the next boot"
        )
    end
  end

  defp load_child_runs(run, tenant, actor) do
    case Ash.load(run, :child_runs, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{child_runs: children}} ->
        {:ok, children}

      {:error, reason} ->
        Logger.warning(
          "[WorkflowRecovery] failed to load composer children for #{run.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp non_terminal?(%WorkflowRun{status: status}), do: not Projection.terminal_status?(status)

  # The after_approved hook is NOT run (Decision 8) — recovery never routes
  # through Cases.decide, so the hook is skipped by construction.
  defp resume_recorded_decision(run) do
    case GateResume.resume(run, recovered: true) do
      {:ok, _value, _resumed} ->
        emit(run, :decision_recorded)

      {:error, reason, _run} ->
        Logger.warning("[WorkflowRecovery] resume failed for run #{run.id}: #{inspect(reason)}")
        emit(run, :decision_recorded)
    end
  end

  defp decision_recorded?(run, tenant, actor) do
    case WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, events} -> {:ok, Enum.any?(events, &(&1.kind == :approval_resolved))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_stranded(run, branch) do
    finish(WorkflowLog.append_recovery(run, run.status), run, branch)
  end

  # Ash.transact / append_recovery both return `{:ok, _}` | `{:error, _}`.
  defp finish({:ok, _}, run, branch), do: emit(run, branch)

  defp finish({:error, reason}, run, branch) do
    Logger.warning(
      "[WorkflowRecovery] failed to reconcile run #{run.id} (#{branch}): #{inspect(reason)}"
    )
  end

  defp emit(run, branch) do
    :telemetry.execute(
      [:jido_claw, :orchestration, :recovered],
      %{count: 1},
      %{run_id: run.id, tenant_id: run.tenant_id, prior_status: run.status, branch: branch}
    )
  end

  defp owns_recovery? do
    recovery_enabled?() and
      Application.get_env(:jido_claw, :serve_mode) != :mcp and
      Application.get_env(:jido_claw, :cluster_enabled, false) != true
  end

  defp recovery_enabled? do
    :jido_claw
    |> Application.get_env(:workflow_recovery, [])
    |> Keyword.get(:enabled?, true)
  end
end
