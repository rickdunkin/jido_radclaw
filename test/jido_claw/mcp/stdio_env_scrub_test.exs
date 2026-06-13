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

    case System.find_executable("printenv") do
      nil ->
        # No `printenv` available — the scrub unit test above still covers it.
        assert true

      printenv ->
        port =
          Port.open(
            {:spawn_executable, printenv},
            [:binary, :exit_status, {:env, Env.scrubbed_port_env([])}]
          )

        output = collect_port_output(port, "")

        refute output =~ "#{@sentinel}=leakme"
        assert output =~ "PATH="
    end
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, _status}} -> acc
    after
      3_000 -> acc
    end
  end
end
