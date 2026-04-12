defmodule JidoClaw.Reasoning.StrategyRegistry do
  @moduledoc "Maps strategy names to jido_ai reasoning modules."

  @strategies %{
    "react" => %{
      module: Jido.AI.Reasoning.ReAct,
      atom: :react,
      description:
        "Reason + Act loop: alternates between reasoning and tool use. Best for multi-step tasks requiring external information."
    },
    "cot" => %{
      module: Jido.AI.Reasoning.ChainOfThought,
      atom: :cot,
      description:
        "Chain of Thought: step-by-step reasoning before answering. Best for logical and mathematical problems."
    },
    "cod" => %{
      module: Jido.AI.Reasoning.ChainOfDraft,
      atom: :cod,
      description:
        "Chain of Draft: concise step-by-step reasoning with minimal token usage. Good for structured analysis."
    },
    "tot" => %{
      module: Jido.AI.Reasoning.TreeOfThoughts,
      atom: :tot,
      description:
        "Tree of Thoughts: explores multiple reasoning branches. Best for complex planning and creative problem-solving."
    },
    "got" => %{
      module: Jido.AI.Reasoning.GraphOfThoughts,
      atom: :got,
      description:
        "Graph of Thoughts: non-linear reasoning with concept connections. Best for complex interconnected problems."
    },
    "aot" => %{
      module: Jido.AI.Reasoning.AlgorithmOfThoughts,
      atom: :aot,
      description:
        "Algorithm of Thoughts: structured algorithmic search with in-context examples. Best for optimization and search problems."
    },
    "trm" => %{
      module: Jido.AI.Reasoning.TRM,
      atom: :trm,
      description:
        "Tiny Recursive Model: recursive decomposition with supervision. Best for hierarchical problems."
    },
    "adaptive" => %{
      module: Jido.AI.Reasoning.Adaptive,
      atom: :adaptive,
      description: "Adaptive: automatically selects the best strategy based on prompt complexity."
    }
  }

  @doc "Returns the strategy module for a given name, or nil for react (handled natively by the agent)."
  @spec plugin_for(String.t()) :: {:ok, module() | nil} | {:error, :unknown_strategy}
  def plugin_for(name) when is_binary(name) do
    case Map.get(@strategies, name) do
      nil -> {:error, :unknown_strategy}
      %{module: module} -> {:ok, module}
    end
  end

  @doc "Returns the atom identifier for a strategy name."
  @spec atom_for(String.t()) :: {:ok, atom()} | {:error, :unknown_strategy}
  def atom_for(name) when is_binary(name) do
    case Map.get(@strategies, name) do
      nil -> {:error, :unknown_strategy}
      %{atom: atom} -> {:ok, atom}
    end
  end

  @doc "Lists all available strategies with name and description."
  @spec list() :: [%{name: String.t(), description: String.t()}]
  def list do
    @strategies
    |> Enum.map(fn {name, %{description: desc}} -> %{name: name, description: desc} end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns true if the strategy name is valid."
  @spec valid?(String.t()) :: boolean()
  def valid?(name), do: Map.has_key?(@strategies, name)
end
