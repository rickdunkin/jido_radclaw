defmodule JidoClaw.Orchestration.VerdictTest do
  @moduledoc """
  Camus C1-3 — the three-exit verdict normalizer. Table tests per exit-table
  row for both kinds, atom+string keys, totality over garbage inputs,
  findings-win, self-contradiction, non-routing pass-through, and the bounded
  `format_reason/1`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verdict

  describe "normalize(:review, _) — infra exits" do
    test "empty-output shapes" do
      for raw <- [nil, "", "   \n\t "] do
        assert Verdict.normalize(:review, raw) == {:infra, :empty_output}
      end
    end

    test "non-map shapes (numbers, lists, binary prose)" do
      for raw <- [42, [], ["a"], "looks good to me", :approve, {:ok, %{}}] do
        assert Verdict.normalize(:review, raw) == {:infra, :not_a_map}
      end
    end

    test "missing overall" do
      assert Verdict.normalize(:review, %{}) == {:infra, {:invalid_overall, nil}}
      assert Verdict.normalize(:review, %{"summary" => "x"}) == {:infra, {:invalid_overall, nil}}
    end

    test "out-of-enum overall (the drifted-reviewer case)" do
      assert Verdict.normalize(:review, %{"overall" => "maybe"}) ==
               {:infra, {:invalid_overall, "maybe"}}

      assert Verdict.normalize(:review, %{overall: :undecided}) ==
               {:infra, {:invalid_overall, :undecided}}

      # A non-atom/non-binary overall value never reaches to_string.
      assert Verdict.normalize(:review, %{"overall" => %{"v" => "approve"}}) ==
               {:infra, {:invalid_overall, %{"v" => "approve"}}}
    end

    test "findings present but not a list" do
      assert Verdict.normalize(:review, %{"overall" => "approve", "findings" => "none"}) ==
               {:infra, :findings_not_a_list}
    end

    test "a finding that is not a map" do
      raw = %{"overall" => "request_changes", "findings" => ["just a string"]}
      assert Verdict.normalize(:review, raw) == {:infra, :malformed_finding}
    end

    test "finding severity missing or out of enum refuses to demote" do
      missing = %{"overall" => "request_changes", "findings" => [%{"description" => "d"}]}
      assert Verdict.normalize(:review, missing) == {:infra, {:invalid_severity, nil}}

      critical = %{
        "overall" => "request_changes",
        "findings" => [%{"severity" => "critical", "description" => "d"}]
      }

      assert Verdict.normalize(:review, critical) == {:infra, {:invalid_severity, "critical"}}
    end

    test "non-approve with zero findings is a self-contradiction (both decisions)" do
      for decision <- ["request_changes", "comment"] do
        assert Verdict.normalize(:review, %{"overall" => decision, "findings" => []}) ==
                 {:infra, :self_contradiction}

        # Absent findings default to [] and still contradict a non-approve.
        assert Verdict.normalize(:review, %{"overall" => decision}) ==
                 {:infra, :self_contradiction}
      end
    end
  end

  describe "normalize(:review, _) — verdict exits" do
    @finding %{"severity" => "warning", "description" => "d", "location" => "l"}

    test "approve + [] is clean (atom and string keys)" do
      for raw <- [
            %{"overall" => "approve", "findings" => []},
            %{overall: :approve, findings: []},
            # Absent findings default to [].
            %{overall: :approve}
          ] do
        assert {:verdict, verdict} = Verdict.normalize(:review, raw)
        assert verdict.clean?
        assert verdict.decision == :approve
        assert verdict.findings == []
      end
    end

    test "approve + findings is NOT clean (findings-win)" do
      raw = %{"overall" => "approve", "findings" => [@finding]}
      assert {:verdict, verdict} = Verdict.normalize(:review, raw)
      refute verdict.clean?
      assert verdict.decision == :approve
      assert verdict.findings == [@finding]
    end

    test "non-approve + findings carries the findings" do
      raw = %{"overall" => "request_changes", "findings" => [@finding]}
      assert {:verdict, verdict} = Verdict.normalize(:review, raw)
      refute verdict.clean?
      assert verdict.decision == :request_changes
      assert verdict.findings == [@finding]
    end

    test "non-routing fields pass through unvalidated" do
      raw = %{
        "overall" => "request_changes",
        "summary" => "needs work",
        "action_needed" => 42,
        "findings" => [
          %{"severity" => "error", "confidence" => :bogus, "location" => %{}, "description" => 1}
        ]
      }

      assert {:verdict, verdict} = Verdict.normalize(:review, raw)
      assert verdict.summary == "needs work"
      assert [finding] = verdict.findings
      assert finding["confidence"] == :bogus
      assert verdict.source == raw
    end

    test "a non-binary summary passes through as nil" do
      raw = %{"overall" => "approve", "findings" => [], "summary" => %{"not" => "a string"}}
      assert {:verdict, %Verdict{summary: nil}} = Verdict.normalize(:review, raw)
    end
  end

  describe "normalize(:iterative_eval, _)" do
    test "typed maps, atom and string keys" do
      assert {:verdict, %Verdict{clean?: true, decision: :pass}} =
               Verdict.normalize(:iterative_eval, %{verdict: :pass})

      assert {:verdict, %Verdict{clean?: false, decision: :fail}} =
               Verdict.normalize(:iterative_eval, %{verdict: :fail})

      assert {:verdict, %Verdict{clean?: true, decision: :pass}} =
               Verdict.normalize(:iterative_eval, %{"verdict" => "pass"})

      assert {:verdict, %Verdict{clean?: false, decision: :fail}} =
               Verdict.normalize(:iterative_eval, %{"verdict" => "fail"})
    end

    test "legacy text verdicts, last token wins" do
      assert {:verdict, %Verdict{decision: :pass}} =
               Verdict.normalize(:iterative_eval, "VERDICT: PASS")

      assert {:verdict, %Verdict{decision: :fail}} =
               Verdict.normalize(:iterative_eval, "verdict: fail")

      assert {:verdict, %Verdict{decision: :fail}} =
               Verdict.normalize(:iterative_eval, "To get VERDICT: PASS, fix X.\nVERDICT: FAIL")
    end

    test "flipped rows: former silent-:fail inputs are now infra" do
      assert Verdict.normalize(:iterative_eval, "nothing here") ==
               {:infra, :no_verdict_token}

      assert Verdict.normalize(:iterative_eval, "") == {:infra, :empty_output}
      assert Verdict.normalize(:iterative_eval, nil) == {:infra, :empty_output}

      assert Verdict.normalize(:iterative_eval, %{verdict: :unknown}) ==
               {:infra, {:invalid_verdict, :unknown}}

      assert Verdict.normalize(:iterative_eval, %{}) == {:infra, {:invalid_verdict, nil}}
    end

    test "totality over garbage" do
      assert Verdict.normalize(:iterative_eval, 42) == {:infra, {:invalid_verdict, 42}}
      assert Verdict.normalize(:iterative_eval, []) == {:infra, {:invalid_verdict, []}}
    end
  end

  describe "format_reason/1" do
    test "bare atoms and tagged tuples" do
      assert Verdict.format_reason(:empty_output) == "empty_output"
      assert Verdict.format_reason({:invalid_overall, "maybe"}) == ~s(invalid_overall: "maybe")
    end

    test "a huge raw payload renders bounded" do
      huge = String.duplicate("x", 100_000)
      rendered = Verdict.format_reason({:invalid_overall, huge})
      assert String.length(rendered) < 400
    end

    test "a deep structured payload renders bounded" do
      deep = Enum.map(1..1_000, &%{"finding" => &1, "text" => String.duplicate("y", 500)})
      rendered = Verdict.format_reason({:invalid_severity, deep})
      assert String.length(rendered) < 400
    end

    test "total over non-tuple non-atom reasons" do
      assert is_binary(Verdict.format_reason(%{"unexpected" => true}))
    end
  end
end
