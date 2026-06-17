# Fix: MCP domain `isError: true` results bypass generic shaping on the live path

## Context

The just-shipped "Generic MCP output shaping" feature (plan
`.claude/plans/shimmering-humming-turing.md`) gives oversized external-MCP results a
reversible, collapse-and-extract shaping path with the spec-standard `isError` flag
**lifted** onto the wrapper (the model's only failure signal) and the full payload stored
under a `fetch_output` ref. A code review found one P1 gap, which I validated against the
dependency source:

**The most important MCP case — a domain `isError: true` result — never reaches the shaper.**

End-to-end trace (all confirmed):

1. `Jido.MCP.call_tool/4` does **not** return an `isError: true` result as a success. Per
   `deps/jido_mcp/lib/jido_mcp/response.ex:27-39`, it inspects `MCPResponse.error?/1` and
   **promotes the domain error** to
   `{:error, %{status: :error, method: "tools/call", type: :tool_error, message: ..., details: <raw result map incl "isError" => true>}}`.
   (A genuine transport/protocol error instead gets `type: :transport`/`:protocol`/`:validation`
   via the `{:error, reason}` clause at `response.ex:52-62` — only domain `isError` yields
   `type: :tool_error`, and only that case carries the raw result map in `details`.)
2. `JidoClaw.MCP.Client.Live.normalize_call/1` passes `{:error, _}` through unchanged
   (`lib/jido_claw/mcp/client/live.ex:59`).
3. The generated proxy's `run/2` passes it through as `{:error, error}`
   (`lib/jido_claw/mcp/proxy_generator.ex:245`).
4. In the `Tools.Action` pipeline (`lib/jido_claw/tools/action.ex:60-63`), `Error.normalize`
   runs **before** the shaper and rewrites it into
   `{:error, %{code: :error, message: <2KB inspect>, details: %{context: %{... details: %{"content"=>..., "isError"=>true}}}}}`
   — burying the content and `isError` several levels deep.
5. `OutputShaper.shape_result` routes to `safe_shape_mcp/3` (the name is `mcp_`-rooted), but
   `do_shape_mcp/3` only matches `{:ok, data}` / `{:ok, data, effects}`
   (`lib/jido_claw/tools/output_shaper.ex:322-327`) — the `{:error, ...}` falls to the
   `do_shape_mcp(other, …) -> other` passthrough, **unshaped**.
6. `OutputLimit.truncate_result` then walks the nested map/list and head-cuts the big
   `text` string at 32 KB **ref-less, dropping the tail where the error detail lives**
   (`lib/jido_claw/tools/output_limit.ex:17-34`).

Net effect: for the headline failure case, `isError` is buried (not lifted), the error
detail's tail is silently dropped, and there is no `fetch_output` recovery ref — exactly the
opposite of the advertised behavior. The new integration test
(`test/jido_claw/tools/output_shaper_test.exs:952-957`) stubs `isError: true` as
`{:ok, data}`, which never goes through the dep's `{:error, %{type: :tool_error}}` promotion,
so the suite is green while production is broken.

## Approach (recommended)

**Re-surface the dep's domain-error promotion back to `{:ok, data}` at the proxy boundary**,
before `Error.normalize` can mangle it. Then the existing `{:ok, data}` → `shape_mcp_payload/3`
path handles everything with **no shaper changes**: over-cap → collapse + lift `isError` +
ref-store; under-cap → structured passthrough so the model sees the full result map (with its
`isError` flag) as data.

Why the proxy and not elsewhere:

- **Not the shaper.** By the time the result reaches `safe_shape_mcp/3`, `Error.normalize` has
  already wrapped it in a normalize-specific nested shape; reconstructing the original result
  from `details.context.details` would couple the shaper to `Error.normalize`'s internals and
  is fragile. The pipeline order (`Error.normalize` before `shape`) is load-bearing and not
  worth reordering.
- **Not `Client.Live`.** The proxy is the LLM-facing adapter; "domain errors reach the model as
  data so it can reason about them" is an LLM-specific policy. Keeping it in the proxy lets
  `Client.Live` stay a faithful adapter of the dep's semantics (a domain error is still
  `{:error, %{type: :tool_error}}` for any non-LLM caller), and — decisively — the proxy is the
  **only** consumer of `JidoClaw.MCP.client()`, which in tests resolves to
  `JidoClaw.MCP.Client.Stub` (`config/test.exs:31`). A clause in the proxy is exercised by the
  existing stub-based tests; a clause in `Client.Live.normalize_call/1` would be bypassed by the
  stub (the stub replaces the whole client module).

