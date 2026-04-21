# v0.5.1 — Custom Command Registry

## Context

v0.5 builds on the `jido_shell` `BackendHost` foundation with four focused point releases. v0.5.1 is the first: register JidoClaw-specific commands (`jido status`, `jido memory search <query>`, `jido solutions find <fingerprint>`) as first-class `jido_shell` commands, accessible from the persistent shell session. Today the agent can run `ls`, `cd`, `bash`, etc. through the shell, but has no ergonomic way to query its own state or stores without invoking a tool — inside a shell session, `jido status` should Just Work.

Two things stand in the way:

1. **`Jido.Shell.Command.Registry`** (`deps/jido_shell/lib/jido_shell/command/registry.ex`) is a plain module with a hard-coded static map of 14 built-ins and no extensibility hook.
2. **`JidoClaw.Shell.SessionManager.classify/2`** (`lib/jido_claw/shell/session_manager.ex:291`) routes everything not in `@sandbox_allowlist` (11 built-ins) to the host `BackendHost`, and `check_all_absolute_paths_mount/2` at `:330` additionally kicks anything without mounted absolute paths to host. Even with the registry patched, `jido status` would still land on `BackendHost` and fail with `jido: command not found`.

v0.5.1 patches the registry *and* widens the classifier so extension commands route through the VFS session where the registry actually runs.

## Approach

### 1. Runtime patch — extensibility hook in `Jido.Shell.Command.Registry`

New file: `lib/jido_claw/core/jido_shell_registry_patch.ex`. Redefine the full `Jido.Shell.Command.Registry` module (mirroring `lib/jido_claw/core/anubis_stdio_patch.ex:1-15` header style). `lookup/1`, `list/0`, and `commands/0` all union the hard-coded built-ins with `Application.get_env(:jido_shell, :extra_commands, %{})`. **Built-ins win on name collision** via `Map.merge(extras, built_ins)` (second argument takes precedence).

The config-key choice (`:jido_shell, :extra_commands`) matches the dep's own `:guardrail_rules` precedent at `deps/jido_shell/lib/jido_shell/guardrails.ex:67`, so the upstream PR's config key is already shaped to fit.

Header must cross-reference:
- `mix.exs:22` `elixirc_options: [ignore_module_conflict: true]` — already in place for the anubis patches; reused, no `mix.exs` change needed.
- Removal trigger: jido_shell ships a release containing the `:extra_commands` hook and we upgrade the dep.
- Usage note documenting that runtime callers extending `:extra_commands` must `Map.merge/2` with the existing value rather than overwrite it — the config is application-global and multiple consumers may contribute.

### 2. Classifier change — route extension commands to VFS

Edit `lib/jido_claw/shell/session_manager.ex`:

