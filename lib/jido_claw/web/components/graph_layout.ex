defmodule JidoClaw.Web.Components.GraphLayout do
  @moduledoc """
  Pure layout engine for a left-to-right step DAG (T3-2): given
  `%{nodes, edges}` it computes absolutely-positioned node boxes, dog-leg edge
  segments, and connection ports for a plain-divs render (no SVG).

  Adapted from SquidSonar (`SquidSonarWeb.WorkflowGraphLayout`), © its
  authors, Apache License 2.0 (dark-trench/squid_sonar); the deadline/recovery
  node-height variants were removed — every node here is the fixed
  210×58 box.

  ## Algorithm

    * **Columns** — longest-path layering: every node starts in column 1 and
      each forward edge pushes its target right of its source (iterated to a
      fixed point, bounded by node count).
    * **Rows** — nodes are placed column-major in input order; each prefers
      its first parent's row (straight horizontal edges for chains) and takes
      the next free row in its column otherwise.
    * **Segments** — same-row edges are one horizontal bar; cross-row edges
      are a horizontal→vertical→horizontal dog-leg meeting halfway between
      the columns.
    * **Safety net** — `edges` whose endpoints are unknown, or that point
      backwards/self-referentially against input order, are silently dropped:
      the layout never loops and never raises on malformed edge data.

  Inputs: `nodes` is a list of maps with at least `:name` (any
  `to_string`-able value); `edges` is a list of `%{from: name, to: name}`.
  Output: `%{width, height, nodes: [%{node, x, y, width, height}], segments,
  ports}` — `node` is the caller's map passed through untouched.
  """

  @node_width 210
  @node_height 58
  @column_gap 72
  @row_gap 42
  @padding_x 24
  @padding_y 20
  @line_size 2

  @doc """
  Calculate node, edge-segment, and port positions for a step graph.
  """
  @spec build(%{nodes: [map()], edges: [map()]}) :: map()
  def build(%{nodes: []}) do
    %{
      width: 0,
      height: 0,
      nodes: [],
      segments: [],
      ports: []
    }
  end

  def build(%{nodes: nodes, edges: edges}) do
    node_order = node_order(nodes)
    graph_edges = graph_edges(edges, node_order)
    columns = columns(nodes, graph_edges, node_order)
    positions = positions(nodes, graph_edges, columns, node_order)

    %{
      width: dimension(positions, :column, @node_width, @column_gap, @padding_x),
      height: dimension(positions, :row, @node_height, @row_gap, @padding_y),
      nodes: positioned_nodes(nodes, positions),
      segments: segments(graph_edges, positions),
      ports: ports(graph_edges, positions)
    }
  end

  defp node_order(nodes) do
    nodes
    |> Enum.with_index()
    |> Map.new(fn {%{name: name}, index} -> {node_key(name), index} end)
  end

  # Keep only edges between known nodes that run FORWARD in input order —
  # back edges and unknown names are silently dropped (the safety net).
  defp graph_edges(edges, node_order) do
    edges
    |> Enum.map(fn %{from: from, to: to} -> {node_key(from), node_key(to)} end)
    |> Enum.filter(fn {from, to} ->
      Map.has_key?(node_order, from) and Map.has_key?(node_order, to) and
        Map.fetch!(node_order, from) < Map.fetch!(node_order, to)
    end)
  end

  # Longest-path layering, iterated to a fixed point (n iterations bound the
  # longest possible chain).
  defp columns(nodes, graph_edges, node_order) do
    initial_columns = Map.new(nodes, fn %{name: name} -> {node_key(name), 1} end)

    Enum.reduce(1..map_size(node_order), initial_columns, fn _iteration, columns ->
      Enum.reduce(graph_edges, columns, &advance_column/2)
    end)
  end

  defp advance_column({from, to}, columns) do
    next_column = Map.fetch!(columns, from) + 1

    if next_column > Map.fetch!(columns, to) do
      Map.put(columns, to, next_column)
    else
      columns
    end
  end

  defp positions(nodes, graph_edges, columns, node_order) do
    parents_by_node =
      Enum.reduce(graph_edges, %{}, fn {from, to}, parents ->
        Map.update(parents, to, [from], &[from | &1])
      end)

    nodes
    |> Enum.sort_by(fn %{name: name} ->
      key = node_key(name)
      {Map.fetch!(columns, key), Map.fetch!(node_order, key)}
    end)
    |> Enum.reduce({%{}, %{}}, fn %{name: name}, {positions, occupied_rows} ->
      key = node_key(name)
      column = Map.fetch!(columns, key)
      desired_row = desired_row(Map.get(parents_by_node, key, []), positions)
      row = available_row(Map.get(occupied_rows, column, MapSet.new()), desired_row)

      position = %{
        column: column,
        row: row,
        x: @padding_x + (column - 1) * (@node_width + @column_gap),
        y: @padding_y + (row - 1) * (@node_height + @row_gap),
        width: @node_width,
        height: @node_height
      }

      {
        Map.put(positions, key, position),
        Map.update(occupied_rows, column, MapSet.new([row]), &MapSet.put(&1, row))
      }
    end)
    |> elem(0)
  end

  # Prefer the first parent's row (straight edges for chains); parents are
  # accumulated reversed, hence the re-reverse.
  defp desired_row(parents, positions) do
    parents
    |> Enum.reverse()
    |> Enum.find_value(1, fn parent ->
      case Map.fetch(positions, parent) do
        {:ok, %{row: row}} -> row
        :error -> nil
      end
    end)
  end

  defp available_row(occupied_rows, desired_row) do
    if MapSet.member?(occupied_rows, desired_row) do
      available_row(occupied_rows, desired_row + 1)
    else
      desired_row
    end
  end

  defp positioned_nodes(nodes, positions) do
    Enum.map(nodes, fn %{name: name} = node ->
      position = Map.fetch!(positions, node_key(name))

      %{
        node: node,
        x: position.x,
        y: position.y,
        width: position.width,
        height: position.height
      }
    end)
  end

  defp dimension(positions, field, item_size, gap, padding) do
    max_index =
      positions
      |> Enum.map(fn {_key, position} -> Map.fetch!(position, field) end)
      |> Enum.max(fn -> 1 end)

    padding * 2 + max_index * item_size + (max_index - 1) * gap
  end

  defp segments(graph_edges, positions) do
    Enum.flat_map(graph_edges, fn {from, to} ->
      source = Map.fetch!(positions, from)
      target = Map.fetch!(positions, to)
      x1 = source.x + source.width
      x2 = target.x
      y1 = source.y + source.height / 2
      y2 = target.y + target.height / 2
      mid_x = x1 + (x2 - x1) / 2

      if y1 == y2 do
        [horizontal_segment(x1, y1, x2 - x1)]
      else
        [
          horizontal_segment(x1, y1, mid_x - x1),
          vertical_segment(mid_x, y1, y2),
          horizontal_segment(mid_x, y2, x2 - mid_x)
        ]
      end
    end)
  end

  defp horizontal_segment(x, y, width) do
    %{
      orientation: :horizontal,
      x: x,
      y: y - @line_size / 2,
      width: width,
      height: @line_size
    }
  end

  defp vertical_segment(x, y1, y2) do
    %{
      orientation: :vertical,
      x: x - @line_size / 2,
      y: min(y1, y2),
      width: @line_size,
      height: abs(y2 - y1)
    }
  end

  defp ports(graph_edges, positions) do
    graph_edges
    |> Enum.flat_map(fn {from, to} ->
      source = Map.fetch!(positions, from)
      target = Map.fetch!(positions, to)

      [
        %{x: source.x + source.width, y: source.y + source.height / 2},
        %{x: target.x, y: target.y + target.height / 2}
      ]
    end)
    |> Enum.uniq()
  end

  defp node_key(value), do: to_string(value)
end
