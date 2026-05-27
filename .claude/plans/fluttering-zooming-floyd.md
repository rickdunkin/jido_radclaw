# T2-1 Handoff — code-review follow-up

## Context

The handoff feature implemented from `please-review-docs-exploration-jidoka-fe-imperative-volcano.md` went through review. Three P2 findings were raised; all three are valid against the code in `main` (`lib/jido_claw/tools/handoff.ex`, `lib/jido_claw/agent/handoff/router.ex`, `test/jido_claw/conversations/handoff_routing_integration_test.exs`). This plan resolves them and keeps the same shape the original plan established (best-effort side-effects, registry-as-truth, etc.).

The acceptance gate is `mix precommit`.

## Validation of findings

### Finding 1 — telemetry not correlated (VALID)

`emit_applied/2` (`tools/handoff.ex:272`) writes `%{event, status, handoff, name, to_template, conversation_id}`; `emit_failed/2` (`:287`) writes `%{event, status, name, error}`. Neither carries `:request_id`, `:tenant_id`, `:agent_id`, or `:from_template`. The collector keys traces by `metadata[:request_id]` (`trace/collector.ex:320`), so handoff events become orphan traces that `Trace.for_request/3` won't return. `extract_context/1` (`tools/handoff.ex:132`) already reads those fields — they're just not threaded into emission.

### Finding 2 — preamble not actually bounded (VALID)

`router.ex:141-156` truncates `message` and `summary` to 2_000 chars each, but `reason` is read as `handoff.reason || "not provided"` with no cap. `budget` is computed *after* `base` is built, so an unbounded `reason` blows the budget — Tidewave confirmed 14,250-byte preambles. The bound test at `router_test.exs:335` permits `<= 5_500` and never tries a huge reason.

### Finding 3 — integration test bypasses the dispatcher (VALID)

`handoff_routing_integration_test.exs` calls `HandoffRouter.resolve_session_owner/6` directly (`:104`) and marks the preamble consumed by hand (`:123`). The risky behavior — `preamble <> message`, dispatching to `routed_pid`, threading routed `tool_context.agent_id`/`agent_template` — lives in `cli/repl.ex:382-387` and `jido_claw.ex:218-228` and is uncovered by any integration test. A regression there would pass today's suite.

## Approach

Three slices, each independent and small. Verification: `mix precommit` plus targeted test runs.

### Slice 1 — Telemetry correlation

**Edit** `lib/jido_claw/tools/handoff.ex`

