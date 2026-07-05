defmodule JidoClaw.Tools.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Templates
  alias JidoClaw.AgentTracker
  alias JidoClaw.Tools.SpawnAgent

  @tenant_id "tenant-spawn-agent-test"

  defmodule FakeRuntime do
    # The tool spawns children via start_subagent/2 (`:temporary` in the real
    # runtime); the message keeps the :start_agent tag for the assertions.
    @spec start_subagent(module(), keyword()) :: {:ok, pid()}
    def start_subagent(_module, opts) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(Application.fetch_env!(:jido_claw, :spawn_agent_test_pid), {:start_agent, opts, pid})
      {:ok, pid}
    end

    # Record-only: never kills the target, so tests control pid lifetime
    # (the AgentTrackerTest.FakeRuntime convention).
    @spec stop_agent(pid() | String.t()) :: :ok
    def stop_agent(target) do
      send(Application.fetch_env!(:jido_claw, :spawn_agent_test_pid), {:stop_agent, target})
      :ok
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

  defmodule TakenTracker do
    # The narrowest tracker that drives register_spawned_agent into its
    # :agent_id_taken branch. The generated-id path skips
    # ensure_agent_id_available, so only these two callbacks are reached.
    @spec child_count(keyword()) :: 0
    def child_count(_opts), do: 0

    @spec register(String.t(), pid(), term(), term(), keyword()) :: {:error, :agent_id_taken}
    def register(_id, _pid, _template, _task, _opts), do: {:error, :agent_id_taken}

    # Straggler absorbers: orchestration tasks from earlier tests can
    # outlive their test (parked on the Recorder flush) and read the
    # swapped-in tracker late — absorb their writes instead of crashing.
    @spec attach_orchestrator(String.t(), pid()) :: :ok
    def attach_orchestrator(_id, _pid), do: :ok

    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_id, _status), do: :ok
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

  # A provider that resolves the canonically-PUBLIC "coder" name to a
  # composer-private template — the AR-8c divergence the resolved-map guard must
  # catch (the name-based guard reads canonical "coder" as public, so it would
  # spawn). Carries :description so the *pre-fix* spawn-success path doesn't
  # KeyError before the receive-and-kill below can prove (and clean up) the leak.
  defmodule DivergentTemplates do
    @spec get(String.t()) :: {:ok, map()}
    def get("coder") do
      {:ok,
       %{
         module: JidoClaw.Tools.SpawnAgentTest.FakeWorker,
         description: "divergent private coder",
         composer_private: true
       }}
    end
  end

  defmodule FakeWorker do
    alias JidoClaw.Test.TerminalSignal

    @spec ask_sync(pid(), String.t(), keyword()) :: :ok
    def ask_sync(pid, task, opts) do
      send(
        Application.fetch_env!(:jido_claw, :spawn_agent_test_pid),
        {:ask_sync, pid, task, opts}
      )

      TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
      :ok
    end
  end

  defmodule BlockingTemplates do
    @spec get(String.t()) :: {:ok, map()}
    def get("coder") do
      {:ok,
       %{module: JidoClaw.Tools.SpawnAgentTest.BlockingWorker, description: "blocking coder"}}
    end
  end

  defmodule BlockingWorker do
    alias JidoClaw.Test.TerminalSignal

    # Holds the spawn orchestration open until released. `ask_sync` runs
    # inside the supervised orchestration task, so `self()` here IS the
    # orchestrator pid — the test uses it to kill the task mid-flight.
    @spec ask_sync(pid(), String.t(), keyword()) :: :ok
    def ask_sync(_pid, task, opts) do
      test_pid = Application.fetch_env!(:jido_claw, :spawn_agent_test_pid)
      send(test_pid, {:ask_sync_started, self(), task})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
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
    old_agent_tracker = Application.get_env(:jido_claw, :agent_tracker)
    old_task_supervisor = Application.get_env(:jido_claw, :task_supervisor)
    old_mcp_facade = Application.get_env(:jido_claw, :mcp_facade)
    old_mcp_target = Application.get_env(:jido_claw, :mcp_facade_capture_target)

    AgentTracker.reset()
    flush_tracker()

    on_exit(fn ->
      restore_env(:spawn_agent_max_children, old_max_children)
      restore_env(:spawn_agent_max_depth, old_max_depth)
      restore_env(:jido_runtime, old_jido_runtime)
      restore_env(:agent_templates, old_agent_templates)
      restore_env(:spawn_agent_busy_ids, old_busy_ids)
      restore_env(:spawn_agent_test_pid, old_test_pid)
      restore_env(:agent_tracker, old_agent_tracker)
      restore_env(:task_supervisor, old_task_supervisor)
      restore_env(:mcp_facade, old_mcp_facade)
      restore_env(:mcp_facade_capture_target, old_mcp_target)
      AgentTracker.reset()
    end)
  end

  test "description and :template doc enumerate exactly the spawnable template set" do
    # Derived at compile time from Templates.spawnable_names/0 — the LLM-facing
    # strings can no longer drift from the registry (post-review fix: the
    # hand-maintained 7-name literals had dropped `fixer`).
    inline = Enum.join(Templates.spawnable_names(), ", ")

    assert SpawnAgent.description() =~ "Available templates: #{inline}."
    assert SpawnAgent.schema()[:template][:doc] =~ "(#{inline})"
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

  test "refuses to spawn the composer-private sketch_build template (AR-8b)" do
    # Real Templates (default seam) so `sketch_build` resolves to the genuine
    # sandboxed template; FakeRuntime records any spawn so we can prove none happened.
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)

    assert {:error, wire} = SpawnAgent.run(%{template: "sketch_build", task: "x"}, ctx())
    assert wire.code == :execution_error
    assert wire.details.reason == :composer_private
    assert wire.details.template == "sketch_build"

    # The guard fires before any runtime spawn or tracker registration.
    refute_receive {:start_agent, _opts, _pid}
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
  end

  test "refuses to spawn a composer-private :docker template too (AR-8b-2 F2)" do
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)

    override = %{"docker_stub" => %{module: JidoClaw.Agent.Workers.Coder, sandbox: :docker}}
    Application.put_env(:jido_claw, :agent_templates_override, override)
    on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

    assert {:error, wire} = SpawnAgent.run(%{template: "docker_stub", task: "x"}, ctx())
    assert wire.details.reason == :composer_private
    assert wire.details.template == "docker_stub"

    refute_receive {:start_agent, _opts, _pid}
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
  end

  test "refuses to spawn the REAL sketch_build_exec template (AR-8b-2 F2, :docker)" do
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)

    assert {:error, wire} = SpawnAgent.run(%{template: "sketch_build_exec", task: "x"}, ctx())
    assert wire.details.reason == :composer_private
    assert wire.details.template == "sketch_build_exec"

    refute_receive {:start_agent, _opts, _pid}
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
  end

  # AR-8c: the system workers are `sandbox: :none` (they run on the real
  # machine) but composer-private via the explicit flag — the LLM swarm tool
  # must still refuse them, so the safety gate cannot be bypassed.
  for template <- ~w[system_executor system_verifier] do
    test "refuses to spawn the composer-private #{template} template (AR-8c, :none + flag)" do
      Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)
      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
      Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
      Application.put_env(:jido_claw, :spawn_agent_max_children, 10)

      assert {:error, wire} = SpawnAgent.run(%{template: unquote(template), task: "x"}, ctx())
      assert wire.details.reason == :composer_private
      assert wire.details.template == unquote(template)

      refute_receive {:start_agent, _opts, _pid}
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end
  end

  test "refuses a spawn when a divergent provider resolves a public name to a private template (AR-8c review fix)" do
    # The bypass AR-8c's review fix closes: :agent_templates points at a provider
    # that resolves canonically-PUBLIC "coder" to a composer-private template. The
    # name-based guard reads canonical "coder" (public) and would spawn; the
    # resolved-map guard reads what the provider actually returned (private) and
    # refuses — guard and launch now read the identical object, so they can't diverge.
    Application.put_env(:jido_claw, :agent_templates, DivergentTemplates)
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :spawn_agent_test_pid, self())
    Application.put_env(:jido_claw, :spawn_agent_max_children, 10)

    result = SpawnAgent.run(%{template: "coder", task: "x"}, ctx())

    # Pre-fix the name-based guard passes "coder" and FakeRuntime spawns a
    # Process.sleep(:infinity) pid. Receive-and-kill (not a bare refute_receive)
    # so a pre-fix run cleans up the pid it just proved was wrongly spawned rather
    # than leaking it. Post-fix the resolved-map guard fires before start_subagent,
    # so nothing arrives and the after-clause passes cleanly.
    receive do
      {:start_agent, _opts, pid} ->
        Process.exit(pid, :kill)
        flunk("composer-private template was spawned despite the resolved-map guard")
    after
      200 -> :ok
    end

    assert {:error, wire} = result
    assert wire.code == :execution_error
    assert wire.details.reason == :composer_private
    assert wire.details.template == "coder"
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
  end

  test "terminal children do not consume the spawn cap (H10 regression)" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :spawn_agent_max_children, 1)

    done_pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             AgentTracker.register("coder_done", done_pid, "coder", "finished task",
               tenant_id: @tenant_id
             )

    AgentTracker.mark_complete("coder_done", :done)
    flush_tracker()

    # The cap is a concurrency limit: a completed child must not block the
    # next spawn in the same scope.
    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert_receive {:start_agent, [id: ^agent_id], pid}

    Process.exit(pid, :kill)
    Process.exit(done_pid, :kill)
  end

  test "a killed orchestration task forces the entry terminal and frees the cap (M17 regression)" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "long haul"}, ctx())

    assert_receive {:start_agent, [id: ^agent_id], agent_pid}
    assert_receive {:ask_sync_started, task_pid, "long haul"}, 1_000

    # In flight: the entry consumes the cap and the agent process is alive.
    assert %{status: :running} = AgentTracker.get_agent(agent_id, tenant_id: @tenant_id)
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 1

    # Kill the orchestrator (uncatchable — the task's try/catch never runs).
    # The tracker's orchestrator monitor must force the entry terminal even
    # though the agent process itself stays alive the whole time.
    Process.exit(task_pid, :kill)

    wait_until(fn ->
      match?(%{status: :error}, AgentTracker.get_agent(agent_id, tenant_id: @tenant_id))
    end)

    assert %{error: error} = AgentTracker.get_agent(agent_id, tenant_id: @tenant_id)
    assert error =~ "orchestrator died"
    assert Process.alive?(agent_pid)
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

    Process.exit(agent_pid, :kill)
  end

  test "reclaims the started sub-agent when registration is taken (P2-2 regression)" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :agent_tracker, TakenTracker)

    # No tag → the availability pre-check is skipped, so the race lands on
    # register, after the sub-agent has already started.
    assert {:error, %{code: :validation_error, details: details}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert details.reason == :agent_id_taken

    # The taken branch must reclaim the started sub-agent: untracked agents
    # are invisible to the TTL sweep and would otherwise leak alive forever.
    assert_receive {:start_agent, _opts, started_pid}
    assert_receive {:stop_agent, ^started_pid}
    refute_receive {:ask_sync, _, _, _}

    Process.exit(started_pid, :kill)
  end

  test "a start_child failure forces the entry terminal and reclaims the sub-agent" do
    configure_fake_spawn()

    start_supervised!({Task.Supervisor, name: __MODULE__.CrampedTaskSup, max_children: 0})
    Application.put_env(:jido_claw, :task_supervisor, __MODULE__.CrampedTaskSup)

    assert {:error, %{code: :execution_error, details: %{phase: :spawn}}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert_receive {:start_agent, [id: agent_id], started_pid}
    assert_receive {:stop_agent, ^started_pid}
    flush_tracker()

    # No orchestration ever ran behind the registered entry: it must be
    # terminal and the cap free.
    assert %{status: :error} = AgentTracker.get_agent(agent_id, tenant_id: @tenant_id)
    assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

    Process.exit(started_pid, :kill)
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

  test "ensure_attaches the spawning template's external MCP tools onto the sub-agent" do
    configure_fake_spawn()
    Application.put_env(:jido_claw, :mcp_facade, JidoClaw.Test.MCPFacadeCapture)
    Application.put_env(:jido_claw, :mcp_facade_capture_target, self())

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, ctx())

    assert_receive {:start_agent, [id: ^agent_id], pid}

    # The orchestration task bounds-attaches the sub-agent under its template
    # before running the turn (workers previously got zero external tools).
    assert_receive {:mcp_ensure_attached, ^pid, "coder", 8_000}, 2_000

    Process.exit(pid, :kill)
  end

  test "sets :agent_template on the child tool_context (per-template approval policy)" do
    configure_fake_spawn()

    tool_context = %{tenant_id: @tenant_id, session_id: "s"}

    assert {:ok, %{agent_id: agent_id}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: tool_context})

    assert_receive {:start_agent, [id: ^agent_id], pid}
    assert_receive {:ask_sync, ^pid, "do work", opts}

    # child/3 nulls it; the tool restores it to the spawning template so the
    # gate (and durable compaction identity) see the template.
    assert opts[:tool_context].agent_template == "coder"

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

  @tag :capture_log
  test "wires AR-5 doctrine injection onto the spawned sub-agent (real runtime)" do
    # Real runtime + real Templates (NOT configure_fake_spawn's sleeping pid):
    # only a pid that actually handles the ReAct set_system_prompt signal proves
    # the seam. No session_uuid → the orchestration's correlation goes cache-only
    # and its transcript writes hit do_append's no-op clause, so the detached Task
    # touches no DB (no sandbox to tear down under it). The flag is OFF globally,
    # so a deleted call would make this never fire — that's the point.
    original = Application.get_env(:jido_claw, :doctrine)
    Application.put_env(:jido_claw, :doctrine, enabled?: true)

    handler_id = "ar5-spawn-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:jido_claw, :agent, :prompt_injected],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:injected, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case original do
        nil -> Application.delete_env(:jido_claw, :doctrine)
        val -> Application.put_env(:jido_claw, :doctrine, val)
      end
    end)

    tool_context = %{tenant_id: "tenant-spawn-ar5-#{System.unique_integer([:positive])}"}

    assert {:ok, %{agent_id: _}} =
             SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: tool_context})

    # The orchestration Task injects right after ensure_attached (spawn_agent.ex),
    # before its first SubagentTranscript.run.
    assert_receive {:injected, metadata}, 10_000
    assert metadata.source == :doctrine
    assert metadata.template == "coder"

    if is_pid(metadata.pid), do: JidoClaw.Jido.stop_agent(metadata.pid)
  end

  defp flush_tracker do
    _ = AgentTracker.get_state()
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    wait_until_deadline(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_until_deadline(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        wait_until_deadline(fun, deadline)
    end
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
