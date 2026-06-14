defmodule JidoClaw.Reasoning.YamlStore do
  # ex_dna:disable-for-this-file
  #
  # This module is a code-injection template: `__using__/1` quotes the shared
  # cached-registry GenServer (start_link/init/load_from_disk/…) into the using
  # stores. ExDNA would fingerprint those quoted defs as clones of the very call
  # sites they exist to de-duplicate — a meaningless self-match. The
  # store-specific logic that actually warrants duplicate detection lives in the
  # using modules, which stay covered.
  @moduledoc """
  Shared helpers and base machinery for YAML-backed reasoning stores
  (strategies, pipelines).

  ## `use JidoClaw.Reasoning.YamlStore`

  `use`-ing this module injects a complete cached-registry GenServer:

    * Client API — `start_link/1`, `list/0`, `get/1`, `all/0`, `reload/0`
    * Server — `init/1`, `handle_continue(:load, _)`, and `handle_call/3` for
      `:all | :list | :get | :reload`
    * Loading — `load_from_disk/1`, `parse_file/1`, `dedupe_by_name/1`,
      `entities_dir/1`

  The using module supplies the domain-specific parts: its `defstruct` /
  `@type t`, a private `validate/1` (called bare from the injected
  `parse_file/1`, so it resolves to the using module's own clause), and any
  store-specific helpers. Options:

    * `:subdir` — the `.jido/<subdir>` directory to load `*.yaml` from
    * `:label` — the log tag (e.g. `"PipelineStore"`)

  Entries are deduped by `name` (lexicographically-first file wins; files are
  sorted before parsing so ordering is reproducible across filesystems), and
  malformed/colliding files are warn-and-skipped — the process never crashes.
  """

  @doc """
  Extract and validate the `name` field from a parsed YAML document.

  Returns `{:ok, name}` for a non-empty string without a `/` separator
  (the latter would clash with the namespaced lookup in
  `StrategyRegistry` / `PipelineRegistry`).
  """
  @spec fetch_name(map()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_name(data) do
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

  @doc false
  defmacro __using__(opts) do
    subdir = Keyword.fetch!(opts, :subdir)
    label = Keyword.fetch!(opts, :label)

    quote do
      use GenServer
      require Logger

      # -----------------------------------------------------------------------
      # Client API
      # -----------------------------------------------------------------------

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc "Return all cached entry names."
      @spec list() :: [String.t()]
      def list do
        GenServer.call(__MODULE__, :list)
      end

      @doc "Find a cached entry by name."
      @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
      def get(name) when is_binary(name) do
        GenServer.call(__MODULE__, {:get, name})
      end

      @doc "Return all cached entry structs."
      @spec all() :: [t()]
      def all do
        GenServer.call(__MODULE__, :all)
      end

      @doc "Reload entries from disk."
      @spec reload() :: :ok
      def reload do
        GenServer.call(__MODULE__, :reload)
      end

      # -----------------------------------------------------------------------
      # Server callbacks
      # -----------------------------------------------------------------------

      @impl GenServer
      def init(opts) do
        project_dir = Keyword.fetch!(opts, :project_dir)
        {:ok, %{project_dir: project_dir, entities: []}, {:continue, :load}}
      end

      @impl GenServer
      def handle_continue(:load, state) do
        entities = load_from_disk(state.project_dir)

        Logger.debug(
          "[#{unquote(label)}] Cached #{length(entities)} user entries from #{entities_dir(state.project_dir)}"
        )

        {:noreply, %{state | entities: entities}}
      end

      @impl GenServer
      def handle_call(:all, _from, state), do: {:reply, state.entities, state}

      @impl GenServer
      def handle_call(:list, _from, state) do
        {:reply, Enum.map(state.entities, & &1.name), state}
      end

      @impl GenServer
      def handle_call({:get, name}, _from, state) do
        case Enum.find(state.entities, &(&1.name == name)) do
          nil -> {:reply, {:error, :not_found}, state}
          entity -> {:reply, {:ok, entity}, state}
        end
      end

      @impl GenServer
      def handle_call(:reload, _from, state) do
        entities = load_from_disk(state.project_dir)
        Logger.info("[#{unquote(label)}] Reloaded #{length(entities)} user entries")
        {:reply, :ok, %{state | entities: entities}}
      end

      # -----------------------------------------------------------------------
      # Private — loading + parsing
      # -----------------------------------------------------------------------

      defp entities_dir(project_dir), do: Path.join([project_dir, ".jido", unquote(subdir)])

      defp load_from_disk(project_dir) do
        dir = entities_dir(project_dir)

        case File.ls(dir) do
          {:ok, files} ->
            files
            # Sort first so name collisions resolve to lexicographically-first
            # reproducibly across filesystems (File.ls returns undefined order).
            |> Enum.sort()
            |> Enum.filter(&String.ends_with?(&1, ".yaml"))
            |> Enum.flat_map(fn file -> parse_file(Path.join(dir, file)) end)
            |> dedupe_by_name()

          {:error, _} ->
            []
        end
      end

      defp parse_file(path) do
        case YamlElixir.read_from_file(path) do
          {:ok, data} when is_map(data) ->
            case validate(data) do
              {:ok, entity} ->
                [entity]

              {:error, reason} ->
                Logger.warning("[#{unquote(label)}] Skipping #{path}: #{reason}")
                []
            end

          {:ok, _} ->
            Logger.warning("[#{unquote(label)}] Skipping #{path}: not a YAML mapping")
            []

          {:error, reason} ->
            Logger.warning("[#{unquote(label)}] Failed to parse #{path}: #{inspect(reason)}")
            []
        end
      end

      # Resolves user-vs-user name collisions by keeping the lexicographically-first
      # file (the sort above guarantees consistent ordering across filesystems).
      defp dedupe_by_name(entities) do
        {kept, _seen} =
          Enum.reduce(entities, {[], MapSet.new()}, fn entity, {acc, seen} ->
            if MapSet.member?(seen, entity.name) do
              Logger.warning(
                "[#{unquote(label)}] Duplicate '#{entity.name}' — keeping the lexicographically-first definition"
              )

              {acc, seen}
            else
              {[entity | acc], MapSet.put(seen, entity.name)}
            end
          end)

        Enum.reverse(kept)
      end
    end
  end
end
