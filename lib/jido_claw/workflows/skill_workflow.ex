defmodule JidoClaw.Workflows.SkillWorkflow do
  @moduledoc """
  Builds and executes jido_composer Workflows from YAML skill definitions at runtime.

  Converts each skill step into an ActionNode backed by `StepAction`, wires up
  FSM transitions (step_1 -> step_2 -> ... -> done), and runs the workflow
  synchronously via Machine + Strategy.

  This replaces the hand-rolled sequential `Enum.reduce_while` in RunSkill with
  a proper FSM that supports error handling, state tracking, and future extensions
  like FanOut for parallel steps.
  """

  alias Jido.Composer.Workflow.Machine
  alias Jido.Composer.Node.ActionNode
  alias JidoClaw.Workflows.{ContextBuilder, StepResult}
  require Logger

  @doc """
  Execute a skill as a jido_composer Workflow.

  Takes a `%JidoClaw.Skills{}` struct and optional context, builds an FSM,
  and runs each step sequentially through the Machine.

  Returns `{:ok, results}` with a list of `%StepResult{}` structs,
  or `{:error, reason}` if any step fails.
  """
  @spec run(JidoClaw.Skills.t(), String.t(), String.t()) :: {:ok, list()} | {:error, term()}
  def run(skill, extra_context \\ "", project_dir \\ File.cwd!()) do
    steps = skill.steps
    step_count = length(steps)

    if step_count == 0 do
      {:error, "Skill '#{skill.name}' has no steps"}
    else
      # Build state names: :step_1, :step_2, ..., :step_N
      state_names = for i <- 1..step_count, do: :"step_#{i}"

      # Build nodes: each state maps to an ActionNode wrapping StepAction
      nodes =
        steps
        |> Enum.with_index(1)
        |> Enum.map(fn {_step, idx} ->
          state_name = :"step_#{idx}"
          {:ok, node} = ActionNode.new(JidoClaw.Workflows.StepAction)
          {state_name, node}
        end)
        |> Map.new()

      # Build transitions: step_1 :ok -> step_2, step_2 :ok -> step_3, ..., step_N :ok -> :done
      transitions =
        state_names
        |> Enum.chunk_every(2, 1, [:done])
        |> Enum.map(fn
          [current, next] -> {{current, :ok}, next}
        end)
        |> Map.new()
        |> Map.put({:_, :error}, :failed)

      # Create FSM
      machine =
        Machine.new(
          initial: :step_1,
          nodes: nodes,
          transitions: transitions,
          terminal_states: [:done, :failed]
        )

      # Execute steps sequentially through the FSM
      execute_machine(machine, steps, extra_context, project_dir)
    end
  end

  # Walk the FSM: at each non-terminal state, run the corresponding step's action,
  # apply the result, and transition.
  defp execute_machine(machine, steps, extra_context, project_dir) do
    execute_loop(machine, steps, extra_context, project_dir, [])
  end

  defp execute_loop(machine, steps, extra_context, project_dir, results) do
    if Machine.terminal?(machine) do
      if machine.status == :done do
        {:ok, Enum.reverse(results)}
      else
        {:error, "Workflow failed at state #{machine.status}"}
      end
    else
      # Current state is :step_N — extract the step index
      step_idx = state_to_index(machine.status)
      step = Enum.at(steps, step_idx - 1)

      template_name = Map.get(step, "template") || Map.get(step, :template)
      task = Map.get(step, "task") || Map.get(step, :task)
      step_name = Map.get(step, "name") || Map.get(step, :name) || template_name

      # Build context from all preceding step results
      preceding_context = ContextBuilder.format_preceding_all(results)

      full_task = ContextBuilder.build_task(task, extra_context, preceding_context, "")

      IO.puts(
        "  \e[2m  step #{step_idx}: #{template_name} — #{String.slice(task, 0, 60)}...\e[0m"
      )

      # Execute the step action
      params = %{
        template: template_name,
        task: full_task,
        project_dir: project_dir,
        name: step_name
      }

      case JidoClaw.Workflows.StepAction.run(params, %{}) do
        {:ok, %StepResult{} = step_result} ->
          # Apply result to machine context and transition to next state
          machine = Machine.apply_result(machine, step_result)

          case Machine.transition(machine, :ok) do
            {:ok, machine} ->
              results = [step_result | results]
              execute_loop(machine, steps, extra_context, project_dir, results)

            {:error, reason} ->
              {:error, "Transition failed after step #{step_idx}: #{inspect(reason)}"}
          end

        {:error, reason} ->
          Logger.warning("[SkillWorkflow] Step #{step_idx} (#{template_name}) failed: #{reason}")
          {:error, "Step #{step_idx} (#{template_name}) failed: #{reason}"}
      end
    end
  end

  defp state_to_index(state) do
    state
    |> Atom.to_string()
    |> String.replace_prefix("step_", "")
    |> String.to_integer()
  end
end
