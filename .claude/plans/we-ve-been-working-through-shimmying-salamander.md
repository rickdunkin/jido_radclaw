# Plan: Resolve code-review findings on the `forward_context` work

## Context

The just-landed `forward_context` feature (plan `please-review-docs-exploration-jidoka-fe-greedy-ocean.md`) got a code review that surfaced two issues. Both are **validated** against the current source:

1. **`apply_visibility/2` fails OPEN for malformed `{:except, _}` policies** (`lib/jido_claw/tool_context.ex:143`). The `{:except, drop}` clause runs `drop_keys(ctx, Enum.filter(drop, &(&1 in @policy_controlled_keys)))`. A typo'd atom (`{:except, [:usr_id]}`) or a string key (`{:except, ["user_id"]}`) gets filtered to `[]`, so **nothing is dropped** and the parent's full scope (`user_id`, `actor`, `workspace_uuid`, `workspace_id`, `forge_session_key`) leaks to the child. The sibling `{:only, _}` clause (line 140) fails *closed* via `@policy_controlled_keys -- keep`, so the two are asymmetric. `Templates.hydrate_template/1` catches this for the default registry, but `apply_visibility/2` is public, and `spawn_agent`/`send_to_agent` resolve templates through the injectable `Application.get_env(:jido_claw, :agent_templates, …)` (`spawn_agent.ex:210`, `send_to_agent.ex:116`) — an alternate/fake registry that skips hydration passes a raw policy straight to the primitive. This contradicts the documented "fails closed" contract on the function and the `visibility/0` typedoc. This matches the project threat model (leakage hygiene), so closing it is in scope.

2. **Doc count is wrong** (`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md:187`). T2-2 says AgentView is "consumed by **two of four** surfaces" then names 2 wired consumers (`agents_live.ex`, `agent_status` MCP tool) + 3 remaining (CLI REPL, `dashboard_live`, `forge_live`) = **5** surfaces. The doc's own prior-state paragraph (line 210) enumerates the same 5 (three LiveViews + CLI REPL + MCP). "four" should be "five".

**Definition of done:** `mise exec -- mix precommit` passes (Postgres up). Run via `mise exec` to pin OTP 28.5 — shell-default OTP forces a `memento` recompile that fails.

---

## Fix 1 — Make `{:only, _}` / `{:except, _}` fail closed on any non-policy key

### `lib/jido_claw/tool_context.ex`

Replace the two pattern-clauses (lines 140–144) so each one validates that **every** listed key is a member of `@policy_controlled_keys`; if not, fail closed (strip every policy-controlled key) — mirroring the exact `Enum.all?(keys, &(&1 in allowed))` check already used in `Templates.validate_fc/2` (`agent/templates.ex`):

```elixir
def apply_visibility(ctx, {:only, keep}) when is_map(ctx) and is_list(keep) do
  if Enum.all?(keep, &(&1 in @policy_controlled_keys)),
    do: drop_keys(ctx, @policy_controlled_keys -- keep),
    else: drop_keys(ctx, @policy_controlled_keys)
end

def apply_visibility(ctx, {:except, drop}) when is_map(ctx) and is_list(drop) do
  if Enum.all?(drop, &(&1 in @policy_controlled_keys)),
    do: drop_keys(ctx, drop),
    else: drop_keys(ctx, @policy_controlled_keys)
end
```

Behavior delta:
- `{:except, [:usr_id]}` / `{:except, ["user_id"]}` / `{:except, [:tenant_id]}` → **now fail closed** (was: leaked full scope / kept everything). The fail-open hole is closed.
- `{:only, [:user_id, :usr_id]}` (valid + typo) → now fails closed (was: silently kept `:user_id`). Minor tightening — not a leak fix, but makes the primitive consistent with `validate_fc` (which rejects the same input → `:none`). Both clauses are now genuinely symmetric.
- Valid policies are byte-for-byte unchanged: `{:only, [:user_id]}` keeps `:user_id`; `{:except, [:actor]}` strips only `:actor`. `:public`/`:none`/catch-all clauses are untouched.
- Structural keys (`:tenant_id`, `:session_id`, `:session_uuid`, `:project_dir`) are still never in any strip set, so they survive every path — including the new fail-closed branches.

Also update the doc text to match the new contract (no logic, just keep docs honest):
- `apply_visibility/2` `@doc` (lines 126–135): change the "both range only over `policy_controlled_keys/0`" sentence to state that a `{:only, _}`/`{:except, _}` naming **any** key outside `policy_controlled_keys/0` fails closed (matching `Templates.hydrate_template/1`), so a typo'd or string key can never silently forward the full scope.
- `visibility/0` `@typedoc` (lines 49–59): broaden "An unrecognized policy fails closed…" to also cover `{:only, _}`/`{:except, _}` listing an unknown key.

No spec change (`@spec apply_visibility(map(), visibility() | term()) :: map()` already admits `term()`); the `if/do/else` form matches the existing `validate_fc` style, so `credo --strict`/`dialyzer` stay green.

