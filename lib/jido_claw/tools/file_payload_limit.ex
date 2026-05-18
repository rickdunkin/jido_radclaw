defmodule JidoClaw.Tools.FilePayloadLimit do
  @moduledoc false

  @max_bytes 5 * 1024 * 1024

  def max_bytes, do: @max_bytes

  def validate(_field, content) when is_binary(content) and byte_size(content) <= @max_bytes do
    :ok
  end

  def validate(field, content) when is_binary(content) do
    {:error, "#{field} exceeds #{@max_bytes} byte limit (#{byte_size(content)} bytes)."}
  end
end
