defmodule JidoClaw.CLI.Commands.ApprovalsTest do
  @moduledoc """
  Pins the `/gates` REPL surface: listing the pending inbox and routing an
  approve decision through `Cases.decide/4` (under a tenant system actor, since
  the REPL is unauthenticated).
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.CLI.Commands.Approvals
  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.WorkflowLog
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

  # Camus C1-4: /gates renders a review-stall case legibly (finding list, not
  # inspect(details)) and approve records WAIVE-ALL — one derived record per
  # required key (from the complete finding_keys, not the capped display),
  # landing on the case's :approved timeline event.
  test "/gates renders a review-stall case and approve records waive-all",
       %{tenant: tenant, actor: actor} do
    {case_id, key} = stall_case(tenant, actor)
    state = %{tenant_id: tenant}

    listing = capture_io(fn -> assert {:ok, ^state} = Approvals.list(state) end)
    assert listing =~ "missing nil check"
    assert listing =~ "review_stall"
    assert listing =~ "waive"

    output =
      capture_io(fn ->
        assert {:ok, ^state} = Approvals.decide(state, :approve, case_id, "accepted")
      end)

    assert output =~ "Waivers recorded"

    {:ok, decided} = AgentCase.by_id(case_id, tenant: tenant, actor: actor)
    assert decided.status == :approved

    {:ok, case_events} = AgentCaseEvent.for_case(case_id, tenant: tenant, actor: actor)
    approved = Enum.find(case_events, &(&1.type == :approved))
    assert [%{"key" => ^key, "severity" => "error"}] = approved.data["waive_records"]
  end

  defp stall_case(tenant, actor) do
    {:ok, parent} =
      WorkflowRun.create(%{name: "stalled-composer", workflow_type: "composer"},
        tenant: tenant,
        actor: actor
      )

    {:ok, _} = WorkflowLog.append(parent, :run_started, %{}, tenant: tenant, actor: actor)
    key = String.duplicate("c", 64)

    {:ok, gate} =
      WorkflowLog.case_open_runbound(
        parent,
        %{
          workflow_run_id: parent.id,
          step_name: "review-stall",
          fingerprint: "cli-stall-fp",
          details: %{
            "finding_keys" => [key],
            "findings" => [
              %{
                "key" => key,
                "title" => "missing nil check",
                "severity" => "error",
                "location" => "lib/auth.ex"
              }
            ],
            "resume_hint" => "waive every finding and approve, or reject"
          }
        },
        tenant: tenant,
        actor: actor
      )

    {gate.id, key}
  end

  defp run_gated(tenant, actor) do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "cli-ws-#{uniq}", workspace_path: "/tmp/cli-ws-#{uniq}"}
    ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor)
  end
end
