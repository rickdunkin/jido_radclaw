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
    prev_keychain = Application.get_env(:jido_claw, :claude_keychain_reader)

    # Deterministic keychain MISS by default: on a darwin dev machine the
    # real reader could find the operator's actual Keychain credential and
    # flip the :no_credentials paths green. Keychain-specific tests arm
    # their own fun.
    Application.put_env(:jido_claw, :claude_keychain_reader, fn -> :error end)

    on_exit(fn ->
      restore(:claude_home_dir, prev_claude)
      restore(:forge_home, prev_forge)
      restore(:claude_keychain_reader, prev_keychain)
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

    test "every iteration is a FRESH -p session — never a resume/continue token (PR-3)",
         %{client: client, state: state} do
      # camus SKILL.md's fresh-session-per-round rule: each composer re-review
      # wave must re-read the CURRENT tree, never resume a stale session
      # (camus C3-1's intra-attempt resume probe is deliberately not ported).
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = ClaudeCode.run_iteration(client, state, [])

      ["claude" | args] = StubSandbox.last_run_args(client)

      assert List.first(args) == "-p"
      refute Enum.any?(args, &(&1 =~ "resume"))
      refute "--continue" in args
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

      # The credential lands at the DOTTED in-sandbox name (what in-VM Linux
      # claude reads under CLAUDE_CONFIG_DIR) through a CHECKED write whose
      # command chmods 600 in the same exec; the minimal settings.json rides
      # the same exec-based transport — and nothing else from the host dir
      # crosses (no settings/skills/CLAUDE.md sync).
      cred_cmd = Enum.find(sync_cmds, &String.contains?(&1, "#{config_dir}/.credentials.json"))
      assert cred_cmd
      assert cred_cmd =~ "chmod 600 #{config_dir}/.credentials.json"
      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      refute Enum.any?(exec_cmds, &String.contains?(&1, "CLAUDE.md"))
      refute Enum.any?(exec_cmds, &String.contains?(&1, "skills"))

      # The minimal settings body is exactly the exec-written "{}" — never the
      # allow-all pin, and never a jailed Sandbox.write_file (which records a
      # {:write, path} event / file entry on the stub).
      settings_cmd = Enum.find(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      assert settings_cmd =~ Base.encode64("{}")
      assert StubSandbox.file(client, "#{config_dir}/settings.json") == nil
    end

    test "config_sync: :auth_only fails closed when the checked credential write fails",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # Every exec fails; the unchecked mkdirs shrug, but the CHECKED
      # credential write must surface the failure — a session without its
      # credential must not start and drift into an opaque CLI failure.
      StubSandbox.program_exec(client, {"disk full", 1})

      assert {:error, {:checked_write_failed, dest, 1}} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert dest == "#{forge_home}/.claude/.credentials.json"
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
               "--verbose",
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

  # Docker write build (Unit C): the shared credential source for
  # `config_sync: :auth_only` — dotted host file → legacy dotless file →
  # macOS Keychain (the `:claude_keychain_reader` seam), fail
  # `:no_credentials` when all three miss. Content-based: an empty source
  # falls through to the next.
  describe "shared credential source (:auth_only)" do
    setup do
      host = make_tmpdir!("claude_cred_source")
      Application.put_env(:jido_claw, :claude_home_dir, host)
      forge_home = make_tmpdir!("forge_home_cred_source")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home, config_dir: "#{forge_home}/.claude"}
    end

    defp cred_cmd(client, config_dir) do
      Enum.find_value(StubSandbox.events(client), fn
        {:exec, cmd} ->
          if String.contains?(cmd, "base64 -d") and
               String.contains?(cmd, "#{config_dir}/.credentials.json"),
             do: cmd

        _ ->
          nil
      end)
    end

    test "the dotted host file wins over the legacy dotless file",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, ".credentials.json"), ~s({"which":"dotted"}))
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      cmd = cred_cmd(client, config_dir)
      assert cmd =~ Base.encode64(~s({"which":"dotted"}))
      refute cmd =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "the legacy dotless file is used when no dotted file exists",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "the Keychain seam is consulted when no host file exists (darwin source); blob never lands on host disk",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      Application.put_env(:jido_claw, :claude_keychain_reader, fn ->
        {:ok, ~s({"which":"keychain"})}
      end)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"keychain"}))
      # The blob rides the exec transport only — never written to the host dir.
      refute File.exists?(Path.join(host, ".credentials.json"))
      refute File.exists?(Path.join(host, "credentials.json"))
    end

    test "an empty host file falls through (content-based resolution)",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, ".credentials.json"), "")
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "all three sources missing ⇒ {:error, :no_credentials}, nothing written",
         %{forge_home: forge_home} do
      # setup arms the keychain seam to a deterministic miss.
      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert StubSandbox.events(client) == []
    end

    test "a keychain blob that is empty ⇒ {:error, :no_credentials}",
         %{forge_home: forge_home} do
      Application.put_env(:jido_claw, :claude_keychain_reader, fn -> {:ok, ""} end)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})
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
