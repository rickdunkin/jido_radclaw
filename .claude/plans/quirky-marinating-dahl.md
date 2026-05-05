# Phase 3a — Memory: post-review remediation

## Context

A code review of the v0.6 Phase 3a Memory data layer surfaced four P1 and three P2 issues plus a broken prompt test. All eight findings were re-verified against the current tree (line numbers and code snippets confirmed). User approved invalidate-and-replace for `:revise`, full four-mode bitemporal wiring, deleting the prompt persistent-memory describe block, and workspace-only export scoping.

## Findings being addressed

1. **[P1] No-match recall returns unrelated memories** (`retrieval.ex:124-128`) — non-empty query with no hits silently falls through to `recency_scan/2`.
2. **[P1] Retrieval ignores the scope chain** (`retrieval.ex:109-119`, `hybrid_search_sql.ex`) — only the leaf `{kind, fk}` reaches SQL; `Scope.chain/1` exists but is unused.
3. **[P1] ANN search filters on the wrong Voyage model** (`retrieval.ex:43-44`) — defaults to `voyage-4` (request model) while rows are stored under `voyage-4-large` (stored model).
4. **[P1] Block `:revise` is not bitemporal** (`block.ex:130-137`) — plain in-place update; resource docstring contract and `history_for_label` Block-row read both depend on invalidate-and-replace.
5. **[P2] Bitemporal option accepted but unused** (`retrieval.ex:79-88`) — `:bitemporal` parsed but never threaded to `HybridSearchSql`; the `bitemporal_predicate/2` builder already exists at `retrieval.ex:212-241` and is unreferenced from the search path.
6. **[P2] Shell `jido memory search` lost its scope** (`shell/commands/jido.ex:93-102`) — calls `Memory.recall(query)` without `tool_context`; returns `[]` for every query.
7. **[P2] Export task leaks across scopes** (`mix/tasks/jidoclaw.export.memory.ex:40-46`) — `Ash.read!(Fact)` with no tenant/workspace/bitemporal filter; `--project DIR` only sets the output path.
8. **[Test fix] `prompt_test.exs:270`** — calls removed `Memory.remember/3`; the whole `describe "persistent memory integration"` block tests a feature `prompt.ex:426-432` intentionally returns `[]` for in v0.6.3a.

## Files to modify

**P1 fixes**
- `lib/jido_claw/memory/retrieval.ex` — kill no-hit fallback (keep empty-query fallback), switch to scope-chain via `Scope.chain/1`, pull stored model from `PolicyResolver`, thread `:bitemporal` through, also chain-and-bitemporal-aware `recency_scan`.
- `lib/jido_claw/memory/hybrid_search_sql.ex` — accept `scope_chain: [{kind, fk_id}, ...]` (replace `scope_kind`/`scope_fk_id`), inline `Retrieval.bitemporal_predicate/2` fragments per pool, expand the param list with optional world_t/system_t.
- `lib/jido_claw/memory/resources/block.ex` — replace `update :revise` action with a public `revise/2` orchestrator that does invalidate-and-replace inside a transaction. Drop the `code_interface define(:revise)` (the public function carries the same `Block.revise(block, attrs)` signature, so existing call sites keep working).

**P2 fixes**
- `lib/jido_claw/shell/commands/jido.ex` — `emit_memory/2` builds a `tool_context` from `default_scope/0` (mirroring `emit_solution/2` exactly).
- `lib/mix/tasks/jidoclaw.export.memory.ex` — resolve `--project DIR` to `(tenant_id, workspace_id)` via `Workspaces.Resolver.ensure_workspace/3` (opts default `[]`), filter on `tenant_id`/`workspace_id` + current-truth nulls, apply `Redaction.Memory.redact_fact!/1` to each `content`.

**Test hygiene**
- `test/jido_claw/prompt_test.exs` — delete `describe "persistent memory integration"` (lines 268–283) and the v0.5.x ETS-table teardown loop (lines 22–26).
- `test/jido_claw/memory/block_test.exs` — strengthen `:revise` and `history_for_label` assertions (see Targeted regression tests below).
- `test/jido_claw/memory/retrieval_test.exs` (or the existing tests there) — add five targeted regression tests.

