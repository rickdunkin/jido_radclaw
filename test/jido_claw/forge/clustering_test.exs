defmodule JidoClaw.Forge.ClusteringTest.MockHarness do
  @moduledoc false
  use GenServer

  # A minimal GenServer that responds to the same call messages as Harness,
  # but is NOT registered in the local SessionRegistry. Used to verify that
  # Harness.call/2 and Manager.get_session_cluster/1 actually fall through
  # to the :pg lookup path.

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  @impl true
  def init(session_id) do
    {:ok, %{session_id: session_id}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      state: :ready,
      iteration: 0,
      runner: nil,
      sandbox_id: nil,
      sandbox_status: :ready,
      sandboxes: [:default],
      started_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      source: :pg_fallback
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:exec, command, _opts}, _from, state) do
    {:reply, {:ok, {"mock:#{command}", 0}}, state}
  end
end

defmodule JidoClaw.Forge.ClusteringTest do
  @moduledoc """
  Tests for Phase 7: Clustering (Many Brains).
  Covers :pg group membership, cluster-aware session lookup, :pg fallback
  path verification, cluster-wide duplicate rejection, and graceful
  degradation when clustering is disabled.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge
  alias JidoClaw.Forge.{Manager, Harness}
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ClusteringTest.MockHarness

  @timeout 10_000

  setup do
    # Disable persistence for these tests
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    # Ensure clustering is disabled by default
    prev_cluster = Application.get_env(:jido_claw, :cluster_enabled, false)
    Application.put_env(:jido_claw, :cluster_enabled, false)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.put_env(:jido_claw, :cluster_enabled, prev_cluster)
    end)

    :ok
  end

  defp start_session(opts \\ []) do
    session_id = "cluster_test_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(session_id)

    spec = Keyword.get(opts, :spec, %{runner: :shell, sandbox: :fake})
    {:ok, _handle} = Forge.start_session(session_id, spec)
    assert_receive {:ready, ^session_id}, @timeout

    session_id
  end

  defp stop_session(session_id) do
    try do
      Forge.stop_session(session_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  describe "without clustering (default)" do
    test "sessions work normally via local Registry" do
      sid = start_session()

      {:ok, status} = Forge.status(sid)
      assert status.state == :ready

      {:ok, {output, 0}} = Forge.exec(sid, "echo hello")
      assert String.trim(output) == "hello"

      stop_session(sid)
    end

    test "get_session_cluster/1 finds local sessions" do
      sid = start_session()

      {:ok, pid} = Manager.get_session_cluster(sid)
      assert is_pid(pid)
      assert node(pid) == node()

      stop_session(sid)
    end

    test "get_session_cluster/1 returns not_found for missing sessions" do
      assert {:error, :not_found} = Manager.get_session_cluster("nonexistent_session")
    end

    test "get_handle/1 uses cluster-aware lookup" do
      sid = start_session()

      {:ok, handle} = Forge.get_handle(sid)
      assert handle.session_id == sid
      assert is_pid(handle.pid)

      stop_session(sid)
    end

    test "Harness.call routes to local sessions" do
      sid = start_session()

      {:ok, status} = Harness.status(sid)
      assert status.session_id == sid

      stop_session(sid)
    end

    test "cluster lookup falls through gracefully when disabled" do
      assert {:error, :not_found} = Manager.get_session_cluster("ghost_session")
    end
  end

  describe "with clustering enabled" do
    setup do
      # Start a :pg scope for the test. If the app already started one
      # (unlikely in test), this will fail harmlessly.
      pg_pid =
        case :pg.start_link(:jido_claw) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      Application.put_env(:jido_claw, :cluster_enabled, true)

      on_exit(fn ->
        Application.put_env(:jido_claw, :cluster_enabled, false)
        if Process.alive?(pg_pid) do
          Process.exit(pg_pid, :normal)
        end
      end)

      :ok
    end

    test "Harness joins :pg group on init" do
      sid = start_session()

      members = :pg.get_members(:jido_claw, {:forge_session, sid})
      assert length(members) == 1

      {:ok, pid} = Manager.get_session(sid)
      assert pid in members

      stop_session(sid)
    end

    test ":pg group is empty after session stops" do
      sid = start_session()

      assert [_pid] = :pg.get_members(:jido_claw, {:forge_session, sid})

      stop_session(sid)
      Process.sleep(50)

      assert :pg.get_members(:jido_claw, {:forge_session, sid}) == []
    end

    test "get_session_cluster/1 finds sessions via :pg" do
      sid = start_session()

      {:ok, pid} = Manager.get_session_cluster(sid)
      assert is_pid(pid)

      stop_session(sid)
    end

    test "cluster lookup returns not_found when session doesn't exist" do
      assert {:error, :not_found} = Manager.get_session_cluster("no_such_session")
    end

    test "operations route correctly with clustering enabled" do
      sid = start_session()

      {:ok, status} = Forge.status(sid)
      assert status.state == :ready

      {:ok, {output, 0}} = Forge.exec(sid, "echo clustered")
      assert String.trim(output) == "clustered"

      {:ok, result} = Forge.run_iteration(sid, command: "echo iteration_works")
      assert result.status == :done
      assert result.output =~ "iteration_works"

      stop_session(sid)
    end

    test "multiple sessions join distinct :pg groups" do
      sid1 = start_session()
      sid2 = start_session()

      members1 = :pg.get_members(:jido_claw, {:forge_session, sid1})
      members2 = :pg.get_members(:jido_claw, {:forge_session, sid2})

      assert length(members1) == 1
      assert length(members2) == 1
      refute hd(members1) == hd(members2)

      stop_session(sid1)
      stop_session(sid2)
    end

    test "attach_sandbox works with clustering enabled" do
      sid = start_session()

      {:ok, result} = Forge.attach_sandbox(sid, :clustered_sbx, %{sandbox: :fake})
      assert result.name == :clustered_sbx

      {:ok, {output, 0}} = Forge.exec(sid, "echo from_attached", sandbox: :clustered_sbx)
      assert String.trim(output) == "from_attached"

      stop_session(sid)
    end
  end

  describe ":pg fallback path (session in :pg but not local Registry)" do
    # These tests verify the actual cluster fallback code path by creating a
    # MockHarness that is registered ONLY in :pg, never in the local Registry.
    # This forces Manager.get_session_cluster/1 and Harness.call/2 to miss the
    # Registry.lookup and fall through to :pg.get_members.

    setup do
      pg_pid =
        case :pg.start_link(:jido_claw) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      Application.put_env(:jido_claw, :cluster_enabled, true)

      on_exit(fn ->
        Application.put_env(:jido_claw, :cluster_enabled, false)
        if Process.alive?(pg_pid) do
          Process.exit(pg_pid, :normal)
        end
      end)

      :ok
    end

    test "get_session_cluster/1 finds session via :pg when not in local Registry" do
      sid = "pg_only_#{:erlang.unique_integer([:positive])}"
      {:ok, mock_pid} = MockHarness.start_link(sid)
      :pg.join(:jido_claw, {:forge_session, sid}, mock_pid)

      # Confirm it's NOT in the local Registry
      assert Registry.lookup(JidoClaw.Forge.SessionRegistry, sid) == []

      # Cluster-aware lookup must find it via :pg
      {:ok, found_pid} = Manager.get_session_cluster(sid)
      assert found_pid == mock_pid

      GenServer.stop(mock_pid)
    end

    test "Harness.status/1 routes to :pg-only session via call/2 fallback" do
      sid = "pg_status_#{:erlang.unique_integer([:positive])}"
      {:ok, mock_pid} = MockHarness.start_link(sid)
      :pg.join(:jido_claw, {:forge_session, sid}, mock_pid)

      # Confirm not in local Registry
      assert Registry.lookup(JidoClaw.Forge.SessionRegistry, sid) == []

      # Harness.status calls the private call/2 which should fall through to :pg
      {:ok, status} = Harness.status(sid)
      assert status.session_id == sid
      assert status.source == :pg_fallback

      GenServer.stop(mock_pid)
    end

    test "Harness.exec/3 routes to :pg-only session via call/2 fallback" do
      sid = "pg_exec_#{:erlang.unique_integer([:positive])}"
      {:ok, mock_pid} = MockHarness.start_link(sid)
      :pg.join(:jido_claw, {:forge_session, sid}, mock_pid)

      assert Registry.lookup(JidoClaw.Forge.SessionRegistry, sid) == []

      {:ok, {output, 0}} = Harness.exec(sid, "test_command")
      assert output == "mock:test_command"

      GenServer.stop(mock_pid)
    end

    test "Forge.get_handle/1 resolves :pg-only session" do
      sid = "pg_handle_#{:erlang.unique_integer([:positive])}"
      {:ok, mock_pid} = MockHarness.start_link(sid)
      :pg.join(:jido_claw, {:forge_session, sid}, mock_pid)

      {:ok, handle} = Forge.get_handle(sid)
      assert handle.session_id == sid
      assert handle.pid == mock_pid

      GenServer.stop(mock_pid)
    end

    test "returns not_found when session is absent from both Registry and :pg" do
      assert {:error, :not_found} = Manager.get_session_cluster("truly_missing")
      assert {:error, :not_found} = Harness.status("truly_missing")
    end
  end

  describe "cluster-wide duplicate rejection" do
    setup do
      pg_pid =
        case :pg.start_link(:jido_claw) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      Application.put_env(:jido_claw, :cluster_enabled, true)

      on_exit(fn ->
        Application.put_env(:jido_claw, :cluster_enabled, false)
        if Process.alive?(pg_pid) do
          Process.exit(pg_pid, :normal)
        end
      end)

      :ok
    end

    test "start_session rejects session_id already present in :pg on another node" do
      sid = "dup_cluster_#{:erlang.unique_integer([:positive])}"

      # Simulate a session already running on a remote node by placing a
      # MockHarness into the :pg group (without local Registry entry).
      {:ok, mock_pid} = MockHarness.start_link(sid)
      :pg.join(:jido_claw, {:forge_session, sid}, mock_pid)

      # Confirm not in local Registry (simulates remote-only session)
      assert Registry.lookup(JidoClaw.Forge.SessionRegistry, sid) == []

      # Attempting to start the same session_id locally should be rejected
      assert {:error, :already_exists} =
               Forge.start_session(sid, %{runner: :shell, sandbox: :fake})

      GenServer.stop(mock_pid)
    end

    test "start_session succeeds when :pg group is empty" do
      sid = "no_dup_#{:erlang.unique_integer([:positive])}"
      ForgePubSub.subscribe(sid)

      # No mock in :pg — should start normally
      {:ok, _handle} = Forge.start_session(sid, %{runner: :shell, sandbox: :fake})
      assert_receive {:ready, ^sid}, @timeout

      stop_session(sid)
    end

    test "start_session rejects local duplicates same as before" do
      sid = start_session()

      # Second start with same ID should fail (local Registry check)
      assert {:error, :already_exists} =
               Forge.start_session(sid, %{runner: :shell, sandbox: :fake})

      stop_session(sid)
    end
  end

  describe "atomic DB claim (Persistence.claim_session)" do
    # These tests exercise the DB-level claim that makes session ownership
    # atomic across the cluster. The unique index on forge_sessions.name
    # ensures only one node can win a concurrent start.

    setup do
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: true)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

      on_exit(fn ->
        Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
      end)

      :ok
    end

    test "claim_session succeeds for a fresh session_id" do
      sid = "claim_fresh_#{:erlang.unique_integer([:positive])}"
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})

      # Verify the row was created
      session = JidoClaw.Forge.Persistence.find_session(sid)
      assert session != nil
      assert session.phase == :created
    end

    test "claim_session rejects a duplicate session_id (advisory lock + phase check)" do
      sid = "claim_dup_#{:erlang.unique_integer([:positive])}"

      # First claim succeeds (creates row with phase :created)
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})

      # Second claim with same name fails — row is in :created (active) phase
      assert {:error, :already_claimed} =
               JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
    end

    test "claim_session allows reuse of a terminal (completed) session" do
      sid = "claim_reuse_#{:erlang.unique_integer([:positive])}"

      # Create and mark as completed
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :completed)

      # Verify it's terminal
      session = JidoClaw.Forge.Persistence.find_session(sid)
      assert session.phase == :completed

      # Reclaiming a terminal session should succeed (upsert resets it)
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :workflow})

      # Verify the session was reset
      session = JidoClaw.Forge.Persistence.find_session(sid)
      assert session.phase == :created
    end

    test "claim_session allows reuse of a cancelled session" do
      sid = "claim_cancelled_#{:erlang.unique_integer([:positive])}"

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :cancelled)

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
    end

    test "claim_session allows reuse of a failed session" do
      sid = "claim_failed_#{:erlang.unique_integer([:positive])}"

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :failed)

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
    end

    test "claim_session rejects when existing session is in active phase" do
      sid = "claim_active_#{:erlang.unique_integer([:positive])}"

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :running)

      assert {:error, :already_claimed} =
               JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
    end

    test "recovery claim succeeds for active-phase sessions" do
      sid = "claim_recovery_#{:erlang.unique_integer([:positive])}"

      # Create a session and set it to :running (simulates a crash that
      # left stale state in the DB)
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :running)

      # A normal (non-recovery) claim should be rejected
      assert {:error, :already_claimed} =
               JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})

      # A recovery claim should succeed — the crashed process left stale state
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell}, recovery: true)

      # Verify the session was reset to :created
      session = JidoClaw.Forge.Persistence.find_session(sid)
      assert session.phase == :created
    end

    test "recovery claim rejects when another recovery already claimed" do
      sid = "claim_double_recovery_#{:erlang.unique_integer([:positive])}"

      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :failed)

      # First recovery claim succeeds (resets to :created)
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell}, recovery: true)

      # Second recovery claim sees :created (active) — rejected
      assert {:error, :already_claimed} =
               JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell}, recovery: true)
    end

    test "serialized terminal reuse — second claim sees reset row" do
      sid = "claim_serial_#{:erlang.unique_integer([:positive])}"

      # Create and terminate
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :completed)

      # First reuse claim succeeds (upsert resets to :created)
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :workflow})

      # Second reuse claim sees :created (active phase) — rejected
      assert {:error, :already_claimed} =
               JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
    end

    test "claim_session returns :ok when persistence is disabled" do
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

      assert :ok = JidoClaw.Forge.Persistence.claim_session("anything", %{runner: :shell})
    end

    test "Harness.init rejects when DB has active session for same name" do
      # This verifies the end-to-end path: Harness.init -> claim_session -> DB.
      # Use shared sandbox mode so the Harness process (spawned by
      # DynamicSupervisor) can access the DB connection.
      Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, {:shared, self()})

      pg_pid =
        case :pg.start_link(:jido_claw) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      Application.put_env(:jido_claw, :cluster_enabled, true)

      # Pre-create an active session in the DB
      sid = "claim_e2e_#{:erlang.unique_integer([:positive])}"
      assert :ok = JidoClaw.Forge.Persistence.claim_session(sid, %{runner: :shell})
      JidoClaw.Forge.Persistence.update_session_phase(sid, :running)

      # Starting a Forge session with the same name should fail
      assert {:error, :already_exists} =
               Forge.start_session(sid, %{runner: :shell, sandbox: :fake})

      Application.put_env(:jido_claw, :cluster_enabled, false)
      if Process.alive?(pg_pid), do: Process.exit(pg_pid, :normal)
    end
  end
end
