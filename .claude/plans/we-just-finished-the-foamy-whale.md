# WS3 P1 follow-up — claim-aware stamp-error fail-close (+ reclaim re-arm)

## Context

WS3 (reclaim & recovery) is shipped. A post-ship code review flagged a **[P1]** on the
single-node lease-degrade path; two further reviews of *this plan* corrected the fix direction
and then closed a residual. I traced every referenced path (direct reads + an Explore sweep of
boot-recovery, gate-park, composer-parent, finalize, and fences A/B). **The finding is valid;
the converged fix is fail-closed for re-stamps, plus a reclaim re-arm so the always-on Pooler
(not just boot) recovers it.**

**The bug.** `WorkflowLease.Middleware.init/1` claims a run's lease by CAS-stamping the prior
token. On a `{:error, _}` from `WorkflowLease.stamp/4` it calls `fail_or_degrade/2`
(`middleware.ex:82-92`), which **single-node proceeds DEGRADED** (runs unleased) on the
moduledoc assumption *"nothing was stamped, so there are no claim columns to lapse."*

That holds **only for a genesis run** (`run.claim_token == nil`). `GateResume.resume/2`
re-establishes this middleware (via `normalize_middleware`, `gate_resume.ex:182`) with a **fresh**
token put into *both* the reactor context and `finalize_opts` (`gate_resume.ex:158,169`) on a run
that **already** carries a prior `claim_token` + `claim_expires_at`. Two callers reach it, both
active single-node (where the degrade runs):

- **Boot recovery** — `workflow_recovery.ex:604` `GateResume.resume(recovered: true)` for a
  `:running` + checkpoint + `approval_resolved` run; the row carries a non-NULL, already-expired
  `claim_expires_at`. `owns_recovery?` gates boot recovery to non-clustered/non-MCP = single-node.
- **Operator approve** — `cases.ex:570`. Gate-park writes **no** lease column (projection-ownership
  invariant keeps `status` and `claim_*` disjoint), so a parked-then-approved run carries a non-NULL
  (post-park, usually expired) `claim_expires_at` once `approval_resolved` flips it back to `:running`.

On a transient stamp `{:error, _}` there, the old `fail_or_degrade` degrades single-node, leaving
the row `:running` + stale expiry + **prior** token while the live resumed executor holds the
**fresh** token. Two harms: (1) the stale expiry lapses → the **always-on** `ReclaimPooler`
(`enabled?: true` even single-node, `config/config.exs:264`) reclaims a *live* executor; (2) the
fresh-vs-prior disagreement makes fences A/B reject that live executor's own `run_completed`/
`run_failed` (`allocate.ex:160`, `reactor_runner.ex:657`), so it can never finalize.

**Why fail-closed (not "suspend the prior token").** The first plan draft suspended the prior
claim — but that keeps the prior token in the row while the resume holds a fresh one, so fences
A/B would still strand the live executor. The correct move is to **not run an executor at all**:
fail closed (`{:error, {:lease_claim, reason}}`, both modes). That `{:error, _}` flows to
`ReactorRunner.finalize/3`'s generic clause (`:718-734`), whose `fenced?/2` sees
`reloaded.claim_token (prior) != held (fresh)` → `{:error, :fenced, reloaded}` with **NO terminal**
→ the run stays `:running`, to be re-resumed from the checkpoint by reclaim/boot.

**Why the re-arm (the second-reviewer residual).** "Left for reclaim" only holds when the prior
`claim_expires_at` is non-NULL. A prior token can carry `claim_expires_at = NULL`, left by an
earlier single-node **sidecar-degrade** (`suspend_claim`, `workflow_lease.ex:91`). The `:claimable`
predicate (`workflow_run.ex:258`) requires `not is_nil(claim_expires_at)`, so a `{prior, NULL,
:running}` row is **Pooler-unreclaimable — boot-recovery-only**. So before failing closed, the
non-genesis branch **re-arms** the prior claim's expiry (token-fenced, best-effort, `now() +
reclaim_cooldown`) so the always-on Pooler reclaims it on the next poll. The cooldown (not `now()`)
is load-bearing: this fail-close can itself run **inside** a Pooler `reclaim → GateResume` drain,
so a `now()` re-arm would hot-loop — exactly why `WorkflowRecovery.release_on_defer/1` uses a
cooldown.

**Not affected: the composer parent.** It stamps only at genesis (`claim_genesis/2`,
`route_composer.ex:411`; whole `Ash.transact` rolls back) and re-**renews** (not re-stamps) on
resume (`lease_preflight_and_resume/3`, `:1174`); its sidecar-degrade already re-arms via `renew`.
**No composer change** (the reviewer confirmed this exclusion).

**Intended outcome.** A single-node re-stamp can never proceed degraded; genesis still degrades
byte-identically; a re-stamp fails closed *and* is left Pooler-reclaimable (no boot-only residual).
`mix precommit` green.

## The fix

### 1. `lib/jido_claw/orchestration/workflow_lease.ex` — single-source the reclaim re-arm

Move the cooldown + best-effort re-arm here (the module that owns `release_with_cooldown/3`), so
the middleware and `WorkflowRecovery` share one implementation (no clone-gate duplication):

```elixir
@spec reclaim_cooldown_seconds() :: pos_integer()
def reclaim_cooldown_seconds do
  ms = Application.get_env(:jido_claw, :reclaim_pooler, [])[:poll_interval_ms] || 15_000
  max(div(ms, 1000), 1)
