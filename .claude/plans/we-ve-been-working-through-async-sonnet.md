# AR-5 Follow-up — Close the `send_to_agent` doctrine race

## Context

The code review of AR-5 (Central Doctrine Injection into Sub-Agents) found one **[P2]**
race, now **validated**:

- `spawn_agent.ex:111` registers the child in `AgentTracker` **synchronously** (a blocking
  `GenServer.call`) before `run/2` returns — at which point the child is externally
  addressable (tracker entry + Jido Registry).
- The doctrine injection (`JidoClaw.Startup.inject_subagent_prompt/3`) runs **async**, inside
  the orchestration `Task`, *after* `mcp().ensure_attached/3` — `spawn_agent.ex:167` →
  `:173`. The `ensure_attached` call ahead of it can block up to 8s, widening the window.
- So `spawn_agent` returns while the worker is addressable but still on jido_ai's **default
  ReAct prompt** (no doctrine yet).
- A fast `send_to_agent` follow-up dispatches a turn through `send_to_agent.ex:87`'s task,
  which calls `ensure_attached` (`:95`) but **never** `inject_subagent_prompt`, then runs the
  turn at `:100`. The first follow-up can miss AR-5's prompt.

This is a real asymmetry: every turn surface re-ensures MCP tools, but only spawn and the
skill-step path inject doctrine. **`agent_runner.ex:72` injects synchronously** inside `run/4`'s
`with` body before its single-shot turn — no race there, no change needed. The gap is
**`send_to_agent` only**.

**Fix (chosen): re-ensure doctrine on the follow-up path**, mirroring how `ensure_attached`
is already called there. Rejected the alternative (move spawn's injection synchronous) because
it adds DB+file I/O to the spawn caller's critical path, reverses AR-5's deliberate async
design, and still leaves `send_to_agent` reliant on prompt persistence with no recovery if the
spawn-time injection ever failed (it's best-effort and returns `:ok` even on failure). The
re-ensure path is self-healing and per-turn correct.

**Why it's safe to repeat:** `Jido.AI.set_system_prompt/2` *replaces* the prompt (writes
`config.system_prompt` wholesale — `react/strategy.ex:868-887`), it does not append, so
re-injecting the same template's doctrine overwrites with identical-or-fresher bytes. No
duplication. No tracker flag is added — plain replace-semantics is sufficient; revisit only if
profiling shows the per-follow-up build cost matters.

## Change 1 — `lib/jido_claw/tools/send_to_agent.ex`

Inside `dispatch/6`'s supervised task, **after** the `mcp().ensure_attached(pid, template_name,
8_000)` at `:95` and **before** the `try` at `:97`, add the fire-and-forget injection. All three
args are already in scope (`pid` from `whereis`, `template_name` = `entry.template`,
`child_tool_context` built at `:49-53`):

```elixir
            _ = mcp().ensure_attached(pid, template_name, 8_000)

            # AR-5: re-inject the doctrine system prompt before the follow-up
            # turn. A follow-up can outrun the spawn's async injection, so
            # without this the first follow-up could run on the default ReAct
            # prompt. Safe to repeat (set_system_prompt replaces, never
            # appends); best-effort + gated, mirrors the ensure_attached above.
            _ = JidoClaw.Startup.inject_subagent_prompt(pid, template_name, child_tool_context)

            try do
```

Placement is load-bearing: **inside** the task (off the caller path) and **before**
`SubagentTranscript.run/5` (`:100`), so the injection — a blocking call sequenced ahead of the
turn in the same task — is guaranteed to land before that follow-up's turn runs. Use the
fully-qualified `JidoClaw.Startup.inject_subagent_prompt` (no new alias), matching
`spawn_agent.ex:174` and `agent_runner.ex:72`. The `_ =` prefix keeps `compile_check` clean
(it returns `:ok`).

## Intentional behavior — prompt freshness on re-injection

Re-injection rebuilds via `SubagentPrompt.build(template_name, child_tool_context)` using the
**follow-up call's** `child_tool_context`, not the original spawn context. This is a deliberate,
documented decision:

- **Stable (load-bearing) tiers are unaffected:** the role (worker module `description/0`) and
  the `## DOCTRINE` block (compile-time priv-file slices via `Doctrine.for_template/1`) are
  identical regardless of context — the AR-5 contract never drifts.
- **Dynamic tiers reflect current state:** the Memory-Blocks tier (`Scope.resolve` →
  `list_blocks_for_scope_chain`) and `JIDO.md` are re-read at follow-up time, so they can refresh
  or differ from spawn time. The scope itself stays stable for legitimate follow-ups —
  `send_to_agent` re-applies the template's `forward_context` every turn (`:41-43`) and the
  tenant gate holds — so drift is limited to memory blocks added/edited or `JIDO.md` edited
  between spawn and follow-up. Re-reading those dynamic tiers per follow-up is intentional and
  acceptable.
