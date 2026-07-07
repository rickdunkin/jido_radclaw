defmodule JidoClaw.RouteComposer.WaveBuilder do
  @moduledoc """
  Builds one Kahn level (a composer wave) into a runnable `%Reactor{}` (AR-2 §5).

  Mirrors `JidoClaw.Skills.Compiler.build_graph/3`: `Builder.new` →
  `add_input(:extra_context)` → one `JidoClaw.Skills.Steps.AgentStep` per stage →
  a terminal `JidoClaw.RouteComposer.Steps.WaveCollect` → `Builder.return`. The
  stage steps form a flat parallel batch — each reads **only** `:extra_context`
  (no intra-wave `from_result` edges, since same-Kahn-level stages are
  independent; all cross-wave data arrives via the formatted `:extra_context`).

  ## Wave shapes (AR-2 §14 Phase 4a)

  Three classified outcomes:

    * an **all-worker** cohort builds the struct path above → `{:ok, %Reactor{}}`;
    * a **solo gate** stage (`{:gate, name}`) resolves to its named
      `JidoClaw.Orchestration.Reactors.*` gate-producer reactor via
      `JidoClaw.RouteComposer.GateReactors` → `{:ok, {:module_reactor, module,
      inputs}}` (a gate **must** be a module, not a struct — the resume checkpoint
      keys on a module name, see `Reactors.PlanGate`'s moduledoc). The `inputs`
      carry `wave_index`/`stage_name`/`artifact_name`/`signal_name`; the loop
      supplies the gate input's `plan_ref` (the builder has no store access);
    * a gate **mixed** with any other stage, or more than one gate, is rejected
      `{:error, {:gate_must_be_solo_wave, names}}` — the router does not guarantee
      a gate is alone in its Kahn level (the shipped catalog co-locates `plan-gate`
      + `test-author` + `implementer`), so the loop peels a solo gate out before
      dispatch; this is the backstop.

  A `{:seed, _}` / `{:skill, _}` unit stays unsupported (`{:error,
  {:unsupported_unit, name, unit}}`; `AgentStep` requires a `template:`,
  `agent_step.ex:52`). An oversized worker wave (more stages than
  `JidoClaw.Workflows.StepIds.max/0`) returns `{:error, :wave_too_large}` rather
  than crashing — a backstop, since a wave is a single Kahn level.
  """

  alias JidoClaw.RouteComposer.GateReactors
  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.Steps.WaveCollect
  alias JidoClaw.RouteComposer.VerifyReactors
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Workflows.StepIds
  alias Reactor.Argument
  alias Reactor.Builder

  @collect_id :__collect__

  @doc """
  Build `stages` (a list of `%Stage{}`, one Kahn level) into a runnable wave.

  Returns `{:ok, %Reactor{}}` for an all-worker cohort, `{:ok, {:module_reactor,
  module, inputs}}` for a solo gate stage, `{:ok, {:verify_reactor, module,
  inputs}}` for a solo verify stage (item 5 — a NON-halting module reactor; the
  loop merges the run-scoped `project_dir`/`sealed_head`/`verify_override`
  inputs), or `{:error, reason}` on an unsupported unit, a mixed/multi
  gate/verify cohort, an unknown gate/verify, or an oversized worker wave.

  Options: `:wave_index` (stamped into `WaveCollect` / the gate inputs; default `0`).
  """
  @spec build_wave([Stage.t()], keyword()) ::
          {:ok, Reactor.t()}
          | {:ok, {:module_reactor, module(), map()}}
          | {:ok, {:verify_reactor, module(), map()}}
          | {:error, term()}
  def build_wave(stages, opts \\ []) do
    wave_index = Keyword.get(opts, :wave_index, 0)

    case classify(stages) do
      :workers ->
        with :ok <- validate_size(stages) do
          build(Enum.with_index(stages, 1), wave_index)
        end

      {:solo_gate, stage} ->
        build_gate_wave(stage, wave_index)

      {:solo_verify, stage} ->
        build_verify_wave(stage, wave_index)

      {:error, _reason} = error ->
        error
    end
  end

  # Classify the dispatch cohort: an all-worker cohort takes the struct path; a
  # lone gate/verify becomes a named module reactor; a gate or verify mixed
  # with any other stage (or >1 of either) is rejected (the loop peels a solo
  # gate and DEFERS a verify, so these are the backstops — the verify one
  # doubly so, since CatalogValidator invariant 10 already rejects >1 verify
  # stage per catalog at load). A `{:seed,_}`/`{:skill,_}` unit stays
  # unsupported.
  defp classify(stages) do
    {gates, non_gates} = Enum.split_with(stages, &gate?/1)
    {verifies, workers} = Enum.split_with(non_gates, &verify?/1)

    cond do
      gates == [] and verifies == [] ->
        classify_workers(workers)

      match?([_single], gates) and non_gates == [] ->
        {:solo_gate, hd(gates)}

      match?([_single], verifies) and gates == [] and workers == [] ->
        {:solo_verify, hd(verifies)}

      gates != [] ->
        {:error, {:gate_must_be_solo_wave, Enum.map(stages, & &1.name)}}

      true ->
        {:error, {:verify_must_be_solo_wave, Enum.map(stages, & &1.name)}}
    end
  end

  defp classify_workers(stages) do
    case Enum.find(stages, fn %Stage{unit: unit} -> not match?({:worker_template, _}, unit) end) do
      nil -> :workers
      %Stage{name: name, unit: unit} -> {:error, {:unsupported_unit, name, unit}}
    end
  end

  defp gate?(%Stage{unit: {:gate, _name}}), do: true
  defp gate?(%Stage{}), do: false

  defp verify?(%Stage{unit: {:verify, _name}}), do: true
  defp verify?(%Stage{}), do: false

  # A solo gate wave is dispatched as its named gate-producer reactor module
  # (Phase 4a). `GateReactors` bounds the gate name → `{module, signal}` (no
  # `String.to_atom` on the catalog-sourced name); the loop merges `plan_ref`
  # into these inputs (the builder has no store access).
  defp build_gate_wave(%Stage{unit: {:gate, gate_name}} = stage, wave_index) do
    case GateReactors.resolve(gate_name) do
      {module, signal} ->
        inputs = %{
          wave_index: wave_index,
          stage_name: stage.name,
          artifact_name: List.first(stage.output),
          signal_name: signal
        }

        {:ok, {:module_reactor, module, inputs}}

      nil ->
        {:error, {:unknown_gate, stage.name, gate_name}}
    end
  end

  # A solo verify wave is dispatched as its named verify-stage reactor module
  # (item 5 — the gate shape minus the park). `VerifyReactors` bounds the
  # verify name → module (no `String.to_atom` on the catalog-sourced name); the
  # loop merges the run-scoped `project_dir`/`sealed_head`/`verify_override`
  # inputs (the builder has no run-state access).
  defp build_verify_wave(%Stage{unit: {:verify, verify_name}} = stage, wave_index) do
    case VerifyReactors.resolve(verify_name) do
      nil ->
        {:error, {:unknown_verify, stage.name, verify_name}}

      module ->
        inputs = %{
          wave_index: wave_index,
          stage_name: stage.name,
          lens: stage.lens
        }

        {:ok, {:verify_reactor, module, inputs}}
    end
  end

  defp validate_size(stages) do
    if length(stages) <= StepIds.max(), do: :ok, else: {:error, :wave_too_large}
  end

  defp build(indexed, wave_index) do
    with {:ok, reactor} <- new_with_input(),
         {:ok, reactor} <- add_stage_steps(reactor, indexed),
         {:ok, reactor} <- add_collect(reactor, indexed, wave_index) do
      Builder.return(reactor, @collect_id)
    end
  end

  defp new_with_input, do: Builder.add_input(Builder.new(), :extra_context)

  defp add_stage_steps(reactor, indexed) do
    Enum.reduce_while(indexed, {:ok, reactor}, fn {stage, idx}, {:ok, acc} ->
      case add_stage_step(acc, stage, idx) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_stage_step(reactor, %Stage{unit: {:worker_template, template}} = stage, idx) do
    options =
      [
        template: template,
        task: stage.task,
        step_name: stage.name,
        # AR-6: the dedicated stage carrier, set ONLY here (the wave-builder path), distinct
        # from `step_name` (the StepResult label, which a skill step may name arbitrarily).
        # Steers per-stage persona resolution downstream; inert for the saga cleanup path.
        catalog_stage_name: stage.name,
        context_format: :deps,
        upstream: [],
        consumes: []
      ] ++ tier_opts(stage) ++ executor_opts(stage)

    Builder.add_step(reactor, step_id!(idx), {AgentStep, options}, [input_arg()],
      async?: true,
      max_retries: 0
    )
  end

  # AR-9: the per-stage tiering seam. Only DECLARED halves are put (an untiered
  # stage's options stay byte-identical to today's — never a present-nil key a
  # downstream `Keyword.get` default would be defeated by).
  defp tier_opts(%Stage{model: nil, effort: nil}), do: []

  defp tier_opts(%Stage{model: model, effort: effort}),
    do: Enum.reject([model: model, effort: effort], fn {_key, value} -> is_nil(value) end)

  # PR-4 (camus OQ-1(b)): the per-stage executor override, in the tier_opts
  # conditionally-put shape — a declared override rides the step options; an
  # undeclared stage's options stay byte-identical (never a present-nil key).
  defp executor_opts(%Stage{executor: nil}), do: []
  defp executor_opts(%Stage{executor: executor}), do: [executor: executor]

  defp add_collect(reactor, indexed, wave_index) do
    args = Enum.map(indexed, fn {_stage, idx} -> result_arg(step_id!(idx)) end)
    stage_meta = Map.new(indexed, fn {stage, idx} -> {step_id!(idx), meta(stage)} end)

    Builder.add_step(
      reactor,
      @collect_id,
      {WaveCollect, [stage_meta: stage_meta, wave_index: wave_index]},
      args,
      async?: true,
      max_retries: 0
    )
  end

  # The minimal stage projection the emit mapper needs (AR-2 §7).
  defp meta(%Stage{} = stage) do
    %{
      name: stage.name,
      emit: stage.emit,
      lens: stage.lens,
      output: stage.output,
      publishes: stage.publishes
    }
  end

  defp input_arg, do: Argument.from_input(:extra_context, :extra_context)

  defp result_arg(step_id), do: Argument.from_result(step_id, step_id)

  # The size is validated up front, so the `{:ok, id}` match always holds.
  defp step_id!(idx) do
    {:ok, id} = StepIds.fetch(idx)
    id
  end
end
