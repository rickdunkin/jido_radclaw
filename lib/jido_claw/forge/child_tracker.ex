defmodule JidoClaw.Forge.ChildTracker do
  @moduledoc """
  Tracks host-tier runner CLI processes per Forge incarnation so teardown
  can be graceful, sequenced, and race-free
  (docs/system/forge-session-resume.md).

  Keys are TAGGED incarnations — `{session_id, {:durable, epoch}}` for
  claimed sessions, `{session_id, {:local, uuid}}` for no-claim /
  persistence-disabled runs — so a reused session id never collides across
  incarnations (a surviving old task's teardown cannot kill the new
  incarnation's processes).

  Registration is TWO-PHASE: the iteration task pre-registers itself as an
  OWNER (`register_owner/2`) before any pre-spawn work (fenced DB writes,
  config writes), and the CLI spawn later ATTACHES to that entry
  (`register_spawn/3` from the same process returns the SAME ref). The
  teardown barrier awaits registered owners, so pre-spawn work can never
  race `run_forge_home` removal.

  Laws:

    * a registration against a CLOSING/CLOSED incarnation — or a closing
      SESSION — is refused and the late process is killed immediately,
      identity-verified; when a sweep or session barrier is in flight the
      refusal kill is TRACKED and the barrier outwaits it (iteration
      tasks run under the global Task.Supervisor and can outlive their
      Harness);
    * task-supervisor unavailability (VM shutdown — it starts after this
      tracker and terminates first) degrades every kill lane from
      asynchronous to SYNCHRONOUS in-server verified kills — sweep kill
      tasks, refusal kills, and the reap replacement all fall back rather
      than pretending completion, so a barrier never returns over a kill
      that silently did not run;
    * `graceful_teardown/2` is idempotent and synchronous — every caller
      (initiator or joiner) returns only when the sweep is complete;
    * a sweep completes only when its kill phase is done AND every
      pre-spawn owner registered under the key has resolved (owner DOWN —
      the TTL reap and the BOUNDED owner-stop at the grace window both
      force-stop a wedged owner so its own DOWN resolves it) AND every
      tracked late kill has finished AND every adopted reap-kill has
      resolved — sweeps adopt pending reap-kills in BOTH orderings
      (`start_sweep` seeds them from the entries' kill monitors, a
      mid-sweep reap inserts its fresh monitor), so a barrier can never
      return while a reap's terminate_tree still runs, even when the
      sweep's own kill task died unreported;
    * the TTL reap never drops live bookkeeping: an expired pre-spawn
      owner is force-stopped and RETAINED, an expired spawned entry gets a
      monitored identity-verified kill and is RETAINED — a reaping entry
      is removed only by its DOWN (owner DOWN for owner-only entries, the
      reap-kill task's `:normal` exit for spawned ones; an abnormal
      kill-task exit resets and restarts the kill — replacement started
      BEFORE the dead monitor clears — falling back to a synchronous
      in-server verified kill when the task supervisor is gone).
      `unregister/1` defers to that DOWN, and an attach to a reaping owner
      is CLOSING: identity adopted for the verified kill, TTL never
      refreshed, `{:error, :closing}` returned — never a revival;
    * `graceful_teardown_session/2` is the session-wide barrier: it
      tombstones the whole session, sweeps every live incarnation
      CONCURRENTLY (wall time bounded by the max grace window, not the
      sum), joins in-flight incarnation sweeps, outwaits session-scoped
      late kills, and returns when all are complete — the caller may only
      then remove shared filesystem resources (`run_forge_home` is the
      LAST thing removed);
    * ALL kills are identity-verified (`OsCmd.terminate_tree/2` + the
      birth identity captured at registration) — a reused OS pid is never
      killed, and a nil birth identity refuses (unverifiable);
    * tombstones are retained on a pure TTL — at LEAST a fresh
      #{300_000}ms window at tombstone time, lifted to the max registered
      entry TTL when that is higher, and re-tombstoning only ever EXTENDS
      (an already-expired entry TTL never produces a born-dead tombstone
      the next reap tick removes mid-barrier) — session ids are per-run
      UUIDs and recovered incarnations mint new epochs, so retention
      cannot block legitimate work;
    * the VM-shutdown `terminate/2` sweeps every live entry (supervised
      at the front of the core children so it terminates LAST).
  """

  use GenServer
  require Logger

  alias JidoClaw.Core.OsCmd

  @default_grace_ms 2_000
  @default_timeout_ms 300_000
  @reap_interval_ms 5_000
  # Slack past the covering window for the synchronous teardown calls: the
  # sweep's kill phase (STOP fixpoint + verified KILL) runs after the grace
  # window and the bounded owner-stop adds up to one more window, so the
  # call outwaits `2 × grace` plus this ps/exec overhead slack.
  @call_slack_ms 15_000

  @typedoc "A tagged incarnation key."
  @type incarnation_key :: {String.t(), {:durable, pos_integer()} | {:local, String.t()}}

  # -- client -------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Phase one: the iteration task announces itself as the incarnation's OWNER
  before any pre-spawn work. `{:error, :closing}` means the incarnation or
  session is tearing down — the caller must not start work. A nil key or an
  unavailable tracker returns nil (a budget guard must never block work).
  No explicit deregistration: owner exit (monitored) resolves the entry,
  and a later `register_spawn/3` from the same process attaches to it.
  """
  @spec register_owner(incarnation_key() | nil, keyword()) ::
          {:ok, reference()} | {:error, :closing} | nil
  def register_owner(key, opts \\ [])
  def register_owner(nil, _opts), do: nil

  def register_owner(key, opts) do
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))
    GenServer.call(__MODULE__, {:register_owner, key, self(), timeout_ms}, 10_000)
  catch
    :exit, _reason -> nil
  end

  @doc """
  Register a spawned CLI's OS pid under its incarnation. Captures the
  birth identity CALLER-side (as close to the spawn as possible), then
  registers — attaching to the caller's own owner-only entry when one
  exists (same ref returned, so the later `unregister/1` drops the whole
  entry). `{:error, :closing}` means the incarnation or session is tearing
  down — the tracker has already killed the late process (identity-
  verified, and tracked by any in-flight barrier). Returns `nil` when the
  tracker is unavailable (a budget guard must never break a live command).
  """
  @spec register_spawn(incarnation_key(), pos_integer(), keyword()) ::
          {:ok, reference()} | {:error, :closing} | nil
  def register_spawn(key, os_pid, opts \\ []) do
    birth = OsCmd.process_identity(os_pid)
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))

    GenServer.call(__MODULE__, {:register, key, os_pid, birth, self(), timeout_ms}, 10_000)
  catch
    :exit, _reason -> nil
  end

  @doc "Remove a registration after its command returned."
  @spec unregister(reference() | nil) :: :ok
  def unregister(ref) when is_reference(ref), do: GenServer.cast(__MODULE__, {:unregister, ref})
  def unregister(_ref), do: :ok

  @doc """
  Tear down one incarnation: tombstone it (late registrations are
  refused + killed), `OsCmd.terminate_tree/2` every registered process,
  await pre-spawn owners (bounded at the grace window), and return when
  the sweep is complete. Idempotent — a second caller joins the in-flight
  sweep. Best-effort: an unavailable tracker returns `:ok`, and a call
  that outlives even the covering timeout degrades loudly rather than
  blocking forever.
  """
  @spec graceful_teardown(incarnation_key(), keyword()) :: :ok
  def graceful_teardown(key, opts \\ []) do
    grace = grace_ms(opts)
    GenServer.call(__MODULE__, {:teardown, key, grace}, 2 * grace + @call_slack_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "[Forge.ChildTracker] graceful_teardown for #{inspect(key)} returned early: " <>
          inspect(reason)
      )

      :ok
  end

  @doc """
  The session-wide teardown barrier: tombstone the SESSION (any late
  registration for ANY epoch of the session is killed), sweep every live
  incarnation concurrently, join in-flight sweeps, outwait tracked late
  kills, and return when all are complete.
  """
  @spec graceful_teardown_session(String.t(), keyword()) :: :ok
  def graceful_teardown_session(session_id, opts \\ []) do
    grace = grace_ms(opts)
    GenServer.call(__MODULE__, {:teardown_session, session_id, grace}, 2 * grace + @call_slack_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "[Forge.ChildTracker] session barrier for #{session_id} returned early: " <>
          inspect(reason)
      )

      :ok
  end

  defp grace_ms(opts) do
    Keyword.get(
      opts,
      :grace_ms,
      Application.get_env(:jido_claw, :forge_runner_teardown_grace_ms, @default_grace_ms)
    )
  end

  defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_timeout(_infinity_or_invalid), do: @default_timeout_ms

  # -- server -------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct entries: %{},
              by_key: %{},
              monitors: %{},
              tombstones: %{},
              session_tombstones: %{},
              sweeps: %{},
              session_waits: %{},
              late_kills: %{},
              task_supervisor: JidoClaw.TaskSupervisor,
              auto_reap: true
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %State{
      task_supervisor: Keyword.get(opts, :task_supervisor, JidoClaw.TaskSupervisor),
      auto_reap: Keyword.get(opts, :schedule_reap, true)
    }

    if state.auto_reap, do: schedule_reap()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register_owner, key, owner, timeout_ms}, _from, state) do
    if closing?(state, key) do
      # Nothing exists yet — refusal alone (the caller must not start work).
      {:reply, {:error, :closing}, state}
    else
      {ref, state} = create_entry(state, key, nil, nil, owner, timeout_ms)
      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call({:register, key, os_pid, birth, owner, timeout_ms}, _from, state) do
    if closing?(state, key) do
      # Late straggler against a closing incarnation/session: kill it now
      # (hard — its window is over), identity-verified, and TRACKED when a
      # sweep/barrier is in flight so the barrier outwaits the kill.
      state = refuse_kill(state, key, %{os_pid: os_pid, birth_id: birth})
      {:reply, {:error, :closing}, state}
    else
      register_or_attach(state, key, os_pid, birth, owner, timeout_ms)
    end
  end

  def handle_call({:teardown, key, grace}, from, state) do
    case Map.get(state.sweeps, key) do
      %{froms: froms} = sweep ->
        # Join the in-flight sweep.
        {:noreply,
         %{state | sweeps: Map.put(state.sweeps, key, %{sweep | froms: [from | froms]})}}

      nil ->
        state = tombstone_key(state, key)

        case start_sweep(state, key, grace, [from]) do
          {:started, state} -> {:noreply, state}
          {:empty, state} -> {:reply, :ok, state}
        end
    end
  end

  def handle_call({:teardown_session, session_id, grace}, from, state) do
    tombstoned = tombstone_session(state, session_id)

    live_keys =
      for {key, _refs} <- tombstoned.by_key, session_of(key) == session_id, do: key

    inflight_keys =
      for {key, _sweep} <- tombstoned.sweeps, session_of(key) == session_id, do: key

    # Start a sweep for every live incarnation not already sweeping —
    # CONCURRENT tasks, so the barrier's wall time is bounded by the max
    # grace window.
    {swept, started} =
      Enum.reduce(live_keys -- inflight_keys, {tombstoned, []}, fn key, {acc, started} ->
        acc = tombstone_key(acc, key)

        case start_sweep(acc, key, grace, []) do
          {:started, acc} -> {acc, [key | started]}
          {:empty, acc} -> {acc, started}
        end
      end)

    pending = MapSet.new(inflight_keys ++ started)

    if MapSet.size(pending) == 0 and not session_late_kills?(swept, session_id) do
      {:reply, :ok, swept}
    else
      wait = Map.get(swept.session_waits, session_id, %{pending: MapSet.new(), froms: []})

      wait = %{
        wait
        | pending: MapSet.union(wait.pending, pending),
          froms: [from | wait.froms]
      }

      {:noreply, %{swept | session_waits: Map.put(swept.session_waits, session_id, wait)}}
    end
  end

  @impl GenServer
  def handle_cast({:unregister, ref}, state) do
    case Map.get(state.entries, ref) do
      %{reaping: true} ->
        # A reaping entry is removed only by its kill's DOWN — the command
        # returning (its reaped root died) must not lapse barrier accounting
        # while the kill task is still sweeping descendants.
        {:noreply, state}

      _live_or_gone ->
        {:noreply, clear_pending_owner(drop_entry(state, ref), ref)}
    end
  end

  @impl GenServer
  def handle_info({:sweep_complete, key}, state) do
    {:noreply, mark_kills_done(state, key)}
  end

  # The bounded owner-stop: a pre-spawn owner still unresolved at the grace
  # window is force-stopped — its DOWN clears the sweep's pending ref. An
  # attached or already-resolved entry passes (attach cannot happen during
  # a sweep — the key is tombstoned — so a live owner-only entry here is
  # genuinely wedged pre-spawn work).
  def handle_info({:owner_stop, key, ref}, state) do
    case Map.get(state.entries, ref) do
      %{key: ^key, os_pid: nil, owner: owner} ->
        Logger.warning(
          "[Forge.ChildTracker] force-stopping wedged pre-spawn owner for #{inspect(key)}"
        )

        Process.exit(owner, :kill)
        {:noreply, state}

      _attached_or_gone ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, mon) do
      {{:owner, ref}, monitors} ->
        {:noreply, owner_down(%{state | monitors: monitors}, ref)}

      {{:sweep, key}, monitors} ->
        {:noreply, sweep_task_down(%{state | monitors: monitors}, key)}

      {{:reap_kill, ref}, monitors} ->
        {:noreply, reap_kill_down(%{state | monitors: monitors}, ref, mon, reason)}

      {{:late_kill, key}, monitors} ->
        {:noreply, late_kill_down(%{state | monitors: monitors}, key, mon)}

      {{:late_kill_session, session_id}, monitors} ->
        state = %{state | monitors: monitors, late_kills: Map.delete(state.late_kills, mon)}
        {:noreply, resettle_session(state, session_id)}

      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(:reap, state) do
    if state.auto_reap, do: schedule_reap()
    {:noreply, reap(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # VM shutdown: hard, identity-verified sweep of everything still
  # registered (owner-only entries have no pid and refuse). Supervision
  # places this tracker at the front of the core children so it terminates
  # last — after every Harness had its chance at a graceful pass.
  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_ref, entry} ->
      verified_kill(entry, 0)
    end)

    :ok
  end

  # -- internals ----------------------------------------------------------------

  defp session_of({session_id, _tag}), do: session_id

  defp closing?(state, key) do
    Map.has_key?(state.tombstones, key) or
      Map.has_key?(state.session_tombstones, session_of(key))
  end

  defp register_or_attach(state, key, os_pid, birth, owner, timeout_ms) do
    case owner_only_ref(state, key, owner) do
      nil ->
        {ref, state} = create_entry(state, key, os_pid, birth, owner, timeout_ms)
        {:reply, {:ok, ref}, state}

      ref ->
        attach_or_close(state, ref, os_pid, birth, timeout_ms)
    end
  end

  defp attach_or_close(state, ref, os_pid, birth, timeout_ms) do
    if state.entries[ref].reaping do
      # Attach to a REAPING owner is CLOSING, never a revival: without
      # this, owner DOWN would keep the just-attached spawned entry and
      # the reaping mark would exempt it from every future reap — an
      # orphaned live CLI, permanently.
      {:reply, {:error, :closing}, adopt_reaping_attach(state, ref, os_pid, birth)}
    else
      # Attach: the pre-registered owner's spawn arrived — the SAME ref
      # returns, so the caller's later unregister drops the whole entry.
      {:reply, {:ok, ref}, attach_spawn(state, ref, os_pid, birth, timeout_ms)}
    end
  end

  defp create_entry(state, key, os_pid, birth, owner, timeout_ms) do
    ref = make_ref()
    mon = Process.monitor(owner)

    entry = %{
      key: key,
      session_id: session_of(key),
      os_pid: os_pid,
      birth_id: birth,
      owner: owner,
      ttl: entry_ttl(timeout_ms),
      reaping: false,
      reap_kill_mon: nil
    }

    state = %{
      state
      | entries: Map.put(state.entries, ref, entry),
        by_key: Map.update(state.by_key, key, MapSet.new([ref]), &MapSet.put(&1, ref)),
        monitors: Map.put(state.monitors, mon, {:owner, ref})
    }

    {ref, state}
  end

  defp attach_spawn(state, ref, os_pid, birth, timeout_ms) do
    entry = %{state.entries[ref] | os_pid: os_pid, birth_id: birth, ttl: entry_ttl(timeout_ms)}
    %{state | entries: Map.put(state.entries, ref, entry)}
  end

  # Identity only — NO TTL refresh: the entry is closing, and the still-
  # expired TTL lets the next reap tick retry (via the spawned clause)
  # if the monitored kill fails to start here.
  defp adopt_reaping_attach(state, ref, os_pid, birth) do
    entry = %{state.entries[ref] | os_pid: os_pid, birth_id: birth}
    state = put_entry(state, ref, entry)

    case start_reap_kill(state, ref, entry) do
      {:started, state} -> state
      {:not_started, state} -> put_entry(state, ref, %{entry | reaping: false})
    end
  end

  defp put_entry(state, ref, entry) do
    %{state | entries: Map.put(state.entries, ref, entry)}
  end

  defp entry_ttl(timeout_ms),
    do: System.monotonic_time(:millisecond) + 2 * (timeout_ms + grace_ms([]))

  # The caller's own owner-only entry under this key, if any — the attach
  # target. A different process's owner entry is never attached to.
  defp owner_only_ref(state, key, owner) do
    state.by_key
    |> Map.get(key, MapSet.new())
    |> Enum.find(fn ref ->
      match?(%{os_pid: nil, owner: ^owner}, state.entries[ref])
    end)
  end

  # Tombstones are TTL-only: retained for at LEAST a fresh default window
  # (#{@default_timeout_ms}ms), lifted to the max registered entry TTL when
  # that is higher — an already-expired entry TTL never produces a born-dead
  # tombstone the next reap tick removes mid-barrier — and re-tombstoning
  # only ever EXTENDS an existing tombstone. Safe to retain long — session
  # ids are per-run UUIDs and recovered incarnations mint new epochs, so a
  # tombstone can never block legitimate work; dropping one early is what
  # F4 exploited (a zero-owner tombstone reaped at the first tick lapsed
  # the late-kill protection).
  defp tombstone_key(state, key) do
    ttl = tombstone_ttl(state, key)

    %{
      state
      | tombstones: Map.update(state.tombstones, key, %{ttl: ttl}, &%{ttl: max(&1.ttl, ttl)})
    }
  end

  defp tombstone_session(state, session_id) do
    # The fresh deadline is the SEED, never 0: BEAM monotonic milliseconds
    # are negative, so a 0-seeded max would win over every real deadline
    # and make a zero-entry tombstone immortal (never `ttl < now`).
    ttl =
      for({_ref, entry} <- state.entries, entry.session_id == session_id, do: entry.ttl)
      |> Enum.reduce(fresh_tombstone_ttl(), &max/2)

    %{
      state
      | session_tombstones:
          Map.update(
            state.session_tombstones,
            session_id,
            %{ttl: ttl},
            &%{ttl: max(&1.ttl, ttl)}
          )
    }
  end

  defp tombstone_ttl(state, key) do
    # Fresh-deadline seed — see tombstone_session/2 on the negative clock.
    state.by_key
    |> Map.get(key, MapSet.new())
    |> Enum.map(&state.entries[&1].ttl)
    |> Enum.reduce(fresh_tombstone_ttl(), &max/2)
  end

  defp fresh_tombstone_ttl,
    do: System.monotonic_time(:millisecond) + @default_timeout_ms

  defp start_sweep(state, key, grace, froms) do
    refs = Map.get(state.by_key, key, MapSet.new())

    if MapSet.size(refs) == 0 do
      {:empty, state}
    else
      {owner_refs, spawned_refs} =
        refs
        |> MapSet.to_list()
        |> Enum.split_with(&is_nil(state.entries[&1].os_pid))

      # Pre-spawn owners get the BOUNDED stop: at the grace window a still
      # owner-only entry's owner is force-stopped (its DOWN clears the
      # pending ref) — the sweep can await owners, but never unboundedly.
      Enum.each(owner_refs, fn ref ->
        Process.send_after(self(), {:owner_stop, key, ref}, grace)
      end)

      {task_pid, state} =
        start_kill_task(state, key, Enum.map(spawned_refs, &state.entries[&1]), grace)

      # Adopt every pending reap-kill (reap→sweep ordering; the mid-sweep
      # reap inserts its monitor via adopt_into_sweep/3). The reaping
      # entries still ALSO ride the sweep's own kill task — idempotent,
      # identity-verified, and robust if the reap-kill task crashed
      # without killing.
      adopted =
        spawned_refs
        |> Enum.map(&state.entries[&1].reap_kill_mon)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      sweep = %{
        task_pid: task_pid,
        froms: froms,
        kills_done: is_nil(task_pid),
        pending_owners: MapSet.new(owner_refs),
        pending_kills: adopted
      }

      if sweep.kills_done and MapSet.size(sweep.pending_owners) == 0 and
           MapSet.size(sweep.pending_kills) == 0 do
        # Born-complete: the kill task could not start (supervisor gone)
        # and nothing else pends — start_kill_task/4 already killed these
        # entries SYNCHRONOUSLY, so drop the swept refs and reply complete
        # (exactly what complete_sweep/3 would do); installing the sweep
        # would wedge its callers forever with no event left to fire.
        {:empty, Enum.reduce(spawned_refs, state, fn ref, acc -> drop_entry(acc, ref) end)}
      else
        {:started, %{state | sweeps: Map.put(state.sweeps, key, sweep)}}
      end
    end
  end

  defp start_kill_task(state, _key, [], _grace), do: {nil, state}

  defp start_kill_task(state, key, entries, grace) do
    tracker = self()

    case start_task(state.task_supervisor, fn ->
           Enum.each(entries, &verified_kill(&1, grace))
           send(tracker, {:sweep_complete, key})
         end) do
      {:ok, task_pid} ->
        mon = Process.monitor(task_pid)
        {task_pid, %{state | monitors: Map.put(state.monitors, mon, {:sweep, key})}}

      {:error, :unavailable} ->
        # The kill phase must never be PRETENDED done: kill synchronously
        # in-server so the nil task pid truthfully means "no asynchronous
        # work left" — a sweep completing over these entries drops
        # verified-dead processes, not live ones.
        Logger.warning(
          "[Forge.ChildTracker] sweep kill task for #{inspect(key)} could not start — " <>
            "killing synchronously"
        )

        Enum.each(entries, &sync_verified_kill/1)
        {nil, state}
    end
  end

  # A registered root whose CURRENT identity no longer matches its birth
  # identity was reused by the OS — never killed. A nil birth identity is
  # unverifiable — also never killed (the accepted residual; owner-only
  # entries land here by construction).
  defp verified_kill(%{os_pid: os_pid, birth_id: birth}, grace) do
    if is_binary(birth) and OsCmd.process_identity(os_pid) == birth do
      OsCmd.terminate_tree(os_pid, grace)
    end

    :ok
  end

  # Async identity-verified kill (F3): the refusal and reap paths share the
  # sweep's predicate — a reused OS pid or an unverifiable birth refuses.
  defp spawn_kill(state, entry, grace) do
    start_task(state.task_supervisor, fn ->
      await_kill_gate()
      verified_kill(entry, grace)
    end)
  end

  # Task.Supervisor.start_child/2 EXITS (:noproc) against a missing or
  # stopped supervisor — it never returns an error — so every "task didn't
  # start" branch would otherwise be unreachable exactly when needed (VM
  # shutdown: the supervisor starts after this tracker and terminates
  # first), crashing the tracker instead of degrading. Every non-{:ok, pid}
  # result normalizes to the same refusal so a future :max_children config
  # follows the same safe path.
  defp start_task(supervisor, fun) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, pid} -> {:ok, pid}
      _refused -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # The supervisor-gone degradation is async → SYNCHRONOUS, never
  # async → pretended-done: bounded (grace 0), identity-verified, raises
  # rescued (the accepted best-effort residual class — same as the
  # dead-sweep-task lane) so a shutdown-time kill can never crash the
  # tracker's bookkeeping away.
  defp sync_verified_kill(entry) do
    verified_kill(entry, 0)
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.error(
        "[Forge.ChildTracker] synchronous kill for #{inspect(entry.key)} raised: " <>
          Exception.message(e)
      )

      :ok
  end

  # Test-only choreography seam (app-env armed; unset — production — this
  # is a no-op): a held kill makes reap retention observable and DOWN
  # timing test-controlled. The `after` bound means a leaked gate can
  # never wedge a real kill.
  defp await_kill_gate do
    case Application.get_env(:jido_claw, :forge_child_tracker_kill_gate) do
      gate when is_pid(gate) ->
        ref = make_ref()
        send(gate, {:kill_gate, ref, self()})

        receive do
          {:kill_gate_release, ^ref} -> :ok
        after
          30_000 -> :ok
        end

      _unset ->
        :ok
    end
  end

  # A refused late registration's kill joins any in-flight barrier: the
  # sweeping key's `pending_kills`, else the session wait's `late_kills` —
  # so a barrier can no longer complete while a just-refused CLI's
  # terminate_tree is still running. With no barrier in flight it stays
  # fire-and-forget.
  defp refuse_kill(state, key, entry) do
    case spawn_kill(state, entry, 0) do
      {:ok, task_pid} ->
        track_late_kill(state, key, task_pid)

      _not_started ->
        # Supervisor gone: kill synchronously — this runs inside the
        # registration call, so {:error, :closing} replies only after the
        # verified kill finished (a refused CLI must never outlive the
        # refusal because the async lane was unavailable).
        Logger.warning(
          "[Forge.ChildTracker] refusal kill task for #{inspect(key)} could not start — " <>
            "killing synchronously"
        )

        sync_verified_kill(entry)
        state
    end
  end

  defp track_late_kill(state, key, task_pid) do
    session_id = session_of(key)

    case Map.get(state.sweeps, key) do
      %{pending_kills: kills} = sweep ->
        mon = Process.monitor(task_pid)
        sweep = %{sweep | pending_kills: MapSet.put(kills, mon)}

        %{
          state
          | sweeps: Map.put(state.sweeps, key, sweep),
            monitors: Map.put(state.monitors, mon, {:late_kill, key})
        }

      nil ->
        if Map.has_key?(state.session_waits, session_id) do
          mon = Process.monitor(task_pid)

          %{
            state
            | late_kills: Map.put(state.late_kills, mon, session_id),
              monitors: Map.put(state.monitors, mon, {:late_kill_session, session_id})
          }
        else
          state
        end
    end
  end

  defp mark_kills_done(state, key) do
    case Map.get(state.sweeps, key) do
      nil ->
        state

      sweep ->
        state = %{state | sweeps: Map.put(state.sweeps, key, %{sweep | kills_done: true})}
        maybe_complete_sweep(state, key)
    end
  end

  # A sweep completes only when the kill phase reported AND no pre-spawn
  # owner is still pending AND no tracked late or adopted reap kill is
  # still running.
  defp maybe_complete_sweep(state, key) do
    case Map.get(state.sweeps, key) do
      %{kills_done: true, pending_owners: owners, pending_kills: kills} = sweep ->
        if MapSet.size(owners) == 0 and MapSet.size(kills) == 0 do
          complete_sweep(state, key, sweep)
        else
          state
        end

      _incomplete_or_absent ->
        state
    end
  end

  defp complete_sweep(state, key, %{froms: froms}) do
    Enum.each(froms, &GenServer.reply(&1, :ok))

    state =
      state.by_key
      |> Map.get(key, MapSet.new())
      |> Enum.reduce(%{state | sweeps: Map.delete(state.sweeps, key)}, fn ref, acc ->
        drop_entry(acc, ref)
      end)

    settle_session_waits(state, key)
  end

  # The one clearing path for a sweep's pending-owner ref — owner DOWN and
  # non-reaping unregister route here (the TTL reap no longer clears
  # directly: it force-stops the owner and lets its DOWN resolve).
  defp clear_pending_owner(state, ref), do: clear_sweep_dependency(state, :pending_owners, ref)

  # The pending-kill mirror: tracked late kills and adopted reap-kills
  # clear through here when their monitors resolve.
  defp clear_pending_kill(state, mon), do: clear_sweep_dependency(state, :pending_kills, mon)

  defp clear_sweep_dependency(state, field, item) do
    Enum.reduce(state.sweeps, state, fn {key, sweep}, acc ->
      if MapSet.member?(Map.fetch!(sweep, field), item) do
        sweep = Map.update!(sweep, field, &MapSet.delete(&1, item))
        maybe_complete_sweep(%{acc | sweeps: Map.put(acc.sweeps, key, sweep)}, key)
      else
        acc
      end
    end)
  end

  defp owner_down(state, ref) do
    state =
      case Map.get(state.entries, ref) do
        %{os_pid: nil} ->
          # Owner-only entry: no future attach possible (attach comes from
          # the owner itself) — drop it, no kill. This is ALSO the single
          # resolution point for a TTL-reaped (force-stopped) owner.
          drop_entry(state, ref)

        _spawned_or_gone ->
          # Spawned entries keep their semantics — the CLI can outlive the
          # task and stays until swept or TTL-reaped.
          state
      end

    clear_pending_owner(state, ref)
  end

  defp sweep_task_down(state, key) do
    case Map.get(state.sweeps, key) do
      %{kills_done: false} ->
        # The sweep task died without reporting — complete best-effort so
        # joiners are never wedged (adopted reap-kills still hold the
        # sweep open until their own DOWNs resolve).
        Logger.warning("[Forge.ChildTracker] sweep task for #{inspect(key)} died — completing")
        mark_kills_done(state, key)

      _reported_or_absent ->
        state
    end
  end

  defp late_kill_down(state, key, mon) do
    case Map.get(state.sweeps, key) do
      nil ->
        state

      sweep ->
        sweep = %{sweep | pending_kills: MapSet.delete(sweep.pending_kills, mon)}
        maybe_complete_sweep(%{state | sweeps: Map.put(state.sweeps, key, sweep)}, key)
    end
  end

  # A reaping entry resolves ONLY here: a `:normal` exit is the only proof
  # the verified kill finished.
  defp reap_kill_down(state, ref, mon, :normal) do
    state
    |> drop_entry(ref)
    |> clear_pending_owner(ref)
    |> clear_pending_kill(mon)
  end

  # Abnormal exit — task crash, or the task supervisor (started after this
  # tracker, so terminated first at shutdown) killing in-flight tasks: the
  # kill did NOT complete, so the entry is never discarded on it.
  defp reap_kill_down(state, ref, mon, reason) do
    case Map.get(state.entries, ref) do
      nil ->
        clear_pending_kill(state, mon)

      entry ->
        Logger.warning(
          "[Forge.ChildTracker] reap kill for #{inspect(entry.key)} exited " <>
            "#{inspect(reason)} — restarting"
        )

        entry = %{entry | reaping: false, reap_kill_mon: nil}
        state = put_entry(state, ref, entry)

        # Replacement FIRST, dead-monitor clear SECOND: clear_pending_kill
        # runs the sweep completion check, and clearing the sweep's last
        # dependency before the replacement exists would complete the
        # sweep and drop the entry mid-kill.
        case start_reap_kill(state, ref, entry) do
          {:started, state} -> clear_pending_kill(state, mon)
          {:not_started, state} -> sync_reap_fallback(state, ref, entry, mon)
        end
    end
  end

  # The task supervisor is gone (VM shutdown): kill synchronously
  # in-server, bounded (grace 0 — two ps execs; the pathological lane can
  # afford it), then let any sweep complete over verified-dead processes.
  defp sync_reap_fallback(state, ref, entry, mon) do
    verified_kill(entry, 0)

    state
    |> drop_entry(ref)
    |> clear_pending_owner(ref)
    |> clear_pending_kill(mon)
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      # Supervisor down AND the kill raising — the accepted pathological
      # residual (same class as the dead-sweep-task lane): keep the entry
      # for terminate/2, clear only the dead monitor.
      Logger.error(
        "[Forge.ChildTracker] synchronous reap fallback for #{inspect(entry.key)} raised: " <>
          Exception.message(e)
      )

      clear_pending_kill(state, mon)
  end

  # Hand a reaping entry its monitored, identity-verified kill: the entry
  # is RETAINED marked `reaping` until the kill task's DOWN resolves it —
  # a barrier arriving mid-reap sees either the entry (and outwaits the
  # adopted kill) or nothing left alive. On a start refusal the entry
  # stays exactly as passed (the caller decides the retry posture).
  defp start_reap_kill(state, ref, entry) do
    case spawn_kill(state, entry, 0) do
      {:ok, task_pid} ->
        mon = Process.monitor(task_pid)
        entry = %{entry | reaping: true, reap_kill_mon: mon}

        state = %{
          state
          | monitors: Map.put(state.monitors, mon, {:reap_kill, ref}),
            entries: Map.put(state.entries, ref, entry)
        }

        {:started, adopt_into_sweep(state, entry.key, mon)}

      _not_started ->
        {:not_started, state}
    end
  end

  # Sweep→reap ordering: a reap firing while the key's sweep is already in
  # flight inserts its fresh kill monitor into that sweep's pending_kills
  # (no-op without one — reap→sweep ordering seeds at start_sweep instead).
  defp adopt_into_sweep(state, key, mon) do
    case Map.get(state.sweeps, key) do
      nil ->
        state

      %{pending_kills: kills} = sweep ->
        sweep = %{sweep | pending_kills: MapSet.put(kills, mon)}
        %{state | sweeps: Map.put(state.sweeps, key, sweep)}
    end
  end

  defp settle_session_waits(state, key) do
    session_id = session_of(key)

    case Map.get(state.session_waits, session_id) do
      nil ->
        state

      %{pending: pending} = wait ->
        try_settle_session(state, session_id, %{wait | pending: MapSet.delete(pending, key)})
    end
  end

  # Session-wait settlement requires the pending sweep set empty AND the
  # session's tracked late-kill set empty.
  defp try_settle_session(state, session_id, wait) do
    if MapSet.size(wait.pending) == 0 and not session_late_kills?(state, session_id) do
      Enum.each(wait.froms, &GenServer.reply(&1, :ok))
      %{state | session_waits: Map.delete(state.session_waits, session_id)}
    else
      %{state | session_waits: Map.put(state.session_waits, session_id, wait)}
    end
  end

  defp resettle_session(state, session_id) do
    case Map.get(state.session_waits, session_id) do
      nil -> state
      wait -> try_settle_session(state, session_id, wait)
    end
  end

  defp session_late_kills?(state, session_id) do
    Enum.any?(state.late_kills, fn {_mon, sid} -> sid == session_id end)
  end

  defp drop_entry(state, ref) do
    case Map.pop(state.entries, ref) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        by_key =
          case Map.get(state.by_key, entry.key) do
            nil ->
              state.by_key

            refs ->
              refs = MapSet.delete(refs, ref)

              if MapSet.size(refs) == 0,
                do: Map.delete(state.by_key, entry.key),
                else: Map.put(state.by_key, entry.key, refs)
          end

        %{state | entries: entries, by_key: by_key}
    end
  end

  # Tombstones drop on their TTL alone (per-run-unique session ids make
  # long retention safe — see the moduledoc law). Entries past their TTL
  # are handed to reap_entry/3 and RETAINED marked reaping — removal
  # happens only at their DOWN (owner DOWN / the reap-kill task's normal
  # exit), so a barrier arriving mid-reap never loses accounting.
  defp reap(state) do
    now = System.monotonic_time(:millisecond)

    expired_entries =
      Enum.filter(state.entries, fn {_ref, entry} -> entry.ttl < now and not entry.reaping end)

    reaped =
      Enum.reduce(expired_entries, state, fn {ref, entry}, acc ->
        reap_entry(acc, ref, entry)
      end)

    reapable = fn {_key, ts} -> ts.ttl < now end
    tombstones = Map.new(Enum.reject(reaped.tombstones, reapable))
    session_tombstones = Map.new(Enum.reject(reaped.session_tombstones, reapable))

    %{reaped | tombstones: tombstones, session_tombstones: session_tombstones}
  end

  # An owner-only entry alive at TTL (2 × (timeout + grace)) has spent
  # double its iteration budget without spawning a CLI — genuinely wedged
  # pre-spawn work. Force-stop it (the sweep's bounded owner-stop
  # posture); owner_down/2 is the single resolution point.
  defp reap_entry(state, ref, %{os_pid: nil} = entry) do
    Logger.warning(
      "[Forge.ChildTracker] force-stopping TTL-expired pre-spawn owner for #{inspect(entry.key)}"
    )

    Process.exit(entry.owner, :kill)
    put_entry(state, ref, %{entry | reaping: true})
  end

  defp reap_entry(state, ref, entry) do
    Logger.warning(
      "[Forge.ChildTracker] TTL-reaping leaked entry for #{inspect(entry.key)} (os pid #{entry.os_pid})"
    )

    # On a start refusal the entry stays un-marked — the next tick
    # retries, and any intervening barrier still sees the entry.
    {_started_or_not, state} = start_reap_kill(state, ref, entry)
    state
  end

  defp schedule_reap, do: Process.send_after(self(), :reap, @reap_interval_ms)
end
