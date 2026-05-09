defmodule JidoClaw.Workspaces.PolicyTransitionsTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Memory.Fact
  alias JidoClaw.Repo
  alias JidoClaw.Workspaces.{PolicyTransitions, Workspace}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "apply_embedding/3 — memory_facts coverage" do
    test ":default flips memory_facts :disabled rows to :pending alongside solutions" do
      {:ok, ws} = ws("default-flip")
      {:ok, fact} = seed_disabled_fact(ws)
      assert fact.embedding_status == :disabled

      :ok = PolicyTransitions.apply_embedding(ws.id, :default)

      reloaded = Ash.get!(Fact, fact.id)
      assert reloaded.embedding_status == :pending
    end

    test ":disabled flips memory_facts :pending|:processing|:failed back to :disabled" do
      {:ok, ws} = ws("disable-active")

      pending = seed_fact_with_status(ws, :pending)
      processing = seed_fact_with_status(ws, :processing)
      failed = seed_fact_with_status(ws, :failed)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)

      Enum.each([pending, processing, failed], fn fact ->
        reloaded = Ash.get!(Fact, fact.id)
        assert reloaded.embedding_status == :disabled
        assert reloaded.embedding_attempt_count == 0
        assert is_nil(reloaded.embedding_next_attempt_at)
        assert is_nil(reloaded.embedding_last_error)
      end)
    end

    test ":disabled with purge_existing: true clears :ready memory_fact embeddings" do
      {:ok, ws} = ws("disable-purge")
      ready_fact = seed_ready_fact(ws)

      assert ready_fact.embedding_status == :ready
      refute is_nil(ready_fact.embedding)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled, purge_existing: true)

      reloaded = Ash.get!(Fact, ready_fact.id)
      assert reloaded.embedding_status == :disabled
      assert is_nil(reloaded.embedding)
    end

    test ":disabled WITHOUT purge_existing leaves :ready memory_fact embeddings intact" do
      {:ok, ws} = ws("disable-keep-ready")
      ready_fact = seed_ready_fact(ws)

      :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)

      reloaded = Ash.get!(Fact, ready_fact.id)
      assert reloaded.embedding_status == :ready
      refute is_nil(reloaded.embedding)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(label) do
    Workspace.register(%{
      tenant_id: "default",
      path: "/tmp/policy-transitions-#{label}-#{System.unique_integer([:positive])}",
      name: label
    })
  end

  defp seed_disabled_fact(workspace) do
    Fact
    |> Ash.Changeset.for_create(:record, %{
      tenant_id: workspace.tenant_id,
      scope_kind: :workspace,
      workspace_id: workspace.id,
      label: "policy-#{System.unique_integer([:positive])}",
      content: "disabled-row",
      tags: ["fact"],
      source: :user_save,
      trust_score: 0.5,
      embedding_status: :disabled
    })
    |> Ash.create(domain: JidoClaw.Memory)
  end

  defp seed_fact_with_status(workspace, status) when status in [:pending, :processing, :failed] do
    {:ok, fact} =
      Fact
      |> Ash.Changeset.for_create(:record, %{
        tenant_id: workspace.tenant_id,
        scope_kind: :workspace,
        workspace_id: workspace.id,
        label: "policy-#{status}-#{System.unique_integer([:positive])}",
        content: "row-with-status-#{status}",
        tags: ["fact"],
        source: :user_save,
        trust_score: 0.5,
        embedding_status: :pending
      })
      |> Ash.create(domain: JidoClaw.Memory)

    # Drive the row into the target status via direct UPDATE so we
    # cover the :processing / :failed branches the action layer
    # doesn't expose as an initial-create option.
    Repo.query!(
      "UPDATE memory_facts SET embedding_status = $2 WHERE id = $1",
      [Ecto.UUID.dump!(fact.id), Atom.to_string(status)]
    )

    Ash.get!(Fact, fact.id)
  end

  defp seed_ready_fact(workspace) do
    {:ok, fact} =
      Fact
      |> Ash.Changeset.for_create(:record, %{
        tenant_id: workspace.tenant_id,
        scope_kind: :workspace,
        workspace_id: workspace.id,
        label: "ready-#{System.unique_integer([:positive])}",
        content: "ready-row",
        tags: ["fact"],
        source: :user_save,
        trust_score: 0.5,
        embedding_status: :pending
      })
      |> Ash.create(domain: JidoClaw.Memory)

    fact
    |> Ash.Changeset.for_update(:transition_embedding_status, %{
      embedding: List.duplicate(0.001, 1024),
      embedding_status: :ready
    })
    |> Ash.update!()
  end
end
