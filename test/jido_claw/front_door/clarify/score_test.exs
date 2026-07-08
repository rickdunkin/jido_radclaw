defmodule JidoClaw.FrontDoor.Clarify.ScoreTest do
  @moduledoc """
  The ported ouroboros scoring semantics (PORT-OB1-1): constants pinned against
  the source values, the ambiguity formula, the deterministic anti-gaming
  floor, the boundary-inclusive pass gate, and the OR2-5 readiness verdict.
  Pure — no LLM, no DB.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.FrontDoor.Clarify.Score

  describe "ported constants (ouroboros ambiguity.py:35-57)" do
    test "threshold / streak / temperature" do
      assert Score.threshold() == 0.2
      assert Score.streak_required() == 2
      assert Score.temperature() == 0.1
    end

    test "brownfield weights sum to 1.0 and match the source" do
      assert Score.weights() == %{
               "goal" => 0.35,
               "constraints" => 0.25,
               "success_criteria" => 0.25,
               "context" => 0.15
             }

      assert_in_delta Enum.sum(Map.values(Score.weights())), 1.0, 1.0e-9
    end

    test "per-dimension floors match the source" do
      assert Score.floors() == %{
               "goal" => 0.75,
               "constraints" => 0.65,
               "success_criteria" => 0.70,
               "context" => 0.60
             }
    end

    test "greenfield weights ported for fidelity (documented-but-unused)" do
      assert Score.greenfield_weights() == %{
               "goal" => 0.40,
               "constraints" => 0.30,
               "success_criteria" => 0.30
             }
    end
  end

  describe "ambiguity/1 (1 − Σ clarity × weight)" do
    test "perfectly clear ⇒ 0.0 (test_calculate_overall_perfectly_clear)" do
      clarity = Map.new(Score.dimensions(), &{&1, 1.0})
      assert Score.ambiguity(clarity) == 0.0
    end

    test "completely ambiguous ⇒ 1.0 (test_calculate_overall_completely_ambiguous)" do
      clarity = Map.new(Score.dimensions(), &{&1, 0.0})
      assert Score.ambiguity(clarity) == 1.0
    end

    test "mixed scores match the hand-computed weighted sum" do
      clarity = %{
        "goal" => 0.8,
        "constraints" => 0.6,
        "success_criteria" => 0.4,
        "context" => 1.0
      }

      # 1 − (0.8·0.35 + 0.6·0.25 + 0.4·0.25 + 1.0·0.15) = 1 − 0.68 = 0.32
      assert Score.ambiguity(clarity) == 0.32
    end

    test "missing dimension reads as 0.0 clarity" do
      assert Score.ambiguity(%{"goal" => 1.0}) == Float.round(1.0 - 0.35, 4)
    end
  end

  describe "normalize_clarity/1" do
    test "clamps out-of-range values (test_parse_response_clamps_scores)" do
      normalized = Score.normalize_clarity(%{"goal" => 1.7, "constraints" => -0.3})
      assert normalized["goal"] == 1.0
      assert normalized["constraints"] == 0.0
    end

    test "missing / non-numeric dimensions coerce to 0.0 (floor-failing)" do
      normalized = Score.normalize_clarity(%{"goal" => "high"})
      assert normalized == Map.new(Score.dimensions(), &{&1, 0.0})
    end

    test "non-map input coerces to the all-zero shape" do
      assert Score.normalize_clarity(nil) == Map.new(Score.dimensions(), &{&1, 0.0})
    end
  end

  describe "deterministic_floor/1 (grading.py:523-547)" do
    test "empty ledger ⇒ 0.0" do
      assert Score.deterministic_floor(%{open: 0, conflicting: 0, assumed: 0, total: 0}) == 0.0
    end

    test "coefficients: 0.05 per open, 0.10 per conflicting, 0.05 × assumed ratio" do
      assert Score.deterministic_floor(%{open: 1, conflicting: 0, assumed: 0, total: 4}) == 0.05
      assert Score.deterministic_floor(%{open: 0, conflicting: 1, assumed: 0, total: 4}) == 0.10

      assert Score.deterministic_floor(%{open: 0, conflicting: 0, assumed: 2, total: 4}) ==
               0.05 * 0.5

      assert_in_delta Score.deterministic_floor(%{open: 2, conflicting: 1, assumed: 1, total: 4}),
                      0.05 * 2 + 0.10 + 0.05 * 0.25,
                      1.0e-9
    end

    test "clamps to 1.0" do
      assert Score.deterministic_floor(%{open: 30, conflicting: 5, assumed: 0, total: 35}) == 1.0
    end
  end

  describe "effective_ambiguity/2 (max — the LLM cannot under-report)" do
    test "floor wins when the LLM under-reports" do
      assert Score.effective_ambiguity(0.05, 0.3) == 0.3
    end

    test "LLM score wins when honest" do
      assert Score.effective_ambiguity(0.5, 0.1) == 0.5
    end

    test "clamps a wild LLM score into [0, 1]" do
      assert Score.effective_ambiguity(7.0, 0.0) == 1.0
      assert Score.effective_ambiguity(-2.0, 0.0) == 0.0
    end
  end

  describe "qualifies?/2 (threshold ∧ 4 floors, boundaries inclusive)" do
    # Every floor met exactly — one strong dimension can't mask a weak one.
    @at_floors %{
      "goal" => 0.75,
      "constraints" => 0.65,
      "success_criteria" => 0.70,
      "context" => 0.60
    }

    test "exactly 0.2 passes; just above fails (test_is_ready_for_seed_at_threshold)" do
      assert Score.qualifies?(0.2, @at_floors)
      refute Score.qualifies?(0.2001, @at_floors)
    end

    test "one dimension under its floor fails even with a passing score" do
      refute Score.qualifies?(0.1, %{@at_floors | "context" => 0.59})
    end

    test "clarity exactly at every floor passes (inclusive)" do
      assert Score.qualifies?(0.0, @at_floors)
    end

    test "missing dimension fails its floor" do
      refute Score.qualifies?(0.0, Map.delete(@at_floors, "goal"))
    end
  end

  describe "readiness/1 (orca OR2-5 vocabulary)" do
    defp item(status, required?) do
      %{
        "question" => "q?",
        "why_it_matters" => "",
        "risk_if_unanswered" => "",
        "recommended_default_assumption" => "d",
        "user_input_required" => required?,
        "status" => status,
        "user_answer" => nil
      }
    end

    test "unresolved required item ⇒ blocked_needs_user_input" do
      assert Score.readiness([item("open", true)]) == "blocked_needs_user_input"
      assert Score.readiness([item("conflicting", true)]) == "blocked_needs_user_input"
    end

    test "unresolved-but-assumable or assumed items ⇒ ready_with_assumptions" do
      assert Score.readiness([item("open", false)]) == "ready_with_assumptions"
      assert Score.readiness([item("assumed", false)]) == "ready_with_assumptions"
      assert Score.readiness([item("assumed", true)]) == "ready_with_assumptions"
    end

    test "all answered (or empty) ⇒ ready_for_tasks" do
      assert Score.readiness([item("answered", true)]) == "ready_for_tasks"
      assert Score.readiness([]) == "ready_for_tasks"
    end
  end
end
