# v0.5.2 — Environment Profiles

## Context

v0.5.2 is the second slice of v0.5 (Advanced Shell Integration), building on v0.5.1's custom command registry. It delivers named environment-variable sets (dev/staging/prod) that users can switch per workspace session, so the agent's shell session targets the right environment. Today `Shell.SessionManager` starts both the host and VFS sessions with `env: %{}` (nothing overlaid on OS env), and there is no user-facing way to scope env per mode — a gap that becomes painful once v0.5.3 adds SSH-to-staging/prod.

Deliverables (from ROADMAP v0.5.2):
1. `profiles:` key in `.jido/config.yaml` — map of name → env var map; profile env merges over the session's base env
2. `JidoClaw.Shell.ProfileManager` GenServer — loads profiles, tracks active-per-workspace, emits `jido_claw.shell.profile_switched`
3. REPL `/profile` command: `list`, `switch <name>`, `current`
4. Secret redaction of sensitive values in logs + `/profile current`
5. Status-bar indicator when the active profile ≠ default

---

## Design

### ProfileManager is the source of truth

Singleton GenServer keyed by `workspace_id`, independent of shell-session lifecycle. It owns three things:

- `profiles` — `%{name => env_map}`, loaded from `.jido/config.yaml` `profiles:` key at boot
- `default_env` — `profiles["default"]` (or `%{}` if unset). There is no separate `active_profile:` config key; the magic name `"default"` within `profiles:` defines the baseline that every profile inherits.
- `active_by_workspace` — `%{workspace_id => profile_name}`. Updated by `switch/2` after session env updates succeed (or immediately when no live sessions exist); does not require live sessions.

**`switch/2` does not require a live shell session.** Shell sessions are created lazily in `SessionManager.ensure_session/3` on the first `SessionManager.run/4` call (see `session_manager.ex:190`). REPL boot generates `state.session_id` but does not start shell sessions. If `switch/2` required live sessions, users couldn't preselect a profile at startup. Instead:

- `switch/2` validates the profile name, applies env to live sessions if any, and only then updates `active_by_workspace` (see the flow under Key APIs — state is not mutated on error)
- If no live sessions exist, `SessionManager.update_env/3` is a no-op returning `:ok`, so the switch still succeeds and records intent
- `SessionManager.start_new_session/3` calls `ProfileManager.active_env(workspace_id)` at creation time so new sessions inherit the recorded active profile. It tolerates `ProfileManager` not being running (e.g. isolated unit tests that start only `SessionManager`) by falling back to `%{}`

`active_env/1` returns `default_env |> Map.merge(profiles[active_name] || %{})` — profiles inherit default's keys and override. When no profile is active, returns `default_env`.

### How we mutate `state.env` on a live session

`deps/jido_shell`'s `ShellSessionServer` has no public mutator — `apply_state_updates/2` at `shell_session_server.ex:244` is private, called only from backend callbacks (the built-in `env VAR=value` command drives it via `{:state_update, %{env: new_env}}`). The mutation semantics are public contract; the external-caller path is missing.

**We runtime-patch `Jido.Shell.ShellSessionServer` + `Jido.Shell.ShellSession`** to add `update_env/2`, mirroring v0.5.1's `jido_shell_registry_patch.ex` precedent. Header notes removal trigger ("when jido_shell ships `update_env/2`"). No session rebuild — that would lose history, cancel in-flight commands, and silently break cwd.

**Drop+merge at the session boundary, NOT replace.** A profile switch must preserve ad hoc `env VAR=value` mutations the user made via the shell's built-in `env` command. The transformation on switch from profile A to profile B:

```
keys_owned_by(A) = Map.keys(default_env) ++ Map.keys(profiles[A] || %{})
keys_owned_by(B) = Map.keys(default_env) ++ Map.keys(profiles[B] || %{})
keys_to_drop    = keys_owned_by(A) -- keys_owned_by(B)
new_overlay     = default_env |> Map.merge(profiles[B] || %{})

new_state_env = state.env |> Map.drop(keys_to_drop) |> Map.merge(new_overlay)
```

This removes profile-A-only keys, adds profile-B-only keys, upserts shared keys, and leaves ad-hoc-only keys untouched. No `meta.base_env` stash in the patched state — ProfileManager owns the profile model; the server just accepts a new env map.

### Atomic update across both sessions with rollback

`SessionManager.update_env/3` takes `(workspace_id, keys_to_drop, new_overlay)`. It:

1. Reads current `state.env` from both host and VFS sessions (`ShellSessionServer.get_state/1`)
2. Computes new env for each independently (each session has its own ad hoc mutations)
3. Calls `ShellSession.update_env/2` on host; on failure returns `{:error, reason}` with no mutation
4. On host success, calls `ShellSession.update_env/2` on VFS
5. On VFS failure, rolls back host by calling `update_env` again with the pre-read host env
6. If rollback also fails, returns `{:error, {:partial, host_state: :rolled_back | :stuck, vfs_state: :unchanged}}` with details logged

This keeps live sessions consistent. ProfileManager only updates `active_by_workspace` after `update_env/3` returns `:ok`; on any error it reports up to the REPL handler without updating state.

### Redaction

`Patterns.redact/1` at `redaction/patterns.ex:25` is value-regex — good for log bodies containing API keys, but misses `DATABASE_PASSWORD=prod-cluster-01` because the value isn't a recognized pattern. The generic env-var rule at `patterns.ex:18` matches `password|secret|token|api_key|apikey` as a key-text prefix in running text, which is orthogonal to our key-name-based need.

New module `JidoClaw.Security.Redaction.Env`:

```elixir
@sensitive_suffix ~r/_(KEY|TOKEN|SECRET|PASSWORD|PASS|PAT)$/i
@sensitive_specific ~r/^(AWS_SECRET_.*|AWS_SESSION_TOKEN|DATABASE_URL|DB_URL)$/i
@url_with_creds ~r{(\w+://)([^:@/]+):([^@/]+)(@)}

def redact_env(env), do: Enum.into(env, %{}, fn {k, v} -> {k, redact_value(k, v)} end)

def redact_value(key, value) do
  cond do
    sensitive_key?(key) -> "[REDACTED]"
    String.match?(value, @url_with_creds) -> Regex.replace(@url_with_creds, value, "\\1\\2:[REDACTED]\\4")
    true -> JidoClaw.Security.Redaction.Patterns.redact(value)
  end
end
```

Covers the roadmap's `*_KEY|*_TOKEN|*_SECRET` plus `*_PASSWORD|*_PASS|*_PAT` (conservative additions; real-world env names) and URL creds (`postgres://user:pass@host/db` → `postgres://user:[REDACTED]@host/db`). `DATABASE_URL`/`DB_URL` keys mask the whole value because even the user/host can be sensitive.

### Config reload with active-profile fallback

`ProfileManager.reload/0` re-parses `.jido/config.yaml`. Before replacing any in-memory state, it **computes transitions against the OLD state**:

```
old_state = %{profiles: old_profiles, default_env: old_default, active_by_workspace: old_active}
new_state = %{profiles: new_profiles, default_env: new_default, active_by_workspace: <to compute>}

for each {workspace_id, active_name} in old_active:
  cond
    active_name in new_profiles              -> recompute overlay against new_default, update sessions
    active_name == "default"                 -> recompute against new_default, update sessions
    active_name not in new_profiles (removed)-> fall back to "default":
      - keys_to_drop  = old keys owned by (old_default ++ old_profiles[active_name]) -- new keys owned by "default"
      - new_overlay   = new_default
      - emit signal with from: active_name, to: "default", reason: "profile_removed"
      - log warning

After the loop: replace profiles / default_env in one step. `active_by_workspace` updates per-workspace as each transition succeeds (not atomically across all workspaces).
```

Computing `keys_to_drop` requires the removed profile's env, so the old profile map must remain available during the loop — hence the "compute before replace" ordering.

**Reload is best-effort per workspace, not atomic across all workspaces.** If transition for workspace A succeeds and workspace B fails, A's sessions are already mutated — rolling them back across a crashed workspace adds more failure surface than it removes. Accept the per-workspace semantic: A's `active_by_workspace` entry updates (reflecting reality), B's stays on the old (now-removed) profile name with a warning log so operators know manual intervention is needed for B. The `profiles` / `default_env` replacement happens once at the end so in-flight `switch/2` calls see a consistent view.

---

## Files

### New

