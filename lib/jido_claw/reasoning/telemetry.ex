defmodule JidoClaw.Reasoning.Telemetry do
  @moduledoc """
  Telemetry-and-persistence wrapper for reasoning strategy calls.

  `with_outcome/4` runs `fun` between two `:telemetry.execute/3` calls,
  captures the result + duration, and persists a `reasoning_outcomes` row
  asynchronously via `Task.Supervisor`. In tests the write is synchronous
  (see `:reasoning_telemetry_sync` in `config/test.exs`) so assertions can
  inspect DB state immediately.

  The fun must return `{:ok, map()}` or `{:error, term()}`; the wrapper does
  not change the return value.
  """

  require Logger

  alias JidoClaw.Reasoning.{Classifier, Resources.Outcome, TaskProfile}

  @type fun_result :: {:ok, map()} | {:error, term()}

  @type opts :: [
          execution_kind: atom(),
          workspace_id: String.t() | nil,
          project_dir: String.t() | nil,
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

  Emits:
    * `[:jido_claw, :reasoning, :strategy, :start]` with `%{system_time: _}`
      and metadata `%{strategy, execution_kind, task_type, prompt_length}`.
    * `[:jido_claw, :reasoning, :strategy, :stop]` with `%{duration_ms}` and
      metadata `%{strategy, execution_kind, task_type, status}`.

  Persists a `reasoning_outcomes` row asynchronously (or synchronously when
  `:reasoning_telemetry_sync` is true). Emits `jido_claw.reasoning.outcome_recorded`
  on successful write. Write failures are debug-logged; they never disrupt
  the caller.
  """
  @spec with_outcome(String.t(), String.t(), opts(), (-> fun_result())) :: fun_result()
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

    :telemetry.execute(
      [:jido_claw, :reasoning, :strategy, :start],
      %{system_time: System.system_time()},
      %{
        strategy: strategy_name,
        execution_kind: execution_kind,
        task_type: profile.task_type,
        prompt_length: profile.prompt_length
      }
    )

    {result, status} =
      try do
        case fun.() do
          {:ok, _} = ok -> {ok, :ok}
          {:error, :timeout} = err -> {err, :timeout}
          {:error, _} = err -> {err, :error}
        end
      rescue
        e ->
          Logger.debug(
            "[Reasoning.Telemetry] strategy #{strategy_name} raised: #{Exception.message(e)}"
          )

          {{:error, e}, :error}
      catch
        :exit, reason ->
          Logger.debug(
            "[Reasoning.Telemetry] strategy #{strategy_name} exited: #{inspect(reason)}"
          )

          {{:error, reason}, :error}
      end

    completed_at = DateTime.utc_now()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_mono, :native, :millisecond)

    :telemetry.execute(
      [:jido_claw, :reasoning, :strategy, :stop],
      %{duration_ms: duration_ms},
      %{
        strategy: strategy_name,
        execution_kind: execution_kind,
        task_type: profile.task_type,
        status: status
      }
    )

    persist(
      strategy_name,
      profile,
      execution_kind,
      status,
      duration_ms,
      started_at,
      completed_at,
      result,
      opts
    )

    result
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

  defp persist(
         strategy,
         profile,
         execution_kind,
         status,
         duration_ms,
         started_at,
         completed_at,
         result,
         opts
       ) do
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
      workspace_id: Keyword.get(opts, :workspace_id),
      project_dir: Keyword.get(opts, :project_dir),
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
      Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") ||
        Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens"),
      Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") ||
        Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens")
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
