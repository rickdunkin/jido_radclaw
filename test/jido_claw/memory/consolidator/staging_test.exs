defmodule JidoClaw.Memory.Consolidator.StagingTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Memory.Consolidator.Staging

  test "new/0 returns an empty buffer" do
    assert Staging.total(Staging.new()) == 0
  end

  test "add/3 appends per-type proposals" do
    s = Staging.new()
    {:ok, s} = Staging.add(s, :fact_add, %{content: "a"})
    {:ok, s} = Staging.add(s, :fact_update, %{fact_id: "x", new_content: "b"})
    {:ok, s} = Staging.add(s, :fact_delete, %{fact_id: "y"})
    {:ok, s} = Staging.add(s, :link_create, %{from_fact_id: "a", to_fact_id: "b", relation: "r"})
    {:ok, s} = Staging.add(s, :cluster_defer, %{cluster_id: "c"})

    assert length(s.fact_adds) == 1
    assert length(s.fact_updates) == 1
    assert length(s.fact_deletes) == 1
    assert length(s.link_creates) == 1
    assert length(s.cluster_defers) == 1
    assert Staging.total(s) == 5
  end

  describe "add_block_update/2" do
    test "returns :ok for content within char_limit" do
      s = Staging.new()

      assert {:ok, s} =
               Staging.add_block_update(s, %{
                 label: "x",
                 new_content: "short",
                 char_limit: 100
               })

      assert length(s.block_updates) == 1
    end

    test "returns structured overflow info for content exceeding char_limit" do
      s = Staging.new()
      content = String.duplicate("x", 200)

      assert {:char_limit_exceeded, 200, 100} =
               Staging.add_block_update(s, %{
                 label: "x",
                 new_content: content,
                 char_limit: 100
               })
    end
  end
end
