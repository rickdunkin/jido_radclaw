# Inspection / AgentView Code-Review Remediation

## Context

The `recursive-squishing-cake.md` plan (T2-2 AgentView + T2-4 Inspection) landed: two
top-level modules (`JidoClaw.AgentView`, `JidoClaw.Inspection`), an `Inspection.Summary`
struct, two MCP tools (`agent_status`, `inspect_agent`), a rewired `agents_live.ex`, and
top-level delegates. A code review then found **5 code issues + 2 housekeeping items**.

This plan validates and fixes them. I read every cited line; **all five code findings are
real**, and the `inspect_request` correlation finding is worse than reported — see Fix 4.

**Done = `mix precommit` is green** (compile `--warnings-as-errors`, `system_prompt.check`,
`deps.unlock --unused`, `format`, `credo --strict`, `dialyzer --format short`, `test`).
`system_prompt.check` only tracks `JidoClaw.Agent.tool_modules()` (the main agent's tools),
not MCP tools — none of these fixes change that set, so it is unaffected.

## Validation Summary

| # | Sev | Finding | Verified root cause |
|---|-----|---------|---------------------|
| 1 | P1 | `kind: "workflow"` exposed via MCP, but workflow runs aren't tenant-scoped | `inspect_agent.ex:43,89` → `Inspection.inspect_workflow/1` → global `WorkflowRun.by_id/1` (`inspection.ex:180`). `project/1` drops the `:workflows` list, but `duration_ms`/`error`/existence-oracle still leak cross-tenant. Contradicts the module's own moduledoc + plan intent. |
| 2 | P2 | Compaction not JSON-normalized in MCP output | `inspect_agent.ex:118` passes `s.compaction` raw; `compaction_for/3` (`inspection.ex:621`) does `Map.from_struct(snap)`, leaving atom keys + atom values (`status: :summarized`, `strategy: :summary`) and an arbitrary nested `:metadata`. `project/1`'s `stringify/1` is applied to `handoffs`/`error` but **not** `compaction`. JSON-safe test seeds no compaction → misses it. |
| 3 | P2 | PID + non-handoff agent-id underimplemented | `pid_summary/1` (`inspection.ex:297`) only extracts `request_id` — no `tool_names`/`system_prompt`/trace fields. `agent_tools_for/2` (`inspection.ex:383`) is a literal `[]` stub. |
| 4 | P2 | `inspect_request` wrong-tenant correlation treated as "missing" | `correlation_session_uuid/2` (`inspection.ex:132`) expects `{:ok, %{...}}`, but `safe/1` already unwraps `{:ok, _}` → **the clause never matches, so `session_uuid` is _always_ nil today** (latent bug). Wrong-tenant must return `{:error, :not_found}` per plan; today returns `{:ok, summary}` with nil session fields. |
| 5 | P3 | Usage aggregation only reads atom keys | `usage_from_trace/1` (`inspection.ex:522`) uses `Map.get(m, :input_tokens, 0)`. Confirmed: `durable_event_to_struct/1` (`trace.ex:343`) re-atomizes `category`/`status` but leaves `measurements`/`metadata` **string-keyed** after a Postgres round-trip → rehydrated traces report `0`. `error_message/2` (`inspection.ex:574`) has the same latent bug on `metadata`. |

Reusable assets confirmed during validation:
- `JidoClaw.Core.MapKeys.coalesce_field/3` — atom-OR-string indifferent read (precedent:
  `run_pipeline.ex:577`, `reasoning/telemetry.ex:330`).
- `JidoClaw.Agent.Templates.get/1` — `template` string → `%{module: ...}` (`agent/templates.ex:61`).
- `JidoClaw.AgentView` private `jsonify/1` (`agent_view.ex:607`) — the generic recursive
  normalizer to extract (handles atoms→strings, DateTime/NaiveDateTime/Date→ISO-8601,
  MapSet→list, structs, drops modules/PIDs/refs).

---

## Fix 1 — [P1] Remove workflow dispatch from the MCP `inspect_agent` tool

**File:** `lib/jido_claw/tools/inspect_agent.ex`

- Drop `"workflow"` from the `kind` enum (`:43`): `{:in, ~w(auto module agent_id session request)}`.
- Delete the `defp dispatch("workflow", target, _tenant_id)` clause (`:89-91`).
- Scrub "workflow id"/"workflow" from the moduledoc (`:1-12`), `description` (`:16-18`), the
  `target` doc (`:40`), and the `kind` doc (`:46-47`).

**Keep** `JidoClaw.Inspection.inspect_workflow/1` and the `JidoClaw.inspect_workflow/1`
delegate — trusted local Elixir callers only. This matches the plan's stated v1 scope ("the
MCP projection drops `:subagents` AND `:workflows`") and the project threat model (weight
toward leakage hygiene). Tenant-scoping `WorkflowRun` is a separate, larger change and is
**deliberately out of scope** here.

