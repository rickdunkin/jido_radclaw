# Features Worth Borrowing from OptimalEngine

Exploration notes — not a plan, not a commitment. **Inventory: 2026-07-02**, against OptimalEngine @ `c91cc03` (2026-06-27, main) and jido_radclaw @ `ff39bbc9` (main). Cites are firsthand reads of both trees (five parallel subsystem reviews over the source), accurate to within a few lines.

Source: `~/workspace/research/OptimalEngine` — [Miosa-osa/OptimalEngine](https://github.com/Miosa-osa/OptimalEngine), **MIT** (© 2026 "Optimal Engine contributors", no NOTICE file). Self-description: *"a self-hosted second brain and operating engine for human and AI workspaces."* Shape: Elixir 1.17+/OTP 27, ~332 `.ex` files / ~83k LOC under `lib/`, 157 test files / ~1.8k test blocks, SQLite via exqlite (no Ecto), hand-rolled Plug/Cowboy HTTP API (90 routes, no Phoenix), 53 `mix optimal.*` tasks, a TypeScript MCP server (11 tools, stdio), three handwritten SDKs (TS/Python/Svelte), Ollama-only LLM touchpoints around a deliberately deterministic core, and a **dead `rdf ~> 2.0` dep** (the "RDF" engine inside is entirely hand-rolled; the hex lib has zero references). This is the **third Miosa-osa subject** after OSA (polished orphaned code) and osa-claude-code (does not run) — and it is the org's best repo by a wide margin.

**Honesty calibration, before anything else.** The pattern flips here, halfway. OptimalEngine has real CI, a real test culture (`test: prove X store 0→1 via real flows` commits), candid self-audit docs (`docs/architecture/REALITY-AUDIT.md` lists its own schema-only layers; `PLAN.md` gives per-gate "built spine, needs hardening" statuses), and — remarkably — an executable countermeasure to its siblings' disease: **`mix optimal.reality_check`**, a 2,016-line task that boots the app and drives every layer end-to-end with OK/WARN/FAIL probes, including asserting that provenance edges were actually written. The marquee is wired this time: the truth ladder (SourcePackage → Claim → Fact → MemoryObject) runs end-to-end, transactionally (promotion is one `BEGIN IMMEDIATE` transaction with reload-from-DB discipline, `memory_core/fact_promoter.ex:174-248`), bitemporally (closed versions immutable, `:416-439`), under a supervised autonomous `PromotionScheduler` — and Signal classification, dead in OSA, here genuinely drives routing, retrieval decay, and review (`pipeline/classifier.ex:118`, `retrieval/search.ex:518-534`). **But the OSA pattern persists, localized**: the Knowledge triple store is supervised, hydrated, and written on every edge assert with **no production reader**; OWL 2 RL inferences are computed into an ephemeral ETS table and **discarded** (`bridge/knowledge.ex:117-134`); `Session`/`SessionCompressor` (the conversation-compaction story) has no route, no CLI, no tests — and name-collides with the tested `Memory.Session`; `WorkflowSkill` stores an elaborate promotion ladder whose `execution_policy`/contracts are **read nowhere** (no executor exists; packages are born `disabled`, `workflow_skill.ex:543-544`); `WorkspaceExport` (the bidirectional projection lifecycle) is reachable only from the reality-check task; `Architecture.apply` dispatch has zero production callers; the governed tool gate is proven in tests but **bypassed by the one live autonomous path** (`connectors/pull_scheduler.ex:126` calls ungoverned `run`) and reachable from no HTTP endpoint; the audit moduledoc claims ~18 event kinds and **3 are emitted**; ACL defaults permissive and HTTP never plumbs a principal into it; the CloudEvents `Signal.Envelope` bus talks only to itself. Instructive small bugs: batch import's dedup branch matches `{:error, :duplicate}` which Intake **never returns** (dead-by-contract-drift, `batch.ex:56,225`); vector cosine silently `zip`-truncates on a dimension mismatch (`store/vectors.ex:213-217`); two embedding tables where retrieval reads the older one; all intake serialized through one global GenServer (`pipeline/intake.ex:135`); `String.to_atom` on raw HTTP body input (`api/router.ex:2139`); and the author's personal instance leaks into shipped defaults (`intent_analyzer.ex:34-64` hardcodes "ahmed"/"bennett"/"cliniciq"; `routing.ex:56` defaults to `/Users/rhl/Desktop/OptimalOS`; the `optimal://nodes/` URI resolver only resolves the demo workspace's node ids, `uri.ex:40-52`).

