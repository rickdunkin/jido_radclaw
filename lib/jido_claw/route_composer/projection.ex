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
  effect), `stages_invalidated` (Phase 4e rerun primitive → `ran` difference,
  an optional `closed_wave_index` advance, a per-stage `rerun_counts`
  increment, + item 5's `verified_integrity` clear when it covers the
  certified verify stage), `stage_infra` (camus C1-3 → a per-stage
  `infra_counts` increment + the same optional `closed_wave_index` advance;
  **never touches `ran`** — an infra'd stage was never folded, so its
  publishes stay unsatisfied and the next tick re-offers it), `finding_keys`
  (camus C1-5, next-ten #6 → the per-lens `finding_rounds` shift: the new
  round's keys become `current_keys`, the old current becomes `prior_keys`,
  and — BEFORE the shift — the old current joins `seen_prior`, the union of
  every round before current, the oscillation set; a clean round's `keys: []`
  still advances the round), and the item-5
  verify kinds: `stage_tampered` (→ `tampered_stages[stage] = {reason,
  report_ref}`), `head_observed` (→ `observed_head` baseline / `sealed_head`
  derivation), `verify_certified` (→ `verified_integrity`, latest wins), and
  `verify_report_recorded` (provenance only). Genesis, terminals, and any
  non-composer kind fold as no-ops.

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

  # Subtractive `ran` delta (Phase 4e rerun primitive). Three extras:
  #   * the OPTIONAL `closed_wave_index` advances `wave_index = max(_, idx + 1)`
  #     — set ONLY by the reject-parked-gate path (closing a never-completed gate
  #     wave so the re-fire gets a FRESH launch key); a generic completed-wave
  #     rerun omits it (its `wave_completed` already advanced the index, so
  #     re-advancing would skip a key + burn the `max_waves` budget);
  #   * `rerun_counts` increments per invalidated stage — the per-stage rerun cap
  #     the loop's `over_budget?` reads (rebuilt here so the cap survives a crash);
  #   * item 5: invalidating the CERTIFIED verify stage clears
  #     `verified_integrity` — a stale certificate must never back a later
  #     green (the convergence-time re-check would otherwise compare against a
  #     superseded bind).
  defp apply_event(%{kind: :stages_invalidated, payload: payload}, state) do
    stages = EventPayload.list(payload, :stages)

    # `ran`/`wave_index` always exist on the seed (the `|` update); `rerun_counts`
    # is added tolerantly (a synthetic-log test seed may omit it).
    base = %{
      state
      | ran: MapSet.difference(state.ran, MapSet.new(stages)),
        wave_index: advance_on_invalidation(state.wave_index, payload)
    }

    base
    |> clear_invalidated_certificate(stages)
    |> bump_counts(:rerun_counts, stages)
  end

  # Per-stage infra tally (camus C1-3): a judge that produced no usable verdict.
  # Bumps `infra_counts` (tolerantly, like `rerun_counts`) and honors the same
  # OPTIONAL `closed_wave_index` advance as `stages_invalidated` — set by the
  # wave-error lane (the failed wave never wrote `wave_completed`, so without it
  # a restart would rebuild the old `wave_index` and the relaunch would dedupe
  # onto the failed child); the output-boundary lane omits it (its
  # `wave_completed` already advanced the index). NEVER touches `ran` — the
  # infra'd stage was never folded, so the next tick re-offers it naturally.
  defp apply_event(%{kind: :stage_infra, payload: payload}, state) do
    base = %{state | wave_index: advance_on_invalidation(state.wave_index, payload)}
    bump_counts(base, :infra_counts, EventPayload.list(payload, :stages))
  end

  # Camus C1-5 (next-ten #6): one reviewer round's finding-identity fold. The
  # per-lens `finding_rounds` entry shifts — new keys become `current_keys`,
  # the old current becomes `prior_keys`, and (BEFORE the shift) the old
  # current joins `seen_prior`, the union of every round before current — the
  # oscillation set. Marks are canonicalized to atom-keyed `%{key, severity,
  # confidence}` so a live atom-keyed mirror and a JSONB-reloaded fold agree
  # (the equivalence invariant). A payload with no binary `lens` folds as a
  # no-op (fail-safe — never a guessed round). Added tolerantly (a
  # synthetic-log seed may omit `finding_rounds`).
  defp apply_event(%{kind: :finding_keys, payload: payload}, state) do
    case EventPayload.get(payload, :lens) do
      lens when is_binary(lens) ->
        fold_finding_round(state, lens, finding_round_keys(payload), decode_round_marks(payload))

      _absent ->
        state
    end
  end

  # Item 10 (OB1-3): one wave's evidence classification — bump the per-stage
  # `evidence_breaches` counter for every breaching classification (the
  # OpenHelm "counted, breach-visible" rider; the `bump_counts` pattern,
  # added tolerantly), plus the payload's slice-2 `ac` section: violated
  # AC ids count once per breaching wave under the validator-reserved
  # `"evidence:ac"` key. The routing consequences (signals, finding keys,
  # feedback, invalidation) ride their own welded markers — this fold is the
  # durable breach ledger only.
  defp apply_event(%{kind: :evidence_classified, payload: payload}, state) do
    breached =
      for classification <- EventPayload.list(payload, :classifications),
          is_map(classification),
          EventPayload.get(classification, :breach) == true,
          stage = EventPayload.get(classification, :stage),
          is_binary(stage),
          do: stage

    # A breach-less (or malformed) classification folds as a TRUE no-op —
    # never even the tolerant empty-map key add, so clean/garbled ledger
    # entries leave the state byte-identical.
    case breached ++ ac_breach_bump(payload) do
      [] -> state
      stages -> bump_counts(state, :evidence_breaches, stages)
    end
  end

  # Item 5: the evidence-preserving tamper record — `tampered_stages[stage] =
  # {reason, report_ref}` (added tolerantly: a synthetic-log seed may omit the
  # map). The tick terminalizes `:verify_tampered` off this ahead of every
  # other branch, so a crash between the wave commit and the terminal append
  # re-terminalizes idempotently FROM PARENT EVENTS ALONE.
  defp apply_event(%{kind: :stage_tampered, payload: payload}, state) do
    case EventPayload.get(payload, :stage) do
      stage when is_binary(stage) ->
        detail = {EventPayload.get(payload, :reason), EventPayload.get(payload, :report_ref)}
        Map.update(state, :tampered_stages, %{stage => detail}, &Map.put(&1, stage, detail))

      _absent ->
        state
    end
  end

  # Item 5 (C1-6b): the engine's wave-boundary HEAD observation. The FIRST
  # marker is the durable baseline (`observed_head`); a subsequent DIFFERING
  # sha means the run committed work — `sealed_head` derives from it (flipping
  # later verifies to sealed mode). Both added tolerantly.
  defp apply_event(%{kind: :head_observed, payload: payload}, state) do
    case EventPayload.get(payload, :head) do
      sha when is_binary(sha) -> observe_head(state, sha)
      _absent -> state
    end
  end

  # Item 5: a green verify's compact certificate (latest wins — a single
  # verify stage per catalog is validator-enforced, invariant 10) — the
  # convergence-time re-check compares against this without decrypting the
  # report. `mode` crosses the boundary as a string and is whitelist-decoded
  # here; an unknown mode folds a certificate the re-check fails CLOSED on.
  defp apply_event(%{kind: :verify_certified, payload: payload}, state) do
    certificate = %{
      stage: EventPayload.get(payload, :stage),
      head: EventPayload.get(payload, :head),
      tree_digest: EventPayload.get(payload, :tree_digest),
      mode: decode_certified_mode(EventPayload.get(payload, :mode))
    }

    Map.put(state, :verified_integrity, certificate)
  end

  # Item 5: parent-log reachability for a non-`:ok` verify report — provenance
  # only, no routing effect (the ref must never enter the artifact store).
  defp apply_event(%{kind: :verify_report_recorded}, state), do: state

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

  # Tolerant per-stage counter bump under `key` (`:rerun_counts` /
  # `:infra_counts`) — added via `Map.update` because a synthetic-log test seed
  # may omit the counts map entirely.
  defp bump_counts(state, key, stages) do
    Map.update(state, key, bump_stage_counts(%{}, stages), &bump_stage_counts(&1, stages))
  end

  # The AC half of the evidence breach ledger (item 10 remediation, review
  # P2): the payload's `ac.violated` ids — filtered to binaries, since
  # `EventPayload.list/2` is total but returns junk lists as-is — bump the
  # reserved `"evidence:ac"` key once per breaching wave. Absent, empty,
  # non-map, or junk-only `ac` values contribute nothing, preserving the
  # TRUE-no-op property for AC-less events.
  defp ac_breach_bump(payload) do
    with ac when is_map(ac) <- EventPayload.get(payload, :ac),
         [_ | _] <- Enum.filter(EventPayload.list(ac, :violated), &is_binary/1) do
      ["evidence:ac"]
    else
      _absent_or_junk -> []
    end
  end

  # The camus C1-5 round shift. `seen_prior` is computed BEFORE the shift —
  # the union of every round strictly before the incoming one — so
  # `current ∩ (seen_prior \ prior)` is exactly the oscillation set (a key
  # that vanished for ≥1 round and came back). Keys live as MapSets in-memory
  # (projection state only — the durable payload stays a sorted list).
  defp fold_finding_round(state, lens, keys, marks) do
    rounds = Map.get(state, :finding_rounds, %{})

    entry =
      case Map.get(rounds, lens) do
        nil ->
          %{
            round: 1,
            prior_keys: MapSet.new(),
            current_keys: keys,
            seen_prior: MapSet.new(),
            current_marks: marks,
            prior_marks: []
          }

        %{round: round, current_keys: current, seen_prior: seen, current_marks: current_marks} ->
          %{
            round: round + 1,
            prior_keys: current,
            current_keys: keys,
            seen_prior: MapSet.union(seen, current),
            current_marks: marks,
            prior_marks: current_marks
          }
      end

    Map.put(state, :finding_rounds, Map.put(rounds, lens, entry))
  end

  defp finding_round_keys(payload) do
    payload
    |> EventPayload.list(:keys)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  # Canonicalize marks to atom-keyed `%{key, severity, confidence}` (a live
  # atom-keyed mirror and a JSONB string-keyed reload must fold EQUAL states).
  # A key-less/malformed mark entry is dropped — marks are advisory (trend
  # only), so a partial list is safe here, unlike the emission-boundary decode.
  defp decode_round_marks(payload) do
    for mark <- EventPayload.list(payload, :marks),
        is_map(mark),
        key = EventPayload.get(mark, :key),
        is_binary(key) do
      # reach:disable-next-line fixed_shape_map
      %{
        key: key,
        severity: binary_or_nil(EventPayload.get(mark, :severity)),
        confidence: binary_or_nil(EventPayload.get(mark, :confidence))
      }
    end
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  # First observation = baseline; a differing later sha = the seal (the run
  # committed work — later verifies certify the COMMITTED state). Tolerant
  # `Map.put` (a synthetic-log seed may omit both keys).
  defp observe_head(state, sha) do
    case Map.get(state, :observed_head) do
      nil ->
        Map.put(state, :observed_head, sha)

      ^sha ->
        state

      _moved ->
        state
        |> Map.put(:observed_head, sha)
        |> Map.put(:sealed_head, sha)
    end
  end

  # Item 5: invalidating the stage that holds the live certificate clears it —
  # a stale certificate must never back a later green. Tolerant `Map.get` (a
  # synthetic-log seed may omit `verified_integrity`).
  defp clear_invalidated_certificate(state, stages) do
    case Map.get(state, :verified_integrity) do
      %{stage: stage} when is_binary(stage) ->
        if stage in stages, do: Map.put(state, :verified_integrity, nil), else: state

      _absent ->
        state
    end
  end

  @certified_modes %{"working_tree" => :working_tree, "sealed" => :sealed}

  defp decode_certified_mode(mode) when is_binary(mode), do: Map.get(@certified_modes, mode)
  defp decode_certified_mode(mode) when mode in [:working_tree, :sealed], do: mode
  defp decode_certified_mode(_mode), do: nil

  defp bump_stage_counts(counts, stages) do
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
