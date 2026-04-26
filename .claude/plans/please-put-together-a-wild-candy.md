# v0.5.4 — Streaming Output to Display + `force:` → `backend:` consolidation

## Context

v0.5.4 of JidoClaw wires `jido_shell` transport events directly into `JidoClaw.Display`
so output renders in real time during long-running commands. Today, every backend
(host, VFS, SSH) already broadcasts chunks to subscribed pids via
`Jido.Shell.ShellSessionServer.broadcast/2`, but the only subscriber is
`JidoClaw.Shell.SessionManager`'s synchronous collector (`do_collect/4`,
`do_collect_ssh/5`), which assembles a single binary and returns it at command end.
Live output therefore never reaches the user until the command finishes — a poor UX
for `mix test`, long `git clone`, or noisy build commands.

This milestone also clears two items deferred from v0.5.3 that were explicitly
tagged `→ v0.5.4`:

1. **`force:` → `backend:` consolidation in `RunCommand`** — remove the legacy alias.
2. **Streaming SSH output to `Display`** — covered by the main streaming work since
   v0.5.3 ships the SSH backend.

(Roadmap §v0.5.4 + v0.5.3 "Out of scope (deferred) → v0.5.4")

### Roadmap vs reality

The roadmap text gets several mechanics wrong; this plan corrects them.

**Transport-event names.** Roadmap mentions `:stdout_chunk`, `:stderr_chunk`,
`:exit_status`, `:error`, `:start`. These names **do not exist** in jido_shell.
Actual catalog from `Jido.Shell.ShellSessionServer.broadcast/2` (and the JidoClaw
runtime patch at `lib/jido_claw/core/jido_shell_session_server_patch.ex:300-304`):

| Event tuple | Backend(s) | Notes |
| --- | --- | --- |
| `{:command_started, line}` | all | Server-side; fires after `run_command` accepted |
| `{:output, chunk}` | all | stdout+stderr merged (host: `:stderr_to_stdout`; SSH: no separate stderr) |
| `{:exit_status, code}` | **host only** | Local/VFS and SSH never emit this |
| `{:cwd_changed, cwd}` | Local/VFS only | from `cd` builtin |
| `:command_done` | all | zero-exit completion |
| `{:error, %Jido.Shell.Error{}}` | all | SSH non-zero exit lands here as `code: {:command, :exit_code}, context: %{code: n}` (see B.2 special case) |
| `:command_cancelled` | all | from explicit `cancel/1` |
| `{:command_crashed, reason}` | all | backend task DOWN with non-normal reason |

All events arrive at subscribers as `{:jido_shell_session, session_id, event}`.
`Jido.Shell.ShellSessionServer.subscribe/2` calls `Process.monitor(transport_pid)`
internally (`jido_shell_session_server_patch.ex:156`), so the second arg **must
be a pid** — never an atom/registered-name. Multi-subscriber works (broadcast
is `for pid <- transports, do: send(...)`), so adding `Display` as a second
subscriber alongside `SessionManager`'s collector is safe.

**Output-cap reality.**
- `JidoClaw.Shell.BackendHost.collect_port_output/5`
  (`lib/jido_claw/shell/backend_host.ex:131`) currently returns
  **`{:ok, :output_truncated}`** on overflow — silent truncation, not an error.
  v0.5.4 changes this to honor `Jido.Shell.Backend.OutputLimiter` semantics
  and return `{:error, %Jido.Shell.Error{}}` with the limiter's context shape
  (`%{emitted_bytes: bytes_so_far, max_output_bytes: cap}` — same as
  `Jido.Shell.Backend.OutputLimiter.check/3`). The over-limit chunk is **not**
  emitted (matches SSH/Local behavior; previous draft mistakenly kept it).
- `JidoClaw.Shell.SessionManager.finalize_output/1`
  (`lib/jido_claw/shell/session_manager.ex:1088`) **always** truncates the
  captured return to `@max_output_chars 10_000`, regardless of mode. v0.5.4
  raises this **only modestly** in streaming mode (10 KB → 50 KB preview)
  with an explicit truncation note. The model-facing return stays small
  precisely so streaming a multi-megabyte build log doesn't blow up the
  agent's context window. Live emission still goes up to 10 MB; only the
  captured echo is preview-sized.
