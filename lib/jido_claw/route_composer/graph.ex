defmodule JidoClaw.RouteComposer.Graph do
  @moduledoc """
  Shared precedence-DAG topological sort over the catalog's data graph.

  `kahn/2` is a faithful port of Alp River `route.py`'s `_toposort` with one
  deliberate divergence: where the source silently appends an undrained cohort
  as a trailing wave (*"data graph is acyclic"*), this returns `{:error,
  undrained}` instead — never a silently-runnable wave (AR-2 §3.2 step 5).

  Both consumers use it so there is one edge-construction implementation, not a
  duplicated block (a `defp` cannot span modules):

    * `JidoClaw.RouteComposer.Router` topo-sorts the runnable set (and raises on
      `{:error, _}` — the validator should already have rejected any cyclic
      catalog at load),
    * `JidoClaw.RouteComposer.CatalogValidator` runs it over the whole catalog
      as its cycle check, reporting a problem on `{:error, _}`.

  Edges run producer → consumer: a `required` **or** `optional` input creates an
  ordering edge only when the producing stage is itself in `names` (an absent
  optional producer creates no edge, never a drop). Self-predecessor edges are
  discarded (a stage requiring its own output is not a data cycle here — the
  validator catches that as a separate self-dependency invariant). Each Kahn
  frontier is alpha-sorted, so the order and waves are deterministic.
  """

  alias JidoClaw.RouteComposer.Stage

  @type kahn_result :: {:ok, [String.t()], [[String.t()]]} | {:error, [String.t()]}

  @doc """
  Topo-sorts `names` (a subset of `stages`' keys) by the input/output
  precedence DAG.

  Returns `{:ok, order, waves}` — `order` the flat alpha-within-level
  topological order, `waves` the Kahn levels (each a parallel cohort,
  `flatten(waves) == order`) — or `{:error, undrained}` with the sorted names
  of the stages a cycle left undrained.
  """
  @spec kahn(%{optional(String.t()) => Stage.t()}, Enumerable.t()) :: kahn_result()
  def kahn(stages, names) do
    name_set = MapSet.new(names)
    producers = producers(stages, name_set)
    {edges, indeg} = precedence_edges(stages, name_set, producers)
    drain(edges, indeg, name_set)
  end

  @doc """
  Index each artifact name to the set of stages in `names` that output it
  (every name must be a key of `stages`).

  Shared by `kahn/2`'s edge construction and
  `JidoClaw.Orchestration.ReviewIndependence.check_route/2` (which walks a
  review stage's inputs back to their producing stages) — one producer-index
  implementation, not a duplicated block.
  """
  @spec producers(%{optional(String.t()) => Stage.t()}, Enumerable.t()) ::
          %{optional(String.t()) => MapSet.t(String.t())}
  def producers(stages, names) do
    Enum.reduce(names, %{}, fn name, acc ->
      outputs = Map.fetch!(stages, name).output

      Enum.reduce(outputs, acc, fn art, inner ->
        Map.update(inner, art, MapSet.new([name]), &MapSet.put(&1, name))
      end)
    end)
  end

  defp precedence_edges(stages, name_set, producers) do
    edges = Map.new(name_set, fn name -> {name, MapSet.new()} end)
    indeg = Map.new(name_set, fn name -> {name, 0} end)

    Enum.reduce(name_set, {edges, indeg}, fn name, {edges_acc, indeg_acc} ->
      preds = predecessors(Map.fetch!(stages, name), producers, name)
      add_edges(preds, name, edges_acc, indeg_acc)
    end)
  end

  defp predecessors(%Stage{input: %{required: req, optional: opt}}, producers, name) do
    inputs = req ++ opt

    inputs
    |> Enum.reduce(MapSet.new(), fn art, acc ->
      MapSet.union(acc, Map.get(producers, art, MapSet.new()))
    end)
    |> MapSet.delete(name)
  end

  defp add_edges(preds, name, edges, indeg) do
    Enum.reduce(preds, {edges, indeg}, fn pred, {edges_acc, indeg_acc} ->
      {Map.update!(edges_acc, pred, &MapSet.put(&1, name)),
       Map.update!(indeg_acc, name, &(&1 + 1))}
    end)
  end

  defp drain(edges, indeg, name_set) do
    initial =
      name_set
      |> Enum.filter(&(Map.fetch!(indeg, &1) == 0))
      |> Enum.sort()

    waves = collect_waves(initial, edges, indeg, [])
    order = Enum.concat(waves)
    undrained = MapSet.difference(name_set, MapSet.new(order))
    resolve(order, waves, undrained)
  end

  defp collect_waves([], _edges, _indeg, acc), do: Enum.reverse(acc)

  defp collect_waves(frontier, edges, indeg, acc) do
    {next_frontier, indeg} = advance(frontier, edges, indeg)
    collect_waves(next_frontier, edges, indeg, [frontier | acc])
  end

  defp advance(frontier, edges, indeg) do
    {next, indeg} =
      Enum.reduce(frontier, {MapSet.new(), indeg}, fn name, acc ->
        relax_successors(Map.fetch!(edges, name), acc)
      end)

    {Enum.sort(MapSet.to_list(next)), indeg}
  end

  defp relax_successors(successors, acc) do
    Enum.reduce(successors, acc, fn succ, {next_acc, indeg_acc} ->
      indeg_acc = Map.update!(indeg_acc, succ, &(&1 - 1))
      ready(succ, next_acc, indeg_acc)
    end)
  end

  defp ready(succ, next, indeg) do
    case Map.fetch!(indeg, succ) do
      0 -> {MapSet.put(next, succ), indeg}
      _ -> {next, indeg}
    end
  end

  defp resolve(order, waves, undrained) do
    case MapSet.size(undrained) do
      0 -> {:ok, order, waves}
      _ -> {:error, Enum.sort(MapSet.to_list(undrained))}
    end
  end
end
