# Plan: v0.6 Memory & Persistence Migration

Replace the file- and ETS-based persistence behind `JidoClaw.Memory`,
`JidoClaw.Solutions.Store`, and the chat-session JSONL writer with an
Ash + PostgreSQL data layer, add pgvector + Postgres FTS retrieval,
introduce a multi-tier memory model with a scheduled consolidator, and
collapse the existing string-keyed scope plumbing onto real Ash
relationships.

---

## Background

### Today's persistence

| Subsystem | Storage | Search | Scope |
|---|---|---|---|
| Memory | `Jido.Memory.Store.ETS` + `.jido/memory.json` | substring on text/key/kind | per-`project_dir`, no FK plumbing |
| Solutions | `:ets` table + `.jido/solutions.json` | exact-signature → fingerprint Jaccard → trust-weighted | per-`project_dir`, `agent_id` is a string |
| Reputation | `:ets` table + `.jido/reputation.json` | n/a | per-`agent_id` string |
| Chat transcripts | per-session JSONL at `.jido/sessions/<tenant>/<id>.jsonl` | none | per-`tenant_id` string + `session_id` filename |
| Session state | `JidoClaw.Session.Worker` GenServer (in-memory) | n/a | per `{tenant_id, session_id}` |

Five GenServer + ETS + file-snapshot stores, four different scope key
schemes, no FTS, no embeddings, and chat transcripts that capture only
`{role: user|assistant, content, timestamp}` — no tool calls, no tool
results, no reasoning steps.

### Target state

- One AshPostgres data layer for Memory, Solutions, Reputation, and
  Conversations (chat sessions + messages).
- pgvector embeddings + Postgres FTS, hybrid retrieval via Reciprocal
  Rank Fusion (RRF).
- Multi-scope memory: User / Workspace / Project / Session, with read-time
  precedence `session > project > workspace > user`.
- Bitemporal modeling on every memory record (`valid_at`,
  `invalid_at`, `inserted_at`, `expired_at`) — invalidate, never delete.
- Three memory tiers:
  - **Block** — small, char-bounded, pinned to the system prompt with
    frozen-snapshot semantics.
  - **Fact** — searchable tier (FTS + pgvector).
  - **Episode** — immutable provenance, links every derived memory back
    to the source turn / document / event.
- Three write sources, with different routing:
  - **Model** writes via `remember` tool → Fact tier (candidate).
  - **User** writes via `/memory save` → Fact tier (trusted).
  - **Consolidator** (scheduled) is the only writer to the Block tier;
    also promotes/invalidates Facts and discovers Links.
- Voyage-4 embeddings: `voyage-4-large` for write-time creation,
  `voyage-4` for retrieval (compatible vector space, cost-tuned).
- No JSON-file fallback. Postgres is required (already true for
  Ash resources).

### What this plan does *not* do

- Persistent agent state recovery (already in Forge resources).
- Workflow orchestration (already in `Orchestration` domain).
- Cluster coordination beyond what Postgres + `:pg` provide today.
- Burrito packaging (v0.7).
- Cross-tenant data sharing or marketplace features.

### Reference research

This plan synthesizes findings from prior research in this
conversation, plus the patterns survey across Hermes, Letta/MemGPT,
Cognee, Zep/Graphiti, Mem0, and A-Mem. Patterns imported and
deliberately skipped are documented per phase below.

---

## Phase summary

```
v0.6.0  Foundation       Workspace + Conversation.Session resources, FK plumbing
v0.6.1  Solutions        Migrate Solutions + Reputation to Ash, add FTS + pgvector
v0.6.2  Conversations    Migrate chat transcripts to Postgres with full fidelity
v0.6.3  Memory           Multi-tier memory subsystem, consolidator, retrieval API
v0.6.4  Audit & Tenant   Audit log, real Ash multitenancy, residual file-store cleanup
```

Each phase is independently reviewable and ships as its own point
release; phases must run in order: Phase 1 needs the foundation FKs
from Phase 0; the consolidator in Phase 3 needs queryable transcripts
from Phase 2.

**Rollback caveat.** "Independently revertible" is overstated — once a
phase ships, new traffic writes only to the new Postgres tables (the
JSONL/ETS write paths are removed in 1.7 / 2.6 / 3.18), so reverting to
the prior point release loses visibility into anything written in
between. The plan is *not* dual-write. To make a rollback recoverable
each phase pairs its decommissioning step with an export task that
serializes the new tables back into the old on-disk shape:

- `mix jido_claw.export.solutions` — writes `Solutions.Solution` +
  `Reputation` rows back to `.jido/solutions.json` /
  `.jido/reputation.json` per workspace, in the v0.5.x format the ETS
  store loaded from.
- `mix jido_claw.export.conversations` — writes `Conversations.Message`
  rows back to `.jido/sessions/<tenant>/<id>.jsonl` in `sequence`
  order. **Non-v0.5 roles are dropped on export with a warning**:
  v0.5.x JSONL only ever stored `{role: :user | :assistant, content,
  timestamp}`, so `:tool_call`, `:tool_result`, `:reasoning`, and
  `:system` rows have no equivalent in the rolled-back binary's
  reader. The exporter logs the per-session count of dropped rows to
  STDERR and writes a `.jido/sessions/<tenant>/<id>.export-manifest.json`
  alongside each JSONL listing the dropped sequence numbers and roles
  so a re-import after re-upgrading can replay them via the Phase 2
  importer (which preserves `import_hash` idempotency). Inline-encoding
  the extra roles into the JSONL would either break the rolled-back
  reader or require schema sniffing on every read; dropping with a
  manifest is the simpler and more honest choice.
- `mix jido_claw.export.memory` — writes active `Memory.Fact` rows back
  to `.jido/memory.json` in the v0.5.x entry shape (Block / Episode /
  Link tiers have no v0.5.x equivalent and are dropped on export with a
  warning).

Each export task is idempotent and is run before downgrading. Without
running it, downgrading silently loses post-migration data — the rolled
back binary cannot read Postgres tables it doesn't know about. Each
phase's acceptance gate (§1.8 / §2.7 / §3.19) verifies the
corresponding export task on **two** fixtures:

1. A **sanitized** v0.5 fixture (no strings matching §1.4's
   redaction patterns — no `sk-`, `sk-ant-`, AWS key, JWT,
   `Bearer`, GitHub PAT, or URL-userinfo). load → migrate →
   export → assert byte-equivalent to input (modulo dropped non-
   v0.5 shapes: roles in Phase 2, Block/Episode/Link tiers in
   Phase 3). This is the rollback-safety contract.
2. A **redaction-delta** fixture that *does* contain matched
   patterns. load → migrate → export → assert the exported file
   contains `[REDACTED]` in exactly the positions where the input
   contained matched secrets, with all non-secret bytes
   unchanged. The export task emits a sidecar
   `<file>.redaction-manifest.json` listing the
   `(line_or_offset, pattern_name, original_length)` of every
   redaction it observed during import — the round-trip test
   diff-checks the manifest against the export.

Splitting the gate is what keeps both invariants honest: the
rollback path is byte-true on data that was always safe to
persist, and the redaction path is observably enforced rather than
silently asserted. A single byte-equivalent assertion against a
fixture with secrets would either falsely fail (because import-
time redaction mutates the bytes — see §1.4 for solutions, §2.4
for conversations, §3.10 for memory) or hide a redaction
regression behind "looks the same as input." Without the split
gate, export tasks are a rollback hazard: untested code that only
runs in panicked downgrades.

### Cross-phase dependencies

| Phase | Needs from earlier phases |
|---|---|
| 0 | nothing |
| 1 | Workspace + Session FKs (P0) |
| 2 | Workspace + Session FKs (P0); redaction modules from Phase 1 (§1.4) |
| 3 | Conversations.Message queryable (P2); redaction modules from Phase 1 (§1.4); Workspace/Session FKs (P0) |
| 4 | nothing strict — runs after the dust settles |

The redaction modules
(`Redaction.Patterns` URL-userinfo extension,
`Redaction.Embedding`, `Redaction.Transcript`) ship in Phase 1
even though their broadest consumer (transcript persistence in
Phase 2) lands later — Phase 1's Solution write path and embedding
inputs already need them, and bundling them into v0.6.1 means the
security gate ships with the first dataset that can contain
secrets rather than trailing the data move. See §1.4 for the full
module specs.

### Out-of-band: prerequisite that's already in place

`anthropic_prompt_cache: true` was added to `JidoClaw.Agent` ahead of
this plan. The frozen-snapshot system prompt work in Phase 3 lets that
flag actually fire — without a stable prefix, the cache flag was a
no-op.

---

## Phase 0 — Foundation: Workspace and Session resources

**Goal:** stop carrying tech debt around string IDs in places where we
clearly want FKs. Establish `Workspace` and chat `Session` as real Ash
resources before any data starts pointing at them.

### 0.1 New domain: `JidoClaw.Workspaces`

```
lib/jido_claw/workspaces/
  domain.ex                 # JidoClaw.Workspaces — Ash.Domain
  resources/
    workspace.ex            # JidoClaw.Workspaces.Workspace
```

Following the Forge.Domain / Reasoning.Domain folder convention (the
one used when a domain has more than one or two resources).

### 0.2 `Workspaces.Workspace` resource

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

### 0.3 New domain: `JidoClaw.Conversations`

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

### 0.4 `Conversations.Session` resource

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

### 0.5 String-ID coexistence strategy

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

### 0.5.1 `tool_context` shape upgrade

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

### 0.5.2 Tenant column from Phase 0 (cross-cutting)

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

### 0.6 Migrations

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

### 0.7 Acceptance gates

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

---

## Phase 1 — Solutions migration with FTS + pgvector

**Goal:** retire `JidoClaw.Solutions.Store` ETS+JSON, swap to Ash +
Postgres, replace Stage-1 token-coverage scoring with hybrid FTS +
cosine retrieval, decide the Reputation ledger's fate, and prove out
the migration shape on the simpler of the two stores.

### 1.0 Prerequisites: pgvector and pg_trgm setup

`JidoClaw.Repo.installed_extensions/0` currently returns
`["ash-functions", "citext"]`. AshPostgres vector support
(`AshPostgres.Extensions.Vector`) plus the §1.5 lexical retrieval
branch need four things landed before the v0.6.1 migration that
introduces `embedding vector(1024)`:

1. `"vector"` added to `installed_extensions/0`. The
   `mix ash_postgres.setup_vector` task does this and runs
   `CREATE EXTENSION vector;` against the database.
2. `"pg_trgm"` added to `installed_extensions/0`. Powers the
   `similarity()` ranking and `%` operator in §1.5's
   `lexical_pool`. Installed via a hand-written `execute("CREATE
   EXTENSION IF NOT EXISTS pg_trgm")` in the Phase 1 migration.
3. A Postgrex types module — a single-line file (not inside a
   `defmodule`):
   ```elixir
   Postgrex.Types.define(
     JidoClaw.PostgrexTypes,
     [AshPostgres.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
     []
   )
   ```
4. `config :jido_claw, JidoClaw.Repo, types: JidoClaw.PostgrexTypes`
   in `config/config.exs` so the repo actually uses that module.

Without (3) and (4), the migration succeeds but Postgrex cannot
encode/decode `vector` columns at runtime — every embedding
read/write blows up.

### 1.1 New domain: `JidoClaw.Solutions.Domain`

```
lib/jido_claw/solutions/
  domain.ex                 # NEW: JidoClaw.Solutions.Domain
  resources/                # NEW
    solution.ex             # JidoClaw.Solutions.Resources.Solution
    reputation.ex           # JidoClaw.Solutions.Resources.Reputation
  fingerprint.ex            # KEEP (pure functional)
  matcher.ex                # KEEP (Stage-2 scoring stays in Elixir)
  trust.ex                  # KEEP (pure functional)
  store.ex                  # DELETE after migration
  reputation.ex             # DELETE after migration
  solution.ex               # DELETE after migration (struct → resource)
```

`JidoClaw.Solutions` (the existing namespace) becomes a thin facade
that delegates to the resource code interfaces — same pattern as
`JidoClaw.Forge`.

### 1.2 `Solutions.Resources.Solution` resource

All 13 fields from the current `%Solution{}` struct, plus:

- `embedding` — `vector(1024)` (or whatever Voyage 4 produces; confirmed
  at implementation time and reflected in the migration).
- `embedding_status` — atom
  (`:pending`, `:ready`, `:failed`, `:disabled`); jobs poll this
  column. `:disabled` matches the workspace opt-out semantics in
  §1.4 (a workspace with `embedding_policy: :disabled` writes
  rows that stay `:disabled` permanently and only ever match via
  FTS). Solution and `Memory.Fact` (§3.6) carry the same enum so
  the backfill worker has one shape to switch on across both
  resources.
- `embedding_attempt_count` — integer, default 0. Incremented on
  every failed attempt; the worker flips status to `:failed` once
  it reaches the configured cap (default 6). Durable so a node
  restart doesn't reset the counter and silently retry forever.
- `embedding_next_attempt_at` — `utc_datetime_usec`, nullable. Set
  to `now() + backoff` after a failure; the periodic scan filters
  on `(next_attempt_at IS NULL OR next_attempt_at <= now())` so
  exponential backoff survives across restarts.
- `embedding_last_error` — text, nullable. Latest error message
  when status is `:failed` (or the most recent transient error
  while still `:pending`). Surfaces in `/admin` so operators have
  context for retry/manual intervention rather than just a status
  flag.
- `embedding_model` — text, nullable. Records which model
  produced the current `embedding` (e.g. `"voyage-4-large"`) so
  later mixed-model rollouts and per-row re-embed sweeps know
  which rows are out of date. Set on success; left null while
  pending/failed.
- `search_vector` — `tsvector`, generated column. The migration
  declares it as:
  ```sql
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('english',
      coalesce(solution_content, '') || ' ' ||
      array_to_string(coalesce(tags, ARRAY[]::text[]), ' ') || ' ' ||
      coalesce(language, '') || ' ' ||
      coalesce(framework, '')
    )
  ) STORED
  ```
  The naive `solution_content || tags || language || framework`
  shape is wrong on three counts: (1) `tags` is `text[]`, not
  `text`, and `||` between them is a type error; (2) any null
  field would null the entire concatenation result, so a missing
  `framework` would void the FTS row; (3) the column has to feed
  `to_tsvector`, not be a raw concatenation. `array_to_string`
  flattens the tag array to a space-separated string;
  `coalesce(..., '')` keeps null fields from poisoning the result.
- `lexical_text` — `text`, generated column. The migration
  declares it as:
  ```sql
  lexical_text text GENERATED ALWAYS AS (
    lower(
      coalesce(solution_content, '') || ' ' ||
      array_to_string(coalesce(tags, ARRAY[]::text[]), ' ') || ' ' ||
      coalesce(language, '') || ' ' ||
      coalesce(framework, '')
    )
  ) STORED
  ```
  Pre-lowercased and concatenated so the §1.5 lexical pool can do
  an indexed substring match without per-query `lower()`/`coalesce()`
  wrapping. A single column-level expression is what makes the
  expression GIN trigram index (below) actually fire on the query —
  Postgres only matches index expressions against the *exact* same
  expression in the WHERE clause. Earlier drafts kept `solution_content`
  as the indexed column and called `lower(coalesce(...))` at query
  time, which silently fell back to a sequential scan because the
  index expression and the query expression differed.
- `workspace_id` — nullable FK (Workspaces.Workspace).
- `session_id` — nullable FK (Conversations.Session).
- `created_by_user_id` — nullable FK (Accounts.User).
- `tenant_id` — text, **required** (not nullable). Populated from
  `tool_context.tenant_id` at write time. Per the cross-cutting
  "Tenant column from Phase 0" note (§0.5.2), every new persisted
  resource carries this column so Phase 4 can promote it to an FK
  without a multi-table backfill. Indexed leading every primary
  read pattern below.

Indexes (declared via `custom_indexes` in the `postgres` block, per
JidoClaw convention):

| Index | Type | Purpose |
|---|---|---|
| `(tenant_id, problem_signature)` | btree | tenant-scoped exact-signature lookup; replaces today's linear `tab2list + Enum.find` |
| `(tenant_id, workspace_id)` | btree | tenant- and workspace-scoped reads (the dominant filter combo) |
| `(tenant_id, language, framework)` | btree | filter composition within a tenant |
| `(tenant_id, agent_id)` | btree | reputation lookup join, tenant-scoped |
| `(tenant_id, sharing)` | btree | cross-workspace visibility queries within a tenant |
| `(tenant_id, trust_score DESC)` | btree | sort by trust within a tenant |
| `search_vector` | GIN | FTS (tenant filter applied in WHERE) |
| `lexical_text` | GIN (trigram) | `gin_trgm_ops` operator class; powers the §1.5 `lexical_pool` substring branch via `lexical_text LIKE '%' || $escaped || '%'`. Hand-written `execute/1` migration for the same reason as the HNSW index — `custom_indexes` has no per-column opclass option. Indexed against the generated `lexical_text` column rather than `solution_content` so the index expression matches what the query filters on; otherwise the planner ignores the index. |
| `embedding` | HNSW (cosine — see note) | pgvector ANN; cosine operator class to match the `<=>` distance used in 1.5 |

The HNSW index needs the `vector_cosine_ops` operator class to
match the `<=>` cosine-distance operator used in 1.5; pgvector's
default operator class is `vector_l2_ops`, which would silently
rank against L2 distance. **AshPostgres `custom_indexes` does not
expose an operator-class option** —
`AshPostgres.CustomIndex` (deps/ash_postgres/lib/custom_index.ex)
accepts `using:`, `where:`, `include:`, `nulls_distinct:`, etc.,
but not the per-column opclass that pgvector requires. The index
ships as a hand-written `execute/1` migration statement instead:

```elixir
def up do
  execute("""
  CREATE INDEX solutions_embedding_hnsw_idx
    ON solutions USING hnsw (embedding vector_cosine_ops)
  """)
end

def down do
  execute("DROP INDEX IF EXISTS solutions_embedding_hnsw_idx")
end
```

Filed as a separate migration after the resource migration so
`mix ash.codegen` doesn't try to regenerate it. The other
indexes (problem_signature, search_vector GIN, etc.) stay in the
resource's `custom_indexes` block.

Actions:

- `create :store` — the live write action. Accepts the user-set
  fields (`solution_content`, `problem_description`, `tags`,
  `language`, `framework`, `agent_id`, `sharing`, …), derives
  signature if missing. Required arguments include `workspace_id`
  (the caller's resolved workspace), `tenant_id`, and an optional
  `sharing` (default `:local`, matching today's enum from
  `lib/jido_claw/solutions/solution.ex:39`), so every row is scoped
  at write time. **Does not** accept `id`, `inserted_at`,
  `updated_at`, `deleted_at`, or any of the embedding-status
  retry columns — those are system-managed. A model-routed call
  attempting to set them is rejected by the action's accept-list.

  A `before_action` hook validates the §0.5.2 cross-tenant FK
  invariant: it fetches the `Workspaces.Workspace` row matching
  `workspace_id` and (when set) the `Conversations.Session` row
  matching `session_id` inside the action's transaction, and
  rejects the create with `:cross_tenant_fk_mismatch` when
  either parent's `tenant_id` differs from `changeset.tenant_id`.
  Per the §0.5.2 untenanted-parent rule, `created_by_user_id`
  is skipped (Accounts.User is intentionally untenanted). This
  is the validate-equality variant of the §0.5.2 hook:
  `tenant_id` comes from `tool_context.tenant_id`,
  `workspace_id` comes from the caller's resolved workspace,
  `session_id` from the caller's active session — three pieces
  of context that should agree on tenant but only do so by
  convention. A buggy `WorkspaceResolver` shim or a future
  direct-API caller that constructs `tool_context` from
  disparate sources can produce a mismatch that silently lands
  the row under the wrong tenant; the validate-equality hook is
  the only thing that catches it at write time. Tests in §1.8
  pin a constructed-mismatch fixture against the action.
- `create :import_legacy` — privileged migration-only action used
  by `mix jido_claw.migrate.solutions`. Accepts the full live-action
  field set **plus** `id`, `inserted_at`, `updated_at`, and
  `deleted_at` so the migration can preserve the legacy row's
  primary key (today's `JidoClaw.Solutions.Store` keys ETS by `id`,
  and re-keying breaks referential continuity per §1.6) and its
  observed timestamps. Mirrors `Conversations.Message.:import` and
  `Memory.Fact.:import_legacy` — keeping privileged-import
  surface area off the live `:store` action means a model-routed
  call can't spoof a legitimate row's ID or timestamp via the
  tool path. The action still runs the §1.4 write-time content
  redaction, so legacy secrets get scrubbed on import. The same
  `before_action` cross-tenant FK validation as `:store` runs
  here — even more important on the migrator path, because the
  migration script pieces `tenant_id` and `workspace_id` together
  from independent lookups (the legacy ETS row's `project_dir` →
  Workspace, the host's tenant string → tenant_id) and a
  mismatch would land an entire batch under the wrong tenant
  before anyone noticed.
- `read :by_signature` — arguments `signature`, `workspace_id`,
  `tenant_id`, `local_visibility` (default `[:local, :shared, :public]`),
  `cross_workspace_visibility` (default `[]`).
  Filters to rows where:

  ```
  tenant_id = ^tenant_id
    AND (
      (workspace_id = ^workspace_id AND sharing = ANY(^local_visibility))
      OR sharing = ANY(^cross_workspace_visibility)
    )
  ```

  Splitting visibility into two lists is the load-bearing piece —
  the earlier draft folded both into one `sharing_visibility` array
  joined to `workspace_id = ^workspace_id OR sharing = ANY(...)`,
  which leaks every other workspace's `:local`/`:private` row the
  moment that level appears in the array (and the action's default
  list included it). With the split, `local_visibility` only
  applies inside the caller's workspace, and
  `cross_workspace_visibility` only matches whatever the caller
  has explicitly opted into reading across workspaces (e.g.
  `[:shared]` for network reads, `[:public]` for marketplace
  reads). Defaults are caller-workspace-only — no cross-workspace
  reads happen unless the caller passes `cross_workspace_visibility`
  explicitly. The outer `tenant_id` predicate enforces the
  Phase 4 boundary from day one.
- `read :search` — arguments `query`, `language`, `framework`,
  `limit`, `threshold`, `workspace_id`, `tenant_id`,
  `local_visibility`, `cross_workspace_visibility`. Same split
  scope filter as `:by_signature` is composed into both CTEs in 1.5
  before the RRF merge. Today's per-`project_dir` ETS table
  (`lib/jido_claw/solutions/store.ex:133-156`) gave isolation by
  accident; once everything sits in one Postgres table that
  protection has to be explicit, otherwise a cross-tenant or
  cross-workspace lookup leaks rows.

Sharing vocabulary note: today's enum is `:local | :shared | :public`
(`lib/jido_claw/solutions/solution.ex:226-232`). Earlier drafts of
this plan referenced a different vocabulary
(`:private | :workspace | :public | :network`); we keep today's
shape to avoid a churn migration on top of the data move. If a
finer split is wanted later, that's a follow-up. The cleanup-debt
section flags this for revisit.
- `update :update_trust`, `update :update_verification`,
  `update :update_verification_and_trust` — preserve the existing
  three-way mutation API. The compound update goes through an
  `Ash.Changeset.before_action` that runs `Trust.compute/2`.
- `update :soft_delete` — sets `deleted_at = now()` so rows stay
  in the table (keeps fingerprints stable for replay). Modeled
  as an `update` action rather than a `destroy`: Ash's `destroy`
  actions remove rows by default, and only AshArchival or a
  manual destroy implementation rewrites that into a soft delete.
  An `update` action is simpler and explicit. Reads filter
  `is_nil(deleted_at)` by default; a `read :with_deleted` exists
  for replay/audit. Adds a corresponding `deleted_at`
  (`utc_datetime_usec`, nullable) attribute.

### 1.3 `Solutions.Resources.Reputation` resource — and wire it up

We're choosing the "wire it up" option from the three the audit
surfaced. Reasoning:

- 361 LOC of working code is already there.
- The `Trust.compute/2` `:agent_reputation` opt is wired but never
  fed; closing that loop is a small additional change.
- It's the single most concrete behavioral improvement we get from
  this migration on the Solutions side.

Resource fields mirror today's struct (`agent_id`, `score`,
`solutions_shared`, `solutions_verified`, `solutions_failed`,
`last_active`), plus a required `tenant_id` text column (per §0.5.2)
so reputation is per-tenant from day one. The unique identity becomes
`(tenant_id, agent_id)` rather than `agent_id` alone — two tenants'
agents sharing a string id stay separate.

Wiring. **Every read and write API takes `tenant_id` as a
required first argument** so the resource's `(tenant_id,
agent_id)` identity is honored end-to-end. The single-arg
`record_success/1`, `record_failure/1`, `record_share/1`, and
`get/1` shapes that ship with today's GenServer
(`lib/jido_claw/solutions/reputation.ex:52-91`) are deleted, not
deprecated — keeping them around would let any caller silently
fall back to the v0.5.x global-agent semantics and leak one
tenant's reputation into another's verification path. Concretely:

- `Reputation.record_success/2`, `record_failure/2`,
  `record_share/2` — first arg `tenant_id`, second `agent_id`.
- `Reputation.get/2` — `(tenant_id, agent_id)`; returns the
  default-0.5 entry when no row matches that pair.
- `Reputation.upsert/1` — takes a map `%{tenant_id, agent_id, ...}`;
  used by the migration step in §1.6 step 4.

Call sites:

- `verify_certificate` extracts `tenant_id` from
  `solution.tenant_id` (Phase-0-stamped per §0.5.2) and calls
  `Reputation.record_success/2` / `record_failure/2` with
  `(solution.tenant_id, solution.agent_id)`.
- `Network.Node.handle_solution_shared/2` calls
  `Reputation.record_share/2` with the inbound solution's
  `tenant_id` (which the receiving node stores when accepting
  the share — cross-tenant network shares are out of scope; the
  network layer is per-tenant).
- `Trust.compute/2` callers (only `update_verification_and_trust/3`
  today) look up `Reputation.get(solution.tenant_id,
  solution.agent_id)` and pass the score through
  `:agent_reputation`. Default 0.5 still applies when the
  reputation row is absent.

`agent_id` stays a string for now — making it an FK requires a real
"Agent" resource that doesn't exist yet, and the v0.4.3 `Outcome`
precedent already established the "string for now, FK later" pattern.

**Legacy reputation merge on import.** A single
`.jido/reputation.json` file has no concept of tenants — every row
in it predates the `tenant_id` column. The §1.6 migration writes
each legacy row under whatever tenant is currently in scope at
migration time (typically `"default"`, or the user-uuid string for
authenticated surfaces). Two scenarios need explicit handling:

1. **Same-tenant collision** — two different `.jido/reputation.json`
   files (e.g., from two project directories) are imported into the
   same tenant and contain rows for the same `agent_id`. The
   `(tenant_id, agent_id)` identity makes the second insert
   collide. The migrator merges by **summing the counters**
   (`solutions_shared`, `solutions_verified`, `solutions_failed`)
   and taking `max(last_active)`; `score` is **recomputed** from the
   merged counters via `Reputation.compute_score/1` rather
   than averaging the two pre-existing scores (averaging would
   produce an artifact that doesn't correspond to any real history).
   `Reputation.compute_score/1` is the public-API form of today's
   private `JidoClaw.Solutions.Reputation.recalculate_score/1`
   (`lib/jido_claw/solutions/reputation.ex:237-253`) — same formula
   (`success_rate * 0.5 + activity_bonus + freshness * 0.1 + 0.15`),
   exposed on the new resource module so the migrator and any future
   recomputation path call a documented function rather than reaching
   into a private helper. Earlier drafts referred to
   `Trust.compute_reputation_score/1`, which never existed in
   `JidoClaw.Solutions.Trust` — `Trust.compute/2` computes a Solution
   trust score, not a reputation score.
2. **Cross-tenant import** — a single migration run that imports
   reputation files into multiple tenants treats each tenant
   independently, with no merging across tenants. This is the
   scenario `(tenant_id, agent_id)` was added to enforce in the
   first place.

The migrator emits one telemetry event per merge with
`{tenant_id, agent_id, sources: 2, merged_score: <new>,
prior_scores: [<a>, <b>]}` so operators can audit whether the
merge produced expected results before locking it in. A
`--dry-run` flag prints the merge plan without writing.

**Import-ledger for same-source idempotency.** The merge logic
above is correct for *distinct* source files; it is wrong for the
same source replayed twice. Without a fingerprint of "what we've
already imported," running `mix jido_claw.migrate.solutions` a
second time against an unchanged `.jido/reputation.json` would re-
hit the same-tenant collision branch and sum the same counters into
the same row again, inflating reputation by every replay. Solutions
sidesteps this with `id`-preservation (§1.6 step 5), but reputation
rows have no stable id in the legacy file — the ETS store keys by
`agent_id`, which collides by design — so the migrator records what
it imported in a sibling table:

```
JidoClaw.Solutions.Resources.ReputationImport
- id            :: uuid
- tenant_id     :: text, required
- source_path   :: text     (absolute path of the .jido/reputation.json file)
- source_sha256 :: bytea    (SHA-256 of the file's bytes at import time)
- agents_merged :: integer  (count, for telemetry)
- imported_at   :: utc_datetime_usec
```

Identity: `unique_import_source` on `[tenant_id, source_sha256]`
(total identity, no partial gate). The migrator's per-file flow
becomes:

1. Read the file's bytes; compute `source_sha256`.
2. Look up `(tenant_id, source_sha256)` in `ReputationImport`. If a
   row exists, log `"already imported at <imported_at>; skipping"`
   and move on. Counts as a successful run for `--dry-run`
   reporting.
3. Otherwise: process rows (sum-on-collision merge; recompute
   `score` via `Reputation.compute_score/1`), then insert one
   `ReputationImport` row with the `agents_merged` count.

The `source_sha256` covers a renamed-but-unchanged file (typical
when users move a project directory) — the file's content hash is
the dedup key, not its path. A user who *intends* to re-import an
edited file gets a fresh hash and the merge proceeds; `--dry-run`
plus the merge telemetry surface that to them. A `--force-reimport`
flag is intentionally **not** added: editing the file produces a
new hash, which is the legitimate path to re-merge; bypassing the
ledger would silently double-count.

This is the only legacy-import surface that needs source-fingerprint
tracking. Solutions imports preserve the legacy `id` per §1.6 step
5 and rely on the partial unique identity to deduplicate replays
(no counter accumulation, so a re-insert is a no-op via
`ON CONFLICT DO NOTHING`). Conversations imports use the
`import_hash` partial identity for the same reason. Reputation is
unique among the three because the v0.5 file uses agent_id as both
the row key and the dedup key, so the partial-identity pattern
can't catch replays without a separate ledger.

### 1.4 Embeddings pipeline

New module: `lib/jido_claw/embeddings/voyage.ex`.

- HTTP client wrapped around Voyage AI's API.
- Two callable functions: `embed_for_storage/1` (uses
  `voyage-4-large`, `input_type: "document"`) and
  `embed_for_query/1` (uses `voyage-4`, `input_type: "query"`).
- Both return `{:ok, [float]}` or `{:error, reason}`.
- Both pass `output_dimension: 1024` and `output_dtype: "float"`
  explicitly on every request so the database schema
  (`vector(1024)`) and downstream cosine math are not coupled to
  whatever default the provider happens to expose at that moment.
  Voyage 4-series models are dimension-selectable; pinning the
  request parameter is what guarantees a 1024-element response,
  not the model name. Skipping `input_type` would also let the
  model fall back to a generic embedding space, which costs
  retrieval quality on the document/query asymmetric pair.
- API key from env (`VOYAGE_API_KEY`) via `JidoClaw.Security.Vault` —
  stored encrypted via `AshCloak`, same pattern as other secrets.
- Telemetry: `[:jido_claw, :embeddings, :voyage, :request]` with
  model, tokens, latency, cost.
- **Redaction gate**: every string passed to `embed_for_storage/1` or
  `embed_for_query/1` is run through
  `JidoClaw.Security.Redaction.Embedding.redact/1` (specced below in
  "Redaction modules") before the HTTP request leaves the node.
  Voyage is a third-party API; sending raw user content (which can
  include API keys, JWTs, AWS credentials, PII) is a leak regardless
  of how the embedding is later used. Telemetry counts
  `redactions_applied` per request so we can observe how often the
  gate fires in production. See also "Embedding opt-out per
  workspace" below.

**Redaction modules (built in Phase 1, consumed by Phases 1–3).**
Three modules land together in
`lib/jido_claw/security/redaction/`. All three ship in v0.6.1
because Phase 1 already needs them — Solution write-time
redaction and embedding redaction can't wait for Phase 2 to
introduce them — and the recursive walker is structured to be
reusable as-is by Phase 2's transcript boundary and Phase 3's
Memory.Fact write path. Bundling them into the first phase that
persists potentially-sensitive content means the security gate
ships with the first dataset that can contain secrets.

- `JidoClaw.Security.Redaction.Patterns` — extends the existing
  binary-only module
  (`lib/jido_claw/security/redaction/patterns.ex`) with a new
  **URL-userinfo** pattern (`scheme://user:pass@host` → password
  segment masked), pulled out of the key/value-shaped
  `Redaction.Env` so it can also fire on free-form binaries. The
  existing `sk-`, `sk-ant-`, AWS, JWT, Bearer, and GitHub PAT
  patterns stay as-is. `redact/1` continues to return non-binary
  input unchanged so the recursive walker can call it safely.
