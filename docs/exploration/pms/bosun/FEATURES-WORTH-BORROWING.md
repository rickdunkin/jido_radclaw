# Features Worth Borrowing from bosun

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's fifth and final first-wave dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md) — briefed
as "targeted read, timeboxed"; run as a full six-reader exploration on operator
instruction, and the subject earned it: the readers overturned or sharpened eight scan
claims). Source: `~/workspace/research/pms/bosun` (virtengine/bosun — "a production-grade
control plane for an autonomous software engineer": plans and routes work across an
executor pool, automates PR lifecycles, operator control via Telegram + a Mini App
dashboard). Pinned: bosun @ `18e079f6` (2026-05-12, v0.43.1 — **zero drift from the scan
pin**; `pull --ff-only` re-run this dig came back already-up-to-date), jido_radclaw @
`609350aa`. Cites are firsthand reads of both trees, accurate to within a few lines.
Shape: Node ≥22 pure-ESM, **~787k LOC** JS/TS (ui 143k, workflow 57k, agent 44k, server
42k, infra 40k, task 20k, shell 17k, workspace/telegram 16k each; the scan's "114k-line
`cli.mjs`" was a bytes-for-lines misread — cli.mjs is 3,219 lines/114KB, a thin
dispatcher). Maturity: 2,821 commits in under three months (2026-02-19 → 2026-05-12),
authors jaeko44 (1,411) + Jonathan Philipos (~440) plus bot/test committers
(copilot-swe-agent 62, "Bosun Bot", three literal "Test"-named identities ~208) — solo-
plus-agents velocity with the drift to match; quiet since May. License: Apache-2.0
(clean). Nothing was built or executed this review — all claims are code reads. In-repo
doc/code drift is **heavy** and recorded per entry; headliners: the two-way kanban sync
engine's module was deleted while its workflow-template replacement still dynamic-imports
it (silently failing), `_docs/NATIVE_ADAPTER_COMPARISON.md` lists as open gaps seven
features the code ships, `_docs/WORKFLOWS.md` attributes startup resume to a server that
explicitly disables it, docs reference a "VKAdapter" that no longer exists, the
`CronScheduler` class is test-only dead code, and the root AGENTS.md routes worktree work
to the legacy of two parallel worktree subsystems. Calibrate accordingly, in both
directions — the mechanics below were verified against code, not docs.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — eight claims),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on; FLOW §7
already cites "the bosun-adapter trap" — BO1-4 is that citation cashed out),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md) (MC1-1
resume stack BO2-3/BO2-4 garnish; MC1-4 failure taxonomy BO1-1/BO1-2 ride),
[../orca/FEATURES-WORTH-BORROWING.md](../orca/FEATURES-WORTH-BORROWING.md) (OR1-4
provisioning BO2-1 composes with; OR1-3's push-release vs BO1-4's pull-gating),
[../chorus/FEATURES-WORTH-BORROWING.md](../chorus/FEATURES-WORTH-BORROWING.md) (CH1-2's
boundary-delivery finding, which BO2-4 narrows),
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md) (C1-3
infra-vs-verdict, whose executor-level sibling is BO2-3), and
[../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md](../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)
(XA2-1 approval expiry, which BO2-5 hands a shipped reference; XA1-2's
notifier-independence rule, which the sentinel ships as a process). Threat-model
weighting as always: personal tailnet — LLM-misbehavior containment and leakage hygiene
over external-attacker hardening.

**Structure note**: like the sibling digs, this doc adds a **"Dig-brief dispositions"**
section after the tiers and a scan-corrections block mirrored into the corpus README.

## Determination (TL;DR)

**Nothing to adopt as a dependency; the corpus's feature-superset comparable is also its
most instructive wreck survey.** The scan's framing ("on paper it has nearly every argus
noun") survives — event-sourced ledger, auto-resume, worktree lifecycle, gate family,
kanban adapters, phone surface all exist — but on contact a large fraction dissolves:
the two-way sync engine was **deleted in production** (its replacement imports a missing
module and fails silently), the run-level governance approval pauses nothing, the
risky-action gate is default-off, gate timeout defaults to *proceed*, `/remediate` is a
stub, `ask_user` has a writer and no reader, and resume runs off an atomic state
*snapshot* while the "execution ledger" is a non-crash-atomic audit sidecar. What
survives verification is genuinely worth having: the corpus's **only shipped
interrupted-run auto-resume** (whose qualification fences and unresumable-reason taxonomy
are the reference for the resume path our reclaim machinery documents as missing), a
13-type **agent-anomaly taxonomy** with warn/kill thresholds (our LoopGuard's bigger
sibling), the field's most complete **phone delivery shapes** (immediate-vs-digest
priority split, a live digest edited in place per window, a pinned always-current status
board), true **mid-turn steering on the Claude lane** via the agent-SDK streaming-input
channel (narrowing the corpus's "boundary delivery, never mid-turn" record to "one
shipped exception"), and worktree bootstrap details nobody else shipped (shared-path
symlink dependency reuse, signature-keyed idempotency). Equally valuable is what the
wreckage *proves*: FLOW §7's two-way-sync rejection and native task layer, our
durable-`AgentCase`-plus-checkpoint gate resume (vs their poll loops that re-open
approved gates on restart), our typed-event attention taxonomy (vs keyword sniffing),
and shared Postgres (vs fleet-over-shared-filesystem) each now have a
counterexample-verified justification. The §5 execution-layer edit-and-resume sweep
stays empty at **subject 21** — verified in the engine and every HTTP surface.

| Part of bosun | As a dependency | What to take |
| --- | --- | --- |
| Workflow engine + run store | No — snapshot-resume, JSON files, no tenancy/leases | **The auto-resume reference** (BO1-1): detection sources, qualification fences, dedupe rules, cap, unresumable-reason taxonomy, single-owner recovery |
| Anomaly detector + sentinel | No | 13-type taxonomy + warn/kill thresholds; the off-process watchdog shape (BO1-2) |
| Telegram bot + Mini App | No — argus is React PWA | Delivery shapes: immediate-vs-digest split, live digest, status board, confirm-with-token UX (BO1-3); the keyword classifier and Mini App authz gap as anti-patterns |
| Kanban adapters + task store | No | The deleted-sync-engine cautionary tale + status-machine lessons (BO1-4); assessment/debt vocabulary (BO2-6) |
| Worktree/workspace domain | No — two parallel subsystems | Shared-path symlinks + signature idempotency + conditional readiness (BO2-1); claim-time scope-locks as the blocking `fileConflicts` pole (BO2-2) |
| Executor harness (5 SDKs + 19 drivers) | No | Failover breaker's infra-vs-session split + poisoned-thread list (BO2-3); Claude mid-turn steer mechanism (BO2-4) |
| Approval family | No — ours is stronger where it counts | Expiry + reconcilers for XA2-1 (BO2-5); wake-prompt garnish; the key-collision accidental standing grant as a cautionary |
| Execution ledger + projections | No — ours supersets it | The committed projection-contract doc pattern (BO3-2) |

## Why not adopt as a dependency

