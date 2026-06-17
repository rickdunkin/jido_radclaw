defmodule JidoClaw.Trace.Sanitize do
  @moduledoc """
  Thin facade over `JidoClaw.Trace.Policy` for sanitizing trace payloads.

  Redaction policy (which keys are omitted/redacted, embedded-value
  scrubbing, sampling) now lives in `JidoClaw.Trace.Policy`, which reuses
  the central `JidoClaw.Security.Redaction.{Env,Patterns}` stack. This
  module keeps the historical `payload/1` / `preview/2` entry points so
  existing callers stay source-compatible:

    * `payload/1` scrubs with `Policy.default/0`;
    * `payload/2` scrubs with a caller-supplied policy (the Collector
      threads its snapshotted policy through here);
    * `preview/2` produces a bounded, redacted, serialization-safe preview.

  See `JidoClaw.Trace.Policy` for the full redaction + sampling contract.
  """

  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Trace.Policy

  @default_preview_bytes 500

  @doc """
  Scrubs a payload with the default policy.

  Equivalent to `payload(Policy.default(), value)`.
  """
  @spec payload(term()) :: term()
  def payload(value), do: Policy.scrub(Policy.default(), value)

  @doc """
  Scrubs a payload with a caller-supplied policy.
  """
  @spec payload(Policy.t(), term()) :: term()
  def payload(%Policy{} = policy, value), do: Policy.scrub(policy, value)

  @doc """
  Produces a bounded printable preview of an arbitrary value.

  Strings are redacted (catching embedded secrets), made serialization-safe
  if still invalid UTF-8, then sliced. Other values are scrubbed with the
  default policy then inspected with a capped `printable_limit` so even
  pathological payloads stay bounded.
  """
  @spec preview(term(), pos_integer()) :: String.t()
  def preview(value, bytes \\ @default_preview_bytes)

  def preview(value, bytes) when is_binary(value) and is_integer(bytes) and bytes > 0 do
    redacted = Patterns.redact(value)
    safe = if String.valid?(redacted), do: redacted, else: inspect(redacted)
    String.slice(safe, 0, bytes)
  end

  def preview(value, bytes) when is_integer(bytes) and bytes > 0 do
    value
    |> payload()
    |> inspect(limit: 20, printable_limit: bytes)
    |> String.slice(0, bytes)
  end
end
