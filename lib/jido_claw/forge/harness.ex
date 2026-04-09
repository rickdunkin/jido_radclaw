defmodule JidoClaw.Forge.Harness do
  use GenServer, restart: :temporary
  require Logger

  alias JidoClaw.Forge.{Sandbox, Bootstrap, Persistence, PubSub, ResourceProvisioner}

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
    resources = Map.get(spec, :resources, [])

    case ResourceProvisioner.validate_resources(resources) do
      :ok ->
        state = %__MODULE__{
          session_id: session_id,
          spec: spec,
          started_at: DateTime.utc_now(),
          last_activity: DateTime.utc_now(),
          sandbox_module: resolve_client(Map.get(spec, :sandbox, :default))
        }

        persist(fn -> Persistence.record_session_started(session_id, spec) end)
        persist(fn -> log_event(state, "session.started") end)

        send(self(), :provision)
        {:ok, state}

      {:error, reasons} ->
        Logger.error("[Forge.Harness] Resource validation failed for #{session_id}: #{inspect(reasons)}")
        {:stop, {:resource_validation_failed, reasons}}
    end
  end

  @impl true
  def handle_info(:provision, state) do
    persist(fn -> log_event(state, "sandbox.provisioning") end)
    persist(fn -> update_phase(state, :provisioning) end)

    resources = Map.get(state.spec, :resources, [])
    resource_mounts = ResourceProvisioner.file_mount_specs(resources)

    sandbox_spec =
      state.spec
      |> Map.get(:sandbox_spec, %{})
      |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))
      |> merge_resource_mounts(resource_mounts)

    case state.sandbox_module.create(sandbox_spec) do
      {:ok, client, sandbox_id} ->
        new_state = %{state | client: client, sandbox_id: sandbox_id, state: :bootstrapping}

        persist(fn -> log_event(new_state, "sandbox.provisioned", %{sandbox_id: sandbox_id}) end)
        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)

        if state.resume_checkpoint_id do
          send(self(), :init_runner)
        else
          send(self(), :bootstrap)
        end

        {:noreply, new_state}

      {:error, reason} ->
        persist(fn -> log_event(state, "sandbox.provision_failed", %{reason: inspect(reason)}) end)
        Logger.error("[Forge.Harness] Provision failed for #{state.session_id}: #{inspect(reason)}")
        {:stop, {:provision_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:bootstrap, state) do
    persist(fn -> log_event(state, "bootstrap.started") end)
    persist(fn -> update_phase(state, :bootstrapping) end)

    env = Map.get(state.spec, :env, %{})
    if map_size(env) > 0 do
      Sandbox.inject_env(state.client, env)
    end

    # Provision declarative resources (git repos, env vars, secrets)
    # File mounts are already handled at sandbox creation time.
    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(state.client, resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      new_state = %{state | state: :initializing}
      send(self(), :init_runner)
      {:noreply, new_state}
    else
      {:error, resource, reason} when is_map(resource) ->
        persist(fn -> log_event(state, "resource.provision_failed", %{resource: inspect(resource), reason: inspect(reason)}) end)
        Logger.error("[Forge.Harness] Resource provisioning failed: #{inspect(reason)}")
        {:stop, {:resource_provision_failed, reason}, state}

      {:error, step, reason} ->
        persist(fn -> log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)}) end)
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
        persist(fn -> log_event(new_state, "runner.ready") end)
        persist(fn -> update_phase(new_state, :ready) end)
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:ok, runner_state} ->
        new_state = %{state | runner: runner_module, runner_state: runner_state, state: :ready}
        persist(fn -> log_event(new_state, "runner.ready") end)
        persist(fn -> update_phase(new_state, :ready) end)
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:error, reason} ->
        persist(fn -> log_event(state, "runner.init_failed", %{reason: inspect(reason)}) end)
        Logger.error("[Forge.Harness] Runner init failed: #{inspect(reason)}")
        {:stop, {:runner_init_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, opts}, from, %{state: :ready} = state) do
    new_state = %{state | state: :running, iteration: state.iteration + 1, last_activity: DateTime.utc_now()}

    persist(fn -> log_event(new_state, "iteration.started", %{iteration: new_state.iteration}) end)
    persist(fn -> update_phase(new_state, :running) end)

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
    persist(fn -> log_event(state, "exec.started", %{command: command}) end)
    result = Sandbox.exec(state.client, command, opts)
    persist(fn -> log_event(state, "exec.completed", %{command: command}) end)
    new_state = %{state | last_activity: DateTime.utc_now()}
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:exec, _command, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:apply_input, input}, _from, %{state: :needs_input} = state) do
    persist(fn -> log_event(state, "input.received") end)

    case state.runner.apply_input(state.client, input, state.runner_state) do
      :ok ->
        new_state = %{state | state: :ready, last_activity: DateTime.utc_now()}
        persist(fn -> update_phase(new_state, :ready) end)
        {:reply, :ok, new_state}

      {:ok, new_runner_state} ->
        new_state = %{state | state: :ready, runner_state: new_runner_state, last_activity: DateTime.utc_now()}
        persist(fn -> update_phase(new_state, :ready) end)
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

    persist(fn ->
      log_event(new_state, "iteration.completed", %{
        iteration: state.iteration,
        status: result.status,
        output_sequence: new_state.output_sequence
      })
    end)

    persist(fn ->
      Persistence.record_execution_complete(
        state.session_id,
        Map.get(result, :output, ""),
        Map.get(result, :exit_code, 0),
        state.iteration
      )
    end)

    persist(fn ->
      Persistence.save_checkpoint(state.session_id, state.iteration, new_state.runner_state, %{
        resources: Map.get(state.spec, :resources, []),
        bootstrap_steps: Map.get(state.spec, :bootstrap_steps, [])
      })
    end)

    persist(fn -> update_phase(new_state, new_state.state) end)

    GenServer.reply(from, {:ok, result})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:iteration_complete, {:error, reason}, from, _iteration}, state) do
    persist(fn -> log_event(state, "iteration.failed", %{reason: inspect(reason)}) end)
    persist(fn -> update_phase(state, :ready) end)
    PubSub.broadcast(state.session_id, {:error, %{reason: reason}})
    GenServer.reply(from, {:error, reason})
    {:noreply, %{state | state: :ready}}
  end

  @impl true
  def terminate(reason, state) do
    persist(fn -> log_event(state, "session.stopped", %{reason: inspect(reason)}) end)

    # Only update phase if not already in a terminal state (e.g. Manager sets
    # :cancelled before terminating the child — don't overwrite that).
    persist(fn ->
      case Persistence.find_session(state.session_id) do
        %{phase: phase} when phase in [:cancelled, :completed, :failed] ->
          :ok

        _ ->
          terminal_phase = if reason in [:normal, :shutdown], do: :completed, else: :failed
          update_phase(state, terminal_phase)
      end
    end)

    PubSub.broadcast(state.session_id, {:stopped, reason})

    if state.runner && function_exported?(state.runner, :terminate, 2) do
      state.runner.terminate(state.client, reason)
    end

    if state.client && state.sandbox_id do
      Sandbox.destroy(state.client, state.sandbox_id)
    end

    :ok
  end

  # Persistence helpers — fire-and-forget, never crash the Harness
  defp log_event(state, event_type, data \\ %{}) do
    Persistence.log_event(state.session_id, event_type, data, state.iteration)
  end

  defp update_phase(state, phase) do
    Persistence.update_session_phase(state.session_id, phase)
  end

  defp persist(fun) do
    try do
      fun.()
    rescue
      e -> Logger.warning("[Forge.Harness] Persistence error: #{inspect(e)}")
    end
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

  defp merge_resource_mounts(sandbox_spec, []), do: sandbox_spec

  defp merge_resource_mounts(sandbox_spec, mounts) do
    existing = Map.get(sandbox_spec, :extra_mounts, [])
    Map.put(sandbox_spec, :extra_mounts, existing ++ mounts)
  end

  defp run_bootstrap_steps(state) do
    bootstrap_steps = Map.get(state.spec, :bootstrap_steps, [])
    Bootstrap.execute(state.client, bootstrap_steps)
  end
end
