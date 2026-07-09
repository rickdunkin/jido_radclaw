# Agent Control-Plane Landscape Scan (ades)

**Status**: initial scan (2026-07-03), with **all six deep-dives — traycer, emdash,
termic, claude-command-center, muxara, and (trigger-fired later the same day) Xantham —
completed** (see each repo's "Dig outcome" paragraph and linked inventory), plus a
same-day **connective pass** stitching what the parallel digs couldn't see of each
other: cross-cutting observations 6–8, the combined first wave at the bottom, and
dated back-links added into the earlier inventories. A **cross-corpus pass**
(2026-07-05) followed once the sibling [pms corpus](../pms/README.md) closed its
eight digs (all 2026-07-04): pms findings that confirm, contradict, or extend this
corpus are stitched back as dated 2026-07-05 notes in each inventory and in the
observations / first-wave block below — the [DIG-BRIEFS revisit
policy](../pms/DIG-BRIEFS.md)'s motion 1. **Three late subjects joined 2026-07-06** —
cmux and herdr, terminal-native multiplexers flagged by the operator after the
corpus closed, plus t3code, the corpus's first whole-product architectural **peer**
(server + decoupled web/desktop/mobile clients): quick-scanned the same day,
**digs queued** (comparison table + categories 4–5 below).
The scan itself was a quick pass over the repos cloned at `~/workspace/research/ades/`
— six parallel read-only scan passes (README + docs skim, manifests, top-level source
layout, a handful of key files) plus git metadata. For the six dug repos, claims are
firsthand code reads. Scanned at: claude-command-center
@ `e53d51d`, emdash @ `c67e93e8`, muxara @ `1046684`, termic @ `5c236b6`, traycer
@ `b09cf8d`, Xantham-system-blueprint @ `c5db232`; jido_radclaw as of 2026-07-03.
The 2026-07-06 additions live outside the ades directory — the multiplexer pair at
`~/workspace/research/multiplexers/`, t3code at `~/workspace/research/t3code/` —
and were scanned at: cmux @ `48e69cbb05`, herdr @ `5b4450c`, t3code @ `32e7844837`
— herdr's detection module and t3code's architecture docs read firsthand, everything
else per README / tree layout / test-suite names. **All three digs fired 2026-07-06**
— t3code and herdr first (dig outcomes in categories 5 and 4; six and four scan
claims corrected), then cmux's targeted dig the same day (category 4; the scan's
"thin" iOS-client claim corrected, "hook-fed" confirmed-and-sharpened), closing the
late-subject set.

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
  Every project scanned through the corpus close chose the inverse on at least two
  of those axes (local-first, no server DB, desktop form factor); the 2026-07-06
  addition t3code is the recorded exception — the first subject sharing the
  server-plus-decoupled-web/mobile-clients shape (category 5).
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
  tools, cluster wiring. Every runnable app in this set infers agent state by
  scraping terminals or bolting on hooks — herdr and cmux included (herdr is the
  field's most engineered scrape×hook hybrid — dig-confirmed 2026-07-06, and it
  deliberately moved its biggest CLIs' state authority *back* to the scrape,
  keeping hooks for session identity; cmux hook-fed per scan; observation 3 holds
  the dig-corrected nuance) — with one per-scan exception among
  the 2026-07-06 additions: t3code ingests structured provider events over the
  `codex app-server` JSON-RPC stream and re-emits them as ordered typed pushes,
  the set's closest posture to our own; we get structured events for
  free — borrow their *taxonomy and UX*, never their detection machinery.
- Threat model (personal, tailnet-only): LLM misbehavior + leakage hygiene, not
  external attackers. CCC's no-auth tailnet posture is the cautionary reference here.

## Quick comparison

