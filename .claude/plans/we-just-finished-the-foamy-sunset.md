# Fix: sync `run_sync` caller misreports `:timeout` on a clean fence/terminal stop

## Context

The WS2 composer-lease work added `:parent_fenced` clean-stop arms throughout
`RouteComposer` that return `{:stop, :normal, state}` when another node has
reclaimed the parent (token rotated). A code review (P2) found these stops are
**also reachable from the blocking `RouteComposer.run_sync/1` API**, and they break
its terminal protocol.

**Verified valid.** `run_sync/1` monitors an unlinked composer and blocks in
`await_terminal/7` (`route_composer.ex:881-901`). That `receive` has three clauses
+ an `after timeout`:

1. `{:route_composer, ref, {:done, summary}}` → `{:ok, summary}`
2. `{:route_composer, ref, {:terminalize_failed, reason}}` → `{:error, {:terminalize_failed, _}}`
3. `{:DOWN, …, reason}` **`when reason != :normal`** → terminalize live + `{:error, {:crashed, _}}`
4. `after timeout` → kill + terminalize + `{:error, :timeout}`

The success path depends on `finish/2` (`:2816`) calling `maybe_notify/2` (`:2825`)
to send the `{:route_composer, …}` tuple **before** the process stops. The comment
at `:874-880` documents the design: a benign `:DOWN :normal` is fine *because*
`finish/2` already enqueued the `{:done, _}` tuple ahead of it.

But the `:parent_fenced` arms (and the **pre-existing** `:parent_terminal` arms,
plus the lease-zombie `:1096`, clustered-sidecar-fail `:1136`, rebuild-exhausted
`:1209`, and rebuild-already-terminal `:1063` arms — ~20 sites total) return
`{:stop, :normal, state}` **without** going through `finish/2`. So a `run_sync`
composer that fences at a wave commit (`handle_wave_value` `:1505`), wave start
(`run_built_wave` `:1358` / `run_gate_wave` `:1280`), or gate resume
(`fold_resumed_gate` `:1932`) sends **no** notify. The monitor then fires
`:DOWN :normal`, which clause 3's `reason != :normal` guard deliberately ignores,
and there is no catch-all — so the caller blocks the full **60 s**
(`@default_timeout_ms`, `:166`) and returns a misleading `{:error, :timeout}`
(also pointlessly attempting a kill + fenced terminalize) for what was a clean stop.

`run_sync/1` currently has **no production callers** (tests only), but it is a
public, `@spec`'d blocking API and the supervised WS2 paths (which rely on the
durable terminal, not the notify) are unaffected — so this is a latent
correctness bug in the blocking API, worth closing now.

The review found **no other issues** (token threading, marker/terminal fence
placement, sidecar registration retry, and the new tests were all cleared, and the
two named suites passed). So this plan resolves the single validated finding.

## Fix — one new `await_terminal` clause (reviewer's option B)

Adding the notify to ~20 stop sites (option A) is fragile and semantically awkward
for arms like rebuild-exhausted ("left `:running` for recovery"). Instead, handle
the benign stop at the **single chokepoint** where the sync caller already
observes process death — `await_terminal/7`. This one clause covers every current
*and future* no-notify `{:stop, :normal}` arm.

### `lib/jido_claw/route_composer/route_composer.ex`

1. **New 4th `receive` clause** in `await_terminal/7`, after the crash clause
   (`:891`). Clauses 3 and 4 are guard-disjoint on `reason`, so order between them
   is irrelevant:

   ```elixir
   {:DOWN, ^monitor_ref, :process, ^pid, :normal} ->
     {:error, :stopped_without_terminal}
   ```

   It must **not** terminalize (unlike clauses 3/4): a benign `:normal` stop means
   the parent is already terminal (`:parent_terminal`), owned by another node
   (`:parent_fenced`/zombie/clustered), or intentionally left `:running` for
   recovery — terminalizing here would be wrong (and a stale-token terminalize is a
   fenced no-op anyway). Returning promptly is the whole point.

   **Ordering safety (no happy-path regression):** when `finish/2` *did* notify,
   Erlang's signal-ordering guarantee (already relied on by the `:877-880` comment)
   puts the `{:done, _}` message ahead of the `:DOWN :normal` in the mailbox, and
   clause 1 is tried first — so the new clause only ever fires when **no** notify
   preceded the benign DOWN.

2. **`@spec run_sync/1`** (`:848-853`): add `| {:error, :stopped_without_terminal}`.

3. **`@doc` "Returns" list** (`:838-846`): add a bullet documenting
   `{:error, :stopped_without_terminal}` — "the composer stopped cleanly without delivering a
   terminal to this caller (a lease fence/reclaim, an external cancel, a zombie
   restart, or a left-for-recovery stop); re-read the parent if the cause matters."

