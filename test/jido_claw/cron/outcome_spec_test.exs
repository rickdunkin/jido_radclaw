defmodule JidoClaw.Cron.OutcomeSpecTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Cron.OutcomeSpec

  @valid %{
    end_state: "the digest email is sent",
    check: "the send API returned 200",
    stop_bound: "stop after 2 failed attempts"
  }

  @wire %{
    "end_state" => "the digest email is sent",
    "check" => "the send API returned 200",
    "stop_bound" => "stop after 2 failed attempts"
  }

  describe "normalize/1" do
    test "atom- and string-keyed maps normalize to the same trimmed wire form" do
      assert OutcomeSpec.normalize(@valid) == @wire
      assert OutcomeSpec.normalize(@wire) == @wire

      padded = %{@wire | "check" => "  the send API returned 200  "}
      assert OutcomeSpec.normalize(padded) == @wire
    end

    test "partial, blank, or junk values fail open to nil (no contract)" do
      assert OutcomeSpec.normalize(Map.delete(@wire, "check")) == nil
      assert OutcomeSpec.normalize(%{@wire | "end_state" => "  "}) == nil
      assert OutcomeSpec.normalize(%{@wire | "stop_bound" => 42}) == nil
      assert OutcomeSpec.normalize(nil) == nil
      assert OutcomeSpec.normalize("junk") == nil
      assert OutcomeSpec.normalize(%{}) == nil
    end
  end

  describe "validate/1 (the creation rules)" do
    test "a valid triple normalizes" do
      assert {:ok, @wire} = OutcomeSpec.validate(@valid)
    end

    test "each missing/blank field errors naming the field" do
      for field <- [:end_state, :check, :stop_bound] do
        assert {:error, message} = OutcomeSpec.validate(Map.delete(@valid, field))
        assert message =~ Atom.to_string(field)

        assert {:error, _} = OutcomeSpec.validate(Map.put(@valid, field, "   "))
      end

      assert {:error, _} = OutcomeSpec.validate(nil)
    end

    test "over-long fields error at the 500-char bound" do
      at_bound = Map.put(@valid, :check, String.duplicate("c", 500))
      assert {:ok, _} = OutcomeSpec.validate(at_bound)

      over = Map.put(@valid, :check, String.duplicate("c", 501))
      assert {:error, message} = OutcomeSpec.validate(over)
      assert message =~ "500"
    end

    test "check == end_state (case-insensitive) errors — a restated end state verifies nothing" do
      same = %{@valid | check: String.upcase(@valid.end_state)}
      assert {:error, message} = OutcomeSpec.validate(same)
      assert message =~ "must differ"
    end
  end

  describe "render_block/1" do
    test "nil renders empty — the absent-contract byte-identity carrier" do
      assert OutcomeSpec.render_block(nil) == ""
    end

    test "a spec renders the deterministic three-line contract" do
      assert OutcomeSpec.render_block(@wire) ==
               "[Outcome contract — the run succeeds ONLY if this is met]\n" <>
                 "End state: the digest email is sent\n" <>
                 "Check: the send API returned 200\n" <>
                 "Stop bound: stop after 2 failed attempts"
    end
  end
end
