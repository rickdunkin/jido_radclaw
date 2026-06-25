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
    * `:user_id`        — UUID of the authenticated user; nil for CLI/Discord
    * `:agent_id`       — runtime agent identity (e.g. `"main"` or a session id)
    * `:agent_template` — current routed template name (e.g., `"main"`,
                           `"reviewer"`). Distinct from `:agent_id`, which is
                           the opaque runtime identity. Used by the handoff
                           tool to derive `from_template` cleanly.
    * `:subagent`       — boolean. `true` for spawned sub-agents and
                           workflow steps (set by `child/2,3` and the
                           workflow scope); `false` for conversation owners
                           (REPL/chat main + handoff workers). Drives the
                           durable `messages.subagent` flag so cold readers
                           can exclude sub-agent rows from the primary view.
    * `:sanitize_sensitive_context` — boolean (AR-2 Phase 2b). `true` for a
                           composer subagent's turn whose derived durable
                           output must be sanitized at every sink. Canonical
                           (always forwarded — never policy-strippable) so it
                           propagates to nested `spawn_agent`/`send_to_agent`
                           children automatically.
    * `:sandbox`        — `:none` | `:prototype` | `:docker` (AR-8b /
                           AR-8b-2 F2). The isolation tier the turn runs under,
                           stamped from the template's `sandbox` policy by
                           `Skills.Steps.AgentRunner`. The file tools read it
                           (`:prototype`/`:docker`) to forbid remote VFS schemes
                           (`github://`/…); under `:docker`, `run_command`
                           additionally routes into a Forge Docker session
                           (`JidoClaw.Tools.RunCommand.ForgeBridge`) instead of
                           the host shell. Canonical (always forwarded — never
                           policy-strippable) so a sketch worker's nested
                           `spawn_agent`/`send_to_agent` children inherit the
                           jail and can't shed it. Value-agnostic to propagate:
                           `:docker` rides the existing machinery with no
                           builder change.
    * `:request_correlation_expires_at` — `DateTime` | nil (AR-2 Phase 2b).
                           The conservative `RequestCorrelation` TTL ceiling a
                           composer wave seeds so an orphaned late-writing
                           subagent's marker row outlives realistic late writes.
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
    :subagent,
    :sanitize_sensitive_context,
    :sandbox,
    :request_correlation_expires_at,
    :actor
  ]

  @typedoc """
  `forward_context` visibility policy for a child agent's tool_context:

    * `:public` — forward the parent's full scope (default; back-compat).
    * `:none` — strip every policy-controlled key.
    * `{:only, keys}` — keep only the listed policy-controlled keys.
    * `{:except, keys}` — strip only the listed policy-controlled keys.

  `keys` range only over `policy_controlled_keys/0`. An unrecognized
  policy — or a `{:only, _}`/`{:except, _}` listing any key outside
  `policy_controlled_keys/0` — fails closed (strips everything
  strippable).
  """
  @type visibility :: :public | :none | {:only, [atom()]} | {:except, [atom()]}

  # Caller-identity + scope-attribution keys a child may not need — the ONLY
  # keys any policy can strip. Always forwarded (absent here, so untouchable):
  # :tenant_id (Ash multitenancy), :session_id/:session_uuid (request
  # correlation + trace linkage), :project_dir (child file tools; child/2 also
  # cwd-fallbacks it).
  @policy_controlled_keys [:user_id, :workspace_id, :workspace_uuid, :actor, :forge_session_key]

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
  Ensure a flat scope is reachable under the nested `:tool_context` key.

  jido_ai flat-merges the caller's `tool_context` map into the `run/2`
  context, so on the live ReAct path the canonical scope keys arrive at the
  **top level** and `context[:tool_context]` is absent. Tools, `OutputShaper`,
  and the tool-approval gate all read `context[:tool_context]`, so this lifts
  a flat, tenant-bearing context into the nested shape they expect.

    * `(a)` an existing non-empty `:tool_context` map is respected unchanged;
    * `(b)` a flat context carrying a string `:tenant_id` is rebuilt nested
      via `build/1`, **excluding `:agent_id`** — jido_ai overwrites it with
      the runtime id, and capturing that into the nested scope would hand
      swarm parent-scoping (`SwarmScope.scope_from_tool_context/1`) and
      telemetry a `:parent_agent_id` they do not see today. Tenant, session,
      and template all lift cleanly without it;
    * `(c)` anything else (no tenant scope to lift) passes through unchanged,
      leaving MCP default-injection to populate scope when nothing lifts.
  """
  @spec ensure_nested(map()) :: map()
  def ensure_nested(%{tool_context: tc} = context) when is_map(tc) and map_size(tc) > 0 do
    context
  end

  def ensure_nested(%{tenant_id: tenant_id} = context) when is_binary(tenant_id) do
    Map.put(context, :tool_context, build(Map.delete(context, :agent_id)))
  end

  def ensure_nested(context) when is_map(context), do: context

  @doc """
  Build a child tool_context map from a parent's tool_context, replacing
  the agent_id with `child_tag` and falling back to `File.cwd!()` for
  `:project_dir` when the parent's value is `nil`.

  This is the canonical helper for swarm tools (`spawn_agent`,
  `send_to_agent`). By itself it forwards the parent's **full** scope —
  `tenant_id`, `session_uuid`, `workspace_uuid`, `forge_session_key`,
  `user_id`, `actor` — rather than just `:project_dir` + `:workspace_id`.
  To narrow what a child sees, route through `child/3` (or pre-apply
  `apply_visibility/2`) with a `forward_context` policy: it nulls the
  policy-controlled keys (`policy_controlled_keys/0`) before this builds
  the child. The structural keys `:tenant_id`/`:session_id`/`:session_uuid`
  and `:project_dir` are **always forwarded** — no policy can strip them,
  so request correlation, trace linkage, multitenancy, and child file
  tools keep working.

  Resets `:agent_template` to `nil` because spawned children are not
  routed via the handoff registry; callers that need a specific template
  attribution should set it explicitly after the call.

  Forces `:subagent` to `true` so the child's durable rows are flagged as
  sub-agent rows (excluded from the primary cold-read view) and its
  `RequestCorrelation` carries the sub-agent identity.
  """
  @spec child(map() | nil, String.t()) :: map()
  def child(parent_tool_context, child_tag) when is_binary(child_tag) do
    parent = parent_tool_context || %{}

    parent
    |> Map.put(:agent_id, child_tag)
    |> Map.put(:agent_template, nil)
    |> Map.put(:subagent, true)
    |> Map.put(:project_dir, Map.get(parent, :project_dir) || File.cwd!())
    |> build()
  end

  @doc """
  Keys a `forward_context` policy may strip. Used by
  `JidoClaw.Agent.Templates` to validate per-template policy config and
  by `apply_visibility/2` as the universe of strippable keys.
  """
  @spec policy_controlled_keys() :: [atom()]
  def policy_controlled_keys, do: @policy_controlled_keys

  @doc """
  Apply a `forward_context` visibility policy to a tool_context map by
  nulling the policy-controlled keys the policy drops.

  `{:only, _}`/`{:except, _}` are symmetric — a policy naming **any**
  key outside `policy_controlled_keys/0` (a typo'd atom or a string key)
  fails closed, stripping every policy-controlled key (matching
  `JidoClaw.Agent.Templates.hydrate_template/1`), so a malformed policy
  can never silently forward the full scope. Structural keys are never
  in the strip universe, so they survive every path. Nulls (rather than
  deletes) so `build/1`'s canonical shape is preserved. An unrecognized
  policy likewise fails closed (strips every policy-controlled key).
  """
  @spec apply_visibility(map(), visibility() | term()) :: map()
  def apply_visibility(ctx, :public) when is_map(ctx), do: ctx
  def apply_visibility(ctx, :none) when is_map(ctx), do: drop_keys(ctx, @policy_controlled_keys)

  def apply_visibility(ctx, {:only, keep}) when is_map(ctx) and is_list(keep) do
    if Enum.all?(keep, &(&1 in @policy_controlled_keys)),
      do: drop_keys(ctx, @policy_controlled_keys -- keep),
      else: drop_keys(ctx, @policy_controlled_keys)
  end

  def apply_visibility(ctx, {:except, drop}) when is_map(ctx) and is_list(drop) do
    if Enum.all?(drop, &(&1 in @policy_controlled_keys)),
      do: drop_keys(ctx, drop),
      else: drop_keys(ctx, @policy_controlled_keys)
  end

  # Fail closed: an unrecognized policy strips everything strippable rather
  # than silently forwarding the full scope.
  def apply_visibility(ctx, _other) when is_map(ctx), do: drop_keys(ctx, @policy_controlled_keys)

  defp drop_keys(map, keys), do: Enum.reduce(keys, map, fn k, acc -> Map.put(acc, k, nil) end)

  @doc """
  Build a child tool_context, applying a `forward_context` visibility
  policy to the parent's scope before delegating to `child/2`.

  Same fail-closed contract as `apply_visibility/2` — an invalid policy
  is in-contract and strips every policy-controlled key.
  """
  @spec child(map() | nil, String.t(), visibility() | term()) :: map()
  def child(parent_tool_context, child_tag, visibility) when is_binary(child_tag) do
    (parent_tool_context || %{})
    |> apply_visibility(visibility)
    |> child(child_tag)
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
