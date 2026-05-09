# Resolve v0.6 Phases 0–3c Code-Review Findings

## Context

A code review of the v0.6 Phase 0–3c work surfaced five issues. Independent
exploration verified all five are accurate. This plan resolves each, in
priority order.

| ID | Sev | Topic | Status |
|---|---|---|---|
| 1 | P1 | Recorder telemetry capture is empty on real turns | accurate — needs `ai.usage` subscription + multi-shape `extract_telemetry` |
| 2 | P2 | Workspace attribute still allows `:local_only` | accurate — constraint mismatch with action arg |
| 3 | P2 | `shadowed_by` not derived from real dropped candidates | accurate — current Elixir-side broad read mis-classifies |
| 4 | P3 | `/memory blocks edit` exits on char_limit miss | accurate — plan §8.1 calls for re-edit |
| 5 | P3 | Missing acceptance-gate tests | accurate — 3 test files / one suite addition still missing |

The intended outcome: telemetry columns populate on normal turns, the
attribute layer enforces the `local_only` removal, retrieval shadows are
real losers from the candidate set, the block editor re-prompts on
limit-exceeded, and the missing acceptance gates exist.

---

## Fix 1 — Recorder telemetry capture (P1)

### Problem

- `recorder.ex:64` `@topics` does not include `"ai.usage"` and
  `agent_server_plugin/recorder.ex:39-45` does not bridge it onto
  `JidoClaw.SignalBus`. The signal never reaches the Recorder.
- `recorder.ex:385-403` `extract_telemetry/1` reads only flat
  `input_tokens` / `output_tokens` / `latency_ms`. The directive's
  `Signal.LLMResponse` carries no usage at all (it's emitted via
  `Signal.LLMResponse.new!` with only `call_id` / `result` /
  `metadata`); tokens land separately on `Signal.Usage` (`ai.usage`
  schema: `input_tokens`, `output_tokens`, `model`, `total_tokens`).
- The directive's `ai.usage` metadata does **not** include
  `request_id` (`deps/jido_ai/lib/jido_ai/directive/llm_generate.ex:259-263`),
  while React's does (`react/strategy.ex:1768-1779`). And in the
  directive flow, `ai.usage` is cast **before** `ai.llm.response`,
  so a learn-from-LLMResponse strategy can't help in time.
- `duration_ms` is **not** set on any current signal (neither
  `ai.usage` nor `ai.llm.response` carry it from the directive
  path). It IS published as a standard telemetry event at
  `[:jido, :ai, :llm, :complete]` with `metadata.request_id`
  (`deps/jido_ai/lib/jido_ai/observe.ex:113-119`,
  `llm_generate.ex:155`). That's the supported capture surface
  without patching jido_ai.

### Approach

1. **Tokens / model / run_id**: subscribe the Recorder to `ai.usage`.
   Teach `extract_telemetry/1` the multiple upstream shapes (atom
   and string keys at every level — `Signal.Usage` data is a
   struct-derived map; tests can pass plain maps with either key
   form). Correlate `call_id → request_id` inside the Recorder
   when `ai.usage` arrives without `request_id`, by **buffering**
   the payload until the matching `ai.llm.response` arrives.
2. **latency_ms**: attach a `:telemetry.attach_many/4` handler for
   both `[:jido, :ai, :llm, :complete]` and
   `[:jido, :ai, :llm, :error]` in the Recorder's `do_setup/1`.
   The handler reads `metadata.request_id` and
   `measurements.duration_ms` and calls
   `RequestCorrelation.record_telemetry/2`. No jido_ai patch
   required — the events fire by default
   (`obs_cfg.emit_telemetry?` defaults to `true` —
   `observe.ex:210-212`).

### Changes

**`lib/jido_claw/agent_server_plugin/recorder.ex`** (signal_patterns
list at line 39-45):
- Add `"ai.usage"`. Update the `@moduledoc` topic list.

**`lib/jido_claw/conversations/recorder.ex`**:
- Add `"ai.usage"` to `@topics` (line 64).
- Extend `defstruct` (line 75-79) with two bounded buffers:
  - `pending_usage: %{}` — `call_id => telemetry_map`. Buffer of
    `ai.usage` payloads received before the matching
    `ai.llm.response` resolved their `request_id`. Bounded
    LRU; size cap **256**. Drained on the matching
    `ai.llm.response`, evicted on size cap, and explicitly cleared
    on terminal signal for the resolved request_id.
  - `call_to_request: %{}` — `call_id => request_id` map learned
    from `ai.llm.response`. Same LRU shape, same cap.
  Both buffers track insertion order via parallel queues to keep
  eviction deterministic; reuse the same shape as the existing
  `recent_completed` LRU at `recorder.ex:78-79`.
