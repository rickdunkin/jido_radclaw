# Phase 1 — Solutions migration: implementation plan (revised)

## Context

`docs/plans/v0.6/phase-1-solutions.md` is the spec for retiring
`JidoClaw.Solutions.Store` (ETS + JSONL) and replacing it with an Ash
domain on Postgres, layering FTS + pgvector + pg_trgm hybrid retrieval,
and wiring the dormant Reputation system into the verification path.
The motivation is threefold:

- **Today's stack doesn't compose.** ETS is per-node (so the cluster
  can't share a corpus), JSON files key by `project_dir` (so a tenant
  flip silently leaks rows), and substring `String.contains?` search
  produces poor matches once the corpus grows beyond a few dozen rows.
- **v0.6's Phase 0 already shipped the foundation** — Workspaces,
  Conversations.Session, ToolContext, the cross-tenant FK invariant —
  but nothing consumes those new scope columns yet. Phase 1 is the
  first phase that *uses* the foundation, and the migration shape it
  proves out is the template Phases 2–3 will follow.
- **Reputation has been built but never wired.** 361 LOC of working
  code feeds a `:agent_reputation` opt that no caller populates;
  closing that loop is the single largest qualitative win available
  during this migration.

User decisions (from clarifying-question pass):

1. **Voyage API key** — `System.get_env("VOYAGE_API_KEY")` at request
   time (Ollama precedent). No SecretRef row, no Cloak encryption-at-
   rest. The plan's "via Vault" wording is documentation drift.
2. **Mix task name** — `mix jidoclaw.migrate.solutions`
   (`Mix.Tasks.Jidoclaw.Migrate.Solutions`), matching the existing
   one-word `Mix.Tasks.Jidoclaw` convention.
3. **Slicing** — one bundled PR.
4. **Cutover** — single hard cutover.

Review revisions integrated below — each is called out at the spot it
applies, with verification notes against the deps and codebase.

## Phase 0 reuse and gaps

Verified against the codebase. **Reused as-is:**

- `JidoClaw.Workspaces.Workspace` (verified — note the module is
  **flat**, not `Workspaces.Resources.Workspace`; the directory
  `workspaces/resources/` is nested but the module name follows the
  existing v0.6 convention of flat namespacing) carries
  `embedding_policy` and `consolidation_policy` (default `:disabled`)
  with `set_embedding_policy` / `set_consolidation_policy` update
  actions
  (`lib/jido_claw/workspaces/resources/workspace.ex:86-106, 157-169`).
  Note: both actions are `update` actions — the code-interface
  signature is `Workspace.set_embedding_policy(workspace_struct,
  policy)`, **not** `(workspace_uuid, policy)`. CLI surfaces with
  only a UUID must `Ash.get!(JidoClaw.Workspaces.Workspace, uuid,
  domain: JidoClaw.Workspaces.Domain)` first. See Stream 11 for the
  wizard flow consequence.

  **Naming convention applies to the new Solutions resources too.**
  The new resource modules are `JidoClaw.Solutions.Solution`,
  `JidoClaw.Solutions.Reputation`, `JidoClaw.Solutions.ReputationImport`
  (flat namespace), each at `lib/jido_claw/solutions/resources/<name>.ex`
  (nested directory). These reuse the legacy module names exactly —
  the legacy struct (`Solution`) and GenServer (`Reputation`) are
  deleted in the same change that introduces the resources, so the
  module name swap is clean and there's never two `JidoClaw.Solutions.Solution`
  modules at once.
- `JidoClaw.Workspaces.Resolver.ensure_workspace/3` —
  `lib/jido_claw/workspaces/resolver.ex:17-42`. Already invoked from
  `lib/jido_claw.ex:104`, REPL `lib/jido_claw/cli/repl.ex:508`,
  `lib/jido_claw/web/channels/rpc_channel.ex:58`. The plan's
  `WorkspaceResolver.ensure/1` is stale — we use `ensure_workspace/3`.
- `JidoClaw.Conversations.Session` cross-tenant FK
  before_action hook
  (`lib/jido_claw/conversations/resources/session.ex:73-98`) —
  Solutions resources mirror the inline pattern.
- `JidoClaw.ToolContext` 7-key shape
  (`lib/jido_claw/tool_context.ex:31-39`).
- `JidoClaw.TaskSupervisor`, `JidoClaw.Finch`, `JidoClaw.Telemetry`.
- `JidoClaw.Security.Redaction.Patterns` — extended (not replaced) to
  add the URL-userinfo pattern lifted from
  `lib/jido_claw/security/redaction/env.ex:37`.
- `mix ash_postgres.generate_migrations` — used for the resource
  migration; index migrations are committed alongside.
- Domain layout convention: nested
  (`lib/jido_claw/<subsystem>/domain.ex` plus
  `<subsystem>/resources/*.ex`).
- `code_interface` declared on each resource (matches every v0.6
  resource).

**Confirmed available types:**

- `Ash.Type.Vector` registered as builtin `:vector`
  (`deps/ash/lib/ash/type/vector.ex:29`); accepts `dimensions`
  constraint. The Solutions resource uses `attribute :embedding,
  :vector, constraints: [dimensions: 1024]`.
- `AshPostgres.Tsvector`
  (`deps/ash_postgres/lib/types/tsvector.ex:5`); the Solutions
  resource uses `attribute :search_vector, AshPostgres.Tsvector`.
  **Plain `:tsvector` is not a built-in Ecto type** — the earlier
  draft was wrong about this.

**Gaps Phase 1 fills:**

- `JidoClaw.Repo.installed_extensions/0` extends to add `"vector"`
  and `"pg_trgm"` (currently `["ash-functions", "citext"]`).
- `JidoClaw.PostgrexTypes` module + `types: JidoClaw.PostgrexTypes`
  under `config :jido_claw, JidoClaw.Repo`.
- `JidoClaw.Security.Redaction.Embedding` and
  `JidoClaw.Security.Redaction.Transcript` — neither exists.
- `lib/jido_claw/embeddings/` — entire stack is greenfield.
- Tools (`store_solution`, `find_solution`, `verify_certificate`)
  read `tool_context` for scope; they currently take `_context`.
- **`Req` is currently a transitive dep only** — added as a direct
  `mix.exs` dep alongside the new Voyage client.

**Verified post-review** — additional Solutions consumers that must
swap from `Solutions.Store` / `%Solutions.Solution{}` to the new
code interface:

- `lib/jido_claw/cli/commands.ex:256, 280` — `/solutions` REPL
  command (search and stats).
- `lib/jido_claw/shell/commands/jido.ex:105` — `jido solutions find`
  shell command.
- `lib/jido_claw/tools/verify_certificate.ex:55, 219, 222` — alias
  + lookup + the "Solution store is not running" error path.
- `lib/jido_claw/cli/presenters.ex:11, 20` — typespecs against
  `%JidoClaw.Solutions.Solution{}`; presenter consumes the struct.
- `lib/jido_claw/network/protocol.ex:105` — docstring reference (no
  behavior change, but update the comment).
- `lib/jido_claw/reasoning/classifier.ex:18` — uses
  `Solutions.Fingerprint`. Fingerprint is preserved as a pure
  module, so this caller is unaffected, but the import line is
  worth verifying.

## Execution sequence

One PR. Twelve work streams in dependency order. Each stream lands
its tests before the next so a regression bisect stays tight.

### Stream 1 — Postgres extensions and Postgrex types

`mix ash_postgres.setup_vector` is **a no-op in the installed
ash_postgres 2.9.0** (the igniter body at
`deps/ash_postgres/lib/mix/tasks/ash_postgres.setup_vector.ex:46-50`
returns the unchanged igniter — see the commented-out warning at
line 49). The plan does the four manual steps explicitly:

1. `lib/jido_claw/repo.ex` — `installed_extensions/0` becomes
   `["ash-functions", "citext", "pg_trgm", "vector"]`.
2. `lib/jido_claw/postgrex_types.ex` — single-line file (NOT inside
   a `defmodule`):
   ```elixir
   Postgrex.Types.define(
     JidoClaw.PostgrexTypes,
     [AshPostgres.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
     []
   )
   ```
   Verified shape via `deps/ash_postgres/lib/extensions/vector.ex:9-20`.
