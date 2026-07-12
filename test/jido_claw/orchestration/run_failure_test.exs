defmodule JidoClaw.Orchestration.RunFailureTest.RaisingMessageError do
  defexception [:message]

  @impl Exception
  def message(_error), do: raise("hostile message")
end

defmodule JidoClaw.Orchestration.RunFailureTest.ThrowingMessageError do
  defexception [:message]

  @impl Exception
  def message(_error), do: throw(:hostile_throw)
end

defmodule JidoClaw.Orchestration.RunFailureTest.ExitingMessageError do
  defexception [:message]

  @impl Exception
  def message(_error), do: exit(:hostile_exit)
end

defmodule JidoClaw.Orchestration.RunFailureTest.HostileInspect do
  defstruct [:x]
end

defmodule JidoClaw.Orchestration.RunFailureTest do
  @moduledoc """
  MC1-4 — the 22-kind run-failure taxonomy. Classify rule table over every
  producer input, Normalize-integration rows (the exit-5/6 path), totality
  over hostile input (raisers, throwers, exiters, invalid UTF-8), container
  permutation invariance, boundary-safe numeric codes, exact derived-set
  membership, and the bounded renderers.
  """
  use ExUnit.Case, async: true

  alias Jido.Action.Error.TimeoutError, as: ActionTimeoutError
  alias Jido.AI.Error.API.Auth
  alias Jido.AI.Error.API.RateLimit
  alias Jido.AI.Error.API.Request, as: AIRequest
  alias Jido.Error.TimeoutError, as: JidoTimeoutError
  alias JidoClaw.Error.Execution, as: ExecutionClass
  alias JidoClaw.Error.Normalize
  alias JidoClaw.Forge.Error, as: ForgeError
  alias JidoClaw.Orchestration.RunFailure
  alias ReqLLM.Error.API.Request, as: LLMRequest
  alias ReqLLM.Error.API.Response, as: LLMResponse

  alias JidoClaw.Orchestration.RunFailureTest.ExitingMessageError
  alias JidoClaw.Orchestration.RunFailureTest.HostileInspect
  alias JidoClaw.Orchestration.RunFailureTest.RaisingMessageError
  alias JidoClaw.Orchestration.RunFailureTest.ThrowingMessageError

  describe "classify/1 — producer table" do
    test "runner terminal strings" do
      assert RunFailure.classify("harness_timeout") == :stalled_wall_clock
      assert RunFailure.classify("runner_unavailable") == :agent_runtime_missing_executable
    end

    test "sandbox tuples and exit codes" do
      assert RunFailure.classify({"partial output", :timeout}) == :stalled_wall_clock
      assert RunFailure.classify({"too big", :output_limit}) == :agent_process_failure
      assert RunFailure.classify({"", 124}) == :stalled_wall_clock

      assert RunFailure.classify({"bash: claude: command not found", 127}) ==
               :agent_runtime_missing_executable

      assert RunFailure.classify({"boom", 3}) == :agent_process_failure
    end

    test "iteration bound shapes (never the deadline)" do
      assert RunFailure.classify(:max_iterations_reached) == :iteration_limit
      assert RunFailure.classify({:iteration_limit, 8}) == :iteration_limit
      assert RunFailure.classify({:ok, :max_iterations_reached}) == :agent_unknown
    end

    test "cancel shapes are the non-failure kind" do
      for shape <- [:cancelled, :run_cancelled, {:cancelled, :user}, %{status: :cancelled}] do
        assert RunFailure.classify(shape) == :user_cancelled
      end
    end

    test "fallback marker and bare atoms" do
      assert RunFailure.classify({:fallback_marker, "I'm sorry, I can't help."}) ==
               :agent_fallback_message

      assert RunFailure.classify(:unauthorized) == :agent_provider_auth_or_access
      assert RunFailure.classify(:unreachable) == :agent_provider_network
      assert RunFailure.classify(:timeout) == :stalled_wall_clock
      assert RunFailure.classify({:timeout, 5_000}) == :stalled_wall_clock
    end

    test "{:error, _} shells unwrap, depth-bounded" do
      assert RunFailure.classify({:error, :unauthorized}) == :agent_provider_auth_or_access

      assert RunFailure.classify({:error, {:error, {:error, :unauthorized}}}) ==
               :agent_provider_auth_or_access

      assert RunFailure.classify({:error, {:error, {:error, {:error, :unauthorized}}}}) ==
               :agent_unknown
    end
  end

  describe "classify/1 — Jido.AI struct rows" do
    test "Auth and RateLimit" do
      assert RunFailure.classify(Auth.exception(message: "bad key")) ==
               :agent_provider_auth_or_access

      assert RunFailure.classify(RateLimit.exception(retry_after: 30)) ==
               :agent_provider_capacity_or_rate_limit
    end

    test "Request dispatches on its kind field" do
      assert RunFailure.classify(AIRequest.exception(kind: :timeout)) ==
               :agent_timeout

      assert RunFailure.classify(AIRequest.exception(kind: :network)) ==
               :agent_provider_network

      assert RunFailure.classify(AIRequest.exception(kind: :provider, status: 500)) ==
               :agent_provider_server_error

      assert RunFailure.classify(AIRequest.exception(kind: :provider, status: 429)) ==
               :agent_provider_capacity_or_rate_limit

      assert RunFailure.classify(AIRequest.exception(kind: :provider)) ==
               :agent_provider_server_error
    end
  end

  describe "classify/1 — ReqLLM struct rows" do
    test "API.Request by status" do
      rows = [
        {401, :agent_provider_auth_or_access},
        {403, :agent_provider_auth_or_access},
        {402, :agent_provider_quota_limit},
        {400, :api_invalid_request},
        {404, :agent_model_not_found_or_unavailable},
        {408, :agent_timeout},
        {429, :agent_provider_capacity_or_rate_limit},
        {529, :agent_provider_capacity_or_rate_limit},
        {500, :agent_provider_server_error},
        {503, :agent_provider_server_error},
        {422, :api_invalid_request}
      ]

      for {status, expected} <- rows do
        error = LLMRequest.exception(reason: "r", status: status)
        assert RunFailure.classify(error) == expected, "status #{status}"
      end
    end

    test "API.Request nil status dispatches on the transport cause" do
      timeout_cause = Req.TransportError.exception(reason: :timeout)
      refused_cause = Req.TransportError.exception(reason: :econnrefused)

      assert RunFailure.classify(LLMRequest.exception(reason: "r", cause: timeout_cause)) ==
               :agent_timeout

      assert RunFailure.classify(LLMRequest.exception(reason: "r", cause: refused_cause)) ==
               :agent_provider_network

      assert RunFailure.classify(LLMRequest.exception(reason: "r")) ==
               :agent_provider_network
    end

    test "API.Response: non-2xx speaks provider, 2xx/nil is unusable payload" do
      assert RunFailure.classify(LLMResponse.exception(reason: "r", status: 500)) ==
               :agent_provider_server_error

      assert RunFailure.classify(LLMResponse.exception(reason: "r", status: 200)) ==
               :agent_empty_or_unparseable_output

      assert RunFailure.classify(LLMResponse.exception(reason: "r")) ==
               :agent_empty_or_unparseable_output
    end
  end

  describe "classify/1 — timeout leaves and first-party leaves" do
    test "both TimeoutError leaves are the agent's own request" do
      assert RunFailure.classify(JidoTimeoutError.exception(timeout: 5_000)) ==
               :agent_timeout

      assert RunFailure.classify(ActionTimeoutError.exception(timeout: 5_000)) ==
               :agent_timeout
    end

    test "ConfigError is missing config" do
      assert RunFailure.classify(JidoClaw.Error.config_error("Provider not configured")) ==
               :agent_missing_config
    end

    test "ExecutionError timeout phase splits on the operation" do
      assert RunFailure.classify(JidoClaw.Error.timeout(:reasoning, 5_000)) == :agent_timeout

      assert RunFailure.classify(Normalize.forge_error({:timeout, 5_000})) ==
               :stalled_wall_clock

      assert RunFailure.classify(Normalize.reasoning_error({:timeout, 5_000})) ==
               :agent_timeout
    end

    test "ExecutionError forge phases compose through Forge.Error.classify/1" do
      provision = JidoClaw.Error.execution_error("provision blew up", phase: :provision)
      assert RunFailure.classify(provision) == :agent_process_failure
    end

    test "ValidationError is a documented boundary error" do
      assert RunFailure.classify(JidoClaw.Error.validation_error("bad input")) ==
               :agent_unknown
    end
  end

  describe "classify/1 — Forge Splode structs compose via the pinned contract" do
    test "each struct maps through its {kind, recovery} pair" do
      assert RunFailure.classify(ForgeError.ProvisionError.exception(message: "m")) ==
               :agent_process_failure

      assert RunFailure.classify(ForgeError.BootstrapError.exception(message: "m")) ==
               :agent_process_failure

      assert RunFailure.classify(ForgeError.ExecSessionError.exception(message: "m")) ==
               :agent_process_failure

      assert RunFailure.classify(ForgeError.SandboxError.exception(message: "m")) ==
               :agent_process_failure

      assert RunFailure.classify(ForgeError.TimeoutError.exception(message: "m")) ==
               :stalled_wall_clock
    end
  end

  describe "classify/1 — Normalize integration (the exit-5/6 path)" do
    test "auth survives the reasoning_error wrap" do
      auth = Auth.exception(message: "invalid x-api-key")
      wrapped = Normalize.reasoning_error(auth)

      assert %JidoClaw.Error.ExecutionError{} = wrapped
      assert RunFailure.classify(wrapped) == :agent_provider_auth_or_access
    end

    test "network survives the reasoning_error wrap" do
      network = AIRequest.exception(kind: :network, message: "conn refused")
      wrapped = Normalize.reasoning_error(network)

      assert RunFailure.classify(wrapped) == :agent_provider_network
    end
  end

  describe "classify/1 — Splode container precedence" do
    test "permuting leaves never changes the answer (auth beats rate)" do
      auth = Auth.exception(message: "bad key")
      rate = RateLimit.exception(retry_after: 5)

      for leaves <- [[auth, rate], [rate, auth]] do
        container = ExecutionClass.exception(errors: leaves)
        assert RunFailure.classify(container) == :agent_provider_auth_or_access
      end
    end

    test "specific beats unknown regardless of order" do
      unknown = RuntimeError.exception("mystery")
      process = ForgeError.ExecSessionError.exception(message: "exec died")

      for leaves <- [[unknown, process], [process, unknown]] do
        container = ExecutionClass.exception(errors: leaves)
        assert RunFailure.classify(container) == :agent_process_failure
      end
    end

    test "an empty container is unknown" do
      assert RunFailure.classify(ExecutionClass.exception(errors: [])) ==
               :agent_unknown
    end
  end

  describe "classify/1 — string arm" do
    test "session-poison family beats the generic numeric rules" do
      assert RunFailure.classify("400 invalid_encrypted_content in rollout") ==
               :agent_session_poisoned

      assert RunFailure.classify("session not found or expired") == :agent_session_poisoned

      assert RunFailure.classify("unknown tool_call_id in request (400)") ==
               :agent_session_poisoned
    end

    test "the verified vendor resume-rejection messages classify session-poisoned" do
      # claude CLI, verified live: leading bare line on a rejected --resume.
      assert RunFailure.classify(
               "No conversation found with session ID: 018f0000-0000-7000-8000-000000000001"
             ) == :agent_session_poisoned

      # codex 0.144.1, verified live: single-line rejection on `exec resume`.
      assert RunFailure.classify(
               "Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-0000-0000-0000-000000000001 (code -32600)"
             ) == :agent_session_poisoned
    end

    test "context overflow beats the generic 400" do
      assert RunFailure.classify("400: prompt is too long for the context window") ==
               :agent_context_overflow
    end

    test "provider classes" do
      assert RunFailure.classify("Authentication failed for key") ==
               :agent_provider_auth_or_access

      assert RunFailure.classify("your credit balance is too low") ==
               :agent_provider_quota_limit

      assert RunFailure.classify("Rate limit exceeded, slow down") ==
               :agent_provider_capacity_or_rate_limit

      assert RunFailure.classify("The model is overloaded") ==
               :agent_provider_capacity_or_rate_limit

      assert RunFailure.classify("model not found: fable-9") ==
               :agent_model_not_found_or_unavailable

      assert RunFailure.classify("invalid_request_error: field x") == :api_invalid_request
      assert RunFailure.classify("Internal Server Error") == :agent_provider_server_error
      assert RunFailure.classify("econnrefused talking upstream") == :agent_provider_network

      assert RunFailure.classify("zsh: command not found: codex") ==
               :agent_runtime_missing_executable

      assert RunFailure.classify("ANTHROPIC_API_KEY not configured") == :agent_missing_config
    end

    test "boundary-safe numeric codes (negatives)" do
      assert RunFailure.classify("HTTP 401 from provider") == :agent_provider_auth_or_access

      assert RunFailure.classify("status 429 returned") ==
               :agent_provider_capacity_or_rate_limit

      assert RunFailure.classify("request id 40123 processed") == :agent_unknown
      assert RunFailure.classify("code 4010 emitted") == :agent_unknown
      assert RunFailure.classify("item 5031 shipped") == :agent_unknown
    end

    test "timeout words rank last so richer classes win first" do
      assert RunFailure.classify("rate limit hit before the timeout") ==
               :agent_provider_capacity_or_rate_limit

      assert RunFailure.classify("the request timed out") == :agent_timeout
      assert RunFailure.classify("operation timed out after 60s") == :stalled_wall_clock
      assert RunFailure.classify("deadline exceeded") == :stalled_wall_clock
    end
  end

  describe "fallback_marker?/1 (the :agent_fallback_message producer heuristic)" do
    test "a short bare single line is a marker" do
      assert RunFailure.fallback_marker?("I'm unable to continue this conversation.")
      assert RunFailure.fallback_marker?("  Something went wrong.  \n")
    end

    test "stream-JSONL protocol output is never a marker" do
      refute RunFailure.fallback_marker?(~s({"type":"result","subtype":"success"}))
    end

    test "multi-line, oversized, empty, and non-binary inputs are never markers" do
      refute RunFailure.fallback_marker?("line one\nline two")
      refute RunFailure.fallback_marker?(String.duplicate("x", 321))
      refute RunFailure.fallback_marker?("")
      refute RunFailure.fallback_marker?("   \n  ")
      refute RunFailure.fallback_marker?(nil)
      refute RunFailure.fallback_marker?({:error, "x"})
    end

    test "exactly 320 bytes still qualifies (the bound is inclusive)" do
      assert RunFailure.fallback_marker?(String.duplicate("x", 320))
    end
  end

  describe "classify/1 — totality" do
    test "arbitrary garbage classifies unknown, never raises" do
      for garbage <- [
            42,
            3.14,
            [],
            [:a, :b],
            {:weird},
            {1, 2, 3, 4},
            self(),
            make_ref(),
            fn -> :x end,
            %{random: :map},
            %HostileInspect{x: 1}
          ] do
        assert RunFailure.classify(garbage) == :agent_unknown
      end
    end

    test "invalid UTF-8 cannot be sniffed" do
      assert RunFailure.classify(<<0xFF, 0xFE, 0xFD>>) == :agent_unknown
    end

    test "a hostile exception whose message/1 raises still classifies" do
      # Elixir's Exception.message/1 already shields plain raises — the
      # classifier must survive whatever string comes back.
      assert RunFailure.classify(RaisingMessageError.exception(message: "x")) ==
               :agent_unknown
    end

    test "a thrower and an exiter hit the catch backstop" do
      assert RunFailure.classify(ThrowingMessageError.exception(message: "x")) ==
               :agent_unknown

      assert RunFailure.classify(ExitingMessageError.exception(message: "x")) ==
               :agent_unknown
    end
  end

  describe "derived sets" do
    test "exact retryable membership" do
      retryable = Enum.filter(RunFailure.all_kinds(), &RunFailure.retryable?/1)

      assert Enum.sort(retryable) ==
               Enum.sort([
                 :stalled_wall_clock,
                 :stalled_no_output,
                 :agent_semantic_inactivity,
                 :agent_session_poisoned
               ])
    end

    test "exact resume-unsafe membership" do
      unsafe = Enum.filter(RunFailure.all_kinds(), &RunFailure.resume_unsafe?/1)

      assert Enum.sort(unsafe) ==
               Enum.sort([
                 :iteration_limit,
                 :agent_fallback_message,
                 :api_invalid_request,
                 :agent_semantic_inactivity,
                 :agent_session_poisoned
               ])
    end

    test "the retry ∧ resume-unsafe overlap is exactly the retry-fresh pair" do
      overlap =
        Enum.filter(
          RunFailure.all_kinds(),
          &(RunFailure.retryable?(&1) and RunFailure.resume_unsafe?(&1))
        )

      assert Enum.sort(overlap) ==
               Enum.sort([:agent_semantic_inactivity, :agent_session_poisoned])
    end

    test "failure?/1 is false only for user_cancelled" do
      refute RunFailure.failure?(:user_cancelled)

      for kind <- RunFailure.all_kinds() -- [:user_cancelled] do
        assert RunFailure.failure?(kind)
      end
    end

    test "provenance follows the name prefix" do
      for kind <- RunFailure.all_kinds() do
        expected =
          if String.starts_with?(Atom.to_string(kind), "agent_"), do: :agent, else: :platform

        assert RunFailure.provenance(kind) == expected
      end
    end

    test "the enum is 22 unique kinds" do
      kinds = RunFailure.all_kinds()
      assert Enum.count(kinds) == 22
      assert kinds == Enum.uniq(kinds)
    end
  end

  describe "decode/1" do
    test "round-trips every kind" do
      for kind <- RunFailure.all_kinds() do
        assert RunFailure.decode(Atom.to_string(kind)) == {:ok, kind}
      end
    end

    test "rejects anything outside the whitelist" do
      assert RunFailure.decode("bogus") == :error
      assert RunFailure.decode("agent_") == :error
      assert RunFailure.decode("") == :error
    end
  end

  describe "format_reason/2" do
    test "bounded on huge raw terms" do
      rendered = RunFailure.format_reason(:agent_unknown, String.duplicate("x", 50_000))

      assert String.starts_with?(rendered, "agent_unknown: ")
      assert String.length(rendered) < 300
    end

    test "a malformed struct still renders bounded output, never raises" do
      # Kernel.inspect defaults to safe rendering (#Inspect.Error<…> instead
      # of raising), so the rescue backstop stays belt-and-suspenders; this
      # row pins that a broken-Inspect shape yields a bounded string.
      rendered = RunFailure.format_reason(:agent_unknown, %{__struct__: Range})

      assert String.starts_with?(rendered, "agent_unknown: ")
      assert String.length(rendered) < 300
    end
  end

  describe "error_details/2" do
    test "policy bits merge over extra after stripping reserved keys in both forms" do
      extra = %{
        :retry => true,
        "retry" => true,
        :failure_kind => :bogus,
        "failure_kind" => "bogus",
        :reason => :smuggled,
        "reason" => "smuggled",
        :other => 1
      }

      details = RunFailure.error_details(:api_invalid_request, extra)

      assert details == %{other: 1, failure_kind: :api_invalid_request, retry: false}
    end

    test "retry rides the derived set" do
      assert RunFailure.error_details(:agent_session_poisoned).retry
      refute RunFailure.error_details(:agent_fallback_message).retry
    end
  end
end
