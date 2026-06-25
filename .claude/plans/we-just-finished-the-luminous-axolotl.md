# Fix P1 — ForgeBridge residual-timeout teardown can outrun the bridge error

## Context

The AR-8b-2 F2 Phase 1 plan (`.claude/plans/please-review-docs-exploration-alp-river-flickering-mochi.md`)
shipped the RunCommand↔Forge bridge. A code review found **one P1 issue** (everything else —
policy propagation, the approval bypass, Forge status validation, read-real/refusal changes —
passed). This plan resolves that single finding. **Done = `mix precommit` green.**

### The bug (verified valid)

`JidoClaw.Tools.RunCommand.ForgeBridge` builds the nested-deadline chain
`inner_OsCmd < harness_outer (inner + cushion) < jido_deadline`. It derives
`inner = remaining - margin` where `margin = Forge.exec_timeout_cushion_ms() + @taint_overhead_ms`
(cushion = 5000, `@taint_overhead_ms` = 500 ⇒ margin = 5500). The harness sizes its **outer**
`GenServer.call` deadline to `inner + cushion` (`Harness.exec_call_timeout/1`).

When a real in-container timeout occurs, that outer call times out and raises `:exit, {:timeout, _}`,
which the bridge catches at `forge_exec/3` (`forge_bridge.ex:226-230`) and routes to `taint_and_error/2`
(`forge_bridge.ex:232`). **This residual catch fires at `T0 + inner + cushion = deadline − 500`** — only
**500 ms** before `Jido.Exec` kills the action. But `taint_and_error/2` then runs **synchronous**
`safe_stop/1` → `Forge.stop_session/1` → `Manager.stop_session/1`, which is a
`GenServer.call(Manager, …)` with the **default 5000 ms timeout** (`manager.ex:38-40`) whose handler does
`DynamicSupervisor.terminate_child` on the *wedged* harness (`manager.ex:124`, up to ~5 s). So the stop
can block ~5000 ms against a 500 ms budget ⇒ **`Jido.Exec` kills the action and returns a *retryable*
`%Jido.Action.Error.TimeoutError{}` instead of the bridge's *non-retryable* `:sandbox_command_timeout`**,
defeating the timeout-ordering guarantee the bridge was built for.

Reviewer's Tidewave repro (stop sleeps 1 s, `Jido.Exec.run(RunCommand, …, timeout: 7_000, max_retries: 0)`
⇒ `TimeoutError` at ~7001 ms) matches this arithmetic exactly. The same `taint_and_error/2 → safe_stop/1`
sync teardown is also on the manufactured-124/153 taint path (currently "barely fits": returns at
`T0 + inner`, leaving `margin = 5500 ms` for a stop that can take ~5000 ms). The existing tests only use
*immediate* synthetic exits, so the sync stop runs with full budget and never exercises the race.

### Intended outcome

