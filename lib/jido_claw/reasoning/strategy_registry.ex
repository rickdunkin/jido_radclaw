defmodule JidoClaw.Reasoning.StrategyRegistry do
  @moduledoc """
  Maps strategy names to jido_ai reasoning modules.

  Each built-in entry carries a `:prefers` map used by
  `JidoClaw.Reasoning.Classifier` to recommend strategies based on the profile
  of an incoming prompt. The preferences are heuristic — the classifier's
  scoring keeps recommendations soft so unseen combinations still produce a
  candidate.

  User-defined aliases loaded from `.jido/strategies/*.yaml` overlay on top
  of the built-ins via `JidoClaw.Reasoning.StrategyStore`. Built-ins always
  win on name collision (see `StrategyStore.validate/1`).

  ## Alias resolution

    * `plugin_for/1` — returns the base strategy's module. React always
      returns `{:ok, Jido.AI.Reasoning.ReAct}` (both for direct `"react"` and
      react-based aliases). `Reason.run_strategy/3` routes react via the
      user-facing name, so no caller depends on `nil`.
    * `atom_for/1` — returns the base atom (e.g. `:cot` for a cot-aliased
      user strategy). Callers that care about the user-facing name should
      read it from their own call site.
    * `prefers_for/1` — returns the user-supplied `prefers` map for aliases
      (the whole point of metadata overlays).
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

  alias JidoClaw.Reasoning.StrategyStore

  @doc "Returns the strategy module for a given name."
  @spec plugin_for(String.t()) :: {:ok, module()} | {:error, :unknown_strategy}
  def plugin_for(name) when is_binary(name) do
    cond do
      builtin = Map.get(@strategies, name) ->
        {:ok, builtin.module}

      entry = user_strategy(name) ->
        plugin_for(entry.base)

      true ->
        {:error, :unknown_strategy}
    end
  end

  @doc "Returns the atom identifier for a strategy name. Aliases return their base's atom."
  @spec atom_for(String.t()) :: {:ok, atom()} | {:error, :unknown_strategy}
  def atom_for(name) when is_binary(name) do
    cond do
      builtin = Map.get(@strategies, name) ->
        {:ok, builtin.atom}

      entry = user_strategy(name) ->
        atom_for(entry.base)

      true ->
        {:error, :unknown_strategy}
    end
  end

  @doc """
  Lists all available strategies with name and description.

  Built-ins merged with user aliases, sorted by name. User entries include a
  `:display_name` field when provided; built-ins set it to `nil` so callers can
  branch uniformly.
  """
  @spec list() :: [%{name: String.t(), description: String.t(), display_name: String.t() | nil}]
  def list do
    builtins =
      Enum.map(@strategies, fn {name, %{description: desc}} ->
        %{name: name, description: desc, display_name: nil}
      end)

    users =
      user_all()
      |> Enum.map(fn entry ->
        %{name: entry.name, description: entry.description, display_name: entry.display_name}
      end)

    (builtins ++ users)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns true if the strategy name is known (built-in or user alias)."
  @spec valid?(String.t()) :: boolean()
  def valid?(name) when is_binary(name) do
    Map.has_key?(@strategies, name) or user_strategy(name) != nil
  end

  @doc """
  Returns the `prefers` map for a strategy, or `nil` when unknown. User aliases
  return their own `prefers` (the whole point of metadata overlays).

  Consumed by `JidoClaw.Reasoning.Classifier.recommend/2`.
  """
  @spec prefers_for(String.t()) ::
          %{task_types: [atom()], complexity: [atom()]} | nil
  def prefers_for(name) when is_binary(name) do
    cond do
      builtin = Map.get(@strategies, name) -> builtin.prefers
      entry = user_strategy(name) -> entry.prefers
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private — user strategy lookup with exit-safety
  # ---------------------------------------------------------------------------

  # GenServer.call/2 on a non-started named process *exits* the caller — a
  # `rescue` block won't catch that. Wrap the call in a :exit catch and fall
  # back to nil so the registry still resolves built-ins even when
  # StrategyStore isn't supervised (tests, minimal boot paths).
  defp user_strategy(name) do
    case GenServer.whereis(StrategyStore) do
      nil ->
        nil

      _pid ->
        try do
          case StrategyStore.get(name) do
            {:ok, entry} -> entry
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end
    end
  end

  defp user_all do
    case GenServer.whereis(StrategyStore) do
      nil ->
        []

      _pid ->
        try do
          StrategyStore.all()
        catch
          :exit, _ -> []
        end
    end
  end
end
