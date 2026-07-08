defmodule JidoClaw.Forge.Sandbox.DockerWriteBuildIntegrationTest do
  @moduledoc """
  Docker write build (executor-seam follow-up): the live proofs behind
  docker-backed vendor dispatch. Requires Docker/`sbx` (`@moduletag
  :docker_sandbox`, excluded from precommit).

    * stdin-EOF: `sbx exec` without `-i` has docker-exec stdin semantics —
      a stdin-reading command returns immediately instead of hanging (the
      docker-path replacement for HostShell's `</dev/null` wrap).
    * allow_network reachability — THE GATE: an in-VM client must reach a
      host `127.0.0.1`-bound listener via `host.docker.internal` under a
      per-sandbox `sbx policy allow network` rule. If this fails, the
      deposit-endpoint design does not hold; STOP and redesign — never
      silently bind the endpoint wider.

  Run with `mix test --include docker_sandbox`.
  """
  use ExUnit.Case, async: false

  @moduletag :docker_sandbox

  alias JidoClaw.Forge.Sandbox.Docker
  alias JidoClaw.Security.Redaction.Env

  setup_all do
    case System.cmd("sbx", ["version"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
      {_version, 0} -> :ok
      _ -> raise "sbx CLI not available — skipping Docker write-build integration tests"
    end
  end

  test "sbx exec without -i gives immediate stdin EOF (run/4 path)" do
    {:ok, client, sandbox_id} = Docker.create(%{runner: :shell})
    on_exit(fn -> Docker.destroy(client, sandbox_id) end)

    # `cat` reads stdin until EOF: with docker-exec stdin semantics (stdin
    # not attached) it returns immediately; a hang would hit the timeout and
    # return 124 — the failure this probe exists to catch.
    assert {_output, 0} = Docker.run(client, "cat", [], timeout: 15_000)
  end

  test "allow_network: in-VM curl reaches a host 127.0.0.1 listener via host.docker.internal" do
    {port, stop_listener} = start_loopback_http_listener()
    on_exit(stop_listener)

    spec = %{
      runner: :shell,
      allow_network: ["host.docker.internal:#{port}", "localhost:#{port}"]
    }

    {:ok, client, sandbox_id} = Docker.create(spec)
    on_exit(fn -> Docker.destroy(client, sandbox_id) end)

    probe =
      "if command -v curl >/dev/null 2>&1; then " <>
        "curl -s --connect-timeout 5 --max-time 10 " <>
        "http://host.docker.internal:#{port}/ || echo CURL_FAILED; " <>
        "else echo PROBE_UNAVAILABLE; fi"

    {out, _code} = Docker.exec(client, probe, timeout: 30_000)

    cond do
      out =~ "deposit-ok" ->
        :ok

      out =~ "PROBE_UNAVAILABLE" ->
        flunk("curl missing in the sandbox image — the reachability gate is inconclusive")

      true ->
        flunk(
          "in-VM curl could NOT reach the host loopback listener via " <>
            "host.docker.internal:#{port} — the deposit-endpoint design does not hold; " <>
            "STOP and redesign (never bind wider). Output: #{inspect(out)}"
        )
    end
  end

  test "per-sandbox policy rules are removed when the sandbox is destroyed (no leak)" do
    {:ok, client, sandbox_id} = Docker.create(%{runner: :shell, allow_network: ["localhost:1"]})
    name = client.sandbox_name

    {ls_before, 0} =
      System.cmd("sbx", ["policy", "ls"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env())

    assert ls_before =~ name

    Docker.destroy(client, sandbox_id)

    {ls_after, 0} =
      System.cmd("sbx", ["policy", "ls"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env())

    refute ls_after =~ name,
           "per-sandbox policy rules outlived `sbx rm` — Docker.destroy needs policy cleanup"
  end

  # A minimal host HTTP listener bound to 127.0.0.1:<kernel port> — the same
  # bind `ScopedEndpoint` uses, so reaching THIS proves reaching the deposit
  # endpoint.
  defp start_loopback_http_listener do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    {:ok, acceptor} = Task.start(fn -> accept_loop(listen) end)

    stop = fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end

    {port, stop}
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        _ = :gen_tcp.recv(sock, 0, 5_000)

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-length: 10\r\nconnection: close\r\n\r\ndeposit-ok"
        )

        :gen_tcp.close(sock)
        accept_loop(listen)

      {:error, _} ->
        :ok
    end
  end
end
