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
    # Inert (PD1-1): the hand-defined `server_info/0` below is the wire
    # identity. Anubis skips its generated server_info when the module defines
    # its own, but `maybe_define_server_info`'s `is_nil(version)` arm would
    # force-generate a duplicate — so this literal must stay a non-nil binary.
    version: "0",
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
        JidoClaw.Tools.ReplayWorkflow,

        # Lua code-mode pair (amber AM-1 + jidoka V2-7): sandboxed read-only
        # cross-run queries server-side. Read-only by construction
        # (Bindings.assert_read_only!/0 per eval) ⇒ deliberately NOT on the
        # approval require list.
        JidoClaw.Tools.LuaQuery,
        JidoClaw.Tools.LuaDocs
      ],
      resources: [
        # The route-composer catalog at jido://workflows/catalog (AR-2 Phase 5,
        # §10.2): a client can discover the composable surface, not just trigger it.
        JidoClaw.MCPServer.Resources.WorkflowCatalog,
        # Served-surface version facts at jido://_meta/version (PD1-1).
        JidoClaw.MCPServer.Resources.MetaVersion,
        # One-read client orientation at jido://bootstrap (PD2-1, slim).
        JidoClaw.MCPServer.Resources.Bootstrap
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

  alias JidoClaw.MCPServer.ErrorCodes
  alias JidoClaw.MCPServer.SurfaceVersion

  # PD1-1: the wire identity carries the APP version via `Application.spec/2`
  # — never a hand-rolled literal (the old "0.2.0" had drifted three minor
  # versions stale). Anubis's `maybe_define_server_info` sees this definition
  # (`Module.defines?`) and skips its generated one, and `__after_compile__`
  # skips `validate_server_info!` too.
  @impl Anubis.Server
  @spec server_info() :: %{String.t() => String.t()}
  def server_info, do: %{"name" => "jido_claw", "version" => SurfaceVersion.app_version()}

  # PD1-2: the served error-contract stability sentence rides the MCP
  # initialize handshake. Anubis's `maybe_define_server_instructions` sees
  # this definition (`Module.defines?`) and skips its generated nil fallback
  # (jido_mcp passes no `:instructions`).
  @impl Anubis.Server
  @spec server_instructions() :: String.t()
  def server_instructions, do: ErrorCodes.stability_sentence()

  @doc """
  The MCP-published tool modules, derived from the generated `__publish__/0`
  so the tool-wrapper marker sweeps cover every publication surface (not just
  `JidoClaw.Agent.tool_modules/0`) and can never drift from this list.
  `replay_workflow` is MCP-only and on the approval require list.
  """
  @spec published_tool_modules() :: [module()]
  def published_tool_modules, do: __publish__().tools

  @doc """
  The published tool names, sorted — the served-surface enumeration the
  golden fixture pins (PD1-1) and the tool facts `jido://_meta/version` and
  `jido://bootstrap` serve.
  """
  @spec served_tool_names() :: [String.t()]
  def served_tool_names do
    __publish__().tools
    |> Enum.map(& &1.name())
    |> Enum.sort()
  end
end