end

# Best-effort token-fenced re-arm: push `token`'s expiry to now()+cooldown so the always-on
# Pooler re-claims this held-token row on the NEXT poll (never the same drain → anti-hot-loop).
# Swallows {:ok, 0}/{:error, _} (the claim_next lease window still bounds re-claim).
@spec release_for_reclaim(String.t(), String.t()) :: :ok
def release_for_reclaim(run_id, token) do
  case release_with_cooldown(run_id, token, reclaim_cooldown_seconds()) do
    {:ok, _rows} -> :ok
    {:error, reason} ->
      Logger.warning("[WorkflowLease] reclaim re-arm failed for #{run_id}: #{inspect(reason)}")
      :ok
  end
end
```
(Add `require Logger`.)

### 2. `lib/jido_claw/orchestration/workflow_recovery.ex` — use the shared helper

`release_on_defer/1`'s binary-token clause → `WorkflowLease.release_for_reclaim(run.id, token)`;
**delete** WR's private `reclaim_cooldown_seconds/0` and its inline `case`. Keep the nil-token
clause; update the comment to point at the shared helper. (Contract unchanged — no caller ripple.)

### 3. `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — claim-aware stamp-error path

```elixir
{:error, reason} ->
  stamp_error_degrade(id, run.claim_token, {:lease_claim, reason}, ctx)
```
```elixir
# Genesis (nil prior): nothing was ever stamped — no claim columns, no fresh-vs-prior token
# disagreement — so a single-node degrade is byte-identical to the pre-lease world. Cluster
# still fails closed (unchanged).
defp stamp_error_degrade(_id, nil, reason, ctx) do
  if cluster_enabled?() do
    {:error, reason}
  else
    Logger.warning("[WorkflowLease] degraded (single-node, genesis), running unleased: #{inspect(reason)}")
    {:ok, ctx}
  end
end

# Already-claimed (binary prior — a GateResume/recovery re-stamp): the failed CAS did NOT rotate,
# so the row still holds the PRIOR token while this resume holds a FRESH one. Proceeding degraded
# would strand a live executor behind fences A/B. FAIL CLOSED in both modes — no executor runs,
# and finalize's fence A (prior != fresh) leaves the run :running with NO terminal. Re-arm the
# prior claim first so a NULL-expiry (sidecar-degrade) residual is Pooler-reclaimable, not boot-only.
defp stamp_error_degrade(id, prior, reason, _ctx) when is_binary(prior) do
  WorkflowLease.release_for_reclaim(id, prior)
  {:error, reason}
end
```
- **Remove** `fail_or_degrade/2` (else an unused-function warning fails `compile_check`).
- **Leave `suspend_or_fail_closed/4` UNCHANGED** — it is the SIDECAR-failure path (row holds the
  *fresh* token; suspend-on-fresh is correct). No longer reused by the stamp-error path.
- **Add the test seam** for `stamp/4` only:
  `defp lease_module, do: Application.get_env(:jido_claw, :workflow_lease_module, WorkflowLease)`,
  call site `lease_module().stamp(id, token, run.claim_token, tenant: tid)`. Forcing a *real* stamp
  `{:error, _}` needs a Postgrex error, which would poison the shared sandbox transaction; no Mox in
  the project. No config sets `:workflow_lease_module` (verified) → prod resolves to `WorkflowLease`.
  (Reviewer OK'd the app-env seam for this `async: false` suite, provided exact delete-vs-put restore.)

### 4. `lib/jido_claw/orchestration/reactor_runner.ex` — fix the now-stale comment

Update the `{:lease_claim, _}` comment (`:698-701`), which says it "DOES own the lease … fails the
run it owns." Post-fix that is true only when the row's token == the held token (sidecar-fail, or a
genesis cluster stamp-error where the row was never stamped); a **re-stamp** `{:lease_claim, _}`
leaves the row on the PRIOR token ≠ the fresh held token → `fenced?` true → NO terminal, left
`:running` for reclaim/boot. Comment-only.

## Tests

