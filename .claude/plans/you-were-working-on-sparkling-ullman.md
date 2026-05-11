# Phase 4 Cleanup — Pickup Plan

Picks up from `.claude/plans/the-plan-was-wrong-snoopy-crown.md`. The
prior plan was substantially executed through Step A, B (mostly), C.1
(except the sweep), and C.2 (except Block). Then it stopped: **C.3, C.4,
C.5 tightening, C.6, and the acceptance test were not started**, and a
few items in completed slices have observable gaps that will bite once
policies turn on.

## Context

This is a continuation of v0.6.4 audit-log + tenant FK + Ash policy
work. The previous session left the codebase in a state where:

- The actor module, plugs, ToolContext, Session.Worker, and Recorder
  are wired (so the *plumbing* is in place for the centrally-controlled
  paths).
- **Authorization is NOT enforced anywhere yet.** The two resources
  that already declare `Ash.Policy.Authorizer` (Audit.Event, Cron.Job)
  ship with `authorize_if always()` — defense-in-depth scaffolding,
  not real enforcement.
- **A large external-call-site sweep (~91 sites) is missing**, and
  several change modules / system bypasses / channel adapters still
  rely on the chat/4 fallback rather than explicit actor passthrough.
  Turning on a single tenant-actor read policy would break the
  consolidator, CLI memory tools, network facade, and resolver paths.

The goal is to finish the policy rollout without leaving regressions,
shipping each slice independently green-able.

---

## What's already done (skip)

**Step A** — `Memory.Episode.:record` audit emit at
`lib/jido_claw/memory/resources/episode.ex:85-88`. ✅

**Step B**:
- B.1 (`session_start_idempotency_test.exs`) ✅
- B.2 (`v064_cross_tenant_test.exs`) ✅
- B.3 (cross-tenant isolation describe in `event_test.exs:210-251`) ✅
- B.5 (`real action surfaces` describe in `producers_test.exs:172-420`) ✅

**Step C.1**:
- C.1.a `JidoClaw.Authorization.Actor`
  (`lib/jido_claw/authorization/actor.ex`) — exports `build/1`,
  `build(nil)`, `system/1`. ✅
- C.1.b — `:current_actor` assigned in `require_auth.ex`,
  `api_key_auth.ex`, `user_socket.ex`; controllers/channels read it. ✅
- C.1.c — `:actor` in `ToolContext.@canonical_keys`,
  `JidoClaw.chat/4` populates, `run_skill.scope_context/1` and
  `step_action.resolve_scope/3` preserve. ✅ (channel-adapter
  explicit-actor calls flagged below — see Cleanup.)
- C.1.d — `Session.Supervisor.ensure_session/3` accepts
  `opts[:actor]`; `Session.Worker` carries actor in state and exposes
  `set_actor/3`. ✅
- C.1.e — `Recorder.attempt_append/3` and `actor_for/1` thread the
  actor; `MCPScope.wrap` reads tool_context.actor with system-actor
  fallback. ✅

**Step C.2**:
- C.2.a `Solution.ResolveInitialEmbeddingStatus`
  (`solution.ex:547-596`) ✅
- C.2.b `Fact.resolve_status_from_policy` (`fact.ex:644-689`) ✅

**Authorizer scaffolding** (with `authorize_if always()`) on
`Audit.Event` (`event.ex:21,89-99`) and `Cron.Job`
(`job.ex:23,43-51`). C.5 below tightens these.

---

## Remaining work

The work splits into two buckets: **Cleanup** of small gaps in
already-shipped slices (must land before any policy goes on), and
**New work** picking up at C.3.

### Cleanup — must land before C.3

#### Cleanup-1 — B.4: Complete cross-tenant FK validation matrix

