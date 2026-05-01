defmodule JidoClaw.Security.Redaction.Embedding do
  @moduledoc """
  Outbound-text scrubber used by the embedding clients before any text
  leaves the host.

  Wraps `JidoClaw.Security.Redaction.Patterns.redact_with_count/1` so
  callers (`Voyage.embed_for_storage/1`, `Voyage.embed_for_query/1`,
  `Local.embed_for_storage/1`, `Local.embed_for_query/1`) get back the
  redacted input plus the count of redactions applied — the telemetry
  emitter reports `redactions_applied` per request so operators can see
  if scrubbing fired before paying the embedding cost.

  Non-binary input (e.g. a list of inputs) passes through unchanged
  with a count of 0.
  """

  alias JidoClaw.Security.Redaction.Patterns

  @doc """
  Returns `{redacted_input, redactions_applied_count}`.

  ## Examples

      iex> JidoClaw.Security.Redaction.Embedding.redact("client.api_base_url")
      {"client.api_base_url", 0}

      iex> {redacted, n} = JidoClaw.Security.Redaction.Embedding.redact("Bearer abcdef0123456789abcdef")
      iex> n
      1
      iex> String.contains?(redacted, "[REDACTED]")
      true
  """
  @spec redact(String.t() | term()) :: {String.t() | term(), non_neg_integer()}
  def redact(text), do: Patterns.redact_with_count(text)
end
