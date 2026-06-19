defmodule JidoClaw.RouteComposer.Fold do
  @moduledoc """
  Folds a wave's emissions back into composer state (AR-2 §4/§7).

  Synchronous and deterministic — no async race. `fold/2` takes the composer
  state (a map carrying at least `:live`, `:artifacts`, `:ran`) and the wave's
  `%JidoClaw.RouteComposer.StageEmission{}` list and returns the next state:

    * **signals** union into `live`, with **paired-verdict last-writer-wins** —
      folding `clean:<lens>` retracts any live `findings:<lens>` and vice-versa,
      so a re-reviewed lens that flips clears the stale signal and convergence
      stays reachable (the §7 mutual-exclusion invariant);
    * **artifacts** index into the provenance store as `store[name][producer] =
      value`, so co-producers of one `name` (AR-3's per-lens `findings`) coexist
      without clobbering;
    * **stage names** union into `ran`.

  The routing set `available` is **derived** from the store (`available/1`), not
  folded independently — a `name` is available iff the store holds at least one
  producer entry for it.
  """

  alias JidoClaw.RouteComposer.StageEmission

  @type store :: %{optional(String.t()) => %{optional(String.t()) => term()}}

  @doc """
  Fold the wave's emissions into `state`, returning the updated state. Folds each
  emission in order (signals → artifacts → ran).
  """
  @spec fold(map(), [StageEmission.t()]) :: map()
  def fold(state, emissions) do
    Enum.reduce(emissions, state, &fold_one/2)
  end

  @doc """
  Derive the routing `available` set from the provenance store: a `name` with at
  least one producer entry.
  """
  @spec available(store()) :: MapSet.t(String.t())
  def available(store) do
    for {name, producers} <- store, map_size(producers) > 0, into: MapSet.new(), do: name
  end

  defp fold_one(%StageEmission{} = emission, state) do
    state
    |> fold_signals(emission.signals)
    |> fold_artifacts(emission.stage, emission.artifacts)
    |> fold_ran(emission.stage)
  end

  defp fold_signals(state, signals) do
    %{state | live: Enum.reduce(signals, state.live, &add_signal/2)}
  end

  # Add the signal and retract its paired verdict (clean ↔ findings) for the
  # same lens — the two are mutually exclusive in `live`.
  defp add_signal(signal, live) do
    case paired_verdict(signal) do
      nil ->
        MapSet.put(live, signal)

      paired ->
        live
        |> MapSet.delete(paired)
        |> MapSet.put(signal)
    end
  end

  defp paired_verdict("clean:" <> lens), do: "findings:" <> lens
  defp paired_verdict("findings:" <> lens), do: "clean:" <> lens
  defp paired_verdict(_signal), do: nil

  defp fold_artifacts(state, producer, artifacts) do
    store =
      Enum.reduce(artifacts, state.artifacts, fn {name, value}, acc ->
        Map.update(acc, name, %{producer => value}, &Map.put(&1, producer, value))
      end)

    %{state | artifacts: store}
  end

  defp fold_ran(state, stage), do: %{state | ran: MapSet.put(state.ran, stage)}
end
