# Phase 4 Cleanup — Close gaps from `findings-the-tenanted-zany-catmull.md`

## Context

Phase 4 (commit `bd0da2b`) substantially delivered Steps 1–4 of the v0.6.4
audit log + tenant FK plan. A follow-up audit identified concrete gaps,
and the user's review of v1 of this plan flagged additional issues. User
has clarified scope:

- Project is pre-production. The migration backfill SQL flagged in the
  audit is **out of scope**, as is `tenants/migration_test.exs` (it was
  the backfill round-trip pin).
- Ash codegen is preferred over hand-rolled SQL/migrations. None of the
  changes here require migrations.
- Close every other flagged gap, but be precise about which resources are
  actually tenanted, where actors must be threaded (it's deeper than just
  external call sites), and what the existing infrastructure assumes.

This plan covers three workstreams:

1. **Step A** — single missing audit producer wiring on
   `Memory.Episode.:record`.
2. **Step B** — six missing tests (two consolidated into existing files).
3. **Step C** — Step 5 of the original plan: `Ash.Policy.Authorizer` +
   actor threading. Sliced sharply per user feedback so each slice is
   independently green-able.

---

## Resource scope correction (applies to Step C)

The v1 plan listed 21 resources. The user's review confirmed several are
**not tenant-scoped** — they have no `tenant_id` column and no
multitenancy block. Adding the standard tenant-actor policy to them
would be wrong without a separate migration to introduce a tenant
column. Skip them in this phase:

- `JidoClaw.Reasoning.Resources.Outcome`
  (`lib/jido_claw/reasoning/resources/outcome.ex`) — note the namespace
  is `Reasoning.Resources.Outcome`, not `Reasoning.Outcome`. No tenant.
- `JidoClaw.Embeddings.DispatchWindow`
  (`lib/jido_claw/embeddings/resources/dispatch_window.ex:5`) — explicit
  comment that it has no tenant id.
- All four Forge resources
  (`lib/jido_claw/forge/resources/{checkpoint,event,exec_session,session}.ex`)
  — untenanted.

**Resources actually in scope for Step C** (15 total):

| Resource | File | Notes |
|---|---|---|
| Tenants.Tenant | `tenants/resources/tenant.ex` | Permissive — see C.4 |
| Workspaces.Workspace | `workspaces/resources/workspace.ex` | Standard |
| Conversations.Session | `conversations/resources/session.ex` | Standard |
| Conversations.Message | `conversations/resources/message.ex` | Standard, after C.1 actor propagation |
| Conversations.RequestCorrelation | `conversations/resources/request_correlation.ex:79` | Permissive — see C.4 + remaining-gap callout |
| Solutions.Solution | `solutions/resources/solution.ex` | Standard, after nested-call fix in C.3 |
| Solutions.Reputation | `solutions/resources/reputation.ex` | Standard |
| Solutions.ReputationImport | `solutions/resources/reputation_import.ex` | Standard |
| Memory.Block | `memory/resources/block.ex` | Standard, after BlockRevision nested-call fix |
| Memory.Fact | `memory/resources/fact.ex` | Standard, after `:670` nested-call fix |
| Memory.Episode | `memory/resources/episode.ex` | Standard |
| Memory.Link | `memory/resources/link.ex` | Standard |
| Memory.ConsolidationRun | `memory/resources/consolidation_run.ex` | Standard |
| Memory.BlockRevision | `memory/resources/block_revision.ex` | Standard |
| Memory.FactEpisode | `memory/resources/fact_episode.ex` | Standard |

`Audit.Event` and `Cron.Job` already declare `Ash.Policy.Authorizer` but
use `authorize_if always()`. Step C tightens them last (after AsyncWriter
is updated) — see C.5.

---

## Step A — `Memory.Episode.:record` audit emit

**Single change** in `lib/jido_claw/memory/resources/episode.ex`. After
the last existing `change` (line 83, `RedactContent`), add:

```elixir
change(
  {JidoClaw.Audit.Producers.MemoryWrite,
   [event_kind: :memory_write, target_kind: :memory_episode]}
)
```

Notes:

- `:memory_episode` is already in `Audit.Event.@target_dispatch`
  (`event.ex:65`).
- Episode has no `:source` field (only `:kind`). The `MemoryWrite`
  producer's `actor_kind` lookup falls through to `:agent` — acceptable;
  defer adding a `:source` attribute.

---

## Step B — Missing tests

### B.1 — `audit/session_start_idempotency_test.exs` (new)

Pins the `Session.:start` insert-only + resolver-fallback contract that
guarantees exactly one `:session_start` audit row per session.

```elixir
use JidoClaw.TenantCase, async: false

test "exactly one :session_start audit per session, idempotent reuse" do
  %{tenant_id: tenant, workspace: ws} = seed_full(tenant_label: "idempotency")

  {:ok, sess1} = Resolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1", %{})
  {:ok, sess2} = Resolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1", %{})

  assert sess1.id == sess2.id

  {:ok, events} = Audit.Event.for_target(:session, sess1.id, tenant: tenant)
  starts = Enum.filter(events, &(&1.event_kind == :session_start))
  assert length(starts) == 1
end

test "concurrent first-callers still yield exactly one :session_start" do
  %{tenant_id: tenant, workspace: ws} = seed_full(tenant_label: "concurrent")

  1..50
  |> Task.async_stream(fn _ ->
       Resolver.ensure_session(tenant, ws.id, :web_rpc, "race-1", %{})
     end, max_concurrency: 10)
  |> Stream.run()

  {:ok, sess} = Session.by_external(ws.id, :web_rpc, "race-1", tenant: tenant)
  {:ok, events} = Audit.Event.for_target(:session, sess.id, tenant: tenant)
  starts = Enum.filter(events, &(&1.event_kind == :session_start))
  assert length(starts) == 1
end
```

