# v0.5.3 Code-Review Fixes

## Context

Post-implementation review of v0.5.3 (the SSH backend + `backend:` routing override work) turned up three bugs in `lib/jido_claw/shell/session_manager.ex`. All three were verified against the code below:

1. **[P2] `backend: :host | :vfs` is silently ignored for local routing.** `resolve_target/3` (session_manager.ex:791) only consults `:force`. Anything passed as `:backend` falls through to the classifier, so commands like `pwd`, `ls`, or `env FOO` sent with `backend: "vfs"` still route to host. The RunCommand tests cover this with `echo`, which happens to behave the same on either side — masking the regression.
2. **[P2] SSH commands never set an output limit.** `execute_ssh_command/4` (session_manager.ex:985) calls `ShellSessionServer.run_command(session_id, command)` with no opts. The `:output_limit_exceeded` handler at session_manager.ex:1039 can therefore never fire, and a chatty remote can stream into the SessionManager mailbox until the command exits or times out. `@max_output_chars` only truncates the collected buffer post-hoc.
3. **[P3] SSH reconnect failures skip `SSHError.format/2`.** When a cached SSH session's underlying connection dies, the next command triggers a synchronous reconnect inside `ShellSessionServer.run_command/3`. That returns a `%Jido.Shell.Error{}` which session_manager.ex:997 renders as `"Command rejected: #{inspect(reason)}"` instead of the planned `SSH to <name> failed: ...` message.

