defmodule JidoClaw.Orchestration.AgentCasePendingForRunTreeTest do
  @moduledoc """
  Pins the `:pending_for_run_tree` read — the one-shot runner's composer gate
  probe. A composer PARENT stays `:running` while parked on a human gate (the
  child wave run goes `:awaiting_approval` and carries the `AgentCase`), so
  the probe must see cases on the run itself AND on its direct children.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    tenant_id = seed_tenant("run-tree")
    {:ok, tenant_id: tenant_id, actor: actor_for(tenant_id)}
  end

  defp seed_run(ctx, attrs \\ %{}) do
    {:ok, run} =
      WorkflowRun.create(
        Map.merge(
          %{name: "run-#{System.unique_integer([:positive])}", workflow_type: "composer"},
          attrs
        ),
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    run
  end

  defp open_case(ctx, run_id) do
    {:ok, agent_case} =
      AgentCase.create(
        %{workflow_run_id: run_id, step_name: "gate", kind: :irreversible_write},
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    agent_case
  end

  test "finds a pending case on the run itself", ctx do
    parent = seed_run(ctx)
    agent_case = open_case(ctx, parent.id)

    assert {:ok, [found]} =
             AgentCase.pending_for_run_tree(parent.id, tenant: ctx.tenant_id, actor: ctx.actor)

    assert found.id == agent_case.id
  end

  test "finds a pending case on a direct child run from the parent id", ctx do
    parent = seed_run(ctx)
    child = seed_run(ctx, %{parent_run_id: parent.id})
    agent_case = open_case(ctx, child.id)

    assert {:ok, [found]} =
             AgentCase.pending_for_run_tree(parent.id, tenant: ctx.tenant_id, actor: ctx.actor)

    assert found.id == agent_case.id
  end

  test "cases on unrelated runs are excluded", ctx do
    parent = seed_run(ctx)
    unrelated = seed_run(ctx)
    _noise = open_case(ctx, unrelated.id)

    assert {:ok, []} =
             AgentCase.pending_for_run_tree(parent.id, tenant: ctx.tenant_id, actor: ctx.actor)
  end

  test "decided cases are excluded", ctx do
    parent = seed_run(ctx)
    child = seed_run(ctx, %{parent_run_id: parent.id})
    agent_case = open_case(ctx, child.id)

    {:ok, _} = AgentCase.approve(agent_case, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

    assert {:ok, []} =
             AgentCase.pending_for_run_tree(parent.id, tenant: ctx.tenant_id, actor: ctx.actor)
  end
end
