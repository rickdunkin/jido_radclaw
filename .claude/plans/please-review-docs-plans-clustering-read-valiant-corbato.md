# WS2 — Composer Lease (AR-2 Phase 6)

## Context

JidoClaw can be flipped into multi-node mode (`cluster_enabled: true`), but doing
so today **silently strands every interrupted run**: boot recovery turns itself
off under clustering (`workflow_recovery.ex` `owns_recovery?`), on the design
intent that *lease-expiry reclaim* replaces it. WS1 shipped the lease
**mechanism** (`WorkflowLease.stamp/renew/claim_next/fence_decision/start_sidecar`,
the `Sidecar`/`Middleware`, both terminal fences, and self-claim-on-launch for
single `Reactor.run` runs). WS2 is the piece AR-2 deferred as "Phase 6": a single
`Reactor.run` is not the composer's unit of work — a composed run is a **loop
spanning N waves** with state living *between* reactor executions, parked for
days on human gates. So the lease must be re-derived around the **parent composer
run**, owned by the long-lived `RouteComposer` GenServer.

The hard constraint that shapes the design: the `RouteComposer` GenServer runs
its wave loop **synchronously** — each worker wave calls `ReactorRunner.run/3`
and blocks there (up to `wave_timeout_ms`, default 300 s) while the lease is only
60 s. A self-timer inside the GenServer cannot fire mid-wave, so it could not
keep a long wave's lease alive. **We therefore renew the parent lease from an
off-process sidecar** (Approach A, decided with the user), exactly as WS1 already
heartbeats child runs. This preserves the invariant WS3 depends on: **a fresh
lease ⇒ a live owner; an expired lease ⇒ a reclaimable owner**, regardless of how
long a legitimate wave runs.

This plan implements WS2 single-node (renewal + fence + halt mechanics);
real cross-node reclaim is WS3's trigger + WS6's multi-node harness.

## Approach (decided: Approach A — off-process sidecar)

- **Reuse the WS1 `Sidecar`** for the parent (one small registration-retry change,
  §3). The `RouteComposer` GenServer is the sidecar's "executor": the sidecar
  renews the parent lease every `renew_seconds` independently of the GenServer
  mailbox (no mid-wave gap), and on a stale fence (`renew/2 → {:ok, 0}`) does
  `Process.exit(composer, :kill)`.
- **`:kill` → `:transient` restart → held-token preflight.** The killed composer
  is restarted by `RouteComposer.Supervisor`; on rebuild it **preflights the
  token it holds** (frozen in its start_opts, *not* re-read from the row). If
  `renew/2` returns `{:ok, 0}` the row's token was rotated by the reclaiming node
  → the restarted process is a zombie → `{:stop, :normal}` writing **no parent
  events**, so the reclaiming node's rebuilt state stays authoritative.
- **Durable token-fence defense** on the parent marker + terminal writes, so even
  a not-yet-killed zombie cannot corrupt the new owner's log (today composer
  markers are only parent-*terminal* guarded, never token-fenced).

### Token lifecycle (the WS3-load-bearing invariant — also documented in the WS2 doc)

| Phase | Token behavior |
|---|---|
| **Fresh launch** | `create_parent_run/1` stamps the parent `nil → fresh token` *before* the GenServer ticks; token rides `build_start_opts → init → state.claim_token`. |
| **Local restart** (crash, same node) | `:transient` restart reuses the **frozen start_opts token**; preflight `renew/2 → {:ok, 1}` (row token unchanged single-node) → resume + restart sidecar. |
| **WS3 reclaim** (other node) | The dispatcher starts the composer from the token `claim_next` returned; same start_opts seam. *(WS2 builds the seam; WS3 wires the dispatcher.)* |
| **Fence-kill restart** | Held token ≠ rotated row token → preflight `renew/2 → {:ok, 0}` → `{:stop, :normal}`, no events. |

### Master compatibility switch

