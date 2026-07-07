defmodule JidoClaw.Security.Redaction.PromptRedaction do
  @moduledoc false

  alias JidoClaw.Security.Redaction.Ansi
  alias JidoClaw.Security.Redaction.Patterns

  # Both clauses run the ANSI pre-pass before the pattern scan (PR-3 — the
  # `OutputRedaction` root's posture, applied at prompt EGRESS too): an
  # escape-split secret (`sk-ant-\e[0m…`) must be reassembled or the value
  # scan misses it. Blast radius is the vendor-runner egress sites (codex /
  # claude_code argv + context.md) — all outbound to a second vendor, all
  # should strip.
  @spec redact(String.t() | list()) :: String.t() | list()
  def redact(text) when is_binary(text), do: Patterns.redact(Ansi.strip(text))

  def redact(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{"content" => content} = msg when is_binary(content) ->
        Map.put(msg, "content", Patterns.redact(Ansi.strip(content)))

      %{content: content} = msg when is_binary(content) ->
        Map.put(msg, :content, Patterns.redact(Ansi.strip(content)))

      other ->
        other
    end)
  end

  def redact(other), do: other
end
