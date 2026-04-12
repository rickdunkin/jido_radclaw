defmodule JidoClaw.Tools.RecallTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.Recall
  alias JidoClaw.Tools.Remember

  # Jido.Signal.Bus uses its own internal naming, not Process.register/2.
  # Attempt the start and treat :already_started as success.
  defp ensure_signal_bus do
    case Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_recall_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ensure_signal_bus()

    # Clear the four ETS tables used by Jido.Memory.Store.ETS (base: :jido_claw_memory).
    # Memory is owned by the Application supervision tree — clear tables directly.
    for table <-
          ~w[jido_claw_memory_records jido_claw_memory_ns_time jido_claw_memory_ns_class_time jido_claw_memory_ns_tag]a do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "run/2 with matching memories" do
    test "should return {:ok, result} map" do
      Remember.run(%{key: "db_schema", content: "users table has id, email, name"}, %{})

      assert {:ok, result} = Recall.run(%{query: "db_schema"}, %{})
      assert is_map(result)
    end

    test "should return results as a formatted string" do
      Remember.run(%{key: "api_url", content: "https://example.com/api"}, %{})

      assert {:ok, result} = Recall.run(%{query: "api_url"}, %{})
      assert is_binary(result.results)
    end

    test "should return count equal to number of matching entries" do
      Remember.run(%{key: "convention_1", content: "use snake_case"}, %{})
      Remember.run(%{key: "convention_2", content: "use modules not functions"}, %{})

      assert {:ok, result} = Recall.run(%{query: "convention"}, %{})
      assert result.count >= 2
    end

    test "results string includes the key and content" do
      Remember.run(%{key: "preferred_style", content: "4 space indent"}, %{})

      assert {:ok, result} = Recall.run(%{query: "preferred_style"}, %{})
      assert result.results =~ "preferred_style"
      assert result.results =~ "4 space indent"
    end

    test "results string includes the memory type" do
      Remember.run(%{key: "db_decision", content: "use Ecto", type: "decision"}, %{})

      assert {:ok, result} = Recall.run(%{query: "db_decision"}, %{})
      assert result.results =~ "decision"
    end

    test "should match on content substring" do
      Remember.run(%{key: "random_key", content: "the auth_token is refreshed hourly"}, %{})

      assert {:ok, result} = Recall.run(%{query: "auth_token"}, %{})
      assert result.count >= 1
    end

    test "should match on type substring" do
      Remember.run(%{key: "some_fact", content: "a recorded fact", type: "fact"}, %{})

      assert {:ok, result} = Recall.run(%{query: "fact"}, %{})
      assert result.count >= 1
    end
  end

  describe "run/2 with no matching memories" do
    test "should return {:ok, result} even when no memories match" do
      assert {:ok, result} = Recall.run(%{query: "completely_nonexistent_xyz_abc"}, %{})
      assert is_map(result)
    end

    test "should return count of 0 when no memories match" do
      assert {:ok, result} = Recall.run(%{query: "xyzzy_no_match_ever"}, %{})
      assert result.count == 0
    end

    test "should return 'No memories found' message in results" do
      assert {:ok, result} = Recall.run(%{query: "totally_unique_nonexistent"}, %{})
      assert result.results =~ "No memories found"
    end

    test "no-match message includes the query term" do
      assert {:ok, result} = Recall.run(%{query: "my_missing_query"}, %{})
      assert result.results =~ "my_missing_query"
    end
  end

  describe "run/2 with limit parameter" do
    setup do
      # Store 5 memories with a common searchable key prefix
      for i <- 1..5 do
        Remember.run(%{key: "limit_test_#{i}", content: "content #{i}"}, %{})
      end

      :ok
    end

    test "should respect limit when fewer results are available than the limit" do
      assert {:ok, result} = Recall.run(%{query: "limit_test", limit: 10}, %{})
      assert result.count == 5
    end

    test "should cap results to the given limit" do
      assert {:ok, result} = Recall.run(%{query: "limit_test", limit: 2}, %{})
      assert result.count <= 2
    end

    test "should default to at most 10 results when no limit is given" do
      # Store 12 memories with same prefix
      for i <- 1..12 do
        Remember.run(%{key: "default_limit_#{i}", content: "value #{i}"}, %{})
      end

      assert {:ok, result} = Recall.run(%{query: "default_limit"}, %{})
      assert result.count <= 10
    end
  end
end
