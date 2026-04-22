# v0.5.3 — SSH Backend Support

## Context

v0.5.3 adds remote command execution on declared SSH targets, completing the third step of v0.5's shell-integration arc (registry → profiles → SSH → streaming). The `Jido.Shell.Backend.SSH` module in `deps/jido_shell/lib/jido_shell/backend/ssh.ex` is already complete: full `init/1`/`execute/4`/`cancel/2`/`terminate/2` callbacks, transport events already broadcasting to subscribed pids. This release is pure JidoClaw-side wiring.

Design principle from the roadmap: **SSH is never auto-selected.** The classifier continues to choose host vs VFS only; SSH is always explicit (`backend: :ssh, server: <name>`). Local command execution is unchanged.

## Design decisions (revised)

1. **SSH sessions live in `SessionManager` state** (new `ssh_sessions` field, keyed by `{workspace_id, server_name}`), alongside host + VFS.
2. **New `JidoClaw.Shell.ServerRegistry` GenServer** parallels `ProfileManager` for config parsing, validation, and read API.
3. **`RunCommand` schema uses string-typed backend** (`"host" | "vfs" | "ssh"`). Coercion is split to match Nimble's validation order:
   - **Pre-validation** (`on_before_validate_params/1`): coerce legacy atom `:ssh` → `"ssh"` for backward-compat with any in-process callers that still pass atoms. No string→atom coercion here.
   - **Inside `run/2`** (after validation): convert the validated string to an internal atom via an explicit `case` — not `String.to_atom/1` (no dynamic atom creation). Legacy `force:` param stays untouched.
4. **Passphrase-protected keys are out of scope for v0.5.3.** `build_auth_opts/1` accepts only `:key`, `:key_path`, or `:password`; `KeyCallback.user_key/2` has no passphrase path. v0.5.3 handles encrypted keys via the user's ssh-agent (fall-through to default key discovery when neither `key_path` nor `password_env` is set).
5. **SSH collector has distinct terminal vs success paths.** Today `do_collect/4` at `session_manager.ex:596` swallows `{:error, _}` events. For SSH a new `do_collect_ssh/4`:
   - `%Error{code: {:command, :exit_code}, context: %{code: code}}` → `{:ok, %{output, exit_code: code}}` — **preserves remote non-zero exit codes**, which is the normal success-but-failed case.
   - `%Error{code: {:command, :timeout}}`, `%Error{code: {:command, :output_limit_exceeded}}`, `%Error{code: {:command, :start_failed}}`, and all other `{:error, _}` events → `{:error, format_ssh_error(error, server_entry)}`.
   - `:command_done` → `{:ok, %{output, exit_code: 0}}`.
   Host/VFS keep the existing swallow behavior — no regression.
6. **SSH profile-env updates recompute effective env from scratch** (`server.env |> Map.merge(new_profile_env)`). Drop+merge would lose server-declared vars that overlapped with the old profile; full recompute preserves server invariants. Call `Jido.Shell.ShellSession.update_env(session_id, new_effective_env)` directly — the patched `update_env/2` already replaces the full env map, no new `replace_env/2` helper needed.
7. **Lazy connect, strict fallback.** No eager SSH session at workspace bootstrap. If `SessionManager` is unavailable, SSH requests fail — **never** fall back to local `System.cmd`. Host/VFS fallback unchanged.
8. **Key paths resolved lazily** at session start against `project_dir` (threaded through `ensure_ssh_session/4`).
9. **Secrets via env-var references** (`password_env:`). Empty env vars (`""`) treated as missing.
10. **Config reload returns a diff; caller invalidates.** `ServerRegistry.reload/0` returns `{:ok, %{added, changed, removed}}` without calling into SessionManager from within the registry GenServer (avoids the SR ↔ SM deadlock: `SessionManager.run/4` already calls into `ServerRegistry.get/1` on the hot path). The caller (REPL `/servers reload`, a future hot-reload watcher) explicitly invokes `SessionManager.invalidate_ssh_sessions(added ++ changed ++ removed)` afterward. Both calls are safe serially because neither holds cross-process locks.
11. **`do_update_env_impl/5` restructure to handle SSH-only workspaces.** Today it short-circuits on `state.sessions[workspace_id] == nil` (`session_manager.ex:376`). Since SSH can be a workspace's first session, change the branch to: if `sessions[workspace_id]` AND no SSH sessions for workspace → `:ok`; else run host/VFS updates (skip block if nil) THEN SSH updates. SSH-only workspaces get profile env propagation without spurious failures.
12. **`GenServer.call` timeout accounts for SSH connect.** `SessionManager.run/4`'s call timeout is `command_timeout + 5_000` today; SSH adds up to `connect_timeout` (default 10s) before exec. When `backend: :ssh`, bump the call timeout to `command_timeout + connect_timeout + 5_000` by reading the server entry's connect_timeout before the call. Document this in `RunCommand`'s `timeout` param doc so users set generous timeouts for slow-connecting hosts.

