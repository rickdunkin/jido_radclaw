# Re-port `anubis_tools_handler_patch.ex` against anubis_mcp 1.5.0

## Context

`mix deps.update --all` bumped `anubis_mcp` from 1.1.1 → 1.5.0 (transitive, via `jido_mcp`). The runtime patch at `lib/jido_claw/core/anubis_tools_handler_patch.ex` is a verbatim port of upstream's 1.1.1 `Anubis.Server.Handlers.Tools` with two surgical fixes layered in: (a) `rescue` clause in `validate_params/3` that catches Peri crashes triggered by jido_mcp's JSON-Schema-shaped tool descriptors, and (b) `atomize_known_keys/1` that converts incoming string-keyed MCP arguments to atoms before dispatch.

Between 1.1.1 and 1.5.0, upstream added `check_task_policy/3` to enforce MCP spec 2025-11-25 task-augmentation semantics — tools may declare `task_support: :required` (must be invoked through a task worker, signaled by `Frame.task_id` being set) or `:forbidden` (callers must not include `params.task`). The 1.5.0 `handle_call/3` heads bind the whole request map and call `check_task_policy/3` ahead of `validate_params/3`. Our patch still uses 1.1.1's shape: it drops `= request`, never calls `check_task_policy/3`, and silently bypasses both enforcement rules.

Today this is a latent gap, not a live bug: a grep across `lib/` and `test/` finds zero declarations of `task_support`, and `deps/jido_mcp/lib/jido_mcp/server/runtime.ex:10-15` only forwards `description` and `input_schema`, leaving every JidoClaw tool on the struct default (`:forbidden`). No client today sends `params.task`. The patch's two surgical fixes are still load-bearing — `deps/jido_mcp/.../runtime.ex:247-253` still emits JSON Schema via `Jido.Action.Schema.to_json_schema/2`, so the Peri-rescue removal trigger has not been hit.

Goal: re-port the patch against 1.5.0 so the missing enforcement is back, keep both surgical fixes, and add the regression coverage that should have existed from the start so the next bump can't silently drift the same way.

## Approach

### 1. Re-port the handler (`lib/jido_claw/core/anubis_tools_handler_patch.ex`)

Use `deps/anubis_mcp/lib/anubis/server/handlers/tools.ex` (1.5.0, 134 lines) as the new base, then re-apply the two surgical fixes. Concrete edits relative to the current patch file:

- **Both `handle_call/3` heads** — restore the `= request` binding so the whole map is available to the policy check:
  - Head 1: `def handle_call(%{"params" => %{"name" => tool_name, "arguments" => params}} = request, frame, server)`
  - Head 2: `def handle_call(%{"params" => %{"name" => tool_name}} = request, frame, server)`
- **Both `with` chains** — prepend `:ok <- check_task_policy(tool, request, frame),` before the existing `{:ok, params} <- validate_params(...)` step.
- **Add `check_task_policy/3`** as three private clauses, copied verbatim from upstream (the spec comment block above it stays). The clauses are `%Tool{task_support: :required}` + `%Frame{task_id: nil}` → `:method_not_found`; `%Tool{task_support: :forbidden}` + `%{"params" => %{"task" => _}}` → `:method_not_found`; catch-all `_, _, _` → `:ok`.
- **Preserve verbatim** (do not touch): the `rescue _ -> {:ok, params}` clause on `validate_params/3`, the `params = atomize_known_keys(params)` line at the top of `forward_to/4` (handler-less branch), `atomize_known_keys/1`, `safe_to_existing_atom/1`. These are the surgical fixes; the FIX comments stay.
- **Update the file header docstring**: change "Patch for anubis_mcp 1.1.1" → "Patch for anubis_mcp 1.5.0"; mention that `check_task_policy/3` is preserved from upstream, and that the surgical fixes are still required because (i) jido_mcp at commit `7ad146b5` still emits JSON Schema via `Jido.Action.Schema.to_json_schema/2`, and (ii) Jido actions still pattern-match on atom keys.

### 2. Update `mix.exs` patch-inventory comment

The comment block at `mix.exs:14-30` says "anubis_mcp 1.1.1 — patched in `lib/jido_claw/core/`". Update the version pin in that comment to `1.5.0`. No code change to `mix.exs` — comment only.

### 3. Add regression test (`test/jido_claw/core/anubis_tools_handler_patch_test.exs`)