3. `config/config.exs` — under `config :jido_claw, JidoClaw.Repo,
   ...` add `types: JidoClaw.PostgrexTypes`.
4. Run `mix ash_postgres.generate_migrations` — picks up the
   extended `installed_extensions/0` and emits a committed
   `_extensions_*.exs` migration that runs
   `CREATE EXTENSION IF NOT EXISTS "pg_trgm"` and `... "vector"`.
   This is the same shape as
   `priv/repo/migrations/20260321034746_create_accounts_and_projects_extensions_1.exs`.

**Verify:** `mix ecto.reset` runs cleanly; `\dx` lists `vector` and
`pg_trgm`; `Postgrex.query!(JidoClaw.Repo, "SELECT '[1,2,3]'::vector",
[])` decodes a vector in `iex` without raising.

### Stream 2 — Redaction modules

1. `lib/jido_claw/security/redaction/patterns.ex`:
   - Lift the URL-userinfo regex from
     `lib/jido_claw/security/redaction/env.ex:37` into the
     binary-pattern module so embedding/transcript callers pick it up.
   - Verify pattern ordering: `sk-ant-...` is matched **before**
     generic `sk-...` (the user flagged this as a possible
     drift; verify when editing — Anthropic-specific labels matter
     for the redaction-delta fixture in §1.8).
   - Keep `redact/1`'s "non-binary input passes through unchanged"
     contract.
2. `lib/jido_claw/security/redaction/embedding.ex` — wrapper used
   by `Voyage.embed_for_storage/1` and `embed_for_query/1`.
   `redact/1` returns `{redacted_input, redactions_applied_count}`
   so the Voyage telemetry can report the counter directly.
3. `lib/jido_claw/security/redaction/transcript.ex` — recursive
   walker over arbitrary terms. **Restricted JSON re-encoding**
   (the spec's "any binary value that's parseable JSON is decoded,
   redacted as a map, re-encoded" is too aggressive — it would
   rewrite legitimate Solution content that happens to be JSON-
   shaped). Instead:
   - Strings: `Patterns.redact/1` only.
   - Maps: recurse with sensitive-key replacement via
     `Redaction.Env.sensitive_key?/1`.
   - Lists: recurse element-wise.
   - **JSON-decode pass is gated on caller intent** — the walker
     accepts an `:json_aware_keys` opt (default `[]`); only values
     under those keys (e.g. `"arguments"`, `"input"`,
     `"tool_input"`, `"content"`) are decode-redact-encoded. The
     §1.4 Solution.solution_content path runs the walker with
     `[]`, so user content is never speculatively decoded.
     Phase 2 (Conversations) and Phase 3 (Memory) pass the
     provider-shape keys when they need that pass.
   - Idempotent — re-redacting an already-redacted string is a
     no-op.
4. Tests in `test/jido_claw/security/redaction/`:
   - Each pattern category through `Patterns.redact/1`.
   - `sk-ant-` vs generic `sk-` ordering test.
   - Sensitive-key replacement.
   - Idempotency.
   - JSON-decode gate: a JSON-shaped string that is NOT under a
     `:json_aware_keys` key is preserved byte-equivalent (no
     decode-encode round-trip).

**Verify:** `mix test test/jido_claw/security/redaction` green;
the JSON-gate test pins the restriction so Phase 2/3 don't
accidentally widen it.

### Stream 3 — Solutions domain and resources

1. `lib/jido_claw/solutions/domain.ex` — `JidoClaw.Solutions.Domain`,
   nested-style. Registers `Solution`, `Reputation`,
   `ReputationImport`. Append to `:ash_domains` in
   `config/config.exs`.
2. `lib/jido_claw/solutions/resources/solution.ex` —
   `JidoClaw.Solutions.Solution`. All §1.2 fields:
   - 13 legacy fields verbatim from `lib/jido_claw/solutions/solution.ex`
     (preserve types — `sharing :: :local | :shared | :public`,
     default `:local`).
   - `embedding` — `attribute :embedding, :vector, constraints:
     [dimensions: 1024], allow_nil?: true`
     (verified Ash builtin at `deps/ash/lib/ash/type/vector.ex:29`).
   - `embedding_status` — atom one_of `[:pending, :processing,
     :ready, :failed, :disabled]`. **No default at the attribute
     level** — resolved at write time per Stream 3 step 4 below.
     `:processing` is the claim-lease state introduced in Stream 7
     and is part of the enum, the migration, the policy
     transitions, and the §1.8 acceptance gates from day one.
   - `embedding_attempt_count` (integer, default 0),
     `embedding_next_attempt_at` (utc_datetime_usec, nullable),
     `embedding_last_error` (text, nullable),
     `embedding_model` (text, nullable).
   - `search_vector` — `attribute :search_vector,
     AshPostgres.Tsvector` (verified at
     `deps/ash_postgres/lib/types/tsvector.ex:5`). Generated column;
     hand-edit on the Ash-emitted migration in Stream 4.
   - `lexical_text` — `attribute :lexical_text, :string`. Generated
     column.
   - Phase 0 scope FKs: `workspace_id`, `session_id`,
     `created_by_user_id`, `tenant_id` (text, **required**).
     **`created_by_user_id` is nullable and mostly unused in
     Phase 1** — the existing `JidoClaw.ToolContext`
     (`lib/jido_claw/tool_context.ex:28-36`) does not carry a
     `:user_id` key. The web/RPC channel paths can populate it
     directly from `current_user.id` at the call site (those
     surfaces have an authenticated user); CLI, Discord, MCP, and
     cron paths leave it `nil`. Extending ToolContext to carry
     `:user_id` is a Phase-0 patch outside this scope.
   - `deleted_at` (utc_datetime_usec, nullable).
   - **Soft delete enforcement: NO `base_filter`.** Each "live"
     read action declares `prepare build(filter: [is_nil(deleted_at)])`
     (or its data-layer-aware equivalent), and the `:with_deleted`
     read explicitly omits the filter. Same predicate is repeated
     in the manual `:search` SQL CTEs in Stream 8. Reason:
     `base_filter` would force `:with_deleted` to bypass it via
     `unrestrict/1` or `bypass_filter`, which adds friction. Per-
     action filter is explicit and testable. The §1.8 soft-delete
     leakage gate pins this.
   - `custom_indexes` block (verified Ash supports `using:` per
     `deps/ash_postgres/lib/custom_index.ex`):
     - `index([:tenant_id, :problem_signature], using: "btree")`
     - `index([:tenant_id, :workspace_id])`
     - `index([:tenant_id, :language, :framework])`
     - `index([:tenant_id, :agent_id])`
     - `index([:tenant_id, :sharing])`
     - `index([:tenant_id, :trust_score], ...)` — declared with a
       descending opclass via the index's where/opclass fragment
       (or a hand-written fallback if Ash custom_indexes can't
       express `DESC` cleanly; defer the syntax decision to
       implementation).
     - **`index([:search_vector], using: "gin")`** — added per
       review feedback. The earlier draft missed this and would
       have made FTS read paths fall back to seq scan. GIN
       (no opclass needed — default `gin_trgm_ops` is for
       `text`, not `tsvector`) lives in `custom_indexes`
       cleanly.
   - HNSW and GIN-trigram indexes go in **separate hand-written
     migrations** (Stream 4) because `custom_indexes` doesn't
     express opclass per-column.
   - Identity: legacy UUID is the primary `id`; legacy duplicates
     on `problem_signature` are preserved (the legacy store keys
     by `id`, multiple rows can share a signature; the §1.6
     migration script preserves these as-is).
