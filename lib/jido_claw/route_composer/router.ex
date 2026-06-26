defmodule JidoClaw.RouteComposer.Router do
  @moduledoc """
  The pure, deterministic route composer — a 1:1 port of Alp River
  `route.py`'s `compute_route` / `merge_sticky` (AR-2 §3, the crown jewel).

  `compose_route/4` is a pure function of `(catalog, live, available, ran)`:
  same inputs ⇒ same result. Zero I/O, no process state. It is the entire
  decision layer; everything around it (later phases) is plumbing.

  The five steps, in `route.py` order:

    1. **trigger** — for each stage **not in `ran`**, the first `subscribes`
       topic matching `live` (OR-membership, declaration order, family-prefix
       via `matches?/2`) names its trigger.
    2. **route-filter** — drop a triggered stage whose `routes` exclude the live
       path. With no path signal live (the pre-triage seed) nothing is filtered.
    3. **drop-unsatisfiable** — a fixed-point loop dropping any stage with a
       required input that no in-route producer (or seeded artifact) can
       supply. Optional inputs are never consulted here.
    4. **locks → held** — a lock entry is active iff its `while` is live and its
       `until` is not (reading `live` only, never `available`). A stage held by
       any active entry is pulled out, then drop-unsatisfiable re-runs (a held
       producer's consumers drop).
    5. **topo-sort** — Kahn by levels over the survivors (via
       `JidoClaw.RouteComposer.Graph`); each frontier is a wave.

  `size` is a **label** derived from the route length, not a count.
  `triggered_by` is keyed only on in-route stages; `held` is always present
  (`%{}` when nothing is locked) and its values are lists of unmet `until`
  signals; a held stage is never in `dropped`.
  """

  alias JidoClaw.RouteComposer.Graph
  alias JidoClaw.RouteComposer.SignalMatch
  alias JidoClaw.RouteComposer.Stage

  @paths ~w(talk sketch code system)

  @type catalog :: %{optional(String.t()) => Stage.t()}

  @type drop_reason :: :off_path | :unsatisfiable_input

  @type result :: %{
          route: [String.t()],
          waves: [[String.t()]],
          size: String.t(),
          triggered_by: %{String.t() => String.t()},
          dropped: %{String.t() => drop_reason()},
          held: %{String.t() => [String.t()]}
        }

  @type merged :: %{
          :route => [String.t()],
          :waves => [[String.t()]],
          :size => String.t(),
          :triggered_by => %{String.t() => String.t()},
          :dropped => %{String.t() => drop_reason()},
          :held => %{String.t() => [String.t()]},
          optional(:sticky_kept) => [String.t()]
        }

  @doc """
  Composes a route from the catalog and the currently-live state.

  Pure and deterministic. See the module doc for the five steps and the
  `result` shape.
  """
  @spec compose_route(catalog(), MapSet.t(String.t()), MapSet.t(String.t()), MapSet.t(String.t())) ::
          result()
  def compose_route(catalog, live, available, ran) do
    triggered = trigger(catalog, live, ran)
    on_path = on_live_path(catalog, triggered, live)
    kept = drop_unsatisfiable(catalog, on_path, available)
    active = active_locks_for(catalog, kept, live)
    locked = locked_names(active)
    runnable = drop_unsatisfiable(catalog, Map.drop(kept, MapSet.to_list(locked)), available)
    {order, waves} = toposort(catalog, Map.keys(runnable))
    assemble(triggered, on_path, order, waves, active, locked)
  end

  @doc """
  Re-adds previous-turn `guard: :sticky` stages that have since left the route
  (asymmetric safety — a sticky stage is never auto-dropped), re-toposorts, and
  tags the result with `:sticky_kept`. A no-op (returns `result` unchanged) when
  nothing sticky needs re-adding. Tolerant of a `prev_name` absent from the
  catalog.

  > This is the **display / persistence** route, **not** a dispatch list.
  > `compose_route/4`'s own route never holds a `ran` stage (trigger skips
  > `ran`), but `merge_sticky/3` deliberately re-adds already-run sticky stages.
  > The Phase-1 loop must filter each merged wave to `stage not in ran` before
  > it executes or tests convergence — folding `merge_sticky` straight into
  > `hd(waves)` would re-run a sticky stage and never converge.
  """
  @spec merge_sticky(catalog(), [String.t()], result()) :: merged()
  def merge_sticky(catalog, prev_names, result) do
    keep =
      Enum.filter(prev_names, fn name -> sticky?(catalog, name) and name not in result.route end)

    case keep do
      [] -> result
      _ -> apply_sticky(catalog, result, keep)
    end
  end

  @doc """
  Maps a route length to its size label: `0 → "empty"`, `1 → "XS"`, `2-3 →
  "S"`, `4-6 → "M"`, `7-10 → "L"`, `11-15 → "XL"`, `16+ → "XXL"`.
  """
  @spec size_label(integer()) :: String.t()
  def size_label(n) when n <= 0, do: "empty"
  def size_label(n) when n <= 1, do: "XS"
  def size_label(n) when n <= 3, do: "S"
  def size_label(n) when n <= 6, do: "M"
  def size_label(n) when n <= 10, do: "L"
  def size_label(n) when n <= 15, do: "XL"
  def size_label(_n), do: "XXL"

  # ---------------------------------------------------------------------------
  # Trigger — the first subscribed signal a not-yet-run stage matches in `live`
  # ---------------------------------------------------------------------------

  defp trigger(catalog, live, ran) do
    Enum.reduce(catalog, %{}, fn {name, stage}, acc ->
      add_trigger(acc, name, stage, live, ran)
    end)
  end

  defp add_trigger(acc, name, stage, live, ran) do
    if MapSet.member?(ran, name) do
      acc
    else
      put_first_match(acc, name, stage.subscribes, live)
    end
  end

  defp put_first_match(acc, name, subscribes, live) do
    case Enum.find(subscribes, fn sig -> SignalMatch.matches?(sig, live) end) do
      nil -> acc
      sig -> Map.put(acc, name, sig)
    end
  end

  # ---------------------------------------------------------------------------
  # Route filter — drop a triggered stage whose routes exclude the live path
  # ---------------------------------------------------------------------------

  defp on_live_path(catalog, triggered, live) do
    live_paths = Enum.filter(@paths, fn path -> MapSet.member?(live, path) end)

    case live_paths do
      [] -> triggered
      _ -> Map.filter(triggered, fn {name, _sig} -> on_path?(catalog, name, live_paths) end)
    end
  end

  defp on_path?(catalog, name, live_paths) do
    Enum.any?(Map.fetch!(catalog, name).routes, fn route -> route in live_paths end)
  end

  # ---------------------------------------------------------------------------
  # Drop unsatisfiable — a fixed-point cascade over required (not optional) inputs
  # ---------------------------------------------------------------------------

  defp drop_unsatisfiable(catalog, kept, available) do
    produced = produced_set(catalog, kept)
    unsat = for {name, _sig} <- kept, unsatisfiable?(catalog, name, available, produced), do: name

    case unsat do
      [] -> kept
      _ -> drop_unsatisfiable(catalog, Map.drop(kept, unsat), available)
    end
  end

  defp produced_set(catalog, kept) do
    Enum.reduce(kept, MapSet.new(), fn {name, _sig}, acc ->
      MapSet.union(acc, MapSet.new(Map.fetch!(catalog, name).output))
    end)
  end

  defp unsatisfiable?(catalog, name, available, produced) do
    Enum.any?(Map.fetch!(catalog, name).input.required, fn art ->
      not MapSet.member?(available, art) and not MapSet.member?(produced, art)
    end)
  end

  # ---------------------------------------------------------------------------
  # Locks — a stage held by any active lock (while live, until not) is pulled out
  # ---------------------------------------------------------------------------

  defp active_locks_for(catalog, kept, live) do
    Map.new(kept, fn {name, _sig} -> {name, active_locks(Map.fetch!(catalog, name), live)} end)
  end

  defp active_locks(%Stage{lock: locks}, live) do
    Enum.filter(locks, fn lock ->
      SignalMatch.matches?(lock.while, live) and not SignalMatch.matches?(lock.until, live)
    end)
  end

  defp locked_names(active) do
    for {name, locks} <- active, locks != [], into: MapSet.new(), do: name
  end

  # ---------------------------------------------------------------------------
  # Topo-sort — raises on a cycle the validator should have rejected at load
  # ---------------------------------------------------------------------------

  defp toposort(catalog, names) do
    case Graph.kahn(catalog, names) do
      {:ok, order, waves} ->
        {order, waves}

      {:error, undrained} ->
        raise ArgumentError,
              "RouteComposer.Router: precedence graph has a cycle; undrained stages: #{inspect(undrained)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Result assembly
  # ---------------------------------------------------------------------------

  defp assemble(triggered, on_path, order, waves, active, locked) do
    held = held_map(active, locked)

    %{
      route: order,
      waves: waves,
      size: size_label(length(order)),
      triggered_by: triggered_by(triggered, order),
      dropped: build_dropped(triggered, on_path, order, held),
      held: held
    }
  end

  defp held_map(active, locked) do
    Map.new(locked, fn name -> {name, Enum.map(Map.fetch!(active, name), & &1.until)} end)
  end

  defp triggered_by(triggered, order) do
    Map.new(order, fn name -> {name, Map.fetch!(triggered, name)} end)
  end

  defp build_dropped(triggered, on_path, order, held) do
    order_set = MapSet.new(order)

    Enum.reduce(Map.keys(triggered), %{}, fn name, acc ->
      classify_drop(acc, name, on_path, order_set, held)
    end)
  end

  defp classify_drop(acc, name, on_path, order_set, held) do
    cond do
      not Map.has_key?(on_path, name) -> Map.put(acc, name, :off_path)
      drop_unsatisfiable?(name, order_set, held) -> Map.put(acc, name, :unsatisfiable_input)
      true -> acc
    end
  end

  defp drop_unsatisfiable?(name, order_set, held) do
    not MapSet.member?(order_set, name) and not Map.has_key?(held, name)
  end

  # ---------------------------------------------------------------------------
  # merge_sticky helpers
  # ---------------------------------------------------------------------------

  defp sticky?(catalog, name) do
    match?(%Stage{guard: :sticky}, Map.get(catalog, name))
  end

  defp apply_sticky(catalog, result, keep) do
    union = MapSet.union(MapSet.new(result.route), MapSet.new(keep))
    {order, waves} = toposort(catalog, union)

    %{
      route: order,
      waves: waves,
      size: size_label(length(order)),
      triggered_by: result.triggered_by,
      dropped: result.dropped,
      held: result.held,
      sticky_kept: keep
    }
  end

  # The one-directional family-prefix matcher (`trigger` + `active_locks`) lives in
  # `JidoClaw.RouteComposer.SignalMatch` — single-sourced with the AR-4 self-heal
  # helpers; cf. CatalogValidator's bidirectional `family_match?/2`, which is
  # deliberately NOT shared.
end
