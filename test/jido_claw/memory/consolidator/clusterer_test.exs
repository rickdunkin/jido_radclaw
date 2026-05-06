defmodule JidoClaw.Memory.Consolidator.ClustererTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Memory.Consolidator.Clusterer

  test "groups facts by label" do
    facts = [
      %{id: "1", label: "preferences"},
      %{id: "2", label: "preferences"},
      %{id: "3", label: "decisions"}
    ]

    clusters = Clusterer.cluster(facts)

    labels = Enum.map(clusters, & &1.label)
    assert "preferences" in labels
    assert "decisions" in labels
  end

  test "lumps unlabeled facts together" do
    facts = [%{id: "1", label: nil}, %{id: "2", label: ""}]
    clusters = Clusterer.cluster(facts)
    assert [%{id: "unlabeled", fact_ids: ids}] = clusters
    assert Enum.sort(ids) == ["1", "2"]
  end

  test "caps cluster count at max_clusters" do
    facts = for i <- 1..30, do: %{id: "#{i}", label: "label-#{i}"}
    clusters = Clusterer.cluster(facts, 5)
    assert length(clusters) == 5
  end
end
