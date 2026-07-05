defmodule JidoClaw.Tools.Projection do
  @moduledoc """
  Shared MCP-boundary projection helpers for the read-only inspection
  tools (`inspect_agent`, `inspect_workflow`, `workflow_events`).
  """

  @doc """
  `to_string/1` that preserves `nil`.

  The projected fields (`model`/`status`) are atom-or-string-or-nil; a
  bare `to_string/1` would emit `"nil"` at the MCP boundary (nil is an
  atom), and a present-but-`"nil"` value would defeat the tools'
  add-key-only-when-non-nil projection rule.
  """
  @spec stringify_nilable(term()) :: String.t() | nil
  def stringify_nilable(nil), do: nil
  def stringify_nilable(value), do: to_string(value)
end
