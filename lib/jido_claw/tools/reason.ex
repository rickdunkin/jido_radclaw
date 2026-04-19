defmodule JidoClaw.Tools.Reason do
  @moduledoc """
  Applies a structured reasoning strategy to analyze a complex problem.

  Delegates to `Jido.AI.Actions.Reasoning.RunStrategy`, which runs an isolated
  runner agent for the requested strategy. Supports `auto` (history-aware
  selection — the recommended default), react, cot, cod, tot, got, aot, trm,
  and user-defined aliases declared in `.jido/strategies/*.yaml`.

  `adaptive` is accepted for backwards compatibility and is silently
  normalized to `auto` at the tool boundary. Prefer `auto` in new code.
  """

  use Jido.Action,
    name: "reason",
    description:
      "Apply a structured reasoning strategy to analyze a complex problem. Use for architectural decisions, debugging complex issues, or multi-step planning.",
    category: "reasoning",
    tags: ["reasoning", "exec"],
    output_schema: [
      strategy: [type: :string, required: true],
      output: [type: :string, required: true],
      note: [type: :string],
      status: [type: :atom],
      usage: [type: :map]
    ],
    schema: [
      strategy: [
        type: :string,
        required: true,
        doc:
          "Strategy: auto (recommended — history-aware selection), react, cot, cod, tot, got, aot, trm, adaptive (deprecated — alias for auto), or a user-defined alias"
      ],
      prompt: [
        type: :string,
        required: true,
        doc: "The problem or question to reason about"
      ]
    ]

  alias JidoClaw.Reasoning.{AutoSelect, StrategyRegistry, Telemetry}

  @impl true
  def run(params, context) do
    strategy_name = params.strategy
    prompt = params.prompt

    cond do
      strategy_name in ["auto", "adaptive"] ->
        run_auto(prompt, context)

      StrategyRegistry.valid?(strategy_name) ->
        run_strategy(strategy_name, prompt, context)

      true ->
        valid = StrategyRegistry.list() |> Enum.map(& &1.name) |> Enum.join(", ")
        {:error, "Unknown strategy '#{strategy_name}'. Valid strategies: #{valid}"}
    end
  end

  # Auto path: history-aware selection resolves to a concrete strategy, then
  # delegates to the normal runner path with the chosen strategy. The outcome
  # row stores the *base* name (cot/tot/etc., never "auto"/"adaptive" and
  # never a user alias) so `Statistics.best_strategies_for/2` learns on a
  # stable vocabulary. When AutoSelect picks a user alias whose base differs
  # from the alias name, `metadata.alias_name` preserves the alias so
  # diagnostics stay lossless.
  defp run_auto(prompt, context) do
    {:ok, concrete_strategy, _confidence, profile, diagnostics} =
      AutoSelect.select(prompt)

    {:ok, base_atom} = StrategyRegistry.atom_for(concrete_strategy)
    base_name = Atom.to_string(base_atom)
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)

    run_params = %{
      strategy: base_atom,
      prompt: prompt,
      timeout: 60_000
    }

    metadata =
      if concrete_strategy != base_name do
        Map.put(diagnostics, :alias_name, concrete_strategy)
      else
        diagnostics
      end

    opts =
      base_telemetry_opts(context,
        execution_kind: :strategy_run,
        base_strategy: base_name,
        profile: profile,
        metadata: metadata
      )

    Telemetry.with_outcome(base_name, prompt, opts, fn ->
      runner.run(run_params, %{})
    end)
    |> format_runner_result(base_name)
  end

  # Dispatches on the *resolved base* of the strategy. User aliases whose base
  # is `react` take the react branch with their user-facing name preserved in
  # the output; non-react bases run through RunStrategy with base_strategy set
  # to the resolved built-in.
  defp run_strategy(strategy_name, prompt, context) do
    {:ok, base_atom} = StrategyRegistry.atom_for(strategy_name)
    base_name = Atom.to_string(base_atom)

    if base_name == "react" do
      run_react(strategy_name, prompt, context)
    else
      run_runner_strategy(strategy_name, base_atom, base_name, prompt, context)
    end
  end

  # The react branch returns a structured prompt template — ReAct is the
  # agent's native loop, so this tool just hands back a scaffold. Wrapping it
  # in Telemetry.with_outcome/4 keeps the row coherent: strategy is the
  # user-facing name, base_strategy is "react".
  defp run_react(strategy_name, prompt, context) do
    opts =
      base_telemetry_opts(context,
        execution_kind: :react_stub,
        base_strategy: "react"
      )

    Telemetry.with_outcome(
      strategy_name,
      prompt,
      opts,
      fn -> {:ok, react_payload(strategy_name, prompt)} end
    )
  end

  defp react_payload(strategy_name, prompt) do
    %{
      strategy: strategy_name,
      output: """
      [ReAct Reasoning Mode]

      Applying Reason + Act strategy to: #{prompt}

      Think step by step:
      1. What do I know about this problem?
      2. What information do I need to gather (tools to call)?
      3. What is my reasoning at each step?
      4. What is my final conclusion?

      Begin reasoning now.
      """,
      note: "ReAct is the agent's native reasoning loop. This prompt structures the approach."
    }
  end

  defp run_runner_strategy(strategy_name, base_atom, base_name, prompt, context) do
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)

    run_params = %{
      strategy: base_atom,
      prompt: prompt,
      timeout: 60_000
    }

    opts =
      base_telemetry_opts(context,
        execution_kind: :strategy_run,
        base_strategy: base_name
      )

    Telemetry.with_outcome(
      strategy_name,
      prompt,
      opts,
      fn -> runner.run(run_params, %{}) end
    )
    |> format_runner_result(strategy_name)
  end

  # Pull workspace_id / project_dir / agent_id / forge_session_key from
  # tool_context (all nil-safe) and fold in any extra keyword opts.
  defp base_telemetry_opts(context, extra) do
    tool_context = Map.get(context, :tool_context, %{}) || %{}

    [
      workspace_id: Map.get(tool_context, :workspace_id),
      project_dir: Map.get(tool_context, :project_dir),
      agent_id: Map.get(tool_context, :agent_id),
      forge_session_key: Map.get(tool_context, :forge_session_key)
    ]
    |> Keyword.merge(extra)
  end

  defp format_runner_result({:ok, result}, strategy_name) do
    {:ok,
     %{
       strategy: strategy_name,
       output: extract_output(result),
       status: Map.get(result, :status),
       usage: Map.get(result, :usage, %{})
     }}
  end

  defp format_runner_result({:error, reason}, strategy_name) do
    {:error, format_error(strategy_name, reason)}
  end

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

  defp format_error(strategy, %{output: output}) when is_binary(output) do
    "#{strategy} reasoning failed: #{output}"
  end

  defp format_error(strategy, reason), do: "#{strategy} reasoning failed: #{inspect(reason)}"
end
