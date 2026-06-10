defmodule JidoClaw.Tools.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias JidoClaw.AgentTracker
  alias JidoClaw.Tools.SpawnAgent

  @tenant_id "tenant-spawn-agent-test"

  defmodule FakeRuntime do
    @spec start_agent(module(), keyword()) :: {:ok, pid()}
    def start_agent(_module, opts) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(Application.fetch_env!(:jido_claw, :spawn_agent_test_pid), {:start_agent, opts, pid})
      {:ok, pid}
    end

    @spec whereis(String.t()) :: pid() | nil
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
    @spec get(String.t()) :: {:ok, map()}
    def get("coder") do
      {:ok, %{module: JidoClaw.Tools.SpawnAgentTest.FakeWorker, description: "fake coder"}}
    end
  end

  defmodule RestrictedTemplates do
    @spec get(String.t()) :: {:ok, map()}
    def get("coder") do
      {:ok,
       %{
         module: JidoClaw.Tools.SpawnAgentTest.FakeWorker,
         description: "fake coder",
         forward_context: :none
       }}
    end
  end

  defmodule FakeWorker do
    @spec ask_sync(pid(), String.t(), keyword()) :: :ok
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

    assert {:error, wire} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert wire.code == :execution_error
    assert wire.message =~ "Maximum concurrent child agents for this scope reached (0/0)"
    assert wire.details.reason == :max_children
    assert wire.details.limit == 0
    assert wire.details.current == 0
    assert wire.details.phase == :spawn_limit
  end

  test "requires tenant scope before checking spawn limits" do
    Application.put_env(:jido_claw, :spawn_agent_max_children, 0)

    assert {:error, %{code: :tenant_required}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: %{}})
  end

  test "rejects spawning when swarm depth is reached" do
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)
    Application.put_env(:jido_claw, :spawn_agent_max_depth, 1)

    assert {:error, wire} =
             SpawnAgent.run(
               %{template: "coder", task: "do work"},
               ctx(%{swarm_depth: 1})
             )

    assert wire.code == :execution_error
    assert wire.message =~ "Maximum swarm depth reached (1/1)"
    assert wire.details.reason == :max_depth
    assert wire.details.limit == 1
    assert wire.details.depth == 1
    assert wire.details.phase == :spawn_limit
  end

  test "generated IDs are UUID-based and registered without collisions" do
    configure_fake_spawn()

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert agent_id =~
             ~r/^coder_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    assert_receive {:start_agent, [id: ^agent_id], pid}
    assert_receive {:ask_sync, ^pid, "do work", opts}
    assert opts[:tool_context].agent_id == agent_id

    # The tracker entry must carry the same request_id that ask_sync was
    # called with — registration happens AFTER register_child_correlation/1,
    # so get_agent_result can read request-scoped state.
    request_id = opts[:request_id]
    assert is_binary(request_id)

    assert %{id: ^agent_id, template: "coder", request_id: ^request_id} =
             AgentTracker.get_agent(agent_id, tenant_id: @tenant_id)

    Process.exit(pid, :kill)
  end

  test "applies the template's forward_context policy to the child tool_context" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :agent_templates, RestrictedTemplates)

    tool_context = %{
      tenant_id: @tenant_id,
      session_id: "s",
      user_id: "u",
      workspace_uuid: "w",
      actor: %{kind: :system}
    }

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: tool_context})

    assert_receive {:start_agent, [id: ^agent_id], pid}
    assert_receive {:ask_sync, ^pid, "do work", opts}

    child_ctx = opts[:tool_context]
    assert child_ctx.user_id == nil
    assert child_ctx.workspace_uuid == nil
    assert child_ctx.actor == nil
    assert child_ctx.session_id == "s"

    Process.exit(pid, :kill)
  end

  test "default template (no forward_context) forwards the full scope" do
    configure_fake_spawn()

    tool_context = %{tenant_id: @tenant_id, session_id: "s", user_id: "u", workspace_uuid: "w"}

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: tool_context})

    assert_receive {:start_agent, [id: ^agent_id], pid}
    assert_receive {:ask_sync, ^pid, "do work", opts}

    child_ctx = opts[:tool_context]
    assert child_ctx.user_id == "u"
    assert child_ctx.workspace_uuid == "w"
    assert child_ctx.session_id == "s"

    Process.exit(pid, :kill)
  end

  test "rejects an explicit tag already registered in AgentTracker" do
    configure_fake_spawn()
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             AgentTracker.register("coder_existing", pid, "coder", "existing task",
               tenant_id: @tenant_id
             )

    assert {:error, %{code: :validation_error, message: message, details: details}} =
             SpawnAgent.run(
               %{template: "coder", task: "do work", tag: "coder_existing"},
               ctx()
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
               ctx()
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

  test "AgentTracker.register/5 stores request_id when provided" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok =
             AgentTracker.register("with-rid", pid, "coder", "do thing", request_id: request_id)

    assert %{request_id: ^request_id} = AgentTracker.get_agent("with-rid")
    Process.exit(pid, :kill)
  end

  test "AgentTracker.register/4 still works (backwards compat — request_id nil)" do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = AgentTracker.register("no-rid", pid, "coder", "do thing")
    assert %{request_id: nil} = AgentTracker.get_agent("no-rid")
    Process.exit(pid, :kill)
  end

  test "AgentTracker.update_request_id/2 overwrites the stored request_id" do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             AgentTracker.register("upd-rid", pid, "coder", "task", request_id: "rid-1")

    assert :ok = AgentTracker.update_request_id("upd-rid", "rid-2")
    assert %{request_id: "rid-2"} = AgentTracker.get_agent("upd-rid")
    Process.exit(pid, :kill)
  end

  test "AgentTracker.update_request_id/2 is a no-op for unknown agents" do
    assert :ok = AgentTracker.update_request_id("never-registered", "rid-x")
    assert AgentTracker.get_agent("never-registered") == nil
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

  defp ctx(extra \\ %{}) do
    %{tool_context: Map.merge(%{tenant_id: @tenant_id}, extra)}
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
