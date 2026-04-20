defmodule JidoClaw.Reasoning.PipelineStore do
  @moduledoc """
  Cached registry of user-defined pipelines loaded from
  `.jido/pipelines/*.yaml`.

  Each YAML file declares a named pipeline with a required non-empty
  `stages:` list. Stages are normalized + validated at load time using
  `JidoClaw.Reasoning.PipelineValidator`, so a YAML-loaded pipeline is
  byte-for-byte equivalent to an inline one at execution time.

  ## Schema

      name: plan_then_summarize
      description: CoT plan → CoD summary
      stages:
        - strategy: cot
        - strategy: cod
          context_mode: accumulate
          prompt_override: "Summarize the above…"

  `name` is required (non-empty, no `/`). `description` is optional.

  ## Lookup

  `JidoClaw.Tools.RunPipeline` calls `get/1` with a `pipeline_ref:` param.
  Inline `stages` always win over `pipeline_ref`; the store is only
  consulted when the caller didn't supply inline stages.

  ## Lenient skipping

  Malformed YAML, missing `name`/`stages`, invalid stages, collisions —
  all log a warning and the offending file is skipped. The process never
  crashes. User-vs-user name collisions resolve to the
  lexicographically-first filename (files are sorted before parsing).
  """

  use GenServer
  require Logger

  alias JidoClaw.Reasoning.PipelineValidator

  defstruct [:name, :description, :stages, :max_context_bytes]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          stages: [map()],
          max_context_bytes: pos_integer() | nil
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all cached pipeline names."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Find a cached pipeline by name."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Return all cached pipeline structs."
  @spec all() :: [t()]
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Reload pipelines from disk."
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
    {:ok, %{project_dir: project_dir, pipelines: []}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    pipelines = load_from_disk(state.project_dir)

    Logger.debug(
      "[PipelineStore] Cached #{length(pipelines)} user pipelines from #{pipelines_dir(state.project_dir)}"
    )

    {:noreply, %{state | pipelines: pipelines}}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.pipelines, state}

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.pipelines, & &1.name), state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Enum.find(state.pipelines, &(&1.name == name)) do
      nil -> {:reply, {:error, :not_found}, state}
      pipeline -> {:reply, {:ok, pipeline}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    pipelines = load_from_disk(state.project_dir)
    Logger.info("[PipelineStore] Reloaded #{length(pipelines)} user pipelines")
    {:reply, :ok, %{state | pipelines: pipelines}}
  end

  # ---------------------------------------------------------------------------
  # Private — loading + parsing
  # ---------------------------------------------------------------------------

  defp pipelines_dir(project_dir), do: Path.join([project_dir, ".jido", "pipelines"])

  defp load_from_disk(project_dir) do
    dir = pipelines_dir(project_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        # Sort first so name collisions resolve to lexicographically-first
        # reproducibly across filesystems (File.ls returns undefined order).
        |> Enum.sort()
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&parse_pipeline_file/1)
        |> dedupe_by_name()

      {:error, _} ->
        []
    end
  end

  defp parse_pipeline_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) ->
        case validate(data) do
          {:ok, pipeline} ->
            [pipeline]

          {:error, reason} ->
            Logger.warning("[PipelineStore] Skipping #{path}: #{reason}")
            []
        end

      {:ok, _} ->
        Logger.warning("[PipelineStore] Skipping #{path}: not a YAML mapping")
        []

      {:error, reason} ->
        Logger.warning("[PipelineStore] Failed to parse #{path}: #{inspect(reason)}")
        []
    end
  end

  defp validate(data) do
    with {:ok, name} <- fetch_name(data),
         {:ok, max_context_bytes} <- fetch_max_context_bytes(data),
         {:ok, raw_stages} <- fetch_stages(data),
         {:ok, normalized} <- PipelineValidator.normalize_stages(raw_stages),
         :ok <- PipelineValidator.validate_stages(normalized) do
      {:ok,
       %__MODULE__{
         name: name,
         description: stringish(Map.get(data, "description"), ""),
         stages: normalized,
         max_context_bytes: max_context_bytes
       }}
    end
  end

  defp fetch_max_context_bytes(data) do
    raw = Map.get(data, "max_context_bytes")

    if PipelineValidator.valid_max_context_bytes?(raw) do
      {:ok, raw}
    else
      {:error, "max_context_bytes must be a positive integer (got: #{inspect(raw)})"}
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

  defp fetch_stages(data) do
    case Map.get(data, "stages") do
      stages when is_list(stages) and stages != [] -> {:ok, stages}
      [] -> {:error, "stages must be a non-empty list"}
      nil -> {:error, "missing `stages` key"}
      _ -> {:error, "stages must be a list"}
    end
  end

  defp stringish(v, _default) when is_binary(v), do: v
  defp stringish(_, default), do: default

  # Resolves user-vs-user name collisions by keeping the lexicographically-first
  # file (the sort above guarantees consistent ordering across filesystems).
  defp dedupe_by_name(pipelines) do
    {kept, _seen} =
      Enum.reduce(pipelines, {[], MapSet.new()}, fn pipeline, {acc, seen} ->
        if MapSet.member?(seen, pipeline.name) do
          Logger.warning(
            "[PipelineStore] Duplicate user pipeline '#{pipeline.name}' — keeping the lexicographically-first definition"
          )

          {acc, seen}
        else
          {[pipeline | acc], MapSet.put(seen, pipeline.name)}
        end
      end)

    Enum.reverse(kept)
  end
end
