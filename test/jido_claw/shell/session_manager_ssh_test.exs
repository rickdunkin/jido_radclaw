defmodule JidoClaw.Shell.SessionManagerSSHTest do
  # async: false — SessionManager and ServerRegistry are named
  # singletons. Tests share the supervised instances; parallel cases
  # would trample each other's SSH session cache.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.ProfileManager
  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Test.FakeSSH
  alias JidoClaw.VFS.Workspace

  @staging %ServerEntry{
    name: "staging",
    host: "web01.example.com",
    user: "deploy",
    port: 22,
    auth_kind: :default,
    cwd: "/srv/app",
    env: %{"SERVER_VAR" => "server-side"},
    shell: "sh",
    connect_timeout: 10_000
  }

  @fixture_profiles %{
    "default" => %{"JIDO_SSH_SMOKE" => "base"},
    "staging" => %{"JIDO_SSH_SMOKE" => "staging-value"}
  }

  setup do
    FakeSSH.bind_test_pid()
    FakeSSH.set_mode(:normal)

    Application.put_env(:jido_claw, :ssh_test_modules, %{
      ssh_module: FakeSSH,
      ssh_connection_module: FakeSSH
    })

    ServerRegistry.replace_servers_for_test(%{"staging" => @staging})
    ProfileManager.replace_profiles_for_test(@fixture_profiles)

    workspace_id = "sm-ssh-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_sm_ssh_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
      Application.delete_env(:jido_claw, :ssh_test_modules)
      ProfileManager.replace_profiles_for_test(%{})
      ProfileManager.clear_active_for_test()
      ServerRegistry.replace_servers_for_test(%{})
      FakeSSH.clear_mode()
      FakeSSH.clear_test_pid()
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  # -- Happy path ------------------------------------------------------------

  describe "run/4 with backend: :ssh" do
    test "executes remote command via FakeSSH", %{workspace_id: ws, tmp: tmp} do
      assert {:ok, %{output: output, exit_code: 0}} =
               SessionManager.run(ws, "echo hi", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert output =~ "ok"
      assert_receive {:fake_ssh, {:connect, _, 22, _, _}}
      assert_receive {:fake_ssh, {:exec, _, _, _cmd}}
    end

    test "preserves remote non-zero exit code", %{workspace_id: ws, tmp: tmp} do
      assert {:ok, %{output: output, exit_code: 42}} =
               SessionManager.run(ws, "__fake_nonzero__", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert output =~ "oops"
    end

    test "reuses existing session across calls — one connect, two exec", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, _} =
               SessionManager.run(ws, "echo one", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert_receive {:fake_ssh, {:connect, _, _, _, _}}
      assert_receive {:fake_ssh, {:exec, _, _, _}}

      assert {:ok, _} =
               SessionManager.run(ws, "echo two", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      # Second call: another exec, but no second connect.
      assert_receive {:fake_ssh, {:exec, _, _, _}}
      refute_received {:fake_ssh, {:connect, _, _, _, _}}
    end
  end

  # -- Error paths -----------------------------------------------------------

  describe "output limit" do
    test "output larger than cap aborts with SSH-formatted error", %{workspace_id: ws, tmp: tmp} do
      assert {:error, message} =
               SessionManager.run(ws, "__fake_output_overflow__", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert message =~ "SSH to staging"
      assert message =~ "output limit exceeded"
    end
  end

  describe "connection errors" do
    test "connect refused formats SSH error", %{workspace_id: ws, tmp: tmp} do
      FakeSSH.set_mode(:connect_error)

      assert {:error, message} =
               SessionManager.run(ws, "true", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert message =~ "SSH to staging failed: connection refused"
    end

    test "connect refused does not cache; retry re-attempts", %{workspace_id: ws, tmp: tmp} do
      FakeSSH.set_mode(:connect_error)

      assert {:error, _} =
               SessionManager.run(ws, "true", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert_receive {:fake_ssh, {:connect_error, _, _}}

      # Fix the "network"; next call connects successfully.
      FakeSSH.set_mode(:normal)

      assert {:ok, _} =
               SessionManager.run(ws, "echo recovered", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert_receive {:fake_ssh, {:connect, _, _, _, _}}
    end

    test "reconnect failure on dead cached connection formats via SSHError", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # 1. Happy-path establish — session cached, connection alive.
      assert {:ok, _} =
               SessionManager.run(ws, "echo cached", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert_receive {:fake_ssh, {:connect, _, _, _, conn_pid}}
      drain_fake_ssh_messages()

      # 2. Kill the underlying "SSH" conn so Process.alive?/1 returns false
      #    inside the backend's `ensure_connected/1`.
      Process.exit(conn_pid, :kill)

      # Yield so the exit is processed before we continue.
      refute Process.alive?(conn_pid)

      # 3. Flip FakeSSH to reject the next connect.
      FakeSSH.set_mode(:connect_error)

      # 4. Next call triggers a synchronous reconnect inside
      #    ShellSessionServer.run_command, which fails — the error must
      #    render through SSHError.format/2 (not "Command rejected: ...").
      assert {:error, message} =
               SessionManager.run(ws, "echo after-death", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert message =~ "SSH to staging failed: connection refused"
      refute message =~ "Command rejected"
    end
  end

  describe "registry miss" do
    test "unknown server name → 'not declared' error", %{workspace_id: ws, tmp: tmp} do
      assert {:error, message} =
               SessionManager.run(ws, "true", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "ghost"
               )

      assert message =~ "SSH server 'ghost' not declared"
    end
  end

  describe "secret resolution" do
    test "missing password_env reports clean error", %{workspace_id: ws, tmp: tmp} do
      missing_var = "JIDO_SM_SSH_MISSING_#{System.unique_integer([:positive])}"
      System.delete_env(missing_var)

      pw_entry = %ServerEntry{
        @staging
        | auth_kind: :password,
          password_env: missing_var
      }

      ServerRegistry.replace_servers_for_test(%{"staging" => pw_entry})

      assert {:error, message} =
               SessionManager.run(ws, "true", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert message =~ "env var #{missing_var} is not set"
    end

    test "empty password_env treated as missing", %{workspace_id: ws, tmp: tmp} do
      var = "JIDO_SM_SSH_EMPTY_#{System.unique_integer([:positive])}"
      System.put_env(var, "")
      on_exit(fn -> System.delete_env(var) end)

      pw_entry = %ServerEntry{
        @staging
        | auth_kind: :password,
          password_env: var
      }

      ServerRegistry.replace_servers_for_test(%{"staging" => pw_entry})

      assert {:error, message} =
               SessionManager.run(ws, "true", 5_000,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )

      assert message =~ "env var #{var} is not set"
    end
  end

  # -- Profile env propagation ----------------------------------------------

  describe "profile switch on live SSH session" do
    test "command after switch sees new profile env, server var survives", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # First call: establish SSH session with default profile env.
      {:ok, _} =
        SessionManager.run(ws, "__fake_echo_env__", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:exec, _, _, cmd1}}
      # SSH backend wraps env values in single quotes for shell safety
      # (`env VAR='value' sh -lc ...`).
      assert cmd1 =~ "JIDO_SSH_SMOKE='base'"
      assert cmd1 =~ "SERVER_VAR='server-side'"

      # Switch profile → live SSH session should see staging env on next call.
      {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      {:ok, _} =
        SessionManager.run(ws, "__fake_echo_env__", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:exec, _, _, cmd2}}
      assert cmd2 =~ "JIDO_SSH_SMOKE='staging-value'"
      # Server-declared var must survive — not in either profile.
      assert cmd2 =~ "SERVER_VAR='server-side'"
    end

    test "SSH-only workspace still gets profile env propagation", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # First call: SSH only (no host/VFS).
      {:ok, _} =
        SessionManager.run(ws, "__fake_echo_env__", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      # Drain previous exec messages.
      drain_fake_ssh_messages()

      {:ok, _} =
        SessionManager.run(ws, "__fake_echo_env__", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:exec, _, _, cmd}}
      assert cmd =~ "JIDO_SSH_SMOKE='staging-value'"
    end

    test "host/VFS env unchanged when SSH update fails during profile switch", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Bootstrap host + SSH.
      {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      {:ok, _} =
        SessionManager.run(ws, "echo ok", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      fail_ssh_writer = fn _id, _env -> {:error, :induced} end
      real_writer = &Jido.Shell.ShellSession.update_env/2

      # Manually drive update_env with an injected SSH writer that
      # fails. Host/VFS should succeed; SSH failure must not roll host
      # back, and the SSH session should be evicted from cache.
      assert :ok =
               SessionManager.do_update_env(
                 ws,
                 [],
                 %{"JIDO_SSH_SMOKE" => "injected"},
                 host_writer: real_writer,
                 vfs_writer: real_writer,
                 ssh_writer: fail_ssh_writer
               )

      # Host should have the injected value (not rolled back).
      {:ok, host_env} = SessionManager.__host_env_for_test__(ws)
      assert host_env["JIDO_SSH_SMOKE"] == "injected"

      # Drain FakeSSH close_channel messages from the evicted session
      # before asserting the next call reconnects.
      drain_fake_ssh_messages()

      # Next SSH call should re-create the session.
      {:ok, _} =
        SessionManager.run(ws, "echo reconnected", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:connect, _, _, _, _}}
    end
  end

  # -- Session invalidation --------------------------------------------------

  describe "invalidate_ssh_sessions/1" do
    test "tears down cached session; next run reconnects", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:connect, _, _, _, _}}

      :ok = SessionManager.invalidate_ssh_sessions(["staging"])
      drain_fake_ssh_messages()

      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      # Fresh connect after invalidation.
      assert_receive {:fake_ssh, {:connect, _, _, _, _}}
    end

    test "no-op for unknown server names", %{workspace_id: ws, tmp: tmp} do
      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:connect, _, _, _, _}}

      :ok = SessionManager.invalidate_ssh_sessions(["nonexistent"])
      drain_fake_ssh_messages()

      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      # Cache hit — no new connect.
      refute_receive {:fake_ssh, {:connect, _, _, _, _}}, 50
    end
  end

  describe "project_dir drift" do
    test "new project_dir tears down stale session and rebuilds", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      assert_receive {:fake_ssh, {:connect, _, _, _, conn_pid}}
      drain_fake_ssh_messages()

      other =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_sm_ssh_other_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)

      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: other,
          backend: :ssh,
          server: "staging"
        )

      # New connect for the rebuilt session. ShellSessionServer doesn't
      # trap exits, so the old backend's terminate isn't called on
      # shutdown — we assert the reconnect rather than a close message.
      assert_receive {:fake_ssh, {:connect, _, _, _, new_conn}}
      assert new_conn != conn_pid
    end
  end

  describe "stop/drop for SSH-only workspaces" do
    test "stop_session tears down SSH session when no host/vfs exists", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      session_id = ws <> ":ssh:staging"
      assert {:ok, _pid} = Jido.Shell.ShellSession.lookup(session_id)

      :ok = SessionManager.stop_session(ws)

      # Registry cleanup is async — the session pid is terminated
      # synchronously, but the Registry entry is removed via a :DOWN
      # monitor message shortly after. Poll briefly to avoid the race.
      assert_eventually(fn ->
        Jido.Shell.ShellSession.lookup(session_id) == {:error, :not_found}
      end)
    end

    test "drop_sessions tears down SSH session", %{workspace_id: ws, tmp: tmp} do
      {:ok, _} =
        SessionManager.run(ws, "true", 5_000,
          project_dir: tmp,
          backend: :ssh,
          server: "staging"
        )

      session_id = ws <> ":ssh:staging"
      assert {:ok, _pid} = Jido.Shell.ShellSession.lookup(session_id)

      :ok = SessionManager.drop_sessions(ws)

      assert_eventually(fn ->
        Jido.Shell.ShellSession.lookup(session_id) == {:error, :not_found}
      end)
    end
  end

  # -- Client-side call timeout ----------------------------------------------

  describe "call timeout budget" do
    test "SSH call timeout includes connect_timeout", %{workspace_id: ws, tmp: tmp} do
      # Slow-connecting server: bump connect_timeout so the client-side
      # GenServer.call budget is large. The actual FakeSSH connect is
      # instant, so this just verifies the computation doesn't reject
      # the call — a regression would surface as an exit with :timeout.
      slow_entry = %ServerEntry{@staging | connect_timeout: 30_000}
      ServerRegistry.replace_servers_for_test(%{"staging" => slow_entry})

      assert {:ok, %{exit_code: 0}} =
               SessionManager.run(ws, "echo fast", 500,
                 project_dir: tmp,
                 backend: :ssh,
                 server: "staging"
               )
    end
  end

  defp drain_fake_ssh_messages do
    receive do
      {:fake_ssh, _} -> drain_fake_ssh_messages()
    after
      0 -> :ok
    end
  end

  # Polls `fun` until it returns truthy or the deadline expires.
  # Used for Registry cleanup races (session termination is sync, but
  # the Registry entry clears via an async monitor :DOWN message).
  defp assert_eventually(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("assert_eventually timed out")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
    end
  end
end
