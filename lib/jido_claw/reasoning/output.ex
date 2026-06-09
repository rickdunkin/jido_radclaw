defmodule JidoClaw.Reasoning.Output do
  @moduledoc """
  Shared helpers for extracting human-readable text from reasoning /
  workflow tool results.

  Reasoning tools (`Tools.Reason`, `Tools.RunPipeline`,
  `Tools.VerifyCertificate`) and the agent tools that pull intermediate
  outputs from sub-agents (`Tools.GetAgentResult`, `Skills.Steps.AgentRunner`)
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
  sub-agent. Prefers `:last_answer`, then `:answer`, then `:text`; for
  typed structured-output maps (post `Jido.AI.Output` validation), falls
  back to `:summary` and finally `:reasoning` so workflow transcripts get
  prose instead of an inspected map. Anything else is pretty-printed.
  """
  @spec extract_result(any()) :: String.t()
  def extract_result(%{last_answer: answer}) when is_binary(answer), do: answer
  def extract_result(%{answer: answer}) when is_binary(answer), do: answer
  def extract_result(%{text: text}) when is_binary(text), do: text
  def extract_result(%{summary: summary}) when is_binary(summary), do: summary
  def extract_result(%{"summary" => summary}) when is_binary(summary), do: summary
  def extract_result(%{reasoning: reasoning}) when is_binary(reasoning), do: reasoning
  def extract_result(%{"reasoning" => reasoning}) when is_binary(reasoning), do: reasoning
  def extract_result(result) when is_binary(result), do: result
  def extract_result(result), do: inspect(result, limit: :infinity, pretty: true)

  @doc """
  Pull the `:result` field out of a request map (or a JSON-decoded
  string-keyed equivalent), falling back to the whole value when no
  `:result` key is present. Used when `Jido.AgentServer.await_completion`
  is configured with `result_path: [:requests, request_id]` — the whole
  request map comes back, and callers need to split `:result` from
  `:meta`.
  """
  @spec request_result(map() | any()) :: any()
  def request_result(%{result: result}), do: result
  def request_result(%{"result" => result}), do: result
  def request_result(other), do: other

  @doc """
  Pull `meta.output` (the `Jido.AI.Output.meta/4` bag) out of a request
  map. Returns the meta map when present and shaped correctly, otherwise
  `nil`. Accepts both atom- and string-keyed shapes.
  """
  @spec request_meta_output(map() | any()) :: map() | nil
  def request_meta_output(%{meta: %{output: meta}}) when is_map(meta), do: meta
  def request_meta_output(%{"meta" => %{"output" => meta}}) when is_map(meta), do: meta
  def request_meta_output(_), do: nil

  @doc """
  Return the typed result from a request map when `meta.output[:status]`
  is `:validated` or `:repaired` and `:result` is a map. Returns `nil`
  otherwise — fall back to `extract_result/1` on the request's raw
  result for legacy free-form text.
  """
  @spec typed_request_output(map() | any()) :: map() | nil
  def typed_request_output(request) when is_map(request) do
    case output_status(request_meta_output(request)) do
      status when status in [:validated, :repaired, "validated", "repaired"] ->
        typed_result(request)

      _ ->
        nil
    end
  end

  def typed_request_output(_), do: nil

  defp output_status(%{status: status}), do: status
  defp output_status(%{"status" => status}), do: status
  defp output_status(_), do: nil

  defp typed_result(request) do
    case request_result(request) do
      result when is_map(result) -> result
      _ -> nil
    end
  end
end
