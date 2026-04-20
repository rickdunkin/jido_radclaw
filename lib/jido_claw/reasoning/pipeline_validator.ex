defmodule JidoClaw.Reasoning.PipelineValidator do
  @moduledoc """
  Shared normalization and validation for RunPipeline stages.

  Used by both the tool's inline path (`JidoClaw.Tools.RunPipeline`) and
  the YAML-loading path (`JidoClaw.Reasoning.PipelineStore`). Keeping both
  callers on a single implementation ensures a YAML-defined pipeline and
  an inline pipeline go through the exact same rules.

  Error-message strings are a consumer contract — `RunPipeline`'s moduledoc
  advertises them and tests grep for them. Don't reword without auditing
  call sites.

  ## Normalization

  `normalize_stage/1` accepts maps with either atom or string keys (YAML
  parsers return string-keyed maps; Elixir callers pass atom-keyed maps)
  and always returns atom-keyed maps.

  ## Validation

  `validate_stage/2` checks that the stage's strategy resolves to a
  concrete non-react, non-selector strategy. Selectors (`auto`, `adaptive`)
  are rejected — pipelines chain concrete reasoning per stage. React is
  rejected because the current `Reason.react` branch is a structured-prompt
  stub, not a full ReAct loop.
  """

  alias JidoClaw.Reasoning.StrategyRegistry

  @type stage :: %{
          :strategy => String.t(),
          :context_mode => String.t(),
          :prompt_override => String.t() | nil,
          :max_context_bytes => pos_integer() | nil
        }

  @doc """
  Normalize a list of stage maps to atom-keyed form.

  Returns `{:ok, [stage]}` when every entry is a well-formed map, or
  `{:error, reason}` on the first bad entry (strings carry the stage index
  when relevant).
  """
  @spec normalize_stages(term()) :: {:ok, [stage()]} | {:error, String.t()}
  def normalize_stages([]), do: {:error, "stages must be a non-empty list"}

  def normalize_stages(stages) when is_list(stages) do
    Enum.reduce_while(stages, {:ok, []}, fn stage, {:ok, acc} ->
      case normalize_stage(stage) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  def normalize_stages(_), do: {:error, "stages must be a list"}

  @doc """
  Normalize a single stage map to atom-keyed form.

  Rejects non-maps and stages without a string `strategy` key. Default
  `context_mode` is `"previous"` when absent. `max_context_bytes`, when
  present, must be a positive integer.
  """
  @spec normalize_stage(term()) :: {:ok, stage()} | {:error, String.t()}
  def normalize_stage(stage) when is_map(stage) do
    strategy = fetch_key(stage, :strategy) || fetch_key(stage, "strategy")

    context_mode =
      fetch_key(stage, :context_mode) || fetch_key(stage, "context_mode") || "previous"

    prompt_override =
      fetch_key(stage, :prompt_override) || fetch_key(stage, "prompt_override")

    raw_max_context_bytes =
      fetch_key(stage, :max_context_bytes) || fetch_key(stage, "max_context_bytes")

    cond do
      not is_binary(strategy) ->
        {:error, "each stage must have a string `strategy` key"}

      context_mode not in ["previous", "accumulate"] ->
        {:error,
         "stage context_mode must be \"previous\" or \"accumulate\" (got: #{inspect(context_mode)})"}

      not valid_max_context_bytes?(raw_max_context_bytes) ->
        {:error,
         "stage max_context_bytes must be a positive integer (got: #{inspect(raw_max_context_bytes)})"}

      true ->
        {:ok,
         %{
           strategy: strategy,
           context_mode: context_mode,
           prompt_override: prompt_override,
           max_context_bytes: raw_max_context_bytes
         }}
    end
  end

  def normalize_stage(_), do: {:error, "each stage must be a map"}

  @doc """
  Returns true when `value` is nil or a positive integer. Used for both
  per-stage and top-level `max_context_bytes`.
  """
  @spec valid_max_context_bytes?(term()) :: boolean()
  def valid_max_context_bytes?(nil), do: true
  def valid_max_context_bytes?(n) when is_integer(n) and n > 0, do: true
  def valid_max_context_bytes?(_), do: false

  @doc """
  Validate a list of already-normalized stages.

  Fails with the first offending stage's error (including 1-based index).
  """
  @spec validate_stages([stage()]) :: :ok | {:error, String.t()}
  def validate_stages(stages) when is_list(stages) and stages != [] do
    Enum.reduce_while(Enum.with_index(stages, 1), :ok, fn {stage, idx}, :ok ->
      case validate_stage(stage, idx) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  def validate_stages(_), do: {:error, "stages must be a non-empty list"}

  @doc """
  Validate a single normalized stage. Rejects selectors (`auto`/`adaptive`),
  unknown strategies, and any strategy that resolves (alias-aware) to react.
  """
  @spec validate_stage(stage(), pos_integer()) :: :ok | {:error, String.t()}
  def validate_stage(%{strategy: strategy}, idx) do
    cond do
      strategy in ["auto", "adaptive"] ->
        {:error,
         "stage #{idx}: strategy '#{strategy}' is a selector, not a concrete strategy. Pipelines chain concrete strategies (cot, tot, …) — pick one per stage."}

      not StrategyRegistry.valid?(strategy) ->
        {:error, "stage #{idx}: unknown strategy '#{strategy}'"}

      resolves_to_react?(strategy) ->
        {:error,
         "stage #{idx}: strategy '#{strategy}' resolves to react, which is the agent's native loop. Pipelines chain non-react strategies only — invoke the agent's ReAct loop after the pipeline's final output."}

      true ->
        :ok
    end
  end

  @doc "Returns true when `strategy` resolves (alias-aware) to the `:react` base."
  @spec resolves_to_react?(String.t()) :: boolean()
  def resolves_to_react?(strategy) do
    case StrategyRegistry.atom_for(strategy) do
      {:ok, :react} -> true
      _ -> false
    end
  end

  defp fetch_key(map, key), do: Map.get(map, key)
end
