# Re-port `anubis_tools_handler_patch.ex` against anubis_mcp 1.6.1

## Context

`mix deps.update --all` bumped `anubis_mcp` from 1.5.0 → 1.6.1 (transitive, via `jido_mcp`). The runtime patch at `lib/jido_claw/core/anubis_tools_handler_patch.ex` is a verbatim port of upstream's 1.5.0 `Anubis.Server.Handlers.Tools` with two surgical fixes layered in: (a) `rescue` clause in `validate_params/3` that catches Peri crashes triggered by jido_mcp's JSON-Schema-shaped tool descriptors, and (b) `atomize_known_keys/1` that converts incoming string-keyed MCP arguments to atoms before dispatch.

Between 1.5.0 and 1.6.1, upstream's 1.6.0 release added OAuth 2.1 authorization (#158, see `deps/anubis_mcp/CHANGELOG.md:12-18`). The relevant code change is in `deps/anubis_mcp/lib/anubis/server/handlers/tools.ex`: `handle_list/3` now filters tools through `Enum.filter(&visible?(&1, frame))` before pagination (line 17), and both `handle_call/3` clauses now run `:ok <- check_scopes(tool, frame)` as the first step of the `with` chain (lines 35, 49). Two new private helpers were added: `check_scopes/2` (`tools.ex:61-72`) and `visible?/2` (`tools.ex:74-75`). 1.6.1 itself only patches an unrelated request-id echo (`CHANGELOG.md:5-10`), so the handler module is identical between 1.6.0 and 1.6.1.

Our patch — copied from 1.5.0 — has none of this. With our patch loaded, any tool registered with non-empty `scopes:` would be visible to clients without those scopes (in `handle_list`) and would dispatch without enforcement (in `handle_call`).

