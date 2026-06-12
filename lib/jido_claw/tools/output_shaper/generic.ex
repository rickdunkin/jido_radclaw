defmodule JidoClaw.Tools.OutputShaper.Generic do
  @moduledoc """
  Format-agnostic head+tail compression for tool output the
  `JidoClaw.Tools.OutputShaper` could not parse.

  Keeps the first `head_bytes` and last `tail_bytes` of the text with an
  elision marker between them. Strictly better than a blind head-only
  cut for build/test logs: errors and summaries live at the tail. The
  marker is deliberately **ref-free** — the shaper appends the
  `fetch_output` footer after storage resolves, so this module never has
  to know whether a ref exists.
  """

  alias JidoClaw.Tools.OutputLimit

  # Reserved for the elision marker when sizing `fit/2` cuts. The marker
  # is ~31 bytes plus the elided-count digits (~45 bytes even for absurd
  # counts), so head + tail + marker can never overshoot the budget.
  @marker_allowance 64

  @doc """
  Fit `text` within `budget_bytes`, elision marker included.

  Returns `:nocompress` when the text already fits, otherwise
  `{:ok, body}` with `byte_size(body) <= budget_bytes` — a hard
  contract the shaper relies on to keep `OutputLimit` from ever
  cutting a shaped body (and the ref footer after it).

  The usable budget splits tail-weighted (1:2, same ratio as the 2KB/4KB
  generic defaults) because errors and summaries live at the tail.
  Degenerate budgets — too small to hold content plus the marker —
  floor to a UTF-8-safe suffix of the text, no marker, for the same
  reason: the tail is never sacrificed to an end trim.
  """
  @spec fit(binary(), non_neg_integer()) :: {:ok, String.t()} | :nocompress
  def fit(text, budget_bytes) when is_binary(text) and byte_size(text) <= budget_bytes do
    :nocompress
  end

  def fit(text, budget_bytes) when is_binary(text) and budget_bytes <= @marker_allowance do
    suffix =
      text
      |> binary_part(byte_size(text) - budget_bytes, budget_bytes)
      |> valid_utf8_suffix()

    {:ok, suffix}
  end

  def fit(text, budget_bytes) when is_binary(text) do
    usable = budget_bytes - @marker_allowance
    head = div(usable, 3)

    head_tail(text, head, usable - head)
  end

  @doc """
  Compress `text` to `head_bytes` + elision marker + `tail_bytes`.

  Returns `{:ok, body}` or `:nocompress` when the text already fits the
  combined budget (caller passes the original through). Both cuts are
  UTF-8 safe.
  """
  @spec head_tail(binary(), pos_integer(), pos_integer()) :: {:ok, String.t()} | :nocompress
  def head_tail(text, head_bytes, tail_bytes) when is_binary(text) do
    if byte_size(text) <= head_bytes + tail_bytes do
      :nocompress
    else
      head =
        text
        |> binary_part(0, head_bytes)
        |> OutputLimit.valid_utf8_prefix()

      tail =
        text
        |> binary_part(byte_size(text) - tail_bytes, tail_bytes)
        |> valid_utf8_suffix()

      elided = byte_size(text) - byte_size(head) - byte_size(tail)

      {:ok, head <> "\n\n... [elided #{elided} bytes] ...\n\n" <> tail}
    end
  end

  @doc false
  @spec valid_utf8_suffix(binary()) :: binary()
  def valid_utf8_suffix(value) do
    if String.valid?(value) do
      value
    else
      trim_to_valid_utf8(value, 0)
    end
  end

  # Drop leading bytes (a tail cut can land mid-codepoint, leaving
  # continuation bytes at the front) until the remainder is valid UTF-8.
  # Mirrors `OutputLimit.valid_utf8_prefix/1`'s full-trim behavior for
  # pathological all-invalid input (returns "").
  defp trim_to_valid_utf8(value, offset) when offset >= byte_size(value), do: ""

  defp trim_to_valid_utf8(value, offset) do
    candidate = binary_part(value, offset, byte_size(value) - offset)

    if String.valid?(candidate) do
      candidate
    else
      trim_to_valid_utf8(value, offset + 1)
    end
  end
end
