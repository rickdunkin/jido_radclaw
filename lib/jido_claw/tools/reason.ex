defmodule JidoClaw.Tools.Reason do
  @moduledoc """
  Applies a structured reasoning strategy to analyze a complex problem.

  Delegates to `Jido.AI.Actions.Reasoning.RunStrategy`, which runs an isolated
  runner agent for the requested strategy. Supports react (ReAct), cot, cod,
  tot, got, aot, trm, and adaptive strategies.
  """

  use Jido.Action,
    name: "reason",
    description:
      "Apply a structured reasoning strategy to analyze a complex problem. Use for architectural decisions, debugging complex issues, or multi-step planning.",
    schema: [
      strategy: [
        type: :string,
        required: true,
        doc: "Strategy: react, cot, cod, tot, got, aot, trm, adaptive"
      ],
      prompt: [
        type: :string,
        required: true,
        doc: "The problem or question to reason about"
      ]
    ]

  alias JidoClaw.Reasoning.StrategyRegistry

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

  defp run_strategy("react", prompt, _context) do
    # ReAct is the agent's native loop — format result as a structured reasoning prompt
    {:ok,
     %{
       strategy: "react",
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
     }}
  end

  defp run_strategy(strategy_name, prompt, _context) do
    {:ok, strategy_atom} = StrategyRegistry.atom_for(strategy_name)

    run_params = %{
      strategy: strategy_atom,
      prompt: prompt,
      timeout: 60_000
    }

    case Jido.AI.Actions.Reasoning.RunStrategy.run(run_params, %{}) do
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
