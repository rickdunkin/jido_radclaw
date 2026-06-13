# Fix P1: Concurrent approval decisions overwrite each other (stale-loaded `AgentCase`)

## Context

The just-shipped V2-1 per-tool-call approval gate (plan
`concurrent-humming-shannon.md`) added a run-less decision path to
`JidoClaw.Orchestration.Cases`. A code review surfaced one **P1**: the
human-approval decision path can record **contradictory operator decisions
under a real race** (operator A approves while operator B rejects, last write
wins). This plan fixes it. Completion criterion: **`mix precommit` passes**.

### The validated finding

`AgentCase`'s `:approve`/`:reject` actions carry
`change filter(expr(status == :pending))`. The moduledoc (`agent_case.ex:19-28`)
and the `:approve` comment (`agent_case.ex:151`) claim this "compiles to a
DB-side `UPDATE … WHERE status = 'pending'`" and is the multi-approver race
fence. **It does not.** For *record* updates in `ash_postgres 2.9.1`
(confirmed in `mix.lock`) a `change filter` is an **in-memory precondition**,
not a DB `WHERE` — the captured UPDATE keys on `id`/`tenant_id` only. This is
stated correctly in the team's own `:consume` comment (`agent_case.ex:209-215`)
and matches the project's recorded behavior note (`change filter` ≠ DB fence in
ash_postgres 2.9). The reviewer also reproduced it empirically (rollback-only
Tidewave eval: load a pending case twice, approve struct A, reject the stale
struct B → the stale reject returned `{:ok, …}` and left the row `:rejected`).

Because the decision is computed from the **pre-transaction struct** loaded at
`cases.ex:127`, two deciders that both load `:pending` before either commits
each pass the in-memory precondition and both write — the loser overwrites the
winner. Affected commit paths (all use the stale loaded struct):

- `commit_approve/5` — `cases.ex:344` (workflow axis)
- `commit_reject/5` — `cases.ex:363` (workflow axis)
- `commit_tool_call_decision/5` (both clauses) — `cases.ex:307`, `cases.ex:317` (run-less tool-call axis)
- `commit_retract/5` — `cases.ex:441` (reopen of the stale `:approved` struct — same class of bug, a double-retract artifact; folded in for consistency so the corrected docs are uniformly true)

**Not affected** (already correct — they re-read `pending_for_run` *fresh
inside* the transaction, not from the pre-load): `commit_abandon/5`
(`cases.ex:390`) and recovery's `cancel_pending_cases/4`
(`workflow_log.ex:181`). No logic change there; docs only.

The workflow path's existing `lock_run/3` (`cases.ex:467`) serializes the two
transactions but does **not** fix this — the loser still holds a stale
`:pending` struct and overwrites. The run-less path has no lock at all in its
decision transaction.

## Fix

Use the codebase's established **`FOR UPDATE` reload-and-recheck** idiom — the
exact pattern already in `Cases.lock_run/3`,
`AgentCaseEvent.Changes.Allocate.lock_case/3` (`allocate.ex:63`), and
`ToolApprovals.lock_by_fingerprint/3`. Inside each decision transaction:
reload the `AgentCase` row `FOR UPDATE`, re-check its status on that **locked,
fresh** struct, then run the decision action **on the locked struct** (never
the pre-loaded one). The loser blocks on the row lock, reads the winner's
committed status, and rolls back with `{:error, :not_pending}`.

### `lib/jido_claw/orchestration/cases.ex`

1. **New private helper** `lock_case/3`, mirroring `lock_run/3` exactly:
   ```elixir
   defp lock_case(case_id, tenant, actor) do
     AgentCase
     |> Query.filter(id == ^case_id)
     |> Query.lock("FOR UPDATE")
     |> Ash.read_one(tenant: tenant, actor: actor)
     |> case do
       {:ok, %AgentCase{} = locked} -> {:ok, locked}
       _ -> {:error, :not_found}
     end
   end
   ```
   (`Query`, `Ash.read_one`, `AgentCase`, and `ensure_case_pending/1`/
   `ensure_case_approved/1` already exist in this module — no new deps.)

2. **`commit_approve/5` / `commit_reject/5`** — insert the case lock + recheck
   **after** `lock_run` (preserving the global **run → case** lock order the
   `cases.ex:337-343` comment requires), and pass the **locked** struct to the
   action:
   ```elixir
   with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
        {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
        :ok <- ensure_case_pending(locked),
        {:ok, gate} <- AgentCase.approve(locked, attrs, tenant: tenant, actor: actor),
        ...
   ```

