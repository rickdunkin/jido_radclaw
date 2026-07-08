defmodule JidoClaw.Cluster.LeaderTest do
  @moduledoc """
  WS4 — `:pg` leader election (single-BEAM). Cross-BEAM `:peer` election —
  agreement and re-election on a real leader-node death — is proven by WS6's
  `JidoClaw.Cluster.LeaderElectionTest`; here we test the pure
  selection/reducer core with synthetic node-name lists (a single BEAM cannot
  make `node(pid)` return a remote name), the `leader?/0`/`leader/0`
  fast-path + fail-closed behavior, real `:pg` join/leave wiring via the
  `:members_fun` DI seam, and the `:rest_for_one` restart coupling of `:pg` +
  Leader.

  `async: false`: toggles the global `:cluster_enabled` app-env and owns the
  shared `:jido_claw` `:pg` scope. `[[project_suite_flaky_tests]]`: verify in
  isolation, not under `--seed 0`.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Cluster
  alias JidoClaw.Cluster.Leader

  @group :cluster_leader

  setup do
    restore_app_env(:cluster_enabled)
    restore_app_env(:cluster_leader_module)
    :ok
  end

  defp restore_app_env(key) do
    original = Application.fetch_env(:jido_claw, key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, key, value)
        :error -> Application.delete_env(:jido_claw, key)
      end
    end)
  end

  # Start the shared `:jido_claw` :pg scope, killing it on exit only if WE
  # started it (mirrors the clustering_test idiom, but never kills a scope we
  # merely found already-running).
  defp start_pg_scope do
    {pid, started?} =
      case :pg.start_link(:jido_claw) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    on_exit(fn -> if started? and Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp wait_for_new_pid(name, old, attempts \\ 200) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(5)
        wait_for_new_pid(name, old, attempts - 1)

      _ ->
        flunk("#{inspect(name)} did not restart with a fresh pid")
    end
  end

  describe "elect/1 (pure)" do
    test "lowest node name wins" do
      assert Leader.elect([:c@h, :a@h, :b@h]) == :a@h
    end

    test "single member elects itself" do
      assert Leader.elect([:only@h]) == :only@h
    end

    test "empty membership has no leader" do
      assert Leader.elect([]) == nil
    end
  end

  describe "recompute/2 (pure)" do
    test "sets leader, reports change, and re-elects when the leader leaves" do
      state0 = %Leader{self_node: :b@h, leader: nil, members: []}

      {state1, changed1} = Leader.recompute(state0, [:a@h, :b@h])
      assert state1.leader == :a@h
      assert state1.members == [:a@h, :b@h]
      # nil -> :a@h is a change.
      assert changed1

      # The leader (:a@h) leaves → :b@h is now lowest → leadership moves.
      {state2, changed2} = Leader.recompute(state1, [:b@h])
      assert state2.leader == :b@h
      assert changed2
    end

    test "a membership change that doesn't move the leader reports changed? == false" do
      state = %Leader{self_node: :b@h, leader: :b@h, members: [:b@h]}

      # :c@h joins but :b@h is still lowest — membership changed, leader didn't.
      {next, changed?} = Leader.recompute(state, [:b@h, :c@h])
      assert next.leader == :b@h
      assert next.members == [:b@h, :c@h]
      refute changed?
    end

    test "dedupes membership" do
      state = %Leader{self_node: :a@h, leader: nil, members: []}
      {next, _} = Leader.recompute(state, [:a@h, :a@h, :b@h])
      assert next.members == [:a@h, :b@h]
    end
  end

  describe "leader?/0 and leader/0 — single node" do
    test "leader?/0 is trivially true with clustering disabled, touching no process" do
      Application.put_env(:jido_claw, :cluster_enabled, false)
      assert GenServer.whereis(Leader) == nil

      assert Leader.leader?() == true
      # Façade delegates to the real module (no stub installed).
      assert Cluster.leader?() == true
    end

    test "leader/0 returns the local node with clustering disabled" do
      Application.put_env(:jido_claw, :cluster_enabled, false)
      assert Leader.leader() == Cluster.local_node()
      # Façade delegates to the real module (no stub installed).
      assert Cluster.leader() == Cluster.local_node()
    end
  end

  describe "leader?/0 — fail closed" do
    test "returns false when clustered but the Leader process is absent" do
      Application.put_env(:jido_claw, :cluster_enabled, true)
      assert GenServer.whereis(Leader) == nil

      assert Leader.leader?() == false
      assert Leader.leader() == nil
      # The Cluster.leader/0 façade is also nil (indeterminate leadership).
      assert Cluster.leader() == nil
    end
  end

  describe "Cluster.leader/0 façade — seam" do
    test "delegates to the configured :cluster_leader_module" do
      Application.put_env(:jido_claw, :cluster_leader_module, JidoClaw.ClusterLeaderStub)
      Application.put_env(:jido_claw, :cluster_leader_stub_node, :owner@elsewhere)

      on_exit(fn -> Application.delete_env(:jido_claw, :cluster_leader_stub_node) end)

      assert Cluster.leader() == :owner@elsewhere
    end
  end

  describe ":pg membership wiring" do
    setup do
      start_pg_scope()
      Application.put_env(:jido_claw, :cluster_enabled, true)
      :ok
    end

    test "joins the leader group on init and resolves leadership on a single BEAM" do
      pid = start_supervised!(Leader)

      # Joined the well-known group.
      assert pid in Cluster.members(@group)

      # Single BEAM ⇒ the only member is the local node ⇒ it is the leader.
      assert Cluster.leader?() == true
      assert Leader.leader() == Cluster.local_node()

      # Survives a real join/leave of another member without crashing (leader
      # stays the local node — same node).
      other = spawn(fn -> Process.sleep(:infinity) end)
      Cluster.join(@group, other)
      Cluster.leave(@group, other)
      _ = :sys.get_state(pid)

      assert Process.alive?(pid)
      assert Cluster.leader?() == true
    end
  end

  describe "leader_changed telemetry (members_fun DI seam)" do
    setup do
      start_pg_scope()
      Application.put_env(:jido_claw, :cluster_enabled, true)

      # The Leader reads membership through this Agent so the test can flip it
      # between handle_info calls without touching real :pg membership.
      agent = start_supervised!(%{id: :members, start: {Agent, :start_link, [fn -> [] end]}})
      members_fun = fn -> Agent.get(agent, & &1) end

      test_pid = self()
      handler_id = "leader-changed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_claw, :cluster, :leader_changed],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:leader_changed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, agent: agent, members_fun: members_fun}
    end

    test "fires once when a membership change flips the leader, not otherwise", ctx do
      %{agent: agent, members_fun: members_fun} = ctx

      Agent.update(agent, fn _ -> [:b@h, :z@h] end)
      pid = start_supervised!({Leader, [members_fun: members_fun]})

      %Leader{ref: ref, leader: :b@h} = :sys.get_state(pid)

      # :b@h leaves → leader moves :b@h -> :z@h → telemetry fires once.
      Agent.update(agent, fn _ -> [:z@h] end)
      send(pid, {ref, :leave, @group, []})
      _ = :sys.get_state(pid)

      assert_receive {:leader_changed, %{count: 1}, %{leader: :z@h, previous: :b@h}}, 500

      # Membership grows but the leader (:z@h is still lowest) doesn't move →
      # no telemetry.
      Agent.update(agent, fn _ -> [:z@h, :zz@h] end)
      send(pid, {ref, :join, @group, []})
      _ = :sys.get_state(pid)

      refute_received {:leader_changed, _, _}
    end
  end

  describe "restart coupling under :rest_for_one" do
    setup do
      Application.put_env(:jido_claw, :cluster_enabled, true)
      :ok
    end

    test "killing :pg restarts both (in order); killing the Leader restarts only it" do
      children = [
        %{id: :pg_leader_test, start: {:pg, :start_link, [:jido_claw]}},
        Leader
      ]

      sup =
        start_supervised!(%{
          id: :leadership_test_sup,
          start:
            {Supervisor, :start_link,
             [children, [strategy: :rest_for_one, max_restarts: 10, max_seconds: 5]]},
          type: :supervisor
        })

      pg1 = Process.whereis(:jido_claw)
      leader1 = Process.whereis(Leader)
      assert is_pid(pg1) and is_pid(leader1)
      assert Cluster.leader?() == true

      # Kill the :pg scope → rest_for_one restarts :pg AND the Leader after it.
      Process.exit(pg1, :kill)

      pg2 = wait_for_new_pid(:jido_claw, pg1)
      leader2 = wait_for_new_pid(Leader, leader1)
      # Fresh init re-joined + re-monitored: leadership still resolves, no stale
      # ref against the dead scope.
      assert Cluster.leader?() == true
      assert leader2 in Cluster.members(@group)

      # Kill ONLY the Leader → only the Leader restarts; :pg is untouched.
      Process.exit(leader2, :kill)
      leader3 = wait_for_new_pid(Leader, leader2)

      assert leader3 != leader2
      assert Process.whereis(:jido_claw) == pg2
      assert Cluster.leader?() == true

      # Quiet the unused binding warning while documenting the supervisor seam.
      assert is_pid(sup)
    end
  end
end
