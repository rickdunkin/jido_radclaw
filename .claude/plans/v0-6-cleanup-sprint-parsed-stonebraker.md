# v0.6 Cleanup Sprint

## Context

Phases 0–4 of `docs/plans/v0.6/` have shipped (commits `bd0da2b` through `4b9d42c`). A post-merge review surfaced:

1. **Plan drift**: `lib/jido_claw/solutions/hybrid_search_sql.ex` uses weighted-blend scoring (`fts*0.4 + ann*0.4 + lex*0.2`) but plan §1.5 (`docs/plans/v0.6/phase-1-solutions.md:1008-1102`) specifies Reciprocal Rank Fusion. Memory already implements RRF correctly (`lib/jido_claw/memory/hybrid_search_sql.ex:13-23, 329-331`); Solutions is the outlier.
2. **Missing dedicated tests** for Phase 1 acceptance gates whose underlying behavior works but is not regression-locked.
3. **Phase 0 §0.7 test gap**: `test/jido_claw/workflows/scope_propagation_test.exs:134` only covers `:sequential` (`SkillWorkflow`). `:dag` (`PlanWorkflow`) and `:iterative` (`IterativeWorkflow`) need parallel integration coverage.
4. **Phase 4 plan deviation**: `priv/repo/migrations/20260510003012_v064_audit_tenant.exs` promotes 16 tenant FKs via standard one-shot `references(:tenants, ...)`, not the plan-§4.2-mandated `NOT VALID` + `VALIDATE CONSTRAINT` staged form.
5. **Phase 2 deferred feature**: optional `search_vector` GIN on `Conversations.Message.content` was left for "if enabled" landing.

Goal: close drift + add regression tests so v0.6 is plan-compliant and the gaps don't reappear.