**Tests:** no existing MCP test uses `kind: "workflow"`. Calling `InspectAgent.run/2` directly
**bypasses the Jido schema-validation pipeline**, so don't dress a dispatch test up as a
"schema validation" test. Do one of:
- assert `InspectAgent.run(%{target: "x", kind: "workflow"}, ctx)` returns the normalized
  `{:error, %{code: :unknown_kind}}` (honest: exercises the removed-clause → catch-all
  `dispatch(_, _, _)` fallthrough, normalized by `Tools.Action`), and/or
- assert `InspectAgent.validate_params(%{target: "x", kind: "workflow"})` returns `{:error, _}`
  to genuinely cover the enum rejection at the schema layer.

## Fix 2 — [P2] Shared JSON-safe normalizer for the MCP projection

**New file:** `lib/jido_claw/core/json_safe.ex` — `JidoClaw.Core.JsonSafe` with public
`@spec encode(term()) :: term()` (+ `@moduledoc`/`@doc`). Move the `jsonify/1` clause set
**verbatim** from `agent_view.ex:607-647` (including private `jsonify_key/1` and `module?/1`).

**Rewire `lib/jido_claw/agent_view.ex`:** change `to_mcp_map/1`'s final `|> jsonify()` to
`|> JsonSafe.encode()`; delete the now-moved `jsonify/1`, `jsonify_key/1`, `module?/1`. Add
`alias JidoClaw.Core.JsonSafe`. Behavior is identical — `agent_view_test.exs` (no-leaf-atoms /
no-DateTime / no-module assertions) stays green.

**Rewire `lib/jido_claw/tools/inspect_agent.ex` `project/1`:** adopt one obvious rule —
**top-level keys stay atoms; every nested term goes through `JsonSafe.encode/1`.** Apply it to
`compaction`, `handoffs`, `error`, **and `usage`** (the latter is currently explicit and safe,
but encoding it keeps the projection rule uniform and future-proof against new nested values).
Delete the partial `stringify/1`/`stringify_value/1`. Keep `input_kind: Atom.to_string(...)`.
Top-level atom keys are required by `output_schema` and the tool tests (`output.input_kind`,
`output.tool_names`); no test reads nested `usage` keys, so string-keying the inner map is safe.

**Tests:** in `inspect_agent_test.exs`, seed a compaction snapshot via
`ConversationsSession.set_compaction_snapshot/2` (as `agent_view_test.exs:354` does), inspect
that session, and assert `output.compaction` has no leaf atoms/DateTimes — reuse a recursive
walker like `agent_view_test.exs`'s `leaf_violates?/1`. **Pin the intentional string-keyed shape
explicitly** so it isn't silently reverted later: assert nested maps are accessed as
`output.usage["input_tokens"]` / `output.compaction["status"] == "summarized"` (string keys,
**not** `output.usage.input_tokens`). Top-level access stays atom-keyed (`output.input_kind`).

## Fix 3 — [P2] PID + non-handoff agent-id running state

**File:** `lib/jido_claw/inspection.ex`

