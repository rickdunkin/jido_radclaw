defmodule JidoClaw.Orchestration.WorkflowRunParentLineageTest do
  @moduledoc """
  AR-2 Phase 2a — the parent-run lineage `WorkflowRun` gained the writable,
  cross-tenant-guarded `parent_run_id` FK. Phase 2d turned the `WorkflowRecovery`
  composer guard from a no-op observe into the real rebuild+resume branch: a
  `:running` composer parent with a recoverable config catalog is restarted and
  resumed; one with no recoverable catalog (absent/malformed) is left `:running`
  with a logged warning; a never-started `:pending` composer still fails (H20).

  Non-async (`TenantCase`): the recovery tests drive `WorkflowRecovery.reconcile_all/0`,
  a tenant-blind global scan, so they must not run concurrently with other runs.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures

  @composer_supervisor JidoClaw.RouteComposer.Supervisor

  describe "cross-tenant parent_run_id guard" do
    test "a child run pointing at a parent in another tenant is rejected" do
      tenant_a = seed_tenant("lineage-a")
      tenant_b = seed_tenant("lineage-b")

      {:ok, parent_a} =
        WorkflowRun.create(%{name: "parent-a", workflow_type: "composer"},
          tenant: tenant_a,
          actor: actor_for(tenant_a)
        )

      assert {:error, %Ash.Error.Invalid{} = err} =
               WorkflowRun.create(
                 %{name: "child-b", workflow_type: "reactor", parent_run_id: parent_a.id},
                 tenant: tenant_b,
                 actor: actor_for(tenant_b)
               )

      # Errors arrive nested as `Ash.Error.Invalid` wrapping
      # `Ash.Error.Changes.InvalidAttribute` carrying the
      # `cross_tenant_fk_mismatch` message (the `CrossTenantFk.validate/2`
      # precedent in solution_test.exs).
      assert Enum.any?(err.errors, &match?(%{message: "cross_tenant_fk_mismatch"}, &1)),
             "expected :cross_tenant_fk_mismatch in error chain; got: #{inspect(err)}"
    end

    test "a child run pointing at a same-tenant parent is accepted" do
      tenant = seed_tenant("lineage-same")

      {:ok, parent} =
        WorkflowRun.create(%{name: "parent", workflow_type: "composer"},
          tenant: tenant,
          actor: actor_for(tenant)
        )

      assert {:ok, child} =
               WorkflowRun.create(
                 %{name: "child", workflow_type: "reactor", parent_run_id: parent.id},
                 tenant: tenant,
                 actor: actor_for(tenant)
               )

      assert child.parent_run_id == parent.id
    end

    test "a root composer parent (nil parent_run_id) passes the guard" do
      tenant = seed_tenant("lineage-root")

      assert {:ok, parent} =
               WorkflowRun.create(%{name: "root", workflow_type: "composer"},
                 tenant: tenant,
                 actor: actor_for(tenant)
               )

      assert is_nil(parent.parent_run_id)
    end
  end

  describe "WorkflowRecovery composer rebuild+resume branch (Phase 2d)" do
    test "a :running composer with a recoverable config catalog is rebuilt + resumed" do
      tenant = seed_tenant("lineage-recoverable")
      actor = actor_for(tenant)

      # A genesis with the serialized catalog + seed live/artifacts in config, and
      # `max_waves: 0` so the resumed loop dispatches a cohort then immediately
      # hits the budget — terminalizing WITHOUT running a real wave (no stub-worker
      # harness needed). The terminal proves recovery decoded the catalog, started
      # the supervised composer, folded the genesis seed events (live/artifacts
      # rebuilt → a dispatch was found), and resumed the loop.
      on_exit(&sweep_composers/0)

      {:ok, parent} =
        RouteComposer.create_parent_run(
          tenant: tenant,
          actor: actor,
          catalog: TestFixtures.phase1_catalog(),
          live: TestFixtures.phase1_seed_live(),
          artifacts: TestFixtures.phase1_seed_artifacts(),
          max_waves: 0
        )

      assert parent.status == :running
      assert :ok = WorkflowRecovery.reconcile_all()

      assert :failed = await_status(parent.id, tenant, actor, :failed, 15_000)
      {:ok, events} = WorkflowEvent.for_run(parent.id, tenant: tenant, actor: actor)
      assert :route_budget_exhausted in Enum.map(events, & &1.kind)
    end

    test "a :running composer with no recoverable catalog is left :running with a warning" do
      tenant = seed_tenant("lineage-no-catalog")
      actor = actor_for(tenant)

      # create_parent_run with NO catalog leaves the parent :running with an empty
      # config — un-recoverable. Recovery logs a warning and leaves it :running
      # (never failing it via the reactor `:stranded` branch, never starting a
      # composer with catalog: nil that would crash inside compose_route).
      assert {:ok, parent} = RouteComposer.create_parent_run(tenant: tenant, actor: actor)
      assert parent.status == :running

      log =
        capture_log(fn ->
          assert :ok = WorkflowRecovery.reconcile_all()
        end)

      assert log =~ "no recoverable catalog"

      assert {:ok, reloaded} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)
      assert reloaded.status == :running
    end

    test "reconcile_all fails a never-started :pending composer parent" do
      tenant = seed_tenant("lineage-pending")
      actor = actor_for(tenant)

      # A composer row from the public create/1 (NOT create_parent_run) never gets
      # its run_started, so it sits :pending with no checkpoint — the narrowed guard
      # lets it fall through to the :stranded branch instead of observing it forever.
      {:ok, parent} =
        WorkflowRun.create(%{name: "stranded-composer", workflow_type: "composer"},
          tenant: tenant,
          actor: actor
        )

      assert parent.status == :pending
      assert :ok = WorkflowRecovery.reconcile_all()

      assert {:ok, reloaded} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)
      assert reloaded.status == :failed

      # Assert the recovery audit, not just the terminal status — this locks the
      # intended fall-through to fail_stranded/2 → WorkflowLog.append_recovery/2,
      # which writes the pair in seq order (`:for_run` sorts seq ascending). A
      # directly-created :pending run has no prior events, so these are the only two.
      assert {:ok, events} = WorkflowEvent.for_run(parent.id, tenant: tenant, actor: actor)
      assert Enum.map(events, & &1.kind) == [:run_recovered, :run_failed]
    end
  end

  # reconcile_all/0 returns once the supervised composer has *started* (not
  # finished), so poll for the durable terminal.
  defp await_status(run_id, tenant, actor, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(run_id, tenant, actor, target, deadline)
  end

  defp await_status_loop(run_id, tenant, actor, target, deadline) do
    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor)

    cond do
      run.status == target -> run.status
      System.monotonic_time(:millisecond) >= deadline -> run.status
      true -> Process.sleep(25) && await_status_loop(run_id, tenant, actor, target, deadline)
    end
  end

  # Sweep any composer the recoverable test started (terminate_child, not kill — a
  # :transient child would otherwise be restarted by a kill).
  defp sweep_composers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@composer_supervisor) do
      DynamicSupervisor.terminate_child(@composer_supervisor, pid)
    end
  end
end