1. **Wrong topology.** Single-host execution with fleet coordination over a *shared
   filesystem* (`presence.json`, file-locked claim registries, "eventual consistency on
   distributed filesystems" — `workspace/shared-state-manager.mjs:4-9`); no remote
   dispatch exists (`agent/fleet-coordinator.mjs:14-19` produces routing *hints*; the
   remote-sandbox runtime is a user-supplied `commandPrefix` stub,
   `workflow/heavy-runner-pool.mjs:383-389`). Argus's whole premise — clustered nodes,
   shared Postgres, node-affine execution — is the load-bearing thing bosun lacks.
2. **The substrate strengths argus needs are exactly what's missing.** Status lives in
   mutable JSON documents rewritten wholesale (`workflow/execution-ledger.mjs:1928`, no
   fsync/rename); resume trusts a debounced, `unref()`'d 500ms checkpoint timer
   (`workflow-engine.mjs:643, 9336`); approvals resume via in-process poll loops that
   **re-open already-approved gates after a crash** (`approval-queue.mjs:337,349`); no
   tenancy, no leases, no transactional projections. Our event spine, FOR-UPDATE
   projections, and lease fencing are the stronger halves of every one of these.
3. **Verification cost.** A third of the scan-level claims dissolved on contact (see
   Scan corrections), `_docs/` is dominated by plans and stale matrices, and the commit
   history is solo-plus-agents at 2,821 commits/3 months. Any claim not read in code
   this dig should be treated as unverified.
4. License is clean (Apache-2.0) — irrelevant, since nothing here is worth operating.

## How to read this document

Recommendation vocabulary per the corpus conventions (`docs/exploration/README.md`):
**BORROW-PATTERN**, **BORROW-REFERENCE**, **BORROW-RUBRIC**, **FOLD-IN**,
**INDEPENDENT**, **ALREADY-COVERED**, **TRACK**, **SKIP**. Initial inventory — no Status
lines. Tiers scoped to this codebase: **Tier 1** = clear gap, high leverage, buildable
against a shipped seam or a decided argus slice. **Tier 2** = valuable, lands with a
specific argus slice or an already-queued work item. **Tier 3** = garnish. IDs
`BO<tier>-<seq>`; `S-n` skips; `OQ-n` open questions. Every Gap claim verified against
jido_radclaw @ `609350aa` on 2026-07-04.

---

## Tier 1 — High Impact

### BO1-1. Interrupted-run auto-resume — the qualification fences and the unresumable-reason taxonomy

**Recommendation**: BORROW-REFERENCE — the corpus's only shipped resume-on-restart (21
subjects), and the reference checklist for the resume path our reclaim machinery
documents as missing.

**Where in bosun**: detection — `_detectInterruptedRuns` scans four sources
(`workflow/workflow-engine.mjs:9395-9597`): the previous process's persisted
`_active-runs.json`, index rows still `RUNNING` with no live execution, stranded
`PAUSED && resumable` rows, and a **bounded** orphan-detail-file scan (RUNNING/WAITING
nodes, no `endedAt`; capped + time-windowed, `:9516-9534`); marks each
`PAUSED + resumable + interruptedAt`. Resume — `resumeInterruptedRuns`
(`:9607-10143`): startup cohort first; **dedupe by taskId keeping latest** (older →
`duplicate_task_run`) and **family dedupe** (a root resume covers descendants →
`covered_by_root_interrupted_run`); hard cap `WORKFLOW_INTERRUPTED_RESUME_MAX_RUNS`
default **25**, overflow marked `recovery_cap_exceeded` (`:9410-9413,9470`); per-run
re-checks (workflow deleted, detail file missing, task already active, task terminal in
kanban, watchdog exhausted, and a **create-tasks idempotency guard** that blocks resume
unless the task-creating node can dedupe against a listable kanban,
`:3962-3990,10098-10107`). Fencing: a run with a **live local task claim is skipped**
(`:9452-9455`); a task-scoped run missing its claim at resume forces `from_scratch`
(`task_claim_missing_on_resume`, `:10088-10093`). The resume itself is
`retryRun(mode: "from_failed")` (`:5135-5343`): a fresh context **pre-seeded with every
COMPLETED node's persisted status and output verbatim**, failed/skipped reset, so the
DAG "naturally skips" completed nodes and re-executes from the failed one —
at-least-once, with idempotency pushed to specific nodes. Non-qualifying runs get a
durable reason (`_markRunUnresumable`, `:10195-10216`): ~11 values observed
(`invalid_task_identity, recovery_cap_exceeded, workflow_deleted, no_detail_file,
task_already_active, terminal_task_status, duplicate_task_run,
covered_by_root_interrupted_run, scheduled_non_task_run, create_tasks_pending_guard,
retry_error:*`). **Recovery has one owner**: the ui-server explicitly disables both
detect and resume flags ("The monitor owns startup interrupted-run recovery",
`server/ui-server.mjs:2085-2118,3898-3910`); the monitor/worker run it
(`server/workflow-engine-worker.mjs:294-297`, `infra/monitor.mjs:15210-15213`). The
warts ride along as anti-patterns: the checkpoint is a **debounced 500ms, `unref()`'d
timer** firing only at node completion (`workflow-engine.mjs:643,9314-9338` — a crash
loses the debounce window plus all in-node work), and a gate node re-executed on resume
**re-upserts its approval request back to pending** even if it was already approved
(`workflow/approval-queue.mjs:337,349` — hardcoded `status:"pending"`,
`resolution:null`, flagged "reopened").

**Gap in jido_radclaw** (verified 2026-07-04): reclaim exists and is automatic
(`ReclaimPooler` 15s poll everywhere, `reclaim_pooler.ex:52,139,146-150`; boot
`WorkflowRecovery` single-node/non-MCP, `workflow_recovery.ex:780-790`) but **resume is
narrow by design**: a `:running` run with no checkpoint is STRANDED → failed
(`workflow_recovery.ex:266-283,371`) because checkpoints are written only at
`:awaiting_approval` (moduledoc `:11-13`); the one genuine resume path is
decided-gate-downstream (`GateResume.resume(recovered: true)`, `:337-358`) plus the
composer's event-log route rebuild (`:501-524`). Our own code says the quiet part:
"a partially-executed reactor cannot be safely re-run today… the idempotency key is
launch-dedupe, not step-idempotency" (`workflow_recovery.ex:186-188`).

**Why it matters**: argus puts runs on worktrees on specific nodes; node restarts stop
being rare. When we build resume-past-the-gate-boundary, bosun is the only field
subject that shipped the whole checklist — and its taxonomy proves the hard part is not
the re-run but the *refusals* (dedupe, caps, claim fences, terminal-task checks) that
keep a recovery storm from double-executing work.

