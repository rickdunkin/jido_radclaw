# v0.6 Phase 1 — Code Review Fix-Up

## Context

A code review of v0.6 Phase 1 (the Postgres + Ash migration of solutions, hybrid search, embeddings, and the network facade) surfaced 5 verified bugs and a major gap in regression coverage. All 5 findings have been confirmed against the working tree:

1. **P1** — `lib/jido_claw/solutions/hybrid_search_sql.ex:142` source reads `ESCAPE '\\\\'`. In a non-sigil heredoc each `\\` is one runtime backslash, so Postgres receives `ESCAPE '\\'` — a two-character escape string — and rejects with `invalid escape string`. Error is double-swallowed by `run/1` and `Matcher.find_solutions/2`, so non-exact searches silently return `[]`.
2. **P1** — `combined_score` is selected by SQL but dropped by `load_solutions/2` (not an Ash attribute, never reaches the struct). `Matcher` falls back to `trust_score` (default `0.0`) and filters against `0.3`, removing virtually every fuzzy hit.
3. **P1** — `Matcher` defaults `embedding_model` to `"voyage-4-large"` and never consults workspace `embedding_policy`. `:disabled` workspaces with `VOYAGE_API_KEY` set ship query text to Voyage; `:local_only` queries the wrong provider and filters against the wrong stored model.
4. **P1** — `RatePacer.acquire/2` and `RatePacer.try_admit/2` have **zero callers** in `lib/`. Both Voyage entry points (`BackfillWorker.embed_via_voyage/2` and `Matcher.compute_query_embedding/2` Voyage branch) bypass per-node and cluster-global rate limits.
5. **P2** — `NetworkFacade.find_local/2` filters by `tenant_id` only. A node in workspace B can broadcast a workspace-A `:local` row over PubSub if it has the UUID.

Plus 8 deleted test files leaving every §1.8 acceptance gate uncovered.

---

## Key Design Decisions

These decisions are load-bearing and fix the issues raised in plan review. Locking them down before writing tests so test boundaries are clean.

### D1 — Bypass Ash for hybrid search

`Ash.Query.set_result/2` returning wrapper maps from a read action would fight the framework. Choices:
- **(A) Add a virtual/calculated `combined_score` field** on the `Solution` resource so the read action returns `%Solution{combined_score: float}`. Keeps Ash policy hooks intact.
- **(B) Drop the Ash `:search` read action and have `Matcher` call `HybridSearchSql.run/1` directly**, returning `[%{solution: %Solution{}, combined_score: float}]`.

**Decision: (B).** The `:search` action only existed to wrap the manual SQL — there are no policy hooks beyond what the SQL already enforces (tenant + workspace + visibility, all hand-written in the CTE). Removing the action eliminates the dead `before_action` preparation, the result-shape impedance mismatch, and the unused `threshold` argument that the SQL never honored. Matcher gets a clean wrapper-map list. Update the resource to drop the action and the preparation file (`lib/jido_claw/solutions/preparations/hybrid_search.ex`).

### D2 — PolicyResolver fails closed

Missing/unreadable workspace must never default to `:default` (Voyage egress).

**Decision:**
- `PolicyResolver.resolve/1` returns `:disabled` when the workspace row is missing.
- `Matcher` interprets `:disabled` as `query_embedding: nil` (FTS + lexical only).
- `BackfillWorker` interprets `:disabled` for a missing workspace as "transition to `embedding_status: :disabled` and skip Voyage" — same handling as a deliberately-disabled workspace. The `dispatch_one/1` path already does this for `:disabled`; just have `PolicyResolver.resolve/1` return `:disabled` on lookup failure and the existing `case` arm covers it.

### D3 — Separate request model from stored model

`PolicyResolver` returns explicit shape:

```elixir
%{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}
%{provider: :local,  request_model: "mxbai-embed-large", stored_model: "mxbai-embed-large"}
:disabled
```

- SQL filters on `stored_model` (the existing `embedding_model = $11` predicate).
- Voyage HTTP layer (`lib/jido_claw/embeddings/voyage.ex`) uses `request_model`.
- `RatePacer.try_admit/2` keys on a shared Voyage bucket label (e.g., the string `"voyage"`) — no point splitting buckets per request_model when they all hit the same Voyage account.

### D4 — RatePacer semantics: fix the implementation, don't paper over with tests

Once wired, `acquire/2` and `try_admit/2` become user-facing. Three real bugs in the existing impl:

