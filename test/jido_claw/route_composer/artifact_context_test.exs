defmodule JidoClaw.RouteComposer.ArtifactContextTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.ArtifactContext
  alias JidoClaw.RouteComposer.TestFixtures

  test "pulls required + optional names across producers, skipping unreferenced artifacts" do
    stages = [TestFixtures.stage(name: "implementer", req: ["plan"], opt: ["approved-plan"])]

    store = %{
      "plan" => %{"planner" => "PLAN"},
      "approved-plan" => %{"approver" => "APPROVED"},
      "diff" => %{"implementer" => "D"}
    }

    ctx = ArtifactContext.build(stages, store)

    assert ctx =~ "### plan"
    assert ctx =~ "planner"
    assert ctx =~ "PLAN"
    assert ctx =~ "### approved-plan"
    assert ctx =~ "approver"
    assert ctx =~ "APPROVED"
    # `diff` is neither required nor optional for this stage → absent
    refute ctx =~ "### diff"
  end

  test "omits a missing optional input" do
    stages = [TestFixtures.stage(name: "implementer", req: ["plan"], opt: ["approved-plan"])]
    ctx = ArtifactContext.build(stages, %{"plan" => %{"planner" => "PLAN"}})

    assert ctx =~ "### plan"
    refute ctx =~ "approved-plan"
  end

  test "renders every producer of a co-produced name" do
    stages = [TestFixtures.stage(name: "fixer", req: ["findings"])]
    store = %{"findings" => %{"quality-reviewer" => "Q", "security-reviewer" => "S"}}

    ctx = ArtifactContext.build(stages, store)

    assert ctx =~ "quality-reviewer"
    assert ctx =~ "security-reviewer"
  end

  test "returns empty string when nothing wanted is present" do
    stages = [TestFixtures.stage(name: "planner", req: ["request"])]
    assert ArtifactContext.build(stages, %{}) == ""
  end
end
