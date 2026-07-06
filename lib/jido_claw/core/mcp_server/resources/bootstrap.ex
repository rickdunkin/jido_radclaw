defmodule JidoClaw.MCPServer.Resources.Bootstrap do
  @moduledoc """
  Slim one-read client orientation (pad PD2-1): `jido://bootstrap` → version
  facts + served tool names + a bounded tenant snapshot (pending gates,
  active runs, recent completions), so a fresh MCP client orients itself in
  one resource read instead of a tool-call fan-out.

  **Version/tool facts are always present** (they need no scope). The
  `tenant` block depends on the MCP default scope
  (`JidoClaw.Tools.MCPScope.with_default/1`): unresolved ⇒ `available: false`
  with `reason: "mcp_scope_unavailable"` — never a fabricated empty snapshot.

  **Honesty over zeros** (the deliberate inversion of
  `RuntimeOverview.approvals/1`'s degrade-to-zero): a failed read inside a
  resolved tenant flips that block's `*_available: false` flag instead of
  reporting 0/[] — a bootstrap consumer must never mistake a DB fault for an
  idle tenant.

  **Caps**: `active_runs`/`recent_completions` carry at most
  `@recent_runs_cap` rows (built on `Visibility.run_view(:operator)`
  projections via the honest `WorkflowView.runs/2` read, so completions carry
  `disposition`/`findings_deferred_count`). Each list's `*_overflow_count`
  comes from a cap+1 read: **≥1 means more exist — it is a signal, not a
  total** (use `workflow_status`/`jido.runs` for real listings).
  """

  # The shared resource callback set IS an extracted behaviour already —
  # `Jido.MCP.Server.Resource`, a dep contract this check cannot see. The
  # group finding anchors at its alphabetically-first module (this one).
  # reach:disable-for-this-file behaviour_candidate
  @behaviour Jido.MCP.Server.Resource

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.SurfaceVersion
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.WorkflowView

  @uri "jido://bootstrap"
  @recent_runs_cap 5

  @impl Jido.MCP.Server.Resource
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl Jido.MCP.Server.Resource
  @spec name() :: String.t()
  def name, do: "bootstrap"

  @impl Jido.MCP.Server.Resource
  @spec description() :: String.t()
  def description,
    do:
      "One-read client orientation: app/surface versions, served tool names, and a " <>
        "bounded tenant snapshot (pending gates, active runs, recent completions)."

  @impl Jido.MCP.Server.Resource
  @spec mime_type() :: String.t()
  def mime_type, do: "application/json"

  @impl Jido.MCP.Server.Resource
  @spec read(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def read(@uri, _frame) do
    tool_names = MCPServer.served_tool_names()

    payload = %{
      "app_version" => SurfaceVersion.app_version(),
      "surface_version" => SurfaceVersion.current(),
      "tool_count" => length(tool_names),
      "tool_names" => tool_names,
      "tenant" => tenant_block()
    }

    {:ok, JsonSafe.encode(payload)}
  end

  def read(_uri, _frame), do: {:error, :not_found}

  defp tenant_block do
    case MCPScope.with_default(%{}) do
      %{tool_context: %{tenant_id: tenant_id} = scope} when is_binary(tenant_id) ->
        actor = Map.get(scope, :actor) || Actor.system(tenant_id)

        %{
          "available" => true,
          "tenant_id" => tenant_id,
          "workspace_id" => Map.get(scope, :workspace_id),
          "session_id" => Map.get(scope, :session_id),
          "project_dir" => Map.get(scope, :project_dir)
        }
        |> Map.merge(pending_gates(tenant_id, actor))
        |> Map.merge(runs_block("active_runs", tenant_id, actor, []))
        |> Map.merge(
          runs_block("recent_completions", tenant_id, actor,
            statuses: Projection.terminal_statuses(),
            sort: [completed_at: :desc]
          )
        )

      _unresolved ->
        %{"available" => false, "reason" => "mcp_scope_unavailable"}
    end
  end

  # The operator-inbox count. A read fault flips the availability flag —
  # never a fabricated 0 (contrast RuntimeOverview.approvals/1, a dashboard
  # rollup that deliberately degrades to zero).
  defp pending_gates(tenant_id, actor) do
    case AgentCase.pending_for_tenant(tenant: tenant_id, actor: actor) do
      {:ok, cases} -> %{"pending_gates_count" => length(cases)}
      _fault -> %{"pending_gates_available" => false}
    end
  end

  # One capped run listing (default statuses = active; opts override for the
  # completions read). The cap+1 read makes overflow honest: fetched beyond
  # the cap ⇒ overflow_count ≥ 1 (more exist), never a total.
  defp runs_block(key, tenant_id, actor, opts) do
    read_opts = Keyword.put(opts, :limit, @recent_runs_cap + 1)

    case WorkflowView.runs([tenant_id: tenant_id, actor: actor], read_opts) do
      {:ok, runs} ->
        %{
          key => Enum.take(runs, @recent_runs_cap),
          (key <> "_overflow_count") => max(0, length(runs) - @recent_runs_cap)
        }

      {:error, _fault} ->
        %{(key <> "_available") => false}
    end
  end
end