3. **`commit_tool_call_decision/5`** (both `:approve` and `:reject` clauses) —
   no run, so case lock only (consistent with the producer, which also locks
   `agent_cases` first):
   ```elixir
   with {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
        :ok <- ensure_case_pending(locked),
        {:ok, gate} <- AgentCase.approve(locked, attrs, tenant: tenant, actor: actor),
        ...
   ```

4. **`commit_retract/5`** — same shape with `ensure_case_approved/1` and
   `AgentCase.reopen(locked, …)`, after `lock_run` (run → case order):
   ```elixir
   with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
        {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
        :ok <- ensure_case_approved(locked),
        :ok <- ensure_not_resumed(run.id, tenant, actor),
        {:ok, gate} <- AgentCase.reopen(locked, %{}, tenant: tenant, actor: actor),
        ...
   ```

5. **Docs** — rewrite the `## Idempotency / concurrency` moduledoc
   (`cases.ex:69-74`) and the `commit_approve` lock-order comment
   (`cases.ex:337-343`) to describe the `FOR UPDATE` reload-recheck fence and
   the now run→case→(events) order. Keep the pre-transaction `ensure_case_pending`
   early-out in `decide_tool_call/5` (cheap masking of the sequential duplicate;
   the in-transaction recheck is the real fence).

**Deadlock check** (verified): all workflow commits take `lock_run` first, so
they serialize on the run before touching the case → global run→case order is
preserved. The run-less decision path locks a single case row by id and never
waits on a second lock, so it cannot form a cycle with the producer's
multi-row `lock_by_fingerprint`. `Allocate.lock_case` later in the same
transaction re-locks the already-held case row (reentrant, no new wait). The
`change filter` preconditions stay as in-memory defense-in-depth (and the
sequential early-out), but are no longer described as the fence.

### `lib/jido_claw/orchestration/agent_case.ex` (docs only)

Correct the two false claims so they match the honest `:consume` comment
(`agent_case.ex:209`) and the new fence:

- `## Concurrency fence` moduledoc (`agent_case.ex:19-28`): the real fence is
  the `FOR UPDATE` reload-and-recheck in `Cases`; `change filter` is an
  in-memory precondition (not a DB `WHERE` for record updates in
  ash_postgres 2.9), which still rejects a *freshly-loaded* non-pending struct
  (sequential duplicate) but the `FOR UPDATE` reload is what closes the
  concurrent stale-load race.
- `:approve` comment (`agent_case.ex:151`): same correction.
- Light alignment of the `:abandon` ("re-read fresh under the run lock") and
  `:reopen` ("lock-fenced in `commit_retract`") comments.

### Doc-honesty sweep (every restatement of the false invariant)

This bug originated in a false *local* invariant, so be ruthless: after the
edits, run

```
rg "DB-fenced|DB-side|pending-only fence|change filter|stale-record|status == :pending" lib/ test/
```