- `JidoClaw.Security.Redaction.Embedding` — wrapper used by
  `Voyage.embed_for_storage/1` and `embed_for_query/1`. Calls
  `Patterns.redact/1` over each string in the batch and emits the
  `redactions_applied` telemetry counter.
- `JidoClaw.Security.Redaction.Transcript` — recursive walker
  over arbitrary terms:
  - **Strings:** run through `Patterns.redact/1`.
  - **Maps:** redact each value recursively. When the key matches
    a sensitive name (delegates to
    `Redaction.Env.sensitive_key?/1` — `_KEY`, `_TOKEN`,
    `_SECRET`, `_PASSWORD`, `_PASS`, `_PAT` suffixes plus the
    `AWS_SECRET_*` / `*_URL` specifics), replace the value with
    `[REDACTED]` regardless of shape.
  - **Lists:** redact each element recursively.
  - **Other terms:** pass through (the JSON-safe envelope
    normalizer in §2.4 collapses tuples / non-encodable structs
    to strings or tagged maps before this module runs, so the
    only inputs the walker sees are JSON primitives).
  - Provider-specific JSON shapes (Anthropic content blocks,
    OpenAI tool-call argument JSON strings) get a final pass:
    any binary value that's parseable JSON is decoded, redacted
    as a map, re-encoded.

  The walker is idempotent — re-redacting an already-redacted
  string is a no-op, so migration paths and the live write path
  can share it without double-masking.

  Consumers in this plan:
  - §1.4 write-time redaction of `Solutions.Solution.solution_content`.
  - §1.4 embedding redaction (via `Redaction.Embedding`, which
    wraps `Patterns` directly).
  - §2.4 transcript persistence boundary on `Conversations.Message`.
  - §3.10 Memory.Fact write redaction.

**Embedding opt-out per workspace.** Phase 0 §0.2 already added
`Workspaces.Workspace.embedding_policy` (atom enum
`:default | :local_only | :disabled`) with a default of
`:disabled`; Phase 1 §1.4 is where that column starts being
*consumed*. The three values:

- `:default` — content is redacted (per the redaction gate above)
  then sent to Voyage.
- `:local_only` — embeddings are computed via `Embeddings.Local`
  (a thin wrapper over an Ollama embedding model) and Voyage is
  never called for this workspace's rows. Slower and
  lower-quality, but no third-party exposure. **The local model
  and dimension are pinned, not free-form.** See "Local
  embedding isolation" below for why and how.
- `:disabled` — `embedding_status` stays `:disabled` permanently;
  retrieval falls back to FTS + lexical for these workspaces.

The backfill worker reads `embedding_policy` per row's workspace and
routes accordingly; the queued embedding job re-reads the policy at
execute time so a policy change takes effect on already-pending
rows rather than only newly-inserted ones (this matters because
`:disabled` is the default — a user opting in via
`Workspaces.set_embedding_policy/2` after migration must trigger
embedding work for previously-skipped rows).

**Policy transition: flipping `:disabled` rows when a workspace
opts in.** Re-reading the policy at execute time only helps rows
that are already on the queue (`embedding_status: :pending`).
Rows written under `:disabled` were stamped with
`embedding_status: :disabled` permanently per the §1.4 contract,
so they are *not* on the queue and the periodic scan
(L1311-1330) only selects `:pending` rows. Without an explicit
transition step, a user flipping `:disabled → :default` later
would see embeddings on every newly-written row but not on any
of the rows that pre-date the policy change — a confusing
half-state where some labels match via cosine and others don't,
with no obvious signal to the user about which is which.

`Workspaces.Workspace.set_embedding_policy/2` — and the
`:set_embedding_policy` action it wraps — therefore performs a
transactional row-status fix-up after writing the new policy
value. The transition is shape-specific:

| Old | New | Action on existing rows in this workspace |
|---|---|---|
| `:disabled` | `:default` | Flip every row's `embedding_status: :disabled` → `:pending`, clear `embedding_attempt_count` / `embedding_next_attempt_at` / `embedding_last_error` so the worker treats them as fresh. Rows already at `:pending` / `:ready` / `:failed` (impossible from `:disabled` but defensive) are untouched. |
| `:disabled` | `:local_only` | Same flip to `:pending`. The dispatcher routes to `Embeddings.Local` rather than Voyage at execute time. |
| `:default` | `:local_only` | Flip every `:ready` row's `embedding` to `NULL` and `embedding_status` back to `:pending` so the local model re-embeds (the existing Voyage vector is in a different vector space — see §1.4 "Local embedding isolation"). Pending rows are flipped to `:pending` (no-op shape change) and re-routed at execute time. |
| `:local_only` | `:default` | Mirror of the previous: re-embed via Voyage, since the local vector space differs. |
| `:default` / `:local_only` | `:disabled` | Flip every `:pending` and `:failed` row to `:disabled` so the worker stops trying. **Existing `:ready` rows keep their `embedding`** by default — that data already left the node and clearing the column doesn't recall it; what `:disabled` controls going forward is *new* egress. The action accepts a `purge_existing: true` opt that additionally NULLs `embedding` on every row in the workspace and flips them all to `:disabled` for users who want a hard reset. The opt is off by default so an accidental policy flip doesn't drop expensive embedding work. |
| `:default` ↔ `:default` (no-op) | (no-op) | (no-op) |

The fix-up runs in the same transaction as the policy write,
across both `Solutions.Solution` and `Memory.Fact` per the
shared `embedding_policy` contract in §1.4 / §3.16. For a
small workspace this is a single bounded UPDATE per resource;
for a large one (millions of rows), the action either runs the
UPDATE in `LIMIT`-batched commits behind a configurable
`policy_transition_batch_size` (default 10_000) **or** writes
a single `:policy_transition_pending` marker on the workspace
that a background worker drains over multiple ticks. The
implementation choice is deferred to v0.6.1; both shapes are
acceptable as long as the *visible* contract — "after
`set_embedding_policy/2` returns, no row in this workspace is
in a status incompatible with the new policy" — holds either
synchronously (small workspaces) or eventually (large
workspaces, with the marker visible in `/admin`). The §1.8
acceptance gate exercises the small-workspace synchronous path.

`set_consolidation_policy/2` is a pure column flip — no row
status to fix up — because the consolidator's policy gate
(§3.15 step -1) reads the live workspace policy on every run
rather than caching anything onto Fact / Message rows. Flipping
to `:disabled` on Tuesday means the run on Wednesday morning
skips; flipping back to `:default` on Thursday means the run on
Thursday afternoon proceeds with whatever messages and facts
have accumulated. No catch-up backlog work is needed because
the consolidator's watermark advances only over published rows
(§3.15 step 7), so a multi-day skip is just a longer run when
the policy comes back.

**Local embedding isolation.** `:local_only` writes share the
same `embedding vector(1024)` column as Voyage rows, the same
HNSW index, and the same retrieval CTE shape (§1.5 / §3.13).
That is **only safe** if local and Voyage embeddings are
either kept out of the same retrieval at the query level or
proven to live in compatible vector spaces. They are not
compatible by default — Voyage's 4-series and any local Ollama
model train on different corpora, with different objectives,
and "vector(1024)" is the column dimension, not a guarantee
that two 1024-d vectors live in the same metric space. Cosine
distance between a Voyage `voyage-4` query vector and a
`mxbai-embed-large` document vector is mathematically defined
but semantically meaningless — the retrieval will return rows,
but ranking will be uncorrelated with relevance.

The plan therefore pins three invariants:

1. **One pinned 1024-d local model for v0.6.x.**
   `Embeddings.Local` runs `mxbai-embed-large` (1024-d
   normalized output) against a local Ollama. The choice is
   driven by dimension parity with `vector(1024)` so the
   column shape doesn't have to grow a `vector(N)` per row.
   The configured model is exposed at
   `config :jido_claw, JidoClaw.Embeddings.Local, model:
   "mxbai-embed-large"`; switching to a different 1024-d
   model is a config change, but the plan does not support
   non-1024-d models in v0.6.x. A v0.7+ extension can
   introduce a per-row `embedding_dimensions` column and
   per-(model, dimension) ANN indexes.

2. **Per-row `embedding_model` is queried, not just
   recorded.** §1.2 / §3.6 already declare the
   `embedding_model` text column. The §1.5 `ann_pool` CTE
   and the §3.13 Memory retrieval gain an
   `embedding_model = $K` predicate, where `$K` is selected
   per call from the caller's workspace policy:
   - Workspace `:embedding_policy = :default` → query embedding
     produced by `voyage-4`, ANN pool restricted to
     `embedding_model = 'voyage-4-large'` rows (the storage
     model — query/storage asymmetry in §1.4 is preserved).
   - Workspace `:embedding_policy = :local_only` → query
     embedding produced by `mxbai-embed-large`, ANN pool
     restricted to `embedding_model = 'mxbai-embed-large'`
     rows.
   Without this filter, `:local_only` writes pollute Voyage
   queries (and vice versa) the moment a workspace's policy
   changes or the same retrieval reads across workspaces with
   different policies. The HNSW index is not partitioned by
   `embedding_model` — pgvector's HNSW doesn't support
   filtered indexes — but the predicate runs on the post-ANN
   filter step, and an `(embedding_model, tenant_id)` btree
   pre-filter is added so the planner narrows before the
   distance scan when policies are mixed.

3. **Cross-policy retrieval reads only from the caller's
   policy.** §1.5 acceptance gates already require workspace
   isolation; this extends it to the embedding-space dimension.
   A workspace with `:embedding_policy = :local_only` cannot
   ANN-search Voyage-embedded rows even when sharing
   visibility (`:public`, `:shared`) would otherwise admit
   them, because the vectors aren't comparable. Such cross-
   policy candidates fall back to FTS + lexical pools, which
   work regardless of embedding space. The query planner
   sees this as one extra `AND embedding_model = $K` clause
   on the ann_pool CTE; FTS and lexical pools are unchanged.

   The retrieval contract: **same embedding space within the
   ANN pool, different spaces fall through to FTS/lexical**.
   This is invisible to callers — `Retrieval.search/2` returns
   merged results either way — but the §1.8 acceptance gate
   pins it with a fixture that seeds Voyage and local
   embeddings of the same content under different workspaces,
   issues a query from each, and asserts each pool's ANN
   matches stay scoped to their own model.

The §1.4 transition table (above) folds in the model-switch
case: flipping `:default` ↔ `:local_only` re-embeds because
the existing column is in the wrong space, not because the
data is gone.

**CLI/config surface for setting the policy.** Three entry points,
matching how other per-workspace settings (project_id, archived_at)
are managed today:

- `Workspaces.Workspace.set_embedding_policy(workspace_id, policy)`
  — code interface; the canonical write surface.
