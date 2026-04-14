# Plan: Resolve All Low-Priority Audit Findings (docs/TODO.md)

## Context

The April 2026 codebase audit identified 11 lower-priority issues in `docs/TODO.md`. These span tool metadata gaps, LiveView anti-patterns, Ash resource inconsistencies, and minor security hardening. None are blocking, but resolving them improves code quality, consistency, and defense-in-depth.

---

## Execution Order

Grouped by complexity. Items 1+2 are combined into a single pass since they touch the same files.

### Phase 1: One-liner fixes (Items 4, 7, 3)

**Item 4 — `String.length` to `byte_size` in git_diff.ex**
- File: `lib/jido_claw/tools/git_diff.ex` line 26-27
- Change both the check and the truncation to byte logic:
  ```elixir
  # Before:
  if String.length(output) > 15_000 do
    String.slice(output, 0, 15_000) <> "\n... (diff truncated)"

  # After:
  if byte_size(output) > 15_000 do
    binary_part(output, 0, 15_000) <> "\n... (diff truncated)"
  ```
- Note: `run_command.ex` (line 65) uses `byte_size` for the guard but still `String.slice` for truncation. `browse_web.ex` (lines 129-132) uses `byte_size` + `binary_part`. We follow `browse_web.ex`'s fully byte-consistent pattern here.
- Verify: `mix compile --warnings-as-errors`

**Item 7 — Move `Application.get_env` from render to mount in settings_live.ex**
- File: `lib/jido_claw/web/live/settings_live.ex`
- Add `ash_domain_count: length(Application.get_env(:jido_claw, :ash_domains, []))` to `mount/3` assigns (line ~9)
- Replace `length(Application.get_env(:jido_claw, :ash_domains, []))` in template (line 34) with `@ash_domain_count`
- Verify: `mix compile`, confirm settings page renders correctly

**Item 3 — Remove `IO.puts` with ANSI codes from run_skill.ex**
- File: `lib/jido_claw/tools/run_skill.ex` lines 58-60
- Delete the `IO.puts("  \e[33m...\e[0m ...")` call entirely
- The return map (lines ~93-101) already carries `skill`, `steps_completed`, `message` -- callers/Display have the data
- Verify: `mix compile`

### Phase 2: Localized LiveView and config changes (Items 5, 6, 8)

**Item 5 — Convert `<a>` to `<.link navigate=...>` in app layout**
- File: `lib/jido_claw/web/components/layouts/app.html.heex`
- Convert all 7 `<a href="...">` tags (lines 4, 8-14) to `<.link navigate="..." ...>...</.link>`
- `<.link>` is available because `layouts.ex` does `use Phoenix.Component`
- Preserve all existing `class` and `style` attributes (they pass through)
- Verify: `mix compile`, navigate between pages in browser -- confirm no full page reloads (WebSocket stays connected)

**Item 6 — Replace DashboardLive catch-all `handle_info`**
- File: `lib/jido_claw/web/live/dashboard_live.ex` lines 58-65
- Replace the catch-all with specific clauses for the known PubSub messages:
  - Forge events (2-arity tuples): `{:session_started, _id}`, `{:session_recovering, _id}`, `{:session_recovery_exhausted, _id}` -- update only `forge_sessions` assign
  - Forge events (3-arity tuple): `{:session_stopped, _id, _reason}` -- update only `forge_sessions` assign
  - Run events (3-arity tuples): `{:run_started, _id, _info}`, `{:run_completed, _id, _info}`, `{:run_failed, _id, _info}` -- update only `workflow_summary` assign
