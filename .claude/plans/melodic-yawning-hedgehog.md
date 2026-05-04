# v0.6 Phase 2 — Code-review remediation

## Context

A code review against the v0.6 Phase 2 (Conversations: chat transcripts in Postgres) work surfaced one P1 and three P2 issues. All four were independently verified against the source — `MIX_ENV=test mix compile --warnings-as-errors` reproduces the P1 failure, and direct reads of the cited files confirm the P2 logic gaps. The reviewer also noted that local `ash.setup` failed because Postgres lacked the `vector` extension; that gate is now lifted (`pgvector` is supported and `lib/jido_claw/repo.ex:8` already lists `"vector"` in `installed_extensions/0`), so the targeted Phase 2 tests the reviewer skipped should now run end-to-end.

The intended outcome:
- Strict compile is green under `MIX_ENV=test` so CI can gate on it.
- `JidoClaw.history/2` and `history/3` honor the legacy `[user|assistant|system]` chat-history contract that Phase 2 §2.7 promised to preserve.
- `:tool_result` rows always link to the matching `:tool_call` parent of the *same request*, never a stale or sibling row.
- Workflow-launched child agents inherit the parent's `user_id` so audit trails carry user scope through nested skills.

## Files to modify

| # | File | Change |
|---|---|---|
| 1 | `lib/jido_claw/conversations/transcript_envelope.ex` (lines 117-123) | Drop unreachable `nil` clause in `jason_encoder?/1` |
| 2 | `lib/jido_claw/conversations/resources/message.ex` (lines 91-99 + 152) | Add `:tool_call_parent` read action and code_interface entry |
| 3 | `lib/jido_claw/conversations/recorder.ex` (lines 249-281) | Switch parent lookup to the new action; guard nil `request_id` |
| 4 | `lib/jido_claw/platform/session/worker.ex` (lines 142-175, 250-282) | Filter chat roles in `to_view` and the in-memory cache append |
| 5 | `lib/jido_claw.ex` (lines 293-319) | Filter chat roles in `cold_view` path of `history/3` |
| 6 | `lib/jido_claw/tools/run_skill.ex` (lines 55-63) | Add `:user_id` to scope_context `Map.take` allowlist |
| 7 | `lib/jido_claw/workflows/step_action.ex` (lines 13-42, 159-169) | Add `user_id` to schema and `resolve_scope/3` |

Tests added under `test/jido_claw/conversations/` and `test/jido_claw/workflows/`.

## Fix details (in execution order)

### 1. P1 — `transcript_envelope.ex:117-123`

**Why first:** unblocks `MIX_ENV=test mix compile --warnings-as-errors`. Until this passes, Phase 2 tests can't be gated by strict compile.

**Change:** collapse `jason_encoder?/1` to a two-clause case (no `nil ->`), since under consolidated protocol `Jason.Encoder.impl_for/1` only returns registered impl modules. The function is only invoked from inside the struct branch of `walk/1`, so the meaningful question is whether the impl is `Jason.Encoder.Any` or a real one.

```
defp jason_encoder?(value) do
  case Jason.Encoder.impl_for(value) do
    Jason.Encoder.Any -> false
    _ -> true
  end
end
```

### 2. New `:tool_call_parent` read action — `resources/message.ex`

Defines the single-row parent lookup that fix #3 consumes. Add alongside the existing `:by_tool_call` and `:by_request` actions; do not remove `:by_tool_call` (it's a debug helper).

```
read :tool_call_parent do
  argument :session_id, :uuid, allow_nil?: false
  argument :request_id, :string, allow_nil?: false
  argument :tool_call_id, :string, allow_nil?: false

  filter expr(
    session_id == ^arg(:session_id) and
    request_id == ^arg(:request_id) and
    tool_call_id == ^arg(:tool_call_id) and
    role == :tool_call
  )

  prepare build(limit: 1, sort: [sequence: :asc])
end
```

Add the matching `define/3` in `code_interface`:
```
define :tool_call_parent, action: :tool_call_parent, args: [:session_id, :request_id, :tool_call_id]
```

The existing `(session_id, role)` index (`message.ex:84`) plus the partial `unique_live_tool_row` identity already cover this filter — no new index needed. After adding the action, run `mix ash.codegen --check` and `mix ash_postgres.generate_migrations --check`; if either reports drift, run the corresponding generator to capture whatever it wants (see Risks).

### 3. P2 — `recorder.ex:249-281` parent resolution

