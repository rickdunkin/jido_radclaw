defmodule JidoClaw.Reasoning.StrategyRegistry do
  @moduledoc """
  Maps strategy names to jido_ai reasoning modules.

  Each entry carries a `:prefers` map used by `JidoClaw.Reasoning.Classifier`
  to recommend strategies based on the profile of an incoming prompt. The
  preferences are heuristic — the classifier's scoring keeps recommendations
  soft so unseen combinations still produce a candidate.
  """

  @strategies %{
    "react" => %{
      module: Jido.AI.Reasoning.ReAct,
      atom: :react,
      description:
        "Reason + Act loop: alternates between reasoning and tool use. Best for multi-step tasks requiring external information.",
      prefers: %{
        task_types: [:debugging, :exploration],
        complexity: [:moderate, :complex, :highly_complex]
      }
    },
    "cot" => %{
      module: Jido.AI.Reasoning.ChainOfThought,
      atom: :cot,
      description:
        "Chain of Thought: step-by-step reasoning before answering. Best for logical and mathematical problems.",
      prefers: %{
        task_types: [:qa, :verification, :open_ended],
        complexity: [:simple, :moderate]
      }
    },
    "cod" => %{
      module: Jido.AI.Reasoning.ChainOfDraft,
      atom: :cod,
      description:
        "Chain of Draft: concise step-by-step reasoning with minimal token usage. Good for structured analysis.",
      prefers: %{
        task_types: [:verification, :qa],
        complexity: [:simple, :moderate]
      }
    },
    "tot" => %{
      module: Jido.AI.Reasoning.TreeOfThoughts,
      atom: :tot,
      description:
        "Tree of Thoughts: explores multiple reasoning branches. Best for complex planning and creative problem-solving.",
      prefers: %{
        task_types: [:planning, :refactoring],
        complexity: [:complex, :highly_complex]
      }
    },
    "got" => %{
      module: Jido.AI.Reasoning.GraphOfThoughts,
      atom: :got,
      description:
        "Graph of Thoughts: non-linear reasoning with concept connections. Best for complex interconnected problems.",
      prefers: %{
        task_types: [:exploration, :refactoring, :planning],
        complexity: [:highly_complex]
      }
    },
    "aot" => %{
      module: Jido.AI.Reasoning.AlgorithmOfThoughts,
      atom: :aot,
      description:
        "Algorithm of Thoughts: structured algorithmic search with in-context examples. Best for optimization and search problems.",
      prefers: %{
        task_types: [:verification],
        complexity: [:complex, :highly_complex]
      }
    },
    "trm" => %{
      module: Jido.AI.Reasoning.TRM,
      atom: :trm,
      description:
        "Tiny Recursive Model: recursive decomposition with supervision. Best for hierarchical problems.",
      prefers: %{
        task_types: [:refactoring],
        complexity: [:complex, :highly_complex]
      }
    },
    "adaptive" => %{
      module: Jido.AI.Reasoning.Adaptive,
      atom: :adaptive,
      description:
        "Adaptive: automatically selects the best strategy based on prompt complexity.",
      prefers: %{task_types: [], complexity: []}
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

  @doc """
  Returns the `prefers` map for a strategy, or `nil` when unknown.

  Consumed by `JidoClaw.Reasoning.Classifier.recommend/2`.
  """
  @spec prefers_for(String.t()) ::
          %{task_types: [atom()], complexity: [atom()]} | nil
  def prefers_for(name) when is_binary(name) do
    case Map.get(@strategies, name) do
      nil -> nil
      %{prefers: prefers} -> prefers
    end
  end
end
