# Phase 1 — Solutions migration with FTS + pgvector

**Goal:** retire `JidoClaw.Solutions.Store` ETS+JSON, swap to Ash +
Postgres, replace Stage-1 token-coverage scoring with hybrid FTS +
cosine retrieval, decide the Reputation ledger's fate, and prove out
the migration shape on the simpler of the two stores.

## 1.0 Prerequisites: pgvector and pg_trgm setup

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

## 1.1 New domain: `JidoClaw.Solutions.Domain`

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

## 1.2 `Solutions.Resources.Solution` resource

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

## 1.3 `Solutions.Resources.Reputation` resource — and wire it up

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

## 1.4 Embeddings pipeline

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

## 1.5 Hybrid retrieval (Stage-1)

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

## 1.6 Migration script

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

## 1.7 Decommissioning

- `JidoClaw.Solutions.Store` GenServer removed from supervision.
- `JidoClaw.Solutions.Reputation` GenServer removed from supervision.
- ETS tables dropped.
- `.jido/solutions.json` and `.jido/reputation.json` left on disk
  (don't delete user data); add a one-line README in `.jido/` noting
  they're deprecated.

## 1.8 Acceptance gates

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

