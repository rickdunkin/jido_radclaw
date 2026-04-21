# v0.5.1 Code Review Follow-up

## Context

Code review of v0.5.1 (Custom Command Registry) surfaced three issues. All three were verified against the current code:

1. **[P2]** `MatcherTest` setup only isolates the Store when `GenServer.whereis(Store)` returns nil. Under `mix test`, the app supervisor has already started `JidoClaw.Solutions.Store` with `project_dir: File.cwd!()`, so the `_pid` branch runs and every `store_solution/1` call in the test persists into the repo's `.jido/solutions.json`. The comment at the top of the setup block calls out this exact flake but the guard doesn't cover the normal case.
2. **[P3]** `SessionManager.extension_command_names/0` reads `Map.keys(extra_commands)` directly. The registry patch correctly lets built-ins win on name collisions (via `Map.merge(extras, @built_ins)`), but the classifier's extension set still treats shadowed names as extension-only and skips the absolute-path mount check — changing baseline routing for any built-in (`ls`, `cat`, `rm`, …) that a consumer happens to shadow in config.
3. **[P3]** The v0.5.1 roadmap entry still says "Planned," references `JidoClaw.Application.core_children/0` registration, promises `jido status` includes "profile," and says "upstream PR preferred." The ship used config-only registration (`config :jido_shell, :extra_commands`), deferred profile output to v0.5.2, and took the runtime-patch fallback.

## Changes

### 1. Fix Store isolation in `test/jido_claw/solutions/matcher_test.exs`

Replace the conditional `GenServer.whereis(Store)` branch (lines 15–37) with the terminate-and-restart pattern already in use at `test/jido_claw/solutions/store_test.exs:40-81`. Same file, identical intent — mirroring keeps the two suites consistent.

Specifically:
- Copy the `ensure_signal_bus/0` helper from `store_test.exs:17-22` (`Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus)` with an `{:already_started, _}` fallback) and call it from `setup`. `Store.store_solution/1` emits `jido_claw.solution.stored` via `JidoClaw.SignalBus.emit/2` (`lib/jido_claw/solutions/store.ex:164`), so the bus must be up before any seeding call.
- `Supervisor.terminate_child(JidoClaw.Supervisor, Store)` then `Supervisor.delete_child/2` before `start_supervised!`.
- `start_supervised!({Store, project_dir: tmp_dir})` with a per-test tmp path.
- `on_exit/1` clears ETS, `File.rm_rf!` the tmp, and re-adds Store to `JidoClaw.Supervisor` using `Application.get_env(:jido_claw, :project_dir, File.cwd!())` — matches StoreTest exactly.

**File**: `test/jido_claw/solutions/matcher_test.exs` (lines 15–75 — setup block).

### 2. Filter extension names against built-ins in classifier

The registry patch owns the truth of "what is a built-in" (the `@built_ins` module attribute at `lib/jido_claw/core/jido_shell_registry_patch.ex:43-58`). Expose a public helper from the patch that returns the *effective* extras (extras with built-in-shadowed keys dropped), then use it from the classifier. Single source of truth, no duplicated command-name list.

**File**: `lib/jido_claw/core/jido_shell_registry_patch.ex`

Add after `commands/0`:

```elixir
@doc """
Returns the `:extra_commands` config map with any names shadowed by
built-ins removed. Built-ins always win in `commands/0`; callers that
reason about "which commands are actually extension-backed" should use
this helper rather than reading `:extra_commands` directly.
"""
@spec extra_commands() :: %{String.t() => module()}
def extra_commands do
  :jido_shell
  |> Application.get_env(:extra_commands, %{})
  |> Map.drop(Map.keys(@built_ins))
end
```

**File**: `lib/jido_claw/shell/session_manager.ex` (lines 321–327)

Replace `extension_command_names/0`:

```elixir
defp extension_command_names do
  # Use `Registry.extra_commands/0` (extras minus built-in-shadowed keys)
  # so a consumer that registers under a built-in name — which
  # `Registry.commands/0` correctly overrides with the built-in — does
  # not cause the classifier to skip the absolute-path mount check for
  # that now-built-in-backed command. `help` is added explicitly because
  # it's a built-in that doesn't touch workspace paths.
  Jido.Shell.Command.Registry.extra_commands()
  |> Map.keys()
  |> MapSet.new()
  |> MapSet.put("help")
end
```

