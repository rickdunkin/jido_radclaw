defmodule JidoClaw.Memory.Consolidator.LockOwner do
  @moduledoc """
  Per-run dedicated process that holds a `pg_try_advisory_lock` on
  the scope's lock-key for the duration of a consolidator run.

  `Repo.checkout/1` pins the connection to the executing process for
  the full transaction; the RunServer can't both hold the lock and
  serve `GenServer.call`s, so we delegate the lock-holding to a
  linked Task that pins one connection from the Repo pool. The
  RunServer remains responsive throughout.

  Pool sizing: with `max_concurrent_scopes: 4`, the Repo pool must
  accommodate four pinned connections for lock-owners plus normal
  reads/writes from the rest of the system. Confirm
  `config :jido_claw, JidoClaw.Repo, pool_size:` is at least
  `base_size + max_concurrent_scopes`.
  """

  @acquire_timeout 5_000
  @release_timeout 5_000

  @doc """
  Try to acquire the advisory lock for `scope_lock_key`.

  Returns:
    * `{:ok, lock_pid}` — lock held by the spawned task; release
      with `release/1`.
    * `:busy` — another holder owns the key; back off.
    * `{:error, :lock_acquire_timeout}` — the spawned task didn't
      reply within `#{@acquire_timeout}` ms; the task was killed.
  """
  @spec acquire(integer()) :: {:ok, pid()} | :busy | {:error, :lock_acquire_timeout}
  def acquire(scope_lock_key) when is_integer(scope_lock_key) do
    if bypass?() do
      bypass_acquire()
    else
      do_acquire(scope_lock_key)
    end
  end

  defp do_acquire(scope_lock_key) do
    parent = self()
    {:ok, pid} = Task.start_link(fn -> hold(scope_lock_key, parent) end)

    receive do
      {:acquired, ^pid} -> {:ok, pid}
      {:busy, ^pid} -> :busy
    after
      @acquire_timeout ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        {:error, :lock_acquire_timeout}
    end
  end

  @doc """
  Release the lock held by `lock_pid`. Idempotent: returns `:ok` even
  if the holder is already gone.
  """
  @spec release(pid()) :: :ok
  def release(lock_pid) when is_pid(lock_pid) do
    if bypass?() do
      :ok
    else
      do_release(lock_pid)
    end
  end

  defp do_release(lock_pid) do
    ref = Process.monitor(lock_pid)
    send(lock_pid, :release)

    receive do
      {:released, ^lock_pid} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        :ok
    after
      @release_timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp hold(key, parent) do
    JidoClaw.Repo.checkout(fn ->
      case JidoClaw.Repo.query!("SELECT pg_try_advisory_lock($1)", [key]) do
        %{rows: [[true]]} ->
          send(parent, {:acquired, self()})

          receive do
            :release ->
              JidoClaw.Repo.query!("SELECT pg_advisory_unlock($1)", [key])
              send(parent, {:released, self()})
          end

        %{rows: [[false]]} ->
          send(parent, {:busy, self()})
      end
    end)
  end

  # Test-only escape hatch. `Repo.checkout/1` pins a Postgres connection for
  # the run's duration so the advisory lock survives across queries — that
  # pin is incompatible with `Ecto.Adapters.SQL.Sandbox`'s shared mode (one
  # routed connection serves every process; pinning it deadlocks the rest).
  # Tests using `start_owner!(shared: true)` set this flag so acquire/release
  # are no-ops, and lock semantics are covered separately by `lock_owner_test.exs`.
  defp bypass?, do: Application.get_env(:jido_claw, :consolidator_advisory_lock_disabled?, false)

  defp bypass_acquire do
    {:ok, spawn(fn -> :ok end)}
  end
end
