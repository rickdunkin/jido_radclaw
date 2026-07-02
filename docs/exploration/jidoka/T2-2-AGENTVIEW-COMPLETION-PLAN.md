# T2-2 AgentView Completion Plan

Planning note for finishing Jidoka T2-2, "surface-neutral view projection", in
jido_radclaw. This document is intentionally narrower than
`FEATURES-WORTH-BORROWING.md`: it defines what "complete" means and what work is
required to get there.

Baseline date: 2026-05-31.

> **Status (2026-06-11): EXECUTED — plan complete.** The completion bar was met
> and T2-2 is recorded as ADOPTED in
> [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) (landed in
> commit `7964773` "Surface-neutral view projection", 2026-06-03). The body
> below is unrevised plan-time text — its "Current Baseline" / "Still ad hoc"
> claims describe the pre-work state, not today. Outcome deviations and
> post-plan drift worth knowing:
>
> - `inspect_agent`'s MCP `kind` enum became `module|session|request`, exactly
>   as Resolved Decision 5 recommended. The Search Checks grep for the old
>   `auto … agent_id …` enum therefore no longer matches anything.
> - The MCP publish list has since grown to **24 tools** (`replay_workflow`
>   joined 2026-06-09; `fetch_output`, `inspect_workflow` — AR-2 Phase 5,
>   2026-06-22 — and `workflow_events` — G2-1a, 2026-07-01 — followed), so the
>   `publishes 17 tools` search check is stale; the count assertion lives in
>   `test/jido_claw/mcp_server_test.exs`.
> - `RunSummaryFeed` was deleted outright (the "or replace it with a
>   `WorkflowView` read" branch), not made tenant-keyed.
> - Resolved Decision 6 shipped with one deliberate deviation: `WorkflowRun`
>   got the required-`tenant_id` multitenancy block, but kept a hand-rolled
>   `use Ash.Resource` (needed for the AshCloak extension) instead of
>   switching to `use JidoClaw.Resource`.
> - The post-plan Reactor migration (Phases 0–5, 2026-06-08..10; see
>   `docs/exploration/squidie/REACTOR-ADOPTION.md`) deleted
>   `Workflows.StepAction` and `workflows/{plan,iterative,skill}_workflow.ex`
>   — workflow-step agents now run through `skills/steps/agent_runner.ex`
>   under the `orchestration/` Reactor engine — and replaced
>   `orchestration/approval_gate.ex` with the gate/case family. References to
>   those modules below are historical.

## Summary

T2-2 is not blocked on a mechanical migration of the remaining consumers to the
existing `JidoClaw.AgentView`. The existing view is a session-axis projection:
it answers "what is this chat/session owner doing right now?" by aggregating
`Trace`, `Session.Worker`, `Handoff.Registry`, and compaction state.

The remaining surfaces need other axes:

- Swarm axis: per-agent child-agent rollups from `AgentTracker`.
- Forge axis: sandbox harness/session lifecycle state.
- Workflow axis: durable workflow-run state and recent run summaries.
- Session axis: the existing `AgentView`.

Completion therefore means a small projection family, not one giant struct.
Each projection needs a tenant-safe data source, an MCP-safe public map, and all
UI/CLI/MCP consumers moved away from ad hoc reads.

## Completion Bar

T2-2 can be marked `ADOPTED` only when all of the following are true:

1. `JidoClaw.AgentView` remains the canonical session-axis projection and has no
   known placeholder fields required by current consumers.
2. New canonical projections exist for swarm, Forge, and workflow state.
3. Every tenant-facing projection or tool is scoped from
   `tool_context.tenant_id` or an authenticated `Actor`, and cannot expose
   cross-tenant existence, status, errors, duration, or IDs.
4. The main user-facing consumers no longer hand-roll projection logic from
   `AgentTracker`, `Forge`, `RunSummaryFeed`, or `WorkflowRun`.
5. The MCP server exposes complete status coverage for session, swarm, Forge,
   and workflow views.
6. Tests prove cross-tenant isolation for every tenant-facing projection and
   tool.
7. The inventory document can honestly say there are no deferred surface
   migrations, placeholder data sources, or local-only exceptions for the
   surfaces T2-2 claims to unify.

The strict standard matters: a view module that works locally but cannot be
published over MCP because it reads global state is still `PARTIAL`.

Scope boundary: T2-2 unifies four axes only — session, swarm, Forge, and
workflow. Other CLI status surfaces that read low-level state directly
(`CronScheduler.list_jobs/1`, `Network.Node.status/0`,
`Channel.Supervisor.list_channels/1`, `SolutionsStats`) are explicitly out of
scope, so item 7 above is judged only against the four axes.

## Current Baseline

Already complete:

- `JidoClaw.AgentView.snapshot/2` and `to_mcp_map/1`.
- `JidoClaw.Tools.AgentStatus`.
- `JidoClaw.Web.AgentsLive` consuming `AgentView`.
- Session-axis tenant checks for `agent_status`.

Still ad hoc:

- REPL `/status` and `/agents` read `AgentTracker` directly and render
  `SwarmBox`.
- `JidoClaw.Display` and `Display.StatusBar` read `AgentTracker` directly for
  live swarm updates, swarm summaries, and the terminal status bar.
- Persistent shell `jido status` reads `AgentTracker.get_state/0`, the Forge
  Ash resource via `ForgeSession.list_active/0` (note: a *different* API from the
  LiveViews' `Forge.list_sessions/0`), and `Stats.get/0` directly through
  `CLI.Presenters`.
- `DashboardLive` reads `JidoClaw.Forge.list_sessions/0` and
  `RunSummaryFeed.get_summary/0` directly.
- `ForgeLive` reads `JidoClaw.Forge.list_sessions/0` directly.
- `WorkflowsLive` reads `WorkflowRun.list/1` directly. This was not in the
  original four-consumer estimate; the resolved direction is to keep it as a
  direct Ash resource table, but make that read tenant-scoped and authorized.
- `Tools.ListAgents` still returns a global runtime list if called directly.
  It is not currently MCP-published, but it is in the main agent's own tool
  list, so agent-facing access is still tenant-facing and must be scoped.

Known blocking issue:

- `AgentTracker`, `WorkflowRun`, and Forge sessions are not tenant-scoped enough
  for public exposure. `InspectAgent` already drops `:subagents` and
  `:workflows` for this reason.
- That drop is not the whole safety story: the already-published MCP
  `inspect_agent` tool still routes `kind: "agent_id"` and `kind: "auto"` through
  `Inspection.inspect_agent/2`, which reads `AgentTracker.get_agent/1` by bare
  id. Those modes must become tenant-scoped or be rejected for MCP callers before
  swarm status is considered public-safe.
- Do not rely on today's MCP default tenant as the threat boundary. MCP itself is
  single-scope, but the web/API surfaces derive tenants from authenticated users,
  and the tenant manager supports arbitrary tenants. T2-2 should make the
  underlying status model tenant-correct from the start.

## Projection Family

Use a family of focused modules with shared conventions:

- `snapshot/2` for one target.
- `list/2` for tenant-scoped collections.
- `to_mcp_map/1` for JSON-safe public output.
- `status` enums that match each domain instead of forcing one generic enum.
- `metadata` maps only for stable, non-secret, non-tenant-leaking data.

Recommended modules:

- `JidoClaw.AgentView`: existing session-axis view.
- `JidoClaw.SwarmView`: child-agent and swarm rollup view.
- `JidoClaw.ForgeView`: Forge session/harness view.
- `JidoClaw.WorkflowView`: workflow run and workflow summary view.
- `JidoClaw.RuntimeOverview`: dashboard-level aggregate assembled from the
  three collection views, not a new source of truth.

Do not solve this by adding Forge/workflow/swarm fields to `AgentView`. That
would blur ownership, make tenant boundaries harder to reason about, and repeat
the original problem under a larger struct.

## Tenancy Work

### AgentTracker

`AgentTracker` is currently a process-global singleton with entries keyed by
agent id. Each entry already carries the operational data needed for much of a
swarm rollup: `request_id`, `template`, `task`, status, started/finished
timestamps, error, token count, tool-call count, tool-name set, and last tool.
The missing piece for a public `SwarmView` is scope metadata:

- `tenant_id`
- `session_id`
- `session_uuid`
- `workspace_id` or `workspace_uuid`, if available
- `parent_agent_id`

Required API changes:

- `register/5` (today `register(id, pid, template, task \\ nil, opts \\ [])`,
  where `opts` only recognizes `:request_id`) or equivalent must accept scope
  metadata from `tool_context`.
- `get_state/1` should support `tenant_id: ...`, plus optional
  `session_id`/`workspace_id` filters for narrower views.
- `get_agent/2` should support a tenant option and return `nil` for a real
  agent owned by another tenant. That makes "known id in the wrong tenant" and
  "unknown id" indistinguishable at public boundaries.
- `child_count/1` should count within a tenant/session scope for tenant-facing
  spawn limits. A separate process-global capacity guard may remain if needed
  to protect the BEAM, but it should produce a generic capacity error rather
  than exposing another tenant's child count.
- Existing unscoped APIs can remain only as explicit trusted local/admin
  helpers. UI, CLI, MCP, and agent tool code should not use them for
  user-facing status or runtime operations.

Required call-site changes:

- `Tools.SpawnAgent.register_spawned_agent/6` already builds a scoped child
  `tool_context` but forwards only `request_id` to `AgentTracker.register`; it
  must also pass tenant/session/workspace scope.
- `Tools.SpawnAgent.ensure_agent_id_available/1` and `enforce_spawn_limits/1`
  use bare `AgentTracker.get_agent/1`, `jido_runtime().whereis/1`, and
  `AgentTracker.child_count/0`. Agent ids should stay globally unique because
  the Jido runtime registry is process-global; tenant isolation is enforced by
  checking tracker ownership before a global runtime id is used. Explicit tag
  collisions should return the same generic "id unavailable" error whether the
  id belongs to the caller, another tenant, or the runtime registry.
- `Tools.SendToAgent` and `Tools.GetAgentResult` resolve live pids and request
  ids by bare `agent_id` today (`jido_runtime().whereis/1` plus
  `AgentTracker.get_agent/1`). They must first resolve the agent through scoped
  `AgentTracker.get_agent(agent_id, tenant_id: ...)`, then use the global Jido
  runtime id only after ownership is proven.
- `Tools.KillAgent` is even more direct: it calls `JidoClaw.Jido.stop_agent/1`
  by bare id, and its `"all"` mode calls `JidoClaw.Jido.list_agents/0` then stops
  every non-main agent. Tenant-facing use must be scoped through tracker
  ownership: single-id kill verifies the scoped entry first, and `"all"` stops
  only agents owned by the caller's tenant/session scope.
- `Tools.ListAgents` calls `JidoClaw.Jido.list_agents/0` directly. It should be
  rewritten as a thin wrapper around scoped `SwarmView` for user-facing use. A
  separate local-admin listing can exist only if it is explicit and not exposed
  to the main agent or MCP surfaces.
- `Workflows.StepAction` does **not** register its step agents with
  `AgentTracker` today — it starts them via `JidoClaw.Jido.start_agent` and kills
  them in an `after` block. There is no registration to re-scope. If workflow
  step agents should appear in `SwarmView`, that is new registration work plus a
  design decision on whether ephemeral, per-step agents belong in a swarm rollup
  at all — not a call-site tweak.
- REPL main-agent registration is `AgentTracker.register("main", pid, nil, nil)`
  (`repl.ex:216`) with all-nil scope even though the tenant/session are in hand;
  it should include its tenant/session scope.

Because the project is greenfield, there is no mixed-scope transition to
support. Every tracker registration that can affect a user-facing view or tool
must carry tenant/session scope from the start. A scoped `SwarmView` should drop
unscoped entries by default and tests should treat any unexpected unscoped
entry as a bug, not as legacy data to preserve.

### WorkflowRun

`WorkflowRun` needs a tenant-safe read path before workflow status can be
published over MCP.

Acceptable approaches:

- Add a direct `tenant_id` attribute to `WorkflowRun` and enforce it in create,
  list, active-list, and by-id reads.
- Or prove and enforce tenancy through `project_id -> Project -> tenant_id` —
  but note this chain does not exist today: `JidoClaw.Projects.Project` has no
  `tenant_id` attribute and no multitenancy block, so this option *also* requires
  adding tenant scope to `Project` first.

Direct `tenant_id` is the clearer (and lower-cost) choice: workflow runs are
already queried as operational status, not only as project-owned records, and
the derivation alternative requires touching a second resource before it works
at all. `WorkflowRun` also has no `multitenancy` block today and uses
`use Ash.Resource` directly rather than the project's `use JidoClaw.Resource`
helper — see `Workspaces.Workspace` and `Cron.Job` for the established
`multitenancy { strategy :attribute; attribute :tenant_id; global? false }`
pattern to copy.

Required changes:

- Persist tenant scope on every new run, including scheduled workflow jobs —
  cron-initiated runs currently land with `tenant_id`/`project_id`/`user_id` all
  nil (the tenant is known in `WorkflowRunner`'s in-memory scope but never
  written to the row). Use normal Ash multitenancy (`tenant: tenant_id` plus a
  tenant-bound actor), not `authorize?: false`, for the public create/read path.
- Add tenant-aware `list`, `list_active`, `by_id`, and summary reads. Trusted
  local/admin global reads, if any remain, should be separate actions with names
  that make the bypass obvious (`by_id_global`-style), not the default code
  interface.
- Change `RunSummaryFeed` from a single global summary to tenant-keyed summaries
  or replace it with a `WorkflowView` read that can compute the same data. This
  is gated on the next bullet: the feed builds itself from the global
  `orchestration:runs` topic, whose events carry no tenant, so it cannot key by
  tenant until the events do. Sequence the pubsub-payload change first.
- Ensure workflow events published through `RunPubSub` carry enough scope for
  tenant-keyed feeds (today the `{event, run_id, info}` payload has no
  `tenant_id`/`project_id`).
- If `WorkflowView` exposes step or approval-gate details, those child resources
  need a tenant-safe loading story too. Today `WorkflowStep` and `ApprovalGate`
  have no direct tenant attribute or multitenancy block; detail reads must either
  be authorized strictly through an already-scoped parent run or get their own
  tenant scope.
- `JidoClaw.Inspection.inspect_workflow/1` should become tenant-aware
  (`inspect_workflow(id, tenant_id: ...)` or an equivalent scoped input) before
  `WorkflowRun.by_id` stops being global. Local inspection can still exist, but
  it should not depend on the public by-id action bypassing tenant scope.

### Forge

Forge has two disjoint session sources, and a public `ForgeView` must reconcile
them:

- The `Forge.Manager` GenServer holds an in-memory `MapSet` of session-id
  strings — authoritative for "what is live right now" but carrying no fields.
  `Forge.list_sessions/0` returns *only this list of id strings*, not structs,
  which is exactly why `ForgeLive` can render only a hardcoded `:running` badge.
- The `Forge.Resources.Session` Ash resource holds the rich per-session fields
  (`phase`, `runner_type`, `sandbox_id`, `execution_count`, `last_activity_at`,
  …) but has no `tenant_id`/`workspace_id` and is not multitenant.

So the core Forge work is not just "scope the sessions" — it is deciding which
identifier belongs to the process-global runtime and which identifier is safe
to expose as tenant-owned state. For Jido/OTP compatibility, the runtime
registry key can remain globally unique. Tenant isolation should come from
required scope on the persisted row and an ownership check before any global
runtime key is used.

Required changes:

- Persist tenant and workspace scope on `Forge.Resources.Session` records.
  Because T2-2 publishes `forge_status`, Forge status is not a local-only
  exception.
- Pass tenant/workspace scope into Forge session creation from tool, workflow,
  and shell call sites.
- Add tenant-aware active-session list and session snapshot APIs that join the
  live Manager set to the persisted Ash fields.
- Make `Persistence.claim_session`, `find_session`, `wake`, and recovery paths
  scope-aware. A public or tenant-facing caller must never find or operate on a
  Forge session by bare runtime id alone.
- Decide the identity shape explicitly. Recommended greenfield shape:
  `name` (or a renamed `runtime_id`) remains a globally unique runtime key used
  by `Forge.Manager`, `Registry`, and advisory locks; `tenant_id` and
  `workspace_id` are required attributes and indexed for scoped reads. If
  tenant-local human names are needed, add a separate `public_name`/`label`
  field with a scoped identity such as `[:tenant_id, :workspace_id,
  :public_name]`. Do not make the process-global registry key tenant-local
  unless the Manager/Registry key is also changed to a scoped tuple.
- Include scope in Forge PubSub events (today `{:session_started, session_id}`
  etc. carry only the id, on the global `forge:sessions` topic) so LiveViews can
  update without global refreshes.
- No legacy-session handling: the project is greenfield, so
  `Forge.Resources.Session` carries required `tenant_id`/`workspace_id` from the
  start and every create site sets them. There are no unscoped rows to hide,
  backfill, or migrate.

## View Details

### Session Axis: AgentView

Existing shape is mostly sufficient.

Completion tasks:

- Keep `agent_status` as the session status MCP tool.
- Optionally add `AgentView.list(tenant_id, opts)` so `AgentsLive` no longer
  knows how to enumerate session workers.
- Update module docs if the final projection family means the REPL no longer
  consumes `AgentView` directly.

### Swarm Axis: SwarmView

Purpose: answer "what child agents exist for this tenant/session, what are they
doing, and what have they consumed?"

Suggested fields:

- `tenant_id`
- `session_id`
- `session_uuid`
- `agents`
- `running_count`
- `done_count`
- `error_count`
- `total_tokens`
- `total_tool_calls`
- `generated_at`

Per-agent fields:

- `agent_id`
- `template`
- `task`
- `status`
- `request_id`
- `started_at`
- `finished_at`
- `duration_ms`
- `tokens`
- `tool_calls`
- `tool_names`
- `last_tool`
- `error`

Required consumers:

- REPL `/agents`.
- REPL `/status` swarm section.
- `JidoClaw.Display` live swarm rendering and status-bar agent segment.
- Persistent shell `jido status` agent counts.
- New MCP `swarm_status` tool.
- `JidoClaw.Inspection` (the local module behind REPL inspection) may continue
  to use its own summary shape, but should source subagent lists through
  `SwarmView` once available. This is distinct from the published MCP tool
  `Tools.InspectAgent`, which today drops `:subagents`/`:workflows` for
  tenant-safety but still has an agent-id path through global `AgentTracker`.
  First make that dispatch scoped or unavailable to MCP; then decide whether
  `inspect_agent` re-adds `:subagents`/`:workflows` sourced through safe views or
  stays permanently stripped. Completion-bar item 5 is the test for that
  decision.

### Forge Axis: ForgeView

Purpose: answer "which Forge sessions are active or recently active for this
tenant/workspace, and what phase are they in?"

Suggested collection fields:

- `tenant_id`
- `workspace_id`
- `active_count`
- `sessions`
- `generated_at`

Per-session fields:

- `session_id` or public name
- `phase`
- `runner_type`
- `sandbox_id`
- `execution_count`
- `last_activity_at`
- `started_at`
- `completed_at`
- `last_error`
- `recovering?`

All of these except `recovering?` exist on `Forge.Resources.Session` today
(`name` is the session identity; there is no separate `session_id` column).
`recovering?` is aspirational — recovery is only transient `Forge.Manager`
bookkeeping (`recovery_attempts`) plus a `:session_recovering` PubSub event, not
a queryable field, so deriving it for the view needs a deliberate source.

Required consumers:

- `ForgeLive`.
- `DashboardLive` Forge count.
- Persistent shell `jido status` Forge section.
- New MCP Forge status tool.

### Workflow Axis: WorkflowView

Purpose: answer "which workflow runs are active or recently completed for this
tenant, and what is their state?"

Suggested collection fields:

- `tenant_id`
- `active_count`
- `active_runs`
- `recent_completions`
- `generated_at`

Per-run fields:

- `run_id`
- `name`
- `workflow_type`
- `status`
- `started_at`
- `completed_at`
- `duration_ms`
- `error`
- `result_summary`
- `project_id` only if safe for the caller

Optional detail fields:

- `steps` with step name, status, agent template, duration, and error.
- `approval_gates` if human approval status becomes part of the dashboard.

These detail fields are optional only after the tenant-safety question for
`WorkflowStep` and `ApprovalGate` is answered. A scoped `WorkflowRun` read does
not automatically make direct child-resource reads public-safe.

Required consumers:

- `DashboardLive` recent workflows and active workflow count.
- `WorkflowsLive` remains a direct Ash resource table, but its read must be
  tenant-scoped and authorized.
- New MCP workflow status tool.
- Local `Inspection.inspect_workflow/1` can remain, but should not be the only
  workflow projection.

### RuntimeOverview

Purpose: support dashboard and CLI status summaries without direct reads from
three subsystems.

Suggested fields:

- `tenant_id`
- `session_count`
- `swarm`
- `forge`
- `workflows`
- `uptime`
- `generated_at`

`RuntimeOverview` should compose the view modules. It should not read
`AgentTracker`, `Forge.Manager`, or `RunSummaryFeed` directly unless those reads
are hidden inside the corresponding view module. One source it cannot get from
the three views is `JidoClaw.Stats`: `uptime` and `agents_spawned` come from
`Stats.get/0` today (used by both `/status` and `jido status`), so either
`RuntimeOverview` wraps `Stats` explicitly or those fields stay out.

## MCP Surface

Minimum MCP-complete surface:

- Existing `agent_status`: session-axis status by session id.
- New `swarm_status`: tenant-scoped child-agent list and rollup.
- New `forge_status`: tenant/workspace-scoped Forge active sessions.
- New `workflow_status`: tenant-scoped workflow runs and summary.

Rejected alternative:

- A single `runtime_status` tool can replace the three new tools if it has
  explicit sections for swarm, Forge, and workflows, and all sections are
  tenant-safe. This is simpler for clients but less precise for schema and
  pagination. The resolved direction is three focused tools.

Rules:

- Tenant comes only from `context.tool_context.tenant_id`, never from MCP input.
- Workspace/project filters may come from tool context or from parameters only
  after authorization/scoping is enforced.
- No tool may return process-global `AgentTracker`, `WorkflowRun`, or
  `Forge.Manager` data.
- `Tools.ListAgents` should be rewritten as a thin wrapper around scoped
  `SwarmView` for user-facing use. If a trusted local-admin global listing is
  still useful, it should be a separate explicit API, not this agent tool.
- The already-published `Tools.InspectAgent` is part of the MCP surface. Its
  runtime dispatch should not have a bare-id path. Recommended MCP schema:
  remove `kind: "auto"` and `kind: "agent_id"`; keep `kind: "session"` and
  `kind: "request"` for tenant-scoped runtime inspection, and keep
  `kind: "module"` only if it stays definition-only and never reads
  `AgentTracker` or `WorkflowRun`.
- New status tools are published by adding them to the `publish: %{tools: [...]}`
  list in `lib/jido_claw/core/mcp_server.ex` — a *separate* list from the agent's
  own toolset in `lib/jido_claw/agent/agent.ex` (the one AGENTS.md documents).
  Following the `agent_status`/`inspect_agent` precedent, these introspection
  tools should be MCP-published only and not added to the agent's own tool list.

## Consumer Migration

Primary consumers that must move:

- `JidoClaw.CLI.Commands`:
  - `/agents` uses `SwarmView`.
  - `/status` uses `RuntimeOverview` or `SwarmView` plus `ForgeView` and
    `WorkflowView`.
- `JidoClaw.Display`:
  - Live swarm header/line/summary rendering uses `SwarmView` for the current
    tenant/session scope held in display state.
  - The terminal status bar's agent segment no longer recomputes directly from
    raw `AgentTracker` state.
- `JidoClaw.Shell.Commands.Jido`:
  - `jido status` uses `RuntimeOverview`.
  - `CLI.Presenters.status_lines/1` accepts projection structs/maps rather than
    raw tracker and Forge rows.
- `JidoClaw.Web.DashboardLive`:
  - Replaces direct `Forge.list_sessions/0` and `RunSummaryFeed.get_summary/0`
    reads with `RuntimeOverview` or `ForgeView`/`WorkflowView`.
  - Subscribes to tenant-scoped Forge/workflow updates.
- `JidoClaw.Web.ForgeLive`:
  - Replaces `Forge.list_sessions/0` with `ForgeView.list/2`.
  - Shows real phase/status instead of hardcoded `:running`.

Secondary consumer:

- `JidoClaw.Web.WorkflowsLive`:
  - Keep as a direct Ash resource table rather than a runtime projection.
  - It currently calls `WorkflowRun.list(authorize?: false)` with no tenant, so
    the migration must also stop bypassing authorization — swapping the call
    alone leaves a tenant-scoped resource globally readable.
  - If it stays as a direct Ash resource table, build a tenant actor for the
    logged-in user (`Actor.build(socket.assigns.current_user)`) or assign
    `current_actor` in `LiveUserAuth`; do not pass the raw `%User{}` as the
    authorization actor for a tenant-scoped resource.
  - Document that it is a CRUD-like resource table rather than a runtime
    projection surface; dashboard/MCP workflow status still goes through
    `WorkflowView`.

Existing consumer to preserve:

- `JidoClaw.Web.AgentsLive` should keep using `AgentView`, possibly through a
  new `AgentView.list/2` helper.

## Testing Requirements

Unit tests:

- `AgentView.list/2`, if added.
- `SwarmView` list/snapshot/to_mcp_map.
- `ForgeView` list/snapshot/to_mcp_map.
- `WorkflowView` list/snapshot/to_mcp_map.
- `RuntimeOverview` composition.

Tenant isolation tests:

- Tenant A cannot read tenant B's live session through `agent_status` even when
  the session id is known. Existing tests cover `tenant_required` and
  unknown-session-under-known-tenant, and the `AgentView` unit test covers the
  cold wrong-tenant uuid path, but there is no tool-level test for a session that
  genuinely exists under another tenant — add it, since completion-bar item 6
  requires isolation tests for *every* tenant-facing tool.
- Tenant A cannot see tenant B child agents through `SwarmView` or MCP.
- Tenant A cannot inspect tenant B child-agent metadata through `inspect_agent`
  because MCP no longer accepts `kind: "agent_id"` or `kind: "auto"`.
- Tenant A cannot send to, get results from, kill, or list tenant B child agents
  through any tenant-facing swarm tool. These tools are in the main agent's tool
  list, so they need scoped ownership tests even if they remain unpublished over
  MCP.
- Tenant A cannot see tenant B Forge sessions through `ForgeView` or MCP.
- Tenant A cannot operate on tenant B Forge sessions by a known runtime id; the
  scoped Forge persistence/read path must reject the id before calling
  `Forge.Manager`.
- Tenant A cannot see tenant B workflow runs through `WorkflowView` or MCP.
- Tenant A cannot see tenant B workflow steps or approval gates if those details
  are exposed through `WorkflowView`.
- Unknown IDs in another tenant return `:not_found` or an equivalent
  non-oracle error, not cross-tenant state.

Consumer tests:

- REPL `/agents` and `/status` render from projections.
- `Display` status bar and live swarm updates render from scoped projections.
- Persistent shell `jido status` renders from projections.
- `DashboardLive` updates Forge and workflow sections from projections.
- `ForgeLive` renders phase from `ForgeView`.
- `WorkflowsLive` tests document the intentional direct-resource read with a
  tenant-bound actor and no `authorize?: false`.

MCP tool tests:

- Missing tenant context returns `:tenant_required`.
- Happy paths return JSON-safe maps.
- Cross-tenant rows are hidden.
- `inspect_agent` no longer accepts `agent_id` or `auto` over MCP; `module`
  remains definition-only if it remains published.
- Published tool count/list assertions are updated alongside
  `MCPServer.__publish__/0` so accidental publication of unscoped global tools is
  caught.
- Existing global tools are either removed from tenant-facing surfaces or
  rewritten to prove scoped ownership before calling global runtime APIs.

Regression tests:

- Existing `agent_status` behavior remains stable.
- `inspect_agent` still drops or safely sources fields that are not public.
- Spawn/send/get-result flow still works with scoped `AgentTracker`.
- `kill_agent "all"` stops only agents owned by the caller's scope.
- Workflow and Forge status still update after process restarts where durable
  state exists.

Suggested verification command before marking complete:

```bash
mix format --check-formatted
mix test
mix compile --warnings-as-errors
mix ash_postgres.generate_migrations --check
```

## Work Sequence

1. Lock in the public shape and naming.
   - MCP surface is three tools: `swarm_status`, `forge_status`, and
     `workflow_status`.
   - `WorkflowsLive` stays in scope as a tenant-scoped resource table, not as a
     runtime projection consumer.

2. Add tenant scoping to sources.
   - Scope `AgentTracker`.
   - Scope `WorkflowRun` reads and summaries.
   - Scope `WorkflowStep` / `ApprovalGate` reads if workflow detail fields are
     exposed.
   - Scope Forge sessions and active-session reads.
   - Run `mix ash.codegen` after Ash resource changes and commit the generated
     migrations/snapshots intentionally.

3. Build projection modules.
   - Add `SwarmView`.
   - Add `ForgeView`.
   - Add `WorkflowView`.
   - Add `RuntimeOverview`.

4. Publish MCP tools.
   - Add schemas.
   - Use `JidoClaw.Core.JsonSafe` for output normalization.
   - Enforce tenant context.
   - Register in the `mcp_server.ex` publish list only after isolation tests
     exist.

5. Rewrite consumers.
   - CLI REPL.
   - Display/status bar.
   - Persistent shell command and presenters.
   - DashboardLive.
   - ForgeLive.
   - WorkflowsLive decision.

6. Clean up direct reads.
   - Keep low-level subsystem APIs for owners and local internals.
   - Remove UI/CLI/MCP reads of global runtime state.
   - Update `FEATURES-WORTH-BORROWING.md` after the completion bar is met.

## "Not Complete" Cases

Do not mark T2-2 `ADOPTED` if any of these are true:

- A consumer is moved to `AgentView` but loses swarm/Forge/workflow data.
- MCP exposes global `AgentTracker`, `WorkflowRun`, or Forge session state.
- MCP `inspect_agent` can still resolve bare child-agent ids through global
  `AgentTracker`.
- Tenant-facing swarm write/read tools (`send_to_agent`, `get_agent_result`,
  `kill_agent`, `list_agents`) can address another tenant's child agent by bare
  id before proving scoped tracker ownership.
- The implementation adds public tools without tenant isolation tests.
- `DashboardLive`, shell status, REPL status, or `Display` still computes its own
  runtime projection from low-level sources.
- User-facing status reads `AgentTracker` directly instead of through scoped
  view APIs. The singleton can remain process-global, but every public read must
  filter by required scope.
- Workflow and Forge views exist but are local-only placeholders.

## Search Checks

Useful checks before closing the work:

```bash
rg "AgentTracker.get_state|AgentTracker.get_agent|child_count" lib/jido_claw/web lib/jido_claw/cli lib/jido_claw/shell lib/jido_claw/tools lib/jido_claw/display.ex lib/jido_claw/display
rg "Forge.list_sessions|ForgeSession.list_active|RunSummaryFeed.get_summary" lib/jido_claw/web lib/jido_claw/cli lib/jido_claw/shell lib/jido_claw/tools lib/jido_claw/display.ex lib/jido_claw/display
rg "WorkflowRun.list_active|WorkflowRun.list[(]" lib/jido_claw/web lib/jido_claw/cli lib/jido_claw/shell lib/jido_claw/tools lib/jido_claw/display.ex lib/jido_claw/display
rg "JidoClaw\\.Jido\\.(list_agents|stop_agent)|jido_runtime\\(\\)\\.whereis" lib/jido_claw/web lib/jido_claw/cli lib/jido_claw/shell lib/jido_claw/tools lib/jido_claw/display.ex lib/jido_claw/display
rg "WorkflowRun\\.(by_id|list_active|list\\()|AgentTracker\\.(get_state|get_agent)" lib/jido_claw/inspection.ex
rg "Persistence\\.(find_session|claim_session)|unique_name|authorize\\?: false" lib/jido_claw/forge lib/jido_claw/web/live lib/jido_claw/orchestration
rg "kind: \\{:in, ~w\\(auto module agent_id session request\\)\\}|publishes 17 tools" lib/jido_claw/tools/inspect_agent.ex test/jido_claw/mcp_server_test.exs
```

The original three-line version missed multiple real consumers — the shell's
`ForgeSession.list_active/0` (an Ash read, not `Forge.list_sessions/0`) and
`WorkflowsLive`'s `WorkflowRun.list/1` (the original checked only
`list_active`), plus `JidoClaw.Display`'s direct `AgentTracker` status reads and
the destructive/listing swarm paths through bare `JidoClaw.Jido` ids. They are
included above.

Expected result: UI/CLI/MCP surfaces should call view modules, not these source
APIs. Any remaining unscoped source read should be an explicit trusted
local/admin API outside the T2-2 surfaces.

## Resolved Decisions

Resolved 2026-05-31; revised after review. Posture: **greenfield,
tenant-correct runtime surfaces.** There is no legacy data to migrate, backfill,
hide, or preserve. Required scope columns should be introduced as
`allow_nil?(false)` from their first migration, every create site should set
them immediately, and tests should treat unscoped runtime/status entries as
bugs.

The right compatibility line is not "single tenant, so global runtime is fine."
MCP currently resolves a default `"default"` scope, but web/API surfaces derive
tenant ids from authenticated users and the platform supports arbitrary tenants.
Instead:

- OTP/Jido registries may remain process-global and use globally unique runtime
  ids.
- Tenant-facing code must prove scoped ownership before using a global runtime
  id to read, send, stop, resume, or summarize anything.
- Ash resources should use the project's standard tenant-scoped resource shape
  unless there is a documented reason not to.

1. **MCP shape — three focused tools.** `swarm_status`, `forge_status`, and
   `workflow_status` join the existing `agent_status`, for full four-axis MCP
   coverage (completion-bar item 5 met by coverage, not the smaller-surface
   escape hatch). More schema precision and per-axis pagination than a single
   aggregate `runtime_status`.

2. **Tenant source of truth.** MCP tools read tenant only from
   `context.tool_context.tenant_id` after `MCPScope` has applied its default.
   Web/LiveView code uses `Actor.build(current_user)` or an assigned
   `current_actor`. CLI/REPL code uses the tenant in REPL/session state
   (`"default"` today). No public tool accepts a caller-supplied tenant id as an
   authorization shortcut.

3. **Agent ids stay globally unique, but runtime operations are scoped.** Keep
   globally unique agent ids for Jido registry compatibility. Add
   `tenant_id`/`session_id`/`session_uuid`/`workspace_id`/`parent_agent_id` to
   `AgentTracker` entries at registration time. `SwarmView`, `/agents`,
   `/status`, `Display`, `list_agents`, `send_to_agent`, `get_agent_result`, and
   `kill_agent` all resolve through scoped tracker APIs first. Only after the
   tracker proves ownership may code call `whereis/1`, `stop_agent/1`, or await
   a request id in the global runtime. `kill_agent "all"` means "all agents in
   this caller's scope", not every non-main process in the BEAM.

4. **Spawn limits are scoped plus capacity-protected.** Tenant-facing spawn
   limits use scoped `child_count`. A separate global capacity guard may remain
   to protect the runtime, but its errors should be generic capacity failures
   and should not expose other tenants' counts or ids.

5. **`inspect_agent` MCP restricts runtime dispatch.** Remove MCP
   `kind: "auto"` and `kind: "agent_id"` because they currently read global
   `AgentTracker` by bare id. MCP may keep `kind: "session"` and
   `kind: "request"` for tenant-scoped runtime inspection, and may keep
   `kind: "module"` if it remains definition-only. Local
   `Inspection.inspect_agent/2` can keep richer dispatch for trusted REPL/code
   callers, but subagent/workflow lists should come from scoped `SwarmView` and
   `WorkflowView` once those exist.

6. **`WorkflowRun` gets direct tenant scope.** Switch it from
   `use Ash.Resource` to `use JidoClaw.Resource`, copy the `Cron.Job`
   multitenancy shape (`strategy :attribute; attribute :tenant_id; global?
   false`) with required `tenant_id`, and create/list/read with a tenant-bound
   actor. The `project_id` derivation is rejected because `Projects.Project` is
   not tenant-scoped today. `RunSummaryFeed` becomes tenant-keyed or is replaced
   by `WorkflowView`; `RunPubSub` events include tenant scope. If
   `WorkflowView` exposes steps or approval gates, load them only through an
   already-scoped parent run unless those child resources also get direct tenant
   scope.

7. **Forge sessions are scoped, with a global runtime key.** Add required
   `tenant_id` and `workspace_id` to `Forge.Resources.Session`. Keep the
   process registry/advisory-lock key globally unique for Manager compatibility
   (`name` today, or a renamed `runtime_id`). Scoped reads join the live Manager
   set to persisted Ash rows filtered by tenant/workspace. `Persistence.find`,
   `claim`, `wake`, recovery, stop, and status paths all take scope or operate
   only after a scoped row proves ownership. If tenant-local human names are
   needed, add a separate `public_name`/`label` with a scoped identity; do not
   overload the global runtime key as a tenant-local public name.

8. **`WorkflowsLive` stays a scoped resource table.** It can remain outside
   `WorkflowView` because it is a CRUD/audit table, not a runtime projection,
   but it must call `WorkflowRun.list` with tenant and actor and without
   `authorize?: false`. `WorkflowView` is reserved for dashboard rollups and
   the MCP `workflow_status` tool.

9. **No local-only exception for main-agent tools.** A tool being absent from
   the MCP publish list is not enough if it is present in the main agent's
   toolset. Swarm tools in `lib/jido_claw/agent/agent.ex` are tenant-facing
   because the LLM can call them during a tenant-scoped session, so they must be
   scoped or removed from that toolset.

10. **Completion-bar reconciliation.** `AgentTracker` and `Forge.Manager` may
    remain process-global implementation details, but no UI/CLI/MCP/agent-tool
    surface may expose their global state directly. The public contract is the
    scoped projection or scoped ownership check, not the singleton process.
