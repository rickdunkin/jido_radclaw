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
      the `gate_open` commit and the checkpoint persist): cancel the run
      (`run_cancelled`) and the pending `AgentCase`, in one transaction.
    * `:running` **+ checkpoint** → **decision already recorded** (approve
      committed `approval_resolved` → `:running`, then crashed before/within
      resume): `GateResume.resume(recovered: true)` re-runs the durable
      downstream steps. `init/1` appends `run_resumed`; the gate's
      `after_approved` hook is **skipped** (Decision 8); downstream steps must
      be idempotent (Decision 7 caveat).
    * `:running` **+ no checkpoint** → genuinely stranded → `run_recovered` +
      `run_failed`.
    * `:pending` **+ no checkpoint** → never started → `run_recovered` +
      `run_failed`.
    * `:pending` **+ checkpoint** → an impossible/corrupt pair (a checkpoint is
      only ever written after `:awaiting_approval`) → fail-with-audit and a
      `Logger.warning`; **never** resumed.

  No branch clears a checkpoint by hand — every terminal clears it centrally in
  the projection (Decision 7).

  ## Single-node ownership

  `core_children/0` boots in *every* surface (MCP, gateway, and future
  cluster nodes), so an ungated reconciler could mark a run `:failed` while
  another live BEAM is still executing it. Recovery therefore runs only when
  this process is the sole owner of workflow execution: `:workflow_recovery`
  is enabled (default true; **false in test**), `:serve_mode` is not `:mcp`,
  and clustering is off. Boot recovery is explicitly the single-node restart
  mechanism (Reactor doc §4.8); multi-node reclaim is the deferred
  lease/fencing work (§4.11).
  """

  use Task

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.GateResume
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

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
    case WorkflowRun.list_non_terminal_global(authorize?: false) do
      {:ok, runs} ->
        Enum.each(runs, &reconcile_run/1)

      {:error, reason} ->
        Logger.warning("[WorkflowRecovery] non-terminal scan failed: #{inspect(reason)}")
    end

    :ok
  end

  # Classify on (status, checkpoint presence) and dispatch. Nothing is live at
  # boot, so the branch is decidable from DB state alone (no event fold).
  defp reconcile_run(run), do: reconcile_branch(classify(run), run)

  defp classify(%WorkflowRun{status: :awaiting_approval, resume_checkpoint: cp})
       when not is_nil(cp),
       do: :parked

  defp classify(%WorkflowRun{status: :awaiting_approval, resume_checkpoint: nil}),
    do: :dangling_gate

  defp classify(%WorkflowRun{status: :running, resume_checkpoint: cp}) when not is_nil(cp),
    do: :decision_recorded

  defp classify(%WorkflowRun{status: :pending, resume_checkpoint: cp}) when not is_nil(cp),
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

  # Dangling gate: cancel the run + the orphaned pending case, atomically, via
  # the shared WorkflowLog helper (the same choreography the runner's gate-pause
  # failure path uses).
  defp reconcile_branch(:dangling_gate, run) do
    run
    |> WorkflowLog.terminate_cancelling_cases(
      :run_cancelled,
      %{reason: @dangling_gate_reason},
      @dangling_gate_reason,
      tenant: run.tenant_id,
      actor: Actor.system(run.tenant_id)
    )
    |> finish(run, :dangling_gate)
  end

  # Decision already recorded: re-run the persisted reactor's durable downstream
  # steps. The after_approved hook is NOT run (Decision 8) — recovery never
  # routes through Cases.decide, so the hook is skipped by construction.
  defp reconcile_branch(:decision_recorded, run) do
    case GateResume.resume(run, recovered: true) do
      {:ok, _value, _resumed} ->
        emit(run, :decision_recorded)

      {:error, reason, _run} ->
        Logger.warning("[WorkflowRecovery] resume failed for run #{run.id}: #{inspect(reason)}")
        emit(run, :decision_recorded)
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