The comment at lines 308–310 about "re-read extras on every call" still applies and should be preserved in `check_allowlist_or_extension/1`.

### 3. Add regression tests for shadowing

Pin the contract at two levels — the registry helper (unit) and the classifier (behavioural).

**File**: `test/jido_claw/core/jido_shell_registry_patch_test.exs` — extend existing "name collision" describe block (lines 35–64).

Add a test that registers `%{"ls" => __MODULE__.FakeCommand, "jido" => JidoClaw.Shell.Commands.Jido}` in `:extra_commands` (the existing setup at lines 36–47 already captures/restores) and asserts:
- `Registry.extra_commands()` **does not** contain `"ls"` (shadowed by built-in — dropped).
- `Registry.extra_commands()` **does** contain `"jido"` (no shadow — kept).
- `Registry.lookup("ls")` still returns `Jido.Shell.Command.Ls` (built-in wins — redundant with the existing test at line 61, but colocated so the contract reads clearly).

Reuse the existing `FakeCommand` module defined at lines 66–81.

**File**: `test/jido_claw/shell/session_manager_classify_test.exs`

Add a test in the "baseline classifier" describe block (after line 71) that:
- Registers `%{"ls" => JidoClaw.Shell.Commands.Jido}` in `:extra_commands` via `Application.put_env/2` (the existing `setup` already captures/restores — see lines 22–31).
- Asserts `SessionManager.classify("ls", ws) == :host` — shadowing doesn't reroute baseline built-ins.
- Asserts `SessionManager.classify("ls /unmounted/path", ws) == :host` — the absolute-path mount check is not skipped.

Any module atom works — the test only exercises classification, not dispatch.

### 4. Update the ROADMAP entry for v0.5.1

**File**: `docs/ROADMAP.md` (lines 209–217)

Rewrite to reflect what actually shipped:
- Change **Status: Planned** → **Status: Complete**.
- Replace the "upstream PR preferred" sentence: the runtime patch at `lib/jido_claw/core/jido_shell_registry_patch.ex` is the delivered approach (not a fallback). Mention its removal trigger ("delete when `jido_shell` ships a compatible `:extra_commands` hook") — matches the file header.
- Drop "profile" from the `jido status` bullet; note profile output is deferred to v0.5.2.
- Replace the `JidoClaw.Application.core_children/0` registration bullet with the actual mechanism: `config :jido_shell, :extra_commands, %{"jido" => JidoClaw.Shell.Commands.Jido}` in `config/config.exs`.
- Keep the list of initial commands accurate — the ship only has `jido` (with `status`, `memory search`, `solutions find` subcommands inside a single module); confirm against `lib/jido_claw/shell/commands/jido.ex` when editing.

## Verification

1. `mix compile --warnings-as-errors` — must pass (strict-compile with the patched registry).
2. `mix test test/jido_claw/solutions/matcher_test.exs` — runs in isolation, no stray writes to `.jido/solutions.json` (inspect `git status` after).
3. `mix test test/jido_claw/solutions/store_test.exs test/jido_claw/solutions/matcher_test.exs` — both in the same invocation to confirm ownership ping-pong of the supervised Store works.
4. `mix test test/jido_claw/core/jido_shell_registry_patch_test.exs test/jido_claw/shell/session_manager_classify_test.exs` — the new shadowing regressions pass at both registry and classifier level, existing tests still pass.
5. `mix test --max-failures 5` — full suite; reviewer's prior baseline was 1134 tests, 0 failures, 10 excluded.
6. `mix format --check-formatted lib/jido_claw/core/jido_shell_registry_patch.ex lib/jido_claw/shell/session_manager.ex test/jido_claw/solutions/matcher_test.exs test/jido_claw/core/jido_shell_registry_patch_test.exs test/jido_claw/shell/session_manager_classify_test.exs docs/ROADMAP.md` — targeted format check (repo has no top-level `.formatter.exs`, per the review note).

## Out of Scope

- No behaviour change to `Registry.commands/0`, `lookup/1`, or `list/0` — the built-ins-win invariant is already correct; the patch adds only a read-only helper.
- No refactor of the conditional vs. terminate-and-restart pattern elsewhere in the suite — only MatcherTest is being brought in line with StoreTest.
- No `core_children/0` or `ProfileManager` work — those belong to v0.5.2.
