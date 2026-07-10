defmodule JidoClaw.Audit.AsyncWriter do
  @moduledoc """
  Hybrid sync/async dispatcher for `Audit.Event` writes.

  * `sync/1` runs in the caller's transaction. Used by tx-bound
    producers (memory writes, solution shares, session start/end);
    a rollback in the outer action rolls the audit row back too.
  * `cast/1` runs in a Task.Supervisor child. Used by hot-path
    producers (tool-call signal listener, auth events) so audit-
    write latency doesn't gate the request. Failures are logged,
    never raised — losing an audit row is preferable to dropping
    a request.
  * `enqueue/1,2` is the result-bearing variant of `cast/1`: same
    spawn, but the caller learns whether the writer task was
    accepted (`{:ok, pid}` means SPAWNED, not persisted). Used by
    the AshTracer double-emit fence, which marks a denial audited
    only on a successful handoff.

  All call shapes accept attrs containing `tenant_id`; the writer
  strips it from attrs and threads it via `tenant:` opt to match
  the `:attribute` multitenancy contract.
  """

  alias JidoClaw.Audit.Event
  alias JidoClaw.Authorization.Actor
  require Logger

  @sup JidoClaw.Audit.TaskSupervisor

  @spec cast(map()) :: :ok
  def cast(attrs) when is_map(attrs) do
    _accepted_or_not = enqueue(attrs)
    :ok
  end

  @doc """
  Spawn an async audit write, reporting whether the task was accepted.

  A total, non-raising boundary: `Task.Supervisor.start_child/3` can EXIT
  with `:noproc` (supervisor down — shutdown races), not just return
  `{:error, _}`, so both are normalized to `{:error, term}`. `{:ok, pid}`
  means the writer task was **spawned** — never that the row persisted.
  The `supervisor` override exists so tests can pin the
  unavailable-supervisor case against an isolated supervisor.
  """
  @spec enqueue(map(), Supervisor.supervisor()) :: {:ok, pid()} | {:error, term()}
  def enqueue(attrs, supervisor \\ @sup) when is_map(attrs) do
    case Task.Supervisor.start_child(supervisor, fn ->
           safe_record(attrs, :async)
         end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[Audit.AsyncWriter] enqueue failed to spawn: #{inspect(reason)}")
        {:error, reason}
    end

    # a dead/unregistered supervisor EXITs the call; a bad supervisor ref
    # raises — an audit handoff must never take the producer down with it
  rescue
    # reach:disable-next-line bare_rescue
    error ->
      Logger.warning("[Audit.AsyncWriter] enqueue failed to spawn: #{inspect(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("[Audit.AsyncWriter] enqueue failed to spawn: exit #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  @spec sync(map()) :: :ok
  def sync(attrs) when is_map(attrs) do
    safe_record(attrs, :sync)
    :ok
  end

  @doc """
  Drain in-flight async audit writes. Loops until the supervisor
  reports no live children or `timeout_ms` elapses. Tasks scheduled
  by stragglers during the drain window are picked up by the loop.

  Public so it can be invoked from `Application.stop/1` later, but
  currently used only from test sandbox teardown to keep
  `Postgrex.Protocol ... owner exited` noise out of the suite.
  """
  @spec flush(non_neg_integer()) :: :ok
  def flush(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    drain_loop(deadline)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp drain_loop(deadline) do
    case Task.Supervisor.children(@sup) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          if Process.alive?(pid) do
            ref = Process.monitor(pid)
            remaining = max(deadline - System.monotonic_time(:millisecond), 0)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              remaining ->
                Process.demonitor(ref, [:flush])
                :ok
            end
          end
        end)

        if System.monotonic_time(:millisecond) < deadline do
          drain_loop(deadline)
        else
          :ok
        end
    end
  end

  defp safe_record(attrs, mode) do
    do_record(attrs)
    # losing an audit row is preferable to dropping the request
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      if sandbox_shutdown?(e) do
        # `DBConnection.ConnectionError` is raised (not thrown) when
        # the sandbox owner exits mid-checkout, so we must look for
        # it here as well as in the catch clause below.
        :ok
      else
        Logger.warning(
          "[Audit.AsyncWriter] #{mode} write failed: #{Exception.message(e)} attrs=#{inspect(attrs)}"
        )
      end
  catch
    kind, payload ->
      if sandbox_shutdown?(payload) do
        # Test sandbox tore down before the cast'd write could check out a
        # connection. Not interesting; drop without logging.
        :ok
      else
        Logger.warning(
          "[Audit.AsyncWriter] #{mode} write #{kind}: #{inspect(payload)} attrs=#{inspect(attrs)}"
        )
      end
  end

  defp sandbox_shutdown?({:shutdown, reason}) when is_binary(reason),
    do: sandbox_text?(reason)

  defp sandbox_shutdown?({{:shutdown, reason}, _}) when is_binary(reason),
    do: sandbox_text?(reason)

  defp sandbox_shutdown?(%DBConnection.ConnectionError{message: msg}) when is_binary(msg),
    do: sandbox_text?(msg)

  defp sandbox_shutdown?(_), do: false

  defp sandbox_text?(text),
    do: String.contains?(text, "owner") and String.contains?(text, "exited")

  defp do_record(%{tenant_id: tenant_id} = attrs) when is_binary(tenant_id) do
    attrs
    |> Map.delete(:tenant_id)
    |> Event.record(tenant: tenant_id, actor: Actor.system(tenant_id))
    |> case do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        Logger.debug("[Audit.AsyncWriter] write rejected: #{inspect(err)}")
        :ok

      other ->
        Logger.warning("[Audit.AsyncWriter] write returned: #{inspect(other)}")
        :ok
    end
  end

  defp do_record(attrs) do
    Logger.warning(
      "[Audit.AsyncWriter] dropping audit attrs without tenant_id: #{inspect(attrs)}"
    )

    :ok
  end
end
