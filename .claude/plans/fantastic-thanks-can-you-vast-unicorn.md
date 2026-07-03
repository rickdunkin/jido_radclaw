# Make the LLM stubs emit terminal signals (`ai.request.completed` / `ai.request.failed`)

## Context

The test suite's LLM calls are stubbed, so the `ai.request.completed` terminal signal — normally published to `JidoClaw.SignalBus` by the `JidoClaw.AgentServerPlugin.Recorder` plugin when a real agent turn finishes — never fires. Every dispatcher path that calls `JidoClaw.Conversations.Recorder.flush/2` therefore blocks for the full `:recorder_flush_timeout` (50ms in test) and logs `[Recorder.flush] timeout`. A full run hits **~500 timeouts ≈ 25s of dead wait** in the 158.7s serial suite, plus 500 lines of log noise, and the flush barrier is never actually exercised.

Fix: emit the terminal signal from the **test stubs** — semantically faithful, since the stubs replace the very runtime that emits it in production. Expected: serial ~159s → ~135s, `composer_durable_test.exs` 27.8s → ~22s, near-zero flush warnings. **Zero production-code changes.**

## Verified mechanics (all confirmed against source)

- **Emit recipe** (proven in-tree at `test/jido_claw/conversations/recorder_test.exs:546-563`): `Jido.Signal.new(type, %{request_id: rid}, source: "/test")` + `Bus.publish(JidoClaw.SignalBus, [signal])`. The Recorder reads `data.request_id` via `MapKeys.coalesce_field` (atom or string key); no other payload fields needed on this untyped path.
- **Both terminal types are equivalent for the barrier**: `recorder.ex:333-343` — the `"ai.request.completed"` and `"ai.request.failed"` clauses are parallel (same field, same `finalize_request`). We can therefore emit the semantically-matching type per stub.
- **Race-free by construction**: `Bus.publish` (partition_count 1, inline pid dispatch in `deps/jido_signal/.../dispatch/pid.ex:136-139`) returns only after the signal is in the Recorder's mailbox; a later `flush` call lands behind it (FIFO). And flush-after-finalize returns `:ok` immediately via `recent_completed_set` (512-LRU, `recorder.ex:217-224`) — order-independent either way.
- **Guards**: `finalize_request(nil)` is a no-op → only emit for binary request_ids. `Bus.whereis/1` (`bus.ex:309`, same guard the Recorder uses at `recorder.ex:245`) makes the helper a clean no-op if the bus is down; `Bus.publish` never raises on a dead bus.
- **Side effect**: finalizing runs `Cache.delete(request_id)` on the correlation ETS cache. Exactly **one** test asserts cache presence after a stubbed turn (see step 6); everything else confirmed unaffected (no test asserts flush `{:error, :timeout}` via stubs or captures the timeout log; `recorder_test.exs:19-27` uses a nonexistent request_id with no stub involved).

## Implementation

### 1. New shared helper — `test/support/terminal_signal.ex` (only new file)

```elixir
defmodule JidoClaw.Test.TerminalSignal do
  @moduledoc false

  # Publishes the terminal signal (`ai.request.completed` / `ai.request.failed`)
  # that the real `JidoClaw.AgentServerPlugin.Recorder` plugin emits when an
  # agent run finishes, so stubbed LLM paths release `Conversations.Recorder`'s
  # flush barrier immediately instead of blocking to the test-capped timeout.
  # Both types hit the same finalize path (recorder.ex:333-343); pick the one
  # matching the stub's outcome. No-op for nil request_ids and when the
  # SignalBus isn't running.

  alias Jido.Signal.Bus

  @bus JidoClaw.SignalBus
  @completed "ai.request.completed"
  @failed "ai.request.failed"

  @spec emit_completed(String.t() | nil) :: :ok
  def emit_completed(request_id), do: emit_terminal(request_id, @completed)

  @spec emit_failed(String.t() | nil) :: :ok
  def emit_failed(request_id), do: emit_terminal(request_id, @failed)

  @doc "Emit for the request_id embedded in an `await_completion` `:result_path` opt."
  @spec emit_from_await(keyword(), String.t()) :: :ok
  def emit_from_await(opts, type \\ @completed) do
    case Keyword.get(opts, :result_path) do
      [:requests, request_id | _rest] -> emit_terminal(request_id, type)
      _other -> :ok
    end
  end

  defp emit_terminal(request_id, type) when is_binary(request_id) do
    with {:ok, _pid} <- Bus.whereis(@bus),
         {:ok, signal} <- Jido.Signal.new(type, %{request_id: request_id}, source: "/test") do
      _ = Bus.publish(@bus, [signal])
    end

    :ok
  end

  defp emit_terminal(_request_id, _type), do: :ok
end
```

