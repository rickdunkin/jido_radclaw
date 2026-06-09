defmodule JidoClaw.Orchestration.GateLifecycleTest do
  @moduledoc """
  WS5/WS7: the `AgentCaseEvent` timeline (every case transition appends in
  the same transaction) and the AR-1 gate lifecycle — operator `abandon` and
  stale-approval `retract` (exercised through the `resume: false` commit-only
  seam).
  """
  use JidoClaw.TenantCase

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gatelc")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "AgentCaseEvent timeline" do
    test "gate_open appends :opened; approve appends :approved — gap-free seq", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      assert {:ok, [opened]} = AgentCaseEvent.for_case(case_id, scope(ctx))
      assert opened.type == :opened
      assert opened.seq == 1
      assert opened.data["kind"] == "irreversible_write"

      assert {:ok, _run} = Cases.decide(case_id, :approve, %{}, scope(ctx))

      assert {:ok, [^opened, approved]} = AgentCaseEvent.for_case(case_id, scope(ctx))
      assert approved.type == :approved
      assert approved.seq == 2
      assert approved.data["decision"] == "approve"
    end

    test "reject appends :rejected with the decision data", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      assert {:ok, _run} =
               Cases.decide(case_id, :reject, %{decision_comment: "too risky"}, scope(ctx))

      assert {:ok, [_opened, rejected]} = AgentCaseEvent.for_case(case_id, scope(ctx))
      assert rejected.type == :rejected
      assert rejected.data["comment"] == "too risky"
    end

    test "the GateStep seeds the case details from the gate DSL", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))

      assert agent_case.kind == :irreversible_write
      assert agent_case.details["gate_title"] == "Approve irreversible write (test)"
      # Caller-supplied details merge over the DSL seed.
      assert agent_case.details["summary"] == "create workspace"

      assert [field] = agent_case.details["fields"]
      assert field["name"] == "comment"
      assert field["type"] == "textarea"
      assert field["label"] == "Comment"
    end
  end

  describe "abandon (AR-1)" do
    test "abandon from :awaiting_approval reaches :abandoned and drops the case", ctx do
      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, run} = result

      assert {:ok, abandoned_run} =
               Cases.abandon(case_id, %{cancellation_reason: "not worth it"}, scope(ctx))

      assert abandoned_run.status == :abandoned
      assert %DateTime{} = abandoned_run.completed_at
      assert is_nil(abandoned_run.encrypted_resume_checkpoint)

      assert :run_abandoned in kinds(run, ctx)

      assert {:ok, %AgentCase{status: :abandoned, cancellation_reason: "not worth it"}} =
               AgentCase.by_id(case_id, scope(ctx))

      assert {:ok, case_events} = AgentCaseEvent.for_case(case_id, scope(ctx))
      assert Enum.map(case_events, & &1.type) == [:opened, :abandoned]

      # The inbox is empty and the downstream write never ran.
      assert {:ok, []} = AgentCase.pending_for_run(run.id, scope(ctx))
      refute workspace_exists?(inputs.workspace_path, ctx)
    end

    test "abandon against a :running run is refused and rolls back atomically", ctx do
      %{tenant: tenant} = ctx
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, run} = result

      # Force the run live (:running) while the case is still pending — the
      # state abandon must refuse (no live-process cancellation this phase).
      {:ok, parked} = WorkflowRun.by_id(run.id, scope(ctx))

      {:ok, _} =
        parked
        |> Ash.Changeset.for_update(:set_status, %{status: :running},
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update()

      assert {:error, _reason} = Cases.abandon(case_id, %{}, scope(ctx))

      # The illegal run_abandoned rolled the WHOLE transaction back: the case
      # flip reverted with it, and no run_abandoned event persisted.
      assert {:ok, %AgentCase{status: :pending}} = AgentCase.by_id(case_id, scope(ctx))
      assert reload(run, ctx).status == :running
      refute :run_abandoned in kinds(run, ctx)
    end

    test "abandon through an already-decided case is refused", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      assert {:ok, _} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert {:error, :not_pending} = Cases.abandon(case_id, %{}, scope(ctx))
    end
  end

  describe "stale-approval retraction (AR-1)" do
    test "retract pre-resume reopens the case clean and re-earns the approval", ctx do
      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, run} = result

      # Commit-only approve: the pre-resume window, made real by the seam.
      assert {:ok, running} =
               Cases.decide(
                 case_id,
                 :approve,
                 %{decision_comment: "lgtm", decided_by_id: Ecto.UUID.generate()},
                 Keyword.put(scope(ctx), :resume, false)
               )

      assert running.status == :running
      assert is_binary(running.encrypted_resume_checkpoint)
      assert {:ok, %AgentCase{status: :approved}} = AgentCase.by_id(case_id, scope(ctx))
      refute workspace_exists?(inputs.workspace_path, ctx)

      # Retract: the run parks back at the gate, the case reopens with ALL
      # decision data cleared, the checkpoint survives.
      assert {:ok, parked} = Cases.retract(case_id, %{decision_comment: "re-plan"}, scope(ctx))
      assert parked.status == :awaiting_approval
      assert is_binary(parked.encrypted_resume_checkpoint)

      assert {:ok, reopened} = AgentCase.by_id(case_id, scope(ctx))
      assert reopened.status == :pending
      assert is_nil(reopened.decision)
      assert is_nil(reopened.decided_at)
      assert is_nil(reopened.decision_comment)
      assert is_nil(reopened.decided_by_id)

      assert :approval_retracted in kinds(run, ctx)

      assert {:ok, case_events} = AgentCaseEvent.for_case(case_id, scope(ctx))
      assert Enum.map(case_events, & &1.type) == [:opened, :approved, :retracted]

      # The revised plan re-earns its approval: a full approve now resumes to
      # completion.
      assert {:ok, completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert completed.status == :completed
      assert workspace_exists?(inputs.workspace_path, ctx)
    end

    test "retract after the reactor resumed is refused with :already_resumed", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      # Full approve: approval_resolved + run_resumed (the resume ran).
      assert {:ok, completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert completed.status == :completed

      assert {:error, :already_resumed} = Cases.retract(case_id, %{}, scope(ctx))

      # Nothing changed: the case keeps its decision.
      assert {:ok, %AgentCase{status: :approved}} = AgentCase.by_id(case_id, scope(ctx))
    end

    test "retract of a still-pending case is refused (nothing to retract)", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      assert {:error, :not_approved} = Cases.retract(case_id, %{}, scope(ctx))
      assert {:ok, %AgentCase{status: :pending}} = AgentCase.by_id(case_id, scope(ctx))
    end
  end

  # -- Helpers --

  defp run_gated(tenant, actor) do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "gatelc-ws-#{uniq}", workspace_path: "/tmp/gatelc-ws-#{uniq}"}
    {ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor), inputs}
  end

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]

  defp reload(run, ctx) do
    {:ok, reloaded} = WorkflowRun.by_id(run.id, scope(ctx))
    reloaded
  end

  defp kinds(run, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run.id, scope(ctx))
    Enum.map(events, & &1.kind)
  end

  defp workspace_exists?(path, ctx) do
    case Workspace.by_path(nil, path, scope(ctx)) do
      {:ok, %Workspace{}} -> true
      _ -> false
    end
  end
end