Replace the `by_tool_call` lookup with `tool_call_parent`. The new action declares `request_id` and `tool_call_id` as `allow_nil?: false`, so guard both before calling — `:by_tool_call` happened to tolerate nils by returning a possibly-wrong row, but the new action will raise.

```
parent =
  if is_binary(request_id) and is_binary(tool_call_id) do
    case Message.tool_call_parent(scope.session_id, request_id, tool_call_id) do
      {:ok, [%{id: id} | _]} -> id
      _ -> nil
    end
  else
    nil
  end
```

If `request_id` is `nil`, `resolve_scope/1` (line 384) already returns `:error` before this branch is reached — meaning the `:tool_result` row isn't written at all. The guard above only matters for the rare path where scope resolves but `tool_call_id` is missing from the signal data; in that case we still write a `:tool_result` row with `parent_message_id: nil` (matching today's behavior).

This closes the three failure modes the plan §2.3 enumerated:
1. Cold-start replay re-emitting a stale `tool_call_id` no longer matches an older parent (request_id differs).
2. Duplicate `:tool_call` rows from strategy + directive layers can't shadow each other across requests.
3. Same tool called twice in different requests with overlapping lifetimes resolves the right parent for each.

### 4. P2 — `worker.ex:250-282` view filtering

Collapse the two `to_view` clauses to a single one returning `:skip` for non-chat roles, then thread through `Enum.flat_map/2`:

```
defp load_messages(session_uuid) do
  case Message.for_session(session_uuid) do
    {:ok, rows} -> Enum.flat_map(rows, &to_view/1)
    _ -> []
  end
rescue
  e ->
    Logger.warning("[Session] message hydration raised: #{Exception.message(e)}")
    []
end

defp to_view(%{role: role, content: content, inserted_at: inserted_at})
     when role in [:user, :assistant, :system] do
  [%{
    role: Atom.to_string(role),
    content: content,
    timestamp: DateTime.to_unix(inserted_at, :millisecond)
  }]
end

defp to_view(_), do: []
```

Update the in-memory cache append in `handle_call({:add_message, ...}, ...)` (lines 142-171) to use list concatenation with the new list-returning helper:

```
new_state = %{
  state
  | messages: state.messages ++ to_view(message),
    last_active: DateTime.utc_now()
}
```

Note `++ to_view(message)` (not `++ [view]`) — `to_view` now returns either `[view]` or `[]`. All current `add_message/4` callers pass `:user` or `:assistant`, so this is mostly defensive, but it keeps the in-memory cache consistent with what hydration produces.

### 5. P2 — `lib/jido_claw.ex:293-319` cold-cache history

Mirror the worker's filter:

```
{:ok, rows} <- JidoClaw.Conversations.Message.for_session(session.id) do
  rows
  |> Enum.filter(&(&1.role in [:user, :assistant, :system]))
  |> Enum.map(&cold_view/1)
end
```

`cold_view/1` itself stays unchanged.

### 6. P2 — `tools/run_skill.ex:55-63` scope_context

Add `:user_id` to the `Map.take` allowlist:

```
scope_context =
  Map.take(tool_context, [
    :tenant_id,
    :session_id,
    :session_uuid,
    :workspace_id,
    :workspace_uuid,
    :project_dir,
    :user_id
  ])
```

`Map.take` is the only chokepoint that strips `user_id` between agent → workflow drivers. The drivers themselves (`SkillWorkflow`, `PlanWorkflow`, `IterativeWorkflow`) `Map.merge(scope_context)` straight into params (audited via `grep "Map.take|Keyword.take" lib/jido_claw/workflows/` — no driver filters), so once `user_id` is in `scope_context` it flows through unchanged.

### 7. P2 — `workflows/step_action.ex` schema + resolve_scope

Add the schema entry (after `:workspace_uuid`, line 41):
```
user_id: [
  type: :string,
  required: false,
  doc: "Authenticated user UUID for downstream FK attribution (Phase 0)"
]
```

Add the resolver entry inside `resolve_scope/3` (line 159-169):
```
user_id: pick(params, context, :user_id, nil)
```

`register_child_correlation/1` (line 196) already calls `Map.get(c, :user_id)` — once `resolve_scope` populates the key, the existing call wires through to `JidoClaw.register_correlation/5` and the `RequestCorrelation` row gets `user_id` filled.

`spawn_agent.ex` and `send_to_agent.ex` use `JidoClaw.ToolContext.child/2`, which preserves all canonical keys (including `:user_id` per `tool_context.ex:36`); their child correlations already work. Fix #7 brings the workflow path to parity.

## Tests to add

