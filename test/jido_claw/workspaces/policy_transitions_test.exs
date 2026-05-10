defmodule JidoClaw.Workspaces.PolicyTransitionsTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Memory.Fact
  alias JidoClaw.Repo
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(tenant_id, label) do
    Workspace.register(
      %{
        path: "/tmp/policy-transitions-#{label}-#{System.unique_integer([:positive])}",
        name: label
      },
      tenant: tenant_id
    )
  end

  defp seed_disabled_fact(tenant_id, workspace) do
    Fact
    |> Ash.Changeset.for_create(
      :record,
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
      tenant: tenant_id
    )
    |> Ash.create(domain: JidoClaw.Memory)
  end

  defp seed_fact_with_status(tenant_id, workspace, status)
       when status in [:pending, :processing, :failed] do
    {:ok, fact} =
      Fact
      |> Ash.Changeset.for_create(
        :record,
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
        tenant: tenant_id
      )
      |> Ash.create(domain: JidoClaw.Memory)

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
      Fact
      |> Ash.Changeset.for_create(
        :record,
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
        tenant: tenant_id
      )
      |> Ash.create(domain: JidoClaw.Memory)

    fact
    |> Ash.Changeset.for_update(
      :transition_embedding_status,
      %{
        embedding: List.duplicate(0.001, 1024),
        embedding_status: :ready
      },
      tenant: tenant_id
    )
    |> Ash.update!()
  end
end