- **agent-id stub (`agent_tools_for/2`, `:383`):** derive the module from the tracker entry's
  `:template` via `Templates.get/1` (`AgentEntry` has no `:module` field — only `:template`),
  falling back to `JidoClaw.Agent` when there is no tracker entry / unknown template / `"main"`
  (`Templates` has no `"main"` key). Then `tool_names_for_module(module)` (existing helper,
  `:477`). This makes `inspect_agent("main")` return the main tool set.
- **pid path (`:59-62`, `pid_summary/1` `:297`):** accept `opts`; from
  `Jido.AgentServer.state(pid)` (wrapped — generalize the existing `safe_agent_request_id/1`)
  derive `agent_id := state.agent.id`, `module := state.agent_module`,
  `request_id := state.agent.state[:last_request_id]` (access paths per `trace.ex:251-267`).
  Populate `tool_names` (from module), `system_prompt`, `mcp_tools`, `skills`, and trace fields
  via `fetch_trace(agent_id, opts[:tenant_id])`. Keep `input_kind: :pid`. A dead/non-agent pid
  → nil module → `tool_names: []`, no crash.

**Tests:**
- agent-id fallback: extend "untracked id returns :ok…" to also assert `"read_file" in
  s.tool_names` (the `JidoClaw.Agent` fallback).
