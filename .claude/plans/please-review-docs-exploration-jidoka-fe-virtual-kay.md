# Plan: V2-2 — External MCP Tool Consumption

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` inventories capabilities worth borrowing from jidoka V2. Against the current code:

- **V2-1 (the per-tool-call approval gate — the headline borrow) is fully shipped and wired** (commit `7fa62675`). It's PARTIAL only for explicitly-deprioritized deferrals, one of which is **default-on approval for external MCP tools — part of V2-2**.
- **V2-2 (external MCP tool consumption) is the doc's explicit next item** (Sequencing §2), unblocked now that V2-1 shipped. Everything else (V2-3…V2-6) is "opportunistic"; V2-7 is "watch, don't build."

The platform *serves* MCP (22 tools) but agents cannot *consume* external MCP servers — every capability is a hand-written `Jido.Action`. This change lets the operator declare external MCP servers in `.jido/config.yaml`; their tools are discovered, wrapped in jido_radclaw's full safety pipeline, and exposed to the LLM alongside native tools.

**The entire transport/client stack already ships** in `deps/jido_mcp` (`ClientPool`, stdio/SSE/HTTP, `Jido.MCP.list_tools/2`, `call_tool/4`, `register_endpoint/1`) — auto-started but referenced nowhere in app code. The work is **wiring + trust policy**.

**Critical gotcha:** the dep's `Jido.MCP.JidoAI.ProxyGenerator` emits proxies that `use Jido.Action` and return remote data **raw** (`proxy_generator.ex:104-107`), bypassing every jido_radclaw safety concern. **We generate our own proxies that `use JidoClaw.Tools.Action`**, so the safety pipeline applies automatically.

### Decisions locked (user)

1. **Implement V2-2.**
2. **Gate external MCP tools by default** — each external tool requires approval unless its server is explicitly trusted (`require_approval: false`); per-server setting overrides the global default.
3. **Transport-agnostic**; verify against a self-consume loopback.

### Revisions from two review rounds (all findings addressed)

Round 1: stdio env hygiene; collision-proof tool names; non-blocking attach; corrected shaping claim (redacted+capped, not shaped); exact-name approval policy; `enabled?: true` in gate tests; live-tool inspection; explicit `schema: Zoi.map()`.

Round 2:
- **[P1] `env: %{}` does NOT default-deny** — `Port.open` `{:env}` overlays, doesn't replace, and the dep can't express `false` unsets. → patch `Jido.MCP.Transport.STDIO` to build `:env` via the project's existing `Env.scrubbed_port_env/1` (Trust Boundary §1).
- **[P1] approval can fail OPEN** if `:persistent_term` is lost while `mcp_*` modules remain registered. → unknown `mcp_`-prefixed names fall back to the **global default (gated)**, never native; exact `false` is the only ungate path.
- **[P2] attach still blocks in `:ready`** (`register_tool`/`has_tool?` are AgentServer calls). → all registration runs in short-lived **bounded Tasks** off the Consumer process.
- **[P2] `Jido.AI.list_tools/1` returns `{:ok, tools}`** (not a bare list); `has_tool?/2` returns `{:ok, bool}`. → fix the inspection snippet and assert `{:ok, true} = …` in tests.
- **[P2] tool names/descriptions are prompt-trusted pre-call** (`tool_adapter.ex:140`). → sanitize/cap descriptions; document configured servers as trusted for prompt metadata (Trust Boundary §2).

Round 3: default `client_info` for `Endpoint.new/2`; tolerate `{:endpoint_already_registered, _}` on Consumer restart; explicit `mcp_requirement` clauses (fix the `&&/||` footgun — global `false` is also an ungate path); `OutputLimit` is prefix-cap (not head/tail); registration tasks via `JidoClaw.TaskSupervisor`.

Round 4: registration is **fire-and-forget** supervised (`Task.Supervisor.start_child`) with bounded `register_tool(timeout:)` — the Consumer never `Task.yield`s in a callback; reserve the hash suffix room *before* the 64-char name cap; stdio `cwd` support (the scrubbed self-consume child reloads `.env` from its cwd).

Round 5: per-module `try/catch :exit` in `register_modules` (a dead/slow agent call warn-logs and continues — no silent partial registration); rehydrate live agents from `AgentTracker.get_state/1` after prep (Consumer-restart tolerance); align the `EndpointConfig.parse/1` test note to the `{specs, warnings}` batch contract.

Round 6: split stdio `command` list → `command` (string) + `args` (`stdio.ex:26`); add bounded **`ensure_attached/2`** for the request path (Consumer defers the reply to waiting callers until prep completes — never blocks itself — caller registers, so a fresh session's first turn has its tools), keeping `attach_to_agent` fire-and-forget for boot/restart; narrow the rehydrate claim (AgentTracker covers REPL/spawned, chat agents use `ensure_attached`); make `requirement/3` map `:gated→:mcp_external` / `:trusted→nil` / `:not_external→native` explicitly.

Round 7: call `ensure_attached` on the chat request path for **every** resolved pid (covers existing chat agents, not just fresh), idempotent via an `attached` fast-path (`:already`); flush `waiters` with `{:ok, []}` if prep dies before `{:prepared}`; filter rehydrate to `status==:running` + `Process.alive?` (`AgentTracker` retains terminal entries, `agent_tracker.ex:213`).

Round 8: real provider schema via `JsonSchemaBridge.to_zoi/1` (`Zoi.map()` would advertise *no args* — `ToolAdapter` forces `additionalProperties:false`, `tool_adapter.ex:274`); enforce an `mcp_` root on every generated name (a custom prefix would break the fail-closed fallback); start the Consumer after `AgentTracker` (`:268`) + guard the rehydrate read; `register_modules` returns `:ok`/`:partial`, marking `attached` only on full success; hard 200-tool cap (warned); definition-complete module hash incl. schema digest; accept both stdio `command` shapes; explicit `native_requirement` clauses (no `&&/||`).

Round 9: schema is **JSON-Schema pass-through** (remote `inputSchema` used directly as `schema:`, `schema.ex:11`) not `to_zoi` (which rejects `oneOf`/`$defs` → no-args); crash waiter-flush replies `{:error, :mcp_unavailable}` (≠ success-empty `{:ok, []}`, so a failed prep isn't marked attached); drop `prefix` from `ServerSpec` (always-derived); document the `strict: true` → `additionalProperties:false` narrowing of dynamic-object args.

Round 10: remove the stale `{:ok, []}` waiter-flush test line (crash ⇒ `{:error, :mcp_unavailable}`, success-empty ⇒ `{:ok, []}`); make the 200-tool cap a **deterministic** first-N-by-sorted-name with dropped count+names warned (vs the dep failing the whole sync); add a dynamic-object-schema narrowing test.

No new Ash resources (reviewer confirmed reusing `AgentCase`/`ToolApprovals` is idiomatic).

---

## Architecture

Two responsibilities, split (no agent exists at boot — REPL starts one lazily `id: "main"` at `cli/repl.ex:67`; chat path one per `session_id` at `jido_claw.ex:165`):

1. **Boot prep — `JidoClaw.MCP.Consumer` (GenServer):** `init/1` returns immediately and spawns a **separate, crash-isolated prep process** (so the GenServer mailbox stays free). Prep (best-effort, internally rescued): read config → register endpoints → await ready (bounded) → discover tools (bounded) → compile safe proxy modules → message `{:prepared, modules, policy}`. The Consumer then publishes the per-server approval policy to `:persistent_term`, caches the module list, flips to `:ready`.
2. **Attach — two paths, both keeping the Consumer non-blocking:**
   - **`attach_to_agent(pid, template)` (fire-and-forget — boot/restart):** a `GenServer.call` that records the pid, replies **instantly**, and registers in a **fire-and-forget supervised task** (`Task.Supervisor.start_child(JidoClaw.TaskSupervisor, …)`, never `Task.yield` in a callback) doing bounded `register_tool/3` (idempotent via `has_tool?/2`, per-module `try/catch :exit`, warn-log). Used at REPL boot (natural delay before the first prompt) and the `:prepared`/restart rehydrate fan-out.
   - **`ensure_attached(pid, timeout)` (bounded — request path):** a fresh chat session's first turn must already have its tools. The Consumer answers `:modules_when_ready` **immediately if `:ready`, else defers the reply** (stashes `from`, replies on `:prepared`) — the *caller* waits (bounded by its call timeout), the Consumer never does. On `{:ok, modules}` the caller registers them onto `pid` (bounded, idempotent, per-module `try/catch :exit`) and marks `attached` only if all confirmed; on `{:error, :mcp_unavailable}` (prep crashed) it proceeds tool-less without marking, so a later turn retries. A slow agent ties up only that request. Called on the chat request path for **every** resolved pid (fresh *or* existing — chat agents aren't in `AgentTracker`), so it's steady-state-cheap: the Consumer fast-returns `:already` for a pid it has confirmed `attached`, so only a pid's first turn does registration work.

**Safety inheritance (the payoff):** the generated proxy `run/2` returns `{:ok, data}` and the module does `use JidoClaw.Tools.Action`, so the wrapper (`tools/action.ex:49-65`) automatically applies, around it: `ToolApproval.gate → Error.normalize → OutputRedaction.redact_result → OutputLimit.truncate_result`, inside `MCPScope.wrap`, stamping the three `__jidoclaw_tool_*__` markers. Inbound results are **redacted and capped** with no extra code. The proxy adds only **outbound arg scrubbing**.

> **Shaping caveat (corrected):** format-aware *shaping* with reversible `fetch_output` storage is allowlisted to `run_command`/`git_diff` only (`OutputShaper.@shapeable_tools`, `output_shaper.ex:59`). External MCP output is **not** reversibly stored in phase 1: an oversized result is **prefix-capped** by `OutputLimit` (UTF-8-safe prefix + truncation marker, `output_limit.ex:17`) and the truncated remainder is not retrievable. Generic MCP shaping is deferred.

**Approval default (exact-name + fail-closed prefix fallback):** the Consumer publishes `%{exact_tool_name => true|false|nil}` to `:persistent_term`. `ToolApproval.requirement/3` resolves:
- exact `true` ⇒ gated; exact `false` ⇒ trusted; exact `nil` ⇒ global `mcp_require_approval` default. **Ungate paths: exact `false` OR global `mcp_require_approval: false`.**
- **not in map but name is `mcp_`-prefixed ⇒ global default** — never treated as native — so a lost/reset `:persistent_term` (Consumer restart, failed prep) falls back to the global posture (gated by default) rather than silently ungating to native.
- not in map and not `mcp_`-prefixed ⇒ native tool (existing `require`/`require_patterns` logic).

This reuses the entire durable-approval machinery (run-less `AgentCase`, canonical fingerprint, `/gates`, `/approvals`) and avoids the prefix-overlap problem (exact overrides win; the prefix is only a fail-safe applying the global default, no per-server discrimination needed in that degraded state).

---

## Trust boundary

Two things sit **outside** the per-call approval axis — `require_approval` gates tool *calls*, not these.

### 1. stdio subprocess environment (the corrected trapdoor)

`.env` secrets are loaded into `System` env at boot (`application.ex:431-456`). `Port.open`'s `{:env, …}` **overlays/unsets specific vars — it does not replace the inherited env** — so the dep's stdio transport leaks the full host env: `maybe_put_env(opts, nil)` adds no `:env` (full inheritance), and even an explicit map goes through `normalize_env_for_erlang` (`stdio.ex:256-260`) which `to_charlist`s values (can't express a `false` unset) and only *merges* keys. Setting endpoint `env: %{}` does **not** default-deny.

**Fix — reuse the project's existing subprocess-scrub.** `JidoClaw.Security.Redaction.Env.scrubbed_port_env/1` (`env.ex:184`) returns the correct `Port.open` `:env` list: it walks `System.get_env()` and emits `{key, false}` to **unset** every non-inheritable var (secrets), keeps the inheritable allowlist (PATH/HOME/locale/proxy-without-creds), and applies caller overrides. It already backs every spawn site: `shell/backend_host.ex:132`, `forge/runner/host_shell.ex:216`, `forge/sandbox/docker.ex:182`, `core/os_cmd.ex:107`.

The dep hardcodes `Jido.MCP.Transport.STDIO` by transport type (no per-endpoint module override), so apply the scrub via the project's **established dependency-patch pattern**: a patched `Jido.MCP.Transport.STDIO` (faithful copy whose **only** change is building `:env` via `Env.scrubbed_port_env(state.env || %{})`), registered in `DependencyPatches.@patched_modules` (`core/dependency_patches.ex:4-9` — alongside the existing Anubis + 3 `Jido.Shell.*` patches; `ignore_module_conflict: true` already set). The endpoint `env:` map becomes the operator **override** set (default `%{}` ⇒ pure default-deny). Carry the same "remove when upstream offers an env hook" note the other patches carry, and keep it in sync with the dep version.

> Scope lever: stdio is the only transport with this concern (http/sse spawn no subprocess). If trimming, phase 1 could ship http/sse only and defer stdio + its patch — but the plan includes stdio, since the scrub infra already exists.

### 2. Tool metadata is prompt-trusted before any call

Remote tool **names/descriptions reach the model as soon as they're registered** (`tool_adapter.ex:140`), before any call or approval — the gate cannot stop description-borne prompt injection. So **configured MCP servers are trusted for prompt metadata** (the operator chose to add them). Mitigation at generation time: `ProxyGenerator` strips control characters and caps description length (~a few KB). Documented as an explicit trust assumption in AGENTS.md.

---

## Files to create (`lib/jido_claw/mcp/` + one patch)

**`mcp.ex` — `JidoClaw.MCP`** (facade): `attach_to_agent/2` (fire-and-forget) + `ensure_attached/2` (bounded, request-path); `client/0` → `Application.get_env(:jido_claw, :mcp_client, JidoClaw.MCP.Client.Live)`; `approval_policy/0` → `:persistent_term.get({:jido_claw, :mcp_approval_policy}, %{})`.

**`client.ex` (`JidoClaw.MCP.Client` behaviour) + `client/live.ex` (`Client.Live`):** `@callback`s `register_endpoint/1`, `await_endpoint_ready/2`, `list_tools/2`, `call_tool/3`. `Live` delegates to `Jido.MCP.*`, **normalizes response shapes here** (`{:ok, %{data: %{"tools" => t}}}` → `{:ok, t}`; `{:ok, %{data: d}}` → `{:ok, d}`), passes **explicit discovery timeouts** (override the endpoint 30s `request_ms`), and treats `register_endpoint/1`'s `{:error, {:endpoint_already_registered, _}}` as `:ok` so a Consumer restart re-discovers and rebuilds proxies (`client_pool.ex:91`). Two impls of one explicit behaviour satisfy reach `behaviour_candidate`.

**`endpoint_config.ex` — `JidoClaw.MCP.EndpointConfig`:** `parse(raw_list)` → `{[%JidoClaw.MCP.ServerSpec{}], [warning]}`, fail-closed per entry (mirror `Templates.validate_fc/2`, `agent/templates.ex:118-138`). `ServerSpec` **struct** (`name`, `endpoint`, `require_approval`, `templates`) — avoids reach `fixed_shape_map`; the local-name prefix is always derived `"mcp_" <> name <> "_"` in the generator (not a stored/config field). Translate → `Jido.MCP.Endpoint.new/2` (`endpoint.ex:22-51`) with a default `client_info: %{name: "jido_claw", version: to_string(Application.spec(:jido_claw, :vsn) || "dev")}` (enforced key, `endpoint.ex:22,172`); reject names not `^[a-z][a-z0-9_]*$` before `String.to_atom/1`; stdio `env:` carried as the **override map** for the patched transport (default `%{}`), plus optional `cwd:` passed through (`stdio.ex:29`). Accept **both** stdio command shapes — `command: [exe | rest]` (split → `command: exe` + `args: rest`) **and** `command: "exe"` + `args: [...]` — the transport requires a string command + list args (`stdio.ex:26-27`).

**`proxy_generator.ex` — `JidoClaw.MCP.ProxyGenerator`:** `build_modules(server_name, endpoint_id, tools)` → `[module]`. **Tool-count cap first:** sort tools by name and take the first `@max_tools` (default **200**, configurable — the dep's bound, `sync_tools_to_agent.ex:29,93`; the dep *fails* the whole sync when exceeded, but skipping a server loses all its tools, so we keep a **deterministic** first-N) and `Logger.warning` the dropped **count + names** (no silent cap — each tool becomes code/atoms/prompt-metadata/registration *before* approval can help). Reuse the dep's proven `sanitize_segment` / `:erlang.phash2` / `Code.ensure_loaded?/1` idempotency, plus:
- **`mcp_`-rooted, collision-proof local names:** the prefix is **always** `"mcp_" <> server <> "_"` (not operator-configurable) and the generator asserts every `.name` starts with `mcp_` — this is what keeps the approval fail-closed fallback safe (a custom prefix like `tw_` would look *native* if the policy map were lost). Track `used_names`; `base = prefix <> sanitize(remote)`; on collision truncate base to `64 - byte_size("_<phash6>")` **then** append `_<phash6>` (≤64, the provider limit); else cap to 64. Distinct remotes that sanitize alike get distinct `.name`s, so `ToolAdapter.from_actions/2` never raises (`tool_adapter.ex:99`).
- **Real provider schema via JSON-Schema pass-through (NOT `Zoi.map()`, NOT `to_zoi`):** use the remote `inputSchema` **directly** as the action `schema:` — `Jido.Action.Schema` accepts a plain JSON-Schema object map as an LLM-only pass-through (`schema.ex:11-19`; detected when `%{"type"=>"object","properties"=>_}`, `to_json_schema` returns it ~unchanged), so `ToolAdapter` advertises the real properties. `Zoi.map()` renders as an object with **no properties + `additionalProperties:false`** (`tool_adapter.ex:143,286`) = *no args*; `to_zoi/1` is worse — it **rejects** unsupported keywords (`oneOf`/`$defs`/…, `json_schema_bridge.ex:180`), forcing the no-args fallback. Normalize each `inputSchema` to an object map (default `%{"type"=>"object","properties"=>%{}}` when absent/non-object); inject as a literal/`Macro.escape`d map. Local validation is skipped (pass-through) — the **remote server** validates args at runtime. **Limitation:** `ToolAdapter` calls `to_json_schema(strict: true)` which recursively sets `additionalProperties:false` (`schema.ex:119-128`), so a tool with genuinely *dynamic* object args is narrowed — warn-log such schemas; documented phase-1 limitation.
- **Sanitized description:** strip control chars, cap length (Trust Boundary §2).
- **Definition-complete module hash:** the `:erlang.phash2` module-name hash covers server/endpoint, remote name, local name, sanitized description, **and a digest of the resolved schema**, so a remote name/description/schema change regenerates the module instead of `Code.ensure_loaded?/1` keeping a stale proxy (`proxy_generator.ex:121`).
- Quoted body:

```elixir
quote location: :keep do
  use JidoClaw.Tools.Action,
    name: unquote(local_name),           # "mcp_<server>_<tool>" (deduped, ≤64)
    description: unquote(safe_description),
    schema: unquote(Macro.escape(input_schema_object))  # remote JSON Schema, pass-through (LLM-only)

  @endpoint_id unquote(endpoint_id)
  @remote_tool_name unquote(remote_name)

  # NO @impl — the JidoClaw.Tools.Action before_compile wrapper IS the
  # @impl Jido.Action run/2; this run/2 is its `super` target.
  def run(params, _context) do
    scrubbed = JidoClaw.Tools.OutputRedaction.redact(params)   # outbound arg scrub
    case JidoClaw.MCP.client().call_tool(@endpoint_id, @remote_tool_name, scrubbed) do
      {:ok, data} -> {:ok, data}                                # wrapper redacts/caps
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_proxy_response, other}}
    end
  end
