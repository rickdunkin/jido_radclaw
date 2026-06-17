defmodule JidoClaw.Tools.OutputRedaction do
  @moduledoc """
  Redacts tool execution results before they are returned to an agent.
  """

  alias JidoClaw.Security.Redaction.{Ansi, Env, Patterns}

  @binary_payload_keys ~w(base64 bytes image_bytes screenshot screenshot_base64)

  @spec redact_result(term()) :: term()
  def redact_result({:ok, output}), do: {:ok, redact(output)}
  def redact_result({:ok, output, effects}), do: {:ok, redact(output), redact(effects)}
  def redact_result({:error, reason}), do: {:error, redact(reason)}
  def redact_result({:error, reason, effects}), do: {:error, redact(reason), redact(effects)}
  def redact_result(other), do: redact(other)

  # ANSI escapes can interrupt a secret (`sk-ant-\e[0m...`) so a raw value
  # scan would miss it — strip first to reassemble, then redact. Closes the
  # leak for every tool and every path (incl. under-cap MCP passthrough) at
  # the root, so the shaping path downstream consumes already-clean text.
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value), do: Patterns.redact(Ansi.strip(value))

  def redact(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key, redact_value(key, inner)} end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value), do: value

  defp redact_value(key, value) do
    cond do
      sensitive_key?(key) ->
        "[REDACTED]"

      binary_payload_key?(key) and is_binary(value) ->
        "[REDACTED:BINARY_PAYLOAD]"

      true ->
        redact(value)
    end
  end

  defp sensitive_key?(key), do: Env.sensitive_key?(classified_key(key))

  defp binary_payload_key?(key), do: classified_key(key) in @binary_payload_keys

  # Classify keys through an ANSI strip so an escape-split key
  # (`"api_\e[0mkey"`) can't dodge sensitive-key detection while its value
  # leaks. The emitted key is left unmutated — the `Map.new/2` in `redact/1`
  # keeps the original; only classification sees the stripped form. Atoms are
  # handled defensively (they come from code, not external JSON); a non-binary,
  # non-atom key falls through to a guaranteed-false classification downstream.
  defp classified_key(key) when is_atom(key), do: Ansi.strip(Atom.to_string(key))
  defp classified_key(key) when is_binary(key), do: Ansi.strip(key)
  defp classified_key(key), do: key
end