- **`check_allowlist/1` (line 302)** becomes `check_allowlist_or_extension/1`: unions `@sandbox_allowlist` with `Application.get_env(:jido_shell, :extra_commands, %{}) |> Map.keys()` and admits `"help"` (so `help` and `help jido` route to the registry instead of the host's bash builtin). Look up the extras map fresh each call — the value may be mutated in tests and must not be cached.
- **New helper `check_extension_only_or_paths_mount/2`** inserted before `check_all_absolute_paths_mount/2` (line 330) in the `classify/2` `with` chain. If every parsed command is an extension or `"help"` (none of which operate on the workspace filesystem), short-circuit to `:ok`. Otherwise delegate to the existing `check_all_absolute_paths_mount/2` unchanged.

Net effect: `jido status`, `jido memory search foo`, `jido solutions find abc`, `help`, and `help jido` classify to `:vfs`; every existing classification result is unchanged. Cite each change with a short comment pointing at v0.5.1.

**Scoping statement — registry/classifier split.** v0.5.1 promotes exactly two things to VFS: `"help"` (so the registry's own help surface becomes reachable) and any command registered in `Application.get_env(:jido_shell, :extra_commands, %{})` (the JidoClaw `"jido"` command for now). Other registry built-ins that theoretically don't touch the filesystem — `sleep`, `seq`, `env`, `echo` — continue to route to the host per the pre-v0.5.1 classifier behavior. They land on host because `check_all_absolute_paths_mount/2` currently treats "no absolute paths" as `:fallback_to_host` (see `session_manager.ex:337`). Fully reconciling the registry and the classifier (deriving the sandbox list from `Jido.Shell.Command.Registry.commands/0` and tagging path-free commands) is a larger refactor that touches every existing classify test — deferred, noted for a future cleanup pass.

### 3. Command module — `JidoClaw.Shell.Commands.Jido`

New file: `lib/jido_claw/shell/commands/jido.ex`. Single module owns the registry name `"jido"` and dispatches sub-commands via **multiple `run/3` heads** pattern-matching on `%{args: [...]}`:

```elixir
def run(_state, %{args: []}, emit),                              do: emit_usage_ok(emit)
def run(_state, %{args: ["help"]}, emit),                        do: emit_usage_ok(emit)
def run(_state, %{args: ["status"]}, emit),                      do: emit_status(emit)
def run(_state, %{args: ["memory", "search"]}, emit),            do: emit_missing(:memory_search_query, emit)
def run(_state, %{args: ["memory", "search" | rest]}, emit),     do: emit_memory(rest, emit)
def run(_state, %{args: ["solutions", "find"]}, emit),           do: emit_missing(:solutions_find_fingerprint, emit)
def run(_state, %{args: ["solutions", "find", fp]}, emit),       do: emit_solution(fp, emit)
def run(_state, %{args: [sub | _]}, emit),                       do: emit_unknown(sub, emit)
```

**Exact-match trailing-args policy.** `jido status foo`, `jido help nonsense`, `jido solutions find abc def` all fall through to `emit_unknown/2` as unknown sub-command rather than silently swallowing the trailing args. The only intentionally variadic head is `memory search <multi-word query>` — that's how natural-language queries work. Every other sub-command has a fixed arity.

**Distinguish three outcome shapes, and emit a human-readable error line.** `SessionManager.execute_command/3` at `lib/jido_claw/shell/session_manager.ex:406` turns `{:error, _}` returns into `exit_code: 1` + whatever text was already emitted — **the structured `Jido.Shell.Error` is dropped before it reaches the REPL**. So user-visible output comes entirely from `emit.({:output, ...})` calls. The structured error shape is exercised by unit tests; the emitted text is what the human and agent see.

- **Success** (`emit_usage_ok/1`, `emit_status/1`, populated `emit_memory/2`, any `emit_solution/2`) — emit lines, return `{:ok, nil}`, exit code 0.
- **Validation error — valid prefix, missing required arg** (`emit_missing/2`). Emit usage, emit a second plain-text line `"error: <field> is required"`, then return `{:error, Jido.Shell.Error.validation("jido", [%{path: [:args, <field>], message: "is required"}])}` (helper at `deps/jido_shell/lib/jido_shell/error.ex:111-118`). Visible outcome: usage + error line + exit 1. Structured error is for the test assertions and for any future programmatic `SessionManager.run/4` caller that does surface the struct.
- **Unknown sub-command** (`emit_unknown/2`). Emit usage, emit `"error: unknown sub-command \"<sub>\""`, then return `{:error, Jido.Shell.Error.shell(:unknown_command, %{name: "jido " <> sub})}` (helper at `error.ex:85-91`). Visible outcome: usage + error line + exit 1.

`:not_found` from `JidoClaw.Solutions.Store.find_by_signature/1` is **not** an error — the fingerprint was well-formed, the store simply doesn't have it. Emit `"No solution with that signature."` and return `{:ok, nil}` (exit 0).

**Callbacks** (per `Jido.Shell.Command` behaviour at `deps/jido_shell/lib/jido_shell/command.ex`):
- `name/0` → `"jido"`
- `summary/0` → `"JidoClaw introspection — status, memory search, solutions find"`
- `schema/0` → `Zoi.map(%{args: Zoi.array(Zoi.string()) |> Zoi.default([])})` (identical to `deps/jido_shell/lib/jido_shell/command/echo.ex:24-28` and `deps/jido_shell/lib/jido_shell/command/help.ex:15-19`)

`@moduledoc` must describe each sub-command clearly — `Help.run/3` at `deps/jido_shell/lib/jido_shell/command/help.ex:37-63` renders it verbatim via `Code.fetch_docs/1`, so it is the canonical help surface. **No profile line**; that lands with v0.5.2's `ProfileManager`, and stubbing `"default"` here would mislead agents about the feature's availability.

### 4. Shared presenter module — `JidoClaw.CLI.Presenters`

New file: `lib/jido_claw/cli/presenters.ex`. **Purely pure functions** — every presenter takes a plain map/struct and returns `[String.t()]`. No direct calls to global named processes from inside the presenter; that keeps it unit-testable without standing up the Memory, AgentTracker, Solutions.Store, or Stats fixtures.

The shell command module (`JidoClaw.Shell.Commands.Jido`) is responsible for **fetching** the data and **composing** the snapshot. The presenter module is responsible for **formatting** it.

Signatures:

- `status_lines(%{tracker: tracker_state, sessions: sessions_result, stats: stats})` — where `sessions_result` is `{:ok, list} | {:error, reason}`. On `:error` the lines include a `"sessions unavailable: <reason>"` line instead of the per-session breakdown. `tracker` and `stats` are always present; uptime is read from `stats.uptime_seconds`.
- `memory_search_lines(query, results)` — returns header + per-result lines, or the empty-results line when `results == []`.
- `solution_lines(find_result)` — where `find_result` is `{:ok, %JidoClaw.Solutions.Solution{}} | :not_found`. Returns structured block or not-found line.

In the shell command's `emit_status/1`:

```elixir
defp emit_status(emit) do
  snapshot = %{
    tracker: JidoClaw.AgentTracker.get_state(),
    sessions: fetch_active_sessions(),
    stats: JidoClaw.Stats.get()
  }

  snapshot
  |> JidoClaw.CLI.Presenters.status_lines()
  |> Enum.each(&emit.({:output, &1 <> "\n"}))

  {:ok, nil}
end

defp fetch_active_sessions do
  JidoClaw.Forge.Resources.Session.list_active()
rescue
  e -> {:error, Exception.message(e)}
end
```

**Uptime comes from `Stats.get().uptime_seconds`** (`lib/jido_claw/core/stats.ex:85`) — it's already computed there with the same `:started_at` fallback convention used elsewhere in the app, so the presenter reads it from the snapshot rather than recomputing. **`agents_spawned`** for the "running / spawned" line similarly comes from `Stats.get().agents_spawned` (`stats.ex:81`), not from tracker state — matches how `/status` renders it at `lib/jido_claw/cli/commands.ex:34-56`.

This is the seam the reviewer asked for. The REPL slash commands at `lib/jido_claw/cli/commands.ex:28,186,279` continue to use their own ANSI-colored rendering for now — migrating them is a follow-up refactor, not v0.5.1 scope. The presenter module's `@moduledoc` notes this intent so future readers see the path forward.

### 5. Compile-time registration

Add to `config/config.exs`:

```elixir
config :jido_shell, :extra_commands, %{
  "jido" => JidoClaw.Shell.Commands.Jido
}
```

Compile-time is strictly better than the original plan's `Application.put_env` in `start/2`:
- The ROADMAP's "before `SessionManager` starts" constraint is trivially satisfied — compile-time config is resolved before any application starts.
- No wholesale clobbering risk — future runtime extenders use `Map.merge/2` per the patch moduledoc's documented pattern.
- No edit to `lib/jido_claw/application.ex`.

### 6. Tests

All globally-named processes (`JidoClaw.Memory`, `JidoClaw.Solutions.Store`, `JidoClaw.AgentTracker`) mean every new file runs `async: false`. Mirror the setup pattern at `test/jido_claw/solutions/store_test.exs:40-78` (tmp_dir + `start_supervised!`) where stateful fixtures are needed.

- **`test/jido_claw/shell/commands/jido_test.exs`** — `async: false`. Tests exercise each `run/3` head directly with a collecting `emit` fn, asserting output lines **and return shape**. Covers: empty args → `{:ok, nil}`; `help` → `{:ok, nil}`; `status` → `{:ok, nil}` with content; `memory search <q>` → `{:ok, nil}`; `memory search` with no query → `{:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}}` AND usage emitted first; `solutions find <fp>` found/not_found both → `{:ok, nil}` (different body); `solutions find` with no fp → `{:error, validation}`; `jido bogus` → `{:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}}`.
- **`test/jido_claw/shell/session_manager_classify_test.exs`** — `async: false`. New focused test around `classify/2`: `jido status` → `:vfs`, `jido memory search foo` → `:vfs`, `help` → `:vfs`, `help jido` → `:vfs`, `ls` (baseline sandbox) → `:host` when no absolute path, `cat /project/x.txt` (baseline mounted) → `:vfs`, `rm -rf /` (pipeline meta) → `:host`. Uses the capture/restore `put_env` pattern from `deps/jido_shell/test/jido/shell/guardrails_extension_test.exs:17-23` so the extras map is set for the test and restored on exit.
- **`test/jido_claw/core/jido_shell_registry_patch_test.exs`** — `async: false`. Asserts `Registry.lookup("ls")` returns the built-in, `Registry.lookup("jido")` returns `JidoClaw.Shell.Commands.Jido`, `Registry.list()` contains both names (as set membership, **not** ordered — `Registry.list/0` is `Map.keys/1` which has no order guarantee; ordering belongs to `Help.run/3`'s own `Enum.sort/1`). Includes a name-collision test: put a fake command at `"ls"` in `:extra_commands` and assert the built-in still wins.
- **`test/jido_claw/shell/session_manager_jido_integration_test.exs`** — `async: false`. Full shell path: `start_supervised!` a workspace, call `SessionManager.run(ws, "jido status", 5_000, project_dir: tmp)` and assert the captured output contains an expected line from `status_lines/0`. Also `SessionManager.run(ws, "help", ...)` and assert `"jido"` appears in the listing. Proves the patch + classifier + command module chain works end-to-end (the unit tests can't catch a classifier regression that silently routes `jido` to host).
- **`test/jido_claw/cli/presenters_test.exs`** — `async: true` (presenters are pure — no process touches). Unit-tests each presenter by constructing a snapshot map directly: `status_lines/1` with `{:ok, [...]}` sessions and with `{:error, "db down"}` sessions (asserts the graceful-degradation line without standing up Ash or AgentTracker); `memory_search_lines/2` with empty + populated results; `solution_lines/1` with `{:ok, struct}` and `:not_found`.

### 7. Removal trigger

No upstream PR is being filed. The patch lives in-tree as the canonical extensibility mechanism until/unless `jido_shell` ships native support independently. The patch header documents this: the file is the real hook, not a stopgap. If jido_shell later adds an equivalent seam, the removal trigger is "jido_shell releases a version with a compatible `:extra_commands` (or similarly-shaped) hook and we upgrade the dep" — at which point the patch file and its moduledoc pointer can be deleted without touching the call sites in `config/config.exs` or the command/presenter modules.

## Critical Files

**New:**
- `lib/jido_claw/core/jido_shell_registry_patch.ex` — module-redefinition patch (hook + moduledoc)
- `lib/jido_claw/shell/commands/jido.ex` — command module (plus `lib/jido_claw/shell/commands/` dir)
- `lib/jido_claw/cli/presenters.ex` — shared plain-text presenters
- `test/jido_claw/shell/commands/jido_test.exs`
- `test/jido_claw/shell/session_manager_classify_test.exs`
- `test/jido_claw/core/jido_shell_registry_patch_test.exs`
- `test/jido_claw/shell/session_manager_jido_integration_test.exs`
- `test/jido_claw/cli/presenters_test.exs`

**Edited:**
- `config/config.exs` — one `config :jido_shell, :extra_commands, %{...}` block
- `lib/jido_claw/shell/session_manager.ex` — rewire `check_allowlist/1` → `check_allowlist_or_extension/1`, add `check_extension_only_or_paths_mount/2`, update `classify/2`'s `with` chain

**Reference (do not modify):**
- `deps/jido_shell/lib/jido_shell/command/registry.ex` — full source the patch replaces
- `deps/jido_shell/lib/jido_shell/command.ex` — 4-callback behaviour contract
- `deps/jido_shell/lib/jido_shell/command/echo.ex:24-28` — Zoi schema template
- `deps/jido_shell/lib/jido_shell/command/help.ex:21-55` — `Help.run/3` flow (`Registry.list/0`/`lookup/1` + `Code.fetch_docs/1`)
- `deps/jido_shell/lib/jido_shell/command_runner.ex:83,101-106` — dispatch path
- `deps/jido_shell/test/jido/shell/guardrails_extension_test.exs:17-23` — capture/restore `put_env` precedent
- `lib/jido_claw/core/anubis_stdio_patch.ex:1-15` — patch header template
- `lib/jido_claw/cli/commands.ex:28,186,279` — existing ANSI presentations (prospective migration targets)
- `mix.exs:22` — `ignore_module_conflict` (already in place)

## Reused APIs

- `JidoClaw.Memory.recall/2` at `lib/jido_claw/platform/memory.ex:44`
- `JidoClaw.Solutions.Store.find_by_signature/1` at `lib/jido_claw/solutions/store.ex:46`
- `JidoClaw.AgentTracker.get_state/0` at `lib/jido_claw/agent_tracker.ex:58`
- `JidoClaw.Forge.Resources.Session.list_active/0` via Ash code interface at `lib/jido_claw/forge/resources/session.ex:19` (non-bang; wrapped with `rescue` to return `{:ok, list} | {:error, reason}`)
- `JidoClaw.Stats.get/0` at `lib/jido_claw/core/stats.ex:87` — `agents_spawned` + `uptime_seconds`
- `Jido.Shell.Error.shell/2` and `Jido.Shell.Error.validation/3` at `deps/jido_shell/lib/jido_shell/error.ex:85,111` — distinct error shapes for unknown-command vs missing-arg
- `Jido.Shell.Command` behaviour — 4 callbacks, stock Zoi schema pattern

## Verification

1. `mix format --check-formatted` — no formatting drift.
2. `mix compile --warnings-as-errors` — patch compiles cleanly under existing `ignore_module_conflict` flag; no new warnings.
3. `mix test test/jido_claw/shell/commands/jido_test.exs test/jido_claw/shell/session_manager_classify_test.exs test/jido_claw/core/jido_shell_registry_patch_test.exs test/jido_claw/shell/session_manager_jido_integration_test.exs test/jido_claw/cli/presenters_test.exs` — new tests pass.
4. `mix test` — full suite green; existing shell/session tests unaffected by the classifier change.
5. `mix jidoclaw` → start REPL → exercise the shell path:
   - `help` — confirm `jido` appears in the sorted listing alongside built-ins.
   - `help jido` — confirm `@moduledoc` renders.
   - `jido` with no args — confirm usage text.
   - `jido status` — confirm plain-text output with agent count, active forge sessions, uptime.
   - `jido memory search <term>` — seed memory via `/memory save` first, then confirm results render.
   - `jido solutions find <unknown-fp>` — confirm clean "No solution with that signature." message **with exit code 0** (not_found is not an error).
   - `jido memory search` (no query) — confirm usage printed + validation error + exit code 1.
   - `jido solutions find` (no fp) — confirm usage printed + validation error + exit code 1.
   - `jido bogus` — confirm usage + unknown-command error + exit code 1.
   - `ls`, `cd`, `cat`, `bash -c 'pwd'` — baseline built-ins still work unchanged.

## Out of Scope (deferred)

- **Profile info in `jido status`** — v0.5.2 ships `ProfileManager`; v0.5.1 omits the line entirely. No stub.
- **Migrating REPL slash commands to the shared presenters** — `/status`, `/memory search`, `/solutions` stay on their ANSI-colored renderers; migration is a follow-up refactor once more consumers of the presenters emerge.
- **Upstream PR to jido_shell** — not being filed; the in-tree patch is the canonical hook.
- **Additional `jido` sub-commands** (e.g., `jido agent list`, `jido session info`) — the dispatch shape supports them trivially; add when use cases surface.
- **Dynamic runtime `register/unregister` of extra commands** — the `:extra_commands` config is the seam; no GenServer needed for the current static set.
