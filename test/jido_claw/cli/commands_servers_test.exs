defmodule JidoClaw.CLI.CommandsServersTest do
  # async: false — ServerRegistry and SessionManager are named
  # singletons. Tests share the supervised instances; parallel cases
  # would trample each other's server fixtures and SSH cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.CLI.Commands
  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Test.FakeSSH
  alias JidoClaw.VFS.Workspace

  defp base_state(tmp \\ nil) do
    cwd = tmp || File.cwd!()

    %{
      session_id: "commands-servers-test-#{System.unique_integer([:positive])}",
      profile: "default",
      strategy: "auto",
      cwd: cwd,
      config: %{},
      model: "test:model"
    }
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_cmd_servers_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      ServerRegistry.replace_servers_for_test(%{})
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "/servers (bare) and /servers list" do
    test "renders empty state when no servers are declared" do
      ServerRegistry.replace_servers_for_test(%{})

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers", base_state())
        end)

      assert output =~ "Declared Servers"
      assert output =~ "No servers declared"
    end

    test "renders default auth_kind row as unchecked" do
      ServerRegistry.replace_servers_for_test(%{
        "agent-srv" => %ServerEntry{
          name: "agent-srv",
          host: "agent.example.com",
          user: "ops",
          port: 22,
          auth_kind: :default,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state())
        end)

      assert output =~ "agent-srv"
      assert output =~ "ops@agent.example.com:22"
      assert output =~ "default"
      assert output =~ "unchecked"
      assert output =~ "0 env vars"
    end

    test "renders password auth_kind row as ok when env var is set" do
      var = "JIDO_SRV_PW_OK_#{System.unique_integer([:positive])}"
      System.put_env(var, "secret")
      on_exit(fn -> System.delete_env(var) end)

      ServerRegistry.replace_servers_for_test(%{
        "prod" => %ServerEntry{
          name: "prod",
          host: "prod.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :password,
          password_env: var,
          cwd: "/",
          env: %{"FOO" => "bar"},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state())
        end)

      assert output =~ "prod"
      assert output =~ "password"
      assert output =~ "ok"
      assert output =~ "1 env var"
    end

    test "renders password auth_kind row as missing_env when env var is unset", %{tmp: tmp} do
      var = "JIDO_SRV_PW_MISSING_#{System.unique_integer([:positive])}"
      System.delete_env(var)

      ServerRegistry.replace_servers_for_test(%{
        "stale" => %ServerEntry{
          name: "stale",
          host: "stale.example.com",
          user: "root",
          port: 22,
          auth_kind: :password,
          password_env: var,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state(tmp))
        end)

      assert output =~ "stale"
      assert output =~ "password"
      assert output =~ "missing_env"
    end

    test "renders key_path row as ok when key file exists", %{tmp: tmp} do
      key_path = Path.join(tmp, "id_test")
      File.write!(key_path, "fake-key-content")

      ServerRegistry.replace_servers_for_test(%{
        "ok-key" => %ServerEntry{
          name: "ok-key",
          host: "ok.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :key_path,
          key_path: key_path,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state(tmp))
        end)

      assert output =~ "ok-key"
      assert output =~ "key_path"
      assert output =~ "ok"
    end

    test "renders key_path row as missing_key when key file does not exist", %{tmp: tmp} do
      missing_key = Path.join(tmp, "does-not-exist")

      ServerRegistry.replace_servers_for_test(%{
        "miss-key" => %ServerEntry{
          name: "miss-key",
          host: "miss.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :key_path,
          key_path: missing_key,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state(tmp))
        end)

      assert output =~ "miss-key"
      assert output =~ "missing_key"
    end

    test "renders key_path row as unreadable_key when path is a directory", %{tmp: tmp} do
      # Pointing key_path at a directory yields {:error, :eisdir} from
      # File.read/1 — exercises the :unreadable_key branch without
      # chmod games (which are flaky on root-owned containers / WSL).
      ServerRegistry.replace_servers_for_test(%{
        "bad-key" => %ServerEntry{
          name: "bad-key",
          host: "bad.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :key_path,
          key_path: tmp,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers list", base_state(tmp))
        end)

      assert output =~ "bad-key"
      assert output =~ "unreadable_key"
    end
  end

  describe "/servers current" do
    test "is an alias for list" do
      ServerRegistry.replace_servers_for_test(%{
        "alpha" => %ServerEntry{
          name: "alpha",
          host: "alpha.example.com",
          user: "ops",
          port: 22,
          auth_kind: :default,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers current", base_state())
        end)

      assert output =~ "Declared Servers"
      assert output =~ "alpha"
    end
  end

  describe "/servers test <name>" do
    setup %{tmp: tmp} do
      FakeSSH.bind_test_pid()
      FakeSSH.set_mode(:normal)

      Application.put_env(:jido_claw, :ssh_test_modules, %{
        ssh_module: FakeSSH,
        ssh_connection_module: FakeSSH
      })

      workspace_id = "cmd-servers-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = SessionManager.stop_session(workspace_id)
        _ = Workspace.teardown(workspace_id)
        Application.delete_env(:jido_claw, :ssh_test_modules)
        FakeSSH.clear_mode()
        FakeSSH.clear_test_pid()
      end)

      state = %{base_state(tmp) | session_id: workspace_id}
      {:ok, state: state}
    end

    test "prints reachable on successful run", %{state: state} do
      ServerRegistry.replace_servers_for_test(%{
        "staging" => %ServerEntry{
          name: "staging",
          host: "staging.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :default,
          cwd: "/srv/app",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers test staging", state)
        end)

      assert output =~ "staging"
      assert output =~ "reachable"
    end

    test "prints SSHError-formatted failure for unknown server", %{state: state} do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers test ghost", state)
        end)

      assert output =~ "ghost"
      assert output =~ "not declared"
    end

    test "prints failure when connect refused", %{state: state} do
      ServerRegistry.replace_servers_for_test(%{
        "broken" => %ServerEntry{
          name: "broken",
          host: "broken.example.com",
          user: "deploy",
          port: 22,
          auth_kind: :default,
          cwd: "/",
          env: %{},
          shell: "sh",
          connect_timeout: 10_000
        }
      })

      FakeSSH.set_mode(:connect_error)

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers test broken", state)
        end)

      assert output =~ "broken"
      assert output =~ "connection refused"
    end
  end

  describe "/servers (malformed)" do
    test "bogus sub-command prints usage" do
      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/servers garbage garbage garbage", base_state())
        end)

      assert output =~ "Usage:"
      assert output =~ "/servers"
    end
  end
end