- For Local/VFS, `Backend.Local` drops `:output_limit` from `exec_opts`. The
  shell server reads limits from `execution_context.limits.max_output_bytes`
  (`jido_shell_session_server_patch.ex:430`). v0.5.4 must plumb a real
  `execution_context: %{limits: %{max_output_bytes: 10_000_000}}` for Local/VFS
  streaming, not just an `:output_limit` opt.

**MCP-mode collision.** Display writes to stdout (raw `IO.write` + ANSI codes).
JidoClaw's MCP server uses **stdio for JSON-RPC**. A streaming command with
`stream_to_display: true` while running under `mix jidoclaw --mcp` would
corrupt the JSON-RPC framing. v0.5.4 gates `stream_to_display:` off in MCP mode.

**Multi-agent concurrency reality.** `SessionManager.run/4` is a `GenServer.call`
that synchronously runs the command inside the SessionManager process. Multiple
agents calling `run_command` therefore **serialize globally** at SessionManager.
This is a pre-existing constraint — v0.5.4 does not lift it. Streams keyed by
`session_id` still need to handle the case where two streams briefly coexist in
Display's state (e.g. terminal event for stream A still being processed when
stream B starts), but truly interleaved live chunks from two simultaneous
commands are not possible today.

---

## Part A — `force:` → `backend:` consolidation (deferred from v0.5.3)

### Why now

v0.5.3 left `force:` as a transitional alias next to the new `backend:` param.
Two ways to spell the same intent in a single tool param invites bugs and is the
kind of API thicket better cleared before adding `stream_to_display:`. Hard-remove
per roadmap text — no warn-and-route fallback.

### Changes

**`lib/jido_claw/tools/run_command.ex`**
- Drop `force:` from schema (line 56).
- Strip the legacy alias paragraph from `@moduledoc` (line ~20).
- Drop the `force: Map.get(params, :force)` opt forwarded to SessionManager (line 128).
- `coerce_backend/1` and `coerce_backend_param/2` already cover the live param —
  no other dispatch changes needed.

**`lib/jido_claw/shell/session_manager.ex`**
- Drop the `force:` branch in `resolve_target/3` (lines 800-811). Precedence
  becomes `backend: :ssh` (with `server`) > `backend: :host` > `backend: :vfs` >
  classifier-routed default. No more conflict resolution between `force:` and
  `backend:`.
- Update doc/`@spec` comments at lines 24, 80 to drop legacy mentions.

**Test migration — type-aware**

`SessionManager.resolve_target/3` expects atom backends; `RunCommand`'s schema is
string-typed and coerces internally. Migrate accordingly:

| Test file | Replacement |
| --- | --- |
| `test/jido_claw/tools/run_command_test.exs` | `force: :host` → `backend: "host"` (string — public RunCommand API) |
| `test/jido_claw/shell/session_manager_*.exs` (4 files) | `force: :host` → `backend: :host` (atom — direct SessionManager API) |
| `test/jido_claw/vfs/workspace_test.exs` | `force: :host` → `backend: :host` (atom; tests call SessionManager.run/4 directly) |

Two tests are deleted outright (their assertions cease to be meaningful):
- `test/jido_claw/tools/run_command_test.exs:227-232` — `"legacy force: :host
  still works"` — coverage parity already exists in `backend:` tests at lines
  184-225.
- `test/jido_claw/shell/session_manager_vfs_test.exs:178` — `"force: :host wins
  over backend: :vfs on conflict"` — the precedence is no longer ambiguous.

**Verification gate:** `grep -rn "force:" lib/ test/` returns zero matches after
the change.

---

## Part B — Streaming output to Display

### B.1 Stream lifecycle lives **entirely inside `SessionManager`**

The previous draft had `RunCommand` calling `Display.start_stream` before
`SessionManager.run/4`. That's wrong: concurrent callers (or even back-to-back
queued calls) would register multiple pending streams while waiting for
SessionManager's serialized GenServer call. Same-workspace queued calls would
overwrite each other before SessionManager resolved the actual session_id.

