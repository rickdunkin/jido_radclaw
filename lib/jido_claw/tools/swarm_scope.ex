defmodule JidoClaw.Tools.SwarmScope do
  @moduledoc false

  alias JidoClaw.AgentTracker
  alias JidoClaw.Error

  @doc """
  Build the canonical tracker scope from an enriched tool `context`
  (the map carrying `:tool_context`). Thin wrapper over
  `scope_from_tool_context/1`.
  """
  @spec tracker_scope(map()) :: {:ok, keyword()} | {:error, :tenant_required}
  def tracker_scope(context) do
    context
    |> Map.get(:tool_context, %{})
    |> scope_from_tool_context()
  end

  @doc """
  Build the canonical tracker scope from a `tool_context` map.

  Maps the caller's `:agent_id` to `:parent_agent_id` — mirroring the
  register-time mapping in `JidoClaw.Tools.SpawnAgent` — so agent-invoked
  swarm tools scope to the caller's **own direct children**, then filters
  to `AgentTracker.scope_keys/0` (the map clause drops nils +
  non-canonical keys) and requires a tenant. Human surfaces pass no
  `:agent_id`, so `:parent_agent_id` is nil and drops out, leaving their
  scope session/tenant-wide.
  """
  @spec scope_from_tool_context(map()) :: {:ok, keyword()} | {:error, :tenant_required}
  def scope_from_tool_context(tool_context) when is_map(tool_context) do
    tool_context
    |> Map.put(:parent_agent_id, Map.get(tool_context, :agent_id))
    |> JidoClaw.RuntimeScope.require_tenant(AgentTracker.scope_keys())
  end

  @spec scoped_agent(module(), String.t(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def scoped_agent(agent_tracker, agent_id, scope_opts) do
    case agent_tracker.get_agent(agent_id, scope_opts) do
      nil -> {:error, Error.not_found(:agent, agent_id)}
      entry -> {:ok, entry}
    end
  end
end
