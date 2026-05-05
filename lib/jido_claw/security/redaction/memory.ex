defmodule JidoClaw.Security.Redaction.Memory do
  @moduledoc """
  Redactor for `Memory.Fact` and `Memory.Block` content + metadata.

  Wraps `JidoClaw.Security.Redaction.Patterns.redact/1` (which already
  scrubs API keys, JWTs, bearer tokens, AWS keys, and URL-userinfo).
  Adds a metadata-jsonb pass that scrubs values under known sensitive
  keys (`password`, `secret`, `token`, `api_key`, etc.) so a Fact's
  `metadata` map can't smuggle a secret past the binary scrubber by
  putting the value in a structural slot instead of inline text.

  ## Idempotence

  All passes are idempotent — applying redaction twice produces the
  same string. The Fact `:record` action runs this in a `before_action`
  hook; the legacy migrator runs it again on import; both writes
  converge on the same redacted form.
  """

  alias JidoClaw.Security.Redaction.Patterns

  @sensitive_keys ~w(password passwd pwd secret token api_key apikey access_key
                     authorization auth_token bearer credential credentials)

  @doc """
  Redact a Fact's content (binary). Returns the redacted string.

  Raises only on programmer error (a non-binary slipping past the
  resource's `:string` typing). The `!` suffix mirrors the
  `Conversations.Redaction.Transcript.redact/2` shape.
  """
  @spec redact_fact!(String.t()) :: String.t()
  def redact_fact!(content) when is_binary(content), do: Patterns.redact(content)

  @doc """
  Redact arbitrary metadata. Maps recurse; lists map element-wise;
  binaries pass through `Patterns.redact/1`. Values keyed by anything
  in `@sensitive_keys` (case-insensitive) are replaced with
  `[REDACTED:METADATA_VALUE]` regardless of their content shape.
  """
  @spec redact_metadata(term()) :: term()
  def redact_metadata(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} ->
      if sensitive_key?(k) do
        {k, "[REDACTED:METADATA_VALUE]"}
      else
        {k, redact_metadata(v)}
      end
    end)
    |> Map.new()
  end

  def redact_metadata(value) when is_list(value) do
    Enum.map(value, &redact_metadata/1)
  end

  def redact_metadata(value) when is_binary(value), do: Patterns.redact(value)
  def redact_metadata(other), do: other

  defp sensitive_key?(k) when is_atom(k) do
    sensitive_key?(Atom.to_string(k))
  end

  defp sensitive_key?(k) when is_binary(k) do
    lower = String.downcase(k)
    Enum.any?(@sensitive_keys, &String.contains?(lower, &1))
  end

  defp sensitive_key?(_), do: false
end
