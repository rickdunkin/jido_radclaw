# Features Worth Borrowing from Jidoka

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/jidoka` (Mike Hostetler, creator of `jido`). Initial inventory **2026-05-18**, audited **2026-05-26**, re-audited against both codebases **2026-05-30**, re-audited **2026-06-11** after jidoka's V2 rewrite and jido_radclaw's Reactor migration (see next section), facts re-verified **2026-07-02** against jidoka `9469dc09` (2026-06-17, still `0.8.0-beta.1` — only dep bumps and prefixed-UUIDv7 IDs since) — the jidoka-side pointers held; jido_radclaw-side drift (worker-family growth, WS4a cron ownership, `:awaiting_approval`) is corrected inline.

## The jidoka V2 rewrite (2026-06-11 re-audit)

Between 2026-05-29 and 2026-06-01 jidoka was rewritten from scratch as **Jidoka V2**: the git history restarts at "Initial Jidoka V2 spike" (2026-05-29), the version reset from `1.0.0-beta.1` to `0.8.0-beta.1`, and jidoka's AGENTS.md declares the old implementation "moved to `../jidoka_v1`" (that directory is not present locally, so the V1 paths below are historical references only). Every borrow in this document was taken from V1. The rewrite changes none of the jido_radclaw-side statuses — the borrows were translations, not dependencies on jidoka code — but it invalidates most "Where in jidoka" pointers, so each entry now carries a dated **V2 note**.

V2 is a different animal from the V1 this doc inventoried: "a data-driven agent framework for the Jido ecosystem with a Spark DSL and durable turn runtime." The architecture is functional-core/effect-shell with an **effect journal and deterministic replay**: pure phase functions in a Runic "turn spine" (`runtime/spine/`) plan `Effect.Intent`s; only `Runtime.EffectInterpreter` touches the world, records intents/results into `Effect.Journal`, and never re-executes an effect the journal already holds (idempotency classes `pure/idempotent/dedupe/reconcile/unsafe_once`). Turns can **hibernate** to serializable `AgentSnapshot`s (notably on approval interrupts) and resume. jidoka's AGENTS.md explicitly forbids `Jido.AI.ReAct` as the loop owner — V2 owns its own loop.

Fate of the V1 features this doc inventoried, in V2:

| V1 feature (entry) | V2 state |
| --- | --- |
| Trace (T1-1) | Reshaped: `%Trace.Event{}` + telemetry collector → `Jidoka.Event` (Zoi struct) + `Trace.Sink` behaviour + `Trace.Policy` (redaction/sampling as data) |
| Compaction (T1-2) | **Removed — no replacement** |
| Output (T1-3) | Reshaped: `Agent.Spec.Result` (Zoi schema + `max_repairs`); repair-retry lives in the turn runtime |
| Error (T1-4) | Kept: still Splode; converged on the same four classes jido_radclaw chose |
| Handoff (T2-1) | Kept, slimmed: data contract + pluggable `OwnerStore` behaviour (ETS default) |
| AgentView (T2-2) | Kept, slimmed (384 lines + `Events`); macro + lifecycle hooks survive |
| `forward_context` (T2-3) | Kept: same `:public/:none/{:only}/{:except}` shape on subagent/handoff/workflow operation sources |
| Inspection (T2-4) | Grown: `Jidoka.Inspection` + `Jidoka.Debug` (`RequestSummary`, `ReplayDiagnostics`) |
| Schedule (T2-5) | **Removed — no replacement** |
| ImportedAgent (T2-6) | Renamed `Jidoka.Import` (+ new `Jidoka.Export` inverse); same allowlist-registry model |
| Hooks/guardrails (T3-1) | Replaced by **Controls** (`Jidoka.Control` behaviour) + **Review** approval interrupt/resume |
| Plugin (T3-2), Character (T3-3) | Removed (`jido_character` dep dropped) |
| Session (T3-4) | Reshaped: facade over a durable `Harness.Session` envelope |
| Workflow (T3-5) | Grown: Spark DSL + Runic runtime, parallel steps, retry policies, sandboxed **Lua-authored DAGs** |
| Kino (T3-6) | Kept minus log-trace modules; new debug views |
| Agent DSL (T3-7) | Kept, narrow: exactly `agent`/`tools`/`controls` sections over a serializable spec |
| Chat.Stream (T3-8) | Kept: `Jidoka.Stream` (Enumerable; `text_delta/1`, `await/2`) |

New in V2 with no entry in this inventory: the effect journal + deterministic replay itself, `Harness.Session`/`Harness.Replay` durable session envelopes, the Controls + Review approval system (interrupt → hibernate → `approve/deny` → resume), `Jidoka.Eval` (deterministic eval harness over fake/live capabilities), `Jidoka.Export` spec round-tripping, `Debug.ReplayDiagnostics`, the `Memory.Store` behaviour (`InMemory`/`JidoMemory`), browser tool sources (`jido_browser`), catalog-backed tools, parallel tool-call batches, and the sandboxed Lua workflow planner. These are tiered in the companion **[`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md)** (2026-06-11) — headline: V2-1 operation controls with durable approval interrupts (Tier 1), V2-2 external-MCP tool consumption (Tier 2). Several others converge with work jido_radclaw did independently — the Reactor-based workflow event log/replay (`docs/exploration/squidie/REACTOR-ADOPTION.md`) is the obvious rhyme.

**jido_radclaw drift since 2026-05-30 that touches entries below**: the Reactor migration (Phases 0–5, shipped 2026-06-08..10) replaced the standalone workflow modules — `workflows/{plan,iterative,skill}_workflow.ex`, `Workflows.StepAction`, and `orchestration/approval_gate.ex` are deleted; skills now compile to Reactor (`skills/compiler.ex` + `skills/steps/*`), approval gates became the `orchestration/` gate/case family, and `RunSummaryFeed` was deleted in favor of `WorkflowView`. Affected references in T1-3, T2-3, T2-4, T3-1, and T3-5 are updated in place below.

## How to read this document

Jidoka as inventoried here (V1) was a small, opinionated developer-facing layer over `jido` + `jido_ai` with a Spark-DSL `agent do ... end` macro — intentionally tiny: a single agent module, a `chat/3` call, and progressive opt-in for tools, memory, compaction, structured output, workflows, subagents, handoffs. V2 keeps the narrow authoring surface (`agent`/`tools`/`controls` sections, `chat/3` still the entry point) but swaps the internals for the data-driven turn runtime described in the previous section.

jido_radclaw is a production-shaped platform that has already paid the cost of building most of what Jidoka exposes — but has it as scattered subsystems (`AgentTracker`, `Recorder`, `RequestCorrelation`, `Reasoning.Telemetry`, `Forge.Persistence`) rather than under unified Jidoka-shaped names. Most of the "borrow" decisions are therefore not about copying code; they are about whether a Jidoka primitive supplies a missing **shape** or **public surface** over machinery jido_radclaw already runs.

Because Jidoka is written by the creator of `jido`, the patterns here also hint at where the upstream framework is heading. That's a second reason to borrow selectively even when something is "already covered" — alignment with the next year of upstream API direction.

Tiers are scoped to this codebase:

- **Tier 1** — clear gap or high-leverage shape; strong adoption candidate
- **Tier 2** — useful, more design work, or addresses a less acute gap
- **Tier 3** — polish; nice to have but not load-bearing
- **Already Covered / N/A** — jido_radclaw has a more capable or differently-shaped equivalent

For each entry:

- **Status (2026-05-18)** — jido_radclaw side: NOT_ADOPTED / PARTIAL / ADOPTED / SUPERSEDED / N/A. **ADOPTED is strict** — the borrowed capability is fully implemented with no deferred or placeholder pieces. Any explicit deferral ("deferred to v2," a hardcoded-`nil` field awaiting a source it doesn't have yet, an unfinished consumer migration) keeps the entry PARTIAL, even when the shipped core is load-bearing in production.
- **Where in jidoka** — file paths (V1 paths = the borrowed shape; dated **V2 notes** added 2026-06-11 give the current location or removal)
- **What it does** — 1–3 sentences
- **Gap in jido_radclaw** — what we don't have that this would supply
- **Why it matters** — the case for adoption
- **Adoption sketch** — broad outline in jido_radclaw's idioms (OTP, Ash, Jido, Phoenix)

Live deferrals and watch entries from this doc and the V2 companion are rolled up in [`UNADOPTED-IDEAS.md`](UNADOPTED-IDEAS.md) (2026-07-02) — standing, verdict, and adoption trigger for each, in one place.

Borrowing means translating, not transplanting. Jidoka is a single-runtime library; jido_radclaw is a multi-tenant Ash/Postgres platform with Forge sandboxing, swarm, MCP server, and Phoenix LiveView.

---

## Tier 1 — High Impact

### T1-1. Unified runtime trace surface (`Jidoka.Trace` + `Trace.Event`)

**Status (2026-05-26)**: ADOPTED — `JidoClaw.Trace` is the unified projection. `Conversations.Recorder`, `AgentTracker`, `Reasoning.Telemetry`, and `RequestCorrelation` still exist (each a different abstraction — durable Postgres messages, in-memory per-agent stats, reasoning outcomes, per-request scope); Trace is the in-flight overlay that links them via `request_id`/`run_id`.

Key facts:

* **Modules**: `lib/jido_claw/trace.ex` (public API: `emit/3`, `latest/2`, `for_request/3`, `list/2`), `lib/jido_claw/trace/event.ex` (`%JidoClaw.Trace.Event{}`), `lib/jido_claw/trace/collector.ex` (singleton GenServer attaching `:telemetry` handlers — telemetry only; there is **no** `JidoClaw.SignalBus` subscription despite the original adoption sketch floating one — sanitizing into `%Event{}`, indexing by request/run/trace/agent/tenant). Helpers: `trace/domain.ex`, `trace/limit.ex`, `trace/persistence.ex`, `trace/sanitize.ex` (a thin facade since the V2-3 policy/sink split added `trace/policy.ex`, `trace/sink.ex` + `sink/{postgres,in_memory}.ex`), and — since WS-4 (2026-06-29) — `trace/retention_sweeper.ex` (hourly batched pruning of expired `trace_runs`/`trace_events` rows).
* **Durable replay**: Adopted the optional Postgres path — `lib/jido_claw/trace/resources/` defines `TraceRun` and `TraceEvent` Ash resources, and the collector writes through `Persistence` for cross-restart replay. This extends Jidoka's bounded-in-memory shape for jido_radclaw's multi-tenant deployment.
* **Telemetry coverage** (wired in `collector.ex`): `[:jido, :ai, :request|:llm|:tool, *]` (incl. the `:tool, :execute` triplet; `[:jido, :ai, :llm, :delta]` is deliberately omitted), `[:jido, :ai, :output, :start|:validated|:repair|:error]` (T1-3), and eleven `[:jido_claw, <subsystem>, :event]` slots — `hook`, `guardrail`, `memory`, `workflow`, `subagent`, `handoff` (T2-1), `mcp`, `output`, `schedule`, `compaction` (T1-2), `reasoning`.
* **Tenant scoping**: events are keyed by `tenant_id`, as the original adoption sketch called for.
* **Event shape**: `%JidoClaw.Trace.Event{}` carries `seq, at_ms, source, category, event, phase, name, status, duration_ms` plus correlation IDs (`request_id, run_id, trace_id, span_id, parent_span_id`) and `measurements`/`metadata` — mirrors V1 Jidoka's struct, including the `schema_version` field late-V1 Jidoka added on its `%Trace.Event{}` (jido_radclaw carries it too — and, unlike Jidoka's in-memory-only design, *persists* it on every `trace_events` row, via a nullable `:schema_version` column, as forward-migration insurance; V2's replacement `Jidoka.Event` dropped the field, which doesn't weaken the insurance argument here).
* **`latest/2` recency fix (2026-05-28)**: `Collector.rebuild_indexes/1` now iterates the insertion-ordered `state.order` instead of the `state.traces` map, which Erlang reorders into hash order past the ~32-entry HAMT threshold — that scramble made `latest/2` return a stale trace for a busy agent. Found and fixed while building T2-2/T2-4, both of which lean on `Trace.latest/2`; regression-tested in `test/jido_claw/trace_test.exs`.

**Prior state (kept for historical context)**: Before T1-1 landed, the raw event stream already flowed in jido_radclaw but lived in four uncoordinated places — `lib/jido_claw/conversations/recorder.ex` (bus-subscriber writing `Message` rows for `ai.tool.started`, `ai.tool.result`, `ai.llm.response`, `ai.usage`, `ai.request.completed`), `lib/jido_claw/agent_tracker.ex` (in-memory per-agent tokens/tool_calls/status), `lib/jido_claw/reasoning/telemetry.ex` (`with_outcome/4` → `Reasoning.Outcome`), and `lib/jido_claw/conversations/resources/request_correlation.ex` (per-request scope). There was no shared `%Event{}` struct or unified `request_id → events` projection — each LiveView, CLI REPL, and MCP surface reconstructed timelines ad hoc.

