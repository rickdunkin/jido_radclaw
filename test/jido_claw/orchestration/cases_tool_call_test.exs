defmodule JidoClaw.Orchestration.CasesToolCallTest do
  @moduledoc """
  The run-less branch of `Cases.decide/4`: approving/rejecting a tool-call case,
  the abandon refusal, the decide idempotency fence, and the full
  request → decide → request loop end-to-end.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ToolApprovals

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "cases-tool-call")
    actor = actor_for(tenant_id)

    scope = %{
      tenant_id: tenant_id,
      session_uuid: session.id,
      session_id: session.external_id,
      actor: actor
    }

    {:ok, tenant_id: tenant_id, actor: actor, scope: scope}
  end

  defp open(ctx, params \\ %{message: "x"}) do
    assert {:pending, agent_case} = ToolApprovals.request(ctx.scope, "git_commit", params)
    agent_case
  end

  defp opts(ctx), do: [tenant: ctx.tenant_id, actor: ctx.actor]

  defp event_types(case_id, ctx) do
    {:ok, events} = AgentCaseEvent.for_case(case_id, tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.map(events, & &1.type)
  end

  describe "run-less decide" do
    test "approving a tool-call case returns the decided AgentCase, not a run", ctx do
      opened = open(ctx)

      assert {:ok, %AgentCase{} = decided} = Cases.decide(opened.id, :approve, %{}, opts(ctx))
      assert decided.status == :approved
      assert decided.workflow_run_id == nil

      # The case timeline carries opened + approved; no run/WorkflowEvent exists.
      assert event_types(opened.id, ctx) == [:opened, :approved]
    end

    test "rejecting a tool-call case returns the decided AgentCase", ctx do
      opened = open(ctx, %{message: "y"})

      assert {:ok, %AgentCase{} = decided} = Cases.decide(opened.id, :reject, %{}, opts(ctx))
      assert decided.status == :rejected
      assert event_types(opened.id, ctx) == [:opened, :rejected]
    end

    test "a sequential duplicate decide loses at the status recheck", ctx do
      opened = open(ctx)
      assert {:ok, %AgentCase{}} = Cases.decide(opened.id, :approve, %{}, opts(ctx))

      # The already-approved case cannot be decided again — the status recheck
      # refuses the sequential duplicate (the concurrent stale-load race is
      # fenced by the FOR UPDATE reload-and-recheck inside the commit).
      assert {:error, _} = Cases.decide(opened.id, :reject, %{}, opts(ctx))

      assert {:ok, %AgentCase{status: :approved}} =
               AgentCase.by_id(opened.id, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "concurrent approve vs reject resolves to exactly one winner + one event", ctx do
      # Race two stale-loaded deciders on one pending case. The FOR UPDATE
      # reload-and-recheck in `commit_tool_call_decision` is the fence: the
      # loser blocks on the row lock, re-reads the winner's status, and rolls
      # back. Loop over fresh cases so the pre-transaction reload (which masks a
      # single race by refusing at the pre-transaction guard) cannot hide it —
      # at least one iteration lands both loads before either transaction.
      #
      # Without the fix the loser overwrites the winner: two {:ok} and a
      # [:opened, :approved, :rejected] timeline. With it, the loser rolls back.
      for _ <- 1..16 do
        opened = open(ctx, %{message: "race-#{System.unique_integer([:positive])}"})

        results =
          [:approve, :reject]
          |> Enum.map(fn decision ->
            Task.async(fn -> Cases.decide(opened.id, decision, %{}, opts(ctx)) end)
          end)
          |> Task.await_many()

        # Exactly one writer wins; the other rolls back on the locked recheck.
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1,
               "expected exactly one {:ok}, got: #{inspect(results)}"

        assert Enum.count(results, &match?({:error, _}, &1)) == 1,
               "expected exactly one {:error}, got: #{inspect(results)}"

        # The persisted row reflects the winner...
        {:ok, decided} = AgentCase.by_id(opened.id, tenant: ctx.tenant_id, actor: ctx.actor)
        assert decided.status in [:approved, :rejected]
        assert decided.status == winning_status(results)

        # ...and exactly one decision event was appended (never both).
        assert event_types(opened.id, ctx) == [:opened, decided.status]
      end
    end
  end

  # The decision matching the task that returned {:ok}; the decisions list and
  # `Task.await_many` results are positionally aligned.
  defp winning_status(results) do
    [:approve, :reject]
    |> Enum.zip(results)
    |> Enum.find_value(fn
      {:approve, {:ok, _}} -> :approved
      {:reject, {:ok, _}} -> :rejected
      _ -> nil
    end)
  end

  describe "workflow-only operations refuse a tool-call case" do
    test "abandon is refused", ctx do
      opened = open(ctx)
      assert {:error, :not_workflow_case} = Cases.abandon(opened.id, %{}, opts(ctx))
    end
  end

  describe "end-to-end ticket loop" do
    test "request → decide approve → request executes once → re-pends", ctx do
      opened = open(ctx)

      assert {:ok, %AgentCase{}} = Cases.decide(opened.id, :approve, %{}, opts(ctx))

      # The retry matches the approved case and consumes it.
      assert {:allowed, consumed} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      assert consumed.id == opened.id

      # Single-use: the next identical request re-pends a fresh case.
      assert {:pending, repended} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      refute repended.id == opened.id
    end

    test "request → decide reject → request is denied once → re-pends", ctx do
      opened = open(ctx, %{message: "z"})

      assert {:ok, %AgentCase{}} = Cases.decide(opened.id, :reject, %{}, opts(ctx))

      assert {:denied, consumed} = ToolApprovals.request(ctx.scope, "git_commit", %{message: "z"})
      assert consumed.id == opened.id

      assert {:pending, repended} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "z"})

      refute repended.id == opened.id
    end
  end
end
