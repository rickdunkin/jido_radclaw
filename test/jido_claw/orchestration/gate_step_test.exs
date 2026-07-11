defmodule JidoClaw.Orchestration.GateStepTest do
  @moduledoc """
  Item 9 — the `GateStep` runtime `:extra_details` merge, pinned through the
  real production path (`Reactors.PlanGate`'s `input(:lint)` →
  `argument(:extra_details, …)` → the case details):

    * a namespaced `premises_lint` payload lands in `AgentCase.details`
      WITHOUT disturbing `summary`/`gate_title`/`gate_description`/`fields`
      (the survival pin — the namespace makes collision impossible);
    * an empty payload (`lint: %{}` — the clean-report case) leaves the
      details byte-identical to the DSL + options seed;
    * a reactor with NO `extra_details` argument at all (`GatedTestReactor`)
      also stays byte-identical (the arguments-absent clause).
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.Gate.Presentation
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.Reactors.PlanGate
  alias JidoClaw.Orchestration.WorkflowRun

  @lint_payload %{
    "premises_lint" => %{
      "grade" => "b",
      "findings" => [
        %{
          "code" => "vague_acceptance_criteria",
          "message" => "Acceptance criterion is vague: The CLI should be easy",
          "target" => "AC1"
        }
      ],
      "advisories" => []
    }
  }

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gatestep")
    actor = actor_for(tenant)

    {:ok, parent} =
      WorkflowRun.create(%{name: "gatestep-parent", workflow_type: "composer"},
        tenant: tenant,
        actor: actor
      )

    {:ok, %ComposerArtifact{ref: plan_ref}} =
      ComposerArtifact.store_pending(
        %{
          ref: JidoClaw.Refs.mint("art_"),
          name: "plan",
          producer: "planner",
          term: "PLAN: the plan body",
          child_run_id: nil,
          parent_run_id: parent.id,
          wave_index: 0
        },
        tenant: tenant,
        actor: actor
      )

    {:ok, tenant: tenant, actor: actor, parent: parent, plan_ref: plan_ref}
  end

  test "a premises_lint payload merges into the case details; summary/gate_title survive",
       ctx do
    assert {:ok, {:paused, case_id}, _run} = run_plan_gate(ctx, @lint_payload)

    {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))

    assert %{"grade" => "b", "findings" => [finding]} = agent_case.details["premises_lint"]
    assert finding["code"] == "vague_acceptance_criteria"
    assert finding["target"] == "AC1"

    # Survival pin: the namespaced merge can never collide with the DSL seed.
    assert agent_case.details["summary"] == "Approve the implementation plan before execution"
    assert agent_case.details["gate_title"] == "Approve plan"
    assert is_binary(agent_case.details["gate_description"])
    assert is_list(agent_case.details["fields"])
  end

  test "an empty lint payload (%{} — the clean report) leaves details byte-identical", ctx do
    assert {:ok, {:paused, case_id}, _run} = run_plan_gate(ctx, %{})

    {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))

    assert agent_case.details ==
             expected_details(JidoClaw.Gates.PlanGate, %{
               "summary" => "Approve the implementation plan before execution"
             })
  end

  test "a reactor with NO extra_details argument stays byte-identical (arguments-absent)",
       ctx do
    assert {:ok, {:paused, case_id}, _run} =
             ReactorRunner.run(
               GatedTestReactor,
               %{workspace_name: "gatestep-ws", workspace_path: "/tmp/gatestep-ws"},
               tenant: ctx.tenant,
               actor: ctx.actor
             )

    {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))

    assert agent_case.details ==
             expected_details(TestIrreversibleWrite, %{"summary" => "create workspace"})
  end

  # -- Helpers --

  defp run_plan_gate(ctx, lint) do
    ReactorRunner.run(
      PlanGate,
      %{
        plan_ref: ctx.plan_ref,
        wave_index: 0,
        stage_name: "plan-gate",
        artifact_name: "approved-plan",
        signal_name: "plan-approved",
        lint: lint
      },
      tenant: ctx.tenant,
      actor: ctx.actor,
      parent_run_id: ctx.parent.id
    )
  end

  # The DSL + options seed as it reads back through the jsonb column (atom
  # option keys land as strings).
  defp expected_details(gate_module, options_details) do
    gate_module
    |> Presentation.details()
    |> Map.merge(options_details)
    |> json_round_trip()
  end

  defp json_round_trip(map), do: Jason.decode!(Jason.encode!(map))

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]
end