Type rule: `emit_failed` where the stub's outcome is unambiguously a failure; shape-branch where the stub's response is configurable. House-style notes: `@moduledoc false` + `#` commentary matches sibling stubs; `@spec` on public functions (credo Specs); no bare rescue (reach --strict). Compiled via `elixirc_paths(:test)`, so it must pass the full precommit gauntlet.

### 2. Path A stubs (`:ask_runtime` `ask_sync/3`; request_id at `opts[:request_id]`)

- `test/support/handoff_dispatch_capture.ex:16-17` — after the `send(target, {:dispatch_capture, ...})`, branch on the configured response shape before returning it:
  ```elixir
  request_id = Keyword.get(opts, :request_id)

  case response do
    {:error, _reason} -> JidoClaw.Test.TerminalSignal.emit_failed(request_id)
    _ok -> JidoClaw.Test.TerminalSignal.emit_completed(request_id)
  end

  response
  ```
  Covers front_door, chat_composer_ack, chat_resume, cli/run_command, cron/dispatcher (agent route), handoff_dispatcher_integration. The `{:error, :timeout}` failure-path test (`handoff_dispatcher_integration_test.exs:213-240`) only asserts `preamble_consumed?` and the error return — unaffected.
- `test/support/pass_stub.ex:13-17` — `emit_completed(Keyword.get(opts, :request_id))` before `{:ok, ...}`.
- `test/support/echo_stub.ex:25-30` — **gated** `emit_completed` (see step 6):
  ```elixir
  if Application.get_env(:jido_claw, :echo_stub_emit_terminal, true),
    do: JidoClaw.Test.TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
  ```
- `test/jido_claw/cli/run_command_test.exs:34` — local `GateTrippingAsk.ask_sync/3`: `emit_completed` before its `{:ok, "I need approval..."}` return.

### 3. Path B async stubs (`:step_agent_server`; emit at `await_completion` — the point where production emits, i.e. run completion)

request_id arrives as `opts[:result_path] = [:requests, request_id]` (`agent_runner.ex:339-343`) → use `emit_from_await`.

- `test/support/jido_claw/route_composer/composer_stubs.ex`:
  - `StubAgentServer.await_completion/2` (:152): branch the emit inside the existing `case StubStore.fetch(request_id)` — `emit_completed(request_id)` in the `{:ok, canned}` branch, `emit_failed(request_id)` in the `:error` → `{:ok, %{status: :failed, result: {:no_canned_output, ...}}}` branch (consistent with the semantic-type rule). Covers composer_durable (112 timeouts), composer_loop, composer_self_heal_loop, composer_system_loop, replay, sensitive_route.
  - `BlockingAgentServer.await_completion/2` (:176): **emit after the sleep, before the failed return** — rename `_opts` → `opts`, then `TerminalSignal.emit_from_await(opts, "ai.request.failed")`. It models a *late* terminal run, not a never-completing one: it returns `{:ok, %{status: :failed, result: :blocked}}` after outliving `run_sync`'s timeout, and `composer_loop_test.exs:916` explicitly drains that late wave. Emitting there is faithful and removes its residual flush timeout.
  - `GatedAgentServer` (:196) — **no edit**: every completion path funnels through its delegation to `StubAgentServer.await_completion` (:207), so the emit added there covers it with a single emit. That includes the killed-mid-gate scenario (`composer_durable_test.exs:563`): the composer dies but the in-flight wave executor (async_nolink) survives, receives `:proceed`, and still delegates.
- `test/jido_claw/skills/steps/agent_runner_test.exs:666-760` — the 6 local fakes: change `await_completion(_pid, _opts)` → `(_pid, opts)` and prepend an emit. `ValidatedFakeAgentServer`, `ErrorFakeAgentServer`, `SummaryFakeAgentServer`, `ArtifactsFakeAgentServer`, `FreeFormFakeAgentServer`: `emit_from_await(opts)`. `FailedFakeAgentServer` (returns `status: :failed`): `emit_from_await(opts, "ai.request.failed")`.

### 4. Path B sync stubs (`ask_sync/3` reached via `SubagentTranscript.record_terminal` → flush)

