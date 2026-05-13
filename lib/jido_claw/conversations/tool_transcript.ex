defmodule JidoClaw.Conversations.ToolTranscript do
  @moduledoc """
  Shared formatter helpers for tool-call/tool-result rows.

  Used by both the `Conversations.Recorder` (signal-driven path) and
  the `Tools.MCPScope.wrap/4` helper (MCP serve-mode path) so the two
  paths produce byte-identical row shapes.
  """

  alias JidoClaw.Conversations.TranscriptEnvelope
  alias JidoClaw.Security.Redaction.Transcript

  @doc """
  Run the supplied payload through the canonical envelope normalizer
  and the redactor. Both Recorder and MCP wrapper call this in place
  of the two-step pipeline they used to inline.
  """
  @spec envelope(any()) :: any()
  def envelope(payload) do
    payload
    |> TranscriptEnvelope.normalize()
    |> Transcript.redact()
  end

  @doc """
  One-line summary of tool arguments for the `content` column.
  """
  @spec summarize_args(String.t() | atom(), any()) :: String.t()
  def summarize_args(tool_name, arguments) do
    "#{to_string(tool_name)}(#{summarize_args_body(arguments)})"
  end

  defp summarize_args_body(args) when is_map(args) do
    args
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{summarize_value(v)}" end)
  end

  defp summarize_args_body(_), do: ""

  defp summarize_value(v) when is_binary(v), do: ~s("#{String.slice(v, 0, 40)}")
  defp summarize_value(v), do: inspect(v, limit: 5)

  @doc """
  One-line summary of a tool result for the `content` column.
  """
  @spec result_summary(String.t() | atom(), any()) :: String.t()
  def result_summary(tool_name, {:ok, _, _}), do: "#{to_string(tool_name)} → ok"
  def result_summary(tool_name, {:ok, _}), do: "#{to_string(tool_name)} → ok"

  def result_summary(tool_name, {:error, reason, _}),
    do: "#{to_string(tool_name)} → error: #{inspect(reason, limit: 3)}"

  def result_summary(tool_name, {:error, reason}),
    do: "#{to_string(tool_name)} → error: #{inspect(reason, limit: 3)}"

  def result_summary(tool_name, _), do: "#{to_string(tool_name)} → unknown"
end
