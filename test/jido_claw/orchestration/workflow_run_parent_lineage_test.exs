defmodule JidoClaw.Orchestration.WorkflowRunParentLineageTest do
  @moduledoc """
  AR-2 Phase 2a — the parent-run lineage `WorkflowRun` gained: the writable,
  cross-tenant-guarded `parent_run_id` FK, and the `WorkflowRecovery` no-op guard
  that keeps reactor recovery from clobbering a `:running` composer parent.

  Non-async (`TenantCase`): the recovery test drives `WorkflowRecovery.reconcile_all/0`,
  a tenant-blind global scan, so it must not run concurrently with other runs.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer

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

  describe "WorkflowRecovery composer no-op guard" do
    test "reconcile_all leaves a :running composer parent untouched" do
      tenant = seed_tenant("lineage-recovery")
      actor = actor_for(tenant)

      # create_parent_run leaves the parent :running (create + run_started) with
      # no checkpoint — exactly the (status, checkpoint) pair the shipped
      # `:running + no checkpoint → :stranded → :failed` branch would clobber.
      assert {:ok, parent} = RouteComposer.create_parent_run(tenant: tenant, actor: actor)
      assert parent.status == :running

      assert :ok = WorkflowRecovery.reconcile_all()

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
end
