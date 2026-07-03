defmodule JidoClaw.Agent.LoopGuardTest do
  @moduledoc """
  Pure-core LoopGuard tests: the sliding windows and staged recovery as
  properties (StreamData), plus units for signature build, typed
  classification, directive delivery, the suggestion table, and the halt
  message/details contract. Explicit opts throughout — env-free.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JidoClaw.Agent.LoopGuard
  alias JidoClaw.Agent.LoopGuard.KeyState

  @opts [
    repeat_threshold: 4,
    repeat_window: 8,
    failure_threshold: 3,
    failure_window: 20,
    max_calls: 100,
    warn_pct: 0.80,
    max_recoveries: 2,
    now: 1_000
  ]

  defp attempts(state, call_keys, opts \\ @opts) do
    Enum.map_reduce(call_keys, state, fn call_key, acc ->
      {verdict, acc} = LoopGuard.check_attempt(acc, call_key, opts)
      {verdict, acc}
    end)
  end

  defp failures(state, tool, text, count, opts \\ @opts) do
    Enum.map_reduce(1..count//1, state, fn _i, acc ->
      {verdict, acc} = LoopGuard.check_result(acc, {tool, true, text}, opts)
      {verdict, acc}
    end)
  end

  defp filler_failures(state, count, offset) do
    Enum.map_reduce(1..count//1, state, fn i, acc ->
      observation = {"other_tool", true, "unique filler error #{offset + i}"}
      {verdict, acc} = LoopGuard.check_result(acc, observation, @opts)
      {verdict, acc}
    end)
  end

  defp max_run([]), do: 0

  defp max_run(keys) do
    keys
    |> Enum.chunk_by(& &1)
    |> Enum.map(&length/1)
    |> Enum.max()
  end

  describe "failure-signature window (mechanism 2)" do
    property "(a) a clean success of a tool resets its own failure streak" do
      check all(
              k1 <- integer(0..2),
              k2 <- integer(0..2),
              text <- string(:printable, min_length: 1, max_length: 60)
            ) do
        {before_verdicts, seeded} = failures(%KeyState{}, "edit_file", text, k1)

        {success_verdict, cleared} =
          LoopGuard.check_result(seeded, {"edit_file", false, ""}, @opts)

        {after_verdicts, _state} = failures(cleared, "edit_file", text, k2)

        assert success_verdict == :ok
        assert Enum.all?(before_verdicts ++ after_verdicts, &(&1 == :ok))
      end
    end

    test "(a2) a T2 success never clears T1 signatures — the interleaved repair loop triggers" do
      text = "old_string not found in lib/foo.ex"

      {v1, state1} = LoopGuard.check_result(%KeyState{}, {"edit_file", true, text}, @opts)
      {ok1, state2} = LoopGuard.check_result(state1, {"read_file", false, ""}, @opts)
      {v2, state3} = LoopGuard.check_result(state2, {"edit_file", true, text}, @opts)
      {ok2, state4} = LoopGuard.check_result(state3, {"read_file", false, ""}, @opts)
      {v3, _state} = LoopGuard.check_result(state4, {"edit_file", true, text}, @opts)

      assert [v1, ok1, v2, ok2] == [:ok, :ok, :ok, :ok]

      assert match?({:nudge, _directive}, v3),
             "3rd edit_file failure must nudge despite interleaved read_file successes"
    end

    property "(c) failure signatures fire on non-adjacent 3-in-20" do
      check all(gap1 <- integer(0..5), gap2 <- integer(0..5)) do
        text = "Permission denied: /etc/shadow"

        {v1, state1} = LoopGuard.check_result(%KeyState{}, {"run_command", true, text}, @opts)
        {fill1, state2} = filler_failures(state1, gap1, 0)
        {v2, state3} = LoopGuard.check_result(state2, {"run_command", true, text}, @opts)
        {fill2, state4} = filler_failures(state3, gap2, gap1)
        {v3, _state} = LoopGuard.check_result(state4, {"run_command", true, text}, @opts)

        assert [v1, v2] == [:ok, :ok]
        assert Enum.all?(fill1 ++ fill2, &(&1 == :ok))
        assert match?({:nudge, _directive}, v3)
      end
    end

    test "(e) a nudge clears accumulated signatures — three fresh failures for the next trigger" do
      text = "command not found: frobnicate"
      {verdicts, state} = failures(%KeyState{}, "run_command", text, 3)

      assert match?([:ok, :ok, {:nudge, _}], verdicts)
      assert state.failure_sigs == []
      assert state.recovery_count == 1

      {verdicts2, _state} = failures(state, "run_command", text, 3)
      assert match?([:ok, :ok, {:nudge, _}], verdicts2)
    end

    test "(f) after max_recoveries nudges, the next trigger halts" do
      text = "No such file or directory: foo.txt"
      {verdicts, state} = failures(%KeyState{}, "read_file", text, 9)

      assert match?({:nudge, _}, Enum.at(verdicts, 2))
      assert match?({:nudge, _}, Enum.at(verdicts, 5))
      assert Enum.at(verdicts, 8) == {:halt, :failure_signature}
      assert state.halted == :failure_signature
      assert state.recovery_count == 2
    end

    test "the nudge directive carries the ported recovery text with remapped tool names" do
      {verdicts, _state} =
        failures(%KeyState{}, "edit_file", "old_string not found in lib/foo.ex", 3)

      assert [:ok, :ok, {:nudge, directive}] = verdicts
      assert directive =~ "[DOOM LOOP RECOVERY: You tried edit_file 3 times with the same error:"
      assert directive =~ "Call read_file on the target file"
      assert directive =~ "COMPLETELY DIFFERENT arguments"
      assert directive =~ "Do NOT call edit_file with the same arguments again.]"
    end
  end

  describe "identical-call window (mechanism 1)" do
    property "(b) A-B-A-B oscillation never trips the identical-call halt" do
      check all(pairs <- integer(4..12)) do
        keys =
          Enum.flat_map(1..pairs, fn _i -> [{"tool_a", "digest_a"}, {"tool_b", "digest_b"}] end)

        {verdicts, _state} = attempts(%KeyState{}, keys)
        assert Enum.all?(verdicts, &(&1 == :ok))
      end
    end

    property "(b) 4 truly consecutive identical calls always halt on the 4th" do
      prefix_gen = list_of(member_of([{"tool_x", "dx"}, {"tool_y", "dy"}]), max_length: 6)

      check all(prefix <- prefix_gen, max_run(prefix) < 4) do
        {prefix_verdicts, state} = attempts(%KeyState{}, prefix)
        assert Enum.all?(prefix_verdicts, &(&1 == :ok))

        {verdicts, halted} = attempts(state, List.duplicate({"repeat_tool", "dr"}, 4))
        assert verdicts == [:ok, :ok, :ok, {:halt, :identical_repeat}]
        assert halted.halted == :identical_repeat
      end
    end

    test "success-agnostic: attempts alone (no results recorded) trip the halt" do
      {verdicts, _state} = attempts(%KeyState{}, List.duplicate({"list_directory", "d"}, 4))
      assert verdicts == [:ok, :ok, :ok, {:halt, :identical_repeat}]
    end
  end

  describe "absolute call cap (mechanism 3)" do
    property "(d) exactly one :warn at trunc(max * warn_pct); the call after max halts" do
      check all(max_calls <- integer(5..40)) do
        opts = Keyword.merge(@opts, max_calls: max_calls)
        warn_at = trunc(max_calls * 0.80)
        keys = for i <- 1..(max_calls + 1), do: {"tool_#{i}", "digest_#{i}"}

        {verdicts, state} = attempts(%KeyState{}, keys, opts)
        {executed, [blocked]} = Enum.split(verdicts, max_calls)
        expected = for i <- 1..max_calls, do: if(i == warn_at, do: :warn, else: :ok)

        assert executed == expected
        assert blocked == {:halt, :call_cap}
        assert state.halted == :call_cap
        assert state.total_calls == max_calls, "the blocked call must not count as executed"
      end
    end
  end

  describe "sticky halt (g)" do
    property "a halted key halts every attempt and mutates nothing" do
      check all(
              reason <- member_of([:identical_repeat, :call_cap, :failure_signature]),
              tool <- member_of(["read_file", "run_command"])
            ) do
        state = %KeyState{halted: reason, halted_at: 500, last_activity: 400}

        {attempt_verdict, after_attempt} = LoopGuard.check_attempt(state, {tool, "d"}, @opts)
        assert attempt_verdict == {:halt, reason}
        assert after_attempt == state, "a blocked attempt must not refresh any timer"

        {result_verdict, after_result} = LoopGuard.check_result(state, {tool, true, "x"}, @opts)
        assert result_verdict == :ok
        assert after_result == state
      end
    end
  end

  describe "signature_text/1" do
    test "collapses whitespace, trims, and caps at 100 characters (idempotent)" do
      assert LoopGuard.signature_text("  a\n\n b\t\tc  ") == "a b c"

      long = String.duplicate("x", 150)
      capped = LoopGuard.signature_text(long)
      assert capped == String.duplicate("x", 100)
      assert LoopGuard.signature_text(capped) == capped
    end
  end

  describe "classify_result/2 (typed classification)" do
    test "error tuples classify as failures with the message text, effects tolerated" do
      reason = %{code: :execution_error, message: "boom", details: %{}}
      assert LoopGuard.classify_result({:error, reason}, %{}) == {:failure, "boom"}
      assert LoopGuard.classify_result({:error, reason, [:fx]}, %{}) == {:failure, "boom"}
    end

    test "nonzero exit_code is a failure; zero exit and plain ok shapes are successes" do
      assert LoopGuard.classify_result({:ok, %{exit_code: 1, output: "err text"}}, %{}) ==
               {:failure, "err text"}

      assert LoopGuard.classify_result({:ok, %{exit_code: 0, output: "fine"}}, %{}) == :success
      assert LoopGuard.classify_result({:ok, %{listing: []}}, %{}) == :success
      assert LoopGuard.classify_result({:ok, %{listing: []}, [:fx]}, %{}) == :success
    end

    test "blank nonzero-exit output falls back to exit status + printable digest prefix" do
      params = %{command: "silent-failure"}

      assert {:failure, text} =
               LoopGuard.classify_result({:ok, %{exit_code: 2, output: "  "}}, params)

      assert text =~ ~r/\Aexit status 2 \(args:[0-9a-f]{8}\)\z/

      assert LoopGuard.classify_result({:ok, %{exit_code: 2, output: ""}}, params) ==
               {:failure, text}

      assert {:failure, other} =
               LoopGuard.classify_result({:ok, %{exit_code: 2, output: ""}}, %{command: "x"})

      refute other == text, "different silent commands must not collide into one signature"
    end

    test "MCP isError OK shapes classify as failures with the joined content text" do
      output = %{
        "isError" => true,
        "content" => [
          %{"type" => "text", "text" => "rate limit exceeded"},
          %{"text" => "try again later"},
          %{"type" => "image", "data" => "abc"},
          "stray-non-map-item"
        ]
      }

      expected = {:failure, "rate limit exceeded try again later"}
      assert LoopGuard.classify_result({:ok, output}, %{}) == expected
      assert LoopGuard.classify_result({:ok, output, [:fx]}, %{}) == expected
    end

    test "blank/absent isError content falls back to the flag + printable digest prefix" do
      params = %{server: "github", query: "x"}

      assert {:failure, text} =
               LoopGuard.classify_result({:ok, %{"isError" => true, "content" => []}}, params)

      assert text =~ ~r/\AisError \(args:[0-9a-f]{8}\)\z/

      assert LoopGuard.classify_result({:ok, %{"isError" => true}}, params) == {:failure, text}

      assert LoopGuard.classify_result(
               {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "  "}]}},
               params
             ) == {:failure, text}

      assert {:failure, other} =
               LoopGuard.classify_result(
                 {:ok, %{"isError" => true, "content" => []}},
                 %{server: "other"}
               )

      refute other == text,
             "different silent isError failures must not collide into one signature"
    end

    test "isError false or non-boolean stays a success" do
      assert LoopGuard.classify_result({:ok, %{"isError" => false, "content" => []}}, %{}) ==
               :success

      assert LoopGuard.classify_result({:ok, %{"isError" => "true", "content" => []}}, %{}) ==
               :success

      assert LoopGuard.classify_result({:ok, %{"isError" => false}, [:fx]}, %{}) == :success
    end

    test "non-tuple / unknown shapes are skipped, not recorded as successes" do
      assert LoopGuard.classify_result(:weird, %{}) == :skip
      assert LoopGuard.classify_result("raw", %{}) == :skip
    end
  end

  describe "args_digest/1" do
    test "full 32-byte sha256, stable across map construction order" do
      pairs = for i <- 1..40, do: {"k#{i}", i}
      ascending = Map.new(pairs)
      descending = Map.new(Enum.reverse(pairs))

      digest = LoopGuard.args_digest(ascending)
      assert byte_size(digest) == 32
      assert digest == LoopGuard.args_digest(descending)
      refute digest == LoopGuard.args_digest(Map.put(ascending, "k1", 99))
    end
  end

  describe "append_directive/2 (shape-aware delivery)" do
    @directive "[DOOM LOOP RECOVERY: test directive]"

    test "appends to :message for error envelopes, preserving effects" do
      reason = %{code: :execution_error, message: "boom", details: %{}}

      assert {:error, %{message: message}} =
               LoopGuard.append_directive({:error, reason}, @directive)

      assert message == "boom\n\n" <> @directive

      assert {:error, %{message: message3}, [:fx]} =
               LoopGuard.append_directive({:error, reason, [:fx]}, @directive)

      assert message3 == "boom\n\n" <> @directive
    end

    test "appends to :output for the run_command nonzero-exit OK shape" do
      assert {:ok, %{exit_code: 2, output: output}} =
               LoopGuard.append_directive({:ok, %{exit_code: 2, output: "err"}}, @directive)

      assert output == "err\n\n" <> @directive

      assert {:ok, %{output: output3}, [:fx]} =
               LoopGuard.append_directive(
                 {:ok, %{exit_code: 2, output: "err"}, [:fx]},
                 @directive
               )

      assert output3 == "err\n\n" <> @directive
    end

    test "appends the directive as the LAST content item for the MCP isError shape" do
      original_item = %{"type" => "text", "text" => "rate limit exceeded"}
      result = %{"isError" => true, "content" => [original_item]}
      item = %{"type" => "text", "text" => @directive}

      assert {:ok, %{"isError" => true, "content" => content}} =
               LoopGuard.append_directive({:ok, result}, @directive)

      assert content == [original_item, item]

      assert {:ok, %{"content" => content3}, [:fx]} =
               LoopGuard.append_directive({:ok, result, [:fx]}, @directive)

      assert content3 == [original_item, item]
    end

    test "absent isError content becomes a one-item list; non-list content passes through" do
      assert {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => @directive}]}} =
               LoopGuard.append_directive({:ok, %{"isError" => true}}, @directive)

      malformed = {:ok, %{"isError" => true, "content" => "not-a-list"}}
      assert LoopGuard.append_directive(malformed, @directive) == malformed
    end

    test "unknown shapes pass through unchanged" do
      assert LoopGuard.append_directive(:weird, @directive) == :weird

      assert LoopGuard.append_directive({:error, %{code: :x}}, @directive) ==
               {:error, %{code: :x}}
    end
  end

  describe "build_suggestion/1 (the 8 OSA branches, tool names remapped)" do
    test "identical old/new" do
      suggestion = LoopGuard.build_suggestion("old_string and new_string are identical")
      assert suggestion =~ "already contains the change"
      assert suggestion =~ "read_file"
    end

    test "old_string not found (beats the generic not-found branch)" do
      suggestion = LoopGuard.build_suggestion("old_string not found in lib/foo.ex")
      assert suggestion =~ "doesn't exist in the file"
      assert suggestion =~ "read_file"
    end

    test "old_string found N times" do
      suggestion = LoopGuard.build_suggestion("old_string found 3 times in lib/foo.ex")
      assert suggestion =~ "appears multiple times"
      assert suggestion =~ "replace_all: true"
    end

    test "command not found" do
      suggestion = LoopGuard.build_suggestion("zsh: command not found: frobnicate")
      assert suggestion =~ "run_command(command: \"which <tool>\")"
    end

    test "permission denied" do
      suggestion = LoopGuard.build_suggestion("Permission denied: /etc/shadow")
      assert suggestion =~ "Check file permissions"
    end

    test "no such file" do
      suggestion = LoopGuard.build_suggestion("No such file or directory: foo.txt")
      assert suggestion =~ "search_code or list_directory"
    end

    test "blocked by permissions" do
      suggestion = LoopGuard.build_suggestion("Blocked: destination not allowed")
      assert suggestion =~ "different tool or approach"
    end

    test "fallback" do
      suggestion = LoopGuard.build_suggestion("some entirely novel failure")
      assert suggestion =~ "completely different approach"
      assert suggestion =~ "Do NOT retry the same operation"
    end
  end

  describe "halt_message/3 and halt_details/3" do
    defp halted_state do
      %KeyState{
        call_keys: List.duplicate({"read_file", "d"}, 4),
        failure_sigs: List.duplicate({"edit_file", "old_string not found in lib/foo.ex"}, 3),
        total_calls: 100
      }
    end

    test "details always carry retry: false and :trigger, never :reason" do
      for reason <- [:identical_repeat, :call_cap, :failure_signature] do
        details = LoopGuard.halt_details(reason, halted_state(), @opts)
        assert details.retry == false
        assert details.trigger == reason
        refute Map.has_key?(details, :reason)
      end
    end

    test "identical-repeat message names the tool and streak, plus the do-not-retry line" do
      message = LoopGuard.halt_message(:identical_repeat, halted_state(), @opts)
      assert message =~ "tool `read_file` was called with identical arguments 4 times in a row"
      assert message =~ "Do not retry; stop calling tools and summarize the current state."

      assert LoopGuard.halt_details(:identical_repeat, halted_state(), @opts) ==
               %{retry: false, trigger: :identical_repeat, tool: "read_file", repeats: 4}
    end

    test "cap message carries totals and the :loop_guard config pointer" do
      message = LoopGuard.halt_message(:call_cap, halted_state(), @opts)
      assert message =~ "session tool call limit (100/100)"
      assert message =~ "adjust `max_calls` under `config :jido_claw, :loop_guard`"
      assert message =~ "Do not retry; stop calling tools"

      assert LoopGuard.halt_details(:call_cap, halted_state(), @opts) ==
               %{retry: false, trigger: :call_cap, total_calls: 100, max_calls: 100}
    end

    test "signature message embeds the dominant signature and its targeted suggestion" do
      message = LoopGuard.halt_message(:failure_signature, halted_state(), @opts)

      assert message =~
               "I hit the same error 3 times with edit_file: old_string not found in lib/foo.ex"

      assert message =~ "doesn't exist in the file"
      assert message =~ "Do not retry; stop calling tools"

      assert LoopGuard.halt_details(:failure_signature, halted_state(), @opts) ==
               %{retry: false, trigger: :failure_signature, tool: "edit_file", occurrences: 3}
    end
  end
end
