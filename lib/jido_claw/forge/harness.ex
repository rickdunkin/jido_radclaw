defmodule JidoClaw.Forge.Harness do
  # The {client, sandbox_id, spec} map is this module's internal runner-state
  # shape, threaded between harness callbacks — not cross-module domain data.
  # reach:disable-for-this-file fixed_shape_map
  #
  # GenServer harness boundary: every bare rescue here wraps best-effort
  # cleanup (sandbox destroy in detach_sandbox / safe_destroy_sandbox) or
  # the persistence side-channel (persist/1). A typed rescue would let an
  # unrelated process crash propagate up and kill the live Forge session
  # — that is exactly the failure mode this harness exists to prevent.
  # reach:disable-for-this-file bare_rescue
  @moduledoc false
  use GenServer, restart: :temporary
  require Logger

  alias JidoClaw.Core.MapKeys

  alias JidoClaw.Forge.{
    Bootstrap,
    ChildTracker,
    Persistence,
    PubSub,
    ResourceProvisioner,
    ResumeSignal,
    ResumeState,
    Sandbox
  }

  alias JidoClaw.Forge.Resources.Checkpoint
  alias JidoClaw.Orchestration.RunFailure
  alias JidoClaw.Telemetry

  @registry JidoClaw.Forge.SessionRegistry

  # Ash CRUD + Postgrex faults the checkpoint-recovery read can hit; narrowed
  # so a real bug surfaces instead of silently treating recovery as a miss.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

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
    input_sandbox: nil,
    iteration_task_pid: nil,
    iteration_task_ref: nil,
    iteration_from: nil,
    # EM3-3 transcript honesty: :replay marks a driver-authorized fresh
    # re-send of the same logical turn (the effect-free retry / crash
    # replay); everything else is :live. Whitelist-decoded from the
    # driver's run_iteration opts, stamped on the iteration.completed event.
    iteration_source: :live,
    # The incarnation fence (docs/system/forge-session-resume.md): minted at
    # claim time for every claimed session. The token authorizes this
    # incarnation's fenced writes; epoch 0 + nil token is the local posture
    # (claim: false / persistence disabled — no durable recovery). The
    # tagged key names this incarnation in the ChildTracker — local
    # incarnations get a per-boot uuid so a reused session id never
    # collides across incarnations.
    incarnation_epoch: 0,
    incarnation_token: nil,
    incarnation_key: nil
  ]

  # The no-mint posture for claim: false runs and disabled persistence.
  @local_incarnation %{epoch: 0, token: nil}

  @spec start_link({String.t(), map(), keyword()}) :: GenServer.on_start()
  def start_link({session_id, spec, _opts}) do
    GenServer.start_link(__MODULE__, {session_id, spec},
      name: {:via, Registry, {@registry, session_id}}
    )
  end

  @spec run_iteration(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_iteration(session_id, opts \\ []) do
    # Same C3 geometry as `exec/3`: the OUTER `GenServer.call` deadline is
    # cushioned past the INNER backend timeout (`opts[:timeout]`, riding the
    # runner task down to `Sandbox.exec`). The outer clock starts first, so
    # equal deadlines always expire the outer one — the inner must win so a
    # real command timeout surfaces as the runner's graceful reply (Shell maps
    # HostShell's manufactured `{_, 124}`) instead of an uncaught caller
    # `:exit, {:timeout, _}` (`call/3` only catches `:noproc`).
    call(session_id, {:run_iteration, opts}, exec_call_timeout(opts))
  end

  @spec exec(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def exec(session_id, command, opts \\ []) do
    # AR-8b-2 F2 (C3): the OUTER GenServer.call deadline is cushioned past the
    # INNER backend timeout (`opts[:timeout]`, passed through unchanged to
    # `Sandbox.exec`). The inner (later-starting) OsCmd deadline must win so a
    # real timeout surfaces as the backend's manufactured `{_, 124}` — which the
    # ForgeBridge taints on — rather than an uncaught caller `:exit, {:timeout,
    # _}` (`call/3` only catches `:noproc`). Before this bridge `exec/3` had no
    # production callers, so the cushion regresses nothing pre-existing.
    call(session_id, {:exec, command, opts}, exec_call_timeout(opts))
  end

  # The outer `GenServer.call` timeout for BOTH `exec/3` and `run_iteration/2`:
  # the caller's inner timeout plus the single-sourced cushion. A unit-testable
  # seam (the bridge's deadline-budget margin reads the SAME
  # `Forge.exec_timeout_cushion_ms/0`, so the two can never drift). A
  # non-integer/absent inner timeout falls back to the legacy 300_000 default
  # before cushioning.
  @doc false
  @spec exec_call_timeout(keyword()) :: timeout()
  def exec_call_timeout(opts) do
    inner =
      case Keyword.get(opts, :timeout, 300_000) do
        n when is_integer(n) and n >= 0 -> n
        _ -> 300_000
      end

    inner + JidoClaw.Forge.exec_timeout_cushion_ms()
  end

  @spec apply_input(String.t(), term()) :: :ok | {:error, term()}
  def apply_input(session_id, input) do
    call(session_id, {:apply_input, input})
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(session_id) do
    call(session_id, :status)
  end

  # AR-8b-2 F2 (1.3): a clean completion close that lands the session
  # **`:completed`** (with `completed_at`), distinct from `Manager.stop_session`'s
  # `:cancelled` — so a converged sketch run isn't misread as cancelled in
  # ForgeView/history. Routed as a Harness self-stop with `reason: :normal`: the
  # `:complete` handler best-effort stamps `completed_at`, then `{:stop, :normal,
  # …}` lets `terminate/2`'s `maybe_finalize_phase(:normal ⇒ :completed)` finalizer
  # be the FALLBACK, so a row whose stamp WRITE failed still lands `:completed`
  # (not `:failed`). The microVM is destroyed by `terminate/2` either way.
  @spec complete(String.t()) :: :ok | {:error, term()}
  def complete(session_id) do
    call(session_id, :complete)
  end

  @spec attach_sandbox(String.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def attach_sandbox(session_id, name, sandbox_spec) when is_atom(name) do
    call(session_id, {:attach_sandbox, name, sandbox_spec})
  end

  @spec detach_sandbox(String.t(), atom()) :: :ok | {:error, term()}
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

  @impl GenServer
  def init({session_id, spec}) do
    # Load-bearing for teardown (docker write build): `Manager.stop_session`
    # terminates this child with a `:shutdown` exit, and `terminate/2` — whose
    # body was always written for that delivery (`maybe_finalize_phase`
    # reasons about Manager-driven `:shutdown` explicitly) — only RUNS on an
    # external exit when trapping. Without this flag `Sandbox.destroy/2`
    # never fired on the stop path: invisible for HostShell (its sandbox
    # Agents are linked and die with the harness), a leaked microVM + secret-
    # bearing workspace per session on docker (found live by the write-build
    # smoke). Stray `{:EXIT, _, _}` messages from linked ports/Agents land in
    # the `handle_info` catch-all — a crashed linked client now surfaces on
    # its next use instead of killing the session mid-flight.
    Process.flag(:trap_exit, true)
    resources = Map.get(spec, :resources, [])

    case ResourceProvisioner.validate_resources(resources) do
      :ok -> claim_and_start(session_id, spec)
      {:error, reasons} -> stop_invalid_resources(session_id, reasons)
    end
  end

  # Claim session ownership atomically in the DB via advisory lock.
  # Both fresh starts and recovery go through this path — the lock
  # serializes all claim attempts for the same session_id cluster-wide.
  defp claim_and_start(session_id, spec) do
    resume_checkpoint_id = Map.get(spec, :resume_checkpoint_id)

    case maybe_claim_session(session_id, persistable_spec(spec), resume_checkpoint_id) do
      :ok -> start_claimed_session(session_id, spec, resume_checkpoint_id)
      {:error, reason} -> stop_unclaimed_session(session_id, reason)
    end
  end

  # Materialize-then-persist (docs/system/forge-session-resume.md): the
  # PERSISTED runner config is the runner's complete static posture — every
  # init/2 default written explicitly and stamped for
  # `RecoveredSpec.runner_config/1`, so a recovered session re-inits with
  # exactly this posture, never a re-applied default. Only the persisted
  # copy is materialized: the RUNTIME spec keeps the caller's config
  # untouched, because attempt-scoped values (mcp_config_path/json) still
  # ride runner_config into init today and materialization deliberately
  # drops them from the durable row.
  defp persistable_spec(spec) do
    runner_module = resolve_runner(Map.get(spec, :runner, :shell))

    if Code.ensure_loaded?(runner_module) and
         function_exported?(runner_module, :materialize_config, 1) do
      materialized = runner_module.materialize_config(Map.get(spec, :runner_config, %{}))
      Map.put(spec, :runner_config, materialized)
    else
      spec
    end
  end

  defp start_claimed_session(session_id, spec, resume_checkpoint_id) do
    initial_state = %__MODULE__{
      session_id: session_id,
      spec: spec,
      started_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      sandbox_module: resolve_client(Map.get(spec, :sandbox, :default)),
      resume_checkpoint_id: resume_checkpoint_id
    }

    persist(fn -> log_event(initial_state, "session.started") end)

    case mint_incarnation(session_id, spec, resume_checkpoint_id) do
      {:ok, incarnation, effective_checkpoint_id} ->
        state = %{
          initial_state
          | incarnation_epoch: incarnation.epoch,
            incarnation_token: incarnation.token,
            incarnation_key: incarnation_key(session_id, incarnation),
            resume_checkpoint_id: effective_checkpoint_id
        }

        state = kickoff_session(state, spec, effective_checkpoint_id)

        # Join :pg group for cluster-wide session discovery — but only for
        # sessions that actually claimed ownership. Failed claims never reach
        # here, and ephemeral no-claim runs (`claim: false`) must not advertise
        # ownership they don't hold, so `maybe_pg_join/2` skips them.
        maybe_pg_join(session_id, spec)

        {:ok, state}

      {:stop, reason} ->
        Logger.error(
          "[Forge.Harness] Incarnation mint failed for #{session_id}: #{inspect(reason)}"
        )

        persist(fn ->
          log_event(initial_state, "incarnation.mint_failed", %{reason: inspect(reason)})
        end)

        {:stop, reason}
    end
  end

  # Durable incarnations key on their fence epoch; local ones (no mint)
  # get a per-boot uuid so no-DB session-id reuse never collides in the
  # ChildTracker.
  defp incarnation_key(session_id, %{token: token, epoch: epoch}) when is_binary(token),
    do: {session_id, {:durable, epoch}}

  defp incarnation_key(session_id, _local),
    do: {session_id, {:local, Ecto.UUID.generate()}}

  # Mint exactly once per Harness incarnation, IMMEDIATELY after claiming and
  # BEFORE any provisioning/resuming phase — terminal reuse must never expose
  # the prior incarnation's checkpoint pointer during a recoverable phase.
  # Fresh starts and terminal reuse CAS from the stored pair into a BLANK
  # transplant (the previous native anchor is never carried); recovery
  # transplants under the mint's lock (below). A failed mint is a loud stop:
  # running un-fenced would let a crash resurface a stale incarnation's
  # pointer, and the Manager's recovery sweep retries the whole boot.
  defp mint_incarnation(_session_id, %{claim: false}, resume_checkpoint_id),
    do: {:ok, @local_incarnation, resume_checkpoint_id}

  defp mint_incarnation(session_id, _spec, nil = _fresh_start) do
    if Persistence.enabled?() do
      expected = persistence().stored_recovery_pair(session_id)

      case persistence().mint_resume_epoch(session_id, expected, nil) do
        {:ok, pair} -> {:ok, pair, nil}
        {:error, :persistence_disabled} -> {:ok, @local_incarnation, nil}
        {:error, reason} -> {:stop, {:mint_failed, reason}}
      end
    else
      {:ok, @local_incarnation, nil}
    end
  end

  defp mint_incarnation(session_id, _spec, resume_checkpoint_id) do
    if Persistence.enabled?() do
      mint_recovery_incarnation(session_id, resume_checkpoint_id)
    else
      {:ok, @local_incarnation, resume_checkpoint_id}
    end
  end

  # Recovery sequencing: locked {select transplant + CAS-mint with it}, then
  # IMMEDIATELY the checked transplant checkpoint under the new token. The
  # selector runs INSIDE the mint's critical section (an outliving old task
  # cannot move state between selection and install), but the mint returns
  # only {epoch, token} — the pointed snapshot selected under the lock is
  # also what the transplant checkpoint must be built from, so the selector
  # stashes it in the process dictionary under a unique ref (the fun runs
  # synchronously in this process) and it is deleted immediately after.
  defp mint_recovery_incarnation(session_id, requested_checkpoint_id) do
    expected = persistence().stored_recovery_pair(session_id)
    stash = make_ref()

    result = persistence().mint_resume_epoch(session_id, expected, transplant_selector(stash))
    selection = Process.delete(stash) || %{selected: nil, pointed: nil}

    case result do
      {:ok, pair} ->
        save_transplant_checkpoint(session_id, pair, selection, requested_checkpoint_id)

      {:error, reason} ->
        {:stop, {:recovery_failed, {:mint_failed, reason}}}
    end
  end

  defp transplant_selector(stash) do
    fn session ->
      pointed = persistence().pointed_checkpoint(session)
      snapshot = (pointed && pointed.runner_state_snapshot) || %{}

      {md_guidance, md_corrupt?} =
        decode_guidance_copy(get_in(session.metadata, ["resume", "guidance"]))

      {cp_guidance, cp_corrupt?} =
        decode_guidance_copy(get_in(snapshot, ["resume", "guidance"]))

      selected =
        ResumeState.select(
          decode_state_copy(get_in(session.metadata, ["resume", "state"])),
          md_guidance,
          decode_state_copy(get_in(snapshot, ["resume", "state"])),
          cp_guidance
        )

      selected = maybe_graft_lost_guidance(selected, md_corrupt? or cp_corrupt?)

      Process.put(stash, %{selected: selected, pointed: pointed})
      selected
    end
  end

  # Corrupt-evidence preservation (F6): when a guidance copy decoded corrupt
  # and the merged selection carries NO live guidance (e.g. the metadata
  # marker is also malformed/absent), the operator's parked answer would be
  # erased entirely — graft a conservative re-parkable marker instead, so
  # the transplant encodes marker-only pending and recovery
  # deterministically re-parks as :guidance_text_missing. Live merged
  # guidance stands on its own (its own status already delivers or
  # re-parks correctly).
  defp maybe_graft_lost_guidance(selected, false), do: selected

  defp maybe_graft_lost_guidance(%ResumeState{} = selected, true) do
    if ResumeState.live_guidance?(selected),
      do: selected,
      else: ResumeState.mark_guidance_lost(selected)
  end

  # No armed state copies at all — nothing to park on. Loud log; the
  # documented residual (armed sessions always carry state copies in
  # practice).
  defp maybe_graft_lost_guidance(nil, true) do
    Logger.warning("[Forge.Harness] corrupt guidance with no armed state copies — evidence lost")

    nil
  end

  defp decode_state_copy(encoded) do
    case ResumeState.decode_state(encoded) do
      {:ok, rs} -> rs
      :error -> nil
    end
  end

  # {copy_or_nil, corrupt?} — corruption is TRACKED, not collapsed: the
  # selector's graft above is what keeps corrupt evidence re-parkable.
  defp decode_guidance_copy(encoded) do
    case ResumeState.decode_guidance(encoded) do
      {:ok, copy} ->
        {copy, false}

      {:error, :corrupt_guidance} ->
        Logger.warning("[Forge.Harness] corrupt guidance copy during transplant selection")
        {nil, true}
    end
  end

  # The transplant checkpoint re-establishes the pointer the mint just
  # cleared. Without it, a crash between mint and recovery completion leaves
  # the session honestly unrecoverable, and the runner restore would read a
  # pre-select stale copy — possibly resurrecting an anchor the select
  # rejected (a poisoned id). Failure is therefore a loud recovery stop,
  # never a degraded continue.
  defp save_transplant_checkpoint(session_id, pair, selection, requested_checkpoint_id) do
    %{selected: selected, pointed: pointed} = selection
    base_snapshot = (pointed && pointed.runner_state_snapshot) || %{}
    sequence = (pointed && pointed.exec_session_sequence) || 0
    metadata = (pointed && pointed.metadata) || %{}

    if pointed == nil or pointed.id != requested_checkpoint_id do
      Logger.warning(
        "[Forge.Harness] recovery re-selected checkpoint under lock for #{session_id} " <>
          "(requested #{inspect(requested_checkpoint_id)}, pointer #{inspect(pointed && pointed.id)})"
      )
    end

    with {:ok, snapshot, marker} <- transplant_snapshot(selected, pair.epoch, base_snapshot),
         {:ok, checkpoint} <-
           persistence().save_recovery_checkpoint(
             session_id,
             sequence,
             snapshot,
             metadata,
             marker,
             pair.token
           ) do
      {:ok, pair, checkpoint.id}
    else
      {:error, reason} ->
        {:stop, {:recovery_failed, {:transplant_not_persisted, reason}}}
    end
  end

  # A nil selection (resume-off sessions, no decodable copies) transplants
  # the old snapshot verbatim minus any garbled resume object — garbled
  # decodes as absent, never as a guess.
  defp transplant_snapshot(nil, _epoch, base_snapshot),
    do: {:ok, Map.delete(base_snapshot, "resume"), nil}

  defp transplant_snapshot(%ResumeState{} = selected, epoch, base_snapshot) do
    stamped = ResumeState.stamp(selected, epoch, 0)

    case ResumeState.encode_guidance(stamped) do
      {:ok, guidance} ->
        resume_object =
          put_guidance_object(%{"state" => ResumeState.encode_state(stamped)}, guidance)

        snapshot = Map.put(base_snapshot, "resume", resume_object)
        {:ok, snapshot, ResumeState.encode_guidance_marker(stamped)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_guidance_object(resume_object, nil), do: resume_object

  defp put_guidance_object(resume_object, guidance),
    do: Map.put(resume_object, "guidance", guidance)

  defp stop_unclaimed_session(session_id, :already_claimed) do
    Logger.warning("[Forge.Harness] Session #{session_id} already claimed by another node")
    {:stop, :already_claimed}
  end

  # `Persistence.claim_session/3` returns `{:error, :scope_required}` when the
  # spec carries no tenant/workspace scope. A normal (claiming) spec missing
  # its scope is a programmer error — stop loudly rather than crash with a
  # FunctionClauseError. (Workspace-less runs opt out of claiming entirely via
  # `claim: false`; see `maybe_claim_session/3`.)
  defp stop_unclaimed_session(session_id, :scope_required) do
    Logger.error("[Forge.Harness] Session #{session_id} spec is missing tenant/workspace scope")
    {:stop, {:invalid_spec, :scope_required}}
  end

  defp stop_invalid_resources(session_id, reasons) do
    Logger.error(
      "[Forge.Harness] Resource validation failed for #{session_id}: #{inspect(reasons)}"
    )

    {:stop, {:resource_validation_failed, reasons}}
  end

  defp kickoff_session(state, spec, nil = _fresh_start) do
    if Map.get(spec, :deferred_provision, false) do
      kickoff_deferred(state)
    else
      send(self(), :provision)
      state
    end
  end

  defp kickoff_session(state, _spec, checkpoint_id) do
    persist(fn ->
      log_event(state, "session.recovering", %{checkpoint_id: checkpoint_id})
    end)

    persist(fn -> update_phase(state, :resuming) end)
    send(self(), {:recover, checkpoint_id})
    state
  end

  # Deferred provisioning is still a ready moment: the mint just cleared the
  # checkpoint pointer, so without the same checked initial checkpoint every
  # sibling ready-path lands (fresh eager, recovery, lazy provision) a crash
  # here would leave a claimed row that silently refuses recovery. The
  # runner-less snapshot is an honest `%{}` (see build_resume_snapshot/1);
  # token-less sessions no-op as everywhere else.
  defp kickoff_deferred(state) do
    persist(fn -> log_event(state, "provision.deferred") end)
    ensure_initial_checkpoint(state)
    persist(fn -> update_phase(state, :ready) end)
    PubSub.broadcast(state.session_id, {:ready, state.session_id})
    %{state | state: :ready}
  end

  @impl GenServer
  def handle_info(:provision, state) do
    state = %{state | sandbox_status: :provisioning}
    persist(fn -> log_event(state, "sandbox.provisioning") end)
    persist(fn -> update_phase(state, :provisioning) end)

    case create_default_sandbox(state) do
      {:ok, new_state, sandbox_id} ->
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

  @impl GenServer
  def handle_info(:bootstrap, state) do
    persist(fn -> log_event(state, "bootstrap.started") end)
    persist(fn -> update_phase(state, :bootstrapping) end)

    # Provision declarative resources (git repos, env vars, secrets)
    # File mounts are already handled at sandbox creation time.
    resources = Map.get(state.spec, :resources, [])

    with :ok <- inject_spec_env(default_client(state), state.spec),
         :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      new_state = %{state | state: :initializing}
      send(self(), :init_runner)
      {:noreply, new_state}
    else
      {:error, {:bootstrap_step, step}, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)})
        end)

        Logger.error(
          "[Forge.Harness] Bootstrap failed at step #{inspect(step)}: #{inspect(reason)}"
        )

        {:stop, {:bootstrap_failed, reason}, state}

      {:error, resource, reason} when is_map(resource) ->
        persist(fn ->
          log_event(state, "resource.provision_failed", %{
            resource: inspect(resource),
            reason: inspect(reason)
          })
        end)

        Logger.error("[Forge.Harness] Resource provisioning failed: #{inspect(reason)}")
        {:stop, {:resource_provision_failed, reason}, state}

      {:error, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: "inject_env", reason: inspect(reason)})
        end)

        Logger.error("[Forge.Harness] Spec env injection failed: #{inspect(reason)}")
        {:stop, {:bootstrap_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:init_runner, state) do
    runner_module = resolve_runner(Map.get(state.spec, :runner, :shell))
    runner_config = Map.get(state.spec, :runner_config, %{})

    case runner_module.init(default_client(state), runner_config) do
      :ok ->
        {:noreply, finalize_runner_ready(state, runner_module, runner_config)}

      {:ok, runner_state} ->
        {:noreply, finalize_runner_ready(state, runner_module, runner_state)}

      {:error, reason} ->
        persist(fn -> log_event(state, "runner.init_failed", %{reason: inspect(reason)}) end)
        Logger.error("[Forge.Harness] Runner init failed: #{inspect(reason)}")
        {:stop, {:runner_init_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:recover, checkpoint_id}, state) do
    persist(fn -> log_event(state, "recovery.started", %{checkpoint_id: checkpoint_id}) end)

    with checkpoint when not is_nil(checkpoint) <- load_checkpoint(checkpoint_id),
         {:ok, state} <- recover_provision(state),
         {:ok, state} <- recover_bootstrap(state),
         {:ok, state} <- recover_runner(state, checkpoint),
         {:ok, state} <- recover_extra_sandboxes(state, checkpoint) do
      state = stamp_runner_resume(%{state | sandbox_status: :ready})

      # Guidance re-adoption BEFORE the checked initial checkpoint: the
      # runner's restore_state restores only ["resume"]["state"], so the
      # transplant's guidance copy is adopted here — and a re-park's durable
      # `repark_reason` marker then persists fenced via the checkpoint's
      # existing marker mirror (zero new writers).
      {state, repark_reason} = readopt_guidance(state, checkpoint)

      # Recovery completion's checked initial checkpoint — the counterpart of
      # the fresh-provision one in finalize_runner_ready/3.
      ensure_initial_checkpoint(state)
      persist(fn -> log_event(state, "recovery.completed") end)
      {:noreply, finish_recovery(state, repark_reason)}
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

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{iteration_task_ref: ref} = state
      ) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{iteration_task_ref: ref} = state
      ) do
    failure = {:iteration_task_failed, reason}

    persist(fn -> log_event(state, "iteration.failed", %{reason: inspect(failure)}) end)
    persist(fn -> update_phase(state, :ready) end)
    PubSub.broadcast(state.session_id, {:error, %{reason: failure}})
    reply_iteration_from(state, {:error, failure})

    new_state =
      state
      |> clear_iteration_task()
      |> Map.put(:state, :ready)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:run_iteration, opts}, from, %{state: :ready} = state) do
    case ensure_target_sandbox(state, opts) do
      {:ok, state, client} ->
        case advance_guidance_inflight(%{state | iteration: state.iteration + 1}) do
          {:ok, prepared} ->
            start_iteration_task(prepared, client, opts, from)

          {:error, reason} ->
            # The checked pending → inflight transition did not persist:
            # NO spawn (a best-effort inflight would let a crash resend the
            # same answer). The caller sees the error; the iteration count
            # and phase are untouched.
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:run_iteration, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl GenServer
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

  @impl GenServer
  def handle_call({:exec, _command, _opts}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl GenServer
  def handle_call({:apply_input, input}, _from, %{state: :needs_input} = state) do
    persist(fn -> log_event(state, "input.received") end)

    # Route input to the sandbox that triggered :needs_input
    client =
      case get_sandbox_entry(state, state.input_sandbox) do
        %{client: c} -> c
        nil -> default_client(state)
      end

    case park_pending_guidance(state, input) do
      {:ok, state} ->
        dispatch_apply_input(state, client, input)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:apply_input, _input}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state}}, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      state: state.state,
      iteration: state.iteration,
      runner: state.runner,
      sandbox_id: state.sandbox_id,
      # AR-8b-2 F2 (D5): surface the resolved default-client backend module so
      # `Skills.Steps.AgentRunner.validate_sandbox_scope(:docker)` can assert the
      # session is a REAL `JidoClaw.Forge.Sandbox.Docker` backend (not a
      # HostShell/default one) before launching a `:docker` worker — the
      # structural invariant Unit B's per-call approval bypass rests on.
      sandbox_module: state.sandbox_module,
      sandbox_status: state.sandbox_status,
      sandboxes: Map.keys(state.clients),
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, {:ok, status}, state}
  end

  # AR-8b-2 F2 (1.3): the completion-aware close. Best-effort stamp `:completed` +
  # `completed_at` (swallow any write error), then self-stop `:normal`.
  # `terminate/2`'s `maybe_finalize_phase` finalizes `:completed` for `:normal`
  # whether the stamp landed (clean: `completed_at` set) or failed (row still
  # `:ready`/`:running` ⇒ finalized `:completed`, no `completed_at`) — NEVER
  # `:failed`. A Manager-driven `terminate_child` would deliver `:shutdown`, so a
  # failed prewrite would fall through to `:failed` — the misread `:completed`
  # exists to avoid. Routed through the `persistence/0` seam so a test can force
  # the stamp-failure → `:normal`-fallback path.
  @impl GenServer
  def handle_call(:complete, _from, state) do
    persist(fn -> persistence().complete_session(state.session_id) end)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_call({:attach_sandbox, name, sandbox_spec}, _from, state) do
    if Map.has_key?(state.clients, name) do
      {:reply, {:error, :already_attached}, state}
    else
      attach_new_sandbox(state, name, sandbox_spec)
    end
  end

  @impl GenServer
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

  @impl GenServer
  def handle_cast(
        {:iteration_complete, task_pid, {:ok, result}, from, _iteration, target_sandbox,
         iteration_started_at},
        state
      ) do
    if state.iteration_task_pid == task_pid do
      state = clear_iteration_task(state)

      # Classified ONCE per terminal error (MC1-4): the broadcast, the
      # telemetry counter, and the event-log metadata all carry the same kind.
      # Control flow is untouched — the taxonomy enriches, never redecides.
      failure_kind = failure_kind_of(result)

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
            Telemetry.emit_run_failure(failure_kind, RunFailure.provenance(failure_kind))

            PubSub.broadcast(
              state.session_id,
              {:error, %{reason: result.error, kind: failure_kind}}
            )

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

      # Guidance consumed (best-effort) BEFORE the anchor mirror + checked
      # save below, so the consumed marker rides this iteration's durable
      # writes; then the fenced metadata mirror of the anchor state.
      new_state =
        new_state
        |> consume_inflight_guidance(result.status)
        |> mirror_anchor()

      persist(fn ->
        log_event(
          new_state,
          "iteration.completed",
          iteration_completed_data(state, new_state, result, failure_kind)
        )
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
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(
        {:iteration_complete, task_pid, {:error, reason}, from, _iteration, _target_sandbox,
         _iteration_started_at},
        state
      ) do
    if state.iteration_task_pid == task_pid do
      state = clear_iteration_task(state)
      persist(fn -> log_event(state, "iteration.failed", %{reason: inspect(reason)}) end)
      persist(fn -> update_phase(state, :ready) end)
      PubSub.broadcast(state.session_id, {:error, %{reason: reason}})
      GenServer.reply(from, {:error, reason})
      {:noreply, %{state | state: :ready}}
    else
      {:noreply, state}
    end
  end

  defp clear_iteration_task(state) do
    if state.iteration_task_ref, do: Process.demonitor(state.iteration_task_ref, [:flush])

    %{
      state
      | iteration_task_pid: nil,
        iteration_task_ref: nil,
        iteration_from: nil
    }
  end

  # `failure_kind` joins the event data only on `:error` terminals; every
  # row carries `source: :live | :replay` (EM3-3 — the Forge event log is
  # the live surface for replay honesty).
  defp iteration_completed_data(state, new_state, result, failure_kind) do
    data = %{
      iteration: state.iteration,
      status: result.status,
      output_sequence: new_state.output_sequence,
      source: state.iteration_source
    }

    if failure_kind, do: Map.put(data, :failure_kind, failure_kind), else: data
  end

  defp iteration_source(opts) do
    case Keyword.get(opts, :source) do
      :replay -> :replay
      _live_or_arbitrary -> :live
    end
  end

  # The armed vendor runners classify closest to the evidence and thread the
  # kind through `metadata.error_details` — prefer it over re-classifying
  # `result.error`, whose label-only terms would downgrade to :agent_unknown.
  # Anything outside the closed 22-kind set falls back to classify/1.
  defp failure_kind_of(%{status: :error} = result) do
    with %{error_details: %{failure_kind: kind}} <- result.metadata,
         true <- kind in RunFailure.all_kinds() do
      kind
    else
      _ -> RunFailure.classify(result.error)
    end
  end

  defp failure_kind_of(_result), do: nil

  # The shared fresh-provision ready tail: stamp the armed runner state with
  # this incarnation's epoch, then land the CHECKED initial checkpoint before
  # anyone can observe :ready.
  defp finalize_runner_ready(state, runner_module, runner_state) do
    new_state =
      stamp_runner_resume(%{
        state
        | runner: runner_module,
          runner_state: runner_state,
          state: :ready,
          sandbox_status: :ready
      })

    init_preattached_sandboxes(new_state)
    ensure_initial_checkpoint(new_state)
    persist(fn -> log_event(new_state, "runner.ready") end)
    persist(fn -> update_phase(new_state, :ready) end)
    PubSub.broadcast(new_state.session_id, {:ready, new_state.session_id})
    new_state
  end

  defp start_iteration_task(new_state, client, opts, from) do
    new_state = %{
      new_state
      | state: :running,
        last_activity: DateTime.utc_now(),
        iteration_source: iteration_source(opts)
    }

    persist(fn ->
      log_event(new_state, "iteration.started", %{iteration: new_state.iteration})
    end)

    persist(fn -> update_phase(new_state, :running) end)

    target_sandbox = Keyword.get(opts, :sandbox, new_state.default_client)
    iteration_started_at = DateTime.utc_now()
    session_pid = self()
    runner = new_state.runner
    runner_state = new_state.runner_state
    iteration_opts = enrich_iteration_opts(opts, new_state)

    case Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
           result = run_tracked_iteration(runner, client, runner_state, iteration_opts)

           GenServer.cast(
             session_pid,
             {:iteration_complete, self(), result, from, new_state.iteration, target_sandbox,
              iteration_started_at}
           )
         end) do
      {:ok, task_pid} ->
        task_ref = Process.monitor(task_pid)

        {:noreply,
         %{
           new_state
           | iteration_task_pid: task_pid,
             iteration_task_ref: task_ref,
             iteration_from: from
         }}

      {:error, reason} ->
        persist(fn ->
          log_event(new_state, "iteration.failed", %{reason: inspect(reason)})
        end)

        persist(fn -> update_phase(new_state, :ready) end)
        {:reply, {:error, reason}, %{new_state | state: :ready}}
    end
  end

  # Owner-keyed pre-registration (F4): the iteration task announces itself
  # BEFORE dispatch, so pre-spawn work (the fenced anchor write, config
  # writes) is covered by the teardown barrier — which awaits registered
  # owners. Registers with the ENRICHED opts (they carry :incarnation_key;
  # the raw caller opts would make this a permanent no-op). A closing
  # incarnation/session refuses the iteration outright; an unavailable
  # tracker never blocks work. No explicit owner unregister — owner DOWN
  # (this task exiting) resolves the entry.
  defp run_tracked_iteration(runner, client, runner_state, iteration_opts) do
    case ChildTracker.register_owner(
           Keyword.get(iteration_opts, :incarnation_key),
           timeout_ms: Keyword.get(iteration_opts, :timeout, 300_000)
         ) do
      {:error, :closing} -> {:error, :session_closing}
      _registered_or_unavailable -> runner.run_iteration(client, runner_state, iteration_opts)
    end
  end

  # Ephemeral fence threading (never persisted): the runner authorizes its
  # fenced writes with the token captured when ITS iteration began, so a
  # rotated incarnation invalidates a stale runner's writes automatically;
  # the epoch stamps a fresh runner's pre-spawn anchor copy with the true
  # incarnation ordinal. The tagged incarnation key is what the vendor
  # runners hand the ChildTracker for graceful CLI teardown.
  defp enrich_iteration_opts(opts, state) do
    opts
    |> Keyword.put(:forge_session_id, state.session_id)
    |> Keyword.put(:incarnation_epoch, state.incarnation_epoch)
    |> Keyword.put(:incarnation_key, state.incarnation_key)
    |> put_incarnation_token(state.incarnation_token)
  end

  defp put_incarnation_token(opts, nil), do: opts
  defp put_incarnation_token(opts, token), do: Keyword.put(opts, :incarnation_token, token)

  # pending → inflight is a CHECKED canonical transition that must persist
  # BEFORE the CLI spawns; persist failure ⇒ no spawn (the parked answer
  # stays :pending and is re-attempted on the next call). Sessions without
  # live pending guidance — or without a token — pass through untouched.
  defp advance_guidance_inflight(state) do
    with %ResumeState{pending_guidance: %{status: :pending}} = rs <- runner_resume(state),
         token when is_binary(token) <- state.incarnation_token do
      {:ok, inflight} = ResumeState.guidance_inflight(rs)
      prepared = put_runner_resume(state, inflight)

      case save_checked_checkpoint(prepared) do
        :ok -> {:ok, prepared}
        {:error, reason} -> {:error, {:guidance_not_persisted, reason}}
      end
    else
      _no_live_pending_or_no_token -> {:ok, state}
    end
  end

  defp dispatch_apply_input(state, client, input) do
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

  # The apply_input guidance lifecycle (reached by the vendor runners via
  # the recovery re-park — `finish_recovery/2` parks :needs_input when a
  # recovered answer could not be restored safely): the answer is parked
  # :pending via the CHECKED save — encrypted text in the checkpoint
  # snapshot, status marker in metadata (a fresh answer also self-clears the
  # durable `repark_reason`) — BEFORE the runner sees it, and the ack is :ok
  # only when that write landed (`{:error, :not_persisted}` otherwise).
  # Non-binary input, resume-off runners, and token-less sessions bypass the
  # lifecycle untouched.
  defp park_pending_guidance(state, input) do
    with true <- is_binary(input),
         %ResumeState{} = rs <- runner_resume(state),
         token when is_binary(token) <- state.incarnation_token do
      case ResumeState.put_guidance(rs, input) do
        {:ok, parked} ->
          prepared = put_runner_resume(state, parked)

          case save_checked_checkpoint(prepared) do
            :ok -> {:ok, prepared}
            {:error, _reason} -> {:error, :not_persisted}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      _bypass -> {:ok, state}
    end
  end

  # Consumption is VENDOR-OWNED on delivery (`take_continuation_guidance/2`
  # consumes at take; fresh-armed reverts inflight → pending) — this is the
  # FALLBACK for runners that made no disposition (returned no armed state,
  # e.g. the fake/scripted substrate). Both stay best-effort: the marker
  # rides the next checked save; a crash before it re-parks an
  # already-answered question — an unnecessary re-prompt, never a
  # double-send. An :error iteration keeps the guidance :inflight
  # (recovery re-parks; never resends).
  defp consume_inflight_guidance(state, :error), do: state

  defp consume_inflight_guidance(state, _status) do
    case runner_resume(state) do
      %ResumeState{pending_guidance: %{status: :inflight}} = rs ->
        put_runner_resume(state, ResumeState.guidance_consumed(rs))

      _no_inflight_guidance ->
        state
    end
  end

  # Best-effort FENCED mirror of the sanitized anchor state to session
  # metadata after every iteration — the harness owns revision bumping. A
  # stale fence is logged and DROPPED, never treated as success; the bumped
  # in-memory revision is kept either way so later mirrors stay strictly
  # monotonic relative to whatever last landed.
  defp mirror_anchor(%{incarnation_token: token} = state) when is_binary(token) do
    case runner_resume(state) do
      %ResumeState{} = rs ->
        stamped = ResumeState.stamp(rs, state.incarnation_epoch, rs.revision + 1)

        case persistence().anchor_session(state.session_id, stamped, token) do
          {:error, :stale_resume_write} ->
            Logger.warning(
              "[Forge.Harness] anchor mirror fenced out for #{state.session_id} " <>
                "(stale incarnation) — dropped"
            )

          _ok_or_best_effort_nil ->
            :ok
        end

        put_runner_resume(state, stamped)

      nil ->
        state
    end
  end

  defp mirror_anchor(state), do: state

  # Stamp the armed runner state with this incarnation's epoch (revision
  # kept): a freshly-initialized ResumeState carries epoch 0, and the
  # initial checkpoint's encoded copy must match `forge_recovery.epoch` or
  # `Manager.recoverable?/1`'s epoch rule would refuse the session.
  defp stamp_runner_resume(state) do
    case runner_resume(state) do
      %ResumeState{} = rs ->
        put_runner_resume(state, ResumeState.stamp(rs, state.incarnation_epoch, rs.revision))

      nil ->
        state
    end
  end

  defp runner_resume(%{runner_state: %{resume: %ResumeState{} = rs}}), do: rs
  defp runner_resume(_state), do: nil

  defp put_runner_resume(state, %ResumeState{} = rs),
    do: %{state | runner_state: Map.put(state.runner_state, :resume, rs)}

  # The checked initial checkpoint (fresh provision AND recovery completion),
  # BEFORE the :ready broadcast. Failure does NOT brick the session: it
  # marks recovery honestly degraded (token-fenced — a stale incarnation can
  # never degrade a newer one) and emits the loud signal; the next
  # successful checked save self-heals structurally
  # (`save_recovery_checkpoint/6` clears the marker in its transaction).
  defp ensure_initial_checkpoint(%{incarnation_token: token} = state)
       when is_binary(token) do
    case save_checked_checkpoint(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Forge.Harness] initial checkpoint failed for #{state.session_id}: " <>
            "#{inspect(reason)} — recovery degraded"
        )

        persist(fn -> log_event(state, "recovery.degraded", %{reason: inspect(reason)}) end)
        persistence().mark_recovery_degraded(state.session_id, token)
        ResumeSignal.emit_recovery_degraded(%{session_id: state.session_id, reason: reason})
        :ok
    end
  end

  defp ensure_initial_checkpoint(_tokenless_state), do: :ok

  # The CHECKED pointer-moving save for token-holding sessions: snapshot +
  # guidance (encrypted text when live) + status marker, one transaction.
  defp save_checked_checkpoint(%{incarnation_token: token} = state) do
    case build_resume_snapshot(state) do
      {:ok, snapshot, marker} ->
        case persistence().save_recovery_checkpoint(
               state.session_id,
               state.iteration,
               snapshot,
               checkpoint_metadata(state),
               marker,
               token
             ) do
          {:ok, _checkpoint} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:guidance_encode_failed, reason}}
    end
  end

  # Snapshot = the runner's serialized state, plus the encrypted guidance
  # object when the armed state carries any — checkpoint copies are the ONLY
  # store guidance text ever rides (`ResumeState.select/4` reads it back).
  # Deferred sessions (runner nil) serialize to nil — coalesce to an explicit
  # `%{}` so `resume_epochs_match?` semantics stay clean and restore falls
  # back field-by-field on the missing keys.
  defp build_resume_snapshot(state) do
    snapshot = serialize_runner_state(state.runner, state.runner_state) || %{}

    case runner_resume(state) do
      %ResumeState{} = rs ->
        case ResumeState.encode_guidance(rs) do
          {:ok, nil} ->
            {:ok, snapshot, ResumeState.encode_guidance_marker(rs)}

          {:ok, guidance} ->
            {:ok, put_in_resume(snapshot, "guidance", guidance),
             ResumeState.encode_guidance_marker(rs)}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:ok, snapshot, nil}
    end
  end

  defp put_in_resume(snapshot, key, value) when is_map(snapshot) do
    Map.update(snapshot, "resume", %{key => value}, &Map.put(&1, key, value))
  end

  defp checkpoint_metadata(state) do
    extra_sandboxes =
      state.clients
      |> Map.delete(state.default_client)
      |> Map.new(fn {name, %{spec: spec}} -> {name, spec} end)

    %{
      resources: Map.get(state.spec, :resources, []),
      bootstrap_steps: Map.get(state.spec, :bootstrap_steps, []),
      output_sequence: state.output_sequence,
      extra_sandboxes: extra_sandboxes
    }
  end

  defp reply_iteration_from(%{iteration_from: nil}, _reply), do: :ok
  defp reply_iteration_from(%{iteration_from: from}, reply), do: GenServer.reply(from, reply)

  @impl GenServer
  def terminate(reason, state) do
    persist(fn -> log_event(state, "session.stopped", %{reason: inspect(reason)}) end)

    # Only update phase if not already in a terminal state (e.g. Manager sets
    # :cancelled before terminating the child — don't overwrite that).
    persist(fn -> maybe_finalize_phase(state, reason) end)

    PubSub.broadcast(state.session_id, {:stopped, reason})

    if state.runner && function_exported?(state.runner, :terminate, 2) do
      state.runner.terminate(default_client(state), reason)
    end

    # Teardown runs DETACHED under the app TaskSupervisor as ONE SEQUENCED
    # task: the graceful ChildTracker sweep of this incarnation's CLIs
    # FIRST, sandbox destroys second — two independent tasks could delete
    # the workdir under a live CLI. Detached because a docker destroy is a
    # real multi-second `sbx rm --force`, and running it inline here would
    # hold the supervisor's shutdown budget AND block `Manager.stop_session`'s
    # synchronous `terminate_child` past its callers' 5s GenServer.call
    # deadlines (serialized through the singleton Manager for a whole wave).
    # The client entries are plain data by now — a linked stub Agent is
    # already dead (destroy tolerates it), and a failed/interrupted rm is the
    # boot reaper's job (`SandboxInit`).
    clients = state.clients
    incarnation_key = state.incarnation_key

    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      if incarnation_key, do: ChildTracker.graceful_teardown(incarnation_key)

      Enum.each(clients, fn {_name, entry} ->
        try do
          Sandbox.destroy(entry.client, entry.sandbox_id)
        catch
          kind, reason ->
            Logger.warning("[Forge.Harness] Sandbox destroy failed: #{kind} #{inspect(reason)}")
        end
      end)
    end)

    :ok
  end

  # Gated like every other Persistence entry point: with persistence
  # disabled there is no phase row to finalize, and the bare `find_session`
  # read was the one UNGATED terminate-time DB call — now that `terminate/2`
  # actually runs on the Manager stop path (trap_exit), an ungated read
  # would stall teardown on DB latency for sessions that never persisted
  # anything.
  defp maybe_finalize_phase(state, reason) do
    if Persistence.enabled?() do
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
    else
      :ok
    end
  end

  defp attach_new_sandbox(state, name, sandbox_spec) do
    sandbox_module = resolve_client(Map.get(sandbox_spec, :sandbox, :default))
    create_spec = build_sandbox_spec(state, sandbox_spec)

    case sandbox_module.create(create_spec) do
      {:ok, client, sandbox_id} ->
        finalize_attached_sandbox(state, name, sandbox_spec, client, sandbox_id)

      {:error, reason} ->
        {:reply, {:error, {:provision_failed, reason}}, state}
    end
  end

  defp finalize_attached_sandbox(state, name, sandbox_spec, client, sandbox_id) do
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
        safe_destroy_sandbox(client, sandbox_id)
        {:reply, {:error, {:bootstrap_failed, reason}}, state}
    end
  end

  defp safe_destroy_sandbox(client, sandbox_id) do
    Sandbox.destroy(client, sandbox_id)
  rescue
    _ -> :ok
  end

  # Recovery helpers

  defp load_checkpoint(checkpoint_id) do
    case Checkpoint.get_by_id(checkpoint_id) do
      {:ok, checkpoint} -> checkpoint
      {:error, _} -> nil
    end
  rescue
    _ in @db_errors ->
      nil
  end

  # The recovery guidance disposition (F6): decode the transplant
  # checkpoint's guidance copy and let `ResumeState.adopt_recovered_guidance/2`
  # decide — restore/keep recover :ready; a re-park reason threads to
  # `finish_recovery/2`. Resume-off runners (no armed state) pass through.
  defp readopt_guidance(state, checkpoint) do
    case runner_resume(state) do
      %ResumeState{} = rs ->
        decoded =
          ResumeState.decode_guidance(
            get_in(checkpoint.runner_state_snapshot, ["resume", "guidance"])
          )

        {disposition, adopted} = ResumeState.adopt_recovered_guidance(rs, decoded)
        state = put_runner_resume(state, adopted)

        case disposition do
          {:repark, reason} -> {state, reason}
          _none_restored_kept -> {state, nil}
        end

      nil ->
        {state, nil}
    end
  end

  # The recovery ready tail — or the re-park: a session whose parked answer
  # could not be restored safely lands `:needs_input` (a recoverable,
  # ForgeView-active phase) with the static re-entry prompt, and the loud
  # signal fires so operators watching the buses see it immediately. The
  # durable `repark_reason` marker already rode the initial checkpoint above,
  # so an operator arriving after the broadcast still sees actionable
  # instructions (ForgeView `needs_input` projection).
  defp finish_recovery(state, nil) do
    persist(fn -> update_phase(state, :ready) end)
    PubSub.broadcast(state.session_id, {:ready, state.session_id})
    state
  end

  defp finish_recovery(state, reason) do
    persist(fn -> log_event(state, "guidance.reparked", %{reason: reason}) end)
    ResumeSignal.emit_guidance_reparked(%{session_id: state.session_id, reason: reason})
    persist(fn -> update_phase(state, :needs_input) end)

    PubSub.broadcast(
      state.session_id,
      {:needs_input, %{prompt: ResumeState.repark_prompt(), reason: reason}}
    )

    %{state | state: :needs_input, input_sandbox: nil}
  end

  defp recover_provision(state) do
    case create_default_sandbox(state) do
      {:ok, new_state, sandbox_id} ->
        persist(fn -> Persistence.record_sandbox_id(state.session_id, sandbox_id) end)
        {:ok, new_state}

      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  defp recover_bootstrap(state) do
    resources = Map.get(state.spec, :resources, [])

    with :ok <- inject_spec_env(default_client(state), state.spec),
         :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
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

    with {:ok, base_runner_state} <-
           init_recovered_runner(runner_module, default_client(state), runner_config) do
      runner_state = restore_runner_state(runner_module, base_runner_state, checkpoint)
      {:ok, apply_recovered_runner(state, runner_module, runner_state, checkpoint)}
    end
  end

  defp init_recovered_runner(runner_module, client, runner_config) do
    case runner_module.init(client, runner_config) do
      :ok -> {:ok, runner_config}
      {:ok, rs} -> {:ok, rs}
      {:error, reason} -> {:error, {:runner_init_failed, reason}}
    end
  end

  # Overlay checkpoint state using restore_state callback if available,
  # otherwise merge the snapshot directly.
  defp restore_runner_state(runner_module, base_runner_state, checkpoint) do
    snapshot = checkpoint.runner_state_snapshot || %{}

    if function_exported?(runner_module, :restore_state, 2) do
      restore_via_callback(runner_module, base_runner_state, snapshot)
    else
      Map.merge(base_runner_state, snapshot)
    end
  end

  defp restore_via_callback(runner_module, base_runner_state, snapshot) do
    case runner_module.restore_state(base_runner_state, snapshot) do
      {:ok, restored} -> restored
      {:error, _} -> Map.merge(base_runner_state, snapshot)
    end
  end

  defp apply_recovered_runner(state, runner_module, runner_state, checkpoint) do
    checkpoint_metadata = normalize_checkpoint_metadata(checkpoint.metadata)
    iteration = checkpoint.exec_session_sequence || 0

    %{
      state
      | runner: runner_module,
        runner_state: runner_state,
        state: :ready,
        iteration: iteration,
        output_sequence: Map.get(checkpoint_metadata, :output_sequence) || iteration
    }
  end

  defp recover_extra_sandboxes(state, checkpoint) do
    checkpoint_metadata = normalize_checkpoint_metadata(checkpoint.metadata)
    extra = Map.get(checkpoint_metadata, :extra_sandboxes, %{})

    Enum.reduce_while(extra, {:ok, state}, fn {name, spec}, {:ok, acc_state} ->
      recover_extra_sandbox(acc_state, name, spec)
    end)
  end

  defp recover_extra_sandbox(acc_state, raw_name, spec) do
    case normalize_sandbox_name(raw_name) do
      nil ->
        Logger.warning("[Forge.Harness] Skipping unknown sandbox name during recovery")
        {:cont, {:ok, acc_state}}

      name ->
        spec = MapKeys.normalize_keys(spec, :atom_existing)
        do_recover_extra_sandbox(acc_state, name, spec)
    end
  end

  defp normalize_sandbox_name(name) when is_atom(name), do: name

  defp normalize_sandbox_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp normalize_sandbox_name(_), do: nil

  defp do_recover_extra_sandbox(acc_state, name, spec) do
    sandbox_module = resolve_client(Map.get(spec, :sandbox, :default))
    create_spec = build_sandbox_spec(acc_state, spec)

    case sandbox_module.create(create_spec) do
      {:ok, client, sandbox_id} ->
        finalize_recovered_sandbox(acc_state, name, spec, client, sandbox_id)

      {:error, reason} ->
        Logger.warning("[Forge.Harness] Failed to recreate sandbox #{name}: #{inspect(reason)}")

        {:cont, {:ok, acc_state}}
    end
  end

  defp finalize_recovered_sandbox(acc_state, name, spec, client, sandbox_id) do
    case bootstrap_client(acc_state, client) do
      :ok ->
        entry = %{client: client, sandbox_id: sandbox_id, spec: spec}
        new_state = %{acc_state | clients: Map.put(acc_state.clients, name, entry)}

        persist(fn ->
          log_event(new_state, "sandbox.recovered", %{name: name, sandbox_id: sandbox_id})
        end)

        {:cont, {:ok, new_state}}

      {:error, reason} ->
        safe_destroy_sandbox(client, sandbox_id)

        Logger.warning(
          "[Forge.Harness] Failed to bootstrap recovered sandbox #{name}: #{inspect(reason)}"
        )

        {:cont, {:ok, acc_state}}
    end
  end

  defp normalize_checkpoint_metadata(nil), do: %{}

  defp normalize_checkpoint_metadata(metadata) when is_map(metadata) do
    MapKeys.normalize_keys(metadata, :atom_existing)
  end

  defp normalize_checkpoint_metadata(_), do: %{}

  # Lazy provisioning helpers

  # Resolve the target sandbox for an operation. Only triggers lazy provisioning
  # when the operation actually targets the default sandbox.
  defp ensure_target_sandbox(state, opts) do
    case Keyword.get(opts, :sandbox) do
      nil -> ensure_default_target(state)
      name -> ensure_named_target(state, opts, name)
    end
  end

  defp ensure_default_target(state) do
    # Targeting default — lazy-provision if needed
    case ensure_default_sandbox(state) do
      {:ok, state} -> {:ok, state, default_client(state)}
      {:error, reason} -> {:error, {:provision_failed, reason}}
    end
  end

  defp ensure_named_target(state, opts, name) do
    # Targeting a specific sandbox — no default provisioning
    case get_client(state, opts) do
      nil -> {:error, {:unknown_sandbox, name}}
      client -> ensure_named_runner(state, client)
    end
  end

  # Runner init is session-level. If deferred, we still need to
  # initialize the runner module before any run_iteration call.
  defp ensure_named_runner(state, client) do
    case ensure_runner(state, client) do
      {:ok, state} -> {:ok, state, client}
      {:error, reason} -> {:error, reason}
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
      {:ok, provisioned} -> finalize_provision_sync(state, provisioned)
      {:error, reason} -> revert_provision_sync(state, reason)
    end
  end

  defp finalize_provision_sync(state, provisioned) do
    case bootstrap_and_init_sync(provisioned) do
      {:ok, _state} = ok ->
        ok

      {:error, reason} ->
        destroy_sandbox(provisioned)
        revert_provision_sync(state, reason)
    end
  end

  defp revert_provision_sync(state, reason) do
    persist(fn -> update_phase(state, :ready) end)
    {:error, reason}
  end

  defp provision_sandbox_sync(state) do
    case create_default_sandbox(state) do
      {:ok, new_state, sandbox_id} ->
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
      state = stamp_runner_resume(%{state | sandbox_status: :ready})

      # Lazy provisioning is this session's fresh-provision ready moment —
      # same checked initial checkpoint as the eager path.
      ensure_initial_checkpoint(state)
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

    resources = Map.get(state.spec, :resources, [])

    with :ok <- inject_spec_env(default_client(state), state.spec),
         :ok <- ResourceProvisioner.provision_all(default_client(state), resources),
         :ok <- run_bootstrap_steps(state) do
      persist(fn -> log_event(state, "bootstrap.completed") end)
      {:ok, %{state | state: :initializing}}
    else
      {:error, {:bootstrap_step, step}, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: inspect(step), reason: inspect(reason)})
        end)

        {:error, {:bootstrap_failed, reason}}

      {:error, resource, reason} when is_map(resource) ->
        persist(fn ->
          log_event(state, "resource.provision_failed", %{
            resource: inspect(resource),
            reason: inspect(reason)
          })
        end)

        {:error, {:resource_provision_failed, reason}}

      {:error, reason} ->
        persist(fn ->
          log_event(state, "bootstrap.failed", %{step: "inject_env", reason: inspect(reason)})
        end)

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

  # Post-iteration/topology persistence. With an incarnation token this is
  # the CHECKED pointer-moving save — recovery restores what was last
  # durably pointed, and a success self-heals `recovery_degraded` — while a
  # failure only logs: the session continues and an older pointed checkpoint
  # stays authoritative. Token-less sessions (claim: false, persistence
  # disabled) keep the legacy best-effort unpointed row.
  defp save_topology_checkpoint(%{incarnation_token: token} = state)
       when is_binary(token) do
    case save_checked_checkpoint(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Forge.Harness] checked checkpoint failed for #{state.session_id}: " <>
            "#{inspect(reason)} — pointer unchanged"
        )

        :ok
    end
  end

  defp save_topology_checkpoint(state) do
    persist(fn ->
      snapshot = serialize_runner_state(state.runner, state.runner_state)

      Persistence.save_checkpoint(
        state.session_id,
        state.iteration,
        snapshot,
        checkpoint_metadata(state)
      )
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
    fun.()
  rescue
    e -> Logger.warning("[Forge.Harness] Persistence error: #{inspect(e)}")
  catch
    # DB faults can arrive as EXITS, not raises (e.g. a DBConnection
    # checkout whose pool/owner died mid-call). Best-effort means neither
    # may crash the harness — inside `terminate/2` an uncaught exit would
    # REPLACE the session's real exit reason (`:normal` → a DB error),
    # miscoloring the stop for every monitor.
    :exit, reason -> Logger.warning("[Forge.Harness] Persistence exit: #{inspect(reason)}")
  end

  # Named test seam (the app-env-seam idiom, cf. `:forge_facade`/`:sbx_finder`)
  # for the `:complete` handler AND the resume-fence writes
  # (stored_recovery_pair / mint_resume_epoch / pointed_checkpoint /
  # save_recovery_checkpoint / mark_recovery_degraded / anchor_session): a
  # test installs a delegating stub that forces one call to fail — e.g. the
  # checked initial checkpoint, to drive the `recovery_degraded` path. The
  # rest of the harness calls `Persistence` directly —
  # `maybe_finalize_phase/2`'s fallback write must stay on the real
  # `Persistence` so the row genuinely lands `:completed`.
  defp persistence do
    Application.get_env(:jido_claw, :forge_persistence, Persistence)
  end

  defp resolve_runner(:shell), do: JidoClaw.Forge.Runners.Shell
  defp resolve_runner(:claude_code), do: JidoClaw.Forge.Runners.ClaudeCode
  defp resolve_runner(:codex), do: JidoClaw.Forge.Runners.Codex
  defp resolve_runner(:workflow), do: JidoClaw.Forge.Runners.Workflow
  defp resolve_runner(:custom), do: JidoClaw.Forge.Runners.Custom
  defp resolve_runner(:fake), do: JidoClaw.Forge.Runners.Fake
  defp resolve_runner(module) when is_atom(module), do: module

  defp resolve_client(:default), do: Sandbox
  defp resolve_client(:host_shell), do: JidoClaw.Forge.Runner.HostShell
  defp resolve_client(:local), do: JidoClaw.Forge.Runner.HostShell
  defp resolve_client(:fake), do: JidoClaw.Forge.Runner.HostShell
  defp resolve_client(:docker_sandbox), do: JidoClaw.Forge.Sandbox.Docker
  defp resolve_client(module) when is_atom(module), do: module

  # Create the default sandbox from the session spec and install its client
  # entry in state. Ends right after `new_state` is built — callers own their
  # divergent logging/dispatch tails (`recover_provision/1` deliberately never
  # logs "sandbox.provisioned").
  defp create_default_sandbox(state) do
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

        {:ok, new_state, sandbox_id}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Build the backend create spec from the per-session `base_spec` (AR-8b-2 F2 1.5).
  Public so the map→tuple mount normalization is asserted directly without a live
  session.
  """
  @spec build_sandbox_spec(%__MODULE__{}, map()) :: map()
  def build_sandbox_spec(state, base_spec) do
    resources = Map.get(state.spec, :resources, [])
    resource_mounts = ResourceProvisioner.file_mount_specs(resources)

    base_spec
    |> Map.put_new(:runner, Map.get(state.spec, :runner, :shell))
    |> merge_resource_mounts(resource_mounts)
    |> normalize_mounts()
  end

  defp merge_resource_mounts(sandbox_spec, []), do: sandbox_spec

  defp merge_resource_mounts(sandbox_spec, mounts) do
    existing = Map.get(sandbox_spec, :extra_mounts, [])
    Map.put(sandbox_spec, :extra_mounts, existing ++ mounts)
  end

  # AR-8b-2 F2 (1.5): normalize every `:extra_mounts` entry to a
  # `{host, container, mode}` tuple at this single harness boundary, so the
  # backend's mount handling stays tuple-only AND the PERSISTED spec stays
  # JSON-safe (a tuple cannot be jsonb-encoded — `redact_map/1` would raise — so
  # F2 persists map mounts `%{"host"=>,"container"=>,"mode"=>}` and they convert
  # here). SHAPE-only: the same-path + absolute requirement (sbx 0.34.0
  # workspace positionals) is the backend's own validation. Runs
  # UNCONDITIONALLY (including the no-resource-mounts path), and is
  # IDEMPOTENT: an already-`{h,c,m}` tuple (resource mounts, or a later
  # create/recovery/sync re-run on an in-memory spec already converted) passes
  # through. A malformed entry is an impossible-by-construction invariant on the
  # F2 create/recovery paths (the front door builds well-formed maps; `wake/2`
  # fail-closes a malformed recovered mount), so it raises a DESCRIPTIVE
  # `ArgumentError` naming the bad entry — a clear boundary failure, not a
  # `FunctionClauseError` buried in the backend's tuple destructure. With
  # `restart: :temporary` that raise is a clean session death (front door
  # degrades / recovery fails closed). Non-F2 sessions with no `:extra_mounts`
  # pass through untouched.
  defp normalize_mounts(sandbox_spec) do
    case Map.get(sandbox_spec, :extra_mounts) do
      nil ->
        sandbox_spec

      mounts when is_list(mounts) ->
        Map.put(sandbox_spec, :extra_mounts, Enum.map(mounts, &normalize_mount/1))

      other ->
        raise ArgumentError,
              "[Forge.Harness] invalid :extra_mounts (expected a list, got #{inspect(other)})"
    end
  end

  # An already-`{host, container, mode}` tuple passes through. `mode` is NOT
  # constrained to a binary: `ResourceProvisioner.file_mount_specs/1` yields an
  # ATOM mode (`:ro`/`:rw`), which the backend's mount positional accepts — only
  # `host`/`container` must be the binary paths the backend emits.
  defp normalize_mount({host, container, _mode} = tuple)
       when is_binary(host) and is_binary(container),
       do: tuple

  defp normalize_mount(%{"host" => host, "container" => container, "mode" => mode})
       when is_binary(host) and is_binary(container) and is_binary(mode),
       do: {host, container, mode}

  defp normalize_mount(entry) do
    raise ArgumentError,
          "[Forge.Harness] invalid mount spec entry " <>
            "(expected {host, container, mode} tuple or " <>
            "%{\"host\" => _, \"container\" => _, \"mode\" => _} map, got #{inspect(entry)})"
  end

  defp bootstrap_client(state, client) do
    resources = Map.get(state.spec, :resources, [])

    with :ok <- inject_spec_env(client, state.spec),
         :ok <- ResourceProvisioner.provision_all(client, resources),
         :ok <- run_bootstrap_steps(state, client),
         :ok <- init_runner_for_sandbox(state, client) do
      :ok
    else
      {:error, _resource_or_step, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Env is part of the sandbox spec: a failed injection means the sandbox
  # does not match what was asked for, so every bootstrap path treats it
  # as a bootstrap failure instead of running with silently missing env.
  defp inject_spec_env(client, spec) do
    env = Map.get(spec, :env, %{})

    if map_size(env) > 0 do
      Sandbox.inject_env(client, env)
    else
      :ok
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

    case Bootstrap.execute(client || default_client(state), bootstrap_steps) do
      {:error, step, reason} -> {:error, {:bootstrap_step, step}, reason}
      other -> other
    end
  end

  # Session claim — atomic ownership via advisory lock + unique constraint.
  # Both fresh starts and recovery must go through the claim to prevent
  # duplicate owners across the cluster.
  #
  # Ephemeral no-claim run: a workspace-less spec (e.g. user/project-scope
  # memory consolidation) has no workspace_id to satisfy the Forge session
  # scope, so it opts out of claiming entirely. No DB row, no recovery, no
  # history, no ForgeView entry, and no :pg ownership (see
  # start_claimed_session). The sandbox still runs; every persist/2 call
  # no-ops because find_session never finds a row.
  defp maybe_claim_session(_session_id, %{claim: false}, _resume_checkpoint_id), do: :ok

  defp maybe_claim_session(session_id, spec, nil = _fresh_start) do
    Persistence.claim_session(session_id, spec)
  end

  defp maybe_claim_session(session_id, spec, _resume_checkpoint_id) do
    Persistence.claim_session(session_id, spec, recovery: true)
  end

  # Clustering helpers — :pg group membership for cross-node session discovery

  # No-claim ephemeral runs don't own the session, so they must not join the
  # ownership group — a cluster lookup must never route to them.
  defp maybe_pg_join(_session_id, %{claim: false}), do: :ok

  defp maybe_pg_join(session_id, _spec) do
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
