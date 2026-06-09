defmodule JidoClaw.Skills.Steps.AgentStep do
  @moduledoc """
  The sequential/dag leaf step of a compiled skill reactor.

  Reconstructs the step's context from its wired arguments — the
  dependency/preceding results (keyed by the `:upstream` `depends_on` set) and
  the producer/artifact results (keyed by the `:consumes` set) — formats it via
  `JidoClaw.Workflows.ContextBuilder`, injects the produces contract, then
  delegates the spawn/run/capture to `JidoClaw.Skills.Steps.AgentRunner`.

  `arguments` is keyed by upstream `:step_id` → `%StepResult{}` plus
  `:extra_context`. `options` (the impl tuple's keyword list) carries the
  step's static config: `:template`, `:task`, `:produces`, `:step_name` (the
  YAML name or `nil`), `:context_format` (`:deps` | `:preceding`), `:upstream`
  (`[{step_id, yaml_name}]`, the `depends_on` set), and `:consumes`
  (`[{step_id, yaml_name, produces_map}]`).
  """

  use Reactor.Step

  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.ContextBuilder
  alias JidoClaw.Workflows.StepResult

  @impl true
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(arguments, context, options) do
    template = Keyword.fetch!(options, :template)
    raw_task = Keyword.fetch!(options, :task)
    produces = Keyword.get(options, :produces)
    step_name = Keyword.get(options, :step_name)
    context_format = Keyword.get(options, :context_format, :deps)
    upstream = Keyword.get(options, :upstream, [])
    consumes = Keyword.get(options, :consumes, [])

    extra_context = Map.get(arguments, :extra_context, "")

    dep_context = build_dep_context(arguments, upstream, context_format)
    artifact_context = build_artifact_context(arguments, consumes)

    task = AgentRunner.inject_produces_instruction(raw_task, produces)
    full_task = ContextBuilder.build_task(task, extra_context, dep_context, artifact_context)

    AgentRunner.run(template, full_task, step_name, context)
  end

  # The dependency / preceding results, ordered oldest-first from `upstream`.
  defp build_dep_context(arguments, upstream, :preceding) do
    # `format_preceding_all/1` reverses its input (legacy prepend-order), so
    # pass the oldest-first list reversed to recover oldest-first output.
    upstream
    |> dep_results(arguments)
    |> Enum.reverse()
    |> ContextBuilder.format_preceding_all()
  end

  defp build_dep_context(arguments, upstream, :deps) do
    dep_names = Enum.map(upstream, fn {_id, yaml} -> yaml end)
    ContextBuilder.format_for_deps(dep_results(upstream, arguments), dep_names)
  end

  defp dep_results(upstream, arguments) do
    upstream
    |> Enum.map(fn {step_id, _yaml} -> Map.get(arguments, step_id) end)
    |> Enum.filter(&match?(%StepResult{}, &1))
  end

  # Artifact context from the `consumes` producers: their static `produces`
  # metadata (carried in the tuples) merged with the dynamic `artifacts` on
  # each producer's `%StepResult{}` (pulled from `arguments` by step_id).
  defp build_artifact_context(_arguments, []), do: ""

  defp build_artifact_context(arguments, consumes) do
    producer_results =
      consumes
      |> Enum.map(fn {step_id, _yaml, _produces} -> Map.get(arguments, step_id) end)
      |> Enum.filter(&match?(%StepResult{}, &1))

    producer_steps =
      Enum.map(consumes, fn {_step_id, yaml, produces} -> %{name: yaml, produces: produces} end)

    consuming_step = %{consumes: Enum.map(consumes, fn {_id, yaml, _p} -> yaml end)}

    ContextBuilder.format_artifact_context(consuming_step, producer_steps, producer_results)
  end
end
