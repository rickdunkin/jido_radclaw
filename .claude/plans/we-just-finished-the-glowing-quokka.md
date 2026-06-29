# WS3 reclaim/recovery — code-review fixes

## Context

WS3 (`docs/plans/clustering/WS3-reclaim-and-recovery.md`, "shipped") made the
`ReclaimPooler` **always-on in every serve mode and both single-/multi-node**. A
post-ship review found two correctness issues that the always-on pooler exposes,
plus one `.reach.exs` quality note. Both findings are **verified**; this plan
resolves them, incorporating reviewer follow-ups (fail-closed on a lost suspend;
strict ownership identity). Definition of done: **`mix precommit` succeeds**
(compile_check zero-warnings, format, `reach.check --arch --smells --strict`,
credo `--strict`, dialyzer, full test suite).

---

## Finding P1 — single-node "degrade without heartbeat" is reclaimable while live (VERIFIED)

**The bug.** Two paths stamp a lease, fail to arm the heartbeat sidecar, and in
single-node mode proceed *without* a sidecar while leaving `claim_expires_at`
stamped:

- `lib/jido_claw/orchestration/workflow_lease/middleware.ex:44-50,68-78` —
  `stamp/4` succeeds (`{:ok, :claimed}`, sets `claim_expires_at = now()+60s`),
  `start_sidecar/4` fails, `fail_or_degrade/2` returns `{:ok, ctx}`.
- `lib/jido_claw/route_composer/route_composer.ex:1110,1135-1161` — preflight
  `renew/2` bumps `claim_expires_at`, `start_sidecar/4` fails,
  `sidecar_fail_or_degrade/3` calls `resume_or_tick` keeping the token.

Once that stamped lease lapses (~60s), the `:claimable` selector
(`workflow_run.ex:256-263`, clause 1: `status in [:pending,:running] AND
claim_expires_at IS NOT NULL AND claim_expires_at < now()`) matches it, and the
always-on `ReclaimPooler` (`reclaim_pooler.ex:99-110`, `application.ex:170`)
reclaims/fails a **live** execution.

**Confirmed facts that shape the fix:**
- No existing lease primitive NULLs the claim columns. `release_with_cooldown/3`
  sets a *shorter* expiry (still reclaimable), not NULL.
- Terminal-append fence tokens are **context-captured**, not DB re-reads
  (`reactor_middleware.ex:420`, `reactor_runner.ex:895`,
  `route_composer.ex:1751,3092`); fence A/B short-circuit to "not fenced" when
  the row token equals or either side is nil — so keeping the DB token while
  NULLing only the expiry leaves terminals passing.
- A composer is `restart: :transient`; if we NULLed the *token*, a
  crash-restart's frozen-token preflight `renew` would return `{:ok, 0}` →
  `{:stop, :normal}` and permanently halt it. **Keep the token**, NULL only the
  expiry.

### Fix P1a: `suspend_claim/2` + `degrade_gate/2` (NULL the expiry, keep the token, gate on success)

New in `lib/jido_claw/orchestration/workflow_lease.ex` (beside `@renew_sql` /
`renew_for/3`):

```elixir
@suspend_claim_sql """
UPDATE workflow_runs
   SET claim_expires_at = NULL
 WHERE id = $1 AND claim_token = $2
"""

@doc """
Suspend a held lease's expiry: NULL `run_id`'s `claim_expires_at` iff its current
token is `token`, KEEPING `claimed_by`/`claim_token`. `{:ok, 1}` suspended,
`{:ok, 0}` fenced/rotated (a reclaimer already took it), `{:error, term()}`.
"""
@spec suspend_claim(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
def suspend_claim(run_id, token) do
  params = [Ecto.UUID.dump!(run_id), Ecto.UUID.dump!(token)]

  case Repo.query(@suspend_claim_sql, params) do
    {:ok, %{num_rows: rows}} -> {:ok, rows}
    {:error, reason} -> {:error, reason}
  end
end

@doc """
Single-node degrade gate — single-sourced so the reactor middleware and the
route-composer parent cannot diverge. Suspends the held claim and reports whether
the caller may proceed degraded: `:degrade` **iff the suspend took** (`{:ok, 1}`);
`:fail_closed` on a lost/failed suspend (`{:ok, 0}` / `{:error, _}`), where the
unsafe stamped-but-unrenewed state persists so the caller MUST abort/stop and
leave the row for reclaim/boot. Returns a decision (never fire-and-forget) so a
caller cannot ignore a failed suspend and keep running.
"""
@spec degrade_gate(String.t(), String.t()) :: :degrade | :fail_closed
def degrade_gate(run_id, token) do
  case suspend_claim(run_id, token) do
    {:ok, 1} -> :degrade
    _ -> :fail_closed
  end
end
```