1. `test/jido_claw/conversations/history_test.exs` (new)
   - Seed `Conversations.Session` and a Workspace via `Workspaces.Resolver.ensure_workspace/3`. Seed `Message.append/1` rows for `:user`, `:tool_call`, `:tool_result`, `:reasoning`, `:assistant`.
   - **Hot path:** `Session.Supervisor.ensure_session(tenant, external_id)` so the worker exists, then `Session.Worker.set_session_uuid(tenant, external_id, session.id)` — this is what triggers `load_messages/1` to hydrate `state.messages` from Postgres. Without that setter call, `state.messages` is empty regardless of how many rows are in Postgres. Then call `JidoClaw.history(tenant, external_id)` — assert exactly the user/assistant entries.
   - **Cold path:** stop the worker by looking up the PID via `Registry.lookup(JidoClaw.SessionRegistry, {tenant_id, external_id})` and `GenServer.stop/1` (no `Session.Supervisor.stop_session` helper exists). Then call `JidoClaw.history(tenant, external_id, kind: :api, workspace_id: project_dir)`. Note: `:workspace_id` here is **the workspace project path**, not the UUID — `history/3` passes it through `Workspaces.Resolver.ensure_workspace/3`. Use the same `project_dir` you fed the resolver during seeding so the Workspace lookup matches. Assert the same filtered set.

2. `test/jido_claw/conversations/recorder_test.exs` (extend) — tool signals carry `request_id` only, not `session_id`; the recorder resolves the session via `RequestCorrelation` lookup. Tests must register correlations *before* emitting signals AND must serialize on the recorder's async dispatch.
   - **Deterministic barrier.** After each emitted `ToolResult`, also emit the matching `ai.request.completed` signal (`%Jido.Signal{type: "ai.request.completed", data: %{request_id: rid}}`) and call `Recorder.flush(rid)` before querying Postgres. The recorder processes signals from a separate process; without the terminal-signal + flush barrier the test races `Message` reads against pending recorder work.
   - **Cross-session case:** create sessions A and B. Register R1 against session A and R2 against session B (via `JidoClaw.register_correlation/5` or by inserting `RequestCorrelation` rows + `Cache.put`). Seed a `:tool_call` row in A with `(request_id: R1, tool_call_id: "xyz")` and another in B with `(request_id: R2, tool_call_id: "xyz")`. Emit a `Signal.ToolResult` carrying `metadata.request_id = R1` and `call_id = "xyz"`; emit `request.completed` for R1; flush. Assert the resulting `:tool_result.parent_message_id == session_A_tool_call.id`.
   - **Same-session, two-request case:** in one session, register R1 and R2; seed two `:tool_call` rows with the same `call_id` under R1 and R2. Emit `ToolResult` for R2; emit `request.completed` for R2; flush. Assert it links to the R2 parent, not R1's.
   - **Missing parent (registered scope, real call_id, no parent row) case:** register R3 against session A; emit `ToolResult` for R3 with a real `tool_call_id` (e.g. `"orphan_call"`) that has no seeded `:tool_call` row. Assert the `:tool_result` is written with `parent_message_id: nil` and no log promotes to error. (Don't use a missing/nil `tool_call_id` here — the partial identity `unique_live_tool_row` and the new action's `allow_nil?: false` argument both gate that path differently; a real call_id with no parent is the failure mode users actually hit on cold-start replay.)
   - **Unregistered request_id case:** emit `ToolResult` with `metadata.request_id` set to a UUID that has no `RequestCorrelation` row and no Cache entry. Don't emit a terminal signal for it (there's nothing to flush against). Assert no `:tool_result` row is written (`resolve_scope/1` short-circuits) and no exception escapes — sleep briefly or rely on the recorder mailbox being empty after a probe call (e.g. flush a known-completed sentinel request to confirm the queue has drained).

3. `test/jido_claw/workflows/step_action_test.exs` (new) — keep at the unit level; do not exercise `Agent.Templates` end-to-end unless we add a stub template that doesn't touch a live LLM path.
   - Build a `tool_context` map with all canonical keys including `user_id`. Call `StepAction.resolve_scope(%{}, %{tool_context: ctx}, "tag")` and assert the result map carries the `user_id`.
   - Pass `user_id` via `params` and via `context.tool_context` independently; assert both paths populate the resolved scope (covers the `pick/4` lookup chain).
   - Confirm `register_child_correlation/1` (private — exercise via a thin test wrapper or by spawning `StepAction.run/2` against a stub that yields immediately) writes a `RequestCorrelation` row with the populated `user_id`.