end
```
  Outbound scrub reuses `JidoClaw.Tools.OutputRedaction.redact/1` (`output_redaction.ex:17-33`).

**`consumer.ex` — `JidoClaw.MCP.Consumer`** (GenServer):
- State `%{status: :preparing | :ready, modules: [], pending: %{pid => template}, waiters: [], attached: MapSet.new(), prep_ref}`.
- `init/1` → spawn the off-process prep (monitored; fn is internally best-effort and always sends `{:prepared, …}`); `{:ok, state}` immediately.
- `handle_call({:attach, pid, template})` → `Process.monitor(pid)`; reply `:ok`; if `:ready`, `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> register_modules(pid, modules) end)` (**fire-and-forget — no yield in the callback**); else queue in `pending`. `register_modules/2` registers each module **independently** — `has_tool?`/`register_tool` wrapped in `try/catch :exit` (+ rescue) per module, so a `GenServer.call` timeout / dead-pid (`agent_server.ex:375`, `jido_ai.ex:656`) warn-logs and continues instead of aborting the batch into silent partial registration; bounded `timeout:` where honored. `register_modules/2` returns `:ok` only when **all** expected modules are confirmed present (`has_tool?`), else `:partial`.
- `handle_call({:modules_when_ready, pid}, from)` → `pid ∈ attached` ⇒ reply `:already` (steady-state fast path, no work); else `:ready` ⇒ reply `{:ok, modules}` (the caller registers and casts `{:mark_attached, pid}` **only if `register_modules` returned `:ok`** — a `:partial` is left unmarked so the next turn retries; Consumer `Process.monitor`s the pid); else stash `from` in `waiters` and **defer** (no reply) — the caller's bounded `ensure_attached` waits, the Consumer doesn't. `handle_cast({:mark_attached, pid})` → `MapSet.put`.
- `handle_info({:prepared, modules, policy})` → publish `policy` to `:persistent_term`; cache; `status: :ready`; `GenServer.reply {:ok, modules}` to all `waiters` (clear them); `start_child` a fire-and-forget `register_modules` task per pending pid **and per `AgentTracker.get_state/1` entry filtered to `status == :running` + `Process.alive?(pid)`** (`agent_tracker.ex:213` retains terminal entries — skip them; REPL/spawned only, chat agents rely on `ensure_attached`), so a Consumer restart mid-prep re-attaches tracked **live** agents (idempotent). Best-effort overall.
- `handle_info({:DOWN, …})` → drop a dead agent pid from `pending`/`attached`; if the **prep process** dies without `{:prepared, …}` (unexpected kill), reply **`{:error, :mcp_unavailable}`** to all `waiters` and clear them — distinct from a *successful* empty prep's `{:ok, []}`, so callers don't sit to timeout **and** a failed prep is never marked `attached` — then mark `:ready` empty so `attach` stops queueing.
- Discovery runs servers concurrently (`Task.async_stream`, `:timeout` + `on_timeout: :kill_task`). `:persistent_term` survives Consumer restarts.

**`core/mcp_stdio_transport_patch.ex` — patched `Jido.MCP.Transport.STDIO`:** faithful copy of the dep module; the only behavioral change is `:env` construction via `Env.scrubbed_port_env(state.env || %{})`. `@moduledoc false`, patch-provenance + removal-condition comment like the other patches.

---

## Files to modify

**`lib/jido_claw/core/config.ex`** — `mcp_servers/1` after `servers/1` (`:142-148`): raw list, default `[]`. Not in `@defaults`.

**`lib/jido_claw/core/dependency_patches.ex`** — add `{Jido.MCP.Transport.STDIO, :jido_mcp}` to `@patched_modules` (`:4-9`).

**`lib/jido_claw/application.ex`** — serve-mode-gated `mcp_consumer_children/0` (`[]` when `serve_mode == :mcp`, else `[JidoClaw.MCP.Consumer]`); flatten into `core_children/0` **after `JidoClaw.AgentTracker` (`:268`)** — the `:prepared` rehydrate reads `AgentTracker`, so the Consumer must start after it, and the read is still guarded with `Process.whereis(JidoClaw.AgentTracker)`. `:jido_mcp` app dep ⇒ `ClientPool` up first.

**`lib/jido_claw/security/tool_approval.ex`** — without touching `require`/`require_patterns` (invariant at `:230` intact):
- `@config_defaults` (`:66`): `mcp_require_approval: true`.
- `requirement/3` (`:114`): map `mcp_requirement/2` **explicitly** so internal tags never reach `reason_suffix/1` — `:gated → :mcp_external`, `:trusted → nil`, `:not_external → native_requirement(tool, params, opts)` (explicit `if tool in require_list(opts), do: :listed, else: pattern_match(...)` — no `&&/||`).
- `mcp_requirement/2` (**explicit clauses** — avoid the `&&/||` footgun that maps `global==false` to `:not_external`): `Map.fetch(mcp_policy(opts), tool)` → `{:ok,true}→:gated`; `{:ok,false}→:trusted`; `{:ok,nil}→global_req(opts)`; `:error→ if String.starts_with?(tool,"mcp_"), do: global_req(opts), else: :not_external`. `global_req(opts) = global_to_req(opt_or_config(opts,:mcp_require_approval))` with `global_to_req(true)→:gated`, `global_to_req(false)→:trusted`. `mcp_policy/1 = Keyword.get(opts,:mcp_policy) || JidoClaw.MCP.approval_policy()`.
- `reason_suffix(:mcp_external)` clause (`:219`).
- Bypass note (`feedback_gate_bypass_coverage_sweeps`): proxies are in-process actions; `run_command` can't invoke them.

**`lib/jido_claw/inspection.ex`** — in `pid_summary/2` (`:405-428`): `tool_names: live_tool_names(pid) || tool_names_for_module(module)`, where `live_tool_names/1 = safe(fn -> {:ok, tools} = Jido.AI.list_tools(pid); Enum.map(tools, & &1.name) end)` — **must match `{:ok, tools}`** (`jido_ai.ex:449`), not a bare-list pipe. Served `mcp_tools:` field unchanged.

**`lib/jido_claw.ex`** — on the chat request path, **after** `resolve_agent_pid/1` returns (`~:108`, covering **both** fresh and existing pids — existing chat agents aren't in `AgentTracker`) and before `run_chat_turn`: `JidoClaw.MCP.ensure_attached(pid, ms)` (bounded, best-effort on timeout; steady-state-cheap via the Consumer's `attached` fast path).

**`lib/jido_claw/cli/repl.ex`** — after `start_agent(Agent, id: "main")` (`:67-69`): `JidoClaw.MCP.attach_to_agent(pid, "main")`. Best-effort.

**`config/config.exs`** — document `:tool_approval, mcp_require_approval:`; commented `mcp_servers:` example (incl. stdio `env:` semantics = operator overrides over default-deny).
**`config/test.exs`** — `config :jido_claw, :mcp_client, JidoClaw.MCP.Client.Stub`.
**`AGENTS.md`** — `JidoClaw.MCP.*` namespace row; "External MCP consumption" note (stdio env default-deny via the patch; call-vs-start approval distinction; prompt-metadata trust); update the gap statement.

---

## Config surface (`.jido/config.yaml`)

```yaml
mcp_servers:
  - name: tidewave
    transport: streamable_http   # stdio | sse | streamable_http
    url: "http://localhost:4000/tidewave/mcp"
    require_approval: false       # trusts this server (default: gated)
  - name: filesystem
    transport: stdio
    command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/dir"]
    cwd: "/path/to/project"       # subprocess working dir (optional)
    env: {FOO: "bar"}             # operator overrides on top of default-deny (omit ⇒ pure deny)