Depends on `Session.:start`'s after-action audit hook firing only on
insert success (`session.ex:106`, `producers.ex:161`); fallback path
uses `:touch` which has no audit hook.

### B.2 — `v064_cross_tenant_test.exs` (new)

Pins the raw-SQL boundary in `Memory.HybridSearchSql` and
`Solutions.HybridSearchSql`. Both apply `tenant_id = $X` in every CTE
(11+ sites in memory, 4 in solutions) and `Map.fetch!(args, :tenant_id)`
raises if absent.

Cases:

- Seed `Memory.Fact` rows under `tenant_a` and `tenant_b` with overlapping
  scope/labels.
- Drive `Memory.Retrieval.search/1` with a `tool_context` carrying
  `tenant_a`. Assert no `tenant_b` rows in the result. Repeat for the
  recency variant.
- Same shape for `Solutions.Matcher.find_solutions/2`.
- Negative test: pop `:tenant_id` out of `Memory.HybridSearchSql.run/1`
  args; assert `Map.fetch!` raises `KeyError` (the fail-loud contract).

### B.3 — Audit cross-tenant isolation (consolidate into `event_test.exs`)

Add `describe "cross-tenant isolation"` to
`test/jido_claw/audit/event_test.exs`:

- `Audit.Event.read(tenant: tenant_a)` returns no `tenant_b` rows.
- `Audit.Event.for_target(:session, session_b_id, tenant: tenant_a)`
  returns `[]`.

### B.4 — Audit cross-tenant FK validation (consolidate into `event_test.exs`)

Add `describe "cross-tenant FK validation"`. For each tenanted entry in
`@target_dispatch`, build a parent under `tenant_b` and try to write an
audit event under `tenant_a` referencing it. Assert
`{:error, %Ash.Error.Invalid{}}` whose `inspect/1` contains
`"cross_tenant_fk_mismatch"`.

### B.5 — Audit integration (fold into `producers_test.exs`)

Existing `producers_test.exs` exercises producer change modules
directly. Add `describe "real action surfaces"` that drives each
producer via its public action call:

- `Fact.record/promote/invalidate_*`, `Block.write/invalidate`,
  `Episode.record` (after Step A), `Link.create_link`,
  `ConsolidationRun.record_run`, `Solution.store` (shared variant),
  `Session.start`, `Session.close`.

### B.6 — `cron/persistent_disable_test.exs` (new)

The v1 plan's approach used a `:system_job` MFA helper to drive
failures. **This won't work as written**: `Scheduler.build_persistent_opts/1`
(`scheduler.ex:40-47`) drops `mfa_module`, `mfa_function`, and `mfa_args`,
so reloaded jobs lose their MFA and `always_fail/0` would never fire
after restart.

Split the test into the two independent contracts and skip reload
roundtrips:

**Tenant supervisor must exist** before `Cron.Scheduler.schedule/2`
will find a `cron_sup` to start the worker under. `seed_tenant/1`
only creates the Ash row — it doesn't start the per-tenant
`Tenant.InstanceSupervisor`. The fixture must call
`JidoClaw.Tenant.Manager.ensure_tenant(tenant)` (or
`ensure_tenant(tenant, project_dir)`) to bring up the supervisor tree.

**Worker name lookup** — `Cron.Worker` registers via
`{:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}`
(confirmed at `worker.ex:31,36,41,46`). Use
`GenServer.whereis({:via, ...})` to test for liveness.

**Cleanup** — Contract 1 starts a real cron worker under the per-tenant
supervisor. Without an `on_exit` cleanup, the worker survives across
test cases and can leak (and fail) in unrelated tests. Each test that
calls `Cron.Scheduler.schedule/2` must pair it with an
`on_exit(fn -> Cron.Scheduler.unschedule(tenant, "fail-test") end)`
(or the equivalent worker-stop path — verify exact API during
implementation).

**Contract 1**: 3 worker failures persist `disabled_at` to the DB.

```elixir
test "3 failures auto-disable a job and persist disabled_at" do
  tenant = seed_tenant("disable")
  {:ok, _} = JidoClaw.Tenant.Manager.ensure_tenant(tenant)

  {:ok, _job} = Cron.Job.upsert(%{
    job_id: "fail-test",
    schedule_kind: :every,
    schedule_value: "60000",
    mode: :system_job,
    mfa_module: "JidoClaw.Cron.TestSupport",
    mfa_function: "always_fail",
    mfa_args: %{}
  }, tenant: tenant)

  {:ok, "fail-test", _pid} =
    Cron.Scheduler.schedule(tenant,
      id: "fail-test",
      mode: :system_job,
      schedule: {:every, 60_000},
      mfa: {JidoClaw.Cron.TestSupport, :always_fail, []}
    )

  on_exit(fn -> _ = Cron.Scheduler.unschedule(tenant, "fail-test") end)

  for _ <- 1..3, do: Cron.Worker.trigger(tenant, "fail-test")

  # Poll instead of fixed sleep — three casts may not have settled yet
  row = wait_until_disabled("fail-test", tenant)
  assert %DateTime{} = row.disabled_at
end

defp wait_until_disabled(job_id, tenant, attempts \\ 50) do
  Enum.reduce_while(1..attempts, nil, fn _, _ ->
    case Cron.Job.by_job_id(job_id, tenant: tenant) do
      {:ok, %{disabled_at: %DateTime{}} = row} -> {:halt, row}
      _ -> Process.sleep(20); {:cont, nil}
    end
  end) || flunk("disabled_at never set within #{attempts * 20}ms")
end
```

