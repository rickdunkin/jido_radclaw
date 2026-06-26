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

  Produced by the loop: `route_composed` (→ `premises` latest-wins + `prev_route`
  snapshot; its `live`/`available` snapshot is legibility only, never folded),
  `wave_completed` (→ `ran ∪ stages`, `wave_index = max(_, idx + 1)`),
  `signals_published`/`signals_retracted` (→ `live` union/difference),
  `artifacts_produced` (→ tagged store insert), `artifacts_invalidated` (→ store
  delete), `wave_paused`/`wave_resumed` (gate lifecycle provenance — no routing
  effect), and `stages_invalidated` (Phase 4e rerun primitive → `ran` difference,
  an optional `closed_wave_index` advance, + a per-stage `rerun_counts` increment).
  Genesis, terminals, and any non-composer kind fold as no-ops.

  ## Tolerant payload access

  Atom-vs-string key tolerance lives in `JidoClaw.RouteComposer.EventPayload`
  (`get/2`, `list/2`, `int/2`), shared with `JidoClaw.RouteComposer.Observe`.
  """

  alias JidoClaw.RouteComposer.EventPayload

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

  @doc """
  Fold an ordered `[{kind, payload}]` marker batch into composer state in-memory,
  reusing the SAME per-event logic `project/2` applies (AR-4).

  The AR-4 self-heal hooks weld their rerun markers (`stages_invalidated` /
  `artifacts_produced` / `artifacts_invalidated`) into the wave commit and must
  mirror them in memory on `:ok`. Routing that mirror through this — the
  projection's own fold — makes `project(seed, log) == in-memory` hold **by
  construction**: the in-memory mutation can never drift from what a later
  `project/2` over the same durable markers produces. `payload`s are atom-keyed
  in-memory and `apply_event` tolerates both (`EventPayload`), so a live mirror
  and a JSONB-reloaded fold agree.
  """
  @spec apply_markers(map(), [{atom(), map()}]) :: map()
  def apply_markers(state, markers) do
    Enum.reduce(markers, state, fn {kind, payload}, acc ->
      apply_event(%{kind: kind, payload: payload}, acc)
    end)
  end

  # `route_composed` is the only kind carrying `premises`/`prev_route`; its
  # `live`/`available` snapshot is legibility only (the published/retracted deltas
  # are the authority), so it is NOT folded into `live`.
  defp apply_event(%{kind: :route_composed, payload: payload}, state) do
    state
    |> put_premises(payload)
    |> Map.put(:prev_route, EventPayload.list(payload, :route))
  end

  # The fold-applied marker (appended unconditionally, even for an empty-emission
  # wave). `wave_index` advances to `max(_, idx + 1)` so a benign re-dispatched
  # `wave_completed` is idempotent.
  defp apply_event(%{kind: :wave_completed, payload: payload}, state) do
    stages = EventPayload.list(payload, :stages)

    %{
      state
      | ran: MapSet.union(state.ran, MapSet.new(stages)),
        wave_index: advance_wave_index(state.wave_index, EventPayload.int(payload, :wave_index))
    }
  end

  defp apply_event(%{kind: :signals_published, payload: payload}, state) do
    %{state | live: MapSet.union(state.live, MapSet.new(EventPayload.list(payload, :signals)))}
  end

  defp apply_event(%{kind: :signals_retracted, payload: payload}, state) do
    %{
      state
      | live: MapSet.difference(state.live, MapSet.new(EventPayload.list(payload, :signals)))
    }
  end

  defp apply_event(%{kind: :artifacts_produced, payload: payload}, state) do
    store = Enum.reduce(artifact_entries(payload), state.artifacts, &produce_artifact/2)
    %{state | artifacts: store}
  end

  defp apply_event(%{kind: :artifacts_invalidated, payload: payload}, state) do
    store = Enum.reduce(artifact_entries(payload), state.artifacts, &invalidate_artifact/2)
    %{state | artifacts: store}
  end

  # Subtractive `ran` delta (Phase 4e rerun primitive). Two extras:
  #   * the OPTIONAL `closed_wave_index` advances `wave_index = max(_, idx + 1)`
  #     — set ONLY by the reject-parked-gate path (closing a never-completed gate
  #     wave so the re-fire gets a FRESH launch key); a generic completed-wave
  #     rerun omits it (its `wave_completed` already advanced the index, so
  #     re-advancing would skip a key + burn the `max_waves` budget);
  #   * `rerun_counts` increments per invalidated stage — the per-stage rerun cap
  #     the loop's `over_budget?` reads (rebuilt here so the cap survives a crash).
  defp apply_event(%{kind: :stages_invalidated, payload: payload}, state) do
    stages = EventPayload.list(payload, :stages)

    # `ran`/`wave_index` always exist on the seed (the `|` update); `rerun_counts`
    # is added tolerantly (a synthetic-log test seed may omit it).
    base = %{
      state
      | ran: MapSet.difference(state.ran, MapSet.new(stages)),
        wave_index: advance_on_invalidation(state.wave_index, payload)
    }

    Map.update(
      base,
      :rerun_counts,
      bump_rerun_counts(%{}, stages),
      &bump_rerun_counts(&1, stages)
    )
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
    case EventPayload.get(payload, :premises) do
      nil -> state
      premises -> %{state | premises: premises}
    end
  end

  # `max(current, idx + 1)` = completed-wave count, idempotent under a benign
  # re-dispatch; a missing index falls back to a plain count bump.
  defp advance_wave_index(current, idx) when is_integer(idx), do: max(current, idx + 1)
  defp advance_wave_index(current, _idx), do: current + 1

  # `stages_invalidated` advances `wave_index` ONLY when it carries the optional
  # `closed_wave_index` (the reject-parked-gate path); otherwise the index is
  # untouched (a generic completed-wave rerun).
  defp advance_on_invalidation(current, payload) do
    case EventPayload.int(payload, :closed_wave_index) do
      idx when is_integer(idx) -> max(current, idx + 1)
      _absent -> current
    end
  end

  defp bump_rerun_counts(counts, stages) do
    Enum.reduce(stages, counts, fn stage, acc -> Map.update(acc, stage, 1, &(&1 + 1)) end)
  end

  defp produce_artifact(entry, store) do
    name = EventPayload.get(entry, :name)
    producer = EventPayload.get(entry, :producer)
    ref = EventPayload.get(entry, :ref)

    if is_binary(name) and is_binary(producer) do
      Map.update(store, name, %{producer => {:ref, ref}}, &Map.put(&1, producer, {:ref, ref}))
    else
      store
    end
  end

  # Delete `store[name][producer]`, pruning a now-empty name map so `available`
  # (which excludes empty producer maps) stays correct.
  defp invalidate_artifact(entry, store) do
    name = EventPayload.get(entry, :name)
    producer = EventPayload.get(entry, :producer)

    case Map.get(store, name) do
      nil ->
        store

      producers ->
        pruned = Map.delete(producers, producer)
        if map_size(pruned) == 0, do: Map.delete(store, name), else: Map.put(store, name, pruned)
    end
  end

  defp artifact_entries(payload) do
    case EventPayload.get(payload, :artifacts) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
