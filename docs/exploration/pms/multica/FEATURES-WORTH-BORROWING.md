# Features Worth Borrowing from multica

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's priority dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md)). Source:
`~/workspace/research/pms/multica` (multica-ai/multica — "Your next 10 hires won't be
human. The open-source managed agents platform"; a Linear-style issue tracker where
coding agents are first-class assignees, executed by a daemon on operator machines).
Pinned: multica @ `129efb768` (2026-07-04, v0.3.38 — refreshed from the scan's
`1ff99e5af` same-week), jido_radclaw @ `a9629f01`. Cites are firsthand reads of both
trees, accurate to within a few lines. Shape: Go server ~151k LOC (+142k test), 354 SQL
migrations, sqlc + pgx on Postgres 17 (pg_bigm/pg_cron/pgcrypto — **no pgvector**,
correcting the scan); TS ~234k LOC pnpm monorepo (Next.js web, Electron desktop, Expo
iOS, shared `packages/{core,views,ui}`); 14 CLI drivers in `server/pkg/agent/`.
Maturity: 3,903 commits in ~7 months, ~10 human authors + agent committers ("Multica
Eve", "devv-eve"), near-daily tagged releases, bilingual (zh/en) docs with real internal
doc discipline. License: modified Apache-2.0 with Dify-style clauses — internal
single-org use is explicitly exempt from the commercial-license condition (LICENSE §1a),
but house discipline stays patterns-first; nothing here needs their code anyway (Go/TS →
Elixir). Nothing was built or executed this review — all claims are code reads; where
their docs and code diverge, the divergence is recorded (found four: daemon poll default
3s-doc vs **30s-code** `server/internal/daemon/config.go:22`; offline threshold 45s-doc
vs **150s-code** `handler/heartbeat_scheduler.go:98-100`; "webhook triggers have no
endpoint yet" in CLI_AND_DAEMON.md vs a **shipped** webhook ingress
`handler/autopilot_webhook.go:305-343`; product-overview.md is internally dated
2026-04-21 and predates squads entirely).

Companion docs: [../README.md](../README.md) (the pms scan this corrects),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on),
[../../ades/traycer/FEATURES-WORTH-BORROWING.md](../../ades/traycer/FEATURES-WORTH-BORROWING.md)
(worktree schema cribs these mechanics compose with),
[../../ades/emdash/FEATURES-WORTH-BORROWING.md](../../ades/emdash/FEATURES-WORTH-BORROWING.md)
(provisioning practice; ACP costing — multica is now the strongest ACP-adoption
datapoint), [../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md](../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-2 attention-feed gap this doc's negative findings sharpen),
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-3 verdict normalizer that MC1-4 composes with), and
[../../osa/FEATURES-WORTH-BORROWING.md](../../osa/FEATURES-WORTH-BORROWING.md) (OS1-5 —
whose shipped form the seams pass disambiguated from MC1-1). Threat-model weighting as
always: personal tailnet — LLM-misbehavior containment and leakage hygiene over
external-attacker hardening.

**Structure note**: this doc adds a **"Dig-brief dispositions"** section after the tiers
— the umbrella deliverable ([DIG-BRIEFS.md](../DIG-BRIEFS.md)) requires an explicit
answered/contradicted/absent verdict per standing question. That section plus six scan
corrections justify running longer than the camus band.

## Determination (TL;DR)

**Nothing to adopt as a dependency; the corpus's richest validation + reference haul.**
multica is the only scanned product sharing argus's full topology (server Postgres,
multi-device clients, machine-attached execution) at real scale, so its value splits
three ways: (1) **validation** — it independently arrived at pinned placement /
nothing-migrates, visible-skip automation, task-scoped credentials, and
one-spawn-in-flight-per-task, which hardens four argus FLOW decisions; (2) **reference
mechanics** — its CLI session-resume stack, worktree/repocache plumbing, workdir GC
taxonomy, and run-failure taxonomy are the working spec for things we're about to build
(and one thing we already have wrong: our Forge CLI runners re-send accumulated prompts
instead of using native `--resume`); (3) **negative datapoints** — its dependency table
is dead code, its severity model is ~aspirational, its phone app has no push, its
reconnect story is full-refetch, and it remains gate-free (16 subjects, §5 sweep still
empty) — each one a place argus's design is ahead, now with evidence.

| Part of multica | As a dependency | What to take |
| --- | --- | --- |
| Go server + tracker schema | No — Go/TS, tracker-centric, license clause | Schema shapes for the argus task layer (numbering, position, metadata KV, provenance, the one-pending-task fence); the status-enum cautionary tale |
| Daemon (claim/heartbeat/recovery/GC) | No | Prepare-lease, eager session pinning, runtime-gone choreography, GC taxonomy — as reference for argus node behavior; our DB leases already superset the ownership half |
| CLI drivers (`pkg/agent/`) | No | **The resume stack** (MC1-1): flag-driven resume, poisoned-session taxonomy, cwd-keyed resume gating, env-scrub discipline — directly fixes a live gap in our Forge runners |
| Squads / autopilots | No | Leader-protocol prompt rubric; admission-gate + visible-skip + auto-pause breaker for FLOW §8 |
| IM channel engine (Slack/Lark) | No | TRACK — the normalized-envelope + router pipeline shape, if argus ever grows a second IM surface |
| Clients (web/desktop/mobile) | No | Almost nothing — thread-aware comment pagination is the exception (MC1-5); mobile has no push to learn from |

## Why not adopt as a dependency

1. **Wrong center of gravity.** multica is a *tracker that drives agents*; jido_radclaw
   is an *agent platform growing a tracker view* (argus). Adopting it would mean
   operating a second product with its own DB, auth, and clients beside the thing argus
   exists to unify.
2. **Runtime mismatch.** Go + sqlc + gorilla/websocket + Next.js vs OTP + Ash +
   Phoenix. Every borrow below is a translation, none a transplant — the standing rule.
3. **The execution model is thinner than ours where it matters to us.** No durable event
   log (in-process synchronous bus, `server/internal/events/bus.go:61-88`), live-only WS
   with full-refetch reconnect (`packages/core/realtime/use-realtime-sync.ts:1148-1162`),
   no gates, no leases (hub-spoke daemon trust instead). The things we'd want from a
   dependency are exactly the things it doesn't have.
4. **License friction, mildly.** The Dify-style clause exempts internal use, but
   patterns-only keeps the question moot.

## How to read this document

Recommendation vocabulary per the corpus conventions (`docs/exploration/README.md`):
**BORROW-PATTERN** (translate the contract into our idioms), **BORROW-REFERENCE** (their
implementation is the spec for something we build), **BORROW-RUBRIC** (lift evaluative
criteria/prompt text), **ALREADY-COVERED** (cite the local equivalent; take a garnish),
**TRACK** (parked with a named trigger), **SKIP**. Initial inventory — no Status lines.

Tiers scoped to this codebase: **Tier 1** = clear gap, high leverage, buildable against
a shipped seam or a decided argus slice. **Tier 2** = valuable, lands with a specific
argus slice or needs a small design decision. **Tier 3** = garnish. IDs `MC<tier>-<seq>`;
`S-n` skips; `OQ-n` open questions. Per-entry fields per the house anatomy; every Gap
claim verified against jido_radclaw @ `a9629f01` on 2026-07-04.

---

## Tier 1 — High Impact

### MC1-1. Native CLI session resume for Forge runners — the full resume stack

**Recommendation**: BORROW-PATTERN + BORROW-REFERENCE (their edge-case list is the
spec). The one entry that fixes a **live defect-shaped gap today**, before argus.