- Keep a final catch-all that is a no-op (`{:noreply, socket}`) -- no logging of unknown payloads
- This avoids unnecessary cross-domain data fetching on every message
- **Call-site audit for run events:** `RunPubSub.broadcast/2` has **zero call sites** in the current codebase. The run event tuples (`:run_started`, `:run_completed`, `:run_failed`) only appear as receivers in `RunSummaryFeed.handle_info` (lines 31-63). The subscription exists but nothing publishes to it yet. Still add the run event clauses -- they match the intended contract in `RunPubSub` and `RunSummaryFeed`, and a future commit will wire up the broadcasts
- Forge events DO fire: `broadcast_session_event` is called in `lib/jido_claw/forge/manager.ex` (lines 110, 133, 176, 201)
- **Add a focused test** that sends each expected tuple directly to the LiveView process via `send/2` to verify each clause handles it correctly without the catch-all
- Verify: `mix compile`, `mix test`, monitor dashboard while forge sessions start/stop

**Item 8 — Different signing salts**
- File: `lib/jido_claw/web/endpoint.ex` line 7 -- change `signing_salt: "jidoclaw_lv"` to `signing_salt: "jidoclaw_session"`
- Leave `config/config.exs` line 194 as `signing_salt: "jidoclaw_lv"` (LiveView salt stays)
- Note: invalidates existing session cookies (acceptable for dev/internal tool)
- Verify: `mix compile`, then confirm:
  1. Session cookie works (sign in, navigate)
  2. LiveView WebSocket connects (pages load live)
  3. UserSocket `/ws` connects -- `lib/jido_claw/web/channels/user_socket.ex:7` authenticates from the same session payload via `connect_info[:session]`, so the session salt change affects it

### Phase 3: ExecSession and Session refactors (Items 9, 10)

**Item 9 — Wire dead attributes on ExecSession (start/complete persistence refactor)**

The current flow in `record_execution_complete/5` (`persistence.ex:125`) creates the ExecSession *after* the runner finishes, then immediately completes it. Both `started_at` and `completed_at` are stamped back-to-back, giving near-zero durations. The `output` is also truncated/redacted before storage (`persistence.ex:152`), so `byte_size` on it measures stored excerpt size, not raw output.

**Scope decision:** `ExecSession` tracks **iteration completions only**, not ad-hoc `exec/3` calls. The `exec/3` path (`harness.ex:375`) is a synchronous one-shot command that already logs start/complete events. `ExecSession` models the runner iteration lifecycle (with sequence numbers, status transitions, and output capture). Add a `@moduledoc` note to `ExecSession` documenting this scope.

**Changes needed:**

1. **Pass real start timestamp through the execution lifecycle:**
   - `harness.ex:334` (`handle_call({:run_iteration, ...})`): capture `iteration_started_at = DateTime.utc_now()` before spawning the Task
   - `harness.ex:358`: include `iteration_started_at` in the `{:iteration_complete, ...}` cast tuple
   - `harness.ex:527` (`handle_cast({:iteration_complete, ...})`): extract `iteration_started_at` and pass to `record_execution_complete`
   - `persistence.ex:125`: add `started_at` parameter to `record_execution_complete/6`
   - `persistence.ex:133`: pass it as `started_at:` in the ExecSession `:start` create attrs (overriding the auto-stamp)

2. **Capture raw output size before truncation/redaction:**
   - `persistence.ex:149-155`: capture `raw_output_bytes = byte_size(output || "")` before the `truncate(Patterns.redact(...))` call
   - Pass `raw_output_bytes` as an argument to the `:complete` update

3. **Compute duration_ms in the `:complete` action:**
   - `exec_session.ex:27`: add `argument(:raw_output_bytes, :integer)` to `:complete`
   - Add Ash change to compute `duration_ms` from `DateTime.diff(now, data.started_at, :millisecond)` and set `output_size_bytes` from the argument
   - **Nil-safe:** if `data.started_at` is nil (old rows, unexpected callers), leave `duration_ms` unset rather than crashing the update
   - Could be inline `before_action` or a dedicated change module in `lib/jido_claw/forge/changes/`

4. **Update `:start` action to accept `started_at`:**
   - `exec_session.ex:20-25`: add `:started_at` to the `accept` list and remove the `set_attribute(:started_at, ...)` auto-stamp, so the caller controls the value. Keep the auto-stamp as a fallback default for callers that don't pass it

