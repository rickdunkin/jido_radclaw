# Plan: Resolve v0.6 Phase 3b Code-Review Findings

## Context

Phase 3b's code review surfaced two real bugs in the memory consolidator:

1. **P1 — Cadence runs are silently killed at 5s.** `Consolidator.tick/0` fans out per-scope runs through `Task.Supervisor.async_stream_nolink/6` without an explicit `:timeout`, so each task inherits the 5,000ms default. Real runs target a 600,000ms harness budget, so every cadence-driven run is killed at 5s while the linked-but-trapping `RunServer` and the `:async_nolink` harness Task continue detached for up to 600s. With `max_concurrent_scopes: 4` and `max_candidates_per_tick: 100`, that means a single tick can leave up to 100 detached Forge sessions running concurrently. The `cadence` cron is gated by `enabled: false` today, so this only fires when the flag flips — but the regression should be fixed before that happens.

2. **P2 — Tests stop the sandbox while Forge is still writing.** `run_now/2` returns when `RunServer` terminates after `commit_proposals`, but it does not wait for the linked harness Task or `Forge.Manager.stop_session`. After `run_now/2` returns, `Forge.Harness`'s `terminate/2` (`forge/harness.ex:617-636`) and the per-iteration `:iteration_complete` cast handler (`forge/harness.ex:531-601`) call `JidoClaw.Forge.Persistence.persist/1` 6+ more times. `persist/1` is `try/rescue`-wrapped, so the writes don't crash the suite, but they emit `DBConnection.ConnectionError {:owner, exited}` and Forge GenServer crash logs. Today only one of the six tests in `run_server_test.exs` (`:269-315`) waits for the session to drain — the other five let teardown race the writes.

Both findings verified against the live tree: `consolidator.ex:81-89` matches the report, the misleading `:async` doc lives at `consolidator.ex:49-50`, and the test setup at `run_server_test.exs:24-51` does not touch Forge persistence config. The clean fix pattern for P2 already exists at `test/jido_claw/forge/clustering_test.exs:58-73`.

## Fix 1 (P1) — Bound the cadence stream timeout to the inner GenServer.call timeout

**File:** `lib/jido_claw/memory/consolidator.ex`

**Change at lines 81-89:** Pass an explicit `:timeout` to `async_stream_nolink/6` derived from `default_await_timeout/0`, plus a small buffer so the inner `GenServer.call` (which already has timeout `default_await_timeout()` per `:57, :60`) gets to finish and return its `{:error, ...}` before the stream kills the task.

```elixir
Task.Supervisor.async_stream_nolink(
  JidoClaw.Memory.Consolidator.TaskSupervisor,
  candidates,
  fn scope -> run_now(scope) end,
  max_concurrency: max_concurrency,
  on_timeout: :kill_task,
  timeout: default_await_timeout() + 5_000,
  ordered: false
)
|> Stream.run()
```

Two cleanups baked into the same edit:

- **Drop `async: true`** from the `run_now/2` call (line 84). The exploration confirmed `run_now/2` does not consult `opts[:async]` — it is dead code and misleading.
- **Update the docstring at lines 49-50** so it no longer documents `:async`. The remaining options (`:await_ms`, `:override_min_input_count`, `:fake_proposals`) stay.

**Why not implement true async dispatch with a separate semaphore?** The reviewer's secondary suggestion ("implement true async dispatch with separate backpressure") is a bigger refactor and changes runtime semantics. The minimal fix — explicit timeout matching the inner call — restores correct backpressure for the cadence loop, since `max_concurrency` will only free a slot when the inner run actually finishes (or hits its own 660s timeout). Defer the larger refactor.

## Fix 2 (P2) — Disable Forge.Persistence in the consolidator regression test

**File:** `test/jido_claw/memory/consolidator/run_server_test.exs`

**Change in setup (lines 24-51):** Mirror `test/jido_claw/forge/clustering_test.exs:58-73`. Save the existing `JidoClaw.Forge.Persistence` config, set `enabled: false` for the test, and restore in `on_exit/1` *before* `stop_owner/1`.

Insert after line 32 (`Sandbox.start_owner!`):
```elixir
prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
```

Update `on_exit/1` (lines 44-48) to restore persistence first:
```elixir
on_exit(fn ->
  Application.put_env(:jido_claw, @consolidator_key, prev)
  Application.put_env(:jido_claw, :consolidator_advisory_lock_disabled?, false)
  Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
  Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
end)
```

**Why this is the right shape:** `persist/1` is the only path in the post-`commit_proposals` chain that touches `JidoClaw.Repo` (per the trace through `harness.ex:576/584/595/597/621/634`). `Forge.Persistence.enabled?` is read at every call (no caching), so flipping the env flag eliminates every leaking Repo write. The harness Task and Manager.stop_session still complete in the background, but their non-DB work is harmless and does not race the sandbox.

**Why not drain `Forge.Manager.list_sessions/0` in `on_exit/1` instead?** That's a stricter fix but it doesn't address `:iteration_complete` casts that may already be queued, and it duplicates the `eventually` logic already used at `run_server_test.exs:269-315`. Disabling persistence is a one-line semantic change that matches what other Forge regression tests already do.

**Verify the existing `:269-315` test still passes** — that test specifically asserts "Forge session is eventually stopped after every covered exit path", which is independent of persistence. With persistence off, the session lifecycle still happens; only the DB writes are suppressed.

## Critical Files

| File | Change |
| --- | --- |
| `lib/jido_claw/memory/consolidator.ex` | Add `:timeout` to `async_stream_nolink`, drop dead `async: true` arg, fix `:async` doc |
| `test/jido_claw/memory/consolidator/run_server_test.exs` | Disable `JidoClaw.Forge.Persistence` in setup, restore in `on_exit` |

Reused (no edits):
- `test/jido_claw/forge/clustering_test.exs:58-73` — pattern to mirror for P2
- `JidoClaw.Memory.Consolidator.default_await_timeout/0` (`consolidator.ex:116-124`) — already returns the right number for P1

## Verification

1. `mix compile --warnings-as-errors` — no new warnings.
2. `mix format --check-formatted` — confirm formatter is happy.
3. `mix test test/jido_claw/memory/consolidator/run_server_test.exs` — full file passes **with no `DBConnection.ConnectionError owner exited` lines** in the stderr/log output. Capture stderr (`2>&1`) and grep for `ConnectionError` and `Forge.Harness terminating` to confirm silence.
4. `mix test test/jido_claw/memory/consolidator_test.exs` — the consolidator unit tests still pass (these don't exercise `tick/0` but should be sanity-checked since we touched the module's public docstring).
5. **Targeted P1 sanity check (manual, in `iex -S mix`)**: invoke a synchronous run that exceeds 5s using the fake harness with `harness_options: [timeout_ms: 8_000]` plus an artificial delay, and confirm the cadence path no longer kills tasks at 5s. (This is a one-time manual verification; a permanent regression test for the timeout would require fixturing slow runs — defer unless the reviewer asks for it.)
6. `mix test` — full suite green; spot-check that Forge stderr noise from this file is gone.

## Out of Scope

- True async dispatch with a separate backpressure semaphore for `tick/0`. The reviewer flagged it as an alternative; the minimal fix is sufficient for v0.6.
- Adding a regression test for the cadence-stream timeout. Would require fixturing a slow `run_now/2` and exercising `tick/0`, which currently has no test coverage. Defer.
- Touching `cadence: enabled: false` default — leave gated until cadence runs are validated end-to-end.