**Design:** `SessionManager` is the single owner of every stream's `start →
subscribe → run → unsubscribe → end` sequence. `RunCommand` only signals intent.

**`RunCommand.run/2`** — when `stream_to_display: true`:
1. **MCP-mode guard** — `Application.get_env(:jido_claw, :serve_mode) == :mcp`
   → log debug, drop the streaming flag, fall through to non-streaming path.
2. **System.cmd fallback gate** — if `SessionManager` is unregistered (existing
   path at lines 171-184), `stream_to_display:` is ignored entirely (no Display
   interaction); command runs via `System.cmd` and captured output returns as
   today. (Otherwise we'd start a stream that never gets shell events.)
3. Otherwise pass `stream_to_display: true, agent_id: agent_id, tool_name:
   "run_command"` opts to `SessionManager.run/4`. SessionManager handles
   everything else.

`agent_id` resolves from `get_in(context, [:tool_context, :agent_id]) || "main"`.

**`SessionManager.run/4`** — when opts include `stream_to_display: true`:

```
handle_local_run/6 (or handle_ssh_run/6):
  resolve_target/3 + ensure_session/3   # final session_id known
  display_pid = GenServer.whereis(JidoClaw.Display)
  if display_pid do
    case Display.start_stream(session_id, agent_id, tool_name) do
      :ok       -> proceed_with_streaming
      {:error, _} -> log_debug; proceed_without_streaming
    end
  else
    proceed_without_streaming
  end

  proceed_with_streaming:
    try do
      case ShellSessionServer.subscribe(session_id, display_pid) do
        {:ok, :subscribed} ->
          ShellSessionServer.run_command(session_id, command, exec_opts)
          collect_*(session_id, timeout)
        {:error, _} = err ->
          err
      end
    after
      ShellSessionServer.unsubscribe(session_id, display_pid)  # no-op if subscribe failed
      Display.end_stream(session_id)                            # cast — guaranteed cleanup
    end
