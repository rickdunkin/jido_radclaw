# Agent Control-Plane Landscape Scan (ades)

**Status**: initial scan (2026-07-03). Quick pass over the repos cloned at
`~/workspace/research/ades/` — six parallel read-only scan passes (README + docs skim,
manifests, top-level source layout, a handful of key files) plus git metadata. Nothing
here has been built, run, or read in depth yet; treat every claim as "per their docs /
light skim" until a follow-up dig verifies it. Scanned at: claude-command-center
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
| [claude-command-center](https://github.com/amirfish1/claude-command-center) | Local dashboard for every Claude Code/Codex/Cursor/Antigravity/Kilo session on the machine | Python stdlib server + vanilla JS; REST + SSE; no DB (rescans `~/.claude/**` per request) | MIT | 2,019 commits, solo author (aliases), active Jul 2026, v5.5.0 alpha | Read-mostly dashboard kin; donors: attention/"soft-block" detector, editable managed-markdown + mtime-409 save, PWA shell, tailnet posture |
| [emdash](https://github.com/generalaction/emdash) | Desktop app for parallel coding agents, one git worktree per task (General Action, YC W26) | Electron/TS nx monorepo; React + Solid; SQLite + Drizzle; ACP runtime | Apache-2.0 | 8,044 commits, 126 contributors, very active Jul 2026, v1.1.36 | Comparable cockpit; donors: worktree lifecycle service, ACP permission model, `workspace-server` oRPC contract (stubbed multi-device direction) |
| [muxara](https://github.com/muxara/muxara) | macOS mission control for parallel Claude Code tmux sessions | Tauri 2 (Rust + React 19); no DB, reconciles from tmux each poll | MIT | 72 commits, 2 contributors, quiet since May 2026, v0.1.5 | Minimal kin; donor: NeedsInput/Working/Idle/Errored status taxonomy + attention-sorted UX |
| [termic](https://github.com/simion/termic) | "One window, many parallel coding agents, each in its own git worktree" — open Conductor alternative | Tauri 2 (Rust + React 19); PTY-spawns real agent CLIs; JSON-file persistence | **AGPL-3.0** | 392 commits, 7 contributors, ~7 weeks old, multiple releases/week, v0.17.7 | Closest desktop comparable; donors (**patterns only — AGPL**): worktree layout + Spotlight mirror, turn-completion detection, review-comment batching |
| [traycer](https://github.com/traycerai/traycer) | Traycer AI's full orchestration product, open-sourced — BYOA orchestrator over Claude Code/Codex/Cursor/OpenCode | Electron 42 + React 19, Bun + Nx, ~440k LOC; yjs CRDT; versioned WS-RPC; SQLite + cloud sync | Apache-2.0 | 113 commits (history likely squashed at open-sourcing; PRs to #187), 8 contributors, active Jul 2026, v0.x | **Dug 2026-07-03** → [inventory](traycer/FEATURES-WORTH-BORROWING.md): closest *contract-layer* comparable (host binary is closed-source; epic is a CRDT container, not a DAG); haul = versioned-RPC skew layer (TR1-1/-2) + worktree schema cribs (TR1-3/-4); checkpoints are per-turn file undo — **no edit-and-resume** |
| [Xantham-system-blueprint](https://github.com/ZQadus/Xantham-system-blueprint) | Paste-into-Claude-Code "self-installing personal AI orchestrator" blueprint (Telegram-driven) | ~18k lines of markdown wizard/templates + real bash hooks + a Docker audit sandbox | MIT | 61 commits, 1 author, last Jun 2026, v32 | Contrast only: single-machine prompt orchestrator; its ideas (worktree-per-agent, phone approvals, council) are covered natively or superseded by argus's design |

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

**muxara** (Contino folks). The minimal take: Tauri 2 mission control that polls tmux
every ~1.5s, classifies each Claude Code session NeedsInput/Working/Idle/Errored (with
Permission-vs-Question sub-types and plan-mode detection), attention-sorts cards, and
switches you into the real terminal. No DB, no orchestration, notifications explicitly
unimplemented, quiet since May 2026. The borrowable bit is the **status taxonomy and
needs-input-floats-to-top UX** — a clean, small spec for how argus's agent list should
sort and badge, fed by our structured events instead of their regex scraping.

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

## Cross-cutting observations

1. **Worktree-per-task is unanimous.** Five of six converged on it independently —
   strong validation for argus §3.1, and three concrete schema/lifecycle references to
   study before we model `Worktree`: traycer's `worktree-schemas.ts` (per-device
   binding ≈ our `node` column), emdash's `worktree-service.ts` (lifecycle scripts,
   preservePatterns), termic's layout + Spotlight mirror.
2. **Nobody has edit-step-output-and-resume.** The closest analogs: traycer's Epic
   checkpoint manifests (dig-confirmed 2026-07-03: per-turn file undo, not workflow
   checkpoints — the traycer slot is now *verified* empty), CCC's editable
   managed-markdown with 409 saves, emdash's Plan Mode approve gate. Argus §5 remains
   genuinely novel in this set — and CCC's mtime-409 is independent convergence on the
   optimistic-concurrency shape we sketched (`expectedSeq` CAS; note the traycer dig's
   seams pass found the argus sketch's "the event append is the CAS" premise is wrong —
   the append is pessimistic; see TR2-3).
3. **Everyone else scrapes; we have events.** All five apps spend their hardest
   engineering on inferring agent state from terminals (muxara's regex+debounce,
   termic's OSC 9;4 + quiet-gating, CCC's scored soft-block heuristic). Argus reads
   the `WorkflowEvent` log and `AgentCase` rows. Borrow the taxonomy and attention UX;
   skip every line of detection machinery.
4. **ACP is emerging as the agent↔client protocol** — emdash builds its session
   runtime on it, CCC ships an adapter, and it standardizes exactly the
   permission-request surface our tool-approval gate exposes. Worth a standing
   question: should JidoClaw eventually *speak* ACP so third-party cockpits (emdash,
   Zed, …) can drive it, with argus's GraphQL/Channels as the richer first-party
   surface on top?
5. **Argus's differentiators survive contact.** Multi-device cluster, shared Postgres,
   phone-first PWA with Web Push, real auth, durable event-sourced history — zero of
   six have any of them (CCC has the PWA shell only, explicitly rejects multi-user and
   persistence). The competitive gap is real; the sub-problem solutions are what's
   worth taking.

## Early read (to be challenged in the deep-dive)

1. ✅ **DONE 2026-07-03 — traycer dig** ([inventory](traycer/FEATURES-WORTH-BORROWING.md)).
   Verdict: closest *contract-layer* comparable — the skew layer and worktree schemas
   delivered (TR1-1..TR1-4, TR2-1/-2/-4); Epic checkpoints turned out to be per-turn
   file undo (no edit-and-resume anywhere); one INDEPENDENT correction to the argus
   `expectedSeq` sketch (TR2-3); one do-today item (TR1-2a, MCP golden test).
2. **Second dig: emdash** — worktree lifecycle scripts, the ACP permission model, and
   the `workspace-server` contract as a checklist against argus's API surface plan
   (§4). Its scale (126 contributors) makes it the best-tested worktree UX of the set.
3. **Targeted read, not a full dig: CCC** — `docs/attention-api.md`,
   `docs/flow-workspace.md`, `docs/worktree-init.md`; the soft-block detector and the
   409-save editable-node model are the two transplantable ideas.
4. **Pattern notes only: termic** (AGPL — ideas, never code): Spotlight mirror,
   turn-completion signals, review-comment batching.
5. **Captured here, no dig: muxara** (status taxonomy is the whole borrow) and
   **Xantham** (methodology contrast; mechanisms are coarser versions of what we run).

## Suggested next steps

- [x] ~~Deep-dive traycer~~ **Done 2026-07-03** →
      [traycer/FEATURES-WORTH-BORROWING.md](traycer/FEATURES-WORTH-BORROWING.md)
      (scoped as planned: worktree schemas / Epic checkpoints / versioned-RPC).
- [ ] Deep-dive emdash (`explore-repo`), scoped to worktree lifecycle + ACP
      permissions + the workspace-server contract-as-checklist.
- [ ] Targeted CCC read: attention/soft-block heuristics + Flow editable-node
      409-save model; fold anything durable into the argus §5 editor design notes.
- [ ] Decide whether **ACP** merits its own corpus subject (protocol-level, like the
      squidie engine comparison) — trigger: when argus's API surface plan (§4) gets a
      design pass, evaluate "expose ACP alongside GraphQL" then.
- [ ] No action: muxara, Xantham — revisit only if argus's agent-list UX (muxara's
      taxonomy) or phone-approval loop (Xantham's Telegram gate) needs a second
      reference at build time.
