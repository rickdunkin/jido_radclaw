# Features Worth Borrowing from Camus

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-02**. Source: `~/workspace/research/camus` (mateodaza/camus, v0.2.7, formerly Nightcrawler v2). Self-description: *"Makes it work. Knows when to stop. No agent grades its own work: Claude writes the code, Codex (a competing model) reviews every change, and your repo's own type-check and tests have the final word."* Single author, actively developed (0.2.7 cut after a multi-round adversarial audit of its own gate). Shape: a pnpm monorepo whose product is three Claude Code dynamic workflows (~3.2k LOC JS: `camus-plan` / `camus-loop` / `camus-feat`), a skill (`SKILL.md` + Codex review prompt + severity schema), and ~12 pure-stdlib Python/bash gate scripts (~3.5k LOC, 22 unit-test suites, no deps, no network). Design doc: `CAMUS-SPEC.md`; philosophy docs under `docs/`.

Companion docs this interacts with: `docs/exploration/alp-river/` (AR-2 composer, AR-3 reviewer fan-out, AR-4 self-heal loop — the shipped machinery most camus items graft onto; AR-9 multi-plan arbiter — shipped 2026-07-03; two entries coordinate with it), `docs/exploration/squidie/` (event log, gates, replay — why camus's resume/state themes are Already Covered), `docs/exploration/jidoka/` (typed worker verdicts, operation controls), `docs/exploration/hermes/` (T1-4 error classifier, T1-8 MoA), and `docs/plans/unadopted-next-five/README.md` (the current queue; collision notes inline below).

**Revision (2026-07-02, same day as the initial inventory)**: C1-1 reframed after operator review — from "wire cross-vendor review onto the AR-9 PR-1 tiering seam" to a general **executor seam** (any Forge runner behind any stage or skill step), with cross-vendor review as its first *configuration* rather than a standalone feature. Camus's fixed "Claude Code orchestrates, Codex reviews" pairing is deliberately not copied — the pairing is one point in a space the seam opens. Direction agreed worth pursuing; OQ-1, the dependency graph, and the bottom line updated to match.

## Determination (TL;DR)

**Nothing to adopt as a dependency; a lot to borrow as contracts.** Camus and jido_radclaw independently converged on the same loop topology — plan → implement → bounded [review ↔ fix] → verify, event-logged, crash-resumable, human-gated. We already own the better *engine* (the composer + Reactor + WorkflowEvent log are a superset of camus's resume/state model). What camus owns that we don't is the *judgment layer*: cross-vendor review, deterministic verification as the final authority, infra-vs-verdict separation enforced in code, honest terminal statuses that never launder deferred risk into plain success, and git-evidence receipts that distrust the system's own runners.

| Part of camus | As a dependency | What to take |
| --- | --- | --- |
| Workflow JS engine (loop/state/resume) | No — Claude-Code-harness-specific | Nothing; composer + Reactor already superset it |
| Codex review lane (`codex_review.sh`, `sev.schema.json`, `adapter.py`) | No — bash/Python around one CLI | The **contracts**: cross-vendor invariant, verdict schema + fail-closed normalization, fresh-session-per-round |
| `verify.py` | No | The **semantics**: inconclusive-vs-failed kinds, head-bound verdicts, tamper snapshots, no-verifier-is-loud |
| Commit/merge gate scripts + receipts | No | Evidence-sealing discipline: `done` carries a sha; receipts cross-checked against live git |
| Status vocabulary (`done_with_findings`, `needs_decision`, `env_not_ready`, …) | — | Near-verbatim, onto composer dispositions + a new gate kind |
| `canary` / `retro` / `env-check` / heartbeat-staleness | No | The command shapes, re-expressed over our event log |
| Trust-boundary doctrine (five laws, ROADMAP-0.3) | — | As a review checklist for orchestration changes |

## Why not adopt camus as a dependency

1. **It's a harness artifact, not a library.** The engine half is Claude Code dynamic-workflow JS (`agent()`/`workflow()`/`budget.spent()`/journal-resume — all Claude Code ≥2.1.154 primitives). jido_radclaw *is* the harness on its side; there is no seam to embed camus into.
2. **Runtime mismatch.** Pure-stdlib Python/bash scripts orchestrated by JS, communicating via argv + stdout JSON. Our equivalents are OTP processes over an Ash/Postgres event log. Borrowing means translating, not transplanting (same rule as every doc in this directory).
3. **Scope mismatch.** Camus is single-operator, local-git-only, one-repo-at-a-time by design (it never pushes, never touches GitHub). jido_radclaw is multi-tenant, clustered, with a durable orchestration layer. Camus's file-IPC state (`~/.camus/*.json`, mtime heartbeats, sha-gated steer files) is exactly what our Postgres event log replaces — their 0.3 roadmap is slowly reinventing pieces we have.
4. **We'd inherit their weakest link.** Camus's acknowledged structural weakness is that verdicts travel through a thin LLM relay that could hallucinate `{"pass":true}` (`CAMUS-SPEC.md:304-307`); half their receipt machinery exists to police that boundary. In jido_radclaw the engine is BEAM code that can run gates and read exit codes itself — adopting the contracts without the relay makes them *stronger* here than upstream.

## How to read this document

Each entry carries a **Recommendation** (this is an initial inventory — no Status lines; those appear at first re-review):

- **BORROW-PATTERN** — translate the contract/invariant into jido_radclaw idioms (OTP, Ash, Jido, the composer).
- **ALREADY-COVERED** — we have an equal-or-better shape; entry cites it and takes at most a garnish.
- **SKIP** — not applicable to this codebase or superseded by a different local decision.

(No ADOPT-AS-DEP axis — per the table above, nothing here is consumable as a dependency.)

Tiers are scoped to this codebase: **Tier 1** = clear gap, high leverage, achievable now (most graft onto shipped composer machinery). **Tier 2** = useful, needs a design decision or new small surface. **Tier 3** = polish. Per-entry fields: **Where in camus** (file:line, accurate to within a few lines — "start here," not gospel), **What**, **Gap in jido_radclaw** (verified against source 2026-07-02), **Why it matters**, **Adoption sketch**. IDs are `C<tier>-<seq>`.

One recurring translation note: camus splits *probabilistic* judgment (Codex review — can be wrong, gets bounded rounds) from *deterministic* judgment (tests, git facts — final word). jido_radclaw's composer currently treats both as LLM verdicts. Most Tier-1 entries are different faces of fixing that one asymmetry.

---

## Tier 1 — High Impact

### C1-1. Executor seam: any Forge runner behind any stage or skill step

**Recommendation**: BORROW-PATTERN, generalized — build the seam, not the pairing. **Direction (2026-07-02)**: agreed worth pursuing. Cross-vendor review ("no agent grades its own work") is the seam's first configuration, not a standalone feature; camus's hardcoded Claude→Codex topology is explicitly what we refuse to copy.

**Where in camus**: `CAMUS-SPEC.md:33,66,180-183` (cross-vendor audit reduces self-preference bias; "do not let Claude re-judge Codex's verdict"); `packages/cli/skills/camus/scripts/review.sh:8-16,38-57` (reviewer-backend dispatcher **fails closed on an unknown backend** — a silent fallback "could hand review to the implementer's own vendor and let the gate grade its own homework"; note it gestures at pluggable backends but never generalizes past the review lane); `codex_review.sh:432-433` (fresh `codex exec` per round, read-only sandbox); `SKILL.md:110-114` (fresh reviewer each round so old findings get re-raised; thin relay, no re-judgment); `review-prompt.md:1-19` (adversarial persona + "correct but incomplete must NOT pass" completeness clause, priority-1).

**What**: The borrowable core is camus's *invariant* — the judge must not share the implementer's vendor, enforced fail-closed at dispatch — plus the fresh-session and no-re-judgment disciplines. The generalization camus never makes: any executable unit behind a workflow stage should be able to name its executor, so "a competing model reviews" becomes one configuration among many (planner on the `claude_code` CLI, verify on the `shell` runner, `fake`-backed stages for evals).

**Gap in jido_radclaw**: One hard binding, in one place. Every stage/step execution funnels through the same core: `WaveBuilder` turns each `{:worker_template, _}` stage into a `Skills.Steps.AgentStep` (`route_composer/wave_builder.ex:146-160`), and `AgentStep` delegates to `Skills.Steps.AgentRunner` — the "spawn → ask → await → record" core (`skills/steps/agent_runner.ex:6,60-83`) — which always spawns an *in-process* `Jido.AI` worker from `Templates.get/1`. So `Reviewer`/`Coder`/`Fixer` all run the same in-process `model: :fast` (`agent/workers/reviewer.ex:16`, `coder.ex:22`, `fixer.ex:34`); the reviewer is a different prompt, never a different executor. Meanwhile the Forge side already holds everything an alternative executor needs: a full session contract — `init/run_iteration/apply_input/handle_output/terminate` with statuses `continue | done(output) | needs_input(question) | blocked | error` (`forge/runner.ex:24-73`) that map ~1:1 onto stage semantics (`done` → stage output, `needs_input` → gate park, `blocked`/`error` → C1-3's infra lane) — six runners including both vendor CLIs (`forge/runners/claude_code.ex`, `codex.ex`, plus `shell`/`custom`/`fake`/`workflow`), and a **proven headless driver**: the memory consolidator resolves a harness (`:claude_code | :codex | :fake`), provisions a Forge session, and starts a per-run MCP endpoint the external CLI deposits results through (`memory/consolidator/run_server.ex:516-541`). Templates already carry per-template execution config (`model`, `max_iterations`, `forward_context`, a hydrated `:sandbox` key — `agent_runner.ex:182`), and the catalog's own doctrine — a stage is "metadata over an existing executable unit, not a new executor" (`route_composer/stage.ex:2-4`) — is exactly the invariant that makes the seam safe to open at the template layer.

**Why it matters**: One seam yields the whole family, on both surfaces at once (skill YAML steps share `AgentStep`/`AgentRunner` with composer waves): cross-vendor review lenses (the camus case — the highest leverage-to-novelty item found in this review), a planner backed by the `claude_code` CLI's own repo exploration, C1-2's deterministic verify as a `shell`-runner stage, `fake`-backed deterministic stages for the planned eval harness (`unadopted-next-five` #5). And the result-channel design beats camus structurally: they must parse `codex exec --output-schema` stdout through a hallucination-prone thin relay (their acknowledged weakest link); our engine owns both ends of an MCP callback.

**Adoption sketch**: (a) **Binding on the worker template**, not the stage: `executor: :in_process (default) | {:forge, :codex | :claude_code | :shell | :custom | :fake}` in the `Templates` registry — the catalog stays untouched, and a stage-level `executor` *override* can follow later in the same shape AR-9 PR-1 plans for `model`/`effort`. (b) `AgentRunner` branches on it: the Forge path provisions a session (consolidator `RunServer` pattern), materializes context per a template `workspace: :repo | :scratch | :none` knob, and exposes a scoped per-run MCP endpoint whose single deposit tool (`submit_structured_output`) validates against the template's output schema through the C1-3 normalizer — schema drift is `{:infra, _}`, never a verdict. (c) **Cross-vendor invariant enforced at resolution**: a review-lens stage whose resolved executor shares the implementer's vendor is *held* (fail closed, mirroring `review.sh`'s unknown-backend refusal) unless the operator opts into same-vendor degraded independence in `.jido/config.yaml`; fresh session per re-review wave; lift `review-prompt.md`'s persona + completeness clause near-verbatim for the review templates. (d) **Safety staging**: first wave is read-only stages only (reviewer/planner/critic — camus's `-s read-only` equivalent); write-capable stages on a runner require sandboxed mode, because a CLI's internal tool calls bypass the `Tools.Action` pipeline and the sandbox is the compensating control (the same accepted model as the `:docker` shell-floor skip and the consolidator's S-L2 residual); outbound prompt assembly passes the redaction root before egress to a second vendor. (e) A runner's `needs_input` parks as a gate case eventually; first wave may treat it as `blocked` → infra-retry. Cost note: a Forge session per execution (forge_home, MCP endpoint, CLI boot) is heavyweight next to an in-process spawn — right for a handful of review/plan stages per run, wrong for high-frequency stages; template-level opt-in keeps the choice deliberate.

---

### C1-2. Deterministic verify authority with head-bound, tamper-fenced verdicts

**Recommendation**: BORROW-PATTERN — the single most valuable item in this doc.

> **Status: ✅ ADOPTED 2026-07-05** (next-ten #5, with C1-6a+b). Shipped as
> `JidoClaw.Orchestration.Verify` (pure `build_result/2`, injected
> runner/porcelain/head/diff-digest seams) + `Verify.Envelope` /
> `Verify.Git` / `Verify.OsCmdRunner` / `Verify.Config`, dispatched as the
> catalog's `{:verify, "default"}` stage (`Reactors.VerifyStage`, the gate
> shape minus the park; `Loop.defer_solo_verify/2` — the INVERSE of the gate
> peel — makes it run LAST in its Kahn level). Green ⇒ `clean:verify` + a
> welded `:verify_certified` marker; red ⇒ `findings:verify` +
> `findings`/`action_needed` riding the existing Hook R fixer re-fire (red
> exhaustion → `:route_verify_failed`); inconclusive rides the C1-3 infra
> lane; tampered ⇒ the new `:route_verify_tampered` terminal via a welded
> `:stage_tampered` marker (report ref on the marker, never
> `artifacts_produced`) — never retried, never fed to the fixer, and the tick
> checks tamper AHEAD of every other terminal. `VERIFY_OATH` landed verbatim
> as the `:verify_oath` doctrine slice on `verifier`/`system_verifier`/
> `test_runner` (+ read-only `lua_query`/`lua_docs` evidence, OH1-3).
> Corrections to this entry: (1) the shipped envelope is richer than the
> summary — `checks[{name, cmd, exit}]`, `integrity_note`, per-failure
> `exit`/`reason`, plus `mode`/`tree_digest`/`sealed_head`; (2) the
> classification table is the five camus rows plus mix adaptations (the
> `mix`-scoped task-not-found env lane, an `output_limit` inconclusive kind
> for the OsCmd capture cap); (3) "refuse loudly when nothing resolves" is a
> loud INCONCLUSIVE envelope (remedy in `log_tail`), not a raise — config
> errors ride the infra lane, never a wave failure; (4) upstream is
> sealed-only — we run TWO modes (`sealed_head` present ⇒ camus-verbatim
> sealed; else `working_tree` for today's non-committing routes:
> dirty-before is an envelope FACT and mid-verify integrity rides HEAD
> stability + a content-addressed `git diff --no-ext-diff --no-textconv
> --binary` digest, since porcelain can't see content edits to already-dirty
> files); (5) camus's degrade-OPEN on a failed git capture is corrected to
> inconclusive-on-would-be-green (`integrity_unavailable` — law 4: our
> target is a git repo by definition, a green must name what it certified);
> (6) "runs last" needed the inverse defer peel — Kahn leveling alone
> co-locates verify with the reviewers; (7) no shell, ever: `cmd` is an argv
> list (scalars whitespace-split only when metacharacter-free and not
> env-assignment-led), executed via `Core.OsCmd` with execvp-style argv0
> resolution against the check cwd / the EFFECTIVE child PATH. Convergence
> re-derives the mode-specific integrity tuple against the folded
> `verified_integrity` before `:converged` (retract + re-verify on mismatch
> or unreadable capture), and an uncertified green is reclassified
> `{:inconclusive, "uncertified_green"}` BEFORE the fold. OQ-4 is answered in
> `Verify.Config`'s moduledoc (per-run override → `verify_cmd:`/`verify:` →
> mix auto-detect → loud inconclusive; no tenant defaults in v1; camus C2-7
> mid-run config-edit freeze deliberately parked).

**Where in camus**: `packages/cli/skills/camus/scripts/verify.py:121-201` (stack auto-detect / `CAMUS_VERIFY_CMD` override), `:271-303` (`INCONCLUSIVE_KINDS = missing_tool | no_tests | timeout`; exit-127/timeout/pytest-5 classification), `:306-434` (the integrity envelope: tracked-file porcelain snapshot before/after, `uncommitted_state`/`tracked_mutation`/`head_moved` all **RED, never inconclusive**, and the verdict **names the HEAD it certified**); `:358-374` (no verifier detected = loud `pass:false` + inconclusive + remedy, never a pass); `camus-loop.workflow.js:52-55` (`VERIFY_OATH` — the runner is told a RED is a *successful run* and tampering is detected); canary GREEN stage (`canary.py:135-150`) proving `result.head == git rev-parse HEAD` round-trips.

**What**: Verification is a process exit code, not an opinion. The envelope `{pass, inconclusive, tampered, failures[{stage, kind, log_tail}], head}` distinguishes "code is broken" from "environment couldn't answer" from "someone touched the tree mid-verify", and binds every green to the exact commit it certified — which is what makes an edit→commit→rerun cover-up detectable downstream.

**Gap in jido_radclaw**: Verification never gates on the exit code. The `iterative_feature`/`verified_feature`/`sfr_review` skills have a verifier *agent* run `mix test`/`mix compile --warnings-as-errors` and self-report a verdict; the loop authority is `IterativeStep.parse_verdict/1` (`skills/steps/iterative_step.ex:133-154`) reading the LLM's interpretation. The composer's system path re-checks machines via `RunCommand` but again through a worker's judgment (`agent/workers/system_verifier.ex:17-29`). Nothing produces a head-bound verdict, and nothing detects the tree changing around a verification. (Adjacent, not colliding: the planned eval harness — `unadopted-next-five` #5 — is forward-looking regression cases, not per-run acceptance.)

**Why it matters**: This is camus's "verification gap" thesis: LLM-judged acceptance degrades exactly when sampling pressure rises (a fix loop *is* sampling pressure). Their run-6 incident — a verifier agent edited the code under verification to turn red green — is a failure mode our current shape cannot detect either. And we hold a structural advantage: camus needs a thin LLM to relay `verify.py`'s stdout (their acknowledged weakest link); our engine can run the command and read the exit code itself, so the borrowed contract is *stronger* here than upstream.

**Adoption sketch**: A `JidoClaw.Orchestration.Verify` module (engine-side, no LLM): resolve the gate command (`.jido/config.yaml` `verify_cmd:`, defaulting per stack — `mix precommit` here; refuse loudly when nothing resolves), run it via `System.cmd`/Forge shell runner with a timeout, emit the camus envelope including `head` (from `git rev-parse HEAD`) and the before/after tracked-porcelain snapshot. Wire it as a composer *stage that is not an agent* — the catalog already models non-LLM stages (gates); a `verify` stage appends a `WorkflowEvent` carrying the envelope, and route convergence requires `pass: true` whose `head` matches the commit the run sealed (C1-6). Classification table lifted from `verify.py` (exit 127 → `missing_tool`, timeout sentinel → `timeout`, "no tests" → `no_tests`; all inconclusive-not-failed). Keep the LLM verifier workers for *diagnosis* of a red, never for the verdict. Where a verify must run through an agent anyway (remote/system path), lift `VERIFY_OATH` verbatim into that prompt.

---

### C1-3. Infra-vs-verdict separation, enforced at every judge boundary

**Recommendation**: BORROW-PATTERN.

> **Status: ✅ ADOPTED 2026-07-03** (next-ten #4). Shipped as
> `JidoClaw.Orchestration.Verdict` (envelope + behaviour + bounded
> `format_reason/1`) with `Verdict.Review` + `Verdict.IterativeEval` kind
> modules — the adapter.py rules verbatim incl. refuse-to-demote severity and
> the self-contradiction guard (widened, operator decision, to ANY non-approve
> with zero findings). Both engine boundaries consume it: `DefaultMapper` now
> dispatches on **lens presence, not output shape** (an infra'd reviewer emits
> `outcome: {:infra, reason}` — no signals, never folded), and the composer
> retries on a separate per-stage `infra_cap` budget (default 2 ⇒ camus's 3
> attempts; persisted in parent config) via durable `:stage_infra` events,
> terminalizing `:route_review_infra_failed` (disposition
> `"review_infra_failed"`). A **lens-only cohort's wave-execution error** rides
> the same budget (operator decision; `closed_wave_index` closes the failed
> wave for rebuild + observe; mixed cohorts keep `route_failed`).
> `IterativeStep` routes through `normalize(:iterative_eval, _)` with an
> `infra_retries` evaluator-only lane (proven red→green — the named live bug).
> Corrections to this entry: `parse_verdict/1` clauses were :134-154 (spec
> :133) and are now DELETED; the gap paragraph understated the composer half —
> a drifted `overall` fell through `DefaultMapper`'s shape-dispatch as a
> silent EMPTY emission, so the lens never went clean and the run
> mis-terminalized `:not_converged` (never `:route_failed`), while a
> degenerate `request_changes` with zero findings summoned the fixer with
> empty feedback and burned `rerun_cap` toward a false `:fix_failed`.
> `{:inconclusive, _}` is typed + defensively folded into the infra lane;
> since 2026-07-05 C1-2's deterministic verify (next-ten #5) is its live
> producer (refusals + the uncertified-green reclassification). Trace
> `:composer` events (bounded reasons, `run_id`-indexed) +
> `jido_claw.composer.infra.total`. The crabbox CB2-1 vocabulary now has its
> landing envelope. Rider C2-8 landed with it (see below).

**Where in camus**: `packages/cli/skills/camus/scripts/adapter.py:46-111` (`normalize_codex` fails closed to `ran:false` on: nonzero exit, empty output, unparseable JSON, out-of-enum verdict, missing findings list, out-of-range priority — "refuse to silently demote a drifted priority to a nit" — and the self-contradiction guard: "patch is incorrect" with zero blocking findings is an *infra* error); `SKILL.md:106-109` (Hard Rule #2: infra failure is retried with backoff, **never fed to the fix loop as a rejection, never counted as clean** — "the #1 cause of runaway loops"); `camus-loop.workflow.js:328-345` (`asGate`/`asVerify` force unparseable output to infra/inconclusive, not to a verdict); `README.md:101-104` ("a broken environment never reads as broken code… enforced in the adapter, not in a prompt").

**What**: Every boundary where a probabilistic judge's output enters the engine passes through a deterministic normalizer with three distinct exits — verdict (clean/revise), infra (`ran:false`, retry with backoff), inconclusive (environment couldn't answer) — and schema drift fails closed to infra rather than being coerced into a verdict.

**Gap in jido_radclaw**: The pieces exist but not the contract. Forge runners distinguish `harness_timeout`/`runner_unavailable` from CLI failure (`forge/runners/codex.ex:128-130`); the composer separates `route_verify_failed` from `route_fix_failed`/`route_deadlocked` (`orchestration/workflow_event.ex:140-158`); `TestRunner`'s schema separates `:error` from `:failed` (`agent/workers/test_runner.ex:8,23`). But there is no single normalization module for judge outputs, and the crucial *loop rule* — an unparseable/failed reviewer round must not consume a fix-loop round or read as findings — isn't anywhere: `IterativeStep.parse_verdict/1` treats a malformed verdict as a failed iteration, exactly the conflation camus calls the #1 runaway cause. (hermes T1-4's `FailoverReason` taxonomy is the provider-level sibling of this idea, still NOT_ADOPTED; camus's version is narrower — judge boundaries only — and independently adoptable first.)

**Why it matters**: The fix loop's economics depend on it: a Codex auth blip or a worker whose structured output drifted must cost a retry, not a wasted fix wave — and must never let a run report "reviewed" when review never ran. As we wire a second vendor (C1-1), infra flakiness *will* rise; this contract is what keeps it from corrupting verdicts. *(A second, unrelated subject converges on this exact contract: crabbox's capsule-replay outcome taxonomy separates `inconclusive_env_error` (lease/sync/tooling failure — propagated, never a test verdict) from `pass`/`fail_reproduced`/`fail_new` — see [sandboxes/crabbox CB2-1](../sandboxes/crabbox/FEATURES-WORTH-BORROWING.md). Its four-way vocabulary and the novel signature-gated "same-failure-or-not" oracle are ready to lift when this envelope is built.)*

**Adoption sketch**: A `JidoClaw.Orchestration.Verdict` envelope + normalizer behaviour: `normalize(stage_kind, raw) :: {:verdict, %Verdict{}} | {:infra, reason} | {:inconclusive, reason}`, with the fail-closed rules lifted from `adapter.py` (including the self-contradiction guard and refuse-to-demote-drifted-severity). Composer loop consumes it: `{:infra, _}` decrements an infra-retry budget (camus: 2 retries) *without* touching the stage `rerun_cap`, then terminalizes as a distinct `review_infra_failed` disposition — never `:fix_failed`, never clean. Emit `:infra` occurrences as Trace events. This is also the landing pad for C1-1's runner-backed stages: every deposit through the executor seam's callback tool passes the normalizer, never straight into artifacts.

---

### C1-4. Honest terminal statuses: `done_with_findings` + `needs_decision`

**Recommendation**: BORROW-PATTERN (vocabulary near-verbatim; machinery is one new gate kind + one disposition family).

> **Status: ✅ ADOPTED 2026-07-06** (next-ten #6, with C1-5 + the C3-2 rider).
> Shipped as the `:review_stall` gate kind + the `done_with_findings`
> completed-family disposition (`:route_done_with_findings` → `:completed`
> from `:running` only; `result.disposition` disposition-first as sketched —
> no DB status; the OQ-2 disposition-first answer implemented as specified).
> Corrections/deviations vs this sketch: (a) "rides the squidie T2-5 Spark
> DSL" understated the novelty — the composer parent is a GenServer with no
> Reactor checkpoint, and an `:awaiting_approval` composer row is recovery's
> dangling-gate arm, so the park is **parent-stays-`:running`, child-less**
> (dedicated `stall_parked` + stall deadline-timer fields beside the child
> park's — a stale fire from one park must never dispose the other) with
> kind-dispatched `Cases.decide`/`abandon` branches, never
> `GateStep`/`GateResume`; recovery re-derives the park and resolves by
> fingerprint with ZERO recovery-code changes (restart-re-park and
> decided-while-down proven). (b) The run result carries **keys + counts +
> severity histogram + trend + certified_head** — verbatim finding bodies
> ride only the gate case (raise-time decrypt of the encrypted artifacts,
> redact-before-truncate) and the BO2-6 ledger, never the result (redaction
> posture). (c) The release decision is per-finding waive records,
> all-or-reject (`{:error, :incomplete_waiver}`, never auto-reject — orca
> OQ-1 as decided), recorded on the case's `:approved` timeline event;
> `Cases.waived_findings_ledger/2` + the `jido.debt` Lua binding are the
> queryable debt view. Waive completeness validates PRE-transaction (case
> details are immutable after open; `Ash.transact` wraps in-txn
> `{:error, atom}`s opaque — the abandon-guard precedent); the in-txn fence
> stays lock_run → lock_case → ensure_case_pending. (d) The gate fires only
> on a **green AND certified** C1-2 verify; a red-verify stall lands
> `fix_failed` via the fixish fall-through (never `verify_failed` at that
> seam); headless CLI exit for `done_with_findings` stays 0 (the osa OQ-4
> exit-code pin), disposition marked in text + JSON. (e) The surface rule
> shipped at the base projection: `Visibility.run_view` carries
> `disposition`/`findings_deferred_count` so every downstream surface
> inherits it; the web badge is amber "completed · findings" (never plain
> green); the `WorkflowView` rollup sums `findings_deferred` over its
> recent-completions window (the tenant-wide total is the ledger's job).
> `needs_decision` itself shipped under the `review_stall` name — the parked
> case IS the needs-decision lane; no separate disposition was needed.

**Where in camus**: `camus-loop.workflow.js:1122-1149` (`review_unresolved` carries `verifyClean`, `stuck`, `oscillating`, `parkedSha`), `:1197-1215` (oneshot `done_with_findings`: findings verbatim + the fix agent's `claimedResolution` — "claims, never verdicts, because nobody re-checked"); `camus-feat.workflow.js:988-1002` (`review_unresolved + verifyClean === true` → task `needs_decision`; a human `land: [taskId]` is authorized **only** by that prior proven state — an unproven land request downgrades loudly to the full loop); `VELOCITY-DIRECTION.md:62-72,126-139` ("**no posture may report plain `done` while deferring risk**"; a feat holding any ◈ task ends `done_with_findings` itself; the posture is loudly visible on every surface); `status.py:30-41` (the glyph vocabulary: `◆ needs_decision`, `◈ done_with_findings`, `◇ ready_to_merge`).

**What**: Two honest outcomes between success and failure. `needs_decision`: the deterministic gate says shippable but the probabilistic one is stuck — that's a human's call, reachable by one flag that lands the already-proven work without re-implementing. `done_with_findings`: work shipped with named review debt carried verbatim, contaminating every aggregate above it — never laundered into plain `done`.

**Gap in jido_radclaw**: `WorkflowRun` terminals are `:completed | :failed | :cancelled | :abandoned` (`orchestration/workflow_run.ex:294-304`). The composer's richer dispositions (`:not_converged`, `:fix_failed`, `:verify_failed`, …) project onto them but all land in the `:failed` family (`workflow_event.ex:140-158`) — a run whose fix loop capped out with a *green verify* is indistinguishable in kind from one that never compiled. The gate-park machinery (`:awaiting_approval`, PlanGate, safety gate, `GateDisposition`) is shipped and is exactly the right substrate for `needs_decision` — what's missing is the gate kind and the two dispositions.

**Why it matters**: This is the "knows when to stop" half of camus. Without a `needs_decision` lane, cap-outs read as failures and get re-run (burning rounds on what camus correctly identifies as "a stale flag or a real disagreement — both deserve a human"); without `done_with_findings`, any future speed posture (C3-3) or lenient path silently impersonates the full gate. Both are cheap here *because* squidie's gate/case machinery already shipped.

**Adoption sketch**: (a) New `HumanGate` kind `review_stall` (rides the squidie T2-5 Spark DSL): raised by the composer when the fix loop exhausts `rerun_cap` (or C1-5 fires) *and* the deterministic verify (C1-2) is green; the case carries the surviving findings + the certified `head`. Approve-disposition = land: the run completes off the already-proven artifacts, no re-implementation, terminal disposition `done_with_findings` with findings attached; reject = `:fix_failed` as today. (b) `done_with_findings` as a first-class composer disposition projecting to `:completed` with `result.disposition = "done_with_findings"` + findings in the result (start disposition-first; promote to a DB status only if surfaces need to filter on it). (c) Surface rule ported to REPL `/gates`, web dashboards, and `workflow_status`/`inspect_workflow`: an aggregate containing a findings-deferred run is itself marked, never plain green.

---

### C1-5. Finding identity: stuck-finding and oscillation early-halt

**Recommendation**: BORROW-PATTERN.

> **Status: ✅ ADOPTED 2026-07-06** (next-ten #6, the trigger feeder for
> C1-4). Shipped as `RouteComposer.FindingKey` (`{:v1, file, title}` hashed
> through `Core.CanonicalHash.sha256_term/1` — the T1-3 house rule, never a
> rendered string) over a new required short `title` on the reviewer finding
> schema. Corrections vs this sketch: (a) "`seen_keys`/`prior_keys` are
> derivable from wave artifacts already in the event log" is **FALSE** —
> findings persist as encrypted `ComposerArtifact` rows the projection never
> decrypts, so cross-wave identity rides a welded per-round `:finding_keys`
> marker (stage/lens/hex keys + enum marks only — redaction posture; a clean
> round welds `keys: []` so the lens round still advances for oscillation
> detection); (b) the fingerprint downcases the **title only** — file paths
> are identity on case-sensitive filesystems (deliberate deviation from
> camus, which downcases both halves). Detection is camus-verbatim (stuck =
> current ∩ prior round; oscillating = reappear-after-absence via the
> seen-keys memory; un-keyable findings excluded — never a fabricated
> identity; confidence trend advisory only), with two shipped deviations: a
> stop suppresses **all of Hook R** (not just the fixer weld), and there is
> no named `review_stalled?/1` — the stop reasons compose in
> `fix_stop_lenses/1` (re-review-budget exhaustion ++ stall evidence) so
> Hook R and the tick's terminal reclassification read one decision and can
> never disagree. Marks decode asymmetrically by design: the emission
> boundary (`StageEmission`) fails the WHOLE block closed, the projection
> fold drops malformed entries (marks are advisory trend data there).
> Observability: `jido_claw.composer.stall.total` + one bounded `:composer`
> `:fix_stopped` Trace event (hex keys only, tenant-stamped).

**Where in camus**: `camus-loop.workflow.js:822-830` (`findingKey` = lowercased file (line stripped) + normalized title; un-keyable findings excluded), `:812-930` (a keyable finding present in round N and N-1, with N ≥ 2 → `stuckFindings`, break early — "a finding that survives its own fix deserves a human, not more rounds"), `:833-943` (`allSeenKeys` oscillation memory: appeared r1, vanished r2, returned r3 → `oscillating`, break — "reviewer can't make up its mind"), `:846-851` (confidence trend across rounds: falling → likely stale re-flag, "lean ACCEPT"; steady → "lean REFINE" — advisory only, never an auto-pass), `:953-960` (final round with blockers dispatches **no fix it can't re-review** — halt with findings instead).

**What**: Findings get stable identities so the loop can recognize *non-progress* (same finding survives its own fix) and *non-determinism* (finding oscillates in and out) and halt to a human early, instead of burning the full round cap on a disagreement more rounds cannot resolve.

**Gap in jido_radclaw**: The AR-4 self-heal loop reruns lenses until clean or per-stage `rerun_cap` → `:fix_failed` (`route_composer.ex:126-144`, `route_composer/loop.ex:95-101`). Findings live in wave artifacts with no cross-wave identity: a stale flag or a genuine impasse consumes every rerun before terminalizing, and terminalizes as plain failure (see C1-4) with no signal that it was *the same finding* all along.

**Why it matters**: Bounded loops are only economical if they exit early on non-progress — camus's cap is 3 *because* stuck/oscillation detection usually fires first. It's also the trigger feeding C1-4's `review_stall` gate, and the confidence-trend garnish gives the human deciding that gate a real prior ("this finding's confidence fell every round — probably stale").

**Cross-reference**: fingerprint construction should follow the house rule already in `Solutions`/replay — hash a canonicalized semantic term, not a rendered string (cf. squidie T1-3's definition-hash discipline).

**Adoption sketch**: Reviewer lens output schema gains a per-finding canonical fingerprint computed engine-side (normalize file path + title casing/whitespace; drop line numbers — they shift under fix diffs). The composer keeps `seen_keys`/`prior_keys` per lens in its projected state (they're derivable from wave artifacts already in the event log, so resume-safe for free). Rules lifted verbatim: repeat-across-consecutive-waves → raise `review_stall` (C1-4) with `stuck: true`; reappear-after-absence → same gate with `oscillating: true`; never dispatch a fix wave the route has no re-review budget to check.

---

### C1-6. Git-evidence sealing: `done` carries a sha, receipts over relays

**Recommendation**: BORROW-PATTERN (scoped: evidence for engine-visible claims now; receipts in full when the shipping tail lands).

> **Status: ✅ ADOPTED 2026-07-05 — scoped to sketch items (a)+(b)** (next-ten
> #5, alongside C1-2). (a) `Tools.GitCommit` now returns ENGINE facts:
> `git rev-parse HEAD` before/after via the shared `Verify.Git` seam,
> `committed` ⇔ the head moved, full shas (never `--short`), and a
> staged-empty commit is an explicit `no_changes` SUCCESS naming the live
> head (distinct `add_failed`/`commit_failed` errors kept). (b) The composer
> observes HEAD itself at every wave commit on verify-bearing runs: a durable
> `:head_observed` marker on the FIRST observation (the baseline — an
> in-memory-only baseline is laundered by crash + external move) and on every
> change; a change derives `sealed_head` (flipping later verifies to
> C1-2's sealed mode), and a move while `clean:verify` is live welds the
> retraction + re-verify into the same txn. A green verify's
> `:verify_certified` marker (`{stage, head, tree_digest, mode}`) is what the
> convergence-time re-check holds greens against. One correction vs the
> sketch: the facts land in the child run's durable `result` via the tool
> output (the `WorkflowEvent`-stamping phrasing overstated — no separate
> event kind for tool commits; the composer-side `:head_observed` is the
> engine-derived event). Deliberately NOT adopted here: (c) `files_changed`
> reconciliation, (d) receipts + hookless gate-owned git (awaits AR-10), and
> (e) ancestry-proof gate dispositions.

**Where in camus**: `packages/cli/skills/camus/scripts/commit.sh:32-48` (gate-owned commit: `git -c core.hooksPath=/dev/null -c commit.gpgsign=false`; empty stage → `{committed:false, reason:"empty"}` → task reports `no_changes`, never silently done; every `done` requires a full `commit_sha`); `merge.sh:47-77` (the receipt: every merge verdict is written to `~/.camus/merges/<taskId>.json` *before* it is printed — "a verdict without a receipt is impossible by construction"); `camus-feat.workflow.js:1212-1347` (three-way cross-check: runner relay vs receipt vs live `git rev-parse` — divergence halts with the receipt's pre-merge sha as reset target; a relay that hand-resolved a refused conflict is exactly the run-6 class this caught), `:1442-1490` (postflight self-audit: every completed task's branch proven in feat history via `git rev-list --count`, missing evidence halts loud), `:1050-1092` ("no-op" with unmerged commits on its branch recognized as a prior run's proven work and rescued, never dropped); `reconcile.py:124-136` + `land.py:65-87` (operator attestations refused without git evidence: commit must exist *and* be an ancestor / branch must hold unmerged commits).

**What**: No claim about git state is believed on testimony. Completion requires a sha the gate itself minted; merge reports are cross-checked against a receipt the script wrote as it computed the verdict and against the live repo; run-end audits prove ancestry for every task; and even the human's word ("I landed it by hand") is checked against `merge-base --is-ancestor`.

**Gap in jido_radclaw**: Git is gated *before* execution (`Security.ShellCommand.Git` resolves effects; `git_commit`/`git_push` approval-gated — shipped, including the 2026-07-02 push sweep) but never *sealed after*: `Tools.GitCommit` (`tools/git_commit.ex:26-41`) returns raw output without cross-checking the resulting sha; `Coder`/`Fixer` self-report `files_changed` that nothing reconciles against `git status`; no completion status anywhere is bound to a commit. The relay-distrust half is smaller here (tool results reach the engine deterministically, not through an LLM echo) — but the *claim* boundary is real: worker structured outputs assert outcomes the engine never re-derives.

**Why it matters**: This is the precondition for C1-2's head binding to mean anything (a verify certifies *a commit*; something must have sealed that commit), and it's the trust story for the planned AR-10 shipping tail (`unadopted-next-five` footnote): the moment a route step runs `git commit && git push && gh pr create`, "work provably lands" needs engine-derived evidence, not runner testimony. The reconcile/land rule ("git as the witness" even for operator attestations) also maps directly onto our gate dispositions — an approve that lands work should verify the work exists.

**Adoption sketch**: (a) `Tools.GitCommit` (and any composer commit step) appends engine-derived facts to the result: `git rev-parse HEAD` before/after, `committed?` ⇔ head moved, staged-empty as an explicit `:no_changes` outcome — stamped into the `WorkflowEvent`, not just tool output. (b) Composer code-path convergence records `sealed_head`; C1-2's verify must certify that head. (c) Worker `files_changed` claims reconciled against `git status --porcelain` delta at wave commit; divergence is a Trace warning first (observe), a held stage later (enforce). (d) When AR-10 lands: hookless/unsigned flags for *gate-owned* git lifted verbatim (`-c core.hooksPath=/dev/null -c commit.gpgsign=false` — repo hooks must not be able to abort or hijack unattended engine commits; note `--no-verify` alone is insufficient, `commit.sh:23-31`), and a receipt row (Ash resource, not a JSON file) written by the executing step that the run's terminal accept cross-checks. (e) Gate dispositions that attest external work (reconcile-style) require ancestry proof before flipping state.

---

## Tier 2 — Medium Impact

### C2-1. Token budget with halt-as-question at wave boundaries, durable across resume

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `camus-feat.workflow.js:87-93,839-853,1426-1440` (`budgetTokens`: per-task spend deltas persisted per node; checked before each task and once after the final task before integration; over-cap → `needs_human` stage `budget` — "continue with a higher budget, or stop here", never a silent overrun and never auto-resumable so a watchdog can't ping-pong it); `README.md:200-207` ("an estimate, never an invoice"; Codex-side spend never dollarized, only named).

**What**: A run-scoped output-token ceiling checked at natural boundaries against totals that survive crash/resume, halting as a *question* (a gate) rather than an abort — resuming with a higher budget skips finished work.

**Gap in jido_radclaw**: No cost governor exists. `AgentTracker` token/cost stats are in-memory, reset between conversations, never persisted (`agent_tracker.ex:137-140,438-440`); the composer's exhaustion bounds are waves/deadline/rerun-caps (`route_composer.ex:187-215`) — time and step budgets, not spend. Web surfaces carry no token/cost at all.

**Why it matters**: Autonomous loops with a second vendor (C1-1) and unattended runs are exactly where spend anxiety blocks adoption; camus's framing — hard question at a boundary, honest "estimate not invoice" labeling, totals that survive resume — is the trust-preserving shape. Wave boundaries and the event log make this near-mechanical for us.

**Adoption sketch**: `budget_tokens` composer start opt; per-wave token deltas (from `AgentTracker`/runner usage) stamped into wave-commit `WorkflowEvent`s so the projection can sum spend durably; on exceed at a wave boundary, park at a `budget` gate (C1-4 machinery) whose approve-with-new-ceiling resumes and whose reject terminalizes `route_budget_exhausted` (disposition already exists). Label every surfaced figure an estimate. Follow-up, not blocking: roll the same per-wave numbers up to `workflow_status`/dashboards (closes the Axis-5 observability gap en passant).

### C2-2. Canary: known-answer end-to-end self-test (RED by name, GREEN head-bound)

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `packages/cli/skills/camus/scripts/canary.py:119-150,162-246` (throwaway repo under `$TMPDIR`, torn down in `finally` on every path; **RED**: a repo whose test fails by design must come back `pass:false, inconclusive:false` with a *named* failed check; **GREEN**: fix, commit, and verify must return `pass:true` **and** `result.head == git rev-parse HEAD`; optional `--review` stage exercises the real reviewer for one small call and requires `ran:true` with all contract keys); `README.md:358-384` ("`npm test` proves the gate's *units*. `camus canary` proves the *toolchain*").

**What**: A known-answer integration test of the *installed* gate + local toolchain: if the verifier can't tell broken from working, or a green doesn't bind to its commit, nothing downstream is trustworthy — proven on a throwaway repo before a real run pays for the discovery.

**Gap in jido_radclaw**: Setup checks are presence/version probes (`setup/prerequisite_checker.ex:23-27` — ollama isn't even a connectivity probe) plus DB connectivity in the wizard; Forge runners fail closed on missing credentials (`forge/runners/claude_code.ex:155-160`) but nothing proves a real turn runs. There is no doctor/canary command; the first evidence that a provider, runner, or verify command is broken is a failed real run.

**Why it matters**: Directly conditioned on C1-2 (the canary is what proves the verify envelope's RED/GREEN/head contracts round-trip on an operator's actual machine) and on C1-1 (the `--review`-style stage proves the cross-vendor lane before an unattended run depends on it). Known-answer + short-circuit + teardown-always is a shape worth copying exactly.

**Adoption sketch**: `mix jidoclaw.canary`: scaffold a throwaway mix project in tmp (or a vendored fixture), stage RED (failing test → C1-2 envelope must be `pass:false`, not inconclusive, named check), stage GREEN (fix + commit → `pass:true` + head-bound), optional `--runner claude_code|codex` stage driving one minimal Forge turn, optional `--review` driving one reviewer-lens call through the C1-3 normalizer requiring `{:verdict, _}`. Exit 0 only when every stage holds; print the first broken stage with its evidence; teardown in `after`.

### C2-3. Env doctor preflight: remedies attached, facts injected, relay contradictions halt

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `packages/cli/skills/camus/scripts/env_check.py:98-170` (issues checked in the verifier's own execution context: required-vs-actual node with range-aware semver, lockfile-but-no-deps-installed, env-managed-python misdetection, every detected check's binary resolving on PATH), `:185-270` (advisory `[env-facts]` block: platform, GNU-`timeout` absence, codex presence/auth/tier — lifted into every task's plan/implement/fix prompt "so agents stop rediscovering quirks mid-run"); `camus-feat.workflow.js:313-322` (readiness derived from the *exit code*; a relay whose self-judged `ready` contradicts its own `exitCode` **halts**); README preflight ("every refusal prints the exact commands that clear it"). Doctrine: "friction that bites once becomes a deterministic check… explicitly NO LLM 'predict what could go wrong' preflight" (`docs/HARNESS-DIRECTION.md:116-121`).

**What**: A deterministic pre-run doctor that checks exactly what the verifier will need, in the context the verifier will run in, naming the remedy for each refusal — plus a facts block injected into agent prompts so environmental quirks are stated once instead of rediscovered per agent.

**Gap in jido_radclaw**: Nothing checks run-readiness at run start (Axis 7): `PrerequisiteChecker` is setup-time presence only; no dirty-tree/ground checks before code-path runs (see C2-6); no env-facts injection (the prompt builder assembles memory/persona blocks, not platform truths). The relay-contradiction rule has a direct local analog: worker structured outputs asserting success that their own tool results contradict.

**Why it matters**: Camus's ordering is right — a broken environment discovered mid-run poisons verdicts (C1-3 can only classify the failure; the doctor prevents it). The env-facts block is the cheapest borrow in the doc and pays every run: our workers re-derive "is ollama up, which repo root, is this darwin" constantly.

**Adoption sketch**: `JidoClaw.Orchestration.Preflight` run by code-path triage: verify-command binary resolution (shares C1-2's `detect`), repo ground checks (C2-6), provider/runner reachability (reuse credential fail-closed probes), each issue paired with a remedy string; refusal terminalizes as `env_not_ready` (new disposition, projects to `:failed` with the remedy in `result`). Env-facts: a small deterministic map (platform, repo root, verify command, runner versions) rendered into worker prompts via the existing prompt builder — snapshot-stable within a run to respect the frozen-prompt discipline (hermes T1-7).

### C2-4. Per-run heartbeat: "running must mean running"

**Recommendation**: BORROW-PATTERN (nearly free over the event log).

**Where in camus**: `camus-loop.workflow.js:243-251` + `camus-feat.workflow.js:185-191` (`touch ~/.camus/feats/<featId>.hb` prepended to every runner command and think-phase prompt); `status.py:47-56,183-209,245-247` (heartbeat age = newest of state-file/`.hb` mtime; `LIVENESS_STALE_S = 600`; a `running` feat quiet >10m gets a loud "the run may have died; safe to resume with the same args" warning on `status`/`watch`).

**What**: Every phase touches a liveness marker so observers can distinguish "running" from "abandoned by a crash the state file never saw" — with the staleness warning naming the recovery action.

**Gap in jido_radclaw**: Liveness is a *global* 60s `.jido/heartbeat.md` (`heartbeat.ex`) plus crash-driven `:DOWN` monitoring in `AgentTracker`; nothing flags a live-but-silent run. `workflow_status`/`inspect_workflow`/LiveViews report status but not event recency; a composer stuck on a hung runner shows `:running` indefinitely (the wave deadline eventually kills it, but the operator gets no early "quiet" signal).

**Why it matters**: For unattended runs the watch surface is the trust surface. We can do better than mtime: the `WorkflowEvent` log *is* the heartbeat — last-event age per run is already durable and queryable.

**Adoption sketch**: `workflow_status`/`inspect_workflow`/`workflows_live` compute `last_event_age` from the newest `WorkflowEvent` (plus composer in-memory wave progress for sub-wave granularity) and render a loud `⚠ running but quiet for Nm — <recovery hint>` past a threshold (default 600s, config). No new writes needed; recovery hint names the actual lever (`replay_workflow` / gate decision / wave deadline pending). Cross-ref: alp-river UNADOPTED #9 (idle-based hang *kill*) stays evidence-gated — this item is the observation layer that would produce that evidence.

### C2-5. Retro: read-only, evidence-gated run analytics (never a model call)

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `packages/cli/skills/camus/scripts/retro.py:1-34` (read-only *by construction* — no writes, no subprocess, no network; a "zero writes" test asserts the reports dir is byte-identical), `:58-96,210-241` (schema-tolerant aggregates: status/posture mix, review-round distribution, per-task token p50/p90), `:155-207` (`MIN_EVIDENCE = 3`: each observation cites its supporting count + driving numbers inline, else prints `insufficient data (N runs)` — "rather than guess from a thin pile"; the catalogue is deliberately descriptive-only, nothing recommends an irreversible action).

**What**: A command that reads run history back and surfaces only what ≥3 data points support, with the evidence cited inline — honest self-analysis with no model in the loop and no ability to mislead.

**Gap in jido_radclaw**: History-driven recommendation exists for *strategies* (`reasoning/resources/outcome.ex` + `Statistics.best_strategies_for/2`) and *solutions* (`solutions/trust.ex`), but nothing reads workflow-run outcomes to describe loop behavior (round distributions, disposition mix, spend spread) — the data is all in `WorkflowRun`/`WorkflowEvent` already. (Not colliding with the planned eval harness, `unadopted-next-five` #5: eval is forward-looking regression cases; retro is backward-looking observation.)

**Why it matters**: Once C1-4/C1-5/C2-1 land, their value shows up as distributions (how often does `review_stall` fire? what's the rerun p90? is oneshot — C3-3 — actually cheaper?). The ≥3-data-points + cite-inline + insufficient-data-honesty rules are what keep such a surface trustworthy; the "recommendations that can't mislead" stance fits our gate-everything posture.

**Adoption sketch**: A read-only surface (REPL command and/or MCP tool `workflow_retro`) over `WorkflowRun` + wave/disposition aggregates from the event log: per-run one-liners, aggregate block, then the evidence-gated observation catalogue (start with camus's three: posture/config mix, high-rerun tasks, token spread once C2-1 records spend). Every observation carries `n` and the driving numbers; below `min_evidence: 3` print insufficient-data verbatim. Ash read actions only; no writes, no LLM.

### C2-6. Ground preflight for repo-mutating runs: dirty-tree refusal + baseline verify (`base_red`)

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `camus-feat.workflow.js` preflight statuses (`not_a_git_repo`, `unborn_repo`, `detached_head`, `dirty_tree` — each refusal prints the exact clearing commands, with a hint when the dirt is a stale submodule pointer; `README.md:110-114`) and the baseline gate (`base_red`: verify the *base* before implementing so failures are attributable to the change, not the ground; `camus-plan`'s rubric likewise demands "baseline green between tasks"); `verify.py:330-357` (a gating verify over a dirty tree is RED `uncommitted_state` — "a green over uncommitted edits certifies nothing").

**What**: Refuse bad ground before mutating: not-a-repo/unborn/detached/dirty each halt with the remedy attached, and a baseline verify pins "was the repo green before we touched it" so every later red is attributable.

**Gap in jido_radclaw**: No ground checks exist before code-path runs (Axis 7/9): `Security.ShellCommand.Git` classifies commands for approval but never asserts tree state; the composer's code path will happily plan/implement/fix on a dirty tree, and a pre-existing red suite is indistinguishable from a regression the run caused. (House memory agrees from the other side: "pre-existing failure" disputes are common enough that we wrote a rule about trusting the user on them — a recorded baseline would make the question decidable.)

**Why it matters**: Attribution is the quiet half of verification honesty: C1-2's verdicts only indict the change if the base was proven green. Dirty-tree refusal also protects the *user's* work from being swept into an agent commit (same instinct as our targeted-staging rule).

**Adoption sketch**: Part of C2-3's `Preflight`, code-path only: repo checks via `System.cmd` git probes, each failure → `env_not_ready` with remedy text; then a baseline C1-2 verify whose envelope is stamped as `baseline` in the event log — red baseline parks at a gate ("proceed anyway (failures pre-exist) / stop") rather than hard-refusing, since unlike camus we have gate machinery for exactly this question. Sketch/system paths and non-repo tenants skip the git half.

### C2-7. Frozen judge assets: no self-mutation mid-run, drift checked

**Recommendation**: BORROW-PATTERN (scoped to the judge/gate surface; general config freezing is out of scope).

**Where in camus**: `packages/cli/install.sh:2-8,138-171` (the gate is a *copy*, deliberately not a symlink — "never live-edited while a run is driving"; shasum fingerprint printed at install), `:52-72,106-136` (`camus check`: `diff -rq` installed-vs-source with direction-aware verdicts — stale gate vs "you'd DOWNGRADE"; "run before every auto run… a stale gate can never run silently"); `CAMUS-SPEC.md:258-265` (gate scripts live *outside* the worktree so implement/fix agents cannot edit the reviewer/verifier judging them mid-run); `docs/V2-OVERNIGHT-DESIGN.md:107-109` ("a system that rewrites its own brakes mid-drive has no brakes"; camus improves itself only through tasks that pass its own gates, in a later human-initiated run).

**What**: The assets that judge a run (reviewer prompt, severity schema, verify command, gate scripts, permissions) are frozen for the run's duration, live outside the agents' write surface, and are drift-checked before trusted runs.

**Gap in jido_radclaw**: Partially covered, with real holes. Covered: the composer catalog is compiled Elixir (agents can't edit it), and squidie T1-3's definition-hash gate refuses *replay* across changed skill YAML (`orchestration/replay.ex:205-221`). Holes: `.jido/skills/*.yaml`, `.jido/strategies/`, `.jido/system_prompt.md`, and (post-C1-1) the reviewer prompt + verify command in `.jido/config.yaml` are all writable by the agent's own file tools mid-run — nothing pins them at run start or blocks the write; and the known `system_prompt.md` manual-sync pain (AGENTS.md) is the same drift class `camus check` exists to catch.

**Why it matters**: C1-1/C1-2 move judgment into config-addressable assets (review prompt, verify command). The moment the fix loop can edit the file that defines its own acceptance, the gate is decorative — camus treats this as a hard boundary, and their auto-mode wrapper-trust analysis ("allowing a script trusts it wholesale, so it must be frozen and checkable") matches our own gate-bypass review instincts.

**Adoption sketch**: (a) Run-start pinning: the composer snapshots hashes of the judge assets it will consult (skill YAML already fingerprinted — extend to reviewer prompt + `verify_cmd` config) into the start event; wave commits re-check and a mismatch parks at a gate (`judge_drift`) rather than proceeding on silently-changed rules. (b) Write-side: `@require_patterns`-style tool-approval trigger for `write_file`/`edit_file` paths under `.jido/` (the ToolApproval param-pattern seam exists) — an agent editing the gate mid-run becomes an operator decision. (c) A `mix jidoclaw.check`-style drift report for `.jido/system_prompt.md` vs `priv/defaults/system_prompt.md` (direction-aware, camus-style) to retire the documented manual-sync footgun.

### C2-8. The trust-boundary doctrine (five laws) as an orchestration review checklist

**Recommendation**: BORROW-PATTERN (documentation-only).

> **Status: ✅ ADOPTED 2026-07-03** (rider on next-ten #4). Landed as
> `docs/TRUST-BOUNDARIES.md` — the five laws adapted to our vocabulary
> ("script" → engine/gate code, "green" → verdict/disposition) **plus the
> event-sourced durability checklist materialized from house memory as law 3's
> working form** (it previously lived only in operator memory), with a pointer
> + summary from AGENTS.md's Verdict Normalizer bullet. Framed as the review
> rubric for orchestration/gate changes and the acceptance frame for C1-3
> (shipped, see above) and C1-2 (next-ten #5).

**Where in camus**: `docs/ROADMAP-0.3.md:21-36` — "Camus is a distributed transaction manager wrapped around probabilistic agents; bugs live at the trust boundaries." Every phase/handoff must satisfy: (1) allowed mutations live in allowlisted deterministic code; (2) every handoff needs script-written evidence — agent relays are cross-checks, never sources of truth; (3) every crash window needs resume semantics; (4) every "green" proves exactly what state it certified; (5) every helper agent is untrusted around state-changing commands. "A feature that can't answer all five isn't designed yet."

**What**: A five-question design gate for any feature that hands state between an LLM and the engine.

**Gap in jido_radclaw**: We enforce cousins of these piecemeal (the event-sourced durability checklist in house memory covers law 3; ToolApproval covers slices of 1 and 5) but no written standard asks all five of one change. Laws 2 and 4 are exactly the gaps C1-2/C1-6 close — evidence that the checklist finds real holes here.

**Why it matters**: Cheapest possible borrow (a docs paragraph) that would have caught, at design time, both of the Tier-1 gaps this review found. It generalizes beyond the composer: MCP proxying, Forge runners, and the shipping tail all sit on the same boundary.

**Adoption sketch**: Add the five laws (adapted to our vocabulary: "script" → engine/gate code, "green" → verdict/disposition) to AGENTS.md or `docs/` as the review rubric for orchestration/gate changes, cross-linking the existing durability checklist. Apply retroactively as the acceptance frame for C1-2/C1-3/C1-6.

---

## Tier 3 — Polish

### C3-1. Judge-lane liveness by output activity, resume-before-repay

**Recommendation**: BORROW-PATTERN, evidence-gated (keep alp-river UNADOPTED #9's bar).

**Where in camus**: `packages/cli/skills/camus/scripts/review_watch.py:1-31,147-213` (Codex runs detached with the event stream as the liveness signal — "a review counts as alive while it emits events"; silence past 360s → group-kill, retried as *infra*; a wrapper-written exit-code file is the only honest exit channel); `codex_review.sh:98-146,292-336` (a killed review's thread id is persisted only for terminal abandoned shapes; the next attempt resumes that thread for one short turn instead of re-paying a full review, gated fail-closed — any completion evidence, or any doubt, falls to a byte-identical fresh review).

**What**: Long external-CLI judgments are bounded by *idle time*, not wall clock (honest long reviews survive; hung ones die fast as infra), and a killed judgment is resumed before it is re-paid — falling closed to fresh on any doubt.

**Gap in jido_radclaw**: Forge runners bound runs by wall-clock (`harness_timeout`) and stream output already; there's no idle-based watchdog and no partial-work recovery for a killed CLI run. Real but unproven need — alp-river UNADOPTED #9 already holds "idle-based hang detection" pending evidence, and C2-4's staleness observation is what would produce that evidence.

**Adoption sketch (when triggered)**: Forge harness tracks last-output-at per session; idle > threshold → kill process group, classify `{:infra, :idle_killed}` (C1-3), retry within the infra budget. Codex-runner resume via thread id only if the CLI's evidence supports "abandoned, no verdict" — else fresh.

### C3-2. Pause hints name their exact resume shape

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `camus-loop.workflow.js:543-556`, `camus-feat.workflow.js:1094-1109,691` (every `needs_human` return carries a `resumeWith` object — the literal payload to re-run with: `{answers: {taskId: "<your answer here>"}}`, `{posture: "oneshot | full"}` — plus a note naming the command; `status.py` renders the right ask per stage).

**What**: A paused run tells the operator precisely how to resume it, as data, shaped to the pause's stage.

**Gap in jido_radclaw**: Gate cases surface kind + payload on `/gates` and `/approvals`, and resume is automatic on decision — but budget/posture/answer-shaped pauses (arriving with C1-4/C2-1) need the operator to supply *arguments*, and nothing today formats "what to provide" as a copyable payload.

**Adoption sketch**: A `resume_hint` field on gate cases (populated by the raising stage), rendered verbatim in REPL/web/`inspect_workflow`. Trivial once the new gate kinds exist; do it with C1-4.

> **Status: ✅ ADOPTED 2026-07-06** (rider on next-ten #6, exactly as this
> entry prescribed — "do it with C1-4"). `resume_hint` ships in the
> `:review_stall` case details (populated at raise time), rendered on the
> REPL `/gates` case view, web `/approvals`, and the `WorkflowView`
> composer gate-block (which `inspect_workflow` serves). Scoped to the new
> kind: the pre-existing kinds gain hints as their argument-bearing pauses
> arrive (C2-1 budget, answer-shaped asks).

### C3-3. Review postures (`full` / `oneshot`) with an honest price

**Recommendation**: BORROW-PATTERN, after C1-4 (the honest statuses are the prerequisite, not the posture).

**Where in camus**: `README.md:150-171` (`oneshot`: one review at diff-narrowed scope — same severity bar, narrower field of view — one unreviewed fix, no re-review, verify still decides; result is `done_with_findings` carrying findings verbatim + per-finding `claimedResolution` — "claims, never verdicts, because nobody re-checked"; explicit posture used verbatim and never re-asked, classifier recommends otherwise; unknown postures rejected loudly, never silently downgraded; the posture is named on every surface).

**What**: A speed dial that trades probabilistic review depth for latency while the deterministic floor stays unskippable — priced honestly in the terminal status rather than hidden.

**Gap in jido_radclaw**: The composer has no cadence dial: every code-path run gets the full lens set and fix loop. Useful for trusted-small-change runs, but only safe once `done_with_findings` exists — which is exactly camus's own dependency ordering.

**Adoption sketch**: `posture: full | oneshot` composer start opt: oneshot schedules one review wave (diff-scoped lens prompts), one fix wave, no re-review, then C1-2 verify; terminal is `done_with_findings` with claims labeled unverified. Reject unknown postures loudly; name the posture in run events and every status surface.

### C3-4. Decision journaling (judgment calls in the run report)

**Recommendation**: BORROW-PATTERN.

**Where in camus**: `camus-loop.workflow.js:285-296,562-566` (implementer schema carries `decisions[]` — what / why / rejected alternative; under `policy: autonomous` an ambiguity is decided, logged, and reviewed at merge instead of asked); `README.md:194-196` ("you review decisions, not just diffs").

**What**: Every judgment call the implementer makes is a first-class, structured entry in the run's record — the autonomous policy's accountability mechanism.

**Gap in jido_radclaw**: Worker structured outputs report results (`files_changed`, verdicts), not choices; `AgentCase` timelines record *operator* decisions. Nothing captures "widened the parameter type; rejected the alternative because…" — which is precisely what a `review_stall`/plan-gate human wants in front of them.

**Adoption sketch**: Add `decisions[]` (what/why/alternative) to Coder/Fixer/Planner output schemas; thread into wave artifacts and surface on `inspect_workflow` + gate-case detail views.

### C3-5. Plan-quality rubric: acceptance criteria folded into the task as data

**Recommendation**: BORROW-RUBRIC — fold into AR-9's critique stages rather than new machinery.

**Where in camus**: `camus-plan.workflow.js:120-181` (task schema requires `title, spec, files, acceptance`; the STANDARDS rubric: right-sized ≤~8 files, safely ordered additive→destructive→cleanup, baseline green between tasks, independently verifiable acceptance a verifier can check, self-contained spec, source-bound references, never scaffold the verifier as task 1), `:272-341` (adversarial critique loop, cap 2; an infra/malformed critique emits a synthetic major issue → `planned_with_caveats`, never a silent clean), `:343-421` (**acceptance criteria are concatenated into each task's spec string** so the planning rigor flows down into the implement/review gate as data — "the reviewer must judge against it").

**What**: The plan gate scores task lists against a concrete decomposition rubric, and the acceptance criteria survive planning by being folded into the task payload the reviewer later judges against.

**Gap in jido_radclaw**: The plan gate (AR-1) approves an approach; nothing scores decomposition quality, and planner output doesn't carry per-task acceptance criteria into the reviewer lenses' inputs. AR-9 (queue #3, PR-3) is about to build critique-only challenger stages + an arbiter — the natural home. *(2026-07-03: built — the challenger stages + arbiter shipped; contributing the STANDARDS rubric to their prompts remains open.)*

**Adoption sketch**: Contribute the STANDARDS rubric text to AR-9's challenger prompts; add `acceptance` to the planner's task schema and append it to implementer/reviewer stage inputs (respecting the seam-threading house rule: a dedicated field, not an overloaded carrier). The completeness clause pairs with C1-1's review prompt ("correct but incomplete must not pass — judge against the acceptance criteria").

---

## Skip / Already Covered

- **S-1. Dynamic-workflow JS engine (loop/state/journal-resume).** SKIP — Claude-Code-harness-specific. The composer + Reactor + `WorkflowEvent` projection are the local engine and a superset (crash-anywhere resume, idempotent wave dedupe, boot-time recovery, replay gates — squidie T1-1/T1-3, AR-2, all shipped). Camus's `~/.camus/*.json` + mtime + sha-gated file IPC is what our Postgres log replaces.
- **S-2. Crash-resume / skip-finished-work machinery.** ALREADY-COVERED — `route_composer.ex:1015-1099` re-projection + `composer:<run>:<wave>` idempotency keys; `resume_checkpoint` gate resume; `WorkflowRecovery`. Camus would borrow from us here. The one garnish worth taking is C1-6's `ready_to_merge`-style *proven-work* nuance: resume lanes should distinguish "proven but unlanded" from "unfinished" (falls out of C1-4/C1-6 dispositions).
- **S-3. Human-gate parking (`needs_human`, answers threading).** ALREADY-COVERED — squidie T1-4/T2-5 gates + `GateDisposition` + `Cases.decide`. Camus's *new* contribution is only the two dispositions and the land lane (C1-4) and resume hints (C3-2).
- **S-4. MCP pruning for the review lane** (`CAMUS_CODEX_DISABLE_MCP` — "a review needs the repo, not your toolbelt"). ALREADY-COVERED — per-template MCP reach allowlists (`Consumer.modules_for_template/3`, `templates:` scoping) are the same idea generalized. Apply the existing mechanism to the C1-1 reviewer template; nothing new to build.
- **S-5. `merge_settings.py` permission-profile merger / auto-mode narrow profile.** SKIP — Claude Code settings machinery; ToolApproval + the shell-floor analyzer are the local answer. (Its *merge discipline* — append-only, preserve `$defaults`, backup, refuse invalid JSON — is already house practice via the deep-merge-config memory.)
- **S-6. `steer` (live guidance via file IPC).** SKIP — experimental and default-off even upstream ("the architecture is the problem"; their 0.3 redesign is an atomic-claim inbox). Our steering surface is OTP messages/signals + gates, which don't have the TOCTOU class. Worth keeping only their closing lesson, which matches house memory: claim-to-a-private-location beats split read-then-act for retryable atomic ops.
- **S-7. Cost-survival run-target design** (subscription-vs-metered boundary, tmux/VPS targets, `caffeinate`). SKIP — Claude-Code-billing-specific operational doctrine, not portable machinery. C2-1 takes the one durable idea (budget as a boundary-checked question).
- **S-8. `transcripts.py` Claude-transcript parsing for watch enrichment.** SKIP — harness-internal-format scraping; we own our telemetry (Trace events, `AgentTracker`, the event log). C2-4 gets the same "honest live board" outcome from first-party data.
- **S-9. Worktree containment guard / out-of-tree task worktrees.** SKIP for now — camus needs worktree isolation because its agents share the operator's machine; our isolation model is Forge sandboxes + `.prototypes/` dirs, and host-tree edits are the REPL's supervised normal mode. The *containment assertion* half (prove the tree only changed where claimed) is absorbed into C1-6(c) as claims-vs-porcelain reconciliation. Revisit wholesale if argus §3.1 (`Worktrees` domain) becomes real — camus's `wt.sh`/naming-fence/cleanup discipline is a good reference then.

## Open questions

- **OQ-1. Executor-seam residuals (direction decided 2026-07-02; see C1-1).** The old question here — Forge runner vs a second `Jido.AI` provider — is resolved (Forge runner, behind a template-level `executor:` binding). What remains open: (a) **workspace materialization** — how a repo-coupled runner stage gets the working tree (mount vs clone vs diff-only into the sandbox; interacts with S-9 and argus §3.1's Worktrees design); (b) **override precedence** — template `executor:` vs a later stage-level override vs run-level config, and whether a run can force `:in_process` fleet-wide (e.g. Forge disabled); (c) **result channel exclusivity** — is the MCP deposit tool the *only* channel, or do schema-capable CLIs also get a stdout path (two channels invite contract drift; leaning single-channel); (d) **`needs_input` → gate case** mapping (first wave treats it as `blocked`).
- **OQ-2. `done_with_findings` — disposition or DB status?** Start as `result.disposition` on `:completed` (no migration, surfaces filter in memory); promote to a first-class `WorkflowRun` status only if dashboards/queries need to index on it. The projection layer makes the promotion cheap later.
- **OQ-3. Budget unit.** Camus caps output tokens because that's what its harness meters; `AgentTracker` already tracks cost. Cap on tokens (portable, provider-neutral) with cost displayed alongside, or cap on estimated cost (what operators actually fear)? Needs a decision before C2-1's event schema is set.
- **OQ-4. Verify command source of truth.** ✅ ANSWERED 2026-07-05 — the design note of record is `JidoClaw.Orchestration.Verify.Config`'s moduledoc: per-run override → `.jido/config.yaml` (`verify_cmd:` scalar/argv or a `verify:` block incl. the registry-lite `checks:` list) → minimal Elixir auto-detect (`mix.exs` + `precommit` alias ⇒ `mix precommit`, else `mix test`) → a loud INCONCLUSIVE envelope (never a pass, never a silent skip). No tenant-level defaults in v1, code-path routes only (the sketch/F2 exec tier gets no verify), argv lists only (no shell — scalars whitespace-split only when metacharacter-free and not env-assignment-led). Known residual (camus C2-7, parked): a fix loop editing `.jido/config.yaml` mid-run changes later resolutions.

## Cross-references and dependencies

```
C1-3 (verdict normalizer) ──┬──> C1-1 (executor seam → cross-vendor review, runner-backed stages)
                            │         └─ later stage-level override aligns with AR-9 PR-1's shape
C1-2 (deterministic verify) ┼──> C1-4 (done_with_findings / needs_decision)
        │         └─ a shell-runner-backed verify stage is one C1-1 implementation
        │                   │
        │                   └──> C1-5 (stuck/oscillation) ──> C1-4
        │
        └──> C1-6 (git sealing) ──> [AR-10 shipping tail, when it lands]

C2-2 (canary) proves C1-1 + C1-2 on an operator's machine
C2-3/C2-6 (doctor/ground) prevent what C1-3 would otherwise classify
C2-1 (budget) + C2-4 (staleness) + C2-5 (retro) are the operator-trust layer over all of it
C3-3 (postures) requires C1-4 first — camus's own ordering
```

Suggested first wave if any of this is adopted: **C1-3 → C1-2 → C1-4** (normalizer, deterministic verify, honest statuses) — they're mutually reinforcing, touch only the orchestration layer, and none depends on AR-9. **C1-1 (the executor seam) is independent of AR-9** — the template-level binding + `AgentRunner` branch can land any time after C1-3 (its normalizer is the deposit-tool contract); only the later *stage-level* override should coordinate with AR-9 PR-1 so the two override mechanisms share one shape. C2-2/C2-3 follow C1-2 naturally; C2-8 (the five laws) costs a paragraph and can land any time.

## Bottom line

Camus's engine is not worth taking — ours is better, and theirs is welded to Claude Code. Camus's *judgment layer* is worth taking almost wholesale: it is the most carefully articulated version of "never let the system grade its own work" in any codebase this directory has reviewed, and jido_radclaw's composer is one seam-wiring away from being able to express all of it. The three ideas that should not be allowed to slip: **any runner behind any stage, with cross-vendor review as its first configuration** (C1-1 — one in-process binding in `AgentRunner` is all that stands between the shipped substrate and the whole family; direction agreed 2026-07-02), **the repo's own tests are the final authority, head-bound** (C1-2 — closes a real cover-up class our LLM-verdict shape cannot detect), and **stalls become named human decisions instead of laundered failures** (C1-4 — the "knows when to stop" half, nearly free on the shipped gate machinery).
