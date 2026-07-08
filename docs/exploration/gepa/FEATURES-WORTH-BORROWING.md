# Features Worth Borrowing from GEPA

Exploration notes — not a plan, not a commitment. **Inventory: 2026-07-02**, against gepa @ `92dadfff` and jido_radclaw @ `ff39bbc9` (main). Cites are firsthand reads of both trees, accurate to within a few lines.

Source: `~/workspace/research/gepa` — [gepa-ai/gepa](https://github.com/gepa-ai/gepa) v0.1.1, MIT (© 2025 Lakshya A Agrawal). Self-description: *"Optimize any text parameter — prompts, code, agent architectures, configurations — using LLM-based reflection and Pareto-efficient evolutionary search."* GEPA ("Genetic-Pareto") is the reference implementation of arXiv:2507.19457 (*Reflective Prompt Evolution Can Outperform Reinforcement Learning* — Agrawal, Khattab, Potts, Klein, Stoica, Zaharia, et al.). Pure Python ≥3.10 with **zero required dependencies** (litellm/wandb/mlflow are extras); `src/` ≈ 22.6k LOC of which the actual engine + strategies + proposers are only ≈ 4.2k (adapters ≈ 7.8k, `optimize_anything.py` ≈ 1.6k); tests ≈ 13.5k LOC. Not a toy: it ships inside `dspy.GEPA`, `mlflow.genai.optimize_prompts()`, Comet Opik, and Google ADK's `adk optimize`, with published results of the "35× fewer rollouts than GRPO", "55%→82% coding-agent resolve rate via auto-learned skills" variety.

The core idea, in one sentence: instead of collapsing a rollout into a scalar reward, an LLM *reads the execution trace and evaluator feedback* ("Actionable Side Information") to diagnose *why* a candidate text failed and propose a targeted rewrite; a per-instance Pareto frontier keeps specialist candidates alive; a cheap minibatch acceptance gate keeps eval spend frugal.

Companion docs: the propose→eval→promote loop sketched here rides machinery inventoried elsewhere — the AR-2 composer and its AR-4 review→fix→re-review dynamic loop (`alp-river/FEATURES-WORTH-BORROWING.md`), the Reactor skill runner and `:iterative` generator/evaluator step (`squidie/REACTOR-ADOPTION.md`), and the `.jido/` YAML reload posture noted in gust G3-2. First inventory — no `UNADOPTED-IDEAS.md` rollup yet (camus precedent).

## Determination (TL;DR)

**Nothing to adopt as a dependency; the algorithmic contracts are the best borrow-per-line of any exploration subject so far — jido_radclaw already owns most of GEPA's substrate (scorers, durable traces, a cron reflection loop, hot-reloadable prompt YAML) while lacking all four load-bearing pieces (eval sets, a candidate store, Pareto selection, a prompt-rewrite harness), and each missing piece ports as a small mostly-pure Elixir module.**

| Part of gepa | As a dependency | What to take |
| --- | --- | --- |
| Reflective mutation pipeline + meta-prompt (`proposer/`, `strategies/instruction_proposal.py`) | No (Python) | The whole shape, near-verbatim: trace → reflective dataset → generic meta-prompt → fenced rewrite (GP1-1) |
| Adapter/evaluator contract (`core/adapter.py`) | No | `evaluate` + `make_reflective_dataset` boundary; ASI feedback records; never-raise scoring (GP1-2, GP2-2) |
| Budget machinery (acceptance gate, metric-call budget, eval cache, eval policy) | No | Minibatch-gate-then-full-eval cascade (GP1-3); score-row-as-cache (GP2-4) |
| `GEPAState` (candidates, lineage, per-instance scores) | No (pickle files) | The schema, as Ash resources (GP1-4) |
| Per-instance Pareto frontier + frequency-weighted selection (`gepa_utils.py`) | No | The ~150-line algorithm, as a pure module (GP2-1) |
| System-aware merge (`proposer/merge.py`) | No | Later, once lineage + frontier exist (GP2-3) |
| `optimize_anything` (seedless bootstrap, refiner co-evolution) | No | Watch; seed-bootstrap idea only (GP3-4) |
| Stop conditions, candidate-tree viz, proposals audit table | No | Small borrows (GP3-1..3) |
| LM wrapper, pickle persistence, wandb/mlflow tracking, sandboxed exec, domain adapters | No | Nothing — already covered or out of stack (Skip) |

## Why not adopt gepa as a dependency

1. **Runtime mismatch.** Pure Python on the BEAM means a sidecar subprocess — and GEPA is not a leaf utility, it's a *loop that owns state, budget, and scheduling*. Putting the loop outside OTP supervision, Ash durability, and tenant scoping inverts everything the platform is built on.
2. **Inversion of control.** GEPA wants to own the optimization loop and call *your* system through its adapter. jido_radclaw's core competency is exactly that orchestration layer (composer waves, Reactor skills, cron system jobs, gate cases). Two loop-owners is one too many.
3. **Persistence mismatch.** GEPA checkpoints to `run_dir/gepa_state.bin` via pickle/cloudpickle with hand-rolled schema migration (`core/state.py:306-401`). We event-source to Postgres and project (`WorkflowEvent` → composer state); its resume story is solved differently and better here.
4. **LM plumbing duplication.** GEPA's `LM`/`TrackingLM` (litellm cost accounting, `lm.py:73-190`) parallels ReqLLM + `Jido.AI` model aliases + AgentTracker token/cost rollups. Bridging two provider stacks buys nothing.
5. **The valuable parts are small.** The reflection meta-prompt is ~20 lines; the acceptance gate is one comparison; the Pareto update + dominated-pruning + weighted sampling is ~150 lines of pure logic. Porting is cheaper than bridging, and the port lands tenant-scoped, gate-guarded, and telemetry-instrumented for free.

## How to read this document

- **Recommendation** axis: `BORROW-PATTERN` (reimplement the idea in our idioms) / `ALREADY-COVERED` (we have an equivalent) / `SKIP` (not worth it here). Nothing rates `ADOPT-AS-DEP` (see above).
- **Tiers**: Tier 1 = clear gap, high leverage, buildable now on existing substrate. Tier 2 = useful, but a design decision gates it. Tier 3 = polish.
- Per-entry fields: **Recommendation**, **Where in gepa**, **What**, **Gap in jido_radclaw**, **Why it matters**, **Adoption sketch**. IDs are `GP<tier>-<seq>`. First inventory, so entries carry no **Status** field yet (camus precedent: statuses arrive with the first adoption pass).

## Tier 1 — High Impact

### GP1-1. The reflective mutation pipeline — and its deliberately generic meta-prompt

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `proposer/reflective_mutation/reflective_mutation.py:191-447` (select candidate → sample minibatch → evaluate parent with traces → pick component → build reflective dataset → propose rewrite → evaluate child on the *same* minibatch); `strategies/instruction_proposal.py:13-34` (the meta-prompt: two placeholders, `<curr_param>` and `<side_info>`, output extracted from the last ``` fence); `strategies/component_selector.py:10` (round-robin: mutate exactly one named component per iteration, per-candidate cursor).

**What**: The full "read the trace, diagnose, rewrite" loop. The meta-prompt is small and *generic* — "identify all niche and domain specific factual information … and include it in the instruction" — and all domain specialization arrives through the adapter-authored feedback text, never through engine prompt engineering. GEPA is best understood as *precomputing reasoning during optimization* so future task instances get it for free (the README's evolved AIME/HotpotQA prompts are essentially distilled playbooks).

**Gap in jido_radclaw**: There is no gather-trace → reflect → rewrite-artifact harness anywhere. Every prompt is static: compile-time worker literals (`agent/workers/coder.ex:6-8`), the human-gated `system_prompt.md` sync (`agent/prompt.ex:94-218` — a SHA-pair reconciliation, not an optimizer), and `.jido/` YAML read-only stores. The closest architectural relative is the memory consolidator (`memory/consolidator.ex` — cron-driven LLM reflection over clustered memories, proposing add/update/delete mutations through MCP tools), which reflects over *memories*, not *instructions*. `PullRequestCoordinator` accumulates a per-attempt `history` and never feeds it back into `generate_patch` (`github/agents/pull_request_coordinator.ex:14-37`).

**Why it matters**: This is the headline capability of the whole exploration — closing the loop from outcomes to instruction text. The consolidator proves the platform can already run periodic-LLM-reflection-then-artifact-mutation safely (leader-gating caveats documented at `platform/cron/scheduler.ex:352-361`); the missing piece is pointing that shape at prompts with scores attached. GEPA's evidence says the payoff is large and cheap (100–500 metric calls, works from as few as 3 examples).

**Adoption sketch**: A new `JidoClaw.Optimize` subsystem. (a) `Optimize.Reflector` — port the meta-prompt near-verbatim; call via `Jido.AI.generate_object/3` following the `JidoClaw.Triage.LLM` pattern (`triage/llm.ex:34-58`: tool-less, process-less, `gen` app-env seam for tests), `model: :capable`. (b) Reflective dataset assembled from `reasoning_outcomes` rows (`reasoning/telemetry.ex:253-301`) and Trace/`WorkflowEvent` context per GP1-2. (c) Loop host: a cron `:system_job` cloned from the consolidator's `SystemJobsInitializer` (`platform/cron/scheduler.ex:363-391`), idempotent/DB-leased; graduate to a composer route later (GP2-2 / Open questions). (d) Round-robin component cursor when the artifact is multi-slot (a strategy YAML `prompts:` block has up to five named slots — a ready-made `dict[str,str]` candidate).

### GP1-2. Actionable Side Information: evaluators return feedback text, not just a score

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `core/adapter.py:15` (`EvaluationBatch`: `outputs`, `scores`, opaque `trajectories`, optional per-objective scores); `adapter.py:112` (contract: *never raise per-example* — return score 0.0 with the error in the trajectory); `adapter.py:183` (reflective-record schema: `{"Inputs", "Generated Outputs", "Feedback"}`); `optimize_anything.py:173,349` (`SideInfo`, thread-safe `oa.log(...)` capture, described as "the text-optimization analogue of the gradient").

**What**: The evaluator's textual diagnosis — compiler errors, failed-check names, reviewer findings — is the payload reflection runs on. Scores select; *feedback teaches*.

**Gap in jido_radclaw**: The scorers exist but nothing shapes their diagnostics into per-example records a reflection prompt could consume. Certificates parse a fenced JSON verdict + confidence 0.0–1.0 (`reasoning/certificates.ex:301-320`); `PatchQuality.validate/1` returns failed-check atoms (`github/patch_quality.ex:41-48`); composer verify stages emit `findings:*` signals; `WorkflowEvent` carries terminal kinds (`route_verify_failed`, `route_budget_exhausted`, … at `orchestration/workflow_event.ex:95-160`). Each is a dead end today — scored, logged, never re-read by anything that improves an artifact.

**Why it matters**: Cheapest contract change with the largest downstream effect; it is the difference between "score went down" and "here is the error message that explains why." It also composes with house instincts — the never-raise rule is exactly the `Tools.Action` error-normalization idiom, and "redact before durable sink" already applies to trace text.

**Adoption sketch**: Define `JidoClaw.Optimize.EvalRecord` (inputs, generated output, score, feedback iodata, refs to Trace/`ToolOutput`). Provide adapters from the three existing scorer families: certificate verdict+confidence → score + rationale text; `PatchQuality` failed checks → named-check feedback; composer findings payloads → per-lens feedback. Feedback text passes through `OutputRedaction` before persistence (same posture as tool output).

### GP1-3. Eval sets and the budget-frugal gate cascade

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `strategies/acceptance.py:39` (`StrictImprovementAcceptance`: child must beat parent on the *same minibatch*, by summed score, before any full eval); `core/engine.py:175-287` (full-valset eval + Pareto update only for gate-passers); `core/state.py:286` (every eval increments a metric-call budget; `num_metric_calls_by_discovery` stamped per candidate); `utils/stop_condition.py:163,176` (`MaxMetricCalls`, `MaxReflectionCost`).

**What**: Two-stage spend control: a cheap same-minibatch A/B gate filters mutations, and only winners pay for the full validation set. Budget is denominated in *metric calls*, the honest unit when each eval is an agent rollout.

**Gap in jido_radclaw**: No eval dataset / benchmark concept exists at all (grep for eval-harness/benchmark/golden-set/pareto finds nothing). `reasoning_outcomes` is opportunistic *production* telemetry — no fixed inputs, no expected outputs, so scores are not comparable across candidates. Budget exists on the workflow axis (`route_budget_exhausted`) but nothing counts evals.

**Why it matters**: This is the prerequisite that makes GP1-1 an *optimizer* rather than a prompt-rewriting daemon. Without a fixed scored set there is no signal; without the cascade, cost explodes (each eval here is a Forge run or an agent turn, not a cheap completion).

**Adoption sketch**: `EvalTask` Ash resource (tenant-scoped: input payload, check spec — expected output, command assertion, or certificate template ref — plus provenance: hand-written vs mined from a `WorkflowEvent` terminal). `EvalSet` groups them; start hand-curated and small (GEPA claims useful signal from ~3 examples). Minibatch sampling per gepa's `EpochShuffledBatchSampler` (shuffle per epoch, deterministic seeded RNG — `strategies/batch_sampler.py`). Executor: Forge (`forge/harness.ex:55-61`) for command-shaped tasks, `RunStrategy` via `Reasoning.Telemetry.with_outcome/4` for reasoning-shaped ones (outcome rows then double as score records). Budget: a per-run metric-call counter surfaced as a composer budget gate, same family as `route_budget_exhausted`.

### GP1-4. A candidate store with lineage and per-instance scores

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `core/state.py:157-180` — `program_candidates: list[dict[str,str]]`; `parent_program_for_candidate: list[list[idx|None]]` (a *list* of parents because merges have two); `prog_candidate_val_subscores: list[dict[DataId, float]]` (per-instance scores keyed by example id — a dict, not a list, so partial coverage is first-class); `num_metric_calls_by_discovery`; per-candidate round-robin cursor. Update path `state.py:527`.

**What**: The genealogy and score matrix that everything else (frontier, merge, viz, resume) reads from.

**Gap in jido_radclaw**: The only prompt "versioning" in the tree is two SHAs in `.jido/.system_prompt.sync` (`agent/prompt.ex:355-363`). No candidate rows, no scores-per-candidate, no lineage anywhere.

**Why it matters**: Prerequisite for GP2-1/GP2-3, and the auditability story: "which prompt text, descended from what, scored how, at what spend" is exactly the kind of question the platform answers with Ash resources everywhere else. GEPA's dict-keyed subscores detail matters — it is what lets an incremental eval policy score only part of the valset without corrupting comparisons.

**Adoption sketch**: Two resources. `PromptCandidate`: `component_texts` (jsonb map — pin the JSONB round-trip shapes at the boundary), `parent_ids` (array), `surface` (strategy alias / skill name / tool name), `status`, `discovered_at_budget`. `CandidateScore`: (`candidate_id`, `eval_task_id`, `score`, `feedback_ref`), unique on the pair — one row per (candidate, task), so partial coverage is the natural representation and the store doubles as the eval cache (GP2-4). Deploying a winner = writing the strategy YAML `prompts:` block and calling the store's `reload/0` (`reasoning/yaml_store.ex:140-145`) — **behind a human gate case** (Open questions, OQ-1).

## Tier 2 — Useful, gated on a design decision

### GP2-1. Per-instance Pareto frontier with frequency-weighted selection

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `core/state.py:162-163,486` (per-example best score + the *set* of programs achieving it; beat ⇒ replace set, tie ⇒ join set); `gepa_utils.py:37,90,106` (prune programs dominated on every front they appear on; then sample a candidate with probability proportional to the number of instances it is best on); `core/state.py:22` (frontier types: `instance` / `objective` / `hybrid` / `cartesian`); `strategies/candidate_selector.py` (also `CurrentBest`, `EpsilonGreedy`, `TopKPareto`).

**What**: Selection that retains *specialists*: a candidate that is best on only three stubborn examples survives instead of being averaged away, and gets mutation attention proportional to its wins. This is the paper's answer to why evolution beats hill-climbing-on-the-mean.

**Gap in jido_radclaw**: `Statistics.best_strategies_for/2` is single-objective aggregate success-rate ranking (`reasoning/statistics.ex:34-70`), folded into `AutoSelect` (`reasoning/auto_select.ex`). Nothing per-instance, nothing multi-candidate.

**Why it matters**: Without it, GP1-1 degenerates to greedy hill-climbing on the aggregate — the configuration the paper ablates against. The design decision gating it: which frontier axis (per eval-task instance, per named objective, or hybrid — gepa defaults `optimize_anything` to hybrid, `optimize` to instance), and whether `AutoSelect` later grows a per-task_type instance frontier of its own (a natural convergence, not required now).

**Adoption sketch**: Pure module `JidoClaw.Optimize.Frontier` (~150 lines) computed from `CandidateScore` rows: build per-instance fronts, prune dominated, emit the weighted sampling list. Property-test dominance pruning. Keep `CurrentBest` and `EpsilonGreedy` as cheap alternates behind one config key.

### GP2-2. The narrow adapter boundary — one engine, many optimizable surfaces

**Recommendation**: BORROW-PATTERN.

**Where in gepa**: `core/adapter.py:59-195` — the *entire* integration surface is `evaluate(batch, candidate, capture_traces)` + `make_reflective_dataset(candidate, eval_batch, components)` + optional `propose_new_texts`, keyed on opaque `dict[str,str]` candidates. Ten shipped adapters ride it, including the MCP adapter that optimizes *tool descriptions* (`adapters/mcp_adapter/mcp_adapter.py:94`) and the `gskill` SWE-bench skill-learning harness (`src/gepa/gskill/`, the 55%→82% result).

**What**: The reason GEPA generalizes: everything downstream of the engine sees named-text-components + per-example scores, nothing else.

**Gap in jido_radclaw**: Prompt text lives in four unlike formats — compile-time worker literals (`agent/templates.ex:87-190`), strategy YAML `prompts:` blocks validated ≤5KB per slot (`reasoning/strategy_store.ex:85-101,161-209`), skill step `task:`/`synthesis:` strings (`platform/skills.ex:63-130`), catalog stage `task:` strings (compile-time, `route_composer/catalog.ex`) — with no unified "optimizable text component" abstraction over them.

**Why it matters**: The decision this forces is the right one to have on paper *before* GP1-1 ships: which surface is the first optimization target. Strategy `prompts:` blocks are the lowest-friction (already flow into live `RunStrategy` calls via `strategy_registry.ex:199-234`, hot-reloadable, per-strategy isolated, and *already shaped as a named-components map*). Skill `task:` strings are higher leverage — the gskill precedent says skills are where coding-agent gains live — but riskier blast radius. MCP tool descriptions are a documented prompt-trust surface we both serve and consume; gepa has a dedicated adapter precedent for exactly that.

**Adoption sketch**: `JidoClaw.Optimize.Adapter` behaviour: `evaluate/3`, `make_reflective_dataset/3`, optional `propose_new_texts/3`. First implementation `Adapters.StrategyPrompts`; second `Adapters.SkillTasks`; keep `Adapters.MCPToolDescriptions` on the roadmap only. Worker literals and catalog `task:` strings stay out of scope until a runtime overlay exists for them (they are compile-time by design).

### GP2-3. System-aware merge (ancestor-aware crossover)

**Recommendation**: BORROW-PATTERN, deferred.

**Where in gepa**: `proposer/merge.py:118-306` — find two frontier programs sharing a common ancestor both outperform; per component take the descendant text that *changed* relative to the ancestor (higher-scoring descendant wins conflicts); require ≥5 shared evaluated val ids; subsample-score on examples where the parents differ. Scheduling: a merge is *earned* by an accepted mutation (`merges_due`, `core/engine.py:370-374`), attempted before the next reflection, accepted iff `new_sum >= max(parent_sums)` (`engine.py:688`), and a rejected merge does not consume the merge budget (`engine.py:721`).

**What**: Recombination of complementary specialists — the "genetic" half of Genetic-Pareto.

**Gap in jido_radclaw / Why deferred**: Needs GP1-4 lineage and GP2-1 frontier to exist first, and the paper treats merge as a secondary contributor. Adopt when the reflective loop demonstrably plateaus on tasks where two candidates hold disjoint instance-wins.

**Adoption sketch**: A pure function over `PromptCandidate` rows (ancestor triangulation is trivial with `parent_ids`); reuse GP1-3's acceptance machinery with the `>=`-max-parent variant.

### GP2-4. Evaluation cache and incremental eval policy

**Recommendation**: BORROW-PATTERN (mostly free given GP1-4).

**Where in gepa**: `core/state.py:46,618` — cache keyed `(sha256(candidate), example_id)`; full evals split cached/uncached and pay only for misses. `strategies/eval_policy.py:12-53` — `EvaluationPolicy` chooses *which* val ids each full eval scores; best-program comparison averages over evaluated ids and tie-breaks on coverage, so partial coverage is sound. Disk-backed variant in the `optimize_anything` adapter.

**What**: Never pay for the same (candidate, example) rollout twice; optionally never pay for the whole valset at once.

**Gap in jido_radclaw**: Nothing caches eval results because no evals exist. Fingerprint-keyed caching is, however, a house pattern already (`Solutions.Fingerprint` canonical-term hashing — and the memory rule applies: hash a canonicalized semantic term, not rendered text).

**Why it matters**: Evals are the dominant cost, and resume/re-run becomes near-free. The unique `(candidate_id, eval_task_id)` row from GP1-4 *is* the cache — this entry is mostly a policy decision (score the full set per promotion, or a rotating subset).

**Adoption sketch**: Enforce the unique pair index; eval = "insert missing rows only." Start with gepa's default full-eval policy; add a rotating-subset policy only if valsets grow past what a budget tolerates.

## Tier 3 — Polish

- **GP3-1. Stop-condition vocabulary — BORROW-PATTERN (partial) / ALREADY-COVERED (partial).** `utils/stop_condition.py` ships Timeout / file-sentinel / ScoreThreshold / **NoImprovement** / signal / MaxMetricCalls / MaxReflectionCost / Composite. The budget kinds map onto the composer's existing budget-gate family (`route_budget_exhausted`); the borrow is the *no-improvement (dry-rounds) stopper* and a score-threshold early-exit for optimization runs. Small.
- **GP3-2. Candidate lineage tree visualization — BORROW-PATTERN.** `visualization.py` renders the genealogy (self-contained HTML, written every iteration, `core/engine.py:880`). A LiveView page over `PromptCandidate.parent_ids` edges with per-node aggregate score; cheap once GP1-4 exists, and exactly the dashboard's shape.
- **GP3-3. Proposal-level audit logging — BORROW-PATTERN.** The engine logs a "proposals" table carrying the *full reflection prompt and raw LM output* per attempt (`core/engine.py:264,818`). Map to Trace events (an `:optimize` event kind) + a `WorkflowEvent` per accepted candidate — matches the house rule that reflection I/O is redacted before any durable sink.
- **GP3-4. `optimize_anything` extras: seedless bootstrap + co-evolved refiner — watch, don't build.** Seed generation from an `objective` string (`optimize_anything.py:617-658`) is a nice cold-start; the refiner (an inner per-eval improvement loop whose own prompt is auto-injected into the candidate and co-evolved by the outer loop, `optimize_anything.py:1406-1412`) is clever but two loops deep. Revisit only after GP1-1 is boring.

## Skip / Already Covered

- **The library as a sidecar dependency — SKIP.** Reasons 1–5 above; the loop must live inside OTP/Ash or it fights the platform.
- **`LM`/`TrackingLM` + litellm cost accounting (`lm.py`) — ALREADY-COVERED.** ReqLLM + `Jido.AI` aliases (`:fast`/`:capable`, set from `.jido/config.yaml` at `cli/repl.ex:58-59`) and AgentTracker token/cost rollups cover model plumbing and spend visibility.
- **Pickle state persistence + schema migration + auto-resume (`core/state.py:306-401,669`) — ALREADY-COVERED.** Event-sourced `WorkflowEvent` projection is the house resume story; GP1-4 stores candidates durably from the start, so there is nothing to migrate.
- **wandb/mlflow experiment tracking (`logging/experiment_tracker.py`) — SKIP.** Telemetry + Trace + the dashboard are the equivalents; no wandb/mlflow in the stack.
- **Sandboxed code execution util (`utils/code_execution.py`) — ALREADY-COVERED.** Forge microVMs are strictly stronger (checkpointing, event log, Docker isolation).
- **Domain adapters (DSPy, generic RAG, LangChain, Terminus, AnyMaths) — SKIP.** Not our stack. The Confidence adapter's logprob-aware scoring (penalize lucky guesses, `adapters/confidence_adapter/scoring.py`) is a genuinely good idea to remember *if* ReqLLM ever exposes logprobs cleanly — footnote-level, not an entry.
- **Parallel proposal machinery (`core/engine.py:381`) — SKIP.** Incidental under OTP; `Task.async_stream` when the loop needs it.
- **Multimodal/image reflection (`instruction_proposal.py:116`) — SKIP.** Premature here.

## Open questions

- **OQ-1 — Deploy gate.** An optimizer that rewrites `.jido/strategies/*.yaml` is a config-writing agent; the write must route through the gate family (an `AgentCase`, like tool approvals / workflow gates), or through an `/upgrade-prompt`-style sidecar diff review (`agent/prompt.ex:94-218` is the precedent). Which surface — gate case with diff payload, or sidecar file + REPL command?
- **OQ-2 — Eval-task provenance.** Hand-curated golden set (stable, labor) vs mined from `WorkflowEvent` terminal runs (free, but noisy expected-outputs). Start hand-curated-small (~10 tasks/surface); add a "promote this run to an eval task" affordance later.
  *Provenance note (2026-07-08, next-ten #9 shipped)*: runs can now carry structured
  `acceptance_criteria` premises (stable `AC1…` ids, `docs/system/structured-premises.md`) —
  an AC that shipped with a run is a **labeled eval-task candidate**, so the mined path
  has real expected-outputs to mine when this question is picked up; the first eval
  seed case pinning ACs-in-prompt lives in `test/jido_claw/eval/composer_vendor_case_test.exs`.
- **OQ-3 — First surface.** Strategy `prompts:` blocks (isolated, hot-reloadable, shaped right) vs skill `task:` strings (gskill says the leverage is here). Recommendation embedded in GP2-2: strategies first to prove the loop, skills second.
- **OQ-4 — Reflection spend policy.** Reflection calls use `:capable`; evals use whatever the surface uses. Is the budget denominated only in metric calls (gepa's default) or also in reflection tokens (`MaxReflectionCost` analog via AgentTracker)?

## Cross-references and dependencies

```
GP1-2 (EvalRecord/ASI) ──► GP1-1 (reflective loop) ◄── GP2-2 (adapter boundary: first surface)
                                │
GP1-3 (eval sets + gate) ──────┤
                                ▼
GP1-4 (candidate store) ──► GP2-1 (Pareto frontier) ──► GP2-3 (merge, deferred)
        │                                                     
        ├──► GP2-4 (score-row-as-cache)                       
        └──► GP3-2 (lineage viz), GP3-3 (audit log), GP3-1 (stoppers)
```

Build order that follows: GP1-2 → GP1-3 → GP1-4 → GP1-1 (loop over CurrentBest selection) → GP2-1 (swap in Pareto) → the rest as pull demands.

## Comparison: gepa's loop vs jido_radclaw today

| Concern | gepa | jido_radclaw today |
| --- | --- | --- |
| Candidate texts | `dict[str,str]` components, versioned in `GEPAState` | Static files/YAML/literals; no versioning beyond two sync SHAs |
| Eval + scores | Adapter `evaluate` over fixed train/val sets, per-instance floats | Opportunistic telemetry (`reasoning_outcomes`), certificates, PatchQuality — no fixed sets |
| Feedback for reflection | ASI: `Feedback` text per example, never-raise contract | Diagnostics exist (findings, failed checks, verdicts) but are terminal, never re-read |
| Reflection call | litellm one-shot with generic meta-prompt | `Jido.AI.generate_object/3` (Triage.LLM pattern) — ready |
| Loop host | Python `while` loop, `run_dir` checkpoints | Cron system jobs (consolidator precedent) / composer routes — stronger |
| Selection | Per-instance Pareto, frequency-weighted | `AutoSelect` aggregate success-rate bandit over a fixed strategy set |
| Budget | Metric-call + reflection-cost stoppers | Workflow-axis budget gates; no eval accounting |
| Durability/audit | Pickle + JSON logs + HTML tree | Ash/Postgres, `WorkflowEvent`, Trace — stronger |

## Bottom line

GEPA as a dependency is a non-starter, but as a *donor of contracts* it is unusually well matched: the platform already runs a cron reflection loop (memory consolidator), already scores work three different ways (certificates, PatchQuality, composer findings), already hot-reloads the exact YAML surface that makes the best first optimization target (strategy `prompts:` blocks), and already has the durable event-sourced spine GEPA fakes with pickle files. What is missing is small and nameable: an `EvalRecord` feedback contract (GP1-2), an eval-set + minibatch-gate cascade (GP1-3), a candidate store with lineage and per-instance scores (GP1-4), and the ~20-line reflection meta-prompt wired through `Jido.AI.generate_object/3` (GP1-1). Ship those four as `JidoClaw.Optimize`, prove it on one strategy's prompts against a ten-task hand-curated set behind a human deploy gate, and only then reach for the Pareto frontier (GP2-1) and merge (GP2-3) that give the approach its name.
