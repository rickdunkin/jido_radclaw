defmodule JidoClaw.Solutions.MatcherTest do
  use ExUnit.Case

  # NOT async — depends on Store GenServer (named process + named ETS table).
  # Sequential execution ensures isolation without race conditions.

  alias JidoClaw.Solutions.{Fingerprint, Matcher, Store}

  @ets_table :jido_claw_solutions

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # Ensure Store is running (may not be started in test env)
    case GenServer.whereis(Store) do
      nil ->
        {:ok, _} = start_supervised({Store, [project_dir: System.tmp_dir!()]})

      _pid ->
        :ok
    end

    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    # Seed three solutions with distinct languages, frameworks, and tags.
    {:ok, _} =
      Store.store_solution(%{
        solution_content: "Use GenServer for stateful process management",
        language: "elixir",
        framework: "otp",
        tags: ["genserver", "state", "process"]
      })

    {:ok, _} =
      Store.store_solution(%{
        solution_content: "Use React.useState hook for component state",
        language: "typescript",
        framework: "react",
        tags: ["hooks", "state", "component"]
      })

    {:ok, _} =
      Store.store_solution(%{
        solution_content: "Use Ecto.Multi for transactional database operations",
        language: "elixir",
        framework: "phoenix",
        tags: ["ecto", "transaction", "database"]
      })

    on_exit(fn ->
      if :ets.whereis(@ets_table) != :undefined do
        :ets.delete_all_objects(@ets_table)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # find_solutions/2
  # ---------------------------------------------------------------------------

  describe "find_solutions/2" do
    test "should return exact match when signature matches" do
      # Matcher looks up solutions by the signature produced by Fingerprint.generate,
      # not by Solution.signature (which uses a different separator). We must
      # pre-compute the fingerprint signature and store the solution with that
      # exact value so Store.find_by_signature hits.
      description = "Use Task.async for concurrent work"
      language = "elixir"
      framework = "otp"

      fp = Fingerprint.generate(description, language: language, framework: framework)

      {:ok, solution} =
        Store.store_solution(%{
          solution_content: description,
          language: language,
          framework: framework,
          problem_signature: fp.signature,
          tags: ["task", "concurrency"]
        })

      results =
        Matcher.find_solutions(description,
          language: language,
          framework: framework
        )

      assert length(results) == 1
      [%{solution: matched, score: score, match_type: match_type}] = results
      assert matched.id == solution.id
      assert score == 1.0
      assert match_type == :exact
    end

    test "should return fuzzy matches for related problems" do
      # Combined score = fp_score * 0.6 + trust_score * 0.4. Seeded solutions
      # have trust_score 0.0, so use a low threshold to capture fuzzy hits.
      results =
        Matcher.find_solutions("stateful process with GenServer in Elixir", threshold: 0.0)

      assert length(results) > 0

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :solution)
        assert Map.has_key?(result, :score)
        assert Map.has_key?(result, :match_type)
      end)
    end

    test "should filter by threshold — high threshold yields fewer results" do
      low_threshold_results = Matcher.find_solutions("state management", threshold: 0.01)
      high_threshold_results = Matcher.find_solutions("state management", threshold: 0.95)

      assert length(low_threshold_results) >= length(high_threshold_results)
    end

    test "should respect the limit option" do
      results = Matcher.find_solutions("state", threshold: 0.0, limit: 1)

      assert length(results) <= 1
    end

    test "should return empty list for empty description" do
      assert [] = Matcher.find_solutions("")
    end

    test "should return empty list for nil description" do
      assert [] = Matcher.find_solutions(nil)
    end

    test "should return results with score and match_type fields" do
      results = Matcher.find_solutions("database transaction elixir", threshold: 0.0)

      assert length(results) > 0

      Enum.each(results, fn result ->
        assert is_map(result)
        assert Map.has_key?(result, :solution)
        assert Map.has_key?(result, :score)
        assert Map.has_key?(result, :match_type)
        assert is_float(result.score)
        assert result.match_type in [:exact, :fuzzy]
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # rank_solutions/2
  # ---------------------------------------------------------------------------

  describe "rank_solutions/2" do
    test "should sort by combined score descending" do
      solutions = Store.all()
      query_fp = Fingerprint.generate("stateful process management in elixir", language: "elixir")

      ranked = Matcher.rank_solutions(solutions, query_fp)

      scores = Enum.map(ranked, fn {_sol, score} -> score end)
      assert scores == Enum.sort(scores, :desc)
    end

    test "should combine fingerprint score and trust score" do
      # Build two solutions: one with higher trust_score but weaker fp match,
      # one with lower trust but exact domain match. Verify the ranking changes
      # when trust scores differ.
      {:ok, low_trust} =
        Store.store_solution(%{
          solution_content: "Use Agent for simple shared state",
          language: "elixir",
          framework: "otp",
          tags: ["agent", "state"],
          trust_score: 0.0
        })

      {:ok, high_trust} =
        Store.store_solution(%{
          solution_content: "Use Agent for simple shared state",
          language: "elixir",
          framework: "otp",
          tags: ["agent", "state"],
          trust_score: 1.0
        })

      query_fp = Fingerprint.generate("simple shared state agent", language: "elixir")
      ranked = Matcher.rank_solutions([low_trust, high_trust], query_fp)

      [{top_solution, top_score}, {_bottom_solution, bottom_score}] = ranked

      assert top_solution.id == high_trust.id
      assert top_score > bottom_score
    end
  end

  # ---------------------------------------------------------------------------
  # best_match/2
  # ---------------------------------------------------------------------------

  describe "best_match/2" do
    test "should return single best match" do
      # Seeded solutions have trust_score 0.0; use a low threshold so a fuzzy
      # match qualifies and best_match returns a result rather than nil.
      result = Matcher.best_match("GenServer stateful process elixir otp", threshold: 0.0)

      assert is_map(result)
      assert Map.has_key?(result, :solution)
      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :match_type)
    end

    test "should return nil when no matches found" do
      # An extremely high threshold ensures nothing qualifies.
      result = Matcher.best_match("zzz_no_match_xyz_abc_123", threshold: 0.99)

      assert is_nil(result)
    end
  end

  # ---------------------------------------------------------------------------
  # text_relevance/2
  # ---------------------------------------------------------------------------

  describe "text_relevance/2" do
    test "should return 0.0 for empty query terms list" do
      assert Matcher.text_relevance([], "some document text here") == 0.0
    end

    test "should return > 0.0 when terms match the document" do
      score =
        Matcher.text_relevance(
          ["genserver", "state"],
          "use genserver for stateful state management"
        )

      assert score > 0.0
    end

    test "should return 0.0 when no terms match the document" do
      score = Matcher.text_relevance(["zzz", "xyz"], "use genserver for stateful management")

      assert score == 0.0
    end

    test "should handle non-string document input by returning 0.0" do
      assert Matcher.text_relevance(["term"], nil) == 0.0
      assert Matcher.text_relevance(["term"], 42) == 0.0
      assert Matcher.text_relevance(["term"], :atom) == 0.0
    end

    test "should handle non-list query terms input by returning 0.0" do
      assert Matcher.text_relevance(nil, "some document text") == 0.0
      assert Matcher.text_relevance("not a list", "some document text") == 0.0
    end

    test "should score proportionally — more matching terms means higher score" do
      one_term_score = Matcher.text_relevance(["genserver"], "use genserver for state management")

      two_term_score =
        Matcher.text_relevance(
          ["genserver", "state"],
          "use genserver for state management"
        )

      assert two_term_score >= one_term_score
    end
  end
end
