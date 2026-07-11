defmodule JidoClaw.Orchestration.AgentCaseToolCallTest do
  @moduledoc """
  Resource-level tests for the run-less tool-call `AgentCase` slice:
  create-validation split, single-use/deny-once consume fences, and the
  partial-unique pending-fingerprint index.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Orchestration.AgentCase

  setup do
    tenant_id = seed_tenant("tool-call-case")
    {:ok, tenant_id: tenant_id, actor: actor_for(tenant_id)}
  end

  defp open(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          step_name: "git_commit",
          tool_name: "git_commit",
          fingerprint: "fp-#{System.unique_integer([:positive])}",
          details: %{"tool" => "git_commit"}
        },
        overrides
      )

    AgentCase.open_tool_call(attrs, tenant: ctx.tenant_id, actor: ctx.actor)
  end

  describe "create-validation split" do
    test "the workflow :create action still requires a workflow_run_id", ctx do
      assert {:error, _} =
               AgentCase.create(%{step_name: "gate", kind: :irreversible_write},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )
    end

    test ":open_tool_call needs no run and stamps the tool-call defaults", ctx do
      assert {:ok, agent_case} = open(ctx)

      assert agent_case.workflow_run_id == nil
      assert agent_case.kind == :tool_call
      assert agent_case.gate_module == JidoClaw.Gates.ToolCallGate
      assert agent_case.status == :pending
      assert agent_case.tool_name == "git_commit"
    end

    test ":open_tool_call requires a fingerprint", ctx do
      assert {:error, _} = open(ctx, %{fingerprint: nil})
    end

    test ":open_tool_call requires a tool_name", ctx do
      assert {:error, _} = open(ctx, %{tool_name: nil})
    end
  end

  # NOTE: the single-use / deny-once *race* fence is the producer's FOR UPDATE
  # re-read (tested end-to-end in tool_approvals_test.exs). At the resource
  # level the `:consume`/`:consume_rejection` actions stamp `consumed_at`.
  describe "consume claim stamps" do
    test ":consume stamps consumed_at on an approved case", ctx do
      assert {:ok, agent_case} = open(ctx)

      assert {:ok, approved} =
               AgentCase.approve(agent_case, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, consumed} =
               AgentCase.consume(approved, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert consumed.consumed_at != nil
      assert consumed.status == :approved
    end

    test ":consume_rejection stamps consumed_at on a rejected case", ctx do
      assert {:ok, agent_case} = open(ctx)

      assert {:ok, rejected} =
               AgentCase.reject(agent_case, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, consumed} =
               AgentCase.consume_rejection(rejected, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert consumed.consumed_at != nil
      assert consumed.status == :rejected
    end
  end

  describe "partial-unique pending fingerprint index" do
    test "two pending cases with the same fingerprint collide on the named index", ctx do
      fingerprint = "fp-dup-#{System.unique_integer([:positive])}"

      assert {:ok, _first} = open(ctx, %{fingerprint: fingerprint})

      assert {:error, err} = open(ctx, %{fingerprint: fingerprint})
      assert AshErrors.unique_violation?(err, ["agent_cases_pending_fingerprint_index"])
    end

    test "a non-pending case frees the fingerprint for a fresh pending case", ctx do
      fingerprint = "fp-reuse-#{System.unique_integer([:positive])}"

      assert {:ok, first} = open(ctx, %{fingerprint: fingerprint})
      # Reject the first so it leaves the partial index's WHERE (status='pending').
      assert {:ok, _rejected} =
               AgentCase.reject(first, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      # A new pending case with the same fingerprint is now allowed.
      assert {:ok, _second} = open(ctx, %{fingerprint: fingerprint})
    end
  end

  describe "reads" do
    test "by_fingerprint returns the tenant's cases newest-first", ctx do
      fingerprint = "fp-read-#{System.unique_integer([:positive])}"

      assert {:ok, first} = open(ctx, %{fingerprint: fingerprint})

      assert {:ok, _rejected} =
               AgentCase.reject(first, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, second} = open(ctx, %{fingerprint: fingerprint})

      assert {:ok, [newest | _]} =
               AgentCase.by_fingerprint(fingerprint, tenant: ctx.tenant_id, actor: ctx.actor)

      assert newest.id == second.id
    end

    test "pending_for_session finds only pending tool-call cases for the session", _ctx do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "session-probe")
      actor = actor_for(tenant_id)

      assert {:ok, _open} =
               AgentCase.open_tool_call(
                 %{
                   step_name: "git_commit",
                   tool_name: "git_commit",
                   fingerprint: "fp-sess-#{System.unique_integer([:positive])}",
                   session_id: session.id
                 },
                 tenant: tenant_id,
                 actor: actor
               )

      assert {:ok, [found]} =
               AgentCase.pending_for_session(session.id, tenant: tenant_id, actor: actor)

      assert found.session_id == session.id
    end
  end
end
