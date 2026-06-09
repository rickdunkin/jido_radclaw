# Resolve new AshCredo warnings: `AuthorizeFalse` (44 sites) + `OverlyPermissivePolicy` (1 site)

## Context

Two new credo rules were enabled in `.credo.exs`: `AshCredo.Check.Warning.AuthorizeFalse` (flags any literal `authorize?: false` in lib code) and `AshCredo.Check.Warning.OverlyPermissivePolicy` (flags unscoped `policy always() / authorize_if always()`). `mix credo` currently reports 45 warnings: 44 `authorize?: false` call sites across 18 files plus one overly-permissive policy in `lib/jido_claw/projects/project.ex:58`.

The codebase already has the exact machinery the checks recommend:
- `JidoClaw.Authorization.Actor.system(tenant_id)` — tenant-bound system actor for internal infrastructure (`lib/jido_claw/authorization/actor.ex`)
- `JidoClaw.Authorization.Checks.ActorTenantMatches` — write-policy check
- `JidoClaw.Resource` macro — standard tenant policy block with a `bypass action(:by_id_global)` for cross-tenant lookups (`lib/jido_claw/resource.ex`)
- Hand-rolled equivalents on orchestration resources, and `multitenancy(:bypass)` read actions for global scans (`WorkflowRun.list_non_terminal_global`)

So the work is mostly mechanical: thread the existing system actor where a tenant is in hand, extend the action-scoped bypass for the few genuinely global lookups, and delete the flag where it was vestigial.

User confirmed: (1) fix the dormant consolidator discovery bug properly now — the project is greenfield, no compatibility layers or data migrations to worry about; (2) `Projects.Project` requires an actor for **all** actions (`actor_present()`), updating the two actor-less tests.

## Key findings from exploration (verified)

1. **Vestigial sites**: Forge `ExecSession`/`Event`/`Checkpoint` and all three Folio resources configure **no authorizers** — `authorize?: false` there is a no-op; deleting it is behavior-neutral (verified via grep: no `authorizers:` key).
2. **`RequestCorrelation`** has a documented intentionally-permissive policy (`policy action_type([...]) / authorize_if always()` — *scoped*, so not flagged). Its sweeper's `authorize?: false` is redundant; deleting is behavior-neutral.
3. **Bypass ordering matters**: empirically verified (Tidewave eval against ETS resources, ash 3.27.8) that a `bypass` appended *after* regular policies is ineffective — Ash's solver folds right-to-left, a bypass only skips policies after it. Also verified two `policies do` blocks merge in declaration order. ⇒ New global actions must be added to the bypass *inside* `JidoClaw.Resource`'s single policies block via a new macro option, not via a second policies block.
4. **Pre-existing dormant bug**: `Memory.Consolidator` discovery (`read_workspaces/0`, `active_session_scopes/1`) reads `Workspace` / `Conversations.Session` with **no tenant**. Both are `global?(false)`, so every read fails with `TenantRequired` (verified via Tidewave: `{:error, "...require a tenant to be specified"}`) and the rescue/case collapses it to `[]` — cron-driven consolidation discovers zero scopes today. `authorize?: false` never bypassed multitenancy; this has been broken since the resources became tenant-required.
5. **Policy-DSL action references are not checked** by `AshCredo.Check.Warning.UnknownAction` (it only resolves raw `Ash.*` call sites), and a bypass naming a nonexistent action compiles fine (verified) — so the macro's bypass list can safely carry names not defined on every resource (status quo: forge `Session` has no `:by_id_global`).
6. Both `ProjectsLive` and `FolioLive` are in the `:require_auth` live_session; `current_actor` (canonical `Actor.build/1` map) is already assigned in `LiveUserAuth.assign_current_user`.
7. `ReactorRunner` requires `:tenant`/`:actor` opts and seeds them into Reactor context, so `Projects.Project` create/undo via the saga always has an actor.

## Changes by group

### A. Macro: `lib/jido_claw/resource.ex`
Add a `global_actions:` option to `use JidoClaw.Resource` — extra action names merged into the bypass:

```elixir
bypass action(unquote(Macro.escape(bypass_actions))) do
  authorize_if(always())
end
```

