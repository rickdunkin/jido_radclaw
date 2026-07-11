defmodule JidoClaw.Conversations.MessageTest do
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Conversations.Message

  defp seed do
    seed_full(
      tenant_label: "msg",
      session: [kind: :repl, external_id: "sess-#{System.unique_integer([:positive])}"]
    )
  end

  describe ":append" do
    test "writes a row with monotonically allocated sequence" do
      %{session: session, tenant_id: tenant_id} = seed()

      assert {:ok, m1} =
               Message.append(
                 %{
                   session_id: session.id,
                   role: :user,
                   content: "hello"
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert m1.sequence == 1
      assert m1.tenant_id == tenant_id
      assert m1.role == :user

      assert {:ok, m2} =
               Message.append(
                 %{
                   session_id: session.id,
                   role: :assistant,
                   content: "hi back"
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert m2.sequence == 2
    end

    test "tenant_id is denormalized from the parent session, not the caller" do
      %{session: session, tenant_id: tenant_id} = seed()

      {:ok, m} =
        Message.append(
          %{
            session_id: session.id,
            role: :user,
            content: "x"
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert m.tenant_id == tenant_id
    end

    test "redaction runs on content before persistence" do
      %{session: session, tenant_id: tenant_id} = seed()

      {:ok, m} =
        Message.append(
          %{
            session_id: session.id,
            role: :user,
            content: "API_KEY=sk-abcdef0123456789abcdef0123456789"
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

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
               Message.import(
                 %{
                   session_id: session.id,
                   role: :user,
                   sequence: 1,
                   content: "same",
                   inserted_at: ts,
                   import_hash: hash1
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert {:ok, _} =
               Message.import(
                 %{
                   session_id: session.id,
                   role: :user,
                   sequence: 2,
                   content: "same",
                   inserted_at: ts,
                   import_hash: hash2
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )
    end

    test "import is idempotent on duplicate import_hash" do
      %{session: session, tenant_id: tenant_id} = seed()

      hash = "dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Message.import(
          %{
            session_id: session.id,
            role: :user,
            sequence: 1,
            content: "same",
            inserted_at: DateTime.utc_now(),
            import_hash: hash
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:error, %Ash.Error.Invalid{} = err} =
               Message.import(
                 %{
                   session_id: session.id,
                   role: :user,
                   sequence: 99,
                   content: "again",
                   inserted_at: DateTime.utc_now(),
                   import_hash: hash
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert inspect(err) =~ "unique_import_hash"
    end
  end

  describe ":import redaction" do
    test "redacts content and metadata at the storage boundary (persisted row, not just the return)" do
      %{session: session, tenant_id: tenant_id} = seed()

      raw_key = "sk-abcdef0123456789abcdef0123456789"

      {:ok, imported} =
        Message.import(
          %{
            session_id: session.id,
            role: :user,
            sequence: 1,
            content: "legacy line with #{raw_key} inline",
            metadata: %{"api_key" => raw_key},
            inserted_at: DateTime.utc_now(),
            import_hash: "redact-#{System.unique_integer([:positive])}"
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      # Re-read from Postgres — pins the persisted state, not the
      # in-memory changeset result.
      {:ok, [row]} =
        Message.for_session(session.id, tenant: tenant_id, actor: actor_for(tenant_id))

      assert row.id == imported.id
      assert row.content =~ "[REDACTED:API_KEY]"
      refute row.content =~ raw_key
      assert row.metadata["api_key"] == "[REDACTED]"
    end
  end

  describe "cross-tenant FK invariant" do
    test "import refuses tenant_id that doesn't match the parent session" do
      %{session: session} = seed()

      # Ensure the unrelated tenant exists so the FK validation hook
      # actually fires the cross_tenant_fk_mismatch branch (vs. a
      # missing-parent error for the audit row).
      other_tenant = seed_tenant("other")

      assert {:error, %Ash.Error.Invalid{} = err} =
               Message.import(
                 %{
                   session_id: session.id,
                   role: :user,
                   sequence: 1,
                   content: "x",
                   inserted_at: DateTime.utc_now(),
                   import_hash: "x-#{System.unique_integer([:positive])}"
                 },
                 tenant: other_tenant,
                 actor: actor_for(other_tenant)
               )

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end
  end

  describe ":for_session" do
    test "returns rows ordered by sequence ascending" do
      %{session: session, tenant_id: tenant_id} = seed()

      Message.append!(%{session_id: session.id, role: :user, content: "1"},
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

      Message.append!(%{session_id: session.id, role: :assistant, content: "2"},
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

      Message.append!(%{session_id: session.id, role: :user, content: "3"},
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

      {:ok, rows} =
        Message.for_session(session.id, tenant: tenant_id, actor: actor_for(tenant_id))

      assert Enum.map(rows, & &1.content) == ["1", "2", "3"]
      assert Enum.map(rows, & &1.sequence) == [1, 2, 3]
    end
  end
end
