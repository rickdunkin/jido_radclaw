defmodule JidoClaw.RouteComposer.ArtifactContext do
  @moduledoc """
  Formats the cross-wave artifact store into the single `:extra_context` string
  a wave reactor receives (AR-2 §5).

  Per-wave reactors are separate, so the in-reactor `StepResult` edges
  `JidoClaw.Workflows.ContextBuilder` wires don't span waves. The composer
  instead serializes the artifacts each wave's stages name in their `input`
  (required ∪ optional, across producers) out of the **provenance-keyed** store
  (`name → %{producer => value}`) into one markdown block.

  Missing optionals are simply absent; a missing *required* input is the
  router's drop decision, not the formatter's. Each rendered value is truncated
  to a per-value byte cap (elision marked) and the whole string to a total cap —
  even for the spike, unbounded artifact text into `:extra_context` is a spend
  and debuggability hazard. Names and producers are sorted so the string is
  deterministic.
  """

  alias JidoClaw.RouteComposer.Stage

  @per_value_cap 4_000
  @total_cap 16_000
  @elision "…[truncated]"

  @type store :: %{optional(String.t()) => %{optional(String.t()) => term()}}

  @doc """
  Build the `:extra_context` string for `stages` from the provenance `store`.

  Collects every artifact named in the stages' `input` (required ∪ optional),
  renders each present artifact's `producer → value` entries, and joins them.
  Returns `""` when none of the wanted artifacts are present.
  """
  @spec build([Stage.t()], store()) :: String.t()
  def build(stages, store) do
    stages
    |> wanted_names()
    |> Enum.sort()
    |> Enum.flat_map(fn name -> section(name, Map.get(store, name)) end)
    |> Enum.join("\n\n")
    |> cap(@total_cap)
  end

  defp wanted_names(stages) do
    Enum.reduce(stages, MapSet.new(), fn %Stage{input: input}, acc ->
      acc
      |> MapSet.union(MapSet.new(input.required))
      |> MapSet.union(MapSet.new(input.optional))
    end)
  end

  defp section(_name, nil), do: []
  defp section(_name, producers) when map_size(producers) == 0, do: []

  defp section(name, producers) do
    entries =
      producers
      |> Enum.sort_by(fn {producer, _value} -> producer end)
      |> Enum.map_join("\n", fn {producer, value} ->
        "- **#{producer}**: #{cap(to_text(value), @per_value_cap)}"
      end)

    ["### #{name}\n#{entries}"]
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value)

  defp cap(text, limit) when byte_size(text) <= limit, do: text
  defp cap(text, limit), do: byte_truncate(text, limit) <> @elision

  # Byte-bounded but UTF-8-safe: take `limit` bytes, then drop any dangling
  # partial codepoint (at most 3 bytes) so the result is always a valid string.
  defp byte_truncate(text, limit) do
    part = binary_part(text, 0, limit)
    if String.valid?(part), do: part, else: byte_truncate(text, limit - 1)
  end
end
