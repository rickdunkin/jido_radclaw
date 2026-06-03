# Features Worth Borrowing from Jidoka

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/jidoka` (Mike Hostetler, creator of `jido`; `mix.exs` still reads `1.0.0-beta.1` from the 2026-05-24 tag, but the working tree has advanced well past it — notably the "Hard-remove legacy agent DSL surface" and "Wrap agent lifecycle in internal Runic workflow" commits, both of which move the goalposts on several entries below). Initial inventory **2026-05-18**, audited **2026-05-26**, re-audited against both codebases **2026-05-30**.

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

- **Status (2026-05-18)** — jido_radclaw side: NOT_ADOPTED / PARTIAL / ADOPTED / SUPERSEDED / N/A. **ADOPTED is strict** — the borrowed capability is fully implemented with no deferred or placeholder pieces. Any explicit deferral ("deferred to v2," a hardcoded-`nil` field awaiting a source it doesn't have yet, an unfinished consumer migration) keeps the entry PARTIAL, even when the shipped core is load-bearing in production.
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

* **Modules**: `lib/jido_claw/trace.ex` (public API: `emit/3`, `latest/2`, `for_request/3`, `list/2`), `lib/jido_claw/trace/event.ex` (`%JidoClaw.Trace.Event{}`), `lib/jido_claw/trace/collector.ex` (singleton GenServer attaching `:telemetry` handlers — telemetry only; there is **no** `JidoClaw.SignalBus` subscription despite the original adoption sketch floating one — sanitizing into `%Event{}`, indexing by request/run/trace/agent/tenant). Helpers: `trace/domain.ex`, `trace/limit.ex`, `trace/persistence.ex`, `trace/sanitize.ex`.
* **Durable replay**: Adopted the optional Postgres path — `lib/jido_claw/trace/resources/` defines `TraceRun` and `TraceEvent` Ash resources, and the collector writes through `Persistence` for cross-restart replay. This extends Jidoka's bounded-in-memory shape for jido_radclaw's multi-tenant deployment.
* **Telemetry coverage** (wired in `collector.ex`): `[:jido, :ai, :request|:llm|:tool, *]`, `[:jido, :ai, :output, :start|:validated|:repair|:error]` (T1-3), `[:jido_claw, :compaction, :event]` (T1-2), `[:jido_claw, :handoff, :event]` (T2-1 emitter has since landed).
* **Tenant scoping**: events are keyed by `tenant_id`, as the original adoption sketch called for.
* **Event shape**: `%JidoClaw.Trace.Event{}` carries `seq, at_ms, source, category, event, phase, name, status, duration_ms` plus correlation IDs (`request_id, run_id, trace_id, span_id, parent_span_id`) and `measurements`/`metadata` — mirrors Jidoka's struct, including the `schema_version` field current Jidoka added on its `%Trace.Event{}` (jido_radclaw now carries it too — and, unlike Jidoka's in-memory-only design, *persists* it on every `trace_events` row, via a nullable `:schema_version` column, as forward-migration insurance).
* **`latest/2` recency fix (2026-05-28)**: `Collector.rebuild_indexes/1` now iterates the insertion-ordered `state.order` instead of the `state.traces` map, which Erlang reorders into hash order past the ~32-entry HAMT threshold — that scramble made `latest/2` return a stale trace for a busy agent. Found and fixed while building T2-2/T2-4, both of which lean on `Trace.latest/2`; regression-tested in `test/jido_claw/trace_test.exs`.

**Prior state (kept for historical context)**: Before T1-1 landed, the raw event stream already flowed in jido_radclaw but lived in four uncoordinated places — `lib/jido_claw/conversations/recorder.ex` (bus-subscriber writing `Message` rows for `ai.tool.started`, `ai.tool.result`, `ai.llm.response`, `ai.usage`, `ai.request.completed`), `lib/jido_claw/agent_tracker.ex` (in-memory per-agent tokens/tool_calls/status), `lib/jido_claw/reasoning/telemetry.ex` (`with_outcome/4` → `Reasoning.Outcome`), and `lib/jido_claw/conversations/resources/request_correlation.ex` (per-request scope). There was no shared `%Event{}` struct or unified `request_id → events` projection — each LiveView, CLI REPL, and MCP surface reconstructed timelines ad hoc.

**Where in jidoka**: `lib/jidoka/trace.ex`, `lib/jidoka/trace/event.ex`, `lib/jidoka/trace/collector.ex`, plus `lib/jidoka/trace/correlation.ex` (added since the 2026-05-18 baseline).

Pair with hermes T2-9 (diagnostic registry) — the unified trace surface is the natural backing store for diagnostics.

---

### T1-2. Summary-based context compaction (`Jidoka.Compaction`)

**Status (landed 2026-05-20; reclassified 2026-05-28; ADOPTED 2026-05-30)**: ADOPTED — the two v2 deferrals are closed and compaction now covers **every** agent. Per-`{agent_id, context_ref}` keying is real: each `Conversations.Message` carries a durable compaction identity (`JidoClaw.Reasoning.Compactor.Identity` — `"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed worker, the spawn tag for a sub-agent) plus a `subagent` flag; the Compactor reads its source slice keyed by that identity (`Message.for_session_agent` / `since_watermark_for_agent`) and persists per-key snapshots under `Session.metadata["compactions"][key]` via an atomic `jsonb_set` (concurrent distinct-key writes both survive). All 7 worker templates carry `compaction: [mode: :auto]`, and spawned/handoff/workflow sub-agents get their durable transcripts *completed* (task `:user` + terminal `:assistant`/`:system` turns, stamped sub-agent identity, written by `JidoClaw.Conversations.SubagentTranscript`), so each agent compacts a coherent per-agent slice. The summarizer retries transient failures (`:summarizer_timeout|:summarizer_exit|:summarizer_backend`, `summarizer_max_retries` additional attempts with `summarizer_retry_backoff_ms` backoff; `:summarizer_exception` is never retried). The handoff worker's reason/summary is injected additively into its system prompt (`Startup.inject_handoff_prompt/4`) so the transformer always keeps it. Lives in `lib/jido_claw/reasoning/compactor*`; hooks into the agent lifecycle via `JidoClaw.Agent.Defaults`'s `on_before_cmd/2` override on `{:ai_react_start, _}`. Cold readers (`Session.Worker`, `AgentView`, `JidoClaw.history/3`) use the `for_session_primary` view so sub-agent rows never surface in the chat-visible transcript; exports stay full-fidelity. (`Inspection` is not in this set — it reads `message_count` through the worker and request-scoped rows via `Message.by_request`, so it never renders the chat transcript directly.) Real `context_ref` lanes remain a no-op follow-up (the key shape is `"<identity>::<context_ref|default>"`).

