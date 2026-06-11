# Fix OsCmd idle-timeout → wall-clock deadline (review P1 on the H13/H15 branch)

## Context

Post-implementation review of the uncommitted H13/H15 work (plan `please-review-docs-reports-code-review-2-logical-corbato.md`) found one P1, **validated**:

`JidoClaw.Core.OsCmd.run/3` (lib/jido_claw/core/os_cmd.ex:112-135) treats `:timeout` as an **idle-output** timeout: `collect/4` recurses on every `{:data, chunk}` with the full `timeout`, re-entering `receive ... after timeout` and resetting the window. The replaced pattern at both call sites was `Task.yield(task, timeout)` — **wall-clock**. Consequence: any command that emits output more often than the timeout interval (progress bars, streaming JSON, agent CLIs like `claude`/`codex`) never times out. Reviewer reproduced it: `timeout: 120` against a loop printing every 50ms returned *success* after ~472ms. Affected callers: `host_shell.ex:138` (`run_with_timeout/5`) and `docker.ex:263` (`exec_with_timeout/2`) — Forge command budgets are silently unenforceable for chatty commands. The review reported no other blockers.

**Done = `mix precommit` passes** (compile_check, system_prompt.check, deps.unlock --unused, format, reach --arch --smells --strict, credo --strict, dialyzer, full test suite).

## Fix — `lib/jido_claw/core/os_cmd.ex` (only file with logic changes)

Compute an absolute monotonic deadline once in `run/3`, then receive with the *remaining* time:

1. In `run/3` (~line 88): replace `collect(port, os_pid, [], timeout)` with `collect(port, os_pid, [], deadline(timeout))`.
2. New private helpers (next to the other run/3 internals):
   ```elixir
   defp deadline(:infinity), do: :infinity
   defp deadline(timeout_ms) when is_integer(timeout_ms),
     do: System.monotonic_time(:millisecond) + timeout_ms

   defp remaining(:infinity), do: :infinity
   defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
   ```
3. `collect/4`: rename the 4th param `timeout` → `deadline` and check the remaining time **before** receiving — `after 0` alone is not enough, because a zero-timeout receive still consumes queued `{:data, chunk}` messages first, so a chatty child with a mailbox backlog could keep delaying the kill past the deadline. Mirror the existing wall-clock collector shape in `lib/jido_claw/shell/session_manager.ex:1261-1268` (`do_collect/5`; same again at :1372-1375):
   ```elixir
   defp collect(port, os_pid, acc, deadline) do
     case remaining(deadline) do
       0 ->
         timeout(port, os_pid, acc)

       wait ->
         receive do
           {^port, {:data, chunk}} ->
             collect(port, os_pid, [acc | chunk], deadline)

           {^port, {:exit_status, status}} ->
             flush_port(port)
             {IO.iodata_to_binary(acc), status}
         after
           wait ->
             timeout(port, os_pid, acc)
         end
     end
   end
   ```
   `timeout/3` is the current `after` body extracted verbatim (kill_tree-or-close → drain → flush → `{IO.iodata_to_binary(output), :timeout}`). Note `remaining(:infinity) == :infinity` falls into the `wait` branch, where `after :infinity` is valid.
   Deliberate: **no** zero-timeout `exit_status`-only peek before `timeout/3` — once the deadline passes we report `:timeout` even if the child raced to completion; `kill_tree/1` on an already-dead pid is a documented no-op and `drain_after_kill/2` still collects the queued output.
4. Doc touch: the `:timeout` bullet in the `run/3` @doc (~line 55) → state it is a **wall-clock cap on total runtime; output activity does not extend it**.

Deliberately unchanged:
- `drain_after_kill/2` stays idle-based (`@post_kill_drain_ms` per chunk) — correct semantics for a post-SIGKILL drain of finite buffered output; the child is already dead.
- Both call sites (`host_shell.ex`, `docker.ex`) need no changes — they delegate `:timeout` straight through and already handle the `{partial, :timeout}` shape.
- Public `@spec`/return contract unchanged → no dialyzer churn expected.

## Regression test — `test/jido_claw/core/os_cmd_test.exs`

Add to the existing `describe "run/3"` (file already has the `sh` fixture and `assert_eventually` helper):

```elixir
test "timeout is wall-clock — steady output does not extend it", %{sh: sh} do
  started = System.monotonic_time(:millisecond)

  # Prints every 50ms for up to ~7.5s. Each chunk lands well inside the
  # 750ms window, so an idle-reset implementation never fires (the
  # command completes with status 0 after ~7.5s); a wall-clock deadline
  # returns {:timeout} at ~750ms.
  assert {output, :timeout} =
           OsCmd.run(
             sh,
             ["-c", "i=0; while [ $i -lt 150 ]; do echo tick; sleep 0.05; i=$((i+1)); done"],
             timeout: 750
           )

  elapsed = System.monotonic_time(:millisecond) - started
  assert output =~ "tick"
  # Generous CI headroom above 750ms + post-kill drain, well below the ~7.5s full run.
  assert elapsed < 5_000
end
```

Fails on HEAD deterministically (match failure `{_, 0}` after ~7.5s, no hang); passes with the fix in ~1s.

## Noted, not in scope (pre-existing; not part of this P1)

`BackendHost.collect_port_output/5` (lib/jido_claw/shell/backend_host.ex:154-201) has the same idle-reset shape (`after timeout` + recurse with full `timeout`), but it predates this branch — the working-tree diff only added the tree-kill/cancel clauses around it. It is also backstopped: the SessionManager collector sitting above it already enforces a wall-clock deadline (`do_collect`/`do_collect_ssh`, session_manager.ex:1261/:1368). Changing the backend's own timeout semantics would alter pre-existing interactive-session behavior and isn't part of this finding. Leave it; candidate follow-up if port-level wall-clock is wanted there too (its "timed out after Xms" message reads wall-clock).

## Verification

1. Prove the regression test fails on HEAD (run it once before applying the fix), then passes after.
2. Targeted, same set the reviewer ran: `mix test test/jido_claw/core/os_cmd_test.exs test/jido_claw/forge/runner/host_shell_test.exs test/jido_claw/shell/backend_host_test.exs test/jido_claw/shell/session_manager_ssh_test.exs` — confirms the call-site tests (which use silent commands, where idle == wall-clock) stay green.
3. **Gate: `mix precommit`** — must pass in full. Watch-outs: `mix format` on the new helpers; dialyzer on the `integer | :infinity` deadline union (private fns, success typing should infer cleanly).

## Order of work

1. Add the regression test; run it on HEAD → confirm it fails as described.
2. Apply the deadline fix + doc touch in os_cmd.ex.
3. Targeted test set → green.
4. `mix precommit` → green.