| Repo | What it is | Tech / persistence | License | Activity | Fit |
| --- | --- | --- | --- | --- | --- |
| [claude-command-center](https://github.com/amirfish1/claude-command-center) | Local dashboard for every Claude Code/Codex/Cursor/Antigravity/Kilo session on the machine | Python stdlib server + vanilla JS; REST + SSE; no DB (rescans `~/.claude/**` per request) | MIT | 2,019 commits, solo author (aliases), active Jul 2026, v5.5.0 alpha | **Dug 2026-07-03** → [inventory](claude-command-center/FEATURES-WORTH-BORROWING.md): the attention layer is the haul — soft-block rubric + `ended_blocked` + attention-feed read-model, with a do-today slice (LoopGuard halts, cron failures, Forge `:needs_input` reach no operator surface today); mtime-409 is a **half-precedent** (server contract real, client recovery never built); trust posture = the corpus's sharpest negative reference for argus §4.4 |
| [cmux](https://github.com/manaflow-ai/cmux) | Ghostty-based native macOS terminal / workspace manager for AI coding agents (Manaflow), with an iOS companion client | Swift/AppKit + libghostty (no Electron), ~3.9k Swift files + TS webviews/workers; hook-fed agent notifications (dig-confirmed: a 17-agent hook catalog + Claude/codex wrappers); CLI + socket API; in-app scriptable browser | GPL-3.0-or-later + commercial (dual) | 5,749 commits, 133 contributors, very active Jul 2026 (HEAD 2026-07-06), v0.64.17 | **Dug 2026-07-06 (targeted)** → [inventory](cmux/FEATURES-WORTH-BORROWING.md): both flagged targets resolve *against* building what cmux built — claude-teams is a **tmux impersonation** (fake `TMUX` env + PATH shim + a pinned command-translation table) resting on nine unguarded vendor assumptions (CM1-1, slice 6's cost sheet for vendor-internal driving), and the "thin" iOS client corrects to **~75k LOC + four cloud services + APNs** (CM2-1 — §2.6's PWA choice upgraded to evidence-based); the riders over-delivered: hook-authority state with mechanical fences, herdr's opposite pole (CM1-2), the typed feed classifier + decision-only soft-wait approval cards (CM1-3), two cross-device FLOW §12 delivery rules (CM1-4); sweep subject 26 closes execution-layer empty, finishing the family sweep |
| [emdash](https://github.com/generalaction/emdash) | Desktop app for parallel coding agents, one git worktree per task (General Action, YC W26) | Electron/TS nx monorepo; React + Solid; SQLite + Drizzle; PTY default + opt-in ACP (Claude/Codex only) | Apache-2.0 | 8,044 commits, 126 contributors, very active Jul 2026, v1.1.36 | **Dug 2026-07-03** → [inventory](emdash/FEATURES-WORTH-BORROWING.md): worktree provisioning *practice* (preservePatterns, idempotent setup steps — composes with traycer's schemas), shipped two-trigger notification taxonomy, attention fold + seen-flag, minimal-ACP-server brief; Plan Mode is deleted code — **no edit-and-resume**; one do-today gate gap (EM2-3) |
| [herdr](https://github.com/ogulcancelik/herdr) | "tmux rebuilt for agents" — server-holds-the-PTYs terminal multiplexer; sidebar rolls every pane to blocked/working/done/idle | Rust, single ~10MB binary (208 source files), no DB; detach/reattach incl. phone-over-ssh + `--remote` client mode; dual-source state detection (18 per-agent tail-pattern TOML manifests × 14 managed hook integrations, arbitrated with damping); socket API + plugins; worktree helpers | **AGPL-3.0-or-later** + commercial (dual) — patterns only | 1,038 commits, 45 contributors, daily commits Jul 2026 (HEAD 2026-07-07), v0.7.1; #1 GitHub trending Jun 30 2026 (per README badge) | **Dug 2026-07-06** → [inventory](herdr/FEATURES-WORTH-BORROWING.md): the state engine delivers as argus slice 1's rubric — authority-tiered arbitration + stale-reporter fences (HD1-1), damp-only-the-clear numbers + re-verify-at-delivery (HD1-2), seen-fold `done` + the identity-bound sorter existence proof (HD1-3); PTY broker banked for slice 8 (HD2-1); 14-vendor resume argv table rides MC1-1 (HD2-2); headline lesson: herdr **retreated from hook-borne state** for the seven biggest CLIs (hooks carry session identity only — events-over-proxies validated from the field's best scraper); subject 25 empty; four scan claims corrected (incl. the SY2-3 single-sourcing credit — the 14 packs are hand-written) |
| [muxara](https://github.com/muxara/muxara) | macOS mission control for parallel Claude Code tmux sessions | Tauri 2 (Rust + React 19); no DB, reconciles from tmux each poll | MIT | 72 commits, solo author (2 aliases), quiet since May 2026, v0.1.5 | **Dug 2026-07-03** → [inventory](muxara/FEATURES-WORTH-BORROWING.md): the taxonomy delivers as the **single-agent status contract** (MX1-1 — sub-typed needs-input, plan-mode as an orthogonal modifier, honest `unknown`, asymmetric damping; every signal maps to structured events we already emit); the attention-sort claim inverts — the set's only shipping sorter exhibits the churn defect (positional selection drift) that seals CC2-1/EM2-1's badges-not-reordering verdict; unflagged find: worktree lifecycle datapoints (agent-owned creation via `claude -w`, dirty-check-blocked teardown) |
| [t3code](https://github.com/pingdotgg/t3code) | "Minimal web GUI for coding agents" (T3 Tools / pingdotgg) — one Node server owning orchestration/providers/terminals/git/fs; decoupled web, desktop, and mobile clients share one model (README claims four providers; the code ships five — Codex, Claude, Cursor, Grok, OpenCode — and the Codex-only architecture doc is the stale one; dig-resolved, category 5) | Node.js WS server wrapping `codex app-server` (JSON-RPC over stdio) + React/Vite SPA; Effect-TS pnpm monorepo (packages: contracts, effect-acp, effect-codex-app-server, ssh, tailscale); typed ordered push channels, schema-validated at the transport boundary; SQLite in apps/server | MIT | 1,902 commits, 160 contributors, very active Jul 2026 (HEAD 2026-07-05), self-described "very very early"; npx + winget/brew/AUR desktop releases | **Dug 2026-07-06 (targeted)** → [inventory](t3code/FEATURES-WORTH-BORROWING.md): the peer delivers one layer off the scan — the flagged push stack is pre-release Effect RPC plumbing (the per-connection-sequence claim was false), and the hauls are the **durable `afterSequence` catch-up contract + client sync loop** (TC1-1 — argus slice 1's working reference, defects annotated), the corpus's **first positive auth reference** (scoped credentials + WS tickets + shipped QR pairing, TC1-2), and **five drivers over four vendor protocols with native codex `thread/resume`** (TC1-3 — slice 6 / executor PR-2); paired tree+conversation rewind out-classes traycer's file undo (TC2-1); approvals die on restart (moat evidence, S-3); edit-and-resume verified absent (subject 27) |
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

### 4. Terminal-native multiplexers — late additions (2026-07-06, both dug the same day)

Two subjects flagged by the operator after the corpus closed, cloned at
`~/workspace/research/multiplexers/` rather than the ades directory. Both are
"the terminal *is* the product" plays — the form factor the original six lack
(herdr's own README positions against "conductor, cmux, emdash", i.e. against
category 1 above). Everything below is quick-scan level — herdr's detection
module was read firsthand, the rest is per README / tree layout / test-suite
names — and the standing edit-and-resume sweep question rides along with each
dig per the [DIG-BRIEFS revisit policy](../pms/DIG-BRIEFS.md) (they would be
sweep subjects 25–26).

**herdr** (ogulcancelik; 45 contributors; **AGPL-3.0/commercial dual — patterns
only**, the termic discipline). A Rust rebuild of tmux for agents: one ~10MB
binary whose background server owns the PTYs (detach/reattach from any terminal,
including a phone over ssh; `herdr --remote` turns the local terminal into a
client of a remote server), mouse-native workspaces/tabs/panes, and a sidebar
that rolls every pane up to blocked/working/done/idle. It earns a full dig
despite observation 3's settled borrow-taxonomy-never-machinery rule because its
state engine is **dual-source with arbitration** — a layer no ades subject had:
terminal-tail pattern matching driven by 18 per-agent TOML manifests
(`src/detect/manifests/`) is the zero-config floor; 14 managed, versioned,
auto-installed per-agent hook integrations (`src/integration/assets/`, reporting
over its socket) sharpen it; and `AgentDetection` carries confidence metadata to
arbitrate the two — screen-visible blocker chrome may override a non-blocked
integration state, and a `skip_state_update` flag keeps agent-owned transcript
viewers from reading as false idle, a failure mode muxara never met. Damping is
a real state machine (working→idle held for 3 confirmations under a 700ms cap,
100ms rechecks, a 3s startup grace window) — MX1-1's raise-fast/clear-slow,
engineered several steps further. One doc-drift note in the corpus's expected
flavor: the README's "zero config, no hooks required" coexists with those 14
managed hook scripts — the likely truth is scrape-as-floor,
integrations-as-sharpener, and that arbitration seam is the dig's first
question. The dig's second half: the only server-side PTY-broker architecture in
either corpus family (pane persistence, reattach semantics, remote client mode)
— banked reference for FLOW §11's per-worktree operator terminal (slice 8,
deliberately last; this half banks rather than unblocks). Riders: `worktree.rs`
(generated adjective-noun branch slugs, branch→path sanitization — garnish for
FLOW §4's naming templates), `agent_resume.rs` + `handoff_runtime.rs`,
single-sourced multi-agent integration-template generation (SY2-3's pattern
independently re-derived), and a socket API + plugin layer "agents can drive" (a
contrast datapoint for the standing ACP TRACK).

**Dig outcome (2026-07-06** — [herdr/FEATURES-WORTH-BORROWING.md](herdr/FEATURES-WORTH-BORROWING.md)**)**,
same-day, four parallel reader passes + a seams pass over our tree @ `85cbe9f2`,
correcting four scan claims: (1) the "single-sourced integration-template
generation (SY2-3's pattern)" credit is **false** — the 14 packs are hand-written
per agent over shared Rust merge primitives, consistency enforced by
string-asserting tests, deliberately preserving each agent's native config format
(the opposite pole of SY2-3); (2) the arbitration is **authority-tiered, not
symmetric**: seven full-lifecycle agents' hooks own state absolutely (a screen
blocker can never override — only scraper-observed process exit outranks), the
seven biggest CLIs' hooks carry **session identity only** (claude's pack v7 wires
`SessionStart` alone and strips the state hooks earlier versions installed — a
deliberate retreat from hook-borne state, reasoned in the script itself), and the
scan's blocker-may-override rule holds only for residual custom socket sources;
(3) `handoff_runtime.rs` is not agent handoff — it is a live *binary-upgrade*
transfer passing PTY master FDs to the replacement server over SCM_RIGHTS (≤64
panes, Unix-only); (4) `AgentDetection`'s "confidence metadata" is four booleans
marking chrome-backed evidence plus the `skip_state_update` viewer neutralizer,
not a score. The scan's damping numbers confirmed verbatim (3 confirmations /
700ms cap / 100ms recheck / 3s grace) and sharpened: **only working→plain-idle is
damped** — blocked/working raise instantly, visible evidence bypasses the hold.
The haul: HD1-1/HD1-2/HD1-3 land in argus slice 1 (the arbitration contract,
damping + re-verify-at-delivery, the seen-fold + sorter existence proof), HD2-1
banks the slice-8 PTY-broker mechanics, HD2-2 folds the 14-vendor resume argv
table into the queued MC1-1 build. "Zero config, no hooks required" resolves as
scrape-floor + additive opt-in packs exactly as the scan predicted (caveat the
sentence hides: omp/mastracode have no screen manifest at all). Prose soft-blocks
are **undetectable by design** (fixed chrome patterns only — a free-form closing
question classifies Idle) — CC1-1 stays unique in the field. Edit-and-resume
verified absent at **subject 25**: every human→agent channel is a pass-through
PTY byte write; no gate object exists.

**cmux** (Manaflow, Inc.; 133 contributors; **GPL-3.0/commercial dual — treat as
patterns only** as well). A native Swift/AppKit + libghostty macOS terminal:
vertical tabs, notification rings on panes, a sidebar carrying git branch /
linked-PR status / cwd / listening ports / latest notification text, an in-app
scriptable browser, SSH workspaces, and hook-fed agent notifications (Claude and
OpenCode hook plumbing is visible throughout the test suite). At ~3.9k Swift
files it is the largest codebase in either corpus, and most of it re-covers the
quadrant categories 1–2 already mined four subjects deep — hence a **targeted
dig, not a full read**. The two targets are things no subject in the 15-repo
corpus has: (1) **`cmux claude-teams`** — Claude Code's teammate mode driven as
native splits with sidebar metadata and notifications (per README; the `CLI/`
Swift entry points and `tests/test_cli_claude_teams_*.py` are where to start) —
the field's only teammate-mode driving reference, joining slice 6's CLI-adapter
reading list ([SYNTHESIS §5.6](../argus/SYNTHESIS.md)); and (2) the **`ios/`
companion app** (~26 Swift files — a real if thin mobile terminal client:
composition root, terminal input/viewport feature tests, and a
pairing-account-preflight test) — the field's datapoint for the native
phone-client question. Argus chose PWA for convenience and development speed,
not on the merits (OVERVIEW §2.6 parks native/APNs as "wrap in Tauri/Capacitor
if required"); what a thin native terminal companion actually costs, and how its
pairing flow works, is the evidence to revisit that with — composing with
myrlin's MY1-4 QR enrollment ladder.

**Dig outcome (2026-07-06** — [cmux/FEATURES-WORTH-BORROWING.md](cmux/FEATURES-WORTH-BORROWING.md)**)**,
same-day, four parallel reader passes + a seams pass over our tree @ `85cbe9f2`,
correcting one scan claim outright and sharpening a second: (1) the "real if thin
mobile terminal client (~26 Swift files)" is **false** — the 26 files are a
composition-root veneer over ~58.7k LOC of iOS-only Swift in 15 packages + ~16.1k
shared, four cloud services (Stack Auth ×2 projects, the cmux.com registry/APNs
API, a Durable-Objects presence worker, APNs), Tailscale as the mandatory data
plane (shipped transport is plain TCP over the tailnet; iroh is aspiration), and
a second release pipeline — the decisive native-vs-PWA datapoint, banked for the
§2.6 revisit (CM2-1), with two transferable FLOW §12 delivery rules riding free
(presence-gated cross-device forwarding; ack-sync as an absolute projection —
CM1-4). (2) "Hook-fed" confirms and **sharpens into herdr's opposite pole**: hooks
are the deliberate state *authority* — cmux deleted its title/mtime scraping
heuristics and reinforced hooks with mechanical fences (per-surface session+turn
generation gating, pid-generation exit fencing, correct-only transcript
corroboration, misroute-refusal) — same stale-reporter disease as herdr, opposite
cure, converging on the same fences (CM1-2). claude-teams resolves as a **tmux
impersonation**: fake `TMUX`/`TMUX_PANE` env, a PATH shim exec'ing
`cmux __tmux-compat`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, and a pinned
tmux-command translation table — working, and resting on nine unguarded
assumptions about Anthropic internals (the Go remote daemon's reimplementation is
already behind, silently missing the trust-gate handling); the assumption ledger
joins SYNTHESIS §5.6 as the priced alternative to structured-surface driving
(CM1-1), and the restore-argv sanitizer (prompt boundaries never replayed, trust
bypass never persisted) rides MC1-1 (CM2-3). The Feed is the field's most complete
decision-only approval surface — a typed `(source, event)` classifier registry
(never string-matched; their #4985 scar), three actionable kinds, semaphore-parked
soft-wait with timeout-falls-through-to-the-vendor-TUI (the OQ-1 polarity
question) — and **sweep subject 26 closes execution-layer empty**: decisions are
mode/option picks plus one feedback string riding an ExitPlan decision; plan text
renders read-only; every other channel is keystroke injection. GPL patterns-only
held; drift findings in the corpus's expected flavor (the README's "No tmux
required" hides that the feature installs a fake `tmux` shim; the
streaming-agent-updates doc is a plan, not shipped code).

### 5. Whole-product architectural peer — late addition (2026-07-06, dug the same day)

**t3code** (T3 Tools / pingdotgg; **MIT** — the one late addition whose code, not
just patterns, is liftable; 1,902 commits, 160 contributors, HEAD 2026-07-05,
self-described "very very early — expect bugs"). Cloned at
`~/workspace/research/t3code/`; scanned at `32e7844837` — architecture docs, tree,
and manifests read firsthand, **no source read**: everything here is per scan.

The first subject in either corpus family that shares argus's architecture instead
of inverting it: a Node.js server owning orchestration, providers, terminals, git,
and filesystem, with decoupled clients — a React/Vite SPA over a typed WebSocket
contract, plus `apps/desktop` and `apps/mobile` — sharing one model. The client
stack is the haul, because it covers the half of argus neither corpus produced a
single reference for ([FLOW §13](../argus/FLOW.md) prices the client as "the
second product," likely costlier than the server): a connection state machine with
outbound requests queued while disconnected, typed push envelopes with a
per-connection monotonic `sequence`, schema-validated decode at the transport
boundary (failures become structured diagnostics, never silent drops), per-channel
`replayLatest` caching, a single ordered `ServerPushBus`, a `ServerReadiness`
startup barrier before `server.welcome` hydration, and typed runtime receipts that
tests await instead of polling — mapping nearly line-for-line onto OVERVIEW §4.2's
channel-layer questions (ordered delivery, reconnect catch-up, minimal payloads;
their sequence is per-connection where ours is the durable per-run `afterSeq` — a
contrast to record, not a borrow). Provider driving is structured, not scraped —
the set's third posture (see the carve-out in "Where argus stands today"):
provider-native events arrive over `codex app-server` JSON-RPC
(`packages/effect-codex-app-server` — a second SY1-1-class client for slice 6's
reading list), are normalized by queue-backed workers into persisted orchestration
events, and re-emit as domain pushes. Also aboard: `packages/tailscale` +
`docs/architecture/remote.md` — the corpus's first tailnet-native remote-access
reference, stating our own doctrine in so many words ("keep the T3 server as the
execution boundary"; avoid a local control plane) — and `packages/effect-acp`, a
fresh datapoint for the standing ACP TRACK.

Two per-scan cautions, both in the corpus's expected flavor. First, live doc drift
at the front door: the top-level README claims four providers (Codex, Claude,
Cursor, OpenCode) while `docs/architecture/providers.md` says "Codex is the only
implemented provider. `claudeCode` is reserved in contracts/UI" — which doc is
stale, and how the other three are actually driven (`effect-acp` is the plausible
seam), is the dig's first question. Second, the remote doc is explicitly *target*
architecture — design claims, not shipped fact — so the wiring-mortality
discipline applies double. Dig shape: **targeted, not full** (the session-UX
quadrant is mined four subjects deep) — (a) the client/transport/push-contract
stack in source, before slice 1's client scaffold; (b) the remote/tailscale model,
shipped-vs-aspirational; (c) the two packages (`effect-codex-app-server`,
`effect-acp`); (d) the standing edit-and-resume sweep question (subject 27 if the
queued pair fires first) — `CheckpointReactor` "captures git checkpoints on turn
start/complete," which per scan smells like traycer's per-turn file undo, not
edit-and-resume; verify. The dig also owes updates to observations 3 and 5 below,
both framed on the pre-t3code set.

**Dig outcome (2026-07-06** — [t3code/FEATURES-WORTH-BORROWING.md](t3code/FEATURES-WORTH-BORROWING.md)**)**,
same-day, five parallel reader passes + a seams pass over our tree @ `85cbe9f2`,
correcting six scan claims: (1) the "per-connection monotonic `sequence`" is **false**
— the real sequence is a durable global SQLite autoincrement with `afterSequence`
catch-up on thread/shell subscriptions, i.e. *convergent with our WorkflowEvent feed*,
upgrading the scan's "contrast to record" into the headline borrow (TC1-1); (2)
`ServerPushBus`/`ServerReadiness`/`server.welcome`/`replayLatest` are **stale doc
fiction** — the shipped transport is Effect's pre-release `unstable/rpc` (streams as
`stream: true` RPCs, no t3-authored envelope), the startup gate is a command-queueing
`ServerRuntimeStartup`, and latest-value caching is bespoke per service; (3) the
provider drift resolves **against providers.md** — five drivers ship (codex,
claudeAgent, cursor, grok, opencode) over four vendor protocols, with `effect-acp` as
Cursor+Grok's production transport and codex holding native `thread/resume` (TC1-3);
(4) remote.md's target-architecture caution **inverts** — remote ships beyond the doc
(tailscale-serve wrapper, desktop SSH launch+tunnel, an in-repo Cloudflare-Worker
relay that is control-plane-only), and the local auth layer is the corpus's first
*positive* §4.4 reference (scoped credentials on every request and WS upgrade,
one-time pairing, WS tickets, a per-RPC scope map enforced at build — TC1-2); (5) the
"typed runtime receipts tests await" are test-only — the production receipt bus is a
no-op; (6) `CheckpointReactor` is richer than the scan's traycer-shaped guess —
**paired tree+conversation rewind** (orphan commits at hidden refs + provider
`thread/rollback`, TC2-1) — and still not edit-and-resume: **subject 27 verified
empty**, with t3code's plan layer sitting *below* the field's three promote-the-edit
precedents. Riders: the corpus steering record corrected (mid-turn steer-fold ships
across four adapters — TC2-2, FLOW §13 note), and the moat evidence sharpens
(approvals die on restart; no clustering, no skew handling — observation 5's dated
note).

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
   *(Cross-corpus, 2026-07-05)*: the pms corpus broke the unanimity usefully —
   worktree-per-task held in only five of nine subjects, and the exceptions paid
   visibly (OpenHelm's shared project dir forced a **global concurrency cap of 1**;
   upstream symphony's per-issue shallow clones were replaced by worktrees in its
   fork — a clean isolated datapoint that worktrees win on cost at volume). The
   teardown spectrum gained a branch/PR axis and members at both ends
   ([pms observation 11](../pms/README.md)): orca force-deletes worktree *and
   branch* (rejected work unrecoverable — below even CCC's delegate-to-agent),
   myrlin's record-delete strands both, and symphony
   [SY2-4](../pms/symphony/FEATURES-WORTH-BORROWING.md) contributes the only
   PR-side sweep in either corpus (`before_remove` closes stranded open PRs). The
   composite law argus FLOW §5 adopted: phased + dirty-checked (TR2-1/MX2-2) +
   PR-aware (SY2-4) + a records↔worktrees reconciliation sweep.
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
   *(Cross-corpus, 2026-07-05)*: the pms corpus swept nine more subjects (the
   16th through the **24th**) — the execution layer stayed empty at every one —
   but found
   the **plan-layer** variant this corpus lacked, three times, and all three
   promote the operator's edit verbatim rather than re-prompting: Chorus's
   proposal editor ([CH1-1](../pms/chorus/FEATURES-WORTH-BORROWING.md)), orca's
   briefing Accept path, and myrlin's spinoff spec editor
   ([MY2-1](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)). The argus §5
   novelty claim narrows honestly to *execution-layer* head-promotion. The
   field's gate defects also assembled into a §5.4 acceptance-criteria list
   ([pms observation 9](../pms/README.md)): approve-fence (Chorus and orca both
   double-materialize on double-approve; our FOR-UPDATE + single-use `:consume`
   is the axis to keep), revision history (Chorus keeps one overwritten
   `reviewNote`), restart durability (bosun's approved gates re-open to
   pending), expiry (three subjects converge on XA2-1), timeout direction
   (bosun defaults timeout-means-proceed — a gate timeout only ever fails
   closed), plus MY2-1's severed-consumer criterion: prove the resumed step
   consumes the head revision's bytes, not merely that the revision was stored.
   *(t3code dig, 2026-07-06)*: **subject 27 closes empty** — execution layer bare
   (approvals are four-way decisions; review comments are client-side prompt
   appends), and the plan layer sits *below* the three promote-the-edit precedents:
   the proposed-plan card is read-only, `thread.proposed-plan.upsert` is not
   client-dispatchable, and "implement" sends the agent's markdown verbatim
   ([t3code S-7](t3code/FEATURES-WORTH-BORROWING.md)). The §5 novelty survives its
   architecturally closest test.
   *(herdr dig, 2026-07-06)*: **subject 25 closes empty** at the field's most
   terminal-native subject — herdr owns no gate or approval object at all; every
   human→agent channel (focused-pane keystrokes, `agent send`,
   `pane send_text|send_keys|send_input`, plugins) is a pass-through PTY byte
   write, and its only confirmation modals guard herdr's own destructive ops
   ([herdr S-1](herdr/FEATURES-WORTH-BORROWING.md)).
   *(cmux dig, 2026-07-06)*: **subject 26 closes empty — and closes the family
   sweep.** cmux is the first swept subject with a genuinely elaborate out-of-band
   decision surface (Feed cards: Permission/ExitPlanMode/AskUserQuestion, decided
   by buttons — [cmux S-1](cmux/FEATURES-WORTH-BORROWING.md)) — and it is still
   decision-only: the plan card renders read-only, the one free-text field is
   commentary riding an ExitPlan mode decision (annotate-then-continue, below the
   three plan-layer promote-the-edit precedents), the pending object is a ≤120s
   semaphore that dies with the agent's PID, and every other human→agent channel
   is keystroke injection. All 27 subjects across both corpora are now verified:
   execution-layer head-promotion exists nowhere in the field.
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
   *(t3code dig, 2026-07-06)*: the per-scan carve-out deepens into the corpus's only
   architectural convergence — t3code doesn't merely ingest structured provider
   events, it is **event-sourced end-to-end** (commands → pure decider → append-only
   event log as source of truth → projections → fan-out, persist-then-publish), and
   it normalizes **five vendors over four native protocols** (codex app-server
   JSON-RPC, the Claude agent SDK, ACP ×2, the opencode SDK) behind one adapter
   contract. For this subject the borrow accordingly shifts from "taxonomy and UX"
   to *contracts*: the durable catch-up feed (TC1-1) and the adapter/protocol
   surfaces (TC1-3).
   *(herdr dig, 2026-07-06)*: the hybrid's own history now argues the conclusion —
   herdr, holding the field's best scraper, **retreated from hook-borne state** for
   the seven biggest CLIs: the claude pack strips the state hooks earlier versions
   installed and reports session identity only, because vendor hook events proved
   noisy proxies for turn state (SubagentStop reviving idle panes after the main
   turn ended — the reason is a comment in the hook script itself); state authority
   moved back to the screen, fenced by per-source monotonic seqs, stale-generation
   suppression, and process-exit-outranks-everything
   ([herdr HD1-1](herdr/FEATURES-WORTH-BORROWING.md)).
   Borrow-the-taxonomy-never-the-machinery survives its strongest test — with the
   carve-out that the machinery's *fences* are the part that transfers: slice 6's
   CLI adapters will relay exactly this class of noisy proxy.
   *(cmux dig, 2026-07-06)*: the opposite pole, engineered equally deep — cmux made
   hooks the **state authority** ("state transitions come from exactly one channel:
   agent hook events") and deleted its title/mtime scraping layer, curing the same
   stale-reporter disease herdr cured by the opposite retreat; both poles converge
   on the same mechanical fences (generation gating, process-exit outranks
   everything, correct-only corroboration —
   [cmux CM1-2](cmux/FEATURES-WORTH-BORROWING.md)). The fences-transfer carve-out
   is now complete from both directions; the *choice of authority* is what our
   structured events dissolve.
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
   *(Cross-corpus, 2026-07-05)*: multica supplies the strongest adoption
   datapoint yet — the fastest-moving tracker in the pms corpus attaches its
   newest backend drivers via ACP
   ([multica dig](../pms/multica/FEATURES-WORTH-BORROWING.md)); the costed TRACK
   and its trigger stand.
5. **Argus's differentiators survive contact.** Multi-device cluster, shared Postgres,
   phone-first PWA with Web Push, real auth, durable event-sourced history — zero of
   six have any of them (CCC has the PWA shell only, explicitly rejects multi-user and
   persistence). The competitive gap is real; the sub-problem solutions are what's
   worth taking.
   *(Cross-corpus, 2026-07-05)*: the pms corpus narrows the gap but confirms it —
   five of nine subjects ship a second device and two run real server Postgres,
   yet none has multi-node clustering with node-affine execution, a durable
   event-feed catch-up contract behind the UI, an agent-unmintable decision
   object, or execution-layer edit-and-resume
   ([pms observation 5](../pms/README.md)).
   *(t3code dig, 2026-07-06)*: the closest call yet, and the moat still holds —
   t3code ships a real server DB, a **durable event-feed catch-up behind the UI**
   (the first subject in either corpus with one), real scoped auth (the first
   positive §4.4 reference), and two additional device form factors; it still has
   **no multi-node clustering and no durable decision object** (pending approvals
   die with the process — "Restart the turn to continue"), no rolling-upgrade skew
   handling, and no edit-and-resume (subject 27). Where it converges —
   event-sourcing, persist-then-publish, the tailnet execution-boundary doctrine —
   it validates argus; where it diverges it is behind, not ahead.
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
   *(Cross-corpus, 2026-07-05)*: the pms corpus supplied the **delivery-policy
   layer** beneath this stack — assembled the same way, at its own connective
   pass ([pms observation 10](../pms/README.md)): bosun owns aggregation
   ([BO1-3](../pms/bosun/FEATURES-WORTH-BORROWING.md) — immediate-vs-digest
   split, the edited-in-place live digest, the pinned status board), OpenHelm
   owns storm semantics ([OH2-2](../pms/openhelm/FEATURES-WORTH-BORROWING.md) —
   semantic dedup keys, touch-in-place escalation, incident collapse, the
   never-vanish fallback row), myrlin owns the device-side rules
   ([MY1-3](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md) — replay
   suppression, focus-ack-consumes, minimum-signal re-arm), and Chorus the
   recipient model ([CH2-3](../pms/chorus/FEATURES-WORTH-BORROWING.md) —
   per-kind mutes, wake ≠ read). The two-corpus stack now reads: MX1-1 per-agent
   state → EM2-1 fold → CC1-2 feed → pms delivery policy → EM1-3/TM2-5/XA1-2
   triggers.
   *(herdr dig, 2026-07-06)*: the stack's bottom layer gains its engineered
   reference — authority-tiered multi-source arbitration with mechanical
   stale-reporter fences (HD1-1), the damping numbers plus the rule that generates
   them (damp only the inferred clear; evidence bypasses — HD1-2), "done" as a
   seen-fold projection over the closed enum (HD1-3), and two delivery rules the
   merged set lacked (re-verify-at-delivery; blocked pierces DND while completion
   respects it). The settled list UX gains its existence proof: herdr ships the
   corpus's only defect-free priority sorter — selection bound to identity — and
   still defaults to stable grouped order
   ([herdr HD1-3](herdr/FEATURES-WORTH-BORROWING.md)); its `Unknown` ranks below
   idle, the boring-unknown datapoint for muxara OQ-2.
   *(cmux dig, 2026-07-06)*: the delivery layer gains its **cross-device** rules —
   presence-gated forwarding (push only while the operator is away from the
   primary surface) and ack-sync as an absolute synced projection, never
   per-device arithmetic ([cmux CM1-4](cmux/FEATURES-WORTH-BORROWING.md)) — and
   MX1-1's sub-type-at-the-feed / fold-at-the-state composition gets its second
   shipped validation (three actionable feed kinds collapsing to one `needsInput`
   pane state, cmux CM1-3).
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
   *(Cross-corpus, 2026-07-05)*: now answered six times over. myrlin
   independently re-derived **exactly** EM1-3's two triggers — five push
   preference keys declared, precisely `session:complete` + `task:review` live
   ([MY2-4](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)) — with the
   corpus's sharpest cautionary attached: the product that *named* the
   `fileConflicts` trigger ships it as dead code, so every trigger argus
   declares needs a named, tested producer. The failure-push divergence is
   settled: argus FLOW §12 includes run-failed — this operator has left the
   desk — with bosun's immediate-vs-digest split and OpenHelm's guaranteed
   escalation + additive email as the field mechanics that make error pushes
   livable.
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
   *(Cross-corpus, 2026-07-05)*: [pms observation 13](../pms/README.md) extends
   this from doc drift to **wiring mortality** — all eight pms digs found dead
   *code paths*, not just stale docs (26 corrections across the four digs that
   tallied) — yielding two laws now written into the argus plans: advertisement
   without mechanical enforcement rots (pad
   [PD1-1](../pms/pad/FEATURES-WORTH-BORROWING.md), live in our own tree as the
   MCP server's hardcoded `0.2.0`), and a dependency edge survives only if a
   scheduler consumes it (four dead `blocked_by` implementations against two
   live).
   *(t3code dig, 2026-07-06)*: the corpus record — **both flagship architecture
   docs describe a transport that does not exist by those names at HEAD**
   (overview.md's `ServerPushBus`/`ServerReadiness`/`pushBus.ts`; providers.md's
   "Codex is the only implemented provider" against five shipped drivers, plus a
   `wsTransport.ts` that exists only as an oxlint rule name); runtime-modes.md
   documents two of three runtime modes; the README's winget/brew/AUR installs are
   not produced by the release pipeline; the docs index links a `docs/mobile/`
   that doesn't exist; and the wiring-mortality law lands twice more (a fully
   built sequence-gap recovery coordinator plus the `replayEvents` RPC with zero
   production callers; a production receipt bus that is a no-op). Six scan claims
   corrected — the pin-the-commit, read-the-code discipline held.
   *(cmux dig, 2026-07-06)*: milder but present — the README's "No tmux required"
   is accurate only as "no real tmux server" (the feature installs and depends on
   a fake `tmux` shim); `docs/streaming-agent-updates.md` describes a
   screen-scraping subsystem that is a plan, not shipped code; the Go remote
   daemon's claude-teams path silently lacks the Swift path's trust-gate handling
   (a live over-SSH deadlock class); and the repo carries a second, experimental
   multiplexer (`mux/`) whose orchestration primitives exist only in a proposed
   spec.

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
7. ✅ **DONE 2026-07-06 — herdr dig** ([inventory](herdr/FEATURES-WORTH-BORROWING.md)),
   fired the day it was queued, before slice 1's attention build as scoped; all
   three challenge verdicts answered: (1) the engine is as engineered as scanned
   and ports as rubric — but its center is authority **tiering** + stale-reporter
   fences, not symmetric arbitration, and the biggest CLIs' hooks deliberately
   carry session identity only (the retreat from hook-borne state — HD1-1);
   damping confirmed verbatim and sharpened to a single damped transition (HD1-2);
   (2) the PTY broker banks for slice 8 (HD2-1 — keep reattach-as-redraw + the
   single-slot render lane; invert the auth and versioning choices); (3) "zero
   config, no hooks required" resolves exactly as predicted (scrape floor, opt-in
   sharpeners; omp/mastracode manifest-less caveat). Four scan claims corrected
   (SY2-3 single-sourcing credit false; handoff = binary-upgrade FD transfer;
   blocker-override is custom-sources-only; confidence = booleans); subject 25
   empty.
8. ✅ **DONE 2026-07-06 — cmux targeted dig** ([inventory](cmux/FEATURES-WORTH-BORROWING.md)),
   both halves fired together the day queued (operator request, ahead of their
   named triggers — the references now bank *for* those triggers): (1)
   claude-teams is a tmux impersonation on nine unguarded vendor assumptions —
   slice 6's cost sheet for vendor-internal vs structured-surface driving (CM1-1),
   with the restore-argv sanitizer riding MC1-1 (CM2-3); (2) the "thin"
   iOS-client scan claim is **corrected** to ~75k LOC + four cloud services + APNs
   (CM2-1, banked for the §2.6 revisit — which the seams pass upgraded from
   "speed, not merit" to cost-led but merit-checked); the riders delivered the
   hook-authority pole + fences (CM1-2), the typed feed classifier + soft-wait
   cards (CM1-3), and two FLOW §12 cross-device delivery rules (CM1-4); sweep
   subject 26 empty; corpus updates in observations 2/3/6/8, argus OVERVIEW §2.6,
   FLOW §12, SYNTHESIS §5.1/§5.6.
9. ✅ **DONE 2026-07-06 — t3code targeted dig** ([inventory](t3code/FEATURES-WORTH-BORROWING.md)),
   fired the day it was queued, all four challenge-verdicts answered: (1) the
   client/transport/push stack is NOT clean-in-source as doc'd — the architecture
   docs name symbols that don't exist and the transport is pre-release Effect RPC
   plumbing — but one layer up the **durable `afterSequence` catch-up contract +
   client sync loop** is real, convergent with our WorkflowEvent feed, and lands as
   slice 1's working reference with its two defects (mount-pinned cursor, dead
   gap-detection) as our acceptance criteria (TC1-1); (2) remote is shipped
   **beyond** the doc's target-architecture framing (tailscale-serve wrapper, SSH
   launch+tunnel, an in-repo control-plane-only relay — plus the field's first
   positive scoped-auth layer, TC1-2); (3) the provider drift resolves **against
   providers.md** — five drivers over four vendor protocols, `effect-acp` is
   Cursor+Grok's seam, Claude rides the agent SDK, codex has native `thread/resume`
   (TC1-3 — slice 6 / executor PR-2); (4) `CheckpointReactor` is *richer* than
   traycer's file undo — paired tree+conversation rewind (TC2-1) — and still not
   edit-and-resume: **subject 27 verified empty**. Rider: the corpus steering
   record corrected (TC2-2 — mid-turn steer is mainstream here, not BO2-4's
   singular exception).

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
- [x] ~~Dig herdr~~ **Done 2026-07-06** →
      [herdr/FEATURES-WORTH-BORROWING.md](herdr/FEATURES-WORTH-BORROWING.md)
      (scoped as planned — four reader passes + a seams pass @ `85cbe9f2`; haul =
      HD1-1/HD1-2/HD1-3 for slice 1's attention build, HD2-1 banked for slice 8,
      HD2-2 riding the queued MC1-1 build; four scan claims corrected; sweep
      subject 25 empty; corpus updates landed in observations 2/3/6, argus FLOW
      §4/§11/§12, and SYNTHESIS §5.1/§5.6).
- [x] ~~Targeted cmux dig~~ **Done 2026-07-06** →
      [cmux/FEATURES-WORTH-BORROWING.md](cmux/FEATURES-WORTH-BORROWING.md)
      (both halves fired together on operator request, ahead of their named
      triggers — the references bank *for* those triggers: CM1-1 for slice 6's
      reading list, CM2-1 for the §2.6 revisit; four reader passes + a seams pass
      @ `85cbe9f2`; GPL patterns-only held; sweep subject 26 empty; one scan claim
      corrected, one sharpened).
- [x] ~~Targeted t3code dig~~ **Done 2026-07-06** →
      [t3code/FEATURES-WORTH-BORROWING.md](t3code/FEATURES-WORTH-BORROWING.md)
      (scoped as planned — five reader passes + a seams pass @ `85cbe9f2`; haul =
      TC1-1 catch-up contract for slice 1, TC1-2 scoped auth for argus §4.4, TC1-3
      five-driver/app-server stack for slice 6 + executor PR-2; subject 27 empty;
      six scan claims corrected; corpus updates landed in observations 2/3/5/8,
      argus FLOW §13, SYNTHESIS §5.6, and OVERVIEW §4.4).

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

**Cross-corpus status update (2026-07-05** — the [pms corpus](../pms/README.md)
closed 2026-07-04, and its combined first wave moves four of the items above**)**:
**TR1-2a is superseded** — pad [PD1-1](../pms/pad/FEATURES-WORTH-BORROWING.md)
fuses the same golden-pin with the served-surface *advertisement* half traycer
lacks into one queued stability-contract PR
([PD-FIRST-WAVE](../pms/pad/PD-FIRST-WAVE.md)), which also kills the hardcoded
MCP `0.2.0` the pad dig found live in our tree. **XA2-3 has its closing item
queued** — the scheduled provider credential canary
([SY-FIRST-WAVE](../pms/symphony/SY-FIRST-WAVE.md) item 1, built on
`Config.check_provider/1`), with symphony SY1-4 the only shipped probe in either
corpus and myrlin MY1-1's transient-never-marks-dead rule as the health-model
upgrade. **CC1-2a gained its missing reply half** — surfacing Forge
`:needs_input` without `Forge.apply_input/2` wired would show a park nobody can
answer; the combined surface-plus-reply item is queued with done-when criteria
at [CH-FIRST-WAVE item 1](../pms/chorus/CH-FIRST-WAVE.md). **XA2-1 is now a
three-subject convergence** — bosun
[BO2-5](../pms/bosun/FEATURES-WORTH-BORROWING.md) ships the reference
implementation (expiry + reconcilers) and OpenHelm ships the same never-expire
gap, both pointing at our missing `AgentCase` TTL/sweeper. EM2-3, TM1-1, CC1-1,
and CC2-2 stand unchanged.

*(2026-07-09: the combined set is queued at
[docs/plans/pre-argus-do-now](../../plans/pre-argus-do-now/README.md) —
including two items this corpus deliberately parked in Forge/security territory
(termic TM1-2, joined by crabbox CB1-1/CB1-2) and one garnish it never rolled up
(emdash EM3-3); the cmux subscription-lane plan's Lane A got its operator
go-ahead the same day.)*