### `test/jido_claw/tool_context_test.exs`

- **Update `full_parent/0`** (lines 136–145) to add `workspace_id: "runtime-w"`. Today the helper carries only 4 of the 5 policy-controlled keys (`user_id`, `workspace_uuid`, `actor`, `forge_session_key`) — `:workspace_id` is missing, so no test exercises it even though the policy controls it and the review finding named both `workspace_id` and `workspace_uuid`. Adding it lets the suite prove all five keys are handled. Then add `workspace_id` assertions to each case below so the proof is real, not implied:
  - `:public` (keeps all) → `child.workspace_id == "runtime-w"`.
  - `:none` (strips all) → `child.workspace_id == nil`.
  - `{:only, [:user_id]}` (keeps only user_id) → `child.workspace_id == nil`.
  - `{:except, [:actor]}` (strips only actor) → `child.workspace_id == "runtime-w"`.
  - `:bogus` fail-closed → `child.workspace_id == nil`.
- **Rewrite** the existing `"{:except, [:tenant_id]} cannot drop the structural :tenant_id"` test (lines 100–110). It currently asserts `user_id`/`actor`/`forge_session_key` **survive** — that flips under fail-closed. New assertions: `:tenant_id`/`:session_uuid` survive (structural), **and** all five policy keys are nulled (`user_id`, `workspace_id`, `workspace_uuid`, `actor`, `Map.get(child, :forge_session_key) == nil`). Update the test name + comment to "fails closed — a non-policy key strips everything strippable; structural keys survive regardless."
- **Add** three tests proving the fix (use the updated `full_parent/0` + `child/3`):
  - `{:except, [:usr_id]}` (typo'd atom) → all five policy keys nil (incl. `workspace_id`), `tenant_id`/`session_uuid` intact (the headline regression).
  - `{:except, ["user_id"]}` (string key) → policy keys nil, `tenant_id` intact.
  - `{:only, [:user_id, :usr_id]}` (valid + unknown) → fails closed (`user_id` nil), documenting the `{:only}` tightening.

**No change to `templates.ex`/`templates_test.exs`** — the template layer already fails closed via `validate_fc`. This fix is purely defense-in-depth at the primitive, complementing (not replacing) the template-layer validation + warning.

---

## Fix 2 — Correct the T2-2 surface count

### `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md:187`

Change "consumed by **two of four** surfaces" → "consumed by **two of five** surfaces". (2 wired: `agents_live.ex` + `agent_status` MCP tool; 3 remaining: CLI REPL, `dashboard_live`, `forge_live` = 5 total, consistent with the line-210 enumeration.) No other numeral in the doc is wrong — lines 357/375 list the consumers without a count.

---

## Verification

1. **Primary gate (definition of done):** `mise exec -- mix precommit` — clean. Watch `credo --strict` (the new `if/do/else` mirrors `validate_fc`), `dialyzer` (specs unchanged), `format`. `jidoclaw.system_prompt.check` stays green (no tool/schema change).
2. **Focused tests** (the review's set, for regression):
   `mise exec -- mix test test/jido_claw/tool_context_test.exs test/jido_claw/memory/namespace_info_test.exs test/jido_claw/inspection_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/workflows/step_action_test.exs test/jido_claw/templates_test.exs`
3. **Manual (tidewave `project_eval`)** — prove the hole is closed:
   - `JidoClaw.ToolContext.apply_visibility(%{tenant_id: "t", user_id: "u", actor: %{}, forge_session_key: "fk"}, {:except, [:usr_id]})` → `user_id`/`actor`/`forge_session_key` nil, `tenant_id` intact.
   - `…apply_visibility(…, {:except, [:actor]})` → only `:actor` nil (valid case still works).
   - `…apply_visibility(…, {:except, ["user_id"]})` → policy keys nil (string-key fail-closed).

## Risks / notes

- **`{:except, [:tenant_id]}` semantics change** from "keep everything" to "fail closed." Intentional: naming a non-policy key is a malformed policy, and the template layer already rejects it (`validate_fc` → `:none`). The primitive now agrees. `:tenant_id` itself still survives (structural), so correlation/tenancy are unaffected.
- **No behavior change for the default hydrated template registry** — `Templates.get/1` hydrates + validates, so `step_action.ex`/`spawn_agent.ex`/`send_to_agent.ex` feed `apply_visibility/2` only already-valid policies; the swarm/workflows are byte-for-byte unchanged. The fix **does** change malformed-policy behavior for any *injected* `:agent_templates` module that skipped hydration (`spawn_agent`/`send_to_agent` intentionally allow one) and for direct public callers of the primitive — closing that gap is the point of the fix, not a side effect.
- **No logging at the primitive** — `apply_visibility/2` stays quiet on fail-closed. `Templates.hydrate_template/1` already logs malformed policies with operator-useful context (the template module); logging per child turn inside the primitive would be noisy and redundant.
- No new deps, migrations, tools, or schema changes.
