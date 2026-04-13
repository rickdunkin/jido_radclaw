defmodule JidoClaw.Solutions.Reputation do
  @moduledoc """
  GenServer tracking agent reputation over time.

  Reputation entries are stored in an ETS table (`:jido_claw_reputation`) for
  fast in-session access and persisted to `.jido/reputation.json` on every
  write for cross-session survival.

  ## Reputation entry shape

      %{
        agent_id:            String.t(),
        score:               float(),    # 0.0–1.0, starts at 0.5
        solutions_shared:    integer(),
        solutions_verified:  integer(),
        solutions_failed:    integer(),
        last_active:         String.t()  # ISO 8601, or nil
      }

  ## Score formula

  Recomputed on every `record_success/1` and `record_failure/1`:

      success_rate    = verified / max(1, verified + failed)
      activity_bonus  = min(0.1, shared * 0.01)
      freshness       = 1.0 if last_active within 30 days, else decays to 0.0
      score           = 0.5 * 0.3 + success_rate * 0.5 + activity_bonus + freshness * 0.1

  Result is clamped to 0.0–1.0.
  """

  use GenServer
  require Logger

  @table :jido_claw_reputation

  defstruct project_dir: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the reputation entry for `agent_id`, or a default entry with
  `score: 0.5` if the agent is unknown.
  """
  @spec get(String.t()) :: map()
  def get(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> default_entry(agent_id)
      _pid -> GenServer.call(__MODULE__, {:get, agent_id})
    end
  end

  @doc """
  Record a successful verification for `agent_id`.
  Increments `:solutions_verified`, recalculates the score, and persists to disk.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:record_success, agent_id})
    end
  end

  @doc """
  Record a failed verification for `agent_id`.
  Increments `:solutions_failed`, recalculates the score, and persists to disk.
  """
  @spec record_failure(String.t()) :: :ok
  def record_failure(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:record_failure, agent_id})
    end
  end

  @doc """
  Record a solution share event for `agent_id`.
  Increments `:solutions_shared` and persists to disk.
  """
  @spec record_share(String.t()) :: :ok
  def record_share(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:record_share, agent_id})
    end
  end

  @doc "Return all reputation entries as a list."
  @spec all() :: [map()]
  def all do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :all)
    end
  end

  @doc "Return the top `limit` agents sorted by score descending."
  @spec top(non_neg_integer()) :: [map()]
  def top(limit \\ 10) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, {:top, limit})
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
    ensure_table()
    load_from_disk(state.project_dir)
    Logger.debug("[Reputation] Initialised from #{state.project_dir}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get, agent_id}, _from, state) do
    entry = lookup(agent_id)
    {:reply, entry, state}
  end

  @impl true
  def handle_call({:record_success, agent_id}, _from, state) do
    entry =
      agent_id
      |> lookup()
      |> Map.update!(:solutions_verified, &(&1 + 1))
      |> touch_active()
      |> recalculate_score()

    upsert(entry)
    persist_to_disk(state.project_dir)

    JidoClaw.SignalBus.emit("jido_claw.reputation.updated", %{
      agent_id: agent_id,
      score: entry.score
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_failure, agent_id}, _from, state) do
    entry =
      agent_id
      |> lookup()
      |> Map.update!(:solutions_failed, &(&1 + 1))
      |> touch_active()
      |> recalculate_score()

    upsert(entry)
    persist_to_disk(state.project_dir)

    JidoClaw.SignalBus.emit("jido_claw.reputation.updated", %{
      agent_id: agent_id,
      score: entry.score
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_share, agent_id}, _from, state) do
    entry =
      agent_id
      |> lookup()
      |> Map.update!(:solutions_shared, &(&1 + 1))
      |> touch_active()
      |> recalculate_score()

    upsert(entry)
    persist_to_disk(state.project_dir)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    entries = :ets.tab2list(@table) |> Enum.map(fn {_id, entry} -> entry end)
    {:reply, entries, state}
  end

  @impl true
  def handle_call({:top, limit}, _from, state) do
    entries =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  # ---------------------------------------------------------------------------
  # ETS helpers
  # ---------------------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        @table
    end
  end

  defp lookup(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entry}] -> entry
      [] -> default_entry(agent_id)
    end
  end

  defp upsert(entry) do
    :ets.insert(@table, {entry.agent_id, entry})
  end

  # ---------------------------------------------------------------------------
  # Score calculation
  # ---------------------------------------------------------------------------

  defp recalculate_score(entry) do
    %{
      solutions_verified: verified,
      solutions_failed: failed,
      solutions_shared: shared,
      last_active: last_active
    } = entry

    success_rate = verified / max(1, verified + failed)
    activity_bonus = min(0.1, shared * 0.01)
    freshness = freshness_score(last_active)

    raw = 0.5 * 0.3 + success_rate * 0.5 + activity_bonus + freshness * 0.1
    score = raw |> max(0.0) |> min(1.0)

    %{entry | score: score}
  end

  defp freshness_score(nil), do: 0.0

  defp freshness_score(last_active) when is_binary(last_active) do
    case DateTime.from_iso8601(last_active) do
      {:ok, dt, _} ->
        age_days = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400.0

        if age_days <= 30 do
          1.0
        else
          max(0.0, 1.0 - (age_days - 30) / 30)
        end

      _ ->
        0.0
    end
  end

  defp freshness_score(_), do: 0.0

  defp touch_active(entry) do
    %{entry | last_active: DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  # ---------------------------------------------------------------------------
  # Default entry
  # ---------------------------------------------------------------------------

  defp default_entry(agent_id) do
    %{
      agent_id: agent_id,
      score: 0.5,
      solutions_shared: 0,
      solutions_verified: 0,
      solutions_failed: 0,
      last_active: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Disk persistence (JSON backup for cross-session survival)
  # ---------------------------------------------------------------------------

  defp persist_to_disk(project_dir) do
    entries = :ets.tab2list(@table) |> Map.new()

    path = reputation_path(project_dir)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, Jason.encode!(entries, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Reputation] Persist failed: #{inspect(reason)}")
    end
  end

  defp load_from_disk(project_dir) do
    path = reputation_path(project_dir)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, map} when is_map(map) ->
            Enum.each(map, fn {_outer_key, raw} ->
              entry = coerce_entry(raw)
              :ets.insert(@table, {entry.agent_id, entry})
            end)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp coerce_entry(raw) do
    %{
      agent_id: to_string(Map.get(raw, :agent_id, "")),
      score: coerce_float(Map.get(raw, :score, 0.5)),
      solutions_shared: Map.get(raw, :solutions_shared, 0),
      solutions_verified: Map.get(raw, :solutions_verified, 0),
      solutions_failed: Map.get(raw, :solutions_failed, 0),
      last_active: Map.get(raw, :last_active)
    }
  end

  defp coerce_float(v) when is_float(v), do: v
  defp coerce_float(v) when is_integer(v), do: v / 1.0

  defp coerce_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.5
    end
  end

  defp coerce_float(_), do: 0.5

  @impl true
  def terminate(_reason, state) do
    persist_to_disk(state.project_dir)
    :ok
  end

  defp reputation_path(project_dir), do: Path.join([project_dir, ".jido", "reputation.json"])
end
