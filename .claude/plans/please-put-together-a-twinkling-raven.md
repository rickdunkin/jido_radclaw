# Phase 3 — Memory Subsystem Implementation Plan

## Context

`docs/plans/v0.6/phase-3-memory.md` (1,902 lines) specifies the
v0.6.3 release: replace today's `JidoClaw.Memory` GenServer + ETS +
`.jido/memory.json` with a multi-scope, bitemporal, multi-tier Ash
subsystem (Block / Fact / Episode / FactEpisode / Link /
ConsolidationRun) backed by Postgres, three write sources (model,
user, scheduled consolidator), hybrid retrieval (FTS + pgvector +
trigram), and a frozen-snapshot system prompt that lets
`anthropic_prompt_cache: true` actually fire across turns.

Phases 0/1/2 have shipped (commits `98382d1`, `2b53296`, `3dc1727`),
so Phase 3 builds on a real Ash data layer with redaction modules,
hybrid retrieval patterns (`Solutions.HybridSearchSql`), embedding
infrastructure (`Voyage`/`Local`/`BackfillWorker`/`PolicyResolver`),
Workspace-policy plumbing (`embedding_policy`/`consolidation_policy`),
Conversation transcripts, and tenant-stamped FK invariants.

The intended outcome: the agent's memory becomes self-improving (a
frontier-model harness consolidates raw transcripts and Facts into
durable Block content every 6 hours per scope), retrievable
(hybrid search across FTS, vector, trigram pools with scope/source
precedence), and time-travelable (bitemporal `valid_at`/`invalid_at`
× `inserted_at`/`expired_at`). Without it, today's substring-matched
ETS memory remains the bottleneck — every `recall("api")` is a sequential
scan, every prompt build busts the cache, and there's no Block tier
at all.

## Ship cadence

Phase 3 ships as **three sub-releases** so each is independently
reviewable and `main` stays release-able between them:

- **v0.6.3a — Data layer & retrieval.** Resources + migrations +
  writes + hybrid retrieval + tool/CLI surface (`Remember`/`Recall`/
  `Forget`, `/memory blocks`/`list`/`search`/`save`/`forget`). The
  embeddings backfill worker extends to `Memory.Fact`. The legacy
  `JidoClaw.Memory` GenServer is removed; `mix jidoclaw.migrate.memory`
  + `mix jidoclaw.export.memory` ship here so users can move data
  before depending on the consolidator. Sections 1, 2, 3, 4, 5, 6,
  8, 11 (migration tasks + GenServer decommissioning), and the
  matching subset of §12 verification.
- **v0.6.3b — Consolidator runtime & frozen-snapshot prompt.**
  Prompt builder rewrite for snapshot caching, `Conversations.Session.metadata`
  wiring, `Cron.Scheduler.start_system_jobs/0` + worker
  system-job mode, per-session `sandbox_mode` knob, `Memory.Consolidator`
  + clustering + staging buffer + transactional publish, scoped
  in-process HTTP MCP server, `Fake` runner for tests, `ClaudeCode`
  runner extension to inject `--mcp-config` and parse stream-json
  tool-call events. Adds `/memory consolidate` + `/memory status`
  CLI commands. Sections 7, 9 (minus 9a Codex), 10, and the
  matching §12 gates.
- **v0.6.3c — Codex sibling runner.** `Forge.Runners.Codex` with
  `sync_host_codex_config/1`, configurable as `harness: :codex`
  on the consolidator. Section 9a + the relevant §12 cross-runner
  gates. Smallest ship of the three.

Below, each implementation section is tagged with the sub-ship it
belongs to. Decommissioning details are folded into 3.0a since the
new write paths land there; the `Cron`/`prompt`/`Forge` glue lands
in 3.0b alongside the consolidator that needs it.

## Pre-existing state (verified)

- **Phase 0 done:** `Workspaces.Workspace`, `Conversations.Session`,
  `RequestCorrelation`. `Workspace` already carries
  `embedding_policy` and `consolidation_policy` (default `:disabled`).
  `Project` and `Accounts.User` lack `tenant_id` (acknowledged debt;
  cross-tenant validation skips with telemetry per plan §0.5.2).
- **Phase 1 done:** `Solutions.Solution` resource, hybrid retrieval
  (`solutions/hybrid_search_sql.ex`), `SearchEscape.escape_like/1` +
  `lower_only/1`, `Embeddings.Voyage` (with `embed_for_storage/{1,2}`
  + `embed_for_query/{1,2}`, **not** `embed/2`), `Embeddings.Local`,
  `BackfillWorker` (`Process.send_after :scan` loop with
  `FOR UPDATE SKIP LOCKED`), `PolicyResolver`, `RatePacer`,
  `DispatchWindow`. Redaction: `Patterns` (URL-userinfo already
  included), `Embedding.redact/1` (returns `{redacted, count}`),
  `Transcript.redact/2` (with `:json_aware_keys` opt).
- **Phase 2 done:** `Conversations.Message` (writable `inserted_at`,
  `import_hash` partial identity, `:append`/`:import` actions, nested
  `Changes.RedactContent` + `Changes.AllocateSequence` +
  `Changes.DenormalizeTenant` + `Changes.ValidateCrossTenantFk`),
  `Recorder` GenServer subscribing to `ai.tool.started`,
  `ai.tool.result`, `ai.llm.response`, `ai.request.completed`,
  `ai.request.failed` SignalBus topics. Mix tasks namespaced
  `mix jidoclaw.*` (single word, e.g. `jidoclaw.export.conversations`),
  not `jido_claw.*`.
- **`JidoClaw.Repo.installed_extensions/0`** today returns
  `["ash-functions", "citext", "pg_trgm", "vector"]`. **`pgcrypto`
  is NOT present.**