4. **Update the `await_terminal` comment** (`:874-880`) to describe the new
   benign-DOWN-without-notify clause and why it must not terminalize.

> **Decided:** return the single generic `{:error, :stopped_without_terminal}` for
> every benign stop — no parent re-read. Minimal contract change (one spec member,
> no extra DB query); a caller that needs the cause re-reads the parent itself. The
> atom is deliberately neutral/truthful: the clause also covers "parent already
> terminal" and "left `:running` for recovery", not only WS2 lease ownership loss,
> so `:stopped_without_terminal` reads more honestly than `:ownership_lost`.

## Test — deterministic `run_sync` fence regression

Add one test to `test/jido_claw/route_composer/composer_lease_test.exs` (it already
has `arm_gate/1`, `converging_outputs/0`, `base_opts/1`, and `rotate_token!/2`; add
a small `composer_parent_run/1` helper mirroring `composer_loop_test.exs:672`).

Reuse the proven `Task.async` + `{:wave_gate, exec_pid}` model
(`composer_loop_test.exs:605`):

1. `converging_outputs()`; `arm_gate(ctx)`.
2. Run `run_sync` in a Task with a **generous** timeout (longer than the
   wave-gate setup window, so a slow machine can't race the timeout against
   startup):
   `Task.async(fn -> send(test_pid, {:run_sync, RouteComposer.run_sync(Keyword.put(base_opts(ctx), :timeout, 15_000))}) end)`.
3. `assert_receive {:wave_gate, exec_pid}, 10_000` — wave 0 is blocked in the
   executor; its start markers already landed under the still-valid token.
4. `parent = composer_parent_run(ctx)`; `rotate_token!(parent.id, Ash.UUID.generate())`
   — simulate a reclaimer rotating the token out from under the live owner.
5. `send(exec_pid, :proceed)` — the wave completes, returns to the composer, and
   `handle_wave_value`'s `commit_wave` (fenced via `commit_opts`) sees the rotated
   row token → `:parent_fenced` → `{:stop, :normal}` with **no** notify.
6. **`assert_receive {:run_sync, {:error, :stopped_without_terminal}}, 5_000`**,
   then `Task.await(task)`. This is deterministic *and* race-free: the *fixed*
   build delivers `{:error, :stopped_without_terminal}` within ms of `:proceed`, so
   the 5 s window passes easily; a *broken* build leaves the composer blocked in
   `await_terminal` until its 15 s `run_sync` timeout, so **no** reply arrives
   inside the 5 s window → `assert_receive` fails fast (~5 s). Because the
   discriminator is "did the reply arrive shortly after `:proceed`" (not a short
   `run_sync` timeout), nothing races the ≤10 s startup-to-wave-gate window.
7. (Optional) assert the parent stays `:running` with the reclaimer's token and the
   zombie appended no terminal (the WS2 "write nothing" invariant).

No new sidecar tick is driven (test config parks auto-renew at 86 400 s), so the
composer is never killed — the wave proceeds and the commit fence is the trigger.
The wave completes before the fence, so its child-run write lands before the stop
(no orphan-drain needed). This same clause also covers the pre-existing
`:parent_terminal` family; one `:parent_fenced` test is sufficient to lock the
clause.

## Critical files

| File | Change |
|---|---|
| `lib/jido_claw/route_composer/route_composer.ex` | new `await_terminal/7` benign-`:normal`-DOWN clause; `@spec` + `@doc` + comment updates |
| `test/jido_claw/route_composer/composer_lease_test.exs` | new deterministic `run_sync` fence regression test + `composer_parent_run/1` helper |

## Verification (definition of done = `mix precommit` green)

1. New + adjacent suites first:
   `mix test test/jido_claw/route_composer/composer_lease_test.exs test/jido_claw/route_composer/composer_loop_test.exs test/jido_claw/route_composer/ test/jido_claw/orchestration/workflow_lease_test.exs`
   — confirm the new test passes and the existing `run_sync` timeout test
   (`composer_loop_test.exs:594`, a *genuine* hung-wave timeout) still returns
   `{:error, :timeout}` (no DOWN occurs there, so the new clause cannot interfere).
2. **`mix precommit` green** — `jidoclaw.compile_check` (warnings-as-errors),
   `format --check-formatted`, `reach.check --arch --smells --strict`,
   `credo --strict`, `dialyzer` (the only new type is the spec'd
   `{:error, :stopped_without_terminal}` flowing from `await_terminal` to `run_sync`), full
   `test`. Watch points are minimal: one receive clause, one spec member, no new
   module/forwarder/clone. Never pipe precommit through `tail`.