- New `handle_signal(%{type: "ai.usage"})` clause: extract
  telemetry, then resolve a `request_id` in this priority order
  and dispatch as soon as we have one:
  1. `metadata.request_id` on the signal itself (React path) —
     dispatch immediately.
  2. `state.call_to_request[call_id]` if a prior
     `ai.llm.response` for this call_id already populated the
     map (out-of-order or strategy-specific orderings) —
     dispatch immediately.
  3. Otherwise (directive path: ai.usage cast before
     ai.llm.response) — buffer by `call_id` in
     `pending_usage`. The matching `ai.llm.response` will
     drain it.
- Modify `handle_signal(%{type: "ai.llm.response"})`: after the
  existing `record_reasoning` and `record_telemetry`, learn the
  `call_id → request_id` mapping and drain any buffered
  `pending_usage[call_id]` against the now-known `request_id`.
- In `do_setup/1` (line 162-173), after subscribing to bus topics,
  attach a single telemetry handler via
  `:telemetry.attach_many/4` for both `:complete` and `:error`
  events. **Handler-id is a stable singleton:**
  `{JidoClaw.Conversations.Recorder, :latency}`. The Recorder is
  already a singleton (registered as `name: __MODULE__`), so the
  handler-id never collides across boots. Detach the same id
  defensively before attaching so a prior dirty exit (no
  `terminate/2`) can't leave a stale handler bound to a dead
  function reference. The handler is a small function that pulls
  `metadata.request_id` and `measurements.duration_ms` and calls
  `RequestCorrelation.record_telemetry/2` wrapped in `try/rescue`
  (a transient DB failure must not crash the emitting process).
  Add a `terminate/2` callback that calls
  `:telemetry.detach/1` on the same singleton id; document that
  terminate is best-effort and the defensive-detach in
  `do_setup/1` is the actual contract.
- `extract_telemetry/1` reads from these positions in order
  (first non-nil wins per field). At every map step, accept both
  atom and string keys via a `nested_field/2` helper that walks
  a key path and tries atom-first then string fallback:
  - `data.metadata.request_id` / `data.request_id` — for the merge
    target lookup.
  - `data.metadata.run_id` / `data.run_id`.
  - `data.metadata.model` / `data.model`.
  - **NEW** `data.input_tokens` / `data.output_tokens` (flat —
    `Signal.Usage` shape).
  - **NEW** `data.usage.input_tokens` / `data.usage.output_tokens`
    (nested — populated if a future patch adds it to LLMResponse).
  - **NEW** `data.result` extraction: when `data.result` is
    `{:ok, %{usage: %{...}}, _effects}` or
    `{:ok, %{usage: %{...}}}`, pull tokens from there (React's
    LLMResponse path).
  - Existing flat `data.latency_ms` retained for backwards
    compatibility with tests; `data.duration_ms` mapped to
    `:latency_ms` for forward compat.
- `finalize_request/2` (line 338-349): clear any
  `pending_usage` entries whose `call_id` resolved to this
  `request_id` via `call_to_request`; also clear the
  `call_to_request` entries themselves. Avoids unbounded growth
  on orphaned LLM calls.

### Tests

`test/jido_claw/conversations/recorder_test.exs` — add the three
plan §8.3 telemetry-race scenarios (encapsulated-goblet.md:1162-1180)
plus latency capture. Tests use the supervisor-managed singleton
Recorder; **do not** detach the singleton's
`{JidoClaw.Conversations.Recorder, :latency}` handler in
`on_exit` — that would silently kill telemetry capture for any
later test in the suite. The handler attaches once at boot and
stays attached for the supervisor's lifetime; the Recorder's
`do_setup/1` defensive-detach handles re-attach on supervisor
restart. Existing setup pattern (`Sandbox.start_owner!` +
`stop_owner` `on_exit`) is unchanged.

If a test wants to verify the latency-handler path in isolation,
it attaches a *separate* handler under a test-only id like
`{__MODULE__, :test_observer, ref}` and detaches *that* exact id
on `on_exit` — never touching the production singleton id.

1. **Full-turn happy path**: emit
   `ai.tool.started` → `ai.tool.result` → `ai.usage` (with
   tokens+model, no request_id in metadata) → `ai.llm.response`
   (with `metadata.request_id`+`run_id`) → also
   `:telemetry.execute([:jido, :ai, :llm, :complete],
   %{duration_ms: 123}, %{request_id: r1})` → `ai.request.completed`.
   Then call `Session.Worker.add_message(:assistant, ...)`. Assert
   the resulting `Message` row carries `model`, `input_tokens`,
   `output_tokens`, `run_id`, `latency_ms: 123`.

2. **Telemetry-record-before-finalize ordering**: emit `ai.usage`
   carrying request_id-bearing metadata (React-style) and
   `ai.request.completed`; assert the durable
   `RequestCorrelation` row has the telemetry fields populated
   *before* the cache is cleared.

