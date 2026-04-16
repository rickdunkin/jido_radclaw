defmodule JidoClaw.Solutions.TrustTest do
  use ExUnit.Case, async: true
  # async: Trust is pure functional — no GenServer, no ETS, no global state.

  alias JidoClaw.Solutions.Trust

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds a DateTime that is `days` days in the past relative to `now`.
  defp days_ago(days, now) do
    DateTime.add(now, -days * 86_400, :second)
  end

  # A minimal solution map (only the structurally required keys).
  defp minimal_solution do
    %{solution_content: "x", language: "elixir"}
  end

  # ---------------------------------------------------------------------------
  # compute/2
  # ---------------------------------------------------------------------------

  describe "compute/2" do
    test "should return a float between 0.0 and 1.0" do
      score = Trust.compute(minimal_solution())

      assert is_float(score)
      assert score >= 0.0
      assert score <= 1.0
    end

    test "should apply correct weights (0.35 verification, 0.25 completeness, 0.25 freshness, 0.15 reputation)" do
      now = ~U[2026-01-01 12:00:00Z]

      solution = %{
        solution_content: "x",
        language: "elixir",
        verification: %{status: "passed"},
        # completeness bonuses: framework +0.10, runtime +0.10, verification +0.15 → base 0.3 + 0.35 = 0.65
        framework: "phoenix",
        runtime: "otp-26",
        updated_at: DateTime.to_iso8601(DateTime.add(now, -1 * 86_400, :second))
      }

      # verification_score  = 1.0
      # completeness_score  = 0.65 (base 0.3 + framework 0.1 + runtime 0.1 + verification 0.15)
      # freshness_score     = 1.0  (1 day old < 7 day threshold)
      # agent_reputation    = 0.5  (default)
      expected = 1.0 * 0.35 + 0.65 * 0.25 + 1.0 * 0.25 + 0.5 * 0.15

      actual = Trust.compute(solution, now: now)

      assert_in_delta actual, expected, 0.001
    end

    test "should use default agent_reputation of 0.5" do
      # No :agent_reputation opt → defaults to 0.5.
      # Craft a solution where every other component is deterministic.
      now = ~U[2026-01-01 12:00:00Z]

      solution = %{
        solution_content: "x",
        language: "elixir",
        verification: %{status: "passed"},
        updated_at: DateTime.to_iso8601(days_ago(1, now))
      }

      score_default = Trust.compute(solution, now: now)
      score_explicit = Trust.compute(solution, now: now, agent_reputation: 0.5)

      assert_in_delta score_default, score_explicit, 0.000_01
    end

    test "should accept custom agent_reputation via opts" do
      now = ~U[2026-01-01 12:00:00Z]

      solution = %{
        solution_content: "x",
        language: "elixir",
        verification: %{status: "passed"},
        updated_at: DateTime.to_iso8601(days_ago(1, now))
      }

      score_low = Trust.compute(solution, now: now, agent_reputation: 0.0)
      score_high = Trust.compute(solution, now: now, agent_reputation: 1.0)

      # Difference must equal the weight of the reputation component (0.15).
      assert_in_delta score_high - score_low, 0.15, 0.000_01
    end
  end

  # ---------------------------------------------------------------------------
  # verification_score/1
  # ---------------------------------------------------------------------------

  describe "verification_score/1" do
    test "should return 0.3 for nil verification" do
      assert Trust.verification_score(%{verification: nil}) == 0.3
    end

    test "should return 0.3 for empty map" do
      assert Trust.verification_score(%{verification: %{}}) == 0.3
    end

    test "should return 0.3 when verification key is absent" do
      assert Trust.verification_score(%{solution_content: "x"}) == 0.3
    end

    test "should return 1.0 for %{status: \"passed\"}" do
      assert Trust.verification_score(%{verification: %{status: "passed"}}) == 1.0
    end

    test "should return 1.0 for %{\"status\" => \"passed\"} (string keys)" do
      assert Trust.verification_score(%{verification: %{"status" => "passed"}}) == 1.0
    end

    test "should return 0.0 for %{status: \"failed\"}" do
      assert Trust.verification_score(%{verification: %{status: "failed"}}) == 0.0
    end

    test "should return 0.0 for %{\"status\" => \"failed\"} (string keys)" do
      assert Trust.verification_score(%{verification: %{"status" => "failed"}}) == 0.0
    end

    test "should return partial score for %{status: \"partial\", passed: 3, total: 4}" do
      score =
        Trust.verification_score(%{
          verification: %{status: "partial", passed: 3, total: 4}
        })

      assert_in_delta score, 3 / 4, 0.000_01
    end

    test "should return partial score with string keys" do
      score =
        Trust.verification_score(%{
          verification: %{"status" => "partial", "passed" => 2, "total" => 5}
        })

      assert_in_delta score, 2 / 5, 0.000_01
    end

    test "should return 0.3 for unknown status" do
      assert Trust.verification_score(%{verification: %{status: "pending"}}) == 0.3
    end

    test "should return confidence * 0.85 for semi_formal with atom keys" do
      score =
        Trust.verification_score(%{
          verification: %{status: "semi_formal", confidence: 0.92}
        })

      assert_in_delta score, 0.92 * 0.85, 0.000_01
    end

    test "should return confidence * 0.85 for semi_formal with string keys" do
      score =
        Trust.verification_score(%{
          verification: %{"status" => "semi_formal", "confidence" => 0.92}
        })

      assert_in_delta score, 0.92 * 0.85, 0.000_01
    end

    test "should return 0.0 for semi_formal with confidence 0.0" do
      score =
        Trust.verification_score(%{
          verification: %{status: "semi_formal", confidence: 0.0}
        })

      assert score == 0.0
    end

    test "should return 0.85 for semi_formal with confidence 1.0" do
      score =
        Trust.verification_score(%{
          verification: %{status: "semi_formal", confidence: 1.0}
        })

      assert_in_delta score, 0.85, 0.000_01
    end

    test "should return confidence * 0.85 for semi_formal with confidence 0.5" do
      score =
        Trust.verification_score(%{
          verification: %{"status" => "semi_formal", "confidence" => 0.5}
        })

      assert_in_delta score, 0.5 * 0.85, 0.000_01
    end

    test "should fall through to catch-all 0.3 when semi_formal confidence is out of range" do
      score =
        Trust.verification_score(%{
          verification: %{status: "semi_formal", confidence: 1.5}
        })

      assert score == 0.3
    end

    test "should fall through to catch-all 0.3 when semi_formal confidence is negative" do
      score =
        Trust.verification_score(%{
          verification: %{status: "semi_formal", confidence: -0.1}
        })

      assert score == 0.3
    end
  end

  # ---------------------------------------------------------------------------
  # completeness_score/1
  # ---------------------------------------------------------------------------

  describe "completeness_score/1" do
    test "should return 0.3 for minimal solution (only required fields)" do
      assert Trust.completeness_score(minimal_solution()) == 0.3
    end

    test "should add 0.1 for framework present" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :framework, "phoenix"))

      assert_in_delta score, 0.4, 0.000_01
    end

    test "should add 0.1 for runtime present" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :runtime, "otp-26"))

      assert_in_delta score, 0.4, 0.000_01
    end

    test "should add 0.1 for non-empty tags" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :tags, ["elixir", "otp"]))

      assert_in_delta score, 0.4, 0.000_01
    end

    test "should not add bonus for empty tags list" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :tags, []))

      assert_in_delta score, 0.3, 0.000_01
    end

    test "should add 0.1 for agent_id present" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :agent_id, "agent-007"))

      assert_in_delta score, 0.4, 0.000_01
    end

    test "should add 0.15 for non-empty verification" do
      score =
        Trust.completeness_score(Map.put(minimal_solution(), :verification, %{status: "passed"}))

      assert_in_delta score, 0.45, 0.000_01
    end

    test "should not add bonus for empty verification map" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :verification, %{}))

      assert_in_delta score, 0.3, 0.000_01
    end

    test "should add 0.15 for non-local sharing" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :sharing, :shared))

      assert_in_delta score, 0.45, 0.000_01
    end

    test "should not add bonus for :local sharing" do
      score = Trust.completeness_score(Map.put(minimal_solution(), :sharing, :local))

      assert_in_delta score, 0.3, 0.000_01
    end

    test "should cap at 1.0 when all bonuses are present" do
      solution = %{
        solution_content: "x",
        language: "elixir",
        framework: "phoenix",
        runtime: "otp-26",
        tags: ["elixir"],
        agent_id: "agent-1",
        verification: %{status: "passed"},
        sharing: :public
      }

      # base 0.3 + 0.10 + 0.10 + 0.10 + 0.10 + 0.15 + 0.15 = 1.0 (exactly, no clamp needed)
      assert Trust.completeness_score(solution) == 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # freshness_score/2
  # ---------------------------------------------------------------------------

  describe "freshness_score/2" do
    setup do
      {:ok, now: ~U[2026-01-01 12:00:00Z]}
    end

    test "should return 1.0 for solutions updated today", %{now: now} do
      solution = %{updated_at: DateTime.to_iso8601(days_ago(0, now))}

      assert Trust.freshness_score(solution, now) == 1.0
    end

    test "should return 1.0 for solutions updated 3 days ago", %{now: now} do
      solution = %{updated_at: DateTime.to_iso8601(days_ago(3, now))}

      assert Trust.freshness_score(solution, now) == 1.0
    end

    test "should return < 1.0 for solutions updated 30 days ago", %{now: now} do
      solution = %{updated_at: DateTime.to_iso8601(days_ago(30, now))}
      score = Trust.freshness_score(solution, now)

      assert score < 1.0
      assert score > 0.0
    end

    test "should return 0.0 for solutions updated over 365 days ago", %{now: now} do
      solution = %{updated_at: DateTime.to_iso8601(days_ago(366, now))}

      assert Trust.freshness_score(solution, now) == 0.0
    end

    test "should return 0.0 for nil timestamp", %{now: now} do
      assert Trust.freshness_score(%{updated_at: nil}, now) == 0.0
    end

    test "should return 0.0 when no timestamp key is present", %{now: now} do
      assert Trust.freshness_score(%{solution_content: "x"}, now) == 0.0
    end

    test "should handle string ISO 8601 updated_at", %{now: now} do
      iso = DateTime.to_iso8601(days_ago(1, now))
      solution = %{updated_at: iso}

      assert Trust.freshness_score(solution, now) == 1.0
    end

    test "should handle DateTime struct as updated_at", %{now: now} do
      solution = %{updated_at: days_ago(1, now)}

      assert Trust.freshness_score(solution, now) == 1.0
    end

    test "should fall back to inserted_at when updated_at is absent", %{now: now} do
      solution = %{inserted_at: DateTime.to_iso8601(days_ago(2, now))}

      assert Trust.freshness_score(solution, now) == 1.0
    end

    test "should apply linear decay between 7 and 365 days", %{now: now} do
      age = 186
      solution = %{updated_at: DateTime.to_iso8601(days_ago(age, now))}
      score = Trust.freshness_score(solution, now)

      expected = 1.0 - (age - 7) / (365 - 7)

      assert_in_delta score, expected, 0.001
    end
  end
end
