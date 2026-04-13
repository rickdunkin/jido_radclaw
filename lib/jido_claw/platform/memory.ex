defmodule JidoClaw.Memory do
  @moduledoc """
  Persistent memory backed by jido_memory's ETS store with JSON disk persistence.

  In-session: fast ETS-backed queries via `Jido.Memory.Store.ETS`
  Cross-session: JSON file at `.jido/memory.json` loaded on boot, saved on writes.

  Types: "fact" | "pattern" | "decision" | "preference"
  """

  use GenServer
  require Logger

  @store Jido.Memory.Store.ETS
  @store_opts [table: :jido_claw_memory]
  @namespace "jido_claw"

  @valid_memory_types %{
    "fact" => :fact,
    "pattern" => :pattern,
    "decision" => :decision,
    "preference" => :preference,
    "context" => :context
  }

  defstruct project_dir: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Upsert a memory entry. Returns :ok."
  def remember(key, content, type \\ "fact") do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:remember, key, content, type})
    end
  end

  @doc "Search memories by keyword. Returns list of maps sorted by recency."
  def recall(query, opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, {:recall, query, opts})
    end
  end

  @doc "Delete a memory by key."
  def forget(key) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:forget, key})
    end
  end

  @doc "List the N most recently updated memories."
  def list_recent(limit \\ 10) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, {:list_recent, limit})
    end
  end

  @doc "Return all memories sorted by observed_at descending."
  def all do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :all)
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
    @store.ensure_ready(@store_opts)

    disk_memories = load_from_disk(state.project_dir)

    Enum.each(disk_memories, fn {_key, entry} ->
      record = entry_to_record(entry)

      case @store.put(record, @store_opts) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("[Memory] Failed to load record: #{inspect(reason)}")
      end
    end)

    Logger.debug("[Memory] Loaded #{map_size(disk_memories)} memories from #{state.project_dir}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:remember, key, content, type}, _from, state) do
    now = System.system_time(:millisecond)

    record = %Jido.Memory.Record{
      id: key,
      namespace: @namespace,
      class: type_to_class(type),
      kind: Map.get(@valid_memory_types, type, :fact),
      text: content,
      content: %{key: key, type: type},
      tags: [type, "memory"],
      source: "user",
      observed_at: now
    }

    case @store.put(record, @store_opts) do
      {:ok, _} ->
        persist_to_disk(state.project_dir)
        JidoClaw.SignalBus.emit("jido_claw.memory.saved", %{key: key, type: type})
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("[Memory] Failed to store: #{inspect(reason)}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:recall, query_text, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    # Query all memories and filter by text match
    query = %Jido.Memory.Query{
      namespace: @namespace,
      limit: 1000,
      order: :desc
    }

    results =
      case @store.query(query, @store_opts) do
        {:ok, records} ->
          q = String.downcase(query_text)

          records
          |> Enum.filter(fn rec ->
            text = (rec.text || "") |> String.downcase()
            key = get_in(rec.content, [:key]) || rec.id || ""
            kind = to_string(rec.kind || "")

            String.contains?(text, q) or
              String.contains?(String.downcase(key), q) or
              String.contains?(String.downcase(kind), q)
          end)
          |> Enum.take(limit)
          |> Enum.map(&record_to_entry/1)

        {:error, _} ->
          []
      end

    {:reply, results, state}
  end

  @impl true
  def handle_call({:forget, key}, _from, state) do
    @store.delete({@namespace, key}, @store_opts)
    persist_to_disk(state.project_dir)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_recent, limit}, _from, state) do
    query = %Jido.Memory.Query{
      namespace: @namespace,
      limit: limit,
      order: :desc
    }

    results =
      case @store.query(query, @store_opts) do
        {:ok, records} -> Enum.map(records, &record_to_entry/1)
        {:error, _} -> []
      end

    {:reply, results, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    query = %Jido.Memory.Query{
      namespace: @namespace,
      limit: 1000,
      order: :desc
    }

    results =
      case @store.query(query, @store_opts) do
        {:ok, records} -> Enum.map(records, &record_to_entry/1)
        {:error, _} -> []
      end

    {:reply, results, state}
  end

  # ---------------------------------------------------------------------------
  # Conversion helpers
  # ---------------------------------------------------------------------------

  defp entry_to_record(%{key: key, content: content, type: type} = entry) do
    observed_at =
      case Map.get(entry, :updated_at) || Map.get(entry, :created_at) do
        nil -> System.system_time(:millisecond)
        ts when is_binary(ts) -> parse_iso8601_to_ms(ts)
        ts when is_integer(ts) -> ts
      end

    %Jido.Memory.Record{
      id: key,
      namespace: @namespace,
      class: type_to_class(type),
      kind: Map.get(@valid_memory_types, type, :fact),
      text: content,
      content: %{key: key, type: type},
      tags: [type, "memory"],
      source: "disk",
      observed_at: observed_at
    }
  end

  defp record_to_entry(record) do
    key = get_in(record.content, [:key]) || record.id
    type = to_string(record.kind || "fact")
    ts = record.observed_at |> ms_to_iso8601()

    %{
      key: key,
      content: record.text || "",
      type: type,
      created_at: ts,
      updated_at: ts
    }
  end

  defp type_to_class("pattern"), do: :procedural
  defp type_to_class("decision"), do: :semantic
  defp type_to_class("preference"), do: :semantic
  defp type_to_class(_), do: :episodic

  defp parse_iso8601_to_ms(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp ms_to_iso8601(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp ms_to_iso8601(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ---------------------------------------------------------------------------
  # Disk persistence (JSON backup for cross-session survival)
  # ---------------------------------------------------------------------------

  defp persist_to_disk(project_dir) do
    query = %Jido.Memory.Query{namespace: @namespace, limit: 10_000, order: :desc}

    case @store.query(query, @store_opts) do
      {:ok, records} ->
        entries =
          records
          |> Enum.map(fn rec ->
            entry = record_to_entry(rec)
            {entry.key, entry}
          end)
          |> Map.new()

        path = memory_path(project_dir)
        File.mkdir_p!(Path.dirname(path))

        case File.write(path, Jason.encode!(entries, pretty: true)) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("[Memory] Persist failed: #{inspect(reason)}")
        end

      {:error, _} ->
        :ok
    end
  end

  defp load_from_disk(project_dir) do
    path = memory_path(project_dir)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, map} when is_map(map) ->
            map
            |> Enum.map(fn {outer_key, entry} ->
              key = Map.get(entry, :key, to_string(outer_key))
              {key, entry}
            end)
            |> Map.new()

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  @impl true
  def terminate(_reason, state) do
    persist_to_disk(state.project_dir)
    :ok
  end

  defp memory_path(project_dir), do: Path.join([project_dir, ".jido", "memory.json"])
end