**Where in jidoka**: V1 (the borrowed shape): `lib/jidoka/trace.ex`, `lib/jidoka/trace/event.ex`, `lib/jidoka/trace/collector.ex`, `lib/jidoka/trace/correlation.ex`. **V2 note (2026-06-11)**: reshaped — the event struct is now top-level `Jidoka.Event` (Zoi struct: `seq, event, category, phase, status, agent_id, request_id, loop_index, effect_id, effect_kind, operation, data, error`; 26 named events as of `9469dc09`; no span ids, no `schema_version`), `lib/jidoka/trace.ex` (155 lines) is a pure projection helper over event lists, and the telemetry-attached collector GenServer is gone in favor of a `Trace.Sink` behaviour (`Sink.InMemory` default) plus `Trace.Policy` data (deterministic sampling; `redact_keys`/`omit_keys` defaults that scrub secrets and bulky payloads). jido_radclaw's telemetry-collector adoption matched V1; V2's sink/policy split — redaction and sampling as declarative policy rather than code — has since been adopted as well (`Trace.Policy` data + a `Trace.Sink` behaviour — **V2-3** in [`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md), ADOPTED 2026-06-16), with the Collector still riding `:telemetry` for transport.

Pair with hermes T2-9 (diagnostic registry) — the unified trace surface is the natural backing store for diagnostics.

---

### T1-2. Summary-based context compaction (`Jidoka.Compaction`)

**Status (landed 2026-05-20; reclassified 2026-05-28; ADOPTED 2026-05-30)**: ADOPTED — the two v2 deferrals are closed and compaction now covers **every** agent. Per-`{agent_id, context_ref}` keying is real: each `Conversations.Message` carries a durable compaction identity (`JidoClaw.Reasoning.Compactor.Identity` — `"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed worker, the spawn tag for a sub-agent) plus a `subagent` flag; the Compactor reads its source slice keyed by that identity (`Message.for_session_agent` / `since_watermark_for_agent`) and persists per-key snapshots under `Session.metadata["compactions"][key]` via an atomic `jsonb_set` (concurrent distinct-key writes both survive). All worker templates carry `compaction: [mode: :auto]` (13 as of 2026-07-02 — the original 7 plus AR-4's Fixer, AR-8b's sketch trio, and AR-8c's system pair), and spawned/handoff/workflow sub-agents get their durable transcripts *completed* (task `:user` + terminal `:assistant`/`:system` turns, stamped sub-agent identity, written by `JidoClaw.Conversations.SubagentTranscript`), so each agent compacts a coherent per-agent slice. The summarizer retries transient failures (`:summarizer_timeout|:summarizer_exit|:summarizer_backend`, `summarizer_max_retries` additional attempts with `summarizer_retry_backoff_ms` backoff; `:summarizer_exception` is never retried). The handoff worker's reason/summary is injected additively into its system prompt (`Startup.inject_handoff_prompt/4`) so the transformer always keeps it. Lives in `lib/jido_claw/reasoning/compactor*`; hooks into the agent lifecycle via `JidoClaw.Agent.Defaults`'s `on_before_cmd/2` override on `{:ai_react_start, _}`. Cold readers (`Session.Worker`, `AgentView`, `JidoClaw.history/3`) use the `for_session_primary` view so sub-agent rows never surface in the chat-visible transcript; exports stay full-fidelity. (`Inspection` is not in this set — it reads `message_count` through the worker and request-scoped rows via `Message.by_request`, so it never renders the chat transcript directly.) Real `context_ref` lanes remain a no-op follow-up (the key shape is `"<identity>::<context_ref|default>"`).

Key divergences from Jidoka's shape:

* **Hook surface**: the live LLM rewrite goes through a `Jido.AI.Reasoning.ReAct.RequestTransformer` implementation, not `runtime_context` mutation. The transformer filters projected messages by `refs.request_id ∈ snapshot.summarized_request_ids` (cumulative set) and prepends a delimited *user-role* summary message after any leading system messages — no system-prompt mutation, preserving trust boundary.
* **Watermarking**: two handles — `last_summarized_sequence` (Postgres watermark, drives `Message.since_watermark/2` reads) and a cumulative `summarized_request_ids` set (drives transformer filter). Each re-compaction merges new source IDs and dedupes.
* **Boundary discipline**: turn-grouped (by `request_id`), not role-adjacency-based, because `:tool_call` / `:tool_result` rows are standalone in this codebase.
* **Forward-tagging**: `on_before_cmd` always injects `params[:extra_refs][:request_id]` so the live turn's projected messages will carry `refs.request_id` and be filterable by future compactions.
* **Config**: opts-keyword via `compaction: [...]` on `use JidoClaw.Agent.Defaults`, not a Spark DSL (T3-7 decision).
* **Summarizer bounds**: `Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, ...)` + 15s timeout + specific rescue clauses. Transient phases (`:summarizer_timeout|:summarizer_exit|:summarizer_backend`) retry up to `summarizer_max_retries` times with `summarizer_retry_backoff_ms` backoff; `:summarizer_exception` is never retried.
* **Trace surface**: `[:jido_claw, :compaction, :event]` already pre-wired in `Trace.Collector` (status mapping for `:summarized`/`:skipped` → `:completed`).

**Prior state (kept for historical context)**: `forge/context_builder.ex` has a hard-chop "max_chars trim" for resume prompts (compacting prior session history *into* a resume prompt — not the live thread). `conversations/tool_transcript.ex::result_summary/2` is a one-line preview of tool result content for DB storage.

**Where in jidoka**: V1: `lib/jidoka/compaction.ex` (~790 lines), `lib/jidoka/compaction/{config,prompt}.ex`. **V2 note (2026-06-11)**: compaction was removed entirely in the V2 rewrite — no module, no replacement context-windowing subsystem (`grep -i compaction` over V2's lib/ and guides is empty). The borrowed capability now lives on only in jido_radclaw.

**What** (V1, the borrowed shape): Summary-based compaction. (Originally a DSL `compaction do mode :auto; max_messages 60; keep_last 12; max_summary_chars 4_000 end` — late V1 removed the agent-DSL `compaction` section and kept the `mode`/`max_messages`/`keep_last`/`max_summary_chars` knobs runtime-side on `Jidoka.Compaction.Config`; V2 then deleted the subsystem outright.) On every `:ai_react_start` over threshold, runs a separate summarizer LLM call (the agent's own model or a configured one) with **previous-summary continuity** (each new summary sees the prior one), normalized into `%Jidoka.Compaction{summary, source_message_count, retained_message_count, status, ...}` and stored on `agent.state[@state_key]`. Preserves tool-call/tool-result adjacency at the retained boundary (`expand_tool_boundary/2`). Emits `[:jidoka, :compaction, :event]` traces. Manual `Compaction.compact/2` is also exposed. The original `Jido.Thread` stays intact — compaction only affects provider-facing messages for future turns.

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

**Status (2026-05-26)**: ADOPTED — all worker templates carry structured-output contracts. No `JidoClaw.Agent.Output` behaviour was ported (the original adoption sketch called for one); instead, jido_radclaw consumes upstream `Jido.AI.Output` directly via `use Jido.AI.Agent, output: %{schema, retries, on_validation_error}`. Verifier and Reviewer landed in `46e1f87`; Coder, Researcher, TestRunner, Refactorer, and DocsWriter completed the rollout. The family has since grown to 13 templates (2026-06-23..26: AR-4's Fixer, AR-8b's SketchBuild/SketchBuildExec/SketchReviewer, AR-8c's SystemExecutor/SystemVerifier), each shipping with a contract from birth; the recurring shapes are single-sourced in `JidoClaw.Agent.Workers.OutputSchema` (AR-5).

Key facts:

* **Engine**: `Jido.AI.Output` (deps), not a borrowed module. Each worker file in `lib/jido_claw/agent/workers/` adds an `output: %{schema: Zoi.object(...), retries: 1, on_validation_error: :repair}` keyword to its `use JidoClaw.Agent.Defaults` call. The macro plumbs that into `strategy_opts[:output]` as a compiled `%Jido.AI.Output{}` (`deps/jido_ai/lib/jido_ai/agent.ex:354,427`), which the ReAct strategy then enforces.
* **Validation site**: `Jido.AI.Reasoning.ReAct.Runner.finalize_output/4`, not Jidoka's `on_after_cmd` placement — same semantics: parse the model's last answer, either succeed, `:repair` once via a corrective re-prompt, or fail typed.
* **Per-worker shapes**:
  * **Verifier**: `verdict` (`:pass`/`:fail`), `confidence` (`:low`/`:medium`/`:high`), `reasoning`.
  * **Reviewer** (enriched 2026-06-25..27, AR-3/AR-7; shape now shared as `OutputSchema.reviewer_verdict/0` with SketchReviewer and SystemVerifier): `overall` (`:approve`/`:request_changes`/`:comment`), `summary`, `action_needed`, `findings[]` (`severity` and per-finding `confidence` as **string** enums — an atom enum would persist as `":error"` through `ComposerArtifact.Envelope.normalize/1` — plus `location`, `description`).
  * **Coder / Refactorer**: `status` (`:completed`/`:partial`/`:blocked`), `summary`, `files_changed[]`, plus `notes` and an optional `signals[]` string list (Coder, via `OutputSchema.coder_result/0` — self-reports `code-written`/`tests-ready` to the AR-2 route composer) or `improvements[]` (Refactorer).
  * **Researcher** (enriched 2026-06-26..27, AR-4/AR-7): `summary`, `status` (`:completed`/`:partial`/`:blocked` — a blocked planner is refused at the composer's mapper instead of fabricating a plan), `confidence`, `findings[]` (`topic`, `detail`, `references[]`, per-finding `confidence` string enum), optional `signals[]`.
  * **TestRunner**: `status` (`:passed`/`:failed`/`:error`), `summary`, `passed_count`/`failed_count` (both refined non-negative via `Zoi.gte(0)`), `failures[]` (`test`, `error`).
  * **DocsWriter**: `status`, `summary`, `files_changed[]`, `kinds[]` (enum of `moduledoc`/`typespec`/`readme`/`guide`/`inline_comment`/`other`).
  * **The 2026-06 additions**: Fixer carries `OutputSchema.fixer_result/0` (builder fields + a required `signals[]`), SystemExecutor `builder_result/0` (builder fields, no `signals`), the sketch builders the same builder shape via the shared `SketchWorker` base, and SketchReviewer/SystemVerifier the shared `reviewer_verdict/0`.
* **Artifacts sub-object**: every workflow-touching worker (Coder, Researcher, TestRunner, Refactorer, DocsWriter — joined in 2026-06 by Fixer, SystemExecutor, and the sketch builders) carries an `artifacts` sub-object with known optional keys (`url`/`port`/`files`) — that's the full wire contract the LLM sees (`ReqLLM.Schema` emits `additionalProperties: false`, so extras are forbidden by the JSON Schema injected into the prompt). The Zoi schema keeps `unrecognized_keys: :preserve` as **internal parse-time tolerance** so a defiant LLM emitting an unexpected key won't fail validation; the docs and prompt never promise that capability. Verifier and the reviewer-shaped judges (Reviewer, SketchReviewer, SystemVerifier) omit the sub-object (evaluator/reviewer roles — no produces metadata). A `Zoi.map(key_type, value_type)` was tried first but crashes in `Jido.AI.Output`'s zoi-input normalizer (`deps/jido_ai/lib/jido_ai/output.ex:372` only recognises `Zoi.Types.Map` field-mode); the sub-object form side-steps that and still satisfies the existing `inject_produces_instruction` vocabulary.
* **Workflow consumer (updated 2026-06-11, post-Reactor)**: `JidoClaw.Workflows.StepAction` was deleted in the Reactor migration; the consumer is now `JidoClaw.Skills.Steps.AgentRunner` (`lib/jido_claw/skills/steps/agent_runner.ex`), which projects `typed_output[:summary]` into `StepResult.result` (so `ContextBuilder.format_all`/skill result assembly see prose, not an inspected map) and merges `typed_output[:artifacts]` (stringified) into `StepResult.artifacts`. `JidoClaw.Reasoning.Output.extract_result/1` carries the `:summary`/`:reasoning` fallbacks. `inject_produces_instruction/2` (now on `AgentRunner`) is schema-agnostic — it tells the LLM to use the `artifacts` field when emitting structured JSON, or append a fenced `ARTIFACTS:` block otherwise, so workers without a schema still feed the regex extractor.
* **Trace surface**: `[:jido, :ai, :output, :start | :validated | :repair | :error]` wired in `JidoClaw.Trace.Collector` (`lib/jido_claw/trace/collector.ex`).
* **Swarm consumer**: `JidoClaw.Tools.GetAgentResult` consumes typed output via `JidoClaw.Reasoning.Output.typed_request_output/1` and `request_meta_output/1` (`lib/jido_claw/tools/get_agent_result.ex:80-81`).
* **Typed verdict parsing (updated 2026-06-11, post-Reactor)** lives in `JidoClaw.Skills.Steps.IterativeStep.parse_verdict/1` (`lib/jido_claw/skills/steps/iterative_step.ex` — moved from the deleted `Workflows.IterativeWorkflow`). It accepts both the typed `%{verdict: :pass | :fail}` shape from Verifier and the legacy free-form `VERDICT: PASS / FAIL` text. `JidoClaw.Reasoning.Certificates` only owns `parse_certificate/1` for fenced certificate JSON — a different artifact consumed by `Tools.VerifyCertificate`.

**Prior state (kept for historical context)**: `lib/jido_claw/reasoning/output.ex` was an `extract_output/1` helper pulling `:result`/`:answer`/`:conclusion` from heterogeneous reasoning-tool result shapes — coercion, not validation. The Jido.Action behaviour had per-tool input schemas (most NimbleOptions, three Zoi — `edit_file.ex`, `write_file.ex`, `shell/commands/jido.ex`) but no agent-level final-answer schema. The whole `JidoClaw.Agent.Workers.*` family returned free-form strings that downstream code parsed heuristically.

**Where in jidoka**: V1: `lib/jidoka/output.ex`, `lib/jidoka/output/{config,error,runtime,schema}.ex`. **V2 note (2026-06-11)**: the standalone Output module is gone; the concept survives as `Jidoka.Agent.Spec.Result` (`lib/jidoka/agent/spec/result.ex` — Zoi schema + `max_repairs`, default 1) declared via the agent DSL's `result` option, with repair-retry executed by the turn runtime (`lib/jidoka/turn/state.ex` emits a `result_repair_requested` event and injects a corrective user message; exhaustion returns `{:error, {:invalid_result, …}}`). Same semantics jido_radclaw consumes from upstream `Jido.AI.Output` — validate, repair N times, fail typed.

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

**Where in jidoka**: V1: `lib/jidoka/error.ex`, `lib/jidoka/error/normalize.ex` + `normalize/{common,context}.ex`. **V2 note (2026-06-11)**: survives nearly unchanged — still a Splode root (`lib/jidoka/error.ex`), now with `error/format.ex` and `normalize/{basic,helpers,runtime}.ex`. V2 converged on the same four classes jido_radclaw chose (`invalid`/`execution`/`config`/`internal` with `Internal.UnknownError`) — the "four classes instead of three" divergence above is now the shared shape.

Pairs naturally with hermes **T1-4** (FailoverReason classifier) — the Splode classes are the *taxonomy* layer; FailoverReason is the *recovery-action* layer above it.

---

## Tier 2 — Useful

### T2-1. Conversation-ownership handoff (`Jidoka.Handoff`)

**Status (2026-05-27)**: ADOPTED — mid-conversation ownership transfer is a first-class capability. The main agent carries `JidoClaw.Tools.Handoff` (tool #33, after `fetch_output` and `search_web` joined the registry), the REPL and `JidoClaw.chat/4` both route through `JidoClaw.Agent.Handoff.Router.resolve_session_owner/6` before every dispatch, and ownership survives process restarts via `Conversations.Session.metadata["current_agent_template"]`.

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
* **Tool context**: `JidoClaw.ToolContext` adds `:agent_template` as a canonical key alongside `:agent_id`. `:agent_id` is opaque runtime identity (`"handoff:<uuid>:<template>"`); `:agent_template` is the human-readable template name (`"reviewer"`, etc.) that the tool reads to derive `from_template`. `ToolContext.child/2` resets `:agent_template` to `nil` so swarm-spawned children aren't mis-attributed (they're not routed via the registry); since V2-1's per-template approval policy, spawn / follow-up / skill-step re-stamp the child's *own* template right after.
* **Telemetry**: `JidoClaw.Tools.Handoff` emits `[:jido_claw, :handoff, :event]` with `event: :applied | :error`. The slot was already wired into `JidoClaw.Trace.Collector` (`lib/jido_claw/trace/collector.ex:106`) as part of T1-1; this entry is the first emitter and `event_name_label(:handoff, …)` already labels rows by template.
* **Supervision**: `JidoClaw.Agent.Handoff.Registry` is started under `core_children` in `lib/jido_claw/application.ex:142`, alongside `SessionRegistry` and `TenantRegistry`.
* **Tests landed**: registry unit, router unit, public-API integration, conversations dispatcher integration, conversations routing integration, worker hydration cold-start, tool unit, plus a `test/support/handoff_dispatch_capture.ex` helper.

**Adoption divergences from the original sketch**:

* **Not returned as a directive**: the original sketch had `Platform.Session.Worker` interpret a `{:handoff, …}` directive returned from the tool. The shipped shape leaves `Session.Worker` ignorant of handoff — the Registry is the source of truth, and routing is resolved at the *next* turn's dispatch entry point (REPL + `run_chat_turn/8`) rather than mid-current-turn. The model's response to a `handoff` call is treated as a normal turn ending; the system prompt instructs the LLM to emit a brief acknowledgement only. This decoupling avoided invasive Session.Worker changes and made the tool composable with any future surface that calls `Router.resolve_session_owner/6`.
* **Registry key is `{tenant_id, runtime_session_id}`, not `conversation_id`**: jido_radclaw doesn't have a single `conversation_id` — the runtime carries `(tenant, runtime_session_id)` and the durable layer carries `session_uuid`. The Registry uses the runtime key (hot-path); the `%Handoff{}` struct also carries `session_uuid` so cold-start and durable mirror paths have a UUID handle.
* **Per-tenant scoping is implicit, not via a separate `Handoff.Registry` instance**: a single GenServer keyed by `(tenant, session)` covers the multitenant case without spawning per-tenant processes. `TenantRegistry` was not repurposed.
* **'main' is a sentinel, not a target**: the tool rejects `to_template: "main"`. `/reset` is the only path back to main. This keeps the durable metadata mirror unambiguous — an absent `current_agent_template` key always means "main".

**Where in jidoka**: V1: `lib/jidoka/handoff.ex` plus the `lib/jidoka/capability/handoff/` tree (`registry`, `capability`, `metadata`, `runtime`, `tool`) and a late-V1 `handoff/owner_store.ex`. **V2 note (2026-06-11)**: the capability tree is gone. V2 keeps `lib/jidoka/handoff.ex` as a 74-line Zoi data contract and makes ownership storage a pluggable behaviour — `Handoff.OwnerStore` (`owner/1`, `put_owner/2`, `reset/1`; configurable via `config :jidoka, :handoff_owner_store`) with an ETS-backed `OwnerStore.InMemory` default — wired to the agent as a tool source (`agent/tool_sources/handoff.ex` → `operation/source/handoff.ex`, which also carries `forward_context`). Routing future turns is explicitly the host application's concern in V2. jido_radclaw's Registry + durable `Session.metadata` mirror is, in V2 vocabulary, a Postgres-backed owner store — the shapes converged.

---

### T2-2. Surface-neutral view projection (`Jidoka.AgentView`)

**Status (2026-05-31)**: ADOPTED — the session-axis `%JidoClaw.AgentView{}` remains the canonical "what is this conversation agent doing?" projection, and the other runtime axes now have their own tenant-scoped canonical projections instead of being folded into the session view: `JidoClaw.SwarmView`, `JidoClaw.ForgeView`, `JidoClaw.WorkflowView`, and `JidoClaw.RuntimeOverview`. The UI, CLI, shell, and MCP surfaces that T2-2 claims to unify now read those views rather than directly stitching together `AgentTracker`, Forge sessions, workflow runs, or ad-hoc summaries. The macro, lifecycle callbacks, and `streaming_message` remain deliberate non-goals/placeholders — not gaps.

**Completion note (2026-05-31)**: the 2026-05-29 correction was the right direction. T2-2 is complete as a multi-axis view redesign, not as a mechanical migration of every surface onto `AgentView`. `AgentView` stays narrow and session-focused; swarm, Forge, and workflow status are first-class sibling views composed by `RuntimeOverview`.

Key facts:

* **Modules**: `lib/jido_claw/agent_view.ex` — `%JidoClaw.AgentView{}` struct + public `snapshot/2`, `list/2`, and `to_mcp_map/1`; `lib/jido_claw/swarm_view.ex`; `lib/jido_claw/forge_view.ex`; `lib/jido_claw/workflow_view.ex`; `lib/jido_claw/runtime_overview.ex`. No `use JidoClaw.AgentView` macro (the original sketch explicitly said *don't ship the macro*; the surfaces here only need the data shape, not Jidoka's ergonomics).
* **Identity vocabulary**: two ids on the struct — `:session_id` (runtime id = `Conversations.Session.external_id`, keys the live worker + handoff registry) and `:session_uuid` (`Conversations.Session.id`, the Postgres UUID for FK reads). Both are carried because cold-read callers may hold one but not the other.
* **Input forms**: `%{tenant_id, session_id}` map, `%Conversations.Session{}`, or `%Session.Worker{}`. Only the `%Session{}` form is permissive (returns `{:ok, …}` with no live worker); the map form is strict and needs a live worker or a resolvable `session_uuid`. Reserved errors: `:tenant_required`, `:session_not_resolved`, `:session_id_mismatch`, `:session_not_found`.
* **Status enum**: `:idle | :running | :awaiting_handoff | :awaiting_approval | :error | :hibernated | :agent_lost` (`:awaiting_approval` joined with V2-1's tool-approval gate, 2026-06-13), derived by cascade (trace `:failed`→`:error`, trace `:running`→`:running`, owner with `preamble_consumed?: false`→`:awaiting_handoff`, pending tool-approval case→`:awaiting_approval`, worker `:hibernated`/`:agent_lost`, else `:idle`). Worker `:active` is the normal idle lifecycle and is **not** mapped to `:running`. There is deliberately no `:done` — a long-lived session whose last trace completed is `:idle`; the terminal nuance (`:completed | :cancelled | :interrupted`) lives on a separate `:trace_status` field.
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

**Where in jidoka**: V1: `lib/jidoka/agent_view.ex` (~437 lines), `lib/jidoka/agent_view/{defaults,projection,run,start,turn_state}.ex`. **V2 note (2026-06-11)**: survives slimmed — `lib/jidoka/agent_view.ex` (384 lines) + `agent_view/events.ex` only; still a "surface-neutral UI projection", still a `use Jidoka.AgentView` macro with lifecycle hooks (`before_turn`/`after_turn`/`snapshot`). V2 struct: `agent_id, conversation_id, runtime_context, visible_messages, streaming_message, events, status (:idle | :running | :error | :interrupted | :handoff), error, error_text, outcome, metadata`. jido_radclaw ships the struct + `snapshot/2` shape only — none of the macro/lifecycle machinery (deliberate non-goal, unchanged by V2).

---

### T2-3. Subagent context-visibility policy (`forward_context`)

**Status (2026-05-29)**: ADOPTED — `forward_context` is a first-class, operator-controlled visibility policy enforced at every templated child-context build site. Default `:public` (forward the parent's full scope) means zero behavior change on landing; operators tighten an individual template by adding `forward_context: :none | {:only, [...]} | {:except, [...]}` to its map.

Key facts:

* **Policy mechanism**: `JidoClaw.ToolContext` carries the `visibility/0` type (`:public | :none | {:only, [atom()]} | {:except, [atom()]}`), a public `apply_visibility/2` (the single enforcement primitive — nulls the dropped keys, preserving `build/1`'s canonical shape), a `child/3` (apply-then-`child/2`), and `policy_controlled_keys/0` (the strippable-key universe). `{:only}`/`{:except}` are symmetric — both range only over `@policy_controlled_keys`.
* **Always-forward structural invariant**: the policy can strip only `[:user_id, :workspace_id, :workspace_uuid, :actor, :forge_session_key]`. `:tenant_id` (Ash multitenancy), `:session_id`/`:session_uuid` (request correlation + trace linkage), and `:project_dir` (child file tools) are never strippable — so a restrictive policy can't break correlation, tenancy, or a child's filesystem anchor. `register_child_correlation/1` keeps working because `:tenant_id`/`:session_uuid` survive.
* **Operator-controlled, not LLM-chosen**: the policy lives on the **template** (operator config), not a per-spawn LLM param — a real security boundary. It's identical across spawn / follow-up / workflow-step, so a child can't be re-widened mid-conversation. Policy keys stay atoms in source (no `String.to_atom` on untrusted input). A per-spawn LLM-override param is a documented future enhancement, not v1.
* **Enforced at three child-context build sites (updated 2026-06-11, post-Reactor)**: `Tools.SpawnAgent.register_spawned_agent/6` (spawn), `Tools.SendToAgent.send_to_agent/3` (follow-up — re-applies the policy every turn), and — since the Reactor migration deleted `Workflows.StepAction` — `Skills.Steps.AgentRunner` (`lib/jido_claw/skills/steps/agent_runner.ex`, the workflow/skill step runner: reads the template's `forward_context` and routes through `ToolContext.apply_visibility/2` before building the child context). All three keep `tool_context:` on the `ask`/`ask_sync` call, so the static-AST check in `tool_context_shape_test.exs` still passes.
* **Handoff routing is explicitly exempt**: `lib/jido_claw.ex` + `lib/jido_claw/cli/repl.ex` route the same conversation's existing `tool_context` to the owning worker. Handoff is an *ownership transfer*, not a freshly-built child — full-context continuity is its defining purpose — so `forward_context` deliberately does not apply. An explanatory comment sits at each routed-turn dispatch site.
* **Fail-closed validation**: `Agent.Templates.hydrate_template/1` defaults absent `:forward_context` to `:public` and validates the field — every `{:only,_}`/`{:except,_}` key must be a member of `ToolContext.policy_controlled_keys/0`. One membership check rejects both string keys (`{:only, ["user_id"]}`) and typo'd atoms (`{:except, [:usr_id]}` — which would otherwise fail OPEN for `:except`); any unknown key or malformed value logs a warning and fails closed to `:none`. `apply_visibility/2`'s catch-all also fails closed.

**Where in jidoka**: V1: `lib/jidoka/subagent.ex` plus the `lib/jidoka/capability/subagent/` tree. **V2 note (2026-06-11)**: the capability tree is gone, but **`forward_context` survives V2 intact** — same `:public | :none | {:only, […]} | {:except, […]}` shape, default `:public`, now declared on the DSL's subagent/handoff/workflow tool entities and enforced by `Operation.Source.Subagent` (likewise `…Handoff`/`…Workflow`) filtering the parent `Jidoka.Context` before the child turn; V2's 2026-06-08 context-boundary hardening commits tightened it further to forward only public context data. The full subagent shape stays SUPERSEDED by swarm (`Tools.SpawnAgent` + `Tools.GetAgentResult` + `AgentTracker` + worker modules — real OTP processes with bidirectional messaging); only the `forward_context` knob was the genuine gap, and it's closed.

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
* **`inspect_workflow/1`** takes a `%WorkflowRun{}` or UUID (via a new `define(:by_id, action: :read, get_by: [:id])` code interface). It is **local-callers-only** — not reachable through the `inspect_agent` MCP tool (see divergences). (The MCP tool *named* `inspect_workflow` — AR-2 Phase 5, 2026-06-22 — is a different surface: the route-composer run observer over `RouteComposer.Observe`, not this function.)
* **MCP tool**: `JidoClaw.Tools.InspectAgent` (new), tenant read strictly from `tool_context.tenant_id`. Nested terms are normalized through the shared `JsonSafe.encode/1`; top-level keys stay atoms to satisfy `output_schema`. `:memory` IS surfaced (it is tenant-scoped via `Scope.resolve`) but is slimmed at the boundary to `%{scope_kind, blocks_count}` — both the raw-UUID `scope` sub-map and the FK embedded in `namespace` are dropped, since a `"session:<uuid>"` namespace would leak the session UUID (notably on `kind: "request"`, where the caller supplied only a request id). Local Elixir callers keep the full `namespace`/`scope`. This contrasts with the fully-dropped `:subagents`/`:workflows`. (Cost note: `blocks_count` loads full Block rows to `length/1`; fine at current volumes, a dedicated `Ash.count/2` is a future optimization.)

**Adoption divergences from the original sketch**:

* **Leakage hygiene: the MCP tool drops `:subagents` and `:workflows` and refuses workflow dispatch entirely.** When this entry landed, `AgentTracker` and `WorkflowRun` were not tenant-scoped, so a tenant-facing tool that surfaced them (even `duration_ms`/`error`/an existence oracle) would have leaked cross-tenant runtime state. T2-2 has since tenant-scoped both sources and (2026-06-03) narrowed the tool's `kind` enum to `module|session|request` — the bare-id `auto`/`agent_id` dispatch modes were removed per the T2-2 plan, and scoped swarm/workflow status now ships via the dedicated `swarm_status`/`workflow_status` tools rather than by re-widening `inspect_agent`. Trusted local Elixir callers still see both fields and `inspect_workflow/1`.
* **Top-level `JidoClaw` delegates added** for full T2-4 parity with Jidoka's `Jidoka.inspect_*` surface (the sketch only called for the module).
* **The implementation went through a code-review remediation pass** (the `transient-greeting-locket` plan): five fixes — remove MCP workflow dispatch [P1], extract the shared `JidoClaw.Core.JsonSafe` normalizer + JSON-normalize the compaction sub-map [P2], fill in the PID + non-handoff agent-id running state (both were stubs returning bare `[]`/`request_id` only) [P2], fix a latent always-nil bug in the request-correlation resolver so wrong-tenant returns `:not_found` [P2], and read usage/error via `coalesce_field` [P3].

**Where in jidoka**: V1: `lib/jidoka/inspection/inspection.ex`, `lib/jidoka/inspection/debug.ex`, `lib/jidoka/inspection/prompt_preflight.ex`. The V1 `Debug.summary` field list was the adoption target; jido_radclaw's `Summary` copied the shape and sources it from `AgentTracker` + `Conversations` + `Trace` + `Compactor.Storage` + `Handoff.Registry`, sharing `model`/`status`/`user_message` with late-V1 while deliberately leaving out `input_message`/`prompt_preview`/`prompt_sections`/`mcp_errors` (no non-placeholder source here) and adding two of its own (`input_kind`/`resolved_at_ms`) — so jido_radclaw's 21-field `Summary` remains a stable subset-plus-two of the V1 target. **V2 note (2026-06-11)**: this surface *grew* in V2 — there is now a top-level `lib/jidoka/inspection.ex` (399 lines; backs a polymorphic `Jidoka.inspect/2` over specs/plans/turn results/snapshots/sessions/journals/reviews, and `Jidoka.preflight/3`, a prompt preview that assembles the prompt without interpreting effects) plus a data-only `lib/jidoka/debug.ex`: `Debug.request/2` → `%Debug.RequestSummary{request_id, agent_id, session_id, status, model, input, content, value, prompt, context_keys, operation_names, operation_results, memory, usage, timeline, journal, pending_reviews, diagnostics, replay_diagnostics, error, metadata}` (context *keys*, not values — leakage hygiene matching this entry's own MCP discipline) and `Debug.ReplayDiagnostics` ("are the journaled effects complete/safe to reason about without re-executing providers?" — `:complete | :waiting | :failed | :incomplete`). The replay-diagnostics idea has a natural future pairing with jido_radclaw's Reactor replay (`Orchestration.Replay`), which has its own fingerprint gate today.

---

### T2-5. Schedule kind switch (`:agent | :workflow`)

**Status (ADOPTED 2026-06-04)**: ADOPTED on the narrowed borrowed capability (scope below). `lib/jido_claw/cron/` + `lib/jido_claw/platform/cron/` is far more production-shaped than Jidoka's beta in-memory scheduler (multi-tenant, durable, Postgres-backed, failure-tolerant, auto-disable after 3 failures). The execution-target axis shipped in `77d852c`: `Cron.Job` carries `target :: :agent | :workflow | :mfa` orthogonal to `mode`, and `Cron.Dispatcher` routes legacy-first (`mode: :system_job` → MFA *before* `target` is read), so every pre-`target` row keeps working and new rows default to `target: :agent`. `:workflow` rows carry a skill name and drive a tracked `JidoClaw.Orchestration.WorkflowRun`. This plan closed the remaining items:

- **Durability counters across dispatch targets** — `run_count`/`last_run_at` stamped by the `:record_run` action after every tick for any persisted job (agent/workflow/mfa), best-effort so a DB hiccup never crashes the worker. (Durability = per-job counters across dispatch targets, not per-kind.)
- **Timezone-aware cron firing** — found during adoption: the worker hardcoded `DateTime.from_naive!(naive, "Etc/UTC")`, so `"0 9 * * *"` fired at 09:00 **UTC** regardless of the operator's zone. `Cron.Job.timezone` (IANA, default `"Etc/UTC"`) is now read through the pure `JidoClaw.Cron.NextRun` — a hard `try/rescue` boundary around crontab (which parses `@reboot` but then *raises* in the scheduler), with DST-correct fall-back (first occurrence) / spring-forward (instant after the gap) resolution. `"Etc/UTC"` short-circuits to byte-identical legacy behavior. Threaded through the `schedule_task` tool (strict validation), scheduler hydration, and both display surfaces (CLI `/cron`, `list_scheduled_tasks` — non-UTC only).
- **Target-aware telemetry** — cron events now carry `mode`, `target`, and the *effective* `dispatch_target` (via `Dispatcher.dispatch_target/1`, the single source of truth shared with routing), plus `tenant_id` on exceptions; the four cron metrics tag on `[:mode, :target, :dispatch_target]`. Fixes the consolidator (`mode: :system_job`, `target` defaulting to `:agent`) reporting `:agent` while actually running MFA.
- **Dead stuck-detection removed** — the `:check_stuck` handler could never fire (no timer scheduled it, status was never set `:running`, and synchronous dispatch blocks the GenServer during a tick); removed along with its misleading moduledoc claim.

**Borrowed capability (narrowed → ADOPTED)**: the execution-target dispatch axis (`:agent | :workflow | :mfa`), per-job durability counters across dispatch targets (`run_count`/`last_run_at`), and — closing the UTC-only bug found during adoption — timezone-aware cron firing. All shipped; the borrowed capability has no in-scope deferrals.

**NOT borrowed from Jidoka's `schedule/2` (out of scope, with rationale)**:

- `overlap: :skip | :allow` + `skip_count` — cannot occur under synchronous single-worker dispatch (a busy worker can't re-tick; the next `:tick` just queues). N/A by architecture.
- schedule history retention — low value; workflow-target runs are already recorded as `WorkflowRun`.

**Operational notes (not Jidoka features, so not "deferrals" of the borrow)**:

- stuck-detection — removed here (dead code); a real watchdog needs async dispatch (future work).
- multi-tenant boot-reload — **closed by WS4a (2026-06-29)**: `JidoClaw.Cron.Owner` now owns persisted user jobs cluster-wide, reconciling workers for *every active tenant* on the leader (single-node is trivially leader; the `"default"`-only `Scheduler.load_persistent_jobs/2` boot path is superseded).
- rich `/cron add … tz=…` input — deferred; the positional CLI syntax has no tz slot, so the timezone-aware entry point is the `schedule_task` agent tool (the CLI `/cron` help points there).

**Where in jidoka**: V1: `lib/jidoka/schedule.ex` (~375 lines), `lib/jidoka/schedule/{executor,manager}.ex`. **V2 note (2026-06-11)**: removed entirely in the V2 rewrite — no scheduler, no replacement. The borrowed execution-target axis lives on only in jido_radclaw's cron subsystem.

**What (V1 jidoka)**: `Jidoka.schedule/2` registers a chat schedule (calls `Jidoka.chat/3` on fire) or workflow schedule (calls `Jidoka.Workflow.run/3` on fire). `prompt`/`input`/`context` resolvers can be a function or MFA tuple. `overlap: :skip|:allow`, `timezone`, history retention.

---

### T2-6. Imported agent specs with allowlist registries (`Jidoka.ImportedAgent`)

**Status (2026-05-18; re-checked 2026-05-30)**: PARTIAL. `lib/jido_claw/platform/skills.ex` consumes YAML skills from `.jido/skills/*.yaml`, and `lib/jido_claw/agent/templates.ex` holds a static `@templates` map of the 7 `JidoClaw.Agent.Workers.*` modules (compiled-in, not file-imported, not allowlist-validated — there is no `priv/templates/` directory). But there's no equivalent for "import an agent definition from a file and validate it against an allowlist."

**Where in jidoka**: V1: `lib/jidoka/imported_agent.ex` (~310 lines) + `imported_agent/{definition,runtime_compiler}.ex` and subdirs `io/`, `registry/`, `runtime/`, `schema/`. **V2 note (2026-06-11)**: renamed and promoted — `Jidoka.Import` (`lib/jidoka/import.ex`, 278 lines, + `import/{agent_document,controls,decoder,normalize,registry,tools}.ex`) imports JSON/YAML into the same `Jidoka.Agent.Spec` the Spark DSL compiles to, with the same caller-supplied allowlist registries (actions, ash_resources, controls, catalogs, context/result schemas — anything executable must come from a registry) plus hardening knobs (`max_import_bytes/depth/nodes`). A new `Jidoka.Export` is the inverse (runtime values become registry refs), so specs round-trip. If the tenant-facing agent-builder need ever materializes here, V2's Import/Export pair is the reference shape to lift.

**What**: Imports an agent spec from JSON/YAML at runtime; tools, characters, skills, subagents, workflows, handoffs, plugins, hooks, guardrails are all resolved through explicit `available_*` allowlist registries passed at import time. Invalid imports fail loudly with structured errors. The constrained schema mirrors the DSL but is intentionally a subset.

**Gap**: Tenant-supplied agent specs are not currently a use case, but as the platform grows toward multi-tenancy, this becomes the natural shape for "user creates an agent in the web UI without writing Elixir."

**Why it matters**: Foundational for a tenant-facing agent-builder UI. The allowlist-registry pattern (rather than open module loading) is the right shape for security boundaries. Spec files round-trip cleanly between web UI / CLI / API.

**Adoption sketch**: Defer until there's a concrete need for tenant-supplied agents. When that need arises, lift the Jidoka import schema and adapt the registries to read from per-tenant `Agent.Templates` allowlists. Pairs with **T1-4 Error** (constrained imports need structured validation errors).

---

## Tier 3 — Polish

### T3-1. Splode-based hook/guardrail registration

**Where in jidoka**: V1: `lib/jidoka/hook.ex`, `lib/jidoka/guardrail.ex`, `lib/jidoka/lifecycle/{hooks,guardrails}.ex` (the lifecycle layer later absorbed V1's internal-Runic-workflow change). **V2 note (2026-06-11)**: hooks, guardrails, and the whole `lifecycle/` layer are gone, replaced by **Controls** — a `Jidoka.Control` behaviour (`name/0` + `call/1` returning `:allow | {:block, _} | {:interrupt, _} | {:error, _}`), built-ins (`MaxInputLength`, `RequireApproval`, `RequireContext`), a DSL `controls` section (`max_turns`, `timeout`, plus `input`/`output`/`operation` control entities with kind/name/source matching), and a **Review** subsystem where `{:interrupt, _}` durably hibernates the turn to a snapshot and `Jidoka.approve/deny` + `Session.resume` continue it.

**Status (2026-05-18; re-checked 2026-05-30; re-checked 2026-06-11)**: SUPERSEDED — and the jido_radclaw side moved too. `lib/jido_claw/security/redaction/` still has the nine scrubbers (Patterns, Env, PromptRedaction, Embedding, Memory, Transcript, UI, Channel, LogRedactor) — outbound serializers, not turn gates. The old `orchestration/approval_gate.ex` Ash resource was deleted in the Reactor migration; human approval is now the `orchestration/` gate/case family (`gates.ex`, `gate_step.ex`, `gate_resume.ex`, `gate_context.ex`, `human_gate.ex`, `cases.ex`, `agent_case.ex`) — Reactor-native pause/resume, still Postgres-backed and heavier than Jidoka's interrupt-and-resume. The verdict stands: the functionality is here; a unified-named-registry would be ergonomic, but the pieces don't share Jidoka's turn-gating semantics. Skip. (The *per-LLM-turn / per-tool-call* gating layer V2 built instead is inventoried separately as **V2-1** in [`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md) — that entry, not this one, tracks the adoption question.)

### T3-2. Plugin wrapper module shape

**Where in jidoka**: V1: `lib/jidoka/plugin.ex`. **V2 note (2026-06-11)**: removed — V2 has no plugin wrapper (it even passes `default_plugins: false` to `use Jido.Agent`).

**Status**: SUPERSEDED — and now moot upstream. jido_radclaw uses `Jido.Plugin` directly via `lib/jido_claw/agent_server_plugin/recorder.ex`. Adding another wrapper would be noise.

### T3-3. Character / persona DSL

**Where in jidoka**: V1: `lib/jidoka/character.ex` (used `jido_character`). **V2 note (2026-06-11)**: removed — the module and the `jido_character` dependency are both gone; V2 agents carry plain string `instructions`.

**Status**: N/A. Personas in jido_radclaw are baked into `Agent.Workers.*` modules and `priv/defaults/system_prompt.md`. The `.agents/skills/` SKILL.md tree (managed by `usage-rules`) is the conceptual analogue at a different level. Inverting the model isn't worth it.

### T3-4. Session descriptor struct

**Where in jidoka**: V1: `lib/jidoka/session.ex` (~468 lines). **V2 note (2026-06-11)**: reshaped — `Jidoka.Session` (176 lines) is now an ergonomic facade over `Jidoka.Harness.Session`, a serializable durable envelope (`schema_version, session_id, agent_id, spec, status, requests, snapshots, result, pending_reviews, error, metadata`) persisted through a `Harness.Store` behaviour, with `Harness.Replay` reconstructing timelines from it.

**Status**: SUPERSEDED. `Conversations.Session` (Ash resource, multitenant, Postgres) + `Platform.Session.{Supervisor,Worker}` (per-session OTP worker) already implement the durable, registered, supervised version. Jidoka's `Session` is what you'd use *if* you weren't backed by a database — and V2's store-behaviour version makes exactly that shape explicit.

(The previously-suggested `Session.chat_opts/2` polish is dead — V2 removed that helper.)

### T3-5. Spark-DSL'd workflows compiled to Runic graphs

**Where in jidoka**: V1: `lib/jidoka/workflow.ex` + `workflow/{build,codegen,definition,dsl,ref,runtime,step_action,spark_dsl}.ex`. **V2 note (2026-06-11)**: this is where V2 invested most — the workflow tree is now jidoka's largest subsystem: Spark-DSL'd (`workflow do … end` / `steps do … end`) or callback workflows compiled to Runic graphs, a parallel runtime (`:async` + `:max_concurrency`), per-step retry policies, workflow call-depth limits, and a sandboxed **Lua planner** (`Jidoka.Workflow.Lua.execute/2`: scripts call `jidoka.workflow({...})` to author bounded Runic DAGs over an allowlisted `Jido.Action.Catalog`, under a strict `Lua.Policy` — default 1.5s timeout, 12 calls, 6KB script, read-only actions required; Lua explicitly cannot drive the agent loop).

**Status (re-checked 2026-06-11)**: SUPERSEDED — but both sides moved. jido_radclaw replaced its hand-rolled workflow modules with **Reactor** (see `docs/exploration/squidie/REACTOR-ADOPTION.md`; Phases 0–5 shipped 2026-06-08..10): `lib/jido_claw/orchestration/` is now a Reactor engine with a durable workflow event log, human approval gates (the gate/case family), definition fingerprint + replay, read-models/graph viz, and live-run cancellation; skills compile onto it via `skills/compiler.ex` + `skills/steps/*`. The `workflows/{plan,iterative,skill}_workflow.ex` and `orchestration/approval_gate.ex` modules this entry previously pointed at are deleted. The verdict is unchanged in substance: jido_radclaw's Postgres/Ash/Reactor engine is more capable for the multi-tenant case than Jidoka's Runic-on-top wrapper. The genuinely novel V2 piece with no counterpart here is the Lua-authored-DAG surface (LLM-authored, policy-bounded workflow plans) — worth tracking, not borrowing yet.

### T3-6. Livebook helpers (`Jidoka.Kino`)

**Where in jidoka**: V1: `lib/jidoka/kino/{context_view,trace_view,log_trace,agent_view,chat}.ex` plus `kino.ex`, `logger_handler.ex`, `render.ex`, `runtime_setup.ex` (late V1 had already dropped `timeline.ex`/`call_graph.ex`). **V2 note (2026-06-11)**: `log_trace.ex` and `logger_handler.ex` are gone too; what remains is `kino.ex` + `kino/{agent_view,chat,context_view,render,runtime_setup,trace_view}.ex`, plus new debug helpers (`debug_agent`/`debug_request`/`preflight`/`agent_diagram`) riding the T2-4 Debug surface.

**Status**: N/A. jido_radclaw isn't a Livebook-centric library; the equivalent role is filled by Phoenix LiveViews and the CLI REPL.

### T3-7. Spark-based `agent do ... end` DSL

**Where in jidoka**: V1: `lib/jidoka/agent/{spark_dsl,dsl}.ex`, `lib/jidoka/agent/dsl/sections/`, compilers/verifiers; late V1 had already gutted the wide surface down to `contract`/`tools`/`controls`, with a `dsl/forbidden.ex` failing loudly on the removed macros. **V2 note (2026-06-11)**: V2 kept exactly that narrow footprint, cleaned up: sections are `agent` (id, model, generation, instructions, context schema, result schema, memory), `tools` (operation-source entities: `action`, `ash_resource`, `browser`, `mcp_tools`, `catalog`, `skill_ref`/`skill_path`, `subagent`, `handoff`, `workflow`), and `controls`; `forbidden.ex` is gone (V2 never had the wide surface to forbid), and three verifiers (`verify_agent`/`verify_controls`/`verify_tools`) guard it. Everything compiles to a data `Jidoka.Agent.Spec`, equally reachable without Spark via JSON/YAML import (T2-6).

**Status**: N/A. `lib/jido_claw/agent/agent.ex` (71 lines, `use JidoClaw.Agent.Defaults, name: ..., tools: [...]`) is a much simpler approach to a similar problem. Adopting Spark at this layer would be net-negative complexity. The V1→V2 arc sharpens that lesson rather than reversing it: upstream kept a DSL, but only as a thin authoring veneer over a serializable spec — spec-as-data, not the Spark surface, is the durable part. (Spark is already used elsewhere in jido_radclaw — via Ash and via internal DSLs — so the reason to skip remains fit, not capability.)

### T3-8. Chat streaming wrapper (`Jidoka.Chat.Stream`)

**Where in jidoka**: V1: `lib/jidoka/chat.ex`, `lib/jidoka/chat/stream.ex`. **V2 note (2026-06-11)**: survives as top-level `Jidoka.Stream` (`lib/jidoka/stream.ex` — an `Enumerable` over `Jidoka.Event`s with `text_delta/1`, `thinking_delta/1`, `await/2`; its moduledoc says it deliberately "mirrors the request-owned streaming shape from Jidoka v1 without depending on Jido.AI's internal event structs") plus `Jidoka.Chat.Request` (`chat/request.ex`), an async request handle.

**Status**: PARTIAL. jido_radclaw already streams via `Jido.AI.Request.Handle` and the various LiveView assigns. Jidoka's stream wrapper is useful sugar for CLI/script use but not load-bearing. Could be lifted as `JidoClaw.Chat.Stream` if the CLI REPL would benefit from a cleaner streaming surface — V2's event-struct-backed version (decoupled from Jido.AI internals) is now the better reference of the two.

---

## Cross-references and dependencies

The Tier 1 four and the first Tier 2 borrows cluster into a dependency graph. Under the strict ADOPTED standard (any deferral demotes to PARTIAL — ◐), the fully-adopted set is T1-1 Trace, T1-2 Compaction, T1-3 Output, T1-4 Error, T2-1 Handoff, T2-2 AgentView/projections, T2-3 Subagent context-visibility, and T2-4 Inspection (✓). (T2-3 stands outside the Trace cluster below — it depends on `ToolContext` + `Templates`, not Trace.) Jidoka's V2 rewrite changes none of these statuses — but two of the borrows (T1-2 Compaction, T2-5 Schedule) now outlive their source: V2 deleted both subsystems.

```
T1-4 Error ✓ ──┬──> T1-1 Trace ✓ ──┬──> T2-2 AgentView/projections ✓
               │                    ├──> T2-4 Inspection ✓ (:memory now sourced)
               │                    └──> T2-1 Handoff ✓ (emits trace events)
               ├──> T1-2 Compaction ✓ (per-agent keying + retries; all 13 workers + sub-agents compact)
               └──> T1-3 Output ✓ (emits trace events)
```

**First wave**:

1. **T1-4 Error** — ADOPTED. Splode root with four classes (`invalid`, `execution`, `config`, `internal`), merging with `Ash.Error`.
2. **T1-1 Trace** — ADOPTED. `JidoClaw.Trace` + `Trace.Collector` + `TraceRun`/`TraceEvent` Ash resources for durable replay.
3. **T1-2 Compaction** — ADOPTED 2026-05-30. `JidoClaw.Reasoning.Compactor` + `RequestTransformer`; per-key Postgres snapshots in `Session.metadata["compactions"][key]`. Per-`{agent_id, context_ref}` keying + summarizer retries closed; all 13 worker templates + handoff/spawned sub-agents compact on their own slices (durable transcripts completed via `SubagentTranscript`).
4. **T1-3 Output** — ADOPTED 2026-05-26. All 13 worker templates carry structured-output contracts via upstream `Jido.AI.Output` (recurring shapes single-sourced in `Workers.OutputSchema`).

**Tier 2 sequencing** (T1-1/T1-2/T1-3/T1-4 ADOPTED; T2-1 ADOPTED 2026-05-27; T2-3 + T2-4 ADOPTED 2026-05-29; T2-2 ADOPTED 2026-05-31; remaining items unblocked):

- **T2-4 Inspection** — ADOPTED 2026-05-29. Agent-axis summary (`JidoClaw.inspect_*` delegates + `inspect_agent` tool); the four-source stitching is unified inside one function and works across all input kinds. The last placeholder, `:memory`, is now sourced from `Memory.namespace_info/1` on the three rich builders (the thin map path / MCP `kind: "session"` stays `nil` by design, parallel to `:compaction`; MCP slims `:memory` to `{scope_kind, blocks_count}` — no raw FK/UUID).
- **T2-3 Subagent context-visibility** — ADOPTED 2026-05-29. Operator-controlled `forward_context` policy on the template, enforced at spawn / follow-up / workflow-step via `ToolContext.apply_visibility/2`; structural keys (`tenant_id`/`session_*`/`project_dir`) are always forwarded; handoff routing is exempt; fail-closed validation in `hydrate_template`; `:public` default = zero behavior change on landing.
- **T2-2 AgentView/projections** — ADOPTED 2026-05-31. Session-axis `AgentView` remains canonical for conversations; sibling `SwarmView`, `ForgeView`, `WorkflowView`, and `RuntimeOverview` cover the remaining axes. UI/CLI/shell/MCP surfaces now consume tenant-scoped views or scoped ownership checks, and MCP exposes `agent_status`, `swarm_status`, `forge_status`, and `workflow_status`.
- **T2-5 Schedule kind** — ADOPTED 2026-06-04. Execution-target axis (`:agent | :workflow | :mfa`) + per-job durability counters + timezone-aware cron firing (`Cron.NextRun`) + target-aware telemetry; dead stuck-detection removed. Borrowed capability narrowed so it has no in-scope deferrals (overlap/`skip_count` + schedule-history retention explicitly out of scope — see T2-5).
- **T2-6 Imported agents** — defer until tenant-builder UI is on the roadmap.

## Relationship to hermes exploration

This doc and `docs/exploration/hermes/FEATURES-WORTH-BORROWING.md` are complementary, not redundant:

- **hermes T1-2 (compaction)** → **deprecated by Jidoka T1-2** as the adoption sketch. Jidoka's Elixir-native shape is the right target; hermes's `protect_first_n` knob remains a paired discipline.
- **hermes T1-4 (FailoverReason)** → **layers above Jidoka T1-4 Error**. Splode classes are taxonomy; FailoverReason is recovery-action policy.
- **hermes T2-9 (diagnostic registry)** → **builds on Jidoka T1-1 Trace** as the backing store.

Jidoka T1-1, T1-2, T1-3, and T1-4 are all ADOPTED — re-evaluate hermes T1-2 (`protect_first_n` paired discipline), T1-4 (FailoverReason recovery-action layer above Splode), and T2-9 (diagnostic registry backed by the trace surface) next.

## Notes on upstream alignment

Because Jidoka is written by the creator of `jido`, the patterns here also hint at where the upstream framework is heading. The V2 rewrite (2026-05-29 →) is itself the strongest signal yet; the original predictions re-read through that lens (revised 2026-06-11):

1. **Telemetry event taxonomy — prediction revised.** V1's `[:jidoka, :{category}, :event]` telemetry shape did *not* survive: V2 dropped telemetry-as-transport entirely in favor of a first-class `Jidoka.Event` struct (~30 named events) flowing through `Trace.Sink` behaviours under a `Trace.Policy` (redaction + deterministic sampling as data). The durable bet is "events are data, with policy-controlled sinks" — not any particular `:telemetry` atom topology. jido_radclaw's `Trace.Collector` still rides `:telemetry` (correct here: that's what `jido_ai` emits today); the sink/policy half of that bet has since been adopted locally (`Trace.Policy` data + a `Trace.Sink` behaviour — **V2-3**, ADOPTED 2026-06-16), leaving only the telemetry-as-transport half as the piece to revisit if upstream `jido` drops it for a first-class event struct.
2. **Output/Trace integration surface — prediction partly wrong.** The guess was that the `on_before_cmd`/`on_after_cmd` plugin-pair would become the upstream-blessed pattern. V2 went the other way: it *owns the loop* — a Runic "turn spine" of pure phase functions plus an effect interpreter, with jidoka's AGENTS.md explicitly forbidding `Jido.AI.ReAct` as loop owner — and folds output-repair into the turn runtime (`Agent.Spec.Result` + `max_repairs`). jido_radclaw's reliance on upstream `Jido.AI.Output` + ReAct request transformers remains correct for *this* codebase (it sits on `jido_ai`'s loop), but expect churn here if `jido_ai` ever absorbs V2's effect-journal/deterministic-replay runtime. That journal/replay design also rhymes with what jido_radclaw independently built on Reactor (workflow event log, fingerprint + replay) — convergent evolution worth keeping an eye on.
3. **Schema library convergence on Zoi — confirmed.** V2 is Zoi-exclusive (`zoi ~> 0.18`) for specs, events, and import/export schemas; `jido_action` 2.x uses Zoi for its own internal metadata schemas, and `Jido.Action.schema` officially accepts both `NimbleOptions` and Zoi. The guidance stands: **for LLM-facing schemas** (tool I/O, agent Output, Context), prefer Zoi — it composes pipeline-style, natively emits JSON Schema for provider structured-output modes, and matches the upstream pattern; **for internal config validation** (worker init, registry args, `Cron.Job` options), NimbleOptions remains idiomatic. jido_radclaw already mixes both styles (NimbleOptions for most tools; Zoi for `edit_file.ex`, `write_file.ex`, `shell/commands/jido.ex`, and the worker output schemas) — the mixed state is fine because both are first-class. Caveat: Zoi is still 0.x (jido_radclaw locks 0.18.4); API may shift, so pin carefully.
4. **Agent-DSL contraction — confirmed, with a twist.** Late V1's hard-removal stuck: V2 stabilized on exactly three sections (`agent`/`tools`/`controls`). But the deeper V2 move is *spec-as-data* — the DSL is just one author of a serializable `Jidoka.Agent.Spec` that JSON/YAML import produces equally. This still validates T3-7's decision to skip Spark at the agent layer; the part worth watching now is the spec/import/export triangle (T2-6), not the DSL syntax.
5. **New (2026-06-11): controls + interrupt/hibernate/resume as the safety surface.** V2 replaced hooks/guardrails with `Jidoka.Control` decisions (`:allow | {:block, _} | {:interrupt, _}`) where an interrupt durably hibernates the turn as a snapshot pending `approve/deny`, then resumes. jido_radclaw's Reactor gate/case family covers the workflow-step case; a *per-LLM-turn / per-tool-call* control point (snapshot-hibernate, not a blocked process) has no equivalent here and is the most interesting new borrow candidate to come out of V2 — now inventoried as **V2-1** (Tier 1) in [`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md).
