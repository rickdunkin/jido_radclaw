defmodule JidoClaw.Forge.Harness do
  use GenServer, restart: :temporary
  require Logger

  alias JidoClaw.Forge.{Sandbox, Bootstrap, Persistence, PubSub, ResourceProvisioner}

  @registry JidoClaw.Forge.SessionRegistry

  defstruct [
    :session_id, :spec, :sandbox_id, :client, :runner, :runner_state,
    state: :starting, iteration: 0, output_sequence: 0,
    started_at: nil, last_activity: nil,
    resume_checkpoint_id: nil, sandbox_module: nil,
    sandbox_status: :none
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
        resume_checkpoint_id = Map.get(spec, :resume_checkpoint_id)

        state = %__MODULE__{
          session_id: session_id,
          spec: spec,
          started_at: DateTime.utc_now(),
          last_activity: DateTime.utc_now(),
          sandbox_module: resolve_client(Map.get(spec, :sandbox, :default)),
          resume_checkpoint_id: resume_checkpoint_id
        }

        persist(fn -> Persistence.record_session_started(session_id, spec) end)
        persist(fn -> log_event(state, "session.started") end)

        state =
          case resume_checkpoint_id do
            nil ->
              if Map.get(spec, :deferred_provision, false) do
                persist(fn -> log_event(state, "provision.deferred") end)
                persist(fn -> update_phase(state, :ready) end)
                PubSub.broadcast(state.session_id, {:ready, state.session_id})
                %{state | state: :ready}
              else
                send(self(), :provision)
                state
              end

            checkpoint_id ->
              persist(fn -> log_event(state, "session.recovering", %{checkpoint_id: checkpoint_id}) end)
              persist(fn -> update_phase(state, :resuming) end)
              send(self(), {:recover, checkpoint_id})
              state
          end

        {:ok, state}

      {:error, reasons} ->
        Logger.error("[Forge.Harness] Resource validation failed for #{session_id}: #{inspect(reasons)}")
        {:stop, {:resource_validation_failed, reasons}}
    end
  end

  @impl true
  def handle_info(:provision, state) do
    state = %{state | sandbox_status: :provisioning}
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
        new_state = %{state | runner: runner_module, runner_state: runner_config, state: :ready, sandbox_status: :ready}
        persist(fn -> log_event(new_state, "runner.ready") end)
        persist(fn -> update_phase(new_state, :ready) end)
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:ok, runner_state} ->
        new_state = %{state | runner: runner_module, runner_state: runner_state, state: :ready, sandbox_status: :ready}
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
  def handle_info({:recover, checkpoint_id}, state) do
    persist(fn -> log_event(state, "recovery.started", %{checkpoint_id: checkpoint_id}) end)

    with checkpoint when not is_nil(checkpoint) <- load_checkpoint(checkpoint_id),
         {:ok, state} <- recover_provision(state),
         {:ok, state} <- recover_bootstrap(state),
         {:ok, state} <- recover_runner(state, checkpoint) do
      state = %{state | sandbox_status: :ready}
      persist(fn -> log_event(state, "recovery.completed") end)
      persist(fn -> update_phase(state, :ready) end)
      PubSub.broadcast(state.session_id, {:ready, state.session_id})
      {:noreply, state}
    else
      nil ->
        persist(fn -> log_event(state, "recovery.failed", %{reason: "checkpoint_not_found"}) end)
        Logger.error("[Forge.Harness] Recovery failed for #{state.session_id}: checkpoint #{checkpoint_id} not found")
        {:stop, {:recovery_failed, :checkpoint_not_found}, state}

      {:error, reason} ->
        persist(fn -> log_event(state, "recovery.failed", %{reason: inspect(reason)}) end)
        Logger.error("[Forge.Harness] Recovery failed for #{state.session_id}: #{inspect(reason)}")
        {:stop, {:recovery_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, opts}, from, %{state: :ready} = state) do
    case ensure_sandbox(state) do
      {:ok, state} ->
        new_state = %{state | state: :running, iteration: state.iteration + 1, last_activity: DateTime.utc_now()}

        persist(fn -> log_event(new_state, "iteration.started", %{iteration: new_state.iteration}) end)
        persist(fn -> update_phase(new_state, :running) end)

        session_pid = self()
        Task.start(fn ->
          result = state.runner.run_iteration(state.client, state.runner_state, opts)
          GenServer.cast(session_pid, {:iteration_complete, result, from, new_state.iteration})
        end)

        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, {:provision_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:exec, command, opts}, _from, %{state: :ready} = state) do
    case ensure_sandbox(state) do
      {:ok, state} ->
        persist(fn -> log_event(state, "exec.started", %{command: command}) end)
        result = Sandbox.exec(state.client, command, opts)
        persist(fn -> log_event(state, "exec.completed", %{command: command}) end)
        new_state = %{state | last_activity: DateTime.utc_now()}
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, {:provision_failed, reason}}, state}
    end
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
      sandbox_status: state.sandbox_status,
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
      snapshot = serialize_runner_state(state.runner, new_state.runner_state)
      Persistence.save_checkpoint(state.session_id, state.iteration, snapshot, %{
        resources: Map.get(state.spec, :resources, []),
        bootstrap_steps: Map.get(state.spec, :bootstrap_steps, []),
        output_sequence: new_state.output_sequence
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
          # Only :normal means the session genuinely finished its work.
          # :shutdown and {:shutdown, _} may be external kills (e.g.
          # Process.exit(pid, :shutdown)) that should remain recoverable,
          # so mark them :failed. Manager.stop_session already sets
          # :cancelled before terminating — that's handled above.
          terminal_phase = if reason == :normal, do: :completed, else: :failed
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

  # Recovery helpers

  defp load_checkpoint(checkpoint_id) do
    try do
      JidoClaw.Forge.Resources.Checkpoint
      |> Ash.get!(checkpoint_id, authorize?: false)
    rescue
      _ -> nil
    end
  end

  defp recover_provision(state) do
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
        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)
        {:ok, new_state}

      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  defp recover_bootstrap(state) do
    env = Map.get(state.spec, :env, %{})
    if map_size(env) > 0 do
      Sandbox.inject_env(state.client, env)
    end

    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(state.client, resources),
         :ok <- run_bootstrap_steps(state) do
      {:ok, %{state | state: :initializing}}
    else
      {:error, _resource_or_step, reason} -> {:error, {:bootstrap_failed, reason}}
      {:error, reason} -> {:error, {:bootstrap_failed, reason}}
    end
  end

  defp recover_runner(state, checkpoint) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(state.client, runner_config) do
      init_result when init_result == :ok or is_tuple(init_result) ->
        base_runner_state = case init_result do
          :ok -> runner_config
          {:ok, rs} -> rs
        end

        # Overlay checkpoint state using restore_state callback if available,
        # otherwise merge the snapshot directly
        snapshot = checkpoint.runner_state_snapshot || %{}

        runner_state =
          if function_exported?(runner_module, :restore_state, 2) do
            case runner_module.restore_state(base_runner_state, snapshot) do
              {:ok, restored} -> restored
              {:error, _} -> Map.merge(base_runner_state, snapshot)
            end
          else
            Map.merge(base_runner_state, snapshot)
          end

        checkpoint_metadata = checkpoint.metadata || %{}

        new_state = %{state |
          runner: runner_module,
          runner_state: runner_state,
          state: :ready,
          iteration: checkpoint.exec_session_sequence || 0,
          output_sequence: Map.get(checkpoint_metadata, "output_sequence") ||
                           Map.get(checkpoint_metadata, :output_sequence) ||
                           checkpoint.exec_session_sequence || 0
        }

        {:ok, new_state}

      {:error, reason} ->
        {:error, {:runner_init_failed, reason}}
    end
  end

  # Lazy provisioning helpers

  defp ensure_sandbox(%{client: nil} = state), do: provision_sync(state)
  defp ensure_sandbox(state), do: {:ok, state}

  defp provision_sync(state) do
    state = %{state | sandbox_status: :provisioning}
    persist(fn -> log_event(state, "sandbox.provisioning") end)
    persist(fn -> update_phase(state, :provisioning) end)

    case provision_sandbox_sync(state) do
      {:ok, provisioned} ->
        case bootstrap_and_init_sync(provisioned) do
          {:ok, _state} = ok ->
            ok

          {:error, reason} ->
            destroy_sandbox(provisioned)
            persist(fn -> update_phase(state, :ready) end)
            {:error, reason}
        end

      {:error, reason} ->
        persist(fn -> update_phase(state, :ready) end)
        {:error, reason}
    end
  end

  defp provision_sandbox_sync(state) do
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
        {:ok, new_state}

      {:error, reason} ->
        persist(fn -> log_event(state, "sandbox.provision_failed", %{reason: inspect(reason)}) end)
        {:error, {:sandbox_creation_failed, reason}}
    end
  end

  defp bootstrap_and_init_sync(state) do
    with {:ok, state} <- bootstrap_sync(state),
         {:ok, state} <- init_runner_sync(state) do
      state = %{state | sandbox_status: :ready}
      persist(fn -> log_event(state, "runner.ready") end)
      persist(fn -> update_phase(state, :ready) end)
      {:ok, state}
    end
  end

  defp bootstrap_sync(state) do
    persist(fn -> log_event(state, "bootstrap.started") end)
    persist(fn -> update_phase(state, :bootstrapping) end)

    env = Map.get(state.spec, :env, %{})
    if map_size(env) > 0 do
      Sandbox.inject_env(state.client, env)
    end

    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(state.client, resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      {:ok, %{state | state: :initializing}}
    else
      {:error, resource, reason} when is_map(resource) ->
        persist(fn -> log_event(state, "resource.provision_failed", %{resource: inspect(resource), reason: inspect(reason)}) end)
        {:error, {:resource_provision_failed, reason}}

      {:error, step, reason} ->
        persist(fn -> log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)}) end)
        {:error, {:bootstrap_failed, reason}}

      {:error, reason} ->
        persist(fn -> log_event(state, "bootstrap.failed", %{reason: inspect(reason)}) end)
        {:error, {:bootstrap_failed, reason}}
    end
  end

  defp init_runner_sync(state) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(state.client, runner_config) do
      :ok ->
        {:ok, %{state | runner: runner_module, runner_state: runner_config, state: :ready}}

      {:ok, runner_state} ->
        {:ok, %{state | runner: runner_module, runner_state: runner_state, state: :ready}}

      {:error, reason} ->
        persist(fn -> log_event(state, "runner.init_failed", %{reason: inspect(reason)}) end)
        {:error, {:runner_init_failed, reason}}
    end
  end

  defp destroy_sandbox(state) do
    if state.client && state.sandbox_id do
      Sandbox.destroy(state.client, state.sandbox_id)
    end
  end

  defp serialize_runner_state(runner_module, runner_state) do
    if runner_module && function_exported?(runner_module, :serialize_state, 1) do
      runner_module.serialize_state(runner_state)
    else
      runner_state
    end
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