Key divergences from Jidoka's shape:

* **Hook surface**: the live LLM rewrite goes through a `Jido.AI.Reasoning.ReAct.RequestTransformer` implementation, not `runtime_context` mutation. The transformer filters projected messages by `refs.request_id ∈ snapshot.summarized_request_ids` (cumulative set) and prepends a delimited *user-role* summary message after any leading system messages — no system-prompt mutation, preserving trust boundary.
* **Watermarking**: two handles — `last_summarized_sequence` (Postgres watermark, drives `Message.since_watermark/2` reads) and a cumulative `summarized_request_ids` set (drives transformer filter). Each re-compaction merges new source IDs and dedupes.
* **Boundary discipline**: turn-grouped (by `request_id`), not role-adjacency-based, because `:tool_call` / `:tool_result` rows are standalone in this codebase.
* **Forward-tagging**: `on_before_cmd` always injects `params[:extra_refs][:request_id]` so the live turn's projected messages will carry `refs.request_id` and be filterable by future compactions.
* **Config**: opts-keyword via `compaction: [...]` on `use JidoClaw.Agent.Defaults`, not a Spark DSL (T3-7 decision).
* **Summarizer bounds**: `Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, ...)` + 15s timeout + specific rescue clauses. Transient phases (`:summarizer_timeout|:summarizer_exit|:summarizer_backend`) retry up to `summarizer_max_retries` times with `summarizer_retry_backoff_ms` backoff; `:summarizer_exception` is never retried.
* **Trace surface**: `[:jido_claw, :compaction, :event]` already pre-wired in `Trace.Collector` (status mapping for `:summarized`/`:skipped` → `:completed`).

**Prior state (kept for historical context)**: `forge/context_builder.ex` has a hard-chop "max_chars trim" for resume prompts (compacting prior session history *into* a resume prompt — not the live thread). `conversations/tool_transcript.ex::result_summary/2` is a one-line preview of tool result content for DB storage.

**Where in jidoka**: `lib/jidoka/compaction.ex` (~790 lines), `lib/jidoka/compaction/{config,prompt}.ex`

