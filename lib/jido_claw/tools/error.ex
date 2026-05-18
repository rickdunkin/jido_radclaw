defmodule JidoClaw.Tools.Error do
  @moduledoc """
  Normalizes tool failures into one agent-facing error shape.
  """

  @type t :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:details) => map()
        }

  @spec normalize_result(term()) :: term()
  def normalize_result({:ok, %{status: status} = output})
      when status in [:failed, "failed", :error, "error"] do
    {:error, normalize(output)}
  end

  def normalize_result({:error, reason}), do: {:error, normalize(reason)}
  def normalize_result({:error, reason, effects}), do: {:error, normalize(reason), effects}
  def normalize_result(other), do: other

  @spec normalize(term()) :: t()
  def normalize(%{code: code, message: message, details: details})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %{code: code, message: message, details: details}
  end

  def normalize(%module{} = reason) do
    %{
      code: struct_code(reason),
      message: exception_message(reason),
      details:
        reason
        |> Map.from_struct()
        |> Map.drop([:code, :message])
        |> Map.put(:type, inspect(module))
    }
  end

  def normalize(%{message: message} = reason) when is_binary(message) do
    %{
      code: code_from_map(reason),
      message: message,
      details: details_from_map(reason, [:code, :message, "code", "message"])
    }
  end

  def normalize(%{"message" => message} = reason) when is_binary(message) do
    %{
      code: code_from_map(reason),
      message: message,
      details: details_from_map(reason, [:code, :message, "code", "message"])
    }
  end

  def normalize(%{error: error} = reason) do
    %{
      code: code_from_map(reason),
      message: message(error),
      details: details_from_map(reason, [:code, :error, "code", "error"])
    }
  end

  def normalize(%{"error" => error} = reason) do
    %{
      code: code_from_map(reason),
      message: message(error),
      details: details_from_map(reason, [:code, :error, "code", "error"])
    }
  end

  def normalize(reason) when is_binary(reason) do
    %{code: :tool_error, message: reason, details: %{}}
  end

  def normalize(reason) when is_atom(reason) do
    %{code: reason, message: humanize_atom(reason), details: %{}}
  end

  def normalize({code, _} = reason) when is_atom(code) do
    %{code: code, message: humanize_atom(code), details: %{reason: inspect(reason)}}
  end

  def normalize(reason) do
    %{code: :tool_error, message: inspect(reason), details: %{reason: inspect(reason)}}
  end

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

  defp struct_code(%{code: code}), do: code_from_value(code)
  defp struct_code(%{status: status}), do: code_from_value(status)
  defp struct_code(%{__exception__: true}), do: :exception
  defp struct_code(_reason), do: :tool_error

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