where `bypass_actions = Enum.uniq([:by_id_global | List.wrap(global_actions)])`, validated at expansion time (raise `ArgumentError` unless all atoms). Default `[]` keeps every existing user identical. Update moduledoc. (Scoped bypasses with `authorize_if always()` are *not* flagged by OverlyPermissivePolicy — verified in check source.)

### B. Genuinely global reads → action-scoped bypass (3 resources, 3 call sites)
- `lib/jido_claw/forge/resources/session.ex`: `use JidoClaw.Resource, ..., global_actions: [:by_name_global]` (action already exists with `multitenancy(:bypass)`; moduledoc already justifies global lookup — names are UUIDs by construction). Then `Forge.Persistence.find_session_global/1` drops `authorize?: false`.
- `lib/jido_claw/orchestration/workflow_run.ex` (hand-rolled policies): `bypass action(:by_id_global)` → `bypass action([:by_id_global, :list_non_terminal_global])`. Then `WorkflowRecovery.reconcile_all/0` drops `authorize?: false`.
- Consolidator fix (see D).

### C. Tenant in hand → `actor: Actor.system(tenant)` (most sites)
Standard policies (`ActorTenantMatches` for writes, `tenant_id == ^actor(:tenant_id)` filter for reads) pass for a system actor built from the same tenant — behavior-preserving.

- `lib/jido_claw/audit/async_writer.ex:138` — `Event.record(tenant: tenant_id, actor: Actor.system(tenant_id))`. Also refresh the stale policy comment in `lib/jido_claw/audit/resources/event.ex` (~line 91) that still says AsyncWriter "bypasses with `authorize?: false`".
- `lib/jido_claw/platform/cron/scheduler.ex:18` — `Job.for_tenant(tenant: tenant_id, actor: Actor.system(tenant_id))`
- `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex` (5 sites: `lock_run`, `next_seq`, `apply_status`, `load_run`, `attempt_step_upsert`) — **thread the caller's actor**: capture `context.actor` in `change/3`, close it over the `before_action`/`after_action` hooks, and pass `actor: context.actor || Actor.system(changeset.tenant)` (preserve the real caller; system actor only as nil fallback). Tenant stays `changeset.tenant`. Any caller actor that reached `:append` necessarily tenant-matches (the append's own `ActorTenantMatches` already passed), so the internal reads/writes authorize identically. Rewrite the moduledoc "Tenant threading" paragraph that currently documents the `authorize?: false` rationale.
- `lib/jido_claw/orchestration/agent_case_event/changes/allocate.ex` (2 sites) — same caller-actor threading pattern.
- `lib/jido_claw/orchestration/cases.ex:362` (`lock_run`) — the enclosing `commit_retract/5` already has the **caller's** `actor` in scope; pass it through rather than minting a system actor.
- `lib/jido_claw/forge/persistence.ex:619` (`session_action_opts/1`, *not flagged* — keyword-list literal evades the check, but same smell): drop `authorize?: false`; it already carries `actor: Actor.system(tenant_id)`.
- Mix tasks (14 sites) — operator CLI tools; each site already has the tenant:
  - `jidoclaw.migrate.solutions.ex` (5): `workspace.tenant_id`
  - `jidoclaw.migrate.conversations.ex` (2): `tenant_id` / `session.tenant_id` (`set_next_sequence` also gains an explicit `tenant:`)
  - `jidoclaw.migrate.memory.ex` (2): `"default"` / per-row `tenant_id`
  - `jidoclaw.migrate.cron.ex` (1): `tenant`
  - `jidoclaw.export.conversations.ex` (2): `tenant` / `session.tenant_id`
  - `jidoclaw.export.memory.ex` (2): `tenant_id` from resolved workspace

### D. Fix the dormant consolidator discovery bug (`lib/jido_claw/memory/consolidator.ex`, 4 sites)
Replace the broken untenanted reads with two new dedicated cross-tenant read actions (in-repo precedent: `WorkflowRun.list_non_terminal_global`):

- `Workspace` (`lib/jido_claw/workspaces/resources/workspace.ex`):
  ```elixir
  read :list_consolidatable_global do
    description("Cross-tenant scan of workspaces eligible for memory consolidation.")
    multitenancy(:bypass)
    filter(expr(consolidation_policy != :disabled))
  end
  ```
