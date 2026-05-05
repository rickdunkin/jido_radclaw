# Phase 3b — Memory: Consolidator Runtime & Frozen-Snapshot Prompt

**Goal:** ship the scheduled consolidator (a per-scope worker that
invokes a frontier-model coding harness as a Forge session,
collects memory mutations through a scoped MCP tool surface, and
publishes them transactionally) plus the frozen-snapshot system
prompt that lets `anthropic_prompt_cache: true` fire across turns.
After 3b, the Block tier is filled automatically every cadence
tick, the Anthropic prompt cache amortises across multi-turn
sessions, and `/memory consolidate` / `/memory status` are wired.

## 3b.0 Scope and dependencies

### What 3b ships

- §3.14 — frozen-snapshot system prompt rewrite of
  `JidoClaw.Agent.Prompt.build/1` into `build_snapshot/2`, with
  the snapshot stored in `Conversations.Session.metadata`.
- §3.15 — full consolidator design: per-scope advisory lock,
  watermark resolution, clustering, harness session via
  `JidoClaw.Forge.Runners.ClaudeCode` + the new
  `JidoClaw.Forge.Runners.Fake` (test substrate), scoped
  in-process HTTP MCP server hosting the eleven proposal tools
  (`list_clusters`, `get_cluster`, `get_active_blocks`,
  `find_similar_facts`, `propose_add`, `propose_update`,
  `propose_delete`, `propose_block_update`, `propose_link`,
  `defer_cluster`, `commit_proposals`), staging buffer +
  transactional publish, contiguous-prefix watermark advance,
  failure handling.
- `JidoClaw.Cron.Scheduler.start_system_jobs/0` (new entry point)
  + a new `system_job` mode on `JidoClaw.Cron.Worker` that
  dispatches to a `{module, function, args}` rather than going
  through `JidoClaw.chat/4`. The consolidator registers as a
  system-level cron job at boot (distinct from
  `.jido/cron.yaml` user jobs).
- Per-session `sandbox_mode` knob threaded through
  `Forge.Manager.start_session/2` so consolidator runs select
  `:local` (skipping Docker) without changing the global
  app-env default for ad-hoc Forge sessions.
- `/memory consolidate` and `/memory status` CLI commands.
- The consolidator + snapshot subset of §3.19 acceptance gates.

### Out of scope (deferred to 3c)

- `JidoClaw.Forge.Runners.Codex` sibling runner. The consolidator
  in 3b runs against `:claude_code` only (plus `:fake` for tests);
  the `harness:` config knob accepts `:codex` but a 3b deployment
  with `harness: :codex` returns `:no_runner_configured` until 3c
  ships.

### Dependencies

- **Phase 3a:** all seven Memory resources (`Block`,
  `BlockRevision`, `Fact`, `Episode`, `FactEpisode`, `Link`,
  `ConsolidationRun`), `Memory.Scope.resolve/1`,
  `Memory.Retrieval.search/2`, the write-path wrappers, the
  shared `JidoClaw.Security.CrossTenantFk` helper. The
  consolidator's transactional publish (§3.15 step 7) writes to
  resources defined in 3a.
- **Phase 0:** `Workspaces.Workspace.consolidation_policy`
  (default `:disabled`, ordering `:disabled < :local_only <
  :default`) — drives the §3.15 step `-1` egress gate.
- **Phase 2:** `Conversations.Session.metadata` jsonb column —
  the snapshot sidecar storage. `Recorder` (the GenServer
  subscribing to `ai.*` topics) — used to trigger snapshot build
  on first message.
- **Pre-existing:** `JidoClaw.Forge.Runners.ClaudeCode` shipped
  v0.6 baseline; 3b extends it with `--mcp-config` injection
  and intermediate stream-json tool-call event surfacing.

### Implementation discoveries (additions to source plan)

- **Forge runner today injects no MCP server.**
  `lib/jido_claw/forge/runners/claude_code.ex` invokes
  `claude -p <prompt> --model <m> --dangerously-skip-permissions
  --output-format stream-json --max-turns 200` and
  `parse_output/1` discards every non-final stream-json event
  (only `{type: "result"}` is parsed). The consolidator harness
  needs (a) a `--mcp-config <path>` flag pointing at a per-run
  config file, and (b) intermediate `tool_use` / `tool_result`
  events surfaced as proposals rather than discarded. Both are
  new code in 3b's `ClaudeCode` runner extension.
- **Sandbox mode is global today, not per-session.**
  `lib/jido_claw/forge/sandbox.ex:45` reads the impl from
  `Application.get_env(:jido_claw, :forge_sandbox, ...)`. 3b
  threads a `sandbox_mode` field through
  `Forge.Resources.Session.spec` (jsonb) so the consolidator
  selects `:local` per run while existing Forge users keep their
  global default.
