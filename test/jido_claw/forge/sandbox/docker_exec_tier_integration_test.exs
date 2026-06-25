defmodule JidoClaw.Forge.Sandbox.DockerExecTierIntegrationTest do
  @moduledoc """
  AR-8b-2 F2 (§2.5): the TRUE production-isolation gate for the exec sketch tier.
  Requires Docker/`sbx` (`@moduletag :docker_sandbox`, excluded from precommit) —
  precommit only proves the no-egress flag is EMITTED; THIS test proves it is
  ENFORCED. A `sbx` that *rejects* the flag degrades to a file-only sketch (safe);
  a `sbx` that *silently ignores* `--network none` would fail OPEN — caught only by
  the egress assertion here. Must pass before trusting the tier with real `sbx`.

  Run with `mix test --include docker_sandbox`.
  """
  use ExUnit.Case, async: false

  @moduletag :docker_sandbox

  alias JidoClaw.Forge.Sandbox.Docker
  alias JidoClaw.Security.Redaction.Env

  setup_all do
    case System.cmd("sbx", ["version"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
      {_version, 0} -> :ok
      _ -> raise "sbx CLI not available — skipping Docker exec-tier integration tests"
    end
  end

  setup do
    # The front-door-owned `.prototypes/<id>/` (host side), mounted rw at /proto.
    proto = Path.join(System.tmp_dir!(), "f2_proto_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(proto)

    # The flattened create-spec the Harness builds from `sandbox_spec` (1.5/1.6):
    # tuple mounts (post-`build_sandbox_spec`), no-egress, workdir, global opt-out.
    spec = %{
      runner: :shell,
      extra_mounts: [{proto, "/proto", "rw"}],
      workdir: "/proto",
      network: :none,
      isolate_global_config: true
    }

    case Docker.create(spec) do
      {:ok, client, sandbox_id} ->
        on_exit(fn ->
          Docker.destroy(client, sandbox_id)
          File.rm_rf(proto)
        end)

        %{client: client, proto: proto}

      {:error, reason} ->
        raise "Failed to create no-egress exec sandbox: #{inspect(reason)}"
    end
  end

  test "network egress is DENIED (the fail-open gate)", %{client: client} do
    # Structural proof: `--network none` leaves only loopback — no external iface.
    {ifaces, _code} = Docker.exec(client, "ls /sys/class/net", timeout: 10_000)
    assert ifaces =~ "lo"
    refute ifaces =~ "eth0"

    # Behavioral proof: a raw outbound TCP/HTTP connection cannot be established.
    # http:// (not https) + no -f so TLS/CA or HTTP-status failures don't masquerade
    # as a network denial (the exec tier skips the CA-cert mount, 1.6). curl's own
    # timeouts drop the external `timeout` dep. Tri-state: a missing probe tool fails
    # loudly (inconclusive ≠ pass) — only a genuine BLOCKED passes the gate.
    probe =
      "if command -v curl >/dev/null 2>&1; then " <>
        "curl -s --connect-timeout 5 --max-time 5 http://1.1.1.1 -o /dev/null " <>
        "&& echo REACHED || echo BLOCKED; " <>
        "else echo PROBE_UNAVAILABLE; fi"

    {out, _code} = Docker.exec(client, probe, timeout: 15_000)

    cond do
      out =~ "REACHED" ->
        flunk("egress REACHED the internet — `--network none` is NOT enforced (fail-OPEN)")

      out =~ "PROBE_UNAVAILABLE" ->
        flunk(
          "egress probe tool (curl) missing in the sandbox image — the check is inconclusive; " <>
            "cannot trust the isolation gate"
        )

      out =~ "BLOCKED" ->
        :ok

      true ->
        flunk("unexpected egress probe output: #{inspect(out)}")
    end
  end

  test "--workdir /proto lands exec in the mount (a relative path sees host-written files)", %{
    client: client,
    proto: proto
  } do
    File.write!(Path.join(proto, "from_host.txt"), "host wrote this")

    # RELATIVE path — only resolves if the in-container cwd is the /proto mount.
    {output, 0} = Docker.exec(client, "cat from_host.txt", timeout: 10_000)
    assert String.trim(output) == "host wrote this"
  end

  test "the :rw mount round-trips BOTH directions (container write → host read)", %{
    client: client,
    proto: proto
  } do
    # Container exec writes (relative → /proto/out.txt)...
    {_out, 0} = Docker.exec(client, "echo 'container wrote this' > out.txt", timeout: 10_000)

    # ...and a host file tool reads it back (catches UID/GID / mount mismatches a
    # stub masks), and can remove it on cleanup.
    host_path = Path.join(proto, "out.txt")
    assert String.trim(File.read!(host_path)) == "container wrote this"
    assert File.rm(host_path) == :ok
  end
end
