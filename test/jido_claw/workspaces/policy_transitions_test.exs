defmodule JidoClaw.Workspaces.PolicyTransitionsTest do
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Memory.Fact
  alias JidoClaw.Repo
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Workspaces.PolicyTransitions

  setup do
    %{tenant_id: seed_tenant("policy-transitions")}
  end

  describe "apply_embedding/3 — memory_facts coverage" do
    test ":default flips memory_facts :disabled rows to :pending alongside solutions", %{
      tenant_id: tenant_id
    } do
      {:ok, ws} = ws(tenant_id, "default-flip")
      {:ok, fact} = seed_disabled_fact(tenant_id, ws)
      assert fact.embedding_status == :disabled

      :ok = PolicyTransitions.apply_embedding(ws.id, :default)

      {:ok, reloaded} = Fact.by_id_global(fact.id)
      assert reloaded.embedding_status == :pending
    end

    test ":disabled flips memory_facts :pending|:processing|:failed back to :disabled", %{
      tenant_id: tenant_id
    } do
      {:ok, ws} = ws(tenant_id, "disable-active")

      pending = seed_fact_with_status(tenant_id, ws, :pending)
      processing = seed_fact_with_status(tenant_id, ws, :processing)
      failed = seed_fact_with_status(tenant_id, ws, :failed)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)

      Enum.each([pending, processing, failed], fn fact ->
        {:ok, reloaded} = Fact.by_id_global(fact.id)
        assert reloaded.embedding_status == :disabled
        assert reloaded.embedding_attempt_count == 0
        assert is_nil(reloaded.embedding_next_attempt_at)
        assert is_nil(reloaded.embedding_last_error)
      end)
    end

    test ":disabled with purge_existing: true clears :ready memory_fact embeddings", %{
      tenant_id: tenant_id
    } do
      {:ok, ws} = ws(tenant_id, "disable-purge")
      ready_fact = seed_ready_fact(tenant_id, ws)

      assert ready_fact.embedding_status == :ready
      refute is_nil(ready_fact.embedding)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled, purge_existing: true)

      {:ok, reloaded} = Fact.by_id_global(ready_fact.id)
      assert reloaded.embedding_status == :disabled
      assert is_nil(reloaded.embedding)
    end

    test ":disabled WITHOUT purge_existing leaves :ready memory_fact embeddings intact", %{
      tenant_id: tenant_id
    } do
      {:ok, ws} = ws(tenant_id, "disable-keep-ready")
      ready_fact = seed_ready_fact(tenant_id, ws)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)

      {:ok, reloaded} = Fact.by_id_global(ready_fact.id)
      assert reloaded.embedding_status == :ready
      refute is_nil(reloaded.embedding)
    end
  end

  describe "apply_embedding/3 — solutions coverage and full state machine" do
    test "embedding policy transitions fix up solution row status across the full state machine",
         %{tenant_id: tenant_id} do
      {:ok, ws} = ws(tenant_id, "sol-policy-flip", embedding_policy: :disabled)
      actor = actor_for(tenant_id)

      # 1. With :disabled, stored solutions get :disabled status.
      sols = for i <- 1..3, do: seed_solution(ws, tenant_id, "problem #{i}")
      Enum.each(sols, fn s -> assert s.embedding_status == :disabled end)

      # 2. Flip to :default — all three rows go to :pending, error fields cleared.
      :ok = PolicyTransitions.apply_embedding(ws.id, :default)

      for s <- reload_solutions(sols, tenant_id, actor) do
        assert s.embedding_status == :pending
        assert s.embedding_attempt_count == 0
        assert s.embedding_last_error == nil
      end

      # 3. Simulate backfill completion via direct SQL (backfill worker
      # is out of scope for this state-machine test).
      Enum.each(sols, &mark_solution_embedding_ready(&1, tenant_id))

      Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
        assert s.embedding_status == :ready
        refute is_nil(s.embedding)
      end)

      # 4. Flip back to :disabled WITHOUT purge_existing — :ready rows
      # keep their embedding (and stay :ready).
      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)

      Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
        assert s.embedding_status == :ready
        refute is_nil(s.embedding)
      end)

      # 5. Flip with purge_existing — rows go :disabled, embedding NULL.
      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled, purge_existing: true)

      Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
        assert s.embedding_status == :disabled
        assert is_nil(s.embedding)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(tenant_id, label, opts \\ []) do
    attrs =
      maybe_put(
        %{
          path: "/tmp/policy-transitions-#{label}-#{System.unique_integer([:positive])}",
          name: label
        },
        opts,
        :embedding_policy
      )

    Workspace.register(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
  end

  defp maybe_put(attrs, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  defp seed_solution(workspace, tenant_id, content) do
    hash = :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}-#{content}")
    sig = Base.encode16(hash, case: :lower)

    {:ok, sol} =
      Solution.store(
        %{
          problem_signature: sig,
          solution_content: content,
          language: "elixir",
          sharing: :local,
          workspace_id: workspace.id,
          embedding_status: :disabled
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    sol
  end

  defp reload_solutions(sols, tenant_id, actor) do
    Enum.map(sols, fn s ->
      {:ok, reloaded} = Solution.by_id(s.id, tenant: tenant_id, actor: actor)
      reloaded
    end)
  end

  defp mark_solution_embedding_ready(sol, tenant_id) do
    sol
    |> Ash.Changeset.for_update(
      :transition_embedding_status,
      %{
        embedding: List.duplicate(0.001, 1024),
        embedding_status: :ready,
        embedding_attempt_count: 0,
        embedding_next_attempt_at: nil,
        embedding_last_error: nil
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )
    |> Ash.update!()
  end

  defp seed_disabled_fact(tenant_id, workspace) do
    Fact.record(
      %{
        scope_kind: :workspace,
        workspace_id: workspace.id,
        label: "policy-#{System.unique_integer([:positive])}",
        content: "disabled-row",
        tags: ["fact"],
        source: :user_save,
        trust_score: 0.5,
        embedding_status: :disabled
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )
  end

  defp seed_fact_with_status(tenant_id, workspace, status)
       when status in [:pending, :processing, :failed] do
    {:ok, fact} =
      Fact.record(
        %{
          scope_kind: :workspace,
          workspace_id: workspace.id,
          label: "policy-#{status}-#{System.unique_integer([:positive])}",
          content: "row-with-status-#{status}",
          tags: ["fact"],
          source: :user_save,
          trust_score: 0.5,
          embedding_status: :pending
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    # Drive the row into the target status via direct UPDATE so we
    # cover the :processing / :failed branches the action layer
    # doesn't expose as an initial-create option.
    Repo.query!(
      "UPDATE memory_facts SET embedding_status = $2 WHERE id = $1",
      [Ecto.UUID.dump!(fact.id), Atom.to_string(status)]
    )

    {:ok, reloaded} = Fact.by_id_global(fact.id)
    reloaded
  end

  defp seed_ready_fact(tenant_id, workspace) do
    {:ok, fact} =
      Fact.record(
        %{
          scope_kind: :workspace,
          workspace_id: workspace.id,
          label: "ready-#{System.unique_integer([:positive])}",
          content: "ready-row",
          tags: ["fact"],
          source: :user_save,
          trust_score: 0.5,
          embedding_status: :pending
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    Fact.transition_embedding_status!(
      fact,
      %{
        embedding: List.duplicate(0.001, 1024),
        embedding_status: :ready
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )
  end
end
