# Phase 4 — v0.6.4 Audit Log + Tenant FK Promotion

## Context

Phases 0–3 of the v0.6 migration added `tenant_id text` columns to 14 Ash
resources and wired cross-tenant FK validation hooks at write time. The column
is still just text — no FK to a `tenants` table, no Ash multitenancy filter,
no audit log of who wrote what. Phase 4 closes those gaps:

1. Promote the `tenant_id` text column on every tenanted resource to a real FK
   pointing at a new `Tenants.Tenant` Ash resource.
2. Switch every tenant-scoped resource to `multitenancy :attribute` so the SQL
   layer enforces the boundary, not just the action argument.
3. Add an append-only `Audit.Event` resource fed by hybrid sync/async producers.
4. Migrate `.jido/cron.yaml` to a `Platform.Cron.Job` Ash resource.
5. Deprecate the `Reasoning.Outcome` string columns now that Phase 0's UUID
   siblings carry the same data.
6. (Follow-up step) Layer Ash policies on top of multitenancy with actor-based
   authorization.

The plan source is `docs/plans/v0.6/phase-4-audit-tenant.md`.

User-confirmed decisions:
- **Audit dispatch: hybrid** — sync for tx-bound producers, async for hot-path
  tool calls and auth events.
- **Tenant resource: minimal** — mirror the existing `JidoClaw.Tenant` struct
  (`lib/jido_claw/platform/tenant.ex`).
- **Multitenancy strategy: `:attribute` on every tenanted resource** with one
  exception (RequestCorrelation, see Step 1.G).
- **Auth scope: AuthController only** for `:auth_event`. Known gap: API-key
  auth at `lib/jido_claw/web/plugs/api_key_auth.ex` is not covered.
- **Policies: separate Step 5** with actor threading across every Ash call site.
- **RequestCorrelation: `multitenancy :attribute, global?: true`** so the
  cross-tenant sweeper at `lib/jido_claw/conversations/request_correlation/sweeper.ex:55`
  keeps working and the 6 by-`request_id` lookup callers stay unchanged.

Terminology: this plan refers to "Steps 1–5" as the slicing units. Each step is
a self-contained change; everything reviews and commits together once the full
plan is implemented (no per-step commits).

---

## Step slicing (5 steps)

| # | Scope | Risk |
|---|---|---|
| 1 | Tenants resource + FK promotion + `:attribute` multitenancy + cross-tenant FK hook rewrite + `ensure_tenant` flow | High |
| 2 | Audit log + SignalBus producer + AuthController + tx-bound producers | Medium |
| 3 | Cron.Job resource + migrator + scheduler/CLI/tools refactor | Low |
| 4 | Reasoning.Outcome string deprecation + residual file-store sweep | Low |
| 5 | Ash policies + actor threading | Medium |

Step 3 depends on Step 1's tenants table (its own migration adds an FK to
tenants(id)). Step 5 depends on Step 1's multitenancy. Steps 2 and 4 don't
strictly depend on each other.

---

## Step 1 — `JidoClaw.Tenants` domain, FK promotion, `:attribute` multitenancy

### 1.A — Resource

```
lib/jido_claw/tenants/
  domain.ex                 # JidoClaw.Tenants
  resources/
    tenant.ex               # JidoClaw.Tenants.Tenant
```

`Tenants.Tenant` resource:
- Primary key pinned to `:string` per §4.2 step 1:
  `attribute :id, :string, primary_key?: true, allow_nil?: false, default: &generate_id/0`.
  Generator mirrors `lib/jido_claw/platform/tenant.ex:32` (`"tenant_<base64>"`).
- Attributes match the existing struct:
  `name :string`, `status :atom (:active | :suspended | :terminating)`,
  `config :map`, `archived_at :utc_datetime_usec, allow_nil? true`, `timestamps()`.
- Actions: `create :register` declared with `upsert? true` and
  `upsert_fields([:updated_at])` (mirrors
  `lib/jido_claw/workspaces/resources/workspace.ex:71`). Omitting
  `upsert_identity` defaults to the primary key, so a duplicate-`id`
  insert collapses onto the existing row and only `updated_at` is touched
  — `status`, `name`, `config` are preserved, so a `:suspended` tenant
  isn't reactivated by a routine `ensure/1` call.
  Plus `update :suspend`, `update :resume`, `update :archive` (soft, sets
  `status: :terminating` + `archived_at`), `read :list`, `read :by_id`
  with `args: [:id], get?: true` (codebase convention at
  `lib/jido_claw/conversations/resources/session.ex:53-54`).
- `code_interface`: `register/1`, `suspend/1`, `resume/1`, `archive/1`,
  `by_id/1`, `list/0`. No `destroy` — Audit.Event rows in Step 2 FK at this
  row, and a hard delete would orphan history.

Add `JidoClaw.Tenants` to `:ash_domains` in `config/config.exs:222-236`.

### 1.B — Authoritative table list

The 14 tenanted resources, with the exact `table()` names verified against the
resource modules:

| # | Module | Table |
|---|---|---|
| 1 | `JidoClaw.Workspaces.Workspace` | `workspaces` |
| 2 | `JidoClaw.Conversations.Session` | `conversation_sessions` |
| 3 | `JidoClaw.Conversations.Message` | `messages` |
| 4 | `JidoClaw.Conversations.RequestCorrelation` | `request_correlations` |
| 5 | `JidoClaw.Solutions.Solution` | `solutions` |
| 6 | `JidoClaw.Solutions.Reputation` | `reputations` |
| 7 | `JidoClaw.Solutions.ReputationImport` | `reputation_imports` |
| 8 | `JidoClaw.Memory.Block` | `memory_blocks` |
| 9 | `JidoClaw.Memory.Fact` | `memory_facts` |
| 10 | `JidoClaw.Memory.Episode` | `memory_episodes` |
| 11 | `JidoClaw.Memory.Link` | `memory_links` |
| 12 | `JidoClaw.Memory.ConsolidationRun` | `memory_consolidation_runs` |
| 13 | `JidoClaw.Memory.BlockRevision` | `memory_block_revisions` |
| 14 | `JidoClaw.Memory.FactEpisode` | `memory_fact_episodes` |

Step 2 adds a 15th (`audit_events`); Step 3 adds a 16th (`cron_jobs`). Each
adds its own FK constraint in its own migration — Step 1's `@tenanted_tables`
list is exactly the 14 above.

### 1.C — Migration: backfill + FK promotion in one go

`mix ash.codegen v064_tenants_promotion` produces the create-table migration.
Hand-edit it. **Use explicit `up/0` and `down/0` rather than `change/0`**
for the FK-promotion block — `execute(forward, "")` inside `change/0`
sends an empty SQL statement on rollback, which is risky. Explicit
direction lets the rollback drop the FK constraints in reverse, then
drop the tenants table:

```elixir
def up do
  # 1. Create tenants (id text PK)
  create table(:tenants, primary_key: false) do
    add :id, :text, primary_key: true
    add :name, :text, null: false
    add :status, :text, null: false, default: "active"
    add :config, :map, default: %{}
    add :archived_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

# 2. Backfill from union of distinct tenant_id strings across every
#    source table that already carries a tenant_id text column.
#    Use UTC-normalized timestamps to match this codebase's existing
#    migration convention (every prior migration uses
#    `fragment("(now() AT TIME ZONE 'utc')")` — see
#    priv/repo/migrations/20260503202649_v060_create_messages_and_request_correlations.exs:41).
execute("""
INSERT INTO tenants (id, name, status, config, inserted_at, updated_at)
SELECT DISTINCT tid, tid AS name, 'active', '{}'::jsonb,
       (now() AT TIME ZONE 'utc'),
       (now() AT TIME ZONE 'utc')
FROM (
  SELECT tenant_id AS tid FROM workspaces
  UNION SELECT tenant_id FROM conversation_sessions
  UNION SELECT tenant_id FROM messages
  UNION SELECT tenant_id FROM request_correlations
  UNION SELECT tenant_id FROM solutions
  UNION SELECT tenant_id FROM reputations
  UNION SELECT tenant_id FROM reputation_imports
  UNION SELECT tenant_id FROM memory_blocks
  UNION SELECT tenant_id FROM memory_facts
  UNION SELECT tenant_id FROM memory_episodes
  UNION SELECT tenant_id FROM memory_links
  UNION SELECT tenant_id FROM memory_consolidation_runs
  UNION SELECT tenant_id FROM memory_block_revisions
  UNION SELECT tenant_id FROM memory_fact_episodes
) t
WHERE tid IS NOT NULL
ON CONFLICT (id) DO NOTHING
""", "")

# 3. ADD CONSTRAINT NOT VALID, then VALIDATE per table.
#    Note: this list is a *local* var inside change/0 (or a
#    module-level @attribute outside it), not @-prefixed inside
#    a function — Elixir module attributes are compile-time and
#    must be declared at module scope.
tenanted_tables = [
  "workspaces", "conversation_sessions", "messages", "request_correlations",
  "solutions", "reputations", "reputation_imports",
  "memory_blocks", "memory_facts", "memory_episodes", "memory_links",
  "memory_consolidation_runs", "memory_block_revisions", "memory_fact_episodes"
]

  for table <- tenanted_tables do
    execute("""
    ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES tenants(id)
      NOT VALID
    """)

    execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{table}_tenant_id_fkey")
  end
end

def down do
  tenanted_tables = [
    "workspaces", "conversation_sessions", "messages", "request_correlations",
    "solutions", "reputations", "reputation_imports",
    "memory_blocks", "memory_facts", "memory_episodes", "memory_links",
    "memory_consolidation_runs", "memory_block_revisions", "memory_fact_episodes"
  ]

  for table <- tenanted_tables do
    execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{table}_tenant_id_fkey")
  end

  drop table(:tenants)
end
```

