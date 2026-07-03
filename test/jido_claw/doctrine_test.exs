defmodule JidoClaw.DoctrineTest do
  @moduledoc """
  Pure registry contract for `JidoClaw.Doctrine` (AR-5). No DB — slices are
  compile-time priv-file text and the template→slice map is in-code.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Doctrine

  describe "slice/1" do
    test "returns non-empty text for each known slice key" do
      for key <- [
            :base,
            :artifacts,
            :reviewer_min,
            :reviewer_contract,
            :system_verify,
            :fixer_contract,
            :emit_signals,
            :confidence_tagging,
            :tie_break,
            :challenger_contract,
            :code_doctrine
          ] do
        assert is_binary(Doctrine.slice(key))
        assert Doctrine.slice(key) != ""
      end
    end

    test "returns \"\" for an unknown key" do
      assert Doctrine.slice(:does_not_exist) == ""
    end

    test "list/0 enumerates exactly the seed slices" do
      assert Enum.sort(Doctrine.list()) == [
               :artifacts,
               :base,
               :challenger_contract,
               :code_doctrine,
               :confidence_tagging,
               :emit_signals,
               :fixer_contract,
               :reviewer_contract,
               :reviewer_min,
               :system_verify,
               :tie_break
             ]
    end
  end

  describe "for_template/1" do
    test "the coder gets base + artifacts + emit-signals (it self-reports), never the reviewer slice" do
      doctrine = Doctrine.for_template("coder")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      # AR-4: the coder (implementer + test-author) self-reports its completion
      # signals, so it carries the `:emit_signals` slice.
      assert doctrine =~ "Emitted signals"
      assert doctrine =~ "tests-ready"
      # AR-7: a non-reviewer worker carries the `:confidence_tagging` slice.
      assert doctrine =~ "Confidence tagging"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-4 fixer is a producing worker WITH its own fixer-contract (base + artifacts + fixer-contract)" do
      doctrine = Doctrine.for_template("fixer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Fixer Contract"
      assert doctrine =~ "self-report"
      # AR-7: a non-reviewer worker carries the `:confidence_tagging` slice.
      assert doctrine =~ "Confidence tagging"
      # It is a producer, not a judge — never the reviewer discipline.
      refute doctrine =~ "Review discipline"
    end

    test "a reviewer_verdict judge gets base + reviewer-min + reviewer-contract, never artifacts" do
      doctrine = Doctrine.for_template("reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      # AR-7: the reviewer family is EXCLUDED from the standalone slice — its
      # `reviewer_contract` already carries the equivalent per-finding tag (the
      # `=~ "likely"` above), so the header anchor must NOT appear.
      refute doctrine =~ "Confidence tagging"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the verifier is a judge WITHOUT the reviewer-contract (it has a different schema)" do
      doctrine = Doctrine.for_template("verifier")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      refute doctrine =~ "Reviewer Contract"
      # AR-7: the verifier gets the prose slice (prose-only — its flat
      # verdict/confidence/reasoning schema is unchanged), unlike the reviewer family.
      assert doctrine =~ "Confidence tagging"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-8b-2 sketch_reviewer is a reviewer_verdict judge (base + reviewer-min + contract)" do
      doctrine = Doctrine.for_template("sketch_reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      # AR-7: reviewer family — excluded from the standalone slice.
      refute doctrine =~ "Confidence tagging"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-8b-2 F2 sketch_build_exec is a producing worker (base + artifacts)" do
      doctrine = Doctrine.for_template("sketch_build_exec")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      # AR-7: a non-reviewer worker carries the `:confidence_tagging` slice.
      assert doctrine =~ "Confidence tagging"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-8c system_executor is a producing worker (base + artifacts)" do
      doctrine = Doctrine.for_template("system_executor")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      # AR-7: a non-reviewer worker carries the `:confidence_tagging` slice.
      assert doctrine =~ "Confidence tagging"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-8c system_verifier is a judge with the reviewer-contract + system-verify slices" do
      doctrine = Doctrine.for_template("system_verifier")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      assert doctrine =~ "System verification discipline"
      # AR-7: reviewer family — excluded from the standalone slice.
      refute doctrine =~ "Confidence tagging"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-7 researcher carries the confidence-tagging slice (base + artifacts + emit-signals + confidence-tagging)" do
      doctrine = Doctrine.for_template("researcher")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Emitted signals"
      # AR-7: the researcher is the one non-reviewer worker with a STRUCTURAL
      # per-finding tag; it also carries the prose slice, including the unique
      # source-URL rule. Both anchors are absent from `reviewer_contract`.
      assert doctrine =~ "Confidence tagging"
      assert doctrine =~ "Source your web claims"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-9 plan_arbiter is a producing adjudicator (base + artifacts + tie-break)" do
      doctrine = Doctrine.for_template("plan_arbiter")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Plan arbitration"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Confidence tagging"
      # A selector over plans, not a code judge — never the reviewer discipline.
      refute doctrine =~ "Review discipline"
    end

    test "the AR-9 plan_challenger carries the critique-only contract" do
      doctrine = Doctrine.for_template("plan_challenger")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Plan critique"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Confidence tagging"
      # Its critique lists are NOT the reviewer_verdict shape — never that contract.
      refute doctrine =~ "Reviewer Contract"
    end

    test "the AR-9 plan_drafter NEVER carries the emit-signals slice (deviation c)" do
      doctrine = Doctrine.for_template("plan_drafter")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Confidence tagging"
      # The `emit_signals` slice instructs emitting `plan-ready` when a plan is
      # drafted — undeclared on a lens stage under strict emit checking, so the
      # drafter's prompt surface must never carry that anchor.
      refute doctrine =~ "Emitted signals"
      refute doctrine =~ "plan-ready"
      refute doctrine =~ "Review discipline"
    end

    test "item 4: coder/fixer/refactorer carry the code-doctrine slice; judges and non-code producers do not" do
      for template <- ~w(coder fixer refactorer) do
        assert Doctrine.for_template(template) =~ "Code craft",
               "#{template} should carry the code_doctrine slice"
      end

      for template <- ~w(reviewer researcher) do
        refute Doctrine.for_template(template) =~ "Code craft",
               "#{template} should NOT carry the code_doctrine slice"
      end
    end

    test "\"main\" maps to no doctrine (it uses Prompt — doctrine never double-applies)" do
      assert Doctrine.for_template("main") == ""
    end

    test "an unmapped template maps to no doctrine" do
      assert Doctrine.for_template("totally_unknown_template") == ""
    end
  end

  describe "registry-drift guard" do
    test "every doctrine template is a real agent template" do
      assert Enum.all?(Doctrine.template_names(), &Templates.exists?/1)
    end

    test "the doctrine template set equals the worker template set" do
      # A future worker added without a doctrine mapping (or vice versa) fails here.
      # "main" is intentionally absent from both (it is not a worker template).
      assert Enum.sort(Doctrine.template_names()) == Enum.sort(Templates.names())
      refute "main" in Doctrine.template_names()
    end
  end
end
