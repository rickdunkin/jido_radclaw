defmodule JidoClaw.Tools.Error do
  @moduledoc """
  Normalizes tool failures into one agent-facing error shape.

  Wire format: `%{code: atom, message: String.t(), details: map}`.

  Inputs are dispatched in two tiers:

  1. **First-party structured errors** (`%JidoClaw.Error.*{}`) — `code` comes
     from a strict `struct_code/1` map (never conflating `:phase` with
     `:code`); `message` comes from `Exception.message/1` for leaves and
     `JidoClaw.Error.format/1` for class containers; `details` is the
     flattened-and-sanitized union of the struct's inner `:details` map and
     its top-level leaf fields.
  2. **Legacy heterogeneous inputs** (strings, atoms, tagged tuples, plain
     maps, foreign exceptions) — kept on the existing fallback path so
     callers that haven't migrated yet still produce the same wire shape.

  `details` is always passed through `sanitize_details/1` before reaching
  the agent. `OutputRedaction` and `OutputLimit` intentionally skip structs,
  so without this layer raw `%File.Error{}` payloads, PIDs, refs, large
  `old_string` blobs, etc. would leak directly to the LLM context. PIDs,
  refs, and ports are dropped entirely from maps and lists; inside tuples
  (where positional structure can't tolerate missing elements) they are
  replaced with the atom `:dropped_runtime_handle`.

  Both `wire.message` and string values inside structured/exception
  `wire.details` are capped at `@max_string_bytes` (2 KB) and UTF-8 trimmed
  at the truncation boundary. Legacy plain-map detail strings are handled
  by the downstream `OutputLimit` pass in the tool wrapper, not here.
  """

  alias JidoClaw.Tools.OutputLimit

  @type t :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:details) => map()
        }

  @jido_claw_leaf_structs [
    JidoClaw.Error.ValidationError,
    JidoClaw.Error.ConfigError,
    JidoClaw.Error.ExecutionError,
    JidoClaw.Error.Internal.UnknownError
  ]

  @jido_claw_class_structs [
    JidoClaw.Error.Invalid,
    JidoClaw.Error.Config,
    JidoClaw.Error.Execution,
    JidoClaw.Error.Internal
  ]

  @max_string_bytes 2 * 1024
  @max_collection_bytes 8 * 1024

  # Allow-list of keys preserved when an oversized top-level details map is
  # collapsed to a summary placeholder. These are the keys consumers actually
  # log/route on; growing the list risks the placeholder itself being oversized.
  @kept_when_truncated [
    :phase,
    :field,
    :code,
    :status,
    :agent_id,
    :operation,
    :reason,
    :kind
  ]

  # Sentinel emitted by `sanitize_value/1` for values that must be removed
  # entirely (PIDs, refs, ports). Tagged with `__MODULE__` so a legitimate
  # user-supplied atom can never collide. Always check via `drop?/1`.
  @drop {__MODULE__, :drop}

  @spec normalize_result(term()) :: term()
  def normalize_result({:ok, %{status: status} = output})
      when status in [:failed, "failed", :error, "error"] do
    {:error, normalize(output)}
  end

  def normalize_result({:error, reason}), do: {:error, normalize(reason)}
  def normalize_result({:error, reason, effects}), do: {:error, normalize(reason), effects}
  def normalize_result(other), do: other

  @spec normalize(term()) :: t()
  # ---- First-party JidoClaw leaf ----
  def normalize(%struct{} = error) when struct in @jido_claw_leaf_structs do
    %{
      code: struct_code(error),
      message: truncate_string(Exception.message(error)),
      details: sanitize_details(error_details(error))
    }
  end

  # ---- First-party JidoClaw class container ----
  def normalize(%struct{errors: errors, class: class} = error)
      when struct in @jido_claw_class_structs and is_list(errors) do
    %{
      code: struct_code(error),
      message: truncate_string(JidoClaw.Error.format(error)),
      details:
        sanitize_details(%{
          class: class,
          errors: Enum.map(errors, &child_error_summary/1)
        })
    }
  end

  # ---- Legacy heterogeneous inputs (preserved) ----
  #
  # No sanitize_details/1 on these paths: OutputLimit and OutputRedaction
  # already walk plain maps. Sanitization is reserved for the struct paths
  # above, where those passes skip the inputs entirely.
  def normalize(%{code: code, message: message, details: details})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %{code: code, message: truncate_string(message), details: details}
  end

  def normalize(%module{} = reason) do
    %{
      code: struct_code(reason),
      message: truncate_string(exception_message(reason)),
      details:
        reason
        |> Map.from_struct()
        |> Map.drop([:code, :message])
        |> Map.put(:type, inspect(module))
        |> sanitize_details()
    }
  end

  def normalize(%{message: message} = reason) when is_binary(message) do
    %{
      code: code_from_map(reason),
      message: truncate_string(message),
      details: details_from_map(reason, [:code, :message, "code", "message"])
    }
  end

  def normalize(%{"message" => message} = reason) when is_binary(message) do
    %{
      code: code_from_map(reason),
      message: truncate_string(message),
      details: details_from_map(reason, [:code, :message, "code", "message"])
    }
  end

  def normalize(%{error: error} = reason) do
    %{
      code: code_from_map(reason),
      message: truncate_string(message(error)),
      details: details_from_map(reason, [:code, :error, "code", "error"])
    }
  end

  def normalize(%{"error" => error} = reason) do
    %{
      code: code_from_map(reason),
      message: truncate_string(message(error)),
      details: details_from_map(reason, [:code, :error, "code", "error"])
    }
  end

  def normalize(reason) when is_binary(reason) do
    %{code: :tool_error, message: truncate_string(reason), details: %{}}
  end

  def normalize(reason) when is_atom(reason) do
    %{code: reason, message: humanize_atom(reason), details: %{}}
  end

  def normalize({code, _} = reason) when is_atom(code) do
    %{code: code, message: humanize_atom(code), details: %{reason: inspect(reason)}}
  end

  def normalize(reason) do
    %{
      code: :tool_error,
      message: truncate_string(inspect(reason)),
      details: %{reason: inspect(reason)}
    }
  end

  # ---- struct_code/1: strict mapping, NEVER conflates phase with code ----

  defp struct_code(%JidoClaw.Error.ValidationError{}), do: :validation_error
  defp struct_code(%JidoClaw.Error.ConfigError{}), do: :config_error
  defp struct_code(%JidoClaw.Error.ExecutionError{}), do: :execution_error
  defp struct_code(%JidoClaw.Error.Internal.UnknownError{}), do: :unknown_error
  defp struct_code(%JidoClaw.Error.Invalid{}), do: :validation_error
  defp struct_code(%JidoClaw.Error.Config{}), do: :config_error
  defp struct_code(%JidoClaw.Error.Execution{}), do: :execution_error
  defp struct_code(%JidoClaw.Error.Internal{}), do: :internal_error
  defp struct_code(%{code: code}), do: code_from_value(code)
  defp struct_code(%{status: status}), do: code_from_value(status)
  defp struct_code(%{__exception__: true}), do: :exception
  defp struct_code(_reason), do: :tool_error

  # ---- error_details/1: flatten inner :details + overlay leaf fields ----

  defp error_details(%JidoClaw.Error.ValidationError{
         field: field,
         value: value,
         details: details
       }) do
    details
    |> ensure_map()
    |> maybe_put(:field, field)
    |> maybe_put(:value, value)
  end

  defp error_details(%JidoClaw.Error.ConfigError{field: field, value: value, details: details}) do
    details
    |> ensure_map()
    |> maybe_put(:field, field)
    |> maybe_put(:value, value)
  end

  defp error_details(%JidoClaw.Error.ExecutionError{phase: phase, details: details}) do
    details
    |> ensure_map()
    |> maybe_put(:phase, phase)
  end

  defp error_details(%JidoClaw.Error.Internal.UnknownError{error: inner, details: details}) do
    details
    |> ensure_map()
    |> maybe_put(:error, sanitize_value(inner))
  end

  defp ensure_map(value) when is_map(value) and not is_struct(value), do: value
  defp ensure_map(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- child_error_summary/1: per-error wire shape inside a class container ----

  defp child_error_summary(%struct{} = error) when struct in @jido_claw_leaf_structs do
    %{code: struct_code(error), message: truncate_string(Exception.message(error))}
  end

  defp child_error_summary(%struct{} = error) when is_exception(error) do
    %{code: :foreign, module: inspect(struct), message: truncate_string(Exception.message(error))}
  end

  defp child_error_summary(other) do
    %{code: :unknown, message: truncate_string(inspect(other))}
  end

  # ---- sanitize_details/1: recursive scrub ----
  #
  # Compensates for `OutputRedaction`/`OutputLimit` skipping structs by
  # walking the details map and:
  #  * replacing nested exception structs with %{module: <inspect string>, message: ...}
  #  * dropping PIDs, refs, ports, stacktrace tuples
  #  * truncating long strings (>@max_string_bytes)
  #  * truncating large collections (>@max_collection_bytes serialized)

  @doc false
  def sanitize_details(value) when is_map(value) and not is_struct(value) do
    sanitized =
      value
      |> Enum.map(fn {k, v} -> {k, sanitize_value(v)} end)
      |> Enum.reject(fn {_k, v} -> drop?(v) end)
      |> Map.new()

    if approximate_byte_size(sanitized) > @max_collection_bytes do
      %{
        truncated: true,
        description: describe(sanitized),
        kept: Map.take(sanitized, @kept_when_truncated)
      }
    else
      sanitized
    end
  end

  def sanitize_details(_value), do: %{}

  defp drop?(@drop), do: true
  defp drop?(_), do: false

  defp sanitize_value(value) when is_binary(value), do: truncate_string(value)

  defp sanitize_value(%struct{} = exception) when is_exception(exception) do
    %{module: inspect(struct), message: truncate_string(safe_exception_message(exception))}
  end

  defp sanitize_value(%_struct{} = other) do
    %{module: inspect(other.__struct__), value: truncate_string(inspect(other))}
  end

  defp sanitize_value(value) when is_pid(value) or is_reference(value) or is_port(value),
    do: @drop

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, sanitize_value(v)} end)
    |> Enum.reject(fn {_k, v} -> drop?(v) end)
    |> Map.new()
    |> cap_collection()
  end

  defp sanitize_value(value) when is_list(value) do
    if stacktrace?(value) do
      "[stacktrace dropped]"
    else
      value
      |> Enum.map(&sanitize_value/1)
      |> Enum.reject(&drop?/1)
      |> cap_collection()
    end
  end

  # Tuples preserve positional structure (e.g. `{:ok, pid}` from
  # `GenServer.start_link/3`), so dropped runtime handles are replaced
  # with the placeholder atom `:dropped_runtime_handle` rather than
  # removed — wholesale tuple replacement would lose the `:ok`
  # discriminator that callers pattern-match on.
  defp sanitize_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(fn element ->
      sanitized = sanitize_value(element)
      if drop?(sanitized), do: :dropped_runtime_handle, else: sanitized
    end)
    |> List.to_tuple()
  end

  defp sanitize_value(value), do: value

  defp stacktrace?([{mod, fun, arity_or_args, _location} | _])
       when is_atom(mod) and is_atom(fun) and
              (is_integer(arity_or_args) or is_list(arity_or_args)),
       do: true

  defp stacktrace?(_), do: false

  defp safe_exception_message(exception) do
    Exception.message(exception)
  rescue
    _ -> inspect(exception)
  end

  defp truncate_string(str) when is_binary(str) and byte_size(str) > @max_string_bytes do
    str
    |> binary_part(0, @max_string_bytes)
    |> OutputLimit.valid_utf8_prefix()
    |> Kernel.<>("... (truncated)")
  end

  defp truncate_string(str), do: str

  defp cap_collection(collection) when is_map(collection) do
    if approximate_byte_size(collection) > @max_collection_bytes do
      %{truncated: true, description: describe(collection)}
    else
      collection
    end
  end

  defp cap_collection(collection) when is_list(collection) do
    if approximate_byte_size(collection) > @max_collection_bytes do
      [%{truncated: true, description: describe(collection)}]
    else
      collection
    end
  end

  defp approximate_byte_size(value), do: value |> inspect() |> byte_size()

  defp describe(value) when is_map(value), do: "map with #{map_size(value)} keys"
  defp describe(value) when is_list(value), do: "list with #{length(value)} items"

  # ---- legacy helpers (unchanged) ----

  defp code_from_map(reason) do
    reason
    |> value_for([:code, "code", :status, "status"])
    |> code_from_value()
  end

  defp code_from_value(code) when is_atom(code), do: code
  defp code_from_value({_, code}) when is_atom(code), do: code
  defp code_from_value("failed"), do: :failed
  defp code_from_value("error"), do: :error
  defp code_from_value("still_running"), do: :still_running
  defp code_from_value("timeout"), do: :timeout
  defp code_from_value(_code), do: :tool_error

  defp exception_message(%{__exception__: true} = reason), do: Exception.message(reason)
  defp exception_message(%{message: message}) when is_binary(message), do: message
  defp exception_message(reason), do: inspect(reason)

  defp details_from_map(reason, drop_keys) do
    reason
    |> Map.drop(drop_keys)
    |> case do
      empty when map_size(empty) == 0 -> %{}
      details -> %{context: details}
    end
  end

  defp value_for(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_atom(reason), do: humanize_atom(reason)
  defp message(reason), do: inspect(reason)

  defp humanize_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
  end
end
