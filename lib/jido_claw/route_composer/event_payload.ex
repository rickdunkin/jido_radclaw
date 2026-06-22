defmodule JidoClaw.RouteComposer.EventPayload do
  @moduledoc """
  Tolerant accessors over a composer `WorkflowEvent` payload, shared by
  `JidoClaw.RouteComposer.Projection` (the seed-folding rebuild) and
  `JidoClaw.RouteComposer.Observe` (the seed-free observe summary).

  Events reloaded from JSONB carry **string keys**; synthetic-log tests may use
  atom keys. Every accessor tolerates both — the atom key wins, else the string
  key, else the default — so a folder/summarizer reads one shape regardless of
  whether the event came from the DB or a synthetic log.
  """

  @doc """
  Fetch `key` from a payload, tolerating atom-or-string keys (atom wins, else
  string). Returns `nil` for a missing key or a non-map payload.
  """
  @spec get(term(), atom()) :: term()
  def get(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  def get(_map, _key), do: nil

  @doc "Fetch `key` as a list, falling back to `[]` when absent or not a list."
  @spec list(term(), atom()) :: list()
  def list(payload, key) do
    case get(payload, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Fetch `key` as an integer, falling back to `nil` when absent or not an integer."
  @spec int(term(), atom()) :: integer() | nil
  def int(payload, key) do
    case get(payload, key) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end
end
