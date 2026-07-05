# Features Worth Borrowing from Chorus

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's §5-design dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md) — trigger pulled early
with the argus review-gate design pass approaching). Source:
`~/workspace/research/pms/Chorus` (Chorus-AIDLC/Chorus — "The Agent Harness for
AI-Human Collaboration"; the AI-DLC methodology as software: Idea → Proposal →
Document + Task DAG → Execute → Verify, "Reversed Conversation: AI proposes, humans
verify"). Pinned: Chorus @ `47b5bb6` (2026-07-02, v0.13.0 — refreshed 2026-07-04, the
default branch is byte-identical to the scan pin; `origin/develop` and four unmerged
branches moved), jido_radclaw @ `609350aa`. Cites are firsthand reads of both trees,
accurate to within a few lines. Shape: ~81k LOC non-test TS/TSX **plus ~73k of tests**
(unusual discipline for near-solo), Next.js 15 App Router + ~30 services, 27 Prisma
models in a 757-line schema (**zero Prisma enums** — every "enum" is a String plus a
comment; `relationMode = "prisma"` — no DB-level FKs), 79 MCP tools over stateless
streamable HTTP, a ~30-file plain-ESM daemon CLI, and three packages (openclaw-plugin —
the daemon reimplemented inside the OpenClaw host; chorus-cdk — AWS ECS/Aurora/
ElastiCache; landing). Maturity: 611 commits 2026-02→2026-07, near-solo (445 Yifei Chen
+ 52 "AutoJunjie" agent commits), a disciplined release train (v0.9→v0.13 in five weeks,
CHANGELOG + blog per release, coverage badge, bilingual docs), and an `openspec/`
spec-driven change process (~57 ratified capability specs) that visibly produced the
recent subsystems. Nothing was built or executed this review — all claims are code
reads.

**License law for this doc — AGPL-3.0**: nothing here may be lifted as code, ever
(the termic rule). Every verdict below is BORROW-PATTERN / BORROW-REFERENCE /
BORROW-RUBRIC — reimplement from the contract in our idioms; schemas are quoted as
facts, not as source.

**Recency warning, load-bearing for this dig**: the subsystems the dig briefs care most
about are 1–3 weeks old at pin — the daemon with interrupt/instruction shipped v0.11
(2026-06-22), `(agent, host, cwd)` addressable instances + pinned `deliver_turn` wakes
v0.12 (2026-06-27), the Codex backend v0.12.1 (2026-06-29) — and three unmerged
branches carrying identical +9,782-line diffs (`feat/turn-interrupted-state`,
`fix/orphan-turn-restart-generation`, `feat/daemon-exit-orphan-turn-integration`) are
actively reworking exactly the orphaned-turn gaps this doc records. Expect CH1-2/CH1-3
mechanics to move; re-pin before citing them in a build decision.

