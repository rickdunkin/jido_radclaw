defmodule JidoClaw.WorkflowViewTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.WorkflowStatus
  alias JidoClaw.WorkflowView

  setup do
    tenant_a = seed_tenant("workflow-view-a")
    tenant_b = seed_tenant("workflow-view-b")
    {:ok, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  test "list/1 and workflow_status hide runs from other tenants", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b
  } do
    {:ok, run_a} =
      WorkflowRun.create(%{name: "visible", workflow_type: "audit"},
        tenant: tenant_a,
        actor: actor_for(tenant_a)
      )

    {:ok, run_b} =
      WorkflowRun.create(%{name: "hidden", workflow_type: "audit"},
        tenant: tenant_b,
        actor: actor_for(tenant_b)
      )

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant_a})
    assert Enum.map(view.active_runs, & &1.run_id) == [run_a.id]

    assert {:error, :not_found} = WorkflowView.snapshot(run_b.id, %{tenant_id: tenant_a})

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant_a}})
    assert status["active_count"] == 1
    assert Enum.map(status["active_runs"], & &1["run_id"]) == [run_a.id]
  end

  test "tenant scope is required" do
    assert {:error, :tenant_required} = WorkflowView.list(%{})
    assert {:error, %{code: :tenant_required}} = WorkflowStatus.run(%{}, %{tool_context: %{}})
  end

  test "secrets seeded into result/error never reach MCP output (T2-2 security pin)",
       %{tenant_a: tenant} do
    secret = "sk-" <> String.duplicate("z", 24)

    {:ok, run} =
      WorkflowRun.create(%{name: "leaky", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # WorkflowRun.error/result store RAW values (only event payloads are
    # redacted at append) — corruption-sim them in directly.
    {:ok, _} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{
          status: :failed,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          completed_at: DateTime.utc_now(),
          error: "boom #{secret}",
          result: %{"summary" => "leaked #{secret}", "token" => secret}
        },
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant}})

    encoded = Jason.encode!(status)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED"

    leaky = Enum.find(status["recent_completions"], &(&1["run_id"] == run.id))
    assert leaky["error"] =~ "[REDACTED:API_KEY]"
    # Operator scope: only the filtered summary keys, never the raw result.
    refute Map.has_key?(leaky, "result")
  end

  test "an overdue run reports deadline evidence; runs without a policy report nil (T2-1)",
       %{tenant_a: tenant} do
    {:ok, run} =
      WorkflowRun.create(
        %{name: "late-run", workflow_type: "reactor", config: %{deadline: %{within: 60}}},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    {:ok, plain} =
      WorkflowRun.create(%{name: "no-policy", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # Started 5 minutes ago, still running — a 60s policy is overdue.
    # Corruption-sim precedent: stamp via the private projection action.
    {:ok, _} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{status: :running, started_at: DateTime.add(DateTime.utc_now(), -300, :second)},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant})

    late = Enum.find(view.active_runs, &(&1.run_id == run.id))
    assert late.deadline.status == :overdue
    assert late.deadline.overdue_by_ms > 0
    assert %DateTime{} = late.deadline.due_at

    # No policy / not-yet-started -> nil, additive key only.
    no_policy = Enum.find(view.active_runs, &(&1.run_id == plain.id))
    assert Map.has_key?(no_policy, :deadline)
    assert is_nil(no_policy.deadline)

    # The MCP tool inherits additively and JSON-safely.
    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant}})
    mcp_late = Enum.find(status["active_runs"], &(&1["run_id"] == run.id))
    assert mcp_late["deadline"]["status"] == "overdue"
    assert is_binary(mcp_late["deadline"]["due_at"])
  end
end
