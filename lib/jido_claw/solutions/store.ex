defmodule JidoClaw.Solutions.Store do
  @moduledoc """
  Persistent solution store backed by ETS with JSON disk persistence.

  In-session: O(1) ETS lookups keyed by solution id.
  Cross-session: JSON file at `.jido/solutions.json` loaded on boot, saved on writes.

  Client functions are safe to call even when the server is not running — they
  return sensible defaults rather than raising.
  """

  use GenServer
  require Logger

  alias JidoClaw.Solutions.Solution

  @table :jido_claw_solutions

  defstruct project_dir: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Build a Solution from attrs, store in ETS, persist to disk. Returns {:ok, solution}."
  def store_solution(attrs) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, {:store_solution, attrs})
    end
  end

  @doc "Lookup a solution by its ID. Returns {:ok, solution} or :not_found."
  def find_by_id(id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :not_found
      _pid -> GenServer.call(__MODULE__, {:find_by_id, id})
    end
  end

  @doc "Exact match on problem_signature. Returns {:ok, solution} or :not_found."
  def find_by_signature(signature) do
    case GenServer.whereis(__MODULE__) do
      nil -> :not_found
      _pid -> GenServer.call(__MODULE__, {:find_by_signature, signature})
    end
  end

  @doc """
  Text search across all solutions. Tokenizes query and matches against
  solution_content, tags, language, and framework.

  Opts: :language, :framework, :limit (default 10).
  Returns list of solutions sorted by relevance descending.
  """
  def search(query_text, opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, {:search, query_text, opts})
    end
  end

  @doc "Update trust_score for solution by id. Returns :ok."
  def update_trust(id, score) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:update_trust, id, score})
    end
  end

  @doc "Update verification field for solution by id. Returns :ok."
  def update_verification(id, verification_map) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:update_verification, id, verification_map})
    end
  end

  @doc "Remove solution by id. Returns :ok."
  def delete(id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:delete, id})
    end
  end

  @doc "Return %{total: int, by_language: %{}, by_framework: %{}}."
  def stats do
    case GenServer.whereis(__MODULE__) do
      nil -> %{total: 0, by_language: %{}, by_framework: %{}}
      _pid -> GenServer.call(__MODULE__, :stats)
    end
  end

  @doc "List solutions with :limit (default 50) and :offset (default 0)."
  def all(opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, {:all, opts})
    end
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    {:ok, %__MODULE__{project_dir: project_dir}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _ -> :ets.delete_all_objects(@table)
    end

    disk_solutions = load_from_disk(state.project_dir)

    Enum.each(disk_solutions, fn solution ->
      :ets.insert(@table, {solution.id, solution})
    end)

    Logger.debug(
      "[Solutions.Store] Loaded #{length(disk_solutions)} solutions from #{state.project_dir}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_call({:store_solution, attrs}, _from, state) do
    solution = Solution.new(attrs)
    :ets.insert(@table, {solution.id, solution})
    persist_to_disk(state.project_dir)

    JidoClaw.SignalBus.emit("jido_claw.solution.stored", %{
      id: solution.id,
      language: solution.language
    })

    {:reply, {:ok, solution}, state}
  end

  @impl true
  def handle_call({:find_by_id, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, solution}] -> {:ok, solution}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_by_signature, signature}, _from, state) do
    result =
      :ets.tab2list(@table)
      |> Enum.find(fn {_id, solution} -> solution.problem_signature == signature end)
      |> case do
        {_id, solution} -> {:ok, solution}
        nil -> :not_found
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:search, query_text, opts}, _from, state) do
    language_filter = Keyword.get(opts, :language)
    framework_filter = Keyword.get(opts, :framework)
    limit = Keyword.get(opts, :limit, 10)

    tokens = tokenize(query_text)
    total_tokens = length(tokens)

    results =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, solution} -> solution end)
      |> filter_by_language(language_filter)
      |> filter_by_framework(framework_filter)
      |> Enum.map(fn solution ->
        score = relevance_score(solution, tokens, total_tokens)
        {score, solution}
      end)
      |> Enum.filter(fn {score, _} -> score > 0.0 end)
      |> Enum.sort_by(fn {score, _} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, solution} -> solution end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:update_trust, id, score}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, solution}] ->
        updated = %{solution | trust_score: score, updated_at: utc_now_iso()}
        :ets.insert(@table, {id, updated})
        persist_to_disk(state.project_dir)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_verification, id, verification_map}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, solution}] ->
        updated = %{solution | verification: verification_map, updated_at: utc_now_iso()}
        :ets.insert(@table, {id, updated})
        persist_to_disk(state.project_dir)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    persist_to_disk(state.project_dir)
    JidoClaw.SignalBus.emit("jido_claw.solution.deleted", %{id: id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    solutions = :ets.tab2list(@table) |> Enum.map(fn {_id, s} -> s end)

    by_language =
      solutions
      |> Enum.group_by(& &1.language)
      |> Map.new(fn {lang, list} -> {lang, length(list)} end)

    by_framework =
      solutions
      |> Enum.filter(&(&1.framework != nil))
      |> Enum.group_by(& &1.framework)
      |> Map.new(fn {fw, list} -> {fw, length(list)} end)

    result = %{
      total: length(solutions),
      by_language: by_language,
      by_framework: by_framework
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:all, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    solutions =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, s} -> s end)
      |> Enum.sort_by(& &1.inserted_at, :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, solutions, state}
  end

  # ---------------------------------------------------------------------------
  # Search helpers
  # ---------------------------------------------------------------------------

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[\s[:punct:]]+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.uniq()
  end

  defp tokenize(_), do: []

  defp relevance_score(_solution, [], _total), do: 0.0
  defp relevance_score(_solution, _tokens, 0), do: 0.0

  defp relevance_score(solution, tokens, total_tokens) do
    corpus =
      [
        solution.solution_content || "",
        Enum.join(solution.tags, " "),
        solution.language || "",
        solution.framework || ""
      ]
      |> Enum.join(" ")
      |> String.downcase()

    matching =
      tokens
      |> Enum.count(fn token -> String.contains?(corpus, token) end)

    matching / total_tokens
  end

  defp filter_by_language(solutions, nil), do: solutions

  defp filter_by_language(solutions, language) do
    Enum.filter(solutions, fn s -> s.language == language end)
  end

  defp filter_by_framework(solutions, nil), do: solutions

  defp filter_by_framework(solutions, framework) do
    Enum.filter(solutions, fn s -> s.framework == framework end)
  end

  # ---------------------------------------------------------------------------
  # Disk persistence (JSON backup for cross-session survival)
  # ---------------------------------------------------------------------------

  defp persist_to_disk(project_dir) do
    entries =
      :ets.tab2list(@table)
      |> Map.new(fn {id, solution} -> {id, Solution.to_map(solution)} end)

    path = solutions_path(project_dir)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, Jason.encode!(entries, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Solutions.Store] Persist failed: #{inspect(reason)}")
    end
  end

  defp load_from_disk(project_dir) do
    path = solutions_path(project_dir)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            map
            |> Enum.map(fn {_id, entry} -> Solution.from_map(entry) end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @impl true
  def terminate(_reason, state) do
    persist_to_disk(state.project_dir)
    :ok
  end

  defp solutions_path(project_dir), do: Path.join([project_dir, ".jido", "solutions.json"])

  defp utc_now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