**Adoption sketch**: keep our disposition today (fail-stranded is honest given
at-least-once side effects). When resume-from-reclaim gets designed (trigger: OQ-1),
lift the checklist: qualification fences first (our lease + `claimed_by` is the
claim-fence analog; taskId dedupe ≈ our thread/task identity; family dedupe ≈ composer
parent-covers-children — already shipped in `workflow_recovery.ex:501-524`), a resume
cap with a durable `recovery_cap_exceeded`-class reason, and a **reason taxonomy on
unresumed runs** folded into MC1-4's `RunFailure` enum rather than invented separately.
Invert the two warts: checkpoints stay transactional (never debounced), and approval
state must survive resume (our `AgentCase` is already the fix — the criterion is "keep
it that way" when gate steps become re-executable).

### BO1-2. Agent-anomaly taxonomy + the sentinel watchdog — the LoopGuard sibling and the infra-degraded push

**Recommendation**: BORROW-REFERENCE (taxonomy + thresholds → MC1-4 rider and LoopGuard
watch-list) and BORROW-PATTERN (the off-process watchdog, for argus §12's
infra-degraded triggers).

**Where in bosun**: `infra/anomaly-detector.mjs` — 13 anomaly types, verbatim:
`TOKEN_OVERFLOW, MODEL_NOT_SUPPORTED, STREAM_DEATH, TOOL_CALL_LOOP, REBASE_SPIRAL,
GIT_PUSH_LOOP, SUBAGENT_WASTE, COMMAND_FAILURE_RATE, TOOL_FAILURE_CASCADE,
THOUGHT_SPINNING, SELF_DEBUG_LOOP, REPEATED_ERROR, IDLE_STALL` (`:36`), with per-type
**warn/kill thresholds** (`DEFAULT_THRESHOLDS`, `:53`): tool-call loop 6/12, rebase
spiral 10/25, git-push loop 4/8, subagent waste 10/20, tool-failure cascade 10/30,
command failure rate warn 25%, thought-spinning 25/50, repeated error 5/10, idle stall
300s/600s; actions `KILL | RESTART | ALERT`; only CRITICAL/HIGH notify; 5-min alert
dedupe. The origin corpus is `_docs/VK_FAILURE_PATTERN_CATALOG.md` — 13 *categories* of
observed agent-session failures with detection strings (session-log pathology, not
board-sync pain). Alongside it, the doom-loop floor in the tool executor:
`MAX_IDENTICAL_CALLS = 4` consecutive identical name+args aborts the turn
(`shell/tool-executor.mjs:73,226-229`). The **sentinel**
(`telegram/telegram-sentinel.mjs`, 2,434 lines) is a separate watchdog *process*:
companion mode (monitor alive, sentinel idle-watches via PID files + heartbeat JSON) ↔
standalone mode (monitor dead: sentinel takes over Telegram polling, pushes
`bosun crashed` / crash-loop alerts, runs recovery: crash-loop threshold 3-in-10min,
repair-agent with 15min cooldown / 20min timeout, restart backoff, and a recovery
circuit breaker — 5 consecutive recovery failures → 30min cooldown; config verbatim at
`telegram-sentinel.mjs:312-409`, health check every 30s `:171,1920`).

**Gap in jido_radclaw** (verified 2026-07-04): `Agent.LoopGuard` ships three mechanisms
(identical-call 4-in-8, failure signatures 3-in-20, per-key budget 100) — covering
bosun's TOOL_CALL_LOOP/REPEATED_ERROR/budget classes and nothing else; a LoopGuard halt
reaches **no operator surface** (tool-error envelope + telemetry only,
`agent/loop_guard.ex:94,146` — the CC1-2 gap, re-confirmed); MC1-4's failure taxonomy is
queued, unstarted. Nothing watches the watcher: if the whole node or the agent loop
wedges, no process-external mechanism pushes "your control plane is down" (XA1-2's
delivery rule — "the notifier must not depend on the agent loop being healthy" — is
recorded doctrine with no infra-degraded producer; the credential canary XA2-3 is the
only shipped kin).

**Why it matters**: the anomaly list is field-observed agent pathology with paid-for
thresholds — exactly the classes (rebase spiral, push loop, idle stall,
thought-spinning, subagent waste) a worktree-attached agent fleet will manifest and our
LoopGuard deliberately doesn't model. And the sentinel is the only corpus subject that
ships XA1-2's rule *as a process*: the thing that tells your phone the orchestrator died
cannot run inside the orchestrator. *(Connective note, 2026-07-04 pass: the corpus's
final dig added the in-process variant — OpenHelm's heartbeat watchdog soft-restarts a
silent tick loop and `process.exit(1)`s on the second silence so the supervisor
restarts it ([OH1-1](../openhelm/FEATURES-WORTH-BORROWING.md)). The sentinel remains
the only *separate-process* observer, but XA1-2's rule now has two shipped arrivals in
this corpus; README observation 12 assembles the shelf.)*

**Adoption sketch**: (a) fold the 13-type list + thresholds into MC1-4's `RunFailure`/
anomaly enum when it lands — as *detection kinds feeding attention items*, not kill
authority (our LoopGuard halts stay the only in-band stop; anomaly kinds route to the
CC1-2 attention feed). (b) argus slice 1: an infra-degraded trigger family per §12 —
heartbeat-stale node, wedged agent loop, cron circuit-open — produced by the gateway
layer (Phoenix, PubSub-subscribed) per XA1-2, with the sentinel as the reference for
what to push (crash, crash-loop, recovery-failed) and for the recovery circuit breaker
shape. An OTP translation note: supervision gives us in-process restart for free — the
borrowable part is strictly the *off-process* observer + phone push + breaker, which for
a personal tailnet can be as small as a systemd/launchd sibling or a second node's
watchdog cron probing `/health`.

### BO1-3. Phone delivery shapes — immediate-vs-digest split, the live digest, the status board

**Recommendation**: BORROW-PATTERN (delivery mechanics) for argus slice 1 (attention
loop + push); the classification half is the anti-pattern to avoid.

**Where in bosun**: the pipeline (`infra/monitor.mjs:9898-10004` →
`telegram/telegram-bot.mjs:11136-11185`): every outbound message is (1) fuzzy-deduped
(5-min window), (2) classified P1 critical → P5 by **keyword sniffing** over the
message text (positive signals like "task completed" force info), (3) filtered by a
verbosity ceiling (`TELEGRAM_VERBOSITY`: minimal P≤2 / summary P≤4 default / detailed
P≤5), then (4) routed: **P ≤ `TELEGRAM_IMMEDIATE_PRIORITY` (default 1) sends
immediately; everything else lands in the Live Digest** — one message per 20-minute
window (`TELEGRAM_LIVE_DIGEST_WINDOW_SEC` 1200), sent silent on first event, then
**edited in place** (3s debounce) with a severity-count line + chronological entries,
trimmed at ~3800 chars ("…N earlier trimmed"), **sealed** at window end and persisted
across restarts (`telegram-bot.mjs:10766-11009`). Beside it, the **Status Board**: one
pinned message edited forever (2s debounce) carrying the periodic status summary
(`:11011-11135`). Legacy batch mode caps per severity (critical all, errors first 5
"+N more", warnings first 3, info aggregated counts, `:11190`). P≤2 additionally
bridges to WhatsApp (`monitor.mjs:10004`). The chat-side act-before-doing pattern:
**confirmation keyboards with signed short-lived UI action tokens** (TTL 30min) carrying
a preview (Task/Executor/SDK/Model) before destructive commands
(`telegram-bot.mjs:4573,2577,906`). The negative findings ride along: **no quiet hours,
no per-kind caps** (Xantham stays ahead there); the classifier is regex-over-prose
(fragile by construction); and the Mini App **authz gap** — Telegram initData HMAC is
validated (standard WebAppData algorithm, `server/ui-server.mjs:15343`) but the result
is never checked against the chat-id allowlist, the HMAC compare is `!==` rather than
constant-time, an empty allowlist allows everyone, and `TELEGRAM_UI_ALLOW_UNSAFE`
disables all auth (`telegram-bot.mjs:315`, `ui-server.mjs:15639-15666`).

**Gap in jido_radclaw** (verified 2026-07-04): no push channel of any kind — the only
proactive surface is the LiveView dashboard, and only for gate/run/forge topics
(`dashboard_live.ex:16-18`, `approvals_live.ex:25`); **cron failures broadcast nothing**
(`cron/worker.ex:235-262`, logs/telemetry/DB only) and LoopGuard halts reach no surface
(BO1-2). OVERVIEW §6.2 has the trigger set decided (emdash/termic/CCC/Xantham merged,
FLOW §12) but the *delivery* layer — what a phone actually receives, at what
granularity — has no shipped reference in the corpus richer than this one.
*(Connective note, 2026-07-04 pass: two later digs supplied the layers beside it —
OpenHelm's storm semantics (semantic dedup keys, touch-in-place escalation, incident
collapse, never-vanish fallback, additive email —
[OH2-2](../openhelm/FEATURES-WORTH-BORROWING.md), which cites this entry forward) and
myrlin's device-side rules (replay suppression, focus-ack-consumes, min-signal re-arm —
[MY1-3](../myrlin-workbook/FEATURES-WORTH-BORROWING.md)). README observation 10
assembles the full stack; OQ-2's digest decision should read OH2-2's hourly
edited-in-place per-project digest as the second aggregation datapoint.)*

**Why it matters**: slice 1 is "the thing you check from your phone." The corpus's
other answers are per-event pushes with dedupe/debounce rules; bosun is the only
subject that shipped the *aggregation* story — and for a solo operator supervising many
agents, "one quiet digest message per window + immediate page for P1 + one pinned
always-current board" is a materially better phone experience than N discrete pushes.

**Adoption sketch**: slice 1 — keep our typed-event taxonomy as the classifier (kinds,
never keywords; the §12 trigger list is already the enum), then adopt the delivery
split: attention kinds map to `immediate` (gate opened, blocked-on-you, run failed,
infra-degraded) vs `digest` (completions, progress, skips); digest = a per-project
rolling window rendered from the CC1-2 attention feed read-model (Web Push notification
+ one updating card in the PWA — the "edited message" translated to our transport);
status board = the PWA home screen, which we get for free. Signed short-lived action
tokens are already our shape (per-session tokens minted through the UI, FLOW §11) —
extend the same rule to any push-notification action buttons. Carry the Mini App authz
gap into the §4.4 negative-reference list (validate-then-authorize: transport HMAC is
not authorization; allowlists must bind on every surface, constant-time compares).

### BO1-4. The deleted sync engine + the task-store lessons — FLOW §7's cautionary tale, cashed out

**Recommendation**: BORROW-RUBRIC (the failure inventory as design checklist) — and the
strongest validation evidence in the corpus for three already-made argus decisions.

