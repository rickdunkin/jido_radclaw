defmodule JidoClaw.Orchestration.ToolApprovalsTest do
  @moduledoc """
  The conversation-axis tool-approval producer: ticket lifecycle, single-use
  approvals, deny-once rejections, fingerprint canonicalization, and the
  duplicate-pending / concurrent-claim paths.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ToolApprovals

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-approvals")

    scope = %{
      tenant_id: tenant_id,
      session_uuid: session.id,
      session_id: session.external_id,
      actor: actor_for(tenant_id)
    }

    {:ok, tenant_id: tenant_id, session: session, scope: scope}
  end

  defp approve(agent_case, ctx) do
    {:ok, approved} =
      AgentCase.approve(agent_case, %{}, tenant: ctx.tenant_id, actor: ctx.scope.actor)

    approved
  end

  defp reject(agent_case, ctx) do
    {:ok, rejected} =
      AgentCase.reject(agent_case, %{}, tenant: ctx.tenant_id, actor: ctx.scope.actor)

    rejected
  end

  describe "opening a ticket" do
    test "a first call opens a pending tool-call case", ctx do
      assert {:pending, agent_case} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      assert agent_case.status == :pending
      assert agent_case.kind == :tool_call
      assert agent_case.tool_name == "git_commit"
      assert agent_case.workflow_run_id == nil
      assert agent_case.session_id == ctx.session.id
      assert agent_case.details["tool"] == "git_commit"
    end

    test "a duplicate call while pending reuses the same ticket", ctx do
      assert {:pending, first} = ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})
      assert {:pending, second} = ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      assert first.id == second.id

      # Exactly one pending case exists for the fingerprint.
      assert {:ok, cases} =
               AgentCase.by_fingerprint(first.fingerprint,
                 tenant: ctx.tenant_id,
                 actor: ctx.scope.actor
               )

      assert Enum.count(cases, &(&1.status == :pending)) == 1
    end

    test "no tenant scope is a fail-closed error, not a ticket", ctx do
      scope = Map.delete(ctx.scope, :tenant_id)
      assert {:error, :no_tenant_scope} = ToolApprovals.request(scope, "git_commit", %{})
    end
  end

  describe "single-use approval" do
    test "an approved ticket is consumed once, then the next identical call re-pends", ctx do
      assert {:pending, opened} = ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})
      _approved = approve(opened, ctx)

      # The retry consumes the approval and is allowed exactly once.
      assert {:allowed, consumed} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      assert consumed.id == opened.id
      assert consumed.consumed_at != nil

      # A second identical call cannot reuse the spent approval — it re-pends.
      assert {:pending, repended} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      refute repended.id == opened.id
      assert repended.status == :pending
    end
  end

  describe "deny-once rejection" do
    test "a rejected ticket is consumed once, then the next identical call re-pends", ctx do
      assert {:pending, opened} = ToolApprovals.request(ctx.scope, "network_share", %{host: "h"})
      _rejected = reject(opened, ctx)

      assert {:denied, consumed} = ToolApprovals.request(ctx.scope, "network_share", %{host: "h"})
      assert consumed.id == opened.id
      assert consumed.consumed_at != nil

      assert {:pending, repended} =
               ToolApprovals.request(ctx.scope, "network_share", %{host: "h"})

      refute repended.id == opened.id
      assert repended.status == :pending
    end
  end

  describe "fingerprint canonicalization" do
    test "atom-keyed and string-keyed equivalent params fingerprint identically", ctx do
      atom_fp = ToolApprovals.fingerprint(ctx.scope, "git_commit", %{message: "x", amend: true})

      string_fp =
        ToolApprovals.fingerprint(ctx.scope, "git_commit", %{"message" => "x", "amend" => true})

      assert atom_fp == string_fp
    end

    test "atom and string enum-like values collapse, distinct values do not", ctx do
      atom_fp = ToolApprovals.fingerprint(ctx.scope, "reason", %{strategy: :tot})
      string_fp = ToolApprovals.fingerprint(ctx.scope, "reason", %{"strategy" => "tot"})
      other_fp = ToolApprovals.fingerprint(ctx.scope, "reason", %{strategy: :got})

      assert atom_fp == string_fp
      refute atom_fp == other_fp
    end

    test "nested map key order does not change the fingerprint", ctx do
      a = ToolApprovals.fingerprint(ctx.scope, "t", %{opts: %{a: 1, b: 2}})
      b = ToolApprovals.fingerprint(ctx.scope, "t", %{opts: %{b: 2, a: 1}})
      assert a == b
    end

    test "different tools fingerprint differently", ctx do
      a = ToolApprovals.fingerprint(ctx.scope, "git_commit", %{})
      b = ToolApprovals.fingerprint(ctx.scope, "network_share", %{})
      refute a == b
    end
  end

  describe "template-scoped fingerprint (:v2)" do
    test "distinct templates fingerprint differently and open distinct pending cases", ctx do
      coder = Map.put(ctx.scope, :agent_template, "coder")
      reviewer = Map.put(ctx.scope, :agent_template, "reviewer")

      refute ToolApprovals.fingerprint(coder, "git_commit", %{message: "x"}) ==
               ToolApprovals.fingerprint(reviewer, "git_commit", %{message: "x"})

      assert {:pending, c1} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      assert {:pending, c2} = ToolApprovals.request(reviewer, "git_commit", %{message: "x"})
      refute c1.id == c2.id
    end

    test "the same template collapses identical calls to one fingerprint", ctx do
      coder = Map.put(ctx.scope, :agent_template, "coder")

      assert ToolApprovals.fingerprint(coder, "git_commit", %{message: "x"}) ==
               ToolApprovals.fingerprint(coder, "git_commit", %{message: "x"})

      assert {:pending, first} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      assert {:pending, second} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      assert first.id == second.id
    end

    test "an approval for one template is not reusable by another", ctx do
      coder = Map.put(ctx.scope, :agent_template, "coder")
      reviewer = Map.put(ctx.scope, :agent_template, "reviewer")

      assert {:pending, opened} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      _approved = approve(opened, ctx)

      # The coder's approval is consumed by the coder's retry...
      assert {:allowed, _} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      # ...but the reviewer issuing the identical call still pends (own consent).
      assert {:pending, _} = ToolApprovals.request(reviewer, "git_commit", %{message: "x"})
    end

    test "a non-binary agent_template normalizes to the same hash as nil", ctx do
      nil_fp = ToolApprovals.fingerprint(ctx.scope, "git_commit", %{})
      atom_scope = Map.put(ctx.scope, :agent_template, :coder)

      assert ToolApprovals.fingerprint(atom_scope, "git_commit", %{}) == nil_fp
    end

    test "details carries the agent_template when present", ctx do
      coder = Map.put(ctx.scope, :agent_template, "coder")

      assert {:pending, agent_case} = ToolApprovals.request(coder, "git_commit", %{message: "x"})
      assert agent_case.details["agent_template"] == "coder"
    end

    test "details omits agent_template when absent", ctx do
      assert {:pending, agent_case} =
               ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})

      refute Map.has_key?(agent_case.details, "agent_template")
    end
  end

  describe "concurrent claims" do
    test "an approval is consumed by exactly one of two concurrent retries", ctx do
      assert {:pending, opened} = ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"})
      _approved = approve(opened, ctx)

      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> ToolApprovals.request(ctx.scope, "git_commit", %{message: "x"}) end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:allowed, _}, &1)) == 1
      assert Enum.count(results, &match?({:pending, _}, &1)) == 1
    end

    test "two concurrent first-calls collapse to a single pending ticket", ctx do
      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> ToolApprovals.request(ctx.scope, "kill_agent", %{id: "a"}) end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:pending, _}, &1))

      ids =
        results
        |> Enum.map(fn {:pending, c} -> c.id end)
        |> Enum.uniq()

      assert match?([_], ids)
    end
  end

  describe "details redaction" do
    test "a key-named secret is redacted before the arguments summary", ctx do
      assert {:pending, agent_case} =
               ToolApprovals.request(ctx.scope, "network_share", %{
                 api_key: "no-regex-pattern-here"
               })

      refute inspect(agent_case.details) =~ "no-regex-pattern-here"
    end
  end
end
