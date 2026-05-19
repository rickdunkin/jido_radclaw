defmodule JidoClaw.Tools.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias JidoClaw.AgentTracker
  alias JidoClaw.Tools.SpawnAgent

  defmodule FakeRuntime do
    def start_agent(_module, opts) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(Application.fetch_env!(:jido_claw, :spawn_agent_test_pid), {:start_agent, opts, pid})
      {:ok, pid}
    end

    def whereis(agent_id) do
      if MapSet.member?(
           Application.get_env(:jido_claw, :spawn_agent_busy_ids, MapSet.new()),
           agent_id
         ) do
        self()
      end
    end
  end

  defmodule FakeTemplates do
    def get("coder") do
      {:ok, %{module: JidoClaw.Tools.SpawnAgentTest.FakeWorker, description: "fake coder"}}
    end
  end

  defmodule FakeWorker do
    def ask_sync(pid, task, opts) do
      send(
        Application.fetch_env!(:jido_claw, :spawn_agent_test_pid),
        {:ask_sync, pid, task, opts}
      )

      :ok
    end
  end

  setup do
    old_max_children = Application.get_env(:jido_claw, :spawn_agent_max_children)
    old_max_depth = Application.get_env(:jido_claw, :spawn_agent_max_depth)
    old_jido_runtime = Application.get_env(:jido_claw, :jido_runtime)
    old_agent_templates = Application.get_env(:jido_claw, :agent_templates)
    old_busy_ids = Application.get_env(:jido_claw, :spawn_agent_busy_ids)
    old_test_pid = Application.get_env(:jido_claw, :spawn_agent_test_pid)

    AgentTracker.reset()
    flush_tracker()

    on_exit(fn ->
      restore_env(:spawn_agent_max_children, old_max_children)
      restore_env(:spawn_agent_max_depth, old_max_depth)
      restore_env(:jido_runtime, old_jido_runtime)
      restore_env(:agent_templates, old_agent_templates)
      restore_env(:spawn_agent_busy_ids, old_busy_ids)
      restore_env(:spawn_agent_test_pid, old_test_pid)
      AgentTracker.reset()
    end)
  end

  test "rejects spawning when the child cap is reached" do
    Application.put_env(:jido_claw, :spawn_agent_max_children, 0)

    assert {:error, %{code: :max_children, message: "max children", details: %{}}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: %{}})
  end

  test "rejects spawning when swarm depth is reached" do
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)
    Application.put_env(:jido_claw, :spawn_agent_max_depth, 1)

    assert {:error, %{code: :max_depth, message: "max depth", details: %{}}} =
             SpawnAgent.run(
               %{template: "coder", task: "do work"},
               %{tool_context: %{swarm_depth: 1}}
             )
  end

  test "generated IDs are UUID-based and registered without collisions" do
    configure_fake_spawn()

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: %{}})

    assert agent_id =~
             ~r/^coder_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    assert_receive {:start_agent, [id: ^agent_id], pid}
    assert_receive {:ask_sync, ^pid, "do work", opts}
    assert opts[:tool_context].agent_id == agent_id

    assert %{id: ^agent_id, template: "coder"} = AgentTracker.get_agent(agent_id)
    Process.exit(pid, :kill)
  end

  test "rejects an explicit tag already registered in AgentTracker" do
    configure_fake_spawn()
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = AgentTracker.register("coder_existing", pid, "coder", "existing task")

    assert {:error, %{code: :validation_error, message: message, details: details}} =
             SpawnAgent.run(
               %{template: "coder", task: "do work", tag: "coder_existing"},
               %{tool_context: %{}}
             )

    assert message == "Agent ID 'coder_existing' is already in use."
    assert details.field == :tag
    assert details.value == "coder_existing"
    assert details.reason == :agent_id_taken

    refute_receive {:start_agent, _opts, _pid}
    Process.exit(pid, :kill)
  end

  test "rejects an explicit tag already present in the runtime registry" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :spawn_agent_busy_ids, MapSet.new(["runtime_busy"]))

    assert {:error, %{message: "Agent ID 'runtime_busy' is already in use."}} =
             SpawnAgent.run(
               %{template: "coder", task: "do work", tag: "runtime_busy"},
               %{tool_context: %{}}
             )

    refute_receive {:start_agent, _opts, _pid}
  end

  test "AgentTracker rejects duplicate registrations" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    other_pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = AgentTracker.register("dup", pid, "coder", "first")
    assert {:error, :agent_id_taken} = AgentTracker.register("dup", other_pid, "coder", "second")

    assert %{pid: ^pid, task: "first"} = AgentTracker.get_agent("dup")
    Process.exit(pid, :kill)
    Process.exit(other_pid, :kill)
  end

  defp flush_tracker do
    _ = AgentTracker.get_state()
  end

  defp configure_fake_spawn do
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)
    Application.put_env(:jido_claw, :spawn_agent_max_depth, 1)
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :agent_templates, FakeTemplates)
    Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
