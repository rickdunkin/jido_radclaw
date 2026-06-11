# Code review follow-up: P2 retention-sweeper TOCTOU (lock the sweep batch)

## Context

The M7+M8+L9 plan shipped and its post-implementation review surfaced **one finding**:

> **[P2]** `trace_run.ex:241` — `updated_at` is only checked when the sweep batch is read. If `Trace.Persistence` writes a new event for one of those trace IDs after selection but before/between the event/run bulk deletes, the sweeper can delete fresh events, delete the refreshed run row, or leave a fresh event orphaned.

**Verdict: VALIDATED.** `sweep_expired/1` (`lib/jido_claw/trace/resources/trace_run.ex:241-293`) reads the expired batch with a plain `Ash.read` — no lock, no transaction — then issues two independent `Ash.bulk_destroy` calls. `Trace.Persistence.do_persist/2` (the **only** durable writer, a singleton GenServer; grep-verified) runs run-upsert → event-append as two separate sequential transactions (`persistence.ex:99→115`). A trace idle >30 days that revives during the sweep window hits one of three interleavings:

- **(a) fresh data wiped** — bump+event commit between read and event-delete: the fresh event is deleted, then the refreshed run row (same pk — upsert hits the same row via the `unique_trace_id` identity) is deleted.
- **(b) permanent orphan** — bump commits between event-delete and run-delete: the refreshed run is deleted by pk, stranding the just-written event. Orphan events are *deliberately never swept*, so this is permanent garbage.
- **(c) refreshed run deleted** — any interleaving where the bump lands after selection.

Narrow window (sub-second, only for traces reviving exactly during a sweep), but (b) is permanent and the fix is cheap.