`test/jido_claw/audit/event_test.exs:253-344` covers only 4 of the 11
tenanted entries in `@target_dispatch` (`event.ex:58-70`). Add cases
for the missing 7: `:solution`, `:memory_block`, `:memory_episode`,
`:memory_link`, `:memory_consolidation_run`, `:reputation`,
`:cron_job`. Use the existing pattern (build a parent under
`tenant_b`, attempt audit write under `tenant_a`, assert
`Ash.Error.Invalid` whose `inspect/1` contains
`"cross_tenant_fk_mismatch"`).

#### Cleanup-2 — C.2.c: `Block.WriteRevisionForUpdate` actor pass-through

`lib/jido_claw/memory/resources/block.ex:419-454` currently:

```elixir
def change(changeset, _opts, _context) do      # context discarded
  Ash.Changeset.after_action(changeset, fn cs, result ->
    ...
    case BlockRevision.create_for_block(attrs, tenant: prior.tenant_id) do
```

Change to `change(changeset, _opts, context)`, capture
`actor = Map.get(context, :actor)`, and pass
`actor: actor, tenant: prior.tenant_id` to `create_for_block`. Same
fix at `block.ex:676` (`write_revision_row/2` called from
`Block.revise/2`).

Without this, every `Block.:write` action fails the moment
`BlockRevision` gets a tenant-actor policy in C.6.

#### Cleanup-3 — C.1.f: External tenant-only call-site sweep

~91 sites in `lib/` pass `tenant:` but no `actor:`. The four named
high-density files have **zero** actor calls today:

- `lib/jido_claw/memory/consolidator/run_server.ex` — 17 sites
- `lib/jido_claw/cli/commands.ex` — 12 sites
- `lib/jido_claw/conversations/resolver.ex` — 4 sites
- `lib/jido_claw/solutions/network_facade.ex` — 3 sites

Plus all of: `memory.ex` (5), `tools/{forget,store_solution,schedule_task,unschedule_task,verify_certificate}.ex`,
`memory/scope.ex`, `solutions/matcher.ex`, `solutions/hybrid_search_sql.ex`,
`workspaces/resolver.ex`, `cron/scheduler.ex` (read paths),
`solutions/resources/solution.ex` (lines 577, 649 — call sites,
not the change module).

The actor is now available everywhere it needs to be:

- Tools — `tool_context.actor` (canonical after C.1.c)
- Resolvers — accept and thread an `actor` arg
- CLI commands (`cli/commands.ex`) — read from CLI state; if absent,
  use `JidoClaw.Authorization.Actor.system("default")`
- Memory consolidator (`run_server.ex`) — its scheduler-driven
  actions belong to a tenant; build
  `JidoClaw.Authorization.Actor.system(tenant_id)` (the worker
  already carries `tenant_id` in state)

**Convert `Ash.Query.set_tenant/2` chains to `Ash.Query.for_read/4`**:
4 sites in `memory.ex:307,318,329,340` use the `set_tenant` shape.
Plus any other `rg 'Ash\.Query\.set_tenant' lib/` matches found
during the sweep. Move auth context to the query construction:

```elixir
Resource
|> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_id)
|> Ash.Query.filter(...)
|> Ash.read!()
```

For the deliberate cross-tenant system reads at
`memory/consolidator.ex:159` (Workspace global discovery) and
`:214` (Session global discovery), build with `authorize?: false` —
these are handled in C.4 below; just ensure they're left alone here.

#### Cleanup-4 — C.1.g: Test fixture actor threading

`test/support/jido_claw/tenant_case.ex` has an `actor_for/1` helper
(line 78-81) but the `seed_workspace/2` (line 100), `seed_session/3`
(line 122), and other seeders only pass `tenant:`. Wire `actor:` through
each seeder so that downstream resource calls within fixtures are
authorized correctly once policies turn on.

`test/support/jido_claw/solutions_case.ex` — add an `actor_for/1`
helper (mirror tenant_case) and thread `actor:` through
`workspace_fixture/2` (line 71) and `solution_fixture/4` (line 121).

