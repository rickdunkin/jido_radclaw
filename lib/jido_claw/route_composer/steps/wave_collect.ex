defmodule JidoClaw.RouteComposer.Steps.WaveCollect do
  @moduledoc """
  The terminal step of a composer wave reactor (AR-2 §5/§7).

  Unlike `JidoClaw.Skills.Steps.CollectStep`, which text-collapses results via
  `JidoClaw.Skills.Result.build/3` (discarding the typed output the mappers
  read), `WaveCollect` holds the typed `%JidoClaw.Workflows.StepResult{}` list in
  memory and runs each stage's `emit` mapper. **Each artifact value is then
  persisted to an encrypted `:pending` `JidoClaw.Orchestration.ComposerArtifact`
  row (Phase 2b)** and only its opaque `art_<hex>` ref is emitted, so the
  json-safe terminal map carries refs, never values:

      %{"wave_index" => n,
        "emissions" => [%{"stage" => s, "signals" => [...], "artifacts" => %{name => ref}}]}

  The map is mandatory and must be json-safe: this return lands in the child
  `WorkflowRun.result` (an Ash `:map`), and `ReactorMiddleware.complete/2`
  collapses any struct/tuple to `%{}` (`json_safe?/1`). So it never returns a
  `%StageEmission{}` / `%StepResult{}` / tuple / bare list — the composer
  rehydrates the structs from this map via `StageEmission.from_map/1`.

  The wave's child `WorkflowRun` (created by `ReactorRunner` before
  `Reactor.run`) is read from the reactor `context` (`:workflow_run`,
  `:tenant`, `:actor`); `child_run_id`/`parent_run_id` come from it,
  `wave_index` from the step options. `store_pending`'s lineage guard always
  holds here — the child's `parent_run_id` *is* the composer parent.

  A mapper error (an undeclared signal, a reviewer without a lens) or an
  artifact-store failure returns `{:error, _}`, failing the wave loudly.
  `emit: {:mapper, _}` and any non-`%StepResult{}` argument (an iterative
  `[gen, eval]` shape) are explicit loud errors — out of fixture scope.
  """

  use Reactor.Step

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.RouteComposer.Emit.DefaultMapper
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.Workflows.StepResult

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(arguments, context, options) do
    stage_meta = Keyword.fetch!(options, :stage_meta)
    wave_index = Keyword.fetch!(options, :wave_index)

    case collect(arguments, stage_meta, context, wave_index) do
      {:ok, emissions} -> {:ok, %{"wave_index" => wave_index, "emissions" => emissions}}
      {:error, _reason} = error -> error
    end
  end

  defp collect(arguments, stage_meta, context, wave_index) do
    folded =
      Enum.reduce_while(stage_meta, {:ok, []}, fn {step_id, meta}, {:ok, acc} ->
        with {:ok, emission} <- run_mapper(Map.get(arguments, step_id), meta),
             {:ok, refs} <- persist_artifacts(emission, context, wave_index) do
          {:cont, {:ok, [to_map(emission, refs) | acc]}}
        else
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

  # Persist each `name => value` artifact as an encrypted `:pending` row,
  # returning `%{name => ref}`. Any store failure aborts the wave loudly
  # (P1 — a value must never fall back to inline).
  defp persist_artifacts(
         %StageEmission{artifacts: artifacts, stage: producer},
         context,
         wave_index
       ) do
    Enum.reduce_while(artifacts, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case store_one(name, producer, value, context, wave_index) do
        {:ok, ref} -> {:cont, {:ok, Map.put(acc, name, ref)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp store_one(name, producer, value, context, wave_index) do
    child = Map.fetch!(context, :workflow_run)

    ComposerArtifact.store_wave_artifact(name, producer, value, child, wave_index,
      tenant: Map.fetch!(context, :tenant),
      actor: Map.fetch!(context, :actor)
    )
  end

  defp to_map(%StageEmission{} = emission, ref_artifacts) do
    %{"stage" => emission.stage, "signals" => emission.signals, "artifacts" => ref_artifacts}
  end
end