Companion docs: **osa** (`osa/FEATURES-WORTH-BORROWING.md`) is the primary cross-reference — same org, and OE1-1 measures exactly the summary artifact OS1-1's compaction work produces; OS3-2 already recorded that our redaction is secrets-only (OE2-3's opening). **jidoka** — queue item 5 (deterministic eval harness, `docs/plans/unadopted-next-five/README.md`) is the designated vehicle for both Tier-1 entries here. **hermes** (T1-2 compaction summary residuals; T2-15 curator). **gepa** (GP1-3 eval-sets-before-optimization — OE2-2's lineage stamps are that program's substrate; the SICA lesson kills their auto-promote-at-2-traces). **camus** (deterministic-verification doctrine — theirs is the same instinct: deterministic default judge, LLM optional). **alp-river** (AR-9's landed `[:jido_claw, :composer, :stage_prompt]` telemetry is OE2-1's trigger instrument).

## Determination (TL;DR)

**Nothing to adopt as a dependency, and a deliberately small borrow list — the smallest yet — because OptimalEngine's headline territory is where jido_radclaw is already strongest.** Their epistemics core (bitemporal facts, supersession, trust, provenance, governed recall) is real and well-built, and we already have the equivalent or better: our memory Facts are bitemporal with in-transaction invalidate-and-replace and four partial unique identities (`memory/resources/fact.ex:15-22,57-64`), episodes give staged raw provenance, recall is RRF over FTS+pgvector+trigram with scope-chain authorization *in the SQL* (`memory/hybrid_search_sql.ex:30-39`) — against their `LIKE '%q%'` governed candidate fetch. What they have that we verifiably lack sits almost entirely in **measurement**: a wired eval harness and a summary-fidelity metric, which land exactly on our queued eval-harness work; plus one named algorithm (MCTS context packing) waiting for a trigger, provenance stamps on autonomous memory writes, a PII redaction class, and a fistful of checklist-grade governance patterns.

| Part of OptimalEngine | As a dependency | What to take |
| --- | --- | --- |
| Cold-read fidelity eval (`insight/verify.ex`) | No | A measured fidelity metric for compaction summaries — the case family that makes queued eval item 5 pay (OE1-1) |
| Eval harness (`evaluation.ex`) | No | JSONL datasets, durable runs/cases, pluggable retriever/answerer/judge with a deterministic default — confirms + refines item 5's plan (OE1-2) |
| MCTS packer + tiered downgrade (`retrieval/mcts.ex`, `bandwidth_planner.ex`) | No | Coverage-maximizing budget packing; demote-fidelity-don't-drop — trigger-gated on real packing pressure (OE2-1) |
| Derivation ledger + scoring policy (`memory_core/`) | No | Model/prompt/policy-version stamps on autonomous memory writes; versioned trust formula (OE2-2) |
| PII detection + redact strategies (`compliance/pii.ex`, `redact.ex`) | No | A PII class (Luhn-validated CC, ssn/email/phone) beside our secrets redaction — demand-gated (OE2-3) |
| `mix optimal.reality_check` | No | The booted-app spine-probe pattern, as dev-ops garnish (OE3-1) |
| Governance micro-patterns | No | Audit-id backreference; unknown ≠ false before destroy; multi-source scope sweep; output contracts (OE3-2) |
| Promotion review floor (`scoring_policy.ex`) | No | Below-confidence-floor promotions wait for review — posture, demand-gated (OE3-3) |
| Truth ladder, Signal Theory, wiki, pools, RDF/OWL, skills, MCP server, connectors | — | Skip — covered better here, dead upstream, or product mismatch |

## Why not adopt OptimalEngine as a dependency