3. **Cache-with-stale-data fallback**: pre-populate
   `RequestCorrelation.Cache` with a scope-only entry (no
   telemetry); insert a durable `RequestCorrelation` row carrying
   telemetry; call `Session.Worker.add_message`; assert the row
   carries the durable telemetry, not the cache's empty values.

4. **call_id → request_id buffer**: emit `ai.usage` (no request_id,
   call_id `c1`), then emit `ai.llm.response` (call_id `c1`,
   request_id `r1`); assert the durable RequestCorrelation row
   for `r1` now has the buffered tokens.

5. **Telemetry latency capture (no signal path)**: register a
   correlation row, fire only the telemetry event
   `[:jido, :ai, :llm, :complete]` with `duration_ms: 250` and
   `metadata.request_id`; assert the durable row's `latency_ms`
   is 250 — proves the telemetry handler path works in isolation.

---

## Fix 2 — Workspace policy attribute constraint (P2)

### Problem

`lib/jido_claw/workspaces/resources/workspace.ex:156-168`:

```elixir
attribute :embedding_policy, :atom do
  ...
  constraints(one_of: [:default, :local_only, :disabled])  # still allows :local_only
end
attribute :consolidation_policy, :atom do
  ...
  constraints(one_of: [:default, :local_only, :disabled])  # same
end
```

Action arguments at `workspace.ex:85-105` correctly restrict to
`[:default, :disabled]`, but the `:register` action (line 60-72)
accepts `embedding_policy` / `consolidation_policy` straight to the
attribute, so a caller can still write `:local_only` via
`Workspace.register/1`. The migration at
`priv/repo/migrations/20260507120000_v062_strip_local_embeddings.exs:8-9`
explicitly states `local_only` is removed.

### Changes

`lib/jido_claw/workspaces/resources/workspace.ex`:

```elixir
attribute :embedding_policy, :atom do
  allow_nil?(false)
  public?(true)
  default(:disabled)
  constraints(one_of: [:default, :disabled])  # removed :local_only
end

attribute :consolidation_policy, :atom do
  allow_nil?(false)
  public?(true)
  default(:disabled)
  constraints(one_of: [:default, :disabled])  # removed :local_only
end
```

Also update the moduledoc at `workspace.ex:12-18` if it still mentions
the legacy three-value enum (per the docstring already saying
`:default | :disabled`, no edit needed).

### Tests

`test/jido_claw/workspaces/workspace_test.exs` — add a single test
under `describe "register/1"`:

```elixir
test ":local_only is rejected at the attribute layer for both policies" do
  assert {:error, _} =
           Workspace.register(%{
             tenant_id: "default",
             path: "/tmp/local-only-#{System.unique_integer([:positive])}",
             name: "demo",
             embedding_policy: :local_only
           })

  assert {:error, _} =
           Workspace.register(%{
             tenant_id: "default",
             path: "/tmp/local-only-c-#{System.unique_integer([:positive])}",
             name: "demo",
             consolidation_policy: :local_only
           })
end
```

---

## Fix 3 — `shadowed_by` from SQL-derived candidates (P2)

### Problem

`lib/jido_claw/memory/retrieval.ex:156-171` `collect_shadows/4` reads
all rows by `(tenant_id, label, scope_chain)` with no query-match
predicate, no bitemporal predicate, and no source-precedence
constraint. This surfaces invalid/expired rows, query-mismatched
rows, and rows that were never candidates at all as "shadows".

The plan
(`docs/plans/v0.6/phase-3a-memory-data.md:1140-1143, 1174-1178`) says
shadows are projected **from `merged`** — the in-SQL candidate set
that already passed FTS/ANN/lexical matching, bitemporal, and
tenant filtering. The §3.13 regression test
(`phase-3a-memory-data.md:1388-1401`) seeds three same-label
same-scope rows with different sources and asserts only
`:user_save` returns, with the other two ids in
`metadata.shadowed_by`.

The current SQL applies **per-pool precedence dedup**
(`hybrid_search_sql.ex:343-352`) before pool ranking. The losers it
filters never reach the cross-pool `deduped` CTE, so projection from
`deduped` alone yields empty `shadowed_by`.

### Approach

Don't re-derive matches with broad predicates — that mis-classifies
candidates (e.g. `embedding IS NOT NULL AND embedding_status =
'ready'` would mark every ready-embedded row in scope as a candidate
even when it never made the ANN top-K).

Instead, add three new "_matches" CTEs **in parallel with** the
existing pool CTEs (don't refactor the existing pools to read from
them — preserves ranking semantics exactly). The new CTEs expose
the match set unconstrained by per-pool dedup, used only by a new
`candidates` CTE for shadow projection. The existing
`fts_pool` / `ann_pool` / `lex_pool` keep their inline predicates
and per-pool dedup verbatim. Some predicate duplication is the
acceptable price for not changing precedence semantics.