**Fix shape (per the review's first suggestion): one transaction + `FOR UPDATE SKIP LOCKED` on the selecting read.** The alternative (re-check expiry at delete time) was analyzed and rejected: the events phase can't be made conditional on the run's `updated_at` in one atomic statement — there's no FK and no event→run Ash relationship to `exists()` through — and reordering runs-first reintroduces the orphan-on-partial-failure hazard the current events-first ordering was built to avoid.

### What the lock guarantees — and the one residual it doesn't

Persistence runs run-upsert → event-insert sequentially (two separate transactions), and is the only event writer. **The lock closes the reviewed fresh-revival TOCTOU** — for a *fresh* event (higher seq, upsert condition passes, `updated_at` bumped):

- Bump committed before the locking SELECT's snapshot → row excluded from the batch. Bump committed between snapshot and lock acquisition → the `FOR UPDATE` predicate re-check (EvalPlanQual) drops the row. Bump in flight → `SKIP LOCKED` skips the row.
- Upsert arriving *after* the sweeper holds the lock → it parks on the row lock (`INSERT … ON CONFLICT DO UPDATE` must lock the conflicting row); after the sweeper commits (row deleted) it finds no conflict → inserts a brand-new run row → the event appends. The trace re-materializes as a consistent run+event pair. No orphan, no fresh-event loss — and the event-insert can't jump the queue, because persistence doesn't start it until its upsert transaction commits.
- `SKIP LOCKED` also lets multi-node sweepers (cluster mode runs one per node) partition batches instead of colliding, and means the locking read never waits → the sweeper can't join a deadlock cycle.
- Crash/failure mid-sweep → rollback → no partial states at all (strictly better than the current two-phase failure story).

**Documented residual (NOT fixed here):** a **skipped** upsert (duplicate/out-of-order event, `incoming_last_seq <= last_seq`) commits *without* bumping `updated_at` and releases its row lock immediately; the subsequent event INSERT never touches the run row, so it can land while the sweeper holds the run lock → that single stale event row can be orphaned. Bounded and benign: only a stale re-emission for an already-expired trace, one unowned row, and orphans are already deliberately unswept. Closing it would require transaction-wrapping `Trace.Persistence.do_persist/2` (or making event-append lock/check the run) — out of scope; record it in the docs as the one remaining orphan source (besides out-of-band deletes) and as a possible follow-up.

### Verified support facts (deps source, ash 3.27.8 / ash_postgres 2.9.1 / ash_sql 0.6.4)

- `Ash.Query.lock/2` accepts strings; ash_postgres `can?({:lock, "FOR UPDATE SKIP LOCKED"})` is true and translates to `fragment("FOR UPDATE OF ? SKIP LOCKED")` (`deps/ash_postgres/lib/data_layer.ex:3736-3769`). **Must be the exact upper-case string** — capability check upcases, but the SQL-generating `lock/3` clause-matches the literal (lowercase → FunctionClauseError). **The `:for_update` atom emits no SKIP LOCKED.**
- Ash never enforces/checks transaction presence for locks — wrapping in `Repo.transaction` is on us (locks released at statement end otherwise).
- `Ash.bulk_destroy` defaults: `strategy: :atomic`, `transaction: :batch`, `max_concurrency: 0` → runs on the calling process/connection; nested `repo.transaction` becomes a savepoint and **joins the outer transaction**. Only `max_concurrency > 1` would task-spawn onto other connections — don't set it.
- Reach: `JidoClaw.Trace.*` and `JidoClaw.Repo` are both `data`-layer; only `data → web` is forbidden — a `Repo.transaction` call inside the resource is layer-internal, no arch finding.
- Ecto SQL sandbox: inner `Repo.transaction` becomes a savepoint; same-transaction `FOR UPDATE` self-locks are no-ops → **all 5 existing sweeper tests keep passing unmodified**.

Done = `mix precommit` passes.

---

## 1. The fix — `lib/jido_claw/trace/resources/trace_run.ex`

Add `alias JidoClaw.Repo`. Extract the batch query into a `@doc false` public builder (so the lock-pin test exercises the *production* query, not a copy):

```elixir
@doc false
# Public for the lock-pin regression test; not part of the resource's API.
def expired_batch_query(%DateTime{} = cutoff) do
  cutoff
  |> __MODULE__.query_to_expired()
  |> Ash.Query.limit(@sweep_batch)
  # Exact upper-case string: ash_postgres validates the lock case-insensitively
  # but generates SQL by clause-matching the literal; the :for_update atom form
  # emits no SKIP LOCKED at all.
  |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
end
```

Rework `sweep_expired/1` to run read + both deletes in **one** `Repo.transaction`, keeping the events-first order, with any failure aborting the whole batch via `Repo.rollback` (tagged reasons):

```elixir
def sweep_expired(%DateTime{} = cutoff) do
  result =
    Repo.transaction(fn ->
      case Ash.read(expired_batch_query(cutoff)) do
        {:ok, []} -> {0, false}
        {:ok, batch} -> sweep_events_then_runs(batch)
        {:error, reason} -> Repo.rollback({:sweep_read, reason})
      end
    end)

  case result do
    {:ok, {deleted, more?}} ->
      {:ok, deleted, more?}

    {:error, reason} ->
      Logger.warning("[TraceRun] retention sweep rolled back: #{inspect(reason)}")
      {:ok, 0, false}
  end
end
```

`sweep_events_then_runs/1` / `destroy_runs/1`: same bulk calls as today (`TraceEvent.sweep_delete(events_query, bulk_options: [return_errors?: true])`, then `__MODULE__.sweep_delete(batch, …)`), but every non-`:success` `BulkResult` branch becomes `Repo.rollback({:sweep_event_delete | :sweep_run_delete, status, error_count})` instead of returning partial progress. Clean success returns `{length(batch), length(batch) == @sweep_batch}`.

**Contract notes:**
- Return shape `{:ok, deleted, more?}` and the `@spec` are unchanged → `RetentionSweeper` GenServer needs no code change.
- Partial-progress accounting (`{:ok, max(length(batch) - errors, 0), false}`) is deleted — all-or-nothing per batch. `more?` is still true only on a cleanly-deleted full batch, so the drain-on-clean-progress gating survives; a failing batch now waits for the next hourly tick with **zero** progress instead of partial.
- Contingency: if the atomicity test (§3) reveals ash_postgres surfaces a mid-delete Postgres error as a *raise* rather than an error `BulkResult`, normalize it in `sweep_expired` with a rescue → same logged `{:ok, 0, false}` path (never-raises posture, `# reach:disable-next-line bare_rescue` annotation per `persistence.ex`).

**Doc rewrite** of the `sweep_expired/1` `@doc` (trace_run.ex:217-239): replace the failure-safe-two-phase-ordering story with the transactional one — single transaction, `FOR UPDATE SKIP LOCKED` on selection, why (closes the fresh-revival TOCTOU: a concurrent Persistence upsert parks on the row lock and re-creates the run cleanly after commit), all-or-nothing failure handling. **Do not claim orphans are impossible**: state the residual plainly — a stale skipped-upsert re-emission racing the sweep can still strand one old event row (see Context), which together with out-of-band deletes is why orphans stay deliberately unswept.

## 2. Doc touch-ups (no behavior change)

- `lib/jido_claw/trace/retention_sweeper.ex` moduledoc (~lines 10-13): "any failure waits for the next tick" wording → each batch is a single transaction; failures roll back wholesale and retry next tick (`more?` still only true on a clean full batch).
- `test/jido_claw/trace/retention_sweeper_test.exs` moduledoc: "two-phase event→run delete" → single-transaction locked sweep.

## 3. Tests — `test/jido_claw/trace/retention_sweeper_test.exs`

Existing 5 tests stay as-is (they pass unchanged under savepoint nesting). Add two pins; a true cross-connection concurrency test is impossible under the SQL sandbox (sandbox rows are uncommitted, hence invisible/unlockable from a second connection) — state that in a comment.

1. **Lock pin** — the production query carries the lock all the way to SQL:
   ```elixir
   query = TraceRun.expired_batch_query(cutoff_days_ago(30))
   assert query.lock == "FOR UPDATE SKIP LOCKED"
   %{query: ecto_query} = Ash.data_layer_query!(query)
   {sql, _} = Repo.to_sql(:all, ecto_query)
   assert sql =~ "FOR UPDATE OF"
   assert sql =~ "SKIP LOCKED"
   ```

2. **Atomicity pin** — a failed run-delete rolls back the already-executed event-delete (`@tag :capture_log`). Seed + backdate a trace, then install a sandbox-local trigger (transactional DDL, auto-reverted by the sandbox rollback; raises only on `trace_runs` DELETE). **Idempotent DDL** — `CREATE OR REPLACE` + `DROP … IF EXISTS` — so a rerun after an interrupted local session that leaked the objects stays boring:
   ```elixir
   Repo.query!("CREATE OR REPLACE FUNCTION sweep_test_block() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'sweep_test'; END; $$ LANGUAGE plpgsql")
   Repo.query!("DROP TRIGGER IF EXISTS sweep_test_block ON trace_runs")
   Repo.query!("CREATE TRIGGER sweep_test_block BEFORE DELETE ON trace_runs FOR EACH ROW EXECUTE FUNCTION sweep_test_block()")

   assert {:ok, 0, false} = TraceRun.sweep_expired(cutoff_days_ago(30))
   assert run_count(expired) == 1
   assert event_count(expired) == 2   # event delete happened in-txn, then rolled back
   ```
   This is the test that pins the actual fix: under the old code it fails (`event_count == 0` — events gone, run stranded… the exact inverse of finding (b)).

## 4. Report bookkeeping — `docs/reports/code-review-2026-06-10.md`

Extend the M7 fixed-note (line 233) with the hardening sentence, per the established per-finding style: post-fix review (2026-06-11) caught a TOCTOU between the batch read and the deletes (a trace reviving mid-sweep could lose fresh rows or strand a permanent orphan event); hardened same day — the batch now runs in a single `Repo.transaction` with `FOR UPDATE SKIP LOCKED` on the selecting read, closing the fresh-revival race (a concurrent Persistence upsert parks on the row lock and cleanly re-creates the run after commit; any delete failure rolls the whole batch back). Name the accepted residual: a stale skipped-upsert re-emission can still strand one old event row, since Persistence's run-upsert and event-append are separate transactions — would need a transaction-wrapped `do_persist/2` to close.

## Verification

1. Targeted: `mix test test/jido_claw/trace/retention_sweeper_test.exs` (all 5 existing + 2 new), then the review's trio `mix test test/jido_claw/trace/retention_sweeper_test.exs test/jido_claw/orchestration/reactor_middleware_test.exs test/jido_claw/orchestration/replay_test.exs`.
2. **`mix precommit` must pass** — the completion gate. Watch-items: dialyzer on the `Repo.transaction` return match; exact `Ash.BulkResult` status matches kept; no new tools/config/migrations, so `system_prompt.check` and `ash.codegen --check` are untouched.
3. No commit unless asked; if asked, style: `Code review P2 fix: transactional locked trace retention sweep`, staging only the files above.
4. Housekeeping once out of plan mode — save the review-feedback lessons to auto-memory: (a) a row lock only serializes writers that touch the locked row — before claiming a concurrency fix is airtight, audit every writer path including skipped/no-op variants (here: a skipped upsert commits without bumping `updated_at`, and the follow-up event INSERT never touches the locked run row); (b) test-created DB objects (triggers/functions) must use idempotent DDL (`CREATE OR REPLACE`, `DROP … IF EXISTS`, or unique names) so interrupted local sessions don't break reruns.
