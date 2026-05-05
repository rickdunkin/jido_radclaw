# Phase 3a — Memory: Data Layer & Retrieval

**Goal:** ship the multi-scope, bitemporal Memory data layer
(resources, schema, hybrid retrieval, write paths, tool/CLI
surface) without the consolidator harness. After 3a, agents can
`remember` / `recall` / `forget` Facts in Postgres, the legacy
`JidoClaw.Memory` GenServer is gone, the `Memory.Block` tier
exists and is editable via `/memory blocks edit`, and migration
tasks let users move data off `.jido/memory.json`.

## 3a.0 Scope and dependencies

### What 3a ships

- §3.1-§3.13 — domain layout, scope/bitemporal columns, all seven
  Memory resources (`Block`, `BlockRevision`, `Fact`, `Episode`,
  `FactEpisode`, `Link`, `ConsolidationRun`), write paths, tool
  API (`Remember`, `Recall`, `Forget`), CLI (`/memory blocks`,
  `list`, `search`, `save`, `forget`), retrieval API.
- §3.16 — embeddings pipeline (`Memory.Fact.embedding` populated
  by the existing `Embeddings.BackfillWorker` extended to a second
  resource).
- §3.17 — migration `mix jidoclaw.migrate.memory` and the
  rollback-export task `mix jidoclaw.export.memory`.
- §3.18 — decommissioning of the legacy `JidoClaw.Memory` GenServer
  and `Jido.Memory.Store.ETS` dep cleanup.
- The data-layer subset of §3.19 acceptance gates.

### Out of scope (deferred to 3b/3c)

- §3.14 — frozen-snapshot system prompt rewrite (3b).
- §3.15 — consolidator design and harness session orchestration (3b).
- `/memory consolidate` and `/memory status` CLI commands (3b —
  they drive the consolidator).
- `JidoClaw.Forge.Runners.Codex` sibling runner (3c).
- Acceptance gates that drive the consolidator harness or assert
  prompt-cache hits (3b/3c).

### Dependencies on prior phases

- **Phase 0 (`v0.6.0`):** `Workspaces.Workspace` (with
  `embedding_policy`, `consolidation_policy`),
  `Conversations.Session`, `Accounts.User`.
  `Workspaces.Resolver.ensure_workspace/3` is the actual function
  name (the source plan §3.17 says "ensure/1", which is wrong).
- **Phase 1 (`v0.6.1`):** `Solutions.Solution` resource and the
  patterns Memory mirrors — `HybridSearchSql` pool shape,
  `SearchEscape.escape_like/1` + `lower_only/1`,
  `Embeddings.Voyage` (real surface is `embed_for_storage/{1,2}`
  and `embed_for_query/{1,2}`, **not** `embed/2`),
  `Embeddings.Local`, `BackfillWorker`, `PolicyResolver`,
  `RatePacer`, `DispatchWindow`. Redaction modules: `Patterns`
  (URL-userinfo extension already shipped),
  `Embedding.redact/1` (returns `{redacted, count}`, not a bare
  string), `Transcript.redact/2` (with `:json_aware_keys` opt,
  default `[]`).
- **Phase 2 (`v0.6.2`):** `Conversations.Message` (writable
  `inserted_at`, `import_hash` partial identity, `:append`/`:import`
  actions, the `Changes.RedactContent` + `Changes.AllocateSequence`
  + `Changes.DenormalizeTenant` + `Changes.ValidateCrossTenantFk`
  nested-module pattern), `Recorder` GenServer subscribing to
  `ai.*` SignalBus topics. Existing mix-task namespace is
  `mix jidoclaw.*` (single-word `jidoclaw`); the source plan
  references `mix jido_claw.*` in places — Phase 3 follows the
  existing convention.

### Implementation discoveries (additions to the source plan)

Surfaced during reconnaissance against the v0.6.0/v0.6.1/v0.6.2
baseline:

- **`pgcrypto` extension is missing.**
  `JidoClaw.Repo.installed_extensions/0` returns
  `["ash-functions", "citext", "pg_trgm", "vector"]` today; the
  Phase 3a migration must add `pgcrypto` so
  `Memory.Fact.content_hash`'s `digest(content, 'sha256')`
  generated column compiles. Without it the migration fails loudly
  at `CREATE TABLE` rather than silently NULL'ing the column —
  preferable to the latter, but the extension addition is the
  fix.
