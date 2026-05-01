defmodule JidoClaw.MCPScope.Initializer do
  @moduledoc """
  One-shot startup task that resolves the default tool_context for
  MCP mode and stashes it in the application env under
  `:jido_claw_mcp_default_scope`.

  Picked up by `JidoClaw.Tools.MCPScope.with_default/1` so the
  Solutions tools (`StoreSolution`, `FindSolution`,
  `VerifyCertificate`) inherit a default scope when the MCP transport
  doesn't provide one.

  The MCP server is a fixed process: `mix jidoclaw --mcp` is launched
  with a known `cwd`, that's the only scope information available, and
  it's enough. `tenant_id: "default"` is correct because the MCP
  protocol has no auth and is single-user by definition.

  Multi-tenant MCP is out of scope — the protocol has no mechanism to
  distinguish callers.
  """

  use Task

  require Logger

  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts) do
    cwd = File.cwd!()

    case JidoClaw.Workspaces.Resolver.ensure_workspace("default", cwd) do
      {:ok, workspace} ->
        scope = %{
          tenant_id: "default",
          workspace_uuid: workspace.id,
          workspace_id: workspace.id,
          session_uuid: nil,
          session_id: nil,
          project_dir: cwd,
          agent_id: "main"
        }

        Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, scope)
        Logger.debug("[MCPScope.Initializer] default scope resolved: #{inspect(scope)}")

      {:error, reason} ->
        Logger.warning(
          "[MCPScope.Initializer] could not resolve default workspace for cwd=#{cwd}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
