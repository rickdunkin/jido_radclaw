defmodule JidoClaw.Skills.Steps.CollectStep do
  @moduledoc """
  The terminal step of every compiled skill reactor — it produces the run's
  durable result.

  Depends on **every** agent/iterative step (not just the leaves) so no result
  is dropped, reorders the received results by the configured step order, and
  calls `JidoClaw.Skills.Result.build/3` to assemble the JSON-safe result map
  (`%{skill, steps_completed, synthesis_prompt, results, message}`). That map is
  the reactor's return value, which `JidoClaw.Orchestration.ReactorMiddleware`
  persists into `WorkflowRun.result`.

  `arguments` carries each agent step's `%StepResult{}` (dag/sequential) or the
  `[gen_result, eval_result]` list (iterative), keyed by step_id. `options`
  carries `:order` (`[{step_id, yaml_name}]` for **all** agent steps, in
  declaration order), `:skill_name`, and `:synthesis`. `steps_completed` is the
  count of agent results received, so it is correct regardless of this
  synthetic step appearing in the `step_*` timeline.
  """

  use Reactor.Step

  alias JidoClaw.Skills.Result
  alias JidoClaw.Workflows.StepResult

  @impl Reactor.Step
  def run(arguments, _context, options) do
    order = Keyword.fetch!(options, :order)
    skill_name = Keyword.fetch!(options, :skill_name)
    synthesis = Keyword.get(options, :synthesis)

    results = collect_results(arguments, order)
    {:ok, Result.build(skill_name, synthesis, results)}
  end

  # Flatten each step_id's value in declaration order: a dag/sequential agent
  # yields one `%StepResult{}`, while an iterative one yields its
  # `[gen_result, eval_result]` list.
  defp collect_results(arguments, order) do
    Enum.flat_map(order, fn {step_id, _yaml} ->
      case Map.get(arguments, step_id) do
        %StepResult{} = result -> [result]
        results when is_list(results) -> results
        nil -> []
        other -> [other]
      end
    end)
  end
end
