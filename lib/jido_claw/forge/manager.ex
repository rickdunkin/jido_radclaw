defmodule JidoClaw.Forge.Manager do
  use GenServer
  require Logger

  @registry JidoClaw.Forge.SessionRegistry
  @supervisor JidoClaw.Forge.HarnessSupervisor

  @max_recovery_attempts 3

  defstruct sessions: MapSet.new(),
            session_runners: %{},
            runner_counts: %{},
            recovery_attempts: %{},
            max_sessions: 50,
            max_per_runner: %{claude_code: 10, shell: 20, workflow: 10}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_session(session_id, spec) do
    GenServer.call(__MODULE__, {:start_session, session_id, spec}, 30_000)
  end

  def stop_session(session_id, reason \\ :normal) do
    GenServer.call(__MODULE__, {:stop_session, session_id, reason})
  end

  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  def get_session(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Cluster-aware session lookup. Tries local Registry first, then falls back
  to :pg process groups for cross-node discovery when clustering is enabled.
  """
  def get_session_cluster(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        if Application.get_env(:jido_claw, :cluster_enabled, false) do
          case :pg.get_members(:jido_claw, {:forge_session, session_id}) do
            [pid | _] -> {:ok, pid}
            [] -> {:error, :not_found}
          end
        else
          {:error, :not_found}
        end
    end
  catch
    _, _ -> {:error, :not_found}
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_sessions: Keyword.get(opts, :max_sessions, 50),
      max_per_runner:
        Keyword.get(opts, :max_per_runner, %{claude_code: 10, shell: 20, workflow: 10})
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_session, session_id, spec}, _from, state) do
    runner_type = Map.get(spec, :runner, :shell)
    runner_count = Map.get(state.runner_counts, runner_type, 0)
    max_for_runner = Map.get(state.max_per_runner, runner_type, state.max_sessions)

    cond do
      MapSet.size(state.sessions) >= state.max_sessions ->
        {:reply, {:error, :at_capacity}, state}

      runner_count >= max_for_runner ->
        {:reply, {:error, :runner_at_capacity}, state}

      true ->
        case Registry.lookup(@registry, session_id) do
          [{_pid, _}] ->
            {:reply, {:error, :already_exists}, state}

          [] ->
            if cluster_session_exists?(session_id) do
              {:reply, {:error, :already_exists}, state}
            else
              child_spec = {JidoClaw.Forge.Harness, {session_id, spec, []}}

              case DynamicSupervisor.start_child(@supervisor, child_spec) do
                {:ok, pid} ->
                  Process.monitor(pid)
                  handle = %{session_id: session_id, pid: pid}

                  new_state = %{
                    state
                    | sessions: MapSet.put(state.sessions, session_id),
                      session_runners: Map.put(state.session_runners, session_id, runner_type),
                      runner_counts: Map.update(state.runner_counts, runner_type, 1, &(&1 + 1))
                  }

                  JidoClaw.Forge.PubSub.broadcast_session_event({:session_started, session_id})
                  {:reply, {:ok, handle}, new_state}

                {:error, :already_claimed} ->
                  {:reply, {:error, :already_exists}, state}

                {:error, reason} ->
                  {:reply, {:error, reason}, state}
              end
            end
        end
    end
  end

  @impl true
  def handle_call({:stop_session, session_id, reason}, _from, state) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        # Persist cancelled phase before terminating so recovery can distinguish
        # graceful stops from crashes
        JidoClaw.Forge.Persistence.update_session_phase(session_id, :cancelled)
        DynamicSupervisor.terminate_child(@supervisor, pid)
        new_state = decrement_session(state, session_id)
        JidoClaw.Forge.PubSub.broadcast_session_event({:session_stopped, session_id, reason})
        {:reply, :ok, new_state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    {:reply, MapSet.to_list(state.sessions), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    dead =
      Enum.filter(MapSet.to_list(state.sessions), fn sid ->
        Registry.lookup(@registry, sid) == []
      end)

    new_state = Enum.reduce(dead, state, &decrement_session(&2, &1))

    # Always schedule recovery checks for dead sessions. The DB phase is the
    # authority on whether recovery is appropriate — Manager.stop_session already
    # sets :cancelled before terminating, so recoverable?/1 will reject those.
    # This avoids the ambiguity of :shutdown (could be user-initiated cancel or
    # external kill like Process.exit(pid, :shutdown)).
    Enum.each(dead, fn session_id ->
      send(self(), {:attempt_recovery, session_id})
    end)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:attempt_recovery, session_id}, state) do
    attempts = Map.get(state.recovery_attempts, session_id, 0)

    if attempts < @max_recovery_attempts && recoverable?(session_id) do
      Logger.info(
        "[Forge.Manager] Attempting recovery for #{session_id} (attempt #{attempts + 1}/#{@max_recovery_attempts})"
      )

      JidoClaw.Forge.PubSub.broadcast_session_event({:session_recovering, session_id})

      new_attempts = Map.put(state.recovery_attempts, session_id, attempts + 1)

      # Spawn a Task so Forge.wake -> Manager.start_session doesn't deadlock
      # (start_session does GenServer.call back to this process)
      Task.start(fn ->
        case JidoClaw.Forge.wake(session_id) do
          {:ok, _handle} ->
            Logger.info("[Forge.Manager] Recovery succeeded for #{session_id}")

          {:error, reason} ->
            Logger.warning(
              "[Forge.Manager] Recovery failed for #{session_id}: #{inspect(reason)}"
            )
        end
      end)

      {:noreply, %{state | recovery_attempts: new_attempts}}
    else
      if attempts >= @max_recovery_attempts do
        Logger.warning(
          "[Forge.Manager] Recovery exhausted for #{session_id} after #{attempts} attempts"
        )

        JidoClaw.Forge.PubSub.broadcast_session_event({:session_recovery_exhausted, session_id})
      end

      {:noreply, state}
    end
  end

  defp recoverable?(session_id) do
    try do
      db_session = JidoClaw.Forge.Persistence.find_session(session_id)
      checkpoint = JidoClaw.Forge.Persistence.latest_checkpoint(session_id)

      db_session != nil &&
        checkpoint != nil &&
        db_session.phase in [:running, :ready, :needs_input, :resuming, :failed]
    rescue
      _ -> false
    end
  end

  defp cluster_session_exists?(session_id) do
    if Application.get_env(:jido_claw, :cluster_enabled, false) do
      case :pg.get_members(:jido_claw, {:forge_session, session_id}) do
        [_ | _] -> true
        [] -> false
      end
    else
      false
    end
  catch
    _, _ -> false
  end

  defp decrement_session(state, session_id) do
    runner_type = Map.get(state.session_runners, session_id)

    %{
      state
      | sessions: MapSet.delete(state.sessions, session_id),
        session_runners: Map.delete(state.session_runners, session_id),
        runner_counts:
          if(runner_type,
            do: Map.update(state.runner_counts, runner_type, 0, &max(&1 - 1, 0)),
            else: state.runner_counts
          )
    }
  end
end
