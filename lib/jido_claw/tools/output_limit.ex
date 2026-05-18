defmodule JidoClaw.Tools.OutputLimit do
  @moduledoc """
  Caps agent-facing tool output at a uniform byte threshold.
  """

  @default_max_bytes 32 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes do
    Application.get_env(:jido_claw, :tool_output_max_bytes, @default_max_bytes)
  end

  @spec truncate_result(term()) :: term()
  def truncate_result(result), do: truncate(result, max_bytes())

  @spec truncate(term(), pos_integer()) :: term()
  def truncate(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    marker = truncation_marker(byte_size(value), max_bytes)
    prefix_bytes = max(max_bytes - byte_size(marker), 0)

    value
    |> binary_part(0, prefix_bytes)
    |> valid_utf8_prefix()
    |> Kernel.<>(marker)
  end

  def truncate(value, _max_bytes) when is_binary(value), do: value

  def truncate(value, max_bytes) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key, truncate(inner, max_bytes)} end)
  end

  def truncate(value, max_bytes) when is_list(value),
    do: Enum.map(value, &truncate(&1, max_bytes))

  def truncate(value, max_bytes) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&truncate(&1, max_bytes))
    |> List.to_tuple()
  end

  def truncate(value, _max_bytes), do: value

  defp truncation_marker(original_bytes, max_bytes) do
    "\n\n[tool output truncated: original #{original_bytes} bytes, cap #{max_bytes} bytes]"
  end

  defp valid_utf8_prefix(value) do
    if String.valid?(value) do
      value
    else
      trim_to_valid_utf8(value, byte_size(value))
    end
  end

  defp trim_to_valid_utf8(_value, 0), do: ""

  defp trim_to_valid_utf8(value, bytes) do
    candidate = binary_part(value, 0, bytes)

    if String.valid?(candidate) do
      candidate
    else
      trim_to_valid_utf8(value, bytes - 1)
    end
  end
end
