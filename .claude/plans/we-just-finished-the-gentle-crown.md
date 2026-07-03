# Fix review finding: `resolve_embedding?: false` drops an explicit `query_embedding` (Matcher)

## Context

The Lua code-mode plan (`please-review-docs-plans-unadopted-next-squishy-spindle.md`) shipped and was code-reviewed. One finding came back, P3:

> `matcher.ex:113`: `resolve_embedding?: false` currently forces `embedding = nil`, even when the caller supplied an explicit `:query_embedding`. That subtly changes the existing "explicit embedding wins" contract into "disable ANN entirely." Preserve caller-supplied vectors and only skip policy/Voyage resolution when no vector is provided; add a test for `query_embedding: ..., resolve_embedding?: false`.

**Verification: CONFIRMED.** The "explicit embedding wins" contract lives in `EmbeddingResolver.resolve/4` (`lib/jido_claw/memory/embedding_resolver.ex:33-36`) — a non-nil `:query_embedding` returns directly, touching neither `PolicyResolver` nor Voyage. The new gate at `lib/jido_claw/solutions/matcher.ex:113-118` short-circuits to literal `nil` on `resolve_embedding?: false` **before** the resolver is ever consulted, so `query_embedding: vec, resolve_embedding?: false` silently drops `vec` and disables the ANN pool (`$4::vector IS NOT NULL`, `lib/jido_claw/solutions/hybrid_search_sql.ex:154`). Latent, not live: the only caller passing the opt is the Lua `jido.solutions` binding (`lib/jido_claw/tools/lua/bindings.ex:576`), which never passes `query_embedding` — its behavior stays byte-identical after the fix.

**No-egress invariant is preserved by the fix**: entering `EmbeddingResolver.resolve/4` with an explicit vector hits its first clause (return the vector) — no policy lookup, no Voyage HTTP. Shipped docs (AGENTS.md Lua bullet, amber AM-1 §(5), unadopted-next-ten README item-3 blockquote) all describe the opt from the binding's perspective ("the binding is lexical-only / must not trigger Voyage egress") — still true post-fix, so **no doc reconciliation is needed** beyond the matcher's own `@doc`.

Truth table (the fix changes exactly one cell):

| `query_embedding` | `resolve_embedding?` | today | after fix |
| --- | --- | --- | --- |
| absent / nil | `true` (default) | policy path | same |
| absent / nil | `false` | `nil` (no egress) | same |
| vector | `true` (default) | vector, no egress | same |
| vector | `false` | **`nil` — vector dropped (bug)** | **vector, no egress** |

## Changes (2 files)

### 1. `test/jido_claw/solutions/matcher_test.exs` — regression test FIRST (red)

Add to the existing `describe "resolve_embedding?: false (the Lua binding's no-egress seam)"` block. The test must prove the vector *reaches the SQL* (not merely that egress is absent), so the seeded row is reachable **only** via the ANN pool:

```elixir
test "an explicit query_embedding still wins under resolve_embedding?: false (ANN runs, zero egress)",
     %{tenant_id: tenant_id, workspace: ws} do
  vec = List.duplicate(0.05, 1024)

  # Content shares no tokens/trigrams with the query, so the FTS and
  # lexical pools cannot surface this row — only the ANN pool (via the
  # explicit vector) can. Pre-fix, resolve_embedding?: false dropped the
  # vector and this row was unreachable.
  sol =
    solution_fixture(tenant_id, ws.id, "postgres vacuum autotune runbook",
      embedding: vec,
      embedding_status: :ready
    )

  results =
    Matcher.find_solutions("frobnicate zymurgy quixotic",
      tenant_id: tenant_id,
      workspace_id: ws.id,
      threshold: 0.0,
      query_embedding: vec,
      resolve_embedding?: false,
      policy_resolver: SpyResolver,
      voyage_module: SpyVoyage,
      rate_pacer: NoopRatePacer
    )

  refute_received {:resolver_called, _}
  refute_received {:voyage_called_at, _}

  assert Enum.any?(results, fn m -> m.solution.id == sol.id end),
         "explicit query_embedding must reach the ANN pool under resolve_embedding?: false"
end
```

Mechanics (all verified against existing code):
- 1024 dims matches the vector column (`hybrid_search_sql_test.exs:587-595`; the existing explicit-embedding matcher test already uses `List.duplicate(0.01, 1024)`).
- `solution_fixture(..., embedding:, embedding_status: :ready)` is the proven pattern from `hybrid_search_sql_test.exs:240-241`; the store path just persists the injected vector — no Voyage egress on insert.
- Identical query/row vectors → cosine distance 0 → ANN rank 1 → RRF `1/61 ≈ 0.016 ≥ 0.0` threshold.
- Exact-match can't preempt: the fixture's `problem_signature` defaults to a unique hash.
- The SpyResolver/SpyVoyage refutes pin the no-egress invariant *simultaneously* with the vector being honored.

**Red check before fixing**: run `mix test test/jido_claw/solutions/matcher_test.exs` and confirm this test fails (results are `[]` because the vector was nilled → `Enum.any?` false). Never weaken the assertion.

### 2. `lib/jido_claw/solutions/matcher.ex` — the gate (lines 113-118) + `@doc`

Replace the gate so an explicit vector always enters the resolver (whose first clause returns it without any resolution), keeping `EmbeddingResolver` the single owner of the "explicit wins" contract — no duplicated `query_embedding` dispatch in the matcher:

```elixir
# An explicit caller-supplied :query_embedding needs no resolution —
# EmbeddingResolver returns it without touching the policy resolver or
# Voyage — so it survives resolve_embedding?: false, which only skips
# the policy/Voyage resolution that would otherwise compute a vector.
explicit_embedding? = Keyword.get(opts, :query_embedding) != nil

embedding =
  if explicit_embedding? or Keyword.get(opts, :resolve_embedding?, true) do
    resolve_embedding(query, workspace_id, opts)
  else
    nil
  end
```

Present-nil `query_embedding: nil` stays "resolve via policy" (documented semantics), which under `resolve_embedding?: false` still yields `nil` — unchanged.

Update the `@doc` `:resolve_embedding?` entry (matcher.ex:69-75): append one sentence making the contract precise — `resolve_embedding?: false` means "do not **compute** an embedding" (no policy lookup, no Voyage HTTP), **not** "force lexical-only": an explicit caller-supplied `:query_embedding` still wins and the ANN pool still runs with it. (This keeps the Lua binding docs true — the binding supplies no vector, so it IS lexical-only — while making the lower-level API contract exact.)

Rejected alternative (for the record): moving the `resolve_embedding?` check into `EmbeddingResolver.resolve/4` — it would silently extend the opt to `Memory.Retrieval`'s recall path (shared-helper ripple) and exceeds the finding's scope.

## Verification (done = precommit green)

1. **Red**: add the test only; `mix test test/jido_claw/solutions/matcher_test.exs` → 10 tests, 1 failure (the new test; the existing 9 stay green).
2. **Green**: apply the matcher fix; same command → all pass.
3. Adjacent consumer sanity: `mix test test/jido_claw/tools/lua` (the `jido.solutions` no-egress binding test stays green — binding behavior byte-identical).
4. **Gate**: `mix precommit`, run bare (no pipes/tail/echo), report exact exit code + test counts verbatim. Known flake to ignore if it appears: `MemoryExportTest` capture_log race in full suite (pre-existing, not a regression).
5. `mix format` before the gate; credo/reach/dialyzer stay at zero. Nothing committed — all changes stay unstaged alongside the existing working tree.
