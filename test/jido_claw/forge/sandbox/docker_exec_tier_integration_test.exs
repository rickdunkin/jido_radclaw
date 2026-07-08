defmodule JidoClaw.Forge.Sandbox.DockerExecTierIntegrationTest do
  @moduledoc """
  AR-8b-2 F2 (§2.5): the TRUE production-isolation gate for the exec sketch tier.
  Requires Docker/`sbx` (`@moduletag :docker_sandbox`, excluded from precommit) —
  precommit only proves the deny-all policy args are EMITTED; THIS test proves the
  rule is ENFORCED. A `sbx` that *rejects* the policy call fails the create closed
  (safe); a `sbx` that *silently ignores* the deny rule would fail OPEN — caught
  only by the egress assertion here. Must pass before trusting the tier with real
  `sbx`.

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
    # Same-path (sbx 0.34.0): the proto dir mounts in-VM at its host path.
    spec = %{
      runner: :shell,
      extra_mounts: [{proto, proto, "rw"}],
      workdir: proto,
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
    # Behavioral proof only: the 0.34.0 deny-all is a per-sandbox POLICY rule
    # enforced by a transparent proxy, not an iface removal — `eth0` exists,
    # the TCP connect SUCCEEDS (to the proxy), and the denial arrives IN-BAND
    # as an HTTP 403 whose body names "Blocked by network policy" (smoke-
    # verified; `sbx policy log` records the deny). So the probe is
    # body-aware: the block marker ⇒ BLOCKED; a transport failure ⇒ BLOCKED;
    # a real upstream response ⇒ REACHED (fail-open). curl's own timeouts
    # drop the external `timeout` dep. Tri-state: a missing probe tool fails
    # loudly (inconclusive ≠ pass) — only a genuine BLOCKED passes the gate.
    probe =
      "if command -v curl >/dev/null 2>&1; then " <>
        "out=$(curl -s --connect-timeout 5 --max-time 5 http://1.1.1.1 2>&1); rc=$?; " <>
        "if printf %s \"$out\" | grep -q 'Blocked by network policy'; then echo BLOCKED; " <>
        "elif [ $rc -ne 0 ]; then echo BLOCKED; else echo REACHED; fi; " <>
        "else echo PROBE_UNAVAILABLE; fi"

    {out, _code} = Docker.exec(client, probe, timeout: 15_000)

    cond do
      out =~ "REACHED" ->
        flunk("egress REACHED the internet — the deny-all policy is NOT enforced (fail-OPEN)")

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

  test "--workdir lands exec in the same-path mount (a relative path sees host-written files)", %{
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
