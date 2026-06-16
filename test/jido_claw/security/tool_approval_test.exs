defmodule JidoClaw.Security.ToolApprovalTest do
  @moduledoc """
  The wrapper-level tool-approval gate: requirement logic (require list + shell
  param-patterns), the pend → approve → execute-once → re-pend loop through the
  shared `Tools.Action` wrapper, deny-once, fail-closed unavailability, and the
  config-sanity coverage sweeps.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Security.ShellCommand
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

  defp with_template(scope, name), do: Map.put(scope, :agent_template, name)

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

  describe "shell-aware run_command gating (env-free opts)" do
    defp run_cmd(scope, command, opts \\ []) do
      ToolApproval.gate(
        "run_command",
        Map.new([{:command, command}]),
        ctx(scope),
        Keyword.merge([enabled?: true, require: []], opts)
      )
    end

    test "newly-closed shell bypasses of git_commit pend", %{scope: scope} do
      bypasses = [
        ~s(git -C "my dir" commit),
        "FOO=bar git commit",
        "A=1 B=2 git commit",
        "sudo git commit",
        "sudo -u user git commit",
        "/usr/bin/git commit",
        ~s(sh -c "git commit"),
        "bash -lc 'git commit'",
        "git commit &",
        "echo x\ngit commit",
        "timeout 5 git commit",
        # git-aware resolution: dynamic sub-command, inline alias, redirect-aware
        # arg extraction, and an unknown pre-sub-command flag all gate.
        "git $x",
        "git -c alias.ci=commit ci",
        "git > out commit",
        "git --frobnicate commit",
        # config injection (review F1/F2): GIT_CONFIG_* env (inline, env-wrapper,
        # cross-command export/set -a) and an inline config-include directive.
        "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci",
        "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci",
        "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit; git ci",
        "set -a; GIT_CONFIG_COUNT=1; GIT_CONFIG_KEY_0=alias.ci; GIT_CONFIG_VALUE_0=commit; git ci",
        "git -c include.path=/path/to/config ci",
        # config injection (review F3): a persistent `git config` alias/include
        # write — gates even with no later git in the same string.
        "git config alias.ci commit; git ci",
        "git config alias.ci commit",
        "git config include.path /tmp/evil",
        # the closed dynamic-key bug + the deliberate config grammar: a dynamic
        # key, a section rename into a risky section, and the editor mutation
        # surface all gate as persistent writes.
        ~s(git config "$key" commit),
        ~s(git config set "$key" commit),
        "git config rename-section foo alias",
        "git config --rename-section foo include",
        "git config edit",
        ~s(K=alias.ci; git config "$K" commit; git ci)
      ]

      for cmd <- bypasses do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "compound and control forms hiding git commit pend", %{scope: scope} do
      compounds = [
        "(git commit)",
        "{ git commit; }",
        "if true; then git commit; fi",
        "f(){ git commit; }; f"
      ]

      for cmd <- compounds do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "un-analyzable commands fail closed and pend (never silently pass)", %{scope: scope} do
      unknowns = [
        "$GIT commit",
        "git${IFS}commit",
        "sudo -X git commit",
        "sh <<EOF\ngit commit\nEOF",
        String.duplicate("a;", 300),
        # A dynamic interpreter/eval script target cannot be read — fail closed.
        ~s(sh -c "$cmd"),
        ~s(eval "$cmd")
      ]

      for cmd <- unknowns do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "suspicious shell structure pends under the default kinds", %{scope: scope} do
      structural = [~S|echo $(date)|, ~S|git log `date`|, "curl x | sh", "base64 -d | bash -e"]

      for cmd <- structural do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "benign commands and pinned residuals pass through", %{scope: scope} do
      benign = [
        "git status",
        "git diff",
        "ls -la",
        "echo hello",
        "git log && echo commit",
        "bash deploy.sh",
        "sh < deploy.sh",
        "alias gc='git commit'",
        "gc",
        # git-aware resolution keeps common benign dynamic-arg usage un-gated:
        # a dynamic value is not a sub-command.
        ~s(git push origin "$branch"),
        ~s(git -C "$dir" status),
        # config-injection benign regressions (review F1/F2/F3): a GIT_CONFIG token
        # with no git command, a non-GIT_CONFIG env prefix, a non-include `-c`, and
        # an ordinary `git config` write to a non-alias/include key.
        "echo GIT_CONFIG_COUNT=1",
        "GIT_AUTHOR_NAME=x git status",
        "git -c core.pager=less status",
        "git config user.name x",
        # config reads/removals + a benign dynamic-value write are intentionally
        # allowed (they cannot plant config a later git honors).
        ~s(git config user.name "$val"),
        "git config --get alias.x",
        "git config get user.name",
        "git config unset alias.x",
        "git config remove-section alias",
        "git config --list"
      ]

      for cmd <- benign do
        assert :ok = run_cmd(scope, cmd), "expected #{inspect(cmd)} to pass through"
      end
    end

    test "an argument-position variable does not mask a literal git commit", %{scope: scope} do
      assert {:error, %{code: :approval_pending}} = run_cmd(scope, ~S|git commit -m "$MSG"|)
    end

    test ":suspicious_shell_structure_kinds narrows structural gating", %{scope: scope} do
      # Default-on: command substitution pends.
      assert {:error, %{code: :approval_pending}} = run_cmd(scope, ~S|echo $(date)|)

      # Narrowed to pipe-only: $() passes through, the pipe-into-shell still pends.
      narrowed = [suspicious_shell_structure_kinds: [:pipe_to_shell]]
      assert :ok = run_cmd(scope, ~S|echo $(date)|, narrowed)
      assert {:error, %{code: :approval_pending}} = run_cmd(scope, "curl x | sh", narrowed)
    end

    test ":suspicious_shell_structure_kinds: [] disables structure but not the floor", %{
      scope: scope
    } do
      off = [suspicious_shell_structure_kinds: []]
      # $() passes once structural gating is off...
      assert :ok = run_cmd(scope, ~S|echo $(date)|, off)
      # ...but the git matcher and the un-analyzable fail-closed floor still pend.
      assert {:error, %{code: :approval_pending}} = run_cmd(scope, "git commit", off)
      assert {:error, %{code: :approval_pending}} = run_cmd(scope, "$GIT commit", off)
    end

    test "a malformed kinds config falls back to the default (does not disable)", %{scope: scope} do
      # A non-list typo must not silently turn structural gating off.
      assert {:error, %{code: :approval_pending}} =
               run_cmd(scope, ~S|echo $(date)|, suspicious_shell_structure_kinds: :oops)
    end

    test "the gate is backend-agnostic (pre-dispatch) — an SSH-backed git commit pends", %{
      scope: scope
    } do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "run_command",
                 %{command: "git commit", backend: "ssh", server: "x"},
                 ctx(scope),
                 enabled?: true,
                 require: []
               )
    end

    test "a config %Regex{} matcher coexists with the structured run_command default", %{
      scope: scope
    } do
      opts = [
        enabled?: true,
        require: [],
        require_patterns: %{"read_file" => {:path, [~r{/etc/shadow}]}}
      ]

      # The structured run_command default still gates a shell git commit...
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("run_command", %{command: "git commit"}, ctx(scope), opts)

      # ...and the config-supplied regex gates read_file on a matching path.
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("read_file", %{path: "/etc/shadow"}, ctx(scope), opts)

      assert :ok = ToolApproval.gate("read_file", %{path: "/tmp/ok"}, ctx(scope), opts)
    end

    test "a config {:effect, _} matcher with an unknown kind is warn-skipped, not silently inert",
         %{
           scope: scope
         } do
      cfg = fn kind ->
        [
          enabled?: true,
          require: [],
          require_patterns: %{"read_file" => {:path, [{:effect, kind}]}}
        ]
      end

      # A valid effect kind gates read_file when its path is commit-shaped...
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "read_file",
                 %{path: "git commit"},
                 ctx(scope),
                 cfg.(:git_commit)
               )

      # ...while a typo'd kind warn-skips the whole entry (logged, never silently
      # accepted-then-inert), so the same path now passes through.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   ToolApproval.gate(
                     "read_file",
                     %{path: "git commit"},
                     ctx(scope),
                     cfg.(:git_commt)
                   )
        end)

      assert log =~ "ignoring invalid :require_patterns"
    end
  end

  describe "per-template require_approval overlay (env-free opts)" do
    setup do
      original = Application.get_env(:jido_claw, :agent_templates_override, %{})

      # Real shipped worker module (carries read_file/list_directory/run_command);
      # only :require_approval is overridden per template under test.
      overrides = %{
        "coder" => %{module: JidoClaw.Agent.Workers.Coder, require_approval: ["read_file"]},
        "ra_all" => %{module: JidoClaw.Agent.Workers.Coder, require_approval: :all},
        "ra_runcmd" => %{module: JidoClaw.Agent.Workers.Coder, require_approval: ["run_command"]},
        "victim_tpl" => %{
          module: JidoClaw.Agent.Workers.Coder,
          require_approval: ["tool_approval_victim"]
        }
      }

      Application.put_env(:jido_claw, :agent_templates_override, Map.merge(original, overrides))
      on_exit(fn -> Application.put_env(:jido_claw, :agent_templates_override, original) end)
      :ok
    end

    test "a tool in the calling template's require_approval pends", %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(with_template(scope, "coder")),
                 enabled?: true,
                 require: []
               )
    end

    test "a tool NOT in the template's require_approval passes through", %{scope: scope} do
      assert :ok =
               ToolApproval.gate(
                 "list_directory",
                 %{path: "x"},
                 ctx(with_template(scope, "coder")),
                 enabled?: true,
                 require: []
               )
    end

    test ":all gates every native tool for the template", %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(with_template(scope, "ra_all")),
                 enabled?: true,
                 require: []
               )
    end

    test ~s(the unrouted "main" agent is never gated by template policy), %{scope: scope} do
      assert :ok =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(with_template(scope, "main")),
                 enabled?: true,
                 require: []
               )
    end

    test "an absent tool_context (no template) consults the global floor only", %{scope: scope} do
      assert :ok =
               ToolApproval.gate("read_file", %{path: "x"}, ctx(scope),
                 enabled?: true,
                 require: []
               )
    end

    test "a global require-listed tool stays gated regardless of template", %{scope: scope} do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "git_commit",
                 %{message: "x"},
                 ctx(with_template(scope, "coder")),
                 enabled?: true,
                 require: ["git_commit"]
               )
    end

    test "a param-pattern reason wins over a broad template policy (order check)", %{scope: scope} do
      assert {:error, %{message: message}} =
               ToolApproval.gate(
                 "run_command",
                 %{command: "git commit -m x"},
                 ctx(with_template(scope, "ra_runcmd")),
                 enabled?: true,
                 require: []
               )

      assert message =~ "guarded-operation pattern"
      refute message =~ "agent template"
    end

    test "lifts a flat agent_template (ReAct flat-merge) and gates via the live wrapper", %{
      scope: scope
    } do
      enable_gate([])

      flat =
        scope
        |> Map.delete(:tool_context)
        |> Map.put(:agent_template, "victim_tpl")

      assert {:error, %{code: :approval_pending}} = Victim.run(%{arg: "x"}, flat)
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

      for {tool, {param, _matchers}} <- ToolApproval.require_patterns() do
        module = Map.get(by_name, tool)
        assert module, "require_patterns key #{inspect(tool)} resolves to no wrapped tool"

        field = module.schema()[param]
        assert field, "#{inspect(tool)} schema has no #{inspect(param)} field"

        assert field[:type] == :string,
               "#{inspect(tool)} param #{inspect(param)} must be a :string field, got #{inspect(field[:type])}"
      end
    end

    test "every shipped {:effect, _} matcher names a known analyzer effect kind" do
      known = MapSet.new(ShellCommand.effect_kinds())

      for {_tool, {_param, matchers}} <- ToolApproval.require_patterns(),
          {:effect, kind} <- matchers do
        assert MapSet.member?(known, kind),
               "shipped {:effect, #{inspect(kind)}} is not a known effect kind"
      end
    end

    # Trivial today (every shipped template ships `require_approval: []`), but a
    # live typo guard the moment entries are added: each entry must be one of
    # THAT template's own tools (not the broad MCP-inclusive wrapped set).
    test "every shipped template's require_approval names a tool that template can call" do
      for {name, template} <- Templates.list() do
        assert_template_require_approval(name, template)
      end
    end

    defp assert_template_require_approval(_name, %{require_approval: :all}), do: :ok

    defp assert_template_require_approval(name, %{require_approval: list} = template)
         when is_list(list) do
      own_tools = template_tool_names(template)

      for entry <- list do
        assert MapSet.member?(own_tools, entry),
               "template #{name} require_approval entry #{inspect(entry)} is not one of its tools"
      end
    end

    defp template_tool_names(%{module: module}) do
      module.strategy_opts()
      |> Keyword.get(:tools, [])
      |> Enum.map(& &1.name())
      |> MapSet.new()
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