**Contract 2**: rows with `disabled_at` set are excluded by
`Job.for_tenant`, so a scheduler reload doesn't start a worker for
them.

```elixir
test "rows with disabled_at set are not loaded by scheduler reload" do
  tenant = seed_tenant("excluded")
  {:ok, _} = JidoClaw.Tenant.Manager.ensure_tenant(tenant)

  {:ok, job} = Cron.Job.upsert(%{
    job_id: "skip-me",
    schedule_kind: :every,
    schedule_value: "60000",
    mode: :main,
    task: "noop"
  }, tenant: tenant)

  # Disable's exact arity depends on the generated code interface —
  # likely `disable(record, %{}, opts)` for an update action with no
  # required input args. Verify shape during implementation; this may
  # be `Cron.Job.disable(job, %{}, tenant: tenant)`.
  {:ok, _} = Cron.Job.disable(job, %{}, tenant: tenant)

  {:ok, count} = Cron.Scheduler.load_persistent_jobs(tenant, ".")
  assert count == 0

  worker_via =
    {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant, "skip-me"}}}

  refute GenServer.whereis(worker_via)
end
```

Add `JidoClaw.Cron.TestSupport.always_fail/0` under `test/support/`.

**Separate fix flagged but not blocking this test**:
`build_persistent_opts/1` drops mfa fields — system jobs persisted via
`Cron.Job` lose their MFA on reload. Worth fixing in a follow-up but
not part of this plan; the test split above sidesteps it.

---

## Step C — Ash policies + actor threading (sliced)

The v1 plan treated this as one large sweep. The user's review surfaced
several deeper plumbing issues that demand a sharper split: actor
storage in `ToolContext`, actor propagation through `Session.Worker` /
`Recorder` (which write `Message` rows with no actor today), nested Ash
calls inside change modules, and the AsyncWriter audit-write path.
Re-slice into 6 pieces, each independently green-able.

### C.1 — Actor plumbing only (no policies yet)

This slice adds the actor builder and threads `actor` through every path
that will need it, *without* turning on any new policies. After this
slice, the system still works exactly as before — but every Ash call
site that currently passes `tenant:` also passes `actor:`, and `actor`
is available at every internal boundary.

#### C.1.a — `JidoClaw.Authorization.Actor` helper

Lives at `lib/jido_claw/authorization/actor.ex` — a layer-neutral home,
since CLI, Discord, Telegram, MCP, Cron.Worker, and tests all consume it
in addition to the web plugs. The web plugs *consume* this module; they
don't own it.

```elixir
defmodule JidoClaw.Authorization.Actor do
  @moduledoc "Builds the canonical actor map for Ash authorization."

  def build(%JidoClaw.Accounts.User{} = user) do
    %{user_id: user.id, tenant_id: to_string(user.id)}
  end

  def build(nil), do: nil

  @doc """
  Build a tenant-bound system actor. **The actor must carry a tenant_id
  matching the resource being acted on** — the standard policy is
  `tenant_id == ^actor(:tenant_id)`, so a `tenant_id: nil` system actor
  would be denied. Always pass the per-call tenant.
  """
  def system(tenant_id) when is_binary(tenant_id) do
    %{kind: :system, user_id: nil, tenant_id: tenant_id}
  end
end
```

Consolidates the `to_string(user.id)` user→tenant rule. CLI/Discord
contexts use `JidoClaw.Authorization.Actor.system(tenant_id)` (`tenant_id` defaults
to `"default"` for those surfaces). The earlier `system/0` shape would
have failed every standard policy — `tenant_id: nil` doesn't match
`^actor(:tenant_id)`.

#### C.1.b — All three auth surfaces assign `:current_actor`

The v1 plan missed `ApiKeyAuth`. The full set:

- `lib/jido_claw/web/plugs/require_auth.ex:21` — assign
  `:current_actor`.
- `lib/jido_claw/web/plugs/api_key_auth.ex:15` — assign `:current_actor`
  alongside `:current_user`. **`/v1/chat/completions` uses this plug,
  not RequireAuth.**
- `lib/jido_claw/web/channels/user_socket.ex:16` — assign on `connect/2`.

In both plugs, also call `Ash.PlugHelpers.set_actor(conn, actor)`
alongside `assign(conn, :current_actor, actor)`. Our own controllers
read `conn.assigns.current_actor`, but Ash-integrated web code
(AshAdmin, future Ash-extended endpoints) reads from Plug private
state via `Ash.PlugHelpers.get_actor/1`. Keeping both in sync removes
a future footgun.

Update consumers to read `:current_actor`:

- `lib/jido_claw/web/controllers/chat_controller.ex:36, 74`
- `lib/jido_claw/web/channels/rpc_channel.ex:44-67, 79-86`

#### C.1.c — `ToolContext` carries `:actor`

Add `:actor` to `@canonical_keys` in `lib/jido_claw/tool_context.ex:29`.
Update `JidoClaw.chat/4` (`lib/jido_claw.ex:192`) and every other
public chat/history entry point to populate it. Audit:

- `JidoClaw.chat/4` — primary entry; web routes already have
  `:current_actor` after C.1.b, REPL passes
  `Authorization.Actor.system("default")`.
- `JidoClaw.history/3` (if it remains a public API around
  `Message.for_session`) — pass actor; otherwise tenant-scoped reads
  return `[]` post-policy.
- **Cron.Worker chat calls** for `:main` / `:isolated` jobs — the
  worker has `state.tenant_id`; build
  `Authorization.Actor.system(state.tenant_id)`.
- **Discord channel adapter** (Nostrum bot) — uses default-tenant;
  `Authorization.Actor.system("default")`.
- **Telegram channel adapter** (if present) — same shape.
- **MCP default-scope initializer paths** that ensure
  workspace/session before a normal `ToolContext` exists — pass
  `Authorization.Actor.system(tenant_id)` since no user is in scope.
- REPL/CLI builders — `Authorization.Actor.system("default")`.

**Workflow contexts also need actor propagation.** Once `:actor` is in
`@canonical_keys`, `ToolContext.child/2` preserves it. But two
workflow-side helpers will silently drop it unless updated:

- `lib/jido_claw/tools/run_skill.ex` `scope_context/1` — rebuilds a
  scope map for skill steps; add `:actor` to its preserved keys.
- `lib/jido_claw/workflows/step_action.ex` `resolve_scope/3` — same.

Without these, swarm child agents and skill steps run with `actor: nil`
and any tenant-scoped Ash call inside them gets denied. Catch this
during the C.1.f sweep — search `rg 'scope_context|resolve_scope' lib/`
and ensure each helper threads `:actor` like it does `:tenant_id`.

After this change, every tool that reads `tool_context` has access to
the actor without further plumbing.

#### C.1.d — `Session.Worker` carries actor in state

`lib/jido_claw/platform/session/worker.ex:155` writes Message rows with
only `tenant:`. The supervisor entry point is
`JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id)` at
`lib/jido_claw.ex:72` — it does not currently carry an actor.

Required changes:

1. **`Session.Supervisor.ensure_session/3`** — extend to
   `ensure_session(tenant_id, session_id, opts)` where `opts[:actor]` is
   passed through to the worker. New sessions start with the caller's
   actor in state.
2. **`Session.Worker`** — add `:actor` to the GenServer state struct.
   Read it inside `add_message`/`append` paths and pass `actor:
   state.actor` to `Message.append`.
3. **Already-running workers** — when `ensure_session/3` finds a worker
   already running for the same session id, the existing worker's actor
   may be `nil` (set by an earlier caller before this plumbing) or stale
   (set by a different user reusing the same session id). Add
   `Session.Worker.set_actor(tenant_id, session_id, actor)` that updates
   the state. Call it from `ensure_session/3` after the
   already-running detection so the most recent caller's actor wins.

   Alternative: pass `actor` as part of every `add_message` call rather
   than storing it in state. Simpler if every Message.append site has
   the actor in scope; more verbose if not. Recommended: state-stored
   plus `set_actor/3` for the call ergonomics.

