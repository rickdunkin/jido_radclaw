defmodule JidoClaw.SwarmViewTest do
  use ExUnit.Case, async: false

  alias JidoClaw.AgentTracker
  alias JidoClaw.SwarmView
  alias JidoClaw.Tools.{KillAgent, ListAgents, SwarmStatus}

  defmodule FakeRuntime do
    @moduledoc false

    def stop_agent(agent_id) do
      send(Application.fetch_env!(:jido_claw, :swarm_view_test_pid), {:stop_agent, agent_id})
      :ok
    end
  end

  setup do
    old_runtime = Application.get_env(:jido_claw, :jido_runtime)
    old_test_pid = Application.get_env(:jido_claw, :swarm_view_test_pid)

    AgentTracker.reset()
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :swarm_view_test_pid, self())

    on_exit(fn ->
      restore_env(:jido_runtime, old_runtime)
      restore_env(:swarm_view_test_pid, old_test_pid)
      AgentTracker.reset()
    end)

    :ok
  end

  test "list/1 and swarm_status expose only the caller tenant's child agents" do
    pid_a = child_pid()
    pid_b = child_pid()

    assert :ok =
             AgentTracker.register("agent-a", pid_a, "coder", "visible",
               tenant_id: "tenant-a",
               session_id: "session-a"
             )

    assert :ok =
             AgentTracker.register("agent-b", pid_b, "reviewer", "hidden",
               tenant_id: "tenant-b",
               session_id: "session-b"
             )

    AgentTracker.track_tokens("agent-a", 42)

    assert {:ok, view} = SwarmView.list(%{tenant_id: "tenant-a"})
    assert Enum.map(view.agents, & &1.agent_id) == ["agent-a"]
    assert view.total_tokens == 42

    assert {:error, :not_found} = SwarmView.snapshot("agent-b", %{tenant_id: "tenant-a"})

    assert {:ok, status} = SwarmStatus.run(%{}, ctx("tenant-a"))
    assert Enum.map(status["agents"], & &1["agent_id"]) == ["agent-a"]
    assert status["total_tokens"] == 42

    assert {:ok, %{count: 1, agents: agents}} = ListAgents.run(%{}, ctx("tenant-a"))
    assert agents =~ "agent-a"
    refute agents =~ "agent-b"

    Process.exit(pid_a, :kill)
    Process.exit(pid_b, :kill)
  end

  test "tenant-scoped kill does not stop a child owned by another tenant" do
    pid = child_pid()

    assert :ok =
             AgentTracker.register("agent-a", pid, "coder", "visible", tenant_id: "tenant-a")

    assert {:error, %{code: :validation_error, details: details}} =
             KillAgent.run(%{agent_id: "agent-a"}, ctx("tenant-b"))

    assert details.reason == :not_found
    refute_receive {:stop_agent, "agent-a"}

    Process.exit(pid, :kill)
  end

  test "kill_agent \"all\" stops only the caller tenant's children" do
    pid_a = child_pid()
    pid_b = child_pid()

    assert :ok = AgentTracker.register("agent-a", pid_a, "coder", "a", tenant_id: "tenant-a")
    assert :ok = AgentTracker.register("agent-b", pid_b, "coder", "b", tenant_id: "tenant-b")

    assert {:ok, %{stopped: 1}} = KillAgent.run(%{agent_id: "all"}, ctx("tenant-a"))

    assert_receive {:stop_agent, "agent-a"}
    refute_receive {:stop_agent, "agent-b"}

    Process.exit(pid_a, :kill)
    Process.exit(pid_b, :kill)
  end

  test "parent scope: an agent acts on its own child but not a sibling subtree" do
    own = child_pid()
    sibling = child_pid()

    # Both children live in the same tenant; only the parent_agent_id differs.
    assert :ok =
             AgentTracker.register("own-child", own, "coder", "mine",
               tenant_id: "tenant-a",
               parent_agent_id: "main"
             )

    assert :ok =
             AgentTracker.register("sibling-child", sibling, "coder", "theirs",
               tenant_id: "tenant-a",
               parent_agent_id: "other-parent"
             )

    # Caller "main" can stop its own child...
    assert {:ok, %{agent_id: "own-child", status: "stopped"}} =
             KillAgent.run(%{agent_id: "own-child"}, ctx("tenant-a", "main"))

    assert_receive {:stop_agent, "own-child"}

    # ...but a sibling subtree (different parent) is not_found for it.
    assert {:error, %{code: :validation_error, details: details}} =
             KillAgent.run(%{agent_id: "sibling-child"}, ctx("tenant-a", "main"))

    assert details.reason == :not_found
    refute_receive {:stop_agent, "sibling-child"}

    Process.exit(own, :kill)
    Process.exit(sibling, :kill)
  end

  test "tenant scope is required" do
    assert {:error, :tenant_required} = SwarmView.list(%{})
    assert {:error, %{code: :tenant_required}} = SwarmStatus.run(%{}, %{tool_context: %{}})
  end

  defp child_pid do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp ctx(tenant_id), do: %{tool_context: %{tenant_id: tenant_id}}

  defp ctx(tenant_id, agent_id),
    do: %{tool_context: %{tenant_id: tenant_id, agent_id: agent_id}}

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
