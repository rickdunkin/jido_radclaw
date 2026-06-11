# Fix H13 (leaked SSH connections) + H15 (orphaned OS processes on timeout)

From `docs/reports/code-review-2026-06-10.md`. Greenfield — no data/path compat concerns. **Done = `mix precommit` passes** (compile_check, system_prompt.check, deps.unlock --unused, format, reach --arch --smells --strict, credo --strict, dialyzer, full test suite — see `mix.exs:252-261`).

## Context

- **H13:** `lib/jido_claw/core/jido_shell_session_server_patch.ex` is a full-module redefinition of `Jido.Shell.ShellSessionServer` (loaded via `DependencyPatches.ensure_loaded!()`). It was forked from an older jido_shell and accidentally dropped `Process.flag(:trap_exit, true)` + the `{:EXIT, ...}` handle_info clause that the pinned dep (`deps/jido_shell/lib/jido_shell/shell_session_server.ex:92-98, 250-256`) added precisely so `terminate/2 → Backend.SSH.terminate/1 → :ssh.close` runs on `DynamicSupervisor.terminate_child/2`. Every teardown path (`stop_session`, `drop_sessions`, `invalidate_ssh_sessions`, project-dir-drift rebuild — all funnel through `ShellSession.stop/1`) leaks one SSH connection. The SSH conn pid is neither linked nor monitored; `Backend.SSH.terminate/1` is the *only* thing that closes it.
- **H15:** On timeout, all three exec sites kill only the BEAM side (Task brutal_kill / `Port.close`), never the OS process tree — the `sh -c` grandchildren (real `claude`/`codex`/user commands) keep running. Report's suggested fixes don't fit: `setsid` doesn't exist on macOS (dev machine), and an `exec` prefix is unsafe for pipeline commands. `System.cmd` exposes no os_pid. The right shape: a port-based runner + process-**tree** kill (`ps` snapshot → BFS → `kill -KILL`), seeded from `Port.info(port, :os_pid)`.

Scope decision (user-approved): **the backend_host cancel path is in scope** — `cancel/2`'s `Process.exit(task, :shutdown)` orphans the same way (the existing cancel test leaves a stray `sleep 10` every run); fix via trap_exit + cooperative reap.

---

## Part 1 — H13: re-port `trap_exit` into the session-server patch

**File: `lib/jido_claw/core/jido_shell_session_server_patch.ex`**

1. Add `Process.flag(:trap_exit, true)` as the **first line** of `init/1` (~line 122, before `session_id = Keyword.fetch!(...)`), porting the dep's explanatory comment verbatim (dep lines 93-97 — names the exact terminate-skip failure mode).
2. Add after the existing `{:DOWN, ...}` handle_info clause (~line 276), with the dep's comment (dep lines 251-256):
   ```elixir
   @impl GenServer
   def handle_info({:EXIT, _pid, _reason}, state) do
     {:noreply, state}
   end
   ```
   (Patch style uses `@impl GenServer`, dep uses `@impl true` — keep patch style.)
