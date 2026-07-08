defmodule JidoClaw.Forge.Sandbox.DockerArgsTest do
  @moduledoc """
  sbx 0.34.0 arg shapes: workspaces are `sbx create` POSITIONALS (same-path,
  rw default / `:ro` suffix — the CLI has no `--mount`), network control is
  post-create `sbx policy` (no `--network` flag on create), and `run/4` rides
  `sbx exec` argv semantics (no `sbx run` agent dispatch). Precommit proves the
  args are EMITTED; the manual `:docker_sandbox` tier proves they are ENFORCED.
  `async: false` — mutates the global `:onecli` / `:forge_docker_sandbox` /
  `:sbx_finder` config.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.Sandbox.Docker

  setup do
    # Same-path world: the CA cert's parent DIRECTORY is the mounted
    # workspace (sbx 0.34.0 rejects file workspace positionals).
    ca_dir = Path.join(System.tmp_dir!(), "f2_ca_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(ca_dir)
    ca = Path.join(ca_dir, "onecli.crt")
    File.write!(ca, "CERT")

    prev_onecli = Application.get_env(:jido_claw, :onecli)
    prev_docker = Application.get_env(:jido_claw, :forge_docker_sandbox)

    Application.put_env(:jido_claw, :onecli,
      enabled: true,
      gateway_url: "http://localhost:10255",
      ca_cert_path: ca
    )

    Application.put_env(:jido_claw, :forge_docker_sandbox,
      extra_mounts: [{"/host/global", "/host/global", "ro"}]
    )

    on_exit(fn ->
      restore(:onecli, prev_onecli)
      restore(:forge_docker_sandbox, prev_docker)
      File.rm_rf(ca_dir)
    end)

    %{ca_dir: ca_dir, ca: ca}
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)

  # The mount POSITIONALS — everything after `create --name NAME AGENT WORKSPACE`.
  # An exact head match, so a shape change in the emitted args fails loudly here.
  defp mounts(["create", "--name", _name, _agent, _workspace | mount_positionals]),
    do: mount_positionals

  describe "build_create_args/4 — workspace positionals (sbx 0.34.0)" do
    test "mounts are trailing positionals after [agent, workspace]; no --mount/--network" do
      spec = %{network: :none, extra_mounts: [{"/proto/dir", "/proto/dir", "rw"}]}

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)

      assert ["create", "--name", "forge-x", "shell", "/tmp/ws" | positionals] = args
      refute "--mount" in args
      refute "--network" in args
      assert "/proto/dir" in positionals
    end

    test "isolate_global_config: true skips the global mounts", %{ca_dir: ca_dir} do
      spec = %{
        isolate_global_config: true,
        network: :none,
        extra_mounts: [{"/proto/dir", "/proto/dir", "rw"}]
      }

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)

      # No OneCLI CA-cert dir, no operator global :extra_mounts (a host-path
      # mount would survive the post-create deny-all policy).
      refute Enum.any?(mounts(args), &String.contains?(&1, ca_dir))
      refute "/host/global:ro" in mounts(args)

      # The prototype mount (spec-declared) IS present, rw = bare path.
      assert mounts(args) == ["/proto/dir"]
    end

    test "without the opt-out, the global mounts ARE layered (CA dir + operator mounts)", %{
      ca_dir: ca_dir
    } do
      spec = %{network: :none, extra_mounts: [{"/proto/dir", "/proto/dir", "rw"}]}

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)

      # The CA cert mounts as its parent DIRECTORY, same-path read-only
      # (sbx 0.34.0 rejects file workspace positionals — probe-verified).
      assert "#{ca_dir}:ro" in mounts(args)
      assert "/host/global:ro" in mounts(args)
      assert "/proto/dir" in mounts(args)
    end

    test "ro mounts get the :ro suffix, rw mounts are bare paths; atom and string modes" do
      spec = %{
        isolate_global_config: true,
        extra_mounts: [{"/a/b", "/a/b", :ro}, {"/c/d", "/c/d", "rw"}, {"/e/f", "/e/f", :rw}]
      }

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)
      assert mounts(args) == ["/a/b:ro", "/c/d", "/e/f"]
    end
  end

  describe "invalid mounts — the two-level contract" do
    test "create/1 returns {:error, {:invalid_mount, entry}} before any resource is created" do
      base = Path.join(System.tmp_dir!(), "f2_inv_mount_#{:erlang.unique_integer([:positive])}")
      prev = Application.get_env(:jido_claw, :forge_docker_sandbox)
      Application.put_env(:jido_claw, :forge_docker_sandbox, workspace_base: base)

      on_exit(fn ->
        restore(:forge_docker_sandbox, prev)
        File.rm_rf(base)
      end)

      # host≠container is inexpressible in sbx 0.34.0 (same-path only).
      spec = %{extra_mounts: [{"/host/a", "/container/b", "rw"}]}
      assert {:error, {:invalid_mount, {"/host/a", "/container/b", "rw"}}} = Docker.create(spec)

      # No workspace dir was created for the refused spec.
      refute File.exists?(base)
    end

    test "a relative mount path is refused (would resolve against sbx's cwd)" do
      assert {:error, {:invalid_mount, _}} =
               Docker.create(%{extra_mounts: [{"rel/path", "rel/path", "rw"}]})
    end

    test "an unknown mount mode is refused" do
      assert {:error, {:invalid_mount, _}} =
               Docker.create(%{extra_mounts: [{"/a/b", "/a/b", "rwx"}]})
    end

    test "an operator-global mount with host≠container fails create loudly" do
      prev = Application.get_env(:jido_claw, :forge_docker_sandbox)

      Application.put_env(:jido_claw, :forge_docker_sandbox,
        extra_mounts: [{"/host/global", "/container/global", "ro"}]
      )

      on_exit(fn -> restore(:forge_docker_sandbox, prev) end)

      assert {:error, {:invalid_mount, {"/host/global", "/container/global", "ro"}}} =
               Docker.create(%{})
    end

    test "build_create_args/4 raises on invalid data when called directly (defense in depth)" do
      assert_raise ArgumentError, ~r/invalid mount/, fn ->
        Docker.build_create_args("forge-x", "shell", "/tmp/ws", %{
          extra_mounts: [{"/host/a", "/container/b", "rw"}]
        })
      end
    end
  end

  describe "build_policy_args/3 — post-create network policy (sbx 0.34.0)" do
    test "deny-all egress for network: :none" do
      assert Docker.build_policy_args("deny", "forge-x", "**") ==
               ["policy", "deny", "network", "--sandbox", "forge-x", "**"]
    end

    test "per-sandbox allow rule for allow_network" do
      csv = "host.docker.internal:4567,localhost:4567"

      assert Docker.build_policy_args("allow", "forge-x", csv) ==
               ["policy", "allow", "network", "--sandbox", "forge-x", csv]
    end
  end

  describe "allow_network validation (the values become a policy CSV — fail closed)" do
    test "valid host[:port] entries pass" do
      assert Docker.valid_network_host?("host.docker.internal:4567")
      assert Docker.valid_network_host?("localhost")
      assert Docker.valid_network_host?("127.0.0.1:80")
    end

    test "wildcards, commas, blanks, whitespace, and non-binaries are rejected" do
      refute Docker.valid_network_host?("**")
      refute Docker.valid_network_host?("*.example.com")
      refute Docker.valid_network_host?("a,b")
      refute Docker.valid_network_host?("")
      refute Docker.valid_network_host?("host x")
      refute Docker.valid_network_host?("host:port")
      refute Docker.valid_network_host?(nil)
    end

    test "create/1 refuses an invalid allow_network entry before any resource" do
      assert {:error, {:invalid_allow_network, _}} = Docker.create(%{allow_network: ["**"]})

      assert {:error, {:invalid_allow_network, _}} =
               Docker.create(%{allow_network: "host.docker.internal"})
    end

    test "create/1 refuses network: :none combined with a non-empty allow_network" do
      spec = %{network: :none, allow_network: ["host.docker.internal:4567"]}
      assert {:error, {:contradictory_network_policy, _}} = Docker.create(spec)
    end
  end

  # The in-VM wrapper every exec rides: `exec "$0" "$@" </dev/null` (the sbx
  # client forwards its piped stdin — a stdin-reading command would hang to
  # timeout without the redirect), plus the `.forge_env` export loop when the
  # env file exists (`sbx exec --env-file` is INERT on 0.34.0 — probe-verified
  # — and `-e K=V` would put vault secrets on the host argv).
  @stdin_wrapper ~S(exec "$0" "$@" </dev/null)

  describe "build_exec_args/4 — --workdir + the in-VM wrapper" do
    test "emits --workdir <dir> when a workdir is stamped" do
      # A workspace dir with no `.forge_env` so the env prelude is skipped.
      args = Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", "/proto")

      assert args == [
               "exec",
               "--workdir",
               "/proto",
               "forge-x",
               "sh",
               "-c",
               @stdin_wrapper,
               "sh",
               "-c",
               "echo hi"
             ]
    end

    test "emits NO --workdir for a nil/blank workdir" do
      refute "--workdir" in Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", nil)
      refute "--workdir" in Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", "")
    end
  end

  describe "run/4 rides sbx exec (0.34.0 — the vendor CLI is an in-sandbox executable)" do
    setup do
      fake_sbx = Path.join(System.tmp_dir!(), "fake_sbx_#{:erlang.unique_integer([:positive])}")
      File.write!(fake_sbx, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
      File.chmod!(fake_sbx, 0o755)

      prev = Application.get_env(:jido_claw, :sbx_finder)
      Application.put_env(:jido_claw, :sbx_finder, fn "sbx" -> fake_sbx end)

      on_exit(fn ->
        restore(:sbx_finder, prev)
        File.rm(fake_sbx)
      end)

      :ok
    end

    test "run/4 execs into the harness-created sandbox with --workdir; opts[:name] is ignored" do
      client = %Docker{
        sandbox_name: "forge-run-x",
        workspace_dir: "/tmp/no_env_dir",
        sandbox_id: "x",
        workdir: "/repo"
      }

      {output, 0} = Docker.run(client, "claude", ["-p", "hi"], name: "other-session")

      assert String.split(output, "\n", trim: true) ==
               [
                 "exec",
                 "--workdir",
                 "/repo",
                 "forge-run-x",
                 "sh",
                 "-c",
                 @stdin_wrapper,
                 "claude",
                 "-p",
                 "hi"
               ]
    end

    test "run/4 without a stamped workdir emits no --workdir" do
      client = %Docker{
        sandbox_name: "forge-run-y",
        workspace_dir: "/tmp/no_env_dir",
        sandbox_id: "y"
      }

      {output, 0} = Docker.run(client, "codex", ["exec", "task"], [])

      assert String.split(output, "\n", trim: true) == [
               "exec",
               "forge-run-y",
               "sh",
               "-c",
               @stdin_wrapper,
               "codex",
               "exec",
               "task"
             ]
    end

    test "run/4 applies .forge_env IN-VM (export loop in the wrapper, never --env-file/-e)" do
      dir = Path.join(System.tmp_dir!(), "f2_run_env_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      env_file = Path.join(dir, ".forge_env")
      File.write!(env_file, "A=b\n")
      on_exit(fn -> File.rm_rf(dir) end)

      client = %Docker{sandbox_name: "forge-run-z", workspace_dir: dir, sandbox_id: "z"}

      {output, 0} = Docker.run(client, "claude", ["-p", "hi"], [])

      assert ["exec", "forge-run-z", "sh", "-c", wrapper, "claude", "-p", "hi"] =
               String.split(output, "\n", trim: true)

      # The wrapper reads the env file in-VM with assignment-only exports
      # (never shell-evaluated values) and still redirects stdin.
      assert wrapper =~ ~s{export "$__fl"}
      assert wrapper =~ "< '#{env_file}'"
      assert wrapper =~ @stdin_wrapper
      # No inert --env-file flag, no ps-visible -e K=V on the host argv.
      refute output =~ "--env-file"
      refute output =~ "A=b"
    end
  end

  describe "isolate_global_config?/1 + maybe_inject_onecli_env/4 (the second call site)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "f2_inject_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      client = %Docker{sandbox_name: "forge-x", workspace_dir: dir, sandbox_id: "x"}
      %{dir: dir, client: client}
    end

    test "predicate is true only for the explicit opt-out" do
      assert Docker.isolate_global_config?(%{isolate_global_config: true})
      refute Docker.isolate_global_config?(%{})
      refute Docker.isolate_global_config?(%{isolate_global_config: false})
    end

    test "the post-create OneCLI env injection is SKIPPED under the opt-out", %{
      dir: dir,
      client: client
    } do
      assert :ok =
               Docker.maybe_inject_onecli_env(%{isolate_global_config: true}, client, "x", "x")

      refute File.exists?(Path.join(dir, ".forge_env"))
    end

    test "the OneCLI proxy env IS injected without the opt-out, CA env at the HOST path", %{
      dir: dir,
      client: client,
      ca: ca
    } do
      assert :ok = Docker.maybe_inject_onecli_env(%{}, client, "x", "x")
      env = File.read!(Path.join(dir, ".forge_env"))
      assert env =~ "HTTP_PROXY"
      # Same-path world: the cert env points at the original host path
      # (in-VM identical), not a /usr/local/share remap.
      assert env =~ "NODE_EXTRA_CA_CERTS=#{ca}"
      refute env =~ "/usr/local/share/ca-certificates"
    end
  end
end
