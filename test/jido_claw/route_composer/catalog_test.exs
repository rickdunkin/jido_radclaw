defmodule JidoClaw.RouteComposer.CatalogTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.Stage

  test "the starter catalog validates clean" do
    assert CatalogValidator.validate(Catalog.all()) == []
  end

  test "all/0 returns every stage keyed by its own name" do
    all = Catalog.all()
    assert map_size(all) == length(Catalog.names())
    assert Enum.all?(all, fn {name, stage} -> match?(%Stage{name: ^name}, stage) end)
  end

  test "get/1 returns a Stage for a known name and nil otherwise" do
    assert %Stage{name: "triage"} = Catalog.get("triage")
    assert Catalog.get("ghost") == nil
  end

  test "names/0 lists the stage names" do
    names = Catalog.names()
    assert "implementer" in names
    assert "fixer" in names
  end

  test "valid?/1 reflects catalog membership" do
    assert Catalog.valid?("plan-gate")
    refute Catalog.valid?("ghost")
  end
end
