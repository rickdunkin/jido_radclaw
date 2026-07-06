defmodule JidoClaw.MCPServer.ServedSurfaceGoldenTest do
  @moduledoc """
  PD1-1 golden: the served MCP surface (tool names, static resource URIs,
  template URIs, surface version) is pinned to a committed fixture. Any drift
  fails here until the change is made deliberately — apply the
  `JidoClaw.MCPServer.SurfaceVersion` bump rules and regenerate the fixture
  IN THE SAME DIFF (the failure message prints the ready-to-commit JSON).

  Set-compares names per enumeration surface (the house drift-guard rule —
  never counts, which pass real drift). The separate "publishes 26 tools"
  count test in `mcp_server_test.exs` is not this golden's concern.
  """

  # async: false — the same module-loading caveat as mcp_server_test.exs.
  use ExUnit.Case, async: false

  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.SurfaceVersion

  @fixture_path Path.expand("../../../fixtures/mcp_surface/served_surface.json", __DIR__)

  setup_all do
    {:module, MCPServer} = Code.ensure_loaded(MCPServer)
    :ok
  end

  test "served surface matches the committed golden (bump SurfaceVersion + regen deliberately)" do
    live = live_surface()

    case File.read(@fixture_path) do
      {:ok, json} ->
        golden = Jason.decode!(json)

        for surface <- ["tool_names", "static_resource_uris", "resource_templates"] do
          assert Enum.sort(List.wrap(golden[surface])) == live[surface],
                 "served #{surface} drifted from the committed golden.\n" <> regen_help(live)
        end

        assert golden["surface_version"] == live["surface_version"],
               "surface_version drifted from the committed golden.\n" <> regen_help(live)

      {:error, reason} ->
        flunk(
          "golden fixture unreadable (#{inspect(reason)}): #{@fixture_path}\n" <>
            regen_help(live)
        )
    end
  end

  # Each enumeration surface derived from the live module, sorted:
  #   * tool_names — `served_tool_names/0` (already sorted).
  #   * static_resource_uris — the `publish:` resources' exact `uri/0`s.
  #   * resource_templates — anubis `component` templates; NEVER read from
  #     `__publish__().resources`, where templates never appear (the
  #     workflow_stage_test false-green trap).
  defp live_surface do
    static_uris =
      MCPServer.__publish__().resources
      |> Enum.map(& &1.uri())
      |> Enum.sort()

    template_uris =
      MCPServer.__components__(:resource)
      |> Enum.filter(& &1.uri_template)
      |> Enum.map(& &1.uri_template)
      |> Enum.sort()

    %{
      "surface_version" => SurfaceVersion.current(),
      "tool_names" => MCPServer.served_tool_names(),
      "static_resource_uris" => static_uris,
      "resource_templates" => template_uris
    }
  end

  defp regen_help(live) do
    "If the change is DELIBERATE: apply the SurfaceVersion bump rules, then commit this as " <>
      "#{@fixture_path}:\n" <> Jason.encode!(live, pretty: true) <> "\n"
  end
end
