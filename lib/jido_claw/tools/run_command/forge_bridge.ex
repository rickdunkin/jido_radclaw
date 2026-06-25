defmodule JidoClaw.Tools.RunCommand.ForgeBridge do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Routes a `run_command` call into a Forge Docker microVM session (AR-8b-2 F2).

  When a worker carries `tool_context[:sandbox] == :docker`,
  `JidoClaw.Tools.RunCommand` short-circuits the host/VFS/SSH dispatch and
  hands the command to `dispatch/4`, which executes it inside the worker's
  pre-created Forge session (`tool_context[:forge_session_key]`) via
  `JidoClaw.Forge.exec/3`. It **hard-fails** (never falls back to the host
  shell) when the session is unavailable — OS-level isolation is the whole
  point of the `:docker` tier, so a degraded host run would silently defeat it.

  ## Two substrates, one adapter

  `RunCommand`'s native path returns `{:ok, %{output:, exit_code:}}` (from
  `Shell.SessionManager`); `Forge.exec/3` returns `{:ok, {output, exit_code}}`
  (a tuple inside `:ok`). The load-bearing logic is the pure, public
  `normalize_exec_result/2`, which adapts the Forge return to the tool's
  `output_schema` map shape and recognizes the Docker backend's *manufactured*
  `{message, code}` failure pairs (`Forge.Sandbox.Docker`):

    * `{"sbx: command not found", 127}` → non-retryable `:sandbox_unavailable`
      (nothing ran; **no taint**),
    * `{"timeout after \#{inner}ms", 124}` (an **exact** match — the bridge knows
      the `inner` timeout it passed) → **taint** + `:sandbox_command_timeout`,
    * `{"output limit exceeded after N bytes", 153}` (the byte count is dynamic,
      so an **anchored** regex) → **taint** + `:sandbox_output_limit`.

  A *user* command can legitimately exit 124/153/127 with its own output, so the
  disambiguation matches the manufactured **exact message + code**, never the
  code alone — everything else is an ordinary `{out, code}` returned verbatim
  with **no taint**.

  ## Non-retryability (TWO layers: code AND an explicit `retry: false`)

  A bridge error must survive **two independent** retry checks:

    1. The ReAct runner's `Jido.AI.Error.retryable?/1`, which keys off the error
       `code` (these codes all default non-retryable — never `:timeout`) *and*
       digs into `details` for a retry hint.
    2. `Jido.Exec`'s own action-level retry (default `max_retries: 1`), which
       wraps the returned `{:error, map}` into a
       `%Jido.Action.Error.ExecutionFailureError{}` whose
       `Jido.Action.Error.retryable?/1` **defaults that class to retryable**
       unless it finds a `retry: false` hint in `details`.

  So every bridge error uses a distinct non-retryable code
  (`:sandbox_unavailable`/`:sandbox_command_timeout`/`:sandbox_output_limit`/
  `:sandbox_deadline_exceeded`) **and** carries an explicit `details.retry: false`.
  The `retry: false` is load-bearing for layer 2: without it a tainted command
  would be **re-executed**, and because teardown is now detached (see
  `dispatch/4`), that retry can re-enter the session *before* the asynchronous
  `stop_session` lands — re-running the command in the still-live sandbox. Both
  layers' hint-extractors read `retry` out of the (possibly nested) `details`, so
  the one key satisfies both. `details` otherwise stays free of `:reason`/
  retry-*truthy* keys that could flip the posture back to retryable.
  `JidoClaw.Tools.Error.normalize_result/1` preserves the full
  `%{code:, message:, details:}` map verbatim, so both layers see `retry: false`.

  ## Two nested deadlines

  The whole `RunCommand` action is wrapped by `Jido.Exec`, which kills the task
  at its own deadline (sized from `tool_timeout_ms`, default 30_000 on every
  agent). Since `RunCommand`'s own `timeout` param also defaults to 30_000, a
  bare cushion is moot — Jido would kill the action before the bridge could
  taint/stop/return. `dispatch/4` therefore derives the **inner** Forge command
  timeout from the **outer** absolute deadline `Jido.Exec` stamps into context
  (`:__jido_deadline_ms__`), reserving a `margin` so the chain
  `inner_OsCmd < harness_outer (inner + cushion) < jido_deadline` holds. Below a
  minimum-viable budget it refuses to launch (`:sandbox_deadline_exceeded`); the
  `margin` reads the single-sourced `JidoClaw.Forge.exec_timeout_cushion_ms/0`
  (the same value `Forge.Harness` cushions its outer call with) so the two can
  never drift.
  """

  alias JidoClaw.Forge

  # The absolute deadline `Jido.Exec` stamps onto the action context (a
  # `System.monotonic_time(:millisecond)` value). Read-only here.
  @deadline_key :__jido_deadline_ms__

  # Slack reserved *beyond* the harness cushion for the bridge to taint +
  # stop_session + return after the inner exec yields, all before Jido's action
  # deadline. The full timeout-budget margin is `cushion + this`.
  @taint_overhead_ms 500

  # Don't launch when fewer than this many ms remain after reserving `margin` —
  # there isn't time to run + taint + return before Jido kills the action.
  @min_viable_launch_ms 1_000

  # The Docker backend's manufactured output-limit exit status (single-sourced).
  @output_limit_exit_status JidoClaw.Forge.Sandbox.output_limit_exit_status()

  # The anchored manufactured output-limit message — the byte count is dynamic
  # (`docker.ex`), so anchor rather than exact-compare to avoid a false taint on
  # a user command that exits 153 with similar-looking output.
  @output_limit_message ~r/\Aoutput limit exceeded after \d+ bytes\z/

  @type err :: %{code: atom(), message: String.t(), details: map()}

  @doc """
  Execute `command` in the worker's Forge Docker session and adapt the result.

  Derives the inner Forge command timeout from `params[:timeout]` (locally
  defaulted to 30_000 — the docker branch short-circuits before `RunCommand`'s
  own default line) bounded by the outer `Jido.Exec` deadline in `context`, runs
  `Forge.exec/3`, and normalizes the return via `normalize_exec_result/2`. On a
  taint outcome it tears the session down asynchronously (`Forge.stop_session/1`,
  best-effort, detached off the return path — so the non-retryable error wins the
  `Jido.Exec` action deadline regardless of how long teardown takes).

  Returns `{:ok, %{output:, exit_code:}}` | `{:error, err}` (both flow through
  the outer `Tools.Action` normalize → redact → shape → cap pipeline).
  """
  @spec dispatch(String.t(), term(), map(), map()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, err()}
  def dispatch(command, forge_key, params, context) do
    requested = Map.get(params, :timeout, 30_000)

    case derive_inner_timeout(requested, context) do
      {:refuse, err} -> {:error, err}
      {:ok, inner} -> execute(command, forge_key, inner)
    end
  end

  # Derive the inner Forge command timeout from the requested timeout and the
  # outer `Jido.Exec` deadline in `context`. With a `:__jido_deadline_ms__`
  # present: `inner = min(requested, budget)` where `budget = remaining - margin`,
  # refusing (`{:refuse, err}`) when `budget` is below the minimum-viable-launch
  # threshold. Without one (e.g. a direct test call), honors `requested`
  # unchanged. Public `@doc false` purely as a unit-test seam.
  @doc false
  @spec derive_inner_timeout(term(), map()) :: {:ok, integer()} | {:refuse, err()}
  def derive_inner_timeout(requested, context) do
    case Map.get(context, @deadline_key) do
      deadline when is_integer(deadline) ->
        remaining = deadline - System.monotonic_time(:millisecond)
        budget = remaining - margin_ms()

        if budget < @min_viable_launch_ms do
          {:refuse, deadline_exceeded_error()}
        else
          {:ok, min(requested, budget)}
        end

      _ ->
        {:ok, requested}
    end
  end

  @doc """
  Adapt a `Forge.exec/3` return to the tool's result shape, recognizing the
  Docker backend's manufactured failure pairs against the exact `inner_timeout`
  the bridge passed.

  Returns a tagged value so the taint side-effect stays in `dispatch/4`:

    * `{:ok, %{output:, exit_code:}}` — success (incl. a user command's own
      124/153/127 exit with non-manufactured output),
    * `{:error, err}` — non-retryable failure, **no** session teardown,
    * `{:taint, err}` — non-retryable failure; the caller tears the session down (async).
  """
  @spec normalize_exec_result(term(), integer()) ::
          {:ok, %{output: String.t(), exit_code: integer()}} | {:error, err()} | {:taint, err()}
  def normalize_exec_result({:ok, {out, code}}, inner_timeout)
      when is_binary(out) and is_integer(code) do
    classify(out, code, inner_timeout)
  end

  # Only adapt a success when the code is an integer; any other `{:ok, _}` shape
  # is defensive-unavailable (the backend contract is a `{binary, integer}`).
  def normalize_exec_result({:ok, _other}, _inner_timeout), do: {:error, unavailable_error()}

  # ANY `{:error, term}` from Forge/Harness — `:not_found`, `{:invalid_state,_}`,
  # `{:provision_failed,_}`, `{:unknown_sandbox,_}`, or anything else — is a
  # non-retryable `:sandbox_unavailable` (nothing ran in-container; hard-fail,
  # never SessionManager). No taint.
  def normalize_exec_result({:error, _term}, _inner_timeout), do: {:error, unavailable_error()}

  # Any other shape (defensive) — treat as unavailable.
  def normalize_exec_result(_other, _inner_timeout), do: {:error, unavailable_error()}

  # -- Manufactured-code dispatch (exact message + code, never code alone) -----

  # `sbx` missing: nothing ran, so no taint — the session is just unreachable.
  defp classify("sbx: command not found", 127, _inner), do: {:error, unavailable_error()}

  # Manufactured timeout: the bridge knows the exact `inner` it passed
  # (`docker.ex` emits "timeout after \#{timeout}ms"), so an exact match — a user
  # command exiting 124 with different output stays ordinary.
  defp classify(out, 124, inner) do
    if out == "timeout after #{inner}ms" do
      {:taint, command_timeout_error()}
    else
      {:ok, ok_result(out, 124)}
    end
  end

  # Manufactured output-limit: the byte count is dynamic, so anchored-regex
  # match (not exact) — a user command exiting 153 with different output stays
  # ordinary.
  defp classify(out, @output_limit_exit_status, _inner) do
    if Regex.match?(@output_limit_message, out) do
      {:taint, output_limit_error()}
    else
      {:ok, ok_result(out, @output_limit_exit_status)}
    end
  end

  # Everything else — including a user command that genuinely exits with its own
  # output — is an ordinary success. No taint on a user's own exit code.
  defp classify(out, code, _inner), do: {:ok, ok_result(out, code)}

  defp ok_result(out, code), do: %{output: out, exit_code: code}

  # -- Execution + taint side-effect -------------------------------------------

  defp execute(command, forge_key, inner) do
    case forge_exec(command, forge_key, inner) do
      :caught_timeout ->
        # The residual catch funnels to the SAME outcome as the manufactured
        # 124 (both delivery paths of a real in-container timeout converge).
        taint_and_error(forge_key, command_timeout_error())

      {:returned, result} ->
        case normalize_exec_result(result, inner) do
          {:ok, map} -> {:ok, map}
          {:error, err} -> {:error, err}
          {:taint, err} -> taint_and_error(forge_key, err)
        end
    end
  end

  # Catch tightly scoped to the Forge call. The `:exit, {:timeout, _}` catch is
  # the residual net (pairs with C3's harness cushion + the deadline derivation
  # above): a real inner timeout that still escapes as a caller exit converges
  # to the taint path rather than crashing `RunCommand.run/2`.
  defp forge_exec(command, forge_key, inner) do
    {:returned, forge().exec(forge_key, command, timeout: inner)}
  catch
    :exit, {:timeout, _} -> :caught_timeout
  end

  defp taint_and_error(forge_key, err) do
    _ = schedule_teardown(forge_key)
    {:error, err}
  end

  # Detached best-effort teardown. Capture the Forge facade NOW — app env can change
  # before the task runs (a test restoring :forge_facade in on_exit), so an orphaned
  # task must not fall through to the real Forge.stop_session. Returning the
  # non-retryable error immediately lets it win Jido.Exec's action deadline instead
  # of blocking on a synchronous Forge.stop_session (a Manager GenServer.call that
  # can take ~5s terminating a wedged harness — long enough for Jido to kill the
  # action and surface a RETRYABLE TimeoutError). Runs under JidoClaw.TaskSupervisor,
  # not the caller's context (the real stop_session phase write is detached from any
  # caller Ecto sandbox). The start is guarded so a missing supervisor can't mask the
  # bridge error.
  defp schedule_teardown(forge_key) do
    forge_mod = forge()

    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> safe_stop(forge_mod, forge_key) end)

    :ok
  catch
    :exit, _ -> :ok
  end

  # Best-effort teardown of the zombie in-container command; never let a stop
  # fault mask the bridge's error.
  defp safe_stop(forge_mod, forge_key) do
    forge_mod.stop_session(forge_key)
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- Error envelopes (details: neutral keys + explicit retry: false) ---------
  # `retry: false` makes each error non-retryable at BOTH the ReAct
  # (`Jido.AI.Error`) and `Jido.Exec` (`Jido.Action.Error`) layers — see the
  # "Non-retryability" moduledoc section. Without it, `Jido.Exec` would re-run a
  # tainted command into the asynchronously-torn-down session.

  defp unavailable_error do
    %{
      code: :sandbox_unavailable,
      message:
        "The Docker execution sandbox is unavailable, so this command did not run. " <>
          "This is not retryable and must not fall back to the host shell — the sketch's " <>
          "isolated sandbox session could not be reached.",
      details: %{operation: "run_command", sandbox_status: :unavailable, retry: false}
    }
  end

  defp command_timeout_error do
    %{
      code: :sandbox_command_timeout,
      message:
        "The command exceeded its Docker sandbox time budget and was killed; the sandbox " <>
          "session is being torn down. This is not retryable — narrow the command or split " <>
          "the work.",
      details: %{operation: "run_command", exit_status: 124, retry: false}
    }
  end

  defp output_limit_error do
    %{
      code: :sandbox_output_limit,
      message:
        "The command exceeded the Docker sandbox output limit and was killed; the sandbox " <>
          "session is being torn down. This is not retryable — reduce the volume of output " <>
          "the command produces.",
      details: %{operation: "run_command", exit_status: @output_limit_exit_status, retry: false}
    }
  end

  defp deadline_exceeded_error do
    %{
      code: :sandbox_deadline_exceeded,
      message:
        "Not enough of the tool time budget remained to run this command in the Docker " <>
          "sandbox before the action deadline, so it was not launched. This is not retryable " <>
          "— the turn is nearly out of time.",
      details: %{operation: "run_command", sandbox_status: :deadline_exceeded, retry: false}
    }
  end

  # The full timeout-budget margin: the single-sourced harness cushion plus the
  # taint/stop/return slack. Reading `Forge.exec_timeout_cushion_ms/0` (the same
  # value the harness cushions its outer call with) keeps the ordering airtight.
  defp margin_ms, do: Forge.exec_timeout_cushion_ms() + @taint_overhead_ms

  # Injectable Forge facade (the app-env seam idiom, cf. `:mcp_facade`/
  # `:step_agent_server`) so bridge tests drive a deterministic stub `exec`/
  # `stop_session` without a live microVM. Production resolves to `JidoClaw.Forge`.
  defp forge, do: Application.get_env(:jido_claw, :forge_facade, Forge)
end
