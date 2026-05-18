defmodule JidoClaw.Tools.OutputRedaction do
  @moduledoc """
  Redacts tool execution results before they are returned to an agent.
  """

  alias JidoClaw.Security.Redaction.{Env, Patterns}

  @binary_payload_keys ~w(base64 bytes image_bytes screenshot screenshot_base64)

  @spec redact_result(term()) :: term()
  def redact_result({:ok, output}), do: {:ok, redact(output)}
  def redact_result({:ok, output, effects}), do: {:ok, redact(output), redact(effects)}
  def redact_result({:error, reason}), do: {:error, redact(reason)}
  def redact_result({:error, reason, effects}), do: {:error, redact(reason), redact(effects)}
  def redact_result(other), do: redact(other)

  @spec redact(term()) :: term()
  def redact(value) when is_binary(value), do: Patterns.redact(value)

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

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> Env.sensitive_key?()
  defp sensitive_key?(key) when is_binary(key), do: Env.sensitive_key?(key)
  defp sensitive_key?(_key), do: false

  defp binary_payload_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> binary_payload_key?()

  defp binary_payload_key?(key) when is_binary(key), do: key in @binary_payload_keys
  defp binary_payload_key?(_key), do: false
end
