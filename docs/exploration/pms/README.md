# Agent-Era Project-Management Landscape Scan (pms)

**Status**: initial scan (2026-07-04); digs so far — multica, symphony+OpenSymphony
(joint), Chorus, orca, bosun, pad, myrlin-workbook, OpenHelm (all 2026-07-04 — the
OpenHelm no-dig was reversed on operator request; **the corpus's planned reads are now
complete**), plus a same-day **connective pass** stitching what the sequential digs
couldn't see of each other — cross-cutting observations 9–13, the combined first
wave at the bottom, and dated connective notes back into the inventories (the ades
README's own connective-pass motion, applied here). The **cross-corpus half** —
dated back-links into the [ades corpus](../ades/README.md)'s six inventories and
README where these digs confirm, contradict, or extend them — ran **2026-07-05**
([DIG-BRIEFS](DIG-BRIEFS.md) "After the digs", motion 1). Nine parallel read-only
scan passes over the repos cloned at `~/workspace/research/pms/` — README + docs skim,
manifests, top-level source layout, a handful of key files — plus git metadata. Treat
every claim below as "per scan" until a dig verifies it: the sibling ades corpus's six
digs corrected twenty scan claims between them, and there is no reason to expect a
better hit rate here. One claim was already cross-checked during the scan (the
symphony→OpenSymphony worktree delta, observation 3). Scanned at: bosun @ `18e079f6`
(2026-05-12), Chorus @ `47b5bb6` (2026-07-02), multica @ `1ff99e5af` (2026-07-03),
myrlin-workbook @ `7e26a80` (2026-07-03), OpenHelm @ `1f4196c` (2026-07-04),
OpenSymphony @ `8d101a0` (2026-04-26), orca @ `2520b31` (2026-05-13), pad @ `4429af5`
(2026-07-03), symphony @ `4cbe3a9` (2026-06-09); jido_radclaw as of 2026-07-04.

**Goal**: place each project relative to the [argus](../argus/OVERVIEW.md)
control-plane effort, as the sibling corpus to [ades](../ades/README.md). Where the
ades set was session cockpits — "one surface for many parallel agents", watching
terminals — this set is **project-management-forward**: a board, tracker, or pipeline
is the product's center of gravity, and agents attach to *it*. That inverts the scan
questions: not "how do they detect agent state" but **what PM data model do agents get
assigned through, how does human control flow through PM artifacts, and does anyone
gate execution on an editable checkpoint** (the argus §5 sweep, continued). There is
real overlap with the ades corpus (one repo, myrlin-workbook, is essentially an ADE
that grew a board), but the distinctive material here is the board-as-HITL-surface
pattern, plan-layer edit gates, server-authoritative multi-device topologies, and —
twice — our own Elixir stack.

## Where argus stands today (the seams these would plug into)

- **Decided architecture** (`../argus/OVERVIEW.md` §2): clustered JidoClaw nodes over
  Tailscale + one shared Postgres; GraphQL (AshGraphql) + Phoenix Channels; React +
  Apollo SPA/PWA, phone-friendly, Web Push. Several projects in *this* set are
  server-authoritative and multi-device (unlike the ades set, which was uniformly
  local desktop) — the topology comparisons are finally apples-to-apples.
- **No task/issue/board model exists in JidoClaw, and argus doesn't add one.**
  `Projects.Project` is metadata-only (name, github_full_name, default_branch,
  settings — OVERVIEW appendix A.2); work arrives as conversations, cron jobs, skills,
  and composer routes. Argus's hierarchy is project → worktree → runs/sessions, with
  no "task" between. Every PM-native product in this corpus inserts one. Whether argus
  *wants* a task layer — and if so whether it's a first-class resource or a view over
  runs — is the new design question this scan surfaces (observation 2 and 6).
- **Worktree domain to be built** (§3.1–3.3): `Worktree` as a git facet stacked on
  `Workspace`, with `branch`/`status`/`node` and node-affinity for runs. This corpus
  adds several *remote/multi-machine* execution references (SSH workers, daemon
  runtimes with heartbeats, `(agent, host, cwd)` addressing) the ades set lacked.
- **Review checkpoints** (§5): the one behavioral change argus makes to the gate
  family — a `:review` gate kind, revision events, `GateResume` promoting the head
  revision, step-type-specific editors. The standing question for each repo: *does
  anyone have edit-the-step-output-and-resume?* (Spoiler: still no at the execution
  layer — but this corpus has real **plan-layer** edit gates, which the ades corpus
  did not. Observation 1.)
- **What we already have** that most of these lack: event-sourced runs
  (`WorkflowEvent` log + projections), a durable gate/approval family (`AgentCase`,
  `Cases.decide/4`), leases + reclaim for single-writer runs, MCP observe/control
  tools, cluster wiring. Two projects here (bosun, orca) also went event-sourced —
  the first architectural peers on that axis in either corpus.
- Threat model (personal, tailnet-only): LLM misbehavior + leakage hygiene, not
  external attackers.

## Quick comparison

| Repo | What it is | Tech / persistence | License | Activity | Fit |
| --- | --- | --- | --- | --- | --- |
| [bosun](https://github.com/virtengine/bosun) | VirtEngine's "control plane for an autonomous software engineer" — plans/decomposes work, routes across executor pool, full PR lifecycle, Telegram-supervised | Node ≥22 pure-ESM monorepo (giant files); Express/Hono + WS; Preact no-build UI + Electron + ink TUI; 4 vendor agent SDKs + own 18-provider harness; JSON + SQLite ledger, event-sourced projections | Apache-2.0 | 2,821 commits, v0.43.1, last 2026-05-12, 2 main authors + agent bots | Closest *feature-superset* comparable: event-sourced ledger + auto-resume, first-class worktree manager, risk-tiered gates, phone surface — but approve/deny only (no edit-and-resume), and the phone UI is a Telegram Mini App. Targeted read, not a full dig — huge. **Dug 2026-07-04** (upgraded to a full dig) → [bosun/FEATURES-WORTH-BORROWING.md](bosun/FEATURES-WORTH-BORROWING.md) |
| [Chorus](https://github.com/Chorus-AIDLC/Chorus) | "Agent harness for AI-human collaboration" — AI-DLC pipeline: Idea → Proposal → Doc + Task DAG → Execute → Verify; humans and agents are peer assignees | Next.js 15 / React 19 / Prisma 7 → Postgres (embedded PGlite for local, Redis for fan-out); REST + MCP-HTTP (~81 tools) + SSE; daemon drives Claude Code/Codex headless | **AGPL-3.0** | 611 commits, v0.13.0, last 2026-07-02, near-solo + agent bot | **The §5-adjacent find**: humans edit AI-drafted proposal artifacts *including the task DAG* while in draft, then approve → materialize; plus daemon interrupt/resume/instruction-injection and a unified user-or-agent Notification model. Plan-layer only — no execution-layer edit-and-resume. Patterns only (AGPL). **Dug 2026-07-04** → [chorus/FEATURES-WORTH-BORROWING.md](chorus/FEATURES-WORTH-BORROWING.md) |
| [multica](https://github.com/multica-ai/multica) | "Linear for agents" — issue tracker where agents are first-class teammates; local/cloud daemon drives 14 CLI backends against assigned issues | Go + Chi + sqlc + Postgres 17 (pg_bigm/pg_cron; **no pgvector** — dig correction) (server-authoritative); Next.js 16 web + Electron + native iOS (Expo, no push); daemon **polls HTTP**, outbound WS is wakeup/heartbeat only (dig correction) | Modified Apache (Dify-style commercial clause; internal single-org use exempt) | 3,903 commits in ~7 months, v0.3.38, last 2026-07-04, ~10 humans + agent bot | **Strongest whole-product comparable**: server DB + multi-device clients + worktree-per-task + agents-as-assignees. HITL is deliberately conversational (comment-triggered `--resume`, Slack/Lark @mentions) — no gates at all, tools hard-coded auto-approved. **Dug 2026-07-04** → [multica/FEATURES-WORTH-BORROWING.md](multica/FEATURES-WORTH-BORROWING.md) |
| [myrlin-workbook](https://github.com/therealarthur/myrlin-workbook) | Browser + TUI + native-mobile session manager for Claude Code/Codex with per-project kanban and a worktree task board | Node/Express + vanilla-JS SPA (no build); node-pty; JSON file store; Expo RN mobile app, QR-pair + Bearer; SSE state + WS terminals; Expo push | **AGPL-3.0** | 560 commits, v1.2.0, last 2026-07-03, solo + agent alias | The **ades bridge**: an ADE-class cockpit that grew a PM layer. Real phone app with per-event push taxonomy (needs-input, task-review, file-conflicts), worktree-task board with dependencies + concurrency caps, task-spinoff from live transcripts. Patterns only (AGPL). **Dug 2026-07-04** → [myrlin-workbook/FEATURES-WORTH-BORROWING.md](myrlin-workbook/FEATURES-WORTH-BORROWING.md) |
| [OpenHelm](https://github.com/maxbeech/OpenHelm) | macOS Tauri app turning goals into scheduled, self-correcting Claude Code jobs — for *business/growth automation*, not coding | React 18 + Tauri 2 + Node sidecar; Drizzle/SQLite local; cloud tier = Fly worker + Supabase + e2b sandboxes running Goose; REST `/v1` + webhooks | **BUSL-1.1** | 584 commits, **v2.1.0** (2026-07-04; package.json says 0.1.0, updater manifest stale at 1.2.0), last 2026-07-04, solo + agent alias | Adjacent domain (agent fleet ops, not SWE). **Both scan citations corrected by the dig**: the per-tool risk-1–5 gate is dead code (live = autonomy dial × action-class × apply-with-undo) and the run snapshot is write-only (read path has zero callers). The haul is the cron-health breaker family + attention mechanics + evaluator convergence. No worktrees, no kanban, no edit-and-resume (subject 24). **Dug 2026-07-04** (no-dig reversed) → [openhelm/FEATURES-WORTH-BORROWING.md](openhelm/FEATURES-WORTH-BORROWING.md) |
| [OpenSymphony](https://github.com/Swiftyos/OpenSymphony) | Community fork of OpenAI's symphony: Linear-driven autonomous daemon, generalized to Claude Code/Codex/OpenCode with label-based routing | Elixir 1.19 / Phoenix 1.8 / LiveView; **no DB** (in-memory + files, Linear is source of truth); worktrees off a cached repo (**non-bare** — dig correction); SSH remote workers; Grafana/Vector stack | Apache-2.0 (OpenAI copyright) | 42 commits, 0.1.0, fork last 2026-04-26 (diverged; not a superset of upstream) | **Our stack**, inverse philosophy (unattended-by-design). The fork is the argus-relevant variant: multi-backend adapter dispatch, per-issue worktrees, label-routed model/effort tiers, multi-account rate-limit rotation. **Dug 2026-07-04** (joint with upstream) → [symphony/FEATURES-WORTH-BORROWING.md](symphony/FEATURES-WORTH-BORROWING.md) |
| [orca](https://github.com/andrewmcoupe/orca) | Local-first Tauri desktop: brief → plan → per-task phase pipeline (default implementer → auditor; test-author opt-in — dig correction) → gated land | Tauri 2 (Rust) + React 19; rusqlite + git2 + portable-pty; **event-sourced** SQLite store under `$HOME/.orca` (dig correction: no longer repo-local), rebuildable projections (manual dev command); drives Claude Code/Codex via stream-json | MIT | 95 commits, v0.1.13, last 2026-05-13, solo | Sharpest *pattern* donor — dig-confirmed with corrections: queue-then-release DAG (auto-start only for human-queued tasks; cancelled deps keep dependents blocked), worktree-per-task with toolchain auto-init, structured auditor verdicts (severity-tagged; anchors prompt-only, dead-rendered at HEAD), and a briefing loop that **promotes edits verbatim on Accept** (re-prompt is the Refine lane; pushback never promotes) — the scan's "still re-prompt-not-promote" was wrong. Single-user, no server. **Dug 2026-07-04** → [orca/FEATURES-WORTH-BORROWING.md](orca/FEATURES-WORTH-BORROWING.md) |
| [pad](https://github.com/PerpetualSoftware/pad) | "Project management for the agent era" — single-binary PM substrate that agents plug *into* (skill + MCP); it does not drive agents | Go 1.26 + chi + SQLite/FTS5 (opt-in Postgres+Redis); embedded SvelteKit UI; Yjs CRDT collab editing (single-node — dig correction); REST + SSE + MCP (stdio + OAuth2 remote); PWA manifest (no SW/push — dig correction) | Apache-2.0 | 915 commits, v0.8.0, last 2026-07-04, solo | **The complement, not a competitor**: kanban + playbooks-as-data + agent roles, exposed via CLI/skill/MCP with explicit surface versioning. No run engine at all — and no LLM code anywhere (§5 subject 22, structurally absent). **Dug 2026-07-04** → [pad/FEATURES-WORTH-BORROWING.md](pad/FEATURES-WORTH-BORROWING.md) |
| [symphony](https://github.com/openai/symphony) | OpenAI "engineering preview": spec-first autonomous daemon — polls Linear, one Codex session per issue until PR/handoff. "Manage work instead of supervising coding agents" | 2,185-line language-agnostic **SPEC.md** + experimental Elixir reference impl (Phoenix/LiveView/Bandit; Ecto for validation only, **no DB**); Codex app-server JSON-RPC over stdio; per-issue shallow clones; SSH workers | Apache-2.0 | 23 commits, 0.1.0, last 2026-06-09, OpenAI staff | **Our stack, from OpenAI**: the Codex app-server client is the most directly liftable artifact in the corpus; orchestrator dispatch loop (bounded concurrency, backoff, stall detection, reconciliation) is a clean reference. Read-only dashboard, `approval_policy: never` shipped — the philosophical inverse of argus HITL. **Dug 2026-07-04** (joint with the fork) → [symphony/FEATURES-WORTH-BORROWING.md](symphony/FEATURES-WORTH-BORROWING.md) |

## Categories

### 1. Agent-native trackers — "Linear for agents" (multica, Chorus)

The whole-product comparables. Both are server-authoritative (real Postgres), both
put a board/pipeline at the center with **agents as first-class assignees**, and both
run agents through a daemon installed on the operator's machines — the same
"control plane + execution nodes" split argus makes, arrived at from the PM side.

**multica** (multica-ai, ~8-person team, staggering velocity — 3,901 commits in six
months). A Linear-clone schema (`issue` with kanban position, `issue_dependency`
blocks/blocked_by/related, sub-issues, projects, threaded comments) where
`assignee_type`, `creator_type`, `actor_type` are all `member | agent`. A Go daemon
connects outbound over WebSocket, auto-detects agent CLIs on PATH, and executes
issues in **worktrees off a repo cache**; ~15 backend drivers (Claude Code, Codex,
Copilot, Cursor, OpenCode, Gemini, Kimi, …) all via subprocess stream-json.
Higher-order constructs: **squads** (assign to a group; a leader agent delegates) and
**autopilots** (cron/webhook-triggered runs). HITL is deliberately conversational:
agents report blockers as comments + `inbox_item.severity ∈
action_required/attention/info`; a human reply spawns a "comment-triggered task" that
resumes the prior session via `--resume`; `RerunIssue force_fresh_session` discards
poisoned state. Two considered datapoints for argus: `AskUserQuestion` is *disabled*
(clarifications are forced into issue comments — headless has no UI), and
`--permission-mode bypassPermissions` is hardcoded — **no approval gate exists
anywhere** (verified across all 352 migrations by the scan). Slack/Lark integration
makes agents @mentionable, and a chat session can live *in* the IM channel.

> **Dig corrections (2026-07-04)** — [multica/FEATURES-WORTH-BORROWING.md](multica/FEATURES-WORTH-BORROWING.md),
> dug @ `129efb768`: **no pgvector** (extensions are pg_bigm/pg_cron/pgcrypto);
> the daemon **polls HTTP** (code default 30s) — the outbound WS carries only wakeup
> hints + heartbeats, HTTP claims stay authoritative; **`issue_dependency` is dead
> code** (shipped in migration 001, zero queries/API/release logic — their real
> sequencing is integer `stage` barriers on sub-issues that *dispatch the parent's
> agent* on frontier close); the **severity model is ~two-level in practice**
> (`attention` has exactly one producer, no UI consumes severity; `task_completed`
> deliberately writes no inbox row); worktrees confirmed but **agent-initiated**
> (task workdirs start empty; the agent CLI calls a daemon-local checkout endpoint);
> gemini backend **removed** (roster is 14 drivers, newest attach via ACP); the
> post-scan "permission_mode/invocation_targets" work is **invocation access
> control** (who may invoke whose agent — motivated by Composio credential sharing),
> NOT a tool gate — `bypassPermissions` holds, all 14 drivers auto-approve;
> mobile app ships **no push at all**; reconnect catch-up is full refetch. Both
> anti-interactive datapoints above CONFIRMED; comment-triggered `--resume` and
> `force_fresh_session` semantics confirmed precisely as scanned.

**Chorus** (Chorus-AIDLC, near-solo). The methodology product: AI-DLC ("reversed
conversation: AI proposes, humans verify") as software. Idea → **Proposal** (AI-drafted
documents + task drafts as JSON) → human edits the drafts **including the task DAG**
in a visual editor while `status == draft` → approve **materializes** them into real
Task/Document rows in a transaction; reject-with-note sends back for agent revision.
Tasks flow `open → assigned → in_progress → to_verify → done` with per-row acceptance
criteria and dual-path verification (dev self-check + admin verify). The daemon side
is the other half: each `(agent, host, cwd)` is an addressable **AgentInstance**;
notification "wakes" can be **pinned** to exactly one instance; a reverse control
channel does interrupt (SIGINT with double-check), resume, and free-text
**instruction injection** into a running turn. One `Notification` model addresses
users *or* agents — the same row type is a human ping or an agent wake. ~81
permission-gated MCP tools behind a uniform 5-resources × 3-actions matrix granted to
humans or agents alike. Notably **no worktrees** (plain cwds) — the inverse gap of
multica, which has worktrees but no gates.

> **Dig corrections (2026-07-04)** — [chorus/FEATURES-WORTH-BORROWING.md](chorus/FEATURES-WORTH-BORROWING.md),
> dug @ `47b5bb6` (scan pin, zero default-branch drift): the headline correction is
> observation 1(b)'s — **human draft edits are PROMOTED, not re-prompted**: edits
> write into the same `taskDrafts`/`documentDrafts` JSON the AI authored and approve
> materializes those bytes verbatim (the model is never re-invoked); only
> reject-with-note re-prompts. **"Instruction injection into a running turn" is
> next-boundary delivery** — a durable `pending` turn + a lossy `deliver_turn` ping,
> serialized per root idea behind the in-flight subprocess; never mid-flight stdin.
> The matrix is **79 tools, 42 gated / 37 ungated** (two ungated *write* paths incl.
> guard-free `chorus_create_tasks`) and binds **agents only** — humans sit entirely
> outside it. Reject returns `pending → draft` (the schema's `rejected`/`revised`
> are dead values); `reviewNote` is one overwritten column — **no revision history**
> — and approve→materialize has **no concurrency fence** (double-approve
> double-materializes). No durable wake queue (offline agent = notification-only;
> the turn table + reconnect backfill is the net); hard (mention) pins offline go
> notify-only, soft (assignment) pins degrade to online-first; a session whose
> origin `(host, cwd)` dies goes **read-only, never rerouted** (explicit cold
> re-point is the one mobility affordance — nothing-migrates kinship). The daemon
> **defaults to yolo** (`--dangerously-skip-permissions`; DAEMON.md's y/N
> confirmation is never prompted — doc drift), and chorus mode auto-denies rather
> than bridging approvals. No push of any kind (grep-verified); the Notification
> model is flat (no severity, no kind enum, one dead kind `proposal_submitted`).
> Confirmed as scanned: the `(agent, host, cwd)` AgentInstance (now a durable third
> assignee type with the idea as pin root, v0.12), the 5×3 matrix shape, OIDC+API-key
> auth, and no-worktrees (exhaustive — zero git anywhere). Recency caveat: the
> daemon/instance/wake surface is 1–3 weeks old at pin, with three unmerged branches
> (+9.8k lines) reworking orphan-turn handling (orphaned `running` turns currently
> persist forever).

### 2. The Symphony lineage — tracker-driven autonomous daemons, in Elixir (symphony, OpenSymphony)

OpenAI's symphony and its community fork are the corpus's stack-mates: Phoenix +
LiveView + Bandit, GenServer orchestration, escript CLI. Their thesis is the
**inverse of argus HITL**: unattended by design ("This is an unattended orchestration
session. Never ask a human" — the shipped `WORKFLOW.md` sets `approval_policy:
never`), with the human managing *work* in Linear and reviewing *PRs* in GitHub.
There is no PM model in either repo — Linear is the board; a normalized `Issue`
read-model (with `blocked_by` honored at dispatch) is the only entity.

What they're *for*, from our side, is the execution layer: **symphony** (upstream,
23 commits, spec-first — the README invites you to hand SPEC.md to an agent and
reimplement it) has the most directly liftable artifact in the corpus, a
dependency-light **Codex app-server JSON-RPC-over-stdio client** (`initialize` →
`thread/start` → `turn/start`, approval/user-input/elicitation handling, dynamic
tools, token accounting, stall/turn timeouts), plus an orchestrator loop with bounded
concurrency, per-state caps, exponential-backoff retries, stall detection,
reconciliation against the external source of truth, and **least-loaded SSH
remote-worker selection**. `WORKFLOW.md` is a tidy config-as-repo-contract pattern:
YAML front-matter (runtime policy) + Liquid prompt body, validated by Ecto embedded
schemas — Ecto with no database. History note: a "Linear comment resumes" UX was
tried and **reverted** (#84 → #85).

**OpenSymphony** (Swiftyos fork; diverged, both sides evolved independently — the
fork is *not* behind, it's sideways) is the argus-relevant variant: multi-backend
adapters (Codex app-server, **Claude Code headless stream-json**, OpenCode) selected
per-ticket by Linear label including effort labels, multi-project routing,
multi-account **rate-limit health rotation** (`healthy|limited|exhausted|paused`),
and — verified during this scan — isolation moved from upstream's per-issue shallow
clones to **`git worktree` off a cached bare repo** (observation 3).

> **Dig corrections (2026-07-04)** —
> [symphony/FEATURES-WORTH-BORROWING.md](symphony/FEATURES-WORTH-BORROWING.md), joint
> read @ symphony `4cbe3a9` / OpenSymphony `8d101a0` (scan pins, zero drift):
> the fork's cache is **non-bare** — a normal full clone with the target branch
> checked out (`checkout -f -B` + `reset --hard` on the cache), worktrees added off
> it; branch template `symphony/<sanitized-issue-id>`, no collision counter
> (`worktree add --force -B` resets instead). **The daemon never writes Linear** —
> zero callers of `create_comment`/`update_issue_state` in either repo; every state
> move/comment/PR link is the *agent's* work via the injected `linear_graphql` tool
> (upstream SPEC flags first-class tracker writes as an unbuilt TODO). The
> `approval_policy: never` claim holds for the shipped WORKFLOW.md; the **code
> default** is a reject-map (approvals fail the turn — auto-approve is opt-in).
> `codex.stall_timeout_ms` is never consumed by the Codex driver — stall detection
> is orchestrator-side only. Account health is **six** states (adds
> `unknown`/`disabled`), and the default `usage_aware_round_robin` strategy is
> plain round-robin (only non-default `least_usage` reads usage). SSH "least-loaded"
> = running-count only, sticky retry host, **no health checks**; OpenCode is
> local-only. The #84→#85 comment-resume revert records **no technical why**
> ("the request was to revert") — a softer negative datapoint than scanned; #66
> then shipped the *surfacing* half (in-memory blocked-sessions lane), which the
> **fork deleted** along with upstream's MCP-elicitation hard-block (two fork
> capability regressions). Claude driver resume model differs from multica's:
> one long-lived stdin-fed process with a client-generated `--session-id` (no
> `--resume` flag at all). §5 edit-and-resume verified empty in both (17th/18th
> subjects).

### 3. Autonomous-fleet consoles with supervision loops (bosun, OpenHelm)

Both run fleets of scheduled/queued autonomous work under risk-tiered approve/deny
gates with escalation, and both grew a phone-adjacent surface. Neither has
edit-and-resume; both chose *self-correction + gating* instead.

**bosun** (VirtEngine). The feature-superset comparable: on paper it has nearly every
argus noun — event-sourced projections (`live-event-projector`, replay reader,
projection contracts), per-run **execution ledgers with auto-resume on restart**, a
centralized **worktree lifecycle manager** with stack-detection/bootstrap and a
recovery state machine, a task hierarchy (epic/task/subtask) with a status
transition state machine, **multi-backend kanban adapters** (internal JSON+SQLite,
GitHub Issues, GitHub Projects V2, Jira), a gate family (workflow gate nodes,
risk-tiered action approval, per-tool-call approval — resolve accepts only
`{approved, denied}` + note, verified by the scan), and a Telegram Mini App as the
phone surface with sentinel-pushed escalations. The deltas: Node pure-ESM monolith
(114k-line `cli.mjs`), executors driven via **vendor SDKs in-process** (plus a
from-scratch 18-provider HTTP harness they're migrating onto), and mid-session
**steer/nudge prompt injection** as the closest HITL affordance. Activity note: last
commit 2026-05-12 — the only repo besides orca and the symphonies not touched within
days of the scan.

> **Dig corrections (2026-07-04)** — [bosun/FEATURES-WORTH-BORROWING.md](bosun/FEATURES-WORTH-BORROWING.md),
> dug @ `18e079f6` (the scan pin — zero drift; quiet since May): the "114k-line
> `cli.mjs`" was bytes-for-lines (3,219 lines / 114KB — a thin dispatcher; the bulk
> lives in ui-server ~31k and telegram-bot ~11.8k lines). Executor counts: **5** vendor
> SDK executors (not 4; a 6th SDK is voice-only) + **19** provider drivers (not 18) —
> and the internal harness hit its Tier-1 sign-off (GO 2026-04-20) **without retiring
> the vendor SDKs** (both stacks stay wired and config-selectable). **Auto-resume is
> real** (the corpus's only shipped resume-on-restart: capped 25/restart, taskId +
> run-family dedupe, live-claim fences, an ~11-value unresumable-reason taxonomy,
> single-owner recovery) — but it resumes from the **atomic state-snapshot store**, not
> the event ledger, which is a non-crash-atomic audit sidecar (four distinct
> ledger/journal stores total). The "centralized worktree lifecycle manager" is **two
> parallel subsystems** (the manager class is legacy; task worktrees run through a
> workflow action node) and the "recovery state machine" is a 4-state health
> *telemetry* tracker plus inline poison-reset logic. "Risk-tiered action approval"
> resolves to three unrelated risk systems — the workflow-action layer is binary and
> **default-off**, per-tool auto-approves low/medium, and gate timeout defaults to
> `onTimeout:"proceed"` (timeout = auto-approve); resolve = `{approved, denied}` +
> note **confirmed verbatim**, and the gate family does round-trip in-process — via 5s
> poll loops and one in-memory-promise lane, with requests durable but waiters lost on
> restart (a resumed gate **re-opens to pending even if already approved**). The
> Telegram *chat* has **no approve/deny controls** (counts only) — the Mini App is the
> actionable approval surface; "sentinel-pushed escalations" are monitor-crash
> watchdog pushes, never approvals. The kanban tale is sharper than scanned: the
> two-way **sync engine was deleted from the repo** (its workflow-template replacement
> dynamic-imports the missing module with `continueOnError: true`; the Projects V2
> webhook always 503s) — backends are internal/github/jira/**repo-mirror** with
> Projects V2 a mode inside the github adapter. And steer/nudge is sharpened:
> the **Claude lane injects mid-turn** via the agent-SDK streaming-input channel
> (Codex/Copilot queue to the next boundary) — the field's one shipped mid-turn
> exception to observation 1's boundary-steering convergence. §5 edit-and-resume
> verified empty at **subject 21** (nearest miss: `/restore` forks a new run with
> workflow-*variable* overrides; `/remediate` is a stub; `ask_user` has a writer and
> no reader).

**OpenHelm** (maxbeech, BUSL-1.1). Included in the batch but aimed elsewhere:
anthropomorphized agents ("Postie") run **scheduled business-automation jobs**
(social posting, SEO, outreach) via headless Claude Code locally or Goose-in-e2b in
the cloud. No worktrees (shared project dirs), no kanban ("tasks" are an attention
inbox). The transferable bits are operational patterns: a **risk-taxonomy approval
gate** (tool-call risk 1–5 vs user threshold; risky calls block and materialize as
tasks carrying the exact `{server,tool,args}` payload, executed verbatim on
approval — never operator-edited), **run snapshots** (resolved MCP scope + creds
persisted at run start so interrupted runs resume with identical context), and the
**Autopilot** supervision loop (outcome triage, circuit breaker, prompt-rewrite
proposer, dedup, escalation digests). Evidence of a rebrand from a prior "Athenic"
product; ships a Go TLS/MITM proxy for browser automation in sandboxes.

> **Dig corrections (2026-07-04)** — [openhelm/FEATURES-WORTH-BORROWING.md](openhelm/FEATURES-WORTH-BORROWING.md),
> dug @ `2facabaa` (5 commits past the scan pin, same day — and the drift mattered:
> `v2.1.0` **replaced the entire Autopilot subsystem the scan described**; v1's
> Maintainy scanner — ~475 metrics per 15-min tick, keyword triage — is retired in the
> CHANGELOG's words as "the thing users disabled for burning tokens", succeeded by
> Engine v2: cheap DB signals → snapshot-diff (no change ⇒ zero LLM) → one Haiku triage
> on a closed enum → risk-gated actions with undo / capped Sonnet deep reviews, under a
> charge-before-call per-project daily token ledger). **Both recorded pattern citations
> corrected**: (1) the "risk-taxonomy gate (tool-call risk 1–5 vs user threshold)" is
> **dead code** — `checkApproval` has zero production callers and its per-tool
> `riskWeight` lookup no longer matches the taxonomy JSON shape; live gating is a 1–5
> **autonomy dial** (stored {1,3,5}, 3 preset cards; the old 1–5 descriptions are
> self-labeled "dishonest" in code) × an action-**class** taxonomy
> (`reversible_tuning | auto_with_undo | destructive_availability`, unknown →
> destructive, i.e. fail-closed) × **apply-with-undo** (`job_changes` audit + one-click
> revert task) — "executed verbatim on approval, never operator-edited" CONFIRMED, and
> sharpened: the stored `{server,tool,args}` payload is never even rendered on the
> approval card. (2) "Run snapshots … resume with identical context" is **write-only**:
> `readRunMcpSnapshot` has zero callers, resume re-resolves MCP scope live from current
> DB state — the exact bug its own migration comment claims to fix; snapshotted creds
> are refs + injection method, never values. Also corrected: the TLS/MITM proxy is
> **desktop-only, default-off, loopback-bound** (not in the e2b image — "browser
> automation in sandboxes" was wrong; it's JA3/JA4 fingerprint control); the
> prompt-rewrite loop is split (agent-path auto-applies with undo, contradicting its
> own "always propose" header; the human-facing proposal buttons are mis-wired — missing
> the required `newPrompt` — and fail on click; cloud has no apply path); local runs
> execute **in the user's real project directory** with the collision fix being a
> global concurrency cap of **1** (the corpus's cleanest evidence that no-worktrees
> forces fleet-wide serialization); and `docs/` (the PRD + ~35 plan docs README/CLAUDE.md
> cite) is **gitignored** — the public repo withholds the planning corpus. Three
> shipped-but-unwired subsystems found (snapshot read path, per-tool gate, the
> OpenRouter cost-metering proxy — each with tests); the auto-updater manifest is two
> releases stale (a 1.2.0 install is never offered 2.1.0). What survives verification is
> the argus-relevant haul: the **layered cron-health breaker family** (transient ≠
> rate-limit ≠ infra classification before counting; persisted consecutive-failure
> breaker → pause + attention item + **auto-recovery** — added after an overnight blip
> once paused every job ~9h; heartbeat watchdog with process-exit escalation, XA1-2 as
> shipped code), the **attention mechanics** (semantic dedup keys, touch-in-place with
> priority escalation, infra-incident storm collapse — 16 failing jobs → one task,
> guaranteed escalation with a never-vanish fallback row, email-on-attention additive at
> `approval_required` OR priority ≥ 80), and strong independent convergence with the
> queued camus/ouroboros verification program (required `outcome_spec` contracts on
> agent-created jobs; a fresh-context judge with **read-only DB tools** that weighs
> primary evidence over prose; fabrication as claimed-vs-observed; honest
> `partially_succeeded`/`permanent_failure` terminals with an enforced transition
> table). §5 edit-and-resume verified empty at **subject 24** — approvals are one-click
> on stored payloads, the lone custom-input path is dead code, and chat's "Request
> Change" rejects the whole batch and re-prompts. Anti-interactive datapoint for §12:
> their HITL deliberately **ends the run** and fires a named follow-up job on approval
> (the README calls mid-run pause "fragile") — the opposite pole from our durable
> checkpoint+resume, and the design question argus phone approvals must answer (who
> executes a grant decided after the session died?).

### 4. Local plan-to-land pipeline (orca)

**orca** (Andy Coupe, solo, MIT). The smallest codebase in the set and the sharpest
pattern-per-line ratio. Event-sourced to the bone: each workspace repo gets its own
append-only SQLite event store (`.orca/events.sqlite`) with versioned events,
`command_id` idempotency, `correlation_id`/`causation_id`, and **disposable,
rebuildable projections** — the same architectural commitments as our
`WorkflowEvent` spine, independently arrived at in Rust. On top: Plan → Task with a
**dependency DAG** (cycle-checked, and a queue manager auto-starts a task when its
last dependency **merges** — the sharpest borrowable scheduling semantic in the
corpus), **worktree-per-task** with toolchain auto-detection (pnpm/uv/cargo/go install
before first phase), and a per-task **phase pipeline** (test-author → implementer →
auditor, each independently retriable) driven through Claude Code/Codex stream-json.
HITL is two-layered: the **briefing loop** (operator edits the AI's draft plan
inline, pushes back on individual assumptions — `BriefingDraftEdited`,
`BriefingPushedBack` — and the edits feed regeneration) and the **auditor verdict
gate** (auto-progression halts on a structured verdict: approve/revise/reject with
severity-tagged, `path:line`-anchored concerns; the human approves, passes back with
authoritative notes, rejects, or lands). Code review is **read-only by design** — the
"git is an implementation detail" doctrine bans even the words branch/merge/diff from
UI copy and column names. Single-user, Tauri IPC only, no server, quiet since
2026-05-13.

> **Dig corrections (2026-07-04)** — [orca/FEATURES-WORTH-BORROWING.md](orca/FEATURES-WORTH-BORROWING.md),
> dug @ `2520b31` (the scan pin — zero drift; the whole product is an 11-day solo
> sprint, 2026-05-02→05-13): the headline correction is observation 1(b)'s —
> **Accept PROMOTES draft edits verbatim** (`apply_edits_to_draft` merges the
> operator's edits into the materialized plan/tasks, model never re-invoked);
> Refine is the re-prompt lane; **pushback never promotes** (their own test:
> "pushbacks become input to the next refinement, not draft state") — and the
> rich pushback-reconciliation prompt the scan's framing implied is **dead code**
> (the live persona prompts pass one generic `user_feedback_json` blob).
> **Auto-queue-on-merge is armed**: last-dep-merge releases, but only
> human-queued (`is_queued`) tasks auto-start; `cancelled`/`archived` deps keep
> dependents blocked (FLOW §7's canceled-doesn't-release, independently shipped).
> Default pipeline is **implementer → auditor** (test-author supported, opt-in).
> Auditor verdict confirmed `approve|revise|reject` + `blocking|advisory` — but
> **anchors are prompt-only** (absent from the structured-output JSON schema, so
> Codex-path verdicts lack them) and the line-anchored rendering is **dead code at
> HEAD** (#22 orphaned `DiffModal`); concerns are unvalidated `Vec<Value>`
> pass-through. Event store: **`command_id` is server-minted** (guards internal
> retries, not UI double-submits), **`correlation_id`/`causation_id` are dead
> columns** (always `None`), docs' upcasters don't exist (tolerant serde
> defaults), and the store moved to `$HOME/.orca/workspaces/<key>/` (repo-local
> `.orca/` is copy-migrated legacy). The pipeline **always halts for a human after
> the auditor** (no auto-retry on `revise`); accept has **no concurrency fence**
> (double-accept double-materializes — the corpus's third missing approve fence,
> after Chorus). Teardown is the corpus's weak end: reject/cancel/delete
> force-delete worktree **and branch**, discarding unmerged work. Vocabulary
> doctrine (`GIT_IS_IMPLEMENTATION.md`) real and land-flow-compliant, but
> enforcement leaks ("merged"/"cycle" in the dependency UI). CLI gotchas
> confirmed + sharpened: the plan-mode deadlock is `ExitPlanMode` awaiting
> approval against closed stdin (orca bans `plan` for Claude outright; Codex
> `plan` = `--sandbox read-only`, exempt); the auditor clamp covers
> `bypassPermissions` AND `plan`, at four defense-in-depth sites; **no CLI
> session resume anywhere** (fresh spawn per phase; continuity = shared worktree
> + per-phase auto-commits). §5 execution-layer edit-and-resume verified empty
> (20th subject).

### 5. Cockpit-with-a-board — the ades bridge (myrlin-workbook)

**myrlin-workbook** (Arthur, solo, AGPL). If it had been in the ades batch it would
have slotted next to emdash/CCC: it discovers and PTY-drives Claude Code/Codex
sessions with embedded terminals, JSONL transcript tailing, and a read-only live
session **mirror**. What earns it a place here is the PM growth on top: a
**worktree-task board** (Backlog/Planning/Running/Review/Done) with task
dependencies, per-task model assignment, and **concurrency caps (1–8)**;
**task-spinoff** (AI extracts actionable tasks from a running session's transcript
into structured, *human-editable* spec forms, each spawning a parallel worktree
agent); and PR automation with auto-advance-on-merge. Its topology is the closest
existing analog to argus's client story — QR-pair + Bearer token, SSE for state, WS
for terminals, a **native Expo mobile app that drives agents** (not view-only), and
**per-event push subscriptions** (`sessionComplete`, `sessionNeedsInput`,
`fileConflicts`, `taskReview`, `serverOnline`) with cross-session **file-conflict
detection** between parallel agents. Deep multi-account credential management with
quota meters. REST+SSE rather than GraphQL; vanilla-JS SPA; JSON-file persistence.

> **Dig corrections (2026-07-04)** — [myrlin-workbook/FEATURES-WORTH-BORROWING.md](myrlin-workbook/FEATURES-WORTH-BORROWING.md),
> dug @ `7e26a80d` (the scan pin — zero drift): the headline correction is the push
> taxonomy — **five preference keys are declared, exactly two events fire**
> (`session:complete`, `task:review` — precisely emdash's EM1-3 two-trigger set):
> `fileConflicts` listens for a store event **nothing emits**, `sessionNeedsInput`'s
> producer greps session logs for strings no code writes (the real needs-input
> detector is frontend xterm scraping that never reaches the server), and
> `serverOnline` has no listener at all. **Conflict detection is real but
> poll-only** (no push, no SSE): a transcript-derived detector (last-50KB `tool_use`
> Edit/Write paths, ≥2 sessions per path, 30s cache) plus a git-status detector
> behind a 15s promise-cache with eager invalidation from the mutating-git
> chokepoint. **QR pairing is broken at HEAD** (a helper refactor made
> `isRateLimited` return an always-truthy object; three call sites updated,
> `pairing.js` missed — `POST /api/auth/pair` always 429s; the asserting test exists
> and evidently doesn't gate releases; read-verified, not executed). **Task-spinoff
> shipped** (README's "Coming Soon" roadmap is stale) and its editor **promotes
> verbatim** (plan-layer promote-the-edit #3, correcting observation 1(b) again) —
> but the promoted spec **never reaches the spawned agent** (the spinoff path
> creates the session with no initial prompt; the rich context-handoff endpoint is
> UI-dead). **Task dependencies are inert** (`blockedBy` is display-only — the
> corpus's fourth dead-dependency subject); **concurrency caps are client-side
> only** (three UI checks, refuse-not-queue, API-bypassable) and the whole worktree
> board ships **off by default**; **auto-advance-on-merge fires only on a manual
> "Refresh PR Status" click** (no poll, no webhook); record-delete strands the git
> worktree/branch with no reconciliation sweep. Board columns are five over seven
> statuses through a mapping layer (Done folds `merged`/`completed`/`rejected`; two
> different landing paths write two different terminal statuses). Confirmed as
> scanned: the native Expo app **drives** (merge/reject tasks, fully interactive
> terminal over WS) — though frozen since 2026-04-01 with visible server drift
> (diverged task types, a broken deep-link route, an inert notification-level
> control) — and the multi-account credential manager is the dig's headline borrow
> (cross-machine OAuth refresh-token **lineage guard**, rotation write-back,
> three-state token health). §5 edit-and-resume verified empty at the execution
> layer (23rd subject).

### 6. Agent-facing PM substrate — the complement (pad)

**pad** (PerpetualSoftware/xarmian, solo, Apache-2.0). The inverse of everything
above: pad **does not drive agents** — external agents drive *pad*, through a
natural-language `/pad` skill that shells the CLI and an MCP server sharing the same
dispatch path. A single Go binary embeds the SvelteKit UI; SQLite with FTS5 local,
opt-in Postgres+Redis for multi-node/cloud. The PM substance is real: typed
Collections with a field DSL, items with stable refs (`TASK-5`), kanban +
blocks/blocked-by + parent/child, per-transition `StatusTransition` audit rows,
**playbooks-as-data** (user-editable multi-step procedures with `invocation_slug`,
typed arguments, draft/active/deprecated lifecycle — the *authoring* half of a
workflow system with deliberately no run engine: the agent executes the steps
itself), trigger-based **conventions** agents auto-load, and **agent roles** with
(user, role) assignment and full attribution (`created_by`, `source = cli|web|mcp`).
Two argus-relevant garnishes: **explicit agent-surface versioning**
(`tool_surface_version`, `cmdhelp_version`, a closed error-code taxonomy — the same
skew problem traycer TR1-1/TR1-2 solves, solved at the tool-contract layer), and
Yjs CRDT collaborative editing + SSE with a Redis multi-node bridge. PWA manifest
present. HITL is a social convention in the skill text ("never save without
asking") — nothing server-enforced.

> **Dig corrections (2026-07-04)** — [pad/FEATURES-WORTH-BORROWING.md](pad/FEATURES-WORTH-BORROWING.md),
> dug @ `bcc4a69` (15 commits past the scan pin — an email-verification +
> restricted-owner auth-perimeter sprint): the surface-versioning claim verified
> **stronger** than scanned (two decoupled constants, four advertisement surfaces
> incl. the MCP handshake, an in-file v0.1→v0.7 changelog) but **enforcement is
> manual** — no golden pin, and pad's own handshake `instructions.md` still
> describes the v0.4 surface against v0.7 code (three stale sites); the "closed
> error-code taxonomy" is a **boundary-classification layer** (15 codes at the MCP
> edge, funneled by classifiers + a 2-code whitelist) over an open 40+-code HTTP
> interior. **Attribution is split, not unified**: `status_transitions` rows carry
> NO actor columns (fact only); `created_by`/`source` live on items and the
> `activities` feed — and item-level `source` is never `mcp` (MCP writes stamp
> `cli`; `mcp` exists only on workspace-creation provenance). The **Redis bridge is
> SSE-only** — Yjs collab is single-instance by design (MemoryOpBus hardcoded,
> RedisOpBus a deferred IDEA) while shipped k8s manifests advertise 2–10 replicas
> with no sticky routing; the **PWA is installable-only** (no service worker, no
> offline, no push; a second conflicting manifest sits unreferenced). The playbook
> "draft/active/deprecated lifecycle" is a plain **mutable status field** (no
> versioning, no state machine) — the durable-discipline story is the import-copy
> library with frozen-at-creation snapshots and a **removed** auto-upgrade hook
> (IDEA-1479). `blocks` links are **inert** (no computed blocked state, no release
> semantics — the corpus's third dead-dependency datapoint). Item refs confirmed
> computed-never-stored with a **workspace-global** counter (moves preserve the
> number: IDEA-42 → BUG-42). No notification/inbox/watch model of any kind;
> attention is a capped, computed dashboard array. §5 verified in its strongest
> form: **pad contains no LLM integration at all** (subject 22, structurally
> absent). Also confirmed: 4-perimeter email-verification enforcement, bearer-admin
> suppression (admin authority is cookie-only), and a 7-hole "restricted owner"
> fix family — the argus §4.4 negative-reference material.

## Cross-cutting observations

1. **The execution-layer edit-and-resume slot is still empty — nine more repos, zero
   hits — but this corpus found the *plan-layer* variant the ades corpus lacked.**
   Three real edit gates, all pre-execution: Chorus's proposal editor (edit AI-drafted
   docs *and the task DAG* while draft, approve → materialize into real entities),
   orca's briefing loop (inline draft edits + per-assumption pushback feeding
   regeneration), and myrlin's editable task-spinoff spec forms. During execution the
   field converges on *steering* instead: free-text instruction injection (Chorus
   `deliver_turn`, bosun steer/nudge), comment-triggered `--resume` (multica), or
   pass-back-with-notes re-running a phase (orca). Two sharpenings for argus §5:
   (a) the industry-validated first editor is the **plan/markdown editor at a
   pre-execution gate** — exactly argus sequencing step 4's markdown-first plan, now
   externally confirmed three times; (b) every external "edit" **re-prompts the model
   with the edits** rather than promoting the operator's text as the artifact —
   argus's head-revision promotion (the edited output *is* what the next step
   consumes) remains genuinely novel even against the closest analogs. orca's
   read-only-review-by-design and symphony's tried-then-reverted comment-resume are
   useful negative datapoints: both teams looked at richer in-run intervention and
   backed off. (Dig sharpening 2026-07-04: symphony's revert records no technical
   rationale — "the request was to revert" — so it evidences withdrawal, not
   failure.) **(Dig correction 2026-07-04, Chorus: claim (b) is wrong for Chorus —
   its human-edit path *promotes*: edits write into the same draft JSON the AI
   authored and approve materializes those bytes verbatim, the model never
   re-invoked; only reject-with-note re-prompts. Plan-layer promote-the-edit
   therefore exists in the field once; argus's novelty claim narrows honestly to
   execution-layer head-promotion — which Chorus also verifies empty, the 19th
   subject.)** **(Second dig correction 2026-07-04, orca: claim (b) is wrong for
   orca too — its Accept path promotes the operator's draft edits verbatim
   (`apply_edits_to_draft`, a pure merge; the model is never re-invoked); Refine is
   the re-prompt lane, and per-assumption pushback never promotes — accepted
   without an intervening refine it is audit-trail-only. Plan-layer
   promote-the-edit exists in the field twice; the execution layer stays empty at
   subject 20.)** **(Third dig correction 2026-07-04, myrlin-workbook: its spinoff
   spec editor also promotes verbatim — edited title/description flow unchanged
   into the created tasks, the model never re-invoked — making plan-layer
   promote-the-edit three-for-three among the corpus's edit gates. The sharpening
   is that myrlin's promotion is *severed from execution*: the promoted spec never
   reaches the spawned agent (no initial prompt on the spinoff path; the rich
   handoff endpoint is UI-dead), so argus §5.4 gains an end-to-end acceptance
   criterion — prove the resumed step consumes the head revision's bytes, not
   merely that the revision was stored. Execution layer stays empty at subject
   23.)**

2. **The board is the HITL surface.** Where the ades cockpits routed attention
   through notification badges, this corpus routes *control* through PM artifacts:
   ticket states as gates (symphony/OpenSymphony's `Human Review` is a Linear column,
   not an endpoint), comments as resume triggers (multica), inbox severity as the
   attention feed (multica `action_required`, OpenHelm's task inbox), proposals as
   approval objects (Chorus). multica's considered anti-interactive stance —
   `AskUserQuestion` disabled, clarifications forced into issue comments — is the
   purest statement of the pattern. For argus this cuts both ways: our durable
   `AgentCase` gate family is *ahead* of everything scanned (only bosun has
   comparable gate machinery), but the field unanimously validates **async,
   conversational, phone-answerable** HITL over modal blocking. The argus gate UX
   should feel like answering a comment, not clearing a dialog — which is exactly
   what the §5 review-gate + editor design does, and a useful lens for the XA OQ-1
   standing-approvals conversation.

3. **Worktree-per-task is *not* unanimous here (unlike ades) — and the exceptions are
   instructive.** Yes: multica (worktrees off a bare-clone repo cache — dig 2026-07-04:
   *agent-initiated* via a daemon-local checkout endpoint, task workdirs start empty;
   branch template `agent/{agent}/{task8}`), orca (plus toolchain
   auto-init), bosun (lifecycle manager + recovery state), myrlin (board-integrated),
   OpenSymphony. No: Chorus (plain cwds — session-level isolation only), OpenHelm
   (shared project dir, concurrent jobs collide), upstream symphony (per-issue
   **shallow clones** via lifecycle hook), pad (n/a). The symphony→OpenSymphony fork
   delta — clone-based isolation replaced by worktrees off a cached repo — was
   **verified during this scan** (upstream `elixir/lib` has zero worktree hits; the
   fork's `workspace.ex` builds `git worktree add` scripts) and is a clean isolated
   datapoint that worktrees win on cost once volume rises. (Dig correction
   2026-07-04: the cache is **non-bare** — a full clone with the target branch
   checked out, not the bare repo the scan claimed; the worktree half of the delta
   stands as verified.) New material for argus
   §3.4 delta 4 (node affinity): this corpus solves remote placement three ways —
   symphony's least-loaded SSH worker selection, multica's daemon runtimes with
   heartbeats and capability profiles, Chorus's addressable `(agent, host, cwd)`
   instances with pinned wake delivery. Chorus's pinned-wake model (route the wake to
   exactly the instance that owns the context) is the closest external design to our
   claim-on-`worktree.node` placement policy.

4. **Headless CLI + stream-json + `--resume` is the de facto agent-driving standard**
   — multica, Chorus, orca, OpenHelm, and OpenSymphony's Claude backend all spawn
   `claude -p --output-format stream-json` (or `codex exec --json`) and resume by
   session id; bosun is the outlier on vendor SDKs (while building its own harness to
   leave them); symphony upstream uses Codex's app-server JSON-RPC. Recurring
   hard-won details worth keeping: session UUIDs generated client-side and **anchored
   to the domain entity** (Chorus anchors on the idea UUID; multica pins
   task↔session for crash recovery), new-vs-resume decided by probing the on-disk
   transcript (dig correction: **multica does not probe** — purely flag-driven off the
   server-persisted session id, with a clear-id-then-retry-fresh dance on silent resume
   failure), env scrubbing to avoid nested-session confusion (multica strips
   `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID` by **exact name**, deliberately not the whole
   `CLAUDE_CODE_*` namespace), detached process-group spawn so the MCP
   subtree dies with the parent (OpenHelm), and orca's gotcha list (Claude `plan`
   permission-mode deadlocks against closed stdin; the auditor is hard-clamped to
   never receive `bypassPermissions`). Mostly not our integration axis — JidoClaw
   *is* the agent — but directly relevant if argus ever fronts external agent CLIs as
   additional executors, and the strongest argument yet that the seam belongs behind
   a small adapter behaviour (symphony's `AppServer` dispatch, in our own language,
   is the reference).

5. **Multi-device is table stakes in this corpus — argus's differentiators narrow but
   hold.** Unlike the ades set (uniformly local desktop), five of nine ship a second
   device: multica (web + Electron + native iOS — dig 2026-07-04: **zero push
   code**; attention is in-app inbox over WS only), Chorus (central server, phone
   browser), myrlin (QR-paired native app + push — dig 2026-07-04: two of five
   declared push events actually fire, and the pairing endpoint is
   shipped-broken at HEAD), pad (PWA + LAN/Tailscale +
   cloud), bosun (Telegram Mini App via tunnel). Two run real server Postgres
   (multica, Chorus). What *no one* has: multi-node clustering with a shared DB and
   node-affine execution (every daemon here is a spoke to one hub, not a peer), an
   event-sourced run history behind the UI (bosun and orca event-source internally
   but expose no durable-feed catch-up contract like argus §4.2's
   `workflowEvents(afterSeq:)`), a durable decision object (`AgentCase`-class) an
   agent cannot mint, or execution-layer edit-and-resume. Auth hygiene is again the
   weak flank across the field (symphony: none, localhost; myrlin: shared password +
   pairing tokens; Chorus: real OIDC + API keys, the exception) — the argus §4.4
   posture survives another corpus.

6. **A task layer between Project and Worktree is the corpus's implicit proposal to
   argus.** Argus's hierarchy is project → worktree → runs/sessions; every PM-native
   product here inserts "task/issue" as the unit agents are *assigned*, and binds
   execution to it: multica issues own worktree-scoped runs, orca tasks own
   worktrees 1:1 (branch `orca/<task_id>`), myrlin's board columns *are* worktree
   states, Chorus tasks own agent sessions. The binding direction is consistent —
   task is the durable identity; worktree/session is its execution residue. If argus
   grows a task concept it slots exactly where Worktree creation is triggered today,
   and orca's auto-queue-on-dependency-merge shows what the task layer buys
   (scheduling semantics runs alone can't express: "start B's worktree when A
   lands"). Equally defensible: skip it — symphony delegates the entire layer to
   Linear and stays thinner for it, and pad shows the layer can live in a separate
   product reached over MCP. This is a real, open argus design question the ades
   corpus never posed; it deserves a decision (even "no, runs are enough") before
   the §3 data model freezes.

7. **Five of nine repos have agent committers in their own history** (bosun's
   copilot-swe-agent, multica's "Multica Eve", Chorus's AutoJunjie, myrlin's "Marty",
   OpenHelm's the-today-app) — the products are built by the workflow they sell,
   at solo-plus-agents velocity. Same corollary as ades observation 8: expect
   doc/code drift everywhere, pin commits, treat docs as hypotheses. The scan already
   surfaced version-truth drift (OpenHelm manifest says 0.1.0, releases at v1.3.0;
   multica package.json 0.2.0, changelog v0.3.36) and orphaned terminology
   (OpenSymphony's WORKFLOW.md mixing "Symphony Workpad"/"Codex Workpad").

8. **License discipline map for dig time**: clean — orca (MIT), bosun, pad, symphony,
   OpenSymphony (Apache-2.0). Patterns-only — Chorus and myrlin-workbook (AGPL-3.0,
   the termic rule applies: rubrics and schemas, never code), OpenHelm (BUSL-1.1),
   multica (modified Apache with Dify-style commercial conditions — read the clause
   before lifting anything beyond ideas; for our internal-tool use it almost
   certainly doesn't bind, but keep the habit).

9. **The gate family's defects assemble into the §5.4 acceptance-criteria list**
   *(added in the 2026-07-04 connective pass — the sequential digs each hit one
   defect axis; only side by side do they enumerate the checklist)*. Five axes,
   each with a shipped failure: **fence** — none of the three trackers with a
   plan-approve surface serializes it (multica ships no human approve path at all;
   Chorus double-approve double-materializes, CH1-1; orca double-accept
   double-materializes, its own "fence datapoint #3"); **revision history** —
   Chorus's one overwritten `reviewNote`; **durability** — bosun's poll-loop gates
   re-open to pending on restart *even if already approved* (requests durable,
   waiters in memory); **expiry** — OpenHelm's pending approvals never expire, and
   bosun's BO2-5 independently folded the same gap into ades XA2-1 — three subjects
   now converge on our missing `AgentCase` TTL/sweeper; **timeout direction** —
   bosun's workflow gate defaults `onTimeout:"proceed"` (timeout = auto-approve),
   the corpus's sharpest argument for the inverted house rule (a gate timeout only
   ever fails closed). Riding beside them, the **decided-after-death** question only
   OpenHelm answers (its approve executes the stored payload platform-side after the
   run ended; ours grants a retry a live agent loop must re-issue — OH OQ-2, the
   design decision argus phone approvals owe per gate kind). We ship the fence today
   (FOR-UPDATE + single-use `:consume`); the criterion, as the orca dig put it, is
   "keep it" — and add the missing axes.

10. **The attention/delivery mechanics layer assembled itself across four digs —
    none could see the others** *(2026-07-04 connective pass; the composition
    mirrors ades observation 6, one layer down)*. Under the ades trigger set
    (EM1-3/TM2-5/XA1-2) and CC1-2's read-model, the pms digs supplied the delivery
    *policy* layer: bosun owns **aggregation**
    ([BO1-3](bosun/FEATURES-WORTH-BORROWING.md) — immediate-vs-digest split, the
    edited-in-place live digest, the pinned status board; the corpus's only shipped
    aggregation story); OpenHelm owns **storm semantics**
    ([OH2-2](openhelm/FEATURES-WORTH-BORROWING.md) — caller-supplied semantic dedup
    keys, touch-in-place priority escalation, 16-failing-jobs→one-incident collapse,
    the never-vanish fallback row, additive email-on-attention); myrlin owns the
    **device-side rules** ([MY1-3](myrlin-workbook/FEATURES-WORTH-BORROWING.md) —
    replay suppression on reconnect, focus-ack-consumes, minimum-signal re-arm,
    per-device batch-coalescing, prune-on-provider-rejection); Chorus owns the
    **recipient model** ([CH2-3](chorus/FEATURES-WORTH-BORROWING.md) — per-kind mute
    booleans, wake ≠ read, notifications as a projection over the activity stream).
    The negatives complete it: multica's severity theater (three levels declared,
    ~two live, no UI consumes severity, `task_completed` deliberately writes no
    inbox row) and pad's no-notification-model-at-all (attention as a capped
    *computed* dashboard array — confirming CC1-2's computed-feed shape from the
    null side). Slice 1 consumes the whole stack; the open seams to decide together
    are bosun OQ-2 (adopt the digest split?), chorus OQ-3 (per-kind vs severity),
    and multica OQ-3 (deferred escalation).

11. **Teardown spectrum, pms edition — the ades spectrum gains a branch/PR axis**
    *(2026-07-04 connective pass; the members were dug in an order that hid the
    line — symphony's answer landed five digs before the weak-enders it answers)*.
    Weakest to strongest: orca **destroys** (force-delete on every path, branch
    included — rejected work unrecoverable) < myrlin **leaks** (record-delete
    strands worktree + branch, no reconciliation sweep; the two are the corpus's
    paired anti-references, opposite failure modes) < bosun's middle (dir
    force-removed, branches survive, age sweeps + zombie status + boot maintenance)
    < multica's GC taxonomy (full/orphan/artifact-only modes + worktree prune +
    branch cleanup — stranded PRs honestly not detected) <
    [SY2-4](symphony/FEATURES-WORTH-BORROWING.md) (`before_remove` closes stranded
    open PRs — the only PR-side sweep in either corpus). Kin at other layers:
    OpenHelm's age-guarded orphan reclaim + orphan-schedule reconciler (cron-side),
    pad's soft-delete-without-cascades (substrate-side), Chorus's orphaned
    `running` turns with no reaper (turn-side). The composite law for FLOW §5:
    phased + dirty-checked (ades TR2-1/MX2-2) + PR-aware (SY2-4) + a
    records↔worktrees reconciliation sweep (the leg myrlin and pad are missing) —
    every product on the line is missing at least one leg, and paid visibly.

12. **The health shelf: classify before counting, then break, then watch the
    watcher** *(2026-07-04 connective pass)*. Four subjects shipped failure
    *classification* as the precondition for counting — multica's 21-reason
    run-failure taxonomy with retryable/resume-unsafe subsets (MC1-4), bosun's
    executor infra-vs-session split + poisoned-thread list (BO2-3, folded into
    MC1-4), OpenHelm's transient ≠ rate-limit ≠ infra rule ("a rate-limited job is
    not a failing job"), myrlin's three-state token health (transients never mark
    dead) — all converging on the law our shipped Verdict normalizer (camus C1-3)
    states in-house. Above it, the breaker family: multica's auto-pause (fail-ratio
    0.9 over 7d), OpenHelm's persisted consecutive-failure breaker with bounded
    auto-recovery (the 9-hour-pause paid lesson), bosun's sentinel crash-loop +
    recovery breakers, myrlin's crash-loop persistent latch. Above that, XA1-2's
    watch-the-watcher rule shipped twice, independently: bosun's off-process
    sentinel (a literally separate process) and OpenHelm's heartbeat watchdog with
    process-exit escalation. And twice, never cross-cited until this pass,
    **rate-limit as a first-class schedulable state**: symphony's six-state account
    health with the shipped reset-header probe (SY1-4, the XA2-3 sibling) and
    OpenHelm's defer-all-runs-to-reset. FLOW §8's checklist membership is now
    MC2-5 (admission gate / visible skip / breaker) + SY1-2
    (reconcile-before-dispatch / backoff / stall) + MY2-6 (skip-and-record, the
    third confirmation) + OH2-1 (charge-before-call budget ledger) — with MC1-4 the
    shared taxonomy seam every one of them classifies into.

13. **Declared surface ≥ live surface, everywhere — the wiring-mortality census**
    *(2026-07-04 connective pass; extends ades observation 8 from doc drift to code
    liveness)*. All eight digs found shipped-but-dead subsystems — not stale docs,
    dead *code paths*: multica's `issue_dependency` table + four producerless inbox
    types; Chorus's dead proposal statuses, guard-free write tools, and phantom
    architecture docs; symphony's never-consumed `stall_timeout_ms`, the misnamed
    `usage_aware_round_robin`, and two fork capability deletions; orca's
    dead-rendered anchors, always-`None` correlation columns, and dead briefing
    prompt; bosun's deleted-in-production sync engine, `ask_user`
    writer-with-no-reader, and stub `/remediate`; pad's three-versions-stale
    handshake instructions and hardcoded `tool_surface_stable: true`; myrlin's
    3-of-5 dead push events and 429-broken pairing endpoint (the asserting test
    exists and doesn't gate releases); OpenHelm's dead risk gate, write-only run
    snapshot, and unwired cost proxy. The four digs that tallied corrections alone
    count 26 (multica 6, orca 6, pad 5, bosun 9) — most of them liveness, not
    drift. Two laws fall out. (a) **Advertisement without mechanical enforcement
    rots** (pad's PD1-1, re-proven same-day by myrlin's pairing bug — and by our
    own tree: the MCP server advertising `0.2.0` on an `0.6.4` app, a moduledoc
    promising a replay command that doesn't exist, the dormant `:schedule` Trace
    channel, `Forge.apply_input/2` with zero callers). (b) **A dependency edge
    survives only if a scheduler consumes it** — the census: multica's
    `issue_dependency` (dead table), bosun's `blockedByTaskIds` (never iterated;
    its live pull-gate reads other state), pad's `blocks` (no consumer), myrlin's
    `blockedBy` (badges only) — four dead; against orca's queue-then-release
    (mechanical, human-armed, canceled-keeps-blocked) and multica's stage barriers
    (agent-mediated) — two live; with Chorus between (DAG edges materialize into
    real rows that structure and render, but nothing schedules off them). Pad's
    rule is the design law for FLOW §7's `Task.depends_on`: "ship the release
    semantics with them or not at all."

## Early read (to be challenged at dig time)

1. **multica** — the priority dig once argus implementation starts: the only scanned
   product with argus's full server topology (shared Postgres, multi-device clients,
   node-attached execution) *plus* worktree-per-task *plus* a shipped
   agents-as-assignees schema. Scope a dig at: the issue⇄run⇄worktree binding
   (`execenv/git.go`, repocache), the daemon protocol (heartbeats, capability
   profiles, pinned delivery), the Claude driver edge-case list (`claude.go`), and
   the inbox/severity attention model. Also the best subject for observation 6 (task
   layer) with real schema to study. Caveat: modified-Apache license, read first.
2. **Chorus** — dig when argus §5 gets its design pass: the proposal-editor
   (draft-edit-approve-materialize, including DAG editing UX and the
   `canEdit = draft` state guard), the reverse control channel (interrupt double-check,
   instruction injection), and the unified user-or-agent Notification/wake model are
   all §5/§6.2-adjacent. AGPL — patterns only.
3. **symphony + OpenSymphony** — one joint targeted read, not two digs: the Codex
   app-server client (near-liftable, our language), the orchestrator dispatch loop,
   `WORKFLOW.md`-as-validated-contract, SSH worker selection, and the fork's
   worktree + multi-backend + account-rotation deltas. Trigger: when argus needs a
   second executor backend, or when the run-scheduler/node-placement work starts.
4. **orca** — targeted read alongside the §5 editor work and the Worktree domain
   modeling: DAG auto-queue semantics, worktree auto-init, the auditor verdict
   schema (severity + line-anchored concerns is a ready shape for review-gate
   payloads), briefing-loop event vocabulary, and the event-store conventions
   (`command_id` idempotency, correlation/causation) as an external mirror of our
   own spine. MIT, small, quiet — low risk of drift before we get there.
5. **bosun** — targeted read only (the codebase is enormous and monolithic): the
   projection/ledger contracts, worktree recovery state machine, and the Telegram
   approval UX. Skepticism warranted: feature breadth at 0.43 with two main authors
   suggests scan claims may describe aspiration; verify the gate family actually
   round-trips before citing it.
6. **myrlin-workbook** — pattern notes only, largely superseded by the ades digs on
   the cockpit side; the unique residue is the per-event push-subscription taxonomy
   (extends the ades §6.2 trigger set with `fileConflicts` — cross-agent conflict
   detection is a trigger nobody in ades had), the QR-pair device-enrollment flow,
   and the task-spinoff editable-spec form. AGPL.
7. **pad** — pattern notes when the argus GraphQL surface freezes: the
   tool-surface/error-taxonomy versioning is a second precedent beside traycer
   TR1-1/TR1-2, and playbooks-as-data is a datapoint for the skills-authoring story.
   Also the reference answer if we ever want argus data *exposed to* third-party
   agents rather than only operated by ours.
8. ~~**OpenHelm** — no dig planned. Keep as contrast (fleet-ops posture, BUSL) and
   two pattern citations: the risk-taxonomy gate (a graduated version of our binary
   require-list) and run-snapshot-for-resume (we get the equivalent from encrypted
   checkpoints; theirs pins resolved tool scope + creds too, worth remembering when
   composer stages gain external MCP reach).~~ **Reversed and dug 2026-07-04** on
   operator request — and both recorded citations were wrong at HEAD (the per-tool
   risk gate is dead code; the run snapshot is write-only). See the dig-corrections
   block above and
   [openhelm/FEATURES-WORTH-BORROWING.md](openhelm/FEATURES-WORTH-BORROWING.md); the
   composer-external-MCP-reach trigger survives as OH2-4 (TRACK, drift-detection
   first).

## Suggested next steps

> **Dig briefs (2026-07-04)**: [DIG-BRIEFS.md](DIG-BRIEFS.md) — per-repo standing
> questions from the argus product-flow pass ([../argus/FLOW.md](../argus/FLOW.md)).
> Full explorations expected; the questions ride along, they do not scope.

- [x] ~~Decide the task-layer question~~ **Decided 2026-07-04** — argus grows a
      native task layer: per-project statuses grouped into display lanes, a
      seven-kind semantic enum, task↔thread M:N with a one-task-per-thread
      default ([../argus/FLOW.md](../argus/FLOW.md) §7); multica's schema remains
      the dig reference to pressure-test the field shapes.
- [x] ~~Dig multica~~ **Done 2026-07-04** —
      [multica/FEATURES-WORTH-BORROWING.md](multica/FEATURES-WORTH-BORROWING.md)
      @ `129efb768`: richest validation + reference haul of the corpus — pinned
      placement / visible-skip automation / task-scoped credentials validate four
      FLOW decisions; headline borrows are the CLI session-resume stack (MC1-1 —
      our Forge runners fake resume today), the task-schema field reference +
      status-kind evidence (MC1-2), stage-barriers→parent-agent dispatch (MC1-3),
      and the 21-reason run-failure taxonomy (MC1-4); §5 edit-and-resume verified
      empty at all four layers (16th subject); six scan claims corrected (see the
      dig-corrections block above).
- [x] ~~Dig Chorus~~ **Done 2026-07-04** —
      [chorus/FEATURES-WORTH-BORROWING.md](chorus/FEATURES-WORTH-BORROWING.md)
      @ `47b5bb6`: the §5 design pass has its precedent — Chorus ships **plan-layer
      promote-the-edit** (observation 1(b) corrected above; execution layer verified
      empty, 19th subject), and its two missing fences (approve idempotency, revision
      history) become §5.4 acceptance criteria (CH1-1); FLOW's steering question is
      answered — the field ships boundary delivery, not mid-turn injection, our agent
      mailbox already queues turns, and the dep's `steer/inject` sits unwired (CH1-2,
      with the do-now Forge needs-input reply loop closing CC1-2's dead-end);
      pinned-wake hard/soft ladder + identity/liveness instance split feed FLOW §2 /
      OVERVIEW §3.3 (CH1-3/-4); scan corrected (79 tools 42-gated agent-only, yolo
      default, next-boundary injection, no push, no revision history).
- [x] ~~Joint targeted read: symphony + OpenSymphony~~ **Done 2026-07-04** —
      [symphony/FEATURES-WORTH-BORROWING.md](symphony/FEATURES-WORTH-BORROWING.md)
      (one joint doc, `SY-*`): the CLI-engine reference stack is complete in our
      language (SY1-1 app-server client, superseding hermes T2-13; composes with
      MC1-1); dispatch hygiene joins MC2-5 as the FLOW §8 checklist (SY1-2);
      validated-config contract for FLOW §9 (SY1-3); multi-account rotation +
      the shipped XA2-3 probe (SY1-4); same-language worktree plumbing with the
      bare-repo scan correction (SY2-1); blocked-input taxonomy the fork deleted
      (SY2-2); teardown PR sweep — the corpus's first stranded-PR answer (SY2-4).
      §5 verified empty at both layers (17th/18th subjects); several scan claims
      corrected (see the dig-corrections block above).
- [x] ~~Targeted read: orca~~ **Done 2026-07-04** (upgraded to a full dig) —
      [orca/FEATURES-WORTH-BORROWING.md](orca/FEATURES-WORTH-BORROWING.md)
      @ `2520b31` (zero drift from the scan pin): the corpus's best
      reference-schema haul per line read — headline borrows are the
      review-verdict payload reference with the anchor-fidelity taxonomy and two
      paid-for drift lessons (OR1-1, feeding argus §5.3 / next-ten #6), the
      catch-up staleness enum + stale-approval doctrine + resolution-as-proposal
      (OR1-2, validating FLOW §6's merge-back doctrine), queue-then-release
      dependency semantics with canceled-keeps-blocked shipped (OR1-3), and the
      worktree toolchain-init table + init-status split (OR1-4); two
      adoptable-now items queued ([orca/OR-FIRST-WAVE.md](orca/OR-FIRST-WAVE.md):
      our step-projection rebuild IOU, the non-interactive env floor); §5
      edit-and-resume verified empty at the execution layer (20th subject) while
      observation 1(b) is corrected a second time — orca's Accept promotes;
      six scan claims corrected (see the dig-corrections block above).
- [x] ~~Targeted read: bosun~~ **Done 2026-07-04** (upgraded to a full dig — the
      readers kept overturning scan claims) —
      [bosun/FEATURES-WORTH-BORROWING.md](bosun/FEATURES-WORTH-BORROWING.md)
      @ `18e079f6` (scan pin, zero drift): the feature-superset comparable doubles as
      the corpus's most instructive wreck survey — verification found the two-way
      sync engine deleted in production (FLOW §7's rejection now
      counterexample-backed), the risky-action gate default-off with
      timeout-means-proceed, resumed gates re-opening to pending, and approvals
      decidable only in the Mini App; what survives is the headline haul — the
      corpus's only shipped interrupted-run auto-resume (BO1-1: fences +
      unresumable-reason taxonomy, the reference for our documented-missing resume
      path), the 13-type anomaly taxonomy + off-process sentinel watchdog (BO1-2),
      the field's richest phone delivery shapes (BO1-3: immediate-vs-digest split,
      live digest, pinned status board), the deleted-sync-engine checklist + 7-state
      task-machine lessons (BO1-4), and the field's one shipped mid-turn steer
      (BO2-4, Claude SDK streaming input). §5 edit-and-resume verified empty at
      subject 21; nine scan claims corrected (see the dig-corrections block above).
- [x] ~~Pattern notes: pad~~ **Done 2026-07-04** (upgraded to a full dig — run
      ahead of its "API-surface freeze" trigger because argus implementation is
      beginning) — [pad/FEATURES-WORTH-BORROWING.md](pad/FEATURES-WORTH-BORROWING.md)
      @ `bcc4a69`: the field's best agent-surface contract-discipline donor —
      headline borrows are the served-surface stability contract fused with traycer
      TR1-2a as a do-today PR (PD1-1 — the seams pass found our MCP server
      advertising a hardcoded `0.2.0` on an `0.6.4` app, pad's rot lesson live in
      our tree), the closed-at-the-boundary error contract with typed hints
      (PD1-2), the FLOW §7 task-schema reference (PD1-3: workspace-global computed
      refs, terminal classification, open-children guard, inert-`blocks` negative),
      and shipped validation for FLOW §13's import-copy seam incl. the
      removed-auto-upgrade negative result (PD1-4); §5 verified structurally absent
      (subject 22 — pad has no LLM code at all); five scan claims corrected (see
      the dig-corrections block above); three adoptable-now items queued
      ([pad/PD-FIRST-WAVE.md](pad/PD-FIRST-WAVE.md): the stability-contract PR
      superseding TR1-2a, the boundary error-code registry, the `/setup` doctor).
- [x] ~~Pattern notes: myrlin-workbook~~ **Done 2026-07-04** (upgraded to a full
      dig — the readers kept overturning scan claims, same as bosun) —
      [myrlin-workbook/FEATURES-WORTH-BORROWING.md](myrlin-workbook/FEATURES-WORTH-BORROWING.md)
      @ `7e26a80d` (scan pin, zero drift): the predicted residue survives
      reshaped — the push taxonomy is 5-declared/2-live (the `fileConflicts` push
      is dead code; the live pair is exactly emdash's EM1-3 set), the QR-pair
      enrollment ladder is the OVERVIEW §4.4 reference but ships broken at HEAD
      (pairing always 429s — a missed call site in a helper refactor), and the
      spinoff editable-spec form promotes verbatim but into a record no agent
      consumes; the unpredicted headline is the **credential lineage guard**
      (MY1-1 — cross-machine OAuth refresh-token theft, found and fixed; the
      file-mechanics half of SY1-4) plus three storm-tested delivery rules for
      slice 1 (MY1-3: replay suppression, focus-ack-consumes, min-signal
      re-arm). §5 verified empty at subject 23; observation 1(b) corrected a
      third time (see above); one argus-independent do-now queued inline
      (MY1-4a: a `mix jidoclaw.api_key` task — our side has zero key-minting
      paths).
- [x] ~~Fold myrlin's `fileConflicts` push trigger into the argus OVERVIEW's
      deferred-question notes (§6.2)~~ **Done 2026-07-04** by the myrlin dig,
      with the correction attached: the trigger concept stands (and FLOW §12
      already adopted it), but myrlin's own conflict→push wiring is dead — the
      §6.2 note now cites the two detector shapes (MY1-2) as the buildable half.
      *(The pad half of this item — tool-surface versioning into §6.3 — was done
      2026-07-04 by the pad dig.)*
- [x] ~~No action: OpenHelm (contrast reference only)~~ **Reversed — dug 2026-07-04**
      on operator request as argus implementation begins —
      [openhelm/FEATURES-WORTH-BORROWING.md](openhelm/FEATURES-WORTH-BORROWING.md)
      @ `2facabaa` (5 same-day commits past the scan pin; Autopilot v2 landed in the
      gap): both recorded citations corrected (per-tool risk gate dead, run snapshot
      write-only); headline haul is the cron-health breaker family (OH1-1, with an
      adoptable-now our-side slice — our cron failures are currently invisible:
      in-memory counter, vanishing disabled rows, status-blind telemetry), the
      autonomy-dial × action-class × apply-with-undo approval stack (OH1-2), and
      evaluator/outcome-contract convergence recorded as riders on next-ten #5/#6/#9/#10
      (OH1-3, [openhelm/OH-FIRST-WAVE.md](openhelm/OH-FIRST-WAVE.md)); §5 verified
      empty at subject 24, closing the corpus with argus's differentiators intact.

**Combined first wave** (2026-07-04 connective pass — the argus-independent do-now
set rolled up across the six first-wave queues plus the one inline item (corrected
2026-07-09: this said "two inline items" — an overcount; the two queue-less
inventories each held a slot, but only myrlin's is filled (MY1-4a) and bosun's is
deliberately empty, as the last bullet records); the individual queues each
recorded their own riders, but this is the one place the whole set and its
cross-queue sequencing are visible):

- **MC1-4 → MC1-1 → MC3-4** ([MC-FIRST-WAVE](multica/MC-FIRST-WAVE.md)): the failure
  taxonomy first (S — its `resume_unsafe?/1` is what resume consumes), then native
  CLI session resume for the Forge runners (M — the corpus-wide composition target:
  riders attached from the orca dig (OR3-2 dual-timeout split + group-kill), the
  Chorus dig (anchor-ownership axis + group teardown, CH2-6/CH3-2), symphony (SY3-3
  continuation-turn discipline rides the same build), and — added this pass — bosun
  (BO2-3's infra-vs-session split into MC1-4, its Codex poisoned-resume inventory
  into MC1-1)), then exit-code tiering (XS — consume PD1-2's registry rather than
  re-sniffing, whichever lands second).
- **SY canary · config boot · stage-stalled** ([SY-FIRST-WAVE](symphony/SY-FIRST-WAVE.md)):
  the scheduled provider credential canary (S — **closes ades XA2-3**), fail-closed
  `.jido/config.yaml` boot + last-known-good re-read (S), and the composer wave
  inactivity clock `:stage_stalled` (M — soft-depends on MC1-4).
- **CH needs-input reply loop · headless fragment** ([CH-FIRST-WAVE](chorus/CH-FIRST-WAVE.md)):
  wire `Forge.apply_input/2` end-to-end (S — **completes ades CC1-2a's missing reply
  half**), plus the headless-contract prompt fragment (XS).
- **PD stability contract · error registry · doctor** ([PD-FIRST-WAVE](pad/PD-FIRST-WAVE.md)):
  the served-surface stability PR (S — kills the hardcoded MCP `0.2.0`, **supersedes
  ades TR1-2a**), the boundary error-code registry (S — MC3-4's consumer), and the
  `/setup` doctor (S).
- **OH cron-health slice** ([OH-FIRST-WAVE](openhelm/OH-FIRST-WAVE.md)): persist the
  breaker, classify before counting (reuses MC1-4's split), stop disabled rows
  vanishing, outcome-tagged telemetry + the `:schedule` Trace channel's first
  producer (S).
- **OR reproject · env floor** ([OR-FIRST-WAVE](orca/OR-FIRST-WAVE.md)): build the
  step-projection rebuild we already claim (`mix jidoclaw.reproject_steps`, S) and
  the non-interactive subprocess env floor (XS).
- **MY1-4a** (inline, [myrlin](myrlin-workbook/FEATURES-WORTH-BORROWING.md)): a
  `mix jidoclaw.api_key` mint/list/revoke task — `Accounts.ApiKey` has zero minting
  paths today (S). bosun deliberately queued nothing standalone (its adoptables
  landed as next-ten riders).

*(2026-07-09: this merged set — re-statused against HEAD, minus items since
shipped — is queued as
[docs/plans/pre-argus-do-now](../../plans/pre-argus-do-now/README.md), together
with three recovered items the rollups missed and the crabbox CB1-1/CB1-2
pair.)*