**Files:**
- `lib/jido_claw/forge/harness.ex` -- lines 334-360 (run_iteration), 527-591 (iteration_complete)
- `lib/jido_claw/forge/persistence.ex` -- lines 125-161 (record_execution_complete)
- `lib/jido_claw/forge/resources/exec_session.ex` -- actions block

**Verify:** `mix compile`, run a forge iteration, query DB: `SELECT started_at, completed_at, duration_ms, output_size_bytes FROM forge_exec_sessions ORDER BY inserted_at DESC LIMIT 1` -- `duration_ms` should reflect actual execution time, `output_size_bytes` should reflect raw (pre-truncation) output size.

**Item 10 — Consolidate duplicate Session create actions**

Collapse onto `:start` as the single primary create action. The advisory lock in `claim_session` (`persistence.ex:59-86`) already serializes access and routes between "new session" vs "reuse terminal/recoverable session" -- both paths can use `:start` safely because:
- When no existing row matches, `:start` with `upsert?` just inserts (same as `:create`)
- The field resets (`phase: :created`, `completed_at: nil`, etc.) are correct defaults for new sessions too
- The advisory lock prevents races, so upsert identity conflicts won't occur for the "new session" path

**Changes:**
- `session.ex:26-29`: remove the `:create` action entirely
- `session.ex:31`: make `:start` the `primary?(true)` action
- `session.ex` code_interface: check if `:create` is exposed (line ~13-20) and remove/update
- `persistence.ex:101-106`: change `claim_create` to call `action: :start` (or just inline into `claim_session` since both private functions now do the same thing -- call `:start`)
- Simplify: merge `claim_create` and `claim_upsert` into one private function, since they're now identical

**Files:**
- `lib/jido_claw/forge/resources/session.ex` -- actions block + code_interface
- `lib/jido_claw/forge/persistence.ex` -- lines 101-113

**Verify:** `mix compile`, `mix test` (especially forge tests), exercise session claim flow: create new session, stop it, reclaim same name -- all should work through `:start`.

### Phase 4: Tool metadata (Items 1 + 2, combined single pass)

**Items 1+2 — Add `output_schema`, `category`, and `tags` to all 27 tools**
- Files: All 27 modules in `lib/jido_claw/tools/`
- Process each file once, adding all three options to the `use Jido.Action` block
- Jido.Action fully supports all three (confirmed in `deps/jido_action/lib/jido_action.ex`)

Category mapping (from agent.ex comment groups):
| Category | Tools |
|---|---|
| `"filesystem"` | ReadFile, WriteFile, EditFile, ListDirectory, SearchCode |
| `"shell"` | RunCommand |
| `"git"` | GitStatus, GitDiff, GitCommit |
| `"project"` | ProjectInfo |
| `"swarm"` | SpawnAgent, ListAgents, GetAgentResult, SendToAgent, KillAgent |
| `"skills"` | RunSkill |
| `"memory"` | Remember, Recall |
| `"solutions"` | StoreSolution, FindSolution, NetworkShare, NetworkStatus |
| `"browser"` | BrowseWeb |
| `"reasoning"` | Reason |
| `"scheduling"` | ScheduleTask, UnscheduleTask, ListScheduledTasks |

For `output_schema`: read each tool's `run/2` return map and define matching NimbleOptions schema. Tools with branched return shapes (e.g., BrowseWeb with different actions) use the union of possible fields.

For `tags`: add read/write semantics and domain tags (e.g., `["io", "read"]`, `["vcs", "write"]`).

**Important:** `output_schema` is runtime validation, not compile-time. `mix compile --warnings-as-errors` will NOT catch bad schemas for branched tools. Need runtime verification.

