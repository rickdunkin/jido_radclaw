# v0.5.3.1 — `/servers` REPL, `jido status` SSH segment, Auto-Reconnect

## Context

v0.5.3 shipped the SSH backend wiring (registry, lazy session cache, structured errors, profile integration). It explicitly deferred three actionable items into a follow-up "v0.5.3.1," all of which touch the same surface (`SessionManager` SSH cache + `ServerRegistry`) so they bundle naturally:

1. `/servers` REPL command — there's no user-facing way today to list declared servers, see their auth mode, or do a quick connectivity check; users have to read `.jido/config.yaml` and trial-run `run_command`.
2. `jido status` SSH session count — the introspection command shows agents/uptime/forge/profile but is silent on cached SSH sessions, so a user can't tell whether a long-lived `staging` session is still attached.
3. Auto-reconnect on a dropped SSH session — the existing self-heal in `ensure_ssh_session/4` (`lib/jido_claw/shell/session_manager.ex:604`) only catches the case where the SSH owning *process* is dead at the next `run/4`. If the process is alive but the underlying TCP/channel is dead, the next command currently surfaces the failure to the user instead of transparently reconnecting.

Roadmap entry: `docs/ROADMAP.md` lines 265–273. Follows v0.5.4 chronologically; the version number reflects the milestone the items follow up on.

## Approach

Three independent changes, each small and self-contained. No upstream `jido_shell` changes — all work is JidoClaw-side. No new modules; everything extends existing files.

---

### Part 1 — `/servers` REPL command

Mirror the `/profile` pattern in `lib/jido_claw/cli/commands.ex` exactly (clauses around line 659–668, helpers around line 805–890).

**Files to modify:**

- `lib/jido_claw/cli/commands.ex` — add `handle("/servers " <> rest, state)` and `handle("/servers", state)` clauses near the `/profile` clauses; add private helpers (`list_servers/1`, `test_server/2`, `print_servers_usage/1`) near the profile helpers.
- `lib/jido_claw/cli/branding.ex` — add a `Servers` section to `help_text/0` between `Platform` (line 188) and the closing border (line 193), matching the 51-visible-char-wide format exactly.

**Sub-commands** (per roadmap):