- agent-id template→module (cheap, no LLM): `AgentTracker.register("child", self(), "reviewer")`
  (`register/5`, `agent_tracker.ex:58`), then `inspect_agent("child")` and assert
  `s.tool_names` equals `JidoClaw.Agent.Workers.Reviewer`'s declared tools — compute `expected`
  from the module in-test (`Reviewer.strategy_opts() |> Keyword.fetch!(:tools) |> Enum.map(&to_string(&1.name()))`)
  so it isn't brittle, and assert the sets match. **AgentTracker has no deregister API** — clean
  up in `on_exit` with `AgentTracker.reset(); AgentTracker.get_state()`: `reset/0` is a cast
  (`agent_tracker.ex:104,255`) and the trailing `get_state/0` call is the sync barrier. (Tracker
  is process-global; this stops the "child" entry leaking into other `async: false` tests' `subagents`.)
- pid: assert `inspect_agent(self())` returns `{:ok, %Summary{input_kind: :pid}}` without
  raising (safe-fallback path; `self()` is not a `Jido.AgentServer`, so module→nil→`tool_names: []`).
  **Note:** a live-agent happy-path pid test is deferred — the session worker's `agent_pid` is
  `nil` at idle (`worker.ex:69,229`) and standing up a real `Jido.AgentServer` needs a turn/LLM
  provider unavailable in the test sandbox. (`Jido.AgentServer.State` does carry `agent_module`,
  so the production code path is valid.)

## Fix 4 — [P2] `inspect_request` wrong-tenant correlation → `:not_found`

**File:** `lib/jido_claw/inspection.ex`

Replace the broken `correlation_session_uuid/2` (dead `{:ok, …}` pattern → always nil) with a
direct, unwrapped resolver that distinguishes the three plan cases. In `do_inspect_request`,
after `Trace.for_request` succeeds, branch on a new `resolve_correlation(request_id, tenant_id)`:

```elixir
# RequestCorrelation.lookup/1 returns {:ok, row | nil} | {:error, _} (NOT pre-unwrapped here)
defp resolve_correlation(request_id, tenant_id) do
  case lookup_correlation(request_id) do
    %{session_id: uuid, tenant_id: ^tenant_id} -> {:ok, uuid}     # match  → session fields
    %{tenant_id: _other}                        -> {:error, :not_found}  # wrong → unresolvable
    nil                                         -> {:ok, nil}     # missing → ok, nil fields
  end
end
# lookup_correlation/1: call RequestCorrelation.lookup(request_id) with its own
# try/rescue/catch (NOT safe/1, which collapses the distinction); {:ok, row}->row, _->nil.
```

Thread the resolved `session_uuid` into `build_request_summary/5` (drop its internal lookup).
On `{:error, :not_found}`, `do_inspect_request` returns `{:error, :not_found}`. This also
**fixes the latent always-nil bug** so `context_preview`/`compaction` populate on the happy path.

**Tests:** add
- (a) found-but-wrong-tenant correlation → `{:error, :not_found}`. **Construct carefully:**
  register the `RequestCorrelation` row under `other_tenant`, but **emit the trace telemetry
  under the requested `tid`** (same `request_id`), so `Trace.for_request(_, _, tenant_id: tid)`
  **succeeds** and only the correlation tenant cross-check fails — otherwise the test would pass
  for the wrong reason (Trace not found).
- (b) missing correlation → `{:ok, summary}` with `context_preview`/`compaction` nil but
  usage/duration populated.

The existing happy-path test (`inspection_test.exs:174`) still passes (and now actually
resolves `session_uuid`).

## Fix 5 — [P3] Usage + error read atom OR string keys

**File:** `lib/jido_claw/inspection.ex` — add `alias JidoClaw.Core.MapKeys`.

- `usage_from_trace/1` (`:522`): `MapKeys.coalesce_field(m, :input_tokens) || 0` and the
  `:output_tokens` counterpart.
- `error_message/2` (`:574`): `MapKeys.coalesce_field(meta, :error)` / `:message` (same
  string-keyed-`metadata` root cause, found during validation — included so the class is fixed,
  not deflected).

**Test:** durable-rehydration regression. Seed a trace directly via
`JidoClaw.Trace.Resources.TraceRun.upsert_run/1` + `TraceEvent.append_event/1` (mirror the attr
shapes in `trace/persistence.ex`) for a `request_id` **never** emitted through the in-memory
collector, with a `:model` event whose `measurements` use **string** keys
(`%{"input_tokens" => 10, "output_tokens" => 20}`). `inspect_request/2` then routes through
`Trace.for_request` → `rehydrate_from_postgres` (`trace.ex:156,284`) → string-keyed
measurements; assert `usage.input_tokens == 10`. The existing atom-key happy-path test stays
green (coalesce handles both).

## Housekeeping (independent of the precommit gate)

- Add `.DS_Store` to `.gitignore` (currently absent; `.claude/.DS_Store` is untracked).
- Delete the stale sidecar `.claude/plans/recursive-squishing-cake-agent-a474630c7e7a1874b.md`
  (untracked; superseded by `recursive-squishing-cake.md`).

Neither affects `mix precommit`. Per project memory, **do not `git commit`** without explicit
authorization.

## Critical Files

New:
- `lib/jido_claw/core/json_safe.ex`

Modified:
- `lib/jido_claw/inspection.ex` (Fixes 3, 4, 5)
- `lib/jido_claw/tools/inspect_agent.ex` (Fixes 1, 2)
- `lib/jido_claw/agent_view.ex` (Fix 2 rewire)
- `.gitignore` (housekeeping)
- Tests: `test/jido_claw/inspection_test.exs`, `test/jido_claw/tools/inspect_agent_test.exs`

Reused (read-only): `lib/jido_claw/core/map_keys.ex`, `lib/jido_claw/agent/templates.ex`,
`lib/jido_claw/trace.ex`, `lib/jido_claw/trace/persistence.ex`,
`lib/jido_claw/trace/resources/{trace_run,trace_event}.ex`.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test test/jido_claw/inspection_test.exs \
         test/jido_claw/tools/inspect_agent_test.exs \
         test/jido_claw/agent_view_test.exs \
         test/jido_claw/tools/agent_status_test.exs \
         test/jido_claw/mcp_server_test.exs
mix precommit   # the gate — must be fully green
```

Manual smoke (optional): in `iex -S mix`, confirm `JidoClaw.inspect_agent("main")` returns
populated `tool_names`; `JidoClaw.inspect_workflow(uuid)` still works for local callers; the
MCP `inspect_agent` tool rejects `kind: "workflow"` and emits string-keyed `compaction`.

## Out of Scope
- Tenant-scoping `WorkflowRun` / `AgentTracker` (workflows stay local-only via Fix 1).
- Live-agent happy-path PID test (sandbox can't stand up a `Jido.AgentServer`).
- Any `git commit` (memory: never commit unprompted).
