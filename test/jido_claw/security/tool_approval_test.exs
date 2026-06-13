defmodule JidoClaw.Security.ToolApprovalTest do
  @moduledoc """
  The wrapper-level tool-approval gate: requirement logic (require list + shell
  param-patterns), the pend → approve → execute-once → re-pend loop through the
  shared `Tools.Action` wrapper, deny-once, fail-closed unavailability, and the
  config-sanity coverage sweeps.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Security.ToolApproval

  # Inline victim actions exercise the real wrapper pipeline.
  defmodule Victim do
    use JidoClaw.Tools.Action,
      name: "tool_approval_victim",
      description: "Test-only action gated through the approval wrapper.",
      schema: []

    @impl Jido.Action
    def run(_params, _context), do: {:ok, %{ran: true}}
  end

  defmodule FailingVictim do
    use JidoClaw.Tools.Action,
      name: "tool_approval_failing_victim",
      description: "Test-only action that errors after the approval is consumed.",
      schema: []

    @impl Jido.Action
    def run(_params, _context), do: {:error, "boom"}
  end

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-approval")

    scope = %{
      tenant_id: tenant_id,
      session_uuid: session.id,
      session_id: session.external_id,
      actor: actor_for(tenant_id)
    }

    {:ok, tenant_id: tenant_id, scope: scope}
  end

  defp ctx(scope), do: %{tool_context: scope}

  defp enable_gate(require) do
    prior = Application.get_env(:jido_claw, :tool_approval)
    Application.put_env(:jido_claw, :tool_approval, enabled?: true, require: require)
    on_exit(fn -> Application.put_env(:jido_claw, :tool_approval, prior) end)
  end

  describe "requirement logic (env-free opts)" do
    test "disabled gating passes through", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("git_commit", %{message: "x"}, ctx(scope),
                 enabled?: false,
                 require: ["git_commit"]
               )
    end

    test "a tool neither listed nor pattern-matched passes through", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(scope),
                 enabled?: true,
                 require: ["git_commit"]
               )
    end

    test "a require-listed tool pends", %{scope: scope} do
      assert {:error, %{code: :approval_pending, details: %{case_id: _}}} =
               ToolApproval.gate("git_commit", %{message: "x"}, ctx(scope),
                 enabled?: true,
                 require: ["git_commit"]
               )
    end

    test "run_command git-commit equivalents pend via the shell param-pattern", %{scope: scope} do
      commits = [
        "git commit -m x",
        "git -C repo commit",
        "git -c user.name=x commit",
        "git --git-dir=.git commit",
        "cd /tmp && git commit -m x",
        "crontab -e"
      ]

      for cmd <- commits do
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate("run_command", %{command: cmd}, ctx(scope),
                   enabled?: true,
                   require: []
                 ),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "run_command non-commit commands and bare-token interpositions pass through", %{
      scope: scope
    } do
      benign = ["git status", "git log && echo commit", "echo committing soon"]

      for cmd <- benign do
        assert :ok =
                 ToolApproval.gate("run_command", %{command: cmd}, ctx(scope),
                   enabled?: true,
                   require: []
                 ),
               "expected #{inspect(cmd)} to pass through"
      end
    end

    test "the command pattern normalizes string param keys (MCP path)", %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("run_command", %{"command" => "git commit -m x"}, ctx(scope),
                 enabled?: true,
                 require: []
               )
    end

    test "no tenant scope is a fail-closed approval_unavailable (empty details)", %{scope: _scope} do
      assert {:error, %{code: :approval_unavailable, details: details}} =
               ToolApproval.gate("git_commit", %{}, %{}, enabled?: true, require: ["git_commit"])

      assert details == %{}
    end

    test "approval error details never carry retry-hint keys", %{scope: scope} do
      assert {:error, %{details: details}} =
               ToolApproval.gate("git_commit", %{message: "x"}, ctx(scope),
                 enabled?: true,
                 require: ["git_commit"]
               )

      refute Map.has_key?(details, :reason)
      refute Map.has_key?(details, :retry)
      refute Map.has_key?(details, :retryable)
    end
  end

  describe "wrapper integration (full ticket loop)" do
    test "pend → approve → execute once → re-pend", %{tenant_id: tenant_id, scope: scope} do
      enable_gate(["tool_approval_victim"])
      actor = scope.actor
      flat = Map.delete(scope, :tool_context)

      # 1. First call pends — the tool body never runs.
      assert {:error, %{code: :approval_pending, details: %{case_id: case_id}}} =
               Victim.run(%{arg: "x"}, flat)

      # 2. Operator approves the case.
      {:ok, agent_case} = AgentCase.by_id(case_id, tenant: tenant_id, actor: actor)
      {:ok, _approved} = AgentCase.approve(agent_case, %{}, tenant: tenant_id, actor: actor)

      # 3. The identical retry consumes the approval and runs exactly once.
      assert {:ok, %{ran: true}} = Victim.run(%{arg: "x"}, flat)

      # 4. A second identical call cannot reuse the spent approval — it re-pends.
      assert {:error, %{code: :approval_pending, details: %{case_id: case_id2}}} =
               Victim.run(%{arg: "x"}, flat)

      refute case_id2 == case_id
    end

    test "reject → denied → re-pend", %{tenant_id: tenant_id, scope: scope} do
      enable_gate(["tool_approval_victim"])
      actor = scope.actor
      flat = Map.delete(scope, :tool_context)

      assert {:error, %{code: :approval_pending, details: %{case_id: case_id}}} =
               Victim.run(%{arg: "y"}, flat)

      {:ok, agent_case} = AgentCase.by_id(case_id, tenant: tenant_id, actor: actor)
      {:ok, _rejected} = AgentCase.reject(agent_case, %{}, tenant: tenant_id, actor: actor)

      # The retry is denied once (deny-once consumes the rejection)...
      assert {:error, %{code: :approval_denied}} = Victim.run(%{arg: "y"}, flat)

      # ...and the next identical call re-pends rather than reusing the denial.
      assert {:error, %{code: :approval_pending}} = Victim.run(%{arg: "y"}, flat)
    end

    test "an approval grants ONE attempt — a failing execution still consumes it", %{
      tenant_id: tenant_id,
      scope: scope
    } do
      enable_gate(["tool_approval_failing_victim"])
      actor = scope.actor
      flat = Map.delete(scope, :tool_context)

      assert {:error, %{code: :approval_pending, details: %{case_id: case_id}}} =
               FailingVictim.run(%{arg: "z"}, flat)

      {:ok, agent_case} = AgentCase.by_id(case_id, tenant: tenant_id, actor: actor)
      {:ok, _approved} = AgentCase.approve(agent_case, %{}, tenant: tenant_id, actor: actor)

      # The retry consumes the approval, then the tool body fails.
      assert {:error, %{code: :tool_error}} = FailingVictim.run(%{arg: "z"}, flat)

      # The approval is spent even though the execution failed — re-pend.
      assert {:error, %{code: :approval_pending, details: %{case_id: case_id2}}} =
               FailingVictim.run(%{arg: "z"}, flat)

      refute case_id2 == case_id

      {:ok, consumed} = AgentCase.by_id(case_id, tenant: tenant_id, actor: actor)
      assert consumed.consumed_at != nil
    end

    test "gating disabled — the gated tool runs unimpeded", %{scope: scope} do
      # Default test config has tool_approval disabled.
      flat = Map.delete(scope, :tool_context)
      assert {:ok, %{ran: true}} = Victim.run(%{arg: "x"}, flat)
    end
  end

  describe "config-sanity coverage" do
    defp wrapped_tool_names do
      (JidoClaw.Agent.tool_modules() ++ JidoClaw.MCPServer.published_tool_modules())
      |> Enum.uniq()
      |> Enum.map(& &1.name())
      |> MapSet.new()
    end

    defp tool_module_by_name do
      (JidoClaw.Agent.tool_modules() ++ JidoClaw.MCPServer.published_tool_modules())
      |> Enum.uniq()
      |> Map.new(&{&1.name(), &1})
    end

    test "every shipped require entry resolves to a real wrapped tool" do
      wrapped = wrapped_tool_names()

      for name <- ToolApproval.default_require() do
        assert MapSet.member?(wrapped, name),
               "require entry #{inspect(name)} resolves to no wrapped tool"
      end
    end

    test "every require_patterns key is a real tool whose param is a :string schema field" do
      by_name = tool_module_by_name()

      for {tool, {param, _regexes}} <- ToolApproval.require_patterns() do
        module = Map.get(by_name, tool)
        assert module, "require_patterns key #{inspect(tool)} resolves to no wrapped tool"

        field = module.schema()[param]
        assert field, "#{inspect(tool)} schema has no #{inspect(param)} field"

        assert field[:type] == :string,
               "#{inspect(tool)} param #{inspect(param)} must be a :string field, got #{inspect(field[:type])}"
      end
    end
  end

  describe "external MCP tool policy (env-free opts)" do
    test "an mcp_ tool with an explicit nil policy entry is gated by the global default",
         %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("mcp_x_y", %{}, ctx(scope),
                 enabled?: true,
                 mcp_policy: %{"mcp_x_y" => nil}
               )
    end

    test "an mcp_ tool whose server is trusted (false) passes through", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("mcp_x_y", %{}, ctx(scope),
                 enabled?: true,
                 mcp_policy: %{"mcp_x_y" => false}
               )
    end

    test "global mcp_require_approval: false ungates a nil-policy mcp_ tool", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("mcp_x_y", %{}, ctx(scope),
                 enabled?: true,
                 mcp_require_approval: false,
                 mcp_policy: %{"mcp_x_y" => nil}
               )
    end

    test "overlapping prefixes resolve independently by exact name", %{scope: scope} do
      policy = %{"mcp_foo_q" => false, "mcp_foo_bar_q" => true}

      assert :ok =
               ToolApproval.gate("mcp_foo_q", %{}, ctx(scope), enabled?: true, mcp_policy: policy)

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("mcp_foo_bar_q", %{}, ctx(scope),
                 enabled?: true,
                 mcp_policy: policy
               )
    end

    test "an unknown mcp_-prefixed tool with an empty policy fails CLOSED to gated (not native)",
         %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("mcp_unknown_t", %{}, ctx(scope),
                 enabled?: true,
                 mcp_policy: %{}
               )
    end

    test "the same unknown mcp_ tool ungates under a global false (the &&/|| footgun)",
         %{scope: scope} do
      assert :ok =
               ToolApproval.gate("mcp_unknown_t", %{}, ctx(scope),
                 enabled?: true,
                 mcp_require_approval: false,
                 mcp_policy: %{}
               )
    end

    test "a native (non-mcp_) tool is unaffected by the mcp policy", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(scope),
                 enabled?: true,
                 require: ["git_commit"],
                 mcp_policy: %{}
               )
    end
  end
end
