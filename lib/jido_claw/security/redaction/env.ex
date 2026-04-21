defmodule JidoClaw.Security.Redaction.Env do
  @moduledoc """
  Environment-variable redaction for profile values in logs and
  `/profile current` output.

  Unlike `JidoClaw.Security.Redaction.Patterns` which scans value strings
  for known secret formats (`sk-...`, `ghp_...`, JWTs), this module
  classifies by *key name* — `DATABASE_PASSWORD=prod-cluster-01` is
  sensitive even though `prod-cluster-01` doesn't match any value
  pattern. Falls through to `Patterns.redact/1` so values with embedded
  API keys still get scrubbed.

  ## Rules

    * Key name ending in `_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`,
      `_PASS`, or `_PAT` (case-insensitive) → whole value masked as
      `[REDACTED]`.
    * Specific names — `AWS_SECRET_*`, `AWS_SESSION_TOKEN`,
      `DATABASE_URL`, `DB_URL` → whole value masked (user/host in a
      connection URL can be sensitive on its own).
    * Values matching `scheme://user:pass@host/...` → password segment
      masked, user/scheme/host preserved.
    * Otherwise → pass through `Patterns.redact/1`.

  ## Documented false negatives

  Suffix-only matching leaves `SESSION_ID`, `USER_ID`, `CLIENT_ID` etc.
  untouched. Over-redacting identifiers that show up in legitimate
  tracing/debugging output is worse than under-redacting for a dev
  tool — the trade-off is explicit.
  """

  alias JidoClaw.Security.Redaction.Patterns

  @sensitive_suffix ~r/_(KEY|TOKEN|SECRET|PASSWORD|PASS|PAT)$/i
  @sensitive_specific ~r/^(AWS_SECRET_.*|AWS_SESSION_TOKEN|DATABASE_URL|DB_URL)$/i
  @url_with_creds ~r{(\w+://)([^:@/]+):([^@/]+)(@)}

  @doc """
  Redacts sensitive values in the given env map. Returns a new map with
  the same keys and redacted-or-preserved values.
  """
  @spec redact_env(map()) :: map()
  def redact_env(env) when is_map(env) do
    Enum.into(env, %{}, fn {k, v} -> {k, redact_value(k, v)} end)
  end

  def redact_env(other), do: other

  @doc """
  Redacts a single value based on its key name.

    * Sensitive keys → `[REDACTED]`
    * URL-with-creds values → password segment masked
    * Otherwise → `Patterns.redact/1` (catches embedded API keys)

  Defensive on non-binary values: coerced via `to_string/1` before
  matching so call-sites passing arbitrary terms from logs/signals
  don't crash.
  """
  @spec redact_value(String.t(), String.t() | term()) :: String.t()
  def redact_value(key, value) when is_binary(key) do
    value_str = coerce(value)

    cond do
      sensitive_key?(key) ->
        "[REDACTED]"

      String.match?(value_str, @url_with_creds) ->
        Regex.replace(@url_with_creds, value_str, "\\1\\2:[REDACTED]\\4")

      true ->
        Patterns.redact(value_str)
    end
  end

  def redact_value(_key, value), do: coerce(value)

  @doc """
  Returns `true` when the given key name matches a sensitive pattern.
  """
  @spec sensitive_key?(String.t()) :: boolean()
  def sensitive_key?(key) when is_binary(key) do
    String.match?(key, @sensitive_suffix) or String.match?(key, @sensitive_specific)
  end

  def sensitive_key?(_), do: false

  defp coerce(v) when is_binary(v), do: v
  defp coerce(v), do: to_string(v)
end