The composer's runtime lease behavior is gated on **`is_binary(state.claim_token)`**
(mirrors the WS1 `Middleware` no-token clause). A real launch always claims (§1
genesis is unconditional, inside the txn), so it always runs leased. A **nil** token
— a `loop_state/3` raw-state tick or any path that bypasses `create_parent_run` —
⇒ byte-identical unleased path: no preflight, no sidecar, no marker/terminal fence.
This keeps every existing composer test unchanged.

## Implementation

### 1. Genesis self-claim — atomic, inside the genesis transaction (`create_parent_run/1`, 334-377)

**Stamp INSIDE the genesis `Ash.transact` (354-370), between `WorkflowRun.create`
(:pending) and the `run_started` append** — mirroring WS1's `:pending`-claim
invariant (`middleware.ex:8`). Claiming *after* `run_started` flips the row
`:running` (my earlier draft) would, on a crash-in-the-gap, leave a `:running +
nil claim_token` row — a shape `:claimable` does **not** select
(`workflow_run.ex:250-256`; cf. the documented safe crash shape in
`workflow_lease_test.exs:333`), i.e. permanently stranded.

- Generate `claim_token = Ash.UUID.generate()` **outside** the transact (so it
  survives for the post-txn struct-set), capture it into the closure.
- New `claim_genesis(parent, token)` helper wrapping `WorkflowLease.stamp(parent.id,
  token, nil)`: `{:ok, :claimed} -> :ok`; `{:ok, :lost} -> {:error, :lease_lost}`;
  `{:error, r} -> {:error, r}`. Insert `:ok <- claim_genesis(parent, claim_token)`
  in the with-chain right after `create`, before `run_started`. A non-`:claimed`
  result returns `{:error, _}` → the **whole genesis rolls back** (no half-baked
  row) → surfaced as `{:error, {:start_failed, _}}`. Keep the outer
  `case genesis do {:error, reason} -> …` match **generic** (don't pattern-match
  `:lease_lost` outside the transact — `[[project_ash_transact_dialyzer_error_channel]]`).
- Raw `Repo.query` (inside `stamp/4`) joins the same connection/transaction as the
  surrounding `Ash.transact` (the standard drop-to-SQL-in-a-txn pattern): the
  just-created uncommitted `:pending` row is visible to the stamp, and
  `run_started`'s internal `Allocate.lock_run` FOR-UPDATE reload sees the stamped
  token (genesis threads **no** `claim_fence_token`, so `Allocate.claim_fenced?`
  stays inert for it).

Result: a crash leaves either **nothing** (rolled back) or **`:running + claimed`**
(reclaimable on expiry) — never the `:running + nil` crack. No post-commit stamp,
no orphan-terminalize, no `cluster_enabled` branch at genesis (the claim is
unconditional and inert single-node). After the txn, thread the token onto the
reloaded struct — `reload_running_parent(%{parent | claim_token: claim_token}, …)`
— so `build_start_opts` and the 871 reload-failure `terminalize_parent` (§5) both
carry the held token.

### 2. Thread the token start_opts → state

- `build_start_opts/2` (704-717): add `Keyword.put(:claim_token, parent.claim_token)`.
  This freezes the token into the supervised child spec (so it survives
  `:transient` restart) and equally carries the **persisted** token on the
  recovery path (recovery passes a reloaded parent through the same helper).
- `init/1` state map (894-938): add `claim_token: Keyword.get(opts, :claim_token)`
  (defaults `nil` ⇒ unleased).

### 3. Preflight + start the parent sidecar — `do_rebuild/1` (1011-1026)

In the `{:ok, parent, events}` branch, **gated on `is_binary(state.claim_token)`**:

1. **Preflight** `WorkflowLease.renew(state.parent_run_id, state.claim_token)`
   (the *held* token, never `parent.claim_token`):
   - `{:ok, 1}` → still owner; continue to step 2 then `resume_or_tick`.
   - `{:ok, 0}` → reclaimed/zombie → `{:stop, :normal, state}` (no events).
   - `{:error, _}` → `retry_rebuild_or_stop/2` (existing capped backoff).