The bridge returns its non-retryable error **immediately** and always wins the Jido deadline, regardless
of how long teardown takes. Teardown is best-effort zombie cleanup with **no ordering contract** on the
return — so we **detach it**: structural fix, not a magic-number margin. (Chosen over the reviewer's
"reserve more budget" alternative, which is fragile — it depends on the stop never exceeding a guessed
worst case — and permanently taxes every command's runtime by enlarging `margin`.)

`Jido.Exec` enforces its deadline by killing the action task under **`Jido.Action.TaskSupervisor`**
(`deps/jido_action/lib/jido_action/exec.ex:498-588`) — a *separate* supervisor from the
`JidoClaw.TaskSupervisor` the teardown will run under, so the detached task is doubly immune to the kill.

---

## The fix

### `lib/jido_claw/tools/run_command/forge_bridge.ex`

Make `taint_and_error/2` schedule the teardown fire-and-forget and return immediately, via a guarded
`schedule_teardown/1` helper. Three load-bearing details (all from review feedback):

- **Capture the Forge facade *before* spawning.** `safe_stop` reads the injected facade via `forge()`
  (`Application.get_env(:jido_claw, :forge_facade, Forge)`). Once teardown is async the app env can change
  before the task runs — e.g. a test's `ForgeStub` cleanup restores `:forge_facade` in `on_exit` — so an
  orphaned task calling `forge()` *inside* the closure could hit the **real** `Forge.stop_session` (real
  Manager + a DB phase write outside the test's SQL sandbox). Capture `forge_mod = forge()` at spawn time
  and thread it in; change `safe_stop/1` → `safe_stop/2` (`forge_mod.stop_session/1`). `safe_stop`'s
  best-effort rescue/catch (and its `# reach:disable-next-line bare_rescue`) are otherwise unchanged.
- **Guard the spawn itself.** `Task.Supervisor.start_child/2` can `:exit` (e.g. `:noproc`) if the
  supervisor is unavailable/shutting down; teardown must *never* mask the bridge error, so wrap the start
  in a `catch :exit, _ -> :ok`.
- The leading `_ =` matches the house convention; the comment is substantive (why detached + the Ecto
  caveat) so it doesn't trip ExSlop's obvious/narrator-comment checks.

```elixir
defp taint_and_error(forge_key, err) do
  _ = schedule_teardown(forge_key)
  {:error, err}
end

# Detached best-effort teardown. Capture the Forge facade NOW — app env can change
# before the task runs (a test restoring :forge_facade in on_exit), so an orphaned
# task must not fall through to the real Forge.stop_session. Returning the
# non-retryable error immediately lets it win Jido.Exec's action deadline instead
# of blocking on a synchronous Forge.stop_session (a Manager GenServer.call that
# can take ~5s terminating a wedged harness — long enough for Jido to kill the
# action and surface a RETRYABLE TimeoutError). Runs under JidoClaw.TaskSupervisor,
# not the caller's context (the real stop_session phase write is detached from any
# caller Ecto sandbox). The start is guarded so a missing supervisor can't mask the
# bridge error.
defp schedule_teardown(forge_key) do
  forge_mod = forge()
  Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> safe_stop(forge_mod, forge_key) end)
  :ok
catch
  :exit, _ -> :ok
end
```

`JidoClaw.TaskSupervisor` is a core supervision child (`application.ex:142`); this exact
`Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> … end)` idiom is already used at
`manager.ex:178`, `harness.ex:458`, and elsewhere. (`forge/0` stays in use — `forge_exec/3` still calls
`forge().exec(...)`.)

**Error messages — match the now-async behavior.** The two taint-path envelopes claim the session is
already gone; with scheduled teardown it isn't yet at return time:
- `command_timeout_error/0` (~line 265): "the sandbox session **has been** torn down" → "**is being**
  torn down".
- `output_limit_error/0` (~line 276): same change.
(`unavailable_error/0`/`deadline_exceeded_error/0` are no-taint paths and don't mention teardown.)

**Doc prose** — update so the docs match behavior:
- moduledoc "Two substrates, one adapter" / the `dispatch/4` `@doc` (~lines 97-98): teardown is
  **asynchronous/detached** (best-effort, off the return path).
- `normalize_exec_result/2` `@doc` `:taint` line (~149): "the caller tears the session down **(async)**".

---

## Test changes (`mix precommit`-green via stubs)

### `test/support/forge_stub.ex` — make teardown observable + delayable

The existing stub's `stop_session/1` records the call and flips `exec_result` to `{:error, :not_found}`.
Two small additions so tests can rendezvous with the now-async stop and simulate a slow one:

- `install/1`: accept `notify: pid` (default `nil`) and `stop_delay: ms` (default `0`); stash both in the
  Agent state. **Default `notify` to nil so existing `install(client: client)` callers keep working.**
- Add `set_stop_delay/1` (mutates the Agent's `stop_delay`) for per-test override after the shared setup.
- `stop_session/2`: read `notify`+`stop_delay`; **`if stop_delay > 0, do: Process.sleep(stop_delay)`
  before** recording/flipping; after the `Agent.update`, `if notify, do: send(notify,
  {:forge_stub_stopped, session_id})`. (The delay must live **here**, not in `StubSandbox`'s `exec`
  `{:sleep,…}` form — the regressed defect is the *stop* blocking the return, not `exec`.)

### `test/jido_claw/tools/run_command_test.exs`

**Setup (docker bridge routing describe, ~line 600-605):** install with notify —
`ForgeStub.install(client: client, notify: self())`. (`setup` runs in the test process, so `self()` is the
test pid; `assert_receive` then drains the test mailbox.) The streaming-neutralization setup (~line 733)
needs no change — it never taints.

**Flip the two existing taint tests off synchronous `stops()` (now racy under async):**
- "a manufactured timeout taints…" (~647-662): after `assert err.code == :sandbox_command_timeout`, add
  `assert_receive {:forge_stub_stopped, "sess-x"}, 2_000`, then keep `assert ForgeStub.stops() != []`, and
  **move the follow-up-hard-fails assertion (`:sandbox_unavailable`) to after the `assert_receive`** — it
  depends on the async stop having flipped `exec_result`.
- "a Forge.exec that exits {:timeout, _} converges…" (~664-672): **also box in the residual-catch path
  directly** — `ForgeStub.set_stop_delay(1_000)`, capture elapsed around `RunCommand.run`, replace
  `assert ForgeStub.stops() != []` with `assert elapsed < 400, …` + `assert_receive
  {:forge_stub_stopped, "sess-x"}, 3_000`. This pins the *original residual-timeout shape* (the
  `exit({:timeout, _})` delivery path) with the same fast-return discriminant as the new test below.

The two full-`Jido.Exec.run` tests (~674-702) need **no change** — they assert only the returned code
(`err.details.code`), which the async fix preserves, and don't check `stops()`.

**New regression test (fast, deterministic, fail-before/pass-after)** in the same describe — the
*manufactured-124* delivery path (the existing test above covers the residual-catch path); together they
box in both paths that share `taint_and_error/2`:

```elixir
test "taint teardown is detached — the bridge returns before a slow stop_session", %{client: client} do
  ForgeStub.set_stop_delay(1_000)
  StubSandbox.program_exec(client, {"timeout after 5000ms", 124})

  t0 = System.monotonic_time(:millisecond)
  assert {:error, %{code: :sandbox_command_timeout}} =
           RunCommand.run(%{command: "sleep 999", timeout: 5_000}, docker_ctx())
  elapsed = System.monotonic_time(:millisecond) - t0

  # Decoupled: the sync code blocked here for the full 1s stop; async returns in ms.
  assert elapsed < 400, "expected a fast return; got #{elapsed}ms (teardown blocked it)"

  # The stop still runs, asynchronously.
  assert_receive {:forge_stub_stopped, "sess-x"}, 3_000
end
```

Both **fail on the current sync code** (return gated behind the 1000 ms stop, `elapsed ≈ 1000`) and
**pass on the async fix** (`elapsed ≈ single-digit ms`), a ~600 ms discriminating margin. `docker_ctx()`
carries no `:__jido_deadline_ms__`, so `derive_inner_timeout/2` honors `requested` and never refuses — the
tests exercise the taint→stop path directly. (A faithful full-`Jido.Exec.run` wall-clock repro would need
`timeout ≥ ~6500 ms` because of the 5000 ms cushion + 1000 ms min-viable floor, making it a ~6.5 s,
scheduler-timing-flaky test — the direct elapsed-time tests are the crisper regression.)

---

## Critical files

| Concern | File |
| --- | --- |
| The fix (async teardown) + doc prose | `lib/jido_claw/tools/run_command/forge_bridge.ex` (`taint_and_error/2`) |
| Stub: `notify`/`stop_delay`/`set_stop_delay`, send `{:forge_stub_stopped, _}` | `test/support/forge_stub.ex` |
| Flip 2 taint tests to `assert_receive` + new regression test | `test/jido_claw/tools/run_command_test.exs` |
| Reference only — `JidoClaw.TaskSupervisor` core child | `lib/jido_claw/application.ex:142` |
| Reference only — Jido kills under a *separate* supervisor | `deps/jido_action/lib/jido_action/exec.ex:498-588` |

Unaffected: `forge_bridge_test.exs` is pure (`normalize_exec_result/2` + `derive_inner_timeout/2`, no
taint side-effect). No other test in the suite depends on synchronous bridge teardown (only
`run_command_test.exs:657,660,671`).

---

## Verification

1. **`mix precommit`** — definition of done (`jidoclaw.compile_check` no-warnings,
   `format --check-formatted`, credo strict, ExSlop reach/clone at zero, full suite).
2. Targeted while iterating:
   - `mix test test/jido_claw/tools/run_command_test.exs test/jido_claw/tools/run_command/forge_bridge_test.exs`
3. **Prove the regression bites:** temporarily make teardown synchronous again (`_ = safe_stop(forge(),
   forge_key)` in `taint_and_error/2`) and confirm both "teardown is detached" assertions **fail**
   (`elapsed ≈ 1000 ms`), then restore `schedule_teardown/1` and confirm they **pass** —
   fail-before/pass-after.

### Hygiene notes
- No **new** bare rescue: `safe_stop` only changes arity (`/1` → `/2`), keeping its existing
  `# reach:disable-next-line bare_rescue`. `schedule_teardown/1`'s guard is a `catch :exit, _` (not a
  `rescue`), so it doesn't trip the `bare_rescue` check (mirrors `safe_stop`'s unannotated `catch _, _`).
- The supervised spawn is a single statement matching a 7+-site existing pattern — no clone/seam finding.
- Keep the `schedule_teardown/1` comment substantive (the why + facade-capture + Ecto caveat) to avoid an
  ExSlop obvious/narrator-comment flag.
