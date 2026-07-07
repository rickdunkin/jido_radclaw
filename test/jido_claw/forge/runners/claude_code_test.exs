defmodule JidoClaw.Forge.Runners.ClaudeCodeTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Forge.Runners.ClaudeCode`. Mirrors the
  Codex runner test shape — exercises `init/2` against a stub sandbox
  with `:claude_home_dir` and `:forge_home` injected via app env so
  filesystem effects stay confined to tmp dirs.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.Runners.ClaudeCode
  alias JidoClaw.Test.StubSandbox

  setup do
    prev_claude = Application.get_env(:jido_claw, :claude_home_dir)
    prev_forge = Application.get_env(:jido_claw, :forge_home)

    on_exit(fn ->
      restore(:claude_home_dir, prev_claude)
      restore(:forge_home, prev_forge)
    end)

    :ok
  end

  describe "init/2 — :no_credentials" do
    test "returns {:error, :no_credentials} when host claude dir is missing" do
      missing = Path.join(System.tmp_dir!(), "no_claude_#{:erlang.unique_integer([:positive])}")
      Application.put_env(:jido_claw, :claude_home_dir, missing)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      events = StubSandbox.events(client)
      refute Enum.any?(events, fn {kind, _} -> kind == :write end)
    end

    test "returns {:error, :no_credentials} when host dir exists but credentials.json is missing" do
      tmp = make_tmpdir!("claude_missing_creds")
      File.write!(Path.join(tmp, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, tmp)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      on_exit(fn -> File.rm_rf(tmp) end)
    end
  end

  describe "init/2 — happy path" do
    setup do
      host = make_tmpdir!("claude_host")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "syncs ~/.claude into the sandbox and pins permissions settings",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, state} =
               ClaudeCode.init(client, %{
                 forge_home: forge_home,
                 prompt: "do consolidator work"
               })

      assert state.forge_home == forge_home
      assert state.model == "claude-sonnet-4-20250514"

      events = StubSandbox.events(client)

      mkdirs =
        for {:exec, cmd} <- events, String.starts_with?(cmd, "mkdir -p"), do: cmd

      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/.claude"))
      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/session"))

      sync_cmds =
        for {:exec, cmd} <- events, String.contains?(cmd, "base64 -d"), do: cmd

      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{forge_home}/.claude/credentials.json"))

      # credentials.json gets chmod 600
      assert Enum.any?(events, fn
               {:exec, cmd} -> cmd == "chmod 600 #{forge_home}/.claude/credentials.json"
               _ -> false
             end)

      # The pinned settings.json overwrites whatever the sync wrote.
      pinned = StubSandbox.file(client, "#{forge_home}/.claude/settings.json")
      assert pinned == ~s({"permissions":{"allow":["*"]}})

      # The redacted prompt was dropped at session/context.md.
      assert StubSandbox.file(client, "#{forge_home}/session/context.md") =~ "consolidator work"
    end
  end

  describe "run_iteration/3" do
    setup do
      host = make_tmpdir!("claude_host_run")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude_run")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, client, _sid} = StubSandbox.create()

      {:ok, state} =
        ClaudeCode.init(client, %{forge_home: forge_home, prompt: "do work"})

      {:ok, client: client, state: state}
    end

    test "timeout → harness_timeout", %{client: client, state: state} do
      StubSandbox.program_run(client, {"", :timeout})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               ClaudeCode.run_iteration(client, state, [])
    end

    test "docker-manufactured timeout (exit 124) → harness_timeout", %{
      client: client,
      state: state
    } do
      # Docker maps a harness timeout to `{"timeout after \#{t}ms", 124}`, not the
      # `:timeout` atom HostShell uses. `Sandbox.run/4` normalizes that EXACT
      # tuple back to `:timeout`, so the runner classifies it as harness_timeout
      # rather than the generic "claude cli failed" it fell into before the fix.
      StubSandbox.program_run(client, {"timeout after 5000ms", 124})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               ClaudeCode.run_iteration(client, state, timeout: 5000)
    end
  end

  # Executor-seam PR-2 knobs. Defaults (covered above) preserve the
  # consolidator byte-for-byte; these pin the vendor-executor posture —
  # env/argv assertions, not just copied files (review finding P1b).
  describe "executor knobs (PR-2)" do
    setup do
      host = make_tmpdir!("claude_host_knobs")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), ~s({"host":"settings"}))
      File.write!(Path.join(host, "CLAUDE.md"), "# host claude md\n")
      File.mkdir_p!(Path.join(host, "skills"))
      File.write!(Path.join(host, "skills/host_skill.md"), "host skill\n")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude_knobs")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "config_sync: :auth_only builds an isolated CLAUDE_CONFIG_DIR — credentials only, minimal settings, env injected",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _state} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      config_dir = "#{forge_home}/.claude"

      # The isolation is the ENV, not the copied files (P1b): claude's whole
      # config universe becomes the per-run dir.
      assert StubSandbox.env(client) == %{"CLAUDE_CONFIG_DIR" => config_dir}

      exec_cmds = for {:exec, cmd} <- StubSandbox.events(client), do: cmd
      sync_cmds = Enum.filter(exec_cmds, &String.contains?(&1, "base64 -d"))

      # credentials.json synced (and re-tightened) + the minimal settings.json
      # written through the SAME exec-based transport — and nothing else from
      # the host dir crosses (no settings/skills/CLAUDE.md sync).
      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{config_dir}/credentials.json"))
      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      assert "chmod 600 #{config_dir}/credentials.json" in exec_cmds
      refute Enum.any?(exec_cmds, &String.contains?(&1, "CLAUDE.md"))
      refute Enum.any?(exec_cmds, &String.contains?(&1, "skills"))

      # The minimal settings body is exactly the exec-written "{}" — never the
      # allow-all pin, and never a jailed Sandbox.write_file (which records a
      # {:write, path} event / file entry on the stub).
      settings_cmd = Enum.find(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      assert settings_cmd =~ Base.encode64("{}")
      assert StubSandbox.file(client, "#{config_dir}/settings.json") == nil
    end

    test "config_sync: :auth_only fails closed when the env inject is refused",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # A refused CLAUDE_CONFIG_DIR inject means claude would read the
      # operator's REAL ~/.claude — the unisolated session must not start.
      StubSandbox.program_inject_env(client, {:error, :inject_env_refused})

      assert {:error, {:config_isolation_failed, :inject_env_refused}} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})
    end

    test "access: :read_only pins the restricted flag set (no bypass flag); add_dirs land",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()
      repo_dir = Path.join(forge_home, "repo")

      {:ok, state} =
        ClaudeCode.init(client, %{
          forge_home: forge_home,
          config_sync: :auth_only,
          access: :read_only,
          allowed_mcp_tools: ["mcp__jido_deposit__submit_structured_output"],
          add_dirs: [repo_dir],
          mcp_config_path: "/tmp/deposit.json",
          prompt: "review it"
        })

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = ClaudeCode.run_iteration(client, state, [])

      ["claude" | args] = StubSandbox.last_run_args(client)

      assert args == [
               "-p",
               "review it",
               "--model",
               "claude-sonnet-4-20250514",
               "--tools",
               "Read,Glob,Grep",
               "--allowedTools",
               "Read,Glob,Grep,mcp__jido_deposit__submit_structured_output",
               "--permission-mode",
               "dontAsk",
               "--strict-mcp-config",
               "--output-format",
               "stream-json",
               "--max-turns",
               "200",
               "--add-dir",
               repo_dir,
               "--mcp-config",
               "/tmp/deposit.json"
             ]

      refute "--dangerously-skip-permissions" in args
    end
  end

  defp make_tmpdir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
end
