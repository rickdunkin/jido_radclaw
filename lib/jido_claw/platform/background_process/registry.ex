defmodule JidoClaw.BackgroundProcess.Registry do
  @moduledoc """
  Tracks spawned OS processes (ports and PIDs) with output buffering.
  Two-phase termination: SIGTERM -> 5s delay -> SIGKILL.
  Auto-cleanup after 1 hour.
  """
  use GenServer
  require Logger

  @buffer_max_bytes 200 * 1024
  @cleanup_interval 3_600_000
  @kill_delay 5_000

  defstruct processes: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a background process."
  def register(id, port_or_pid, command, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register, id, port_or_pid, command, metadata})
  end

  @doc "Append output to a process buffer."
  def append_output(id, data) do
    GenServer.cast(__MODULE__, {:append_output, id, data})
  end

  @doc "Get process info and buffered output."
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc "List all tracked processes."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Terminate a process with two-phase shutdown."
  def terminate_process(id) do
    GenServer.call(__MODULE__, {:terminate, id})
  end

  @doc "Remove a completed/exited process from tracking."
  def deregister(id) do
    GenServer.cast(__MODULE__, {:deregister, id})
  end

  # -- Server --

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, id, port_or_pid, command, metadata}, _from, state) do
    entry = %{
      port_or_pid: port_or_pid,
      command: command,
      metadata: metadata,
      output_buffer: <<>>,
      started_at: DateTime.utc_now(),
      status: :running
    }

    processes = Map.put(state.processes, id, entry)
    {:reply, :ok, %{state | processes: processes}}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.get(state.processes, id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call(:list, _from, state) do
    list =
      state.processes
      |> Enum.map(fn {id, entry} ->
        %{id: id, command: entry.command, status: entry.status, started_at: entry.started_at}
      end)

    {:reply, list, state}
  end

  def handle_call({:terminate, id}, _from, state) do
    case Map.get(state.processes, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{port_or_pid: port} = entry when is_port(port) ->
        # Phase 1: SIGTERM
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        # Phase 2: SIGKILL after delay
        Process.send_after(self(), {:force_kill, id, port}, @kill_delay)
        updated = %{entry | status: :terminating}
        {:reply, :ok, %{state | processes: Map.put(state.processes, id, updated)}}

      %{port_or_pid: pid} = entry when is_pid(pid) ->
        Process.exit(pid, :shutdown)
        Process.send_after(self(), {:force_kill_pid, id, pid}, @kill_delay)
        updated = %{entry | status: :terminating}
        {:reply, :ok, %{state | processes: Map.put(state.processes, id, updated)}}
    end
  end

  @impl true
  def handle_cast({:append_output, id, data}, state) do
    case Map.get(state.processes, id) do
      nil ->
        {:noreply, state}

      entry ->
        buffer = entry.output_buffer <> data

        # Trim to max buffer size (keep tail)
        trimmed =
          if byte_size(buffer) > @buffer_max_bytes do
            binary_part(buffer, byte_size(buffer) - @buffer_max_bytes, @buffer_max_bytes)
          else
            buffer
          end

        updated = %{entry | output_buffer: trimmed}
        {:noreply, %{state | processes: Map.put(state.processes, id, updated)}}
    end
  end

  def handle_cast({:deregister, id}, state) do
    {:noreply, %{state | processes: Map.delete(state.processes, id)}}
  end

  @impl true
  def handle_info({:force_kill, id, port}, state) do
    try do
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      System.cmd("kill", ["-9", to_string(os_pid)])
    catch
      _, _ -> :ok
    end

    case Map.get(state.processes, id) do
      nil ->
        {:noreply, state}

      entry ->
        updated = %{entry | status: :killed}
        {:noreply, %{state | processes: Map.put(state.processes, id, updated)}}
    end
  end

  def handle_info({:force_kill_pid, id, pid}, state) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    case Map.get(state.processes, id) do
      nil ->
        {:noreply, state}

      entry ->
        updated = %{entry | status: :killed}
        {:noreply, %{state | processes: Map.put(state.processes, id, updated)}}
    end
  end

  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)

    cleaned =
      state.processes
      |> Enum.reject(fn {_id, entry} ->
        entry.status in [:exited, :killed] and
          DateTime.compare(entry.started_at, one_hour_ago) == :lt
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | processes: cleaned}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.processes, fn {id, %{port_or_pid: port_or_pid, status: status}} ->
      if status in [:running, :terminating] do
        try do
          case port_or_pid do
            port when is_port(port) -> Port.close(port)
            pid when is_pid(pid) -> Process.exit(pid, :shutdown)
          end
        catch
          _, _ -> :ok
        end

        Logger.debug("[BackgroundProcess.Registry] Killed process #{id} during shutdown")
      end
    end)

    :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