After this, every `Message.append(attrs, tenant: state.tenant_id)` site
adds `actor: state.actor` (system actor when `state.actor` is nil — see
C.1.a's `Authorization.Actor.system/1`).

**Concurrency note**: with state-stored actor, an assistant write that
follows a different user's `set_actor/3` call uses whichever actor is
currently in worker state. This is acceptable in v0.6.4 because the
enforced policy only checks `tenant_id`, and a worker is keyed by
`(tenant_id, session_id)` — the `tenant_id` cannot drift between turns.
If a future policy enforces `user_id` matching as well, the safer
shape is to pass `actor` per `add_message` call rather than storing it
in state. Document this constraint in `Session.Worker`'s moduledoc so
the assumption is visible at the next policy expansion.

#### C.1.e — `Recorder` derives actor from `RequestCorrelation`

`lib/jido_claw/conversations/recorder.ex:749-750`:

```elixir
defp attempt_append(attrs, tenant_id) do
  case Message.append(attrs, tenant: tenant_id) do
```

The current shape `attempt_append(attrs, tenant_id)` cannot derive an
actor — there's no correlation row in scope at this layer. Change the
function shape:

```elixir
defp attempt_append(attrs, tenant_id, actor) do
  case Message.append(attrs, tenant: tenant_id, actor: actor) do
```

The actor is built one level up where the correlation/scope is
resolved. Some handlers have the raw `RequestCorrelation` row; others
have a resolved scope map sourced from the Recorder cache (the
two-tier path at `recorder.ex:716-732` returns identical map shapes
from both DB and cache). Phrase the actor build to work for either
shape — derive from the resolved metadata, not the row type:

```elixir
# `scope` is %{user_id:, tenant_id:, session_id:, workspace_id:} —
# the same shape Cache.lookup/1 and the DB fallback both produce.
actor = %{user_id: scope.user_id, tenant_id: scope.tenant_id}
attempt_append(attrs, scope.tenant_id, actor)
```

For signals where no `request_id` resolves a correlation (already
skipped with telemetry today), the path doesn't reach `attempt_append`.
For edge cases where `rc.user_id` is nil (CLI/Discord origins), the
actor is effectively system-shaped — fine since the policy only checks
`tenant_id`.

If pulling actor from the correlation row proves ambiguous in
implementation (e.g. signal handlers don't all have `rc` in scope),
fall back to `actor: JidoClaw.Authorization.Actor.system(tenant_id)`. This is
the same posture as C.5's AsyncWriter bypass — internal infrastructure
acting on a tenant-bound resource.

**Recorder reads also need the actor.** `Recorder.tool_call_parent/3`
(and similar lookup helpers used by tool-result correlation) call
`Message.tool_call_parent(...)` / similar reads — these need `actor:`
threaded through too. A reader without an actor will return `[]` under
the read policy filter, which would silently break tool-result
threading. Search `rg 'Message\.(tool_call_parent|by_live_tool_row|by_id)' lib/jido_claw/conversations/recorder.ex` and pass actor at every call site.

**`Tools.MCPScope.wrap/4` has the same issue** — its `Message.append`
(`mcp_scope.ex:145`) and `Message.by_live_tool_row` (`:174`) calls need
`actor:` too. Read it from `tool_context.actor` (canonical after
C.1.c) or build a system actor from `tc.tenant_id`.

#### C.1.f — Sweep external `tenant:` call sites to also pass `actor:`

The mechanical sweep across ~85 sites (35 files). The actor is now
available at every call boundary:

- Tools: `tool_context.actor`
- Resolvers: `actor` arg
- CLI commands: `state.actor` (add field)
- Mix tasks / sweepers / boot paths: pass nothing — handled in C.4.

Highest-density files: `memory/consolidator/run_server.ex` (17 sites),
`cli/commands.ex` (12), `conversations/resolver.ex` (4),
`solutions/network_facade.ex` (3).

**Direct query paths** also need the actor — not only code-interface
calls. The Ash idiom is to set actor and tenant **at query
construction**, not on the terminal `read!`/`read`:

```elixir
# Preferred: build the query with actor + tenant in one call.
Resource
|> Ash.Query.for_read(:read, %{}, actor: actor, tenant: scope.tenant_id)
|> Ash.Query.filter(...)
|> Ash.Query.sort(...)
|> Ash.read!()

# System reads: same idea — declare the bypass at construction.
Resource
|> Ash.Query.for_read(:read, %{}, authorize?: false)
|> Ash.Query.filter(...)
|> Ash.read!()
```

Don't tack `actor:` onto `Ash.read!()` after a chain of pipes if you
can avoid it — Ash's docs and idiomatic usage put authorization
context on the query, not on the executor.

Sites to update:

- `lib/jido_claw/memory.ex:307` and similar — queries built with
  `Resource |> Ash.Query.filter(...) |> Ash.Query.set_tenant(...) |>
  Ash.read!()`. Convert to the `Ash.Query.for_read/4` shape above with
  `actor:` and `tenant:` set up-front.
- `lib/jido_claw/memory/consolidator.ex:159` (workspaces global
  discovery) and `:214` (sessions global discovery) — these are
  deliberate cross-tenant system reads. Build with
  `Ash.Query.for_read/4` carrying `authorize?: false` (handled in C.4,
  not C.1.f).
- Every other `Ash.Query.set_tenant/2 |> Ash.read*` chain in `lib/`
  needs the same conversion — search `rg 'Ash\.Query\.set_tenant' lib/`
  during implementation; C.1.f's sweep covers these alongside the
  code-interface call sites.

#### C.1.g — Test fixtures gain actor threading

`test/support/jido_claw/{tenant_case.ex, solutions_case.ex}` — every
helper that takes `tenant:` also takes `actor:` (default to
`%{user_id: tenant_id, tenant_id: tenant_id}` to mirror prod's
user→tenant rule).

**Acceptance for C.1**: `mix test` is fully green with no policies
turned on yet.

### C.2 — Nested Ash calls inside change modules

Before any policy is enabled, the nested calls inside change modules
need the actor available. These will start failing the moment their
parent resource gets a tenant-actor policy. Enumerate and fix:

| Site | File:line | Fix |
|---|---|---|
| `Solution.ResolveInitialEmbeddingStatus` reads Workspace | `solution.ex:575` | Read `actor = context.actor` (the `change/3` context arg); pass `actor:` (use `:by_id_global` → bypass when actor absent — already there in `:577`). |
| `Fact.resolve_status_from_policy` reads Workspace | `fact.ex:670` | Same pattern. |
| `Block.:write` writes BlockRevision | `block.ex:443` | Pass `actor: context.actor` (read from the `change/3` context arg) or `authorize?: false` if BlockRevision is intended to be infrastructure-only. Recommended: actor pass-through. |

**The idiomatic pattern** is to use the `change/3` `context` argument,
which `Ash.Resource.Change.change/3` documents as carrying the actor.
Don't spelunk `changeset.context[:private][:actor]` — use the typed
context arg:

```elixir
def change(changeset, _opts, context) do
  Ash.Changeset.before_action(changeset, fn cs ->
    actor = context.actor  # canonical
    tenant_id = cs.tenant
    # ...nested call uses tenant_id + actor
  end)
end
```

When the change is called as a top-level `change` block in a resource
(not a module), use the `change fn changeset, context -> ... end`
two-arity form. Confirm exact arity via `mix usage_rules.docs
Ash.Resource.Change` during implementation.

For BlockRevision specifically, this resource is purely an audit-log
sibling of Block (revisions are written as a side effect of Block
writes). The parent `Block.:write` already has actor in `change/3`
context, so **prefer actor pass-through** to keep BlockRevision under
the same tenant-actor policy as every other tenanted resource. Only
fall back to `bypass action(:create_for_block)` if implementation
proves there's no reliable actor in the side-effect path (e.g. an
internal scheduler triggers a revision write outside any user-driven
changeset). The bypass is a regression risk against future external
call sites; pass-through is the conservative default.

C.2 picks actor-passthrough for all three sites: Solution:575 and
Fact:670 (`:by_id` reads) and Block:443 (BlockRevision write).

### C.3 — Vertical slice 1: Workspace + Session + Message

Now that actor is plumbed (C.1) and nested calls handle the actor (C.2
addresses Solution/Fact/Block; this slice doesn't yet need them), turn
on policies for the conversations/workspaces vertical.

For **Workspace, Session, Message**, add to each:

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer]

policies do
  # Only include this bypass on resources that actually define
  # :by_id_global. Audit.Event and ReputationImport do NOT — see C.5
  # and C.6 notes.
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

**Important — read vs write authorization shapes differ in observable
behavior.** `authorize_if expr(tenant_id == ^actor(:tenant_id))`:

- For **creates/updates/destroys**: returns
  `{:error, %Ash.Error.Forbidden{}}` when the actor's `tenant_id` doesn't
  match the changeset's `tenant_id`. (Ash evaluates the policy at action
  time.)
