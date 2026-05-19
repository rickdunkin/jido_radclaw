# Features Worth Borrowing from Hermes-Agent

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/hermes-agent` (Nous Research, Python 3.11+ self-improving agent platform). Initial inventory 2026-04-28; **re-reviewed 2026-05-18** against current state of both projects.

## Re-review summary (2026-05-18)

Original inventory had 39 numbered items (10 Tier-1, 10 Tier-2, 12 Tier-3, 7 Open Questions) plus three appendices. Since 2026-04-28:

- **Adopted outright**: 0 items closed end-to-end. Two appendix items moved to **SUPERSEDED** because jido_radclaw chose a different approach (Forge multi-runner abstraction; Postgres-backed Forge checkpoints).
- **Partially adopted**: 9 items. Highlights: **T1-7 frozen-snapshot half landed** via `Prompt.build_snapshot/2` on `Conversations.Session.metadata["prompt_snapshot"]` + `anthropic_prompt_cache: true` worker opt-in. **T1-9 FTS infrastructure landed** on Message rows (GIN index `messages_search_vector_idx`) but no session-search tool. **T1-10 cluster-shared rate-limit pattern proven** for Voyage embeddings (`Embeddings.RatePacer` + `dispatch_window` table), not generalized to LLM providers. **T2-6 frozen-snapshot discipline adopted**, swappable `Memory.Provider` ABC not. Tracked under each entry's Status line.
- **Hermes refactored**: 9 entries need a re-read at adoption time. Biggest: **T1-9 deleted the aux-LLM summarizer entirely** — single-shape tool with discovery/scroll/browse modes returns SQLite content directly. T2-3 is no longer a prerequisite for T1-9. T2-3 itself gained a **4-step layered fallback ladder** (primary aux → user-configured `fallback_chain` → main-agent safety net → warn). T1-7's "system_and_3" naming is dated — 1h prefix-cache layout was tried and removed in favor of byte-static-system-within-session discipline. OQ-1's `run_agent.py` was decomposed into ~13 modules.
- **New entries**: 14 new candidates (1 Tier-1, 7 Tier-2, 6 Tier-3) covering orchestrator-driven auto-decomposition, gateway deliverable mode, ACP edit approval, Codex app-server runtime, the ABC-plus-registry plugin pattern, curator, persistent `/goal` loop, post-write delta-lint, install-method stamping, Windows bootstrap discipline, multi-project boards, diagnostic registry, cross-platform `/handoff`, xAI OAuth.

The full first-wave recommendation has shifted: see "Cross-references and dependencies" near the bottom.

## Status legend

For each entry, two new header lines appear under the title:

- **`Status (2026-05-18)`** — jido_radclaw side. One of:
  - **ADOPTED** — feature or clear functional equivalent now lives in jido_radclaw
  - **PARTIAL** — some pieces landed; refreshed "Gap" tracks what's left
  - **NOT_ADOPTED** — no evidence of the feature; entry stands as written
  - **SUPERSEDED** — gap closed by a different approach (often a jido_radclaw-native shape that doesn't translate hermes's design)
  - **N/A** — original entry was a skip recommendation

- **`Hermes (2026-05-18)`** — only present when hermes-side code changed materially since 2026-04-28. Points at the new location and notes any behavior delta. If absent, the entry's file paths and behavior are unchanged.

## How to read this document

Each entry is ranked by impact × fit × adoption ease for **this** project. Tiers:

- **Tier 1** — clear gap, high leverage, achievable adoption. Strong candidates for actual work.
- **Tier 2** — useful, but requires more design or infra investment, or addresses a less acute gap.
- **Tier 3** — ergonomics or polish; nice to have but not load-bearing.

For each item:

- **Where in hermes** — file paths so you can dive into the source.
- **What it does** — 1–3 sentences.
- **Gap in jido_radclaw** — what we don't have that this would supply.
- **Why it matters** — the case for adoption.
- **Adoption sketch** — high-level shape of what borrowing this would look like in jido_radclaw's idioms (OTP, Ash, Jido). Not a plan — just the broad outline.

Hermes is a single-process Python agent — its concurrency model is `ThreadPoolExecutor` + asyncio. jido_radclaw runs on the BEAM with libcluster, OTP supervision, and signals. **Borrowing means translating, not transplanting.** Most of these concepts will look quite different once they're idiomatic Elixir/Jido.

---

## Tier 1 — High Impact

### T1-1. Programmatic Tool Calling (PTC)

**Status (2026-05-18)**: NOT_ADOPTED. No `JidoClaw.Tools.RunScript`, no `jido_tools.{ex,exs,py}` stub generator. Forge runners (`claude_code.ex`, `codex.ex`, `shell.ex`, `custom.ex`, `fake.ex`, `workflow.ex`) host external CLI tools but no LLM-authored-script-batches-its-own-tool-calls pattern.

**Hermes (2026-05-18)**: UNCHANGED. RPC calls in `tools/hermes_tools` are now serialized to prevent races (19f9be1df); Vercel Sandbox was added as a 6th execution backend alongside Local/Docker/Modal/SSH/Daytona/Singularity (5a1d4f680).

**Where**: `tools/code_execution_tool.py`

**What**: Generates an `hermes_tools.py` stub that exposes the agent's tools as RPC-callable functions. The LLM writes a Python script that orchestrates multiple tool calls; only stdout returns to the LLM. Two transports: UDS for local, file-based RPC for Docker/SSH/Modal/Daytona/Singularity. Sandbox-allowed list (`web_search`, `web_extract`, `read_file`, ...).

**Gap**: jido_radclaw has Forge for sandboxed execution of _user-provided_ code, but no pattern for the LLM to write a script that batches its own tool calls in a single inference turn.

**Why it matters**: This is the single biggest token/latency lever in the inventory. A 10-tool-call investigation collapses to 1 inference turn. Intermediate tool results never enter LLM context, so context bloat shrinks dramatically. Forge already exists as the sandbox host — we have ~80% of the infrastructure.

**Adoption sketch**: New `JidoClaw.Tools.RunScript` action. Forge's runner hosts a Python (or Elixir) process; before launch, generate a `jido_tools.py` (or `.exs`) stub mapping each existing `Jido.Action` to an RPC call. The agent process runs an Elixir RPC server on a UDS socket; the script makes synchronous calls into it. Reuse Forge's sandbox boundary for isolation. Allowlist tools per call (mirrors hermes's sandbox set). Open question: do we ship Python in Forge for richer LLM script-writing, or stick with Elixir and accept smaller training-data coverage?

---

### T1-2. Layered context compaction with structured handoff

**Status (2026-05-18)**: NOT_ADOPTED. No `JidoClaw.Reasoning.ContextEngine`, no compactor, no model-facing tool-result summarizer. `conversations/tool_transcript.ex::result_summary/2` is a one-line preview for the Postgres transcript `content` column, not a compaction handoff. The Forge `context_builder.ex::max_chars` trim ("truncated to fit token budget") is a hard chop, not a structured handoff.

**Hermes (2026-05-18)**: REFACTORED. New `protect_first_n` configurable knob on the `ContextEngine` ABC (dee71a31e, 4ceab1689). Historical media stripping after compression added (3b3909690 — port of Kilo-Org/kilocode#9434) — adoption sketch should include this as a paired discipline. Iterative summary-continuity, content-filter softening, and tail-protection fixes; nothing structural changed.

**Where**: `agent/context_compressor.py`, `agent/context_engine.py`, `agent/manual_compression_feedback.py`

**What**: A pluggable `ContextEngine` ABC. Pre-pass replaces tool-output dumps with one-line summaries (`[terminal] ran 'npm test' -> exit 0, 47 lines output`) before the LLM ever sees them. Then a structured summary template ("Resolved/Pending/Active Task/Remaining Work") with an explicit `SUMMARY_PREFIX` warning the model: "treat as background, your task is in `## Active Task`, don't re-execute." Token-budget tail protection. Image cost (`_IMAGE_TOKEN_ESTIMATE = 1600`) included. Iterative summary updates across multiple compactions. New: `protect_first_n` lets the engine keep the first N messages intact across compactions (useful for tool-defining preambles). Historical media stripped on compression to avoid image-token bloat.

**Gap**: No compaction system exists in jido_radclaw. Long sessions hit context limits with no graceful degradation.

**Why it matters**: Without structured handoff, compaction either drops information silently or causes the model to re-execute work. The "Resolved/Pending/Active Task/Remaining Work" structure (deliberately not "Next Steps", which the model reads as imperatives) plus the explicit "this is background, not your assignment" prefix is hard-won prompt engineering.

**Adoption sketch**: New `JidoClaw.Reasoning.ContextEngine` behaviour with `compress/2`, `summarize_tool_result/2`, `handoff_template/1`, and a `protect_first_n` option. Plug into the agent's pre-LLM-call step. Existing reasoning subsystem (`lib/jido_claw/reasoning/`) gives a natural home — it already has classifier, telemetry, certificates. Default implementation: `JidoClaw.Reasoning.Compactor.Default`. Pair with a historical-image-strip pass before each compaction. Future: an LCM-style alternative.

---

### T1-3. Subdirectory hint discovery

**Status (2026-05-18)**: NOT_ADOPTED. `agent/prompt.ex::load_jido_md/1` loads exactly one project file (`.jido/JIDO.md`) at session start. No ancestor walking, no AGENTS.md/CLAUDE.md/.cursorrules discovery, no HintTracker, no path events from `Tools.ReadFile`/`Tools.RunCommand`/etc.

**Where**: `agent/subdirectory_hints.py`

**What**: As tools are called with paths (`read_file`, `terminal`, etc.), this tracker walks ancestor directories (up to 5 levels) and lazily loads any `AGENTS.md`/`CLAUDE.md`/`.cursorrules` it hasn't seen yet, appending the content to **the tool result** (not the system prompt — so prompt cache stays valid). Inspired by Block/goose. Dedup via `_loaded_dirs` set.

**Gap**: jido_radclaw appears to load `JIDO.md` once at startup. Subprojects in monorepos with their own conventions get ignored.

