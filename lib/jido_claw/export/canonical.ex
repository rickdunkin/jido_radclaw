defmodule JidoClaw.Export.Canonical do
  @moduledoc """
  Canonical JSON encoder for round-trippable exports.

  Round-trip acceptance tests assert that `import → export → re-import →
  re-export` produces byte-identical output. That requires deterministic
  serialization:

    * Object keys sorted lexicographically (recursively).
    * Datetimes formatted as ISO8601 with fixed microsecond precision.
    * No pretty-printing (single line per record).
    * Caller is responsible for emitting rows in deterministic order
      (typically primary-key ASC).
  """

  @doc """
  Canonicalize a value (map / list / scalar) for deterministic JSON.

  Datetimes are coerced to ISO8601 strings with microsecond precision so
  the encoder doesn't depend on Jason's struct fallback (which is
  consistent but couples behavior to library version). Anything that is
  already JSON-friendly passes through.
  """
  @spec canonicalize(any()) :: any()
  def canonicalize(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  def canonicalize(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:microsecond)
    |> NaiveDateTime.to_iso8601()
  end

  def canonicalize(%Date{} = d), do: Date.to_iso8601(d)
  def canonicalize(%Time{} = t), do: Time.to_iso8601(t)

  def canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  def canonicalize(value) when is_list(value),
    do: Enum.map(value, &canonicalize/1)

  def canonicalize(value), do: value

  @doc """
  Encode a value as a canonical JSON string. Sorted keys, no
  pretty-printing.
  """
  @spec encode!(any()) :: String.t()
  def encode!(value) do
    value
    |> canonicalize()
    |> sorted_encode!()
    |> IO.iodata_to_binary()
  end

  defp sorted_encode!(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [Jason.encode!(to_string(k)), ":", sorted_encode!(v)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp sorted_encode!(value) when is_list(value) do
    inner =
      value
      |> Enum.map(&sorted_encode!/1)
      |> Enum.intersperse(",")

    ["[", inner, "]"]
  end

  defp sorted_encode!(value), do: Jason.encode!(value)

  @doc """
  Emit `records` (already in deterministic order) as JSONL. Each
  record is serialized via `encode!/1` and terminated with a newline.
  """
  @spec to_jsonl([any()]) :: String.t()
  def to_jsonl(records) when is_list(records) do
    Enum.map_join(records, fn r -> encode!(r) <> "\n" end)
  end
end
