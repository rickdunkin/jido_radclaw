# Plan: Fix code-review finding — `collector_test.exs` trace-config leak

## Context

The V2-3 trace policy/sink split (`Trace.Policy` + `Trace.Sink`) is complete and a code review was run against it. The review surfaced **one** validated issue (P2) and explicitly found **no implementation-level problem** in the new `Trace.Policy` / `Trace.Sink` code itself. This plan resolves that single finding. **Completion bar: `mix precommit` passes** (the review only ran the trace test subset, so full precommit is the bar that proves done).

### The validated finding (P2)

`test/jido_claw/trace/collector_test.exs:42` (the pre-existing `by_tenant index` test) does:

```elixir
Application.put_env(:jido_claw, :trace, max_traces: 3)
```

This **replaces the whole `:trace` config** with `[max_traces: 3]`, dropping the `persist?: false` that `setup` merges in (collector_test.exs:16). Because:

- `persist?/0` defaults to `true` when the key is absent (`collector.ex:767-769`), and
- the default sink is `Trace.Sink.Postgres` (`config/config.exs:346`),

each of the test's 5 telemetry events fires an async `Persistence` cast → `TraceRun.upsert_run/2` with **no SQL sandbox owner** (this file is `async: false` but never checks out a sandbox) → `DBConnection.OwnershipError`, caught by `do_persist`'s rescue (`persistence.ex:108-112`) and logged as a warning. Result: 5 spurious ownership warnings per run. The test still passes (the ring/eviction assertions don't depend on persistence), so this is log-noise / sandbox-hygiene, not a test failure — but it is exactly the sandbox leak the plan's D4 ("`persist?` stays live") was meant to avoid.

This is a **pre-existing latent leak** (HEAD's `persist?/0` already defaulted to `true`; the new `SinkPostgres.write/2` just delegates to the same `Persistence.append/2`), surfaced by the review during verification of this plan.

### Ruled out (swept every `put_env(:jido_claw, :trace` site — no second instance)

- `trace_test.exs:350` `enabled?: false` — also replaces the whole config, but `enabled?` is snapshotted into the struct and short-circuits ingest in `handle_info` (`collector.ex:259-260`) **before** any sink write. Provably safe; left as-is (setting only `enabled?: false` is the clearest expression of that test's intent).
- `persistence_test.exs:20`, `sink/postgres_test.exs:24` — replace the config but set `persist?: true` deliberately **and** own a sandbox.
- `retention_sweeper_test.exs:154`, `collector_test.exs:263` (`with_trace_config/2`) — already use the correct `Keyword.merge(previous || [], …)` form.

## The fix (one line)

In `test/jido_claw/trace/collector_test.exs:42`, merge over the captured `previous` config (captured at line 35, which already carries `persist?: false` from `setup`) instead of replacing it:

```elixir
# before
Application.put_env(:jido_claw, :trace, max_traces: 3)
# after
Application.put_env(:jido_claw, :trace, Keyword.merge(previous || [], max_traces: 3))
```

This preserves `persist?: false`, so the 5 events take the in-memory-only path (`maybe_write_sink/3` short-circuits on `persist?()`), eliminating the DB writes and the warnings. The ring/eviction behavior is unaffected (`persist?` gates only the sink write, not the ring), so the test's existing assertions (collector_test.exs:60-63) still hold.

**Reuse, don't reinvent:** this is the exact convention already used by `with_trace_config/2` (collector_test.exs:263) and `retention_sweeper_test.exs:154` — no new pattern. (The `by_tenant index` test could alternatively be refactored to call the existing `with_trace_config([max_traces: 3], fn -> … end)` helper, which removes its hand-rolled `on_exit`/`restart_collector` boilerplate; the one-line merge is the minimal, lower-risk fix and is what this plan applies.)

## Verification

1. **Reproduce-gone check (seed-pinned)** — run the exact command where the warning was easiest to see and confirm it's gone:
   ```bash
   mix test test/jido_claw/trace/sink/postgres_test.exs test/jido_claw/trace/retention_sweeper_test.exs test/jido_claw/trace/collector_test.exs --seed 531040 --trace
   ```
   This file set + `--seed 531040` is the ordering under which the leak surfaced clearly. Expect all green with **no** `DBConnection.OwnershipError` / `[Trace.Persistence] persistence raised` lines in the output (grep the output to be sure) — the fixed `by_tenant index` test should now run clean. Then run the broader trace suite as a wider check:
   ```bash
   mix test test/jido_claw/trace test/jido_claw/trace_test.exs
   ```
2. **`mix format`** — the edited line is already format-clean (~88 cols, stays one line), but run it so the format gate is satisfied.
3. **`mix precommit`** — the completion bar. Must pass fully (compile-check zero-warnings, system-prompt check, `deps.unlock --unused`, format check, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`, full test suite). Per memory: run the **full** command, do **not** pipe through `tail`. If precommit surfaces anything the review's trace-only run didn't catch (e.g. a credo/reach/dialyzer/format finding in the new `policy.ex` / `sink*.ex` files), fix it before declaring done.

## Critical files

- Modify (one line): `test/jido_claw/trace/collector_test.exs` (line 42)

No source, config, or other test changes are required to resolve the finding.
