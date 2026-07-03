defmodule JidoClaw.Tools.LoopGuardIntegrationTest do
  @moduledoc """
  Full-pipeline LoopGuard tests: the guard driven through the generated
  `Tools.Action` wrapper (gate → guard → normalize → observe → redact →
  shape → cap), the halt envelope's non-retryability at BOTH retry layers
  (`Jido.Exec` and the ReAct `Jido.AI.Error` predicate, plus the live
  `Jido.AI.Turn` path), and the documented feed-boundary residuals pinned
  as behavior (classes 1 and 4).

  async: false — the guard is enabled via Application.put_env and state
  lives in the singleton Store (reset per test).
  """
  use JidoClaw.TenantCase, async: false

  # The Exec/Turn-driven fakes log their (expected) failures at :error.
  @moduletag capture_log: true

  alias Jido.AI.Error, as: ReactError
  alias Jido.AI.Turn
  alias JidoClaw.Agent.LoopGuard.Store

  # ── Inline tools (output_shaper_test pattern) ────────────────────────────

  # Guarded echo: the generated wrapper runs the full pipeline on whatever
  # `:result` the test hands it; `context[:notify]` counts body executions.
  defmodule FailingEcho do
    use JidoClaw.Tools.Action,
      name: "loop_guard_failing_echo",
      description: "Test-only guarded echo returning a canned result.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :failing_echo})
      result
    end
  end

  defmodule GatedEcho do
    use JidoClaw.Tools.Action,
      name: "loop_guard_gated_echo",
      description: "Test-only guarded echo for the approval-gate interplay.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :gated_echo})
      result
    end
  end

  # run_command-shaped echo: the real run_command returns an OK map with a
  # nonzero exit_code, not an error tuple.
  defmodule ExitCodeEcho do
    use JidoClaw.Tools.Action,
      name: "loop_guard_exit_code_echo",
      description: "Test-only guarded echo returning run_command-shaped results.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :exit_code_echo})
      result
    end
  end

  # MCP-proxy-shaped echo: generated proxies deliberately re-surface domain
  # failures as {:ok, %{"isError" => true, ...}} — mcp_-rooted name for
  # pipeline fidelity (the shaper's generic MCP path keys on it).
  defmodule McpErrorEcho do
    use JidoClaw.Tools.Action,
      name: "mcp_loop_guard_echo",
      description: "Test-only guarded echo returning MCP-proxy-shaped results.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :mcp_error_echo})
      result
    end
  end

  # Residual class 1: a required integer param so Jido.Exec's validation can
  # fail BEFORE run/2 — those attempts must never reach the guard.
  defmodule StrictParamsEcho do
    use JidoClaw.Tools.Action,
      name: "loop_guard_strict_params_echo",
      description: "Test-only guarded echo with a required integer param.",
      schema: [value: [type: :integer, required: true]]

    @impl Jido.Action
    def run(params, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :strict_params_echo})
      {:ok, %{value: params[:value]}}
    end
  end

  # Residual class 4: an output_schema so Jido.Exec's output validation can
  # fail AFTER run/2 returned {:ok, _} — the guard records a success while
  # the LLM sees an error.
  defmodule BadOutputEcho do
    use JidoClaw.Tools.Action,
      name: "loop_guard_bad_output_echo",
      description: "Test-only guarded echo whose output can violate its output_schema.",
      output_schema: [value: [type: :integer, required: true]],
      schema: [result: [type: :any, required: true], index: [type: :integer, default: 0]]

    @impl Jido.Action
    def run(%{result: result}, _context), do: result
  end

  # Bare Jido.Action fakes (NO pipeline) for the retry contract: they return
  # envelopes verbatim, so the tests isolate the envelope's retry posture.
  defmodule DoomEnvelopeTool do
    use Jido.Action,
      name: "loop_guard_doom_envelope_tool",
      description: "Test-only action returning the exact doom-loop halt envelope.",
      schema: []

    alias JidoClaw.Agent.LoopGuard
    alias JidoClaw.Agent.LoopGuard.KeyState

    @doc "The exact halt envelope the facade builds, via the public pure helpers."
    @spec doom_envelope() :: map()
    def doom_envelope do
      state = %KeyState{
        failure_sigs: List.duplicate({"edit_file", "old_string not found in lib/foo.ex"}, 3)
      }

      %{
        code: :doom_loop,
        message: LoopGuard.halt_message(:failure_signature, state, []),
        details: LoopGuard.halt_details(:failure_signature, state, [])
      }
    end

    @impl Jido.Action
    def run(_params, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :doom_tool})
      {:error, doom_envelope()}
    end
  end

  defmodule RetryableErrorTool do
    use Jido.Action,
      name: "loop_guard_retryable_error_tool",
      description: "Test-only action returning a code-only error map (no retry hint).",
      schema: []

    @impl Jido.Action
    def run(_params, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :retryable_tool})
      {:error, %{code: :some_error, message: "x", details: %{}}}
    end
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    original = Application.get_env(:jido_claw, :loop_guard, [])
    Application.put_env(:jido_claw, :loop_guard, Keyword.merge(original, enabled?: true))
    on_exit(fn -> Application.put_env(:jido_claw, :loop_guard, original) end)

    :ok = Store.reset()
    on_exit(fn -> Store.reset() end)

    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "loopguard")

    context = %{
      tool_context: %{
        tenant_id: tenant_id,
        session_uuid: session.id,
        session_id: "cli-loopguard",
        agent_template: "main"
      },
      notify: self()
    }

    {:ok, context: context, tenant_id: tenant_id}
  end

  defp failing_error(message) do
    {:error, %{code: :execution_error, message: message, details: %{}}}
  end

  defp mcp_result(error?, text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}}
  end

  # ── Staged failure-signature flow through the pipeline ──────────────────

  test "repeated failing calls: directive appended at each trigger, doom envelope after budget",
       %{context: context} do
    message = "old_string not found in lib/foo.ex"

    results =
      for i <- 1..9 do
        # Varied args (:index) so the identical-call check never fires; the
        # signature comes from the error text alone.
        FailingEcho.run(%{result: failing_error(message), index: i}, context)
      end

    # Calls 1-2, 4-5, 7-8: the error flows through untouched.
    for i <- [0, 1, 3, 4, 6, 7] do
      assert {:error, %{code: :execution_error, message: ^message}} = Enum.at(results, i)
    end

    # Calls 3 and 6: the recovery directive is appended to the message the
    # LLM reads (nudges #1 and #2).
    for i <- [2, 5] do
      assert {:error, %{code: :execution_error, message: nudged}} = Enum.at(results, i)
      assert String.starts_with?(nudged, message)
      assert nudged =~ "[DOOM LOOP RECOVERY: You tried loop_guard_failing_echo 3 times"
      assert nudged =~ "Do NOT call loop_guard_failing_echo with the same arguments again.]"
    end

    # Call 9 (3rd trigger): the doom envelope REPLACES the result — asserted
    # on the final piped value (survives normalize → observe → redact →
    # shape → cap).
    assert {:error, %{code: :doom_loop, message: halt_message, details: details}} =
             Enum.at(results, 8)

    assert halt_message =~ "I hit the same error 3 times with loop_guard_failing_echo"
    assert halt_message =~ "Do not retry; stop calling tools and summarize the current state."
    assert details.retry == false
    assert details.trigger == :failure_signature
    refute Map.has_key?(details, :reason)

    # All nine calls executed (failures are executions); the halt is sticky,
    # so call 10 is blocked pre-execution.
    for _i <- 1..9, do: assert_receive({:ran, :failing_echo})

    assert {:error, %{code: :doom_loop}} =
             FailingEcho.run(%{result: failing_error(message), index: 10}, context)

    refute_receive {:ran, :failing_echo}, 50
  end

  test "3-tuple error results keep their effects through nudge and halt", %{context: context} do
    message = "same effectful failure"

    results =
      for i <- 1..9 do
        result = {:error, %{code: :execution_error, message: message, details: %{}}, [:fx]}
        FailingEcho.run(%{result: result, index: i}, context)
      end

    assert {:error, %{message: nudged}, [:fx]} = Enum.at(results, 2)
    assert nudged =~ "[DOOM LOOP RECOVERY:"

    assert {:error, %{code: :doom_loop, details: %{trigger: :failure_signature}}, [:fx]} =
             Enum.at(results, 8)
  end

  # ── Identical-call halt through the pipeline ─────────────────────────────

  test "4 identical calls: exactly 3 executions, the 4th is blocked pre-execution",
       %{context: context} do
    handler_id = "loop-guard-integration-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:jido_claw, :loop_guard], [:jido_claw, :guardrail, :event]],
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    params = %{result: {:ok, %{listing: ["a.ex"]}}}

    for _i <- 1..3 do
      assert {:ok, %{listing: ["a.ex"]}} = FailingEcho.run(params, context)
      assert_receive {:ran, :failing_echo}
    end

    assert {:error, %{code: :doom_loop, message: halt_message, details: details}} =
             FailingEcho.run(params, context)

    refute_receive {:ran, :failing_echo}, 50

    assert halt_message =~
             "tool `loop_guard_failing_echo` was called with identical arguments 4 times in a row"

    assert details ==
             %{
               retry: false,
               trigger: :identical_repeat,
               tool: "loop_guard_failing_echo",
               repeats: 4
             }

    # Sticky: a DIFFERENT call on the same key is blocked too.
    assert {:error, %{code: :doom_loop}} =
             FailingEcho.run(%{result: {:ok, %{}}, other: true}, context)

    refute_receive {:ran, :failing_echo}, 50

    # Observability: the telemetry rollup and the :guardrail Trace channel
    # both saw the halt.
    assert_receive {:telemetry, [:jido_claw, :loop_guard], %{total: 1},
                    %{event: :halt, trigger: :identical_repeat, tool: "loop_guard_failing_echo"}}

    assert_receive {:telemetry, [:jido_claw, :guardrail, :event], _measurements,
                    %{guardrail: "loop_guard", event: :halt, trigger: :identical_repeat}}
  end

  # ── run_command nonzero-exit OK shape ────────────────────────────────────

  test "nonzero-exit OK results accumulate signatures; the directive lands in :output",
       %{context: context} do
    output = "make: *** [target] Error 2"

    results =
      for i <- 1..3 do
        ExitCodeEcho.run(%{result: {:ok, %{exit_code: 2, output: output}}, index: i}, context)
      end

    assert [
             {:ok, %{exit_code: 2, output: ^output}},
             {:ok, %{exit_code: 2, output: ^output}},
             third
           ] =
             results

    # Still the OK shape (run_command's contract) — the directive is
    # appended to :output, the field the LLM reads, never :message.
    assert {:ok, %{exit_code: 2, output: nudged}} = third
    assert String.starts_with?(nudged, output)
    assert nudged =~ "[DOOM LOOP RECOVERY: You tried loop_guard_exit_code_echo 3 times"
  end

  test "exit_code 0 is a clean success and clears that tool's signatures",
       %{context: context} do
    output = "boom: build failed"

    for i <- 1..2 do
      ExitCodeEcho.run(%{result: {:ok, %{exit_code: 1, output: output}}, index: i}, context)
    end

    ExitCodeEcho.run(%{result: {:ok, %{exit_code: 0, output: "fixed"}}, index: 3}, context)

    # The two pre-success signatures are gone: two more failures stay quiet.
    for i <- 4..5 do
      assert {:ok, %{exit_code: 1, output: ^output}} =
               ExitCodeEcho.run(
                 %{result: {:ok, %{exit_code: 1, output: output}}, index: i},
                 context
               )
    end
  end

  # ── MCP isError OK shape (the generated-proxy domain-failure contract) ───

  test "repeated isError results accumulate signatures; the directive rides as a content item",
       %{context: context} do
    text = "GitHub API rate limit exceeded for installation"

    results =
      for i <- 1..9 do
        # Varied args (:index) so the identical-call check never fires; the
        # signature comes from the content text alone.
        McpErrorEcho.run(%{result: mcp_result(true, text), index: i}, context)
      end

    # Calls 1-2, 4-5, 7-8: the isError result flows through untouched.
    for i <- [0, 1, 3, 4, 6, 7] do
      assert {:ok, %{"isError" => true, "content" => [%{"text" => ^text}]}} =
               Enum.at(results, i)
    end

    # Calls 3 and 6 (nudges #1 and #2): the recovery directive is APPENDED
    # as a text content item after the error text — asserted on the final
    # piped result (survives normalize → observe → redact → shape → cap).
    for i <- [2, 5] do
      assert {:ok, %{"isError" => true, "content" => content}} = Enum.at(results, i)

      assert [%{"type" => "text", "text" => ^text}, %{"type" => "text", "text" => directive}] =
               content

      assert directive =~ "[DOOM LOOP RECOVERY: You tried mcp_loop_guard_echo 3 times"
      assert directive =~ "Do NOT call mcp_loop_guard_echo with the same arguments again.]"
    end

    # Call 9 (3rd trigger): the doom envelope REPLACES the result.
    assert {:error, %{code: :doom_loop, message: halt_message, details: details}} =
             Enum.at(results, 8)

    assert halt_message =~ "I hit the same error 3 times with mcp_loop_guard_echo"
    assert details.retry == false
    assert details.trigger == :failure_signature

    # All nine calls executed (isError results ARE executions); the halt is
    # sticky, so call 10 is blocked pre-execution.
    for _i <- 1..9, do: assert_receive({:ran, :mcp_error_echo})

    assert {:error, %{code: :doom_loop}} =
             McpErrorEcho.run(%{result: mcp_result(true, text), index: 10}, context)

    refute_receive {:ran, :mcp_error_echo}, 50
  end

  test "an isError result must not clear prior transport-error signatures for the same tool",
       %{context: context} do
    text = "connection refused"

    # Two transport-level failures ({:error, _} tuples) for the mcp_* tool.
    for i <- 1..2 do
      assert {:error, %{message: ^text}} =
               McpErrorEcho.run(%{result: failing_error(text), index: i}, context)
    end

    # The 3rd same-text failure arrives via the MCP domain contract. Pre-fix
    # it classified :success — clearing the two signatures above and
    # recording nothing; it must instead be the 3rd occurrence and nudge.
    assert {:ok, %{"isError" => true, "content" => content}} =
             McpErrorEcho.run(%{result: mcp_result(true, text), index: 3}, context)

    assert match?(
             [%{"text" => ^text}, %{"type" => "text", "text" => "[DOOM LOOP RECOVERY:" <> _}],
             content
           ),
           "3rd same-text failure must nudge — an isError result must not clear the window"
  end

  test "a genuine isError => false success still clears the tool's signatures",
       %{context: context} do
    text = "search index temporarily unavailable"

    for i <- 1..2 do
      McpErrorEcho.run(%{result: mcp_result(true, text), index: i}, context)
    end

    # A clean domain success clears mcp_loop_guard_echo's two signatures.
    assert {:ok, %{"isError" => false}} =
             McpErrorEcho.run(%{result: mcp_result(false, "2 results"), index: 3}, context)

    # The stale pair is gone: two more identical-text failures stay quiet
    # (without the clear, the first of these would have been the 3rd
    # occurrence and nudged).
    for i <- 4..5 do
      assert {:ok, %{"isError" => true, "content" => [%{"text" => ^text}]}} =
               McpErrorEcho.run(%{result: mcp_result(true, text), index: i}, context)
    end
  end

  # ── Approval-gate interplay ──────────────────────────────────────────────

  test "approval-gate errors never count toward the guard's windows", %{context: context} do
    approval_original = Application.get_env(:jido_claw, :tool_approval, [])

    Application.put_env(
      :jido_claw,
      :tool_approval,
      Keyword.merge(approval_original, enabled?: true, require: ["loop_guard_gated_echo"])
    )

    on_exit(fn -> Application.put_env(:jido_claw, :tool_approval, approval_original) end)

    params = %{result: {:ok, %{done: true}}}

    # Five identical gated calls: the gate short-circuits BEFORE the guard's
    # pre-execution check, and the approval envelope is skip-listed by
    # observe — so neither window records anything.
    for _i <- 1..5 do
      assert {:error, %{code: code}} = GatedEcho.run(params, context)
      assert code in [:approval_pending, :approval_denied, :approval_unavailable]
      refute_received {:ran, :gated_echo}
    end

    # Ungate: the same identical call must start from a CLEAN window — three
    # executions before the identical-call halt on the 4th. Had the five
    # gated calls counted, the very first ungated call would be blocked.
    Application.put_env(:jido_claw, :tool_approval, approval_original)

    for _i <- 1..3 do
      assert {:ok, %{done: true}} = GatedEcho.run(params, context)
      assert_receive {:ran, :gated_echo}
    end

    assert {:error, %{code: :doom_loop, details: %{trigger: :identical_repeat, repeats: 4}}} =
             GatedEcho.run(params, context)

    refute_receive {:ran, :gated_echo}, 50
  end

  # ── Retry contract (both layers) ─────────────────────────────────────────

  describe "retry contract" do
    test "(i) Jido.Exec never retries the doom envelope; a code-only map IS retried" do
      assert {:error, wrapped} =
               Jido.Exec.run(DoomEnvelopeTool, %{}, %{notify: self()},
                 max_retries: 2,
                 backoff: 1,
                 log_level: :error
               )

      assert is_exception(wrapped)
      assert_receive {:ran, :doom_tool}
      refute_receive {:ran, :doom_tool}, 100

      # Contrast — proves the live retry loop would catch a regression: the
      # same body without `details.retry: false` runs more than once.
      assert {:error, _wrapped} =
               Jido.Exec.run(RetryableErrorTool, %{}, %{notify: self()},
                 max_retries: 2,
                 backoff: 1,
                 log_level: :error
               )

      assert_receive {:ran, :retryable_tool}
      assert_receive {:ran, :retryable_tool}, 500
    end

    test "(ii) the raw envelope is non-retryable under the ReAct runner predicate" do
      refute ReactError.retryable?({:error, DoomEnvelopeTool.doom_envelope()})
      refute ReactError.retryable?({:error, DoomEnvelopeTool.doom_envelope(), []})
    end

    test "(iii) through Jido.AI.Turn.execute_module the wrapped error stays non-retryable" do
      result = Turn.execute_module(DoomEnvelopeTool, %{}, %{notify: self()})

      assert {:error, _wrapped, []} = result
      refute ReactError.retryable?(result)
      assert_receive {:ran, :doom_tool}
      refute_receive {:ran, :doom_tool}, 100
    end
  end

  # ── Feed-boundary residual pinning ───────────────────────────────────────

  describe "documented residuals" do
    test "class 1: param-validation failures never reach the guard's windows",
         %{context: context} do
      # Three valid identical calls — streak 3, one short of the halt.
      for _i <- 1..3 do
        assert {:ok, %{value: 7}} =
                 Jido.Exec.run(StrictParamsEcho, %{value: 7}, context, log_level: :error)

        assert_receive {:ran, :strict_params_echo}
      end

      # Five identical INVALID calls: Jido.Exec rejects them before run/2 —
      # the body never runs and (their digest differing from the valid one)
      # they would BREAK the streak if the guard saw them.
      for _i <- 1..5 do
        assert {:error, error} =
                 Jido.Exec.run(StrictParamsEcho, %{value: "nope"}, context, log_level: :error)

        assert is_exception(error)
        assert inspect(error.__struct__) =~ "InvalidInput"
        refute_received {:ran, :strict_params_echo}
      end

      # The 4th valid identical call halts: the streak survived untouched,
      # proving the invalid attempts fed nothing (as documented).
      assert {:error, %{code: :doom_loop, details: %{trigger: :identical_repeat}}} =
               StrictParamsEcho.run(%{value: 7}, context)

      refute_receive {:ran, :strict_params_echo}, 50
    end

    test "class 4: an output-validation failure records a false success for that tool only",
         %{context: context} do
      t2_error = failing_error("bad output tool exploded the same way")
      t1_error = failing_error("old_string not found in lib/one.ex")

      # Two accumulated signatures each for T2 (BadOutputEcho) and T1
      # (FailingEcho) — both one short of the trigger.
      for i <- 1..2 do
        assert {:error, _reason} = BadOutputEcho.run(%{result: t2_error, index: i}, context)
        assert {:error, _reason} = FailingEcho.run(%{result: t1_error, index: i}, context)
      end

      # The bad-output call: run/2 returns {:ok, _} (the guard records a T2
      # SUCCESS and clears T2's signatures), then Jido.Exec's output
      # validation fails — the LLM sees an error the guard never saw.
      assert {:error, validation_error} =
               Jido.Exec.run(
                 BadOutputEcho,
                 %{result: {:ok, %{oops: true}}, index: 3},
                 context,
                 log_level: :error
               )

      assert is_exception(validation_error)

      # T2's window restarted (the false-success residual, as documented):
      # two more identical T2 failures stay quiet where the 3rd-in-a-row
      # would otherwise have nudged.
      for i <- 4..5 do
        assert {:error, %{message: message}} =
                 BadOutputEcho.run(%{result: t2_error, index: i}, context)

        refute message =~ "[DOOM LOOP RECOVERY:"
      end

      # T1's signatures were untouched by T2's false success (per-tool
      # clearing): the 3rd T1 failure nudges.
      assert {:error, %{message: nudged}} =
               FailingEcho.run(%{result: t1_error, index: 3}, context)

      assert nudged =~ "[DOOM LOOP RECOVERY: You tried loop_guard_failing_echo 3 times"
    end
  end
end
