# Plan: Resolve T2-2 AgentView code-review findings (rev. 2)

## Context

The currently-unstaged "T2-2 AgentView completion" changes tenant-scope agent tracking,
Forge sessions, and workflow runs. A code review raised 13 findings; a review-of-the-review
validated most but flagged #6/#10 as overstated/conditional and #4 as biting only non-empty
tables. A second pass over the actual code (this revision) tightened the approach on seven
points — see **Reviewer corrections incorporated** below.

Decisions already made:

- **Scope handling (#1/#8/#12):** unify into one canonical scope helper + one key set, and
  drop the overloaded `workspace_id` from the **agent-tracker** scope (key on `workspace_uuid`).
- **Consolidation (#3):** when `workspace_id` is `nil` (user/project scope), run **without a
  Forge claim** (ephemeral; no persisted session row).

Grounded via Tidewave: migration `20260531191754_…` is **not applied** here; `forge_sessions`,
`workflow_runs`, and their FK-children (`forge_checkpoints`, `forge_events`,
`forge_exec_sessions`, `approval_gates`, `workflow_steps`, all `ON DELETE NO ACTION`) are
**empty**.

## Reviewer corrections incorporated

1. **Migration must clear FK children first** — Tier 2.4 now `TRUNCATE … CASCADE`s the parents
   *and* the five child tables, not a bare `DELETE FROM` (which would fail on `NO ACTION` FKs).
2. **Don't strip `workspace_id` from RuntimeOverview-feeding scopes** — `ForgeView.build/1`
   keys on `workspace_id` as the DB UUID (`forge_view.ex:72,77,98`; `nil` ⇒ all-tenant). The
   scope fix is now **agent-tracker-only**: `SwarmView`/`SwarmScope`/`AgentTracker` move to
   `workspace_uuid`; the single scope map keeps `workspace_id`(=UUID, ForgeView) **and**
   `workspace_uuid`(=UUID, SwarmView), each view reading the key it owns. No per-view split,
   and **`commands.ex:867` needs no change** (already carries both).
3. **`parent_agent_id` needs the `agent_id → parent_agent_id` mapping** — `tool_context` has
   `:agent_id`, not `:parent_agent_id` (`tool_context.ex:21`, `child/2` replaces `agent_id`).
   The canonical helper performs the same mapping `SpawnAgent` already does at register time
   (`spawn_agent.ex:213`); without it, adding the key is inert. This is an **intentional
   behavior change** (see Notes) — pinned by tests.
4. **`claim: false` is internal-only and lossy** — Tier 1.3 states explicitly that a no-claim
   run has no DB recovery/history and no `ForgeView` row, keeps the flag an internal spec key,
   and adds a test asserting no `forge_sessions` row is written.
5. **`SwarmStatus` workspace param** — Tier 1.1 realigns the schema param to `workspace_uuid`
   and routes the tool through the canonical helper (it currently omits `parent_agent_id`,
   `swarm_status.ex:48`).
6. **`RuntimeScope.normalize/2` does not filter keyword input** (`runtime_scope.ex:16`) — the
   helper passes a **map** to `require_tenant/2` so the map clause (`:18-22`) strips nils and
   non-canonical keys. Returning a keyword with nils would make scoped reads match nothing.
7. **StatusBar elapsed** — Tier 3.7 adds a `session_started_at` to `Display` state and computes
   real elapsed, rather than `Stats.uptime_seconds` (process, not session, uptime).
8. **#5 precedent** — cite both `TraceRun` *and* `TraceEvent` (`trace_event.ex:15`) as the
   global-identity precedent.
9. **Verification** — add `mix ash_postgres.generate_migrations --check` (touches Ash shape).

_Rev. 3 (implementation-detail corrections):_

10. **`request_id` stays out of the canonical key set.** `scope_keys/0` governs **filtering only**
    (`scoped_entry?/2`). `request_id` is registration metadata — layered onto `scope_opts` at the
    register call (`spawn_agent.ex:81`) and stored as `AgentEntry.request_id` (`agent_tracker.ex:203`).
    `scope_from_opts/1` and the `AgentEntry` shape are **unchanged**; ownership scope keys and
    registration metadata stay two distinct concepts.
11. **Parent filter is direct-child, not recursive.** `parent_agent_id == caller.agent_id`
    matches one level. With the default depth limit `:n_depth = 1` (`spawn_agent.ex`), children
    can't spawn grandchildren, so "direct children" == full descendant set today. Plan/tests now
    say "own **direct children**"; transitive-subtree control is an explicit non-goal unless the
    depth limit is raised (then it needs ancestor-chain traversal — a follow-up).
12. **`swarm_status` param rename is an MCP-breaking change.** Add canonical `workspace_uuid` but
    keep `workspace_id` as a documented **deprecated alias** mapped to the `workspace_uuid` scope
    key, so existing external callers don't break.
13. **No-claim runs must not advertise ownership in `:pg`.** `claim: false` also skips
    `maybe_pg_join/1`, and the "only after a successful claim" comment (`harness.ex:130`) is
    updated to name the ephemeral path — keeping the ownership invariant true.

---

## Tier 1 — Correctness

### 1. Unify the agent-tracker scope; key on `workspace_uuid`; real parent scoping (#1, #8, #12)

**One canonical key set, defined once:** make `AgentTracker.scope_keys/0` public with value
`[:tenant_id, :session_id, :session_uuid, :workspace_uuid, :parent_agent_id]` (was the private
clause at `agent_tracker.ex:371-373`, with `:workspace_id` replaced by `:workspace_uuid`).
`scope_keys/0` governs **filtering only** (`scoped_entry?/2`, `:360-369`). `scope_from_opts/1`
(`:336-346`) and the `AgentEntry` shape are **left unchanged** — `request_id` (`agent_tracker.ex:203`,
layered on at `spawn_agent.ex:81`) and other registration metadata are NOT ownership keys and must
keep flowing into the entry. `SwarmView.scope_keys/0` (`swarm_view.ex:155-157`) and
`Tools.SwarmScope` (`swarm_scope.ex:6`) delegate to it — this adds `:parent_agent_id` to SwarmScope (fixes #12) and drops the
overloaded `:workspace_id` everywhere on the tracker side.

**One scope builder** `Tools.SwarmScope.scope_from_tool_context/1`, extracted from the existing
`spawn_agent.ex:201-215` shape:

```elixir
def scope_from_tool_context(tool_context) do
  tool_context
  |> Map.put(:parent_agent_id, Map.get(tool_context, :agent_id))   # #3: agent_id -> parent
  |> JidoClaw.RuntimeScope.require_tenant(AgentTracker.scope_keys())  # map clause strips nils + non-canonical keys (#6)
end
```

Route all swarm tools through it: `spawn_agent` (both `child_count(scope_opts)` at `:150` and
`register/…` — #8 becomes correct for free), `kill_agent` (`:27,41`), `send_to_agent` (`:24`),
`get_agent_result` (`:32`), `list_agents` (`:20`, replacing the raw-`tool_context` pass so it
gains parent scoping), and `swarm_status` (replacing the `Map.take` at `swarm_status.ex:46-50`).

**SwarmView-feeding scopes must provide `workspace_uuid`** (the only behavioral edits to query
sites): add `workspace_uuid: workspace_uuid` to `shell/commands/jido.ex:87`; add a canonical
`workspace_uuid` param to `swarm_status` while retaining `workspace_id` as a **documented
deprecated alias** that maps to the `workspace_uuid` scope key (`swarm_status.ex:31` — avoids an
MCP-schema break for existing callers; `output_schema` already has `workspace_uuid`).
`commands.ex:867` and `display.ex:811-817` already carry
`workspace_uuid`; `dashboard_live.ex:113` is intentionally tenant-only (unchanged). The
spawn-limit error copy (`spawn_agent.ex:158-162`) is reworded to read as a per-scope cap.

### 2. Forge harness must not crash on `:scope_required` (#2)

`Persistence.claim_session/3` can return `{:error, :scope_required}` (`persistence.ex:507-530`)
but `Harness.stop_unclaimed_session/2` only matches `:already_claimed` (`harness.ex:136-139`) →
`FunctionClauseError`. Add a `:scope_required` clause and a catch-all mirroring
`stop_invalid_resources/2` (`harness.ex:141-147`) — log + `{:stop, {:invalid_spec, reason}}` /
`{:stop, {:claim_failed, reason}}`. Fix the `claim_session/3` docstring (`persistence.ex:55-69`).

### 3. Run workspace-less consolidation without a Forge claim (#3)

`run_server.ex:401-407` builds the spec with `workspace_id: state.scope.workspace_id`, `nil`
for `:user`/`:project` scopes (`consolidator.ex:179-209`).

- In `run_server.ex`, when `state.scope.workspace_id` is `nil`, add an **internal** spec flag
  `claim: false`. Keeping it explicit means a genuinely-missing scope on a *normal* spec still
  fails loudly via #2.
- In `harness.ex`, add a guard to `maybe_claim_session/3` (`:1305-1314`) so `%{claim: false}`
  returns `:ok` and skips the claim. The sandbox still runs; best-effort `persist(…)` writes
  already degrade gracefully (`record_session_started/2` `else` clause, `persistence.ex:19-48`).
- A no-claim run must also **skip `maybe_pg_join/1`** (so an unowned ephemeral session never
  advertises ownership in `:pg`), and the "only after a successful claim" comment
  (`harness.ex:130`) is updated to name the ephemeral path so the ownership invariant stays
  true. Verify the stop/await paths don't assume `:pg` membership for these runs.
- **Explicit trade-off (documented in code + tested):** a no-claim run has **no DB-backed
  recovery, no history row, and no `ForgeView` entry** — acceptable for random-UUID
  consolidator runs. Test asserts a `:user`-scope run completes and writes **no** `forge_sessions`
  row.

---

## Tier 2 — Schema / data safety / tests

### 4. FK-safe migration clear (#4)

`priv/repo/migrations/20260531191754_t2_2_agentview_completion.exs` adds `null: false`
`tenant_id`/`workspace_id` FKs to existing `forge_sessions` and `workflow_runs`. Prepend to
`up/0` a single FK-safe clear before the `alter table … add … null: false` blocks:

```elixir
execute("TRUNCATE forge_events, forge_checkpoints, forge_exec_sessions, forge_sessions, approval_gates, workflow_steps, workflow_runs CASCADE")
```

No-op on the current empty DB; prevents a `NOT NULL`-on-existing-rows failure on any populated
DB. Comment that this discards rows in these ephemeral runtime/history tables. (Lighter than
the `NOT VALID`→`VALIDATE` staging in `20260511144321_v064b_tenant_fk_staged.exs`, which is
overkill for disposable tables on a single-node project.)

### 5. Justify + verify the global Forge-session upsert identity (#5)

`forge/resources/session.ex:234` keeps `identity(:unique_name, [:name], all_tenants?: true)`;
`tenant_id` is absent from the `:start` action's `accept`/`upsert_fields` (`session.ex:37-63`).
The global identity is **required** by `Persistence.find_session_global/1`
(`persistence.ex:490-505`), so keep it and guarantee the precondition — matching the in-repo
precedents `Trace.Resources.TraceRun` **and** `Trace.Resources.TraceEvent` (`trace_event.ex:15`),
both of which document global identities for globally-unique-by-construction keys:

- Add a moduledoc note on `Forge.Session` stating `name` MUST be globally unique by
  construction (UUID-based), which is what makes `all_tenants?: true` safe.
- Verify every name source is UUID-based (consolidator already uses `Ecto.UUID.generate()`,
  `run_server.ex:359`); fix any caller that passes a human/short name.
- Leave `tenant_id` **out** of `upsert_fields` (correct as-is) — AshPostgres sets it from the
  `tenant:` option on insert (`persistence.ex:127-131`); including it would let a colliding
  upsert steal tenant ownership.

### 6. Add the genuinely-missing cross-tenant + parent-scope tests (#6)

Existing coverage already has cross-tenant `SwarmView`/`SwarmStatus`/`ListAgents` and a
single-agent `KillAgent` test (`test/jido_claw/swarm_view_test.exs:34,70`). Reuse its
`FakeRuntime` + `ctx/1` + `AgentTracker.reset()` helpers and add:

- `swarm_view_test.exs`: `kill_agent "all"` stops only the caller tenant's children (register
  in tenant-a + tenant-b; assert only tenant-a's `{:stop_agent, id}`).
- `swarm_view_test.exs`: **parent-scope isolation** (the #3-mapping behavior change) — an agent
  acts on its own child but not on a sibling/another subtree.
- `tools/send_to_agent_test.exs` and `tools/get_agent_result_test.exs`: return `not_found` when
  the agent exists but in another tenant (the fake trackers already tenant-gate;
  `parent_agent_id` added to `scope_opts` is ignored by those fakes, so existing tests stay green).

---

## Tier 3 — Cleanups

### 7. StatusBar shows real session elapsed (#7)

`status_bar.ex:146` `metrics(%SwarmView{})` hardcodes `"0s"`, and the live render path always
hits that clause (`display.ex:798` passes `current_swarm_view/1`). `Display` state has no start
time. Add a `session_started_at` (monotonic ms) to the `Display` struct (`display.ex:41-53`),
set it in the `{:set_scope, …}` handler (`:198-208`, when a session is established) with an
`init` fallback, and compute elapsed in `StatusBar.render/3` from `display_state` (it already
receives `display_state` as arg 1) via the existing `format_elapsed/1`. Drop the hardcoded `"0s"`.

### 9. Scope-consistent spawn count in RuntimeOverview (#9)

`runtime_overview.ex:76-87` mixes global `Stats.get()` into a per-scope snapshot. Keep
`uptime.seconds` (legitimately process-wide; label as such) but source the agent count from the
scoped `%SwarmView{}` already built in `snapshot/1` (`:38`) instead of the global
`agents_spawned` counter. Low impact on a single-tenant CLI; removes the multi-tenant leak.

### 10. Note `Display.set_scope/1` is REPL-only (#10)

Per the review-of-review this is **not** a latent bug. No behavior change: add `@doc false` + a
one-line comment on `display.ex:93-95` stating it is REPL-boot-only.

### 11. Remove the dead `RunSummaryFeed` read API (#11)

`run_summary_feed.ex:12-14` `get_summary/1` has zero callers; `DashboardLive` self-subscribes
and rebuilds `RuntimeOverview`. Recommended: delete the whole module + its supervisor entry
(`application.ex:163`) — it is a subscriber with no reader. Fallback (if the team wants to keep
the live accumulator for the future read source named in `T2-2-AGENTVIEW-COMPLETION-PLAN.md`):
delete only `get_summary/1` + its `handle_call/3`.

### 13. Debounce DashboardLive overview rebuilds (#13)

`dashboard_live.ex:71-105` has seven `handle_info` clauses, each rebuilding `RuntimeOverview`
(≥3 DB queries) with no debounce. Collapse to a single coalesced `:refresh_overview` via
`Process.send_after/3` + a pending flag, mirroring `display.ex:387-402`
(`@swarm_header_debounce`). `agents_live.ex` (5s poll) and `workflows_live.ex` (idle) unchanged;
debounce `forge_live.ex` only if trivial.

---

## Notes / behavior changes

- **Swarm-tool isolation tightens (intentional, confirmed).** With the canonical helper mapping
  `agent_id → parent_agent_id` (flat filter `parent_agent_id == caller.agent_id`), agent-invoked
  tools (`list_agents`, `swarm_status`, `kill`, `send`, `get_agent_result`) scope to the caller's
  **own direct children**. With the default depth limit `:n_depth = 1` no grandchildren exist, so
  direct-children == the full descendant set today; if the depth limit is raised, a grandparent
  reaches grandchildren only via their direct parent (transitive-subtree control is an explicit
  non-goal, deferred). The main orchestrator still reaches all its workers; cross-subtree (sibling)
  access is blocked. REPL/web human surfaces (`commands.ex`, `display.ex`, `dashboard_live.ex`)
  build scopes with no `agent_id`, so they remain session/tenant-wide. The Tier-2.6 parent-scope
  test pins both directions (acts on own child; cannot act on a sibling).
- `SwarmView`'s vestigial `workspace_id` struct field is left `nil` (display-only; `workspace_uuid`
  is the meaningful one). Forge keeps its `workspace_id` DB column / `ForgeView` key unchanged.
- Rejected for #3: making Forge first-class workspace-optional (option C) — out of scope.

## Verification

- **Static:** `mise exec -- mix compile --warnings-as-errors`,
  `mise exec -- mix format --check-formatted`, and
  `mise exec -- mix ash_postgres.generate_migrations --check` (no unexpected resource/migration
  drift from the #5 identity work).
- **Targeted tests:**
  `mise exec -- mix test test/jido_claw/swarm_view_test.exs test/jido_claw/tools/kill_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/tools/get_agent_result_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/forge/clustering_test.exs test/jido_claw/memory/consolidator/run_server_test.exs test/jido_claw/web/live/dashboard_live_test.exs`,
  then the full suite `mise exec -- mix test`.
- **#1 runtime proof (Tidewave):** register a child under a scope, then confirm
  `SwarmView.list/1` / `RuntimeOverview.snapshot/1` return it through the cleaned
  `workspace_uuid`-keyed path (previously returned 0); confirm `ForgeView` is still
  workspace-filtered via `workspace_id`.
- **#4 migration:** `mise exec -- mix ecto.migrate` succeeds on the empty DB; then insert a
  `forge_sessions` row + an FK child, re-run on a fresh DB, and confirm the `TRUNCATE … CASCADE`
  lets the `NOT NULL` adds succeed.
- **#3 consolidation:** trigger a `:user`-scope tick; confirm it completes with no
  `FunctionClauseError` and `SELECT count(*) FROM forge_sessions` stays 0 (Tidewave + `get_logs`).
- **Manual REPL (`mise exec -- mix jidoclaw`):** spawn child agents; confirm `/agents` and the
  status bar list them and show a non-`"0s"` elapsed.