#### Cleanup-5 — C.1.c: Channel adapter explicit actor calls (optional but recommended)

`JidoClaw.chat/4` builds a system actor at lines 72-76 when none is
passed, so the following sites work *by fallback* but the plan called
for explicit calls. Updating them removes the implicit dependency on
chat/4's fallback shape:

| Site | File | Today | Change to |
|---|---|---|---|
| Cron.Worker `:main`/`:isolated` chat | `platform/cron/worker.ex:119,127` | no actor | `JidoClaw.Authorization.Actor.system(state.tenant_id)` |
| Discord adapter | `platform/channel/discord.ex:46` | no actor | `JidoClaw.Authorization.Actor.system("default")` |
| Telegram adapter | `platform/channel/telegram.ex:45` | no actor | `JidoClaw.Authorization.Actor.system("default")` |
| MCP default-scope initializer | `mcp_scope/initializer.ex:71-79` | scope map missing `:actor` | add `:actor` to scope map (read by ToolContext.build) |
| REPL ensure_session | `cli/repl.ex:152` | no actor passed to Session.Supervisor | pass `actor: Authorization.Actor.system("default")` |

Functionally optional, but skipping these means a future change to
chat/4's fallback shape silently breaks these adapters.

#### Cleanup-6 — B.6: Verify `Cron.Job.disable` arity

`platform/cron/worker.ex:223` calls `Job.disable(job, tenant: ...)`
(2-arity) and `test/jido_claw/cron/persistent_disable_test.exs:94`
matches. But `test/jido_claw/cron/job_test.exs:85,140` use 3-arity
`disable(row, %{}, tenant: ...)`. The Ash code interface for an update
action with `accept([])` typically generates a 2-arity
`disable(record, opts \\ [])`. Run `mix test test/jido_claw/cron/job_test.exs`
once during this slice to confirm both arities work — if 3-arity
fails, normalize the older test to 2-arity. **Do not touch this until
verifying** — if it currently passes, leave it.

---

### New work

#### C.3 — Vertical slice 1: Workspace + Session + Message policies

Add to each of:

- `lib/jido_claw/workspaces/resources/workspace.ex`
- `lib/jido_claw/conversations/resources/session.ex`
- `lib/jido_claw/conversations/resources/message.ex`

The standard policy block:

```elixir
use Ash.Resource,
  ...,
  authorizers: [Ash.Policy.Authorizer]

policies do
  bypass action(:by_id_global) do
    authorize_if always()
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end

  policy action_type(:read) do
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end
end
```

Verify each resource defines `:by_id_global`; omit the bypass for any
that doesn't. (Workspace, Session, Message all do — verify during
implementation.)

**Read vs write behavior gotcha**: cross-tenant *reads* return `[]`
(or `nil` for `get?` actions), not `Forbidden`. Only writes raise
`Ash.Error.Forbidden`. The C.6 acceptance test asserts the correct
shape per action type — don't pattern-match `Forbidden` on reads.

**Acceptance for C.3**: full `mix test` green. The sweep in Cleanup-3
must land first or test failures will mask C.3-specific regressions.

#### C.4 — System bypasses + permissive resources

##### Bypasses (12 sites)

Add `authorize?: false` to:

| Site | File:line |
|---|---|
| RequestCorrelation sweeper | `lib/jido_claw/conversations/request_correlation/sweeper.ex:55` |
| Memory consolidator workspace global discovery | `lib/jido_claw/memory/consolidator.ex:159` |
| Memory consolidator session global discovery | `lib/jido_claw/memory/consolidator.ex:214` |
| System jobs initializer | `lib/jido_claw/memory/consolidator/system_jobs_initializer.ex:21,23` |
| Cron scheduler boot load | `lib/jido_claw/platform/cron/scheduler.ex:16` |
| Tenant Manager ETS sync | `lib/jido_claw/platform/tenant/manager.ex` (Tenant.create/by_id sites) |
| `mix jidoclaw.migrate.conversations` | `lib/mix/tasks/jidoclaw.migrate.conversations.ex` |
| `mix jidoclaw.migrate.cron` | `lib/mix/tasks/jidoclaw.migrate.cron.ex` |
| `mix jidoclaw.migrate.memory` | `lib/mix/tasks/jidoclaw.migrate.memory.ex` |
| `mix jidoclaw.migrate.solutions` | `lib/mix/tasks/jidoclaw.migrate.solutions.ex` |
| `mix jidoclaw.export.conversations` | `lib/mix/tasks/jidoclaw.export.conversations.ex` |
| `mix jidoclaw.export.memory` | `lib/mix/tasks/jidoclaw.export.memory.ex` |