`test/support/jido_claw/orchestration/lease_helpers.ex`:
- `with_forced_stamp_error/1` — sets `:workflow_lease_module` to the stub around `fun`, `try/after`,
  restoring via `Application.fetch_env/2` (`{:ok, v}` → `put_env`, `:error` → `delete_env` — exact
  restore, reviewer's requirement). Models `with_cluster_enabled/2`.
- `JidoClaw.Orchestration.LeaseHelpers.ForcedStampErrorLease` — stub whose `stamp/4` returns
  `{:error, :forced}` (no DB touch).

`test/jido_claw/orchestration/workflow_lease_test.exs` — a `describe "stamp-error fail-close
(claim-aware)"` block (each `@tag :capture_log`, driving `LeaseMiddleware.init/1` directly like
test #12):
1. **Genesis, single-node** → `{:ok, ctx_in}`; row still nil token/expiry (byte-identical).
2. **Genesis, cluster** → `{:error, {:lease_claim, :forced}}`; row token still nil.
3. **Already-claimed + NULL prior expiry (the headline / residual case)** — seed `:running` + prior
   token, then `WorkflowLease.suspend_claim(id, prior)` → `{prior, NULL}` (the sidecar-degrade shape).
   Forced stamp error, cluster off ⇒ `{:error, {:lease_claim, :forced}}` (no degrade), token still
   `prior`, **expiry now NON-NULL** (re-arm closed the residual). Then backdate the re-armed expiry
   (`set_claim!(id, prior, -1)`) and assert `WorkflowLease.claim_next/0` returns the run — the
   reviewer's explicit "claim_next can claim it after the stamp-error path."
4. **Already-claimed, cluster** → `{:error, {:lease_claim, :forced}}` (mode-independent re-stamp branch).
5. **Finalize no-terminal proof** — `ReactorRunner.finalize({:error, {:lease_claim, :forced}},
   running_run_with_prior_token, [claim_token: fresh, …])` ⇒ `{:error, :fenced, %{status: :running}}`,
   and `refute :run_failed in kinds(...)` (mirrors the fence-A `finalize` tests #18). Proves
   fail-closed is non-lossy / re-resumable.
6. **`release_for_reclaim/2` unit** — on a held token → `:ok` + expiry ≈ now()+cooldown; on a rotated
   token → `:ok` with 0 rows (token-fenced, no change). Plus `reclaim_cooldown_seconds/0` floors at 1s.

## Doc reconciliation

- **`middleware.ex` moduledoc** "Degraded vs fail-closed" — three shapes: genesis stamp-error
  (degrade single-node / fail cluster); already-claimed stamp-error (fail closed both modes, re-arm
  for reclaim, fence A leaves it `:running`); sidecar failure (unchanged `suspend_or_fail_closed/4`).
  Update the inline comment replacing `fail_or_degrade/2`.
- **`docs/plans/clustering/WS3-reclaim-and-recovery.md`** — extend "Post-ship review (P1/P2 fixes)"
  (`:13-24`): a re-stamp now fails closed + re-arms (Pooler-reclaimable, not boot-only); only genesis
  degrades; composer needs no analogue.
- **`docs/plans/clustering/WS1-lease-core.md:210`** — `fail_or_degrade/2` → `stamp_error_degrade/4`,
  qualify "byte-identical **only for a genesis stamp error**; a re-stamp fails closed + re-arms."

## Files

- `lib/jido_claw/orchestration/workflow_lease.ex` — `reclaim_cooldown_seconds/0` + `release_for_reclaim/2` (+ `require Logger`).
- `lib/jido_claw/orchestration/workflow_recovery.ex` — use the shared helper; delete the private cooldown.
- `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — claim-aware fix + seam + doc/comments (`suspend_or_fail_closed/4` untouched).
- `lib/jido_claw/orchestration/reactor_runner.ex` — comment-only correction.
- `test/support/jido_claw/orchestration/lease_helpers.ex` — `with_forced_stamp_error/1` + stub.
- `test/jido_claw/orchestration/workflow_lease_test.exs` — new describe block (6 tests).
- `docs/plans/clustering/WS3-reclaim-and-recovery.md`, `docs/plans/clustering/WS1-lease-core.md` — doc reconciliation.

## Considered & rejected

- **Document the NULL-expiry residual as boot-recovery-only** (the reviewer's simpler option):
  drop the re-arm, just `{:error, reason}`, and test that `{prior, NULL}` stays boot-only. Simpler,
  but reintroduces a stranded-until-reboot gap — exactly the class WS3 exists to close — so we take
  the reviewer's "better" path and re-arm (reusing the existing `release_with_cooldown` precedent).
- **Adopt-and-degrade primitive** (CAS prior→fresh + NULL expiry so the resume completes
  immediately): correct but a new primitive to save only the bounded re-resume latency that
  re-arm + reclaim already covers.

## Verification

- `mix test test/jido_claw/orchestration/workflow_lease_test.exs` — new block green; existing
  sidecar/degrade/fence tests still green.
- `mix test test/jido_claw/orchestration/{reclaim_pooler_test.exs,workflow_recovery_test.exs} test/jido_claw/route_composer/composer_durable_test.exs` —
  the reclaim/recovery/composer suites (recovery touched by the shared-helper migration) still green.
- **`mix precommit`** — the bar for "done": clean `compile_check` (no unused `fail_or_degrade/2`;
  `_id`/`_ctx` underscored), `format`, `credo`/`reach` strict at zero (single-sourced re-arm = no
  clone; one non-clone get_env seam; trivial stub in test/support), dialyzer (dynamic
  `lease_module().stamp` is permissive), full suite.
