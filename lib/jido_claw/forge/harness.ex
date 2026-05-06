defmodule JidoClaw.Forge.Harness do
  use GenServer, restart: :temporary
  require Logger

  alias JidoClaw.Forge.{Sandbox, Bootstrap, Persistence, PubSub, ResourceProvisioner}

  @registry JidoClaw.Forge.SessionRegistry

  defstruct [
    :session_id,
    :spec,
    :sandbox_id,
    :runner,
    :runner_state,
    clients: %{},
    default_client: :default,
    state: :starting,
    iteration: 0,
    output_sequence: 0,
    started_at: nil,
    last_activity: nil,
    resume_checkpoint_id: nil,
    sandbox_module: nil,
    sandbox_status: :none,
    input_sandbox: nil
  ]

  def start_link({session_id, spec, _opts}) do
    GenServer.start_link(__MODULE__, {session_id, spec},
      name: {:via, Registry, {@registry, session_id}}
    )
  end

  def run_iteration(session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    call(session_id, {:run_iteration, opts}, timeout)
  end

  def exec(session_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    call(session_id, {:exec, command, opts}, timeout)
  end

  def apply_input(session_id, input) do
    call(session_id, {:apply_input, input})
  end

  def status(session_id) do
    call(session_id, :status)
  end

  def attach_sandbox(session_id, name, sandbox_spec) when is_atom(name) do
    call(session_id, {:attach_sandbox, name, sandbox_spec})
  end

  def detach_sandbox(session_id, name) when is_atom(name) do
    call(session_id, {:detach_sandbox, name})
  end

  defp call(session_id, msg, timeout \\ 300_000) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          # Registry may hold a stale PID briefly after the process terminates
          # (monitor cleanup is async). Treat as not_found.
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      [] ->
        # Local Registry miss — try cluster-wide :pg lookup for remote sessions
        case cluster_lookup(session_id) do
          {:ok, pid} ->
            try do
              GenServer.call(pid, msg, timeout)
            catch
              :exit, {:noproc, _} -> {:error, :not_found}
            end

          :error ->
            {:error, :not_found}
        end
    end
  end

  @impl true
  def init({session_id, spec}) do
    resources = Map.get(spec, :resources, [])

    case ResourceProvisioner.validate_resources(resources) do
      :ok ->
        resume_checkpoint_id = Map.get(spec, :resume_checkpoint_id)

        # Claim session ownership atomically in the DB via advisory lock.
        # Both fresh starts and recovery go through this path — the lock
        # serializes all claim attempts for the same session_id cluster-wide.
        with :ok <- maybe_claim_session(session_id, spec, resume_checkpoint_id) do
          state = %__MODULE__{
            session_id: session_id,
            spec: spec,
            started_at: DateTime.utc_now(),
            last_activity: DateTime.utc_now(),
            sandbox_module: resolve_client(Map.get(spec, :sandbox, :default)),
            resume_checkpoint_id: resume_checkpoint_id
          }

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
                persist(fn ->
                  log_event(state, "session.recovering", %{checkpoint_id: checkpoint_id})
                end)

                persist(fn -> update_phase(state, :resuming) end)
                send(self(), {:recover, checkpoint_id})
                state
            end

          # Join :pg group for cluster-wide session discovery.
          # Only after a successful claim — failed claims must not appear in :pg.
          maybe_pg_join(session_id)

          {:ok, state}
        else
          {:error, :already_claimed} ->
            Logger.warning(
              "[Forge.Harness] Session #{session_id} already claimed by another node"
            )

            {:stop, :already_claimed}

          {:error, reason} ->
            Logger.error(
              "[Forge.Harness] Session claim failed for #{session_id}: #{inspect(reason)}"
            )

            {:stop, {:claim_failed, reason}}
        end

      {:error, reasons} ->
        Logger.error(
          "[Forge.Harness] Resource validation failed for #{session_id}: #{inspect(reasons)}"
        )

        {:stop, {:resource_validation_failed, reasons}}
    end
  end

  @impl true
  def handle_info(:provision, state) do
    state = %{state | sandbox_status: :provisioning}
    persist(fn -> log_event(state, "sandbox.provisioning") end)
    persist(fn -> update_phase(state, :provisioning) end)

    base_spec =
      state.spec
      |> Map.get(:sandbox_spec, %{})
      |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))

    create_spec = build_sandbox_spec(state, base_spec)

    case state.sandbox_module.create(create_spec) do
      {:ok, client, sandbox_id} ->
        entry = %{client: client, sandbox_id: sandbox_id, spec: base_spec}

        new_state = %{
          state
          | clients: Map.put(state.clients, state.default_client, entry),
            sandbox_id: sandbox_id,
            state: :bootstrapping
        }

        persist(fn -> log_event(new_state, "sandbox.provisioned", %{sandbox_id: sandbox_id}) end)
        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)

        if state.resume_checkpoint_id do
          send(self(), :init_runner)
        else
          send(self(), :bootstrap)
        end

        {:noreply, new_state}

      {:error, reason} ->
        persist(fn ->
          log_event(state, "sandbox.provision_failed", %{reason: inspect(reason)})
        end)

        Logger.error(
          "[Forge.Harness] Provision failed for #{state.session_id}: #{inspect(reason)}"
        )

        {:stop, {:provision_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:bootstrap, state) do
    persist(fn -> log_event(state, "bootstrap.started") end)
    persist(fn -> update_phase(state, :bootstrapping) end)

    env = Map.get(state.spec, :env, %{})

    if map_size(env) > 0 do
      Sandbox.inject_env(default_client(state), env)
    end

    # Provision declarative resources (git repos, env vars, secrets)
    # File mounts are already handled at sandbox creation time.
    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      new_state = %{state | state: :initializing}
      send(self(), :init_runner)
      {:noreply, new_state}
    else
      {:error, resource, reason} when is_map(resource) ->
        persist(fn ->
          log_event(state, "resource.provision_failed", %{
            resource: inspect(resource),
            reason: inspect(reason)
          })
        end)

        Logger.error("[Forge.Harness] Resource provisioning failed: #{inspect(reason)}")
        {:stop, {:resource_provision_failed, reason}, state}

      {:error, step, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)})
        end)

        Logger.error(
          "[Forge.Harness] Bootstrap failed at step #{inspect(step)}: #{inspect(reason)}"
        )

        {:stop, {:bootstrap_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:init_runner, state) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(default_client(state), runner_config) do
      :ok ->
        new_state = %{
          state
          | runner: runner_module,
            runner_state: runner_config,
            state: :ready,
            sandbox_status: :ready
        }

        init_preattached_sandboxes(new_state)
        persist(fn -> log_event(new_state, "runner.ready") end)
        persist(fn -> update_phase(new_state, :ready) end)
        PubSub.broadcast(state.session_id, {:ready, state.session_id})
        {:noreply, new_state}

      {:ok, runner_state} ->
        new_state = %{
          state
          | runner: runner_module,
            runner_state: runner_state,
            state: :ready,
            sandbox_status: :ready
        }

        init_preattached_sandboxes(new_state)
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
         {:ok, state} <- recover_runner(state, checkpoint),
         {:ok, state} <- recover_extra_sandboxes(state, checkpoint) do
      state = %{state | sandbox_status: :ready}
      persist(fn -> log_event(state, "recovery.completed") end)
      persist(fn -> update_phase(state, :ready) end)
      PubSub.broadcast(state.session_id, {:ready, state.session_id})
      {:noreply, state}
    else
      nil ->
        persist(fn -> log_event(state, "recovery.failed", %{reason: "checkpoint_not_found"}) end)

        Logger.error(
          "[Forge.Harness] Recovery failed for #{state.session_id}: checkpoint #{checkpoint_id} not found"
        )

        {:stop, {:recovery_failed, :checkpoint_not_found}, state}

      {:error, reason} ->
        persist(fn -> log_event(state, "recovery.failed", %{reason: inspect(reason)}) end)

        Logger.error(
          "[Forge.Harness] Recovery failed for #{state.session_id}: #{inspect(reason)}"
        )

        {:stop, {:recovery_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, opts}, from, %{state: :ready} = state) do
    case ensure_target_sandbox(state, opts) do
      {:ok, state, client} ->
        new_state = %{
          state
          | state: :running,
            iteration: state.iteration + 1,
            last_activity: DateTime.utc_now()
        }

        persist(fn ->
          log_event(new_state, "iteration.started", %{iteration: new_state.iteration})
        end)

        persist(fn -> update_phase(new_state, :running) end)

        target_sandbox = Keyword.get(opts, :sandbox, state.default_client)
        iteration_started_at = DateTime.utc_now()
        session_pid = self()

        Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
          result = state.runner.run_iteration(client, state.runner_state, opts)

          GenServer.cast(
            session_pid,
            {:iteration_complete, result, from, new_state.iteration, target_sandbox,
             iteration_started_at}
          )
        end)

        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_iteration, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:exec, command, opts}, _from, %{state: :ready} = state) do
    case ensure_target_sandbox(state, opts) do
      {:ok, state, client} ->
        persist(fn -> log_event(state, "exec.started", %{command: command}) end)
        result = Sandbox.exec(client, command, opts)
        persist(fn -> log_event(state, "exec.completed", %{command: command}) end)
        new_state = %{state | last_activity: DateTime.utc_now()}
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:exec, _command, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl true
  def handle_call({:apply_input, input}, _from, %{state: :needs_input} = state) do
    persist(fn -> log_event(state, "input.received") end)

    # Route input to the sandbox that triggered :needs_input
    client =
      case get_sandbox_entry(state, state.input_sandbox) do
        %{client: c} -> c
        nil -> default_client(state)
      end

    case state.runner.apply_input(client, input, state.runner_state) do
      :ok ->
        new_state = %{
          state
          | state: :ready,
            input_sandbox: nil,
            last_activity: DateTime.utc_now()
        }

        persist(fn -> update_phase(new_state, :ready) end)
        {:reply, :ok, new_state}

      {:ok, new_runner_state} ->
        new_state = %{
          state
          | state: :ready,
            input_sandbox: nil,
            runner_state: new_runner_state,
            last_activity: DateTime.utc_now()
        }

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
      sandboxes: Map.keys(state.clients),
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:attach_sandbox, name, sandbox_spec}, _from, state) do
    if Map.has_key?(state.clients, name) do
      {:reply, {:error, :already_attached}, state}
    else
      sandbox_module = resolve_client(Map.get(sandbox_spec, :sandbox, :default))
      create_spec = build_sandbox_spec(state, sandbox_spec)

      case sandbox_module.create(create_spec) do
        {:ok, client, sandbox_id} ->
          case bootstrap_client(state, client) do
            :ok ->
              # Store the original caller-provided spec, not the runtime-expanded
              # one with extra_mounts tuples. build_sandbox_spec recomputes mounts
              # from session resources at create time, so the original is sufficient
              # for recovery and is JSON-serializable for checkpoint persistence.
              entry = %{client: client, sandbox_id: sandbox_id, spec: sandbox_spec}
              new_state = %{state | clients: Map.put(state.clients, name, entry)}

              persist(fn ->
                log_event(new_state, "sandbox.attached", %{name: name, sandbox_id: sandbox_id})
              end)

              save_topology_checkpoint(new_state)
              {:reply, {:ok, %{name: name, sandbox_id: sandbox_id}}, new_state}

            {:error, reason} ->
              try do
                Sandbox.destroy(client, sandbox_id)
              rescue
                _ -> :ok
              end

              {:reply, {:error, {:bootstrap_failed, reason}}, state}
          end

        {:error, reason} ->
          {:reply, {:error, {:provision_failed, reason}}, state}
      end
    end
  end

  @impl true
  def handle_call({:detach_sandbox, name}, _from, state) do
    cond do
      name == state.default_client and state.state in [:running, :bootstrapping, :provisioning] ->
        {:reply, {:error, :cannot_detach_default_while_active}, state}

      state.state == :needs_input and state.input_sandbox == name ->
        {:reply, {:error, :cannot_detach_while_awaiting_input}, state}

      not Map.has_key?(state.clients, name) ->
        {:reply, {:error, :not_attached}, state}

      true ->
        entry = get_sandbox_entry(state, name)

        try do
          Sandbox.destroy(entry.client, entry.sandbox_id)
        rescue
          _ -> :ok
        end

        new_state = %{state | clients: Map.delete(state.clients, name)}
        persist(fn -> log_event(new_state, "sandbox.detached", %{name: name}) end)
        save_topology_checkpoint(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast(
        {:iteration_complete, {:ok, result}, from, _iteration, target_sandbox,
         iteration_started_at},
        state
      ) do
    new_state =
      case result.status do
        :needs_input ->
          PubSub.broadcast(state.session_id, {:needs_input, %{prompt: result.question}})
          %{state | state: :needs_input, input_sandbox: target_sandbox}

        :done ->
          PubSub.broadcast(
            state.session_id,
            {:output, %{chunk: result.output, seq: state.output_sequence + 1}}
          )

          %{state | state: :ready, output_sequence: state.output_sequence + 1}

        :continue ->
          PubSub.broadcast(
            state.session_id,
            {:output, %{chunk: result.output, seq: state.output_sequence + 1}}
          )

          %{state | state: :ready, output_sequence: state.output_sequence + 1}

        :error ->
          PubSub.broadcast(state.session_id, {:error, %{reason: result.error}})
          %{state | state: :ready}

        _ ->
          %{state | state: :ready}
      end

    # Merge runner state from metadata if the runner returned updated state
    new_state =
      case result.metadata do
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
        state.iteration,
        result.status,
        iteration_started_at
      )
    end)

    save_topology_checkpoint(new_state)

    persist(fn -> update_phase(new_state, new_state.state) end)

    GenServer.reply(from, {:ok, result})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(
        {:iteration_complete, {:error, reason}, from, _iteration, _target_sandbox,
         _iteration_started_at},
        state
      ) do
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
      state.runner.terminate(default_client(state), reason)
    end

    Enum.each(state.clients, fn {_name, entry} ->
      try do
        Sandbox.destroy(entry.client, entry.sandbox_id)
      catch
        kind, reason ->
          Logger.warning("[Forge.Harness] Sandbox destroy failed: #{kind} #{inspect(reason)}")
      end
    end)

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
    base_spec =
      state.spec
      |> Map.get(:sandbox_spec, %{})
      |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))

    create_spec = build_sandbox_spec(state, base_spec)

    case state.sandbox_module.create(create_spec) do
      {:ok, client, sandbox_id} ->
        entry = %{client: client, sandbox_id: sandbox_id, spec: base_spec}

        new_state = %{
          state
          | clients: Map.put(state.clients, state.default_client, entry),
            sandbox_id: sandbox_id,
            state: :bootstrapping
        }

        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)
        {:ok, new_state}

      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  defp recover_bootstrap(state) do
    env = Map.get(state.spec, :env, %{})

    if map_size(env) > 0 do
      Sandbox.inject_env(default_client(state), env)
    end

    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
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

    case runner_module.init(default_client(state), runner_config) do
      init_result when init_result == :ok or is_tuple(init_result) ->
        base_runner_state =
          case init_result do
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

        new_state = %{
          state
          | runner: runner_module,
            runner_state: runner_state,
            state: :ready,
            iteration: checkpoint.exec_session_sequence || 0,
            output_sequence:
              Map.get(checkpoint_metadata, "output_sequence") ||
                Map.get(checkpoint_metadata, :output_sequence) ||
                checkpoint.exec_session_sequence || 0
        }

        {:ok, new_state}

      {:error, reason} ->
        {:error, {:runner_init_failed, reason}}
    end
  end

  defp recover_extra_sandboxes(state, checkpoint) do
    checkpoint_metadata = checkpoint.metadata || %{}

    # extra_sandboxes may be stored under atom or string keys depending on serialization
    extra =
      Map.get(checkpoint_metadata, "extra_sandboxes") ||
        Map.get(checkpoint_metadata, :extra_sandboxes) ||
        %{}

    Enum.reduce_while(extra, {:ok, state}, fn {name, spec}, {:ok, acc_state} ->
      name =
        if is_binary(name) do
          try do
            String.to_existing_atom(name)
          rescue
            ArgumentError -> nil
          end
        else
          name
        end

      if is_nil(name) do
        Logger.warning("[Forge.Harness] Skipping unknown sandbox name during recovery")
        {:cont, {:ok, acc_state}}
      else
        spec = atomize_spec_keys(spec)
        sandbox_module = resolve_client(Map.get(spec, :sandbox, :default))
        create_spec = build_sandbox_spec(acc_state, spec)

        case sandbox_module.create(create_spec) do
          {:ok, client, sandbox_id} ->
            case bootstrap_client(acc_state, client) do
              :ok ->
                # Store the original spec (JSON-safe) for future checkpoints
                entry = %{client: client, sandbox_id: sandbox_id, spec: spec}
                new_state = %{acc_state | clients: Map.put(acc_state.clients, name, entry)}

                persist(fn ->
                  log_event(new_state, "sandbox.recovered", %{name: name, sandbox_id: sandbox_id})
                end)

                {:cont, {:ok, new_state}}

              {:error, reason} ->
                try do
                  Sandbox.destroy(client, sandbox_id)
                rescue
                  _ -> :ok
                end

                Logger.warning(
                  "[Forge.Harness] Failed to bootstrap recovered sandbox #{name}: #{inspect(reason)}"
                )

                {:cont, {:ok, acc_state}}
            end

          {:error, reason} ->
            Logger.warning(
              "[Forge.Harness] Failed to recreate sandbox #{name}: #{inspect(reason)}"
            )

            {:cont, {:ok, acc_state}}
        end
      end
    end)
  end

  defp atomize_spec_keys(spec) when is_map(spec) do
    Map.new(spec, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end

      pair ->
        pair
    end)
  end

  # Lazy provisioning helpers

  # Resolve the target sandbox for an operation. Only triggers lazy provisioning
  # when the operation actually targets the default sandbox.
  defp ensure_target_sandbox(state, opts) do
    target = Keyword.get(opts, :sandbox)

    case target do
      nil ->
        # Targeting default — lazy-provision if needed
        case ensure_default_sandbox(state) do
          {:ok, state} -> {:ok, state, default_client(state)}
          {:error, reason} -> {:error, {:provision_failed, reason}}
        end

      name ->
        # Targeting a specific sandbox — no default provisioning
        case get_client(state, opts) do
          nil ->
            {:error, {:unknown_sandbox, name}}

          client ->
            # Runner init is session-level. If deferred, we still need to
            # initialize the runner module before any run_iteration call.
            case ensure_runner(state, client) do
              {:ok, state} -> {:ok, state, client}
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  defp ensure_default_sandbox(state) do
    if default_client(state) == nil do
      provision_sync(state)
    else
      {:ok, state}
    end
  end

  # Ensures the session-level runner module is initialized, even when the
  # default sandbox hasn't been provisioned (deferred_provision sessions).
  # Uses the given client for init side effects, then inits all other
  # pre-attached sandboxes.
  defp ensure_runner(%{runner: nil} = state, client) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(client, runner_config) do
      :ok ->
        new_state = %{state | runner: runner_module, runner_state: runner_config}
        init_preattached_sandboxes(new_state)
        {:ok, new_state}

      {:ok, runner_state} ->
        new_state = %{state | runner: runner_module, runner_state: runner_state}
        init_preattached_sandboxes(new_state)
        {:ok, new_state}

      {:error, reason} ->
        {:error, {:runner_init_failed, reason}}
    end
  end

  defp ensure_runner(state, _client), do: {:ok, state}

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
    base_spec =
      state.spec
      |> Map.get(:sandbox_spec, %{})
      |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))

    create_spec = build_sandbox_spec(state, base_spec)

    case state.sandbox_module.create(create_spec) do
      {:ok, client, sandbox_id} ->
        entry = %{client: client, sandbox_id: sandbox_id, spec: base_spec}

        new_state = %{
          state
          | clients: Map.put(state.clients, state.default_client, entry),
            sandbox_id: sandbox_id,
            state: :bootstrapping
        }

        persist(fn -> log_event(new_state, "sandbox.provisioned", %{sandbox_id: sandbox_id}) end)
        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)
        {:ok, new_state}

      {:error, reason} ->
        persist(fn ->
          log_event(state, "sandbox.provision_failed", %{reason: inspect(reason)})
        end)

        {:error, {:sandbox_creation_failed, reason}}
    end
  end

  defp bootstrap_and_init_sync(state) do
    with {:ok, state} <- bootstrap_sync(state),
         {:ok, state} <- init_runner_sync(state),
         {:ok, state} <- init_preattached_sandboxes(state) do
      state = %{state | sandbox_status: :ready}
      persist(fn -> log_event(state, "runner.ready") end)
      persist(fn -> update_phase(state, :ready) end)
      {:ok, state}
    end
  end

  # After lazy provisioning initializes the runner, any sandboxes that were
  # attached while the session was deferred (runner was nil) need a retroactive
  # runner.init call for per-sandbox side effects.
  defp init_preattached_sandboxes(state) do
    pre_attached =
      state.clients
      |> Map.delete(state.default_client)
      |> Map.keys()

    Enum.reduce_while(pre_attached, {:ok, state}, fn name, {:ok, acc} ->
      entry = get_sandbox_entry(acc, name)

      case init_runner_for_sandbox(acc, entry.client) do
        :ok ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          Logger.warning(
            "[Forge.Harness] Failed to init runner for pre-attached sandbox #{name}: #{inspect(reason)}"
          )

          {:cont, {:ok, acc}}
      end
    end)
  end

  defp bootstrap_sync(state) do
    persist(fn -> log_event(state, "bootstrap.started") end)
    persist(fn -> update_phase(state, :bootstrapping) end)

    env = Map.get(state.spec, :env, %{})

    if map_size(env) > 0 do
      Sandbox.inject_env(default_client(state), env)
    end

    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      {:ok, %{state | state: :initializing}}
    else
      {:error, resource, reason} when is_map(resource) ->
        persist(fn ->
          log_event(state, "resource.provision_failed", %{
            resource: inspect(resource),
            reason: inspect(reason)
          })
        end)

        {:error, {:resource_provision_failed, reason}}

      {:error, step, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)})
        end)

        {:error, {:bootstrap_failed, reason}}

      {:error, reason} ->
        persist(fn -> log_event(state, "bootstrap.failed", %{reason: inspect(reason)}) end)
        {:error, {:bootstrap_failed, reason}}
    end
  end

  defp init_runner_sync(state) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(default_client(state), runner_config) do
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
    case get_sandbox_entry(state, state.default_client) do
      %{client: client, sandbox_id: sid} when not is_nil(sid) ->
        Sandbox.destroy(client, sid)

      _ ->
        :ok
    end
  end

  defp serialize_runner_state(runner_module, runner_state) do
    if runner_module && function_exported?(runner_module, :serialize_state, 1) do
      runner_module.serialize_state(runner_state)
    else
      runner_state
    end
  end

  # Client helpers — multi-sandbox support

  defp default_client(state) do
    case Map.get(state.clients, state.default_client) do
      %{client: client} -> client
      nil -> nil
    end
  end

  defp get_client(state, opts) do
    name = Keyword.get(opts, :sandbox, state.default_client)

    case Map.get(state.clients, name) do
      %{client: client} -> client
      nil -> nil
    end
  end

  defp get_sandbox_entry(state, name) do
    Map.get(state.clients, name)
  end

  defp save_topology_checkpoint(state) do
    persist(fn ->
      snapshot = serialize_runner_state(state.runner, state.runner_state)

      extra_sandboxes =
        state.clients
        |> Map.delete(state.default_client)
        |> Map.new(fn {name, %{spec: spec}} -> {name, spec} end)

      Persistence.save_checkpoint(state.session_id, state.iteration, snapshot, %{
        resources: Map.get(state.spec, :resources, []),
        bootstrap_steps: Map.get(state.spec, :bootstrap_steps, []),
        output_sequence: state.output_sequence,
        extra_sandboxes: extra_sandboxes
      })
    end)
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
  defp resolve_runner(:fake), do: JidoClaw.Forge.Runners.Fake
  defp resolve_runner(module) when is_atom(module), do: module

  defp resolve_client(:default), do: Sandbox
  defp resolve_client(:local), do: JidoClaw.Forge.Sandbox.Local
  defp resolve_client(:fake), do: JidoClaw.Forge.Sandbox.Local
  defp resolve_client(:docker_sandbox), do: JidoClaw.Forge.Sandbox.Docker
  defp resolve_client(module) when is_atom(module), do: module

  defp build_sandbox_spec(state, base_spec) do
    resources = Map.get(state.spec, :resources, [])
    resource_mounts = ResourceProvisioner.file_mount_specs(resources)

    base_spec
    |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))
    |> merge_resource_mounts(resource_mounts)
  end

  defp merge_resource_mounts(sandbox_spec, []), do: sandbox_spec

  defp merge_resource_mounts(sandbox_spec, mounts) do
    existing = Map.get(sandbox_spec, :extra_mounts, [])
    Map.put(sandbox_spec, :extra_mounts, existing ++ mounts)
  end

  defp bootstrap_client(state, client) do
    env = Map.get(state.spec, :env, %{})

    if map_size(env) > 0 do
      Sandbox.inject_env(client, env)
    end

    resources = Map.get(state.spec, :resources, [])

    with :ok <- ResourceProvisioner.provision_all(client, resources),
         :ok <- run_bootstrap_steps(state, client),
         :ok <- init_runner_for_sandbox(state, client) do
      :ok
    else
      {:error, _resource_or_step, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Run runner.init on a non-default sandbox for its side effects (e.g.
  # ClaudeCode creates /var/local/forge dirs and settings). The returned
  # runner_state is discarded — session-level state is unchanged.
  defp init_runner_for_sandbox(%{runner: nil}, _client), do: :ok

  defp init_runner_for_sandbox(%{runner: runner} = state, client) do
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner.init(client, runner_config) do
      :ok -> :ok
      {:ok, _discarded_state} -> :ok
      {:error, reason} -> {:error, {:runner_init_failed, reason}}
    end
  end

  defp run_bootstrap_steps(state, client \\ nil) do
    bootstrap_steps = Map.get(state.spec, :bootstrap_steps, [])
    Bootstrap.execute(client || default_client(state), bootstrap_steps)
  end

  # Session claim — atomic ownership via advisory lock + unique constraint.
  # Both fresh starts and recovery must go through the claim to prevent
  # duplicate owners across the cluster.
  defp maybe_claim_session(session_id, spec, nil = _fresh_start) do
    Persistence.claim_session(session_id, spec)
  end

  defp maybe_claim_session(session_id, spec, _resume_checkpoint_id) do
    Persistence.claim_session(session_id, spec, recovery: true)
  end

  # Clustering helpers — :pg group membership for cross-node session discovery

  defp maybe_pg_join(session_id) do
    if Application.get_env(:jido_claw, :cluster_enabled, false) do
      :pg.join(:jido_claw, {:forge_session, session_id}, self())
    end
  catch
    _, _ -> :ok
  end

  defp cluster_lookup(session_id) do
    if Application.get_env(:jido_claw, :cluster_enabled, false) do
      case :pg.get_members(:jido_claw, {:forge_session, session_id}) do
        [pid | _] -> {:ok, pid}
        [] -> :error
      end
    else
      :error
    end
  catch
    _, _ -> :error
  end
end
