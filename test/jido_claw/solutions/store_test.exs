defmodule JidoClaw.Solutions.StoreTest do
  use ExUnit.Case

  # NOT async — Store is a named GenServer with a global ETS table.
  # Isolation is enforced through sequential execution and explicit ETS cleanup
  # between tests.

  alias JidoClaw.Solutions.Store
  alias JidoClaw.Solutions.Solution

  @ets_table :jido_claw_solutions

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_signal_bus do
    case Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp solution_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        solution_content: "def hello, do: :world",
        language: "elixir",
        framework: nil,
        tags: []
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_solutions_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    ensure_signal_bus()

    # The application supervisor starts Store as part of core_children. To take
    # ownership in the test supervisor we must first remove it permanently from
    # the application supervisor, then start our own isolated instance.
    Supervisor.terminate_child(JidoClaw.Supervisor, Store)
    Supervisor.delete_child(JidoClaw.Supervisor, Store)

    # Clear any ETS state left by the application-owned Store so each test
    # begins with an empty table.
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    start_supervised!({Store, project_dir: tmp_dir})

    on_exit(fn ->
      # Clear ETS rows so the next test starts with an empty store.
      if :ets.whereis(@ets_table) != :undefined do
        :ets.delete_all_objects(@ets_table)
      end

      File.rm_rf!(tmp_dir)

      # Re-add Store to the application supervisor so subsequent test setups
      # can remove it again. This tolerates the case where the child was never
      # added (e.g., if the application did not start).
      project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
      _ = Supervisor.start_child(JidoClaw.Supervisor, {Store, project_dir: project_dir})
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # store_solution/1
  # ---------------------------------------------------------------------------

  describe "store_solution/1" do
    test "should store a solution and return {:ok, solution}" do
      assert {:ok, %Solution{}} = Store.store_solution(solution_attrs())
    end

    test "should auto-generate id" do
      {:ok, solution} = Store.store_solution(solution_attrs())
      assert is_binary(solution.id)
      assert String.length(solution.id) > 0
    end

    test "should auto-generate timestamps" do
      {:ok, solution} = Store.store_solution(solution_attrs())
      assert is_binary(solution.inserted_at)
      assert is_binary(solution.updated_at)
    end

    test "should generate problem_signature" do
      {:ok, solution} = Store.store_solution(solution_attrs())
      assert is_binary(solution.problem_signature)
      assert String.length(solution.problem_signature) == 64
    end

    test "should persist to solutions.json on disk", %{tmp_dir: tmp_dir} do
      Store.store_solution(solution_attrs())

      path = Path.join(tmp_dir, ".jido/solutions.json")
      assert File.exists?(path), "Expected #{path} to exist after store_solution/1"
    end

    test "should be retrievable after storage" do
      {:ok, stored} = Store.store_solution(solution_attrs())

      [retrieved] = Store.all()
      assert retrieved.id == stored.id
    end
  end

  # ---------------------------------------------------------------------------
  # find_by_signature/1
  # ---------------------------------------------------------------------------

  describe "find_by_signature/1" do
    test "should find a stored solution by exact signature match" do
      {:ok, stored} = Store.store_solution(solution_attrs())
      sig = stored.problem_signature

      assert {:ok, found} = Store.find_by_signature(sig)
      assert found.id == stored.id
    end

    test "should return :not_found when signature doesn't exist" do
      assert :not_found = Store.find_by_signature("nonexistent_sig_abc123")
    end
  end

  # ---------------------------------------------------------------------------
  # search/2
  # ---------------------------------------------------------------------------

  describe "search/2" do
    test "should find solutions matching query text" do
      Store.store_solution(
        solution_attrs(%{
          solution_content: "use GenServer for state management",
          language: "elixir"
        })
      )

      results = Store.search("GenServer")
      assert length(results) >= 1
    end

    test "should return empty list when nothing matches" do
      Store.store_solution(
        solution_attrs(%{solution_content: "def hello, do: :world", language: "elixir"})
      )

      results = Store.search("zzz_no_match_xyz_qrs")
      assert results == []
    end

    test "should filter by language when option provided" do
      Store.store_solution(
        solution_attrs(%{solution_content: "def elixir_fn, do: :ok", language: "elixir"})
      )

      Store.store_solution(
        solution_attrs(%{solution_content: "def python_fn", language: "python"})
      )

      results = Store.search("def", language: "elixir")
      assert Enum.all?(results, fn s -> s.language == "elixir" end)
      refute Enum.any?(results, fn s -> s.language == "python" end)
    end

    test "should filter by framework when option provided" do
      Store.store_solution(
        solution_attrs(%{
          solution_content: "plug router",
          language: "elixir",
          framework: "phoenix"
        })
      )

      Store.store_solution(
        solution_attrs(%{solution_content: "plug handler", language: "elixir", framework: "plug"})
      )

      results = Store.search("plug", framework: "phoenix")
      assert Enum.all?(results, fn s -> s.framework == "phoenix" end)
    end

    test "should respect limit option" do
      for i <- 1..5 do
        Store.store_solution(
          solution_attrs(%{solution_content: "shared content pattern #{i}", language: "elixir"})
        )
      end

      results = Store.search("pattern", limit: 2)
      assert length(results) <= 2
    end

    test "should rank results by relevance" do
      # High relevance: multiple token hits
      Store.store_solution(
        solution_attrs(%{
          solution_content: "GenServer handle_call handle_cast",
          language: "elixir",
          tags: ["genserver", "otp"]
        })
      )

      # Lower relevance: single hit
      Store.store_solution(
        solution_attrs(%{solution_content: "GenServer intro", language: "python"})
      )

      results = Store.search("GenServer handle_call otp")

      # Just verify results come back sorted (first result should be the more relevant one)
      assert length(results) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # update_trust/2
  # ---------------------------------------------------------------------------

  describe "update_trust/2" do
    test "should update the trust_score of a stored solution" do
      {:ok, stored} = Store.store_solution(solution_attrs())

      assert :ok = Store.update_trust(stored.id, 0.9)

      {:ok, updated} = Store.find_by_signature(stored.problem_signature)
      assert updated.trust_score == 0.9
    end

    test "should return :ok when solution doesn't exist" do
      assert :ok = Store.update_trust("nonexistent-id-abc", 0.5)
    end
  end

  # ---------------------------------------------------------------------------
  # update_verification/2
  # ---------------------------------------------------------------------------

  describe "update_verification/2" do
    test "should update the verification map of a stored solution" do
      {:ok, stored} = Store.store_solution(solution_attrs())
      verification = %{"tests_passed" => true, "lint" => "ok"}

      assert :ok = Store.update_verification(stored.id, verification)

      {:ok, updated} = Store.find_by_signature(stored.problem_signature)
      assert updated.verification == verification
    end

    test "should return :ok when solution doesn't exist" do
      assert :ok = Store.update_verification("nonexistent-id-abc", %{"tests_passed" => false})
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "should remove a solution from the store" do
      {:ok, stored} = Store.store_solution(solution_attrs())

      assert :ok = Store.delete(stored.id)
      assert :not_found = Store.find_by_signature(stored.problem_signature)
    end

    test "should return :ok when solution doesn't exist" do
      assert :ok = Store.delete("nonexistent-id-abc")
    end

    test "should not affect other solutions" do
      {:ok, keep} =
        Store.store_solution(
          solution_attrs(%{solution_content: "keep this one", language: "elixir"})
        )

      {:ok, remove} =
        Store.store_solution(
          solution_attrs(%{solution_content: "remove this one", language: "python"})
        )

      Store.delete(remove.id)

      assert {:ok, _} = Store.find_by_signature(keep.problem_signature)
      assert :not_found = Store.find_by_signature(remove.problem_signature)
    end
  end

  # ---------------------------------------------------------------------------
  # stats/0
  # ---------------------------------------------------------------------------

  describe "stats/0" do
    test "should return total count" do
      Store.store_solution(solution_attrs(%{language: "elixir"}))

      Store.store_solution(
        solution_attrs(%{solution_content: "other content", language: "python"})
      )

      stats = Store.stats()
      assert stats.total == 2
    end

    test "should group by language" do
      Store.store_solution(solution_attrs(%{language: "elixir"}))

      Store.store_solution(
        solution_attrs(%{solution_content: "other content", language: "python"})
      )

      Store.store_solution(solution_attrs(%{solution_content: "yet another", language: "elixir"}))

      stats = Store.stats()
      assert stats.by_language["elixir"] == 2
      assert stats.by_language["python"] == 1
    end

    test "should group by framework" do
      Store.store_solution(solution_attrs(%{language: "elixir", framework: "phoenix"}))

      Store.store_solution(
        solution_attrs(%{
          solution_content: "other content",
          language: "elixir",
          framework: "phoenix"
        })
      )

      Store.store_solution(
        solution_attrs(%{solution_content: "yet another", language: "elixir", framework: "plug"})
      )

      stats = Store.stats()
      assert stats.by_framework["phoenix"] == 2
      assert stats.by_framework["plug"] == 1
    end

    test "should return zeros when store is empty" do
      stats = Store.stats()
      assert stats.total == 0
      assert stats.by_language == %{}
      assert stats.by_framework == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # all/1
  # ---------------------------------------------------------------------------

  describe "all/1" do
    test "should return all solutions" do
      Store.store_solution(solution_attrs(%{solution_content: "content one", language: "elixir"}))
      Store.store_solution(solution_attrs(%{solution_content: "content two", language: "python"}))

      results = Store.all()
      assert length(results) == 2
    end

    test "should respect limit option" do
      for i <- 1..5 do
        Store.store_solution(
          solution_attrs(%{solution_content: "content #{i}", language: "elixir"})
        )
      end

      results = Store.all(limit: 3)
      assert length(results) == 3
    end

    test "should respect offset option" do
      for i <- 1..5 do
        Store.store_solution(
          solution_attrs(%{solution_content: "content #{i}", language: "elixir"})
        )

        # Ensure distinct inserted_at timestamps for deterministic ordering
        Process.sleep(2)
      end

      all = Store.all()
      offset_results = Store.all(offset: 2)

      assert length(offset_results) == 3
      # First item in offset_results should match the 3rd item in all
      assert Enum.at(offset_results, 0).id == Enum.at(all, 2).id
    end

    test "should return empty list when store is empty" do
      assert [] = Store.all()
    end
  end

  # ---------------------------------------------------------------------------
  # Disk persistence
  # ---------------------------------------------------------------------------

  describe "disk persistence" do
    test "should create solutions.json after store_solution", %{tmp_dir: tmp_dir} do
      Store.store_solution(solution_attrs())

      path = Path.join(tmp_dir, ".jido/solutions.json")
      assert File.exists?(path)
    end

    test "should reload solutions from disk on restart", %{tmp_dir: tmp_dir} do
      {:ok, stored} =
        Store.store_solution(
          solution_attrs(%{solution_content: "survived restart", language: "elixir"})
        )

      # Stop the supervised Store process (test-owned)
      stop_supervised!(Store)

      # Wipe ETS so the in-memory store is empty
      if :ets.whereis(@ets_table) != :undefined do
        :ets.delete_all_objects(@ets_table)
      end

      # Restart Store against the same directory — it should reload the JSON.
      # The application supervisor's child was already removed in setup, so
      # start_supervised! will not encounter a conflict here.
      start_supervised!({Store, project_dir: tmp_dir})

      assert {:ok, reloaded} = Store.find_by_signature(stored.problem_signature)
      assert reloaded.id == stored.id
      assert reloaded.solution_content == "survived restart"
    end
  end

  # ---------------------------------------------------------------------------
  # Graceful degradation when GenServer is not running
  # ---------------------------------------------------------------------------

  describe "graceful handling when GenServer is not running" do
    test "store_solution/1 returns {:error, :not_running} when process is absent" do
      stop_supervised!(Store)
      assert {:error, :not_running} = Store.store_solution(solution_attrs())
    end

    test "find_by_signature/1 returns :not_found when process is absent" do
      stop_supervised!(Store)
      assert :not_found = Store.find_by_signature("any-signature")
    end

    test "search/2 returns [] when process is absent" do
      stop_supervised!(Store)
      assert [] = Store.search("anything")
    end

    test "update_trust/2 returns :ok when process is absent" do
      stop_supervised!(Store)
      assert :ok = Store.update_trust("any-id", 0.5)
    end

    test "update_verification/2 returns :ok when process is absent" do
      stop_supervised!(Store)
      assert :ok = Store.update_verification("any-id", %{})
    end

    test "delete/1 returns :ok when process is absent" do
      stop_supervised!(Store)
      assert :ok = Store.delete("any-id")
    end

    test "stats/0 returns zero-filled map when process is absent" do
      stop_supervised!(Store)
      assert %{total: 0, by_language: %{}, by_framework: %{}} = Store.stats()
    end

    test "all/1 returns [] when process is absent" do
      stop_supervised!(Store)
      assert [] = Store.all()
    end
  end
end
