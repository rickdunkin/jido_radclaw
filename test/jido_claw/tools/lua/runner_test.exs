defmodule JidoClaw.Tools.Lua.RunnerTest do
  # async: false — the eval runs in an UNLINKED supervised task, and that
  # task performs the DB reads, so the Ecto sandbox must be in shared mode
  # (TenantCase's default for sync tests). Kill-path timing also makes
  # concurrency unwelcome here.
  use JidoClaw.TenantCase, async: false

  alias Jido.AI.Error, as: ReactError
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.Lua.Runner

  # Envelope-verbatim bare action (no pipeline) for the retry contract —
  # the loop_guard DoomEnvelopeTool pattern.
  defmodule LuaEnvelopeTool do
    use Jido.Action,
      name: "lua_runner_envelope_tool",
      description: "Test-only action returning a canned lua_query error envelope.",
      schema: []

    @impl Jido.Action
    def run(_params, context) do
      if is_pid(context[:notify]), do: send(context[:notify], {:ran, :lua_envelope_tool})
      {:error, context[:envelope]}
    end
  end

  setup do
    tenant_id = seed_tenant("lua-runner")
    {:ok, tenant_id: tenant_id, context: %{tool_context: %{tenant_id: tenant_id}}}
  end

  defp seed_run(tenant_id, name) do
    {:ok, run} =
      WorkflowRun.create(%{name: name, workflow_type: "audit"},
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    run
  end

  describe "success envelope" do
    test "pure computation returns results with an empty call audit", %{context: context} do
      assert {:ok, result} = Runner.eval("return 2 + 2", context)

      assert result == %{"results" => [4], "call_count" => 0, "calls" => []}
    end

    test "host calls are audited in the calls trace", %{tenant_id: tenant_id, context: context} do
      _run = seed_run(tenant_id, "audited")

      assert {:ok, result} =
               Runner.eval("return #jido.runs({limit = 5})", context)

      assert result["results"] == [1]
      assert result["call_count"] == 1
      assert [call] = result["calls"]
      assert call["binding"] == "jido.runs"
      assert call["status"] == "ok"
      assert call["output"] == %{"count" => 1}
    end
  end

  describe "pre-spawn gates" do
    test "empty and whitespace scripts refuse without spawning", %{context: context} do
      assert {:error, %{code: :lua_empty_script, details: %{retry: false}}} =
               Runner.eval("", context)

      assert {:error, %{code: :lua_empty_script}} = Runner.eval("  \n\t ", context)
    end

    test "oversize script refuses with sizes in the details", %{context: context} do
      script = "return 1 --" <> String.duplicate("x", 300)

      assert {:error, %{code: :lua_script_too_large, message: message, details: details}} =
               Runner.eval(script, context, max_script_bytes: 256)

      assert details.retry == false
      assert details.script_bytes == byte_size(script)
      assert details.max_script_bytes == 256
      assert message =~ "Do not retry unchanged"
    end

    test "a past turn deadline refuses before dispatch", %{context: context} do
      context = Map.put(context, :__jido_deadline_ms__, System.monotonic_time(:millisecond) - 5)

      assert {:error, %{code: :lua_deadline_exceeded, details: %{retry: false}}} =
               Runner.eval("return 1", context)
    end
  end

  describe "compile and runtime failures" do
    test "compile error", %{context: context} do
      assert {:error, %{code: :lua_compile_error, details: %{retry: false}}} =
               Runner.eval("return ((", context)
    end

    test "script-raised error", %{context: context} do
      assert {:error, %{code: :lua_runtime_error, message: message, details: details}} =
               Runner.eval(~s|error("boom from script")|, context)

      assert message =~ "boom from script"
      assert details.retry == false
    end

    test "sandboxed os.getenv raises (uncaught)", %{context: context} do
      assert {:error, %{code: :lua_runtime_error, message: message}} =
               Runner.eval(~s|return os.getenv("PATH")|, context)

      assert message =~ "sandboxed"
    end

    test "print is sandboxed post-new — model text can never reach host IO.puts",
         %{context: context} do
      # Uncaught on purpose: pcall could swallow the raise; the invariant
      # under test is that print NEVER executes (it would write straight
      # to host IO, bypassing the redaction boundary).
      assert {:error, %{code: :lua_runtime_error, message: message}} =
               Runner.eval(~s|print("leak me") return 1|, context)

      assert message =~ "sandboxed"
      assert message =~ "print"
    end

    test "debug is sandboxed post-new", %{context: context} do
      assert {:error, %{code: :lua_runtime_error}} =
               Runner.eval("return debug.traceback()", context)
    end

    test "the max_instructions budget bounds runaway CPU deterministically",
         %{context: context} do
      assert {:error, %{code: :lua_runtime_error, message: message}} =
               Runner.eval("while true do end", context,
                 max_instructions: 100_000,
                 timeout_ms: 5_000
               )

      assert message =~ "instruction budget exceeded"
    end
  end

  describe "kill paths" do
    test "wall-clock timeout kills the eval; non-retryable", %{context: context} do
      # Instruction budget raised so the wall clock, not the instruction
      # counter, is what fires (~100k instructions burn in single-digit ms).
      assert {:error, %{code: :lua_timeout, message: message, details: details}} =
               Runner.eval("while true do end", context,
                 max_instructions: 100_000_000,
                 timeout_ms: 200
               )

      assert details.retry == false
      assert details.timeout_ms == 200
      assert message =~ "Do not retry unchanged"
    end

    test "heap cap kills a memory bomb (small strings stay on-heap)", %{context: context} do
      # 300k 48-byte strings (< 64B ⇒ heap binaries, not refc) blow the
      # 64MiB cap well before the instruction budget or the wall clock.
      script = ~s|local t = {} for i = 1, 300000 do t[i] = string.rep("x", 48) end return #t|

      assert {:error, %{code: :lua_memory_exceeded, details: details}} =
               Runner.eval(script, context,
                 max_instructions: 100_000_000,
                 timeout_ms: 5_000
               )

      assert details.retry == false
      assert details.max_heap_bytes == 64 * 1024 * 1024
    end

    test "a kill leaves the call trace consistent", %{tenant_id: tenant_id, context: context} do
      _run = seed_run(tenant_id, "pre-kill")

      assert {:error, %{code: :lua_timeout, details: details}} =
               Runner.eval("jido.runs({limit = 1}) while true do end", context,
                 max_instructions: 100_000_000,
                 timeout_ms: 300
               )

      # The host call that completed before the kill is still counted.
      assert details.call_count == 1
    end
  end

  describe "call budget (post-eval, pcall-proof)" do
    test "the 13th host call under max_calls 12 fails the eval", %{
      tenant_id: tenant_id,
      context: context
    } do
      _run = seed_run(tenant_id, "budget")

      script = "for i = 1, 13 do jido.runs({limit = 1}) end return 'done'"

      assert {:error, %{code: :lua_call_budget_exceeded, message: message, details: details}} =
               Runner.eval(script, context)

      assert details.retry == false
      assert details.max_calls == 12
      assert details.call_count == 12
      assert message =~ "Do not retry unchanged"
    end

    test "a pcall-swallowed refusal still errors (refused? is not swallowable)", %{
      tenant_id: tenant_id,
      context: context
    } do
      _run = seed_run(tenant_id, "swallow")

      # The script wraps every call in pcall and "completes" fine — the
      # Runner overrides the successful result post-eval.
      script = """
      for i = 1, 13 do
        pcall(function() return jido.runs({limit = 1}) end)
      end
      return "ok"
      """

      assert {:error, %{code: :lua_call_budget_exceeded, details: %{retry: false}}} =
               Runner.eval(script, context)
    end
  end

  describe "aggregate result bound" do
    test "an oversized structured result errors (never silently capped)", %{context: context} do
      # Many small strings — the exact case OutputLimit's per-leaf trim
      # cannot bound.
      script = ~s|local t = {} for i = 1, 5000 do t[i] = string.rep("a", 20) end return t|

      assert {:error, %{code: :lua_result_too_large, message: message, details: details}} =
               Runner.eval(script, context)

      assert details.retry == false
      assert details.result_bytes > details.max_result_bytes
      assert details.max_result_bytes == 32_768
      assert message =~ "Do not retry unchanged"
    end

    test "a non-UTF-8 binary return is refused honestly", %{context: context} do
      assert {:error, %{code: :lua_result_not_encodable, details: %{retry: false}}} =
               Runner.eval("return string.char(200)", context)
    end
  end

  describe "retry contract (both layers)" do
    test "a runner envelope is never retried by Jido.Exec and is non-retryable under the ReAct predicate",
         %{context: context} do
      assert {:error, envelope} =
               Runner.eval("while true do end", context,
                 max_instructions: 100_000_000,
                 timeout_ms: 150
               )

      assert envelope.code == :lua_timeout

      assert {:error, wrapped} =
               Jido.Exec.run(LuaEnvelopeTool, %{}, %{notify: self(), envelope: envelope},
                 max_retries: 2,
                 backoff: 1,
                 log_level: :error
               )

      assert is_exception(wrapped)
      assert_receive {:ran, :lua_envelope_tool}
      refute_receive {:ran, :lua_envelope_tool}, 100

      refute ReactError.retryable?({:error, envelope})
    end
  end
end
