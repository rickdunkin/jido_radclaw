defmodule JidoClaw.RouteComposer.WaveBuilder do
  @moduledoc """
  Builds one Kahn level (a composer wave) into a runnable `%Reactor{}` (AR-2 §5).

  Mirrors `JidoClaw.Skills.Compiler.build_graph/3`: `Builder.new` →
  `add_input(:extra_context)` → one `JidoClaw.Skills.Steps.AgentStep` per stage →
  a terminal `JidoClaw.RouteComposer.Steps.WaveCollect` → `Builder.return`. The
  stage steps form a flat parallel batch — each reads **only** `:extra_context`
  (no intra-wave `from_result` edges, since same-Kahn-level stages are
  independent; all cross-wave data arrives via the formatted `:extra_context`).

  **Worker-only.** Every unit must be `{:worker_template, _}`; a `{:gate, _}` /
  `{:seed, _}` / `{:skill, _}` unit is rejected with `{:error, {:unsupported_unit,
  name, unit}}` (gates/seed/skill are later phases, and `AgentStep` requires a
  `template:`, `agent_step.ex:52`). An oversized wave (more stages than
  `JidoClaw.Workflows.StepIds.max/0`) returns `{:error, :wave_too_large}` rather
  than crashing — a backstop, since a wave is a single Kahn level.
  """

  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.Steps.WaveCollect
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Workflows.StepIds
  alias Reactor.Argument
  alias Reactor.Builder

  @collect_id :__collect__

  @doc """
  Build `stages` (a list of `%Stage{}`, one Kahn level) into `{:ok, %Reactor{}}`,
  or `{:error, reason}` on a non-worker unit or an oversized wave.

  Options: `:wave_index` (stamped into `WaveCollect`; default `0`).
  """
  @spec build_wave([Stage.t()], keyword()) :: {:ok, Reactor.t()} | {:error, term()}
  def build_wave(stages, opts \\ []) do
    wave_index = Keyword.get(opts, :wave_index, 0)

    with :ok <- validate_units(stages),
         :ok <- validate_size(stages) do
      build(Enum.with_index(stages, 1), wave_index)
    end
  end

  defp validate_units(stages) do
    case Enum.find(stages, fn %Stage{unit: unit} -> not match?({:worker_template, _}, unit) end) do
      nil -> :ok
      %Stage{name: name, unit: unit} -> {:error, {:unsupported_unit, name, unit}}
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
    options = [
      template: template,
      task: stage.task,
      step_name: stage.name,
      context_format: :deps,
      upstream: [],
      consumes: []
    ]

    Builder.add_step(reactor, step_id!(idx), {AgentStep, options}, [input_arg()],
      async?: true,
      max_retries: 0
    )
  end

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