- For **reads**: applies as a filter on the query. Cross-tenant reads
  return `[]` for collection actions and `nil` (or `Ash.Error.Query.NotFound`,
  depending on `get?`) for `get?` actions — **not** `Forbidden`.

The v1 plan's tests asserted `Forbidden` for cross-tenant reads, which
is wrong. C.6 tests assert the correct shape per action type.

If hard-`Forbidden` reads are desired (defense-in-depth UX), use a
non-filter check via a custom `Ash.Policy.SimpleCheck` module. Defer
this decision; v0.6.4 ships with the filter behavior.

**Acceptance for C.3**: `mix test` is green for the Workspace + Session
+ Message tests with the new policies enabled. No other resources
have policies yet.

### C.4 — System / sweeper / mix-task bypasses + permissive resources

Add `authorize?: false` (or system actor when easier) to:

| Site | File:line |
|---|---|
| RequestCorrelation sweeper | `conversations/request_correlation/sweeper.ex:55` |
| Memory consolidator workspace discovery | `memory/consolidator.ex:159` |
| Memory consolidator session discovery | `memory/consolidator.ex:214` |
| System jobs initializer | `memory/consolidator/system_jobs_initializer.ex:21,23` |
| Cron scheduler boot load | `platform/cron/scheduler.ex:16` |
| Tenant Manager ETS sync | `platform/tenant/manager.ex` (Tenant.create/by_id) |
| `mix jidoclaw.migrate.conversations` | task:198 |
| `mix jidoclaw.migrate.cron` | task:92 |
| `mix jidoclaw.migrate.memory` | task:81, 185 |
| `mix jidoclaw.migrate.solutions` | task:98, 191, 236, 264, 281 |
| `mix jidoclaw.export.conversations` | task:101, 128 |
| `mix jidoclaw.export.memory` | task:66 |

**Permissive policies** (declare authorizer, but `authorize_if always()`
for all actions):

- **Tenants.Tenant** — itself untenanted; ships permissive in v0.6.4.
  Admin scoping for `:archive`/`:suspend` deferred.
- **Conversations.RequestCorrelation** — `global? true` by design
  (`request_correlation.ex:79`). Lookup-by-`request_id` callers
  (Recorder, Session.Worker, sweeper, JidoClaw.chat) have no actor at
  lookup time. Permissive matches existing behavior.

  **Remaining gap** (document in moduledoc and CHANGELOG): with this
  plan applied, `RequestCorrelation` is the only tenanted-resource
  surface that does not enforce tenant-actor matching. Lookup by
  `request_id` is an internal-trust boundary — a malicious actor with a
  valid `request_id` from another tenant could resolve correlation
  metadata. This is the same posture as v0.6.3; this plan does not
  close it. Closing it requires an `agent_id` column on
  `RequestCorrelation` and a tenant-derived from the request id, which
  is v0.7+ work.

### C.5 — AsyncWriter system bypass + Audit.Event/Cron.Job tightening

The v1 plan tightened `Audit.Event` to tenant-actor matching, but missed
that `AsyncWriter.do_record/1` (`async_writer.ex:61`) calls
`Event.record(tenant: tenant_id)` with no actor. Tightening would break
**every audit write** — producer rows, auth events, signal-listener
tool-call rows.

Order of operations:

1. **First, update AsyncWriter** to pass `authorize?: false` on the
   `Event.record/2` call (`async_writer.ex:61`). Audit writes are
   internal infrastructure: a tenant-bound producer call has already
   established the tenant; the audit row's tenant is set from the
   producer's, not negotiated with an actor. `authorize?: false` is the
   right primitive here.
