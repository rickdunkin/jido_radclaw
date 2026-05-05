defmodule JidoClaw.Memory.FactTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Memory
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

    {:ok, ws} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/fact_test_#{System.unique_integer([:positive])}",
        []
      )

    tool_context = %{
      tenant_id: "default",
      user_id: nil,
      workspace_uuid: ws.id,
      session_uuid: nil
    }

    {:ok, tool_context: tool_context, workspace: ws}
  end

  describe ":record" do
    test "writes a Fact at the resolved scope", %{tool_context: tc, workspace: ws} do
      :ok =
        Memory.remember_from_user(
          %{key: "label_a", content: "value_a", type: "fact"},
          tc
        )

      [fact] = Ash.read!(Fact)
      assert fact.tenant_id == "default"
      assert fact.scope_kind == :workspace
      assert fact.workspace_id == ws.id
      assert fact.label == "label_a"
      assert fact.content == "value_a"
      assert fact.tags == ["fact"]
      assert fact.source == :user_save
      assert fact.invalid_at == nil
      assert fact.expired_at == nil
    end

    test "second write at same label invalidates the prior", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "L", content: "v1", type: "fact"}, tc)
      :ok = Memory.remember_from_user(%{key: "L", content: "v2", type: "fact"}, tc)

      facts = Ash.read!(Fact) |> Enum.sort_by(& &1.inserted_at)
      assert length(facts) == 2

      [old, new] = facts
      assert old.content == "v1"
      assert old.invalid_at != nil
      assert old.expired_at != nil

      assert new.content == "v2"
      assert new.invalid_at == nil
    end

    test "active label uniqueness — concurrent writes collide", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "L", content: "v1", type: "fact"}, tc)

      [fact] = Ash.read!(Fact)
      assert fact.invalid_at == nil
    end
  end

  describe "content_hash + search_vector generated columns" do
    test "content_hash is populated by Postgres digest()", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "h", content: "hash me", type: "fact"}, tc)

      %Postgrex.Result{rows: [[hash]]} =
        JidoClaw.Repo.query!("SELECT content_hash FROM memory_facts WHERE label = 'h'")

      expected = :crypto.hash(:sha256, "hash me")
      assert hash == expected
    end

    test "search_vector is populated for label, content, and tags", %{tool_context: tc} do
      :ok =
        Memory.remember_from_user(
          %{key: "fts_label", content: "elixir is functional", type: "preference"},
          tc
        )

      %Postgrex.Result{rows: [[matched]]} =
        JidoClaw.Repo.query!(
          "SELECT count(*)::int FROM memory_facts " <>
            "WHERE search_vector @@ websearch_to_tsquery('english', 'elixir')"
        )

      assert matched >= 1
    end
  end

  describe "substring-superset regression (plan §3.19)" do
    test "recall finds api_base_url, preferred_style, foo.bar.baz", %{tool_context: tc} do
      :ok =
        Memory.remember_from_user(
          %{key: "api_base_url", content: "https://api.example.com", type: "fact"},
          tc
        )

      :ok =
        Memory.remember_from_user(
          %{key: "preferred_style", content: "snake_case", type: "preference"},
          tc
        )

      :ok = Memory.remember_from_user(%{key: "foo.bar.baz", content: "nested", type: "fact"}, tc)

      r1 = Memory.recall("api", tool_context: tc, limit: 5)
      assert Enum.any?(r1, fn m -> m.key == "api_base_url" end)

      r2 = Memory.recall("preference", tool_context: tc, limit: 5)
      assert Enum.any?(r2, fn m -> m.key == "preferred_style" end)

      r3 = Memory.recall("foo.bar", tool_context: tc, limit: 5)
      assert Enum.any?(r3, fn m -> m.key == "foo.bar.baz" end)
    end
  end

  describe "forget" do
    test "user_save forget invalidates the user-saved row", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "del", content: "v", type: "fact"}, tc)

      :ok = Memory.forget("del", tool_context: tc, source: :user_save)

      after_forget = Memory.recall("del", tool_context: tc, limit: 5)
      refute Enum.any?(after_forget, fn m -> m.key == "del" end)
    end

    test "model-source forget does not touch user-saved rows", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "shared", content: "user", type: "fact"}, tc)

      :ok = Memory.forget("shared", tool_context: tc, source: :model_remember)

      survivors = Ash.read!(Fact)
      assert Enum.any?(survivors, fn f -> f.label == "shared" and is_nil(f.invalid_at) end)
    end
  end

  describe "cross-tenant FK validation" do
    test "rejects a workspace_id pointing at a different tenant", %{workspace: ws} do
      attrs = %{
        tenant_id: "other_tenant",
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "x",
        content: "y",
        tags: [],
        source: :user_save,
        trust_score: 0.7
      }

      assert {:error, %Ash.Error.Invalid{} = err} = Fact.record(attrs)
      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end
  end
end
