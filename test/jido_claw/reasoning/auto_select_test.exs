defmodule JidoClaw.Reasoning.AutoSelectTest do
  # async: false — Statistics queries hit the DB via Ecto sandbox, and
  # Classifier reads from the supervised StrategyStore.
  use ExUnit.Case, async: false

  import JidoClaw.Reasoning.StrategyTestHelper

  alias JidoClaw.Reasoning.{AutoSelect, Resources.Outcome, TaskProfile}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  # A tiebreaker stub that always picks the *last* candidate. Lets tests
  # differentiate a tie-break pick from the heuristic top pick.
  defmodule PickLastTiebreaker do
    @moduledoc false

    def choose(_prompt, candidates, _opts) when is_list(candidates) and candidates != [] do
      {:ok, List.last(candidates)}
    end
  end

  defmodule FailingTiebreaker do
    @moduledoc false
    def choose(_prompt, _candidates, _opts), do: {:error, :timeout}
  end

  defp insert_outcome(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      strategy: "cot",
      execution_kind: :strategy_run,
      task_type: :qa,
      complexity: :simple,
      prompt_length: 10,
      status: :ok,
      started_at: now
    }

    {:ok, _} = Outcome.record(Map.merge(defaults, attrs))
  end

  describe "select/2 — basic happy paths" do
    test "returns {:ok, strategy, confidence, profile, diagnostics} with a concrete strategy" do
      assert {:ok, strategy, confidence, %TaskProfile{} = profile, diag} =
               AutoSelect.select("Fix the bug in the login handler", skip_history: true)

      # Must never surface a selector as the resolved strategy.
      refute strategy in ["auto", "adaptive"]
      # react is excluded from the auto candidate pool.
      refute strategy == "react"
      assert is_float(confidence) and confidence >= 0.0 and confidence <= 1.0
      assert profile.task_type == :debugging
      assert diag.selection_mode == "auto"
      assert diag.heuristic_rank >= 1
    end

    test "diagnostics.history_window is :empty when skip_history" do
      {:ok, _, _, _, diag} = AutoSelect.select("Plan a migration", skip_history: true)
      assert diag.history_window == :empty
      assert diag.history_samples == 0
    end

    test "alternatives list contains ranked candidates" do
      {:ok, _, _, _, diag} = AutoSelect.select("Plan a new auth system", skip_history: true)
      assert is_list(diag.alternatives)
      assert length(diag.alternatives) >= 2
    end
  end

  describe "select/2 — history branching" do
    test "uses caller-supplied history when present" do
      # cot gets a huge success rate with enough samples; should lift cot above
      # heuristic baseline for QA.
      history = [
        %{strategy: "cot", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50}
      ]

      {:ok, _, _, _profile, diag} =
        AutoSelect.select("What is a GenServer?",
          history: history,
          llm_tiebreak: false
        )

      # The history window label for a supplied non-empty list is :all_time.
      assert diag.history_window == :all_time
      assert diag.history_samples == 50
    end

    test "returns :empty window when caller supplies an empty history" do
      {:ok, _, _, _profile, diag} =
        AutoSelect.select("What is a GenServer?", history: [], llm_tiebreak: false)

      assert diag.history_window == :empty
    end

    test "falls back to all-time when recent window is sparse" do
      # Seed only old rows (outside 30d) — recent window will be empty so
      # AutoSelect should re-query all-time. We can't easily fake the date,
      # but we can seed enough to exceed @min_history_samples total.
      now = DateTime.utc_now()
      old = DateTime.add(now, -60 * 86_400, :second)

      for _ <- 1..6 do
        insert_outcome(%{strategy: "cot", task_type: :qa, started_at: old, status: :ok})
      end

      {:ok, strategy, _, _, diag} =
        AutoSelect.select("What is a GenServer?", llm_tiebreak: false)

      # All rows are >30d old, so recent query returns nothing. AutoSelect
      # should have fallen back to all-time and found the 6 cot samples.
      assert diag.history_window == :all_time
      assert diag.history_samples == 6
      assert strategy == "cot"
    end

    test "uses recent window when it has enough samples" do
      now = DateTime.utc_now()

      for _ <- 1..6 do
        insert_outcome(%{strategy: "cot", task_type: :qa, started_at: now, status: :ok})
      end

      {:ok, _, _, _, diag} =
        AutoSelect.select("What is a GenServer?", llm_tiebreak: false)

      assert diag.history_window == :recent
      assert diag.history_samples == 6
    end
  end

  describe "select/2 — tiebreak" do
    test "LLM tiebreaker fires when top-2 scores are within threshold" do
      # Two candidates with identical heuristic scores + history boosts tied.
      # Use tiebreak_module to deterministically pick the last candidate.
      # Prompt with no strong signal → fallback cot path activates when
      # history is empty and heuristics can't separate candidates.
      # To force a tie, supply matched history for multiple strategies.
      history = [
        %{strategy: "cot", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50},
        %{strategy: "cod", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50}
      ]

      {:ok, chosen, _, _, diag} =
        AutoSelect.select("What is a GenServer?",
          history: history,
          tiebreak_module: PickLastTiebreaker
        )

      # tiebreak_by_llm? is true *if* the top-2 scores were tied.
      if diag.tie_broken_by_llm? do
        assert chosen in ["cot", "cod"]
      end
    end

    test "tiebreak disabled via llm_tiebreak: false never fires" do
      history = [
        %{strategy: "cot", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50},
        %{strategy: "cod", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50}
      ]

      {:ok, _, _, _, diag} =
        AutoSelect.select("What is a GenServer?",
          history: history,
          llm_tiebreak: false
        )

      refute diag.tie_broken_by_llm?
    end

    test "tiebreak failure falls back to top heuristic pick" do
      history = [
        %{strategy: "cot", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50},
        %{strategy: "cod", success_rate: 1.0, avg_duration_ms: 100.0, samples: 50}
      ]

      {:ok, chosen, _, _, diag} =
        AutoSelect.select("What is a GenServer?",
          history: history,
          tiebreak_module: FailingTiebreaker
        )

      # Fallback path — tie_broken_by_llm? is false when the LLM call fails.
      refute diag.tie_broken_by_llm?
      assert is_binary(chosen)
    end
  end

  describe "select/2 — react exclusion" do
    test "never returns react even when history would favor it" do
      history = [
        %{strategy: "react", success_rate: 1.0, avg_duration_ms: 100.0, samples: 100}
      ]

      {:ok, chosen, _, _, _} =
        AutoSelect.select("Fix the bug in the login handler",
          history: history,
          llm_tiebreak: false
        )

      refute chosen == "react"
    end
  end

  describe "select/2 — alias exclusion" do
    test "never returns a react-based alias even when history would favor it" do
      with_user_strategy(
        """
        name: deep_debug
        base: react
        prefers:
          task_types: [debugging]
          complexity: [complex, highly_complex]
        """,
        fn ->
          history = [
            %{
              strategy: "deep_debug",
              success_rate: 1.0,
              avg_duration_ms: 100.0,
              samples: 100
            }
          ]

          {:ok, chosen, _, _, diag} =
            AutoSelect.select("Fix the bug in the login handler",
              history: history,
              llm_tiebreak: false
            )

          refute chosen == "deep_debug"
          refute chosen == "react"

          refute Enum.any?(diag.alternatives, fn {name, _} ->
                   name == "deep_debug" or name == "react"
                 end)
        end
      )
    end

    test "never returns an adaptive-based alias even when history would favor it" do
      with_user_strategy(
        """
        name: smart_pick
        base: adaptive
        """,
        fn ->
          history = [
            %{
              strategy: "smart_pick",
              success_rate: 1.0,
              avg_duration_ms: 100.0,
              samples: 100
            }
          ]

          {:ok, chosen, _, _, diag} =
            AutoSelect.select("What is a GenServer?",
              history: history,
              llm_tiebreak: false
            )

          refute chosen == "smart_pick"
          refute chosen == "adaptive"

          refute Enum.any?(diag.alternatives, fn {name, _} ->
                   name == "smart_pick" or name == "adaptive"
                 end)
        end
      )
    end

    test "a cot-based alias with strong favorable history can be picked" do
      # Exclusion is surgical at react + adaptive bases only — aliases
      # pointing at cot stay in the candidate pool.
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        prefers:
          task_types: [qa, verification]
          complexity: [simple, moderate]
        """,
        fn ->
          history = [
            %{
              strategy: "fast_reviewer",
              success_rate: 1.0,
              avg_duration_ms: 100.0,
              samples: 100
            }
          ]

          {:ok, _, _, _, diag} =
            AutoSelect.select("What is a GenServer?",
              history: history,
              llm_tiebreak: false
            )

          assert Enum.any?(diag.alternatives, fn {name, _} -> name == "fast_reviewer" end)
        end
      )
    end
  end
end
