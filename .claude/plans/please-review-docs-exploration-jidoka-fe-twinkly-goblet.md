# Worker/Sub-Agent MCP Sync + Per-Template Reach-Allowlist

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` tracks features borrowed from jidoka V2. The two headline borrows — **V2-1** (per-tool-call approval gate) and **V2-2** (external MCP tool consumption) — are substantially shipped (both PARTIAL). After reviewing the doc and the code, the highest-value remaining item is **V2-2's headline deferral**: workers can't use external MCP tools, and there's no way to scope external tools per worker class.

**Today's gap** (verified in code): external MCP proxy tools attach **only to the main chat pid** (`lib/jido_claw.ex:121`, `lib/jido_claw/cli/repl.ex:72`). Three+ surfaces that run agent turns get **zero** external MCP tools: spawned workers (`spawn_agent`), follow-up turns (`send_to_agent`), skill-step agents (`agent_runner`), **and handoff-routed chat turns** (the turn runs against a freshly-started, non-tracked worker pid — see correctness note below). Separately, `ServerSpec.templates` (the per-server allowlist field) is **parsed and validated but then discarded** (`lib/jido_claw/mcp/server_spec.ex:12-15` — "parsed only in phase 1").

**Intended outcome**: every agent-turn surface gets its external MCP tools registered before the turn runs, **scoped per template** by a reach-allowlist — a server's config declares which agent templates may reach its tools, so a `researcher` only gets the external tools its class is allowlisted for. Continues the per-template-approval trajectory (the last shipped commit) and is threat-model-aligned (capability scoping per worker class).

## Key design decision: reach, not gating

Per-template control is achieved by **registration filtering (reach)**, not by changing the approval gate. An MCP tool that is never registered onto a worker is withheld from both execution *and* the tool descriptions the LLM sees — strictly stronger and simpler than overloading approval policy. This means:

- **`lib/jido_claw/security/tool_approval.ex` is NOT touched.** The existing `mcp_requirement/2` already gates every `mcp_*` call by the global per-server `require_approval` policy, and the producer fingerprint already includes `agent_template` (template-scoped consent). So the *approval* story for whatever tools a worker does get is already covered. We only add: *which* tools a worker's template gets registered.
- This deliberately sidesteps the `mcp_requirement/2`-resolves-before-the-native-overlay surgery and the fail-open/closed design fork — a finer per-tool **approval overlay** for MCP remains an explicit non-goal (keeps V2-2 honestly PARTIAL on that narrow axis, while closing the bigger gap).

### Allowlist semantics

- A server's `templates: []` (default/absent) ⇒ **all** templates get its tools (back-compat: main keeps everything).
- `templates: ["researcher", "coder"]` ⇒ **only** those templates' agents get its tools. `"main"` is just a nameable template — an operator writes `["main", ...]` to keep the tools on the interactive REPL agent.
- Naturally **fail-closed**: no registration ⇒ no tools. A non-binary/nil template resolves to *unrestricted-only* (servers with empty allowlist).
- **Operator note to document prominently**: the moment any server uses an allowlist, the operator must include `"main"` in it to keep those tools on the interactive agent.

### Confirmed implementation decisions (from design review + user feedback)

1. Key the allowlist map by **module atom**: `module_templates :: %{module() => :all | [String.t()]}`.
2. nil/non-binary template ⇒ **unrestricted-only**. The fallback lives in `modules_for_template/3` (an `is_binary` check), **not** as a guard on the facade — `ensure_attached`'s template arg is typed `term()` (required *position*, not required *binary*), preserving the fallback. Do **not** special-case `nil → "main"` in the tracker fan-out (main isn't tracker-registered; workers always carry a binary template).
3. `ensure_attached(pid, template, timeout)` is **strictly 3-arity (no default timeout)** so the compiler generates no `/2`. This is what actually enforces "no 2-arity shim": with a defaulted timeout, a stale `ensure_attached(pid, 3_000)` would silently bind `3_000` as the *template* (and use the default timeout); strict 3-arity makes that a loud undefined-`/2` error instead. Call sites pass the bounded timeout explicitly (`8_000`, the former default, tunable per path).
4. Keep the `attached` MapSet **pid-keyed** — a pid's template is immutable for its lifetime, so the `:already` fast path stays correct and needs no re-filter.
5. The empty `module_templates` map must travel through **all three** prep-exit sites and the hard-fail `:DOWN` handler.

## Implementation

### 1. `lib/jido_claw/mcp/consumer.ex` (the bulk)

Thread a `module_templates` map alongside the existing `modules`/`policy`:

- **`prepare_server/1`** (~`:363`): normalize `spec.templates` (`[] → :all`, else the list) and return it per server; build the per-server `%{module => allowed}`. Modules are already loaded here (`module.name()` is called at `:370`).
- **`prepare/1`** (~`:342`): accumulate `module_templates` via `Map.merge` (same posture as the `policy` merge at `:359`); return `{modules, policy, module_templates}`.
- **`run_prep/2`** (~`:329`): send `{:prepared, modules, policy, module_templates}`; both rescue/catch sites send `{:prepared, [], %{}, %{}}`.
- **State** (`:70`): add `module_templates: %{}`.
- **`handle_info({:prepared, modules, policy, module_templates}, state)`** (`:146`): store `module_templates`; reply to each waiter with its **filtered** subset; pass through to both fan-outs.
- **New private `modules_for_template(modules, module_templates, template)`**: keep `mod` where `module_templates[mod] == :all` OR (`is_binary(template)` AND `template in module_templates[mod]`).
- **`handle_call({:attach, pid, template}, ...)`** ready branch (`:92`): register `modules_for_template(...)` not `state.modules`.
- **`handle_call({:modules_when_ready, pid, template}, ...)`** (`:104`): add `template` param; ready returns the filtered subset; waiters become `{from, pid, template}` (update the `:prepared` reply loop at `:150` and the `:DOWN`-failure flush at `:188` to the new tuple arity).
- **`fan_out_to_pending`** (`:274`): use the stashed per-pid template (currently ignored: `fn {pid, _template}`) to filter.
- **`fan_out_to_tracked`** + **`tracked_live_pids/0`** (`:282`,`:294`): return `[{pid, template}]` (`entry.template`); register the filtered subset. **Critical:** the already-attached reject at `:284` is currently `Enum.reject(&MapSet.member?(state.attached, &1))` — `&1` is now a `{pid, template}` tuple but `attached` holds pids, so change it to reject on the pid (`fn {pid, _t} -> MapSet.member?(state.attached, pid) end`), and `ensure_monitored` on the pid. Add a one-line comment: main and skill-step workers aren't tracked, so every tracked template is a worker binary; a non-binary falls back to unrestricted-only.
- **Hard-fail `:DOWN` handler** (`:181`): also set `module_templates: %{}`.
- **(Recommended) operator warn-check** in `prepare/1`: warn (don't drop) when an allowlist names an unknown template. Validate each name via `Templates.get/1` (which honors the `:agent_templates_override` test/custom hook, unlike `names/0`/`exists?/1`), and special-case `"main"` so it never false-warns. Mirrors the existing warn-and-skip posture.

### 2. `lib/jido_claw/mcp.ex` (facade)

- `ensure_attached(pid, template, timeout)` — **strictly 3-arity, no default** (so no `/2` is generated; a stale 2-arity call fails loudly rather than binding the timeout as the template). `@spec ensure_attached(pid(), term(), timeout()) :: attach_result()`; **no `is_binary` guard** (accept any term; the binary check is downstream in `modules_for_template/3`). `do_ensure_attached/3` threads `template` into `{:modules_when_ready, pid, template}`.
- `attach_to_agent/2` — unchanged (already carries `template`).

### 3. Call sites — bounded `ensure_attached` before each turn (via an `mcp()` seam)

The bounded path (not fire-and-forget) is required so the turn carries its tools; it blocks only the per-turn task, never the caller or Consumer (mirrors the existing chat path). Each call goes through a per-module `mcp()` seam (see §4) so tests can assert the pid/template passed, and passes the bounded timeout explicitly (`8_000`) since `ensure_attached` is strict 3-arity.

- **`lib/jido_claw.ex` — handoff-routed chat turn (REQUIRED correctness fix).** The `ensure_attached(agent_pid)` at `:121` attaches to the **pre-routing** main pid, but `run_chat_turn/8` resolves the session owner at `:202-212` and runs `ask_sync` against `routed_pid` at `:253`. A handoff worker is a fresh, non-`AgentTracker`-registered pid (`router.ex:382-405`), so tracked fan-out never covers it. **Move the attach out of `chat/4` (`:121`) and into `run_chat_turn/8` right after `resolve_session_owner` returns**: `_ = mcp().ensure_attached(routed_pid, routed_template, 8_000)`. `default_tuple` returns `{pid, "main", ...}` (`router.ex:270`), so the no-handoff case attaches `(main_pid, "main")` exactly as today; a handoff attaches `(reviewer_pid, "reviewer")` — the fix.
- **`lib/jido_claw/tools/spawn_agent.ex`** `start_orchestration` task (after `attach_orchestrator`, before `SubagentTranscript.run`): `_ = mcp().ensure_attached(subagent_pid, template_name, 8_000)` (`template_name` already in scope).
- **`lib/jido_claw/tools/send_to_agent.ex`**: thread `entry.template` into `dispatch` as a `template_name` param; in the task before `SubagentTranscript.run`: `_ = mcp().ensure_attached(pid, template_name, 8_000)`.
- **`lib/jido_claw/skills/steps/agent_runner.ex`** `run/4` (after `start_subagent` success, before `run_step`): `_ = mcp().ensure_attached(pid, template_name, 8_000)`. (Skill-steps are single-shot — a `:partial`/`:skipped` here is tool-less for that step, still strictly better than today's zero tools.)

### 4. MCP test seam in the four call-site modules

Add `defp mcp, do: Application.get_env(:jido_claw, :mcp_facade, JidoClaw.MCP)` to `lib/jido_claw.ex`, `spawn_agent.ex`, `send_to_agent.ex`, `agent_runner.ex` — idiomatic (these modules already use the same `Application.get_env` seam for `jido_runtime`/`agent_tracker`/`templates`/`step_agent_server`). Lets call-site tests assert the *right pid/template* is passed (the Consumer is off in the default test env, so a direct call only yields `:skipped`).

### 5. `lib/jido_claw/mcp/endpoint_config.ex` — tighten allowlist parsing

`validate_templates/1` (`:132-139`) currently accepts empty-string elements. Match `require_approval`'s non-empty-string posture: `Enum.all?(list, &(is_binary(&1) and &1 != ""))` — an empty string in an allowlist is a silent "allowlisted to nobody" footgun. Add a parse test for it.

## Test plan

Filtering must be proven at the **Consumer unit level** (Consumer is off in most of the suite). Extend `test/jido_claw/mcp/consumer_test.exs` using its existing harness (`stub(%{list_tools: …})`, `start_consumer!`, `start_agent!`, `has_tool?`, `assert_eventually`). The existing `@server` has no `templates:` key ⇒ parses to `:all` ⇒ **all existing tests stay green by construction** (back-compat proof). Update the existing `ensure_attached(agent, <timeout>)` calls (`:150,:161,:172,:187,:199,:218,:267`) to the 3-arity `ensure_attached(agent, "main", <timeout>)`.

New `describe "per-template reach"`:

1. **Empty allowlist ⇒ all templates** (back-compat): two agents, different templates, both get the tool.
2. **Restricted ⇒ only listed**: server `templates: ["coder"]`; `ensure_attached(coder, "coder")` ⇒ tool present; `ensure_attached(other, "researcher")` ⇒ returns `:ok` (empty filtered set registers vacuously and marks attached) **but `refute has_tool?`** — assert the `:ok`-vs-`has_tool?` distinction explicitly with a comment.
3. **Fire-and-forget path** (`attach_to_agent`) respects the allowlist (exercises the `pending` template threading + ready-branch filter).
4. **Deferred (`:preparing`) attach lands filtered** (pin prep with `blocking_list_tools`; exercises `fan_out_to_pending` using the now-used stashed template).
5. **Union: one `:all` server + one restricted server, same pid** — coder gets both, researcher gets only the unrestricted one. The key behavioral guarantee.
6. **Tracked fan-out filtering** on `:prepared` rehydrate — the Consumer reads the **globally-named** `JidoClaw.AgentTracker` (`consumer.ex:295`), so use **that running singleton**, not a second tracker. Snapshot or `AgentTracker.reset/0` (`:245`) its state in `setup`/`on_exit` so rehydrate assertions don't pick up stale tracked entries; `register/5` two live pids with templates `"coder"`/`"researcher"`; assert each gets its allowed subset and that already-attached pids are correctly skipped (the `:284` pid-membership fix).
7. **`:already` invariance** — second `ensure_attached(pid, same_template)` ⇒ `:already`, tool set unchanged.

Call-site (with the seam, configuring `:mcp_facade` to a stub that records calls): assert each path calls `ensure_attached` with the correct pid/template; plus non-regression — orchestration completes when the facade returns `:skipped`. Specifically extend `handoff_dispatcher_integration_test` (or the nearest handoff/chat test) to assert the **routed** pid/template is what's attached — e.g. a `"reviewer"` handoff attaches the reviewer worker pid under `"reviewer"`, not the main pid. In `endpoint_config_test.exs`, add **both** the empty-string `templates` rejection test **and** a positive assertion that `templates: ["main", "coder"]` is carried through onto the `ServerSpec` — lock the valid surface, not just the invalid case.

## Docs to update

- `lib/jido_claw/mcp/server_spec.ex` moduledoc (`:12-15`): `templates` is now an **enforced reach-allowlist** (`[]`/absent ⇒ all; a list ⇒ only those templates; `"main"` nameable; enforcement by registration filtering, stronger than gating) — drop "parsed only in phase 1".
- `AGENTS.md` (MCP consumption section, ~`:87`): move "per-template allowlist enforcement" and "worker/sub-agent sync" from Deferred to shipped; one sentence on the reach-allowlist keyed by `:agent_template` (covering spawn / follow-up / skill-step / handoff-routed turns) and the "include `main`" operator note.
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` V2-2 status (`:52-54`): dated note moving both items to shipped; clarify the mechanism is per-template **allowlisting via reach (registration)**, not via the approval path — so the "resolves before the native template overlay" caveat is no longer read as "still impossible". Touch the V2-1 cross-ref (`:44`) if needed.