3. **Actions:**
   - `create :store` — accept-list excludes id/timestamps/embedding
     state. Runs:
     - `Redaction.Transcript.redact(content, json_aware_keys: [])`
       on `solution_content`.
     - Cross-tenant + cross-workspace FK `before_action` hook
       (validate-equality variant per §0.5.2). Inside the
       transaction:
       - Fetch the parent `Workspace` matching `workspace_id`.
         Reject with `:cross_tenant_fk_mismatch` if
         `workspace.tenant_id != changeset.tenant_id`.
       - When `session_id` is set, fetch the parent `Session`.
         Reject with `:cross_tenant_fk_mismatch` if
         `session.tenant_id != changeset.tenant_id` **or**
         `session.workspace_id != changeset.workspace_id`. The
         double check matters: same-tenant rows attached to a
         wrong-workspace session would otherwise pass the
         tenant-only validation and silently misattribute.
       - `created_by_user_id` is skipped (Accounts.User is
         intentionally untenanted per §0.5.2's "untenanted-
         parent rule").
     - **Initial `embedding_status` resolution from workspace
       policy** (review fix; the earlier draft would have left
       `:disabled` workspaces' rows on `:pending` and the periodic
       scan would have shipped them to Voyage):
       - `:default | :local_only` → `:pending`.
       - `:disabled` → `:disabled`.
       Resolution happens in a `change` that reads the
       `Workspace.embedding_policy` for the action's
       `workspace_id` and sets `embedding_status` accordingly.
       Same lookup runs in `:import_legacy`.
   - `create :import_legacy` — privileged, additionally accepts
     `id`, `inserted_at`, `updated_at`, `deleted_at`. Same
     redaction + same FK hook + same initial-status resolution.
   - `read :by_signature` — **returns a list, NOT a single row.**
     The earlier draft implied `get? true`. Per review: the legacy
     store does `Enum.find` (first match), but legitimate
     duplicates exist; signature-only lookup returns multiple
     rows. The action accepts `signature, workspace_id, tenant_id,
     local_visibility, cross_workspace_visibility`; orders by
     `trust_score DESC, updated_at DESC` deterministically.
     `Matcher.find_solutions/2`'s exact-match short-circuit takes
     `List.first/1` of the result.
   - `read :search` — accepts `query, language, framework, limit,
     threshold, workspace_id, tenant_id, local_visibility,
     cross_workspace_visibility, query_embedding,
     embedding_model, query_text_lower, query_text_like_escaped`.
     Calls into the §1.5 SQL via a manual data-layer action
     (Stream 8).
   - `read :with_deleted` — explicit no-filter read for replay/audit.
   - `update :update_trust`, `update :update_verification`,
     `update :update_verification_and_trust` — preserve the three-
     way mutation API. Compound runs `Trust.compute/2` in a
     `before_action`, looking up `Reputation.get(tenant_id,
     agent_id)` and threading the score through `:agent_reputation`.
   - `update :soft_delete` — sets `deleted_at = now()`.
   - `update :transition_embedding_status` — used by the backfill
     worker after dispatch completes. Updates `embedding`,
     `embedding_model`, `embedding_status`, and the retry columns
     in a single update; the **claim** to `:processing` happens
     separately via the Stream 7 atomic `UPDATE ... FOR UPDATE
     SKIP LOCKED` SQL, not through this action (Ash actions can't
     express the locking-cursor pattern cleanly).
   - `read :stats` — replaces the legacy `Solutions.Store.stats/0`.
     Returns `%{total, by_language, by_framework}` scoped to the
     caller's `tenant_id` and `workspace_id`. Used by the
     `/solutions` REPL stats branch (`cli/commands.ex:280`).
   - `code_interface` exposes `store, import_legacy, by_signature,
     search, stats, update_trust, update_verification,
     update_verification_and_trust, soft_delete,
     transition_embedding_status, with_deleted`.
4. `lib/jido_claw/solutions/resources/reputation.ex` —
   `JidoClaw.Solutions.Reputation`. Mirror today's
   struct fields plus `tenant_id` text required. Identity
   `(tenant_id, agent_id)`. The single-arg API at
   `lib/jido_claw/solutions/reputation.ex:52-91` is **deleted**
   (not deprecated).
   - **Atomicity for counter writes** (review fix; the GenServer
     serialized increments, Postgres needs explicit care):
     - `:record_success`, `:record_failure`, `:record_share` —
       each wraps a single `Repo.transaction`:
       1. `Ash.read!` (or raw `Repo.one`) with `lock:
          "FOR UPDATE"` on the reputation row identified by
          `(tenant_id, agent_id)`. Creates the row at default 0.5
          if absent (an upsert-shaped `INSERT ... ON CONFLICT DO
          NOTHING` followed by a re-read inside the same lock).
       2. Increment the counter in Elixir; recompute `score` via
          `Reputation.compute_score/1`.
       3. Single `UPDATE` writing both the new counter and the
          new score, plus `last_active = now()`.
       Pessimistic locking is correct here — reputation writes
       happen at human cadence, not millisecond contention, so
       holding a row lock for the duration of a single Elixir
       compute is fine. Optimistic CAS retries would add
       complexity for no measurable gain. The `change` module
       implementing this lives at
       `lib/jido_claw/solutions/changes/reputation_record.ex`.
     - `:upsert` (used by the migration step) takes a full
       attrs map; uses Ash's `upsert?: true, upsert_identity:
       :unique_tenant_agent`.
   - `code_interface`: `record_success(tenant_id, agent_id)`,
     `record_failure(tenant_id, agent_id)`,
     `record_share(tenant_id, agent_id)`,
     `get(tenant_id, agent_id)` (returns the default-0.5 entry
     when no row matches), `upsert(attrs_map)`.
   - Public `Reputation.compute_score/1` — lifts the formula from
     today's private `recalculate_score/1`
     (`lib/jido_claw/solutions/reputation.ex:237-253`) verbatim
     (preserves the `0.15` baseline constant).
5. `lib/jido_claw/solutions/resources/reputation_import.ex` — the
   import-ledger from §1.3. Identity `[tenant_id, source_sha256]`.
   `code_interface`: `record_import/1`, `find_by_hash(tenant_id,
   sha)`.
6. **Preserved as pure modules:** `fingerprint.ex`, `matcher.ex`,
   `trust.ex`. `Matcher.find_solutions/2` gains opts
   (`workspace_id:, tenant_id:, local_visibility:,
   cross_workspace_visibility:`) and threads them through.

**Verify:** `mix ash.codegen --check` clean; resources load in
`iex`; `Solution.store!` round-trip works; basic
`Reputation.record_success(tid, aid)` increments `solutions_verified`
under contention via a `Task.async_stream/3` test.

### Stream 4 — Migration shape

`mix ash_postgres.generate_migrations` emits the resource migration.
Hand-edits and additional migrations:

1. **Generated columns** — edit the Ash-emitted migration to
   declare `search_vector` and `lexical_text` as
   `GENERATED ALWAYS AS (...) STORED` with the §1.2 SQL bodies.
   Without this, both columns ship as plain types and FTS / lexical
   searches silently never match. §1.8 acceptance gate inserts a
   row, asserts the columns are populated by the database (not by
   Elixir), and asserts FTS+lexical match against the populated
   contents.
2. **Partial HNSW indexes per `embedding_model`** (review fix —
   per the pgvector docs, partial HNSW indexes are the right
   shape for low-cardinality filters; `embedding_model` has 2
   values in v0.6.x):
   ```sql
   -- Voyage rows
   CREATE INDEX solutions_embedding_voyage_hnsw_idx
     ON solutions USING hnsw (embedding vector_cosine_ops)
     WHERE embedding_model = 'voyage-4-large';

   -- Local Ollama rows
   CREATE INDEX solutions_embedding_local_hnsw_idx
     ON solutions USING hnsw (embedding vector_cosine_ops)
     WHERE embedding_model = 'mxbai-embed-large';
   ```
   The `vector_cosine_ops` opclass matches the `<=>` operator in
   the §1.5 query; pgvector's default `vector_l2_ops` would
   silently rank against L2 distance.
   The `embedding_model = $11` predicate in the §1.5 ANN CTE is
   what makes the planner pick the matching partial index. The
   earlier draft's `(embedding_model, tenant_id)` btree
   composite is **dropped** — it was a workaround for the
   monolithic-HNSW shape that this stream eliminates.
3. **GIN trigram on `lexical_text`** — separate hand-written
   migration:
   ```sql
   CREATE INDEX solutions_lexical_text_trgm_idx
     ON solutions USING gin (lexical_text gin_trgm_ops);
   ```
   `gin_trgm_ops` is required because the default `gin_ops` for
   `text` doesn't support similarity / LIKE.

**Verify:** `mix ecto.reset` clean; `\d solutions` shows the four
indexes (search_vector GIN from custom_indexes, two partial HNSW,
one GIN trigram); §1.8 "Lexical-index engaged" gate confirms
EXPLAIN ANALYZE uses the trigram index on a 5,000-row corpus.

### Stream 5 — Voyage and Local embedding clients

1. `mix.exs` — add `Req` as a direct dep (currently transitive).
2. `lib/jido_claw/embeddings/voyage.ex`:
   - `embed_for_storage/1` — `voyage-4-large`, `input_type:
     "document"`, `output_dimension: 1024`, `output_dtype:
     "float"`.
   - `embed_for_query/1` — `voyage-4`, `input_type: "query"`,
     same dimension/dtype.
   - Both: read `System.get_env("VOYAGE_API_KEY")`; fail loudly
     (`{:error, :missing_api_key}`) when absent rather than
     calling Voyage with a nil header.
   - Both: pre-redact via `Redaction.Embedding.redact/1`,
     capturing `redactions_applied`.
   - HTTP via `Req.new(finch: JidoClaw.Finch)`.
   - 429 returns `{:error, {:rate_limited, retry_after}}` so the
     backfill worker classifies correctly.
3. Telemetry `[:jido_claw, :embeddings, :voyage, :request]` with
   `model, tokens, latency_ms, redactions_applied,
   status_code`.
4. `lib/jido_claw/embeddings/local.ex` — Ollama HTTP client,
   `mxbai-embed-large` (1024-d), same redaction gate. Pinned
   model per §1.4 "Local embedding isolation" — one config key
   `config :jido_claw, JidoClaw.Embeddings.Local, model:
   "mxbai-embed-large"`. Non-1024-d models are out of scope for
   v0.6.x.

**Verify:** unit tests with stubbed Req adapter (Voyage and
Ollama responses); a `@tag :voyage_live` skipped-by-default test
hits the real API behind a guard.

### Stream 6 — Rate pacer and dispatch window

1. `lib/jido_claw/embeddings/rate_pacer.ex` — per-node GenServer.
   - Token bucket per `(model, :rpm)` and `(model, :tpm)`.
   - **Rate-limit math fix** (review): if `cluster_window_seconds
     = 1` (the default per §1.4), per-window budget is
     `rpm * window_seconds / 60` and `tpm * window_seconds /
     60`. The earlier draft's `$3 = rpm/cluster_window_seconds`
     was off by a factor of 60. The corrected SQL parameters in
     Stream 8 use `rpm * window_seconds / 60` and
     `tpm * window_seconds / 60`.
   - Defaults conservative — Voyage's free trial is much
     smaller than paid Tier 1. The plan ships defaults
     deliberately at paid-Tier-1-conservative levels, with a
     **boot-time warning** if `VOYAGE_API_KEY` is set but the
     operator hasn't explicitly configured `:rate_limits` (the
     warning points at the docs URL and the config key).
     Operators on the free trial must override down; operators
     on Tier 2/3 must override up. Auto-detection via the API
     is intentionally out of scope.
   - `acquire/2` blocks up to `:rate_acquire_timeout_ms` (default
     30_000); refill via `System.monotonic_time/1`.
2. `lib/jido_claw/embeddings/resources/dispatch_window.ex` —
   `JidoClaw.Embeddings.DispatchWindow` (flat namespace per the
   project's v0.6 convention). Composite PK
   `(model, window_started_at)`, `request_count integer`,
   `token_count integer`. No `tenant_id` (Voyage RPM/TPM is
   per-API-key, cluster-global).
3. Conditional UPSERT exposed as a manual data-layer action
   `:try_admit/2` (or `Repo.query!` helper):
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
   `$3 = rpm * cluster_window_seconds / 60` (per the math fix
   above), `$4 = tpm * cluster_window_seconds / 60`. Zero-row
   RETURNING means rejection; counter unchanged.
4. Daily GC drops rows older than `:cluster_window_gc_after_seconds`
   (default 60). Implemented via `:timer.send_interval/2` in
   RatePacer (no separate cron).
5. Telemetry `[:jido_claw, :embeddings, :rate_pacer]` and
   `[:jido_claw, :embeddings, :cluster_window]` per §1.4.

**Verify:**
- Unit test the in-process bucket with a controlled clock.
- §1.8 "Rejected-call no-charge" gate (prefill row to budget,
  100 attempts, all rejected, counter unchanged, advance window,
  next admit succeeds).
- §1.8 "Cross-node embedding budget" gate (two libcluster nodes
  share within ±10% of configured per-second budget).

### Stream 7 — Backfill worker

Two correctness changes from the spec, both review-driven:

**Change A — claim atomicity.** The earlier draft scanned
`:pending` rows and dispatched without claim, so two nodes (or
two scan ticks) could process the same row. Two-step claim shape:

1. **Atomic claim — periodic-scan path.** A single SQL statement
   transitions a batch of rows from `:pending` (or expired
   `:processing`) to a freshly-leased `:processing`:
   ```sql
   UPDATE solutions
      SET embedding_status = 'processing',
          embedding_next_attempt_at = now() + INTERVAL '5 minutes'
    WHERE id IN (
      SELECT id FROM solutions
       WHERE (
               embedding_status = 'pending'
               OR (embedding_status = 'processing'
                   AND embedding_next_attempt_at <= now())
             )
         AND (embedding_next_attempt_at IS NULL
              OR embedding_next_attempt_at <= now())
         AND inserted_at < now() - INTERVAL '1 minute'
       ORDER BY embedding_next_attempt_at ASC NULLS FIRST
       LIMIT $1
       FOR UPDATE SKIP LOCKED
    )
    RETURNING id, ...;
   ```
   Two predicate branches in the inner SELECT — `:pending` rows
   and `:processing` rows whose 5-minute lease has expired. Without
   the second branch, a worker that died mid-dispatch would leave
   its claimed rows stuck in `:processing` forever; the periodic
   scan would skip them indefinitely because the only filter was
   `embedding_status = 'pending'`. The `FOR UPDATE SKIP LOCKED` on
   the inner select still serializes against any concurrent
   live-claim attempt; the outer UPDATE flips the status to a
   fresh lease.
2. **Atomic claim — hint-by-id path.** The `after_transaction`
   hint (Change B below) sends a row id to the worker. The hint
   handler runs a different claim SQL keyed on `id`:
   ```sql
   UPDATE solutions
      SET embedding_status = 'processing',
          embedding_next_attempt_at = now() + INTERVAL '5 minutes'
    WHERE id = $1
      AND (
            embedding_status = 'pending'
            OR (embedding_status = 'processing'
                AND embedding_next_attempt_at <= now())
          )
    RETURNING id, ...;
   ```
   This bypasses the `inserted_at < now() - INTERVAL '1 minute'`
   age guard that the periodic scan needs (the scan's age guard
   exists to avoid double-claiming a row the live insert is about
   to dispatch — but the hint *is* that live dispatch, so the
   guard would block its own trigger). Zero-row RETURNING means
   another worker / scan claimed the row first; the hint silently
   becomes a no-op.
2. **Status enum gains `:processing`** — per the review feedback.
   The §1.2 enum becomes `[:pending, :processing, :ready, :failed,
   :disabled]`. The §1.8 acceptance gates pin: `:processing` is
   never observable on a row whose worker has finished
   (success → `:ready`, failure → `:pending` with backoff or
   `:failed` at cap).
3. On success: `transition_embedding_status` action sets
   `embedding`, `embedding_model`, `:ready`; clears
   `attempt_count`/`next_attempt_at`/`last_error`.
4. On failure: increments `attempt_count`, writes
   `last_error`, sets `next_attempt_at = now() + 2^attempt seconds`
   (cap 1 hour); flips `embedding_status` back to `:pending` so
   the next scan picks it up. At cap, flips to `:failed`.
5. **HTTP 429 special case**: classified as `:rate_limited`,
   respects `Retry-After`, **does NOT** increment
   `attempt_count`. The row goes back to `:pending` with the
   header-derived `next_attempt_at`.

**Change B — enqueue trigger uses `after_transaction`, not
`after_action`.** Ash `after_action` runs inside the create
transaction; a worker triggered there can observe an uncommitted
row (or one about to be rolled back). The fix:

- The `:store` and `:import_legacy` actions register a
  `change after_transaction(...)` callback that, if the
  transaction committed, sends a non-blocking message to
  `BackfillWorker` ("hint: row $id is pending"). The worker
  treats hints as advisory — it still calls the atomic claim
  step before dispatching, so a hint that races against the
  periodic scan can't double-claim.
- Periodic scan remains as the durable backstop. Default
  `:scan_interval_seconds` lowered from 300 to 30 in dev (still
  300 in prod) so test latency doesn't suffer.

`lib/jido_claw/embeddings/backfill_worker.ex` — GenServer.
- Concurrency cap via `Task.async_stream(rows, fn row -> ... end,
  max_concurrency: :max_concurrent_embedding_batches,
  ordered: false, on_timeout: :kill_task)` (default 4).
- Dispatch routes per workspace policy re-read at execute time
  (`:default → Voyage`, `:local_only → Local`,
  `:disabled → no-op + transition to :disabled`).
- Telemetry `recovered_pending_count` and `failed_count` per
  scan tick.

**Supervision placement** (review fix; verified against
`lib/jido_claw/application.ex`): `JidoClaw.TaskSupervisor` and
`JidoClaw.Repo` live in the **InfraSupervisor** (line 70-71 inside
`infra_children`); `Finch` named `JidoClaw.Finch` starts at
line 102-103 of core_children, *after* InfraSupervisor returns.
The new workers depend on both Repo (Ash actions) and Finch
(Voyage HTTP), so they must start after Finch:

- Insert `JidoClaw.Embeddings.RatePacer` immediately after
  `{Finch, name: JidoClaw.Finch}` (currently line 103).
- Insert `JidoClaw.Embeddings.BackfillWorker` immediately after
  RatePacer.
- Both replace `JidoClaw.Solutions.Store` (line 131) and
  `JidoClaw.Solutions.Reputation` (line 132) — those two are
  removed in Stream 12.

**Verify:**
- §1.8 "Embedding rate-limit ceiling" gate.
- New gate: **claim atomicity** — start two BackfillWorker-
  equivalent processes against the same DB, seed 100 `:pending`
  rows, assert each row is dispatched exactly once. Without
  `FOR UPDATE SKIP LOCKED`, the test exposes double-dispatch.
- New gate: **lease expiry** — claim a row, kill the worker
  process before it transitions to `:ready`/`:pending`, advance
  the clock past the 5-minute lease, assert the next scan
  re-claims the row.

### Stream 8 — Hybrid retrieval (§1.5)

1. Implement the `read :search` action body via
   `Ecto.Adapters.SQL.query!/3` wrapped in a manual data-layer
   action. Result rows are loaded via `Repo.load(Solution, ...)`
   so callers receive Solution structs.
2. **Parameter map fix** (review):
   - `$1` query text (raw, for FTS via `websearch_to_tsquery`).
   - `$2..$8` as before (filters + visibility split + tenant +
     limit + workspace).
   - `$9` tenant_id.
   - `$10` LIKE-escaped, lower-cased query text — used by the
     `LIKE '%' || $10 || '%' ESCAPE '\'` predicate **only**.
   - `$11` embedding model name — set per workspace policy.
   - **`$12` raw lower-cased query text (NOT escape-quoted)** —
     used by `similarity(lexical_text, $12)`. The earlier draft
     used `$10` for both, which would penalize `similarity('100\\%',
     ...)` because the literal `\\%` is in the comparison.
     `escape_like/1` produces an escaped string for LIKE; a
     separate raw-lowercased string drives similarity.
3. `lib/jido_claw/solutions/search_escape.ex` — the
   `escape_like/1` reference implementation per §1.5. Add a
   sibling `lower_only/1` that just `String.downcase/1`s, used
   by callers to compute `$12`.
4. **Soft-delete predicate explicit in every CTE** —
   `AND deleted_at IS NULL` repeated in `fts_pool`, `ann_pool`,
   `lexical_pool`, and the outer `SELECT` (per the
   no-`base_filter` decision in Stream 3).
5. `Matcher.find_solutions/2` gains opts and threads through:
   `workspace_id, tenant_id, local_visibility,
   cross_workspace_visibility`. Computes `query_embedding` via
   `Voyage.embed_for_query/1` (or `Local.embed_for_query/1`
   when policy is `:local_only`); `nil` falls back to FTS +
   lexical only via the `$4::vector IS NOT NULL` guard.
   Computes `embedding_model = $11` from the workspace policy
   (`'voyage-4-large'` or `'mxbai-embed-large'`).

**Verify:**
- §1.8 "Substring-superset" — `"client.api_base_url"` matched by
  `"api_base"`.
- §1.8 "Lexical-index engaged" (5,000 rows, EXPLAIN ANALYZE
  trigram).
- §1.8 "LIKE-wildcard escape" — `"100%"` and `"user_"` literal.
- New gate: **similarity-rank correctness** — seed two rows, one
  containing `"100%"` and one containing `"100ish"`. Query
  `"100%"`. Assert the `"100%"` row ranks higher; without the
  `$10`/`$12` split, `similarity('100\\%', '100%')` ranks lower
  than `similarity('100\\%', '100ish')` due to the escape
  character.
- §1.8 "Soft-delete leakage" — explicit `AND deleted_at IS NULL`
  in every CTE pinned by EXPLAIN-or-result-set test.
- §1.8 cross-workspace isolation.

### Stream 9 — Tools and Network facade

1. `lib/jido_claw/tools/store_solution.ex` — `def run(params,
   context)` reads `context.tool_context.workspace_uuid,
   context.tool_context.tenant_id`, optionally `session_uuid`.
   Calls `Solutions.Solution.store/1`. Fails loudly
   when scope is missing — no v0.5.x "workspace = nil means
   everywhere" fallback.
2. `lib/jido_claw/tools/find_solution.ex` — same context wiring;
   calls `Matcher.find_solutions/2` with the resolved opts.
3. `lib/jido_claw/tools/verify_certificate.ex:55, 219, 222` —
   replace `Solutions.Store.find_by_id/1` with the new code
   interface; remove the "Solution store is not running" error
   path (Postgres is always up; a missing row is a missing row,
   not a downed service). Reads `context.tool_context.tenant_id`
   for any subsequent `Reputation.record_*` call (Stream 10).
4. `lib/jido_claw/cli/commands.ex:256, 280` — `/solutions` REPL
   command. Resolves the current REPL session's
   `workspace_uuid` and `tenant_id` and calls
   `Solution.search/1` (256) and a new `Solution.stats/1` action
   (280) — replacing `Store.search/2` and `Store.stats/0`.
5. `lib/jido_claw/shell/commands/jido.ex:24, 105` — `jido
   solutions find` shell command. Replace
   `Solutions.Store.find_by_signature/1` with
   `Solution.by_signature/1` (returns a list now), update the
   docstring at line 24, take `List.first/1` to preserve the
   shell's existing single-row output shape.
6. `lib/jido_claw/cli/presenters.ex:11, 20` — typespec swaps
   from `%JidoClaw.Solutions.Solution{}` to
   `%JidoClaw.Solutions.Solution{}`. Verify the
   presenter doesn't pattern-match on struct internals; if it
   does, update field accessors.
7. `lib/jido_claw/network/protocol.ex:105` — docstring update
   only (no behavioral change).
8. `lib/jido_claw/solutions/network_facade.ex` —
   `JidoClaw.Solutions.NetworkFacade`. Two functions:
   - `store_inbound/2` — receives an attrs map plus `node_state`,
     resolves workspace/tenant, forces `sharing: :shared`,
     clears sender-supplied scope keys, calls
     `Solution.store/1`.
   - `find_local/2` — receives a `solution_id` and `node_state`,
     reads via `Solution.by_signature/1` or
     `Ash.get(Solution, id, ...)` scoped to the receiving
     workspace's tenant. Used by outbound paths.
9. **`Network.Node` scope expansion** (review fix; the earlier
   draft only handled inbound):
   - `defstruct` adds `:tenant_id` and `:workspace_id`. Resolved
     at `start_link/1` from the supervisor's opts.
   - `lib/jido_claw/application.ex:147` — pass `tenant_id` (and
     `project_dir` already passed) to `Network.Supervisor`,
     which forwards to `Network.Node`. The Network supervisor
     today is per-app singleton; tenant resolution happens once
     at boot from `Application.get_env(:jido_claw,
     :network_tenant)` (or a sensible default like `"default"`
     for unauthenticated single-tenant deployments). Multi-
     tenant network presence is out of scope for v0.6.1 — the
     network layer is per-tenant; documented.
   - **All four Network.Node call sites swap to scope-aware
     paths** (verified at `lib/jido_claw/network/node.ex`):
     - `broadcast_solution/1` (line 104) → reads via
       `NetworkFacade.find_local/2` instead of
       `find_solution_by_id/1`'s legacy Store call.
     - `handle_solution_requested/2` (line 292) → calls
       `Matcher.find_solutions/2` with the node's
       `tenant_id`/`workspace_id` threaded through.
     - `handle_solution_response/2` (line 318, NOT 325 as the
       spec claimed) → `NetworkFacade.store_inbound/2`.
     - `store_received_solution/2` (line 360-363) →
       `NetworkFacade.store_inbound/2`.
     - `find_solution_by_id/1` (line 365) → delete; replaced by
       `NetworkFacade.find_local/2`.

**Verify:**
- §1.8 cross-tenant FK validation gate — disagreeing
  `tenant_id`/`workspace_id` rejects with
  `:cross_tenant_fk_mismatch`.
- §1.8 inbound network integration gate — `:share`/`:response`
  path produces a Solution with the right scope.
- New gate: **outbound network scope** — drive a
  `broadcast_solution(id)` for a `:local` row in workspace A;
  assert the read path resolves via the node's tenant/
  workspace. Drive a `handle_solution_requested` and assert
  `Matcher.find_solutions/2` is called with the node's scope
  opts.

#### MCP-mode tool scope

`lib/jido_claw/core/mcp_server.ex:30-31` publishes
`JidoClaw.Tools.StoreSolution` and `JidoClaw.Tools.FindSolution`
over the MCP stdio transport. MCP invocations from external
clients (Claude Code, Cursor) **do not** carry a `tool_context`
the way agent dispatch does — the MCP transport hands tools a
JSON arg map, period. Without explicit handling, every MCP
solutions tool call would fail loudly with the new
"missing scope" error path from Stream 9 step 1.

The MCP server runs in a fixed process: `mix jidoclaw --mcp` is
launched with a known `cwd` (per the README's `.mcp.json`
example). That `project_dir` is the only scope information
available; it's enough.

**Resolve once at MCP boot, inject into every call:**

1. `lib/jido_claw/core/mcp_server.ex` — at server start, resolve
   the MCP-mode workspace via
   `JidoClaw.Workspaces.Resolver.ensure_workspace("default",
   File.cwd!(), [])`. `tenant_id: "default"` is correct for MCP —
   the protocol has no auth and is single-user by definition.
2. Stash the resolved `{tenant_id, workspace_uuid}` on the MCP
   server state (or in a process dictionary keyed under
   `:jido_claw_mcp_default_scope`).
3. Wrap each Solutions tool's `run/2` so when `context.tool_context`
   is missing or empty, it falls back to the MCP-default scope.
   Implementation choice — either:
   - A small `JidoClaw.Tools.MCPScope.with_default/2` helper that
     `StoreSolution` and `FindSolution` (and
     `VerifyCertificate`) call before invoking the resource code
     interface, or
   - A `pre_run` hook in the Jido.MCP.Server publish list that
     uniformly stamps the default scope.
   Pick the helper for v0.6.1 — fewer moving parts in the MCP
   library.

**Testing.** A dedicated MCP-mode test boots the MCP server with
a temp `cwd`, asserts a resolved Workspace row exists for
`("default", cwd)`, calls `StoreSolution` with no
`tool_context`, asserts the resulting Solution row carries
`tenant_id: "default"` and the resolved `workspace_id`. Without
this gate, an MCP user shipping production code through Claude
Code would see every solutions write fail.

**Out of scope.** Multi-tenant MCP (each MCP client a different
tenant) is deferred — the protocol has no mechanism to
distinguish callers, so it'd require a JidoClaw-specific
authentication layer on top.

### Stream 10 — Reputation wiring

Three call sites:

1. `Solutions.Solution.update_verification_and_trust`
   `before_action`:
   - `Reputation.get(solution.tenant_id, solution.agent_id)` —
     returns the default-0.5 entry when no row matches.
   - Pass score through `Trust.compute/2` as `:agent_reputation`.
2. `update_verification_and_trust` `after_transaction`:
   - On verification `:passed` → `Reputation.record_success(tid, aid)`.
   - On verification `:failed` → `Reputation.record_failure(tid, aid)`.
   - Other verification states (`:partial`, `:semi_formal`) — no
     reputation update; they're not full success/failure signals.
   - Atomicity per Stream 3 step 4 — the `record_*` helpers wrap
     a `Repo.transaction` with `FOR UPDATE` on the reputation
     row.
3. `NetworkFacade.store_inbound/2` after a successful Solution
   write → `Reputation.record_share(tenant_id, agent_id)` with
   the inbound solution's scope.

**Verify:**
- §1.8 "Tenant-scoped reputation parity" — alice/tenant-A
  success and alice/tenant-B failure stay isolated.
- New gate: **concurrent reputation increments** — fire 100
  parallel `record_success(tid, aid)` calls; assert
  `solutions_verified == 100` after settle. Without the
  transaction-and-FOR-UPDATE, lost updates surface here.

### Stream 11 — Embedding-policy CLI surface and transitions

1. **REPL commands** in `lib/jido_claw/cli/repl/commands/workspace.ex`
   (or wherever `/workspace` lives — to be confirmed at
   implementation time):
   - `/workspace embedding <default|local_only|disabled>`
   - `/workspace consolidation <default|local_only|disabled>`
   - **CLI fetch-by-uuid step** (review fix; the existing
     `Workspace.set_embedding_policy/2` action takes a struct,
     not a uuid — verified at
     `lib/jido_claw/workspaces/resources/workspace.ex:86-96`):
     - The REPL command reads `state.workspace_uuid`, calls
       `Ash.get!(JidoClaw.Workspaces.Workspace,
       state.workspace_uuid, domain: JidoClaw.Workspaces.Domain)`
       to get the struct, then calls
       `Workspace.set_embedding_policy(workspace, atom)`.
     - Optional sweetener (deferred unless it cleans up two or
       more call sites): an `:set_embedding_policy_by_uuid`
       action that wraps the lookup. Skipping this for v0.6.1
       — the explicit fetch is two lines and clearer.
2. **Setup wizard flow** (review fix; verified against
   `lib/jido_claw/cli/setup.ex:36-62` and
   `lib/jido_claw/cli/repl.ex:506`):

   `Setup.run/1` today only handles provider/model/API-key
   configuration and writes `.jido/config.yaml`. **It does not
   register a Workspace row** — Workspace persistence happens
   later in `ensure_persisted_session/3` at `cli/repl.ex:506`.
   The earlier draft's "stamp the freshly registered Workspace
   row" was wrong about the timing.

   **Collect-then-apply pattern:**

   1. Add two new wizard prompts to `Setup.run/1` (after the
      existing API-key + model steps, before
      `write_config/2`):
      - "Enable Voyage embeddings for this workspace? [Y/n]"
        (default `:default`)
      - "Allow JidoClaw to send transcripts and memory facts
        to a frontier-model consolidator? [y/N]"
        (default `:disabled`)
   2. Stamp both choices into the `config.yaml` map under
      keys like `embedding_policy:` / `consolidation_policy:`.
      (The existing wizard already merges into the config; this
      is a one-line additional pair of keys.)
   3. In `ensure_persisted_session/3` at
      `lib/jido_claw/cli/repl.ex:506`, after the Workspace row
      is registered (or fetched if it already existed), read
      the two policy keys from config and apply via:
      ```elixir
      workspace
      |> JidoClaw.Workspaces.Workspace.set_embedding_policy(policy_atom)
      ```
      Idempotent — running setup again, then re-entering the
      REPL, just rewrites the same policy. **Skip the apply
      step if the workspace already has a non-`:disabled`
      policy AND the config says `:disabled`** — that's the
      "I changed my mind via /workspace embedding and don't
      want setup to undo it" case. Conversely, if the config
      explicitly sets a non-`:disabled` policy, apply it
      (the user just said yes in the wizard).
   - Existing installs that have already passed the wizard see
     no new prompts because `Setup.needed?/1` returns false
     (config.yaml exists with a `provider` key per
     `setup.ex:24-30`); their workspaces stay `:disabled` until
     `/workspace embedding` runs explicitly. New installs go
     through both prompts.
3. **Policy transition logic in `:set_embedding_policy`**
   (extends the existing action at
   `lib/jido_claw/workspaces/resources/workspace.ex:86-96`):
   - Wrap the column update in a `Repo.transaction` that, after
     writing the new policy, runs the §1.4 transition table:
     - `:disabled → :default | :local_only`: bulk-update every
       Solution and Memory.Fact (Phase 3, deferred — only
       Solution this phase) row in the workspace whose
       `embedding_status = :disabled` to `:pending`; clear
       attempt-count/next-attempt/last-error.
     - `:default ↔ :local_only`: bulk NULL the `embedding`
       column on `:ready` rows and flip `embedding_status` →
       `:pending` so the worker re-embeds in the new space.
     - `:default | :local_only → :disabled`: flip
       `:pending`/`:processing`/`:failed` rows to `:disabled`.
       **`:ready` rows keep their `embedding`** unless
       `purge_existing: true` is passed.
   - Synchronous bounded UPDATE only for v0.6.1 (the spec's
     batched-drain shape is a v0.7+ extension).

**Verify:**
- §1.8 "Policy transition row-status fix-up" gate — full
  `:disabled → :default → :ready → :disabled (purge)` cycle.
- §1.8 "Embedding-policy egress gate" — two workspaces, two
  policies, stub Voyage records bodies; assert egress only
  from `:default` and the `:disabled` row's
  `embedding_status` stays `:disabled`.
- New gate: **initial-status-from-policy** — write a row under
  a `:disabled` workspace; assert `embedding_status: :disabled`.
  Write a row under a `:default` workspace; assert
  `embedding_status: :pending`. Without the per-row policy
  resolution at write time, the periodic scan would ship
  `:disabled` rows to Voyage — the failure mode the §0.2
  default exists to prevent.

### Stream 12 — Migration task and decommission

1. `lib/mix/tasks/jidoclaw.migrate.solutions.ex` —
   `Mix.Tasks.Jidoclaw.Migrate.Solutions`. Steps mirror §1.6:
   - Read `.jido/solutions.json` files; for each entry,
     `Workspaces.Resolver.ensure_workspace/3`, then
     `Solution.import_legacy/1` with preserved `id`,
     `inserted_at`, `updated_at`, `deleted_at`. Idempotency: skip
     when `id` already exists in Postgres.
   - Read `.jido/reputation.json`; SHA-256 the file; check the
     ledger via `ReputationImport.find_by_hash/2`. If present,
     log "already imported at <ts>; skipping" and continue.
     Otherwise: per-agent same-tenant collisions sum counters
     and recompute via `Reputation.compute_score/1`; insert
     the `ReputationImport` row.
   - `--dry-run` flag prints plan without writing.
   - Telemetry per merge: `{tenant_id, agent_id, sources,
     merged_score, prior_scores}`.
2. `lib/mix/tasks/jidoclaw.export.solutions.ex` — round-trip
   export task referenced by §1.8. Emits the legacy JSON shape
   plus a sidecar manifest of redaction sites (positions and
   pattern category) so the redaction-delta fixture can verify
   `[REDACTED]` lands at exactly the manifest positions.
3. `lib/jido_claw/application.ex`:
   - Remove `JidoClaw.Solutions.Store` (line 131) and
     `JidoClaw.Solutions.Reputation` (line 132) from
     `core_children/0`.
   - Add `JidoClaw.Embeddings.RatePacer`,
     `JidoClaw.Embeddings.BackfillWorker`.
   - Update `Network.Supervisor` opts to pass `tenant_id`
     (Stream 9).
4. **Delete legacy files** after cutover:
   - `lib/jido_claw/solutions/store.ex`
   - `lib/jido_claw/solutions/reputation.ex` (the GenServer; the
     resource lives at `solutions/resources/reputation.ex`)
   - `lib/jido_claw/solutions/solution.ex` (the struct; the
     resource lives at `solutions/resources/solution.ex`)
5. Add a one-line README in `.jido/` noting `solutions.json` and
   `reputation.json` are deprecated. Files stay on disk (user
   data).

**Verify:**
- Round-trip sanitized fixture (load → migrate → export →
  byte-equivalent).
- Round-trip redaction-delta fixture (manifest match per
  pattern category).
- §1.8 "Reputation import-ledger idempotency" gate.
- `mix test` green.
- `mix compile --warnings-as-errors` green.
- `mix ash.codegen --check` clean.
- `mix format --check-formatted` clean.

## Critical files reference

**Created:**
- `lib/jido_claw/postgrex_types.ex`
- `lib/jido_claw/security/redaction/embedding.ex`
- `lib/jido_claw/security/redaction/transcript.ex`
- `lib/jido_claw/solutions/domain.ex`
- `lib/jido_claw/solutions/resources/solution.ex`
- `lib/jido_claw/solutions/resources/reputation.ex`
- `lib/jido_claw/solutions/resources/reputation_import.ex`
- `lib/jido_claw/solutions/network_facade.ex`
- `lib/jido_claw/solutions/search_escape.ex`
- `lib/jido_claw/embeddings/domain.ex`
- `lib/jido_claw/embeddings/voyage.ex`
- `lib/jido_claw/embeddings/local.ex`
- `lib/jido_claw/embeddings/rate_pacer.ex`
- `lib/jido_claw/embeddings/backfill_worker.ex`
- `lib/jido_claw/embeddings/resources/dispatch_window.ex`
- `lib/jido_claw/solutions/changes/reputation_record.ex` —
  the transaction-FOR-UPDATE-recompute change module shared by
  `record_success` / `record_failure` / `record_share`.
- `lib/jido_claw/tools/mcp_scope.ex` — `with_default/2` wrapper
  for the three solutions tools.
- `lib/mix/tasks/jidoclaw.migrate.solutions.ex`
- `lib/mix/tasks/jidoclaw.export.solutions.ex`
- Hand-written migrations: `pg_trgm` extension + GIN trigram on
  `lexical_text`, two partial HNSW indexes (one per
  `embedding_model`).

**Modified:**
- `lib/jido_claw/repo.ex` — extend `installed_extensions/0`.
- `config/config.exs` — `:ash_domains` (append Solutions and
  Embeddings); `JidoClaw.Repo` block (`types:`).
- `mix.exs` — add `Req` as direct dep.
- `lib/jido_claw/security/redaction/patterns.ex` — URL-userinfo
  pattern; verify `sk-ant-` ordering.
- `lib/jido_claw/solutions/matcher.ex` — opts threading; exact-
  match short-circuit takes `List.first/1` of
  `by_signature/1`.
- `lib/jido_claw/solutions/fingerprint.ex` — no change.
- `lib/jido_claw/solutions/trust.ex` — no change.
- `lib/jido_claw/tools/store_solution.ex` — context wiring.
- `lib/jido_claw/tools/find_solution.ex` — context wiring.
- `lib/jido_claw/tools/verify_certificate.ex` — code interface
  swap (lines 55, 219, 222).
- `lib/jido_claw/network/node.ex` — defstruct gains
  `tenant_id`/`workspace_id`; all four call sites
  (`broadcast_solution`, `handle_solution_requested`,
  `handle_solution_response`, `store_received_solution`)
  swap to `NetworkFacade`.
- `lib/jido_claw/network/supervisor.ex` — forward `tenant_id`.
- `lib/jido_claw/network/protocol.ex` — docstring update.
- `lib/jido_claw/cli/commands.ex` — `/solutions` REPL command
  swap (lines 256, 280).
- `lib/jido_claw/shell/commands/jido.ex` — `jido solutions find`
  shell command swap (lines 24, 105).
- `lib/jido_claw/cli/presenters.ex` — typespec + presenter swap
  (lines 11, 20).
- `lib/jido_claw/cli/repl/commands/workspace.ex` (or
  equivalent) — add `/workspace embedding` and
  `/workspace consolidation` commands.
- `lib/jido_claw/cli/setup.ex` (wizard) — two new prompts inside
  `Setup.run/1` (after API-key + model steps, before
  `write_config/2`); choices written into `config.yaml` for the
  REPL apply step.
- `lib/jido_claw/cli/repl.ex` — extend
  `ensure_persisted_session/3` (line 506) to apply
  embedding/consolidation policies from config after Workspace
  registration. Skip the apply when the workspace already has a
  non-`:disabled` policy set and the config says `:disabled`
  (don't undo a later `/workspace embedding` change).
- `lib/jido_claw/core/mcp_server.ex` — resolve MCP-mode default
  scope at server boot; wrap solutions tools to inject default
  `tool_context` when callers don't supply one.
- `lib/jido_claw/workspaces/resources/workspace.ex` — extend
  `:set_embedding_policy` action with the transactional row-
  status fix-up.
- `lib/jido_claw/application.ex` — supervision tree changes
  (RatePacer + BackfillWorker after Finch line 103; remove
  legacy Solutions GenServers at lines 131-132);
  Network.Supervisor opts gain `tenant_id`.

**Deleted (after cutover):**
- `lib/jido_claw/solutions/store.ex`
- `lib/jido_claw/solutions/reputation.ex` (GenServer)
- `lib/jido_claw/solutions/solution.ex` (struct)

## Documentation drift to fix in the spec

Found during the codebase audit. Worth updating the spec, but
not blockers:

- `WorkspaceResolver.ensure/1` → `ensure_workspace/3`
  (`lib/jido_claw/workspaces/resolver.ex:17`).
- `lib/jido_claw.ex:29` for the resolver call → actually
  `lib/jido_claw.ex:104`.
- `Network.Node.handle_solution_response/2` line 325 →
  actually line 318.
- `mix jido_claw.migrate.solutions` → `mix jidoclaw.migrate.solutions`
  (project naming convention).
- Voyage API key "via Vault" → read from env at call time.
- `embedding_model` filter via `(embedding_model, tenant_id)`
  btree pre-filter → partial HNSW indexes per model (per
  pgvector docs; the btree pre-filter is dropped).
- Status enum gains `:processing` (claim lease state).
- `Redaction.Transcript` "any binary value that's parseable
  JSON is decoded, redacted, re-encoded" → restricted to
  `:json_aware_keys` opt; default `[]` so callers must opt in.
- Rate-limit budget math: `rpm * window_seconds / 60`, not
  `rpm / window_seconds`.
- `lexical_pool` similarity rank uses a separate raw-lowercased
  query parameter (`$12`), not the LIKE-escaped one.
- Resource module names: `JidoClaw.Workspaces.Workspace` (not
  `Workspaces.Resources.Workspace`); `JidoClaw.Conversations.Session`
  (not `Conversations.Resources.Session`); the new resources
  follow the same flat-module / nested-directory shape:
  `JidoClaw.Solutions.Solution` etc.
- Setup wizard "stamp the freshly registered Workspace row" →
  the wizard runs *before* workspace registration (verified at
  `cli/setup.ex:36-62` and `cli/repl.ex:506`); collect-then-
  apply at the REPL session-persist step.
- `created_by_user_id` populated from `tool_context` →
  ToolContext has no `:user_id` key; column is nullable and
  populated only from web/RPC paths that have a current_user.
- §0.5.2 cross-tenant FK invariant validates tenant equality
  → also validates `session.workspace_id == workspace_id`
  when `session_id` is set, so same-tenant wrong-workspace
  rows are rejected.
- MCP server scope unmentioned → MCP solutions tools don't
  receive `tool_context` from the transport; the MCP server
  resolves a default scope at boot from its `cwd` and injects
  it via a tools wrapper.
- `Solution.stats/1` action — replaces `Solutions.Store.stats/0`
  for the `/solutions` REPL stats branch.

## Verification — end-to-end

Two pass-conditions for the bundle:

1. **`mix test` green** with all §1.8 acceptance gates plus the
   review-driven additions:
   - Substring-superset
   - Lexical-index engaged (EXPLAIN ANALYZE trigram)
   - LIKE-wildcard escape
   - Soft-delete leakage
   - Cross-workspace isolation
   - Cross-tenant FK validation
   - Policy transition row-status fix-up
   - Generated columns sanity
   - Inbound network ingress through NetworkFacade
   - **Outbound network scope (new)** — `broadcast_solution`,
     `handle_solution_requested`, `find_solution_by_id` paths
     all read with the node's scope.
   - Tenant-scoped reputation parity
   - **Concurrent reputation increments (new)** — 100 parallel
     `record_success` calls produce `solutions_verified == 100`.
   - Reputation import-ledger idempotency
   - Embedding rate-limit ceiling
   - Cross-node embedding budget
   - Embedding-policy egress gate
   - **Initial-status-from-policy (new)** — disabled-workspace
     row stamps `:disabled`.
   - **Claim atomicity (new)** — two workers, 100 rows,
     each row dispatched exactly once.
   - **Lease expiry (new)** — killed-mid-dispatch row re-claimed
     after 5-minute lease window. Pins the two-branch WHERE in
     the periodic-scan claim SQL (`pending OR (processing AND
     lease_expired)`); without the second branch, the row sits
     forever.
   - **Hint-by-id bypasses age guard (new)** — write a row,
     observe via the `after_transaction` hint that the
     BackfillWorker dispatches it within ~1s in dev (not
     waiting the 1-minute periodic-scan age guard).
   - **MCP default-scope injection (new)** — boot the MCP
     server with a temp `cwd`, call `StoreSolution` with no
     `tool_context`, assert the resulting Solution row carries
     `tenant_id: "default"` and the resolved `workspace_id`.
   - **Cross-workspace FK rejection (new)** — construct a
     `:store` call with `tenant_id: A`, `workspace_id: WS_a`
     (matching tenant) but `session_id: S_b` (a session whose
     `workspace_id != WS_a`). Assert
     `:cross_tenant_fk_mismatch`. Same-tenant
     wrong-workspace rejection.
   - **Similarity-rank correctness (new)** — `100%` query
     ranks `100%` higher than `100ish` (depends on the
     `$10`/`$12` split).
   - **JSON re-encode gate (new)** — Solution content with
     JSON-shaped substring stays byte-equivalent through the
     redactor.
   - Round-trip sanitized fixture (byte-equivalent)
   - Round-trip redaction-delta fixture (manifest match)
2. **Manual smoke test in REPL** — `mix jidoclaw`, run
   `/workspace embedding default`, store and recall a small
   solution, observe the row materializes in `solutions` with
   `embedding_status: :ready` after a backfill cycle (~1s in
   dev with `:scan_interval_seconds: 30`).

## Out of scope for v0.6.1

- Per-tenant Voyage rate budgets (cluster-global per API key).
- Auto-detection of Voyage account tier.
- Mixed-model embedding rollout / per-row
  `embedding_dimensions` column.
- Async / batched policy-transition fix-up for very large
  workspaces (synchronous bounded UPDATE only).
- `Memory.Fact` resource (Phase 3) — but `Redaction.Transcript`
  ships ready for Phase 2/3 with the `:json_aware_keys` opt.
- Multi-tenant network presence — the network layer is per-
  tenant; cross-tenant network shares are out of scope.
