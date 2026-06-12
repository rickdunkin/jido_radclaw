defmodule JidoClaw.MCPServer do
  @moduledoc """
  MCP server for JidoClaw, powered by jido_mcp.

  Exposes core file, code, and git tools over MCP stdio transport so that
  Claude Code, Cursor, and other MCP-compatible editors can invoke them.

  Usage:
    jido --mcp
  """

  use Jido.MCP.Server,
    name: "jido_claw",
    version: "0.2.0",
    publish: %{
      tools: [
        JidoClaw.Tools.ReadFile,
        JidoClaw.Tools.WriteFile,
        JidoClaw.Tools.EditFile,
        JidoClaw.Tools.ListDirectory,
        JidoClaw.Tools.SearchCode,
        JidoClaw.Tools.RunCommand,
        # MCP run_command/git_diff output is shaped too — without
        # fetch_output, MCP callers couldn't drill into stored refs.
        JidoClaw.Tools.FetchOutput,
        JidoClaw.Tools.GitStatus,
        JidoClaw.Tools.GitDiff,
        JidoClaw.Tools.GitCommit,
        JidoClaw.Tools.ProjectInfo,
        JidoClaw.Tools.RunSkill,

        # Solutions tools
        JidoClaw.Tools.StoreSolution,
        JidoClaw.Tools.FindSolution,

        # Network tools
        JidoClaw.Tools.NetworkShare,
        JidoClaw.Tools.NetworkStatus,

        # Introspection tools
        JidoClaw.Tools.AgentStatus,
        JidoClaw.Tools.InspectAgent,
        JidoClaw.Tools.SwarmStatus,
        JidoClaw.Tools.ForgeStatus,
        JidoClaw.Tools.WorkflowStatus,

        # Workflow replay (Phase 4) — MCP-only by design: the in-REPL agent's
        # tool list deliberately does NOT carry this side-effect lever.
        JidoClaw.Tools.ReplayWorkflow
      ]
    }
end
