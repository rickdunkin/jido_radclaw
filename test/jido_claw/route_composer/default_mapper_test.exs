defmodule JidoClaw.RouteComposer.Emit.DefaultMapperTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Emit.DefaultMapper
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.Workflows.StepResult

  defp reviewer_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "quality-reviewer",
        emit: :default,
        lens: "quality",
        output: ["findings"],
        publishes: ["clean:quality", "findings:quality", "scope-shift"]
      },
      extra
    )
  end

  defp producer_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "planner",
        emit: :default,
        lens: nil,
        output: ["plan"],
        publishes: ["plan-ready", "scope-shift"]
      },
      extra
    )
  end

  describe "reviewer verdict" do
    test "approve + no findings → clean:<lens>" do
      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{"overall" => "approve", "findings" => []}
      }

      assert {:ok,
              %StageEmission{stage: "quality-reviewer", signals: ["clean:quality"]} = emission} =
               DefaultMapper.map(result, reviewer_meta())

      # the output-name mapping still produces a (here empty) findings artifact
      assert emission.artifacts == %{"findings" => []}
    end

    test "request_changes → findings:<lens> + findings artifact" do
      findings = [%{"severity" => "error", "description" => "bug"}]

      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{"overall" => "request_changes", "findings" => findings}
      }

      assert {:ok,
              %StageEmission{signals: ["findings:quality"], artifacts: %{"findings" => ^findings}}} =
               DefaultMapper.map(result, reviewer_meta())
    end

    test "a reviewer-shaped output with no lens is a coherence error" do
      result = %StepResult{name: "r", typed_output: %{"overall" => "approve", "findings" => []}}

      assert {:error, {:reviewer_without_lens, "r"}} =
               DefaultMapper.map(result, reviewer_meta(%{name: "r", lens: nil}))
    end
  end

  describe "explicit signals + output artifacts" do
    test "emits declared signals and maps each output name from typed_output" do
      result = %StepResult{
        name: "planner",
        typed_output: %{"signals" => ["plan-ready"], "plan" => "PLAN"}
      }

      assert {:ok, %StageEmission{signals: ["plan-ready"], artifacts: %{"plan" => "PLAN"}}} =
               DefaultMapper.map(result, producer_meta())
    end

    test "an output name absent from typed/artifacts falls back to the result text" do
      result = %StepResult{
        name: "planner",
        result: "TEXT",
        typed_output: %{"signals" => ["plan-ready"]}
      }

      assert {:ok, %StageEmission{artifacts: %{"plan" => "TEXT"}}} =
               DefaultMapper.map(result, producer_meta())
    end

    test "a signal outside publishes fails loudly (never silent-drop)" do
      result = %StepResult{name: "planner", typed_output: %{"signals" => ["surprise"]}}

      assert {:error, {:undeclared_signals, "planner", ["surprise"]}} =
               DefaultMapper.map(result, producer_meta())
    end
  end

  test "atom-keyed and string-keyed typed_output behave identically" do
    atom = %StepResult{name: "planner", typed_output: %{signals: ["plan-ready"], plan: "PLAN"}}

    string = %StepResult{
      name: "planner",
      typed_output: %{"signals" => ["plan-ready"], "plan" => "PLAN"}
    }

    assert DefaultMapper.map(atom, producer_meta()) == DefaultMapper.map(string, producer_meta())
  end
end
