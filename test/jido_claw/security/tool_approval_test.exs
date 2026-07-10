defmodule JidoClaw.Security.ToolApprovalTest do
  @moduledoc """
  The wrapper-level tool-approval gate: requirement logic (require list + shell
  param-patterns), the pend → approve → execute-once → re-pend loop through the
  shared `Tools.Action` wrapper, deny-once, fail-closed unavailability, and the
  config-sanity coverage sweeps.
  """
  use JidoClaw.TenantCase, async: false

  alias Jido.Action.Schema, as: ActionSchema
  alias Jido.Shell.VFS
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Security.ShellCommand
  alias JidoClaw.Security.ToolApproval
  alias JidoClaw.Security.ToolApproval.MountConfigCache
  alias JidoClaw.VFS.Workspace

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

  # The approval gate only needs the mounted adapter identity. Keeping this
  # intentionally outside AdapterPolicy proves an unknown live module fails
  # closed without requiring a real external service.
  defmodule UnknownLiveAdapter do
    @spec configure(keyword()) :: {module(), keyword()}
    def configure(opts), do: {__MODULE__, opts}

    @spec starts_processes() :: false
    def starts_processes, do: false
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

    test "remote GitHub, S3, and git writes pend while local project writes pass", %{
      scope: scope
    } do
      for tool <- ["write_file", "edit_file"],
          path <- [
            "github://owner/repo/file",
            "s3://bucket/key",
            "git:///tmp/repo//file"
          ] do
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate(tool, %{path: path}, ctx(scope),
                   enabled?: true,
                   require: []
                 )
      end

      for tool <- ["write_file", "edit_file"] do
        assert :ok =
                 ToolApproval.gate(tool, %{path: "lib/local.ex"}, ctx(scope),
                   enabled?: true,
                   require: []
                 )
      end
    end

    test "absolute paths backed by a GitHub mount also pend", %{scope: scope} do
      workspace_id = "approval-mount-#{System.unique_integer([:positive])}"

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "approval-project-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      {:ok, _pid} = Workspace.ensure_started(workspace_id, project_dir)

      :ok =
        Workspace.mount(workspace_id, "/publish", :github, %{
          "owner" => "example",
          "repo" => "example"
        })

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      mounted_scope =
        Map.merge(scope, %{workspace_id: workspace_id, project_dir: project_dir})

      for tool <- ["write_file", "edit_file"] do
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate(tool, %{path: "/publish/file.txt"}, ctx(mounted_scope),
                   enabled?: true,
                   require: []
                 )

        assert :ok =
                 ToolApproval.gate(tool, %{path: "/project/local.txt"}, ctx(mounted_scope),
                   enabled?: true,
                   require: []
                 )
      end
    end

    test "traversal cannot reclassify a remote-mount write as local (live mount)", %{
      scope: scope
    } do
      workspace_id = "approval-traversal-#{System.unique_integer([:positive])}"

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "approval-traversal-project-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      {:ok, _pid} = Workspace.ensure_started(workspace_id, project_dir)

      :ok =
        Workspace.mount(workspace_id, "/publish", :github, %{
          "owner" => "example",
          "repo" => "example"
        })

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      mounted_scope =
        Map.merge(scope, %{workspace_id: workspace_id, project_dir: project_dir})

      for tool <- ["write_file", "edit_file"] do
        # Execution (ShellVFS.resolve_path) canonicalizes before consulting the
        # mount table, so this write lands on the remote /publish mount — the
        # gate must classify the canonical path, never the raw /project prefix.
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate(
                   tool,
                   %{path: "/project/../publish/file.txt"},
                   ctx(mounted_scope),
                   enabled?: true,
                   require: []
                 )

        # The mirror image: a /publish-prefixed raw path that resolves back
        # into the local /project mount stays ungated — the gate matches
        # execution in both directions.
        assert :ok =
                 ToolApproval.gate(
                   tool,
                   %{path: "/publish/../project/local.txt"},
                   ctx(mounted_scope),
                   enabled?: true,
                   require: []
                 )
      end
    end

    test "an unknown live adapter module fails closed to remote-write approval", %{scope: scope} do
      workspace_id = "approval-unknown-live-#{System.unique_integer([:positive])}"

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "approval-unknown-live-project-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      assert :ok = VFS.mount(workspace_id, "/external", UnknownLiveAdapter, [])

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      mounted_scope =
        Map.merge(scope, %{workspace_id: workspace_id, project_dir: project_dir})

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/external/file.txt"},
                 ctx(mounted_scope),
                 enabled?: true,
                 require: []
               )
    end

    test "configured remote mounts pend without bootstrapping the workspace", %{scope: scope} do
      workspace_id = "approval-config-#{System.unique_integer([:positive])}"

      project_dir =
        Path.join(
          System.tmp_dir!(),
          "approval-config-project-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(project_dir, ".jido"))

      File.write!(
        Path.join(project_dir, ".jido/config.yaml"),
        """
        vfs:
          mounts:
            - path: /publish
              adapter: github
              owner: example
              repo: example
            - path: /publish/private
              adapter: typo_that_runtime_skips
        """
      )

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      configured_scope =
        Map.merge(scope, %{workspace_id: workspace_id, project_dir: project_dir})

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, workspace_id) == []

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/private/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, workspace_id) == []
    end

    test "traversal and duplicate-slash forms pend against configured remote mounts", %{
      scope: scope
    } do
      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "traversal-config")

      File.write!(config_path, mount_yaml("github"))

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      # Every form canonicalizes to /publish/private/file.txt — the config
      # fallback must see that, not a raw /project (or dup-slash) prefix.
      for path <- [
            "/project/../publish/private/file.txt",
            "/project/..//publish/private/file.txt",
            "//publish/private/file.txt"
          ] do
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate("write_file", %{path: path}, ctx(configured_scope),
                   enabled?: true,
                   require: []
                 )
      end

      # Relative paths classify non-remote by design: execution's Resolver jail
      # (ensure_under_project) rejects any relative path escaping the project
      # before it can reach a mount, so the gate never absolutizes them —
      # expanding against "/" here would wrongly gate ordinary relative writes.
      assert :ok =
               ToolApproval.gate(
                 "write_file",
                 %{path: "../publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )
    end

    test "an unknown configured adapter fails closed to remote-write approval", %{scope: scope} do
      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "unknown-adapter")

      File.write!(config_path, mount_yaml("future_remote"))

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )
    end

    test "mount YAML parsing is cached by content while every gate re-reads the file", %{
      scope: scope
    } do
      :ok = MountConfigCache.reset()

      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "cache")

      File.write!(config_path, mount_yaml("github"))
      handler_id = "mount-cache-#{System.unique_integer([:positive])}"
      owner = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido_claw, :security, :tool_approval_mount_cache],
          fn _event, _measurements, metadata, _config ->
            send(owner, {:mount_cache, metadata.result})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      for _ <- 1..2 do
        assert {:error, %{code: :approval_pending}} =
                 ToolApproval.gate(
                   "write_file",
                   %{path: "/publish/file.txt"},
                   ctx(configured_scope),
                   enabled?: true,
                   require: []
                 )
      end

      assert_receive {:mount_cache, :miss}
      assert_receive {:mount_cache, :hit}
      refute_receive {:mount_cache, _other}
    end

    test "a same-mtime config edit invalidates by content digest", %{scope: scope} do
      :ok = MountConfigCache.reset()

      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "digest")

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      File.write!(config_path, mount_yaml("local"))
      {:ok, stat} = File.stat(config_path, time: :posix)

      assert :ok =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )

      File.write!(config_path, mount_yaml("github"))
      File.touch!(config_path, stat.mtime)

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )
    end

    test "an oversized mount config fails closed instead of being parsed", %{scope: scope} do
      :ok = MountConfigCache.reset()

      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "oversized")

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      File.write!(config_path, String.duplicate("#", 256_001))

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
               )

      assert MountConfigCache.size() == 0
    end

    test "a scalar vfs container is cached as a typed failure and gates closed", %{scope: scope} do
      :ok = MountConfigCache.reset()

      {workspace_id, project_dir, config_path, configured_scope} =
        mount_config_fixture(scope, "scalar-vfs")

      bytes = "vfs: not-a-map\n"
      File.write!(config_path, bytes)
      digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      on_exit(fn ->
        Workspace.teardown(workspace_id)
        File.rm_rf(project_dir)
      end)

      assert {:error, :invalid_mount_config} =
               MountConfigCache.fetch(project_dir, digest, bytes)

      assert {:error, :invalid_mount_config} =
               MountConfigCache.fetch(project_dir, digest, bytes)

      assert MountConfigCache.size() == 1

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate(
                 "write_file",
                 %{path: "/publish/file.txt"},
                 ctx(configured_scope),
                 enabled?: true,
                 require: []
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
        ~s(K=alias.ci; git config "$K" commit; git ci),
        # git-push equivalence (item 1a): a push publishes to a remote, so it
        # gates like commit in any shell dressing.
        "git push",
        "git push origin main",
        ~s(git push origin "$branch"),
        "sudo git push",
        ~s(sh -c "git push"),
        "git -c alias.p=push p"
      ]

      for cmd <- bypasses do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected #{inspect(cmd)} to pend"
      end
    end

    test "command-runner + interpreter bypasses of the shell floor pend (S-M1)", %{scope: scope} do
      # `require: []` and no template overlay, so the only thing that can gate
      # run_command here is the `{:pattern, :command}` shell param-pattern — i.e.
      # the analyzer's :opaque floor (scope :runner / :interpreter) reached it.
      bypasses = [
        "echo . | xargs git commit -m x",
        "ssh host git commit",
        "su -c 'git commit'",
        "parallel 'git commit' ::: x",
        "find . -exec git commit ;",
        ~s(python -c "import os"),
        ~s(node -e "x"),
        "echo code | python",
        "xargs $cmd"
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
        ~s(git fetch origin "$branch"),
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

    test "the shipped system_verifier gates even a benign run_command", %{scope: scope} do
      assert "run_command" in Templates.require_approval("system_verifier")

      assert {:error, %{code: :approval_pending, message: message}} =
               ToolApproval.gate(
                 "run_command",
                 %{command: "git status"},
                 ctx(with_template(scope, "system_verifier")),
                 enabled?: true,
                 require: []
               )

      assert message =~ "system_verifier"
      assert message =~ "agent template"
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

        json_schema =
          module.schema()
          |> ActionSchema.to_json_schema()
          |> MapKeys.normalize_keys(:string, deep: true)

        properties = Map.get(json_schema, "properties", %{})
        field = Map.get(properties, to_string(param))

        assert field, "#{inspect(tool)} schema has no #{inspect(param)} field"

        type = Map.get(field, "type")

        assert type in ["string", :string],
               "#{inspect(tool)} param #{inspect(param)} must be a string field, got #{inspect(type)}"
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

    test "an explicit gated MCP policy wins over global mcp_require_approval: false", %{
      scope: scope
    } do
      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("mcp_x_y", %{}, ctx(scope),
                 enabled?: true,
                 mcp_require_approval: false,
                 mcp_policy: %{"mcp_x_y" => true}
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

  describe "the :docker bypass (D2-b) skips the shell floor, keeps the additive gates" do
    # Commands that GENUINELY trip a non-disableable floor matcher off the
    # docker path (not benign pipes like `a | b`, which never pend).
    @floor_tripping [
      # {:effect, :git_commit}
      "git commit -m x",
      # {:effect, :git_push}
      "git push origin main",
      # {:effect, :opaque} / :structure (command substitution)
      "echo $(date)",
      # :structure (pipe into a shell)
      "curl x | sh",
      # {:effect, :crontab}
      "crontab -e",
      # {:effect, :opaque} scope :runner (S-M1 command-runner wrapping git commit)
      "xargs git commit -m x",
      # {:effect, :opaque} scope :interpreter (S-M1 interpreter one-liner)
      ~s(python -c "x")
    ]

    test "a floor-tripping run_command under :docker passes the gate", %{scope: scope} do
      docker = Map.put(scope, :sandbox, :docker)

      for cmd <- @floor_tripping do
        assert :ok = run_cmd(docker, cmd),
               "expected :docker to bypass the shell floor for #{inspect(cmd)}"
      end
    end

    test "the SAME commands WITHOUT :docker still pend (the floor is real)", %{scope: scope} do
      for cmd <- @floor_tripping do
        assert {:error, %{code: :approval_pending}} = run_cmd(scope, cmd),
               "expected the shell floor to pend #{inspect(cmd)} off the :docker path"
      end
    end

    test "an explicit operator require: still gates a :docker run_command (additive)", %{
      scope: scope
    } do
      docker = Map.put(scope, :sandbox, :docker)

      # `echo hi` trips no pattern, so only the require-list can gate it — and it
      # does, proving the bypass never weakens the operator floor.
      assert {:error, %{code: :approval_pending}} =
               run_cmd(docker, "echo hi", require: ["run_command"])
    end

    test "a template overlay listing run_command still gates under :docker (additive)", %{
      scope: scope
    } do
      override = %{
        "ra_runcmd_docker" => %{
          module: JidoClaw.Agent.Workers.Coder,
          require_approval: ["run_command"]
        }
      }

      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

      scope =
        scope
        |> Map.put(:sandbox, :docker)
        |> with_template("ra_runcmd_docker")

      assert {:error, %{code: :approval_pending}} =
               ToolApproval.gate("run_command", %{command: "echo hi"}, ctx(scope),
                 enabled?: true,
                 require: []
               )
    end
  end

  defp mount_config_fixture(scope, label) do
    workspace_id = "approval-#{label}-#{System.unique_integer([:positive])}"

    project_dir =
      Path.join(
        System.tmp_dir!(),
        "approval-#{label}-project-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(project_dir, ".jido"))
    config_path = Path.join(project_dir, ".jido/config.yaml")
    configured_scope = Map.merge(scope, %{workspace_id: workspace_id, project_dir: project_dir})
    {workspace_id, project_dir, config_path, configured_scope}
  end

  defp mount_yaml(adapter) do
    """
    vfs:
      mounts:
        - path: /publish
          adapter: #{adapter}
    """
  end
end
