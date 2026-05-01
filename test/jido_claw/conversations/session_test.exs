defmodule JidoClaw.Conversations.SessionTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.Session
  alias JidoClaw.Workspaces.Workspace

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "start/1" do
    test "creates a session row with last_active_at populated automatically" do
      {:ok, ws} =
        Workspace.register(%{
          tenant_id: "tenant_x",
          path: "/tmp/sessbase-#{System.unique_integer([:positive])}",
          name: "ws"
        })

      now = DateTime.utc_now()

      assert {:ok, session} =
               Session.start(%{
                 workspace_id: ws.id,
                 tenant_id: "tenant_x",
                 kind: :repl,
                 external_id: "sess-abc",
                 started_at: now
               })

      assert session.workspace_id == ws.id
      assert session.tenant_id == "tenant_x"
      assert session.kind == :repl
      assert session.external_id == "sess-abc"
      assert session.last_active_at != nil
      assert session.idle_timeout_seconds == 300
      assert session.next_sequence == 1
    end
  end

  describe "cross-tenant FK invariant (§0.7)" do
    test "rejects a Session whose tenant_id does not match the parent Workspace's tenant_id" do
      {:ok, ws} =
        Workspace.register(%{
          tenant_id: "T2",
          path: "/tmp/cross-tenant-fk-#{System.unique_integer([:positive])}",
          name: "ws"
        })

      assert {:error, error} =
               Session.start(%{
                 workspace_id: ws.id,
                 tenant_id: "T1",
                 kind: :repl,
                 external_id: "x",
                 started_at: DateTime.utc_now()
               })

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "cross-tenant FK mismatch"))
    end

    test "rejects when the parent Workspace does not exist" do
      bogus_uuid = Ecto.UUID.generate()

      assert {:error, error} =
               Session.start(%{
                 workspace_id: bogus_uuid,
                 tenant_id: "T1",
                 kind: :repl,
                 external_id: "x",
                 started_at: DateTime.utc_now()
               })

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "workspace not found"))
    end
  end
end