Intended outcome: close the three gaps with targeted fixes and add tests that actually exercise the affected routes (rather than `echo`, which doesn't distinguish them).

## Fix 1 — Backend override for host/vfs (P2)

**Change** `lib/jido_claw/shell/session_manager.ex:791-797`

Extend `resolve_target/3` to honour both `:force` and `:backend` as routing overrides before falling back to `classify/2`. `:force` keeps priority (legacy surface); `:backend` is the documented v0.5.3 surface. Stays private — no new public API.

```elixir
defp resolve_target(command, workspace_id, opts) do
  cond do
    Keyword.get(opts, :force) in [:host, :vfs] ->
      Keyword.fetch!(opts, :force)

    Keyword.get(opts, :backend) in [:host, :vfs] ->
      Keyword.fetch!(opts, :backend)

    true ->
      classify(command, workspace_id)
  end
end
```

`:ssh` is already branched off in `handle_call({:run, …})` at session_manager.ex:230-236 before reaching local dispatch, so the `in [:host, :vfs]` guard is exhaustive for the local path.

**Tests** — all exercise the fix through the public `SessionManager.run/4` surface using `pwd` as the differentiator. Host returns the real project/tmp cwd; VFS returns `/project` (the workspace mount point). Add to `test/jido_claw/shell/session_manager_vfs_test.exs` (it already boots a real session with a known `project_dir`):

- `backend: :vfs` + `pwd` → output starts with `/project`. The classifier would route bare `pwd` to host; the override flips it.
- `backend: :host` + `pwd` → output is the configured `project_dir` (the tmp path from setup).
- `force: :host` + `backend: :vfs` + `pwd` → output is the host cwd (`force` wins over `backend` on conflict).

Also update `test/jido_claw/tools/run_command_test.exs:172-191` — swap `echo` for `pwd` in the two `echo`-based backend-routing tests so host vs VFS distinguishes observably via the same `/project` vs tmp assertion. The workspace fixture in that describe block already provides a tmp `project_dir`.

## Fix 2 — SSH streaming output cap (P2)

**Change** `lib/jido_claw/shell/session_manager.ex`

Add a module attribute and pass it to `ShellSessionServer.run_command/3` only on the SSH path (host/VFS keep current behaviour — scope-limited to what the review called out):

```elixir
@max_ssh_output_bytes 1_000_000
```

Update `execute_ssh_command/4` at session_manager.ex:985:

```elixir
case ShellSessionServer.run_command(session_id, command, output_limit: @max_ssh_output_bytes) do
```

The SSH backend at `deps/jido_shell/lib/jido_shell/backend/ssh.ex:90-92` already reads `Keyword.get(exec_opts, :output_limit)` and wires it into its output limiter, so no library change is needed. When exceeded, the backend emits `%Jido.Shell.Error{code: {:command, :output_limit_exceeded}}`, which is already handled at session_manager.ex:1039 → `SSHError.format/2` → `"SSH to <name>: output limit exceeded, command aborted"`.

**Rationale for 1 MB.** Display truncation stays at 10 KB (`@max_output_chars` in RunCommand + SessionManager). 1 MB is a mailbox safety valve — chatty but not runaway commands still complete and truncate gracefully; only genuinely broken streams abort. Keeping the two limits separate avoids regressing host/VFS behaviour where 12 KB output truncates cleanly today.

**Tests** — add to `test/jido_claw/shell/session_manager_ssh_test.exs`:

- Add a `__fake_output_overflow__` scripted response to `test/support/fake_ssh.ex:98-130` that emits a single chunk larger than `@max_ssh_output_bytes` (e.g. `String.duplicate("x", 1_100_000)`) — mirrors the existing `__fake_big_output__` helper.
- Assert the `run/4` return is `{:error, message}` and `message =~ "SSH to staging: output limit exceeded"`.

Only observable behaviour is asserted (structured error string). We don't probe mailbox internals or the partial output payload — those are implementation details of the collector loop.

## Fix 3 — Route synchronous SSH errors through SSHError (P3)

**Change** `lib/jido_claw/shell/session_manager.ex:997-998`

```elixir
{:error, reason} ->
  {:error, SSHError.format(reason, entry)}
```

`SSHError.format/2` already has a `%Jido.Shell.Error{}` catchall at ssh_error.ex:102-104 that renders `"SSH to <name> failed: <Exception.message/1>"`, plus the existing `{:command, :start_failed}` + `{:ssh_connect, _}` clause at ssh_error.ex:42-47 for the connect-reason-specific messages.

**One nuance worth addressing.** When reconnect fails inside `execute/4`, `do_run_command` in jido_shell wraps the backend's `%Jido.Shell.Error{code: {:command, :start_failed}, context: %{reason: {:ssh_connect, _}, …}}` in *another* `Error.command(:start_failed, %{reason: <inner_error>, line: line})`. That double-wrap would hit SSHError's `%Error{}` catchall (generic "SSH to <name> failed: …") instead of the specific connect-reason formatter.

Add an unwrap clause to `lib/jido_claw/shell/ssh_error.ex` (place above the existing connect-reason clause at ssh_error.ex:42):

```elixir
def format(
      %Error{code: {:command, :start_failed}, context: %{reason: %Error{} = inner}},
      %ServerEntry{} = entry
    ) do
  format(inner, entry)
end
```

This preserves the planned reconnect-failure message ("SSH to staging failed: connection refused at …") when a cached session has a dead connection.

**Tests**

- `test/jido_claw/shell/ssh_error_test.exs`: a focused unit test for the unwrap clause — `connect_error(:econnrefused)` nested inside an outer `Error.command(:start_failed, %{reason: inner, line: "true"})` formats to `"SSH to staging failed: connection refused at web01.example.com:22"`.
- `test/jido_claw/shell/session_manager_ssh_test.exs`: an integration test for the reconnect-failure path. Sequence:
  1. Run a command with `:normal` mode → cached session established; `assert_receive {:fake_ssh, {:connect, _, _, _, conn_pid}}`.
  2. `Process.exit(conn_pid, :kill)` — `Process.alive?` now false on next call.
  3. `FakeSSH.set_mode(:connect_error)`.
  4. Run another command → assert `{:error, message}` where `message =~ "SSH to staging failed: connection refused"` (not "Command rejected:").

## Files modified

- `lib/jido_claw/shell/session_manager.ex` — Fix 1 (`resolve_target/3`), Fix 2 (`@max_ssh_output_bytes`, pass to `ShellSessionServer.run_command/3`), Fix 3 (route synchronous error through `SSHError.format/2`).
- `lib/jido_claw/shell/ssh_error.ex` — Fix 3 (unwrap clause for double-wrapped `start_failed`).
- `test/jido_claw/shell/session_manager_vfs_test.exs` — new `pwd`-based tests for override priority via `SessionManager.run/4`.
- `test/jido_claw/tools/run_command_test.exs` — swap `echo` for `pwd` in the two backend-routing tests so host vs VFS distinguishes observably.
- `test/jido_claw/shell/session_manager_ssh_test.exs` — new tests for SSH output-limit trigger and reconnect-failure formatting.
- `test/support/fake_ssh.ex` — new `__fake_output_overflow__` scripted response.
- `test/jido_claw/shell/ssh_error_test.exs` — unit test for the double-wrap unwrap clause.

## Verification

Use explicit file targets for `mix format` (bare `mix format --check-formatted` fails pre-existing because the repo has no `.formatter.exs` inputs configured — out of scope for this change):

```bash
mix format lib/jido_claw/shell/session_manager.ex \
           lib/jido_claw/shell/ssh_error.ex \
           test/jido_claw/shell/session_manager_vfs_test.exs \
           test/jido_claw/shell/session_manager_ssh_test.exs \
           test/jido_claw/shell/ssh_error_test.exs \
           test/jido_claw/tools/run_command_test.exs \
           test/support/fake_ssh.ex

mix format --check-formatted lib/jido_claw/shell/session_manager.ex \
                             lib/jido_claw/shell/ssh_error.ex \
                             test/jido_claw/shell/session_manager_vfs_test.exs \
                             test/jido_claw/shell/session_manager_ssh_test.exs \
                             test/jido_claw/shell/ssh_error_test.exs \
                             test/jido_claw/tools/run_command_test.exs \
                             test/support/fake_ssh.ex

mix compile --warnings-as-errors

mix test test/jido_claw/shell/session_manager_vfs_test.exs \
         test/jido_claw/shell/session_manager_ssh_test.exs \
         test/jido_claw/shell/ssh_error_test.exs \
         test/jido_claw/tools/run_command_test.exs

mix test
```

Expected: targeted files pass with the new cases green, full suite stays at zero failures, no new warnings.

## Commit plan

Three commits, one per fix, so each bug's fix + test stay bisectable:

1. `fix: honor backend: :host/:vfs override in local routing`
2. `fix: cap SSH streaming output to bound SessionManager mailbox`
3. `fix: route SSH reconnect failures through SSHError.format/2`

(Slicing guidance only — no git commands run without explicit request.)