2. **Then, tighten `Audit.Event`**. Note: Audit.Event does **not**
   define `:by_id_global` (`event.ex:101-106` only declares `:record`,
   `:read`, `:for_target`, `:for_actor`). Omit the bypass:

```elixir
policies do
  policy action_type([:create, :update, :destroy]) do
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end

  policy action_type(:read) do
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end
end
```

3. **Then, tighten `Cron.Job`** with the same shape (Cron.Job does
   define `:by_id_global` per the original Step 2 sweep, so include
   the bypass). Verify `Cron.Scheduler.load_persistent_jobs/2` and
   `Cron.Worker.persist_disabled/1` call sites — the worker
   reads/writes Cron.Job at runtime. The worker carries
   `state.tenant_id`, so build a per-tenant system actor:
   `JidoClaw.Authorization.Actor.system(state.tenant_id)`. This matches
   the policy (`tenant_id == ^actor(:tenant_id)`) and avoids
   `authorize?: false`.

   **Normalize `Cron.Job.disable/N` arity at the same time.** Today
   `Cron.Worker.persist_disabled/1` calls
   `Cron.Job.disable(job, tenant: state.tenant_id)` while existing tests
   call `Cron.Job.disable(row, %{}, tenant: tenant_id)`. The two
   shapes differ in arity. When threading actor in C.5, verify the
   generated code interface and normalize both call sites to the same
   form — likely `Cron.Job.disable(job, %{}, tenant: ..., actor: ...)`
   per the action's input arg shape. B.6's Contract 2 already uses the
   3-arity form; reconcile worker.ex with that.

### C.6 — Add policies to remaining resources, then test

Now that all infrastructure handles the actor, add the standard policy
to the rest:

- **Solutions.*** (Solution, Reputation, ReputationImport) — relies on
  C.2's nested-call fix for `solution.ex:575`. **`ReputationImport`
  does not define `:by_id_global`** (`reputation_import.ex:30` only
  has `:record_import` and `:find_by_hash`); omit that bypass for
  ReputationImport.
- **Memory.*** (Block, Fact, Episode, Link, ConsolidationRun,
  BlockRevision, FactEpisode) — relies on C.2's
  `Fact.resolve_status_from_policy` fix and BlockRevision bypass.

Each gets the same standard policy block as C.3, omitting the
`bypass action(:by_id_global)` line for resources without that action
(ReputationImport in this slice; Audit.Event in C.5).

Then write **`test/jido_claw/policy_authz_test.exs`**. Mirror
`event_test.exs` shape: `use JidoClaw.TenantCase, async: false`; setup
seeds two tenants and two actors.

Cover for at least Workspace, Session, Message, Memory.Fact,
Solutions.Solution, RequestCorrelation, Cron.Job, Audit.Event:

1. **Matching actor → success.**
2. **Cross-actor write → `Ash.Error.Forbidden`** (creates/updates/destroys).
3. **Cross-actor read → empty result or NotFound** (filter behavior, NOT
   Forbidden — see C.3 note).
4. **`:by_id_global` bypass works** (no actor needed) — only run this
   case for resources that actually define `:by_id_global`. Skip for
   Audit.Event and ReputationImport per C.5/C.6 setup notes.
5. **`authorize?: false` bypass works** (system path).
6. **Missing actor on writes → `Ash.Error.Forbidden`** (fail-closed).
7. **Missing actor on reads → empty result** (filter behavior).
8. **RequestCorrelation permissive** — lookup with no actor still
   works.
9. **Tenants.Tenant permissive read** — no actor still works.
10. **Audit.Event tightened** — cross-actor read returns empty (filter),
    cross-actor write returns Forbidden.
11. **Cron.Job tightened** — same shape.
12. **AsyncWriter still produces rows** (regression test for the
    `authorize?: false` opt added in C.5.1) — drive any sync producer,
    assert audit row appears.

---

## Critical files modified

**New:**
- `lib/jido_claw/authorization/actor.ex`
- `test/jido_claw/audit/session_start_idempotency_test.exs`
- `test/jido_claw/v064_cross_tenant_test.exs`
- `test/jido_claw/cron/persistent_disable_test.exs`
- `test/jido_claw/policy_authz_test.exs`
- `test/support/jido_claw/cron_test_support.ex`

**Modified (Step A):** `lib/jido_claw/memory/resources/episode.ex`
(one new `change`).

**Modified (Step B test consolidations):**
- `test/jido_claw/audit/event_test.exs` — two new `describe` blocks.
- `test/jido_claw/audit/producers_test.exs` — one new `describe` block.

**Modified (Step C — sliced):**
- **C.1.a-c**: `web/{plugs/{require_auth,api_key_auth},channels/user_socket}.ex`,
  `web/controllers/chat_controller.ex`, `web/channels/rpc_channel.ex`.
- **C.1.c**: `lib/jido_claw/tool_context.ex` (`@canonical_keys` adds
  `:actor`), `lib/jido_claw.ex` (chat/4 propagates).
- **C.1.d**: `lib/jido_claw/platform/session/supervisor.ex` (extend
  `ensure_session/2` to `ensure_session(tenant_id, session_id, opts)`
  with `opts[:actor]`); `lib/jido_claw/platform/session/worker.ex`
  (carry actor in
  state, pass to `Message.append`).
