defmodule JidoClaw.Skills.Steps.CollectStepTest do
  @moduledoc """
  Pure tests for the terminal collector. It reorders the received step results
  by the configured `:order`, flattens an iterative step's `[gen, eval]` list,
  and produces the JSON-safe `Skills.Result.build/3` map whose
  `steps_completed` counts only agent results.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Skills.Steps.CollectStep
  alias JidoClaw.Workflows.StepResult

  test "reorders dag/sequential results by the configured step order" do
    # arguments arrive keyed by step_id, order is independent of map order.
    arguments = %{
      step_2: %StepResult{name: "b", template: "reviewer", result: "second"},
      step_1: %StepResult{name: "a", template: "coder", result: "first"}
    }

    options = [
      order: [{:step_1, "a"}, {:step_2, "b"}],
      skill_name: "s",
      synthesis: "syn"
    ]

    assert {:ok, result} = CollectStep.run(arguments, %{}, options)
    assert result.steps_completed == 2
    # Transcript order: the first result precedes the second.
    assert result.results =~ ~r/## Step 1: a.*## Step 2: b/s
  end

  test "flattens an iterative step's [gen, eval] list and counts both" do
    gen = %StepResult{name: "implement", template: "coder", result: "code"}
    eval = %StepResult{name: "verify", template: "verifier", result: "VERDICT: PASS"}

    arguments = %{step_1: [gen, eval]}
    options = [order: [{:step_1, nil}], skill_name: "iter", synthesis: "syn"]

    assert {:ok, result} = CollectStep.run(arguments, %{}, options)
    assert result.steps_completed == 2
    assert result.results =~ "implement"
    assert result.results =~ "verify"
  end

  test "skips a missing step_id (nil argument) without inflating the count" do
    arguments = %{step_1: %StepResult{name: "a", template: "coder", result: "x"}}
    options = [order: [{:step_1, "a"}, {:step_2, "b"}], skill_name: "s", synthesis: "syn"]

    assert {:ok, result} = CollectStep.run(arguments, %{}, options)
    assert result.steps_completed == 1
  end

  test "returns a JSON-safe map" do
    arguments = %{step_1: %StepResult{name: "a", template: "coder", result: "x"}}
    options = [order: [{:step_1, "a"}], skill_name: "s", synthesis: "syn"]

    assert {:ok, result} = CollectStep.run(arguments, %{}, options)
    assert {:ok, _json} = Jason.encode(result)
  end
end
