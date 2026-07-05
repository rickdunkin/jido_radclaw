defmodule JidoClaw.Error.Normalize do
  @moduledoc """
  Per-domain entrypoints that convert any error (foreign exception, atom,
  tagged tuple, binary, or first-party JidoClaw error) into a guaranteed
  `%JidoClaw.Error.*{}` exception.

  This module is the **conversion boundary** for the JidoClaw error contract.
  `JidoClaw.Error.to_class/1` aggregates a list of *already-normalized*
  errors into a class container; it is NOT an enforcement point. Code that
  needs a typed JidoClaw error must call one of the `*_error/2` entrypoints
  here.

  ## Foreign-tree dispatch

  Inside every entrypoint, foreign exceptions dispatch on the structural
  class (not blanket-validation):

  * `Ash.Error.Invalid`     → `ValidationError`
  * `Ash.Error.Forbidden`   → `ExecutionError` (authz)
  * `Ash.Error.Framework`   → `ExecutionError` (framework bug)
  * `Ash.Error.Unknown`     → `Internal.UnknownError`
  * `Jido.Error.Validation*`/`Jido.Error.Invalid` → `ValidationError`
  * `Jido.Error.Execution*`/`Jido.Error.TimeoutError`/`Jido.Error.RoutingError`/`Jido.Error.CompensationError` → `ExecutionError`
  * `Jido.Error.Internal*`  → `Internal.UnknownError`
  * `Jido.AI.Error.Validation.*` → `ValidationError`
  * `Jido.AI.Error.API.*`        → `ExecutionError`
  * `Jido.AI.Error.Unknown`      → `Internal.UnknownError`
  * Any other exception (`RuntimeError`, `File.Error`, etc.) → `ExecutionError`
  """

  alias JidoClaw.Error
  alias JidoClaw.Error.Normalize.Common
  alias JidoClaw.Error.Normalize.Context

  @type context :: Context.context()

  # ---------------------------------------------------------------------------
  # tool_error/2 — typed-exception boundary for tool-shaped reasons. (The live
  # Tools.Action pipeline normalizes via Tools.Error.normalize_result/1; this
  # is for callers that need a %JidoClaw.Error.*{} struct.)
  # ---------------------------------------------------------------------------

  @spec tool_error(term(), context()) :: Exception.t()
  def tool_error(reason, context \\ %{})

  def tool_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Tool execution failed.", :tool, context)

  def tool_error({:timeout, timeout}, context),
    do: Common.timeout_error(:tool, timeout, context)

  def tool_error(:timeout, context),
    do: Common.timeout_error(:tool, Context.detail(context, :timeout), context)

  def tool_error({:not_found, kind, value}, context) when is_atom(kind),
    do: Error.not_found(kind, value, details: Context.details(context, %{operation: :tool}))

  def tool_error(reason, context) when is_binary(reason) do
    case Context.detail(context, :field) do
      nil -> Common.execution("Tool execution failed.", :tool, reason, context)
      field -> Common.validation(reason, field, reason, context)
    end
  end

  def tool_error(reason, context),
    do: Common.execution("Tool execution failed.", :tool, reason, context)

  # ---------------------------------------------------------------------------
  # forge_error/2 — sandbox provision/bootstrap/exec failures.
  # ---------------------------------------------------------------------------

  @spec forge_error(term(), context()) :: Exception.t()
  def forge_error(reason, context \\ %{})

  def forge_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Forge operation failed.", :forge, context)

  def forge_error({:timeout, timeout}, context),
    do: Common.timeout_error(:forge, timeout, context)

  def forge_error(reason, context),
    do: Common.execution("Forge operation failed.", :forge, reason, context)

  # ---------------------------------------------------------------------------
  # conversation_error/2 — Session.Worker / Conversations.* failures.
  # ---------------------------------------------------------------------------

  @spec conversation_error(term(), context()) :: Exception.t()
  def conversation_error(reason, context \\ %{})

  def conversation_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Conversation operation failed.", :conversation, context)

  def conversation_error(:session_uuid_unset = reason, context) do
    Error.execution_error("Session UUID is not yet set on the worker.",
      phase: :conversation,
      details:
        Context.details(context, %{operation: :conversation, cause: reason, reason: reason})
    )
  end

  def conversation_error({:not_found, kind, value}, context) when is_atom(kind),
    do:
      Error.not_found(kind, value, details: Context.details(context, %{operation: :conversation}))

  def conversation_error({:timeout, timeout}, context),
    do: Common.timeout_error(:conversation, timeout, context)

  def conversation_error(reason, context),
    do: Common.execution("Conversation operation failed.", :conversation, reason, context)

  # ---------------------------------------------------------------------------
  # reasoning_error/2 — Strategy / Pipeline / Classifier failures.
  # ---------------------------------------------------------------------------

  @spec reasoning_error(term(), context()) :: Exception.t()
  def reasoning_error(reason, context \\ %{})

  def reasoning_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Reasoning operation failed.", :reasoning, context)

  def reasoning_error({:timeout, timeout}, context),
    do: Common.timeout_error(:reasoning, timeout, context)

  def reasoning_error(reason, context) when is_binary(reason) do
    case Context.detail(context, :field) do
      nil -> Common.execution("Reasoning operation failed.", :reasoning, reason, context)
      field -> Common.validation(reason, field, reason, context)
    end
  end

  def reasoning_error(reason, context),
    do: Common.execution("Reasoning operation failed.", :reasoning, reason, context)

  # ---------------------------------------------------------------------------
  # compaction_error/2 — Reasoning.Compactor (storage, summarizer, transformer).
  # ---------------------------------------------------------------------------

  @spec compaction_error(term(), context()) :: Exception.t()
  def compaction_error(reason, context \\ %{})

  def compaction_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Compaction operation failed.", :compaction, context)

  def compaction_error({:timeout, timeout}, context),
    do: Common.timeout_error(:compaction, timeout, context)

  def compaction_error(reason, context) when is_binary(reason) do
    case Context.detail(context, :field) do
      nil -> Common.execution("Compaction operation failed.", :compaction, reason, context)
      field -> Common.validation(reason, field, reason, context)
    end
  end

  def compaction_error(reason, context),
    do: Common.execution("Compaction operation failed.", :compaction, reason, context)

  # ---------------------------------------------------------------------------
  # session_error/2 — Session.Supervisor / Session.Worker process failures.
  # ---------------------------------------------------------------------------

  @spec session_error(term(), context()) :: Exception.t()
  def session_error(reason, context \\ %{})

  def session_error(%_{} = error, context) when is_exception(error),
    do: from_exception(error, "Session operation failed.", :session, context)

  def session_error({:timeout, timeout}, context),
    do: Common.timeout_error(:session, timeout, context)

  def session_error({:not_found, kind, value}, context) when is_atom(kind),
    do: Error.not_found(kind, value, details: Context.details(context, %{operation: :session}))

  def session_error(:not_found, context),
    do:
      Error.not_found(:session, Context.detail(context, :session_id),
        details: Context.details(context, %{operation: :session})
      )

  def session_error(reason, context),
    do: Common.execution("Session operation failed.", :session, reason, context)

  # ===========================================================================
  # Foreign-exception dispatch (shared across every entrypoint).
  # ===========================================================================

  defp from_exception(error, default_message, phase, context) do
    cond do
      Context.jido_claw_error?(error) -> error
      ash_class?(error) -> from_ash_class(error, phase, context)
      ash_leaf?(error) -> from_ash_leaf(error, phase, context)
      jido_error?(error) -> from_jido(error, phase, context)
      jido_ai_error?(error) -> from_jido_ai(error, phase, context)
      true -> Common.passthrough_or_execution(error, default_message, phase, context)
    end
  end

  # ---- Ash dispatch ----

  defp ash_class?(%Ash.Error.Invalid{}), do: true
  defp ash_class?(%Ash.Error.Forbidden{}), do: true
  defp ash_class?(%Ash.Error.Framework{}), do: true
  defp ash_class?(%Ash.Error.Unknown{}), do: true
  defp ash_class?(_), do: false

  defp ash_leaf?(%struct{} = error) do
    is_exception(error) and function_exported?(struct, :splode_error?, 0) and
      try do
        struct.splode_error?() and not struct.error_class?() and
          match?(["Ash" | _], Module.split(struct))

        # Structural classifier probing foreign modules: a stub `error_class?/0`
        # or unexpected callback shape must answer "not an Ash leaf", not crash.
      rescue
        # reach:disable-next-line bare_rescue
        _ -> false
      end
  end

  defp ash_leaf?(_), do: false

  defp from_ash_class(%Ash.Error.Invalid{} = error, phase, context) do
    Error.validation_error(Exception.message(error),
      field: Context.detail(context, :field, :input),
      value: Context.detail(context, :value),
      details:
        Context.details(context, %{operation: phase, source: :ash, class: :invalid, cause: error})
    )
  end

  defp from_ash_class(%Ash.Error.Forbidden{} = error, phase, context) do
    Error.execution_error("Forbidden: " <> Exception.message(error),
      phase: phase,
      details:
        Context.details(context, %{
          operation: phase,
          source: :ash,
          class: :forbidden,
          cause: error
        })
    )
  end

  defp from_ash_class(%Ash.Error.Framework{} = error, phase, context) do
    Error.execution_error("Ash framework error: " <> Exception.message(error),
      phase: phase,
      details:
        Context.details(context, %{
          operation: phase,
          source: :ash,
          class: :framework,
          cause: error
        })
    )
  end

  defp from_ash_class(%Ash.Error.Unknown{} = error, _phase, context) do
    Error.Internal.UnknownError.exception(
      message: Exception.message(error),
      error: error,
      details: Context.details(context, %{source: :ash, class: :unknown})
    )
  end

  defp from_ash_leaf(%_{class: :invalid} = error, phase, context) do
    Error.validation_error(Exception.message(error),
      field: Map.get(error, :field, Context.detail(context, :field, :input)),
      value: Map.get(error, :value, Context.detail(context, :value)),
      details: Context.details(context, %{operation: phase, source: :ash, cause: error})
    )
  end

  defp from_ash_leaf(%_{class: :forbidden} = error, phase, context) do
    Error.execution_error("Forbidden: " <> Exception.message(error),
      phase: phase,
      details: Context.details(context, %{operation: phase, source: :ash, cause: error})
    )
  end

  defp from_ash_leaf(%_{class: :framework} = error, phase, context) do
    Error.execution_error("Ash framework error: " <> Exception.message(error),
      phase: phase,
      details: Context.details(context, %{operation: phase, source: :ash, cause: error})
    )
  end

  defp from_ash_leaf(error, _phase, context) do
    Error.Internal.UnknownError.exception(
      message: Exception.message(error),
      error: error,
      details: Context.details(context, %{source: :ash})
    )
  end

  # ---- Jido dispatch ----

  defp jido_error?(%Jido.Error.ValidationError{}), do: true
  defp jido_error?(%Jido.Error.ExecutionError{}), do: true
  defp jido_error?(%Jido.Error.RoutingError{}), do: true
  defp jido_error?(%Jido.Error.TimeoutError{}), do: true
  defp jido_error?(%Jido.Error.CompensationError{}), do: true
  defp jido_error?(%Jido.Error.InternalError{}), do: true
  defp jido_error?(%Jido.Error.Invalid{}), do: true
  defp jido_error?(%Jido.Error.Execution{}), do: true
  defp jido_error?(%Jido.Error.Routing{}), do: true
  defp jido_error?(%Jido.Error.Timeout{}), do: true
  defp jido_error?(%Jido.Error.Internal{}), do: true
  defp jido_error?(%Jido.Error.Internal.UnknownError{}), do: true
  defp jido_error?(_), do: false

  defp from_jido(%mod{} = error, phase, context)
       when mod in [Jido.Error.ValidationError, Jido.Error.Invalid] do
    Error.validation_error(Exception.message(error),
      field: Map.get(error, :field) || Map.get(error, :kind) || Context.detail(context, :field),
      value: Map.get(error, :subject) || Context.detail(context, :value),
      details: Context.details(context, %{operation: phase, source: :jido, cause: error})
    )
  end

  defp from_jido(%Jido.Error.TimeoutError{} = error, phase, context) do
    Error.execution_error(Exception.message(error),
      phase: :timeout,
      details:
        Context.details(context, %{
          operation: phase,
          source: :jido,
          reason: :timeout,
          timeout: Map.get(error, :timeout),
          cause: error
        })
    )
  end

  defp from_jido(%mod{} = error, phase, context)
       when mod in [
              Jido.Error.InternalError,
              Jido.Error.Internal,
              Jido.Error.Internal.UnknownError
            ] do
    Error.Internal.UnknownError.exception(
      message: Exception.message(error),
      error: error,
      details: Context.details(context, %{operation: phase, source: :jido})
    )
  end

  defp from_jido(error, phase, context) do
    Error.execution_error(Exception.message(error),
      phase: phase,
      details: Context.details(context, %{operation: phase, source: :jido, cause: error})
    )
  end

  # ---- Jido.AI dispatch ----

  defp jido_ai_error?(%Jido.AI.Error.API.RateLimit{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.API.Auth{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.API.Request{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.Validation.Invalid{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.Unknown{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.API{}), do: true
  defp jido_ai_error?(%Jido.AI.Error.Validation{}), do: true
  defp jido_ai_error?(_), do: false

  defp from_jido_ai(%Jido.AI.Error.Validation.Invalid{} = error, phase, context) do
    Error.validation_error(Exception.message(error),
      field: Map.get(error, :field, Context.detail(context, :field)),
      value: Context.detail(context, :value),
      details: Context.details(context, %{operation: phase, source: :jido_ai, cause: error})
    )
  end

  defp from_jido_ai(%Jido.AI.Error.Validation{} = error, phase, context) do
    Error.validation_error(Exception.message(error),
      field: Context.detail(context, :field),
      value: Context.detail(context, :value),
      details: Context.details(context, %{operation: phase, source: :jido_ai, cause: error})
    )
  end

  defp from_jido_ai(%Jido.AI.Error.Unknown{} = error, phase, context) do
    Error.Internal.UnknownError.exception(
      message: Exception.message(error),
      error: error,
      details: Context.details(context, %{operation: phase, source: :jido_ai})
    )
  end

  defp from_jido_ai(error, phase, context) do
    Error.execution_error(Exception.message(error),
      phase: phase,
      details: Context.details(context, %{operation: phase, source: :jido_ai, cause: error})
    )
  end
end