Verified by reading the generated migration body, not just by running it
(per §4.5 acceptance gate language).

### 1.D — `:attribute` multitenancy on each resource

For each of the 14 tables (with the RequestCorrelation exception in 1.G), add:

```elixir
multitenancy do
  strategy :attribute
  attribute :tenant_id
  global? false
end
```

Then **delete** the now-redundant pieces this introduces:

- `argument(:tenant_id, :string, allow_nil?: false)` on every read action
  (`workspace.ex:109,122`, `session.ex:144`, `block.ex:141,152`, `fact.ex`,
  `episode.ex:80`, `message.ex:228`). Ash supplies it from the tenant set on
  the changeset/query.
- `tenant_id == ^arg(:tenant_id) and ...` clauses inside those filters
  (~30 occurrences). The implicit Ash filter replaces them.
- `tenant_id` from the create `accept` lists too — `workspace.ex:65`,
  `solution.ex` `:store` accept block, `message.ex:146`, `session.ex:70`,
  `episode.ex:60`, `block.ex:108`, etc. With multitenancy on, `tenant_id`
  flows in via `Ash.Changeset.set_tenant/2`, not `accept`. Leaving it on
  `accept` invites mismatches between params and tenant context.
  **Exception**: `RequestCorrelation.:register` keeps `tenant_id` in `accept`
  per 1.G — its caller at `lib/jido_claw.ex:192` passes it in attrs, and
  `global? true` means there's no implicit-tenant path to receive it from.
- Manual `Ash.Query.filter(tenant_id == ^tenant ...)` in custom preparations
  (`memory/resources/episode.ex:247-315`,
  `memory/resources/block.ex` for_scope_chain,
  `memory/resources/fact.ex` consolidator queries,
  `conversations/resources/message.ex:518` consolidator). Each becomes the
  scope-only filter; Ash injects the tenant guard.

**AshPostgres index/identity churn**: enabling `:attribute` multitenancy makes
the migration generator add `tenant_id` to identities and custom indexes
unless `all_tenants? true` is set on each. Many of our existing identities
already lead with `tenant_id` (e.g. `Workspace.unique_user_path_authed`,
`Block.unique_label_per_scope_*`), so they're already correctly shaped — but
verify `mix ash_postgres.generate_migrations` output before committing. For
indexes that should remain global (e.g. `request_correlations.request_id`),
mark `all_tenants? true`.

### 1.E — Caller migration: correct Ash APIs

The right APIs:

- For code-interface calls: pass `tenant: tenant_id` opt
  (e.g. `Workspace.register(attrs, tenant: tenant_id)`).
- For changesets built by hand:
  `Ash.Changeset.for_create(Resource, :action, attrs, tenant: tenant_id)` or
  `Ash.Changeset.set_tenant(cs, tenant_id)`.
- For queries built by hand:
  `Ash.Query.for_read(Resource, :action, args, tenant: tenant_id)` or
  `Ash.Query.set_tenant(query, tenant_id)`.

(Note: `Ash.set_tenant/2` and `Ash.Query.unset_tenant/0` do **not** exist;
`Ash.Changeset.set_tenant/2` and `Ash.Query.set_tenant/2` do. To opt out of
the tenant filter on a per-action basis, use `multitenancy :bypass` at the
action level — see 1.F.)

Caller surface to update (greppable):

| File | Today | After |
|---|---|---|
| `lib/jido_claw/workspaces/resolver.ex:19,29` | `Workspace.register(...)` with tenant in attrs | `Workspace.register(attrs_minus_tenant, tenant: tenant_id)` |
| `lib/jido_claw/conversations/resolver.ex:38` | Same pattern | Same fix |
| `lib/jido_claw/conversations/recorder.ex` (5 sites) | `Message.append`/`Message.import` | `Message.append(attrs, tenant: tenant_id)` |
| `lib/jido_claw/memory/consolidator/run_server.ex` | proposal commits + `:record_run` | thread tenant via `tenant:` |
| `lib/jido_claw/memory/retrieval.ex`, `hybrid_search_sql.ex` | reads | `tenant:` |
| `lib/jido_claw/solutions/matcher.ex`, `network_facade.ex`, `reads/*.ex` | reads | `tenant:` |
| `lib/mix/tasks/jidoclaw.migrate.{solutions,memory,conversations}.ex` | uses default tenant | `tenant: "default"` |
| `lib/mix/tasks/jidoclaw.export.*` | per-tenant read loop | `tenant:` per loop |
| `lib/jido_claw/web/controllers/chat_controller.ex:15-16`, `lib/jido_claw/web/channels/rpc_channel.ex:103` | `tenant_id = to_string(user.id)` | unchanged at the source; downstream Ash calls switch to `tenant:` |
| `lib/jido_claw/platform/session/worker.ex:155` | `Message.append(attrs)` (tenant denormalized from session via the soon-to-be-validation hook) | `Message.append(attrs, tenant: state.tenant_id)` |
| `lib/jido_claw/tools/mcp_scope.ex:145` | `Message.append(attrs)` inside `attempt_append/1` | `Message.append(attrs, tenant: tc.tenant_id)` (read from enriched tool context) |
| `lib/jido_claw/tools/mcp_scope.ex:174` | `Message.by_live_tool_row(session_id, request_id, tool_call_id, role)` | add `tenant: tc.tenant_id` |
| `lib/jido_claw/platform/session/worker.ex:255` | `Message.for_session(session_uuid)` | `Message.for_session(session_uuid, tenant: state.tenant_id)` |
| `lib/jido_claw/tools/forget.ex:57` | `Ash.get(JidoClaw.Memory.Fact, id, domain: ...)` + `Fact.invalidate_by_id(fact, ...)` | both calls take `tenant: tool_context.tenant_id` |
| `lib/jido_claw/cli/commands.ex:295` | `Block.for_scope_chain(scope.tenant_id, chain)` (positional tenant arg) | `Block.for_scope_chain(chain, tenant: scope.tenant_id)` after dropping the leading positional `tenant_id` arg per 1.D |
| `lib/jido_claw/solutions/resources/solution.ex:614` (internal call inside an action) | `Reputation.get(record.tenant_id, record.agent_id)` (positional) | `Reputation.get(record.agent_id, tenant: record.tenant_id)` after the positional tenant arg is dropped |

This list is non-exhaustive — see "Implementation guardrail" at the bottom
for the `rg` checklist that must run clean before Step 1 is considered done.

### 1.F — Cross-tenant validation hooks: rewrite to read parents via `:by_id_global`

The existing hooks fetch parents globally. With `global? false` they error.
Each parent resource gets a dedicated read action that opts out of the tenant
filter using **action-level** `multitenancy :bypass`:

```elixir
read :by_id_global do
  get? true
  multitenancy :bypass
  argument :id, :uuid, allow_nil?: false
  filter expr(id == ^arg(:id))
end
```

