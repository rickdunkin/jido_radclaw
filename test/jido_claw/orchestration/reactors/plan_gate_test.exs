defmodule JidoClaw.Orchestration.Reactors.PlanGateTest do
  @moduledoc """
  AR-2 §14 Phase 4a — `Reactors.PlanGate` driven straight through `ReactorRunner`
  (initial pause) + `Cases.decide/4` (completion), independent of the composer
  loop. Asserts the gate pauses at its `GateStep`, approve resumes it to the
  `WaveCollect`-shaped emission envelope, and the `approved-plan` artifact holds
  the RAW plan value as an `:active`-promotable `:pending` row.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.PlanGate
  alias JidoClaw.Orchestration.WorkflowRun

  @raw_plan "PLAN: build the auth feature with a non-lossy, multi-line body\nstep 2: …"

  setup do
    tenant = seed_tenant("plangate")
    actor = actor_for(tenant)

    # A composer parent for the gate child to link to, and the `plan` input
    # ref-stored as a seed-shaped row (child_run_id: nil) the gate resolves.
    {:ok, parent} =
      WorkflowRun.create(%{name: "plangate-parent", workflow_type: "composer"},
        tenant: tenant,
        actor: actor
      )

    {:ok, %ComposerArtifact{ref: plan_ref}} =
      ComposerArtifact.store_pending(
        %{
          ref: gen_ref(),
          name: "plan",
          producer: "planner",
          term: @raw_plan,
          child_run_id: nil,
          parent_run_id: parent.id,
          wave_index: 0
        },
        tenant: tenant,
        actor: actor
      )

    {:ok, tenant: tenant, actor: actor, parent: parent, plan_ref: plan_ref}
  end

  test "pauses at the gate, then approve resumes to the emission envelope + raw approved-plan",
       ctx do
    assert {:ok, {:paused, case_id}, run} = run_gate(ctx)
    assert run.status == :awaiting_approval
    refute is_nil(run.encrypted_resume_checkpoint)

    # `Cases.decide(:approve)` resumes internally (resume: true default) — it
    # alone drives the child to :completed; do not also call GateResume.
    assert {:ok, _resumed} = Cases.decide(case_id, :approve, %{}, scope(ctx))

    {:ok, child} = WorkflowRun.by_id(run.id, scope(ctx))
    assert child.status == :completed

    # The SAME json-safe envelope a worker wave's WaveCollect returns.
    assert %{"wave_index" => 0, "emissions" => [emission]} = child.result
    assert emission["stage"] == "plan-gate"
    assert emission["signals"] == ["plan-approved"]
    assert %{"approved-plan" => approved_ref} = emission["artifacts"]

    # The approved-plan holds the RAW plan value (NOT a 4 KB-capped rendering).
    assert {:ok, @raw_plan} = ComposerArtifact.resolve_value(approved_ref, scope(ctx))

    # It is a :pending row at the gate's wave — :active-promotable by the
    # composer's commit_wave (activate_for_wave), not activated inside the reactor.
    assert {:ok, %ComposerArtifact{state: :pending}} =
             ComposerArtifact.resolve_ref(approved_ref, scope(ctx))

    {:ok, pendings} = ComposerArtifact.pending_for_wave(ctx.parent.id, 0, scope(ctx))
    assert Enum.any?(pendings, &(&1.ref == approved_ref))
  end

  test "reject cancels the run before the emit step — no approved-plan produced", ctx do
    assert {:ok, {:paused, case_id}, run} = run_gate(ctx)

    assert {:ok, _cancelled} = Cases.decide(case_id, :reject, %{}, scope(ctx))

    {:ok, child} = WorkflowRun.by_id(run.id, scope(ctx))
    assert child.status == :cancelled

    # The emit step never ran: only the input `plan` is pending, no `approved-plan`.
    {:ok, pendings} = ComposerArtifact.pending_for_wave(ctx.parent.id, 0, scope(ctx))
    refute Enum.any?(pendings, &(&1.producer == "plan-gate"))
  end

  # -- Helpers --

  defp run_gate(ctx) do
    ReactorRunner.run(
      PlanGate,
      %{
        plan_ref: ctx.plan_ref,
        wave_index: 0,
        stage_name: "plan-gate",
        artifact_name: "approved-plan",
        signal_name: "plan-approved"
      },
      tenant: ctx.tenant,
      actor: ctx.actor,
      parent_run_id: ctx.parent.id
    )
  end

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]

  defp gen_ref, do: JidoClaw.Refs.mint("art_")
end
