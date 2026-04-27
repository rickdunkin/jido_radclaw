# v0.5.3.1 Code Review Resolution Plan

## Context

A code review of v0.5.3.1 (`/servers` REPL + `jido status` SSH segment + auto-reconnect) flagged two P3 findings. After verification against the working tree:

- **Finding 1 (ETS visibility)** is **accurate**. The new `:jido_claw_ssh_sessions_active` ETS table created in `SessionManager` is `:public`, but only `SessionManager` itself ever writes to it. `:public` lets any process in the VM insert/delete rows, which (a) breaks the singleton-mirror invariant, and (b) would crash the next `sync_ssh_sessions_ets/1` cycle because the helper assumes every row is a single-element tuple `{key}` and pattern-matches with `Enum.map(fn {key} -> key end)`. The sibling `ProfileManager` mirror at `lib/jido_claw/shell/profile_manager.ex:233` already uses `:protected` for the same singleton-mirror reason.
- **Finding 2 (ROADMAP mismatch)** is **inaccurate against the current working tree**. Each of the reviewer's specific claims is contradicted by the file as it stands today:
  - Reviewer: "the milestone still says `Status: Planned`" → file line 267 says `**Status: Complete**`.
  - Reviewer: "bullets describe a `count_active_ssh_sessions/0` map-size accessor" → file line 272 says `count_active_ssh_sessions/1` ("workspace-scoped, not global"), and explicitly describes the ETS path.
  - Reviewer: "`/servers` reachability flag" → file lines 271 + 284 explicitly describe static credential validation with no connection ("Status is computed without opening a connection"; "the third column intentionally only validates static credential state").

The reviewer was almost certainly reading an earlier draft. The only ROADMAP change I'd still make is a one-line drive-by: line 272's reference to "public ETS mirror" needs to become "protected ETS mirror" once Finding 1 is applied, so the doc tracks the code.

The intended outcome: tighten the ETS table's access mode from `:public` to `:protected` (matching `ProfileManager`'s pattern), update the in-file comment that calls it "Public", and sync the one matching phrase in ROADMAP.md. Do not otherwise touch ROADMAP — Finding 2's substance does not apply.

## Changes

### 1. `lib/jido_claw/shell/session_manager.ex`

**a. Line 293 — flip the ETS access mode.**

```elixir
# Before
:ets.new(@ssh_sessions_ets, [:named_table, :public, :set, read_concurrency: true])

# After
:ets.new(@ssh_sessions_ets, [:named_table, :protected, :set, read_concurrency: true])
```

Verified safe: every write site (`:ets.insert`, `:ets.delete` at lines 318–319, plus `:ets.new` at 293) sits inside private helpers — `ensure_ssh_sessions_ets/0`, `sync_ssh_sessions_ets/1` — which are only called from `init/1` (line 286) and `put_ssh_sessions/2` → `sync_ssh_sessions_ets/1` (called from `handle_call`/`handle_info` paths). All run inside the SessionManager process. The reader path (`count_active_ssh_sessions/1`, lines 184–195) does only `:ets.whereis` + `:ets.select_count` — both read-only, both fine under `:protected`. No test or lib code references `:jido_claw_ssh_sessions_active` or `ssh_sessions_ets/0` to write.

**b. Line 59 — fix the module-level comment.**

```elixir
# Before
# Public ETS mirror of `state.ssh_sessions` keys. Lets callers …

# After
# Protected ETS mirror of `state.ssh_sessions` keys (read-only for external
# callers; writes funnel through `sync_ssh_sessions_ets/1`). Lets callers …
```

The remaining sentence (rationale about cross-GenServer reads during `handle_call`) stays as-is — still accurate.

### 2. `docs/ROADMAP.md` line 272

One phrase update for doc-code consistency:

```
The accessor reads from a public ETS mirror (`@ssh_sessions_ets`) rather than `GenServer.call`,
```

becomes

```
The accessor reads from a protected ETS mirror (`@ssh_sessions_ets`) rather than `GenServer.call`,
```

No other ROADMAP changes — Finding 2's substance does not apply to the current working tree.

### 3. No new tests

Adding a "this should fail" test that asserts external `:ets.insert` is rejected would test BEAM semantics, not our code. The `:protected` flag is itself the assertion. The existing `count_active_ssh_sessions/1` test cases at `test/jido_claw/shell/session_manager_ssh_test.exs:602-670` continue to pass under `:protected` because they only exercise the public read path through `SessionManager.run/4` writes.

## Critical Files

- `lib/jido_claw/shell/session_manager.ex` — line 59 (comment), line 293 (ETS flag)
- `docs/ROADMAP.md` — line 272 (one word: "public" → "protected")

## Reused Patterns

- `lib/jido_claw/shell/profile_manager.ex:233` is the canonical `:protected, :named_table` singleton-mirror precedent. The post-fix line 293 will use the same option list (modulo `:set` vs `:protected` ordering, which is irrelevant to ETS).

## Verification

Run from the repo root:

```bash
mix format --check-formatted lib/jido_claw/shell/session_manager.ex
mix compile --warnings-as-errors
mix test test/jido_claw/shell/session_manager_ssh_test.exs
mix test test/jido_claw/cli/commands_servers_test.exs test/jido_claw/cli/presenters_test.exs
mix test
```

All five must pass. The reviewer's verification commands already confirmed the suite is green pre-fix; post-fix the only behavior change is rejecting external writes to the ETS mirror, which no test or production caller does.

Smoke check the runtime path manually:

```bash
mix jidoclaw
# In the REPL:
/servers list           # exercises SessionManager.ServerRegistry path (no SSH session writes)
jido status             # exercises count_active_ssh_sessions/1 ETS read under :protected
```

Both should render identically to pre-fix output.

## Out of Scope

- Re-litigating Finding 2. The reviewer's specific claims do not match the working tree; flagging back to them rather than rewriting roadmap text that's already correct.
- Restructuring `sync_ssh_sessions_ets/1` to be defensive against arbitrary tuple shapes. Once writes are `:protected`, the row shape is invariant by construction.
- Touching `ssh_sessions_ets/0` (the `@doc false` accessor at line 199). It returns the table name atom; readers can still use it under `:protected`.
