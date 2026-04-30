# Features Worth Borrowing from Hermes-Agent

Exploration notes — not a plan, not a commitment. Source: `~/workspace/claws/hermes-agent` (Nous Research, Python 3.11+ self-improving agent platform). Compared against jido_radclaw as of 2026-04-28.

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

**Where**: `tools/code_execution_tool.py`

**What**: Generates an `hermes_tools.py` stub that exposes the agent's tools as RPC-callable functions. The LLM writes a Python script that orchestrates multiple tool calls; only stdout returns to the LLM. Two transports: UDS for local, file-based RPC for Docker/SSH/Modal/Daytona/Singularity. Sandbox-allowed list (`web_search`, `web_extract`, `read_file`, ...).

**Gap**: jido_radclaw has Forge for sandboxed execution of _user-provided_ code, but no pattern for the LLM to write a script that batches its own tool calls in a single inference turn.

**Why it matters**: This is the single biggest token/latency lever in the inventory. A 10-tool-call investigation collapses to 1 inference turn. Intermediate tool results never enter LLM context, so context bloat shrinks dramatically. Forge already exists as the sandbox host — we have ~80% of the infrastructure.

**Adoption sketch**: New `JidoClaw.Tools.RunScript` action. Forge's runner hosts a Python (or Elixir) process; before launch, generate a `jido_tools.py` (or `.exs`) stub mapping each existing `Jido.Action` to an RPC call. The agent process runs an Elixir RPC server on a UDS socket; the script makes synchronous calls into it. Reuse Forge's sandbox boundary for isolation. Allowlist tools per call (mirrors hermes's sandbox set). Open question: do we ship Python in Forge for richer LLM script-writing, or stick with Elixir and accept smaller training-data coverage?

---

### T1-2. Layered context compaction with structured handoff

**Where**: `agent/context_compressor.py`, `agent/context_engine.py`, `agent/manual_compression_feedback.py`

**What**: A pluggable `ContextEngine` ABC. Pre-pass replaces tool-output dumps with one-line summaries (`[terminal] ran 'npm test' -> exit 0, 47 lines output`) before the LLM ever sees them. Then a structured summary template ("Resolved/Pending/Active Task/Remaining Work") with an explicit `SUMMARY_PREFIX` warning the model: "treat as background, your task is in `## Active Task`, don't re-execute." Token-budget tail protection. Image cost (`_IMAGE_TOKEN_ESTIMATE = 1600`) included. Iterative summary updates across multiple compactions.

**Gap**: No compaction system exists in jido_radclaw (`grep -rli "compact\|compress" lib/jido_claw` only hits display branding and `forge/context_builder.ex`). Long sessions hit context limits with no graceful degradation.

**Why it matters**: Without structured handoff, compaction either drops information silently or causes the model to re-execute work. The "Resolved/Pending/Active Task/Remaining Work" structure (deliberately not "Next Steps", which the model reads as imperatives) plus the explicit "this is background, not your assignment" prefix is hard-won prompt engineering.

**Adoption sketch**: New `JidoClaw.Reasoning.ContextEngine` behaviour with `compress/2`, `summarize_tool_result/2`, `handoff_template/1`. Plug into the agent's pre-LLM-call step. Existing reasoning subsystem (`lib/jido_claw/reasoning/`) gives a natural home — it already has classifier, telemetry, certificates. Default implementation: `JidoClaw.Reasoning.Compactor.Default`. Future: an LCM-style alternative.

---

### T1-3. Subdirectory hint discovery

**Where**: `agent/subdirectory_hints.py`

**What**: As tools are called with paths (`read_file`, `terminal`, etc.), this tracker walks ancestor directories (up to 5 levels) and lazily loads any `AGENTS.md`/`CLAUDE.md`/`.cursorrules` it hasn't seen yet, appending the content to **the tool result** (not the system prompt — so prompt cache stays valid). Inspired by Block/goose. Dedup via `_loaded_dirs` set.

**Gap**: jido_radclaw appears to load `AGENTS.md` once at startup (or via `system_prompt.md`). Subprojects in monorepos with their own conventions get ignored.

**Why it matters**: Real-world repos have nested AGENTS.md files (a backend monorepo, a frontend submodule, a test fixture's README). Without progressive discovery the agent operates with stale or missing context for any directory it didn't start in.

**Adoption sketch**: A `JidoClaw.Agent.HintTracker` GenServer keyed per session. Path-bearing tools (the `Tools.RunCommand`, `Tools.ReadFile`, `Tools.EditFile`, etc.) post path events; the tracker walks ancestors and emits at most one `[Project hint: <path>]` block appended to the tool result. ETS-backed loaded-set per session. Cache-friendly (system prompt never mutates).

---

### T1-4. Structured error classifier with `FailoverReason` taxonomy

**Where**: `agent/error_classifier.py` (1000+ lines)

**What**: A `FailoverReason` enum (auth/billing/rate_limit/overloaded/context_overflow/payload_too_large/image_too_large/model_not_found/provider_policy_blocked/thinking_signature/long_context_tier/format_error/timeout/...). `classify_api_error()` runs a priority pipeline (HTTP status → message patterns → SSL/transport heuristics → fallback) and returns a `ClassifiedError` with action booleans: `(retryable, should_compress, should_rotate_credential, should_fallback)`. The retry loop just consults flags — no inline string matching.

**Gap**: No equivalent in jido_radclaw (`grep -li "FailoverReason\|classify_error" lib/jido_claw` returns nothing). Provider error handling is presumably scattered through `Jido.AI` adapter code.

**Why it matters**: As provider count grows, decision logic for "retry vs compact context vs rotate key vs fall back to a different model" gets tangled across modules. A single taxonomy keeps recovery decisions cohesive and testable. Pairs naturally with the reasoning subsystem's certificate templates and telemetry.

**Adoption sketch**: New `JidoClaw.Providers.ErrorClassifier` module. Public API: `classify(error_or_response) :: %ClassifiedError{reason: atom, retryable?: bool, should_compress?: bool, should_rotate_credential?: bool, should_fallback?: bool}`. Provider adapters (or `Jido.AI`'s retry path, depending on where the seam is cleanest) consult flags. Reasons emitted as telemetry events for the existing telemetry pipeline.

---

### T1-5. Context-file injection scanning

**Where**: `agent/prompt_builder.py::_scan_context_content`, threat patterns at top of file

**What**: Before injecting `AGENTS.md`/`CLAUDE.md`/`SOUL.md`/`.cursorrules` into the system prompt, scan for prompt-injection patterns: `ignore previous instructions`, hidden Unicode (`​/⁠/﻿`), `<div style=display:none>`, `<!--ignore...-->`, `curl ... $TOKEN`, etc. If any pattern hits, replace content with a `[BLOCKED: <reason>]` marker. Same scan applies to memory writes (`tools/memory_tool.py`).

**Gap**: jido_radclaw's VFS routes `github://`, `s3://`, `git://` to backends. Anything fetched via these URLs could carry a prompt-injection payload that flows directly into the agent's context. No equivalent scrubber today.

**Why it matters**: Prompt injection is increasingly weaponized (poisoned READMEs in dependency packages, malicious comments in fetched gists). Direct security hardening with low blast radius — we just refuse to inject suspect content.

**Adoption sketch**: New `JidoClaw.Security.PromptScrubber` module — regex set + Unicode invisible-char detection. Public API: `scan(content) :: {:ok, content} | {:blocked, reason}`. VFS fetchers (`JidoClaw.VFS.Resolver` and backends) call it before returning content destined for prompt injection. Memory writes (`Tools.Remember`) also call it. Lift the regex set verbatim from hermes — the patterns are well-curated.

---

### T1-6. Anthropic-style SKILL.md with progressive disclosure

**Where**: `tools/skills_tool.py`, `tools/skills_hub.py`, hundreds of `skills/<name>/SKILL.md` files

**What**: Each skill is a directory with:

- `SKILL.md` — YAML frontmatter (`name`/`description`/`platforms`/`metadata.hermes.config`/`tags`) + body
- `references/` — loaded on demand via `skill_view("name", "references/api.md")`
- `templates/`, `scripts/`, `assets/`

Tier 1 = `skills_list` (metadata only — budget-friendly). Tier 2 = `skill_view` (loads SKILL.md body). Tier 3 = `skill_view("name", "references/...")`. Frontmatter declares config requirements (auto-prompted in setup, auto-injected as `[Skill config: ...]` block at load).

**Gap**: jido_radclaw skills are YAML DAGs (`depends_on`) executed by `run_skill`/`run_pipeline` — declarative orchestration. Hermes skills are LLM-readable procedural knowledge: "how do I do X?" The two are different shapes solving different problems.

**Why it matters**: Procedural knowledge ("here's the right way to add a new Ash resource") is the wrong fit for a DAG. It's the right fit for progressive-disclosure markdown the agent reads when needed. Anthropic ships their own SKILL.md format; aligning with the de-facto standard means we benefit from public skill libraries.

**Adoption sketch**: Distinct from existing pipeline-skills. Add a flavor field to skill metadata (`kind: pipeline | knowledge`) or a separate `.jido/knowledge/` directory. New tools: `knowledge_list` (returns frontmatter only) and `knowledge_view(name, ?path)`. Existing skill executor and DAG semantics unchanged. Optional: skill-config auto-injection in main agent prompt.

---

### T1-7. Anthropic prompt-caching `system_and_3` discipline

**Where**: `agent/prompt_caching.py` + AGENTS.md "Prompt Caching Must Not Break" policy

**What**: 4 cache_control breakpoints (Anthropic max): system + last 3 non-system messages. Plus a project-wide invariant: **never mutate context mid-conversation**. Cache-invalidating slash commands MUST default to deferred (apply to next session) with opt-in `--now` flag. `/skills install --now` is the canonical example.

**Gap**: I don't see explicit cache-control marker placement in jido_radclaw's worker templates, and the "don't mutate context mid-session" discipline isn't codified in AGENTS.md.

**Why it matters**: At Opus pricing, cache hit rate is the difference between an affordable and a ruinous deployment. The marker placement is mechanical (~10 LOC); the discipline is the hard part — it has to be enforced in code review and in slash-command design. Codifying it explicitly turns "we should be careful about caching" into "this PR breaks cache hygiene, here's the rule it violates."

**Adoption sketch**: Two parts:

1. **Mechanical**: worker template prompt assembly explicitly places `cache_control` markers at system + last 3 message boundaries when calling Anthropic.
2. **Cultural**: new section in AGENTS.md ("Prompt cache invariants"). Skill executor and slash-command handlers refuse to mutate session-scoped state mid-session by default; emit a "deferred to next session" notice unless the caller passes `now: true`.

---

### T1-8. Mixture-of-Agents worker template

**Where**: `tools/mixture_of_agents_tool.py`

**What**: Sends one prompt to N reference models in parallel (claude-opus, gemini-pro, gpt-pro, deepseek), then an aggregator model synthesizes the responses. References use temp 0.6, aggregator uses 0.4. Graceful degradation: `MIN_SUCCESSFUL_REFERENCES = 1`.

**Gap**: jido_radclaw has Coder/Reviewer/Researcher worker templates but no ensemble-style worker.

**Why it matters**: For hard reasoning tasks (architectural decisions, root-cause analysis on tangled bugs), ensemble outperforms monolithic single-model output — and the marginal cost is acceptable because these tasks already burn tokens. Trivial to OTP-ify with `Task.async_stream` (we get back-pressure and per-task supervision for free).

**Adoption sketch**: New `lib/jido_claw/agent/workers/mixture_of_agents.ex` using `Jido.AI.Agent`. Reference list config-driven (`.jido/config.yaml`). `Task.async_stream` over references with `:max_concurrency` + per-task timeout. Aggregator runs after stream completes. Wire into the swarm so the main agent can spawn an MoA sub-agent.

---

### T1-9. Session search via FTS + auxiliary-LLM summarization

**Where**: `tools/session_search_tool.py`, `hermes_state.py`

**What**: Single SQLite (`~/.hermes/state.db`, WAL mode) with `sessions` and `messages` tables, plus an FTS5 virtual table over message content + tool_name + tool_calls. `session_search` runs FTS5 → groups hits by session → fetches top N → **summarizes each session via auxiliary LLM (cheap model)** → returns per-session summaries (NOT raw transcripts) to the main model.

**Gap**: jido_radclaw stores sessions in `.jido/sessions/` and via `JidoClaw.Platform.Session` (Ash + Postgres). No equivalent search-and-summarize tool surfaces exist.

**Why it matters**: The summarize-not-transcript design is the real innovation. As session count grows, an agent should be able to answer "have we hit this issue before?" without flooding context with 50KB of transcripts. Cheap-model summaries keep recall context-efficient.

**Adoption sketch**: Add Postgres FTS or `pg_trgm` index on `Platform.Session` message content. New `Tools.RecallSession(query, limit)` action. For each match: fetch session messages → call auxiliary LLM (T2-3 below) for per-session summary → return only summaries. Caches summaries on the session resource so repeated lookups are cheap.

---

### T1-10. Cross-cluster rate-limit guard via `:pg`

**Where**: `agent/nous_rate_guard.py`, `agent/rate_limit_tracker.py`

**What**: When one process gets a 429 from a provider, it persists rate-limit state to `~/.hermes/rate_limits/<provider>.json` so other processes (CLI, gateway, cron, auxiliary) check before attempting a request. Eliminates retry amplification (3 SDK retries × 3 internal retries = 9 calls per turn against your RPH).

**Gap**: jido_radclaw uses libcluster + `:pg`. Multi-node clusters can independently retry against the same provider quota — burning 9N calls per 429 across N nodes.

**Why it matters**: BEAM clustering makes the worst-case worse by default — file-based persistence is the wrong shape for clustered processes, but `:pg` is the right shape for cluster-shared rate-limit state. Treating provider quota as a cluster-wide resource is something hermes can't do natively but we can.

**Adoption sketch**: A `:pg` group `:rate_limits` storing `%{provider => %{reset_at: ts, status: :exhausted}}`. Provider call wrapper checks the group state before a request; on 429, broadcasts the new exhaustion. Provider-supplied `Retry-After` headers override timestamps. Lives naturally in `lib/jido_claw/providers/rate_guard.ex`.

---

## Tier 2 — Medium Impact

### T2-1. Subagent delegation discipline (blocklist + summary-only)

**Where**: `tools/delegate_tool.py`

**What**: Spawned subagents get: fresh conversation, restricted toolset (`DELEGATE_BLOCKED_TOOLS = {delegate_task, clarify, memory, send_message, execute_code}` — no recursion, no user interaction, no shared MEMORY.md), focused system prompt. Parent only sees the call + summary; child's intermediate steps never enter parent context.

**Gap**: jido_radclaw's swarm is OTP-supervised (better isolation infra than threads), but I don't see explicit per-template tool blocklists or summary-only contracts.

**Why it matters**: Without blocklists, recursion depth and memory pollution can spiral. Summary-only contract keeps parent context lean — key for long-running parent agents that delegate often.

**Adoption sketch**: Worker-template option `:blocked_tools` (atom list) and `:summary_only?` (bool). `JidoClaw.AgentTracker` enforces; main-agent context only receives summary on completion.

---

### T2-2. Multi-credential pool with strategy + cooldowns

**Where**: `agent/credential_pool.py`, `agent/credential_sources.py`

**What**: Per-provider pool of `PooledCredential` objects with `(last_status, last_error_code, last_error_reset_at, request_count)`. Strategies: `fill_first | round_robin | random | least_used`. 429/402 → mark exhausted with TTL (provider headers override the default cooldown).

**Gap**: jido_radclaw's Vault stores secrets but I don't see automatic rotate-on-rate-limit.

**Why it matters**: Users who rotate keys (e.g., personal + team Anthropic key) effectively double their RPH ceiling — invisibly. Pairs naturally with T1-4 (error classifier sets `should_rotate_credential?`).

**Adoption sketch**: `JidoClaw.Security.CredentialPool` GenServer per provider. Vault stores N credentials per provider; pool selects via configured strategy; classifier flag triggers rotation.

---

### T2-3. Auxiliary client router for side tasks

**Where**: `agent/auxiliary_client.py`

**What**: Single `call_llm()` for "side tasks" (summarization, title generation, vision analysis, web extraction). Resolves backends in a documented priority chain (OpenRouter → Nous Portal → Custom → Codex OAuth → Anthropic → direct providers); on 402 (credit exhaustion), automatically retries down the chain. Per-task overrides (`auxiliary.<task>.provider`). Vision and text get separate chains.

**Gap**: jido_radclaw uses Jido.AI multi-provider but not the explicit "side tasks pick a cheaper backend with cascade fallback" pattern.

**Why it matters**: Title generation, compaction summaries (T1-2), recall summaries (T1-9), and reasoning classifier shouldn't run on the most expensive model. Without an aux-router, every side-task call is at main-model pricing — death by a thousand cuts.

**Adoption sketch**: `JidoClaw.Providers.AuxiliaryClient` with config-driven chain in `.jido/config.yaml`. Public API: `call(:summarize | :title | :classify, prompt, opts)`. Per-task provider+model override. On 402/quota, walk the chain.

---

### T2-4. Skill security guard with trust-level matrix

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

**Where**: `tools/checkpoint_manager.py`

**What**: NOT a tool the LLM sees. Before file-mutating ops (`write_file`, `patch`), automatically snapshots the working dir to a per-directory shadow git repo at `~/.hermes/checkpoints/{sha256(dir)[:16]}/` using `GIT_DIR + GIT_WORK_TREE` so no `.git` lands in the user's project. Snapshots once per turn. `/restore` rolls back. Default excludes `node_modules`, `dist`, `.env*`, etc.

**Gap**: jido_radclaw doesn't appear to have automatic file-mutation rollback.

**Why it matters**: Lets users undo a bad agent session without losing intermediate state. Distinct from VFS — this is filesystem rollback, not virtualization.

**Adoption sketch**: Hook `Tools.WriteFile`/`Tools.EditFile` pre-execution. Per-tenant or per-session checkpoint dir under `.jido/checkpoints/`. New CLI command `/restore <checkpoint-id>`. Excludes lifted from hermes verbatim.

---

### T2-6. Pluggable memory provider ABC + frozen snapshots

**Where**: `agent/memory_provider.py`, `agent/memory_manager.py`, `plugins/memory/<name>/`

**What**: `MemoryProvider` ABC with `initialize/system_prompt_block/prefetch/sync_turn/get_tool_schemas/handle_tool_call/shutdown`, plus optional hooks (`on_turn_start`, `on_session_end`, `on_pre_compress`, `on_memory_write`, `on_delegation`). Built-in `BuiltinMemoryProvider` is always-on (writes `MEMORY.md`/`USER.md`). At most ONE external provider (honcho/mem0/supermemory/byterover/...). System prompt has _frozen_ memory snapshots (cache stays valid); writes go to disk immediately but don't mutate context until next session.

**Gap**: `lib/jido_claw/platform/memory.ex` exists but no provider ABC; the frozen-snapshot discipline isn't explicit.

**Why it matters**: Pluggable memory is becoming standard in agent platforms. Frozen-snapshot discipline is the lesser-known but important half — it's how you keep cache hits high while still writing memories during a session.

**Adoption sketch**: `JidoClaw.Memory.Provider` behaviour. Default `JidoClaw.Memory.Providers.Builtin` writes to `.jido/memory.json` + `MEMORY.md`. External providers under `lib/jido_claw/memory/providers/`. Discipline: writes persist immediately; the in-context `<memory-context>` block is taken from a session-start snapshot and not mutated until the next session.

---

### T2-7. OSV malware check before MCP server launch

**Where**: `tools/osv_check.py`

**What**: Checks `npx`/`uvx` MCP server packages against `MAL-*` advisories from osv.dev before launching the subprocess.

**Gap**: AGENTS.md shows we recommend users add jidoclaw to their `.mcp.json`. If we ever spawn third-party MCP servers (outbound — agent connects to an MCP), we have no malware check.

**Why it matters**: Supply-chain attacks on `npm`/`pypi` MCP packages are a known vector. Free-ish defense.

**Adoption sketch**: `JidoClaw.Security.OsvCheck` querying `https://api.osv.dev/v1/query`. Called before any subprocess that runs a third-party `npm`/`pip`/`pypi` package. Cache results per-version with short TTL.

---

### T2-8. Approval system with auxiliary-LLM auto-classifier

**Where**: `tools/approval.py`

**What**: Per-session approval state via `contextvars` (gateway runs concurrent sessions). Pattern detection (DANGEROUS_PATTERNS) → either prompt user OR send command to an auxiliary LLM that classifies risk and auto-approves low-risk ones. Permanent allowlist persistence. Plugin hooks (`pre_approval_request`, `post_approval_response`).

**Gap**: jido_radclaw has tool-permission checks but auxiliary-LLM risk classification is novel.

**Why it matters**: Reduces approval friction (the agent doesn't ask "can I run `ls`?") without giving up safety on actually dangerous commands. Pairs with T2-3.

**Adoption sketch**: `JidoClaw.Security.RiskClassifier.classify(command) :: :safe | :caution | :dangerous` queries cheap aux model. Approval flow: pattern match → if no match, classify → allow safe, prompt caution, block dangerous (configurable).

---

### T2-9. Process registry with strikes + global circuit breaker

**Where**: `tools/process_registry.py`

**What**: Background-process tracking with rolling 200KB output buffer, watch patterns. **Per-session strike system**: 3 strikes in 15s windows → permanently disable watch, fall back to notify-on-complete. **Global circuit breaker**: 15 matches per 10s across all sessions → 30s cooldown. Crash recovery via JSON checkpoint.

**Gap**: Recent jido_radclaw commit added streaming output. I don't see anti-flooding patterns.

**Why it matters**: A misbehaving process (or a tail of `--verbose` logs) can flood the agent's context with watch hits. Multi-layer rate-limiting is well-thought-out.

**Adoption sketch**: ETS counters per session + global. Background-process tracker checks before notifying. Watch disable is per-session, soft-permanent (resets on session end).

---

### T2-10. Cron with delivery targets + scripted preprocessor

**Where**: `cron/jobs.py`, `cron/scheduler.py`

**What**: Cron jobs execute via gateway tick (60s) with file-lock to prevent overlapping ticks. Each job: cron expression OR human duration ("every 1h"), prompt, optional `--script` (Python script whose stdout becomes context for the agent), `--skills` (preload skills), `--deliver telegram|discord|slack|sms|email|webhook|github_comment|local`. Webhook subscriptions take inbound GitHub events and pattern-match payload fields into prompts (`{pull_request.title}`). `[SILENT]` sentinel for "no notification needed."

**Gap**: jido_radclaw has `Tools.ScheduleTask`/`Tools.ListScheduledTasks` but I don't see `--script` preprocessor or multi-target delivery.

**Why it matters**: "Wake me up if X" workflows. Script handles mechanical work cheaply; agent handles reasoning expensively. `[SILENT]` prevents notification spam when the answer is "all clear."

**Adoption sketch**: Extend the scheduled-task model with `pre_script` (path or inline), `delivery_targets` (list of channels), `silent_when_match` (regex). Discord delivery already works; add webhook + email. Scheduler uses `Quantum` or its existing scheduler.

---

## Tier 3 — Lower Impact / Nice-to-Haves

### T3-1. Single command registry across surfaces

**Where**: `hermes_cli/commands.py`

**What**: One `COMMAND_REGISTRY: list[CommandDef]` drives CLI dispatch + gateway dispatch + autocomplete + Telegram BotCommand menu + Slack subcommand routing + help generation.

**Why**: Eliminates drift between `/foo` in CLI and `/foo` in Discord. Adding a slash command edits one list.

**Adoption sketch**: `JidoClaw.Commands.Registry` with a list of `%CommandDef{}` structs. CLI REPL and Discord bot both consume the same list.

---

### T3-2. Insights engine

**Where**: `agent/insights.py` (~39k chars)

**What**: SQL queries over `state.db` produce: token usage, cost estimates (per-model pricing snapshot), tool/skill usage counters, model breakdown, platform breakdown, activity by day-of-week + hour, daily streak, busiest day/hour. Renders as terminal tables with `█` bar charts or JSON.

**Why**: jido_radclaw has telemetry but doesn't surface it as a user-facing dashboard.

**Adoption sketch**: Phoenix LiveView page `/admin/insights` (or unauthenticated `/insights` for the local CLI tenant) reading from the existing telemetry pipeline (`lib/jido_claw/reasoning/telemetry.ex` + whatever sink stores events). Or a `mix jidoclaw.insights` task for terminal output.

---

### T3-3. Tirith pre-exec security scanner

**Where**: `tools/tirith_security.py`

**What**: External Rust binary auto-installed (with SHA-256 + cosign provenance verification, fail-open on missing cosign), runs as subprocess on every shell command, returns 0/1/2 for allow/block/warn.

**Why**: Forge has sandboxing but no static-pattern scanner. Tirith complements (not replaces).

**Adoption sketch**: Optional. Forge pre-exec hook calls a binary if installed. Probably overkill for now.

---

### T3-4. Shell-script hooks bridging plugin lifecycle events

**Where**: `agent/shell_hooks.py`

**What**: Configurable `hooks:` block in `cli-config.yaml` registers shell scripts for `pre_tool_call/post_tool_call/pre_llm_call/post_llm_call/on_session_start/on_session_end`. JSON to/from stdin/stdout. First-use consent. Output schema: `{"decision":"block","reason":"..."}` or `{"context":"..."}` to inject context.

**Why**: Non-Elixir extension surface for ops users. Lower priority for an Elixir-first community but adds reach.

**Adoption sketch**: `.jido/hooks.yaml` with hook → script paths. `Port`-launched subprocess on each event. Sidecar pattern.

---

### T3-5. Profile system via `HERMES_HOME`

**Where**: `hermes_constants.py::get_hermes_home()`

**What**: `HERMES_HOME` env var redirects everything (config, secrets, sessions, memory, skills, gateway state) to per-profile dirs. Code rule: never `Path.home() / ".hermes"`; always `get_hermes_home()`.

**Why**: jido_radclaw's `.jido/` is per-project (cwd), which already gives some isolation. Multi-tenant on one machine would need a `JIDO_HOME` override.

**Adoption sketch**: Add `JIDO_HOME` env var resolution as fallback when `.jido/` is missing in cwd. Probably low-priority.

---

### T3-6. `@file:`/`@folder:`/`@diff` context references

**Where**: `agent/context_references.py`

**What**: User can include `@file:src/main.py:10-50`, `@diff`, `@staged`, `@url:"..."` in messages; preprocessor expands them into context blocks. Token cost tracked. Sensitive home dirs blocked (`.ssh`, `.aws`, `.gnupg`, `.kube`, `.docker`, `.azure`, `.config/gh`).

**Why**: CLI ergonomic. jido_radclaw has VFS routing — this is a user-shorthand layer on top.

**Adoption sketch**: REPL input preprocessor. Regex match `@(file|folder|git|diff|staged|url):...`, expand inline.

---

### T3-7. Onboarding first-touch hints

**Where**: `agent/onboarding.py`

**What**: Instead of a blocking first-run questionnaire, show a one-time hint at the moment the user first hits a behavior fork. Tracked in `config.yaml` under `onboarding.seen.<flag>`. Atomic YAML write.

**Why**: Low-friction UX pattern.

**Adoption sketch**: `.jido/config.yaml` `onboarding.seen` map. Hint helpers in CLI.

---

### T3-8. Auto-titled sessions

**Where**: `agent/title_generator.py`

**What**: After first user→assistant exchange, fire off auxiliary-LLM call in daemon thread to generate 3-7 word title; persist on session.

**Why**: Trivial UX win for session listing.

**Adoption sketch**: `Platform.Session` gets a `title` field. Background `Task.Supervisor.start_child` after first turn, calls T2-3 aux client, updates resource.

---

### T3-9. "Don't write change-detector tests" doctrine

**Where**: AGENTS.md

**What**: Tests asserting specific data (model names in catalog, config version literals, enumeration counts) are _banned_ — they fail on routine source updates without adding behavioral coverage. Replace with invariants: "every model in the catalog has a context-length entry."

**Why**: Testing philosophy. Applies to any catalog-style test (provider lists, tool registry, skill index).

**Adoption sketch**: New AGENTS.md section. Code review check.

---

### T3-10. CI-parity test wrapper

**Where**: `scripts/run_tests.sh`, `tests/conftest.py`

**What**: Test runs via wrapper that unsets `*_API_KEY`/`*_TOKEN`, sets `TZ=UTC`, `LANG=C.UTF-8`, `-n 4` xdist workers, redirects `HERMES_HOME` to temp. Avoids "works locally, fails in CI."

**Why**: Eliminates a class of flake.

**Adoption sketch**: `scripts/test.sh` wrapper for `mix test` that scrubs API keys, fixes timezone.

---

### T3-11. Multi-platform gateway abstraction

**Where**: `gateway/`

**What**: One process serves Telegram, Discord, Slack, WhatsApp, Signal, Email, SMS, Matrix, Mattermost, Home Assistant, etc. Per-platform display config. "Busy input mode": `interrupt | queue | steer` (steer injects new message after next tool call without interrupting).

**Why**: jido_radclaw has Discord. Unified abstraction would help if we add SMS/email/etc.

**Adoption sketch**: Platform-as-adapter. Per-platform `JidoClaw.Gateway.Adapter` behaviour. Lower priority; current Discord works.

---

### T3-12. Skin/theme engine

**Where**: `hermes_cli/skin_engine.py`

**What**: Skins are pure YAML data: colors, spinner faces, thinking verbs, tool emojis, branding strings. Built-ins: default/ares/mono/slate. Users drop `~/.hermes/skins/cyberpunk.yaml`.

**Why**: Personality polish. Low investment.

**Adoption sketch**: `.jido/skins/` directory + skin loader. `JidoClaw.CLI.Skin.get_active().tool_emoji(:read_file)`.

---

## Open Questions Revisited

The cross-pollination report flagged eight items as "things worth a closer look later." Re-reading them with the Tier-1/2/3 ranking in hand, here's how each lands:

### OQ-1. `run_agent.py` budget grace + interrupt loop semantics

**Hermes ref**: `run_agent.py` (~12k LOC), AGENTS.md lines 119-131 sketch the contract.

**Applicability: HIGH**. The "budget grace call" (one extra call after budget exhaustion to let the agent clean up cleanly) and interrupt-check semantics (where in the loop is interrupt-safe vs. mid-tool-call) are directly relevant to `lib/jido_claw/agent/agent.ex`. **Mostly relevant if/when** we adopt T1-2 (compaction with explicit budgets) or T2-2 (credential rotation triggered by exhaustion). On its own, the patterns are general-purpose agent-loop hygiene that transfers.

**Recommendation**: Don't read in isolation — read alongside any future agent-loop refactor. The 12k LOC has many failure-recovery branches; budget at least an hour to extract the patterns worth keeping.

---

### OQ-2. `auxiliary_client.py` exact 402/429/5xx fallback ordering

**Hermes ref**: `agent/auxiliary_client.py`

**Applicability: MEDIUM**. Only relevant if we adopt **T2-3** (auxiliary client router). On its own, the fallback ordering is provider-specific to hermes's chain (OpenRouter → Nous Portal → Custom → Codex OAuth → Anthropic) and won't transfer wholesale. The general principle (402 = walk down chain to free fallback; 429 = same-provider retry with cooldown; 5xx = retry-then-walk) is the lift.

**Recommendation**: Read together with T2-3 implementation. Skip otherwise.

---

### OQ-3. `_summarize_tool_result` per-tool 1-line summary catalog

**Hermes ref**: `agent/context_compressor.py`

**Applicability: HIGH**. If we adopt **T1-2** (context compaction), we need per-tool summarization formats. Hermes's catalog (e.g., `[terminal] ran 'X' -> exit 0, N lines output`, `[read_file] read X (N lines)`, `[web_search] X results for "Y"`) is the result of months of prompt engineering. Most can lift directly with tool-name swap.

**Recommendation**: Lift verbatim into T1-2 implementation. Map each `Jido.Action` tool to a summarizer function. Test that the model doesn't try to re-execute summarized work.

---

### OQ-4. `gateway/run.py` busy-input semantics (interrupt/queue/steer)

**Hermes ref**: `gateway/run.py` (~561k chars)

**Applicability: LOW-MEDIUM, but with one extractable gem**. We don't have a unified gateway, so most of `gateway/run.py` is irrelevant. But the **"steer" mode** — user types a new message while the agent is mid-tool-call; the message is injected after the next tool call **without** interrupting the in-flight work — is a notably good UX pattern. Applies even to the CLI REPL. The CLI REPL today probably has only "interrupt" (Ctrl-C) and "wait for prompt" (queue).

**Recommendation**: Read just the "busy input mode" section (~few hundred LOC). Steer mode could be a small standalone CLI feature; don't need the rest of the gateway.

---

### OQ-5. `agent/redact.py` vendor key-prefix regexes

**Hermes ref**: `agent/redact.py`

**Applicability: HIGH, direct lift**. `lib/jido_claw/security/` exists (per AGENTS.md "encryption vault, secret redaction"). Hermes's regex catalog covers 24+ vendor key prefixes (OpenAI, Anthropic, GitHub, Slack, Google, Perplexity, Fal, Firecrawl, BrowserBase, ...). This is a "lift the patterns" task, not a "design a system" task — the pattern set is the value.

**Recommendation**: Open `agent/redact.py`, copy the regex set into `JidoClaw.Security.SecretRedaction` (or wherever the existing redaction lives). Verify with property-based tests that we don't false-positive on common UUIDs/hashes.

---

### OQ-6. `agent/insights.py` terminal bar chart approach

**Hermes ref**: `agent/insights.py`

**Applicability: HIGH**. T3-2 (insights engine) is where this lives. The SQL/aggregation logic transfers directly (Postgres has all the same operators); the rendering layer is different (LiveView HTML vs. terminal `█` bars) but trivial. The genuinely useful part is **what to aggregate**: tokens by model, cost estimate (per-model pricing snapshot), activity by day-of-week + hour, daily streak. These are the dimensions worth surfacing.

**Recommendation**: Read alongside any T3-2 implementation. Lift the SQL queries; rewrite the rendering for LiveView.

---

### OQ-7. `_validate_commit_hash` defensive validation

**Hermes ref**: `tools/checkpoint_manager.py::_validate_commit_hash`

**Applicability: HIGH, focused borrow**. Defensive against `--patch`-as-commit-hash injection (i.e., a "commit hash" string that's actually a git flag). Directly applicable to `Tools.GitCommit`, `Tools.GitDiff`, `Tools.GitStatus`. Short, easy to apply, eliminates an attack vector.

**Recommendation**: Read the function (probably <30 LOC). Apply the validator to all git tools that accept commit hashes from agent-generated input. Equally relevant if we adopt T2-5 (shadow-git checkpoint manager).

---

## Cross-references and dependencies

Some Tier-1/2 items compose; here's the dependency graph for adoption sequencing:

- **T2-3** (auxiliary client) is a prerequisite for **T1-2** (compaction summaries should run on cheap models), **T1-9** (recall summaries), **T2-8** (risk classifier), **T3-8** (auto-title).
- **T1-4** (error classifier) sets flags consumed by **T1-10** (rate guard), **T2-2** (credential pool), **T1-2** (should-compress flag).
- **T1-5** (prompt scrubber) and **T2-7** (OSV check) are independent security hardening — no dependencies.
- **T1-6** (knowledge skills) is independent of existing pipeline-skills — they coexist, not replace.
- **T1-1** (PTC) is independent and the highest-leverage standalone item.

A natural first wave (if we ever do this work): **T1-4 → T2-3 → T1-2 → T1-3 → T1-5**. Error classifier and aux client are foundations; compaction sits on top of aux client; subdir hints and prompt scrubber are independent additions.

A natural second wave: **T1-1 (PTC) → T1-9 (session search) → T1-7 (cache discipline) → T1-10 (cluster rate guard)**.

---

## Appendix A: Borrowed but with major translation

These hermes patterns informed the inventory but won't translate cleanly:

- **Six terminal/execution backends** (`tools/environments/`) — Forge already has its own runner abstraction. Worth comparing the in-band stdout-marker CWD-persistence trick if we expand remote backends.
- **Shadow-git checkpoint** at `~/.hermes/checkpoints/{sha}/` — works because hermes is single-tenant; jido_radclaw is potentially multi-tenant. The pattern is in T2-5; the path layout will be different.
- **`HERMES_HOME` env var profile system** — superseded by jido_radclaw's per-project `.jido/` model. Listed in T3-5 as a fallback mechanism only.

## Appendix B: Hermes patterns we explicitly skip

- **Tirith Rust pre-exec scanner** binary distribution model — auto-downloading external binaries is a maintenance burden. T3-3 lists it as optional.
- **Multi-platform gateway** beyond Discord — interesting but not aligned with current product direction; T3-11.
- **Skin/theme engine** — fun but not load-bearing; T3-12.
- **Discord.py-style direct bot** — we already have Nostrum, which is better.

## Appendix C: What jido_radclaw has that hermes doesn't

For orientation when comparing — these are jido_radclaw advantages, not borrows:

- Real OTP concurrency (`Jido.Signal.Bus`, `:pg`, libcluster) vs. `ThreadPoolExecutor`
- Ash + Postgres declarative data layer vs. SQLite + ad-hoc SQL
- Phoenix LiveView dashboard vs. embedded xterm in FastAPI
- Reasoning subsystem with strategy/pipeline stores, classifier, certificate templates
- Solutions subsystem (fingerprinting, trust scoring, semi-formal verification)
- DAG skill engine with `depends_on` (complementary to T1-6, not redundant)
- VFS routing (`github://`, `s3://`, `git://`) — broader than hermes's path handling
- Native Anubis MCP server (Elixir) and ACP — hermes's MCP server is Python
- Native Discord via Nostrum (BEAM-native bot, not discord.py wrapper)
- Forge as a first-class sandboxed-execution engine