New file. Drives `Anubis.Server.Handlers.Tools.handle_call/3` directly with hand-built request maps, `%Anubis.Server.Frame{}` values, and a stub `server_module` that captures `handle_tool_call/3` invocations. Four cases:

1. **Peri rescue regression** — register a tool whose `validate_input.(params)` raises (mimics jido_mcp's JSON Schema → Peri crash). Assert `handle_call/3` does *not* propagate the raise, that `server.handle_tool_call/3` is invoked, and that the unvalidated params arrive at the handler.
2. **Atomization regression** — call with `%{"params" => %{"name" => "x", "arguments" => %{"path" => "/tmp", "recursive" => true}}}` where `:path` and `:recursive` already exist as atoms in the BEAM. Assert the stub receives `%{path: "/tmp", recursive: true}`. Also include an unknown string key and assert it survives as a string (covers the `safe_to_existing_atom/1` fallback).
3. **`task_support: :required` without `task_id`** — register a tool with `task_support: :required`, build a `%Frame{task_id: nil}`, call `handle_call/3`. Assert `{:error, %Anubis.MCP.Error{code: code} = err, _frame}` where `code` is the `:method_not_found` protocol error code and the message mentions `taskSupport == "required"`.
4. **`task_support: :forbidden` with `params.task`** — register a tool with `task_support: :forbidden` (the struct default, but assert it explicitly), call with a request map that includes `"task" => %{...}` under `"params"`. Assert the same shape of `:method_not_found` error.

Use `Anubis.Server.Component.Tool` to build tool structs and `Anubis.Server.Frame` for frame values (both under `deps/anubis_mcp/lib/anubis/server/`). The stub server module can be a tiny `defmodule` in the test file that implements `handle_tool_call/3` to send the captured args to `self()` for assertion via `assert_received`.

`Anubis.Server.Handlers.get_server_tools/2` returns whatever is in `frame.tools` (a map), so we don't need a real server — building a frame with the tool pre-seeded into `frame.tools` is enough.

## Files

| File | Change |
| --- | --- |
| `lib/jido_claw/core/anubis_tools_handler_patch.ex` | Re-port against 1.5.0: add `check_task_policy/3`, `= request` bindings, `with`-chain step; preserve Peri rescue and `atomize_known_keys/1`; update header docstring version pin. |
| `mix.exs` | Bump `anubis_mcp 1.1.1` → `anubis_mcp 1.5.0` in the patch-inventory comment block (lines 14–30). Comment only. |
| `test/jido_claw/core/anubis_tools_handler_patch_test.exs` | New file. Four regression cases (Peri rescue, atomization, `:required`-without-task_id, `:forbidden`-with-task). |

## Reference points (do not modify)

- `deps/anubis_mcp/lib/anubis/server/handlers/tools.ex` — 1.5.0 upstream, the new base
- `deps/anubis_mcp/lib/anubis/server/component/tool.ex:81-93` — `Tool` struct, `task_support` default is `:forbidden`
- `deps/anubis_mcp/lib/anubis/server/frame.ex:37-57` — `Frame.task_id` field
- `deps/jido_mcp/lib/jido_mcp/server/runtime.ex:247-253` — confirms JSON Schema emission still happens, surgical fixes still required

## Verification

1. `mix compile --warnings-as-errors` — confirms the re-port still satisfies `ignore_module_conflict: true` redefinition and that the new clauses type-check against 1.5.0's `Anubis.MCP.Error`, `Anubis.Server.Component.Tool`, `Anubis.Server.Frame`.
2. `mix test test/jido_claw/core/anubis_tools_handler_patch_test.exs` — all four new cases pass.
3. `mix test` — full suite (1521 tests) stays green; no regression in the existing MCP-related test at `test/jido_claw/mcp_server_test.exs`.
4. Manual smoke: `mix jidoclaw --mcp` should still serve tool calls. Driving an actual MCP client is out of scope, but startup-without-crash plus the regression suite is enough confidence given the latent (not live) nature of the gap.

## Out of scope

- Setting `task_support` on any JidoClaw tool. No tool needs `:required` or `:optional` today; surfacing task-augmentation semantics through `Jido.Action` is a separate feature.
- Re-examining the `jido_shell_*` patches. Their drift against the new `jido_shell` commit (`5d7ecf09` → `7e4060f8`) is entirely doc-block and formatter churn — no functional changes to port.
- Removing the patch entirely. Both removal triggers (Peri-compatible schemas from jido_mcp; upstream `update_env/2` in jido_shell) are still open.
