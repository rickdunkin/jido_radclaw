defmodule JidoClaw.Tools.ReplayWorkflowTest do
  @moduledoc """
  The MCP replay surface: a happy-path replay through the tool envelope, the
  refusal→error-string mapping, the deliberate absence of override params
  (the gate philosophy — overrides are dashboard-only), and an MCP-dispatch-
  shaped request proving string-keyed `%{"run_id" => _}` arguments atomize
  through the anubis patch path.
  """
  use JidoClaw.TenantCase, async: false

  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Tools, as: ToolsHandler
  alias Anubis.Server.Response
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Tools.ReplayWorkflow

  @fixture_name "replay_fixture"

  @fixture_yaml """
  name: replay_fixture
  description: replay fixture skill
  steps:
    - name: only
      template: researcher
      task: "do the thing"
  synthesis: done
  """

  setup do
    tenant = seed_tenant("replay-tool")
    Application.put_env(:jido_claw, :echo_stub_target, self())

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "researcher" => %{module: EchoStub, description: "stub", model: :fast, max_iterations: 1}
    })

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
    end)

    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "run/2" do
    test "happy path replays a terminal run and reports the new run", ctx do
      original = launch_fixture!(ctx)

      assert {:ok, output} =
               ReplayWorkflow.run(%{run_id: original.id}, tool_ctx(ctx))

      assert output.retry_of_id == original.id
      assert output.status == "completed"
      assert output.name == original.name
      refute output.new_run_id == original.id
      assert output.message =~ output.new_run_id
    end

    test "a refusal maps to a clear error string (unknown run)", ctx do
      assert {:error, %{message: message}} =
               ReplayWorkflow.run(%{run_id: Ash.UUID.generate()}, tool_ctx(ctx))

      assert message =~ "not found"
    end

    test "a definition change refuses, points at the dashboard, and carries diagnostics", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(ctx, dir)

      write_fixture!(dir, String.replace(@fixture_yaml, "do the thing", "do something else"))

      # The refusal envelope is additive: the plain-English message stays, with
      # the preflight diagnostics attached at details.diagnostics. The envelope
      # keys are atoms; everything inside to_mcp_map/1 is string-keyed.
      assert {:error, %{message: message, details: %{diagnostics: diagnostics}}} =
               ReplayWorkflow.run(%{run_id: original.id}, tool_ctx(ctx))

      assert message =~ "definition changed"
      assert message =~ "dashboard-only"
      assert diagnostics["definition"]["status"] == "changed"
      refute diagnostics["preflight_clear?"]
    end

    test "an irreversible-steps refusal carries diagnostics", ctx do
      dir = tmp_project_dir!()

      write_fixture!(dir, """
      name: replay_fixture
      description: irreversible fixture
      steps:
        - name: only
          template: researcher
          task: "do the thing"
          irreversible: true
      synthesis: done
      """)

      original = launch_fixture!(ctx, dir)

      assert {:error, %{message: message, details: %{diagnostics: diagnostics}}} =
               ReplayWorkflow.run(%{run_id: original.id}, tool_ctx(ctx))

      assert message =~ "irreversible steps"
      assert message =~ "dashboard-only"
      assert diagnostics["irreversible_executed?"] == true
      assert "irreversible_steps_executed" in Enum.map(diagnostics["blockers"], & &1["code"])
    end

    test "missing tenant in tool context fails cleanly" do
      assert {:error, %{message: message}} =
               ReplayWorkflow.run(%{run_id: Ash.UUID.generate()}, %{tool_context: %{}})

      assert message =~ "no tenant"
    end
  end

  describe "schema (gate philosophy)" do
    test "exposes run_id ONLY — no force / allow_irreversible override params" do
      assert Keyword.keys(ReplayWorkflow.schema()) == [:run_id]
    end
  end

  describe "MCP dispatch (anubis patch path)" do
    defmodule StubServer do
      @moduledoc false

      @spec __components__(atom()) :: list()
      def __components__(:tool), do: []
      def __components__(_other), do: []

      @spec handle_tool_call(term(), term(), term()) :: {:reply, term(), term()}
      def handle_tool_call(name, params, frame) do
        send(Map.fetch!(frame.assigns, :test_pid), {:called, name, params})
        {:reply, %Response{type: :tool, content: [], isError: false}, frame}
      end
    end

    test "string-keyed run_id arguments atomize through the patch before dispatch" do
      # Mimic jido_mcp's registration: a JSON-Schema-shaped descriptor whose
      # Peri validation crashes — the patch must rescue AND atomize.
      tool = %Tool{
        name: "replay_workflow",
        task_support: :optional,
        validate_input: fn _params -> raise "Peri-incompatible JSON-Schema descriptor" end
      }

      frame = %Frame{
        tools: %{"replay_workflow" => tool},
        assigns: %{test_pid: self()},
        context: %Context{}
      }

      run_id = Ash.UUID.generate()

      request = %{
        "params" => %{
          "name" => "replay_workflow",
          "arguments" => %{"run_id" => run_id}
        }
      }

      assert {:reply, _payload, _frame} =
               ToolsHandler.handle_call(request, frame, StubServer)

      # `:run_id` was interned at compile by the tool schema literal, so the
      # patch's String.to_existing_atom atomization hands Jido the atom-keyed
      # params its actions pattern-match on.
      assert_received {:called, "replay_workflow", %{run_id: ^run_id}}
    end
  end

  # -- Helpers --

  defp tool_ctx(%{tenant: tenant, actor: actor}),
    do: %{tool_context: %{tenant_id: tenant, actor: actor}}

  defp tmp_project_dir! do
    dir = Path.join(System.tmp_dir!(), "replay_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, ".jido", "skills"]))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_fixture!(dir, yaml \\ @fixture_yaml) do
    File.write!(Path.join([dir, ".jido", "skills", "fixture.yaml"]), yaml)
  end

  defp launch_fixture!(ctx, dir \\ nil) do
    dir = dir || tap(tmp_project_dir!(), &write_fixture!/1)
    {:ok, skill} = Skills.load_skill(@fixture_name, dir)
    {:ok, reactor} = Compiler.compile(skill)

    assert {:ok, _value, run} =
             ReactorRunner.run(reactor, %{extra_context: ""},
               tenant: ctx.tenant,
               actor: ctx.actor,
               name: skill.name,
               async?: true,
               definition_hash: DefinitionFingerprint.for_skill(skill),
               context: %{project_dir: dir}
             )

    assert run.status == :completed
    run
  end
end