- `/workspace embedding <default|local_only|disabled>` — REPL
  command (added in Phase 1 alongside the policy's first consumer)
  scoped to the current session's resolved workspace.
- First-run setup wizard prompt — `mix jidoclaw` on a brand new
  install asks "Enable Voyage embeddings for this workspace?
  [Y/n]" and stamps the chosen value on the freshly-registered
  Workspace row. Existing installs that already passed the wizard
  see no prompt — their workspaces stay `:disabled` until the user
  runs `/workspace embedding` explicitly.

**CLI/config surface for `consolidation_policy`.** Mirrors the
embedding-policy surface, with a separate prompt and command so
the user makes the consent decisions independently:

- `Workspaces.Workspace.set_consolidation_policy(workspace_id, policy)`.
- `/workspace consolidation <default|local_only|disabled>` REPL
  command, added in Phase 3 alongside the consolidator. Scoped
  to the current session's resolved workspace.
- First-run setup wizard prompt — distinct from the embedding
  prompt: "Allow JidoClaw to send transcripts and memory facts
  to a frontier-model consolidator (Claude Code/Codex) for
  long-term memory curation? [y/N]". The default differs
  intentionally — the embedding prompt nudges toward "Y" because
  retrieval quality benefits, while consolidation defaults to
  "N" because the egress class is broader. Existing installs
  see no prompt; workspaces stay `:disabled` until explicitly
  flipped.

The backfill worker MUST refuse to enqueue jobs for any row whose
workspace policy is `:disabled` (the default), and the §1.5
retrieval pool MUST gracefully fall back to FTS + lexical when the
caller's workspace is `:disabled` (no ANN pool, no error). Both
behaviors are pinned by §1.8 acceptance gates so a future
refactor can't silently re-enable Voyage egress on workspaces
that opted out.

New worker: `lib/jido_claw/embeddings/backfill_worker.ex`.

- On `Solution` insert with `embedding_status: :pending`, enqueue an
  embedding job. Implementation: a lightweight queue using existing
  `Task.Supervisor` for in-process dispatch with **bounded
  concurrency** (see "Provider rate-limit backpressure" below).
  Per-row retry state still lives in the database — node restarts
  resume from the durable counters — but the worker process now
  carries an in-process token-bucket pacer and a Postgres-backed
  cross-node lease so two libcluster nodes don't both burn through
  Voyage's RPM at the same time.
- The queued job re-reads `Workspace.embedding_policy` at execute
  time (so a policy change takes effect on already-pending rows
  rather than only newly-inserted ones).
- On embedding success, write `embedding`, set `embedding_model`,
  flip `embedding_status: :ready`, and clear
  `embedding_next_attempt_at` and `embedding_last_error` in one
  update.
- On failure, increment `embedding_attempt_count`, write
  `embedding_last_error`, and set
  `embedding_next_attempt_at = now() + 2^attempt_count seconds`
  (capped at 1 hour). Once `attempt_count` reaches the configured
  cap (default 6 attempts → ~64 seconds + ~128 + ~256 + ~512 +
  ~1024 + cap → roughly 30–35 minutes of backoff total), flip
  `embedding_status: :failed` and surface in `/admin`. All four
  fields persist, so a node restart resumes from the correct
  attempt-count and respects the existing backoff window rather
  than retrying immediately. **HTTP 429 responses from Voyage are
  classified as `:rate_limited` failures** and respect any
  `Retry-After` header the API returns: when present, the
  worker sets `embedding_next_attempt_at = now() + Retry-After`
  instead of the exponential default, and treats the failure as a
  non-counting attempt (does not increment `attempt_count`,
  because rate-limited retries shouldn't burn the row's failure
  budget).
- **Periodic durable backfill scan.** The worker runs a
  configurable-interval (`config :jido_claw, JidoClaw.Embeddings,
  :scan_interval_seconds, 300`) sweep that selects rows with
  `embedding_status: :pending AND (embedding_next_attempt_at IS
  NULL OR embedding_next_attempt_at <= now()) AND inserted_at <
  now() - INTERVAL '1 minute'`, ordered by
  `embedding_next_attempt_at ASC NULLS FIRST`, and re-enqueues
  them. The 1-minute lower bound avoids re-enqueueing rows the
  live insert hook is already about to dispatch; the
  `next_attempt_at` predicate is what makes the scan respect
  exponential backoff across restarts (without it, a permanently
  failing row would re-enter the worker every scan tick rather
  than waiting for the durable backoff to elapse). The scan is
  per-resource — both `Solutions.Solution` and `Memory.Fact`
  (§3.6) get one — and it bounds work via `LIMIT scan_batch_size`
  (default 200) so a large outage backlog drains over multiple
  ticks rather than flooding Voyage in one burst. Telemetry
  counts `recovered_pending_count` and a `failed_count` (rows
  that just flipped to `:failed` this tick) per scan so operators
  can spot a worker that's stuck failing to dispatch.

**Provider rate-limit backpressure.** Voyage publishes RPM and TPM
limits per model and recommends batching, pacing, and exponential
backoff for 429s ([Voyage rate-limit
guide](https://docs.voyageai.com/docs/rate-limits)). The naive
`Task.Supervisor` dispatch + per-row backoff alone doesn't bound
RPM at the node or cluster level — a backfill catching up on
thousands of `:pending` rows after an outage can burst into the
API in milliseconds. The backfill worker adds three layers:

1. **In-process concurrency cap.** A configurable
   `:max_concurrent_embedding_batches` (default 4) bounds how many
   Voyage HTTP requests can be in flight from a single node at
   once. Implemented via `Task.async_stream` with
   `:max_concurrency` rather than fire-and-forget
   `Task.Supervisor.start_child/2` so backpressure flows up to
   the periodic-scan loop.
2. **Token-bucket request pacer.** A
   `JidoClaw.Embeddings.RatePacer` GenServer holds a per-model
   bucket configured from
   `config :jido_claw, JidoClaw.Embeddings, :rate_limits, %{
   "voyage-4-large" => %{rpm: 1_500, tpm: 2_500_000},
   "voyage-4" => %{rpm: 1_500, tpm: 6_500_000} }`. Defaults
   intentionally sit a comfortable margin below the published
   Basic-tier ceilings so burst traffic can fit and so the
   ceiling moves with the operator's billing tier without
   requiring a config change. Voyage's published Basic-tier
   limits as of this writing
   ([rate-limits docs](https://docs.voyageai.com/docs/rate-limits))
   are 2,000 RPM and **3M TPM** for `voyage-4-large` and
   2,000 RPM / **8M TPM** for `voyage-4` — note the asymmetric
   TPM ceilings between the two models. An earlier draft used
   `tpm: 5_000_000` for both, which **exceeds** the
   `voyage-4-large` Basic ceiling and would 429 against a
   free-tier API key in production. Each model's TPM default
   needs its own conservative-of-the-published-ceiling value;
   the values above are roughly 80% of the Basic ceiling. The
   constant-1500 RPM holds for both models because the RPM
   ceiling does not differ across the 4-series. Every dispatch
   calls `RatePacer.acquire(model, token_count)`, which blocks
   (with a timeout) until both the request and token budgets
   refresh enough to admit the call. Refill is computed from
   `System.monotonic_time/1` — no polling timer needed.

   Tier-2 / Tier-3 deployments (paid Voyage accounts; the
   ceilings double / triple) bump these via the same config
   key — operators on a paid account override the map at app
   boot, no code change. The plan does **not** auto-detect the
   account tier: tier discovery via the API is brittle and the
   conservative default is the right behavior for any
   operator who hasn't deliberately raised it.
3. **Cross-node Postgres counter.** When clustering is enabled
   (`:cluster_enabled` per the Application supervisor), `acquire/2`
   atomically increments a per-`(model, window_started_at)` counter
   row **only when the post-increment totals stay within budget**.
   The conditional UPSERT is the load-bearing piece: an
   unconditional increment would let rejected callers consume the
   window's budget, so a backlog of rejected callers — say after
   a brief Voyage outage where every slot is briefly out of budget
   — would continue bumping the counter while being rejected,
   poisoning the window for any legitimate request that arrives
   later in the same second.

   ```sql
   INSERT INTO embedding_dispatch_window
     (model, window_started_at, request_count, token_count)
   VALUES ($1, date_trunc('second', now()), 1, $2)
   ON CONFLICT (model, window_started_at) DO UPDATE
     SET request_count = embedding_dispatch_window.request_count + 1,
         token_count   = embedding_dispatch_window.token_count + EXCLUDED.token_count
     WHERE embedding_dispatch_window.request_count + 1 <= $3
       AND embedding_dispatch_window.token_count + EXCLUDED.token_count <= $4
     RETURNING request_count, token_count;
   ```

   `$3` is `rpm/cluster_window_seconds` and `$4` is
   `tpm/cluster_window_seconds` for the model. The
   `ON CONFLICT … DO UPDATE … WHERE …` clause is a Postgres
   feature: when the WHERE on the DO UPDATE is false, no row is
   updated, the RETURNING returns no rows, and the caller knows
   the slot was rejected. The counter is **unchanged** in that
   case — rejected callers do not consume budget. The INSERT-
   side of the UPSERT (a new row for an empty window) is
   unconditional and admits the first caller per window
   automatically; that's correct because a single request can
   never exceed an integer per-second budget on insertion alone.

   The first caller in a new window writes a row with
   `request_count = 1` and `token_count = $2`. Subsequent
   callers within the same window go through DO UPDATE and are
   either admitted (budget left) or rejected (budget full). When
   admitted, the RETURNING values let the caller assert the
   pacer's local view matches the DB's authoritative view; on
   rejection (zero-row RETURNING), the caller's slot is deferred
   to the next periodic-scan tick. Old rows are GC'd by a daily
   scheduled job that deletes everything older than one minute
   (one minute is the longest backoff the in-process pacer would
   honour; beyond that there's no point keeping the row).

   Edge case: an oversized single request whose `token_count`
   alone exceeds `$4` would otherwise wedge a window forever
   (no number of admitted requests fit). The pacer's local
   token-bucket layer (item 2 above) refuses to dispatch a
   batch larger than `tpm/cluster_window_seconds` so the
   condition can't fire; the SQL-level guard is belt-and-braces
   only.

   Earlier drafts used a session-scoped `pg_try_advisory_lock`
   keyed on `phash2({:embeddings_dispatch, model, second_window})`
   to elect a leader per second-bucket. Three problems with that
   shape made it untenable:

   - **Locks accumulated.** The key changes every second; without
     `pg_advisory_unlock` the connection that won second 0
     continued holding K0 forever, then K1, then K2, etc. Over an
     hour, one connection accrues 3,600 advisory locks — Postgres'
     per-connection lock-manager memory grows unboundedly.
   - **Pooled connections leaked locks across users.** Session-
     scoped locks survive `Repo` connection return-to-pool, so a
     subsequent unrelated query that happened to check out the
     same connection inherited a lock keyed to a stale time
     window. The §3.15 consolidator pattern works around this by
     pinning the connection via `Repo.checkout/2` and explicitly
     unlocking in an `after` block; the embedding lease's
     write-on-acquire path doesn't have a clean place to attach
     either.
   - **`xact`-scoped locks broke the design.** Switching to
     `pg_try_advisory_xact_lock` would have released the lock at
     transaction commit, but admission is a *short* transaction —
     so within the same `second_window`, a second node would
     succeed too, defeating the leader-election goal.

   The counter table sidesteps all three: it doesn't hold any
   connection-scoped state, it's a single atomic UPSERT instead of
   a check-then-act, and the budget is enforced cluster-wide by
   the row's `(model, window_started_at)` unique index. For
   single-node deployments it's a one-row write per dispatch
   (negligible) and the in-process pacer is still the primary
   throttle.

   `embedding_dispatch_window` lives in the `Embeddings` namespace
   as `JidoClaw.Embeddings.Resources.DispatchWindow`. Schema:

   ```
   model               :: text,                primary key (composite)
   window_started_at   :: utc_datetime_usec,   primary key (composite)
   request_count       :: integer
   token_count         :: integer
   ```

   No tenant column — Voyage's RPM/TPM are per-API-key, not per-
   tenant, so the cluster shares one budget regardless of tenant
   scope. If a future deployment wants per-tenant rate limits they
   can be layered on top of this row without changing the schema
   contract.

Tunables exposed via `config :jido_claw, JidoClaw.Embeddings`:

| Key | Default | Purpose |
|---|---|---|
| `:max_concurrent_embedding_batches` | `4` | Per-node concurrency cap. |
| `:rate_limits` | per-model RPM/TPM map | Token-bucket sizing. |
| `:rate_acquire_timeout_ms` | `30_000` | Max wait before a row is re-deferred to backoff. |
| `:cluster_window_seconds` | `1` | `embedding_dispatch_window` row width. Should match the unit the per-second budget is computed in. |
| `:cluster_window_gc_after_seconds` | `60` | Drop `embedding_dispatch_window` rows older than this. |
| `:scan_interval_seconds` | `300` | Periodic recovery scan cadence. |
| `:scan_batch_size` | `200` | Max rows re-enqueued per scan tick. |

Telemetry: `[:jido_claw, :embeddings, :rate_pacer]` with `model`,
`waited_ms`, `bucket_rpm_remaining`, `bucket_tpm_remaining`;
`[:jido_claw, :embeddings, :cluster_window]` with `model`,
`admitted?`, `request_count`, `token_count`, `node`. A spike in
`waited_ms` is the operator signal that the cap is too tight or
the rate limit needs raising; an `admitted? == false` rate that
trends up means the cluster is hitting the per-second ceiling and
nodes are deferring to the next scan tick.
The acceptance gate at §1.8 includes a regression test that
floods 1000 `:pending` rows simulated under a stub Voyage that
returns 429 on the 11th concurrent request and asserts the worker
never actually exceeds 10 in flight — pinning the
`max_concurrent_embedding_batches` ceiling to a real ceiling.

The same acceptance gate covers the **rejected-call no-charge
invariant** for the cross-node counter: pre-fill the
`embedding_dispatch_window` row for `(model, window)` to
`request_count = budget` (i.e., the window is full). Issue 100
admission attempts against the conditional UPSERT; assert all 100
return zero rows (rejected). Read the row back; assert
`request_count` is still exactly `budget` — the rejected attempts
did not bump the counter. Then advance the window by one second
(via a controlled clock) and assert the next admission succeeds.
Without the conditional `WHERE … DO UPDATE`, the counter would
read `budget + 100` after the test and stay above budget for the
rest of the window even though no work was admitted.

**Write-time redaction for Solution content.** Independently of the
embedding redaction, `Solutions.Solution.create :store` runs
`Redaction.Transcript.redact/1` (§2.4) on `solution_content` and on
any tool-call payloads the solution embeds. Today the
`store_solution` tool path takes content from the model verbatim and
stores it; that's a latent secret-persistence path the migration
either has to plug or carry into Postgres. Plugging it at the
`:store` action means migration data (1.6) gets the same treatment
on import. The redactor is idempotent — re-redacting an already-
redacted string is a no-op.

### 1.5 Hybrid retrieval (Stage-1)

Replace `Solutions.Store.search/2` with an Ash `read :search` action
that runs a single SQL query combining FTS rank, cosine similarity,
and exact-lexical (substring) match via Reciprocal Rank Fusion. All
three pools are pre-filtered by the caller's tenant, workspace, and
the requested sharing visibility — this is the same scope predicate
used by `:by_signature`, lifted into the SQL so it composes correctly
with the RRF rank windows. The soft-delete predicate is also lifted
into every pool so a custom-SQL action doesn't bypass the resource's
`is_nil(deleted_at)` default filter (per §1.2's `:soft_delete`
contract):

```sql
WITH fts_pool AS (
  SELECT id,
         ts_rank(search_vector, websearch_to_tsquery('english', $1)) AS rank
  FROM solutions
  WHERE tenant_id = $9
    AND deleted_at IS NULL
    AND search_vector @@ websearch_to_tsquery('english', $1)
    AND ($2::text IS NULL OR language = $2)
    AND ($3::text IS NULL OR framework = $3)
    AND (
      (workspace_id = $6 AND sharing = ANY($7::text[]))
      OR sharing = ANY($8::text[])
    )
  ORDER BY rank DESC
  LIMIT 100
),
fts AS (
  SELECT id, rank,
         RANK() OVER (ORDER BY rank DESC) AS r_fts
  FROM fts_pool
),
ann_pool AS (
  SELECT id,
         1 - (embedding <=> $4::vector) AS sim,
         embedding <=> $4::vector AS dist
  FROM solutions
  WHERE $4::vector IS NOT NULL                  -- skip ANN entirely when query embedding is unavailable
    AND tenant_id = $9
    AND deleted_at IS NULL
    AND embedding IS NOT NULL
    AND embedding_model = $11                   -- vector-space isolation per §1.4 "Local embedding isolation"
    AND ($2::text IS NULL OR language = $2)
    AND ($3::text IS NULL OR framework = $3)
    AND (
      (workspace_id = $6 AND sharing = ANY($7::text[]))
      OR sharing = ANY($8::text[])
    )
  ORDER BY embedding <=> $4::vector ASC
  LIMIT 100
),
ann AS (
  SELECT id, sim,
         RANK() OVER (ORDER BY dist ASC) AS r_ann
  FROM ann_pool
),
lexical_pool AS (
  -- Substring coverage for what FTS can't catch:
  -- partial identifiers ("api" → "api_base_url"), code-ish tokens
  -- with punctuation, exact label matches. The filter uses LIKE
  -- against the pre-lowercased generated column `lexical_text`,
  -- so the GIN trigram index on `lexical_text` (per §1.2) is
  -- actually engaged — the index expression matches the query
  -- expression exactly. `similarity()` is still used for the rank
  -- score (per-row CPU; doesn't need an index).
  --
  -- $10 is the LIKE-escaped, lower-cased query text; the caller
  -- runs the input through `Solutions.SearchEscape.escape_like/1`
  -- which doubles backslashes and prefixes literal `%`/`_` with
  -- backslash before lowercasing, so the filter can't be widened
  -- by user-supplied wildcards ("100%" stays a 4-char literal).
  SELECT id,
         similarity(lexical_text, $10) AS sim
  FROM solutions
  WHERE tenant_id = $9
    AND deleted_at IS NULL
    AND lexical_text LIKE '%' || $10 || '%' ESCAPE '\'
    AND ($2::text IS NULL OR language = $2)
    AND ($3::text IS NULL OR framework = $3)
    AND (
      (workspace_id = $6 AND sharing = ANY($7::text[]))
      OR sharing = ANY($8::text[])
    )
  ORDER BY sim DESC
  LIMIT 100
),
lexical AS (
  SELECT id, sim,
         RANK() OVER (ORDER BY sim DESC) AS r_lex
  FROM lexical_pool
)
SELECT s.*,
       1.0 / (60 + COALESCE(fts.r_fts, 1000)) +
       1.0 / (60 + COALESCE(ann.r_ann, 1000)) +
       1.0 / (60 + COALESCE(lexical.r_lex, 1000)) AS rrf
FROM solutions s
LEFT JOIN fts ON fts.id = s.id
LEFT JOIN ann ON ann.id = s.id
LEFT JOIN lexical ON lexical.id = s.id
WHERE (fts.id IS NOT NULL OR ann.id IS NOT NULL OR lexical.id IS NOT NULL)
  AND s.tenant_id = $9
  AND s.deleted_at IS NULL
ORDER BY rrf DESC
LIMIT $5;
```

Three correctness changes from the earlier draft:

1. **The visibility filter is split into "in-workspace" and
   "cross-workspace" lists** (`$7` and `$8`), matching the
   `:by_signature` action shape in §1.2. The earlier
   `workspace_id = $6 OR sharing = ANY($7)` shape leaked every
   `:local`/`:private` row in every workspace whenever that level
   appeared in `$7` — and the documented default included it. The
   new shape only allows the in-workspace levels (`$7`) to match
   inside the caller's workspace, and cross-workspace levels
   (`$8`) to match anywhere; defaults are
   `$7 = ['local','shared','public']`, `$8 = []`.
2. **Each candidate CTE is materialized via a `_pool` step that
   has its own explicit `ORDER BY ... LIMIT 100` before the
   `RANK()` window runs.** The earlier shape put `LIMIT 100`
   directly on a CTE that contained a window function — Postgres
   evaluates window functions before LIMIT, but without an explicit
   outer `ORDER BY` the LIMIT picks an arbitrary 100 rows from the
   ranked set, so the top-N rank assignments need not appear in
   the output. The pool step makes the top-100-by-relevance
   selection explicit, then the wrapper CTE assigns ranks within
   that already-ordered pool. As a side benefit, the explicit
   `ORDER BY embedding <=> $4 LIMIT 100` in `ann_pool` is the
   access pattern that the HNSW index actually uses for k-NN
   search — without it the planner can fall back to a sequential
   distance scan.
3. **A third `lexical_pool` candidate covers what FTS can't.**
   Postgres FTS tokenizes via stemming and discards punctuation,
   so a query of `"api"` doesn't match a tsvector containing
   `"api_base_url"`, and `"foo.bar.Baz"` doesn't match identifier
   tokens cleanly. Today's `JidoClaw.Memory.recall/2` and
   `Solutions.Store.search/2` both use raw substring match
   (`String.contains?`) and the contract documented in
   `lib/jido_claw/tools/recall.ex` explicitly promises substring
   semantics. The lexical pool restores that capability via two
   working pieces:

   - **A generated `lexical_text` column** (per §1.2) that pre-
     lowercases and concatenates the four searchable fields.
     Trigram GIN indexing happens on this column, *not* on
     `solution_content` — the index expression must match the
     query expression for the planner to use it. Indexing
     `solution_content` while filtering through
     `lower(coalesce(solution_content, ''))` (an earlier draft)
     leaves the index unused; the query degrades to a sequential
     scan as soon as the table outgrows shared buffers.
   - **An escaped LIKE filter** built at the call site. The
     callers thread the query text through
     `JidoClaw.Solutions.SearchEscape.escape_like/1`, which
     prefixes literal `\`, `%`, and `_` with `\` and lowercases
     the result. The query then uses
     `lexical_text LIKE '%' || $escaped || '%' ESCAPE '\'` so the
     trigram-indexed expression is what the planner sees, while
     `recall("100%")` and `recall("user_")` continue to behave as
     literal substring searches the way today's `String.contains?`
     contract promises.

   Earlier drafts considered two alternatives and rejected both:
   `strpos(lower(coalesce(solution_content, '')), lower($1)) > 0`
   preserves substring semantics but doesn't fire any index, so it
   falls to a sequential scan; bare `ILIKE '%' || $1 || '%'`
   widens the filter every time a user types `%` or `_`. The
   generated-column + `escape_like` shape gives both indexed lookup
   and literal-substring semantics. RRF blends all three pools
   with equal weight; the constant-`60` smoothing prevents any
   single missing pool from dominating. The `pg_trgm` extension is
   added to `JidoClaw.Repo.installed_extensions/0` in the same
   Phase 1 migration that adds `vector` and creates the
   `lexical_text` GIN trigram index.

Parameter map:
- `$1` query text — raw, used by FTS via `websearch_to_tsquery`
  (which has its own parser that already handles wildcards safely)
- `$2` language filter (or NULL)
- `$3` framework filter (or NULL)
- `$4` query embedding (or NULL)
- `$5` outer LIMIT
- `$6` caller's `workspace_id` (resolved via `WorkspaceResolver`
  from `tool_context`)
- `$7` in-workspace sharing levels — only applied when
  `workspace_id = $6` matches
- `$8` cross-workspace sharing levels — applied to any row in the
  same tenant
- `$9` caller's `tenant_id` (per §0.5.2; every read is
  tenant-scoped)
- `$10` LIKE-escaped, lower-cased query text — derived from `$1`
  by `Solutions.SearchEscape.escape_like/1` at the call site, so
  the SQL itself contains no wildcard handling. Used by the
  `lexical_pool` filter and `similarity()` rank.
- `$11` ANN embedding model name — set by the caller from the
  resolved workspace's `embedding_policy` per §1.4 "Local
  embedding isolation". `'voyage-4-large'` for `:default`,
  `'mxbai-embed-large'` (or whatever the pinned local model
  is) for `:local_only`. Restricts the ANN pool to candidate
  rows whose stored embedding shares the caller's vector space;
  cross-policy ANN comparisons would be mathematically defined
  but semantically meaningless. Null is not a valid value
  here — when the caller's workspace is `:disabled`, `$4`
  (query embedding) is also NULL and the `$4::vector IS NOT
  NULL` guard short-circuits the pool entirely before this
  filter is evaluated.

Postgres positional parameters are integer-only; earlier drafts
used `$7a`/`$7b` (which is not legal SQL) for the visibility
split — the rewritten map renumbers visibility to `$7`/`$8`,
shifts `tenant_id` to `$9`, and adds `$10`/`$11` for the
lexical-escape and ANN model filters. Defaults are
caller-workspace-only — callers must pass an explicit `$8` list
to broaden cross-workspace visibility.

`SearchEscape.escape_like/1` lives at
`lib/jido_claw/solutions/search_escape.ex`. It's a one-function
module, but it's pulled out so Memory's retrieval (§3.13) and any
future search surface call the same escape implementation rather
than each rolling their own. Reference shape:

```elixir
defmodule JidoClaw.Solutions.SearchEscape do
  @doc """
  Escapes a query string for use as the body of a `LIKE` pattern
  with `ESCAPE '\\'`, then lower-cases it. Use the result inside
  `'%' || ? || '%'` so the surrounding wildcards remain operative
  while user-supplied `%`/`_`/`\\` are taken literally.
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> String.downcase()
  end
end
```

The `$4::vector IS NOT NULL` guard in the `ann_pool` matters
because `embed_for_query/1` can fail (Voyage transient outage,
key expiry, network partition) — when the caller passes `nil`, the
query gracefully degrades to FTS + lexical without scanning the
HNSW index against a `nil` vector. The outer
`WHERE fts.id IS NOT NULL OR ann.id IS NOT NULL OR lexical.id IS
NOT NULL` already handles the empty-`ann` case, so no additional
plumbing is needed at the caller.

Because the SQL uses `<=>` (cosine distance), the HNSW index's
operator class must be `vector_cosine_ops`; the pgvector default
is `vector_l2_ops` (L2 distance), which would silently produce
wrong rankings. See §1.2 for the hand-written `execute/1`
migration that ships the index — AshPostgres `custom_indexes`
doesn't expose a per-column opclass option, so the index can't
live in the resource DSL.

(Exact form of the retrieval query will be expressed via Ash
fragments / `Ash.Query.calculate` or as a custom SQL action —
chosen at implementation time based on which composes better with
filters.)

Stage-2 (`Matcher.score_candidates/2`) still re-fingerprints in
Elixir and combines with `trust_score` 60/40 — that's CPU work, not
DB work. Keep it.

`Matcher.find_solutions/2` orchestration changes at two boundaries:
the public signature gains opts entries `workspace_id:`, `tenant_id:`,
`local_visibility:` (default `[:local, :shared, :public]`), and
`cross_workspace_visibility:` (default `[]`), and both the
`:by_signature` short-circuit and the `:search` fallback thread that
scope through. The rest of the contract (exact short-circuit → fuzzy
fallback → threshold filter → take limit) is preserved.

`JidoClaw.Tools.FindSolution.run/2` and `JidoClaw.Tools.StoreSolution.run/2`
both currently ignore `_context`; in v0.6.1 they read
`tool_context.workspace_uuid` (populated by Phase 0's resolver) and
pass it to `Matcher.find_solutions/2` and the `:store` action
respectively. Tools without a resolved workspace fail loudly rather
than silently storing/reading globally — there is no v0.5.x
"workspace = nil means everywhere" fallback.

**Network ingress facade.** `Network.Node` bypasses the tool layer
entirely — `handle_solution_response/2`
(`lib/jido_claw/network/node.ex:325`) and `store_received_solution/2`
(line 360-363) call `Store.store_solution(attrs)` directly with the
inbound payload + sender `agent_id`. `Network.Node` state today
only carries `:agent_id, :identity, :project_dir, :status, :peers,
:relay_url`; it has no `tenant_id` or `workspace_id`/`workspace_uuid`,
so the new required-`workspace_id`/`tenant_id` `:store` action would
fail loudly on every inbound shared/response solution if the network
paths called it directly.

The migration adds a `JidoClaw.Solutions.NetworkFacade` module that
sits between `Network.Node` and the resource:

```elixir
# Replaces Store.store_solution/1 calls in Network.Node
JidoClaw.Solutions.NetworkFacade.store_inbound(attrs, node_state)
```

Inside the facade:

1. Resolve the receiving workspace from `node_state.project_dir`
   via `WorkspaceResolver.ensure/1` (the same path
   `JidoClaw.chat/3` already uses on line 29 of `lib/jido_claw.ex`).
2. Resolve `tenant_id` from the resolved workspace row (workspaces
   carry tenant per §0.5.2).
3. Force `sharing: :shared` on inbound writes (a peer-shared
   solution is by definition not the receiver's `:local` row,
   regardless of what the sender claimed) and clear any
   sender-supplied `workspace_id`/`tenant_id` keys to prevent
   spoofing.
4. Call `Solutions.Resources.Solution.store/1` with
   `workspace_id`, `tenant_id`, the verified `agent_id`, and the
   redacted/normalized payload.

`Network.Node` state grows a `:project_dir` field at start time
(it already has one — the facade just consumes it) and any future
multi-workspace network presence work updates the facade rather
than re-introducing untenanted writes. The acceptance gate in §1.8
adds an integration test that drives an inbound `:share`/`:response`
through the network path and asserts the resulting Solution row
carries the expected `tenant_id`, `workspace_id`, and
`sharing: :shared`.

### 1.6 Migration script

```
mix jido_claw.migrate.solutions
```

(Implemented as a Mix task at `lib/mix/tasks/jido_claw.migrate.solutions.ex`.)

Steps:
1. Read every `.jido/solutions.json` under known `project_dir`s
   (configurable; default `File.cwd!()`).
2. For each entry, `WorkspaceResolver.ensure/1` to get the workspace
   row, then call the privileged
   `Solutions.Resources.Solution.import_legacy/1` action (per §1.2)
   with all current fields + `workspace_id` + `tenant_id` (resolved
   from the workspace row's tenant) + the preserved `id`,
   `inserted_at`, and `updated_at`. The `:import_legacy` action
   runs the §1.4 write-time redaction over `solution_content`, so
   any secrets that slipped into legacy JSONL are scrubbed on
   import rather than carried into Postgres verbatim. **Preserve the
   legacy `id` (UUID) on the migrated row** — today's
   `JidoClaw.Solutions.Store` keys ETS by `id`, and
   `find_by_signature` uses `Enum.find` (returns the first match),
   which means multiple Solutions can legitimately share a
   `problem_signature`. Migrating with a fresh UUID would break
   referential continuity with anything that cached the old id;
   deduping on signature would silently drop the duplicates.
   `:import_legacy` is the only action that accepts caller-set
   `id`/timestamps — the live `:store` action rejects them, so
   the model-facing tool path can't spoof legacy rows.
3. Embedding starts as `:pending` for workspaces with
   `embedding_policy: :default | :local_only`, and `:disabled` for
   workspaces with `embedding_policy: :disabled` (the Phase 0
   default — §0.2 "Why default `:disabled`"). The backfill worker
   only picks up `:pending` rows, so legacy data never leaves the
   node until a user explicitly runs `/workspace embedding default`
   or the equivalent code-interface call. Operators migrating from
   v0.5 should be aware: retrieval quality on legacy rows is FTS +
   lexical only until the policy is flipped and the backfill
   completes.
4. Reputation: `.jido/reputation.json` → `Reputation.upsert/1` for
   each row, with `tenant_id` set from the migrator's tenant
   argument and the `(tenant_id, agent_id)` identity as the upsert
   key. Same-tenant collisions sum counters and recompute `score`
   via `Reputation.compute_score/1`; cross-tenant rows stay
   isolated. **Same-source replays are short-circuited** by the
   import-ledger check in §1.3 "Legacy reputation merge on import"
   so re-running the migrator against an unchanged
   `.jido/reputation.json` is a no-op — without that, the sum-on-
   collision merge inflates counters every replay. See §1.3 for the
   full merge semantics, the import-ledger schema, and the
   `--dry-run` audit path.
5. Idempotency key: skip the row when its preserved `id` already
   exists in Postgres. Re-running the migration is then safe and
   does not collapse legitimate same-signature duplicates.

### 1.7 Decommissioning

- `JidoClaw.Solutions.Store` GenServer removed from supervision.
- `JidoClaw.Solutions.Reputation` GenServer removed from supervision.
- ETS tables dropped.
- `.jido/solutions.json` and `.jido/reputation.json` left on disk
  (don't delete user data); add a one-line README in `.jido/` noting
  they're deprecated.

### 1.8 Acceptance gates

- `mix test` green; existing Solutions tests adapted (most assertions
  hold; ETS-specific test helpers replaced with sandbox).
- `find_solution` returns better matches than today on a small
  benchmark of paraphrased problem descriptions (qualitative).
- **Substring-superset regression test.** Seed a row whose
  `solution_content` contains an identifier-style token (e.g.
  `"client.api_base_url"`). Issue `:search` with the partial
  token `"api_base"` (something Postgres FTS would not match
  via stemming) and assert the row appears in the result set.
  Repeat for `language` and `framework` filters and a tag-only
  match. Without the §1.5 `lexical_pool` this assertion fails —
  it's the contract `recall.ex` documents and the v0.5.x ETS
  store met by accident.
- **Lexical-index engaged regression test.** Seed 5,000 Solutions
  in one workspace. `EXPLAIN ANALYZE` a `:search` whose only
  matching pool is the lexical one (a punctuated identifier query
  FTS would miss, with no query embedding). Assert the plan node
  selecting from `solutions` for the lexical pool uses
  `Bitmap Index Scan on <lexical_text trigram index>`, *not*
  `Seq Scan`. Catches the regression class where the trigram
  index gets pointed back at `solution_content` (mismatched
  expression → unused index) or where the WHERE clause re-
  introduces `lower(...)`/`coalesce(...)` wrappers (same
  failure mode). Mirror gate in §3.19 for `Memory.Fact`.
- **LIKE-wildcard escape regression test.** Issue `:search` with
  the literal queries `"100%"` and `"user_"`. Assert results match
  rows whose `lexical_text` contains the literal byte sequence,
  not rows where `%` is treated as a wildcard or `_` matches a
  single character. Without `Solutions.SearchEscape.escape_like/1`
  feeding `$10` (per §1.5), `recall("100%")` would match anything
  containing `"100"` and `recall("user_")` would match
  `"user1"`/`"userA"`/etc. — silently widening the contract.
- **Soft-delete leakage regression test.** Seed two rows; soft-
  delete one via `:soft_delete`. Run `:search` and `:by_signature`
  with broad parameters that *would* match the deleted row;
  assert it is not returned. Toggle to `read :with_deleted` and
  assert it now appears. Catches a `deleted_at IS NULL` clause
  going missing from the `lexical_pool`/`fts_pool`/`ann_pool`
  CTEs or the outer SELECT.
- Reputation rows accumulate during a real session.
- No `force:` or string-keyed scope debt added.
- A regression test exercises the cross-workspace isolation
  guarantee: seed solutions in two workspaces, run `:search` and
  `:by_signature` with each workspace's id, assert no row from the
  other workspace appears at any sharing level except the explicit
  cross-workspace ones the test broadens visibility for.
- **Cross-tenant FK validation regression test.** Create two
  Workspaces under distinct tenants (`WS_a` in tenant A, `WS_b`
  in tenant B). Construct a `:store` action call with
  `tenant_id: A` but `workspace_id: WS_b.id` (i.e.,
  `tool_context.tenant_id` and the resolved workspace disagree).
  Assert the action fails with `:cross_tenant_fk_mismatch` and
  no row is written. Repeat for `:import_legacy` with the same
  mismatch, including a check that no rows from the import
  batch were written (the failure halts the transaction). This
  pins the §0.5.2 "cross-tenant FK invariant" hook against
  drift — a future refactor that drops the validation hook from
  the action would surface here rather than in production data.
- **Policy transition row-status fix-up test.** Seed a workspace
  with `embedding_policy: :disabled` and write three Solutions
  under it; assert all three have
  `embedding_status: :disabled`. Call
  `set_embedding_policy(workspace_id, :default)`; assert all
  three flip to `:pending` and that
  `embedding_attempt_count`/`next_attempt_at`/`last_error` are
  cleared. Run the backfill worker; assert the rows reach
  `:ready`. Then call `set_embedding_policy(workspace_id,
  :disabled)` (without `purge_existing`); assert the rows stay
  at `:ready` with their `embedding` intact (existing data is
  not recalled — only future writes are blocked). Repeat the
  last step with `purge_existing: true`; assert `embedding` is
  now `NULL` and `embedding_status: :disabled` on all three.
  Mirror this gate in §3.19 against `Memory.Fact`. Without
  these tests, a refactor that breaks the transition leaves the
  user-facing policy-flip behavior silently wrong.
- `JidoClaw.Solutions.Domain` appended to
  `config :jido_claw, :ash_domains`. Resources don't load without
  the domain entry; missing this is a silent breakage that doesn't
  surface until the first action call.
- `mix ash.codegen --check` clean (no pending resource changes).
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors; the Solutions partial identities
  carry the entries listed in §Cross-cutting concerns.
- Generated columns sanity (per §Cross-cutting "Generated columns"):
  the migration for `Solutions.Solution.search_vector` declares
  `GENERATED ALWAYS AS (to_tsvector(...)) STORED`, and an
  integration test inserts a row, asserts `search_vector` is
  populated by the database (not by Elixir), and asserts FTS
  matches against the populated vector. Without this gate the
  default `mix ash.codegen` output emits a plain
  `add :search_vector, :tsvector` and FTS silently never matches.
- An integration test drives an inbound `:share`/`:response`
  through `Network.Node` and asserts the resulting Solution row
  carries the receiving workspace's `tenant_id`, `workspace_id`,
  and `sharing: :shared` — proves the §1.5 NetworkFacade is wired
  in and the ingress path doesn't bypass the new required scope
  fields.
- **Tenant-scoped reputation parity test.** Record a success for
  `agent_id: "alice"` under tenant A and a failure for the same
  agent_id under tenant B; assert
  `Reputation.get("tenant-a", "alice").solutions_verified == 1`
  and `Reputation.get("tenant-b", "alice").solutions_failed == 1`
  with no cross-pollution. Then assert
  `Trust.compute/2` invoked from a tenant-A solution sees
  tenant A's reputation, and the same call from a tenant-B
  solution sees tenant B's. Without the §1.3 `(tenant_id,
  agent_id)` API change both tenants would resolve to the same
  ETS-style global row.
- **Reputation import-ledger idempotency.** Run
  `mix jido_claw.migrate.solutions` against a fixture
  `.jido/reputation.json` containing
  `agent_id: "bob"` with `solutions_verified: 5`. Assert the
  resulting row has `solutions_verified == 5`. Run the migration
  a second time against the same file with no edits; assert the
  row still has `solutions_verified == 5` (the
  `ReputationImport` ledger short-circuits on the unchanged
  `source_sha256` per §1.3) and that the `ReputationImport` row
  count stays at 1. Then edit the fixture to bump `verified` to
  `7`, re-run; assert the merged row reports `solutions_verified
  == 12` (the legitimate sum-on-collision merge is the only path
  that ever runs). Without the ledger, the second run inflates
  counters to 10 and the third to 17 — the regression the
  source-fingerprint check exists to catch.
- **Embedding rate-limit ceiling test.** Stand up a stub Voyage
  endpoint that returns 429 on the 11th concurrent request and
  records max-in-flight count. Insert 1,000 `:pending` Solutions,
  configure `:max_concurrent_embedding_batches: 10`, and let the
  backfill worker drain. Assert the stub's max-in-flight observation
  never exceeds 10 and zero rows flip to `:failed` (every 429 is
  classified as `:rate_limited` per §1.4 and re-deferred to
  backoff without consuming the row's attempt budget). Without
  the §1.4 concurrency cap + 429 classification, the worker
  bursts past 10 and rows accumulate spurious failures.
- **Cross-node embedding budget test.** Boot two libcluster
  nodes; have both observe the same 1,000 `:pending` rows
  through the periodic scan. Assert the combined RPS as
  measured by the stub Voyage matches the configured per-second
  budget within ±10% — neither node should be operating
  independently of the other. The
  `embedding_dispatch_window` UPSERT in §1.4 is what makes this
  hold; the test fails if the counter approach is replaced with
  the earlier session-scoped advisory-lock shape (which leaks
  locks per second-bucket per §1.4 "Earlier drafts used…").
- **Embedding-policy egress gate.** Insert two
  `Solutions.Solution` rows under workspaces with
  `embedding_policy: :default` and `:disabled` respectively. Run
  the backfill worker against a stub Voyage that records every
  inbound HTTP body. Assert: the `:default` row's content reaches
  the stub (after redaction); the `:disabled` row's content does
  not, and its `embedding_status` stays `:disabled`. Without this
  gate a future refactor could silently re-enable egress on
  opted-out workspaces — the failure mode the §0.2 default exists
  to prevent.
- `mix jido_claw.export.solutions` round-trip test, two
  fixtures (per the Phase summary "Rollback caveat" two-fixture
  contract):
  - **Sanitized fixture**: a v0.5.x `.jido/solutions.json` with
    no strings matching §1.4 redaction patterns. load → migrate
    → export → assert byte-equivalent to input. This is the
    rollback-safety gate.
  - **Redaction-delta fixture**: a v0.5.x `.jido/solutions.json`
    seeded with at least one match per pattern category
    (`sk-…`, `sk-ant-…`, AWS access key, JWT, `Bearer …`, GitHub
    PAT, URL-userinfo). load → migrate → export → assert the
    exported `solution_content` contains `[REDACTED]` in
    exactly the positions the import-time
    `Redaction.Transcript.redact/1` observed (cross-checked
    against the sidecar manifest the export task emits).
    Without this gate, a regression in `Redaction.Patterns`
    (e.g., a tightened regex that stops matching) ships
    silently — the byte-equivalent gate alone would *pass* on a
    secret-containing fixture if redaction had stopped firing.

---

## Phase 2 — Conversations: chat transcripts in Postgres

**Goal:** retire the JSONL writer, capture full-fidelity transcripts
(user, assistant, tool calls, tool results, reasoning) in Postgres,
and give the consolidator a real query surface to work from.

### 2.1 `Conversations.Message` resource

```
lib/jido_claw/conversations/resources/message.ex
```

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `session_id` | uuid (FK Conversations.Session) | required |
| `tenant_id` | text | required; denormalized from the session row by a `before_action` so reads can filter without a join (per §0.5.2). |
| `sequence` | bigint | monotonic per-session ordinal; assigned at write time. See "Per-session ordering" below. |
| `role` | atom (one_of: `:user`, `:assistant`, `:tool_call`, `:tool_result`, `:reasoning`, `:system`) | richer than today's user/assistant binary |
| `content` | text | redacted at write |
| `tool_call_id` | text, nullable | matches a tool_call's id; FK-by-string for now. Combined with `request_id` and `role` for the partial unique identity that prevents duplicate tool rows from re-published signals (see Identities below). |
| `request_id` | text, nullable | The strategy-level request identifier (e.g. ReAct's `request_id` from `runtime_signal_metadata`). First-class column rather than buried in `metadata` because the Recorder (§2.3) keys on it for parent-row lookup and uniqueness, and Phase 3 retrieval/audit queries filter by it. Required on `:tool_call`/`:tool_result`/`:reasoning` rows; nullable on user/system rows. |
| `run_id` | text, nullable | The per-iteration run identifier from the same metadata source. Same rationale as `request_id`; recorded for fault-tracing across iterations of the same request. |
| `parent_message_id` | uuid (FK self), nullable | for chain-of-thought / tool result threading |
| `model` | text, nullable | model identifier for assistant turns |
| `input_tokens`, `output_tokens` | integer, nullable | cost telemetry |
| `latency_ms` | integer, nullable | end-to-end latency |
| `metadata` | map | tool name, error context, residual signal data not promoted above |
| `import_hash` | text, nullable | content-derived dedup key for legacy JSONL imports; null on live traffic |
| `inserted_at` | utc_datetime_usec | append-only, no `updated_at`. Declared as a plain `attribute :inserted_at, :utc_datetime_usec, default: &DateTime.utc_now/0, allow_nil?: false, writable?: true` rather than the standard `create_timestamp` macro — `create_timestamp` ships with `writable? false` (`deps/ash/lib/ash/resource/dsl.ex:54-77`), which would block the `:import` action below from setting historical timestamps from the JSONL. The `:append` action explicitly omits `inserted_at` from its accept list, so live traffic still gets the default; only `:import` is allowed to set it. |

Identities:
- `unique_import_hash` on `[import_hash]`, partial
  (`WHERE import_hash IS NOT NULL`) — used by the JSONL migrator
  for idempotent re-runs (see 2.5). Needs a
  `postgres.identity_wheres_to_sql` entry — see the cross-cutting
  "partial identities" note.
- `unique_session_sequence` on `[session_id, sequence]` — enforces
  the per-session monotonic ordering invariant. Total identity
  (no `where`), so no `identity_wheres_to_sql` entry needed.
- `unique_live_tool_row` on `[session_id, request_id, tool_call_id, role]`,
  partial (`WHERE request_id IS NOT NULL AND tool_call_id IS NOT
  NULL AND role IN ('tool_call', 'tool_result')`). Prevents
  duplicate `:tool_call` / `:tool_result` rows when the Recorder
  receives the same signal twice (e.g. strategy + directive layer
  both publish, or after a Recorder restart that races a re-emitted
  result). Without this, looking up the parent `:tool_call` by
  `tool_call_id` alone is fragile across sessions and reruns. Needs
  a `postgres.identity_wheres_to_sql` entry — see the cross-cutting
  "partial identities" note.

Indexes:
- `(tenant_id, session_id, sequence)` — primary read pattern;
  tenant-scoped per §0.5.2. `sequence` is monotonic by
  construction so it doubles as a chronological key.
- `(session_id, inserted_at)` — kept as a secondary index for
  time-window queries that don't care about strict per-session
  order (e.g. "messages since 1h ago across all sessions").
- `(request_id, role)` — Recorder's parent-lookup path:
  finding the `:tool_call` parent for an arriving `:tool_result`,
  or the most recent `:reasoning` row for a request.
- `tool_call_id` — chase tool result back to call (kept for the
  legacy lookup; the partial identity above is the authoritative
  uniqueness guarantee).
- `parent_message_id` — chain traversal.
- Optional FTS: `search_vector` GIN on `content` for `conversation_search`
  in Phase 3 / Phase 4.

Actions:

- `create :append` — live-traffic write. Accepts `session_id`,
  `role`, `content`, `tool_call_id`, `request_id`, `run_id`,
  `parent_message_id`, `model`, `input_tokens`, `output_tokens`,
  `latency_ms`, `metadata`. Does **not** accept `inserted_at`,
  `sequence`, `tenant_id`, or `import_hash` — `inserted_at` falls
  through to the attribute default; `sequence` is assigned by the
  per-session-ordering `before_action` (live-only, see below);
  `tenant_id` is denormalized from the session row by another
  `before_action` (caller can't spoof it); `import_hash` is null
  on live traffic.
- `create :import` — JSONL migrator only. Accepts everything
  `:append` does plus `inserted_at`, `sequence`, `tenant_id`, and
  `import_hash`. The migrator passes a deterministic per-session
  `sequence` derived from JSONL file order (see 2.5), so the same
  ordering invariant applies to imported and live rows alike.
  The auto-sequence `before_action` **does not run** on `:import`
  — the action validates the caller-supplied `sequence` against
  `[session_id, sequence]` uniqueness (the `unique_session_sequence`
  identity catches collisions) and a non-negative-integer guard;
  `Session.next_sequence` is bumped exactly once per session at
  the end of the import batch, not per row, so concurrent live
  `:append`s during/after the migration pick up where the import
  left off (§2.5 step 4). Reasoning: a per-row hook would
  silently overwrite the migrator's deterministic JSONL ordering
  with a counter-derived value, breaking historical chronology
  and breaking idempotency on rerun (every replay would
  re-allocate fresh sequences). Marked `accept` rather than
  `default_accept` so it's clear at the resource that this is
  the privileged-import surface; the CLI tools / web surfaces
  don't expose it.

  A `before_action` hook validates the §0.5.2 cross-tenant FK
  invariant: it fetches the `Conversations.Session` row matching
  `session_id` inside the action transaction and rejects the
  create with `:cross_tenant_fk_mismatch` when
  `session.tenant_id != changeset.tenant_id`. The `:append`
  action denormalizes `tenant_id` *from* the session row, so the
  invariant trivially holds; `:import` accepts both
  caller-supplied — the migrator pieces `tenant_id` together
  from the host tenant resolution while pulling `session_id`
  from the JSONL filename (which itself reflects the legacy
  per-`project_dir` directory layout). A misaligned migrator
  command (`mix jido_claw.migrate.conversations --tenant=foo`
  pointed at sessions that resolve to tenant `bar`) would
  otherwise land a whole tenant's transcript history under the
  wrong tenant boundary; the validate-equality hook stops the
  batch on the first mismatched row.
- `read :for_session` — orders by `sequence` ASC.
- `read :since_watermark` — used by the consolidator's load query
  in 3.15 step 2.
- `read :by_tool_call`.
- `read :by_request` — args `request_id` (and optionally `role`).
  Used by the Recorder for the parent-row lookup that backs
  `parent_message_id` on `:tool_result` rows; replaces the previous
  `tool_call_id`-only lookup that was fragile across reruns.

**Per-session ordering.** `inserted_at` alone — even at
`utc_datetime_usec` resolution — is not sufficient to order a
session's transcript. The Phase 2.3 Recorder publishes
`:tool_call`/`:tool_result` rows from a separate process than the
Session Worker that publishes user/assistant rows; concurrent
inserts from different processes routinely collide on the
database clock, and sorting by `id` (UUIDv4) on ties yields stable
but not chronological order. `parent_message_id` partly mitigates
this for the tool-call ↔ tool-result subset, but does nothing for
the interleaving of user/assistant/reasoning rows.

The `sequence` column is assigned via a `before_action` hook on
`:append` only — `:import` is the **caller-supplied-sequence
path**, see the action note above. The hook uses an **atomic
counter on the session row**, not an aggregate over `messages`.
`Conversations.Session` gains a `next_sequence` bigint column
(default `1`) — see §0.4 — and the per-message live-write hook
runs the following inside the action's transaction:

```sql
UPDATE conversations_sessions
SET next_sequence = next_sequence + 1
WHERE id = $session_id
RETURNING next_sequence - 1 AS sequence;
```

The `UPDATE … RETURNING` is a single atomic step: Postgres takes a
row-level write lock on that session row for the duration of the
enclosing transaction, increments the counter, and returns the
pre-increment value. Two concurrent appends to the same session
serialize on the row lock; each gets a distinct `sequence` and the
loser of the race waits at most one transaction's worth of writes
(typically microseconds). Appends to different sessions don't
contend.

Why not `SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE
session_id = $1 FOR UPDATE`? Earlier drafts used that shape, but
PostgreSQL **rejects locking clauses on aggregate queries**:
`SELECT MAX(...) ... FOR UPDATE` raises *"FOR UPDATE is not
allowed with aggregate functions"*
([Postgres SELECT docs, "Locking Clauses"](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)).
Even if it executed, it would lock the qualifying *messages* rows
(not a session row), giving no protection on the first append to a
session — the first writer's `WHERE session_id = $1` matches zero
rows so there's nothing to lock, and a concurrent second writer
would compute the same `MAX + 1`. The atomic counter on the session
row sidesteps both issues.

`Session.next_sequence` is initialised to `1` on `create :start`. The
import migrator (§2.5) does **not** mutate `next_sequence` per row —
the auto-sequence `before_action` is `:append`-only, so per-row
import writes leave the counter untouched. After all rows for one
session have been imported, the migrator does a single `Ash.update`
setting `next_sequence = max(sequence) + 1` (§2.5 step 6), so live
writes that arrive afterwards never collide with imported rows.

Read paths use `sequence` where chronology matters within a
single session: `for_session` orders by `sequence` ASC, the JSONL
importer assigns sequences in file order, and the consolidator's
clustering pass (3.15 step 3) groups by `session_id` and orders by
`sequence` so the LLM sees `:tool_call` rows before their
matching `:tool_result` rows even when both committed within the
same microsecond.

The consolidator's *watermark* in 3.9 stays
`(inserted_at, id)`, because the watermark needs a single global
key over messages from many sessions in the same scope; tracking
a per-session sequence map on `ConsolidationRun` would multiply
the watermark schema by the session count without buying anything
the contiguous-prefix invariant doesn't already provide.
`inserted_at` also remains for cross-session telemetry queries
(e.g. "messages per hour across all sessions").

### 2.2 Replace `Session.Worker.add_message/4`

`JidoClaw.Session.Worker` becomes a thin wrapper that calls
`Conversations.Message.append!/1`. The in-memory `messages` list is
kept for the GenServer's lifetime (cheap context for active session)
but the source of truth moves to Postgres.

`handle_continue(:load, state)` re-hydrates from Postgres via
`Message.for_session/1` instead of streaming the JSONL.

### 2.3 Capture tool calls and reasoning at write time

The agent loop currently increments `Stats.track_tool_call/2` and
renders pending tool calls but never persists. Persistence has to
live at a layer every surface shares — `display_new_tool_calls/2`
(`lib/jido_claw/cli/repl.ex:310`) is REPL-only and polls the agent
status snapshot, so hooking it would silently miss every
`JidoClaw.chat/4` caller (`web/controllers/chat_controller.ex`,
`web/channels/rpc_channel.ex`, `platform/channel/discord.ex`,
`platform/channel/telegram.ex`, `platform/cron/worker.ex`) and could
double-write rows when the poll catches a call that's already been
flushed.

Capture instead at the layer that already carries `tool_call_id`
end-to-end *and* the result payload. The available observation
points and what each provides:

1. `[:jido, :action, :start|:stop]` from `Jido.Action.Exec.do_run/4`
   (deps/jido_action/lib/jido_action/exec.ex:430). Carries `action`,
   `params`, `context` — but `tool_call_id` is not in the context.
   `Jido.AI.Turn.run_single_tool/4`
   (deps/jido_ai/lib/jido_ai/turn.ex:707) extracts `call_id`
   locally and never injects it before `execute/4`. **Unreliable
   without a dependency patch.**
2. `[:jido, :ai, :tool, :execute, :start|:stop|:exception]` from
   `Jido.AI.Turn.start_execute_telemetry/3`
   (deps/jido_ai/lib/jido_ai/turn.ex:621). Reads
   `context[:call_id]` — same `nil` problem as (1).
3. `[:jido, :ai, :tool, :start|:complete|:error|:timeout]` from
   `Jido.AI.Reasoning.React.Strategy.emit_runtime_telemetry/8`
   (deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:2310).
   Metadata reliably carries `tool_call_id`, `tool_name`,
   `agent_id`, `request_id`, `run_id`, `iteration`, `model`. **But
   the result payload is not in the metadata** —
   `emit_tool_completed_telemetry/4` (strategy.ex:2375) only uses
   the result to *route* between `tool(:complete)` /
   `tool(:error)` / `tool(:timeout)` and discards it. So this
   tells us *that* a tool finished and *what id* it had, but not
   *what content* the result was. Insufficient on its own for
   full-fidelity transcript persistence.
4. `Jido.AI.Signal.ToolStarted` (`ai.tool.started`) and
   `Jido.AI.Signal.ToolResult` (`ai.tool.result`), emitted by the
   ReAct strategy at strategy.ex:1620 and 1647 (and by the
   directive layer at directive/tool_exec.ex:416 and 431, plus
   directive/emit_tool_error.ex:63). Both signals carry
   `call_id`, `tool_name`, and `metadata` populated by
   `runtime_signal_metadata(request_id, run_id, iteration,
   :tool_execute)`, but **the payload field differs**:
   `ToolStarted` carries `arguments` (the tool input — see
   `deps/jido_ai/lib/jido_ai/signals/tool_started.ex`),
   while `ToolResult` carries `result` (the full payload
   including the raw tuple — see
   `deps/jido_ai/lib/jido_ai/signals/tool_result.ex`).
   **This is the hook for content on both sides of the call** —
   but only after we add an explicit bridge (see below).

**Bus bridging.** These signals are not on `JidoClaw.SignalBus`
today. Each emission point — strategy.ex:1468, directive/tool_exec.ex:423,
directive/tool_exec.ex:438, directive/emit_tool_error.ex:72 — calls
`Jido.AgentServer.cast(self(), signal)` (or the equivalent agent
pid cast), which lands the signal in the AgentServer mailbox and
routes through the agent's internal router. Nothing publishes to
`JidoClaw.SignalBus`. `JidoClaw.Agent` also does not set
`default_dispatch`, so the `Jido.Signal.Dispatch` fallback path is
never engaged either (see `deps/jido/lib/jido/agent_server/directive_executors.ex:22-24`).

The Recorder needs an explicit bridge. The chosen approach:

- Add a `JidoClaw.AgentServerPlugin.Recorder` plugin (using the
  `Jido.Plugin` `handle_signal/2` callback at
  `deps/jido/lib/jido/agent_server.ex:1957-2000`) that intercepts
  `ai.tool.started`, `ai.tool.result`, and the ReAct progress
  signals on the agent's own routing path. The plugin forwards each
  matched signal to `JidoClaw.SignalBus.emit/2` (the existing API
  at `lib/jido_claw/core/signal_bus.ex:48`), then returns
  `{:ok, :continue}` so the agent's existing routing is untouched.
  Plugins are invoked from `do_process_signal/4`
  (`deps/jido/lib/jido/agent_server.ex:1731-1732`), which runs on
  every inbound `cast` — including the inbound paths used by
  strategy.ex:1468 and the directive layer — so every tool signal
  is captured.
- **The plugin must be added to every `use Jido.AI.Agent`
  block individually.** Earlier drafts of this plan claimed
  workers (`workers/coder.ex`, etc.) "inherit the plugin via its
  `use Jido.AI.Agent` macro options" from `JidoClaw.Agent` — that
  is incorrect. Inspection of the codebase
  (`lib/jido_claw/agent/agent.ex:2`,
  `lib/jido_claw/agent/workers/coder.ex:2`) confirms each module
  has its own `use Jido.AI.Agent, ...` block with its own options;
  there is no inheritance from `JidoClaw.Agent`. As-is,
  `anthropic_prompt_cache` is wired only on the main agent and
  every worker template's tool calls would silently bypass the
  Recorder. The Phase 2 implementation must (a) add the plugin
  configuration to every existing `use Jido.AI.Agent`
  declaration: `JidoClaw.Agent` plus
  `workers/{coder, docs_writer, refactorer, researcher, reviewer,
  test_runner, verifier}.ex`; and (b) provide a thin
  `JidoClaw.Agent.Defaults` macro or shared options module that
  callers can splice in to avoid drift. The acceptance gate in
  §2.7 grep-enforces "every `use Jido.AI.Agent` site lists the
  Recorder plugin," which mirrors the §0.7 tool-context coverage
  check.

The Recorder GenServer then subscribes to `ai.tool.*` and
`ai.react.*` topics on `JidoClaw.SignalBus` at supervisor start.
On `ai.tool.started` it writes a `:tool_call` `Message`, populating
`request_id`, `run_id`, and `tool_call_id` from the signal
metadata, plus storing the signal's `arguments` field through the
JSON-safe envelope normalizer (§2.4) into the row's `metadata`
column (redacted per §2.4). The `content` column gets a one-line
summary (`"#{tool_name}(args…)"`) so existing FTS / display paths
still read meaningfully without unwrapping the envelope. On
`ai.tool.result` it writes a `:tool_result` row carrying the
signal's `result` payload — also normalized + redacted —
with `parent_message_id` resolved via the
`Message.read :by_request` action filtering on
`(session_id, request_id, tool_call_id, role: :tool_call)` — not
`tool_call_id` alone. Three reasons the call_id-only lookup the
earlier draft proposed was fragile: (1) call_ids are unique per
request but not globally unique across reruns, so a cold-start
restore that re-emits a stored call_id could collide with an
older row; (2) the strategy and directive layers both emit
`Signal.ToolResult` for the same call in some paths, so a
duplicate started signal could write a sibling `:tool_call` row
with the same call_id; (3) without `request_id` in the WHERE
clause, a session that runs the same tool twice across separate
requests with overlapping lifetimes can match the wrong parent.
The `(session_id, request_id, tool_call_id, role)` partial unique
identity from §2.1 prevents the duplicate row insert in (2) and
the indexed `(request_id, role)` lookup makes the parent fetch
O(log n).

The result payload flows through the JSON-safe envelope
normalizer (§2.4) and is redacted before persistence.

Why a plugin rather than configuring `default_dispatch`: the
`%Directive.Emit{}` codepath that consumes `default_dispatch`
(directive_executors.ex:8-37) is the *outbound* path used when an
action explicitly emits a signal as a directive. The inbound `cast`
path used by the strategy at strategy.ex:1468 never visits that
code, so setting `default_dispatch` would not catch tool signals.
A plugin's `handle_signal/2` runs on every signal the AgentServer
processes, regardless of how it arrived.

**Session correlation.** Neither the runtime telemetry nor the
runtime signals carry `tool_context` — they only have
`request_id` / `run_id`. So the Recorder needs a side mapping from
`request_id → {session_uuid, tenant_id, workspace_uuid, user_id}`,
maintained durably so a BEAM restart mid-request doesn't strand
in-flight tool signals. Implementation: a two-tier cache backed
by Postgres, **not ETS-only**.

A new Ash resource `JidoClaw.Conversations.RequestCorrelation`:

| Attribute | Type | Notes |
|---|---|---|
| `request_id` | text, primary key | Application-generated by the dispatcher; matches the value the runtime signals carry as `metadata.request_id`. |
| `session_id` | uuid (FK Conversations.Session) | required |
| `tenant_id` | text | required (per §0.5.2) |
| `workspace_id` | uuid (FK Workspaces.Workspace), nullable | populated when `tool_context` carried it |
| `user_id` | uuid (FK Accounts.User), nullable | populated for authenticated surfaces |
| `inserted_at` | utc_datetime_usec | |
| `expires_at` | utc_datetime_usec | `inserted_at + idle_timeout_seconds + slack` (default ~10 min); see TTL eviction below. |

Indexes: `request_id` is the PK (covers the Recorder lookup);
`(expires_at)` btree powers the TTL sweep;
`(tenant_id, expires_at)` btree for tenant-scoped operator
queries (the §0.5.2 leading-`tenant_id` shape applies here
too).

Actions: `create :register` accepts `request_id`, `session_id`,
`tenant_id`, `workspace_id`, `user_id`, `expires_at`. A
`before_action` enforces the §0.5.2 cross-tenant FK invariant
across `session_id` and `workspace_id` — both have tenanted
parents, both must match `changeset.tenant_id`. `user_id` is
skipped per the §0.5.2 untenanted-parent rule (Accounts.User
spans tenants by design). The dispatcher writes one
RequestCorrelation per agent invocation; without the validation
hook, a buggy `tool_context` resolver could create a
RequestCorrelation under tenant A whose Session is in tenant B,
and every signal that arrives later would be Recorded against
the wrong tenant — the `Conversations.Message` rows the Recorder
writes denormalize tenant_id from the correlation, so a
mistenanted correlation propagates straight into the transcript.

`destroy :complete` and `destroy :sweep_expired` are the only
delete paths — both bypass the cross-tenant validation (no FK
change), but the destroy itself filters
`tenant_id = caller.tenant_id` via Ash policy so a request from
tenant A cannot delete tenant B's correlation row even when both
are alive concurrently.

ETS in front, Postgres behind, with the same shape:

- **At dispatch time** (`JidoClaw.chat/4` and every other
  `Agent.ask`/`ask_sync` site updated in §0.5.1), the caller
  generates the `request_id` it will pass to the agent and
  **writes both** an ETS entry (`:public, :named_table` —
  `JidoClaw.Conversations.RequestCorrelation.Cache`) and a
  `RequestCorrelation` row in a single helper call. The Postgres
  insert happens before the agent receives the request, so any
  signal the agent emits is guaranteed to find the row.
- **The Recorder reads ETS first** (microsecond lookup, no DB
  round-trip on the hot path) and **falls back to a
  `RequestCorrelation` Postgres lookup** when the ETS row is
  missing — full BEAM restart, hot code reload, or a Recorder
  process crash all clear ETS but leave the durable row intact.
  After a successful Postgres lookup the Recorder rehydrates the
  ETS entry so subsequent signals on the same request hit the
  cache.
- **TTL eviction.** When the corresponding
  `request_completed` / `request_failed` / `request_cancelled`
  signal arrives, the Recorder deletes both the ETS entry and the
  `RequestCorrelation` row. Crashed runs that never emit a
  terminal signal are swept by a periodic worker that deletes
  rows where `expires_at < now()` (default sweep interval 60
  seconds; bounded `LIMIT` per tick so a backlog drains
  gracefully).

This is preferable to "patch jido_ai to thread `tool_context`
through `Runtime.Event` and `runtime_signal_metadata`" because
the patch surface would need to touch every strategy module
(ReAct, Tree-of-Thoughts, Chain-of-Thought), and a small Ash
resource is local to JidoClaw. Earlier drafts described falling
back to `Conversations.Session.metadata`, but nothing in the
dispatch path actually wrote to it — the
`RequestCorrelation` resource closes that gap with an explicit,
testable persistence contract.

For reasoning steps (model thinking turns), subscribe to the
existing ReAct progress signals on the `SignalBus` and write
`:reasoning` rows threaded by `parent_message_id`. The same
correlation table resolves `session_uuid`.

If the signal path proves insufficient (e.g., a future strategy
doesn't emit `Signal.ToolResult`), the **fallback** is a minimal
`deps/jido_ai` patch to inject `tool_context` into
`runtime_signal_metadata`. A patch we'd then have to carry across
upgrades — but acceptable if forced.

This is the "transcript enrichment" decision from the New tensions
section; doing it here means the consolidator in Phase 3 can learn
from "we tried X, Y didn't work, Z worked."

### 2.4 Tool-payload normalization and redaction at write

Tool result payloads on `ai.tool.result` arrive as the raw 3-tuple
`{:ok, value, effects}` or `{:error, reason, effects}` (see
`deps/jido_ai/lib/jido_ai/directive/tool_exec.ex:387-408`). `value`
and `reason` can be any Elixir term — atoms, tuples, structs, nested
combinations of all three. Postgres `jsonb` (which is what
`Message.metadata` is in Ash) cannot encode tuples, will refuse
structs that don't implement `Jason.Encoder`, and silently
stringifies atoms in ways that lose round-trip fidelity. So
persistence runs in two stages: **normalize first, then redact**.

**Stage 1: `JidoClaw.Conversations.TranscriptEnvelope.normalize/1`.**
Converts an arbitrary tool result tuple into a JSON-safe map with
this canonical shape:

```elixir
%{
  status: :ok | :error,                # always present
  value: term | nil,                   # JSON-safe value on :ok; nil on :error
  error: %{type: atom, message: text, # populated on :error; nil on :ok
           details: term | nil},
  effects: [term],                     # JSON-safe; defaults to []
  raw_inspect: text | nil              # set ONLY when normalization had to
                                       # fall back; an Elixir-formatted dump
                                       # of whatever couldn't be encoded
}
```

Normalization rules, applied recursively to `value`, `error.details`,
and each entry in `effects`:

- **Atoms:** convert to string with a `:` prefix preserved (e.g.
  `:ok` → `":ok"`) so re-reads can distinguish atoms from strings
  if needed; safe atoms (`true`, `false`, `nil`) become their JSON
  primitives.
- **Tuples:** convert to a tagged map
  `%{__tuple__: [normalized_elements]}`. Round-trippable; explicit
  about being a non-JSON shape.
- **Structs with `Jason.Encoder`:** encode and decode through
  `Jason` to get a pure map, then recurse.
- **Structs without `Jason.Encoder`:** stringify with `inspect/2`
  (limit `:infinity`, `pretty: false`) into `raw_inspect` and set
  the corresponding slot to `nil`. The envelope's `raw_inspect`
  field is never set otherwise, so its presence is the signal that
  data was lossy.
- **Maps, lists:** recurse into values/elements.
- **Strings, numbers, booleans, nil:** pass through.
- **Anything else** (PIDs, references, functions, ports): same
  fallback as structs without encoder.

**Stage 2: `JidoClaw.Security.Redaction.Transcript.redact/1`** runs
on the normalized envelope. The full module specification — the
recursive rules over strings/maps/lists, sensitive-key detection
via `Redaction.Env.sensitive_key?/1`, and provider-specific JSON
unwrapping — lives in §1.4 alongside the URL-userinfo pattern
extension to `Redaction.Patterns`, because Phase 1's Solution
write path already consumes both. Phase 2 contributes the
**call-site**: applied at the `Message.append`/`:import` boundary
to `content`, `metadata`, and any tool-result payloads before
persistence.
`Message.role: :tool_result` rows store the redacted envelope as
`metadata` (jsonb), with `content` set to a one-line summary
(`"#{tool_name} → ok"` or `"#{tool_name} → error: #{type}"`) so
existing FTS / display paths that read `content` still work
without unwrapping the envelope.

Original (unredacted) content is **not** preserved anywhere — once
redacted, it's gone. This is intentional: the cost of leaking a key
into Postgres outweighs the cost of losing an unredactable string.

### 2.5 Migration: JSONL → Postgres

```
mix jido_claw.migrate.conversations
```

1. Walk `.jido/sessions/<tenant>/*.jsonl`. The `<tenant>` path
   segment is the source of truth for `tenant_id` — preserve it
   verbatim (no defaulting to `"default"`). `Conversations.Session.tenant_id`
   is still a text column in v0.6.0–v0.6.3 (real Ash tenant
   resources don't land until Phase 4), so the migrator does
   **not** require an Ash tenant row to exist; the string is
   stored as-is. As a sanity check the migrator can call
   `JidoClaw.Tenant.Manager.get_tenant/1` against the existing
   ETS table and warn (not skip) when the tenant string isn't
   registered there, so users can reconcile before Phase 4
   converts the column to an FK.
2. Parse each filename to derive `(kind, external_id)`:
   - `session_<timestamp>.jsonl` → `(:repl, "session_<timestamp>")`
   - `discord_<channel_id>.jsonl` → `(:discord, "discord_<channel_id>")`
   - `telegram_<chat_id>.jsonl` → `(:telegram, "telegram_<chat_id>")`
   - `cron_<job_id>_<ts>.jsonl` → `(:cron, "cron_<job_id>_<ts>")`
   - `api_<int>.jsonl` / `api_stream_<int>.jsonl` → `(:api, <as-is>)`
   - any other shape → `(:imported_legacy, <basename without .jsonl>)`,
     with `:imported_legacy` added to §0.4's `kind` enum for this
     purpose. Falling back to `:api` (as earlier drafts did) would
     conflate genuine API sessions with anything that doesn't
     match a known prefix; tagging unknowns explicitly preserves
     the post-Phase-0 invariant that `kind` reflects an actual
     surface and lets the v0.6.4 sweep find imported rows that
     need reclassification.

   The `<tenant>` segment from step 1 supplies `tenant_id`. The
   parser table here is the **only** prefix-inference path in the
   plan; live writes through `chat/4` always carry an explicit
   `:kind` per §0.5.1, so the migrator is the one place where
   prefix parsing is unavoidable (legacy JSONL filenames have no
   sidecar metadata).
3. Resolve the workspace before the session: legacy JSONL doesn't
   carry a `project_dir`, so use `WorkspaceResolver.ensure/1` with
   `File.cwd!()` as the fallback (matches today's `JidoClaw.chat/3`
   behavior at `lib/jido_claw.ex:29`). Then call
   `SessionResolver.ensure_session/4` with
   `(tenant_id, workspace.id, kind, external_id)` — the Phase 0.4
   identity is `[tenant_id, workspace_id, kind, external_id]`, so
   all four are required to look up or insert idempotently. The
   migrator surfaces the `cwd` assumption in its CLI output so
   users with multi-workspace JSONL archives can override.
4. Stream lines from the JSONL **in file order**; for each, call
   `Message.import/1` (the writable-timestamp action defined in
   2.1) with `role`, `content`, derived `inserted_at` from the JSONL
   timestamp, and `sequence` set to the running counter for that
   session (1-based; the importer maintains a `%{session_id =>
   next_seq}` map across the stream). The JSONL on disk is already
   in append order, so the file order is the chronological order;
   using a monotonic counter rather than rederiving from
   `inserted_at` avoids ambiguity on ties. Compute an
   `import_hash = SHA-256(session_id || sequence || role ||
   inserted_at_ms || content)` and store it in a top-level
   `import_hash` attribute on `Message` (text, nullable —
   live-traffic rows leave it null). Including `sequence` in the
   hash is what prevents idempotency from collapsing into
   accidental dedup: two legitimate identical replies in the same
   session at the same millisecond (e.g., a user sending "ok"
   twice in quick succession, or two `:tool_call` rows for the
   same tool in a single turn) would collide on a hash that
   omitted `sequence` and one would be silently dropped on
   import. With `sequence` in the hash the importer remains
   idempotent (re-runs find the same `(session, sequence)` and
   skip on the partial unique identity) without lossy
   deduplication.
5. Idempotency key: a partial unique identity
   `unique_import_hash` on `[import_hash]` gated on
   `WHERE import_hash IS NOT NULL`. Ash identities take attribute
   names, not JSONB paths — burying the hash inside `metadata`
   would force a `custom_indexes` raw-SQL unique index that Ash's
   upsert/conflict resolution wouldn't see, so the migrator
   couldn't use `Ash.Changeset.upsert/2` to skip on collision.
   Plain `inserted_at` is millisecond-resolution
   (`platform/session/worker.ex:93`) and bursty traffic can produce
   ties within a session; legacy JSONL has no row id to preserve, so
   a content-derived hash is the only stable dedup key.
6. **After all rows for a session are imported**, update the
   session row exactly once: `Session.next_sequence = (max
   imported sequence) + 1`. Done as a single `Ash.update` outside
   the per-row loop, not as a per-row hook (the per-row auto-
   increment hook is `:append`-only per §2.1). This is what makes
   live writes that arrive after migration pick up at the right
   ordinal — without it, the first live `:append` post-migration
   would clash with imported `sequence` values on the
   `unique_session_sequence` identity. On a re-run that imports
   zero new rows (every row's `import_hash` already exists), the
   bump is a no-op because `max(sequence)` doesn't move.

JSONL files are **not deleted** during migration. They become a backup
that can be removed by hand after verification.

### 2.6 Decommissioning

- `JidoClaw.Session` legacy module (`platform/session.ex` —
  `save_turn`/`load_recent`) removed; it's already dead code.
- `Worker.append_to_jsonl/3` removed.
- `Worker.load_from_jsonl/2` removed.
- `Worker.jsonl_dir/1` and `jsonl_path/2` removed.

### 2.7 Acceptance gates

- New REPL session creates `Conversations.Session` + `Message` rows.
- Discord traffic populates `Message` rows including tool calls and
  results.
- Existing `JidoClaw.history/2` API preserved (now reads Postgres).
- Migrated transcripts retain full content and ordering.
- Redaction confirmed on the obvious patterns via test fixtures.
- **Recorder plugin coverage**: a CI check (or AST traversal under
  `lib/`) lists every `use Jido.AI.Agent` declaration and asserts
  each one configures the Recorder plugin (matching the §0.7
  tool-context coverage shape). Known sites: `JidoClaw.Agent`,
  `Workers.Coder`, `Workers.DocsWriter`, `Workers.Refactorer`,
  `Workers.Researcher`, `Workers.Reviewer`, `Workers.TestRunner`,
  `Workers.Verifier`. New worker templates added later must satisfy
  the same check. Without this gate, swarm children's tool calls
  silently bypass persistence and transcripts lose fidelity exactly
  where it matters most.
- Concurrent tool-result signals from a single call_id (e.g. both
  the strategy and directive layers publishing) result in exactly
  one `:tool_result` row per `(session_id, request_id,
  tool_call_id, role)` — verified by an integration test that
  emits the same `Signal.ToolResult` twice and asserts the second
  insert is rejected by the partial unique identity.
- **Recorder correlation survives a process restart.** Dispatch a
  request through `JidoClaw.chat/4`; assert the
  `RequestCorrelation` row is in Postgres before the agent emits
  its first tool signal. Stop and restart the Recorder GenServer
  (clearing its ETS cache); emit a `Signal.ToolResult` with the
  same `request_id`; assert the resulting `Message` row carries
  the correct `session_id`, `tenant_id`, `workspace_id`, and
  `user_id` — the fallback found the durable row and rehydrated
  ETS. Without the §2.3 `Conversations.RequestCorrelation`
  resource (rather than the earlier broken
  `Session.metadata` fallback), this test fails by emitting an
  uncorrelated `Message`.
- **TTL sweep eviction.** Insert a `RequestCorrelation` row with
  `expires_at = now() - 1` (manually backdated); run the sweep;
  assert the row is gone. Then dispatch a fresh request; emit its
  terminal `request_completed` signal; assert both the ETS entry
  and the Postgres row are deleted in the same operation.
- A `:tool_call` row's `metadata` envelope contains the tool's
  `arguments` (sourced from `Signal.ToolStarted.arguments`); the
  paired `:tool_result` row's `metadata` envelope contains the
  `result`. A regression test runs a tool end-to-end and asserts
  both shapes — without it the Recorder could silently lose call
  inputs (the original draft confused which signal carries which
  payload).
- An import-hash collision test: two identical `:user` JSONL
  entries written within the same millisecond import as two
  separate Message rows (different `sequence`, different
  `import_hash`), not one. Verifies the §2.5 sequence-in-hash fix.
- **Cross-tenant FK validation regression test for `:import`.**
  Create two Sessions under distinct tenants (`Sess_a` in tenant
  A, `Sess_b` in tenant B). Invoke `Conversations.Message.import`
  with `tenant_id: A` but `session_id: Sess_b.id`. Assert the
  action fails with `:cross_tenant_fk_mismatch` and no row is
  written. The `:append` action's denormalized-from-session
  shape makes its own test trivially pass; the migrator path is
  the one that needs the gate.
- `mix jido_claw.export.conversations` round-trip, three
  fixtures (per the Phase summary "Rollback caveat" two-fixture
  contract, plus the existing dropped-roles case):
  - **Sanitized fixture** with only `:user`/`:assistant` rows
    and no strings matching §1.4 redaction patterns: byte-
    equivalent round-trip.
  - **Dropped-roles fixture** with `:tool_call` /
    `:tool_result` / `:reasoning` rows present: the
    user/assistant subset is byte-equivalent and the dropped
    roles appear in the
    `<file>.export-manifest.json` sidecar with the correct
    sequence numbers and roles.
  - **Redaction-delta fixture** that does contain matched
    secrets in `:user` / `:assistant` content: the export
    contains `[REDACTED]` exactly where the import-time
    `Redaction.Transcript.redact/1` observed a match,
    cross-checked against the export's redaction manifest.
- `mix ash.codegen --check` clean.
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors; Conversations.Message's
  partial identities carry the entries listed in §Cross-cutting
  concerns.
- Generated columns sanity (per §Cross-cutting "Generated columns"):
  the optional `Conversations.Message.search_vector` migration, if
  enabled, declares `GENERATED ALWAYS AS (to_tsvector(content))
  STORED`. (Memory.Fact's `search_vector` and `content_hash`
  generated-column gates land in §3.19.)

---

## Phase 3 — Memory subsystem

**Goal:** replace `JidoClaw.Memory` with a multi-tier, multi-scope,
bitemporal Ash subsystem driven by three write sources, with a
scheduled consolidator and a hybrid retrieval API.

### 3.1 Domain layout

```
lib/jido_claw/memory/
  domain.ex                 # JidoClaw.Memory.Domain (read-only AshAdmin + Authorizer)
  resources/
    block.ex
    block_revision.ex
    fact.ex
    episode.ex
    fact_episode.ex
    link.ex
    consolidation_run.ex
  retrieval.ex              # query orchestration
  consolidator.ex           # scheduled-run orchestrator (per-scope worker entry)
  consolidator/
    cluster.ex              # in-memory clustering (deterministic, no LLM)
    prompt.ex               # renders the harness prompt from clusters + Block tier
    proposals.ex            # staging buffer + validation + transactional publish
    tools.ex                # the scoped MCP tool surface exposed to the harness
                            # (list_clusters, propose_*, commit_proposals, etc.)
  embedder.ex               # delegates to Embeddings.Voyage
  scope.ex                  # scope precedence + chain helpers
```

The Forge runners that the consolidator drives live where the
existing infrastructure already does:

```
lib/jido_claw/forge/runners/
  claude_code.ex            # already present; consolidator uses it as-is
  codex.ex                  # NEW in Phase 3; sibling runner with sync_host_codex_config/1
```

The existing `lib/jido_claw/platform/memory.ex` GenServer is renamed
to `JidoClaw.Memory.Cache` for a transitional period and eventually
removed (see 3.10).

### 3.2 Multi-scope schema (shared across all resources)

The **primary memory resources** — `Memory.Block`, `Memory.Fact`,
`Memory.Episode`, and `Memory.ConsolidationRun` — each carry the
full set:

| Column | Type | Notes |
|---|---|---|
| `tenant_id` | text, **required** | per §0.5.2; outer scope above the precedence chain. Every memory read filters on this first. |
| `scope_kind` | atom (`:user`, `:workspace`, `:project`, `:session`) | which scope this memory "lives at" within the tenant |
| `user_id` | uuid (FK Accounts.User), nullable | populated for narrower scopes too |
| `workspace_id` | uuid (FK Workspaces.Workspace), nullable | populated for project/session scopes |
| `project_id` | uuid (FK Projects.Project), nullable | populated for session scope when known |
| `session_id` | uuid (FK Conversations.Session), nullable | only for `scope_kind: :session` |

The **derived/edge resources** —
`Memory.BlockRevision`, `Memory.FactEpisode`, and `Memory.Link` —
carry **at least `tenant_id`** (denormalized from a parent row by
a `before_action` and validated against any second parent row).
Each table's per-row notes specify the exact subset:
- `BlockRevision` denormalizes the full set from its parent
  `Block` (full audit trail with scope on every revision).
- `FactEpisode` denormalizes `tenant_id` only (cross-tenant
  joins rejected at write time); cross-scope joins inside one
  tenant remain legal because consolidator clusters can mix
  episodes from sibling scopes intentionally.
- `Link` denormalizes `tenant_id` and `scope_kind` (cross-tenant
  *and* cross-scope edges rejected at write time, per §3.8).

The reason derived rows don't all carry the full §3.2 set is to
keep the denormalization hooks fast — every column the hook copies
is a column that has to stay consistent through every parent
mutation — and because the §3.13 retrieval API doesn't query
revisions or join rows directly. Phase 4 tenant policies attach to
`tenant_id` on every table, so the security boundary is uniform
even when the scope detail isn't.

Read precedence within a tenant (closer scope wins on dedup):
`session > project > workspace > user`. Implemented in
`Memory.Scope.resolve/1`, which takes a `tool_context` and returns
the `(tenant_id, FK chain)` pair to query. `tenant_id` is *not* in
the precedence chain — it's a hard outer boundary — so memory never
crosses tenants regardless of scope.

**Scope FK invariant.** The matching FK for a row's `scope_kind`
must be populated. The ancestor FKs *may* be populated and are
expected to be when the consolidator or write-time helpers can
resolve the chain (a session-scoped memory has `session_id`,
`project_id` if the session is linked to a project, `workspace_id`,
and `user_id` all populated whenever known). Ancestor FKs being
populated is what lets read-precedence queries (`session > project
> workspace > user`) join through a single row efficiently and
lets retention/cleanup operations cascade — e.g. archiving a
workspace finds every memory pointing at it without a recursive
session lookup.

A single check constraint enforces only "the FK matching
`scope_kind` is `NOT NULL`." Ancestor FKs are unconstrained; create
actions populate them but don't validate that they're set, because
a fact written before its workspace is reified (e.g. a CLI-only
flow) would still be valid with only the deeper FK known.

Earlier drafts of this plan said the per-scope create actions
"validate that the scope FK matching its name is populated and
the others are null." That was incorrect: it would have made
ancestor population impossible, and it's not what the partial-index
`where` clauses in 1.2 / 3.4 / 3.6 enforce either (they only
require the matching FK `IS NOT NULL`). The validation is
"matching FK populated" — full stop.

### 3.3 Bitemporal columns (shared)

The bitemporal axis is carried by **`Memory.Block`,
`Memory.Fact`, and `Memory.BlockRevision`** — the resources
that can be superseded over time. `Memory.Episode` is
event-shaped (an episode happened or it didn't; there's no
"valid_at vs invalid_at" axis), and `Memory.ConsolidationRun`
has its own time columns (`started_at` / `finished_at` /
watermark `_at`s) that record run lifecycle, not bitemporal
truth. `Memory.FactEpisode` and `Memory.Link` are join/edge
rows that inherit their bitemporal semantics from the parent
Fact rows they reference. The earlier draft of this section
read "every memory resource also carries" the bitemporal
columns; that overstated the contract — only the
truth-bearing tier resources carry them, and read paths
filter accordingly.

Block, Fact, and BlockRevision each carry:

| Column | Meaning |
|---|---|
| `inserted_at` | **system** time the row was inserted (Ash standard); when *we learned* about this fact. |
| `valid_at` | **world** time the fact became true (defaults to `inserted_at` if unspecified); when *the world* started having this property. |
| `invalid_at` | **world** time the fact became no longer true; null if currently valid (or if validity has no scheduled end). |
| `expired_at` | **system** time we learned the fact was no longer valid; the system-time partner of `invalid_at`. Null if we still consider the fact valid. **Not a soft-delete.** Memory rows are never destroyed; they're invalidated bitemporally. The retrieval API in §3.13 distinguishes the world axis (`valid_at`/`invalid_at`) from the system axis (`inserted_at`/`expired_at`) and applies them independently; conflating `expired_at IS NULL` with "row is current" is load-bearing only on the default current-truth read, and §3.13 is explicit about the four modes. |

The two axes are independent. A fact's lifecycle on each axis:
- World axis: `valid_at` set at creation; `invalid_at` may
  later be set if the world changes.
- System axis: `inserted_at` set at creation; `expired_at` may
  later be set if our *knowledge* changes (e.g. the consolidator
  invalidates a fact based on contradicting evidence).

Reads default to current truth (current-system, current-world):
`WHERE valid_at <= now() AND (invalid_at IS NULL OR
invalid_at > now()) AND expired_at IS NULL`. The `valid_at <=`
clause matters because Facts can be recorded with a future
`valid_at` (e.g. a planned change), and the default read should
exclude those until they're actually true. The `expired_at IS
NULL` clause is the hot-path shortcut for "current system
knowledge"; on time-travel reads it is replaced by the full
system-time predicate or dropped entirely. Historical reads
substitute `as_of_world` for `now()` on the world clauses and
`as_of_system` for `now()` on the system clauses, independently
— see §3.13 for the predicate matrix. The consolidator never
deletes; it sets `invalid_at` (world axis: stopped being true)
and `expired_at` (system axis: we now know that) when
contradicted by a new fact.

### 3.4 `Memory.Block` — curated tier

Pinned to the system prompt with frozen-snapshot semantics. Always
visible to the model; never searched.

| Attribute | Type | Notes |
|---|---|---|
| `id`, scope cols, bitemporal cols | (as above) | |
| `label` | text | e.g., `"persona"`, `"project_conventions"`, `"user_preferences"` |
| `description` | text | guides the consolidator on what belongs here |
| `value` | text | the content seen by the model |
| `char_limit` | integer, default 2000 | hard cap; writes that exceed fail |
| `pinned` | boolean, default true | unpinned blocks are eligible for eviction |
| `position` | integer | render order in the system prompt |
| `source` | atom (`:user`, `:consolidator`) | model cannot write blocks directly |

Identities: `unique_label_per_scope` enforced as four partial unique
indexes — one per `scope_kind` value — each over `[tenant_id,
label]` plus the single FK column populated for that kind
(`user_id`, `workspace_id`, `project_id`, or `session_id`). The
`[scope_kind, scope_id, label]` shorthand from earlier drafts
referenced a `scope_id` column that the schema in 3.2 does not
have (it has four separate nullable FK columns). Each partial index
also requires `WHERE invalid_at IS NULL` so historical (invalidated)
Block snapshots don't collide with the live row. The `tenant_id`
prefix is what enforces the per-§0.5.2 outer boundary —
without it, two tenants' identical labels at the same workspace
FK could collide. All four partial identities need
`postgres.identity_wheres_to_sql` entries — see the cross-cutting
"partial identities" note.

Char-limit enforcement uses the Hermes pattern: when a write would
exceed the limit, return an error that includes the current value
back to the consolidator so it can rewrite.

Actions:

- `create :write` — used by both user CLI writes (§3.12) and the
  consolidator's `propose_block_update` (§3.15 step 4 staging
  buffer; the worker calls `:write` at step 7 publication).
  Accepts `scope_kind`, the populated scope FKs, `tenant_id`,
  `label`, `description`, `value`, `position`, `pinned`,
  `source` (`:user` or `:consolidator`). A `before_action`
  enforces (a) the §3.2 scope-FK invariant — the FK matching
  `scope_kind` is populated; (b) the §0.5.2 cross-tenant FK
  invariant — every populated scope FK's parent row has
  `tenant_id == changeset.tenant_id`, with the same
  validate-equality shape used by `Memory.Fact.:record`; and
  (c) the char-limit cap on `value`. Wrapped in
  `transaction? true`; the same transaction writes a paired
  `Memory.BlockRevision` row (§3.5) **before** the live Block
  insert/update so revision history is append-only and cannot
  diverge from the live row's content.
- `update :revise` — same accept-list as `:write` minus
  `scope_kind` and the scope FKs (those are immutable). Same
  cross-tenant validation against the existing row (the new
  `tenant_id` cannot change; the action rejects an attempt to
  set it). Writes a Revision before mutating, same as `:write`.
  The consolidator's published Block updates land here.
- `update :invalidate` — sets `invalid_at` on the live Block
  and writes a final tombstone Revision. Used by `/memory
  forget block <label>` (§3.12) and by the consolidator on the
  rare case of a Block ruled obsolete. Bitemporal: `valid_at`
  is preserved (per §3.3 invariant — overwriting it destroys
  the world-time axis).
- `read :for_scope_chain` — reads all current Blocks for a
  scope chain (the four-FK chain the §3.13 prompt builder
  hydrates). Filters `invalid_at IS NULL` plus the §3.13
  bitemporal current-truth predicate; returns ordered by
  `position ASC`. The frozen-snapshot prompt (§3.14) reads via
  this action.
- `read :history_for_label` — `(tenant_id, scope FK, label)` →
  list of revisions, oldest first. Used by `/memory blocks
  history <label>` to surface the audit trail.

`Memory.Block` does not have a `:destroy` action. Per §3.3,
memory rows are never destroyed; invalidation is bitemporal.
The §4.5 residual-file-store sweep similarly enforces "no
delete paths land in the implementation."

Indexes (in addition to the four partial unique identities
above): `(tenant_id, scope_kind, label, invalid_at)` btree —
matches the §3.13 reader's "current Blocks for this scope" path
with `invalid_at` last so `IS NULL` partial-index plans still
hit the same physical column ordering. `(tenant_id, source,
inserted_at)` btree for "what did the consolidator write
recently" admin queries.

### 3.5 `Memory.BlockRevision` — append-only history

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `block_id` | uuid (FK) | required |
| `tenant_id` | text | denormalized from the parent Block's `tenant_id` by a `before_action` (caller can't spoof). Required so Phase 4 tenant-aware policies attach directly to revisions without joining through Block, and so a residual Block delete that orphaned the revision row would still carry tenant scope for audit. Validation in the action also asserts `tenant_id = block.tenant_id` to catch any bypass of the denormalization hook. |
| `scope_kind`, scope FKs | (as §3.2) | denormalized from the parent Block at the same moment as `tenant_id`. Same rationale: Phase 4 policies, residual-row scoping, and detached-from-parent audit. |
| `value` | text | snapshot at write time |
| `source` | atom | as above |
| `written_by` | text | user id, "consolidator", or `"model:remember"` for legacy paths |
| `reason` | text, nullable | consolidator-supplied rationale |
| `inserted_at` | utc_datetime_usec | |

Every Block update writes a Revision before mutating the live Block
(via an `Ash.Changeset.before_action`); the same hook that copies
`tenant_id` and the scope FKs runs first so the revision is
already scope-stamped when the unique block-side row commits.
Block deletes write a final `tombstone` revision and set the
Block's `invalid_at`.

### 3.6 `Memory.Fact` — searchable tier

| Attribute | Type | Notes |
|---|---|---|
| `id`, scope cols (incl. `tenant_id`), bitemporal cols | (as above) | |
| `label` | text, nullable | optional short identifier; carries the model's `remember` `key`, the user's `/memory save <label>` argument, **and the legacy `entry.key` from `.jido/memory.json` imports** so `forget` can target by label and the invalidate-and-replace flow can find the prior active row. Today's `JidoClaw.Memory.recall/2` substring-matches on `key` (`lib/jido_claw/platform/memory.ex:152-157`) and the Recall tool's docstring promises that contract; dropping the legacy key on import would silently break those matches. Null only for consolidator-promoted Facts. |
| `content` | text | the searchable claim. Redacted at write per §3.10. |
| `content_hash` | bytea, generated | SHA-256 of `content`, generated column: `GENERATED ALWAYS AS (digest(content, 'sha256')) STORED`. Used as the dedup key for unlabeled writes (specifically consolidator-promoted Facts). Requires the `pgcrypto` extension — added to `JidoClaw.Repo.installed_extensions/0` in Phase 3. |
| `embedding` | vector(N) | populated async by embedder |
| `embedding_status` | atom | `:pending`, `:ready`, `:failed`, `:disabled` (per §1.4 workspace policy) |
| `embedding_attempt_count` | integer, default 0 | mirrors §1.2; durable retry counter so node restarts don't reset progress |
| `embedding_next_attempt_at` | utc_datetime_usec, nullable | mirrors §1.2; backoff window honored by the periodic scan |
| `embedding_last_error` | text, nullable | mirrors §1.2; surfaces in `/admin` |
| `embedding_model` | text, nullable | mirrors §1.2; records which model produced the current embedding |
| `search_vector` | tsvector (generated) | over `coalesce(label, '') || ' ' || content || ' ' || array_to_string(coalesce(tags, ARRAY[]::text[]), ' ')`. Tags are included so a `recall("preference")` can hit a Fact tagged `[:preference]` without a label or content match — preserves today's `recall` behavior of substring-matching on the legacy `kind` field, which migrates to a tag in §3.17. |
| `lexical_text` | text (generated) | `lower(coalesce(label, '') || ' ' || content || ' ' || array_to_string(coalesce(tags, ARRAY[]::text[]), ' '))`, `GENERATED ALWAYS AS (...) STORED`. Same role as `Solutions.Solution.lexical_text` (§1.2): pre-lowercased + concatenated so the §3.13 lexical pool can do an indexed substring match via `lexical_text LIKE '%' || $escaped || '%' ESCAPE '\'` against the GIN trigram index on this column. The expression-index → expression-query pairing is what makes the trigram lookup actually fire instead of falling back to a sequential scan. |
| `tags` | {:array, text}, default [] | freeform |
| `source` | atom (`:model_remember`, `:user_save`, `:consolidator_promoted`, `:imported_legacy`) | |
| `trust_score` | float, default 0.5 | seeded by source; nudged by consolidator |
| `import_hash` | text, nullable | content-derived dedup key for legacy `.jido/memory.json` imports; null on live traffic. Mirrors the Phase 2 `Conversations.Message.import_hash` pattern (§2.5). Hash shape: `SHA-256(workspace_id \|\| label \|\| content \|\| inserted_at_ms)`. Used by `mix jido_claw.migrate.memory` to make re-runs idempotent without relying on legacy UUIDs (legacy entries are keyed by user-supplied strings, not UUIDs — see `lib/jido_claw/platform/memory.ex` `record_to_entry/1`). |

`inserted_at` and `valid_at` follow the same writable-attribute
pattern as `Conversations.Message.inserted_at` (§2.1): plain
`attribute :inserted_at, :utc_datetime_usec, default:
&DateTime.utc_now/0, allow_nil?: false, writable?: true` and
`attribute :valid_at, :utc_datetime_usec, default:
&DateTime.utc_now/0, allow_nil?: false, writable?: true`. The
`:record` create action doesn't accept either, so live traffic
gets the defaults; only `:import_legacy` (below) does. `invalid_at`
and `expired_at` stay default-nil and are only set by the
invalidate actions or the invalidate-and-replace flow inside
`:record` (§3.6 "Why this is no longer an upsert").

Provenance is modeled as `has_many :fact_episodes, FactEpisode`
(see 3.7.1) — a single fact can be derived from one message, a
cluster of messages, or a mixture of messages + prior facts, so the
relation is M:N rather than a singular `episode_id`. `:model_remember`
and `:user_save` writes link a single FactEpisode at insert time
(the originating message); the consolidator links every clustered
Episode that contributed to a promoted fact.

Identities, two families, both partial:

- **`unique_active_label_per_scope_*` (one per `scope_kind`)** —
  over `[tenant_id, label, source]` plus the single populated
  scope FK, gated on `WHERE label IS NOT NULL AND invalid_at IS
  NULL`. Prevents two active labeled rows from the same source
  colliding within a scope. Used as a uniqueness guarantee, not
  an upsert target — see "Why this is no longer an upsert"
  below.
- **`unique_active_promoted_content_per_scope_*` (one per
  `scope_kind`)** — over `[tenant_id, content_hash]` plus the
  single populated scope FK, gated on
  `WHERE source = 'consolidator_promoted' AND invalid_at IS NULL
  AND content_hash IS NOT NULL`. Prevents the consolidator from
  publishing two active unlabeled Facts with byte-identical
  content for the same scope. Necessary because consolidator-
  promoted Facts have `label IS NULL` (so the label identity is
  inapplicable) and the contiguous-prefix watermark (§3.9)
  intentionally re-loads deferred clusters on the next run — if
  the harness regenerates the same proposal, the duplicate is
  rejected by this identity rather than persisted.

All eight partial identities need `postgres.identity_wheres_to_sql`
entries — see the cross-cutting "partial identities" note.

Indexes: `(tenant_id, scope_kind, valid_at)` btree,
`search_vector` GIN, `(tenant_id, source, inserted_at)` btree,
plus the partial unique indexes above (the label one doubles as
`forget`-by-label lookups). The HNSW index for `embedding` ships
as a hand-written `execute/1` migration (`CREATE INDEX ... USING
hnsw (embedding vector_cosine_ops)`) for the same reason as in
§1.2 — AshPostgres's `custom_indexes` DSL has no per-column
opclass option, and the cosine operator class is required for
the `<=>` distance used in retrieval (default `vector_l2_ops`
would rank against L2 distance and silently break results). The
`lexical_text` GIN trigram index ships in the same hand-written
migration block: `CREATE INDEX ... USING gin (lexical_text
gin_trgm_ops)`. Same opclass-not-in-DSL story; same indexed-
expression-must-match-query-expression rule as §1.2.

**Why this is no longer an upsert.** Earlier drafts had four
`create :record_at_*` actions each with `upsert? true` and a
scope-specific `upsert_identity`. That preserved today's
"re-`remember` overwrites" behavior, but it also broke the
plan's bitemporal claim — an Ash upsert on conflict UPDATEs the
existing row in place, mutating `content` and erasing what was
true before. There is no surviving record of the prior value
(no FactRevision sibling, no historical row) and a `valid_at`-
windowed read can no longer answer "what did we believe at time
T."

The rewrite uses **invalidate-and-replace** instead of upsert.
For a labeled write at scope `S` and source `Src`:

1. Inside the action's transaction, look up the current active
   row matching `(tenant_id, scope FK, label, source) AND
   invalid_at IS NULL`.
2. If found, set its `invalid_at = now()` and `expired_at =
   now()` (preserve `valid_at` — that's the world-time the
   superseded fact originally became true; overwriting it
   destroys the bitemporal axis). Do **not** delete or mutate
   `content`.
3. Insert the new row with fresh `valid_at` (defaults to `now()`)
   and `invalid_at = NULL`.
4. Optionally write a `:supersedes` Link from the new row to the
   invalidated one — useful for "show me the history of this
   label" queries.

Steps 2 and 3 happen in a single transaction, so concurrent writers
never observe two active rows or zero active rows for a label;
the partial unique identity is the safety net. For unlabeled
consolidator-promoted writes, step 1 finds nothing (there's no
label to match) and the content-hash identity guards against
duplicate content from a re-loaded cluster.

The `unique_active_label_per_scope_*` identity becomes a
*defense* against concurrent invalidate-and-replace racing —
two transactions both inserting after both finding "no active
row" in step 1 will collide on the partial unique constraint,
and Postgres rejects the loser. The loser's transaction rolls
back; Ash surfaces the conflict and the caller retries
(re-running step 1, which now sees the winner's row). This is
the same shape used by Letta's append-only fact model and by
several ledger-style designs.

Actions:

- `create :record` — single create action that takes
  `scope_kind` plus the populated scope FKs as inputs (the four
  per-scope actions in earlier drafts existed only to satisfy
  Ash's compile-time `upsert_identity` constraint; without
  upsert, a single action suffices). Wrapped in
  `transaction? true`. A `before_action` change validates that
  the FK matching `scope_kind` is populated (consistent with
  §3.2), populates ancestor FKs from `tool_context`, redacts
  `content` per §3.10, and — for labeled writes — runs the
  invalidate-of-prior-active step described above. The action
  does **not** null-out ancestor FKs.

  The same `before_action` enforces the §0.5.2 cross-tenant FK
  invariant: it fetches the parent row matching the populated
  scope FK (`Conversations.Session` for `:session`,
  `Projects.Project` for `:project`,
  `Workspaces.Workspace` for `:workspace`, `Accounts.User` for
  `:user`) and rejects the create with
  `:cross_tenant_fk_mismatch` when `parent.tenant_id !=
  changeset.tenant_id`. `tenant_id` comes from
  `tool_context.tenant_id`; the scope FKs come from the same
  `tool_context` for live writes but from caller arguments for
  programmatic uses (skill steps, script-driven backfill, the
  `Memory.remember_from_user/2` wrapper called from the CLI).
  A wrapper that constructs the changeset from a stale or
  spliced `tool_context` — a real failure mode if §0.5.1's
  category-(3) fix regresses — would otherwise land memory
  under whatever `tenant_id` the wrapper synthesised, even
  though the FKs point at a different tenant's workspace. The
  hook is the only thing that catches it before the row commits.

  When ancestor FKs are populated (`session_id` is set but
  `project_id`, `workspace_id`, `user_id` are also populated for
  read-precedence joins per §3.2), the hook validates against
  *every* populated FK, not just the matching one. Cheap (one
  indexed PK lookup per FK) and the fail-loud path is what we
  want when ancestors disagree with the leaf.
- The wrappers in 3.10 thread `scope_kind` through:
  ```elixir
  def remember_from_model(attrs, ctx) do
    Memory.Fact
    |> Ash.Changeset.for_create(:record, Map.merge(attrs, %{
        scope_kind: ctx.scope_kind,
        tenant_id: ctx.tenant_id,
        # scope FKs derived from ctx
        source: :model_remember,
        trust_score: 0.4
      }))
    |> Ash.create()
  end
  ```
  No per-scope action dispatch is needed.
- `create :import_legacy` — used by `mix jido_claw.migrate.memory`
  only. Accepts `inserted_at`, `valid_at`, **`label`**, and
  **`import_hash`** (the standard `:record` action doesn't take the
  last two as caller-set inputs); fixes `source: :imported_legacy`
  internally so callers don't have to. Like the `:import` action
  on `Conversations.Message`, this is the only action that can
  set historical timestamps; the writable-attribute approach in
  §3.6's attribute table is what makes that legal. `:import_legacy`
  bypasses the invalidate-of-prior step (every legacy row is
  treated as a fresh insertion), and the migrator deduplicates
  via the partial unique identity on `import_hash`
  (`unique_import_hash`, `WHERE import_hash IS NOT NULL`) — Ash's
  `upsert?: true` against that identity makes a re-run a no-op
  for already-imported rows. The earlier "check `Fact.exists?(id:
  legacy_uuid)`" approach is wrong: legacy `.jido/memory.json`
  entries are keyed by user-supplied strings (`"db_schema"`,
  `"preferred_style"`), not UUIDs, so there is no `legacy_uuid` to
  exist-check against (`record_to_entry/1` in
  `lib/jido_claw/platform/memory.ex:235-247` confirms the on-disk
  shape).

  The `before_action` cross-tenant FK validation from `:record`
  also runs here, against every populated scope FK. The
  `mix jido_claw.migrate.memory` script (§3.17) reads
  `tenant_id` from the resolved `Workspace.tenant_id` directly,
  so the legacy import path is structurally aligned, but the
  hook is mandatory belt-and-braces — a future migrator that
  layers in cross-workspace heuristics could otherwise quietly
  mis-tenant a row, and `:imported_legacy` rows feed the
  consolidator (§3.15 step 2 explicitly includes the source),
  so a mistenanted legacy fact would propagate into
  consolidator-promoted facts on the first run.
- `read :search` (hybrid as in Phase 1).
- `update :promote` — only callable by the consolidator; bumps
  `trust_score` and adjusts `source`.
- `read :for_consolidator` — since-watermark, scope-filtered.
- The two invalidate actions:

- `update :invalidate_by_id` — callable with a Fact `id`. Sets
  `invalid_at`/`expired_at`. Targets a single row, no ambiguity.
- `update :invalidate_by_label` — callable with `(tenant_id,
  label, scope, source)`. Sets `invalid_at`/`expired_at`. The
  `source` argument is required because the
  `unique_active_label_per_scope_*` identities each include
  `source` — a model-source and user-source fact can both be
  active under the same label in the same scope, so `(label,
  scope)` alone is not unique.

`(label, scope)` *without* a source argument intentionally has no
backing action: there's no defensible default policy ("all
sources" silently double-invalidates; "user wins" silently leaves
model rows; "model wins" surprises the user). Callers either know
the source (programmatic uses, the consolidator) or pass through
the CLI's interactive prompt (see 3.12).

### 3.7 `Memory.Episode` — immutable provenance

| Attribute | Type | Notes |
|---|---|---|
| `id`, scope cols | scope cols only — bitemporal not used (episodes are events, not facts) | |
| `kind` | atom (`:chat_message`, `:chat_run`, `:tool_result`, `:user_input`, `:system_event`, `:document_ingested`) | |
| `source_message_id` | uuid (FK Conversations.Message), nullable | for chat-derived |
| `source_solution_id` | uuid (FK Solutions.Solution), nullable | for solution-derived |
| `content` | text | snapshot at the time. Redacted at write per §3.10 — Episodes carry transcript fragments and tool output, both of which can contain secrets that the original writer (`Conversations.Message.:append`) already redacted; passing through `Redaction.Transcript.redact/1` here is the idempotent no-op for already-redacted strings (§1.4) and the only line of defense for anything that bypassed message-time redaction (e.g., a `:document_ingested` episode sourced from outside the chat path). |
| `metadata` | map | tool name, document path, etc. |
| `inserted_at` | utc_datetime_usec | |

No updates, no destroys (other than soft-delete via the platform's
retention policy in Phase 4). Every Fact created by the consolidator
links back to one or more Episodes via `Memory.FactEpisode`.

Actions:

- `create :record` — used by every Episode source: the §2.3
  Recorder for `:chat_message`/`:tool_result` episodes, the
  §1.5 NetworkFacade for `:document_ingested` episodes (when
  `Solutions.Solution`s arrive over the network), and ad-hoc
  `:system_event` writes from the consolidator and shell-tool
  paths. Accepts `kind`, `scope_kind`, the populated scope FKs,
  `tenant_id`, `source_message_id`, `source_solution_id`,
  `content`, and `metadata`. A `before_action` enforces:
  - **§3.2 scope-FK invariant** — the FK matching `scope_kind`
    is populated.
  - **§0.5.2 cross-tenant FK invariant** — for every populated
    scope FK and for `source_message_id` / `source_solution_id`
    (when set), the parent row's `tenant_id` equals
    `changeset.tenant_id`. This validation is mandatory because
    Episodes feed `FactEpisode` joins (§3.7.1) and the
    consolidator's clustering reads (§3.15 step 3); a
    mistenanted Episode would propagate into clustered inputs
    that the harness sees, and the harness's resulting
    proposals would land under the wrong tenant. The
    `source_message_id` validation is the load-bearing case:
    it's the one cross-resource pointer that's both nullable
    and routinely populated, so a bug in the Recorder's
    `tool_context` resolution would otherwise silently widen
    the tenant boundary.
  - **§3.10 redaction** — `content` runs through
    `Redaction.Transcript.redact/1` before commit. Idempotent
    against already-redacted strings.
- `read :for_consolidator` — since-watermark, scope-filtered
  reads matching the §3.15 step 2 input load shape. Internal
  use only; not exposed to the model or CLI.
- `read :for_fact` — joins through `FactEpisode` to surface
  the originating Episodes for a Fact id. Used by `/memory
  why <fact_id>` (§3.12) for provenance display.

Indexes: `(tenant_id, scope_kind, inserted_at)` btree —
the consolidator's load query orders by this. `(tenant_id,
source_message_id)` partial (`WHERE source_message_id IS NOT
NULL`) — joins from a transcript message to its derived
Episode. `(tenant_id, source_solution_id)` partial
(`WHERE source_solution_id IS NOT NULL`) — same shape for the
Solutions side. The partial indexes need
`postgres.identity_wheres_to_sql` entries per the cross-cutting
"partial identities" note.

### 3.7.1 `Memory.FactEpisode` — fact ↔ episode join

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `fact_id` | uuid (FK Fact) | |
| `episode_id` | uuid (FK Episode) | |
| `tenant_id` | text | denormalized from `fact_id` by a `before_action` and validated to equal `episode.tenant_id` in the same hook. Required for Phase 4 tenant policies and for the cross-tenant rejection invariant: a join row that pointed at facts/episodes in different tenants would be a confused-deputy footgun even if neither side's read path returned the row directly. |
| `role` | atom (`:primary`, `:supporting`, `:contradicting`) | how this episode relates to the fact |
| `inserted_at` | utc_datetime_usec | |

Identities: `unique_pair` on `[fact_id, episode_id]`. Indexes:
`(fact_id)`, `(episode_id)`, `(tenant_id, fact_id)` (matches the
tenant-scoped retrieval shape). Append-only; consolidation that
supersedes a fact (3.15 step 4) writes new FactEpisode rows on the
replacement fact rather than mutating existing rows.

### 3.8 `Memory.Link` — graph edge

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `from_fact_id`, `to_fact_id` | uuid (FK Fact) | |
| `tenant_id` | text | denormalized from `from_fact_id` by a `before_action`. The hook fetches both fact rows and **rejects the create** when `from.tenant_id != to.tenant_id`. Cross-tenant graph edges are not a supported operation — they would let a recursive-CTE traversal walk from a fact in tenant A into facts in tenant B, leaking memory across the §0.5.2 outer boundary. The reason is captured in the action error so the consolidator (the only legitimate writer) surfaces a clear failure mode rather than silently dropping the link. |
| `scope_kind` | atom | denormalized from `from_fact_id`. The same hook also rejects the create when `from.scope_kind != to.scope_kind` or when the scope FKs of the matching kind differ. Cross-scope links would break the §3.13 scope-chain retrieval invariant: a recursive CTE traversing links from a session-scoped fact could surface workspace- or user-scoped facts that the read precedence chain would otherwise dedup or hide. If a cross-scope relationship is ever needed (e.g., "this session-scoped fact elaborates a workspace-scoped fact"), it should be encoded as two facts with a `:supersedes` chain, not a Link. |
| `relation` | atom (`:related`, `:supports`, `:contradicts`, `:supersedes`, `:elaborates`) | |
| `reason` | text | harness-supplied rationale (A-Mem style) |
| `confidence` | float, default 0.5 | harness-supplied 0..1 |
| `inserted_at` | utc_datetime_usec | |

Indexes: `(tenant_id, from_fact_id, relation)`,
`(tenant_id, to_fact_id, relation)` — leading `tenant_id` matches
the §0.5.2 prepare-query injection so the planner never has to
consider cross-tenant rows. Graph traversal in pure SQL via
recursive CTEs — no separate graph DB. Recursive CTE callers
**must** include the `tenant_id = $tenant` predicate on every
hop; the action-level cross-tenant rejection enforces it at write
time, but read-time queries that omit the filter would surface
nothing today (the indexes already filter) yet become a leak
vector if a future migration loosened the write-time check.

### 3.9 `Memory.ConsolidationRun` — watermark + audit

Tracks consolidator runs per scope:

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `scope_kind`, scope FKs | (as above) | |
| `started_at`, `finished_at` | utc_datetime_usec | |
| `messages_processed_until_at` | utc_datetime_usec, nullable | `inserted_at` half of the message-stream watermark — max over `Conversations.Message` rows actually **published** by this run (see 3.15 step 7). Null on failure or when no messages were published. |
| `messages_processed_until_id` | uuid, nullable | `id` half of the message-stream watermark, used as a tiebreaker because millisecond `inserted_at` collisions are common. Always populated when `_at` is. |
| `facts_processed_until_at` | utc_datetime_usec, nullable | `inserted_at` half of the fact-stream watermark — max over input `Memory.Fact` rows (sources `:model_remember`, `:user_save`, `:imported_legacy`) actually **published** by this run. Null on failure or when no qualifying facts were published. |
| `facts_processed_until_id` | uuid, nullable | `id` half of the fact-stream watermark; same role as messages. |
| `messages_processed`, `facts_processed` | integer | |
| `blocks_written`, `blocks_revised`, `facts_added`, `facts_invalidated`, `links_added` | integer | |
| `status` | atom (`:running`, `:succeeded`, `:failed`, `:partial`, `:skipped`) | `:skipped` is written by §3.15 step 0 when the per-scope advisory lock is held by another worker, and by the §3.15 step 2 pre-flight gate when fewer than `min_input_count` inputs are loaded — recording the attempt in the run table (rather than dropping it silently) gives operators visibility into how often scopes race each other and how often a scheduled tick had nothing to do. |
| `error` | text, nullable | on failure; also carries skip reasons (`:insufficient_inputs`, `:no_credentials`, etc.) for `:skipped` and `:failed` statuses so operators don't need to cross-reference logs to diagnose a quiet consolidator |
| `forge_session_id` | uuid (FK `JidoClaw.Forge.Resources.Session`), nullable | populated for every run that reached §3.15 step 4 (harness invocation), even on failure. Lets operators pull the harness transcript via existing Forge persistence to debug "why did the consolidator decide to invalidate that fact?" — without this, harness output is opaque. Null for runs that skipped at step 0 (lock contention) or step 2 (pre-flight gate) before invoking the harness. |
| `harness` | atom (`:claude_code`, `:codex`), nullable | which harness was used. Null for skipped runs. Captured per-run rather than read from config because the operative knob may have changed between runs. |
| `harness_model` | text, nullable | concrete model identifier (e.g. `"claude-opus-4-7"`) the harness ran. Null for skipped runs. |

Acts as the watermark source — "the last successful run published
messages up through the message watermark and input facts up
through the fact watermark, so consolidate everything strictly
after each respective `(inserted_at, id)` pair."

**Why two watermarks rather than one.** Earlier drafts used a single
`processed_until` defined as `max(message.inserted_at)`, but the
input query in 3.15 step 2 also loads facts (model/user/imported
writes since the prior run). One watermark across two streams
breaks in two ways: (1) a run with new facts but no new messages
would never advance the watermark — the same facts would be
reprocessed every cadence forever; (2) when `max(fact.inserted_at)
> max(message.inserted_at)`, the next run's `inserted_at >
watermark` clause re-pulls those facts. Splitting the watermark per
stream gives each its own lower bound and removes both bugs.

**Why composite `(inserted_at, id)` rather than `inserted_at`
alone.** Live transcripts under bursty traffic produce ties on
`inserted_at` at millisecond resolution
(`platform/session/worker.ex:93`). With a timestamp-only watermark,
two messages stamped at the same millisecond either both get
re-loaded or one gets silently dropped depending on the comparison
operator. Recording the row `id` alongside the timestamp gives a
total order. Comparisons at load time are
`(inserted_at, id) > (watermark_at, watermark_id)` lexicographically.

**Why "contiguous published prefix" rather than "loaded max" or
"published max."** Cost-control caps in 3.15 (max-cluster cap,
harness deferral, max_turns, timeout) mean that not every loaded
row gets through the run. "Loaded max"
would skip deferred rows entirely. "Published max" still skips
deferred rows whenever clusters span non-contiguous indices: a
published cluster `[1, 4]` and a deferred cluster `[2, 3]` would
advance the watermark past 2 and 3 forever. Advancing only to the
last `(inserted_at, id)` such that every earlier loaded row was
published makes the watermark *monotonic and gap-free*. The cost
is that some published rows may be re-loaded on the next run; the
unique active-label and active-promoted-content identities (§3.6)
plus the idempotent staging make that a no-op (see 3.15 step 7
for the worked example) — for labeled writes the partial unique
identity rejects the duplicate insert; for unlabeled
consolidator-promoted writes the content-hash identity does the
same.

Watermarks are intentionally **not** the same as `finished_at`:
a row inserted between a run's load query and its `finished_at`
would have an `inserted_at` older than that `finished_at`, so using
`finished_at` as the next lower bound would silently skip those
rows forever. Recording the actual max-published `(inserted_at, id)`
per stream closes that race.

Actions:

- `create :record_run` — the worker's per-run write at §3.15
  step 7 (succeeded), step -1/0/2 (skipped), or post-failure
  (failed). Accepts the full attribute set above. A
  `before_action` enforces (a) the §3.2 scope-FK invariant —
  the FK matching `scope_kind` is populated; (b) the §0.5.2
  cross-tenant FK invariant against every populated scope FK.
  The `forge_session_id` FK is **not** validated against a
  parent `tenant_id` in Phase 3 because
  `JidoClaw.Forge.Resources.Session` (a pre-existing resource —
  `lib/jido_claw/forge/resources/session.ex`) does not carry a
  `tenant_id` column today. This is documented as a Phase-3
  prerequisite (see "Pre-existing cleanup debt" — Forge.Session
  tenant column) and is added to the §Pre-existing cleanup
  debt list rather than buried inside this section so the work
  is visible at sweep time. Until Forge.Session is tenanted,
  the consolidator's harness-session provenance is pinned by
  the row's own scope FKs (which *are* tenant-validated), and
  the §3.15 step 4 session-spawn path resolves Forge runner
  context from the same tenant the consolidator is running
  under — so a *correct* implementation produces aligned
  tenants even without the validation gate. The gate is what
  makes a *buggy* implementation surface; calling it out as
  prerequisite work avoids quietly shipping a half-defense.
- `read :latest_for_scope` — `(tenant_id, scope_kind, scope FK)`
  → most recent succeeded run's watermarks. Used by §3.15 step
  1 to load watermarks at the start of a run. Filters
  `status = :succeeded` because skipped/failed runs have null
  watermarks.
- `read :history_for_scope` — full run history per scope,
  ordered by `started_at DESC`, surfaced by `/memory status`
  (§3.12).

No `update`, no `destroy` — runs are append-only. A failed run
plus a subsequent succeeded run are two rows, not an update;
operators reading the history see both, which is the correct
audit record.

Indexes: `(tenant_id, scope_kind, scope_id, started_at DESC)`
btree — matches `:latest_for_scope` and `:history_for_scope`,
where `scope_id` is the populated FK column for the row's
`scope_kind`. The §0.5.2 leading `tenant_id` shape applies
here too. `(tenant_id, status, started_at)` btree for
operator dashboards filtering on succeeded vs. failed vs.
skipped runs across a tenant. `(forge_session_id)` partial
(`WHERE forge_session_id IS NOT NULL`) — joins from a Forge
session to its provenance run; partial to keep the index
small (skipped runs lack a session).

### 3.10 Write paths

Three sources, each with different routing:

| Source | Tier | Action | Trust seed |
|---|---|---|---|
| Model via `remember` tool | Fact | `create :record` with `source: :model_remember` | 0.4 |
| User via `/memory save` | Fact | `create :record` with `source: :user_save` | 0.7 |
| Consolidator (scheduled) | **Block** + Fact updates + Links | `create :record` (Fact, `source: :consolidator_promoted`) + Block CRUD | 0.85 |

Today both the `remember` tool and the `/memory save` CLI command
funnel through a single function — `JidoClaw.Memory.remember/3`
(`lib/jido_claw/platform/memory.ex:37`) — with no caller
distinction. The new code path replaces that with two explicit
entry points so source is captured at the call site:

- `Memory.remember_from_model/2(attrs, tool_context)` — used by
  `JidoClaw.Tools.Remember`; sets `source: :model_remember` and
  `trust_score: 0.4`.
- `Memory.remember_from_user/2(attrs, tool_context)` — used by the
  `/memory save` REPL command; sets `source: :user_save` and
  `trust_score: 0.7`.

Both resolve scope from `tool_context` and call the single
`Memory.Fact.create :record` action threading `scope_kind`
through. The action's `before_action` chain — redact, validate
scope, populate ancestors, invalidate prior labeled active row,
insert — runs inside one transaction. Re-`remember` of the same
`key`/`label` no longer upserts; it invalidates the prior active
row (preserving its `valid_at` for bitemporal time-travel queries)
and inserts a fresh one. The label uniqueness identity
(§3.6) prevents two writers from racing this in.

**Write-time redaction.** Every create on `Memory.Fact` and
`Memory.Block` runs `JidoClaw.Security.Redaction.Memory.redact/1`
on `content` (and on `value` for Blocks) before persistence. The
redactor wraps the binary patterns from §2.4 (`Patterns.redact/1`
plus URL-userinfo) and additionally scrubs known sensitive keys
in `metadata` jsonb. This closes the secret-persistence gap
that `remember` and `/memory save` would otherwise open — those
paths take content from the model/user verbatim, so any string
that would have leaked through to JSONL today would also leak
into Postgres without the gate. Idempotent (re-redacting already-
redacted content is a no-op), so the consolidator's promotion
flow doesn't double-redact across runs.

The model never writes Blocks directly. The Letta lesson: keeping
write privileges scoped reduces cross-source confusion. Model and
user writes land in the searchable tier where the consolidator can
review them on its next run.

`/memory blocks` (CLI) lets the user *list* and *manually edit* blocks
as a power-user escape hatch — but those edits are recorded as Block
revisions with `source: :user`, so the consolidator can see them on
the next run and decide whether to keep, revise, or surface a
contradiction.

### 3.11 Tool API (model-facing)

| Tool | Action | Notes |
|---|---|---|
| `remember` | Existing API preserved (key/content/type) | Internal mapping: `key` → `Fact.label`, `content` → `Fact.content`, `type` → `Fact.tags`. Calls `Memory.remember_from_model/2`. Re-`remember` of the same `key` invalidates the prior `(label, scope, source: :model_remember)` row (sets its `invalid_at`/`expired_at`, preserves `valid_at`) and inserts a fresh active row in the same transaction — preserves today's "latest write wins on read" contract from `JidoClaw.Memory.remember/3` while keeping prior values queryable for bitemporal time-travel reads. |
| `recall` | Existing API preserved (query/limit) | Hybrid retrieval against Fact tier with auto-resolved scope from `tool_context`. |
| `forget` | New | Soft-invalidate via `Fact.invalidate_by_id/1` (preferred — no ambiguity) or `Fact.invalidate_by_label/1`. The label form scopes to **the model's own writes** (`source: :model_remember`) only — a model invoking `forget("api_key")` should not be able to delete the user's `:user_save` row sharing the same label. The CLI command (3.12) handles user-facing label invalidation with explicit source resolution. |

The `remember` schema doesn't change — it's the stored type that
shifts to Fact. Existing prompt instructions don't need to be
rewritten for v0.6.0 → v0.6.3.

### 3.12 CLI API (user-facing)

| Command | Purpose |
|---|---|
| `/memory blocks` | List Blocks for current scope |
| `/memory blocks edit <label>` | Open editor on block value |
| `/memory list` | Recent Facts (preserved) |
| `/memory search <q>` | Hybrid search (preserved, now FTS+vector) |
| `/memory save <label> <content>` | User-write to Fact (preserved) |
| `/memory forget <label> [--source model\|user\|all]` | Soft-invalidate. `--source` defaults to `user` (matches today's intuition: `/memory save` is the inverse of `/memory forget`). When multiple active facts share the label across sources in the current scope chain and no `--source` was passed, the CLI lists them and prompts for selection rather than guessing. `forget --source all <label>` invalidates every active fact at that label/scope across sources. |
| `/memory consolidate` | Trigger consolidator for current scope (new, debugging aid) |
| `/memory status` | Last consolidation run, counts per tier (new) |

### 3.13 Retrieval API

`JidoClaw.Memory.Retrieval` is the single entry point.

```elixir
Retrieval.search(
  query,
  scope: tool_context,
  tier: [:block, :fact, :episode],   # any subset
  limit: 20,
  threshold: 0.3,
  as_of_world: nil,                  # world-time travel
  as_of_system: nil,                 # system-time travel (knowledge-as-of)
  filters: [tags: ["api"], source: :user_save]
)
```

Implementation:
- Block tier: skip search, return all current Blocks for the scope
  chain (merged by precedence, deduped by label).
- Fact tier: hybrid SQL against the scope chain, blending FTS,
  cosine ANN, and the lexical/trigram pool via three-way RRF —
  same shape as Solutions §1.5 (`fts_pool` + `ann_pool` +
  `lexical_pool`). The lexical pool filters
  `lexical_text LIKE '%' || $escaped || '%' ESCAPE '\'` against
  the GIN trigram index on Memory.Fact's `lexical_text` generated
  column (§3.6); `$escaped` is the query text run through
  `JidoClaw.Solutions.SearchEscape.escape_like/1` (§1.5) before
  the SQL, so user input can't inject LIKE wildcards. This
  preserves today's `JidoClaw.Memory.recall/2` substring contract
  (`String.contains?(text)`, `String.contains?(key)`,
  `String.contains?(kind)`) — a query of `"api"` against a Fact
  labeled `"api_base_url"` matches because the indexed substring
  search sees the lower-cased concatenation, even though Postgres
  FTS tokenizes via stemming and would miss it.

  **Bitemporal predicate matrix.** §3.3 declares two independent
  axes — *world time* (`valid_at`/`invalid_at`: when a fact was
  true in the world) and *system time*
  (`inserted_at`/`expired_at`: when we knew about that truth).
  `Retrieval.search` exposes both axes; the predicate applied
  to every pool depends on which arguments the caller passed:

  | Mode | Caller args | Predicate per pool |
  |---|---|---|
  | **Current truth** (default) | neither | `valid_at <= now() AND (invalid_at IS NULL OR invalid_at > now()) AND expired_at IS NULL` — current world *and* current system. The `expired_at IS NULL` clause is a hot-path shortcut equivalent to "we haven't decided this is expired yet" in current system time, fast under index. |
  | **World time-travel** | `as_of_world: T_w` | `valid_at <= T_w AND (invalid_at IS NULL OR invalid_at > T_w)` — what was *true in the world* at world-time `T_w`, according to **current** system knowledge. The `expired_at IS NULL` clause is **dropped** because a fact that was valid at T_w but later superseded must still surface; including it would hide every historically-valid-but-since-corrected fact, exactly the case world-time-travel is for. |
  | **System time-travel** | `as_of_system: T_s` | `inserted_at <= T_s AND (expired_at IS NULL OR expired_at > T_s)` — what we *knew* at system-time `T_s`, evaluated against current world predicates. Default world clauses (`valid_at <= now() AND (invalid_at IS NULL OR invalid_at > now())`) still apply unless the caller also passed `as_of_world`. |
  | **Full bitemporal** | both `as_of_world: T_w` and `as_of_system: T_s` | Both axes applied independently: `valid_at <= T_w AND (invalid_at IS NULL OR invalid_at > T_w) AND inserted_at <= T_s AND (expired_at IS NULL OR expired_at > T_s)` — "what we believed at system-time T_s about world-time T_w". |

  Crucial invariant: `expired_at IS NULL` is a **system-time**
  filter, not a soft-delete gate. The earlier draft applied it
  unconditionally in every pool, which was correct for current
  reads (the hot path) and silently wrong for world-time travel
  — a fact that became `invalid` after T_w would be excluded
  even though it was valid at T_w. The matrix above moves the
  `expired_at` clause behind the system-time mode rather than
  conflating it with "is the row deleted". Memory has no
  separate soft-delete column; rows are never destroyed, only
  invalidated bitemporally.

  The §3.3 column glossary is updated alongside this section to
  call out that `expired_at` is the system-time partner of
  `invalid_at`, not a `deleted_at`-equivalent — naming alone
  was load-bearing in the earlier confusion.
- Episode tier: FTS + lexical (no cosine — Episodes are immutable
  and rarely embedded).
- Returns a unified result list with a `tier` field and a normalized
  `score`.

**Precedence: scope > source, applied inside the SQL before the
outer LIMIT.** Two precedence axes are in play:

1. **Scope precedence** (§3.2): `:session > :project > :workspace
   > :user`. Closer scope wins; a session-scoped Fact with label
   `"api_url"` shadows a workspace-scoped Fact with the same
   label. Cross-scope groups must dedup against each other —
   the same label appearing in `:session` and `:workspace` for
   the same caller is the headline collision case.
2. **Source precedence** (§3.6 Fact identity): within a single
   `(scope_kind, scope_id, label)` group, **`:user_save` >
   `:consolidator_promoted` > `:imported_legacy` >
   `:model_remember`**. The user explicitly saying it wins;
   reviewed cross-turn consensus beats a single in-the-moment
   model claim; legacy data outranks fresh model claims
   post-migration so a curated v0.5 fact isn't shadowed on the
   first turn.

Both axes must be applied **inside the SQL, before the outer
`LIMIT $5`** — an Elixir-side pass after the SQL returns sees
only the top-N candidates by RRF rank, and the higher-precedence
row may not be in that top-N if its label appears with a worse
match. The earlier draft applied this dedup post-LIMIT and was
quietly wrong: a `:user_save` Fact with a poor RRF score could
be excluded by the candidate cap while a `:model_remember` Fact
with the same label survived. The same hazard applies to scope
— a session-scoped row losing the candidate cap to a
workspace-scoped row inverts the intended precedence.

The implementation runs a single window-function pass that
folds both axes together. After the three RRF pools return
ranked candidates (overfetched to `LIMIT 100` per pool, well
above any practical outer LIMIT), an outer CTE assigns
`ROW_NUMBER()` partitioned by the *content-key* and ordered by
the *precedence-key*:

```sql
-- ... existing fts/ann/lexical pools and rrf merge ...
merged AS (
  SELECT f.*,
         1.0 / (60 + COALESCE(fts.r_fts, 1000)) +
         1.0 / (60 + COALESCE(ann.r_ann, 1000)) +
         1.0 / (60 + COALESCE(lexical.r_lex, 1000)) AS rrf
  FROM memory_facts f
  LEFT JOIN fts ON fts.id = f.id
  LEFT JOIN ann ON ann.id = f.id
  LEFT JOIN lexical ON lexical.id = f.id
  WHERE (fts.id IS NOT NULL OR ann.id IS NOT NULL OR lexical.id IS NOT NULL)
    AND f.tenant_id = $9
    AND f.valid_at <= $now
    AND (f.invalid_at IS NULL OR f.invalid_at > $now)
),
deduped AS (
  SELECT *,
         ROW_NUMBER() OVER (
           PARTITION BY
             CASE
               WHEN label IS NOT NULL THEN
                 -- labeled facts dedup across scope-and-source axes
                 'L:' || label
               ELSE
                 -- unlabeled (consolidator-promoted) facts dedup by
                 -- content_hash within (scope_kind, scope_id) only;
                 -- the partition key includes the scope so
                 -- cross-scope unlabeled facts with byte-identical
                 -- content survive (a different decision than the
                 -- labeled case — different scopes are different
                 -- "places" the consolidator may legitimately have
                 -- promoted the same content)
                 'C:' || scope_kind::text || ':' || COALESCE(
                   session_id::text, project_id::text,
                   workspace_id::text, user_id::text
                 ) || ':' || encode(content_hash, 'hex')
             END
           ORDER BY
             -- 1. closer scope wins
             CASE scope_kind
               WHEN 'session' THEN 1
               WHEN 'project' THEN 2
               WHEN 'workspace' THEN 3
               WHEN 'user' THEN 4
             END ASC,
             -- 2. higher-trust source wins
             CASE source
               WHEN 'user_save' THEN 1
               WHEN 'consolidator_promoted' THEN 2
               WHEN 'imported_legacy' THEN 3
               WHEN 'model_remember' THEN 4
             END ASC,
             -- 3. tie-break on relevance
             rrf DESC,
             -- 4. final tie-break: youngest valid_at wins, then
             --    biggest id (deterministic across replicas)
             valid_at DESC,
             id DESC
         ) AS prec_rank
  FROM merged
)
SELECT *
FROM deduped
WHERE prec_rank = 1
ORDER BY rrf DESC
LIMIT $5;
```

Three properties this gives that the post-LIMIT pass did not:

- **Scope precedence is enforced.** A session-scoped
  `"api_url"` and a workspace-scoped `"api_url"` partition into
  the same `'L:api_url'` group; only the session-scoped row
  survives `prec_rank = 1`. The workspace-scoped row's id is
  available for the `metadata.shadowed_by[]` projection (the
  caller can opt back into seeing shadowed rows via
  `dedup: :none`, see below).
- **Source precedence holds even at the candidate-pool edge.**
  A `:user_save` row with rank 87 in the RRF candidate set wins
  over a `:model_remember` row with rank 3 in the same partition,
  because the partition's `prec_rank = 1` is decided by source
  before RRF score. The pool overfetch (`LIMIT 100` per pool) is
  what lets the right row reach the dedup pass; a future
  performance pass can tune that bound, but it must stay well
  above the outer LIMIT.
- **Unlabeled consolidator-promoted Facts dedup correctly.**
  Two consolidator runs in the same scope can produce the same
  `content_hash` (the §3.6 partial unique identity already
  prevents two active rows with that hash within a scope, so
  this only matters across system-time replays); the partition
  key `'C:scope_kind:scope_id:hash'` collapses them into one
  visible row. Different scopes legitimately keep separate
  copies — promoting the same content under `:workspace` and
  `:user` is a meaningful distinction the dedup respects.

`Retrieval.search` exposes:
- `dedup: :by_precedence` (default) — runs the
  `prec_rank = 1` filter shown above.
- `dedup: :none` — drops the `WHERE prec_rank = 1` clause and
  returns every label/content match. Used by the §3.12
  `/memory forget` interactive prompt and by audit/debug
  surfaces.
- `filters: [source: ...]` — when the caller scopes to a single
  source, the source-precedence axis collapses to one value and
  the dedup degenerates to scope precedence only; behavior is
  unchanged but the optimizer drops the `CASE source` ordering.

The Elixir side after the SQL returns is responsible only for
projection (decorating each surviving row with the shadowed-row
ids from `merged` for `metadata.shadowed_by[]`, when the caller
asked for it). The dedup decision itself is in Postgres so it
composes with the LIMIT correctly.

`Retrieval.search` for Solutions §1.5 does not use this dedup —
Solutions are keyed by `problem_signature`, not by user-facing
label, and contradictory active rows are handled by trust-score
ranking rather than precedence. Memory's contract is different
because labels are user-/model-visible identifiers (`recall
"api_url"`) where "the answer" is singular.

Rationale for the order:

- `:user_save` wins because the user explicitly said it; nothing
  else should override that. `/memory forget`'s default of
  `--source user` (§3.12) reflects the same authority.
- `:consolidator_promoted` outranks legacy and model-remember
  because it represents reviewed cross-turn consensus, not a
  single in-the-moment claim.
- `:imported_legacy` outranks `:model_remember` so a v0.5 fact a
  user had explicitly saved (or curated through prior `forget`
  cycles) doesn't get shadowed by a fresh `remember` from the
  model on the first post-migration turn.
- `:model_remember` is the lowest-precedence source — model self-
  claims from a single turn are the cheapest evidence and the
  most likely to be wrong.

### 3.14 Frozen-snapshot system prompt

Today: `Prompt.build/1` runs on every turn and includes a fresh
`Memory.list_recent(20)`. Cache-busting.

New (`prompt.ex` rewrite):

1. On `Conversations.Session` start (or first message), build a
   **system-prompt snapshot** that includes:
   - Static base prompt body.
   - Skills, environment, JIDO.md (rebuilt with `git_branch` cached
     for the session).
   - **Block tier rendered for the scope chain** (Block contents
     joined with separators, per-scope precedence applied).
2. Cache the snapshot in `Conversations.Session.metadata.prompt_snapshot`
   (or a sidecar table if size becomes an issue).
3. Mid-session, Block writes update Block rows immediately but **do not
   invalidate the snapshot** — the model only sees Block updates via
   the tool response, until the next session.
4. `agent_count` and other volatile values are removed from the static
   prefix and surfaced via tools instead — eliminates the obvious
   cache-busters.

Result: `anthropic_prompt_cache: true` actually fires both intra-turn
(within a single ReAct run, ~10x savings on iterations 2..N) and
inter-turn (across multiple turns of the same session, when no Block
writes have evicted the cache via TTL).

### 3.15 Consolidator design

`JidoClaw.Memory.Consolidator` runs on a schedule per scope. Each
run invokes a **frontier-model coding harness** (Claude Code or
Codex) as a Forge session, gives it a scoped tool surface for
proposing memory mutations, and commits the proposals
transactionally. The harness — not a bare LLM API call — is the
unit of work for steps 3–6 below; this is the right reasoning
substrate for ADD/UPDATE/DELETE/NOOP judgments and lets the
consolidator interleave Fact, Block, and Link decisions in one
session instead of three serialised passes.

**Scheduling.** Extends the existing `JidoClaw.Cron.Scheduler`
infrastructure (`lib/jido_claw/platform/cron/scheduler.ex`). A
new `JidoClaw.Cron.Scheduler.start_system_jobs/0` is called at
app boot to register the consolidator as a system-level cron job
(distinct from user-defined `.jido/cron.yaml` jobs); it iterates
all known tenants/scopes per tick. Configured via
`config/config.exs`:

```elixir
config :jido_claw, JidoClaw.Memory.Consolidator,
  enabled: true,                      # consolidator runs by default
  cadence: "0 */6 * * *",             # every 6 hours
  min_input_count: 10,                # skip the run when fewer than 10 staged inputs
                                      # exist for a scope (cheap pre-check before
                                      # acquiring the advisory lock; many scheduled
                                      # ticks will no-op on quiet scopes)
  max_concurrent_scopes: 4,           # bound on simultaneous Forge sessions
  harness: :claude_code,              # :claude_code | :codex
  harness_options: [
    model: "claude-opus-4-7",
    thinking_effort: "xhigh",         # high reasoning effort for consolidation
    sandbox_mode: :local,             # :local skips Docker; the consolidator runs
                                      # against our own Postgres and proposes memory
                                      # writes — no untrusted code execution, so the
                                      # Docker isolation Forge defaults to is overhead
                                      # without security benefit here
    timeout_ms: 600_000,              # 10 min hard cap per scope
    max_turns: 60                     # tool-call turns the harness may take per run;
                                      # belt-and-braces with timeout_ms
  ]
```

The `harness` knob switches between
`JidoClaw.Forge.Runners.ClaudeCode` (already present) and a new
sibling `JidoClaw.Forge.Runners.Codex`. Both runners receive the
same prompt and tool surface; the consolidator code is
runner-agnostic.

**Why frontier-via-harness.** Consolidation is a reasoning-heavy
task: deciding whether a cluster of episodes merits a new Fact, an
update to an existing Fact, or no change at all is genuinely hard
and pays off compounded over the lifetime of the memory store. A
consolidator running every 6 hours that occasionally has nothing
to do is fine; a consolidator that introduces noisy or wrong Facts
corrupts long-term memory. The cost calculus favours the most
capable model available, run infrequently, behind a `min_input_count`
gate so we don't fire an expensive run for one staged episode.

**Auth surface.** Claude Code runs against the host's
`~/.claude/` credentials; the existing `sync_host_claude_config/1`
in `JidoClaw.Forge.Runners.ClaudeCode` handles this. Codex needs
an equivalent `sync_host_codex_config/1` shape against
`~/.codex/`. If credentials are missing at boot, the consolidator
logs a warning and remains scheduled but every run writes
`status: :failed, error: :no_credentials` rather than silently
no-op'ing — the latter would leave operators wondering why memory
isn't consolidating.

**Per-run flow** (one scope, one run):

-1. **Per-scope `consolidation_policy` egress gate.** Before
   anything else — before the lock, before loading watermarks,
   before any DB read of facts/messages — the worker resolves
   the owning workspace's `consolidation_policy` (§0.2) for this
   scope:
   - `:session`, `:project`, `:workspace` → the policy of the
     directly-pointed-to workspace (joining through `Session →
     Workspace` and `Project → Workspace` as needed).
   - `:user` → the **most-restrictive** policy across every
     workspace under that user (`MIN` over the policy ordering
     `:disabled < :local_only < :default`). One opted-out
     workspace blocks user-scope consolidation. Implemented as a
     single aggregate query, not a workspace-by-workspace loop.

   If the resolved policy is `:disabled`, the worker writes a
   `ConsolidationRun` with `status: :skipped, error:
   :consolidation_disabled` (or no row at all, behind a config
   flag — same shape as the lock-skip and pre-flight-skip paths
   in steps 0 and 2 to keep operator dashboards consistent) and
   exits without taking the lock. If the policy is `:local_only`
   and the local-runner branch isn't yet implemented, the worker
   writes `status: :skipped, error:
   :consolidation_local_runner_unavailable`. Only when the
   resolved policy is `:default` does the run proceed to step 0.

   This step runs **before** the lock acquisition because there's
   no point pinning a connection or contending on the advisory
   lock for a scope whose owner has opted out — and pulling the
   gate forward is the only design that guarantees a misconfigured
   `enabled: true` consolidator can never load a transcript row
   from an opted-out workspace into worker memory, even
   transiently. `:cluster_window`-style telemetry would otherwise
   show "loaded N rows, skipped at policy gate" — that load
   itself is the leak we're preventing.

0. **Acquire a per-scope advisory lock under a pinned
   connection.** Before loading any inputs, the worker enters
   `JidoClaw.Repo.checkout/2`, then calls
   `SELECT pg_try_advisory_lock(scope_lock_key)` (note: session-
   level lock, *not* xact) where `scope_lock_key` is a
   deterministic
   `:erlang.phash2({:memory_consolidator, tenant_id, scope_kind,
   scope_fk_id})` masked to a `bigint`. If the lock isn't
   granted, the worker writes a `ConsolidationRun` with
   `status: :skipped` (or no row at all, behind a config flag),
   releases the checkout, and exits without loading inputs.
   This is the only thing that prevents two nodes (libcluster)
   or a `run_now/1` racing the scheduled cadence from both
   reading the same watermark, both loading the same inputs,
   both invoking the harness on the same staged proposals, and
   both publishing duplicates — Postgres's default READ COMMITTED
   isolation does not protect against this on its own.

   Sketch:

   ```elixir
   JidoClaw.Repo.checkout(fn ->
     case JidoClaw.Repo.query!(
            "SELECT pg_try_advisory_lock($1)",
            [scope_lock_key]
          ) do
       %Postgrex.Result{rows: [[true]]} ->
         try do
           # steps 1–2: load watermarks + inputs (no DB transaction yet)
           # steps 3–6: in-memory clustering + Forge harness session —
           # connection is pinned to this process but no transaction is
           # open, so harness latency (which can be many minutes for
           # frontier models with high thinking effort) does not hold a
           # write transaction
           # step 7: open a SHORT transaction just to publish staged writes
           JidoClaw.Repo.transaction(fn -> publish_staged_writes(state) end)
         after
           JidoClaw.Repo.query!(
             "SELECT pg_advisory_unlock($1)",
             [scope_lock_key]
           )
         end

       %Postgrex.Result{rows: [[false]]} ->
         {:skip, :scope_busy}
     end
   end)
   ```

   Why **session** lock + `Repo.checkout/2` rather than `xact`:
   an xact lock is released only on the enclosing transaction's
   commit or rollback. Holding it from step 0 to step 7 would
   force a single transaction to span the harness-invocation
   window in steps 3–6, which defeats the "transaction stays
   short" goal (an open write transaction during harness latency
   holds a connection from the pool, blocks vacuum, and can stall
   under pool contention; with frontier-model harness sessions
   this can be many minutes). A session-level lock decouples the
   lock's lifetime from any one transaction; `Repo.checkout/2`
   pins a single connection to the run process so the lock holder
   is a stable connection across all steps.

   Crash recovery: if the worker crashes mid-run, the pinned
   connection closes, and Postgres auto-releases all
   session-level advisory locks held by that connection. A
   subsequent run acquires the lock cleanly. The `after` block
   handles the normal-termination path; the connection-close
   semantics handle the crash path. No lease table or TTL
   bookkeeping is required.

   `run_now/1` (§On-demand override) goes through the same
   acquisition path: a manual run that races a scheduled run
   loses the lock and returns `{:error, :scope_busy}` to the
   CLI, so the user gets a clear signal rather than a silent
   double-publish.

1. Find the two composite watermarks — last successful run's
   `(messages_processed_until_at, messages_processed_until_id)`
   and `(facts_processed_until_at, facts_processed_until_id)` for
   this scope. Either pair is `(:negative_infinity, _)` if no
   prior run exists, or carried forward from the most recent
   successful run that had a non-null watermark for that stream
   (a successful run that loaded no rows of one kind leaves that
   pair null; we look back further rather than treating null as
   "rewind to the beginning"). Each pair is the
   **max `(inserted_at, id)` of rows of that kind actually
   published by that prior run**, *not* `finished_at` (see 3.9 for
   why).
2. Load inputs against their respective watermarks, ordered
   ascending by `(inserted_at, id)` (the `id` tiebreaker matters —
   millisecond `inserted_at` collisions are common in bursty
   sessions, and a watermark of `inserted_at` alone could
   reload the colliding row or skip its sibling on the next run):
   - `Conversations.Message`s with `(inserted_at, id) >
     messages_watermark` for this scope's sessions, capped at the
     `max_messages_per_run` budget (see Cost control below). When
     the loaded set is fed to clustering in step 3, rows are
     re-grouped by `session_id` and ordered by `sequence` ASC
     within each group, so any same-session prompt slice the
     harness sees is in chronological order even when concurrent
     inserts produced inserted_at ties.
   - `Memory.Fact`s with `source IN (:model_remember, :user_save,
     :imported_legacy)` and `(inserted_at, id) > facts_watermark`,
     similarly capped. Including `:imported_legacy` is what
     actually lets `mix jido_claw.migrate.memory` output reach the
     consolidator (otherwise legacy facts written with that source
     are never picked up — see 3.17).

   The watermark advances **only over rows actually published** in
   step 7, not over the loaded set. Cluster-level deferral
   (max-cluster cap, harness skip, or harness timeout) means some
   loaded rows may remain unprocessed; advancing the watermark to
   the loaded max would skip them forever. Track each row's
   `(inserted_at, id)` as it moves from "loaded" to "included in a
   published cluster"; the new watermark is `max((inserted_at,
   id))` over that "published" subset, or the prior watermark if
   nothing was published. This makes both watermarks
   composite-typed (`{utc_datetime_usec, uuid}`) — store
   `inserted_at` and `id` columns side by side on
   `ConsolidationRun` rather than a single timestamp.

   **Pre-flight `min_input_count` gate.** Before steps 3–7, the
   worker counts loaded inputs (messages + qualifying facts). If
   the total is below `min_input_count`, the worker writes a
   `ConsolidationRun` with `status: :skipped, error:
   :insufficient_inputs`, releases the lock, and exits without
   invoking the harness. This is the cheap pre-check that lets a
   6-hour cadence run on quiet scopes without burning a frontier-
   model session every tick. Watermarks remain at the prior value
   so the inputs accumulate for the next run.

3. **Cluster** by topic: top-k vector similarity grouping (k=5 by
   default), with each cluster centered on its highest-trust
   member. Clustering is a deterministic in-memory pass over the
   loaded set; clusters are passed into the harness session as
   structured input.
4. **Run the consolidation harness** in a Forge session. The
   worker starts a Forge session with `runner: :claude_code` (or
   `:codex`) and `sandbox_mode: :local`, hands it the rendered
   prompt (current Block tier for the scope chain + clustered
   inputs + scope context), and lets the harness drive proposal
   collection through a scoped tool surface. The harness emits
   proposals via tool calls — *not* via stdout JSON — and a
   single Forge session covers what would have been three
   separate passes (Fact proposals, Block edits, Link discovery)
   in the original LLM-call design. Holistic reasoning across
   clusters is a feature, not a side effect: a frontier model
   spotting that two clusters reflect the same underlying fact
   will emit one consolidated proposal instead of two redundant
   ones.

   **Scoped consolidation tools** (registered with the Forge
   session, not the global agent's tool registry — the harness
   cannot `write_file` or `git_commit` from this session):

   | Tool | Direction | Purpose |
   |---|---|---|
   | `list_clusters()` | read | Returns cluster summaries for the run; harness pulls full cluster contents on demand. |
   | `get_cluster(cluster_id)` | read | Full input rows (messages + facts) for one cluster, in the chronological order set by step 2. |
   | `get_active_blocks()` | read | Current Block tier for the scope chain — the harness needs this to decide Block edits. |
   | `find_similar_facts(content, k \\ 5)` | read | Top-k vector search against existing Facts in scope, used for link discovery. |
   | `propose_add(content, tags, label \\ nil)` | stage | Stages new Fact: `source: :consolidator_promoted`, `valid_at = now()`. |
   | `propose_update(fact_id, new_content, reason)` | stage | Stages invalidate + replacement pair: invalidate the existing Fact (leave its `valid_at` **intact** — that's when the world-truth originally started — set `invalid_at = now()` and `expired_at = now()`) and create a new Fact with the updated content, its own `valid_at = now()`, plus a `:supersedes` Link from the new Fact to the old. Overwriting the old `valid_at` would erase bitemporal history and break `as_of_world` queries. |
   | `propose_delete(fact_id, reason)` | stage | Stages invalidation only: `invalid_at` and `expired_at` set; `valid_at` left intact; no replacement. |
   | `propose_block_update(label, new_content, reason)` | stage | Stages Block edit with revision audit. Per-block char limit enforced server-side; on overflow, the tool returns the error + current value and the harness retries (Hermes pattern). |
   | `propose_link(from_fact_id, to_fact_id, relation, reason)` | stage | Stages a graph edge. Cap of 5 links per source Fact (rejected at staging beyond that) to keep the graph sparse. |
   | `defer_cluster(cluster_id, reason)` | stage | Marks a cluster as intentionally deferred; rows in deferred clusters do not contribute to the contiguous-prefix watermark in step 7. |
   | `commit_proposals()` | terminal | Signals "done." The session returns to the worker, which validates and publishes in step 7. |

   The proposal tools **stage** into a per-run buffer in the
   worker process — no DB writes happen during the harness
   session. The harness sees its proposals reflected in
   subsequent `list_clusters`/`find_similar_facts` results
   (so it can build on its own staged decisions within the
   session) but the underlying tables are unchanged until step 7.

   This tool surface is exposed to the harness as MCP tools by a
   purpose-built MCP server that the Forge runner spawns *only*
   for this session — it is not the project's general-purpose
   `mix jidoclaw --mcp` server, which would expose `write_file`,
   `git_commit`, and the rest of the 15-tool surface. Scoping is
   the safety boundary; the transactional commit gate in step 7
   is the secondary safety boundary if the scoping ever leaks.
5. **(Folded into step 4.)** Block consolidation and Link
   discovery happen inside the harness session via
   `propose_block_update` and `propose_link` rather than as
   separate post-passes. The frontier-model harness can interleave
   Fact, Block, and Link decisions naturally — a new Fact
   triggering a Block update is one continuous chain of thought,
   not two passes connected by re-prompting.
6. **(Folded into step 4.)** See above.
7. **Publish atomically.** Once the harness emits
   `commit_proposals` (or the session ends via timeout / max-turns
   / max-cluster cap), the worker validates the staged batch and
   commits. All staged writes — new Facts, FactEpisode rows, Fact
   invalidations, Block revisions, Block updates, Links — plus
   the final `ConsolidationRun` row, commit inside a single
   `JidoClaw.Repo.transaction/1`. The `ConsolidationRun` row
   carries `status: :succeeded`, counts, `finished_at`,
   `forge_session_id` (FK pointer to the Forge session for
   transcript reachability — see §3.9), and the new watermarks
   computed as the **longest contiguous prefix of published rows
   in the loaded stream**:
   - Walk the loaded message stream in `(inserted_at, id)` ASC
     order. Stop at the first row that wasn't published (a row in
     a `defer_cluster`'d cluster, or one a published cluster's
     proposals declined to act on but didn't formally drop).
   - `messages_processed_until_at` and
     `messages_processed_until_id` = the `(inserted_at, id)` of
     the **last row in that contiguous prefix**, or null if the
     first loaded row wasn't published.
   - `facts_processed_until_at` / `facts_processed_until_id` =
     same walk over loaded facts.

   The contiguous-prefix invariant matters because clustering can
   group non-adjacent rows: cluster A might span message indices
   `[1, 4]` and cluster B `[2, 3, 5, 6]`. If a harness deferral
   or cluster-cap forces B to defer, "max published `(inserted_at,
   id)`" would advance to row 4, skipping rows 2 and 3 forever.
   The contiguous-prefix rule advances only to row 1 in that case;
   row 4 gets re-loaded next run and either re-clusters with the
   formerly-deferred rows or — if the same Fact proposals
   recur — collides with the active-label identity (for labeled
   writes) or the active-promoted-content identity (for unlabeled
   consolidator writes) defined in §3.6, and the duplicate insert
   is rejected at the database. The staged invalidate-and-replace
   pattern means the harness's "regenerated" proposal becomes a
   no-op without producing a duplicate row. Cluster ordering
   should bias toward "smallest-min-row clusters first" so the
   prefix advances as far as possible per run, but correctness
   does not depend on it.

   The four watermark fields are null when nothing of that kind
   formed a contiguous published prefix; the next run carries
   forward the prior successful watermark for the silent stream.
   The harness session runs **outside** the transaction (steps
   3–6 are pure staging in memory; the harness pinned-connection
   has no transaction open) so the transaction stays short and
   doesn't hold connections during the multi-minute harness window
   that frontier-model thinking can produce.

**Failure handling.** Any harness error before step 7 — auth
failure, rate limit, transient network failure, harness CLI
non-zero exit, timeout, max-turns cap reached without
`commit_proposals` — aborts the run without ever opening the
transaction. The staging buffer is discarded and a
`status: :failed` `ConsolidationRun` row is written with all four
watermark fields null and the failure reason in `error`. The
`forge_session_id` is recorded even on failure so the transcript
remains reachable for debugging. Any error during step 7 rolls
the transaction back, again leaving a `:failed` row with null
watermarks. In either case the next run picks up from the prior
successful run's watermarks; no partial state is ever visible
because no row from the staging buffer ever lands without all
others. Idempotency guaranteed because all reads are scoped to
"since watermark" and the transaction is the only publication
point. Retry policy is "wait for the next cadence tick" — no
in-process retry within the lock window, since most harness
failures are not transient at sub-cadence timescales (auth and
rate-limit issues need operator attention).

**Cost control.** Each scope's consolidation is bounded:
- `min_input_count` (default 10): the pre-flight gate — if the
  loaded set is smaller than this, the run skips without
  invoking the harness. Cheap pre-check that absorbs the "6-hour
  cadence on a quiet scope" case without spending any
  frontier-model budget.
- `max_messages_per_run` (default 500): `SELECT ... LIMIT 500`
  against the ordered query in step 2. Excess remains for the
  next run — the watermark only advances over published rows, so
  nothing is lost.
- `max_facts_per_run` (default 500): same shape against the fact
  stream.
- `max_clusters_per_run` (default 20): clustering in step 3 caps
  at this number; clusters beyond the cap are dropped from the
  current run (their rows do **not** contribute to step 7's
  contiguous-prefix watermark, so they re-enter the next run's
  load query). Replaces the old `max_llm_calls_per_run` knob —
  in the harness model, "LLM call" is no longer a discrete unit;
  cluster count is.
- `harness_options.timeout_ms` (default 600_000) and
  `harness_options.max_turns` (default 60) bound a single
  harness session.
- Telemetry: `[:jido_claw, :memory, :consolidator, :run]` with
  scope, duration, harness turns, tokens (when the runner can
  surface them), plus
  `messages_loaded` / `messages_published` and
  `facts_loaded` / `facts_published` so deferral rates are
  observable. Per-run cost telemetry is best-effort — Claude
  Code's `--print` mode does not always surface usage; the Codex
  runner has different reporting. `:cost_unknown` is an expected
  value, not a bug.

**On-demand override.** `Memory.Consolidator.run_now/1` triggers an
out-of-cadence run, used by the `/memory consolidate` CLI and by
tests. It goes through the same advisory-lock acquisition as
scheduled runs (step 0) — if a scheduled run is already
in-flight for the same scope, `run_now/1` returns
`{:error, :scope_busy}` and the CLI surfaces a "consolidation
already running for this scope" message rather than queueing or
double-publishing. `run_now/1` accepts an
`override_min_input_count: true` option that bypasses the §3.15
step 2 pre-flight gate, so a user explicitly asking for "consolidate
now" doesn't get a confusing skip on a quiet scope; the gate
remains in force for scheduled runs. Tests that need to drive
consolidation deterministically take the same code path; the
test setup waits on a `:run_completed` telemetry event to know
the prior run released the lock, rather than racing.

### 3.16 Embeddings pipeline

Same `Embeddings.Voyage` module as Phase 1, now also populating
`Memory.Fact.embedding`. The redaction gate, telemetry, and the
per-workspace `embedding_policy` (`:default | :local_only |
:disabled`) defined in §1.4 apply uniformly — Memory writes don't
get a different policy than Solutions writes. Backfill worker
scoped per resource.

Async-on-write contract:
1. Fact created with `embedding_status: :pending` (or `:disabled`
   when the workspace's `embedding_policy: :disabled`).
2. Worker picks up `:pending` rows in batches (Voyage API supports
   batch embedding — saves cost). Workspace policy is re-read at
   execute time so a policy change applies to already-pending
   rows.
3. Each input string is redacted before the HTTP request leaves
   the node, per §1.4. Telemetry counts `redactions_applied`.
4. On success, `embedding` populated, status flipped to `:ready`.
5. Reads filter `is_not_null(embedding)` for cosine; FTS works with
   or without.
6. Cold-start: a Fact created seconds ago might be FTS-only. That's
   fine — the consolidator will see it on the next run.
7. `:disabled` rows stay searchable via FTS but never get an
   embedding; retrieval gracefully degrades to FTS-only when the
   workspace opted out (the `$4::vector IS NOT NULL` guard in
   §1.5 already handles this on the query side; the analogous
   guard applies to memory retrieval in §3.13).
8. The periodic durable backfill scan in §1.4 runs against
   `Memory.Fact` too — same query (`embedding_status: :pending
   AND inserted_at < now() - INTERVAL '1 minute'`), same batch
   cap, same telemetry counter. Crash-recovery semantics are
   identical to the Solutions side, so a Fact written seconds
   before a node restart still gets embedded after recovery.

### 3.17 Migration: `.jido/memory.json` → Postgres

```
mix jido_claw.migrate.memory
```

1. Walk known `.jido/memory.json` files (per workspace). The
   on-disk shape per `record_to_entry/1`
   (`lib/jido_claw/platform/memory.ex:235-247`) is
   `%{key, content, type, created_at, updated_at}`; `key` is a
   user-supplied string identifier (e.g. `"db_schema"`,
   `"preferred_style"`), not a UUID.
2. `WorkspaceResolver.ensure/1` for each.
3. For each entry, call `Memory.Fact.import_legacy/1` (the
   privileged-import action defined in §3.6) with:
   - `tenant_id: <workspace.tenant_id>` (per §0.5.2; the
     workspace row carries it).
   - `scope_kind: :workspace`, `workspace_id: <resolved>`,
     `user_id: <workspace.user_id>` (ancestor FK populated per the
     scope invariant in §3.2).
   - **`label: <entry.key>`** — the legacy key migrates to the
     `Fact.label` column. Required so today's `recall` substring
     match on `key` (`String.contains?(String.downcase(key), q)`
     in `lib/jido_claw/platform/memory.ex:152-157`) and `forget
     <key>` continue to work after migration. Without this
     mapping, the §3.13 lexical pool would have nothing to match
     against for key-only queries.
   - `content: <entry.content>`. Run through the §3.10 write-time
     redactor — same gate the live `:record` action uses, so
     legacy secrets that slipped into JSONL get scrubbed on
     import rather than carried into Postgres verbatim.
   - `tags: [<entry.type>]` (legacy types: fact, pattern,
     decision, preference, context). Including the type as a tag
     preserves today's `recall` substring match on `kind`
     (`String.contains?(String.downcase(kind), q)`) — the
     §3.6 generated `search_vector` includes `tags` so a query
     like `recall("preference")` matches a Fact tagged
     `[:preference]` even with no `label`/`content` hit.
   - `valid_at: <entry.created_at>`, `inserted_at: <entry.created_at>`
     (legacy JSON's `created_at` field maps to the new schema's
     `inserted_at` system-time column). The `:import_legacy`
     action is the only one that accepts these — the live
     `:record` action doesn't.
   - `import_hash: SHA-256(workspace_id || label || content ||
     inserted_at_ms)`. The migrator computes this and passes it
     in; the action stores it under the partial unique identity
     `unique_import_hash`, so re-running the migration is
     idempotent without relying on legacy UUIDs (which the
     on-disk shape doesn't carry).
   - `source` is fixed to `:imported_legacy` by the action itself.
4. Backfill embeddings via the worker. The worker honors
   `Workspace.embedding_policy` (§0.2 default `:disabled`,
   surface in §1.4) — migrated workspaces never enqueue embedding
   work until the user explicitly opts in via
   `Workspaces.set_embedding_policy/2` or
   `/workspace embedding default` (§1.4). Until they do,
   `Memory.Fact.embedding_status` stays `:disabled` for these
   rows and §3.13 retrieval falls back to FTS + lexical without
   the cosine pool.

The legacy types do **not** become Blocks at migration time. They
land in the searchable tier with `source: :imported_legacy`, which
the consolidator's input filter (3.15 step 2) explicitly includes —
that's the only thing that lets the next consolidation run actually
reach them and decide whether to promote individual entries to
Blocks or to `:consolidator_promoted` Facts. This avoids a heuristic
at migration time and gives the consolidator full authority.

### 3.18 Decommissioning

- `JidoClaw.Memory` GenServer deleted; `JidoClaw.Memory` namespace now
  refers to the Ash-backed module surface.
- `Jido.Memory.Store.ETS` still in use? Check; if not, drop the dep
  (`{:jido_memory, ...}` in `mix.exs`).
- `.jido/memory.json` left on disk as backup.

### 3.19 Acceptance gates

- All current memory-related tests adapted and green.
- A scheduled consolidation run produces measurable Block content on
  a real session.
- `recall` returns better matches than today on paraphrased queries
  (qualitative).
- **Substring-superset regression test for `recall`.** Seed a Fact
  with `label: "api_base_url"`, another with `tags: [:preference]`,
  and a third with `content` containing the punctuated identifier
  `"foo.bar.baz"`. Issue `recall("api_base")`, `recall("preference")`
  (matching only on tag), and `recall("foo.bar")` and assert each
  Fact is returned. Without the §3.13 lexical pool — and without
  including `tags` in the `Memory.Fact.search_vector` (per §3.6) —
  these queries return zero hits because Postgres FTS tokenizes
  via stemming. This is the contract `lib/jido_claw/tools/recall.ex`
  documents ("substring match on key, content, and type") and that
  the v0.5.x ETS store met by accident.
- **Lexical-index engaged regression test.** Seed 5,000 Facts at
  one scope. `EXPLAIN ANALYZE` a `Retrieval.search` whose only
  matching pool is the lexical one (a punctuated identifier query
  FTS would miss). Assert the plan node selecting from
  `memory_facts` for the lexical pool uses
  `Bitmap Index Scan on <lexical_text trigram index>`, *not*
  `Seq Scan` and *not* a generic GIN scan over `search_vector`.
  This is the gate that catches a regression where someone moves
  the trigram index off the generated `lexical_text` column or
  reintroduces `lower(...)`/`coalesce(...)` wrappers in the
  filter — both of which silently turn the scan sequential.
  Mirror gate exists in §1.8 for `Solutions.Solution.lexical_text`.
- **Memory.Fact policy transition test.** Mirror of the §1.8
  Solutions transition test, against `Memory.Fact` rows. Seed a
  workspace at `:disabled`, write three labeled Facts; assert
  all `:disabled`. Flip to `:default`; assert all `:pending`.
  After the worker, assert `:ready`. Flip back to `:disabled`;
  assert `:ready` rows keep their embeddings. Flip with
  `purge_existing: true`; assert embeddings are NULLed. Pins
  the §1.4 contract holds for memory writes too.
- **Embedding-space isolation gate.** Set up two workspaces in
  the same tenant: `WS_voyage` (`:default`) and `WS_local`
  (`:local_only`). Seed identical content in each. Backfill
  embeddings under each workspace's policy and assert
  `embedding_model = 'voyage-4-large'` on the first set and
  `embedding_model = 'mxbai-embed-large'` on the second. Issue
  `Retrieval.search(query)` from `WS_voyage`; assert the ANN
  pool returned matches all carry `embedding_model =
  'voyage-4-large'` and that no row from `WS_local` appears in
  the ANN pool's results — even when sharing visibility (set
  to `:public` on a fixture row in each workspace) would
  otherwise admit them. Repeat from `WS_local`. Confirms the
  §1.4 cross-policy isolation contract: cosine comparisons
  never cross vector spaces, and cross-policy candidates fall
  through to FTS/lexical (which the test also asserts pick up
  the same content via lexical match). Without this gate, a
  refactor that drops the `embedding_model = $11` filter would
  silently produce uncorrelated rankings on mixed-policy
  retrievals.
- **Cross-tenant FK validation regression test for `Memory.Fact`.**
  Create two Workspaces under distinct tenants (`WS_a` in tenant
  A, `WS_b` in tenant B). Construct a `:record` action call with
  `scope_kind: :workspace`, `tenant_id: A`, `workspace_id: WS_b.id`.
  Assert the action fails with `:cross_tenant_fk_mismatch`.
  Repeat the test with `:import_legacy` and the same mismatch.
  Repeat once more with a session-scoped fact where
  `session_id` and `workspace_id` are both populated as ancestor
  FKs but disagree on tenant — the hook MUST validate every
  populated FK, not just the leaf, so a session_id pointing at
  the right tenant but a workspace_id ancestor pointing at the
  wrong one still fails. Without these gates a buggy
  `tool_context` resolver could silently land memory under the
  wrong tenant for any of the four scope kinds.
- **Source-precedence dedup regression test.** At one scope, seed
  three active Facts with the same label `"api_url"`:
  `:user_save`, `:consolidator_promoted`, and `:model_remember`.
  Issue `Retrieval.search("api_url")` with default options;
  assert exactly one row is returned and that its `source` is
  `:user_save` (the highest precedence). Assert the returned
  row's `metadata.shadowed_by` lists the IDs of the
  `:consolidator_promoted` and `:model_remember` rows. Repeat
  with `dedup: :none`; assert all three rows return. Repeat with
  `filters: [source: :model_remember]`; assert only the
  `:model_remember` row returns (the explicit-source filter
  short-circuits dedup, per §3.13). Without the precedence pass,
  the model could see contradictory active values for one label
  and have no deterministic rule for which to act on.
- **Scope-precedence dedup regression test.** Seed three active
  Facts with the same label `"api_url"` *across different
  scopes* under the same caller's scope chain:
  `:session`-scoped, `:workspace`-scoped, and `:user`-scoped,
  all `:user_save`. Issue `Retrieval.search("api_url")` from a
  `tool_context` that resolves all three FKs (so the caller's
  scope chain spans all three). Assert exactly one row is
  returned and that its `scope_kind` is `:session` (closer
  scope wins). Repeat the test with the session-scoped row's
  RRF rank artificially poor — e.g. by giving it a slightly
  off-topic content, while making the workspace-scoped row's
  content match the query verbatim. The session-scoped row
  must still win because scope precedence outranks RRF score.
  This pins the §3.13 in-SQL window function against drift; a
  refactor that moves the dedup to Elixir post-LIMIT would fail
  this test (the workspace row would dominate the candidate
  cap by RRF score, the session row would be excluded, and the
  contract would silently invert).
- **Combined precedence test.** Seed (a) session-scoped
  `:model_remember` `"api_url"`, (b) workspace-scoped
  `:user_save` `"api_url"`. Both are active. Issue
  `Retrieval.search("api_url")`; assert (a) wins (scope axis
  outranks source axis). Then add (c) session-scoped
  `:user_save` `"api_url"`. Assert (c) wins (closer scope
  *and* higher source is unambiguous). Pins the precedence
  axis ordering: scope is outer, source is inner.
- Frozen-snapshot prompt cache fires on Anthropic (telemetry shows
  `cache_hits` > 0).
- **Consolidator opt-out egress gate.** Seed two workspaces in the
  same tenant, `WS_off` (`consolidation_policy: :disabled`, the
  §0.2 default) and `WS_on` (`consolidation_policy: :default`).
  In each, seed enough messages and facts to clear
  `min_input_count` and stub the harness runner with a
  `:test_runner` that records whether it was invoked and what
  inputs it received. Run `Memory.Consolidator.run_now/1` for a
  scope under each workspace.

  Assertions for `WS_off`:
  1. The stub harness was **never invoked** (no transcript or
     fact content reached the runner).
  2. A `ConsolidationRun` row exists with
     `status: :skipped, error: :consolidation_disabled` (or no
     row at all if the config flag is set to suppress
     skip-rows — pin whichever the config defaults to).
  3. No watermark advance, no `forge_session_id`, no
     `:jido_claw, :memory, :consolidator, :run` telemetry event
     for invocation (only the skip event).

  Assertions for `WS_on`:
  1. The stub harness **was** invoked with the loaded clusters.
  2. A `ConsolidationRun` row exists with
     `status: :succeeded` and a populated `forge_session_id`.

  This pins the §3.15 step -1 gate behavior: a default install
  (every workspace `:disabled`) cannot send a single transcript
  byte to the consolidator harness. Mirrors the §1.8
  embedding-policy egress gate.

- **Consolidator user-scope most-restrictive test.** Two
  workspaces (`WS_a: :default`, `WS_b: :disabled`) under the
  same `user_id`. Seed user-scoped facts/messages spanning both.
  Run the consolidator at `scope_kind: :user`. Assert
  `status: :skipped, error: :consolidation_disabled` because the
  most-restrictive workspace policy is `:disabled`. Flip `WS_b`
  to `:default`; rerun; assert the harness is invoked. This
  pins the user-scope policy resolution rule from §0.2.

- Bitemporal queries work: "what did we believe about X on date Y"
  returns the correct fact via `as_of_world`.
- **Bitemporal current-truth predicate parity test.** Pin §3.13
  retrieval to the §3.3 predicate by seeding three Facts at the
  same scope and label:
  1. `valid_at = now() + 1 hour`, `invalid_at = NULL` — recorded
     with a future world-time validity (e.g. a planned change).
  2. `valid_at = now() - 1 day`, `invalid_at = now() + 1 hour` —
     currently true now, will become invalid in the future.
  3. `valid_at = now() - 1 day`, `invalid_at = NULL` — currently
     true now and indefinitely.
  Issue `Retrieval.search` with no `as_of_world`. Assert that
  Fact (1) is **excluded** (not yet true) and Facts (2) and (3)
  are **included** (currently true). The earlier
  `invalid_at IS NULL`-only filter would wrongly include (1)
  and exclude (2). Repeat with `as_of_world = now() + 2 hours`
  and assert (1) and (3) are included while (2) is excluded.
  This regression locks the world-axis predicate everywhere
  it's read.
- **Bitemporal world-time-travel + later-superseded test.** Seed
  one Fact with `valid_at = T0 - 1 day`, `invalid_at = T0`,
  `expired_at = T0` (a fact that was true historically but has
  since been invalidated). Issue `Retrieval.search(query,
  as_of_world: T0 - 12 hours)`; assert the row **is returned**.
  This is the case the earlier `expired_at IS NULL`-everywhere
  predicate silently broke — the row was valid at T0 - 12h but
  has since been superseded, and the system-time gate masked
  the world-time truth. Repeat with `as_of_world: T0 + 12
  hours`; assert the row is **not returned** (now invalid in
  world time). Pins the §3.13 matrix's world-time-travel mode.
- **Bitemporal system-time-travel test.** Seed one Fact at
  `inserted_at = T0`. At `T0 + 1 day`, invalidate it (sets
  `invalid_at` and `expired_at` to `T0 + 1 day`). Issue
  `Retrieval.search(query, as_of_system: T0 + 12 hours)`;
  assert the row **is returned** (we knew about it at T0 + 12h
  and didn't yet think it was expired). Issue with
  `as_of_system: T0 + 2 days`; assert the row is **not
  returned** (we'd already learned of its invalidation by then).
  Pins the system-time-travel mode. Without `as_of_system`
  exposed at the API, this case is unreachable from the public
  surface.
- **Bitemporal full-axis test.** Combine: seed a Fact whose
  `valid_at`/`invalid_at` and `inserted_at`/`expired_at` axes
  diverge. Issue queries that pin each combination of (T_w
  inside vs. outside `[valid_at, invalid_at)`) × (T_s inside
  vs. outside `[inserted_at, expired_at)`) and assert the
  matrix from §3.13 holds across all four cells. Pins the
  axes-are-independent invariant and prevents a future
  refactor from collapsing them.
- New `/memory blocks`, `/memory consolidate`, `/memory status`
  commands functional.
- `JidoClaw.Memory.Domain` appended to
  `config :jido_claw, :ash_domains`. Resources don't load without
  the domain entry.
- `mix ash.codegen --check` clean.
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors; the Memory.Block and Memory.Fact
  partial identities carry the entries listed in §Cross-cutting
  concerns.
- Generated columns sanity (per §Cross-cutting "Generated columns"):
  - `Memory.Fact.content_hash` migration declares
    `GENERATED ALWAYS AS (digest(content, 'sha256')) STORED`, and
    requires the `pgcrypto` extension to be present in
    `JidoClaw.Repo.installed_extensions/0`.
  - `Memory.Fact.search_vector` migration declares
    `GENERATED ALWAYS AS (to_tsvector('english',
    coalesce(label, '') || ' ' || content || ' ' ||
    array_to_string(coalesce(tags, ARRAY[]::text[]), ' ')))
    STORED`. The `tags` term is what makes the
    `recall("preference")` tag-only acceptance test (§3.19)
    actually hit via the FTS pool — without it, that query
    only succeeds via the §3.13 lexical pool, which papers
    over the FTS gap rather than fixing it.
  - An integration test inserts a Fact, asserts both columns
    populate at the database level, asserts the
    `unique_active_promoted_content_per_scope_*` partial identity
    rejects a duplicate-content row, and asserts FTS matches.
- A consolidator concurrency test: kick off two `run_now/1` calls
  for the same scope from two processes; assert exactly one
  publishes a `:succeeded` `ConsolidationRun` row and the other
  observes `{:error, :scope_busy}`. Proves the §3.15 step 0
  session-level advisory lock + connection-checkout design works
  through `Repo.checkout/2`.
- **Cross-tenant Link rejection test.** Seed two Facts under
  tenant A and two Facts under tenant B (all four with the same
  scope_kind). Attempt to create a `Memory.Link` from a
  tenant-A Fact to a tenant-B Fact; assert the action returns an
  error with a `:cross_tenant_link` reason and no row is
  inserted. Repeat with same-tenant + different-scope_kind and
  assert the same rejection. Then create a same-tenant
  same-scope link and assert it succeeds. Without the §3.8
  before_action invariant, recursive-CTE traversals could walk
  across the §0.5.2 outer boundary.
- **Scope denormalization test for revisions and join rows.**
  Update a `Memory.Block`, then assert the resulting
  `BlockRevision` row's `tenant_id` and scope FKs equal the
  Block's. Insert a `Memory.FactEpisode`; assert its
  `tenant_id` equals both `Fact.tenant_id` and
  `Episode.tenant_id`. Manually attempt to construct a
  `FactEpisode` linking a Fact and Episode from different
  tenants (bypassing the action's `before_action` by using
  `Ash.Changeset.force_change_attribute/3`); assert the
  validation rejects it. This is what makes Phase 4 tenant
  policies attachable to these tables without joining through
  parents.
- A consolidator crash-recovery test: kill the worker process
  mid-staging (after step 2, before step 7); start a new run for
  the same scope; assert it acquires the lock cleanly (the prior
  connection's session-level lock auto-released on close) and
  publishes correctly.
- Embedding backfill recovery: insert a `Memory.Fact` with
  `embedding_status: :pending`, kill the worker before it picks
  up the live-insert event, restart; assert the next periodic
  scan tick (per §1.4) recovers the row and embeds it. Same
  shape as the Solutions backfill test in §1.8 but against
  `Memory.Fact`.
- `mix jido_claw.export.memory` round-trip, two fixtures (per the
  Phase summary "Rollback caveat" two-fixture contract):
  - **Sanitized fixture**: a v0.5.x `.jido/memory.json` with no
    strings matching §1.4 redaction patterns. load → migrate →
    export → byte-equivalent to input modulo dropped Block /
    Episode / Link rows (which appear in the warning manifest).
    Must include entries that exercise the `entry.key →
    Fact.label` mapping (§3.17) and `entry.type → tag` mapping;
    the round-trip proves no key information is lost.
  - **Redaction-delta fixture**: same shape as the sanitized
    fixture but seeded with at least one match per
    `Redaction.Patterns` category embedded in `entry.text`. The
    export contains `[REDACTED]` exactly where the import-time
    redaction observed a match, cross-checked against the
    export's redaction manifest.
- `mix jido_claw.migrate.memory` idempotency: run the migration
  twice against the same `.jido/memory.json` fixture and assert
  the second run inserts zero rows. Proves the
  `unique_import_hash` partial identity (§3.6, partial-identities
  table) is the actual dedup mechanism, not the broken
  `Fact.exists?(id: legacy_uuid)` shape from earlier drafts.

---

## Phase 4 — Audit log, multi-tenancy, residual gaps

**Goal:** close the remaining file-to-DB gaps from the original
roadmap and turn the ETS-backed Tenant manager into a real Ash
multitenancy story.

### 4.1 Audit log

A new `JidoClaw.Audit` domain (or extend `Reasoning.Domain`) with one
resource:

```
JidoClaw.Audit.Event
  - tenant_id    text  (required; per §0.5.2)
  - event_kind   atom  (:tool_call, :memory_write, :memory_consolidation,
                       :solution_share, :session_start, :session_end,
                       :auth_event, ...)
  - actor_kind   atom  (:user, :agent, :consolidator, :system)
  - actor_id     text
  - target_kind  atom
  - target_id    uuid | text
  - payload      map
  - inserted_at  utc_datetime_usec
```

Append-only (no `update`/`destroy` actions). Indexed for
`(tenant_id, event_kind, inserted_at)` so audit search is
tenant-scoped at the index level — the same pattern used by
every other resource introduced in Phases 0–3 per §0.5.2.
Secondary indexes on `(tenant_id, actor_kind, actor_id,
inserted_at)` for "what did this actor do" queries and
`(tenant_id, target_kind, target_id, inserted_at)` for "what
happened to this row" queries; both are tenant-leading for the
same reason.

The `tenant_id` column is **required** at creation. The
`Audit.Event.create` action accepts `tenant_id` as a mandatory
input and rejects the create if the supplied `tenant_id` doesn't
match the resource referenced by `target_kind`/`target_id`
(when the target is a tenant-scoped resource — Conversations,
Memory, Solutions, etc.). This is the same cross-tenant FK
validation hook from §0.5.2: an audit event for a row in tenant
A landing under tenant B would either miss the audit search for
A's operators or leak in B's, depending on which side ran the
search — both failure modes silently. The validation is
mandatory because audit, by definition, is the surface of last
resort for catching cross-tenant bugs; it cannot itself be the
weakest link.

Ash policy filters every `read` action by the caller's
`tenant_id` (the same shape applied to every other resource by
§4.2 step 5), so audit-search UIs in `web/live/` cannot leak
cross-tenant rows even when the calling code forgets to thread
the tenant filter.

Consumed by a future audit-search UI in `web/live/`.

### 4.2 Real Ash multitenancy

Today's `JidoClaw.Tenant` is ETS-only. Phases 0–3 already added a
required `tenant_id` text column to every new persisted resource
(see §0.5.2), populated from the existing ETS Tenant.Manager
strings, plus indexed as the leading column on every primary read
pattern. Phase 4's job is therefore to **promote** the existing
columns rather than backfill-from-scratch — the heavy lifting
already happened in earlier phases.

1. Make `JidoClaw.Platform.Tenant` an Ash resource (in a new
   `JidoClaw.Tenants` domain or alongside Accounts). **Pin the
   primary key to `:string` (text), not the Ash default
   `:uuid`.** Existing tenant identifiers are opaque
   application-generated strings, and the live system today uses
   *several* shapes — none of them UUIDs:
   - The literal `"default"` for unauthenticated CLI flows
     (`lib/jido_claw.ex:28`,
     `lib/jido_claw/platform/tenant/manager.ex:54`).
   - User UUID strings, derived via
     `to_string(conn.assigns.current_user.id)`, for the web/API
     and Phoenix Channel surfaces
     (`lib/jido_claw/web/controllers/chat_controller.ex:15`,
     `lib/jido_claw/web/channels/rpc_channel.ex:76`). Both call
     sites have a comment acknowledging this is a stopgap until
     a real user-to-tenant model exists, and the Phase 4 FK
     promotion inherits that conflation.
   - The `tenant_<base64>` form generated by
     `JidoClaw.Tenant.new/1` when called without an explicit
     `:id` (`platform/tenant.ex:32-34`). Currently no caller in
     `lib/` exercises this branch, but it remains the canonical
     shape for any future tenant-creation flow.

   Every Phase 0–3 resource carries whichever string the runtime
   produced in a `text tenant_id` column per §0.5.2. Pinning the
   new resource's PK to text lets step 3 below reduce to an
   `ALTER TABLE … ADD CONSTRAINT … NOT VALID FOREIGN KEY` plus
   `VALIDATE CONSTRAINT` — no row-by-row conversion of strings
   into UUIDs across the multi-table surface. The resource's
   primary-key declaration is therefore
   `attribute :id, :string, primary_key?: true, allow_nil?:
   false, default: &generate_id/0` rather than the AshPostgres
   default UUID block.
2. Backfill the Tenant table from the ETS table at migration time
   (one row per distinct `tenant_id` string already in
   Workspaces / Sessions / Solutions / Memory). Because the PK is
   text, the backfill is a single
   `INSERT … SELECT DISTINCT tenant_id FROM …` per source table
   union'd, with `ON CONFLICT (id) DO NOTHING`.
3. Promote each resource's `tenant_id` text column to a real FK in
   a single migration. Rows already carry the correct string, so
   the FK conversion is a column-type change plus a `NOT VALID`
   constraint that's then validated — no row-by-row backfill.
4. Decide per resource whether to use Ash's `:attribute`
   multitenancy strategy (cheaper at query time, declares the
   column on the resource) or to keep tenant scoping as a manual
   `tenant_id` filter — both work because the column is already
   present.
5. Add Ash policies that filter by tenant on every read action;
   the `JidoClaw.Repo.prepare_query/2` injection floated in §0.5.2
   becomes redundant once Ash policies handle it uniformly.
6. Update `tool_context` to carry the resolved tenant FK alongside
   the existing string. Since the tenant id was already a string
   in `tool_context.tenant_id` from Phase 0 onward, this is a
   relabel rather than a new value — the Ash multitenancy hooks
   accept the same string.

### 4.3 Reasoning.Outcome string FK cleanup

`Reasoning.Outcome` carries `workspace_id` (string) and `agent_id`
(string). Phase 0 added a sibling `workspace_uuid` FK. Phase 4
deprecates the string columns and migrates code to the FK.

### 4.4 Remaining file stores

Audit and classify every writer under `.jido/`. The Phase 0–3
migrations remove the data-bearing JSON stores
(`memory.json`, `solutions.json`, `reputation.json`, `sessions/`);
this section enumerates what remains and decides each one's fate.

**Stays as config (not migrated):**
- `.jido/profiles/*.yaml` (per-workspace shell profiles).
- `.jido/skills/*.yaml` (skill definitions).
- `.jido/strategies/*.yaml`, `.jido/pipelines/*.yaml` (reasoning
  config).
- `.jido/JIDO.md`, `.jido/system_prompt.md` (project-level prompt
  scaffolding).

**Active runtime writers — explicitly classified:**
- `.jido/identity.json` — written by
  `lib/jido_claw/agent/identity.ex:153` (`save_identity/2`). Stores
  `agent_id` and seeds the per-workspace agent personality. Stays
  on disk in v0.6.4 — promoting it to a real `Agent` Ash resource
  is the v0.7+ work flagged in the §1.3 "string for now, FK later"
  note. Document the classification here so the §4.5 sweep
  doesn't flag it as a regression.
- `.jido/cron.yaml` — written by
  `lib/jido_claw/platform/cron/persistence.ex:31` and read by
  `lib/jido_claw/platform/cron/scheduler.ex` on boot. Holds the
  scheduled-job catalog (cron expression, agent_id, mode, task).
  v0.6.4 **migrates this to a `Platform.Cron.Job` Ash resource**
  with the existing fields plus a `tenant_id` column (per §0.5.2)
  so jobs are tenant-scoped and the cross-tenant sweep at §4.5
  catches stray rows. Migration mirrors §1.6's import shape: read
  the YAML once, upsert by `(tenant_id, job_id)`, leave the file
  on disk as a backup. After migration, the `schedule_task` /
  `unschedule_task` tools write to Postgres; the persistence
  module is deleted.
- `.jido/heartbeat.md` — written every 60 seconds by
  `lib/jido_claw/heartbeat.ex` as a liveness signal for external
  monitors (the file's mtime is the heartbeat). Stays on disk —
  it's intentionally a sidecar that survives a database outage,
  which would defeat the purpose if it were promoted to Postgres.
  Document the classification here so the §4.5 sweep ignores it.
- Anything else surfaced during Phase 1–3 work — must be
  classified before the §4.5 sweep ships, with a one-line
  rationale (config / migrated / sidecar / other).

**Not under `.jido/` but in scope for the sweep:** ETS-backed
runtime registries (`JidoClaw.Tenant.Manager`,
`JidoClaw.Skills.Registry`) — these are covered by the
"Pre-existing cleanup debt" entry on global ETS / file-backed
stores; not migrated in v0.6.4 by design.

### 4.5 Acceptance gates

- `JidoClaw.Audit` and `JidoClaw.Tenants` appended to
  `config :jido_claw, :ash_domains`. Resources don't load without
  the domain entry.
- `mix ash.codegen --check` clean.
- `Tenants.Tenant` primary key is `:string` (text), not `:uuid`,
  per §4.2 step 1. The migration that promotes each resource's
  `tenant_id` text column to an FK is a single
  `ALTER TABLE … ADD CONSTRAINT … NOT VALID` plus
  `VALIDATE CONSTRAINT` per table — verified by reading the
  generated migration body, not just by it running.
- A regression test for the cross-tenant boundary: seed
  Workspaces / Sessions / Solutions / Memory rows under two
  tenant strings, run reads as each tenant via Ash policies
  (or the manual `tenant_id` filter for resources that opted
  out of Ash multitenancy), assert no row from the other
  tenant ever appears in any read.
- Audit log captures `:tool_call`, `:memory_write`,
  `:memory_consolidation`, `:solution_share`, `:session_start`,
  `:session_end`, `:auth_event` during a real session — verified
  by an integration test that drives each event source and
  asserts a row.
- **Audit cross-tenant isolation regression test.** Seed audit
  events under two tenants (`A` and `B`) covering each
  `event_kind`. Run `Audit.Event.read` as tenant `A`; assert no
  row carries `tenant_id = B` (and vice versa). Issue a target-
  scoped read (`target_kind: :memory_fact, target_id:
  <fact_in_A>`) as tenant `B`; assert it returns zero rows
  even though the underlying fact id is correct. Pins the
  Ash-policy enforcement plus the index-leading
  `tenant_id` shape from §4.1 — without either, audit search
  becomes a cross-tenant leak vector for whoever's tenant-
  scoping bug landed last in the codebase.
- **Audit cross-tenant FK validation test.** Construct an
  `Audit.Event.create` call with `tenant_id: A` but
  `target_kind: :memory_fact, target_id: <fact_in_B>`. Assert
  the create fails with `:cross_tenant_fk_mismatch`. Mirror
  shape against `:conversations_session`, `:solutions_solution`
  targets. Pins the §4.1 cross-tenant validation hook —
  audit events about cross-tenant rows are themselves
  cross-tenant leaks.
- The `Reasoning.Outcome` string-FK deprecation does not break
  any existing call site; consumers all read `workspace_uuid` /
  `session_uuid` and the strings are unused at runtime.
- A residual file-store sweep: walk `lib/`, assert no
  `File.write!`/`File.write` to `.jido/memory.json`,
  `.jido/solutions.json`, `.jido/reputation.json`,
  `.jido/sessions/`, or `.jido/cron.yaml` (post-v0.6.4 cron
  migration). Catches a stray writer that survived
  decommissioning. The sweep explicitly **excludes**
  `.jido/identity.json` and `.jido/heartbeat.md` — both stay on
  disk per §4.4's classification, and an unconditional ban
  would false-positive on the writers that are intentionally
  preserved.

---

## Cross-cutting concerns

### Generated columns

Three columns introduced by this plan are
`GENERATED ALWAYS AS (...) STORED`:

| Resource | Column | Expression | Phase |
|---|---|---|---|
| `Solutions.Solution` | `search_vector` | `to_tsvector('english', coalesce(solution_content, '') \|\| ' ' \|\| array_to_string(coalesce(tags, ARRAY[]::text[]), ' ') \|\| ' ' \|\| coalesce(language, '') \|\| ' ' \|\| coalesce(framework, ''))` | 1 |
| `Conversations.Message` | `search_vector` (optional) | `to_tsvector('english', coalesce(content, ''))` | 2 |
| `Memory.Fact` | `search_vector` | `to_tsvector('english', coalesce(label, '') \|\| ' ' \|\| content \|\| ' ' \|\| array_to_string(coalesce(tags, ARRAY[]::text[]), ' '))` | 3 |
| `Memory.Fact` | `content_hash` | `digest(content, 'sha256')` (requires `pgcrypto`) | 3 |

**AshPostgres has no migration-generator support for
`GENERATED ALWAYS AS … STORED` columns.** The migration generator
emits `add :col, :type` for any attribute it doesn't otherwise
recognise (a grep over `deps/ash_postgres/lib/migration_generator`
confirms zero matches for `GENERATED` literals); without
intervention, the migration creates a plain
`tsvector`/`bytea` column that's never populated, FTS silently
returns no matches, and the `unique_active_promoted_content_per_scope_*`
identity (§3.6) is never enforced because `content_hash` stays
NULL.

Each resource that declares one of these columns therefore ships
with a **hand-written migration patch**:

1. Run `mix ash.codegen <name>` to generate the resource
   migration.
2. Open the generated migration; replace the auto-generated
   `add :search_vector, :tsvector` (and equivalent for
   `content_hash`) with an `execute/1` block that runs the full
   `GENERATED ALWAYS AS (...) STORED` DDL. Example for
   `Solutions.Solution.search_vector`:

   ```elixir
   execute("""
   ALTER TABLE solutions
     ADD COLUMN search_vector tsvector
     GENERATED ALWAYS AS (
       to_tsvector(
         'english',
         coalesce(solution_content, '') || ' ' ||
         array_to_string(coalesce(tags, ARRAY[]::text[]), ' ') || ' ' ||
         coalesce(language, '') || ' ' ||
         coalesce(framework, '')
       )
     ) STORED
   """,
   "ALTER TABLE solutions DROP COLUMN search_vector"
   )
   ```

3. The Ash resource still declares the attribute (so reads can
   reference it through the Ash query layer); it just sets
   `writable?: false, generated?: true` so changesets don't
   try to set it.
4. The `pgcrypto` extension is added to
   `JidoClaw.Repo.installed_extensions/0` in the same Phase 3
   migration that introduces `content_hash`. Without it, the
   `digest()` function isn't available and the migration fails
   loudly — preferable to silent NULLs.
5. Snapshot drift: `mix ash.codegen --check` ignores the
   `execute/1` blocks (they aren't part of the resource
   declaration), so editing the migration won't trigger a "schema
   drifted" failure on subsequent runs. But it **will** silently
   regenerate a plain `add :search_vector, :tsvector` if a future
   resource change forces a new migration. The §1.8 / §2.7 / §3.19
   acceptance gates run an integration test that inserts a row and
   asserts the database populated the generated column — this is
   the only thing that catches drift between the resource
   declaration and the hand-edited migration.

### Partial identities

Several resources in this plan use partial unique indexes via
`identity ... do where(expr ...) end`. AshPostgres's migration
generator and upsert layer **require** every such identity to have
a corresponding entry in
`postgres.identity_wheres_to_sql`, mapping the identity name to a
literal SQL `WHERE` clause. Without it,
`mix ash_postgres.generate_migrations` fails with "Must provide an
entry for :{name} in postgres.identity_wheres_to_sql" (see
`deps/ash_postgres/lib/migration_generator/migration_generator.ex:4122`),
and `upsert_identity:` references at the action level fail with
the same error at compile time
(`deps/ash_postgres/lib/data_layer.ex:3460`).

The identities that need entries:

| Resource | Identity | SQL where |
|---|---|---|
| `Workspaces.Workspace` | `unique_user_path_authed` | `user_id IS NOT NULL` |
| `Workspaces.Workspace` | `unique_user_path_cli` | `user_id IS NULL` |
| `Conversations.Message` | `unique_import_hash` | `import_hash IS NOT NULL` |
| `Conversations.Message` | `unique_live_tool_row` | `request_id IS NOT NULL AND tool_call_id IS NOT NULL AND role IN ('tool_call', 'tool_result')` |
| `Memory.Block` | `unique_label_per_scope_user` | `tenant_id IS NOT NULL AND scope_kind = 'user' AND user_id IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Block` | `unique_label_per_scope_workspace` | `tenant_id IS NOT NULL AND scope_kind = 'workspace' AND workspace_id IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Block` | `unique_label_per_scope_project` | `tenant_id IS NOT NULL AND scope_kind = 'project' AND project_id IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Block` | `unique_label_per_scope_session` | `tenant_id IS NOT NULL AND scope_kind = 'session' AND session_id IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Fact` | `unique_active_label_per_scope_user` | `tenant_id IS NOT NULL AND scope_kind = 'user' AND user_id IS NOT NULL AND label IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Fact` | `unique_active_label_per_scope_workspace` | `tenant_id IS NOT NULL AND scope_kind = 'workspace' AND workspace_id IS NOT NULL AND label IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Fact` | `unique_active_label_per_scope_project` | `tenant_id IS NOT NULL AND scope_kind = 'project' AND project_id IS NOT NULL AND label IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Fact` | `unique_active_label_per_scope_session` | `tenant_id IS NOT NULL AND scope_kind = 'session' AND session_id IS NOT NULL AND label IS NOT NULL AND invalid_at IS NULL` |
| `Memory.Fact` | `unique_active_promoted_content_per_scope_user` | `tenant_id IS NOT NULL AND scope_kind = 'user' AND user_id IS NOT NULL AND source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL` |
| `Memory.Fact` | `unique_active_promoted_content_per_scope_workspace` | `tenant_id IS NOT NULL AND scope_kind = 'workspace' AND workspace_id IS NOT NULL AND source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL` |
| `Memory.Fact` | `unique_active_promoted_content_per_scope_project` | `tenant_id IS NOT NULL AND scope_kind = 'project' AND project_id IS NOT NULL AND source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL` |
| `Memory.Fact` | `unique_active_promoted_content_per_scope_session` | `tenant_id IS NOT NULL AND scope_kind = 'session' AND session_id IS NOT NULL AND source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL` |
| `Memory.Fact` | `unique_import_hash` | `import_hash IS NOT NULL` |

Each `identity` block also gets the matching Ash `where(expr ...)`
clause; the `identity_wheres_to_sql` value is the literal SQL form
used in the migration's partial index. Phase 0 / 2 / 3 each add
their respective rows. Acceptance gate per phase: `mix
ash_postgres.generate_migrations` runs without the
"identity_wheres_to_sql" error.

### Embedding cost budgeting

- `voyage-4-large`: $0.12/M input tokens
  ([Voyage pricing](https://docs.voyageai.com/docs/pricing)).
- `voyage-4`: $0.06/M input tokens.
- Per-Fact cost: depends on content length. A 200-token fact at
  $0.12/M is ~$0.000024 — orders of magnitude cheaper than a
  consolidator harness session, which is the dominant cost line
  for v0.6.3 (frontier model with high thinking effort, run per
  scope per cadence tick that clears the `min_input_count` gate).
- Daily cap configurable in `config :jido_claw,
  JidoClaw.Embeddings, :daily_token_cap, 10_000_000`.
- Telemetry surfaces cumulative spend; admin can see per-day cost.

### Test strategy

Per phase:
- **Resource tests** (`test/jido_claw/<domain>/<resource>_test.exs`)
  for every new resource — actions, validations, identities,
  bitemporal behavior.
- **Migration tests** under `test/jido_claw/<phase>_migration_test.exs`
  using fixtures.
- **Integration tests** that exercise the tool surface end-to-end
  (`remember` → `recall` round-trip, `find_solution` against migrated
  data).
- **Consolidator tests** with a fake harness adapter
  (`JidoClaw.Forge.Runners.Fake` — registered as a third runner
  via the same `harness:` config knob) that emits deterministic
  scripted tool-call sequences against the §3.15 scoped tool
  surface. Exercises every proposal branch (`propose_add`,
  `propose_update`, `propose_delete`, `propose_block_update`,
  `propose_link`, `defer_cluster`) plus failure modes (timeout,
  max_turns, harness exit non-zero, no `commit_proposals`). The
  scoped tool surface is the seam — tests don't need a real
  Claude Code or Codex CLI present to run.
- **Cache tests** verifying the frozen-snapshot prefix is byte-stable
  across turns when no Block write occurs.

Existing memory and solutions tests are adapted, not deleted —
they're the contract this migration must preserve. Per the audit,
that includes:
- `recall` substring semantics (now hybrid retrieval should be a
  superset).
- `remember` "latest write wins on read" semantics on the same
  `key` (now implemented via invalidate-and-replace inside a
  transaction rather than upsert; reads see the last-written
  value but prior values stay queryable for `as_of_world`).
- `find_solution` exact-signature short-circuit.

### Backwards compatibility for tool API

The `remember`, `recall`, `store_solution`, `find_solution` tool
schemas don't change. Their backing implementations swap out, but
the model-facing schema stays. Any prompt rewrites are scoped to
new tools (`forget`, `/memory blocks edit`).

### Pre-existing cleanup debt (track separately)

Items surfaced during this plan's review that are **not in scope for
v0.6** but should be tracked for a follow-up cleanup sprint. Listing
them here so they don't get re-discovered as "v0.6 regressions" — the
plan does not preserve them as design constraints, only documents
that the migration doesn't fix them either.

- **Worker templates do not inherit options from
  `JidoClaw.Agent`.** Each `lib/jido_claw/agent/workers/*.ex`
  declares its own `use Jido.AI.Agent, ...` block with its own
  options; `anthropic_prompt_cache: true` and the Recorder plugin
  must be added to each individually. Phase 2's acceptance gate
  (§2.7) catches this for the Recorder, but a longer-term fix is a
  shared `JidoClaw.Agent.Defaults` macro / helper module so options
  drift can't recur silently. Tracked outside v0.6.
- **`workspace_id` is overloaded as both a runtime key and a
  workspace identifier.** Today (and through v0.6 per §0.5.1)
  `tool_context.workspace_id == session_id`; shell sessions
  (`SessionManager.state.sessions`,
  `:jido_claw_ssh_sessions_active` ETS), VFS mounts
  (`MountTable`, `WorkspaceRegistry`), and profile state
  (`ProfileManager.@ets_active_env`) all key on it as a
  per-session runtime identifier. v0.6 introduces `workspace_uuid`
  as the new Ash FK so DB-side code stops reusing the runtime
  key, but de-overloading `workspace_id` itself — renaming it to
  a true workspace string and routing the per-session runtime key
  to a new `runtime_workspace_id` (or similar) field — is a
  coordinated refactor across Shell/VFS/Profile/file-tool
  consumers and is intentionally deferred. Track this for a
  follow-up sprint after v0.6.4. The `tool_context` shape note
  in §0.5.1 documents why folding it into v0.6 was rejected.
- **Sharing-enum vocabulary drift.** Earlier plan drafts used
  `:private | :workspace | :public | :network`; the actual code
  uses `:local | :shared | :public`
  (`lib/jido_claw/solutions/solution.ex:226-232`). The plan as
  rewritten preserves today's vocabulary to avoid layering an
  enum-rename migration on top of the data move. If a finer split
  is later wanted, that's a focused follow-up — flag this once
  v0.6.1 lands.
- **Path-based workspace identity.** `Workspaces.Workspace`
  uniqueness is `(user_id, path)`, with `path` a raw absolute
  filesystem string. A user moving a project, switching machines,
  or having two clones of the same repo at different paths gets
  distinct workspace rows. v0.6 inherits this; "stable workspace
  identity" (e.g. by remote git URL or a registered project alias)
  is a separate design problem.
- **Permissive Ash policies on existing resources.** Pre-existing
  resources (`Accounts`, `Projects`, `Forge.Domain`, etc.) ship
  with permissive default policies — anything that authenticates
  can read/write within scope today. v0.6.4 adds tenant-aware
  policies on the new resources (Memory / Solutions /
  Conversations), but a sweep of the older domains is a separate
  effort. The cross-cutting "Tenant column from Phase 0" (§0.5.2)
  sets the foundation for that sweep but doesn't perform it.
- **Global ETS / file-backed stores not in this plan's scope.**
  `JidoClaw.Tenant.Manager` (ETS), `JidoClaw.Skills.Registry`,
  `.jido/profiles/*.yaml`, `.jido/system_prompt.md`,
  `.jido/skills/*.yaml`, `.jido/strategies/*.yaml`,
  `.jido/pipelines/*.yaml`. Per §4.4, configuration files **stay**
  on disk; ETS-backed registries get reviewed but not migrated in
  v0.6. Document the boundary here so reviewers don't expect them
  in the migration.
- **`agent_id` as a string everywhere.** No `Agent` Ash resource
  exists; the FK promotion is deferred per the §1.3 note ("string
  for now, FK later"). A real `Agent` resource is a v0.7+
  conversation that touches the swarm tracker and per-agent
  reputation — out of scope here.
- **`Projects.Project` lacks a `tenant_id` column.**
  Pre-existing resource at `lib/jido_claw/projects/project.ex` —
  carries `name`, `github_full_name`, `default_branch`,
  `settings` but no `tenant_id`. Memory rows at
  `scope_kind: :project` and Workspaces with `project_id` set
  populate the FK but the §0.5.2 cross-tenant FK validation
  hook cannot compare against a column that doesn't exist.
  The hook emits a
  `:tenant_validation_skipped_for_untenanted_parent` telemetry
  event for `project_id` until the column is added in a
  follow-up sprint. Adding it is a one-line schema change plus
  a backfill from each project's owning workspace's tenant
  (Projects today are GitHub-link rows owned by a workspace,
  so the tenant is always derivable). Tracked outside v0.6.
- **`Forge.Resources.Session` lacks a `tenant_id` column.**
  Pre-existing resource at
  `lib/jido_claw/forge/resources/session.ex` — verified absent
  by reading the file at this plan's writing. §3.9
  `ConsolidationRun.forge_session_id` would benefit from the
  cross-tenant FK validation hook in §0.5.2, but the parent
  row has no `tenant_id` to compare against. Phase 3 documents
  this in the §3.9 action and pins it as prerequisite work for
  a Phase-4-or-later sweep that adds `tenant_id` to
  `Forge.Session` (and to the related `Forge.Event`,
  `Forge.Checkpoint`, `Forge.ExecSession` resources, by
  inspection of the same directory). When that lands, the
  §3.9 `:record_run` hook gains the `forge_session_id`
  validation branch in a follow-up — the hook's shape is
  ready for it. The same applies to any other pre-existing
  resource that Phase 3+ wires as a dependency: the cross-
  tenant FK hook is best-effort against pre-existing parents
  until they're tenanted.
- **Today's `Reasoning.Outcome` carries `workspace_id` /
  `agent_id` as strings.** Phase 0 adds a sibling FK (§0.5),
  Phase 4 deprecates the strings (§4.3). Calling out the
  string-FK coexistence so reviewers don't flag the duplication
  during Phases 1–3.
- **Tenant-ID shape fragmentation.**
  `JidoClaw.Tenant.new/1` (`platform/tenant.ex:32-34`) generates
  `tenant_<base64>` ids, but no caller in `lib/` currently
  exercises that branch — `lib/jido_claw/platform/tenant/manager.ex:54`
  hardcodes `id: "default"`, and the web/channel surfaces
  derive `tenant_id` from the user's UUID
  (`web/controllers/chat_controller.ex:15`,
  `web/channels/rpc_channel.ex:76`). The `tenant_id` text column
  added by §0.5.2 stores whatever string the runtime produced;
  Phase 4's FK promotion handles all three shapes uniformly. A
  follow-up sprint should either retire the unused
  `tenant_<base64>` generator or wire up a real tenant-creation
  flow that uses it; for v0.6 we just document that the live
  shapes are `"default"` + user UUID strings.
- **`Web/RPC tenant_id` conflates tenant with user.** Both
  `chat_controller.ex:15` and `rpc_channel.ex:76` set
  `tenant_id = to_string(current_user.id)` with an explicit
  comment that this is a stopgap. Phase 4's tenant-FK promotion
  inherits the conflation as a one-row-per-user tenant model,
  which is acceptable for v0.6 but should be untangled once the
  product story for organizations / teams lands.
- **`JidoClaw.Memory.remember/3` swallows store errors.** The
  current GenServer (`platform/memory.ex:121-130`) logs a warning
  on `@store.put` failure and returns `:ok` regardless. The new
  invalidate-and-replace flow in §3.6 wraps writes in a
  transaction and surfaces errors via `Ash.create/2`, so v0.6.3
  fixes this implicitly — but the test contract documented in
  §Testing strategy says "preserve `remember` semantics", so
  flagging here that the silent-error behavior is intentionally
  *not* preserved (it was a bug, not a feature).
- **Per-request session creation in the HTTP API.**
  `web/controllers/chat_controller.ex:35,68` generates
  `api_<int>` / `api_stream_<int>` session ids on **every
  request** via `:erlang.unique_integer([:positive])`, so each
  HTTP call creates a fresh `Conversations.Session` row with no
  continuity to prior calls. This is fine for one-shot REST
  hits but breaks down once any caller wants multi-turn context
  (every turn forks a new session). Phase 0 onwards stamps each
  per-request session with `kind: :api` so post-v0.6 the row
  is at least classifiable for cleanup; teaching the controller
  to honor a client-supplied session id (or sticky-cookie
  equivalent) is the actual fix and lives in a v0.7+ HTTP-surface
  cleanup. Document the intent here so reviewers don't expect
  v0.6 to fix it.
- **Cron `:main` mode reuses `agent_id` as session id.**
  `platform/cron/worker.ex:116` calls
  `JidoClaw.chat(state.tenant_id, state.agent_id, state.task)`
  for `:main`-mode jobs, so two cron jobs targeting the same
  agent within one workspace share a single
  `Conversations.Session` row by design. Phase 0's
  `unique_external` identity adds `workspace_id` to disambiguate
  cross-workspace agent_id reuse (per §0.4), but in-workspace
  reuse stays intentional — the cron contract says "stick all
  invocations of agent X into the same conversation thread."
  Surfacing this here so the per-row `kind: :cron` rows in
  Postgres aren't misread as a bug. A future surface for
  per-job isolated sessions (already present in `:isolated`
  mode) is out of scope.
- **Hardcoded `tenant_id: "default"` in Discord/Telegram
  channels.** `platform/channel/discord.ex:46` and
  `platform/channel/telegram.ex:45` both pass the literal string
  `"default"` to `chat/4`, so every Discord/Telegram message
  lands under the same tenant regardless of which guild/chat it
  came from. Functionally equivalent to today's behavior; v0.6.4
  inherits it and the tenant-FK promotion (§4.2) treats the
  string as one row. A real per-guild / per-chat tenant model is
  a v0.7+ product question — flagging that the migration does
  not retro-bind these surfaces to a multi-tenant identity.
- **`Reputation.recalculate_score/1` carries a likely-stale
  `0.5 * 0.3 = 0.15` constant floor.**
  `lib/jido_claw/solutions/reputation.ex:249` computes
  `raw = 0.5 * 0.3 + success_rate * 0.5 + activity_bonus +
  freshness * 0.1`. The `0.5 * 0.3` term has no remaining
  variable input — it's a `0.15` baseline that looks like the
  residue of an earlier weighting scheme. v0.6.1 lifts this
  formula into the public `Reputation.compute_score/1` (§1.3)
  *unchanged* to avoid a behavioral shift mid-migration; a
  follow-up sprint should either give the constant a real
  variable input (e.g. `prior_belief * 0.3`) or drop the term
  and re-baseline scores.
- **`Solutions.Store.find_by_signature/1` first-match semantics.**
  Today's ETS-backed store (`lib/jido_claw/solutions/store.ex`)
  uses `Enum.find` on a `tab2list` to return the first row
  matching a `problem_signature`, even though signatures
  legitimately collide (different solutions to the same problem).
  v0.6.1 preserves the legacy `id` per §1.6 step 5 so callers
  that cached an id can still find their row, but Stage-1
  retrieval moves to the §1.5 RRF query, which surfaces *all*
  matching candidates. The `find_by_signature` first-match
  contract becomes legacy on entry and should be removed once
  callers migrate to `:by_signature` (which returns the full
  list per §1.2). Track the deletion sweep separately.

### Rollout sequencing

Each phase ships as a point release (`v0.6.0`, `v0.6.1`, …). No phase
is required to ship before its successor's work begins, but phases
must be **deployed** in order — Phase 1's data layer assumes Phase 0
ran.

For development branches, every phase passes:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test` (full suite)
- `mix ash.codegen --check` (no pending resource changes). Note:
  earlier drafts referenced `mix ash_postgres.migrations`, which is
  not a real task — the available `ash_postgres.*` tasks in this
  project are `create`, `drop`, `gen.resources`,
  `generate_migrations`, `install`, `migrate`, `rollback`,
  `setup_vector`, and `squash_snapshots`.

---

## Open questions

These eight items were resolved during plan review; recorded here
for traceability rather than as ongoing decisions. None block
starting Phase 0.

1. **Voyage 4 embedding dimension → 1024.** Stay on the default;
   §1.4 already pins `output_dimension: 1024` in the request
   envelope so the `vector(1024)` column shape and the
   live-request shape can never drift. Lower (256/512) costs less
   storage but loses recall on a corpus that isn't storage-bound;
   2048 doubles cost for marginal gain. Boot-time sanity check
   added: assert `voyage-4` and `voyage-4-large` both honour the
   pinned dimension so retrieval and storage embeddings stay
   in the same vector space.
2. **Consolidator LLM model choice → frontier model via Forge
   harness.** Replaces the original "agent's `:fast` model" plan.
   The consolidator runs as a Forge session (`runner: :claude_code`
   or `:codex`) with the most capable model the user has
   configured — default `claude-opus-4-7` at `thinking_effort:
   xhigh`. See the §3.15 rewrite for the architectural
   consequences (single agentic session per run, scoped MCP tool
   surface, transactional commit gate, `min_input_count` pre-flight
   gate to absorb the cost of running every 6 hours on quiet
   scopes). 6-hour cadence stays as designed; consolidator stays
   enabled-by-default — many scheduled ticks will skip via the
   pre-flight gate without invoking the harness, so the cost
   profile is bounded by activity, not cadence.
3. **Block label vocabulary → seed five, treat as conventions.**
   Phase 3 ships with `user_preferences`, `user_profile`,
   `project_conventions`, `agent_persona`, `current_focus`.
   Documented as conventions, not enums — the schema stores label
   as free-form text so users and skills can introduce new labels
   without a migration.
4. **Memory cache GenServer fate → no new cache in Phase 3.**
   The §3.14 frozen-snapshot prompt is the actual hot-path win;
   after it lands, prompt builds don't hit Postgres per turn.
   Remaining queries (Recall tool, `/memory` commands, write
   paths) aren't turn-frequency hot, and Block tables stay tiny
   (one row per scope+label). Add an ETS layer only if Phase 3
   telemetry shows a real bottleneck — premature caching here
   creates an invalidation problem on Block writes.
5. **AshAdmin exposure → read-only in Phase 3.** Avoids
   bypassing `:before_action` hooks (content-hash dedup,
   scope-FK denormalization, BlockRevision audit trail). Phase 4
   may expose validated *action invocation* (`:promote`,
   `:invalidate`, `:user_save`) once the audit log lands and
   operators have a documented escape hatch for fixing corrupt
   rows.
6. **Quantum vs existing scheduler → extend
   `JidoClaw.Cron.Scheduler`.** Already supports cron
   expressions (via the `crontab` transitive dep through `jido`)
   and per-tenant supervision via `Tenant.InstanceSupervisor`.
   Add a `start_system_jobs/0` entry point at app boot that
   registers the consolidator as a system-level cron job —
   distinct from user-defined `.jido/cron.yaml` jobs. No new
   dependency, consistent with existing tenant-scoped supervision.
7. **Consolidator concurrency → 4 stays the default.** Bound on
   simultaneous Forge sessions per node. Document in the
   deployment runbook that this is a per-node limit, not a
   global one — multi-node libcluster deployments effectively
   multiply this by node count, and the per-scope advisory lock
   keeps that safe.
8. **JSONL deletion timeline → manual `mix jido_claw.cleanup.legacy_files`
   with `--verify`.** Never automatic. Default behaviour:
   verify every JSONL row maps to a Postgres row (counts +
   row-level fingerprints), prompt for confirmation, then
   delete. `--verify-only` reports mismatches without deleting;
   `--force` skips verification as the escape hatch for users
   who've already audited. Lets users base the "I trust the
   migration" decision on evidence rather than vibes.

---

## Out of scope

Explicitly not in v0.6:

- Cross-tenant memory sharing or marketplace.
- Real-time collaborative memory editing.
- Federated/distributed memory across nodes (beyond what `:pg` and
  Postgres already provide).
- Voice/multimodal episode capture.
- Custom embedding models per-workspace.
- Self-improving consolidator (consolidator that learns from past
  ADD/DELETE outcomes). Could be a v0.6.x or v0.7 follow-up.
- ML-based importance scoring on Facts. Trust score is sufficient
  for v0.6.
- Replace AshPaperTrail's role in audit (already used for
  resource-level audit on selected resources; Phase 4 audit log is
  the broader event log).
- Memory export/import as a user-facing feature. Migration is
  internal.

---

## Build order recap

```
v0.6.0  Foundation       Workspace + Conversation.Session resources, FK plumbing
v0.6.1  Solutions        Migrate Solutions + Reputation; FTS + pgvector;
                         Reputation wired into Trust.compute
v0.6.2  Conversations    Migrate chat transcripts; capture tool calls + reasoning;
                         redaction at write
v0.6.3  Memory           Block / Fact / Episode / Link / ConsolidationRun resources;
                         multi-scope, bitemporal, frozen-snapshot prompt;
                         scheduled consolidator running as a Forge harness session
                         (Claude Code or Codex, frontier model + xhigh thinking)
                         with scoped ADD/UPDATE/DELETE/NOOP tool surface
v0.6.4  Audit & Tenant   Audit log; real Ash multitenancy; deprecate string-id
                         siblings; cleanup tasks
```

The migration is gated on actual need — don't migrate file-based
stores ahead of demand. The roadmap signal that triggered this work
is real (Memory/Solutions search is naive; transcript fidelity is
poor; scope plumbing is string-keyed). Each phase delivers
independently observable improvement.
