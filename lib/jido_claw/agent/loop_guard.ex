defmodule JidoClaw.Agent.LoopGuard do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Doom-loop guard on the tool loop: detection logic, thresholds, and message
  texts ported from Miosa-osa/OSA `agent/loop/doom_loop.ex` @ f60e933b
  (Apache-2.0); the integration is rewritten for the shared
  `JidoClaw.Tools.Action` pipeline (no process dictionary, no system-message
  injection, no error-string sniffing).

  Three mechanisms, evaluated per `{tenant_id, session, identity}` key —
  `identity` from `JidoClaw.Reasoning.Compactor.Identity`, so one key per
  agent loop (OSA's "session"):

  1. **Identical-call halt** — a trailing consecutive run of the same
     `{tool, args_digest}` reaching `repeat_threshold` (4) within the last
     `repeat_window` (8) recorded calls halts **pre-execution** (the 4th
     call never runs — an improvement over OSA's post-batch check).
     Success-agnostic: it catches useless-success loops too.
  2. **Failure signatures (staged)** — `{tool, signature_text}` pairs are
     recorded for error results only (`{:error, _}` tuples, run_command's
     nonzero-`exit_code` OK map, and the string-keyed `"isError" => true`
     OK map the MCP proxies deliberately re-surface as `{:ok, data}`); any
     single signature reaching `failure_threshold` (3) within the last
     `failure_window` (20) triggers a staged response: a recovery directive
     appended to the failing tool result (`max_recoveries` = 2 nudges,
     signatures cleared each time), then a hard halt on the next trigger.
     A clean success of tool T clears **only T's** accumulated signatures —
     a deliberate deviation from OSA's *documented* clear-all, which would
     mask the archetypal edit-fail → read-ok → edit-fail repair loop
     (OSA's *code* never cleared at all).
  3. **Absolute call cap** — `max_calls` (100) executed calls per key; the
     next call is blocked pre-execution. Crossing `warn_pct` (80%) logs and
     traces a one-time warning, never injected into results (OSA parity).

  A halt is **sticky**: the key blocks every subsequent call until the
  Store sweep evicts it `halt_ttl_ms` after the halt (blocked attempts
  refresh nothing), after which the key starts fresh. Unhalted keys expire
  `idle_ttl_ms` after their last recorded call. State lives in
  `JidoClaw.Agent.LoopGuard.Store`, an in-memory singleton — **per node**:
  in cluster mode user cron `:agent` jobs fire on every node, so the
  worst-case budget scales with node count. A durable / cluster-wide store
  is out of scope.

  ## Halt envelope

  `{:error, %{code: :doom_loop, message: ..., details: %{retry: false,
  trigger: ..., ...}}}` — non-retryable at BOTH retry layers (the
  ForgeBridge precedent): `:doom_loop` is outside jido_ai's retryable-type
  whitelist, and the explicit `details.retry: false` defuses `Jido.Exec`'s
  retryable-by-default wrap of `{:error, map}`. The details key is
  `:trigger`, never `:reason` (the retry-hint diggers dig `:reason`).
  3-tuple inputs preserve effects: `{:error, envelope, effects}`.

  ## Feed boundary (documented residuals)

  The guard feeds at the `Tools.Action` boundary. `Jido.Exec` /
  `Jido.AI.Turn` wrap AROUND the action's `run/2`, so failures that
  materialize outside it bypass observation:

  1. **Param-validation failures** (before `run/2`): the call never reaches
     the pipeline — neither windows nor the cap see it. An LLM hammering
     identical *invalid* args is invisible to the guard.
  2. **Exec/Turn timeouts**: the attempt dies mid-`run/2`; no observation
     (run_command manages its own timeouts in-band and returns normally).
  3. **Raised exceptions / caught throws**: caught by `Jido.Exec` (which
     may itself retry them) or Turn outside the pipe tail; the guard sees
     nothing.
  4. **Output-schema validation failures after `{:ok, _}`**: the guard
     records a clean success while the LLM sees an error — the one
     false-signal direction. Neutralized cross-tool by per-tool signature
     clearing; same-tool identical-args repeats are still caught by the
     pre-execution identical-call check (those calls DO reach `run/2`).
     Residual: varied-args output-validation loops only.

  Classes 1–3 are under-detection; class 4 is an accepted false-success
  residual. Additionally: `observe_result/5` skips results whose code marks
  a non-execution (`:approval_pending` / `:approval_denied` /
  `:approval_unavailable` / `:doom_loop`), so an LLM retrying into a
  pending approval can never doom-halt the approval flow; and calls with no
  tenant or session scope pass through unguarded (the OutputShaper
  no-tenant posture).

  ## Fail-open

  The facade (`check/4`, `observe_result/5`) wraps Store access in
  rescue/catch → pass-through plus a best-effort `:guardrail` Trace event:
  a budget guard must never break a tool call. The Store itself never
  rescues.

  Config under `:loop_guard` (`config/config.exs`; `enabled?: false` in
  test). Telemetry counter on `[:jido_claw, :loop_guard]` plus `:guardrail`
  Trace events (`JidoClaw.Trace`).
  """

  require Logger

  alias JidoClaw.Agent.LoopGuard.Store
  alias JidoClaw.Reasoning.Compactor.Identity

  defmodule KeyState do
    @moduledoc """
    Per-key guard state. `call_keys` (`{tool, args_digest}`) and
    `failure_sigs` (`{tool, signature_text}`) are **newest-first** sliding
    windows (prepend + `Enum.take/2`). Timestamps are monotonic
    milliseconds; `halted` is `nil` or the halt reason.
    """
    @type t :: %__MODULE__{}
    defstruct call_keys: [],
              failure_sigs: [],
              total_calls: 0,
              recovery_count: 0,
              halted: nil,
              halted_at: nil,
              warned: false,
              last_activity: nil
  end

  @type halt_reason :: :identical_repeat | :call_cap | :failure_signature

  # Thresholds verbatim from OSA doom_loop.ex @ f60e933b (repeat 4-in-8,
  # failure 3-in-20, cap 100 with 80% warn, two recovery nudges). These are
  # the pure core's defaults; the facade merges `:loop_guard` app config on
  # top and the Store passes opts through, so config wins when present.
  @repeat_threshold 4
  @repeat_window 8
  @failure_threshold 3
  @failure_window 20
  @max_calls 100
  @warn_pct 0.80
  @max_recoveries 2

  @do_not_retry "Do not retry; stop calling tools and summarize the current state."

  # Results that represent non-executions: the tool body never ran, so they
  # must not count in any window (an LLM retrying into a pending approval
  # must not doom-halt the approval flow).
  @skip_codes [:approval_pending, :approval_denied, :approval_unavailable, :doom_loop]

  # ── Facade (impure boundary; fail-open) ────────────────────────────────

  @doc """
  Pre-execution gate for one tool call. Returns `:ok` (run the tool) or
  `{:halt, {:error, envelope}}` (the tool never executes).

  Total for the pipeline: the internal `:warn` verdict is consumed here
  (log + Trace + telemetry, then `:ok`). Unscoped calls, a disabled guard,
  and any Store fault all pass through as `:ok`.
  """
  @spec check(atom() | String.t(), term(), map(), keyword()) ::
          :ok | {:halt, {:error, map()}}
  def check(tool, params, context, opts \\ []) do
    opts = effective_opts(opts)

    with true <- Keyword.get(opts, :enabled?, true),
         {:ok, key} <- guard_key(context) do
      tool_name = to_string(tool)

      case Store.check_attempt(key, {tool_name, args_digest(params)}, opts) do
        :ok ->
          :ok

        :warn ->
          warn_cap(tool_name, key, opts)
          :ok

        {:halt, message, details} ->
          emit_guard_event(:halt, details[:trigger], tool_name, key)
          {:halt, {:error, %{code: :doom_loop, message: message, details: details}}}
      end
    else
      _not_guarded -> :ok
    end
  rescue
    # A budget guard must never break a tool call — fail open, pass through.
    # reach:disable-next-line bare_rescue
    error ->
      fail_open(tool, {:error, error})
      :ok
  catch
    :exit, reason ->
      fail_open(tool, {:exit, reason})
      :ok
  end

  @doc """
  Post-execution observation of one normalized tool result. Returns the
  result unchanged, the result with a recovery directive appended (nudge),
  or the `:doom_loop` error envelope replacing it (final failure-signature
  trigger). Skip-listed codes (`#{inspect(@skip_codes)}`) are ignored —
  the tool never executed.
  """
  @spec observe_result(term(), atom() | String.t(), term(), map(), keyword()) :: term()
  def observe_result(result, tool, params, context, opts \\ []) do
    opts = effective_opts(opts)

    if Keyword.get(opts, :enabled?, true) and not skip_result?(result) do
      do_observe(result, to_string(tool), params, context, opts)
    else
      result
    end
  rescue
    # Same fail-open posture as check/4: the result must always flow on.
    # reach:disable-next-line bare_rescue
    error ->
      fail_open(tool, {:error, error})
      result
  catch
    :exit, reason ->
      fail_open(tool, {:exit, reason})
      result
  end

  defp do_observe(result, tool_name, params, context, opts) do
    with {:ok, key} <- guard_key(context),
         {:ok, error?, text} <- observation(result, params) do
      key
      |> Store.check_result({tool_name, error?, text}, opts)
      |> apply_verdict(result, tool_name, key)
    else
      _not_observed -> result
    end
  end

  defp observation(result, params) do
    case classify_result(result, params) do
      :success -> {:ok, false, ""}
      {:failure, text} -> {:ok, true, text}
      :skip -> :skip
    end
  end

  defp apply_verdict(:ok, result, _tool_name, _key), do: result

  defp apply_verdict({:nudge, directive}, result, tool_name, key) do
    emit_guard_event(:nudge, :failure_signature, tool_name, key)
    append_directive(result, directive)
  end

  defp apply_verdict({:halt, message, details}, result, tool_name, key) do
    emit_guard_event(:halt, details[:trigger], tool_name, key)
    halt_result(result, %{code: :doom_loop, message: message, details: details})
  end

  # ── Result classification (typed — no error-string sniffing) ───────────

  @doc """
  Typed result classification: `:skip` (unknown shape — record nothing),
  `:success`, or `{:failure, text}`. Runs after `Error.normalize_result/1`,
  so errors are `{:error, %{code, message, details}}` (2- or 3-tuple); two
  `{:ok, _}` shapes are error-bearing — run_command's nonzero-`exit_code`
  map, and the string-keyed MCP `"isError" => true` contract the generated
  proxies deliberately re-surface as `{:ok, data}` (literal `true` only —
  `false`/non-boolean flags classify as successes).
  """
  @spec classify_result(term(), term()) :: :skip | :success | {:failure, String.t()}
  def classify_result({:error, reason}, _params), do: {:failure, error_text(reason)}
  def classify_result({:error, reason, _effects}, _params), do: {:failure, error_text(reason)}

  def classify_result({:ok, %{exit_code: code} = output}, params)
      when is_integer(code) and code != 0,
      do: {:failure, exit_text(output, code, params)}

  def classify_result({:ok, %{"isError" => true} = output}, params),
    do: {:failure, mcp_error_text(output, params)}

  def classify_result({:ok, %{"isError" => true} = output, _effects}, params),
    do: {:failure, mcp_error_text(output, params)}

  def classify_result({:ok, _output}, _params), do: :success
  def classify_result({:ok, _output, _effects}, _params), do: :success
  def classify_result(_other, _params), do: :skip

  defp error_text(%{message: message}) when is_binary(message) and message != "", do: message
  defp error_text(reason), do: inspect(reason)

  # Nonzero exit: signature from the output head; a blank output falls back
  # to the exit status plus a printable args-digest prefix, so different
  # silent commands cannot collide into one signature.
  defp exit_text(output, code, params) do
    out = output[:output]

    if is_binary(out) and String.trim(out) != "" do
      out
    else
      "exit status #{code} (args:#{digest_prefix(params)})"
    end
  end

  # MCP isError (the generated-proxy re-surfaced domain failure): signature
  # from the joined text content items; blank/absent content falls back to
  # the flag plus a printable args-digest prefix — mirroring exit_text, so
  # distinct silent failures cannot collide into one signature.
  defp mcp_error_text(output, params) do
    case mcp_content_text(output) do
      "" -> "isError (args:#{digest_prefix(params)})"
      text -> text
    end
  end

  defp mcp_content_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _item -> []
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp mcp_content_text(_output), do: ""

  defp digest_prefix(params) do
    params
    |> args_digest()
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Full 32-byte SHA-256 over the deterministic external term format — the
  ToolApprovals fingerprint idiom. Replaces OSA's `:erlang.phash2`, whose
  2^27 range makes a collision-induced hard halt possible.
  """
  @spec args_digest(term()) :: binary()
  def args_digest(params) do
    :crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))
  end

  # ── Nudge / halt delivery (shape-aware) ─────────────────────────────────

  @doc """
  Append the recovery directive to the field the LLM actually reads:
  `message` for error envelopes, `output` for the run_command nonzero-exit
  OK shape, and an appended `%{"type" => "text"}` content item for the MCP
  `"isError" => true` shape (after the error text; a malformed non-list
  `content` passes through unmangled). Effects (3-tuple arities) are
  preserved; unknown shapes pass through unchanged.
  """
  @spec append_directive(term(), String.t()) :: term()
  def append_directive({:error, %{message: message} = reason}, directive)
      when is_binary(message),
      do: {:error, %{reason | message: message <> "\n\n" <> directive}}

  def append_directive({:error, %{message: message} = reason, effects}, directive)
      when is_binary(message),
      do: {:error, %{reason | message: message <> "\n\n" <> directive}, effects}

  def append_directive({:ok, %{output: output} = result}, directive) when is_binary(output),
    do: {:ok, %{result | output: output <> "\n\n" <> directive}}

  def append_directive({:ok, %{output: output} = result, effects}, directive)
      when is_binary(output),
      do: {:ok, %{result | output: output <> "\n\n" <> directive}, effects}

  def append_directive({:ok, %{"isError" => true} = result}, directive),
    do: {:ok, append_mcp_content(result, directive)}

  def append_directive({:ok, %{"isError" => true} = result, effects}, directive),
    do: {:ok, append_mcp_content(result, directive), effects}

  def append_directive(result, _directive), do: result

  # MCP isError delivery: the directive rides as an APPENDED text content
  # item — it must read after the error text, so never prepend and never
  # string-merge into an existing item. Malformed (non-list) `content`
  # passes through unchanged — never mangle remote data; the staged halt
  # still fires on a later trigger.
  defp append_mcp_content(%{"content" => content} = result, directive) when is_list(content),
    do: %{result | "content" => List.insert_at(content, -1, mcp_text_item(directive))}

  defp append_mcp_content(%{"content" => _malformed} = result, _directive), do: result

  defp append_mcp_content(result, directive),
    do: Map.put(result, "content", [mcp_text_item(directive)])

  defp mcp_text_item(text), do: %{"type" => "text", "text" => text}

  defp halt_result({:error, _reason, effects}, envelope), do: {:error, envelope, effects}
  defp halt_result({:ok, _output, effects}, envelope), do: {:error, envelope, effects}
  defp halt_result(_result, envelope), do: {:error, envelope}

  defp skip_result?({:error, %{code: code}}) when code in @skip_codes, do: true
  defp skip_result?({:error, %{code: code}, _effects}) when code in @skip_codes, do: true
  defp skip_result?(_result), do: false

  # ── Key resolution ──────────────────────────────────────────────────────

  # `{tenant, session_uuid || session_id, identity}`; `:skip` without a
  # tenant AND session (the OutputShaper no-tenant posture). `agent_id`
  # resolves top-level first (the live ReAct path — `ensure_nested/1`
  # deliberately leaves the nested copy out there), then the nested scope
  # (direct calls / MCP default scope / tests). Every read is
  # `is_binary`-coerced (the present-nil ToolContext trap).
  defp guard_key(context) when is_map(context) do
    scope = nested_scope(context)
    tenant = binary_or_nil(scope[:tenant_id])
    session = binary_or_nil(scope[:session_uuid]) || binary_or_nil(scope[:session_id])

    if is_nil(tenant) or is_nil(session) do
      :skip
    else
      agent_id = binary_or_nil(context[:agent_id]) || binary_or_nil(scope[:agent_id])
      template = binary_or_nil(scope[:agent_template])
      identity = Identity.resolve(template, agent_id, binary_or_nil(scope[:session_id]))
      {:ok, {tenant, session, identity}}
    end
  end

  defp guard_key(_context), do: :skip

  defp nested_scope(%{tool_context: scope}) when is_map(scope), do: scope
  defp nested_scope(_context), do: %{}

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  # ── Observability ───────────────────────────────────────────────────────

  defp warn_cap(tool_name, key, opts) do
    max = Keyword.get(opts, :max_calls, @max_calls)
    warn_at = trunc(max * Keyword.get(opts, :warn_pct, @warn_pct))

    Logger.warning(
      "loop guard: approaching the tool call cap (#{warn_at}/#{max}) for #{inspect(key)}"
    )

    emit_guard_event(:warn, :call_cap, tool_name, key)
  end

  defp emit_guard_event(event, trigger, tool_name, {tenant, session, identity}) do
    JidoClaw.Trace.emit(
      :guardrail,
      %{
        guardrail: "loop_guard",
        event: event,
        name: tool_name,
        trigger: trigger,
        tenant_id: tenant,
        session_uuid: session,
        agent_id: identity
      },
      %{system_time: System.system_time()}
    )

    JidoClaw.Telemetry.emit_loop_guard(tool_name, event, trigger)
  end

  defp fail_open(tool, failure) do
    Logger.warning("loop guard: fail-open pass-through for #{tool}: #{inspect(failure)}")

    JidoClaw.Trace.emit(
      :guardrail,
      %{guardrail: "loop_guard", event: :fail_open, name: to_string(tool)},
      %{system_time: System.system_time()}
    )
  end

  # Explicit opts override the `:loop_guard` app config; the pure core's
  # in-module defaults backstop anything absent (one merge — no per-key
  # readers here; the Store keeps the `opt_or_config/2` reader for its
  # sweep keys).
  defp effective_opts(opts) do
    Keyword.merge(Application.get_env(:jido_claw, :loop_guard, []), opts)
  end

  # ── Pure core (the property-test surface; explicit opts, no app env) ────

  @doc """
  Judge one attempted call pre-execution and fold it into the key state.

  Detection ported from Miosa-osa/OSA @ f60e933b, Apache-2.0
  (`check_repeat_calls/2` + the absolute call counter); pre-execution
  blocking is ours. A halted state is sticky and mutates nothing.
  """
  @spec check_attempt(KeyState.t(), {String.t(), term()}, keyword()) ::
          {:ok | :warn | {:halt, halt_reason()}, KeyState.t()}
  def check_attempt(%KeyState{halted: reason} = state, _call_key, _opts)
      when not is_nil(reason) do
    {{:halt, reason}, state}
  end

  def check_attempt(%KeyState{} = state, {_tool, _digest} = call_key, opts) do
    now = now(opts)
    window = Keyword.get(opts, :repeat_window, @repeat_window)
    max_calls = Keyword.get(opts, :max_calls, @max_calls)
    call_keys = Enum.take([call_key | state.call_keys], window)

    cond do
      leading_run(call_keys) >= Keyword.get(opts, :repeat_threshold, @repeat_threshold) ->
        {{:halt, :identical_repeat},
         %{state | call_keys: call_keys, halted: :identical_repeat, halted_at: now}}

      state.total_calls >= max_calls ->
        {{:halt, :call_cap}, %{state | halted: :call_cap, halted_at: now}}

      true ->
        state = %{
          state
          | call_keys: call_keys,
            total_calls: state.total_calls + 1,
            last_activity: now
        }

        maybe_warn(state, max_calls, opts)
    end
  end

  @doc """
  Fold one observed result into the key state.

  Detection ported from Miosa-osa/OSA @ f60e933b, Apache-2.0
  (`check_signatures/3` + the staged recovery); the
  `:ok | {:nudge, directive} | {:halt, reason}` contract and per-tool
  success clearing are ours. A halted state is a no-op.
  """
  @spec check_result(KeyState.t(), {String.t(), boolean(), String.t()}, keyword()) ::
          {:ok | {:nudge, String.t()} | {:halt, halt_reason()}, KeyState.t()}
  def check_result(%KeyState{halted: reason} = state, _observation, _opts)
      when not is_nil(reason) do
    {:ok, state}
  end

  def check_result(%KeyState{} = state, {tool, true, error_text}, opts) do
    now = now(opts)
    sig = {tool, signature_text(error_text)}
    window = Keyword.get(opts, :failure_window, @failure_window)
    sigs = Enum.take([sig | state.failure_sigs], window)
    state = %{state | failure_sigs: sigs, last_activity: now}

    case repeated_signature(sigs, Keyword.get(opts, :failure_threshold, @failure_threshold)) do
      nil -> {:ok, state}
      {trigger_sig, count} -> stage_response(state, trigger_sig, count, now, opts)
    end
  end

  def check_result(%KeyState{} = state, {tool, false, _text}, opts) do
    # Per-tool clearing (deliberate deviation — see the moduledoc): a clean
    # success of tool T clears only T's accumulated signatures.
    sigs = Enum.reject(state.failure_sigs, fn {sig_tool, _text} -> sig_tool == tool end)
    {:ok, %{state | failure_sigs: sigs, last_activity: now(opts)}}
  end

  # Staged recovery: nudge (clear signatures, count the recovery) until
  # `max_recoveries` is spent, then halt — leaving the triggering
  # signatures in place so `halt_message/3` can derive them.
  defp stage_response(state, {tool, text}, count, now, opts) do
    if state.recovery_count >= Keyword.get(opts, :max_recoveries, @max_recoveries) do
      {{:halt, :failure_signature}, %{state | halted: :failure_signature, halted_at: now}}
    else
      {{:nudge, recovery_directive(tool, text, count)},
       %{state | failure_sigs: [], recovery_count: state.recovery_count + 1}}
    end
  end

  # First (newest) signature whose windowed frequency reaches the
  # threshold. At most one signature can be at/over threshold (each append
  # adds one occurrence and every trigger clears or halts), but scanning
  # the list keeps the pick deterministic regardless.
  defp repeated_signature(sigs, threshold) do
    freqs = Enum.frequencies(sigs)

    case Enum.find(sigs, fn sig -> Map.fetch!(freqs, sig) >= threshold end) do
      nil -> nil
      sig -> {sig, Map.fetch!(freqs, sig)}
    end
  end

  # Windows are newest-first, so the chronological trailing run is the
  # leading run of identical elements here. Counted without materializing
  # the prefix.
  defp leading_run([head | rest]), do: count_run(rest, head, 1)

  defp count_run([head | rest], head, count), do: count_run(rest, head, count + 1)
  defp count_run(_rest, _head, count), do: count

  defp maybe_warn(%KeyState{warned: false} = state, max_calls, opts) do
    if state.total_calls >= trunc(max_calls * Keyword.get(opts, :warn_pct, @warn_pct)) do
      {:warn, %{state | warned: true}}
    else
      {:ok, state}
    end
  end

  defp maybe_warn(state, _max_calls, _opts), do: {:ok, state}

  @doc """
  Signature text: first 100 characters, whitespace-collapsed, trimmed.
  Idempotent. (Ported from Miosa-osa/OSA @ f60e933b, Apache-2.0.)
  """
  @spec signature_text(String.t()) :: String.t()
  def signature_text(text) when is_binary(text) do
    text
    |> String.slice(0, 100)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ── Messages (OSA texts, tool names remapped) ──────────────────────────

  @doc """
  Halt message for `reason`, derived from the halted key state. Texts
  ported from Miosa-osa/OSA @ f60e933b, Apache-2.0 (tool names remapped,
  cap-config wording remapped to `:loop_guard`), each with an explicit
  do-not-retry line appended.
  """
  @spec halt_message(halt_reason(), KeyState.t(), keyword()) :: String.t()
  def halt_message(reason, state, opts \\ [])

  def halt_message(:identical_repeat, %KeyState{} = state, _opts) do
    {tool, repeats} = identical_streak(state)

    "Stopped: tool `#{tool}` was called with identical arguments #{repeats} times in a row " <>
      "without making progress. The result of an earlier call is already in context — " <>
      "use it, or try a different tool / different arguments. " <> @do_not_retry
  end

  def halt_message(:call_cap, %KeyState{} = state, opts) do
    max = Keyword.get(opts, :max_calls, @max_calls)

    String.trim("""
    I've reached the session tool call limit (#{state.total_calls}/#{max}) and am stopping to avoid runaway execution.

    This limit exists as a safety net independent of error-pattern detection.

    How to proceed:
    - If the task is incomplete, start a new session and continue from where you left off.
    - If you need a higher limit, adjust `max_calls` under `config :jido_claw, :loop_guard`.

    #{@do_not_retry}
    """)
  end

  def halt_message(:failure_signature, %KeyState{} = state, _opts) do
    {{tool, text}, count} = dominant_signature(state)

    String.trim("""
    I hit the same error #{count} times with #{tool}: #{text}

    #{build_suggestion(text)}

    #{@do_not_retry}
    """)
  end

  @doc """
  Halt details for `reason`: always `%{retry: false, trigger: reason, ...}`
  scalars. `retry: false` is load-bearing at the `Jido.Exec` retry layer;
  the key is `:trigger`, never `:reason` (the retry-hint diggers dig
  `:reason`).
  """
  @spec halt_details(halt_reason(), KeyState.t(), keyword()) :: map()
  def halt_details(reason, state, opts \\ [])

  def halt_details(:identical_repeat, %KeyState{} = state, _opts) do
    {tool, repeats} = identical_streak(state)
    %{retry: false, trigger: :identical_repeat, tool: tool, repeats: repeats}
  end

  def halt_details(:call_cap, %KeyState{} = state, opts) do
    %{
      retry: false,
      trigger: :call_cap,
      total_calls: state.total_calls,
      max_calls: Keyword.get(opts, :max_calls, @max_calls)
    }
  end

  def halt_details(:failure_signature, %KeyState{} = state, _opts) do
    {{tool, _text}, count} = dominant_signature(state)
    %{retry: false, trigger: :failure_signature, tool: tool, occurrences: count}
  end

  defp identical_streak(%KeyState{call_keys: []}), do: {"unknown", 0}

  defp identical_streak(%KeyState{call_keys: [{tool, _digest} | _rest] = keys}) do
    {tool, leading_run(keys)}
  end

  defp dominant_signature(%KeyState{failure_sigs: []}), do: {{"unknown", ""}, 0}

  defp dominant_signature(%KeyState{failure_sigs: sigs}) do
    freqs = Enum.frequencies(sigs)
    sig = Enum.max_by(sigs, &Map.fetch!(freqs, &1))
    {sig, Map.fetch!(freqs, sig)}
  end

  # Ported from Miosa-osa/OSA @ f60e933b, Apache-2.0 (file_read →
  # read_file); delivery adapted — appended to the failing tool result
  # rather than injected as a system message.
  defp recovery_directive(tool, text, count) do
    "[DOOM LOOP RECOVERY: You tried #{tool} #{count} times with the same error: " <>
      "\"#{text}\". You MUST change your approach NOW. " <>
      "Step 1: Call read_file on the target file to see its current state. " <>
      "Step 2: Based on what you see, decide if the change is still needed. " <>
      "Step 3: If yes, use COMPLETELY DIFFERENT arguments. If no, move on. " <>
      "Do NOT call #{tool} with the same arguments again.]"
  end

  @doc """
  Targeted recovery advice for a repeated error. Ported verbatim from
  Miosa-osa/OSA @ f60e933b, Apache-2.0, with tool names remapped to ours
  (file_read → read_file, shell_execute → run_command, dir_list →
  list_directory, file_glob → search_code). Branch order is load-bearing
  (e.g. "old_string not found" must beat the generic "not found").
  """
  @spec build_suggestion(String.t()) :: String.t()
  def build_suggestion(triggering_error) do
    cond do
      String.contains?(triggering_error, "old_string and new_string are identical") ->
        "The file already contains the change you're trying to make. " <>
          "Read the file with read_file to see its current state, then decide if the edit " <>
          "is still needed."

      String.contains?(triggering_error, "old_string not found") ->
        "The text you're trying to replace doesn't exist in the file. " <>
          "Read the file with read_file to see the actual content, then use the exact text " <>
          "from the file."

      String.contains?(triggering_error, "old_string found") and
          String.contains?(triggering_error, "times") ->
        "The text appears multiple times. Add more surrounding context to make old_string " <>
          "unique, or use replace_all: true."

      String.contains?(triggering_error, ["command not found", "not found"]) ->
        "The command or binary does not exist. " <>
          "Check what's installed with run_command(command: \"which <tool>\") or use an " <>
          "alternative."

      String.contains?(triggering_error, ["Permission denied", "cannot", "Could not"]) ->
        "Permission denied. Check file permissions or try a different path."

      String.contains?(triggering_error, ["No such file", "No such directory"]) ->
        "File or directory does not exist. " <>
          "Use search_code or list_directory to find the correct path."

      String.contains?(triggering_error, ["Blocked:"]) ->
        "Tool blocked by permissions. Use a different tool or approach."

      true ->
        "Read the relevant files with read_file to understand the current state, " <>
          "then try a completely different approach. Do NOT retry the same operation."
    end
  end

  defp now(opts) do
    Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)
  end
end
