defmodule JidoClaw.Forge.ChildTrackerTest do
  @moduledoc """
  ChildTracker + `OsCmd.terminate_tree/2` against REAL OS processes
  (docs/system/forge-session-resume.md): graceful TERM → grace window →
  verified hard kill, the preserved-set rule (a root exiting during the
  window does not orphan its captured children), tombstoned late
  registrations, identity-guarded kills, in-flight sweep joins, the
  session-wide barrier, and the HostShell registration seam.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Forge.ChildTracker
  alias JidoClaw.Forge.Runner.HostShell
  alias JidoClaw.Security.Redaction.Env

  defp spawn_tree(script) do
    sh = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        args: ["-c", script]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp alive?(os_pid), do: OsCmd.process_identity(os_pid) != nil

  defp assert_eventually_dead(os_pid, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    assert wait_dead(os_pid, deadline), "expected OS pid #{os_pid} to die"
  end

  defp wait_dead(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        wait_dead(os_pid, deadline)
    end
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end

  defp child_of(os_pid) do
    {out, 0} =
      System.cmd(System.find_executable("ps"), ["-A", "-o", "pid=", "-o", "ppid="],
        stderr_to_stdout: true,
        env: Env.scrubbed_cmd_env()
      )

    parent = Integer.to_string(os_pid)

    out
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [pid, ^parent] -> String.to_integer(pid)
        _ -> nil
      end
    end)
  end

  defp key(epoch \\ 1), do: {"tracker_#{:erlang.unique_integer([:positive])}", {:durable, epoch}}

  describe "OsCmd.terminate_tree/2" do
    test "a TERM-respecting tree dies inside the grace window — fast, no hard kill needed" do
      {_port, root} = spawn_tree("sleep 300")

      started = System.monotonic_time(:millisecond)
      assert :ok = OsCmd.terminate_tree(root, 2_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert_eventually_dead(root)
      assert elapsed < 1_500, "graceful exit should not consume the whole window (#{elapsed}ms)"
    end

    test "a TERM-ignoring process is hard-killed after the window" do
      {_port, root} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)
      assert alive?(root)

      started = System.monotonic_time(:millisecond)
      assert :ok = OsCmd.terminate_tree(root, 300)
      elapsed = System.monotonic_time(:millisecond) - started

      assert_eventually_dead(root)
      assert elapsed >= 300, "the hard phase must wait out the grace window (#{elapsed}ms)"
    end

    test "preserved set: the root exiting during the window never orphans a captured child" do
      {_port, root} = spawn_tree(~s{(trap "" TERM; sleep 300) & sleep 300})
      Process.sleep(200)

      child = child_of(root)
      assert is_integer(child), "expected the TERM-trapping child to be forked"

      assert :ok = OsCmd.terminate_tree(root, 300)

      assert_eventually_dead(root)
      assert_eventually_dead(child)
    end
  end

  describe "ChildTracker registration + incarnation teardown" do
    test "a registered CLI is swept synchronously by its incarnation's teardown" do
      incarnation = key()
      {_port, os_pid} = spawn_tree("sleep 300")

      assert {:ok, _ref} = ChildTracker.register_spawn(incarnation, os_pid, timeout_ms: 30_000)

      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 300)
      assert_eventually_dead(os_pid)
    end

    test "a late registration against a closing incarnation is refused and killed" do
      incarnation = key()
      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 100)

      {_port, os_pid} = spawn_tree("sleep 300")
      assert {:error, :closing} = ChildTracker.register_spawn(incarnation, os_pid)
      assert_eventually_dead(os_pid)
    end

    test "a session tombstone refuses late registrations for ANY epoch of the session" do
      {sid, _tag} = key()
      assert :ok = ChildTracker.graceful_teardown_session(sid, grace_ms: 100)

      {_port, os_pid} = spawn_tree("sleep 300")
      assert {:error, :closing} = ChildTracker.register_spawn({sid, {:durable, 99}}, os_pid)
      assert_eventually_dead(os_pid)
    end

    test "a stale incarnation's teardown is inert on the NEW incarnation's processes" do
      {sid, _tag} = key()
      old_key = {sid, {:durable, 1}}
      new_key = {sid, {:durable, 2}}

      {_port, os_pid} = spawn_tree("sleep 300")
      assert {:ok, _ref} = ChildTracker.register_spawn(new_key, os_pid, timeout_ms: 30_000)

      assert :ok = ChildTracker.graceful_teardown(old_key, grace_ms: 100)
      Process.sleep(200)
      assert alive?(os_pid), "the new incarnation's CLI must survive the stale teardown"

      assert :ok = ChildTracker.graceful_teardown(new_key, grace_ms: 300)
      assert_eventually_dead(os_pid)
    end

    test "an unregistered command is no longer swept" do
      incarnation = key()
      {_port, os_pid} = spawn_tree("sleep 300")

      assert {:ok, ref} = ChildTracker.register_spawn(incarnation, os_pid, timeout_ms: 30_000)
      assert :ok = ChildTracker.unregister(ref)
      # The cast is async — give it a beat before sweeping.
      Process.sleep(50)

      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 100)
      Process.sleep(100)
      assert alive?(os_pid), "an unregistered process must not be killed"

      OsCmd.kill_tree(os_pid)
    end

    test "an already-dead registration is identity-unverifiable and never blind-killed" do
      incarnation = key()
      {_port, os_pid} = spawn_tree("true")
      assert_eventually_dead(os_pid)

      # The pid is dead at registration time (birth identity nil) — the
      # sweep must complete without killing whatever may reuse the pid.
      _ = ChildTracker.register_spawn(incarnation, os_pid, timeout_ms: 30_000)
      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 100)
    end

    test "a second teardown caller joins the in-flight sweep and both return complete" do
      incarnation = key()
      {_port, os_pid} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)

      assert {:ok, _ref} = ChildTracker.register_spawn(incarnation, os_pid, timeout_ms: 30_000)

      t1 = Task.async(fn -> ChildTracker.graceful_teardown(incarnation, grace_ms: 500) end)
      Process.sleep(50)
      t2 = Task.async(fn -> ChildTracker.graceful_teardown(incarnation, grace_ms: 500) end)

      assert :ok = Task.await(t1, 20_000)
      assert :ok = Task.await(t2, 20_000)
      refute alive?(os_pid)
    end
  end

  describe "two-phase registration (owner → attach)" do
    test "register_owner then register_spawn from the same process attach to ONE entry" do
      incarnation = key()
      {_port, os_pid} = spawn_tree("sleep 300")

      task =
        Task.async(fn ->
          {:ok, owner_ref} = ChildTracker.register_owner(incarnation, timeout_ms: 30_000)
          {:ok, spawn_ref} = ChildTracker.register_spawn(incarnation, os_pid, timeout_ms: 30_000)
          {owner_ref, spawn_ref}
        end)

      {owner_ref, spawn_ref} = Task.await(task, 5_000)
      # Same ref: the caller's later unregister drops the whole entry.
      assert owner_ref == spawn_ref

      # One entry under the key (owner DOWN keeps the attached entry — the
      # CLI outlives its task), and the sweep kills it identity-verified.
      state = :sys.get_state(ChildTracker)
      assert MapSet.size(Map.fetch!(state.by_key, incarnation)) == 1

      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 300)
      assert_eventually_dead(os_pid)
    end

    test "register_owner against a tombstoned session is refused" do
      {sid, _tag} = key()
      assert :ok = ChildTracker.graceful_teardown_session(sid, grace_ms: 100)

      assert {:error, :closing} =
               ChildTracker.register_owner({sid, {:durable, 7}}, timeout_ms: 5_000)
    end

    test "the incarnation sweep blocks on a pre-spawn owner and completes on owner DOWN" do
      incarnation = key()
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, _ref} = ChildTracker.register_owner(incarnation, timeout_ms: 30_000)
          send(test_pid, :owner_registered)

          receive do
            :finish -> :ok
          end
        end)

      assert_receive :owner_registered, 2_000

      barrier = Task.async(fn -> ChildTracker.graceful_teardown(incarnation, grace_ms: 2_000) end)

      # The barrier must NOT complete while the owner is mid pre-spawn work.
      refute Task.yield(barrier, 300)

      send(owner, :finish)
      assert :ok = Task.await(barrier, 5_000)
    end

    test "a wedged pre-spawn owner is force-stopped at the grace bound and the barrier completes" do
      incarnation = key()
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, _ref} = ChildTracker.register_owner(incarnation, timeout_ms: 30_000)
          send(test_pid, :owner_registered)
          Process.sleep(:infinity)
        end)

      assert_receive :owner_registered, 2_000

      started = System.monotonic_time(:millisecond)
      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 400)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 400, "the owner-stop bound must wait out the grace window (#{elapsed}ms)"
      refute Process.alive?(owner)
    end
  end

  describe "tombstone durability + tracked late kills" do
    test "a zero-owner session tombstone survives a reap tick and still refuses registration" do
      {sid, _tag} = key()
      assert :ok = ChildTracker.graceful_teardown_session(sid, grace_ms: 100)

      # Force a reap tick and synchronize on its processing — the F4
      # regression: the old owner-emptiness predicate reaped this tombstone
      # here, lapsing the late-kill protection.
      send(Process.whereis(ChildTracker), :reap)
      _ = :sys.get_state(ChildTracker)

      {_port, os_pid} = spawn_tree("sleep 300")
      assert {:error, :closing} = ChildTracker.register_spawn({sid, {:durable, 2}}, os_pid)
      assert_eventually_dead(os_pid)
    end

    test "a refusal kill during an in-flight barrier extends the barrier" do
      {sid, _tag} = key()
      key1 = {sid, {:durable, 1}}

      {_p1, pid1} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)
      assert {:ok, _} = ChildTracker.register_spawn(key1, pid1, timeout_ms: 30_000)

      barrier = Task.async(fn -> ChildTracker.graceful_teardown_session(sid, grace_ms: 800) end)
      Process.sleep(150)

      # A TERM-trapping late straggler registers against the tombstoned
      # session mid-barrier: refused, killed, and the kill is TRACKED — the
      # barrier may only return once it finished.
      {_p2, pid2} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)

      assert {:error, :closing} =
               ChildTracker.register_spawn({sid, {:durable, 2}}, pid2, timeout_ms: 30_000)

      assert :ok = Task.await(barrier, 20_000)
      # At barrier return BOTH trees are already dead — no post-return grace.
      refute alive?(pid1)
      refute alive?(pid2)
    end

    test "the TTL reap kills a live leaked entry identity-verified and refuses a dead-birth twin" do
      prev = Application.get_env(:jido_claw, :forge_runner_teardown_grace_ms)
      Application.put_env(:jido_claw, :forge_runner_teardown_grace_ms, 10)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:jido_claw, :forge_runner_teardown_grace_ms)
          val -> Application.put_env(:jido_claw, :forge_runner_teardown_grace_ms, val)
        end
      end)

      incarnation = key()
      {_port, live_pid} = spawn_tree("sleep 300")
      {_port2, dead_pid} = spawn_tree("true")
      assert_eventually_dead(dead_pid)

      # TTL = 2 × (1 + 10)ms — both entries expire immediately.
      assert {:ok, _} = ChildTracker.register_spawn(incarnation, live_pid, timeout_ms: 1)
      _ = ChildTracker.register_spawn(incarnation, dead_pid, timeout_ms: 1)

      Process.sleep(50)
      send(Process.whereis(ChildTracker), :reap)
      _ = :sys.get_state(ChildTracker)

      # The live leak is killed (identity verified); the dead-birth twin is
      # refused without crashing the tracker, and both entries drop by
      # their monitored kill tasks' DOWNs (asynchronously — poll).
      assert_eventually_dead(live_pid)

      assert eventually(fn ->
               not Map.has_key?(:sys.get_state(ChildTracker).by_key, incarnation)
             end)
    end
  end

  describe "session-wide barrier" do
    test "sweeps every live incarnation concurrently and returns only when all are down" do
      {sid, _tag} = key()
      key1 = {sid, {:durable, 1}}
      key2 = {sid, {:durable, 2}}

      {_p1, pid1} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      {_p2, pid2} = spawn_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)

      assert {:ok, _} = ChildTracker.register_spawn(key1, pid1, timeout_ms: 30_000)
      assert {:ok, _} = ChildTracker.register_spawn(key2, pid2, timeout_ms: 30_000)

      started = System.monotonic_time(:millisecond)
      assert :ok = ChildTracker.graceful_teardown_session(sid, grace_ms: 400)
      elapsed = System.monotonic_time(:millisecond) - started

      # The barrier returns only after BOTH TERM-trapping trees are dead…
      refute alive?(pid1)
      refute alive?(pid2)
      # …and the sweeps ran concurrently: wall time is bounded by ONE grace
      # window plus kill/ps overhead, not the sum of both windows.
      assert elapsed >= 400
      assert elapsed < 3_000, "expected concurrent sweeps, got #{elapsed}ms"
    end
  end

  # A PRIVATE, TICK-LESS tracker driven by direct GenServer.call/cast
  # (mirroring the thin client funs): every :reap is test-sent, so no
  # automatic tick can interleave mid-choreography even on slow CI, and
  # the shared singleton other suites depend on is never touched.
  defp start_tracker(opts) do
    opts = Keyword.merge([name: nil, schedule_reap: false], opts)

    start_supervised!(
      Supervisor.child_spec({ChildTracker, opts},
        id: {:private_tracker, :erlang.unique_integer([:positive])},
        restart: :temporary
      )
    )
  end

  # The app-env arming seam: a held kill makes reap retention observable
  # and DOWN timing test-controlled. Deleted in the describe's on_exit.
  defp arm_kill_gate do
    Application.put_env(:jido_claw, :forge_child_tracker_kill_gate, self())
  end

  defp spawn_blocked_owner do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    owner
  end

  defp spawn_reaped_tree(script) do
    {port, os_pid} = spawn_tree(script)
    on_exit(fn -> OsCmd.terminate_tree(os_pid, 0) end)
    {port, os_pid}
  end

  defp reg_owner(tracker, key, owner, timeout_ms),
    do: GenServer.call(tracker, {:register_owner, key, owner, timeout_ms})

  defp reg_spawn(tracker, key, os_pid, timeout_ms) do
    birth = OsCmd.process_identity(os_pid)
    GenServer.call(tracker, {:register, key, os_pid, birth, self(), timeout_ms})
  end

  defp teardown_async(tracker, msg) do
    Task.async(fn -> GenServer.call(tracker, msg, 15_000) end)
  end

  describe "TTL reap barrier accounting" do
    setup do
      prev = Application.get_env(:jido_claw, :forge_runner_teardown_grace_ms)
      Application.put_env(:jido_claw, :forge_runner_teardown_grace_ms, 10)

      on_exit(fn ->
        Application.delete_env(:jido_claw, :forge_child_tracker_kill_gate)

        case prev do
          nil -> Application.delete_env(:jido_claw, :forge_runner_teardown_grace_ms)
          val -> Application.put_env(:jido_claw, :forge_runner_teardown_grace_ms, val)
        end
      end)

      {:ok, tracker: start_tracker([])}
    end

    test "the reap force-stops a TTL-expired pre-spawn owner instead of dropping it", %{
      tracker: tracker
    } do
      incarnation = key()
      owner = spawn_blocked_owner()
      mon = Process.monitor(owner)

      # TTL = 2 × (1ms + 10ms grace) — expired after a beat.
      assert {:ok, _ref} = reg_owner(tracker, incarnation, owner, 1)
      Process.sleep(50)
      send(tracker, :reap)

      # The reap force-stops the wedged owner (never a silent drop) …
      assert_receive {:DOWN, ^mon, :process, ^owner, :killed}, 2_000

      # … and only the owner's own DOWN removes the entry.
      assert eventually(fn ->
               not Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
             end)

      # A teardown after resolution finds nothing live.
      assert :ok = GenServer.call(tracker, {:teardown, incarnation, 100}, 5_000)
    end

    test "a key tombstone never inherits an expired entry TTL — the reap can't lapse it mid-barrier",
         %{tracker: tracker} do
      incarnation = key()
      owner = spawn_blocked_owner()

      assert {:ok, _ref} = reg_owner(tracker, incarnation, owner, 1)
      Process.sleep(50)

      # The barrier pends on the live owner; its tombstone was minted from
      # the entry's already-expired TTL and must be clamped, not inherited.
      barrier = teardown_async(tracker, {:teardown, incarnation, 2_000})
      assert eventually(fn -> Map.has_key?(:sys.get_state(tracker).sweeps, incarnation) end)

      send(tracker, :reap)
      _ = :sys.get_state(tracker)

      # Only tombstones[key] can refuse this — no session tombstone exists.
      new_owner = spawn_blocked_owner()
      assert {:error, :closing} = reg_owner(tracker, incarnation, new_owner, 5_000)

      assert :ok = Task.await(barrier, 10_000)
      refute Process.alive?(owner)
    end

    test "a session tombstone never inherits an expired entry TTL and the barrier outwaits the owner",
         %{tracker: tracker} do
      {sid, _tag} = incarnation = key()
      owner = spawn_blocked_owner()

      assert {:ok, _ref} = reg_owner(tracker, incarnation, owner, 1)
      Process.sleep(50)

      barrier = teardown_async(tracker, {:teardown_session, sid, 2_000})
      assert eventually(fn -> Map.has_key?(:sys.get_state(tracker).sweeps, incarnation) end)

      send(tracker, :reap)
      _ = :sys.get_state(tracker)

      # A new-epoch owner AND a spawn straggler both refuse against the
      # clamped session tombstone, and the straggler is killed.
      new_owner = spawn_blocked_owner()
      assert {:error, :closing} = reg_owner(tracker, {sid, {:durable, 99}}, new_owner, 5_000)

      {_port, straggler} = spawn_reaped_tree("sleep 300")
      assert {:error, :closing} = reg_spawn(tracker, {sid, {:durable, 99}}, straggler, 5_000)

      assert_eventually_dead(straggler)
      assert :ok = Task.await(barrier, 10_000)
      refute Process.alive?(owner)
    end

    test "a sweep adopts a pending reap-kill and the barrier outwaits it", %{tracker: tracker} do
      arm_kill_gate()
      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree("sleep 300")

      assert {:ok, ref} = reg_spawn(tracker, incarnation, os_pid, 1)
      Process.sleep(50)
      send(tracker, :reap)

      # The reap's kill is held by the gate — the entry must be RETAINED,
      # marked reaping, with a monitored kill task.
      assert_receive {:kill_gate, gate_ref, task_pid}, 2_000

      state = :sys.get_state(tracker)
      assert MapSet.member?(Map.get(state.by_key, incarnation, MapSet.new()), ref)
      assert %{reaping: true, reap_kill_mon: kill_mon} = state.entries[ref]
      assert is_reference(kill_mon)
      assert state.monitors[kill_mon] == {:reap_kill, ref}

      barrier = teardown_async(tracker, {:teardown, incarnation, 200})

      # The sweep's OWN kill phase finishes (it re-kills the tree,
      # idempotent); ONLY the adopted reap-kill then holds the barrier.
      assert eventually(fn ->
               match?(%{kills_done: true}, :sys.get_state(tracker).sweeps[incarnation])
             end)

      sweep = :sys.get_state(tracker).sweeps[incarnation]
      assert MapSet.member?(sweep.pending_kills, kill_mon)
      assert Task.yield(barrier, 100) == nil

      # Release: the reap task's :normal DOWN drops the entry and lets
      # the sweep complete.
      send(task_pid, {:kill_gate_release, gate_ref})
      assert :ok = Task.await(barrier, 10_000)
      refute alive?(os_pid)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "a reap during an in-flight sweep adopts its kill into the barrier", %{tracker: tracker} do
      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree(~s(trap "" TERM; while true; do sleep 0.2; done))
      Process.sleep(100)

      assert {:ok, ref} = reg_spawn(tracker, incarnation, os_pid, 1)
      Process.sleep(50)

      # Barrier FIRST: the TERM-trap makes the sweep's own kill wait the
      # full grace window — a deterministic lower bound keeping the sweep
      # in flight while the reap lands (slow CI only widens the window).
      barrier = teardown_async(tracker, {:teardown, incarnation, 2_000})
      assert eventually(fn -> Map.has_key?(:sys.get_state(tracker).sweeps, incarnation) end)

      arm_kill_gate()
      send(tracker, :reap)
      assert_receive {:kill_gate, gate_ref, task_pid}, 2_000

      # Mid-sweep adoption: the fresh reap-kill monitor joins the
      # in-flight sweep's pending_kills.
      assert eventually(fn ->
               state = :sys.get_state(tracker)
               entry = state.entries[ref]
               sweep = state.sweeps[incarnation]

               entry != nil and sweep != nil and is_reference(entry.reap_kill_mon) and
                 MapSet.member?(sweep.pending_kills, entry.reap_kill_mon)
             end)

      assert eventually(
               fn ->
                 match?(%{kills_done: true}, :sys.get_state(tracker).sweeps[incarnation])
               end,
               8_000
             )

      # Kills done, no owners: the barrier waits on the ADOPTED kill alone.
      assert Task.yield(barrier, 100) == nil

      send(task_pid, {:kill_gate_release, gate_ref})
      assert :ok = Task.await(barrier, 10_000)
      refute alive?(os_pid)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "an abnormal reap-kill DOWN replaces the kill before clearing the sweep's last dependency",
         %{tracker: tracker} do
      arm_kill_gate()
      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree("sleep 300")

      assert {:ok, ref} = reg_spawn(tracker, incarnation, os_pid, 1)
      Process.sleep(50)
      send(tracker, :reap)
      assert_receive {:kill_gate, _gate1, task1}, 2_000

      barrier = teardown_async(tracker, {:teardown, incarnation, 200})

      assert eventually(fn ->
               match?(%{kills_done: true}, :sys.get_state(tracker).sweeps[incarnation])
             end)

      # The held kill is now the sweep's LAST dependency — the exact
      # completion race the replace-then-clear order exists for.
      Process.exit(task1, :kill)

      # The replacement announces a SECOND gate: the abnormal DOWN reset
      # and re-ran the kill BEFORE clearing the dead monitor, so the
      # crashed kill resolved nothing.
      assert_receive {:kill_gate, gate2, task2}, 2_000

      state = :sys.get_state(tracker)
      assert MapSet.member?(Map.get(state.by_key, incarnation, MapSet.new()), ref)
      new_mon = state.entries[ref].reap_kill_mon
      assert is_reference(new_mon)
      assert MapSet.member?(state.sweeps[incarnation].pending_kills, new_mon)
      assert Task.yield(barrier, 100) == nil

      send(task2, {:kill_gate_release, gate2})
      assert :ok = Task.await(barrier, 10_000)
      refute alive?(os_pid)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "unregister defers to the reap-kill DOWN for a reaping entry", %{tracker: tracker} do
      arm_kill_gate()
      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree("sleep 300")

      assert {:ok, ref} = reg_spawn(tracker, incarnation, os_pid, 1)
      Process.sleep(50)
      send(tracker, :reap)
      assert_receive {:kill_gate, gate_ref, task_pid}, 2_000

      # cast-then-call from one sender is FIFO — get_state observes the
      # cast already processed, and the entry must still be there.
      GenServer.cast(tracker, {:unregister, ref})
      state = :sys.get_state(tracker)
      assert MapSet.member?(Map.get(state.by_key, incarnation, MapSet.new()), ref)

      send(task_pid, {:kill_gate_release, gate_ref})
      assert eventually(fn -> not Map.has_key?(:sys.get_state(tracker).by_key, incarnation) end)
      refute alive?(os_pid)
    end

    test "losing the task supervisor mid-kill takes the synchronous verified-kill fallback", %{
      tracker: _unused
    } do
      {:ok, private_sup} = Task.Supervisor.start_link()
      tracker = start_tracker(task_supervisor: private_sup)

      arm_kill_gate()
      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree("sleep 300")

      assert {:ok, _ref} = reg_spawn(tracker, incarnation, os_pid, 1)
      Process.sleep(50)
      send(tracker, :reap)
      assert_receive {:kill_gate, _gate, _task}, 2_000

      # Freeze the tracker and queue the barrier FIRST, then fell the
      # supervisor: kill A's abnormal DOWN queues BEHIND the teardown, so
      # the sweep is in flight — pending on the adopted kill — when the
      # replacement start refuses and the synchronous fallbacks take over
      # (the sweep's own kill task never starts, so its sync fallback
      # kills the tree; the reap replacement's fallback then resolves the
      # adopted monitor over the verified-dead process).
      :sys.suspend(tracker)
      barrier = teardown_async(tracker, {:teardown, incarnation, 200})

      assert eventually(fn ->
               case Process.info(tracker, :messages) do
                 {:messages, msgs} ->
                   Enum.any?(msgs, &match?({:"$gen_call", _, {:teardown, _, _}}, &1))

                 nil ->
                   false
               end
             end)

      Supervisor.stop(private_sup)
      :sys.resume(tracker)

      assert :ok = Task.await(barrier, 10_000)
      # The SYNC fallback terminated the tree before the sweep was allowed
      # to complete — nothing else could have killed it.
      refute alive?(os_pid)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "a queued attach to a reaping owner refuses, adopts the identity, and kills — never revives",
         %{tracker: tracker} do
      incarnation = key()
      {_port, cli_pid} = spawn_reaped_tree("sleep 300")
      birth = OsCmd.process_identity(cli_pid)

      owner =
        spawn(fn ->
          receive do
            :go ->
              GenServer.call(
                tracker,
                {:register, incarnation, cli_pid, birth, self(), 30_000},
                5_000
              )
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)

      assert {:ok, _ref} = reg_owner(tracker, incarnation, owner, 1)
      Process.sleep(50)

      :sys.suspend(tracker)
      send(tracker, :reap)
      send(owner, :go)

      # The owner's attach call must queue BEHIND :reap — the exact
      # interleaving the revival scenario needs.
      assert eventually(fn ->
               case Process.info(tracker, :messages) do
                 {:messages, msgs} ->
                   reap_at = Enum.find_index(msgs, &(&1 == :reap))

                   reg_at =
                     Enum.find_index(
                       msgs,
                       &match?({:"$gen_call", _, {:register, _, _, _, _, _}}, &1)
                     )

                   is_integer(reap_at) and is_integer(reg_at) and reap_at < reg_at

                 nil ->
                   false
               end
             end)

      :sys.resume(tracker)

      # The reap kills the owner and marks the entry reaping; the queued
      # attach is then refused: identity adopted (no TTL refresh),
      # monitored kill fired — the CLI dies and the entry drops by the
      # kill's DOWN, never a revival.
      assert_eventually_dead(cli_pid)
      assert eventually(fn -> not Map.has_key?(:sys.get_state(tracker).by_key, incarnation) end)
    end

    test "zero-entry tombstones carry at least a fresh retention window", %{tracker: tracker} do
      {sid, _tag} = incarnation = key()

      before_ms = System.monotonic_time(:millisecond)
      assert :ok = GenServer.call(tracker, {:teardown, incarnation, 100}, 5_000)
      assert :ok = GenServer.call(tracker, {:teardown_session, sid, 100}, 5_000)
      after_ms = System.monotonic_time(:millisecond)

      state = :sys.get_state(tracker)
      assert %{ttl: key_ttl} = state.tombstones[incarnation]
      assert %{ttl: session_ttl} = state.session_tombstones[sid]

      # Bounds hold on any monotonic clock (the BEAM's is negative): a
      # zero-entry tombstone must retain one full fresh window — a
      # 0-seeded max would instead park the TTL at 0, which `ttl < now`
      # never reaps on a negative clock (an immortal tombstone leak).
      assert key_ttl >= before_ms + 300_000
      assert key_ttl <= after_ms + 300_000
      assert session_ttl >= before_ms + 300_000
      assert session_ttl <= after_ms + 300_000
    end

    test "a refused sweep kill task falls back to synchronous kills before replying complete",
         %{tracker: _unused} do
      {:ok, private_sup} = Task.Supervisor.start_link()
      tracker = start_tracker(task_supervisor: private_sup)

      incarnation = key()
      {_port, os_pid} = spawn_reaped_tree("sleep 300")
      assert {:ok, _ref} = reg_spawn(tracker, incarnation, os_pid, 30_000)

      Supervisor.stop(private_sup)

      # The kill task cannot start; the sweep must kill synchronously and
      # only then reply — never pretend the kill phase ran and drop a
      # live entry.
      assert :ok = GenServer.call(tracker, {:teardown, incarnation, 200}, 5_000)
      refute alive?(os_pid)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "a refused sweep kill task still awaits owners — sync-killed spawned entry, live owner",
         %{tracker: _unused} do
      {:ok, private_sup} = Task.Supervisor.start_link()
      tracker = start_tracker(task_supervisor: private_sup)

      incarnation = key()
      owner = spawn_blocked_owner()
      assert {:ok, _oref} = reg_owner(tracker, incarnation, owner, 30_000)

      {_port, os_pid} = spawn_reaped_tree("sleep 300")
      assert {:ok, _sref} = reg_spawn(tracker, incarnation, os_pid, 30_000)

      Supervisor.stop(private_sup)

      barrier = teardown_async(tracker, {:teardown, incarnation, 2_000})

      # The spawned tree dies via the synchronous fallback while the
      # barrier still pends on the live pre-spawn owner.
      assert_eventually_dead(os_pid)
      assert Task.yield(barrier, 100) == nil

      Process.exit(owner, :kill)
      assert :ok = Task.await(barrier, 10_000)
      refute Map.has_key?(:sys.get_state(tracker).by_key, incarnation)
    end

    test "a refused late registration is killed synchronously when the task supervisor is gone",
         %{tracker: _unused} do
      {:ok, private_sup} = Task.Supervisor.start_link()
      tracker = start_tracker(task_supervisor: private_sup)

      incarnation = key()
      assert :ok = GenServer.call(tracker, {:teardown, incarnation, 100}, 5_000)

      Supervisor.stop(private_sup)

      {_port, os_pid} = spawn_reaped_tree("sleep 300")
      assert {:error, :closing} = reg_spawn(tracker, incarnation, os_pid, 5_000)

      # The reply lands only after the in-server verified kill finished —
      # a refused CLI must never outlive the refusal because the async
      # lane was unavailable.
      refute alive?(os_pid)
    end
  end

  describe "HostShell registration seam" do
    test "a graceful-teardown run registers its CLI, and the incarnation sweep unblocks it" do
      incarnation = key()
      {:ok, client, _sandbox_id} = HostShell.create(%{})

      task =
        Task.async(fn ->
          HostShell.run(client, "sleep", ["300"],
            timeout: 60_000,
            teardown: :graceful,
            incarnation_key: incarnation
          )
        end)

      # Give the CLI a beat to spawn + register, then tear the incarnation
      # down — the run must return well before its own 60s timeout.
      Process.sleep(300)
      assert :ok = ChildTracker.graceful_teardown(incarnation, grace_ms: 300)

      assert {_output, status} = Task.await(task, 10_000)
      refute status == 0
    end
  end
end
