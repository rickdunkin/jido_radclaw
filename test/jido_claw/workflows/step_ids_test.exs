defmodule JidoClaw.Workflows.StepIdsTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Workflows.StepIds

  describe "fetch/1" do
    test "returns {:ok, atom} for an index in 1..max" do
      assert StepIds.fetch(1) == {:ok, :step_1}
      assert StepIds.fetch(2) == {:ok, :step_2}
      assert StepIds.fetch(StepIds.max()) == {:ok, :step_256}
    end

    test "returns {:error, :out_of_bounds} past max/0 (and below 1)" do
      assert StepIds.fetch(StepIds.max() + 1) == {:error, :out_of_bounds}
      assert StepIds.fetch(0) == {:error, :out_of_bounds}
    end
  end

  test "max/0 is the step cap (256)" do
    assert StepIds.max() == 256
  end
end
