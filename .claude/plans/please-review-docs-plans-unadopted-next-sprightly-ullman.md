# Doom-loop guard — next-ten item 2 (osa OS1-2)

## Context

The only guard on the tool loop today is jido_ai's soft nudge on *consecutive identical* signatures (`deps/jido_ai/lib/jido_ai/reasoning/react/runner.ex:204-220` — lookback depth is exactly 1 iteration, so A-B-A-B oscillation passes), with no failure-awareness and no hard stop short of the templates' `max_iterations: 25`. Unattended surfaces (cron `:agent` jobs, MCP-driven turns, composer stage agents) can burn real budget re-running a failing tool.

This ports OSA's doom-loop detector — source verified at `~/workspace/research/OSA/lib/optimal_system_agent/agent/loop/doom_loop.ex`, HEAD confirmed `f60e933b`, Apache-2.0 — detection logic + suggestion table **verbatim**, integration **rewritten** (their process-dictionary counter, system-message injection, and `@error_indicators` string-sniffing are exactly the idioms the osa exploration doc lists under "idiom mismatch our gates would reject").

**Decisions settled with the operator (2026-07-03):**
1. **Reset bound**: idle-TTL expiry — per-key state expires after ~30 min without tool calls (config).
2. **Cap scope**: per `{tenant, session, agent}` key (same key as the windows; OSA's "session" = one agent loop, so this is semantically equivalent). **Per node** — the Store is in-memory; in cluster mode user cron `:agent` jobs fire on every node (`lib/jido_claw/platform/cron/worker.ex:189`), so worst-case budget scales with node count. Labeled honestly everywhere (moduledoc, AGENTS.md, config comment); a durable/cluster-wide store is out of scope.
3. **Halt decay**: sticky halt with a dedicated short `halt_ttl` (default 5 min) — a halted key blocks all calls pre-execution (cheap), blocked attempts don't refresh the timer, and on expiry the whole key resets fresh.
4. **Signature clearing is per-tool**, not global (review finding): a clean success of tool T clears only T's accumulated signatures. Global clearing (OSA's *documented* behavior) would mask the archetypal repair loop — `edit_file` fail → `read_file` ok → same `edit_file` fail — which never accumulates 3 under clear-all. Recorded as a deliberate deviation at reconciliation (OSA's *code* never cleared at all; its moduledoc claimed clear-all; we ship per-tool).

## Design

Three mechanisms, thresholds verbatim from OSA:

| # | Mechanism | Trigger | Response |
|---|---|---|---|
| 1 | Identical-call | trailing consecutive run of identical `{tool, args_digest}` ≥ **4** within last **8** recorded calls; success-agnostic | **Immediate halt**, evaluated **pre-execution** (the 4th call never runs — improvement over OSA's post-batch check) |
| 2 | Failure signatures | any single signature ≥ **3** in last **20**; signatures recorded for error results only; a clean success of tool T clears **T's** signatures | **Staged**: nudge #1, #2 (append recovery directive to the error message, clear signatures, `recovery_count+1`), 3rd trigger → halt |
| 3 | Absolute cap | **100** executed calls per key (per node) | Block the 101st pre-execution; crossing **80%** → one-time `Logger.warning` + Trace `:warn` (never injected into results — OSA parity) |

- **Key**: `{tenant_id, session_uuid || session_id, identity}` where `identity = JidoClaw.Reasoning.Compactor.Identity.resolve(agent_template, agent_id, session_id)` (`lib/jido_claw/reasoning/compactor/identity.ex:44-50`). `agent_id` resolution: `context[:agent_id] || get_in(context, [:tool_context, :agent_id])`, each `is_binary`-coerced — top-level for the live ReAct path (nested is deliberately nil there, `tool_context.ex:141-150`), nested fallback for direct calls / MCP default scope (`mcp_scope/initializer.ex:74`) / tests. Missing tenant OR session → pass through unguarded (OutputShaper's no-tenant posture).
- **args_digest**: full 32-byte `:crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))` — the `tool_approvals.ex:111` canonical-hash idiom — kept whole in the window entry (a truncated prefix would only be a collision-resistant approximation). Replaces OSA's `:erlang.phash2`, whose 2^27 range makes a collision-induced hard-halt possible. Params are post-schema-validation at `run/2`, so shapes are stable across repeats; a semantic-equality miss only under-detects (safe direction).
- **Error classification is typed**, replacing OSA's `@error_indicators` string sniff: after `Error.normalize_result`, error? ⇔ `{:error, _}` / `{:error, _, effects}` OR `{:ok, %{exit_code: n}}` with integer `n != 0` (run_command shape; `error.ex:81-88` already converts `{:ok, %{status: :failed|:error}}` → `{:error, _}`).
- **Signatures are stored structurally** as `{tool, sig_text}` tuples in the window (per-tool clearing and counting without string parsing; the rendered `"tool:text"` form appears only in messages/traces). `sig_text` = first 100 chars of the error message, whitespace-collapsed (OSA recipe); for nonzero-exit ok-results use output head, falling back to `"exit status <n> (args:<hex digest prefix>)"` when output is blank — the digest prefix rendered printable via `Base.encode16` (prevents different silent commands colliding into one signature).
- **Nudge delivery is shape-aware**: the recovery directive is appended to the field the LLM actually reads — `{:error, %{message: _}}` → appended to `message`; `{:ok, %{exit_code: n, output: _}}` with `n != 0` (the real run_command return is an OK map, not an error tuple — `run_command.ex:26`) → appended to `output`. 3-tuple arities and effects preserved in both cases.
- **Halt envelope** (non-retryable at BOTH retry layers — ForgeBridge precedent `lib/jido_claw/tools/run_command/forge_bridge.ex:38-62`):
  `{:error, %{code: :doom_loop, message: <ported text + "Do not retry; stop calling tools and summarize the current state.">, details: %{retry: false, trigger: :identical_repeat | :call_cap | :failure_signature, ...scalars}}}`
  `retry: false` is required (jido_action defaults unknown-code maps to RETRYABLE, `deps/jido_action/lib/jido_action/error.ex:464,480,607`); `:doom_loop` is outside jido_ai's whitelist (`deps/jido_ai/lib/jido_ai/error.ex:467`); the retry loop that makes this load-bearing is `runner.ex:909`. The details key is **`:trigger`, never `:reason`** (the retry-hint digger digs `:reason`). 3-tuple inputs preserve effects: `{:error, env, effects}`.
- **Skip list**: `observe_result` ignores results with code ∈ `[:approval_pending, :approval_denied, :approval_unavailable, :doom_loop]` — the tool didn't execute, so it must not count in windows (an LLM retrying into a pending approval must not doom-halt the approval flow).
- **Sticky-halt bookkeeping**: `KeyState` carries `halted: nil | reason` + `halted_at`; sweep evicts halted keys after `halt_ttl_ms` (from `halted_at`) and unhalted keys after `idle_ttl_ms` (from `last_activity`). Blocked attempts mutate nothing.
- **Fail-open**: the facade wraps Store calls in `try/rescue` + `catch :exit` → pass-through + best-effort Trace (`# reach:disable-next-line bare_rescue`). The Store itself never rescues. A budget guard must never break a tool call.

## Feed boundary + documented residuals (review finding P1)

The guard feeds at the `Tools.Action` boundary — the point the item itself specifies. `Jido.Exec`/`Jido.AI.Turn` wrap AROUND action `run/2`, so failures materializing outside it bypass observation:

1. **Param-validation failures** (`deps/jido_action/lib/jido_action/exec.ex:171-183`, before `run/2`): the call never reaches the pipeline at all — neither windows nor the cap see it. An LLM hammering identical *invalid* args is invisible to the guard.
2. **Exec/Turn timeouts** (`exec.ex:493+` task kill; `deps/jido_ai/lib/jido_ai/turn.ex:624-626`): the attempt dies mid-`run/2`; no observation. (run_command manages its own timeouts internally and returns normally — the main hang risk is already in-band.)
3. **Raised exceptions / caught throws**: raises inside `action.run/2` are caught by `Jido.Exec` as execution errors (`exec.ex:864`) — which Exec's own retry loop may re-attempt before normalization — and only exceptions escaping Exec hit Turn's catch (`turn.ex:600-618`). Either way the guard sees nothing: the pipe tail after the raise point never runs. (No claim that these are non-retryable — some are retried at the Exec layer.)
4. **Output-schema validation failures after `{:ok, _}`** (`exec.ex:833`; many of our tools declare `output_schema`): the guard records a clean success while the LLM sees an error — the one *false-signal* direction. **Neutralized cross-tool by per-tool clearing** (decision 4); same-tool identical-args repeats are still caught by the pre-execution identical-call check (those calls DO reach `run/2`). Residual: varied-args output-validation loops only — a shipped code bug, findings-grade rare.

Classes 1–3 are under-detection; class 4 is an accepted **false-success** residual (the guard may record `{:ok, _}` and clear that tool's signatures while the LLM receives the output-validation error), bounded by per-tool clearing and the identical-call precheck. Documented in the LoopGuard moduledoc + the AGENTS.md bullet (the S-M3/S-L2/O-L1 documented-residual house pattern), pinned by tests (below), and recorded at reconciliation: the item's claim that the pipeline "already sees every call + normalized error" holds only for calls that reach the action.

## Files

**New**
- `lib/jido_claw/agent/loop_guard.ex` — facade + pure core + `KeyState` (nested `defstruct` — dodges reach `fixed_shape_map`). Attribution comment at the lift sites: `# Ported from Miosa-osa/OSA @ f60e933b, Apache-2.0`.
- `lib/jido_claw/agent/loop_guard/store.ex` — singleton GenServer (AgentTracker shape: `init` → `handle_continue(:setup)` → `Process.send_after` sweep loop), state `%{key => %KeyState{}}`, synchronous `reset/0` (GenServer.call — tests depend on it), **one** `opt_or_config/2`-style config reader (`lib/jido_claw/security/tool_approval.ex:540-550` idiom — not N per-key readers, which would trip exslop).

**Modified**
- `lib/jido_claw/tools/action.ex` — the two pipeline insertions (below) + update the load-bearing ordering comment.
- `lib/jido_claw/application.ex` — supervise the Store in core children (near `JidoClaw.AgentTracker`, ~line 323).
- `lib/jido_claw/core/telemetry.ex` — `emit_loop_guard` helper next to `emit_shaping/3` (:186-193) + `counter("jido_claw.loop_guard.total", tags: [:event, :trigger])` in the metrics list (:43-47).
- `config/config.exs` (after the `:output_shaping` block, :296-306) and `config/test.exs` (`enabled?: false`, alongside :40/:55).
- `mix.exs` — `{:stream_data, "~> 1.3", only: [:dev, :test]}` (already in mix.lock transitively via ash; first property tests in the repo).

**Tests** (new)
- `test/jido_claw/agent/loop_guard_test.exs` — pure core, `async: true`, explicit opts.
- `test/jido_claw/agent/loop_guard/store_test.exs` — `async: false`, `reset()` in setup.
- `test/jido_claw/tools/loop_guard_integration_test.exs` — full-pipeline + retry-contract + residual-pinning.

**Docs**
- `AGENTS.md` — "Loop Guard" bullet under Key Patterns (after the Tool Approval Gate bullet): mechanisms, feed boundary, the four residual classes, per-node cap.
- `docs/exploration/osa/FEATURES-WORTH-BORROWING.md` — OS1-2 `> **Done <date>** (next-ten #2) — …` blockquote with corrections.
- `docs/plans/unadopted-next-ten/README.md` — mirrored blockquote under item 2 + table-row `— ✅ DONE <date>` (item-1 precedent).

## Pipeline wiring (`action.ex` generated `run/2`)

```elixir
|> ToolApproval.gate(params, enriched_context)
|> case do
  :ok ->
    case LoopGuard.check(@jidoclaw_tool_name, params, enriched_context) do
      :ok -> super(params, enriched_context)
      {:halt, halt_error} -> halt_error          # tool never executes
    end
  {:error, _approval} = gate_error -> gate_error
end
|> Error.normalize_result()
|> LoopGuard.observe_result(@jidoclaw_tool_name, params, enriched_context)  # skip-list guards non-executions
|> OutputRedaction.redact_result()
|> ...
```

Approval gate stays first (an approval-blocked call is not an execution). `check/3` is **total for the pipeline**: it returns only `:ok | {:halt, {:error, map()}}` — the internal `:warn` is consumed inside the facade (Logger + Trace, then `:ok`). `observe_result` sits after normalize (reads the canonical `%{code, message, details}`; `normalize_result` is idempotent for that shape, `error.ex:119-122`) and before redaction (the appended directive is our own text; the underlying message still gets redacted after).

## Public API

```elixir
# Facade (impure boundary; fail-open)
LoopGuard.check(tool, params, context, opts \\ []) :: :ok | {:halt, {:error, map()}}
LoopGuard.observe_result(result, tool, params, context, opts \\ []) :: term()

# Pure core (the property-test surface; explicit opts, no app env)
LoopGuard.check_attempt(%KeyState{}, {tool, args_digest}, opts)
  :: {:ok | :warn | {:halt, halt_reason}, %KeyState{}}
LoopGuard.check_result(%KeyState{}, {tool, error?, error_text}, opts)
  :: {:ok | {:nudge, directive} | {:halt, halt_reason}, %KeyState{}}
LoopGuard.halt_message(halt_reason, %KeyState{}) :: String.t()
LoopGuard.halt_details(halt_reason, %KeyState{}) :: map()   # always %{retry: false, trigger: reason, ...}

# Store (singleton GenServer; applies pure fns atomically inside handle_call)
Store.check_attempt(key, {tool, args_digest}, opts) :: :ok | :warn | {:halt, message, details}
Store.check_result(key, {tool, error?, error_text}, opts) :: :ok | {:nudge, directive} | {:halt, message, details}
Store.reset() :: :ok    # synchronous
```

`KeyState`: `call_keys: [], failure_sigs: [], total_calls: 0, recovery_count: 0, halted: nil, halted_at: nil, warned: false, last_activity: nil`. Store name overridable via `opts[:server]` so fail-open is testable. `GenServer.call` (not cast) for backpressure — two calls per tool call is trivial at LLM pace. `halt_reason :: :identical_repeat | :call_cap | :failure_signature`.

## Message texts (verbatim vs adapted)

All from OSA `doom_loop.ex` with tool-name remap (`file_read`→`read_file`, `shell_execute`→`run_command`, `dir_list`→`list_directory`, `file_glob`→`search_code`); strings built with interpolation/iodata (never `kept ++ [note]` + join).

| Text | OSA lines | Treatment |
|---|---|---|
| Identical-call halt ("Stopped: tool `X` was called with identical arguments N times in a row…") | 130-133 | verbatim + remap + do-not-retry line |
| Cap halt ("I've reached the session tool call limit…") | 219-227 | verbatim, config wording → `:loop_guard`, + do-not-retry line |
| Signature halt ("I hit the same error N times with X: ERR\n\nSUGGESTION") | 273-279 | verbatim + do-not-retry line |
| Recovery directive ("[DOOM LOOP RECOVERY: …COMPLETELY DIFFERENT arguments…]") | 321-326 | verbatim + remap; **delivery adapted** — appended to the failing tool-result message (the item's "tool-result payload"), not a system message |
| `build_suggestion/1` table (8 branches) | 341-374 | verbatim + remap; our `edit_file` phrases already match ("old_string not found in…" / "old_string found N times in…", `edit_file.ex:77,88`) |

## Config

```elixir
# config/config.exs — kill-switch comment block mirroring :output_shaping's;
# note the cap is per {tenant, session, agent} PER NODE (in-memory store)
config :jido_claw, :loop_guard,
  enabled?: true,
  repeat_threshold: 4, repeat_window: 8,
  failure_threshold: 3, failure_window: 20,
  max_calls: 100, warn_pct: 0.80,
  max_recoveries: 2,
  halt_ttl_ms: 300_000,        # 5 min — sticky-halt decay, then full key reset
  idle_ttl_ms: 1_800_000,      # 30 min — idle-window expiry
  sweep_interval_ms: 60_000

# config/test.exs
config :jido_claw, :loop_guard, enabled?: false
```

## Observability

- **Trace**: `JidoClaw.Trace.emit(:guardrail, %{guardrail: "loop_guard", event: :warn | :nudge | :halt, name: tool, trigger: …, tenant_id: …, session_uuid: …, agent_id: …}, %{system_time: System.system_time()})` — arg order `(category, metadata, measurements)` (`trace.ex:110-122`). The `[:jido_claw, :guardrail, :event]` channel is already registered in `trace/collector.ex:102` with **zero producers** — LoopGuard is the first; no collector change needed.
- **Telemetry**: `emit_loop_guard` + counter as above (the OutputShaper dual pattern: telemetry for metrics, Trace for the timeline).

## Implementation order

1. `mix.exs` stream_data + `mix deps.get` (lock unchanged).
2. Pure core + `KeyState` in `loop_guard.ex`; write `loop_guard_test.exs` red → green.
3. `Store` + supervision in `application.ex`; `store_test.exs`.
4. Facade `check/4` + `observe_result/5` (key resolution incl. nested agent_id fallback, typed classification, digest, envelope build, fail-open, Trace/telemetry emission).
5. Pipeline wiring in `action.ex`.
6. Config blocks; telemetry helper + metric.
7. Integration + retry-contract + residual-pinning tests.
8. **Build-time verifications** (facts asserted by exploration, re-checked live): MCP serve-mode `tool_context` session presence (if session-less, the pass-through applies — fold into the residuals doc); composer stage agents / cron `:agent` runs carry tenant+session (expected yes → covered + isolated per key); `{:error, _, effects}` arities through observe.
9. Docs: AGENTS.md bullet; reconciliation blockquotes (corrections below).
10. `mix precommit` to zero findings.

## Tests

**Pure/property** (`loop_guard_test.exs`, StreamData — the item's named properties):
- (a) **reset-on-success, per-tool**: k<3 T-failures + clean T-success + k'<3 T-failures never triggers.
- (a2) **cross-tool isolation**: a T2 success never clears T1 signatures — 3 identical T1 failures interleaved with T2 successes DOES trigger (the edit-fail→read-ok→edit-fail loop).
- (b) **consecutive vs windowed**: A-B-A-B with ≥4 A's in the window never trips identical-call; 4 truly consecutive always does.
- (c) failure signatures fire on **non-adjacent** 3-in-20.
- (d) cap: `max_calls` `:ok`s, `:warn` exactly once at `trunc(max * warn_pct)`, call `max_calls+1` → `{:halt, :call_cap}`.
- (e) nudge clears signatures — 3 fresh needed for the next trigger.
- (f) after `max_recoveries` nudges, the next trigger → `{:halt, :failure_signature}`.
- (g) halted state sticky: any subsequent attempt → `{:halt, _}`, no timer refresh.
- Units: signature build (collapse/100-cap/exit-fallback+digest), all 8 suggestion branches, typed classification (`{:ok, %{exit_code: 1}}` vs `0` vs `{:error, _}` vs 3-tuple incl. effects preserved), `halt_details` always carries `retry: false` + `:trigger` (never `:reason`).

**Store** (`store_test.exs`): key isolation; sweep evicts idle keys after `idle_ttl_ms` and halted keys after `halt_ttl_ms` (tiny configured TTLs); post-expiry key starts fresh; fail-open (`server: :nonexistent` → pass-through); `reset/0` synchronous.

**Integration** (`loop_guard_integration_test.exs`, `TenantCase, async: false`, inline `use JidoClaw.Tools.Action` echo tools per `output_shaper_test.exs` pattern, `put_env` + `on_exit` restore):
- repeated failing calls → directive appended after threshold, `{:error, %{code: :doom_loop, details: %{retry: false}}}` after budget — asserted on the **final piped result** (survives normalize→observe→redact→shape→cap);
- 4 identical calls: echo `send`s to test pid — assert exactly 3 `:ran` messages (4th blocked pre-execution);
- approval-gate errors don't count toward windows;
- **retry contract (review finding P2)**: (i) a fake tool returning the exact doom envelope (built via `halt_message/2` + `halt_details/2`) driven through `Jido.Exec.run(Tool, params, ctx, max_retries: 2)` → body runs exactly once; contrast: same body returning `%{code: :some_error, message: "x", details: %{}}` → body runs more than once (proves the live retry loop would catch a regression); (ii) `refute Jido.AI.Error.retryable?({:error, envelope})` on the raw envelope (the `runner.ex:909` predicate); (iii) the same fake driven through `Jido.AI.Turn.execute_module/4` — the live path where `Jido.Exec` wraps the error map before Turn normalizes it — asserting `refute Jido.AI.Error.retryable?(result)` on the returned `{:error, envelope, []}`;
- **nonzero-exit OK-shape loop**: a run_command-shaped fake returning `{:ok, %{exit_code: 2, output: "…"}}` repeatedly → signatures accumulate and the directive is appended to `output`, not `message`;
- **residual pinning (review finding P1)**: invalid params driven through `Jido.Exec.run` against a guarded tool → windows untouched (class-1 residual behaves as documented); an `output_schema` tool returning a bad shape → recorded as that tool's success only, other tools' signatures unaffected (class-4 neutralization).
- `assert match?(pattern, x), "msg"` form throughout.

## Verification

1. Targeted: `mix test test/jido_claw/agent/loop_guard_test.exs test/jido_claw/agent/loop_guard/store_test.exs test/jido_claw/tools/loop_guard_integration_test.exs`
2. **Gate: `mix precommit`** — run bare (no pipes), report exact exit code + test counts. Zero credo/reach/exslop findings. Done = this passes.
3. Optional live canary (dev): `mix jidoclaw run "..."` (item-1 headless entry) against a prompt that forces repeated failing edits — observe the directive, then the `doom_loop` envelope, and `:guardrail` Trace events.

Nothing is committed — all changes stay unstaged.

## Corrections to record at reconciliation (osa doc OS1-2 + queue README item 2)

1. OSA stages **only** the failure-signature mechanism; identical-call and cap hard-halt immediately (the entry's "On trigger it does not hard-halt" overgeneralized).
2. OSA's "reset on any clean success" is moduledoc-only — its code never clears accumulated signatures (only skips appending the clean iteration's); we shipped **per-tool** clearing, deviating from both (the clear-all spec masks interleaved repair loops; never-clear over-triggers).
3. The `:ok | {:nudge, directive} | {:halt, reason}` contract is our redesign — OSA returns `{:ok, state} | {:halt, message, state}` with the nudge folded into `:ok` via message injection.
4. `@error_indicators` string sniffing replaced by typed classification (with the run_command nonzero-exit special case); `phash2` replaced by a SHA-256 digest.
5. Pre-execution blocking (4th identical call and 101st call never execute) improves on OSA's post-batch detection.
6. The item's "feed from the pipeline **which already sees every call + normalized error**" holds only for calls that reach the action — param-validation/timeout/exception/output-validation failures happen outside `run/2` and are documented residuals.
7. No upstream tests existed; the property tests are net-new (and the repo's first).

## House-gotcha checklist (from project memory)

`KeyState` as defstruct (reach `fixed_shape_map`) · no trivial-forwarder defp around `Identity.resolve` · `bare_rescue` disable comments on fail-open · single config reader (exslop clone seams) · present-nil `is_binary` coercion on every tool_context read · `retry: false` + non-whitelisted code + phrase message, proven at both retry layers by test · iodata/interpolation string building · reach scans test/support (integration fixtures) · full `mix precommit`, never piped.