- Add `:agent_id` to the validated context returned by `extract_context/1` (`:132`). Today the function reads `agent_template` but not `agent_id`. After the change, `ctx_fields` exposes `agent_id` (best-effort — may be `nil` if the dispatcher didn't thread it) alongside the existing `tenant_id`, `runtime_session_id`, `session_uuid`, `request_id`, `actor`, `from_template`.
- Refactor `run/2` so `emit_applied` and `emit_failed` get their context from the right source:
  - **Success path**: thread the already-validated `ctx_fields` and the constructed `%Handoff{}` into `emit_applied`. `from_template`, `tenant_id`, `request_id`, `agent_id`, `conversation_id` come from the canonical validated values (`ctx_fields` for ids, `%Handoff{}` for `to_template`/`from_template`). Have `do_run/2` return `{:ok, payload, ctx_fields, handoff}` *internally* so the dispatch in `run/2` can call `emit_applied(payload, ctx_fields, handoff, started_mono)` without re-deriving anything. **The public `run/2` return value remains `{:ok, payload}` or `{:error, reason}` — the 4-tuple does not leak out of this module** (the shared `JidoClaw.Tools.Action` wrapper expects the 2-shape).
  - **Failure path**: introduce a private `base_telemetry/1` that pulls best-effort `request_id`, `tenant_id`, `conversation_id` (session_uuid), `agent_id`, `from_template` from the raw `context`, reusing the same nested-or-flat lookup `extract_context/1` does. Any field may be `nil`. `emit_failed` takes `(reason, params, base_telemetry, started_mono)` and additionally pulls the *attempted* `to_template` from raw `params` (when it's a binary), so "Unknown template" / "Cannot hand off to 'main'" traces still carry the user-visible value.
- Both emits put `request_id`, `tenant_id`, `conversation_id`, `agent_id`, `from_template`, `to_template` into metadata alongside the existing `:event`/`:status`/`:name`/`:handoff`. Drop nothing.
- While touching failure emission, add a fallback clause to `error_to_string/1`: `defp error_to_string(reason), do: inspect(reason)`. The current single binary-only clause (`tools/handoff.ex:304`) would `FunctionClauseError` on any non-binary failure reason that slips through.

**Edit** `test/jido_claw/tools/handoff_test.exs`

- After the existing `TraceTestHelpers.sync_collector/0` call in the happy-path test (`:120`), assert request + tenant correlation explicitly:
  ```elixir
  assert {:ok, trace} =
           JidoClaw.Trace.for_request({:request, request_id}, request_id,
             tenant_id: tenant_id
           )
  ```
  Then assert the trace's events include the handoff:applied event whose metadata carries every correlation field (request_id, tenant_id, conversation_id == session.id, agent_id == "main", from_template == "main", to_template == "reviewer"). Using `{:request, request_id}` as the target plus `tenant_id:` opt verifies *both* request correlation and tenant enforcement — the tenant filter at `trace.ex:153-156` short-circuits if the trace's tenant doesn't match.
- Add one failure-path correlation test (use the existing unknown-template case): assert `Trace.for_request({:request, request_id}, request_id, tenant_id: tenant_id)` finds the `:failed` event with `to_template == "nonexistent_template"` and the canonical error string.
- The existing tests pass `request_id` through `build_context/4` already (`:36`), so no setup changes are needed beyond capturing it from the ctx.

### Slice 2 — Preamble budget (single global cap)

**Edit** `lib/jido_claw/agent/handoff/router.ex`

- Rename the existing `@max_*_chars` constants to `@max_*_bytes` to match what the code actually enforces (`byte_size/1`-based truncation, not graphemes). The invariant we care about is prompt size; byte naming is clearer. Apply to all three:
  - `@max_preamble_chars` → `@max_preamble_bytes` (4_000)
  - `@max_handoff_message_chars` → `@max_handoff_message_bytes`, 2_000 → 1_500
  - `@max_handoff_summary_chars` → `@max_handoff_summary_bytes`, 2_000 → 1_000
  - `@max_handoff_reason_bytes 800` (new)
- Apply `truncate(reason, @max_handoff_reason_bytes)` alongside the existing message/summary truncation in `build_preamble/3` (`:141`).
- **Order matters**: clamp reason/message/summary first → build `base` from the clamped values → compute `history_budget = max(@max_preamble_bytes - byte_size(base) - byte_size(closing), 0)` → format history to *exactly* that budget → concatenate `base <> history_block <> closing`. Never truncate the final preamble as a whole — that risks cutting off `"END HANDOFF CONTEXT]"` and producing an unparseable marker for the LLM.
- Defense-in-depth final guard, narrowed and **including closing in the size check**: if `byte_size(base) + byte_size(history_block) + byte_size(closing) > @max_preamble_bytes`, clamp the **history block only** (so the closing marker is always preserved). Equivalent formulation: compare `byte_size(history_block)` against `@max_preamble_bytes - byte_size(base) - byte_size(closing)`. The per-field caps make this branch unreachable under normal data, but the guard keeps the invariant if base scaffolding ever grows.

Worst case after these changes: 800 + 1_000 + 1_500 + ~300 scaffolding ≈ 3_600 bytes for `base`; ~25 bytes for `closing`; history budget ≥ ~375 bytes (clamped). `base + history + closing ≤ 4_000`. Closing always intact.

**Edit** `test/jido_claw/agent/handoff/router_test.exs`

- Replace the magic `<= 5_500` at `:335` with the named constant the production code exports. Have the router module expose the cap (`def max_preamble_bytes, do: @max_preamble_bytes`) and assert `byte_size(preamble) <= HandoffRouter.max_preamble_bytes()`. No bare `4_300` / `5_500` literals.
- The existing huge-message-and-summary test stays; update its assertion to use the named accessor.
- Add a "huge reason" test: build a handoff with `reason: String.duplicate("x", 50_000)`, modest message/summary; assert `byte_size(preamble) <= HandoffRouter.max_preamble_bytes()` and the preamble contains `"truncated"`.
- Add an "all three huge" test: message, summary, reason all 50_000 bytes; assert the same bound.
- All bound tests: also `assert String.ends_with?(preamble, "END HANDOFF CONTEXT]\n\n")` so any future truncation regression that eats the closing marker is caught.

### Slice 3 — Dispatcher-level integration test

**Edit** `lib/jido_claw.ex`

- Add a tiny dispatch seam mirroring the Router's `jido_whereis/1` / `jido_start_agent/2` pattern (`router.ex:378-388`):
  ```elixir
  defp ask_runtime, do: Application.get_env(:jido_claw, :ask_runtime, JidoClaw.Agent)
  ```
- Replace `JidoClaw.Agent.ask_sync(routed_pid, ...)` at `:224` with `ask_runtime().ask_sync(routed_pid, ...)`. One line of production change; default behavior identical.
- The REPL dispatch at `cli/repl.ex:384` is intentionally left unchanged — `run_chat_turn/8` and the REPL share the same shape (preamble concatenation, routed pid, tool_context threading), and covering one end-to-end is the gate the review asked for ("at least one dispatcher-level test"). REPL coverage can be added incrementally if needed.

**New** `test/support/handoff_dispatch_capture.ex`

A test-only module exposing `ask_sync/3` that captures `(pid, message, opts)` and sends them to `Application.get_env(:jido_claw, :dispatch_capture_target, self())`. Returns whatever's configured via `:dispatch_capture_response` (default `{:ok, "captured"}`) so the failure-path test can flip it to `{:error, :timeout}`. Pattern mirrors `test/support/echo_stub.ex`.

**New** `test/jido_claw/conversations/handoff_dispatcher_integration_test.exs`

`async: false` (touches global app env). `setup` (crucially aligning the workspace identity so `JidoClaw.chat/4` resolves the *same* Conversations.Session that the seeded session row uses — `chat/4` defaults `:workspace_id` to `File.cwd!()`, so we must thread an explicit path through both the seeder and the chat call):

- Create a temp project dir explicitly and seed the workspace with that path so the test owns the value end-to-end:
  ```elixir
  tmp = Path.join(System.tmp_dir!(), "dispatcher-#{System.unique_integer([:positive])}")
  File.mkdir_p!(tmp)
  on_exit(fn -> File.rm_rf!(tmp) end)

  %{tenant_id: tenant_id, session: session, workspace: workspace} =
    seed_full(tenant_label: "dispatcher", workspace: [path: tmp])
  ```
  If `seed_full/1`'s current signature doesn't accept `workspace: [path:]`, extend the helper (or build the workspace via `Workspaces.Resolver.ensure_workspace/3` directly) — the goal is "the workspace row points at `tmp`."
- Compute `runtime_session_id = session.external_id`. Start the Session.Worker + `set_session_uuid/3` for that runtime id, same as the existing integration test.
- Save the prior values of `:ask_runtime`, `:dispatch_capture_target`, `:dispatch_capture_response` so `on_exit` can restore exactly what was there before, including the "previously unset" case:
  ```elixir
  previous = %{
    ask_runtime: Application.fetch_env(:jido_claw, :ask_runtime),
    target: Application.fetch_env(:jido_claw, :dispatch_capture_target),
    response: Application.fetch_env(:jido_claw, :dispatch_capture_response)
  }

  Application.put_env(:jido_claw, :ask_runtime, JidoClaw.Test.HandoffDispatchCapture)
  Application.put_env(:jido_claw, :dispatch_capture_target, self())
  Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})

  on_exit(fn ->
    restore_env(:ask_runtime, previous.ask_runtime)
    restore_env(:dispatch_capture_target, previous.target)
    restore_env(:dispatch_capture_response, previous.response)
    HandoffRegistry.clear(tenant_id, runtime_session_id)
  end)

  # restore_env/2 helper: {:ok, v} -> put_env, :error -> delete_env
  ```
- Install a handoff for `reviewer` via `Tools.Handoff.run/2` (same `tool_context` shape as the existing integration test at `:60-70`).

Tests — call `JidoClaw.chat/4` with the explicit workspace path so it doesn't resolve a different session under `File.cwd!()`:

```elixir
JidoClaw.chat(tenant_id, runtime_session_id, "Anything to fix?",
  kind: :api,
  workspace_id: tmp,
  external_id: runtime_session_id,
  actor: actor
)
```

1. **First post-handoff turn carries the preamble and routed context.** `assert_receive {:dispatch_capture, pid, message, opts}, 5_000`. Assert *pid identity* against the routed worker AND inequality against the main agent:
   ```elixir
   assert pid == Jido.whereis(JidoClaw.Jido, "handoff:#{session.id}:reviewer")
   refute pid == Jido.whereis(JidoClaw.Jido, runtime_session_id)
   ```
   Assert `message` starts with `"[HANDOFF CONTEXT"` and includes the original handoff message body. Assert `opts[:tool_context].agent_id == "handoff:#{session.id}:reviewer"`, `opts[:tool_context].agent_template == "reviewer"`, and `opts[:request_id]` is a binary UUID.

2. **Second turn drops the preamble.** Drive a second `JidoClaw.chat/4` with the same workspace_id/external_id/actor. `assert_receive {:dispatch_capture, _, message, _}, 5_000`. `refute message =~ "HANDOFF CONTEXT"`. Same routed pid as turn 1.

3. **Failed dispatch leaves `preamble_consumed?` false.** Full reset via `JidoClaw.reset_handoff(tenant_id, runtime_session_id, session.id, actor)` (clears registry + metadata; using the registry-only `/2` form could let a stale metadata mirror re-seed the handoff during the next `chat/4` and mask a regression). Install fresh handoff. Flip `Application.put_env(:jido_claw, :dispatch_capture_response, {:error, :timeout})`. Drive `JidoClaw.chat/4`. Assert it returns `{:error, _}`. Assert `HandoffRegistry.owner(...).preamble_consumed? == false`. Flip response back to `{:ok, "captured"}`. Drive a second `chat/4`. Assert the captured message still starts with `"[HANDOFF CONTEXT"`.

`test/support` is compiled in test (per `mix.exs`), so the capture module is in scope without extra elixirc_paths config.

## Files

**Edited (4)**:
- `lib/jido_claw/tools/handoff.ex` — `base_telemetry/1`, threaded telemetry context, expanded emit metadata
- `lib/jido_claw/agent/handoff/router.ex` — `@max_handoff_reason_bytes` (plus `*_chars` → `*_bytes` rename), tightened caps, history-only clamp + named-cap accessor in `build_preamble/3`
- `lib/jido_claw.ex` — `ask_runtime/0` seam, swap `JidoClaw.Agent.ask_sync` call at `:224`
- `test/jido_claw/tools/handoff_test.exs` — Trace.for_request assertions on success + failure paths

**Edited (1, test)**:
- `test/jido_claw/agent/handoff/router_test.exs` — tighten bound, add huge-reason + all-three-huge tests

**New (2)**:
- `test/support/handoff_dispatch_capture.ex` — ask_sync capture module
- `test/jido_claw/conversations/handoff_dispatcher_integration_test.exs` — three tests above

## Verification

```bash
# Focused — fastest signal during implementation
mix test test/jido_claw/tools/handoff_test.exs
mix test test/jido_claw/agent/handoff/router_test.exs
mix test test/jido_claw/conversations/handoff_dispatcher_integration_test.exs
mix test test/jido_claw/conversations/handoff_routing_integration_test.exs

# Acceptance gate
mix precommit
```

`mix precommit` runs compile-with-warnings-as-errors, system prompt check, deps.unlock, format, credo --strict, dialyzer, and the full test suite (`mix.exs:234-242`).

### Things to watch for in `precommit`

- **Dialyzer**: `base_telemetry/1` returns a map with possibly-nil values — no new typespec needed (private), but if you typespec for clarity use `String.t() | nil` per field. The `ask_runtime/0` seam is private and untyped — matches the Router's `jido_whereis/1` pattern.
- **Credo**: keep `build_preamble/3` cyclomatic complexity flat; the history clamp should be a `case` or a small `defp clamp_history/2`, not nested `if`s.
- **System-prompt check**: untouched — no tool count change.
- **Format**: auto-fix as usual.

## Out of scope

- REPL dispatcher coverage. The single `run_chat_turn`-driven test covers the load-bearing concatenation/pid-routing/tool_context-threading shape. Adding `cli/repl.ex` end-to-end coverage is incremental — defer unless review asks again.
- Per-field finer-grained budgeting (e.g., "if message is long, give summary less room"). The flat per-field caps + global hard cap are sufficient defense and trivially auditable.
- Tuning the cap values themselves (800/1000/1500). They're defaults; if real usage proves them tight, they're constants in one place.
- **UTF-8-safe truncation**: `truncate/2` currently uses `binary_part/3`, which can split a multi-byte UTF-8 codepoint and produce an invalid string. This is pre-existing behavior — not introduced or aggravated by this plan. We're preserving it knowingly. The `*_chars → *_bytes` rename makes the byte-oriented behavior visible at the call site; a follow-up could swap to a safe helper (e.g. truncate by graphemes, then re-check byte cap) without changing any callers.
