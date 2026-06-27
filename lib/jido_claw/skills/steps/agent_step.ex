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
  (`[{step_id, yaml_name}]`, the `depends_on` set), `:consumes`
  (`[{step_id, yaml_name, produces_map}]`), and the saga metadata `:retry` /
  `:compensate` / `:irreversible`.

  ## Saga callbacks (`retry:` / `compensate:` / `irreversible:`)

  Reactor retries a step **only** on a `:retry` return — a bare `{:error, _}`
  is terminal regardless of `max_retries` — so the YAML `retry:` budget is a
  *policy* implemented in `compensate/4`: while `context[:retries_remaining]`
  is positive it returns `:retry` (Reactor caps attempts via the step's
  `max_retries`); once exhausted, a declared `compensate:` cleanup task runs
  via `AgentRunner` (`:ok` = compensated), otherwise the original error stands.
  `undo/4` runs the same cleanup task when a *later* step fails and the saga
  unwinds this completed step.

  Capability is per-step via the `can?/2` override (not blanket module
  exports): `:compensate` iff `retry > 0` or `compensate:` declared; `:undo`
  iff `compensate:` declared **and not** `irreversible: true`. A step with
  neither flag reports no capability — Reactor skips the callbacks entirely,
  which is operationally different from a no-op `:ok` undo (undo stack,
  `fully_reversible?`, replay gates).
  """

  use Reactor.Step

  require Logger

  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.ContextBuilder
  alias JidoClaw.Workflows.StepResult

  import JidoClaw.Skills.Steps.RetryBudget, only: [retry_budget: 1, positive_remaining?: 1]

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(arguments, context, options) do
    template = Keyword.fetch!(options, :template)
    raw_task = Keyword.fetch!(options, :task)
    produces = Keyword.get(options, :produces)
    step_name = Keyword.get(options, :step_name)
    # AR-6: the composer stage (wave-builder-only), distinct from `step_name`. `nil` for a
    # skill step, so a YAML step named like a catalog stage gets the template persona, not
    # the stage one.
    catalog_stage_name = Keyword.get(options, :catalog_stage_name)
    context_format = Keyword.get(options, :context_format, :deps)
    upstream = Keyword.get(options, :upstream, [])
    consumes = Keyword.get(options, :consumes, [])

    extra_context = Map.get(arguments, :extra_context, "")

    dep_context = build_dep_context(arguments, upstream, context_format)
    artifact_context = build_artifact_context(arguments, consumes)

    task = AgentRunner.inject_produces_instruction(raw_task, produces)
    full_task = ContextBuilder.build_task(task, extra_context, dep_context, artifact_context)

    AgentRunner.run(template, full_task, step_name, context, catalog_stage_name)
  end

  # Per-step capability, derived from the impl options — NOT the generated
  # `function_exported?` default, which would make every agent step report
  # compensate/undo-capable because this module exports both.
  @impl Reactor.Step
  def can?(%{impl: {_mod, options}}, :compensate) when is_list(options),
    do: retry_budget(options) > 0 or cleanup_declared?(options)

  def can?(%{impl: {_mod, options}}, :undo) when is_list(options),
    do: cleanup_declared?(options) and not irreversible?(options)

  def can?(step, capability), do: super(step, capability)

  # The `retry:` policy + `compensate:` cleanup. Reactor dispatches this as
  # `compensate(reason, arguments, context, options)` — options LAST.
  @impl Reactor.Step
  @spec compensate(term(), Reactor.inputs(), Reactor.context(), keyword()) ::
          :retry | :ok | {:error, term()}
  def compensate(reason, _arguments, context, options) do
    retries_remaining = Map.get(context, :retries_remaining, 0)

    cond do
      retry_budget(options) > 0 and positive_remaining?(retries_remaining) ->
        :retry

      cleanup_declared?(options) ->
        run_cleanup(options, context, "compensate")

      true ->
        {:error, reason}
    end
  end

  # Saga unwind of a *completed* step (a later step failed). Runs the declared
  # cleanup task; only reachable when `can?(:undo)` (cleanup declared and not
  # irreversible).
  @impl Reactor.Step
  @spec undo(term(), Reactor.inputs(), Reactor.context(), keyword()) :: :ok | {:error, term()}
  def undo(_value, _arguments, context, options) do
    run_cleanup(options, context, "undo")
  end

  defp cleanup_declared?(options) do
    case Keyword.get(options, :compensate) do
      task when is_binary(task) -> String.trim(task) != ""
      _ -> false
    end
  end

  defp irreversible?(options), do: Keyword.get(options, :irreversible, false) == true

  # The declared cleanup task, run through the same spawn/run/capture core as
  # the step itself. Success -> :ok (compensated/undone); failure -> an honest
  # {:error, _} — reporting "compensated" for a failed cleanup would put a lie
  # in the durable event log.
  defp run_cleanup(options, context, phase) do
    template = Keyword.fetch!(options, :template)
    task = Keyword.fetch!(options, :compensate)
    step_name = Keyword.get(options, :step_name)

    case AgentRunner.run(template, task, cleanup_name(step_name, phase), context) do
      {:ok, %StepResult{}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[AgentStep] #{phase} cleanup failed for step #{step_name || "(unnamed)"}: " <>
            inspect(reason)
        )

        {:error, {:cleanup_failed, reason}}
    end
  end

  defp cleanup_name(nil, phase), do: "(#{phase})"
  defp cleanup_name(step_name, phase), do: "#{step_name} (#{phase})"

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