**Where in bosun**: the trap, sharpened beyond what the scan recorded: `sync-engine.mjs`
**does not exist in the repo** — it survives only as strings inside
`template-sync-engine`'s `action.run_command` nodes that dynamic-import it with
`continueOnError: true`, so the replacement fails silently every run
(`workflow-templates/reliability.mjs:1430,1447,1435,1452`); the monitor's handle is
permanently null ("Sync engine lifecycle now managed by workflow template",
`infra/monitor.mjs:15174-15175`); the GitHub Projects V2 **webhook endpoint verifies
HMAC then always 503s** ("Sync engine unavailable", `server/ui-server.mjs:17419-17437`);
the template's own `metadata.replaces` records the deleted class's API
(`reliability.mjs:1528-1534`) — a two-way sync engine was built, hurt, and removed,
leaving per-call direct adapter reads/writes, a narrow PR-merged→done reconcile
(`monitor.mjs:6455-6508`), and executor drift-reconciliation **biased to the internal
store** (`task/task-executor.mjs:4300-4308`). The residue is a catalog of exactly the
two-way failure classes: lossy status round-trip (`cancelled` → close-as-not-planned on
write, any closed → `done` on read, `kanban/kanban-adapter.mjs:3556` vs `:4658`);
priority `medium/low` dropped on read (`:4709-4713`); the shared-state comment written
at the *first* match and read from the *last* (`:4171` vs `:4258` — a latent
divergence bug); non-CAS claim comments rescued only by file locks. The task store
underneath is the useful half: a real 7-state lifecycle collapse
(`NORMALIZED_STATE_MAP`: `backlog, inprogress, paused, inreview, done, cancelled,
blocked`, `task/task-store.mjs:290-311`) with a frozen **allowed-transition table**
(`:312-320`; `done`/`cancelled` terminal) and a completion guard (→`done` blocked while
review context exists unless `reviewStatus === "approved"`, `:1281-1334`) — but
**enforced only on the lifecycle API** (`transitionTaskLifecycle`, `:2630-2726`); the
kanban-adapter path calls raw `setTaskStatus` and **bypasses the state machine
entirely** (`:2521-2572`). Provenance is split: `statusHistory` records
`{status, timestamp, source}` with no actor; actor lands on a parallel `timeline` only
via the lifecycle path (`:2542-2546,702-717`). Dependency gating is **pull-only**:
`canTaskStart` checks all upstream tasks terminal, but completing A never releases or
starts B — no cascade exists (grep-verified; `blockedByTaskIds`, confusingly, holds
*downstream dependents* and is never iterated).

**Gap in jido_radclaw** (verified 2026-07-04): no task layer exists (Ash domains
enumerated; the only adjacent resource is `GitHub.IssueAnalysis`, part of the dead PR
pipeline — `github/issue_analysis.ex:29-52`); FLOW §7 has the whole design decided —
native resource, per-project statuses over system-owned semantic kinds, computed
blocked, one-way ingest later, **two-way sync explicitly rejected citing this very
subject** (`FLOW.md:188`) — but no code, and the schema freezes at slice 3.

