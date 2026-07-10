defmodule JidoClaw.Tools.RunCommandTest do
  use ExUnit.Case, async: false

  import JidoClaw.TenantCase,
    only: [seed_full: 1, actor_for: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Forge.Harness
  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Test.{FakeSSH, ForgeStub, StubSandbox}
  alias JidoClaw.Tools.FetchOutput
  alias JidoClaw.Tools.OutputShaper
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
      assert {:error, %{message: message}} =
               RunCommand.run(%{command: "sleep 10", timeout: 100}, %{})

      assert message =~ "timed out"
    end

    test "should complete within timeout when command finishes in time" do
      assert {:ok, result} = RunCommand.run(%{command: "echo fast", timeout: 5_000}, %{})

      assert String.trim(result.output) == "fast"
    end

    test "a timed-out command does not poison the next command's output" do
      assert {:error, %{message: message}} =
               RunCommand.run(%{command: "sleep 10", timeout: 100}, %{})

      assert message =~ "timed out"

      # The cancelled task lingers in its tree-kill for ~50-500ms after the
      # session moved on. If it then sends a late `command_finished`, the
      # session server re-broadcasts it under this command, which would
      # return `""` here — and shift every later command's output by one.
      # The 1s sleep keeps this command collecting across that window.
      assert {:ok, result} = RunCommand.run(%{command: "sleep 1; echo aftermath"}, %{})

      assert String.trim(result.output) == "aftermath"
    end

    test "a stale outer action deadline refuses the queued command before launch" do
      marker =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_stale_command_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(marker) end)

      context = %{
        __jido_deadline_ms__: System.monotonic_time(:millisecond) - 1,
        tool_context: %{
          workspace_id: "stale-#{System.unique_integer([:positive])}",
          project_dir: System.tmp_dir!()
        }
      }

      assert {:error, %{code: :host_deadline_exceeded, details: %{retry: false}}} =
               RunCommand.run(%{command: "printf stale > #{marker}"}, context)

      refute File.exists?(marker)
    end

    test "Jido.Exec deadline is converted to an inner cancel, not an outer timeout" do
      workspace_id = "outer-deadline-#{System.unique_integer([:positive])}"

      context = %{
        tool_context: %{workspace_id: workspace_id, project_dir: System.tmp_dir!()}
      }

      on_exit(fn -> SessionManager.stop_session(workspace_id) end)

      assert {:error, err} =
               Jido.Exec.run(
                 RunCommand,
                 %{command: "sleep 5"},
                 context,
                 timeout: 1_800,
                 max_retries: 0
               )

      assert err.details.code == :host_command_timeout
      assert get_in(err.details, [:details, :retry]) == false
      refute match?(%Jido.Action.Error.TimeoutError{}, err)

      # The manager cancelled and drained the first command before returning;
      # the persistent session is immediately usable rather than left busy.
      assert {:ok, %{output: output, exit_code: 0}} =
               RunCommand.run(
                 %{command: "echo recovered", workspace_id: workspace_id},
                 context
               )

      assert String.trim(output) == "recovered"
    end

    test "a command timeout is non-retryable at Jido.Exec's action layer" do
      marker =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_timeout_once_#{System.unique_integer([:positive])}"
        )

      workspace_id = "timeout-once-#{System.unique_integer([:positive])}"

      context = %{
        tool_context: %{workspace_id: workspace_id, project_dir: System.tmp_dir!()}
      }

      on_exit(fn ->
        SessionManager.stop_session(workspace_id)
        File.rm(marker)
      end)

      # Default max_retries is intentionally left enabled. Without the
      # `retry: false` result this mutating prefix executes twice.
      assert {:error, err} =
               Jido.Exec.run(
                 RunCommand,
                 %{command: "printf x >> #{marker}; sleep 5", timeout: 100},
                 context,
                 timeout: 5_000
               )

      assert err.details.code == :host_command_timeout
      assert get_in(err.details, [:details, :retry]) == false
      assert File.read!(marker) == "x"
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
      assert_receive {:fake_ssh, {:exec, _, _, command}}
      assert command =~ "echo via-tool"
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
      assert {:error, %{message: message}} =
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
        assert {:error, %{message: message}} =
                 RunCommand.run(
                   %{command: "echo nope", backend: "ssh", server: "staging"},
                   %{}
                 )

        assert message =~ "SSH requires SessionManager"
      after
        Process.register(pid, JidoClaw.Shell.SessionManager)
      end
    end

    test "host/vfs paths return error when SessionManager is down" do
      pid = Process.whereis(JidoClaw.Shell.SessionManager)

      Process.unregister(JidoClaw.Shell.SessionManager)

      try do
        assert {:error, %{message: message}} = RunCommand.run(%{command: "echo ok"}, %{})
        assert message =~ "SessionManager is not running"
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

        original_gl = elem(Process.info(display_pid, :group_leader), 1)
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

      assert {:error,
              %{
                code: :output_limit_exceeded,
                message: "output_limit_exceeded",
                details: %{context: ctx, type: "Jido.Shell.Error"}
              }} =
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

    test "SessionManager outage refuses stream_to_display without touching Display" do
      pid = Process.whereis(JidoClaw.Shell.SessionManager)
      Process.unregister(JidoClaw.Shell.SessionManager)

      try do
        io =
          capture_streaming(fn ->
            response =
              RunCommand.run(
                %{command: "echo fallback_refused", stream_to_display: true, timeout: 5_000},
                %{}
              )

            send(self(), {:response, response})
          end)

        refute io =~ "[main] run_command:"
        assert_received {:response, {:error, %{message: message}}}
        assert message =~ "SessionManager is not running"
      after
        Process.register(pid, JidoClaw.Shell.SessionManager)
      end
    end
  end

  describe "output shaping integration" do
    setup do
      sandbox_pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

      original = Application.get_env(:jido_claw, :output_shaping, [])
      Application.put_env(:jido_claw, :output_shaping, Keyword.merge(original, enabled?: true))

      workspace_id = "rc-shape-#{System.unique_integer([:positive])}"

      dir =
        Path.join(System.tmp_dir!(), "jido_claw_fake_mix_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      write_fake_mix!(dir)

      on_exit(fn ->
        Application.put_env(:jido_claw, :output_shaping, original)
        _ = SessionManager.stop_session(workspace_id)
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(dir)
        Sandbox.stop_owner(sandbox_pid)
      end)

      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "rc-shape")

      context = %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: session.id,
          actor: actor_for(tenant_id),
          workspace_id: workspace_id,
          project_dir: dir
        }
      }

      {:ok, workspace_id: workspace_id, dir: dir, context: context, tenant_id: tenant_id}
    end

    # A fake `mix` ahead of the real one on PATH: emits ~20KB of canned
    # ExUnit output — over the legacy 10KB cap (proving the larger
    # capture), under the legacy 50KB backend valve (so the no-tenant
    # regression run completes instead of erroring).
    defp write_fake_mix!(dir) do
      dots = String.duplicate(".", 18_000)

      script = """
      #!/bin/sh
      cat <<'FAKE_MIX_EOF'
      Running ExUnit with seed: 4242, max_cases: 8

      #{dots}

        1) test shaped end to end (FakeSuiteTest)
           test/fake_suite_test.exs:7
           ** (RuntimeError) intentional fixture failure
           stacktrace:
             test/fake_suite_test.exs:8: (test)

      Finished in 2.0 seconds (1.0s async, 1.0s sync)
      42 tests, 1 failure

      Randomized with seed 4242
      FAKE_MIX_EOF
      exit 2
      """

      path = Path.join(dir, "mix")
      File.write!(path, script)
      File.chmod!(path, 0o755)
    end

    test "mix test output is shaped with a fetchable ref", %{
      dir: dir,
      workspace_id: ws,
      context: context
    } do
      assert {:ok, result} =
               RunCommand.run(
                 %{command: "PATH=#{dir}:$PATH mix test", workspace_id: ws, timeout: 15_000},
                 context
               )

      assert result.exit_code == 2
      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert result.summary.failed == 1

      # The 18KB dots line is gone; the failure block survives verbatim.
      assert result.output =~ "mix test — 41 passed, 1 failed"
      assert result.output =~ "1) test shaped end to end (FakeSuiteTest)"
      assert result.output =~ "** (RuntimeError) intentional fixture failure"
      refute result.output =~ String.duplicate(".", 1_000)
      assert result.output =~ "fetch_output ref=#{result.output_ref}"

      # Roundtrip: the stored full output is fetchable and grep-able.
      assert {:ok, fetched} =
               FetchOutput.run(%{ref: result.output_ref, grep: "intentional fixture"}, context)

      assert fetched.returned_lines == 1
      assert fetched.content =~ "intentional fixture failure"

      assert {:ok, full} = FetchOutput.run(%{ref: result.output_ref, head: 5}, context)
      assert full.content =~ "Running ExUnit with seed: 4242"
    end

    test "no tenant in scope falls back to legacy 10KB truncation, unshaped", %{
      dir: dir,
      workspace_id: ws
    } do
      assert {:ok, result} =
               RunCommand.run(
                 %{command: "PATH=#{dir}:$PATH mix test", workspace_id: ws, timeout: 15_000},
                 %{tool_context: %{workspace_id: ws, project_dir: dir}}
               )

      refute Map.has_key?(result, :shaped)
      refute Map.has_key?(result, :output_ref)

      assert byte_size(result.output) <=
               10_000 + byte_size(SessionManager.truncation_note(false))

      assert String.ends_with?(result.output, SessionManager.truncation_note(false))
    end
  end

  describe "docker bridge routing (AR-8b-2 F2)" do
    setup do
      {:ok, client, _id} = StubSandbox.create()
      # notify: self() — setup runs in the test process, so the async teardown's
      # {:forge_stub_stopped, _} lands in the test mailbox for assert_receive.
      cleanup = ForgeStub.install(client: client, notify: self())
      on_exit(cleanup)
      {:ok, client: client}
    end

    test "routes a success into the Forge session and adapts {out, code} → a map", %{
      client: client
    } do
      StubSandbox.program_exec(client, {"hello from docker\n", 0})

      assert {:ok, result} = RunCommand.run(%{command: "echo hi", timeout: 5_000}, docker_ctx())
      assert result.output == "hello from docker\n"
      assert result.exit_code == 0

      # No outer Jido deadline on a direct call → inner timeout == requested.
      assert [%{opts: opts}] = ForgeStub.execs()
      assert opts[:timeout] == 5_000
    end

    test "ignores a model-supplied backend: \"ssh\" — no preempt, no spurious SSH error", %{
      client: client
    } do
      StubSandbox.program_exec(client, {"ok", 0})

      # On the host path `backend: "ssh"` with no server raises; under :docker the
      # branch short-circuits before coerce_backend/validate_backend_server.
      assert {:ok, %{exit_code: 0}} =
               RunCommand.run(%{command: "x", backend: "ssh", timeout: 5_000}, docker_ctx())
    end

    test "an absent session hard-fails (non-retryable, never SessionManager)" do
      ForgeStub.set_absent(:not_found)

      assert {:error, err} = RunCommand.run(%{command: "echo hi", timeout: 5_000}, docker_ctx())
      assert err.code == :sandbox_unavailable
    end

    test "an omitted :timeout defaults to 30_000 inside the bridge", %{client: client} do
      StubSandbox.program_exec(client, {"x", 0})

      assert {:ok, _} = RunCommand.run(%{command: "x"}, docker_ctx())
      assert [%{opts: opts}] = ForgeStub.execs()
      assert opts[:timeout] == 30_000
    end

    test "a manufactured timeout taints: tears the session down, follow-up hard-fails", %{
      client: client
    } do
      # inner == requested == 5_000 (direct call), so this is the exact match.
      StubSandbox.program_exec(client, {"timeout after 5000ms", 124})

      assert {:error, err} = RunCommand.run(%{command: "sleep 999", timeout: 5_000}, docker_ctx())
      assert err.code == :sandbox_command_timeout

      # Teardown is now detached — rendezvous with the async stop before asserting
      # its effects (recorded call + flipped exec_result).
      assert_receive {:forge_stub_stopped, "sess-x"}, 2_000

      # stop_session ran (best-effort teardown of the in-container zombie).
      assert ForgeStub.stops() != []

      # The torn-down session is now absent → a follow-up hard-fails.
      assert {:error, %{code: :sandbox_unavailable}} =
               RunCommand.run(%{command: "echo retry", timeout: 5_000}, docker_ctx())
    end

    test "a Forge.exec that exits {:timeout, _} converges to the same taint outcome", %{
      client: client
    } do
      # Box in the residual-catch (exit({:timeout, _})) delivery path with the same
      # fast-return discriminant as the manufactured-124 test below.
      ForgeStub.set_stop_delay(1_000)
      StubSandbox.program_exec(client, fn -> exit({:timeout, :simulated}) end)

      t0 = System.monotonic_time(:millisecond)
      assert {:error, err} = RunCommand.run(%{command: "x", timeout: 5_000}, docker_ctx())
      assert err.code == :sandbox_command_timeout
      elapsed = System.monotonic_time(:millisecond) - t0

      # Decoupled: the sync code blocked here for the full 1s stop; async returns in ms.
      assert elapsed < 400, "expected a fast return; got #{elapsed}ms (teardown blocked it)"

      # The stop still runs, asynchronously.
      assert_receive {:forge_stub_stopped, "sess-x"}, 3_000
    end

    test "taint teardown is detached — the bridge returns before a slow stop_session", %{
      client: client
    } do
      ForgeStub.set_stop_delay(1_000)
      StubSandbox.program_exec(client, {"timeout after 5000ms", 124})

      t0 = System.monotonic_time(:millisecond)

      assert {:error, %{code: :sandbox_command_timeout}} =
               RunCommand.run(%{command: "sleep 999", timeout: 5_000}, docker_ctx())

      elapsed = System.monotonic_time(:millisecond) - t0

      # Decoupled: the sync code blocked here for the full 1s stop; async returns in ms.
      assert elapsed < 400, "expected a fast return; got #{elapsed}ms (teardown blocked it)"

      # The stop still runs, asynchronously.
      assert_receive {:forge_stub_stopped, "sess-x"}, 3_000
    end

    test "full Jido.Exec.run: a tiny deadline budget yields the bridge's :sandbox_deadline_exceeded, never launched" do
      # 3_000ms outer deadline ⇒ budget below the min-viable threshold ⇒ refuse
      # before any Forge.exec call. This proves :__jido_deadline_ms__ rides
      # Tools.Action + MCPScope.wrap into the bridge. Jido.Exec wraps the bridge
      # map into a Jido.Action.Error struct, so the code lands under :details.
      ctx = %{tool_context: %{sandbox: :docker, forge_session_key: "sess-x"}}

      assert {:error, err} =
               Jido.Exec.run(RunCommand, %{command: "x"}, ctx, timeout: 3_000, max_retries: 0)

      assert err.details.code == :sandbox_deadline_exceeded
      refute match?(%Jido.Action.Error.TimeoutError{}, err)
      assert ForgeStub.execs() == []
    end

    test "full Jido.Exec.run: an exec timeout surfaces the bridge's code, not Jido's timeout_error",
         %{client: client} do
      StubSandbox.program_exec(client, fn -> exit({:timeout, :simulated}) end)
      ctx = %{tool_context: %{sandbox: :docker, forge_session_key: "sess-x"}}

      # max_retries: 0 keeps this focused on the single bridge attempt + its code.
      # (The default-retry tests below prove the error is also non-retryable at the
      # jido_action layer, so a retry would not re-enter the session anyway.)
      assert {:error, err} =
               Jido.Exec.run(RunCommand, %{command: "x"}, ctx, timeout: 30_000, max_retries: 0)

      assert err.details.code == :sandbox_command_timeout
      refute match?(%Jido.Action.Error.TimeoutError{}, err)
    end

    test "full Jido.Exec.run with default retry: a timeout taint is non-retryable at the jido_action layer — no re-exec",
         %{client: client} do
      # No max_retries override → jido_action's default (1). Jido.Exec wraps the
      # bridge map into an ExecutionFailureError that DEFAULTS to retryable unless
      # details carries retry: false. Without that hint the retry re-runs exec —
      # and with detached teardown the re-entry hits the still-live session before
      # the async stop lands. The bridge error must be non-retryable at this layer.
      StubSandbox.program_exec(client, fn -> exit({:timeout, :simulated}) end)
      ctx = %{tool_context: %{sandbox: :docker, forge_session_key: "sess-x"}}

      assert {:error, err} = Jido.Exec.run(RunCommand, %{command: "x"}, ctx, timeout: 30_000)

      # THE regression: exactly one exec — the retry must not fire.
      assert [_] = ForgeStub.execs()
      assert err.details.code == :sandbox_command_timeout
    end

    test "full Jido.Exec.run with default retry: an output-limit taint is non-retryable — no re-exec",
         %{client: client} do
      # Anchored-regex match (not the inner-exact 124), so it taints regardless of
      # the deadline-derived inner timeout. Same default-retry non-retryability.
      StubSandbox.program_exec(client, {"output limit exceeded after 99999 bytes", 153})
      ctx = %{tool_context: %{sandbox: :docker, forge_session_key: "sess-x"}}

      assert {:error, err} = Jido.Exec.run(RunCommand, %{command: "x"}, ctx, timeout: 30_000)

      assert [_] = ForgeStub.execs()
      assert err.details.code == :sandbox_output_limit
    end
  end

  describe "docker timeout cushion + streaming predicate (AR-8b-2 F2)" do
    test "Harness.exec_call_timeout/1 cushions the outer call past the inner timeout" do
      cushion = JidoClaw.Forge.exec_timeout_cushion_ms()
      assert Harness.exec_call_timeout(timeout: 1_000) == 1_000 + cushion
      # A non-integer/absent inner timeout falls back to the legacy default first.
      assert Harness.exec_call_timeout([]) == 300_000 + cushion
    end

    test "effective_streaming?/2 is docker-scoped: false under :docker, delegates otherwise" do
      params = %{stream_to_display: true}
      docker = %{tool_context: %{sandbox: :docker}}
      host = %{tool_context: %{sandbox: :none}}

      refute OutputShaper.effective_streaming?(params, docker)
      assert OutputShaper.effective_streaming?(params, host)
      # /1 with no context delegates to the raw (non-docker) logic.
      assert OutputShaper.effective_streaming?(params)
    end
  end

  describe "docker streaming neutralization (AR-8b-2 F2)" do
    setup do
      sandbox_pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

      original = Application.get_env(:jido_claw, :output_shaping, [])
      Application.put_env(:jido_claw, :output_shaping, Keyword.merge(original, enabled?: true))

      {:ok, client, _id} = StubSandbox.create()
      cleanup = ForgeStub.install(client: client)

      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "rc-docker-stream")

      on_exit(fn ->
        cleanup.()
        Application.put_env(:jido_claw, :output_shaping, original)
        Sandbox.stop_owner(sandbox_pid)
      end)

      context = %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: session.id,
          actor: actor_for(tenant_id),
          sandbox: :docker,
          forge_session_key: "sess-x"
        }
      }

      {:ok, client: client, context: context}
    end

    test "stream_to_display: true is neutralized — oversized docker output is shaped + ref-backed",
         %{client: client, context: context} do
      # >32KB: a streamed result would hit OutputLimit's ref-less head-cut; the
      # docker predicate forces not-streaming → capture + shape + ref-store.
      big = String.duplicate("line of docker output\n", 2_000)
      StubSandbox.program_exec(client, {big, 0})

      assert {:ok, result} =
               RunCommand.run(
                 %{command: "noisy", stream_to_display: true, timeout: 5_000},
                 context
               )

      assert result.exit_code == 0
      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert result.output =~ "fetch_output ref=#{result.output_ref}"

      # Reversibility preserved: the full output is recoverable via the ref.
      assert {:ok, fetched} = FetchOutput.run(%{ref: result.output_ref, head: 1}, context)
      assert fetched.content =~ "line of docker output"
    end
  end

  defp docker_ctx(extra \\ %{}) do
    %{tool_context: Map.merge(%{sandbox: :docker, forge_session_key: "sess-x"}, extra)}
  end
end