```
Inert when absent.

---

## Out of scope / deferred

Per-template allowlist enforcement (parse-only; `child/2` clears `:agent_template`, `tool_context.ex:157`); worker/sub-agent sync; generic MCP output shaping / reversible storage; reconnect/re-discovery. (Schema fidelity is **in scope** — JSON-Schema pass-through in ProxyGenerator — since `Zoi.map()` would advertise no args.)

---

## Testing (`test/jido_claw/mcp/`)

Stub `test/support/mcp_client_stub.ex` (`@behaviour JidoClaw.MCP.Client`).

1. **`proxy_generator_test.exs`:** generated modules export all three `__jidoclaw_tool_*__/0` markers (the committed wrapper-coverage guarantee — static sweep at `output_redaction_test.exs:75-106` can't reach runtime modules; `feedback_permanent_test_over_spot_check`); outbound args redacted (stub asserts); secret+oversized payload ⇒ result redacted + capped. **Collisions:** `get-user`+`get_user` ⇒ distinct `.name`s, both register. **Description:** control chars stripped, length capped. **Schema:** a remote `inputSchema` with properties ⇒ the action advertises them (pass-through, not an empty `additionalProperties:false` object); an `inputSchema` using a `to_zoi`-unsupported keyword (`oneOf`/`$defs`) stays **provider-visible**; absent/non-object ⇒ normalized empty-object (no args); a dynamic-object schema (`additionalProperties: true` / no fixed properties) ⇒ warn-logged (narrowed by `strict: true`). **mcp_ root:** every generated `.name` starts with `mcp_`. **Regeneration:** changing a remote tool's schema/name yields a new module. **Cap:** >200 remote tools ⇒ 200 generated + a warning.
2. **`tool_approval` (extend, all `enabled?: true`):** `gate("mcp_x_y", %{}, ctx_tenant, enabled?: true, mcp_policy: %{"mcp_x_y" => nil})` ⇒ `:approval_pending`; `mcp_policy: %{"mcp_x_y" => false}` ⇒ `:ok`; global `mcp_require_approval: false` + `nil` ⇒ `:ok`. **Overlap:** `%{"mcp_foo_q" => false, "mcp_foo_bar_q" => true}` ⇒ resolve independently. **Fail-closed:** `mcp_unknown_t` with **empty** policy + `enabled?: true` ⇒ `:approval_pending` (not native). **Global ungate:** same name + `mcp_require_approval: false` ⇒ `:ok` (the `&&/||` footgun would wrongly return native here).
3. **`endpoint_config_test.exs`:** `parse/1` of a list with one valid entry per transport → each yields a `%ServerSpec{}` in the returned **specs** (default `client_info` present); bad transport/url/command/name/template ⇒ in **warnings**, not specs (good entries survive). stdio `env:` default `%{}`, operator merge; `command` list splits to string command + args list.
4. **Env scrub (the trapdoor):** with a sentinel secret in `System` env, `Env.scrubbed_port_env([])` includes `{~c"<SENTINEL>", false}` and keeps `PATH` — and the patched transport builds its `:env` from it (assert the patch delegates; optionally a unix-only live spawn of `printenv` shows the secret absent).
5. **`consumer_test.exs`:** stub tools; `start_agent` real `Agent`, `attach_to_agent(pid, "main")`, **await** `{:ok, true} = Jido.AI.has_tool?(pid, "mcp_<s>_<t>")` (registration is async/bounded — poll with timeout); double-call idempotent. **Deferred attach:** attach during `:preparing` then deliver `{:prepared, …}` ⇒ tool lands. **Restart tolerance:** prep against an already-registered endpoint (`{:endpoint_already_registered, _}`) still discovers + rebuilds proxies (no hard failure). **ensure_attached:** `:ready` ⇒ `{:ok, true} = has_tool?`; called during `:preparing`, it blocks until `{:prepared}` then returns with the tool present (deferred-reply, bounded). **Fast path:** a second `ensure_attached` on an already-`attached` pid returns `:already` without re-registering. **Partial registration:** a module whose `register_tool` exits ⇒ pid **not** marked `attached`, next `ensure_attached` retries. **Crash flush:** prep dies before `{:prepared}` ⇒ blocked `ensure_attached` gets `{:error, :mcp_unavailable}` and does **not** mark `attached`. **Success-empty:** prep completes with no configured tools ⇒ `{:ok, []}`, `ensure_attached` returns and marks `attached`. **Startup guard:** rehydrate tolerates `AgentTracker` not yet up (`Process.whereis` guard).
6. **`config`:** `mcp_servers/1` default `[]` + passthrough.
7. **serve-mode gating:** Consumer absent under `serve_mode: :mcp`.

---

## Precommit checklist (`mix precommit` green = done)

- **Warnings-as-errors (`jidoclaw.compile_check`):** no `@impl` on generated `run/2`; clean quoted AST; idempotent module naming. The transport patch is a deliberate duplicate-module def (`ignore_module_conflict: true`, like existing patches) — verify it doesn't trip the gate.
- **`reach.check --strict`:** `behaviour_candidate` satisfied by `JidoClaw.MCP.Client`; `fixed_shape_map` via `ServerSpec` struct (file-level pragma on the patch/endpoint-attrs map if needed, precedent `application.ex:4`).
- **`credo --strict`:** module docs; `Logger.warning`; factor `build_modules`/prep; `IO.iodata_to_binary` for string assembly (`credo_reach_string_building`); never pipe precommit through `tail`.
- **`dialyzer`:** no `@spec` on generated `run/2`.
- **`deps.unlock --unused`:** no new deps.

---

## Verification (end-to-end)

1. **Automated:** `mix test test/jido_claw/mcp/` + extended `tool_approval`/`config`/`inspection` green; full `mix precommit` green.
2. **Manual loopback (self-consume):**
   ```yaml
   mcp_servers:
     - {name: self, transport: stdio, command: ["mix", "jidoclaw", "--mcp"], cwd: "<project dir>"}
   ```
   (`cwd` matters: the scrubbed-env child reloads secrets via `load_dotenv` from `.env` in its working dir.) `mix jidoclaw`. Ask the agent to call `mcp_self_project_info` ⇒ `approval_pending` + case id (registration + gate-by-default). `/gates approve <id>` ⇒ retry succeeds, result redacted+capped. `inspect_agent` (now live-querying) lists `mcp_self_*`. Set `require_approval: false`, restart ⇒ runs ungated.
3. **Inert when unconfigured:** no `mcp_servers:` ⇒ boot unchanged, no `mcp_*` tools.
4. **Env hygiene:** point `self` at a wrapper dumping `System.get_env()`; confirm a `.env` secret (e.g. `ANTHROPIC_API_KEY`) is **absent** in the child, `PATH` present.
