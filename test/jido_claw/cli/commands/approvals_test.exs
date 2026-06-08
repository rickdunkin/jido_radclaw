defmodule JidoClaw.CLI.Commands.ApprovalsTest do
  @moduledoc """
  Pins the `/gates` REPL surface: listing the pending inbox and routing an
  approve decision through `Cases.decide/4` (under a tenant system actor, since
  the REPL is unauthenticated).
  """
  use JidoClaw.TenantCase

  import ExUnit.CaptureIO

  alias JidoClaw.CLI.Commands.Approvals
  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gates-cli")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  test "/gates lists the pending inbox", %{tenant: tenant, actor: actor} do
    {:ok, {:paused, case_id}, _run} = run_gated(tenant, actor)
    state = %{tenant_id: tenant}

    output = capture_io(fn -> assert {:ok, ^state} = Approvals.list(state) end)

    assert output =~ "Approval Gates"
    assert output =~ case_id
    assert output =~ "approval_gate"
  end

  test "/gates approve resumes the run to completion", %{tenant: tenant, actor: actor} do
    {:ok, {:paused, case_id}, run} = run_gated(tenant, actor)
    state = %{tenant_id: tenant}

    output =
      capture_io(fn ->
        assert {:ok, ^state} = Approvals.decide(state, :approve, case_id, "looks good")
      end)

    assert output =~ "approved"
    {:ok, completed} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)
    assert completed.status == :completed
  end

  defp run_gated(tenant, actor) do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "cli-ws-#{uniq}", workspace_path: "/tmp/cli-ws-#{uniq}"}
    ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor)
  end
end