Add `:by_id_global` to every tenanted parent referenced by a cross-tenant
validation hook:

- `Workspaces.Workspace`
- `Conversations.Session`
- `Conversations.Message` — needed because `CrossTenantFk` validates
  `source_message_id` from `Memory.Episode`
  (`lib/jido_claw/security/cross_tenant_fk.ex:38`,
  `lib/jido_claw/memory/resources/episode.ex:67,203`).
- `Solutions.Solution` — needed for `source_solution_id` (same Episode
  validation list at `episode.ex:68`).
- `Memory.Block`, `Memory.Fact`, `Memory.Episode` (used as parents by
  `BlockRevision`, `FactEpisode`, `Link`, `ConsolidationRun`).

Each hook below switches to the matching `:by_id_global` action, then
performs the existing parent-tenant comparison and rejects mismatches
with `:cross_tenant_fk_mismatch`. The bypass is **only** for these
validation hooks — non-validation reads use tenant-scoped paths
(see "Embedding-policy reads" below).

**Validation hooks** (read-then-compare-then-reject):
1. `lib/jido_claw/conversations/resources/session.ex:78-101` (`:start` inline `before_action`) — read Workspace via `Workspace.by_id_global/1`.
2. `lib/jido_claw/conversations/resources/message.ex:463-498` (`Changes.ValidateCrossTenantFk`) — read Session via `Session.by_id_global/1`.
3. `lib/jido_claw/solutions/resources/solution.ex:458-524` — Workspace + Session via the `_global` actions.
4. `lib/jido_claw/conversations/resources/request_correlation.ex:246-309` — same.
5. `lib/jido_claw/security/cross_tenant_fk.ex:106-124` (shared validator used by Memory.Block:329, Memory.Fact:560, Memory.Episode:200, Memory.ConsolidationRun:288) — replace `Ash.get(parent, ...)` with the matching `:by_id_global` action.

**Denormalize hooks become validation hooks** under multitenancy. Pre-Phase-4
they read the parent, then *force-copy* `tenant_id` onto the child. After
Step 1.D removes `tenant_id` from accept lists, the caller already passed
`tenant:` so the child's tenant_id is set; the hook should now read the
parent globally and **validate** rather than overwrite — same shape as the
validation hooks above.

| File | Hook today | Hook after |
|---|---|---|
| `lib/jido_claw/conversations/resources/message.ex:370-389` (`Changes.DenormalizeTenant`) | `Session.by_id(session_id)` + `force_change_attribute(:tenant_id, parent.tenant_id)` | `Session.by_id_global(session_id)` + reject if mismatch |
| `lib/jido_claw/memory/resources/fact_episode.ex:112-130` (`Changes.DenormalizeTenant`) | `Ash.get(Fact)` + `Ash.get(Episode)` + force-set | `:by_id_global` for both + reject mismatch |
| `lib/jido_claw/memory/resources/link.ex:160-180` (`Changes.ValidateScopeAndDenormalize`) | `Ash.get(Fact)` for both endpoints + force-set | `Fact.by_id_global/1` for both + reject mismatch |
| `lib/jido_claw/memory/resources/block.ex:409-420` (BlockRevision write inside `:write`/`:invalidate`) | reads parent Block | call `BlockRevision.create_for_block` with `tenant:` set on the child create from the outer changeset |

**Non-validation parent reads — prefer tenant-scoped, not bypass.** These
read tenanted parents to derive child state. Unlike cross-tenant
validation, the calling code already knows the correct tenant; routing
them through `:by_id_global` would mean a bogus session id from another
tenant could supply wrong ancestors. Use `tenant:` instead:

| File | What it reads | Fix |
|---|---|---|
| `lib/jido_claw/memory/resources/fact.ex:621` (`resolve_status_from_policy`) | Workspace `embedding_policy` | The hook runs inside `Fact.:record`'s before_action; thread the tenant from the changeset (use `cs.tenant` field access — `Ash.Changeset.set_tenant/2` is the setter; the public reader is the struct field per `deps/ash/lib/ash/changeset/changeset.ex:1073`. Verify exact form via `mix usage_rules.docs Ash.Changeset` before writing). Pass it as `Workspace.by_id(workspace_id, tenant: cs.tenant)`. Add a tenant-scoped `:by_id` get-action to Workspace (separate from `:by_id_global`). |
| `lib/jido_claw/solutions/resources/solution.ex:478, 550` (embedding-policy resolution) | Workspace `embedding_policy` | Same shape — read tenant from the changeset. |
| `lib/jido_claw/memory/scope.ex:130-146` (`maybe_load_session_ancestors`) | Session `workspace_id`/`user_id` | `Memory.Scope.resolve/1` already carries `tenant_id`; thread it into the helper: `Session.by_id(session_id, tenant: scope.tenant_id)`. |
| `lib/jido_claw/memory/scope.ex:148-158` (`maybe_load_workspace_ancestors`) | Workspace `user_id`/`project_id` | Same — pass `tenant: scope.tenant_id`. |

Add a `:by_id` read action (with `args: [:id], get?: true`) to Workspace
and Session. This is distinct from `:by_id_global`: `:by_id` participates
in multitenancy normally; `:by_id_global` opts out via
`multitenancy :bypass` for cross-tenant validation only.

**Raw-SQL search paths** — `lib/jido_claw/memory/hybrid_search_sql.ex` and
`lib/jido_claw/solutions/hybrid_search_sql.ex` (entry point: `run/1` on
both, with `Memory.HybridSearchSql.run_recency/1` for the recency variant)
already include explicit `tenant_id = $1` predicates; Ash multitenancy
doesn't apply to raw queries. Step 1.J's isolation regression test must
exercise these via the public callers (`Memory.Retrieval.search/2`,
`Solutions.Matcher`) and assert no leak — they're the only paths that
bypass Ash entirely.

### 1.G — `RequestCorrelation` special case

`lib/jido_claw/conversations/resources/request_correlation.ex` is fundamentally
a global-access resource. Confirmed call sites:

- `lib/jido_claw.ex:192` (`register_correlation/5`): `register` — passes
  `tenant_id` in attrs.
- `lib/jido_claw/conversations/recorder.ex:253,410` (`record_telemetry`).
- `lib/jido_claw/conversations/recorder.ex:721` (`lookup`).
- `lib/jido_claw/platform/session/worker.ex:309` (`durable_lookup/1`).
- `lib/jido_claw/conversations/request_correlation/sweeper.ex:55`
  (`sweep_expired/0`).

Resolution:

```elixir
# in resources/request_correlation.ex
multitenancy do
  strategy :attribute
  attribute :tenant_id
  global? true
end
```

