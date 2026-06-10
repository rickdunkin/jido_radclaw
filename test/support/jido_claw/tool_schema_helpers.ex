defmodule JidoClaw.ToolSchemaHelpers do
  @moduledoc false

  @spec tool_property_schema(module(), atom()) :: map()
  def tool_property_schema(action, field) do
    properties =
      action.to_tool()
      |> Map.fetch!(:parameters_schema)
      |> stringify_keys()
      |> Map.fetch!("properties")

    Map.fetch!(properties, Atom.to_string(field))
  end

  @spec max_length(map()) :: integer()
  def max_length(schema) do
    schema
    |> stringify_keys()
    |> Map.fetch!("maxLength")
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
