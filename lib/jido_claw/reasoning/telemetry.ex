defmodule JidoClaw.Reasoning.Telemetry do
  @moduledoc """
  Telemetry-and-persistence wrapper for reasoning strategy calls.

  `with_outcome/4` runs `fun` between two `JidoClaw.Trace.emit/3` calls,
  captures the result + duration, and persists a `reasoning_outcomes` row
  asynchronously via `Task.Supervisor`. In tests the write is synchronous
  (see `:reasoning_telemetry_sync` in `config/test.exs`) so assertions can
  inspect DB state immediately.

  The fun must return `{:ok, map()}` or `{:error, term()}`; the wrapper does
  not change the return value.

  ## Canonical reasoning event path

  v0.7+ emits `[:jido_claw, :reasoning, :event]` (the canonical 3-segment
  shape that the Trace surface consumes) via `JidoClaw.Trace.emit/3`. The
  legacy 4-segment `[:jido_claw, :reasoning, :strategy, :start|:stop]`
  events are no longer emitted. External consumers attached to the legacy
  names must migrate to `[:jido_claw, :reasoning, :event]` and filter on
  `metadata.event in [:start, :stop, :error]` and `metadata.phase ==
  :strategy`.
  """

  require Logger

  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Reasoning.{Classifier, Resources.Outcome, TaskProfile}

  @type fun_result(success) :: {:ok, success} | {:error, term()}

  @type opts :: [
          execution_kind: atom(),
          workspace_id: String.t() | nil,
          workspace_uuid: Ecto.UUID.t() | nil,
          session_uuid: Ecto.UUID.t() | nil,
          project_dir: String.t() | nil,
          agent_id: String.t() | nil,
          request_id: String.t() | nil,
          forge_session_key: String.t() | nil,
          profile: TaskProfile.t() | nil,
          base_strategy: String.t() | nil,
          pipeline_name: String.t() | nil,
          pipeline_stage: String.t() | nil,
          certificate_verdict: String.t() | nil,
          certificate_confidence: float() | nil,
          metadata: map()
        ]

  @doc """
  Run `fun` with reasoning-outcome telemetry + persistence.

  Emits via `JidoClaw.Trace.emit(:reasoning, ...)`:

    * `event: :start, phase: :strategy, name: <strategy>` with metadata
      `%{execution_kind, task_type, prompt_length, request_id, agent_id}`.
    * Exactly one terminal event per outcome:
        - `event: :stop` with `%{duration_ms}` on `{:ok, _}`
        - `event: :error` with `%{duration_ms, status, reason}` on
          `{:error, _}` / `{:error, :timeout}`

  The terminal-event split mirrors the canonical `start/stop/error`
  lifecycle that `JidoClaw.Trace.Collector.event_status/3` maps:
  `:start → :running`, `:stop → :completed`, `:error → :failed`.

  Persists a `reasoning_outcomes` row asynchronously (or synchronously when
  `:reasoning_telemetry_sync` is true). Emits `jido_claw.reasoning.outcome_recorded`
  on successful write. Write failures are debug-logged; they never disrupt
  the caller.
  """
  @spec with_outcome(String.t(), String.t(), opts(), (-> fun_result(success))) ::
          fun_result(success)
        when success: map()
  def with_outcome(strategy_name, prompt, opts, fun)
      when is_binary(strategy_name) and is_binary(prompt) and is_list(opts) and
             is_function(fun, 0) do
    execution_kind = Keyword.fetch!(opts, :execution_kind)
    caller_supplied_profile? = Keyword.has_key?(opts, :profile)
    profile = Keyword.get(opts, :profile) || Classifier.profile(prompt)

    unless caller_supplied_profile? do
      emit_classified_signal(strategy_name, profile)
    end

    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time()
    request_id = Keyword.get(opts, :request_id)
    agent_id = Keyword.get(opts, :agent_id)

    :ok =
      JidoClaw.Trace.emit(
        :reasoning,
        %{
          event: :start,
          phase: :strategy,
          name: strategy_name,
          strategy: strategy_name,
          execution_kind: execution_kind,
          task_type: profile.task_type,
          prompt_length: profile.prompt_length,
          request_id: request_id,
          agent_id: agent_id
        },
        %{system_time: System.system_time()}
      )

    {result, status, terminal_reason} =
      try do
        case fun.() do
          {:ok, _} = ok -> {ok, :ok, nil}
          {:error, :timeout} = err -> {err, :timeout, :timeout}
          {:error, reason} = err -> {err, :error, reason}
        end
      rescue
        e ->
          Logger.debug(
            "[Reasoning.Telemetry] strategy #{strategy_name} raised: #{Exception.message(e)}"
          )

          {{:error, e}, :error, e}
      catch
        :exit, reason ->
          Logger.debug(
            "[Reasoning.Telemetry] strategy #{strategy_name} exited: #{inspect(reason)}"
          )

          {{:error, reason}, :error, reason}
      end

    completed_at = DateTime.utc_now()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_mono, :native, :millisecond)

    emit_terminal(
      strategy_name,
      profile,
      execution_kind,
      status,
      duration_ms,
      request_id,
      agent_id,
      terminal_reason
    )

    persist(strategy_name, profile, result, %{
      execution_kind: execution_kind,
      status: status,
      duration_ms: duration_ms,
      started_at: started_at,
      completed_at: completed_at,
      opts: opts
    })

    result
  end

  # Exactly one terminal event per outcome — `:stop` on success,
  # `:error` on failure/timeout. Mirrors the canonical Trace lifecycle
  # so `event_status/3` maps cleanly without ambiguity.
  defp emit_terminal(
         strategy_name,
         profile,
         execution_kind,
         :ok,
         duration_ms,
         request_id,
         agent_id,
         _reason
       ) do
    :ok =
      JidoClaw.Trace.emit(
        :reasoning,
        %{
          event: :stop,
          phase: :strategy,
          name: strategy_name,
          strategy: strategy_name,
          execution_kind: execution_kind,
          task_type: profile.task_type,
          status: :ok,
          request_id: request_id,
          agent_id: agent_id
        },
        %{duration_ms: duration_ms}
      )
  end

  defp emit_terminal(
         strategy_name,
         profile,
         execution_kind,
         status,
         duration_ms,
         request_id,
         agent_id,
         reason
       )
       when status in [:error, :timeout] do
    :ok =
      JidoClaw.Trace.emit(
        :reasoning,
        %{
          event: :error,
          phase: :strategy,
          name: strategy_name,
          strategy: strategy_name,
          execution_kind: execution_kind,
          task_type: profile.task_type,
          status: status,
          reason: inspect(reason),
          request_id: request_id,
          agent_id: agent_id
        },
        %{duration_ms: duration_ms}
      )
  end

  # ---------------------------------------------------------------------------
  # Private — classification signal
  # ---------------------------------------------------------------------------

  # Emit jido_claw.reasoning.classified whenever with_outcome/4 classifies
  # internally (i.e., the caller did not pass opts[:profile]). Callers that
  # already classified should emit their own signal and pass :profile to avoid
  # double emission.
  defp emit_classified_signal(executed_strategy, profile) do
    {:ok, recommended_strategy, confidence} = Classifier.recommend(profile)

    JidoClaw.SignalBus.emit("jido_claw.reasoning.classified", %{
      task_type: profile.task_type,
      complexity: profile.complexity,
      recommended_strategy: recommended_strategy,
      confidence: confidence,
      executed_strategy: executed_strategy
    })
  rescue
    e ->
      Logger.debug("[Reasoning.Telemetry] classified signal emit failed: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Private — persistence
  # ---------------------------------------------------------------------------

  # `info` keys: :execution_kind, :status, :duration_ms, :started_at,
  # :completed_at, :opts. Bundled to keep arity within credo limits.
  defp persist(strategy, profile, result, info) do
    %{
      execution_kind: execution_kind,
      status: status,
      duration_ms: duration_ms,
      started_at: started_at,
      completed_at: completed_at,
      opts: opts
    } = info

    {tokens_in, tokens_out} = extract_tokens(result)
    {extracted_verdict, extracted_confidence} = extract_certificate_fields(result)
    caller_metadata = Keyword.get(opts, :metadata, %{})

    attrs = %{
      strategy: strategy,
      execution_kind: execution_kind,
      base_strategy: Keyword.get(opts, :base_strategy),
      pipeline_name: Keyword.get(opts, :pipeline_name),
      pipeline_stage: Keyword.get(opts, :pipeline_stage),
      task_type: profile.task_type,
      complexity: profile.complexity,
      domain: profile.domain,
      target: profile.target,
      prompt_length: profile.prompt_length,
      status: status,
      duration_ms: duration_ms,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      certificate_verdict: Keyword.get(opts, :certificate_verdict, extracted_verdict),
      certificate_confidence: Keyword.get(opts, :certificate_confidence, extracted_confidence),
      workspace_uuid: Keyword.get(opts, :workspace_uuid),
      session_uuid: Keyword.get(opts, :session_uuid),
      project_dir: Keyword.get(opts, :project_dir),
      forge_session_key: Keyword.get(opts, :forge_session_key),
      # Caller-supplied metadata wins on key collision.
      metadata: Map.merge(%{}, caller_metadata),
      started_at: started_at,
      completed_at: completed_at
    }

    if Application.get_env(:jido_claw, :reasoning_telemetry_sync, false) do
      write_outcome(attrs)
    else
      Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> write_outcome(attrs) end)
    end

    :ok
  end

  defp write_outcome(attrs) do
    case Outcome.record(attrs) do
      {:ok, _record} ->
        JidoClaw.SignalBus.emit("jido_claw.reasoning.outcome_recorded", %{
          strategy: attrs.strategy,
          execution_kind: attrs.execution_kind,
          task_type: attrs.task_type,
          status: attrs.status
        })

        :ok

      {:error, reason} ->
        Logger.debug("[Reasoning.Telemetry] outcome write failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.debug("[Reasoning.Telemetry] outcome write raised: #{Exception.message(e)}")
      :error
  end

  defp extract_tokens({:ok, %{usage: usage}}) when is_map(usage), do: tokens_from_usage(usage)
  defp extract_tokens({:error, %{usage: usage}}) when is_map(usage), do: tokens_from_usage(usage)
  defp extract_tokens(_), do: {nil, nil}

  # jido_ai's extract_usage populates :input_tokens / :output_tokens (see
  # deps/jido_ai/lib/jido_ai/actions/helpers.ex). Legacy providers may still
  # emit :prompt_tokens / :completion_tokens, so try both.
  defp tokens_from_usage(usage) do
    {
      MapKeys.coalesce_field(usage, :input_tokens) ||
        MapKeys.coalesce_field(usage, :prompt_tokens),
      MapKeys.coalesce_field(usage, :output_tokens) ||
        MapKeys.coalesce_field(usage, :completion_tokens)
    }
  end

  defp extract_certificate_fields({:ok, map}) when is_map(map) do
    {
      Map.get(map, :certificate_verdict),
      Map.get(map, :certificate_confidence)
    }
  end

  defp extract_certificate_fields(_), do: {nil, nil}
end
