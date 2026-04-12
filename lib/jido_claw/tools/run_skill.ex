defmodule JidoClaw.Tools.RunSkill do
  @moduledoc """
  Runs a named multi-step skill through a jido_composer Workflow FSM.

  Each skill step becomes a state in the FSM backed by `StepAction`, with
  transitions wired as step_1 -> step_2 -> ... -> done. Errors transition
  to :failed. The workflow is built dynamically from the cached YAML
  skill definition at runtime.

  Supports three execution modes:
  - `:sequential` — steps run one after another via SkillWorkflow FSM
  - `:dag` — steps with `depends_on` run in parallel phases via PlanWorkflow
  - `:iterative` — generator-evaluator loop via IterativeWorkflow
  """

  use Jido.Action,
    name: "run_skill",
    description:
      "Run a named multi-step skill that orchestrates multiple agents via a Workflow FSM. Each step spawns an agent, waits for completion, then transitions to the next step. Use /skills to list available skills.",
    schema: [
      skill: [
        type: :string,
        required: true,
        doc: "Skill name to run (e.g. full_review, refactor_safe, explore_codebase)"
      ],
      context: [
        type: :string,
        required: false,
        doc: "Additional context or instructions appended to each step's task"
      ]
    ]

  alias JidoClaw.Workflows.StepResult

  @impl true
  def run(params, context) do
    skill_name = params.skill
    extra_context = Map.get(params, :context, "")
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()

    case JidoClaw.Skills.get(skill_name, project_dir) do
      {:error, reason} ->
        {:error, reason}

      {:ok, skill} ->
        {mode, executor} =
          case JidoClaw.Skills.execution_mode(skill) do
            :iterative ->
              {"iterative", &JidoClaw.Workflows.IterativeWorkflow.run/3}

            :dag ->
              {"DAG", &JidoClaw.Workflows.PlanWorkflow.run/3}

            :sequential ->
              {"sequential", &JidoClaw.Workflows.SkillWorkflow.run/3}
          end

        IO.puts(
          "  \e[33m▸\e[0m \e[1mRunning skill:\e[0m #{skill.name} (#{length(skill.steps)} steps, #{mode})"
        )

        case executor.(skill, extra_context, project_dir) do
          {:ok, results} ->
            {:ok, build_result(skill, results)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  def build_result(skill, results) do
    # Convert %StepResult{} structs to {label, text} tuples at the boundary
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
      |> Enum.map(fn {{step_name, result}, idx} ->
        "## Step #{idx}: #{step_name}\n\n#{result}"
      end)
      |> Enum.join("\n\n---\n\n")

    %{
      skill: skill.name,
      steps_completed: length(tuples),
      synthesis_prompt: skill.synthesis,
      results: steps_output,
      message:
        "Skill '#{skill.name}' completed #{length(tuples)} steps. " <>
          "Synthesis directive: #{skill.synthesis}\n\n#{steps_output}"
    }
  end
end
