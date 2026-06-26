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
            :emit_signals
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
               :emit_signals,
               :fixer_contract,
               :reviewer_contract,
               :reviewer_min,
               :system_verify
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
      refute doctrine =~ "Review discipline"
    end

    test "the AR-4 fixer is a producing worker WITH its own fixer-contract (base + artifacts + fixer-contract)" do
      doctrine = Doctrine.for_template("fixer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      assert doctrine =~ "Fixer Contract"
      assert doctrine =~ "self-report"
      # It is a producer, not a judge — never the reviewer discipline.
      refute doctrine =~ "Review discipline"
    end

    test "a reviewer_verdict judge gets base + reviewer-min + reviewer-contract, never artifacts" do
      doctrine = Doctrine.for_template("reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the verifier is a judge WITHOUT the reviewer-contract (it has a different schema)" do
      doctrine = Doctrine.for_template("verifier")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      refute doctrine =~ "Reviewer Contract"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-8b-2 sketch_reviewer is a reviewer_verdict judge (base + reviewer-min + contract)" do
      doctrine = Doctrine.for_template("sketch_reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-8b-2 F2 sketch_build_exec is a producing worker (base + artifacts)" do
      doctrine = Doctrine.for_template("sketch_build_exec")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-8c system_executor is a producing worker (base + artifacts)" do
      doctrine = Doctrine.for_template("system_executor")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      refute doctrine =~ "Review discipline"
    end

    test "the AR-8c system_verifier is a judge with the reviewer-contract + system-verify slices" do
      doctrine = Doctrine.for_template("system_verifier")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      assert doctrine =~ "Reviewer Contract"
      assert doctrine =~ "likely"
      assert doctrine =~ "System verification discipline"
      refute doctrine =~ "Runtime artifacts"
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
