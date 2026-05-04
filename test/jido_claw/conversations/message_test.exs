defmodule JidoClaw.Conversations.MessageTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.{Message, Session}
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  defp seed do
    tenant_id = "tenant-#{System.unique_integer([:positive])}"

    {:ok, ws} =
      Workspace.register(%{
        tenant_id: tenant_id,
        path: "/tmp/msgtest-#{System.unique_integer([:positive])}",
        name: "ws"
      })

    {:ok, session} =
      Session.start(%{
        workspace_id: ws.id,
        tenant_id: tenant_id,
        kind: :repl,
        external_id: "sess-#{System.unique_integer([:positive])}",
        started_at: DateTime.utc_now()
      })

    %{tenant_id: tenant_id, workspace: ws, session: session}
  end

  describe ":append" do
    test "writes a row with monotonically allocated sequence" do
      %{session: session, tenant_id: tenant_id} = seed()

      assert {:ok, m1} =
               Message.append(%{
                 session_id: session.id,
                 role: :user,
                 content: "hello"
               })

      assert m1.sequence == 1
      assert m1.tenant_id == tenant_id
      assert m1.role == :user

      assert {:ok, m2} =
               Message.append(%{
                 session_id: session.id,
                 role: :assistant,
                 content: "hi back"
               })

      assert m2.sequence == 2
    end

    test "tenant_id is denormalized from the parent session, not the caller" do
      %{session: session, tenant_id: tenant_id} = seed()

      {:ok, m} =
        Message.append(%{
          session_id: session.id,
          role: :user,
          content: "x"
        })

      assert m.tenant_id == tenant_id
    end

    test "redaction runs on content before persistence" do
      %{session: session} = seed()

      {:ok, m} =
        Message.append(%{
          session_id: session.id,
          role: :user,
          content: "API_KEY=sk-abcdef0123456789abcdef0123456789"
        })

      refute m.content =~ "sk-abcdef0123456789"
    end
  end

  describe "import-hash collision" do
    test "two identical user lines at the same ms produce two rows with different sequences and hashes" do
      %{session: session, tenant_id: tenant_id} = seed()

      ts = DateTime.utc_now()
      hash1 = "h1-#{System.unique_integer([:positive])}"
      hash2 = "h2-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Message.import(%{
                 session_id: session.id,
                 tenant_id: tenant_id,
                 role: :user,
                 sequence: 1,
                 content: "same",
                 inserted_at: ts,
                 import_hash: hash1
               })

      assert {:ok, _} =
               Message.import(%{
                 session_id: session.id,
                 tenant_id: tenant_id,
                 role: :user,
                 sequence: 2,
                 content: "same",
                 inserted_at: ts,
                 import_hash: hash2
               })
    end

    test "import is idempotent on duplicate import_hash" do
      %{session: session, tenant_id: tenant_id} = seed()

      hash = "dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Message.import(%{
          session_id: session.id,
          tenant_id: tenant_id,
          role: :user,
          sequence: 1,
          content: "same",
          inserted_at: DateTime.utc_now(),
          import_hash: hash
        })

      assert {:error, %Ash.Error.Invalid{} = err} =
               Message.import(%{
                 session_id: session.id,
                 tenant_id: tenant_id,
                 role: :user,
                 sequence: 99,
                 content: "again",
                 inserted_at: DateTime.utc_now(),
                 import_hash: hash
               })

      assert inspect(err) =~ "unique_import_hash"
    end
  end

  describe "cross-tenant FK invariant" do
    test "import refuses tenant_id that doesn't match the parent session" do
      %{session: session} = seed()

      assert {:error, %Ash.Error.Invalid{} = err} =
               Message.import(%{
                 session_id: session.id,
                 tenant_id: "OTHER_TENANT",
                 role: :user,
                 sequence: 1,
                 content: "x",
                 inserted_at: DateTime.utc_now(),
                 import_hash: "x-#{System.unique_integer([:positive])}"
               })

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end
  end

  describe ":for_session" do
    test "returns rows ordered by sequence ascending" do
      %{session: session} = seed()

      Message.append!(%{session_id: session.id, role: :user, content: "1"})
      Message.append!(%{session_id: session.id, role: :assistant, content: "2"})
      Message.append!(%{session_id: session.id, role: :user, content: "3"})

      {:ok, rows} = Message.for_session(session.id)
      assert Enum.map(rows, & &1.content) == ["1", "2", "3"]
      assert Enum.map(rows, & &1.sequence) == [1, 2, 3]
    end
  end
end
