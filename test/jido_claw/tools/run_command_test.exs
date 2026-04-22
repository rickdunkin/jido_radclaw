defmodule JidoClaw.Tools.RunCommandTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Test.FakeSSH
  alias JidoClaw.Tools.RunCommand
  alias JidoClaw.VFS.Workspace

  describe "run/2 success" do
    test "should execute command and return stdout output" do
      assert {:ok, result} = RunCommand.run(%{command: "echo hello"}, %{})

      assert String.trim(result.output) == "hello"
    end

    test "should return exit_code 0 for successful command" do
      assert {:ok, result} = RunCommand.run(%{command: "true"}, %{})

      assert result.exit_code == 0
    end

    test "should return non-zero exit_code when command fails" do
      assert {:ok, result} = RunCommand.run(%{command: "false"}, %{})

      assert result.exit_code != 0
    end

    test "should capture stderr merged into output" do
      assert {:ok, result} = RunCommand.run(%{command: "echo err >&2"}, %{})

      assert result.output =~ "err"
    end

    test "should return correct output for multi-word command" do
      assert {:ok, result} = RunCommand.run(%{command: "echo foo bar baz"}, %{})

      assert String.trim(result.output) == "foo bar baz"
    end

    test "should execute commands with pipes" do
      # seq produces one number per line; pipe through wc -l to count them
      assert {:ok, result} = RunCommand.run(%{command: "seq 1 5 | wc -l"}, %{})

      assert String.trim(result.output) =~ "5"
    end

    test "should report correct exit_code for failing command" do
      assert {:ok, result} = RunCommand.run(%{command: "exit 42"}, %{})

      assert result.exit_code == 42
    end
  end

  describe "run/2 output truncation" do
    test "should truncate output longer than 10_000 characters" do
      # generate ~12KB of output: 12000 'x' chars plus newline
      command = "python3 -c \"print('x' * 12000)\""

      assert {:ok, result} = RunCommand.run(%{command: command}, %{})

      assert String.length(result.output) <= 10_000 + 100
      assert result.output =~ "output truncated"
    end

    test "should not truncate output shorter than 10_000 characters" do
      assert {:ok, result} = RunCommand.run(%{command: "echo short"}, %{})

      refute result.output =~ "truncated"
    end
  end

  describe "run/2 timeout" do
    test "should return error when command exceeds timeout" do
      assert {:error, message} =
               RunCommand.run(%{command: "sleep 10", timeout: 100}, %{})

      assert message =~ "timed out"
    end

    test "should complete within timeout when command finishes in time" do
      assert {:ok, result} = RunCommand.run(%{command: "echo fast", timeout: 5_000}, %{})

      assert String.trim(result.output) == "fast"
    end
  end

  describe "run/2 backend routing" do
    @staging %ServerEntry{
      name: "staging",
      host: "web01.example.com",
      user: "deploy",
      port: 22,
      auth_kind: :default,
      cwd: "/",
      env: %{},
      shell: "sh",
      connect_timeout: 10_000
    }

    setup do
      FakeSSH.bind_test_pid()
      FakeSSH.set_mode(:normal)

      Application.put_env(:jido_claw, :ssh_test_modules, %{
        ssh_module: FakeSSH,
        ssh_connection_module: FakeSSH
      })

      ServerRegistry.replace_servers_for_test(%{"staging" => @staging})

      workspace_id = "rc-tool-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_run_command_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      # Seed a marker so the VFS route (/project mounted to tmp) can produce
      # observably different output from host (/project doesn't exist).
      File.write!(Path.join(tmp, "mix.exs"), "mix.exs contents")

      on_exit(fn ->
        _ = SessionManager.stop_session(workspace_id)
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(tmp)
        Application.delete_env(:jido_claw, :ssh_test_modules)
        ServerRegistry.replace_servers_for_test(%{})
        FakeSSH.clear_mode()
        FakeSSH.clear_test_pid()
      end)

      {:ok, workspace_id: workspace_id, tmp: tmp}
    end

    test "backend: \"ssh\" + server routes to SessionManager SSH path", %{workspace_id: ws} do
      assert {:ok, result} =
               RunCommand.run(
                 %{
                   command: "echo via-tool",
                   backend: "ssh",
                   server: "staging",
                   workspace_id: ws
                 },
                 %{}
               )

      assert result.exit_code == 0
      assert_receive {:fake_ssh, {:connect, _, _, _, _}}
    end

    test "legacy atom :ssh coerced to string, validation passes", %{workspace_id: ws} do
      # on_before_validate_params/1 coerces :ssh to "ssh" before
      # NimbleOptions runs the {:in, [...]} check.
      assert {:ok, _params} =
               RunCommand.on_before_validate_params(%{backend: :ssh, server: "staging"})

      # End-to-end via run/2 with atom input.
      assert {:ok, _} =
               RunCommand.run(
                 %{
                   command: "echo hi",
                   backend: :ssh,
                   server: "staging",
                   workspace_id: ws
                 },
                 %{}
               )
    end

    test "backend: \"ssh\" without server returns validation error", %{workspace_id: ws} do
      assert {:error, message} =
               RunCommand.run(
                 %{command: "echo hi", backend: "ssh", workspace_id: ws},
                 %{}
               )

      assert message =~ "server: is required when backend: \"ssh\""
    end

    test "backend: \"host\" overrides a VFS-classified command", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # `cat /project/mix.exs` classifies to VFS. `backend: "host"` must
      # flip it to the host session, where `/project/mix.exs` is not a
      # real path — cat fails. If the override were silently ignored,
      # the command would succeed with the seeded file contents.
      assert {:ok, result} =
               RunCommand.run(
                 %{
                   command: "cat /project/mix.exs",
                   backend: "host",
                   workspace_id: ws
                 },
                 %{tool_context: %{workspace_id: ws, project_dir: tmp}}
               )

      assert result.exit_code != 0
      refute result.output =~ "mix.exs contents"
    end

    test "backend: \"vfs\" routes through SessionManager VFS session", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Same command as the host-override test above, but with the VFS
      # route the file resolves via the /project mount and cat succeeds
      # with the seeded contents.
      assert {:ok, result} =
               RunCommand.run(
                 %{
                   command: "cat /project/mix.exs",
                   backend: "vfs",
                   workspace_id: ws
                 },
                 %{tool_context: %{workspace_id: ws, project_dir: tmp}}
               )

      assert result.exit_code == 0
      assert result.output =~ "mix.exs contents"
    end

    test "legacy force: :host still works" do
      assert {:ok, result} =
               RunCommand.run(%{command: "echo forced", force: :host}, %{})

      assert String.trim(result.output) == "forced"
    end
  end

  describe "run/2 SSH fallback refusal" do
    # Temporarily unregisters the SessionManager name so
    # `session_manager_available?/0` sees nil. `Process.whereis` goes
    # back to finding the pid as soon as we re-register. No restart
    # of the actual process is involved.
    test "returns error instead of falling back to System.cmd when SessionManager is down" do
      pid = Process.whereis(JidoClaw.Shell.SessionManager)
      assert is_pid(pid)

      Process.unregister(JidoClaw.Shell.SessionManager)

      try do
        assert {:error, message} =
                 RunCommand.run(
                   %{command: "echo nope", backend: "ssh", server: "staging"},
                   %{}
                 )

        assert message =~ "SSH requires SessionManager"
      after
        Process.register(pid, JidoClaw.Shell.SessionManager)
      end
    end

    test "host/vfs paths fall back to System.cmd when SessionManager is down" do
      pid = Process.whereis(JidoClaw.Shell.SessionManager)

      Process.unregister(JidoClaw.Shell.SessionManager)

      try do
        assert {:ok, result} = RunCommand.run(%{command: "echo ok"}, %{})
        assert String.trim(result.output) == "ok"
      after
        Process.register(pid, JidoClaw.Shell.SessionManager)
      end
    end
  end
end