2. **Start the heartbeat** `WorkflowLease.start_sidecar(self(), state.parent_run_id,
   state.tenant, state.claim_token)`. On `{:error, _}` follow WS1
   `Middleware.fail_or_degrade/2` semantics, **keeping `state.claim_token` either
   way** (the durable fences and the restart-preflight rely on the held token — do
   **not** clear it): **under clustering** → `{:stop, :normal, state}` (a composer
   with no heartbeat would let the lease lapse and another node reclaim → fail
   closed; the parent stays `:running + claimed` for WS3 reclaim); **single-node** →
   log + proceed with a *degraded* (absent) heartbeat — the held token still matches
   the row so the durable fences never false-positive, and nothing reclaims an
   expired single-node lease. **Not** `retry_rebuild_or_stop` (the bounded retry
   lives in the Sidecar — see below). (The nil-token path skips both steps →
   existing behavior. The fence-kill restart hits `{:ok, 0}` in step 1 and stops
   *before* step 2, so no sidecar is started for a zombie.)

`start_sidecar` blocks ≤5 s for the readiness handshake — acceptable inside
`do_rebuild`, which already does DB work. The sidecar registers in `LeaseRegistry`
keyed by `parent_run_id` (distinct from child-run keys) and exits cleanly when the
composer stops (its monitor fires on the composer's `:DOWN`).

**Registration-race fix (`LeaseRegistry` is `:unique`, application.ex:160).** On an
*ordinary* crash-restart with the same token, the supervisor can restart the
composer before the old sidecar processes its `:DOWN` and unregisters, so the new
sidecar's `Registry.register` hits `{:error, {:already_registered, _}}` →
`{:lease_register_failed, _}` → a false sidecar-start failure. Fix it **in
`Sidecar.run/5`** (`sidecar.ex:53`): bounded-retry registration on
`:already_registered` (~10 × 50 ms, well inside the 5 s readiness deadline, and
*before* the monitor-arm/ready handshake so its invariants hold) before exiting.
This is a deliberate WS1 touch — it's the generic lease-*handoff* race WS3's
reclaim will hit too, so it belongs in the shared sidecar, not a composer-side
busy-poll. Do **not** route the composer's `start_sidecar` failure through
`retry_rebuild_or_stop`: `do_rebuild` resets `rebuild_attempts: 0` on every
successful reload (1019), so a post-reload retry never trips the cap → infinite
loop. The bounded Sidecar retry is the fix; the composer's degrade/stop is the
backstop.

### 4. Stale-fence halt semantics — the `:parent_fenced` atom

The kill→restart→preflight path (step 3) is the primary halt. The durable fence
(step 5) is the secondary defense; it surfaces as a new `{:error, :parent_fenced}`
that the composer treats as **"another owner has the parent — stop clean, write
nothing, tear nothing down."** Distinct from `:parent_terminal` ("the run truly
ended") because at the two **gate-park** Commit sites a terminal tears the gate
`AgentCase` down, whereas a fence must leave it open for the reclaiming node to
re-park.

Add `{:error, :parent_fenced} -> {:stop, :normal, state}` (uniform, no teardown)
at all nine Commit-result sites: `route_composer.ex` **1156, 1231, 1356, 1474,
1616, 1757, 1958, 2380, 2443**. (At the seven non-gate sites this equals the
existing `:parent_terminal` arm; at 1616/1757 it intentionally skips the gate
teardown the terminal arm does.)

### 5. Durable token-fence on marker + terminal writes

- **Markers** — `commit.ex` `guarded_wave_txn/4` (149-159): after
  `reload_for_update`, before the `terminal_status?` check, add a nil-safe token
  guard — `held = opts[:claim_fence_token]`; if `is_binary(held) and
  is_binary(locked.claim_token) and locked.claim_token != held` → return the bare
  atom `:parent_fenced` (success channel, same as `:parent_terminal`). Add
  `unwrap_transact({:ok, :parent_fenced}) -> {:error, :parent_fenced}` (169). This
  one chokepoint covers `commit_wave/4`, `start_wave/3`, **and** `append_markers/3`.
- **Thread the held token** — new `commit_opts(state)` (next to `auth_opts/1`,
  1573) = `Keyword.put(auth_opts(state), :claim_fence_token, state.claim_token)`.
  Use it at the seven `Commit.*` call sites (1342, 1472, 1608, 1743, 1953, 2376,
  2439), all of which target `state.parent`. Leave the non-Commit `auth_opts` use
  (≈1656) as-is (threading a parent token onto a non-parent append would mis-fence).
- **Terminal** — `append_parent_terminal/5` (2870) is the single terminal-write
  primitive. Add an optional `claim_token \\ nil` param → pass
  `claim_fence_token: claim_token` to `WorkflowLog.append` so WS1's existing
  `Allocate.claim_fenced?` (status-authority + token-mismatch ⇒ rollback) fences a
  stale terminal. `parent_terminal_notify/4` (2662-2751) passes `state.claim_token`.
- **`terminalize_parent` must thread the held token, not `nil`** (review finding).
  Its callers are **not** all unclaimed launch-failures: `await_terminal` (run_sync)
  terminalizes a parent that actively *ran* on **crash** (849) and **timeout** (855),
  and `start_composer` (570) / `maybe_terminalize_orphan` (617) / `reload_running_parent`
  (871) all act on a parent `create_parent_run` already claimed. A `nil`
  `claim_fence_token` bypasses the Ash fence, letting a stale node clobber a
  reclaimed parent's terminal. Add an optional `claim_token` to `terminalize_parent/4`
  and thread the held token at every site: `parent.claim_token` (on the struct from
  genesis / persisted on a reloaded recovery parent) at 570/617/849/855, the in-scope
  genesis token at 871. Harmless where held == row (immediate launch failures);
  correctness-relevant on the run_sync crash/timeout paths under clustering.
- **Launch-window fence** (review finding) — `ensure_parent_live/1` (1243), the
  belt-and-suspenders check between `record_wave_start` and `run_reactor`, today
  only tests `terminal_status?`. Since WS2 introduces parent token ownership, also
  read the reloaded `claim_token` and return `{:error, :parent_fenced}` on a
  nil-safe mismatch (`is_binary(state.claim_token) and is_binary(run.claim_token)
  and run.claim_token != state.claim_token`). Caught by the new `:parent_fenced`
  arm at `run_built_wave`'s else (1231). Narrows the post-marker / pre-child-create
  reclaim window (a reload blip still proceeds → fold fenced at `commit_wave/4`).

### 6. Update the WS2 doc — `docs/plans/clustering/WS2-composer-lease.md`

Replace the "renewal lives in the GenServer timer" framing with Approach A; add
the **token-lifecycle table** above; document the durable token-fence; and rewrite
the test plan (renewal is sidecar-driven via the `{:lease_tick}` seam, **not**
"advances each tick"). Note the README WS2 size is now **M** (was S–M) given the
durable-fence ripple. Keep the AR-2 §10.1 / Phase 6 / §6 cross-refs.

### Config

No new keys. Reuse `:workflow_lease` (`config.exs:262` 60 s/15 s; `test.exs:22`
parks the auto-renew at 86 400 s so tests drive renewal through the
`{:lease_tick, from}` seam).

## Critical files

| File | Change |
|---|---|
| `lib/jido_claw/route_composer/route_composer.ex` | genesis stamp (`create_parent_run`, all 3 `stamp` returns); `claim_token` in `build_start_opts` + `init`; preflight + `start_sidecar` in `do_rebuild`; `commit_opts/1` + swap at 7 Commit sites; `:parent_fenced` arm at 9 sites; token check in `ensure_parent_live/1`; `claim_token` through `parent_terminal_notify` + `append_parent_terminal` + `terminalize_parent` (5 call sites) |
| `lib/jido_claw/route_composer/commit.ex` | token guard in `guarded_wave_txn/4` + `unwrap_transact` `:parent_fenced` clause |
| `lib/jido_claw/orchestration/workflow_lease/sidecar.ex` | **modified**: bounded registration retry on `:already_registered` (the lease-handoff race); otherwise reused (monitors the composer, `:kill`s on stale) |
| `lib/jido_claw/orchestration/workflow_lease.ex` | **reused unchanged** (`stamp/renew/fence_decision/start_sidecar/node_identity`) |
| `docs/plans/clustering/WS2-composer-lease.md` | rewrite to Approach A + token lifecycle |
| `test/jido_claw/route_composer/composer_lease_test.exs` | **new** (composer genesis/renew/fence/halt/restart) |
| `test/jido_claw/orchestration/workflow_lease_test.exs` | add the temporary-blocker registration-retry test; re-check the permanent-blocker test (`:347`) under the new retry-then-fail timing |

## Reused WS1/composer machinery (do not rebuild)

- `WorkflowLease.stamp/4` (110), `renew/2` (132), `fence_decision/3` (216),
  `start_sidecar/4` (238), `node_identity/0` (86), the `Sidecar` renew/fence/kill/
  monitor loop + `{:lease_tick}` seam (only its registration gains a retry),
  `LeaseRegistry`/`LeaseTaskSupervisor`.
- `Allocate.claim_fenced?/2` (terminal fence — just needs the token threaded).
- `ComposerProjection.project/2` + the `:transient` rebuild path (the reclaim
  substrate already makes the composer log-derived; WS2 does **not** touch it).
- Existing `{:error, :parent_terminal}` clean-stop idiom (the `:parent_fenced`
  sibling pattern).

## Test plan — `test/jido_claw/route_composer/composer_lease_test.exs`

`use JidoClaw.TenantCase, async: false` (shared sandbox — the composer + its
off-process sidecar must share one connection); reuse `composer_stubs.ex`
(`StubWorker`/`GatedAgentServer`) and the WS1 raw-SQL helpers (`rotate_token!`,
`set_claim!`, `backdate_inserted!`). `on_exit` backstop to sweep leaked
parent sidecars (mirror `workflow_lease_test.exs:55-63`).

1. **Genesis self-claim** — after `create_parent_run/1`, the row has a binary
   `claim_token`, `claimed_by == node_identity()`, `claim_expires_at ≈ now+60 s`.
2. **Sidecar renews across waves** — supervised composer (`ensure_started`) runs
   ≥2 stub waves; look up the parent sidecar in `LeaseRegistry` by
   `parent_run_id`, `send({:lease_tick, self()})`, assert `{:lease_ticked,
   {:ok, 1}}` and `claim_expires_at` advanced.
3. **Renew across gate pause** — composer parked on a `GatedAgentServer` gate;
   drive the parent sidecar tick → `{:ok, 1}`, expiry advances (proves
   off-process renewal during a park).
4. **Fence → kill → restart → preflight → stop normal** — supervised composer;
   `rotate_token!(parent_run_id, other)`; drive sidecar tick → `{:ok, 0}` → assert
   composer is killed, restarts, preflights, stops `:normal` (eventually absent
   from the registry); assert **no new parent events** after the rotation and the
   row token is unchanged.
4b. **Ordinary crash-restart, same token** — supervised composer mid-run;
   `Process.exit(pid, :kill)` it **without** rotating the token. Assert it restarts,
   preflight `renew/2 → {:ok, 1}`, re-registers its parent sidecar, and resumes
   (lease still held, loop continues to terminal). *Integration-level resume check
   — it does not deterministically hit the registration retry (the old sidecar may
   unregister first); test 4c does.*
4c. **Sidecar registration retry — deterministic** (review finding; in
   `workflow_lease_test.exs`, not the composer file). Pre-own the `LeaseRegistry`
   key with a **temporary** blocker process that `Registry.unregister`s after a
   short delay (~100 ms), then call `start_sidecar/4`; assert it returns **`:ok`**
   (it consumes the readiness handshake internally) and `Registry.lookup(@lease_registry,
   run_id)` now resolves to the sidecar — proving the retry succeeded. *(Or drive
   `Sidecar.run/5` directly and assert the `{:lease_ready, run_id}` message.)*
   Companion: the existing **permanent**-blocker test (`:347`) keeps asserting
   `{:error, {:lease_sidecar, _}}` — the sidecar now *exhausts* its bounded retries
   (~500 ms, still < the 5 s readiness deadline) before exiting, so that test's
   outcome is unchanged (just slower); confirm its assertion/timeout still holds.
5. **Durable marker fence** — unit-test `Commit.commit_wave`/`append_markers`:
   mismatched `claim_fence_token` → `{:error, :parent_fenced}`; matching → `:ok`;
   `nil` → `:ok` (unleased skip). Composer-level: a stale wave commit yields
   `:parent_fenced` → `{:stop, :normal}`, no marker appended.
6. **Terminal fence (public seam)** — `append_parent_terminal/5` is private, so
   drive the fence through the **public** `WorkflowLog.append(parent,
   :route_converged, payload, claim_fence_token: stale, …)` (mirroring WS1's
   fence-B tests, `workflow_lease_test.exs:223-255`): a mismatched token is
   rejected with status unchanged; a matching token lands the terminal. Optionally
   add a composer-level path: a stale-token composer reaching `finish/2` writes no
   terminal (`terminalize_parent` fenced).
7. **Reclaim re-folds, never re-runs** — re-derive a completed wave after a
   rebuild; the shipped idempotency key (`composer:<parent>:<wave>`) folds the
   existing child run instead of re-executing it.
8. **Unleased compatibility** — a `claim_token: nil` composer runs with no
   preflight/sidecar/fence (existing behavior intact).

## Verification

1. New + adjacent suites:
   `mix test test/jido_claw/route_composer/composer_lease_test.exs
   test/jido_claw/route_composer/ test/jido_claw/orchestration/workflow_lease_test.exs`
2. **`mix precommit` green** (the definition of done): `jidoclaw.compile_check`
   (warnings-as-errors), `system_prompt.check`, `deps.unlock --unused`,
   `format --check-formatted`, `reach.check --arch --smells --strict`,
   `credo --strict`, `dialyzer`, full `test`. Watch points: dialyzer on the new
   `:parent_fenced` return (commit.ex specs are already `{:error, term()}`);
   `commit_opts/1` builds on `auth_opts/1` (no clone-smell); the nine
   `:parent_fenced` arms are mechanical. Never pipe precommit through `tail`.
3. Tidewave spot-check (optional): drive a supervised composer, confirm the parent
   sidecar in `LeaseRegistry` and `claim_expires_at` advancing on a manual tick.

## Risks / notes

- **Mid-wave kill orphans the in-flight child run.** A stale-fence `:kill` while a
  worker wave is blocked in `ReactorRunner.run/3` abandons that child (it carries
  its own lease; reclaim-resume of a still-running child is **WS3/WS6**). Single-
  node WS2 never triggers a kill (nothing rotates the token), so this is untested
  until the WS6 multi-node harness — call it out, don't silently rely on it.
- **`build_start_opts` token freeze is load-bearing.** The held token must come
  from the frozen start_opts, never re-read from the row on restart — otherwise a
  restarted zombie would renew the *reclaimer's* token and steal the claim back.
- **Lease-handoff registration race needs a Sidecar-level retry, not a rebuild
  retry.** `do_rebuild` resets `rebuild_attempts: 0` on each successful reload
  (1019), so a `start_sidecar` failure routed through `retry_rebuild_or_stop` would
  never trip the cap → infinite loop. The bounded `:already_registered` retry lives
  in `Sidecar.run/5`; the composer's degrade/stop is only the backstop.
- **Full-suite blast radius.** Every `create_parent_run`-launched composer now
  claims + starts a parent sidecar. Renewal is parked in test (86 400 s) and the
  sidecar dies with the composer, so existing tests should be unaffected — the
  full `mix precommit` run is the proof, not an assumption.