3. Update the patch header comment: note the file now has **behavioral parity with dep ref `bace81a` for upstream lifecycle handling**, apart from the documented `:update_env` addition (header/comments/reach annotations still intentionally differ — don't claim full-file parity).

**Safety, verified:** command tasks are started via `Task.Supervisor.start_child` (unlinked, monitored only — patch `monitor_for_command/1` ~:380), so trap_exit introduces no new `{:EXIT,...}` traffic from them; the ignore-clause matches dep behavior exactly. The eviction path (`GenServer.stop`) already runs terminate today — this only restores the supervisor-shutdown path.

**Tests: `test/jido_claw/shell/session_manager_ssh_test.exs`**

- "project_dir drift" test (~501-538): the comment at 532-534 ("ShellSessionServer doesn't trap exits, so the old backend's terminate isn't called") becomes false — rewrite it, and add `assert_receive {:fake_ssh, {:close, ^conn_pid}}` (FakeSSH.close already emits this; don't assume connect-vs-close ordering).
- `describe "stop/drop for SSH-only workspaces"` (~540-582): both tests only poll `ShellSession.lookup == {:error, :not_found}` — add `assert_receive {:fake_ssh, {:close, _}}` after the stop/drop call (terminate runs synchronously in the dying process; default assert_receive window is fine).
- `invalidate_ssh_sessions/1` test (~448-499): this teardown path currently just drains after invalidation (~462) — capture the original `conn_pid` from the `{:connect, ...}` message (~460) and add `assert_receive {:fake_ssh, {:close, ^conn_pid}}` **before** the drain, so all four named teardown paths (drift, stop, drop, invalidate) assert the close.
- Verified no breakage elsewhere: every `refute_receive`/`refute_received` in the file is shape-specific (`{:connect,...}`/`{:exec,...}`), and `drain_fake_ssh_messages/0` insulates the rest.

---

## Part 2 — H15: new `JidoClaw.Core.OsCmd` + three call sites

### 2a. New module `lib/jido_claw/core/os_cmd.ex`

Two public functions (both `@spec`'d, moduledoc'd; **no bare rescue** — typed `catch :error, :badarg` around Port ops only, so no reach pragma needed):

- **`run(executable, args, opts)`** → `{output :: binary, exit_status :: integer | :timeout}`
  - `Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, cd}, {:env, port_env}])`
  - Capture os_pid right after open: `case Port.info(port, :os_pid) do {:os_pid, p} -> p; _ -> nil end` — **must be a non-tuple/nil-safe `case`, not a match**: Elixir's `Port.info/2` returns `nil` once the port is closed (dialyzer + crash safety; the registry's destructuring bind at `registry.ex:160` is the anti-pattern).
  - Selective receive: accumulate `{^port, {:data, chunk}}` iodata; return on `{^port, {:exit_status, code}}`. `after timeout` → kill (guard the `nil` os_pid case — only call `kill_tree/1` with an integer; if os_pid is `nil` fall back to plain close) → drain (post-kill the port delivers data + exit_status for the SIGKILL'd child; ~1s fallback then `Port.close` in a typed catch) → `{partial_output, :timeout}`. Final 0-timeout flush of `{^port, _}` / `{:EXIT, ^port, _}` (trapping callers) — mirrors System.cmd hygiene.
  - `opts`: `:cd` (default `File.cwd!()`), `:timeout` (default `:infinity`), `:env` in **System.cmd format** `[{String, String | nil}]`, **already scrubbed by the caller** — OsCmd does a pure *shape* conversion to port format (charlists, `nil → false`; reuse the conversion body from `security/redaction/env.ex:119-121`). Do **not** re-scrub.
- **`kill_tree(os_pid)`** → `:ok` — accepts only an integer (`when is_integer(os_pid)`; callers guard `nil`). Bounded STOP-fixpoint, then one KILL:
  - `kill -STOP <root>` (root can't fork mid-kill; SIGKILL works on stopped procs).
  - Snapshot `System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="], ...)` (POSIX flags, macOS + Linux), parse to a ppid→pids map, BFS descendants of root; `kill -STOP` any **newly found** descendants; re-snapshot and repeat until the descendant set is stable or a small attempt cap (~5) — already-running descendants can fork between snapshot and KILL, so a single optimistic pass isn't enough for hostile commands.
  - Then one `System.cmd("kill", ["-KILL" | pid_strings])`. **Every pid arg goes through `to_string/1`** — ps parsing should keep pids as strings throughout so integers never reach the argv. Ignore nonzero exits (already-dead pids). Pass `env: Env.scrubbed_cmd_env()` + `stderr_to_stdout: true` on the ps/kill calls (matches the `background_process/registry.ex:159-169` precedent).
  - **Never strand a STOPped process:** wrap the snapshot/parse phase so any failure mid-way still falls through to the KILL of everything collected so far (root included) — or, failing that, sends `CONT` to the pids already STOPped. A raise between STOP and KILL must not leave the tree frozen forever.

### 2b. `lib/jido_claw/forge/runner/host_shell.ex` — `run_with_timeout/5` integer clause (~133-148)

Replace the Task.async/System.cmd/brutal_kill body:
```elixir
defp run_with_timeout(executable, args, cwd, env, timeout) when is_integer(timeout) do
  case OsCmd.run(executable, args, cd: cwd, env: env, timeout: timeout) do
    {_partial, :timeout} -> {"", :timeout}
    {output, status} -> {output, status}
  end
rescue
  e -> {Exception.message(e), 1}
end
```
Exact current return contract preserved (`{"", :timeout}` — partial output still discarded). The `:infinity` clause stays on `System.cmd`. File already has `# reach:disable-for-this-file bare_rescue`.

### 2c. `lib/jido_claw/forge/sandbox/docker.ex` — `exec_with_timeout/2` (~249-262)

```elixir
defp exec_with_timeout(args, timeout) do
  case System.find_executable("sbx") do
    nil -> {"sbx: command not found", 127}
    sbx ->
      case OsCmd.run(sbx, args, env: Env.scrubbed_cmd_env(), timeout: timeout) do
        {_partial, :timeout} -> {"timeout after #{timeout}ms", 124}
        result -> result
      end
  end
end
```
- **Contract constraint (verified):** the `exec` consumer `forge/runner/shell.ex:14-17` matches only `{output, integer}` — never return `:timeout` or `{:error, _}` here. `{string, 124}` / `{string, 127}` keep it green (127 mirrors `host_shell.ex:88`; `spawn/4`'s find_executable precedent is at docker.ex ~:114).
- Also fixes the latent CaseClauseError: current code has no `{:exit, reason}` branch for a crashed Task.
- Add an explicit comment documenting the residual: killing the host-side `sbx` client tree is the fix; the in-container command keeps running until sandbox `destroy` — the microVM contains the blast radius, but a timed-out command still running inside a **long-lived** sandbox can consume its CPU/memory and affect later commands in that same sandbox. Accepted for now; revisit if sbx grows a remote-cancel API.

### 2d. `lib/jido_claw/shell/backend_host.ex` — timeout, output-limit, and cancel paths

1. New private helper:
   ```elixir
   defp kill_port_tree(port) do
     case Port.info(port, :os_pid) do
       {:os_pid, os_pid} -> OsCmd.kill_tree(os_pid)
       _ -> :ok
     end
   end
   ```
2. Call `kill_port_tree(port)` **before** `catch_port_close(port)` in both the `after timeout` branch (~:167) and the `{:limit_exceeded, ...}` branch (~:155) — order matters: after `Port.close`, `:os_pid` is gone. The existing 100ms drain in `catch_port_close` absorbs the post-kill exit_status. The normal `{:exit_status, ...}` branch needs no reap.
3. **Cancel path (approved scope):** `Process.flag(:trap_exit, true)` at the top of `run_command/6`, plus new receive clauses in `collect_port_output/5` — **narrowed by exit reason** so an unexpected linked-process failure isn't misreported as a cancellation:
   ```elixir
   {:EXIT, from, :shutdown} when is_pid(from) ->
     kill_port_tree(port)
     catch_port_close(port)
     {:error, "Command was cancelled"}

   {:EXIT, from, reason} when is_pid(from) ->
     kill_port_tree(port)
     catch_port_close(port)
     {:error, "Command aborted: #{inspect(reason)}"}
   ```
   (`cancel/2` sends exactly `:shutdown`; any other linked exit still reaps + closes but surfaces as a crash-ish error.)
   - `is_pid(from)` excludes the trailing `{:EXIT, port, :normal}` a trapping owner gets on port death.
   - Verified safe: `Process.exit(task, :shutdown)` on a trapping process becomes this message; the user-visible `{:error, "Command was cancelled"}` comes from the **server-side** `:command_cancelled` broadcast (`session_manager.ex:1473` via `do_collect`), independent of the task; the task's late `{:command_finished, ...}` lands in the server's `current_command: nil` ignore clause; the server demonitors on cancel and never awaits the task. Bonus: app-shutdown `:shutdown` from the Task.Supervisor now also reaps.

### 2e. Unchanged / follow-ups (documented, not in scope)

- `host_shell.exec/3` (`sh -c`, no timeout support at all) — no timeout branch exists to orphan from.
- `BackgroundProcess.Registry.force_kill` single-pid kill (L21 dead code) — candidate to adopt `OsCmd.kill_tree` later.
- `reasoning/compactor/summarizer.ex:163` brutal_kill — pure Elixir/HTTP task, no OS process; not affected.

---

## Part 3 — Tests (all extend existing files except the new os_cmd_test)

1. **New `test/jido_claw/core/os_cmd_test.exs`** (`async: false`): normal run/exit status/stderr merge/env set + nil-unset/cd; `:infinity`; partial-output-on-timeout; and the orphan regression — run `sh -c 'sleep 30 & echo $! > <marker>; wait'` (resolve sh via `System.find_executable`) with `timeout:` ~750-1000ms (not ~300 — slow CI shell startup can make "marker was written" flaky), assert `{_, :timeout}`, **poll marker existence first** (avoids write race), read grandchild pid, then poll `ps -p <pid>` until dead (copy the local `assert_eventually` pattern from `session_manager_ssh_test.exs:1006`; unique tmp paths + `on_exit` cleanup).
2. **`test/jido_claw/forge/runner/host_shell_test.exs`** (exists): add a timeout regression test via `exec_argv(client, "sh", ["-c", <grandchild pattern>], timeout: ...)` → returns `{"", :timeout}` promptly + grandchild dies. Same ~750-1000ms timeout guidance.
3. **`test/jido_claw/shell/backend_host_test.exs`** (exists): direct unit tests against `BackendHost.init/execute` with `session_pid: self()` — cleaner than SessionManager plumbing (note: `SessionManager.run`'s 3rd arg is the *collector* deadline, not the backend port timeout; the port timeout is `exec_opts[:timeout]`). **Calling convention:** `command_line/2` (backend_host.ex:192-193) joins command + args with spaces — `execute(state, "sh", ["-c", pattern], ...)` is NOT argv execution. Pass the full shell line as `command` with `args = []`; BackendHost wraps it in `sh -c` itself:
   - **timeout reap:** `execute(state, "sleep 30 & echo $! > #{marker}; wait", [], timeout: ~750-1000)` → receive `{:command_finished, {:error, "Command timed out after ..."}}`, assert marker pid dead.
   - **cancel reap:** must prove the OS child exists **before** cancelling — `execute/4` returns as soon as the task starts, so a too-fast cancel could hit before the port/child exists and pass vacuously. Use the marker-pid pattern here too: execute a long command (full line, `args = []`) that writes the grandchild pid to a marker, poll until the marker pid is alive, then `cancel(state, task_pid)` → receive `{:command_finished, {:error, "Command was cancelled"}}`, assert the marker pid dies.
   - **output-limit reap:** the limit-exceeded branch gets the same reap, so regression-test it: start a background `sleep` + pid marker, then emit enough output to exceed a tiny `output_limit:` exec_opt (execute/4 honors it, backend_host.ex:52), receive the `{:command_finished, {:error, %Jido.Shell.Error{}}}`, assert the sleep pid dies.
4. **H13 ssh test updates** per Part 1. Existing cancel tests (`session_manager_vfs_test.exs:240-259`, `session_manager_ssh_test.exs:927-968`) stay green (broadcast-driven reply).

## Part 4 — Verification

1. Targeted first: `mix test test/jido_claw/core/os_cmd_test.exs test/jido_claw/forge/runner/host_shell_test.exs test/jido_claw/shell/ test/jido_claw/forge/`
2. Manual orphan spot-check while iterating (e.g. `ps` for the marker pid) — but the committed tests above are the durable proof.
3. **Gate: `mix precommit`** — must pass in full. Watch-outs: dialyzer (specs on OsCmd; `case` on `Port.info`), reach `--smells --strict` (no bare rescue in OsCmd; typed catches only), credo `--strict` (moduledocs), format. Reach arch rules only forbid `data → web`, so `JidoClaw.Core.OsCmd` used from forge/ + shell/ is clean. If pre-existing failures surface from the uncommitted H3/H12 work in the tree, report them rather than absorbing them silently.