- `Conversations.Session` (`lib/jido_claw/conversations/resources/session.ex`):
  ```elixir
  read :list_open_for_workspaces_global do
    description("Cross-tenant scan of open sessions belonging to the given workspaces.")
    multitenancy(:bypass)
    argument(:workspace_ids, {:array, :uuid}, allow_nil?: false)
    filter(expr(workspace_id in ^arg(:workspace_ids) and is_nil(closed_at)))
  end
  ```
Both get `code_interface` defines (required by the enabled `MissingCodeInterface` check) and ride the macro's `global_actions:` bypass. `read_workspaces/0` and `active_session_scopes/1` then call these interfaces directly (the ad-hoc `Ash.Query.filter |> Ash.read` plumbing and both `authorize?: false` pairs go away). No DB schema change — read actions only, no migration needed. Project is greenfield — no compatibility shims.

**Regression test exercises the real discovery path, not just the new actions**: make `candidate_scopes/1` public (`@doc` explaining it's the tick discovery seam) and add a test that seeds two tenants (workspaces incl. one `consolidation_policy: :disabled`, an open + a closed session) and asserts `Consolidator.candidate_scopes/1` returns the expected cross-tenant `:workspace`/`:user`/`:project`/`:session` scopes — exactly the path that silently returned `[]` before.

### E. Web LiveViews (4 sites)
- `lib/jido_claw/web/live/projects_live.ex:11`: `Project.read(actor: socket.assigns.current_actor)` (drop flag; switch from raw `current_user` struct to the canonical actor map).
- `lib/jido_claw/web/live/folio_live.ex` (3): drop `authorize?: false`, pass `socket.assigns.current_actor` (Folio resources have no authorizers — behavior-neutral, keeps the surface uniform).

### F. OverlyPermissivePolicy: `lib/jido_claw/projects/project.ex:58`
Replace the unscoped allow-all with an actor-based condition:

```elixir
policies do
  policy always() do
    authorize_if(actor_present())
  end
end
```

`Project` is deliberately global (no tenant attribute); every production caller already supplies an actor (authed LiveView, `ReactorRunner`-seeded saga context). Update the `reactor_undo` comment that references "authorizes via `policy always()`". Tests that call `Project.read()` / `Project.get_by_github_full_name/1` with no actor (`test/jido_claw/orchestration/reactors/project_registration_test.exs:39,72`; sweep for others) gain `actor: actor_for(tenant)` / `Actor.system(...)` args.

Add a dedicated policy test (e.g. `test/jido_claw/projects/project_policy_test.exs`): actor-less `Project.read()` is denied, actor-ful succeeds; same for a write. During implementation, first check whether `actor_present()` is a simple or filter check (simple ⇒ actor-less read returns `Ash.Error.Forbidden`; filter ⇒ returns `{:ok, []}`) and pin the actual semantics in the assertions.

### G. Behavior-neutral deletions (vestigial flag, no authorizers or allow-all policy)
- `lib/jido_claw/forge/persistence.ex` — 7 sites on `ExecSession`/`Event`/`Checkpoint` (lines 188, 221, 249, 331, 355, 405, 591): delete the option.
- `lib/jido_claw/forge/harness.ex:772` (`Checkpoint.get_by_id`): delete.
- `lib/jido_claw/conversations/resources/request_correlation.ex:285,299` (sweeper): delete; refresh the stale policy comment (lines 74–79) that says the sweeper "bypasses explicitly via `authorize?: false`". The intentionally-permissive-until-v0.7 policy itself stays (it is action-type-scoped, not flagged).

## Files NOT changed
- `.credo.exs` — no exclusions/disables; the point is to fix call sites, not silence the checks.
- `RequestCorrelation`'s permissive policy (documented v0.7 follow-up).

## Verification
1. `mix format`
2. `mix credo` → 0 warnings (the 45 current ones gone, none introduced — watch `MissingCodeInterface` / `ActionMissingDescription` on the new actions)
3. `mix jidoclaw.compile_check` (project's warnings-as-errors gate)
4. `mix test` — full suite; expect and fix fallout only in tests that call `Project` actions actor-less
5. New tests added by this change: consolidator discovery regression test (`candidate_scopes/1` returns seeded cross-tenant scopes instead of `[]`), `Project` policy test (actor-less denied / actor-ful allowed)
6. Tidewave smoke: re-run the originally-failing `Workspace` discovery read via the new code path to confirm it returns rows.
