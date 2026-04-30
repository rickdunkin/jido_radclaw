# Phase 0 — Foundation: Workspace and Session resources

**Goal:** stop carrying tech debt around string IDs in places where we
clearly want FKs. Establish `Workspace` and chat `Session` as real Ash
resources before any data starts pointing at them.

## 0.1 New domain: `JidoClaw.Workspaces`

```
lib/jido_claw/workspaces/
  domain.ex                 # JidoClaw.Workspaces — Ash.Domain
  resources/
    workspace.ex            # JidoClaw.Workspaces.Workspace
```

Following the Forge.Domain / Reasoning.Domain folder convention (the
one used when a domain has more than one or two resources).

## 0.2 `Workspaces.Workspace` resource

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `name` | text | display name (defaults to last segment of `path`) |
| `path` | text | absolute project directory; uniqueness by `(user_id, path)` |
| `user_id` | uuid (FK Accounts.User, nullable) | owner; nullable so CLI-only flows still work |
| `project_id` | uuid (FK Projects.Project, nullable) | optional GitHub-linked project |
| `tenant_id` | text | mirrors current Tenant.Manager string until Phase 4; required (defaults to the resolver's caller-tenant). See "Tenant column from Phase 0" below. |
| `embedding_policy` | atom (`:default`, `:local_only`, `:disabled`), default `:disabled` | per-workspace opt-in for sending content to embedding providers. Ships in Phase 0 even though the consuming code lands in Phase 1 §1.4 — putting the column on the foundation row means Phase 1's migration can never accidentally enqueue Voyage calls before the user has agreed to data egress (see "Why default `:disabled`" below). |
| `consolidation_policy` | atom (`:default`, `:local_only`, `:disabled`), default `:disabled` | per-workspace opt-in for sending **transcripts and facts** to the §3.15 consolidator's frontier-model harness (Claude Code → Anthropic, Codex → OpenAI). Distinct from `embedding_policy`: a workspace may legitimately accept Voyage embeddings (small redacted chunks) but refuse the consolidator (whole-cluster transcript content + memory facts to a frontier model). Ships in Phase 0 alongside `embedding_policy` for the same conservative-default reason — Phase 3's consolidator scheduler reads it before invoking any harness, so a workspace that hasn't opted in stays untouched even if the consolidator is otherwise enabled. See "Why default `:disabled`" below. |
| `metadata` | map | future-proofing |
| `inserted_at`, `updated_at` | utc_datetime_usec | standard `timestamps()` |
| `archived_at` | utc_datetime_usec, nullable | soft-archive |

**Why `embedding_policy` defaults to `:disabled` and ships in
Phase 0.** v0.5 does not send memory or solution contents to any
third-party API (verified: no `Voyage`/embedding/HTTP calls in
`lib/jido_claw/platform/memory.ex` or `lib/jido_claw/solutions/`).
v0.6.1 introduces that capability via Voyage. Defaulting the
column to `:default` would silently route every existing
workspace's content through Voyage on first migration, which is
data egress the user never agreed to. Defaulting to `:disabled`
inverts the consent: Voyage is opt-in per workspace, retrieval
falls back to FTS-only until enabled, and the §1.4 redaction gate
+ §1.6 migration script never enqueue an embedding job for a
workspace that hasn't been explicitly switched. The policy column
itself has to land in Phase 0 (not Phase 1 §1.4) so the §1.6
migration runner can read it on the workspace row that already
exists by the time Phase 1's data move happens — adding the column
in Phase 1 alongside the migration would force a "default-on at
migration time" race that the conservative default exists to
avoid.

The three `embedding_policy` values:

- `:disabled` — `embedding_status` stays `:disabled` permanently
  for rows in this workspace; the backfill worker never picks them
  up; retrieval falls back to FTS + lexical without an ANN pool.
  Default for both new and migrated workspaces.
- `:local_only` — embeddings are computed via a local Ollama model
  (`Embeddings.Local`); Voyage is never called. Slower, lower
  quality, no third-party exposure.
- `:default` — content is redacted (§1.4) then sent to Voyage.
  Highest retrieval quality; users opt in by setting the policy.

**Why `consolidation_policy` defaults to `:disabled` and is
separate from `embedding_policy`.** The consolidator (§3.15)
sends a much larger and far less redacted blob to an external
model than the embedder does: full-cluster transcript content +
existing Memory.Block + Memory.Fact rows handed to a
frontier-model coding harness (Claude Code → Anthropic API, or
Codex → OpenAI API). Even with the §1.4 redaction gate applied,
this is a fundamentally different egress class than 1024-d
embedding vectors of pre-redacted snippets. A user reasonably
deciding "Voyage embeddings are fine, my whole transcript going
to Claude is not" needs a separate switch — collapsing both into
one `external_processing_policy` column hides that choice. The
two values mirror `embedding_policy` for surface symmetry but
the runtime behavior differs:

- `:disabled` — consolidator skips this workspace entirely. The
  scheduler iterates known scopes per tick; for every scope whose
  resolved workspace has `consolidation_policy: :disabled`, it
  writes a `ConsolidationRun` with `status: :skipped, error:
  :consolidation_disabled` (or no row, behind a config flag, to
  avoid log spam on quiet scopes) and never invokes the harness.
  Default for both new and migrated workspaces.
- `:local_only` — reserved for a future local-LLM consolidator
  runner (e.g. Ollama-hosted instruct model). No Phase 3 code
  path exists for this value yet; the column accepts it now so
  the v0.7+ runner doesn't need a column-shape migration. Until
  the local runner ships, `:local_only` behaves as `:disabled`
  with `error: :consolidation_local_runner_unavailable` so a
  user who set this expecting it to work gets an explicit signal
  rather than a silent skip.
- `:default` — consolidator processes this workspace's scopes
  using the configured `harness` (`:claude_code` or `:codex`).
  Highest memory quality; users opt in by setting the policy.

For `:user`-scoped memory (§3.2), the policy is resolved from the
**most-restrictive** of all workspaces under that user — a single
`:disabled` workspace blocks user-scope consolidation. This is
deliberately conservative: a user who marked any one of their
workspaces as opted out shouldn't have their cross-workspace user
memory consolidated against the harness either. §3.15 step 0
implements this by joining through workspaces; tests in §3.19
pin the behavior.

Identities: `unique_user_path` on `[tenant_id, user_id, path]`
enforced as two partial unique indexes — one with
`WHERE user_id IS NOT NULL` for authenticated users, one with
`WHERE user_id IS NULL` over `[tenant_id, path]` alone for
CLI-only flows. A single index on `[tenant_id, user_id, path]`
would **not** prevent duplicates because Postgres treats
`NULL ≠ NULL` in unique constraints, so multiple CLI workspaces
at the same path would coexist silently. The leading `tenant_id`
column closes the cross-tenant collision documented in §0.5.2 —
without it, two unauthenticated tenants resolving the same
absolute project path would collapse into a single Workspace
row, undercutting the multitenant boundary every Phase 1+
resource is indexed against. Both partial identities need a
corresponding `postgres.identity_wheres_to_sql` entry — see the
"partial identities" cross-cutting note in §Cross-cutting
concerns for why.

Actions: `create :register`, `update :rename`, `update :archive`,
`update :set_embedding_policy` (atom one-of input — the dedicated
action exists so the CLI in Phase 1 §1.4 has a single privileged
write surface for the policy column rather than threading it
through the general-purpose `:register`/`:update` actions, which
would also accept it on every workspace touchpoint),
`update :set_consolidation_policy` (same shape, atom one-of —
separate action for the same isolation reason; the §3.15
consolidator scheduler is the consumer),
`read :by_path` (filter on `path`), `read :for_user`. `:register`
accepts `embedding_policy` and `consolidation_policy` as optional
inputs so authenticated surfaces (CLI setup wizard, web
onboarding) can pre-set both at workspace creation; the default
of `:disabled` stands for either when the input is omitted.

`code_interface` block on the resource (matches JidoClaw convention,
not the upstream "domain code interface" recommendation).

## 0.3 New domain: `JidoClaw.Conversations`

```
lib/jido_claw/conversations/
  domain.ex                 # JidoClaw.Conversations
  resources/
    session.ex              # JidoClaw.Conversations.Session
    # message.ex follows in Phase 2
```

Naming note: we accept the namespace clash with `Forge.Resources.Session`.
Code reads `Conversations.Session` versus `Forge.Resources.Session`;
ambiguity is contained.

## 0.4 `Conversations.Session` resource

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `workspace_id` | uuid (FK Workspaces.Workspace) | required for new sessions |
| `user_id` | uuid (FK Accounts.User, nullable) | populated for web/auth surfaces |
| `kind` | atom (one_of: `:repl`, `:discord`, `:telegram`, `:web_rpc`, `:cron`, `:api`, `:mcp`, `:imported_legacy`) | surface — must match an actual platform/channel/controller surface; new surfaces add to this enum **and** must pass an explicit `kind` through `JidoClaw.chat/4` (see §0.5.1) so the resolver never has to guess from the session-id string. `:imported_legacy` is only set by the §2.5 JSONL migrator on filenames that don't match any known prefix — it never appears on live traffic and the §4.5 sweep flags any rows still carrying it for reclassification |
| `external_id` | text | e.g., `discord_<channel_id>`, `session_<timestamp>` |
| `tenant_id` | text | mirrors current Tenant.Manager string until Phase 4 |
| `started_at` | utc_datetime_usec | |
| `last_active_at` | utc_datetime_usec | bumped on each message |
| `closed_at` | utc_datetime_usec, nullable | natural session end (REPL exit) |
| `idle_timeout_seconds` | integer, default 300 | matches Worker hibernation |
| `next_sequence` | bigint, default `1` | atomic counter for the per-session message ordinal. Mutated only by `Conversations.Message`'s sequence-assignment `before_action` (see §2.1) via `UPDATE … SET next_sequence = next_sequence + 1 RETURNING`. Writers must not read this directly; the row-level write lock is the serialization guarantee. |
| `metadata` | map | model name, channel name, etc. |
| `inserted_at`, `updated_at` | utc_datetime_usec | |

Identities: `unique_external` on
`[tenant_id, workspace_id, kind, external_id]` so two tenants
don't collide on a shared `session_<timestamp>` or
`discord_<channel_id>`, **and** so two workspaces in the same
tenant don't collide on a shared external id. Tenant scoping is
required because today's `kind: :repl` external IDs are derived
from millisecond timestamps and `kind: :discord` IDs are channel
snowflakes that the same bot might serve across multiple tenants
in v0.6.4+. Workspace scoping is required because `kind: :cron`
in `:main` mode uses `agent_id` as its session id
(`platform/cron/worker.ex:116`) and the same agent id can serve
cron jobs across workspaces within one tenant; `kind: :web_rpc`
also accepts client-supplied session ids that aren't guaranteed
unique across workspaces. Without `workspace_id` in the identity
both surfaces would silently overwrite each other's session row.
Discord channel reuses still produce idempotent session lookup
within a `(tenant, workspace)` pair, which matches today's
single-workspace-per-channel reality.

Actions: `create :start`, `update :touch` (bumps `last_active_at`),
`update :close`, `read :active_for_workspace`, `read :by_external`.

`create :start` accepts `workspace_id`, `user_id`, `kind`,
`external_id`, `tenant_id`, `started_at`, `idle_timeout_seconds`,
and `metadata`. A `before_action` enforces the §0.5.2
cross-tenant FK invariant: it fetches the
`Workspaces.Workspace` row matching `workspace_id` inside the
action transaction and rejects the create with
`:cross_tenant_fk_mismatch` when `workspace.tenant_id !=
changeset.tenant_id`. Both `tenant_id` and `workspace_id` are
caller-supplied (typically from `tool_context.tenant_id` and the
resolved workspace id, respectively) and a buggy resolver could
produce a mismatch. The session row is then the source of truth
that downstream `Conversations.Message.:append` denormalizes its
own `tenant_id` from (§2.1), so a mistenanted session would
propagate the mismatch into every transcript message — the gate
is the only thing that stops that on the way in.

`closed_at` does **not** mean "consolidator should pick this up" — the
consolidator is scheduled by cadence, not by closure. `closed_at` is
informational and lets queries scope to "open vs closed."

## 0.5 String-ID coexistence strategy

Existing call sites pass `workspace_id` and `session_id` as strings
through `tool_context` and into `Reasoning.Outcome`. Phase 0 does **not**
break that — strings continue to flow through tool_context. What
changes:

1. A `WorkspaceResolver` in `lib/jido_claw/workspaces/resolver.ex`
   takes a `project_dir` (or string `workspace_id`) and returns a
   `Workspace` row, creating it on first sight.
2. A `SessionResolver` in `lib/jido_claw/conversations/resolver.ex`
   takes `(tenant_id, workspace_id, kind, external_id)` and returns
   a `Session` row, creating it on first sight. All four are
   required because the `unique_external` identity is
   `[tenant_id, workspace_id, kind, external_id]` (per §0.4) —
   without all four, `ensure_session/4` can't disambiguate
   sessions sharing an external id across tenants or workspaces
   and would either fail uniqueness or silently return the wrong
   row. The argument order changes: `workspace_id` was previously
   trailing as an "optional context"; under the new identity it
   moves into the second position to mirror the index column
   order.
3. Existing `Session.Worker.add_message/4` calls are routed through
   `SessionResolver.ensure_session/4` so every message in the new
   world has a real session row even if downstream still serializes
   the string id.
4. `Reasoning.Outcome.workspace_id` (string column) gets a sibling
   `workspace_uuid` (nullable FK) populated when the resolver finds a
   row. The string column stays for backward compatibility through
   v0.6; deprecation path tracked in Phase 4.

## 0.5.1 `tool_context` shape upgrade

Today's tool_context is **insufficient for downstream resolution**.
At `lib/jido_claw.ex:55-64`, `dispatch_to_agent/5` builds:

```elixir
tool_context: %{
  project_dir: project_dir,
  workspace_id: session_id,    # overloaded: actually the session id
  agent_id: session_id
}
```

That is, `workspace_id` is being populated with the session id, and
neither `tenant_id` nor a real `session_id` field flows through.
The Phase 2 Recorder and Phase 3 memory scope resolver both need
those values, so Phase 0 introduces the new shape:

```elixir
tool_context: %{
  project_dir: project_dir,
  tenant_id: tenant_id,             # NEW — was missing
  session_id: session_id,           # string for now (matches today's REPL/external id)
  session_uuid: session_row.id,     # NEW — FK target after SessionResolver runs
  workspace_id: workspace_id,       # UNCHANGED semantic — still the per-session
                                    # runtime key consumed by Shell/VFS/Profile.
                                    # See "Why workspace_id is not de-overloaded
                                    # in v0.6" below.
  workspace_uuid: workspace_row.id, # NEW — Ash FK; the field new code joins on
  agent_id: agent_id
}
```

**Why `workspace_id` is *not* de-overloaded in v0.6.** Earlier
drafts proposed renaming `workspace_id` to mean the resolved
workspace string (e.g., the cwd path) and routing the session id
to the new `session_id` slot. That looks tidy in `tool_context`
but breaks four runtime subsystems that today key on
`workspace_id` as a *per-session* identifier:

- `JidoClaw.Shell.SessionManager` keys
  `state.sessions = %{workspace_id => …}` plus the
  `:jido_claw_ssh_sessions_active` ETS table; drift detection at
  `session_manager.ex:611` tears a session down when its
  `project_dir` for a given `workspace_id` changes. Two REPL
  sessions resolved to the same workspace string would thrash
  each other into endless teardown.
- `JidoClaw.VFS.MountTable` and the
  `JidoClaw.VFS.WorkspaceRegistry` GenServer
  (`vfs/workspace.ex:47`, `vfs/resolver.ex:46`) look up mounts
  by `workspace_id`. Collapsing two sessions onto one entry
  shares the mount table across them, leaking state between
  concurrent shell tools.
- `JidoClaw.Shell.ProfileManager.@ets_active_env` keys per
  `workspace_id`; `/profile switch` in one session would
  silently change env in every co-resolved session.
- File tools (`read_file`, `write_file`, `edit_file`,
  `list_directory`) thread `workspace_id` into the Resolver and
  inherit the same sharing.

De-overloading cleanly requires every one of those subsystems
to switch to a separate runtime key (per-session) at the same
time. That is a coordinated refactor with its own test
surface, and v0.6 is already a large data-layer migration —
folding a runtime-keying rename into the same release
multiplies risk without buying anything the new
`workspace_uuid` field doesn't already provide. So:

- `workspace_id` keeps its current overload (= per-session
  runtime key) through v0.6.
- `workspace_uuid` is the new field for **DB-side** workspace
  resolution; every Phase 1+ Ash query/changeset reads
  `workspace_uuid`, never `workspace_id`.
- The de-overload itself is tracked in §Pre-existing cleanup
  debt for a separate runtime-keying refactor sprint.

Touch every dispatch site that calls `Agent.ask`/`Agent.ask_sync`.
Three categories, fixed in different places:

1. **Surface entry points that funnel through `JidoClaw.chat`**.
   `web/controllers/chat_controller.ex`,
   `web/channels/rpc_channel.ex`, `platform/channel/discord.ex`,
   `platform/channel/telegram.ex`, `platform/cron/worker.ex` all
   call `JidoClaw.chat(tenant_id, session_id, text)` today. The
   `tool_context` build in `lib/jido_claw.ex:55-64` (the body of
   `dispatch_to_agent/5`) is the single place to populate the new
   shape, but the function signature itself has to grow because
   `kind` and `external_id` are required for §0.4's
   `(tenant_id, workspace_id, kind, external_id)` identity and
   neither is available from `session_id` alone:

   - `web_rpc` accepts a client-supplied session id with no
     prefix convention (`rpc_channel.ex:59`); pattern-matching
     it against `^session_` / `^discord_` / `^telegram_` etc.
     would silently classify it as `:api`.
   - `cron` `:main` mode (`cron/worker.ex:116`) reuses the
     `agent_id` directly, so the session id has no surface
     prefix at all and the same prefix-parser would also fall
     through to `:api`.
   - Every other caller already knows its own surface at the
     point of dispatch; making it pass that knowledge through
     is cheaper and less brittle than inferring it.

   Phase 0 introduces:

   ```elixir
   @spec chat(String.t(), String.t(), String.t(), keyword()) ::
           {:ok, String.t()} | {:error, term()}
   def chat(tenant_id, session_id, message, opts \\ [])
   # opts:
   #   :kind          (required) — one of §0.4's enum atoms
   #   :external_id   (optional) — defaults to session_id; some
   #                  surfaces (cron :main) want to track agent_id
   #                  separately from external_id
   #   :workspace_id  (optional) — string passed to WorkspaceResolver;
   #                  defaults to project_dir from File.cwd!()
   #   :user_id       (optional) — populates Session.user_id for
   #                  authenticated surfaces (web/RPC)
   #   :metadata      (optional) — map merged into Session.metadata
   ```

   The 3-arity head is **kept as a thin shim** for the v0.6.0 →
   v0.6.1 transition only — it forwards to `chat/4` with
   `kind: :api` and emits a one-time deprecation warning per
   call site (using `Logger.warning/2` keyed on a process-dict
   sentinel so it doesn't spam). The acceptance gate at §0.7
   asserts every in-tree caller passes through `chat/4` with an
   explicit `:kind`. Each surface passes its own kind:

   | File | `:kind` | `:external_id` source |
   |---|---|---|
   | `cli/repl.ex` (when it routes through `chat`) | `:repl` | `"session_<ts>"` (existing shape) |
   | `web/controllers/chat_controller.ex` | `:api` | `"api_<int>"` / `"api_stream_<int>"` (existing shape) |
   | `web/channels/rpc_channel.ex` | `:web_rpc` | client-supplied `session_id` |
   | `platform/channel/discord.ex` | `:discord` | `"discord_<channel_id>"` |
   | `platform/channel/telegram.ex` | `:telegram` | `"telegram_<chat_id>"` |
   | `platform/cron/worker.ex` (`:main`) | `:cron` | `state.agent_id` (also passed as `external_id` so two cron jobs sharing an agent_id within one workspace map to one session by design) |
   | `platform/cron/worker.ex` (`:isolated`) | `:cron` | `"cron_<job_id>_<ts>"` |
   | MCP server stdio dispatch | `:mcp` | per-connection identifier |

   `dispatch_to_agent/5` reads `kind` and `external_id` from the
   resolver-returned `Session` row (not from the opts directly)
   so they're sourced from a single authoritative place inside
   the function body.

2. **Direct `Agent.ask`/`ask_sync` callers that bypass `chat/3`**
   and build their own `tool_context` map. These have to be edited
   individually:
   - `lib/jido_claw/cli/repl.ex:242` — REPL calls `Agent.ask`
     directly with a tool_context constructed at the call site.
   - `lib/jido_claw/tools/spawn_agent.ex:59` — swarm child spawn;
     today calls `child_tool_context(project_dir, workspace_id,
     tag, forge_session_key)` which has no tenant/session/UUIDs.
   - `lib/jido_claw/tools/send_to_agent.ex:43` and `:52` — same
     `child_tool_context/4` helper as `SpawnAgent`; both branches
     need updating.
   - `lib/jido_claw/workflows/step_action.ex:38` — workflow step
     spawns a template agent with a hand-rolled tool_context of
     `%{project_dir, workspace_id, agent_id}`.

   For (2), the parent's `tool_context` already has the new fields
   after Phase 0 (so e.g. `SpawnAgent` reads them from
   `context.tool_context` and forwards into the child's
   tool_context). Helpers like `child_tool_context/4` get a new
   shape that propagates `tenant_id`, `session_id`, `session_uuid`,
   `workspace_uuid` from parent to child by default; the only field
   that differs is `agent_id`, which becomes the child's tag.

3. **Workflow drivers that re-enter `Agent.ask`/`ask_sync` via
   `StepAction`.** `lib/jido_claw/tools/run_skill.ex:48-49` reads
   only `project_dir` and `workspace_id` from the parent's
   `tool_context` and forwards them through to whichever workflow
   it dispatches to. The three workflow drivers —
   `SkillWorkflow.run/4`, `PlanWorkflow.run/4`, and
   `IterativeWorkflow.run/4` — accept those two via positional
   args + a `:workspace_id` opt and call `StepAction.run(params,
   %{})` with an **empty context map** (skill_workflow.ex:117,
   plan_workflow.ex:312, iterative_workflow.ex:211 + :235). Even
   after fixing (1) and (2), every skill-spawned child agent would
   still write Memory / Solutions / Audit rows without the
   parent's tenant or session in scope, because StepAction's
   per-call tool_context is built solely from `params`.

   Phase 0 changes the workflow API surface to thread the full
   scope context through:

   - `StepAction`'s schema gains `tenant_id`, `session_id`,
     `session_uuid`, and `workspace_uuid` as optional params; the
     `tool_context` it constructs at `step_action.ex:38` reads
     all six new fields plus `project_dir`/`workspace_id`/
     `agent_id`. Existing ad-hoc unit-test callers that pass
     neither `params` nor `context` keep working — the per-step
     fallback in `resolve_workspace_id/3` extends to a parallel
     `resolve_scope/3` that pulls each scope field from
     `params`, then `context`, then `context.tool_context`, then
     `nil`.
   - `SkillWorkflow.run/4`, `PlanWorkflow.run/4`, and
     `IterativeWorkflow.run/4` accept a new `:scope_context`
     keyword option (a map carrying `tenant_id`, `session_id`,
     `session_uuid`, `workspace_uuid`, plus `workspace_id` if not
     already passed positionally). Each workflow merges that map
     into the `params` it builds for `StepAction.run` and passes
     it again as the second argument so `resolve_scope/3` finds
     it in either place.
   - `RunSkill.run/2` reads the full scope context from
     `context.tool_context` (the post-Phase-0 shape) and threads
     it through `:scope_context` to whichever workflow it
     dispatches to. The Phase 0 `tool_context` upgrade is what
     makes that read non-empty in the first place — without (1)
     and (2) above, `RunSkill` has nothing to forward.

The `session_id` string field stays for backward compatibility
through v0.6 and is deprecated in Phase 4 (consumers migrate to
`session_uuid`). `workspace_id` is *not* deprecated in v0.6 — it
remains the per-session runtime key for Shell/VFS/Profile state
per the "Why `workspace_id` is not de-overloaded" note above; the
follow-up to actually rename it is captured in §Pre-existing
cleanup debt.

## 0.5.2 Tenant column from Phase 0 (cross-cutting)

Phase 4 promotes `JidoClaw.Tenant` to a real Ash resource and turns
tenant scoping into a first-class boundary. But every persisted table
that lands in Phases 0–3 needs a way to be tenant-scoped from day one
or Phase 4 has to backfill (and risk-misassign) every Workspace,
Solution, Session, Message, Block, Fact, Episode, ConsolidationRun,
and Link row already in production. Doing that retroactively means a
multi-table backfill plus a sweep of every read path to add the new
filter — high-risk, easy to miss.

Phase 0 adds a `tenant_id` text column to **every new persisted
resource** introduced in this plan, populated from the existing
`JidoClaw.Tenant.Manager` string at write time:

| Resource | Phase | Notes |
|---|---|---|
| `Workspaces.Workspace` | 0 | Required; resolver populates from caller's tenant. |
| `Conversations.Session` | 0 | Already in §0.4. |
| `Solutions.Solution` | 1 | Required; populated from `tool_context.tenant_id`. |
| `Solutions.Reputation` | 1 | Required; agent reputation is per-tenant from the start. |
| `Conversations.Message` | 2 | Denormalized from `session_id` to avoid a join on every read; enforced by a `before_action` that copies from the session row. |
| `Memory.Block` / `Fact` / `Episode` / `Link` / `FactEpisode` / `ConsolidationRun` | 3 | Required on every memory resource; the consolidator's scope chain (§3.2) gains an outer tenant filter. |
| `Audit.Event` | 4 | Required at creation. |

Each resource indexes `(tenant_id, ...)` as the leading column on the
primary read patterns so every query is tenant-scoped at the index
level — closing the cross-tenant leak that single-table Postgres
storage would otherwise open relative to today's per-`project_dir`
ETS isolation.

**Cross-tenant FK invariant: `tenant_id` must equal the FK
parent's `tenant_id`.** Every resource that carries `tenant_id`
*and* a typed FK whose target row also carries `tenant_id`
(`workspace_id`, `session_id`, `project_id`, `user_id`'s
workspace chain, `from_fact_id`, `to_fact_id`, `block_id`,
`fact_id`, `episode_id`) MUST validate equality between its
denormalized `tenant_id` and the parent row's `tenant_id`
inside the action transaction. Trusting `tool_context.tenant_id`
on its own is not enough: a buggy resolver, a confused-deputy
import path, a future direct API caller, or a migration script
that pieces context together from multiple inputs can produce a
row where `tenant_id = T1` while `workspace_id` points at a row
with `tenant_id = T2`. The §0.5.2 boundary leaks the moment any
read path joins through the FK without re-checking the
denormalized column, and the partial unique indexes (which
include `tenant_id`) silently fail to dedupe across the
mismatched pair.

Two implementation shapes are acceptable; pick per-action based
on whether the tenant value is supplied or derived:

1. **Copy-from-parent.** When the action accepts the FK but
   *not* `tenant_id`, the `before_action` hook fetches the
   parent row inside the transaction and **assigns**
   `tenant_id = parent.tenant_id`. This is the live-traffic
   default for `Conversations.Message.:append`,
   `Memory.BlockRevision.create`, etc. The action's `accept`
   list does not include `tenant_id`, so the caller cannot
   spoof it.
2. **Validate-equality.** When the action accepts both — the
   privileged-import surfaces `:import` /
   `:import_legacy` / live `:store` actions that get
   `tool_context.tenant_id` from a resolver and the FKs from
   user/migrator input — the `before_action` hook fetches the
   parent row inside the transaction and **rejects the create**
   when `parent.tenant_id != changeset.tenant_id`. The error
   surfaces as `:cross_tenant_fk_mismatch` with both the
   supplied and parent tenant values in the action error so
   misconfigured callers fail loudly rather than silently
   landing in the wrong tenant.

Both shapes run inside the create/update transaction so the
parent fetch sees a consistent snapshot — the parent's
`tenant_id` cannot change between fetch and insert. The check
adds one indexed lookup per write, which is cheap and pays for
itself the first time it catches a misconfigured caller. Tests
in each phase's acceptance gates pin the validation against a
constructed-mismatch fixture.

**Which parent resources are tenant-scoped.** The validation
hook is **conditional on whether the parent resource carries a
`tenant_id` column at all**. Not every FK in the v0.6 schema
points at a tenanted parent:

| Parent resource | Tenanted? | Notes |
|---|---|---|
| `Workspaces.Workspace` | ✅ Yes | Introduced by this plan; tenant_id required. |
| `Conversations.Session` | ✅ Yes | Introduced by this plan; tenant_id required. |
| `Memory.Block` / `.Fact` / `.Episode` / `.ConsolidationRun` | ✅ Yes | Carry full §3.2 scope cols. |
| `Solutions.Solution` / `.Reputation` | ✅ Yes | Per §1.2, §1.3. |
| `Audit.Event` | ✅ Yes | Per §4.1 (this plan). |
| `Accounts.User` | ❌ No | **Intentionally untenanted.** A user can authenticate into multiple tenants over their lifetime; binding a user to one tenant breaks the multitenancy model in surfaces that today carry `user_id` directly (`Workspace.user_id`, `Session.user_id`, `RequestCorrelation.user_id`). The validation hook **skips** `user_id` FKs entirely. |
| `Projects.Project` | ❌ No (pre-existing) | Pre-existing resource at `lib/jido_claw/projects/project.ex` with no `tenant_id`. Memory and Conversations rows scoped to `:project` populate `project_id` but the validation hook cannot compare against a column that doesn't exist; flagged in "Pre-existing cleanup debt" for a Phase-4-or-later sweep that adds tenant_id to Projects. |
| `Forge.Resources.Session` | ❌ No (pre-existing) | Same shape as Projects; flagged in "Pre-existing cleanup debt". |

The hook implementation iterates the populated FKs in
priority order (most-tenanted first: `Workspace`, `Session`,
sibling Memory/Solutions/Audit rows) and skips any FK whose
parent resource doesn't define `tenant_id`. **Skipping** is
not the same as **silently passing** — the hook emits a
`:tenant_validation_skipped_for_untenanted_parent` telemetry
event with the FK name so a future audit can see how often
each pre-existing parent is on the validation path. When the
"Pre-existing cleanup debt" sprint tenants Projects /
Forge.Session / etc., flipping each from "skipped" to
"validated" is a one-line change to the hook's parent table.

Both shapes run inside the create/update transaction so the
parent fetch sees a consistent snapshot — the parent's
`tenant_id` cannot change between fetch and insert.

The §3.7.1 (`FactEpisode`), §3.8 (`Link`), and §3.5
(`BlockRevision`) actions already document this hook. The other
write paths (`Solutions.Solution.:store`, `:import_legacy`;
`Memory.Fact.:record`, `:import_legacy`;
`Conversations.Message.:import`; `Conversations.Session.:start`;
`Memory.Block.:write`/`:revise`; `Memory.Episode.:record`;
`Memory.ConsolidationRun.:record_run`; `Audit.Event.:create`)
adopt the same pattern in their respective sections; without
it, the cross-tenant boundary is only as strong as the weakest
resolver and the weakest migrator.

The string column is the migration target for Phase 4: when
`JidoClaw.Tenants.Tenant` becomes an Ash resource, the column is
promoted to an FK in a single migration with a backfill matching the
existing string values, and `Ash.Policy` rules are added that filter
by `tenant_id` on every read action. No row needs a default tenant
synthesised retroactively because every row was tenant-stamped at
write time.

This design also lets `JidoClaw.Repo`'s `prepare_query/2` (or an
Ash policy in v0.6.4) inject a `WHERE tenant_id = ?` predicate on
*every* read by default — the kind of belt-and-suspenders defense
that catches a missing filter in a future query before it leaks rows.

## 0.6 Migrations

```
mix ash.codegen v060_create_workspaces_and_sessions
```

(The migration name is a positional argument to `ash.codegen`, not
a `--name` flag — `mix help ash.codegen` confirms.)

One migration adds both tables, indexes on
`(tenant_id, user_id, path)`, `(workspace_id, started_at)`,
`(tenant_id, workspace_id, kind, external_id)`, and
`(tenant_id, last_active_at)`. The
`(tenant_id, workspace_id, kind, external_id)` shape mirrors the
`unique_external` identity (§0.4) so external-id lookups stay
in-tenant *and* in-workspace; a tenant-less or workspace-less
`(kind, external_id)` index would be a foot-gun for cross-tenant
`:discord` channel reuse and cross-workspace `:cron`/`:web_rpc`
session-id reuse once Phase 4 turns tenants into real
boundaries. No data backfill in Phase 0 — backfill of historical
sessions happens in Phase 2 when transcripts move.

## 0.7 Acceptance gates

- `mix test` green; new test files for `Workspaces.Workspace`,
  `Conversations.Session`, both resolvers, the `Outcome` sibling FK.
- New REPL/Discord/Web RPC sessions create rows; old code continues to
  function with strings.
- Every `Agent.ask`/`Agent.ask_sync` call site populates the new
  `tool_context` shape from 0.5.1 — `tenant_id`, `session_id`
  (string), `session_uuid`, `workspace_id` (kept as today's
  per-session runtime key per §0.5.1), `workspace_uuid`,
  `agent_id`. Coverage is grep-enforced: a CI check (or test
  using `Code.fetch_docs`/AST traversal under `lib/`) lists every
  `\.ask(\|\.ask_sync(` site and asserts each one threads the new
  shape — either by going through `JidoClaw.chat/4` (whose
  tool_context is verified in `lib/jido_claw.ex` test; the
  `chat/3` shim forwards to `chat/4` with `kind: :api` and
  emits a one-time deprecation warning per §0.5.1) or by
  building the map at the call site. The known direct callers as
  of v0.6.0 are: `lib/jido_claw.ex`, `lib/jido_claw/cli/repl.ex`,
  `lib/jido_claw/tools/spawn_agent.ex`,
  `lib/jido_claw/tools/send_to_agent.ex` (two branches), and
  `lib/jido_claw/workflows/step_action.ex`. New direct callers
  added later must satisfy the same check.
- **Skill-spawned child write regression test.** Run a one-step
  skill via `RunSkill` from a parent agent whose `tool_context`
  carries a non-default `tenant_id` / `session_uuid` /
  `workspace_uuid`. Have the step's template invoke a tool that
  writes a row carrying scope (after Phase 1 the simplest target
  is `Solutions.Solution.:store`; pre-Phase-1 a stub action that
  echoes `tool_context` back to the test is enough). Assert the
  written row's tenant/session/workspace match the parent — not
  defaults and not `nil`. Without the §0.5.1 category-(3) fix
  this test fails because `StepAction.run(params, %{})` drops
  the parent context. Cover all three workflow drivers
  (`:sequential`, `:dag`, `:iterative`) so a regression in any
  one of them surfaces.
- `JidoClaw.Workspaces` and `JidoClaw.Conversations` appended to
  `config :jido_claw, :ash_domains` (which today lists `Accounts`,
  `Projects`, `Security`, `Forge.Domain`, `Orchestration`, `GitHub`,
  `Folio`, `Reasoning.Domain`).
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors. Workspace's two partial
  identities (`unique_user_path_authed`, `unique_user_path_cli`)
  have entries — see the cross-cutting "partial identities" note.
- `mix ash.codegen --check` clean (no pending resource changes).
  Note: `mix ash_postgres.migrations` is **not** a real task in this
  project — `mix help` lists `ash_postgres.migrate`,
  `ash_postgres.generate_migrations`, and `ash_postgres.setup_vector`
  among others, but no `migrations` task.
- **Cross-tenant Workspace collision regression test.** Resolve
  the same absolute project path under two distinct unauthenticated
  tenants (`user_id IS NULL` for both); assert two distinct
  Workspace rows are created. Then resolve the same path again
  under each tenant; assert idempotent reuse of the matching row
  per tenant. Without the leading `tenant_id` column on the
  identity, this test would fail by collapsing both tenants into
  one row.
- **Cross-workspace Session collision regression test.** Create
  two Workspaces in the same tenant; call
  `SessionResolver.ensure_session/4` for each with the same
  `(kind: :cron, external_id: "shared-agent-id")`. Assert two
  distinct Session rows are created (one per workspace) and that
  re-calling each is idempotent. This proves the §0.4 identity's
  workspace_id column closes the cron/web_rpc collision class.
- **`embedding_policy` default test.** Register a Workspace via
  `Workspaces.register/1` without supplying `embedding_policy`;
  assert the row's stored value is `:disabled` (the §0.2
  default). Register a second Workspace passing
  `embedding_policy: :default`; assert it stores `:default`.
  Update the first via `set_embedding_policy/2` to `:local_only`;
  assert the column flips. This pins the conservative default
  the v0.6.1 §1.4 backfill worker relies on to keep legacy data
  off Voyage until users opt in.
- **`consolidation_policy` default test.** Same shape as the
  `embedding_policy` test: register a Workspace without supplying
  `consolidation_policy`; assert the stored value is `:disabled`.
  Register a second passing `consolidation_policy: :default`;
  assert it stores `:default`. Update the first via
  `set_consolidation_policy/2` to `:disabled`; assert the column
  flips. The two policy columns are independent — the test
  setting `embedding_policy: :default` on one workspace asserts
  its `consolidation_policy` is still `:disabled`, so a future
  refactor that accidentally collapses the columns surfaces
  here.

