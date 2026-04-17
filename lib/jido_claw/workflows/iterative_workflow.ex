defmodule JidoClaw.Workflows.IterativeWorkflow do
  @moduledoc """
  Execute skills as generator-evaluator loops with iterative refinement.

  Steps are assigned roles (`generator` and `evaluator`). The generator
  produces output, the evaluator reviews it and emits a verdict
  (`VERDICT: PASS` or `VERDICT: FAIL`). The loop continues until the
  evaluator passes or `max_iterations` is reached.

  ## YAML format

      name: robust_feature
      mode: iterative
      max_iterations: 5
      steps:
        - name: implement
          role: generator
          template: coder
          task: "Implement the feature"
          produces:
            type: elixir_module
        - name: evaluate
          role: evaluator
          template: verifier
          task: "Verify: run tests, review code. End with VERDICT: PASS or VERDICT: FAIL."
          consumes: [implement]
      synthesis: "Present final implementation"
  """

  alias JidoClaw.Workflows.{ContextBuilder, StepAction, StepResult}
  require Logger

  @default_max_iterations 3

  @doc """
  Execute a skill using iterative generator-evaluator loops.

  Returns `{:ok, [%StepResult{}, %StepResult{}]}` — exactly two entries:
  the final generator result and the final evaluator result.

  Options:
    * `:workspace_id` — threaded to every generator and evaluator step so
      they share the caller's VFS + shell session. When omitted,
      `StepAction.resolve_workspace_id/3` falls back to a per-step id
      (legacy behavior, used by unit tests and ad-hoc callers).
  """
  @spec run(JidoClaw.Skills.t(), String.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def run(skill, extra_context \\ "", project_dir \\ File.cwd!(), opts \\ []) do
    max_iter = skill.max_iterations || @default_max_iterations
    workspace_id = Keyword.get(opts, :workspace_id)

    case extract_roles(skill) do
      {:ok, generator, evaluator} ->
        IO.puts(
          "  \e[33m▸\e[0m \e[1mIterative mode:\e[0m " <>
            "generator=#{generator.name}, evaluator=#{evaluator.name}, max=#{max_iter}"
        )

        iterate(
          generator,
          evaluator,
          extra_context,
          project_dir,
          workspace_id,
          max_iter,
          1,
          nil
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec build_step_params(map(), String.t(), String.t(), String.t() | nil) :: map()
  def build_step_params(step, task, project_dir, workspace_id) do
    %{
      template: step.template,
      task: task,
      project_dir: project_dir,
      name: step.name
    }
    |> maybe_put(:workspace_id, workspace_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Extract generator and evaluator steps from a skill by `role` field.

  Returns `{:ok, generator, evaluator}` or `{:error, reason}`.
  """
  @spec extract_roles(JidoClaw.Skills.t()) :: {:ok, map(), map()} | {:error, String.t()}
  def extract_roles(skill) do
    steps = Enum.map(skill.steps, &normalize_step/1)

    generator = Enum.find(steps, fn s -> s.role == "generator" end)
    evaluator = Enum.find(steps, fn s -> s.role == "evaluator" end)

    cond do
      is_nil(generator) ->
        {:error, "Iterative skill '#{skill.name}' has no step with role: generator"}

      is_nil(evaluator) ->
        {:error, "Iterative skill '#{skill.name}' has no step with role: evaluator"}

      is_nil(generator.name) ->
        {:error, "Generator step must have a name field"}

      is_nil(evaluator.name) ->
        {:error, "Evaluator step must have a name field"}

      true ->
        {:ok, generator, evaluator}
    end
  end

  @doc """
  Parse a verdict from evaluator output text.

  Returns `:pass`, `:fail`, or `:fail` (conservative default when no match).
  """
  @spec parse_verdict(String.t()) :: :pass | :fail
  def parse_verdict(text) when is_binary(text) do
    # Find the LAST VERDICT: token — earlier mentions may be instructions
    # like "To get VERDICT: PASS, fix X" followed by "VERDICT: FAIL".
    case Regex.scan(~r/VERDICT:\s*(PASS|FAIL)/i, text) do
      [] ->
        :fail

      matches ->
        if String.upcase(List.last(matches) |> List.last()) == "PASS", do: :pass, else: :fail
    end
  end

  def parse_verdict(_), do: :fail

  @doc """
  Build the return value when the iteration cap is reached.

  Returns `{:ok, [gen_result, eval_result]}` preserving the last generator
  output (the implementation) in the first slot rather than the evaluator
  feedback. Exposed for regression testing.
  """
  @spec cap_result(StepResult.t(), StepResult.t()) :: {:ok, [StepResult.t()]}
  def cap_result(%StepResult{} = last_gen_result, %StepResult{} = last_eval_result) do
    {:ok, [last_gen_result, last_eval_result]}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # The last argument is `{last_gen_result, last_eval_result}` — a tuple carrying
  # the most recent outputs from both sides so the max-iteration cap can return
  # the correct generator result rather than the evaluator feedback.
  defp iterate(
         _generator,
         _evaluator,
         _extra_context,
         _project_dir,
         _workspace_id,
         max_iter,
         iteration,
         {last_gen_result, last_eval_result}
       )
       when iteration > max_iter do
    Logger.info("[IterativeWorkflow] Max iterations (#{max_iter}) reached, returning last result")
    cap_result(last_gen_result, last_eval_result)
  end

  defp iterate(
         generator,
         evaluator,
         extra_context,
         project_dir,
         workspace_id,
         max_iter,
         iteration,
         last_pair
       ) do
    last_eval_result = if is_tuple(last_pair), do: elem(last_pair, 1), else: last_pair
    IO.puts("  \e[36m  ⟳ iteration #{iteration}/#{max_iter}\e[0m")

    # Build generator context: first iteration = extra_context only;
    # subsequent = extra_context + latest evaluator feedback only
    gen_context =
      if last_eval_result do
        feedback = ContextBuilder.format_all([last_eval_result])

        ContextBuilder.build_task(
          generator.task,
          extra_context,
          feedback,
          ""
        )
      else
        ContextBuilder.build_task(generator.task, extra_context, "", "")
      end

    # Inject ARTIFACTS instruction if generator has produces
    gen_context = StepAction.inject_produces_instruction(gen_context, generator.produces)

    IO.puts("  \e[2m  [generate] #{generator.name} (#{generator.template})\e[0m")

    gen_params = build_step_params(generator, gen_context, project_dir, workspace_id)

    case StepAction.run(gen_params, %{}) do
      {:ok, %StepResult{} = gen_result} ->
        # Build evaluator context with generator output + artifact metadata
        eval_dep_context = ContextBuilder.format_all([gen_result])

        artifact_context =
          ContextBuilder.format_artifact_context(
            evaluator,
            [generator],
            [gen_result]
          )

        eval_context =
          ContextBuilder.build_task(
            evaluator.task,
            extra_context,
            eval_dep_context,
            artifact_context
          )

        IO.puts("  \e[2m  [evaluate] #{evaluator.name} (#{evaluator.template})\e[0m")

        eval_params = build_step_params(evaluator, eval_context, project_dir, workspace_id)

        case StepAction.run(eval_params, %{}) do
          {:ok, %StepResult{} = eval_result} ->
            case parse_verdict(eval_result.result) do
              :pass ->
                IO.puts("  \e[32m  ✓ VERDICT: PASS (iteration #{iteration})\e[0m")
                {:ok, [gen_result, eval_result]}

              :fail ->
                IO.puts("  \e[33m  ✗ VERDICT: FAIL (iteration #{iteration})\e[0m")

                iterate(
                  generator,
                  evaluator,
                  extra_context,
                  project_dir,
                  workspace_id,
                  max_iter,
                  iteration + 1,
                  {gen_result, eval_result}
                )
            end

          {:error, reason} ->
            Logger.warning("[IterativeWorkflow] Evaluator failed: #{reason}")
            {:error, "Evaluator step failed: #{reason}"}
        end

      {:error, reason} ->
        Logger.warning("[IterativeWorkflow] Generator failed: #{reason}")
        {:error, "Generator step failed: #{reason}"}
    end
  end

  defp normalize_step(step) do
    %{
      name: Map.get(step, "name") || Map.get(step, :name),
      template: Map.get(step, "template") || Map.get(step, :template),
      task: Map.get(step, "task") || Map.get(step, :task),
      role: Map.get(step, "role") || Map.get(step, :role),
      produces: normalize_map_field(step, "produces"),
      consumes: normalize_list_field(step, "consumes")
    }
  end

  defp normalize_map_field(step, key) do
    case Map.get(step, key) || Map.get(step, String.to_existing_atom(key)) do
      v when is_map(v) -> v
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_list_field(step, key) do
    case Map.get(step, key) || Map.get(step, String.to_existing_atom(key)) do
      v when is_list(v) -> Enum.map(v, &to_string/1)
      _ -> []
    end
  rescue
    ArgumentError -> []
  end
end
