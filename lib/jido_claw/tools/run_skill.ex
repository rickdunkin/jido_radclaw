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
    category: "skills",
    tags: ["skills", "exec"],
    output_schema: [
      skill: [type: :string, required: true],
      steps_completed: [type: :integer, required: true],
      synthesis_prompt: [type: :string],
      results: [type: :string, required: true],
      message: [type: :string, required: true]
    ],
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

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Workflows.IterativeWorkflow
  alias JidoClaw.Workflows.PlanWorkflow
  alias JidoClaw.Workflows.SkillWorkflow
  alias JidoClaw.Workflows.StepResult

  @impl true
  def run(params, context) do
    MCPScope.wrap(:run_skill, params, context, fn enriched -> do_run(params, enriched) end)
  end

  defp do_run(params, context) do
    skill_name = params.skill
    extra_context = Map.get(params, :context, "")
    tool_context = Map.get(context, :tool_context, %{}) || %{}
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
    workspace_id = Map.get(tool_context, :workspace_id)

    scope_context = scope_context(tool_context)

    case JidoClaw.Skills.get(skill_name, project_dir) do
      {:error, reason} ->
        {:error, reason}

      {:ok, skill} ->
        result =
          case JidoClaw.Skills.execution_mode(skill) do
            :iterative ->
              IterativeWorkflow.run(
                skill,
                extra_context,
                project_dir,
                workspace_id: workspace_id,
                scope_context: scope_context
              )

            :dag ->
              PlanWorkflow.run(
                skill,
                extra_context,
                project_dir,
                workspace_id: workspace_id,
                scope_context: scope_context
              )

            :sequential ->
              SkillWorkflow.run(
                skill,
                extra_context,
                project_dir,
                workspace_id: workspace_id,
                scope_context: scope_context
              )
          end

        case result do
          {:ok, results} ->
            {:ok, build_result(skill, results)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Test seam: pluck the canonical scope keys out of `tool_context` for
  forwarding into every workflow driver. The full set (minus
  `:agent_id`, which each step assigns) propagates so child agents
  inherit the parent's tenant/session/workspace/user UUIDs and
  `:actor` for tenant-actor policy enforcement on Ash writes/reads.
  """
  def scope_context(tool_context) when is_map(tool_context) do
    Map.take(tool_context, [
      :tenant_id,
      :session_id,
      :session_uuid,
      :workspace_id,
      :workspace_uuid,
      :project_dir,
      :user_id,
      :actor
    ])
  end

  @doc """
  Test seam: assemble the final tool-result map from a skill plus the
  list of step results emitted by the workflow. Converts
  `%StepResult{}` structs to `{label, text}` tuples and renders the
  numbered step transcript that the synthesis prompt references.
  """
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
      |> Enum.map_join("\n\n---\n\n", fn {{step_name, result}, idx} ->
        "## Step #{idx}: #{step_name}\n\n#{result}"
      end)

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