| File | Purpose |
| ---- | ------- |
| `lib/jido_claw/shell/profile_manager.ex` | GenServer — template off `lib/jido_claw/reasoning/strategy_store.ex` |
| `lib/jido_claw/security/redaction/env.ex` | Key-based redactor + URL cred redactor, composes with `Patterns.redact/1` |
| `lib/jido_claw/core/jido_shell_session_server_patch.ex` | Patch: adds `handle_call({:update_env, env}, ...)` replacing `state.env` |
| `lib/jido_claw/core/jido_shell_session_patch.ex` | Patch: `ShellSession.update_env/2` client wrapper |
| `test/jido_claw/shell/profile_manager_test.exs` | Load / switch / reload / signal-emit |
| `test/jido_claw/security/redaction/env_test.exs` | Key-match / URL-cred / case-insensitivity / composition |
| `test/jido_claw/cli/commands_profile_test.exs` | REPL `/profile *` handlers via `ExUnit.CaptureIO` |
| `test/jido_claw/shell/session_manager_profile_test.exs` | Integration: env reaches `RunCommand` on host + VFS sessions; rollback |

### Modified

| File | Change |
| ---- | ------ |
| `lib/jido_claw/core/config.ex` | `profiles/1` accessor (no `active_profile/1`) alongside `strategy/1` at line 104 |
| `lib/jido_claw/shell/session_manager.ex` | New `update_env/3` (drop+merge with rollback); pass `env: ProfileManager.active_env(workspace_id)` into both `ShellSession.start` calls at lines 250-271 |
| `lib/jido_claw/application.ex` | Register `ProfileManager` **before** `Shell.SessionManager` so a SessionManager crash under `:rest_for_one` doesn't wipe `active_by_workspace` |
| `lib/jido_claw/cli/commands.ex` | Four `/profile` heads between `/strategy` (line 657) and `/classify` (line 659) |
| `lib/jido_claw/cli/repl.ex` | `:profile` field on state struct, `resolve_profile/1` mirroring `resolve_strategy/1`, call `Display.set_profile/1` from boot + `/profile switch` |
| `lib/jido_claw/display.ex` | `:profile`/`:default_profile` fields + `set_profile/1` cast + handler |
| `lib/jido_claw/display/status_bar.ex` | `profile_segment/1` optional segment, yellow when active ≠ default |
| `docs/ROADMAP.md` | Flip v0.5.2 to Complete with delivery notes |

---

## Key APIs

### `JidoClaw.Shell.ProfileManager`

```elixir
@spec list() :: [String.t()]                                  # always includes "default" (first-class, always switchable)
@spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
@spec current(String.t()) :: String.t()                       # "default" when no switch has happened
@spec switch(String.t(), String.t()) :: {:ok, String.t()} | {:error, :unknown_profile | atom()}
@spec active_env(String.t()) :: map()                         # default_env ⊕ active_overlay; %{} if neither
@spec reload() :: :ok
```

`list/0` returns `["default" | Map.keys(profiles) -- ["default"]]` sorted alphabetically after the pinned default — `"default"` is always included even when absent from `profiles:` because it's first-class and `switch/2` always accepts it.

`switch/2` flow:
1. Validate: `name == "default"` is always accepted (even when `profiles.default` is absent — resolves to empty `default_env`); any other name must exist in `profiles` (return `{:error, :unknown_profile}` otherwise)
2. Read previous active name (fallback `"default"`); **if equal to `name`, short-circuit return `{:ok, name}`** — no env rewrite, no signal (avoids duplicate signals and needless session writes on redundant switches)
3. Compute `keys_to_drop`, `new_overlay`
4. Call `SessionManager.update_env(workspace_id, keys_to_drop, new_overlay)` — if no live sessions, returns `:ok` without mutation
5. On `:ok`: update `active_by_workspace`, emit signal, return `{:ok, name}`
6. On `{:error, _}`: leave state untouched, return error up

### `JidoClaw.Shell.SessionManager.update_env/3`

```elixir
@spec update_env(String.t(), [String.t()], map()) ::
        :ok |
        {:error, :host_update_failed, reason :: term()} |
        {:error, :vfs_update_failed, rollback :: :ok | :stuck, reason :: term()}
```

Returns `:ok` (possibly a no-op) if no sessions exist for `workspace_id`. If host update fails, no side-effects. If VFS update fails after host succeeded, attempt host rollback (re-apply pre-read env); report rollback status.

**Internal helper for test injection:** The public `update_env/3` delegates to `do_update_env/4` which accepts `:host_writer` and `:vfs_writer` opts (default `&Jido.Shell.ShellSession.update_env/2`). Tests override the VFS writer to induce a post-host failure and assert rollback. The public arity stays at 3; `do_update_env/4` is `@doc false`.

### `Jido.Shell.ShellSession.update_env/2` (patched)