- **`tool_context` schema stays unchanged.**
  `JidoClaw.ToolContext` carries no `:scope_kind` or `:project_id`
  today; rather than churn every caller, `Memory.Scope.resolve/1`
  derives `scope_kind` and the FK chain from the populated context
  keys at call time. The wrapper from §3.10
  (`remember_from_model/2`, `remember_from_user/2`) calls
  `Scope.resolve/1` first and threads the resolved record into
  `Memory.Fact.create :record`. Source plan §3.6 references
  `ctx.scope_kind` directly; reading that as "the wrapper resolves
  scope from context, then sets `scope_kind` on the changeset"
  preserves the spec without touching `ToolContext`.
- **Cross-tenant FK validation is inlined per-resource today.**
  Each of `Conversations.Message`, `Solutions.Solution`,
  `Conversations.Session` defines its own nested
  `Changes.ValidateCrossTenantFk`. Memory ships seven resources
  doing the same dance, so 3a adds a shared helper at
  `lib/jido_claw/security/cross_tenant_fk.ex` rather than
  duplicating the validator seven times. Existing inline copies
  stay untouched (no refactor sweep).
- **`Voyage` API surface is `embed_for_storage/{1,2}` +
  `embed_for_query/{1,2}`,** not `embed/2`. Source plan §3.16
  wording was approximate; Memory's embedding pipeline calls the
  real functions.
- **`Embedding.redact/1` returns `{redacted, count}`,** not just
  the redacted string. Memory's pipeline destructures.
- **`Transcript.redact/2` takes `:json_aware_keys` opt** (default
  `[]`). The new `Redaction.Memory.redact_fact!/1` (§3.10) wraps
  `Transcript.redact/2` with the right opt list for Fact
  `metadata` jsonb scrubbing.
- **Mix task namespace is `mix jidoclaw.*`** (single-word). The
  migration is `mix jidoclaw.migrate.memory`; export is
  `mix jidoclaw.export.memory`. Source plan §3.17 / §3.19 reference
  `mix jido_claw.*` — Phase 3a follows the
  `mix jidoclaw.export.conversations` precedent shipped in v0.6.2.
- **`Memory.HybridSearchSql` uses RRF; `Solutions.HybridSearchSql`
  uses weighted-sum.** Phase 3 SQL pseudocode in §3.13 is RRF
  (`1.0/(60+r)` per pool); Solutions today is
  `0.4*fts + 0.4*ann + 0.2*lex`. Memory ships RRF as specified;
  Solutions is **not** refactored in Phase 3 (out of scope; a
  follow-up sprint can reconcile).
- **IMMUTABLE wrapper functions** for the generated-column
  expressions follow the Solutions Phase 1 pattern. Phase 3a's
  migration ships `memory_search_vector(label, content, tags)` and
  `memory_lexical_text(label, content, tags)` as `LANGUAGE SQL
  IMMUTABLE` functions, invoked from the
  `GENERATED ALWAYS AS (memory_*(...)) STORED` clauses.
- **`Workspace.consolidation_policy`** already exists with the
  right shape (`:default | :local_only | :disabled`, default
  `:disabled`). 3a doesn't consume it (consolidator is in 3b);
  listed here so 3b's plan can rely on its presence.
- **CLI compatibility for `Memory.list_recent/1` consumers.** Today
  `lib/jido_claw/agent/prompt.ex:427` (the prompt builder) and
  `lib/jido_claw/cli/commands.ex:225` call `Memory.list_recent(20)`
  expecting `%{key, content, type, created_at, updated_at}` maps.
  The new `JidoClaw.Memory.recall/2` (3a) returns the same map
  shape so the CLI presenter
  (`lib/jido_claw/cli/presenters.ex:68 format_memory_results/1`)
  keeps working unchanged. The `prompt.ex` consumer is removed in
  3b when the snapshot rewrite drops `memories_section/1`.
- **No `Memory.Forget` tool exists today** (only the
  `/memory forget` REPL command + the direct `Memory.forget/1`
  API). 3a creates it from scratch and registers it in
  `lib/jido_claw/agent/agent.ex`'s tool list.