| Form | Behavior |
|---|---|
| `/servers` | alias for `list` |
| `/servers list` | table of declared servers |
| `/servers current` | alias for `list` (servers don't have an "active" notion, but the alias matches the `/profile` shape) |
| `/servers test <name>` | one-off connectivity check |
| anything else | print usage |

**`list_servers/1`** — render one row per declared server. The third column is **auth status**, not "reachability" (we don't open a connection here — we only validate that whatever credential the entry declares can be located). For each name from `ServerRegistry.list/0`, fetch the entry via `ServerRegistry.get/1` and compute:

- `auth_kind: :default` → `:unchecked`. Delegates to ssh-agent / default key discovery; we have nothing to validate at list time. (Honest signal: "we didn't check, you'll find out when you try.")
- `auth_kind: :password` → call `ServerRegistry.resolve_secrets/1`. `{:ok, _}` → `:ok`; `{:error, {:missing_env, _}}` → `:missing_env`. `resolve_secrets/1` reads the env var **value** to verify presence; the value itself is never rendered (we only check that `getenv/1` returns a non-nil/non-empty result).
- `auth_kind: :key_path` → call `File.read(ServerRegistry.resolve_key_path(entry.key_path, project_dir))` and discriminate the result:
  - `{:ok, _}` → `:ok` (and discard the contents — the read is purely a probe).
  - `{:error, :enoent}` → `:missing_key`.
  - `{:error, _other}` → `:unreadable_key` (covers `:eacces`, `:eisdir`, etc.).
  This matches what the SSH backend ultimately does (`Jido.Shell.Backend.SSH` reads the key file via `File.read/1`); using `File.exists?/1` would let an unreadable file render as `ok` and surprise the user at use time.

Render format (mirrors `/profile`'s `▸` bullet style at `commands.ex:824`):

```
  ▸ staging  deploy@web01.example.com:22  key_path  ok           1 env var
  ▸ prod     ops@prod.example.com:22      password  missing_env  3 env vars
  ▸ legacy   admin@legacy.example.com:22  default   unchecked    0 env vars
```

Don't dump the entry's `env` map inline — that bloats the table on workspaces with many env vars and forces a redaction pass on every row. Show only the count (`<n> env var(s)`) per row. A future `/servers <name>` detail view (out of scope) can render the full env through `Redaction.Env.redact_value/2`.

Column header (printed once before the rows): `name  user@host:port  auth  status  env`.

**ANSI + column alignment:** compute column widths from the **raw** (uncolored) values, then `String.pad_trailing/2` each cell while it's still raw, and only afterwards wrap selected cells in ANSI escapes. Padding a string that already contains escape sequences counts the invisible bytes against the width and the table goes ragged. Keep ANSI scoped to the bullet (`▸`), the `name`, and the `status` cell (green `ok`, red `missing_env|missing_key|unreadable_key`, yellow `unchecked`); leave `user@host:port`, `auth`, and the env-count column plain — they don't need color and dodge the padding/ANSI interaction entirely.

**`test_server/2`** — drive `SessionManager.run(state.session_id, "echo ok", 5_000, project_dir: state.cwd, backend: :ssh, server: name)`. The path already returns `SSHError`-formatted strings on failure, so no new dispatch. Print `✓ <name> reachable` on `{:ok, _}` and `✗ <name>: <message>` on `{:error, message}`. Note that this **caches** the session as a side effect (because `SessionManager` always lazy-caches successful builds) — that's the documented behavior, consistent with how a real `run_command` against this server would behave.

**REPL struct** — no change. Servers are read-only catalog data; read fresh from `ServerRegistry` on each invocation. Adding a `:servers` field would only matter if there were a "switch" notion, and there isn't.

**Redaction** — call `JidoClaw.Security.Redaction.Env.redact_value/2` on any env value rendered, mirroring `commands.ex:852`. `password_env` (the variable *name*) is safe to print verbatim; the value of that env var is read by `resolve_secrets/1` only to verify presence and never rendered.

---

### Part 2 — `jido status` SSH session count (workspace-scoped)

**Files to modify:**

- `lib/jido_claw/shell/session_manager.ex` — add public `count_active_ssh_sessions/1` taking a `workspace_id` plus matching `handle_call/3` returning the count of cache entries whose key matches `{workspace_id, _}`. Place near `cwd/1` (line 156) and `invalidate_ssh_sessions/1` (line 230).
- `lib/jido_claw/shell/commands/jido.ex` — extend the snapshot in `emit_status/2` (line 77) with `ssh_sessions: ssh_session_count(state)`. Reuse the existing `workspace_id_from_state/1` helper (line 155) so the count corresponds to *this* shell session's workspace, matching the profile pattern. Defensive helper:

  ```elixir
  defp ssh_session_count(state) do
    case workspace_id_from_state(state) do
      nil -> 0
      ws ->
        case Process.whereis(JidoClaw.Shell.SessionManager) do
          nil -> 0
          _pid -> JidoClaw.Shell.SessionManager.count_active_ssh_sessions(ws)
        end
    end
  catch
    :exit, _ -> 0
  end
  ```

  `Process.whereis` is the cheap pre-check for "process up at all"; the surrounding `catch :exit, _` handles the race where the GenServer dies between the whereis check and the call (also covers SystemLimit / Timeout / call-on-stopping-process exit shapes that don't reduce to `:noproc`).
- `lib/jido_claw/cli/presenters.ex` — add `optional(:ssh_sessions) => non_neg_integer()` to the `@spec` (line 39), `Map.get(snapshot, :ssh_sessions, 0)` defaulting to 0 for backward compat with callers that don't pass the key, and append the new line to the `header` list (line 52).

**Why workspace-scoped, not global:** the rest of the status snapshot is per-workspace (active profile is derived from `state.workspace_id`; forge sessions are global today but logically scoped). A global `map_size(state.ssh_sessions)` would mislead a user running `jido status` inside a `staging` shell session that has 1 SSH session, while another workspace independently has 5 — they'd see "6 active" without context. Per-workspace counts match the rest of the surface.

**Format** — slot in directly after `"  profile     #{profile}"` (line 56). The 12-char label column convention: `ssh` is 3 chars + 9 spaces = 12. Match the existing `forge       <n> active session(s)` wording for symmetry:

```
  ssh         <n> active session(s)
```

"Active" here means "cached" (matches the existing `forge` semantics — neither filters by liveness). Avoids an O(N) `session_alive?/1` check on every status read.

---

### Part 3 — Bounded auto-reconnect on dropped SSH sessions

**File to modify:** `lib/jido_claw/shell/session_manager.ex`

**Wrap `handle_ssh_run/6`** (line 390–411) with one retry attempt. The current shape:

```elixir
case ensure_ssh_session(...) do
  {:ok, session_id, entry, new_state} ->
    result = with_optional_stream(session_id, opts, fn streaming? ->
               execute_ssh_command(session_id, command, timeout, entry, streaming?, opts)
             end)
    {:reply, result, new_state}
  ...
end
```

becomes a small recursion with `retries_left` capped at 1:

```elixir
defp run_ssh_with_retry(workspace_id, server, command, timeout, opts, project_dir, state, retries_left) do
  case ensure_ssh_session(workspace_id, server, project_dir, state) do
    {:ok, session_id, entry, new_state} ->
      raw = with_optional_stream(session_id, opts, fn streaming? ->
              execute_ssh_command(session_id, command, timeout, entry, streaming?, opts)
            end)

      cond do
        retries_left > 0 and transport_drop?(raw) ->
          Logger.debug("[SessionManager] SSH transport drop on #{workspace_id}/#{server}, retrying once")
          evicted = evict_ssh_session(workspace_id, server, new_state)
          # IMPORTANT: return the recursive call's tuple directly — don't fall
          # through to `{:reply, ..., new_state}` below. The retry's state
          # (post-eviction, possibly with a fresh cache entry from the rebuild)
          # is the authoritative one to thread back to handle_call.
          run_ssh_with_retry(workspace_id, server, command, timeout, opts, project_dir, evicted, retries_left - 1)

        true ->
          {:reply, format_if_retry_raw_error(raw, entry), new_state}
      end

    {:error, message, new_state} ->
      {:reply, {:error, message}, new_state}
  end
end
```

**State threading note for the implementer.** The retry recursion is the only place in `handle_ssh_run` where state can fork: pre-eviction `new_state` (still holds the dead cache entry) versus the recursive call's returned state (post-eviction, possibly with a fresh entry). It's easy to accidentally write `{:reply, formatted, new_state}` after the recursive call and discard the eviction. Don't — the recursive call returns the full `{:reply, _, _}` tuple already, return it as-is.

**Outer `GenServer.call` timeout budget.** The current SSH call timeout is `timeout + connect_timeout + 5_000` (`session_manager.ex:103–137`). With the retry, worst case is two attempts:

```
attempt 1: ensure_ssh_session (≤ connect_timeout) + execute_ssh_command (≤ timeout)
attempt 2: ensure_ssh_session (≤ connect_timeout) + execute_ssh_command (≤ timeout)
```

So the outer call must budget `2 × (timeout + connect_timeout) + slack`. Restructure `compute_call_timeout/2` (replacing the existing `call_timeout = timeout + call_timeout_extra(opts)` line at `session_manager.ex:105`):

```elixir
defp compute_call_timeout(timeout, opts) do
  case Keyword.get(opts, :backend) do
    :ssh ->
      connect = ssh_connect_timeout_lookup(opts)
      # Budget for one bounded retry: 2 attempts × (command + connect) + slack.
      2 * (timeout + connect) + 5_000
    _ ->
      timeout + 5_000
  end
end
```

`ssh_connect_timeout_lookup/1` is the existing `ssh_call_timeout_extra/1` minus the `+ 5_000` slack — refactored to return the raw `connect_timeout` (or `@default_connect_timeout`) so it composes cleanly. The eviction step (`ShellSession.stop/1` + `Map.delete`) is microseconds; the slack comfortably covers it.

**Detecting a transport drop without losing the formatted-error semantics.** Today, `execute_ssh_command/6` (line 1103) routes errors through `SSHError.format/2` *inside* itself (lines 1131, 1190, 1193) — so by the time `handle_ssh_run` sees the result, transport-shaped `%Jido.Shell.Error{}` structs have already been collapsed to user-facing strings. Two error paths already preserve the raw struct (`output_limit_exceeded` at line 1182, the synchronous run rejection branch when reason is a struct), so there's precedent.

Minimum-delta change: add **one** clause in `do_collect_ssh/6` (line 1154) before the generic format clause at line 1189, and adjust the synchronous-rejection branch at line 1126:

```elixir
# In do_collect_ssh — preserve raw for retry classification
{:jido_shell_session, ^session_id,
 {:error, %Jido.Shell.Error{code: {:command, code}} = error}}
when code in [:start_failed, :crashed] ->
  {:error, error}

# Existing generic format clause stays for everything else.
```

```elixir
# In execute_ssh_command's synchronous-rejection branch (line 1126)
{:error, %Jido.Shell.Error{code: {:command, code}} = err}
when code in [:start_failed, :crashed] ->
  if streaming?, do: JidoClaw.Display.abort_stream(session_id)
  {:error, err}

{:error, reason} ->
  if streaming?, do: JidoClaw.Display.abort_stream(session_id)
  {:error, SSHError.format(reason, entry)}
```

`format_if_retry_raw_error/2` then formats only the codes the retry path *just added* raw-preservation for, so the existing `:output_limit_exceeded` raw-error contract (relied on by `RunCommand` to render `context.preview`) stays intact:

```elixir
defp format_if_retry_raw_error({:error, %Jido.Shell.Error{code: {:command, code}} = err}, entry)
     when code in [:start_failed, :crashed],
     do: {:error, SSHError.format(err, entry)}

defp format_if_retry_raw_error(other, _entry), do: other
```

A broader `format_if_raw_error/2` clause that matched any `%Jido.Shell.Error{}` would fold `:output_limit_exceeded` (preserved at `session_manager.ex:1182` so `RunCommand` can render the streamed preview) into a string and break that path silently. Keep the narrowing tight to just the codes this milestone introduces — `:start_failed` and `:crashed`.

**`transport_drop?/1` — narrow positive allowlist** focused on the actual gap the retry exists to close: cached session whose process is alive but whose channel/exec layer is dead.

```elixir
defp transport_drop?({:error, %Jido.Shell.Error{code: {:command, code}, context: ctx}})
     when code in [:start_failed, :crashed] do
  retryable_reason?(get_in(ctx, [:reason]))
end
defp transport_drop?(_), do: false

# ShellSessionServer.do_run_command/3 wraps backend %Error{} in another :start_failed.
# Unwrap one level (mirrors SSHError.format/2 unwrap at ssh_error.ex:47).
defp retryable_reason?(%Jido.Shell.Error{} = inner),
  do: transport_drop?({:error, inner})

# Alive-process / dead-channel shapes — the actual gap this retry closes.
defp retryable_reason?(:exec_failed), do: true
defp retryable_reason?({:channel_open_failed, _}), do: true
defp retryable_reason?(:closed), do: true
defp retryable_reason?(:noproc), do: true

# Explicitly NOT retried:
#   - {:ssh_connect, _} of any flavor (econnrefused / timeout / ehostunreach /
#     authentication_failed / nxdomain). The SSH backend already reconnects
#     internally when `Process.alive?(state.conn)` is false (deps/jido_shell/
#     lib/jido_shell/backend/ssh.ex:80,152). A user-side retry on top of the
#     backend's reconnect just doubles the wait without adding signal.
#   - {:missing_config, _} / {:key_read_failed, _} — config errors; non-transient.
#   - anything else.
defp retryable_reason?(_), do: false
```

This is a tighter allowlist than the previous draft. The `{:ssh_connect, *}` shapes have been removed because the upstream backend's `ensure_connected/1` already attempts a reconnect inside the same call, so when those surface to us they've already been retried once at the lower level.

**`evict_ssh_session/3`** — small helper (no public API change):

```elixir
defp evict_ssh_session(workspace_id, server_name, state) do
  key = {workspace_id, server_name}
  case Map.get(state.ssh_sessions, key) do
    %{session_id: sid} ->
      _ = Jido.Shell.ShellSession.stop(sid)
      %{state | ssh_sessions: Map.delete(state.ssh_sessions, key)}
    nil ->
      state
  end
end
```

**Test seam for `transport_drop?/1`.** Follow the existing `__host_env_for_test__/1` convention at `session_manager.ex:215–221` — add a `@doc false __transport_drop_for_test__/1` thin wrapper so the discrimination logic can be unit-tested as a pure function without exposing `transport_drop?/1` itself as part of the public surface:

```elixir
@doc false
@spec __transport_drop_for_test__(term()) :: boolean()
def __transport_drop_for_test__(result), do: transport_drop?(result)
```

Same convention, same prefix, same `@doc false` opacity. No new precedent; just one more entry in an established pattern.

**Why a positive allowlist over matching the bare code:** `:start_failed` is overloaded — `Jido.Shell.Backend.SSH` emits it for transport drops, missing config, key-read failures, AND auth rejections. Matching the bare code would silently double the wait for auth failures (auth-rejected → wait 1× → retry → auth-rejected again → wait 1× more → user sees same error). Default-deny keeps the change conservative.

**No `Process.monitor` reactive eviction** — bounded retry covers the realistic failure mode (transport drop between commands). Adding monitor-triggered eviction would expand the cache schema and only buys "compress latency from next call to *this* call," which the bounded retry already does.

---

## Critical Files

- `lib/jido_claw/cli/commands.ex` — `/servers` clauses + helpers (Part 1).
- `lib/jido_claw/cli/branding.ex` — help text Servers section (Part 1).
- `lib/jido_claw/cli/presenters.ex` — `status_lines/1` SSH segment (Part 2).
- `lib/jido_claw/shell/commands/jido.ex` — `emit_status/2` snapshot extension + workspace-scoped count (Part 2).
- `lib/jido_claw/shell/session_manager.ex` — `count_active_ssh_sessions/1` (Part 2), retry recursion + `transport_drop?/1` + `retryable_reason?/1` + `evict_ssh_session/3` + `format_if_retry_raw_error/2` + `compute_call_timeout/2` rewrite + `__transport_drop_for_test__/1` seam, plus 2 small clauses in `execute_ssh_command/6` and `do_collect_ssh/6` to preserve raw errors (Part 3).

## Reused Helpers

- `JidoClaw.Shell.ServerRegistry.list/0`, `get/1`, `resolve_secrets/1`, `resolve_key_path/2` — exposed at `lib/jido_claw/shell/server_registry.ex:125–193`. Drive the `/servers list` table.
- `JidoClaw.Security.Redaction.Env.redact_value/2` — at `lib/jido_claw/security/redaction/env.ex:62`. Same call shape as `commands.ex:852`.
- `JidoClaw.Shell.SessionManager.run/4` — for `/servers test <name>`. Already returns SSHError-formatted strings on failure.
- `Jido.Shell.ShellSession.stop/1` — used by the existing self-heal at `session_manager.ex:616`. Mirror that for `evict_ssh_session/3`.
- `JidoClaw.Shell.SSHError.format/2` — at `lib/jido_claw/shell/ssh_error.ex:39`. The retry preserves raw `%Error{}` for classification, then formats once at the boundary.
- `workspace_id_from_state/1` — `lib/jido_claw/shell/commands/jido.ex:155`. Already used for the per-workspace profile derivation; reuse for the SSH count.
- `JidoClaw.Test.FakeSSH` — existing test backend used by `test/jido_claw/shell/session_manager_ssh_test.exs`. Drives the new retry tests; needs one or two new modes (see Tests).

## Tests

- `test/jido_claw/cli/commands_servers_test.exs` (new file, mirrors `commands_profile_test.exs:1–25` setup): bare `/servers`, `list`, `current`, `test <unknown>`, `test <ok>`, malformed sub-command. Use `ServerRegistry.replace_servers_for_test/1` (already exists at `server_registry.ex:243`) for fixtures. Cases for each `auth_kind` × status combination:
  - `:default → :unchecked` (always).
  - `:password → :ok` (env var set) and `:missing_env` (env var unset / empty).
  - `:key_path → :ok` (regular file readable), `:missing_key` (path doesn't exist), `:unreadable_key` — point `key_path` at a **directory** (e.g., the test's `tmp_dir`); `File.read/1` returns `{:error, :eisdir}`. Avoids `chmod 0` games which are flaky on some CI sandboxes (root-owned containers, Windows-via-WSL setups, etc.) and don't even exercise the eacces path on systems running tests as root.

- `test/jido_claw/cli/presenters_test.exs`: extend with `:ssh_sessions` snapshot key and assert the `"  ssh         <n> active session(s)"` line renders with the right column alignment. Add a regression case: snapshot without `:ssh_sessions` key → line still emits with `0`.

- `test/jido_claw/shell/session_manager_ssh_test.exs`:
  - **`count_active_ssh_sessions/1`** — 0 with no cache; 1 after a successful run in workspace A; 0 when queried for workspace B (workspace-scoped); 0 after `invalidate_ssh_sessions/1`. Multi-workspace case: build sessions in two workspaces; assert each query returns its own count.
  - **Retry on `:exec_failed`** — extend `FakeSSH` with a "next exec returns `start_failed{:exec_failed}`, then succeed" mode. Assert: one `SessionManager.run/4` call → two `:session_channel` events (the second from the retry's rebuild) + two `:exec` events (first fails, second succeeds) + `{:fake_ssh, {:close, _}}` (eviction-triggered) + `{:fake_ssh, {:connect, _, _, _, _}}` for the rebuild. Final result `{:ok, _}`.
  - **Retry on `:channel_open_failed`** — separate FakeSSH mode: "next session_channel returns `:channel_open_failed`, then succeed." Assert two `:session_channel` attempts (the first errors, the second from the retry's rebuild succeeds), and **one** `:exec` event (from the retry attempt — the first attempt didn't reach exec). Distinguishing this case from the `:exec_failed` case is important because the failure surface differs.
  - **No retry on auth failure** — exercises the raw-error retry path while ensuring the auth shape doesn't trigger retry. Setup: build a cached session in `:normal` mode (FakeSSH connect+exec succeed). Then kill *only* the FakeSSH conn process (the underlying SSH connection process), leaving the `ShellSession` server process alive. On the next `SessionManager.run/4`:
    - `ensure_ssh_session` calls `session_alive?(session_id)` which checks `ShellSession.lookup/1` — the shell-session process is alive, so self-heal does **not** fire and no rebuild happens at the SessionManager layer.
    - `execute_ssh_command` proceeds, `ShellSessionServer.run_command` invokes the SSH backend's `execute/4`, the backend's `ensure_connected/1` sees `Process.alive?(state.conn) == false` and reconnects internally — this is the *backend's* reconnect, not ours.
    - Set FakeSSH to `:auth_fail` for that internal reconnect → backend returns `start_failed{ssh_connect, :authentication_failed}`.
    - Assert: exactly **one** new `:fake_ssh, {:connect, _, _, _, _}` event after the kill (the backend's internal reconnect attempt) — no second connect from our retry code, because `transport_drop?/1` returns false for `{:ssh_connect, :authentication_failed}`. Final reply is the formatted "authentication rejected" error.
    This test verifies (a) `transport_drop?/1` correctly filters auth out, and (b) we don't double-up on top of the backend's own reconnect-on-dead-conn behavior.
  - **Retry bounded at 1** — FakeSSH stays in `:exec_failed` mode permanently. Assert exactly two `:exec` attempts and a final formatted error.
  - **Outer call timeout adequate** — synthetic test exercising the worst case: command timeout 200ms, connect_timeout 100ms, FakeSSH delays each connect by 80ms and each exec by 150ms, force a single retry. Assert the `GenServer.call/3` returns within `2 × (200 + 100) + slack` rather than hitting the outer timeout. Guards against a future regression where the retry path's budget gets clipped.

- **Pure unit tests for `transport_drop?/1`** in `test/jido_claw/shell/session_manager_ssh_test.exs` (or a small companion file). Call through the `__transport_drop_for_test__/1` seam (see Part 3). Exhaustively cover the discrimination logic without standing up FakeSSH:
  - `{:command, :start_failed}` with `reason: :exec_failed` → true.
  - `{:command, :start_failed}` with `reason: {:channel_open_failed, :foo}` → true.
  - `{:command, :start_failed}` with `reason: :closed | :noproc` → true.
  - `{:command, :start_failed}` with `reason: {:ssh_connect, :authentication_failed | :econnrefused | :timeout | :ehostunreach | :nxdomain}` → false.
  - `{:command, :start_failed}` with `reason: {:missing_config, _}` / `{:key_read_failed, _}` → false.
  - `{:command, :start_failed}` with double-wrapped `reason: %Error{}` (the `ShellSessionServer.do_run_command/3` wrap) → recurses on inner, classification matches the inner.
  - `{:command, :crashed}` → uses same retryable_reason? logic.
  - `{:command, :timeout | :exit_code | :output_limit_exceeded}` → false.
  - `{:ok, _}` → false.
  - Strings (already-formatted errors) → false.

  Pure-function tests are cheaper, faster, and let us evolve the allowlist without re-running FakeSSH gymnastics.

- `test/jido_claw/shell/ssh_error_test.exs`: no changes needed — formatting is unchanged. Cross-check that the existing `format/2` clauses still cover the shapes the retry preserves (they do — the retry just formats *later*, with the same input).

## Verification

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/jido_claw/cli/commands_servers_test.exs
mix test test/jido_claw/cli/presenters_test.exs
mix test test/jido_claw/shell/session_manager_ssh_test.exs
mix test                                       # full suite
```

End-to-end smoke (in a project with `.jido/config.yaml` declaring at least one SSH target):

```
mix jidoclaw
> /servers
> /servers test <name>
> jido status
```

Confirm:
- `/servers` table renders with `auth` and `status` columns; `key_path` with a missing file shows `missing_key`, with a non-file (e.g., a directory) shows `unreadable_key`, intact key shows `ok`.
- `/servers test <name>` returns `✓` for a reachable host, `✗ <SSHError-formatted message>` otherwise.
- `jido status` shows the new `ssh         <n> active session(s)` line; running `/servers test` once bumps the count to 1; the count is workspace-scoped (open a second REPL in a different `cwd` — its `jido status` should show 0 SSH sessions even when the first REPL has 1).
- For the retry: harder to smoke without intentionally dropping a session mid-flight; the FakeSSH-driven tests are authoritative.

## Out of Scope

Per the roadmap (deferred from v0.5.3 / v0.5.3.1, not picked up here):

- Classifier extension for SSH (auto-route based on path prefix) — SSH stays explicit.
- Passphrase-protected SSH private keys — needs upstream `jido_shell` hook.
- SSH jump-host / bastion chains.
- Interactive/TTY-allocating sessions (`ssh -t`).
- Key management UI / secret-store integration.
- `/servers <name>` detail view (full env, full config dump) — kept separate to keep this milestone tight.
- `Process.monitor`-based reactive eviction of dropped sessions — bounded retry is sufficient.
- Active "ping" probe for `/servers list` (would open a connection per row); the third column intentionally only validates static credential state.