```elixir
def update_env(session_id, env) when is_binary(session_id) and is_map(env) do
  with {:ok, pid} <- lookup(session_id) do
    GenServer.call(pid, {:update_env, env})
  end
end
```

Server handler:

```elixir
def handle_call({:update_env, env}, _from, state) when is_map(env) do
  coerced = Enum.into(env, %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
  {:reply, {:ok, coerced}, %{state | env: coerced}}
end
```

Server replaces `state.env` verbatim — the drop+merge logic lives in `SessionManager.update_env/3`, which reads current env first and computes the replacement.

### `JidoClaw.Security.Redaction.Env`

```elixir
@spec redact_env(map()) :: map()
@spec redact_value(String.t(), String.t() | term()) :: String.t()
@spec sensitive_key?(String.t()) :: boolean()
```

`redact_value/2` is defensive: non-binary values are run through `to_string/1` before pattern matching (profile values are already coerced at config load, but log/signal call-sites may pass arbitrary terms). Suffix regex: `_(KEY|TOKEN|SECRET|PASSWORD|PASS|PAT)$`i. Specific patterns: `AWS_SECRET_*`, `AWS_SESSION_TOKEN`, `DATABASE_URL`, `DB_URL`. URL-cred regex masks password in `scheme://user:pass@host/...`.

### Signal payload

```elixir
JidoClaw.SignalBus.emit("jido_claw.shell.profile_switched", %{
  workspace_id: workspace_id,
  from: previous_name,
  to: new_name,
  key_count: map_size(new_overlay),
  reason: "user_switch"   # or "profile_removed" from reload/0 fallback
})
```

No timestamp in `data` — `Jido.Signal` stamps one itself. `reason` is a string (not atom) for CloudEvents-friendly serialization, matching the mix of string and atom payloads already in the codebase (strings safer when payloads cross process/serialization boundaries). Key *names* log to `Logger.info/1`; values never leave the ProfileManager process.

### Config schema

```yaml
# .jido/config.yaml
profiles:
  default:
    FOO: "base-value"
  staging:
    FOO: "staging-value"
    AWS_PROFILE: "staging"
```

Load-time coercion: values → strings (integers tolerated and coerced); non-string-non-integer values rejected per-key with a warn-and-skip. Non-string keys rejected. `profiles.default` is optional; absent → empty `default_env`.

### REPL `/profile` handlers

Mirror `/strategy` at `cli/commands.ex:631-657`. Dispatcher:

```elixir
def handle("/profile " <> rest, state) do
  case String.split(String.trim(rest), " ", parts: 2) do
    ["list"] -> list_profiles(state)
    ["current"] -> print_current(state)
    ["switch", name] -> switch_profile(state, String.trim(name))
    _ -> print_profile_usage(state)
  end
end
def handle("/profile", state), do: print_current(state)
```