For each, wire `authorize?: false` at the `Ash.read*` / code-interface
call site (the same place tenant: is set).

##### Permissive policies (2 resources)

Declare authorizer + always-allow policies on:

- `lib/jido_claw/tenants/resources/tenant.ex` — Tenant itself is
  untenanted; admin scoping is deferred.
- `lib/jido_claw/conversations/resources/request_correlation.ex` —
  `global? true` by design; lookup-by-`request_id` callers have no
  actor at lookup time.

Both get:

```elixir
policies do
  policy action_type([:read, :create, :update, :destroy]) do
    authorize_if always()
  end
end
```

Document the `RequestCorrelation` posture in its moduledoc + the
v0.6.4 CHANGELOG: lookup by `request_id` is an internal-trust
boundary; closing this gap requires `agent_id` on RequestCorrelation
(v0.7+).

#### C.5 — AsyncWriter bypass + Audit.Event/Cron.Job tightening

**Order matters** — bypass first, then tighten, or audit writes break.

1. **`lib/jido_claw/audit/async_writer.ex:61`** — change
   `Event.record(tenant: tenant_id)` to
   `Event.record(tenant: tenant_id, authorize?: false)`.

2. **Tighten `Audit.Event`** (`lib/jido_claw/audit/resources/event.ex:89-99`)
   — replace the current `authorize_if(always())` block with:

   ```elixir
   policies do
     policy action_type(:create) do
       authorize_if expr(tenant_id == ^actor(:tenant_id))
     end

     policy action_type(:read) do
       authorize_if expr(tenant_id == ^actor(:tenant_id))
     end
   end
   ```

   Audit.Event has no update/destroy actions and no `:by_id_global`;
   omit those policies and the bypass.

3. **Tighten `Cron.Job`** (`lib/jido_claw/cron/resources/job.ex:43-51`)
   — keep the existing `bypass action(:by_id_global)`, replace the
   permissive `policy action_type([:read, :create, :update, :destroy])`
   with:

   ```elixir
   policy action_type([:create, :update, :destroy]) do
     authorize_if expr(tenant_id == ^actor(:tenant_id))
   end

   policy action_type(:read) do
     authorize_if expr(tenant_id == ^actor(:tenant_id))
   end
   ```

4. **Update `Cron.Worker.persist_disabled/1`**
   (`lib/jido_claw/platform/cron/worker.ex:220-234`) to pass a system
   actor:

   ```elixir
   defp persist_disabled(state) do
     actor = JidoClaw.Authorization.Actor.system(state.tenant_id)

     case JidoClaw.Cron.Job.by_job_id(state.id, tenant: state.tenant_id, actor: actor) do
       {:ok, job} ->
         case JidoClaw.Cron.Job.disable(job, tenant: state.tenant_id, actor: actor) do
           ...
   ```

   Also add `actor:` to `Cron.Job.by_job_id`/`for_tenant` calls
   elsewhere in the worker — its `enable`/`reschedule`/`status`
   public functions if they hit Ash.

#### C.6 — Remaining policies + acceptance test

Add the standard policy block (with `bypass action(:by_id_global)`
where applicable) to:

| Resource | by_id_global? |
|---|---|
| `lib/jido_claw/solutions/resources/solution.ex` | yes |
| `lib/jido_claw/solutions/resources/reputation.ex` | yes |
| `lib/jido_claw/solutions/resources/reputation_import.ex` | **no** — only `:record_import`/`:find_by_hash`; omit the bypass |
| `lib/jido_claw/memory/resources/block.ex` | yes |
| `lib/jido_claw/memory/resources/fact.ex` | yes |
| `lib/jido_claw/memory/resources/episode.ex` | yes |
| `lib/jido_claw/memory/resources/link.ex` | yes |
| `lib/jido_claw/memory/resources/consolidation_run.ex` | yes |
| `lib/jido_claw/memory/resources/block_revision.ex` | yes (verify; if not, omit) |
| `lib/jido_claw/memory/resources/fact_episode.ex` | yes (verify; if not, omit) |

For each, verify the `:by_id_global` action exists before adding the
bypass — `rg 'def.*:by_id_global|action :by_id_global' lib/jido_claw/<file>`.

##### Acceptance test — `test/jido_claw/policy_authz_test.exs`

`use JidoClaw.TenantCase, async: false`. Setup seeds two tenants
(`tenant_a`, `tenant_b`) and two actors via `actor_for/1` from
TenantCase. Cover at minimum:

1. **Matching actor → success** (Workspace, Session, Message,
   Memory.Fact, Solutions.Solution, Cron.Job, Audit.Event)
2. **Cross-actor write → `Ash.Error.Forbidden`**
   (creates/updates/destroys)
3. **Cross-actor read → empty result or NotFound** (filter behavior,
   NOT `Forbidden`)
4. **`:by_id_global` bypass works** without an actor — only on
   resources defining it (skip Audit.Event, ReputationImport)
5. **`authorize?: false` bypass works** (system path)
6. **Missing actor on writes → `Ash.Error.Forbidden`** (fail-closed)
7. **Missing actor on reads → empty result** (filter)
8. **RequestCorrelation permissive** — lookup with no actor still works
9. **Tenants.Tenant permissive read** — no actor still works
10. **Audit.Event tightened** — cross-actor read empty (filter),
    cross-actor write `Forbidden`
11. **Cron.Job tightened** — same shape
12. **AsyncWriter still produces rows** (regression for the
    `authorize?: false` opt added in C.5.1) — drive any sync producer,
    assert audit row appears

---

## Critical files modified

**New**: `test/jido_claw/policy_authz_test.exs`.

**Modified — Cleanup**:
- `test/jido_claw/audit/event_test.exs` (add 7 FK cases)
- `lib/jido_claw/memory/resources/block.ex` (lines 424, 676 actor
  passthrough)
- ~35 lib files for the C.1.f sweep (high density:
  `memory/consolidator/run_server.ex`, `cli/commands.ex`,
  `conversations/resolver.ex`, `solutions/network_facade.ex`,
  `memory.ex`, plus tools/, resolvers/, scope.ex, matcher.ex)
- `test/support/jido_claw/{tenant_case,solutions_case}.ex` (actor
  threading in seeders)
- (optional) `lib/jido_claw/platform/cron/worker.ex`,
  `platform/channel/{discord,telegram}.ex`,
  `mcp_scope/initializer.ex`, `cli/repl.ex` (channel-adapter explicit
  actors)

**Modified — C.3**: `workspaces/resources/workspace.ex`,
`conversations/resources/{session,message}.ex` — add authorizers + 3
policies each.

**Modified — C.4**: ~12 system call sites add `authorize?: false`;
`tenants/resources/tenant.ex` and `conversations/resources/request_correlation.ex`
gain permissive policies.

**Modified — C.5**: `audit/async_writer.ex:61` adds `authorize?: false`;
`audit/resources/event.ex:89-99` tightens; `cron/resources/job.ex:48-50`
tightens; `platform/cron/worker.ex:220-234` passes system actor.

