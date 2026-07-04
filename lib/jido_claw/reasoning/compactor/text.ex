defmodule JidoClaw.Reasoning.Compactor.Text do
  @moduledoc """
  Byte-safe text truncation helpers shared across the compaction pipeline.

  The compactor persists snapshots as JSONB (via `Storage.persist`), so any
  truncation that cuts a binary at a raw byte offset can split a multibyte
  UTF-8 codepoint and produce invalid UTF-8 — which then fails Jason/Postgrex
  encoding and silently drops the (best-effort) compaction. Every byte-bounded
  cut in the pipeline routes through `utf8_safe_prefix/2` so the result is
  always valid UTF-8.
  """

  @doc """
  Return the longest valid-UTF-8 prefix of `text` whose byte size does not
  exceed `max_bytes`.

  The budget is a **byte** budget (not a character/codepoint count): the
  returned binary is `min(max_bytes, byte_size(text))` bytes or fewer, backing
  off one byte at a time until the prefix is valid UTF-8.
  """
  @spec utf8_safe_prefix(binary(), integer()) :: binary()
  def utf8_safe_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    bounded = min(max_bytes, byte_size(text))
    do_utf8_safe_prefix(text, bounded)
  end

  defp do_utf8_safe_prefix(_text, n) when n <= 0, do: ""

  defp do_utf8_safe_prefix(text, n) do
    candidate = binary_part(text, 0, n)

    if String.valid?(candidate) do
      candidate
    else
      do_utf8_safe_prefix(text, n - 1)
    end
  end
end
