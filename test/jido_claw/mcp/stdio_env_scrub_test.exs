defmodule JidoClaw.MCP.StdioEnvScrubTest do
  @moduledoc """
  The corrected stdio trapdoor: `Port.open`'s `{:env}` overlays the inherited
  host env rather than replacing it, so the patched `Jido.MCP.Transport.STDIO`
  must build `:env` via the default-deny `Env.scrubbed_port_env/1`. Asserts the
  scrub itself, that the patched module is the loaded one, and — on unix — that
  a real subprocess spawned with the scrubbed env cannot see a host secret.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env

  @sentinel "MCP_SCRUB_SENTINEL_SECRET"

  test "scrubbed_port_env/1 unsets a sentinel secret and keeps PATH" do
    System.put_env(@sentinel, "leakme")
    on_exit(fn -> System.delete_env(@sentinel) end)

    env = Env.scrubbed_port_env([])

    # The sentinel is explicitly UNSET (default-deny)...
    assert {String.to_charlist(@sentinel), false} in env
    # ...while PATH is left to inherit (never unset), so it is absent from the
    # unset list rather than present-with-false.
    refute {~c"PATH", false} in env
    refute Enum.any?(env, fn {key, _value} -> key == ~c"PATH" end)
  end

  test "the loaded Jido.MCP.Transport.STDIO is the JidoClaw patched copy" do
    which = to_string(:code.which(Jido.MCP.Transport.STDIO))

    assert which =~ "jido_claw/ebin"
    refute which =~ "jido_mcp/ebin"
  end

  @tag :unix
  test "a subprocess spawned with the scrubbed env cannot see the host secret" do
    System.put_env(@sentinel, "leakme")
    on_exit(fn -> System.delete_env(@sentinel) end)

    # POSIX guarantees /bin/sh, and `env` emits KEY=VALUE lines — no
    # find_executable fallback that could silently skip the assertion.
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, :exit_status, {:args, ["-c", "env"]}, {:env, Env.scrubbed_port_env([])}]
      )

    {output, status} = collect_port_output(port, "")

    assert status == 0
    refute output =~ "#{@sentinel}=leakme"
    assert output =~ "PATH="
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      3_000 -> {acc, :timeout}
    end
  end
end