**Doc/code drift found while reading** (calibrates trust): the drift concentrates in
prose docs while the contract docs are clean. Stale — `docs/DAEMON.md` claims Codex is
unimplemented (both backends ship, `cli/daemon-agent.mjs:9`), claims a first-run yolo
`y/N` confirmation (code never prompts — `daemon-permission-mode.mjs:49,54`
unconditionally `needConfirm:false`; the `yoloAckAt` reader exists uncalled), and its
header says reporting is "intentionally NOT done here" above code that wires four real
reporters; `docs/PRESENCE_DESIGN.md` describes only the ephemeral MCP-presence layer
and is silent on the entire daemon-connection registry it predates;
`docs/ARCHITECTURE.md` §7.2–7.4 model an `outputType` proposal that never existed in
code and a six-state idea flow replaced by the derived 3-state model;
`docs/SSE_REALTIME_UPDATES.md` calls Redis future work (it ships) and documents a hook
file that doesn't exist. Clean — `MCP_TOOLS.md`/`PERMISSIONS.md`/`AUTH.md` match the
code exactly, because `permission-map.ts` is enforced as a test fixture that fails on
drift (`src/mcp/__tests__/server.test.ts`) — a doc-drift fence worth noticing in
passing.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — including
one **corpus-level** correction to cross-cutting observation 1),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) §5 +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md)
(MC1-1 resume stack — CH1-2's interrupt/resume composes with it; MC2-4 env-scrub
lesson Chorus fails), [../symphony/FEATURES-WORTH-BORROWING.md](../symphony/FEATURES-WORTH-BORROWING.md)
(SY2-2 blocked-input taxonomy — joins CH1-2's needs-input loop),
[../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md](../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-2 — the Forge `:needs_input` dead-end this dig re-confirmed at today's HEAD, now
with the reply-path spec), [../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md](../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)
(XA1-1 grant-path law Chorus satisfies; XA OQ-1 standing grants — confirmed still open
on our side), and [../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-3/C2-8 — the trust-boundary rubric CH1-1's negative fences feed). Threat-model
weighting as always: personal tailnet — LLM-misbehavior containment and leakage
hygiene over external-attacker hardening.

**Structure note** (multica precedent): a **"Dig-brief dispositions"** section follows
the tiers — the umbrella deliverable requires an explicit answered/contradicted/absent
verdict per standing question. That section plus the scan corrections justify running
past the camus band.

## Determination (TL;DR)

**Nothing to adopt as a dependency — AGPL decides before the architecture does, and on
every axis argus differentiates on, the asymmetry runs our way: no durable event log
(SSE full-refetch, no browser replay), no approval gates (yolo is the daemon default;
headless tool prompts auto-deny, never bridged), no leases (read-time staleness only),
no worktrees (verified exhaustively — zero git anywhere), no push. The haul is still
the corpus's most §5-relevant:** (1) the dig's headline **contradicts a corpus-level
scan claim** — Chorus ships **plan-layer promote-the-edit**: human edits write into the
same JSON the AI drafted and approve materializes those bytes verbatim, the model never
re-invoked; only reject-with-note re-prompts. pms observation 1(b) ("every external
edit re-prompts") is wrong for Chorus, and the argus §5 novelty claim narrows honestly
to the **execution layer** — where this subject verifies empty too (19th in the
streak). Their two missing fences (no approve idempotency — double-approve
double-materializes; no revision history — one overwritten `reviewNote`) become
acceptance criteria for argus §5.4 (CH1-1). (2) The **reverse control channel**
resolves to a pattern triangle argus should adopt — durable turn rows + lossy
fire-and-forget pings + strict per-thread boundary serialization — and a correction:
"instruction injection into a running turn" is **next-boundary delivery, never
mid-turn stdin**. The seams pass then found we're closer than FLOW assumed: our
agent-server mailbox already queues mid-turn messages as next-turn signals, and the
dep ships true mid-run `steer/inject` **unwired** — so the gap is product affordances
(busy-thread messaging, the Forge `needs_input` reply loop, CLI interrupt/resume), not
engine work (CH1-2). (3) The **pinned-wake resolution ladder** — hard/soft pins with
designed offline degradation, and sessions that go **read-only rather than migrate**
when their origin dies — is the field's closest convergence yet with FLOW §2's
nothing-migrates doctrine, plus the worked answer to "pinned instance gone" (CH1-3).
(4) The **identity/liveness split** (durable identity-only instance rows; liveness
always derived read-time from heartbeat rows; generation fencing; conflict-refusal
registration) is the schema reference for the node-bearing Workspace/Worktree
identities OVERVIEW §3.3 plans (CH1-4).

| Part of Chorus | As a dependency | What to take |
| --- | --- | --- |
| AI-DLC pipeline (idea → elaboration → proposal → tasks) | No — AGPL, Node/Prisma, methodology-shaped | CH1-1: plan-gate promote-the-edit mechanics + the draft-accumulate-via-tools shape; their two missing fences as §5.4 acceptance criteria |
| Daemon + reverse control channel | No | CH1-2: durable-turn/lossy-ping/boundary-serialization triangle; interrupt taxonomy (`user`/`crash`, sticky, resume-gating); two-stage group-kill spec (CH3-2) |
| AgentInstance + presence + registration | No | CH1-4: identity/liveness split, sentinels, `connectedAt` generation fencing, conflict-refusal — schema reference for Workspace/Worktree `node` |
| Notification/wake layer | No | CH1-3: the pinned-wake ladder; CH2-3: attention-feed-as-projection-over-activity + per-kind preference toggles; negative: flat model, no severity/caps/debounce/push |
| Task model + verification | No | CH2-1: dual-column advisory-vs-gating acceptance criteria + reset-on-regress; the REST-bypass multi-surface-drift cautionary tale |
| MCP surface + permission matrix | No | ALREADY-COVERED (S-2): registration-time tool withholding is our Consumer allowlist's shape; garnish: per-request recompute; cautionary: ungated write paths |
| Transcript/prompt hygiene | No | CH2-4: structural synthetic-envelope drop + `<system-reminder>` strip at the sink; CH2-5: the HEADLESS_PREAMBLE rubric |

## Why not adopt as a dependency

1. **AGPL-3.0** — a hard no for lifting into this codebase regardless of merit.
2. **Runtime mismatch** — Next.js/Prisma/Node ESM against OTP/Ash/Phoenix; every
   borrow is a translation.
3. **Wrong center of gravity** — Chorus is a methodology product (AI-DLC as software)
   whose agents are external CLIs attached to a board; jido_radclaw is the agent
   platform, and argus grows the board natively inside the event log, gates, and
   tenancy that justify it.
4. **The execution-model asymmetry runs our way.** Live-only realtime (browser
   catch-up is refetch; the v0.13 changelog itself calls it "the existing SSE
   full-refetch"), no gate family anywhere (yolo default, auto-deny for the rest), no
   durable wake queue (deliberate — the turn table is the net), staleness computed at
   read time with no reclaim story for orphaned turns (`running` forever on main), and
   single-user PGlite quirks in local mode. What we'd want from a dependency is
   exactly what it lacks.

## How to read this document

Recommendation vocabulary per the [corpus conventions](../../README.md):
BORROW-PATTERN / BORROW-REFERENCE / BORROW-RUBRIC / FOLD-IN / TRACK / ALREADY-COVERED /
SKIP. Initial inventory — no Status lines. IDs are `CH<tier>-<seq>`; `S-n` skips;
`OQ-n` open questions. Tiers scoped to this codebase: **Tier 1** = load-bearing for a
named argus design decision (§5.4 editors, FLOW §2/§4/§12) or a live gap verified
today. **Tier 2** = lands with a specific argus slice. **Tier 3** = garnish. Per-entry
fields per the house anatomy; every Gap claim verified against jido_radclaw @
`609350aa` on 2026-07-04.

---

## Tier 1 — load-bearing for named argus decisions

### CH1-1. Plan-gate promote-the-edit — the shipped precedent, and its two missing fences

**Recommendation**: BORROW-PATTERN (the draft-edit-approve-materialize contract) +
BORROW-REFERENCE (their gaps are argus §5.4's acceptance criteria). The dig's headline
entry: it **corrects pms observation 1(b)** and re-scopes the argus novelty claim.

**Where in Chorus**: `src/services/proposal.service.ts` — a Proposal is an
incrementally-built container (`documentDrafts`/`taskDrafts` JSON columns), populated
by discrete MCP tool calls (`chorus_pm_create_proposal` creates it *empty*,
`chorus_pm_add_document_draft`/`add_task_draft` accumulate; acceptance criteria
mandatory at add-time, `:1159`). Statuses actually written: `draft → pending →
approved | closed`, reject = `pending → draft` (the schema's `rejected`/`revised`
values are dead — never written). **Edit-while-draft is enforced server-side**: every
draft mutation queries `WHERE status = "draft"` inline (`:1118,1150,1191,1229,1277,
1310`), mirrored client-side as `canEdit = status === "draft"`
(`proposal-editor.tsx:240`). The human edits documents, task fields, ACs, **and the
DAG** (drawing edges writes `dependsOnDraftUuids` with a client-side BFS cycle check,
`proposal-editor.tsx:350-408`). **The promote path**: human edits write into the same
JSON the AI wrote (`updateTaskDraft` → `prisma.proposal.update({data:{taskDrafts}})`,
`:1257`); `approveProposal` (`:755-895`) reads those columns from the fresh row and
materializes them **verbatim** in one 15s-timeout transaction — documents, tasks
(status `open`), AC rows, and DAG edges via a draftUuid→realUuid remap. The model is
never re-invoked. Reject-with-note is the *other* lane: `reviewNote` (required
non-empty) → `proposal_rejected` notification → daemon wake → the agent re-edits its
own drafts. Revoke (`:915-999`) un-materializes: cascade-close tasks, delete
documents, back to `draft`.

**The two missing fences (their gaps, our criteria)**: (a) **no approve idempotency**
— the "only pending" guard lives in the *callers*, not the service; the transaction
updates `WHERE uuid = ?` with no status predicate, so a double-approve
double-materializes (`:772-773`); (b) **no revision history** — approve/reject/
revoke/close all overwrite the same three columns (`reviewedByUuid`/`reviewNote`/
`reviewedAt`); nothing records what the human changed. Also: the draft-side DAG cycle
check is client-only (materialize trusts it; unknown dep targets silently skipped,
`:854`).

**Gap in jido_radclaw** (verified 2026-07-04): our gates remain approve/reject/abandon
with verbatim re-emission — `GateResume` seeds only the decision atom
(`gate_resume.ex:278-284`) and `EmitApprovedPlan` resolves and re-emits the **original**
plan from its `plan_ref` (`reactors/plan_gate.ex:53-79`); `AgentCase` has no
editor/revision-shaped field (`decision_comment` and `details` are the only free-text
surfaces, `agent_case.ex:283-383`); `AgentCaseEvent` types carry no edit/revise
(`agent_case_event.ex:102-110`). No edit path shipped since the OVERVIEW audit
(git-verified). OVERVIEW §5 designs exactly the missing half: `:review` kind, revision
events, head-promotion on resume, `expectedSeq`.

**Why it matters**: the argus §5 claim needed this test. The field's closest editor
**does** promote operator bytes — at a plan-materialization boundary. What remains
genuinely novel in argus §5 is promotion at the **execution layer** (an operator edit
of a *step output* that the next step of a running workflow consumes), plus everything
Chorus's gaps show is needed to do it safely: revision events instead of an
overwritten note, optimistic concurrency (`expectedSeq`) instead of caller-side status
guards, a FOR-UPDATE-fenced decide instead of double-materialize, server-side
validation instead of client-trusted DAG checks. Their shipped UX also validates two
§5.2 choices: per-artifact typed editing (docs vs tasks vs DAG edges) and
edit-locked-to-a-state-guard (`canEdit = draft` ≈ our gate-open window).

**Adoption sketch**: no new machinery — this lands as **design inputs to OVERVIEW §5.4
/ FLOW slice 4** (the trigger the pms README set for this dig, now satisfied): (a) add
two acceptance tests to the §5.4 build — concurrent double-`decideCase` must
single-materialize (our FOR-UPDATE txn should already give this; pin it), and a
revision surviving a reject must be visible in the timeline (their overwritten-note
counterexample); (b) keep reject-as-re-prompt and approve-as-promote as **two
explicitly separate lanes** in the `:review` gate design — Chorus proves both are
wanted on the same artifact; (c) server-side editor-type validation (§5.5's lean)
gets the client-only-cycle-check counterexample as its justification; (d) the
draftUuid→realUuid mapping return is the small garnish (CH3-3).

### CH1-2. Busy-thread instruction delivery + the interrupt taxonomy — FLOW's mid-run-steering answer

**Recommendation**: BORROW-PATTERN (the durable-turn / lossy-ping / boundary-
serialization triangle; the interrupt taxonomy) — with the seams-pass discovery that
our engine already has the hard parts and the field evidence that mid-turn injection
is something nobody ships.

**Where in Chorus**: instruction path — UI send box → `sendInstruction`
(`daemon-instruction.service.ts:373-411`; ≤4000 chars; 409 read-only if the session's
origin connection is offline) → a **durable `pending` `human_instruction` turn** at
the single notification chokepoint → a fire-and-forget `deliver_turn` control ping
carrying only `turnUuid` (`:333-352` — no text on the wire). The daemon's `WakeQueue`
serializes strictly per root-idea key: "the 2nd wake waits for the 1st subprocess to
exit, so we never run two `claude --resume <sameSessionId>` against one session"
(`wake-queue.mjs:6-9`); the instruction runs as a **fresh `--resume` process at the
next boundary — never stdin into a mid-flight turn**. Per-command durability is
deliberate and split: `resume` pre-checks daemon liveness and refuses (400) when
offline so the sticky state survives; `deliver_turn` recovers via reconnect
pending-turn backfill (`backfill.mjs:122-169`); `interrupt` has no net (its target is
dead anyway). Control events are **forked before the wake router** so "an interrupt
… mistaken for a wake … could spawn a new Claude" (`sse-listener.mjs:260-263`).
Interrupt itself: UI confirm dialog → daemon double-check (connection match +
in-memory running child) → two-stage kill — SIGINT to the **detached process group**,
10s configurable window, then SIGKILL group (`process-killer.mjs:35,47-60,146-149`) —
with provenance: an interrupting flag makes the exit report `interruptedReason:
"user"` vs `"crash"`; `interrupted` is a **sticky** execution status that survives
offline reconciliation, and only `"user"` is manually resumable (`"crash"`
auto-recovers via backfill) (`daemon-execution.service.ts:47-56,889-945`). The negative
half, on main: daemon exit kills nothing (detached groups) and ends no turns — an
orphaned `running` turn stays `running` forever (no reaper; the three unmerged
branches are this fix).

**Gap in jido_radclaw** (verified 2026-07-04, the seams pass's chief product):
*boundary delivery already exists at the engine layer* — a message arriving mid-turn
enters the agent server's `signal_call_queue` and runs as a separate later turn
(`deps/jido/lib/jido/agent_server.ex:1044-1057,1446-1490`); cron's `:main` mode
already delivers turns to idle sessions (`platform/cron/dispatcher.ex:51-68`). One
layer down, the dep ships **true mid-run steering unwired**: `Jido.AI.Agent.steer/3`/
`inject/3` queue text into the *current* ReAct run (`deps/jido_ai/lib/jido_ai/
agent.ex:851-876`) — zero callers in lib/ (and `cancel/2`, the graceful advisory
interrupt, equally unwired). What's actually missing is the **product layer**: no
operator surface sends to a busy session with queue visibility; the Forge
`:needs_input` broadcast dead-ends (per-session topic no operator surface subscribes
to; `Forge.apply_input/2` exists with **no caller** — `forge/harness.ex:531-568,
661-663`, CC1-2 re-confirmed today); and agent turns have no graceful
interrupt-then-resume at all — `kill_agent` is `DynamicSupervisor.terminate_child` on
a `restart: :temporary` child (final), and workflow cancel is durable-terminal.

**Why it matters**: FLOW's Chorus brief explicitly asked whether a mid-run steering
primitive belongs in argus. The dig's answer: **adopt boundary delivery as the product
contract** (the field's best analog does exactly this; our mailbox already implements
it), **wire the needs-input reply loop** (their 409-when-origin-offline and
no-text-on-the-ping details are the spec; SY2-2's park-don't-retry taxonomy joins
here), and **adopt the interrupt taxonomy for CLI threads** (composes with MC1-1:
interrupt provenance decides whether the later `--resume` is offered) — while
`steer/inject` stays a wired-when-proven TRACK, because turning it on would *exceed*
every scanned subject and nothing yet demands it.

**Adoption sketch**: (a) slice 1 — surface Forge `:needs_input` as an attention item
and wire the reply: subscribe an operator surface to the per-session topic (or
re-broadcast onto a sessions-level topic), deliver the answer via the existing
`Forge.apply_input/2`; adopt their rule that the ask may carry text but the *reply
path* is authenticated non-model surface only (XA1-1). (b) slice 1 — "message a busy
thread": expose the already-queued `ask_sync` semantics as UX (send + "queued behind
the running turn" indicator; our engine needs nothing). (c) slice 6 — the CLI adapter
adopts the triangle verbatim: instructions/wakes are durable rows first, transport
pings are lossy hints, reconnect backfills from rows; interrupts are two-stage
group-kills with `user`/`crash` provenance gating resume; keep control and wake lanes
structurally forked. (d) OQ-1/OQ-2 park the native-thread interrupt and true
mid-turn steer decisions with named triggers.

### CH1-3. The pinned-wake resolution ladder — placement degradation, worked out

**Recommendation**: BORROW-PATTERN for FLOW §2/§12 — the four-outcome selection
vocabulary and the hard/soft pin split; plus the strongest external validation yet of
nothing-migrates.

**Where in Chorus**: every wake-triggering notification to a daemon agent resolves to
exactly one of `directed | online_first | offline_pin | none`
(`notification-turn.ts:420-424,451-484`). Pin sources are ranked (`:304-356`): a
human-typed `(host,cwd)` mention suffix is a **HARD pin** — offline ⇒ `offline_pin`,
**notify-only, no wake, no fallback** (a deliberate reversal recorded in-code,
`:33-37`); an assignment-inherited instance (task's own, else the root idea's, under a
same-agent guard) is a **SOFT pin** — offline ⇒ graceful un-pin to `online_first`.
`none` (no online connection) creates **no turn** — "a fully-offline target is a
notification-only event; there is NO durable queue" (`:16-18`); recovery is
reconnect-backfill from the turn table. Directed delivery stamps two **transport-only**
fields (`targetConnectionUuid`, `suppressWake`) on the SSE envelope — never persisted
(`:536-562`); non-target instances suppress. A lower-priority **session-origin
upgrade** re-points autonomous idea-anchored wakes to the connection where the idea's
conversation already lives (`:512-533` — the v0.13 fix for wakes landing "on a random
online cwd"). The pin root is the **idea**: proposals/tasks/wakes inherit it
(pin-once-inherit, v0.12). And the sharpest kinship: a session whose origin connection
is gone becomes **read-only, never rerouted** (`SessionReadOnlyError`,
`daemon-session.service.ts:893-969` — because `claude --resume` is cwd-bound); the one
mobility affordance is an explicit, human-driven re-point that the code honestly
labels a cold start (`repointSessionOriginAndSend`,
`daemon-instruction.service.ts:502-639`).

**Gap in jido_radclaw** (verified 2026-07-04): FLOW §2 has placement rules (pinned at
creation, successor-threads not moves, node-offline as first-class UI state) but no
**wake-resolution semantics** for the offline case; our only async wake is cron
(`dispatcher.ex:35-68`), which has no placement ladder; nothing distinguishes a
hard pin (operator said *this instance*) from a soft one (inherited default) anywhere
in the design.

**Why it matters**: argus threads and worktrees are pinned to nodes; automations will
fire at nodes that are asleep. Chorus's ladder is the worked answer to the standing
DIG-BRIEFS question ("what happens when the pinned instance is gone"): degrade
inherited pins visibly, never silently re-route explicit ones, make full-offline a
notification not a queue, and let durable rows — not transport — be the recovery
substrate. Their read-only-not-rerouted session is FLOW §2's nothing-migrates arrived
at independently (with the same escape hatch: an explicit successor, honestly labeled).

**Adoption sketch**: fold into the slice-1 attention/wake design and slice-3
automation bindings: (a) adopt the four-outcome vocabulary for any "run this on that
thread/node" resolution (directed / default-node fallback / pinned-but-offline ⇒
attention item / no-target ⇒ recorded skip — composing with MC2-5's visible-skip); (b)
encode hard-vs-soft pin as a first-class bit on bindings and spawn requests (operator
override = hard, sticky default = soft); (c) keep targeting hints transport-only,
durable intent in rows (our RunPubSub payloads already follow this rule); (d) FLOW §2
gains the session-origin-upgrade idea as "prefer the node that already holds the
conversation" when a soft resolution has ties.

### CH1-4. Instance identity/liveness split + registration fencing — the node-row schema reference

**Recommendation**: BORROW-REFERENCE for OVERVIEW §3.3's node-bearing identities and
whatever node-presence rows argus grows.

**Where in Chorus**: `AgentInstance` is **identity only** — `@@unique([companyUuid,
agentUuid, host, cwd])`, no status, no lastSeenAt; "Liveness is derived from
[connections], never duplicated onto the instance row" (`prisma/schema.prisma:98-117`).
Liveness lives on `DaemonConnection` heartbeat rows and is computed **at read time**
by one predicate: `status === "online" && now - lastSeenAt <= 90_000` (3× the 30s
heartbeat, `daemon-connection.service.ts:36,231-233`). **No background sweeper exists
anywhere** — a hard-crashed daemon's row stays `online` with a frozen timestamp and is
logically offline by the predicate; rows are retained as history, never deleted.
Fencing: `connectedAt` is a per-registration generation token; heartbeats and
disconnects are `updateMany`-gated on it so a stale generation's late abort can't flip
a newer row (`:54-66,711-751`). Registration conflict: a fresh different-process
incumbent at the same `(agent, host, cwd)` ⇒ **refuse, write nothing**, emit
`connection_conflict`; the daemon warns and permanently skips that cwd, exiting
non-zero only if every declared path conflicts (v0.12.1 — replacing silent takeover).
Sentinel discipline is explicit: `host ""` = unknown, `cwd null` = unknown, with the
Postgres NULL-distinct-in-unique-index workaround documented and a migration ledger
for the reconciliation (`schema.prisma:452-467`).

**Gap in jido_radclaw** (verified 2026-07-04): `Workspace` has **no node column** at
HEAD (`workspace.ex:169-223`; identity is tenant+[user]+path, `:245-251`) — OVERVIEW
§3.3 plans adding `node` *into the identity keys*; nothing registers node/instance
presence for threads or worktrees (our node identity exists only at the workflow-lease
layer, `workflow_lease.ex:109`); agent/session registries are node-local
(`SessionRegistry` keyed `{tenant_id, session_id}`, `application.ex:139`).

**Why it matters**: when argus builds Worktree + `Workspace.node`, the tempting shape
is a `status`+`last_seen` on the durable row — Chorus's split is the better contract:
durable rows carry identity, liveness is always derived from a heartbeat source, and
staleness is a read-time predicate (no sweeper to operate; our `ReclaimPooler`
precedent stays scoped to *runs*, where reclaim has work to do). The `connectedAt`
generation fence is the same CAS-fencing family as our WS1 leases, applied to
registration — argus node re-registration should have it from day one, plus
conflict-refusal instead of silent takeover (two nodes claiming one worktree checkout
is exactly this bug class).

**Adoption sketch**: slice 2 — `Worktree`/`Workspace.node` stay identity;
node presence is a separate heartbeat-bearing row (or `:pg`-derived — we have a
cluster; Chorus doesn't), with `effectively_online?/1` as the single read-time
predicate and thresholds derived as k× the heartbeat; adopt generation-fenced
touch/disconnect writes and refuse-and-surface on registration conflict. Skip their
NULL-sentinel contortions — Ash identities let us make every identity component
non-null by construction.

---

## Tier 2 — lands with a specific argus slice

### CH2-1. Dual-column acceptance-criteria verification — and the multi-surface gate-drift cautionary

**Recommendation**: BORROW-REFERENCE (schema shape) for the argus task layer's
review-kind semantics (FLOW §7) + a cautionary tale our chokepoint doctrine predicts.

**Where in Chorus**: `AcceptanceCriterion` rows carry **two independent status
column-sets**: `devStatus`/`devEvidence`/`devMarkedBy*` (assignee self-check,
advisory) and `status`/`evidence`/`markedBy*` (admin verify — the only one the gate
reads) (`prisma/schema.prisma:291-315`). `to_verify → done` requires all `required`
criteria admin-`passed` (`checkAcceptanceCriteriaGate`, `task.service.ts:975-1008`);
any regression out of `to_verify` (except to `done`) **resets every criterion** (both
column-sets) to pending inside a TOCTOU-guarded transaction (`:596-616`). The
cautionary: the gate + human/admin restriction is enforced in the UI action and the
MCP tool but **not** in the generic REST `PATCH /api/tasks/[uuid]` — an agent assignee
can drive `to_verify → done` over REST, bypassing both (`route.ts:113-162`). Verified
divergence, their side.

**Gap in jido_radclaw** (verified 2026-07-04): no task resource yet (seams-confirmed);
FLOW §7 defines review-kind statuses but no acceptance-criteria shape. Our equivalent
*doctrine* is already stronger where it exists — decisions flow through one chokepoint
(`Cases.decide/4`) — which is exactly the discipline whose absence created their REST
hole.

**Why it matters**: when slice 3 builds tasks, the dev-advisory vs verifier-gating
split is the right shape for agent self-reports (an agent's own "passed" must never
gate — the camus C1-3/trust-boundary law applied to acceptance criteria), and
reset-on-regress is the correct staleness rule for re-entering review. The REST bypass
is the evidence entry for the C2-8 review rubric: **every status transition a gate
protects must route through the single service chokepoint** — surface-level guards
drift.

**Adoption sketch**: slice 3 — AC rows (if adopted) get `self_check` vs `verified`
column families with the gate reading only the latter; regression resets both; all
transitions through one Ash action with the guard inside it (change + policy), never
re-implemented per surface. Cite in `docs/TRUST-BOUNDARIES.md` when the task layer
lands.

### CH2-2. Idea-anchored thread identity + derived lineage — the task↔thread datapoint

**Recommendation**: BORROW-PATTERN (derived lineage; anchor-on-the-durable-root) as
FLOW §7 evidence.

**Where in Chorus**: the durable conversation (`DaemonSession`) is keyed
`(agentUuid, sessionId)` where `sessionId` **is the root idea's uuid** (ad-hoc uuid
otherwise) — the thread unit is the idea, not the task; the Claude `--session-id` is
this uuid, so the CLI conversation *is* the idea's thread (`daemon-session.service.ts`;
`waker.mjs:311-320`). Lineage is **derived, never stored**: `resolveRootIdea` walks
task → proposal (`inputType === "idea"`, `inputUuids[0]`) → idea → `parentUuid`… with
a 50-hop bound, visited-set cycle guard, and an honest `ambiguous: true` +
`candidates` when a proposal has multiple input ideas (`lineage.service.ts:83,
211-247`). The wake-serialization lane is the same key — one conversation, one FIFO
lane. Idea status itself is stored 3-state (`open | elaborating | elaborated`) with
the pipeline stage **derived** from proposal/task state at read time
(`docs/idea-derived-status.md` — the accurate spec; the 8-state UI badge is a
derivation).

**Gap in jido_radclaw** (verified 2026-07-04): no task layer; FLOW §7 decided
task↔thread M:N with a one-task-per-thread default. Chorus's shipped practice is the
*other* default — many tasks, one idea-rooted thread — and it works because the
conversation anchor is the **durable root**, not the leaf.

**Why it matters**: two FLOW reinforcements. (1) §7's M:N is validated from the other
side: what must be stable is the *thread's anchor identity*, not the task↔thread
count. (2) §7's computed-blocked decision gets a sibling precedent: derive
presentation states (their 8-state badge, our lanes/kinds) from minimal stored state
rather than persisting them. The bounded, ambiguity-honest derived-lineage walk is the
shape for any provenance chain argus renders (task → thread → worktree → landing).

**Adoption sketch**: design-input only at slice 3 — keep thread identity anchored on
the durable entity that outlives its work items; if argus ever renders a lineage
chain, derive it with a hop bound and an explicit ambiguity flag rather than
persisting provenance rows.

### CH2-3. Attention feed as a projection over the activity stream — with per-kind preference toggles

**Recommendation**: BORROW-REFERENCE for the slice-1 attention build (composes with
CC1-2's read-model); the negative halves are equally load-bearing.

**Where in Chorus**: notifications are mostly **derived from the append-only Activity
stream** — every `createActivity` emits a bus event; a server-side listener maps
`(targetType, action)` → notification kind, resolves recipients per-kind, dedups,
self-excludes, preference-gates, then batch-creates rows
(`notification-listener.ts:17-48,585-653`). Actionable-vs-informational is encoded
**only** by the daemon's `WAKE_ACTIONS` membership (assigned/verified/reopened/
approved/rejected/claimed/mentioned/instruction wake; comments and status-changes
don't — `prompts.mjs:234-273`). `NotificationPreference` is 12 per-kind booleans on
the same polymorphic owner shape (`schema.prisma:665-690`). The unified row itself:
string-typed polymorphic recipient (`user | agent`), free-text `action` (no enum), a
single kind-specific payload column (`instructionText`, write-once denormalized so
the daemon's existing fetch needs no second round-trip), `readAt`/`archivedAt`
(`schema.prisma:628-663`). Negatives, all verified: **no severity column, no
transition-edge dedup on rows, no debounce, no daily caps, no digest, no push of any
kind** (grep-clean across web-push/VAPID/APNs/FCM/service-worker); a dead kind
(`proposal_submitted` — schema/prefs/docs/UI, zero producers); wake delivery
deliberately does **not** mark rows read (`autoMarkRead: false`) so reconnect
backfill re-derives from the unread set.

**Gap in jido_radclaw** (verified 2026-07-04): CC1-2 re-confirmed at HEAD — LoopGuard
halts are LLM-facing + telemetry only, cron failures log-and-auto-disable silently
(`cron/worker.ex:42,236-247`), Forge `:needs_input` broadcasts where no operator
surface listens; no attention read-model, no push (grep-clean our side too).

**Why it matters**: the projection shape is exactly argus's plan — attention items
derived from durable streams (our `WorkflowEvent`/`Audit.Event`/PubSub) by a gateway
listener, never produced by agent behavior (XA1-2 satisfied by construction). Chorus
adds two details the CC1-2 design lacked: **per-kind recipient preference toggles**
(cheap, and the right first knob before severity tiers) and **wake ≠ read** (delivery
to an agent must not consume the human-visible unread state — ours will share rows
between operator and agent consumers eventually). The negatives confirm the corpus
stack (EM/TM/XA delivery rules, severity, caps) remains ours to build — the third
tracker in a row without it.

**Adoption sketch**: slice 1 — the attention feed is a projection over existing
durable streams with per-kind boolean mutes from day one (severity tiers stay the
CC1-2 design); an item's `consumed_by_wake` and `read_by_operator` are separate
facts; the trigger set stays FLOW §12's (run-state triggers Chorus lacks entirely).

### CH2-4. Transcript hygiene at the durable sink — structural filtering, not regex

**Recommendation**: FOLD-IN to FLOW §4's redact-at-the-sink posture.

**Where in Chorus**: the daemon transcript stores **user/assistant text only** (tool
and thinking blocks never persisted) with a 200-message rolling window
(`daemon-session.service.ts:83,1224-1246`); v0.12.1 fixed skill bodies leaking into
transcripts by **structurally dropping synthetic envelopes** (`type:"user"` +
`isSynthetic:true` — a shape match, so real human turns are never affected) with
defense-in-depth stripping of `<system-reminder>` spans (CHANGELOG #373).

**Gap in jido_radclaw** (verified 2026-07-04): FLOW §4 commits to redaction at the
durable sink for CLI threads but hasn't specified *injected-scaffolding* filtering —
our own CLI adapter will pipe Claude Code streams that carry synthetic context
(skills, system-reminders, MCP instructions) which is neither operator content nor
secret, just noise that bloats and confuses the durable transcript.

**Why it matters**: the lesson is the *mechanism* — filter by structural envelope
markers, not content sniffing (their `isSynthetic` flag ≈ our stream-json event
types), with a string-level strip only as belt-and-suspenders. That's the same
root-then-residual layering our ANSI/redaction stack already uses.

**Adoption sketch**: slice 6 — the CLI adapter's transcript normalizer drops
non-conversation envelopes by type before `Security.Redaction` runs; pin with a test
that a skill-bearing session persists zero skill-body bytes.

### CH2-5. The HEADLESS_PREAMBLE rubric + the unbridged-approvals contrast

**Recommendation**: BORROW-RUBRIC (prompt text shape); the posture contrast is the
FLOW §4 justification, recorded.

**Where in Chorus**: every wake prompt is prefixed with a shared preamble — no human
at the terminal, **never** call AskUserQuestion/blocking prompts, route every
human-decision through async Chorus channels (comments/elaboration), with the
`CHORUS_DAEMON_HEADLESS=1` env marker named (`cli/prompts.mjs:44-92`). The posture
underneath: headless Claude **auto-denies** non-preapproved tools ("there's no
interactive prompt to answer", `claude-spawner.mjs:149-164`); `yolo` — the **default**
mode — is `--dangerously-skip-permissions`; `chorus` mode allowlists only
`mcp__chorus__*`. No approval is ever bridged to a human.

**Gap in jido_radclaw** (verified 2026-07-04): our Forge runner prompts don't state
the headless contract explicitly (the runners are one-shot print-mode today, MC1-1);
FLOW §4 designs the opposite posture — CLI ask-rules bridged into the `AgentCase`
inbox — and now has its third field datapoint (multica dispositions Q8, symphony's
reject-map, Chorus's auto-deny) that **nobody bridges**; every scanned product
chooses deny-or-bypass.

**Why it matters**: the preamble is field-tested text for a failure mode we'll hit
the day a composer stage runs a headless CLI (the agent stalls waiting for an answer
that can't come); the env marker is the cheap machine-readable half. And the
unanimous unbridged field sharpens FLOW §4's differentiation: bridging is worth
building precisely because it's what lets the posture default to *ask* instead of
*bypass*.

**Adoption sketch**: add a headless-contract fragment to Forge runner prompt
assembly (never block on interactive input; deposit questions via the platform;
marker env var) when MC1-1 lands; cite the three-datapoint field survey in the FLOW
§4 ask-rules design note.

### CH2-6. Per-backend resume-anchor differences — the Codex thread-id map

**Recommendation**: FOLD-IN to MC1-1 (the resume stack) — one contract, two anchor
ownership models.

**Where in Chorus**: Claude — session id is **client-generated and deterministic**
(the root idea uuid), new-vs-resume decided by probing the on-disk transcript path
(`~/.claude/projects/<escaped-cwd>/<id>.jsonl`, `claude-spawner.mjs:75-94`); no
persisted map needed. Codex — the CLI **mints its own thread id**; the daemon persists
an `anchor → thread_id` map (`~/.chorus/codex-sessions.json`, 0600, atomic
temp+rename), captured from the first `thread.started` event and persisted **only on
a clean fresh run** (`codex-spawner.mjs:89-96,198-201,291-293`; `codex-session-map.mjs`).
Both spawners share one `wake()` contract; the waker's probe inputs are simply ignored
by the backend that owns its own anchors.

**Gap in jido_radclaw** (verified 2026-07-04): MC1-1's sketch (our Forge runners'
native resume) is still unbuilt; it assumed anchor capture per backend but not the
**ownership split** — deterministic-client-id vs CLI-minted-id — which changes where
the anchor lives (nowhere vs durable map) and when it's trustworthy (always vs
clean-fresh-exit only).

**Why it matters**: when MC1-1 lands, the runner behaviour contract should carry
`anchor_ownership: :client | :backend` rather than special-casing codex inline —
Chorus is the second implementation confirming the split is structural (multica's
flag-driven model is a third variant: server-persisted, no probe).

**Adoption sketch**: rider on MC1-1 — add the ownership axis to the runner state
shape; persist backend-owned anchors on our Forge `Session` row (not a dotfile), only
from clean exits, per their rule.

---

## Tier 3 — garnish

### CH3-1. Control-lane/wake-lane structural fork
One-line doctrine from `sse-listener.mjs:260-263`: control frames are forked before
the wake router so a misparsed interrupt can never *spawn* work. Our channel-layer
equivalent (argus §4.2): keep decision/control topics disjoint from work-triggering
topics by construction, not by payload inspection.

### CH3-2. Two-stage group-kill spec
SIGINT to the detached process group (spawn as group leader), configurable grace
window (default 10s, flag > env > config file), then SIGKILL the group; Windows path
honestly marked unverified in-source (`process-killer.mjs:19-23,35-149`). The spec for
the slice-6 CLI adapter's interrupt (and a garnish on our Forge session teardown).

### CH3-3. draftUuid → realUuid materialization mapping
`approveProposal` returns `materializedTasks/Documents` maps so clients correlate
drafts with created rows (`proposal.service.ts:841-895`). Rider for §5.4: `decideCase`
on a `:review` gate should return the promoted revision ref + created-entity ids.

### CH3-4. Copy-session-id human takeover
A one-button "copy the bare `claude --resume` anchor" so a human can take a daemon
conversation over locally (v0.11.1). FLOW §4's CLI threads should keep the same
affordance — the sandboxed session's anchor is operator-visible, so escape-to-local
is one paste (composes with the Forge OAuth file-sync posture; memory:
`project_forge_oauth_file_sync`).

### CH3-5. Secrets-delivery hygiene at spawn
Bearer key in a 0600 tmpfile MCP config deleted after each wake; Codex key via env
never argv; prompt via stdin never argv (`mcp-config.mjs:37-58`, `codex-spawner.mjs:
217-221`, `claude-spawner.mjs:167`). Mostly ALREADY-COVERED by our `Env.scrubbed_port_env`
+ MC2-4 sketch; the take-away garnish is the **cleanup-after-wake** habit for any
per-invocation credential file the slice-6 adapter mints. Negative rider: Chorus does
**no env scrubbing at spawn** (`{...process.env}` wholesale) — multica's exact-name
denylist remains the reference (MC2-4/MC1-1e).

### CH3-6. Mention markup with instance-pin suffix + brand-new-mention dedup
`@[Name](agent:uuid?cwd=…&host=…)` — the pin rides the mention text itself
(`mention.service.ts:32-44`); description edits notify only mentions **not present in
the prior content** (`task.service.ts:1027-1031`). For argus task/thread comments at
slice 3: pin-in-markup is a clean serialization for hard pins, and edit-diff mention
dedup is the transition-edge rule (EM) applied to text.

---

## Skip / Already Covered

- **S-1. Chorus as the control plane / task board** — SKIP. AGPL aside, argus exists
  to put the board *inside* the event log, gates, and tenancy; Chorus's board lives
  beside its agents with neither.
- **S-2. The MCP permission matrix (5×3, registration-time withholding)** —
  ALREADY-COVERED in mechanism: withheld-at-registration is exactly our per-template
  reach allowlist (`Consumer.modules_for_template/3`) and our approval overlay is the
  *risk* axis theirs lacks (`Security.ToolApproval` require-list + patterns + MCP
  default-closed). Garnishes worth noting: per-request recompute means permission
  edits apply next call with no reconnect (our persistent_term policy publish is
  close); their matrix is **capability-shaped (resource:action)** while ours is
  risk-shaped — if argus ever wants agent-facing *capability* scoping (which tools a
  template even sees per project), theirs is the vocabulary. Cautionaries recorded:
  two ungated write tools (`chorus_create_tasks` guard-free by their own docs'
  admission), all `*:read` bits gate nothing, `project:admin` is a dead bit, and the
  matrix binds **agents only** (humans bypass it entirely) — scan corrected.
- **S-3. The yolo-default / auto-deny approval posture** — SKIP as negative
  reference for FLOW §4 (with CH2-5): the daemon defaults to
  `--dangerously-skip-permissions` with a banner instead of the documented
  confirmation; the alternative mode auto-denies rather than asks. Our
  gate-and-bridge design is the deliberate opposite; XA1-1 is satisfied on their side
  only because *nothing* grants at runtime.
- **S-4. Realtime layer (SSE + Redis fan-out + full-refetch catch-up)** —
  ALREADY-COVERED, ours stronger where it counts: no event replay for browsers, no
  `Last-Event-ID`, reconnect = refetch; argus §4.2's durable `workflowEvents(afterSeq:)`
  catch-up survives its third tracker. Garnish: their per-recipient channel naming
  (`notification:{type}:{uuid}`) and count_update cross-device badge sync are fine
  shapes for our channel topics.
- **S-5. PGlite/Redis/CDK/openclaw-plugin infrastructure** — SKIP (different stack;
  our Postgres is already the shared system of record). One honest nod: the embedded
  PGlite port-conflict fix (pre-flight probe + child-exit latch beating a false
  "ready") is a nice boot-race discipline, not applicable here.
- **S-6. Schema looseness: string enums everywhere, `relationMode="prisma"` (no DB
  FKs), company-wide access with no per-project ACL** — SKIP as negative datapoints;
  three of this dig's findings (dead enum values, the dead notification kind, the
  ungated REST transition) are the predictable products. Our Ash constraints,
  DB-enforced identities, and policy layer are the counter-position, kept.
- **S-7. The elaboration Q&A subsystem** (structured rounds, per-question categories
  and issue types, agent-resolve vs human-verify actor split) — SKIP for argus
  (FrontDoor triage + plan gates are our clarification seam), recorded as prior art
  if the composer's premise-elicitation lane ever wants structured rounds.
- **S-8. OpenSpec spec-driven change process** — SKIP as machinery (docs/plans + this
  corpus serve the role here); noted as the visible cause of their contract-doc
  cleanliness (S-2's test-fenced permission map came from it).

---

## Dig-brief dispositions (the standing questions, answered)

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) — disposition ∈ answered / contradicted /
absent, with the entry or evidence that carries it.

**Chorus-specific:**

1. **Proposal lifecycle end-to-end** — ANSWERED (CH1-1), with corrections: statuses
   actually written are `draft/pending/approved/closed` (`rejected`/`revised` are
   dead schema values; reject returns to `draft`); the guard is service-level
   `WHERE status="draft"` (client `canEdit` mirrors it); **approve has no concurrency
   fence** and **no revision history exists** (one overwritten `reviewNote`). The
   edits-re-prompt-the-model seam the brief asked us to map **does not exist on the
   human-edit path** — that path promotes (see observation-1 correction); re-prompt is
   the reject lane only.
2. **Task-DAG visual editing while draft** — ANSWERED (CH1-1): add-edge-only canvas
   over draft JSON (`dependsOnDraftUuids`), client-only BFS cycle check, edges survive
   materialization via draftUuid→realUuid remap (unknown targets silently skipped);
   post-materialization DAG editing also exists (server-side DFS cycle check there);
   the third graph surface (mind map) is read-only navigation.
3. **Reverse control channel** — ANSWERED (CH1-2), with the load-bearing correction:
   instruction "injection" is **next-boundary delivery** (durable pending turn + lossy
   `deliver_turn` ping + per-thread FIFO), never mid-flight stdin; interrupt is
   UI-confirm + daemon double-check + two-stage group kill with `user`/`crash`
   provenance and sticky-`interrupted` resume gating. Assessment for FLOW (the brief's
   ask): argus needs the *affordances*, not an engine — boundary delivery is already
   our mailbox semantics; the dep's true mid-run `steer/inject` sits unwired
   (TRACK, OQ-2); the do-now piece is the Forge needs-input reply loop (CC1-2).
4. **AgentInstance `(agent, host, cwd)` + pinned wakes** — ANSWERED (CH1-3, CH1-4),
   post-scan movement folded in: instances are now a durable **third assignee type**
   with the idea as pin root (v0.12); hard-vs-soft pin degradation; offline target =
   notify-only (no durable wake queue — the turn table recovers); gone-origin
   sessions go read-only with one explicit re-point affordance.
5. **Unified user-or-agent Notification row** — ANSWERED (CH2-3): schema quoted;
   string-typed polymorphic recipient; free-text `action` (no enum, one dead kind);
   **no severity**; wake ≠ read; delivery rules (debounce/caps/digest/push) all
   absent.
6. **The MCP permission matrix** — ANSWERED (S-2): 5 resources × 3 actions = 15 bits
   confirmed verbatim; **79 tools, 42 gated / 37 ungated** (scan's "~81
   permission-gated" corrected twice); grants are two String[] columns on the Agent
   row (role presets ∪ custom bits), recomputed per stateless request, enforced by
   registration-time withholding; **agents only** — humans are outside the matrix
   (scan's "humans or agents alike" corrected).
7. **Verification semantics** — ANSWERED (CH2-1): dual-column advisory-vs-gating AC
   rows; gate reads admin columns only; regression resets both; verify is
   human/`task:admin`-only on two of three surfaces — the generic REST PATCH bypasses
   the gate (their divergence, our cautionary).

**Cross-cutting (every dig):**

1. **§5 edit-and-resume sweep** — ABSENT at the execution layer (grep-honest; the two
   adjacent daemon mechanisms are resume-same-run and boundary chat-injection).
   **Nineteenth subject verified empty.** BUT the **plan layer is PRESENT** — the
   corpus's first shipped promote-the-edit (CH1-1), correcting observation 1(b);
   argus's novelty claim now reads: execution-layer head-promotion, still unclaimed
   by anyone scanned.
2. **Provisioning lifecycles** — ABSENT, cleanly: no git anywhere (grep-verified;
   Codex is spawned with `--skip-git-repo-check`), no workdir provisioning or
   teardown; cwds are pre-existing operator config and function as **addressing**,
   not resources.
3. **Branch/directory naming** — ABSENT (no branches exist); the only naming
   machinery is conversation naming (first `human_instruction` prompt, 60-char
   clamp) and the cwd-escaping rule for Claude's transcript path.
4. **Status/attention taxonomies** — ANSWERED (CH2-2, CH2-3): stored-minimal /
   derived-display statuses (3-state idea + derived 8-state badge — kin to our
   computed-blocked); string enums with dead members on three models; a **flat**
   notification model whose only actionable split is daemon-side `WAKE_ACTIONS`; six
   turn triggers; explicit task-transition table with reset-on-regress. What pings a
   human: entity actions only — **no run-state triggers at all** (no run-failed, no
   needs-input, no blocked-on-you); FLOW §12's set stays differentiated.
5. **Teardown + stranded-work detection** — mostly ABSENT: nothing is provisioned so
   nothing tears down; the one un-materialize affordance is proposal revoke
   (cascade-close tasks, delete documents). Stranded work is real and known: orphaned
   `running` turns persist forever on main (no reaper; executions are hidden at read
   time, not reconciled), with the fix in three unmerged branches — our
   event-log + reclaim spine is the counter-position.
6. **Placement & multi-machine addressing** — ANSWERED (CH1-3, CH1-4): work follows
   the agent's online instances (no scheduler, no capability bidding); explicit pins
   with designed degradation; registration conflict-refusal; sessions never migrate —
   read-only + explicit cold re-point. FLOW §2's nothing-migrates and pinned-placement
   doctrine validated a second time, now from the PM-native side.

---

## Open questions

- **OQ-1 — Graceful interrupt for native threads at v1?** `kill_agent` is a hard
  final kill; the dep's advisory `cancel/2` is unwired; workflow cancel is
  durable-terminal. Chorus's `user`-interrupt → later-resume loop is CLI-shaped
  (process boundaries), and our native turns are cheap to just let finish. Lean:
  defer to slice 6 (CLI threads get interrupt/resume via CH1-2+MC1-1); revisit for
  native threads only if long-turn cancellation becomes a real operator pain.
  Trigger: slice 6 design, or the first operator request to stop a runaway native
  turn that LoopGuard didn't catch.
- **OQ-2 — Wire `steer/inject` (true mid-turn) or stay boundary-only?** Field
  evidence says boundary-only suffices (no scanned subject ships mid-turn; Chorus's
  own affordance is boundary delivery). Wiring `steer` would exceed the field but
  adds a second input path into a running loop — new interruption semantics to
  reason about. Lean: TRACK; trigger = slice-1 busy-thread messaging shipping and
  operators demonstrably wanting text to land *before* the current turn ends.
  *(Connective note, 2026-07-04 pass: the later bosun dig added the field's one
  exception — mid-turn steering shipped exactly once, in bosun's Claude executor
  lane via the vendor agent-SDK streaming-input channel, its Codex/Copilot lanes
  still boundary-queued ([BO2-4](../bosun/FEATURES-WORTH-BORROWING.md), which
  re-verified this entry's engine claims and pinned the CH1-2 locus: the unwired
  current-turn primitive is the `jido_ai` dep's `Jido.AI.Reasoning.ReAct.steer/inject`,
  distinct from base jido's next-turn deferred-signal queue). The lean stands — one
  SDK-mediated exception is not a pattern — but "no scanned subject ships mid-turn"
  now carries that asterisk.)*
- **OQ-3 — Per-kind notification preference toggles vs severity tiers at slice 1?**
  Chorus ships 12 booleans and no severity; CC1-2 designs severity-with-mutes.
  Lean: both are per-kind knobs — start with per-kind mute booleans (their shape,
  trivial) and let severity arrive with the digest/caps work (XA). Decide in the
  slice-1 attention design.

---

## Cross-references and dependencies

```
CH1-1 (promote-the-edit precedent) ──feeds──▶ OVERVIEW §5.4 build (slice 4) + C2-8 rubric
CH1-2 (turn/ping/boundary + interrupt) ──composes──▶ MC1-1 (resume stack), SY2-2 (blocked-input)
      └─do-now slice──▶ CC1-2 (needs_input → attention + apply_input reply)
CH1-3 (pinned-wake ladder) ──feeds──▶ FLOW §2/§12 + MC2-5 (visible-skip admission gate)
CH1-4 (identity/liveness split) ──feeds──▶ OVERVIEW §3.3 node columns (slice 2), WS1 fencing kin
CH2-1 (dual-column AC) ──gated by──▶ argus Task resource (slice 3); cites C1-3 trust law
CH2-3 (projection attention feed) ──lands with──▶ CC1-2 read-model (slice 1)
CH2-4 / CH2-5 / CH2-6 / CH3-2..CH3-5 ──ride──▶ slice 6 CLI adapter + MC1-1
```

**Suggested first wave** (no argus slice required): the **CC1-2 do-today slice just
gained its missing half** — CH1-2(a): surface Forge `:needs_input` as an operator
attention item and wire the reply through the existing-but-callerless
`Forge.apply_input/2`; small, closes a verified dead-end today, and every later CLI
thread inherits it. Two smaller argus-independent pieces join it: CH2-5 (the
headless-contract prompt fragment + env marker, standalone) and the CH2-6/CH3-2
riders recorded against MC1-1's build. Extracted as a grab-ready sequenced queue in
[CH-FIRST-WAVE.md](CH-FIRST-WAVE.md) (sibling doc; per-item done-when criteria + the
reconcile-the-source-entry discipline). Everything else is argus-slice-bound and
correctly waits: CH1-1 is design input for slice 4 (the dig the pms README scheduled
for exactly that moment), CH1-3/CH1-4 for slices 1–2, the remaining Tier-2/3 riders
for slices 3 and 6.

**Collision notes**: nothing collides with the unadopted-next-ten queue (composer/
judgment work). CH1-2 touches the same Forge runner surface as MC1-1 — sequence MC1-1
first (resume is the substrate; interrupt provenance then gates it). CH2-3 must land
*inside* the CC1-2 attention design, not beside it. The FLOW §13 hold-soft item
"review-editor UX (Chorus)" hardens with this doc.

## Bottom line

1. **The §5 novelty claim survives, sharpened**: Chorus ships plan-layer
   promote-the-edit (the corpus's first — observation 1(b) corrected), and the
   execution layer stays empty at subject nineteen. Argus builds head-promotion at
   the execution layer with Chorus's two missing fences — approve idempotency and
   revision history — as named acceptance criteria (CH1-1).
2. **FLOW's steering question is answered cheaply**: boundary delivery is the field's
   contract and our mailbox already implements it; the real work is three
   affordances — busy-thread send, the Forge needs-input reply loop (do-now, CC1-2's
   missing half), and CLI interrupt/resume with `user`/`crash` provenance (CH1-2).
   True mid-turn steer stays a tracked luxury we uniquely already own, unwired.
3. **Placement designs get their evidence**: the hard/soft pin ladder with designed
   offline degradation, read-only-not-rerouted sessions, identity/liveness-split
   instance rows with generation fencing and conflict-refusal — FLOW §2 and OVERVIEW
   §3.3 build on a worked precedent instead of taste (CH1-3, CH1-4).
4. **The differentiators survive their third tracker**: no gates (yolo default,
   auto-deny), no run-state attention triggers, no push, no durable catch-up, no
   provisioning — every axis argus differentiates on is again absent in the field's
   most §5-adjacent product. Build them.
