defmodule JidoClaw.Tools.FilePayloadLimit do
  @moduledoc false

  @max_bytes 5 * 1024 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec validate(atom(), binary()) :: :ok | {:error, String.t()}
  def validate(_field, content) when is_binary(content) and byte_size(content) <= @max_bytes do
    :ok
  end

  def validate(field, content) when is_binary(content) do
    {:error, "#{field} exceeds #{@max_bytes} byte limit (#{byte_size(content)} bytes)."}
  end
end
