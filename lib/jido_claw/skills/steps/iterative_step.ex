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

  ## Verdict normalization (camus C1-3)

  Evaluator output routes through
  `JidoClaw.Orchestration.Verdict.normalize(:iterative_eval, _)` — three exits,
  never a silent coercion. A real `:fail` burns an iteration as before; a
  garbled/missing verdict (`{:infra, _}`) re-runs the **evaluator only** (same
  iteration, same generator output) up to `:infra_retries` times, then
  terminates with an error — the old `parse_verdict/1` mapped those inputs to
  `:fail` and consumed an iteration exactly like a real fail, camus's "#1 cause
  of runaway loops". An evaluator `AgentRunner` `{:error, _}` joins the same
  infra lane (the composer wave-error symmetry — an evaluator run error is
  camus's exec-failure class); generator errors stay terminal (not a judge).

  `options` (the impl tuple's keyword list) carries `:generator` and
  `:evaluator` (normalized step maps extracted by `extract_roles/1`),
  `:max_iterations`, `:infra_retries` (the evaluator-infra budget, default
  `2` — separate from iterations), `:retry` (the generator's retry budget,
  threaded by the compiler), and `:irreversible` (OR over the two role steps —
  re-running the loop repeats every member step's effects). The only argument
  is `:extra_context`.

  ## Retry policy

  Like `AgentStep`, a bare `{:error, _}` is terminal in Reactor regardless of
  `max_retries`, so the `retry:` budget is a `compensate/4` policy: while
  `context[:retries_remaining]` is positive, `:retry` re-runs the whole loop
  from iteration 1. Capability is per-step via `can?/2` (`:compensate` iff
  `retry > 0`); the loop declares no cleanup, so it never reports `:undo`.
  """

  use Reactor.Step

  require Logger

  # The camus C1-3 normalizer — NOT JidoClaw.Triage.Verdict (different
  # subsystem; never alias both in one module).
  alias JidoClaw.Orchestration.Verdict
  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.ContextBuilder
  alias JidoClaw.Workflows.StepNormalizer
  alias JidoClaw.Workflows.StepResult

  import JidoClaw.Skills.Steps.RetryBudget, only: [retry_budget: 1, positive_remaining?: 1]

  @default_max_iterations 3
  @default_infra_retries 2

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(arguments, context, options) do
    generator = Keyword.fetch!(options, :generator)
    evaluator = Keyword.fetch!(options, :evaluator)
    max_iter = Keyword.get(options, :max_iterations) || @default_max_iterations
    infra_retries = Keyword.get(options, :infra_retries) || @default_infra_retries
    extra_context = Map.get(arguments, :extra_context, "")

    config = %{
      extra_context: extra_context,
      reactor_context: context,
      max_iter: max_iter,
      infra_retries: infra_retries
    }

    iterate(generator, evaluator, config, 1, nil)
  end

  # Per-step capability from the impl options — the generated
  # `function_exported?` default would report every iterative step
  # compensate-capable because this module exports compensate/4.
  @impl Reactor.Step
  def can?(%{impl: {_mod, options}}, :compensate) when is_list(options),
    do: retry_budget(options) > 0

  def can?(step, capability), do: super(step, capability)

  # Reactor dispatches `compensate(reason, arguments, context, options)` —
  # options LAST. `:retry` while budget remains; otherwise the error stands.
  @impl Reactor.Step
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

  # The evaluator context builds ONCE per iteration; the inner attempt loop
  # (`attempt_evaluator/5`) re-runs the evaluator on the same context/generator
  # output when its verdict is infra.
  defp run_evaluator(generator, evaluator, config, iteration, gen_result) do
    eval_dep_context = ContextBuilder.format_all([gen_result])

    artifact_context =
      ContextBuilder.format_artifact_context(evaluator, [generator], [gen_result])

    eval_context =
      ContextBuilder.build_task(
        evaluator.task,
        config.extra_context,
        eval_dep_context,
        artifact_context
      )

    round = %{iteration: iteration, gen_result: gen_result, eval_context: eval_context}
    attempt_evaluator(generator, evaluator, config, round, 0)
  end

  # One evaluator attempt under the three-exit normalizer contract (camus C1-3):
  # a clean verdict returns, a fail burns an ITERATION (unchanged semantics), an
  # `{:infra, _}` exit re-runs the EVALUATOR ONLY on the separate
  # `infra_retries` budget, and `{:inconclusive, _}` (item 5's verify authority
  # produces it, but never on this iterative-eval path) is a defensive terminal
  # error. An evaluator `AgentRunner` `{:error, _}` joins the infra retry lane —
  # an evaluator run error is camus's exec-failure class.
  defp attempt_evaluator(generator, evaluator, config, round, infra_attempt) do
    case AgentRunner.run(
           evaluator.template,
           round.eval_context,
           evaluator.name,
           config.reactor_context
         ) do
      {:ok, %StepResult{} = eval_result} ->
        handle_eval_verdict(eval_result, generator, evaluator, config, round, infra_attempt)

      {:error, reason} ->
        retry_or_fail_infra(
          {:evaluator_run_failed, reason},
          generator,
          evaluator,
          config,
          round,
          infra_attempt
        )
    end
  end

  defp handle_eval_verdict(eval_result, generator, evaluator, config, round, infra_attempt) do
    case Verdict.normalize(:iterative_eval, eval_result.typed_output || eval_result.result) do
      {:verdict, %Verdict{clean?: true}} ->
        {:ok, [round.gen_result, eval_result]}

      {:verdict, _fail} ->
        iterate(
          generator,
          evaluator,
          config,
          round.iteration + 1,
          {round.gen_result, eval_result}
        )

      {:infra, reason} ->
        retry_or_fail_infra(reason, generator, evaluator, config, round, infra_attempt)

      {:inconclusive, reason} ->
        {:error, "Evaluator inconclusive: #{Verdict.format_reason(reason)}"}
    end
  end

  # Re-run the evaluator (same iteration, same generator output) while the
  # infra budget lasts; exhausted → terminal (the step's compensate/retry
  # budget applies as for any other error). NEVER `iterate/5` — an infra exit
  # must not consume an iteration like a real fail.
  defp retry_or_fail_infra(reason, generator, evaluator, config, round, infra_attempt) do
    if infra_attempt < config.infra_retries do
      Logger.warning(
        "[IterativeStep] Evaluator infra (#{Verdict.format_reason(reason)}), " <>
          "retry #{infra_attempt + 1}/#{config.infra_retries}"
      )

      attempt_evaluator(generator, evaluator, config, round, infra_attempt + 1)
    else
      {:error,
       "Evaluator infra failure after #{config.infra_retries} retries: " <>
         Verdict.format_reason(reason)}
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
