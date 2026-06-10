defmodule JidoClaw.MCPScope.Initializer do
  @moduledoc """
  Synchronous startup that resolves the default tool_context for MCP
  mode and stashes it in the application env under
  `:jido_claw_mcp_default_scope`.

  The module runs as a `GenServer` whose `init/1` does all the work
  and returns `:ignore` after stashing the scope. Supervisor children
  block on `start_link/1` returning, so by the time the supervisor
  moves on to start the MCP server, the env key is populated.

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

  use GenServer

  require Logger

  alias JidoClaw.Authorization.Actor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    ensure_default_scope()
    :ignore
  end

  @doc """
  Re-resolve and re-stash the default scope, e.g. for the
  `MCPScope.wrap/4` lazy fallback when the boot-time resolution
  failed silently.
  """
  @spec ensure_default_scope() :: :ok
  def ensure_default_scope do
    cwd = File.cwd!()

    case JidoClaw.Workspaces.Resolver.ensure_workspace("default", cwd) do
      {:ok, workspace} ->
        external_id = "mcp_#{inspect(node())}_#{:erlang.pid_to_list(self())}"

        {session_uuid, session_id} =
          case JidoClaw.Conversations.Resolver.ensure_session(
                 "default",
                 workspace.id,
                 :mcp,
                 external_id
               ) do
            {:ok, session} ->
              {session.id, external_id}

            {:error, reason} ->
              Logger.warning(
                "[MCPScope.Initializer] could not ensure mcp session: #{inspect(reason)}"
              )

              {nil, nil}
          end

        scope = %{
          tenant_id: "default",
          workspace_uuid: workspace.id,
          workspace_id: workspace.id,
          session_uuid: session_uuid,
          session_id: session_id,
          project_dir: cwd,
          agent_id: "main",
          actor: Actor.system("default")
        }

        Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, scope)
        Logger.debug("[MCPScope.Initializer] default scope resolved: #{inspect(scope)}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[MCPScope.Initializer] could not resolve default workspace for cwd=#{cwd}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