- **`JidoClaw.Memory.remember/3` swallows `@store.put` errors** at
  `lib/jido_claw/platform/memory.ex:121-130`. 3a's `:record` action
  surfaces errors via `Ash.create/2`. The public `remember_from_*`
  wrappers preserve today's always-`:ok` external contract
  (callers in `tools/remember.ex:42` and `cli/commands.ex:209`
  rely on it) but log errors via `Logger` instead of dropping
  them silently.

---

## 3.1 Domain layout

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

## 3.2 Multi-scope schema (shared across all resources)

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

## 3.3 Bitemporal columns (shared)

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

## 3.4 `Memory.Block` — curated tier

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

## 3.5 `Memory.BlockRevision` — append-only history

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

## 3.6 `Memory.Fact` — searchable tier

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

## 3.7 `Memory.Episode` — immutable provenance

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

## 3.7.1 `Memory.FactEpisode` — fact ↔ episode join

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

## 3.8 `Memory.Link` — graph edge

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

## 3.9 `Memory.ConsolidationRun` — watermark + audit

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

## 3.10 Write paths

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

## 3.11 Tool API (model-facing)

| Tool | Action | Notes |
|---|---|---|
| `remember` | Existing API preserved (key/content/type) | Internal mapping: `key` → `Fact.label`, `content` → `Fact.content`, `type` → `Fact.tags`. Calls `Memory.remember_from_model/2`. Re-`remember` of the same `key` invalidates the prior `(label, scope, source: :model_remember)` row (sets its `invalid_at`/`expired_at`, preserves `valid_at`) and inserts a fresh active row in the same transaction — preserves today's "latest write wins on read" contract from `JidoClaw.Memory.remember/3` while keeping prior values queryable for bitemporal time-travel reads. |
| `recall` | Existing API preserved (query/limit) | Hybrid retrieval against Fact tier with auto-resolved scope from `tool_context`. |
| `forget` | New | Soft-invalidate via `Fact.invalidate_by_id/1` (preferred — no ambiguity) or `Fact.invalidate_by_label/1`. The label form scopes to **the model's own writes** (`source: :model_remember`) only — a model invoking `forget("api_key")` should not be able to delete the user's `:user_save` row sharing the same label. The CLI command (3.12) handles user-facing label invalidation with explicit source resolution. |

The `remember` schema doesn't change — it's the stored type that
shifts to Fact. Existing prompt instructions don't need to be
rewritten for v0.6.0 → v0.6.3.

## 3.12 CLI API (user-facing)

| Command | Purpose |
|---|---|
| `/memory blocks` | List Blocks for current scope |
| `/memory blocks edit <label>` | Open editor on block value |
| `/memory list` | Recent Facts (preserved) |
| `/memory search <q>` | Hybrid search (preserved, now FTS+vector) |
| `/memory save <label> <content>` | User-write to Fact (preserved) |
| `/memory forget <label> [--source model\|user\|all]` | Soft-invalidate. `--source` defaults to `user` (matches today's intuition: `/memory save` is the inverse of `/memory forget`). When multiple active facts share the label across sources in the current scope chain and no `--source` was passed, the CLI lists them and prompts for selection rather than guessing. `forget --source all <label>` invalidates every active fact at that label/scope across sources. |

## 3.13 Retrieval API

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

## 3.16 Embeddings pipeline

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

## 3.17 Migration: `.jido/memory.json` → Postgres

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

## 3.18 Decommissioning

- `JidoClaw.Memory` GenServer deleted; `JidoClaw.Memory` namespace now
  refers to the Ash-backed module surface.
- `Jido.Memory.Store.ETS` still in use? Check; if not, drop the dep
  (`{:jido_memory, ...}` in `mix.exs`).
- `.jido/memory.json` left on disk as backup.


## 3.19 Acceptance gates (data-layer subset)

This is the subset of source-plan §3.19 that Phase 3a must clear.
Gates that exercise the consolidator harness, the frozen-snapshot
prompt cache, or the Codex sibling runner ship in 3b/3c.

- All current memory-related tests adapted and green.
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

- New `/memory blocks` command (with `edit <label>` editor flow)
  functional. The split-gate companion for `/memory consolidate`
  and `/memory status` ships in 3b alongside the consolidator.
