defmodule JidoClaw.RouteComposer.Observe do
  @moduledoc """
  Seed-free observe summary of a composer run, built from the durable
  `WorkflowEvent` log alone (AR-2 Phase 5, §10.2).

  Distinct from `JidoClaw.RouteComposer.Projection`, which **cannot** run from a
  run row + log alone — it folds onto a *seed* (catalog + seeded
  signals/artifacts) that lives only inside the running GenServer. This module
  sidesteps the seed: every wave durably appends a **self-contained**
  `route_composed` snapshot carrying `route / waves / held / dropped /
  triggered_by / size / live / available / premises` (`route_composer.ex`), so
  the **latest `route_composed` payload** (plus a tiny seed-free fold for
  `ran` / `latest_started_wave_index` / `wave_in_flight`) is the full observe
  view for **running and terminal** runs.

  The snapshot is **names/labels only** (signal topics, stage names, artifact
  *names*, premises `{path, est_size}`) — **no artifact values** — so this
  summary carries no redaction risk.

  Pure: `summarize/1` takes the run's events and returns a map, or `nil` when no
  `route_composed` event exists yet (a run that has not composed its first
  wave). Tolerant payload access (atom-or-string keys) is shared with
  `Projection` via `JidoClaw.RouteComposer.EventPayload`.
  """

  alias JidoClaw.RouteComposer.EventPayload

  @doc """
  Summarize the composer view from `events`, or `nil` when the run has not yet
  composed a wave (no `route_composed` in the log).

  The latest `route_composed` wins (its self-contained snapshot is the route
  view); `ran` / `latest_started_wave_index` / `wave_in_flight` are folded
  seed-free from the whole log.
  """
  @spec summarize([map()]) :: map() | nil
  def summarize(events) do
    events = Enum.sort_by(events, & &1.seq)

    case latest(events, :route_composed) do
      nil ->
        nil

      %{payload: snap} ->
        %{
          route: EventPayload.list(snap, :route),
          waves: EventPayload.get(snap, :waves) || [],
          held: EventPayload.get(snap, :held) || %{},
          dropped: EventPayload.get(snap, :dropped) || %{},
          triggered_by: EventPayload.get(snap, :triggered_by) || %{},
          size: EventPayload.get(snap, :size),
          live: EventPayload.list(snap, :live),
          available: EventPayload.list(snap, :available),
          premises: EventPayload.get(snap, :premises) || %{},
          ran: net_ran(events),
          latest_started_wave_index: latest_started_wave_index(events),
          wave_in_flight: wave_in_flight?(events)
        }
    end
  end

  # Net `ran`, folded in seq order to match `Projection`: `wave_completed.stages`
  # union, `stages_invalidated.stages` difference. Returned sorted (deterministic
  # + directly JSON-safe).
  defp net_ran(events) do
    events
    |> Enum.reduce(MapSet.new(), fn
      %{kind: :wave_completed, payload: p}, acc ->
        MapSet.union(acc, MapSet.new(EventPayload.list(p, :stages)))

      %{kind: :stages_invalidated, payload: p}, acc ->
        MapSet.difference(acc, MapSet.new(EventPayload.list(p, :stages)))

      _event, acc ->
        acc
    end)
    |> Enum.sort()
  end

  # The `wave_index` of the latest `wave_started` — the wave currently/last
  # launched (paired 1:1 with the latest `route_composed`). Named distinctly from
  # `Projection`'s `wave_index`, which means the *next/completed* index advanced
  # by `wave_completed`; for a terminal run those two differ (latest-started `N`
  # vs projected `N+1`).
  defp latest_started_wave_index(events) do
    case latest(events, :wave_started) do
      nil -> nil
      %{payload: p} -> EventPayload.int(p, :wave_index)
    end
  end

  # Reliable "a wave is launched but not yet folded" signal: the latest
  # `wave_started.wave_index` has no matching `wave_completed`. Deliberately does
  # NOT read `wave_paused` (non-load-bearing per `route_composer.ex`), so the
  # parked-gate case — `wave_started(N)`, no `wave_completed(N)`, NO `wave_paused`
  # — still reads in-flight. The authoritative *blocked-on-a-gate* determination
  # is made in `WorkflowView.snapshot/2` from child-run status, not here.
  defp wave_in_flight?(events) do
    case latest_started_wave_index(events) do
      nil -> false
      idx -> not wave_completed?(events, idx)
    end
  end

  defp wave_completed?(events, idx) do
    Enum.any?(events, fn
      %{kind: :wave_completed, payload: p} -> EventPayload.int(p, :wave_index) == idx
      _event -> false
    end)
  end

  # `events` are pre-sorted by seq; the last match is the highest-seq event of
  # `kind`.
  defp latest(events, kind) do
    events
    |> Enum.filter(&(&1.kind == kind))
    |> List.last()
  end
end
