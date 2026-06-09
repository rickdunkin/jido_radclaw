defmodule JidoClaw.Skills.Result do
  @moduledoc """
  Builds a skill run's final, JSON-safe result map from its accumulated
  step results.

  Relocated from `JidoClaw.Tools.RunSkill.build_result/2` so the terminal
  `JidoClaw.Skills.Steps.CollectStep` can assemble the result from its own
  options without reconstructing a partial `%JidoClaw.Skills{}` struct. Takes
  `skill_name` and `synthesis` directly.

  Converts `%JidoClaw.Workflows.StepResult{}` structs (and legacy
  `{label, text}` tuples) into a numbered step transcript that the synthesis
  prompt references. The returned map carries only strings/integers/nil, so it
  passes `ReactorMiddleware`'s `json_safe?/1` guard and persists into
  `WorkflowRun.result` unchanged.
  """

  alias JidoClaw.Workflows.StepResult

  @doc """
  Assemble the final tool-result map from a skill name + synthesis directive
  plus the list of step results emitted by the run.

  `%StepResult{}` structs become `{label, text}` tuples (`name || template`)
  at the boundary; the numbered transcript is the human/synthesis-facing
  rendering. `steps_completed` is the count of step results received.
  """
  @spec build(String.t() | nil, String.t() | nil, [StepResult.t() | {String.t(), String.t()}]) ::
          %{
            skill: String.t() | nil,
            steps_completed: non_neg_integer(),
            synthesis_prompt: String.t() | nil,
            results: String.t(),
            message: String.t()
          }
  def build(skill_name, synthesis, results) do
    tuples =
      Enum.map(results, fn
        %StepResult{name: name, template: template, result: result} ->
          label = name || template
          {label, result}

        {label, result} ->
          {label, result}
      end)

    steps_output =
      tuples
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n---\n\n", fn {{step_name, result}, idx} ->
        "## Step #{idx}: #{step_name}\n\n#{result}"
      end)

    steps_completed = length(tuples)

    %{
      skill: skill_name,
      steps_completed: steps_completed,
      synthesis_prompt: synthesis,
      results: steps_output,
      message:
        "Skill '#{skill_name}' completed #{steps_completed} steps. " <>
          "Synthesis directive: #{synthesis}\n\n#{steps_output}"
    }
  end
end
