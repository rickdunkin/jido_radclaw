# v0.5.4 Code-Review Fixes

## Context

A code review of the just-merged v0.5.4 (streaming output to `Display`) flagged three P2 issues, all verified accurate:

1. **Stream registry leaks on abort paths.** When `Display.start_stream/3` registers an entry but the subsequent `ShellSessionServer.subscribe/2` fails — or when `ShellSessionServer.run_command/2` rejects the run before any events broadcast — `Display.end_stream/1` only flips `end_requested?: true`. No terminal event will ever flip `done?: true`, so the entry stays in `streaming_sessions` forever. Symptom: status bar stuck in streaming mode (cyan `⟲ streaming`); the next `start_stream/3` for the same persistent session id returns `{:error, :stream_still_draining}` and the streaming command silently falls back to non-streaming mode.

2. **Multi-stream final partial line is dropped.** In multi-stream mode `emit_chunk/3` buffers post-last-newline bytes in `entry.line_buffer`, but the terminal-event handler calls `flush_line_buffer/2` which writes only `"\n"` and discards the buffered bytes. A command ending with `printf tail` while ≥2 streams are registered loses `tail` from live render.

3. **`:output_limit_exceeded` discards captured preview.** `do_collect/5` (host/VFS) and `do_collect_ssh/6` (SSH) both have already-accumulated `acc` chunks at the moment overflow fires, but each error branch returns only the bare error — the v0.5.4 plan's "50 KB streaming preview" promise is broken on the overflow path. The existing test only asserts on error context shape, so coverage misses it.

## Files to modify

| File | Change |
| --- | --- |
| `lib/jido_claw/display.ex` | Add `Display.abort_stream/1` (cast → unconditional drop) and emit buffered bytes in `flush_line_buffer/2` |
| `lib/jido_claw/shell/session_manager.ex` | Wire `Display.abort_stream/1` at the five abort sites; inject `preview` into `error.context` on `:output_limit_exceeded` (both `do_collect/5` and `do_collect_ssh/6`) |
| `test/jido_claw/display_test.exs` | New tests: `abort_stream` drops unconditionally; `end_stream` of an entry without a terminal event keeps it draining; multi-stream terminal flushes buffered tail |
| `test/jido_claw/tools/run_command_test.exs` | Extend cap-overflow test to assert `ctx.preview` content |
| `test/jido_claw/shell/session_manager_ssh_test.exs` | New test: SSH `:output_limit_exceeded` preserves preview in `error.context.preview`, wrapped in a `capture_display_io` helper so the streamed bytes don't dump to stdout |
| `test/support/fake_ssh.ex` | New `__fake_streaming_overflow__` branch emitting multiple chunks past the streaming-overridden cap |

Public API addition: `Display.abort_stream/1`. No roadmap changes (other than the unrelated `force:` doc fix flagged separately).

## Issue 1 — Stream registry leak on abort paths

**Approach (final):** Introduce an explicit `Display.abort_stream/1` cast that unconditionally drops the entry, and call it only at known abort sites. `end_stream/1` retains its original semantics (mark `end_requested?: true` and reap on `done?` / nil-entry paths).

The earlier draft of this plan tried to treat any entry without prior events as "pristine" and drop it on `end_stream/1`. That was reviewed out: shell-session events and the `end_stream/1` cast come from different sender processes, so Erlang's cross-sender FIFO does not order them — `end_stream/1` can land in Display's mailbox before queued `:command_started` / `:output` / terminal events from a normal successful run, and pristine-drop would silently discard the queued live output. An explicit `abort_stream/1` API at the five known abort sites avoids the race entirely.

**Edits in `lib/jido_claw/display.ex`:**

1. Add a public `abort_stream/1` API:
   ```elixir
   @spec abort_stream(String.t()) :: :ok
   def abort_stream(session_id) do
     GenServer.cast(__MODULE__, {:abort_stream, session_id})
   end
   ```

2. Handle the cast — unconditional drop:
   ```elixir
   def handle_cast({:abort_stream, session_id}, state) do
     {:noreply, drop_streaming(state, session_id)}
   end
   ```

3. Leave `handle_cast({:end_stream, session_id}, state)` unchanged from v0.5.4 — three clauses (`nil`, `done?: true`, default-flag-flip).

**Edits in `lib/jido_claw/shell/session_manager.ex`:** wire `Display.abort_stream/1` at five abort sites, then return the same error tuple as before:

| Site | Trigger |
| --- | --- |
| `start_display_stream/2` (subscribe-fail branch) | Display registered, then `ShellSessionServer.subscribe(display_pid)` failed |
| `execute_command/4` `run_command` rejected | Local/VFS `run_command` returns `{:error, _}` |
| `execute_command/4` catch (subscribe-failed) | SessionManager's own subscribe threw |
| `execute_ssh_command/...` `run_command` rejected | SSH `run_command` returns `{:error, _}` |
| `execute_ssh_command/...` catch (subscribe-failed) | SessionManager's own subscribe threw |

Each site guards with `if streaming?, do: JidoClaw.Display.abort_stream(session_id)`. The outer `with_optional_stream/3` try/after still calls `end_stream/1`; with the entry already dropped, that hits the `nil` branch and is a safe no-op.

The test helper `cleanup_stream/1` should also use `abort_stream/1` rather than `end_stream/1` so dangling registrations from race-robustness tests don't accumulate on the singleton Display across the suite.

## Issue 2 — Multi-stream final partial line dropped

**Edits in `lib/jido_claw/display.ex`:**

Replace the two `flush_line_buffer/2` clauses at `display.ex:566-571`:

```elixir
defp flush_line_buffer(%{line_buffer: <<>>}, state), do: state

defp flush_line_buffer(%{line_buffer: buf, agent_id: agent_id}, state) do
  # Multi-stream mode buffers an unterminated final line until a newline.
  # Terminal events flush whatever's left with the agent prefix.
  IO.binwrite(prefix_each_line(buf, agent_id))
  IO.write("\n")
  state
end
```

`prefix_each_line/2` already handles a newline-free buffer correctly (returns `"[<agent>] <buf>"`). `split_at_last_newline/1` guarantees `buf` contains no newlines — only the post-last-newline tail is buffered.

Single-stream mode is unaffected because `emit_chunk/3` writes combined bytes directly via `IO.binwrite/1` and leaves `line_buffer: <<>>`, so flush always hits the empty-clause.

## Issue 3 — `:output_limit_exceeded` captured preview

**Edits in `lib/jido_claw/shell/session_manager.ex`:**

1. **Host/VFS path** at `do_collect/5` lines 1065-1070 — fold a finalized preview into `error.context`:
   ```elixir
   {:jido_shell_session, ^session_id,
    {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}} = error}} ->
     preview = finalize_output(acc, streaming?)
     new_context = Map.put(error.context || %{}, :preview, preview)
     {:error, %{error | context: new_context}}
   ```

2. **SSH path** at `do_collect_ssh/6` — add a dedicated `:output_limit_exceeded` clause **before** the generic `%Jido.Shell.Error{}` clause (currently at lines 1168-1169) that returns the same `%Jido.Shell.Error{}` shape with preview-augmented context:
   ```elixir
   {:jido_shell_session, ^session_id,
    {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}} = error}} ->
     preview = finalize_output(acc, streaming?)
     new_context = Map.put(error.context || %{}, :preview, preview)
     {:error, %{error | context: new_context}}
   ```

   The existing generic `SSHError.format/2`-based clause stays for connect/timeout/start_failed errors — those have no `acc` semantics worth preserving.

This unifies the host and SSH return shape for `:output_limit_exceeded`: both return raw `%Jido.Shell.Error{}` structs with `context.preview` added. RunCommand already propagates these structs unchanged. Existing test (`run_command_test.exs:332-363`) continues to pass because it only asserts presence/types of `emitted_bytes` and `max_output_bytes`. `finalize_output/2` already applies the streaming-aware 50 KB cap with the explicit truncation note (session_manager.ex:1189-1203), so preview size is bounded.

**Note on shape consistency:** SSH errors for non-output-limit cases (timeout, start_failed, connect rejected) keep returning `{:error, "<formatted string>"}` via `SSHError.format/2`. Only the `:output_limit_exceeded` branch switches to the structured shape, matching host/VFS.

## Test additions

### `test/jido_claw/display_test.exs`

Add to the existing "start_stream/3 + end_stream/1 lifecycle" describe block:

```elixir
test "abort_stream drops registration unconditionally", %{sid: sid} do
  :ok = Display.start_stream(sid, "agent-a", "run_command")
  Display.abort_stream(sid)
  state = drain_state()
  refute Map.has_key?(state.streaming_sessions, sid)
end

test "abort_stream allows a fresh start_stream for the same sid", %{sid: sid} do
  :ok = Display.start_stream(sid, "agent-a", "run_command")
  Display.abort_stream(sid)
  _ = drain_state()
  assert :ok = Display.start_stream(sid, "agent-b", "run_command")
end

test "end_stream on entry without prior terminal event keeps it draining",
     %{sid: sid} do
  :ok = Display.start_stream(sid, "agent-a", "run_command")
  Display.end_stream(sid)
  state = drain_state()
  assert %{end_requested?: true, done?: false} = state.streaming_sessions[sid]
end
```

Add to "multi-stream prefix" describe block:

```elixir
test "terminal event flushes buffered partial-line tail with agent prefix",
     %{sid_a: a, sid_b: b} do
  :ok = Display.start_stream(a, "alice", "run_command")
  :ok = Display.start_stream(b, "bob", "run_command")

  io =
    capture_display(fn ->
      # Unterminated final fragment from alice while two streams active.
      send_event(a, {:output, "tail"})
      send_event(a, :command_done)
    end)

  assert io =~ "[alice] tail"
end
```

### `test/jido_claw/tools/run_command_test.exs`

Extend the existing "cap overflow returns ..." test (around line 332-363) by adding two preview assertions after the existing context assertions:

```elixir
assert is_binary(ctx.preview)
# Command emits zero-padded sequence numbers; first lines must be in preview.
assert ctx.preview =~ "0000000000000000001"
# Preview is bounded — finalize_output streaming cap is 50 KB.
assert byte_size(ctx.preview) <= 50_000 + 100
```

### `test/support/fake_ssh.ex`

Add a new branch above the existing `__fake_output_overflow__` clause (around line 110-114):

```elixir
String.contains?(command_str, "__fake_streaming_overflow__") ->
  # Multiple chunks emitted as :output (each within cap), then a chunk
  # that pushes past the cap. With test override = 100 KB streaming cap,
  # 4 × 30 KB chunks fit (120 KB cumulative — last chunk rejected).
  for _ <- 1..4 do
    send(caller, {:ssh_cm, conn, {:data, channel_id, 0, String.duplicate("x", 30_000)}})
  end
  send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
  send(caller, {:ssh_cm, conn, {:eof, channel_id}})
  send(caller, {:ssh_cm, conn, {:closed, channel_id}})
```

### `test/jido_claw/shell/session_manager_ssh_test.exs`

Add a streaming-mode SSH overflow test using the new FakeSSH branch:

```elixir
test "SSH :output_limit_exceeded preserves captured preview in error.context",
     %{workspace_id: ws, tmp: tmp} do
  assert {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}, context: ctx}} =
           SessionManager.run(
             ws,
             "echo __fake_streaming_overflow__",
             10_000,
             project_dir: tmp,
             backend: :ssh,
             server: "staging",
             stream_to_display: true,
             agent_id: "main",
             tool_name: "run_command"
           )

  assert is_binary(ctx.preview)
  assert byte_size(ctx.preview) > 0
  assert byte_size(ctx.preview) <= 50_000 + 100
end
```

(Adapt the setup block from existing tests in this file — `FakeSSH.bind_test_pid/0`, `FakeSSH.set_mode(:normal)`, `ServerRegistry.replace_servers_for_test/1`, the `@staging` entry, etc. The existing setup doesn't currently inject `stream_to_display:` to SSH; the SSH overflow path triggers regardless of streaming because the new FakeSSH branch emits enough bytes to exceed the lowered cap.)

## Verification

End-to-end checks the fixes hold and no regressions surfaced:

```bash
mix compile --warnings-as-errors
mix test test/jido_claw/display_test.exs
mix test test/jido_claw/tools/run_command_test.exs
mix test test/jido_claw/shell/session_manager_ssh_test.exs
mix test
mix format
```

Expectations:
- All four targeted suites pass with the new tests included.
- Full suite: 1280 + 4 new tests, 0 failures.
- `mix format` rewrites no files (or only the changed files).

Manual smoke (optional): run the REPL with `mix jidoclaw`, issue a `run_command` against a path that triggers Display to subscribe, then run a follow-up streaming command — confirm the status bar's `⟲ streaming` segment doesn't latch on after a rejected first command.
