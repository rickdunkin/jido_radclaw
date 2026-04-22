defmodule JidoClaw.Shell.ServerRegistryTest do
  # async: false — ServerRegistry is a named singleton in the app
  # tree. Tests start their own instance via GenServer.start_link with
  # no name (see start_registry/1) so they don't compete with the
  # supervised copy.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_server_registry_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, ".jido"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  defp write_config(tmp, yaml) do
    File.write!(Path.join([tmp, ".jido", "config.yaml"]), yaml)
  end

  defp start_registry(tmp) do
    {:ok, pid} = GenServer.start_link(ServerRegistry, project_dir: tmp)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp call(pid, msg), do: GenServer.call(pid, msg)

  describe "parse_servers/1" do
    test "parses a full valid entry with defaults", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - name: staging
          host: web01.example.com
          user: deploy
      """)

      pid = start_registry(tmp)

      assert {:ok, entry} = call(pid, {:get, "staging"})
      assert entry.name == "staging"
      assert entry.host == "web01.example.com"
      assert entry.user == "deploy"
      assert entry.port == 22
      assert entry.cwd == "/"
      assert entry.env == %{}
      assert entry.shell == "sh"
      assert entry.connect_timeout == 10_000
      assert entry.auth_kind == :default
      assert entry.key_path == nil
      assert entry.password_env == nil
    end

    test "accepts all explicit fields", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - name: prod
          host: "1.2.3.4"
          user: root
          port: 2222
          key_path: "~/.ssh/id_ed25519"
          cwd: "/srv/app"
          env:
            RAILS_ENV: production
            WORKERS: 4
          shell: bash
          connect_timeout: 15000
      """)

      pid = start_registry(tmp)

      {:ok, entry} = call(pid, {:get, "prod"})
      assert entry.port == 2222
      assert entry.auth_kind == :key_path
      assert entry.key_path == "~/.ssh/id_ed25519"
      assert entry.cwd == "/srv/app"
      assert entry.env == %{"RAILS_ENV" => "production", "WORKERS" => "4"}
      assert entry.shell == "bash"
      assert entry.connect_timeout == 15_000
    end

    test "password_env sets auth_kind: :password", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
          password_env: MY_PW
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})
      assert entry.auth_kind == :password
      assert entry.password_env == "MY_PW"
    end
  end

  describe "validation — warn-and-skip" do
    test "skips entries with missing name/host/user", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - host: h
              user: u
            - name: ok
              host: h
              user: u
          """)

          pid = start_registry(tmp)
          assert call(pid, :list) == ["ok"]
        end)

      assert log =~ "missing required 'name'"
    end

    test "skips entry with empty name", %{tmp: tmp} do
      capture_log(fn ->
        write_config(tmp, """
        servers:
          - name: ""
            host: h
            user: u
          - name: valid
            host: h
            user: u
        """)

        pid = start_registry(tmp)
        assert call(pid, :list) == ["valid"]
      end)
    end

    test "skips entry when both key_path and password_env are set", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - name: bad
              host: h
              user: u
              key_path: "~/.ssh/id"
              password_env: PW
            - name: ok
              host: h
              user: u
          """)

          pid = start_registry(tmp)
          assert call(pid, :list) == ["ok"]
        end)

      assert log =~ "both key_path and password_env"
    end

    test "invalid port warns and defaults to 22", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - name: s
              host: h
              user: u
              port: 99999
          """)

          pid = start_registry(tmp)
          {:ok, entry} = call(pid, {:get, "s"})
          assert entry.port == 22
        end)

      assert log =~ "invalid port"
    end

    test "duplicate names — later entry wins with warning", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - name: dup
              host: first
              user: u
            - name: dup
              host: second
              user: u
          """)

          pid = start_registry(tmp)
          {:ok, entry} = call(pid, {:get, "dup"})
          assert entry.host == "second"
        end)

      assert log =~ "Duplicate server name"
    end

    test "non-map env dropped with warning", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - name: s
              host: h
              user: u
              env: "not-a-map"
          """)

          pid = start_registry(tmp)
          {:ok, entry} = call(pid, {:get, "s"})
          assert entry.env == %{}
        end)

      assert log =~ "env is not a map"
    end

    test "env coerces integers, drops other non-strings", %{tmp: tmp} do
      capture_log(fn ->
        write_config(tmp, """
        servers:
          - name: s
            host: h
            user: u
            env:
              PORT: 8080
              DEBUG: true
              NAME: "app"
        """)

        pid = start_registry(tmp)
        {:ok, entry} = call(pid, {:get, "s"})
        assert entry.env == %{"PORT" => "8080", "NAME" => "app"}
      end)
    end

    test "invalid connect_timeout warns and defaults", %{tmp: tmp} do
      log =
        capture_log(fn ->
          write_config(tmp, """
          servers:
            - name: s
              host: h
              user: u
              connect_timeout: -5
          """)

          pid = start_registry(tmp)
          {:ok, entry} = call(pid, {:get, "s"})
          assert entry.connect_timeout == 10_000
        end)

      assert log =~ "invalid connect_timeout"
    end
  end

  describe "get/1" do
    test "returns {:error, :not_found} for unknown server", %{tmp: tmp} do
      write_config(tmp, "servers: []\n")
      pid = start_registry(tmp)
      assert call(pid, {:get, "ghost"}) == {:error, :not_found}
    end
  end

  describe "list/0" do
    test "returns sorted names", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - {name: zeta, host: h, user: u}
        - {name: alpha, host: h, user: u}
        - {name: mid, host: h, user: u}
      """)

      pid = start_registry(tmp)
      assert call(pid, :list) == ["alpha", "mid", "zeta"]
    end

    test "returns [] when servers: missing", %{tmp: tmp} do
      write_config(tmp, "provider: ollama\n")
      pid = start_registry(tmp)
      assert call(pid, :list) == []
    end
  end

  describe "resolve_key_path/2" do
    test "absolute path passes through" do
      assert ServerRegistry.resolve_key_path("/abs/key", "/tmp/proj") == "/abs/key"
    end

    test "~-prefixed expands against $HOME" do
      expanded = ServerRegistry.resolve_key_path("~/.ssh/id", "/tmp/proj")
      assert String.starts_with?(expanded, System.user_home!() <> "/.ssh")
      refute String.contains?(expanded, "/tmp/proj")
    end

    test "relative resolves against project_dir" do
      resolved = ServerRegistry.resolve_key_path("keys/id", "/tmp/proj")
      assert resolved == "/tmp/proj/keys/id"
    end
  end

  describe "resolve_secrets/1" do
    test "password — present env var returns the value" do
      var = "JIDO_SR_TEST_#{System.unique_integer([:positive])}"
      System.put_env(var, "secret-val")
      on_exit(fn -> System.delete_env(var) end)

      entry = %ServerEntry{
        name: "s",
        host: "h",
        user: "u",
        port: 22,
        auth_kind: :password,
        password_env: var,
        cwd: "/",
        env: %{},
        shell: "sh",
        connect_timeout: 10_000
      }

      assert {:ok, %{password: "secret-val"}} = ServerRegistry.resolve_secrets(entry)
    end

    test "password — missing env var returns missing_env error" do
      var = "JIDO_SR_MISSING_#{System.unique_integer([:positive])}"
      System.delete_env(var)

      entry = %ServerEntry{
        name: "s",
        host: "h",
        user: "u",
        port: 22,
        auth_kind: :password,
        password_env: var,
        cwd: "/",
        env: %{},
        shell: "sh",
        connect_timeout: 10_000
      }

      assert {:error, {:missing_env, ^var}} = ServerRegistry.resolve_secrets(entry)
    end

    test "password — empty env var counts as missing" do
      var = "JIDO_SR_EMPTY_#{System.unique_integer([:positive])}"
      System.put_env(var, "")
      on_exit(fn -> System.delete_env(var) end)

      entry = %ServerEntry{
        name: "s",
        host: "h",
        user: "u",
        port: 22,
        auth_kind: :password,
        password_env: var,
        cwd: "/",
        env: %{},
        shell: "sh",
        connect_timeout: 10_000
      }

      assert {:error, {:missing_env, ^var}} = ServerRegistry.resolve_secrets(entry)
    end

    test "key_path / default return empty secrets map" do
      entry = %ServerEntry{
        name: "s",
        host: "h",
        user: "u",
        port: 22,
        auth_kind: :default,
        cwd: "/",
        env: %{},
        shell: "sh",
        connect_timeout: 10_000
      }

      assert ServerRegistry.resolve_secrets(entry) == {:ok, %{}}
    end
  end

  describe "reload/0 diff" do
    test "reports added/changed/removed names", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - {name: keep, host: h, user: u}
        - {name: old, host: h, user: u}
      """)

      pid = start_registry(tmp)
      # Sync: ensures handle_continue(:load) has run before we rewrite
      # the config. Without this, the second write races the continue
      # and the initial load picks up the new config instead.
      assert call(pid, :list) == ["keep", "old"]

      write_config(tmp, """
      servers:
        - {name: keep, host: new-host, user: u}
        - {name: brand-new, host: h, user: u}
      """)

      {:ok, diff} = call(pid, :reload)
      assert diff.added == ["brand-new"]
      assert diff.removed == ["old"]
      assert diff.changed == ["keep"]
    end

    test "empty diff when nothing changes", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - {name: s, host: h, user: u}
      """)

      pid = start_registry(tmp)
      assert call(pid, :list) == ["s"]
      {:ok, diff} = call(pid, :reload)
      assert diff == %{added: [], changed: [], removed: []}
    end
  end

  describe "build_ssh_config/3" do
    test "injects ssh_module/ssh_connection_module from Application env", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})

      Application.put_env(:jido_claw, :ssh_test_modules, %{
        ssh_module: FakeMod,
        ssh_connection_module: FakeConnMod
      })

      on_exit(fn -> Application.delete_env(:jido_claw, :ssh_test_modules) end)

      assert {:ok, config} = ServerRegistry.build_ssh_config(entry, tmp, %{"X" => "1"})
      assert config.host == "h"
      assert config.user == "u"
      assert config.port == 22
      assert config.env == %{"X" => "1"}
      assert config.ssh_module == FakeMod
      assert config.ssh_connection_module == FakeConnMod
    end

    test "omits ssh_module when Application env unset", %{tmp: tmp} do
      Application.delete_env(:jido_claw, :ssh_test_modules)

      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})

      assert {:ok, config} = ServerRegistry.build_ssh_config(entry, tmp, %{})
      refute Map.has_key?(config, :ssh_module)
      refute Map.has_key?(config, :ssh_connection_module)
    end

    test "key_path auth_kind includes resolved key_path, no password", %{tmp: tmp} do
      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
          key_path: "keys/id"
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})

      assert {:ok, config} = ServerRegistry.build_ssh_config(entry, tmp, %{})
      assert config.key_path == Path.join(tmp, "keys/id")
      refute Map.has_key?(config, :password)
    end

    test "password auth_kind pulls from env", %{tmp: tmp} do
      var = "JIDO_SR_BUILD_PW_#{System.unique_integer([:positive])}"
      System.put_env(var, "hunter2")
      on_exit(fn -> System.delete_env(var) end)

      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
          password_env: #{var}
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})

      assert {:ok, config} = ServerRegistry.build_ssh_config(entry, tmp, %{})
      assert config.password == "hunter2"
    end

    test "password auth_kind with missing env var returns missing_env", %{tmp: tmp} do
      var = "JIDO_SR_BUILD_MISSING_#{System.unique_integer([:positive])}"
      System.delete_env(var)

      write_config(tmp, """
      servers:
        - name: s
          host: h
          user: u
          password_env: #{var}
      """)

      pid = start_registry(tmp)
      {:ok, entry} = call(pid, {:get, "s"})

      assert {:error, {:missing_env, ^var}} = ServerRegistry.build_ssh_config(entry, tmp, %{})
    end
  end
end
