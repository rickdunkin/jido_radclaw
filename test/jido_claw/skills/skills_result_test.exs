defmodule JidoClaw.Skills.ResultTest do
  @moduledoc """
  Pins `JidoClaw.Skills.Result.build/3` — relocated from
  `RunSkill.build_result/2`. Ports the label-selection tests (name over
  template, unnamed → template fallback, distinct-by-name, legacy tuples) and
  asserts the result map is JSON-safe (only strings/ints/nil).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Skills.Result
  alias JidoClaw.Workflows.StepResult

  test "uses step name as the primary label, not the template name" do
    results = [
      %StepResult{name: "run_tests", template: "test_runner", result: "all pass"},
      %StepResult{name: "review_code", template: "reviewer", result: "looks good"}
    ]

    output = Result.build("test_skill", "summarize", results)

    assert output.results =~ "run_tests"
    assert output.results =~ "review_code"
    refute output.results =~ "## Step 1: test_runner"
    refute output.results =~ "## Step 2: reviewer"
  end

  test "falls back to template when name is nil (unnamed step)" do
    results = [%StepResult{name: nil, template: "coder", result: "done"}]
    output = Result.build("test_skill", "summarize", results)
    assert output.results =~ "## Step 1: coder"
  end

  test "two steps with the same template are distinguishable by name" do
    results = [
      %StepResult{name: "unit_tests", template: "test_runner", result: "unit pass"},
      %StepResult{name: "integration_tests", template: "test_runner", result: "integration pass"}
    ]

    output = Result.build("test_skill", "summarize", results)

    assert output.results =~ "## Step 1: unit_tests"
    assert output.results =~ "## Step 2: integration_tests"
  end

  test "handles legacy {label, text} tuples" do
    output = Result.build("test_skill", "summarize", [{"old_step", "old output"}])
    assert output.results =~ "old_step"
    assert output.steps_completed == 1
  end

  test "carries the skill name, synthesis directive, and step count" do
    results = [
      %StepResult{name: "a", template: "coder", result: "x"},
      %StepResult{name: "b", template: "reviewer", result: "y"}
    ]

    output = Result.build("my_skill", "Present the findings", results)

    assert output.skill == "my_skill"
    assert output.synthesis_prompt == "Present the findings"
    assert output.steps_completed == 2
    assert output.message =~ "Skill 'my_skill' completed 2 steps"
    assert output.message =~ "Present the findings"
  end

  test "result map is JSON-safe (only strings/ints/nil values)" do
    results = [%StepResult{name: "a", template: "coder", result: "x"}]
    output = Result.build("s", "syn", results)

    assert {:ok, _json} = Jason.encode(output)

    Enum.each(output, fn {_k, v} ->
      assert is_binary(v) or is_integer(v) or is_nil(v)
    end)
  end

  test "nil synthesis renders without crashing" do
    results = [%StepResult{name: "a", template: "coder", result: "x"}]
    output = Result.build("s", nil, results)
    assert output.synthesis_prompt == nil
    assert is_binary(output.message)
  end
end
