defmodule JidoClaw.Security.Redaction.Ansi do
  @moduledoc """
  Strips ANSI escape sequences from text before redaction.

  ANSI escapes can interrupt a secret mid-string — `sk-ant-\\e[0m...` —
  so a value- or key-pattern scan would miss it. Stripping the escapes
  first reassembles the secret (or the key name) so the downstream
  `Patterns`/`Env` classifiers see the real bytes.

  Pure leaf: only the three escape regexes and `strip/1`, no
  dependencies. Lives under `security/redaction/` so both the tool
  pipeline (`OutputRedaction`, `OutputShaper`) and any other caller can
  reach it without a cycle.
  """

  # CSI (colors, cursor), OSC (titles, hyperlinks), then remaining
  # two-byte ESC sequences — in that order, so ESC-[ / ESC-] are consumed
  # as CSI/OSC starts before the generic rule sees them.
  @ansi_csi ~r/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/
  @ansi_osc ~r/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?/
  @ansi_two_byte ~r/\x1b[\x40-\x5f]/

  @doc """
  Remove ANSI escape sequences from `text`, returning plain text.

  Stripping ANSI from LLM/tool-bound text is benign — the model doesn't
  render ANSI — and reassembles any escape-split secret for redaction.
  """
  @spec strip(binary()) :: binary()
  def strip(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@ansi_csi, &1, ""))
    |> then(&Regex.replace(@ansi_osc, &1, ""))
    |> then(&Regex.replace(@ansi_two_byte, &1, ""))
  end
end
