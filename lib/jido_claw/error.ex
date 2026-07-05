defmodule JidoClaw.Error do
  @moduledoc """
  Structured JidoClaw error contract.

  JidoClaw uses Splode-backed errors for validation, configuration, and
  execution failures so they can be raised, formatted, classified, and
  serialized consistently.

  ## Layers

  * **Contract** — three leaves (`ValidationError`, `ConfigError`,
    `ExecutionError`) plus a Splode-registered `Internal.UnknownError`
    fallback. Public constructors (`validation_error/2`, `not_found/3`, etc.)
    return Exception structs that callers wrap as `{:error, %X{}}`.
  * **Normalize** — `JidoClaw.Error.Normalize.<domain>_error/2` converts the
    heterogeneous shapes returned by subsystems (atoms, tagged tuples,
    strings, foreign exceptions) into a guaranteed `%JidoClaw.Error.*{}`.

  ## Foreign Splode tree policy

  The VM hosts several Splode trees today: `Ash.Error`, `Jido.Error`,
  `Jido.AI.Error`, and `Reactor.Error`. The policy is explicit and asymmetric.

  * **`Normalize.*_error/2` is the boundary, NOT `to_class/1`.** Splode's
    `to_class/1` is an aggregator, not a policy gate: fresh leaves often have
    `splode: nil`, and Splode may accept those as compatible with the current
    tree even when their owning tree is not in `merge_with`. Code that needs a
    guaranteed `%JidoClaw.Error.*{}` must call `Normalize.tool_error/2` (or
    its peer) explicitly. (The live `Tools.Action` pipeline normalizes tool
    results through `Tools.Error.normalize_result/1` instead — this boundary
    is for callers that need a typed exception struct.)
  * **`merge_with: [Ash.Error]`** — 15+ consumer sites pattern-match on
    `%Ash.Error.*{}`. Merging guarantees typed Ash class containers
    (`%Ash.Error.Invalid{errors: [...]}`) flatten cleanly through
    `to_class/1` rather than being re-wrapped. Behavior on raw Ash leaves is
    best-effort.
  * **`Jido.Error`, `Jido.AI.Error`, `Reactor.Error` are NOT in `merge_with`.**
    Code that bubbles up exceptions from those trees MUST route through
    `Normalize.*_error/2` to get a `%JidoClaw.Error.*{}`. Relying on
    implicit `to_class/1` behavior is wrong.

  Removing `Ash.Error` from `merge_with` later would silently change return
  types for class containers; treat it as effectively irreversible.
  """

  alias JidoClaw.Error.ConfigError
  alias JidoClaw.Error.ExecutionError
  alias JidoClaw.Error.ValidationError

  use Splode,
    error_classes: [
      invalid: JidoClaw.Error.Invalid,
      execution: JidoClaw.Error.Execution,
      config: JidoClaw.Error.Config,
      internal: JidoClaw.Error.Internal
    ],
    merge_with: [Ash.Error],
    filter_stacktraces: ["Splode."],
    unknown_error: JidoClaw.Error.Internal.UnknownError

  @doc """
  Builds a validation error with a consistent JidoClaw shape.
  """
  @spec validation_error(String.t(), keyword() | map()) :: Exception.t()
  def validation_error(message, details \\ %{}) do
    ValidationError.exception(put_details(details, message))
  end

  @doc """
  Builds a configuration error with a consistent JidoClaw shape.
  """
  @spec config_error(String.t(), keyword() | map()) :: Exception.t()
  def config_error(message, details \\ %{}) do
    ConfigError.exception(put_details(details, message))
  end

  @doc """
  Builds a runtime execution error with a consistent JidoClaw shape.
  """
  @spec execution_error(String.t(), keyword() | map()) :: Exception.t()
  def execution_error(message, details \\ %{}) do
    ExecutionError.exception(put_details(details, message))
  end

  @doc """
  Builds a "resource not found" validation error.

  The `kind` atom names what was looked up (e.g. `:agent`, `:session`,
  `:tool`); `identifier` is the value the caller used. The resulting
  `ValidationError` carries `field: kind, value: identifier`.
  """
  @spec not_found(atom(), term(), keyword() | map()) :: Exception.t()
  def not_found(kind, identifier, opts \\ %{}) when is_atom(kind) do
    label =
      kind
      |> Atom.to_string()
      |> String.capitalize()

    validation_error("#{label} #{format_identifier(identifier)} not found.",
      field: kind,
      value: identifier,
      details: merge_details(opts, %{reason: :not_found, kind: kind})
    )
  end

  defp format_identifier(id) when is_binary(id), do: "'#{id}'"
  defp format_identifier(id), do: inspect(id)

  @doc """
  Builds an agent-correctable invalid-argument error.

  Use this when the caller passed something the agent could realistically fix
  — a malformed cron string, an unrecognized path. For runtime failures (file
  read errors, etc.) use `execution_error/2` instead.
  """
  @spec invalid_argument(atom(), term(), keyword() | map()) :: Exception.t()
  def invalid_argument(field, value, opts \\ %{}) when is_atom(field) do
    message = get_detail(opts, :message) || "Invalid value for `#{field}`."

    validation_error(message,
      field: field,
      value: value,
      details: merge_details(opts, %{reason: :invalid_argument})
    )
  end

  @doc """
  Builds a timeout error.

  Always lands on `ExecutionError` with `phase: :timeout` — timeouts are
  runtime failures, not input-validation problems.
  """
  @spec timeout(atom(), non_neg_integer() | nil, keyword() | map()) :: Exception.t()
  def timeout(operation, timeout_ms, opts \\ %{}) when is_atom(operation) do
    message =
      get_detail(opts, :message) || "#{humanize_atom(operation)} timed out."

    execution_error(message,
      phase: :timeout,
      details:
        merge_details(opts, %{
          reason: :timeout,
          operation: operation,
          timeout: timeout_ms
        })
    )
  end

  @doc """
  Builds a missing-required-value validation error.

  Equivalent of Jidoka's `missing_context/2`, reframed because "context" is
  overloaded in JidoClaw.
  """
  @spec missing_required(atom() | String.t(), keyword() | map()) :: Exception.t()
  def missing_required(key, opts \\ %{}) when is_atom(key) or is_binary(key) do
    validation_error("Missing required value for `#{key}`.",
      field: key,
      value: get_detail(opts, :value),
      details: merge_details(opts, %{reason: :missing_required, key: key})
    )
  end

  defp put_details(details, message) when is_map(details) do
    details
    |> Map.put(:message, message)
    |> Map.put_new(:details, %{})
  end

  defp put_details(details, message) when is_list(details) do
    details
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
  end

  defp merge_details(opts, base) when is_map(opts) do
    Map.merge(base, Map.get(opts, :details, %{}))
  end

  defp merge_details(opts, base) when is_list(opts) do
    Map.merge(base, Keyword.get(opts, :details, %{}))
  end

  defp get_detail(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_detail(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_detail(_opts, _key), do: nil

  defp humanize_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @doc """
  Formats JidoClaw error terms for humans.

  * Class containers (`%Invalid{errors: [...]}`, etc.) flatten nested
    classes, dedupe, sort, and join as `"Multiple JidoClaw errors:\\n- ..."`
    or a single-line message when one survives the flattening.
  * Plain exceptions with a binary `:message` return that message directly.
  * Anything else falls back to `inspect/1`.
  """
  @spec format(term()) :: String.t()
  def format(%struct{errors: errors} = error) when is_list(errors) do
    if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
      format_error_class(errors)
    else
      inspect(error)
    end
  end

  def format(%{message: message}) when is_binary(message), do: message
  def format(message) when is_binary(message), do: message
  def format(other), do: inspect(other)

  @doc """
  Reduce an error `reason` to a short, **payload-free** tag string for safe
  logging — the leading atom of an atom or `{tag, …}` tuple, never the payload
  (which may echo prompt/secret/artifact text). Unlike `format/1` this never
  `inspect/1`s the value; an unrecognized shape is `"unknown"`. Pair it with the
  global log redactor for belt-and-suspenders.
  """
  @spec summarize_reason(term()) :: String.t()
  def summarize_reason(reason) when is_atom(reason), do: to_string(reason)
  def summarize_reason({tag, _detail}) when is_atom(tag), do: to_string(tag)
  def summarize_reason({tag, _a, _b}) when is_atom(tag), do: to_string(tag)
  def summarize_reason(_other), do: "unknown"

  defp format_error_class(errors) do
    errors
    |> flatten_class_errors()
    |> Enum.map(&format/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> "JidoClaw operation failed."
      [message] -> message
      messages -> "Multiple JidoClaw errors:\n" <> Enum.map_join(messages, "\n", &"- #{&1}")
    end
  end

  defp flatten_class_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(fn
      %struct{errors: nested} = error when is_list(nested) ->
        if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
          flatten_class_errors(nested)
        else
          [error]
        end

      error ->
        [error]
    end)
  end
end