`global? true` means reads/queries without an explicit tenant return rows
across tenants (today's behavior). The FK promotion in 1.C still applies.
The `:register` action **keeps `tenant_id` in its `accept` list** because:
(a) the caller at `jido_claw.ex:192` passes it in attrs, and (b) `global?
true` means there's no caller-context tenant for Ash to inject. Keeping it
accepted is the least-disruptive change for this resource. Document the
exception inline in the moduledoc so future readers don't apply the 1.D
sweep to it.

`request_id` is a globally-unique string (UUIDv4); cross-tenant lookup is
collision-free.

### 1.H — `ensure_tenant` flow

Today the only `JidoClaw.Tenant.Manager.ensure_tenant/2` caller in `lib/` is
`lib/jido_claw/memory/consolidator/system_jobs_initializer.ex:21` for the
`"system"` tenant. After Step 1.C's FK promotion, an unregistered tenant
string fails the `_tenant_id_fkey` constraint on the first FK-bearing write.

Add the ensure step at the **resolver layer** so every entry point benefits.
`lib/jido_claw/workspaces/resolver.ex:19` (`ensure_workspace/3`) gains a
step 0 that calls `Tenants.Tenant.ensure/1`:

```elixir
def ensure(tenant_id) when is_binary(tenant_id) do
  __MODULE__.register(
    %{id: tenant_id, name: tenant_id, status: :active}
  )
end
```

The action is declared with `upsert? true` and `upsert_fields([:updated_at])`
(see 1.A), so:
- Omitting `upsert_identity` defaults to the primary key — concurrent
  first-writes for the same id collapse onto the same row, no race window.
- `upsert_fields([:updated_at])` means a duplicate-id call **only** touches
  `updated_at`. A `:suspended` tenant won't be reactivated by a routine
  workspace resolve; `name`/`status`/`config` survive.

Update `JidoClaw.Tenant.Manager` to call `Tenants.Tenant.ensure/1` from its
`:ensure` GenServer call so the ETS cache and the Postgres row stay in sync.
The Manager keeps its supervision-tree role
(`Tenant.InstanceSupervisor` per-tenant cron supervisors); the ETS table
becomes a hot cache for the supervisor lookup, not the source of truth.

### 1.I — Dead code to remove

- `JidoClaw.Repo.prepare_query/2` floated in §0.5.2 — verified absent in
  `lib/jido_claw/repo.ex`. Nothing to remove; just delete the §0.5.2
  reference once the multitenancy filter handles it.

### 1.J — Tests

- `test/jido_claw/tenants/tenant_test.exs` — resource actions, status
  transitions, `ensure/1` race-safe upsert (run 50 concurrent
  `Task.async`'d `ensure("same-id")` calls; assert exactly one row).
- `test/jido_claw/tenants/migration_test.exs` — fixture: insert rows under
  two distinct tenant strings before the migration runs; run migration;
  assert FK constraint exists, both tenant strings have a row in `tenants`,
  and the FK is `VALID`.
- **Cross-tenant boundary regression** (`test/jido_claw/v064_cross_tenant_test.exs`):
  seed Workspace/Session/Solution/Memory rows under tenants `"a"` and `"b"`;
  run reads with `tenant: "a"` and assert no `"b"` rows leak. Cover the four
  memory scope reads (user/workspace/project/session) and the public
  callers of the raw-SQL paths — `Memory.Retrieval.search/2` (which calls
  `Memory.HybridSearchSql.run/1`) and `Solutions.Matcher` (which calls
  `Solutions.HybridSearchSql.run/1`). Both raw-SQL modules carry their
  own `tenant_id = $1` predicates; the test pins that those predicates
  are populated correctly when invoked via the public surface.
- `RequestCorrelation` global-access pin: with `global? true`, a read
  without a tenant returns rows from both tenants. Pin this so a later
  "tighten RequestCorrelation" sweep doesn't quietly break the sweeper.
- Cross-tenant FK regression: feed the validation hooks a constructed
  mismatch (Workspace in tenant A, Session.start with `tenant: B`,
  `workspace_id: <ws_in_a>`); assert `:cross_tenant_fk_mismatch`. Cover
  every hook listed in 1.F.

---

## Step 2 — `JidoClaw.Audit` domain, `Audit.Event` resource, producers

### 2.A — Resource

```
lib/jido_claw/audit/
  domain.ex                 # JidoClaw.Audit
  resources/
    event.ex                # JidoClaw.Audit.Event
  async_writer.ex           # Task.Supervisor wrapper
  signal_listener.ex        # SignalBus subscriber for :tool_call
```

`Audit.Event` resource:
- Attributes per §4.1: `tenant_id text`, `event_kind atom`, `actor_kind atom`,
  `actor_id text`, `target_kind atom`, `target_id text`,
  `payload map`, `inserted_at utc_datetime_usec`. `target_id` is `:string`
  (not `:uuid`) so cron job ids and other text ids work.
- Actions: `create :record`, `read :read` (default), plus
  `read :for_target` (`args: [:target_kind, :target_id]`) and
  `read :for_actor` (`args: [:actor_kind, :actor_id]`) for the future
  audit-search UI. **No `update`, no `destroy`** — append-only per §4.1.
- `multitenancy :attribute, attribute: :tenant_id, global? false`.
- Indexes (custom_indexes block):
  - `(tenant_id, event_kind, inserted_at)` — primary search.
  - `(tenant_id, actor_kind, actor_id, inserted_at)` — "what did this actor do."
  - `(tenant_id, target_kind, target_id, inserted_at)` — "what happened to this row."
- Cross-tenant FK validation: a `before_action` that uses an explicit
  `target_kind → {resource, domain}` map. When `target_kind` matches an
  entry in the map, the hook reads the parent via that parent's
  `:by_id_global` action (added in Step 1.F) and rejects with
  `:cross_tenant_fk_mismatch` when `parent.tenant_id != changeset.tenant_id`.

  Step 1.F adds `:by_id_global` only to the parents referenced by
  cross-tenant validation hooks (Workspace, Session, Message, Solution,
  Memory.Block/Fact/Episode). For Audit, **add `:by_id_global` to every
  audited tenanted target kind** so the validation map is complete:

  | target_kind | Resource | `:by_id_global` lives in |
  |---|---|---|
  | `:workspace` | `Workspaces.Workspace` | Step 1.F (already added) |
  | `:session` | `Conversations.Session` | Step 1.F |
  | `:message` | `Conversations.Message` | Step 1.F |
  | `:solution` | `Solutions.Solution` | Step 1.F |
  | `:memory_block` | `Memory.Block` | Step 1.F |
  | `:memory_fact` | `Memory.Fact` | Step 1.F |
  | `:memory_episode` | `Memory.Episode` | Step 1.F |
  | `:memory_link` | `Memory.Link` | **add in Step 2** |
  | `:memory_consolidation_run` | `Memory.ConsolidationRun` | **add in Step 2** |
  | `:reputation` | `Solutions.Reputation` | **add in Step 2** |
  | `:cron_job` | `Cron.Job` | **add in Step 3** alongside the resource |

  Untenanted parents (`:user`, `:project`, `:forge_session`) and target
  kinds **not in this map** skip with a
  `:tenant_validation_skipped_for_untenanted_parent` telemetry event,
  matching the pattern at `lib/jido_claw/security/cross_tenant_fk.ex:106-124`.
  An audit producer using a `target_kind` outside the map (e.g.
  `:tool` for the SignalListener) writes successfully — the validation
  is best-effort by design, only firing where a meaningful comparison
  exists.

Step 2's migration adds `audit_events` with its own FK to tenants(id):
`ALTER TABLE audit_events ADD CONSTRAINT audit_events_tenant_id_fkey ...
NOT VALID; VALIDATE CONSTRAINT ...`.

Add `JidoClaw.Audit` to `:ash_domains` in `config/config.exs`.

### 2.B — Async writer + Task.Supervisor

`lib/jido_claw/audit/async_writer.ex`:

```elixir
defmodule JidoClaw.Audit.AsyncWriter do
  alias JidoClaw.Audit.Event
  require Logger

  @sup JidoClaw.Audit.TaskSupervisor

  def cast(attrs) do
    Task.Supervisor.start_child(@sup, fn ->
      try do
        do_record(attrs)
      rescue
        e -> Logger.warning("[Audit] async write failed: #{Exception.message(e)}")
      end
    end)
    :ok
  end

  def sync(attrs), do: do_record(attrs)

  # Strip tenant_id from the attrs map and pass it via tenant: opt
  # so the call matches the Step 1 pattern (no tenant_id in accept lists).
  defp do_record(%{tenant_id: tenant_id} = attrs) do
    attrs |> Map.delete(:tenant_id) |> Event.record!(tenant: tenant_id)
  end
end
```

Add `{Task.Supervisor, name: JidoClaw.Audit.TaskSupervisor}` to
`lib/jido_claw/application.ex` Core child group.

### 2.C — `:tool_call` producer via SignalBus subscription

`JidoClaw.Tools.MCPScope.wrap/4` is *not* a comprehensive hook — it records
only when `Application.get_env(:jido_claw, :serve_mode) == :mcp` and 16 of
31+ tool modules wrap with it (`remember`, `recall`, `forget`,
`schedule_task`, `unschedule_task`, `spawn_agent`, `send_to_agent`, `reason`,
`run_pipeline`, `browse_web` etc. all bypass).

The right hook is the SignalBus path `Conversations.Recorder` already uses:

- `deps/jido_ai/lib/jido_ai/directive/tool_exec.ex:157` emits
  `ai.tool.started` and `ai.tool.result` for every Jido action runner
  invocation — universal.
- `lib/jido_claw/conversations/recorder.ex:40-47` subscribes to those signals.
  At lines 280-288 it converts `ai.tool.started` to a `:tool_call` Message
  row by resolving `request_id → RequestCorrelation → tenant/session/scope`.

`JidoClaw.Audit.SignalListener` mirrors Recorder's exact resolution pattern.
The signal data shape from `ai.tool.started` puts `request_id` in
`data.metadata`; Recorder uses `metadata_request_id/1` at
`recorder.ex:803` to extract it, falling back to `field(data, :request_id)`
per `:320, :352, :466, :496, :538, :623`. Scope lookup follows Recorder's
two-tier path at `recorder.ex:716-724`: `Cache.lookup/1` first, then
`RequestCorrelation.lookup/1` (Postgres) on cache miss.

`RequestCorrelation` carries `request_id, session_id, tenant_id,
workspace_id, user_id, run_id, model, latency_ms` — verified at
`lib/jido_claw/conversations/resources/request_correlation.ex:132-200`.
**It does not carry `agent_id`.** The audit's `actor_id` for a tool call
falls back to the signal's metadata (Jido emits `agent_id` on most action
runner signals, but it isn't guaranteed); when neither source provides it,
emit `actor_id: nil` rather than block on the missing field. Adding an
`agent_id` column to `RequestCorrelation` is a v0.7+ enhancement.

```elixir
def handle_signal(%{type: "ai.tool.started", data: data}) do
  request_id = metadata_request_id(data) || field(data, :request_id)

  with true <- is_binary(request_id),
       {:ok, scope} <- resolve_scope(request_id) do
    AsyncWriter.cast(%{
      tenant_id: scope.tenant_id,
      event_kind: :tool_call,
      actor_kind: :agent,
      actor_id: field(data, :agent_id) || metadata_field(data, :agent_id),
      target_kind: :tool,
      target_id: field(data, :tool_name),
      payload: %{
        request_id: request_id,
        session_id: scope.session_id,
        arguments: ToolTranscript.envelope(field(data, :arguments))
      }
    })
  else
    _ ->
      :telemetry.execute(
        [:jido_claw, :audit, :tool_call, :skipped],
        %{},
        %{reason: :no_request_id_or_correlation}
      )
  end
end

defp resolve_scope(request_id) do
  case Cache.lookup(request_id) do
    {:ok, scope} ->
      {:ok, scope}

    :error ->
      with {:ok, row} <- RequestCorrelation.lookup(request_id) do
        scope = %{
          session_id: row.session_id,
          tenant_id: row.tenant_id,
          workspace_id: row.workspace_id,
          user_id: row.user_id
        }
        Cache.put(request_id, scope)
        {:ok, scope}
      end
  end
end
```

The Postgres-fallback path normalizes to the same map shape Cache emits
(matches Recorder's behavior at `recorder.ex:716-732`) and writes back
to the cache so subsequent signals for the same request hit warm. Both
paths return identical shapes so callers can use uniform dot access.

Reuse Recorder's `metadata_request_id/1` and `field/2` helpers — extract
them into a shared module (`JidoClaw.Conversations.SignalShape` or
similar) so both subscribers stay in sync if the signal envelope shape
ever changes upstream.

Tools without a `request_id` in their signal payload are explicitly
skipped with telemetry — the alternative (scanning the process tree for a
tenant) is brittle. The skip is observable so a future "every tool always
carries request_id" guarantee can be measured.

Add `JidoClaw.Audit.SignalListener` to the Core child group in
`lib/jido_claw/application.ex`.

### 2.D — Other producer wire-ups

Verified action names (from `lib/jido_claw/memory/resources/*.ex`):

| Resource | Actions present |
|---|---|
| `Memory.Fact` | `:record`, `:import_legacy`, `:promote`, `:invalidate_by_id`, `:invalidate_by_label`, `:transition_embedding_status` |
| `Memory.Block` | `:write`, `:invalidate` (revisions are written as a side-effect of `:write`/`:invalidate` via `BlockRevision.create_for_block`) |
| `Memory.Episode` | `:record` |
| `Memory.Link` | `:create_link` |
| `Memory.FactEpisode` | `:create_for_pair` |
| `Memory.BlockRevision` | `:create_for_block` |
| `Memory.ConsolidationRun` | `:record_run` |

User-save vs model-write distinction is via the `source` enum on `Fact`
(values include `:user_save`), not a separate action.

**Sync (in caller's transaction) — `AsyncWriter.sync/1`:**

| Event kind | Producer action | Notes |
|---|---|---|
| `:memory_write` | `Memory.Fact.:record`, `:promote`, `:invalidate_by_id`, `:invalidate_by_label`, `Memory.Block.:write`, `:invalidate`, `Memory.Episode.:record`, `Memory.Link.:create_link` | `change after_action(...)`. `payload` carries the `source` so `:user_save` is distinguishable from model-driven writes. |
| `:memory_consolidation` | `Memory.ConsolidationRun.:record_run` (terminal status) | `change after_action(...)` |
| `:solution_share` | `Solutions.Solution.:store` when result `sharing in [:shared, :public]` | conditional `change after_action(...)` |
| `:session_start` | `Conversations.Session.:start` after_action (tx-bound) | **Race-safe + tx-bound + exactly-once**. Change `Session.:start` from `upsert?: true` to **insert-only**, relying on the existing `unique_external` identity (`(tenant_id, workspace_id, kind, external_id)`) to enforce uniqueness at the DB. The action's `change after_action(...)` emits audit **only** when the insert actually succeeds, inside the create transaction. `Conversations.Resolver.ensure_session/4` wraps with this exact call sequence (note Step 1 already moved `tenant_id` from `by_external`'s positional args to the `tenant:` opt): <br><br>```elixir<br>case Session.start(attrs_minus_tenant, tenant: tenant_id) do<br>  {:ok, session} -> {:ok, session}<br>  {:error, %Ash.Error.Invalid{errors: errors}} = err -><br>    if Enum.any?(errors, &unique_external_violation?/1) do<br>      with {:ok, existing} <-<br>             Session.by_external(workspace_id, kind, external_id, tenant: tenant_id),<br>           {:ok, touched} <- Session.touch(existing, tenant: tenant_id) do<br>        {:ok, touched}<br>      end<br>    else<br>      err   # genuine validation failure — surface it<br>    end<br>end<br>```<br><br>`unique_external_violation?/1` pattern-matches the specific Ash error shape (likely `%Ash.Error.Changes.InvalidChanges{}` carrying the identity name `:unique_external` or a Postgres `unique_violation` exception code `"23505"` with the constraint name `conversation_sessions_unique_external_index`). Verify the exact shape in implementation via `mix usage_rules.docs Ash.Error` and a one-off failing test. **Don't catch any `Ash.Error.Invalid`** — that swallows real validation failures (e.g. a Workspace cross-tenant FK mismatch raised by the existing hook). |
| `:session_end` | `Conversations.Session.:close` | `change after_action(...)` — `:close` only runs on natural session end and is not upserted |

**Async — `AsyncWriter.cast/1`:**

| Event kind | Producer | Wire point |
|---|---|---|
| `:tool_call` | `JidoClaw.Audit.SignalListener` | subscribes to `ai.tool.started` (see 2.C) |
| `:auth_event` | `lib/jido_claw/web/controllers/auth_controller.ex` | both branches of `sign_in/2` (lines 13-15 success, 17-20 failure) and `sign_out/2` (lines 24-28). **Read `conn.assigns[:current_user]` BEFORE `clear_session/1`** in `sign_out/2` — otherwise `actor_id` is nil. |

Known gap (documented, not fixed in this phase): API-key auth at
`lib/jido_claw/web/plugs/api_key_auth.ex:13-19` (success) and `:46`
(failure) is not covered. Magic-link, password-reset, and register actions
on `lib/jido_claw/accounts/user.ex` are configured but have no HTTP routes
mounted today; if/when they get mounted, audit needs extending.

### 2.E — Tests

- `test/jido_claw/audit/event_test.exs` — append-only enforcement (assert
  no `:update` or `:destroy` action exists), cross-tenant FK validation
  against constructed mismatches for each tenanted target_kind.
- `test/jido_claw/audit/cross_tenant_isolation_test.exs` (§4.5 isolation
  regression).
- `test/jido_claw/audit/cross_tenant_fk_test.exs` (§4.5 FK validation).
- `test/jido_claw/audit/integration_test.exs` (§4.5 "captures during real
  session"): drive each producer via its real public path; assert the
  matching audit row.
- `test/jido_claw/audit/signal_listener_test.exs` — drive a fake
  `ai.tool.started` signal carrying a `request_id` for which a
  `RequestCorrelation` row exists; assert a `:tool_call` audit row.
  Then drive a signal with no `request_id`; assert a skipped telemetry
  event and no audit row.
- `test/jido_claw/audit/session_start_idempotency_test.exs` — call
  `Resolver.ensure_session/4` twice with the same `(tenant, workspace,
  kind, external_id)`; assert exactly one `:session_start` audit row.

---

## Step 3 — `JidoClaw.Cron` domain + `Cron.Job` Ash resource

### 3.A — Resource

```
lib/jido_claw/cron/
  domain.ex                 # JidoClaw.Cron
  resources/
    job.ex                  # JidoClaw.Cron.Job
```

Attributes:
- `id uuid` PK.
- `tenant_id text` (FK to `tenants(id)` — Step 3's create-table migration
  adds the constraint inline, no dependency on Step 1's `@tenanted_tables`
  list).
- `job_id text` — user-supplied or generated id (matches today's
  `schedule_task` `generate_id/1`). Composite identity `(tenant_id, job_id)`.
- `task text, allow_nil? true` — null when `mode: :system_job`.
- `mode atom (:main | :isolated | :system_job)`.
- `schedule_kind atom (:cron | :every | :at)`.
- `schedule_value text` — cron expression for `:cron`, stringified ms for
  `:every`, ISO8601 for `:at`.
- `mfa_module text, mfa_function text, mfa_args map` — populated only for
  `:system_job`.
- `disabled_at utc_datetime_usec, allow_nil? true` — soft-disable.
- `metadata map`.
- `timestamps()`.

Actions: `create :upsert` (with
`upsert? true, upsert_identity: :unique_job`), `update :disable` (sets
`disabled_at = now()`), `update :enable` (clears `disabled_at`),
`destroy :remove`, `read :for_tenant` (filter `is_nil(disabled_at)`),
`read :by_id` with `args: [:id], get?: true`,
`read :by_job_id` with `args: [:job_id], get?: true`.

`multitenancy :attribute, attribute: :tenant_id, global? false`.

`code_interface`:
```elixir
code_interface do
  define(:upsert, action: :upsert)
  define(:by_id, action: :by_id, args: [:id], get?: true)
  define(:by_job_id, action: :by_job_id, args: [:job_id], get?: true)
  define(:remove, action: :remove)
  define(:disable, action: :disable)
  define(:enable, action: :enable)
  define(:for_tenant, action: :for_tenant)
end
```

Caller pattern for fetch-then-mutate (codebase convention; no `get_by:`
shorthand exists here):

```elixir
{:ok, job} = Cron.Job.by_job_id(job_id, tenant: tenant_id)
:ok = Cron.Job.remove(job, tenant: tenant_id)
```

Add `JidoClaw.Cron` to `:ash_domains` in `config/config.exs`.

### 3.B — Mix migrator

`lib/mix/tasks/jidoclaw.migrate.cron.ex`, modeled on
`lib/mix/tasks/jidoclaw.migrate.solutions.ex`:

```
mix jidoclaw.migrate.cron [--dry-run] [--project DIR] [--tenant TENANT]
```

- Defaults `DIR` to `File.cwd!()`, `TENANT` to `"default"`.
- Reads `DIR/.jido/cron.yaml` via an inline YAML reader
  (`YamlElixir.read_from_file/1`, ~8 lines copied from
  `Cron.Persistence.load/1`) — does **not** call `Cron.Persistence.load/1`,
  since that module is deleted in 3.E.
- For each job, `Cron.Job.upsert(attrs, tenant: tenant)`.
- Idempotent — `(tenant_id, job_id)` identity makes re-running safe.
- Leaves `cron.yaml` on disk as a backup per §4.4.

### 3.C — Scheduler refactor + persistent disabled state

`lib/jido_claw/platform/cron/scheduler.ex` changes:
- `load_persistent_jobs(tenant_id, _project_dir)` reads from Postgres via
  `Cron.Job.for_tenant(tenant: tenant_id)`. The action's filter excludes
  `disabled_at IS NOT NULL`, so a restart **does not** re-enable jobs
  auto-disabled on prior runs.
- `start_system_jobs/0` (line 138-165) keeps its current shape — system
  jobs are config-driven and don't go through Postgres in v0.6.4.

`lib/jido_claw/platform/cron/worker.ex`:
- `handle_cast(:disable, state)` (line 72-75) — also call
  `Cron.Job.by_job_id(state.id, tenant: state.tenant_id) |>
  Cron.Job.disable(tenant: state.tenant_id)` so the persistent row matches.
- The auto-disable path at lines 158-162 (after 3 failures) — same
  persistence call.

Otherwise a job that auto-disables stays in-memory disabled but
persistently active; restart re-enables it.

### 3.D — All `Cron.Persistence` consumers (5 sites)

1. `lib/jido_claw/tools/schedule_task.ex:76` —
   `Cron.Persistence.add_job(project_dir, job_map)` →
   `Cron.Job.upsert(attrs, tenant: tenant_id)`.

2. `lib/jido_claw/tools/unschedule_task.ex:29` —
   `Cron.Persistence.remove_job(project_dir, id)` →
   `{:ok, job} = Cron.Job.by_job_id(id, tenant: tenant_id);
   Cron.Job.remove(job, tenant: tenant_id)`.

3. `lib/jido_claw/cli/commands.ex:612` (`/cron add` handler) —
   `Cron.Persistence.add_job/2` after `Cron.Scheduler.schedule/2` →
   `Cron.Job.upsert(...)`.

4. `lib/jido_claw/cli/commands.ex:648` (`/cron remove` handler) —
   `Cron.Persistence.remove_job(state.cwd, id)` after
   `Cron.Scheduler.unschedule/2` → `by_job_id` + `remove`.

5. `lib/jido_claw/platform/cron/scheduler.ex:10` (boot path) —
   `Persistence.load(project_dir)` → `Cron.Job.for_tenant(tenant: tid)`.

The other CLI handlers at `commands.ex:655` (`/cron trigger`),
`:664` (`/cron disable`), `:673` (`/cron list`) don't touch persistence
today. Update `:664` (`/cron disable`) to also call
`Cron.Job.disable/1` so its persistent flag matches the runtime cast.

### 3.E — Delete `Cron.Persistence`

After all 5 consumers are migrated, delete
`lib/jido_claw/platform/cron/persistence.ex` in the same step. The migrator
in 3.B inlines the YAML read so deleting the module doesn't break it.

`.jido/cron.yaml` stays on disk per §4.4. Step 4's residual sweep test bans
new writes to it.

### 3.F — Tests

- `test/jido_claw/cron/job_test.exs` — actions, identity uniqueness.
- `test/mix/tasks/jidoclaw.migrate.cron_test.exs` — fixture round-trip,
  idempotent re-run.
- `test/jido_claw/cron/persistent_disable_test.exs` — schedule a job that
  fails 3x; assert `disabled_at` is set on the row; restart the scheduler
  (`Scheduler.load_persistent_jobs`); assert the disabled row is not
  re-loaded into `Cron.Worker`.
- Round-trip integration: `Tools.ScheduleTask` → `Tools.ListScheduledTasks`
  → `Tools.UnscheduleTask`.
- CLI: `/cron add` followed by `/cron remove` writes/reads the row.

---

## Step 4 — `Reasoning.Outcome` string deprecation + residual file-store sweep

### 4.A — Stop populating string columns

- `lib/jido_claw/reasoning/telemetry.ex:192` (and the type spec at line 23):
  drop `workspace_id`/`agent_id` from the attrs passed to `Outcome.record/1`.
- `lib/jido_claw/tools/reason.ex:184,188`: pass only `workspace_uuid` and
  `session_uuid`.

### 4.B — Mark columns deprecated, keep them

- `@moduledoc` deprecation note in
  `lib/jido_claw/reasoning/resources/outcome.ex` flagging
  `workspace_id` (line 194) and `agent_id` (line 214).
- Drop both from any `accept` list (lines 82, 86).
- Indexes (`(workspace_id, started_at)` line 40,
  `(agent_id, started_at)` line 44) stay until v0.7.

### 4.C — Residual file-store sweep test

`test/jido_claw/v064_file_store_sweep_test.exs`:

```elixir
test "no live writers to deprecated .jido/ stores" do
  banned = ~r"\.jido/(memory\.json|solutions\.json|reputation\.json|sessions/|cron\.yaml)"

  for path <- Path.wildcard("lib/**/*.ex"),
      content = File.read!(path),
      Regex.match?(~r/File\.write!?\b/, content) do
    refute Regex.match?(banned, content),
      "#{path} contains a banned writer to a deprecated .jido path"
  end
end
```

The regex bans by listing paths positively, so `.jido/identity.json`
(kept on disk per §1.3) and `.jido/heartbeat.md` (intentional sidecar per
§4.4) aren't false-positives.

### 4.D — Tests

- The sweep test above.
- A test asserting no `Reasoning.Telemetry.with_outcome/4` row carries
  non-nil string `workspace_id` or `agent_id`.

---

## Step 5 — Ash policies + actor threading

### 5.A — Add policies to each tenanted resource

For all 14 + Audit.Event + Cron.Job (= 16 resources):

```elixir
use Ash.Resource,
  authorizers: [Ash.Policy.Authorizer]

policies do
  policy action_type([:read, :create, :update, :destroy]) do
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end
end
```

`Audit.Event` reads also enforce `actor_id` matching where applicable, so
operators can only see their own audit trail unless explicitly elevated.

### 5.B — Actor threading

Every Ash call site needs `actor: %{tenant_id: tenant_id}` (and
`user_id: ...` where applicable). Caller surface mirrors Step 1.E exactly.
Build the actor map in `lib/jido_claw/web/plugs/require_auth.ex` and
`lib/jido_claw/web/channels/user_socket.ex` from
`conn.assigns.current_user`.

### 5.C — Per-action policy bypasses

- `:by_id_global` actions (Step 1.F) get a top-level policy bypass on the
  resource so the cross-tenant FK validation isn't itself denied:

  ```elixir
  policies do
    bypass action(:by_id_global) do
      authorize_if always()
    end

    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end
  end
  ```

  (`bypass` takes a check argument like `action(:foo)` or
  `action_type(:read)` — `bypass do ... end` without a check is not
  valid syntax.)
- **`RequestCorrelation` lookup paths**: `Recorder.record_telemetry/lookup`
  at `recorder.ex:253,410,721`, `Session.Worker.durable_lookup/1` at
  `session/worker.ex:309`, `JidoClaw.chat/4` register at `jido_claw.ex:192`,
  and the sweeper at `request_correlation/sweeper.ex:55` all need policy
  bypass too (not just the sweeper) — the lookup callers don't have an
  actor in scope at the point of lookup. Either mark every
  `RequestCorrelation` action as `default_actor :system` (custom check
  module) or apply `authorize?: false` at each call site. The simpler
  choice: mark `RequestCorrelation` itself with a permissive policy
  (`authorize_if always()`) since it's already `global? true` and its
  audit value is the rows it points at, not its own access.
- Sweepers / migrators (`mix jidoclaw.migrate.*`): pass
  `authorize?: false` opt to bypass policies.

### 5.D — Tests

- `test/jido_claw/policy_authz_test.exs` — actor matching, missing-actor
  denial (fail-closed), sweeper bypass, RequestCorrelation permissive
  access still works.
- All earlier Step gates pass with `actor:` threaded.

---

## Cross-cutting risks

1. **Step 1 is the largest single change in v0.6.** The `tenant:` opt
   addition is mechanical. The cross-tenant FK hook rewrite (1.F) requires
   verifying each tenanted parent has a `:by_id_global` action and every
   hook calls it correctly. A miss makes the validation crash at write
   time — fails loud, but breaks runtime.
2. **`global? false` is strict.** Any caller that forgets `tenant:` errors
   instead of leaking. Good for safety, demanding for migration coverage.
3. **`RequestCorrelation` `global? true` is a permanent design choice.**
   `request_id` is globally-unique by construction; cross-tenant lookup is
   safe.
4. **AshPostgres index churn.** Enabling `:attribute` multitenancy can
   rewrite identities/custom indexes by adding `tenant_id` unless
   `all_tenants? true` is set. Review `mix ash_postgres.generate_migrations`
   output before committing each resource. The generally-correct fix is to
   leave indexes that already lead with `tenant_id` alone, and mark
   indexes that should remain global with `all_tenants? true`.
5. **Race-safe insert-vs-existing detection for session-start audit.**
   The current Phase 0 `:start` action upserts; Step 2 changes it to
   insert-only and relies on the `unique_external` DB index plus a
   resolver-level conflict-then-fallback to make the audit emit
   exactly-once across concurrent first-callers. The 2.E
   `session_start_idempotency_test` exercises both sequential and
   concurrent (`Task.async_stream`) calls and pins the "exactly one
   audit row per session" contract. If `Session.:start` ever switches
   back to upsert semantics for any reason, this contract breaks.
6. **Cron migrator + `Cron.Persistence` deletion is one-way.** Downgrading
   to a binary that doesn't know about `Cron.Job` loses scheduled jobs.
   No reverse export is built in Step 3.
7. **Deferring policies to Step 5** means Step 1's multitenancy is the only
   security boundary in v0.6.4. That's fine —
   `multitenancy :attribute, global? false` filters at SQL; missing
   `tenant:` errors. Policies are defense-in-depth.

---

## Critical files modified (summary)

**New:**
- `lib/jido_claw/tenants/{domain.ex, resources/tenant.ex}`
- `lib/jido_claw/audit/{domain.ex, resources/event.ex, async_writer.ex, signal_listener.ex}`
- `lib/jido_claw/cron/{domain.ex, resources/job.ex}`
- `lib/mix/tasks/jidoclaw.migrate.cron.ex`
- `priv/repo/migrations/<ts>_v064_tenants_promotion.exs`
- `priv/repo/migrations/<ts+1>_v064_audit_events.exs`
- `priv/repo/migrations/<ts+2>_v064_cron_jobs.exs`
- Test files under `test/jido_claw/{tenants,audit,cron}/`

**Modified (Step 1):**
- All 14 tenanted resource modules — add `multitenancy` block, drop
  `tenant_id` from accept lists + read arguments. RequestCorrelation
  exception per 1.G.
- `lib/jido_claw/security/cross_tenant_fk.ex` — switch parent reads to
  `:by_id_global`.
- `lib/jido_claw/conversations/resources/{session.ex, message.ex, request_correlation.ex}`
  — fix inline cross-tenant validation + denormalize hooks.
- `lib/jido_claw/solutions/resources/solution.ex` — cross-tenant validation
  hooks switch to `:by_id_global`; embedding-policy reads at `:478, :550`
  switch to **tenant-scoped** `Workspace.by_id(.., tenant: cs.tenant)`
  (per Step 1.F's "non-validation parent reads" rule).
- `lib/jido_claw/memory/resources/{block.ex, fact.ex, episode.ex, fact_episode.ex, link.ex, block_revision.ex, consolidation_run.ex}`
  — denormalize→validate hook conversions use `:by_id_global`;
  embedding-policy reads in `fact.ex:621` use **tenant-scoped** `:by_id`.
- `lib/jido_claw/memory/scope.ex:130-158` —
  `maybe_load_session_ancestors`/`maybe_load_workspace_ancestors` use
  **tenant-scoped** reads (`Session.by_id(.., tenant: scope.tenant_id)`,
  `Workspace.by_id(.., tenant: scope.tenant_id)`), not bypass — `Scope.resolve/1`
  already carries `tenant_id`.
- `lib/jido_claw/workspaces/resolver.ex` — add `Tenants.Tenant.ensure/1`
  call.
- `lib/jido_claw/platform/tenant/manager.ex` — sync ETS cache with
  Postgres source-of-truth.
- All resolver / recorder / mix-task callers — add `tenant:` opt.
- `config/config.exs` — append `JidoClaw.Tenants` to `:ash_domains`.

**Modified (Step 2):**
- `lib/jido_claw/web/controllers/auth_controller.ex` — add audit emits.
- Memory / Solutions / Conversations resource actions — add
  `change after_action(...)` for sync audit.
- `lib/jido_claw/conversations/resolver.ex` — wrap `Session.start/2`
  with try-then-fallback: catch the duplicate-key Ash error from the
  insert-only `:start` and fall back to `Session.by_external` +
  `Session.touch`. Return `{:ok, session}` unchanged — the audit emit
  lives in the `:start` action's after_action, fires only when the
  insert actually wins the race.
- `lib/jido_claw/conversations/resources/session.ex` — drop
  `upsert?: true` from `:start`; the `unique_external` identity
  enforces uniqueness at the DB. Add the audit emit as an
  `after_action`.
- **Tests/factories that call `Session.start` directly** (mostly under
  `test/jido_claw/conversations/`) need updates: `:start` is no longer
  idempotent, callers re-running fixtures must either reset the DB
  between calls or expect the `unique_external` conflict path. The
  `test/jido_claw/audit/session_start_idempotency_test.exs` from 2.E
  verifies the resolver-level idempotency contract; downstream tests
  use the resolver, not `:start` directly.
- `lib/jido_claw/application.ex` — add `Audit.TaskSupervisor` and
  `Audit.SignalListener` to Core child group.
- `config/config.exs` — append `JidoClaw.Audit`.

**Modified (Step 3):**
- `lib/jido_claw/tools/{schedule_task.ex, unschedule_task.ex}` — switch
  Persistence calls to `Cron.Job` actions.
- `lib/jido_claw/cli/commands.ex:612, 648, 664` — same.
- `lib/jido_claw/platform/cron/scheduler.ex:10` — read from `Cron.Job`.
- `lib/jido_claw/platform/cron/worker.ex:72-75, 158-162` — persist
  `disabled_at` when auto-disable triggers. **Wrap the persistence call
  in `try/rescue` with logging** so a transient DB error doesn't crash
  the worker — failure mode becomes "in-memory disabled this run, may
  re-enable on restart" rather than worker death. The next auto-disable
  attempt re-tries the persist; eventual consistency is acceptable for
  this state (the alternative — crashing the worker — is strictly worse).
- **Delete** `lib/jido_claw/platform/cron/persistence.ex`.
- `config/config.exs` — append `JidoClaw.Cron`.

**Modified (Step 4):**
- `lib/jido_claw/reasoning/telemetry.ex:23, 192`.
- `lib/jido_claw/tools/reason.ex:184, 188`.
- `lib/jido_claw/reasoning/resources/outcome.ex:82, 86` (drop fields from
  accept), moduledoc deprecation note.

**Modified (Step 5):**
- All 16 tenanted resources — add `authorizers:` and policies.
- All Ash call sites — add `actor:` opt alongside `tenant:`.
- `lib/jido_claw/web/plugs/require_auth.ex` /
  `lib/jido_claw/web/channels/user_socket.ex` — build actor map.

---

## Existing utilities to reuse

- `lib/jido_claw/security/cross_tenant_fk.ex` — shared validator. Step 1.F
  refactors its parent-fetch path; Step 2 reuses the same shape for
  `Audit.Event`.
- `lib/jido_claw/conversations/recorder.ex:40-47, 280-288` — SignalBus
  subscription + `request_id → RequestCorrelation → tenant/session`
  resolution. Step 2.C mirrors this for `Audit.SignalListener`.
- `lib/jido_claw/core/telemetry.ex:143-161` (`emit_tool_*`) — alternative
  hook surface for `:tool_call`. SignalBus is preferred (mirrors the
  Recorder pattern).
- `lib/jido_claw/platform/tenant/manager.ex` `ensure_tenant/2` — keep as
  ETS hot cache; sync with new `Tenants.Tenant.ensure/1`.
- `lib/mix/tasks/jidoclaw.migrate.solutions.ex` — template for
  `jidoclaw.migrate.cron`. Same `OptionParser` flags, same
  `Workspaces.Resolver.ensure_workspace/3` lookup pattern, same dry-run
  reporting.
- `code_interface` patterns — `lib/jido_claw/conversations/resources/session.ex:39-54`
  for `define(:by_id, args: [:id], get?: true)`. No resource uses
  `get_by:` shorthand; stay with the `args: [:id], get?: true` convention.

---

## Implementation guardrail — `rg` checklist for Step 1

Before Step 1 is considered done, every entry below must run clean. These
ripgrep queries surface common multitenancy mistakes the call-site sweep
in 1.E might have missed.

```bash
# 1. No tenanted code-interface call without `tenant:` opt
rg -n 'JidoClaw\.(Workspaces|Conversations|Solutions|Memory|Audit|Cron)\.\w+\.[a-z_]+\(' lib/ \
  | rg -v 'tenant:|by_id_global|RequestCorrelation|Tenants\.Tenant'

# 2. No remaining Ash.get against a tenanted resource without tenant: opt
rg -n 'Ash\.get\(\s*(JidoClaw\.(Workspaces|Conversations|Solutions|Memory)\.\w+|\w+Resource)' lib/ \
  | rg -v 'tenant:|by_id_global'

# 3. No remaining Message.* / Session.by_id / Fact.* without tenant:
rg -n '(Message|Session|Fact|Block|Episode|Link|Solution|Reputation)\.(append|by_id|record|write|invalidate|create_link|store|get|upsert)\(' lib/ \
  | rg -v 'tenant:|by_id_global|@spec|@doc'

# 4. No tenant_id positional first arg on the listed code-interface defines
rg -n 'tenant_id, [a-z_]+\)' lib/jido_claw/{memory,solutions,conversations,workspaces}/resources/*.ex

# 5. accept lists still containing :tenant_id (RequestCorrelation excepted).
#    The piped `rg | rg accept` approach is unreliable because the first
#    rg only emits :tenant_id lines and the second can't see the
#    preceding `accept([` on a different line. Manual review is the
#    primary path:
rg -n ':tenant_id' lib/jido_claw/{memory,solutions,conversations,workspaces,audit,cron}/resources/*.ex
# For each hit verify the surrounding context:
#   - `attribute :tenant_id, :string` declaration → keep.
#   - inside an `accept([... :tenant_id ...])` list → remove (except
#     RequestCorrelation).
#   - filter clause `tenant_id == ^arg(:tenant_id)` → remove (Ash
#     injects under :attribute multitenancy).
#   - index column → keep.
```

The point isn't that these queries return zero hits — many will surface
expected matches in tests, comments, or moduledocs. The point is that
each hit is reviewed against the Step 1 sweep and either:
- Already migrated and the regex is over-eager (mark in the implementation
  notes as "expected match — reviewed").
- Genuinely missed, in which case fix it.

The acceptance gate at Step 1's end re-runs each command and the diff
versus the implementation notes is zero.

---

## Verification

End-to-end gates per step:

**Step 1**:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix ash.codegen --check`
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors and produces no surprise `tenant_id`
  additions to existing indexes (review the generated diff)
- `mix test` full suite green
- `test/jido_claw/v064_cross_tenant_test.exs` — isolation across all 14
  tenanted reads + the two raw-SQL hybrid-search paths
- `test/jido_claw/tenants/migration_test.exs` — fixture pre-migration
  state; assert FK validity post-migration
- `test/jido_claw/tenants/tenant_test.exs` — concurrent `ensure/1` race
- Manual smoke: `mix ecto.reset && mix jidoclaw` REPL, register a
  workspace, send a chat, verify `tenants` row + workspace FK valid

**Step 2**:
- All Step 1 gates plus:
- `test/jido_claw/audit/integration_test.exs` — drives each event_kind
  through its real producer
- `test/jido_claw/audit/session_start_idempotency_test.exs` — pins the
  insert-vs-upsert guard
- `test/jido_claw/audit/signal_listener_test.exs` — `request_id` present
  vs absent paths
- Manual smoke: in REPL mode, run `read_file` and `remember`; assert audit
  rows for both via `Audit.Event.read(tenant: "default")`

**Step 3**:
- `test/mix/tasks/jidoclaw.migrate.cron_test.exs` round-trip
- `test/jido_claw/cron/persistent_disable_test.exs` — restart doesn't
  re-enable failed jobs
- Manual smoke: `mix jidoclaw.migrate.cron --dry-run --project /tmp/fixture`;
  rerun without `--dry-run`; verify `cron_jobs` rows
- REPL: `/cron add "every 1m" "test"`; restart; verify the job survives

**Step 4**:
- `test/jido_claw/v064_file_store_sweep_test.exs`
- `Reasoning.Telemetry` writes Outcome with `workspace_uuid` set,
  `workspace_id` nil

**Step 5**:
- `test/jido_claw/policy_authz_test.exs` — actor matching, missing-actor
  denial, RequestCorrelation permissive access still works, sweeper bypass
- All earlier gates still pass with `actor:` threaded
