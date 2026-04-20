defmodule JidoClaw.Reasoning.StrategyStore do
  @moduledoc """
  Cached registry of user-defined reasoning strategies loaded from
  `.jido/strategies/*.yaml`.

  Each YAML file declares a named alias that routes to one of the 8 built-in
  reasoning modules via a required `base` field. Aliases overlay
  `prefers` metadata and optional custom prompt templates on top of the
  built-in they target.

  YAML schema:

      name: deep_debug              # required; non-empty; no "/"
      base: react                   # required; must be a built-in strategy name
      display_name: "Deep Debug"    # optional
      description: "..."            # optional
      prefers:
        task_types: [debugging]
        complexity: [complex, highly_complex]
      prompts:                      # optional; per-base whitelist, see below
        system: "You are a rigorous mathematician"

  ## Prompts whitelist

  `prompts:` is validated against a per-base accepted-key matrix drawn from
  `Jido.AI.Actions.Reasoning.RunStrategy`'s `@strategy_state_keys` (source of
  truth: `deps/jido_ai/lib/jido_ai/actions/reasoning/run_strategy.ex:108-133`):

  | base     | accepted keys                                    |
  | -------- | ------------------------------------------------ |
  | cot, cod | `system`                                         |
  | tot      | `generation`, `evaluation`                       |
  | got      | `generation`, `connection`, `aggregation`        |
  | trm, aot, react, adaptive | (none — any known key → skip)   |

  Each value must be a non-empty string ≤ 5 KB (aligned with
  `Jido.AI.Validation.@max_prompt_length`). Empty strings are dropped as
  "unset." Known sub-keys (`system`/`generation`/`evaluation`/`connection`/
  `aggregation`) that aren't accepted on this base → **whole file skipped**
  with a warning. Non-string values or oversized values → whole file
  skipped. Unknown sub-keys (e.g. typo `sytem`) → warn-and-drop that key;
  file kept if others are valid.

  ## Lenient skipping

  Unknown `base` values, collisions with built-ins, malformed YAML, and
  prompts-whitelist violations are all logged as warnings and the offending
  file is skipped. The process never crashes. Built-ins always win on name
  collision. On user-vs-user collision the lexicographically-first filename
  wins (files are sorted before parsing so ordering is reproducible across
  environments).
  """

  use GenServer
  require Logger

  alias JidoClaw.Reasoning.{Complexity, TaskType}

  defstruct [:name, :base, :description, :prefers, :display_name, :prompts]

  @type t :: %__MODULE__{
          name: String.t(),
          base: String.t(),
          description: String.t(),
          prefers: %{task_types: [atom()], complexity: [atom()]},
          display_name: String.t() | nil,
          prompts: %{optional(atom()) => binary()}
        }

  @builtin_strategies ~w(react cot cod tot got aot trm adaptive)

  # Per-base accepted `prompts:` keys. Source of truth:
  # `deps/jido_ai/lib/jido_ai/actions/reasoning/run_strategy.ex:108-133`
  # (`@strategy_state_keys`). `react` bypasses RunStrategy entirely (Reason's
  # react branch is a structured-prompt stub) and thus accepts no custom
  # templates either.
  @prompt_keys_by_base %{
    "react" => [],
    "cot" => [:system],
    "cod" => [:system],
    "tot" => [:generation, :evaluation],
    "got" => [:generation, :connection, :aggregation],
    "aot" => [],
    "trm" => [],
    "adaptive" => []
  }

  @known_prompt_keys [:system, :generation, :evaluation, :connection, :aggregation]

  # 5 KB per field. Aligned with `Jido.AI.Validation.@max_prompt_length`
  # (`deps/jido_ai/lib/jido_ai/validation.ex:13`) — user strategies stay
  # consistent with upstream.
  @max_prompt_bytes 5_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all cached strategy names."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Find a cached user strategy by name."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Return all cached strategy structs."
  @spec all() :: [t()]
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Reload strategies from disk (hot-reload after YAML edits)."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    {:ok, %{project_dir: project_dir, strategies: []}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    strategies = load_from_disk(state.project_dir)

    Logger.debug(
      "[StrategyStore] Cached #{length(strategies)} user strategies from #{strategies_dir(state.project_dir)}"
    )

    {:noreply, %{state | strategies: strategies}}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.strategies, state}

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.strategies, & &1.name), state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Enum.find(state.strategies, &(&1.name == name)) do
      nil -> {:reply, {:error, :not_found}, state}
      strategy -> {:reply, {:ok, strategy}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    strategies = load_from_disk(state.project_dir)
    Logger.info("[StrategyStore] Reloaded #{length(strategies)} user strategies")
    {:reply, :ok, %{state | strategies: strategies}}
  end

  # ---------------------------------------------------------------------------
  # Private — loading + parsing
  # ---------------------------------------------------------------------------

  defp strategies_dir(project_dir), do: Path.join([project_dir, ".jido", "strategies"])

  defp load_from_disk(project_dir) do
    dir = strategies_dir(project_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        # Sort first so name collisions resolve to lexicographically-first
        # reproducibly across filesystems (File.ls returns undefined order).
        |> Enum.sort()
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&parse_strategy_file/1)
        |> dedupe_by_name()

      {:error, _} ->
        []
    end
  end

  defp parse_strategy_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) ->
        case validate(data) do
          {:ok, strategy} ->
            [strategy]

          {:error, reason} ->
            Logger.warning("[StrategyStore] Skipping #{path}: #{reason}")
            []
        end

      {:ok, _} ->
        Logger.warning("[StrategyStore] Skipping #{path}: not a YAML mapping")
        []

      {:error, reason} ->
        Logger.warning("[StrategyStore] Failed to parse #{path}: #{inspect(reason)}")
        []
    end
  end

  defp validate(data) do
    with {:ok, name} <- fetch_name(data),
         :ok <- refuse_builtin_collision(name),
         {:ok, base} <- fetch_base(data),
         prefers <- parse_prefers(Map.get(data, "prefers")),
         {:ok, prompts} <- parse_prompts(Map.get(data, "prompts"), base) do
      {:ok,
       %__MODULE__{
         name: name,
         base: base,
         description: Map.get(data, "description", ""),
         prefers: prefers,
         display_name: stringish(Map.get(data, "display_name")),
         prompts: prompts
       }}
    end
  end

  defp fetch_name(data) do
    case Map.get(data, "name") do
      name when is_binary(name) ->
        cleaned = String.trim(name)

        cond do
          cleaned == "" -> {:error, "empty name"}
          String.contains?(cleaned, "/") -> {:error, "name must not contain '/'"}
          true -> {:ok, cleaned}
        end

      _ ->
        {:error, "missing or non-string name"}
    end
  end

  defp refuse_builtin_collision(name) do
    if name in @builtin_strategies do
      {:error, "name '#{name}' collides with a built-in strategy"}
    else
      :ok
    end
  end

  defp fetch_base(data) do
    case Map.get(data, "base") do
      base when is_binary(base) ->
        cleaned = String.trim(base)

        if cleaned in @builtin_strategies do
          {:ok, cleaned}
        else
          {:error,
           "unknown base '#{cleaned}' (must be one of: #{Enum.join(@builtin_strategies, ", ")})"}
        end

      _ ->
        {:error, "missing or non-string base"}
    end
  end

  defp parse_prefers(nil), do: %{task_types: [], complexity: []}

  defp parse_prefers(prefers) when is_map(prefers) do
    %{
      task_types: whitelist_atoms(Map.get(prefers, "task_types", []), TaskType.values()),
      complexity: whitelist_atoms(Map.get(prefers, "complexity", []), Complexity.values())
    }
  end

  defp parse_prefers(_), do: %{task_types: [], complexity: []}

  defp parse_prompts(nil, _base), do: {:ok, %{}}

  defp parse_prompts(prompts, base) when is_map(prompts) do
    accepted = Map.fetch!(@prompt_keys_by_base, base)

    Enum.reduce_while(prompts, {:ok, %{}}, fn {raw_key, raw_value}, {:ok, acc} ->
      case classify_prompt_entry(raw_key, raw_value, base, accepted) do
        {:keep, atom_key, value} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
        :drop -> {:cont, {:ok, acc}}
        {:reject, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_prompts(other, _base),
    do: {:error, "prompts must be a mapping (got: #{inspect(other)})"}

  # Returns one of:
  #   {:keep, atom_key, value}   — valid accepted prompt for this base
  #   :drop                      — unknown sub-key or empty string (warn on unknown)
  #   {:reject, reason}          — whole-file skip (known-but-unsupported, oversize, non-string)
  defp classify_prompt_entry(raw_key, value, base, accepted) do
    atom_key = known_prompt_key(raw_key)

    cond do
      is_nil(atom_key) ->
        Logger.warning(
          "[StrategyStore] Unknown prompt key #{inspect(raw_key)} — dropping (known: #{known_prompt_key_list()})"
        )

        :drop

      atom_key not in accepted ->
        {:reject, "prompts.#{atom_key} not supported on base '#{base}'"}

      is_binary(value) and byte_size(value) > @max_prompt_bytes ->
        {:reject,
         "prompts.#{atom_key} exceeds #{@max_prompt_bytes}-byte limit (#{byte_size(value)} bytes)"}

      is_binary(value) and value == "" ->
        :drop

      is_binary(value) ->
        {:keep, atom_key, value}

      true ->
        {:reject, "prompts.#{atom_key} must be a non-empty string (got: #{inspect(value)})"}
    end
  end

  defp known_prompt_key(k) when is_atom(k) do
    if k in @known_prompt_keys, do: k, else: nil
  end

  defp known_prompt_key(k) when is_binary(k) do
    Enum.find(@known_prompt_keys, fn atom -> Atom.to_string(atom) == k end)
  end

  defp known_prompt_key(_), do: nil

  defp known_prompt_key_list do
    @known_prompt_keys |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
  end

  # Never `String.to_atom/1` on user input — match against the known enum
  # values instead. Unknown strings are silently dropped.
  defp whitelist_atoms(list, allowed) when is_list(list) do
    Enum.flat_map(list, fn v ->
      cond do
        is_atom(v) and v in allowed -> [v]
        is_binary(v) -> map_string_to_atom(v, allowed)
        true -> []
      end
    end)
  end

  defp whitelist_atoms(_, _), do: []

  defp map_string_to_atom(str, allowed) do
    case Enum.find(allowed, fn a -> Atom.to_string(a) == str end) do
      nil -> []
      atom -> [atom]
    end
  end

  defp stringish(nil), do: nil
  defp stringish(v) when is_binary(v), do: v
  defp stringish(_), do: nil

  # Built-in collisions are caught in validate/1. This pass resolves
  # user-vs-user name collisions by keeping the lexicographically-first file
  # (the sort above guarantees consistent ordering across filesystems).
  defp dedupe_by_name(strategies) do
    {kept, _seen} =
      Enum.reduce(strategies, {[], MapSet.new()}, fn strat, {acc, seen} ->
        if MapSet.member?(seen, strat.name) do
          Logger.warning(
            "[StrategyStore] Duplicate user strategy '#{strat.name}' — keeping the lexicographically-first definition"
          )

          {acc, seen}
        else
          {[strat | acc], MapSet.put(seen, strat.name)}
        end
      end)

    Enum.reverse(kept)
  end
end