and audit **every** hit. Remove or correct any prose that implies an Ash
`change filter` is *the database fence* for record updates; the only true
fences are the `FOR UPDATE` reloads. Known hits to resolve (non-exhaustive —
re-run the sweep until clean): the false claims at `agent_case.ex:23` and
`:151`; the already-correct `:consume`/`:consume_rejection` comments
(`agent_case.ex:209-231` — leave, they're the model); the `cases.ex` moduledoc
+ `commit_*` comments; and the test comment strings. **Do not** touch
legitimate matches: the `change filter(expr(status == :pending))` action lines
themselves (kept as in-memory preconditions) and the `status == :pending`
*read*-action filters (`pending_for_run`/`pending_for_tenant`/
`pending_for_session` — ordinary `WHERE`s, not concurrency claims). The pass is
clean when no surviving comment/moduledoc says or implies `change filter`
enforces the decision race in the database.

## Tests

The Ecto sandbox runs these `async: false` cases on one shared connection, so
true `FOR UPDATE` *blocking* isn't reproducible in-sandbox; the convention here
(`tool_approvals_test.exs:144-177`) is `Task.async` + `Task.await_many` with an
**outcome invariant**. The existing "duplicate/concurrent" tests
(`human_gates_test.exs:380`, `cases_tool_call_test.exs:60`) only exercise
*sequential* reloads (each `Cases.decide` reloads fresh, so the second refuses
at the pre-transaction guard) — they do not race two stale-loaded deciders.

Add genuinely concurrent decision tests asserting: exactly one
`{:ok}` + one `{:error}`, the persisted row reflects the **winner**, and
exactly **one** decision event was appended (never `[:opened, :approved,
:rejected]`). Without the fix the loser overwrites → two `{:ok}` and a double
decision event; with it, the loser rolls back.

- **`test/jido_claw/orchestration/cases_tool_call_test.exs`** (run-less,
  primary/cheap): race `:approve` vs `:reject` on one pending tool-call case.
  Wrap in a loop (~10-20 fresh cases) so the stale-load interleaving is
  reliably exercised (the pre-transaction reload can otherwise mask a single
  race). Assert the invariant + `event_types == [:opened, <winner>]`.
- **`test/jido_claw/orchestration/human_gates_test.exs`** (workflow): race
  `:approve` (with `resume: false`, to isolate the fence from `GateResume`) vs
  `:reject` on a gated run's pending case; loop a handful of times. Assert the
  invariant on the `AgentCase` plus exactly one new decision `WorkflowEvent`
  (`approval_resolved` XOR `run_cancelled`). This also exercises the run→case
  lock-order path under the run lock.
- Refresh the two stale "pending-only fence" comment strings in the existing
  sequential tests to reference the `FOR UPDATE` reload fence.

### These race tests are suspect until *proven* load-bearing

A flaky race test is worse than none — it gives false comfort. So the test is
not done until it is **proven to fail without the fix**:

1. **Revert-and-confirm, repeated.** Temporarily revert the `lock_case` reload
   in `commit_tool_call_decision` and run the run-less concurrency test **≥10
   times** (`mix test … --seed N` across seeds, or a shell loop). It must fail
   on (near) every run — two `{:ok}` and/or a `[:opened, :approved, :rejected]`
   timeline. The mechanism that makes this reliable: `decide`'s pre-transaction
   `load` is its *first* DB op, and a transaction holds the single shared
   sandbox connection until commit, so the race window is entirely
   pre-transaction; both tasks' loads almost always land before either
   transaction begins, and a 10-20 iteration loop makes hitting the stale-load
   interleaving at least once a near-certainty. Restore the fix and confirm
   green.
2. **If it does *not* fail reliably**, the outcome-invariant test is
   insufficient — escalate to a **deterministic harness**: add a minimal,
   prod-safe synchronization seam in `Cases.decide` (an optional barrier mfa
   read from `Application.get_env(:jido_claw, :decide_test_barrier, nil)`,
   invoked between the pre-transaction `load` and the commit transaction;
   `nil`/absent in prod, so zero runtime effect). The test sets a barrier that
   releases only once **both** deciders have loaded, forcing the stale-load
   interleaving deterministically. Prefer (1); only add the seam if (1) proves
   unreliable, and document it as test-only.

## Verification

1. `mix test test/jido_claw/orchestration/cases_tool_call_test.exs test/jido_claw/orchestration/human_gates_test.exs test/jido_claw/orchestration/tool_approvals_test.exs` — new concurrency tests pass; existing sequential tests still pass (they assert `{:error, _}` with a wildcard, so the changed error reason — now `:not_pending` — is compatible).
2. **Prove the race tests are load-bearing** (gate, per Tests § above): revert `lock_case` and run the run-less concurrency test **≥10×**; it must fail on (near) every run, else add the deterministic barrier seam. Restore and confirm green.
3. **Doc-honesty sweep is clean**: re-run the `rg` from the sweep section and confirm no surviving prose implies `change filter` is the DB decision fence.
4. **`mix precommit`** (the completion criterion): `jidoclaw.compile_check`,
   `jidoclaw.system_prompt.check`, `deps.unlock --unused`,
   `format --check-formatted`, `reach.check --arch --smells --strict` (zero —
   no new cross-layer deps; all changes stay within `Orchestration.*`),
   `credo --strict` (zero), `dialyzer --format short`, full `test`. Fix
   anything surfaced. Per the original request, all changes stay **unstaged**.

## Post-approval housekeeping

Save two feedback memories (both generalizable beyond this task):

1. **Prove race tests fail without the fix.** A flaky concurrency test is worse
   than none — it gives false comfort. Gate every race test by reverting the
   fix and confirming it fails *reliably* (repeated runs); if it doesn't,
   escalate to a deterministic harness / test-only synchronization seam rather
   than shipping a probabilistic one.
2. **A false local invariant demands a codebase-wide sweep.** When a bug stems
   from an incorrect invariant stated in a comment/moduledoc (here: "Ash
   `change filter` is the DB fence for record updates"), don't just fix the one
   that caused it — `rg` for every restatement and correct them all, while
   leaving the legitimate uses (preconditions, read filters) intact.

## Out of scope

No other blocking issues were found in the producer/policy/wrapper path. The
`change filter` preconditions are retained (not removed) as in-memory
defense-in-depth and the sequential early-out. A non-Postgres bulk-update CAS
alternative is rejected in favor of the house `FOR UPDATE` idiom already used
by `lock_run`, `Allocate.lock_case`, and `ToolApprovals`.