**Out of this plan** (deliberately deferred)
- `.formatter.exs` — adding broad-input formatter config now would churn older migrations and resource snapshots, drowning the review-fix diff. Track separately as a one-shot format pass.
- Docker sandbox timeout (`docker_test.exs:118`) — unrelated; address separately. (Note: the reviewer reported it ran in the full suite despite the AGENTS.md exclusion note — don't rely on the tag exclusion in CI.)

## Implementation notes

### 1. No-match recall — `retrieval.ex:124-128`

Today's `case` in `do_search/3`:

```elixir
case {query, ranked} do
  {"", _} -> recency_scan(scope, settings)
  {_, []} -> recency_scan(scope, settings)            # ← bug
  {_, results} -> Enum.map(results, & &1.fact)
end
```

Drop the second clause. Empty-query recency-fallback is intentional (per the docstring at `retrieval.ex:121-123`); a real query with no matches must return `[]`.

### 2. Scope chain — `retrieval.ex` + `hybrid_search_sql.ex`

`Scope.chain/1` already returns `[{:session, id}, {:project, id}, {:workspace, id}, {:user, id}]` (nils filtered, leaf-to-root). Two changes:

**`Retrieval.do_search/3`** — replace `scope_fk(scope)` with `Scope.chain(scope)`; pass into HybridSearchSql args as `scope_chain: chain`. Drop the `scope_fk/1` helper. **Short-circuit `query == ""` directly to `recency_scan/2`** — never call `HybridSearchSql.run/1` for empty queries; with dynamic bitemporal params and disabled CTEs, an empty-query call risks unused-parameter type errors at the planner.

**`HybridSearchSql.run/1`** — accept `scope_chain: [{kind, fk_id}, ...]` (delete the `scope_kind`/`scope_fk_id` keys). Each pool's WHERE clause becomes:

```sql
WHERE tenant_id = $1
  AND (
    (scope_kind = 'session'   AND session_id   = $session_param) OR
    (scope_kind = 'workspace' AND workspace_id = $workspace_param) OR
    -- one OR-clause per chain entry
  )
  AND <bitemporal_predicate>
  ...
```

**Param-builder shape — high-risk plumbing.** Rather than threading a manually-tracked `next_param_index` integer through every helper, each fragment-builder returns a uniform struct:

```elixir
%{sql: clause_string, params: [...], next: next_free_index}
```

`build_scope_chain_fragment(chain, base_idx)` returns the OR-clause SQL, the chain FK params, and the next free `$N`. `build_bitemporal_fragment(bitemporal, base_idx)` returns the predicate SQL, the world_t/system_t params (or `[]`), and the next free `$N`. The top-level `build_sql/_` chains them: `scope = build_scope_chain_fragment(chain, 2)` → `bt = build_bitemporal_fragment(mode, scope.next)` → static query/embedding/etc params slot in at `bt.next` and beyond. This keeps each fragment self-contained and means the index arithmetic lives in one place per fragment, not scattered across pool builders.

The existing `scope_rank_case` window (`hybrid_search_sql.ex:274-284`) already partitions correctly across `scope_kind` once cross-scope rows enter the candidate pool — no change needed there.

Reference: §3.13 of `docs/plans/v0.6/phase-3a-memory-data.md` lines 1090–1132 is the canonical SQL shape; `Solutions.HybridSearchSql.run/1` is similar but workspace-scalar, so it can't be copied verbatim.

### 3. ANN model resolution — `retrieval.ex:43-44, 102-107, 141-146`

Mirror `Solutions.Matcher.resolve_embedding/3` (`solutions/matcher.ex:149-205`) exactly — including the local-vs-voyage arity asymmetry:

- `Embeddings.Local.embed_for_query/1` (single arg — model is read from app env at `lib/jido_claw/embeddings/local.ex:28`).
- `Embeddings.Voyage.embed_for_query/2` (two-arg — caller supplies `request_model`).

```elixir
defp resolve_embedding(query, workspace_id, opts) do
  explicit_embedding = Keyword.get(opts, :query_embedding)
  explicit_model = Keyword.get(opts, :embedding_model)

  cond do
    not is_nil(explicit_embedding) ->
      {explicit_embedding, explicit_model || "voyage-4-large"}

    not is_nil(explicit_model) ->
      {compute_for_model(query, explicit_model, opts), explicit_model}

    true ->
      resolver = Keyword.get(opts, :policy_resolver, PolicyResolver)
      policy = resolver.resolve(workspace_id)
      case resolver.model_for_query(policy) do
        :disabled -> {nil, nil}
        %{provider: :local,  request_model: _req, stored_model: stored} ->
          {compute_local(query, opts), stored}
        %{provider: :voyage, request_model: req,  stored_model: stored} ->
          {compute_voyage(query, req, opts), stored}
      end
  end
end

defp compute_local(query, opts) do
  local_mod = Keyword.get(opts, :local_module, JidoClaw.Embeddings.Local)
  case local_mod.embed_for_query(query) do
    {:ok, vec} -> vec
    _ -> nil
  end
end

defp compute_voyage(query, model, opts) do
  voyage_mod = Keyword.get(opts, :voyage_module, JidoClaw.Embeddings.Voyage)
  case voyage_mod.embed_for_query(query, model) do
    {:ok, vec} -> vec
    _ -> nil
  end
end
```

`workspace_id` comes from the resolved scope record's `workspace_id` field (always populated for `:session`/`:project`/`:workspace` scopes by `Scope.resolve/1` ancestor walk; nil for pure `:user`-scoped recalls — `PolicyResolver.resolve/1` then fails closed to `:disabled`, which is correct: a user-scope-only recall has no per-workspace embedding policy).

`@default_embedding_model` becomes `"voyage-4-large"` (the stored side). Update the doc at `retrieval.ex:61` to note the default is the stored model. Drop the local `embed_query/2` helper.

### 4. Bitemporal wiring — `retrieval.ex:79-88` + `hybrid_search_sql.ex` pools + `recency_scan`

**Search path.** Pass `bitemporal: settings.bitemporal` into the `HybridSearchSql.run/1` args. Each pool currently hardcodes `AND invalid_at IS NULL AND expired_at IS NULL`; replace with the bitemporal fragment (built once via `build_bitemporal_fragment/2` returning the `%{sql, params, next}` shape per §2 above). Pool builders take the `sql` string and inline it. `Retrieval.bitemporal_predicate/2` (`retrieval.ex:212-241`) is the source of truth; the fragment-builder is a thin shell over it.

**Recency path.** `recency_scan/2` (the empty-query path) currently hardcodes `is_nil(invalid_at) and is_nil(expired_at)` and a leaf-only filter. Apply chain + bitemporal **and the same dedup contract** so empty-query listing matches the plan's contract:

```elixir
defp recency_scan(scope, settings) do
  chain = Scope.chain(scope)
  if chain == [] do
    []
  else
    overfetch = max(settings.limit * length(chain), settings.limit)

    query =
      Fact
      |> Ash.Query.do_filter(build_chain_filter(scope.tenant_id, chain))
      |> Ash.Query.do_filter(bitemporal_filter(settings.bitemporal))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(overfetch)

    case Ash.read(query) do
      {:ok, facts} ->
        facts
        |> dedup_recency(settings.dedup)
        |> Enum.take(settings.limit)

      _ ->
        []
    end
  end
end

defp dedup_recency(facts, :none), do: facts

defp dedup_recency(facts, :by_precedence) do
  scope_rank = %{session: 1, project: 2, workspace: 3, user: 4}

  facts
  |> Enum.group_by(fn f -> f.label || {:by_id, f.id} end)
  |> Enum.flat_map(fn {_label, group} ->
    [Enum.min_by(group, fn f ->
      {Map.get(scope_rank, f.scope_kind, 5), -inserted_at_unix(f.inserted_at)}
    end)]
  end)
  |> Enum.sort_by(& &1.inserted_at, {:desc, &compare_dt/2})
end

defp inserted_at_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
defp inserted_at_unix(_), do: 0

defp compare_dt(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
defp compare_dt(nil, %DateTime{}), do: :lt
defp compare_dt(%DateTime{}, nil), do: :gt
defp compare_dt(_, _), do: :eq
```

`build_chain_filter/2` mirrors `Memory.Block.build_chain_filter/2` (`block.ex:518-547`): map each `{kind, fk}` to an `Ash.Expr` clause, reduce with `or`. `bitemporal_filter/1` is a small dispatch returning the appropriate `Ash.Expr` (current_truth filter is `is_nil(invalid_at) and is_nil(expired_at)`; the others use `valid_at <= ^dt`/`invalid_at > ^dt`/etc.). Drop the four `recency_query/3` clauses.

The `overfetch = limit * length(chain)` heuristic gives the dedup pass enough rows to find the closest-scope row for each label even when the parent scope has many recent unrelated facts. After dedup, take the requested `limit`. Catches the recency-chain dedup contract — see Targeted test #5.

### 5. Block invalidate-and-replace — `lib/jido_claw/memory/resources/block.ex`

Pattern after `Memory.Fact`'s invalidate-and-replace (`fact.ex:625-658, 821-838`) and the in-tree transaction shape at `forge/persistence.ex:59-87`:

1. Remove the `update :revise` action and the `WriteRevisionForUpdate` change module's revise branch (it stays for `:invalidate`).
2. Remove `define(:revise, action: :revise)` from `code_interface`. Existing callers (`Block.revise(block, attrs)`) bind to the public Elixir function below, so the signature is preserved.
3. Add a public `revise/2`. References from inside the resource module use `__MODULE__` / bare function names (the `Block` alias does not exist in scope here):

```elixir
@spec revise(t() | Ecto.UUID.t(), map()) :: {:ok, t()} | {:error, term()}
def revise(prior_block_or_id, attrs) when is_map(attrs) do
  with {:ok, prior} <- load_prior(prior_block_or_id) do
    Ash.transact(__MODULE__, fn ->
      with :ok <- invalidate_prior_block(prior),
           new_attrs = build_revise_attrs(prior, attrs),
           {:ok, new_block} <- write(new_attrs),
           {:ok, _rev} <- write_revision_row(prior, attrs) do
        new_block
      else
        {:error, err} -> Ash.DataLayer.rollback(__MODULE__, err)
        other         -> Ash.DataLayer.rollback(__MODULE__, {:unexpected, other})
      end
    end)
  end
end

defp load_prior(%__MODULE__{} = b), do: {:ok, b}

defp load_prior(id) when is_binary(id),
  do: Ash.get(__MODULE__, id, domain: JidoClaw.Memory.Domain)
```

`Ash.transact/3` is the canonical name (`Ash.transaction/3` is now deprecated). It auto-rolls back on any `Ash.DataLayer.rollback/2` raise inside the function and returns `{:ok, result} | {:error, term}` to the caller. The two `else` clauses cover both `{:error, _}` matches and any unexpected non-matching value from a helper, so partial work is never committed even if a callee returns an off-spec shape. (The helpers should still strictly return `:ok | {:ok, _} | {:error, _}` — the catch-all is defense-in-depth.)

`invalidate_prior_block/1` is a single raw SQL `UPDATE memory_blocks SET invalid_at = now(), expired_at = now() WHERE id = $1` (mirroring `Fact.invalidate_prior_active_label/4`). `build_revise_attrs/2` carries scope FKs + label + source + tenant_id forward from `prior`, lets `attrs` override `value`/`description`/`char_limit`/`pinned`/`position`/`written_by`, and lets `write/1`'s existing `before_action` chain (cap-length, cross-tenant, scope-FK) revalidate. `write_revision_row/2` pulls `:reason` and `:written_by` arguments from `attrs` and calls `BlockRevision.create_for_block/1` with the prior's snapshot.

Notes:
- All errors propagate as `{:error, _}` from `Ash.transact/3` — no bang lifts at the public surface. Matches the `{:ok, t()} | {:error, term()}` spec.
- The partial unique identity `(tenant_id, scope_kind, label, fk) WHERE invalid_at IS NULL` already enforces only one active row per `(scope, label)`; the transaction makes invalidate→insert atomic, so two concurrent revises serialize via Postgres row locks (or one fails on identity conflict — caller-visible).
- `:invalidate` stays as-is (in-place timestamp update + revision row); only `:revise` changes.
- The `WriteRevisionForUpdate` change still exists but is only attached to `:invalidate` after this. Rename to `WriteRevisionForInvalidate` if it makes the intent clearer; otherwise leave the name.

**`history_for_label` semantics.** With invalidate-and-replace, Block rows give "all value versions" — one row per `:revise` plus the live or last-invalidated row. Pure `:invalidate` calls do **not** create a new Block row (they flip timestamps and write a revision side-row only), so `history_for_label` will not surface those as separate entries; the final-state-after-invalidate is visible as `invalid_at != nil` on the last row. This matches the plan §3.4 prose ("`(tenant_id, scope FK, label)` → list of revisions, oldest first") and is the simpler contract. If a future surface needs "all mutations including pure invalidates", expose `BlockRevision.history_for_label/3` separately — out of scope here.

### 6. Shell `jido memory search` — `lib/jido_claw/shell/commands/jido.ex:93-102`

```elixir
defp emit_memory(query_words, emit) do
  query = Enum.join(query_words, " ")
  {tenant_id, workspace_uuid} = default_scope()
  tool_context = %{tenant_id: tenant_id, workspace_uuid: workspace_uuid}
  results = JidoClaw.Memory.recall(query, tool_context: tool_context)
  # ...emission unchanged
end
```

`default_scope/0` already exists at line 132. Mirror `emit_solution/2`'s shape exactly so the asymmetry the reviewer flagged is gone.

### 7. Export task — `lib/mix/tasks/jidoclaw.export.memory.ex`

Add `require Ash.Query` at the top of the module — required for `Ash.Query.filter/2` macro expansion in this file. Then replace lines 40-46:

```elixir
project_dir = Keyword.get(opts, :project) || File.cwd!()
out = Keyword.get(opts, :out, Path.join([project_dir, ".jido", "memory_export.json"]))
with_delta? = Keyword.get(opts, :with_redaction_delta, false)

Mix.Task.run("app.start")

{:ok, %{id: workspace_id, tenant_id: tenant_id}} =
  JidoClaw.Workspaces.Resolver.ensure_workspace("default", project_dir)

facts =
  Fact
  |> Ash.Query.filter(
    tenant_id == ^tenant_id and workspace_id == ^workspace_id and
      is_nil(invalid_at) and is_nil(expired_at)
  )
  |> Ash.read!()
```

`ensure_workspace/3` accepts `(tenant_id, project_dir, opts \\ [])` (`workspaces/resolver.ex:19`); the `opts` default makes the two-arg call shape work.

In `fact_to_export/2`, redact once from the original content and reuse:

```elixir
defp fact_to_export(fact, with_delta?) do
  alias JidoClaw.Security.Redaction.Memory, as: MemoryRedaction
  alias JidoClaw.Security.Redaction.Patterns

  original = fact.content || ""
  redacted = MemoryRedaction.redact_fact!(original)

  base = %{
    id: fact.id,
    tenant_id: fact.tenant_id,
    scope_kind: fact.scope_kind,
    user_id: fact.user_id,
    workspace_id: fact.workspace_id,
    project_id: fact.project_id,
    session_id: fact.session_id,
    label: fact.label,
    content: redacted,
    tags: fact.tags,
    source: fact.source,
    trust_score: fact.trust_score,
    valid_at: fact.valid_at,
    inserted_at: fact.inserted_at,
    import_hash: fact.import_hash
  }

  if with_delta? do
    {^redacted, count} = Patterns.redact_with_count(original)
    Map.put(base, :redactions_applied, count)
  else
    base
  end
end
```

Counting against `original` (not the already-redacted value) ensures the delta reflects scrubs that actually occurred. The pattern-match `{^redacted, count} = ...` asserts both redactor entry points produce the same string — a cheap convergence check (both wrap `Patterns.redact/1` / `redact_with_count/1`). Drop `invalid_at` and `expired_at` from the export shape — they're always nil after the filter, no point serializing.

### 8. Prompt test cleanup — `test/jido_claw/prompt_test.exs`

Delete `describe "persistent memory integration"` block (lines 268–283) and the v0.5.x ETS-table teardown loop in `setup` (lines 22–26). The prompt builder's `load_memories/0` returns `[]` as a transitional shim (commented at `prompt.ex:426-432`); v0.6.3b's Block-tier render will need fresh tests against the new contract.

## Targeted regression tests

Add to `test/jido_claw/memory/retrieval_test.exs` (or the closest equivalent fixture):

1. **No-match returns `[]` even when the scope has rows.** Seed two facts at the same workspace scope (`label: "foo"` and `label: "bar"`). Recall `query: "completely-unrelated-string"` — assert `length(results) == 0`. (Catches the recency-fallback regression.)

2. **Workspace fact recalled from a session-scoped tool_context.** Seed one `:workspace`-scoped fact at `label: "api_url"`. Build a `tool_context` with `session_uuid:` populated; assert `Memory.recall("api_url", tool_context: ctx)` returns the workspace fact. (Catches scope-chain regression.)

3. **Explicit `embedding_model: "voyage-4-large"` produces ANN hits.** Seed one fact with embedding populated and `embedding_model = "voyage-4-large"` (the canonical stored model). Stub the Voyage module so `embed_for_query/2` returns a vector close to the seeded fact's embedding. Use a query string that does **not** lexically or substring-match the fact's content/label/tags (e.g. seed content `"Use Stripe for billing"`, query `"completely-orthogonal-tokens-zzz"`) so FTS and lexical pools both produce zero ranks; assert the fact still returns and that the surviving result's `combined_score` is consistent with ANN-only contribution (`1/(60+1) ≈ 0.0164`). Repeat the test with default opts (no `embedding_model:`) — should also return because the new default is `"voyage-4-large"`. (Catches the model-default regression and rules out accidental FTS/lex success.)

4. **`{:world_at, dt}` returns a superseded fact.** Seed a fact with `valid_at = T0 - 1 day, invalid_at = T0, expired_at = T0`. Issue `Memory.recall(q, tool_context: ctx, bitemporal: {:world_at, ~U[T0 - 12 hours]Z})`; assert returned. Repeat with `{:world_at, T0 + 12 hours}`; assert not returned. Mirrors plan §3.13 lines 1447-1457.

5. **Recency scope-chain dedup.** Seed two active workspace-scoped facts (`label: "preference"` content "X") and a session-scoped fact (`label: "preference"` content "Y") under the same chain. Build a `tool_context` whose chain spans both. Issue `Memory.list_recent(ctx, 5)` (empty-query path → recency_scan). Assert exactly one row at `label: "preference"` and that it's the session-scoped one (closer scope wins). (Catches the recency-chain dedup contract.)

Add to `test/jido_claw/memory/block_test.exs`:

6. **`:revise` invalidates prior + creates new row.** Reload the prior block by id; assert `invalid_at != nil` and `expired_at != nil`. Assert the active row's `id` differs from the prior's. Assert `history_for_label` returns ≥ 2 rows ordered by `inserted_at` ascending.

## Verification

Run in this order:

1. `mix compile --warnings-as-errors` — type-checks the chain/scope/bitemporal refactor.
2. `mix ash.codegen --check && mix ash_postgres.generate_migrations --check` — confirms no resource changes leaked into a schema migration (the Block change is action-only, no DDL).
3. `mix test test/jido_claw/memory/` — exercises `:revise`/`history_for_label`/scope-chain/ANN-model alignment, plus all six targeted regression tests above.
4. `mix test test/jido_claw/tools/recall_test.exs test/jido_claw/tools/remember_test.exs` — public API surface.
5. `mix test test/jido_claw/prompt_test.exs` — must pass with the describe block removed.
6. `mix test` — full suite. Expect `docker_test.exs:118` may surface in the timeout list per the reviewer's note (not addressed here).
7. Manual smoke (Tidewave `execute_sql_query`): after seeding a workspace fact and running recall, confirm the SQL pool runs with `embedding_model = 'voyage-4-large'`.
8. Manual smoke (REPL): from `jido_shell`, `jido memory search foo` returns scope-resolved results (was `[]` before).
9. Manual smoke: `mix jidoclaw.export.memory --project /tmp/some_project_dir` exports only that project's tenant/workspace facts, redacted content, no invalid/expired rows.

## Out of scope

- Consolidator / Block tier rendering into prompts (v0.6.3b — `phase-3b-memory-consolidator.md`).
- Plan §3.13 dedup-on-shadowed-by metadata projection.
- Prompt-cache hit assertions (3b/3c).
- `.formatter.exs` and the one-shot format pass.
- Docker sandbox timeout (`docker_test.exs:118`).