(NULL expiry ⇒ `:claimable` clause 1 needs `not is_nil(claim_expires_at)` → no
match; clause 2 needs `:pending` → run is `:running` → no match. Not reclaimable.
CAS on the held token ⇒ `{:ok, 0}` if a reclaimer already rotated it.)

### Fix P1b: middleware — gate the proceed on `:degrade`, else fail closed

In `workflow_lease/middleware.ex`, the sidecar-failure branch (only reached after
`stamp` succeeded, so there IS a claim to suspend) routes through a new
`suspend_or_fail_closed/4`; the `{:lease_claim, _}` branch (stamp failed, nothing
stamped) keeps the existing `fail_or_degrade/2` unchanged:

```elixir
case WorkflowLease.start_sidecar(self(), id, tid, token) do
  :ok -> {:ok, ctx}
  {:error, reason} -> suspend_or_fail_closed(id, token, {:lease_sidecar, reason}, ctx)
end
# ...{:error, reason} -> fail_or_degrade({:lease_claim, reason}, ctx)   # unchanged

# Cluster: do NOT suspend — fail closed ({:error, _} aborts the run; the runner's
# finalize handles the terminal). Single-node: degrade_gate suspends + decides —
# proceed unleased only when the suspend took, else fail closed (the live,
# sidecar-less, still-stamped run must not be left reclaimable).
defp suspend_or_fail_closed(id, token, reason, ctx) do
  if cluster_enabled?() do
    {:error, reason}
  else
    case WorkflowLease.degrade_gate(id, token) do
      :degrade -> Logger.warning("[WorkflowLease] degraded (single-node), suspended claim + running unleased: #{inspect(reason)}"); {:ok, ctx}
      :fail_closed -> Logger.error("[WorkflowLease] sidecar failed + claim suspend lost/failed (#{inspect(reason)}); failing closed"); {:error, reason}
    end
  end
end
```

### Fix P1c: route_composer — `:degrade` resumes, `:fail_closed` stops

`route_composer.ex` `sidecar_fail_or_degrade/3` (~1145-1161). Cluster branch
unchanged (`{:stop, :normal, state}`, no suspend). Single-node branch routes
through `degrade_gate`; **keep `state.claim_token`** either way:

```elixir
defp sidecar_fail_or_degrade(state, events, reason) do
  if cluster_enabled?() do
    Logger.error("[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} (#{inspect(reason)}); stopping under clustering — parent left :running + claimed for reclaim")
    {:stop, :normal, state}
  else
    case WorkflowLease.degrade_gate(state.parent_run_id, state.claim_token) do
      :degrade ->
        Logger.warning("[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} (#{inspect(reason)}); degraded (single-node), suspended claim + proceeding with no heartbeat")
        resume_or_tick(state, events)

      :fail_closed ->
        Logger.error("[RouteComposer] parent lease sidecar failed for #{state.parent_run_id} (#{inspect(reason)}); claim suspend lost/failed — stopping (parent left :running + claimed for reclaim/boot)")
        {:stop, :normal, state}
    end
  end
end
```

Stopping on `:fail_closed` is safe: no live executor remains, so the later pooler
reclaim of the still-stamped row is a legitimate dead-owner reclaim (the P1 hazard
was a *live* executor being reclaimed).

