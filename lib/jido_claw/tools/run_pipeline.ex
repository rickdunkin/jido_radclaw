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

  ## Two ways to supply stages

    * **Inline `stages:`** — a list of stage maps passed at call time.
    * **`pipeline_ref:`** — a name that resolves via
      `JidoClaw.Reasoning.PipelineStore` to a YAML-declared pipeline under
      `.jido/pipelines/*.yaml`.

  **Precedence:** inline `stages` always win. When `stages` is supplied (even
  as an empty list or malformed entries) the tool runs — or fails — on that
  input; it never silently falls through to `pipeline_ref` on bad inline
  stages. When neither is supplied, the tool returns
  `"must supply pipeline_ref or stages"`.

  **`pipeline_name`:** the caller-supplied `pipeline_name` always wins over
  a YAML `name` for telemetry correlation. The YAML `name` is the lookup
  key only.

  ## Stage shape

      %{
        "strategy" => "cot",          # required; built-in name or user alias
        "context_mode" => "previous", # optional: "previous" (default) | "accumulate"
        "prompt_override" => "..."    # optional; wins unconditionally when set
      }

  ## Context modes

    * `"previous"` (default) — stage N receives the initial prompt plus the
      immediate prior stage output.
    * `"accumulate"` — stage N receives the initial prompt plus all prior
      stage outputs joined with stage headers. **Bounded** by
      `max_context_bytes` (see below).

  `prompt_override` wins over any context mode when present.

  ## `max_context_bytes` cap (accumulate mode only)

  Supplied at two levels:

    * Top-level tool param `max_context_bytes` — pipeline-wide default.
    * Per-stage `max_context_bytes` — overrides the pipeline-wide value
      for that stage.

  When the composed prompt exceeds the effective cap in `accumulate`
  mode, the oldest prior-stage outputs are **dropped as whole entries**
  (never mid-body truncation) until the composed prompt fits. The
  remaining prompt is suffixed with an elision notice of the form:

      [N earlier stage outputs elided to fit max_context_bytes]

  The notice's bytes are budgeted against the cap so
  `byte_size(final_prompt) <= cap` always holds once drops occurred.

  If even `initial_prompt + newest-prior-stage + notice` exceeds the
  cap, the pipeline fails-fast at that stage with:

      stage N: max_context_bytes (C) exceeded by initial prompt + most-recent stage output alone

  If the **initial prompt alone** exceeds the cap, stage 1 fails-fast with:

      stage 1: max_context_bytes (C) exceeded by initial prompt alone

  (no prior outputs exist to drop).

  Earlier stage rows persist as `:ok`; the failing stage row persists as
  `:error` with `metadata.failure_reason`, `metadata.accumulated_context_bytes_pre_cap`,
  and `metadata.dropped_stage_indexes`. On success where a drop occurred,
  `metadata` carries all three cap keys
  (`accumulated_context_bytes_pre_cap`, `accumulated_context_bytes_post_cap`,
  `dropped_stage_indexes`).

  `previous` mode ignores the cap with a one-line warning. The cap is
  byte-size only; token counts are not considered.

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
        required: false,
        doc:
          "Inline list of stage maps (wins over pipeline_ref when both supplied). Each requires `strategy`; optional `context_mode` (previous|accumulate) and `prompt_override`."
      ],
      pipeline_ref: [
        type: :string,
        required: false,
        doc:
          "Name of a pipeline declared in `.jido/pipelines/*.yaml`. Used only when `stages` is not supplied."
      ],
      max_context_bytes: [
        type: :pos_integer,
        required: false,
        doc:
          "Pipeline-wide byte cap for `accumulate`-mode composed prompts. Per-stage `max_context_bytes` overrides this. `previous` mode ignores the cap."
      ]
    ],
    output_schema: [
      pipeline_name: [type: :string, required: true],
      stages: [type: {:list, :map}, required: true],
      final_output: [type: :string, required: true],
      usage: [type: :map]
    ]

  alias JidoClaw.Reasoning.{PipelineStore, PipelineValidator, StrategyRegistry, Telemetry}

  @impl true
  def run(params, context) do
    pipeline_name = params.pipeline_name
    prompt = params.prompt

    tool_context = Map.get(context, :tool_context, %{}) || %{}
    workspace_id = Map.get(tool_context, :workspace_id)
    project_dir = Map.get(tool_context, :project_dir)
    agent_id = Map.get(tool_context, :agent_id)
    forge_session_key = Map.get(tool_context, :forge_session_key)
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)

    caller_cap = Map.get(params, :max_context_bytes)

    case resolve_stages_and_cap(params, caller_cap) do
      {:ok, stages, effective_pipeline_cap} ->
        wrap_opts = [
          runner: runner,
          workspace_id: workspace_id,
          project_dir: project_dir,
          agent_id: agent_id,
          forge_session_key: forge_session_key,
          pipeline_cap: effective_pipeline_cap
        ]

        execute(pipeline_name, prompt, stages, wrap_opts)

      {:error, _} = err ->
        err
    end
  end

  # Precedence: inline `stages` always win. An inline list that is empty or
  # contains malformed entries fails via PipelineValidator — it never
  # silently falls through to pipeline_ref.
  #
  # `is_list/1` as the discriminator is robust to whether Jido.Action leaves
  # absent optional keys as key-absent or nil-valued; nil fails `is_list`
  # and we fall through. Empty list is caught by `validate_stages/1`'s
  # non-empty rule.
  #
  # `pipeline_cap` = caller's `max_context_bytes` wins when set; otherwise
  # the YAML's top-level `max_context_bytes` when resolved via `pipeline_ref`;
  # otherwise nil.
  defp resolve_stages_and_cap(params, caller_cap) do
    inline = Map.get(params, :stages)
    ref = Map.get(params, :pipeline_ref)

    cond do
      is_list(inline) ->
        with {:ok, normalized} <- PipelineValidator.normalize_stages(inline),
             :ok <- PipelineValidator.validate_stages(normalized) do
          {:ok, normalized, caller_cap}
        end

      is_binary(ref) ->
        case PipelineStore.get(ref) do
          {:ok, %PipelineStore{stages: stages, max_context_bytes: yaml_cap}} ->
            # Re-validate at invocation time. Stages are already normalized at
            # load time, but the strategy they reference may have been deleted
            # since — so revalidation catches a now-stale alias cleanly.
            case PipelineValidator.validate_stages(stages) do
              :ok -> {:ok, stages, caller_cap || yaml_cap}
              err -> err
            end

          {:error, :not_found} ->
            {:error, "unknown pipeline '#{ref}'"}
        end

      true ->
        {:error, "must supply pipeline_ref or stages"}
    end
  end

  # ---------------------------------------------------------------------------
  # Execution loop
  # ---------------------------------------------------------------------------

  defp execute(pipeline_name, initial_prompt, stages, wrap_opts) do
    total = length(stages)
    runner = Keyword.fetch!(wrap_opts, :runner)
    pipeline_cap = Keyword.get(wrap_opts, :pipeline_cap)

    warn_if_previous_mode_cap_ignored(stages, pipeline_cap)

    result =
      stages
      |> Enum.with_index(1)
      |> Enum.reduce_while(
        {:ok, %{outputs: [], last: initial_prompt, usage: empty_usage()}},
        fn {stage, idx}, {:ok, acc} ->
          run_stage_in_loop(
            stage,
            idx,
            acc,
            initial_prompt,
            pipeline_name,
            total,
            pipeline_cap,
            runner,
            wrap_opts
          )
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

  defp run_stage_in_loop(
         stage,
         idx,
         acc,
         initial_prompt,
         pipeline_name,
         total,
         pipeline_cap,
         runner,
         wrap_opts
       ) do
    user_strategy = stage.strategy
    {:ok, base_atom} = StrategyRegistry.atom_for(user_strategy)
    base_name = Atom.to_string(base_atom)
    stage_cap = Map.get(stage, :max_context_bytes)

    case compose_and_cap(stage, initial_prompt, acc, stage_cap, pipeline_cap) do
      {:ok, stage_prompt, cap_meta} ->
        opts =
          base_telemetry_opts(idx, total, pipeline_name, base_name, wrap_opts, cap_meta)

        case Telemetry.with_outcome(user_strategy, stage_prompt, opts, fn ->
               run_stage(runner, base_atom, user_strategy, stage_prompt)
             end) do
          {:ok, res} ->
            {:cont, {:ok, append_stage(acc, idx, user_strategy, res)}}

          {:error, reason} ->
            {:halt, {:error, format_stage_error(idx, user_strategy, reason)}}
        end

      {:error, cap_reason, classification_prompt, cap_meta} ->
        reason = "stage #{idx}: #{cap_reason}"

        failure_metadata =
          cap_meta
          |> Map.put(:stage_index, idx)
          |> Map.put(:stage_total, total)
          |> Map.put(:failure_reason, reason)

        opts = [
          execution_kind: :pipeline_run,
          base_strategy: base_name,
          pipeline_name: pipeline_name,
          pipeline_stage: pad_stage(idx, total),
          workspace_id: Keyword.get(wrap_opts, :workspace_id),
          project_dir: Keyword.get(wrap_opts, :project_dir),
          agent_id: Keyword.get(wrap_opts, :agent_id),
          forge_session_key: Keyword.get(wrap_opts, :forge_session_key),
          metadata: failure_metadata
        ]

        # Route the cap failure back through with_outcome so the full
        # lifecycle fires (start/stop, classified signal, persisted row).
        # `classification_prompt` — the irreducible would-be request —
        # drives a meaningful `prompt_length` instead of the full pre-cap
        # bytes that would have never been sent.
        _ =
          Telemetry.with_outcome(
            user_strategy,
            classification_prompt,
            opts,
            fn -> {:error, reason} end
          )

        {:halt, {:error, reason}}
    end
  end

  defp base_telemetry_opts(idx, total, pipeline_name, base_name, wrap_opts, cap_meta) do
    metadata =
      cap_meta
      |> Map.put(:stage_index, idx)
      |> Map.put(:stage_total, total)

    [
      execution_kind: :pipeline_run,
      base_strategy: base_name,
      pipeline_name: pipeline_name,
      pipeline_stage: pad_stage(idx, total),
      workspace_id: Keyword.get(wrap_opts, :workspace_id),
      project_dir: Keyword.get(wrap_opts, :project_dir),
      agent_id: Keyword.get(wrap_opts, :agent_id),
      forge_session_key: Keyword.get(wrap_opts, :forge_session_key),
      metadata: metadata
    ]
  end

  # Warn once when the pipeline includes `previous`-mode stages AND any cap
  # is in effect (top-level or per-stage). Caps only apply in `accumulate`
  # mode; `previous` mode always sends `initial + last_output`, so a cap is
  # meaningless there.
  defp warn_if_previous_mode_cap_ignored(stages, pipeline_cap) do
    previous_stage_caps =
      Enum.filter(stages, fn stage ->
        stage.context_mode == "previous" and
          (Map.get(stage, :max_context_bytes) != nil or not is_nil(pipeline_cap))
      end)

    if previous_stage_caps != [] do
      require Logger

      Logger.warning(
        "[RunPipeline] max_context_bytes applies only to accumulate-mode stages; " <>
          "ignored for #{length(previous_stage_caps)} previous-mode stage(s)."
      )
    end

    :ok
  end

  defp run_stage(runner, base_atom, user_strategy, prompt) do
    run_params =
      %{strategy: base_atom, prompt: prompt, timeout: 60_000}
      |> Map.merge(StrategyRegistry.run_strategy_params_for(user_strategy))

    runner.run(run_params, %{})
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

  # Returns {:ok, prompt, cap_meta} on success or
  # {:error, reason, classification_prompt, cap_meta} when the cap is
  # exceeded by the irreducible (initial + newest-prior-stage + notice).
  #
  # `cap_meta` is `%{}` when no cap applied; otherwise populated with
  # `:accumulated_context_bytes_pre_cap`, `:accumulated_context_bytes_post_cap`
  # (success only), `:dropped_stage_indexes`.
  defp compose_and_cap(
         %{prompt_override: override},
         _initial,
         _acc,
         _stage_cap,
         _pipeline_cap
       )
       when is_binary(override) do
    # prompt_override bypasses composition — cap does not apply.
    {:ok, override, %{}}
  end

  defp compose_and_cap(
         %{context_mode: "previous"} = stage,
         initial,
         acc,
         _stage_cap,
         _pipeline_cap
       ) do
    # `previous` mode ignores any cap (warned at run start).
    {:ok, compose_previous(stage, initial, acc), %{}}
  end

  defp compose_and_cap(
         %{context_mode: "accumulate"},
         initial,
         %{outputs: []},
         stage_cap,
         pipeline_cap
       ) do
    # No prior stages — composed prompt is just `initial`. There's nothing to
    # drop, so the cap (if any) reduces to a simple fit/no-fit check.
    cap = stage_cap || pipeline_cap
    pre_cap_bytes = byte_size(initial)

    cond do
      is_nil(cap) ->
        {:ok, initial, %{}}

      pre_cap_bytes <= cap ->
        {:ok, initial, %{}}

      true ->
        reason = "max_context_bytes (#{cap}) exceeded by initial prompt alone"
        {:error, reason, initial, failure_cap_meta(pre_cap_bytes, [])}
    end
  end

  defp compose_and_cap(
         %{context_mode: "accumulate"},
         initial,
         %{outputs: outputs},
         stage_cap,
         pipeline_cap
       ) do
    cap = stage_cap || pipeline_cap
    prior_chrono = Enum.reverse(outputs)
    full_prompt = build_accumulate_prompt(initial, prior_chrono, 0)
    pre_cap_bytes = byte_size(full_prompt)

    cond do
      is_nil(cap) ->
        {:ok, full_prompt, %{}}

      pre_cap_bytes <= cap ->
        {:ok, full_prompt, %{}}

      true ->
        try_drops(initial, prior_chrono, [], cap, pre_cap_bytes)
    end
  end

  defp compose_previous(_stage, initial, %{outputs: [], last: _}), do: initial

  defp compose_previous(_stage, initial, %{last: last}),
    do: initial <> "\n\n## Prior stage output\n" <> last

  # Drop oldest-first until the composed prompt (with elision notice) fits
  # under `cap`. If only the newest prior stage remains and it still
  # doesn't fit, fail with the "most-recent stage output alone" message.
  defp try_drops(initial, [newest], dropped, cap, pre_cap_bytes) do
    # Irreducible: only the newest prior stage remains. Either it fits or
    # this stage can't proceed.
    irreducible = build_accumulate_prompt(initial, [newest], length(dropped))

    if byte_size(irreducible) <= cap do
      {:ok, irreducible, success_cap_meta(pre_cap_bytes, byte_size(irreducible), dropped)}
    else
      reason =
        "max_context_bytes (#{cap}) exceeded by initial prompt + most-recent stage output alone"

      {:error, reason, irreducible, failure_cap_meta(pre_cap_bytes, dropped)}
    end
  end

  defp try_drops(initial, [oldest | rest], dropped, cap, pre_cap_bytes) do
    new_dropped = [oldest | dropped]
    candidate = build_accumulate_prompt(initial, rest, length(new_dropped))

    if byte_size(candidate) <= cap do
      {:ok, candidate, success_cap_meta(pre_cap_bytes, byte_size(candidate), new_dropped)}
    else
      try_drops(initial, rest, new_dropped, cap, pre_cap_bytes)
    end
  end

  defp build_accumulate_prompt(initial, [], _drop_count), do: initial

  defp build_accumulate_prompt(initial, stages, drop_count) do
    body =
      stages
      |> Enum.map(fn %{stage: i, output: out} -> "## Stage #{i} output\n#{out}" end)
      |> Enum.join("\n\n")

    notice = if drop_count > 0, do: elision_notice(drop_count), else: ""

    initial <> "\n\n" <> body <> notice
  end

  defp elision_notice(count) do
    plural = if count == 1, do: "output", else: "outputs"
    "\n\n[#{count} earlier stage #{plural} elided to fit max_context_bytes]"
  end

  defp success_cap_meta(pre_cap, post_cap, dropped) do
    %{
      accumulated_context_bytes_pre_cap: pre_cap,
      accumulated_context_bytes_post_cap: post_cap,
      dropped_stage_indexes: dropped |> Enum.map(& &1.stage) |> Enum.sort()
    }
  end

  defp failure_cap_meta(pre_cap, dropped) do
    %{
      accumulated_context_bytes_pre_cap: pre_cap,
      dropped_stage_indexes: dropped |> Enum.map(& &1.stage) |> Enum.sort()
    }
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
