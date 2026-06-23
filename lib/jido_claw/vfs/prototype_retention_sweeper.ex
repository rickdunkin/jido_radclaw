defmodule JidoClaw.VFS.PrototypeRetentionSweeper do
  @moduledoc """
  AR-8b-2 C3: an **opt-in** TTL garbage-collector for stale `.prototypes/<uuid>/`
  sketch sandboxes.

  `.prototypes/` is `.gitignore`d, so prototypes accumulate on disk but never
  pollute the repo. The safe default is **never GC** (durability over tidiness —
  the `ComposerArtifact` retention posture); this is the bounded-growth escape
  hatch. Hourly self-rescheduling singleton, config read at tick time so runtime
  flips take effect within an hour; a `nil` / non-positive `max_age_days`
  **disables** sweeping (the tick no-ops). Modeled on
  `JidoClaw.Trace.RetentionSweeper` but with **no drain loop** (the prototype set
  is small).

  A dir is deleted only when ALL hold:

    * it is a real `.prototypes/<uuid>/` dir (`VFS.Sandbox.validate_root/1`),
    * its **effective mtime** — the newest mtime across the dir AND all contained
      files, recursively, lstat-skipping symlinks — predates the cutoff (so an
      *edited* prototype, whose dir mtime alone wouldn't change, stays fresh), and
    * its `prototype_id` is **not referenced** by any live run
      (`JidoClaw.Orchestration.PrototypeReference` — fail-safe: a `:referenced` or
      `:unknown` result keeps the dir).

  Config: `config :jido_claw, prototype_retention: [max_age_days: N]`.
  """

  use GenServer
  require Logger

  alias JidoClaw.Orchestration.PrototypeReference
  alias JidoClaw.ProjectDir
  alias JidoClaw.VFS.Sandbox

  @tick_ms :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    schedule_next()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    case max_age_days() do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
        Enum.each(prototype_roots(), &sweep_root(&1, cutoff))

      _disabled ->
        :ok
    end

    # Background sweeper — any failure must NOT crash the singleton (a crash would
    # stall prototype retention entirely); the GenServer reschedules regardless.
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[PrototypeRetentionSweeper] sweep raised: #{Exception.message(e)}")
      :ok
  catch
    kind, payload ->
      Logger.warning("[PrototypeRetentionSweeper] sweep #{kind}: #{inspect(payload)}")
      :ok
  end

  defp sweep_root(root, cutoff) do
    proto_root = Path.join(root, ".prototypes")

    case File.ls(proto_root) do
      {:ok, children} ->
        children
        |> Enum.filter(&Sandbox.uuid_child?/1)
        |> Enum.each(&maybe_delete(Path.join(proto_root, &1), &1, cutoff))

      {:error, _reason} ->
        # No `.prototypes` dir (or unreadable) — nothing to sweep.
        :ok
    end
  end

  # Deletes only when validated, stale-by-effective-mtime, AND unreferenced. Any
  # non-definitive result (`:referenced`, `:unknown`, an unvalidatable dir, a
  # missing mtime) keeps the dir — fail safe.
  defp maybe_delete(dir, id, cutoff) do
    with :ok <- Sandbox.validate_root(dir),
         {:ok, newest} <- effective_mtime(dir),
         true <- DateTime.compare(newest, cutoff) == :lt,
         :unreferenced <- PrototypeReference.reference_state(id) do
      File.rm_rf(dir)
      :ok
    else
      _keep -> :ok
    end
  end

  # Newest mtime across `dir` and its files (recursive), lstat-skipping symlinks
  # so a planted symlink contributes no outside-tree mtime and causes no loop.
  defp effective_mtime(dir) do
    case max_mtime(dir) do
      nil -> :error
      %DateTime{} = newest -> {:ok, newest}
    end
  end

  defp max_mtime(path) do
    case File.lstat(path, time: :universal) do
      {:ok, %File.Stat{type: :symlink}} -> nil
      {:ok, %File.Stat{type: :directory, mtime: mtime}} -> max_dir_mtime(path, to_datetime(mtime))
      {:ok, %File.Stat{mtime: mtime}} -> to_datetime(mtime)
      {:error, _reason} -> nil
    end
  end

  defp max_dir_mtime(dir, own) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&max_mtime(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(own, &later/2)

      {:error, _reason} ->
        own
    end
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp to_datetime({{year, month, day}, {hour, minute, second}}) do
    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  # A1: single root behind a one-function indirection for a future broadening.
  defp prototype_roots, do: [ProjectDir.current()]

  defp max_age_days,
    do: Keyword.get(Application.get_env(:jido_claw, :prototype_retention, []), :max_age_days)

  defp schedule_next, do: Process.send_after(self(), :sweep, @tick_ms)
end
