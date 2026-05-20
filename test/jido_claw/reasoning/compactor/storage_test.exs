defmodule JidoClaw.Reasoning.Compactor.StorageTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: SessionResource
  alias JidoClaw.Reasoning.Compactor.{Snapshot, Storage}

  defp setup_session(label) do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: label)
    {tenant_id, session, actor_for(tenant_id)}
  end

  defp sample_snapshot(session_id, tenant_id) do
    %Snapshot{
      id: "cpct_#{System.unique_integer([:positive])}",
      session_id: session_id,
      tenant_id: tenant_id,
      agent_id: "main",
      status: :summarized,
      strategy: :summary,
      summary: "Roundtrip summary",
      summary_preview: "Roundtrip summary",
      source_message_count: 8,
      retained_message_count: 4,
      protected_message_count: 2,
      protected_turn_count: 1,
      last_summarized_sequence: 17,
      summarized_request_ids: ["r1", "r2"],
      last_summarized_request_id: "r2",
      last_summarized_at_ms: 1_700_000_000_000,
      started_at_ms: 1_700_000_000_000,
      completed_at_ms: 1_700_000_001_000,
      metadata: %{}
    }
  end

  describe "persist/3 + latest/2" do
    test "round-trips a snapshot through Postgres JSONB" do
      {tenant_id, session, actor} = setup_session("rt")
      snap = sample_snapshot(session.id, tenant_id)

      assert {:ok, ^snap} = Storage.persist(session.id, snap, tenant: tenant_id, actor: actor)

      assert {:ok, %Snapshot{} = restored} =
               Storage.latest(session.id, tenant: tenant_id, actor: actor)

      assert restored.id == snap.id
      assert restored.summary == snap.summary
      assert restored.summarized_request_ids == snap.summarized_request_ids
      assert restored.status == :summarized
    end

    test "latest/2 returns nil when no snapshot has been persisted" do
      {tenant_id, session, actor} = setup_session("nil")
      assert {:ok, nil} = Storage.latest(session.id, tenant: tenant_id, actor: actor)
    end
  end

  describe "tenant isolation" do
    test "tenant A's snapshot is invisible to tenant B" do
      {tenant_a, session_a, actor_a} = setup_session("a")
      {tenant_b, _session_b, actor_b} = setup_session("b")

      snap = sample_snapshot(session_a.id, tenant_a)
      {:ok, _} = Storage.persist(session_a.id, snap, tenant: tenant_a, actor: actor_a)

      assert {:ok, %Snapshot{}} =
               Storage.latest(session_a.id, tenant: tenant_a, actor: actor_a)

      assert {:error, _} = Storage.latest(session_a.id, tenant: tenant_b, actor: actor_b)
    end
  end

  describe "error paths" do
    test "missing session returns an error" do
      tenant_id = seed_tenant("missing")

      assert {:error, _} =
               Storage.latest(Ecto.UUID.generate(),
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )
    end
  end

  describe "Session.set_compaction_snapshot direct" do
    test "writes to Session.metadata['compaction'] as JSONB-shaped map" do
      {tenant_id, session, actor} = setup_session("direct")
      payload = %{"id" => "x", "status" => "summarized"}

      assert {:ok, _updated} =
               SessionResource.set_compaction_snapshot(session, payload,
                 tenant: tenant_id,
                 actor: actor
               )

      assert {:ok, reloaded} = SessionResource.by_id(session.id, tenant: tenant_id, actor: actor)
      assert reloaded.metadata["compaction"] == payload
    end
  end
end