**Verify:** `mix compile --warnings-as-errors`, then verify output_schema correctness in iex using the explicit tool list (no generated `tools/0` accessor exists on the agent module):
```elixir
tools = [
  JidoClaw.Tools.ReadFile, JidoClaw.Tools.WriteFile, JidoClaw.Tools.EditFile,
  JidoClaw.Tools.ListDirectory, JidoClaw.Tools.SearchCode, JidoClaw.Tools.RunCommand,
  JidoClaw.Tools.GitStatus, JidoClaw.Tools.GitDiff, JidoClaw.Tools.GitCommit,
  JidoClaw.Tools.ProjectInfo, JidoClaw.Tools.SpawnAgent, JidoClaw.Tools.ListAgents,
  JidoClaw.Tools.GetAgentResult, JidoClaw.Tools.SendToAgent, JidoClaw.Tools.KillAgent,
  JidoClaw.Tools.RunSkill, JidoClaw.Tools.Remember, JidoClaw.Tools.Recall,
  JidoClaw.Tools.StoreSolution, JidoClaw.Tools.FindSolution,
  JidoClaw.Tools.NetworkShare, JidoClaw.Tools.NetworkStatus,
  JidoClaw.Tools.BrowseWeb, JidoClaw.Tools.Reason,
  JidoClaw.Tools.ScheduleTask, JidoClaw.Tools.UnscheduleTask,
  JidoClaw.Tools.ListScheduledTasks
]

for mod <- tools do
  {mod.name(), mod.category(), mod.tags(), mod.output_schema()}
end
```
For branched tools (BrowseWeb, etc.), run through each action path and confirm the return map validates against the schema.

### Phase 5: IssueAnalysis identity (Item 11)

**Item 11 — Add identity on IssueAnalysis**
- File: `lib/jido_claw/github/issue_analysis.ex`
- Add identity block:
  ```elixir
  identities do
    identity :unique_issue_per_repo, [:repo_full_name, :issue_number]
  end
  ```
- Run `mix ash_postgres.generate_migrations` to generate the unique index migration
- This will also update the Ash snapshot under `priv/resource_snapshots/repo/github_issue_analyses/`
- **Risk**: migration fails if duplicate rows exist. Before migrating, check:
  ```sql
  SELECT repo_full_name, issue_number, COUNT(*) FROM github_issue_analyses
  GROUP BY repo_full_name, issue_number HAVING COUNT(*) > 1;
  ```
  If duplicates exist, add a data migration step to deduplicate first.
- **Files modified:** `lib/jido_claw/github/issue_analysis.ex`, generated migration in `priv/repo/migrations/`, updated snapshot in `priv/resource_snapshots/repo/github_issue_analyses/`
- Verify: `mix ash_postgres.generate_migrations`, `mix ecto.migrate`, `mix compile`, `mix test`

---

## Verification Plan

After all changes:
1. `mix compile --warnings-as-errors` -- no warnings
2. `mix format --check-formatted` -- properly formatted
3. `mix test` -- full test suite passes
4. Manual verification:
   - Navigate web dashboard between pages -- no full page reloads (Item 5)
   - Settings page shows correct domain count (Item 7)
   - Start/stop forge session, confirm dashboard updates correctly (Item 6)
   - Run a forge iteration, check `duration_ms` and `output_size_bytes` in DB (Item 9)
   - Create session, stop it, reclaim same name (Item 10)
   - Sign in, verify session + LiveView + UserSocket all work (Item 8)
5. `mix ecto.migrate` -- Item 11 migration applies cleanly
6. Runtime output_schema verification in iex using explicit module list (Item 1) -- see Phase 4 snippet

## Files Modified

| Phase | Files |
|---|---|
| 1 | `tools/git_diff.ex`, `web/live/settings_live.ex`, `tools/run_skill.ex` |
| 2 | `web/components/layouts/app.html.heex`, `web/live/dashboard_live.ex`, `web/endpoint.ex` |
| 3 | `forge/harness.ex`, `forge/persistence.ex`, `forge/resources/exec_session.ex`, `forge/resources/session.ex` + possible new change module in `forge/changes/` |
| 4 | All 27 files in `tools/` |
| 5 | `github/issue_analysis.ex` + 1 generated migration + 1 updated Ash snapshot |
