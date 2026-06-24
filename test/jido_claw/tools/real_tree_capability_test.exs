defmodule JidoClaw.Tools.RealTreeCapabilityTest do
  @moduledoc """
  AR-8b-2 F3 negative-capability contract: the three read-only real-tree tools are
  **worker-private** to the sketch templates. They are wired explicitly into
  `SketchBuild` + `SketchReviewer` and deliberately NOT registered on the main
  agent or the MCP serve surface, so they are unreachable from any non-sketch
  surface (and the fail-closed `sandbox == :prototype` check makes them inert even
  if they leaked there).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Workers.SketchBuild
  alias JidoClaw.Agent.Workers.SketchReviewer

  @real_tree_tools [
    JidoClaw.Tools.ReadRealFile,
    JidoClaw.Tools.SearchRealCode,
    JidoClaw.Tools.ListRealDirectory
  ]

  defp worker_tools(module), do: Keyword.fetch!(module.strategy_opts(), :tools)

  test "all three real-tree tools are present in the sketch_build tool list" do
    tools = worker_tools(SketchBuild)

    for tool <- @real_tree_tools,
        do: assert(tool in tools, "expected #{inspect(tool)} in SketchBuild")
  end

  test "all three real-tree tools are present in the sketch_reviewer tool list" do
    tools = worker_tools(SketchReviewer)

    for tool <- @real_tree_tools,
        do: assert(tool in tools, "expected #{inspect(tool)} in SketchReviewer")
  end

  test "none are registered on the main agent (Agent default tool list)" do
    tools = JidoClaw.Agent.tool_modules()

    for tool <- @real_tree_tools,
        do: refute(tool in tools, "#{inspect(tool)} leaked to the main agent")
  end

  test "none are exposed over the MCP serve surface" do
    tools = JidoClaw.MCPServer.published_tool_modules()

    for tool <- @real_tree_tools,
        do: refute(tool in tools, "#{inspect(tool)} leaked to the MCP surface")
  end

  test "there is no real-tree write/edit counterpart (mutation is structurally impossible)" do
    refute Code.ensure_loaded?(JidoClaw.Tools.WriteRealFile)
    refute Code.ensure_loaded?(JidoClaw.Tools.EditRealFile)
  end
end