1. **`acquire/2` doesn't block.** Docstring claims it blocks up to `:rate_acquire_timeout_ms`; impl returns `{:error, :timeout}` immediately. Fix: wait queue inside the GenServer.
   - `handle_call({:acquire, model, tokens}, from, state)`: if bucket has capacity, decrement and reply `:ok`. Otherwise enqueue `{from, model, tokens, timeout_ref}` and return `{:noreply, state}`.
   - Schedule a periodic `:refill_tick` (`Process.send_after(self(), :refill_tick, refill_interval_ms)`) **whenever the queue is non-empty** — without this, queued callers get stuck if no new `acquire/2` arrives. Cancel the tick when the queue drains.
   - Each enqueued waiter gets its own `Process.send_after(self(), {:acquire_timeout, ref}, :rate_acquire_timeout_ms)`. On `:refill_tick`, dequeue as many waiters as the refilled bucket allows; for each, `GenServer.reply(from, :ok)` and `Process.cancel_timer(timeout_ref)` to clean up the pending timeout. On `{:acquire_timeout, ref}`, remove the matching waiter and `GenServer.reply(from, {:error, :timeout})`.
2. **`try_admit/2` window math: `max(1, div(rpm * window_seconds, 60))`** clamps to ≥ 1 request per window, so any RPM < `60/window_seconds` is silently rounded up to 1.
   - **Decision: derive an effective window large enough to express the configured RPM** rather than returning `:window_too_short` (turning config into runtime failure is bad operator UX).
   - Effective window: `effective_window_seconds = max(cluster_window_seconds, ceil(60 / rpm))`. So `rpm: 1` with `cluster_window_seconds: 10` upgrades to a 60s window; `rpm: 30` with `cluster_window_seconds: 60` stays at 60s. Log at info level on first boot if the effective window differs from the configured one.
   - Compute `request_cap = div(rpm * effective_window_seconds, 60)` (now always ≥ 1 by construction). Same for `token_cap`.
3. **Window bucketing in the SQL must use the effective window, not `date_trunc('second', now())`.** The current SQL buckets by 1-second granularity, so a 60s cap with second-granularity buckets allows 60× the configured budget. Replace `date_trunc('second', now())` with epoch-floor at the effective window:
   ```sql
   to_timestamp(floor(extract(epoch from now()) / $window_seconds) * $window_seconds)
   ```
   passing `effective_window_seconds` as a parameter. The `embedding_dispatch_window` table's `window_started_at` column then holds the start of the configured window, and the `ON CONFLICT (model, window_started_at)` UPSERT does what its name implies.

These changes turn `RatePacer` from "shaped like a rate limiter, doesn't actually limit" into a working backpressure layer. The public API (`acquire/2`, `try_admit/2`) stays identical, so wiring fixes in `BackfillWorker` and `Matcher` don't churn.

### D5 — Test phasing

Per plan-review feedback:
- **Patch 1 (this plan):** 5 code fixes + RatePacer impl fixes + focused regression tests for each finding (~7 test files).
- **Patch 2 (follow-up, separate plan):** full §1.8 acceptance suite + deleted-test replacements (~17 more test files).
- **Patch 3 (optional, follow-up):** add `.formatter.exs` with proper `inputs` so `mix format --check-formatted` works. Deferred because adding it now will produce broad formatting churn that obscures the bug-fix diff.

### D6 — Test seam style: dependency injection, not Mox

Repo doesn't currently use Mox. Stub Voyage / Local / PolicyResolver via:
- Application env hook for module swap: `Application.get_env(:jido_claw, :voyage_module, JidoClaw.Embeddings.Voyage)`.
- Or explicit `:voyage_module`/`:local_module`/`:policy_resolver` opts on `Matcher.find_solutions/2` and `BackfillWorker.start_link/1`, defaulting to the real module.

Use the explicit-opt path where the call site is short (Matcher), Application env where the call site is deep in the GenServer (BackfillWorker). Tests `Application.put_env/3` in `setup` and assert against a tiny stub module defined in the test file or `test/support/`.

---

## Patch 1 Scope (this plan)

### Code Fixes

#### Fix 1 — Hybrid search ESCAPE clause + error logging

**File:** `lib/jido_claw/solutions/hybrid_search_sql.ex`

- Line 142: change `ESCAPE '\\\\'` → `ESCAPE '\\'`.
- Line 91: replace `{:error, _reason} -> []` with a `Logger.warning("[HybridSearchSql] query failed: #{inspect(reason)}")` then `[]`.
- `Matcher.find_solutions/2:113`: replace silent `_ -> []` with the same logging pattern, scoped to the matcher.