User-approved scope decisions (from clarification turn):
- **RRF threshold**: retune `Matcher.@default_threshold` AND the one test value that depends on it. Keep other matcher.ex code unchanged.
- **Phase 4**: write a **companion follow-up migration** (don't edit the already-applied `v064_audit_tenant.exs`). The companion migration drops + re-adds the 16 tenant FKs in the staged shape.
- **Phase 2 search_vector**: implement now — resource attr + migration + acceptance test, mirroring Solutions' pattern.

---

## Slice 1 — RRF refactor of Solutions hybrid search

### 1.1 Rewrite `sql/0`

**File**: `lib/jido_claw/solutions/hybrid_search_sql.ex`

Replace the current `pooled` CTE + weighted outer SELECT (lines 173–195) with an RRF shape that mirrors Memory's in-tree pattern (`lib/jido_claw/memory/hybrid_search_sql.ex:327-342`), **not** the plan §1.5 spec's `LEFT JOIN from solutions s` form. Starting the outer SELECT from `solutions s` lets the planner consider a tenant scan; starting from the small ranked CTE forces it to operate on the bounded pool union.

**Keep the existing pool CTE bodies intact** (tenant/workspace/sharing/soft-delete predicates inside each pool, `LIMIT $7 * 4`, `ORDER BY <relevance> DESC`). That's load-bearing for cross-workspace crowd-out — pinned by the test at `test/jido_claw/solutions/hybrid_search_sql_test.exs:140-214`.

New shape:

```sql
WITH
fts_pool AS ( ... existing body, unchanged ... ),
ann_pool AS ( ... existing body, unchanged ... ),
lexical_pool AS ( ... existing body, unchanged ... ),
fts AS (
  SELECT id, RANK() OVER (ORDER BY fts_score DESC) AS r_fts
    FROM fts_pool
),
ann AS (
  SELECT id, RANK() OVER (ORDER BY ann_score DESC) AS r_ann
    FROM ann_pool
),
lexical AS (
  SELECT id, RANK() OVER (ORDER BY lex_score DESC) AS r_lex
    FROM lexical_pool
),
ranked AS (
  SELECT id, r_fts, r_ann, r_lex,
         (CASE WHEN r_fts IS NOT NULL THEN 1.0/(60 + r_fts) ELSE 0.0 END
          + CASE WHEN r_ann IS NOT NULL THEN 1.0/(60 + r_ann) ELSE 0.0 END
          + CASE WHEN r_lex IS NOT NULL THEN 1.0/(60 + r_lex) ELSE 0.0 END
         )::float AS combined_score
    FROM (
      SELECT id, MIN(r_fts) AS r_fts, MIN(r_ann) AS r_ann, MIN(r_lex) AS r_lex
        FROM (
          SELECT id, r_fts, NULL::bigint AS r_ann, NULL::bigint AS r_lex FROM fts
          UNION ALL
          SELECT id, NULL::bigint, r_ann, NULL::bigint FROM ann
          UNION ALL
          SELECT id, NULL::bigint, NULL::bigint, r_lex FROM lexical
        ) u
       GROUP BY id
    ) m
)
SELECT s.*, ranked.combined_score
  FROM ranked
  JOIN solutions s ON s.id = ranked.id
 WHERE s.tenant_id = $9
   AND s.deleted_at IS NULL
 ORDER BY ranked.combined_score DESC, s.trust_score DESC, s.updated_at DESC
 LIMIT $7;
```

Notes:
- Column name **must stay `combined_score`** — `load_solutions/3` looks it up by name (line 216) and the manual-read action (`lib/jido_claw/solutions/reads/hybrid_search.ex:37`) attaches it as Ash resource metadata under the same key for `Matcher.find_solutions/2` to consume.
- Visibility predicates stay inside each pool — do **not** copy the plan SQL's simplified `OR sharing = ANY($8)` form at `phase-1-solutions.md:1020` (it would re-introduce the crowd-out bug).
- `RANK()` (not `ROW_NUMBER()`) per the user's spec preference. RANK produces ties when two pool rows have identical raw scores; harmless under RRF since ties just round-robin into the same `1/(60+r)` slot.
- `CASE WHEN r_* IS NOT NULL THEN 1.0/(60 + r_*) ELSE 0.0 END` for absent pools — mirrors Memory exactly (`memory/hybrid_search_sql.ex:329-331`), making `0.0` the unambiguous "absent" contribution. Avoids `COALESCE(rank, 1000)` (drift from Memory and muddies threshold math).
- Outer `tenant_id = $9 AND deleted_at IS NULL` is defense-in-depth — the pool CTEs already filter these, but keeping the outer predicate guards against any future pool refactor.
- Keep `trust_score`, `updated_at` tie-breakers on the outer `ORDER BY` — RRF produces more ties than weighted-blend, so stable tie-breaking matters more.
- Drop the `pooled` CTE entirely. The new `ranked` CTE replaces it.

### 1.2 Update moduledoc

Rewrite the moduledoc (lines 1–49) to mirror `lib/jido_claw/memory/hybrid_search_sql.ex:13-23`. Explain why RRF: the three pools' raw scores (`ts_rank_cd`, `1 - cosine_distance`, `similarity()`) live on incomparable scales, so rank-only fusion avoids per-pool weight tuning. Keep the parameter-map table and the "visibility predicates inside each pool" paragraph — those are still accurate.

### 1.3 RRF tests

**File**: `test/jido_claw/solutions/hybrid_search_sql_test.exs`

Add a new `describe "run/1 — RRF combine"` block. Fixture notes:
- The workspace's `embedding_policy` is irrelevant to `HybridSearchSql.run/1` directly — the SQL just needs `query_embedding` non-nil + rows with `embedding_status: :ready` + an `embedding`. Use `solution_fixture/4` (`test/support/jido_claw/solutions_case.ex:112`) with explicit `embedding_status: :ready` and `embedding: [...]` for ANN-engaging rows. No need to flip the workspace policy.
- **FTS-only rows are essentially impossible to construct** with English content: `lexical_text` is generated from the same fields FTS sees, and the lexical pool's `LIKE '%query%'` branch substring-matches whenever the query is a substring of the content. The only narrow exception is FTS stemming where the query and content are morphologically related but share no substring — e.g., query `"study"`, content `"studies"` (FTS stems both to `studi`; `LIKE '%study%'` does **not** match `studies`; trigram `similarity('studies', 'study')` is moderate but the test can pick a query length / similarity threshold where the row falls out of the lexical pool). Counter-example to avoid: `"deployment"` vs query `"deploy"` — `"deployment"` literally contains `"deploy"`, so the LIKE branch matches.
- Tests below construct rows deliberately and add SQL probes that **assert each seeded row's intended pool membership before** invoking `HybridSearchSql.run/1`, so a fixture-construction bug is caught before becoming an RRF-combine assertion failure.

Tests. **Each test seeds rows and then immediately runs raw-SQL pool-membership probes** before invoking `HybridSearchSql.run/1` — those probes assert each row enters/skips the pools the test cares about, isolating fixture-construction bugs from RRF-combine bugs. **Probes must mirror production query construction**: the lexical pool uses `SearchEscape.lower_only/1` for the `similarity()` argument and `SearchEscape.escape_like/1` for the `LIKE` pattern (`hybrid_search_sql.ex:84-85`). A raw `lower($query)` probe can disagree with production behavior for `%`, `_`, case, and escape edge cases.

```elixir
defp in_fts_pool?(tenant_id, row_id, query) do
  {:ok, %{rows: rows}} =
    Repo.query(
      """
      SELECT 1 FROM solutions
       WHERE id = $1 AND tenant_id = $2
         AND search_vector @@ websearch_to_tsquery('english', $3)
      """,
      [Ecto.UUID.dump!(row_id), tenant_id, query]
    )
  rows != []
end

defp in_lexical_pool?(tenant_id, row_id, query) do
  raw_lower = SearchEscape.lower_only(query)
  like_pattern = SearchEscape.escape_like(query)

  {:ok, %{rows: rows}} =
    Repo.query(
      """
      SELECT 1 FROM solutions
       WHERE id = $1 AND tenant_id = $2
         AND (lexical_text % $3 OR lexical_text LIKE '%' || $4 || '%' ESCAPE '\\')
      """,
      [Ecto.UUID.dump!(row_id), tenant_id, raw_lower, like_pattern]
    )
  rows != []
end

defp in_ann_pool?(tenant_id, row_id, embedding) do
  {:ok, %{rows: rows}} =
    Repo.query(
      """
      SELECT 1 FROM solutions
       WHERE id = $1 AND tenant_id = $2
         AND embedding IS NOT NULL
         AND embedding_status = 'ready'
         AND $3::vector IS NOT NULL
      """,
      [Ecto.UUID.dump!(row_id), tenant_id, embedding]
    )
  rows != []
end
```

1. **`3-pool beats stronger 2-pool` (the regression-locker)**. Seed:
   - Row A: `solution_content: "pg_basebackup streaming replica"`, language `"elixir"`, framework `"postgrex"`, tags `["replication", "postgres"]`. Provide `embedding_status: :ready` with an embedding whose cosine similarity to the query embedding is **deliberately low but non-zero** (e.g., set ANN pool's `(1.0 - distance) ≈ 0.05` by picking a near-orthogonal embedding). Probe to confirm A enters FTS, ANN, and lexical.
   - Row B: `solution_content` engineered for very high `ts_rank_cd` (repeat all query terms many times, place query terms in language/framework — those carry weight A). Also high lexical `similarity()`. `embedding_status: :pending`, embedding NULL → ANN pool drops B. Probe confirms FTS + lexical, not ANN.
   - Query: text `"postgres replica streaming"` + the query embedding chosen so A is mid-ANN, B is absent from ANN.
   - **Deterministic weighted-blend check (before asserting RRF result)**: query the seeded raw scores via raw SQL — `SELECT ts_rank_cd(...), (1.0 - (embedding <=> query::vector)), similarity(lexical_text, ...) FROM solutions WHERE id IN ($A, $B)`. Compute `0.4*fts + 0.4*ann + 0.2*lex` per row. **Assert old-formula(B) > old-formula(A)** — this proves the fixture is calibrated to defeat the old weighted formula, so the test will actually catch a regression to weighted-blend.
   - Then **assert RRF ranks A above B** by checking `HybridSearchSql.run/1` returns `[A, B]` (A first).
   - Under RRF math: A scores `3 × 1/61 ≈ 0.0492`; B scores `2 × 1/61 ≈ 0.0328`. A wins regardless of raw-score magnitudes.

2. **Constant pool membership preserves rank ordering**. Seed 3 rows R1/R2/R3 with descending `ts_rank_cd` (higher token density / weight-A placement on R1, less on R2, least on R3). All three have `embedding_status: :disabled`, embedding NULL (ANN drops). Probe-assert each row is in `fts_pool` AND in `lexical_pool` — since constructing FTS-only rows from natural English is essentially impossible, all three end up in both pools. Additionally **probe the per-pool rank order**: query each pool's CTE (the SELECT-with-RANK form) directly to confirm both FTS and lexical produce `R1 < R2 < R3` ranks. With identical pool membership and identical rank ordering across both pools, the RRF sum trivially preserves the order. Assert `HybridSearchSql.run/1` returns `[R1, R2, R3]`.

3. **Missing-pool defaults (ANN absent)**. Query with `query_embedding: nil` — `$4::vector IS NOT NULL` short-circuits the entire ANN pool. Seed:
   - Row X: `solution_content: "deploymnt configuration runbook deploymnt steps"`, language `"elixir"`. Contains the literal query token. Probe to confirm X enters FTS (`websearch_to_tsquery('english', 'deploymnt')` tokenizes to a stem that matches `deploymnt` in X) AND lexical (trigram + LIKE both match).
   - Row Y: `solution_content: "deployment configuration runbook"`. Does **not** contain the literal `"deploymnt"` substring. Probe to confirm Y is out of `fts_pool` (FTS stems `deployment` → `deploy`; `deploymnt` stems differently, so no FTS match) but in `lexical_pool` (trigram similarity is high — `dep`, `epl`, `plo`, `loy` shared — and you can verify the trigram threshold is exceeded by querying `similarity('deployment configuration runbook', 'deploymnt')` and asserting it's above the default 0.3 threshold).
   - Query: text `"deploymnt"`, `query_embedding: nil`.
   - Probes prove the intended pool memberships hold.
   - Assert X (FTS+lexical, RRF ≈ 2/61 ≈ 0.033) ranks above Y (lexical only, RRF ≈ 1/61 ≈ 0.016). Validates `CASE WHEN r_ann IS NULL THEN 0.0` works and the 2-pool > 1-pool ordering holds without crashing.

4. **Preserve the existing crowd-out test** at lines 140–214 unchanged. Logic survives RRF intact: visible row's rank within each pool is still ~position 42 inside `LIMIT 40`, so it still falls out. Re-validate the test passes; do not edit its body.

### 1.4 Threshold retune (collateral)

**File**: `lib/jido_claw/solutions/matcher.ex` line 51

```elixir
# Before
@default_threshold 0.3

# After
@default_threshold 0.01
```

Rationale: under RRF, max possible `combined_score` is `3 × 1/(60+1) ≈ 0.0492` (3-pool perfect match), typical 2-pool matches hit `~0.033`, single-pool matches hit `~0.016`. `0.01` keeps roughly the "single-pool match is interesting enough to surface" semantic the old `0.3` had.

**File**: `test/jido_claw/solutions/matcher_test.exs` line 70

Update the one explicit `threshold: 0.05` to `threshold: 0.005`. Update the surrounding comment at lines 68–69, 79–81 to drop the "0.3 lexical-pool reach" framing and replace with "RRF score for single-pool match is ~0.016". Other tests in the file use `threshold: 0.0` — unaffected.

### 1.5 Out of scope (do not change)

- `load_solutions/3` (lines 214–250). Column-name contract preserved.
- `lib/jido_claw/solutions/reads/hybrid_search.ex` — threshold filter site. The `0.005` value flows through from the matcher; the read module is generic.
- Pool CTE bodies (visibility, soft-delete, language/framework, embedding_status, HNSW partial-index predicate).
- The Postgres extensions (`pg_trgm`, `vector`).
- Memory's RRF — already correct.

---

## Slice 2 — Phase 1 acceptance gate tests

### 2.1 Standalone `reputation_test.exs`

**New file**: `test/jido_claw/solutions/reputation_test.exs`

Three describe blocks:

1. **`describe "Reputation.upsert + trust composition"`** — extract the one existing reputation test from `test/jido_claw/solutions/solution_test.exs:9-88` ("uses the agent's real reputation score (not the 0.5 neutral fallback)"). After the extraction lands, delete the duplicate from `solution_test.exs` to avoid drift. The fixture pattern (direct `Reputation.upsert/2` call) is documented at `solution_test.exs:20`.

2. **`describe "tenant-scoped isolation"`** — covers plan gate at `phase-1-solutions.md:1489-1505`. Seed reputation `(tenant_a, agent_x, score: 0.9)` and `(tenant_b, agent_x, score: 0.1)`. Assert `Reputation.get(agent_x, tenant: tenant_a, actor: actor_a)` returns the 0.9 row and `Reputation.get(agent_x, tenant: tenant_b, actor: actor_b)` returns the 0.1 row — they don't bleed across tenants.

3. **`describe "import-ledger idempotency"`** — covers gate at `phase-1-solutions.md:1506-1514`. The idempotent-skip behavior does **not** live on the `ReputationImport` resource (which only exposes `record_import/1` create + `find_by_hash/1` get — a second `record_import` with the same `source_sha256` would fail the unique identity, not "short-circuit success"). It lives in the mix-task migration path at `lib/mix/tasks/jidoclaw.migrate.solutions.ex:187-214` (`migrate_reputation/3` — checks `ReputationImport.find_by_hash/1`, prints "skipping" and returns 0 if already imported). Test approach:
   - Seed a temp `.jido/reputation.json` file in a fixture directory (use `System.tmp_dir!/0` + `File.write!/2`).
   - Call the mix task's private function via `JidoClaw.Mix.Tasks.JidoclawMigrateSolutions` if exported, OR invoke `Mix.Task.run("jidoclaw.migrate.solutions", [...])` with the fixture project dir.
   - First run: assert it imports `n` rows + writes a `ReputationImport` row.
   - Second run: assert it short-circuits ("already imported" log; no new rows; no new `ReputationImport` row).
   - The function `migrate_reputation/3` is currently private (`defp`). If invoking via `Mix.Task.run/2` is too heavy for unit testing, the cleanest fix is a small refactor: expose `migrate_reputation/3` (or extract to `JidoClaw.Solutions.ReputationLegacyImporter` as a thin public module) — but that's a code change beyond the test addition. **Decision**: keep this test out of scope for the sprint unless the refactor is accepted. Flag as a follow-up: "Test reputation import idempotency via the mix-task path (requires either `Mix.Task.run/2` integration or a public importer module)."

### 2.2 Generated-column-populated assertion

**New file**: `test/jido_claw/solutions/generated_columns_test.exs`

Covers gate at `phase-1-solutions.md:1475-1482`. One test:

**Important**: `Solution.store/2` accepts `problem_signature`, **not** `problem_description` (`lib/jido_claw/solutions/resources/solution.ex:131-147`). The generated columns are computed from `language + framework + tags + solution_content` (`migrations/20260501113129_v061_solutions.exs:26-55`) — `problem_signature` does **not** feed into `search_vector` or `lexical_text`. The test below puts the FTS/lexical content in `solution_content`.

```elixir
test "search_vector and lexical_text are populated by Postgres, not Elixir" do
  tenant_id = unique_tenant_id()
  workspace = workspace_fixture(tenant_id)
  actor = actor_for(tenant_id)

  {:ok, sol} =
    Solution.store(
      %{
        problem_signature: "deploy_postgres_replica_v1",
        solution_content: "use pg_basebackup with streaming replication for postgres replica setup",
        language: "elixir",
        framework: "postgrex",
        tags: ["replication", "postgres"],
        workspace_id: workspace.id,
        agent_id: "agent_a",
        sharing: :local
      },
      tenant: tenant_id,
      actor: actor
    )

  # Read the generated columns via raw SQL (Ash doesn't expose them).
  {:ok, %{rows: [[search_vec, lex]]}} =
    Repo.query(
      "SELECT search_vector::text, lexical_text FROM solutions WHERE id = $1",
      [Ecto.UUID.dump!(sol.id)]
    )

  assert is_binary(search_vec)
  assert search_vec =~ "replica"        # token from solution_content (weight C)
  assert search_vec =~ "elixir"         # token from language (weight A)
  assert search_vec =~ "postgrex"       # token from framework (weight A)
  # `replication` would appear with weight B (tags); the test exercises C
  # and A directly — B path is exercised by the FTS-match assertion below.
  assert lex =~ "pg_basebackup"
  assert lex == String.downcase(lex)

  # FTS still matches against tokens that came from the right source fields.
  {:ok, %{rows: [[count]]}} =
    Repo.query(
      """
      SELECT COUNT(*) FROM solutions
       WHERE id = $1
         AND search_vector @@ websearch_to_tsquery('english', $2)
      """,
      [Ecto.UUID.dump!(sol.id), "postgres replica"]
    )

  assert count == 1
end
```

### 2.3 Cross-tenant FK rejection tests

**File**: extend `test/jido_claw/solutions/solution_test.exs` with a new `describe "cross-tenant FK rejection"` block. Plan gate at `phase-1-solutions.md:1438-1449`.

Two tests:

1. `:store` with mismatched `(tenant_id, workspace_id)`: seed `workspace_a` in `tenant_a`, call `Solution.store(%{workspace_id: workspace_a.id, ...}, tenant: tenant_b, actor: actor_b)`. Assert `{:error, _}` with `:cross_tenant_fk_mismatch` somewhere in the error chain. Verify no row written via raw SQL:

   ```elixir
   {:ok, %{rows: [[count]]}} =
     Repo.query("SELECT COUNT(*) FROM solutions WHERE tenant_id = $1", [tenant_b])
   assert count == 0
   ```

   (`Repo.aggregate/2` needs an Ecto query or schema as first argument; the raw SQL form sidesteps the need to materialize a queryable for the bare table.)

2. Same shape for `:import_legacy`. The `Changes.ValidateCrossTenantFk` module at `lib/jido_claw/solutions/resources/solution.ex:494-565` runs the same check for both actions, so this is a parallel test.

Use `Workspaces.Workspace.by_id_global/1` (defined at `lib/jido_claw/workspaces/resources/workspace.ex:135-140`, code interface at `:72`) for the in-test cross-tenant lookup if needed.

### 2.4 Policy-transition fixup test

**Extend existing file**: `test/jido_claw/workspaces/policy_transitions_test.exs` (already exists; covers `memory_facts` `:default` and `:disabled` transitions). Add a new `describe "apply_embedding/3 — solutions coverage and full state machine"` block. Covers gate at `phase-1-solutions.md:1450-1466`.

The function under test is `JidoClaw.Workspaces.PolicyTransitions.apply_embedding/3` at `lib/jido_claw/workspaces/policy_transitions.ex:26` — it iterates `@embedding_tables = ["solutions", "memory_facts"]`.

Single test, multiple assertions threaded through state transitions:

**Helper note**: the existing private helper is `ws/2` at file line 80 (`defp ws(tenant_id, label)`) — it doesn't accept opts. For the solutions test, either (a) extend the helper to a third argument `ws(tenant_id, label, opts \\ [])` that forwards `embedding_policy` and any future opts to the workspace create, or (b) reuse `SolutionsCase.workspace_fixture/2` (which already accepts an `embedding_policy:` opt). Option (a) is cleaner for cohesion with the existing tests in this file; pick that.

```elixir
test "embedding policy transitions fix up solution row status across the full state machine",
     %{tenant_id: tenant_id} do
  {:ok, ws} = ws(tenant_id, "sol-policy-flip", embedding_policy: :disabled)
  actor = JidoClaw.Authorization.Actor.system(tenant_id)

  # 1. With :disabled, stored solutions get :disabled status.
  sols = for i <- 1..3, do: seed_solution(ws, tenant_id, "problem #{i}")
  Enum.each(sols, fn s -> assert s.embedding_status == :disabled end)

  # 2. Flip to :default — all three rows go to :pending, error fields cleared.
  :ok = PolicyTransitions.apply_embedding(ws.id, :default)
  for s <- reload_solutions(sols, tenant_id, actor) do
    assert s.embedding_status == :pending
    assert s.embedding_attempt_count == 0
    assert s.embedding_last_error == nil
  end

  # 3. Simulate backfill completion via direct SQL (backfill worker is out of scope).
  Enum.each(sols, &mark_solution_embedding_ready(&1, tenant_id))
  Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
    assert s.embedding_status == :ready
  end)

  # 4. Flip back to :disabled WITHOUT purge_existing — rows stay :ready.
  :ok = PolicyTransitions.apply_embedding(ws.id, :disabled)
  Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
    assert s.embedding_status == :ready
    refute is_nil(s.embedding)
  end)

  # 5. Flip with purge_existing — rows go :disabled, embedding NULL.
  :ok = PolicyTransitions.apply_embedding(ws.id, :disabled, purge_existing: true)
  Enum.each(reload_solutions(sols, tenant_id, actor), fn s ->
    assert s.embedding_status == :disabled
    assert is_nil(s.embedding)
  end)
end
```

Field names verified against `lib/jido_claw/solutions/resources/solution.ex:259, 375, 386`: `embedding_attempt_count` and `embedding_last_error` (not `embedding_attempts` / `last_embedding_error`).

The existing `memory_facts` tests in the file (lines 12+) already cover the analogous gate; no separate `test/jido_claw/memory/policy_transitions_test.exs` is needed. The plan-§3.19 mirror gate is already (mostly) satisfied by the existing file. If the full 5-step state-machine is also desired for Facts, add a parallel test in the same file using `seed_disabled_fact/2` (existing helper at the bottom of the file).

### 2.5 Lexical-index EXPLAIN regression

**New file**: `test/jido_claw/solutions/lexical_index_explain_test.exs`

Covers gate at `phase-1-solutions.md:1405-1415`. No EXPLAIN-assertion prior art in this codebase — design the pattern from scratch:

```elixir
@moduletag :slow

test "lexical-only query uses solutions_lexical_text_trgm_idx (Bitmap Index Scan)" do
  tenant_id = unique_tenant_id()
  workspace = workspace_fixture(tenant_id)

  # Seed 5,000 rows so the planner has a real choice.
  bulk_insert_solutions(workspace, tenant_id, 5_000)

  query_text = "uncommonlexicaltoken"

  {:ok, %{rows: rows}} =
    Repo.query(
      """
      EXPLAIN (FORMAT JSON)
      SELECT id FROM solutions
       WHERE tenant_id = $1
         AND deleted_at IS NULL
         AND (lexical_text % $2 OR lexical_text LIKE '%' || $3 || '%' ESCAPE '\\')
      """,
      [tenant_id, query_text, query_text]
    )

  [[plan_json]] = rows
  plan = plan_json |> List.first() |> Map.fetch!("Plan")

  assert plan_uses_index?(plan, "solutions_lexical_text_trgm_idx"),
         "expected Bitmap Index Scan on trigram index; got: #{inspect(plan)}"
end

defp plan_uses_index?(%{"Node Type" => node_type, "Index Name" => idx}, target)
     when node_type in ["Bitmap Index Scan", "Index Scan"] and idx == target,
     do: true
defp plan_uses_index?(%{"Plans" => children}, target) when is_list(children),
  do: Enum.any?(children, &plan_uses_index?(&1, target))
defp plan_uses_index?(_, _), do: false
```

Tag `@moduletag :slow` so the 5k-row seed doesn't slow the default suite. **`test/test_helper.exs:1` currently reads `ExUnit.start(exclude: [:docker_sandbox])`** — update it to `ExUnit.start(exclude: [:docker_sandbox, :slow])`. The slow test can then be run on demand via `mix test --include slow`.

Bulk-insert helper goes in `SolutionsCase` for reuse. Use `Repo.insert_all/2` (bypasses Ash's per-row pipeline; acceptable for fixture seeding). Specifics:

- **UUIDs as binaries**: `id` and `workspace_id` must be dumped via `Ecto.UUID.dump!/1` — `Repo.insert_all` doesn't run Ecto's type casters the way `Repo.insert` does.
- **Enum columns as text**: `sharing: "local"`, `embedding_status: "disabled"` (string values matching the DB enum representation, not atoms).
- **Unique `problem_signature` per row**: required (NOT NULL) and has a uniqueness identity (`(workspace_id, problem_signature)` typical) — use a counter suffix like `"bulk-sig-#{i}"`.
- **Timestamps**: `inserted_at` and `updated_at` must be supplied as `%DateTime{}` — `insert_all` does not auto-populate them.

**EXPLAIN test seed mix**: a 5,000-row table where *every row* matches the lexical predicate would still let the planner pick a sequential scan (matching everything is cheaper than the index). Seed 4,990 rows with content that does **not** contain `"uncommonlexicaltoken"` (e.g., `"baseline solution #{i}"`) and 10 rows that *do* contain it. The selective ~0.2% hit rate is what forces the planner toward the trigram GIN index.

**Critical**: After `Repo.insert_all/2`, call `Repo.query("ANALYZE solutions")` before running the `EXPLAIN`. Without an explicit analyze, the planner's stats may still reflect a near-empty table and choose a sequential scan even with 5k rows — particularly on fresh databases or older Postgres versions. The plan §1.4 acceptance gate explicitly assumes the planner has accurate stats.

---

## Slice 3 — Phase 0 scope propagation: `:dag` and `:iterative`

**File**: `test/jido_claw/workflows/scope_propagation_test.exs`

Add two new integration tests mirroring the existing SkillWorkflow test at lines 134–168. Plan §0.7 requirement at `docs/plans/v0.6/phase-0-foundation.md:649-661`.

Both `PlanWorkflow.run/4` (`lib/jido_claw/workflows/plan_workflow.ex:36`) and `IterativeWorkflow.run/4` (`lib/jido_claw/workflows/iterative_workflow.ex:51`) accept `scope_context:` as a keyword opt — same shape as `SkillWorkflow`.

**Capture mechanism**: the existing SkillWorkflow test uses **message-passing**, not an Agent. `EchoStub` sends `{:echo_stub, :tool_context, tc}` to a target PID stored in `:echo_stub_target` Application env, and the test asserts with `assert_receive {:echo_stub, :tool_context, tc}, 5_000`. Reuse this. The capture target is `self()` in the test process. **Do not** introduce an Agent.

**Setup factoring**: the existing `agent_templates_override` setup (file lines 105–132) lives inside the `describe "SkillWorkflow integration"` block, so it does not auto-apply to new describes. Lift the setup — including the `Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)` call, the `:agent_templates_override` env put, the `:echo_stub_target` env put, and matching `on_exit` cleanup — to module level. The sandbox owner specifically prevents DB-ownership flakes when workflow drivers spawn worker processes that write `RequestCorrelation` rows; do **not** drop it. The lift must preserve the existing SkillWorkflow integration test's behavior — re-run it after the move.

```elixir
# Module-level setup applied to every integration describe.
# Replaces the inline `setup` currently inside the SkillWorkflow describe (lines 105-132).
setup do
  sandbox_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)

  Application.put_env(:jido_claw, :agent_templates_override, %{
    "echo_test" => %{
      module: EchoStub,
      description: "test-only echo template",
      model: :fast,
      max_iterations: 1
    }
  })

  Application.put_env(:jido_claw, :echo_stub_target, self())

  on_exit(fn ->
    Application.delete_env(:jido_claw, :agent_templates_override)
    Application.delete_env(:jido_claw, :echo_stub_target)
    Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_pid)
  end)

  :ok
end

describe "PlanWorkflow integration via agent_templates_override" do
  test "every step in a parallel DAG receives parent scope via :scope_context" do
    parent_scope = %{
      tenant_id: "parent_tenant_dag",
      session_id: "sess-dag",
      session_uuid: "00000000-0000-0000-0000-000000000a01",
      workspace_id: "parent_ws_dag",
      workspace_uuid: "00000000-0000-0000-0000-000000000a02",
      project_dir: File.cwd!()
    }

    # Parallel DAG: step_a and step_b have NO dependencies (run in parallel).
    # step_c depends_on: [:step_a, :step_b] (fan-in). This exercises DAG-mode
    # specifically — a linear `step_a -> step_b` skill collapses to sequential
    # ordering and would also pass under a broken DAG implementation.
    skill = test_parallel_dag_skill()

    assert {:ok, _results} =
             PlanWorkflow.run(skill, "", File.cwd!(), scope_context: parent_scope)

    # Receive one tool_context message per step (3 total) and assert each
    # carries the parent scope subset. Order is not guaranteed (parallel),
    # so collect first, assert second.
    tcs = collect_echo_stub_tool_contexts(3, 5_000)
    assert length(tcs) == 3

    Enum.each(tcs, fn tc ->
      assert tc.tenant_id == parent_scope.tenant_id
      assert tc.session_uuid == parent_scope.session_uuid
      assert tc.workspace_uuid == parent_scope.workspace_uuid
      assert tc.workspace_id == parent_scope.workspace_id
      assert tc.project_dir == parent_scope.project_dir
      # agent_id is the per-step generated tag, not inherited.
      assert is_binary(tc.agent_id)
      assert String.starts_with?(tc.agent_id, "wf_echo_test_")
    end)

    # Note: verifying that step_c received step_a/step_b OUTPUTS (true fan-in)
    # would require EchoStub to also capture the `prompt` argument it received
    # — but EchoStub currently only forwards `tool_context`. Pin the fan-in
    # property at the workflow-driver level via a separate unit test on
    # PlanWorkflow's step dispatcher if needed. For this regression test,
    # "3 distinct steps all observed with parent scope" is the scope-propagation
    # guarantee we're protecting.
  end
end

describe "IterativeWorkflow integration via agent_templates_override" do
  test "generator and evaluator receive parent scope on every iteration" do
    parent_scope = %{
      tenant_id: "parent_tenant_iter",
      session_id: "sess-iter",
      session_uuid: "00000000-0000-0000-0000-000000000b01",
      workspace_id: "parent_ws_iter",
      workspace_uuid: "00000000-0000-0000-0000-000000000b02",
      project_dir: File.cwd!()
    }

    # max_iterations: 2, with EchoStub returning no "VERDICT: PASS" so the
    # loop completes the full 2 iterations. Each iteration runs generator
    # then evaluator = 4 total invocations.
    skill = test_iterative_skill(max_iterations: 2)

    assert {:ok, _results} =
             IterativeWorkflow.run(skill, "", File.cwd!(), scope_context: parent_scope)

    tcs = collect_echo_stub_tool_contexts(4, 5_000)
    assert length(tcs) == 4,
           "expected 4 captures (gen+eval × 2 iterations); got #{length(tcs)}"

    Enum.each(tcs, fn tc ->
      assert tc.tenant_id == parent_scope.tenant_id
      assert tc.session_uuid == parent_scope.session_uuid
      assert tc.workspace_uuid == parent_scope.workspace_uuid
    end)
  end
end

# Helper: drain N {:echo_stub, :tool_context, tc} messages from the mailbox.
defp collect_echo_stub_tool_contexts(n, timeout) do
  for _ <- 1..n do
    receive do
      {:echo_stub, :tool_context, tc} -> tc
    after
      timeout -> flunk("did not receive expected #{n} tool_context messages")
    end
  end
end
```

Notes:
- The **parallel-DAG test skill** must have at least two parallel-runnable steps and a fan-in step — a `step_a -> step_b` linear graph only exercises sequential mode within `PlanWorkflow`, which doesn't distinguish DAG-mode from sequential-mode. Recommended shape: `step_a` (no deps), `step_b` (no deps), `step_c` (`depends_on: [:step_a, :step_b]`).
- The **iterative test count assertion** is load-bearing: `max_iterations: 2` with no PASS verdict in `EchoStub` produces exactly 4 invocations (gen, eval, gen, eval). Asserting `length(tcs) == 4` (not `>= 1`) catches both "scope propagation skipped on iteration 2" and "second iteration never ran" regressions.
- Scope subset comparison (not `tc == parent_scope`) is required because `EchoStub` captures the full `tool_context`, which includes dynamic fields like `agent_id` and additional driver-injected keys.
- Reuse the test-skill construction pattern from the existing SkillWorkflow test. The existing skill is built inline (`scope_propagation_test.exs:135-145`); for the new tests, define `test_parallel_dag_skill/0` and `test_iterative_skill/1` as private helpers in the same file. If pattern duplication piles up, extract to `test/support/jido_claw/test_skills.ex` — but defer that until needed.
- After lifting setup to module-level, delete the inline `setup` block inside `describe "SkillWorkflow integration"` (lines 105–132) to avoid double-registration of the override env var. Re-run the existing test to verify behavior is preserved.

---

## Slice 4 — Phase 2 `search_vector` on `Conversations.Message`

### 4.1 Resource attribute

**File**: `lib/jido_claw/conversations/resources/message.ex`

Add a `search_vector` attribute. Mirror Solutions' pattern at `lib/jido_claw/solutions/resources/solution.ex:395-400` exactly:

```elixir
attribute :search_vector, AshPostgres.Tsvector do
  allow_nil?(true)
  public?(false)
  writable?(false)
  generated?(true)
end
```

Type is **`AshPostgres.Tsvector`** (not `:tsvector`) — that's the Ash type registered for the Postgres `tsvector` shape and what Solutions/Memory use.

Add an entry to the existing `custom_indexes` block (`message.ex:96`):

```elixir
custom_indexes do
  # ... existing entries ...
  index([:search_vector], using: "gin", all_tenants?: true, name: "messages_search_vector_idx")
end
```

`all_tenants?: true` matches the Solutions and Memory GIN-index declarations (`solution.ex:79`, `fact.ex:137`) — without it, AshPostgres would scope the index per tenant, which doesn't make sense for a single shared GIN.

### 4.2 Migration

Strategy: let `mix ash_postgres.generate_migrations` produce the column declaration and GIN index, then hand-edit to add the IMMUTABLE wrapper SQL function (codegen can't produce that). Mirror Solutions migration `priv/repo/migrations/20260501113129_v061_solutions.exs` lines 26–39 + 113–116 + 136.

Migration sketch (after codegen):

```elixir
def up do
  execute("""
  CREATE OR REPLACE FUNCTION messages_search_vector(content text)
  RETURNS tsvector LANGUAGE sql IMMUTABLE AS $$
    SELECT to_tsvector('english', coalesce(content, ''))
  $$;
  """)

  alter table(:messages) do
    add(:search_vector, :tsvector,
      generated: "ALWAYS AS (messages_search_vector(content)) STORED"
    )
  end

  create(index(:messages, [:search_vector], using: "gin", name: "messages_search_vector_idx"))
end

def down do
  drop(index(:messages, [:search_vector], name: "messages_search_vector_idx"))

  alter table(:messages) do
    remove(:search_vector)
  end

  execute("DROP FUNCTION IF EXISTS messages_search_vector(text)")
end
```

**Online-migration caveat**: adding a `STORED GENERATED` column to an existing populated `messages` table acquires `ACCESS EXCLUSIVE LOCK` for the duration of the rewrite (Postgres backfills the generated column for every existing row in-place). For local development and any environment where `messages` is small (≤ a few hundred thousand rows), this is acceptable. For production environments with very large `messages` tables, this slice would need restructuring (add a regular nullable column, backfill in batches with a trigger maintaining writes, then add NOT NULL and the GIN index — beyond this sprint's scope). **Explicit decision**: accept the lock for this sprint. If/when production scale requires online migration, that's a separate ticket; the gate `phase-2-conversations.md:712-716` was framed as "if enabled," which implies an explicit operator choice rather than a continuous-deployment requirement.

### 4.3 Acceptance test

**New file**: `test/jido_claw/conversations/message_search_vector_test.exs`

Same pattern as Slice 2.2 (generated column populated by Postgres, FTS matches). Set up using `JidoClaw.TenantCase.seed_full/1` (`test/support/jido_claw/tenant_case.ex:153`) which seeds a tenant + workspace + session in one call — `Message.append/2` needs a real `session_id` and a tenant context.

```elixir
test "Message.search_vector is populated by Postgres and supports FTS" do
  %{tenant_id: tenant_id, session: session, actor: actor} = seed_full()

  {:ok, msg} =
    Message.append(%{
      session_id: session.id,
      role: :user,
      content: "deploy the postgres replica via pg_basebackup"
    }, tenant: tenant_id, actor: actor)

  {:ok, %{rows: [[sv]]}} =
    Repo.query("SELECT search_vector::text FROM messages WHERE id = $1",
                [Ecto.UUID.dump!(msg.id)])

  assert is_binary(sv)
  assert sv =~ "replica"
  assert sv =~ "deploy"

  # FTS query matches via the GIN index.
  {:ok, %{rows: [[count]]}} =
    Repo.query("""
      SELECT COUNT(*) FROM messages
       WHERE id = $1
         AND search_vector @@ websearch_to_tsquery('english', $2)
    """, [Ecto.UUID.dump!(msg.id), "postgres replica"])

  assert count == 1
end
```

Note: do **not** pass `:sequence` to `Message.append/2`. The action's `accept` list at `message.ex:143-164` does not include `:sequence`; the `AllocateSequence` change at `:162` populates it. Passing `:sequence` would fail with an "argument not accepted" error.

### 4.4 Out of scope for this slice

- Wiring `search_vector` into `conversation_search` or audit queries — those consumers were planned for Phase 3/4 and don't exist yet in code form. Adding the column + index keeps the surface forward-compatible without committing to a consuming feature.
- No `Manual` read action, no new `Message` query interface. The column is dormant until a consumer arrives.

---

## Slice 5 — Phase 4 companion FK migration

### 5.1 New migration

**New file**: `priv/repo/migrations/<next_timestamp>_v064b_tenant_fk_staged.exs`

Drop + re-add each of the 16 tenant FKs from `v064_audit_tenant.exs` using the staged shape. Tables (cite `20260510003012_v064_audit_tenant.exs:598-960`):

```
messages, solutions, memory_links, reputation_imports,
audit_events, workspaces, request_correlations,
conversation_sessions, memory_facts, memory_consolidation_runs,
memory_episodes, cron_jobs, reputations, memory_block_revisions,
memory_fact_episodes, memory_blocks
```

**Critical: disable the DDL transaction.** Ecto runs migrations inside a single transaction by default; if both `DROP CONSTRAINT` and `VALIDATE CONSTRAINT` run in the same transaction, the lock held by the constraint operations isn't released until commit — defeating the online-migration goal. Add `@disable_ddl_transaction true` at the top of the migration module. Within each step, use one atomic `ALTER TABLE` statement to drop+re-add (avoiding the brief window where the table has no FK), then a separate statement to validate:

Per-table shape (use `execute/1` end-to-end so the migration body assertion test can read the source directly):

```elixir
defmodule JidoClaw.Repo.Migrations.V064bTenantFkStaged do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    # ---- messages ----
    execute("""
    ALTER TABLE messages
      DROP CONSTRAINT messages_tenant_id_fkey,
      ADD CONSTRAINT messages_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE messages VALIDATE CONSTRAINT messages_tenant_id_fkey")

    # ---- solutions ----
    execute("""
    ALTER TABLE solutions
      DROP CONSTRAINT solutions_tenant_id_fkey,
      ADD CONSTRAINT solutions_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE solutions VALIDATE CONSTRAINT solutions_tenant_id_fkey")

    # ... repeat for each of the 16 tables ...
  end

  def down do
    # Each table: drop the staged FK, re-add as the one-shot validated form
    # (matching v064's post-state).
    execute("""
    ALTER TABLE messages
      DROP CONSTRAINT messages_tenant_id_fkey,
      ADD CONSTRAINT messages_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id)
    """)
    # ... repeat ...
  end
end
```

Lock semantics under this shape:
- The combined `DROP + ADD NOT VALID` acquires `ACCESS EXCLUSIVE` *briefly* — the FK metadata change itself is fast (no scan).
- The separate `VALIDATE CONSTRAINT` acquires `SHARE UPDATE EXCLUSIVE` — doesn't block reads or writes. The scan runs concurrently.
- `@disable_ddl_transaction true` ensures each `execute/1` commits independently, so the validate doesn't hold the brief drop-add lock.

The 16 tables (from `20260510003012_v064_audit_tenant.exs:598-960`): `messages, solutions, memory_links, reputation_imports, audit_events, workspaces, request_correlations, conversation_sessions, memory_facts, memory_consolidation_runs, memory_episodes, cron_jobs, reputations, memory_block_revisions, memory_fact_episodes, memory_blocks`.

### 5.2 Migration-body assertion test

**New file**: `test/jido_claw/repo/v064b_migration_shape_test.exs`

No prior art for this in the codebase — design from scratch. The test reads the migration source as text and asserts on substrings/regexes.

```elixir
defmodule JidoClaw.Repo.V064bMigrationShapeTest do
  use ExUnit.Case, async: true

  @migration_glob "priv/repo/migrations/*_v064b_tenant_fk_staged.exs"
  @tables ~w(
    messages solutions memory_links reputation_imports audit_events
    workspaces request_correlations conversation_sessions memory_facts
    memory_consolidation_runs memory_episodes cron_jobs reputations
    memory_block_revisions memory_fact_episodes memory_blocks
  )

  setup_all do
    [path] = Path.wildcard(@migration_glob)
    {:ok, source: File.read!(path)}
  end

  test "DDL transaction is disabled", %{source: src} do
    assert src =~ "@disable_ddl_transaction true"
  end

  test "every tenant FK is added NOT VALID then VALIDATEd in correct order",
       %{source: src} do
    for table <- @tables do
      # Match the table-specific ADD CONSTRAINT ... NOT VALID block. Anchor
      # the regex to the constraint name so we capture the position of THIS
      # table's add, not the first NOT VALID in the file.
      add_re =
        ~r/ADD\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s+FOREIGN\s+KEY\s*\(\s*tenant_id\s*\)\s+REFERENCES\s+tenants\s*\(\s*id\s*\)\s+NOT\s+VALID/

      validate_re = ~r/VALIDATE\s+CONSTRAINT\s+#{table}_tenant_id_fkey/

      add_match = Regex.run(add_re, src, return: :index)
      validate_match = Regex.run(validate_re, src, return: :index)

      assert add_match,
             "missing 'ADD CONSTRAINT #{table}_tenant_id_fkey ... NOT VALID' in migration"

      assert validate_match,
             "missing 'VALIDATE CONSTRAINT #{table}_tenant_id_fkey' in migration"

      # Table-specific ordering: this table's NOT VALID add must precede
      # this table's VALIDATE — not just any NOT VALID before any VALIDATE.
      {add_pos, _} = hd(add_match)
      {validate_pos, _} = hd(validate_match)

      assert add_pos < validate_pos,
             "VALIDATE appears before NOT VALID add for table #{table}"
    end
  end

  test "drop and re-add are in the same ALTER TABLE statement per table",
       %{source: src} do
    # Atomic drop+add: between BEGIN-of-statement and the table's NOT VALID
    # add, the migration must contain `DROP CONSTRAINT <name>_tenant_id_fkey`.
    # Reject migrations that separate them into two `execute/1` calls (which
    # would leave the table briefly without an FK, violating the plan's
    # online-migration invariant).
    for table <- @tables do
      # `\s+` everywhere SQL allows whitespace — including around the
      # comma separator, REFERENCES, the parens, and NOT VALID — so that
      # `mix format`-driven reflows of the migration source don't break
      # this regex.
      atomic_re =
        ~r/ALTER\s+TABLE\s+#{table}\s+DROP\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s*,\s*ADD\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s+FOREIGN\s+KEY\s*\(\s*tenant_id\s*\)\s+REFERENCES\s+tenants\s*\(\s*id\s*\)\s+NOT\s+VALID/

      assert Regex.match?(atomic_re, src),
             "drop+add for #{table} must be in one atomic ALTER TABLE — separate execute calls leave a window with no FK"
    end
  end
end
```

Async-safe (read-only over a file), zero DB impact. The per-table position capture via `Regex.run(..., return: :index)` is the load-bearing change vs. the earlier draft — `:binary.match/2` would find the first global `"NOT VALID"` occurrence regardless of which table's constraint it belongs to, so the order assertion could pass spuriously (e.g., for table N if any earlier table M < N had NOT VALID, that earlier position would satisfy N's check). The third test pins the atomic drop+add property explicitly.

---

## Critical files to be modified

| File | Slice | Action |
|------|-------|--------|
| `lib/jido_claw/solutions/hybrid_search_sql.ex` | 1.1, 1.2 | rewrite `sql/0` and moduledoc |
| `lib/jido_claw/solutions/matcher.ex` | 1.4 | retune `@default_threshold` |
| `test/jido_claw/solutions/hybrid_search_sql_test.exs` | 1.3 | add 3 new tests; preserve existing |
| `test/jido_claw/solutions/matcher_test.exs` | 1.4 | retune one `threshold:` value + comment |
| `test/jido_claw/solutions/reputation_test.exs` | 2.1 | new file (extract one existing test + add tenant-scoped isolation; idempotency deferred) |
| `test/jido_claw/solutions/solution_test.exs` | 2.1, 2.3 | remove duplicated reputation test; add FK rejection block |
| `test/jido_claw/solutions/generated_columns_test.exs` | 2.2 | new file |
| `test/jido_claw/workspaces/policy_transitions_test.exs` | 2.4 | **extend** (file already exists, covers memory_facts; add solutions + full state-machine coverage) |
| `test/jido_claw/solutions/lexical_index_explain_test.exs` | 2.5 | new file |
| `test/test_helper.exs` | 2.5 | add `:slow` to `ExUnit.start(exclude: [...])` |
| `test/jido_claw/workflows/scope_propagation_test.exs` | 3 | add 2 describe blocks |
| `lib/jido_claw/conversations/resources/message.ex` | 4.1 | add attribute + custom_indexes entry |
| `priv/repo/migrations/<ts>_v062_message_search_vector.exs` | 4.2 | new migration (hand-edit after codegen) |
| `priv/resource_snapshots/repo/messages/*.json` | 4.2 | auto-regenerated by `mix ash_postgres.generate_migrations` — must be staged in the same commit |
| `test/jido_claw/conversations/message_search_vector_test.exs` | 4.3 | new file |
| `priv/repo/migrations/<ts>_v064b_tenant_fk_staged.exs` | 5.1 | new migration (`@disable_ddl_transaction true`) |
| `test/jido_claw/repo/v064b_migration_shape_test.exs` | 5.2 | new file |
| `test/support/jido_claw/solutions_case.ex` | 2.5 | add `bulk_insert_solutions/3` helper |

---

## Reusable patterns referenced

- RRF SQL skeleton: plan §1.5 at `docs/plans/v0.6/phase-1-solutions.md:1008-1102` (but **keep current pool visibility predicates**, not the simplified spec form at line 1020).
- RRF moduledoc style: `lib/jido_claw/memory/hybrid_search_sql.ex:13-23`.
- Generated-column + IMMUTABLE function: `priv/repo/migrations/20260501113129_v061_solutions.exs:26-55, 113-121, 141-144`.
- Test fixtures: `test/support/jido_claw/solutions_case.ex` (`unique_tenant_id/0:55`, `workspace_fixture/2:74`, `solution_fixture/4:112`, `actor_for/1:63`).
- `Workspaces.Workspace.by_id_global/1`: `lib/jido_claw/workspaces/resources/workspace.ex:72, 135-140`.
- `Workspaces.PolicyTransitions.apply_embedding/3`: `lib/jido_claw/workspaces/policy_transitions.ex:26`.
- Scope-context plumbing in workflows: `lib/jido_claw/workflows/plan_workflow.ex:36-42`, `lib/jido_claw/workflows/iterative_workflow.ex:51-56`.
- Solution `:search` manual action / threshold filter / metadata attachment: `lib/jido_claw/solutions/reads/hybrid_search.ex:24-41`.
- Cross-tenant FK validator change module: `lib/jido_claw/solutions/resources/solution.ex:494-565`.

---

## Verification

After each slice, run the targeted slice command first; run the full suite before declaring the sprint complete.

```bash
# Slice 1
mix format lib/jido_claw/solutions/hybrid_search_sql.ex \
            lib/jido_claw/solutions/matcher.ex \
            test/jido_claw/solutions/hybrid_search_sql_test.exs \
            test/jido_claw/solutions/matcher_test.exs
mix compile --warnings-as-errors
mix test test/jido_claw/solutions/hybrid_search_sql_test.exs
mix test test/jido_claw/solutions/matcher_test.exs
# Optional EXPLAIN sanity: pick a representative query, confirm HNSW
# partial index and trigram GIN index still engaged on the relevant pools.

# Slice 2
mix test test/jido_claw/solutions/reputation_test.exs
mix test test/jido_claw/solutions/generated_columns_test.exs
mix test test/jido_claw/solutions/solution_test.exs
mix test test/jido_claw/workspaces/policy_transitions_test.exs
mix test test/jido_claw/solutions/lexical_index_explain_test.exs --include slow

# Slice 3
mix test test/jido_claw/workflows/scope_propagation_test.exs

# Slice 4
mix ecto.migrate                # apply the new search_vector migration
mix test test/jido_claw/conversations/message_search_vector_test.exs

# Slice 5
mix ecto.migrate                # apply the v064b staged FK migration
mix test test/jido_claw/repo/v064b_migration_shape_test.exs

# Final
mix format
mix compile --warnings-as-errors
mix ash_postgres.generate_migrations --check    # confirms no pending resource/migration drift
mix test
```

Manual MCP verification (Tidewave) after Slice 1: pick a representative `Solution.search` query and run `EXPLAIN ANALYZE` via `mcp__tidewave__execute_sql_query` to confirm:
- The HNSW partial index `solutions_embedding_hnsw_idx` (predicate `embedding IS NOT NULL AND embedding_status = 'ready'`, defined in `priv/repo/migrations/20260507120000_v062_strip_local_embeddings.exs:108`) is still engaged on the ANN pool. Note: the older per-model partial indexes (`solutions_embedding_voyage_hnsw_idx`, `solutions_embedding_local_hnsw_idx`) were dropped in v062 — do not look for them.
- The trigram GIN index `solutions_lexical_text_trgm_idx` is still engaged on the lexical pool.

The `RANK() OVER` windows run on pool output, not pool predicates — they should not disturb index selection.

---

## Commit slicing (guidance, not authorization)

Five logical commits, in this order so each is independently testable and revertable:

1. `refactor(solutions): replace weighted-blend with RRF in hybrid search`
2. `test(solutions): add Phase 1 acceptance gate tests (reputation, generated columns, FK rejection, policy transitions, EXPLAIN)`
3. `test(workflows): cover scope propagation for :dag and :iterative drivers`
4. `feat(conversations): add Message.search_vector with generated column + GIN`
5. `chore(db): companion migration promoting tenant FKs to staged NOT VALID + VALIDATE form`

Each commit should land green (`mix test` + `mix compile --warnings-as-errors`).