## Verification

End-to-end:

1. `mix jidoclaw.compile_check` clean (the repo's allowlisted strict-compile task — not raw `mix compile --warnings-as-errors`).
2. `mix test test/jido_claw/mcp/consumer_test.exs` — new per-template describe + updated existing calls all green.
3. Targeted: `mix test test/jido_claw/mcp/ test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/skills/` + the handoff/chat integration test (non-regression + routed-attach assertion).
4. Manual (optional, via Tidewave `project_eval`): start a `Consumer` with a stub client and two servers (one `:all`, one `templates: ["coder"]`), `ensure_attached` two agents under different templates, assert `Jido.AI.has_tool?` reflects the allowlist.
5. **`mix precommit` must pass** (the completion bar): `jidoclaw.compile_check` (zero non-allowlisted warnings) → `system_prompt.check` (unaffected — MCP proxies are runtime tools, not static template tools) → `deps.unlock --unused` → `format --check-formatted` → `reach.check --arch --smells --strict` (mind `fixed_shape_map`/`bare_rescue` — the Consumer already file-disables `bare_rescue`; `module_templates` is a dynamic map, not a fixed-shape struct) → `credo --strict` → `dialyzer` (correct `@spec`s for `ensure_attached/3` with `term()` template, `modules_for_template/3`, the widened `:prepared` message) → `test`. Run full `mix precommit`; do not pipe through `tail` (credo/reach string-building findings hide). Nothing committed — leave everything unstaged.

## Out of scope (explicit non-goals)

- Per-tool **approval overlay** for MCP (finer than per-server `require_approval`, additive gating via `tool_approval.ex`) — the reach-allowlist supersedes its primary use; keeps V2-2 PARTIAL on that narrow axis.
- Individual-tool (vs per-server) allowlist granularity — `ServerSpec.templates` is per-server; per-tool is a future refinement.
- Generic MCP output shaping, reconnect/auto-re-prep — unrelated V2-2 deferrals.
