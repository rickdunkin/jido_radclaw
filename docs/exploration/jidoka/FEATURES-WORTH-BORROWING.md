# Features Worth Borrowing from Jidoka

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/jidoka` (Mike Hostetler, creator of `jido`; `1.0.0-beta.1`, released 2026-05-24). Initial inventory **2026-05-18**, audited **2026-05-26**.

## How to read this document

Jidoka is a small, opinionated developer-facing layer over `jido` + `jido_ai` with a Spark-DSL `agent do ... end` macro. It is intentionally tiny — a single agent module, a `chat/3` call, and progressive opt-in for tools, memory, compaction, structured output, workflows, subagents, handoffs.

jido_radclaw is a production-shaped platform that has already paid the cost of building most of what Jidoka exposes — but has it as scattered subsystems (`AgentTracker`, `Recorder`, `RequestCorrelation`, `Reasoning.Telemetry`, `Forge.Persistence`) rather than under unified Jidoka-shaped names. Most of the "borrow" decisions are therefore not about copying code; they are about whether a Jidoka primitive supplies a missing **shape** or **public surface** over machinery jido_radclaw already runs.

Because Jidoka is written by the creator of `jido`, the patterns here also hint at where the upstream framework is heading. That's a second reason to borrow selectively even when something is "already covered" — alignment with the next year of upstream API direction.

Tiers are scoped to this codebase:

- **Tier 1** — clear gap or high-leverage shape; strong adoption candidate
- **Tier 2** — useful, more design work, or addresses a less acute gap
- **Tier 3** — polish; nice to have but not load-bearing
- **Already Covered / N/A** — jido_radclaw has a more capable or differently-shaped equivalent

For each entry:

- **Status (2026-05-18)** — jido_radclaw side: NOT_ADOPTED / PARTIAL / ADOPTED / SUPERSEDED / N/A
- **Where in jidoka** — file paths
- **What it does** — 1–3 sentences
- **Gap in jido_radclaw** — what we don't have that this would supply
- **Why it matters** — the case for adoption
- **Adoption sketch** — broad outline in jido_radclaw's idioms (OTP, Ash, Jido, Phoenix)

Borrowing means translating, not transplanting. Jidoka is a single-runtime library; jido_radclaw is a multi-tenant Ash/Postgres platform with Forge sandboxing, swarm, MCP server, and Phoenix LiveView.

---

## Tier 1 — High Impact

### T1-1. Unified runtime trace surface (`Jidoka.Trace` + `Trace.Event`)

**Status (2026-05-26)**: ADOPTED — `JidoClaw.Trace` is the unified projection. `Conversations.Recorder`, `AgentTracker`, `Reasoning.Telemetry`, and `RequestCorrelation` still exist (each a different abstraction — durable Postgres messages, in-memory per-agent stats, reasoning outcomes, per-request scope); Trace is the in-flight overlay that links them via `request_id`/`run_id`.

Key facts:

* **Modules**: `lib/jido_claw/trace.ex` (public API: `emit/3`, `latest/2`, `for_request/3`, `list/2`), `lib/jido_claw/trace/event.ex` (`%JidoClaw.Trace.Event{}`), `lib/jido_claw/trace/collector.ex` (singleton GenServer attaching `:telemetry` handlers + `JidoClaw.SignalBus` topics, sanitizing into `%Event{}`, indexing by request/run/trace/agent/tenant). Helpers: `trace/domain.ex`, `trace/limit.ex`, `trace/persistence.ex`, `trace/sanitize.ex`.
* **Durable replay**: Adopted the optional Postgres path — `lib/jido_claw/trace/resources/` defines `TraceRun` and `TraceEvent` Ash resources, and the collector writes through `Persistence` for cross-restart replay. This extends Jidoka's bounded-in-memory shape for jido_radclaw's multi-tenant deployment.
* **Telemetry coverage** (wired in `collector.ex`): `[:jido, :ai, :request|:llm|:tool, *]`, `[:jido, :ai, :output, :start|:validated|:repair|:error]` (T1-3), `[:jido_claw, :compaction, :event]` (T1-2), `[:jido_claw, :handoff, :event]` (T2-1 slot — wired but no emitter yet).
* **Tenant scoping**: events are keyed by `tenant_id`, as the original adoption sketch called for.
* **Event shape**: `%JidoClaw.Trace.Event{}` carries `seq, at_ms, source, category, event, phase, name, status, duration_ms` plus correlation IDs (`request_id, run_id, trace_id, span_id, parent_span_id`) and `measurements`/`metadata` — matches current Jidoka's struct.

**Prior state (kept for historical context)**: Before T1-1 landed, the raw event stream already flowed in jido_radclaw but lived in four uncoordinated places — `lib/jido_claw/conversations/recorder.ex` (bus-subscriber writing `Message` rows for `ai.tool.started`, `ai.tool.result`, `ai.llm.response`, `ai.usage`, `ai.request.completed`), `lib/jido_claw/agent_tracker.ex` (in-memory per-agent tokens/tool_calls/status), `lib/jido_claw/reasoning/telemetry.ex` (`with_outcome/4` → `Reasoning.Outcome`), and `lib/jido_claw/conversations/resources/request_correlation.ex` (per-request scope). There was no shared `%Event{}` struct or unified `request_id → events` projection — each LiveView, CLI REPL, and MCP surface reconstructed timelines ad hoc.

**Where in jidoka**: `lib/jidoka/trace.ex`, `lib/jidoka/trace/event.ex`, `lib/jidoka/trace/collector.ex`, plus `lib/jidoka/trace/correlation.ex` (added since the 2026-05-18 baseline).

Pair with hermes T2-9 (diagnostic registry) — the unified trace surface is the natural backing store for diagnostics.

---

### T1-2. Summary-based context compaction (`Jidoka.Compaction`)

**Status (2026-05-20)**: ADOPTED — main agent v1. Lives in `lib/jido_claw/reasoning/compactor*` with a tenant-aware Postgres-backed snapshot in `Session.metadata["compaction"]`. Workers explicitly carry `compaction: [mode: :off]` so they don't pay the cost; per-`{agent_id, context_ref}` keying is deferred to v2. Hooks into the agent lifecycle via `JidoClaw.Agent.Defaults`'s `on_before_cmd/2` override on `{:ai_react_start, _}`.

Key divergences from Jidoka's shape:

* **Hook surface**: the live LLM rewrite goes through a `Jido.AI.Reasoning.ReAct.RequestTransformer` implementation, not `runtime_context` mutation. The transformer filters projected messages by `refs.request_id ∈ snapshot.summarized_request_ids` (cumulative set) and prepends a delimited *user-role* summary message after any leading system messages — no system-prompt mutation, preserving trust boundary.
* **Watermarking**: two handles — `last_summarized_sequence` (Postgres watermark, drives `Message.since_watermark/2` reads) and a cumulative `summarized_request_ids` set (drives transformer filter). Each re-compaction merges new source IDs and dedupes.
* **Boundary discipline**: turn-grouped (by `request_id`), not role-adjacency-based, because `:tool_call` / `:tool_result` rows are standalone in this codebase.
* **Forward-tagging**: `on_before_cmd` always injects `params[:extra_refs][:request_id]` so the live turn's projected messages will carry `refs.request_id` and be filterable by future compactions.
* **Config**: opts-keyword via `compaction: [...]` on `use JidoClaw.Agent.Defaults`, not a Spark DSL (T3-7 decision).
* **Summarizer bounds**: `Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, ...)` + 15s timeout + specific rescue clauses. No retries on v1.
* **Trace surface**: `[:jido_claw, :compaction, :event]` already pre-wired in `Trace.Collector` (status mapping for `:summarized`/`:skipped` → `:completed`).

**Prior state (kept for historical context)**: `forge/context_builder.ex` has a hard-chop "max_chars trim" for resume prompts (compacting prior session history *into* a resume prompt — not the live thread). `conversations/tool_transcript.ex::result_summary/2` is a one-line preview of tool result content for DB storage.

**Where in jidoka**: `lib/jidoka/compaction.ex` (~790 lines), `lib/jidoka/compaction/{config,prompt}.ex`

**What**: DSL `compaction do mode :auto; max_messages 60; keep_last 12; max_summary_chars 4_000 end`. On every `:ai_react_start` over threshold, runs a separate summarizer LLM call (the agent's own model or a configured one) with **previous-summary continuity** (each new summary sees the prior one), normalized into `%Jidoka.Compaction{summary, source_message_count, retained_message_count, status, ...}` and stored on `agent.state[@state_key]`. Preserves tool-call/tool-result adjacency at the retained boundary (`expand_tool_boundary/2`). Emits `[:jidoka, :compaction, :event]` traces. Manual `Compaction.compact/2` is also exposed. The original `Jido.Thread` stays intact — compaction only affects provider-facing messages for future turns.

**Gap**: Long sessions hit context limits with no graceful degradation. Today the only choice is to truncate or fail.

**Why it matters**: This is the closest thing to a drop-in feature in this whole inventory. The design choices are well-worth lifting:

1. Keep the original thread intact, only mutate provider-facing window
2. Tool-call adjacency expansion is hard-won prompt engineering (truncating in the middle of a tool_use/tool_result pair breaks Anthropic's API contract)
3. Summary continuity (each new summary sees the previous one) prevents drift across multiple compactions
4. Explicit prompt template knob

Pairs with the **hermes T1-2 `protect_first_n`** discipline (keep first N messages intact for tool-defining preambles) and the **hermes 3b3909690** historical-media-stripping pass.

**Adoption sketch**: Lift `Jidoka.Compaction` shape nearly intact as `JidoClaw.Reasoning.Compactor` (the `reasoning/` subsystem is the natural home — it already has strategy, telemetry, certificates). Two adaptations: (1) jido_radclaw stores transcript in Postgres (`Conversations.Message`), so the compactor should write the `%Compaction{}` snapshot to `Conversations.Session.metadata["compaction"]` (already has JSONB metadata via `set_prompt_snapshot`); (2) pair with `protect_first_n` knob since prompt-snapshot freezing is already a discipline in this codebase (T1-7 PARTIAL on the hermes side). Use the worker's `model: :fast` for the summarizer call. Wire compaction events into the Trace from T1-1.

This entry **deprecates hermes T1-2** as the adoption sketch — Jidoka's Elixir-native shape is closer to the BEAM/Ash idiom than hermes's Python `ContextEngine` ABC translation.

---

### T1-3. Structured final output with repair-retry (`Jidoka.Output`)

**Status (2026-05-26)**: ADOPTED — all 7 worker templates carry structured-output contracts. No `JidoClaw.Agent.Output` behaviour was ported (the original adoption sketch called for one); instead, jido_radclaw consumes upstream `Jido.AI.Output` directly via `use Jido.AI.Agent, output: %{schema, retries, on_validation_error}`. Verifier and Reviewer landed in `46e1f87`; Coder, Researcher, TestRunner, Refactorer, and DocsWriter completed the rollout.

Key facts:

* **Engine**: `Jido.AI.Output` (deps), not a borrowed module. Each worker file in `lib/jido_claw/agent/workers/` adds an `output: %{schema: Zoi.object(...), retries: 1, on_validation_error: :repair}` keyword to its `use JidoClaw.Agent.Defaults` call. The macro plumbs that into `strategy_opts[:output]` as a compiled `%Jido.AI.Output{}` (`deps/jido_ai/lib/jido_ai/agent.ex:354,427`), which the ReAct strategy then enforces.
* **Validation site**: `Jido.AI.Reasoning.ReAct.Runner.finalize_output/4`, not Jidoka's `on_after_cmd` placement — same semantics: parse the model's last answer, either succeed, `:repair` once via a corrective re-prompt, or fail typed.
* **Per-worker shapes**:
  * **Verifier**: `verdict` (`:pass`/`:fail`), `confidence` (`:low`/`:medium`/`:high`), `reasoning`.
  * **Reviewer**: `overall` (`:approve`/`:request_changes`/`:comment`), `summary`, `findings[]` (`severity`, `description`).
  * **Coder / Refactorer**: `status` (`:completed`/`:partial`/`:blocked`), `summary`, `files_changed[]`, plus `notes` (Coder) or `improvements[]` (Refactorer).
  * **Researcher**: `summary`, `confidence`, `findings[]` (`topic`, `detail`, `references[]`).
  * **TestRunner**: `status` (`:passed`/`:failed`/`:error`), `summary`, `passed_count`/`failed_count` (both refined non-negative via `Zoi.gte(0)`), `failures[]` (`test`, `error`).
  * **DocsWriter**: `status`, `summary`, `files_changed[]`, `kinds[]` (enum of `moduledoc`/`typespec`/`readme`/`guide`/`inline_comment`/`other`).
* **Artifacts sub-object**: every workflow-touching worker (Coder, Researcher, TestRunner, Refactorer, DocsWriter) carries an `artifacts` sub-object with known optional keys (`url`/`port`/`files`) — that's the full wire contract the LLM sees (`ReqLLM.Schema` emits `additionalProperties: false`, so extras are forbidden by the JSON Schema injected into the prompt). The Zoi schema keeps `unrecognized_keys: :preserve` as **internal parse-time tolerance** so a defiant LLM emitting an unexpected key won't fail validation; the docs and prompt never promise that capability. Verifier and Reviewer omit the sub-object (evaluator/reviewer roles — no produces metadata). A `Zoi.map(key_type, value_type)` was tried first but crashes in `Jido.AI.Output`'s zoi-input normalizer (`deps/jido_ai/lib/jido_ai/output.ex:372` only recognises `Zoi.Types.Map` field-mode); the sub-object form side-steps that and still satisfies the existing `inject_produces_instruction` vocabulary.
* **Workflow consumer**: `JidoClaw.Workflows.StepAction.run_step_async/7` projects `typed_output[:summary]` into `StepResult.result` (so `ContextBuilder.format_all`/`RunSkill.build_result` see prose, not an inspected map) and merges `typed_output[:artifacts]` (stringified) into `StepResult.artifacts`. `JidoClaw.Reasoning.Output.extract_result/1` carries the `:summary`/`:reasoning` fallbacks. `inject_produces_instruction/2` is schema-agnostic — it tells the LLM to use the `artifacts` field when emitting structured JSON, or append a fenced `ARTIFACTS:` block otherwise, so workers without a schema still feed the regex extractor.
* **Trace surface**: `[:jido, :ai, :output, :start | :validated | :repair | :error]` wired in `JidoClaw.Trace.Collector` (`lib/jido_claw/trace/collector.ex`).
* **Swarm consumer**: `JidoClaw.Tools.GetAgentResult` consumes typed output via `JidoClaw.Reasoning.Output.typed_request_output/1` and `request_meta_output/1` (`lib/jido_claw/tools/get_agent_result.ex:60-82`).
* **Typed verdict parsing** lives in `JidoClaw.Workflows.IterativeWorkflow.parse_verdict/1` (`lib/jido_claw/workflows/iterative_workflow.ex:144-165`). It accepts both the typed `%{verdict: :pass | :fail}` shape from Verifier and the legacy free-form `VERDICT: PASS / FAIL` text. `JidoClaw.Reasoning.Certificates` only owns `parse_certificate/1` for fenced certificate JSON — a different artifact consumed by `Tools.VerifyCertificate`.

**Prior state (kept for historical context)**: `lib/jido_claw/reasoning/output.ex` was an `extract_output/1` helper pulling `:result`/`:answer`/`:conclusion` from heterogeneous reasoning-tool result shapes — coercion, not validation. The Jido.Action behaviour had per-tool input schemas (most NimbleOptions, three Zoi — `edit_file.ex`, `write_file.ex`, `shell/commands/jido.ex`) but no agent-level final-answer schema. The whole `JidoClaw.Agent.Workers.*` family returned free-form strings that downstream code parsed heuristically.

**Where in jidoka**: `lib/jidoka/output.ex`, `lib/jidoka/output/{config,error,runtime,schema}.ex`.

**Adoption divergences from the original sketch**:

* No `JidoClaw.Agent.Output` behaviour. Jido.AI already exposes the shape; wrapping it would add a passthrough.
* No `@output_schema` module attribute. Reading attributes inside the `Defaults` macro expansion is fragile; the public path is `WorkerModule.strategy_opts() |> Keyword.fetch!(:output)`, which is what the per-worker contract smoke test (`test/jido_claw/agent/workers/worker_output_schemas_test.exs`) uses.
* No system-prompt edits. Per-request schema instructions are injected by `Jido.AI.Output.apply_instructions/2`.
* Wiring order matched the original suggestion — Verifier first as the canary, then Reviewer, then the five workflow workers as the consumer path stabilised.

---

### T1-4. Structured error contract (`Jidoka.Error` via Splode)

**Status (2026-05-26)**: ADOPTED — `lib/jido_claw/error.ex` is a Splode root with four error classes (`invalid`, `execution`, `config`, `internal`), merging with `Ash.Error` so framework errors classify alongside first-party ones.

Key facts:

* **Module**: `lib/jido_claw/error.ex` — `use Splode, error_classes: [invalid: ..., execution: ..., config: ..., internal: ...], merge_with: [Ash.Error], unknown_error: JidoClaw.Error.Internal.UnknownError`.
* **Public constructors**: `validation_error/2`, `config_error/2`, `execution_error/2`, `not_found/3`, `invalid_argument/3`, `timeout/3`, `missing_required/2`.
* **Concrete leaves**: `JidoClaw.Error.{ValidationError, ConfigError, ExecutionError}` plus `error/normalize.ex` (+ `error/normalize/` adapters), `error/internal/`, `error/invalid.ex`, `error/execution.ex`, `error/config.ex`.
* **Forge integration**: `lib/jido_claw/forge/error.ex` modules (`ProvisionError`, `BootstrapError`, `ExecSessionError`, etc.) use `Splode.Error` and register under the `:execution` class — `Forge.Error.classify/1` is harmonized via class membership rather than parallel tuple-returning code.
* **Tools integration**: `lib/jido_claw/tools/error.ex::normalize/1` consumes `%JidoClaw.Error.*{}` first-party structs before falling back to legacy heterogeneous inputs, producing a single agent-facing `%{code, message, details}` wire shape.

**Adoption divergences from the original sketch**:

* Four classes instead of three (added `internal` for `UnknownError` and other unclassified surfaces).
* Merges with `Ash.Error` so framework errors classify cleanly — wasn't in the original sketch.

**Where in jidoka**: `lib/jidoka/error.ex`, `lib/jidoka/error/normalize.ex`, plus `lib/jidoka/error/normalize/{common,context}.ex` (split since the 2026-05-18 baseline).

Pairs naturally with hermes **T1-4** (FailoverReason classifier) — the Splode classes are the *taxonomy* layer; FailoverReason is the *recovery-action* layer above it.

---

## Tier 2 — Useful

### T2-1. Conversation-ownership handoff (`Jidoka.Handoff`)

**Status (2026-05-26)**: NOT_ADOPTED. There is no concept of "transfer ownership of this conversation to a different worker template and end this turn" anywhere in jido_radclaw. The closest pattern is `Tools.SpawnAgent` + `Tools.GetAgentResult`, which is a request/response model (parent stays in charge). Note: the trace surface (T1-1) already has `[:jido_claw, :handoff, :event]` wired in `collector.ex:103` — infrastructure-ready for an emitter.

**Where in jidoka**: `lib/jidoka/handoff.ex`, `lib/jidoka/capability/handoff/registry.ex` (moved from `lib/jidoka/handoff/registry.ex` since the 2026-05-18 baseline), plus capability module

**What**: A handoff is a first-class conversation-ownership transfer (returned as `{:handoff, %Jidoka.Handoff{}}` from `Jidoka.chat/3`, not just a tool call). `Handoff.Registry` tracks the current owner per `conversation_id`. `Jidoka.handoff_owner/1` and `reset_handoff/1` are public APIs. Subsequent turns on the same conversation route to the new owner until reset.

**Gap**: Today the chat REPL has no way to say "this isn't my job, route to a different worker." Routing decisions all happen at *spawn* time, not mid-conversation.

**Why it matters**: A genuinely new capability that fits well with the existing platform. Example use case: a generic agent receives a request, decides it's a code-review task, and hands off to `Workers.Reviewer` for the rest of the conversation. The user sees a continuous chat but the routing optimization happens transparently. Foundation for tenant-level routing policies.

**Adoption sketch**: New `JidoClaw.Agent.Handoff` struct (`to_agent`, `message`, `context`). New `Tools.Handoff` action that returns it as a directive. `Platform.Session.Worker` interprets the directive: ends the current turn, updates `Conversations.Session.metadata["current_agent_template"]`, optionally writes a `:system` message recording the transfer. Add a per-tenant `Handoff.Registry` (or repurpose the existing `TenantRegistry` infrastructure). The `[:jido_claw, :handoff, :event]` slot is already wired in the T1-1 Trace collector.

The most independently shippable Tier 2 item — minimal blocking dependencies now that Trace has landed.

---

### T2-2. Surface-neutral view projection (`Jidoka.AgentView`)

**Status (2026-05-26)**: NOT_ADOPTED — no `JidoClaw.AgentView` struct exists. Each surface still reinvents projection:

- `lib/jido_claw/web/live/agents_live.ex`, `dashboard_live.ex`, `forge_live.ex` — each subscribes to PubSub and assembles its own assigns
- `lib/jido_claw/cli/repl.ex`, `commands.ex`, `presenters.ex` — its own projection
- MCP server — its own
- `Platform.Session.Worker` is sort of the canonical state holder but isn't shaped as a *projection*

A doc-comment in `lib/jido_claw/trace/domain.ex:8` names AgentView as a future trace-surface consumer; the surface is ready, the consumer isn't built.

**Where in jidoka**: `lib/jidoka/agent_view.ex` (~437 lines), `lib/jidoka/agent_view/{defaults,projection,run,start,turn_state}.ex`

**What**: A `use Jidoka.AgentView, agent: MyAgent` macro that gives any LiveView/CLI/channel a stable struct `%AgentView{visible_messages, streaming_message, llm_context, events, status, error, outcome, metadata}` plus lifecycle callbacks `before_turn/start_turn/await_turn/refresh_turn/after_turn`. The point: every surface that talks to an agent consumes the same projection.

**Gap**: The three LiveViews, CLI REPL, and MCP all want the same view of "what is this agent doing right now" — but each derives it differently and they drift.

**Why it matters**: This is the one Jidoka feature where the *shape* is much higher value than the *implementation*. Defining a `%JidoClaw.AgentView{}` struct would let all surfaces consume one snapshot function and have consistent UX. Investment pays off as LiveViews get more sophisticated and as MCP exposes more agent state.

**Adoption sketch**: Define `JidoClaw.AgentView` struct with fields matching Jidoka's. Build a single projection function `AgentView.snapshot(session_id, opts)` that reads from `Conversations` + `AgentTracker` + `Trace` (T1-1) into the struct. LiveViews and the REPL both call it; MCP exposes it as `Tools.AgentStatus` (already exists but returns ad-hoc shape). **Don't ship the macro** — jido_radclaw's surfaces don't need the "easy ergonomics" Jidoka was built for; just the data shape.

T1-1 Trace has landed; this is now unblocked.

---

### T2-3. Subagent context-visibility policy (`forward_context`)

**Status (2026-05-26)**: NOT_ADOPTED on the policy axis. `Tools.SpawnAgent` always forwards everything — there's no `:public | :none | {:only, [...]} | {:except, [...]}` knob.

**Where in jidoka**: `lib/jidoka/subagent.ex`, plus `lib/jidoka/capability/subagent/{context,definition,metadata,tool}.ex` and `lib/jidoka/capability/subagent/runtime/{calls,executor,result,trace}.ex` (moved from `lib/jidoka/subagent/*` since the 2026-05-18 baseline).

**What**: Subagents are specialists exposed to the parent as tools with a fixed `task_schema`, `forward_context: :public | :none | {:only, [...]} | {:except, [...]}`, `target: :ephemeral | {:peer, _} | {:peer, {:context, _}}`, `result: :text | :structured`. The forwarding policy is enforced before the child agent is invoked.

**Gap**: The full subagent shape is SUPERSEDED by swarm (`Tools.SpawnAgent` + `Tools.GetAgentResult` + `AgentTracker` + worker modules) — actual OTP processes with full bidirectional messaging are much more capable than Jidoka's tool-call subagent pattern. But the **`forward_context` knob** is a genuine policy gap. Today every spawn forwards the same context.

**Why it matters**: Tenant-isolation hygiene. A child agent often shouldn't see the parent's full context (e.g., user PII the parent gathered for a different decision). An explicit visibility policy enforced at spawn time is a small tightening with security payoff.

**Adoption sketch**: Add a `context_visibility` parameter to `Tools.SpawnAgent` with the vocabulary `:public | :none | {:only, [keys]} | {:except, [keys]}`. Apply at the `JidoClaw.Agent.Workers.*` spawn path. Default to `:public` for backwards compat, but document that production deployments should pick explicitly. Optional: enforce via Spark verifier so the default-public-by-omission is loud in code review.

---

### T2-4. Agent inspection surface (`Jidoka.Inspection`)

**Status (2026-05-26)**: NOT_ADOPTED — no `JidoClaw.Inspection` module exists. Adjacent surfaces give partial views: `AgentTracker.get_state/0` returns agent stats, `lib/jido_claw/core/stats.ex` aggregates, `lib/jido_claw/cli/presenters.ex` formats. But there's no unified `JidoClaw.inspect_agent/1` returning a single shape across "definition" (what worker is this?) and "running" (what is it doing right now?).

**Where in jidoka**: `lib/jidoka/inspection/inspection.ex`, `lib/jidoka/inspection/debug.ex`

**What**: `Jidoka.inspect_agent/1`, `inspect_request/1`, `inspect_workflow/1` — returns a normalized `%Jidoka.Debug.summary{}` map (`system_prompt`, `skills`, `tool_names`, `mcp_tools`, `context_preview`, `memory`, `compaction`, `subagents`, `workflows`, `handoffs`, `usage`, `duration_ms`, `interrupt`, `error`, `message_count`) regardless of whether the input is a compiled module, struct, PID, or ID string.

**Gap**: For an agent platform with REPL + LiveView + MCP, `JidoClaw.inspect_agent(agent_id)` returning a single inspection map (definition + last request summary + active state) is valuable. Today these views are scattered.

**Why it matters**: Makes debugging dramatically faster. A user reports "the agent did the wrong thing" — one function call returns the full picture instead of stitching it together from four sources.

**Adoption sketch**: New `JidoClaw.Inspection` module mirroring Jidoka's surface but consuming jido_radclaw's existing sources (AgentTracker + Conversations.Session + Trace). The `Debug.summary` field list is a useful target — copy the shape. T1-1 Trace has landed, so the `usage`/`duration_ms` fields it would source from are now available.

---

### T2-5. Schedule kind switch (`:agent | :workflow`)

**Status (2026-05-26)**: PARTIAL on the execution-target axis. `lib/jido_claw/cron/` + `lib/jido_claw/platform/cron/` is much more production-shaped than Jidoka's beta in-memory scheduler (multi-tenant, durable, Postgres-backed, failure-tolerant, auto-disable after 3 failures, stuck detection at 2h). `Cron.Job` has `@schedule_kinds [:cron, :every, :at]` — but those are *schedule-expression* shapes (cron string vs interval vs absolute time), not the *execution-target* shape Jidoka uses. Today the resource carries `mfa_module`/`mfa_function`/`mfa_args` attributes and dispatches MFA only. Tools `ScheduleTask`/`UnscheduleTask`/`ListScheduledTasks` are mature. Jidoka's `kind: :agent | :workflow` shape (chat-turn vs workflow-input dispatch) is the gap.

**Where in jidoka**: `lib/jidoka/schedule.ex` (~375 lines), `lib/jidoka/schedule/{executor,manager}.ex`

**What**: `Jidoka.schedule/2` registers a chat schedule (calls `Jidoka.chat/3` on fire) or workflow schedule (calls `Jidoka.Workflow.run/3` on fire). `prompt`/`input`/`context` resolvers can be a function or MFA tuple. `overlap: :skip|:allow`, `timezone`, history retention.

**Gap**: jido_radclaw's `Cron.Job` dispatches MFA only. Distinguishing agent-turn schedules from workflow schedules at the Ash resource level would clean up consumer code.

**Why it matters**: Small ergonomic win, makes the cron UI clearer. Per-kind observability shapes (run_count/skip_count/last_started_at_ms) are useful enrichments to `Cron.Job` attributes.

**Adoption sketch**: Add a separate `target :: :agent | :workflow | :mfa` attribute to `Cron.Job` (the existing `kind` attribute is taken by the schedule expression). Dispatch through a small adapter that maps target to runtime entrypoint. Extend the `ScheduleTask` tool surface to expose the target. Add the `run_count`/`skip_count` fields if not already present.

---

### T2-6. Imported agent specs with allowlist registries (`Jidoka.ImportedAgent`)

**Status (2026-05-18)**: PARTIAL. `lib/jido_claw/platform/skills.ex` consumes YAML skills from `.jido/skills/*.yaml`, and `priv/templates/` ships JSON-ish agent templates. But there's no equivalent for "import an agent definition from a file and validate it against an allowlist."

**Where in jidoka**: `lib/jidoka/imported_agent.ex` (~300 lines), `lib/jidoka/imported_agent/{codec,definition,io,registry,runtime,runtime_compiler,schema}/`

**What**: Imports an agent spec from JSON/YAML at runtime; tools, characters, skills, subagents, workflows, handoffs, plugins, hooks, guardrails are all resolved through explicit `available_*` allowlist registries passed at import time. Invalid imports fail loudly with structured errors. The constrained schema mirrors the DSL but is intentionally a subset.

**Gap**: Tenant-supplied agent specs are not currently a use case, but as the platform grows toward multi-tenancy, this becomes the natural shape for "user creates an agent in the web UI without writing Elixir."

**Why it matters**: Foundational for a tenant-facing agent-builder UI. The allowlist-registry pattern (rather than open module loading) is the right shape for security boundaries. Spec files round-trip cleanly between web UI / CLI / API.

**Adoption sketch**: Defer until there's a concrete need for tenant-supplied agents. When that need arises, lift the Jidoka import schema and adapt the registries to read from per-tenant `Agent.Templates` allowlists. Pairs with **T1-4 Error** (constrained imports need structured validation errors).

---

## Tier 3 — Polish

### T3-1. Splode-based hook/guardrail registration

**Where in jidoka**: `lib/jidoka/hook.ex`, `lib/jidoka/guardrail.ex`, `lib/jidoka/lifecycle/{hooks,guardrails}.ex`

**Status (2026-05-18)**: SUPERSEDED. `lib/jido_claw/security/redaction/` has eight separate scrubbers (Patterns, Env, PromptRedaction, Embedding, Memory, Transcript, UI, Channel). `lib/jido_claw/orchestration/approval_gate.ex` is a Postgres-backed approval resource — much heavier than Jidoka's interrupt-and-resume. The functionality is there; the unified-named-registry isn't. Adding one would be ergonomic, but the scrubbers don't behave like Jidoka guardrails (which gate LLM turns); they're outbound serializers. Skip.

### T3-2. Plugin wrapper module shape

**Where in jidoka**: `lib/jidoka/plugin.ex`

**Status**: SUPERSEDED. jido_radclaw uses `Jido.Plugin` directly via `lib/jido_claw/agent_server_plugin/recorder.ex`. Adding another wrapper would be noise.

### T3-3. Character / persona DSL

**Where in jidoka**: `lib/jidoka/character.ex` (uses `jido_character`)

**Status**: N/A. Personas in jido_radclaw are baked into `Agent.Workers.*` modules and `priv/defaults/system_prompt.md`. The `.agents/skills/` SKILL.md tree (managed by `usage-rules`) is the conceptual analogue at a different level. Inverting the model isn't worth it.

### T3-4. Session descriptor struct

**Where in jidoka**: `lib/jidoka/session.ex` (~468 lines)

**Status**: SUPERSEDED. `Conversations.Session` (Ash resource, multitenant, Postgres) + `Platform.Session.{Supervisor,Worker}` (per-session OTP worker) already implement the durable, registered, supervised version. Jidoka's `Session` is what you'd use *if* you weren't backed by a database.

Small polish to consider: the `Session.chat_opts/2` helper that merges per-turn context over session context is a small ergonomic win that could be ported onto `Platform.Session.Worker`.

### T3-5. Spark-DSL'd workflows compiled to Runic graphs

**Where in jidoka**: `lib/jidoka/workflow.ex`, `lib/jidoka/workflow/{build,codegen,definition,dsl,ref,runtime,step_action,spark_dsl}.ex`

**Status**: SUPERSEDED. `lib/jido_claw/orchestration/{workflow_run,workflow_step,approval_gate}.ex` plus `lib/jido_claw/workflows/{plan,iterative,skill}_workflow.ex` give Postgres-backed Ash workflow state machines with approval gates and human-in-the-loop pause/resume. Much more capable than Jidoka's Runic-on-top wrapper for the multi-tenant case.

### T3-6. Livebook helpers (`Jidoka.Kino`)

**Where in jidoka**: `lib/jidoka/kino/{timeline,call_graph,context_view,trace_view,log_trace,agent_view,chat}.ex`

**Status**: N/A. jido_radclaw isn't a Livebook-centric library; the equivalent role is filled by Phoenix LiveViews and the CLI REPL.

### T3-7. Spark-based `agent do ... end` DSL

**Where in jidoka**: `lib/jidoka/agent/{spark_dsl,dsl}.ex`, `lib/jidoka/agent/dsl/sections/`, compilers/verifiers

**Status**: N/A. `lib/jido_claw/agent/agent.ex` (58 lines, `use JidoClaw.Agent.Defaults, name: ..., tools: [...]`) is a much simpler approach to a similar problem. Adopting Spark at this layer would be net-negative complexity. (Note: Spark is already used elsewhere in jido_radclaw — via Ash and via internal DSLs — so the reason to skip is fit, not capability.)

### T3-8. Chat streaming wrapper (`Jidoka.Chat.Stream`)

**Where in jidoka**: `lib/jidoka/chat.ex`, `lib/jidoka/chat/stream.ex`

**Status**: PARTIAL. jido_radclaw already streams via `Jido.AI.Request.Handle` and the various LiveView assigns. Jidoka's `Chat.Stream` is a small enumerable wrapper with `text_delta/1` and `await/2` helpers — useful sugar for CLI/script use but not load-bearing. Could be lifted as `JidoClaw.Chat.Stream` if the CLI REPL would benefit from a cleaner streaming surface.

---

## Cross-references and dependencies

The Tier 1 four clustered into a dependency graph (all now ADOPTED as of 2026-05-26):

```
T1-4 Error ✓ ──┬──> T1-1 Trace ✓ ──┬──> T2-2 AgentView
               │                    ├──> T2-4 Inspection
               │                    └──> T2-1 Handoff (uses trace events)
               ├──> T1-2 Compaction ✓ (emits trace events)
               └──> T1-3 Output ✓ (emits trace events)
```

**First wave (complete)**:

1. **T1-4 Error** — ADOPTED. Splode root with four classes (`invalid`, `execution`, `config`, `internal`), merging with `Ash.Error`.
2. **T1-1 Trace** — ADOPTED. `JidoClaw.Trace` + `Trace.Collector` + `TraceRun`/`TraceEvent` Ash resources for durable replay.
3. **T1-2 Compaction** — ADOPTED 2026-05-20. `JidoClaw.Reasoning.Compactor` + `RequestTransformer`; Postgres-backed snapshot in `Session.metadata["compaction"]`.
4. **T1-3 Output** — ADOPTED 2026-05-26. All 7 worker templates carry structured-output contracts via upstream `Jido.AI.Output`.

**Tier 2 sequencing** (T1 is complete; all items below are unblocked):

- **T2-1 Handoff** — most independently shippable; the `[:jido_claw, :handoff, :event]` trace slot is already wired.
- **T2-3 Subagent context-visibility** — small policy add, security-flavored.
- **T2-2 AgentView** + **T2-4 Inspection** — pair, now unblocked since T1-1 Trace has landed.
- **T2-5 Schedule kind** — small ergonomic win, can ship anytime.
- **T2-6 Imported agents** — defer until tenant-builder UI is on the roadmap.

## Relationship to hermes exploration

This doc and `docs/exploration/hermes/FEATURES-WORTH-BORROWING.md` are complementary, not redundant:

- **hermes T1-2 (compaction)** → **deprecated by Jidoka T1-2** as the adoption sketch. Jidoka's Elixir-native shape is the right target; hermes's `protect_first_n` knob remains a paired discipline.
- **hermes T1-4 (FailoverReason)** → **layers above Jidoka T1-4 Error**. Splode classes are taxonomy; FailoverReason is recovery-action policy.
- **hermes T2-9 (diagnostic registry)** → **builds on Jidoka T1-1 Trace** as the backing store.

Jidoka T1-1, T1-2, T1-3, and T1-4 are all now ADOPTED — re-evaluate hermes T1-2 (`protect_first_n` paired discipline), T1-4 (FailoverReason recovery-action layer above Splode), and T2-9 (diagnostic registry backed by the trace surface) next.

## Notes on upstream alignment

Because Jidoka is written by the creator of `jido`, the patterns here also hint at where the upstream framework is heading. Three things to watch:

1. **Telemetry event taxonomy**: Jidoka's `[:jidoka, :{category}, :event]` shape (with `category` ∈ hook/guardrail/memory/workflow/subagent/handoff/mcp/output/schedule) is likely the canonical event topology `jido` will converge on. Aligning `JidoClaw.SignalBus` topics with this taxonomy reduces future churn.
2. **Output/Trace DSL surface**: If `Jido.AI.Agent` eventually grows an output/trace surface at the framework level, the integration shape Jidoka uses (Output as `on_before_cmd`/`on_after_cmd` plugin pair, Trace as telemetry tap) will be the upstream-blessed pattern. Lifting Jidoka's shape now avoids retrofitting later.
3. **Schema library convergence on Zoi**: `jido_action` 2.2 already uses Zoi for its own internal metadata schemas (`@schema Zoi.struct(...)` in `deps/jido_action/lib/jido_action.ex:162`). Jidoka uses Zoi exclusively. `Jido.Action.schema` officially accepts both `NimbleOptions` and Zoi today, but the upstream direction is Zoi. **For LLM-facing schemas** (tool I/O, agent Output, Context), prefer Zoi — it composes pipeline-style, natively emits JSON Schema for provider structured-output modes, and matches the upstream pattern. **For internal config validation** (worker init, registry args, `Cron.Job` options), NimbleOptions remains idiomatic; no benefit to converting. jido_radclaw already mixes both styles (NimbleOptions for most tools; Zoi for `edit_file.ex`, `write_file.ex`, `shell/commands/jido.ex`) — the mixed state is fine because both styles are first-class. Caveat: Zoi is 0.x (currently 0.17.4); API may still shift, so pin carefully.
