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

        # Raw per-run event feed (G2-1a, the get_logs_on_task analogue) —
        # byte-paginated; MCP-only by design, like inspect_workflow (absent from
        # the in-REPL agent's tool list).
        JidoClaw.Tools.WorkflowEvents,

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

  # Per-stage drill-down template at jido://workflows/{name} (G2-1b). An anubis
  # `component` (the macro arrives via `use Jido.MCP.Server` → `use
  # Anubis.Server`), deliberately NOT in `publish:` — templates never go there
  # (jido_mcp's publish DSL has no template concept). It registers compile-time
  # into `__components__(:resource)`, is listed by `resources/templates/list`,
  # and anubis's read path routes matching URIs directly to the component's
  # `read/2` — static resources match first, so the catalog URI above is
  # unaffected.
  component(JidoClaw.MCPServer.Resources.WorkflowStage)

  @doc """
  The MCP-published tool modules, derived from the generated `__publish__/0`
  so the tool-wrapper marker sweeps cover every publication surface (not just
  `JidoClaw.Agent.tool_modules/0`) and can never drift from this list.
  `replay_workflow` is MCP-only and on the approval require list.
  """
  @spec published_tool_modules() :: [module()]
  def published_tool_modules, do: __publish__().tools
end