## `servers:` YAML schema

```yaml
servers:
  - name: "staging"                  # required, non-empty, unique
    host: "web01.example.com"        # required, non-empty
    user: "deploy"                   # required, non-empty
    port: 22                         # optional int 1..65535, default 22
    key_path: "~/.ssh/id_ed25519"    # optional; absolute, ~-expanded, or project-relative
    password_env: "SSH_PROD_PW"      # optional env var name (alternative to key_path)
    cwd: "/srv/app"                  # optional, default "/"
    env:                             # optional map string→string (integers coerced)
      RAILS_ENV: "staging"
    shell: "bash"                    # optional, default "sh"
    connect_timeout: 10000           # optional int ms, default 10_000
```

Validation (per-entry warn-and-skip, modeled on `ProfileManager.parse_profile/3`):
- `name`/`host`/`user` missing or empty → drop entry with warning.
- Setting both `key_path` and `password_env` → drop entry (ambiguous auth).
- Neither set → `auth_kind: :default` (rely on user's ssh-agent / default keys).
- `port` out of range or non-integer → warn and default to 22.
- Duplicate `name` → later entry wins, warning logged.
- `env` non-map → drop the env field; per-key: integers coerced, other types dropped with a warning.
- `connect_timeout` → integer > 0, default `10_000`.

**Passphrases**: Not supported in v0.5.3. If `key_path` points at an encrypted key, connect will fail at decode time; the error message (point 6 below) will suggest using ssh-agent. Add a `ServerRegistry.moduledoc` note.

## Files

### New

**`lib/jido_claw/shell/server_registry.ex`** (GenServer, ~250 LOC)
- `start_link(opts)`, `init(opts)` with `:project_dir`. No ETS mirror — servers aren't hot-path.
- `list/0 :: [String.t()]` — alphabetical.
- `get/1 :: {:ok, ServerEntry.t()} | {:error, :not_found}`.
- `reload/0 :: {:ok, %{added: [name], changed: [name], removed: [name]}}` — re-parses disk, diffs against prior state, returns the diff. Does **not** call into `SessionManager` from inside the GenServer (deadlock risk). Caller invokes `SessionManager.invalidate_ssh_sessions/1` after the reload call returns.
- `resolve_key_path/2` — absolute passes, `~` expands against `$HOME`, relative resolves against `project_dir`.
- `resolve_secrets/1` — reads `password_env` via `getenv/1` helper treating `""` and `nil` as missing → `{:error, {:missing_env, var}}`.
- `build_ssh_config(entry, project_dir, effective_env) :: {:ok, map} | {:error, reason}` — assembles the map for `Jido.Shell.Backend.SSH.init/1`. **Test injection**: reads `Application.get_env(:jido_claw, :ssh_test_modules, %{})` and merges `:ssh_module` / `:ssh_connection_module` into the config map when set. Application env is not exposed in the YAML schema; it's set by test setup (e.g., `Application.put_env(:jido_claw, :ssh_test_modules, %{ssh_module: FakeSSH, ssh_connection_module: FakeSSHConnection})`) and unset on teardown. Pattern mirrors ProfileManager's test-seam approach.
- `replace_servers_for_test/1` — runtime public test seam matching the repo's existing convention (e.g., `ProfileManager.replace_profiles_for_test/1`). Swaps the in-memory server map without touching disk. Not compile-env gated; consistent with the rest of the codebase.
- Private `parse_servers/1` — lenient per-entry validation.
- `ServerEntry` struct: `:name, :host, :port, :user, :auth_kind (:key_path | :password | :default), :key_path, :password_env, :cwd, :env, :shell, :connect_timeout`.

**`lib/jido_claw/shell/ssh_error.ex`** (pure module, no state)
- `format(error, server_entry) :: String.t()` — the mapping table (see below). Lives here rather than as a private `SessionManager` helper so unit tests can cover every row without going through SessionManager integration.

**`test/jido_claw/shell/server_registry_test.exs`** — fixture YAML round-trips, validation edge cases, key-path resolution (absolute, `~`, project-relative), secret resolution with present/missing/empty env vars, reload diff computation.

**`test/jido_claw/shell/session_manager_ssh_test.exs`** — FakeSSH-based integration of SessionManager SSH wiring (see Test Plan).

**`test/support/fake_ssh.ex`** — adapted from `deps/jido_shell/test/jido/shell/backend/ssh_test.exs`'s FakeSSH helper, extended to model exec timeouts, non-zero exit codes, and mid-command errors.

### Modified

**`lib/jido_claw/core/config.ex`** — add thin accessor:
```elixir
def servers(config) do
  case Map.get(config, "servers") do
    list when is_list(list) -> list
    _ -> []
  end
end
```

**`lib/jido_claw/shell/session_manager.ex`**:
- Add state field: `ssh_sessions: %{}`. Entry shape: `%{session_id, server_entry, project_dir, resolved_ssh_config}` keyed by `{workspace_id, server_name}`.
- Extend `run/4` opts: `:backend` (`:host | :vfs | :ssh`), `:server` (required when `backend: :ssh`). When `:ssh`, skip classifier, call `ensure_ssh_session/4`. **Timeout**: when backend is `:ssh`, the client-side `GenServer.call` timeout is `command_timeout + connect_timeout + 5_000`. Use `ServerRegistry.get(server)` on the caller side to read the real `connect_timeout`; if the server isn't declared (lookup returns `:not_found`), fall back to a default `10_000` for the extra timeout and let `ensure_ssh_session/4` return the real "SSH server '<name>' not declared" error at call time. Host/VFS timeout unchanged.
- Add `ensure_ssh_session(workspace_id, server_name, project_dir, state) :: {:ok, session_id, state} | {:error, formatted_message, state}`:
  1. **Fast path**: entry in `ssh_sessions` whose `project_dir` matches and whose session pid is alive (`session_alive?/1`) → return existing session_id. On project_dir drift or dead pid: tear down and fall through.
  2. `ServerRegistry.get(server_name)` → `{:error, "SSH server '<name>' not declared in .jido/config.yaml"}` on miss.
  3. `ServerRegistry.resolve_secrets(entry)` → `{:error, SSHError.format({:missing_env, var}, entry)}` on missing/empty env.
  4. Effective env = `entry.env |> Map.merge(profile_env(workspace_id))`.
  5. `ServerRegistry.build_ssh_config(entry, project_dir, effective_env)` — returns the map (including test `:ssh_module` / `:ssh_connection_module` when set via Application env).
  6. `ShellSession.start(...)` with `backend: {Jido.Shell.Backend.SSH, ssh_config}`, session_id `"<workspace_id>:ssh:<server>"`.
  7. On connect error, format via `SSHError.format/2`, do not cache.
- Add `invalidate_ssh_sessions(names) :: :ok` — for every workspace, for every server_name in `names` that has a cached entry, tear down the session and remove from state. No-op for unknown names.
- Restructure `do_update_env_impl/5` to support SSH-only workspaces:
  - If `sessions[workspace_id]` is nil AND no ssh_sessions for workspace exist → `:ok`.
  - If `sessions[workspace_id]` present: run the existing host + VFS drop+merge atomicity (unchanged).
  - After host/VFS (or if nil): iterate ssh_sessions for this workspace. For each:
    - **Use the `new_overlay` argument directly** — it *is* the target composed profile env. Do **not** read `ProfileManager`'s ETS mirror here: during `ProfileManager.switch/2`, `SessionManager.update_env/3` runs before ProfileManager updates its active state/ETS, so an ETS read would see the old profile.
    - `new_effective_env = Map.merge(server_entry.env, new_overlay)` — profile wins on overlap, server-declared vars survive.
    - Call `ShellSession.update_env(session_id, new_effective_env)` — full-env replace (no drop+merge for SSH).
    - On failure: evict the session from `ssh_sessions` (next command reconnects), log a warning, continue to next SSH session. Do **not** roll back host/VFS.
  - Initial SSH session env in `ensure_ssh_session/4` also uses `new_overlay`'s in-flight equivalent: at session start, read the current profile env from `ProfileManager` (safe here — no switch in flight), then compose `server_entry.env |> Map.merge(profile_env)`.
- Extend `stop_session/1` and `drop_sessions/1`: iterate and stop SSH sessions for the workspace. Handle the case where `sessions[workspace_id]` is nil but `ssh_sessions` has entries for it (SSH can be first session).
- Add `session_alive?/1` helper (wraps `Process.alive?` + rescue).
- Add `do_collect_ssh/5(session_id, deadline, acc, exit_code, server_entry)`:
  ```
  {:jido_shell_session, ^sid, {:error, %Error{code: {:command, :exit_code}, context: %{code: code}}}} ->
    # Remote non-zero exit — success-but-failed case; preserve the actual code
    {:ok, %{output: finalize_output(acc), exit_code: code}}

  {:jido_shell_session, ^sid, {:error, error}} ->
    # timeout / output_limit_exceeded / start_failed / unknown — terminal failure
    {:error, SSHError.format(error, server_entry)}

  {:jido_shell_session, ^sid, :command_done} ->
    {:ok, %{output: finalize_output(acc), exit_code: exit_code}}

  # :output, :exit_status (for 0), lifecycle events — same as host/VFS collector
  ```
  Host/VFS keep using `do_collect/4`.

**`lib/jido_claw/tools/run_command.ex`**:
- Schema additions (string-typed to dodge the Jido tool-schema enum coercion trap):
  ```elixir
  backend: [
    type: {:in, ["host", "vfs", "ssh"]},
    required: false,
    doc: "Routing override. \"host\"/\"vfs\" bypass classifier; \"ssh\" requires server."
  ],
  server: [
    type: :string,
    required: false,
    doc: "SSH server name from .jido/config.yaml (required when backend: \"ssh\")."
  ]
  ```
- **`on_before_validate_params/1`**: runs before Nimble validates. Only task here is backward-compat coercion of legacy atom values. Handle both atom-key and string-key params (direct callers bypassing normal tool conversion):
  ```elixir
  def on_before_validate_params(params) do
    params
    |> coerce_backend(:backend)
    |> coerce_backend("backend")
    |> then(&{:ok, &1})
  end

  defp coerce_backend(params, key) do
    case Map.get(params, key) do
      atom when atom in [:host, :vfs, :ssh] -> Map.put(params, key, Atom.to_string(atom))
      _ -> params
    end
  end
  ```
  Do **not** convert strings to atoms here — Nimble would then reject `:ssh` against the string enum.
- **Inside `run/2`** (post-validation): convert the validated string to an internal atom with an explicit case, not `String.to_atom/1`:
  ```elixir
  backend_atom =
    case Map.get(params, :backend) do
      "host" -> :host
      "vfs"  -> :vfs
      "ssh"  -> :ssh
      nil    -> nil
    end
  ```
- Validate before dispatch: if `backend_atom == :ssh`, `server` must be a non-empty binary → `{:error, "server: is required when backend: \"ssh\""}`.
- **SSH fallback refusal**: when `backend_atom == :ssh` and `session_manager_available?/0` is false, return `{:error, "SSH requires SessionManager; SessionManager is not running"}` — do **not** fall through to local `System.cmd`. Local fallback continues to apply only when `backend` is absent or `:host`/`:vfs`.

**`lib/jido_claw/application.ex`** — insert between the existing `ProfileManager` entry and `SessionManager` (lines 167 and 170):
```elixir
{JidoClaw.Shell.ServerRegistry, [project_dir: project_dir()]},
```
Under `:rest_for_one`: ServerRegistry crash → SessionManager restarts, stale SSH cache cleared. ProfileManager unaffected.

## Error message mapping (`JidoClaw.Shell.SSHError.format/2`)

Takes `(error, server_entry)` so every message can interpolate host/port/user/path reliably. Authentication-specific reasons are narrow; unknown connect failures fall through to a generic "connection failed" message instead of misclassifying as auth.

| Error shape | Formatted message |
|---|---|
| `%Jido.Shell.Error{code: {:command, :start_failed}, context: %{reason: {:ssh_connect, :econnrefused}}}` | `SSH to <name> failed: connection refused at <host>:<port>` |
| `...%{reason: {:ssh_connect, :nxdomain}}` | `SSH to <name> failed: host not found (<host>)` |
| `...%{reason: {:ssh_connect, :timeout}}` | `SSH to <name> failed: connection timed out at <host>:<port>` |
| `...%{reason: {:ssh_connect, :ehostunreach}}` | `SSH to <name> failed: host unreachable (<host>)` |
| `...%{reason: {:ssh_connect, reason}}` where reason matches auth shapes (`"Unable to connect using the available authentication methods"`, `:authentication_failed`, charlist containing `"auth"`, etc.) | `SSH to <name> failed: authentication rejected for <user>@<host>` |
| `...%{reason: {:ssh_connect, reason}}` all other reasons | `SSH to <name> failed: connection failed (<inspect reason>)` |
| `...%{reason: {:key_read_failed, :enoent}, path: path}` | `SSH to <name> failed: key file not found at <path>` |
| `...%{reason: {:key_read_failed, :eacces}, path: path}` | `SSH to <name> failed: key file unreadable at <path> (check permissions)` |
| `...%{reason: {:key_read_failed, reason}, path: path}` (other) | `SSH to <name> failed: could not read key file at <path> (<reason>)` |

Note: encrypted-key decode failures may surface as connect/auth failures rather than `:key_read_failed` — file read succeeds, the decode happens inside the SSH key callback. These land in the generic "connection failed"/"authentication rejected" branches. The manual-verification step with an encrypted key covers the user-observable shape; don't overpromise that the error category will be `:key_read_failed`.
| `%Jido.Shell.Error{code: {:command, :timeout}}` | `SSH to <name> command timed out` |
| `%Jido.Shell.Error{code: {:command, :output_limit_exceeded}}` | `SSH to <name>: output limit exceeded, command aborted` |
| `{:missing_env, var}` | `SSH to <name> failed: env var <var> is not set` |
| `{:missing_config, key}` | `SSH to <name>: server entry missing required field '<key>'` |
| other `%Jido.Shell.Error{}` | `SSH to <name> failed: <Exception.message(error)>` |
| other | `SSH to <name> failed: <inspect reason>` |

Use `Exception.message/1` (not `Error.message/1`) to render `%Jido.Shell.Error{}` values — `Jido.Shell.Error` implements the `Exception` behaviour.

## PermitUserEnvironment caveat

Many OpenSSH servers default `PermitUserEnvironment no`, which silently discards `ssh_connection.setenv/5`. The backend already wraps each command as `cd <cwd> && env VAR=val <command>` (see `ssh.ex:375`), so env propagation works regardless. Document in `ServerRegistry` moduledoc.

## Verification

**Unit tests** (`mix test test/jido_claw/shell/server_registry_test.exs`):
- Parse valid/invalid entry fixtures; warn-and-skip behavior.
- `resolve_key_path/2`: absolute pass-through, `~` expands against `$HOME`, project-relative against `project_dir`.
- `resolve_secrets/1`: present → value; `nil` → missing; `""` → missing.
- Duplicate name resolution (later wins, warning).
- `reload/0` returns diff shape `{added, changed, removed}` correctly; does **not** call into SessionManager.
- `build_ssh_config/3` injects `ssh_module` / `ssh_connection_module` from Application env when set.

**SSHError unit tests** (`mix test test/jido_claw/shell/ssh_error_test.exs`):
- Every row in the mapping table.
- Auth-specific reasons classified as auth rejected; generic `{:ssh_connect, reason}` shapes classified as "connection failed".
- `<host>`, `<port>`, `<user>`, `<path>` interpolated from the passed `ServerEntry`.

**Integration tests** (`mix test test/jido_claw/shell/session_manager_ssh_test.exs`) — using FakeSSH via `Application.put_env(:jido_claw, :ssh_test_modules, ...)`:
- `run/4` with `backend: :ssh, server: "staging"`: stdout captured, exit code 0.
- **Remote non-zero exit** (`%Error{code: {:command, :exit_code}, context: %{code: 42}}`): returns `{:ok, %{exit_code: 42, output: ...}}` — **code preserved, not forced to 1**.
- **Remote timeout** (`%Error{code: {:command, :timeout}}`): returns `{:error, "SSH to <name> command timed out"}`.
- **Output limit exceeded**: `{:error, "...output limit exceeded..."}`.
- Connect refused → formatted error, no cache entry (next call re-attempts).
- Unknown server → `"SSH server 'ghost' not declared..."`.
- Missing env var (`nil`) → `"...env var SSH_PASS is not set"`.
- **Empty env var** (`""`) → same missing-var error.
- **Profile switch** during live SSH session: command after switch sees new profile env; **server-declared env var not in either profile** survives the switch.
- **SSH update_env failure** during profile switch: SSH session evicted from cache; next command reconnects with fresh env.
- **Host/VFS update unchanged** when SSH update fails during profile switch (no spurious rollback).
- **SSH-only workspace profile switch**: workspace with ssh_sessions but no host/vfs sessions still gets SSH env updated.
- Session reuse: two calls to same server → FakeSSH sees one `:connect`, two `:exec`s.
- **project_dir drift**: SessionManager's `ensure_ssh_session` sees a new project_dir in opts and tears down the stale session before rebuilding.
- **Registry reload invalidation**: call `SessionManager.invalidate_ssh_sessions(["staging"])` → cached session torn down; next command reconnects with fresh config.
- **`stop_session/1` / `drop_sessions/1`** with only SSH sessions (no host/VFS entry): SSH sessions closed.
- **Client-side call timeout includes connect_timeout** when `backend: :ssh` — assert that a slow-connecting server doesn't time out the outer `GenServer.call` within the normal command-timeout window.

**RunCommand tool-path tests** (`mix test test/jido_claw/tools/run_command_test.exs`):
- `backend: "ssh"` via the actual action/tool schema path (exercises NimbleOptions validation + `run/2` post-validation atom conversion).
- Legacy `backend: :ssh` atom input → `on_before_validate_params/1` coerces to `"ssh"`, validation passes.
- `backend: "ssh"` + missing `server` → validation error.
- `backend: "ssh"` + SessionManager not running → `{:error, "SSH requires SessionManager..."}`, **never** falls through to `System.cmd`.
- `backend: "host"` or `backend: "vfs"` maps to the internal `:host`/`:vfs` atoms and still routes via SessionManager.
- Legacy `force: :host` still works unchanged (no regression).

**Full suite**: `mix test` — confirm no regressions, especially in SessionManager update_env atomicity tests and RunCommand legacy-force tests.

**Manual verification**:
- `.jido/config.yaml` with a real server entry targeting local sshd. `run_command backend: "ssh", server: "local", command: "uname -a"` executes remotely.
- `/profile switch staging` then `run_command backend: "ssh", server: "local", command: "env | sort"` shows staging env + server-declared env.
- Typo in `host:` → clean error, REPL continues.
- `password_env` pointing at an unset var → clean error.
- `key_path` pointing at an encrypted key → decode failure with the passphrase/agent hint.

## Deferred to v0.5.3.1 / v0.5.4 / later

- **Passphrase-protected key support** — upstream jido_shell change required.
- `/servers` REPL command (list, test connectivity, show auth mode).
- `jido status` SSH session count segment.
- Automatic reconnect on dropped sessions.
- Classifier extension for SSH (auto-route based on path prefix).
- Consolidate `force:` → `backend:` in RunCommand and remove the legacy alias (v0.5.4).
- Jump-host / bastion chains.
- Interactive / TTY-allocating (`ssh -t`) sessions.
- Key management UI / secret-store integration for passwords.
- Streaming SSH output to Display (v0.5.4 scope).

## Critical files

- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/shell/server_registry.ex` (new)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/shell/ssh_error.ex` (new)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/shell/session_manager.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tools/run_command.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/core/config.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/application.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/test/support/fake_ssh.ex` (new)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/test/jido_claw/shell/server_registry_test.exs` (new)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/test/jido_claw/shell/ssh_error_test.exs` (new)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/test/jido_claw/shell/session_manager_ssh_test.exs` (new)

## After merge — ROADMAP update

Mark v0.5.3 **Status: Complete** and update the current-state paragraph at the top of `docs/ROADMAP.md` to mention SSH remote execution with declared server targets, profile-aware env, and structured connection errors. Note the passphrase-protected-key deferral explicitly in the v0.5.3 "Out of scope" list.