- `test/jido_claw/tools/spawn_agent_test.exs:96` (`FakeWorker.ask_sync/3`): `emit_completed` before `:ok`; `:119` (`BlockingWorker`): emit after its `:release` receive — the run does complete. Both blocking workers currently ignore their opts (`_opts`-style heads) — rename to `opts` where the emit reads `opts[:request_id]`.
- `test/jido_claw/tools/send_to_agent_test.exs:163` (`FakeWorker`) and `:190` (`BlockingWorker`): same treatment, including the `_opts` → `opts` rename.
- `test/support/workflow_stubs.ex` — `ErrorStub` (:13) and `SecretErrorStub` (:56): `emit_failed` before their error returns. `CrashStub` (:34): `emit_failed` **before** the `raise` (the flush happens in AgentRunner's rescue path). `FlakyStub` (:79): branch on the attempt outcome — `emit_failed` for the failing attempts, `emit_completed` for the succeeding one (match its existing return-shape logic).
- `test/jido_claw/reasoning/compactor/coherence_test.exs:208` — calls `SubagentTranscript.record_result/3` **directly** with `"req_c1"` (no stub in the loop): add `TerminalSignal.emit_completed("req_c1")` immediately before that call.

### 5. Redundant per-test `recorder_flush_timeout: 50` overrides — remove 7, keep 1

Remove the now-redundant local overrides (their stubs now emit): `front_door_test.exs:52` (+ key in the put_env list at :41), `chat_composer_ack_test.exs:46` (+ :37), `chat_resume_test.exs:114` (+ :104), `send_to_agent_test.exs:225` (+ stale comment :222-224 + restore at :232), `cli/run_command_test.exs:82` (+ :61), `handoff_dispatcher_integration_test.exs:55` (+ :45 + restore :61), `cron/dispatcher_test.exs:56` (+ :48 + restore :64).
**Keep `subagent_transcript_test.exs:13`** — it drives `record_terminal` directly with no stub in the loop, so it genuinely needs the cap.

### 6. The one breaking test — `agent_runner_test.exs:507-531`

"child correlation carries the parent's user_id end-to-end" scans the `:jido_claw_request_correlations` ETS table after an `EchoStub` turn and asserts the entry is still there (`assert cached != []`, :521) — finalization's `Cache.delete` would empty it. Fix: the gated emit from step 2 — in this test's body, capture the prior value and restore it, not blanket-delete:
```elixir
prev = Application.fetch_env(:jido_claw, :echo_stub_emit_terminal)
Application.put_env(:jido_claw, :echo_stub_emit_terminal, false)

on_exit(fn ->
  case prev do
    {:ok, val} -> Application.put_env(:jido_claw, :echo_stub_emit_terminal, val)
    :error -> Application.delete_env(:jido_claw, :echo_stub_emit_terminal)
  end
end)
```
(`fetch_env/2`, not `get_env/2`, so "unset" and "set to nil" restore differently.)
(Module is `async: false`, so no race; the restore pattern matches `send_to_agent_test`'s `restore_env`.) That test keeps today's pre-finalize semantics on the 50ms cap; every other EchoStub-driven test (visibility, replay_workflow, workflow_step_projection, step_retry, compiler_integration, agent_step, iterative_step) emits and speeds up. Verified no other EchoStub test reads the cache.

### 7. `config/test.exs:85-94` comment refresh

Keep `config :jido_claw, :recorder_flush_timeout, 50`. Rewrite the comment: the terminal signal is now emitted by test-support stubs (`JidoClaw.Test.TerminalSignal`), so flush returns immediately on stubbed paths; the 50ms cap remains as backstop for the paths that intentionally don't emit (subagent_transcript_test's direct flush, the opted-out correlation test at `agent_runner_test.exs:507`, Recorder bus-restart windows). Fill in the re-measured serial number from verification.

## Verification

1. Fast signal — heavy file: `mise exec -- mix test test/jido_claw/route_composer/composer_durable_test.exs` → expect ~27.8s → ~22s, and near-zero `Recorder.flush` warnings in its output.
2. Full serial run (log to scratchpad, no pipes on the command itself): expect **~500 → ~single-digit** `grep -c 'Recorder.flush'` — the residue is the intentional non-emitters (subagent_transcript_test's several direct flush calls, recorder_test's timeout-contract test, the opted-out correlation test) plus any bus-restart stragglers; all 4305 passing, wall ~135s. Record the number for the config comment (step 7).
3. Partitioned parity: `scripts/test-partitioned.sh` → all partitions green, total wall should drop below ~71s.
4. Gates: `mise exec -- mix precommit` in background, read tail — watch dialyzer on the helper's `with`, reach/credo on the new `test/support` file.

## Wrap-up

Test-only change: no AGENTS.md update needed. Finish commit-ready per git policy: list files to stage (new helper, ~10 stub/test files, config/test.exs) + suggested message, e.g. `fix: emit terminal signals from LLM stubs so Recorder.flush stops timing out`.
