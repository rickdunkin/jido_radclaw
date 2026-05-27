defmodule JidoClaw.ToolContext do
  @moduledoc """
  Canonical builder for the `tool_context` map threaded into every
  `Agent.ask*` call.

  All callers (REPL, web controllers, RPC channels, channel adapters,
  cron worker, workflow drivers, swarm tools) go through `build/1` or
  `child/2` so the canonical key set stays in sync. Absent keys are
  written as `nil` (not omitted) so downstream consumers can pattern-
  match on a stable shape.

  ## Canonical keys

    * `:project_dir`    — absolute filesystem path the surface is anchored to
    * `:tenant_id`      — tenant string (e.g. `"default"` for CLI/Discord)
    * `:session_id`     — runtime/string session id (CLI session id, etc.)
    * `:session_uuid`   — Phase 0 UUID FK target (`Conversations.Session.id`)
    * `:workspace_id`   — runtime per-session VFS/Shell/Profile key (overload)
    * `:workspace_uuid` — Phase 0 UUID FK target (`Workspaces.Workspace.id`)
    * `:user_id`        — UUID of the authenticated user; nil for CLI/Discord/Telegram
    * `:agent_id`       — runtime agent identity (e.g. `"main"` or a session id)
    * `:agent_template` — current routed template name (e.g., `"main"`,
                           `"reviewer"`). Distinct from `:agent_id`, which is
                           the opaque runtime identity. Used by the handoff
                           tool to derive `from_template` cleanly.
    * `:actor`          — Ash authorization actor map; built by
                           `JidoClaw.Authorization.Actor`. Nil for paths
                           that haven't resolved an actor (system / public)

  `:forge_session_key` is preserved through `build/1` and `child/2` when
  set on the input scope; consumers (`spawn_agent`, `send_to_agent`,
  `Reasoning.Telemetry.with_outcome/4`) attribute outcomes to the forge
  session via that string key.
  """

  @canonical_keys [
    :project_dir,
    :tenant_id,
    :session_id,
    :session_uuid,
    :workspace_id,
    :workspace_uuid,
    :user_id,
    :agent_id,
    :agent_template,
    :actor
  ]

  @doc """
  Build the canonical tool_context map from a scope map.

  The seven canonical keys are always present in the result (as `nil`
  when not supplied). `:forge_session_key` is preserved when present in
  the scope, otherwise omitted.
  """
  @spec build(map()) :: map()
  def build(scope) when is_map(scope) do
    base = Map.new(@canonical_keys, fn key -> {key, Map.get(scope, key)} end)

    case Map.get(scope, :forge_session_key) do
      nil -> base
      key -> Map.put(base, :forge_session_key, key)
    end
  end

  @doc """
  Build a child tool_context map from a parent's tool_context, replacing
  the agent_id with `child_tag` and falling back to `File.cwd!()` for
  `:project_dir` when the parent's value is `nil`.

  This is the canonical helper for swarm tools (`spawn_agent`,
  `send_to_agent`) so child agents inherit the parent's full scope —
  `tenant_id`, `session_uuid`, `workspace_uuid`, `forge_session_key` —
  rather than just `:project_dir` + `:workspace_id`.

  Resets `:agent_template` to `nil` because spawned children are not
  routed via the handoff registry; callers that need a specific template
  attribution should set it explicitly after the call.
  """
  @spec child(map() | nil, String.t()) :: map()
  def child(parent_tool_context, child_tag) when is_binary(child_tag) do
    parent = parent_tool_context || %{}

    parent
    |> Map.put(:agent_id, child_tag)
    |> Map.put(:agent_template, nil)
    |> Map.put(:project_dir, Map.get(parent, :project_dir) || File.cwd!())
    |> build()
  end

  @doc """
  Return the effective project directory from an enriched tool context.

  Tools that shell out or inspect the filesystem should use this after
  `MCPScope.wrap/4` enriches the context, so MCP/web/CLI calls operate on the
  scoped workspace instead of the BEAM startup directory.
  """
  @spec project_dir(map()) :: String.t()
  def project_dir(%{tool_context: %{project_dir: dir}}) when is_binary(dir) and dir != "" do
    dir
  end

  def project_dir(_enriched), do: File.cwd!()
end
