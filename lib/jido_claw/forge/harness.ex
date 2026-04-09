defmodule JidoClaw.Forge.Harness do
  use GenServer, restart: :temporary
  require Logger

  alias JidoClaw.Forge.{Sandbox, Bootstrap, PubSub}

  @registry JidoClaw.Forge.SessionRegistry

  defstruct [
    :session_id, :spec, :sandbox_id, :client, :runner, :runner_state,
    state: :starting, iteration: 0, output_sequence: 0,
    started_at: nil, last_activity: nil,
    resume_checkpoint_id: nil, sandbox_module: nil
  ]

  def start_link({session_id, spec, _opts}) do
    GenServer.start_link(__MODULE__, {session_id, spec},
      name: {:via, Registry, {@registry, session_id}})
  end

  def run_iteration(session_id, opts \\ []) do
    call(session_id, {:run_iteration, opts})
  end

  def exec(session_id, command, opts \\ []) do
    call(session_id, {:exec, command, opts})
  end

  def apply_input(session_id, input) do
    call(session_id, {:apply_input, input})
  end

  def status(session_id) do
    call(session_id, :status)
  end

  defp call(session_id, msg) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> GenServer.call(pid, msg, 300_000)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init({session_id, spec}) do
    state = %__MODULE__{
      session_id: session_id,
      spec: spec,
      started_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      sandbox_module: resolve_client(Map.get(spec, :sandbox, :default))
    }

    send(self(), :provision)
    {:ok, state}
  end

  @impl true
  def handle_info(:provision, state) do
    sandbox_spec =
      state.spec
      |> Map.get(:sandbox_spec, %{})
      |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))

    case state.sandbox_module.create(sandbox_spec) do
      {:ok, client, sandbox_id} ->
        new_state = %{state | client: client, sandbox_id: sandbox_id, state: :bootstrapping}

        if state.resume_checkpoint_id do
          send(self(), :init_runner)
        else
          send(self(), :bootstrap)
        end

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Forge.Harness] Provision failed for #{state.session_id}: #{inspect(reason)}")
        {:stop, {:provision_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:bootstrap, state) do
    env = Map.get(state.spec, :env, %{})
    if map_size(env) > 0 do
      Sandbox.inject_env(state.client, env)
    end

    bootstrap_steps = Map.get(state.spec, :bootstrap_steps, [])

    case Bootstrap.execute(state.client, bootstrap_steps) do
      :ok ->
        new_state = %{state | state: :initializing}
        send(self(), :init_runner)
        {:noreply, new_state}

      {:error, step, reason} ->
        Logger.error("[Forge.Harness] Bootstrap failed at step #{inspect(step)}: #{inspect(reason)}")
        {:stop, {:bootstrap_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:init_runner, state) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(state.client, runner_config) do
      :ok ->
        new_state = %{state | runner: runner_module, runner_state: runner_config, state: :ready}
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:ok, runner_state} ->
        new_state = %{state | runner: runner_module, runner_state: runner_state, state: :ready}
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Forge.Harness] Runner init failed: #{inspect(reason)}")
        {:stop, {:runner_init_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, opts}, from, %{state: :ready} = state) do
    new_state = %{state | state: :running, iteration: state.iteration + 1, last_activity: DateTime.utc_now()}

    session_pid = self()
    Task.start(fn ->
      result = state.runner.run_iteration(state.client, state.runner_state, opts)
      GenServer.cast(session_pid, {:iteration_complete, result, from, new_state.iteration})
    end)

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:run_iteration, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:exec, command, opts}, _from, %{state: :ready} = state) do
    result = Sandbox.exec(state.client, command, opts)
    new_state = %{state | last_activity: DateTime.utc_now()}
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:exec, _command, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:apply_input, input}, _from, %{state: :needs_input} = state) do
    case state.runner.apply_input(state.client, input, state.runner_state) do
      :ok ->
        new_state = %{state | state: :ready, last_activity: DateTime.utc_now()}
        {:reply, :ok, new_state}

      {:ok, new_runner_state} ->
        new_state = %{state | state: :ready, runner_state: new_runner_state, last_activity: DateTime.utc_now()}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:apply_input, _input}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      state: state.state,
      iteration: state.iteration,
      runner: state.runner,
      sandbox_id: state.sandbox_id,
      started_at: state.started_at,
      last_activity: state.last_activity
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:iteration_complete, {:ok, result}, from, _iteration}, state) do
    new_state = case result.status do
      :needs_input ->
        PubSub.broadcast(state.session_id, {:needs_input, %{prompt: result.question}})
        %{state | state: :needs_input}

      :done ->
        PubSub.broadcast(state.session_id, {:output, %{chunk: result.output, seq: state.output_sequence + 1}})
        %{state | state: :ready, output_sequence: state.output_sequence + 1}

      :continue ->
        PubSub.broadcast(state.session_id, {:output, %{chunk: result.output, seq: state.output_sequence + 1}})
        %{state | state: :ready, output_sequence: state.output_sequence + 1}

      :error ->
        PubSub.broadcast(state.session_id, {:error, %{reason: result.error}})
        %{state | state: :ready}

      _ ->
        %{state | state: :ready}
    end

    # Merge runner state from metadata if the runner returned updated state
    new_state = case result.metadata do
      %{state: updated_runner_state} ->
        %{new_state | runner_state: updated_runner_state}
      _ ->
        new_state
    end

    GenServer.reply(from, {:ok, result})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:iteration_complete, {:error, reason}, from, _iteration}, state) do
    PubSub.broadcast(state.session_id, {:error, %{reason: reason}})
    GenServer.reply(from, {:error, reason})
    {:noreply, %{state | state: :ready}}
  end

  @impl true
  def terminate(reason, state) do
    PubSub.broadcast(state.session_id, {:stopped, reason})

    if state.runner && function_exported?(state.runner, :terminate, 2) do
      state.runner.terminate(state.client, reason)
    end

    if state.client && state.sandbox_id do
      Sandbox.destroy(state.client, state.sandbox_id)
    end

    :ok
  end

  defp resolve_runner(:shell), do: JidoClaw.Forge.Runners.Shell
  defp resolve_runner(:claude_code), do: JidoClaw.Forge.Runners.ClaudeCode
  defp resolve_runner(:workflow), do: JidoClaw.Forge.Runners.Workflow
  defp resolve_runner(:custom), do: JidoClaw.Forge.Runners.Custom
  defp resolve_runner(module) when is_atom(module), do: module

  defp resolve_client(:default), do: Sandbox
  defp resolve_client(:fake), do: JidoClaw.Forge.Sandbox.Local
  defp resolve_client(:docker_sandbox), do: JidoClaw.Forge.Sandbox.Docker
  defp resolve_client(module) when is_atom(module), do: module
end
