defmodule JidoClaw.Reasoning.YamlStore do
  @moduledoc """
  Shared helpers for YAML-backed reasoning stores (strategies, pipelines).
  """

  @doc """
  Extract and validate the `name` field from a parsed YAML document.

  Returns `{:ok, name}` for a non-empty string without a `/` separator
  (the latter would clash with the namespaced lookup in
  `StrategyRegistry` / `PipelineRegistry`).
  """
  @spec fetch_name(map()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_name(data) do
    case Map.get(data, "name") do
      name when is_binary(name) ->
        cleaned = String.trim(name)

        cond do
          cleaned == "" -> {:error, "empty name"}
          String.contains?(cleaned, "/") -> {:error, "name must not contain '/'"}
          true -> {:ok, cleaned}
        end

      _ ->
        {:error, "missing or non-string name"}
    end
  end
end
