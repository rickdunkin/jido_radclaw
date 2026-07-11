defmodule JidoClaw.V064CrossTenantTest do
  @moduledoc """
  Pins the raw-SQL tenant boundary for the two hybrid retrieval modules
  that bypass Ash's tenant filter (`Memory.HybridSearchSql` and
  `Solutions.HybridSearchSql`). Both apply `tenant_id = $X` in every CTE
  and call `Map.fetch!(args, :tenant_id)` so a missing key raises loudly
  rather than silently dropping the predicate.

  Cases:

    * Memory.Retrieval.search/1 under tenant A never returns a Fact
      written under tenant B.
    * Memory.Retrieval recency variant (empty query) never returns a
      Fact written under another tenant.
    * Solutions.Matcher.find_solutions/2 under tenant A never returns a
      Solution written under tenant B.
    * Negative test: dropping `:tenant_id` from the args raises
      `KeyError` (the fail-loud contract).
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Memory
  alias JidoClaw.Memory.HybridSearchSql, as: MemoryHybridSearchSql
  alias JidoClaw.Solutions.HybridSearchSql, as: SolutionsHybridSearchSql
  alias JidoClaw.Solutions.Matcher
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Workspaces.Workspace

  defp seed_tenant_with_workspace(label) do
    tenant_id = seed_tenant(label)

    {:ok, ws} =
      Workspace.register(
        %{
          path: "/tmp/#{label}-#{System.unique_integer([:positive])}",
          name: "ws-#{label}-#{System.unique_integer([:positive])}",
          embedding_policy: :disabled
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    {tenant_id, ws}
  end

  describe "Memory hybrid search isolation" do
    test "search/1 under tenant A never returns Facts written under tenant B" do
      {tenant_a, ws_a} = seed_tenant_with_workspace("memory-iso-a")
      {tenant_b, ws_b} = seed_tenant_with_workspace("memory-iso-b")

      ctx_a = %{tenant_id: tenant_a, workspace_uuid: ws_a.id}
      ctx_b = %{tenant_id: tenant_b, workspace_uuid: ws_b.id}

      :ok =
        Memory.remember_from_user(
          %{key: "shared-label", content: "tenant_a-secret", type: "fact"},
          ctx_a
        )

      :ok =
        Memory.remember_from_user(
          %{key: "shared-label", content: "tenant_b-secret", type: "fact"},
          ctx_b
        )

      results = Memory.recall("secret", tool_context: ctx_a, limit: 50)

      refute Enum.any?(results, fn entry ->
               String.contains?(to_string(entry.content), "tenant_b")
             end),
             "tenant A search returned a row from tenant B"

      assert Enum.any?(results, fn entry ->
               String.contains?(to_string(entry.content), "tenant_a")
             end)
    end

    test "recency variant never returns Facts written under another tenant" do
      {tenant_a, ws_a} = seed_tenant_with_workspace("memory-rec-a")
      {tenant_b, ws_b} = seed_tenant_with_workspace("memory-rec-b")

      ctx_a = %{tenant_id: tenant_a, workspace_uuid: ws_a.id}
      ctx_b = %{tenant_id: tenant_b, workspace_uuid: ws_b.id}

      :ok =
        Memory.remember_from_user(
          %{key: "lab-a", content: "alpha", type: "fact"},
          ctx_a
        )

      :ok =
        Memory.remember_from_user(
          %{key: "lab-b", content: "beta", type: "fact"},
          ctx_b
        )

      # Empty query forces the recency path through HybridSearchSql.run_recency/1.
      results = Memory.recall("", tool_context: ctx_a, limit: 50)

      refute Enum.any?(results, fn entry ->
               String.contains?(to_string(entry.content), "beta")
             end)

      assert Enum.any?(results, fn entry ->
               String.contains?(to_string(entry.content), "alpha")
             end)
    end

    test "Map.fetch!/2 raises when :tenant_id is dropped from run/1 args" do
      args = %{
        scope_chain: [{:workspace, Ecto.UUID.generate()}],
        query: "anything"
      }

      assert_raise KeyError, fn -> MemoryHybridSearchSql.run(args) end
    end

    test "Map.fetch!/2 raises when :tenant_id is dropped from run_recency/1 args" do
      args = %{
        scope_chain: [{:workspace, Ecto.UUID.generate()}]
      }

      assert_raise KeyError, fn -> MemoryHybridSearchSql.run_recency(args) end
    end
  end

  describe "Solutions hybrid search isolation" do
    test "Matcher.find_solutions/2 under tenant A never returns Solutions from tenant B" do
      {tenant_a, ws_a} = seed_tenant_with_workspace("solutions-iso-a")
      {tenant_b, ws_b} = seed_tenant_with_workspace("solutions-iso-b")

      sig_a = "sig-a-#{System.unique_integer([:positive])}"
      sig_b = "sig-b-#{System.unique_integer([:positive])}"

      {:ok, _sol_a} =
        Solution.store(
          %{
            problem_signature: sig_a,
            solution_content: "tenant_a payload with retry idempotent xyzzy",
            language: "elixir",
            sharing: :local,
            workspace_id: ws_a.id,
            embedding_status: :disabled,
            tags: []
          },
          tenant: tenant_a,
          actor: actor_for(tenant_a)
        )

      {:ok, _sol_b} =
        Solution.store(
          %{
            problem_signature: sig_b,
            solution_content: "tenant_b payload with retry idempotent xyzzy",
            language: "elixir",
            sharing: :local,
            workspace_id: ws_b.id,
            embedding_status: :disabled,
            tags: []
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      results =
        Matcher.find_solutions(
          "retry idempotent xyzzy",
          tenant_id: tenant_a,
          workspace_id: ws_a.id,
          threshold: 0.0,
          limit: 50
        )

      refute Enum.any?(results, fn entry ->
               String.contains?(entry.solution.solution_content, "tenant_b")
             end),
             "tenant A search returned a row from tenant B"
    end

    test "Map.fetch!/2 raises when :tenant_id is dropped from run/1 args" do
      args = %{
        query: "anything",
        workspace_id: Ecto.UUID.generate()
      }

      assert_raise KeyError, fn -> SolutionsHybridSearchSql.run(args) end
    end
  end
end