- **C.1.e**: `lib/jido_claw/conversations/recorder.ex` (derive actor
  from `RequestCorrelation`).
- **C.1.f**: ~35 lib files containing the ~85 Ash call sites.
- **C.1.g**: `test/support/jido_claw/{tenant_case,solutions_case}.ex`.
- **C.2**: `lib/jido_claw/solutions/resources/solution.ex` (line 575),
  `lib/jido_claw/memory/resources/fact.ex` (line 670),
  `lib/jido_claw/memory/resources/block.ex` (line 443) +
  BlockRevision bypass.
- **C.3**: 3 resources (Workspace, Session, Message) — add authorizers
  + policies.
- **C.4**: ~12 system / sweeper / mix-task call sites — `authorize?:
  false`. Tenants.Tenant + RequestCorrelation gain permissive policies.
- **C.5**: `lib/jido_claw/audit/async_writer.ex` (line 61 — add
  `authorize?: false`); tighten `audit/resources/event.ex` and
  `cron/resources/job.ex`. Update `Cron.Worker` persistence call to
  pass system actor.
- **C.6**: 10 remaining resources (Solutions.*, Memory.*) — add
  authorizers + policies.

---

## Existing utilities to reuse

- `JidoClaw.TenantCase` (`test/support/jido_claw/tenant_case.ex`) — base
  case for every new test.
- `JidoClaw.Audit.Producers.MemoryWrite` (`audit/producers.ex:18-81`) —
  Step A drop-in.
- Resolver fallback at `conversations/resolver.ex:55-78` — pinned by B.1.
- `Ash.Policy.Authorizer` block already on `Audit.Event` and `Cron.Job` —
  C.5 tightens.
- `to_string(user.id)` user→tenant rule — moved into `Authorization.Actor.build/1`.
- `RequestCorrelation` carries `user_id` and `tenant_id` — C.1.e uses
  this to build a recorder-side actor.

---

## Verification

**Step A:**
- `mix test test/jido_claw/audit/producers_test.exs` includes Episode
  case.
- Manual: `Memory.Episode.record(attrs, tenant: t)`; `Audit.Event.read(tenant:
  t)` includes the row.

**Step B:**
- Each new test passes individually.
- Full `mix test` green.

**Step C — per-slice gates:**

- **C.1**: full `mix test` green; **no behavior change** since policies
  aren't on yet.
- **C.2**: full `mix test` green; nested Ash calls work with actor
  propagated. (Still no policies on.)
- **C.3**: Workspace + Session + Message policy tests (new) pass; full
  suite still green for all other resources.
- **C.4**: system paths and mix tasks still work end-to-end. REPL smoke:
  `mix ecto.reset && mix jidoclaw`; chat, `/cron list`, `remember`/`recall`.
- **C.5**: AsyncWriter regression test (C.6's #12) and Audit.Event/Cron.Job
  tightened tests pass; auth events still write to audit_events.
- **C.6**: `policy_authz_test.exs` passes; full `mix test` green.

**End-to-end:**
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix ash.codegen --check` produces no migrations (policies are
  runtime).
- Web smoke: `mix phx.server`; hit `/v1/chat/completions` (uses
  ApiKeyAuth) and confirm `current_actor` is assigned and tenant-scoped
  reads succeed; hit a RequireAuth-protected route same way.

---

## Slicing for execution

Per CLAUDE.md and user feedback: no commits without explicit request.
The slice list above doubles as a commit boundary suggestion if/when
the user asks. Each of C.1–C.6 is independently green-able and can ship
separately:

1. Step A + B (small, low risk, independent of C).
2. C.1 (actor plumbing only — no policy changes).
3. C.2 (nested Ash calls handle actor — still no policies on).
4. C.3 (turn on policies for the Workspace+Session+Message vertical).
5. C.4 (system bypasses + permissive resources).
6. C.5 (AsyncWriter system bypass, then Audit.Event + Cron.Job tightened).
7. C.6 (remaining policies + acceptance test).

C.1 + C.2 must precede any of C.3–C.6 because every later slice depends
on actor being plumbed and nested calls being safe. C.3 can ship before
C.4–C.6 only if the test suite is willing to tolerate "policies on for
3 of 15 resources" — it is, since each slice's gate is "full mix test
green."

---

## Known remaining gaps (post-plan)

These are explicitly **not closed** by this plan:

- **`RequestCorrelation` permissive policy** (C.4) — lookup by
  `request_id` remains an internal-trust boundary. v0.7+ work to attach
  a tenant-derived check.
- **`Tenants.Tenant` admin scoping** — `:archive`/`:suspend` should
  eventually require an admin actor. v0.6.4 ships permissive.
- **Untenanted resources** (Reasoning.Resources.Outcome, Embeddings,
  Forge.*) — out of scope; would need separate design + migration.
- **`API-key auth audit event`** — was flagged as a known gap in the
  original plan and remains so. ApiKeyAuth (`api_key_auth.ex:13-19`
  success, `:46` failure) does not emit `:auth_event` rows.
- **`Scheduler.build_persistent_opts/1` drops MFA fields** — system
  jobs lose their MFA on reload. Flagged but not fixed; B.6 splits the
  test to sidestep.
