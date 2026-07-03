defmodule JidoClaw.CLI.RunAwaitTest do
  @moduledoc """
  Drives `JidoClaw.CLI.RunAwait.await/4` against seeded runs: terminal
  detection by polling, gate detection through the run TREE (composer parents
  stay `:running` while a child wave parks on a gate), and the timeout path.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.CLI.RunAwait
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    tenant_id = seed_tenant("run-await")
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

  defp set_status!(run, status, ctx) do
    {:ok, updated} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{status: status, completed_at: DateTime.utc_now()},
        tenant: ctx.tenant_id,
        authorize?: false
      )
      |> Ash.update()

    updated
  end

  test "a terminal run resolves {:done, status, run} immediately", ctx do
    run = seed_run(ctx)
    set_status!(run, :completed, ctx)

    assert {:done, :completed, %WorkflowRun{id: id}} =
             RunAwait.await(run.id, ctx.tenant_id, ctx.actor, 5_000)

    assert id == run.id
  end

  test "failed terminals resolve with their status", ctx do
    run = seed_run(ctx)
    set_status!(run, :failed, ctx)

    assert {:done, :failed, _run} = RunAwait.await(run.id, ctx.tenant_id, ctx.actor, 5_000)
  end

  test "a pending gate on a CHILD run resolves {:gate_pending, ids} from the parent", ctx do
    parent = seed_run(ctx)
    child = seed_run(ctx, %{parent_run_id: parent.id})

    {:ok, agent_case} =
      AgentCase.create(
        %{workflow_run_id: child.id, step_name: "gate", kind: :irreversible_write},
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    assert {:gate_pending, [case_id]} =
             RunAwait.await(parent.id, ctx.tenant_id, ctx.actor, 5_000)

    assert case_id == agent_case.id
  end

  test "a run that never terminalizes times out", ctx do
    run = seed_run(ctx)

    assert :timeout = RunAwait.await(run.id, ctx.tenant_id, ctx.actor, 50)
  end

  test "an unknown run id surfaces an error tuple", ctx do
    assert {:error, _} =
             RunAwait.await(Ecto.UUID.generate(), ctx.tenant_id, ctx.actor, 1_000)
  end
end