**Modified — C.6**: 10 resources add authorizers + standard policy
block.

---

## Existing utilities to reuse

- `JidoClaw.Authorization.Actor.{build/1,system/1}`
  (`lib/jido_claw/authorization/actor.ex`) — system actor builder.
- `JidoClaw.TenantCase.actor_for/1`
  (`test/support/jido_claw/tenant_case.ex:78-81`) — test helper.
- `Ash.PlugHelpers.set_actor/2` — already wired in both plugs;
  consumers already read `:current_actor`.
- `JidoClaw.chat/4` system-actor fallback at `lib/jido_claw.ex:72-76`
  — keeps Cleanup-5 from being load-bearing.

---

## Verification

**Per-slice gates** (CLAUDE.md: no commits without explicit request,
but each slice should be independently green):

- **Cleanup-1, Cleanup-2, Cleanup-3, Cleanup-4** (Cleanup-5
  optional): `mix test` green. No behavior change yet — still no
  policies on (beyond the existing permissive Audit.Event /
  Cron.Job).
- **Cleanup-6**: `mix test test/jido_claw/cron/job_test.exs` green;
  arity reconciled or confirmed-both-supported.
- **C.3**: `mix test` green. Workspace/Session/Message policies on.
  No other resource has policies yet.
- **C.4**: system paths, mix tasks, REPL all still work end-to-end.
  Manual smoke: `mix ecto.reset && mix jidoclaw`; chat,
  `/cron list`, `remember`/`recall`.
- **C.5**: `mix test` green; auth events still appearing in
  `audit_events` after producer drives. Audit.Event and Cron.Job
  cross-tenant reads/writes behave per the policy shapes.
- **C.6**: `mix test` green; `policy_authz_test.exs` passes.

**End-to-end**:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix ash.codegen --check` produces no migrations (policies are
  runtime).
- Web smoke: `mix phx.server`; hit `/v1/chat/completions` (ApiKeyAuth)
  and a RequireAuth-protected route; confirm tenant-scoped reads
  succeed under the assigned actor.

---

## Slicing for execution

CLAUDE.md memory says no commits without explicit request — the slice
list below doubles as commit-boundary suggestions if/when asked.
Each is independently green-able:

1. **Cleanup-1 + Cleanup-2** (B.4 FK cases + Block actor passthrough)
   — small, independent.
2. **Cleanup-3** (the ~91-site sweep) — biggest single slice; do this
   alone. Mostly mechanical but touches ~35 files.
3. **Cleanup-4** (test fixture actor threading) — small, depends on
   Cleanup-3 only insofar as the test harness should match prod call
   shape.
4. **Cleanup-5** (channel adapter explicit actors) — optional; can
   ship at any point or skip entirely.
5. **Cleanup-6** (Cron.Job.disable arity) — verify-only; small.
6. **C.3** (Workspace+Session+Message policies on).
7. **C.4** (system bypasses + permissive resources).
8. **C.5** (AsyncWriter bypass, then Audit.Event + Cron.Job tightened).
9. **C.6** (remaining 10 resources + acceptance test).

Cleanup-1 through Cleanup-4 must precede C.3. Cleanup-5 and Cleanup-6
are independent. C.3 must precede C.4–C.6 only insofar as we want
each slice's full-suite gate to be green.

---

## Known remaining gaps (post-plan)

Same as the original plan — these stay open for v0.7+:

- `RequestCorrelation` permissive policy — internal-trust boundary,
  needs `agent_id` column to close.
- `Tenants.Tenant` admin scoping — `:archive`/`:suspend` should
  require admin actor.
- Untenanted resources (Reasoning.Resources.Outcome, Embeddings,
  Forge.*) — out of scope.
- API-key auth audit event — ApiKeyAuth doesn't emit `:auth_event`
  rows.
- `Scheduler.build_persistent_opts/1` drops MFA fields on reload —
  flagged but not fixed; B.6 split sidesteps.