`switch_profile/2` calls `ProfileManager.switch(state.session_id, name)`, on success updates `%{state | profile: name}` and calls `Display.set_profile(name)`, prints a two-line success message. On `{:error, :unknown_profile}` prints available names (matches `/strategy`'s error path at commands.ex:641-645). On partial-update errors prints the detailed failure.

### Status bar

In `display/status_bar.ex:33-41` segment list:

```elixir
segments = [
  {:required, " \e[36m⚕\e[0m #{model}"},
  {:required, provider},
  {:required, "#{format_tokens(total)}/#{format_tokens(context)}"},
  profile_segment(display_state),   # nil or {:optional, " \e[33m⚑ #{name}\e[0m"}
  {:optional, "#{progress_bar(pct, 10)} #{pct}%"},
  ...
]
|> Enum.reject(&is_nil/1)
```

`profile_segment/1` returns `nil` when `profile == default_profile`, preserving the existing bar for non-profile users. Yellow for visual contrast with staging/prod.

---

## Reused existing primitives

- `StrategyStore` shape (`lib/jido_claw/reasoning/strategy_store.ex`) — GenServer layout, lenient warn-and-skip, `reload/0`
- `JidoClaw.SignalBus.emit/2` — `lib/jido_claw/core/signal_bus.ex`
- `Config.deep_merge/2` — `lib/jido_claw/core/config.ex:448`
- `Patterns.redact/1` — composed into `Redaction.Env.redact_value/2` fallback branch
- `apply_state_updates/2` mutation semantics — `deps/jido_shell/lib/jido_shell/shell_session_server.ex:244-256`; the patch exposes the same `%{state | env: new_env}` transform to external callers

---

## Edge cases

- **`/profile switch` before first shell command** — `switch/2` succeeds; `active_by_workspace` updates; next lazy session start at `SessionManager.start_new_session/3` inherits via `ProfileManager.active_env/1`.
- **Mid-command switch** — Port env is frozen when the command started; next command sees new env. `update_env/3` does NOT return `:busy` on in-flight command; document precedence in command help.
- **Ad hoc `env VAR=value` between switches** — preserved by drop+merge. Only keys that were in the OLD profile and not in the NEW profile get dropped.
- **User declares `profiles.default`** — wins over implicit empty default. Deliberate.
- **Profile removed by `reload/0` while active** — fall back to `"default"`, live-update sessions with `keys_to_drop = keys_of_removed_profile`, emit signal with `reason: "profile_removed"`, log warning. Reload computes transitions against OLD state before replacing it so removed-profile keys remain computable.
- **Switching to `"default"` when `profiles.default` is absent** — always accepted; resolves to empty `default_env`. The magic name is first-class, not dependent on a YAML entry.
- **Supervisor restart** — ProfileManager is registered *before* SessionManager in the application children. Under `:rest_for_one`, a SessionManager crash restarts only SessionManager (and anything after it), preserving `active_by_workspace`. SessionManager in turn tolerates a not-yet-started ProfileManager by falling back to `%{}` for isolated unit tests.
- **Partial update** — `SessionManager.update_env/3` rolls back host on VFS failure; reports rollback status. ProfileManager does not update `active_by_workspace` on any error.
- **Non-string values in profile YAML** — ints coerced; floats/bools/lists/nil rejected per-key with a warn-and-skip (matches `strategy_store.ex:196-216`).
- **`.env` precedence** — `.env` loaded into `System.get_env` at boot; profile env overlays via Port's `:env` option. Profile env > `.env` > OS env inside shell commands. Document.
- **OS-inherited `HOME`/`PATH`** — live in host process env, not `state.env`. Redactor never sees them unless a profile explicitly lists them.
- **Redaction false negatives** — suffix-only matching; `SESSION_ID`/`USER_ID` not masked (over-redacting worse than under-redacting for a dev tool). Documented.

---

## Tests

### Unit

- `profile_manager_test.exs` —
  - `list/0` ordering with `"default"` pinned first; `"default"` included even when `profiles:` has no such key
  - `switch/2` without sessions: active map updates, no crash, subsequent `active_env/1` reflects
  - `switch/2` with sessions: env actually reaches both host + VFS session state
  - `switch/2` unknown profile: `{:error, :unknown_profile}`, state unchanged
  - `switch/2` same profile as current: short-circuits with `{:ok, name}`, no signal emitted, no session writes
  - Signal payload assertions (subscribe to `SignalBus` in test setup)
  - `reload/0` with removed-active-profile: falls back to default, emits `reason: "profile_removed"`, drops removed profile's keys from live sessions
  - `reload/0` no-op when nothing changed
  - `switch(ws, "default")` when `profiles.default` is absent → `{:ok, "default"}`
- `env_test.exs` —
  - Suffix match case-insensitivity (`my_secret`, `My_Secret`, `MY_SECRET`)
  - `_PASSWORD`, `_PASS`, `_PAT` additions all match
  - `HOME`, `PATH`, `SESSION_ID`, `USER_ID` no-op
  - URL cred redaction in `postgres://user:pass@host/db` → `postgres://user:[REDACTED]@host/db`
  - `DATABASE_URL` whole-value mask
  - Composed `Patterns.redact/1` fallback for URL with embedded `sk-...` key
  - `redact_env/1` over mixed-sensitivity map
- `commands_profile_test.exs` —
  - Four command shapes via `Commands.handle/2` + `ExUnit.CaptureIO`
  - Unknown profile: state unchanged, available names printed
  - Partial-update error surfaces in REPL output

### Integration

`session_manager_profile_test.exs` (non-async, mirrors `session_manager_jido_integration_test.exs:1-66`):

- Fixture config with `profiles: %{"default" => %{"JIDO_SMOKE" => "base"}, "staging" => %{"JIDO_SMOKE" => "staging"}}`
- Host-side: `SessionManager.run(ws, "echo $JIDO_SMOKE", _, force: :host)` before switch → `base`, after switch → `staging`
- VFS-side: `SessionManager.run(ws, "env JIDO_SMOKE", _, force: :vfs)` — note: no pipe, no grep (both would route host-side; the VFS backend runs `env` as a sandbox built-in that reads `state.env` directly). Assert the env built-in prints the expected value.
- Ad hoc preservation: `SessionManager.run(ws, "env ADHOC=kept", _, force: :vfs)`, then `ProfileManager.switch(ws, "staging")`, then `SessionManager.run(ws, "env ADHOC", _, force: :vfs)` → still `kept`
- Rollback: genuine rollback must exercise "host update OK, VFS update fails *after* pre-read." Killing the VFS session before `update_env/3` runs fails at preflight (`get_state/1`) and never mutates host — that tests preflight, not rollback. Test calls the `@doc false` `do_update_env/4` with a `:vfs_writer` stub that returns `{:error, :induced}` after host has already succeeded. Assert host env returns to pre-call state and `current/1` stays on old profile.

### Extend

- `test/jido_claw/cli/repl_test.exs` — add `resolve_profile/1` describe mirroring `resolve_strategy/1` at lines 8-27

### Skip

- No unit tests against patch files directly. Integration exercises the behaviour; patch-level unit tests couple to the patch and rot when jido_shell upstreams `update_env/2`.

---

## Verification (end-to-end smoke)

Add to `.jido/config.yaml`:

```yaml
profiles:
  default:
    JIDO_SMOKE: "base"
  staging:
    JIDO_SMOKE: "staging-value"
    AWS_SECRET_ACCESS_KEY: "AKIASMOKETESTXXXXXXX"
```

In `iex -S mix`:

```elixir
ws = "smoke-ws"
dir = File.cwd!()

# Default profile active by inheritance
SessionManager.run(ws, "echo $JIDO_SMOKE", 5_000, project_dir: dir, force: :host)
# => {:ok, %{output: "base\n", exit_code: 0}}

JidoClaw.Shell.ProfileManager.switch(ws, "staging")
# => {:ok, "staging"}

SessionManager.run(ws, "echo $JIDO_SMOKE", 5_000, project_dir: dir, force: :host)
# => {:ok, %{output: "staging-value\n", exit_code: 0}}

# VFS path, no pipe (pipes route host-side):
SessionManager.run(ws, "env JIDO_SMOKE", 5_000, project_dir: dir, force: :vfs)
# => {:ok, %{output: "JIDO_SMOKE=staging-value\n", exit_code: 0}}

JidoClaw.Shell.ProfileManager.current(ws)
# => "staging"

# Signal bus check
JidoClaw.SignalBus.subscribe("jido_claw.shell.profile_switched")
JidoClaw.Shell.ProfileManager.switch(ws, "default")
# flush() shows payload: %{workspace_id: "smoke-ws", from: "staging", to: "default", key_count: 1, reason: "user_switch"}
```

In the REPL:

1. `bin/jidoclaw` (or `mix jidoclaw`)
2. `/profile list` → `default ← active`, `staging`
3. `/profile switch staging` → success message + status bar yellow `⚑ staging` segment
4. `/profile current` → shows `JIDO_SMOKE=staging-value`, `AWS_SECRET_ACCESS_KEY=[REDACTED]`
5. Ask the agent: `run this command and print the output: env` → agent-invoked `run_command` tool sees `JIDO_SMOKE=staging-value`
6. `/profile switch default` → status bar indicator disappears

Note on smoke: the REPL has no `!` shell escape. Non-slash input routes to the agent; to exercise the shell path from the REPL use slash commands or have the agent invoke `run_command`. Direct `SessionManager.run/4` from `iex` is the cleanest manual test.

### Tests

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test test/jido_claw/shell/profile_manager_test.exs
mix test test/jido_claw/security/redaction/env_test.exs
mix test test/jido_claw/cli/commands_profile_test.exs
mix test test/jido_claw/shell/session_manager_profile_test.exs
mix test  # full suite green
```

---

## Natural slicing (optional)

One PR is feasible (~350 LOC). Commit-per-slice if preferred:

1. **Plumbing** — patch files + `SessionManager.update_env/3` (drop+merge + rollback) + `Config.profiles/1` + `Redaction.Env` + integration test (no user-visible change yet)
2. **ProfileManager + REPL** — GenServer + supervisor registration + `/profile` handlers + `Repl.:profile` field + signal emission (feature usable CLI-side)
3. **Display polish** — `Display.set_profile/1` + status bar segment + ROADMAP flip to Complete