```

The `try/after` ensures unsubscribe and `end_stream` fire even if
`subscribe/2` itself failed (rare after session resolution but possible if the
server dies between resolve and subscribe), keeping Display from getting stuck
in streaming mode. `unsubscribe/2` against a non-existent subscription is a
no-op in `ShellSessionServer`.
`Display.start_stream/3` is a **`GenServer.call`** (not cast) so the metadata
is installed in Display's state before the first `subscribe` returns and
broadcasts can land. If the call times out or returns `{:error, _}` (Display
busy / shutting down), SessionManager logs and runs without streaming.

This wiring guarantees:
- Streams keyed by the **resolved** `session_id`, not `workspace_id`.
- Host (`<workspace>:host`), VFS (`<workspace>:vfs`), and SSH
  (`<workspace>:ssh:<server>`) sessions are persistent — the same
  `session_id` is reused across back-to-back commands within a workspace, not
  freshly minted per command. Display's `start_stream/3` therefore rejects
  reuse against an already-registered entry (B.2) so the next command's
  stream can't pick up a still-draining prior stream's chunks.
- `Display.end_stream/1` is sent only after `unsubscribe/2` returns. The server
  has stopped broadcasting to Display by then, so all in-flight transport
  events for this session are already in Display's mailbox (FIFO from server)
  and will be drained before the cast is processed (cast lands at the back of
  Display's mailbox). Plus the explicit `done?`/`end_requested?` belt-and-suspenders
  in B.2 below covers any edge case.

### B.2 Display chunk handling

State additions in `lib/jido_claw/display.ex` (state struct line 25-44):

```elixir
streaming_sessions: %{}
# session_id => %{
#   agent_id, tool_name, bytes_streamed, started_at,
#   line_buffer,        # pending partial line for multi-stream prefix
#   dropped_warned?,    # true after the one-shot backpressure warning fired
#   done?,              # true after a terminal transport event arrived
#   end_requested?      # true after Display.end_stream/1 was called
# }
```

Keyed by `session_id`. Multiple concurrent streams from different sessions can
coexist in state (rare given SessionManager serialization, but correct).

**New API:**
- **`Display.start_stream(session_id, agent_id, tool_name)`** — `GenServer.call`.
  Returns `:ok` when the entry is freshly registered. Returns
  `{:error, :stream_still_draining}` when an entry already exists for
  `session_id`. Host, VFS, and SSH sessions are all persistent
  (`<workspace>:host`, `<workspace>:vfs`, `<workspace>:ssh:<server>`), so the
  same `session_id` is reused across back-to-back commands. Replacing an
  active entry would misattribute its lagging chunks to the next stream;
  rejecting forces the caller to fall back to non-streaming mode for that
  command, which preserves correctness over UX. SessionManager's existing
  `{:error, _} → proceed_without_streaming` branch handles the rejection
  cleanly — captured output still returns to the agent normally. On `:ok`
  clears active spinner via `\e[2K\r`. Header printing deferred until
  `{:command_started, line}` arrives.
- **`Display.end_stream(session_id)`** — cast. Sets `end_requested? = true`.
  If `done? = true` already, removes the entry. Otherwise leaves it; the
  terminal-event handler removes it once `done?` flips.

**Removal rule (the `done?`/`end_requested?` belt and suspenders):**
- Terminal transport events (`:command_done`, `{:error, _}`,
  `:command_cancelled`, `{:command_crashed, _}`) set `done? = true`. If
  `end_requested? = true`, remove. Else leave.
- `end_stream` cast sets `end_requested? = true`. If `done? = true`, remove.
  Else leave.
- The race "end_stream cast overtakes a lagging `{:output, _}`" can't actually
  happen given the FIFO ordering between unsubscribe and end_stream (B.1).
  But the flag pair removes the dependency on Erlang ordering subtleties — a
  free correctness margin.

**New `handle_info` clauses for `{:jido_shell_session, sid, event}`:**

Match clauses guard on `Map.has_key?(state.streaming_sessions, sid)`. Stragglers
arriving for an unknown sid (e.g. after both flags flipped and entry was
removed) match the catch-all at `display.ex:323` and are silently dropped.

| Event | Render |
| --- | --- |
| `{:command_started, line}` | print `\n[<agent_id>] <tool_name>: $ <line>\n`; clear spinner first |
| `{:output, chunk}` | bypass spinner; write chunk via `IO.binwrite`; bump `bytes_streamed`; multi-stream line prefixing (see below) |
| `{:exit_status, code}` | silent (covered by `:command_done`/`{:error, _}`) |
| `{:cwd_changed, _}` | silent |
| `:command_done` | newline if `line_buffer` non-empty; flip `done?`; remove if `end_requested?` |
| `{:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: n}}}` | render dim `[exit <n>]\n` (NOT red) — SessionManager re-routes this as `{:ok, %{exit_code: n}}` to caller; flip `done?`; remove if `end_requested?` |
| `{:error, err}` (any other shape) | render red `\e[31m! <Exception.message(err)>\e[0m\n`; flip `done?`; remove if `end_requested?` |
| `:command_cancelled` | render dim `[cancelled]\n`; flip `done?`; remove if `end_requested?` |
| `{:command_crashed, reason}` | render red `[backend crashed: <inspect reason>]\n`; flip `done?`; remove if `end_requested?` |

**Note:** `Exception.message/1`, not `Jido.Shell.Error.message/1` (which doesn't
exist as a function). `Jido.Shell.Error` is a `defexception`, so the standard
`Exception` protocol resolves it.

**Real-time, not throttled** (per roadmap "not swarm-box throttled"). Existing
`@render_throttle 100` and `@status_bar_interval 1000` do not apply to the
streaming path.

**Binary-safe chunk handling.** Shell chunks are raw bytes — possibly with
embedded `\r` (carriage-return progress bars), partial UTF-8 sequences, ANSI
escape sequences, and lines split across chunks. Implementation:

```elixir
defp emit_chunk(chunk, %{line_buffer: buf} = sess, state) do
  combined = buf <> chunk
  case map_size(state.streaming_sessions) do
    1 ->
      IO.binwrite(combined)
      %{sess | line_buffer: <<>>}  # let the terminal handle CR/ANSI naturally
    _ ->
      {complete_lines, remainder} = split_at_last_newline(combined)
      lines_with_prefix = prefix_each_line(complete_lines, sess.agent_id)
      IO.binwrite(lines_with_prefix)
      %{sess | line_buffer: cap_buffer(remainder, @line_buffer_cap)}
  end
end
```

`split_at_last_newline/1` uses `:binary.match/2` for `<<"\n">>`.
`cap_buffer/2` truncates partial-line buffer to `@line_buffer_cap 65_536` bytes
(emit + reset with one-time elision marker) to prevent unbounded growth on a
stream with no newlines (e.g. raw binary). Single-stream mode does **not**
prefix or split — terminal handles `\r` naturally for progress bars.

### B.3 Output-cap plumbing

**`lib/jido_claw/shell/backend_host.ex` — change overflow semantics**

`collect_port_output/5` (line 126-141) currently sends a `"\n... (output
truncated)"` chunk and returns `{:ok, :output_truncated}`. v0.5.4 calls
`Jido.Shell.Backend.OutputLimiter.check/3` directly (signature:
`check(chunk_bytes, emitted_bytes, output_limit)`):

```elixir
case OutputLimiter.check(byte_size(chunk), bytes_sent, output_limit) do
  {:ok, new_total} ->
    send(session_pid, {:command_event, {:output, chunk}})
    collect_port_output(port, session_pid, new_total, output_limit, deadline)
  {:limit_exceeded, %Jido.Shell.Error{} = error} ->
    Port.close(port)
    {:error, error}     # context already %{emitted_bytes:, max_output_bytes:} per OutputLimiter
end
```

The over-limit chunk itself is **not** emitted (matches SSH/Local; previous
draft mistakenly emitted a truncation marker). The `emitted_bytes` field in
the error context is the *attempted updated total* including the rejected
chunk's size — the chunk is not actually emitted to the transport, but the
error reports the byte count that would have been emitted had the limit
allowed it. Callers (Display, captured-output assembly) see the bytes that
were sent prior to the rejection.

`@max_output_bytes 50_000` becomes `max_output_bytes(opts)` honoring
`Keyword.get(opts, :streaming, false)` → `10_000_000` else `50_000`.

`BackendHost.execute/4` keeps explicit `:output_limit` precedence so existing
callers that pass it directly (e.g. the SSH plumbing in `SessionManager`) are
not shadowed by the new streaming default:

```elixir
output_limit = Keyword.get(exec_opts, :output_limit, max_output_bytes(exec_opts))
```

**`lib/jido_claw/shell/session_manager.ex` — three-cap streaming awareness**

| Cap site | Non-streaming | Streaming |
| --- | --- | --- |
| `BackendHost.@max_output_bytes` (emission) | 50 KB | 10 MB |
| SSH `output_limit:` in `exec_opts` (line 1000) | 1 MB (`@max_ssh_output_bytes`) | 10 MB |
| Local/VFS `execution_context.limits.max_output_bytes` (new) | (n/a today; default uncapped) | 10 MB |
| `SessionManager.finalize_output/1` (returned to caller, line 1088) | 10 KB (`@max_output_chars`) | **50 KB preview** + truncation note |

The captured-return cap stays modest — model context survives a long stream:

```elixir
defp finalize_output(output, opts) do
  cap = if Keyword.get(opts, :streaming, false),
           do: @streaming_capture_preview,   # 50_000
           else: @max_output_chars            # 10_000

  if byte_size(output) > cap do
    binary_part(output, 0, cap) <>
      "\n... (output truncated; full output streamed live)\n"
  else
    output
  end
end
```

`@streaming_capture_preview 50_000`. Live render is full-fidelity (up to 10 MB);
agent-facing return is preview-sized.

**Local/VFS limit plumbing — `execution_context`, not `:output_limit`**

`Backend.Local` drops `:output_limit` from `exec_opts`; the shell server reads
limits from `execution_context.limits.max_output_bytes`
(`jido_shell_session_server_patch.ex:430`). For Local/VFS streaming,
`SessionManager.execute_command/3` builds:

```elixir
exec_opts = [
  execution_context: %{limits: %{max_output_bytes: max_output_bytes(streaming?)}}
]
```

For host backend, the existing `BackendHost.execute/4` gets `streaming:
streaming?` in opts so its internal cap function uses the right ceiling.

**Test cap override.** `config/test.exs` adds:

```elixir
config :jido_claw, :test_streaming_max_output_bytes_override, 100_000
```

`max_output_bytes/1` honors the override **only** on the streaming branch,
leaving the non-streaming 50 KB cap unchanged so existing non-streaming
overflow tests stay valid:

```elixir
defp max_output_bytes(opts) do
  if Keyword.get(opts, :streaming, false) do
    Application.get_env(:jido_claw, :test_streaming_max_output_bytes_override) || 10_000_000
  else
    50_000
  end
end
```

The override is set only in `config/test.exs`; production runtime never sets
it. No `Mix.env()` reads at runtime.

### B.4 Backpressure (warn-and-drop-oldest)

Volume risk: a noisy build can flood Display's mailbox. Mitigation in Display's
`{:output, chunk}` handler:

```elixir
case Process.info(self(), :message_queue_len) do
  {:message_queue_len, n} when n > @backpressure_watermark ->
    drained = drain_oldest_chunks_for(sid, @drain_batch)
    maybe_warn_once(sid, drained, state)
  _ ->
    :ok
end
```

`@backpressure_watermark 1000`, `@drain_batch 500`. `drain_oldest_chunks_for/2`
does a selective `receive` on `{:jido_shell_session, ^sid, {:output, _}}` with
`after 0`, discarding up to N pending chunks for that stream.

`maybe_warn_once/3` emits one yellow line per stream:

```
\e[33m[<agent_id>] [output dropped to keep up — captured result is preview only]\e[0m\n
```

Wording explicitly does not promise complete captured output — `finalize_output/1`
already caps the preview at 50 KB even without backpressure.

### B.5 StatusBar streaming segment

**`lib/jido_claw/display/status_bar.ex`** — add `streaming_segment(state)`:
- `nil` when `state.streaming_sessions == %{}`.
- `{:optional, " \e[36m⟲\e[0m streaming"}` for one stream.
- `{:optional, " \e[36m⟲\e[0m streaming (#{n})"}` for n>1.

Insert into the `render/3` segment list (line ~33) as `{:optional, ...}` between
the progress bar and the cost segment. The existing `trim_optional/4` will drop
it gracefully on narrow terminals.

### B.6 Drive-by fix: throttle gate stuck open (proper state threading)

`lib/jido_claw/display.ex` — `throttled_swarm_render/1` at line 396 reads
`state.last_render` to gate at 100 ms but never writes back. Both this function
and `render_swarm_update/1` currently return values that callers ignore.

Fix:
1. `throttled_swarm_render/1` returns `{updated_state, :ok | :throttled}` and
   updates `last_render` on the rendered branch.
2. `render_swarm_update/1` returns updated state.
3. **All caller sites** in `display.ex` reassign:
   - `handle_info({:agent_completed, ...}, state)` at line 307
   - `handle_info(:status_bar_tick, ...)` at line 218
   - `handle_info(:render_swarm_header, ...)` at line 286 (already follows
     through; make consistent)

Without state threading, the gate stays permanently open. Mention in commit
message.

---

## Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/tools/run_command.ex` | drop `force:`; add `stream_to_display:` schema param; MCP-mode guard; System.cmd fallback gate; pass `stream_to_display:`/`agent_id:`/`tool_name:` opts to SessionManager |
| `lib/jido_claw/shell/session_manager.ex` | drop `force:` from `resolve_target/3`; own full stream lifecycle (start_stream → subscribe → run → unsubscribe → end_stream) inside `handle_local_run/6` and `handle_ssh_run/6`; streaming-aware `finalize_output/1` (50 KB preview + note); thread `execution_context.limits.max_output_bytes` for Local/VFS; bump SSH `output_limit` to 10 MB when streaming |
| `lib/jido_claw/shell/backend_host.ex` | replace `@max_output_bytes` constant with `max_output_bytes(opts)`; change overflow semantics from `{:ok, :output_truncated}` to `{:error, %Jido.Shell.Error{}}` with proper `OutputLimiter` context shape (`%{emitted_bytes:, max_output_bytes:}`); stop emitting the over-limit chunk |
| `lib/jido_claw/display.ex` | add `streaming_sessions` keyed by `session_id` with `done?`/`end_requested?` flags; `start_stream/3` (call) + `end_stream/1` (cast); `handle_info` clauses for transport events with binary-safe line buffering and SSH non-zero exit special case; backpressure watermark; drive-by `last_render` state-threading fix |
| `lib/jido_claw/display/status_bar.ex` | add `streaming_segment/1`; insert into `render/3` segment list |
| `test/jido_claw/tools/run_command_test.exs` | migrate `force:` → `backend: "host"` (strings); delete legacy-alias test; new streaming tests using real `Display` + `ExUnit.CaptureIO.capture_io/1` |
| `test/jido_claw/shell/session_manager_*.exs` (4 files) | migrate `force:` → `backend: :host` (atoms); delete precedence test in `_vfs_test.exs:178` |
| `test/jido_claw/vfs/workspace_test.exs` | migrate 2 `force:` sites (atoms — direct SessionManager API) |
| `config/test.exs` | add `config :jido_claw, :test_max_output_bytes_override, 100_000` so overflow tests run fast |

(No new modules. No new dependencies.)

### Reused, not reinvented

- `Jido.Shell.ShellSessionServer.subscribe/2`, `unsubscribe/2` — already exist;
  reference template at `deps/jido_shell/lib/jido_shell/transport/iex.ex:114-144`.
- `JidoClaw.Display.StatusBar.trim_optional/4` — graceful narrow-terminal
  truncation already handles the new segment.
- `Jido.Shell.Backend.OutputLimiter.check/3`
  (`deps/jido_shell/lib/jido_shell/backend/output_limiter.ex`) — error-shape
  template for `BackendHost`'s overflow rewrite.
- `ExUnit.CaptureIO.capture_io/1` — used for verifying Display rendering in
  tests against the real Display GenServer.

---

## Implementation order

1. **Part A** — Mechanical, independent, easy to revert. Drop `force:`, migrate
   tests (atoms vs strings as noted), ensure full suite green.
2. **B.7 MCP-mode guard + System.cmd fallback gate** in `RunCommand` — ship
   with `stream_to_display:` schema param landing as a no-op (always falls
   through). Establishes the API surface without behavior change.
3. **B.3 BackendHost overflow rewrite** (`{:ok, :output_truncated}` →
   `{:error, %Jido.Shell.Error{}}`, OutputLimiter shape, drop over-limit chunk).
   Independent of streaming; tightens non-streaming overflow too. Update any
   tests asserting the old tuple.
4. **B.3 cap plumbing** — `:streaming` opt threaded through
   `RunCommand → SessionManager → BackendHost`; `execution_context.limits` for
   Local/VFS; raise `output_limit:` for SSH; streaming-aware `finalize_output/1`
   (50 KB preview + note).
5. **B.1 SessionManager owns lifecycle** — start_stream call, subscribe,
   try/after teardown.
6. **B.2 Display streaming state + handlers** — `done?`/`end_requested?` flags,
   handle_info clauses, line buffering, SSH exit-code special case. Unit-testable
   via direct `send/2` + `CaptureIO`.
7. **RunCommand `stream_to_display:` end-to-end wiring** — finishes the path.
8. **B.4 Backpressure watermark** — exercise with a flood test.
9. **B.5 StatusBar segment**.
10. **B.6 `last_render` state-threading fix**.

---

## Verification

### Compile + format gates
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `grep -rn "force:" lib/ test/` returns zero matches (Part A acceptance gate)

### Test suite
- `mix test` — full suite green. Test config sets a small
  `:test_max_output_bytes_override` (100 KB) so overflow tests run fast.
- New tests under `test/jido_claw/tools/run_command_test.exs`:
  - **Streaming roundtrip (host):** real `Display` + `ExUnit.CaptureIO.capture_io/1`
    around the test body. Run a streaming `run_command` printing 50+ lines;
    assert captured stdout includes the lines in order; assert agent receives
    captured-string preview ending with the `"... output truncated; full output
    streamed live"` note when output exceeds 50 KB.
  - **Cap overflow:** generate output past `:test_max_output_bytes_override`
    (100 KB) with `stream_to_display: true` → expect `{:error, _}` with
    `code: {:command, :output_limit_exceeded}` and `context: %{emitted_bytes:,
    max_output_bytes:}`.
  - **MCP-mode guard:** `Application.put_env(:jido_claw, :serve_mode, :mcp)`,
    confirm `stream_to_display: true` is silently ignored (no Display
    interaction; no stdout writes from Display); command still returns captured
    output.
  - **System.cmd fallback gate:** stop `JidoClaw.Shell.SessionManager`, run
    `RunCommand.run` with `stream_to_display: true`; assert no Display
    interaction and command falls through to `System.cmd` returning captured
    output.
  - **SSH non-zero exit special case:** mock SSH backend emitting
    `{:error, %Jido.Shell.Error{code: {:command, :exit_code}, context:
    %{code: 2}}}`; assert Display rendered dim `[exit 2]` (via `CaptureIO`),
    not red error; assert RunCommand returned `{:ok, %{exit_code: 2}}`.
- New tests under `test/jido_claw/display_test.exs`:
  - Send synthetic `{:jido_shell_session, sid, event}` messages directly to
    Display via `send(GenServer.whereis(JidoClaw.Display), ...)` after
    seeding `streaming_sessions` via `Display.start_stream/3`. Verify side
    effects via `CaptureIO` and `:sys.get_state/1`.
  - **Race robustness — output between `end_stream` and terminal event:** call
    `Display.end_stream(sid)` (sets `end_requested?`; `done?` still false), then
    send `{:jido_shell_session, sid, {:output, "late"}}`. Assert the late chunk
    **renders** (the entry is still live since `done?` is false). Then send a
    terminal event; assert the entry is now removed.
  - **Race robustness — output after both terminal and `end_stream`:** call
    `end_stream(sid)`, send a terminal event (entry removed via combined-flag
    rule), then send a really late `{:jido_shell_session, sid, {:output, _}}`.
    Assert it is silently dropped (catch-all clause hit), no crash.
  - **Back-to-back same `session_id` while prior still draining:** call
    `start_stream(sid, "agent-a", "run_command")` and immediately, before
    sending any terminal/end_stream messages, call `start_stream(sid,
    "agent-b", "run_command")` again. Assert second call returns
    `{:error, :stream_still_draining}`. Then send a terminal event +
    `end_stream(sid)` for the original; allow the cast to drain (e.g.
    `:sys.get_state/1` round-trip). Call `start_stream(sid, "agent-b",
    "run_command")` once more; assert `:ok` (entry now freshly registered
    against the persistent host/VFS session_id).
  - **Multi-stream prefix:** `start_stream` for two distinct session_ids,
    interleave chunks; assert each line prefixed with the right `[agent_id]`.
  - **Backpressure:** flood watermark; assert one warning emitted per stream;
    assert subsequent chunks render normally after backlog drains.
- Backend tests:
  - `test/jido_claw/shell/backend_host_test.exs` — update overflow assertion
    from `{:ok, :output_truncated}` to `{:error, %Jido.Shell.Error{}}` with
    proper context keys.
  - Cap function: assert `max_output_bytes(streaming: true) == 10_000_000`.

### Live verification (REPL)
1. `mix jidoclaw`
2. Have agent run `run_command(command: "for i in $(seq 1 5000); do echo line
   $i; sleep 0.001; done", stream_to_display: true)`. Lines render in real
   time. Captured return is 50 KB preview with truncation note.
3. SSH (`servers:` declared in `.jido/config.yaml`):
   `run_command(command: "yes | head -100", backend: "ssh", server: "test",
   stream_to_display: true)` — same live render with `[<agent_id>]` attribution.
4. SSH non-zero exit: `run_command(command: "exit 2", backend: "ssh", server:
   "test", stream_to_display: true)` — Display shows dim `[exit 2]`, agent
   receives `{:ok, %{exit_code: 2}}`.
5. Cap overflow: `run_command(command: "yes 'A'", stream_to_display: true)` →
   error within ~10 MB. Captured preview is 50 KB.
6. MCP mode: `mix jidoclaw --mcp`, send a tool-call with
   `stream_to_display: true` — JSON-RPC framing intact; captured result returned.
7. System.cmd fallback: covered by the unit test (`SessionManager` is supervised
   under `:rest_for_one` and restarts immediately after `Process.exit`, making
   a clean REPL repro flaky). The unit test temporarily unregisters via
   `Process.unregister(JidoClaw.Shell.SessionManager)` for deterministic
   verification; no live REPL step.
8. `/profile` indicator unchanged when streaming inactive; `⟲ streaming` segment
   appears alongside it during a long stream and trims out on narrow terminal.

### Manual regression spots
- `:swarm` mode rendering for non-streaming agents must still work. The
  `last_render` fix may change render cadence subtly — exercise multi-agent
  swarm runs and confirm bar still updates.
- Spinner (kaomoji) cancellation when a stream starts (`\e[2K\r` clear-line).
- `Display` crash + restart leaves no orphaned subscriptions: kill Display
  during a stream, watch SessionManager's own subscription continue, confirm
  Display restarts with empty `streaming_sessions`. (SessionManager's
  `Process.monitor`-based cleanup on the Display pid handles unsubscribe
  automatically inside ShellSessionServer.)

---

## Explicitly out of scope (still deferred from v0.5.3)

These v0.5.3 deferral items are **not** picked up by v0.5.4 — flagged here for
visibility, not for action:

| Item | Disposition |
| --- | --- |
| `/servers` REPL command (list, test connectivity, show auth mode) | → v0.5.3.1 |
| `jido status` SSH session count segment | → v0.5.3.1 |
| Auto-reconnect on dropped SSH sessions | revisit on user demand |
| Classifier extension for SSH (auto-route by path) | SSH stays explicit |
| Passphrase-protected private keys | requires upstream jido_shell hook |
| SSH jump-host / bastion chains | not assigned |
| Interactive/TTY-allocating sessions (`ssh -t`) | command-mode only |
| Key management UI / secret-store integration | not assigned |
| Truly concurrent multi-agent streaming (interleaved chunks from two simultaneous commands) | requires lifting SessionManager's GenServer-call serialization — separate milestone |

The two v0.5.3 items explicitly tagged `→ v0.5.4` (`force:` consolidation +
streaming SSH output) are addressed by Parts A and B above.