The shadow-projection ordering and the `deduped` ordering and the
`scope_precedence_partition()` per-pool ordering must all be
identical, including a deterministic tie-break (`id DESC`), so
every winner-selection path agrees on tie-breaks.

### Changes

**`lib/jido_claw/memory/hybrid_search_sql.ex`**:

- Add three new CTEs **in parallel with** the existing pool CTEs.
  Don't change the existing pool CTEs — these new ones are
  independent and exist only to feed the `candidates` CTE.

  ```sql
  fts_matches AS (
    SELECT id
      FROM memory_facts
     WHERE tenant_id = $1
       AND #{scope_clause}
       AND #{bt_predicate}
       AND search_vector @@ websearch_to_tsquery('english', #{off.query})
  ),
  ann_matches AS (
    -- For shadow projection only. ANN has no semantic
    -- threshold, so "all rows that match" is really "every
    -- ready-embedded row in scope" — unbounded on large tenants
    -- and not how the existing ann_pool actually thinks about
    -- candidates. We use a pragmatic top-K = N*8 as a bounded
    -- diagnostic candidate set: wider than ann_pool's N*4 so
    -- we surface lower-precedence siblings that ann_pool drops
    -- via per-pool dedup, but capped to keep the query
    -- predictable. This is honestly an approximation of "all
    -- candidates", not a mirror of ann_pool's actual scan.
    --
    -- The existing ann_pool is unchanged and continues to apply
    -- per-pool precedence dedup BEFORE its top-K LIMIT, which
    -- guarantees a higher-precedence farther sibling beats a
    -- lower-precedence closer sibling for ranking. ann_matches
    -- only feeds shadow projection, never ranking.
    SELECT id
      FROM memory_facts
     WHERE tenant_id = $1
       AND #{scope_clause}
       AND #{bt_predicate}
       AND #{off.embedding}::vector IS NOT NULL
       AND embedding IS NOT NULL
       AND embedding_status = 'ready'
     ORDER BY (embedding <=> #{off.embedding}::vector) ASC
     LIMIT #{off.limit} * 8
  ),
  lex_matches AS (
    SELECT id
      FROM memory_facts
     WHERE tenant_id = $1
       AND #{scope_clause}
       AND #{bt_predicate}
       AND (
         lexical_text % #{off.raw_lower}
         OR lexical_text LIKE '%' || #{off.like_pattern} || '%' ESCAPE '\\'
       )
  )
  ```

  When the query is empty, `fts_matches` and `lex_matches` short to
  `WHERE FALSE` (mirroring the existing empty-pool stubs at lines
  354-361, 470-476). When no embedding is supplied, `ann_matches`
  shorts the same way (mirroring 408-419).

- The existing `fts_pool_sql`, `ann_pool_sql`,
  `lexical_pool_sql` stay as-is. No refactor to read from
  `_matches` CTEs — this preserves ranking semantics, including
  the per-pool dedup + LIMIT ordering that prevents
  closer-distance lower-precedence inversions.

- Add `id DESC` as a tie-break to **all three** precedence
  orderings: `scope_precedence_partition/0` (line 343-352),
  the new `candidates` CTE, and the modified `deduped` CTE.
  All three use the identical ORDER BY:
  `scope_rank ASC, source_rank ASC, valid_at DESC, id DESC`.

- Add a `candidates` CTE downstream of the matches CTEs:

  ```sql
  candidates AS (
    SELECT mf.id,
           mf.label,
           mf.scope_kind,
           mf.source,
           COALESCE(mf.label, mf.id::text) AS partition_key,
           ROW_NUMBER() OVER (
             PARTITION BY COALESCE(mf.label, mf.id::text)
             ORDER BY #{scope_rank_case()} ASC,
                      #{source_rank_case()} ASC,
                      mf.valid_at DESC,
                      mf.id DESC
           ) AS prec_rank
      FROM memory_facts mf
     WHERE mf.id IN (
       SELECT id FROM fts_matches
       UNION
       SELECT id FROM ann_matches
       UNION
       SELECT id FROM lex_matches
     )
  )
  ```

  The `ORDER BY` is identical to the new `deduped` ordering (see
  next bullet). `id DESC` tie-break makes the winner pick
  deterministic and identical between the two CTEs.

- Modify `deduped` to add the matching `id DESC` tie-break and
  carry the partition_key:

  ```sql
  deduped AS (
    SELECT mf.*, r.combined_score,
           COALESCE(mf.label, mf.id::text) AS partition_key,
           ROW_NUMBER() OVER (
             PARTITION BY COALESCE(mf.label, mf.id::text)
             ORDER BY #{scope_rank_case()} ASC,
                      #{source_rank_case()} ASC,
                      mf.valid_at DESC,
                      mf.id DESC
           ) AS row_num
      FROM ranked r
      JOIN memory_facts mf ON mf.id = r.id
  )
  ```

