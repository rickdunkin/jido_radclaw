defmodule JidoClaw.Agent.RecorderPluginCoverageTest do
  @moduledoc """
  CI gate from §G: every `use Jido.AI.Agent` site under `lib/` MUST
  resolve to one that injects the Recorder plugin (i.e. routes via
  `JidoClaw.Agent.Defaults`). Adding a new agent worker without
  routing through `Defaults` would silently drop tool activity from
  the persistence layer.
  """
  use ExUnit.Case, async: true

  test "every agent declaration site under lib/ uses JidoClaw.Agent.Defaults" do
    lib_dir = Path.expand("../../../lib", __DIR__)

    files =
      Path.wildcard(Path.join(lib_dir, "**/*.ex"))
      |> Enum.reject(&String.contains?(&1, "/lib/jido_claw/agent/defaults.ex"))

    {good, bad} =
      Enum.reduce(files, {[], []}, fn path, {good, bad} ->
        contents = File.read!(path)

        cond do
          String.contains?(contents, "use JidoClaw.Agent.Defaults,") ->
            {[path | good], bad}

          String.contains?(contents, "use Jido.AI.Agent,") ->
            {good, [path | bad]}

          true ->
            {good, bad}
        end
      end)

    assert bad == [], """
    Found `use Jido.AI.Agent,` outside JidoClaw.Agent.Defaults — these sites
    will skip the Recorder plugin and silently drop tool persistence:

      #{Enum.join(bad, "\n  ")}
    """

    assert length(good) >= 8, """
    Expected at least 8 agent declaration sites, found #{length(good)}.
    Did the agent_server_plugin coverage regress?
    """
  end
end
