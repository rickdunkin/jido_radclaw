defmodule JidoClaw.Tools.Lua.Runner do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error), and the success envelope is the
  # lua_query wire result — explicit API surfaces, not incidental
  # duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Lifecycle orchestration for one sandboxed `lua_query` eval.

  Hardening lifted from `Jido.Tools.LuaEval` (jido_action, Apache-2.0)
  rather than delegated to it (LuaEval can only inject inert globals —
  no host functions): unlinked supervised task + monitor + watchdog
  (parent death kills the eval), wall-clock kill with bounded drain,
  the `:__jido_deadline_ms__` deadline gate, and the per-process
  `:max_heap_size` kill flag. Orchestration shape (CallTrace ownership,
  policy-first, post-eval result assembly) ported from jidoka
  `lib/jidoka/workflow/lua.ex` @ 9469dc09 (Apache-2.0).

  Sandbox posture inside the task: `Lua.new/1`'s default sandbox strips
  `io`/`file`/`os.execute|getenv|…`/`package`/`load`/`require`, and the
  VM's deterministic budgets (`max_call_depth`, `max_instructions`,
  `max_string_bytes`) are wired from policy; `print` and `debug` are
  additionally sandboxed post-new — the default sandbox does NOT cover
  them, and `print` writes model-controlled text straight to host
  `IO.puts`, bypassing the redaction boundary.

  Two checks are deliberately **post-eval** (an in-script `pcall` can
  swallow a host-raised error and let the script "complete"):

    * budget refusal — `CallTrace.refused?/1` overrides an otherwise
      successful result to `:lua_call_budget_exceeded`;
    * the aggregate result bound — the final envelope (results +
      call_count + calls, the exact term handed to the tool wrapper) is
      measured as JSON bytes against `max_result_bytes`. This bound is
      load-bearing, not belt-and-suspenders: `OutputLimit` caps
      individual string leaves only, and `OutputShaper` never shapes
      this tool, so nothing else bounds a large structured map/list.

  ## Error taxonomy (all non-retryable)

  Every failure is `{:error, %{code: :lua_*, message: phrase-with-
  guidance, details: %{retry: false, …}}}` — non-retryable at BOTH
  retry layers (`:lua_*` codes sit outside jido_ai's retryable set;
  the explicit `details.retry: false` defuses `Jido.Exec`'s
  retryable-by-default wrap; the details never carry a `:reason` key).
  `:lua_timeout` is deliberately non-retryable (a deviation from
  LuaEval's retryable timeout): the same script under the same caps
  re-times-out. `:lua_result_not_encodable` extends the planned table:
  a Lua string is raw bytes, and a non-UTF-8 return cannot be JSON-
  measured or serialized downstream — surfaced honestly instead of
  crashing the measurement.
  """

  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Tools.Lua.Bindings
  alias JidoClaw.Tools.Lua.CallTrace
  alias JidoClaw.Tools.Lua.Policy

  @deadline_key :__jido_deadline_ms__

  @doc """
  Evaluate `code` in the sandbox under the caller's `context` (the
  enriched action context — `:tool_context` carries the scope, and the
  `#{inspect(@deadline_key)}` deadline key is honored). `opts` override
  policy caps (tests); production callers pass none.

  Returns `{:ok, %{"results" => …, "call_count" => n, "calls" => […]}}`
  or an error envelope per the taxonomy above.
  """
  @spec eval(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def eval(code, context, opts \\ []) when is_binary(code) and is_map(context) do
    Bindings.assert_read_only!()
    policy = Policy.resolve(opts)
    tool_context = nested_scope(context)
    started_ms = System.monotonic_time(:millisecond)

    result = do_eval(code, context, tool_context, policy)

    observe(result, code, tool_context, System.monotonic_time(:millisecond) - started_ms)
    result
  end

  defp do_eval(code, context, tool_context, policy) do
    with :ok <- validate_script(code, policy),
         {:ok, timeout_ms} <- effective_timeout(policy.timeout_ms, context) do
      # Owned by the tool process, not the eval task: a killed eval
      # leaves a readable partial audit.
      {:ok, trace} = CallTrace.start_link()

      try do
        outcome = run_supervised(code, tool_context, trace, policy, timeout_ms)
        build_result(outcome, CallTrace.refused?(trace), CallTrace.calls(trace), policy)
      after
        if Process.alive?(trace), do: Agent.stop(trace)
      end
    end
  end

  # ── Result assembly (post-eval; pcall cannot swallow these) ────────────

  # Budget refusal overrides everything, success included: subsequent
  # reserves keep refusing, so a pcall-looping script did zero further
  # reads and its "completed" result is not trustworthy work.
  defp build_result(_outcome, true, calls, policy) do
    envelope(
      :lua_call_budget_exceeded,
      "lua_query exceeded its host-call budget (max #{policy.max_calls} jido.* calls " <>
        "per eval); batch reads (one call with a larger limit) or split the work across " <>
        "separate lua_query calls. Do not retry unchanged.",
      %{max_calls: policy.max_calls, call_count: length(calls)}
    )
  end

  defp build_result({:ok, results}, false, calls, policy) do
    safe_results = JsonSafe.encode(results)
    result = %{"results" => safe_results, "call_count" => length(calls), "calls" => calls}

    case measure(result) do
      {:ok, bytes} when bytes > policy.max_result_bytes ->
        envelope(
          :lua_result_too_large,
          "lua_query result is #{bytes} bytes, over the #{policy.max_result_bytes}-byte " <>
            "cap; filter/aggregate in-script and return only what you need — page with " <>
            "after_seq (jido.events) or offset (jido.output). Do not retry unchanged.",
          %{
            result_bytes: bytes,
            max_result_bytes: policy.max_result_bytes,
            call_count: length(calls)
          }
        )

      {:ok, _bytes} ->
        {:ok, result}

      :unencodable ->
        envelope(
          :lua_result_not_encodable,
          "lua_query result contains non-UTF-8 binary data; Lua strings returned to the " <>
            "host must be valid UTF-8 text. Return printable text only. Do not retry unchanged.",
          %{call_count: length(calls)}
        )
    end
  end

  defp build_result({:error, :compile, message}, false, calls, _policy) do
    envelope(
      :lua_compile_error,
      "Lua compile error: #{message} — fix the script source and retry the corrected script.",
      %{call_count: length(calls)}
    )
  end

  defp build_result({:error, :runtime, message}, false, calls, _policy) do
    envelope(
      :lua_runtime_error,
      "Lua runtime error: #{message} — fix the script; fallible host calls can be " <>
        "wrapped in pcall(...) to handle errors in-script.",
      %{call_count: length(calls)}
    )
  end

  defp build_result({:error, :timeout, timeout_ms}, false, calls, _policy) do
    envelope(
      :lua_timeout,
      "lua_query timed out after #{timeout_ms}ms and was killed; the same script under " <>
        "the same caps would time out again — reduce the work per eval (fewer host " <>
        "calls, less in-script computation). Do not retry unchanged.",
      %{timeout_ms: timeout_ms, call_count: length(calls)}
    )
  end

  defp build_result({:error, :memory, _}, false, calls, policy) do
    envelope(
      :lua_memory_exceeded,
      "lua_query exceeded its #{policy.max_heap_bytes}-byte memory cap and was killed; " <>
        "build smaller intermediate tables (filter earlier, page instead of " <>
        "accumulating). Do not retry unchanged.",
      %{max_heap_bytes: policy.max_heap_bytes, call_count: length(calls)}
    )
  end

  defp build_result({:error, :task_exit, exit_reason}, false, calls, _policy) do
    envelope(
      :lua_task_exited,
      "lua_query eval task exited unexpectedly (#{inspect(exit_reason)}). Do not retry unchanged.",
      %{exit: inspect(exit_reason), call_count: length(calls)}
    )
  end

  defp measure(result) do
    {:ok, byte_size(Jason.encode!(result))}
  rescue
    # A Lua string is raw bytes; invalid UTF-8 makes Jason raise. The
    # envelope for it is built by the caller — measurement stays total.
    # reach:disable-next-line bare_rescue
    _error -> :unencodable
  end

  # ── Pre-spawn gates ─────────────────────────────────────────────────────

  defp validate_script(code, policy) do
    case Policy.validate_script(code, policy) do
      :ok ->
        :ok

      {:error, :lua_empty_script} ->
        envelope(
          :lua_empty_script,
          "lua_query script is empty; pass Lua source, typically ending with " <>
            "`return <value>`. Call lua_docs for the binding catalog.",
          %{}
        )

      {:error, {:lua_script_too_large, actual, max}} ->
        envelope(
          :lua_script_too_large,
          "lua_query script is #{actual} bytes, over the #{max}-byte cap; shrink the " <>
            "script. Do not retry unchanged.",
          %{script_bytes: actual, max_script_bytes: max}
        )
    end
  end

  # LuaEval's deadline gate: refuse when the turn deadline already
  # passed, else shrink the eval timeout to the remaining budget.
  defp effective_timeout(timeout_ms, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        remaining = deadline_ms - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          envelope(
            :lua_deadline_exceeded,
            "execution deadline exceeded before the Lua eval started; do not retry " <>
              "in this turn.",
            %{deadline_ms: deadline_ms}
          )
        else
          {:ok, min(timeout_ms, remaining)}
        end

      _ ->
        {:ok, timeout_ms}
    end
  end

  # ── Supervised eval (LuaEval task-isolation port) ───────────────────────

  defp run_supervised(code, tool_context, trace, policy, timeout_ms) do
    parent = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
        send(parent, {:lua_query_result, ref, sandboxed_eval(code, tool_context, trace, policy)})
      end)

    watchdog = start_watchdog(parent, pid)
    monitor_ref = Process.monitor(pid)

    case await_result(ref, pid, monitor_ref, timeout_ms) do
      {:ok, outcome} ->
        cleanup(ref, monitor_ref, watchdog)
        outcome

      {:exit, :killed} ->
        # We only kill on timeout (handled below); an unprompted :killed
        # is the max_heap_size flag.
        cleanup(ref, monitor_ref, watchdog)
        {:error, :memory, :killed}

      {:exit, reason} ->
        cleanup(ref, monitor_ref, watchdog)
        {:error, :task_exit, reason}

      :timeout ->
        _ = Process.exit(pid, :kill)
        wait_for_down(monitor_ref, pid, 100)
        cleanup(ref, monitor_ref, watchdog)
        {:error, :timeout, timeout_ms}
    end
  end

  # Runs inside the eval task, under the heap kill flag — result
  # normalization of a huge return table is bounded too.
  defp sandboxed_eval(code, tool_context, trace, policy) do
    :erlang.process_flag(:max_heap_size, %{
      size: bytes_to_heap_words(policy.max_heap_bytes),
      kill: true,
      error_logger: false
    })

    lua =
      [
        max_call_depth: policy.max_call_depth,
        max_instructions: policy.max_instructions,
        max_string_bytes: policy.max_string_bytes
      ]
      |> Lua.new()
      |> Lua.sandbox([:print])
      |> Lua.sandbox([:debug])
      |> Bindings.install(tool_context, trace, policy)

    {values, _lua} = Lua.eval!(lua, code)
    {:ok, Enum.map(values, &Bindings.normalize_lua_value/1)}
  rescue
    e in Lua.CompilerException ->
      {:error, :compile, Exception.message(e)}

    e in Lua.RuntimeException ->
      {:error, :runtime, Exception.message(e)}

    # Sandbox boundary: any exception (VM internals, a binding bug) must
    # become a structured error, never an abnormal task exit that would
    # misclassify as :lua_task_exited.
    # reach:disable-next-line bare_rescue
    e ->
      {:error, :runtime, Exception.message(e)}
  catch
    kind, caught -> {:error, :runtime, "#{kind}: #{inspect(caught)}"}
  end

  defp await_result(ref, pid, monitor_ref, timeout_ms) do
    receive do
      {:lua_query_result, ^ref, outcome} ->
        {:ok, outcome}

      {:DOWN, ^monitor_ref, :process, ^pid, :normal} ->
        # The send races the exit: give the already-sent result a beat.
        wait_for_result(ref, 100)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout_ms -> :timeout
    end
  end

  defp wait_for_result(ref, wait_ms) do
    receive do
      {:lua_query_result, ^ref, outcome} -> {:ok, outcome}
    after
      wait_ms -> {:exit, :normal}
    end
  end

  defp wait_for_down(monitor_ref, pid, wait_ms) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      wait_ms -> :ok
    end
  end

  defp cleanup(ref, monitor_ref, watchdog) do
    send(watchdog, :stop)
    Process.demonitor(monitor_ref, [:flush])
    flush_results(ref)
  end

  defp flush_results(ref) do
    receive do
      {:lua_query_result, ^ref, _outcome} -> flush_results(ref)
    after
      0 -> :ok
    end
  end

  # Parent death must kill the eval task (it is unlinked by design so a
  # heap kill can't take the tool process down with it).
  defp start_watchdog(parent, lua_pid) do
    spawn(fn ->
      parent_ref = Process.monitor(parent)
      lua_ref = Process.monitor(lua_pid)

      receive do
        {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
          if Process.alive?(lua_pid), do: Process.exit(lua_pid, :kill)
          Process.demonitor(lua_ref, [:flush])

        {:DOWN, ^lua_ref, :process, ^lua_pid, _reason} ->
          Process.demonitor(parent_ref, [:flush])

        :stop ->
          Process.demonitor(parent_ref, [:flush])
          Process.demonitor(lua_ref, [:flush])
      end
    end)
  end

  defp bytes_to_heap_words(bytes) do
    bytes
    |> div(:erlang.system_info(:wordsize))
    |> max(1)
  end

  # ── Envelope / scope helpers ────────────────────────────────────────────

  defp envelope(code, message, extra) do
    {:error, %{code: code, message: message, details: Map.put(extra, :retry, false)}}
  end

  defp nested_scope(%{tool_context: scope}) when is_map(scope), do: scope
  defp nested_scope(_context), do: %{}

  # ── Observability (one terminal event per eval + discrete refusals) ────

  defp observe(result, code, tool_context, duration_ms) do
    {status, trigger, call_count} =
      case result do
        {:ok, %{"call_count" => count}} ->
          {:completed, :none, count}

        {:error, %{code: error_code, details: details}} ->
          {:failed, error_code, Map.get(details, :call_count, 0)}
      end

    metadata =
      Map.merge(identity(tool_context), %{
        guardrail: "lua_query",
        event: :eval,
        status: status,
        trigger: trigger,
        script_bytes: byte_size(code),
        call_count: call_count,
        duration_ms: duration_ms
      })

    JidoClaw.Trace.emit(:guardrail, metadata, %{system_time: System.system_time()})
    JidoClaw.Telemetry.emit_lua_eval(status, trigger, %{})

    if trigger == :lua_call_budget_exceeded do
      JidoClaw.Trace.emit(
        :guardrail,
        Map.merge(identity(tool_context), %{
          guardrail: "lua_query",
          event: :budget_refused,
          trigger: :lua_call_budget_exceeded,
          call_count: call_count
        }),
        %{system_time: System.system_time()}
      )

      JidoClaw.Telemetry.emit_lua_eval(:budget_refused, :lua_call_budget_exceeded, %{})
    end

    :ok
  end

  defp identity(tool_context) do
    %{
      tenant_id: binary_or_nil(Map.get(tool_context, :tenant_id)),
      session_uuid: binary_or_nil(Map.get(tool_context, :session_uuid)),
      agent_id: binary_or_nil(Map.get(tool_context, :agent_id))
    }
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil
end
