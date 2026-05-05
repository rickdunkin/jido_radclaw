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
v0.6.0   Foundation       Workspace + Conversation.Session resources, FK plumbing
v0.6.1   Solutions        Migrate Solutions + Reputation to Ash, add FTS + pgvector
v0.6.2   Conversations    Migrate chat transcripts to Postgres with full fidelity
v0.6.3a  Memory data      Block/Fact/Episode/Link/ConsolidationRun resources, retrieval, writes
v0.6.3b  Memory consol.   Scheduled consolidator (Claude Code harness), frozen-snapshot prompt
v0.6.3c  Memory codex     Codex sibling runner for the consolidator
v0.6.4   Audit & Tenant   Audit log, real Ash multitenancy, residual file-store cleanup
```

Each phase is independently reviewable and ships as its own point
release; phases must run in order: Phase 1 needs the foundation FKs
from Phase 0; the consolidator in Phase 3b needs queryable
transcripts from Phase 2 plus the data-layer resources from 3a;
3c needs 3b's runner orchestration.

**On Phase 3's split.** The original `phase-3-memory.md` was a
single 1,902-line spec covering the entire Memory rewrite. During
implementation planning it was sliced along the consolidator
boundary into three sub-phases (3a data layer, 3b consolidator +
frozen-snapshot prompt, 3c Codex runner) so each ships as a
reviewable PR with `main` release-able in between. The original
file is preserved as an index pointing at the three sub-phase docs;
all source-plan section numbering (§3.1, §3.6, §3.13, …) is kept
verbatim across the splits so cross-phase references in Phase 0 /
1 / 2 / 4 keep resolving.

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

## Phase documents

Each phase ships as its own point release; deploy in order.

- [Phase 0 — Foundation](phase-0-foundation.md): `Workspace` and `Conversation.Session` Ash resources; FK plumbing for tenant + workspace + session.
- [Phase 1 — Solutions](phase-1-solutions.md): migrate Solutions + Reputation to Ash; FTS + pgvector hybrid retrieval; Reputation wired into `Trust.compute`.
- [Phase 2 — Conversations](phase-2-conversations.md): JSONL → Postgres; capture tool calls, tool results, reasoning; redaction at write.
- **Phase 3 — Memory** ([index](phase-3-memory.md)) ships in three
  sub-releases:
  - [Phase 3a — Memory: Data Layer & Retrieval](phase-3a-memory-data.md):
    multi-scope, bitemporal `Block` / `Fact` / `Episode` /
    `FactEpisode` / `Link` / `ConsolidationRun` resources; hybrid
    retrieval (FTS + pgvector + trigram via RRF); model and user
    write paths; tool surface (`Remember`, `Recall`, `Forget`);
    CLI (`/memory blocks`, `list`, `search`, `save`, `forget`);
    embedding pipeline; migration + rollback-export tasks; legacy
    GenServer decommissioning.
  - [Phase 3b — Memory: Consolidator Runtime & Frozen-Snapshot
    Prompt](phase-3b-memory-consolidator.md): scheduled
    consolidator with per-scope advisory locks, watermark
    resolution, in-memory clustering, Forge harness session via
    Claude Code with an in-process HTTP scoped MCP server hosting
    the eleven proposal tools, transactional staged-publish; the
    frozen-snapshot system prompt rewrite that lets
    `anthropic_prompt_cache: true` fire across turns;
    `Cron.Scheduler.start_system_jobs/0`; per-session
    `sandbox_mode` knob; `/memory consolidate` + `/memory status`
    CLI.
  - [Phase 3c — Memory: Codex Sibling Runner](phase-3c-memory-codex.md):
    `JidoClaw.Forge.Runners.Codex` sibling runner so the
    consolidator's `harness:` config knob accepts `:codex`.
- [Phase 4 — Audit & Tenant](phase-4-audit-tenant.md): audit log; real Ash multitenancy; deprecate string-id siblings; cleanup tasks.

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
v0.6.0   Foundation       Workspace + Conversation.Session resources, FK plumbing
v0.6.1   Solutions        Migrate Solutions + Reputation; FTS + pgvector;
                          Reputation wired into Trust.compute
v0.6.2   Conversations    Migrate chat transcripts; capture tool calls + reasoning;
                          redaction at write
v0.6.3a  Memory data      Block / Fact / Episode / FactEpisode / Link /
                          ConsolidationRun resources; multi-scope + bitemporal;
                          hybrid retrieval (RRF over FTS + pgvector + trigram);
                          model + user write paths; CLI; migration; legacy
                          GenServer decommissioning
v0.6.3b  Memory consol.   Scheduled consolidator running as a Forge harness
                          session (Claude Code, frontier model + xhigh thinking)
                          with an in-process HTTP scoped MCP server exposing the
                          ADD/UPDATE/DELETE/NOOP/LINK proposal tool surface;
                          frozen-snapshot system prompt that lets
                          `anthropic_prompt_cache: true` fire across turns;
                          `/memory consolidate` + `/memory status` CLI
v0.6.3c  Memory codex     Codex sibling runner so the consolidator's `harness:`
                          knob accepts `:codex`; same orchestration as 3b
v0.6.4   Audit & Tenant   Audit log; real Ash multitenancy; deprecate string-id
                          siblings; cleanup tasks
```

The migration is gated on actual need — don't migrate file-based
stores ahead of demand. The roadmap signal that triggered this work
is real (Memory/Solutions search is naive; transcript fidelity is
poor; scope plumbing is string-keyed). Each phase delivers
independently observable improvement.