- Final SELECT projects shadows by joining `candidates` to the
  winning row's partition AND excluding the winner's own id.
  Preserve the existing `inserted_at DESC` tie-break in the
  outer ORDER BY; just append `id DESC` after it for full
  determinism:

  ```sql
  SELECT d.*,
         (
           SELECT COALESCE(
             jsonb_agg(
               jsonb_build_object(
                 'id', c.id::text,
                 'scope_kind', c.scope_kind::text,
                 'source', c.source::text
               )
               ORDER BY c.prec_rank
             ),
             '[]'::jsonb
           )
           FROM candidates c
           WHERE c.partition_key = d.partition_key
             AND c.id <> d.id
         ) AS shadowed_by
    FROM deduped d
   WHERE d.row_num = 1
   ORDER BY combined_score DESC, valid_at DESC, inserted_at DESC, id DESC
   LIMIT #{off.limit}
  ```

  Excluding by `c.id <> d.id` (not `prec_rank > 1`) hardens against
  any future ordering drift between the two CTEs — even if rankings
  diverge, the winner is never in its own shadow list.

- `final_select_sql(:none, ...)` stays unchanged: `dedup: :none`
  callers explicitly opted out of dedup, so no shadow projection.
  The output rows have **no** `shadowed_by` column for this branch.

- `load_facts/2` (line 598-631):
  1. Detect whether `shadowed_by` is present in the result columns
     (will be present for `:by_precedence`, absent for `:none`).
  2. When present, build a `id => shadow_list` map BEFORE the Ash
     reload (the Ash reload returns a `Fact` struct with no extra
     columns, so the SQL-level shadow JSON would be discarded).
  3. After Ash reload hydrates the `Fact` structs, walk the
     wrapper-list and reattach metadata via
     `Ash.Resource.put_metadata(fact, :shadowed_by, list)` keyed
     on the fact id from the saved map.
  4. JSONB arrives as a list of maps with string keys — atomize
     the three known keys (`"id"` / `"scope_kind"` / `"source"`)
     and convert the `scope_kind` / `source` string values to
     atoms via `String.to_existing_atom/1` (safe — both columns
     are Ash atom enums with known members).

**`lib/jido_claw/memory/retrieval.ex`**:

- Delete `maybe_project_shadowed_by/4`, `collect_shadows/4`, and
  `build_chain_filter/1` (lines 132-185). Shadow projection moves
  to `HybridSearchSql.load_facts/2`.
- `do_search/3` (line 94) maps to `& &1.fact` directly. The
  `shadowed_by` metadata is already on each Fact via the SQL pass.

### Tests

`test/jido_claw/memory/retrieval_test.exs` — add the regression
tests called out in the plan (encapsulated-goblet.md:1228-1232,
phase-3a-memory-data.md:1388-1401):

1. **Source-precedence dedup** — seed three same-label same-scope
   rows with sources `:user_save`, `:consolidator_promoted`,
   `:model_remember`; query for the label; assert exactly one row
   returns (the `:user_save`); assert
   `Ash.Resource.get_metadata(fact, :shadowed_by)` lists the
   other two ids with their `scope_kind` / `source`. Repeat with
   `dedup: :none` and assert all three rows return without
   `shadowed_by` metadata.

2. **Bitemporal exclusion** — seed two same-label same-scope rows;
   mark the second as `expired_at: past`; assert the first wins
   and `shadowed_by` is empty (the expired row was filtered by
   `bt_predicate` in the `_matches` CTEs). Re-run with
   `bitemporal: {:system_at, past_t}` so the expired row is
   bitemporally visible; assert the right row is shadowed.

3. **Query-mismatch exclusion** — seed two same-label same-scope
   rows whose contents differ; query for the first row's content
   only; assert only that row returns with empty `shadowed_by`
   (the other row didn't match any pool predicate, so it's not in
   `candidates`).

4. **ANN precedence regression (Recommended by reviewer)** — seed
   two same-label rows: one `:user_save` whose content is
   semantically far from the query, one `:model_remember` whose
   content is semantically close. Both have ready embeddings.
   Issue `Retrieval.search(query)` with embedding enabled; assert
   the `:user_save` row wins (precedence beats distance) and the
   `:model_remember` row appears in its `shadowed_by`. This pins
   the per-pool dedup ordering — any refactor that swaps to
   "rank-by-distance-then-dedup" would fail the precedence
   assertion.

The existing `recency_scan` path (`run_recency`) does not surface
shadows and stays unchanged — empty-query recency is documented as
not having a shadow projection.

---

## Fix 4 — `/memory blocks edit` re-edit on char_limit (P3)

### Problem

`lib/jido_claw/cli/commands.ex:1424-1443` prints the limit error and
returns. Plan
(`encapsulated-goblet.md:633-654`) calls for "and allow re-edit".

### Changes

Two related fixes in `lib/jido_claw/cli/commands.ex`:

**(a) Re-edit loop on char_limit miss.** Refactor
`edit_and_save_block/2` to recurse on limit overflow with the
over-limit content preloaded so the user can trim without
re-typing:

```elixir
defp edit_and_save_block(scope, block) do
  do_edit_block(scope, block, block.value)
end

defp do_edit_block(scope, block, initial) do
  case open_in_editor(initial, label_to_filename(block.label)) do
    {:ok, new_value} ->
      cond do
        new_value == block.value ->
          IO.puts("  \e[2m   No changes detected.\e[0m")

        byte_size(new_value) > block.char_limit ->
          IO.puts(
            "  \e[31m✗\e[0m  Block exceeds char_limit (#{byte_size(new_value)} > #{block.char_limit}). Re-opening editor..."
          )

          do_edit_block(scope, block, new_value)

        true ->
          apply_block_edit(scope, block, new_value)
      end

    {:error, reason} ->
      IO.puts("  \e[31m✗\e[0m  Editor failed: #{inspect(reason)}")
  end
end
```

`open_in_editor/2` already creates a fresh tempfile from the
supplied initial content (`commands.ex:1493-1514`), so the recursion
naturally preloads the over-limit version.

**(b) `$EDITOR` with arguments.** The current
`open_in_editor/2` does `System.cmd(editor, [tmp_path])` on
line 1501, which breaks values like `EDITOR="code --wait"` or
`EDITOR="emacsclient -nw"` — the whole string becomes a literal
program name and `System.cmd` fails. Fix:

```elixir
defp open_in_editor(initial_content, suffix) do
  raw = System.get_env("EDITOR") || "vi"
  [editor | extra_args] = String.split(raw, ~r/\s+/, trim: true)
  ...
  case System.cmd(editor, extra_args ++ [tmp_path], into: IO.stream(:stdio, :line)) do
    ...
  end
end
```

Splitting on whitespace covers the common `command --flag` shape
without bringing in shell-quoting complexity. Anything more exotic
(`EDITOR='vim -c "set foo"'`) was never supported and stays
unsupported.

### Tests

Both fixes are P3 interactive behavior. **Defer test coverage**:

- **Re-edit loop**: requires mocking `System.cmd` or extracting
  the loop logic — out of proportion for a 5-line recursion.
- **`$EDITOR` parse**: a public wrapper just for testing a
  trivial `String.split` is over-engineering. If we change our
  mind later, extract a tiny helper module rather than expose
  the parser through the CLI surface.

Manual QA covers both: operator `/memory blocks edit <label>`,
type beyond limit, save, observe re-prompt; set
`EDITOR="code --wait"` and exercise the full path.

---

## Fix 5 — Missing acceptance gates (P3)

### Files to create

#### 5a. `test/jido_claw/mcp_scope/initializer_test.exs`

Per plan `encapsulated-goblet.md:1258-1264`. Boots the
`MCPScope.Initializer` GenServer; asserts a `Conversations.Session`
row with `kind: :mcp` exists with the per-process `external_id`;
asserts `Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)`
contains `:session_uuid` and `:session_id` populated from that row.

`Initializer.init/1` returns `:ignore` after stashing the env, so
the test calls `MCPScope.Initializer.ensure_default_scope()` directly
(public function at `initializer.ex:46`) under the SQL Sandbox to
exercise the same code path without supervisor lifecycle gymnastics.

```elixir
defmodule JidoClaw.MCPScope.InitializerTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.Session
  alias JidoClaw.MCPScope.Initializer

  setup do
    # Reset env BEFORE the test runs — a previous test (or a stale
    # boot from `mix jidoclaw --mcp` in dev) can leave a value
    # that masks a regression.
    Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  test "ensure_default_scope/0 creates a kind: :mcp Session and stashes scope" do
    :ok = Initializer.ensure_default_scope()

    scope = Application.fetch_env!(:jido_claw, :jido_claw_mcp_default_scope)
    assert is_binary(scope.session_uuid)
    assert is_binary(scope.session_id)
    assert is_binary(scope.workspace_uuid)
    assert scope.tenant_id == "default"

    {:ok, session} = Session.by_id(scope.session_uuid)
    assert session.kind == :mcp
    assert session.external_id == scope.session_id
  end
end
```

#### 5b. `test/mix/tasks/jidoclaw_memory_export_test.exs`,
#### `test/mix/tasks/jidoclaw_solutions_export_test.exs`,
#### `test/mix/tasks/jidoclaw_conversations_export_test.exs`

Per plan `encapsulated-goblet.md:1119-1128`. Test contract per file:

**Inputs from `test/fixtures/exports/<resource>/`** — fixture
files committed to the repo. Each resource has two fixture
inputs: a "sanitized" set with no secrets, and a "with-secrets"
set carrying values that the §1.4 redaction patterns scrub.
For Memory: `.jido/memory.json` v0.5.x dict. For Solutions:
JSON list matching the migrate task's read shape. For
Conversations: `.jido/sessions/<tenant>/<id>.jsonl`.