- **Out of scope:** byte-stable per-child prompts sourced from a stored spawn-time context. If
  that's ever required, persist the spawn `child_tool_context` (e.g. on the `AgentTracker` entry)
  and rebuild from it. Not needed now.

## Change 2 — wiring test in `test/jido_claw/tools/send_to_agent_test.exs`

Add one `@tag :capture_log` test proving the seam fires **before** the follow-up turn. The
telemetry event only fires when `set_system_prompt` returns `{:ok, _}` (`startup.ex:184`), so
the agent **pid must be a real Jido.AI worker** — but the **template module** is the existing
`BlockingWorker` so the turn is observable and never calls an LLM. `template.module` (run by
`SubagentTranscript.run`) is independent of `pid` (passed to `set_system_prompt`), which lets us
mix a real pid with a fake turn.

Reuse the file's existing `BlockingTemplates`/`BlockingWorker` (`:120-144`) **unchanged** — its
`BlockingTemplates.get("docs_writer")` already maps to `BlockingWorker`, so the new test uses the
`"docs_writer"` template throughout (do **not** touch `BlockingTemplates`; adding/altering clauses
risks the existing re-engagement tests). Reuse the real `AgentTracker` re-engagement pattern
(`:299-342`). Add a tiny fake runtime whose `whereis` returns the real pid (decouples from
Registry lookup mechanics):

```elixir
defmodule RealPidJido do
  @moduledoc false
  @spec whereis(String.t()) :: pid() | nil
  def whereis(_agent_id), do: Application.get_env(:jido_claw, :send_to_agent_real_pid)
end
```

Test body:

1. Override env: `agent_tracker` → real `JidoClaw.AgentTracker` (reset it), `agent_templates` →
   `BlockingTemplates` (`"docs_writer"` → `BlockingWorker`, the existing clause), `jido_runtime` →
   `RealPidJido`, `send_to_agent_test_pid` → `self()`, and **`:doctrine, enabled?: true`** (flag is
   OFF globally, so a deleted call would never fire — that's the regression point). Save/restore
   `:doctrine` and delete `:send_to_agent_real_pid` in `on_exit`.
2. Start a real worker: `{:ok, pid} = JidoClaw.Jido.start_subagent(JidoClaw.Agent.Workers.DocsWriter,
   id: tag)`; `put_env(:send_to_agent_real_pid, pid)`. Register + flush to a terminal entry so the
   follow-up cleanly reactivates: `AgentTracker.register(tag, pid, "docs_writer", "initial",
   tenant_id: @tenant_id)` → `mark_complete(tag, :done)` → `_ = AgentTracker.get_state()`.
   `on_exit`: `JidoClaw.Jido.stop_agent(pid)` (if alive) + `AgentTracker.reset()`.
3. Attach a `[:jido_claw, :agent, :prompt_injected]` handler that sends `{:injected, metadata}`.
4. `assert {:ok, %{status: "message_sent"}} = SendToAgent.run(%{agent_id: tag, message:
   "follow-up"}, ctx())` (ctx is tenant-only → correlation is cache-only, no DB).
5. **Ordering proof:**
   ```elixir
   assert_receive {:ask_sync_started, worker_pid, "follow-up"}, 10_000
   assert_received {:injected, metadata}          # must ALREADY be in the mailbox
   assert metadata.source == :doctrine
   assert metadata.template == "docs_writer"
   send(worker_pid, :release)
   ```
   `BlockingWorker.ask_sync` signals `{:ask_sync_started, …}` then blocks. Because the injection
   runs earlier in the same sequential task, by the time the worker signals its turn the
   `{:injected}` message is already enqueued — so the no-wait `assert_received` succeeds in the
   fixed code and would fail if the call were placed after the turn. This is exactly "injection
   fires before the worker receives `ask_sync`."

Existing `send_to_agent` tests are unaffected: the global flag is OFF, so the new call is a pure
no-op `:ok` (no build, no `set_system_prompt`) under their fakes.

## Verification

- Targeted: `mix test test/jido_claw/tools/send_to_agent_test.exs` and
  `test/jido_claw/tools/spawn_agent_test.exs` (the AR-5 spawn wiring test must stay green).
- Pre-stage while iterating: `mix format`, `mix jidoclaw.compile_check` (zero warnings — the
  `_ =` prefix covers the fire-and-forget call), `mix credo --strict` (the new comment avoids the
  ExSlop step-comment trap; `RealPidJido` carries `@moduledoc false` + a `@spec`).
- **Done gate:** `mix precommit` succeeds. Run it bare in the background and read the tail —
  never pipe to `tail` (it masks the exit code). No new tool, dep, module, or public function, so
  `system_prompt.check`, `deps.unlock --unused`, and dialyzer are unaffected.

## Critical files

- Edit: `lib/jido_claw/tools/send_to_agent.ex` (one line + comment in `dispatch/6`'s task).
- Edit: `test/jido_claw/tools/send_to_agent_test.exs` (one fake module + one ordering test).
