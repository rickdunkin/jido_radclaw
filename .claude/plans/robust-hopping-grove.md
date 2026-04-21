# v0.5.2 Code Review Fixes

## Context

v0.5.2 (Environment Profiles) has shipped and a code review flagged three P2 findings plus one open question. All three findings verified accurate against HEAD:

- Raw user values (including potential secrets) land in `Logger.warning` calls before malformed profile entries are rejected.
- `/profile current` displays the raw profile map, omitting keys inherited from the `default` profile — the command misrepresents the env the shell actually sees.
- `ProfileManager.switch/2` and `SessionManager.start_new_session/3` form a GenServer mutual-call cycle that can deadlock on concurrent profile-switch + first-shell-command, and crash `ProfileManager` under its supervisor.

The open question — the v0.5.1 ROADMAP line promising profile output in `jido status` — is resolved by honoring that commitment, because `jido status` runs inside shell sessions where `/profile` isn't reachable. The `jido_shell` command protocol already threads the session state (which carries `workspace_id`) as the first arg to `Command.run/3`, so the plumbing is existing — we just add a small `workspace_id_from_state/1` helper to keep the dispatch clauses tidy.

Intended outcome: close the three P2 findings with behavior-preserving fixes, close the ROADMAP commitment, add regression fences, and leave the v0.5.2 public surface unchanged.

---

## Fix 1 — Redact rejected profile values in warn logs (strict: type hints only)

### Problem
`lib/jido_claw/shell/profile_manager.ex` has three log sites that interpolate raw user input with `inspect/1` before skipping the entry:

- Line 437-441 (`parse_profile/3` non-map branch) — logs `inspect(other)`.
- Line 447-451 (`coerce_entry/4` non-string-key branch) — logs `inspect(key)`.
- Line 460-463 (`coerce_entry/4` non-string/non-integer value branch) — logs `inspect(value)`.

A config typo like `DATABASE_PASSWORD: [prod-secret]` or `API_TOKEN: { nested: secret }` writes the raw value.

### Approach (stricter than the initial draft)
**Never log raw rejected values.** Type hints only. No bounded-inspect fallback for "safe" keys — the policy stays simple: if we're rejecting the entry, we don't know what the value contains, so we don't log it.