**Outputs to `System.tmp_dir!()`** — never to `test/fixtures/`.
Each test creates a unique project_dir under `System.tmp_dir!()`
via `Path.join([System.tmp_dir!(), "export-test-#{unique}"])`,
copies the fixture inputs into it, runs migrate + export against
that dir, and writes output JSON to a sibling tempfile. Cleanup
in `on_exit`.

**Test attributes**: `use ExUnit.Case, async: false` — Mix.Task
state and the global Application env are shared. Setup uses
`Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared:
true)` so the Mix tasks (which don't run in the test process)
see the sandboxed connection. Per-test unique `tenant_id`
(`"export-test-#{System.unique_integer([:positive])}"`) keeps
DB rows isolated. Reenable **both** tasks between successive
runs in one test:

```elixir
Mix.Task.reenable("jidoclaw.migrate.#{resource}")
Mix.Task.reenable("jidoclaw.export.#{resource}")
```

Without reenabling the migrate task, the second run is a no-op
that won't even hit the import-ledger path — defeats the
idempotency assertion.

Per-test scenarios:

1. **Sanitized happy-path determinism**: copy sanitized fixture,
   run migrate, run export, capture bytes; reenable export task,
   run again, capture bytes; assert byte-equal.
2. **Round-trip idempotency** (Memory and Solutions): rerun
   migrate (must be a no-op via `import_hash` /
   import-ledger); rerun export; assert byte-equal to first
   export.
3. **Redaction-delta / redaction-manifest variant**: copy
   with-secrets fixture, run migrate, run export with
   `--with-redaction-delta` (Memory) or
   `--with-redaction-manifest` (Solutions, Conversations).
   For Memory: assert each row's `redactions_applied` counter
   matches the count returned by
   `Patterns.redact_with_count(original_content)`. For
   Solutions/Conversations: assert the
   `<file>.redaction-manifest.json` sidecar's `redactions`
   list contains entries that, when applied to the original
   content, yield the redacted content in the export.

Fixtures live in
`test/fixtures/exports/<memory|solutions|conversations>/{sanitized,with_secrets}/...`.
Keep them tiny (3-5 records each). Fixture inputs are
checked into git — they're test inputs, not test outputs.

Conversations is the trickiest because the migrate task reads
`.jido/sessions/<tenant>/<id>.jsonl`, and the tenant id is
embedded in the directory path. Per-test unique tenant_id
means per-test fixture-copy with a tenant-renamed subdirectory.
A small helper in `test/support/export_test_helper.ex`
encapsulates the "copy fixture, rename tenant dir" boilerplate
so all three test files stay readable.

#### 5c. Recorder telemetry race tests

Already covered under Fix 1's test additions to
`test/jido_claw/conversations/recorder_test.exs`.

### Note on bookkeeping

The plan also enumerates several other tests at
`encapsulated-goblet.md:1095-1300` (e.g., `harness_turns` derivation,
trigram-index plan stability, `:scope_busy` concurrency,
TTL-sweep eviction). The code review feedback called out only
the three above as missing; we trust that scoping. If others are
still missing, they'll surface in a future review — not in scope
here.

---

## Critical files to modify / create

| File | Action |
|---|---|
| `lib/jido_claw/conversations/recorder.ex` | Subscribe to `ai.usage`; new state for buffer + call→request map; multi-shape `extract_telemetry`; new `handle_signal` clause |
| `lib/jido_claw/agent_server_plugin/recorder.ex` | Add `"ai.usage"` to `signal_patterns` and moduledoc |
| `lib/jido_claw/workspaces/resources/workspace.ex` | Drop `:local_only` from both `constraints(one_of: ...)` |
| `lib/jido_claw/memory/hybrid_search_sql.ex` | New `fts_matches` / `ann_matches` / `lex_matches` + `candidates` CTEs; `shadowed_by` JSON column on winner select; add `id DESC` tie-break to `scope_precedence_partition()`, `deduped`, `candidates`; `load_facts/2` reads + decodes shadow JSON |
| `lib/jido_claw/memory/retrieval.ex` | Delete `maybe_project_shadowed_by/4`, `collect_shadows/4`, `build_chain_filter/1` |
| `lib/jido_claw/cli/commands.ex` | Refactor `edit_and_save_block/2` into recursive `do_edit_block/3`; split `$EDITOR` on whitespace in `open_in_editor/2` |
| `test/jido_claw/conversations/recorder_test.exs` | Add 5 telemetry tests (full-turn happy path, finalize ordering, cache-stale fallback, call_id buffer, latency-only handler) |
| `test/jido_claw/workspaces/workspace_test.exs` | Add `:local_only` rejection test |
| `test/jido_claw/memory/retrieval_test.exs` | Add 4 shadowed_by regression tests (source-precedence, bitemporal, query-mismatch, ANN-precedence) |
| `test/jido_claw/mcp_scope/initializer_test.exs` (new) | Boot Initializer; assert `kind: :mcp` Session row + scope env |
| `test/mix/tasks/jidoclaw_memory_export_test.exs` (new) | Round-trip + determinism + redaction-delta |
| `test/mix/tasks/jidoclaw_solutions_export_test.exs` (new) | Same |
| `test/mix/tasks/jidoclaw_conversations_export_test.exs` (new) | Same |
| `test/fixtures/exports/{memory,solutions,conversations}/*.json` (new) | Fixture inputs |

## Existing functions to reuse

- `JidoClaw.Conversations.RequestCorrelation.record_telemetry/2` — already
  takes a `request_id` + telemetry-fields map; existing call site at
  `recorder.ex:367-371` stays unchanged. Buffer drain just calls this
  with the resolved request_id.
- `JidoClaw.Conversations.RequestCorrelation.Cache.put/2` —
  recorder.ex:377 already merges telemetry into the cache row when
  available.
- `JidoClaw.Memory.HybridSearchSql.scope_rank_case/0` &
  `source_rank_case/0` (line 533-559) — reuse in the new
  `candidates` CTE; the SQL identical to the existing partition.
- `JidoClaw.Memory.HybridSearchSql.build_scope_chain_fragment/2` &
  `build_bitemporal_fragment/2` (lines 242-286) — already produce the
  predicate fragments the new `_matches` CTEs need.
- `JidoClaw.Export.Canonical.encode!/1` — already pinned by
  `test/jido_claw/export/canonical_test.exs`. The new round-trip
  tests rely on its determinism but don't need to re-test it.
- `MCPScope.Initializer.ensure_default_scope/0` — public entry
  point for the new initializer test (avoids GenServer lifecycle).

## Verification

```bash
mix compile --warnings-as-errors
mix ash.codegen --check
mix test
mix test test/jido_claw/conversations/recorder_test.exs
mix test test/jido_claw/workspaces/workspace_test.exs
mix test test/jido_claw/memory/retrieval_test.exs
mix test test/jido_claw/mcp_scope/initializer_test.exs
mix test test/mix/tasks/
```

**Formatting note:** the repo currently has no usable
`.formatter.exs` (`mix format --check-formatted` errors with
"no inputs"), so we don't run the project-wide formatter as a
gate. Format edited files individually:

```bash
mix format lib/jido_claw/conversations/recorder.ex \
           lib/jido_claw/agent_server_plugin/recorder.ex \
           lib/jido_claw/workspaces/resources/workspace.ex \
           lib/jido_claw/memory/hybrid_search_sql.ex \
           lib/jido_claw/memory/retrieval.ex \
           lib/jido_claw/cli/commands.ex
```

(Restoring a working `.formatter.exs` is out of scope — orthogonal
maintenance task.)

End-to-end manual QA for the editor loop:

```bash
mix jidoclaw                      # enter REPL
> /memory blocks edit my-block    # type beyond char_limit, save
                                  # observe: error message + editor re-opens
                                  # type within limit, save
                                  # observe: success message
```

End-to-end manual QA for telemetry capture:

```bash
mix jidoclaw                                      # one chat turn
mix run -e 'JidoClaw.Repo.query!("SELECT model, input_tokens, output_tokens, latency_ms FROM messages ORDER BY inserted_at DESC LIMIT 5") |> IO.inspect()'
```

Expect non-null `model`, `input_tokens`, `output_tokens`, and
`latency_ms` on the most-recent assistant message. `latency_ms`
comes from the standard
`[:jido, :ai, :llm, :complete]` telemetry event, captured by the
new handler; tokens come from `ai.usage`; `model` and `run_id`
come from `ai.llm.response.metadata` and `ai.usage`.

## Commit plan (slicing, not authorization)

Each fix commits with its own tests so a bisect on any commit
runs a green tree. The final commit picks up the standalone
acceptance gates that aren't tied to a code fix.

1. `fix(workspaces): tighten policy attribute constraints to {:default, :disabled}` — workspace.ex change + workspace_test.exs `:local_only` rejection test.
2. `fix(memory): derive shadowed_by from real candidate set` — hybrid_search_sql.ex + retrieval.ex changes + retrieval_test.exs §3.13 regression tests.
3. `fix(conversations): capture telemetry from ai.usage and llm.complete` — recorder.ex + agent_server_plugin/recorder.ex changes + recorder_test.exs five new telemetry tests.
4. `fix(cli): allow re-edit of memory block after char_limit overflow; support multi-arg $EDITOR` — commands.ex changes only. Tests deferred (interactive code; manual QA).
5. `test: add missing v0.6 acceptance gates (mcp initializer, export round-trip)` — initializer_test.exs + three Mix-task export tests + fixture inputs + support helper.
