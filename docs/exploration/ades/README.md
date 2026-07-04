# Agent Control-Plane Landscape Scan (ades)

**Status**: initial scan (2026-07-03), with **all six deep-dives — traycer, emdash,
termic, claude-command-center, muxara, and (trigger-fired later the same day) Xantham —
completed** (see each repo's "Dig outcome" paragraph and linked inventory), plus a
same-day **connective pass** stitching what the parallel digs couldn't see of each
other: cross-cutting observations 6–8, the combined first wave at the bottom, and
dated back-links added into the earlier inventories.
The scan itself was a quick pass over the repos cloned at `~/workspace/research/ades/`
— six parallel read-only scan passes (README + docs skim, manifests, top-level source
layout, a handful of key files) plus git metadata. For the five dug repos, claims are
firsthand code reads; for the rest, treat every claim as "per their docs / light skim"
until a follow-up dig verifies it. Scanned at: claude-command-center
@ `e53d51d`, emdash @ `c67e93e8`, muxara @ `1046684`, termic @ `5c236b6`, traycer
@ `b09cf8d`, Xantham-system-blueprint @ `c5db232`; jido_radclaw as of 2026-07-03.

**Goal**: place each project relative to the [argus](../argus/OVERVIEW.md) control-plane
effort before that work starts — which are whole-product comparables (design references
for the thing we're about to build), which are pattern donors for specific argus
subsystems (the Worktree domain, review checkpoints, the live event layer, the client),
and which are noise. Every project in this set is a variation on argus's thesis —
"one surface for many parallel coding agents" — which makes the *differences*
(multi-device, shared DB, phone, structured events) the interesting data.

## Where argus stands today (the seams these would plug into)

- **Decided architecture** (`../argus/OVERVIEW.md` §2): clustered JidoClaw nodes over
  Tailscale + one shared Postgres; GraphQL (AshGraphql) for queries/mutations + Phoenix
  Channels for live events; client = React + Apollo SPA/PWA, phone-friendly, Web Push.
  Every project scanned here chose the inverse on at least two of those axes
  (local-first, no server DB, desktop form factor).
- **Worktree domain to be built** (§3.1–3.3): `Worktree` as a git facet stacked on
  `Workspace`, with `branch`/`status`/`node` and node-affinity for runs. **No worktree
  functionality exists in our codebase today** (OVERVIEW appendix A.2) — so external
  worktree designs are at their most useful right now, before we model it.
- **Review checkpoints** (§5): the one behavioral change argus makes to the gate family —
  a `:review` gate kind, revision events in the ref-store, `GateResume` promoting the
  head revision, step-type-specific editors (markdown / code_diff / json / prompt /
  command_list). The scan's standing question for each repo: *does anyone already have
  edit-the-step-output-and-resume?* (Spoiler: no.)
- **What we already have** that these projects lack: event-sourced runs
  (`WorkflowEvent` log + projections), a durable gate/approval family (`AgentCase`,
  `Cases.decide/4`), leases + reclaim for single-writer runs, MCP observe/control
  tools, cluster wiring. All five apps below infer agent state by scraping terminals;
  we get structured events for free — borrow their *taxonomy and UX*, never their
  detection machinery.
- Threat model (personal, tailnet-only): LLM misbehavior + leakage hygiene, not
  external attackers. CCC's no-auth tailnet posture is the cautionary reference here.

## Quick comparison

| Repo | What it is | Tech / persistence | License | Activity | Fit |
| --- | --- | --- | --- | --- | --- |
| [claude-command-center](https://github.com/amirfish1/claude-command-center) | Local dashboard for every Claude Code/Codex/Cursor/Antigravity/Kilo session on the machine | Python stdlib server + vanilla JS; REST + SSE; no DB (rescans `~/.claude/**` per request) | MIT | 2,019 commits, solo author (aliases), active Jul 2026, v5.5.0 alpha | **Dug 2026-07-03** → [inventory](claude-command-center/FEATURES-WORTH-BORROWING.md): the attention layer is the haul — soft-block rubric + `ended_blocked` + attention-feed read-model, with a do-today slice (LoopGuard halts, cron failures, Forge `:needs_input` reach no operator surface today); mtime-409 is a **half-precedent** (server contract real, client recovery never built); trust posture = the corpus's sharpest negative reference for argus §4.4 |
| [emdash](https://github.com/generalaction/emdash) | Desktop app for parallel coding agents, one git worktree per task (General Action, YC W26) | Electron/TS nx monorepo; React + Solid; SQLite + Drizzle; PTY default + opt-in ACP (Claude/Codex only) | Apache-2.0 | 8,044 commits, 126 contributors, very active Jul 2026, v1.1.36 | **Dug 2026-07-03** → [inventory](emdash/FEATURES-WORTH-BORROWING.md): worktree provisioning *practice* (preservePatterns, idempotent setup steps — composes with traycer's schemas), shipped two-trigger notification taxonomy, attention fold + seen-flag, minimal-ACP-server brief; Plan Mode is deleted code — **no edit-and-resume**; one do-today gate gap (EM2-3) |
| [muxara](https://github.com/muxara/muxara) | macOS mission control for parallel Claude Code tmux sessions | Tauri 2 (Rust + React 19); no DB, reconciles from tmux each poll | MIT | 72 commits, solo author (2 aliases), quiet since May 2026, v0.1.5 | **Dug 2026-07-03** → [inventory](muxara/FEATURES-WORTH-BORROWING.md): the taxonomy delivers as the **single-agent status contract** (MX1-1 — sub-typed needs-input, plan-mode as an orthogonal modifier, honest `unknown`, asymmetric damping; every signal maps to structured events we already emit); the attention-sort claim inverts — the set's only shipping sorter exhibits the churn defect (positional selection drift) that seals CC2-1/EM2-1's badges-not-reordering verdict; unflagged find: worktree lifecycle datapoints (agent-owned creation via `claude -w`, dirty-check-blocked teardown) |
| [termic](https://github.com/simion/termic) | "One window, many parallel coding agents, each in its own git worktree" — open Conductor alternative | Tauri 2 (Rust + React 19); PTY-spawns real agent CLIs; JSON-file persistence | **AGPL-3.0** | 392 commits, 7 contributors, ~7 weeks old, multiple releases/week, v0.17.7 | **Dug 2026-07-03** → [inventory](termic/FEATURES-WORTH-BORROWING.md) (**patterns only — AGPL**): do-today = emit the work-done protocol from our own CLI (TM1-1 — the agent CLIs already broadcast turn state over OSC; termic listens, we can speak); cage trust rules → Forge + crabbox CB1-1 (TM1-2); Spotlight = the preview-worktree spec (TM1-3, gated on EM2-3); edit-and-resume verified absent — the §5 sweep is complete |
| [traycer](https://github.com/traycerai/traycer) | Traycer AI's full orchestration product, open-sourced — BYOA orchestrator over Claude Code/Codex/Cursor/OpenCode | Electron 42 + React 19, Bun + Nx, ~440k LOC; yjs CRDT; versioned WS-RPC; SQLite + cloud sync | Apache-2.0 | 113 commits (history likely squashed at open-sourcing; PRs to #187), 8 contributors, active Jul 2026, v0.x | **Dug 2026-07-03** → [inventory](traycer/FEATURES-WORTH-BORROWING.md): closest *contract-layer* comparable (host binary is closed-source; epic is a CRDT container, not a DAG); haul = versioned-RPC skew layer (TR1-1/-2) + worktree schema cribs (TR1-3/-4); checkpoints are per-turn file undo — **no edit-and-resume** |
| [Xantham-system-blueprint](https://github.com/ZQadus/Xantham-system-blueprint) | Paste-into-Claude-Code "self-installing personal AI orchestrator" blueprint (Telegram-driven) | ~18k lines of markdown wizard/templates + real bash hooks + a Docker audit sandbox | MIT | 61 commits, 1 author, last Jun 2026, v32 | **Dug 2026-07-03** → [inventory](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md): "contrast only" holds architecturally, and the dig still pays — the Telegram gate lands as argus §4.4's **second negative reference** (the model sits inside the approval TCB and the ledger inside the agent's write reach, per its own unusually honest SECURITY.md); the notification set is the **third §6.2 answer** (+ the rule the others never state: infra alerts must not ride the agent path); holding their gate against ours exposed two our-side gaps (unconsumed approvals never expire, XA2-1; no hard-block tier, XA2-2) plus the do-today credential canary (XA2-3 — `check_provider` exists, nothing schedules it) |

## Categories

### 1. Parallel-worktree agent cockpits — the whole-product comparables

The "Conductor-shaped" cluster: spawn N agents, each in its own git worktree, watch
them, review diffs, merge. All three are desktop apps with the inverse architecture to
argus (local-first, no cluster, no shared DB, no phone), which is exactly what makes
them useful — they've each solved the *sub-problems* argus is about to hit, under
harsher constraints (no structured events, no server).

**traycer** (traycerai). The full commercial product, open-sourced Apache-2.0: Electron
host + local host process, React 19 GUI, a 183-file shared `protocol/` package (Zod +
yjs), bespoke versioned WebSocket RPC with schema-version negotiation/bridging, local
SQLite + cloud sync, realtime CRDT collaboration. Per their docs: parallel multi-agent
runs with shared context, agent-to-agent messaging, and **first-class git worktrees** —
`protocol/src/host/worktree-schemas.ts` models per-entry local|worktree mode, a
WorktreeBinding projected into snapshots, a setup state machine, and **device-local
paths kept private to each host** — the closest thing in the wild to argus §3's
node-affinity Worktree. "Epic mode" is their plan/spec-driven surface (spatial canvas,
artifacts, `persistence/epic/checkpoint-manifests.ts`) — the scan did *not* confirm an
explicit pause-edit-resume gate; that's the first question for the dig. Two more
argus-relevant finds: the protocol layer treats client/host schema skew as first-class
(`versioned-rpc`, `compatibility-checker`, `json-schema-fingerprint`) — directly
relevant to argus's rolling-upgrade skew between cluster nodes and a separately-shipped
SPA (OVERVIEW §6.3 picked codegen tooling as an open question; skew handling is the
harder half) — and MCP is consumed as a first-class integration surface.

**Dig outcome (2026-07-03** — [traycer/FEATURES-WORTH-BORROWING.md](traycer/FEATURES-WORTH-BORROWING.md)**)**,
correcting three scan claims: (1) the repo is the open-source **clients + CLI +
protocol only** — the host binary that executes git/checkpoint/agent work is a
closed-source signed binary, so the readable layer is the *contract*, which is exactly
what argus needs. (2) The pause-edit-resume question is answered **no**: plans are
approve/reject/dismiss (GUI plan mode is non-blocking, no gate at all), the checkpoint
manifests are per-*turn file undo* (content-addressed snapshots + honest per-file
restore results), and an epic is a CRDT container document — phases were removed in
their 3.0; there is no execution DAG. Traycer is a contract-layer comparable, not an
orchestration comparable. (3) The versioned-RPC layer is *richer* than scanned:
per-method `{major,minor}` manifests negotiated at connect, a pure compatibility
oracle, "newer side owns transforms", additive-minor invariants enforced at registry
load, and a CI-frozen released-surface golden born from two real skew incidents — the
headline borrow (TR1-1/TR1-2).

**emdash** (General Action, YC W26). The biggest codebase of the set: Electron/TS nx
monorepo, React renderer plus a Solid-based chat renderer, SQLite + Drizzle, multi-
provider agent registry (Claude Code, Codex, Cursor, Gemini, Amp, Devin, …). Adopts
**ACP (Agent Client Protocol)** as its session runtime — state machine,
permissions/resolvePermission with auto-approve, terminal management — rather than
bespoke per-agent plumbing. Worktree-per-task is core (`worktree-service.ts`: branch
prefixes, preservePatterns, setup/run/teardown lifecycle scripts). "Plan Mode" is a
read-only research→plan→approve→execute gate — approval-shaped, not edit-shaped. The
sleeper: `apps/workspace-server`, a remote daemon exposing a fully-specced workspace
contract over oRPC (git/files/deps/acp/ptyAgent + protocol negotiation) — currently
almost entirely `notImplemented` stubs, but it documents exactly what a desktop cockpit
thinks a remote workspace API needs; a useful checklist to diff against argus's
GraphQL surface.

**Dig outcome (2026-07-03** — [emdash/FEATURES-WORTH-BORROWING.md](emdash/FEATURES-WORTH-BORROWING.md)**)**,
correcting three scan claims: (1) ACP is **not** "its session runtime" — it's an
opt-in chat transport for Claude/Codex only (2 of ~37 providers; the default is PTY
with per-provider bypass flags, and auto-approve exists only on the PTY side; the ACP
path has no auto-approve and persists no grants). (2) **Plan Mode is deleted code** —
the documented read-only mode was removed in the 2026-06 monorepo restructure and never
rebuilt; `PLANNING.md` is an orphan doc. The §5-novelty conclusion *holds and is now
verified*: no edit-step-output-and-resume anywhere (diff comments spawn a new prompt;
Monaco edits touch files, not step output). (3) The workspace-server is quantified at
**2 of 130 procedures implemented**, no auth, binds all interfaces — contract-first
scaffold, checklist value only. The durable borrows: worktree provisioning practice
(preservePatterns with three safety rules, idempotent compiled setup steps — EM1-1/-2),
the shipped two-trigger notification taxonomy (EM1-3, answers argus §6.2), the
attention fold + seen-flag (EM2-1), and the minimal ACP server surface, now enumerated
at four methods + two callback families (EM1-4).

**termic** (Simion Agavriloaei). The keyboard-driven minimalist: Tauri 2, PTY-spawns
the *real* agent CLIs so inference rides existing Pro/Max plans (an explicit bet
against vendor SDKs), JSON-file persistence, no daemon. Worktree-per-workspace with
duplicate-worktree and attach-to-root options; **Spotlight** mirrors a worktree's live
changes into the repo root on a detached HEAD without touching your branch — a genuinely
novel worktree UX worth remembering when the argus UI grows a "preview this worktree
locally" story. Their turn-completion detection (per-CLI title classifier + OSC 9;4 +
byte-quiet/content-hash gating) is the most engineered of the set. Review is
terminal-native plus an AI-review dialog and GitHub-style inline comments batched back
to the agent — no gated resume. **AGPL-3.0**: treat as pattern reference only, never
lift code.

**Dig outcome (2026-07-03** — [termic/FEATURES-WORTH-BORROWING.md](termic/FEATURES-WORTH-BORROWING.md)**)**,
correcting two scan claims and adding an unflagged subsystem: (1) there is **no
AI-review dialog** — "Review" is a builtin prompt-library entry fired at the same
PTY agent, which computes its own diff; findings land as unparsed terminal text.
(2) The detection engine is real and holds up, but its load-bearing trick reframes it:
termic **claims `TERM_PROGRAM=iTerm.app` so the agent CLIs volunteer their turn state**
over public OSC sequences (9;4 progress, 133 prompt marks, 9 notifications, titles) —
less scraping than listening, with the quiet/hash heuristics as fallback and the title
classifier covering claude+codex only. The invertible half is the dig's do-today item:
our REPL knows its own state authoritatively and can *emit* the same protocol (TM1-1).
(3) The scan missed the **sandbox** — per-workspace Seatbelt + an in-process CONNECT
proxy — whose trust rules are half the haul: login-shell rc-delta withheld from caged
spawns, cage-gating config read from outside the agent's write reach (the crabbox CB1-1
fix shape), per-agent credential-dir isolation, and a monitor/shadow mode (TM1-2,
TM2-3); their Docker plan also independently rejected OAuth-token brokering for mounted
credential dirs — validating our Forge OAuth file-sync decision from the outside.
Spotlight confirmed as the set's one novel worktree UX, now with its guardrail spec
(TM1-3, gated on EM2-3). Edit-and-resume **verified absent** (S-1), completing the §5
sweep. "Quick-jump to next waiting agent" is roadmap-only — the HEAD commit edits the
README roadmap, not code.

### 2. Read-mostly dashboards / attention routers

Attach-to-what's-running observability rather than owning the spawn. The relevant axis
for argus: both projects live or die on *attention routing* — "which of my N agents
needs me right now" — which is argus's channel/notification layer in miniature.

**claude-command-center** (Amir Fish, solo). The maximal one-person take: a Python
stdlib HTTP server + vanilla-JS frontend (53k + 45k line monoliths), no DB, no daemon —
every request rescans `~/.claude/**` and JSON sidecars; REST + SSE, kanban + Flow graph
+ live triage band, engine adapters for five agent CLIs. Three donors stand out despite
the architecture being the deliberate opposite of ours: (1) the **attention/"COO
soft-block" detector** — a scored heuristic catching *prose* questions ("paused for
your review") when no formal gate fired; argus has real gates, but the idea of
detecting soft blocks in agent output on top of them is worth keeping; (2) **Flow node
inspector** — editable Markdown status files with managed `ccc:auto` blocks and
**mtime-409 optimistic saves**, a working mini-precedent for argus's
`reviseStepOutput(expectedSeq)` CAS design; (3) a real **PWA shell** (manifest + service
worker, no Web Push) and a `CCC_TRUST_TAILNET` same-origin allowlist — tailnet-adjacent
posture, but **no auth at all**, which argus explicitly does better (API key +
tailnet ACLs). Also ships an ACP adapter and a peer-orchestration skill
(`/api/ask`, spawn with `report_to` parent linkage).

**Dig outcome (2026-07-03** — [claude-command-center/FEATURES-WORTH-BORROWING.md](claude-command-center/FEATURES-WORTH-BORROWING.md)**)**,
upgraded from the planned targeted read to a full inventory, correcting three scan
claims: (1) the mtime-409 editable-node model is a **half-precedent** — the server
contract is mature and convergent (typed 409 carrying the fresh mtime), but the client
recovery flow was never built: a conflict dead-ends and recovery loses the operator's
edits, converting the borrow into acceptance criteria for argus §5.4 (CC1-3). (2) "No
auth at all" was imprecise in both directions — the real posture is localhost-default
bind + an unusually frank SECURITY.md + same-origin CSRF checks; but CSRF ≠ auth:
Origin-less requests bypass every POST gate *including the trust-config endpoint*, GET
(all transcripts) is entirely ungated, and their orchestration skills instruct agents
to bypass their own sandbox to drive the control plane — the corpus's sharpest negative
reference for argus §4.4 (CC2-4). (3) The triage surface is *not* attention-sorted —
CCC shipped float-to-top and removed it as a churn bug (CCC-182), converging with
emdash on stable-order-plus-badges; the one hoisted bucket is `ended_blocked` (dead
session, orphaned question). The haul: the two-stage prose soft-block detector (rubric
portable verbatim, CC1-1) + the attention-feed read-model with kinds/priority/
suppression and git-stranded-work items (CC1-2) — with a do-today slice on our side:
the seams pass found LoopGuard halts, failed cron runs, and Forge `:needs_input` all
reach **no operator surface today**. Garnishes: managed-block co-ownership re-homed to
our `system_prompt.md` upgrade chore (CC2-2), worktree advisory-hook/no-teardown
datapoints (CC2-3), the no-op-SW PWA installability floor (CC3-2).

**muxara** (Contino folks). The minimal take: Tauri 2 mission control that polls tmux
every ~1.5s, classifies each Claude Code session NeedsInput/Working/Idle/Errored (with
Permission-vs-Question sub-types and plan-mode detection), attention-sorts cards, and
switches you into the real terminal. No DB, no orchestration, notifications explicitly
unimplemented, quiet since May 2026. The borrowable bit is the **status taxonomy and
needs-input-floats-to-top UX** — a clean, small spec for how argus's agent list should
sort and badge, fed by our structured events instead of their regex scraping.

**Dig outcome (2026-07-03** — [muxara/FEATURES-WORTH-BORROWING.md](muxara/FEATURES-WORTH-BORROWING.md)**)**,
fired deliberately as argus implementation approached (the scan's named trigger),
correcting five scan claims: (1) effectively **solo** (one Contino author under two
aliases). (2) It tracks **every tmux pane**, not just Claude sessions — Claude presence
is advisory metadata from a `ps` process-tree walk — and the taxonomy has a fifth
state, `Unknown`, first-class and visually distinct. (3) Plan-mode is classified but
**never rendered** — an orthogonal `Option<bool>` modifier the UI plumbs and drops.
(4) Notifications are simply **absent** (no stub, no TODO, not even in the brief's
future list), not "explicitly unimplemented". (5) The attention-sort claim held — and
inverted in value: muxara is the set's only *shipping* sorter, and its keyboard
selection ring binds to grid position, so reorders silently move the selection — the
churn defect CCC named (CCC-182), demonstrated in code (MX2-1), sealing the
badges-not-reordering verdict. The haul: the **single-agent status contract** (MX1-1 —
the per-agent enum EM2-1's fold and CC1-2's kinds compose over: sub-typed needs-input,
modes-as-modifiers, honest unknown, raise-fast/clear-slow damping), worktree lifecycle
datapoints (MX2-2: creation delegated to Claude Code's own `-w` flag; teardown
hard-blocked on uncommitted changes — the middle of the CCC→traycer teardown
spectrum), and the classifier's real-capture calibration corpus + port-drift lesson
(MX3-1). Edit-and-resume trivially empty (S-7: no input channel to an agent at all).

### 3. Methodology blueprint — contrast, not code

**Xantham-system-blueprint** (Zaki Qadus, solo). Not a running app: two giant markdown
files (~18k lines) that a fresh Claude Code session executes as a setup wizard,
generating a Telegram-driven orchestrator + 9 specialists, plus real bash hooks (a
408-line safety gate), a checksummed install, and a Docker audit sandbox. Ideas
overlap argus at the headline level — worktree-per-agent with merge-back, a phone
approval loop (safety gate → Telegram ping → `yes` appended to an approvals file with a
30-day TTL), a "Command Deck" mobile dashboard — but every mechanism is single-machine,
file-based, and coarser than what we already run (its approval gate is allow/deny on
one shell command; our `AgentCase` family + argus's edit-and-resume is strictly
richer). Value is as a *contrast document* and idea checklist (council pattern,
auto-drafted skills, auth-failover canary), not a source of designs. Likely SKIP at
dig time.

**Dig outcome (2026-07-03** — [Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)**)**,
fired by the operator as argus implementation began (the scan's own named trigger),
correcting four scan claims: (1) the approval loop is **model-mediated end to end** —
the LLM phrases the Telegram ask, interprets the natural-language "yes", and writes
the approval line itself into a file inside the agent's own write reach (`echo`-class
commands skip the gate, so self-approval is a one-liner; their SECURITY.md names the
TOCTOU and symlink races) — not a human-side file append; (2) "auto-drafted skills"
are LLM-scaffolded on explicit request only — the automated drafters are
corrections→rules and dream consolidation, both human-gated, and v32's skill-lifecycle
curator is PROPOSE-ONLY; (3) the **Command Deck is vapor in the public repo** — no UI
or Worker code ships, one changelog line plus two telemetry feeder hooks; (4) the "9
specialists" are in-session Task-tool *voices* generated from one parameterized
template (plus an undocumented per-specialist `-fable` effort-clone roster — their
workaround for frontmatter-fixed effort, independently validating our AR-9 tiering
seam). The haul: the §4.4 negative reference (XA1-1, joining CC2-4), the third §6.2
trigger answer with the infra-alerts-bypass-the-agent-path rule (XA1-2), two our-side
gate gaps the contrast exposed (XA2-1 approval TTL, XA2-2 hard-block tier), and the
do-today credential canary (XA2-3). Edit-and-resume verified absent (XA S-11) — the
§5 sweep now closes across all six subjects.

## Cross-cutting observations

1. **Worktree-per-task is unanimous — all six, counting CCC's spawn-time creation.**
   Strong validation for argus §3.1, and five concrete schema/lifecycle references to
   study before we model `Worktree`: traycer's `worktree-schemas.ts` (per-device
   binding ≈ our `node` column), emdash's `worktree-service.ts` (lifecycle scripts,
   preservePatterns), termic's layout + Spotlight mirror, CCC's spawn-time create
   (advisory init hook that can't fail the create — the cautionary argument for
   traycer's `setup_status`; `orphan_prs` as a stranded-work kind —
   [CC2-3](claude-command-center/FEATURES-WORTH-BORROWING.md)), and muxara's
   rejected-alternative datapoint (creation delegated to the agent CLI's own `-w`
   flag — the convention-coupling cost argues for orchestrator-owned ops; plus the
   dirty-check-blocked teardown, [MX2-2](muxara/FEATURES-WORTH-BORROWING.md)) — and
   Xantham's far-end datapoint (worktree ops delegated *wholesale* to the harness's
   `isolation: "worktree"` param, with the observable result an unspecifiable
   merge-back story; its one concrete tool, `safe-merge-check.sh`'s
   merge-base-not-two-dot deletion report, is a pre-merge detail for the argus review
   surface — [XA3-2](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)).
   Connective (2026-07-03 pass): the digs also assembled a **teardown spectrum**,
   weakest to strongest — CCC's delegate-deletion-to-the-agent prompt (the
   anti-pattern, CC2-3) < termic's `remove --force` behind a bare confirm (TM2-4) <
   muxara's dirty-check hard block (MX2-2) < traycer's phased, busy-checked delete
   (TR2-1) — with Xantham independently approval-gating `worktree remove --force`
   in its own bash gate, the emdash EM2-3 thesis from outside; and an **ownership
   spectrum** (host-owned traycer / app-owned emdash·termic·CCC / agent-owned
   muxara / harness-delegated Xantham) whose every step away from
   orchestrator-owned ops cost something observable.
2. **Nobody has edit-step-output-and-resume.** The closest analogs: traycer's Epic
   checkpoint manifests (dig-confirmed 2026-07-03: per-turn file undo, not workflow
   checkpoints — the traycer slot is now *verified* empty), CCC's editable
   managed-markdown with 409 saves, and emdash's Plan Mode — which the emdash dig
   found is **deleted code** (its live analogs, batched diff comments and Monaco
   file edits, are annotate-then-new-prompt and file edits respectively — the emdash
   slot is likewise *verified* empty, EM S-2). The termic dig closed the last desktop
   slot the same day (termic S-1): both of its human-in-loop channels are
   annotate-style (batched comments become a *new* PTY prompt; prompt-body edits touch
   the instruction, never agent output). The CCC dig closed the final slot (CC1-3):
   its editable managed-markdown is co-owned *status docs*, not step outputs, and the
   mtime-409 save is a **half-precedent** — the server contract (typed 409 carrying
   the fresh cursor) is real, independent convergence on the `expectedSeq` shape, but
   the client recovery flow was never built (a conflict dead-ends; recovery loses the
   edits) — acceptance criteria for argus §5.4, not a working reference. Argus §5
   remains genuinely novel in this set, with **every slot now verified** — muxara's
   trivially (observe-only; no input channel to an agent exists at all, MX S-7),
   and Xantham's by decision-shape (approvals are allow/deny on exact command
   strings; `dream approve`/`reject` is decision-only; plans land as files with no
   gate — XA S-11, closing the sweep across all six subjects) —
   (note the traycer dig's seams pass also corrected the argus sketch itself: the
   append is pessimistic, not a CAS; see TR2-3).
3. **Everyone else scrapes; we have events** — with one dig correction: emdash
   doesn't scrape. It gets structured signals via config-installed agent hooks
   (POSTing to a token-guarded localhost server) and ACP session updates (emdash
   dig, EM S-7); the scraping engineering belongs to muxara (dig-refined: regex over
   pane captures, damped by a wall-clock cool-off, pinned by a real-capture fixture
   corpus — MX3-1),
   termic (dig-refined: less scraping than *listening* — it claims a capable
   `TERM_PROGRAM` so the CLIs volunteer OSC 9;4/title state, heuristics only as
   fallback), and CCC (dig-refined: a hooks+scrape hybrid — two installed Claude
   hooks plus JSONL/ps scanning). The conclusion stands either
   way: argus reads the `WorkflowEvent` log and `AgentCase` rows natively. Borrow
   the taxonomy and attention UX; skip both the detection machinery *and* the
   hook-bolt-on plumbing — with two carve-outs the digs earned: the *emit*
   side (jidoclaw speaking the work-done protocol from its own CLI) is a borrow
   (termic TM1-1), and so is CCC's soft-block *rubric* itself (CC1-1) — "ended by
   asking a question in prose" is invisible to formal events on any substrate,
   ours included.
4. **ACP is emerging as the agent↔client protocol** — emdash offers it as its
   structured-chat transport (Claude/Codex only, per the dig — not its whole
   runtime), CCC ships the *agent side* in 616 experimental lines that punt the
   permission bridge entirely (CC S-7 — confirming the bridge is the one
   design-risk piece), and it standardizes exactly the
   permission-request surface our tool-approval gate exposes. The standing question
   — should JidoClaw eventually *speak* ACP so third-party cockpits (emdash, Zed, …)
   can drive it? — is now a **costed TRACK**: the emdash dig enumerated the minimal
   agent-server surface (four methods + two callback families, mapping ~1:1 onto
   `chat/4`, SignalBus, and the tool-approval gate; EM1-4), with one real design
   decision in the permission bridge (single-use consume vs ACP's `allow_always` —
   EM OQ-1).
5. **Argus's differentiators survive contact.** Multi-device cluster, shared Postgres,
   phone-first PWA with Web Push, real auth, durable event-sourced history — zero of
   six have any of them (CCC has the PWA shell only, explicitly rejects multi-user and
   persistence). The competitive gap is real; the sub-problem solutions are what's
   worth taking.
6. **The attention stack assembled itself across four digs — no single subject has
   all of it, and the composition is itself a finding** *(added in the 2026-07-03
   connective pass; the parallel digs each saw only their slice)*. Bottom-up: muxara
   owns the *per-agent* status contract
   ([MX1-1](muxara/FEATURES-WORTH-BORROWING.md) — small closed enum, sub-typed
   needs-input, modes-as-modifiers, honest `unknown`, raise-fast/clear-slow damping);
   emdash owns the *cross-agent* fold + seen-flag
   ([EM2-1](emdash/FEATURES-WORTH-BORROWING.md)); CCC owns the *feed* — kinds,
   priority, suppression, git-stranded-work items, and the produce/decide split
   ([CC1-2](claude-command-center/FEATURES-WORTH-BORROWING.md)) — plus the layer no
   formal event system sees on any substrate: the prose soft-block detector and
   `ended_blocked` ([CC1-1](claude-command-center/FEATURES-WORTH-BORROWING.md)). The
   list UX over all of it is settled with prejudice (badges on stable order, one
   hoisted bucket, selection bound to identity — emdash never sorted, CCC retracted
   sorting as churn, termic badges-only, and muxara, the set's one shipping sorter,
   demonstrates the defect in code, [MX2-1](muxara/FEATURES-WORTH-BORROWING.md)).
   Every layer feeds from events we already emit; the do-today slice is ours
   (CC1-2a's three invisible signals, muxara's two Forge sharpenings, Xantham's
   XA2-3 canary). Three conversations to hold together at build time:
   unknown-semantics (muxara OQ-2 reconciles its boring-unknown with termic's
   fail-toward-attention), needs-input vs our non-blocking approvals (muxara OQ-1),
   and the attention/disposition vocabulary shared with camus C1-4/C1-5 (CCC
   OQ-1/OQ-2, next-ten #6).
7. **Argus §6.2 (push triggers) is answered three times over, convergently — and
   the answers layer rather than compete** *(connective pass)*. emdash and termic
   independently shipped the same two triggers — agent finished + agent blocked on
   you ([EM1-3](emdash/FEATURES-WORTH-BORROWING.md),
   [TM2-5](termic/FEATURES-WORTH-BORROWING.md)) — and CCC + Xantham independently
   arrived at the third: ended-owing-an-answer (`ended_blocked` / the never-silent
   fallback; CC1-1, [XA1-2](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)).
   Delivery rules, merged: transition-edge dedupe, active-surface suppression, and
   deep links (emdash); sound only on completion, per-key debounce, and
   ambiguous-states-fail-toward-attention (termic); per-kind daily caps,
   `==`-not-`>=` streak firing, and the one architectural rule no product states —
   **infra alerts must never ride the agent path** (Xantham). Beneath the triggers,
   CC1-2's feed is the source layer: "push = P1 item entering the feed", with
   priority doubling as the per-severity mute knob EM OQ-3 wanted. The one open
   divergence is failure pushes (emdash excludes errors — defensible on a desktop;
   EM OQ-3 leans include for a control plane whose operator left). All of this is
   cross-referenced into argus OVERVIEW deferred-question 2.
8. **Doc/code drift is endemic in the set** *(connective pass)*: five of six digs
   shipped an explicit drift finding (emdash's flagship Plan Mode: deleted code with
   live docs; termic: six findings; CCC: an architecture doc describing a build ~14×
   smaller than the server it ships; muxara: small but real; Xantham: nine findings,
   including a shipped gate missing its own changelog's headline fix), and the sixth
   (traycer) can't even be checked — its host is a closed binary whose behavior
   exists only as schema doc-comments, treated as claims. The method held: pin the
   commit, read the code, treat docs as hypotheses — it's what let the six digs
   correct twenty scan claims between them (3+3+2+3+5+4). Keep that discipline for
   re-review passes; it's the same solo-author-plus-agent velocity pressure our own
   doc-reconcile habit exists to counter.

## Early read (to be challenged in the deep-dive)

1. ✅ **DONE 2026-07-03 — traycer dig** ([inventory](traycer/FEATURES-WORTH-BORROWING.md)).
   Verdict: closest *contract-layer* comparable — the skew layer and worktree schemas
   delivered (TR1-1..TR1-4, TR2-1/-2/-4); Epic checkpoints turned out to be per-turn
   file undo (no edit-and-resume anywhere); one INDEPENDENT correction to the argus
   `expectedSeq` sketch (TR2-3); one do-today item (TR1-2a, MCP golden test).
2. ✅ **DONE 2026-07-03 — emdash dig** ([inventory](emdash/FEATURES-WORTH-BORROWING.md)).
   Verdict: the practice half of the worktree reference (preservePatterns + idempotent
   provisioning, EM1-1/-2 — composes with traycer's schema half), two shipped answers
   to argus open questions (notification taxonomy EM1-3, attention rubric EM2-1), the
   ACP question costed (EM1-4), the workspace-server checklist quantified at 2/130
   implemented (EM2-5); one do-today item (EM2-3, gate `git worktree` mutations).
3. ✅ **DONE 2026-07-03 — CCC dig** ([inventory](claude-command-center/FEATURES-WORTH-BORROWING.md)),
   upgraded from targeted read to full inventory once the seams pass found live
   our-side gaps. Verdict: the soft-block detector transplants (CC1-1) and grows into
   an attention-feed read-model with a do-today slice (CC1-2 — LoopGuard halts, cron
   failures, and Forge `:needs_input` reach no operator surface today); the 409-save
   model is a half-precedent (CC1-3); sleeper: managed-block co-ownership fixes the
   `system_prompt.md` upgrade chore (CC2-2).
4. ✅ **DONE 2026-07-03 — termic dig** ([inventory](termic/FEATURES-WORTH-BORROWING.md)),
   upgraded from pattern-notes to a full dig once the scan's three donors kept opening
   onto more (the sandbox trust rules were entirely unflagged). AGPL discipline held:
   every entry is pattern/reference/rubric, no code.
5. ✅ **DONE 2026-07-03 — muxara dig** ([inventory](muxara/FEATURES-WORTH-BORROWING.md)),
   upgraded from "captured here, no dig" once argus implementation approached (the
   scan's own named trigger). Verdict: the taxonomy is real and lands as the
   single-agent status contract (MX1-1); the attention-sort borrow inverts into the
   counterexample sealing CC2-1/EM2-1's badges-not-reordering rule; the unflagged find
   was the worktree lifecycle pair (MX2-2).
6. ✅ **DONE 2026-07-03 — Xantham dig** ([inventory](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)),
   the parked "no dig by design" reversed when the scan's own trigger fired (argus
   implementation beginning; operator-requested). Verdict: "contrast only" holds
   architecturally; the haul is the argus §4.4 negative reference (XA1-1), the third
   §6.2 trigger answer (XA1-2), two our-side gate gaps (XA2-1 approval TTL, XA2-2
   hard-block tier — both queue-independent), and the do-today credential canary
   (XA2-3); edit-and-resume verified absent (XA S-11).

## Suggested next steps

- [x] ~~Deep-dive traycer~~ **Done 2026-07-03** →
      [traycer/FEATURES-WORTH-BORROWING.md](traycer/FEATURES-WORTH-BORROWING.md)
      (scoped as planned: worktree schemas / Epic checkpoints / versioned-RPC).
- [x] ~~Deep-dive emdash~~ **Done 2026-07-03** →
      [emdash/FEATURES-WORTH-BORROWING.md](emdash/FEATURES-WORTH-BORROWING.md)
      (scoped as planned: worktree lifecycle + ACP permissions + workspace-server
      checklist; first wave: EM2-3 today, alongside traycer's TR1-2a).
- [x] ~~Pattern notes: termic~~ **Done 2026-07-03, upgraded to a full dig** →
      [termic/FEATURES-WORTH-BORROWING.md](termic/FEATURES-WORTH-BORROWING.md)
      (the three flagged donors delivered plus an unflagged fourth, the sandbox trust
      rules; first wave: TM1-1 — emit the work-done protocol — joining TR1-2a and
      EM2-3 as the do-today set).
- [x] ~~Targeted CCC read~~ **Done 2026-07-03, upgraded to a full dig** →
      [claude-command-center/FEATURES-WORTH-BORROWING.md](claude-command-center/FEATURES-WORTH-BORROWING.md)
      (attention stack / 409 model / trust posture; first wave: CC1-2a this week —
      surface the three invisible attention signals — then CC1-1; argus §5 editor
      notes fed via CC1-3).
- [ ] Decide whether **ACP** merits its own corpus subject (protocol-level, like the
      squidie engine comparison) — trigger: when argus's API surface plan (§4) gets a
      design pass, evaluate "expose ACP alongside GraphQL" then.
- [x] ~~No action: muxara~~ **Dug 2026-07-03** — the "argus agent-list UX needs a
      second reference at build time" trigger fired with argus implementation
      approaching → [muxara/FEATURES-WORTH-BORROWING.md](muxara/FEATURES-WORTH-BORROWING.md)
      (single-agent status contract MX1-1; sorting counterexample MX2-1; worktree
      datapoints MX2-2; no do-today items of its own — CC1-2a stays the first wave).
- [x] ~~No action: Xantham~~ **Dug 2026-07-03** — the phone-approval-loop trigger
      fired with argus implementation beginning →
      [Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md](Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)
      (argus §4.4 negative reference XA1-1; §6.2 third answer XA1-2; gate hardenings
      XA2-1/XA2-2 are a small queue-independent session; the credential canary XA2-3
      joins CC1-2a's do-today slice).

**Combined first wave** (2026-07-03 connective pass — the do-today set rolled up
across all six digs, every item independent of argus; grouped as the docs paired
them): **EM2-3** (gate `git worktree` mutations in the shell analyzer — prerequisite
for termic TM1-3/TM2-4, and independently validated by CCC's delegate-teardown
anti-pattern CC2-3 and Xantham's own gate XA3-2) · **TR1-2a** (MCP served-surface
golden test) · **TM1-1** (emit the work-done protocol from the REPL) · **CC1-2a**
(surface the invisible attention signals — LoopGuard halts, cron failures, Forge
`:needs_input`, plus muxara's two Forge sharpenings — with **XA2-3**'s credential
canary joining the slice) · **XA2-1 + XA2-2** (approval TTL + hard-block tier — one
gate-hardening session, shadow-first per termic TM2-3) · then **CC1-1** (soft-block
detector, with muxara MX3-1's fixture-corpus method) and **CC2-2** (ManagedDoc for
`system_prompt.md`, with Xantham XA3-1 as second reference).
