defmodule JidoClaw.Orchestration.WorkflowRecovery do
  @moduledoc """
  Boot-time reconciler for runs stranded by a crash.

  `WorkflowRunner` drives a run synchronously in-process: if the BEAM dies
  between `run_started` and a terminal event, the run's projected status is
  stuck non-terminal forever with nothing to advance it. On boot this Task
  scans every non-terminal run and, for the no-gate case (all that exists in
  Phase 0), records `run_recovered` + `run_failed` so the projection folds it
  to `:failed` with an audit trail. **This is the original bug fix.**

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

  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

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

  # No-gate case only: nothing is live at boot, so a non-terminal run is
  # genuinely stranded -> fail-with-audit. Gate-aware parking (leave an
  # :awaiting_approval run that has a checkpoint untouched) lands with the
  # human-gate work; :awaiting_approval is currently unreachable, its producer
  # having been removed.
  defp reconcile_run(run) do
    case WorkflowLog.append_recovery(run, run.status) do
      {:ok, _event} ->
        :telemetry.execute(
          [:jido_claw, :orchestration, :recovered],
          %{count: 1},
          %{run_id: run.id, tenant_id: run.tenant_id, prior_status: run.status}
        )

      {:error, reason} ->
        Logger.warning("[WorkflowRecovery] failed to reconcile run #{run.id}: #{inspect(reason)}")
    end
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
