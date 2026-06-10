defmodule JidoClaw.AgentTrackerTest do
  use ExUnit.Case, async: false

  alias JidoClaw.AgentTracker
  alias JidoClaw.Tools.{GetAgentResult, KillAgent, SendToAgent}

  @tenant_id "tenant-agent-tracker-test"

  defmodule FakeRuntime do
    @moduledoc false

    # Record-only: never kills the target, so tests control pid lifetime.
    @spec stop_agent(pid() | String.t()) :: :ok
    def stop_agent(target) do
      case Application.get_env(:jido_claw, :agent_tracker_test_pid) do
        pid when is_pid(pid) -> send(pid, {:stop_agent, target})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule ExpiredRuntime do
    @moduledoc false

    # The runtime view after a sweep stopped the child: no registry entry.
    @spec whereis(String.t()) :: nil
    def whereis(_agent_id), do: nil

    @spec stop_agent(pid() | String.t()) :: {:error, :not_found}
    def stop_agent(_target), do: {:error, :not_found}
  end

  setup do
    old_ttl = Application.get_env(:jido_claw, :agent_tracker_terminal_ttl_ms)
    old_retry = Application.get_env(:jido_claw, :agent_tracker_stop_retry_ms)
    old_runtime = Application.get_env(:jido_claw, :jido_runtime)
    old_test_pid = Application.get_env(:jido_claw, :agent_tracker_test_pid)

    AgentTracker.reset()
    drain()

    on_exit(fn ->
      restore_env(:agent_tracker_terminal_ttl_ms, old_ttl)
      restore_env(:agent_tracker_stop_retry_ms, old_retry)
      restore_env(:jido_runtime, old_runtime)
      restore_env(:agent_tracker_test_pid, old_test_pid)
      AgentTracker.reset()
    end)
  end

  describe "child_count/1" do
    test "counts only :running children; terminal entries remain visible" do
      running = live_pid()
      finished = live_pid()

      assert :ok = AgentTracker.register("runner", running, "coder", "t1", tenant_id: @tenant_id)
      assert :ok = AgentTracker.register("done-1", finished, "coder", "t2", tenant_id: @tenant_id)
      AgentTracker.mark_complete("done-1", :done)
      drain()

      assert AgentTracker.child_count(tenant_id: @tenant_id) == 1

      state = AgentTracker.get_state(tenant_id: @tenant_id)
      assert %{status: :running} = state.agents["runner"]
      assert %{status: :done} = state.agents["done-1"]
      assert Enum.sort(state.order) == ["done-1", "runner"]

      Process.exit(running, :kill)
      Process.exit(finished, :kill)
    end

    test "\"main\" never counts toward the child cap" do
      pid = live_pid()
      assert :ok = AgentTracker.register("main", pid, "main", nil, tenant_id: @tenant_id)

      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

      Process.exit(pid, :kill)
    end
  end

  describe "terminal transitions" do
    test ":DOWN on a running agent marks it :error" do
      pid = live_pid()
      assert :ok = AgentTracker.register("crasher", pid, "coder", "t", tenant_id: @tenant_id)

      kill_and_wait(pid)

      assert %{status: :error, error: error} = AgentTracker.get_agent("crasher")
      assert error =~ "killed"
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test ":DOWN preserves an earlier :done (no clobber to :error)" do
      pid = live_pid()
      assert :ok = AgentTracker.register("finisher", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("finisher", :done)
      drain()

      assert %{finished_at: finished_at} = AgentTracker.get_agent("finisher")

      kill_and_wait(pid)

      assert %{status: :done, finished_at: ^finished_at, error: nil} =
               AgentTracker.get_agent("finisher")
    end

    test "mark_complete(:done) after a :DOWN-marked :error does not clobber" do
      pid = live_pid()
      assert :ok = AgentTracker.register("late-done", pid, "coder", "t", tenant_id: @tenant_id)
      kill_and_wait(pid)

      AgentTracker.mark_complete("late-done", :done)
      drain()

      assert %{status: :error} = AgentTracker.get_agent("late-done")
    end
  end

  describe "mark_running/2" do
    test "re-activates a live terminal entry with a matching pid" do
      pid = live_pid()
      assert :ok = AgentTracker.register("revive", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("revive", :done)
      drain()
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

      assert :ok = AgentTracker.mark_running("revive", pid)

      assert %{status: :running, finished_at: nil, error: nil} = AgentTracker.get_agent("revive")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 1

      Process.exit(pid, :kill)
    end

    test "is a no-op :ok for an already-running entry with a matching live pid" do
      pid = live_pid()
      assert :ok = AgentTracker.register("already", pid, "coder", "t", tenant_id: @tenant_id)

      assert :ok = AgentTracker.mark_running("already", pid)
      assert %{status: :running} = AgentTracker.get_agent("already")

      Process.exit(pid, :kill)
    end

    test "refuses a dead-pid terminal entry without mutating it" do
      pid = live_pid()
      assert :ok = AgentTracker.register("deceased", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("deceased", :done)
      drain()
      kill_and_wait(pid)

      assert {:error, :not_found} = AgentTracker.mark_running("deceased", pid)
      assert %{status: :done} = AgentTracker.get_agent("deceased")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "refuses a mismatched expected_pid without mutating the entry" do
      pid = live_pid()
      other = live_pid()
      assert :ok = AgentTracker.register("mismatch", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("mismatch", :done)
      drain()

      assert {:error, :not_found} = AgentTracker.mark_running("mismatch", other)
      assert %{status: :done} = AgentTracker.get_agent("mismatch")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

      Process.exit(pid, :kill)
      Process.exit(other, :kill)
    end

    test "refuses a missing id" do
      assert {:error, :not_found} = AgentTracker.mark_running("never-was", self())
    end

    test "a re-activated entry self-heals to :error when its pid dies" do
      pid = live_pid()
      assert :ok = AgentTracker.register("self-heal", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("self-heal", :done)
      drain()
      assert :ok = AgentTracker.mark_running("self-heal", pid)

      kill_and_wait(pid)

      assert %{status: :error} = AgentTracker.get_agent("self-heal")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end
  end

  describe "terminal TTL sweep" do
    setup do
      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
      Application.put_env(:jido_claw, :agent_tracker_test_pid, self())
      Application.put_env(:jido_claw, :agent_tracker_terminal_ttl_ms, 0)
      Application.put_env(:jido_claw, :agent_tracker_stop_retry_ms, 300_000)
      :ok
    end

    test "evicts expired terminal entries once their pids are dead" do
      pid = live_pid()
      assert :ok = AgentTracker.register("expired", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("expired", :done)
      drain()
      kill_and_wait(pid)

      sweep()

      assert AgentTracker.get_agent("expired") == nil
      state = AgentTracker.get_state()
      refute Map.has_key?(state.agents, "expired")
      refute "expired" in state.order
      refute_receive {:stop_agent, _}
      assert Process.alive?(Process.whereis(AgentTracker))
    end

    test "running entries and \"main\" survive an expired sweep" do
      running = live_pid()
      main = live_pid()

      assert :ok = AgentTracker.register("runner", running, "coder", "t", tenant_id: @tenant_id)
      assert :ok = AgentTracker.register("main", main, "main", nil, tenant_id: @tenant_id)
      AgentTracker.mark_complete("main", :done)
      drain()
      kill_and_wait(main)

      sweep()

      assert %{status: :running} = AgentTracker.get_agent("runner")
      assert %{status: :done} = AgentTracker.get_agent("main")
      refute_receive {:stop_agent, _}

      Process.exit(running, :kill)
    end

    test "fresh terminal entries survive a sweep within the TTL" do
      Application.put_env(:jido_claw, :agent_tracker_terminal_ttl_ms, 1_800_000)

      pid = live_pid()
      assert :ok = AgentTracker.register("fresh", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("fresh", :done)
      drain()
      kill_and_wait(pid)

      sweep()

      assert %{status: :done} = AgentTracker.get_agent("fresh")
    end

    test "stops a live expired entry by pid, deduplicates, then evicts once dead" do
      pid = live_pid()
      assert :ok = AgentTracker.register("idle", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("idle", :done)
      drain()

      sweep()

      # Stop is requested with the monitored pid (not the id) and the entry
      # is retained — an agent is never invisible while its pid is alive.
      assert_receive {:stop_agent, ^pid}, 1_000
      assert %{status: :done} = AgentTracker.get_agent("idle")

      # A second sweep inside the retry threshold does not re-request.
      sweep()
      refute_receive {:stop_agent, _}

      # Once the pid dies, the next sweep evicts.
      kill_and_wait(pid)
      sweep()
      assert AgentTracker.get_agent("idle") == nil
    end

    test "does not stop an entry re-activated via mark_running" do
      pid = live_pid()
      assert :ok = AgentTracker.register("reused", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("reused", :done)
      drain()
      assert :ok = AgentTracker.mark_running("reused", pid)

      sweep()

      refute_receive {:stop_agent, _}
      assert %{status: :running} = AgentTracker.get_agent("reused")

      Process.exit(pid, :kill)
    end
  end

  describe "TTL expiry — public tool behavior" do
    setup do
      Application.put_env(:jido_claw, :jido_runtime, ExpiredRuntime)
      :ok
    end

    test "stopped-but-not-yet-evicted: tools read not_found and never resurrect the entry" do
      pid = live_pid()

      assert :ok =
               AgentTracker.register("expired_tool", pid, "coder", "t", tenant_id: @tenant_id)

      AgentTracker.mark_complete("expired_tool", :done)
      drain()
      kill_and_wait(pid)

      assert {:error, %{details: %{reason: :not_found}}} =
               SendToAgent.run(%{agent_id: "expired_tool", message: "hi"}, tool_ctx())

      assert {:error, %{details: %{reason: :not_found}}} =
               GetAgentResult.run(%{agent_id: "expired_tool"}, tool_ctx())

      assert {:error, %{details: %{reason: :not_found}}} =
               KillAgent.run(%{agent_id: "expired_tool"}, tool_ctx())

      # The resurrection-race assertion: a tool touching an expired agent
      # must leave the entry terminal and the spawn cap untouched.
      assert %{status: :done} = AgentTracker.get_agent("expired_tool")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "after eviction: all three tools read not_found via scoped_agent" do
      pid = live_pid()
      assert :ok = AgentTracker.register("gone_tool", pid, "coder", "t", tenant_id: @tenant_id)
      AgentTracker.mark_complete("gone_tool", :done)
      drain()
      kill_and_wait(pid)

      # Expire just for the manual sweep, then restore so a timer-fired sweep
      # can't interfere with the assertions below.
      Application.put_env(:jido_claw, :agent_tracker_terminal_ttl_ms, 0)
      sweep()
      Application.put_env(:jido_claw, :agent_tracker_terminal_ttl_ms, 1_800_000)
      assert AgentTracker.get_agent("gone_tool") == nil

      assert {:error, %{details: %{reason: :not_found}}} =
               SendToAgent.run(%{agent_id: "gone_tool", message: "hi"}, tool_ctx())

      assert {:error, %{details: %{reason: :not_found}}} =
               GetAgentResult.run(%{agent_id: "gone_tool"}, tool_ctx())

      assert {:error, %{details: %{reason: :not_found}}} =
               KillAgent.run(%{agent_id: "gone_tool"}, tool_ctx())
    end
  end

  defp tool_ctx, do: %{tool_context: %{tenant_id: @tenant_id}}

  defp live_pid, do: spawn(fn -> Process.sleep(:infinity) end)

  # GenServer.call barrier: everything already in the tracker mailbox
  # (casts, :DOWNs, manual sweep sends) is processed before this returns.
  defp drain, do: _ = AgentTracker.get_state()

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    drain()
  end

  defp sweep do
    send(AgentTracker, :sweep_terminal)
    drain()
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
