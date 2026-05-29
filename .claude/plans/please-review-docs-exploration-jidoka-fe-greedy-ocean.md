# Plan: Finish T2-4 Inspection `:memory` + Ship T2-3 `forward_context`

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` tracks Jidoka primitives borrowed into jido_radclaw. The most recent commit (`e7b00e4 "AgentView + Inspection (part 1)"`) left two items short of the doc's strict ADOPTED bar. This plan closes two small, independent gaps:

- **T2-4 Inspection (`:memory` field)** — PARTIAL only because `%JidoClaw.Inspection.Summary{}.memory` is hardcoded `nil`: its intended source, `Memory.namespace_info/1`, doesn't exist. Every other Summary field is sourced. Building that one function + wiring it in takes T2-4 → ADOPTED.
- **T2-3 Subagent context-visibility (`forward_context`)** — NOT_ADOPTED. Every spawned/stepped child inherits the parent's **full** scope today. There's no `:public | :none | {:only, _} | {:except, _}` knob. This is a leakage-hygiene gap matching the project threat model (LLM-misbehavior + scope leakage, not external attackers).

**T2-2 AgentView consumer migration** is explicitly **out of scope** — the three "unmigrated" surfaces (CLI REPL, `dashboard_live`, `forge_live`) project *different subsystems* (per-agent swarm via `AgentTracker`, Forge sandbox harnesses, workflow-run aggregates) that the per-session `AgentView` doesn't model. Part C corrects the doc's framing rather than attempting a migration that would lose data.

**Definition of done:** `mise exec -- mix precommit` passes (compile `--warnings-as-errors`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer`, `test`). Run via `mise exec` to pin OTP 28.5 — the shell-default OTP forces a dep recompile that fails on `memento`. Postgres must be running.

## Changes from v1 (addressing repo review)

