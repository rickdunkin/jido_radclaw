defmodule JidoClaw.Web.Components.StepGraph do
  @moduledoc """
  Adapter from projected `WorkflowStep` rows to the `GraphLayout` input shape
  (T3-1): nodes carry **metadata only** (name/label/status/step_type — never
  output/error/config/deadline payloads, composing with the T2-2 visibility
  rules), and edges come from the durable `depends_on` column.

  ## Edge sources

    * **Declared** — each step's `depends_on` (the compiler-stamped
      `depends_on ∪ consumes` union for DAG skills, incl. the synthetic
      collect's named-step list), filtered to names present in this run.
    * **Fallback** — when NO step declares an edge (sequential skills don't
      stamp; pre-T3-1 rows are empty), synthesize the linear
      sequence-order chain — an honest "ran in this order" rendering.
      Declared and synthesized edges are never mixed.

  Node `name` is the projected row's name (YAML name, or the positional /
  `:__collect__` fallback identity); the synthetic collect maps to a friendly
  `"collect"` label.
  """

  alias JidoClaw.Orchestration.WorkflowStep

  @collect_name ":__collect__"

  @doc """
  Build `%{nodes, edges}` for `GraphLayout.build/1` from one run's step rows.
  """
  @spec build([WorkflowStep.t()]) :: %{nodes: [map()], edges: [map()]}
  def build(steps) do
    ordered = Enum.sort_by(steps, &{collect_rank(&1), &1.sequence, &1.name})
    nodes = Enum.map(ordered, &graph_node/1)

    %{nodes: nodes, edges: edges(ordered)}
  end

  # The collect row projects with sequence 0 (its Reactor id is not a
  # positional ":step_N"), which a plain {sequence, name} sort would place
  # FIRST — and the layout's forward-edge filter would then drop every
  # named→collect edge, isolating the node. It is the terminal sink, so rank
  # it last.
  defp collect_rank(%{name: @collect_name}), do: 1
  defp collect_rank(_step), do: 0

  # Metadata-only node: never payloads (output/error/config/deadline).
  defp graph_node(step) do
    %{
      name: step.name,
      label: label(step),
      status: step.status,
      step_type: step.step_type
    }
  end

  defp label(%{name: @collect_name}), do: "collect"
  defp label(step), do: step.name

  defp edges(ordered) do
    declared = declared_edges(ordered)

    if declared == [] do
      sequence_chain(ordered)
    else
      declared
    end
  end

  # Edges from the durable depends_on lists, filtered to names present in
  # this run (the layout would drop dangling edges anyway; filtering here
  # keeps the adapter's output honest).
  defp declared_edges(ordered) do
    known = MapSet.new(ordered, & &1.name)

    for step <- ordered,
        dep <- List.wrap(step.depends_on),
        MapSet.member?(known, dep) do
      %{from: dep, to: step.name}
    end
  end

  # No declared edges anywhere -> the honest linear chain in sequence order.
  defp sequence_chain(ordered) do
    ordered
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> %{from: from.name, to: to.name} end)
  end
end