- Add a private `type_hint/1` helper returning structural info (`"list/2"`, `"map/3"`, `"float"`, `"atom"`, `"tuple/N"`, `"term"`).
- Rewrite the three log sites to use `type_hint/1` for the offending value. Key-side logs also use `type_hint(key)` — a non-string key could itself be a structured term carrying data.
- Keep the profile `name` and `key` (when it's a known-good binary) in the log message so the user can find the entry.

### Files
- `lib/jido_claw/shell/profile_manager.ex` — three log sites + one private helper.

### Existing utilities to reuse
- None required — `type_hint/1` is a short helper local to the module. `JidoClaw.Security.Redaction.Env` is not used here because we never log the value at all.

---

## Fix 2 — `/profile current` shows effective env, not raw profile

### Problem
`lib/jido_claw/cli/commands.ex:843` calls `ProfileManager.get(current)`, which returns only the raw overrides for the active profile (not the merged `default_env ++ profile_overrides` that live sessions actually see). Keys inherited from `default` are missing from the display; a profile that only overrides existing default keys shows `"No variables in this profile"` while the shell has a full env.

### Approach
Replace `ProfileManager.get(current)` with `ProfileManager.active_env(state.session_id)` — which already exists (`lib/jido_claw/shell/profile_manager.ex:123`) and returns the merged map. Collapse the three-clause `case` into a size-0-vs-non-empty `cond` (the `:not_found` branch is unreachable once we use `active_env/1`, which returns `%{}` when the manager isn't running).

Not in scope: inherited-vs-override key annotation. Effective env alone closes the review finding; annotation is a UX follow-up.

### Files
- `lib/jido_claw/cli/commands.ex` — rewrite `print_profile_current/1` at line 833-863.

### Existing utilities to reuse
- `JidoClaw.Shell.ProfileManager.active_env/1` at `lib/jido_claw/shell/profile_manager.ex:123` — already tolerant of the manager not running (returns `%{}` via catch + whereis check).
- `JidoClaw.Security.Redaction.Env.redact_value/2` at `lib/jido_claw/security/redaction/env.ex:62` — unchanged from current use.

---

## Fix 3 — Break ProfileManager ↔ SessionManager deadlock via ETS mirror

### Problem
Two GenServer handlers form a mutual-call cycle:

- `ProfileManager.handle_call({:switch, ...})` (PM held) → `SessionManager.update_env/3` (acquires SM) — at `lib/jido_claw/shell/profile_manager.ex:283`.
- `SessionManager.handle_call({:run, ...})` (SM held) → `ensure_session` → `start_new_session` → `profile_env/1` → `ProfileManager.active_env/1` (acquires PM) — at `lib/jido_claw/shell/session_manager.ex:317`.

Concurrent invocations cross-lock and both wait `@default_timeout + 5_000` ms (35 s) before crashing. ProfileManager is registered `:rest_for_one` *before* SessionManager, so a PM crash cascades.

### Approach
Make ProfileManager the single writer of an ETS mirror; SessionManager reads the mirror directly. Break the cycle on the read side (SM → PM) without changing the write-side semantics — `switch/2` still blocks on `SessionManager.update_env/3` success, preserving the invariant that `active_by_workspace` only commits on success.

**Table:**
- Name stored as a module attribute: `@ets_active_env :profile_active_env` (single source of truth, easier to rename).
- `:set`, `:protected`, `:named_table`, `read_concurrency: true`. **`:protected`, not `:public`** — ProfileManager is the only writer; SessionManager reads via the named table; no external writers.

**Opt-in creation to avoid test collision (important):**
Existing `profile_manager_test.exs` uses `start_manager/1` to spawn unregistered PM instances under the same module. If `init/1` unconditionally creates a `:named_table` with name `:profile_active_env`, those test instances collide with the supervised singleton's table (Erlang permits only one `:named_table` with a given name globally).

Resolution: the mirror is **opt-in** via an init option.

- `ProfileManager.init/1` accepts `ets_mirror: true | false` (default `false`).
- `JidoClaw.Application`'s supervisor child spec for the singleton passes `ets_mirror: true` — production always has the mirror.
- Existing tests (`profile_manager_test.exs`'s `start_manager/1`) do not pass the option; their PMs skip ETS creation entirely and keep exercising the existing `GenServer.call` path via `active_env/1` (still valid — no SessionManager involved in those tests, no cycle possible).
- SessionManager's read path hard-codes the fixed name `:profile_active_env` and tolerates `:undefined` (falls back to `%{}`). Tests running against an isolated PM with no mirror see SM fall back to `%{}`, which is the correct isolated-unit behavior.
- Tests that specifically want to exercise the mirror (e.g., asserting a post-switch row lands) should go through the supervised singleton using the existing `replace_profiles_for_test/1` + `clear_active_for_test/0` test seams.

**Tuples:**
- `{workspace_id, overlay_map}` — per-workspace active overlay.
- `{:__default__, default_env}` — sentinel for workspaces with no switch yet. Present after `handle_continue(:load, ...)` completes when `ets_mirror: true`.

**Write sites (ProfileManager, all guarded by `state.ets_mirror?`):**
- `init/1` — create the table with `@ets_active_env` attribute iff `ets_mirror: true`; store the flag on state (`:ets_mirror?` field).
- `handle_continue(:load, state)` — after `{profiles, default_env} = load_from_disk(state.project_dir)`, insert `{:__default__, default_env}` using the **fresh `default_env` local** (not `state.default_env`, which is still `%{}` before the state update).
- `apply_switch/5` success branch (line ~285) — insert `{workspace_id, new_overlay}` before returning `{:ok, new_state}`.
- `transition_workspace/5` success branch (line ~355) — mirror write with the new overlay.
- `handle_call(:reload, ...)` — rewrite `{:__default__, new_default_env}` (local from `load_from_disk/1`).
- `handle_call({:replace_profiles_for_test, profiles}, ...)` — rewrite `{:__default__, default_env}` (matches existing variable name in that handler) so the test-seam sentinel stays consistent with the replaced profiles.
- `handle_call(:clear_active_for_test, ...)` — **delete workspace entries but reinsert the default sentinel**. The cleanest implementation: `:ets.delete_all_objects(@ets_active_env)` followed immediately by `:ets.insert(@ets_active_env, {:__default__, state.default_env})`. Never leave the table in a state where `:__default__` is absent — later tests reading the mirror after a clear would see `%{}` instead of the default env and silently test the wrong thing.

**Read site (SessionManager):**
Rewrite `profile_env/1` at `lib/jido_claw/shell/session_manager.ex:315-321`:

```elixir
defp profile_env(workspace_id) do
  table = JidoClaw.Shell.ProfileManager.ets_table()   # returns @ets_active_env
  case :ets.whereis(table) do
    :undefined -> %{}
    _ref ->
      case :ets.lookup(table, workspace_id) do
        [{^workspace_id, overlay}] -> overlay
        [] ->
          case :ets.lookup(table, :__default__) do
            [{:__default__, env}] -> env
            [] -> %{}
          end
      end
  end
end
```

Expose the attribute via `ProfileManager.ets_table/0` (zero-arg public function returning the attribute value) so SessionManager depends on the name through the module, not a duplicated literal.

### Alternatives rejected
- **Cast the PM→SM call** — breaks `switch/2`'s synchronous success contract.
- **Agent for the read path** — still a GenServer, still deadlock-prone under load.
- **Thread env through `run/4` opts** — invasive, leaks abstraction, touches every caller.

### Files
- `lib/jido_claw/shell/profile_manager.ex` — add opt-in ETS init + `ets_table/0` accessor + `:ets_mirror?` state field, mirror writes in 6 handlers (all guarded).
- `lib/jido_claw/shell/session_manager.ex` — rewrite `profile_env/1`.
- `lib/jido_claw/application.ex` — pass `ets_mirror: true` to the supervised `ProfileManager` child spec.

---

## Fix 4 — Close the `jido status` ROADMAP commitment via existing state plumbing

### Problem
`docs/ROADMAP.md:217` says: *"Profile output in `jido status` is deferred to v0.5.2 alongside `ProfileManager`."* v0.5.2 shipped without updating `jido status`. `jido status` runs inside shell sessions (via the v0.5.1 Command.Registry extension) where `/profile` is not reachable.

### Plumbing (corrected)
No new helper needed. `Jido.Shell.Command.run/3` already receives `%Jido.Shell.ShellSession.State{workspace_id: ...}` as its first argument — confirmed by the Zoi schema at `deps/jido_shell/lib/jido_shell/shell_session/state.ex:36` (required string) and by state construction in `Jido.Shell.ShellSessionServer.init/1` at `deps/jido_shell/lib/jido_shell/shell_session_server.ex` (around line 91-103, where `State.new(...)` runs during server init). Built-in commands like `cat`, `cd`, `env` already use `state` directly.

`JidoClaw.Shell.Commands.Jido.run/3` currently ignores its first arg (`_state`). Use the state's `workspace_id` via a small helper — cleaner than pattern-matching every `run/3` clause on `%State{}` (five clauses today, more to come as sub-commands grow):

```elixir
defp workspace_id_from_state(%Jido.Shell.ShellSession.State{workspace_id: ws}) when is_binary(ws), do: ws
defp workspace_id_from_state(_), do: nil
```

Only `emit_status/2` consumes the value; other sub-commands continue to ignore the state arg.

### Approach
1. `lib/jido_claw/cli/presenters.ex` — `status_lines/1` (line 40) reads `:profile` from the snapshot with default `"default"` and appends one header line: `"  profile     #{profile}"`.
2. `lib/jido_claw/shell/commands/jido.ex` — rename `_state` to `state` in the clauses where it's used, add `workspace_id_from_state/1` helper, thread workspace_id through `emit_status/2`, call `ProfileManager.current(workspace_id)` with `"default"` fallback when `workspace_id_from_state/1` returns `nil`.
3. `docs/ROADMAP.md:217` — update to "delivered in v0.5.2".

No `active_workspaces/0` helper. Each shell session's `state` carries its own `workspace_id`, so `jido status` always shows the profile for the session it's running in — multi-workspace safe by construction.

### Files
- `lib/jido_claw/cli/presenters.ex` — one header line in `status_lines/1`.
- `lib/jido_claw/shell/commands/jido.ex` — rename `_state` to `state` where needed, add `workspace_id_from_state/1` helper, thread `workspace_id` into `emit_status/2`, call `ProfileManager.current/1` with `"default"` fallback.
- `docs/ROADMAP.md` — update v0.5.1 note at line 217.

---

## Formatter note (not a precursor)

The reviewer noted `mix format --check-formatted` reports no `.formatter.exs`. **Do not add one as a precursor** — it's unrelated to the findings and `.formatter.exs` typically triggers repo-wide formatting churn that would contaminate these commits. Note the existing limitation in the verification section and let the user decide separately whether to add formatter config.

---

## Verification

After each fix, verify incrementally:

```bash
mix compile --warnings-as-errors
mix test test/jido_claw/shell/profile_manager_test.exs
mix test test/jido_claw/shell/session_manager_profile_test.exs
mix test test/jido_claw/cli/commands_profile_test.exs
mix test test/jido_claw/security/
mix test
```

**`mix format --check-formatted` is not run** — the project lacks `.formatter.exs`. Confirm with `ls .formatter.exs`; if truly absent, rely on `mix compile --warnings-as-errors` plus code review for style.

End-to-end manual verification inside the REPL:

```bash
# Start REPL
mix jidoclaw

# Fix 1 — malformed value does not leak into logs
#   Edit .jido/config.yaml to include: staging: { DATABASE_PASSWORD: [leak-me] }
#   Observe the warning line includes "list/1" (type hint), not "leak-me".

# Fix 2 — /profile current shows inherited defaults
#   .jido/config.yaml with default: { BASE: v } + staging: { K: s }
/profile switch staging
/profile current
#   → shows both BASE=v (inherited) and K=s.

# Fix 3 — deadlock fence (see deterministic tests below)

# Fix 4 — jido status shows profile
/profile switch staging
#   Inside a shell session, type: `jido status`
#   → header includes "profile     staging".
```

### Regression tests

**Deadlock tests (Fix 3) — two complementary coverage layers:**

1. **White-box fast-fallback when PM is gone** (deterministic, no timing):
   - `test/jido_claw/shell/session_manager_profile_test.exs` — a new test that:
     - Stops the supervised `ProfileManager` with `GenServer.stop/1` (remember: the table is `:protected` and owned by PM, so killing PM destroys the table — this is a capability of the test, not a regression).
     - Immediately calls `SessionManager.run/4` with a fresh project_dir + workspace_id.
     - Asserts the run completes quickly and the started session's env is `%{}` (no profile overlay, because the table is gone).
   - What this proves: when ETS is absent, `profile_env/1` returns `%{}` synchronously without blocking on a dead GenServer. It does NOT prove "switched profile state survives PM death" — that would require a table heir, which is out of scope for this fix. The property we care about for the deadlock finding is "SessionManager's read path never makes a GenServer call into ProfileManager", and fast completion against a dead PM is sufficient evidence.
   - Restart the supervised PM in `on_exit` so subsequent tests have a working mirror.

2. **Deterministic cycle ordering** (new file `test/jido_claw/shell/profile_manager_deadlock_test.exs`, `async: false`):
   - Starts PM + supervised SessionManager.
   - Forces a cycle attempt by:
     - Task A: `ProfileManager.switch(ws, "staging")` — this calls `SessionManager.update_env/3` inside PM's handle_call.
     - Task B (spawned *after* A is known to be mid-call via a `:sys.trace` hook or a short sleep — not ideal but bounded): `SessionManager.run(ws_fresh, "echo hi", 5_000)` on a *different* workspace_id so the SM handler proceeds past classification and hits `start_new_session`.
   - Assert: both tasks return within 2000 ms (well below any GenServer timeout).
   - Before the fix: at least one task hits the 35 s timeout path. After the fix: both complete inside 2 s.
   - Accept non-determinism in the narrow "Task A is in PM's handler when Task B starts" window — the sleep is a bounded worst-case; the white-box test above is the authoritative determinism layer.

**Other tests:**
- `test/jido_claw/shell/profile_manager_test.exs` — add three log-capture tests for Fix 1 (assert no raw value in captured output), add ETS mirror assertions for Fix 3 (post-switch the table has `{ws, overlay}`; post-`clear_active_for_test/0` the workspace entries are gone but `{:__default__, _}` remains).
- `test/jido_claw/cli/commands_profile_test.exs` — Fix 2 default-inheritance assertion (capture_io; post-switch-to-staging, output includes both `BASE` and `STAGING_KEY` lines).
- `test/jido_claw/cli/presenters_test.exs` (new or existing) — `status_lines/1` includes `"  profile     default"` by default and `"  profile     staging"` when `:profile` is set.
- Extend `test/jido_claw/shell/commands/jido_test.exs` (or add file) — pass a synthetic `%Jido.Shell.ShellSession.State{workspace_id: ws}` to `run/3` with args `["status"]`, assert `profile` line appears and follows the active profile.

---

## Commit slicing (guidance — not commit authorization)

Four orderable commits:

1. `fix: redact rejected profile values in warn logs` — Fix 1.
2. `fix: show effective profile env in /profile current` — Fix 2.
3. `refactor: break ProfileManager↔SessionManager deadlock via ETS mirror` — Fix 3.
4. `feat: surface active profile in jido status` — Fix 4 + ROADMAP correction.
