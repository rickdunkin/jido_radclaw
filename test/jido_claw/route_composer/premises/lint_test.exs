defmodule JidoClaw.RouteComposer.Premises.LintTest do
  @moduledoc """
  The ported GradeGate battery — edge cases anchored to ouroboros's own tests
  (`tests/unit/auto/test_ledger_grading_answerer.py` @ e905a41c; see
  `docs/exploration/ouroboros/PORT-OB1-2.md` for the row-by-row mapping).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Premises.Lint

  defp criteria(list), do: %{"acceptance_criteria" => list}

  defp codes(entries), do: Enum.map(entries, & &1.code)

  defp open_required_item(question) do
    %{"question" => question, "status" => "open", "user_input_required" => true}
  end

  describe "observable/vague scans (grading.py:474-498)" do
    # test_grade_gate_accepts_observable_seed_with_ready_ledger (:234)
    test "a concrete observable criterion passes clean (grade :a)" do
      report =
        Lint.run(criteria(["`habit list` prints stable stdout containing created habits"]))

      assert report == %{grade: :a, blockers: [], findings: [], advisories: []}
    end

    # test_grade_gate_requires_observable_acceptance_behavior_not_keywords (:285)
    test "hint keywords alone don't pass — both criteria fire untestable" do
      report =
        Lint.run(criteria(["The command uses clean architecture", "The API is maintainable"]))

      assert report.grade == :b

      assert codes(report.findings) == [
               "untestable_acceptance_criteria",
               "untestable_acceptance_criteria"
             ]
    end

    # test_grade_gate_rejects_vacuous_coding_command_acceptance_criteria (:322)
    test "command-shaped wording without a concrete observation fires per-index targets" do
      report =
        Lint.run(
          criteria(["The command exits", "The command reports success", "The command passes"])
        )

      assert report.grade == :b

      untestable =
        Enum.filter(report.findings, &(&1.code == "untestable_acceptance_criteria"))

      assert Enum.map(untestable, & &1.target) == ["AC1", "AC2", "AC3"]
    end

    # test_grade_gate_rejects_vague_acceptance_criteria (:385)
    test "vague terms fire vague_acceptance_criteria" do
      report = Lint.run(criteria(["The CLI should be easy and user-friendly"]))

      assert report.grade == :b
      assert "vague_acceptance_criteria" in codes(report.findings)
    end

    # test_grade_gate_accepts_exit_status_and_http_status_criteria (:1338)
    test "exit-status and http-status phrasings are observable" do
      report = Lint.run(criteria(["CLI exits 0 on success", "GET /health returns 200"]))

      assert report == %{grade: :a, blockers: [], findings: [], advisories: []}
    end

    test "vague and untestable are independent — one criterion can fire both" do
      report = Lint.run(criteria(["It should be robust"]))

      assert "vague_acceptance_criteria" in codes(report.findings)
      assert "untestable_acceptance_criteria" in codes(report.findings)
    end
  end

  describe "over-fragmentation advisory (grading.py:275-289)" do
    # test_grade_gate_flags_over_fragmented_acceptance_criteria (:2818)
    test "10 clean criteria fire the advisory without flipping the grade" do
      list =
        for index <- 1..10 do
          "`habit step#{index}` prints stable stdout containing step #{index} result"
        end

      report = Lint.run(criteria(list))

      assert codes(report.advisories) == ["over_fragmented_criteria"]
      assert report.grade == :a
      assert report.findings == []
    end

    # test_grade_gate_no_over_fragmentation_flag_for_normal_seed (:2843)
    test "a normal count fires no advisory" do
      report = Lint.run(criteria(["`habit list` prints stable stdout containing habits"]))
      assert report.advisories == []
    end
  end

  describe "missing/empty/meaningless criteria (map decision 1 + orca fold)" do
    test "missing criteria fire ONLY when a clarify loop ran" do
      # No clarify evidence: a triage-only launch without criteria is the
      # normal case, never a defect.
      assert Lint.run(%{"path" => "code"}, mode: :gate).findings == []

      # Clarify ran — the `:ledger` opt (the compose-time lint).
      clarify_report = Lint.run(%{"path" => "code"}, mode: :clarify, ledger: [])
      assert codes(clarify_report.findings) == ["missing_acceptance_criteria"]

      # Clarify ran — the premises fingerprint (`"ambiguity_score"`, always
      # composed by the clarify lane): the gate re-lint has no ledger.
      gate_report = Lint.run(%{"path" => "code", "ambiguity_score" => 0.1}, mode: :gate)
      assert codes(gate_report.findings) == ["missing_acceptance_criteria"]
    end

    test "a present-but-empty criteria list fires the orca empty finding" do
      report = Lint.run(criteria([]))
      assert codes(report.findings) == ["empty_acceptance_criteria"]
    end

    # orca briefing.rs:539-549 — the meaningless bank over the normalization.
    test "placeholder criteria fire meaningless_acceptance_criteria per item" do
      report = Lint.run(criteria(["TODO", "tbd", "N/A", "Acceptance criteria", "!!!"]))

      meaningless =
        Enum.filter(report.findings, &(&1.code == "meaningless_acceptance_criteria"))

      assert Enum.map(meaningless, & &1.target) == ["AC1", "AC2", "AC3", "AC4", "AC5"]
    end

    test "AC-quality findings NEVER become blockers, even in clarify mode" do
      report =
        Lint.run(criteria(["TODO", "vague and easy", "unobservable"]),
          mode: :clarify,
          ledger: []
        )

      assert report.blockers == []
      assert report.grade == :b
    end
  end

  describe "blocker-class checks + the mode split" do
    # test_grade_gate_blocks_high_ambiguity_seed (:1436)
    test "clarify mode: ambiguity > 0.20 is a blocker (grade :c)" do
      report = Lint.run(%{"ambiguity_score" => 0.45}, mode: :clarify, ledger: [])

      assert codes(report.blockers) == ["high_ambiguity_score"]
      assert report.grade == :c
    end

    test "the 0.20 boundary is exclusive — 0.20 passes, matching #8's pass gate" do
      assert Lint.run(%{"ambiguity_score" => 0.20}, mode: :clarify, ledger: []).blockers == []
      assert Lint.run(%{"ambiguity_score" => 0.2001}, mode: :clarify, ledger: []).blockers != []
    end

    # test_grade_gate_ledger_only_suppresses_high_ambiguity_blocker (:2669) —
    # the degraded arm of grading.py:214 (map decision (B): demote, keep visible).
    test "degraded premises demote the ambiguity blocker to a finding in clarify mode" do
      report =
        Lint.run(%{"ambiguity_score" => 0.45, "degraded" => true}, mode: :clarify, ledger: [])

      assert report.blockers == []
      assert "high_ambiguity_score" in codes(report.findings)
      assert report.grade == :b
    end

    # test_grade_gate_rejects_unresolved_ledger_even_with_clean_seed (:274)
    test "an unresolved user_input_required item is a ledger_open_gap blocker" do
      ledger = [open_required_item("Which auth provider should this use?")]

      report =
        Lint.run(criteria(["`mix test` passes"]), mode: :clarify, ledger: ledger)

      assert codes(report.blockers) == ["ledger_open_gap"]
      assert report.grade == :c
    end

    test "unresolved NON-required items are findings, never blockers" do
      ledger = [
        %{
          "question" => "Repo-discoverable detail?",
          "status" => "open",
          "user_input_required" => false
        }
      ]

      report = Lint.run(%{}, mode: :clarify, ledger: ledger)

      assert report.blockers == []
    end

    test "degraded premises demote ledger_open_gap (the post-ack compose, map decision (B))" do
      ledger = [open_required_item("Which auth provider should this use?")]

      report = Lint.run(%{"degraded" => true}, mode: :clarify, ledger: ledger)

      assert report.blockers == []
      assert "ledger_open_gap" in codes(report.findings)
    end

    # test_grade_gate_blocks_high_risk_auto_fill_inference (:1408)
    test "an assumed item with risky content is a single high_risk_assumptions blocker" do
      ledger = [
        %{
          "question" => "How should deployment authenticate?",
          "status" => "assumed",
          "recommended_default_assumption" => "Use production credential for deployment"
        },
        %{
          "question" => "Which payment provider?",
          "status" => "assumed",
          "recommended_default_assumption" => "Assume the payment sandbox"
        }
      ]

      report = Lint.run(%{}, mode: :clarify, ledger: ledger)

      assert codes(report.blockers) == ["high_risk_assumptions"]
    end

    # test_grade_gate_ignores_inactive_high_risk_assumptions (:1385)
    test "risky text on a non-assumed item never fires the high-risk blocker" do
      ledger = [
        %{
          "question" => "Production database?",
          "status" => "open",
          "user_input_required" => false,
          "recommended_default_assumption" => "Use production credential"
        }
      ]

      report = Lint.run(%{}, mode: :clarify, ledger: ledger)

      refute "high_risk_assumptions" in codes(report.blockers)
    end

    # test_grade_seed_allows_safe_product_delete_assumptions (:1313)
    test "a safe assumed default fires nothing" do
      ledger = [
        %{
          "question" => "Can users delete their own tasks?",
          "status" => "assumed",
          "recommended_default_assumption" =>
            "Users can delete their own tasks after confirmation"
        }
      ]

      report =
        Lint.run(criteria(["`task delete` prints stable stdout confirming deletion"]),
          mode: :clarify,
          ledger: ledger
        )

      assert report == %{grade: :a, blockers: [], findings: [], advisories: []}
    end

    test "the question is the fallback scan text when the assumed default is blank" do
      ledger = [
        %{
          "question" => "Which production credential rotation policy?",
          "status" => "assumed",
          "recommended_default_assumption" => ""
        }
      ]

      report = Lint.run(%{}, mode: :clarify, ledger: ledger)

      assert codes(report.blockers) == ["high_risk_assumptions"]
    end
  end

  describe "gate mode never returns blockers (map decision 2, fail-closed)" do
    # The blocker-richest premises/ledger combination.
    defp blocker_rich do
      {%{"ambiguity_score" => 0.9},
       [
         open_required_item("Required unknown?"),
         %{
           "question" => "Auth?",
           "status" => "assumed",
           "recommended_default_assumption" => "Use production credential"
         }
       ]}
    end

    test "gate mode demotes every blocker-class hit to a finding" do
      {premises, ledger} = blocker_rich()

      report = Lint.run(premises, mode: :gate, ledger: ledger)

      assert report.blockers == []
      assert report.grade == :b

      # missing_acceptance_criteria rides along: the ambiguity fingerprint
      # says a clarify loop ran, and these premises carry no criteria.
      assert Enum.sort(codes(report.findings)) ==
               [
                 "high_ambiguity_score",
                 "high_risk_assumptions",
                 "ledger_open_gap",
                 "missing_acceptance_criteria"
               ]
    end

    test "an unknown or missing mode behaves exactly as :gate" do
      {premises, ledger} = blocker_rich()

      for opts <- [[ledger: ledger], [mode: :wat, ledger: ledger], [mode: nil, ledger: ledger]] do
        report = Lint.run(premises, opts)
        assert report.blockers == []
      end
    end

    test "is total over junk premises and junk ledger" do
      assert %{grade: :a} = Lint.run(nil)
      assert %{grade: :a} = Lint.run("junk", mode: :clarify, ledger: "junk")
      assert %{blockers: []} = Lint.run(%{"acceptance_criteria" => 42}, mode: :gate)
    end
  end

  describe "to_details/1 (the JSONB persistence form)" do
    test "a clean report is %{} — byte-identical gate details" do
      assert Lint.to_details(Lint.run(%{"path" => "code"})) == %{}
    end

    test "namespaces under premises_lint with string keys only" do
      report = Lint.run(criteria(["TODO"]))
      details = Lint.to_details(report)

      assert %{"premises_lint" => %{"grade" => "b", "findings" => findings, "advisories" => []}} =
               details

      assert Enum.all?(findings, fn entry ->
               is_binary(entry["code"]) and is_binary(entry["message"]) and
                 is_binary(entry["target"])
             end)
    end

    test "clips messages and caps entry counts" do
      long = String.duplicate("x", 5_000)
      report = Lint.run(criteria(List.duplicate(long, 40)))
      %{"premises_lint" => %{"findings" => findings}} = Lint.to_details(report)

      # No 17th entry survives the cap (length/1-vs-literal is a smell).
      assert Enum.drop(findings, 16) == []
      assert Enum.all?(findings, &(byte_size(&1["message"]) < 300))
    end

    test "blockers fold into the findings list (clarify-lane reports keep severity)" do
      report = Lint.run(%{"ambiguity_score" => 0.9}, mode: :clarify, ledger: [])
      %{"premises_lint" => %{"grade" => "c", "findings" => findings}} = Lint.to_details(report)

      assert Enum.any?(findings, &(&1["code"] == "high_ambiguity_score"))
    end

    test "advisory-only reports still emit (visibility without a grade flip)" do
      list =
        for index <- 1..10 do
          "`habit step#{index}` prints stable stdout containing step #{index} result"
        end

      %{"premises_lint" => %{"grade" => "a", "advisories" => advisories}} =
        Lint.to_details(Lint.run(criteria(list)))

      assert [_advisory] = advisories
    end
  end
end
