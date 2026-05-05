defmodule JidoClaw.Tools.RecallTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.Recall
  alias JidoClaw.Tools.Remember
  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

    {:ok, ws} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/recall_test_#{System.unique_integer([:positive])}",
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

  describe "run/2 with matching memories" do
    test "returns {:ok, result} map", %{tool_context: tc} do
      Remember.run(%{key: "db_schema", content: "users table has id, email, name"}, %{
        tool_context: tc
      })

      assert {:ok, result} = Recall.run(%{query: "db_schema"}, %{tool_context: tc})
      assert is_map(result)
    end

    test "results string includes the key and content", %{tool_context: tc} do
      Remember.run(%{key: "preferred_style", content: "4 space indent"}, %{tool_context: tc})

      assert {:ok, result} = Recall.run(%{query: "preferred_style"}, %{tool_context: tc})
      assert result.results =~ "preferred_style"
      assert result.results =~ "4 space indent"
    end

    test "results string includes the memory type", %{tool_context: tc} do
      Remember.run(%{key: "db_decision", content: "use Ecto", type: "decision"}, %{
        tool_context: tc
      })

      assert {:ok, result} = Recall.run(%{query: "db_decision"}, %{tool_context: tc})
      assert result.results =~ "decision"
    end

    test "matches on label substring (substring-superset regression)", %{tool_context: tc} do
      Remember.run(%{key: "api_base_url", content: "https://api.example.com"}, %{
        tool_context: tc
      })

      assert {:ok, result} = Recall.run(%{query: "api"}, %{tool_context: tc})
      assert result.count >= 1
    end

    test "matches on content substring", %{tool_context: tc} do
      Remember.run(
        %{key: "random_key", content: "the auth_token is refreshed hourly"},
        %{tool_context: tc}
      )

      assert {:ok, result} = Recall.run(%{query: "auth_token"}, %{tool_context: tc})
      assert result.count >= 1
    end
  end

  describe "run/2 with no matching memories" do
    test "returns {:ok, result} even when no memories match", %{tool_context: tc} do
      assert {:ok, result} =
               Recall.run(%{query: "completely_nonexistent_xyz_abc"}, %{tool_context: tc})

      assert is_map(result)
    end

    test "returns count of 0 when no memories match", %{tool_context: tc} do
      assert {:ok, result} =
               Recall.run(%{query: "xyzzy_no_match_ever"}, %{tool_context: tc})

      assert result.count == 0
    end

    test "returns 'No memories found' message in results", %{tool_context: tc} do
      assert {:ok, result} =
               Recall.run(%{query: "totally_unique_nonexistent"}, %{tool_context: tc})

      assert result.results =~ "No memories found"
    end

    test "no-match message includes the query term", %{tool_context: tc} do
      assert {:ok, result} =
               Recall.run(%{query: "my_missing_query"}, %{tool_context: tc})

      assert result.results =~ "my_missing_query"
    end
  end

  describe "run/2 with limit parameter" do
    setup %{tool_context: tc} do
      for i <- 1..5 do
        Remember.run(
          %{key: "limit_test_#{i}", content: "shared pattern content #{i}"},
          %{tool_context: tc}
        )
      end

      :ok
    end

    test "respects limit when fewer results are available than the limit", %{tool_context: tc} do
      assert {:ok, result} =
               Recall.run(%{query: "limit_test", limit: 10}, %{tool_context: tc})

      assert result.count <= 5
    end

    test "caps results to the given limit", %{tool_context: tc} do
      assert {:ok, result} = Recall.run(%{query: "limit_test", limit: 2}, %{tool_context: tc})
      assert result.count <= 2
    end
  end
end
