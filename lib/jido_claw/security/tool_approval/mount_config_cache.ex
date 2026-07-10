defmodule JidoClaw.Security.ToolApproval.MountConfigCache do
  @moduledoc """
  Bounded content-addressed cache for the approval gate's VFS mount view.

  The caller still reads and hashes `.jido/config.yaml` on every gate. This
  process caches only the parsed `vfs.mounts` list under `{project_dir,
  sha256}`, so same-mtime edits are observed while repeated writes avoid YAML
  parsing. Invalid documents are cached as an opaque error too; no credentials
  or unrelated config keys enter the table.
  """

  use GenServer

  alias JidoClaw.Config

  @table __MODULE__
  @default_max_entries 64

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec fetch(String.t(), String.t(), binary()) :: {:ok, list()} | {:error, atom()}
  def fetch(project_dir, digest, bytes)
      when is_binary(project_dir) and is_binary(digest) and is_binary(bytes) do
    key = {project_dir, digest}

    case :ets.lookup(@table, key) do
      [{^key, result}] ->
        emit(:hit)
        result

      [] ->
        result = parse_mounts(bytes)
        :ok = GenServer.call(__MODULE__, {:put, key, result})
        emit(:miss)
        result
    end
  rescue
    ArgumentError -> {:error, :cache_unavailable}
  catch
    :exit, _reason -> {:error, :cache_unavailable}
  end

  @doc "Clear every cached mount parse and reset FIFO eviction order."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Return the current number of cached `{project_dir, digest}` entries."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @impl GenServer
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{order: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:put, key, result}, _from, state) do
    state =
      if :ets.member(@table, key) do
        state
      else
        true = :ets.insert(@table, {key, result})
        evict(%{state | order: :queue.in(key, state.order)})
      end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, _state) do
    true = :ets.delete_all_objects(@table)
    {:reply, :ok, %{order: :queue.new()}}
  end

  defp parse_mounts(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, config} when is_map(config) ->
        case Config.vfs_mounts(config) do
          {:ok, mounts} -> {:ok, mounts}
          {:error, _reason} -> {:error, :invalid_mount_config}
        end

      {:ok, nil} ->
        {:ok, []}

      {:ok, _other} ->
        {:error, :invalid_mount_config}

      {:error, _reason} ->
        {:error, :invalid_mount_config}
    end
  rescue
    _error in [YamlElixir.ParsingError, ArgumentError] -> {:error, :invalid_mount_config}
  end

  defp evict(state) do
    if :ets.info(@table, :size) > max_entries() do
      case :queue.out(state.order) do
        {{:value, oldest}, rest} ->
          true = :ets.delete(@table, oldest)
          %{state | order: rest}

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp max_entries do
    case Application.get_env(
           :jido_claw,
           :tool_approval_mount_cache_max_entries,
           @default_max_entries
         ) do
      value when is_integer(value) and value > 0 -> min(value, 1_024)
      _invalid -> @default_max_entries
    end
  end

  defp emit(result) do
    :telemetry.execute(
      [:jido_claw, :security, :tool_approval_mount_cache],
      %{count: 1},
      %{result: result}
    )
  end
end
