defmodule JidoClaw.Security.Redaction.Patterns do
  @moduledoc """
  Binary-pattern secret scrubber.

  Order matters: Anthropic-prefixed `sk-ant-...` keys must be matched
  *before* the generic `sk-...` rule, otherwise the generic pattern
  consumes the prefix and emits `[REDACTED:API_KEY]` instead of
  `[REDACTED:ANTHROPIC_KEY]`. The full ordering invariant — most-
  specific to most-generic — is also exercised by tests in
  `test/jido_claw/security/redaction/patterns_test.exs`.
  """

  @patterns [
    # Anthropic keys — must come BEFORE generic sk-… so the prefix isn't consumed
    {~r/sk-ant-[a-zA-Z0-9_-]{20,}/, "[REDACTED:ANTHROPIC_KEY]"},
    # OpenAI / generic API keys
    {~r/sk-[a-zA-Z0-9_-]{20,}/, "[REDACTED:API_KEY]"},
    # JidoClaw API keys
    {~r/jidoclaw_[a-zA-Z0-9_-]{20,}/, "[REDACTED:JIDOCLAW_KEY]"},
    # GitHub PATs
    {~r/ghp_[a-zA-Z0-9]{36}/, "[REDACTED:GITHUB_PAT]"},
    {~r/github_pat_[a-zA-Z0-9_]{20,}/, "[REDACTED:GITHUB_PAT]"},
    # Bearer tokens
    {~r/Bearer\s+[a-zA-Z0-9_\-\.]{20,}/, "Bearer [REDACTED]"},
    # JWTs (three base64 segments separated by dots)
    {~r/eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/, "[REDACTED:JWT]"},
    # URL-with-userinfo (lifted from Redaction.Env so transcript/embedding
    # callers redact `scheme://user:pass@host/...` even outside env-var contexts).
    {~r{(\w+://)([^:@/\s]+):([^@/\s]+)(@)}, "\\1\\2:[REDACTED]\\4"},
    # Generic secrets in env vars
    {~r/(?i)(password|secret|token|api_key|apikey)\s*[=:]\s*["']?[^\s"']{8,}["']?/,
     "[REDACTED:SECRET]"},
    # AWS keys
    {~r/AKIA[0-9A-Z]{16}/, "[REDACTED:AWS_KEY]"}
  ]

  @doc """
  Apply all binary-pattern redactions to `text` in declaration order.

  Returns the redacted string. Non-binary input passes through unchanged
  — callers (logs, signals, mixed-shape transcripts) sometimes hand in
  arbitrary terms.
  """
  @spec redact(String.t() | term()) :: String.t() | term()
  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def redact(other), do: other

  @doc """
  Returns `{redacted, count}` — the redacted string and the number of
  patterns whose replacement actually fired (counted by global match
  count summed over all patterns). Used by the embedding telemetry
  to report `redactions_applied` per request.
  """
  @spec redact_with_count(String.t() | term()) :: {String.t() | term(), non_neg_integer()}
  def redact_with_count(text) when is_binary(text) do
    Enum.reduce(@patterns, {text, 0}, fn {pattern, replacement}, {acc, n} ->
      matches = Regex.scan(pattern, acc) |> length()
      {Regex.replace(pattern, acc, replacement), n + matches}
    end)
  end

  def redact_with_count(other), do: {other, 0}
end