#### Fix 2 — Combined score plumbing (via D1)

**Files:** `lib/jido_claw/solutions/hybrid_search_sql.ex`, `lib/jido_claw/solutions/matcher.ex`, `lib/jido_claw/solutions/preparations/hybrid_search.ex`, `lib/jido_claw/solutions/resources/solution.ex`

- `HybridSearchSql.run/1` returns `[%{solution: %Solution{}, combined_score: float()}]`. `load_solutions/2` extracts `combined_score` from the row's column map and emits the wrapper.
- Drop the `:search` read action from `Solution` and delete `preparations/hybrid_search.ex`.
- `Matcher.find_solutions/2` calls `HybridSearchSql.run/1` directly with the args map; reads `combined_score` from the wrapper. Drop the `trust_score` fallback; threshold filter gates on retrieval relevance only.

#### Fix 3 — Workspace embedding policy on read path (via D2, D3)

**New file:** `lib/jido_claw/embeddings/policy_resolver.ex`

```elixir
defmodule JidoClaw.Embeddings.PolicyResolver do
  alias JidoClaw.Repo

  @spec resolve(workspace_id :: binary() | nil) :: :default | :local_only | :disabled
  def resolve(workspace_id) do
    with {:ok, dumped} <- normalize_workspace_id(workspace_id),
         {:ok, %Postgrex.Result{rows: [[policy]]}} <-
           Repo.query("SELECT embedding_policy FROM workspaces WHERE id = $1", [dumped]) do
      coerce(policy)
    else
      _ -> :disabled  # fail closed — missing/unreadable/malformed workspace blocks egress
    end
  end

  # Accepts:
  #   - 36-char string UUID (Matcher passes this) → Ecto.UUID.dump!
  #   - 16-byte binary (BackfillWorker SQL returns this in raw rows) → pass through
  #   - anything else (incl. nil) → :error
  defp normalize_workspace_id(<<_::binary-size(36)>> = s), do: Ecto.UUID.dump(s)
  defp normalize_workspace_id(<<_::binary-size(16)>> = b), do: {:ok, b}
  defp normalize_workspace_id(_), do: :error

  defp coerce("disabled"), do: :disabled
  defp coerce("local_only"), do: :local_only
  defp coerce("default"), do: :default
  defp coerce(_), do: :disabled

  @spec model_for_query(:default | :local_only | :disabled) ::
          %{provider: :voyage | :local, request_model: String.t(), stored_model: String.t()} | :disabled
  def model_for_query(:default), do: %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}
  def model_for_query(:local_only), do: %{provider: :local, request_model: default_local_model(), stored_model: default_local_model()}
  def model_for_query(:disabled), do: :disabled

  defp default_local_model do
    Application.get_env(:jido_claw, JidoClaw.Embeddings.Local, [])[:model] || "mxbai-embed-large"
  end
end
```

`Ecto.UUID.dump/1` (vs `dump!/1`) returns `:error` instead of raising on a malformed string, and `with` short-circuits to the fail-closed `_ -> :disabled` arm.

**File:** `lib/jido_claw/solutions/matcher.ex`

When `:embedding_model` is **not** passed and `:query_embedding` is **not** passed:
- Resolve via `PolicyResolver.resolve(workspace_id)` then `model_for_query/1`.
- `:disabled` → `query_embedding: nil`, `embedding_model: nil`. SQL handles `nil` via `$4::vector IS NOT NULL`.
- `:local_only` → call `Local.embed_for_query/1` with `request_model`; pass `stored_model` to SQL.
- `:default` → call (rate-paced) `Voyage.embed_for_query/1` with `request_model`; pass `stored_model` to SQL.

**File:** `lib/jido_claw/embeddings/backfill_worker.ex:228–246`

Replace inline `lookup_workspace_policy/1` and `coerce_policy/1` with `PolicyResolver.resolve/1` (same `:default | :local_only | :disabled` shape; the existing `case` in `dispatch_one/1` already handles missing-workspace = `:disabled` once `PolicyResolver` fails closed).

#### Fix 4 — RatePacer wiring + impl fixes (D4)

**File:** `lib/jido_claw/embeddings/rate_pacer.ex`

Implementation of D4. Three changes:

- **acquire/2 blocking** (D4 #1): waiter queue, periodic `:refill_tick` while queue is non-empty, per-waiter `Process.send_after(self(), {:acquire_timeout, ref}, :rate_acquire_timeout_ms)`, `GenServer.reply/2` on dequeue, `Process.cancel_timer/1` on cleanup. See D4 #1 for the precise semantics. **Single bucket model:** v0.6.1 uses one Voyage-wide bucket (no per-model partitioning). The `model` argument on `acquire/2` is accepted for future multi-provider growth but currently ignored by the bucket logic — update the moduledoc accordingly so the field name doesn't imply per-model fairness that doesn't exist. If/when a Local provider needs separate metering, re-shape state to `%{voyage: bucket(), local: bucket()}` keyed on model/provider.
- **try_admit/2 effective-window derivation** (D4 #2): compute on each call. RPM and TPM both must be positive integers — validate at `init/1` and refuse to start with a clear log message if either is `<= 0` or non-integer (operator-visible config error beats silent crash). Once validated:
  ```elixir
  configured_window = Keyword.get(config, :cluster_window_seconds, @default_window)
  effective_window = Enum.max([configured_window, ceil(60 / rpm), ceil(60 / tpm)])
  request_cap = div(rpm * effective_window, 60)
  token_cap = div(tpm * effective_window, 60)
  ```
  Both `request_cap` and `token_cap` are ≥ 1 by construction (since the window is sized to make both expressible). No `max(1, _)` clamp. Log once at boot if `effective_window != configured_window`, including which constraint forced the upgrade (`rpm` or `tpm`).
- **SQL window bucketing** (D4 #3): `try_admit/2` passes `effective_window` as a parameter. The UPSERT replaces `date_trunc('second', now())` with `to_timestamp(floor(extract(epoch from now()) / $window_seconds) * $window_seconds)` so `window_started_at` is the start of the configured window. The `gc_dispatch_window` SQL also needs to delete by the same bucketing or by an absolute age cutoff.

**File:** `lib/jido_claw/embeddings/backfill_worker.ex:259`

```elixir
defp embed_via_voyage(id, content) do
  with :ok <- RatePacer.acquire(:voyage, 1),
       :ok <- RatePacer.try_admit("voyage", 1) do
    case Voyage.embed_for_storage(content, "voyage-4-large") do
      {:ok, vector} -> on_success(id, vector, "voyage-4-large")
      {:error, reason} -> on_failure(id, reason)
    end
  else
    {:error, :timeout} -> on_failure(id, :rate_limited_local)
    {:error, :budget_exhausted} -> on_failure(id, :rate_limited_cluster)
  end
end
```

`on_failure/2` handles `:rate_limited_local | :rate_limited_cluster` with a short fixed retry window (e.g., 30s) without incrementing `attempt_count`. (No `:window_too_short` arm — D4 derives an effective window so that error variant doesn't exist.)

**File:** `lib/jido_claw/solutions/matcher.ex` (Voyage branch of `compute_query_embedding/2`)

```elixir
defp compute_query_embedding(query, %{provider: :voyage, request_model: model}) do
  with :ok <- RatePacer.acquire(:voyage, 1),
       :ok <- RatePacer.try_admit("voyage", 1),
       {:ok, list} <- Voyage.embed_for_query(query, model) do
    list
  else
    _ -> nil  # graceful FTS+lexical fallback; log at info level
  end
end
```

(Token estimation stays at `1` for v0.6.1 — TODO comment referencing the follow-up.)

**File:** `lib/jido_claw/embeddings/voyage.ex`

Current API is `embed_for_query/1` and `embed_for_storage/1`, which hardcodes `"voyage-4"` (or `"voyage-4-large"`) internally. D3 needs explicit `request_model` selection:

- Add `embed_for_query/2` and `embed_for_storage/2` taking `(content, request_model)`.
- Keep `embed_for_query/1` and `embed_for_storage/1` as 1-arity wrappers that delegate to the 2-arity form with the existing default model so existing call sites (if any) don't churn — but in practice Patch 1 updates every call site to use the explicit form.

#### Fix 5 — NetworkFacade.find_local/2 scope

**File:** `lib/jido_claw/solutions/network_facade.ex:66–74`

```elixir
def find_local(solution_id, node_state) when is_binary(solution_id) and is_map(node_state) do
  tenant_id = Map.fetch!(node_state, :tenant_id)
  workspace_id = Map.fetch!(node_state, :workspace_id)

  case Ash.get(Solution, solution_id, domain: JidoClaw.Solutions.Domain) do
    {:ok, %Solution{tenant_id: ^tenant_id, workspace_id: ^workspace_id, sharing: sharing} = sol}
        when sharing in [:local, :shared, :public] ->
      {:ok, sol}

    {:ok, %Solution{tenant_id: ^tenant_id, sharing: :public} = sol} ->
      {:ok, sol}

    _ ->
      :not_found
  end
end
```

Tenant pin retained, workspace + sharing added; cross-workspace path admits `:public` only.

### Tests (Patch 1 regression coverage)

Each test file exists primarily to lock in its corresponding fix.

| Test file | Locks in |
|---|---|
| `test/jido_claw/solutions/search_escape_test.exs` | Helper-level: `%`, `_`, `\` escaping correctness (cheap, directly tied to Finding 1) |
| `test/jido_claw/solutions/hybrid_search_sql_test.exs` | Fix 1 (LIKE escape works, no longer errors) + Fix 2 (combined_score in wrapper, threshold gates correctly) |
| `test/jido_claw/solutions/matcher_test.exs` | Fix 2 (threshold against combined_score, not trust_score) + Fix 3 (PolicyResolver delegation, fail-closed on missing workspace) + cross-workspace isolation |
| `test/jido_claw/solutions/network_facade_test.exs` | Fix 5 (find_local cross-workspace `:local` returns `:not_found`; `:public` crosses; `:shared` stays in workspace) |
| `test/jido_claw/embeddings/policy_resolver_test.exs` | D2 fail-closed + D3 model shape (`:disabled` for missing workspace, raw-binary UUID acceptance, distinct request/stored models for Voyage) |
| `test/jido_claw/embeddings/rate_pacer_test.exs` | D4 (acquire/2 actually blocks until refill or timeout via the periodic refill tick; try_admit/2 enforces low RPM via effective-window derivation; SQL buckets by configured window, not per-second) |
| `test/jido_claw/embeddings/backfill_worker_test.exs` | Fix 4 (Voyage call gated by RatePacer; `:rate_limited_*` reschedules without incrementing attempts) + Fix 3 wiring (`:disabled` workspace skips Voyage) |
| `test/support/jido_claw/solutions_case.ex` | New helper for sandbox + tenant/workspace fixture seeding (used by all of the above) |

### Files to Modify (code, Patch 1)

- `lib/jido_claw/solutions/hybrid_search_sql.ex` — ESCAPE fix, error logging, return wrapper maps
- `lib/jido_claw/solutions/matcher.ex` — call `HybridSearchSql.run/1` directly; consult `PolicyResolver`; rate-pace Voyage; log error fallback
- `lib/jido_claw/solutions/network_facade.ex` — pin `workspace_id` + `sharing` in `find_local/2`
- `lib/jido_claw/solutions/resources/solution.ex` — drop `:search` read action
- `lib/jido_claw/embeddings/voyage.ex` — add `embed_for_query/2` + `embed_for_storage/2` taking explicit `request_model`
- `lib/jido_claw/embeddings/backfill_worker.ex` — `RatePacer` wiring, replace inline policy lookup with `PolicyResolver`, extend `on_failure/2` reasons, switch to `Voyage.embed_for_storage/2`
- `lib/jido_claw/embeddings/rate_pacer.ex` — make `acquire/2` block (waiter queue + refill ticks + per-waiter timeouts); fix `try_admit/2` window math (effective window derivation); switch SQL bucketing to epoch-floor by effective window
- **Delete** `lib/jido_claw/solutions/preparations/hybrid_search.ex` (no longer needed)
- **Regenerate** `priv/resource_snapshots/repo/extensions.json` and any solution-related snapshots if `mix ash.codegen --check` flags drift after dropping `:search`

### Files to Add (Patch 1)

- `lib/jido_claw/embeddings/policy_resolver.ex` (code)
- `test/support/jido_claw/solutions_case.ex` (helper)
- `test/jido_claw/solutions/search_escape_test.exs`
- `test/jido_claw/solutions/hybrid_search_sql_test.exs`
- `test/jido_claw/solutions/matcher_test.exs`
- `test/jido_claw/solutions/network_facade_test.exs`
- `test/jido_claw/embeddings/policy_resolver_test.exs`
- `test/jido_claw/embeddings/rate_pacer_test.exs`
- `test/jido_claw/embeddings/backfill_worker_test.exs`

---

## Existing Code to Reuse

- `JidoClaw.Solutions.Fingerprint.generate/2` — already used by Matcher.
- `JidoClaw.Solutions.SearchEscape.{escape_like,lower_only}/1` — already correct, regression-tested in Patch 1.
- `JidoClaw.Solutions.Solution` Ash resource — drive seeding from tests via `Solution.store/1`. The `:search` action goes away but `:by_signature`, `:store`, `:soft_delete`, etc. stay.
- `Ecto.Adapters.SQL.Sandbox` — already configured; `SolutionsCase` wraps it.

---

## Verification

```bash
mix compile --warnings-as-errors
mix format
mix ash.codegen --check
mix test
```

Manual smoke checks:

1. **LIKE escape regression:** Test DB needs `pgvector` (server-side install — not just `CREATE EXTENSION`) and `pg_trgm`. If `mix test` fails with `extension "vector" is not available`, install pgvector at the Postgres server level (Homebrew: `brew install pgvector` then restart the postgres service); then run:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE EXTENSION IF NOT EXISTS pg_trgm;
   ```
2. **Fuzzy search end-to-end:** `mix jidoclaw`; `/solutions search "FooBar"` against a seeded workspace — confirm hits where the broken build returned `[]`.
3. **Embedding policy egress:** set `VOYAGE_API_KEY=stub`; create a workspace with `embedding_policy: :disabled`; run `/solutions search "anything"` from that workspace; confirm no Voyage HTTP call (telemetry / stub assertion). Same for an unknown workspace UUID — fail-closed must apply.
4. **RatePacer ceiling:** configure `:rpm: 1, :tpm: 60, :cluster_window_seconds: 1`; expect the effective window to upgrade to 60s on boot (log line should say so). Trigger 5 backfill rows in a tight loop; confirm `acquire/2` actually blocks subsequent callers until refill (not returning `:timeout` immediately) and that `try_admit/2` returns `:budget_exhausted` once the per-window cap is consumed.
5. **Network scope:** spin up two `Network.Node` instances with different workspaces; share a `:local` solution UUID; confirm receiving node's `find_local/2` returns `:not_found` (not the broadcastable row).

---

## Out of Scope for Patch 1 (tracked for Patch 2)

The full §1.8 acceptance suite + deleted-test replacements. To be addressed in a follow-up plan once Patch 1 is reviewed and the design decisions above are validated in code:

**§1.8 acceptance gates not covered by Patch 1 regressions:**
- Lexical-index engaged (EXPLAIN ANALYZE plan check)
- Generated-column FTS sanity
- Cross-tenant FK validation
- Policy transition row-status fix-up (`:disabled → :pending` propagation, `purge_existing: true`)
- NetworkFacade integration end-to-end (inbound `:share` + `:response` through `Network.Node`)
- Tenant-scoped reputation parity (same `agent_id` across tenants stays distinct)
- Reputation import-ledger idempotency (identity = `(tenant_id, source_sha256)`; one ledger row per `reputation.json` source hash; same content = no-op even with different path; different content = new ledger entry)
- Cross-node embedding budget (multi-node libcluster harness)
- Embedding-policy egress gate (CLI/tool path — Patch 1 covers it at the Matcher layer)
- Export round-trip (sanitized fixture + redaction-delta sidecar manifest)
- MCP default scope (FindSolution / StoreSolution / Initializer)

**Deleted-test replacements:**
- `solution_resource_test.exs` (Ash resource action coverage — `:store`, `:by_signature`, `:soft_delete`, `:transition_embedding_status`, `:update_trust`, `:update_verification_and_trust`)
- `reputation_test.exs` (Ash resource — defaults, `record_success`/`record_failure`, tenant-scoped parity)
- `reputation_import_test.exs` (one ledger row per `reputation.json` source hash; identity = `(tenant_id, source_sha256)`; same content = no-op regardless of path; different content = new ledger entry)
- `verify_certificate_test.exs`
- `network/node_test.exs`, `network_share_test.exs`, `network_status_test.exs`
- `find_solution_test.exs`, `store_solution_test.exs`
- `mcp_scope/initializer_test.exs`, `tools_mcp_scope_test.exs`
- `shell/commands/jido_test.exs`
- `mix/tasks/jidoclaw_migrate_solutions_test.exs`, `jidoclaw_export_solutions_test.exs`
- `embeddings/voyage_test.exs`, `local_test.exs`
- `workspaces/policy_transitions_test.exs`
- (`solutions/search_escape_test.exs` is moved up to Patch 1 above)

**Patch 3 (optional):** add `.formatter.exs` with proper `inputs` so `mix format --check-formatted` works in CI. Deferred — adding it now produces broad formatting churn that obscures the bug-fix diff.
