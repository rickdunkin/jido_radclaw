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

    test "truncated output stays valid UTF-8 when cap cuts a multibyte codepoint" do
      # Non-streaming cap is 10_000 bytes. '€' is 3 bytes:
      # 10_000 / 3 = 3333 remainder 1 → cap falls inside the 3334th '€'.
      # A naive `binary_part/3` cut would yield invalid UTF-8 and break
      # JSON encoding for the tool result; truncate_utf8 must drop the
      # partial codepoint.
      command = ~s|python3 -c "import sys; sys.stdout.write('€' * 5000)"|

      assert {:ok, result} = RunCommand.run(%{command: command}, %{})

      assert result.output =~ "output truncated"
      assert String.valid?(result.output)
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

  describe "stream_to_display: roundtrip" do
    setup do
      workspace_id = "rc-stream-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = SessionManager.stop_session(workspace_id)
        # Best-effort: streams use the persistent host session_id, so
        # if the test died mid-stream the entry could still be live.
        _ = JidoClaw.Display.end_stream(workspace_id <> ":host")
      end)

      {:ok, workspace_id: workspace_id}
    end

    # Display writes via IO.write on its own group leader; redirect
    # it to the calling process's gl so capture_io can see it.
    # async: false on the suite makes this safe.
    defp capture_streaming(fun) do
      ExUnit.CaptureIO.capture_io(fn ->
        display_pid =
          GenServer.whereis(JidoClaw.Display) || flunk("Display singleton not running")

        original_gl = Process.info(display_pid, :group_leader) |> elem(1)
        Process.group_leader(display_pid, Process.group_leader())

        try do
          fun.()
          # Ensure all pending casts to Display have flushed.
          _ = :sys.get_state(JidoClaw.Display)
        after
          Process.group_leader(display_pid, original_gl)
        end
      end)
    end

    test "renders chunks in real time and returns a captured preview", %{workspace_id: ws} do
      io =
        capture_streaming(fn ->
          {:ok, result} =
            RunCommand.run(
              %{
                command: "for i in $(seq 1 50); do echo line_$i; done",
                stream_to_display: true,
                workspace_id: ws,
                timeout: 10_000
              },
              %{}
            )

          # Captured-output return is a preview — small for a 50-line
          # stream, but the assertion is on the structural shape.
          assert is_binary(result.output)
          send(self(), {:exit_code, result.exit_code})
        end)

      assert_received {:exit_code, 0}

      # Display rendered the lines live. Spot-check first/last; checking
      # all 50 individually is overkill (and noisy).
      assert io =~ "line_1"
      assert io =~ "line_50"

      # Stream banner from {:command_started, line} event.
      assert io =~ "[main] run_command:"
    end

    test "cap overflow returns {:error, %Jido.Shell.Error{}} with proper context", %{
      workspace_id: ws
    } do
      # Test config sets :test_streaming_max_output_bytes_override = 100_000.
      # Generate ~150 KB of output: 1500 lines of 100 chars each.
      command = "for i in $(seq 1 1500); do printf '%0100d\\n' $i; done"

      _io =
        capture_streaming(fn ->
          response =
            RunCommand.run(
              %{
                command: command,
                stream_to_display: true,
                workspace_id: ws,
                timeout: 10_000
              },
              %{}
            )

          send(self(), {:response, response})
        end)

      assert_received {:response, response}

      assert {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}, context: ctx}} =
               response

      assert is_integer(ctx.emitted_bytes)
      assert is_integer(ctx.max_output_bytes)
      assert ctx.max_output_bytes == 100_000

      assert is_binary(ctx.preview)
      # Command emits zero-padded sequence numbers; first lines must be in preview.
      assert ctx.preview =~ "0000000000000000001"
      # Preview is bounded — finalize_output streaming cap is 50 KB.
      assert byte_size(ctx.preview) <= 50_000 + 100
      # Preview must always be valid UTF-8 — JSON/tool-result encoding
      # would break otherwise. ASCII content here, but the assertion
      # also guards future multibyte regressions.
      assert String.valid?(ctx.preview)
    end

    test "MCP serve_mode silently drops stream_to_display:", %{workspace_id: ws} do
      Application.put_env(:jido_claw, :serve_mode, :mcp)

      try do
        io =
          capture_streaming(fn ->
            {:ok, result} =
              RunCommand.run(
                %{
                  command: "echo mcp_check",
                  stream_to_display: true,
                  workspace_id: ws,
                  timeout: 5_000
                },
                %{}
              )

            send(self(), {:result, result})
          end)

        # No Display interaction (no streaming banner).
        refute io =~ "[main] run_command:"

        # Captured output still returns to the agent normally.
        assert_received {:result, %{output: out, exit_code: 0}}
        assert String.trim(out) == "mcp_check"
      after
        Application.delete_env(:jido_claw, :serve_mode)
      end
    end

    test "System.cmd fallback ignores stream_to_display: entirely" do
      pid = Process.whereis(JidoClaw.Shell.SessionManager)
      Process.unregister(JidoClaw.Shell.SessionManager)

      try do
        io =
          capture_streaming(fn ->
            {:ok, result} =
              RunCommand.run(
                %{command: "echo fallback_ok", stream_to_display: true, timeout: 5_000},
                %{}
              )

            send(self(), {:result, result})
          end)

        # System.cmd path doesn't touch Display.
        refute io =~ "[main] run_command:"
        assert_received {:result, %{output: out, exit_code: 0}}
        assert String.trim(out) == "fallback_ok"
      after
        Process.register(pid, JidoClaw.Shell.SessionManager)
      end
    end
  end
end
