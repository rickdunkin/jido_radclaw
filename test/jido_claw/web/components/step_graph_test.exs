defmodule JidoClaw.Web.Components.StepGraphTest do
  @moduledoc """
  Pins the step-rows → graph adapter (T3-1): declared `depends_on` edges
  (unknown names filtered), the all-empty sequence-chain fallback (never
  mixed with declared edges), the collect-ranked-last ordering that keeps
  named→collect edges forward, and the leakage-hygiene guarantee that nodes
  carry metadata only. Pure struct-in/map-out — no DB.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Web.Components.GraphLayout
  alias JidoClaw.Web.Components.StepGraph

  defp step(name, sequence, overrides \\ []) do
    struct!(
      %WorkflowStep{
        name: name,
        sequence: sequence,
        status: :completed,
        step_type: "agent",
        depends_on: [],
        output: %{"result" => "SENSITIVE PAYLOAD"},
        error: "SENSITIVE ERROR",
        config: %{"secret" => "x"},
        deadline: %{"within" => 60}
      },
      overrides
    )
  end

  test "declared depends_on become edges; unknown targets are filtered" do
    steps = [
      step("run_tests", 1),
      step("review_code", 2),
      step("synthesize", 3, depends_on: ["run_tests", "review_code", "ghost"])
    ]

    %{edges: edges} = StepGraph.build(steps)

    assert %{from: "run_tests", to: "synthesize"} in edges
    assert %{from: "review_code", to: "synthesize"} in edges
    refute Enum.any?(edges, &(&1.from == "ghost"))
    assert Enum.count(edges) == 2
  end

  test "no declared edges anywhere -> the linear sequence chain (sequential skills)" do
    steps = [step("s1", 1), step("s2", 2), step("s3", 3)]

    %{edges: edges} = StepGraph.build(steps)

    assert edges == [
             %{from: "s1", to: "s2"},
             %{from: "s2", to: "s3"}
           ]
  end

  test "all-empty depends_on with a collect row chains THROUGH the collect (ranked last)" do
    # Sequential runs declare no edges anywhere — the compiler mode-gates the
    # collect's depends_on to [] outside dag mode (pre-T3-1 rows are all-empty
    # too). The fallback must render step1→…→stepN→collect, never isolate the
    # collect or star into it.
    steps = [
      step(":__collect__", 0, step_type: "collect"),
      step("one", 1),
      step("two", 2),
      step("three", 3)
    ]

    %{edges: edges} = StepGraph.build(steps)

    assert edges == [
             %{from: "one", to: "two"},
             %{from: "two", to: "three"},
             %{from: "three", to: ":__collect__"}
           ]
  end

  test "declared and synthesized edges never mix (one real edge disables the fallback)" do
    steps = [step("s1", 1), step("s2", 2), step("s3", 3, depends_on: ["s1"])]

    %{edges: edges} = StepGraph.build(steps)

    # Only the declared edge — no synthetic s1->s2 / s2->s3 chain.
    assert edges == [%{from: "s1", to: "s3"}]
  end

  test "the collect row (sequence 0) ranks LAST so its incoming edges stay forward" do
    steps = [
      step(":__collect__", 0, step_type: "collect", depends_on: ["alpha", "beta"]),
      step("alpha", 1),
      step("beta", 2)
    ]

    %{nodes: nodes, edges: edges} = StepGraph.build(steps)

    # Collect ranks last; the friendly label replaces the synthetic Reactor id.
    assert [%{name: "alpha"}, %{name: "beta"}, %{name: ":__collect__", label: "collect"}] = nodes

    assert %{from: "alpha", to: ":__collect__"} in edges
    assert %{from: "beta", to: ":__collect__"} in edges

    # End-to-end through the layout: the collect edges survive the
    # forward-edge filter (the node is NOT isolated).
    layout = GraphLayout.build(%{nodes: nodes, edges: edges})
    assert layout.segments != []
  end

  test "nodes carry metadata only — never payload keys (leakage hygiene)" do
    %{nodes: nodes} = StepGraph.build([step("s1", 1), step("s2", 2)])

    for node <- nodes do
      assert Enum.sort(Map.keys(node)) == [:label, :name, :status, :step_type]
      refute inspect(node) =~ "SENSITIVE"
    end
  end

  test "empty step list builds an empty graph" do
    assert StepGraph.build([]) == %{nodes: [], edges: []}
  end
end
