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

        # Single-run composer observe (AR-2 Phase 5, §10.2) — MCP-only by
        # design (the `workflow_status` precedent: not on the in-REPL agent).
        JidoClaw.Tools.InspectWorkflow,

        # Workflow replay (Phase 4) — MCP-only by design: the in-REPL agent's
        # tool list deliberately does NOT carry this side-effect lever.
        JidoClaw.Tools.ReplayWorkflow
      ],
      resources: [
        # The route-composer catalog at jido://workflows/catalog (AR-2 Phase 5,
        # §10.2): a client can discover the composable surface, not just trigger it.
        JidoClaw.MCPServer.Resources.WorkflowCatalog
      ]
    }

  @doc """
  The MCP-published tool modules, derived from the generated `__publish__/0`
  so the tool-wrapper marker sweeps cover every publication surface (not just
  `JidoClaw.Agent.tool_modules/0`) and can never drift from this list.
  `replay_workflow` is MCP-only and on the approval require list.
  """
  @spec published_tool_modules() :: [module()]
  def published_tool_modules, do: __publish__().tools
end
