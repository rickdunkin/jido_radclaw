defmodule JidoClaw.RouteComposer.FoldTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.StageEmission

  defp state(overrides \\ %{}) do
    Map.merge(%{live: MapSet.new(), artifacts: %{}, ran: MapSet.new()}, overrides)
  end

  test "folds signals into live, artifacts into the provenance store, names into ran" do
    emission = %StageEmission{
      stage: "planner",
      signals: ["plan-ready"],
      artifacts: %{"plan" => "P"}
    }

    next = Fold.fold(state(), [emission])

    assert MapSet.member?(next.live, "plan-ready")
    assert next.artifacts == %{"plan" => %{"planner" => "P"}}
    assert MapSet.member?(next.ran, "planner")
  end

  test "co-producers of one artifact name coexist (no clobber)" do
    e1 = %StageEmission{stage: "quality-reviewer", artifacts: %{"findings" => []}}
    e2 = %StageEmission{stage: "security-reviewer", artifacts: %{"findings" => []}}
    next = Fold.fold(state(), [e1, e2])

    assert next.artifacts == %{
             "findings" => %{"quality-reviewer" => [], "security-reviewer" => []}
           }
  end

  test "paired verdict is last-writer-wins (clean retracts findings and vice-versa)" do
    flagged = Fold.fold(state(), [%StageEmission{stage: "q", signals: ["findings:quality"]}])
    assert MapSet.member?(flagged.live, "findings:quality")

    cleaned = Fold.fold(flagged, [%StageEmission{stage: "q", signals: ["clean:quality"]}])
    assert MapSet.member?(cleaned.live, "clean:quality")
    refute MapSet.member?(cleaned.live, "findings:quality")

    reflagged = Fold.fold(cleaned, [%StageEmission{stage: "q", signals: ["findings:quality"]}])
    assert MapSet.member?(reflagged.live, "findings:quality")
    refute MapSet.member?(reflagged.live, "clean:quality")
  end

  test "available/1 derives the name set from the store" do
    store = %{"plan" => %{"planner" => "P"}, "diff" => %{"implementer" => "D"}}
    assert Fold.available(store) == MapSet.new(["plan", "diff"])
  end

  test "available/1 excludes names whose producer map is empty" do
    store = %{"plan" => %{"planner" => "P"}, "request" => %{}}
    assert Fold.available(store) == MapSet.new(["plan"])
  end
end