- **`config :jido_claw, :ash_domains`** today registers `Accounts`,
  `Projects`, `Security`, `Forge.Domain`, `Orchestration`, `GitHub`,
  `Folio`, `Reasoning.Domain`, `Workspaces`, `Conversations`,
  `Solutions.Domain`, `Embeddings.Domain`. Phase 3 appends
  `JidoClaw.Memory.Domain`.
- **`JidoClaw.ToolContext`** canonical keys: `:project_dir`,
  `:tenant_id`, `:session_id`, `:session_uuid`, `:workspace_id`,
  `:workspace_uuid`, `:user_id`, `:agent_id`. **No `:project_id`,
  no `:scope_kind`** — `Memory.Scope.resolve/1` derives both at
  call time from the populated FKs (decision: minimize `tool_context`
  churn, scope handling stays Memory-local).
- **Forge runners** at `lib/jido_claw/forge/runners/`: `claude_code.ex`
  (CLI runner via `claude -p ... --output-format stream-json`),
  `custom.ex`, `shell.ex`, `workflow.ex`. **No `Codex`, no `Fake`.**
  `claude_code.ex` does **not** inject `--mcp-config` today and
  discards intermediate stream-json events (only the final
  `{type: "result"}` row is parsed). `Forge.Resources.Session`
  lacks `tenant_id`. Sandbox is selected globally via
  `Application.get_env(:jido_claw, :forge_sandbox, ...)`, not
  per-session.
- **`JidoClaw.Cron.Scheduler`** at `lib/jido_claw/platform/cron/`
  has `load_persistent_jobs/2`, `schedule/2`, `unschedule/2`,
  `list_jobs/1`, `trigger/2`. No `start_system_jobs/0` exists.
  `Cron.Worker` today only routes through `JidoClaw.chat/4`; system
  jobs that bypass the chat API need a new mode.
- **Prompt builder** at `lib/jido_claw/agent/prompt.ex:276`:
  `build/1` is called from `lib/jido_claw/startup.ex:84` and
  `lib/jido_claw/cli/commands.ex:760` — already mostly static
  but `load_memories()`/`load_agent_count()`/`git_branch()`
  rebuild on every call. Frozen-snapshot rewrite has a clean seam.
  `Conversations.Session.metadata` (jsonb, default `%{}`) is
  available as the snapshot sidecar.
