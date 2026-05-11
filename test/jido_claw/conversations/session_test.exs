defmodule JidoClaw.Conversations.SessionTest do
  use JidoClaw.TenantCase, async: false

  describe "start/1" do
    test "creates a session row with last_active_at populated automatically" do
      tenant_id = seed_tenant("session-start")
      {:ok, ws} = seed_workspace(tenant_id)

      now = DateTime.utc_now()

      assert {:ok, session} =
               Session.start(
                 %{
                   workspace_id: ws.id,
                   kind: :repl,
                   external_id: "sess-abc",
                   started_at: now
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert session.workspace_id == ws.id
      assert session.tenant_id == tenant_id
      assert session.kind == :repl
      assert session.external_id == "sess-abc"
      assert session.last_active_at != nil
      assert session.idle_timeout_seconds == 300
      assert session.next_sequence == 1
    end
  end

  describe "cross-tenant FK invariant (§0.7)" do
    test "rejects a Session whose tenant_id does not match the parent Workspace's tenant_id" do
      parent_tenant = seed_tenant("parent")
      other_tenant = seed_tenant("other")

      {:ok, ws} = seed_workspace(parent_tenant)

      assert {:error, error} =
               Session.start(
                 %{
                   workspace_id: ws.id,
                   kind: :repl,
                   external_id: "x",
                   started_at: DateTime.utc_now()
                 },
                 tenant: other_tenant,
                 actor: actor_for(other_tenant)
               )

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "cross_tenant_fk_mismatch"))
    end

    test "rejects when the parent Workspace does not exist" do
      tenant_id = seed_tenant("missing-ws")
      bogus_uuid = Ecto.UUID.generate()

      assert {:error, error} =
               Session.start(
                 %{
                   workspace_id: bogus_uuid,
                   kind: :repl,
                   external_id: "x",
                   started_at: DateTime.utc_now()
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "workspace_not_found"))
    end
  end
end
