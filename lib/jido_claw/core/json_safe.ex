defmodule JidoClaw.Core.JsonSafe do
  @moduledoc """
  Recursively normalize a term into a JSON-safe shape for MCP output.

  This is the shared normalizer consumed by `JidoClaw.AgentView.to_mcp_map/1`
  and `JidoClaw.Tools.InspectAgent` so both surfaces stringify the same way.

  The transformation is **total**: every term maps to something
  `Jason.encode/1` accepts, so callers never have to pre-sanitize input.

    * `nil`, booleans, numbers, and binaries pass through unchanged,
    * atoms (besides `nil` / booleans) become strings; module (`Elixir.*`)
      atoms become `nil`,
    * `DateTime` / `NaiveDateTime` / `Date` become ISO-8601 strings,
    * `MapSet` becomes a list,
    * other structs are converted to plain maps and walked,
    * lists and tuples are recursively encoded element-by-element (a tuple
      becomes a list, so e.g. `{:ok, 1}` → `["ok", 1]`),
    * map keys are stringified — binaries pass through, atoms via
      `Atom.to_string/1`, and any other key (integer, tuple, …) via
      `inspect/1`, so every key is a valid JSON object key,
    * pids / refs / functions / ports are not JSON-encodable: as a map value
      the entry is dropped entirely; anywhere else (list element, top-level
      term, nested leaf) they become `nil`,
    * anything left (e.g. a non-binary bitstring) is rendered with `inspect/1`.
  """

  @doc """
  Recursively encode `term` into a JSON-safe value. See the moduledoc for
  the full transformation rules.
  """
  @spec encode(term()) :: term()
  def encode(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  def encode(value) when is_struct(value, NaiveDateTime), do: NaiveDateTime.to_iso8601(value)
  def encode(value) when is_struct(value, Date), do: Date.to_iso8601(value)

  def encode(%MapSet{} = set) do
    set
    |> MapSet.to_list()
    |> Enum.map(&encode/1)
  end

  def encode(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> encode()
  end

  def encode(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      cond do
        is_pid(v) or is_reference(v) or is_function(v) or is_port(v) ->
          acc

        is_atom(v) and not is_nil(v) and not is_boolean(v) and module?(v) ->
          acc

        true ->
          Map.put(acc, encode_key(k), encode(v))
      end
    end)
  end

  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)

  # Tuples have no JSON representation; encode them as lists so keyword lists,
  # `{:ok, _}` / `{:error, _}` shapes, etc. don't leak un-encodable terms.
  def encode(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&encode/1)
  end

  def encode(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    if module?(atom), do: nil, else: Atom.to_string(atom)
  end

  # Runtime types are not JSON-encodable. The map reducer above drops them
  # entirely when they're a map value; this leaf clause catches every other
  # position (list element, top-level term, nested leaf) and yields `nil` —
  # parallel to how a module atom becomes `nil` outside a map value.
  def encode(value)
      when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
      do: nil

  # JSON leaves pass through unchanged.
  def encode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: value

  # Total fallback: anything left (e.g. a non-binary bitstring) is rendered to
  # a string so encode/1 never emits a term `Jason.encode/1` would reject.
  def encode(value), do: inspect(value)

  defp encode_key(k) when is_binary(k), do: k
  defp encode_key(k) when is_atom(k), do: Atom.to_string(k)
  defp encode_key(k), do: inspect(k)

  defp module?(atom) when is_atom(atom) do
    match?("Elixir." <> _, Atom.to_string(atom))
  end
end
