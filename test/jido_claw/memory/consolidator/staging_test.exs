defmodule JidoClaw.Memory.Consolidator.StagingTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Memory.Consolidator.Staging

  test "new/0 returns an empty buffer" do
    assert Staging.total(Staging.new()) == 0
  end

  test "add/3 appends per-type proposals" do
    {:ok, with_add} = Staging.add(Staging.new(), :fact_add, %{content: "a"})
    {:ok, with_update} = Staging.add(with_add, :fact_update, %{fact_id: "x", new_content: "b"})
    {:ok, with_delete} = Staging.add(with_update, :fact_delete, %{fact_id: "y"})

    {:ok, with_link} =
      Staging.add(with_delete, :link_create, %{from_fact_id: "a", to_fact_id: "b", relation: "r"})

    {:ok, staging} = Staging.add(with_link, :cluster_defer, %{cluster_id: "c"})

    assert [_] = staging.fact_adds
    assert [_] = staging.fact_updates
    assert [_] = staging.fact_deletes
    assert [_] = staging.link_creates
    assert [_] = staging.cluster_defers
    assert Staging.total(staging) == 5
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

      assert [_] = s.block_updates
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
