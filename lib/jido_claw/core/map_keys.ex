defmodule JidoClaw.Core.MapKeys do
  @moduledoc """
  Shared helpers for reading and normalizing maps whose keys may be either
  atoms or strings.

  Two read helpers expose explicitly different fallback semantics:

    * `field/3` — fetch-default semantics. Returns the value at the
      preferred key (even if it is `nil`/`false`), and only falls back
      to the counterpart key when the preferred key is **absent**.
    * `coalesce_field/3` — `||` semantics. Treats `nil`/`false` at the
      preferred key as "absent" and falls through to the counterpart
      key shape.

  Use the helper that matches the original code's semantics. When
  porting a `Map.get(map, :k, Map.get(map, "k"))` site, pick `field/3`;
  for `Map.get(map, :k) || Map.get(map, "k")` sites, pick
  `coalesce_field/3`. The two helpers diverge on the `nil`/`false`
  rows — folding both into one would silently change behavior.

  `normalize_keys/2` provides boundary normalization for cases where
  the inbound shape is unknown but should be made canonical before
  downstream code reads it. It is **struct-safe**: structs always pass
  through unchanged, so DateTime/NaiveDateTime values embedded in
  payloads survive the round trip.

  Never call `String.to_atom/1` on user input. The `:atom_existing`
  normalization mode wraps `String.to_existing_atom/1` and exposes an
  optional `drop_unknown: true` to silently drop strings whose atom
  counterpart does not yet exist (matches the legacy
  `Solutions.NetworkFacade.normalize_keys/1` contract).
  """

  @doc """
  Fetch a value by the preferred key (atom or binary), falling back to
  the counterpart key shape only if the preferred key is absent.
  Returns `default` if neither key is present, or for non-map input.

  Matches `Map.get/3` fetch-default semantics: a present-but-`nil`
  (or `false`) value at the preferred key is returned as-is, with no
  fallback to the counterpart.
  """
  @spec field(term, atom | binary, term) :: term
  def field(map, preferred_key, default \\ nil)

  def field(map, atom_key, default) when is_map(map) and is_atom(atom_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(atom_key), default)
    end
  end

  def field(map, string_key, default) when is_map(map) and is_binary(string_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> field_atom_fallback(map, string_key, default)
    end
  end

  def field(_, _, default), do: default

  defp field_atom_fallback(map, string_key, default) do
    case safe_existing_atom(string_key) do
      {:ok, atom_key} -> Map.get(map, atom_key, default)
      :error -> default
    end
  end

  @doc """
  Fetch a value by the preferred key (atom or binary), treating `nil`
  and `false` as "absent" and falling through to the counterpart key
  shape. Matches the `Map.get(map, k1) || Map.get(map, k2)` pattern.
  """
  @spec coalesce_field(term, atom | binary, term) :: term
  def coalesce_field(map, preferred_key, default \\ nil)

  def coalesce_field(map, atom_key, default) when is_map(map) and is_atom(atom_key) do
    Map.get(map, atom_key) || Map.get(map, Atom.to_string(atom_key)) || default
  end

  def coalesce_field(map, string_key, default) when is_map(map) and is_binary(string_key) do
    Map.get(map, string_key) || coalesce_atom_fallback(map, string_key) || default
  end

  def coalesce_field(_, _, default), do: default

  defp coalesce_atom_fallback(map, string_key) do
    case safe_existing_atom(string_key) do
      {:ok, atom_key} -> Map.get(map, atom_key)
      :error -> nil
    end
  end

  @doc """
  Normalize map keys to a canonical shape.

  Modes:

    * `:string` — convert atom keys to strings. Already-string keys
      pass through unchanged.
    * `:atom_existing` — convert string keys to atoms via
      `String.to_existing_atom/1`. Already-atom keys pass through
      unchanged. When an inbound string has no existing atom
      counterpart, the entry is retained as a string key unless
      `:drop_unknown` is `true`, in which case it is dropped silently.

  Options:

    * `:deep` (default `false`) — recurse into nested maps and lists.
      Structs ALWAYS pass through unchanged regardless of this flag.
    * `:drop_unknown` (default `false`, `:atom_existing` only) — drop
      string keys whose atom counterpart does not yet exist.

  ## Collision precedence

  When the input map contains both `:key` and `"key"` for the same
  name, the canonical shape for the chosen mode wins: `:atom_existing`
  keeps the atom-keyed value; `:string` keeps the string-keyed value.
  Precedence is deterministic and applies recursively when `:deep` is
  true.

  Public API is map-only (non-struct map). Top-level lists are not
  accepted; wrap with `Enum.map(list, &normalize_keys(&1, mode, opts))`
  at the call site.
  """
  @spec normalize_keys(map, :string | :atom_existing, keyword) :: map
  def normalize_keys(map, mode, opts \\ [])

  def normalize_keys(map, mode, opts) when is_map(map) and not is_struct(map) do
    deep? = Keyword.get(opts, :deep, false)
    drop_unknown? = Keyword.get(opts, :drop_unknown, false)
    do_normalize_map(map, mode, deep?, drop_unknown?)
  end

  defp do_normalize_map(map, mode, deep?, drop_unknown?) do
    map
    |> ordered_entries(mode)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case convert_key(k, mode, drop_unknown?) do
        {:ok, new_key} ->
          Map.put(acc, new_key, maybe_walk(v, mode, deep?, drop_unknown?))

        :drop ->
          acc
      end
    end)
  end

  # :atom_existing — process strings first so genuine atom entries
  #   overwrite their string counterparts (atom-first precedence).
  # :string — process atoms first so genuine string entries overwrite
  #   their atom counterparts (string-first precedence).
  defp ordered_entries(map, :atom_existing) do
    {atoms, others} = Enum.split_with(map, fn {k, _} -> is_atom(k) end)
    others ++ atoms
  end

  defp ordered_entries(map, :string) do
    {atoms, others} = Enum.split_with(map, fn {k, _} -> is_atom(k) end)
    atoms ++ others
  end

  defp convert_key(k, :string, _drop) when is_atom(k), do: {:ok, Atom.to_string(k)}
  defp convert_key(k, :string, _drop) when is_binary(k), do: {:ok, k}
  defp convert_key(k, :string, _drop), do: {:ok, k}

  defp convert_key(k, :atom_existing, _drop) when is_atom(k), do: {:ok, k}

  defp convert_key(k, :atom_existing, drop) when is_binary(k) do
    case safe_existing_atom(k) do
      {:ok, atom} -> {:ok, atom}
      :error -> if drop, do: :drop, else: {:ok, k}
    end
  end

  defp convert_key(k, :atom_existing, _drop), do: {:ok, k}

  defp maybe_walk(value, _mode, false, _drop), do: value
  defp maybe_walk(%_struct{} = value, _mode, true, _drop), do: value

  defp maybe_walk(value, mode, true, drop) when is_map(value) do
    do_normalize_map(value, mode, true, drop)
  end

  defp maybe_walk(value, mode, true, drop) when is_list(value) do
    Enum.map(value, fn
      %_struct{} = element -> element
      element when is_map(element) -> do_normalize_map(element, mode, true, drop)
      element when is_list(element) -> maybe_walk(element, mode, true, drop)
      element -> element
    end)
  end

  defp maybe_walk(value, _mode, true, _drop), do: value

  @doc """
  Wrap `String.to_existing_atom/1` in a result tuple. Returns
  `{:ok, atom}` if the atom already exists, `:error` otherwise. Never
  calls `String.to_atom/1` on user input.
  """
  @spec safe_existing_atom(binary) :: {:ok, atom} | :error
  def safe_existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