1. **It's an application with a product agenda.** The engine under MIOSA's workspace OS — Svelte dashboard SDK, starter-prompt packs, a sample workspace the URI resolver is literally hardcoded to. No library seam.
2. **Domain mismatch.** OptimalEngine governs *heterogeneous knowledge intake* for a company second brain (documents, transcripts, connectors → reviewed truth). jido_radclaw is a *code-agent orchestration platform* whose memory is operational agent recall. Their central problem (should this PDF's claims become facts?) is one we deliberately don't have.
3. **Substrate mismatch at every layer.** SQLite behind one Store GenServer + hand-rolled Plug router + row-scoping-by-convention vs Ash/Postgres policy-enforced tenancy + Phoenix. Same language, different organs — every stateful piece rewrites at the seam.
4. **Quality variance persists**, just better-localized than OSA's: the dead subsystems above, the live-path governance bypass, the atom-exhaustion warts. Anything lifted gets full red/green + precommit treatment regardless.

MIT + same runtime means pure modules (the MCTS packer, PII patterns, eval shapes) can move nearly verbatim with an attribution comment (`Miosa-osa/OptimalEngine @ c91cc03, MIT` — no NOTICE file; preserve the LICENSE copyright line).

## How to read this document

- **Recommendation** axis: `BORROW-PATTERN` / `ALREADY-COVERED` / `SKIP`. Nothing rates `ADOPT-AS-DEP`.
- **Lift** axis (same-runtime privilege, osa precedent): **verbatim** — pure functions/pattern tables/test shapes port nearly as-is; **reshape** — mechanism ports, every state/config seam rewritten; **design-only** — take the contract, write fresh.
- **Tiers**: Tier 1 = verified gap, high leverage, buildable now (both Tier 1s ride already-queued work — no new slot). Tier 2 = useful, gated on a trigger. Tier 3 = polish/checklist. IDs are `OE<tier>-<seq>`. First inventory — no Status lines yet.
- Per-entry fields: **Recommendation**, **Lift**, **Where in OptimalEngine** (with wired-in verdict), **What**, **Gap in jido_radclaw** (verified 2026-07-02), **Why it matters**, **Adoption sketch**.

---

## Tier 1 — High Impact (both ride queued eval item 5)

### OE1-1. Cold-read fidelity eval — a quality metric for compaction summaries

**Recommendation**: BORROW-PATTERN. **Lift**: design-only (theirs is an Ollama-specific prompt + scorer; the *shape* is the value).

**Where in OptimalEngine** (wired via `mix optimal.verify`; thin coverage — no `test/insight/` directory): `insight/verify.ex` — an LLM is given only a title + L0 abstract and asked to *predict the full content*; the prediction is scored against the actual content. A summary that can't support reconstruction of what matters is a summary that lost it. Same instinct as their `evaluation.ex` judge: deterministic scoring, LLM only where unavoidable.

**What**: the first measurement we'd have of whether a compaction summary preserved the load-bearing facts — as opposed to merely existing.

**Gap in jido_radclaw**: `Reasoning.Compactor` snapshots persist the summary and `summarized_request_ids`, and the transformer trims faithfully — but **nothing anywhere scores summary quality** (grep clean). Hermes T1-2 (PARTIAL) tracks summary *shape* residuals; osa OS1-1c queues a richer 8-section summary prompt — with, today, no way to tell whether the new prompt is actually better. That's the classic optimize-before-eval sequencing error gepa GP1-3 exists to prevent.

**Why it matters**: item 5 in `docs/plans/unadopted-next-five/README.md` (deterministic eval harness, jidoka #1) is queued and fires when AR-9's PR-3/4 land. Compaction fidelity is the case family that makes that harness pay beyond prompt-surface pinning: the compactor already persists exactly the (source slice, summary) pairs a fidelity case needs.

**Adoption sketch**: an eval case family for item 5's harness — from a recorded conversation slice, extract deterministic *anchors* (files touched, decisions made, open threads, error strings); grade a summary by anchor coverage, checked by string/pattern match against the summary text (camus doctrine: deterministic verdicts, head-bound). The cold-read variant (LLM reconstructs, then anchors are checked against the reconstruction) is the stricter form — keep it behind the harness's pluggable-judge seam (OE1-2) rather than day one. First fixtures: a real compacted session from `Session.metadata["compactions"]` plus a synthetic slice with planted anchors. Cross-refs: hermes T1-2, osa OS1-1c (this entry is that prompt's acceptance test).

### OE1-2. Eval-harness design points — independent confirmation for queued item 5

**Recommendation**: BORROW-PATTERN (refines queued work; nothing new to build ahead of it). **Lift**: design-only.

**Where in OptimalEngine** (wired: `mix optimal.eval.run`; `evaluation_runs`/`evaluation_cases` tables; tested): `evaluation.ex` — a dependency-light retrieval eval harness: datasets load from **JSON/JSONL files** (`:87-96,423-452`); runs and per-case results persist as **durable rows**, not console output (`:144-289`); retriever/answerer/judge are **pluggable callbacks** with deliberately deterministic defaults — extractive answerer (concatenate retrieved fact text, `:679-696`), substring "expected-answer-contains" judge (`:702-738`); per-score-key min/avg/max aggregation (`:380-403`). An LLM judge is an injection point, not a premise.

**Gap in jido_radclaw**: item 5's plan pins `Jidoka.Eval.Case`'s shape (spec + request + assertions against fake/live capabilities) and inventories our existing stubs — but leaves dataset format, run persistence, and judge defaults undecided.

**Why it matters**: two unrelated projects (jidoka, OptimalEngine) converged on spec + assertions + pluggable-judge — that's design validation, the same signal the hermes/OSA convergences carried. OptimalEngine contributes three concrete decisions worth pre-empting: **datasets as committed JSONL fixtures** (versionable, diffable, greppable), **runs persisted as data** (regression comparison across prompt changes becomes a query, not archaeology), and **deterministic-first judging** with the LLM judge as a pluggable upgrade — which is camus doctrine arriving independently.

**Adoption sketch**: when item 5 builds, adopt the three decisions: `test/fixtures/evals/*.jsonl` datasets; run results written as a JSON artifact first (rows later if regression-diffing demand appears); judge as a behaviour with the deterministic default. Seed with item 5's planned doctrine/persona/arbiter cases plus OE1-1's compaction-fidelity family. Explicitly **skip** their durable-SQL-rows-first posture (our harness runs in test env; durability can wait) and their extractive answerer (our cases target prompts/contracts, not RAG answers).

---

## Tier 2 — Useful, gated on a trigger

### OE2-1. MCTS coverage-maximizing context packing (+ demote-don't-drop rider)

**Recommendation**: BORROW-PATTERN, **trigger-gated**: adopt when a packing point shows real budget pressure. **Lift**: reshape (pure modules, tested upstream, MIT — port + property-test).

**Where in OptimalEngine** (wired behind `MCTS.enabled?`, reached from `POST /api/assemble` via `ContextAssembler.build_l2`; tested `test/retrieval/mcts_test.exs`): `retrieval/mcts.ex` — real UCT tree search over candidate *subsets*: reward `Σ relevance + λ·coverage` with λ=0.5 (`mcts.ex:29,160-163`), so the packer prefers items that add *new* information over near-duplicates of what's already packed. The rider: `bandwidth_planner.ex:110-151` `plan_tiered` — when an item won't fit, **demote its fidelity L3→L2→L1→L0 instead of dropping it**, keeping high-value items present at coarser grain.

**What**: the principled replacement for greedy top-k everywhere a budget meets a candidate list.

**Gap in jido_radclaw**: every packing point is greedy or whole: the `recall` tool returns RRF top-k (`tools/recall.ex`), memory blocks are individually char-budgeted, composer premises render in full (`route_composer/premises_context.ex` — deliberately, they're small today), compaction keeps summary + tail. No anti-redundancy selection exists (grep clean). **Honestly: no measured pain either** — which is exactly why this is Tier 2. The instrument that will say when it becomes real just landed: AR-9's `[:jido_claw, :composer, :stage_prompt]` bytes telemetry.

**Why it matters**: near-duplicate recall hits and premise growth waste budget invisibly, and this is the rare packing algorithm that arrives pure, tested, and liftable. Their legacy path independently converged on demote-don't-drop — the two compose (pack under budget; degrade fidelity at the margin).

**Adoption sketch (when triggered)**: `JidoClaw.Context.Packer` — pure `select(items, budget, relevance_fn, coverage_fn, opts)` UCT under a fixed iteration cap, property-tested (never exceeds budget; dominates greedy on planted-duplicate fixtures). Likely first consumers, in order: recall-tool k-selection; premises when stage-prompt telemetry shows growth; the osa OS1-1a degrade ladder choosing which tool results survive verbatim. Trigger: stage-prompt telemetry showing premises/recall dominating a stage's bytes, or OS1-1a landing. Until then, zero carrying cost — this entry names the answer.

### OE2-2. Provenance stamps on autonomous memory writes

**Recommendation**: BORROW-PATTERN. **Lift**: design-only.

**Where in OptimalEngine** (wired; the ladder's connective tissue): the `derivation_ledger` table (migration 032) records, for **every** Source→Claim→Fact→Memory transition: actor/evaluator/parser ids, `model_id`/`model_version`/`prompt_template_id`, confidence/precision *deltas*, a versioned `scoring_policy_version` string, and `replay_status` — so any fact answers "which model, which prompt, which policy, scored how, when" (`memory_core/derivation_ledger_entry.ex`; stamped throughout `fact_promoter.ex`, `scoring_policy.ex:1-18`).

**Gap in jido_radclaw**: consolidator-written facts carry `source: :consolidator_promoted` and a trust lift (`memory/resources/fact.ex:54`), and `consolidation_run` records counters and watermarks (`consolidation_run.ex:136-247`) — but **not which model/prompt-template/policy version produced a given fact**. Trace events see it happen, ephemerally. Similarly `Solutions.Trust`'s weights (35/25/25/15, `solutions/trust.ex`) are code constants: recomputed scores carry no formula version.

**Why it matters**: when a wrong consolidator fact surfaces, "what wrote this" is the first question and today it's unanswerable from data. The gepa program (prompt optimization behind eval gates) needs exactly this before/after lineage; a trust-formula change can't re-score history without knowing which formula scored it. This is the eval-substrate half of gepa GP1-3, bought cheaply.

**Adoption sketch**: stamp consolidator writes with `%{model:, prompt_ref:, policy_version:}` in fact/block metadata (jsonb — mind the Ash-persistence-boundary rules: string keys, test the reload path); stamp `Trust`'s formula version into solutions verification metadata on write. Trigger: the next consolidator-quality investigation or gepa kickoff — small enough to ride either session.

### OE2-3. PII redaction as a class beside secrets

**Recommendation**: BORROW-PATTERN, **demand-gated**. **Lift**: verbatim-ish for the pattern set (MIT), reshape the wiring.

**Where in OptimalEngine** (wired, fully tested — `test/compliance/{pii,redact}_test.exs`): `compliance/pii.ex` — email/phone/ssn/ipv4/url plus **Luhn-validated** credit cards (`:82-113`, killing the worst CC false-positive class); `compliance/redact.ex` — placeholder/mask/hash/remove strategies applied by **right-to-left byte-offset splicing** so earlier offsets stay valid (`:63-78`).

**Gap in jido_radclaw**: `OutputRedaction` is secrets-focused (key classification + value patterns + the ANSI root pass) — osa OS3-2 already recorded this; no PII class exists anywhere in `security/`.

**Why it matters**: secrets redaction protects *our* credentials; PII redaction protects *other people's data* transiting our durable sinks (ToolOutput rows, transcripts, memory). Irrelevant for the single-operator REPL; load-bearing the day a Discord/gateway/MCP surface relays third-party traffic in anger.

**Adoption sketch**: a PII pattern module in `security/redaction/` with per-class toggles, **default off**, enabled per-surface via config; runs in the same root pass as value redaction (redact-before-truncate holds; same posture as the ANSI strip). Port the Luhn check + pattern table with attribution; adapt their offset-splice only if we leave the regex-replace idiom. Trigger: any multi-user surface handling real third-party data.

---

## Tier 3 — Polish / checklist

### OE3-1. A booted-app spine probe (`reality_check` pattern)

**Recommendation**: BORROW-PATTERN garnish. **Lift**: design-only. **Where**: `lib/mix/tasks/optimal.reality_check.ex` (2,016 LOC, wired, doc-mandated before calling a backend change safe) — boots the real app and drives every layer with OK/WARN/FAIL + elapsed ms + row counts, including asserting provenance edges were really written. Born of necessity: this org ships disconnected subsystems, and this task is the institutional countermeasure — the executable form of what our exploration docs do in prose. **Gap**: our verification is `mix precommit` (test env) + strong integration tests; nothing boots the dev app against real Postgres and probes the spine (REPL boot path, tool pipeline + gate round-trip, composer catalog coherence, memory write→recall, MCP catalog read). **Honest weighting**: our test culture already covers most of what theirs exists to catch — value concentrates post-dep-bump/post-migration and as an operator confidence artifact, hence Tier 3. **Sketch**: `mix jidoclaw.reality_check` — migrations current; catalog integrity (stages resolve, publishes/subscribes coherence); tool pipeline with the echo stub; gate create→decide round-trip; memory write→recall; MCP catalog read. Additive to precommit, never a substitute.

### OE3-2. Governance micro-patterns — as a review checklist, not code

**Recommendation**: ALREADY-COVERED in spirit; keep four quotable rules (osa OS3-5 genre). **Lift**: none.
1. **Audit-id backreference**: a governed action inserts its audit row via `INSERT … RETURNING id` and stamps the *real* id back on the run; on failure it records `audit_link_error` — **never fabricates a synthetic id** (`tool_model_governance.ex:571-596`). Extends our event-sourced-durability checklist ("durable write not nested in conditional notify") with: never fabricate a link id.
2. **Unknown ≠ false before destructive ops**: `LegalHold.held?` returns `{:error, :hold_check_failed}` on DB error, never `{:ok, false}` (`legal_hold.ex:99-124`). We practice fail-closed on gates; quote this rule wherever a delete path consults a predicate (`forget`, future retention sweeps).
3. **Multi-source scope sweep**: authorize **every** workspace id named anywhere in the request (path + body + query), not just the one the handler reads; foreign tenant → 404 indistinguishable from absent (`workspace_auth_plug.ex:57-160`). A checklist line for gateway/MCP argument handling.
4. **Output contracts on governed calls**: input *and* output schema validation with a distinct `output_rejected` terminal (`tool_model_governance.ex:535-555`) — proven in tests upstream, not live-wired (their one autonomous path bypasses the whole gate — the exact gate-bypass class our coverage-sweep memory warns about, demonstrated in the wild). Ours: Zoi envelopes already contract worker outputs; a contract check on MCP proxy results stays a watch item under the deferred per-tool MCP overlay.

### OE3-3. Promotion review floor — below-confidence promotions wait for review

**Recommendation**: BORROW-PATTERN, **demand-gated**. **Lift**: design-only. **Where** (wired): `scoring_policy.ex:205-231` — promotion needs an explicit verifier or opt-in auto-policy ≥ a fixed 0.85 floor; unreviewed-source claims score 0.55, so the autonomous `PromotionScheduler` **structurally cannot** launder them into facts; self-review is rejected. **Gap**: our consolidator promotes everything it writes (trust lift on `:consolidator_promoted`); no pending state, no floor. Wrong facts get bitemporally invalidated later — which has been sufficient. **Why the entry exists**: if memory ever feeds higher-stakes artifacts (auto-doctrine, solution promotion to `network_share`), "below-floor waits for a human" is the posture, and our `AgentCase` gate family is the natural host (a `:memory_promotion` kind on the same `/gates`–`/approvals` surfaces). Trigger: a consolidator-written fact demonstrably steering an agent wrong, or memory feeding any externally visible artifact. Zero carrying cost now.

---

## Skip / Already Covered

- **The truth ladder as a system (Claims→Facts→MemoryObjects, bitemporal supersession, governed recall) — ALREADY-COVERED**, and better-integrated: our Facts are bitemporal (`valid_at`/`invalid_at` world time + `inserted_at`/`expired_at` system time) with in-transaction invalidate-and-replace and four partial unique identities (`memory/resources/fact.ex:15-22,57-64,101-115`); episodes are the staged raw layer with `source_message_id` provenance; `fact_episode` is the evidence join; links are typed with confidence. Their genuine deltas are exactly OE2-2 (write lineage) and OE3-3 (review floor). Their supersession-cascades-to-stale-ContextPackages is our recall filtering current-valid by construction.
- **Signal Theory classification — SKIP, with respect.** The first Miosa repo where the marquee actually runs (deterministic 5-dim classify + 142-genre registry → routing, genre half-life retrieval decay, review, receiver-format re-encoding). It solves *their* problem — heterogeneous document intake. Ours (conversations/code/tool results) is routed by front_door triage + the composer catalog. The transferable lesson — classification must drive decisions or it's an analytics column — was already booked in the osa doc, and here is its proof-by-contrast. The genre half-life detail: our bitemporal invalidation + source-precedence rank covers staleness differently; not worth a scoring rework.
- **Governed Context Packages / Active Memory Pools — ALREADY-COVERED.** Authorization-in-candidate-SQL is our scope-chain `WHERE` (`hybrid_search_sql.ex:30-39`); their governed candidate fetch is `LIKE '%q%'` with no relevance ranking — our RRF path is strictly stronger. Pools ≈ sessions + `SubagentTranscript` + composer waves/premises. One garnish noted, not queued: their **excluded-object accounting** ("N objects withheld, by reason class" returned with results, `retrieval_coordinator.ex:143-198`) — transparency worth remembering if a multi-tenant gateway recall surface ever ships.
- **Wiki layer (staleness scheduler, LLM re-curation, integrity checks incl. contradictions + claim density, citation rows; `Wiki.Directives`' 7-verb whitelisted template language projecting one body → plain/markdown/Claude-XML/OpenAI-JSON) — SKIP.** We have no wiki and no demand; req_llm owns provider formatting; `PremisesContext` owns stage-context rendering. The kernel worth remembering if a curated knowledge surface ever appears (hermes T2-15 curator world): deterministic whitelisted directives + citation consistency between curated and raw paths (`wiki/directives.ex:24-35`, `retrieval/deliver.ex:45-65`).
- **Session / SessionCompressor — SKIP.** Orphaned upstream (no route, no CLI, no direct tests; name-collides with the *tested* `Memory.Session`) and our Compactor with durable per-agent snapshots is strictly stronger. The one OSA-classic specimen in the tree.
- **CloudEvents Signal bus (Envelope/Journal/PubSub/Dispatcher) — SKIP.** Supervised but talks only to itself; no content-path publishers; the Dispatcher's only caller is the reality-check task. We ride `Jido.Signal`.
- **RDF/SPARQL/OWL knowledge engine — SKIP, with a tip of the hat.** Hand-rolled SPARQL 1.1 parser+executor, OWL 2 RL reasoner, leapfrog/trie worst-case-optimal joins — real, unit-tested, and **write-only in production** (no reader; inferences computed then discarded; the hex `rdf` dep never called). The org's finest polished orphan. No graph-reasoning demand here; pgvector + typed links + RRF serve.
- **WorkflowSkill promotion ladder (traces → generalized workflow → procedural memory → Skill Package) — SKIP as machinery.** No executor exists; `execution_policy`/contracts are read nowhere; packages are born disabled; callers are one mix task + reality_check. The ladder *concept* is gepa GP1-1/GP2-2 + hermes T2-15 territory, already queued behind eval gates — and their auto-promote-at-2-similar-traces would recreate the SICA lesson (osa doc: occurrence counting ≠ validation).
- **Tool/model governance registry — mostly covered.** Our `ToolApproval` is durable, fingerprinted, fail-closed, and *live on every path*; theirs is automated-policy flavored, tested, and bypassed by its own scheduler. The output-contract idea is booked in OE3-2.4.
- **MCP server (TypeScript, 11 tools, stdio, no resources, no tests, read-mostly HTTP proxy) — SKIP.** Ours exceeds it on both serve (24 tools + catalog + per-stage template resources) and consume (safety-pipeline proxies) sides.
- **Connectors (15 adapters, real HTTP, PullScheduler) — SKIP.** Product-space mismatch; VFS + MCP consumption are our integration seams. Lesson recorded: their one live autonomous caller uses the ungoverned entry point — gate-bypass sweeps must include schedulers and internal callers, not just user surfaces.
- **WorkspaceExport bidirectional projection lifecycle** (content-hashed `projection_revision`s, drift detection, capture-edit re-ingest) — **concept noted, DEAD upstream** (mix-task-only). We project no editable files; if we ever do, read `workspace_export.ex` first.
- **Auth / tenancy / audit / backup / rate limiting — ours stronger** (Ash policies vs row-convention + boundary plug; AshCloak vault; pg_dump vs `VACUUM INTO`). Shared gap, explicitly a non-borrow: **neither side has tamper-evident audit** (their `events` table is plain rows; hash-chaining would be net-new to both, and nothing drives it).
- **Their bugs as checklist confirmations** — each maps to a discipline we already carry: dead dedup branch matching an error the callee never returns (dialyzer/compile_check territory); silent vector-dim truncation (pgvector's typed columns make it structural for us); two embedding tables with retrieval on the older one (architecture drift — doc-reconcile territory); one-GenServer intake serialization (our per-session processes); `String.to_atom` on HTTP input (usage-rules staple).

## Open questions

- **OQ-1 — Packer placement (gates OE2-1).** When packing pressure materializes, which consumer first: recall-tool k-selection, premises rendering, or the OS1-1a degrade ladder's keep-verbatim choice? Decide from the stage-prompt telemetry, not in advance.
- **OQ-2 — Fidelity-judge policy (gates OE1-1).** Deterministic anchor-coverage only (camus doctrine), or admit the cold-read LLM-reconstruction variant behind item 5's pluggable-judge seam from day one? Leaning deterministic-first; the LLM variant is a later upgrade.
- **OQ-3 — PII pass placement (gates OE2-3).** Inside `OutputRedaction`'s root pass beside the ANSI strip, or a separate stage? And how does PII value-detection interact with key classification (an email in a value vs an email-shaped key)?

## Cross-references and dependencies

```
jidoka item 5 (queued eval harness) ──► OE1-2 (design points) ──► OE1-1 (fidelity cases) ──► OQ-2
osa OS1-1c (8-section summary prompt) ──► OE1-1 (its acceptance test)
AR-9 stage_prompt telemetry (landed) ──► OE2-1 trigger ──► OQ-1
gepa GP1-3 (evals before optimization) ──► OE2-2 (lineage stamps are the substrate)
osa OS3-2 (redaction is secrets-only) ──► OE2-3 ──► OQ-3
osa OS3-5 (lessons-as-checklist genre) ──► OE3-2
```

Build order that follows: **OE1-2 + OE1-1 ride item 5 when it fires** (no new queue slot). **OE2-2 rides the next consolidator/gepa session.** Everything else waits on its named trigger.

## Comparison: OptimalEngine vs jido_radclaw today

| Concern | OptimalEngine | jido_radclaw today |
| --- | --- | --- |
| Truth/memory model | SourcePackage→Claim→Fact→MemoryObject, bitemporal, ledger, review floor | Episodes→Facts, bitemporal + trust + links, autonomous consolidator — equivalent core; no write lineage (OE2-2), no review floor (OE3-3) |
| Recall | Governed path is `LIKE`-ranked; legacy hybrid is linear-blend; MCTS packer | FTS+pgvector+trigram RRF, scope-chain authz in SQL, bitemporal filters — stronger ranking; no packer (OE2-1) |
| Compaction | Orphaned `SessionCompressor` | Live Compactor, durable per-agent snapshots — stronger, but unmeasured (OE1-1) |
| Eval | Wired JSONL dataset runner, durable runs, pluggable judge | Queued (item 5) — theirs confirms the design (OE1-2) |
| Workflows/skills | Data-only promotion ladder, no executor | YAML DAG engine + durable event-sourced composer with gates/replay — stronger |
| Tool governance | Automated policy gate w/ output contracts; tested; bypassed on its own live path | Durable human gate, fail-closed, live on every path — stronger where it counts |
| Multi-tenancy | Row-convention SQLite + boundary plug (one genuinely good plug) | Ash/Postgres policy-enforced — stronger |
| Classification/routing | Wired, deterministic, drives decisions (org first) | front_door triage + composer catalog — different problem, covered |
| Audit | 3 emitters vs ~18 claimed; no tamper evidence | Trace + WorkflowEvent + ToolOutput refs; no tamper evidence either |
| Self-verification | `reality_check` boot probe (institutionalized countermeasure) | precommit + suite (stronger culture); no boot probe (OE3-1) |

## Bottom line

OptimalEngine is the first Miosa-osa repo where the marquee feature actually runs, and it's no accident that the same repo carries a self-audit doc and a 2,000-line executable wiring probe — the org diagnosed its own disease and built the countermeasure, which is worth more respect than any single subsystem. As a system it solves a problem we deliberately don't have (governed knowledge intake for a workspace second brain), on a substrate we've deliberately surpassed (SQLite + convention vs Ash/Postgres + policy), which is why the borrow list is the smallest of any subject so far — the overlap lands on our strongest organs, not our gaps. What survives is precise: their measurement layer arrives exactly as our eval-harness queue item needs design confirmation (OE1-2) and a first high-value case family (OE1-1); their MCTS packer names the algorithm for a packing decision our new telemetry will eventually force (OE2-1); their derivation ledger shows the cheap lineage stamps our consolidator and the gepa program will want (OE2-2); and their compliance layer contributes a PII class ours never needed until multi-user surfaces make it need one (OE2-3). Take the measurement pieces when item 5 fires, book the triggers for the rest, and file the deepest lesson where the org's whole arc points: wiring is the feature, and every subsystem here that skipped its own reality check — the discarded OWL inferences, the bypassed governance gate, the orphaned compressor — is the proof.
