defmodule JidoClaw.Tools.RunPipeline do
  @moduledoc """
  Sequential composition of non-react reasoning strategies.

  Each stage runs a named strategy on a composed prompt and feeds its output
  into the next stage. The pipeline fail-fasts any stage whose strategy
  resolves (alias-aware) to `react` — ReAct is the agent's native loop, and
  the current react branch of `Reason` is a structured-prompt stub that
  wouldn't be useful mid-pipeline. For "plan then act" flows, invoke this
  tool for the planning chain and let the agent's native ReAct loop act on
  the final output.

  ## Stage shape (inline only in 0.4.2; YAML deferred)

      %{
        "strategy" => "cot",          # required; built-in name or user alias
        "context_mode" => "previous", # optional: "previous" (default) | "accumulate"
        "prompt_override" => "..."    # optional; wins unconditionally when set
      }

  ## Context modes

    * `"previous"` (default) — stage N receives the initial prompt plus the
      immediate prior stage output.
    * `"accumulate"` — stage N receives the initial prompt plus all prior
      stage outputs joined with stage headers. **Token-budget footgun**:
      unbounded; long pipelines can blow context windows. 0.4.3 may add a
      `max_context_bytes` cap if users hit this.

  `prompt_override` wins over any context mode when present.

  ## Telemetry

  Each stage writes a `reasoning_outcomes` row with:
    * `execution_kind: :pipeline_run`
    * `pipeline_name` + zero-padded `pipeline_stage` (e.g., `"001/003"`)
    * `metadata.stage_index` + `metadata.stage_total` (integers, for numeric
      sort without parsing the padded string)
    * `base_strategy` set to the resolved built-in

  On mid-pipeline error, earlier rows persist normally (the async writer
  has already fired) and the failing stage's row is written with
  `status: :error` by `Telemetry.with_outcome/4`.
  """

  use Jido.Action,
    name: "run_pipeline",
    description:
      "Run a sequence of reasoning strategies, feeding each stage's output into the next. For multi-stage analysis: CoT planning → ToT exploration → CoD summary.",
    category: "reasoning",
    tags: ["reasoning", "pipeline"],
    schema: [
      pipeline_name: [
        type: :string,
        required: true,
        doc: "Identifier for this pipeline run (used in telemetry)."
      ],
      prompt: [
        type: :string,
        required: true,
        doc: "Initial problem or question."
      ],
      stages: [
        type: {:list, :map},
        required: true,
        doc:
          "Non-empty list of stage maps. Each requires `strategy`; optional `context_mode` (previous|accumulate) and `prompt_override`."
      ]
    ],
    output_schema: [
      pipeline_name: [type: :string, required: true],
      stages: [type: {:list, :map}, required: true],
      final_output: [type: :string, required: true],
      usage: [type: :map]
    ]

  alias JidoClaw.Reasoning.{StrategyRegistry, Telemetry}

  @impl true
  def run(params, context) do
    pipeline_name = params.pipeline_name
    prompt = params.prompt
    raw_stages = params.stages

    tool_context = Map.get(context, :tool_context, %{}) || %{}
    workspace_id = Map.get(tool_context, :workspace_id)
    project_dir = Map.get(tool_context, :project_dir)
    agent_id = Map.get(tool_context, :agent_id)
    forge_session_key = Map.get(tool_context, :forge_session_key)
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)

    with {:ok, stages} <- normalize_stages(raw_stages),
         :ok <- validate_stages(stages) do
      execute(pipeline_name, prompt, stages,
        runner: runner,
        workspace_id: workspace_id,
        project_dir: project_dir,
        agent_id: agent_id,
        forge_session_key: forge_session_key
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Stage-map normalization
  # ---------------------------------------------------------------------------

  # Elixir callers pass atom keys; JSON-routed tool invocations pass string
  # keys. Normalize to atom keys for internal use.
  defp normalize_stages([]), do: {:error, "stages must be a non-empty list"}

  defp normalize_stages(stages) when is_list(stages) do
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

  defp normalize_stages(_), do: {:error, "stages must be a list"}

  defp normalize_stage(stage) when is_map(stage) do
    strategy = fetch_string_key(stage, :strategy) || fetch_string_key(stage, "strategy")

    context_mode =
      fetch_string_key(stage, :context_mode) || fetch_string_key(stage, "context_mode") ||
        "previous"

    prompt_override =
      fetch_string_key(stage, :prompt_override) || fetch_string_key(stage, "prompt_override")

    cond do
      not is_binary(strategy) ->
        {:error, "each stage must have a string `strategy` key"}

      context_mode not in ["previous", "accumulate"] ->
        {:error,
         "stage context_mode must be \"previous\" or \"accumulate\" (got: #{inspect(context_mode)})"}

      true ->
        {:ok,
         %{
           strategy: strategy,
           context_mode: context_mode,
           prompt_override: prompt_override
         }}
    end
  end

  defp normalize_stage(_), do: {:error, "each stage must be a map"}

  defp fetch_string_key(map, key) when is_map(map) do
    cond do
      is_atom(key) -> Map.get(map, key)
      is_binary(key) -> Map.get(map, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage validation (fail-fast, no LLM calls yet)
  # ---------------------------------------------------------------------------

  defp validate_stages(stages) when is_list(stages) and stages != [] do
    Enum.reduce_while(Enum.with_index(stages, 1), :ok, fn {stage, idx}, :ok ->
      case validate_stage(stage, idx) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_stage(%{strategy: strategy}, idx) do
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

  defp resolves_to_react?(strategy) do
    case StrategyRegistry.atom_for(strategy) do
      {:ok, :react} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Execution loop
  # ---------------------------------------------------------------------------

  defp execute(pipeline_name, initial_prompt, stages, wrap_opts) do
    total = length(stages)
    runner = Keyword.fetch!(wrap_opts, :runner)
    workspace_id = Keyword.get(wrap_opts, :workspace_id)
    project_dir = Keyword.get(wrap_opts, :project_dir)
    agent_id = Keyword.get(wrap_opts, :agent_id)
    forge_session_key = Keyword.get(wrap_opts, :forge_session_key)

    result =
      stages
      |> Enum.with_index(1)
      |> Enum.reduce_while(
        {:ok, %{outputs: [], last: initial_prompt, usage: empty_usage()}},
        fn {stage, idx}, {:ok, acc} ->
          stage_prompt = compose_prompt(stage, initial_prompt, acc)
          user_strategy = stage.strategy
          {:ok, base_atom} = StrategyRegistry.atom_for(user_strategy)
          base_name = Atom.to_string(base_atom)

          opts = [
            execution_kind: :pipeline_run,
            base_strategy: base_name,
            pipeline_name: pipeline_name,
            pipeline_stage: pad_stage(idx, total),
            workspace_id: workspace_id,
            project_dir: project_dir,
            agent_id: agent_id,
            forge_session_key: forge_session_key,
            metadata: %{stage_index: idx, stage_total: total}
          ]

          case Telemetry.with_outcome(user_strategy, stage_prompt, opts, fn ->
                 run_stage(runner, base_atom, stage_prompt)
               end) do
            {:ok, res} ->
              {:cont, {:ok, append_stage(acc, idx, user_strategy, res)}}

            {:error, reason} ->
              {:halt, {:error, format_stage_error(idx, user_strategy, reason)}}
          end
        end
      )

    case result do
      {:ok, acc} ->
        {:ok,
         %{
           pipeline_name: pipeline_name,
           stages: Enum.reverse(acc.outputs),
           final_output: acc.last,
           usage: acc.usage
         }}

      err ->
        err
    end
  end

  defp run_stage(runner, base_atom, prompt) do
    runner.run(%{strategy: base_atom, prompt: prompt, timeout: 60_000}, %{})
  end

  defp append_stage(%{outputs: outputs, usage: usage} = acc, idx, user_strategy, result) do
    output = extract_output(result)

    stage_record = %{
      stage: idx,
      strategy: user_strategy,
      output: output,
      status: :ok
    }

    merged_usage = merge_usage(usage, Map.get(result, :usage, %{}))

    %{acc | outputs: [stage_record | outputs], last: output, usage: merged_usage}
  end

  defp compose_prompt(%{prompt_override: override}, _initial, _acc) when is_binary(override),
    do: override

  defp compose_prompt(%{context_mode: "accumulate"}, initial, %{outputs: outputs}) do
    parts =
      outputs
      |> Enum.reverse()
      |> Enum.map(fn %{stage: i, output: out} -> "## Stage #{i} output\n#{out}" end)

    case parts do
      [] -> initial
      _ -> initial <> "\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp compose_prompt(%{context_mode: "previous"}, initial, %{outputs: [], last: _}),
    do: initial

  defp compose_prompt(%{context_mode: "previous"}, initial, %{last: last}) do
    initial <> "\n\n## Prior stage output\n" <> last
  end

  # Zero-pad to 3 digits so "10/12" sorts after "02/12" as text. In addition,
  # metadata.stage_index carries the raw integer for numeric consumers.
  defp pad_stage(idx, total) do
    width = max(3, total |> Integer.to_string() |> String.length())
    "#{pad(idx, width)}/#{pad(total, width)}"
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  defp extract_output(%{output: output}) when is_binary(output) and output != "", do: output

  defp extract_output(%{output: output}) when is_map(output) do
    cond do
      Map.has_key?(output, :result) -> output.result
      Map.has_key?(output, :answer) -> output.answer
      Map.has_key?(output, :conclusion) -> output.conclusion
      true -> inspect(output)
    end
  end

  defp extract_output(%{output: output}), do: inspect(output)
  defp extract_output(result), do: inspect(result)

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0}

  defp merge_usage(acc, usage) when is_map(usage) do
    %{
      input_tokens:
        (acc[:input_tokens] || 0) +
          (Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0),
      output_tokens:
        (acc[:output_tokens] || 0) +
          (Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0)
    }
  end

  defp merge_usage(acc, _), do: acc

  defp format_stage_error(idx, user_strategy, reason) do
    "pipeline stage #{idx} (#{user_strategy}) failed: #{format_reason(reason)}"
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
