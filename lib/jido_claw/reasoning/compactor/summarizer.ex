defmodule JidoClaw.Reasoning.Compactor.Summarizer do
  @moduledoc """
  Bounded LLM-backed summarizer for `JidoClaw.Reasoning.Compactor`.

  Wraps the actual summarizer call in a supervised task with a hard timeout.
  Uses `Task.Supervisor.async_nolink/3` against `JidoClaw.TaskSupervisor` so
  a runaway exit never propagates to the calling agent process. The task
  body itself is wrapped in `try/rescue/catch` so it returns `{:error, _}`
  rather than exiting.

  ## Backends

  The actual LLM call is dispatched through a backend module — the default
  is `JidoClaw.Reasoning.Compactor.Summarizer.LLMBackend` (production); tests
  override it via:

      Application.put_env(:jido_claw, :compaction_summarizer, MyFakeBackend)

  A backend implements a single callback, `summarize/2`, that takes a
  pre-built prompt string and an options keyword list and returns
  `{:ok, summary} | {:error, reason}`.

  ## Errors

  All failure modes return a `%JidoClaw.Error.ExecutionError{}` with a
  specific `phase`:

    * `:summarizer_timeout` — the task did not produce a result before
      `summarizer_timeout_ms`.
    * `:summarizer_exception` — the task body raised; the original
      exception is preserved in `details`.
    * `:summarizer_exit` — the task exited (linked process died, etc.);
      the exit reason is preserved in `details`.
    * `:summarizer_backend` — the backend returned `{:error, reason}`.

  ## Retries

  Transient failures (`:summarizer_timeout`, `:summarizer_exit`,
  `:summarizer_backend`) are retried up to `config.summarizer_max_retries`
  additional times, sleeping `config.summarizer_retry_backoff_ms` between
  attempts and emitting a `:retry` Trace breadcrumb before each. A
  `:summarizer_exception` is treated as a deterministic bug in the backend
  and is **never** retried. Worst-case added latency is
  `summarizer_max_retries * (summarizer_timeout_ms + summarizer_retry_backoff_ms)`.
  """

  alias JidoClaw.Error
  alias JidoClaw.Error.ExecutionError
  alias JidoClaw.Reasoning.Compactor.Config

  @type prompt :: String.t()
  @type backend_opts :: keyword()

  @doc """
  Behaviour for summarizer backends.

  Backends MUST return within their own internal timeout — the Summarizer
  wraps the call in a Task with `summarizer_timeout_ms`, but a backend that
  blocks longer than that will simply be killed via `Task.shutdown/2`.
  """
  @callback summarize(prompt(), backend_opts()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Run the summarizer.

    * `prompt` — full prompt string (see
      `JidoClaw.Reasoning.Compactor.Prompt.build/3`).
    * `config` — the compaction `%Config{}` (`summarizer_timeout_ms`,
      `summarizer_model`, `max_summary_chars`).
    * `opts` — keyword options forwarded to the backend (e.g. `request_id`,
      `agent_id`, `tenant_id` for telemetry).

  Returns `{:ok, summary}` on success or `{:error, %ExecutionError{}}`.
  """
  @spec summarize(prompt(), Config.t(), keyword()) ::
          {:ok, String.t()} | {:error, Exception.t()}
  def summarize(prompt, %Config{} = config, opts \\ [])
      when is_binary(prompt) and is_list(opts) do
    backend_opts =
      opts
      |> Keyword.put_new(:model, config.summarizer_model)
      |> Keyword.put_new(:max_chars, config.max_summary_chars)

    attempt_summarize(prompt, config, backend_opts, 0)
  end

  # Run one attempt; on a transient failure, sleep the configured backoff
  # and recurse until `summarizer_max_retries` additional attempts are
  # exhausted. `:summarizer_exception` is non-transient and short-circuits.
  defp attempt_summarize(prompt, %Config{} = config, backend_opts, attempt) do
    case run_attempt(prompt, config, backend_opts) do
      {:ok, _summary} = ok ->
        ok

      {:error, error} ->
        if retryable?(error) and attempt < config.summarizer_max_retries do
          emit_retry(error, attempt + 1, config, backend_opts)
          Process.sleep(config.summarizer_retry_backoff_ms)
          attempt_summarize(prompt, config, backend_opts, attempt + 1)
        else
          {:error, error}
        end
    end
  end

  defp run_attempt(prompt, %Config{} = config, backend_opts) do
    backend = resolve_backend()
    timeout_ms = config.summarizer_timeout_ms

    task =
      Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, fn ->
        run_backend(backend, prompt, backend_opts)
      end)

    yield_result = Task.yield(task, timeout_ms)
    finalize(yield_result, task, config, timeout_ms)
  end

  defp retryable?(%ExecutionError{phase: phase})
       when phase in [:summarizer_timeout, :summarizer_exit, :summarizer_backend],
       do: true

  defp retryable?(_), do: false

  defp emit_retry(error, attempt, %Config{} = config, backend_opts) do
    JidoClaw.Trace.emit(
      :compaction,
      %{
        event: :retry,
        phase: :compaction,
        name: "summary",
        compaction: "summary",
        status: :retry,
        reason: error_phase(error),
        retry_attempt: attempt,
        max_retries: config.summarizer_max_retries,
        request_id: Keyword.get(backend_opts, :request_id),
        agent_id: Keyword.get(backend_opts, :agent_id),
        tenant_id: Keyword.get(backend_opts, :tenant_id)
      },
      %{system_time: System.system_time()}
    )

    :ok
  end

  # Every transient/terminal failure from `run_attempt` is an `%ExecutionError{}`.
  defp error_phase(%ExecutionError{phase: phase}), do: phase

  defp run_backend(backend, prompt, backend_opts) do
    {:ok, backend.summarize(prompt, backend_opts)}
    # supervised task body converts any backend fault to a tagged tuple so
    # the parent finalize/4 can produce a structured ExecutionError
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:exception, e, __STACKTRACE__}
  catch
    :exit, reason -> {:exit, reason}
    :throw, value -> {:throw, value}
  end

  defp finalize(nil, task, %Config{} = config, timeout_ms) do
    case Task.shutdown(task, :brutal_kill) do
      nil -> {:error, timeout_error(timeout_ms)}
      {:exit, reason} -> {:error, exit_error(reason)}
      result -> handle_task_result(result, config.max_summary_chars)
    end
  end

  defp finalize(result, _task, config, _timeout_ms) do
    handle_task_result(result, config.max_summary_chars)
  end

  defp handle_task_result({:ok, {:ok, {:ok, summary}}}, limit) when is_binary(summary) do
    {:ok, trim_to_max(summary, limit)}
  end

  defp handle_task_result({:ok, {:ok, {:error, reason}}}, _limit),
    do: {:error, backend_error(reason)}

  defp handle_task_result({:ok, {:exception, exception, stacktrace}}, _limit),
    do: {:error, exception_error(exception, stacktrace)}

  defp handle_task_result({:ok, {:exit, reason}}, _limit),
    do: {:error, exit_error(reason)}

  defp handle_task_result({:ok, {:throw, value}}, _limit),
    do: {:error, exit_error({:throw, value})}

  defp handle_task_result({:ok, other}, _limit) do
    {:error,
     Error.execution_error(
       "Compaction summarizer returned an unexpected value.",
       phase: :summarizer_backend,
       details: %{operation: :compaction, value: inspect(other)}
     )}
  end

  defp handle_task_result({:exit, reason}, _limit), do: {:error, exit_error(reason)}

  defp resolve_backend do
    Application.get_env(:jido_claw, :compaction_summarizer) ||
      JidoClaw.Reasoning.Compactor.Summarizer.LLMBackend
  end

  defp trim_to_max(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if byte_size(text) <= limit do
      text
    else
      <<head::binary-size(^limit), _rest::binary>> = text
      head
    end
  end

  defp timeout_error(timeout_ms) do
    Error.execution_error(
      "Compaction summarizer timed out after #{timeout_ms}ms.",
      phase: :summarizer_timeout,
      details: %{operation: :compaction, timeout: timeout_ms}
    )
  end

  defp exception_error(exception, stacktrace) do
    Error.execution_error(
      "Compaction summarizer raised: #{Exception.message(exception)}",
      phase: :summarizer_exception,
      details: %{
        operation: :compaction,
        exception: inspect(exception),
        stacktrace: Exception.format_stacktrace(stacktrace)
      }
    )
  end

  defp exit_error(reason) do
    Error.execution_error(
      "Compaction summarizer exited: #{inspect(reason)}",
      phase: :summarizer_exit,
      details: %{operation: :compaction, reason: inspect(reason)}
    )
  end

  defp backend_error(reason) do
    Error.execution_error(
      "Compaction summarizer backend returned an error: #{inspect(reason)}",
      phase: :summarizer_backend,
      details: %{operation: :compaction, reason: inspect(reason)}
    )
  end
end
