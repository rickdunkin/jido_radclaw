defmodule JidoClaw.Skills.Steps.IterativeStep do
  @moduledoc """
  The single step of a compiled iterative skill reactor — a generator/evaluator
  refinement loop, ported from the retired `JidoClaw.Workflows.IterativeWorkflow`.

  The generator produces output; the evaluator reviews it and returns a verdict
  (`:pass`/`:fail`). The loop continues until the evaluator passes or
  `max_iterations` is reached, feeding the latest evaluator feedback back into
  the next generator turn. Returns `{:ok, [gen_result, eval_result]}` — the
  final generator output (the implementation) followed by the final evaluator
  output.

  `options` (the impl tuple's keyword list) carries `:generator` and
  `:evaluator` (normalized step maps extracted by `extract_roles/1`),
  `:max_iterations`, `:retry` (the generator's retry budget, threaded by
  the compiler), and `:irreversible` (OR over the two role steps — re-running
  the loop repeats every member step's effects). The only argument is
  `:extra_context`.

  ## Retry policy

  Like `AgentStep`, a bare `{:error, _}` is terminal in Reactor regardless of
  `max_retries`, so the `retry:` budget is a `compensate/4` policy: while
  `context[:retries_remaining]` is positive, `:retry` re-runs the whole loop
  from iteration 1. Capability is per-step via `can?/2` (`:compensate` iff
  `retry > 0`); the loop declares no cleanup, so it never reports `:undo`.
  """

  use Reactor.Step

  require Logger

  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.ContextBuilder
  alias JidoClaw.Workflows.StepNormalizer
  alias JidoClaw.Workflows.StepResult

  @default_max_iterations 3

  @impl true
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(arguments, context, options) do
    generator = Keyword.fetch!(options, :generator)
    evaluator = Keyword.fetch!(options, :evaluator)
    max_iter = Keyword.get(options, :max_iterations) || @default_max_iterations
    extra_context = Map.get(arguments, :extra_context, "")

    config = %{
      extra_context: extra_context,
      reactor_context: context,
      max_iter: max_iter
    }

    iterate(generator, evaluator, config, 1, nil)
  end

  # Per-step capability from the impl options — the generated
  # `function_exported?` default would report every iterative step
  # compensate-capable because this module exports compensate/4.
  @impl true
  def can?(%{impl: {_mod, options}}, :compensate) when is_list(options),
    do: retry_budget(options) > 0

  def can?(step, capability), do: super(step, capability)

  # Reactor dispatches `compensate(reason, arguments, context, options)` —
  # options LAST. `:retry` while budget remains; otherwise the error stands.
  @impl true
  @spec compensate(term(), Reactor.inputs(), Reactor.context(), keyword()) ::
          :retry | {:error, term()}
  def compensate(reason, _arguments, context, options) do
    remaining = Map.get(context, :retries_remaining, 0)

    if retry_budget(options) > 0 and positive_remaining?(remaining) do
      :retry
    else
      {:error, reason}
    end
  end

  defp retry_budget(options) do
    case Keyword.get(options, :retry, 0) do
      retry when is_integer(retry) and retry >= 0 -> retry
      _ -> 0
    end
  end

  defp positive_remaining?(:infinity), do: true
  defp positive_remaining?(remaining) when is_integer(remaining), do: remaining > 0
  defp positive_remaining?(_), do: false

  @doc """
  Extract generator and evaluator steps from a skill by `role` field.

  Returns `{:ok, generator, evaluator}` or `{:error, reason}`. The compiler
  calls this to validate an iterative skill at compile time and to build the
  step's options. The role maps carry the fields the loop consumes
  (`name`/`template`/`task`/`role`/`produces`/`consumes`) plus the saga
  metadata the compiler threads onto the loop step: `retry` (raw — the
  compiler normalizes) and `irreversible` (strict boolean). `compensate` is
  deliberately dropped (the loop has no undo), as is `depends_on`
  (meaningless for the fixed gen→eval order).
  """
  @spec extract_roles(JidoClaw.Skills.t()) :: {:ok, map(), map()} | {:error, String.t()}
  def extract_roles(skill) do
    steps =
      skill.steps
      |> StepNormalizer.normalize()
      |> Enum.map(&normalize_step/1)

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
  Parse a verdict from evaluator output.

  Accepts either a typed map (`%{verdict: :pass | :fail | atom}`, the shape
  Verifier emits via Jido.AI structured output) or the legacy free-form text
  containing `VERDICT: PASS` / `VERDICT: FAIL`. Falls through to `:fail` on any
  unrecognised input — conservative because a missing/garbled verdict should
  not be treated as success.
  """
  @spec parse_verdict(map() | String.t() | nil) :: :pass | :fail
  def parse_verdict(%{verdict: :pass}), do: :pass
  def parse_verdict(%{verdict: :fail}), do: :fail
  def parse_verdict(%{"verdict" => "pass"}), do: :pass
  def parse_verdict(%{"verdict" => "fail"}), do: :fail

  def parse_verdict(text) when is_binary(text) do
    # Find the LAST VERDICT: token — earlier mentions may be instructions like
    # "To get VERDICT: PASS, fix X" followed by "VERDICT: FAIL".
    case Regex.scan(~r/VERDICT:\s*(PASS|FAIL)/i, text) do
      [] ->
        :fail

      matches ->
        # "Last VERDICT wins" is intentional (see comment above); Regex.scan
        # results are bounded by the small number of verdict tokens an LLM emits.
        # credo:disable-for-next-line ExSlop.Check.Refactor.ListLast
        if String.upcase(List.last(matches) |> List.last()) == "PASS", do: :pass, else: :fail
    end
  end

  def parse_verdict(_), do: :fail

  @doc """
  Build the return value when the iteration cap is reached.

  Returns `{:ok, [gen_result, eval_result]}` preserving the last generator
  output (the implementation) in the first slot rather than the evaluator
  feedback.
  """
  @spec cap_result(StepResult.t(), StepResult.t()) :: {:ok, [StepResult.t()]}
  def cap_result(%StepResult{} = last_gen_result, %StepResult{} = last_eval_result) do
    {:ok, [last_gen_result, last_eval_result]}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # The last argument is `{last_gen_result, last_eval_result}` — the most recent
  # outputs from both sides, so the cap can return the generator result rather
  # than the evaluator feedback.
  defp iterate(_generator, _evaluator, %{max_iter: max_iter}, iteration, {last_gen, last_eval})
       when iteration > max_iter do
    Logger.info("[IterativeStep] Max iterations (#{max_iter}) reached, returning last result")
    cap_result(last_gen, last_eval)
  end

  defp iterate(generator, evaluator, config, iteration, last_pair) do
    %{extra_context: extra_context, reactor_context: reactor_context} = config

    last_eval_result = if is_tuple(last_pair), do: elem(last_pair, 1), else: last_pair

    gen_context = generator_context(generator, extra_context, last_eval_result)

    case AgentRunner.run(generator.template, gen_context, generator.name, reactor_context) do
      {:ok, %StepResult{} = gen_result} ->
        run_evaluator(generator, evaluator, config, iteration, gen_result)

      {:error, reason} ->
        Logger.warning("[IterativeStep] Generator failed: #{reason}")
        {:error, "Generator step failed: #{reason}"}
    end
  end

  # First iteration = extra_context only; subsequent = extra_context + latest
  # evaluator feedback only.
  defp generator_context(generator, extra_context, nil) do
    generator.task
    |> ContextBuilder.build_task(extra_context, "", "")
    |> AgentRunner.inject_produces_instruction(generator.produces)
  end

  defp generator_context(generator, extra_context, last_eval_result) do
    feedback = ContextBuilder.format_all([last_eval_result])

    generator.task
    |> ContextBuilder.build_task(extra_context, feedback, "")
    |> AgentRunner.inject_produces_instruction(generator.produces)
  end

  defp run_evaluator(generator, evaluator, config, iteration, gen_result) do
    %{extra_context: extra_context, reactor_context: reactor_context} = config

    eval_dep_context = ContextBuilder.format_all([gen_result])

    artifact_context =
      ContextBuilder.format_artifact_context(evaluator, [generator], [gen_result])

    eval_context =
      ContextBuilder.build_task(evaluator.task, extra_context, eval_dep_context, artifact_context)

    case AgentRunner.run(evaluator.template, eval_context, evaluator.name, reactor_context) do
      {:ok, %StepResult{} = eval_result} ->
        case parse_verdict(eval_result.typed_output || eval_result.result) do
          :pass ->
            {:ok, [gen_result, eval_result]}

          :fail ->
            iterate(generator, evaluator, config, iteration + 1, {gen_result, eval_result})
        end

      {:error, reason} ->
        Logger.warning("[IterativeStep] Evaluator failed: #{reason}")
        {:error, "Evaluator step failed: #{reason}"}
    end
  end

  defp normalize_step(step) do
    %{
      name: Map.get(step, :name),
      template: Map.get(step, :template),
      task: Map.get(step, :task),
      role: Map.get(step, :role),
      produces: normalize_map_field(step, :produces),
      consumes: normalize_list_field(step, :consumes),
      # Saga metadata — preserved so the compiler can thread retry/irreversible
      # onto the loop step (values validated by Compiler.validate_step_metadata/1).
      retry: Map.get(step, :retry),
      irreversible: Map.get(step, :irreversible) == true
    }
  end

  defp normalize_map_field(step, key) do
    case Map.get(step, key) do
      v when is_map(v) -> v
      _ -> nil
    end
  end

  defp normalize_list_field(step, key) do
    case Map.get(step, key) do
      v when is_list(v) -> Enum.map(v, &to_string/1)
      _ -> []
    end
  end
end
