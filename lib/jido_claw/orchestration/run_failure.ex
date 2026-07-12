defmodule JidoClaw.Orchestration.RunFailure do
  # Adapted from multica-ai/multica @ 129efb768 (patterns only, no code lift):
  # server/pkg/taskfailure/failure.go (the 21-kind enum + AllReasons() label
  # pre-warm), classify.go (ordered most-specific-first classifier),
  # service/task.go retryableReasons / resumeUnsafeFailureReason (the two
  # INDEPENDENT derived sets). Riders: orca OR3-2 (stalled_no_output vs
  # stalled_wall_clock split; user_cancelled as a first-class non-failure),
  # bosun BO2-3 (the session-poisoned family).
  @moduledoc """
  The run-failure taxonomy (multica MC1-4): one closed vocabulary for *why an
  agent run failed*, with platform-vs-agent provenance in the name and policy
  derived from membership — never from string-sniffing at decision sites.

  Sits beside `JidoClaw.Orchestration.Verdict` so infra ≠ verdict ≠ failure
  stays one vocabulary, and ABOVE `JidoClaw.Forge.Error.classify/1` (whose
  `{kind, recovery}` contract is pinned — this module composes on top of it,
  never breaks it).

  ## The two independent predicates

  `retryable?/1` answers "may the WORK be re-attempted?" and
  `resume_unsafe?/1` answers "must the CONVERSATION (native CLI session
  anchor) be abandoned?" — independent decisions (multica's sharpest idea).
  Their overlap (`agent_semantic_inactivity`, `agent_session_poisoned` are
  retryable AND resume-unsafe: retry the work fresh, never on the old anchor)
  is the point of keeping two predicates rather than one severity scale.

  The retryable set is deliberately narrow — a conservative, multica-faithful
  default and a consumer policy seam. It is NOT justified by "HTTP-level
  retries already happened" (false for Anthropic 5xx in the current stack);
  widening it is a consumer policy decision, made against this vocabulary.

  ## Totality

  `classify/1` and `format_reason/2` are total over arbitrary input —
  exceptions, throws, and exits inside classification all fall back to
  `:agent_unknown` / a bounded fallback string. Inner extraction
  (`Exception.message/1` on hostile exceptions, `String.downcase/1` on
  invalid UTF-8) is additionally guarded so the outer wrapper is the
  backstop, not the mechanism.

  ## Producer status

  Two kinds are deliberately producer-pending (documented, never silent
  warts): `stalled_no_output` (no silence watchdog exists yet — pre-argus
  Wave B #8 registers the composer-level stall) and
  `agent_runtime_version_unsupported` (no runtime version probe exists).
  Full per-kind producer table: `docs/system/run-failure.md`.
  """

  alias JidoClaw.Forge.Error, as: ForgeError
  alias JidoClaw.Orchestration.Verdict

  @typedoc "The closed 22-kind run-failure vocabulary."
  @type kind ::
          :iteration_limit
          | :api_invalid_request
          | :stalled_wall_clock
          | :stalled_no_output
          | :user_cancelled
          | :agent_provider_auth_or_access
          | :agent_provider_quota_limit
          | :agent_provider_capacity_or_rate_limit
          | :agent_provider_server_error
          | :agent_provider_network
          | :agent_timeout
          | :agent_process_failure
          | :agent_empty_or_unparseable_output
          | :agent_context_overflow
          | :agent_missing_config
          | :agent_model_not_found_or_unavailable
          | :agent_runtime_version_unsupported
          | :agent_runtime_missing_executable
          | :agent_fallback_message
          | :agent_semantic_inactivity
          | :agent_session_poisoned
          | :agent_unknown

  @platform_kinds [
    :iteration_limit,
    :api_invalid_request,
    :stalled_wall_clock,
    :stalled_no_output,
    :user_cancelled
  ]

  @agent_kinds [
    :agent_provider_auth_or_access,
    :agent_provider_quota_limit,
    :agent_provider_capacity_or_rate_limit,
    :agent_provider_server_error,
    :agent_provider_network,
    :agent_timeout,
    :agent_process_failure,
    :agent_empty_or_unparseable_output,
    :agent_context_overflow,
    :agent_missing_config,
    :agent_model_not_found_or_unavailable,
    :agent_runtime_version_unsupported,
    :agent_runtime_missing_executable,
    :agent_fallback_message,
    :agent_semantic_inactivity,
    :agent_session_poisoned,
    :agent_unknown
  ]

  @all_kinds @platform_kinds ++ @agent_kinds

  # Retry-the-WORK eligibility (multica retryableReasons, daemon members
  # dropped, plus the OR3-2 stall split and the poisoned-anchor family).
  @retryable [
    :stalled_wall_clock,
    :stalled_no_output,
    :agent_semantic_inactivity,
    :agent_session_poisoned
  ]

  # Reuse-the-CONVERSATION prohibition (multica resumeUnsafeFailureReason):
  # a member's failure poisons the native CLI session anchor.
  @resume_unsafe [
    :iteration_limit,
    :agent_fallback_message,
    :api_invalid_request,
    :agent_semantic_inactivity,
    :agent_session_poisoned
  ]

  # Splode-container leaf precedence: most-informative-first, TOTAL over the
  # enum (compile-guarded below) so permuting a container's leaves can never
  # change the answer. `user_cancelled` ranks first — a cancel inside a
  # container means the run was cancelled and sibling errors are teardown
  # noise. The plan-stated spine (auth > quota > rate > api_invalid_request >
  # model > server > network > session_poisoned > context_overflow >
  # timeout-kinds > missing_config/missing_executable > empty_output >
  # process_failure > unknown) is preserved; the unlisted kinds slot beside
  # their nearest class.
  @container_precedence [
    :user_cancelled,
    :agent_provider_auth_or_access,
    :agent_provider_quota_limit,
    :agent_provider_capacity_or_rate_limit,
    :api_invalid_request,
    :agent_model_not_found_or_unavailable,
    :agent_provider_server_error,
    :agent_provider_network,
    :agent_session_poisoned,
    :agent_semantic_inactivity,
    :agent_fallback_message,
    :iteration_limit,
    :agent_context_overflow,
    :agent_timeout,
    :stalled_wall_clock,
    :stalled_no_output,
    :agent_missing_config,
    :agent_runtime_missing_executable,
    :agent_runtime_version_unsupported,
    :agent_empty_or_unparseable_output,
    :agent_process_failure,
    :agent_unknown
  ]

  if Enum.sort(@container_precedence) != Enum.sort(@all_kinds) do
    raise CompileError,
      description: "RunFailure container precedence must rank every kind exactly once"
  end

  @container_rank Map.new(Enum.with_index(@container_precedence))

  @decode_map Map.new(@all_kinds, &{Atom.to_string(&1), &1})

  @forge_error_structs [
    ForgeError.ProvisionError,
    ForgeError.BootstrapError,
    ForgeError.ExecSessionError,
    ForgeError.TimeoutError,
    ForgeError.SandboxError
  ]

  # Nested-cause unwrapping bound: `{:error, _}` shells, wrapper `details.cause`
  # digs, and container leaves all count a level; anything deeper is wrapper
  # lasagna, not signal.
  @max_unwrap_depth 3

  # Bounded reason rendering is `Verdict.bounded_inspect/1` — the one shared
  # renderer (same inspect/grapheme caps by construction, not by copy).

  # Ordered most-specific-first (the classify.go discipline): producer-exact
  # markers, then the session-poison family (BEFORE the numeric-code rules so
  # a poisoned 400 stays poisoned), then context overflow (providers ship it
  # as a 400), then the provider classes, with bare timeout words LAST (many
  # messages embed "timeout" incidentally). All substrings lowercase; numeric
  # status codes only as boundary-safe regexes (`\b401\b` never matches
  # "40123" or "error 4010").
  @string_rules [
    {"harness_timeout", :stalled_wall_clock},
    {"runner_unavailable", :agent_runtime_missing_executable},
    {"max_iterations_reached", :iteration_limit},
    {"run_cancelled", :user_cancelled},
    {"cancelled by user", :user_cancelled},
    {"invalid_encrypted_content", :agent_session_poisoned},
    {"rollout path", :agent_session_poisoned},
    # codex 0.144.1 resume rejection, verified live: "Error: thread/resume:
    # thread/resume failed: no rollout found for thread id <uuid>".
    {"no rollout found", :agent_session_poisoned},
    {"tool_call_id", :agent_session_poisoned},
    {"session not found", :agent_session_poisoned},
    {"thread not found", :agent_session_poisoned},
    {"conversation not found", :agent_session_poisoned},
    # claude CLI resume rejection: "No conversation found with session ID: …"
    # ("conversation not found" above doesn't substring-match this shape).
    {"no conversation found", :agent_session_poisoned},
    {"session expired", :agent_session_poisoned},
    {"thread expired", :agent_session_poisoned},
    {"resume rejected", :agent_session_poisoned},
    {"context length", :agent_context_overflow},
    {"context_length", :agent_context_overflow},
    {"context window", :agent_context_overflow},
    {"maximum context", :agent_context_overflow},
    {"prompt is too long", :agent_context_overflow},
    {"too many tokens", :agent_context_overflow},
    {"invalid api key", :agent_provider_auth_or_access},
    {"invalid x-api-key", :agent_provider_auth_or_access},
    {"authentication", :agent_provider_auth_or_access},
    {"unauthorized", :agent_provider_auth_or_access},
    {"permission denied", :agent_provider_auth_or_access},
    {"forbidden", :agent_provider_auth_or_access},
    {~r/\b401\b/, :agent_provider_auth_or_access},
    {~r/\b403\b/, :agent_provider_auth_or_access},
    {"credit balance", :agent_provider_quota_limit},
    {"insufficient credit", :agent_provider_quota_limit},
    {"quota", :agent_provider_quota_limit},
    {"billing", :agent_provider_quota_limit},
    {"payment required", :agent_provider_quota_limit},
    {~r/\b402\b/, :agent_provider_quota_limit},
    {"rate limit", :agent_provider_capacity_or_rate_limit},
    {"rate_limit", :agent_provider_capacity_or_rate_limit},
    {"too many requests", :agent_provider_capacity_or_rate_limit},
    {"overloaded", :agent_provider_capacity_or_rate_limit},
    {~r/\b429\b/, :agent_provider_capacity_or_rate_limit},
    {~r/\b529\b/, :agent_provider_capacity_or_rate_limit},
    {"model not found", :agent_model_not_found_or_unavailable},
    {"model_not_found", :agent_model_not_found_or_unavailable},
    {"no such model", :agent_model_not_found_or_unavailable},
    {"unknown model", :agent_model_not_found_or_unavailable},
    {"model unavailable", :agent_model_not_found_or_unavailable},
    {"invalid_request_error", :api_invalid_request},
    {"invalid request", :api_invalid_request},
    {"request too large", :api_invalid_request},
    {~r/\b400\b/, :api_invalid_request},
    {~r/\b413\b/, :api_invalid_request},
    {"internal server error", :agent_provider_server_error},
    {"server_error", :agent_provider_server_error},
    {"server error", :agent_provider_server_error},
    {"bad gateway", :agent_provider_server_error},
    {"service unavailable", :agent_provider_server_error},
    {"api_error", :agent_provider_server_error},
    {~r/\b50[0234]\b/, :agent_provider_server_error},
    {"econnrefused", :agent_provider_network},
    {"connection refused", :agent_provider_network},
    {"nxdomain", :agent_provider_network},
    {"econnreset", :agent_provider_network},
    {"connection reset", :agent_provider_network},
    {"connection closed", :agent_provider_network},
    {"tls handshake", :agent_provider_network},
    {"ssl error", :agent_provider_network},
    {"unreachable", :agent_provider_network},
    {"network", :agent_provider_network},
    {"command not found", :agent_runtime_missing_executable},
    {"executable not found", :agent_runtime_missing_executable},
    {"no such file or directory", :agent_runtime_missing_executable},
    {"enoent", :agent_runtime_missing_executable},
    {"missing api key", :agent_missing_config},
    {"api key not set", :agent_missing_config},
    {"no api key", :agent_missing_config},
    {"not configured", :agent_missing_config},
    {"missing config", :agent_missing_config},
    {"empty output", :agent_empty_or_unparseable_output},
    {"unparseable", :agent_empty_or_unparseable_output},
    {"malformed output", :agent_empty_or_unparseable_output},
    {"iteration limit", :iteration_limit},
    {"max iterations", :iteration_limit},
    {"request timed out", :agent_timeout},
    {"receive timeout", :agent_timeout},
    {"timed out", :stalled_wall_clock},
    {"timeout", :stalled_wall_clock},
    {"deadline exceeded", :stalled_wall_clock}
  ]

  @reserved_detail_keys [:retry, "retry", :failure_kind, "failure_kind", :reason, "reason"]

  @doc """
  Classify an arbitrary failure term into the closed vocabulary. Total: any
  input — hostile exceptions, throwers, exiters, invalid UTF-8 — maps to a
  kind, never a raise (`:agent_unknown` is the unconditional backstop).
  """
  @spec classify(term()) :: kind()
  def classify(term) do
    do_classify(term, 0)
  rescue
    # Totality backstop (the contract: classify/1 never raises) — any hostile
    # shape a specific arm mishandles classifies unknown, never crashes the
    # caller's terminal path.
    # reach:disable-next-line bare_rescue
    _ -> :agent_unknown
  catch
    _, _ -> :agent_unknown
  end

  @doc "True unless the kind is the non-failure member (`:user_cancelled`)."
  @spec failure?(kind()) :: boolean()
  def failure?(kind) when kind in @all_kinds, do: kind != :user_cancelled

  @doc "May the WORK be re-attempted? Independent of `resume_unsafe?/1`."
  @spec retryable?(kind()) :: boolean()
  def retryable?(kind) when kind in @all_kinds, do: kind in @retryable

  @doc """
  Must the CONVERSATION (native CLI session anchor) be abandoned? Independent
  of `retryable?/1` — the overlap members retry fresh, never on the anchor.
  """
  @spec resume_unsafe?(kind()) :: boolean()
  def resume_unsafe?(kind) when kind in @all_kinds, do: kind in @resume_unsafe

  @doc "Whose side of the boundary produced the failure."
  @spec provenance(kind()) :: :platform | :agent
  def provenance(kind) when kind in @platform_kinds, do: :platform
  def provenance(kind) when kind in @agent_kinds, do: :agent

  @doc """
  The closed kind set, stable order (platform then agent). The telemetry
  label pre-warm export (multica `AllReasons()`) and the totality-test
  domain.
  """
  @spec all_kinds() :: [kind()]
  def all_kinds, do: @all_kinds

  @doc "Whitelist-decode a kind from its string form — never `String.to_atom/1`."
  @spec decode(String.t()) :: {:ok, kind()} | :error
  def decode(value) when is_binary(value), do: Map.fetch(@decode_map, value)

  @doc """
  Render `kind` plus the raw failure term as one bounded human-readable
  string for events, traces, and terminal errors. Total over any raw term.
  """
  @spec format_reason(kind(), term()) :: String.t()
  def format_reason(kind, raw) when is_atom(kind) do
    "#{kind}: #{Verdict.bounded_inspect(raw)}"
  rescue
    # Totality backstop for hostile Inspect implementations.
    # reach:disable-next-line bare_rescue
    _ -> Atom.to_string(kind) <> ": <unrenderable>"
  catch
    _, _ -> Atom.to_string(kind) <> ": <unrenderable>"
  end

  @doc """
  Build the failure slice of an error-details map: `%{failure_kind: kind,
  retry: retryable?(kind)}` merged OVER `extra` after stripping the reserved
  keys in both atom and string forms (`:retry`, `:failure_kind`, `:reason`) —
  callers can never override the policy bits or reintroduce `:reason`
  (retry-hint diggers read it; the LoopGuard `:trigger` precedent).
  """
  @spec error_details(kind(), map()) :: map()
  def error_details(kind, extra \\ %{}) when kind in @all_kinds and is_map(extra) do
    extra
    |> Map.drop(@reserved_detail_keys)
    |> Map.merge(%{failure_kind: kind, retry: retryable?(kind)})
  end

  # A vendor CLI streaming JSONL (`--output-format stream-json` / `--json`)
  # that instead prints one short bare text line produced a fallback MESSAGE,
  # not work — the `:agent_fallback_message` producer heuristic (multica's
  # fallback-marker detection, MC1-1 rider).
  @fallback_marker_max_bytes 320

  @doc """
  The `{:fallback_marker, output}` producer heuristic for armed vendor
  runners: a non-empty single-line output of ≤ #{@fallback_marker_max_bytes}
  bytes that is NOT stream-JSONL protocol output (no leading `{`). Total —
  non-binary input is never a marker.
  """
  @spec fallback_marker?(term()) :: boolean()
  def fallback_marker?(output) when is_binary(output) do
    trimmed = String.trim(output)

    trimmed != "" and
      byte_size(trimmed) <= @fallback_marker_max_bytes and
      not String.contains?(trimmed, "\n") and
      not String.starts_with?(trimmed, "{")
  end

  def fallback_marker?(_), do: false

  # ---------------------------------------------------------------------------
  # classify/1 rule order (most-specific-first, the classify.go discipline):
  # 1. unwrap {:error, _} shells; 2. cancels; 3. specific dep/first-party
  # struct clauses (wrappers dig details.cause before their own dispatch);
  # 4. Splode class containers via the precedence rank; 5. generic exceptions
  # through the guarded string arm; 6. producer tuples/atoms; 7. strings;
  # 8. :agent_unknown.
  # ---------------------------------------------------------------------------

  defp do_classify(_term, depth) when depth > @max_unwrap_depth, do: :agent_unknown

  defp do_classify({:error, reason}, depth), do: do_classify(reason, depth + 1)

  defp do_classify(:cancelled, _depth), do: :user_cancelled
  defp do_classify(:run_cancelled, _depth), do: :user_cancelled
  defp do_classify({:cancelled, _}, _depth), do: :user_cancelled
  defp do_classify(%{status: :cancelled}, _depth), do: :user_cancelled

  defp do_classify(%Jido.AI.Error.API.Auth{}, _depth), do: :agent_provider_auth_or_access

  defp do_classify(%Jido.AI.Error.API.RateLimit{}, _depth),
    do: :agent_provider_capacity_or_rate_limit

  defp do_classify(%Jido.AI.Error.API.Request{kind: :timeout}, _depth), do: :agent_timeout

  defp do_classify(%Jido.AI.Error.API.Request{kind: :network}, _depth),
    do: :agent_provider_network

  defp do_classify(%Jido.AI.Error.API.Request{kind: :provider, status: status}, _depth)
       when is_integer(status),
       do: kind_for_status(status)

  defp do_classify(%Jido.AI.Error.API.Request{kind: :provider}, _depth),
    do: :agent_provider_server_error

  defp do_classify(%Jido.AI.Error.API.Request{} = error, _depth),
    do: classify_string(safe_message(error))

  defp do_classify(%Jido.AI.Error.Unknown{error: inner}, depth) when not is_nil(inner),
    do: do_classify(inner, depth + 1)

  # ReqLLM API.Request: an HTTP status is authoritative; nil status means no
  # response arrived — dispatch on the transport cause (timeout-shaped vs
  # connection-level).
  defp do_classify(%ReqLLM.Error.API.Request{status: status}, _depth)
       when is_integer(status),
       do: kind_for_status(status)

  defp do_classify(%ReqLLM.Error.API.Request{cause: cause}, _depth) do
    if timeout_shaped?(cause), do: :agent_timeout, else: :agent_provider_network
  end

  # ReqLLM API.Response: the parse/unexpected-output class. A non-2xx status
  # is the provider speaking; 2xx/nil means the payload itself was
  # unusable.
  defp do_classify(%ReqLLM.Error.API.Response{status: status}, _depth)
       when is_integer(status) and (status < 200 or status >= 300),
       do: kind_for_status(status)

  defp do_classify(%ReqLLM.Error.API.Response{}, _depth),
    do: :agent_empty_or_unparseable_output

  defp do_classify(%Jido.Error.TimeoutError{}, _depth), do: :agent_timeout
  defp do_classify(%Jido.Action.Error.TimeoutError{}, _depth), do: :agent_timeout

  defp do_classify(%JidoClaw.Error.ConfigError{}, _depth), do: :agent_missing_config

  # A `:timeout`-phase wrapper is timeout-specific by construction (built
  # only from `{:timeout, ms}` shapes — whose raw tuple also rides
  # `details.cause`, so digging first would flatten the operation split):
  # dispatch on the operation BEFORE the generic cause dig.
  defp do_classify(%JidoClaw.Error.ExecutionError{phase: :timeout} = error, _depth),
    do: classify_execution_timeout(error)

  # ExecutionError is the Normalize layer's generic wrapper — dig the known
  # nested cause (normalize.ex wraps Jido.AI failures under `details.cause`)
  # and use it when specific; only then dispatch on the wrapper's own phase.
  defp do_classify(%JidoClaw.Error.ExecutionError{} = error, depth) do
    case dig_cause(error, depth) do
      {:ok, kind} -> kind
      :none -> classify_execution_error(error)
    end
  end

  # A boundary/input error reaching run-failure classification is a caller
  # bug, not an agent-run class — documented as :agent_unknown.
  defp do_classify(%JidoClaw.Error.ValidationError{}, _depth), do: :agent_unknown

  defp do_classify(%JidoClaw.Error.Internal.UnknownError{error: inner}, depth)
       when not is_nil(inner),
       do: do_classify(inner, depth + 1)

  defp do_classify(%mod{} = error, _depth) when mod in @forge_error_structs,
    do: kind_for_forge_pair(ForgeError.classify(error))

  defp do_classify(%struct{errors: errors} = error, depth) when is_list(errors) do
    if splode_class?(struct) do
      classify_container(errors, depth)
    else
      classify_exception_or_unknown(error)
    end
  end

  defp do_classify(%_{} = error, _depth) when is_exception(error),
    do: classify_exception_or_unknown(error)

  defp do_classify({:fallback_marker, _}, _depth), do: :agent_fallback_message
  defp do_classify({:iteration_limit, _}, _depth), do: :iteration_limit
  defp do_classify(:max_iterations_reached, _depth), do: :iteration_limit
  defp do_classify(:unauthorized, _depth), do: :agent_provider_auth_or_access
  defp do_classify(:unreachable, _depth), do: :agent_provider_network
  defp do_classify(:timeout, _depth), do: :stalled_wall_clock

  # `{:timeout, ms}` (the Normalize timeout tuple) must precede the generic
  # `{_, integer}` exit-code arm.
  defp do_classify({:timeout, _}, _depth), do: :stalled_wall_clock
  defp do_classify({_, :timeout}, _depth), do: :stalled_wall_clock
  defp do_classify({_, :output_limit}, _depth), do: :agent_process_failure
  defp do_classify({_, 124}, _depth), do: :stalled_wall_clock
  defp do_classify({_, 127}, _depth), do: :agent_runtime_missing_executable
  defp do_classify({_, code}, _depth) when is_integer(code), do: :agent_process_failure

  defp do_classify(reason, _depth) when is_binary(reason), do: classify_string(reason)

  defp do_classify(_term, _depth), do: :agent_unknown

  # ---------------------------------------------------------------------------
  # Container + wrapper helpers
  # ---------------------------------------------------------------------------

  # Splode class containers (a class struct wrapping an `errors` list):
  # classify every leaf, then pick by the explicit precedence rank — order-
  # invariant by construction (permuting leaves cannot change the answer).
  defp classify_container([], _depth), do: :agent_unknown

  defp classify_container(errors, depth) do
    errors
    |> Enum.map(&do_classify(&1, depth + 1))
    |> Enum.min_by(&Map.fetch!(@container_rank, &1))
  end

  defp splode_class?(struct) do
    function_exported?(struct, :error_class?, 0) and struct.error_class?()
  rescue
    # Structural probe of a foreign module: a stub `error_class?/0` must
    # answer "not a class", not crash classification.
    # reach:disable-next-line bare_rescue
    _ -> false
  end

  defp dig_cause(%{details: details}, depth) when is_map(details) do
    # Verdict.field/2 is the shared atom-key-wins/string-key-fallback read —
    # the jsonb round-trip tolerance, single-sourced beside this module.
    case Verdict.field(details, :cause) do
      nil ->
        :none

      cause ->
        case do_classify(cause, depth + 1) do
          :agent_unknown -> :none
          kind -> {:ok, kind}
        end
    end
  end

  defp dig_cause(_error, _depth), do: :none

  # A `:timeout` phase from the forge domain is the sandbox wall clock; from
  # anywhere else it is the agent's own request timing out.
  defp classify_execution_timeout(%{details: details}) when is_map(details) do
    if Map.get(details, :operation) == :forge, do: :stalled_wall_clock, else: :agent_timeout
  end

  defp classify_execution_timeout(_error), do: :agent_timeout

  # Wrapper-phase dispatch AFTER the cause dig came back unspecific. Forge
  # phases compose through the pinned `Forge.Error.classify/1` contract.
  defp classify_execution_error(%{phase: phase} = error) when phase in [:provision, :bootstrap],
    do: kind_for_forge_pair(ForgeError.classify(error))

  defp classify_execution_error(error), do: classify_string(safe_message(error))

  # Compose over the pinned `{kind, recovery}` contract — never re-match the
  # Forge structs here. Retry-ness is NOT inherited (RunFailure policy is
  # membership-derived).
  defp kind_for_forge_pair({:timeout, _recovery}), do: :stalled_wall_clock
  defp kind_for_forge_pair({:provision_failed, _recovery}), do: :agent_process_failure
  defp kind_for_forge_pair({:bootstrap_failed, _recovery}), do: :agent_process_failure
  defp kind_for_forge_pair({:exec_failed, _recovery}), do: :agent_process_failure
  defp kind_for_forge_pair(_pair), do: :agent_unknown

  defp classify_exception_or_unknown(error) when is_exception(error),
    do: classify_string(safe_message(error))

  defp classify_exception_or_unknown(_error), do: :agent_unknown

  defp timeout_shaped?(:timeout), do: true
  defp timeout_shaped?({:timeout, _}), do: true
  defp timeout_shaped?(%{reason: :timeout}), do: true
  defp timeout_shaped?(%{reason: {:timeout, _}}), do: true
  defp timeout_shaped?(_cause), do: false

  # Shared HTTP-status dispatch for the provider-error structs. 529 is
  # Anthropic's overloaded signal — capacity, not a generic 5xx; 404 in an
  # LLM-request context is the model, not a page.
  defp kind_for_status(status) when status in [401, 403], do: :agent_provider_auth_or_access
  defp kind_for_status(402), do: :agent_provider_quota_limit
  defp kind_for_status(404), do: :agent_model_not_found_or_unavailable
  defp kind_for_status(408), do: :agent_timeout
  defp kind_for_status(429), do: :agent_provider_capacity_or_rate_limit
  defp kind_for_status(529), do: :agent_provider_capacity_or_rate_limit
  defp kind_for_status(status) when status >= 500, do: :agent_provider_server_error
  defp kind_for_status(status) when status >= 400, do: :api_invalid_request
  defp kind_for_status(_status), do: :agent_unknown

  # ---------------------------------------------------------------------------
  # String arm
  # ---------------------------------------------------------------------------

  defp classify_string(string) when is_binary(string) do
    case safe_downcase(string) do
      nil ->
        :agent_unknown

      downcased ->
        Enum.find_value(@string_rules, :agent_unknown, fn {matcher, kind} ->
          if string_matches?(downcased, matcher), do: kind
        end)
    end
  end

  defp string_matches?(string, %Regex{} = regex), do: Regex.match?(regex, string)
  defp string_matches?(string, substring), do: String.contains?(string, substring)

  # Invalid UTF-8 cannot be sniffed (String.downcase/1 would raise) — the
  # string arm abstains and the caller falls back to :agent_unknown.
  defp safe_downcase(string) do
    if String.valid?(string), do: String.downcase(string)
  end

  # The exception's OWN message/1, invoked directly — `Exception.message/1`
  # SHIELDS a raising callback and returns diagnostic text describing the
  # failure (module, call site line numbers), which the string arm could
  # then false-positive on (a `\b401\b`-class rule matching a `file.ex:401`
  # fragment). A hostile `message/1` must classify unknown, so the string
  # arm gets nothing to sniff — never the shield's text.
  defp safe_message(%module{} = error) do
    case module.message(error) do
      msg when is_binary(msg) -> msg
      _ -> ""
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> ""
  catch
    _, _ -> ""
  end
end
