defmodule JidoClaw.Forge.Sandbox.DockerArgsTest do
  @moduledoc """
  AR-8b-2 F2 (1.6): the three additive Docker backend branches, asserted via the
  emitted `sbx` args (precommit proves the flag is EMITTED; the manual
  `:docker_sandbox` test asserts it is ENFORCED). `async: false` — mutates the
  global `:onecli` / `:forge_docker_sandbox` config.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.Sandbox.Docker

  setup do
    ca = Path.join(System.tmp_dir!(), "f2_ca_#{:erlang.unique_integer([:positive])}.crt")
    File.write!(ca, "CERT")

    prev_onecli = Application.get_env(:jido_claw, :onecli)
    prev_docker = Application.get_env(:jido_claw, :forge_docker_sandbox)

    Application.put_env(:jido_claw, :onecli,
      enabled: true,
      gateway_url: "http://localhost:10255",
      ca_cert_path: ca
    )

    Application.put_env(:jido_claw, :forge_docker_sandbox,
      extra_mounts: [{"/host/global", "/container/global", "ro"}]
    )

    on_exit(fn ->
      restore(:onecli, prev_onecli)
      restore(:forge_docker_sandbox, prev_docker)
      File.rm(ca)
    end)

    %{}
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)

  # The `host:container:mode` values of every `--mount` flag in the arg list.
  defp mounts(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _] -> flag == "--mount" end)
    |> Enum.map(fn [_, value] -> value end)
  end

  defp has_flag?(args, flag, value) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.member?([flag, value])
  end

  describe "build_create_args/4 — global-config opt-out + no-egress" do
    test "isolate_global_config: true skips the global mounts AND emits --network none" do
      spec = %{
        isolate_global_config: true,
        network: :none,
        extra_mounts: [{"/proto/dir", "/proto", "rw"}]
      }

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)

      # No OneCLI CA-cert mount, no operator global :extra_mounts (a host-path
      # mount would survive `--network none`).
      refute Enum.any?(mounts(args), &String.contains?(&1, "onecli.crt"))
      refute "/host/global:/container/global:ro" in mounts(args)

      # The prototype mount (spec-declared) IS present, and egress is disabled.
      assert "/proto/dir:/proto:rw" in mounts(args)
      assert has_flag?(args, "--network", "none")
    end

    test "without the opt-out, the global mounts ARE layered (today's behavior)" do
      spec = %{network: :none, extra_mounts: [{"/proto/dir", "/proto", "rw"}]}

      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)

      assert Enum.any?(mounts(args), &String.contains?(&1, "onecli.crt"))
      assert "/host/global:/container/global:ro" in mounts(args)
      assert "/proto/dir:/proto:rw" in mounts(args)
    end

    test "no network flag is emitted when the spec doesn't request no-egress" do
      args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", %{})
      refute "--network" in args
    end
  end

  describe "build_exec_args/4 — --workdir" do
    test "emits --workdir <dir> when a workdir is stamped" do
      # A workspace dir with no `.forge_env` so the env-file branch is skipped.
      args = Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", "/proto")

      assert has_flag?(args, "--workdir", "/proto")
      # The raw command is preserved verbatim (passed to `sh -c`).
      assert "echo hi" in args
    end

    test "emits NO --workdir for a nil/blank workdir (byte-identical to pre-F2)" do
      refute "--workdir" in Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", nil)
      refute "--workdir" in Docker.build_exec_args("forge-x", "/tmp/no_env_dir", "echo hi", "")
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

    test "the OneCLI proxy env IS injected without the opt-out", %{dir: dir, client: client} do
      assert :ok = Docker.maybe_inject_onecli_env(%{}, client, "x", "x")
      assert File.read!(Path.join(dir, ".forge_env")) =~ "HTTP_PROXY"
    end
  end
end