Why re-surfacing is safe and design-consistent (both confirmed in `deps/jido_ai`):

- jido_ai has **zero** `isError` handling and feeds both `{:ok, data}` and `{:error, reason}`
  to the model as a JSON tool-result message; the ReAct loop continues either way (no halt, no
  turn-failure). The only divergence is retry, and a `:tool_error`/`:error`-coded result is
  non-retryable anyway — so control flow is unchanged.
- The documented design already says `isError` is "the model's only failure signal" and the
  shaper "lifts isError onto the wrapper" returned as `{:ok, …}`. Surfacing the domain result
  as `{:ok, data}` is exactly what that design assumes.

## Changes

### 1. `lib/jido_claw/mcp/proxy_generator.ex` (the fix)

In `create_proxy_module/6`'s quoted `run/2` `case` (currently `:243-247`), add a clause for the
dep's domain-error promotion, ordered **before** the existing `{:error, error}` catch-all:

```elixir
case JidoClaw.MCP.client().call_tool(@endpoint_id, @remote_tool_name, scrubbed) do
  {:ok, data} ->
    {:ok, data}

  # jido_mcp promotes a domain `isError: true` result (a *successful* MCP
  # response carrying a tool-execution error flag, per spec) to
  # `{:error, %{type: :tool_error, details: <raw result map>}}`. Re-surface it
  # as `{:ok, data}` so the result (incl. `isError`) reaches the generic MCP
  # shaper (isError lifted + reversible fetch_output ref) and the model as data
  # — its only failure signal — instead of being mangled by `Error.normalize`
  # and ref-lessly head-cut by `OutputLimit`. Matching `"isError" => true` in
  # `details` (not just `type: :tool_error`) documents the MCP domain-error
  # contract in code: any `:tool_error` lacking it, plus genuine
  # transport/protocol errors, stay `{:error, _}`.
  {:error, %{type: :tool_error, details: %{"isError" => true} = data}} ->
    {:ok, data}

  {:error, error} ->
    {:error, error}

  other ->
    {:error, {:unexpected_proxy_response, other}}
end
```

The tighter `%{"isError" => true} = data` match is **production-equivalent** to matching
`type: :tool_error` alone — the dep emits `:tool_error` only when `MCPResponse.error?/1` matches
`is_error: true` exactly (`deps/anubis_mcp/lib/anubis/mcp/response.ex`), i.e. only when the raw
result carries `"isError" => true`. It loses nothing today and guards any future/test-only
`:tool_error` value that lacks the `isError` contract from being wrongly re-surfaced.

Also update the moduledoc claim at `:8-10` ("The proxy `run/2` only adds **outbound arg
scrubbing** and returns `{:ok, data}`") to note the domain-error re-surfacing. Keep comment
lines short to avoid the ExSlop step-comment-wrap trap (no wrapped line beginning with the word
"step"); this is a pattern-match destructure, so no `fixed_shape_map` smell.

### 2. `test/jido_claw/tools/output_shaper_test.exs` (make the integration test faithful)

In the "generated proxy integration" test (`:944-984`), change the stub return value from
`{:ok, %{"content" => [%{"text" => big}], "isError" => true}}` to the **production shape**:

```elixir
{:error, %{type: :tool_error, details: %{"content" => [%{"text" => big}], "isError" => true}}}
```

All existing assertions stay valid and now exercise the real error→data→shape path:
`result.shaped`, `result["isError"] == true`, `result.output_ref =~ ~r/^out_/`,
`byte_size(result.output) <= 4_096`, and the `ToolOutput.by_ref` round-trip with
`row.content =~ "TAILMARK"`. The outbound-ANSI-scrub assertion is unaffected (the stub still
`send`s `{:stub_call, …}` before returning). Reword the test name/comment to say it stubs the
dep's `:tool_error` promotion. Without the §1 fix this test fails (`module.run` returns
`{:error, …}`, so `assert {:ok, result}` breaks) — so it genuinely guards the fix.

The inline `McpEcho`/`run_mcp` shaper tests (`:629-928`) are **unchanged**: they test the
shaper's `{:ok, data}` handling directly, which remains correct (the "error results pass
through" test at `:809-817` still holds — genuine errors are never re-surfaced).

### 3. `test/jido_claw/mcp/proxy_generator_test.exs` (pin the re-surfacing semantics)

