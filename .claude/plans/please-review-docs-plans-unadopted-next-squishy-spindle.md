# Lua code-mode pair — `lua_query` + `lua_docs` (unadopted-next-ten #3, amber AM-1 + jidoka V2-7)

## Context

Today an MCP client (or the REPL agent) answering a cross-run question pages `workflow_events`, calls `inspect_workflow` per run, and correlates in model context — every intermediate row inflates the transcript. AM-1's borrow collapses that to **one tool call carrying a small Lua script**: filter/join/aggregate run server-side in a sandboxed VM whose only capabilities are explicit read-only host bindings; intermediate rows never leave the sandbox.

The substrate is already in-tree: `lua 1.0.0-rc.3` is a hard transitive dep (`jido_shell` requires `~> 1.0.0-rc.1`, `deps/jido_shell/mix.exs:81`), and `Jido.Tools.LuaEval` (`deps/jido_action/lib/jido_tools/lua_eval.ex`) carries proven hardening but is registered nowhere and can only inject inert `globals:` — no host functions. We **lift its hardening, not delegate to it**. The reach envelope is ported from jidoka (`/Users/rickdunkin/workspace/claws/jidoka` @ `9469dc09`, **Apache-2.0** — attribution comments required): `lib/jidoka/workflow/lua/policy.ex` + `lua/call_trace.ex` + the orchestration shape in `lua.ex`. Amber contributes the pattern only (no code lifted; its repo has no license, which is fine — nothing of amber's is copied).

**Decisions settled with the operator (2026-07-03):**
1. **Names**: tool `lua_query` (module `JidoClaw.Tools.LuaQuery`, amber Path-A's own module name) + `lua_docs` (`JidoClaw.Tools.LuaDocs`) — resolves the README-title (`lua_eval`) vs sketch (LuaQuery) inconsistency; avoids colliding with the dep's generic `lua_eval` action name.
2. **Binding surface — six**: the sketched four (`jido.runs`, `jido.events`, `jido.cases`, `jido.solutions`) **plus** `jido.run(id)` (run detail via `WorkflowView.snapshot/2`) **plus** `jido.output(ref, opts)` (stored tool-output read behind fetch_output's S-M2 scoping).

**Load-bearing correction found during exploration** (recorded at reconciliation): `lua 1.0.0-rc.3` is a **from-scratch pure-Elixir VM, not Luerl** (the AM-1 text says "Luerl" twice; Luerl backed only `lua ≤ 0.x`). The new VM adds deterministic budgets (`max_instructions`, `max_string_bytes`) that LuaEval doesn't use — we wire both as policy caps.

## Design

Two thin tools, four `Tools.Lua.*` support modules, a shared `OutputRef` extraction, and one new `WorkflowView` read:

| Module | Responsibility |
| --- | --- |
| `JidoClaw.Tools.LuaQuery` | `use JidoClaw.Tools.Action, name: "lua_query"` (pipeline: approval-gate → loop-guard → redact → shape → cap, `action.ex:60-80`). Extracts scope from `context[:tool_context]` (workflow_status pattern, **no self MCPScope.wrap**), delegates to `Runner.eval/3`. Schema: `code` (string, required) only — **no cap params** (the model can't raise its own budget). `output_schema: []` (dynamic result, the LuaEval precedent). |
| `JidoClaw.Tools.LuaDocs` | `name: "lua_docs"`. Tenant-agnostic/static: returns `%{bindings: Bindings.docs(), policy: Policy.public(Policy.resolve([])), language_notes: %{...}}`. Optional `binding` string param for drill-down. |
| `Tools.Lua.Policy` | `defstruct` ported verbatim from jidoka `policy.ex` **minus `max_parallel_calls`** (no parallel host calls in our surface — noted in moduledoc) **plus** LuaEval's `max_heap_bytes` and the VM's deterministic budgets. Defaults/clamps: `timeout_ms` 1_500 (100..5_000) · `max_calls` 12 (1..25) · `max_call_depth` 64 (4..256) · `max_script_bytes` 6_000 (256..100_000) · `max_heap_bytes` 64MiB · `max_instructions` 10_000_000 (100_000..100_000_000) · `max_string_bytes` 8MiB (64KiB..32MiB — kept **below `max_heap_bytes`**, the VM docs' own warning, `deps/lua/lib/lua.ex:105`) · `max_result_bytes` 32_768 (4_096..262_144 — the aggregate result bound, see Runner step 7). `resolve/1` (opts → `Application.get_env(:jido_claw, :lua, [])` → defaults, the `opt_or_config` idiom), `validate_script/2` (empty/oversize), `public/1` (operator-facing echo for lua_docs). |
| `Tools.Lua.CallTrace` | jidoka's Agent (reserve/complete/calls) **plus a `refused?/1` flag**: `reserve/4` refusing at budget sets it, so the Runner classifies the resulting abort as `:lua_call_budget_exceeded` **without error-string sniffing**. Records `%{"binding", "arguments", "status", "output"}` where BOTH `arguments` (bounded preview ~200 bytes — script-generated args can approach `max_string_bytes` and the trace returns in the result envelope) and `output` (small summary: count/bytes) are capped, never full data. |
| `Tools.Lua.Bindings` | **The single source** (the `Stage.to_map/1` / G2-1b precedent): a list of `%Bindings.Entry{}` structs (`@enforce_keys [:name, :path, :read_only?, :callback_builder, :signature, :description, :params, :returns, :example]`). `install(lua, scope, trace, policy)` does `Lua.set!` per entry; `docs/0` renders the wire maps lua_docs serves; `assert_read_only!/0` raises unless every entry is read-only (called per eval + pinned by a unit test — the forward-guard for any future write binding, which must be approval-require-listed the day it lands). |
| `Tools.Lua.Runner` | Lifecycle orchestration (below) + Trace/telemetry emission. |
| `Tools.OutputRef` (new, shared) | fetch_output's S-M2 lookup **extracted**: `lookup(ref, tenant_id, tool_context)` = serve-mode discriminator (`session_uuid`-scoped `ToolOutput.by_ref_scoped` unless `serve_mode == :mcp`, else tenant-wide `by_ref`) + system-actor default. `fetch_output.ex` migrates to it and **deletes** its private `lookup/scoped_session/mcp_serve_mode?` (single-source the security discriminator; all call sites migrated, no delegate left — the shared-helper house rule). |

### Bindings (each callback: `CallTrace.reserve` → decode args → validated read → `JsonSafe.encode` → `Lua.encode!` → `CallTrace.complete`)

All reads pass **both `tenant:` and `actor:`** (`Actor.system(tenant_id)` unless context carries one). **Callback contract (review-verified):** every host binding is **arity-2** (`fn args, %Lua{} = state`) and returns `{[encoded], updated_state}` — `Lua.encode!/2` allocates table refs *into* the VM state (`deps/lua/lib/lua.ex:330`, `:919`), so returning an encoded ref without threading the updated `%Lua{}` back hands Lua dangling trefs. Inbound Lua tables decode to `[{string_key, val}]` — port jidoka's `normalize_lua_value/1` (`lua.ex:164-192`: pair-lists→maps, numeric-keyed→arrays); option maps arrive **string-keyed** and get a **fixed-key allowlist translation** to the atom keys the backing fns expect (`"after_seq"` → `:after_seq` etc. — never `String.to_atom` on arbitrary keys). Violations (bad args, missing scope, budget) surface as **raised Lua errors** (jidoka semantics: `{:error, msg, state}` from a callback ⇒ `Lua.RuntimeException`) — but in-script `pcall` catches host errors too (`deps/lua/lib/lua/vm/stdlib.ex:233`), so bad-arg errors are script-recoverable by design while **policy refusals are not swallowable**: the Runner re-checks `CallTrace.refused?/1` after eval and overrides an otherwise-successful result (step 6). Empty results are normal empty tables.

| Lua call | Backing (exact fn) | Notes |
| --- | --- | --- |
| `jido.runs(filter)` | **NEW** `WorkflowView.runs/2` | filter: `status` (string/list, validated against the run enum, default active set), `limit` (clamp 1..50, default 25). Returns `Visibility.run_view(:operator)` maps. Honest errors (`:runs_unavailable`), not the rollup's silent `[]` — the `event_feed` "never a misleading empty page" doctrine. |
| `jido.run(id)` | `WorkflowView.snapshot/2` (`workflow_view.ex:61`) | map incl. `:composer` summary + gate-block; `nil` on not-found. |
| `jido.events(run_id, opts)` | `WorkflowView.event_feed/3` (`workflow_view.ex:115`) | opts `after_seq`/`limit`; already byte-bounded (24KB), JSON-safe, cursor-paged. |
| `jido.cases(filter)` | `AgentCase.pending_for_tenant/1`; `pending_for_run_tree/2` when `run_id` given; `pending_for_session/2` when `session = true` (uses own `session_uuid`) (`agent_case.ex:95,106,107`) | **Explicit `case_view` projection** (fixed field allowlist: id, kind, status, step_name, tool_name, details, session_id, workflow_run_id, decision fields, inserted_at) — NOT whole-struct `JsonSafe.encode`, which is broad and future-field-sensitive; `details` is already operator-safe via `Gate.Presentation`. `limit` clamp 1..50 default 25 via the `query:` code-interface opt (`pending_for_tenant` is unbounded, `agent_case.ex:247`). Never binds `Cases.decide/abandon`. |
| `jido.solutions(query)` | `Solutions.Matcher.find_solutions/2` (`matcher.ex:75-133`) | closes over `workspace_uuid` too (raise clear Lua error if absent); visibility opts copied verbatim from `find_solution.ex`; **lexical-only in v1** — the Matcher may resolve a query embedding via Voyage HTTP under the `:default` workspace policy (`matcher.ex:87`, `embedding_resolver.ex:39`, `voyage.ex:73`), and a "read-only" sandbox binding must not trigger external egress/cost, so the binding passes a **new narrow `resolve_embedding?: false` opt added to `Matcher.find_solutions/2`** (default `true` — existing callers byte-identical; `query_embedding: nil` cannot force it because nil means "resolve via policy", the present-nil trap generalized; exact `by_signature` + FTS/trigram search still work) and its docs entry says so. **New projection map** dropping `embedding`/`search_vector`/`lexical_text`, keeping signature/language/framework/tags/trust_score/sharing/content(≤4KB)/timestamps + `score`/`match_type`. `limit` clamp 1..20, default 5. |
| `jido.output(ref, opts)` | `Tools.OutputRef.lookup/3` → row fields `content`/`byte_size`/`truncated` (`fetch_output.ex:99-111` precedent) | opts: `offset` (bytes, ≥0), `max_bytes` (default 16_384, **clamped to `OutputLimit.max_bytes()`** — a 64KB slice would be leaf-truncated by the wrapper AFTER `returned_bytes`/`clipped` were computed, making the metadata lie: the exact fetch_output self-cap lesson). The slice must be **UTF-8-safe at BOTH ends**: `Generic.valid_utf8_suffix/1` on the start-trimmed side (an `offset` landing mid-codepoint; `generic.ex:84`) then `OutputLimit.valid_utf8_prefix/1` on the end cut (`output_limit.ex:49`). Returns `%{"content", "total_bytes", "offset", "returned_bytes", "clipped", "truncated"}`; `nil` for unknown ref. Script-side grep via Lua `string.*` is the point; paging via `offset`. Inherits S-M2 exactly (only binding with session-scoped reach); stored content is already post-redaction, and the eval result is redacted again on the way out. |

### Runner lifecycle (LuaEval hardening lifted + jidoka orchestration)

1. `Bindings.assert_read_only!()`; `Policy.resolve/validate_script` (no task spawned on refusal).
2. Deadline gate: `context[:__jido_deadline_ms__]` (LuaEval `lua_eval.ex:220-241`) — refuse if past, else `min(timeout_ms, remaining)`.
3. `CallTrace.start_link()` — owned by the tool process (survives task kill; partial audit shows `"started"`), `Agent.stop` in `after`.
4. Unlinked supervised task via **`JidoClaw.TaskSupervisor`** (`application.ex:143`; NOT `Jido.Action.TaskSupervisor`, which isn't started here) + `Process.monitor` + `receive after timeout → Process.exit(pid, :kill)` + bounded drain; **watchdog** process (parent death kills the task — LuaEval `:200-218`).
5. Inside the task: `:erlang.process_flag(:max_heap_size, %{size: bytes/wordsize, kill: true, error_logger: false})`; `Lua.new(sandboxed: default, max_call_depth:, max_instructions:, max_string_bytes:)` (default sandbox strips `io`/`file`/`os.execute|getenv|…`/`package`/`load`/`require`) **then `Lua.sandbox/2` for `[:print]` and `[:debug]`** — the default sandbox does NOT cover them, and `print` writes model-controlled text straight to host `IO.puts` (`deps/lua/lib/lua/vm/stdlib.ex:154`), bypassing the redaction boundary; sandboxed they raise (classified `:lua_runtime_error`) and `lua_docs` language_notes say "print is disabled — return values". Then `Bindings.install/4`; `Lua.eval!`.
6. **Post-eval policy override**: check `CallTrace.refused?(trace)` regardless of eval outcome — in-script `pcall` can swallow the refusal raise (`stdlib.ex:233`) and let the script "complete"; refused ⇒ `:lua_call_budget_exceeded` error envelope even over a successful eval. Subsequent reserves also refuse, so a pcall-looping script does zero further reads.
7. **Aggregate result bound**: normalize return values (jidoka `normalize_lua_value`) → `JsonSafe.encode` → build the success envelope `{:ok, %{"results" => [...], "call_count" => n, "calls" => [compact records]}}` (leaner than jidoka — no script/policy echo; policy lives in lua_docs) → measure `Jason.encode!` bytes **of the final envelope** (results + call_count + calls — the exact term handed to the wrapper, since the call trace rides in it) → over `policy.max_result_bytes` ⇒ `:lua_result_too_large` (guidance: filter/aggregate in-script, page with `after_seq`/`offset`). This bound is load-bearing, not belt-and-suspenders: `OutputLimit` caps **individual string leaves** only (`output_limit.ex:17`) and `OutputShaper` covers only `run_command`/`git_diff`/`mcp_*` (`output_shaper.ex:82`) — nothing else bounds a large structured map/list result.
8. In-flight DB reads on kill: reads run inside the task; DBConnection ownership releases on process death. Tests must therefore run **shared sandbox / `async: false`**.

### Error taxonomy — all non-retryable (`details.retry: false`, `:lua_*` codes outside jido_ai's retryable set; defuses Jido.Exec's retryable-by-default `{:error, map}` wrap; never a `details.reason` key)

| Condition | code |
| --- | --- |
| empty / oversize script | `:lua_empty_script` / `:lua_script_too_large` |
| `Lua.CompilerException` | `:lua_compile_error` |
| `Lua.RuntimeException` (script bug, sandboxed call, depth, instructions) | `:lua_runtime_error` |
| budget refusal (`CallTrace.refused?`, checked **post-eval** so `pcall` can't swallow it) | `:lua_call_budget_exceeded` |
| normalized result over `max_result_bytes` | `:lua_result_too_large` |
| wall-clock kill | `:lua_timeout` — **deliberately non-retryable** (deviation from LuaEval's retryable timeout: same script + same caps re-times-out; message says "do not retry unchanged") |
| deadline already past | `:lua_deadline_exceeded` |
| task killed by heap flag / other exit | `:lua_memory_exceeded` / `:lua_task_exited` |
| missing tenant | bare `{:error, :tenant_required}` — the one **deliberate exception** to the `details.retry: false` rule (workflow_status precedent; pre-execution, cheap, `Error.normalize_result` shapes it) |

Each message is a phrase with actionable guidance (loop-guard envelope house style).

## Files

**New**: `lib/jido_claw/tools/lua_query.ex`, `lua_docs.ex`, `lua/policy.ex`, `lua/call_trace.ex`, `lua/bindings.ex`, `lua/runner.ex`, `lib/jido_claw/tools/output_ref.ex`.

**Modified**:
- `lib/jido_claw/workflow_view.ex` — add public `runs/2` (`{:ok, [map]} | {:error, :tenant_required | :runs_unavailable}`), reusing the `read_runs` query shape + `run_to_map/2`; `build/1` keeps swallow-to-`[]` semantics.
- `lib/jido_claw/solutions/matcher.ex` — narrow `resolve_embedding?: false` opt on `find_solutions/2` (default `true`; existing callers byte-identical — the no-egress seam for the Lua binding).
- `lib/jido_claw/tools/fetch_output.ex` — call `OutputRef.lookup/3`; delete `lookup/3`, `scoped_session/1`, `mcp_serve_mode?/0` (behavior-identical; existing tests must stay green).
- `lib/jido_claw/agent/agent.ex` — append `# Lua code-mode (2)` group: `LuaQuery`, `LuaDocs` (`agent.ex:49` after Handoff).
- `lib/jido_claw/core/mcp_server.ex` — publish both (after `ReplayWorkflow`, `mcp_server.ex:58`) with a comment noting read-only ⇒ not require-listed.
- `lib/jido_claw/core/telemetry.ex` — `emit_lua_eval/3` + `counter("jido_claw.lua_eval.total", tags: [:status, :trigger])` (the `emit_loop_guard` pattern, `telemetry.ex:199-206`).
- `priv/defaults/system_prompt.md` — `## Tool Catalog (33 tools)` → **35**; new `### Lua code-mode (2 tools)` section with `**lua_query**`/`**lua_docs**` entries (enforced by `mix jidoclaw.system_prompt.check`).
- `config/config.exs` — `:lua` block between `:loop_guard` (ends :334) and `:destination_policy`: caps only (incl. `max_string_bytes`, `max_result_bytes`), comment states **no `enabled?` — registration is the switch; clamps make bad values safe; `max_parallel_calls` dropped**. **No test.exs entry** (tests pass explicit opts).
- `test/jido_claw/mcp_server_test.exs` — the hard-coded published-tool count (24, `mcp_server_test.exs:68`) → 26, plus explicit assertions that `LuaQuery`/`LuaDocs` are published.

**Docs (reconciliation — same PR, per the queue's own instruction and the corpus lifecycle rule "reconcile the whole entry")**:
- `docs/exploration/amber/FEATURES-WORTH-BORROWING.md` AM-1: `Status (2026-07-03): ADOPTED — …` above the NOT_ADOPTED line; correct both "Luerl" claims (`:139`, `:198`) to the from-scratch-VM fact + note `max_instructions`/`max_string_bytes` adopted; record deviations (names, six bindings incl. `jido.run`/`jido.output` by operator decision, timeout non-retryable, `max_parallel_calls` dropped, solutions binding lexical-only, engine-side `max_result_bytes` because the wrapper pipeline does NOT bound aggregate structured results); reconcile the Gap paragraph ("no scriptable query surface" now false).
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` V2-7: dated cross-link update — the two borrowed pieces now live as `JidoClaw.Tools.Lua.{Policy, CallTrace}`; the authorship-posture verdict (and `UNADOPTED-IDEAS.md` §2) stays untouched.
- `docs/plans/unadopted-next-ten/README.md` — item 3 heading + table row `✅ DONE 2026-07-03` with a corrections blockquote (item-1 precedent).
- `AGENTS.md` — MCP tool count 24→26 (both mentions) + add the pair to the **Exposed tools** list; "~33 tools" → "~35"; short Key Patterns bullet for the Lua pair.
- `.jido/system_prompt.md` — manual copy of the updated default (AGENTS.md instruction; git-ignored).

## Observability

- Trace: **reuse `:guardrail`** (zero collector edits — a new `:lua` channel would touch the collector's fixed event list + strict tests). One terminal event per eval (`event: :eval`, `status: :completed|:failed`, metadata: guardrail `"lua_query"`, trigger, tenant/session/agent, `script_bytes`, `call_count`, `duration_ms`) + a discrete `:budget_refused` event. Emit Trace + telemetry together (`loop_guard.ex:370-386` pattern).

## Implementation order

1. `Policy` (+ attribution) → `policy_test`. 2. `CallTrace` (+ `refused?`) → `call_trace_test`. 3. `OutputRef` extraction; migrate `fetch_output` (its tests stay green). 4. `WorkflowView.runs/2`. 5. `Matcher` `resolve_embedding?: false` opt → matcher test additions (lands before its consumer). 6. `Bindings` (Entry struct, six callbacks, install/docs/assert) → `bindings_test`. 7. `Runner` → `runner_test`. 8. `Telemetry.emit_lua_eval` + counter. 9. `LuaQuery`/`LuaDocs` → tool tests. 10. Register (agent.ex, mcp_server.ex + its count test, system_prompt count+entries). 11. Config block. 12. Pipeline integration test. 13. Docs reconciliation. 14. Gate.

## Tests

- `test/jido_claw/tools/lua/policy_test.exs` (**async: false** — the config-resolution cases mutate `Application` env; everything else takes explicit opts) — clamps both ends per cap; validate_script; public/1; config resolution.
- `test/jido_claw/tools/lua/call_trace_test.exs` (async) — reserve/complete/calls; refusal at cap+1 sets `refused?`; records omit full output.
- `test/jido_claw/tools/lua/bindings_test.exs` (`TenantCase`, async: false) — read-only invariant (`assert_read_only!` + all-entries check); per-binding arg validation/clamps + string-key→atom fixed-key translation; **two-tenant isolation** (tenant-A script can't read tenant-B runs/cases/solutions/outputs); cases projection = the field allowlist (no raw-struct leakage) + limit clamp; solutions projection drops vector fields AND the binding passes `resolve_embedding?: false` (no embedding resolution/egress; matcher default unchanged); `jido.output` S-M2 (session-scoped non-MCP; tenant-wide under `:mcp` serve-mode env toggle) + UTF-8 safety when `offset` lands mid-codepoint + `max_bytes` ceiling = `OutputLimit.max_bytes()` (metadata never lies).
- `test/jido_claw/tools/lua/runner_test.exs` (async: false) — timeout kill (`while true do end`); heap kill; deadline refusal; compile/runtime envelopes (incl. sandbox: `os.getenv` raises; `print`/`debug` sandboxed post-new → raise, nothing reaches host IO — assert via an UNCAUGHT call, since `pcall` can swallow the raise; the invariant under test is host IO/debug unreachability); budget exhaustion via 13 host calls; **pcall-swallowed refusal still errors** (script wraps the 13th call in `pcall` and returns "ok" → `:lua_call_budget_exceeded` anyway); `:lua_result_too_large` on an oversized structured return (many small strings — the case `OutputLimit` can't bound); `max_instructions` bound; success envelope; kill leaves CallTrace consistent.
- `test/jido_claw/tools/lua_query_test.exs` (async: false) — happy path via `LuaQuery.run(%{code: ...}, %{tool_context: %{tenant_id:, session_uuid:, workspace_uuid:}})`; `:tenant_required`; present-nil trap (`tenant_id: nil`).
- `test/jido_claw/tools/lua_docs_test.exs` (async) — static; `docs == Bindings.docs()` single-source assertion; drill-down param; policy echo.
- `test/jido_claw/solutions/matcher_test.exs` (additions) — the shared opt's contract directly, not only via the Lua binding: default (opt absent / `true`) still resolves embeddings; explicit `resolve_embedding?: false` never invokes the policy resolver/Voyage.
- Pipeline integration (in lua_query_test or separate) — success path: a script returning a secret-shaped string arrives **redacted**; error path: an oversized structured result **errors** with `:lua_result_too_large` (never silently capped — that's the design).
- Auto-swept, no work: marker/approval/capability/prefix-identity sweeps + `system_prompt.check` cover both tools once registered.
- Use `assert match?(pat, x), "msg"`; runner/binding tests need shared sandbox (unlinked task does the DB reads) — call this out in the test file header.

## Verification

1. Targeted: `mix test test/jido_claw/tools/lua test/jido_claw/tools/lua_query_test.exs test/jido_claw/tools/lua_docs_test.exs test/jido_claw/tools/fetch_output_test.exs test/jido_claw/solutions/matcher_test.exs test/jido_claw/mcp_server_test.exs`.
2. **Gate: `mix precommit`** — run bare (no pipes/tail/echo), report exact exit code + test counts verbatim. Known flake: `MemoryExportTest` capture_log race in full suite (memory: not a regression).
3. Optional live canary: `mix jidoclaw`, ask the agent to run a `lua_query` script over `jido.runs`; and a `lua_docs` drill-down.
4. Nothing committed — all changes stay unstaged.

## House-gotcha checklist

- [ ] `details.retry: false` + phrase message + `:lua_*` codes on every runner/policy error (two retry layers, opposite defaults); `:tenant_required` stays a bare atom by deliberate exception (workflow_status precedent).
- [ ] Every host callback is arity-2 and threads the post-`Lua.encode!` VM state back (`{[encoded], updated_state}`) — encode allocates trefs into state.
- [ ] Policy refusals checked post-eval via `CallTrace.refused?` (in-script `pcall` swallows the raise).
- [ ] Fixed-key allowlist translation for string-keyed Lua opts (never `String.to_atom` on script input).
- [ ] `print` and `debug` sandboxed post-`Lua.new` (the default sandbox misses them; `print` egresses model-controlled text to host `IO.puts` un-redacted).
- [ ] `Policy`/`Entry` as defstructs; `# reach:disable-for-this-file fixed_shape_map` (with rationale) only on wire-map files (envelopes, docs, projections) — the `loop_guard.ex:5` precedent.
- [ ] No trivial-forwarder defps; `OutputRef` extraction migrates ALL call sites and deletes fetch_output's originals.
- [ ] `is_binary(x) and x != ""` guards on every tool_context read (present-nil trap).
- [ ] Ash reads carry `tenant:` + `actor:` everywhere.
- [ ] `JsonSafe.encode` before every `Lua.encode!` (raw maps raise "deflua functions must return encoded data").
- [ ] No `Cases.decide/abandon`, no write interfaces anywhere near the binding table.
- [ ] Attribution comments in `Policy`/`CallTrace` moduledocs (jidoka @ 9469dc09, Apache-2.0).
- [ ] `mix format` before gate; credo/reach/dialyzer to zero.
