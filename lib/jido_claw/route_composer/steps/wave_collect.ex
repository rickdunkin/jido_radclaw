defmodule JidoClaw.RouteComposer.Steps.WaveCollect do
  @moduledoc """
  The terminal step of a composer wave reactor (AR-2 §5/§7).

  Unlike `JidoClaw.Skills.Steps.CollectStep`, which text-collapses results via
  `JidoClaw.Skills.Result.build/3` (discarding the typed output the mappers
  read), `WaveCollect` holds the typed `%JidoClaw.Workflows.StepResult{}` list in
  memory and runs each stage's `emit` mapper, returning a **json-safe map**:

      %{"wave_index" => n,
        "emissions" => [%{"stage" => s, "signals" => [...], "artifacts" => %{name => value}}]}

  The map is mandatory and must be json-safe: this return lands in the child
  `WorkflowRun.result` (an Ash `:map`), and `ReactorMiddleware.complete/2`
  collapses any struct/tuple to `%{}` (`json_safe?/1`). So it never returns a
  `%StageEmission{}` / `%StepResult{}` / tuple / bare list — the composer
  rehydrates the structs from this map via `StageEmission.from_map/1`.

  A mapper error (an undeclared signal, a reviewer without a lens) returns
  `{:error, _}`, failing the wave loudly. `emit: {:mapper, _}` and any non-
  `%StepResult{}` argument (an iterative `[gen, eval]` shape) are explicit loud
  errors — out of Phase-1 fixture scope.
  """

  use Reactor.Step

  alias JidoClaw.RouteComposer.Emit.DefaultMapper
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.Workflows.StepResult

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(arguments, _context, options) do
    stage_meta = Keyword.fetch!(options, :stage_meta)
    wave_index = Keyword.fetch!(options, :wave_index)

    case collect(arguments, stage_meta) do
      {:ok, emissions} -> {:ok, %{"wave_index" => wave_index, "emissions" => emissions}}
      {:error, _reason} = error -> error
    end
  end

  defp collect(arguments, stage_meta) do
    folded =
      Enum.reduce_while(stage_meta, {:ok, []}, fn {step_id, meta}, {:ok, acc} ->
        case run_mapper(Map.get(arguments, step_id), meta) do
          {:ok, emission} -> {:cont, {:ok, [to_map(emission) | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case folded do
      {:ok, emissions} -> {:ok, Enum.reverse(emissions)}
      {:error, _reason} = error -> error
    end
  end

  defp run_mapper(%StepResult{} = result, %{emit: :default} = meta),
    do: DefaultMapper.map(result, meta)

  defp run_mapper(%StepResult{}, %{emit: {:mapper, _name}}), do: {:error, :mapper_not_registered}

  defp run_mapper(other, %{name: name}), do: {:error, {:missing_step_result, name, other}}

  defp to_map(%StageEmission{} = emission) do
    %{"stage" => emission.stage, "signals" => emission.signals, "artifacts" => emission.artifacts}
  end
end