**What**: Summary-based compaction. (Originally a DSL `compaction do mode :auto; max_messages 60; keep_last 12; max_summary_chars 4_000 end` — but **current jidoka removed the agent-DSL `compaction` section** in the "Hard-remove legacy agent DSL surface" commit; the `mode`/`max_messages`/`keep_last`/`max_summary_chars` knobs survive runtime-side on `Jidoka.Compaction.Config`, configured outside the agent module.) On every `:ai_react_start` over threshold, runs a separate summarizer LLM call (the agent's own model or a configured one) with **previous-summary continuity** (each new summary sees the prior one), normalized into `%Jidoka.Compaction{summary, source_message_count, retained_message_count, status, ...}` and stored on `agent.state[@state_key]`. Preserves tool-call/tool-result adjacency at the retained boundary (`expand_tool_boundary/2`). Emits `[:jidoka, :compaction, :event]` traces. Manual `Compaction.compact/2` is also exposed. The original `Jido.Thread` stays intact — compaction only affects provider-facing messages for future turns.

**Gap**: Long sessions hit context limits with no graceful degradation. Today the only choice is to truncate or fail.

**Why it matters**: This is the closest thing to a drop-in feature in this whole inventory. The design choices are well-worth lifting:

1. Keep the original thread intact, only mutate provider-facing window
2. Tool-call adjacency expansion is hard-won prompt engineering (truncating in the middle of a tool_use/tool_result pair breaks Anthropic's API contract)
3. Summary continuity (each new summary sees the previous one) prevents drift across multiple compactions
4. Explicit prompt template knob

Pairs with the **hermes T1-2 `protect_first_n`** discipline (keep first N messages intact for tool-defining preambles) and the **hermes 3b3909690** historical-media-stripping pass.

**Adoption sketch**: Lift `Jidoka.Compaction` shape nearly intact as `JidoClaw.Reasoning.Compactor` (the `reasoning/` subsystem is the natural home — it already has strategy, telemetry, certificates). Two adaptations: (1) jido_radclaw stores transcript in Postgres (`Conversations.Message`), so the compactor should write the `%Compaction{}` snapshot to `Conversations.Session.metadata["compaction"]` (already has JSONB metadata via `set_prompt_snapshot`) — *shipped as per-agent `metadata["compactions"][key]`, `key = "<agent_id>::<context_ref|default>"`*; (2) pair with `protect_first_n` knob since prompt-snapshot freezing is already a discipline in this codebase (T1-7 PARTIAL on the hermes side). Use the worker's `model: :fast` for the summarizer call. Wire compaction events into the Trace from T1-1.

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

**Status (2026-05-27)**: ADOPTED — mid-conversation ownership transfer is a first-class capability. The main agent carries `JidoClaw.Tools.Handoff` (tool #31), the REPL and `JidoClaw.chat/4` both route through `JidoClaw.Agent.Handoff.Router.resolve_session_owner/6` before every dispatch, and ownership survives process restarts via `Conversations.Session.metadata["current_agent_template"]`.

Key facts:

* **Modules**: `lib/jido_claw/agent/handoff.ex` (value struct), `lib/jido_claw/agent/handoff/registry.ex` (singleton GenServer keyed by `{tenant_id, runtime_session_id}`), `lib/jido_claw/agent/handoff/router.ex` (dispatch-time routing + preamble construction), `lib/jido_claw/tools/handoff.ex` (`handoff` tool with `output_schema`). Public API: `JidoClaw.handoff_owner/2`, `JidoClaw.reset_handoff/2`, `JidoClaw.reset_handoff/4`.
* **Registry shape**: owner record carries `template`, `module`, `%Handoff{}`, `updated_at_ms`, plus two explicit booleans — `:preamble_consumed?` (toggled `true` after the first successful post-handoff turn) and `:prompt_injected?` (toggled `true` after `JidoClaw.Startup.inject_system_prompt/3` primes the routed worker pid). Both flags are assembled inside the registry so callers can't drift the invariants.
* **Bounded preamble**: `Router.build_preamble/3` prepends a delimited `[HANDOFF CONTEXT … END HANDOFF CONTEXT]` block to the user message on the first post-handoff turn. Capped at `@max_preamble_bytes 4_000` total with per-field truncation (`@max_handoff_message_bytes 1_500`, `@max_handoff_summary_bytes 1_000`, `@max_handoff_reason_bytes 800`) plus a `@history_window 10` slice of recent chat history. Built BEFORE the current user message is written to `Session.Worker`, so the history window excludes the in-flight turn. The closing marker is preserved intact even under defense-in-depth clamping (truncating mid-marker would produce an unparseable preamble).
* **Trust boundary**: preamble is a user-role string prepended to the user message — not a system-prompt mutation. Matches the same discipline T1-2 Compaction uses for summary injection.
* **Durable mirror**: every successful handoff writes `Conversations.Session.metadata["current_agent_template"]` AND a `:system` `Conversations.Message` row ("Handed off from main to reviewer: …"). Both writes are best-effort — failure is logged but does not block the tool result. The metadata mirror is what makes cold-start hydration possible.
* **Cold-start hydration**: `Session.Worker.set_session_uuid/3` re-seeds the registry from `metadata["current_agent_template"]` when a worker first learns its UUID after a restart. The original handoff message is lost across restarts, so hydration installs a placeholder owner with `preamble_consumed?: true` — the next post-restart turn lands on the worker raw rather than re-prepending a stale preamble. The Router's `cold_start_or_default/2` is the parallel path for cases where the runtime session isn't routed through `Session.Worker` first.
* **Stale-template self-healing**: if `metadata["current_agent_template"]` names a template that no longer resolves via `Templates.get/1`, both `Session.Worker` hydration and `Router.route_with_owner/2` clear the metadata + log a warning and fall back to main.
* **Worker lifecycle**: routed worker pids are addressed by `agent_id = "handoff:#{session_uuid}:#{template_name}"`. `Router.ensure_worker_pid/2` does a `Jido.whereis` first and falls back to `JidoClaw.Jido.start_agent/2`, treating `:already_started`/`:already_registered` as success. The Jido runtime module is `Application.get_env`-pluggable for tests.
* **`/reset` semantics**: the REPL `/reset` command and `JidoClaw.reset_handoff/4` clear both the registry entry AND the durable metadata mirror so a later cold start doesn't reinstate a stale owner. `reset_handoff/2` is the registry-only path for callers without the `session_uuid`. The handoff tool explicitly rejects `to_template: "main"` with a hint to use `/reset` — handoff is a forward transition only.
* **First-post-handoff barrier**: `Router.mark_preamble_consumed_on_success/5` only flips the flag when the dispatch returned `{:ok, _}` AND the registry still points at the same template (i.e. no concurrent re-handoff happened during the turn). Failures, timeouts, or template flips leave `preamble_consumed?: false` so the next turn re-prepends.
* **System-prompt injection**: `Router.maybe_inject_prompt/6` calls `JidoClaw.Startup.inject_system_prompt/3` once per routed worker pid (gated on `prompt_injected?`). Failures are non-fatal and retry on the next turn.
* **Tool context**: `JidoClaw.ToolContext` adds `:agent_template` as a canonical key alongside `:agent_id`. `:agent_id` is opaque runtime identity (`"handoff:<uuid>:<template>"`); `:agent_template` is the human-readable template name (`"reviewer"`, etc.) that the tool reads to derive `from_template`. `ToolContext.child/2` resets `:agent_template` to `nil` so swarm-spawned children aren't mis-attributed (they're not routed via the registry).
* **Telemetry**: `JidoClaw.Tools.Handoff` emits `[:jido_claw, :handoff, :event]` with `event: :applied | :error`. The slot was already wired into `JidoClaw.Trace.Collector` (`lib/jido_claw/trace/collector.ex:103`) as part of T1-1; this entry is the first emitter and `event_name_label(:handoff, …)` already labels rows by template.
* **Supervision**: `JidoClaw.Agent.Handoff.Registry` is started under `core_children` in `lib/jido_claw/application.ex:131`, alongside `SessionRegistry` and `TenantRegistry`.
* **Tests landed**: registry unit, router unit, public-API integration, conversations dispatcher integration, conversations routing integration, worker hydration cold-start, tool unit, plus a `test/support/handoff_dispatch_capture.ex` helper.

**Adoption divergences from the original sketch**:

* **Not returned as a directive**: the original sketch had `Platform.Session.Worker` interpret a `{:handoff, …}` directive returned from the tool. The shipped shape leaves `Session.Worker` ignorant of handoff — the Registry is the source of truth, and routing is resolved at the *next* turn's dispatch entry point (REPL + `run_chat_turn/8`) rather than mid-current-turn. The model's response to a `handoff` call is treated as a normal turn ending; the system prompt instructs the LLM to emit a brief acknowledgement only. This decoupling avoided invasive Session.Worker changes and made the tool composable with any future surface that calls `Router.resolve_session_owner/6`.
* **Registry key is `{tenant_id, runtime_session_id}`, not `conversation_id`**: jido_radclaw doesn't have a single `conversation_id` — the runtime carries `(tenant, runtime_session_id)` and the durable layer carries `session_uuid`. The Registry uses the runtime key (hot-path); the `%Handoff{}` struct also carries `session_uuid` so cold-start and durable mirror paths have a UUID handle.
* **Per-tenant scoping is implicit, not via a separate `Handoff.Registry` instance**: a single GenServer keyed by `(tenant, session)` covers the multitenant case without spawning per-tenant processes. `TenantRegistry` was not repurposed.
* **'main' is a sentinel, not a target**: the tool rejects `to_template: "main"`. `/reset` is the only path back to main. This keeps the durable metadata mirror unambiguous — an absent `current_agent_template` key always means "main".

**Where in jidoka**: `lib/jidoka/handoff.ex`, `lib/jidoka/capability/handoff/registry.ex` (moved from `lib/jidoka/handoff/registry.ex` since the 2026-05-18 baseline — old path confirmed gone), plus the capability tree (`lib/jidoka/capability/handoff/{capability,metadata,runtime,tool}.ex`) and a new `lib/jidoka/handoff/owner_store.ex`.

---

### T2-2. Surface-neutral view projection (`Jidoka.AgentView`)

**Status (2026-05-31)**: ADOPTED — the session-axis `%JidoClaw.AgentView{}` remains the canonical "what is this conversation agent doing?" projection, and the other runtime axes now have their own tenant-scoped canonical projections instead of being folded into the session view: `JidoClaw.SwarmView`, `JidoClaw.ForgeView`, `JidoClaw.WorkflowView`, and `JidoClaw.RuntimeOverview`. The UI, CLI, shell, and MCP surfaces that T2-2 claims to unify now read those views rather than directly stitching together `AgentTracker`, Forge sessions, workflow runs, or ad-hoc summaries. The macro, lifecycle callbacks, and `streaming_message` remain deliberate non-goals/placeholders — not gaps.

**Completion note (2026-05-31)**: the 2026-05-29 correction was the right direction. T2-2 is complete as a multi-axis view redesign, not as a mechanical migration of every surface onto `AgentView`. `AgentView` stays narrow and session-focused; swarm, Forge, and workflow status are first-class sibling views composed by `RuntimeOverview`.

Key facts:

* **Modules**: `lib/jido_claw/agent_view.ex` — `%JidoClaw.AgentView{}` struct + public `snapshot/2`, `list/2`, and `to_mcp_map/1`; `lib/jido_claw/swarm_view.ex`; `lib/jido_claw/forge_view.ex`; `lib/jido_claw/workflow_view.ex`; `lib/jido_claw/runtime_overview.ex`. No `use JidoClaw.AgentView` macro (the original sketch explicitly said *don't ship the macro*; the surfaces here only need the data shape, not Jidoka's ergonomics).
* **Identity vocabulary**: two ids on the struct — `:session_id` (runtime id = `Conversations.Session.external_id`, keys the live worker + handoff registry) and `:session_uuid` (`Conversations.Session.id`, the Postgres UUID for FK reads). Both are carried because cold-read callers may hold one but not the other.
* **Input forms**: `%{tenant_id, session_id}` map, `%Conversations.Session{}`, or `%Session.Worker{}`. Only the `%Session{}` form is permissive (returns `{:ok, …}` with no live worker); the map form is strict and needs a live worker or a resolvable `session_uuid`. Reserved errors: `:tenant_required`, `:session_not_resolved`, `:session_id_mismatch`, `:session_not_found`.
* **Status enum**: `:idle | :running | :awaiting_handoff | :error | :hibernated | :agent_lost`, derived by cascade (trace `:failed`→`:error`, trace `:running`→`:running`, owner with `preamble_consumed?: false`→`:awaiting_handoff`, worker `:hibernated`/`:agent_lost`, else `:idle`). Worker `:active` is the normal idle lifecycle and is **not** mapped to `:running`. There is deliberately no `:done` — a long-lived session whose last trace completed is `:idle`; the terminal nuance (`:completed | :cancelled | :interrupted`) lives on a separate `:trace_status` field.
* **Trace-key picker**: handoff owner → `"handoff:<uuid>:<template>"`; live worker pid (alive) → the pid; else the runtime `session_id`. A dead pid falls back to `session_id` (not `nil`) so the snapshot doesn't drop trace/events in the race before `Session.Worker` processes the agent's `:DOWN`.
* **Events**: filtered by `events_categories` (default `[:request, :model, :tool, :output, :handoff, :reasoning]`) *first*, then capped by `events_limit` (default 100); `:infinity` branches explicitly to skip `Enum.take/2`.
* **Resilience**: every `Session.Worker` call is wrapped in `try/catch :exit`; with no live worker, messages and count cold-read from `Conversations.Message`/`Session`.
* **MCP projection**: `to_mcp_map/1` drops `:agent_module`, slims `Trace.Event` rows to a small public shape, then runs the whole map through the shared `JidoClaw.Core.JsonSafe.encode/1` (atoms→strings, module atoms dropped, `DateTime`/`NaiveDateTime`/`Date`→ISO-8601, `MapSet`→list, pids/refs dropped).
* **Consumers wired**: `lib/jido_claw/web/live/agents_live.ex` uses `AgentView.list/2`; `dashboard_live.ex`, CLI `/status`, and shell `jido status` use `RuntimeOverview`; `forge_live.ex` uses `ForgeView`; swarm display/list/kill/send/result surfaces use `SwarmView` or scoped tracker ownership checks; MCP exposes `agent_status`, `swarm_status`, `forge_status`, and `workflow_status`.
* **Tenant boundary**: every public projection/tool requires `tool_context.tenant_id` or an authenticated actor-derived tenant before exposing ids, status, errors, durations, or usage. Cross-tenant rows return the same shapes as unknown ids. Forge sessions now carry `tenant_id` + `workspace_id`, workflow runs carry `tenant_id`, and the process-global agent tracker stores tenant/session/workspace ownership metadata for scoped reads.

**Adoption divergences from the original sketch**:

* **Sources are Trace + Session.Worker + Handoff.Registry + Compactor.Storage, not "Conversations + AgentTracker + Trace."** AgentView is session-axis and intentionally does **not** read `AgentTracker` (per-agent stats) — that's T2-4 Inspection's agent-axis job. Cold `Conversations` reads are the no-live-worker fallback only.
* **`Tools.AgentStatus` is new**, not a reshape of an existing tool (the sketch's "already exists but returns ad-hoc shape" was inaccurate — the pre-existing tool is `Tools.ListAgents`, which this changeset rewired to route through the new `Tools.SwarmScope` + `JidoClaw.SwarmView` — gaining tenant/workspace/parent scoping — instead of the process-global `JidoClaw.Jido.list_agents/0`).
* **Struct departures from Jidoka's**: dropped `runtime_context` (lives on `JidoClaw.ToolContext`) and `llm_context` (events carry it via `:model` metadata); added `tenant_id` (always required), `compaction`, `handoff_owner`, `agent_template`.
* **No macro, no lifecycle callbacks** (`before_turn`/`start_turn`/…) — explicit v1 scope cut. The REPL/dashboard/Forge gaps are closed by sibling projections rather than by widening `AgentView`.

**Prior state (kept for historical context)**: each surface reinvented projection — the three LiveViews (`agents_live`, `dashboard_live`, `forge_live`) each subscribed to PubSub and assembled their own assigns, the CLI REPL (`repl.ex`/`commands.ex`/`presenters.ex`) had its own, and MCP had its own. T2-2 replaced those ad-hoc readers with the session/swarm/Forge/workflow projection family above.

**Where in jidoka**: `lib/jidoka/agent_view.ex` (~437 lines), `lib/jidoka/agent_view/{defaults,projection,run,start,turn_state}.ex`. jido_radclaw ships the struct + `snapshot/2` shape only — none of the macro/lifecycle machinery.

---

### T2-3. Subagent context-visibility policy (`forward_context`)

**Status (2026-05-29)**: ADOPTED — `forward_context` is a first-class, operator-controlled visibility policy enforced at every templated child-context build site. Default `:public` (forward the parent's full scope) means zero behavior change on landing; operators tighten an individual template by adding `forward_context: :none | {:only, [...]} | {:except, [...]}` to its map.

Key facts:

* **Policy mechanism**: `JidoClaw.ToolContext` carries the `visibility/0` type (`:public | :none | {:only, [atom()]} | {:except, [atom()]}`), a public `apply_visibility/2` (the single enforcement primitive — nulls the dropped keys, preserving `build/1`'s canonical shape), a `child/3` (apply-then-`child/2`), and `policy_controlled_keys/0` (the strippable-key universe). `{:only}`/`{:except}` are symmetric — both range only over `@policy_controlled_keys`.
* **Always-forward structural invariant**: the policy can strip only `[:user_id, :workspace_id, :workspace_uuid, :actor, :forge_session_key]`. `:tenant_id` (Ash multitenancy), `:session_id`/`:session_uuid` (request correlation + trace linkage), and `:project_dir` (child file tools) are never strippable — so a restrictive policy can't break correlation, tenancy, or a child's filesystem anchor. `register_child_correlation/1` keeps working because `:tenant_id`/`:session_uuid` survive.
* **Operator-controlled, not LLM-chosen**: the policy lives on the **template** (operator config), not a per-spawn LLM param — a real security boundary. It's identical across spawn / follow-up / workflow-step, so a child can't be re-widened mid-conversation. Policy keys stay atoms in source (no `String.to_atom` on untrusted input). A per-spawn LLM-override param is a documented future enhancement, not v1.
* **Enforced at three child-context build sites**: `Tools.SpawnAgent.register_spawned_agent/6` (spawn), `Tools.SendToAgent.send_to_agent/3` (follow-up — re-applies the policy every turn), and `Workflows.StepAction.run/2` (workflow step, via `apply_visibility/2` on the scope before `build/1`). All three keep `tool_context:` on the `ask`/`ask_sync` call, so the static-AST check in `tool_context_shape_test.exs` still passes.
* **Handoff routing is explicitly exempt**: `lib/jido_claw.ex` + `lib/jido_claw/cli/repl.ex` route the same conversation's existing `tool_context` to the owning worker. Handoff is an *ownership transfer*, not a freshly-built child — full-context continuity is its defining purpose — so `forward_context` deliberately does not apply. An explanatory comment sits at each routed-turn dispatch site.
* **Fail-closed validation**: `Agent.Templates.hydrate_template/1` defaults absent `:forward_context` to `:public` and validates the field — every `{:only,_}`/`{:except,_}` key must be a member of `ToolContext.policy_controlled_keys/0`. One membership check rejects both string keys (`{:only, ["user_id"]}`) and typo'd atoms (`{:except, [:usr_id]}` — which would otherwise fail OPEN for `:except`); any unknown key or malformed value logs a warning and fails closed to `:none`. `apply_visibility/2`'s catch-all also fails closed.

**Where in jidoka**: `lib/jidoka/subagent.ex`, plus `lib/jidoka/capability/subagent/{context,definition,metadata,tool}.ex` and `lib/jidoka/capability/subagent/runtime.ex` + `runtime/{calls,executor,result,trace}.ex` (the whole `lib/jidoka/subagent/*` subdir moved under `capability/` since the 2026-05-18 baseline). The full subagent shape there stays SUPERSEDED by swarm (`Tools.SpawnAgent` + `Tools.GetAgentResult` + `AgentTracker` + worker modules — real OTP processes with bidirectional messaging); only the `forward_context` knob was the genuine gap, and it's now closed.

**Adoption divergences from the original sketch**:

* **Policy lives on the template, not a `Tools.SpawnAgent` param.** The sketch proposed a `context_visibility` spawn parameter; the shipped shape makes it operator config on the template so it's a real boundary (the LLM can't choose its own visibility) and is enforced uniformly across spawn / follow-up / workflow-step rather than only at spawn.
* **Enforcement is centralized in `ToolContext`, not duplicated at `Workers.*` spawn paths.** `apply_visibility/2` is the single primitive; all three call sites route through it.
* **No Spark verifier needed.** The sketch floated a verifier so default-public-by-omission is loud; `hydrate_template/1` validation + the fail-closed warning is the loud-on-typo path instead, and `{:only}`/`{:except}` ranging only over `policy_controlled_keys/0` makes the structural keys un-strippable by construction.

**What the policy actually narrows (vs. the original "tenant-isolation" framing)**: it strips selected *caller identity* (`:user_id`, `:actor`) and *workspace/forge attribution* (`:workspace_id`/`:workspace_uuid`, `:forge_session_key`) — it does **not** remove all tenant reach. `:tenant_id` + `:session_uuid` remain, so Ash paths can still synthesize `Actor.system(tenant_id)` and load session ancestors. Think "least-attribution," not "least-tenant-access." Note for operators: `:workspace_id` is the cross-step VFS/shell key, so a restrictive policy on a workflow template reduces shared state between its steps — acceptable because the default is `:public`.

---

### T2-4. Agent inspection surface (`Jidoka.Inspection`)

**Status (2026-05-29)**: ADOPTED — the capability is built and works across every input kind (module, pid, agent id, session, request id, workflow run), unifying "what is this agent?" (definition) with "what is it doing?" (running state) inside one function, with three thin top-level delegates on `JidoClaw` for Jidoka-parity entry points. Every advertised `Summary` field is now sourced: the last placeholder, `:memory`, is populated from `JidoClaw.Memory.namespace_info/1` (built 2026-05-29) on the three rich builders that already populate `:compaction`.

Key facts:

* **Modules**: `lib/jido_claw/inspection.ex` (public: `inspect_agent/2`, `inspect_request/2`, `inspect_workflow/1`), `lib/jido_claw/inspection/summary.ex` (`%JidoClaw.Inspection.Summary{}`). Top-level delegates in `lib/jido_claw.ex`: `JidoClaw.inspect_agent/2`, `inspect_request/2`, `inspect_workflow/1`.
* **Summary shape** was modeled on Jidoka's `Debug.summary` (the two have since partially re-converged — see *Where in jidoka* below): `system_prompt, model, skills, tool_names, mcp_tools, context_preview, user_message, memory, compaction, subagents, workflows, handoffs, usage, duration_ms, status, interrupt, error, message_count, request_id, input_kind, resolved_at_ms`. `:memory` (`%{namespace, blocks_count, scope}`) is sourced from `Memory.namespace_info/1` on the three rich builders (`build_request_summary`, `handoff_session_summary`, `plain_session_summary`) — exactly where `:compaction` is populated. The thin map path (`session_map_summary`, and thus MCP `kind: "session"`) leaves `:memory` `nil` by design: that path has only an `external_id`, no resolvable session UUID — parallel to `:compaction`. `namespace_info/1` reuses `Memory.Scope.resolve/1` (loads ancestor FKs) + `list_blocks_for_scope_chain/1` (reads as `Actor.system/1`, so the count is scope-complete); no new Ash action or schema change.
* **Polymorphic `inspect_agent/2`** dispatches on: compiled module (definition only), pid (→ `Jido.AgentServer.state` → agent_id/module/`last_request_id` + trace), agent-id string incl. `"handoff:<uuid>:<template>"`, `%Conversations.Session{}`, and `%{tenant_id, session_id}` map. The agent-id path resolves a worker module from the tracker entry's `:template` via `Templates.get/1`, falling back to `JidoClaw.Agent` for no-entry/unknown/`"main"` — so `inspect_agent("main")` returns the main tool set.
* **Total `safe/1` discipline**: every field extraction is wrapped so any raise/exit becomes `nil`. `{:error, …}` is reserved for genuinely unresolvable inputs (wrong tenant, missing/mismatched handoff owner, bad target shape).
* **`inspect_request/2` tenant cross-check**: `Trace.for_request` is tenant-scoped, but `RequestCorrelation` rows are global (`multitenancy global?: true`), so the resolver explicitly distinguishes matching-tenant (resolve session uuid) / different-tenant (`:not_found`) / no-row (`{:ok, nil}`, nil session fields). It deliberately does *not* route through `safe/1`, which would collapse the wrong-tenant-vs-missing distinction.
* **`usage`/`error` read atom-OR-string keys** via `JidoClaw.Core.MapKeys.coalesce_field/3`, so durable-rehydrated traces (whose `measurements`/`metadata` come back string-keyed after a Postgres round-trip) still report nonzero token counts.
* **`inspect_workflow/1`** takes a `%WorkflowRun{}` or UUID (via a new `define(:by_id, action: :read, get_by: [:id])` code interface). It is **local-callers-only** — not reachable through the MCP tool (see divergences).
* **MCP tool**: `JidoClaw.Tools.InspectAgent` (new), tenant read strictly from `tool_context.tenant_id`. Nested terms are normalized through the shared `JsonSafe.encode/1`; top-level keys stay atoms to satisfy `output_schema`. `:memory` IS surfaced (it is tenant-scoped via `Scope.resolve`) but is slimmed at the boundary to `%{scope_kind, blocks_count}` — both the raw-UUID `scope` sub-map and the FK embedded in `namespace` are dropped, since a `"session:<uuid>"` namespace would leak the session UUID (notably on `kind: "request"`, where the caller supplied only a request id). Local Elixir callers keep the full `namespace`/`scope`. This contrasts with the fully-dropped `:subagents`/`:workflows`. (Cost note: `blocks_count` loads full Block rows to `length/1`; fine at current volumes, a dedicated `Ash.count/2` is a future optimization.)

**Adoption divergences from the original sketch**:

* **Leakage hygiene: the MCP tool drops `:subagents` and `:workflows` and refuses workflow dispatch entirely.** `AgentTracker` and `WorkflowRun` are not tenant-scoped today, so a tenant-facing tool that surfaced them (even `duration_ms`/`error`/an existence oracle) would leak cross-tenant runtime state. The tool's `kind` enum is `auto|module|agent_id|session|request` — no `workflow`. Trusted local Elixir callers still see both fields and `inspect_workflow/1`.
* **Top-level `JidoClaw` delegates added** for full T2-4 parity with Jidoka's `Jidoka.inspect_*` surface (the sketch only called for the module).
* **The implementation went through a code-review remediation pass** (the `transient-greeting-locket` plan): five fixes — remove MCP workflow dispatch [P1], extract the shared `JidoClaw.Core.JsonSafe` normalizer + JSON-normalize the compaction sub-map [P2], fill in the PID + non-handoff agent-id running state (both were stubs returning bare `[]`/`request_id` only) [P2], fix a latent always-nil bug in the request-correlation resolver so wrong-tenant returns `:not_found` [P2], and read usage/error via `coalesce_field` [P3].

**Where in jidoka**: `lib/jidoka/inspection/inspection.ex`, `lib/jidoka/inspection/debug.ex` (plus a new `lib/jidoka/inspection/prompt_preflight.ex`; there is no top-level `lib/jidoka/inspection.ex` — the module lives only in the subdir). The `Debug.summary` field list was the adoption target; jido_radclaw's `Summary` copied the shape and sources it from `AgentTracker` + `Conversations` + `Trace` + `Compactor.Storage` + `Handoff.Registry`. **Since then jidoka's `Debug.summary` grew, and jido_radclaw has now borrowed back the sourceable additions** — `model`, `status`, and `user_message` are shared again. The remaining jidoka-only fields are `input_message`, `prompt_preview`, `prompt_sections`, `operation_names` (just jidoka's name for `tool_names`, which jido_radclaw already has), and `mcp_errors` — `mcp_errors` left out deliberately, because jido_radclaw has no MCP-error source to populate it without a placeholder, and `input_message`/`prompt_preview`/`prompt_sections` would likewise be placeholders here. jido_radclaw never had `input_kind`/`resolved_at_ms` on the jidoka side (those two are jido_radclaw-specific). So jido_radclaw's 21-field `Summary` is a stable subset-plus-two: the fields it shares with jidoka, plus `input_kind`/`resolved_at_ms`.

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

**Status (2026-05-18; re-checked 2026-05-30)**: PARTIAL. `lib/jido_claw/platform/skills.ex` consumes YAML skills from `.jido/skills/*.yaml`, and `lib/jido_claw/agent/templates.ex` holds a static `@templates` map of the 7 `JidoClaw.Agent.Workers.*` modules (compiled-in, not file-imported, not allowlist-validated — there is no `priv/templates/` directory). But there's no equivalent for "import an agent definition from a file and validate it against an allowlist."

**Where in jidoka**: `lib/jidoka/imported_agent.ex` (~310 lines), `lib/jidoka/imported_agent/definition.ex` + `runtime_compiler.ex` (files, not subdirs), and subdirs `io/` (`codec.ex`), `registry/` (`registries.ex`), `runtime/` (`subagent.ex`), `schema/` (`schema.ex`, `spec.ex`, `validator.ex`). (Note: no `codec/` subdir — `codec.ex` lives under `io/`, and was heavily trimmed by the DSL-removal commit.)

**What**: Imports an agent spec from JSON/YAML at runtime; tools, characters, skills, subagents, workflows, handoffs, plugins, hooks, guardrails are all resolved through explicit `available_*` allowlist registries passed at import time. Invalid imports fail loudly with structured errors. The constrained schema mirrors the DSL but is intentionally a subset.

**Gap**: Tenant-supplied agent specs are not currently a use case, but as the platform grows toward multi-tenancy, this becomes the natural shape for "user creates an agent in the web UI without writing Elixir."

**Why it matters**: Foundational for a tenant-facing agent-builder UI. The allowlist-registry pattern (rather than open module loading) is the right shape for security boundaries. Spec files round-trip cleanly between web UI / CLI / API.

**Adoption sketch**: Defer until there's a concrete need for tenant-supplied agents. When that need arises, lift the Jidoka import schema and adapt the registries to read from per-tenant `Agent.Templates` allowlists. Pairs with **T1-4 Error** (constrained imports need structured validation errors).

---

## Tier 3 — Polish

### T3-1. Splode-based hook/guardrail registration

**Where in jidoka**: `lib/jidoka/hook.ex`, `lib/jidoka/guardrail.ex`, `lib/jidoka/lifecycle/{hooks,guardrails}.ex`. (The `lib/jidoka/lifecycle/` layer has since grown substantially — `config`, `foundation`, `graph`, `phase`, `runner`, `state`, … — as part of the "Wrap agent lifecycle in internal Runic workflow" commit; the Runic change lives here, not in the public Workflow DSL of T3-5.)

**Status (2026-05-18; re-checked 2026-05-30)**: SUPERSEDED. `lib/jido_claw/security/redaction/` has nine separate scrubbers (Patterns, Env, PromptRedaction, Embedding, Memory, Transcript, UI, Channel, LogRedactor). `lib/jido_claw/orchestration/approval_gate.ex` is a Postgres-backed approval resource — much heavier than Jidoka's interrupt-and-resume. The functionality is there; the unified-named-registry isn't. Adding one would be ergonomic, but the scrubbers don't behave like Jidoka guardrails (which gate LLM turns); they're outbound serializers. Skip.

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

**Where in jidoka**: `lib/jidoka/kino/{context_view,trace_view,log_trace,agent_view,chat}.ex` plus `kino.ex`, `logger_handler.ex`, `render.ex`, `runtime_setup.ex`. (The `timeline.ex` and `call_graph.ex` modules the 2026-05-18 baseline listed are now gone.)

**Status**: N/A. jido_radclaw isn't a Livebook-centric library; the equivalent role is filled by Phoenix LiveViews and the CLI REPL.

### T3-7. Spark-based `agent do ... end` DSL

**Where in jidoka**: `lib/jidoka/agent/{spark_dsl,dsl}.ex`, `lib/jidoka/agent/dsl/sections/`, compilers/verifiers. **Current state (2026-05-30): the "Hard-remove legacy agent DSL surface" commit gutted this.** The `agent do … end` DSL still exists but is narrowed to just three sections — `contract`, `tools`, `controls`; the `capabilities`/`compaction`/`lifecycle`/`memory`/`schedules` sections and the `verify_hooks`/`verify_memory` verifiers were deleted, and a new `dsl/forbidden.ex` fails loudly on the removed macros. Those concerns moved to runtime config / capability entries folded under `tools`.

**Status**: N/A. `lib/jido_claw/agent/agent.ex` (69 lines, `use JidoClaw.Agent.Defaults, name: ..., tools: [...]`) is a much simpler approach to a similar problem. Adopting Spark at this layer would be net-negative complexity — a call jidoka itself has since validated by hard-removing most of its own agent-DSL sections (see *Where in jidoka*). (Note: Spark is already used elsewhere in jido_radclaw — via Ash and via internal DSLs — so the reason to skip is fit, not capability.)

### T3-8. Chat streaming wrapper (`Jidoka.Chat.Stream`)

**Where in jidoka**: `lib/jidoka/chat.ex`, `lib/jidoka/chat/stream.ex`

**Status**: PARTIAL. jido_radclaw already streams via `Jido.AI.Request.Handle` and the various LiveView assigns. Jidoka's `Chat.Stream` is a small enumerable wrapper with `text_delta/1` and `await/2` helpers — useful sugar for CLI/script use but not load-bearing. Could be lifted as `JidoClaw.Chat.Stream` if the CLI REPL would benefit from a cleaner streaming surface.

---

## Cross-references and dependencies

The Tier 1 four and the first Tier 2 borrows cluster into a dependency graph. Under the strict ADOPTED standard (any deferral demotes to PARTIAL — ◐), the fully-adopted set is T1-1 Trace, T1-2 Compaction, T1-3 Output, T1-4 Error, T2-1 Handoff, T2-2 AgentView/projections, T2-3 Subagent context-visibility, and T2-4 Inspection (✓). (T2-3 stands outside the Trace cluster below — it depends on `ToolContext` + `Templates`, not Trace.)

```
T1-4 Error ✓ ──┬──> T1-1 Trace ✓ ──┬──> T2-2 AgentView/projections ✓
               │                    ├──> T2-4 Inspection ✓ (:memory now sourced)
               │                    └──> T2-1 Handoff ✓ (emits trace events)
               ├──> T1-2 Compaction ✓ (per-agent keying + retries; all 7 workers + sub-agents compact)
               └──> T1-3 Output ✓ (emits trace events)
```

**First wave**:

1. **T1-4 Error** — ADOPTED. Splode root with four classes (`invalid`, `execution`, `config`, `internal`), merging with `Ash.Error`.
2. **T1-1 Trace** — ADOPTED. `JidoClaw.Trace` + `Trace.Collector` + `TraceRun`/`TraceEvent` Ash resources for durable replay.
3. **T1-2 Compaction** — ADOPTED 2026-05-30. `JidoClaw.Reasoning.Compactor` + `RequestTransformer`; per-key Postgres snapshots in `Session.metadata["compactions"][key]`. Per-`{agent_id, context_ref}` keying + summarizer retries closed; all 7 workers + handoff/spawned sub-agents compact on their own slices (durable transcripts completed via `SubagentTranscript`).
4. **T1-3 Output** — ADOPTED 2026-05-26. All 7 worker templates carry structured-output contracts via upstream `Jido.AI.Output`.

**Tier 2 sequencing** (T1-1/T1-2/T1-3/T1-4 ADOPTED; T2-1 ADOPTED 2026-05-27; T2-3 + T2-4 ADOPTED 2026-05-29; T2-2 ADOPTED 2026-05-31; remaining items unblocked):

- **T2-4 Inspection** — ADOPTED 2026-05-29. Agent-axis summary (`JidoClaw.inspect_*` delegates + `inspect_agent` tool); the four-source stitching is unified inside one function and works across all input kinds. The last placeholder, `:memory`, is now sourced from `Memory.namespace_info/1` on the three rich builders (the thin map path / MCP `kind: "session"` stays `nil` by design, parallel to `:compaction`; MCP slims `:memory` to `{scope_kind, blocks_count}` — no raw FK/UUID).
- **T2-3 Subagent context-visibility** — ADOPTED 2026-05-29. Operator-controlled `forward_context` policy on the template, enforced at spawn / follow-up / workflow-step via `ToolContext.apply_visibility/2`; structural keys (`tenant_id`/`session_*`/`project_dir`) are always forwarded; handoff routing is exempt; fail-closed validation in `hydrate_template`; `:public` default = zero behavior change on landing.
- **T2-2 AgentView/projections** — ADOPTED 2026-05-31. Session-axis `AgentView` remains canonical for conversations; sibling `SwarmView`, `ForgeView`, `WorkflowView`, and `RuntimeOverview` cover the remaining axes. UI/CLI/shell/MCP surfaces now consume tenant-scoped views or scoped ownership checks, and MCP exposes `agent_status`, `swarm_status`, `forge_status`, and `workflow_status`.
- **T2-5 Schedule kind** — small ergonomic win, can ship anytime.
- **T2-6 Imported agents** — defer until tenant-builder UI is on the roadmap.

## Relationship to hermes exploration

This doc and `docs/exploration/hermes/FEATURES-WORTH-BORROWING.md` are complementary, not redundant:

- **hermes T1-2 (compaction)** → **deprecated by Jidoka T1-2** as the adoption sketch. Jidoka's Elixir-native shape is the right target; hermes's `protect_first_n` knob remains a paired discipline.
- **hermes T1-4 (FailoverReason)** → **layers above Jidoka T1-4 Error**. Splode classes are taxonomy; FailoverReason is recovery-action policy.
- **hermes T2-9 (diagnostic registry)** → **builds on Jidoka T1-1 Trace** as the backing store.

Jidoka T1-1, T1-2, T1-3, and T1-4 are all ADOPTED — re-evaluate hermes T1-2 (`protect_first_n` paired discipline), T1-4 (FailoverReason recovery-action layer above Splode), and T2-9 (diagnostic registry backed by the trace surface) next.

## Notes on upstream alignment

Because Jidoka is written by the creator of `jido`, the patterns here also hint at where the upstream framework is heading. Three things to watch:

1. **Telemetry event taxonomy**: Jidoka's `[:jidoka, :{category}, :event]` shape (with `category` ∈ hook/guardrail/memory/workflow/subagent/handoff/mcp/output/schedule) is likely the canonical event topology `jido` will converge on. Aligning `JidoClaw.SignalBus` topics with this taxonomy reduces future churn.
2. **Output/Trace DSL surface**: If `Jido.AI.Agent` eventually grows an output/trace surface at the framework level, the integration shape Jidoka uses (Output as `on_before_cmd`/`on_after_cmd` plugin pair, Trace as telemetry tap) will be the upstream-blessed pattern. Lifting Jidoka's shape now avoids retrofitting later.
3. **Schema library convergence on Zoi**: `jido_action` 2.2 already uses Zoi for its own internal metadata schemas (`@schema Zoi.struct(...)` in `deps/jido_action/lib/jido_action.ex:162`). Jidoka uses Zoi exclusively. `Jido.Action.schema` officially accepts both `NimbleOptions` and Zoi today, but the upstream direction is Zoi. **For LLM-facing schemas** (tool I/O, agent Output, Context), prefer Zoi — it composes pipeline-style, natively emits JSON Schema for provider structured-output modes, and matches the upstream pattern. **For internal config validation** (worker init, registry args, `Cron.Job` options), NimbleOptions remains idiomatic; no benefit to converting. jido_radclaw already mixes both styles (NimbleOptions for most tools; Zoi for `edit_file.ex`, `write_file.ex`, `shell/commands/jido.ex`) — the mixed state is fine because both styles are first-class. Caveat: Zoi is 0.x (currently 0.17.4); API may still shift, so pin carefully.
4. **Agent-DSL contraction**: jidoka's hard-removal of its own `capabilities`/`compaction`/`lifecycle`/`memory`/`schedules` DSL sections (2026-05-28), leaving only `contract`/`tools`/`controls`, signals the upstream direction is a *smaller* declarative agent surface with more concerns pushed to runtime config and capability entries. This retroactively validates jido_radclaw's T3-7 decision to skip the Spark agent DSL entirely — the thing it chose not to adopt is the thing upstream is now shedding.
