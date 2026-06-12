defmodule JidoClaw.Tools.OutputShaper.MixTestTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputShaper.MixTest, as: Parser

  @budget 24 * 1024

  defp failure_block(n, name, file_line) do
    """
      #{n}) test #{name} (MyApp.FooTest)
         #{file_line}
         ** (MatchError) no match of right hand side value: nil
         code: assert {:ok, _} = run(nil)
         stacktrace:
           #{file_line}: (test)
    """
  end

  describe "classic format (Elixir <= 1.19)" do
    test "all-pass output collapses to a counts-only header" do
      text = """
      Running ExUnit with seed: 12345, max_cases: 16

      #{String.duplicate(".", 311)}

      Finished in 4.2 seconds (2.1s async, 2.1s sync)
      311 tests, 0 failures

      Randomized with seed 12345
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)

      assert parsed.body ==
               "mix test — 311 passed, 0 failed (Finished in 4.2 seconds, seed 12345)"

      assert parsed.compressed?
      assert parsed.summary.passed == 311
      assert parsed.summary.failed == 0
      assert parsed.summary.failures == []
      assert parsed.summary.seed == "12345"
    end

    test "failures are kept verbatim with counts and lean summary entries" do
      text = """
      Running ExUnit with seed: 999, max_cases: 16

      ......

      #{failure_block(1, "handles nil", "test/foo_test.exs:42")}
      ....

      #{failure_block(2, "handles empty", "test/foo_test.exs:77")}

      Finished in 1.0 seconds (0.5s async, 0.5s sync)
      8 tests, 2 failures
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)

      assert parsed.body =~ "mix test — 6 passed, 2 failed"
      # Verbatim blocks, including code/stacktrace lines.
      assert parsed.body =~ "1) test handles nil (MyApp.FooTest)"
      assert parsed.body =~ "code: assert {:ok, _} = run(nil)"
      assert parsed.body =~ "2) test handles empty (MyApp.FooTest)"
      # Progress dots between blocks are not carried into the body.
      refute parsed.body =~ "......"

      assert [f1, f2] = parsed.summary.failures
      assert f1.test == "test handles nil (MyApp.FooTest)"
      assert f1.location == "test/foo_test.exs:42"
      assert f1.error =~ "** (MatchError)"
      assert f2.location == "test/foo_test.exs:77"
    end

    test "doctest/property/invalid/skipped/excluded variants normalize counts" do
      text = """
      ....
      Finished in 0.3 seconds (0.1s async, 0.2s sync)
      3 doctests, 2 properties, 20 tests, 0 failures, 1 invalid, 2 skipped, 4 excluded
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      # 25 total - 1 invalid - 2 skipped - 4 excluded = 18 passed
      assert parsed.summary.passed == 18
      assert parsed.summary.invalid == 1
      assert parsed.summary.skipped == 2
      assert parsed.body =~ "18 passed, 0 failed, 1 invalid, 2 skipped, 4 excluded"
    end

    test "singular forms (1 test, 1 failure) parse" do
      text = """
      F
      #{failure_block(1, "only one", "test/one_test.exs:5")}
      Finished in 0.1 seconds (0.0s async, 0.1s sync)
      1 test, 1 failure
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      assert parsed.summary.passed == 0
      assert parsed.summary.failed == 1
    end
  end

  describe "Result: format (Elixir >= 1.20)" do
    test "all-pass with doctest breakdown" do
      text = """
      Running ExUnit with seed: 7, max_cases: 28

      .....

      Finished in 0.2 seconds (0.1s on load, 0.00s async, 0.03s sync)

      Result: 208 passed (207 doctests, 1 test), 1 skipped
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      assert parsed.summary.passed == 208
      assert parsed.summary.failed == 0
      assert parsed.summary.skipped == 1
      assert parsed.body =~ "mix test — 208 passed, 0 failed, 1 skipped"
    end

    test "P/T form derives failures with invalid/skipped/excluded extras" do
      text = """
      Running ExUnit with seed: 7, max_cases: 28

      *.
      #{failure_block(1, "fails one", "probe_test.exs:12")}
      Finished in 0.03 seconds (0.03s on load, 0.00s async, 0.00s sync)

      Result: 1/2 passed, 2 invalid, 1 skipped, 1 excluded
      Failed: 1 test
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      assert parsed.summary.passed == 1
      assert parsed.summary.failed == 1
      assert parsed.summary.invalid == 2
      assert parsed.summary.skipped == 1
      assert parsed.summary.seed == "7"
      assert parsed.body =~ "1) test fails one (MyApp.FooTest)"
    end

    test "assertion-style failures get the first message line as error" do
      text = """
      Running ExUnit with seed: 7, max_cases: 28

        1) test fails two (ProbeTest)
           probe_test.exs:16
           Assertion with == failed
           code:  assert 1 + 1 == 3
           left:  2
           right: 3
           stacktrace:
             probe_test.exs:17: (test)

      Finished in 0.03 seconds (0.00s async, 0.03s sync)

      Result: 0/1 passed
      Failed: 1 test
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      assert [failure] = parsed.summary.failures
      assert failure.error == "Assertion with == failed"
      assert failure.location == "probe_test.exs:16"
    end
  end

  describe "honesty guards" do
    test "no summary line (upstream-truncated input) is :nomatch" do
      assert Parser.parse("........ partial run output, tail cut off", @budget) == :nomatch
    end

    test "failures reported but zero blocks parseable is :nomatch" do
      text = """
      garbled output without numbered blocks
      Finished in 1.0 seconds (0.5s async, 0.5s sync)
      5 tests, 2 failures
      """

      assert Parser.parse(text, @budget) == :nomatch
    end

    test "never claims compression when the body would not shrink" do
      # Tiny output where header + block ≈ original size.
      text = """
      #{failure_block(1, "x", "t.exs:1")}
      1 test, 1 failure
      """

      assert {:ok, parsed} = Parser.parse(text, @budget)
      refute parsed.compressed?
    end
  end

  describe "failures budget" do
    test "blocks beyond the budget collapse into a count line" do
      blocks =
        Enum.map_join(1..6, "\n", fn n ->
          failure_block(n, "case #{n}", "test/budget_test.exs:#{n}")
        end)

      text = """
      ......
      #{blocks}
      Finished in 2.0 seconds (1.0s async, 1.0s sync)
      10 tests, 6 failures
      """

      # Each block is ~200 bytes; budget of 500 keeps 2 blocks.
      assert {:ok, parsed} = Parser.parse(text, 500)

      assert parsed.body =~ "1) test case 1"
      assert parsed.body =~ "2) test case 2"
      refute parsed.body =~ "3) test case 3"
      assert parsed.body =~ "...and 4 more failures"
      # The lean summary still indexes ALL failures (for the delta).
      assert Enum.count(parsed.summary.failures) == 6
    end

    test "the first block is always kept even when it alone exceeds the budget" do
      huge_block = """
        1) test enormous (MyApp.BigTest)
           test/big_test.exs:1
           ** (RuntimeError) #{String.duplicate("x", 2_000)}
      """

      text = """
      #{huge_block}
      Finished in 1.0 seconds (0.5s async, 0.5s sync)
      2 tests, 1 failure
      """

      assert {:ok, parsed} = Parser.parse(text, 100)
      assert parsed.body =~ "1) test enormous"
    end
  end
end
