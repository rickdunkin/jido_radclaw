defmodule JidoClaw.Orchestration.WorkflowRecoveryTest do
  @moduledoc """
  Pins the boot recovery reconciler — the original stranding-bug fix.

  Boot recovery is disabled in test (`config :jido_claw, :workflow_recovery,
  enabled?: false`), so these drive `reconcile_all/0` directly inside the
  sandbox: a stranded non-terminal run folds to `:failed` with a
  `run_recovered` + `run_failed` audit pair; terminal runs are untouched; the
  scan is tenant-blind.
  """
  use JidoClaw.TenantCase

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun

  # Strand a run mid-flight: created + run_started, no terminal event.
  defp strand_running(tenant) do
    {:ok, run} = WorkflowRun.create(%{name: "stranded"}, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    assert running.status == :running
    running
  end

  test "a stranded :running run reconciles to :failed with an audit pair" do
    tenant = seed_tenant("recovery")
    run = strand_running(tenant)

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, recovered} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    assert recovered.status == :failed

    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
    recovered_ev = Enum.find(events, &(&1.kind == :run_recovered))
    failed_ev = Enum.find(events, &(&1.kind == :run_failed))

    assert recovered_ev
    assert failed_ev
    # consecutive seq — the recovery pair committed together, in order
    assert failed_ev.seq == recovered_ev.seq + 1
    assert recovered_ev.payload["prior_status"] == "running"
    assert Projection.project_status(events) == :failed
  end

  test "a terminal (:completed) run is left untouched" do
    tenant = seed_tenant("recovery-terminal")
    {:ok, run} = WorkflowRun.create(%{name: "done"}, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(running, :run_completed, %{result: %{"ok" => true}})

    {:ok, before} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, still} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    {:ok, after_events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

    assert still.status == :completed
    assert length(after_events) == length(before)
  end

  test "reconciliation is tenant-blind — strands in two tenants both fail in one pass" do
    tenant_a = seed_tenant("recovery-a")
    tenant_b = seed_tenant("recovery-b")
    run_a = strand_running(tenant_a)
    run_b = strand_running(tenant_b)

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, a} = WorkflowRun.by_id(run_a.id, tenant: tenant_a, actor: actor_for(tenant_a))
    {:ok, b} = WorkflowRun.by_id(run_b.id, tenant: tenant_b, actor: actor_for(tenant_b))

    assert a.status == :failed
    assert b.status == :failed
  end
end
