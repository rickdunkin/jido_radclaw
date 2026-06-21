defmodule JidoClaw.RouteComposer.Projection do
  @moduledoc """
  Rebuilds composer state from the durable `WorkflowEvent` log (AR-2 Phase 2c).

  Distinct from `JidoClaw.Orchestration.WorkflowEvent.Projection` (which owns the
  parent `WorkflowRun.status`): this folds the composer **delta** kinds back into
  the evolving slice of composer state —

      project(seed_state, events) -> %{seed | live, artifacts, ran, premises, prev_route, wave_index}

  The seed (the full `init/1` state — catalog/tenant/bounds plus the seeded
  `live`/`artifacts`/`premises`) is the **fold base**: the seed artifacts/signals
  are not in the log, so they must already be on `seed_state`. A *fresh* run
  (log = `[run_started]`) projects to the seed unchanged; a *resumed* run projects
  to the seed plus every wave's deltas. One code path — no fresh/resume branch.

  ## Equivalence invariant

  The loop derives each wave's durable content deltas by **diffing** its pre/post
  `JidoClaw.RouteComposer.Fold` state (`route_composer.ex`), so applying
  `union(published) - difference(retracted)` here reproduces `Fold`'s net effect —
  **including paired-verdict last-writer-wins** (`clean:<lens>` ⇄ `findings:<lens>`,
  `fold.ex:58-74`): a flip that retracts a live signal arrives as a
  `signals_retracted` delta. So `project(seed, log)` equals the in-memory `Fold`
  result for any multi-wave run. `available` is **not** part of the rebuilt state —
  the loop derives it each tick via `Fold.available/1`, never folded.

  ## Artifact tagging

  `artifacts_produced` folds `store[name][producer] = {:ref, ref}` — the **tagged**
  shape the live `Fold` store uses (`fold.ex:82-90`), so an inline seed (bare value)
  and a wave-produced ref stay distinguishable at the `ArtifactContext` read boundary.

  ## Key tolerance

  Events reloaded from JSONB carry **string keys**; synthetic-log tests may use
  atom keys. Every payload access tolerates both (atom key wins, else string key).

  ## Folded kinds

  Produced by the 2c loop: `route_composed` (→ `premises` latest-wins + `prev_route`
  snapshot; its `live`/`available` snapshot is legibility only, never folded),
  `wave_completed` (→ `ran ∪ stages`, `wave_index = max(_, idx + 1)`),
  `signals_published`/`signals_retracted` (→ `live` union/difference),
  `artifacts_produced` (→ tagged store insert). Defined + folded now, produced later:
  `artifacts_invalidated` (store delete), `stages_invalidated` (`ran` difference),
  `wave_paused`/`wave_resumed` (gate lifecycle provenance — no routing effect).
  Genesis, terminals, and any non-composer kind fold as no-ops.
  """

  @doc """
  Fold the run's `events` onto `seed_state` in `seq` order, returning the full
  state with the evolving slice (`live`/`artifacts`/`ran`/`premises`/`prev_route`/
  `wave_index`) rebuilt and every static field carried through from the seed.
  """
  @spec project(map(), [map()]) :: map()
  def project(seed_state, events) do
    events
    |> Enum.sort_by(& &1.seq)
    |> Enum.reduce(seed_state, &apply_event/2)
  end

  # `route_composed` is the only kind carrying `premises`/`prev_route`; its
  # `live`/`available` snapshot is legibility only (the published/retracted deltas
  # are the authority), so it is NOT folded into `live`.
  defp apply_event(%{kind: :route_composed, payload: payload}, state) do
    state
    |> put_premises(payload)
    |> Map.put(:prev_route, list_field(payload, :route))
  end

  # The fold-applied marker (appended unconditionally, even for an empty-emission
  # wave). `wave_index` advances to `max(_, idx + 1)` so a benign re-dispatched
  # `wave_completed` is idempotent.
  defp apply_event(%{kind: :wave_completed, payload: payload}, state) do
    stages = list_field(payload, :stages)

    %{
      state
      | ran: MapSet.union(state.ran, MapSet.new(stages)),
        wave_index: advance_wave_index(state.wave_index, int_field(payload, :wave_index))
    }
  end

  defp apply_event(%{kind: :signals_published, payload: payload}, state) do
    %{state | live: MapSet.union(state.live, MapSet.new(list_field(payload, :signals)))}
  end

  defp apply_event(%{kind: :signals_retracted, payload: payload}, state) do
    %{state | live: MapSet.difference(state.live, MapSet.new(list_field(payload, :signals)))}
  end

  defp apply_event(%{kind: :artifacts_produced, payload: payload}, state) do
    store = Enum.reduce(artifact_entries(payload), state.artifacts, &produce_artifact/2)
    %{state | artifacts: store}
  end

  defp apply_event(%{kind: :artifacts_invalidated, payload: payload}, state) do
    store = Enum.reduce(artifact_entries(payload), state.artifacts, &invalidate_artifact/2)
    %{state | artifacts: store}
  end

  defp apply_event(%{kind: :stages_invalidated, payload: payload}, state) do
    %{state | ran: MapSet.difference(state.ran, MapSet.new(list_field(payload, :stages)))}
  end

  # Gate lifecycle markers (Phase 4 producers): provenance only — no routing
  # effect, so they fold as no-ops.
  defp apply_event(%{kind: :wave_paused}, state), do: state
  defp apply_event(%{kind: :wave_resumed}, state), do: state

  # Genesis (`run_started`), parent terminals, and any non-composer kind have no
  # composer-state effect.
  defp apply_event(_event, state), do: state

  # ---------------------------------------------------------------------------
  # Field folds
  # ---------------------------------------------------------------------------

  # Latest-wins. Only set when the event actually carries premises (a missing key
  # keeps the seed); for a future premises producer the value round-trips through
  # the JSON-safe boundary (string keys), so seed it string-keyed to stay equal.
  defp put_premises(state, payload) do
    case get(payload, :premises) do
      nil -> state
      premises -> %{state | premises: premises}
    end
  end

  # `max(current, idx + 1)` = completed-wave count, idempotent under a benign
  # re-dispatch; a missing index falls back to a plain count bump.
  defp advance_wave_index(current, idx) when is_integer(idx), do: max(current, idx + 1)
  defp advance_wave_index(current, _idx), do: current + 1

  defp produce_artifact(entry, store) do
    name = get(entry, :name)
    producer = get(entry, :producer)
    ref = get(entry, :ref)

    if is_binary(name) and is_binary(producer) do
      Map.update(store, name, %{producer => {:ref, ref}}, &Map.put(&1, producer, {:ref, ref}))
    else
      store
    end
  end

  # Delete `store[name][producer]`, pruning a now-empty name map so `available`
  # (which excludes empty producer maps) stays correct.
  defp invalidate_artifact(entry, store) do
    name = get(entry, :name)
    producer = get(entry, :producer)

    case Map.get(store, name) do
      nil ->
        store

      producers ->
        pruned = Map.delete(producers, producer)
        if map_size(pruned) == 0, do: Map.delete(store, name), else: Map.put(store, name, pruned)
    end
  end

  defp artifact_entries(payload) do
    case get(payload, :artifacts) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Tolerant payload access (atom key wins, else string key, else default)
  # ---------------------------------------------------------------------------

  defp list_field(payload, key) do
    case get(payload, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp int_field(payload, key) do
    case get(payload, key) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp get(_map, _key), do: nil
end
