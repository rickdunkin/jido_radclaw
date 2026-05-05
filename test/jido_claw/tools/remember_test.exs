defmodule JidoClaw.Tools.RememberTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.Remember
  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

    {:ok, ws} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/remember_test_#{System.unique_integer([:positive])}",
        []
      )

    tool_context = %{
      tenant_id: "default",
      user_id: nil,
      workspace_uuid: ws.id,
      session_uuid: nil
    }

    {:ok, tool_context: tool_context, workspace_id: ws.id}
  end

  describe "run/2 success" do
    test "returns {:ok, result} with the stored key", %{tool_context: tc} do
      assert {:ok, result} =
               Remember.run(
                 %{key: "my_key", content: "some content"},
                 %{tool_context: tc}
               )

      assert result.key == "my_key"
    end

    test "returns status 'remembered'", %{tool_context: tc} do
      assert {:ok, result} =
               Remember.run(
                 %{key: "any_key", content: "value"},
                 %{tool_context: tc}
               )

      assert result.status == "remembered"
    end

    test "defaults type to 'fact' when not provided", %{tool_context: tc} do
      assert {:ok, result} =
               Remember.run(
                 %{key: "fact_key", content: "a fact"},
                 %{tool_context: tc}
               )

      assert result.type == "fact"
    end

    test "uses custom type when provided", %{tool_context: tc} do
      assert {:ok, result} =
               Remember.run(
                 %{key: "arch_key", content: "use GenServer", type: "decision"},
                 %{tool_context: tc}
               )

      assert result.type == "decision"
    end

    test "persists memory so it can be recalled", %{tool_context: tc} do
      Remember.run(%{key: "persisted_key", content: "persisted content"}, %{tool_context: tc})

      results = JidoClaw.Memory.recall("persisted_key", tool_context: tc)
      assert length(results) > 0
      entry = Enum.find(results, &(&1.key == "persisted_key"))
      assert entry != nil
      assert entry.content == "persisted content"
    end

    test "second remember at same key invalidates the prior and returns the new one", %{
      tool_context: tc
    } do
      Remember.run(%{key: "dup_key", content: "original"}, %{tool_context: tc})
      Remember.run(%{key: "dup_key", content: "updated"}, %{tool_context: tc})

      results = JidoClaw.Memory.recall("dup_key", tool_context: tc)
      entry = Enum.find(results, &(&1.key == "dup_key"))
      assert entry.content == "updated"
    end
  end
end