**Why it matters**: three FLOW §7 decisions now carry counterexample-grade evidence.
(1) Two-way sync: the field's biggest adapter investment (four backends, batching,
caches, webhook plumbing) still ended in deletion — reference-links + one-way ingest is
not conservatism, it's the survivor. (2) The seven semantic kinds: bosun independently
collapsed its status zoo to seven lifecycle states nearly isomorphic to ours (their
`paused` ↔ our `triage` being the only mismatch pair) — the second independent
seven-state arrival after multica's evidence. (3) Kind enforcement must live **on the
resource** (Ash action/changeset), not on the polite caller: bosun built a real
transition table and then let its main write path skip it; and actor provenance must
ride the same write (pad's `StatusTransition` shape), not a parallel best-effort
timeline. The pull-vs-push release contrast with orca (OR1-3) frames slice 3's choice
cleanly: computed-blocked (bosun's pull) *plus* event-triggered release on `done`-kind
(orca's push) — FLOW §7 already picked exactly that composite; keep it.

**Adoption sketch**: slice 3, as checklist rather than code: transitions validated in
the Task resource's own actions (invalid transition = changeset error, no raw setter
exported); `StatusTransition`-style audit rows carry actor + source in the same
transaction; status→kind mapping total (unknown external status → `triage`-kind inbox,
never a silent default like bosun's unknown→`todo`); if GitHub links ever gain ingest,
write a **round-trip property test** for every mapped field (status, priority) — lossy
maps like closed→done are found by tests, not by operators. Completion-guard idea worth
keeping: a `done`-kind transition on a task with open review context requires the
review to be approved or an explicit override — composes with our gate family rather
than a bespoke flag.

---

## Tier 2 — Valuable, lands with a specific slice or queued item

### BO2-1. Worktree bootstrap — shared-path symlinks, signature idempotency, conditional readiness

**Recommendation**: BORROW-PATTERN, composing with OR1-4/TR1-3/EM1-1 in the FLOW §5
provisioning stack (slice 2).

**Where in bosun**: the piece nobody else shipped — **shared-path symlinking as
install-avoidance**: `node_modules` (node), `vendor` (php), `vendor/bundle` (ruby) are
symlinked from the primary checkout into the worktree (junction on win32), and when the
link is possible the corresponding install command is **skipped**
(`workspace/worktree-manager.mjs:74-78,310-330,357-393`). Bootstrap covers 8 stacks ×
package managers (node: pnpm/yarn/bun/npm; python: poetry/uv/pipenv/pdm/pip; go, rust,
java gradle/maven, dotnet, ruby, php — `resolveDefaultBootstrapCommand`, `:251-290`)
with per-stack config overrides and a 600s command timeout
(`DEFAULT_WORKTREE_BOOTSTRAP`, `:66-73`). Idempotency is **signature-keyed**: bootstrap
skips when `JSON.stringify({stacks, sharedPaths, commands})` matches the recorded
`bootstrapState.signature` (`:686-706`); runtime files are content-compared before
write (`worktree-setup.mjs:689-728`). Readiness gating is **conditional on repo
policy**: when the repo ships `.githooks/pre-commit` + `pre-push`, an incomplete setup
*throws* `worktree_runtime_setup_incomplete` (non-retryable → task blocked,
`worktree-manager.mjs:80-100`); otherwise setup is best-effort. Setup state is smeared
across four unshared stores (bootstrap signature / re-derived runtime files / a 4-state
recovery-health tracker `healthy|recovered|failing|degraded` in
`infra/worktree-recovery-state.mjs:17,98-139` / kanban status) — the anti-lesson TR1-3's
single `setup_status` split already fixes. No secrets are materialized (agent-hook
scaffolding only; `sanitizeGitEnv` strips `GIT_DIR`-class vars, `git-safety.mjs:3-42`).

**Gap in jido_radclaw** (verified 2026-07-04): zero toolchain provisioning (Forge's
declarative `bootstrap_steps` is the only hook, `forge/bootstrap.ex:21-30`); FLOW §5
specifies create→setup→ready with idempotent per-project steps, citing orca's detect
table — which refuses to guess but never avoids the install.

**Why it matters**: worktree-per-task on a personal fleet lives or dies on provisioning
latency; for the dominant stacks a symlinked dependency dir turns minutes into
milliseconds. The trade is real (shared mutable store across parallel worktrees — a
`pnpm install` in one worktree mutates all), so it's a per-project *policy*, not a
default.

**Adoption sketch**: slice 2 — extend OR1-4's setup-step table with a per-project
`shared_paths` option (link-then-skip-install when clean; never share when the task
itself edits dependencies); record the step plan's hash as the idempotency signature on
the Worktree row (re-provision only on drift); adopt conditional readiness as "a
worktree isn't offered until ready" (already FLOW §5 doctrine) with the throw-class
failure taken from their non-retryable classification. Keep TR1-3's single
`setup_status` — four unshared state stores is the disease, not the pattern.

### BO2-2. Scope-locks — claim-time file-overlap blocking, the other pole of `fileConflicts`

**Recommendation**: BORROW-PATTERN (as the *blocking* datapoint; FLOW §12 currently
plans advisory-only), decision recorded as OQ-3.

**Where in bosun**: `workspace/scope-locks.mjs` — path-keyed lock entries
`{lockId, taskId, ownerId, attemptToken, path, ttlSeconds: 300, expiresAt, metadata}`
in a file-locked registry, max 128 paths/task, paths inferred from task metadata
(`scopePaths`/`paths`/`filePaths`/`files`, `:194-204,231-256`); same-owner re-acquire is
idempotent, different owner → `{success:false, reason:"scope_lock_conflict"}`
(`:301-326`); expired locks swept on every operation. Wired into the claim path:
`claimTaskInSharedState` **fails a task claim** whose scope paths are locked by another
task (`workspace/shared-state-manager.mjs:583-599`) — overlap prevention *before* work
starts, vs orca's warning-only `detect_file_overlap` and myrlin's post-hoc
`fileConflicts` push.

**Gap in jido_radclaw** (verified 2026-07-04): nothing computes cross-worktree file
overlap; our writer exclusion is the worktree lease (one thread per worktree), which
says nothing about two worktrees touching the same files on different branches — the
exact merge-back conflict predictor FLOW §6/§12 wants surfaced.

**Why it matters**: the corpus now holds both poles — advisory (orca, myrlin) and
blocking-at-claim (bosun). For argus the attention-first posture (§12) is the right
default, but bosun shows the blocking variant is cheap once task metadata carries
predicted paths, and "this spawn will collide with thread X" is more useful *before*
the sub-worktree is provisioned than after.

**Adoption sketch**: slice 3/5 — compute predicted-path overlap at task-spawn and
sub-thread fan-out time from task `relevant_files`-class metadata ∪ live worktree dirty
sets; surface as an attention item + a visible warning in the spawn flow (advisory
default per FLOW §12); leave a per-project strict mode that refuses the spawn
(bosun's semantics) for repos where merge conflicts are expensive. TTL + swept-on-read
if we ever hold real locks — never a lock without an expiry.

### BO2-3. Executor failover breaker — the infra-vs-session error split

**Recommendation**: FOLD-IN → MC1-4 (failure taxonomy) and the camus C1-3 family; also
a SY1-4 sibling for per-executor health.

**Where in bosun**: `agent/query-engine.mjs:7-51,89-91,206-208` — failover to the
fallback executor fires only on **3 consecutive *infrastructure* errors within a 10-min
window** (classifier: timeout/429/econnreset/overloaded/crash/"sdk not available");
**session-scoped** errors (session/thread not found/expired/corrupt) instead trigger a
recovery retry (×1) and *suppress* failover — a wedged thread must not condemn a healthy
provider. Beside it, the **poisoned-thread detection list** for Codex resume: cached
thread metadata is dropped (forcing fresh) on `invalid_encrypted_content` / "missing
rollout path" / `tool_call_id` / 400-tool-call errors
(`agent/agent-launcher.mjs:4771-4800`).

**Gap in jido_radclaw** (verified 2026-07-04): our infra-vs-verdict split lives at the
judge boundary (camus C1-3, shipped); at the *executor* boundary nothing classifies
"this backend is down" vs "this session is poisoned" — relevant the moment next-ten #7
(executor seam) gives stages real vendor backends, and to the Forge CLI lane (MC1-1's
resume work needs exactly bosun's poisoned-resume list: silent resume failure →
clear-id-then-retry-fresh was multica's version; bosun contributes the error-string
inventory).

**Why it matters**: the wrong classification either flaps executors on one corrupt
thread or burns retries against a dead provider. Three unrelated subjects (camus at
judges, multica at resume, bosun at executors) converged on "classify infra separately,
window it, act differently" — corpus-grade validation for extending the C1-3 doctrine
one layer down.

**Adoption sketch**: when next-ten #7 PR-2+ lands Forge-backed executors: per-executor
consecutive-infra counter (windowed, 3-in-10min as the starting constants, attributed),
session-scoped errors → one fresh-session retry without touching executor health;
poisoned-resume error list seeded from bosun + multica; health states can reuse SY1-4's
`healthy|limited|exhausted|paused` vocabulary rather than a new enum.

**Status (2026-07-11, taxonomy half)**: PARTIAL — the vocabulary landed with
pre-argus Wave A #1: `RunFailure`'s `agent_session_poisoned` kind carries this
entry's error-string inventory (`invalid_encrypted_content`, rollout path,
`tool_call_id`, session/thread not-found/expired) as live string rules, retryable
AND resume-unsafe — exactly the "one fresh retry, never on the wedged thread"
split. The poisoned-list *consumer* (resume anchor clearing, driver-side
fresh-retry gating) reconciles with Wave A #2's resume stack; the per-executor
breaker/windowed-counter half stays open on its original next-ten #7 trigger.

**Status (2026-07-11, poisoned-list half)**: LANDED — pre-argus Wave A #2
closed the consumer this half was waiting on: the armed vendor runners
classify failures in-runner (`Runners.ResumePolicy`), a `resume_unsafe?/1`
kind POISONS the anchor (sticky — the id is never reused;
`ResumeState.rearm_new_anchor/4` is the only exit), a poisoned continuation
tags `resume_rejected: true`, and the consolidator driver grants exactly ONE
ledger-gated fresh retry (zero effects + retryable kind + deadline floor +
per-run latch) — the "one fresh-session retry without touching executor
health" split, now enforced. Two of this entry's codex strings were
live-probed to producer-exact forms (`"no rollout found"`, plus claude's
`"no conversation found"`). The per-executor breaker/windowed-counter half
stays open on its original next-ten #7 trigger.

### BO2-4. Claude mid-turn steering via SDK streaming input — the field's one shipped mid-turn lane

**Recommendation**: BORROW-REFERENCE for the argus `:cli` engine (slice 6) — and a
correction to the corpus record CH1-2 established.

**Where in bosun**: the steer path (`agent/session-manager.mjs:1142` →
`agent/internal-harness-runtime.mjs:643,738` → `agent/subagent-control.mjs:598-603` →
per-executor `session.send`): on the **Claude lane** the registered send function
pushes a user message onto the `@anthropic-ai/claude-agent-sdk` **streaming-input async
iterable that the live `query()` is consuming**
(`agent/agent-launcher.mjs:3253-3254`, `shell/claude-shell.mjs:607-617`, mode
`"enqueue"`) — the SDK folds it into the *in-flight* turn: true mid-turn injection, not
boundary queueing. Codex is boundary: `thread.runStreamed(prompt)` queues a follow-up
run, and native steering requires an SDK `steeringMethod` else `sdk_no_steering_api`
(`agent-launcher.mjs:2233-2241`, `codex-shell.mjs:1516+`). Delivery requires an active
registered session + active stage (`no_active_session`/`not_steerable` otherwise,
`internal-harness-runtime.mjs:445-449,707`), and every attempt emits
`intervention-delivered|rejected` telemetry. Approval decisions reuse the same channel
as **wake prompts** ("Operator approval granted … Resume" / "denied … adjust the plan",
`server/ui-server.mjs:6594`).

**Gap in jido_radclaw** (verified 2026-07-04): CH1-2's finding re-verified — our
mid-turn affordance is the AgentServer deferred-signal queue (next-turn delivery,
`deps/jido/lib/jido/agent_server.ex:1219-1288`), and the true mid-turn primitive
(`Jido.AI.Reasoning.ReAct.steer/inject`, PendingInput folded into the *current* run,
`deps/jido_ai/.../react.ex:134-157,225-241`) sits **unwired — zero callers in lib/**;
locus correction to the CH1-2 record: the primitive lives in the `jido_ai` dep, not
base `jido`. On the Forge/CLI side our runners have no steering channel at all.

**Why it matters**: FLOW §4's steering answer leaned on "the field ships boundary
delivery, never mid-turn" (Chorus dig). Bosun narrows that: mid-turn injection *is*
shipped in the field, exactly once, and only where a vendor SDK exposes a streaming
input channel — which is also our situation twice over (the unwired `jido_ai` primitive
for native threads; the agent-SDK streaming mode for a future Claude-lane Forge
runner). The conclusion stands (boundary delivery is the safe default; our mailbox
already queues), but slice 6's CLI adapter should *evaluate* streaming-input mode
rather than assume boundary-only is all that exists.

**Adoption sketch**: no action now. Slice 6 reading list: when the Forge `:cli` engine
picks its Claude invocation mode, weigh streaming-input (steerable mid-turn,
bosun-verified) vs one-shot `-p` (simpler, resume-based) — and if native threads ever
want mid-turn steer, the dep primitive is already there; wire it deliberately with
CH1-2's provenance rules rather than rediscovering it.

### BO2-5. Approval expiry + reconcilers — the shipped reference for XA2-1 (and the timeout-direction anti-pattern)

**Recommendation**: FOLD-IN → XA2-1 (unconsumed approvals never expire), which this
dig re-confirmed live on our side.

**Where in bosun**: every approval mechanism carries a timeout (workflow gate 5min,
workflow action 15min, harness stage 0 = indefinite), expiry writes a durable
resolution with actor `"system:timeout"` (`workflow/approval-queue.mjs:1221-1254`), and
**reconcilers synthesize expiry for orphans** — pending requests whose run is gone/not
active or past `expiresAt` are auto-expired at read time
(`reconcileWorkflowRunApprovalRequests`/`reconcileHarnessRunApprovalRequests`,
`:853-976`; `deriveStaleApprovalResolution`, `:302-317`). The anti-pattern rides along:
the workflow-gate default is **`onTimeout: "proceed"`** — a timed-out approval
auto-approves (`workflow/harness-approval-node.mjs:37-40`,
`workflow/flow.mjs:273-276`); and the per-tool approval's requestId defaults to the
*scope* (runId/sessionId), so **all tools in a session share one request — one approve
becomes an accidental session-wide standing grant**
(`agent/tool-approval-manager.mjs:37-64,145-172`).

**Gap in jido_radclaw** (verified 2026-07-04): `AgentCase` has no `expires_at`/TTL and
no sweeper (`agent_case.ex:286-347`; `Deadline` is a pure read-model,
`deadline.ex:2-6`); pending cases persist until an operator or run-terminal cancels
them (`reactor_runner.ex:795-820`). XA2-1 recorded this; bosun supplies the shipped
shape.

**Why it matters**: stale pending approvals are attention-feed rot and a
standing-grant-by-forgetting risk. Bosun proves expiry needs *two* halves — the timer
and the reconciler that catches orphans the timer missed — and demonstrates both
failure directions: timeout-means-proceed (never), and coarse approval scoping (our
`{tenant, session, agent_template, tool, canonical_params}` fingerprint +
single-use `:consume` is already the fix; the criterion is to keep scope precision when
standing grants land per FLOW §12).

**Adoption sketch**: with the slice-1 approvals build (where XA OQ-1/XA2-1 are already
slated): `expires_at` on `AgentCase` (per-kind defaults; NULL = no expiry for
workflow-axis gates where a parked run is the intended state), expiry as a
system-actor decision event (audit row, never silent), reconcile-on-read for orphaned
`:tool_call` cases, and a hard rule inverted from bosun: **timeout only ever fails
closed** (expired = denied-equivalent + attention item). The wake-prompt garnish (gate
decision rendered as a resume/adjust instruction to the agent) folds into how our
tool-approval envelopes already read.

### BO2-6. Assessment-action + debt-ledger vocabulary — dispositions for the review conversation

**Recommendation**: BORROW-RUBRIC, rider on next-ten #6 (honest terminal statuses /
`review_stall` disposition vocabulary — recorded there this dig).

> **Status: ✅ ADOPTED 2026-07-06 — folded into next-ten #6** exactly as the
> sketch prescribed: `done_with_findings` shipped (camus C1-4), and the debt
> ledger is a **filter over gate decisions, no new table** —
> `Cases.waived_findings_ledger/2` reads the approved `:review_stall` cases'
> `:approved` timeline events (each carrying the per-finding waive records
> with severity) into `%{cases, severity_counts, total_waived}`, exposed as
> the `jido.debt` Lua binding. The retry vocabulary
> (`reprompt_same | reprompt_new_session | new_attempt`) stays
> reference-only, named in the `Gate.Kinds` moduledoc vocabulary note beside
> traycer TR3-2's `superseded` and pad PD3-3's lineage badges; the
> attempt-cap escalation shape informed the stall/exhaustion triggers
> (re-review-budget exhaustion now parks at the gate on a certified green
> verify rather than terminalizing).

**Where in bosun**: `task/task-assessment.mjs:24-36` — the post-attempt decision enum,
verbatim: `merge, reprompt_same, reprompt_new_session, new_attempt, wait,
manual_review, close_and_replan, accept_with_debt, split_task, escalate_to_replan,
noop`; escalation triggers `attemptCount >= 4 → manual_review`,
`sessionRetries >= 3 → new_attempt` with executor swap (`:1017-1034`); and a **debt
ledger** normalizing accepted-with-debt items to `critical|high|medium|low` with counts
(`task/task-debt-ledger.mjs:6-10,124-135`).

**Gap in jido_radclaw** (verified 2026-07-04): next-ten #6 plans `done_with_findings`
(camus C1-4) and the `review_stall` gate; our disposition set has nothing between
"fixed" and "failed" for *accepted debt*, and no attempt-cap escalation vocabulary
(rerun caps exist; the terminal they produce is failure-family only).

**Why it matters**: `accept_with_debt` + a severity-counted ledger is the shipped
version of exactly what `done_with_findings` wants to become — the honest middle
terminal, with the ledger answering "what did we wave through, cumulatively?" (a
per-project surface argus's board can show). `reprompt_same` vs `reprompt_new_session`
vs `new_attempt` is also a cleaner retry vocabulary than our binary rerun.

**Adoption sketch**: inside #6's design (rider added to
`docs/plans/unadopted-next-ten/README.md` this dig): adopt `done_with_findings` as
planned, add the waved-through findings to a queryable ledger view (a filter over gate
decisions — no new table; the event log already holds them), and borrow the
attempt-cap → `manual_review`-class escalation as the `review_stall` trigger's
vocabulary. The full 11-action enum stays reference-only — our composer's
fix/verify/infra lanes already partition most of it.

---

## Tier 3 — Garnish

### BO3-1. Workspace-monitor heuristics + the hardened read-only git runner

**Recommendation**: BORROW-REFERENCE, small. `workspace/workspace-monitor.mjs` polls a
task worktree's git state every 30s through an **allowlisted git runner** (only
`rev-parse|rev-list|diff|ls-files|log` with exact arg shapes, `:330-379`) and derives:
stuck ≥10min without progress, stuck-in-rebase (reads `.git/rebase-merge` progress),
≥20-commit rebase → "suggest merge instead", >50 ahead, ≥5 duplicate commit titles
(`:424-508`). **Gap** (verified 2026-07-04): our AgentTracker watches agent/tool state,
nothing watches *worktree git state*; camus C2-4 (last-event-age staleness) is parked.
Fold the git-derived signals (stuck-in-rebase, rebase-commit count, duplicate-commit
titles) into the §12 attention producers when worktrees exist — they detect exactly the
REBASE_SPIRAL class BO1-2 alerts on, from the artifact side. The allowlisted-runner
shape is already our house pattern (ShellCommand analyzer) — a validation cite.

### BO3-2. The committed projection contract

**Recommendation**: BORROW-PATTERN, docs-sized. `infra/projection-contract.mjs`
declares, in one committed artifact: which caches are **live-only**, which stores are
**durable**, which projections exist, and two rules — "All live and replay views must
be rebuilt solely from canonical events normalized by `event-schema.mjs`" and "SQLite
is the durable query substrate; JSONL is the private append-only event journal"
(`:22-23`). **Gap** (verified 2026-07-04): our equivalents live in moduledocs
(`WorkflowStep` "projected read-model", composer projection) and one of them lied until
orca's dig caught it (OR2-4a — the promised step-projection rebuild doesn't exist).
When OR2-4a's `reproject_steps` lands, add a short projection-contract section to
`docs/TRUST-BOUNDARIES.md` (which stores are projections, from what, and the rebuild
command for each) — the checklist that keeps the next "repairable by replaying" claim
honest.

---

## Skip / Already Covered

- **S-1. bosun as platform/dependency** — SKIP. Single-host execution,
  shared-filesystem fleet, JSON stores, and a verification tax (see "Why not adopt");
  argus exists to be the topology bosun doesn't have.
- **S-2. Event ledger as the run substrate** — ALREADY-COVERED, ours stronger where it
  counts: their resume reads an atomic state *snapshot* (`_writeRunDetail` tmp+rename)
  while the "execution ledger" is a parallel audit artifact whose JSON half is
  **rewritten wholesale with no fsync/rename** (`execution-ledger.mjs:1928`) — vs our
  single event-sourced spine with FOR-UPDATE seq allocation, projection-owned status,
  and leases (`workflow_event/changes/allocate.ex:174-195`). Keep as the cautionary
  pair: two stores that can disagree, and a dead in-module SQLite vestige at schema v1
  beside the real v9 (`execution-ledger.mjs:4,17-20`).
- **S-3. Poll-loop gate resume** — ALREADY-COVERED by durable `AgentCase` +
  checkpoint-seeded `GateResume`: their gate/action nodes poll the store every 5s
  in-process, the harness path holds the resume in an in-memory promise a restart
  orphans, per-tool approval throws with **no re-drive** (its retry loop doesn't cover
  `tool_approval_required`, `agent/tool-orchestrator.mjs:226-374`), and resume re-opens
  approved gates (BO1-1). Their throw-and-re-invoke per-tool shape is convergent with
  our `:approval_pending` envelope — a validation cite, not a borrow.
- **S-4. Keyword notification classifier** — SKIP (regex over prose; our typed events
  are the classifier). The delivery shapes are the borrow (BO1-3).
- **S-5. Fleet-over-shared-filesystem** — SKIP; shared Postgres + libcluster supersedes
  (presence files, file locks, and corruption-repair machinery are the tax of not
  having a database). Their deterministic duplicate-claim resolution (coordinator →
  priority → earlier-claim → lexicographic id) is a tie-break vocabulary worth
  remembering if lease contention ever needs one; our CAS leases make it moot today.
- **S-6. The kanban adapter layer itself** — SKIP per FLOW §7's decided native task
  layer; the sync tale is BO1-4. Projects V2 note for the record: it's a mode inside
  the GitHub adapter, not a separate backend.
- **S-7. Telegram/WhatsApp as the client platform** — SKIP (argus §2.6 is React
  PWA + Web Push; Telegram Mini App inherits Telegram's auth quirks — see BO1-3's
  authz-gap negative reference). WhatsApp channel (baileys, QR-paired, P≤2 bridge) is
  real but not our transport.
- **S-8. Heavy-runner "pool"** — SKIP: not a pool (per-lease subprocess, no cap, no
  queue, `workflow/heavy-runner-pool.mjs:346`); our Forge session caps +
  `RunTaskSupervisor` cover the territory — though *our* workflow-launch path is
  uncapped too (`application.ex:155`), worth remembering when automation volume grows
  (FLOW §8's budget already plans the guard).
- **S-9. The two-subsystem worktree split** — SKIP as architecture (legacy
  `WorktreeManager` + live workflow-node path, mutually unaware, different naming and
  registries; even their AGENTS.md routes to the wrong one). The single-`Worktree`-domain
  decision (OVERVIEW §3.1) is the fix; bosun is the drift evidence. Naming details for
  FLOW §4's records: branch `task/<id12>-<slug48>`, dir `task-<token>-<sha1(branch)>`
  (deterministic = reuse key; no counter), recovery suffix ladder timestamp→index→pid;
  teardown force-removes the directory but **branches survive** (middle of the corpus
  teardown spectrum; orca deletes branches, we plan phased+dirty-checked).

## Open questions

- **OQ-1 — Resume-past-the-checkpoint: node-boundary pre-seed or fail-and-replay?**
  Our reclaim fails stranded in-flight runs (honest, at-least-once-safe); bosun
  pre-seeds completed node outputs and re-executes from the failure. Both dodge step
  idempotency rather than solve it. Decide when argus puts runs on worktrees (side
  effects get heavier) or on the first real stranded-run pain: extend checkpoints to
  step boundaries + adopt BO1-1's fences, or keep fail-and-replay with better replay
  UX. Owner: the WS6/argus-era orchestration follow-up, not now.
- **OQ-2 — Does argus §12 adopt an immediate-vs-digest delivery split?** Bosun's shipped
  answer (P≤threshold pages now; the rest lands in a per-window digest + a pinned
  board) is the best solo-operator ergonomics in the corpus, but it adds a delivery
  policy axis the per-event taxonomy (emdash/termic/Xantham merge) doesn't have.
  Decide at slice 1 with the push wiring; leaning yes with kinds (never keywords) as
  the router.
- **OQ-3 — File-overlap: advisory attention or claim-time blocking?** FLOW §12 plans
  advisory (`fileConflicts`); bosun ships blocking-at-claim (BO2-2), orca/myrlin ship
  advisory. Decide at slice 3 (task metadata is the input); leaning advisory default +
  per-project strict mode.

## Dig-brief dispositions

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) (bosun second-wave brief + the cross-cutting six):

1. **Worktree lifecycle manager + recovery state machine** — ANSWERED with corrections
   (BO2-1, S-9): there are **two** parallel worktree subsystems; the live task path is
   the `action.acquire_worktree` workflow node (`.bosun/worktrees/`,
   `workflow/workflow-nodes/actions.mjs:11129+`), not the "centralized"
   `WorktreeManager` (`.cache/worktrees/`, legacy/non-task callers). The "recovery
   state machine" is a 4-state **health telemetry tracker**
   (`healthy|recovered|failing|degraded` + outcomes
   `healthy_noop|recreated|recreation_failed`, `infra/worktree-recovery-state.mjs`)
   — recording, not controlling; actual recovery is inline poison detection
   (missing gitdir, rebase/merge markers, unmerged index → reset with an
   unmanaged-worktree refusal guard) + a workflow-DAG retry lane + stale-branch
   recreation at a ≥200-file drift threshold with branch backup
   (`actions.mjs:10995-11087,11147,12039-12085`).
2. **Execution ledgers with auto-resume-on-restart** — ANSWERED with the load-bearing
   correction (BO1-1, S-2): auto-resume is real, capped, fenced, and owned by one
   process — but it resumes from the **atomic run-state snapshot store**, not the
   event ledger; the "execution ledger" is an audit/replay sidecar (per-run JSON
   rewritten non-atomically + a WAL SQLite mirror), and a third "ledger"
   (`agent/tool-execution-ledger.mjs`) is a 19-line in-memory fan-out. Four stores
   total, mutually unaware.
3. **Does the risk-tiered gate family round-trip?** — ANSWERED: yes in-process, with
   architecture-grade caveats (S-3, BO2-5): four blocking mechanisms + one advisory;
   gate/action nodes round-trip via 5s poll loops; harness stages via an in-memory
   promise + steer wake (lost on restart); per-tool approval throws and never
   re-drives; the run-level governance approval **pauses nothing** (no engine waiter —
   doc drift). Decisions are `{approved, denied}` + note **verbatim-confirmed**
   (`approval-queue.mjs:1182-1185`); "risk-tiered" resolves to three unrelated
   systems, the workflow-action layer being binary risky-detection that is
   **default-off** (env-gated), with gate timeout defaulting to **proceed**. Restart:
   requests survive durably; waiters don't; resumed gates re-open to pending.
4. **Telegram Mini App approval UX** — ANSWERED with corrections (BO1-3): Telegram
   *chat* has **no approve/deny controls** (counts + stage text only; no approval
   keyboard exists); the **Mini App** is the actionable surface (Approve/Deny buttons
   per harness-run card → HTTP resolve → durable resolution + steer wake-prompt), with
   context limited to reason/preview/latest-event text — no diff at the decision
   point. "Sentinel-pushed escalations" conflated two things: the sentinel is a
   monitor-crash watchdog/failover process and **never touches approvals**.
5. **Kanban adapters as the two-way-sync cautionary tale** — ANSWERED emphatically
   (BO1-4): the sync *engine* was deleted from the repo while its template replacement
   still imports the missing module with `continueOnError: true`; the Projects V2
   webhook 503s unconditionally; what remains is per-call adapter I/O + a
   PR-merged→done reconcile + internal-biased drift repair, over a residue of lossy
   round-trips and a first-write/last-read comment bug. The trap FLOW §7 cites is
   real, and terminal.

Cross-cutting: **§5 edit-and-resume** — execution layer verified EMPTY (**subject
21**), engine + HTTP surfaces: `setNodeOutput` has no operator-facing caller,
`/remediate` records `{status:"noted"}` and applies nothing, `/restore` forks a new run
with **workflow-variable** overrides only (outputs re-seeded verbatim), no revision
history anywhere; nearest misses are the variable-override fork and `action.ask_user`,
whose answer-consumption path doesn't exist (writer at `actions.mjs:8932`, no reader —
an unwired half-feature). **Provisioning** — answered (BO2-1). **Naming** — S-9's
records; deterministic-hash reuse vs our `-{n}` counter is the interesting delta.
**Status/attention taxonomies** — the 7-state lifecycle collapse + frozen transition
table + enforcement-bypass lesson (BO1-4); priority + fire-class ordering; the
13-anomaly taxonomy (BO1-2); keyword classification (S-4). **Teardown/stranded work** —
no dirty-check anywhere, `--force` removal with **branch survival**, per-task sweep at
lifecycle end + age-based sweeps (12h/7d) + boot maintenance + a daily-3am hygiene
workflow template mid-migration from the hardcoded sweep; zombie status + retry for
undeletable dirs; foreign-claim guards on release. **Placement/multi-machine** —
single-host execution, period; fleet = shared-filesystem presence + coordinator
election producing routing *hints*; the cloud-workspace lease registry is
backend-less scaffolding (S-5): honest ABSENT for real remote dispatch.

## Scan corrections (mirrored into [../README.md](../README.md))

1. **"114k-line `cli.mjs`"** — bytes, not lines: cli.mjs is 3,219 lines (114KB), a thin
   dispatcher. The monolith character is real but distributed (~787k LOC total; the
   biggest single files are `server/ui-server.mjs` ~31k lines and
   `telegram/telegram-bot.mjs` ~11.8k).
2. **"4 vendor agent SDKs + own 18-provider harness"** — five vendor coding-agent SDK
   executors (claude, codex, copilot, gemini, opencode; a sixth SDK `@openai/agents` is
   voice-only) and **19** provider drivers.
3. **"event-sourced projections … per-run execution ledgers with auto-resume on
   restart"** — auto-resume is real (capped 25/restart, fenced, single-owner) but runs
   off the **atomic state-snapshot store**; the event ledger is a parallel audit/replay
   sidecar whose per-run JSON is not crash-atomic. Four distinct ledger/journal stores
   exist; "ledger with auto-resume" conflates two of them.
4. **"centralized worktree lifecycle manager with stack-detection/bootstrap and a
   recovery state machine"** — two parallel subsystems (the "manager" class is the
   legacy/non-task one; task worktrees run through a workflow action node); the
   recovery "state machine" is a 4-state health telemetry tracker plus inline
   poison-reset logic and a workflow-DAG repair lane. Stack detection/bootstrap
   confirmed (8 stacks, shared-path symlinks).
5. **"risk-tiered action approval, per-tool-call approval — resolve accepts only
   {approved, denied} + note"** — the resolve payload is confirmed verbatim; "risk-
   tiered" overstates: three unrelated risk systems, of which the workflow-action
   layer is binary risky/not-risky and **default-off** behind an env flag, the
   per-tool layer auto-approves low/medium, and gate timeout defaults to
   `onTimeout:"proceed"` (timeout = auto-approve).
6. **"a Telegram Mini App as the phone surface with sentinel-pushed escalations"** —
   the Mini App is the approve/deny surface (real, with wake-prompt steering); the
   Telegram *chat* shows approval counts only. The sentinel is a monitor-crash
   watchdog; its escalations are crash/recovery pushes, never approvals.
7. **"multi-backend kanban adapters (internal JSON+SQLite, GitHub Issues, GitHub
   Projects V2, Jira)"** — registered backends are internal / github / jira /
   **repo-mirror**; Projects V2 is a mode inside the GitHub adapter; the internal
   store is JSON-primary with a SQLite mirror. And the two-way **sync engine is
   deleted** — the module doesn't exist; its workflow-template replacement fails
   silently; the Projects V2 webhook always 503s. The scan's cautionary tale
   undersold: two-way sync didn't just hurt, it was removed.
8. **"mid-session steer/nudge prompt injection as the closest HITL affordance"** —
   confirmed and sharpened: the Claude lane is **true mid-turn injection** (SDK
   streaming-input channel); Codex/Copilot queue to the next boundary. This also
   narrows scan observation 1's "the field converges on steering [at boundaries]" and
   the Chorus-dig claim that the field ships "boundary delivery, never mid-turn" —
   bosun is the one shipped mid-turn lane (vendor-SDK-mediated).
9. **Observation 4's "while building its own harness to leave [the vendor SDKs]"** —
   the internal harness reached its declared Tier-1 parity (sign-off GO 2026-04-20)
   but the vendor SDK executors were **not retired**: both stacks remain wired and
   config-selectable at HEAD.

## Cross-references and dependencies

```
BO1-1 auto-resume fences ────→ future resume-from-reclaim design (OQ-1); taxonomy → MC1-4
BO1-2 anomaly + sentinel ────→ MC1-4 rider; CC1-2 attention feed; argus §12 infra-degraded
BO1-3 delivery shapes ───────→ argus slice 1 (push + digest; OQ-2); §4.4 negative refs
BO1-4 sync tale + task lessons → FLOW §7 slice 3 (validation + schema checklist)
BO2-1 bootstrap symlinks ────→ FLOW §5 slice 2 (composes with OR1-4 + TR1-3 + EM1-1/-2)
BO2-2 scope-locks ───────────→ FLOW §12 fileConflicts / slice 3 (OQ-3)
BO2-3 failover breaker ──────→ next-ten #7 executor seam; MC1-1/MC1-4; SY1-4 vocabulary
BO2-4 mid-turn steer ────────→ FLOW slice 6 CLI adapter reading list (corrects CH1-2 'never')
BO2-5 approval expiry ───────→ XA2-1 fold-in at the slice-1 approvals build
BO2-6 assessment vocabulary ─→ next-ten #6 rider (recorded there 2026-07-04)
BO3-1 monitor heuristics ────→ §12 attention producers, post-worktree
BO3-2 projection contract ───→ OR2-4a companion (TRUST-BOUNDARIES section)
```

**No first-wave doc**: nothing here is adoptable without an argus slice or an
already-queued item — the fold-ins (MC1-4, XA2-1, next-ten #6/#7, CC1-2) are recorded
in their owning docs/queues, and the next-ten #6 rider was added this dig. Collision
note: nothing conflicts with the in-flight queues; BO2-6 lands *inside* next-ten #6,
BO2-3 inside #7's PR-2+, and BO1-2/BO1-3 are argus-slice-1 material feeding the same
attention-feed design CC1-2 anchors.

## Bottom line

1. **BO1-1** — when resume-from-reclaim gets built, bosun is the reference: the fences
   and the unresumable-reason taxonomy are the hard-won part, and its two warts
   (debounced checkpoints, gates re-opening on resume) are the acceptance criteria.
2. **BO1-2 + BO1-3** — argus slice 1's attention loop should take bosun's delivery
   shapes (immediate-vs-digest, live digest, status board) and anomaly taxonomy, wired
   to our typed events — never its keyword classifier — with the sentinel as the
   shipped proof that the "control plane down" push must live outside the control
   plane.
3. **BO1-4** — the two-way-sync rejection in FLOW §7 is now backed by a deleted-in-
   production engine; the task-store lessons (enforce kinds on the resource, provenance
   in the same write, round-trip tests on any external mapping) go into slice 3's
   schema review.
4. The §5 sweep closes subject 21 still empty at the execution layer — and the corpus
   record gains one honest asterisk: mid-turn steering exists in the field exactly
   once, on bosun's Claude lane, via the vendor SDK's streaming input (BO2-4).