- **Existing tools/CLI** to preserve: `lib/jido_claw/tools/remember.ex`,
  `lib/jido_claw/tools/recall.ex` (docstring claims "substring match
  on key, content, and type"), `lib/jido_claw/cli/commands.ex` lines
  186-252 (`/memory search`, `/memory save`, `/memory forget`,
  `/memory` list). **No `Memory.Forget` tool exists today.**
- **Tests pinning behavior:** `test/jido_claw/memory_test.exs`,
  `test/jido_claw/tools/remember_test.exs`,
  `test/jido_claw/tools/recall_test.exs`,
  `test/jido_claw/prompt_test.exs:270`.

## Implementation plan

### 1. Domain skeleton + cross-tenant helper + extensions  (3.0a)

- Add `pgcrypto` to `JidoClaw.Repo.installed_extensions/0`
  (`lib/jido_claw/repo.ex`). Generated `content_hash` (§3.6) needs
  it.
- Create `JidoClaw.Memory.Domain` at
  `lib/jido_claw/memory/domain.ex` (mirror `Solutions.Domain` shape,
  `.Domain` suffix matches the newer convention). Append to
  `config/config.exs` `:ash_domains` list.
- **Extract a shared cross-tenant FK validator.** Today every
  resource inlines its own `Changes.ValidateCrossTenantFk`. Memory
  has 4+ resources doing the same dance, so factor a helper:
  `JidoClaw.Security.CrossTenantFk` at
  `lib/jido_claw/security/cross_tenant_fk.ex` exposing
  `validate(changeset, [{:workspace_id, Workspace}, ...])`. Keep
  the inline copies in `Solutions`/`Conversations` untouched (no
  refactor sweep — just a new helper Memory uses). The helper
  also handles the "parent has no `tenant_id` column" debt cases
  (`Project`, `Forge.Session`) by skipping with a
  `:tenant_validation_skipped_for_untenanted_parent` telemetry
  event per plan §0.5.2.
- Create `JidoClaw.Memory.Scope` at `lib/jido_claw/memory/scope.ex`:
  - `resolve(tool_context) :: {:ok, scope_record} | {:error, reason}`
    where `scope_record = %{tenant_id, scope_kind, user_id,
    workspace_id, project_id, session_id}`. Derives `scope_kind`
    by checking which FKs are populated, walking inward from
    `:user` → `:workspace` → `:project` → `:session`. Resolves
    ancestors from `Workspace`/`Session` rows to populate the full
    chain when known.
  - `chain(scope_record) :: [{scope_kind, fk}]` — for retrieval's
    scope precedence chain query.
  - `lock_key(tenant_id, scope_kind, fk_id) :: bigint` —
    `:erlang.phash2/2` masked to bigint for `pg_try_advisory_lock`
    (§3.15 step 0).

### 2. Memory resources (schema + actions + identities)  (3.0a)

Files under `lib/jido_claw/memory/resources/`. Each resource gets
its own file per plan §3.1. Mirror `Solutions.Solution`'s style for
generated columns (Ash declares `generated?: true, writable?: false`;
hand-written migration writes the `GENERATED ALWAYS AS (...) STORED`
DDL via `execute/1`).

#### 2a. `Memory.Block` (curated tier)

- Attributes per plan §3.4: scope cols, bitemporal cols, `label`,
  `description`, `value`, `char_limit` (default 2000), `pinned`
  (default true), `position`, `source` (`:user | :consolidator`).
- Four partial unique identities (`unique_label_per_scope_user/_workspace/_project/_session`)
  each `WHERE invalid_at IS NULL AND tenant_id IS NOT NULL AND <fk> IS NOT NULL`.
  All four registered in `postgres.identity_wheres_to_sql`.
- Actions: `:write`, `:revise`, `:invalidate`, `:for_scope_chain`,
  `:history_for_label`. No `:destroy`.
- `before_action` hooks: scope FK invariant, `CrossTenantFk.validate`,
  char-limit cap, BlockRevision tombstone write (paired with the
  live mutation in one transaction).
- Index `(tenant_id, scope_kind, label, invalid_at)` btree;
  `(tenant_id, source, inserted_at)` btree.

#### 2b. `Memory.BlockRevision` (append-only history)

- Attributes per plan §3.5: `id`, `block_id`, `tenant_id` (denorm
  + validated), `scope_kind` + scope FKs (denorm), `value`,
  `source`, `written_by`, `reason`, `inserted_at`. No update, no
  destroy.
- Single `:create_for_block` action invoked from `Block.:write` /
  `:revise` / `:invalidate`'s `before_action` hook.

#### 2c. `Memory.Fact` (searchable tier)

- Attributes per plan §3.6: scope cols, bitemporal cols, `label`
  (nullable), `content`, `content_hash` (generated `bytea`,
  `digest(content, 'sha256')`), `embedding vector(1024)`,
  `embedding_status` (`:pending | :ready | :failed | :disabled`),
  `embedding_attempt_count`, `embedding_next_attempt_at`,
  `embedding_last_error`, `embedding_model`, `search_vector`
  (generated tsvector over `label || content || tags`),
  `lexical_text` (generated lowercased concat), `tags`, `source`
  (`:model_remember | :user_save | :consolidator_promoted | :imported_legacy`),
  `trust_score`, `import_hash` (nullable).
- `inserted_at` and `valid_at` declared writable per plan
  §3.6 (mirrors `Conversations.Message.inserted_at` shape).
- Identities: 4 × `unique_active_label_per_scope_*` (partial,
  `WHERE label IS NOT NULL AND invalid_at IS NULL AND tenant ...
  AND <fk> ...`); 4 × `unique_active_promoted_content_per_scope_*`
  (partial, `WHERE source = 'consolidator_promoted' AND invalid_at
  IS NULL AND content_hash IS NOT NULL AND ...`); 1 ×
  `unique_import_hash` (partial, `WHERE import_hash IS NOT NULL`).
  All 9 in `postgres.identity_wheres_to_sql`.
- Actions per plan §3.6:
  - `:record` — single create action accepting `scope_kind` + scope
    FKs + content. `before_action` chain: scope FK invariant,
    `CrossTenantFk.validate` against every populated scope FK,
    `Redaction.Memory.redact_fact!`, `invalidate_prior_active_label`
    (the invalidate-and-replace step inside one transaction).
  - `:import_legacy` — accepts `inserted_at`, `valid_at`, `label`,
    `import_hash`; fixes `source: :imported_legacy`. Uses the same
    `CrossTenantFk` validation. Idempotent via
    `upsert?: true, upsert_identity: :unique_import_hash`.
  - `:promote` — consolidator-only, bumps trust + flips source.
  - `:invalidate_by_id`, `:invalidate_by_label` (the latter requires
    `source` argument per plan §3.6).
  - `:search` — takes precomputed args from `Memory.Retrieval`.
  - `:for_consolidator` — since-watermark, scope-filtered.
- Indexes: `(tenant_id, scope_kind, valid_at)` btree, `search_vector`
  GIN, `(tenant_id, source, inserted_at)` btree, plus the partial
  unique indexes. HNSW + GIN-trigram ship as hand-written migration
  blocks (mirrors `Solutions` migration shape, including partial
  HNSW per `embedding_model`).

#### 2d. `Memory.Episode` (immutable provenance)

- Attributes per plan §3.7: scope cols (no bitemporal), `kind`,
  `source_message_id`, `source_solution_id`, `content`, `metadata`,
  `inserted_at`. No update, no destroy.
- Actions: `:record` (with scope FK invariant, `CrossTenantFk` over
  scope FKs *plus* `source_message_id` and `source_solution_id`,
  redaction via `Transcript.redact/2`), `:for_consolidator`,
  `:for_fact` (joins through `FactEpisode`).
- Indexes: `(tenant_id, scope_kind, inserted_at)`,
  `(tenant_id, source_message_id)` partial,
  `(tenant_id, source_solution_id)` partial.

#### 2e. `Memory.FactEpisode` (M:N join)

- Attributes per plan §3.7.1: `id`, `fact_id`, `episode_id`,
  `tenant_id` (denorm from `fact_id`, validated against
  `episode_id.tenant_id`), `role` (`:primary | :supporting |
  :contradicting`), `inserted_at`.
- Identity `unique_pair` on `[fact_id, episode_id]`.

#### 2f. `Memory.Link` (graph edge)

- Attributes per plan §3.8: `from_fact_id`, `to_fact_id`,
  `tenant_id` + `scope_kind` (denormalized from `from_fact_id`,
  validated to match `to_fact_id`), `relation`, `reason`,
  `confidence`, `inserted_at`.
- `before_action` rejects cross-tenant edges (`:cross_tenant_link`)
  and cross-scope edges (`:cross_scope_link`).
- Indexes: `(tenant_id, from_fact_id, relation)`,
  `(tenant_id, to_fact_id, relation)`.

#### 2g. `Memory.ConsolidationRun` (watermark + audit)

- Attributes per plan §3.9: scope cols, `started_at`, `finished_at`,
  4 watermark cols (`messages_processed_until_at` + `_id`,
  `facts_processed_until_at` + `_id`), counters
  (`messages_processed`, `facts_processed`, `blocks_written`,
  `blocks_revised`, `facts_added`, `facts_invalidated`,
  `links_added`), `status`, `error`, `forge_session_id` (FK,
  `tenant` validation skipped per debt note), `harness`,
  `harness_model`. Append-only.
- Actions: `:record_run`, `:latest_for_scope`, `:history_for_scope`.
- Indexes: `(tenant_id, scope_kind, scope_id, started_at DESC)`,
  `(tenant_id, status, started_at)`,
  `(forge_session_id)` partial.

#### 2h. Migration

- Single migration: `priv/repo/migrations/<ts>_v063_memory.exs`.
  - Defines IMMUTABLE wrapper functions (`memory_search_vector`,
    `memory_lexical_text`) for the generated-column expressions
    — same workaround Phase 1 used for Solutions (immutable
    function inside a STORED expression).
  - Uses `add :search_vector, :tsvector, generated: "ALWAYS AS (...) STORED"`
    plus `add :content_hash, :bytea, generated: "ALWAYS AS (digest(content, 'sha256')) STORED"`.
  - Hand-written `execute/1` blocks for partial HNSW indexes
    (`CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)
    WHERE embedding_model = 'voyage-4-large'`, plus the
    `mxbai-embed-large` sibling) and the GIN trigram index
    (`CREATE INDEX ... USING gin (lexical_text gin_trgm_ops)`).

### 3. Write paths  (3.0a)

- New module `JidoClaw.Security.Redaction.Memory` at
  `lib/jido_claw/security/redaction/memory.ex` per plan §3.10.
  Wraps `Patterns.redact/1` (which already includes URL-userinfo)
  and adds metadata jsonb key scrubbing for known sensitive keys.
  Idempotent.
- Replace `lib/jido_claw/platform/memory.ex` GenServer with a thin
  module `JidoClaw.Memory` at `lib/jido_claw/memory.ex` (or
  `lib/jido_claw/memory/api.ex`, depending on naming preference)
  exposing:
  - `remember_from_model(attrs, tool_context)` — sets
    `source: :model_remember`, `trust_score: 0.4`. Calls
    `Memory.Scope.resolve/1` then `Memory.Fact.create :record`.
    Returns `:ok` on every persistence path (preserve today's
    always-`:ok` contract that `tools/remember.ex:42` and
    `cli/commands.ex:209` rely on; surfaces errors via Logger
    rather than the return tuple).
  - `remember_from_user(attrs, tool_context)` — sets
    `source: :user_save`, `trust_score: 0.7`.
  - `forget(label, tool_context, opts)` — wraps
    `Memory.Fact.invalidate_by_label`. `opts[:source]` defaults to
    `:user_save` per plan §3.12; `:all` invalidates every active
    fact at `(label, scope, source)` regardless of source.
  - `recall(query, opts)` — pass-through to
    `Memory.Retrieval.search/2`. **Returns the same
    `%{key, content, type, created_at, updated_at}` map shape that
    today's `record_to_entry/1` produces** so the unchanged
    `tools/recall.ex` formatter and `cli/presenters.ex` formatter
    keep working.
- Drop `JidoClaw.Memory` GenServer child from
  `lib/jido_claw/application.ex` Core children list. Remove
  `lib/jido_claw/platform/memory.ex` entirely (per §3.18). Drop
  `Jido.Memory.Store.ETS` dep from `mix.exs` if unused (verify;
  per plan §3.18 confirm "still in use? Check; if not, drop").

### 4. Tool surface (model-facing)  (3.0a)

- **`Memory.Remember` tool**
  (`lib/jido_claw/tools/remember.ex`): swap implementation to call
  `JidoClaw.Memory.remember_from_model/2` with the action's
  `tool_context`. Schema unchanged (`key`/`content`/`type`).
  Internal mapping per plan §3.11: `key → Fact.label`,
  `content → Fact.content`, `type → tag` (single-element list).
- **`Memory.Recall` tool** (`lib/jido_claw/tools/recall.ex`): swap
  implementation to call `JidoClaw.Memory.recall/2`. Schema
  unchanged. Docstring kept as-is — the substring superset is
  preserved (lexical pool over `lexical_text` GIN trigram index).
- **`Memory.Forget` tool**
  (`lib/jido_claw/tools/forget.ex`, **new**): registered in
  `lib/jido_claw/agent/agent.ex` tool list. Schema:
  `id` (uuid, optional) or `label` (string, required if no `id`).
  Calls `Memory.Fact.invalidate_by_id` (preferred) or
  `Memory.Fact.invalidate_by_label` with
  `source: :model_remember` only — model can't invalidate user
  rows (plan §3.11).

### 5. Retrieval API  (3.0a)

- Module `JidoClaw.Memory.Retrieval` at
  `lib/jido_claw/memory/retrieval.ex`. Public:
  - `search(query, opts)` — orchestrates Block tier (no search,
    return scope-chain Blocks ordered by `position`), Fact tier
    (delegates to `Memory.HybridSearchSql.run/1`), Episode tier
    (FTS + lexical only, no cosine).
  - Bitemporal predicate matrix per plan §3.13 — four modes
    (current truth / world / system / full) selecting the right
    `valid_at`/`invalid_at`/`inserted_at`/`expired_at` predicate
    set.
  - Scope/source precedence applied **inside the SQL** via the
    `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` window
    function pseudocode in plan §3.13. `dedup: :by_precedence`
    (default) | `:none`. `metadata.shadowed_by` projection in
    Elixir post-fetch.
- Module `JidoClaw.Memory.HybridSearchSql` at
  `lib/jido_claw/memory/hybrid_search_sql.ex` — mirrors
  `solutions/hybrid_search_sql.ex` but uses **RRF**
  (`1.0/(60 + r_fts) + 1.0/(60 + r_ann) + 1.0/(60 + r_lex)`) per
  plan §3.13 SQL pseudocode rather than Solutions' weighted-sum.
  Documented divergence: Solutions stays weighted-sum (no behavior
  change in Phase 3). Reuses `SearchEscape.escape_like/1` +
  `lower_only/1`.
- IMMUTABLE wrapper functions `memory_search_vector` /
  `memory_lexical_text` for the generated-column expressions
  (mirrors Solutions §1.2 workaround).

### 6. CLI surface  (3.0a, plus `/memory consolidate` + `/memory status` in 3.0b)

- Update `lib/jido_claw/cli/commands.ex` `/memory` block (lines
  186-252):
  - `/memory blocks` — list current scope's Blocks ordered by
    position. Calls `Memory.Block.for_scope_chain` then formats.
  - `/memory blocks edit <label>` — open `$EDITOR` on Block value;
    on save, call `Memory.Block.revise` (writes a
    `BlockRevision` with `source: :user`).
  - `/memory blocks history <label>` — `Block.history_for_label`
    walk.
  - `/memory list` — preserved (use `Retrieval.search` with empty
    query + recency sort, mirrors today's `list_recent(20)`).
  - `/memory search <q>` — preserved (calls `Retrieval.search/2`).
  - `/memory save <label> <content>` — preserved (calls
    `Memory.remember_from_user/2`).
  - `/memory forget <label> [--source model|user|all]` — default
    `:user`; on multi-source ambiguity without `--source`, list
    candidates and prompt for selection (uses
    `dedup: :none` to surface all matches).
  - `/memory consolidate [--scope kind=fk]` — calls
    `Memory.Consolidator.run_now/1`. Returns `{:error,
    :scope_busy}` cleanly when locked.
  - `/memory status` — uses `ConsolidationRun.history_for_scope`
    + per-tier counts.
- Update `lib/jido_claw/cli/branding.ex:166-169` and
  `lib/jido_claw/cli/presenters.ex:68` (`format_memory_results/1`)
  to handle the new fields without breaking the
  `String.slice(mem.updated_at, 0, 10)` shape today's display
  uses.

### 7. Frozen-snapshot system prompt  (3.0b)

- Rewrite `lib/jido_claw/agent/prompt.ex`:
  - New `build_snapshot(scope, tool_context)` returns a deterministic
    string composed of: static base body, skills snapshot,
    environment (`cwd`, `project_type`, `git_branch` cached at
    snapshot time), JIDO.md content, **Block tier rendered for the
    scope chain** (joined by separators, deduped by label per
    Block precedence — calls `Memory.Block.for_scope_chain`).
  - **Remove `agent_count` from the static prefix** (cache-buster);
    surface via a tool only (per plan §3.14 step 4). `git_branch`
    is captured at snapshot time, not per turn.
  - Drop `load_memories()` / `memories_section()` entirely — Facts
    now reach the model via `recall`, not via the prompt.
- Snapshot lifecycle:
  - On `Conversations.Session` create (or first `:append`), the
    Recorder triggers a snapshot build and stores it in
    `Conversations.Session.metadata["prompt_snapshot"]`. Field is
    already jsonb-shaped.
  - The agent uses the snapshot for `system_prompt` going forward.
    Mid-session Block writes update Block rows but **do not**
    invalidate the snapshot (model sees new Blocks via tool
    response only, until the next session).
  - Update callers: `lib/jido_claw/startup.ex:84` (boot — uses the
    pre-snapshot static base + a placeholder), CLI session creation
    (build snapshot lazily on first append).
- Acceptance: telemetry emitted by the Anthropic provider shows
  `cache_hits > 0` over a 3-turn session (intra-turn ReAct already
  caches; this gate is inter-turn).

### 8. Embeddings pipeline (`Memory.Fact`)  (3.0a)

- Extend `JidoClaw.Embeddings.BackfillWorker` (no rename) to run
  against `Memory.Fact` in addition to `Solutions.Solution`. Two
  options the explorer didn't pin down — pick the simplest:
  - **Approach:** Generalize the worker to accept a `resource`
    discriminator in its scan loop, with two concrete query
    bodies. Mirror the `Changes.ResolveInitialEmbeddingStatus`
    + `Changes.HintBackfillWorker` pattern from
    `Solutions.Solution` for `Memory.Fact.:record` /
    `:import_legacy`. Re-read `Workspace.embedding_policy` at
    execute time via the existing `PolicyResolver`.
- Voyage call: `Embeddings.Voyage.embed_for_storage/1` (default
  `voyage-4-large`) at write, `embed_for_query/1` (default
  `voyage-4`) at read. Both paths run input through
  `Redaction.Embedding.redact/1` (which returns `{redacted, count}`
  — destructure properly).
- The `embedding_model = $X` filter in `Memory.HybridSearchSql`
  matches the partial HNSW index (mirrors Solutions §1.4
  cross-policy isolation contract).

### 9. Consolidator infrastructure  (3.0b, except 9a Codex which is 3.0c)

The single highest-risk piece. Builds the substrate the
`Memory.Consolidator` runs on.

#### 9a. `Codex` runner  (3.0c)

- New `JidoClaw.Forge.Runners.Codex` at
  `lib/jido_claw/forge/runners/codex.ex`. Mirrors `ClaudeCode`:
  implements the `JidoClaw.Forge.Runner` behaviour (`init/2`,
  `run_iteration/3`, `apply_input/3`); spawns `codex` CLI with the
  equivalent `--mcp-config` and stream-json output flags;
  `sync_host_codex_config/1` reads from `~/.codex/`. If
  credentials are missing, the runner returns
  `{:error, :no_credentials}` so the consolidator can write
  `status: :failed, error: :no_credentials` per plan §3.15.

#### 9b. `Fake` runner (test substrate)

- New `JidoClaw.Forge.Runners.Fake` at
  `lib/jido_claw/forge/runners/fake.ex`. Replays a scripted list of
  tool calls + a final `commit_proposals` (or a deferred / failure
  variant) against the per-run scoped MCP server. Test-only;
  registered behind a `harness: :fake` knob.

#### 9c. Per-session sandbox knob

- Add a `sandbox_mode` field to `Forge.Resources.Session.spec`
  (jsonb), threading it through `Forge.Manager.start_session/2`.
  Today the sandbox impl is read globally from
  `Application.get_env(:jido_claw, :forge_sandbox, ...)` in
  `lib/jido_claw/forge/sandbox.ex:45`. Patch the dispatch to prefer
  `session.spec[:sandbox_mode]` when set, falling back to the app
  env. Consolidator runs always set `sandbox_mode: :local`
  (skipping Docker) per plan §3.15 — no untrusted code runs, just
  memory proposals.

#### 9d. Scoped MCP server  (in-process HTTP)

- New module `JidoClaw.Memory.Consolidator.Tools` at
  `lib/jido_claw/memory/consolidator/tools.ex`. Defines the
  scoped tool actions per plan §3.15 step 4 table:
  `list_clusters`, `get_cluster`, `get_active_blocks`,
  `find_similar_facts`, `propose_add`, `propose_update`,
  `propose_delete`, `propose_block_update`, `propose_link`,
  `defer_cluster`, `commit_proposals`. Each is a `Jido.Action`-style
  module that mutates the per-run staging buffer (held by the
  consolidator worker process, addressed via a registry-keyed pid).
- New module `JidoClaw.Memory.Consolidator.MCPServer` at
  `lib/jido_claw/memory/consolidator/mcp_server.ex`.
  **In-process HTTP transport via Bandit.** On consolidator-run
  start, the worker:
  1. Builds a per-run tool list (the 11 actions above), bound to
     this run's staging-buffer pid.
  2. Starts a Bandit endpoint on a free port (`port: 0` →
     `:ranch.get_port/1`) hosting the tools via Anubis's HTTP/SSE
     handler shape, mirroring `lib/jido_claw/core/mcp_server.ex`'s
     `use Jido.MCP.Server` declaration but with the run-scoped
     tool list resolved at runtime.
  3. Writes a temp JSON file (`Briefly` or `:proc_lib.tmp_name`)
     containing the harness-format `mcpServers` config:
     ```json
     {"mcpServers":{"consolidator":{"type":"http",
       "url":"http://127.0.0.1:<port>"}}}
     ```
  4. Passes the temp file path to the runner as
     `--mcp-config <path>`; runner injects it into the harness
     CLI invocation.
  5. On `commit_proposals` (or timeout / max-turns / harness
     failure), the worker tears down the Bandit endpoint and
     unlinks the temp config file. Lifetime is bounded by the
     `try/after` block around the lock acquisition.
- The Anubis `tools` Peri-validation shim
  (`lib/jido_claw/core/anubis_tools_handler_patch.ex`) already
  patches the global server's dispatch path; since the
  per-session server uses the same Anubis substrate, the shim
  applies automatically.
- New module `JidoClaw.Memory.Consolidator.Proposals` at
  `lib/jido_claw/memory/consolidator/proposals.ex`. The staging
  buffer + transactional publication (§3.15 step 7). Validates
  staged batch (per-block char-limit, link cap of 5 per source,
  invalidate-and-replace pairing) and commits inside one
  `JidoClaw.Repo.transaction/1`.
- New module `JidoClaw.Memory.Consolidator.Cluster` at
  `lib/jido_claw/memory/consolidator/cluster.ex`. Top-k vector
  similarity grouping (k=5 default), centred on the highest-trust
  member. Deterministic, no LLM call (§3.15 step 3).
- New module `JidoClaw.Memory.Consolidator.Prompt` at
  `lib/jido_claw/memory/consolidator/prompt.ex`. Renders the
  harness prompt from clusters + Block tier.

#### 9e. Cron scheduler hook

- Add `JidoClaw.Cron.Scheduler.start_system_jobs/0` at
  `lib/jido_claw/platform/cron/scheduler.ex`. Called from
  `lib/jido_claw/application.ex` boot path. Registers the
  consolidator as a system-level cron job (distinct from
  user-defined `.jido/cron.yaml` jobs, which today's
  `load_persistent_jobs/2` handles).
- Extend `JidoClaw.Cron.Worker` with a new mode (e.g. `:system_job`)
  that runs an arbitrary `{module, function, args}` rather than
  going through `JidoClaw.chat/4`. Today's `worker.ex:116` only
  routes through chat; system jobs that bypass chat (the
  consolidator drives its own Forge session) need this seam.

### 10. Consolidator implementation  (3.0b)

`JidoClaw.Memory.Consolidator` at `lib/jido_claw/memory/consolidator.ex`
— GenServer or per-tick `Task.Supervisor` task; pick GenServer for
the per-scope supervision and lock semantics. One worker per
in-flight scope at a time, bounded by `max_concurrent_scopes`.

Per-run flow (one scope, one tick) follows plan §3.15 exactly:

- **Step -1:** Resolve `Workspace.consolidation_policy` for the
  scope. `:user` scope rolls up via `MIN(:disabled < :local_only <
  :default)` aggregate over every workspace under that user — one
  aggregate query, not a loop. If `:disabled` → write a
  `ConsolidationRun{status: :skipped, error:
  :consolidation_disabled}` and exit before any input load. If
  `:local_only` and the local-runner branch isn't implemented →
  `:skipped, error: :consolidation_local_runner_unavailable`.
- **Step 0:** `Repo.checkout/2` then `pg_try_advisory_lock` on
  `Memory.Scope.lock_key/3`. Session-level lock, **not xact** —
  the harness window is many minutes and an xact lock would force
  a long-held write transaction. On failure → `:skipped, error:
  :scope_busy` and exit.
- **Step 1:** Read the two composite watermarks from
  `ConsolidationRun.latest_for_scope` (filtered to
  `status: :succeeded`).
- **Step 2:** Load inputs (`Conversations.Message`s and qualifying
  `Memory.Fact`s including `:imported_legacy`) ordered by
  `(inserted_at, id)`, capped at `max_messages_per_run` and
  `max_facts_per_run`. Pre-flight `min_input_count` gate: if total
  < threshold → `:skipped, error: :insufficient_inputs`, release
  lock, exit.
- **Step 3:** In-memory clustering (top-k vector similarity).
- **Step 4:** Spawn Forge session with the configured runner
  (`harness: :claude_code | :codex | :fake`),
  `sandbox_mode: :local`, scoped MCP server up. Prompt rendered
  from clusters + Block tier. Harness drives proposals through
  the staging buffer; emits `commit_proposals` when done. The
  pinned connection has **no transaction open** during the
  harness window.
- **Step 5/6:** Folded into step 4 per plan.
- **Step 7:** Open a short `Repo.transaction/1`. Validate staged
  batch. Insert: new Facts + their `FactEpisode` rows, Fact
  invalidations, Block revisions + Block updates, Links. Compute
  watermarks as the **longest contiguous published prefix** of
  the loaded streams. Insert `ConsolidationRun` row with
  `:succeeded` + counters + `forge_session_id` + harness +
  harness_model.
- **Failure handling:** any error before step 7 aborts without a
  transaction, writes `:failed` row with null watermarks +
  `forge_session_id` populated for transcript reachability. Step
  7 errors roll the whole transaction back. No retry within the
  lock window.

`run_now/1` for `/memory consolidate` and tests goes through the
same lock acquisition; returns `{:error, :scope_busy}` cleanly
on contention. Accepts `override_min_input_count: true` for
"consolidate now even if quiet."

Telemetry: `[:jido_claw, :memory, :consolidator, :run]` events at
start / finish / skip with scope, duration, harness turns, tokens
(best-effort — `:cost_unknown` is not a bug), per-stream
loaded/published counts.

### 11. Migration & decommissioning  (3.0a)

- New mix task `lib/mix/tasks/jidoclaw.migrate.memory.ex`
  (`mix jidoclaw.migrate.memory` — single-word `jidoclaw`
  namespace per existing convention):
  - Walk `.jido/memory.json` files per workspace.
  - `Workspaces.Resolver.ensure_workspace/3` (correct function
    name; not `ensure/1`) for each.
  - For each `entry`: call `Memory.Fact.import_legacy` with
    `tenant_id` from the workspace, `scope_kind: :workspace`,
    `workspace_id`, `user_id` from workspace, `label: entry.key`,
    `content: entry.content` (run through
    `Redaction.Memory.redact_fact!`),
    `tags: [entry.type]`, `valid_at: entry.created_at`,
    `inserted_at: entry.created_at`, `import_hash:
    SHA-256(workspace_id || label || content || inserted_at_ms)`.
  - `:imported_legacy` source is fixed by the action.
  - Embeddings honor `Workspace.embedding_policy` (default
    `:disabled` per Phase 0) — migrated Facts stay
    `embedding_status: :disabled` until the user explicitly
    flips the policy.
- New mix task `lib/mix/tasks/jidoclaw.export.memory.ex` per the
  Phase summary §Rollback caveat and acceptance gate. Two-fixture
  contract: sanitized + redaction-delta. Drops Block / Episode /
  Link tiers with a manifest warning (no v0.5.x equivalent).
- Decommissioning (per plan §3.18):
  - Delete `lib/jido_claw/platform/memory.ex` (the GenServer).
  - Drop the `JidoClaw.Memory` child spec from
    `lib/jido_claw/application.ex`.
  - Drop the `Jido.Memory.Store.ETS` child if any (verify; remove
    the `{:jido_memory, ...}` dep in `mix.exs` if no other
    callers).
  - Leave `.jido/memory.json` on disk as backup (per plan).

### 12. Verification

End-to-end test plan; mirrors plan §3.19 acceptance gates:

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix ash.codegen --check` clean (no pending resource changes).
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors (all 9 partial Memory.Fact
  identities + 4 Memory.Block identities have entries).
- **Resource tests** under `test/jido_claw/memory/` — one file per
  resource: actions, identities, bitemporal behavior, scope-FK
  invariants, cross-tenant rejection.
- **Tool tests** preserved: existing `tools/remember_test.exs` +
  `tools/recall_test.exs` adapted, not deleted; `Forget` tool gets
  a new test.
- **Substring-superset regression** for `recall` — the §3.19 test
  with `"api_base_url"` / `[:preference]` / `"foo.bar.baz"` Facts.
- **Lexical-index engaged** — `EXPLAIN ANALYZE` asserts
  `Bitmap Index Scan on memory_facts_lexical_text_trgm_idx`.
- **Source-precedence** + **scope-precedence** + **combined
  precedence** dedup tests (the in-SQL window function pinned
  against drift to Elixir post-LIMIT).
- **Bitemporal predicate matrix** — current truth, world
  time-travel, system time-travel, full bitemporal cells.
- **Cross-tenant FK validation** — `:record` and `:import_legacy`
  reject mismatched scope FKs at every level, not just the leaf.
- **Cross-tenant Link rejection** + **scope denormalization for
  revisions/joins**.
- **Consolidator opt-out egress gate** — `WS_off` (`:disabled`)
  never invokes the harness; `WS_on` (`:default`) does.
- **Consolidator user-scope most-restrictive** — flips between two
  workspace policies under a shared user.
- **Consolidator concurrency** — two `run_now/1` calls race;
  exactly one publishes `:succeeded`, the other observes
  `:scope_busy`.
- **Consolidator crash recovery** — kill mid-staging; new run
  acquires the lock cleanly (auto-released on connection close).
- **Embedding backfill recovery** — `Memory.Fact` written, worker
  killed, periodic scan picks it up after restart.
- **Embedding-space isolation** — `WS_voyage` vs `WS_local`,
  cosine never crosses vector spaces, falls through to FTS/lexical
  for cross-policy candidates.
- **Memory.Fact policy transition** — flip policies, observe
  `:disabled → :pending → :ready`, then back with
  `purge_existing: true` NULLing embeddings.
- **Frozen-snapshot prompt cache** — Anthropic telemetry shows
  `cache_hits > 0` across a 3-turn session.
- **Migration round-trip** — `mix jidoclaw.migrate.memory` then
  `mix jidoclaw.export.memory` against sanitized + redaction-delta
  fixtures.
- **Migration idempotency** — second run inserts zero rows
  (`unique_import_hash` partial identity does the dedup).
- **`Memory.Fact.content_hash` + `search_vector` integration test**
  — insert a Fact, assert both columns populate at the database
  level, assert the `unique_active_promoted_content_per_scope_*`
  identity rejects a duplicate-content row.

Once all gates pass, the phase ships as `v0.6.3`.

## Critical files to modify (path index)

- `lib/jido_claw/repo.ex` — add `pgcrypto` extension.
- `config/config.exs` — append `Memory.Domain` to `:ash_domains`.
- `lib/jido_claw/tool_context.ex` — **unchanged**; scope kind
  derivation lives in `Memory.Scope.resolve/1`.
- `lib/jido_claw/application.ex` — drop `JidoClaw.Memory`
  GenServer; add `Memory.Consolidator.Supervisor` (or similar);
  call `Cron.Scheduler.start_system_jobs/0`.
- `lib/jido_claw/agent/agent.ex` — register `Memory.Forget` in
  the tool list.
- `lib/jido_claw/agent/prompt.ex` — frozen-snapshot rewrite
  (`build_snapshot/2`, drop `load_memories`/`agent_count`).
- `lib/jido_claw/cli/commands.ex` — replace `/memory` block.
- `lib/jido_claw/cli/branding.ex`, `lib/jido_claw/cli/presenters.ex`
  — adapt formatters.
- `lib/jido_claw/conversations/recorder.ex` — trigger snapshot
  build on session create / first append.
- `lib/jido_claw/embeddings/backfill_worker.ex` — extend to
  `Memory.Fact` resource.
- `lib/jido_claw/forge/sandbox.ex` — per-session `sandbox_mode`
  preference.
- `lib/jido_claw/forge/manager.ex` — thread `sandbox_mode`
  through.
- `lib/jido_claw/platform/cron/scheduler.ex` — add
  `start_system_jobs/0`.
- `lib/jido_claw/platform/cron/worker.ex` — add system-job mode.
- `lib/jido_claw/platform/memory.ex` — DELETE.
- `lib/jido_claw/tools/remember.ex` — swap implementation.
- `lib/jido_claw/tools/recall.ex` — swap implementation.
- `mix.exs` — drop `:jido_memory` if unused.

## New files

- `lib/jido_claw/memory.ex` (or `lib/jido_claw/memory/api.ex`) —
  thin module API.
- `lib/jido_claw/memory/domain.ex` — Ash domain.
- `lib/jido_claw/memory/scope.ex` — scope resolution + lock keys.
- `lib/jido_claw/memory/retrieval.ex` — public retrieval API.
- `lib/jido_claw/memory/hybrid_search_sql.ex` — RRF SQL builder.
- `lib/jido_claw/memory/resources/block.ex`
- `lib/jido_claw/memory/resources/block_revision.ex`
- `lib/jido_claw/memory/resources/fact.ex`
- `lib/jido_claw/memory/resources/episode.ex`
- `lib/jido_claw/memory/resources/fact_episode.ex`
- `lib/jido_claw/memory/resources/link.ex`
- `lib/jido_claw/memory/resources/consolidation_run.ex`
- `lib/jido_claw/memory/consolidator.ex` — orchestrator.
- `lib/jido_claw/memory/consolidator/cluster.ex`
- `lib/jido_claw/memory/consolidator/prompt.ex`
- `lib/jido_claw/memory/consolidator/proposals.ex`
- `lib/jido_claw/memory/consolidator/tools.ex`
- `lib/jido_claw/memory/consolidator/mcp_server.ex`
- `lib/jido_claw/security/cross_tenant_fk.ex` — shared validator.
- `lib/jido_claw/security/redaction/memory.ex`
- `lib/jido_claw/forge/runners/codex.ex`
- `lib/jido_claw/forge/runners/fake.ex`
- `lib/jido_claw/tools/forget.ex`
- `lib/mix/tasks/jidoclaw.migrate.memory.ex`
- `lib/mix/tasks/jidoclaw.export.memory.ex`
- `priv/repo/migrations/<ts>_v063_memory.exs`
- `test/jido_claw/memory/*_test.exs` (one per resource)
- `test/jido_claw/memory/consolidator_test.exs`
- `test/jido_claw/memory/retrieval_test.exs`
- `test/jido_claw/memory/migration_test.exs`

## Pre-existing debt that Phase 3 inherits but does not fix

These are surfaced in the source plan as out-of-scope for v0.6;
recording them here so reviewers don't expect Phase 3 to address
them:

- **`Project` and `Accounts.User` lack `tenant_id`.** The
  `CrossTenantFk` helper skips validation against these parents
  with a `:tenant_validation_skipped_for_untenanted_parent`
  telemetry event. A future sprint adds the column + backfill.
- **`Forge.Resources.Session` lacks `tenant_id`.**
  `ConsolidationRun.forge_session_id` validation is skipped on
  the same telemetry path; the audit pointer still works because
  `ConsolidationRun`'s own scope FKs are tenant-validated.
- **Worker templates don't inherit prompt-cache config.** The
  seven workers under `lib/jido_claw/agent/workers/` each set
  their own `llm_opts`; `anthropic_prompt_cache: true` is on the
  main agent only. Frozen-snapshot caching only fires for the
  main agent's sessions until each worker file is updated. Plan
  §Pre-existing cleanup debt acknowledges this; not in Phase 3
  scope.
- **`Solutions.HybridSearchSql` uses weighted-sum, not RRF.**
  Memory adopts RRF per the plan §3.13 SQL pseudocode. Solutions
  stays weighted-sum; reconciling the two is a follow-up sprint.
- **`Workspaces.Resolver.ensure_workspace/3`** is the actual
  function name (not `ensure/1` as the source plan refers to in a
  few places). Migrate task uses the real name.
- **Mix task namespace** is `mix jidoclaw.*` (single word), not
  `mix jido_claw.*`. Migration and export tasks follow the
  existing convention.