- **`Cron.Scheduler.start_system_jobs/0` doesn't exist** today.
  3b adds it as a sibling of `load_persistent_jobs/2`; called
  from `JidoClaw.Application` boot path.
- **`Cron.Worker` only routes through `JidoClaw.chat/4`** at
  `lib/jido_claw/platform/cron/worker.ex:116`. The consolidator
  runs its own Forge session directly and doesn't go through
  the chat API, so 3b adds a `:system_job` mode that dispatches
  to a `{module, function, args}` tuple.
- **Scoped MCP server transport: in-process HTTP via Bandit.**
  The source plan §3.15 step 4 says "purpose-built MCP server
  that the Forge runner spawns *only* for this session" but
  doesn't pin the transport. The decision: spawn a Bandit
  endpoint per consolidator run on a free port (`port: 0`),
  hosted via Anubis's HTTP/SSE handler shape that mirrors
  `lib/jido_claw/core/mcp_server.ex`. Write a temp JSON file
  containing
  `{"mcpServers":{"consolidator":{"type":"http",
  "url":"http://127.0.0.1:<port>"}}}` and inject it into the
  harness CLI as `--mcp-config <path>`. Anubis's existing
  `Anubis.Server.Handlers.Tools` shim
  (`lib/jido_claw/core/anubis_tools_handler_patch.ex`) applies
  automatically — the per-session server runs on the same
  Anubis substrate as the global `mix jidoclaw --mcp` server.
- **`Forge.Resources.Session` lacks `tenant_id`.**
  `ConsolidationRun.forge_session_id` validation is skipped via
  the §3.9 documented `:tenant_validation_skipped_for_untenanted_parent`
  telemetry path; the audit pointer still works because the
  `ConsolidationRun` row's own scope FKs are tenant-validated.
  Tracked outside Phase 3 per the plan summary.
- **`Conversations.Session.metadata` is already jsonb-shaped** and
  writable from `:upsert`-style actions (see Phase 2 resource
  definition). 3b is the first consumer to write structured
  snapshot data into it.
- **`anthropic_prompt_cache: true` is set on `JidoClaw.Agent`**
  but worker templates under `lib/jido_claw/agent/workers/` do
  **not** inherit it. Frozen-snapshot caching only fires for
  the main agent's sessions in 3b — a one-line follow-up sweep
  copies the option into each worker. Tracked outside Phase 3
  per the plan summary's "Pre-existing cleanup debt" entry.

---

## 3.14 Frozen-snapshot system prompt

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

## 3.15 Consolidator design

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


## 3.19 Acceptance gates (consolidator + snapshot subset)

This is the subset of source-plan §3.19 that Phase 3b must clear.
Gates covering the resource layer, hybrid retrieval, embedding
backfill, migration, and decommissioning ship in 3a; the Codex
runner round-trip ships in 3c.

- A scheduled consolidation run produces measurable Block content on
  a real session.
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

- A consolidator concurrency test: kick off two `run_now/1` calls
  for the same scope from two processes; assert exactly one
  publishes a `:succeeded` `ConsolidationRun` row and the other
  observes `{:error, :scope_busy}`. Proves the §3.15 step 0
  session-level advisory lock + connection-checkout design works
  through `Repo.checkout/2`.
- A consolidator crash-recovery test: kill the worker process
  mid-staging (after step 2, before step 7); start a new run for
  the same scope; assert it acquires the lock cleanly (the prior
  connection's session-level lock auto-released on close) and
  publishes correctly.

- New `/memory consolidate` and `/memory status` CLI commands
  functional. The companion `/memory blocks` gate ships in 3a.
- **Scoped MCP server lifecycle test.** A consolidator run
  starts the per-session Bandit endpoint, writes the temp
  `--mcp-config` JSON, the harness invokes the eleven scoped
  tools, the run terminates either via `commit_proposals` or
  timeout, and asserts (a) the Bandit endpoint is shut down,
  (b) the temp config file is unlinked, (c) the port is no
  longer bound. Pins the lifetime contract from the §3.15 step
  4 `try/after` block.
- **`Cron.Scheduler.start_system_jobs/0` registers the
  consolidator at boot.** Start the application; assert
  `Cron.Scheduler.list_jobs/1` includes a system job tagged
  `:memory_consolidator` with the configured cadence.
- **Frozen-snapshot byte-stability test.** Build a session
  snapshot; perform three turns of tool use that don't write
  any Block; assert the snapshot string returned to the LLM is
  byte-identical across turns. Then perform a Block write
  mid-session and assert the snapshot is **still** byte-identical
  (mid-session Block writes don't invalidate the snapshot per
  §3.14 step 3) — the model only sees the new Block content via
  the next session's snapshot.