- **P1 (MCP `session` → `memory: nil`):** Confirmed `Session` identity is `(tenant_id, workspace_id, kind, external_id)` with only `by_external/3`; external_id alone can't resolve a `%Session{}`. So the claim is corrected, not the dispatch: `:memory` populates exactly where `compaction` already does. The thin map path (`session_map_summary/3`, used by MCP `kind: "session"`) stays `nil` for both — documented, consistent.
- **P1 (workflow children):** `Workflows.StepAction` is a third child surface — now enforces the policy. Handoff routing is explicitly exempt (ownership transfer / full-context continuity).
- **P1 (fail-open):** Policy defaulting/validation centralized in `Templates.hydrate_template/1`; absent → `:public`, invalid → log + fail-closed `:none`. `apply_visibility/2`'s catch-all also fails closed.
- **P2 (`{:except}`):** intersects the drop list with `@policy_controlled_keys` — can never drop structural/`project_dir` keys.
- **P2 (`forge_session_key` test):** assertions use `Map.get(child, :forge_session_key) == nil` (it's omitted, not nil-valued, by `build/1`).
- **P2 (wording):** risks section reworded — policy strips selected caller identity + workspace/forge attribution, not "all tenant reach."
- **P3 (test path):** `test/jido_claw/templates_test.exs` (not `agent/templates_test.exs`).
- **P3 (scope over MCP):** MCP projection slims `:memory` to `%{scope_kind, blocks_count}` — drops the `scope` sub-map AND the FK embedded in `namespace` (no raw UUIDs cross the boundary); local Elixir callers keep the full `namespace`/`scope`.

## Changes from v2 (addressing second review)

- **MCP `namespace` FK leak:** slim to `%{scope_kind, blocks_count}` (not `%{namespace, blocks_count}`) — `"session:<uuid>"` would expose the session UUID, notably on `kind: "request"`.
- **`slim_memory/1` key shape:** route through `JsonSafe.encode/1` like the other nested maps, so MCP keys are string-keyed and the tool test's assertions match.
- **MCP memory test:** prove a NON-nil path via `kind: "request"` (session stays nil by design).
- **Template key-type validation:** `{:only, ["user_id"]}` (string keys) now fails closed — policy keys are atoms, so string keys would silently strip everything.
- **Hydration failure mode preserved:** `ensure_max_iterations/1` keeps its two-clause shape (no permissive catch-all) — malformed templates still fail loudly, never partially hydrate.
- **Handoff exemption comments** placed at each routed-turn dispatch site, not only the router.

## Changes from v3 (addressing third review)

- **`child/3` spec** also admits invalid policies (`visibility() | term()`) — fail-closed handling is in-contract there too (it delegates to `apply_visibility/2`).
- **Stricter key validation:** template `{:only, _}`/`{:except, _}` keys must all be members of `ToolContext.policy_controlled_keys/0`. One membership check rejects both string keys (`{:only, ["user_id"]}`) and typo'd atoms (`{:except, [:usr_id]}` — which would otherwise fail OPEN). New public accessor `ToolContext.policy_controlled_keys/0`.
- **Explicit invalid-key tests** in B4 (string-key, typo'd-atom, and bogus all → `:none`).

---

## Part A — T2-4: source `Summary.memory`

### A1. New `JidoClaw.Memory.namespace_info/1` — `lib/jido_claw/memory.ex`

Public function resolving a scope from a `tool_context`-like map, returning the shape already declared on `Summary` (`lib/jido_claw/inspection/summary.ex:53`): `%{namespace, blocks_count, scope} | nil`. Reuse existing machinery — no new Ash action, no schema change:
- `Memory.Scope.resolve/1` (`memory/scope.ex:75`) → `{:ok, scope_record}` (loads ancestor FKs) or `{:error, _}`.
- `Memory.Scope.primary_fk/1` (`scope.ex:235`) → FK naming the scope's primary level.
- `Memory.list_blocks_for_scope_chain/1` (`memory.ex:171`) → already label-deduped + `rescue`d to `[]`; `length/1` = prompt-visible block count. Reads as `Actor.system/1` internally (same as the prompt builder), so the count is scope-complete.

```elixir
@spec namespace_info(map()) ::
        %{namespace: String.t(), blocks_count: non_neg_integer(), scope: Scope.scope_record()}
        | nil
def namespace_info(tool_context) when is_map(tool_context) do
  case Scope.resolve(tool_context) do
    {:ok, scope} ->
      %{namespace: namespace_label(scope), blocks_count: length(list_blocks_for_scope_chain(scope)), scope: scope}
    {:error, _} -> nil
  end
end
def namespace_info(_), do: nil

defp namespace_label(%{scope_kind: kind} = scope), do: "#{kind}:#{Scope.primary_fk(scope) || "none"}"
```

`Scope` is already aliased in `memory.ex:47`. Returns a bare map/`nil` (consistent with `Memory`'s nil-friendly read API; `Inspection.safe/1` passes it through).

### A2. Wire `:memory` into `JidoClaw.Inspection` — `lib/jido_claw/inspection.ex`

Add `alias JidoClaw.Memory` and a helper mirroring `compaction_for/3` (`inspection.ex:686`):

```elixir
defp memory_for(nil, _tenant_id), do: nil
defp memory_for(_session_uuid, nil), do: nil
defp memory_for(session_uuid, tenant_id),
  do: safe(fn -> Memory.namespace_info(%{tenant_id: tenant_id, session_uuid: session_uuid}) end)
```

Set `memory:` in exactly the **three rich builders that already populate `compaction`** (memory and compaction become perfectly parallel):
- `build_request_summary/5` (`inspection.ex:122`) → `memory: memory_for(session_uuid, tenant_id)`
- `handoff_session_summary/4` (`inspection.ex:483`) → `memory: memory_for(session.id, tenant_id)`
- `plain_session_summary/3` (`inspection.ex:508`) → `memory: memory_for(session.id, tenant_id)`

**Leave `session_map_summary/3` (`inspection.ex:466`) untouched** — the map-input path has only `session_id` (= `external_id`), no session UUID, no actor, and already omits `compaction`/`usage`/`system_prompt`. It genuinely cannot resolve a session-scoped namespace without the UUID, so `:memory` stays `nil` there — consistent with `compaction`, not a new gap. `pid`/`agent_id`/`module` paths likewise stay `nil` (no session context).

### A3. Expose `:memory` over MCP — `lib/jido_claw/tools/inspect_agent.ex`

`:memory` is tenant-scoped via `Scope.resolve` (tenant read strictly from `tool_context.tenant_id`), so it's safe to surface — but minimize internal-identifier exposure at the MCP boundary by dropping BOTH the raw-UUID `scope` sub-map AND the FK embedded in `namespace` (P3 decision; `"session:<uuid>"` would leak the session UUID, e.g. on `kind: "request"` where the caller supplied only a request id):
- `output_schema` (~line 23): add `memory: [type: :map, required: false]`.
- `project/1` (~line 116): add `memory: s.memory |> slim_memory() |> JsonSafe.encode()` (mirrors the existing `JsonSafe.encode/1` normalization of nested maps, so keys come back string-keyed; `JsonSafe.encode(nil)` stays `nil`, as already relied on for `s.handoffs`). Define `slim_memory(%{blocks_count: c, scope: %{scope_kind: kind}}) -> %{scope_kind: to_string(kind), blocks_count: c}` and `slim_memory(_) -> nil` — exposes only the scope *kind* + count, never an FK.
- Update the moduledoc: `:memory` is intentionally exposed (tenant-scoped) but slimmed to `{scope_kind, blocks_count}` with no raw identifiers; the full `namespace`/`scope` are local-callers-only — contrast with the fully-dropped `:subagents`/`:workflows`.

### A4. Tests (Part A)

- **New** `test/jido_claw/memory/namespace_info_test.exs` (pattern: `test/jido_claw/memory/block_test.exs`, `use JidoClaw.TenantCase, async: false`): `seed_tenant/1` + `Workspaces.Resolver.ensure_workspace/3`; write 2 **distinct-label** workspace-scoped `Block.write(%{scope_kind: :workspace, workspace_id: ws.id, ...}, tenant:, actor:)`; assert `Memory.namespace_info(%{tenant_id: tid, workspace_uuid: ws.id})` → `%{namespace: "workspace:" <> _, blocks_count: 2, scope: %{scope_kind: :workspace}}`. Add `namespace_info(%{})` → `nil`.
- **Extend** `test/jido_claw/inspection_test.exs` session-dispatch test (~line 164; `seed_full(tenant_label: "inspection")` → `%{tenant_id, session, workspace}`): seed a **session**-scoped block (`scope_kind: :session, session_id: session.id`), then assert the `%Session{}`-struct case (`Inspection.inspect_agent(session)`, the rich `plain_session_summary` path) returns `s.memory.namespace == "session:#{session.id}"` and `s.memory.blocks_count >= 1`. Do **not** assert memory on the `%{tenant_id, session_id}` map case — it stays `nil` by design.
- **Extend** `test/jido_claw/tools/inspect_agent_test.exs` — prove a NON-nil memory path (since `kind: "session"` stays nil): seed a session-scoped block, register request correlation (`RequestCorrelation.register/1`), push a model trace event + `sync_collector/0` (the existing request-path test setup in `inspection_test.exs` is the template), then call the tool with `kind: "request"`, `target` = the request id, tenant via `tool_context`. Assert `result.memory == %{"scope_kind" => "session", "blocks_count" => n}` (string-keyed) with **no** `"scope"` or `"namespace"` key.

---

## Part B — T2-3: `forward_context` visibility policy

**Design choice (validated in v1 review):** the policy lives on the **template** (operator config), defaults to `:public`, and is enforced wherever a templated *child* context is built. Operator-controlled (a real security boundary, not LLM-chosen); identical across spawn / follow-up / workflow-step (no re-widening leak); policy keys stay atoms in source (no `String.to_atom` on untrusted input). A per-spawn LLM-override param is a documented future enhancement, not v1.

### B1. Policy mechanism — `lib/jido_claw/tool_context.ex`

Add a `visibility()` type, a public `apply_visibility/2` (reused by every enforcement site), and a `child/3` convenience:

```elixir
@type visibility :: :public | :none | {:only, [atom()]} | {:except, [atom()]}

# Caller-identity + scope-attribution keys a child may not need — the ONLY keys
# any policy can strip. Always forwarded (absent here, so untouchable): :tenant_id
# (Ash multitenancy), :session_id/:session_uuid (request correlation + trace
# linkage), :project_dir (child file tools; child/2 also cwd-fallbacks it).
@policy_controlled_keys [:user_id, :workspace_id, :workspace_uuid, :actor, :forge_session_key]

@doc "Keys a forward_context policy may strip. Used by Templates to validate config."
@spec policy_controlled_keys() :: [atom()]
def policy_controlled_keys, do: @policy_controlled_keys

# Spec admits `term()` for the policy: invalid values are in-contract (the
# catch-all below fails them closed), so the spec must say so.
@spec apply_visibility(map(), visibility() | term()) :: map()
def apply_visibility(ctx, :public) when is_map(ctx), do: ctx
def apply_visibility(ctx, :none) when is_map(ctx), do: drop_keys(ctx, @policy_controlled_keys)
def apply_visibility(ctx, {:only, keep}) when is_map(ctx) and is_list(keep),
  do: drop_keys(ctx, @policy_controlled_keys -- keep)
def apply_visibility(ctx, {:except, drop}) when is_map(ctx) and is_list(drop),
  do: drop_keys(ctx, Enum.filter(drop, &(&1 in @policy_controlled_keys)))
# Fail closed: an unrecognized policy strips everything strippable rather than
# silently forwarding the full scope.
def apply_visibility(ctx, _other) when is_map(ctx), do: drop_keys(ctx, @policy_controlled_keys)

defp drop_keys(map, keys), do: Enum.reduce(keys, map, fn k, acc -> Map.put(acc, k, nil) end)

# Same fail-closed contract as apply_visibility/2 — admits invalid policies.
@spec child(map() | nil, String.t(), visibility() | term()) :: map()
def child(parent_tool_context, child_tag, visibility) when is_binary(child_tag) do
  (parent_tool_context || %{}) |> apply_visibility(visibility) |> child(child_tag)
end
```

`{:only}`/`{:except}` are symmetric — both range only over `@policy_controlled_keys`, so structural/`project_dir` keys are never touched (P2). Nulling (not deleting) preserves `build/1`'s canonical shape. Update the moduledoc's "child agents inherit the parent's full scope" paragraph to describe the policy + the always-forward invariant.

### B2. Centralize default + validation — `lib/jido_claw/agent/templates.ex`

Do **not** edit the 7 static `@templates` maps (no churn). Instead make `hydrate_template/1` (run by `get/1` and `list/0`) default/validate the field, so every resolved template carries a valid `:forward_context`:

```elixir
require Logger
# ...
defp hydrate_template(template), do: template |> ensure_max_iterations() |> ensure_forward_context()

# Two clauses, NO catch-all — preserves today's behavior: a template lacking both
# :module and a valid :max_iterations still raises FunctionClauseError (loud),
# rather than returning a partially-hydrated map that crashes less clearly later.
defp ensure_max_iterations(%{max_iterations: m} = t) when is_integer(m) and m > 0, do: t
defp ensure_max_iterations(%{module: module} = t), do: Map.put(t, :max_iterations, module_max_iterations(module))

defp ensure_forward_context(%{forward_context: fc} = t), do: Map.put(t, :forward_context, validate_fc(fc, t))
defp ensure_forward_context(t), do: Map.put(t, :forward_context, :public)

defp validate_fc(fc, _t) when fc in [:public, :none], do: fc
# Every key must be a known policy-controlled key. This single membership check
# rejects BOTH string keys ({:only, ["user_id"]}) and typo'd atoms
# ({:except, [:usr_id]}) — the latter would otherwise fail OPEN for :except.
# Fail closed to :none + warn on any unknown key.
defp validate_fc({mode, keys} = fc, t) when mode in [:only, :except] and is_list(keys) do
  allowed = JidoClaw.ToolContext.policy_controlled_keys()
  if Enum.all?(keys, &(&1 in allowed)), do: fc, else: warn_fc(fc, t)
end
defp validate_fc(other, t), do: warn_fc(other, t)

defp warn_fc(bad, t) do
  Logger.warning("[Templates] invalid :forward_context #{inspect(bad)} for #{inspect(Map.get(t, :module))}; failing closed to :none")
  :none
end
```

Default `:public` everywhere = zero behavior change on landing (the doc's prescribed backwards-compat default). Add a moduledoc note documenting the `forward_context` knob, its vocabulary (atom keys drawn from `ToolContext.policy_controlled_keys/0`), and the `:public` default. Operators tighten an individual template by adding `forward_context: {:only, [...]}` to its map; the three modes are proven by tests (B4).

### B3. Enforce at every child-context build site

- `lib/jido_claw/tools/spawn_agent.ex` `register_spawned_agent/6` (line 71): `template` is in scope — `visibility = Map.get(template, :forward_context, :public)`, then `ToolContext.child(Map.get(context, :tool_context), tag, visibility)` (keep `|> Map.put(:swarm_depth, ...)`).
- `lib/jido_claw/tools/send_to_agent.ex` `send_to_agent/3` (line 34): `template_for_agent/1` returns the template — same `visibility`, then `ToolContext.child(..., params.agent_id, visibility)`. This re-applies the policy on every follow-up, so a child can't be re-widened mid-conversation.
- `lib/jido_claw/workflows/step_action.ex` `run/2` (line 70): change `tool_context = ToolContext.build(scope)` → resolve `visibility = Map.get(template, :forward_context, :public)` and `tool_context = ToolContext.build(ToolContext.apply_visibility(scope, visibility))`. (`scope` carries `actor`/`workspace_id`/etc.; `apply_visibility` nulls the policy keys before `build/1`.)

All three keep `tool_context:` on the `ask`/`ask_sync` call, so the static-AST check in `tool_context_shape_test.exs:103` still passes. `register_child_correlation/1` keeps working because `:tenant_id`/`:session_uuid` are never stripped.

**Explicitly exempt: handoff routing** (`lib/jido_claw.ex:229`, `lib/jido_claw/cli/repl.ex:384`). Handoff is an *ownership transfer* — it routes the same conversation's existing `tool_context` to the owning worker, not a freshly-built child context. Full-context continuity is the defining purpose of handoff, so `forward_context` deliberately does not apply. Place a short explanatory comment at **each routed-turn dispatch site that passes `tool_context` to the routed worker** (`lib/jido_claw.ex:229` AND `lib/jido_claw/cli/repl.ex:384`) — not only near the router — since that's where a reader will wonder why `forward_context` is absent.

### B4. Tests (Part B)

- **Extend** `test/jido_claw/tool_context_test.exs`: build a parent with all of `:tenant_id, :session_uuid, :user_id, :workspace_uuid, :actor, :forge_session_key`, then for each mode assert via `child/3` (or `apply_visibility/2`): `:public` keeps all; `:none` nulls the 5 policy keys, keeps `:tenant_id`/`:session_uuid`; `{:only, [:user_id]}` keeps `:user_id`, nulls the rest; `{:except, [:actor]}` nulls only `:actor`; `{:except, [:tenant_id]}` does **not** drop `:tenant_id` (structural guard); an invalid policy (e.g. `:bogus`) fails closed (nulls all policy keys). **`forge_session_key` assertions use `Map.get(child, :forge_session_key) == nil`** (it's omitted by `build/1`, not nil-valued); canonical keys can use `child.user_id == nil`.
- **Extend** `test/jido_claw/tools/spawn_agent_test.exs`: add a `FakeTemplates` variant returning `forward_context: :none` (or `{:only, [:workspace_uuid]}`); call `run/2` with a populated `tool_context` (user_id/workspace_uuid/actor set); assert via the existing `assert_receive {:ask_sync, ^pid, _, opts}` that `opts[:tool_context].user_id == nil` while `.tenant_id`/`.session_uuid` survive. Confirm the default fake (no `:forward_context`) still forwards everything.
- **Extend** `test/jido_claw/tools/send_to_agent_test.exs`: mirror, proving follow-ups re-apply the policy.
- **Extend** `test/jido_claw/workflows/step_action_test.exs` (uses the `agent_templates_override` hook): override a template with `forward_context: :none`, run a step with a scope carrying `user_id`/`actor`, assert the worker's received `tool_context` has those nulled and `tenant_id`/`session_uuid` intact.
- **Extend** `test/jido_claw/templates_test.exs` (correct path): assert `Templates.get("coder")` includes `forward_context: :public`; via the `agent_templates_override` hook, assert ALL of these hydrate to `:none` — the string-key policy `{:only, ["user_id"]}`, the typo'd-atom policy `{:except, [:usr_id]}` (would otherwise fail OPEN), and a bogus value `:nope`; and assert a valid `{:only, [:user_id]}` survives hydration unchanged.

---

## Part C — Doc update (`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`)

- **T2-4** (~line 231): PARTIAL → ADOPTED; replace the `:memory`-deferred note with the `Memory.namespace_info/1` source + the three rich builders; state the thin map path (`session_map_summary`, and thus MCP `kind: "session"`) leaves `:memory` `nil` by design, parallel to `compaction`; note MCP slims `:memory` to `{scope_kind, blocks_count}` (no raw FK/UUID).
- **T2-3** (~line 214): NOT_ADOPTED → ADOPTED; document the per-template policy, the always-forward structural invariant, enforcement at spawn / follow-up / workflow-step, the handoff exemption, fail-closed validation in `hydrate_template`, and the `:public` default.
- **T2-2** (~line 185): add a correction — the three surfaces project different subsystems (`AgentTracker` swarm, Forge harnesses, workflow aggregates), so "consumer migration" overstated the path; it's a redesign, not a deferral.
- Update the cross-reference graph + sequencing (lines ~343–366) for T2-3 ✓ and T2-4 ✓.

---

## Verification

1. **Primary gate:** `mise exec -- mix precommit` (Postgres up), clean. Watch: `dialyzer` (new `@spec`s on `namespace_info/1`, `apply_visibility/2`, `child/3`, the `visibility()` type); `credo --strict` (small helpers, alias order); `jidoclaw.system_prompt.check` stays green (no tool added/removed — only an existing tool's `output_schema` changes, so the catalog count is unchanged, no `priv/defaults/system_prompt.md` edit).
2. **Targeted:** `mise exec -- mix test test/jido_claw/memory/namespace_info_test.exs test/jido_claw/inspection_test.exs test/jido_claw/tool_context_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/workflows/step_action_test.exs test/jido_claw/templates_test.exs`.
3. **Manual (tidewave `project_eval`)**, after seeding a tenant/workspace/session + a Block or two:
   - `JidoClaw.Memory.namespace_info(%{tenant_id: tid, workspace_uuid: wid})` → `%{namespace: "workspace:" <> _, blocks_count: n, scope: %{scope_kind: :workspace}}`.
   - `JidoClaw.inspect_agent(session)` → `{:ok, %{memory: %{blocks_count: n}}}`.
   - `JidoClaw.ToolContext.apply_visibility(%{tenant_id: "t", session_uuid: "s", user_id: "u", actor: %{}}, :none)` → `user_id`/`actor` nil, `tenant_id`/`session_uuid` intact; `{:only, [:user_id]}` keeps `user_id`; `:bogus` nulls all policy keys.

## Risks / notes

- **Behavior change is opt-in only.** All templates resolve to `:public`, so the swarm + workflows are byte-for-byte unchanged on landing; restrictive policies are an explicit per-template edit validated against that worker's scope needs.
- **What the policy actually narrows (corrected wording):** it strips selected *caller identity* (`:user_id`, `:actor`) and *workspace/forge attribution* (`:workspace_id`/`:workspace_uuid`, `:forge_session_key`) — it does **not** remove all tenant reach. `:tenant_id` + `:session_uuid` remain, Ash paths can still synthesize `Actor.system(tenant_id)` and load session ancestors, and file tools keep `:project_dir`. Think "least-attribution," not "least-tenant-access."
- **Workflow workspace sharing:** `:workspace_id` is the cross-step VFS/shell key, so a restrictive policy on a workflow template reduces shared state between its steps. Acceptable because the default is `:public`; noted for operators.
- **MCP `kind: "session"` shows no memory/compaction** — a documented limitation of the external-id-only map path (no resolvable session UUID). Enriching it would need a `(tenant_id, external_id)` Session read; deferred.
- **`:memory` read cost:** `length(list_blocks_for_scope_chain/1)` loads full Block rows to count; fine at current volumes, a dedicated `Ash.count/2` is a future optimization. Noted, not done.
- **No new dependencies, no migrations, no new tools.**
