# Features Worth Borrowing from OpenHelm

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's eighth dig). This subject was the corpus's one recorded **no-dig** ("contrast
reference only", [../DIG-BRIEFS.md](../DIG-BRIEFS.md)); the dig ran anyway on explicit
operator request as argus implementation begins — the same trigger that reversed the
Xantham and pad no-dig/deferral calls, and the reversal paid: **both** of the scan's
recorded pattern citations turned out to be wrong in load-bearing ways (see Determination).
Source: `~/workspace/research/pms/OpenHelm` (maxbeech/OpenHelm — "a local-first macOS
desktop app that turns high-level goals into scheduled, self-correcting Claude Code jobs";
business/growth automation, not SWE). Pinned: OpenHelm @ `2facabaa` (2026-07-04 — **5
commits past the scan pin `1f4196c`, same day**, and the drift matters: a `v2.1.0` release
replaced the entire Autopilot subsystem the scan described), jido_radclaw @ `8699af6a`.
Cites are firsthand reads of both trees, accurate to within a few lines; nothing was built
or executed this review. Shape: TypeScript ~286k LOC — `agent/` Node sidecar 122k, `src/`
React 80k, `worker/` Fly.io cloud tier 47k, `src-tauri/` Rust shell 12k, plus `shared/`,
`supabase/`, `mcp/`, and a 1.5k-LOC Go TLS proxy. Maturity: 584 commits since 2026-04,
tags v1.2.0/v1.3.0/v2.1.0; top committer is the agent alias `the-today-app` (274) over the
solo human (228) — peak solo-plus-agents velocity, with the drift to prove it: the
auto-update manifest is **two releases stale** (a 1.2.0 install is never offered 2.1.0),
main CI red since 06-09 per its own commit messages, four disagreeing version numbers
across manifests, and three shipped-but-unwired subsystems found during this dig. The
`docs/` tree (PRD + ~35 plan docs cited by README/CLAUDE.md) is **gitignored** — the
public repo withholds the planning corpus, so the 5.4k-line CHANGELOG (implementation-
fidelity, root-cause-style) is the doc surface and the code is the only authority.
License: **BUSL-1.1** (converts to Apache-2.0 on 2029-01-01; free for individual personal
use) — house discipline per corpus observation 8 stays **patterns only, never code**.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — seven claims),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map; §8 crons and §12
attention/approvals are where most entries land),
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md) (C1-3
fail-closed parse and C1-4 honest terminals — OpenHelm independently converges on both),
[../../ouroboros/FEATURES-WORTH-BORROWING.md](../../ouroboros/FEATURES-WORTH-BORROWING.md)
(OB1-2 structured premises / OB1-3 evidence floor — OpenHelm's `outcome_spec` + evaluator
are their shipped shapes),
[../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md](../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)
(XA1-2 off-process watchdog; XA2-1/XA2-2 gate gaps OH1-2 interacts with),
[../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md](../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-2 attention read-model — OH2-2 supplies its dedup/storm mechanics),
[../bosun/FEATURES-WORTH-BORROWING.md](../bosun/FEATURES-WORTH-BORROWING.md) (BO1-2
anomaly taxonomy + sentinel, BO1-3 digest shapes — same family as OH2-2), and
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md) (MC1-4
failure taxonomy OH1-1's classification joins). Threat-model weighting as always:
personal tailnet — LLM-misbehavior containment and leakage hygiene over external-attacker
hardening.

**Structure note**: like the sibling digs, this doc adds a **"Dig-brief dispositions"**
section after the tiers (explicit answered/contradicted/absent per standing question) and
a scan-corrections block mirrored into the corpus README.

## Determination (TL;DR)

**Nothing to adopt as a dependency; the scan's "contrast only, no dig" verdict was wrong
about where the value is.** Both recorded citations *corrected*: the "risk-taxonomy gate
(1–5 per-tool risk vs threshold)" is **dead code** — zero callers, structurally mismatched
with its own taxonomy files — and the live gate is a better idea the scan never saw (a 1–5
autonomy dial presented as three honest preset cards × an action-**class** taxonomy with
fail-closed unknown→most-restrictive × **apply-with-undo** instead of ask-first for
reversible actions); the "run-snapshot-for-resume" is **write-only** — the read-back
function has zero callers, and the exact re-resolve-on-resume bug its migration claims to
fix is still live. What the dig found instead is concentrated on the two argus surfaces
the scan under-read: **FLOW §8** (the cron/automation health loop — a layered,
auto-recovering circuit-breaker family with failure classification, plus the
charge-before-call daily budget ledger) and **FLOW §12** (attention dedup, storm collapse
into incidents, additive email-on-attention), plus strong independent convergence with the
already-queued camus/ouroboros verification program (`outcome_spec` contracts, a
fresh-context evaluator with read-only DB tools that never trusts the executing model's
narrative, fabrication detection by claimed-vs-observed). The seams pass turned up a
live our-side gap this dig makes adoptable now: **cron failures currently have no operator
surface, no persisted failure state, and telemetry that cannot distinguish a failed tick
from a successful one** — OH1-1 is the reference for closing that. §5 edit-and-resume
verified **empty at every layer** (subject 24): approvals execute the stored payload
verbatim (args aren't even rendered on the approval card), the one custom-input path is
dead code, and chat's "Request Change" rejects the whole batch and re-prompts.

| Part of OpenHelm | As a dependency | What to take |
| --- | --- | --- |
| Tauri desktop app + cloud SaaS | No — macOS-only single-tenant desktop + their hosted worker; BUSL; wrong domain (no git/code layer) | Nothing structural |
| Scheduler + CLI-error monitor | No | **The cron health loop** (OH1-1): failure classification (transient vs rate-limit vs infra), persisted consecutive-failure breaker, pause+attention-item+auto-recover, liveness watchdog family |
| Approval/autonomy layer | No | Autonomy preset cards × action-class taxonomy × apply-with-undo × batch-approve card (OH1-2); the dead per-tool 1–5 scorer is the counterexample |
| Engine v2 evaluator + criteria | No | `outcome_spec` + fresh-context judge with DB read tools + fabrication check — riders on next-ten #5/#6/#9/#10 (OH1-3) |
| Engine v2 tick + budget ledger | No | Signals→diff→triage cost shape + charge-before-call daily budgets + the v1 "users disabled it for burning tokens" anti-pattern (OH2-1) |
| Tasks/attention inbox | No | Dedup keys, 24h-reopen touch-in-place, infra-incident storm collapse, guaranteed escalation, email-on-attention rules (OH2-2) |
| Claude Code chat driving | No | `--disallowed-tools` structural scheduler denial + follow-through backstop (OH2-3); MCP preflight + honest tool advertisement (OH2-5) |
| Run MCP snapshot | No | The *intent* (OH2-4, TRACK): our resume re-resolves tools/env live too — nobody has shipped the pin |
| e2b/Goose cloud tier, TLS/MITM stealth proxy, MCP distribution layer | No | Contrast only (S-1/S-2/S-5); the service-role-key-in-sandbox is FLOW §4's negative reference (S-6) |

## Why not adopt as a dependency

1. **Wrong topology and wrong domain.** macOS-only Tauri desktop (single-tenant SQLite)
   plus their hosted cloud worker (Supabase + Fly + e2b). No git layer, no worktrees, no
   code-review surface — jobs run in the user's real project directory or an ephemeral
   Ubuntu sandbox. Argus is a multi-node, phone-reachable control plane over exactly the
   substrate OpenHelm lacks.
2. **BUSL-1.1.** Patterns only per house discipline; nothing here tempts a lift anyway
   (TypeScript/Rust/Go vs OTP/Ash).
3. **The aspiration–wiring gap is wide at HEAD.** This dig found three
   built-and-documented-but-unwired subsystems (the run-snapshot read path, the per-tool
   risk gate, the OpenRouter cost-metering proxy — each with tests), two mis-wired
   surfaces (prompt-rewrite task buttons missing their required arg; a dead custom-input
   editor), a two-releases-stale auto-updater, and self-admitted red CI. The *shipped
   mechanics* below were verified against code, not docs or comments — and several
   CHANGELOG claims survived only partially.
4. **Where it overlaps our substrate, ours is stronger.** No event sourcing, no leases
   (an acknowledged cross-machine race in the cloud scheduler; cancellation is a no-op on
   any machine but the sandbox holder), no durable mid-run pause (their HITL deliberately
   *ends* the run and fires a follow-up job — the README calls mid-run pause "fragile"),
   approvals that end runs rather than checkpoint them.

## How to read this document

Recommendation vocabulary per the corpus conventions (`docs/exploration/README.md`):
**BORROW-PATTERN**, **BORROW-REFERENCE**, **FOLD-IN**, **INDEPENDENT**, **TRACK**,
**ALREADY-COVERED**, **SKIP**. Initial inventory — no Status lines. Tiers scoped to this
codebase: **Tier 1** = clear gap, high leverage, buildable against a shipped seam or a
decided argus slice. **Tier 2** = valuable, lands with a specific argus slice or a queued
work item. **Tier 3** = garnish. IDs `OH<tier>-<seq>`; `S-n` skips; `OQ-n` open
questions. Every Gap claim verified against jido_radclaw @ `8699af6a` on 2026-07-04.

---

## Tier 1 — High Impact

### OH1-1. The cron/automation health loop — failure provenance, layered breakers, auto-recovery

**Recommendation**: BORROW-PATTERN — and the our-side half is **INDEPENDENT, adoptable
now** (no argus dependency; queued in [OH-FIRST-WAVE.md](OH-FIRST-WAVE.md)).

**Where in OpenHelm**: `agent/src/executor/cli-error-monitor.ts:29-30,90-103,245-380`
(the breaker), `agent/src/scheduler/liveness-watcher.ts:62-171` (watchdog +
auto-recovery), `agent/src/executor/failure-triage.ts:81-141` (streak promotion),
`agent/src/scheduler/orphan-reconciler.ts:24-57`, `worker/src/autopilot-corrective.ts:22`,
`worker/src/scheduler.ts:380-448`.

**What**: a family of layered health mechanisms around scheduled agent jobs, each with
failure *classification* before counting:

- **Transient ≠ rate-limit ≠ infra.** Only transient CLI/API errors (regex-classified)
  increment the consecutive-failure counter; rate-limit errors instead defer *all*
  scheduled runs until the reported reset time; connectivity outages stamp a 10-min
  window that suppresses failure-triage entirely (`cli-error-monitor.ts:29-30,311-338`).
- **The breaker**: 5 consecutive transient failures (counter **persisted** as a setting,
  survives restarts) → `scheduler.stop()` + `scheduler_paused=true` + a 20-min pause
  window + a human-facing attention item ("N consecutive runs failed — scheduler
  paused") (`:347-380`).
- **Auto-recovery**: the liveness watcher re-arms only `cli_error` pauses once the window
  elapses (user/auth/update pauses stay), deleting the counter and logging a
  `scheduler_auto_resumed` system event; if the API is still down the breaker simply
  re-trips — bounded churn (`liveness-watcher.ts:126-171`). The paid-for lesson is in the
  CHANGELOG: a 2026-06-05 overnight API blip paused every job ~9h because nothing
  auto-resumed; recovery was added after.
- **Above the breaker**: a per-job failure-streak signal feeds the engine's triage
  (streak ≥ 2 becomes a signal, 5 is critical); a 15-tick sweep promotes 3+ consecutive
  failures in 24h with no clean run to `permanent_failure` + attention item; the cloud
  corrective path grades its response by autonomy level (propose-disable vs
  auto-disable+task). Stranded work: an orphan reconciler heals enabled jobs whose
  `next_fire_at` went NULL; a scheduler heartbeat watchdog soft-restarts a silent tick
  loop and `process.exit(1)`s on the second silence so the *supervisor* restarts the
  agent — XA1-2's off-process rule as shipped code.

**Gap in jido_radclaw** (verified 2026-07-04): the seams pass confirms the CC1-2-era
finding is current, and sharpens it. Our cron worker's 3-strike counter is **in-memory
only** (`lib/jido_claw/platform/cron/worker.ex:42,56-57`) and resets on every Owner
reconcile, leadership move, or restart; auto-disable writes only `disabled_at`
(`worker.ex:355-371`) — and the `:for_tenant` read filters disabled rows out
(`lib/jido_claw/cron/resources/job.ex:170-173`), so a tripped job **vanishes from
listings** rather than surfacing. `Cron.Job` has no failure/error columns (`job.ex:268-283`);
`run_count` bumps on failure too (`worker.ex:378-393`). Telemetry cannot distinguish
outcomes: `emit_cron_stop` fires identically for success and returned error
(`worker.ex:224-225`; metric tags carry no status, `lib/jido_claw/core/telemetry.ex:80-87`),
and `emit_cron_exception` fires only on a raise, not on `{:error, _}`
(`worker.ex:216-235`). Cron emits **zero Trace events**, and the `:schedule` Trace
channel is attached in the collector but has **no producer anywhere in lib/**
(`lib/jido_claw/trace/collector.ex:109`) — the natural slot, sitting dormant. There is
also no stuck-run watchdog: dispatch is synchronous and a hung target blocks the worker
indefinitely (`worker.ex:25-28,182-185`).

**Why it matters**: argus slice 1 is "the thing you check from your phone" — and today a
cron job that fails three times silently disappears. FLOW §8 already commits to
"consecutive failures trip a circuit breaker — pause the schedule, raise an attention
item," citing OpenHelm; this dig verifies the citation and adds the parts FLOW hadn't
specified: **classify before counting** (a rate-limited job is not a failing job — defer,
don't count; an infra outage is nobody's failure), **persist the counter** (ours resets
exactly when the cluster is unstable, which is when it matters), **auto-recover with
bounded churn** (the 9-hour-pause lesson), and **disable must produce an attention item,
never a vanishing row**.

**Adoption sketch** (the adoptable-now half; argus §8 automations inherit it):
`Cron.Job` gains `consecutive_failures`, `last_error_class`, `last_failure_at`, and a
`paused_until` distinct from `disabled_at`; the worker classifies dispatch results
(reuse `MC1-4`'s taxonomy split: retryable / rate-limited / infra / terminal) before
counting; trip ⇒ pause + Trace `:schedule` event (the channel's first producer) + a
pending `AgentCase`-adjacent attention row; the Owner's reconcile re-arms expired pauses.
Telemetry: add a `status` tag to `cron.job.stop` and emit exception-equivalent on
returned errors. A `:for_tenant_all` read (or an `include_disabled?` arg) so tripped jobs
stay visible.

*(Connective note, 2026-07-04 pass: the rate-limit-is-a-schedulable-state rule has a
second shipped arrival this corpus never cross-cited — symphony's six-state account
health with the reset-header probe ([SY1-4](../symphony/FEATURES-WORTH-BORROWING.md)),
whose own first-wave canary closes the same ades XA2-3 slot this entry's watchdog
family sits beside. README observation 12 assembles the shelf.)*

### OH1-2. Autonomy presets × action-class taxonomy × apply-with-undo × the batch-approve card

**Recommendation**: BORROW-PATTERN for the argus approvals build (FLOW §12, slice 1) and
the deferred per-tool MCP overlay; the dead per-tool scorer is the counterexample that
sharpens it.

**Where in OpenHelm**: live gate `agent/src/mcp-servers/autopilot-actions/gate.ts:48-54`
(`resolveActionMode`), classes `agent/src/autopilot/action-class-taxonomy.ts:26-95`,
autonomy cards `shared/src/index.ts:1571-1601` + the old 1–5 descriptions self-labeled
"dishonest" (`:1508-1556`), undo + audit `agent/src/mcp-servers/autopilot-actions/tools.ts:208-514`
+ `job_changes` (`agent/src/db/schema.ts:745`), verbatim-execute
`agent/src/ipc/handlers/tasks.ts:84-151`, batch card
`agent/src/chat-bridge/` + `shared/src/pending-setup.ts` (placeholder chaining), read/write
MCP taxonomies `agent/src/mcp-servers/taxonomies/*.json` (unknown → write,
`agent/src/chat/tools.ts:305-311`). **Dead**: the per-tool 1–5 risk scorer
(`agent/src/tasks/approval-gate.ts:47-95`, `tasks/taxonomy.ts:68-103` — zero callers, and
the taxonomy JSONs no longer even carry `riskWeight`).

**What**: the autonomy surface that *survived* their iteration, in four pieces. (1) One
**1–5 autonomy dial** stored as {1,3,5} and presented as three preset cards with honest
copy ("Balanced: handles routine fixes itself; asks before anything that takes a job
offline. Every action is logged with one-tap Undo."). (2) An **action-class taxonomy** —
`reversible_tuning | auto_with_undo | destructive_availability`, unknown class →
destructive (fail-closed) — where the *destructive* class always proposes below full
autonomy. (3) **Apply-with-undo**: for reversible classes at autonomy ≥ 2, the action
applies immediately, writes a `job_changes` audit row with before/after, and mints a
one-click **Undo task** — the ask is replaced by a revert affordance. (4) For chat-driven
setup, N dependent writes queue into **one approve-all card** with `pending:<kind>:<n>`
placeholder chaining, validated at call time so the model self-corrects before the human
ever sees the card; approval executes strictly in order with dependency-cascade failure
semantics. Approval **executes the stored payload verbatim** from the DB row — the agent
does not re-issue — and there is no edit path (the args aren't even rendered on the task
card, only on the chat card, read-only).

**Gap in jido_radclaw** (verified 2026-07-04): our gate is binary and categorical —
require-list + param-patterns + template overlay + MCP default-on
(`lib/jido_claw/security/tool_approval.ex:125,221-228,265-291`); **no severity or score
concept exists anywhere** on tools, and the graduated graft points are exactly
`requirement/4` and `gate/4`'s nil-vs-reason branch (`tool_approval.ex:204`). Single-use
`:consume` / deny-once (`lib/jido_claw/orchestration/agent_case.ex:210-225`); **pending
approvals never expire** (no TTL attribute or sweeper — XA2-1 still open); no payload
edit (fingerprint-locked, `lib/jido_claw/orchestration/tool_approvals.ex:104-114`). And
one load-bearing contrast the argus phone-approval design must internalize: **our
approve executes nothing** — the agent re-issues the identical call and the approval is
consumed by fingerprint match (`lib/jido_claw/orchestration/cases.ex:264-282`), which
assumes a live agent loop still waiting. OpenHelm's runs *end* before approval, so their
decision object carries the action and the platform executes it on click. An approval
decided from a phone hours later, after the session ended, needs their shape (a durable
recommended action / follow-up trigger), not ours.

**Why it matters**: FLOW §12 already designs against approval fatigue (single-use
default; standing grants scoped `(kind, project)` with TTL; a hard-block list of
never-grantable kinds). OpenHelm ships the closest field-tested version of that stack:
their `destructive_availability` class **is** the hard-block tier; apply-with-undo is the
standing-grant alternative for reversible platform mutations (arguably better: no
standing authority exists to leak — the authority is the revert); the batch card is the
answer to N-related-writes fatigue; and the honest-preset-cards-over-numeric-scale UI —
plus their own dead per-tool numeric scorer and "dishonest" scale descriptions — is
direct evidence for classes over scores (OQ-1). The verbatim-execute semantics feed the
ended-session approval case (OQ-2).

**Adoption sketch**: keep the require-list as the hard floor. Add a class attribute to
gate *reasons* (not tools): today's require-list entries map to classes (`forget`,
`replay_workflow` → hard-block/ask-always; `schedule_task` pause/resume →
reversible-with-undo once OH1-1's pause exists). Argus approve dialog offers
once / this-thread / this-project-N-days (FLOW §12 as designed) **plus** revert
affordances for applied reversible actions (a `job_changes`-style audit row is what our
Audit.Event + Trace already give; the missing piece is the one-click revert case). For
the batch card: the composer's pendingActions equivalent is a multi-write chat turn —
adopt validate-at-queue-time so invalid entries bounce to the model before the card
renders.

### OH1-3. Outcome contracts + the fresh-context evaluator — shipped shapes for the queued verification program

**Recommendation**: FOLD-IN — riders on next-ten #5 (deterministic verify authority),
#6 (honest terminal statuses), #9 (structured premises), #10 (evidence floor). No new
queue item; this entry is the field reference those four consume.

> **Status (partial): the #5 rider ✅ FOLDED IN 2026-07-05** (next-ten #5
> shipped). What landed of this entry's slice: the three verification judges
> (`verifier`, `system_verifier`, `test_runner`) now carry **read-only
> deterministic evidence tools** — `lua_query`/`lua_docs` (sandboxed,
> lexical-only, tenant-scoped, `Lua.Policy`-capped) — instead of
> transcript-only input, plus the camus `VERIFY_OATH` doctrine slice (the
> engine envelope is the verdict authority on the code path; the LLM judges
> diagnose reds). The **forced-verdict-at-cap** rule is satisfied
> engine-side, documented in the item-5 design rather than new machinery:
> every cap exhaustion terminalizes a NAMED disposition
> (`verify_failed`/`review_infra_failed`/`verify_tampered`/
> `budget_exhausted`) — never a silent failure.
>
> **The #6 rider ✅ FOLDED IN 2026-07-06** (next-ten #6 shipped):
> `done_with_findings` is the `partially_succeeded` analogue
> (completed-family, disposition-first, never plain green on any surface),
> and the enforced-transition-table shape landed as an **exhaustive
> authority-kind × terminal-status test matrix** in
> `workflow_event_projection_test.exs` (every status-authority event kind ×
> every terminal status ⇒ `:illegal`, per-kind authority drift-guards) —
> `Projection.next_status/2` was already the enforcement point, so the rider
> cost a describe block. The #9/#10 riders remain queued.

**Where in OpenHelm**: `agent/src/planner/outcome-assessor.ts:74-252,298-421` (the
judge), schema `agent/src/planner/schemas.ts:142-185`, evaluator
`agent/src/engine/evaluator.ts:46-169` + `shared/src/engine/types.ts:12-64`
(`RunEvalVerdict`, criteria), `jobs.outcome_spec` (required for chat/composer-created
jobs, `shared/src/outcome-spec.ts` via CHANGELOG 2.1.0), run statuses + enforced
transitions `agent/src/db/schema.ts:215-228` + `db/queries/runs.ts:48-57`, cloud verifier
`worker/src/run-verifier.ts:42-64`, sandbox preamble "verify the actual outcome" +
HEAD-sha check `shared/src/sandbox-preamble.ts:112-170`.

**What**: the run-quality stack, converging with our queued program from an unrelated
domain. (1) **`outcome_spec` `{endState, check, stopBound}` is REQUIRED** on every
agent-created job — an outcome contract the evaluator judges against (ouroboros OB1-2's
acceptance-criteria idea, enforced at creation). (2) The **outcome assessor** is a
fresh-context Haiku judge given **read-only DB tools** so it verifies rows and
timestamps directly instead of pattern-matching truncated logs; primary evidence (DB
row, HTTP 2xx) outweighs prose; it detects PARTIAL (completed/required counts) and
**FABRICATION** (`claimed` vs `observedInDb`); it **fails closed** — never null, one
retry then high-confidence not-accomplished; a compaction guard suppresses
log-count-based demotion on compacted transcripts. (3) The v2 **evaluator separation**:
after every run, a judge that "never trusts the executing model's narrative" scores goal
advancement (`advanced | no_progress | regressed | not_applicable`), may flip
machine-checkable criteria **only with evidence** (content edits reserved for planning
paths), and writes a `next_run_hint` + capped briefs fed into the next run's prompt —
piggybacked into the existing assessor call so separation costs zero extra LLM calls.
(4) **Honest terminal statuses** with an enforced transition table:
`partially_succeeded` and `permanent_failure` are first-class, and `succeeded` accepts no
further transitions. (5) The cloud verifier is turn-capped and at the cap is **forced to
commit a verdict** — never a silent failure.

**Gap in jido_radclaw** (verified 2026-07-04): this is precisely the territory of queue
items #5/#6/#9/#10 — all confirmed unstarted by the seams pass (no automated
verification authority; `WorkflowRun` statuses lack a partial/permanent split; composer
premises carry no acceptance criteria; no claims-vs-evidence floor). Our `Eval` harness
is deterministic assertions over production functions (`lib/jido_claw/eval.ex:2-8`) —
the right substrate, no judge on top. The camus verdict normalizer (shipped, next-ten
#4) is the parse-discipline half; OpenHelm independently ships the same fail-closed
posture ("schema-invalid LLM output throws, never falls back").

**Why it matters**: convergence across unrelated projects is the corpus's strongest
design-validation signal (the next-ten queue says so itself), and this is the third
independent arrival at the same stack — camus (judgment layer), ouroboros (premises +
evidence floor), now a business-automation product that hit the identical failure modes
(narrative-trusting judges, vanity metrics, fabricated deliverables) and shipped the
same fixes. The transplantable specifics: give the verify stage **read-only deterministic
tools** rather than transcript-only input; require an outcome contract at
automation-creation time (argus crons and agent-created tasks, FLOW §7/§8); make
fabrication a *counted, breach-visible* event; cap the judge and force a committed
verdict at the cap.

**Adoption sketch**: rider notes recorded on the queue items (see
[OH-FIRST-WAVE.md](OH-FIRST-WAVE.md)): #5 gains "judge gets read-only tool access
(lua_query is the natural vehicle — sandboxed, lexical-only, already tenant-scoped)";
#6 gains the `partially_succeeded`-analog disposition + forced-verdict-at-cap; #9's
schema reserves `outcome_spec`-shaped acceptance fields for cron/automation producers;
#10 gains claimed-vs-observed as its sharpest check.

---

## Tier 2 — Valuable, lands with a specific slice or queued item

### OH2-1. The engine tick — signals → snapshot-diff → one cheap triage → capped deep work, under a hard budget

**Recommendation**: BORROW-PATTERN for argus FLOW §8 automations (slice 3) and any future
"platform watches itself" loop; the v1 anti-pattern is the half to internalize first.

**Where in OpenHelm**: `shared/src/engine/tick.ts:16-26,58-177`, signals + facts-hash +
cooldowns `shared/src/engine/signals.ts:110-141` (kinds `types.ts:138-153`), budget
`shared/src/engine/budget.ts` via `tick.ts:81-96`, ledger table `engine_budget_ledger`
(CLAUDE.md data model), jitter `shared/src/engine/jitter.ts:17-31`; the v1 retirement
story in CHANGELOG 2.1.0 ("~475 diagnostic metrics collected every 15-min tick, keyword
triage … the thing users disabled for burning tokens") and the retirement migration
`agent/src/engine/seeder.ts:19-120`.

**What**: the cost architecture of a supervision loop. ~10 cheap DB-computed signals per
tick, content-hashed and snapshot-diffed — **no change = zero LLM calls** (~90% of ticks
per their docs; not executed this review). On change, ONE Haiku triage maps each changed
signal to a closed enum `ignore | externalise | cheap_fix | escalate` — schema-invalid
output **throws**, no keyword fallback (camus C1-3's posture, independently). Cheap
fixes dispatch through the OH1-2 gate with undo + audit and a 6h per-signal cooldown;
escalations enqueue at most `deepReviewsPerDay` (0/0/2/4 by effort preset) Sonnet runs;
ignores cool down 24h. Underneath: a **charge-before-call** per-project daily token
ledger by category, graduated degrade (80% → model downgrade, 100% → refuse +
one deduped escalation task), per-project deterministic jitter. v1 — always-on metric
collection with keyword triage — is the documented anti-pattern, retired by a versioned
idempotent migration with a grep-guard test keeping the deleted code gone.

**Gap in jido_radclaw** (verified 2026-07-04): no self-watching loop exists (fine — argus
§8 is where one arrives); more concretely, **no cross-run spend ceiling exists for
autonomous work**: LoopGuard's 100-call cap is per-session and in-memory
(`lib/jido_claw/agent/loop_guard.ex:13-45`), and isolated cron jobs mint a fresh session
per run (`lib/jido_claw/platform/cron/dispatcher.ex:52`) — a cron firing every 5 minutes
is bounded per-run and unbounded per-day. FLOW §8 names an "automation doom-loop budget…
LoopGuard's sibling at the automation layer" without a shape; this is the shipped shape.

**Why it matters**: argus automations will be exactly this kind of loop (task-status
bindings, cron ticks, workflow→workflow chains). The two transferable laws: **diff
before you think** (signals are free; only deltas earn an LLM call) and **charge before
you call** (a budget checked after the call is a report, not a budget). The v1 story is
the strongest anti-pattern citation in the corpus for always-on LLM supervision.

### OH2-2. Attention mechanics — semantic dedup, storm collapse, guaranteed escalation, additive email

**Recommendation**: FOLD-IN to the argus attention feed (FLOW §12, slice 1) — the
mechanics layer under CC1-2's read-model, joining bosun BO1-3's delivery shapes and
myrlin MY1-3's storm rules.

**Where in OpenHelm**: dedup `agent/src/tasks/index.ts:61-87` + key factory
`agent/src/autopilot/dedup-key.ts` (note `infraIncidentKey`, `:39-50`), 24h reopen +
priority escalation `agent/src/db/queries/tasks.ts:387-529`, guaranteed escalation
`agent/src/tasks/guaranteed-escalation.ts:19-57`, hourly digest
`agent/src/autopilot/hourly-digest.ts:1-11`, email rule `agent/src/tasks/index.ts:127-136`
+ `agent/src/notifications/attention-email.ts:6-26`, native-notification levels + focus
suppression `src/lib/notifications.ts:15-29,151-186`.

**What**: the inbox that stays usable under failure storms. **Semantic dedup keys**
(caller-supplied, project-scoped, `global:` prefix for cross-project) merge repeat
findings into the existing open task — bump `reminder_count`, escalate priority on the
3rd recurrence, reopen if closed within 24h — instead of inserting. **Storm collapse**:
an infra error class shared by 16 failing jobs keys to ONE incident task
(`incident:${project}:infra:${errorClass}`). **Guaranteed escalation**: task creation
under DB contention retries 3× then falls back to a low-lock system-event row that is
rendered unconditionally — an escalation must never vanish (their NaN-priority bug once
made 232 failures invisible; the fix coerces before insert). **Digest**: sub-threshold
breaches roll into one per-project message *edited in place* hourly. **Email-on-attention**
is additive (native notifications always fire) and rule-gated: `approval_required` source
OR priority ≥ 80. Native notifications: `never | on_finish | alerts_only` +
unfocused-only for chat/importance pings.

**Gap in jido_radclaw** (verified 2026-07-04): there is **no attention-item abstraction
at all** — every surface is pull-based CLI/LiveView or in-process PubSub
(`lib/jido_claw/orchestration/run_pubsub.ex:6-13`); no push/email/digest/webhook-out
exists anywhere, and the auth email senders are deliberate no-ops
(`lib/jido_claw/accounts/senders/send_magic_link_email.ex:6-10`). The closest primitive
is the `AgentCase` pending inbox — approval-shaped, not attention-shaped.

**Why it matters**: slice 1's push taxonomy (FLOW §12) already has delivery *rules* from
five products; OpenHelm supplies the *storage* mechanics those rules assume — dedup
keys, touch-don't-insert, storm collapse into incidents, and never-lose-an-escalation.
The `infraIncidentKey` idea maps directly onto our error-class machinery
(`run_error_classes` in their schema; our `MC1-4`-style taxonomy when it lands).

### OH2-3. Structural denial of the CLI's competing scheduler + the follow-through backstop

**Recommendation**: BORROW-PATTERN — the denial lands with the argus `:cli` engine
(slice 6); the backstop joins the FLOW §12 `ended_blocked` family.

**Where in OpenHelm**: `agent/src/chat/cli-scheduling-block.ts` (via CHANGELOG 2.1.0:
`--disallowed-tools CronCreate,CronDelete,CronList,RemoteTrigger,ScheduleWakeup,Skill,SlashCommand`
in BOTH chat modes — "impossible by construction, not by prompt"); follow-through
`shared/src/follow-through-prompt.ts` + `agent/src/chat/turn-runner.ts:155-194` (one
Haiku classification of a zero-write turn with committed-sounding prose → ONE corrective
`--resume`; classification failures surface as errors, never keyword fallbacks).

**What**: two fixes for "the agent promised but the platform never received." (1) When
the platform IS the scheduler, the driven CLI's *own* scheduling surface is denied by
flag, not by prompt — Claude Code's cron/routines/skill tools are structurally
unreachable, so drift into the wrong scheduler is impossible. (2) A turn that *sounds*
committed but wrote nothing gets exactly one cheap classification and one corrective
resume of the same session — "promised but never created" becomes structurally
impossible rather than a nudge.

**Gap in jido_radclaw** (verified 2026-07-04): FLOW §4's CLI threads will drive Claude
Code inside Forge sandboxes — a CLI that ships CronCreate/ScheduleWakeup while argus owns
crons (FLOW §8) reproduces exactly the drift OpenHelm closed. Nothing in the current
Forge/adapter design enumerates denied host-CLI tools. The backstop half: FLOW §12
already carries `ended_blocked` (ended owing an answer); OpenHelm's variant is *ended
owing an artifact*, with a shipped one-shot corrective resume rather than only a
notification.

**Why it matters**: cheap, sharp, and directly on slice 6's adapter checklist — the
adapter config template should carry a deny-list of the CLI's platform-competing tools
(scheduling, skills, slash-commands), and the attention taxonomy gains
promised-but-absent detection with a bounded self-heal before it pings a human.

### OH2-4. The run-scope snapshot — pin what a resumed run sees (corrected citation)

**Recommendation**: TRACK, named triggers: composer stages gaining external MCP reach
(the DIG-BRIEFS trigger, unchanged), or argus review gates creating long halt windows
(slice 4). Downgraded from BORROW-REFERENCE: **OpenHelm never wired the read half.**

**Where in OpenHelm**: write `agent/src/executor/index.ts:1501-1515` (`mcp_scope_json` =
bundled-server allowlist + configured MCP server names + investigation flag;
`connections_resolved_json` = connection **refs + injection method, never values**);
dead read `agent/src/db/queries/runs.ts:211-235` (`readRunMcpSnapshot` — zero callers);
migration `0080_run_mcp_snapshot.sql` and the schema comment both *claim* re-enqueue
reads it back — the exact bug they describe (resume re-resolves against current DB
state) is still live.

**What** (as designed, not as shipped): at run start, persist the resolved tool scope
and credential *references* so a resumed/re-enqueued run executes with the tool surface
it started with, not whatever the config says now.

**Gap in jido_radclaw** (verified 2026-07-04): we have **the same hole, live**: a gate
halt checkpoints the full `%Reactor{}` + inputs
(`lib/jido_claw/orchestration/reactor_runner.ex:866-869`), but MCP tool attachment is
re-resolved per step against the Consumer's node-global cache with 5-minute rediscovery
(`lib/jido_claw/skills/steps/agent_runner.ex:85`,
`lib/jido_claw/mcp/consumer.ex:108-109`) — a `.jido/config.yaml` change between halt and
resume changes the resumed run's tool surface; env/creds are read live at spawn
(`lib/jido_claw/security/redaction/env.ex:159-188`); only the model-tier *label* and
composer artifact refs are pinned. No per-run tool-surface snapshot exists.

**Why it matters, and why TRACK**: today the exposure is small — halts are short, MCP
config is operator-owned, and composer stages don't reach external MCP tools. Both argus
moves change that (long-lived review gates; stages with MCP reach). When the trigger
fires, the right first slice is cheaper than a hard pin: snapshot the tool-surface
*names* into run metadata at halt and **diff at resume** — surface drift as a preflight
warning through the same lane as `Replay`'s definition-hash gate (which is this exact
idea, already shipped for replay inputs). Nobody in 24 subjects has shipped the full pin;
we'd be first, so start with detection.

### OH2-5. MCP preflight + honest tool advertisement

**Recommendation**: BORROW-PATTERN — a small rider on our MCP Consumer now; required
reading for the slice-6 CLI adapter.

**Where in OpenHelm**: `agent/src/claude-code/mcp-preflight.ts:49-87,113-193,341-352`
(per-server initialize + `tools/list` probe, per-server timeouts, **min-tool-count
gates** — browser 10, data 6 — hard-fail + one retry, fail the run with a routable hint
instead of starting half-ready); `worker/src/executor-mcp-bridge.ts:161-264` +
`worker/src/executor.ts:590-605` (unhealthy bridges dropped from **both** the prompt
preamble and the extension list — never advertise an uncallable tool);
`agent/src/claude-code/runner.ts:193-195` (`ENABLE_TOOL_SEARCH=false` when MCP config
present — their root-cause fix after Claude Code's tool-search deferral broke every MCP
job, CHANGELOG 2026-06-04).

**What**: treat "the agent's advertised tool surface" as a checked precondition. Probe
each MCP server before the run; require not just liveness but a minimum tool count
(a server that answers with 3 of its 40 tools is *down*); on failure, fail the run with
a classified reason; and keep prompt-text and config in lockstep so the model never
sees a tool it cannot call.

**Gap in jido_radclaw** (verified 2026-07-04): our Consumer's `ensure_attached/3` is a
bounded wait for attach completion, and boot discovery is crash-isolated — but there is
no min-tool-count concept, no per-server preflight on the *turn* path, and a server that
comes up degraded registers whatever it returned. For native agents the blast radius is
low (tools route through our pipeline anyway); for the slice-6 CLI adapter — where we
generate `--mcp-config` for an external CLI exactly as OpenHelm does — the preflight +
tool-search-deferral gotcha are directly load-bearing.

### OH2-6. Agent-created automations expire unless re-justified

**Recommendation**: BORROW-PATTERN for FLOW §7/§8 (slice 3) — governance for
agent-minted recurring work.

**Where in OpenHelm**: `jobs.expires_at` / `justification` / `last_justified_at`
(CLAUDE.md data model + CHANGELOG 2.1.0); the Operator Review job "re-justifies or
retires expired engine-created jobs"; re-justification tasks dedup-keyed
`engine-rejustify:${jobId}` (`shared/src/engine/retirement.ts:40`).

**What**: work the *system* created carries a TTL and must periodically re-argue its
existence against current goals — a supervision job either renews the justification
(with evidence) or retires the job. Human-created work is exempt.

**Gap in jido_radclaw** (verified 2026-07-04): `schedule_task` is approval-require-listed
at creation (`lib/jido_claw/security/tool_approval.ex:125`), but once approved an
agent-created cron lives forever — `Cron.Job` has no expiry/justification columns
(`lib/jido_claw/cron/resources/job.ex:227-283`). FLOW §7 routes agent-created *tasks*
into triage; the recurring-work analog is unowned.

**Why it matters**: the approval-fatigue design (FLOW §12) governs the *creation* edge;
this governs the *accumulation* edge — a fleet of stale agent-minted crons is the
slow-burn failure mode of exactly the platform argus wants to be. One column pair + one
review lane closes it.

---

## Tier 3 — Garnish

### OH3-1. Sidecar supervision details — stability-reset crash cap + operator kill hatch

**Where**: `src-tauri/src/lib.rs:118-126,588-668` — restart-on-crash with a
5-consecutive-**rapid**-crash cap where 120s of stable running resets the counter (their
lifetime-counter version silently stopped restarting after 5 crashes *ever*); plus a
frontend `kill_sidecar` escape hatch for wedged-but-alive. **Ours**: OTP restart
intensity is windowed by design (`:max_restarts`/`:max_seconds`), so the bug class is
already structural — the garnish is the *operator-facing* kill hatch for a wedged
GenServer, and the reminder for any non-OTP supervisor we write (Forge runners driving
external CLIs, slice 6).

### OH3-2. Deploy-overlap age-guarded orphan reclaim

**Where**: `worker/src/scheduler.ts:380-448` — orphan sweeps only reap runs older than
`sandbox timeout + 15min` so a freshly-booted worker never kills the old machine's
still-live runs during a rolling deploy; failed orphans re-fire on schedule, never
re-dispatch (double-bill avoidance). **Ours**: WS3 reclaim is lease-fenced (strictly
stronger — CAS beats age heuristics), but the *rolling-deploy overlap* scenario is worth
a test case when argus makes multi-node reclaim routine: a rejoining node must not
reclaim runs whose lease is healthy merely because it just booted.

### OH3-3. Deterministic jitter + same-tick stagger

**Where**: `shared/src/engine/jitter.ts:17-31` (FNV-1a-seeded ±20% per-project cadence
jitter — deterministic, so restarts don't reshuffle), `agent/src/scheduler/index.ts:63-67`
(same-tick jobs staggered by `hash(jobId) % 8 × 8s`). **Ours**: cron workers arm exact
`next_run` timers with no stagger (`lib/jido_claw/platform/cron/worker.ex:277-350`) —
fine today; a garnish for when argus puts many projects × many crons on one always-on
node.

---

## Skip / Already Covered

- **S-1. TLS/MITM fingerprint proxy** (`tls-proxy/`, Go): JA3/JA4 ClientHello spoofing to
  defeat bot detection — threat-model inversion for us (we contain the agent; we don't
  disguise it). SKIP. Two hygiene notes worth keeping: loopback-bind assertion and
  SPKI-scoped trust (the MITM CA is never added to system trust — only the launched
  Chrome trusts it, by flag). Desktop-only at HEAD; the scan's "for browser automation in
  sandboxes" was wrong — it is not in the e2b image.
- **S-2. e2b/Goose cloud executor**: Forge covers this tier for us
  (`lib/jido_claw/forge/`); the Goose driving details are provider-specific. SKIP.
- **S-3. Dreaming (memory curation job)**: ALREADY-COVERED by the memory consolidator
  (`lib/jido_claw/memory/consolidator/`); the delta — "surface recurring failures,
  propose adjustments through the gated action path" — folds into OH2-1's loop, not into
  memory.
- **S-4. Chat-first "screens as thread events" shell**: their UX bet; argus is a
  board/cockpit client. SKIP.
- **S-5. MCP distribution layer** (Smithery/ChatGPT connectors, hosted OAuth AS): a SaaS
  distribution concern. SKIP.
- **S-6. Service-role key injected into every sandbox** (`worker/src/executor.ts:509-527`,
  tenant scoping enforced only in edge functions from body ctx): the **negative
  reference** for FLOW §4's sandbox MCP endpoint — our deny-by-default per-session
  scoped-token design is the correction; keep it.
- **S-7. Email-trigger jobs** (dormant `schedule_type='email'` + Haiku router + per-job
  sender allowlist + per-org daily cap): a tidy inbound-trigger shape, but argus's
  ingest path is GitHub webhooks (FLOW §4, later bolt-on); note the guard trio
  (cheap-router + allowlist + daily cap) if inbound-mail triggers ever matter. SKIP.

## Open questions

- **OQ-1 — Classes or scores for the graduated gate?** OpenHelm shipped both: the
  per-tool 1–5 scorer died unwired with "dishonest" UI copy; the action-class taxonomy
  (with fail-closed unknown) lives. Our require-list is already class-shaped. Decide at
  the argus slice-1 approvals build whether the graduated layer is (a) classes on gate
  *reasons* mapped to autonomy presets (OpenHelm's survivor, the lean), or (b) per-tool
  numeric risk (their corpse — adopt only with evidence they lacked).
- **OQ-2 — Who executes a late approval?** Our tool-call approve grants a retry the
  live agent must re-issue (`cases.ex:264-268`); OpenHelm's approve executes the stored
  payload after the run ended. Argus phone approvals will regularly decide after the
  session is gone — pick per gate kind: workflow gates already resume durably
  (`GateResume`); run-less tool-call gates may need a stored-action execution lane
  (their shape) or an explicit "grant expires with session" rule. Interacts with XA2-1
  (unconsumed approvals never expire — still open, reconfirmed by this dig's seams pass).
  *(Connective note, 2026-07-04 pass: the bosun dig hit the same wall from the
  workflow side — its BO2-5 folded approval-expiry + reconciler shapes into ades
  XA2-1, and its `onTimeout:"proceed"` default is the timeout-direction anti-pattern;
  three subjects now converge on the no-TTL gap. README observation 9 rolls this
  into the full gate-defect list.)*
- **OQ-3 — Where does cron breaker state live?** New columns on `Cron.Job` (lean; the
  Owner reconcile path already reads it) vs a separate per-job health resource (keeps
  the schedule row pure; easier storm queries). Decide when OH1-1's first-wave slice is
  picked up; the seams pass confirms nothing exists today either way.

## Dig-brief dispositions

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) — OpenHelm carried no numbered brief (it was the
recorded no-dig); the two standing citations + the cross-cutting six:

1. **Risk-taxonomy gate citation** — **CONTRADICTED as recorded, answered better**: the
   per-tool 1–5-vs-threshold gate (`tasks/approval-gate.ts` `checkApproval`) has zero
   production callers and its risk-weight lookup no longer matches the taxonomy JSON
   shape (those files are read/write classifications consumed by `classifyMcpTool`).
   Live gating is the autonomy dial (1–5, stored {1,3,5}, 3-card UI) × action-class
   taxonomy × apply-with-undo (OH1-2). "Executed verbatim on approval — never
   operator-edited" **CONFIRMED** — and sharpened: args are stored but never rendered on
   the task approval card.
2. **Run-snapshot-for-resume citation** — **CONTRADICTED as recorded**: write-only at
   HEAD; `readRunMcpSnapshot` has zero callers; resume re-resolves live — the exact bug
   migration 0080's comment claims to fix. Creds in the snapshot are refs + injection
   method, never values. The *intent* stands and our side has the same hole
   (OH2-4, TRACK).
3. **§5 edit-and-resume** — **ABSENT at every layer (subject 24)**: execution layer
   grep-clean (kill/pause/propose on interruption, never edit); UI layer one-click
   approve with args hidden, the lone `custom_prompt` input dead (no producer, handler
   drops the text), chat "Request Change" rejects the whole batch and re-prompts
   conversationally. No plan-layer promote-the-edit either (job-definition editing
   exists but is definition-layer, not pending-run). The streak: 24 subjects, still
   empty at the execution layer.
4. **Provisioning lifecycles** — ANSWERED, per-run-ephemeral variant: cloud = fresh e2b
   sandbox per run with ordered gated prep (60s ready gate, Xvfb warn-and-continue, MCP
   bridge probes, env/file credential hydration, idempotent CLI ensure). No durable
   workdir lifecycle anywhere. **Local is the anti-reference FLOW §5 needed**: runs
   execute in the user's real project directory, and after a May-2026 collision incident
   the fix was a global concurrency cap of **1** (`agent/src/executor/index.ts:89,268`) —
   the cleanest field evidence that no-worktrees forces fleet-wide serialization.
5. **Branch/directory naming** — ABSENT: zero `worktree`/branch-template machinery
   repo-wide (scan claim verified).
6. **Status/attention taxonomies** — ANSWERED richly: tasks `todo|done|archived` +
   source enum (`ai_proposed|approval_required|system|user|browser_escalation`) +
   priority 1–100 with **no severity column**; runs 8-status with an enforced transition
   table incl. `partially_succeeded`/`permanent_failure`; triage
   `ignore|externalise|cheap_fix|escalate`; signal severity `info|warn|critical`;
   notification level `never|on_finish|alerts_only`. Human-ping rule: email on
   `approval_required` OR priority ≥ 80, additive to native notifications;
   unfocused-only suppression (emdash EM1-3's rule, independently again).
7. **Teardown + stranded-work** — ANSWERED at the run level (no workdirs to strand):
   age-guarded cloud orphan sweeps (OH3-2), 24h stale-queued sweep, orphan-schedule
   reconciler, scheduler-heartbeat watchdog with process-exit escalation (XA1-2 shipped
   as code), watchdog SIGTERM→sandbox-kill ladders.
8. **Placement & multi-machine** — ABSENT-by-design locally; the cloud tier is
   hub-and-spoke with **no machine identity, no leases** (Postgres is the only
   coordination; an acknowledged non-atomic concurrency race; cancellation is a no-op on
   any machine but the sandbox holder). Argus's lease/reclaim machinery is ahead of the
   ninth subject in a row.

## Scan corrections (mirrored into [../README.md](../README.md))

1. **Version/velocity**: scanned at v1.3.0-era `1f4196c`; five commits later the same
   day, `v2.1.0` **replaced the entire Autopilot subsystem the scan described** (v1
   Maintainy scanner retired as "the thing users disabled for burning tokens"; Engine v2
   = signals→diff→Haiku triage→gated actions/capped deep review + budget ledger +
   criteria oracle + evaluator). Version truth is now four-way (0.1.0 ×3 manifests,
   2.1.0 ×2, update-manifest stale at 1.2.0 — the auto-updater cannot offer current
   releases).
2. **"Risk-taxonomy approval gate (tool-call risk 1–5 vs user threshold; risky calls
   block and materialize as tasks…)"**: the per-tool 1–5 gate is **dead code** (zero
   callers, shape-mismatched taxonomies). Live gating is autonomy-level × action-class
   with apply-with-undo. "Executed verbatim on approval — never operator-edited"
   confirmed (args never even rendered on the approval card).
3. **"Run snapshots (resolved MCP scope + creds persisted at run start so interrupted
   runs resume with identical context)"**: write-only — the read-back has zero callers;
   resume re-resolves live (the migration's own claimed fix, unshipped). Snapshot creds
   are refs + injection method, never values.
4. **"No worktrees, shared project dirs, concurrent jobs collide"**: confirmed and
   sharpened — local runs execute in the user's real project directory; the collision
   fix was a global concurrency cap of 1.
5. **"Ships a Go TLS/MITM proxy for browser automation in sandboxes"**: desktop-only
   (not in the e2b image), default-off, loopback-bound; purpose is JA3/JA4 fingerprint
   control.
6. **Prompt-rewrite proposer**: real but split — the agent-facing tool auto-applies
   with undo + audit (contradicting its own "always propose" header comment); the
   human-facing proposal buttons are mis-wired (missing required `newPrompt`) and fail
   on click; cloud has no apply path at all.
7. **New context**: `docs/` (PRD + ~35 plan docs cited by README/CLAUDE.md) is
   gitignored — the public repo withholds the planning corpus; the CHANGELOG is the doc
   surface.

## Cross-references and dependencies

```
OH1-1 cron health ─────────┬─→ INDEPENDENT slice, adoptable now (OH-FIRST-WAVE)
      (breaker family)     ├─→ FLOW §8 breaker cite hardened (dig-verified)
                           └─→ MC1-4 failure taxonomy (classification joins it)
OH1-2 autonomy × classes ──┬─→ argus slice 1 approvals (FLOW §12 fatigue design)
      × undo × batch card  ├─→ deferred per-tool MCP approval overlay (AGENTS.md)
                           └─→ XA2-1 (no-expiry reconfirmed) / XA2-2 (hard-block ≈ destructive class)
OH1-3 evaluator/contracts ──→ riders on next-ten #5 #6 #9 #10 (recorded in OH-FIRST-WAVE)
OH2-1 engine tick + budget ─→ FLOW §8 automations (slice 3); the doom-loop budget shape
OH2-2 attention mechanics ──→ FLOW §12 slice 1; composes with CC1-2 + BO1-3 + MY1-3
OH2-3 scheduler denial ─────→ slice 6 CLI adapter config; §12 ended-owing-an-artifact
OH2-4 run-scope snapshot ───→ TRACK: composer external-MCP reach / slice 4 review gates
OH2-5 MCP preflight ────────→ Consumer rider now; slice 6 adapter reading list
OH2-6 automation expiry ────→ FLOW §7/§8 slice 3 (agent-created recurring work)
OH3-* garnishes ────────────→ slice-6 runner supervision / WS3 reclaim test / cron stagger
```

**Suggested first wave**: [OH-FIRST-WAVE.md](OH-FIRST-WAVE.md) — one adoptable-now item
(OH1-1's cron failure-provenance + breaker slice; no argus dependency, gap live today)
plus the recorded riders on already-queued work (#5/#6/#9/#10 evaluator shapes; the
slice-6 reading-list entries). Collision note: nothing here conflicts with the in-flight
queues — the riders land inside next-ten items the seams pass confirmed unstarted, and
OH1-1 touches only the cron subsystem (no queue overlap).

## Bottom line

1. **OH1-1** — cron failures are invisible today (in-memory counter, vanishing disabled
   rows, status-blind telemetry, a dormant `:schedule` Trace channel): adopt the
   classify-count-pause-notify-auto-recover loop now; argus slice 1 inherits an
   attention feed that already has something to say.
2. **OH1-2** — the approval-fatigue stack has its field survivor: autonomy preset cards
   × action classes × apply-with-undo × one batch card — and a corpse (per-tool numeric
   risk) that answers OQ-1 in advance. The verbatim-execute contrast (OQ-2) is the
   design question argus phone approvals must answer that nothing else in the corpus
   surfaced.
3. **OH1-3** — the queued verification program (#5/#6/#9/#10) gains its third
   independent convergence and its most concrete shapes: required outcome contracts, a
   fresh-context judge with read-only DB tools, fabrication as claimed-vs-observed, and
   forced verdicts at the cap.
4. Both recorded scan citations for this subject were wrong at HEAD — the no-dig call
   would have left them standing in FLOW's margins. §5 stays empty at subject 24, and
   argus's differentiators (durable mid-run pause, leases, event-sourced runs, edit-gate
   head-promotion) survive the corpus's final subject.