**Comment sweep (false-invariant).** Update the now-false claims and `rg` for
restatements: `route_composer.ex:1125-1131` ("nothing reclaims an expired
single-node lease"), `middleware.ex` moduledoc (~20-29) and `:66-67` ("the WS3
reclaim loop is the net"), and a one-line note in
`docs/plans/clustering/WS3-reclaim-and-recovery.md`. Single-node degrade now means
**suspended claim (NULL expiry, token kept) ⇒ unreclaimable + boot-recovery-only**;
a lost suspend ⇒ **fail closed** (abort/stop), the row left for reclaim/boot.

---

## Finding P2 — composer reclaim swallowed by a stale local composer (VERIFIED)

**The bug.** On live reclaim, `claim_next/1` rotates the parent token, then
`WorkflowRecovery.reclaim/1 → reclaim_composer/1 → start_recovered_composer/3`
(`workflow_recovery.ex:573`) calls `RouteComposer.ensure_started/2`. Its hit-branch
(`route_composer.ex:635-637`) returns an already-registered pid **without checking
its token**. A stale local composer holding the *old* token is returned as-is; the
rotated token never reaches a live process, and recovery emits `:composer` success.
Recovery stalls until the next lease expiry — or, with a sidecar-less stale owner,
forever (the P1 fix removes that sub-case: a degraded composer is suspended/
unreclaimable, so reclaim never targets it; P2 closes the sidecar-bearing case).

**Confirmed facts:**
- Two production callers: `FrontDoor.guarded_launch/2` (fresh `parent.id` ⇒ always
  miss-branch) and `WorkflowRecovery.start_recovered_composer/3` (boot: same
  durable/nil token; reclaim: rotated token — the bug path). A universal hit-branch
  check is safe.
- No `handle_call` exists today; the token lives at `state.claim_token`
  (`route_composer.ex:970`). In-repo precedent: `VFS.Workspace.ensure_started/2`
  (`vfs/workspace.ex:55-90,158-169`) — find → `GenServer.call` for identity → on
  drift, teardown + start_fresh, with `try/catch :exit` for a stale/dead pid.
- Supervisor `JidoClaw.RouteComposer.Supervisor` (`@supervisor`); registry
  `@registry` (`keys: :unique`). The key frees **asynchronously** after
  `terminate_child/2`; `start_supervised_composer/2`'s `{:already_started, pid}`
  collapse can return a *dead* pid if we restart before the key clears — so wait
  (precedent: test `await_deregistered/2`, `composer_durable_test.exs:1271-1283`).

### Fix P2: token-validating `ensure_started/2` with **strict** ownership identity

Add the first `handle_call` to RouteComposer (near `init`/`handle_continue`):

```elixir
@impl GenServer
def handle_call(:get_claim_token, _from, state), do: {:reply, state.claim_token, state}
```

Add `@owner_call_timeout 5_000` and restructure `ensure_started/2`
(`route_composer.ex:633-645`). **Ownership uses exact equality `held == incoming`,
NOT the nil-permissive fence helper `token_mismatch?/2`** — a binary reclaim token
against a `nil`/old held token must NOT count as the current owner (that is the
swallowed-reclaim bug). Only `nil` incoming matches a `nil` held owner (unleased
idempotency); a binary incoming requires the live owner to return that exact binary:

```elixir
def ensure_started(opts, %WorkflowRun{} = parent) do
  case Registry.lookup(@registry, parent.id) do
    [{pid, _value}] -> ensure_current_owner(pid, opts, parent)
    [] -> start_or_terminalize(opts, parent)
  end
end

# A registered composer is the current owner ONLY if it still holds the run's
# (possibly just-reclaimed) token, by exact identity. A stale owner — left when
# `claim_next` rotated the parent token (P2) — or a dead/stale registry entry
# (call exits) is evicted and restarted so the reclaimed token reaches a live
# process. Launch (miss) and boot/unleased (nil==nil) are no-ops.
defp ensure_current_owner(pid, opts, parent) do
  if current_owner?(pid, parent.claim_token) do
    {:ok, pid}
  else
    _ = DynamicSupervisor.terminate_child(@supervisor, pid)
    await_deregistered(parent.id)
    start_or_terminalize(opts, parent)
  end
end

defp current_owner?(pid, incoming_token) do
  try do
    GenServer.call(pid, :get_claim_token, @owner_call_timeout) == incoming_token
  catch
    :exit, _ -> false
  end
end

defp start_or_terminalize(opts, parent) do
  case start_supervised_composer(build_start_opts(opts, parent), parent.id) do
    {:ok, pid} -> {:ok, pid}
    {:error, reason} = error -> maybe_terminalize_orphan(opts, parent, reason, error)
  end
end

# Registry frees the via-tuple key async after terminate_child; wait (bounded)
# before restarting so the already-started collapse can't hand back the dead pid.
defp await_deregistered(parent_id, tries \\ 200) do
  cond do
    Registry.lookup(@registry, parent_id) == [] -> :ok
    tries > 0 -> Process.sleep(10); await_deregistered(parent_id, tries - 1)
    true -> :ok
  end
end
```

The new composer freezes `parent.claim_token`, preflight `renew` returns
`{:ok, 1}`, arms a sidecar, and resumes mid-route. The evict path reuses
`maybe_terminalize_orphan/4`, preserving recovery's "leave `:running` for the next
sweep" (H19) on restart failure. `terminate_child` is synchronous (old pid dead on
return), so callers see the new pid immediately. (`token_mismatch?/2` is left
untouched for its existing fence uses — it is the wrong tool for ownership.)

