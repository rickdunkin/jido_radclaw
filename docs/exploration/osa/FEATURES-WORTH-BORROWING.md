# Features Worth Borrowing from OSA

Exploration notes — not a plan, not a commitment. **Inventory: 2026-07-02**, against OSA @ `f60e933b` (2026-06-03, v0.4.0) and jido_radclaw @ `ff39bbc9` (main). Cites are firsthand reads of both trees, accurate to within a few lines.

Source: `~/workspace/research/OSA` — [Miosa-osa/OSA](https://github.com/Miosa-osa/OSA), Apache 2.0 (© 2026 MIOSA Inc., no NOTICE file). Self-description: *"Signal Theory-optimized proactive AI agent. Local-first. Open source. BEAM-powered."* OSA is the intelligence layer of the MIOSA product. Shape: Elixir 1.17+/OTP 27, ~700 `.ex` files / ~114k LOC under `lib/`, ~32k LOC of tests (153 files, ~3.1k `test` blocks; the README's "1730 tests" is the runtime count), SQLite + ETS + `persistent_term` storage, Goldrush event bus, hand-rolled provider clients over Req, a Rust TUI and a Tauri desktop app. **This is the first exploration subject in our own runtime** — a fact that changes what "borrow" can mean (see the **Lift** axis below).

**Honesty calibration, before anything else.** OSA's distinguishing trait is that its *orphaned* code is polished — near-zero TODO/FIXME density even in dead subsystems — so moduledocs and the README cannot be trusted as wiring evidence; only call-sites and tests can. Verified examples: the marquee **Signal Theory routing is disconnected end-to-end** (the classifier is reachable only from a diagnostic HTTP endpoint; its deterministic "complexity weight" is literally `String.length/500` (`signal/message_classifier.ex:161-165`); the weight→tier mapping just labels an analytics column (`store/signal.ex:70-77`); the genre short-circuit and weight-based tool gate read opts no caller passes (`agent/loop.ex:374,400`)). `swarm/patterns.ex` (282 LOC, all four advertised patterns incl. debate) has **zero callers** and its preset file doesn't exist; `healing/` (1,308 LOC), `speculative/` promotion, `context_mesh/` (1,170 LOC), and `decisions/` (1,436 LOC) are supervised-but-never-called; macOS computer-use is a self-documented stub. The project's own `docs/KNOWN_ISSUES.md` is candid about a fragile hand-rolled tool-call loop (raw-XML tool calls, name mangling on iteration 2). None of this makes OSA worthless — the wired parts are genuinely good — but every entry below carries a wired-in verdict from a firsthand read, and several entries exist precisely because OSA's *failure* is instructive.

Companion docs: **hermes** (`hermes/FEATURES-WORTH-BORROWING.md`) overlaps OSA most — compaction T1-2, error taxonomy T1-4, injection scanning T1-5, SKILL.md disclosure T1-6, credential pool T2-2, shadow-git T2-5, strikes/breaker T2-9, curator T2-15, shell hooks T3-4, context refs T3-6 — entries below cross-reference those statuses (as of the 2026-06-04 re-review) instead of re-inventorying, and where two unrelated projects converged on the same design that is itself signal. **gepa** (`gepa/FEATURES-WORTH-BORROWING.md`): OSA's SICA auto-skill generator is the live counterexample that validates GP1-3's eval-sets-before-optimization sequencing. **alp-river** (AR-2 composer, AR-4 fix loop, AR-5 doctrine, AR-9 judge panel — the shipped/queued machinery several skips point at), **camus** (deterministic-verification doctrine), **jidoka** (eval harness, queue item 5).

## Determination (TL;DR)

**Nothing to adopt as a dependency (OSA is an application, not a library), but the strongest per-entry borrow list since hermes — and the first where "borrow" sometimes means lifting Elixir directly.** jido_radclaw wins on every structural axis (durability, multi-tenancy, gates, sandboxing, event sourcing), but OSA has shipped wired, tested mechanisms in exactly the slots our verification pass confirmed empty: LLM-free compaction degradation and context-overflow recovery, doom-loop detection, deferred tool loading, an inbound prompt-injection guard with a 300-case test corpus, and headless one-shot + session resume.

| Part of OSA | As a dependency | What to take |
| --- | --- | --- |
| Compactor pipeline + ContextCollapse (`agent/compactor.ex`, `loop/context_collapse.ex`) | No | LLM-free degrade ladder; overflow-error recovery; iterative 8-section summary prompt (OS1-1) |
| Doom-loop detector (`loop/doom_loop.ex`) | No | All three mechanisms + staged recovery + suggestion table (OS1-2) |
| Deferred tool loading (`tools/registry.ex`, `tool_search`) | No | The advertise-subset/dispatch-any mechanism (OS1-3) |
| Guardrails (`loop/guardrails.ex` + 308-case test corpus) | No | Unicode de-obfuscation normalizer verbatim; pattern tables + test vectors as a corpus (OS1-4) |
| `mix osa.run` headless + `--resume` | No | The command shape only; our substrate already exists (OS1-5) |
| Provider health-checker / fallback chain / OAuth | No | Circuit-breaker shape; fallback *design anchored on hermes T1-4*, not OSA's string-sniffing (OS2-1) |
| `fs_checkpoint/` shadow-git undo | No | Second precedent for hermes T2-5; restore-by-copy detail (OS2-2) |
| Skills trigger-matched disclosure | No | Mechanism for hermes T1-6's gap — gated on our frozen-prompt cache posture (OS2-3) |
| Hooks engine (`agent/hooks.ex`) | No | Config-declared observe-only sinks; **not** their shell interpolation (OS2-4) |
| Region file locks, effort levels, @-refs, HEARTBEAT checklist, local-model tool-call parsers | No | Small entries, several trigger-gated (OS2-5/6, OS3-*) |
| Signal Theory routing, swarm patterns, healing, speculative, SICA, context_mesh, decisions DAG, computer use | — | Skip — dead/disconnected upstream, or already covered better here |

## Why not adopt OSA as a dependency

1. **It's an application with a product agenda.** OSA is the MIOSA intelligence layer; `open_computers/`, `os/`, `machines.ex` are control-plane glue for that product. There is no library seam.
2. **Substrate mismatch at every layer.** Hand-rolled GenServer ReAct loop vs `Jido.AI.Agent`; SQLite + ETS + process dictionary vs Ash/Postgres; Goldrush vs `Jido.Signal`; settings.json vs `.jido/config.yaml` + Ash resources. Same language, different organs — anything stateful gets rewritten at every seam.
3. **Quality variance is documented, including by OSA itself.** The features we'd want carry real bugs found on firsthand read: post-compact restore called with a hardcoded `nil` session (dead feature, `agent/compactor.ex:293-297` → `compact_restore.ex:15-39`), the max-token "bump" that *halves* the cap (`min(current*2, 16_384)` against a 32,768 default, `loop/react_loop.ex:216`), tool-result cleanup with zero callers, an unescaped `sh -c` hook interpolation (`agent/hooks/shell_hook.ex:91-104`). Lifted code gets our full red/green + precommit treatment regardless, which caps the savings.
4. **Idiom mismatch our gates would reject.** OSA leans on the process dictionary for loop state (doom-recovery counts, bumped token caps), string-sniffs errors, and shells out liberally — credo/reach/dialyzer and house rules (typed errors, no pdict) force a rewrite of exactly those parts.

## How to read this document

- **Recommendation** axis: `BORROW-PATTERN` (reimplement the idea in our idioms) / `ALREADY-COVERED` / `SKIP`. Nothing rates `ADOPT-AS-DEP`.
- **Lift** axis (new, same-runtime privilege): **verbatim** — pure functions, pattern/data tables, prompts, test corpora port nearly as-is; **reshape** — the mechanism ports but every state/event/config seam is rewritten; **design-only** — take the contract, write fresh. Any verbatim/reshape lift carries an attribution comment at the lift site (`Miosa-osa/OSA @ f60e933b, Apache-2.0`) — upstream has no NOTICE file, so the LICENSE copyright line is the thing to preserve.
- **Tiers**: Tier 1 = verified gap, high leverage, buildable now. Tier 2 = useful, gated on a design decision or a demand trigger. Tier 3 = polish. IDs are `OS<tier>-<seq>`. First inventory — no Status lines yet (camus precedent).
- Per-entry fields: **Recommendation**, **Lift**, **Where in OSA** (with wired-in verdict), **What**, **Gap in jido_radclaw** (verified 2026-07-02), **Why it matters**, **Adoption sketch**.

---

## Tier 1 — High Impact

### OS1-1. Compaction resilience: an LLM-free degrade ladder + context-overflow recovery

**Recommendation**: BORROW-PATTERN. **Lift**: reshape (stages are pure list transforms; our message shape is jido_ai's), verbatim for the 8-section summary prompt.

**Where in OSA** (wired): `agent/compactor.ex:264-325` — a six-step short-circuiting pipeline that stops as soon as usage is under target: `micro_compact` (no LLM — keep last 5 tool results verbatim, rewrite older ones to `"[<tool> result — <first 100 chars>… (truncated)]"`, `compactor.ex:351-394`) → `strip_tool_args` (no LLM, `553-574`) → `merge_consecutive` (no LLM, refuses to merge tool-call carriers, `593-600`) → `summarize_warm` (LLM, least-important-first in groups of 5, `626-656`) → `compress_cold` (LLM — the **8-section structured summary**: Goal / Constraints / Progress / Key Decisions / Relevant Files / Errors & Issues / Next Steps / Working Memory, *iteratively merged* with the previous summary held in ETS, `455-478`, `709-823`) → `emergency_truncate` (no LLM, `481-499`). Triggered at 0.80/0.85/0.95 estimated-usage tiers (`233-257` + `config/config.exs:37-39`). Separately, `loop/context_collapse.ex:48-102` is the **overflow-error recovery**: on a provider context-length error, withhold the N largest tool-result bodies (byte-size descending, attempt N of 3, LLM-free, conversation shape preserved) and retry (`react_loop.ex:465-500`).

**What**: two properties our Compactor lacks — a *cheap* degradation path when the summarizer can't run, and a *reactive* recovery when context blows past the window between compactions.

**Gap in jido_radclaw**: `Reasoning.Compactor` is a single LLM summarize call (`compactor/summarizer.ex` via `Jido.AI.generate_text`, 15s hard timeout); on summarizer failure it re-installs the previous snapshot and moves on (`reasoning/compactor.ex:468-471`) — no model-free trim exists (grep clean). The trigger is message-count only (`compactor/config.ex:81-91`; main agent 60/30 at `agent/agent.ex:56-64`). Context-overflow *errors* are normalized by req_llm (`finish_reason :length`, incl. Anthropic's `model_context_window_exceeded`, `deps/req_llm/.../response.ex:690-693`) and then **nothing acts on them** — an oversized request fails the turn. Hermes T1-2 (PARTIAL) tracks the summary-shape residuals; this entry is the *resilience* half hermes never had.

**Why it matters**: converts two real failure modes into degradations. The best-effort posture AGENTS.md documents ("storage and summarizer failures … never block the agent's forward progress") currently means *no compaction happens at all* on failure — a degrade ladder keeps the contract while still shedding tokens. And overflow recovery is the difference between a dead turn and a self-healing one on long tool-heavy sessions.

**Adoption sketch**: (a) Add `Compactor.Degrade` — pure functions mirroring micro-compact/strip-args (operating on our projected messages keyed by `refs.request_id`), run when the Summarizer errors/times out, recorded on the snapshot as `mode: :degraded` and emitted via the existing `:compaction` Trace events. (b) Overflow recovery needs a seam where the ReAct runner surfaces the provider error — either a jido_ai `on_error` hook or a wrapper that classifies context-overflow (typed, via the hermes T1-4 taxonomy — **not** OSA's substring matching) and runs collapse-withhold + immediate re-compact + one retry. (c) Steal the 8-section iterative-merge prompt near-verbatim as an alternative Summarizer prompt (hermes T1-2's "structured summary fields" residual — this closes it). Bugs to *not* copy: OSA's restore stage passes a hardcoded `nil` session (its file/task re-injection is dead), and its loop uses a narrower error matcher than the collapse module ships (`context_collapse.ex:16-32` vs `react_loop.ex:686-691`) — a literal 413 doesn't trigger their recovery. Ours should have one classifier, tested.

### OS1-2. Doom-loop detection with staged recovery

**Recommendation**: BORROW-PATTERN. **Lift**: verbatim for the detection logic + suggestion table (pure), reshape the integration (their recovery counter lives in the process dictionary — ours goes in tracked state).

> **Done 2026-07-03** (next-ten #2) — landed as `JidoClaw.Agent.LoopGuard`
> (pure core + facade) + `LoopGuard.Store` (per-`{tenant, session, agent}`
> KeyStates; in-memory, per NODE — honestly labeled: clustered cron `:agent`
> jobs fire per node, so worst-case budget scales with node count), wired into
> the shared `Tools.Action` pipeline after the approval gate: pre-execution
> `check` — the 4th identical call and the 101st call never run, an
> improvement over OSA's post-batch detection — plus post-normalize
> `observe_result` with a skip-list for approval/doom envelopes
> (non-executions). Thresholds, halt texts, directive, and suggestion table
> verbatim (`# Ported from Miosa-osa/OSA @ f60e933b, Apache-2.0`; tool names
> remapped); halts sticky for `halt_ttl_ms` (5 min) then the key resets; idle
> keys expire after 30 min. Corrections to this entry's claims: (a) "On
> trigger it does *not* hard-halt" overgeneralized — OSA stages ONLY the
> failure-signature mechanism; identical-call and cap hard-halt immediately
> (ours match). (b) "reset on any clean success" is moduledoc-only — OSA's
> *code* never clears accumulated signatures (it only skips appending the
> clean iteration's); we shipped **per-tool** clearing, deviating from both
> (clear-all masks the archetypal edit-fail→read-ok→edit-fail repair loop;
> never-clear over-triggers). (c) The sketch's
> `:ok | {:nudge, _} | {:halt, _}` contract is our redesign — OSA returns
> `{:ok, state} | {:halt, message, state}` with the nudge folded into `:ok`
> via system-message injection and a process-dictionary recovery counter.
> (d) `@error_indicators` string sniffing replaced by typed classification
> (`{:error, _}` tuples / `{:ok, %{exit_code: n}}` with `n != 0` / the MCP
> proxies' re-surfaced `{:ok, %{"isError" => true}}` domain failures);
> `phash2` replaced by full SHA-256 over deterministic ETF. (e) The sketch's "fed from
> the shared `Tools.Action` pipeline (which already sees every call +
> normalized error)" holds only for calls that reach the action's `run/2` —
> param-validation, Exec/Turn-timeout, raised-exception, and output-schema
> validation failures happen outside it and are documented residuals (the
> last is a false-success direction, neutralized cross-tool by the per-tool
> clearing and pinned by tests). (f) No upstream tests existed; the property
> suite (reset-on-success per-tool, consecutive-vs-windowed, non-adjacent
> 3-in-20, cap+warn, staged recovery, sticky halt) is net-new — and the
> repo's first property tests (stream_data).

**Where in OSA** (wired via `react_loop.ex:457-460`; no upstream tests): `loop/doom_loop.ex:51-85` runs three checks after every tool batch — (1) **identical-call window**: fingerprint `{name, :erlang.phash2(args)}`, halt on 4+ consecutive identical calls in a window of 8, *success-agnostic* (catches useless-success loops like re-listing the same directory, `94-149`); (2) **failure signatures**: `"<tool>:<first-100-chars-of-error>"` accumulated only for error-indicating results, fire when any signature hits 3 in a window of 20, **reset on any clean success** (`153-194`); (3) **absolute cap**: 100 tool calls per session, warn at 80% (`217-254`). On trigger it does *not* hard-halt: it injects a recovery directive up to twice (system message: read the target, use *completely different* arguments), clearing signatures each time, and only halts on the third trip (`256-339`). `build_suggestion/1` (`341-374`) pattern-matches the error to targeted advice ("old_string not found" → read the file first; "command not found" → check with `which`).

**Gap in jido_radclaw**: the only guard on the in-REPL agent's tool loop is jido_ai's soft nudge on *consecutive identical* signatures (`deps/jido_ai/.../react/runner.ex:25-27,204-218`) — no failure-awareness, no window (A-B-A-B oscillation passes), no hard stop short of `max_iterations: 25` (`agent/agent.ex:52`). Closest relatives are coordination-loop caps, not tool-level: `PullRequestCoordinator` `@max_attempts 3`, composer `@default_rerun_cap 2`/`route_budget_exhausted`. Hermes T2-9 (NOT_ADOPTED) is the OS-process-level cousin (strikes + global circuit breaker for background processes) — different layer, both eventually wanted.

**Why it matters**: unattended surfaces — cron `:agent` jobs, MCP-driven turns, composer stage agents — can burn real budget re-running a failing tool. We already know our retry semantics are subtle (two retry layers with opposite defaults, per the tool-error-non-retryability finding); a loop detector is the backstop *above* per-call retry policy, and it's the kind of pure-logic module that property-tests well.

**Adoption sketch**: `JidoClaw.Agent.LoopGuard` — pure `check(history_window, opts) :: :ok | {:nudge, directive} | {:halt, reason}` over recent `(tool, args_hash, error?)` tuples, fed from the shared `Tools.Action` pipeline (which already sees every call + normalized error) with a per-`{tenant, session, agent}` sliding window (ETS or AgentTracker). Stage the response: directive as tool-result payload (the LLM sees it), then a non-retryable `{:error, %{code: :doom_loop}}` envelope — same shape as the approval-gate errors, so the loop terminates cleanly. Port the suggestion table and thresholds; emit `:guardrail` Trace events; property-test the windows (reset-on-success, consecutive vs windowed).

### OS1-3. Deferred tool loading — advertise a subset, accept any registered name

**Recommendation**: BORROW-PATTERN. **Lift**: design-only (the mechanism is trivial; the work is the jido_ai seam).

**Where in OSA** (wired, mature): `tools/behaviour.ex:66-96` — per-tool `should_defer?/0` + `always_load?/0`; `tools/registry.ex:51` excludes deferred tools from the advertised list at loop init; `tool_search` (which *"must NEVER be deferred — the model needs it available from turn 1 so it can fetch any other deferred tool"*, `tool_search/tool.ex:9-13`) scans **all** tools with name/keyword/jaro scoring and a `select:A,B,C` exact-fetch grammar (`registry.ex:63-88`), returning name + description + parameter schema as text; execution never gates on the advertised list — dispatch is a `:persistent_term` lookup by name over all registered tools (`loop/tool_executor.ex:449`). Net: no per-session activation state at all.

**Gap in jido_radclaw**: all **33** native tools ship full schemas on every request (`agent/agent.ex:7-50`; `Jido.AI.ToolAdapter.from_actions/2` maps the entire list, `deps/jido_ai/.../tool_adapter.ex:77-106`) — roughly 6–9k tokens of schema per cache-cold request, and external MCP proxies attach *on top*. jido_ai exposes request-scoped `:tools`/`:allowed_tools` overrides (`deps/jido_ai/.../agent.ex:504-505`) that nothing uses. No search/defer mechanism exists (grep clean).

**Why it matters**: the tool list only grows (MCP consumption multiplies it), prompt-cache warmth softens but doesn't eliminate the cost, and this same pattern is shipping in Claude Code itself (deferred tools + ToolSearch) — two independent convergences now. Rarely-used tools (`replay_workflow`, `network_*`, `forge_status`, the inspect family) are natural candidates.

**Adoption sketch**: a `defer?: true` marker on tool modules (metadata function, not config); at agent build, partition into advertised vs registered-only; a `JidoClaw.Tools.ToolSearch` action mirroring the `select:`/keyword grammar over the full registry. **The open design question (OQ-1)**: jido_ai builds both the advertised schemas *and* the execution dispatch from the same `config.tools` list — withholding a tool from the prompt while still accepting its name needs either an upstream jido_ai option (advertised-subset) or registering all modules and filtering only what `ToolAdapter` renders. Approval-gating is unaffected either way — `ToolApproval` keys on tool name at execution time, so a deferred tool is exactly as gated as an advertised one. MCP proxy tools are the second wave (defer by server), independent of the per-template reach allowlist (which is authorization; this is prompt economics).

### OS1-4. Inbound prompt-injection guard: normalizer, pattern tables, and a 300-case corpus

**Recommendation**: BORROW-PATTERN (direct-input half; the indirect half stays anchored on hermes T1-5). **Lift**: verbatim for the Unicode normalizer + pattern tables + test vectors; reshape the wiring and the disposition.

**Where in OSA** (wired, the best-tested code in the tree): `loop/guardrails.ex:77-151` — three deterministic tiers, zero LLM calls: 21 injection regexes (system-prompt extraction, ignore-instructions, DAN/persona jailbreaks); the same set re-run against a **Unicode-normalized** copy — `normalize_for_injection_check/1` (`365-396`) strips zero-width/invisible codepoints, folds fullwidth ASCII (U+FF01–FF5E), collapses 12 Cyrillic/Greek homoglyphs, then lowercases — defeating homoglyph/zero-width obfuscation; and 5 structural patterns for injected prompt-boundary markers (`SYSTEM:` role headers, `### New Instructions`, `<system>`, `[INST]`, `<<SYS>>`, `110-121`). Wired at `loop.ex:369-372` as a hard block. Tests: `loop_injection_test.exs` (818 lines, 130 cases) + `loop_guardrails_test.exs` (946 lines, 178 cases). **Their scope gap**: it runs on direct user input only — tool results and fetched web content are never screened.

**Gap in jido_radclaw**: no inbound injection detection anywhere (`security/` greps clean — the only "injection" hits are git-config injection in `ShellCommand`); `browse_web` returns page content unscanned (`tools/browse_web.ex:144-160`); MCP tool descriptions are documented prompt-trusted. The one precedent is narrow: `front_door/prototype_summary.ex:14-41` wraps untrusted file excerpts in an "UNTRUSTED DATA" block with an ignore-instructions system prompt. Hermes T1-5 (NOT_ADOPTED) remains the design north star for the *indirect* half — its `threat_patterns.py` + `<untrusted_tool_result>` delimiters.

**Why it matters**: our live exposure is indirect injection (web content, MCP results, file contents) more than direct users — but the *detector internals* are shared, and OSA hands us the expensive parts: a hardened normalizer and a large labeled corpus. Building the scanner without the corpus is the slow way.

**Adoption sketch**: `JidoClaw.Security.InjectionScan` — port the normalizer verbatim (it also belongs in front of redaction: an escape-split or homoglyph-obfuscated *secret* is the same evasion class our ANSI-strip-at-root already handles; same posture, wider net). Port the pattern tables + the 300-case corpus as fixtures. **Disposition differs from OSA**: for tool results / web content, don't block — wrap in delimiters + inject a warning (the `prototype_summary` and hermes patterns), flag via `:guardrail` Trace events; for direct channel input, make blocking configurable and default off for the REPL (single-operator surface; OSA hard-blocks because it protects weak local models and accepts false positives — "ignore all instructions" fires on benign sentences). Pipeline position: inside `Tools.Action` after `OutputRedaction` (scan the redacted text — redact-before-everything holds), before shaping.

### OS1-5. Headless one-shot mode + CLI session resume

**Recommendation**: BORROW-PATTERN (the command shape; our substrate exists). **Lift**: design-only.

> **Done 2026-07-03** (next-ten #1) — landed as `mix jidoclaw run "<prompt>" [dir]
> [--session <uuid> | --continue] [--timeout <s>] [--format text|json]` (escript
> mirrored), REPL `--resume <uuid>` / `--continue`, and a `/sessions` list split
> into CLI-resumable vs resume-by-UUID-only groups. Three corrections to this
> entry's claims: (a) it says `JidoClaw.chat/3` — shipped on **`chat/4`**, with a
> new `composer_ack: :detailed` opt returning structural acks (route/status/
> `parent_run_id`) because the plain-binary default is a pinned contract for
> cron/web; (b) "ensure_session (existing UUID or fresh)" undersold resume —
> the session identity includes **kind**, so a resumed row must carry its OWN
> `kind`/`external_id` back through `unique_external` (one-shot sessions got a
> new **`:cli_run`** kind so `--continue` can never resume a web `:api` thread);
> (c) "the Worker already hydrates `state.messages`" was true but **view-only**
> — nothing seeded `Jido.AI.Context` from Postgres, so the genuinely net-new
> mechanism was `JidoClaw.Conversations.ContextRestore` (chat-transcript-only
> `:replace`/`:restore` context op, `refs.request_id` preserved so compaction
> survives resume, snapshot-sourced system prompt so the cached prefix stays
> byte-identical — the CC2-2 rider, tested both halves). Resume was generalized
> into `chat/4` (`context_restore: :best_effort | :strict`), so cron `:main`
> sessions became restart-resumable for free. OQ-4 answered below. stream-json
> stayed out of scope.

**Where in OSA** (wired): `lib/mix/tasks/osa.run.ex` (188 LOC) — `mix osa.run "prompt"` boots the app, creates (or `--resume`s) a session, starts the same `Agent.Loop` every channel uses, runs one `process_message`, prints, exits; `--format text|json|stream-json`, stdin piping, NDJSON streaming by subscribing bus handlers for `:streaming_token`/`:tool_call` (`149-177`). Interactive `/resume` restores a checkpointed session (`channels/cli/session.ex:124`, `loop.ex:266`).

**Gap in jido_radclaw**: no one-shot CLI — every non-flag arg to `mix jidoclaw` is treated as a project dir and drops into the interactive REPL (`cli/repl.ex:314-342`); the programmatic entry `JidoClaw.chat/3` already exists and is what cron and the web surface call. No resume — the REPL mints a fresh `SessionId.new()` per boot (`repl.ex:201`) and creates a new `Conversations.Session` row, even though sessions are durable and the Worker already hydrates `state.messages` from Postgres when rows exist for the session UUID (`repl.ex:214-218`). Both gaps are thin plumbing over shipped substrate.

**Why it matters**: one-shot mode makes the platform scriptable — CI checks, cron-from-shell, camus-style external harnesses, piping. Resume is the top session ergonomic the durable layer already paid for. Effort-to-leverage is the best on this list.

**Adoption sketch**: `mix jidoclaw run "<prompt>" [--format text|json] [--session <uuid>] [--continue]` → resolve project, boot without the REPL UI, `ensure_session` (existing UUID or fresh), `JidoClaw.chat/3`, print, exit code from the outcome envelope. REPL side: `--resume <uuid>` / `--continue` (most recent session for the workspace) + a `/sessions` list. Two contracts to pin (OQ-4): what a **tool-approval interrupt** does in a non-interactive run (print the pending `AgentCase` id, exit distinct code — the gate family already returns `:approval_pending`), and stream-json framing if we add it later (OSA's bus-handler NDJSON is the reference). MCP serve mode is unaffected.

---

## Tier 2 — Useful, gated on a design decision or trigger

### OS2-1. Provider resilience: circuit breaker + fallback chain + length recovery

**Recommendation**: BORROW-PATTERN — mechanics from OSA, **taxonomy from hermes T1-4** (don't let available code pick the design). **Lift**: reshape for the breaker; design-only for fallback.

**Where in OSA**: `providers/health_checker.ex` (208 LOC, wired via `registry.ex:224,328`) — clean per-provider circuit breaker (3 failures → open, 30s → half-open, 1 success → closed) with an *independent* 429 substate honoring `Retry-After`, checked before circuit state (`176-191`). `providers/fallback_chain.ex` (wired at `llm_client.ex:145-157`) retries a failed stream on the next provider — with two warts to not copy: `retryable_error?/1` string-sniffs stringified reasons (any non-binary → retryable, `132-152`), and mid-stream failover **replays the full response through the same callback**, duplicating already-emitted output (`95-115`). Their `max_tokens` truncation recovery exists but the bump computes `min(current*2, 16_384)` against a 32,768 default — it *halves* the cap (`react_loop.ex:216`).

**Gap in jido_radclaw**: `ReqLLM.Step.Retry` covers transport errors (instant, ×3) and 429-with-Retry-After only — **a provider 5xx on the Anthropic path is not retried** (`deps/req_llm/.../step/retry.ex:112`; only `openai_codex` covers 5xx). No fallback-model chain anywhere (grep clean across lib + deps). `finish_reason: :length` is normalized and then ignored. Hermes T1-4 (FailoverReason taxonomy with action flags) and T2-3 (auxiliary router) are both NOT_ADOPTED; T1-10's cluster rate-pacer is proven for Voyage embeddings only.

**Why it matters**: unattended runs (cron, composer, MCP) die on transient 5xx today; local-model support raises flake rates further. The breaker prevents hammering a downed provider across concurrent agents — per-node state is a fine start.

**Adoption sketch**: build hermes T1-4's classifier first (typed `FailoverReason` + action flags, fed by req_llm's typed errors); then `JidoClaw.Providers.Breaker` (OSA's state machine, near-portable) consulted in a jido_ai request wrapper; fallback as config (`fallback_models:` in `.jido/config.yaml`) applied **only before the first emitted token** (fixing OSA's replay wart) or on non-streaming calls; length-recovery = one retry with a raised cap where the model's ceiling allows. Consider upstreaming 5xx retry to req_llm's shared step as the smallest first slice.

### OS2-2. Shadow-git filesystem checkpoints (second precedent for hermes T2-5)

**Recommendation**: BORROW-PATTERN. **Lift**: reshape.

**Where in OSA** (wired, default-on): `fs_checkpoint/server.ex` (385 LOC) — a shadow git repo at `~/.osa/fs_checkpoints/`; a `pre_tool_use` hook (priority 11) snapshots affected files + commits before destructive ops; restore **re-copies files from the shadow commit** rather than `git checkout`, deliberately never touching the host project's git (`server.ex:11-13`); a `rollback` tool exposes it.

**Gap in jido_radclaw**: `write_file`/`edit_file` mutate the host workspace with no undo (greps clean; Forge checkpoints cover *sandbox runner state* only, `forge/resources/checkpoint.ex`). Recovery relies on the user's own git discipline. Hermes T2-5 is PARTIAL for exactly this reason — the transparent pre-write hook + `/restore` command never landed.

**Why it matters**: two unrelated projects built the same shape (hermes `shadow-git checkpoint manager`, OSA `fs_checkpoint`) — that's design validation. The restore-by-copy detail is the right call (no interaction with user branches, rebases, hooks). Our `Tools.Action` pipeline gives a cleaner mount point than OSA's hook chain.

**Adoption sketch**: a pre-stage in `Tools.Action` for mutating VFS ops on the local backend: snapshot target files into a tenant/workspace-scoped shadow repo (`.jido/checkpoints/` or XDG data dir), bounded by count/age GC; `/checkpoints` + `/restore <id>` REPL commands; opt-in first release. Apply hermes OQ-7's commit-hash validation to any agent-supplied restore id. Trigger honesty: demand is latent until an agent-mangles-a-file incident — cheap enough to build ahead of it, but it queues behind Tier 1.

### OS2-3. Trigger-matched progressive skill disclosure (mechanism for hermes T1-6)

**Recommendation**: BORROW-PATTERN, gated on the prompt-cache posture decision. **Lift**: reshape.

**Where in OSA** (wired): `tools/registry.ex:280-385` — every enabled skill always appears in a `## Custom Skills` catalog (name + description); when trigger keywords substring-match the latest user message, the **full instructions** are injected as `### Active Skill: <name>`, priority-sorted, budgeted (4k chars/skill, 12k total), truncating to a "call `use_skill` for the rest" pointer. Frontmatter carries `triggers`/`priority` (`registry/skill_loader.ex:96-128,207-221`); user skills override built-ins by name.

**Gap in jido_radclaw**: the system prompt lists `### Loaded Skills` (name + description, `agent/prompt.ex:227-243`) and `run_skill` executes them — but our skills are DAG *workflows*, not instruction packs, so the direct analog for injectable instructional content is the doctrine/persona surface (AR-5), which is static per-template. Hermes T1-6 (PARTIAL) wants Anthropic-style progressive disclosure on the JidoClaw side; OSA shows the minimal wired mechanism.

**Why it matters**: as doctrine slices and skills grow, the choice is prompt bloat vs discoverability. Catalog-always + full-text-on-match is the standard resolution (it is how Claude Code skills work), and OSA proves it in ~100 lines.

**Adoption sketch — and the gate**: our prompt is a **frozen snapshot** by design (hermes T1-7 posture — cache-warm, per-turn fields dropped). Per-turn injection into the *system* prompt would fight that. The compatible shape: inject matched-skill instructions as a turn-scoped user-message preamble (the same lane compaction summaries use), not into the snapshot. Decide that lane deliberately (it's the same "dynamic context lane" question OS3-1 raises) before building; until then this stays sketched.

### OS2-4. Operator-declared lifecycle hooks — observe-only webhook/command sinks

**Recommendation**: BORROW-PATTERN, narrowed. **Lift**: design-only (their engine is fine; their shell interpolation is a vulnerability to avoid).

**Where in OSA** (engine wired; surface inflated): `agent/hooks.ex` (754 LOC) — ETS-bag dispatch in the caller's process, chain contract `{:ok, mutated} | {:block, reason} | :skip`, crash-isolated, metrics. Config-driven HTTP (`hooks/http_hook.ex`, fire-and-forget Task, 5s) and shell (`hooks/shell_hook.ex`, 10s) hook types. Reality checks: only ~12 of the ~24 declared events ever dispatch (their `session_end` cleanup hook never fires — a leak); the "agent-spawning hook type" doesn't exist (it's the cron subsystem); the response-overriding `stop` hook mechanics are real but have zero users; and the shell interpolation is a **naive `String.replace` into `sh -c`** — a payload containing `$(…)` executes (`shell_hook.ex:91-104`). One genuinely good engine detail: the pre-tool security-hook chain **fails closed** when the hooks server is unreachable (`tool_executor.ex:136-143`).

**Gap in jido_radclaw**: no operator surface at all — internal Trace + `Jido.Signal` topics are rich (`jido_claw.tool.complete`, gate/cron/memory events) but reachable only from Elixir; `.jido/config.yaml` has no `hooks:` key (`core/config.ex:73-103`). Hermes T3-4 (shell hooks) NOT_ADOPTED.

**Why it matters**: "ping me when a gate goes pending", "log tool use to the SIEM", "notify on cron failure" are ops asks that shouldn't require a code change. Two independent projects shipped it; ours is *easier* because the signal bus already exists — the feature is a config-declared sink, not an event system.

**Adoption sketch**: `hooks:` in `.jido/config.yaml` mapping signal patterns to sinks: `webhook` (Req POST, HMAC-signed, payload through `OutputRedaction` first) and `command` (**argv array exec, no shell; payload as JSON on stdin** — never interpolate). Observe-only in v1 — no block/mutate capability (our gates are in-process and fail closed by construction; giving external hooks veto power reopens a trust boundary deliberately). Fire-and-forget under a `Task.Supervisor` with a drop counter. Allowlist the subscribable events explicitly, starting with tool-complete, gate lifecycle, cron outcomes, compaction.

### OS2-5. Region-level file locking for concurrent same-file edits

**Recommendation**: BORROW-PATTERN, **trigger-gated**: adopt when a composer increment wants parallel implementers in one worktree. **Lift**: reshape (clean, near-portable module).

**Where in OSA** (wired via `peer_claim_region` tool): `file_locking/region_lock.ex` (444 LOC) — agents claim **non-overlapping line ranges** `{agent, file, start_line, end_line}`; a GenServer serializes overlap detection, ETS serves hot-path reads, 10-minute inactivity auto-expiry with a 60s sweep.

**Gap in jido_radclaw**: no same-file coordination primitive — by design: parallel writers are isolated per-worktree (Forge, composer, `EnterWorktree`). That design holds until someone wants intra-worktree parallelism (two fixers on one large file), at which point this is the named answer. Genuinely novel — no hermes analog.

**Adoption sketch (when triggered)**: tenant-scoped `RegionLock` GenServer + claims surfaced in stage task context; the write tools check claims when a `parallel_edit` context flag is set. Until the trigger fires, zero carrying cost — this entry exists so the idea has a name.

### OS2-6. Effort levels (a user-facing depth knob)

**Recommendation**: BORROW-PATTERN, small — **sequenced after AR-9 PR-1** (the composer tiering seam, queue item 3), which owns the `:low/:medium/:high` vocabulary. **Lift**: design-only.

**Where in OSA** (wired, tested): `agent/effort.ex` — four levels mapping to `max_iterations` (30/30/50/100), tool budget, Anthropic thinking budget (0/5k/10k/32k), temperature; resolved through their settings cascade; `fast_mode?` gates prefetch and disables thinking. Plus an iteration-budget countdown injected each iteration ("Iteration N/max — X remaining", `react_loop.ex:669-684`).

**Gap in jido_radclaw**: nothing user-facing — the REPL agent runs a compile-time `max_iterations: 25` (`agent/agent.ex:52`); the `.jido/config.yaml` `max_iterations` knob is parsed but **uncalled** (`core/config.ex:115-116` — vestigial); jido_ai's `thinking:` option exists and nothing sets it (`deps/jido_ai/.../react/runner.ex:1171`); the composer's per-stage `effort` field is parsed-and-dormant (`route_composer/stage.ex:78` — AR-9 PR-1 is its designed consumer).

**Why it matters**: "think harder on this one" / "quick answer" is a real per-task control, and every substrate hook already exists unwired. But shipping a REPL `/effort` *before* the composer seam lands risks two competing effort vocabularies — hence the sequencing.

**Adoption sketch**: after PR-1, a `/effort low|medium|high` session override mapping to `{max_iterations, thinking budget}` through `strategy_opts`, sharing the composer's enum; wire the vestigial config knob or delete it (it currently misleads). The countdown injection is a cheap rider worth testing for effect on long turns.

---

## Tier 3 — Polish

### OS3-1. `@`-mention context references

**Recommendation**: BORROW-PATTERN. **Lift**: reshape (parser near-verbatim). **Where in OSA** (wired, default-on): `context_refs/` (325 LOC) — regex-parse `@file:path[:10-25]`, `@diff`, `@staged`, `@git:N`, `@url:…` out of the user message; per-kind resolvers fetch and inject content (`context_refs/parser.ex:11`, `resolvers/`). **Gap**: REPL input passes through unchanged (hermes T3-6 NOT_ADOPTED; hermes OQ-4's steer-mode is adjacent). **Sketch**: parse in the REPL input path, resolve via VFS (which already speaks `github://` etc. — our resolver is *stronger* than theirs), inject as a turn-scoped preamble. Content passes the OS1-4 wrap-and-flag treatment (an `@url` fetch is untrusted input). Same dynamic-lane decision as OS2-3.

### OS3-2. System-prompt-leak output scrub

**Recommendation**: BORROW-PATTERN, redesigned. **Lift**: design-only. **Where in OSA** (wired): `guardrails.ex:34-73` — count 15 hand-listed prompt fingerprints in the response; ≥2 → replace the whole response with a refusal. Born from their open BUG-017 (full prompt dumped on request). **Gap**: no output-side scrub here (J2 verified; our redaction is secrets-focused). **Why bother at all**: multi-tenant gateway/MCP surfaces where the prompt embeds tenant-visible structure. **Sketch**: derive fingerprints *from the actual prompt snapshot at boot* (theirs rot — manually mirrored from SYSTEM.md), scrub the matched spans rather than wholesale-replace, log via `:guardrail` Trace. Low priority; single-operator REPL doesn't need it.

### OS3-3. HEARTBEAT.md — a proactive checklist file

**Recommendation**: ALREADY-COVERED core / BORROW-PATTERN garnish. **Where in OSA** (wired; the most polished subsystem in its cluster): `agent/scheduler/heartbeat.ex` — every 30 min, parse `~/.osa/HEARTBEAT.md` for unchecked `- [ ]` items, run each as a one-shot agent conversation, rewrite to `- [x] … (completed <ts>)` on success, per-item circuit breaker after 3 failures. (Their advertised quiet-hours window is a stub — `heartbeat.ex:34` hardcodes `quiet = false`.) **Covered**: recurring proactive runs are expressible today — `schedule_task` with `target: "agent"` + a cron expression (`tools/schedule_task.ex:25-66`), or `/cron add` (multi-node caveat: user `:agent` cron jobs are not leader-gated and fire per node, `platform/cron/worker.ex:203`). **The garnish**: *one-shot* checklist semantics — items that run once, check themselves off, and can be re-added by the agent — is a distinct UX from recurring cron, adjacent to hermes T2-16 (goals). If demand appears, it's a small cron `:system_job` + a markdown file; until then, covered.

### OS3-4. Local-model tool-call text parsers

**Recommendation**: BORROW-PATTERN, **trigger-gated**: only if weak-local-model tool calling becomes a supported path. **Lift**: verbatim (pure functions; no upstream tests — add ours). **Where in OSA**: `providers/tool_call_parsers.ex` (327 LOC) — extract tool calls from *raw text* for seven model families that don't populate structured `tool_calls` (Hermes/Qwen `<tool_call>`, DeepSeek, Mistral `[TOOL_CALLS]`, Llama `<|python_tag|>`, GLM, Kimi, Qwen3-Coder), with distinctive-marker-first auto-detection. **Gap**: ReqLLM parses provider-structured tool calls; Ollama-hosted small models that emit tool calls as text would today just fail. AGENTS.md recommends Ollama for local dev, so the trigger is plausible. Where it would land: a ReqLLM ollama-provider post-processing step — an upstream contribution more than a JidoClaw module.

### OS3-5. BEAM eventing lessons — as a review checklist, not code

**Recommendation**: ALREADY-COVERED (we ride `Jido.Signal`), keep the lessons. **Where in OSA**: `events/bus.ex` + `events/dlq.ex` — three hard-won, quotable rules from their Goldrush battle scars: (1) *compile-once, dispatch-via-ETS* — recompiling a static router mid-flight wiped tables under in-flight workers (TOCTOU, `bus.ex:221-225`); (2) **store MFA tuples, not closures** in any retry queue — "closures can't survive process restarts" (`dlq.ex:30-31`); (3) monitor registering processes and auto-remove their handlers on `:DOWN` (`bus.ex:235-243`). Nothing to build; add to the review checklist the next time anyone touches signal-bus subscription or the OS2-4 sink dispatcher (which rule 2 directly governs).

---

## Skip / Already Covered

- **Signal Theory routing (classifier → weight → model tier) — SKIP.** Disconnected end-to-end upstream (see calibration); the deterministic weight is `length/500`. Poignantly, we carry the same unrealized aspiration — `:fast`/`:capable` collapse to one model at REPL boot (`cli/repl.ex:58-59`) and the composer's `model`/`effort` stage fields are dormant. The vehicle for *our* version is AR-9 PR-1 (tiering seam) + the gateway triage verdict, not anything in OSA.
- **Swarm patterns (parallel/pipeline/debate/review_loop) — SKIP.** Dead code upstream (zero callers; preset file missing; supervisor comment says swarm was removed). Debate's "consensus" is *the last agent decides*; review_loop approval is `String.starts_with?("approved:")`. The composer (AR-2/AR-4) plus the queued AR-9 judge panel are the real versions of everything here.
- **Healing orchestrator — SKIP as-is; one detail recorded.** 1,308 LOC, fully orphaned (`request_healing` has zero callers). The composer fix loop (AR-4) covers the territory. The one idea worth remembering: the **40/60 budget split between a diagnose agent and a fix agent** — a sensible spend shape if a self-heal stage ever gets budgeted sub-agents.
- **Speculative executor — SKIP.** Promotion/assumption-checking never fires upstream (only `start_speculative` is exposed). Our worktree/Forge isolation answers the "work ahead safely" need.
- **SICA auto-skill promotion — SKIP; the lesson is the entry.** Wired and default-on upstream, and it demonstrates exactly why gepa GP1-3 sequences eval sets *before* any optimizer: with only an `occurrences >= 5` gate, five successful `file_read`s mint a skill whose entire body is `"continue"`, and a second path (`auto_skill_creator`, any turn with ≥5 tool calls) bypasses even that. Auto-learned skills remain the gepa program (GP1-1/GP2-2, gskill precedent) behind eval gates and a human deploy gate — never occurrence counting. Cross-ref hermes T2-15 (curator).
- **Memory store / A-MEM reweave / auto-extract / episodic — ALREADY-COVERED.** Our hybrid recall (FTS + pgvector + trigram under RRF, `memory/hybrid_search_sql.ex:16-25`) beats their formula (50% of the score is a mostly-constant stored weight; their "FTS5 for memories" claim is actually `LIKE`). Consolidator + memory Links cover reweave-ish structure. Their regex auto-extract is below our consolidator's bar.
- **verify_loop / Verification.Loop — ALREADY-COVERED** by the composer's verify stages + AR-4 loop + camus's deterministic-verification doctrine (verify semantics, head-bound verdicts).
- **Soul/IDENTITY/USER/personality overlays — ALREADY-COVERED** by `system_prompt.md`, JIDO.md, and the AR-5 doctrine/persona surface. A `/personality` tone overlay would be a UX garnish on personas, not a new system.
- **Computer use — SKIP.** macOS adapter is a self-documented stub (`{:error, "not yet implemented"}`); X11/Docker halves are real but desktop control is out of our automation posture (browse_web + Forge). Revisit only with a concrete operator demand.
- **Wave orchestration / event forwarder / fork-mode delegate / ETS team mailboxes / peer negotiation — ALREADY-COVERED / watch.** Composer waves, `AgentTracker`, `SubagentTranscript`, and parent→child `send_to_agent` (queued follow-up turns, `tools/send_to_agent.ex`) cover the working parts. Peer *negotiation* (counter-proposing task assignment, `peer/negotiation.ex`) is a genuinely different primitive — no demand; noted.
- **Credential pool — SKIP here; hermes T2-2 stands.** OSA's pool serves one provider and its rate-limit-skip (`mark_rate_limited`) has zero callers. Hermes's state machine (incl. the new `STATUS_DEAD` terminal) remains the design source.
- **Anthropic OAuth (PKCE, auto-refresh, 0600 storage) — watch.** Complete and wired upstream (`auth/oauth.ex`, 277 LOC) — the best same-runtime reference if subscription-auth demand ever reaches us (hermes T3-18 adjacent). No current need; ReqLLM is API-key based.
- **Message-queue debounce, settings.json cascade (user/local layers), skins, workspace layer, command center, SDK facade, machines, os/ manifests, open_computers — SKIP.** REPL is line-synchronous (no debounce need); our config is deliberately project-scoped (a per-user layer is a real but unpulled thread, hermes T3-5); the rest is dashboard stubs, cosmetic theming, or MIOSA product glue (`command_center.ex` metrics return all zeros; roster prompts are literally `"[REDACTED]"`).
- **Fail-closed pre-tool pipeline / per-tier tool allowlists — ALREADY-COVERED.** `ToolApproval` inside `Tools.Action` is in-process and fails closed by construction (`:approval_unavailable`); per-template tool lists + `forward_context` + `SwarmScope` cover per-agent scoping.
- **repl tool (stateless `python3 -c`), regex code_symbols, multi_file_edit — SKIP.** Shallower than `run_command` + Forge; symbol intelligence would come from LSP, not regexes.

## Open questions

- **OQ-1 — Deferred-tools seam (gates OS1-3).** jido_ai derives both the advertised schema list and execution dispatch from `config.tools`. Withhold-from-prompt-but-accept-by-name needs either an upstream jido_ai option (advertise a subset) or a ToolAdapter-level filter with the full module list still registered. Which — and is upstream amenable?
- **OQ-2 — Injection-scan disposition (OS1-4).** For tool results / web content: wrap-and-warn only, or configurable block? And exact pipeline order relative to `OutputRedaction` (scan-after-redact proposed — verify the normalizer belongs in redaction's root pass too, where ANSI-strip already lives).
- **OQ-3 — Overflow-recovery seam (OS1-1b).** Where does the provider error surface cleanly enough to trigger collapse-and-retry — a jido_ai `on_error` hook, a wrapper around the runner, or (narrowest) an upstream req_llm retry-step contribution? Composer stage agents need the same recovery.
- **OQ-4 — Headless approval contract (OS1-5).** Non-interactive run hits a gated tool: print the pending case id and exit with a distinct code, or auto-fail? (The gate family already yields `:approval_pending`; this is purely an exit-contract decision.)
  **Answered 2026-07-03 (shipped with OS1-5)**: distinct code — the contract is `0` success · `1` error/failed-run/await-timeout · `2` usage/config error · `3` approval gate pending (case ids printed with `/gates approve <id>` guidance; JSON envelope carries `pending_cases: [{id, fresh}]`). Two detection subtleties the answer had to absorb: an **inline** gate is invisible in `chat/4`'s return (the gate error becomes a tool result the LLM relays as text), so the runner probes `AgentCase.pending_for_session/1` after the turn — and deliberately does NOT filter by `inserted_at >= turn_start`, because `ToolApprovals` reuses an existing pending case for the same fingerprint (the `fresh` flag distinguishes them instead; a leftover pending is an honest 3). A **composer** gate parks the *child* wave run while the parent stays `:running`, so the awaiter probes the run tree (`AgentCase.pending_for_run_tree/1`) and polls `WorkflowRun.by_id` as the authoritative terminal detector (composer-parent terminals don't broadcast; pubsub is early-wake only).
- **OQ-5 — The dynamic-context lane (OS2-3, OS3-1).** Matched skill instructions and `@`-ref content both want per-turn injection without thawing the frozen prompt snapshot. One shared turn-preamble lane (as compaction summaries use), designed once?

## Cross-references and dependencies

```
hermes T1-4 (error taxonomy) ──► OS1-1b (overflow recovery) ──► OQ-3 (seam)
        │                    └─► OS2-1 (breaker + fallback)
OS1-4 (injection scan) ──► OQ-2 ──► hermes T1-5 (indirect half: delimiters)
OS1-3 (deferred tools) ──► OQ-1 (jido_ai seam)
OS1-5 (one-shot + resume) ──► OQ-4 (approval exit contract)   [independent]
OS1-2 (doom loop)                                              [independent]
OS2-2 (fs checkpoints) ──► hermes T2-5 + OQ-7 (hash validation)
OS2-3 / OS3-1 ──► OQ-5 (dynamic lane)          OS2-6 (effort) ──► AR-9 PR-1 (seam first)
```

Build order that follows: **OS1-5** (thinnest, substrate exists) → **OS1-2** (pure logic, independent) → **OS1-1a** (degrade ladder inside the existing best-effort contract) → **OS1-4** (normalizer + corpus into `security/`) → then the seam-gated pair **OS1-1b/OS1-3** once OQ-3/OQ-1 answer, with Tier 2 behind its triggers.

## Comparison: OSA vs jido_radclaw today

| Concern | OSA | jido_radclaw today |
| --- | --- | --- |
| Agent loop | Hand-rolled GenServer ReAct (fragile per own KNOWN_ISSUES) | `Jido.AI.Agent` ReAct — stronger, but hookable seams are fewer |
| Durability | SQLite + ETS + process dict; ledgers lost on restart | Ash/Postgres, event-sourced composer, Trace — stronger |
| Compaction | 6-step ladder, 4 steps LLM-free; overflow recovery; iterative 8-section summary | Single LLM summary, best-effort; no degrade, no overflow recovery |
| Loop safety | 3-mechanism doom detector + staged recovery | Ported 2026-07-03 (OS1-2): 3-mechanism LoopGuard in the tool pipeline, pre-execution halts + staged recovery |
| Tool prompt cost | Deferred loading + `tool_search` | All 33 schemas every request |
| Injection defense | 3-tier deterministic guard, 308-case corpus (direct input only) | None general; one narrow untrusted-data wrapper |
| Provider resilience | Circuit breaker + fallback chain (warts) + credential pool (half-wired) | 429/transport retry only; no 5xx retry, no fallback |
| Approval/permissions | 5 overlapping mechanisms, CLI-only interactive gate | Durable fingerprinted `AgentCase` gate, fail-closed — stronger |
| Multi-agent | Orchestrator + waves real; swarm patterns dead; teams thin | Composer (durable, gated, replayable) — stronger |
| Scheduling | HEARTBEAT checklist + CRONS/TRIGGERS, polished | Postgres cron + system jobs + `schedule_task` — equivalent core |
| Learning | SICA auto-skills, ungated (noise) | Consolidator (memories); gepa program queued for prompts/skills |
| Model routing | Marquee feature, disconnected | Same aspiration, dormant seams (AR-9 PR-1 is the plan) |

## Bottom line

OSA is the first exploration subject that shares our runtime, and the honest verdict is double-edged. As a *system*, it is what jido_radclaw would look like without Ash, without the gate family, and without event sourcing — its five overlapping permission mechanisms, in-memory ledgers, and disconnected marquee feature are the argument for the structure we already have. As a *parts bin*, it is the richest since hermes: five verified Tier-1 gaps on our side have wired, tested OSA counterparts, and for the first time some borrows are lifts — the Unicode de-obfuscation normalizer, the injection corpus, the doom-loop suggestion table, and the 8-section compaction prompt can move as code with an Apache-2.0 attribution line rather than as translations. Take the resilience pieces first (OS1-1, OS1-2, OS2-1 — they protect unattended runs, which is where the platform is heading), take the two thin ergonomics wins that our substrate already paid for (OS1-5), and let hermes keep naming the designs where both projects overlap — OSA's value there is proving the design in our language, and occasionally, in its orphaned subsystems, proving exactly what happens when you ship the loop without the gates.
