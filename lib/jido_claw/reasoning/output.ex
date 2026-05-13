defmodule JidoClaw.Reasoning.Output do
  @moduledoc """
  Shared helpers for extracting human-readable text from reasoning /
  workflow tool results.

  Reasoning tools (`Tools.Reason`, `Tools.RunPipeline`,
  `Tools.VerifyCertificate`) and the agent tools that pull intermediate
  outputs from sub-agents (`Tools.GetAgentResult`, `Workflows.StepAction`)
  all receive heterogeneous result shapes — sometimes a string, sometimes
  a wrapped map, sometimes a struct. This module hides the dispatch.
  """

  @doc """
  Coerce a reasoning tool result into a display string.

  Tries common keys (`:result`, `:answer`, `:conclusion`) on nested maps
  before falling back to `inspect/1`.
  """
  @spec extract_output(any()) :: String.t()
  def extract_output(%{output: output}) when is_binary(output) and output != "", do: output

  def extract_output(%{output: output}) when is_map(output) do
    cond do
      Map.has_key?(output, :result) -> output.result
      Map.has_key?(output, :answer) -> output.answer
      Map.has_key?(output, :conclusion) -> output.conclusion
      true -> inspect(output)
    end
  end

  def extract_output(%{output: output}), do: inspect(output)
  def extract_output(result), do: inspect(result)

  @doc """
  Coerce an agent-result map into a display string.

  Used by tools that pull intermediate or final outputs from a spawned
  sub-agent. Prefers `:last_answer`, then `:answer`, then `:text`; falls
  back to a pretty-printed inspect.
  """
  @spec extract_result(any()) :: String.t()
  def extract_result(%{last_answer: answer}) when is_binary(answer), do: answer
  def extract_result(%{answer: answer}) when is_binary(answer), do: answer
  def extract_result(%{text: text}) when is_binary(text), do: text
  def extract_result(result) when is_binary(result), do: result
  def extract_result(result), do: inspect(result, limit: :infinity, pretty: true)
end
