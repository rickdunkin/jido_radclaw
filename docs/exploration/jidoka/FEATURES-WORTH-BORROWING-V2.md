# Features Worth Borrowing from Jidoka V2

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/jidoka` at **V2** (`0.8.0-beta.1`; git history starts at "Initial Jidoka V2 spike", 2026-05-29). Inventory date **2026-06-11**.

Companion to [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) — the V1 inventory and adoption record. Nothing here re-litigates that doc: its statuses stand, and V2 reshapes of already-adopted borrows live there as dated V2 notes on each entry. This doc covers what V2 **added** — capabilities with no V1 counterpart and therefore no entry in the V1 inventory — plus the few V2 reshapes that warrant active follow-up rather than just a pointer update.

Weighting note: this is a personal, tailnet-only deployment. Tiers weight **LLM-misbehavior containment and leakage hygiene** over external-attacker hardening, per the project threat model.

## How to read this document

Same conventions as the V1 doc: Tier 1 = clear gap or high-leverage shape; Tier 2 = useful, more design work, or a less acute gap; Tier 3 = polish/watch; Already Covered / N/A = jido_radclaw has a more capable or differently-shaped equivalent. Status values are NOT_ADOPTED / PARTIAL / ADOPTED / SUPERSEDED / N/A with the same strict ADOPTED bar (any deferral or placeholder keeps an entry PARTIAL).

V2 architecture in one paragraph (details in the V1 doc's "The jidoka V2 rewrite" section): functional-core/effect-shell with an effect journal and deterministic replay. Pure phase functions in a Runic "turn spine" plan `Effect.Intent`s; only `Runtime.EffectInterpreter` touches the world, journaling every intent/result and never re-executing an effect the journal already holds (idempotency classes `pure/idempotent/dedupe/reconcile/unsafe_once`). Turns hibernate to serializable `AgentSnapshot`s and resume. The authoring surface is three DSL sections (`agent`/`tools`/`controls`) compiling to a serializable `Jidoka.Agent.Spec`.

---

## Tier 1 — High Impact

### V2-1. Operation controls with durable approval interrupts (`Jidoka.Control` + Review)

**Status (2026-06-11)**: NOT_ADOPTED.

**Where in jidoka**: `lib/jidoka/control.ex` (93 lines — the behaviour), `lib/jidoka/controls/{max_input_length,require_approval,require_context}.ex` (built-ins), `lib/jidoka/agent/spec/controls.ex` + `spec/controls/{input,operation,output}.ex` (declaration), `lib/jidoka/runtime/controls.ex` + `runtime/controls/{decision,operation,operation_context}.ex` (enforcement), the interrupt path in `lib/jidoka/runtime/effect_interpreter.ex`, `lib/jidoka/review/{interrupt,request,response,approval,policy}.ex`, `lib/jidoka/approval_predicate.ex`.

**What**: A control is a module behaviour — `name/0` plus `call/1` returning `:allow | :cont | :ok | {:block, term} | {:interrupt, term} | {:error, term}` — declared per agent in the `controls` DSL section at three boundaries: `input` (user message), `output` (final answer), and `operation` (tool call, with matchers on `kind`/`name`/`source`/`idempotency`). `MaxInputLength` and `RequireContext` block; `RequireApproval` consults a serializable `Review.Policy` whose `ApprovalPredicate` is a module (so specs and snapshots stay data), and returns `{:interrupt, reason}`. The effect interpreter turns an interrupt into a durable `%Review.Interrupt{}` (boundary, control, operation, arguments, effect id, loop index…), the turn **hibernates to a snapshot**, and `Jidoka.approve/3` / `deny/3` + `Session.resume/2` continue or refuse it later. `max_turns` and `timeout` live in the same section.

**Gap in jido_radclaw**: gating exists only at the **workflow** axis (the Reactor gate/case family — `orchestration/{gates,gate_step,gate_resume,human_gate,cases}.ex` — pauses a workflow run for human approval) and at the **sandbox** layer (Forge) where execution routes through it. At the **conversation** axis there is nothing: once the LLM decides to call `run_command`, `git_commit`, `write_file`, `network_share`, `kill_agent`, or `schedule_task`, the tool executes immediately. The containment layers today are input schemas, output redaction (`JidoClaw.Tools.Action`), Forge sandboxing where applicable, and after-the-fact trace/transcript review — no per-tool-call policy decision, and no durable "awaiting approval" state for a chat turn.

**Why it matters**: this is the single most threat-model-aligned item V2 added. The project's stated risk is LLM misbehavior, and the highest-value mitigation for it is a policy point *between the model's decision and the tool's effect*. The supporting pieces conveniently already exist here: the gate/case family proves the durable-approval UX (dashboard approve/deny, resume semantics); `Inspection.Summary` already reserves an `interrupt` field; `AgentView`'s status cascade could grow an `:awaiting_approval` value alongside `:awaiting_handoff`.

**Adoption sketch**:

- **Enforcement point**: jido_ai's ReAct runner offers no veto middleware (it emits `tool_execute` signals — observational only), so enforce at the jido_radclaw tool boundary. The natural single insertion point already exists: `JidoClaw.Tools.Action` (`lib/jido_claw/tools/action.ex`), the shared `use` wrapper that 37 tools already route through for output redaction and MCP scoping — it exists precisely so "individual tools cannot forget" a cross-cutting concern. A pre-execution gate check slots into the same `__before_compile__` wrapping, as a third macro-enforced concern alongside `__jidoclaw_tool_output_redacted__` and `__jidoclaw_tool_mcp_scoped__`.
- **Policy lives on operator config, not LLM params** — same discipline as `forward_context` (V1 T2-3): per-template control lists, validated fail-closed in `Templates.hydrate_template/1` exactly like the visibility policy is today.
- **Durable interrupt**: an Ash resource modeled on (or literally extending) the gate/case family with a `:tool_call` case kind — pending approvals keyed by a fingerprint of `{tenant, session, tool, args-hash}`, mirroring the definition-fingerprint idea Reactor replay already uses.
- **Resume semantics — the honest design problem**: jidoka hibernates the whole turn; jido_radclaw's turn is a live ReAct loop inside jido_ai, so true hibernate belongs upstream. Two local options: (a) **ticket pattern** — the gate returns a structured `approval_pending` tool error with a resume ref; the LLM ends its turn telling the user; once approved (REPL `/approvals`, dashboard), the next invocation matching the fingerprint passes — this is the gate_resume analog and the recommended v1; (b) **bounded blocking await** inside the tool task — simpler, works for short waits, but ties up the request. Start with (a).
- **Phase 1 minimal**: `require_approval` on an operator-listed set of dangerous tools + a `max_input_length`-style input control. Predicates (arg-pattern matching, e.g. `run_command` only for non-allowlisted binaries) phase 2.
- Surface pending approvals through the existing projection family (`AgentView` status, `RuntimeOverview` count, `Inspection.Summary.interrupt`).

Pairs with **V2-2** (external MCP tools should default to `require_approval`) and with the Reactor gate/case family (shared approval UX and vocabulary).

---

## Tier 2 — Useful

### V2-2. External MCP tool consumption (MCP client tool source)

**Status (2026-06-11)**: NOT_ADOPTED — but the transport machinery already ships unused in deps.

**Where in jidoka**: `lib/jidoka/agent/tool_sources/mcp.ex` (the `mcp_tools` DSL entity), `lib/jidoka/operation/source/mcp.ex` + `mcp/{tools,transport}.ex`.

**What**: jidoka agents can declare external MCP servers as tool sources — the tools they advertise are discovered, schema-mapped, and exposed to the LLM alongside local actions, with the same `forward_context` and controls treatment as any other operation source. Import supports `discover_mcp?` for spec-time discovery.

**Gap in jido_radclaw**: the platform is fluent in *serving* MCP (21 published tools; the memory consolidator even spins per-run loopback MCP endpoints for its harness) but agents cannot *consume* external MCP servers. Workers can't use tidewave-, context7-, or filesystem-class servers; every capability must be hand-written as a `Jido.Action` tool.

**Why it matters**: it's the cheapest capability-expansion lever available, because the hard part already exists in deps — `jido_mcp` ships `Jido.MCP.ClientPool` ("one Anubis client per configured endpoint", with `Jido.MCP.{Config, Endpoint, EndpointID}`) plus ready-made jido_ai actions `sync_tools_to_agent` / `unsync_tools_from_agent`. The borrow is wiring and trust policy, not transport code.

**Adoption sketch**: config surface in `.jido/config.yaml` (`mcp_servers:` list, per-template opt-in allowlist — operator-controlled, like `forward_context`); name-prefix synced tools (`mcp_<server>_<tool>`) to avoid collisions with the 31 native tools; treat external tool *results* as untrusted model input — they bypass the `JidoClaw.Tools.Action` redaction wrapper, so synced tools need an equivalent wrapping at sync time (redact outbound args via the existing scrubbers, cap/scrub inbound results); default external tools to `require_approval` once V2-1 exists. Defer per-tenant server config until multi-tenancy is real.

---

## Tier 3 — Polish / Watch

### V2-3. Trace policy/sink split (`Trace.Policy` + `Trace.Sink`)

**Status (2026-06-11)**: PARTIAL — follow-up to V1 T1-1, which is ADOPTED.

**Where in jidoka**: `lib/jidoka/trace/policy.ex`, `lib/jidoka/trace/sink.ex` + `sink/in_memory.ex`.

V2 made trace handling declarative: `Trace.Policy` is data (`enabled, sample_rate, redact_keys, omit_keys` — defaults scrub `api_key/authorization/bearer/password/secret/token` and omit `messages/prompt/raw_response/request_body/response_body`; sampling is deterministic via `:erlang.phash2`), and sinks are a behaviour. jido_radclaw has the same *capabilities* hardwired into `Trace.Collector` (`trace/sanitize.ex`, `trace/limit.ex`, `trace/persistence.ex`). The borrow would be extracting the policy knobs into config-visible data and making the persistence path a sink behaviour (in-memory / Postgres / test). Ergonomic, not load-bearing; do it opportunistically if the Collector gets touched for other reasons.

### V2-4. Replay preflight diagnostics (`Debug.ReplayDiagnostics`)

**Status (2026-06-11)**: PARTIAL — jido_radclaw's Reactor replay has a fingerprint gate; it lacks a diagnostics *report*.

**Where in jidoka**: `lib/jidoka/debug/replay_diagnostics.ex` + `debug/diagnostics.ex`.

V2 answers "is this recorded run complete/safe to reason about without re-executing providers?" as pure data: status `:complete | :waiting | :failed | :incomplete`, with `missing_effect_results`, `failed_effect_results`, `unsafe_effects`, `pending_reviews`, `warnings`. jido_radclaw's `Orchestration.Replay` gates on definition fingerprint (mismatch blocks, dashboard-only override) but reports failures as errors rather than offering a preflight summary. The borrow: a data-only `Replay.diagnose(run)` — terminal-status check, missing/failed step results, pending gates, fingerprint match — surfaced in the dashboard replay panel and in `replay_workflow`'s MCP error detail. Small, bounded, nice-to-have.

### V2-5. Deterministic eval harness (`Jidoka.Eval`)

**Status (2026-06-11)**: PARTIAL — the ingredients exist as test stubs; the harness shape doesn't.

**Where in jidoka**: `lib/jidoka/eval/{case,run}.ex`.

`Eval.Case` packages a spec + request + assertions and runs them against fake or live capabilities deterministically; `Eval.Run` is the result. jido_radclaw already has scripted backends in `test/support/` (`echo_stub`, `pass_stub`, `strategy_test_helper`, `workflow_stubs`) consumed by ordinary ExUnit tests — which covers today's needs. The case/assertion shape becomes worth lifting if reasoning-strategy or prompt regressions start biting (the `reasoning/` subsystem — strategies, pipelines, certificates — is where drift would hurt). Don't build ahead of that pain.

### V2-6. Web search tool (`Browser.Tools.SearchWeb`)

**Status (2026-06-11)**: NOT_ADOPTED.

**Where in jidoka**: `lib/jidoka/browser/tools/{read_page,search_web,snapshot_url}.ex` (backed by `jido_browser`).

jido_radclaw has `Tools.BrowseWeb` (fetch a page) but no web *search* — the Researcher worker can only follow URLs it already knows. jidoka's `search_web` (via the `jido_browser` dep, which jido_radclaw doesn't pull today) is the reference. Small, self-contained; route the output through the `Tools.Action` redaction wrapper like every other tool. Worth doing the next time Researcher quality is the work item.

### V2-7. Lua-authored bounded workflow DAGs — WATCH

**Status (2026-06-11)**: NOT_ADOPTED, deliberately — watch, don't build.

**Where in jidoka**: `lib/jidoka/workflow/lua.ex` + `workflow/lua/{policy,call_trace,plan,plan/*}.ex`.

The genuinely novel V2 idea: an LLM (or operator) writes a tiny sandboxed Lua script that calls `jidoka.workflow({...})` to *author* a bounded Runic DAG over an allowlisted `Jido.Action.Catalog`, under a hard `Lua.Policy` (defaults: 1.5s, 12 calls, 8 parallel, depth 64, 6KB script, read-only actions required) — plans, never drives, the agent loop. The jido_radclaw translation would be a `compose_skill`-style tool: LLM emits a skill definition, `StepNormalizer` validates it against the existing schema, and it runs as a tracked `WorkflowRun` on Reactor — same "LLM authors a bounded plan instead of freestyle tool-looping" payoff without embedding Lua. No current need; revisit if multi-step agent plans become a recurring pattern worth structuring. (V1 T3-5's verdict — Reactor supersedes the workflow engine itself — is unaffected.)

---

## Already Covered / N/A

| V2 capability | Verdict for jido_radclaw |
| --- | --- |
| Parallel tool-call batches (`Effect.LLMDecision` batches, `OperationBatch`, default concurrency 8) | **Already covered upstream**: jido_ai's ReAct runner executes tool batches via `Task.async_stream` with configurable `max_concurrency` (`deps/jido_ai/.../react/runner.ex:672`). |
| Effect journal + deterministic replay at the **agent loop** (`effect/*`, `runtime/effect_interpreter.ex`, `runtime/spine/*`) | **N/A as a borrow — WATCH upstream.** The loop belongs to `jido_ai`; adopting this means replacing the loop, which is a rewrite, not a borrow. jido_radclaw already converges on the same idea at the workflow axis (Reactor event log, fingerprint + replay). If `jido_ai` ever absorbs V2's runtime, revisit this whole table. |
| `Harness.Session` / `Harness.Store` / `Harness.Replay` | **SUPERSEDED**: `Conversations.Session` (Ash/Postgres, multitenant) + `Platform.Session.Worker` + `SubagentTranscript`; workflow-axis replay via `Orchestration.Replay`. V2's store-behaviour shape is what you build *without* a database. |
| Turn model (`turn/{plan,state,transition,cursor}.ex`), runtime spine, `Facade.AgentServer` | **N/A** — internal machinery of a loop jido_radclaw doesn't own. |
| `Memory.Store` behaviour (`InMemory`/`JidoMemory`) | **SUPERSEDED**: Ash-backed `JidoClaw.Memory` with scope chains, plus the consolidator subsystem. A swappable backend solves a problem this codebase doesn't have. |
| `Jidoka.Usage` (provider-neutral token/cost aggregate) | **SUPERSEDED**: `AgentTracker` token counts, `ai.usage` message rows, `RequestCorrelation`. |
| `Jidoka.Projection` (`project/1` serializable views) | **SUPERSEDED**: the T2-2 view family (`AgentView`/`SwarmView`/`ForgeView`/`WorkflowView`/`RuntimeOverview`) + `Core.JsonSafe`. |
| Catalog-backed tools + `Import`/`Export` spec round-trip | **Deferred with V1 T2-6** (tenant agent-builder not on the roadmap). V2's Import/Export/catalog triple is the reference shape when that revives. |
| `Jidoka.Context` public/non-public data partition | **Covered differently**: `ToolContext` + `forward_context` (V1 T2-3, ADOPTED) reaches the same least-attribution outcome via key policy rather than data classification. No action. |
| Workflow call-depth limits | **N/A structurally**: `RunSkill` is in the main agent's toolset only — no worker template carries it — so skill recursion is bounded by construction. Revisit if workers ever gain `run_skill`. |
| `Jidoka.Id` injectable id-generation boundary | **N/A** — no deterministic-replay test need at the agent level; Ash UUIDs fine. |
| `Jidoka.Schema` Zoi helpers, `Jidoka.Config` runtime defaults | **N/A** — covered by the existing Zoi/NimbleOptions split and the config cascade. |
| `Debug.RequestSummary` storing context *keys* not values | **Already matched**: `Tools.InspectAgent` slims/drops sensitive sub-maps at the MCP boundary (V1 T2-4). |
| `AgentView` macro + lifecycle hooks | **Unchanged deliberate non-goal** (V1 T2-2). |

---

## Sequencing and cross-references

1. **V2-1 Controls** is the headline borrow — threat-model aligned, single insertion point already exists (`Tools.Action` wrapper), approval UX already proven by the gate/case family. Nothing blocks it.
2. **V2-2 MCP client** follows naturally — external tools are exactly the case where per-operation controls earn their keep, so land V2-1 first (or at minimum its ticket resource) and default synced tools to `require_approval`.
3. **V2-3 through V2-6** are independent and opportunistic; none justify a dedicated work item today. **V2-7** is a watch entry.

Relationship to the other exploration docs:

- [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) — the V1 inventory; its per-entry V2 notes cover everything V2 *reshaped*, this doc covers what V2 *added*.
- `docs/exploration/squidie/REACTOR-ADOPTION.md` — the workflow-axis convergence story (event log, fingerprint, replay, gates); V2-1 and V2-4 deliberately reuse its vocabulary.
- `docs/exploration/hermes/FEATURES-WORTH-BORROWING.md` — unaffected; the hermes re-evaluation note in the V1 doc still stands.

Upstream watch triggers (re-audit this doc if either fires):

- `jido_ai` absorbing V2's effect-journal/deterministic-replay runtime — flips the first N/A rows into real decisions and would relocate V2-1's enforcement point.
- `jido_ai` growing a tool-execution middleware/veto hook — V2-1's gate moves from the `Tools.Action` wrapper into the runner's hook, where it can also cover tools that bypass the wrapper.