**Why it matters**: Real-world repos have nested AGENTS.md files (a backend monorepo, a frontend submodule, a test fixture's README). Without progressive discovery the agent operates with stale or missing context for any directory it didn't start in. Bonus alignment: jido_radclaw already disciplines the system prompt as a frozen snapshot (T1-7 PARTIAL); appending hints to tool results preserves that invariant.

**Adoption sketch**: A `JidoClaw.Agent.HintTracker` GenServer keyed per session. Path-bearing tools (the `Tools.RunCommand`, `Tools.ReadFile`, `Tools.EditFile`, etc.) post path events; the tracker walks ancestors and emits at most one `[Project hint: <path>]` block appended to the tool result. ETS-backed loaded-set per session. Cache-friendly (system prompt never mutates).

---

### T1-4. Structured error classifier with `FailoverReason` taxonomy

**Status (2026-05-18)**: NOT_ADOPTED. `grep -rli "FailoverReason\|classify_error\|ErrorClassifier"` over `lib/` returns nothing. `lib/jido_claw/providers/` contains only `ollama.ex` (a thin `use ReqLLM.Provider` wrapper). No `%ClassifiedError{}` struct anywhere.

**Hermes (2026-05-18)**: REFACTORED. New timeout-message pattern catalog: `_TIMEOUT_MESSAGE_PATTERNS` classifies "timed out", "deadline exceeded", "request timed out", "upstream timed out", "turn timed out" as `FailoverReason.timeout` (4f8d8ad91). Taxonomy is otherwise unchanged.

**Where**: `agent/error_classifier.py` (1000+ lines)

**What**: A `FailoverReason` enum (auth/billing/rate_limit/overloaded/context_overflow/payload_too_large/image_too_large/model_not_found/provider_policy_blocked/thinking_signature/long_context_tier/format_error/timeout/...). `classify_api_error()` runs a priority pipeline (HTTP status → message patterns → SSL/transport heuristics → fallback) and returns a `ClassifiedError` with action booleans: `(retryable, should_compress, should_rotate_credential, should_fallback)`. The retry loop just consults flags — no inline string matching.

**Gap**: No equivalent in jido_radclaw. Provider error handling is presumably scattered through `Jido.AI` adapter code.

**Why it matters**: As provider count grows, decision logic for "retry vs compact context vs rotate key vs fall back to a different model" gets tangled across modules. A single taxonomy keeps recovery decisions cohesive and testable. Pairs naturally with the reasoning subsystem's certificate templates and telemetry. Foundation for T1-10 (rate guard consumes `rate_limit`), T2-2 (credential pool consumes `should_rotate_credential`), T1-2 (compactor consumes `should_compress`).

**Adoption sketch**: New `JidoClaw.Providers.ErrorClassifier` module. Public API: `classify(error_or_response) :: %ClassifiedError{reason: atom, retryable?: bool, should_compress?: bool, should_rotate_credential?: bool, should_fallback?: bool}`. Provider adapters (or `Jido.AI`'s retry path, depending on where the seam is cleanest) consult flags. Reasons emitted as telemetry events for the existing telemetry pipeline. Include the timeout-message subcatalog from hermes's 2026-05 expansion.

---

### T1-5. Context-file injection scanning

**Status (2026-05-18)**: NOT_ADOPTED. No `JidoClaw.Security.PromptScrubber`. `lib/jido_claw/security/redaction/` has scrubbers for *outbound* secrets (Patterns/Env/PromptRedaction/Embedding/Memory/Transcript/UI/Channel) but no *inbound* prompt-injection detector. VFS resolver (`lib/jido_claw/vfs/resolver.ex`) returns fetched content directly without scanning.

**Hermes (2026-05-18)**: UNCHANGED. Adjacent: tool-use enforcement guidance was extended to GLM (afa5b8191) and Grok / xai-oauth (9b91377be); system prompt now enriches environment hints with host + terminal-backend info (40e7a71c3). Scrubber itself is unchanged.

**Where**: `agent/prompt_builder.py::_scan_context_content`, threat patterns at top of file

**What**: Before injecting `AGENTS.md`/`CLAUDE.md`/`SOUL.md`/`.cursorrules` into the system prompt, scan for prompt-injection patterns: `ignore previous instructions`, hidden Unicode (`​/⁠/﻿`), `<div style=display:none>`, `<!--ignore...-->`, `curl ... $TOKEN`, etc. If any pattern hits, replace content with a `[BLOCKED: <reason>]` marker. Same scan applies to memory writes (`tools/memory_tool.py`).

**Gap**: jido_radclaw's VFS routes `github://`, `s3://`, `git://` to backends. Anything fetched via these URLs could carry a prompt-injection payload that flows directly into the agent's context. No equivalent scrubber today.

**Why it matters**: Prompt injection is increasingly weaponized (poisoned READMEs in dependency packages, malicious comments in fetched gists). Direct security hardening with low blast radius — we just refuse to inject suspect content. Aligned with the personal-tailnet threat model (LLM-misbehavior + leakage hygiene is the focus, not external attackers).

**Adoption sketch**: New `JidoClaw.Security.PromptScrubber` module — regex set + Unicode invisible-char detection. Public API: `scan(content) :: {:ok, content} | {:blocked, reason}`. VFS fetchers (`JidoClaw.VFS.Resolver` and backends) call it before returning content destined for prompt injection. Memory writes (`Tools.Remember`) also call it. Lift the regex set verbatim from hermes — the patterns are well-curated.

---

### T1-6. Anthropic-style SKILL.md with progressive disclosure

**Status (2026-05-18)**: PARTIAL. SKILL.md files with YAML frontmatter (name/description/metadata) and `references/` trees exist under `.agents/skills/<name>/SKILL.md` (ash-framework, jido-framework, phoenix-framework, skill-creator, update-elixir-deps, react-doctor, ...) — managed by `usage-rules`. But these are consumed by Claude Code's harness `Skill` tool, not by the JidoClaw agent. JidoClaw skills (`.jido/skills/*.yaml`) remain DAG pipelines via `platform/skills.ex`. No `knowledge_list`/`knowledge_view` tools on the JidoClaw side.

**Gap (refreshed)**: SKILL.md format is in use locally for Claude Code, but the JidoClaw agent has no progressive-disclosure surface into it. Need JidoClaw-side `Tools.KnowledgeList`/`Tools.KnowledgeView` (or a similar pair) and a registry path the JidoClaw agent can consult, distinct from the existing DAG-skill registry.

**Hermes (2026-05-18)**: UNCHANGED in structure. Reload-cache plumbing added (`/reload-skills` slash command + `skills_reload` agent tool, 7966560fb). Symlinked skill slash commands now load (ff078738e). New trusted registries default — `huggingface/skills` added alongside `openai/skills` and `anthropics/skills` (e0e4856d4). Write-protection on pinned skills (c61b2e0af).

**Where**: `tools/skills_tool.py`, `tools/skills_hub.py`, hundreds of `skills/<name>/SKILL.md` files

**What**: Each skill is a directory with:

- `SKILL.md` — YAML frontmatter (`name`/`description`/`platforms`/`metadata.hermes.config`/`tags`) + body
- `references/` — loaded on demand via `skill_view("name", "references/api.md")`
- `templates/`, `scripts/`, `assets/`

Tier 1 = `skills_list` (metadata only — budget-friendly). Tier 2 = `skill_view` (loads SKILL.md body). Tier 3 = `skill_view("name", "references/...")`. Frontmatter declares config requirements (auto-prompted in setup, auto-injected as `[Skill config: ...]` block at load).

**Why it matters**: Procedural knowledge ("here's the right way to add a new Ash resource") is the wrong fit for a DAG. It's the right fit for progressive-disclosure markdown the agent reads when needed. Anthropic ships their own SKILL.md format; aligning with the de-facto standard means we benefit from public skill libraries. We already maintain SKILL.md content for Claude Code — surfacing the same files to the JidoClaw agent is a smaller lift than starting from scratch.

**Adoption sketch**: Distinct from existing pipeline-skills. Add a flavor field to skill metadata (`kind: pipeline | knowledge`) or a separate `.jido/knowledge/` directory (could share the existing `.agents/skills/` tree via symlink, mirroring hermes's symlinked-skill loader fix). New tools: `knowledge_list` (returns frontmatter only) and `knowledge_view(name, ?path)`. Existing skill executor and DAG semantics unchanged. Optional: skill-config auto-injection in main agent prompt.

---

### T1-7. Anthropic prompt-caching discipline

**Status (2026-05-18)**: PARTIAL. **Frozen-snapshot half landed** in the "Memory: Consolidator Runtime & Frozen-Snapshot Prompt" + "Conversations: chat transcripts in Postgres" commits: `agent/prompt.ex::build_snapshot/2` (lines 287–315) drops "fields that change between turns or sessions (active-agent count, current git branch)" and is persisted on `Conversations.Session.metadata["prompt_snapshot"]` via the `set_prompt_snapshot` action (`conversations/resources/session.ex:119–134`) at session creation (`resolver.ex:23–30`). Worker template opts into Anthropic prompt caching at `agent/agent.ex:51` (`llm_opts: [provider_options: [anthropic_prompt_cache: true]]`). **Missing**: explicit `cache_control` breakpoint placement code; AGENTS.md "Prompt cache invariants" section; slash commands defaulting to deferred with `--now` opt-in.

**Gap (refreshed)**: The snapshot is built and persisted, but breakpoint placement is whatever `Jido.AI` defaults to — no audit that the 4 Anthropic breakpoints are being used optimally. Slash commands in `cli/commands.ex` mutate session state directly without deferred-by-default discipline. The cultural invariant isn't codified in AGENTS.md so PRs aren't reviewed for cache hygiene.

**Hermes (2026-05-18)**: REFACTORED. The "system_and_3" name in the original entry is out of date. A 1h cross-session prefix-cache layout shipped (7b7636655: `tools[-1] 1h + system[0] 1h + messages[-2] 5m + messages[-1] 5m`; within-session rolling shrank from 3 to 2 to free a breakpoint) — then b06e99930 **removed** the long-lived prefix layout once the system prompt was made byte-static within a session. Net current discipline: keep the system prompt byte-stable, use the 4 breakpoints at the rolling positions, rely on Anthropic's full-prefix cache for cross-turn hits.

**Where**: `agent/prompt_caching.py` + AGENTS.md "Prompt Caching Must Not Break" policy

**What**: 4 cache_control breakpoints (Anthropic max). Plus a project-wide invariant: **never mutate context mid-conversation**. Cache-invalidating slash commands MUST default to deferred (apply to next session) with opt-in `--now` flag. `/skills install --now` is the canonical example. Current hermes layout: byte-stable system prompt + 4 breakpoints at rolling positions.

**Why it matters**: At Opus pricing, cache hit rate is the difference between an affordable and a ruinous deployment. The marker placement is mechanical (~10 LOC); the discipline is the hard part — it has to be enforced in code review and in slash-command design. We've already done the load-bearing work (build_snapshot persisted on Session); writing it down protects it.

**Adoption sketch**: Two parts remaining:

1. **Mechanical**: audit `Jido.AI` Anthropic adapter to confirm `cache_control` markers land on system + the two most recent non-system messages (mirroring hermes's current discipline post-b06e99930). Add a snapshot test that exercises the actual JSON sent.
2. **Cultural**: new section in AGENTS.md ("Prompt cache invariants"). Document `build_snapshot/2`. Skill executor and slash-command handlers refuse to mutate session-scoped state mid-session by default; emit a "deferred to next session" notice unless the caller passes `now: true`.

---

### T1-8. Mixture-of-Agents worker template

**Status (2026-05-18)**: NOT_ADOPTED. `agent/workers/` contains coder, docs_writer, refactorer, researcher, reviewer, test_runner, verifier — no `mixture_of_agents.ex`. `grep` for "mixture_of_agents\|MixtureOfAgents\|ensemble" returns nothing.

**Where**: `tools/mixture_of_agents_tool.py`

**What**: Sends one prompt to N reference models in parallel (claude-opus, gemini-pro, gpt-pro, deepseek), then an aggregator model synthesizes the responses. References use temp 0.6, aggregator uses 0.4. Graceful degradation: `MIN_SUCCESSFUL_REFERENCES = 1`.

**Gap**: jido_radclaw has Coder/Reviewer/Researcher worker templates but no ensemble-style worker.

**Why it matters**: For hard reasoning tasks (architectural decisions, root-cause analysis on tangled bugs), ensemble outperforms monolithic single-model output — and the marginal cost is acceptable because these tasks already burn tokens. Trivial to OTP-ify with `Task.async_stream` (we get back-pressure and per-task supervision for free).

**Adoption sketch**: New `lib/jido_claw/agent/workers/mixture_of_agents.ex` using `Jido.AI.Agent`. Reference list config-driven (`.jido/config.yaml`). `Task.async_stream` over references with `:max_concurrency` + per-task timeout. Aggregator runs after stream completes. Wire into the swarm so the main agent can spawn an MoA sub-agent.

---

### T1-9. Session search via FTS

**Status (2026-05-18)**: PARTIAL. **FTS infrastructure landed**: `conversations/resources/message.ex:363–368` declares an `AshPostgres.Tsvector` generated column with a GIN index `messages_search_vector_idx` (line 93–97). The Solutions side has full hybrid retrieval (FTS+pgvector+pg_trgm with RRF combine) at `solutions/hybrid_search_sql.ex` exposed via `Tools.FindSolution`, and Memory has the equivalent at `memory/hybrid_search_sql.ex` exposed via `Tools.Recall`. **Missing**: `Tools.RecallSession`/session-search action; no read action on Message that groups hits by session.

**Gap (refreshed)**: FTS infrastructure on Message rows is built and the hybrid-search patterns are proven elsewhere — adoption is now a new tool + a read action that groups hits by `session_id` and returns anchored windows or summaries.

**Hermes (2026-05-18)**: REFACTORED significantly — entry **rewritten below**. The aux-LLM summarizer path was **deleted** (abf1af540, 94c523f0c). Tool is now single-shape with three calling modes (discovery / scroll / browse) inferred from args, NO LLM calls anywhere, every shape returns byte-for-byte SQLite content. ~20ms discovery vs ~90s before. Discovery returns FTS5 hits + ±5 message window + bookend_start (first 3) + bookend_end (last 3) per session, all in one call. Scroll uses `around_message_id`; browse returns recent sessions chronologically. The "summarize-not-transcript" framing in the original entry is no longer the design. T2-3 (auxiliary client) is **no longer a prerequisite** for T1-9.

**Where**: `tools/session_search_tool.py` (single-shape, post-rewrite), `hermes_state.py`

**What** (revised): Single SQLite (`~/.hermes/state.db`, WAL mode) with `sessions` and `messages` tables, plus an FTS5 virtual table over message content + tool_name + tool_calls. `session_search` infers calling mode from args: **discovery** (FTS query, no anchor) returns top hits grouped by session, each with a ±5 message context window plus the session's first-3 and last-3 messages as bookends — all bytes-from-SQLite, no LLM. **Scroll** (`around_message_id`) returns adjacent messages. **Browse** (no query, no anchor) returns recent sessions chronologically. The "anchored windows + bookends" shape gives the model enough context to decide if a hit is relevant without flooding context with full transcripts.

**Gap**: jido_radclaw has the FTS column and GIN index but no session-search tool surface yet.

**Why it matters**: As session count grows, an agent should be able to answer "have we hit this issue before?" without flooding context with 50KB of transcripts. Hermes initially used aux-LLM summaries to keep recall context-efficient — they replaced that with anchored-windows because (a) summaries cost tokens + latency, (b) the model summarizes worse than the raw bytes for the next step, and (c) the cheaper version is ~4000x faster.

**Adoption sketch** (revised): No aux-LLM dependency needed. Add a `:search_with_windows` read action on `Conversations.Message` that takes `(query, around_message_id?, limit, window?)`. Action runs FTS over `search_vector`, groups hits by `session_id`, returns each hit plus ±N adjacent messages from the same session, plus bookends (first 3 + last 3 of each session by sequence). New `Tools.RecallSession(query, ?around, ?limit)` calls it and returns the structured result. Lift the discovery/scroll/browse dispatch logic verbatim from hermes — single tool, three shapes inferred from args.

---

### T1-10. Cross-cluster rate-limit guard via `:pg`

**Status (2026-05-18)**: PARTIAL. The pattern is **proven for Voyage embeddings**: `embeddings/rate_pacer.ex` is a per-node bucket + cluster-global Postgres-row admit-gate (`embedding_dispatch_window` table via `embeddings/resources/dispatch_window.ex`). It's a cluster-shared rate budget — but only for one provider class. **Missing**: `providers/rate_guard.ex` for LLM 429s; no `:pg` group `:rate_limits`; LLM calls still retry independently per node.

**Gap (refreshed)**: We chose Postgres rows over `:pg` for embeddings (probably right — durable across node restarts). The remaining work is to generalize the same shape to all LLM provider 429/Retry-After handling. Decision required: keep Postgres-row shape (matches existing pattern, durable) or use `:pg` (faster, in-memory) for LLM rate limits.

**Where**: `agent/nous_rate_guard.py`, `agent/rate_limit_tracker.py`

**What**: When one process gets a 429 from a provider, it persists rate-limit state to `~/.hermes/rate_limits/<provider>.json` so other processes (CLI, gateway, cron, auxiliary) check before attempting a request. Eliminates retry amplification (3 SDK retries × 3 internal retries = 9 calls per turn against your RPH).

**Why it matters**: BEAM clustering makes the worst-case worse by default — file-based persistence is the wrong shape for clustered processes, but `:pg` (or a shared Postgres row, as we did for embeddings) is the right shape for cluster-shared rate-limit state. Treating provider quota as a cluster-wide resource is something hermes can't do natively but we can — and we've already proven the pattern works for one provider class.

**Adoption sketch**: Either (a) extend `Embeddings.RatePacer` to a generic `JidoClaw.Providers.RatePacer` keyed by provider, sharing the dispatch-window pattern; or (b) a `:pg` group `:rate_limits` storing `%{provider => %{reset_at: ts, status: :exhausted}}`. Provider call wrapper checks state before a request; on 429, broadcasts/persists the new exhaustion. Provider-supplied `Retry-After` headers override timestamps. Consumes T1-4 (`classify(error).reason == :rate_limit`).

---

### T1-11. NEW — Orchestrator-driven auto-decomposition (kanban triage → task graph)

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `hermes_cli/kanban_decompose.py` (440 LOC, new), `hermes_cli/profile_describer.py` (299 LOC, new), `hermes_cli/kanban_db.py::decompose_triage_task` (atomic helper), `gateway/run.py` (auto-decompose tick), `plugins/kanban/dashboard/plugin_api.py` (profiles endpoints), `hermes_cli/profiles.py` (new `description` + `description_auto` fields). Introduced in commit 1345dda0c.

**What**: A one-liner dropped into Triage is decomposed by an auxiliary LLM into a graph of child tasks routed to specialist profiles by their authored or auto-generated descriptions. The root task becomes a parent of every leaf, so when the graph completes the root wakes back up and its orchestrator-profile assignee can judge completion + add more work. Unknown LLM-picked assignees are rewritten to a configured default so a child task **never** lands with `assignee=None`.

**Gap**: jido_radclaw's swarm has Coder/Reviewer/Researcher/etc. worker templates and `Tools.SpawnAgent`, but no orchestrator-driven decomposition — the parent is responsible for breaking a task down and dispatching by hand.

**Why it matters**: Combines naturally with the existing reasoning-subsystem classifier (Reasoning could pick a decomposition strategy), the worker-template registry (specialist routing by capability declaration), and Ash resources (parent/child task relations are a natural fit for an `Ash.Resource`). The "root wakes when leaves complete" parent-child completion gate is exactly the OTP supervision shape and the existing `AgentTracker` already monitors children. Cheap to prototype: auxiliary-LLM-driven decompose plan + dispatch through the existing swarm.

**Adoption sketch**: `JidoClaw.Workflow.Decompose` consumes the existing `Reasoning.Classifier` to choose a decomposition strategy and uses an auxiliary `Jido.AI` call (precursor to T2-3) to produce a child-task graph. `JidoClaw.Workflow.Task` Ash resource with `parent_id`, `assignee`, `state` — leaves complete via signal → bus updates parent → parent re-enters orchestrator when all children done. Specialist profiles already exist as worker templates; expose them with `description`/`description_auto` fields for the LLM to route against. Pair with reasoning-certificate templates ("decomposition complete", "subtask satisfied") for auditability. Pairs with T1-8 (ensemble decomposition for hard cases).

---

## Tier 2 — Medium Impact

### T2-1. Subagent delegation discipline (blocklist + summary-only)

**Status (2026-05-18)**: NOT_ADOPTED. `agent/templates.ex` registers worker templates with `module`/`description`/`model`/`max_iterations` keys only — no `:blocked_tools` or `:summary_only?` options. `tools/spawn_agent.ex` spawns children without stripping a blocklist; parent receives full child output via `AgentTracker`.

**Hermes (2026-05-18)**: UNCHANGED. `DELEGATE_BLOCKED_TOOLS` contract unchanged. Several hardening fixes (heartbeat guards, provider override honoring, JSON string batch tasks, ACP guidance) but no design change.

**Where**: `tools/delegate_tool.py`

**What**: Spawned subagents get: fresh conversation, restricted toolset (`DELEGATE_BLOCKED_TOOLS = {delegate_task, clarify, memory, send_message, execute_code}` — no recursion, no user interaction, no shared MEMORY.md), focused system prompt. Parent only sees the call + summary; child's intermediate steps never enter parent context.

**Gap**: jido_radclaw's swarm is OTP-supervised (better isolation infra than threads), but I don't see explicit per-template tool blocklists or summary-only contracts.

**Why it matters**: Without blocklists, recursion depth and memory pollution can spiral. Summary-only contract keeps parent context lean — key for long-running parent agents that delegate often. Necessary precursor for T1-11 if we want auto-decomposed children to behave well.

**Adoption sketch**: Worker-template option `:blocked_tools` (atom list) and `:summary_only?` (bool). `JidoClaw.AgentTracker` enforces; main-agent context only receives summary on completion.

---

### T2-2. Multi-credential pool with strategy + cooldowns

**Status (2026-05-18)**: NOT_ADOPTED. `security/vault.ex` is a one-line Cloak vault. `security/runtime_secrets.ex` only handles SECRET_KEY_BASE/TOKEN_SIGNING_SECRET. No `CredentialPool` GenServer, no `PooledCredential` struct, no rotation strategies.

**Hermes (2026-05-18)**: UNCHANGED. ISO-string `last_status_at` rehydration fix (1a4e64ba0); shorter 401 cooldown; pooled auth rotation after quota failures (17d891485). No design change.

**Where**: `agent/credential_pool.py`, `agent/credential_sources.py`

**What**: Per-provider pool of `PooledCredential` objects with `(last_status, last_error_code, last_error_reset_at, request_count)`. Strategies: `fill_first | round_robin | random | least_used`. 429/402 → mark exhausted with TTL (provider headers override the default cooldown).

**Gap**: jido_radclaw's Vault stores secrets but I don't see automatic rotate-on-rate-limit.

**Why it matters**: Users who rotate keys (e.g., personal + team Anthropic key) effectively double their RPH ceiling — invisibly. Pairs naturally with T1-4 (error classifier sets `should_rotate_credential?`).

**Adoption sketch**: `JidoClaw.Security.CredentialPool` GenServer per provider. Vault stores N credentials per provider; pool selects via configured strategy; classifier flag triggers rotation.

---

### T2-3. Auxiliary client router for side tasks

**Status (2026-05-18)**: NOT_ADOPTED. `grep` for "AuxiliaryClient\|auxiliary_client" returns nothing. `lib/jido_claw/providers/` holds only `ollama.ex`. The consolidator (`memory/consolidator.ex`) drives a separate harness (Claude Code or Codex CLI) — different shape, not a per-task LLM router.

**Hermes (2026-05-18)**: REFACTORED significantly. 4-step **layered auxiliary fallback ladder** landed (a57424683 + 43e566f77, May 16–17): (1) primary aux provider → (2) user-configured `auxiliary.<task>.fallback_chain` → (3) **main agent provider+model as last-resort safety net** → (4) warn user + re-raise original error. Capacity-error gating (24c209f11) classifies quota exhaustion as a payment error so it can walk the chain. The fixed chain in the original entry (OpenRouter → Nous Portal → Custom → Codex OAuth → Anthropic) still describes the auto-mode flow, but the new principles are: **per-task config-driven fallback_chain** and **main-agent always-available safety net**. Read `website/docs/user-guide/features/fallback-providers.md` for the canonical spec.

**Where**: `agent/auxiliary_client.py` (~5100 LOC now)

**What**: Single `call_llm()` for "side tasks" (summarization, title generation, vision analysis, web extraction). Resolves backends in a documented priority chain (auto mode) and supports per-task `fallback_chain` config. On capacity/billing error, walks: configured chain → main agent → warn. Vision and text get separate chains.

**Gap**: jido_radclaw uses Jido.AI multi-provider but not the explicit "side tasks pick a cheaper backend with cascade fallback and main-agent safety net" pattern.

**Why it matters**: Title generation, compaction summaries (T1-2), risk classifier (T2-8), and reasoning classifier shouldn't run on the most expensive model. Without an aux-router, every side-task call is at main-model pricing — death by a thousand cuts. The "main agent as last-resort fallback" invariant is the non-obvious win: side tasks never silently fail, they degrade gracefully.

**Adoption sketch**: `JidoClaw.Providers.AuxiliaryClient` with config-driven chain in `.jido/config.yaml`. Public API: `call(:summarize | :title | :classify | :extract, prompt, opts)`. Per-task provider+model override via `auxiliary.<task>.provider` and `auxiliary.<task>.fallback_chain`. On 402/quota/capacity, walk: configured chain → main-agent provider+model → warn + re-raise. Reuses T1-4's classifier to detect "this is a capacity error" vs "this is a real failure". **Note**: T1-9 (session search) was originally a downstream consumer of this — it isn't anymore, since hermes deleted the aux summarizer path; T1-9 can ship without T2-3.

---

### T2-4. Skill security guard with trust-level matrix

**Status (2026-05-18)**: N/A. Prerequisite (external skill registry) hasn't materialized. JidoClaw's `.jido/skills/` is still local YAML DAGs. `.agents/skills/` SKILL.md tree is `usage-rules`-managed reference docs for Claude Code, not user-installed third-party skills.

**Where**: `tools/skills_guard.py`, `tools/skill_manager_tool.py`

**What**: External skills downloaded from registries pass through regex static analysis (exfiltration, injection, destructive, persistence patterns) and a verdict matrix:

```
                 safe      caution    dangerous
builtin:       allow     allow      allow
trusted:       allow     allow      block      (openai/skills, anthropics/skills only)
community:     allow     block      block
agent-created: allow     allow      ask        (gated by skills.guard_agent_created)
```

**Gap**: If jido_radclaw skills become installable from third parties (currently just local YAML).

**Why it matters**: External code execution is the #1 source of supply-chain compromise. A trust-level matrix gives meaningful gradation without "approve everything."

**Adoption sketch**: Only relevant once skill-sharing exists. Pre-install: regex scan + trust-level lookup → verdict. Trust list (`trusted_repos`) hardcoded in source — explicit allowlist beats configuration.

---

### T2-5. Shadow-git checkpoint manager

**Status (2026-05-18)**: PARTIAL. `forge/resources/checkpoint.ex` defines an Ash resource for Forge sandbox checkpoints with `sandbox_checkpoint_id`, `exec_session_sequence`, `runner_state_snapshot`, and a `:latest_for_session` read action. Checkpointing **exists inside Forge sessions** (sandboxed execution domain). **Missing**: transparent pre-write hook on `Tools.WriteFile`/`Tools.EditFile` against the user's working tree; no `/restore <checkpoint-id>` CLI command.

**Gap (refreshed)**: We have checkpoint primitives for sandboxed sessions but no automatic pre-mutation snapshot of the user's actual project tree. The choice is whether to extend Forge's checkpoint shape to non-sandboxed file mutations or add a separate shadow-git-style mechanism.

**Hermes (2026-05-18)**: REFACTORED. v2 single-store rewrite (a0fedfbb1: "v2 single-store rewrite with real pruning + disk guardrails"). The per-directory `~/.hermes/checkpoints/{sha256(dir)[:16]}/` model in the original entry is the v1 description. v2 keeps per-dir keying but adds real pruning + disk guardrails — re-read `checkpoint_manager.py` before adoption.

**Where**: `tools/checkpoint_manager.py`

**What**: NOT a tool the LLM sees. Before file-mutating ops (`write_file`, `patch`), automatically snapshots the working dir to a per-directory shadow git repo at `~/.hermes/checkpoints/{sha256(dir)[:16]}/` using `GIT_DIR + GIT_WORK_TREE` so no `.git` lands in the user's project. Snapshots once per turn. `/restore` rolls back. Default excludes `node_modules`, `dist`, `.env*`, etc. v2 adds disk-budget pruning + size guardrails.

**Why it matters**: Lets users undo a bad agent session without losing intermediate state. Distinct from VFS — this is filesystem rollback, not virtualization. The Forge-side checkpointing is for sandboxed runs; this is for the user's actual project tree.

**Adoption sketch**: Hook `Tools.WriteFile`/`Tools.EditFile` pre-execution. Per-tenant or per-session checkpoint dir under `.jido/checkpoints/` — keep the path layout DB-backed-and-multi-tenant-safe to align with existing Forge checkpoints. New CLI command `/restore <checkpoint-id>`. Excludes lifted from hermes verbatim. Disk guardrails + pruning (v2-style) from day one.

---

### T2-6. Pluggable memory provider ABC + frozen snapshots

**Status (2026-05-18)**: PARTIAL. **Frozen-snapshot half fully adopted** (see T1-7 status): `agent/prompt.ex::build_snapshot/2` is persisted on `Conversations.Session.metadata["prompt_snapshot"]` at session creation, block-tier memory rendered at snapshot time, memory writes (`Tools.Remember`) persist via `lib/jido_claw/memory.ex` but the in-context snapshot doesn't refresh until the next session. **Missing**: `JidoClaw.Memory.Provider` behaviour, `lib/jido_claw/memory/providers/` directory, `BuiltinMemoryProvider` vs `HonchoProvider` etc. Memory subsystem is a single Ash-backed implementation (`memory/resources/` — Fact/Block/Episode/Link/ConsolidationRun/...).

**Gap (refreshed)**: The discipline is in place; the extension surface is not. There's exactly one memory implementation (Ash-backed) with no behaviour or registry to swap in external providers (honcho/mem0/supermemory/byterover/...).

**Hermes (2026-05-18)**: REFACTORED. New optional hook `on_session_switch(new_session_id, *, parent_session_id, reset, **kwargs)` (13683c084) — fires on `/resume`, `/branch`, `/reset`, `/new`, and context compression. Doc listed 5 optional hooks; this adds a 6th. Frozen-snapshot discipline unchanged.

**Where**: `agent/memory_provider.py`, `agent/memory_manager.py`, `plugins/memory/<name>/`

**What**: `MemoryProvider` ABC with `initialize/system_prompt_block/prefetch/sync_turn/get_tool_schemas/handle_tool_call/shutdown`, plus optional hooks (`on_turn_start`, `on_session_end`, `on_pre_compress`, `on_memory_write`, `on_delegation`, `on_session_switch`). Built-in `BuiltinMemoryProvider` is always-on (writes `MEMORY.md`/`USER.md`). At most ONE external provider. System prompt has _frozen_ memory snapshots (cache stays valid); writes go to disk immediately but don't mutate context until next session.

**Why it matters**: Pluggable memory is becoming standard in agent platforms. The frozen-snapshot half is already paying off (we have it); externalizing the provider would let us experiment with mem0/honcho/etc. without re-plumbing the agent.

**Adoption sketch**: `JidoClaw.Memory.Provider` behaviour wrapping the existing `JidoClaw.Memory` API. Default `JidoClaw.Memory.Providers.Builtin` delegates to the current Ash-backed implementation. External providers under `lib/jido_claw/memory/providers/`. Include all 6 optional hooks from hermes (`on_session_switch` is the newest). Discipline preserved: writes persist immediately; the in-context `<memory-context>` block comes from the prompt snapshot at session start and doesn't refresh mid-session.

---

### T2-7. OSV malware check before MCP server launch

**Status (2026-05-18)**: NOT_ADOPTED. `grep` for "osv\|OSV\|malware" returns nothing. `mcp_scope/initializer.ex` configures MCP scope mappings but doesn't query osv.dev before launching servers.

**Where**: `tools/osv_check.py`

**What**: Checks `npx`/`uvx` MCP server packages against `MAL-*` advisories from osv.dev before launching the subprocess.

**Gap**: AGENTS.md shows we recommend users add jidoclaw to their `.mcp.json`. If we ever spawn third-party MCP servers (outbound — agent connects to an MCP), we have no malware check.

**Why it matters**: Supply-chain attacks on `npm`/`pypi` MCP packages are a known vector. Free-ish defense. Worth more given the personal-tailnet threat model where compromised dependencies are a real LLM-misbehavior vector.

**Adoption sketch**: `JidoClaw.Security.OsvCheck` querying `https://api.osv.dev/v1/query`. Called before any subprocess that runs a third-party `npm`/`pip`/`pypi` package. Cache results per-version with short TTL.

---

### T2-8. Approval system with auxiliary-LLM auto-classifier

**Status (2026-05-18)**: PARTIAL. `platform/approval.ex` implements a per-session approval GenServer with `:off | :on_miss | :always` modes, ETS-backed allowlist, pending requests with 120s timeout — but uses a **pattern-match-allowlist** gate, NOT an auxiliary-LLM risk classifier. **Missing**: `JidoClaw.Security.RiskClassifier`, the `classify/1 :: :safe | :caution | :dangerous` surface, DANGEROUS_PATTERNS regex pre-filter.

**Hermes (2026-05-18)**: REFACTORED (small). Tightened dangerous-command detection (6ba35ec33 — "Inspired by Claude Code"); precompiled patterns for perf (cd7150a19); `sudo -S` / stdin / askpass / shell privilege flag catches (976d8e27a, 9520a1ccd); cron jobs no longer treated as gateway context (839cdd1b0); DELETE pattern DOTALL bypass fix (80374d4dd). API-server now exposes approval events (526c0e018). Design unchanged; pattern set grew.

**Where**: `tools/approval.py`

**What**: Per-session approval state via `contextvars` (gateway runs concurrent sessions). Pattern detection (DANGEROUS_PATTERNS) → either prompt user OR send command to an auxiliary LLM that classifies risk and auto-approves low-risk ones. Permanent allowlist persistence. Plugin hooks (`pre_approval_request`, `post_approval_response`).

**Gap (refreshed)**: Approval infrastructure exists but the aux-LLM auto-classifier that would reduce friction on safe commands is missing. Also worth lifting hermes's expanded dangerous-pattern set.

**Why it matters**: Reduces approval friction (the agent doesn't ask "can I run `ls`?") without giving up safety on actually dangerous commands. Pairs with T2-3.

**Adoption sketch**: `JidoClaw.Security.RiskClassifier.classify(command) :: :safe | :caution | :dangerous` queries cheap aux model (via T2-3 once available). Approval flow: pattern match → if no match, classify → allow safe, prompt caution, block dangerous (configurable). Lift the precompiled hermes pattern set including the May-2026 hardening (sudo stdin, DELETE-DOTALL).

---

### T2-9. Process registry with strikes + global circuit breaker

**Status (2026-05-18)**: PARTIAL. `platform/background_process/registry.ex` tracks spawned OS processes with a 200KB output buffer (`@buffer_max_bytes 200 * 1024` — same as hermes), two-phase SIGTERM→5s→SIGKILL termination, auto-cleanup after 1h. **Missing**: per-session strike system, global 10s/15-hit circuit breaker, watch-pattern tracker, JSON checkpoint recovery.

**Gap (refreshed)**: Tracking and buffering exist; the strike + circuit-breaker anti-flooding layer doesn't. Watch-pattern subscription is also absent — currently a `tail -f` would dump unbounded into the buffer.

**Hermes (2026-05-18)**: UNCHANGED. Orphaned Popen killed on post-spawn setup failure (53ec32819); psutil-based cross-platform PID management (cc38282b0). Strike + global circuit breaker design unchanged.

**Where**: `tools/process_registry.py`

**What**: Background-process tracking with rolling 200KB output buffer, watch patterns. **Per-session strike system**: 3 strikes in 15s windows → permanently disable watch, fall back to notify-on-complete. **Global circuit breaker**: 15 matches per 10s across all sessions → 30s cooldown. Crash recovery via JSON checkpoint.

**Why it matters**: A misbehaving process (or a tail of `--verbose` logs) can flood the agent's context with watch hits. Multi-layer rate-limiting is well-thought-out.

**Adoption sketch**: ETS counters per session + global. `platform/background_process/registry.ex` checks before notifying. Watch disable is per-session, soft-permanent (resets on session end). Cluster-wide circuit breaker could ride on the same `:pg`/Postgres-row pattern as T1-10.

---

### T2-10. Cron with delivery targets + scripted preprocessor

**Status (2026-05-18)**: NOT_ADOPTED. `cron/resources/job.ex` defines a persistent `Cron.Job` resource (job_id/task/mode/schedule_kind/schedule_value/mfa_*/metadata) scheduled via `platform/cron/scheduler.ex`. `platform/channel/` has discord + telegram adapters. **Missing**: `pre_script` field, `delivery_targets` list, `silent_when_match`, `[SILENT]` sentinel, cron-to-channel dispatch glue.

**Hermes (2026-05-18)**: REFACTORED. New **`no_agent=True` mode** for script-only cron jobs (3db6b9cc8, May 4) — the classic watchdog pattern (script stdout → channel, no LLM, no tokens). New name-based lookup for job ops (6682f91b8). `deliver=all` fan-out intent (486b14b42). `[SILENT]` sentinel design unchanged. Adoption sketch should add `no_agent` mode — cheapest tier, different use case.

**Where**: `cron/jobs.py`, `cron/scheduler.py`

**What**: Cron jobs execute via gateway tick (60s) with file-lock to prevent overlapping ticks. Each job: cron expression OR human duration ("every 1h"), prompt, optional `--script` (Python script whose stdout becomes context for the agent), `--skills` (preload skills), `--deliver telegram|discord|slack|sms|email|webhook|github_comment|local`. New `no_agent` mode: script stdout goes straight to the channel — no LLM call. Webhook subscriptions take inbound GitHub events and pattern-match payload fields into prompts (`{pull_request.title}`). `[SILENT]` sentinel for "no notification needed."

**Gap**: jido_radclaw has `Tools.ScheduleTask`/`Tools.ListScheduledTasks` and a persistent `Cron.Job` resource but no `--script` preprocessor, no multi-target delivery, and no agent-free mode.

**Why it matters**: "Wake me up if X" workflows. Script handles mechanical work cheaply; agent handles reasoning expensively; `no_agent` mode skips the LLM entirely for pure watchdog use cases. `[SILENT]` prevents notification spam when the answer is "all clear."

**Adoption sketch**: Extend the scheduled-task model with `pre_script` (path or inline), `delivery_targets` (list of channels), `silent_when_match` (regex), `no_agent` (bool — when true, skip LLM and deliver script stdout directly). Discord + Telegram delivery already work via `platform/channel/`; add webhook + email next. Scheduler uses the existing `platform/cron/scheduler.ex`.

---

### T2-11. NEW — Gateway deliverable mode (artifact uploads as native attachments)

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `gateway/platforms/base.py::extract_local_files` (line 2158), `gateway/run.py::_deliver_kanban_artifacts`, `tools/kanban_tools.py` (`kanban_complete` `artifacts` param), `hermes_cli/kanban_db.py` (metadata.artifacts propagation), `website/docs/user-guide/features/deliverable-mode.md`. Commit f2fdb9a17.

**What**: When an agent's response mentions an absolute file path to a supported type (PDF, docx, xlsx/csv/json/yaml, pptx, zip/tar/gz, mp3/wav, html, source files), the gateway dispatches it as a native upload on the target platform (Slack file, Discord attachment, Telegram document, etc.) rather than embedding the path in text. Kanban workers can explicitly attach via `kanban_complete(artifacts=[...])`.

**Gap**: jido_radclaw has Discord delivery via Nostrum but no abstraction for "agent produced an artifact, deliver it natively." File paths in agent responses go out as text.

**Why it matters**: Pattern generalizes "agent produced a chart/PDF/report" into a delivery primitive that doesn't require the agent to know which platform it's on. Plays well with the new auto-decomposition + worker-template pattern (T1-11) — a Researcher worker can produce a PDF and the Discord adapter handles the actual upload.

**Adoption sketch**: `JidoClaw.Platform.Channel.Behaviour` gains an `upload_artifact/3` callback. Response post-processor walks the assistant message looking for absolute paths matching `extract_local_files`-style filters, calls the adapter's `upload_artifact` for each. Discord adapter wraps Nostrum's file-attachment API. Telegram adapter wraps its document-upload primitive. Adapters can opt out (CLI just inlines the path text).

---

### T2-12. NEW — ACP edit approval (pre-execution diff + session-scoped auto-approval)

**Status (2026-05-18)**: NOT_ADOPTED (new entry). jido_radclaw has `platform/approval.ex` (T2-8 PARTIAL) but not the structured pre-execution diff flow.

**Where in hermes**: `acp_adapter/edit_approval.py` (278 LOC, new), `acp_adapter/server.py` (1894 LOC, expanded), `model_tools.py` (approval hooks). Commits 9592e595a, f70e0b85d, 49b28d164, 029239860.

**What**: ACP-bound tools (only ACP — CLI/gateway bypass) request approval before any `write_file`/`patch`/`edit`. Approval is requested with a structured `EditProposal` (tool_name, path, old_text, new_text, arguments). Auto-approve scopes: `ask` / `workspace_session` / `session`. Sensitive paths (`.env*`, `id_rsa`, `id_ed25519`) always require ask. Duplicate-diff suppression. Uses `ContextVar` for clean ACP-only binding.

**Gap**: jido_radclaw has approval infrastructure for shell commands but not a structured pre-execution diff-approval flow for file mutations.

**Why it matters**: T2-8 (auxiliary-LLM risk classifier) is the "decide if a shell command is safe" half; this is the "show the diff before write" half. Together they cover the two main agent action types. Sensitive-path hardcoded denylist is a low-cost win we should have regardless.

**Adoption sketch**: New `JidoClaw.Tools.EditApproval` ContextVar-equivalent (process dictionary or GenServer call). `Tools.WriteFile`/`Tools.EditFile` request approval through it before executing. Approval shape: `%EditProposal{tool, path, old_text, new_text, arguments}`. Approval scopes persisted on `Conversations.Session.metadata["approval_scopes"]`. Sensitive-path filter (`.env*`, SSH keys) is non-bypassable. ACP gateway wraps this in its protocol; CLI/Discord can opt-in.

---

### T2-13. NEW — Codex app-server runtime (alternate transport for OpenAI/Codex models)

**Status (2026-05-18)**: NOT_ADOPTED (new entry). jido_radclaw has a Codex sibling runner inside Forge (`forge/runners/codex.ex`) — a *harness* sibling, NOT the in-Jido.AI transport adapter described here.

**Where in hermes**: `agent/transports/codex_app_server.py` (JSON-RPC 2.0 stdio speaker), `agent/transports/codex_app_server_session.py` (810 LOC session adapter), `agent/transports/codex_event_projector.py`, `hermes_cli/runtime_provider.py` (`codex_app_server` API mode). Commits 091d8e103, d5a0815c3 (monotonic deadlines), 12f755c9e (wedge watchdog + OAuth refresh classify).

**What**: An opt-in alternate runtime that hands OpenAI/Codex turns to a `codex app-server` subprocess instead of Hermes' own tool dispatch. JSON-RPC 2.0 over stdio: spawn → init handshake → thread/start → run_turn (blocks until `turn/completed`) → close. Server-initiated approval requests (`apply_patch`, `exec`) round-trip back through the agent. Monotonic deadlines in the turn loop (so wall-clock skew doesn't wedge cancellation). Post-tool watchdog + wedged-session retire.

**Gap**: `Jido.AI` today routes to OpenAI/Anthropic/etc. via HTTP. We have no in-process alternative for "let the model's native agent runtime do the work and forward events to us."

**Why it matters**: Codex app-server is OpenAI's preferred shape for *agentic* turns (with native `apply_patch` + `exec`) and gives behavior parity with `codex` CLI / Cursor for OpenAI models. The Port-driven JSON-RPC subprocess shape is well-suited to OTP — `Port.command/2` + a GenServer state machine is the natural translation. Worth considering once first-class Codex parity becomes a goal. Also a good pattern reference for any future "run model X via its native runtime" adapter.

**Adoption sketch**: New `JidoClaw.Providers.Adapters.CodexAppServer` `Jido.AI` adapter using a `Port` to speak JSON-RPC 2.0 to a `codex app-server` subprocess. Session state machine modeled on hermes's. Approval round-trips through the existing `platform/approval.ex` (or T2-12). Monotonic deadlines via `:erlang.monotonic_time/1`. Wedged-session retire via timeout-supervised port linking.

---

### T2-14. NEW — ABC-plus-registry plugin pattern (from browser-provider migration)

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `agent/browser_provider.py` (BrowserProvider ABC), `agent/browser_registry.py` (selection registry), `plugins/browser/browserbase/`, `plugins/browser/browser_use/`, `plugins/browser/firecrawl/`, `hermes_cli/plugins.py::register_browser_provider`, `tools/browser_tool.py` (dispatcher dispatches via registry). Commits c6e6909e5 (ABC), b8138ac40 (browserbase spike), a15cdfb05 (browser-use + firecrawl), 40fde853f (dispatcher cutover), 250caebeb (delete legacy dir).

**What**: Three-rule selection registry (explicit-config-wins → single-eligible → legacy-preference walk) backing per-vendor plugin directories. Dispatcher in `tools/browser_tool.py` is a pure registry lookup. New plugins register via `ctx.register_browser_provider()`. The same shape was previously established for web-search providers — this commit migrated cloud-browser providers off in-tree modules.

**Gap**: jido_radclaw has multiple natural plugin slots (VFS backends, channel adapters, memory providers per T2-6, provider adapters in `providers/`) that today are either ad-hoc registries or single implementations.

**Why it matters**: Lifting the *pattern* (not the specific provider) is the value. The "ABC + selection registry + plugin dirs" shape is the right way to model any pluggable backend with a vendor matrix. Applies to memory providers (T2-6), provider adapters, future cloud-browser support, future remote-execution backends, and any "user wants vendor X over our default" surface.

**Adoption sketch**: Standardize a Jido `behaviour` + registry GenServer pattern. Selection rules in priority order: (a) explicit config in `.jido/config.yaml` wins; (b) single-eligible plugin auto-selected; (c) hardcoded preference order as fallback. Per-vendor plugin in `lib/jido_claw/<subsystem>/plugins/<vendor>/`. Each plugin registers itself in its application supervisor. Document the pattern in AGENTS.md once it's used in two places (memory + VFS would be the natural test cases).

---

### T2-15. NEW — Curator (periodic auxiliary-model maintenance of agent-authored artifacts)

**Status (2026-05-18)**: NOT_ADOPTED for skills. **Adjacent**: jido_radclaw has `memory/consolidator.ex` + `memory/consolidator/` directory ("Memory: Consolidator Runtime & Frozen-Snapshot Prompt") — but that's *memory* consolidation specifically, not the general curator pattern.

**Where in hermes**: `agent/curator.py` (1781 LOC), `agent/curator_backup.py`, plus curator hooks in `gateway/run.py` (cron-ticker thread integration, 019d4c1c3). Commits bc79e227e (initial), fa9383d27 (umbrella-first + inherit parent config + unbounded iterations), c8b7e7268 (review prompt → existing tools), 0d31864e3 (defense-in-depth bundled/hub skill gates), a12f7aa8b (7-day default), 8b290a590 (consolidated vs pruned).

**What**: An auxiliary-model task that periodically (default 7 days, gateway cron-tick driven) reviews agent-created skills and maintains the collection. Auto-transitions lifecycle states based on derived skill activity timestamps. Spawns a background review agent that pins / archives / consolidates / patches agent-created skills via `skill_manage`. Strict invariants: only touches agent-created skills, never auto-deletes (archive is recoverable), pinned skills bypass auto-transitions, uses the auxiliary client (never touches main session's prompt cache).

**Gap**: jido_radclaw has memory consolidation but not curation of other agent-authored artifacts: skills, strategy-store entries, certificate templates, classifier outcomes.

**Why it matters**: "Curator" is more general than memory consolidation — it's a *pattern* for periodic agentic review of any agent-authored artifact corpus, with safety invariants (never delete, never touch user-authored, never touch pinned). Natural fit for the reasoning subsystem's strategy store (a curator could pin/archive/consolidate strategies based on usage) and for skill curation if/when knowledge-skills (T1-6) land. Pairs with T2-3 (aux client) and T2-10 (cron scheduling).

**Adoption sketch**: `JidoClaw.Curator.Behaviour` callback with `targets/0`, `review_prompt/1`, `apply_decision/2`. Default curators: `MemoryCurator` (wrapping existing consolidator), `StrategyCurator` (over `reasoning/strategy_store.ex`), and once T1-6 lands, `KnowledgeSkillCurator`. Each curator runs on a configurable cadence via the existing cron infrastructure (default 7 days). Aux-client backed; main-agent context never touched. Lifecycle states + pin protection lifted from hermes.

---

### T2-16. NEW — Persistent cross-turn goals (`/goal` — "Ralph loop")

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `hermes_cli/goal.py`, `hermes_cli/commands.py` (CommandDef registry entries), AIAgent integration in agent loop. Commit 265bd59c1.

**What**: Standing-goal slash command that keeps the agent working toward a user-stated objective across turns until satisfied, paused, or the turn budget runs out. After each turn, a lightweight auxiliary-model judge asks "is this goal satisfied by the assistant's last response?". If not, and we're under the turn budget (default 20), the system feeds a continuation prompt back into the same session as a normal user message. Real user input preempts automatically. Judge failures **fail open** (budget is the real backstop).

**Gap**: jido_radclaw has worker iteration budgets (`max_iterations`) but no user-facing "keep working toward goal X across many turns" primitive.

**Why it matters**: Long-running autonomous workflows are a natural agent pattern jido_radclaw doesn't directly model. Maps cleanly onto Ash (a `Goal` resource) + an aux judge call (T2-3) + a budget GenServer guard. User-controllable pause/resume/clear is good UX. Pairs with reasoning-certificate templates ("goal satisfied" certificate as the auditable judge output).

**Adoption sketch**: `JidoClaw.Workflow.Goal` Ash resource (state: `:active | :paused | :satisfied | :budget_exhausted`, with `turn_budget`, `judge_history`). `/goal <prompt>` slash command creates the row. CLI REPL between-turn hook: if there's an active goal and no user input pending, call the auxiliary judge — if not satisfied and budget remains, inject continuation as next turn. Real user input preempts. Aux judge failure fails open. Pairs with T2-3.

---

### T2-17. NEW — Post-write delta-lint discipline (write_file + patch)

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `tools/file_operations.py::_check_lint`, `_check_lint_delta` (in-process linters for `.py/.json/.yaml/.toml`; shell linter fallback for languages without an in-process equivalent). Commit 5168226d6.

**What**: After every `write_file`/`patch`, runs a post-state lint. In-process linters (`ast.parse` for Python, stdlib parsers for JSON/YAML/TOML) avoid subprocess overhead. Critically: **post-first, pre-lazy** pattern (borrowed from Cline/OpenCode) — if errors are found AND pre-content was captured, lints the pre-state and diffs. If pre-existing file had the SAME errors, report "still has errors but the edit didn't introduce them" rather than blaming the edit.

**Gap**: jido_radclaw's `Tools.WriteFile`/`Tools.EditFile` have no post-write lint check.

**Why it matters**: The delta pattern (don't blame edits for pre-existing damage) is hard-won prompt engineering — the agent reads "you broke X" very differently than "this file had pre-existing X". Cheap to add since Elixir has good in-process parsers for `.ex/.exs/.heex` (Code module) and JSON. Direct improvement to agent feedback loop quality.

**Adoption sketch**: `JidoClaw.Tools.PostWriteLint` plug-style step run after `Tools.WriteFile`/`Tools.EditFile`. Dispatch by extension: `.ex/.exs` → `Code.string_to_quoted/2`; `.heex` → `Phoenix.LiveView.HTMLEngine` parser; `.json` → `Jason.decode/2`; `.yaml` → `YamlElixir`; others fall through to a shell linter if configured. Capture pre-content snapshot on edit-style ops; if post-lint errors and pre-content available, diff. Append result to tool output, never raise.

---

## Tier 3 — Lower Impact / Nice-to-Haves

### T3-1. Single command registry across surfaces

**Status (2026-05-18)**: NOT_ADOPTED. `cli/commands.ex` dispatches via `handle/2` clauses (`/help`, `/quit`, `/clear`, `/status`, `/model`, ...) — no central `COMMAND_REGISTRY` list, no `%CommandDef{}` struct shared with the Discord adapter. `platform/channel/discord_consumer.ex` is a separate dispatch path.

**Where**: `hermes_cli/commands.py`

**What**: One `COMMAND_REGISTRY: list[CommandDef]` drives CLI dispatch + gateway dispatch + autocomplete + Telegram BotCommand menu + Slack subcommand routing + help generation.

**Why**: Eliminates drift between `/foo` in CLI and `/foo` in Discord. Adding a slash command edits one list.

**Adoption sketch**: `JidoClaw.Commands.Registry` with a list of `%CommandDef{}` structs. CLI REPL and Discord (and Telegram) bot adapters all consume the same list.

---

### T3-2. Insights engine

**Status (2026-05-18)**: NOT_ADOPTED. `web/live/dashboard_live.ex` exists but doesn't surface per-model cost breakdowns / day-of-week heatmaps / streaks. `core/telemetry.ex` exists but isn't surfaced as a dashboard.

**Where**: `agent/insights.py` (~39k chars)

**What**: SQL queries over `state.db` produce: token usage, cost estimates (per-model pricing snapshot), tool/skill usage counters, model breakdown, platform breakdown, activity by day-of-week + hour, daily streak, busiest day/hour. Renders as terminal tables with `█` bar charts or JSON.

**Why**: jido_radclaw has telemetry but doesn't surface it as a user-facing dashboard.

**Adoption sketch**: Phoenix LiveView page `/admin/insights` (or unauthenticated `/insights` for the local CLI tenant) reading from the existing telemetry pipeline (`reasoning/telemetry.ex` + whatever sink stores events). Or a `mix jidoclaw.insights` task for terminal output.

---

### T3-3. Tirith pre-exec security scanner

**Status (2026-05-18)**: NOT_ADOPTED (intentional). `grep` for "tirith\|cosign" returns nothing in lib/ and test/.

**Where**: `tools/tirith_security.py`

**What**: External Rust binary auto-installed (with SHA-256 + cosign provenance verification, fail-open on missing cosign), runs as subprocess on every shell command, returns 0/1/2 for allow/block/warn.

**Why**: Forge has sandboxing but no static-pattern scanner. Tirith complements (not replaces).

**Adoption sketch**: Optional. Forge pre-exec hook calls a binary if installed. Probably overkill for now.

---

### T3-4. Shell-script hooks bridging plugin lifecycle events

**Status (2026-05-18)**: NOT_ADOPTED.

**Hermes (2026-05-18)**: REFACTORED (small). Shell hook block handler now honors blocks even when message/reason absent (aeda14611, 63805965e, dbeaaa47f).

**Where**: `agent/shell_hooks.py`

**What**: Configurable `hooks:` block in `cli-config.yaml` registers shell scripts for `pre_tool_call/post_tool_call/pre_llm_call/post_llm_call/on_session_start/on_session_end`. JSON to/from stdin/stdout. First-use consent. Output schema: `{"decision":"block","reason":"..."}` or `{"context":"..."}` to inject context.

**Why**: Non-Elixir extension surface for ops users. Lower priority for an Elixir-first community but adds reach.

**Adoption sketch**: `.jido/hooks.yaml` with hook → script paths. `Port`-launched subprocess on each event. Sidecar pattern.

---

### T3-5. Profile system via `HERMES_HOME`

**Status (2026-05-18)**: NOT_ADOPTED. `grep` for "JIDO_HOME" returns nothing. Project-level `.jido/` is resolved from cwd via `JidoClaw.Startup.resolve_project_dir_from_argv/1`.

**Hermes (2026-05-18)**: UNCHANGED at the API level. New: when `HERMES_HOME` is unset but `active_profile` indicates a non-default profile, hermes logs a one-shot warning to `errors.log` so cross-profile data corruption is diagnosable. Subprocess spawners (systemd template in `hermes_cli/gateway.py`, kanban dispatcher) propagate `HERMES_HOME` explicitly.

**Where**: `hermes_constants.py::get_hermes_home()`

**What**: `HERMES_HOME` env var redirects everything (config, secrets, sessions, memory, skills, gateway state) to per-profile dirs. Code rule: never `Path.home() / ".hermes"`; always `get_hermes_home()`.

**Why**: jido_radclaw's `.jido/` is per-project (cwd), which already gives some isolation. Multi-tenant on one machine would need a `JIDO_HOME` override.

**Adoption sketch**: Add `JIDO_HOME` env var resolution as fallback when `.jido/` is missing in cwd. Subprocess spawners propagate explicitly (cron worker, Forge runner). Probably low-priority.

---

### T3-6. `@file:`/`@folder:`/`@diff` context references

**Status (2026-05-18)**: NOT_ADOPTED. `cli/repl.ex` passes user input through unchanged — no preprocessor.

**Where**: `agent/context_references.py`

**What**: User can include `@file:src/main.py:10-50`, `@diff`, `@staged`, `@url:"..."` in messages; preprocessor expands them into context blocks. Token cost tracked. Sensitive home dirs blocked (`.ssh`, `.aws`, `.gnupg`, `.kube`, `.docker`, `.azure`, `.config/gh`).

**Why**: CLI ergonomic. jido_radclaw has VFS routing — this is a user-shorthand layer on top.

**Adoption sketch**: REPL input preprocessor. Regex match `@(file|folder|git|diff|staged|url):...`, expand inline.

---

### T3-7. Onboarding first-touch hints

**Status (2026-05-18)**: NOT_ADOPTED. `setup/wizard.ex` is a blocking first-run check; no `.jido/config.yaml` `onboarding.seen.<flag>` map; no contextual "first time you do X" hint system.

**Where**: `agent/onboarding.py`

**What**: Instead of a blocking first-run questionnaire, show a one-time hint at the moment the user first hits a behavior fork. Tracked in `config.yaml` under `onboarding.seen.<flag>`. Atomic YAML write.

**Why**: Low-friction UX pattern.

**Adoption sketch**: `.jido/config.yaml` `onboarding.seen` map. Hint helpers in CLI.

---

### T3-8. Auto-titled sessions

**Status (2026-05-18)**: NOT_ADOPTED. `conversations/resources/session.ex` has workspace_id/user_id/kind/external_id/tenant_id/metadata but **no `title` field**. No title-generator background task.

**Where**: `agent/title_generator.py`

**What**: After first user→assistant exchange, fire off auxiliary-LLM call in daemon thread to generate 3-7 word title; persist on session.

**Why**: Trivial UX win for session listing.

**Adoption sketch**: Add a `title` attribute to `Conversations.Session`. Background `Task.Supervisor.start_child` after first turn, calls T2-3 aux client, updates resource.

---

### T3-9. "Don't write change-detector tests" doctrine

**Status (2026-05-18)**: NOT_ADOPTED. AGENTS.md doesn't codify this.

**Where**: AGENTS.md

**What**: Tests asserting specific data (model names in catalog, config version literals, enumeration counts) are _banned_ — they fail on routine source updates without adding behavioral coverage. Replace with invariants: "every model in the catalog has a context-length entry."

**Why**: Testing philosophy. Applies to any catalog-style test (provider lists, tool registry, skill index).

**Adoption sketch**: New AGENTS.md section. Code review check.

---

### T3-10. CI-parity test wrapper

**Status (2026-05-18)**: NOT_ADOPTED. No `scripts/test.sh` wrapper that scrubs API keys / pins timezone.

**Where**: `scripts/run_tests.sh`, `tests/conftest.py`

**What**: Test runs via wrapper that unsets `*_API_KEY`/`*_TOKEN`, sets `TZ=UTC`, `LANG=C.UTF-8`, `-n 4` xdist workers, redirects `HERMES_HOME` to temp. Avoids "works locally, fails in CI."

**Why**: Eliminates a class of flake.

**Adoption sketch**: `scripts/test.sh` wrapper for `mix test` that scrubs API keys, fixes timezone.

---

### T3-11. Multi-platform gateway abstraction

**Status (2026-05-18)**: NOT_ADOPTED for the abstraction. **Adjacent**: `platform/channel/` has behaviour.ex + discord.ex + telegram.ex + worker.ex + supervisor.ex — a per-channel adapter pattern but no unified gateway and no busy-input modes.

**Hermes (2026-05-18)**: REFACTORED. The abstraction is now realized as a **plugin registry** (`plugins/platforms/<name>/`, bundled platform plugins auto-load by default, 4d363499d). Generic plugin hooks for env enablement + cron delivery (af9336d57). Microsoft Teams added as a platform plugin (b3137d758); SimpleX Chat (09d9724a0); IRC interactive setup (868bc1c24). "Platform-as-adapter" is now plug-and-play, not just internal abstraction. Strengthens the adoption case if we ever expand beyond Discord+Telegram.

**Where**: `gateway/` + `plugins/platforms/`

**What**: One process serves Telegram, Discord, Slack, WhatsApp, Signal, Email, SMS, Matrix, Mattermost, Home Assistant, Microsoft Teams, SimpleX, IRC, etc. Per-platform display config. "Busy input mode": `interrupt | queue | steer` (steer injects new message after next tool call without interrupting). Plugins register via the generic plugin hook system; cron delivery routes through whichever platform's home channel matches.

**Why**: jido_radclaw has Discord + Telegram. Unified abstraction would help if we add SMS/email/etc.

**Adoption sketch**: Lift the **plugin registry pattern** (see T2-14 for the general shape) — each platform is a `JidoClaw.Platform.Channel` plugin that registers env-driven enablement + per-target delivery. Existing Discord and Telegram adapters become plugins. Steer/queue/interrupt is a separate, smaller change (see OQ-4).

---

### T3-12. Skin/theme engine

**Status (2026-05-18)**: NOT_ADOPTED. `cli/branding.ex` has hard-coded colors; no `.jido/skins/`.

**Hermes (2026-05-18)**: UNCHANGED in design. Skin YAML parsing hardened for invalid section types (5f234d405).

**Where**: `hermes_cli/skin_engine.py`

**What**: Skins are pure YAML data: colors, spinner faces, thinking verbs, tool emojis, branding strings. Built-ins: default/ares/mono/slate. Users drop `~/.hermes/skins/cyberpunk.yaml`.

**Why**: Personality polish. Low investment.

**Adoption sketch**: `.jido/skins/` directory + skin loader. `JidoClaw.CLI.Skin.get_active().tool_emoji(:read_file)`.

---

### T3-13. NEW — Install-method stamping + Docker detection

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `hermes_cli/config.py::detect_install_method` (line 204), `stamp_install_method` (line 234), `Dockerfile`, `docker/entrypoint.sh`, `scripts/install.sh`. Commit 6f5ec929a.

**What**: Each install pathway (Dockerfile, install.sh, cmd_postinstall) stamps an explicit method tag (`"docker"` / `"git"` / `"pip"`) into `~/.hermes/.install_method`. `detect_install_method()` reads the stamp first, then falls back to managed-system / container / `.git` heuristics. Used to surface the correct upgrade command for the user's install path.

**Gap**: jido_radclaw is distributed via mix/Hex/git rather than a single binary, but no analogous stamping happens — `mix jidoclaw.upgrade` would have to re-detect every time.

**Why it matters**: Low-cost ops hygiene. Stamping at install means `mix jidoclaw.upgrade` (or similar) can recommend the right command for each user, and telemetry can correctly bucket installs. Useful for diagnosing user issues ("you're on the git install, run `git pull && mix deps.get`").

**Adoption sketch**: New `.jido/.install_method` file. `mix.exs` `aliases :setup` and any future `:upgrade` task stamp + read. Detection fallback: presence of `_build/` + `.git/` → git install; presence in `/usr/local/lib/elixir/...` → managed; otherwise → unknown.

---

### T3-14. NEW — Windows bootstrap discipline (dep_ensure, install.ps1, footgun catalog)

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `hermes_cli/dep_ensure.py` (Windows awareness, PowerShell invocation, `(path, shell)` tuple returns), `scripts/install.ps1` (`-Ensure`/`-PostInstall` modes), `tools/browser_tool.py` (Windows `.cmd` shim candidates), `agent/async_utils.py` and assorted call sites (psutil-based PID/process management replacing POSIX-only `os.kill`/`os.killpg`/`os.setsid`/`SIGKILL`). Commits e3a254d65, cc38282b0, e93bfc6c9, 9de893e3b, 8bf09455d.

**What**: A disciplined Windows-portability layer: never `os.kill(pid, 0)` as a liveness probe (it broadcasts `CTRL_C_EVENT` on Windows), always `encoding='utf-8'` on bare `open()`, psutil for everything PID-related, `.cmd` shim dirs surfaced for npm, `AF_UNIX` sandbox gates removed, `/bin/bash` assumptions replaced, agent-browser auto-install for Chromium.

**Gap**: BEAM is more portable than CPython, but Forge sandboxing, libcluster, and any port-driven subprocesses still hit Windows-specific edge cases. No `.ps1` installer; no Windows-specific guidance in AGENTS.md.

**Why it matters**: The disciplined "we found N footguns, here are the rules" catalog is worth lifting as a checklist for Forge port and for any `:os.cmd` / `Port` callers. Even if Windows support isn't a near-term goal, the catalog is useful preemptive reading. If/when we want Windows support, this is the blueprint.

**Adoption sketch**: Read the catalog; add a checklist section to AGENTS.md for Windows portability gotchas. Audit `:os.cmd` and `Port` callers for Windows-hostile assumptions (shell paths, signal semantics, file encodings). Defer the actual `.ps1` installer until there's a real Windows user.

---

### T3-15. NEW — Multi-project boards (per-board isolation for unrelated work streams)

**Status (2026-05-18)**: NOT_ADOPTED for the pattern; **adjacent**: jido_radclaw uses Ash multi-tenancy which gives logical isolation, but not the env-pinned-subprocess-isolation hermes uses.

**Where in hermes**: `hermes_cli/kanban_db.py` (board isolation: `~/.hermes/kanban/boards/<slug>/`), worker env pins (`HERMES_KANBAN_BOARD`, `HERMES_KANBAN_DB`, `HERMES_KANBAN_WORKSPACES_ROOT`). Commit 5ec6baa40.

**What**: First-class isolation between projects/repos/domains. Each board is its own directory with its own SQLite db, workspaces dir, and logs dir. The `default` board keeps the legacy path for back-compat. Workers spawned by the dispatcher have `HERMES_KANBAN_BOARD` pinned so they physically cannot see other boards' tasks.

**Gap**: jido_radclaw's Ash multi-tenant setup gives logical isolation but worker processes don't have a comparable env-pinned guarantee — a misbehaving worker could in principle query across tenants.

**Why it matters**: For the "multiple unrelated workstreams on one install" case (different projects, different research directions), env-pinned workers add a defense-in-depth layer on top of Ash tenancy. The "physically cannot see other boards' tasks" guarantee is stronger than the logical-only equivalent.

**Adoption sketch**: When spawning worker processes (via `Tools.SpawnAgent`, the swarm tracker, cron workers), set `JIDO_TENANT_ID` / `JIDO_WORKSPACE_ID` env vars on the child. Worker startup reads these and refuses to operate against other tenants. Ash tenancy still does the logical separation; the env pin is defense-in-depth.

---

### T3-16. NEW — Diagnostic registry (pluggable rule engine for distress signals)

**Status (2026-05-18)**: NOT_ADOPTED. **Adjacent**: jido_radclaw's reasoning subsystem has classifier/strategy_store/pipeline_validator which are conceptually similar pure-function shapes but operate over reasoning context, not task/event/run distress signals.

**Where in hermes**: `hermes_cli/kanban_diagnostics.py` (new, stateless rule engine). Commit f67063ba8.

**What**: Pluggable diagnostic-rule engine where each rule is a pure function of `(task, events, runs, now, config) -> list[Diagnostic]`. Replaces ad-hoc per-symptom UI fields with a registry-driven system. v1 ships five distress kinds: phantom card ids (hallucinated_references), retry exhaustion, stuck workers, etc. Adding a new distress kind is one function + one registry entry, no UI changes.

**Gap**: jido_radclaw has telemetry but no "registry of pure-function rules that emit typed diagnostics" pattern. Each distress signal today would need ad-hoc code.

**Why it matters**: The shape — pure functions over context emitting typed verdicts — is exactly what jido_radclaw's reasoning-subsystem classifier already does for one domain. Lifting the registry pattern to diagnostics (about agent runs, scheduled tasks, worker health) reuses an idiom we already understand. Pairs with T3-2 (Insights) — diagnostics surface in the dashboard.

**Adoption sketch**: `JidoClaw.Diagnostics.Rule` behaviour: `apply(context) :: [%Diagnostic{kind, severity, evidence}]`. Registry GenServer in `lib/jido_claw/diagnostics/`. Initial rules: hallucinated-reference detector (over `Conversations.Message` tool_calls referencing non-existent ids), retry-exhaustion detector (over `Cron.Job` failures), stuck-worker detector (over `AgentTracker` state). Dashboard (T3-2) renders.

---

### T3-17. NEW — `/handoff` cross-platform live session transfer

**Status (2026-05-18)**: NOT_ADOPTED (new entry).

**Where in hermes**: `hermes_cli/cli.py` (`/handoff <platform>` command), `gateway/run.py::_handoff_watcher` (state machine on sessions table), state transitions: `None → 'pending' → 'running' → ('completed' | 'failed')`. Commit 00ce5f04d.

**What**: A user can transfer a live session from CLI to Discord (or any platform with a home channel) in real time. CLI flips the session row to `'pending'`; gateway's background watcher claims pending rows every 2s, resolves the target platform's home channel, asks the adapter for a fresh thread, and starts processing the destination chat immediately. CLI poll-blocks (60s) on terminal state — on `'completed'` prints `/resume` hint and exits like `/quit`.

**Gap**: jido_radclaw has Discord + Telegram adapters but no cross-surface live-handoff. Sessions are per-channel today.

**Why it matters**: Non-obvious good UX once you have multiple delivery surfaces. The state-machine + atomic-claim shape is the well-designed half — translates well to an Ash attribute + a watcher GenServer.

**Adoption sketch**: Add `handoff_state` to `Conversations.Session` (`:none | :pending | :running | :completed | :failed`) with target platform attribute. `JidoClaw.HandoffWatcher` GenServer claims pending rows. Channel adapters expose `start_thread/2` callback. CLI `/handoff <platform>` flips the row + poll-blocks.

---

### T3-18. NEW — xAI OAuth + cross-vendor execution-guidance principle

**Status (2026-05-18)**: NOT_ADOPTED.

**Where in hermes**: `agent/xai_oauth.py` + xai-oauth provider modules (b62c99797), `agent/transports/codex.py` (xAI Responses API), `agent/system_prompt.py` + `agent/prompt_builder.py` (`TOOL_USE_ENFORCEMENT_GUIDANCE` + `OPENAI_MODEL_EXECUTION_GUIDANCE` now extended to Grok). Commits b62c99797, 9b91377be, 31ba2b0cb, ad1aa1a03.

**What**: Two distinct things in one commit cluster. (a) Subscription-account auth (OAuth + PKCE, not API key) for xAI Grok — same shape as Anthropic Claude Code and OpenAI Codex OAuth. (b) The system-prompt enforcement that was originally written for GPT/Codex ("don't claim completion without tool calls", "use existing tools rather than suggesting workarounds", "act don't ask") was found to apply identically to Grok models — so it's now injected for any model whose name contains `'grok'`.

**Gap**: jido_radclaw's `security/vault.ex` handles API keys; no OAuth-PKCE flow for LLM subscription accounts. No "execution guidance applies to model families, not vendors" abstraction in any prompt template.

**Why it matters**: Two distinct lifts. (a) The OAuth-with-PKCE pattern is becoming the standard for LLM subscription accounts (Claude Code, Codex, Grok). Useful for `JidoClaw.Vault` once we want to support subscription auth. (b) The "guidance applies to model families" insight is non-obvious — once you've written tool-use enforcement for one OpenAI-family model, it applies to Grok, GLM, others. Cross-vendor pattern worth knowing.

**Adoption sketch**: Defer (a) until there's user demand for subscription-account auth. For (b): when writing or maintaining prompt templates for execution guidance, organize by *behavioral family* (OpenAI-style, Anthropic-style, ...) not by vendor.

---

## Open Questions Revisited

The cross-pollination report flagged seven items as "things worth a closer look later." Re-reading them with the Tier-1/2/3 ranking in hand:

### OQ-1. `run_agent.py` budget grace + interrupt loop semantics

**Status (2026-05-18)**: NOT_ADOPTED. `agent/agent.ex` is a thin 58-line shim delegating the loop to `Jido.AI.Agent`; no budget-grace-call or interrupt-loop changes.

**Hermes (2026-05-18)**: REFACTORED significantly — file decomposed. Multi-commit refactor (May 6–7) extracted: `agent/agent_init.py` (1381 LOC `__init__`), `agent/conversation_loop.py` (`run_conversation`), `agent/chat_completion_helpers.py` (893 LOC streaming caller), `agent/tool_executor.py`, `agent/system_prompt.py`, `agent/conversation_compression.py`, `agent/background_review.py`, `agent/tool_dispatch_helpers.py`, `agent/message_sanitization.py`, `agent/stream_diag.py`, `agent/codex_runtime.py`, `agent/iteration_budget.py`, `agent/agent_runtime_helpers.py`. The "12k LOC has many failure-recovery branches" framing is dated — patterns are now distributed across ~13 dedicated modules. Budget grace + interrupt-check semantics now live primarily in `agent/conversation_loop.py` and `agent/iteration_budget.py`.

**Applicability: HIGH**. Still relevant alongside T1-2 (compaction with explicit budgets) or T2-2 (credential rotation triggered by exhaustion). On its own, the patterns are general-purpose agent-loop hygiene.

**Recommendation**: Don't read in isolation — read alongside any future agent-loop refactor. Focus on `conversation_loop.py` + `iteration_budget.py` (much shorter than the old 12k-LOC `run_agent.py`). Easier to mine post-decomposition.

---

### OQ-2. `auxiliary_client.py` exact 402/429/5xx fallback ordering

**Status (2026-05-18)**: NOT_ADOPTED. Depends on T2-3 (auxiliary client) which is NOT_ADOPTED.

**Hermes (2026-05-18)**: REFACTORED. The fallback ordering is now documented at `website/docs/user-guide/features/fallback-providers.md`. The 4-step layered ladder (primary → user-configured chain → main-agent safety net → warn) **is** the canonical model. See T2-3 above for the full description.

**Applicability: MEDIUM**. Only relevant alongside T2-3. The general principle (402 = walk down chain; 429 = same-provider cooldown; 5xx = retry-then-walk; main-agent as last-resort safety net) is the lift, alongside the per-task configurable `fallback_chain`.

**Recommendation**: Read alongside T2-3 implementation. Skip otherwise.

---

### OQ-3. `_summarize_tool_result` per-tool 1-line summary catalog

**Status (2026-05-18)**: PARTIAL. `conversations/tool_transcript.ex::result_summary/2` has a catalog of tool-name → one-line summaries (`tool_name → ok` / `tool_name → error: reason`), but it's strictly for the Postgres transcript `content` column (one-line preview), NOT a model-facing compaction summary like `[terminal] ran 'X' -> exit 0, N lines output`. The catalog is too thin to satisfy OQ-3's prompt-engineering bar.

**Gap (refreshed)**: The terse one-liners would need to be expanded into model-facing summaries (exit codes, line counts, search-result counts) as part of any future T1-2 implementation. Foundation exists — the dispatch shape is right, just the content depth differs.

**Hermes (2026-05-18)**: UNCHANGED.

**Applicability: HIGH**. If we adopt T1-2 (context compaction), we need per-tool summarization formats. Hermes's catalog is the result of months of prompt engineering. Most can lift directly with tool-name swap.

**Recommendation**: Extend the existing `tool_transcript.ex::result_summary/2` catalog with model-facing details (exit codes, line counts, search result counts) and reuse it as the basis for T1-2's `summarize_tool_result/2`. Test that the model doesn't try to re-execute summarized work.

---

### OQ-4. `gateway/run.py` busy-input semantics (interrupt/queue/steer)

**Status (2026-05-18)**: NOT_ADOPTED. `cli/repl.ex` reads stdin synchronously — no "user types while agent is mid-tool-call, injected after next tool call" steer mode.

**Hermes (2026-05-18)**: UNCHANGED in design. TUI v2 now also honors `display.busy_input_mode` (af6b1a334) — the steer/queue/interrupt modes apply across CLI, TUI, and gateway surfaces. Strengthens the case slightly.

**Applicability: LOW-MEDIUM, with one extractable gem**. The "steer" mode — user types a new message while the agent is mid-tool-call; the message is injected after the next tool call **without** interrupting the in-flight work — is a notably good UX pattern. Applies to the CLI REPL today.

**Recommendation**: Read just the "busy input mode" section (~few hundred LOC). Steer mode could be a small standalone CLI feature; don't need the rest of the gateway.

---

### OQ-5. `agent/redact.py` vendor key-prefix regexes

**Status (2026-05-18)**: PARTIAL. `security/redaction/patterns.ex` has 9 patterns (Anthropic key, OpenAI/generic sk-, jidoclaw_, ghp_/github_pat_, Bearer, JWT, URL-with-userinfo, generic password/secret/token kv, AWS AKIA). `security/redaction/env.ex` adds suffix-match (_KEY/_TOKEN/_SECRET/_PASSWORD/_PASS/_PAT) and AWS-specific names. Coverage is solid but narrower than hermes's 24+ vendor prefixes.

**Gap (refreshed)**: ~15+ vendor-prefix patterns still missing — no Slack `xoxb-`/`xoxp-`, no Google service-account, no Perplexity `pplx-`, no Fal, no Firecrawl `fc-`, no BrowserBase, no SendGrid `SG.`, no Stripe `sk_live_`/`pk_live_`, no Mailgun, no Heroku. The additions are mechanical lifts from `hermes/agent/redact.py`.

**Hermes (2026-05-18)**: UNCHANGED in pattern set. Secret redaction is now **enabled by default** (`HERMES_REDACT_SECRETS=true` is the install default, fb1ce793e). Canonical `mask_secret` helper extracted (8c892c145). The "direct lift" recommendation is still valid; patterns are well-tested-in-production now.

**Applicability: HIGH, direct lift**.

**Recommendation**: Open `agent/redact.py`, copy the missing patterns into `security/redaction/patterns.ex`. Verify with property-based tests against common UUIDs/hashes to avoid false positives.

---

### OQ-6. `agent/insights.py` terminal bar chart approach

**Status (2026-05-18)**: NOT_ADOPTED. Same as T3-2.

**Hermes (2026-05-18)**: UNCHANGED.

**Applicability: HIGH**. T3-2 (insights engine) is where this lives. SQL/aggregation logic transfers directly (Postgres has all the same operators); rendering layer is different (LiveView HTML vs terminal `█` bars) but trivial. The genuinely useful part is **what to aggregate**: tokens by model, cost estimate (per-model pricing snapshot), activity by day-of-week + hour, daily streak.

**Recommendation**: Read alongside any T3-2 implementation. Lift the SQL queries; rewrite the rendering for LiveView.

---

### OQ-7. `_validate_commit_hash` defensive validation

**Status (2026-05-18)**: NOT_ADOPTED. `tools/git_commit.ex` accepts `message` and `files` from agent input — `files` passes through `git add --` (line 44) which gives `--`-stop-flag-parsing protection, but `git commit -m message` does not validate `message` against `--patch`-style injection. No commit-hash-accepting tool exists yet, but the validator pattern isn't applied to any current git tool input either.

**Hermes (2026-05-18)**: UNCHANGED (v2 single-store rewrite preserved the validator).

**Applicability: HIGH, focused borrow**. Defensive against `--patch`-as-commit-hash injection (a "commit hash" string that's actually a git flag). Directly applicable to `Tools.GitCommit`, `Tools.GitDiff`, `Tools.GitStatus`. Short, easy to apply, eliminates an attack vector. Bonus: aligns with the LLM-misbehavior threat-model focus.

**Recommendation**: Read the function (~30 LOC). Apply the validator to all git tools that accept agent-generated input. Equally relevant if we adopt T2-5 (shadow-git checkpoint manager).

---

## Cross-references and dependencies

Some items compose. Refreshed dependency graph for adoption sequencing (changes vs the 2026-04-28 graph noted inline):

- **T2-3** (auxiliary client) is a prerequisite for **T1-2** (compaction summaries on cheap models), **T2-8** (risk classifier), **T2-15** (curator), **T2-16** (`/goal` judge), **T3-8** (auto-title). ~~**T1-9** (recall summaries)~~ — **REMOVED**: hermes deleted the aux-LLM summarizer; T1-9 is no longer downstream of T2-3.
- **T1-4** (error classifier) sets flags consumed by **T1-10** (rate guard), **T2-2** (credential pool), **T1-2** (should-compress flag), **T2-3** (capacity-error fallback gating).
- **T1-5** (prompt scrubber) and **T2-7** (OSV check) are independent security hardening — no dependencies.
- **T1-6** (knowledge skills) is independent of existing pipeline-skills — they coexist, not replace.
- **T1-1** (PTC) is independent and the highest-leverage standalone item.
- **T1-11** (auto-decomposition) is enabled by **T2-3** (aux LLM judge) and ideally **T2-1** (subagent discipline) for clean child behavior; pairs with **T1-8** (MoA for hard root tasks).
- **T2-1** (subagent discipline) is a precursor for **T1-11** (auto-decomposed children).
- **T2-12** (ACP edit approval) pairs with **T2-8** (risk classifier) — write half + command half.
- **T2-14** (ABC + registry plugin pattern) is the general shape used by **T2-6** (memory providers) and **T3-11** (platform plugins).
- **T2-15** (curator) is enabled by **T2-3** (aux client) and **T2-10** (cron scheduling).
- **T2-16** (`/goal`) is enabled by **T2-3** (aux judge).
- **T2-17** (post-write delta-lint) pairs with **T2-12** (edit approval) — both wrap file-mutating tools.

**Revised first wave** (foundations + their natural payoff items, no aux-summarizer dependency for T1-9): **T1-4 → T2-3 → T1-2 → T1-3 → T1-5 → T1-9 → OQ-5/OQ-7**. T1-9 can ship anywhere in this wave now that it doesn't need T2-3 — moving it earlier might make sense given the FTS infra is already built.

**Revised second wave** (after foundations): **T1-1 (PTC) → T1-11 (auto-decomposition) → T2-15 (curator) → T1-7 (cache discipline writedown) → T1-10 (cluster rate guard, generalized from embeddings) → T2-17 (delta-lint)**.

**Revised third wave** (platform/UX/integration): **T2-11 (deliverable mode) → T2-12 (edit approval) → T2-16 (`/goal`) → T3-2 + OQ-6 (insights) → T3-17 (`/handoff`)**.

---

## Appendix A: Borrowed but with major translation

These hermes patterns informed the inventory but won't translate cleanly:

- **Six terminal/execution backends** (`tools/environments/`) — **SUPERSEDED**. Forge has its own multi-runner abstraction: `forge/runner/host_shell.ex` + `forge/runners/{claude_code,codex,custom,fake,shell,workflow}.ex` + `forge/sandbox/{behaviour,docker}.ex`. The Codex sibling runner (`forge/runners/codex.ex`) was added in the Memory Phase 4 work. Hermes added a 7th backend (Vercel Sandbox); we'd add new runners under `forge/runners/` if we wanted that coverage.
- **Shadow-git checkpoint** at `~/.hermes/checkpoints/{sha}/` — path layout **SUPERSEDED** (we chose Postgres-row checkpoints on `forge/resources/checkpoint.ex` for multi-tenant safety). The behavior pattern is still in T2-5 (PARTIAL); the path layout choice has been made.
- **`HERMES_HOME` env var profile system** — superseded by jido_radclaw's per-project `.jido/` model in the common case. Listed in T3-5 as a fallback mechanism only.

## Appendix B: Hermes patterns we explicitly skip

- **Tirith Rust pre-exec scanner** binary distribution model — auto-downloading external binaries is a maintenance burden. T3-3 lists it as optional.
- **Multi-platform gateway** beyond Discord+Telegram — interesting but not aligned with current product direction; T3-11 (note that the hermes plugin-registry shape is now strong enough that *if* we want to expand, the lift is smaller than it was).
- **Skin/theme engine** — fun but not load-bearing; T3-12.
- **Discord.py-style direct bot** — we already have Nostrum, which is better.

## Appendix C: What jido_radclaw has that hermes doesn't

For orientation when comparing — these are jido_radclaw advantages, not borrows:

- Real OTP concurrency (`Jido.Signal.Bus`, `:pg`, libcluster) vs. `ThreadPoolExecutor`
- Ash + Postgres declarative data layer vs. SQLite + ad-hoc SQL. **Expanded since 2026-04-28**: new resources under `accounts/`, `conversations/` (Session, Message, RequestCorrelation, GlobalLookup), `workspaces/`, `memory/resources/` (Block/BlockRevision/ConsolidationRun/Episode/Fact/FactEpisode/Link/ScopeFilter), `audit/resources/` (Event), `solutions/resources/` (Solution/Reputation/ReputationImport) — full multi-tenant declarative data layer.
- Phoenix LiveView dashboard vs. embedded xterm in FastAPI. LiveView pages include agents_live, dashboard_live, folio_live, forge_live, projects_live, settings_live, setup_live, sign_in_live, workflows_live.
- Reasoning subsystem with strategy/pipeline stores, classifier, certificate templates, llm_tiebreak, statistics, telemetry. **Expanded**: now also tracks outcomes (`reasoning/resources/outcome.ex`).
- Solutions subsystem (fingerprinting, trust scoring, semi-formal verification). **Expanded since 2026-04-28**: full hybrid retrieval (RRF over FTS5+pgvector+pg_trgm) at `solutions/hybrid_search_sql.ex`; network facade for federated lookup.
- DAG skill engine with `depends_on` (complementary to T1-6, not redundant). Ten skills in `.jido/skills/` covering debug, explore, full review, implement feature, iterative feature, onboard dev, refactor safe, security audit, SFR review, verified feature.
- VFS routing (`github://`, `s3://`, `git://`) — broader than hermes's path handling. **Expanded**: `resolver.ex` gained `:project_dir` jailing per the recent audit work.
- Native Anubis MCP server (Elixir) and ACP — hermes's MCP server is Python. **Expanded**: `memory/consolidator/mcp_server.ex` is a per-run scoped MCP server for the consolidator harness.
- Native Discord and Telegram via Nostrum-style adapters (BEAM-native bots, not discord.py wrappers).
- Forge as a first-class sandboxed-execution engine. **Expanded**: Codex sibling runner (`forge/runners/codex.ex`) added; checkpoint persistence on `forge/resources/checkpoint.ex`; multiple sandbox backends.
- **NEW since 2026-04-28**: Audit log + tenant FK promotion (`audit/`); Workspaces + Sessions as first-class resources (`workspaces/`, `conversations/`); MCP scope subsystem (`mcp_scope/`); embeddings rate-pacer with cluster-shared dispatch window (`embeddings/`); per-tenant authorization layer (`authorization/`); cross-tenant FK enforcement (`security/cross_tenant_fk.ex`).

## Appendix D: Re-review changelog (2026-05-18)

Summary of changes from the 2026-04-28 baseline:

**Status added to every existing entry.** Status legend at top of document.

**Entries whose Hermes description was refreshed**: T1-2 (`protect_first_n` knob, media stripping), T1-4 (timeout patterns), T1-7 (1h prefix layout tried+reverted; "system_and_3" naming dated), T1-9 (**aux-LLM summarizer deleted**; single-shape discovery/scroll/browse rewrite), T2-3 (**4-step layered fallback ladder**), T2-5 (v2 single-store rewrite), T2-6 (`on_session_switch` hook added), T2-8 (pattern set expanded), T2-10 (`no_agent` mode added), T3-4 (block handler), T3-11 (plugin migration), T3-12 (parser hardening), OQ-1 (`run_agent.py` decomposed into ~13 modules), OQ-2 (canonical doc now exists), OQ-4 (TUI also honors busy-input modes), OQ-5 (now default-on).

**Entries whose Gap was refreshed (PARTIAL adoptions)**: T1-6, T1-7, T1-9, T1-10, T2-5, T2-6, T2-8, T2-9, OQ-3, OQ-5.

**New entries added** (14 total):
- Tier 1: T1-11 (orchestrator-driven auto-decomposition)
- Tier 2: T2-11 (deliverable mode), T2-12 (ACP edit approval), T2-13 (Codex app-server runtime), T2-14 (ABC+registry plugin pattern), T2-15 (curator), T2-16 (`/goal` persistent loop), T2-17 (post-write delta-lint)
- Tier 3: T3-13 (install-method stamping), T3-14 (Windows bootstrap discipline), T3-15 (multi-project boards), T3-16 (diagnostic registry), T3-17 (`/handoff` cross-platform), T3-18 (xAI OAuth + cross-vendor guidance)

**Appendix changes**: Two Appendix A items moved to SUPERSEDED (Forge runners; Postgres-row checkpoints). Appendix C expanded with new jido_radclaw subsystems since 2026-04-28.

**Dependency graph rewritten**: T1-9 no longer depends on T2-3 (hermes deleted the dependency); new dependencies added for T1-11, T2-11..T2-17, T3-13..T3-18. First/second/third-wave recommendations revised.