---

## Note — `.reach.exs` production-ignore expansion (quality, reviewer "judgment call")

The change added **three** modules to `fixed_shape_map → ignore`
(`.reach.exs:111-117`) for the `ComposerArtifact.store_pending` 7-key attrs shape
— two **production** modules plus the new test helper. The only *new* occurrence
is the test helper (`fixtures.ex:873-889`, inline map). reach's `fixed_shape_map`
threshold is **3** (default); it scans `lib/**` + `test/support/**` only.

**Clean fix:** route the fixture through the existing production builder
`ComposerArtifact.store_wave_artifact/6` ("the single construction site for the
wave-artifact create-attrs shape"), which builds the identical map and returns the
ref the fixture needs:

```elixir
# commit_wave0/3 in fixtures.ex — replace the inline store_pending(%{...}) with:
{:ok, plan_ref} =
  ComposerArtifact.store_wave_artifact(
    "plan", "planner", "PLAN: build the auth feature", child, 0,
    tenant: ctx.tenant, actor: ctx.actor
  )
```

`child.parent_run_id == parent.id`, so semantics are identical. Then **revert the
entire `.reach.exs` hunk** (all three ignores) — occurrences drop 3→2, below
threshold, green with no ignores. Remove the now-orphaned `defp generate_ref`
**after** `rg generate_ref test/support/.../fixtures.ex` confirms no other caller
(else removal leaves an undefined ref / keeping it leaves an unused-fn warning —
either fails compile_check). (Keeping only the test-helper ignore is unreliable:
fixed_shape findings anchor on an order-dependent module that "drifts between runs.")

---

## Tests

All suites: `use JidoClaw.TenantCase, async: false`. Seed/drive with
`test/support/jido_claw/orchestration/lease_helpers.ex` (`seed_run/2`,
`set_claim!/3` negative seconds = expired, `rotate_token!/2`, `reload_global/1`,
`with_cluster_enabled/2`) and the composer fixtures. Each test must **fail without
the fix**.

**P1 — primitive + the "proceed only when suspend succeeds" guard**
(`workflow_lease_test.exs`):
- `suspend_claim/2` column semantics: stamp (future expiry) → `{:ok, 1}`, reload
  shows `claim_expires_at IS NULL` and `claim_token`/`claimed_by` retained; not
  selected by `claim_next()`/`reclaim_once()`. Rotate-then-suspend on the old token
  → `{:ok, 0}`, expiry untouched.
- **`degrade_gate/2` decision (the reviewer's assertion):** matching-token →
  `:degrade` **and** the row's expiry is now NULL; rotated-token (suspend `{:ok, 0}`)
  → **`:fail_closed`** and the row is unchanged. This guards "degrade proceeds only
  when suspend succeeds" at the single-sourced gate both call sites branch on — a
  future change that ignores a lost suspend cannot return `:degrade`.

**P1 — call-site wiring** (middleware + composer):
- Middleware happy degrade: force `start_sidecar/4` to fail deterministically by
  pre-registering the run's key in `JidoClaw.Orchestration.LeaseRegistry` from the
  test process; `Middleware.init/1` single-node → `{:ok, ctx}` and row
  `claim_expires_at IS NULL`. `with_cluster_enabled(true, …)` →
  `{:error, {:lease_sidecar, _}}`, row left stamped.
- Composer happy degrade: same LeaseRegistry pre-registration on `parent_run_id`,
  start a composer via the fixtures single-node → parent `claim_expires_at IS NULL`,
  token retained, composer still progresses.
- **Composer fail-closed (no test-only visibility):** the `:fail_closed` *decision*
  is already pinned by the `degrade_gate/2` unit test above, and the composer
  consumes it via a visible `case … :fail_closed -> {:stop, :normal, state}`. Do
  **not** expose the private `sidecar_fail_or_degrade/3` to test it — and a
  deterministic `:fail_closed` can't be driven through the public startup path
  (a token mismatch trips the preflight `renew` `{:ok, 0}` → `{:stop, :normal}`
  *before* the sidecar is reached). The composer integration case above exercises
  the `:degrade` happy path through public startup; that plus the gate unit test
  is the coverage.

**P2** (`composer_durable_test.exs` units; `reclaim_pooler_test.exs` end-to-end):
- Evict stale-token owner: start composer with token A (capture `old_pid`), rotate
  DB token to B + reload, `ensure_started(opts, run_B)` → `{:ok, new_pid}`,
  `new_pid != old_pid`, `refute Process.alive?(old_pid)`, registry maps
  `parent.id → new_pid`, `GenServer.call(new_pid, :get_claim_token) == B`.
- **Strict-identity cases:** same token → same pid (no eviction); both nil → same
  pid; **held nil + incoming binary → EVICT** (the case the nil-permissive fence
  helper would have wrongly kept).
- End-to-end reclaim: composer parent whose lease expired with the old local
  process still registered → `ReclaimPooler.reclaim_once()` evicts + restarts with
  the rotated token → parent converges.
- `handle_call(:get_claim_token, …)` returns `state.claim_token`.

---

## Verification

1. `mix format`
2. `mix test test/jido_claw/orchestration/workflow_lease_test.exs test/jido_claw/orchestration/reclaim_pooler_test.exs test/jido_claw/route_composer/composer_durable_test.exs`
3. `mix reach.check --smells --strict` (confirm `fixed_shape_map` green after the fixture fix + ignore revert)
4. **`mix precommit`** — the gate of record. Watch: no unused `generate_ref/0`;
   `@spec`s on the new public `suspend_claim/2`/`degrade_gate/2`; dialyzer on the
   `try/catch :exit` in `current_owner?`; credo on `Process.sleep` in
   `await_deregistered` (bounded-recovery use, precedent exists — restructure only
   if flagged).

### Files touched
- `lib/jido_claw/orchestration/workflow_lease.ex` — `suspend_claim/2`, `degrade_gate/2`, `@suspend_claim_sql`
- `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — `suspend_or_fail_closed/4` (sidecar path), comment sweep
- `lib/jido_claw/route_composer/route_composer.ex` — `handle_call(:get_claim_token,…)`, strict-identity `ensure_started/2` + helpers, `degrade_gate`-driven `sidecar_fail_or_degrade/3`, comment sweep
- `test/support/jido_claw/route_composer/fixtures.ex` — `commit_wave0/3` → `store_wave_artifact/6`; drop `generate_ref/0`
- `.reach.exs` — revert the 3-module `fixed_shape_map` ignore hunk
- `docs/plans/clustering/WS3-reclaim-and-recovery.md` — degrade-suspend/fail-closed note
- tests: `workflow_lease_test.exs`, `composer_durable_test.exs`, `reclaim_pooler_test.exs`