Today this is a latent gap, not a live bug: a grep across `lib/`, `test/`, `priv/`, `config/` returns zero `scopes:` declarations on any tool registration path. `deps/jido_mcp/lib/jido_mcp/server/runtime.ex:10-15` (the project's MCP tool-registration entry point via `JidoClaw.MCPServer` and `JidoClaw.Memory.Consolidator.MCPServer`) only forwards `description` and `input_schema`, so every tool inherits the struct default `scopes: []` (see `deps/anubis_mcp/lib/anubis/server/component/tool.ex:82-95` and `frame.ex:154`). With every tool's `scopes` empty, both new helpers short-circuit on their `%Tool{scopes: []}` clauses (`check_scopes` → `:ok`, `visible?` → `true`) without ever consulting the frame — so the STDIO-transport case (`frame.context.auth == nil`) is irrelevant for current call sites. For completeness: on a default `%Frame{}`, `Frame.scopes/1` (`frame.ex:371-377`) returns `[]`, and `Frame.has_all_scopes?/2` (`frame.ex:400-404`) returns `true` only when `required == []` (otherwise `false`). Net result: with the refresh, every existing call site behaves identically to today.

The patch's two surgical fixes are still load-bearing: `deps/jido_mcp/lib/jido_mcp/server/runtime.ex:247-253` still emits JSON Schema via `Jido.Action.Schema.to_json_schema/2`, and `deps/anubis_mcp/lib/anubis/server/frame.ex:140-141` still wraps that into `fn params -> Peri.validate(raw_schema, params) end` for `validate_input`. Neither removal trigger has been hit.

Goal: re-port the patch against 1.6.1 so the missing scope enforcement is back, keep both surgical fixes, and extend the existing regression test (`test/jido_claw/core/anubis_tools_handler_patch_test.exs`) with cases for the new upstream behavior so the next bump can't silently drift.

## Approach

### 1. Re-port the handler (`lib/jido_claw/core/anubis_tools_handler_patch.ex`)

Use `deps/anubis_mcp/lib/anubis/server/handlers/tools.ex` (1.6.1, 155 lines) as the new base, then re-apply the surgical fixes. Concrete edits relative to the current patch file:

- **`handle_list/3`** — replace the body to pipe through `Enum.filter(&visible?(&1, frame))` between `get_server_tools/2` and `maybe_paginate/3`. Exact upstream shape at `tools.ex:13-27`.
- **Both `handle_call/3` `with` chains** — prepend `:ok <- check_scopes(tool, frame),` as the first step, before the existing `:ok <- check_task_policy(tool, request, frame),`. Exact ordering: `check_scopes → check_task_policy → validate_params → forward_to`. Mirrors upstream `tools.ex:35-37` and `:49-51`.
- **Add `check_scopes/2`** — two clauses, verbatim from upstream `tools.ex:61-72`. Returns `:ok` on empty required scopes; otherwise computes `missing = required − Frame.scopes(frame)` and returns `Error.execution("insufficient_scope", %{required:, granted:})` if `missing ≠ []`.
- **Add `visible?/2`** — two clauses, verbatim from upstream `tools.ex:74-75`. Empty scopes → `true`; otherwise `Frame.has_all_scopes?(frame, required)`.
- **Preserve verbatim** (do not touch): the `rescue _ -> {:ok, params}` clause on `validate_params/3` (current patch lines 108-115), the `params = atomize_known_keys(params)` line at the top of `forward_to/4` (handler-less branch, current patch lines 117-133), `atomize_known_keys/1` and `safe_to_existing_atom/1` (current patch lines 148-165). The FIX comments stay.
- **Preserve verbatim**: `check_task_policy/3` and its three clauses (current patch lines 88-102) — byte-identical to upstream `tools.ex:83-97`.
- **Aliases**: `Frame` is already aliased at current patch line 30 — no change needed for the new `Frame.scopes/1` / `Frame.has_all_scopes?/2` calls.
- **Update the file header docstring** (current patch lines 1-23): change "Patch for anubis_mcp 1.5.0" → "Patch for anubis_mcp 1.6.1"; add a sentence noting that `check_scopes/2`, `visible?/2`, and the `handle_list` filter / `handle_call` scope step were ported from 1.6.0's OAuth 2.1 feature (#158); keep the explanation that the two surgical fixes are still required (jido_mcp still emits JSON Schema; Jido actions still pattern-match on atom keys).

### 2. Update `mix.exs` patch-inventory comment

The comment block at `mix.exs:14-30` says "anubis_mcp 1.5.0 — patched in `lib/jido_claw/core/`". Update the version pin to `1.6.1`. Code unchanged — comment only.

### 3. Extend the regression test (`test/jido_claw/core/anubis_tools_handler_patch_test.exs`)

The existing file already covers the two surgical fixes and the 1.5.0 task-policy clauses (four cases at lines :38, :71, :112, :139 per the existing test). Keep those unchanged. Add five new cases for the 1.6.0 scope-filtering behavior, following the same hand-built frame + stub-server pattern already in the file:

1. **`handle_call` — tool with non-empty `scopes:` and frame missing scopes** — register a tool with `scopes: ["admin"]`, build a frame whose granted scopes are empty, call `handle_call/3`. Assert the exact Anubis error shape: `{:error, %Anubis.MCP.Error{reason: :execution_error, message: "insufficient_scope", data: %{required: ["admin"], granted: []}}, _frame}` (use map-pattern matching on `data` to match the relevant keys). Assert the stub server's `handle_tool_call/3` was *not* invoked.
2. **`handle_call` — tool with non-empty `scopes:` and frame holding all required scopes** — same tool, frame seeded with `["admin"]`. Assert the stub server *is* invoked (i.e., scope check passes → task policy → validate → forward).
3. **`handle_list/3` — visibility filter** — pre-seed `frame.tools` with two tools: one `scopes: []` (always visible) and one `scopes: ["admin"]`. Build a frame without `"admin"` scope. Call `handle_list/3`. Assert only the empty-scopes tool appears in the result.
4. **`handle_list/3` — visibility filter with sufficient scopes** — same two tools, frame seeded with `["admin"]`. Assert both tools appear.
5. **`handle_list/3` — filter runs before pagination** — pre-seed `frame.tools` with two tools where the hidden tool (`scopes: ["admin"]`) sorts *before* the visible tool (`scopes: []`) in `Handlers.get_server_tools/2`'s emitted order. Set `frame.pagination_limit: 1`. Build a frame without `"admin"` scope. Call `handle_list/3`. Assert the visible tool appears in the result. If a future refactor accidentally paginates before filtering, the hidden tool would be selected by the limit-1 cut and removed by the filter, leaving an empty result — this case catches that regression.

Auth-frame shape (confirmed from `Frame.scopes/1` at `deps/anubis_mcp/lib/anubis/server/frame.ex:371-377`):

```elixir
%Anubis.Server.Frame{
  context: %Anubis.Server.Context{auth: %{scopes: ["admin"]}}
}
```

Add `alias Anubis.Server.Context` to the test module along with the existing `Anubis.Server.Frame` alias. For "no scopes granted" cases, omit `auth:` from the context (defaults to `nil`, which `Frame.scopes/1` reads as `[]`).

Stub server pattern: identical to the existing file — a tiny `defmodule` that implements `handle_tool_call/3` to `send(self(), {:called, name, params})` for `assert_received` assertions. New scope tests use the same stub.

## Files

| File | Change |
| --- | --- |
| `lib/jido_claw/core/anubis_tools_handler_patch.ex` | Re-port against 1.6.1: add `check_scopes/2`, `visible?/2`, the `Enum.filter` in `handle_list/3`, and the leading `check_scopes` step in both `handle_call/3` clauses; preserve both surgical fixes and `check_task_policy/3` exactly; update header docstring version pin and rationale. |
| `mix.exs` | Bump `anubis_mcp 1.5.0` → `anubis_mcp 1.6.1` in the patch-inventory comment block (lines 14-30). Comment only. |
| `test/jido_claw/core/anubis_tools_handler_patch_test.exs` | Add five new cases covering scope filtering: two for `handle_call/3` (insufficient + sufficient scopes), three for `handle_list/3` (filtered, unfiltered, filter-before-pagination). Existing four cases unchanged. |

## Reference points (do not modify)

- `deps/anubis_mcp/lib/anubis/server/handlers/tools.ex` — 1.6.1 upstream, the new base
- `deps/anubis_mcp/lib/anubis/server/component/tool.ex:82-95` — `Tool` struct, `scopes: []` default
- `deps/anubis_mcp/lib/anubis/server/frame.ex:138-177` — `Frame.register_tool/3`, accepts `:scopes` opt, defaults `[]` at `:154`
- `deps/anubis_mcp/lib/anubis/server/frame.ex:371-377` and `:400-404` — `Frame.scopes/1` and `Frame.has_all_scopes?/2`, total on default frames
- `deps/anubis_mcp/lib/anubis/server/handlers/prompts.ex:35-73` and `resources.ex:55-118` — sibling handlers that adopted the same scope pattern; useful as cross-reference if any clause shape is ambiguous
- `deps/jido_mcp/lib/jido_mcp/server/runtime.ex:10-15` and `:247-253` — confirms no `scopes:` passed downstream and JSON Schema emission still happens
- `deps/anubis_mcp/CHANGELOG.md:5-18` — 1.6.0 and 1.6.1 entries

## Verification

1. **`mix compile --warnings-as-errors`** — confirms the re-port still satisfies `ignore_module_conflict: true` redefinition, and that `Frame.scopes/1` / `Frame.has_all_scopes?/2` resolve under 1.6.1.
2. **`mix test test/jido_claw/core/anubis_tools_handler_patch_test.exs`** — all four existing cases plus the four new scope cases pass.
3. **`mix test test/jido_claw/mcp_server_test.exs`** — confirms `JidoClaw.MCPServer` is still load-clean after the runtime BEAM swap in `JidoClaw.Application.start/2` (lib/jido_claw/application.ex:25) and still publishes 15 tools.
4. **`mix test`** — full suite (~1900 tests) stays green; no regression in adjacent surface (`tools/mcp_scope_test.exs`, `mcp_scope/initializer_test.exs`, `error/tools_wire_format_test.exs`).
5. **Boot smoke** — `mix jidoclaw --mcp` starts without crashing on init (exercises the three-layer patch loading: `DependencyPatches.ensure_loaded!/0`, the compile-time `ignore_module_conflict`, and the release-time relocation are all consistent with the new module shape).

## Out of scope

- **Adding `scopes:` to any JidoClaw tool.** No tool needs OAuth scopes today (STDIO transport, single-user tailnet — see `memory/project_threat_model.md`). Surfacing scopes through `JidoClaw.Tools.Action` is a separate feature.
- **The other three runtime patches** (`jido_shell_registry_patch.ex`, `jido_shell_session_patch.ex`, `jido_shell_session_server_patch.ex`). These target `jido_shell`, which was not bumped in this `deps.update` cycle (it's GitHub-pinned at `mix.exs:170-173`).
- **Removing the patch entirely.** Both removal triggers (Peri-compatible schemas from jido_mcp; upstream behavior changes) remain open.
- **Adding a startup version-fingerprint assertion** to make future drift loud instead of silent. Worth considering as a follow-up if anubis_mcp churn rate justifies it; not warranted by this single bump.
