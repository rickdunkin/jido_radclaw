defmodule JidoClaw.MCPServerTest do
  # async: false — function_exported?/3 can return stale results during
  # concurrent hot code reloads triggered by parallel async tests.
  use ExUnit.Case, async: false

  alias JidoClaw.MCPServer

  # MCPServer is only auto-loaded when serve_mode == :mcp; in the test VM it can
  # be unloaded, and `function_exported?/3` does NOT auto-load (unlike a direct
  # function call). Force-load it once — module loading is VM-global — so the
  # export checks below stop flaking on test ordering.
  setup_all do
    {:module, MCPServer} = Code.ensure_loaded(MCPServer)
    :ok
  end

  describe "module existence" do
    test "module is compiled and available" do
      assert Code.ensure_loaded?(MCPServer)
    end

    test "module is a Jido.MCP.Server — server_info/0 is defined" do
      assert function_exported?(MCPServer, :server_info, 0)
    end

    test "module exports child_spec/1 (OTP-compatible)" do
      assert function_exported?(MCPServer, :child_spec, 1)
    end

    test "module exports handle_request/2 (MCP server behaviour callback)" do
      assert function_exported?(MCPServer, :handle_request, 2)
    end

    test "module exports handle_tool_call/3 (MCP server behaviour callback)" do
      assert function_exported?(MCPServer, :handle_tool_call, 3)
    end

    test "module exports server_capabilities/0" do
      assert function_exported?(MCPServer, :server_capabilities, 0)
    end
  end

  describe "server_info/0" do
    test "server name is 'jido_claw'" do
      info = MCPServer.server_info()
      assert info["name"] == "jido_claw"
    end

    test "server_info includes a version string" do
      info = MCPServer.server_info()
      assert is_binary(info["version"])
      assert info["version"] != ""
    end

    test "server_info returns a map" do
      assert is_map(MCPServer.server_info())
    end
  end

  describe "published tools" do
    test "__publish__/0 returns a map with tools list" do
      assert function_exported?(MCPServer, :__publish__, 0)
      publish = MCPServer.__publish__()
      assert is_map(publish)
      assert is_list(publish.tools)
    end

    test "publishes 26 tools" do
      assert Enum.count(MCPServer.__publish__().tools) == 26
    end

    test "includes the Lua code-mode pair" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.LuaQuery in tools
      assert JidoClaw.Tools.LuaDocs in tools
    end

    test "includes introspection tools" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.AgentStatus in tools
      assert JidoClaw.Tools.InspectAgent in tools
      assert JidoClaw.Tools.SwarmStatus in tools
      assert JidoClaw.Tools.ForgeStatus in tools
      assert JidoClaw.Tools.WorkflowStatus in tools
    end

    test "includes the single-run composer observe tool (MCP-only surface)" do
      assert JidoClaw.Tools.InspectWorkflow in MCPServer.__publish__().tools
    end

    test "includes the workflow replay tool (MCP-only surface)" do
      assert JidoClaw.Tools.ReplayWorkflow in MCPServer.__publish__().tools
    end

    test "includes the workflow event-feed tool (MCP-only surface)" do
      assert JidoClaw.Tools.WorkflowEvents in MCPServer.__publish__().tools
    end

    test "includes core file tools" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.ReadFile in tools
      assert JidoClaw.Tools.WriteFile in tools
      assert JidoClaw.Tools.EditFile in tools
      assert JidoClaw.Tools.ListDirectory in tools
    end

    test "includes search and execution tools" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.SearchCode in tools
      assert JidoClaw.Tools.RunCommand in tools
      assert JidoClaw.Tools.FetchOutput in tools
    end

    test "includes git tools" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.GitStatus in tools
      assert JidoClaw.Tools.GitDiff in tools
      assert JidoClaw.Tools.GitCommit in tools
    end

    test "includes project and skill tools" do
      tools = MCPServer.__publish__().tools

      assert JidoClaw.Tools.ProjectInfo in tools
      assert JidoClaw.Tools.RunSkill in tools
    end
  end

  describe "published resources (AR-2 Phase 5)" do
    test "__publish__/0 carries a resources list" do
      assert is_list(MCPServer.__publish__().resources)
    end

    test "publishes the route-composer catalog resource" do
      assert JidoClaw.MCPServer.Resources.WorkflowCatalog in MCPServer.__publish__().resources
    end
  end
end
