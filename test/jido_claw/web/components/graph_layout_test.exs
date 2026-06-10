defmodule JidoClaw.Web.Components.GraphLayoutTest do
  @moduledoc """
  Pins the ported layout engine (T3-2): empty-graph zeros, padding-origin
  single node, longest-path columns with horizontal-only straight chains,
  fan-out rows + dog-leg segments for diamonds, and the back-edge safety net.
  Geometry constants (210×58 nodes, 72/42 gaps, 24/20 padding) are part of
  the pinned contract.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Web.Components.GraphLayout

  defp node_fixture(name), do: %{name: name, label: name, status: :completed, step_type: "agent"}

  defp edge(from, to), do: %{from: from, to: to}

  defp positioned(layout, name),
    do: Enum.find(layout.nodes, &(&1.node.name == name))

  test "an empty graph yields all-zero dimensions and no geometry" do
    assert GraphLayout.build(%{nodes: [], edges: []}) == %{
             width: 0,
             height: 0,
             nodes: [],
             segments: [],
             ports: []
           }
  end

  test "a single node sits at the padding origin with the fixed box size" do
    layout = GraphLayout.build(%{nodes: [node_fixture("only")], edges: []})

    assert [%{x: 24, y: 20, width: 210, height: 58, node: %{name: "only"}}] = layout.nodes
    # padding*2 + 1 column/row, no gaps.
    assert layout.width == 2 * 24 + 210
    assert layout.height == 2 * 20 + 58
    assert layout.segments == []
    assert layout.ports == []
  end

  test "a linear chain occupies columns 1..3 on one row with horizontal-only segments" do
    layout =
      GraphLayout.build(%{
        nodes: [node_fixture("a"), node_fixture("b"), node_fixture("c")],
        edges: [edge("a", "b"), edge("b", "c")]
      })

    a = positioned(layout, "a")
    b = positioned(layout, "b")
    c = positioned(layout, "c")

    # Columns advance left-to-right by node_width + column_gap; same row.
    assert {a.x, a.y} == {24, 20}
    assert {b.x, b.y} == {24 + 210 + 72, 20}
    assert {c.x, c.y} == {24 + 2 * (210 + 72), 20}

    assert layout.width == 2 * 24 + 3 * 210 + 2 * 72
    assert layout.height == 2 * 20 + 58

    # Two straight edges -> two horizontal segments, no verticals.
    assert Enum.count(layout.segments) == 2
    assert Enum.all?(layout.segments, &(&1.orientation == :horizontal))

    # Each edge contributes a source + target port (4 distinct points).
    assert Enum.count(layout.ports) == 4
  end

  test "a diamond fans out onto two rows and produces a dog-leg" do
    layout =
      GraphLayout.build(%{
        nodes: [node_fixture("a"), node_fixture("b"), node_fixture("c"), node_fixture("d")],
        edges: [edge("a", "b"), edge("a", "c"), edge("b", "d"), edge("c", "d")]
      })

    a = positioned(layout, "a")
    b = positioned(layout, "b")
    c = positioned(layout, "c")
    d = positioned(layout, "d")

    # Longest-path columns: a=1, b=c=2, d=3.
    assert a.x == 24
    assert b.x == 24 + 210 + 72
    assert c.x == b.x
    assert d.x == 24 + 2 * (210 + 72)

    # b keeps its parent's row; c (same column) takes the next row down.
    assert b.y == a.y
    assert c.y == a.y + 58 + 42
    # d prefers its FIRST parent (b) -> back on row 1.
    assert d.y == b.y

    # Two rows tall.
    assert layout.height == 2 * 20 + 2 * 58 + 42

    # The cross-row edges produce vertical dog-leg segments.
    assert Enum.any?(layout.segments, &(&1.orientation == :vertical))
  end

  test "back edges and unknown-name edges are silently dropped (safety net)" do
    layout =
      GraphLayout.build(%{
        nodes: [node_fixture("a"), node_fixture("b")],
        edges: [
          # Backward against input order.
          edge("b", "a"),
          # Self-reference.
          edge("a", "a"),
          # Unknown endpoint.
          edge("a", "ghost"),
          # The one legitimate forward edge.
          edge("a", "b")
        ]
      })

    # Only a->b survives: one horizontal segment, and b advanced to column 2.
    assert [%{orientation: :horizontal}] = layout.segments
    assert positioned(layout, "b").x == 24 + 210 + 72
  end
end