**Where in multica**: `server/pkg/agent/claude.go:594-596` (`--resume <id>`, flag-driven
— no transcript probing), `:640-645` (`resolveSessionID` clears the reported id when a
resume silently failed, so the daemon's retry can start fresh);
`server/internal/daemon/daemon.go:4253-4262` (**eager pinning** — `session_id` +
`work_dir` persisted server-side the moment the backend emits its first status message,
not at completion; crash mid-run still leaves a resumable anchor), `:3248-3270`
(`gateResumeToReusedWorkdir` — drop the resume pointer whenever the actual workdir ≠
`PriorWorkDir`, because CLI session stores are keyed to cwd, e.g.
`~/.claude/projects/<encoded-cwd>/`), `:3917-3932` (failed resume with no established
session → retry once fresh); `server/internal/daemon/poisoned.go:52-134` (the
**poisoned-session taxonomy**: fallback-marker outputs ≤320 chars → `iteration_limit` /
`agent_fallback_message`; Anthropic `400 invalid_request_error` → `api_invalid_request`
— bad content baked into history, every resume re-hits it; codex semantic-inactivity —
all excluded from the `(agent_id, issue_id)` resume lookup at
`server/pkg/db/queries/agent.sql:501-503`); `handler/daemon.go:1616,1663-1670` (resume
is **runtime-pinned** — a prior session on another machine is never offered);
`claude.go:684-696` (env scrub: **exact-name denylist** — `CLAUDECODE`,
`CLAUDE_CODE_ENTRYPOINT/EXECPATH/SESSION_ID/SSE_PORT` + the `CLAUDECODE_*` prefix —
deliberately NOT the whole `CLAUDE_CODE_*` namespace, which broke Windows by stripping
`CLAUDE_CODE_GIT_BASH_PATH`); `claude.go:102-146` (the stream-json deadlock fix: prompt
written to stdin in its own goroutine while a reader drains stdout; `cmd.WaitDelay=10s`
backstop; `claude_deadlock_test.go` re-execs the test binary as a fake CLI via env);
`codex.go:1076-1133` (`thread/resume` falling back to `thread/start` on protocol errors,
failing fast on transport errors), `:569-596` (MCP config materialized into
`$CODEX_HOME/config.toml` at 0600 — secrets never in argv; **fails closed** when
`mcp_config` is set but `CODEX_HOME` isn't).

**What**: resume a headless CLI's own conversation across process invocations —
flag-driven, eagerly anchored, cwd-gated, with a deterministic taxonomy of
sessions-not-worth-resuming and a clear-id-then-retry-fresh dance when the CLI silently
mints a new session.

**Gap in jido_radclaw** (verified 2026-07-04): our Forge CLI runners are **one-shot
stateless re-invocations** — `forge/runners/claude_code.ex:61-88` builds `claude -p
<accumulated prompt> --output-format stream-json` per iteration and
`forge/runners/codex.ex:90-132` runs `codex exec --ephemeral`; neither ever passes
`--resume`/session ids, so multi-iteration runs re-send the whole accumulated context
every time (token cost grows quadratically with iterations, and CLI-side state — plan
mode, tool caches — is discarded). The `Runner` behaviour already has the seam
(`serialize_state/restore_state`, `forge/runner.ex:24-33`). The osa OS1-5 machinery
shipped 2026-07-03 (`cli/run_command.ex`, `conversations/context_restore.ex`) resumes
**JidoClaw's own conversation layer** — a different axis entirely; the external-CLI
resume slot is empty. Nothing on our side classifies a poisoned CLI session (a resume
that deterministically re-fails just re-fails), and no env scrub runs at Forge CLI spawn
— relevant on the dev box, where jidoclaw itself often runs *under* Claude Code and a
child `claude` inherits `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID` (our
`mcp_stdio_transport_patch.ex` scrubs MCP stdio only).

**Why it matters**: this is the CLI-engine bedrock for argus FLOW §4 (a `:cli` thread IS
a resumed session across turns) — but it also pays today: the memory consolidator and
any composer stage that grows a Forge executor (camus C1-1) inherit cheap multi-turn
runs. The poisoned-session taxonomy is the missing sibling of our shipped Verdict
normalizer: infra ≠ verdict at the judge boundary (camus C1-3), resume-safe ≠
resume-unsafe at the session boundary (this).

**Adoption sketch**: (a) extend `Runners.ClaudeCode`/`Codex` state with `session_id` +
`workdir` captured from the first stream-json `system` event; pass `--resume` (claude) /
`thread/resume` (codex) on subsequent iterations; keep the accumulated-prompt path as
fallback when resume fails (their clear-and-retry-once rule). (b) Store the anchor
eagerly on the Forge `Session` row (`forge/resources/session.ex` `metadata`) — pin at
first event, not at completion. (c) Gate resume on unchanged sandbox workdir (their
cwd-key rule — our sandboxes recreate paths, so this check is load-bearing). (d) Port
the poisoned classifiers as a `resume_unsafe?/1` on the runner result — the
`api_invalid_request` (400-baked-into-history) and iteration-limit-marker cases verbatim;
wire the composer's fresh-vs-resume choice through it. (e) Exact-name env scrub at
sandbox/HostShell spawn for the claude/codex families — lift their denylist and the
not-the-whole-namespace lesson. (f) Lift the deadlock discipline (writer goroutine ≠
reader; bounded stderr tail appended to errors) into the runner's port handling.

### MC1-2. Task-layer schema reference — field shapes for FLOW §7, and the status-enum cautionary tale

**Recommendation**: BORROW-REFERENCE (schema), plus the **divergence evidence** FLOW §7
asked this dig to produce. The hold-soft item ("task schema field details — multica")
can harden.

**Where in multica**: `server/migrations/001_init.up.sql:52-72` + alters (the aggregated
`issue` schema); `020_issue_number.up.sql:2-33` (workspace-scoped `issue_prefix` +
`issue_counter`, incremented under the workspace **row lock** inside the create tx —
`server/internal/service/issue.go:206`; human ref = `MUL-4010`);
`105_issue_metadata.up.sql:8-14` (**agent-writable metadata KV**: JSONB object, ≤8KB
DB-checked, ≤50 primitive keys handler-enforced, single-key atomic writes; the CLI doc's
write doctrine — "most runs write zero new keys — that's the expected case", pin only
what a future run re-reads: `pr_number`, `pipeline_status`, `waiting_on`;
CLI_AND_DAEMON.md §Metadata); `022`/`037` (**one-pending-task-per-issue**: partial
unique index on `(issue_id) WHERE status IN ('queued','dispatched')`);
`042_autopilot.up.sql:75-76` + 060/111/131 (origin provenance: `origin_type ∈
autopilot|quick_create|lark_chat|slack_chat` + `origin_id` — "why does this task exist"
is a lookup); `015_issue_subscriber.up.sql:2-9` (subscriber `reason ∈
creator|assignee|commenter|mentioned|manual`); `001:68` + `issueposition/position.go:17-26`
+ `packages/views/issues/utils/drag-utils.ts:59-67` (position: one FLOAT, server does
top-placement `min−1`, client computes midpoints, ties tolerated with a secondary sort
key); polymorphic actor everywhere (`assignee_type/creator_type/actor_type ∈
member|agent[|squad]`, no FK). The **status model**: fixed global 7-value enum
`backlog todo in_progress in_review done blocked cancelled` (`001:57-58`, never altered;
mirrored in `handler/issue.go:74` and `packages/core/issues/config/status.ts:3-50`) —
**no per-project states, no category/kind layer**; category behavior is hardcoded
*divergently* per call site: terminal = `done|cancelled` (`issue_child_done.go:207-209`),
"work delivered" = `in_review|done|cancelled` (`notification_listeners.go:150-154`),
board hides only `cancelled` (`status.ts:24-31`), search sort order bespoke
(`issue.go:510-519`), and **backlog is a parking lot** — assignment while `backlog` does
not enqueue; promotion out of backlog is the run trigger
(`service/issue.go:409,427`, `issue_trigger.go:14-21`).

**What**: the shipped, load-tested field shapes for exactly the resource argus is about
to design — and the strongest available evidence for two FLOW §7 decisions: (1) fixed
statuses without a semantic-kind layer force category sets to be re-derived (and drift)
at every call site; (2) their `backlog`-gates-automation behavior is our `ready` kind,
hardcoded.

**Gap in jido_radclaw** (verified 2026-07-04): no task/issue/board resource exists
anywhere (`Projects.Project` is metadata-only, `projects/project.ex:75-98`; grep clean).
FLOW §7 has decided the shape (per-project statuses grouped into lanes + a system-owned
seven-kind enum + computed blocked + M:N task↔thread); this entry is the schema-level
reference to pressure-test the *fields* when slice 3 builds it.

**Why it matters**: argus should not re-derive numbering, ordering, dedup-fencing, and
provenance from scratch when a 3,900-commit production tracker publishes working answers
— and the two places argus deliberately diverges (kinds; computed blocked) now carry
evidence instead of taste. multica has **two unrelated "blocked" concepts** (the manual
board status, and the daemon's `TaskResult{Status:"blocked"}` routing sentinel that maps
to task *failure* — `daemon.go:3993-4104` — and never touches the issue) — the naming
collision our kind-vs-status split avoids by construction.

**Adoption sketch**: when slice 3 lands the Task resource — per-project ref =
project-scoped counter incremented under the project row lock (their workspace-lock
pattern, one level down); `position :float` + client midpoints + server top-placement
(skip fractional-index libraries); a partial unique index for one-active-spawn-per-task
(their `022/037` verbatim — FLOW §7's "second spawn queues visibly" needs exactly this
fence); `origin_kind/origin_id` provenance columns from day one; subscriber-reason enum
if/when tasks grow watchers; **metadata KV** as a deliberate OQ (OQ-1) rather than a
default-yes. Statuses/lanes/kinds stay per FLOW §7 — this dig's evidence says the kind
layer is the part multica misses, not the part to trim.

### MC1-3. Stage barriers + notify-the-owning-agent — the shipped dependency answer (and the dead `issue_dependency` table)

**Recommendation**: BORROW-PATTERN (the barrier + parent-dispatch shape) — and record
the negative half as design evidence.

**Where in multica**: `123_issue_stage.up.sql:15` (`stage INTEGER` on issue — ordered
barrier groups among siblings sharing `parent_issue_id`; NULL = unstaged);
`server/internal/handler/issue_child_done.go:68-261` (rollup fires only on a child's
transition **into** terminal `done|cancelled`; backlog parents stay inert (MUL-3497);
human-assigned parents get no auto-comment; `stageBarrierClosed` — stage S closes iff
every staged sibling with `stage <= S` is terminal; on close: a system comment on the
parent + **dispatch the parent's agent** (or squad leader) via the normal task path, with
idempotency keyed on reviewed head SHA `:459-464`). The negative half:
`001_init.up.sql:89-94` defines `issue_dependency (blocks|blocked_by|related)` — and a
repo-wide grep finds **zero** queries, zero API, zero release logic; the Linear-style
mechanical dependency feature shipped as schema and was abandoned. What replaced it in
practice: free-text `metadata` keys (`waiting_on`, `blocked_reason` — recommended by the
runtime prompt, `daemon/execenv/runtime_config.go:628`) that nothing consumes
programmatically, plus the stage barriers above.

**What**: sequencing lives in parent↔children + integer stages; the platform's job on
barrier close is an event + a dispatch to the *owning agent*, which decides what happens
next — not a mechanical status flip on dependents.

**Gap in jido_radclaw** (verified 2026-07-04): no task layer yet (MC1-2); on the
workflow axis our composer already does Kahn-wave mechanical release for *stages*
(`route_composer/router.ex:20-30`), which is the right tool there. The open design is
FLOW §7's task-level dependency release ("start B when A reaches a done-kind status" —
orca's mechanical auto-queue) vs FLOW §6's merge-back doctrine ("the platform emits an
attention item; the **parent's agent** runs the merge"). multica is the production
datapoint that the FLOW §6 shape *generalizes*: they run ALL parent-child continuation
through notify-the-owning-agent, and their mechanical-dependency table is the one that
died.

**Why it matters**: it converts a taste-based FLOW split into an evidenced rule —
mechanical release for machine-plannable graphs (composer waves; sibling stages),
agent-mediated continuation wherever judgment lives (what to do now that the children
are done). And the barrier details are subtle enough to be worth lifting verbatim:
into-terminal-only edges (no re-fires), inert backlog parents, idempotency anchored to
the reviewed artifact (head SHA), humans opted out of auto-dispatch.

**Adoption sketch**: at slice 3/5 — sub-task groups get an optional `stage :integer`;
the system behavior bound to the `done`-kind (FLOW §7) implements
`stage_barrier_closed?` with their closure rule; on close, emit the attention item +
enqueue a turn for the parent thread's agent (our `SendToAgent`/successor-thread
machinery) rather than auto-flipping dependents; idempotency via a
`(parent_task, stage, artifact_ref)` uniqueness key. Keep orca-style mechanical release
only for the explicit `done-kind releases dependents` edge FLOW §7 already scoped.

### MC1-4. Run-failure taxonomy with retryable / resume-unsafe subsets

**Recommendation**: BORROW-RUBRIC — the taxonomy and its two derived sets, near
verbatim. Composes with the shipped Verdict normalizer; adoptable now.

**Where in multica**: `server/pkg/taskfailure/failure.go:19-175` — 21 canonical
`failure_reason` values in two groups: 7 platform-side (`queued_expired`,
`runtime_offline`, `runtime_recovery`, `timeout`, `iteration_limit`, `agent_blocked`,
`api_invalid_request`) and 14 agent-side under an `agent_error.` prefix
(`provider_auth_or_access`, `provider_quota_limit`, `provider_capacity_or_rate_limit`,
`provider_server_error`, `provider_network`, `process_failure`,
`empty_or_unparseable_output`, `agent_timeout`, `context_overflow`, `missing_config`,
`model_not_found_or_unavailable`, `runtime_version_unsupported`,
`runtime_missing_executable`, `unknown`); `classify.go:43-216` (ordered
most-specific-first substring classifier; the SQL CASE is documented as source of truth);
`failure.go:234-247` (`AllReasons()` pre-warms Prometheus labels so dashboards don't
discover values lazily); `service/task.go:1911-1927` — the payoff: **`retryableReasons`
= {runtime_offline, runtime_recovery, timeout, codex_semantic_inactivity}** (auto-retry
eligibility) and **`resumeUnsafeFailureReason` = {iteration_limit,
agent_fallback_message, api_invalid_request, codex_semantic_inactivity}** (whether the
session anchor may be promoted) are *distinct subsets* — retry-the-work and
reuse-the-conversation are independent decisions. Honest wart, theirs: `agent_blocked`
is defined but has **no producer** (`failure.go:89-92`; grep-verified) — the
"agent asked a human" classification is aspirational even here.

**What**: one canonical, closed vocabulary for *why an agent run failed*, with
platform-vs-agent provenance in the name and policy (retry? resume?) derived from
membership — never from string-sniffing at decision sites.

**Gap in jido_radclaw** (verified 2026-07-04): the pieces exist, the vocabulary doesn't.
`Orchestration.Verdict` (camus C1-3, shipped) normalizes *judge outputs*; Forge runners
return `:blocked | :error` with free-form reasons (`forge/runner.ex:15-22`); LoopGuard
classifies failure *signatures* for loop detection; the composer separates
`route_verify_failed`/`route_fix_failed`; but no module names the failure classes of an
agent run, and retry decisions live in scattered `retry: false` envelope flags. hermes
T1-4 (`FailoverReason`, provider-level) is still NOT_ADOPTED — this is its
narrower, independently-adoptable core, arriving from a third direction (camus C1-3 →
crabbox CB2-1 → this).

**Why it matters**: MC1-1's resume machinery *needs* the resume-unsafe set to exist;
argus's attention feed (FLOW §12 "run failed" trigger) needs stable failure kinds to
dedupe and rate-limit on; and the retryable-vs-resume-unsafe split is precisely the
distinction our composer's infra-lane work keeps re-deriving locally.

**Adoption sketch**: `JidoClaw.Orchestration.RunFailure` (or extend `Verdict`'s home):
the enum (drop daemon-specific members, keep the platform/agent prefix split), a
`classify/1` for raw runner/provider errors (ordered, most-specific-first, table-driven),
and the two derived sets as functions — then consume it from Forge runner terminal
results, the composer's Lane-B infra decisions, and (later) the argus attention feed.
Pre-warm telemetry labels the way they do. Wire `resume_unsafe?/1` into MC1-1.

### MC1-5. LLM-context-shaped feed pagination — thread reads designed for agent prompts

**Recommendation**: BORROW-PATTERN. The only client-side Tier-1; nothing else in the
corpus paginates *for the model*.

**Where in multica**: CLI_AND_DAEMON.md §Comments (the contract, verbatim flags) backed
by the comment handlers: `--thread <id> --tail N` returns the N most recent replies but
**always includes the thread root** ("so an agent landing on a long thread keeps the
'what is this about' context without dragging hundreds of replies into its prompt" —
even `--tail 0`); `--recent N` returns the N most-recently-active *threads*, whole,
**oldest-active first "so the freshest thread sits closest to 'now' in an agent
prompt"** (prompt-position-aware ordering); `--since <ts>` incremental polling exempts
the root; cursors are **dual-scope by design** (same flags walk older *threads* under
`--recent`, older *replies* under `--thread --tail`), emitted on **stderr**
(`Next thread cursor: --before <ts> --before-id <id>`) so stdout stays parseable;
cursor emission is suppressed at exact-boundary pages and once the cursor target falls
behind the `--since` watermark, so callers stop paginating instead of fetching
root-only pages; flat `comment list` hard-caps at 2000 rows and the docs steer agents
to the thread-aware reads.

**What**: feed APIs whose pagination unit, ordering, and inclusion rules are chosen for
what lands well in a context window — root-always-included, freshest-nearest-the-end,
stop-signals built into the cursor protocol.

**Gap in jido_radclaw** (verified 2026-07-04): our agent-facing feeds are byte-paginated
(`workflow_events` — raw `after_seq`/`limit`), line-sliced (`fetch_output`), or absent
(no tool reads a conversation/comment thread shape at all; `Conversations.Message` is
sequence-ordered rows consumed by the compactor, not by tools). Argus threads (FLOW §4)
and task comments (FLOW §7) will both need agent reads; the composer's premises context
already fights prompt-position problems by hand.

**Why it matters**: every argus surface where an agent catches up on a conversation —
successor threads, merge-back attention items, task comment triggers — has this exact
shape. Getting root-inclusion and recency-position right at the API layer beats
re-teaching every prompt to cope.

**Adoption sketch**: when the argus thread/task read tools land (slice 1/3): a
`thread`-mode read (`anchor id` walks up to root; root always included; `tail: n`),
a `recent`-mode read (whole threads, oldest-active-first), `since:` watermark exempting
roots, and cursor metadata that goes silent at boundaries. Same rules for `lua_query`'s
eventual conversation binding. Their stderr-cursor trick maps to our envelope metadata
fields (`clipped`/`selected_lines` precedent in `fetch_output`).

---

## Tier 2 — Valuable, lands with a specific slice or decision

### MC2-1. Pinned placement validated; the runtime-gone recovery choreography

**Recommendation**: ALREADY-COVERED (ownership/failover — our DB leases + CAS fencing +
reclaim are strictly stronger) with a BORROW-REFERENCE garnish for the *node-agent-side*
choreography argus hasn't built yet.

**Where in multica**: placement is **pinned, never scheduled** — each agent row carries
`runtime_id`; every task for that agent goes to that runtime
(`service/task.go:661-692`); wakeup delivery is runtime-targeted
(`daemonws/hub.go:330-356`); session resume refuses to cross runtimes
(`handler/daemon.go:1616`). No least-loaded, no capability bidding. The recovery
choreography: `prepare-lease` heartbeats every 15s while a task provisions
(`daemon.go:3389`, migration 124) so slow setup isn't reaped as stalled; on daemon
restart, `RecoverOrphans` fails-and-retries everything the server still attributes to
that runtime (`handler/task_lifecycle.go:24-56`); runtime-deleted-server-side arrives as
a heartbeat ack status (`runtime_gone`) rather than connection teardown
(`protocol/messages.go:139-173`); re-registration is **coalesced** (30s window collapses
a stampede to one `/register`, `daemon.go:305-413`) and the register **response is
authoritative-replace**, not append (`daemon.go:550-597`) so partial deletions don't
duplicate survivors; orphan sweeper thresholds: dispatched >300s, running >2.5h, stale
heartbeat ~150s (`heartbeat_scheduler.go:98-100`).

**Gap in jido_radclaw** (verified 2026-07-04): the server half is covered —
`WorkflowRun` leases (`claimed_by/claim_token/claim_expires_at`,
`workflow_run.ex:403-413`), token-fenced reclaim (`workflow_lease.ex:271-293`),
always-on `ReclaimPooler`, durable-decision-first cross-node cancel
(`cancellation.ex:168-195`). What we don't have: any *provisioning-phase* liveness
(worktree setup under FLOW §5 will be slow — nothing distinguishes "provisioning" from
"stuck", which is exactly what their prepare-lease encodes; traycer TR1-3's
`setup_status` is the state half, this is the liveness half), and Forge sessions carry
**no DB lease at all** (claim is Registry/process-level, `harness.ex:155-168` — an
asymmetry vs the run-lease model that argus's CLI threads will inherit).

**Why it matters**: FLOW §2's nothing-migrates doctrine now has a shipped, at-scale
precedent — the fastest-moving product in the corpus never built placement scheduling
and doesn't miss it. The garnishes close real holes in the argus §5 provisioning design.

**Adoption sketch**: slice 2 — worktree provisioning gets a lease-renewed
`provisioning` phase (reuse `WorkflowLease`'s sidecar shape) distinct from
`setup_status`; slice 6 — Forge sessions backing CLI threads gain the same DB-lease
columns runs have (close the asymmetry before threads depend on it); adopt
coalesced-reregister + authoritative-replace semantics in whatever node-agent
re-registration argus grows.

### MC2-2. Workdir GC taxonomy — full / orphan / artifact-only, with a sidecar meta file

**Recommendation**: BORROW-PATTERN for argus FLOW §5 teardown.

**Where in multica**: CLI_AND_DAEMON.md §Workspace-GC + `daemon/gc.go`: three modes —
**full** (issue terminal + idle > 24h → remove the task dir), **orphan** (no
`.gc_meta.json` sidecar, e.g. daemon crashed before writing it → remove after 72h by
mtime), **artifact-only** (issue still open, task done > 12h → delete only regenerable
build outputs matching basename patterns `node_modules,.next,.turbo`, preserving source,
`.git`, `output/`, `logs/` **so the agent can resume the same workdir**). Safety
contract: basename-only patterns (entries containing separators silently dropped),
never descend `.git`, never follow symlinks, containment-check every path
(`gc.go:471-541`). The sidecar (`.gc_meta.json`, `execenv.go:502-548`) records
parent-record kind (issue/chat/autopilot_run/quick_create) + id + completed_at, so GC
decisions survive daemon restarts and dispatch per-kind (`gc.go:214-229`). Liveness
guard: a **ref-counted** in-memory `activeEnvRoots` mark, with an *outer* mark spanning
result-reporting + meta-write specifically to close the crash-window race
(`daemon.go:2884-2894`, `workdir_race_test.go:248-320`). Worktree-side GC is separate:
`git worktree prune`, then delete `agent/*` branches not attached to any live worktree,
then (only if something was deleted) `reflog expire` + `git gc` (`gc.go:573-679`).
Stranded PRs: **not detected** — honest not-found on their side too.

**Gap in jido_radclaw** (verified 2026-07-04): no worktrees yet; Forge sandbox cleanup
is lifecycle-scoped, not TTL-scoped. FLOW §5 says "deletion is phased and dirty-checked"
(TR2-1/MX2-2) but has no shape for *passive* reclamation — the disk-pressure reality of
worktree-per-task on small tailnet nodes.

**Why it matters**: the artifact-only middle mode is the insight — it reconciles
"preserve for resume" (MC1-1 workdir-keyed sessions!) with "don't fill the disk", which
neither full-delete nor keep-everything does. The sidecar-metadata + refcount pattern is
the crash-safe version of "is anyone using this directory".

**Adoption sketch**: slice 2 teardown — worktree rows already know their parent
(DB beats sidecar files for us), but adopt: the three-mode taxonomy with per-kind TTLs
in project settings; artifact patterns per project (their default list + `_build`,
`deps`, `node_modules`); never-descend-`.git` + containment checks verbatim in whatever
shell runs the delete; a lease/refcount check before any removal (our `Workspace`
anchor + worktree lease stand in for `activeEnvRoots`); orphaned `agent/*`-style branch
reclamation as part of per-node housekeeping (FLOW §2).

### MC2-3. Repocache + worktree mechanics — the git plumbing reference

**Recommendation**: BORROW-REFERENCE for the argus Worktree domain (OVERVIEW §3.1, FLOW
§5) — read alongside traycer's schema cribs and OpenSymphony's `workspace.ex`.

**Where in multica**: `daemon/repocache/cache.go` — **bare clone, deliberately not a
mirror**: `git clone --bare` then remote-tracking refspec
`+refs/heads/*:refs/remotes/origin/*` (`:306-314`), with the stated rationale that
`refs/heads/*` in the cache is **reserved for per-task worktree branches** — a mirror
fetch into `refs/heads/*` would collide with worktree-locked refs and abort
(`:306-311`); per-repo mutex serializes clone/fetch/add/GC (`:133`); fetch-on-every-
worktree-create, **non-fatal** on failure ("agent will see possibly stale code",
`:455-463`); branch template `agent/{sanitized-agent-name}/{8-char-task-id}`
(`:487-488`), collision → literal-`"a branch named"` match only (path collisions
deliberately not retried, would leak branches) → single retry with a unix-timestamp
suffix (`:600-641`); worktree reuse = `.git`-**file** check, then `reset --hard` +
`clean -fd` + fresh branch off base (`:654-683`) — uncommitted prior-task work is
discarded by design; default-branch resolution ladder (`origin/HEAD` → `main|master` →
bare-HEAD-mapped → single-candidate scan that **refuses to guess** at >1, `:711-778`);
agent config files kept out of diffs via `.git/info/exclude`
(`.agent_context`, `CLAUDE.md`, `AGENTS.md`, `.claude`, `.opencode` — `:54,502`);
co-author trailer via a `prepare-commit-msg` hook installed in the **bare repo's shared
hooks/** so every worktree inherits it (`:824-846`). The surprise: worktrees are
**agent-initiated** — `execenv.Prepare` leaves the task workdir empty
(`execenv.go:184-185`) and the agent CLI calls `multica repo checkout` against a
daemon-local HTTP endpoint (`daemon/health.go:157`) to materialize a worktree on demand.
Also: `daemon/execenv/git.go` — the file the dig brief named — is a **dead-code
duplicate** with zero callers.

**Gap in jido_radclaw** (verified 2026-07-04): zero worktree code (grep: one flag token
in `security/shell_command/git.ex:150`). FLOW §2/§4 already specify bare clones +
per-node worktree dirs + two naming templates with a `-{n}` counter.

**Why it matters**: the bare-not-mirror refspec rationale, the collision-match
discipline, and the refuse-to-guess default-branch ladder are exactly the sharp edges a
from-scratch implementation hits in week two. The agent-initiated-checkout model is a
genuine *alternative* to FLOW §5's eager provisioning — worth knowing, not adopting
(argus worktrees are durable first-class residents; theirs are task-scoped disposables —
different lifecycle, same plumbing).

**Adoption sketch**: slice 2 — implement FLOW §4's templates over their plumbing:
bare clone with the remote-tracking refspec verbatim; per-repo serialization (a
per-project GenServer or advisory lock on the bare path); fetch-before-create with
non-fatal degradation *logged as an attention item* (our posture: visible, theirs:
log-only); collision handling stays FLOW's `-{n}` counter (their timestamp suffix is
the worse UX); lift `.git/info/exclude` agent-file hygiene and the shared-hooks
co-author trailer as project settings; default-branch ladder verbatim including the
refusal case.

### MC2-4. Credential & env hygiene at the execution boundary — four garnishes

**Recommendation**: BORROW-REFERENCE garnishes onto existing posture (threat-model
weighted: these are leakage-hygiene items).

**Where in multica**: (a) **task-scoped tokens**: every task carries a single-purpose
`mat_`-prefixed token (`task_token`, migration 108) injected as `MULTICA_TOKEN`; the
daemon **refuses to fall back to its own PAT** when a task arrives without one
(`daemon.go:57-66, 3695-3712`) — scope decays from operator → daemon (`mdt_`) → task
(`mat_`). (b) **custom-env blocklist**: user-supplied `custom_env` may not override
`MULTICA_*`, `HOME`, `PATH`, `CODEX_HOME`, `CURSOR_DATA_DIR`, `OPENCLAW_*`
(`daemon.go:4641-4651`). (c) **secrets out of argv**: codex MCP config with embedded
env secrets is materialized into `$CODEX_HOME/config.toml` at 0600 instead of flags —
"would otherwise leak into ps/logs" — failing **closed** when `CODEX_HOME` is unset
(`codex.go:569-596`); user `-c mcp_servers.*` overrides are stripped so the managed
config stays authoritative (`:148-198`). (d) **argv-only custom runtimes**: operator-
defined runtime profiles are `exec.Command(command_name, fixed_args...)` — **no shell**,
no pipes, no `$VAR`, ever (docs/custom-runtimes.md), with per-machine absolute-path
pinning instead of PATH trust.

**Gap in jido_radclaw** (verified 2026-07-04): partially covered with different shapes —
`Env.scrubbed_port_env/1` default-denies host secrets for MCP stdio subprocesses;
FLOW §4 already designs per-Forge-session scoped tokens (mint at start, dead at end) —
multica is its shipped precedent, including the refuse-fallback rule FLOW hasn't stated;
`ShellCommand.analyze/1` gates shell reach but Forge runner argv construction has no
secrets-in-argv review; nothing pins interpreter/CLI binaries by absolute path.

**Why it matters**: each is a one-line-of-doctrine item that prevents a real leak class
on a tailnet where the adversary is a misbehaving model with `ps` access.

**Adoption sketch**: fold (a)'s refuse-fallback rule into the FLOW §4 sandbox-token
design as a stated invariant; audit Forge runners for secret-bearing argv (the codex
`config.toml` trick maps to our sandbox file-materialization path); adopt (b)'s
blocklist shape in Forge `custom_env` handling (we already blocklist for MCP);
consider (d)'s no-shell rule for any operator-defined runner config argus grows.

### MC2-5. Automation admission gate, visible skips, auto-pause breaker, deferred escalation

**Recommendation**: BORROW-PATTERN — the FLOW §8 cron/automation slice, pre-validated.

**Where in multica**: `service/autopilot.go:205-206, 829-897` (**admission gate at
trigger time**: assignee archived / runtime missing / runtime offline → record a
`skipped` run **with a reason** instead of enqueueing doomed work; skips excluded from
failure-rate math `autopilot.sql.go:1131-1143`); occurrence idempotency per
`(trigger_id, planned_at)` via partial unique index + crashed-run slot release
(`autopilot.go:74-156`); missed-fire **catch-up collapses to the most recent
occurrence** except retry-eligible failed buckets (`jobs_autopilot.go:249-303`, bounded
by a 24h replay window); the **auto-pause circuit breaker** as a separate monitor —
lookback 7d, min 50 runs, fail-ratio 0.9 → `SystemPauseAutopilot` + an inbox item +
a broadcast carrying `reason=auto_paused_high_failure_rate`
(`cmd/server/autopilot_failure_monitor.go:37-45, 114-266`); autopilot tasks **excluded
from generic auto-retry** — the schedule owns its own cadence (`task.go:1937-1961`).
Adjacent, same spirit: the **deferred escalation fallback** — a human reply routed to a
thread-parent agent also enqueues a `deferred` fallback task for the issue assignee,
firing after 5 minutes unless the primary starts, cancelled on primary start
(`comment.go:1447-1460`, `task.go:799, 1447-1510`, migration 128) — timeout-based
re-routing so an unresponsive agent can't strand a human's reply.

**Gap in jido_radclaw** (verified 2026-07-04): our cron (`cron/resources/job.ex` +
`platform/cron/worker.ex`) has **no admission gate, no visible skip, and no breaker** —
a 3-strike consecutive-failure counter auto-disables (`worker.ex:42, 236-247`) with
telemetry only (no operator surface — the CC1-2 gap again); overlap is implicit
(synchronous dispatch serializes a job against itself); missed ticks are swallowed
(`worker.ex:159-185`). FLOW §8 already *decided* skip-and-record + breaker + "every
fire explainable"; nothing implements it.

**Why it matters**: FLOW §8's design is validated nearly clause-for-clause by the
fastest-moving comparable — including the subtle parts (skips excluded from breaker
math; schedule-owned retry). The deferred-escalation shape is new material for FLOW
§12's `ended_blocked` family: a *platform* answer to "the agent owing a reply never
came", which multica needed precisely because its agents' blocked-reporting is
otherwise self-declared (see dispositions, Q8).

**Adoption sketch**: slice 3 — cron/binding fires pass an admission gate (target
thread's node offline, worktree lease busy, agent archived → recorded skip row with
reason kind, surfaced in the attention feed); breaker as a leader-owned monitor over
recorded outcomes (ratio + minimum-N + lookback from project settings) that pauses the
binding and raises an attention item; catch-up policy = collapse-to-latest with an
explicit replay-window bound; deferred-escalation as a `fire_at`-style parked turn our
scheduler promotes, cancelled by primary progress — graft onto the FLOW §12 triggers
when slice 1 wires them.

### MC2-6. Squad leader protocol — the delegation prompt rubric

**Recommendation**: BORROW-RUBRIC (prompt text + two anti-patterns), for our sub-agent
fan-out prompts and FLOW §6.

**Where in multica**: squads are a **routing object, not an agent and not auto-fan-out**
— all squad work enqueues ONE leader task (`service/task.go:728-741`); delegation is
prompt-injected at claim time: `squadOperatingProtocol` + roster + optional squad
instructions (`handler/squad_briefing.go:112-125`). The protocol verbatim
(`squad_briefing.go:20-97`): "you have been activated as a squad LEADER … Your job is to
**coordinate**, NOT to do the work yourself … doing it yourself defeats the entire
purpose of the squad and is a protocol violation"; ordered duties — pick member by
*skills* match, delegate via one terse @mention, **record an evaluation every turn**
(`multica squad activity <issue> action|no_action|failed --reason`), **stop after
dispatching** ("You will be re-triggered automatically when: a delegated member posts an
update … finishes … someone @mentions you again"), re-evaluate on each trigger. The
sharpest rule is the anti-double-trigger: "A child issue you create with `--status todo`
and an agent assignee **already fires that agent** — the assignment IS the trigger. If
you also @mention the same agent … the agent runs twice in parallel … Pick exactly one
path … Never both." Guards: leader self-trigger suppression on its own comments
(`comment.go:1734, 1808-1813`, MUL-4024), per-(issue,agent) pending-task dedup. Honest
not-found on their side: **no caps** on member count or delegation fan-out — bounded by
prompt discipline alone.

**Gap in jido_radclaw** (verified 2026-07-04): our fan-out has the *mechanical* caps
theirs lacks (`spawn_agent.ex:295-335` — max_children 8, max_depth 1; Forge per-runner
caps; LoopGuard budgets) but none of the *coordinator doctrine*: `SpawnAgent`/
`SendToAgent` prompts don't teach stop-after-dispatch, re-trigger contracts, or
the assignment-vs-mention double-fire hazard (ours: spawn-vs-send duplication), and
nothing asks the coordinator to record a per-turn evaluation.

**Why it matters**: FLOW §6's fan-out and the composer's judge/worker cohorts both put
an LLM in the dispatcher seat; multica's protocol text is field-tested language for the
two failure modes we'd otherwise rediscover (leader does the work itself; leader
double-triggers a worker). Their no-caps gap validates keeping our mechanical caps
underneath the doctrine, not instead of it.

**Adoption sketch**: lift the protocol skeleton into a coordinator prompt fragment for
spawn-capable templates (coordinate-don't-execute, one-dispatch-then-stop, re-trigger
contract, never-double-trigger); add a cheap `no_action|action|failed` self-evaluation
deposit (maps onto our Trace events) so idle-leader loops are observable; keep
AgentTracker caps as the floor. Slice 5 for the argus sub-thread version.

---

## Tier 3 — Garnish

### MC3-1. Comment-triggered resume prompt discipline

**Recommendation**: BORROW-RUBRIC. On a warm resume, inject **only the new comment**
("Focus on THIS comment — do not confuse it with previous ones",
`daemon/prompt.go:159-160`) and let the session's own memory carry the rest; pointer
hints branch warm/cold (`BuildNewCommentsHint` / `BuildResumedCommentsHint` /
`BuildColdCommentsHint`, `prompt.go:175-183`); reply-target (`--parent`) is re-emitted
every turn so a resumed session can't reply to a stale anchor (`prompt.go:143-145`);
agent-authored triggers get an anti-loop block (`:161-163`). **Gap**: our successor-
thread and Discord paths re-send context wholesale; when MC1-1 gives us warm resumes,
this is the companion prompt shape. Feeds FLOW §4 thread ingest.

### MC3-2. Duplicate-task advisory-lock fence

**Recommendation**: BORROW-PATTERN, small. `issueguard/duplicate.go` +
`queries/issue.sql:124-135`: normalized-title (lowercase, whitespace-collapsed) +
`(workspace, project, parent)` scope → `pg_advisory_xact_lock(hash(...))` →
active-duplicate check (`status NOT IN (done,cancelled)`), `allow_duplicate: true`
bypass. An anti-LLM-dupe fence at creation time — agents re-filing the same task is
their observed failure mode and will be ours (myrlin task-spinoff, FLOW §7 agent-created
tasks land in triage). **Gap**: nothing equivalent; our Solutions fingerprinting is
post-hoc similarity, not creation-time fencing. Adopt with the argus Task create action
(slice 3): same advisory-lock shape via `Ash.Changeset` `before_action` + fragment.

### MC3-3. Skew-handling pair: soft version gate + flag snapshot on heartbeat

**Recommendation**: BORROW-REFERENCE. (a) `handoff_note` ships **soft version-gated**:
`MinHandoffCLIVersion = "0.3.28"` (`pkg/agent/version.go:29-59`) — an old daemon still
takes the assignment, silently drops the note, and the UI grays the affordance; no
negotiation protocol, one one-way comparison. (b) Server-evaluated **feature-flag
snapshots ride every heartbeat ack** and apply atomically daemon-side
(`protocol/messages.go:147-169`, `daemon.go:2006`). Together: the degrade-gracefully
half of the skew problem traycer TR1-1/TR1-2 and pad's `tool_surface_version` solve with
hard versioning. **Gap**: argus §6.3's rolling-upgrade plan is all hard-gate; these are
the cheap patterns for affordances that may degrade instead. Fold into the slice-1
codegen/skew work as the soft tier.

### MC3-4. CLI exit-code tiering + error translation layer

**Recommendation**: BORROW-PATTERN, small. `server/internal/cli/errors.go` +
CLI_AND_DAEMON.md §Error-Messages: one translation layer renders transport/HTTP
failures as a single actionable sentence; **exit codes tiered by failure class** (0 ok,
1 generic, 2 network, 3 auth, 4 not-found, 5 validation) so scripts branch without
parsing; `--debug` reveals the full chain; server-supplied validation messages pass
through verbatim. **Gap**: `mix jidoclaw run` (OS1-5, `cli/run_command.ex`) exits 0/1
only — and it's explicitly built for scripting/agent callers. Adopt the tier table
nearly verbatim; our MCP error codes already give the classes.

### MC3-5. IM channel engine — normalized envelope + router pipeline

**Recommendation**: TRACK — trigger: argus (or the platform) adds a **second** IM
surface beside Discord (Slack ingest, phone-side chat relay). The shape to lift when it
fires: platform-agnostic `InboundMessage`/`OutboundMessage` envelope with
platform-specifics quarantined in `Raw` (`integrations/channel/doc.go:33-41`); a
capability bitmask callers self-degrade against; one shared `Router` pipeline —
claim-dedup (owner-fenced) → group-@mention filter → identity resolve (unbound sender →
mint a 15-min single-use bind token, never auto-create) → session-ensure (group sessions
owned by the *installer*, p2p by the sender) → in-tx append+mark → **debounced
latest-sender-wins run trigger** (`channel/engine/router.go:218-316`); outbound as an
event-bus subscriber on turn-done. Our Discord consumer (`discord_consumer.ex` →
`chat/3` keyed `discord_<channel_id>`) is the single-platform version; generalizing
before a second platform exists would be speculative structure.

---

## Skip / Already Covered

- **S-1. The tracker product itself as our control plane** — SKIP. Argus is the native
  answer; running multica beside JidoClaw would put the board outside the event log,
  gates, and tenancy that justify argus in the first place.
- **S-2. Realtime layer (WS hub + Redis Streams relay + full-refetch reconnect)** —
  ALREADY-COVERED, ours stronger where it counts: Phoenix.PubSub is cluster-wide without
  a relay tier, and argus §4.2's durable `workflowEvents(afterSeq:)` catch-up is exactly
  what their live-only bus lacks (their only replay is a 5-min node-restart grace on the
  Redis shard, `sharded_stream_relay.go:35-39`). Garnish worth noting: per-scope rooms +
  ULID-deduped cross-node delivery.
- **S-3. In-process synchronous event bus** (`events/bus.go`) — ALREADY-COVERED by
  `SignalBus` + the durable `WorkflowEvent` spine; theirs is the shape we deliberately
  outgrew (squidie T1-1).
- **S-4. DB-backed distributed cron** (`sys_cron_executions` unique
  `(job,scope,plan_time)` + stale-lease steal, `scheduler/spec.go:1-14`) —
  ALREADY-COVERED by clustered cron Owner + leases (WS4a/WS5); the plan-time idempotency
  key and `CatchUpLatestOnly`/`CatchUpEveryPlan` vocabulary fold into MC2-5's catch-up
  policy rather than standing alone.
- **S-5. Composio per-user OAuth tool mounting** — SKIP (different shape: our MCP
  consumption + Vault; single-operator tenancy makes their whole problem — *whose*
  credentials does a shared agent run with — vanish). Keep the one-line insight: their
  agent-access layer exists **because** invoking an agent means borrowing its owner's
  credentials; any future multi-user argus revisits access control as a
  credential-reach question first (XA1-1 kinship).
- **S-6. Agent invocation access control** (`permission_mode: private/public_to` +
  `invocation_targets`, `packages/core/permissions/rules.ts:32-103`) — SKIP for now
  (multi-user workspace concern; we are one operator on a tailnet). Recorded loudly
  because of the **naming collision**: this is what the post-scan "permissions" commits
  are — it is NOT a tool-approval gate; `--permission-mode bypassPermissions` remains
  hardcoded (`claude.go:569`).
- **S-7. Skills injected into provider-native locations** (`.claude/skills/`,
  `CODEX_HOME/skills/`, `.cursor/skills/`, per-provider table in product-overview §3.6)
  — SKIP as a system (ours are first-class platform objects), but the provider-native
  path table is the reference for FLOW §4's CLI engine when sandboxed CLIs need our
  skills materialized; fold into the slice-6 adapter work.
- **S-8. Design-system doc discipline** (`docs/design.md` — token-only colors, 3 font
  sizes, hover-vs-active rules, anti-pattern table) — no borrow, but noted: when the
  argus React client starts, a one-page equivalent is cheap and this one is a good
  exemplar.

---

## Dig-brief dispositions (the standing questions, answered)

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) — disposition ∈ answered / contradicted / absent,
with the entry or evidence that carries it.

**multica-specific:**

1. **Task schema field-by-field** — ANSWERED (MC1-2). Sharpened: statuses are a fixed
   global 7-enum (never per-project), there is **no** status→category mapping (category
   sets hardcoded divergently per call site — the pro-kinds evidence), `blocked` is a
   manually-set status *and* an unrelated daemon routing sentinel (naming collision),
   `backlog` is a parking lot that gates automation (our `ready` kind, hardcoded).
2. **Issue ⇄ run ⇄ worktree binding** — ANSWERED (MC1-1, MC2-3). Corrections: the dig
   brief's named file `execenv/git.go` is dead code; the live path is
   `repocache/cache.go`; worktrees are **agent-initiated** via a daemon-local checkout
   endpoint (task workdirs start empty); branch template `agent/{agent}/{task8}` with a
   timestamp collision suffix; reuse discards dirty state (`reset --hard` + `clean -fd`).
3. **Daemon protocol** — ANSWERED (MC2-1). Correction to the scan: the daemon **polls
   HTTP** (code default 30s; docs say 3s — drift) and claims over HTTP; the outbound WS
   (`daemonws`) carries only wakeup hints, heartbeats, and profile-change pings
   (`hub.go:137-138` — "HTTP claim remains authoritative"). Capability profiles = CLI
   types + versions + custom runtime profiles, **not models** (models are discovered
   on demand via heartbeat-ack requests). Daemon-gone: prepare-lease, orphan recovery
   on re-register, ~150s stale sweep, 300s dispatch / 2.5h running caps.
4. **Claude driver edge cases** — ANSWERED (MC1-1). Correction to scan observation 4:
   multica does **no on-disk transcript probing** — new-vs-resume is purely flag-driven
   off the server-returned `PriorSessionID`. Env scrub is exact-name (not
   namespace-prefix — the Windows lesson). Two additions the scan missed: background
   tool calls are force-rewritten to foreground and `async_launched` results force a
   *failure* ("Multica-managed runs require foreground execution", `claude.go:228-231`);
   `AskUserQuestion` is disabled via `--disallowedTools` (`:576`), with
   clarifications-to-comments enforced by prompt, not mechanism.
5. **Comment-triggered resume + `force_fresh_session`** — ANSWERED (MC1-1, MC3-1,
   dispositions Q3 above). "Discard state" = discard only the session anchor (skip the
   `(agent, issue)` session lookup); the worktree/branch and issue history survive;
   rerun inherits the clicked row's provenance; auto-retry deliberately *keeps* the
   session (MUL-1128) while poisoned classifications force fresh.
6. **Inbox/severity model** — ANSWERED, and materially weaker than scanned: severity
   `attention` has exactly **one** producer (autopilot auto-pause,
   `autopilot_failure_monitor.go:240`), `action_required` three (assignment,
   task-failed, quick-create-failed), everything else `info`; **no UI consumes severity**
   for sort/filter/badge; four declared inbox types (incl. `agent_blocked`,
   `task_completed`) have zero producers — `task:completed` deliberately writes no inbox
   row. The load-bearing attention primitives are elsewhere: issue-deduped unread counts,
   work-delivered auto-archive of failure rows (`notification_listeners.go:159-210`),
   and the WS event feed. Slack/Lark are chat *surfaces* (MC3-5), not notification
   sinks.
7. **Squads and autopilots** — ANSWERED (MC2-5, MC2-6). Corrections: squads are
   prompt-mediated leader routing with **no server-side fan-out and no caps**;
   `autopilot_private_leader` is an access-control test, not a feature; autopilot
   **webhook triggers are shipped** (contra CLI_AND_DAEMON.md — doc drift), with rate
   limits, HMAC, and a five-outcome response taxonomy.
8. **Anti-interactive stance in practice** — ANSWERED. Mechanism: `--disallowedTools
   AskUserQuestion` + prompt doctrine; "waiting on human" has **no task state** — the
   agent posts a question comment, the task *completes*, and the agent itself moves the
   issue to `blocked` (agent-declared board state). The platform-side complement is the
   deferred-escalation fallback (MC2-5). The `agent_blocked` taxonomy entry exists
   unproduced — they know the gap. Feeds FLOW §12's `ended_blocked`: our
   platform-detected version remains ahead of the field.
9. **Still no gates?** — CONFIRMED, sharpened. All 14 usable drivers run auto-approve
   (`bypassPermissions` / `--yolo` / `--allow-all` / `--dangerously-skip-permissions` /
   ACP `approve_for_session`); every mid-run approval request is machine-answered
   (`codex.go:1609-1666` — "In daemon mode there is no human to approve";
   `hermes.go:583-612`); user `custom_args` are blocklisted from overriding the
   protocol-critical flags. The post-scan "permission" work is invocation access
   control (S-6), not a gate.

**Cross-cutting (every dig):**

1. **§5 edit-and-resume sweep** — ABSENT, verified at all four layers independently
   (driver: resume = new `Execute` with a daemon-built prompt, mid-run stdin carries
   only structured approval replies; daemon: no checkpoint/edit machinery; schema: no
   revision surface — `handoff_note` is pre-run additive context; UI: no editor, no
   approval component). **Sixteenth subject verified empty; argus §5 head-promotion
   stays novel.**
2. **Provisioning lifecycles** — PARTIAL. No create→setup→ready state machine (server
   task statuses + `waiting_local_directory` are the closest); per-provider config
   materialization with a rollback sidecar manifest (`execenv.go:237-288`); **no
   toolchain init** (orca keeps that crown); secrets materialize into env, not files
   (MC2-4). The prepare-lease is the piece worth taking (MC2-1).
3. **Branch/directory naming** — ANSWERED (MC2-3): `agent/{agent-name}/{task-short-id}`
   branches; `{WorkspacesRoot}/{ws}/{task-short}/workdir/{repo-name}` dirs; timestamp
   collision suffix (single retry); no operator template override (FLOW §4's two
   templates remain richer).
4. **Status/attention taxonomies** — ANSWERED (MC1-2, dispositions Q6): fixed statuses,
   hardcoded divergent category sets, a three-level severity enum that is ~two-level in
   practice and unrendered; what actually triggers a human is assignment, task-failure,
   and the auto-pause breaker.
5. **Teardown + stranded-work** — ANSWERED (MC2-2): the three-mode GC + sidecar meta +
   refcounted liveness; orphan *branches* reclaimed each cycle; stranded **PRs not
   detected** (absent on their side).
6. **Placement & multi-machine** — ANSWERED (MC2-1): pinned at configuration, no
   scheduling, runtime-gone recovery choreography; cloud runtimes are fleet-provisioned
   nodes running the same daemon (`cloudruntime/client.go` is lifecycle proxying only).

---

## Open questions

- **OQ-1 — Does the argus Task grow an agent-writable metadata KV?** multica's is the
  best-shaped version seen (primitive-only, 50-key/8KB caps, single-key atomic,
  anti-abuse doctrine in the runtime prompt, `--metadata` list filtering) and their
  agents demonstrably coordinate through it (`pr_number`, `pipeline_status`,
  `waiting_on`). But we already have Solutions, Session.metadata, and thread transcripts
  — a fourth state surface needs a boundary statement ("cross-run, task-scoped,
  agent-authored, human-visible" is theirs). Decide at slice 3 with MC1-2. If yes, lift
  caps + doctrine text near-verbatim and add creation-time provenance.
- **OQ-2 — Dependency release: mechanical, agent-mediated, or both?** FLOW §7 currently
  binds release to the `done`-kind mechanically (orca's evidence); multica's shipped
  practice is agent-mediated continuation (MC1-3) and its mechanical table died. Leading
  answer after this dig: both, split by relationship — mechanical for explicit
  sibling/DAG edges an operator drew; agent-mediated (notify + dispatch parent) for
  parent-child rollup. Decide when slice 3 designs `Task.depends_on`.
- **OQ-3 — Adopt the deferred-escalation shape at v1?** (MC2-5's 5-minute parked
  fallback.) It overlaps FLOW §12's `ended_blocked` trigger — theirs *re-routes work*,
  ours *notifies the operator*. On a single-operator tailnet the notification may
  subsume the re-route; but for cron/automation threads with no operator watching,
  a parked fallback turn is the difference between stalled and self-healing. Decide
  with the slice-1 attention build.

---

## Cross-references and dependencies

```
MC1-4 (failure taxonomy) ──feeds──▶ MC1-1 (resume stack: resume_unsafe?/1)
                          └─feeds──▶ MC2-5 (breaker math needs stable failure kinds)
MC1-1 ──unlocks──▶ MC3-1 (warm-resume prompt discipline)
       └─composes─▶ camus C1-1 executor seam (Forge stages get cheap multi-turn)
MC1-2 (task schema) ──gates──▶ MC1-3 (stage barriers), MC3-2 (dupe fence), OQ-1/OQ-2
MC2-1 (prepare-lease) ──joins──▶ traycer TR1-3 setup_status (state + liveness halves)
MC2-2 (GC taxonomy) ──requires──▶ MC1-1's workdir-keyed resume (artifact-only mode
                                   exists to preserve resumability)
MC2-3 (repocache) ──composes──▶ traycer TR2-1/TR2-2, emdash EM1-1/EM2-3, OpenSymphony
MC2-5 / MC2-6 / MC3-1 ──land with──▶ argus slices 3 / 5 / 1 respectively
```

**Suggested first wave** (adoptable now, no argus slice required): **MC1-4** (the
taxonomy module — composes with shipped Verdict, unblocks two other entries) →
**MC1-1** (Forge runner native resume + poisoned classifiers + env scrub — fixes a live
cost/correctness gap; the consolidator is the first beneficiary) → **MC3-4** (exit-code
tiering on `mix jidoclaw run` — an hour). Extracted as a grab-ready sequenced queue in
[MC-FIRST-WAVE.md](MC-FIRST-WAVE.md) (sibling doc; per-item done-when criteria + the
reconcile-the-source-entry discipline). Everything else is argus-slice-bound and
correctly waits; MC1-2/MC1-3's payload is design evidence, already delivered into FLOW
§7/§6 via this doc.

**Collision notes**: nothing here collides with the unadopted-next-ten queue (items 4–10
are composer/judgment work); MC1-1 touches the same Forge runner files as camus C1-1's
executor seam — sequence MC1-1 first (resume is a property of the runner, the seam then
inherits it); MC1-4 should land in/beside `Orchestration.Verdict`'s namespace to keep
the infra≠verdict≠failure vocabulary in one place (C2-8's trust-boundary doc gets a
section).

## Bottom line

1. **Fix the Forge runners' fake resume** (MC1-1 + MC1-4): native `--resume`/
   `thread/resume`, eager anchoring, cwd-gated, with the poisoned-session taxonomy and
   the retryable-vs-resume-unsafe split — a live gap today and the bedrock of argus's
   CLI threads.
2. **The argus task layer now has its schema reference and its two hardest decisions
   evidenced** (MC1-2, MC1-3, OQ-1/OQ-2): lift the field mechanics (numbering, position,
   the one-pending fence, provenance, maybe metadata KV); keep the semantic-kind layer
   multica's hardcoded category drift argues *for*; split dependency release
   mechanical-vs-agent-mediated along their stage-barrier precedent.
3. **FLOW §8 automation lands pre-validated** (MC2-5): admission gate + visible skips +
   ratio breaker + deferred escalation — adopt the shape wholesale at slice 3.
4. **The §5 novelty claim survives its sixteenth and strongest test** — the field's most
   agent-native tracker still has no gate, no edit-and-resume, self-declared blocked
   states, and no push; argus's durable gates + head-promotion + platform-detected
   attention remain the differentiated core. Build them.
