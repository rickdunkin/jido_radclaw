defmodule JidoClaw.Orchestration.NeedsInputTest do
  @moduledoc """
  The needs-input producer (item 7 PR-4): question-agnostic fingerprinting,
  the raise/reuse fence, single-use TTL-bounded answer claims, the identity
  floor (session → run → refuse), the identity-vs-FK split, and the
  kind-dispatched `Cases` decide/abandon branches (answer guard included).
  """
  use JidoClaw.TenantCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.NeedsInput
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "needs-input")
    actor = actor_for(tenant_id)

    {:ok, tenant_id: tenant_id, actor: actor, session: session}
  end

  # The ONE construction site for a producer scope in this file (reach
  # fixed_shape_map discipline) — overrides merge over the session-keyed
  # vendor default.
  defp scope(ctx, overrides \\ []) do
    Map.merge(
      %{
        tenant_id: ctx.tenant_id,
        actor: ctx.actor,
        session_uuid: ctx.session.id,
        session_id: ctx.session.external_id,
        workflow_run_id: nil,
        template_name: "coder",
        step_name: "v-step",
        vendor?: true
      },
      Map.new(overrides)
    )
  end

  defp create_run!(ctx) do
    {:ok, run} =
      WorkflowRun.create(
        %{name: "ni-run-#{System.unique_integer([:positive])}", workflow_type: "reactor"},
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    run
  end

  defp case_events!(agent_case, ctx) do
    {:ok, events} =
      AgentCaseEvent.for_case(agent_case.id, tenant: ctx.tenant_id, actor: ctx.actor)

    events
  end

  defp backdate_decision!(agent_case, hours) do
    past = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    {1, _} =
      JidoClaw.Repo.update_all(
        from(c in "agent_cases", where: c.id == type(^agent_case.id, :binary_id)),
        set: [decided_at: past]
      )
  end

  describe "fingerprint/1" do
    test "is deterministic and question-agnostic (no question term at all)", ctx do
      assert NeedsInput.fingerprint(scope(ctx)) == NeedsInput.fingerprint(scope(ctx))
    end

    test "distinguishes template/stage/session identities", ctx do
      base = NeedsInput.fingerprint(scope(ctx))

      refute NeedsInput.fingerprint(scope(ctx, template_name: "reviewer")) == base
      refute NeedsInput.fingerprint(scope(ctx, step_name: "other-stage")) == base

      refute NeedsInput.fingerprint(scope(ctx, session_uuid: nil, session_id: "other-session")) ==
               base
    end

    test "identity floor: session → run → nil", ctx do
      run_scoped = scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: "run-a")
      assert is_binary(NeedsInput.fingerprint(run_scoped))

      refute NeedsInput.fingerprint(run_scoped) ==
               NeedsInput.fingerprint(%{run_scoped | workflow_run_id: "run-b"})

      assert NeedsInput.fingerprint(
               scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: nil)
             ) == nil
    end
  end

  describe "raise_case/2" do
    test "opens a pending case: provenance, redacted question, hint, injectable + :opened event",
         ctx do
      secret = "ghp_" <> String.duplicate("a", 36)

      assert {:ok, agent_case} =
               NeedsInput.raise_case(scope(ctx), "Which remote? Token #{secret}")

      assert agent_case.status == :pending
      assert agent_case.kind == :needs_input
      assert agent_case.gate_module == JidoClaw.Gates.NeedsInputGate
      assert agent_case.step_name == "v-step"
      assert agent_case.workflow_run_id == nil
      # The FK is the Session UUID — never the external session label.
      assert agent_case.session_id == ctx.session.id
      assert agent_case.details["template"] == "coder"
      assert agent_case.details["injectable"] == true
      assert is_binary(agent_case.details["resume_hint"])
      refute agent_case.details["question"] =~ secret
      assert agent_case.details["question"] =~ "[REDACTED:GITHUB_PAT]"

      assert [%AgentCaseEvent{type: :opened}] = case_events!(agent_case, ctx)
    end

    test "a run-bound raise stores the EXTRACTED run id for provenance", ctx do
      run = create_run!(ctx)

      assert {:ok, agent_case} =
               NeedsInput.raise_case(scope(ctx, workflow_run_id: run.id), "Q?")

      assert agent_case.workflow_run_id == run.id
    end

    test "a raise while pending reuses the case — first question wins", ctx do
      assert {:ok, first} = NeedsInput.raise_case(scope(ctx), "Original question?")
      assert {:ok, reused} = NeedsInput.raise_case(scope(ctx), "Rephrased question?")

      assert reused.id == first.id
      assert reused.details["question"] == "Original question?"

      {:ok, cases} =
        AgentCase.by_fingerprint(first.fingerprint, tenant: ctx.tenant_id, actor: ctx.actor)

      assert Enum.count(cases, &(&1.status == :pending)) == 1
    end

    test "session-less falls back to run-scoped identity and marks injectable: false", ctx do
      run = create_run!(ctx)

      run_scoped =
        scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: run.id, vendor?: true)

      assert {:ok, agent_case} = NeedsInput.raise_case(run_scoped, "Q?")

      # Even on a vendor arm: a run-scoped case can't be claimed by a later
      # run, so promising injection would be false.
      assert agent_case.details["injectable"] == false
      assert agent_case.session_id == nil
      assert agent_case.workflow_run_id == run.id
    end

    test "session-less AND run-less refuses to open — no row", ctx do
      floor = scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: nil)

      assert :error = NeedsInput.raise_case(floor, "Q?")
      assert {:ok, []} = AgentCase.pending_for_tenant(tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "a session arm (vendor?: false) marks injectable: false", ctx do
      assert {:ok, agent_case} = NeedsInput.raise_case(scope(ctx, vendor?: false), "Q?")
      assert agent_case.details["injectable"] == false
    end

    test "nil step_name falls back to the template name (stored + fingerprint stable)", ctx do
      assert {:ok, agent_case} = NeedsInput.raise_case(scope(ctx, step_name: nil), "Q?")
      assert agent_case.step_name == "coder"

      # The fingerprint is the same as an explicitly template-named stage.
      assert NeedsInput.fingerprint(scope(ctx, step_name: nil)) ==
               NeedsInput.fingerprint(scope(ctx, step_name: "coder"))
    end

    test "fail-open on missing tenant scope — :error, no rows", ctx do
      assert :error = NeedsInput.raise_case(scope(ctx, tenant_id: nil), "Q?")
      assert {:ok, []} = AgentCase.pending_for_tenant(tenant: ctx.tenant_id, actor: ctx.actor)
    end
  end

  describe "claim_answer/1" do
    test "an approved answer is claimed once (+ :consumed event); the second claim is :none",
         ctx do
      {:ok, agent_case} = NeedsInput.raise_case(scope(ctx), "Which database?")

      assert {:ok, %AgentCase{}} =
               Cases.decide(agent_case.id, :approve, %{decision_comment: "Use postgres"},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert {:ok, "Use postgres"} = NeedsInput.claim_answer(scope(ctx))

      {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert reloaded.consumed_at != nil
      assert Enum.any?(case_events!(reloaded, ctx), &(&1.type == :consumed))

      # Single-use: nothing left to claim.
      assert :none = NeedsInput.claim_answer(scope(ctx))
    end

    test "a pending case is never claimed", ctx do
      {:ok, _pending} = NeedsInput.raise_case(scope(ctx), "Q?")
      assert :none = NeedsInput.claim_answer(scope(ctx))
    end

    test "a rejected case reads :none, is never consumed, and a later ask opens fresh", ctx do
      {:ok, agent_case} = NeedsInput.raise_case(scope(ctx), "Q?")

      assert {:ok, %AgentCase{}} =
               Cases.decide(agent_case.id, :reject, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert :none = NeedsInput.claim_answer(scope(ctx))

      {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert reloaded.consumed_at == nil

      assert {:ok, fresh} = NeedsInput.raise_case(scope(ctx), "Q again?")
      refute fresh.id == agent_case.id
    end

    test "a STALE approved case (decided past the TTL) is :none and left inert", ctx do
      {:ok, agent_case} = NeedsInput.raise_case(scope(ctx), "Q?")

      {:ok, %AgentCase{}} =
        Cases.decide(agent_case.id, :approve, %{decision_comment: "too late"},
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      backdate_decision!(agent_case, 25)

      assert :none = NeedsInput.claim_answer(scope(ctx))

      {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert reloaded.consumed_at == nil
    end

    test "a run-scoped case is claimable within its run but never by a DIFFERENT run", ctx do
      run = create_run!(ctx)
      run_scoped = scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: run.id)

      {:ok, agent_case} = NeedsInput.raise_case(run_scoped, "Q?")

      {:ok, %AgentCase{}} =
        Cases.decide(agent_case.id, :approve, %{decision_comment: "the answer"},
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      other_run = create_run!(ctx)
      assert :none = NeedsInput.claim_answer(%{run_scoped | workflow_run_id: other_run.id})
      assert {:ok, "the answer"} = NeedsInput.claim_answer(run_scoped)
    end

    test "fail-open on missing scope — :none", ctx do
      assert :none = NeedsInput.claim_answer(scope(ctx, tenant_id: nil))

      assert :none =
               NeedsInput.claim_answer(
                 scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: nil)
               )
    end
  end

  describe "Cases.decide/4 kind dispatch (the answer guard)" do
    test "a RUN-LESS needs_input case dispatches by KIND — blank-answer approve refused", ctx do
      {:ok, agent_case} = NeedsInput.raise_case(scope(ctx), "Q?")
      assert agent_case.workflow_run_id == nil

      # The run-less tool-call catch-all would have approved these; the kind
      # branch's answer guard refuses them and the case stays pending.
      for attrs <- [%{}, %{decision_comment: "   "}] do
        assert {:error, :answer_required} =
                 Cases.decide(agent_case.id, :approve, attrs,
                   tenant: ctx.tenant_id,
                   actor: ctx.actor
                 )
      end

      {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert reloaded.status == :pending

      # Reject needs no comment.
      assert {:ok, %AgentCase{status: :rejected}} =
               Cases.decide(agent_case.id, :reject, %{}, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "a RUN-BOUND approve flips the case + timeline event, no WorkflowEvent, run untouched",
         ctx do
      run = create_run!(ctx)

      {:ok, agent_case} =
        NeedsInput.raise_case(scope(ctx, workflow_run_id: run.id), "Q?")

      {:ok, pre_events} = WorkflowEvent.for_run(run.id, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, %AgentCase{status: :approved}} =
               Cases.decide(agent_case.id, :approve, %{decision_comment: "the answer"},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert Enum.any?(case_events!(agent_case, ctx), &(&1.type == :approved))

      # No WorkflowEvent appended; the run's status is untouched (provenance
      # only — the step already errored and rode its own lanes).
      {:ok, post_events} = WorkflowEvent.for_run(run.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert length(post_events) == length(pre_events)

      {:ok, reloaded_run} = WorkflowRun.by_id(run.id, tenant: ctx.tenant_id, actor: ctx.actor)
      assert reloaded_run.status == run.status
    end
  end

  describe "Cases.abandon/3 refusal" do
    test "refuses :needs_input for BOTH run-less and run-bound cases", ctx do
      {:ok, runless} = NeedsInput.raise_case(scope(ctx), "Q?")

      assert {:error, :not_abandonable} =
               Cases.abandon(runless.id, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      run = create_run!(ctx)

      {:ok, runbound} =
        NeedsInput.raise_case(
          scope(ctx, session_uuid: nil, session_id: nil, workflow_run_id: run.id),
          "Q?"
        )

      assert {:error, :not_abandonable} =
               Cases.abandon(runbound.id, %{}, tenant: ctx.tenant_id, actor: ctx.actor)
    end
  end
end