Add a `describe "domain error re-surfacing"` block with two focused tests, reusing the existing
`stub/1`, `tool/1`, `build_one/1` helpers and a no-tenant `%{}` context (so the shaper is a
no-op and the assertion isolates the proxy's behavior):

- **domain `:tool_error` → `{:ok, data}`**: stub returns
  `{:error, %{type: :tool_error, details: data}}` for a small benign `data`
  (e.g. `%{"content" => [%{"text" => "boom detail"}], "isError" => true}`); assert
  `{:ok, ^data} = module.run(%{}, %{})`.
- **non-domain error stays `{:error, _}`**: stub returns
  `{:error, %{type: :transport, message: "server down"}}`; assert
  `{:error, error} = module.run(%{}, %{})` and `error.message =~ "server down"` — proving only
  `:tool_error` is re-surfaced and transport/protocol/validation errors remain errors.
- **`:tool_error` lacking the `isError` contract stays `{:error, _}`**: stub returns
  `{:error, %{type: :tool_error, details: %{"note" => "no isError key"}}}`; assert
  `{:error, _} = module.run(%{}, %{})` — proving the tighter `%{"isError" => true}` match only
  re-surfaces payloads actually carrying the MCP domain-error contract.

### 4. Docs

- `lib/jido_claw/tools/output_shaper.ex` — add one line to the "External MCP tools" moduledoc
  section (`:38-53`) noting that domain `isError: true` results arrive **re-surfaced to
  `{:ok, data}` by the proxy**, so they hit this path (clarifies why the shaper only matches
  `{:ok, data}`).
- `AGENTS.md` — in the "External MCP Tool Consumption" bullet, note that the proxy re-surfaces
  jido_mcp's `:tool_error` (domain `isError`) promotion to `{:ok, data}` so the failure case is
  shaped + `isError`-lifted + ref-stored rather than mangled to a wire-error.
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` (already modified) — optional: append
  a dated note (2026-06-17) that the live `isError` path was fixed as a follow-up.

## Critical files

- `lib/jido_claw/mcp/proxy_generator.ex` — the fix (quoted `run/2` `case`) + moduledoc.
- `test/jido_claw/tools/output_shaper_test.exs` — faithful integration test.
- `test/jido_claw/mcp/proxy_generator_test.exs` — re-surfacing unit tests.
- `lib/jido_claw/tools/output_shaper.ex`, `AGENTS.md` — doc updates.
- Reference (read-only, reused as-is): `lib/jido_claw/tools/output_shaper.ex`
  (`shape_mcp_payload/3`, `mcp_is_error/1`, `safe_shape_mcp/3`), `lib/jido_claw/tools/error.ex`,
  `lib/jido_claw/tools/output_limit.ex`, `deps/jido_mcp/lib/jido_mcp/response.ex`.

## Verification

Toolchain is `mise exec -- mix`. Run gate commands **bare** (never piped to `tail` — a pipe
masks the exit code); run the full gate in the background and read the output tail.

1. `mise exec -- mix test test/jido_claw/tools/output_shaper_test.exs test/jido_claw/mcp/proxy_generator_test.exs`
   — the two directly-touched suites.
2. `mise exec -- mix test test/jido_claw/tools/ test/jido_claw/mcp/` — neighbouring suites
   (confirms no regression in shaper/consumer/client_live/Forge).
3. **`mise exec -- mix precommit`** — the completion bar: `jidoclaw.compile_check` (zero
   warnings + allowlist), `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`,
   full suite. (The separate Stop-hook `compile --warnings-as-errors` always fails on the two
   intentional `pull_request_coordinator` warnings — not this change; `compile_check`/`precommit`
   are the real gates and tolerate them.)
4. Optional Tidewave `project_eval`: build a proxy via `ProxyGenerator.build_modules/3` with a
   stub returning `{:error, %{type: :tool_error, details: <oversized map incl "isError" => true>}}`
   and tenant context; confirm `module.run/2` yields a `%{"isError" => true, output:, shaped: true,
   output_ref:}` wrapper that `ToolOutput.by_ref` round-trips.

## Out of scope (deliberate)

- Mirroring the re-surfacing into `Client.Live` (the proxy is the only `client/0` consumer and
  the LLM-policy boundary; duplicating would be redundant and untested).
- Teaching the shaper to reconstruct the original result from a normalized `{:error, …}`
  (fragile coupling to `Error.normalize` internals).
- Any change to genuine transport/protocol/validation error handling — those correctly remain
  `{:error, _}`.
