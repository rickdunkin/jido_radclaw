defmodule JidoClaw.Tools.Reason do
  @moduledoc """
  Applies a structured reasoning strategy to analyze a complex problem.

  Delegates to `Jido.AI.Actions.Reasoning.RunStrategy`, which runs an isolated
  runner agent for the requested strategy. Supports react (ReAct), cot, cod,
  tot, got, aot, trm, and adaptive strategies — plus any user-defined alias
  declared in `.jido/strategies/*.yaml` that resolves to one of those built-ins.
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
        doc: "Strategy: react, cot, cod, tot, got, aot, trm, adaptive, or a user-defined alias"
      ],
      prompt: [
        type: :string,
        required: true,
        doc: "The problem or question to reason about"
      ]
    ]

  alias JidoClaw.Reasoning.{StrategyRegistry, Telemetry}

  @impl true
  def run(params, context) do
    strategy_name = params.strategy
    prompt = params.prompt

    case StrategyRegistry.valid?(strategy_name) do
      false ->
        valid = StrategyRegistry.list() |> Enum.map(& &1.name) |> Enum.join(", ")
        {:error, "Unknown strategy '#{strategy_name}'. Valid strategies: #{valid}"}

      true ->
        run_strategy(strategy_name, prompt, context)
    end
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
    workspace_id = get_in(context, [:tool_context, :workspace_id])
    project_dir = get_in(context, [:tool_context, :project_dir])

    Telemetry.with_outcome(
      strategy_name,
      prompt,
      [
        execution_kind: :react_stub,
        base_strategy: "react",
        workspace_id: workspace_id,
        project_dir: project_dir
      ],
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
    workspace_id = get_in(context, [:tool_context, :workspace_id])
    project_dir = get_in(context, [:tool_context, :project_dir])
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)

    run_params = %{
      strategy: base_atom,
      prompt: prompt,
      timeout: 60_000
    }

    Telemetry.with_outcome(
      strategy_name,
      prompt,
      [
        execution_kind: :strategy_run,
        base_strategy: base_name,
        workspace_id: workspace_id,
        project_dir: project_dir
      ],
      fn -> runner.run(run_params, %{}) end
    )
    |> case do
      {:ok, result} ->
        {:ok,
         %{
           strategy: strategy_name,
           output: extract_output(result),
           status: Map.get(result, :status),
           usage: Map.get(result, :usage, %{})
         }}

      {:error, reason} ->
        {:error, format_error(strategy_name, reason)}
    end
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
