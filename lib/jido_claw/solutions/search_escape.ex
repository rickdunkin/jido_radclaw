defmodule JidoClaw.Solutions.SearchEscape do
  @moduledoc """
  Escaping helpers for the hybrid retrieval `:search` action.

  Two functions, two distinct query parameters in the underlying SQL
  (per `docs/plans/v0.6/phase-1-solutions.md` §1.5):

    * `escape_like/1` — escapes `%` and `_` and `\\` so a literal
      query string can be safely interpolated as a `LIKE` pattern.
      The SQL uses `LIKE '%' || $10 || '%' ESCAPE '\\'`.

    * `lower_only/1` — `String.downcase/1`, NO escape. Drives
      `similarity(lexical_text, $12)`. The split exists because
      `similarity('100\\%', '100%')` ranks LOWER than
      `similarity('100\\%', '100ish')` thanks to the literal escape
      char in the query — the lexical-pool LIKE filter wants the
      escape, the similarity-rank scorer does not.
  """

  @doc "Escape `%`, `_`, and `\\` so the result can be embedded in a LIKE pattern."
  @spec escape_like(String.t()) :: String.t()
  def escape_like(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc "Lowercase only. Used as a separate parameter for `similarity(...)`."
  @spec lower_only(String.t()) :: String.t()
  def lower_only(text) when is_binary(text), do: String.downcase(text)
end