4. `test/jido_claw/tools/run_skill_test.exs` (new or extend, unit-level)
   - Mocking `JidoClaw.Skills.get/2` is awkward (no existing pattern in this project). Instead, extract the scope-takeoff into a small private-but-doc-public helper: `RunSkill.scope_context(tool_context)` that wraps the existing `Map.take/2`. Then test it directly: `RunSkill.scope_context(%{user_id: "u-123", tenant_id: "t", ...})` returns a map with `:user_id`. Pure-function test; no Skills lookup, no LLM path.

5. `test/jido_claw/conversations/transcript_envelope_test.exs` (extend)
   - Add a regression test for `jason_encoder?/1` using two **custom** test structs — one with `@derive Jason.Encoder` and one without. `DateTime` has a dedicated `walk/1` clause and never reaches `jason_encoder?/1`, so it can't pin the behavior. The custom-struct variant routes through the generic `walk(%_struct{})` branch and exercises the live decision.
   - Pin both outcomes after protocol consolidation: the derived struct should produce a normalized map (round-trip through `Jason.encode/decode`), and the non-derived struct should produce the `%{status: :error, raw_inspect: "..."}` envelope. The fix collapses the `nil` clause but does not change the `Jason.Encoder.Any` branch — these tests guard against future regressions where derive/no-derive cases get swapped.

6. Strict compile gate: run `MIX_ENV=test mix compile --warnings-as-errors --force` as a CI/check step, not as an ExUnit test. Shelling out to `mix compile` from inside a test is slow and environment-flaky; the same coverage comes from the existing CI command list.

## Verification

```bash
# 1. Strict compile (the P1 gate)
MIX_ENV=test mix compile --warnings-as-errors --force

# 2. Codegen drift after the new read action
mix ash.codegen --check
mix ash_postgres.generate_migrations --check

# 3. Phase 2 targeted suites the reviewer skipped
mix ash.setup --quiet
mix test test/jido_claw/conversations/
mix test test/jido_claw/agent/recorder_plugin_coverage_test.exs

# 4. Workflow correlation propagation
mix test test/jido_claw/workflows/

# 5. Full suite for sanity
mix test
```

Manual end-to-end (REPL):
1. `mix jidoclaw`, start a session, run any built-in skill that triggers a tool call (e.g. `/run_skill explore_codebase`).
2. In iex: `JidoClaw.history("default", "<session_id>")` — verify only `user`/`assistant` entries.
3. `psql $DATABASE_URL -c "SELECT role, count(*) FROM messages GROUP BY role;"` — verify all six role categories present in storage.
4. `psql -c "SELECT user_id FROM request_correlations ORDER BY inserted_at DESC LIMIT 5;"` — exercise the workflow path with a `user_id`-bearing surface (e.g. via the web LiveView dashboard, or by setting `user_id` explicitly through `JidoClaw.chat/4`); verify child correlations carry the same `user_id`.

## Risks & notes

- **Codegen drift.** The new `:tool_call_parent` action is read-only, so AshPostgres should not emit a new SQL migration *or* update the resource snapshot (snapshots track database shape, not action surface). Still run `mix ash.codegen --check` and `mix ash_postgres.generate_migrations --check` to confirm — if either flags drift, run `mix ash.codegen <name>` and `mix ash_postgres.generate_migrations` to capture whatever it wants. Don't pre-commit a snapshot you didn't see drift on.
- **Existing wrong-parent rows in dev DB.** Any `:tool_result` rows already written with the old `(session_id, tool_call_id)` lookup may have an incorrect `parent_message_id` if a `tool_call_id` was reused. Since this is pre-prod, easiest cleanup is `mix ecto.reset` after the fix lands. If reset isn't acceptable, a one-shot Ecto `UPDATE` re-resolving parents over `request_id IS NOT NULL` rows would do it — but only if the locally-persisted data has value.
- **`message_count` semantics shift.** `Session.Worker.get_info/2` now reports `length(state.messages)` against a chat-only cache. Audited consumers (`grep get_info\|message_count`) — only `Session.Worker` itself sees the field; `Channel.Worker` is unrelated. Safe.
- **`Recorder.attempt_append/1` swallows errors.** Independent of these fixes — the Recorder logs and returns `:ok` on every error including `:cross_tenant_fk_mismatch`. Optional follow-up: promote unknown errors to `Logger.error` so monitoring picks up regressions. Out of scope for this remediation unless the new `:tool_call_parent` action surfaces unexpected failure modes during test.
- **Pre-existing tests using `by_tool_call`.** None — `grep` confirms `recorder.ex:259` is the sole caller. Safe to leave the action in place for future inspection helpers.
