# Features Worth Borrowing from herdr

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-06**, the full
dig queued by the [ades scan](../README.md)'s category 4 / early-read item 7 (fired, per its
own trigger, before argus slice 1's attention build). Source:
`~/workspace/research/multiplexers/herdr` (ogulcancelik/herdr). Self-description: *"run all
your coding agents in one terminal. see who's blocked, working, or done at a glance… (if
you've used tmux: it's that, rebuilt for agents.)"* Subject @ `5b4450c` (unmoved since the
2026-07-06 quick scan), jido_radclaw @ `85cbe9f2`. Cites are firsthand reads of both trees,
accurate to within a few lines.

Shape and maturity: a single Rust binary (~10MB per README), 231 `.rs` files ≈ 189k LOC
including the vendored ghostty-vt terminal core and portable-pty; no DB — pretty-JSON
session files with atomic tmp+rename writes (`persist/io.rs:48-61`); wire
`PROTOCOL_VERSION = 16`, snapshot schema v3, detection-manifest engine v2. 1,033 non-merge
commits, effectively solo (876 by Ogulcan Celik; the largest other human contributor has
14; 45 contributors counting bots), 30 releases 2026-04-12 → v0.7.1 (2026-06-24), daily
commits at HEAD (2026-07-07); #1 GitHub trending Jun 30 per the README badge. Windows is a
preview beta with real feature gates (no remote mode, no live handoff, 6-of-14
integrations). Nothing was built or executed this review; all claims are code reads.

**License law for this doc — AGPL-3.0-or-later, dual-licensed commercial** (LICENSE:1-8;
"contact hey@herdr.dev"). The termic discipline applies: **nothing here may be lifted as
code, ever** — every verdict is BORROW-PATTERN / BORROW-REFERENCE / BORROW-RUBRIC /
FOLD-IN, reimplemented from the contract in our idioms; where an entry rides a public
protocol (ConEmu OSC 9;4, xterm titles), cite the protocol's own docs, never herdr's
implementation of it.

**Doc/code drift found while reading** (small, and unusually honest for the corpus): the
README's integration list names 13 packs while the code ships 14 (`mastracode` omitted —
`integration/registry.rs:252-332` vs README:124); `src/persist.rs:1-4` documents
`~/.config/herdr/session.json` while named sessions actually write
`sessions/<name>/session.json` (`session.rs:161-171`); the flagship "zero config, no hooks
required" resolves exactly as the scan predicted — scrape as the floor, opt-in
integrations as additive sharpeners — with one caveat the sentence hides: `omp` and
`mastracode` have **no screen manifest at all** (`detect/mod.rs:66-87`), so zero-config
yields nothing for them. The README's own supported-agents table self-reports its gaps
(pi blocked "partial", kiro blocked "—", gemini/cline "not fully tested") and the code
agrees.

Companion docs: [ades scan README](../README.md) (umbrella — this dig answers its
category-4 questions and **corrects four scan claims**, below);
[muxara](../muxara/FEATURES-WORTH-BORROWING.md) (MX1-1, the single-agent status contract
this dig's Tier 1 refines); [claude-command-center](../claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-1/CC1-2 — the soft-block rubric herdr verifiably lacks, and the feed layer above
this dig's state layer); [emdash](../emdash/FEATURES-WORTH-BORROWING.md) (EM2-1 seen-flag,
EM1-3 triggers); [termic](../termic/FEATURES-WORTH-BORROWING.md) (TM1-1/TM2-1 — the
OSC emit/consume contrast, TM2-5 delivery); [multica](../../pms/multica/FEATURES-WORTH-BORROWING.md)
(MC1-1 — the queued CLI-resume build HD2-2 rides); [symphony](../../pms/symphony/FEATURES-WORTH-BORROWING.md)
(SY2-3 — the single-sourcing pattern the scan wrongly credited herdr with);
[t3code](../t3code/FEATURES-WORTH-BORROWING.md) (TC1-2 positive auth reference, TC2-3
server-owned-PTY sibling); [argus OVERVIEW](../../argus/OVERVIEW.md) /
[FLOW](../../argus/FLOW.md) / [SYNTHESIS](../../argus/SYNTHESIS.md) (the consumers — §11
operator terminal, §12 attention, SYNTHESIS §5.1 stack). Threat model (personal,
tailnet-only): LLM-misbehavior containment and leakage hygiene over external-attacker
hardening.

## Determination (TL;DR)

**The dig's three challenge verdicts all answer — two confirmed with sharpenings, one
scan claim outright corrected — and the haul lands almost entirely in argus slice 1's
attention build.** (1) The state engine is as engineered as the scan hoped, and it ports
as rubric — but its center of gravity is not "dual-source arbitration with confidence
scores." It is **explicit per-source authority tiering plus mechanical fences that keep
any weaker reporter from lying**: per-source monotonic sequence guards, stale-generation
suppression with fresh-ref re-anchor, scraper-observed process exit outranking every hook,
viewer-screen neutralizers (`skip_state_update`), and exactly **one** damped transition
(working→plain-idle; everything else raises instantly). The field lesson underneath is
the dig's sharpest find: herdr **retreated** from hook-borne state for the seven biggest
CLIs — the claude pack (v7) wires a single `SessionStart` hook for session identity and
actively strips the state-mapped hooks earlier versions installed, with the reason
documented in the script itself ("Claude recap/away-summary can emit [SubagentStop] after
the main turn has already stopped. Never let it revive an idle pane") — because vendor
hook events proved noisy proxies for turn state. That is the strongest outside validation
yet of the corpus's "we have events, everyone else has proxies" observation, from the
project with the field's best scraper. (2) The PTY broker banks cleanly as the FLOW §11
operator-terminal reference (slice 8): server-owns-PTY, thin exact-version clients,
reattach as current-state redraw, a single-slot latest-wins render lane per client — with
its two negative halves (no auth beyond fs perms + ssh; exact-match protocol versioning)
already owned by t3code TC1-2 and traycer TR1-1/PD1-1 as the positive references. (3) The
riders deliver: the corpus's widest **per-vendor CLI resume argv table** (14 agents, rides
the queued MC1-1 build), worktree naming/teardown datapoints, detection **manifests as
versioned, distributable data**, and a managed vendor-config-edit contract. The standing
sweep closes empty at **subject 25**: herdr owns no gate or approval object; every
human→agent channel is a pass-through PTY write. As a dependency: no — the AGPL decides
first, and there is no seam anyway (Rust binary, no DB, fs-perms trust).

| Part of herdr | As a dependency | What to take |
| --- | --- | --- |
| Detection engine (`src/detect/`, `pane/agent_detection.rs`, `terminal/state.rs`) | No | The authority-tiering + fence contract (HD1-1); the one-damped-transition rubric (HD1-2); manifests-as-versioned-data (HD2-3) |
| Hook integrations (`src/integration/`) | No | The retreat-to-session-ref lesson (inside HD1-1); the managed config-edit contract (HD2-5). Scan's SY2-3 claim corrected: hand-written packs, not generated |
| Agents panel + notifications (`ui/sidebar.rs`, `app/actions.rs`) | No | done = (idle, ¬seen) + the identity-bound opt-in priority sort (HD1-3); re-verify-at-delivery + blocked-pierces-DND (HD1-2) |
| Server / PTY broker / client protocol / remote (`src/server/`, `pty/`, `client/`, `remote/`) | No | The banked slice-8 reference (HD2-1); the single-slot render lane (HD3-1). Negative refs: exact-match versioning (S-3), fs-only socket trust (S-4) |
| `agent_resume.rs` | No | The 14-vendor resume argv table + `session_start_source` vocabulary → FOLD-IN to MC1-1 (HD2-2) |
| `worktree.rs` | No | Naming/teardown datapoints → FOLD-IN to FLOW §4/§5 (HD2-4) |
| Socket API + plugins + SKILL.md | No | ACP-TRACK datapoint: skill-as-integration-surface + wait-verbs; trust posture is a negative reference (HD3-2) |
| Persistence + live-handoff FD transfer | No | Contrast only (S-6) — the heroic cost of process-held state; our durable substrate obviates it |

**Why not adopt as a dependency**: (1) AGPL-3.0 — a hard no for this codebase regardless
of merit; (2) a single Rust binary with no OTP/Ash seam, JSON-file persistence, and
0600-socket trust — nothing composes with our substrate; (3) the asymmetry runs our way on
every orchestration axis: no durable events (a 4-state in-memory enum + one JSON
snapshot), no gate family (S-1), no auth story (S-4), no skew tolerance (S-3), and a
server restart kills every pane short of the SCM_RIGHTS handoff (S-6). Its excellence is
concentrated exactly where we are weakest — live per-agent state over a real terminal —
which is why this is a rubric-and-reference dig, not an adoption question.

## How to read this document

Recommendation vocabulary per the [corpus conventions](../../README.md): BORROW-PATTERN /
BORROW-REFERENCE / BORROW-RUBRIC / BUILD-ON / FOLD-IN / INDEPENDENT / TRACK /
ALREADY-COVERED / SKIP. Initial inventory — no Status lines. IDs are `HD<tier>-<seq>`;
`S-n` skips; `OQ-n` open questions.

Tiers are scoped to this doc's consumers: **Tier 1** = load-bearing for argus slice 1's
attention build (the dig's own named trigger — read these before writing that code).
**Tier 2** = banks for a later slice or folds into an already-queued build (slice 8's
terminal, the MC-FIRST-WAVE resume stack, the CC1-1 rubric build, the FLOW §4/§5 worktree
step). **Tier 3** = garnish and datapoints. Per-entry fields as usual: Where in herdr /
What / Gap in jido_radclaw (verified 2026-07-06) / Why it matters / Adoption sketch.

---

## Tier 1 — load-bearing for argus slice 1 (the attention build)

### HD1-1. Authority-tiered state arbitration + the stale-reporter fences

**Recommendation**: BORROW-PATTERN — the multi-source half the MX1-1 single-agent
contract never had. Read before wiring any second status source into one agent's surfaced
state (slice 1 folds WorkflowEvent projections, `AgentCase` pendings, Forge phases, and —
at slice 6 — CLI-thread signals into one per-agent state).

**Where in herdr**: sources are tiered into three explicit authority classes. (a)
**Full-lifecycle hook agents** (`full_lifecycle_hook_authority()`, `detect/mod.rs:244-255`
— pi, omp, mastracode, hermes, opencode, kilo, kimi): the hook owns state absolutely —
screen-detected state is dropped (`terminal/state.rs:519-527`), screen scanning and
process probing pause (`app/api.rs:379-397`), and a screen-visible blocker can **never**
override (`state.rs:1239-1240`) — with one deliberate exception: **process-exit
validation stays live** (`pane.rs:728`), because a dead process outranks any report. (b)
**Reserved native-state agents** (`agent_resume.rs:81-92` — claude, codex, copilot,
devin, droid, qodercli, cursor): their hooks carry **session identity only**
(`app/actions.rs:2580-2585`); state stays screen-scraped. (c) **Custom/socket sources**:
take state authority (`actions.rs:2587-2599`), but a not-older screen-visible blocker for
the same agent raises Blocked over their non-blocked report
(`visible_blocker_overrides_hook`, `state.rs:1238-1249`). The resolver is one function
(`recompute_effective_state`, `state.rs:1313-1353`): hook authority wins, else screen,
with the blocker exception. The fences that make tiering safe: per-source **monotonic
sequence guard** (`accept_hook_report`, `state.rs:1078-1093` — a report with
`seq <= last_seq` is dropped); **owner-conflict rejection** (a `(source, agent)` takeover
needs the foreground-*detected* agent to confirm it, `state.rs:844-850,1065-1076`);
**`session_start_source`-gated replacement** (a same-owner session-id change is honored
only for declared reasons — claude `clear|resume|compact`, opencode `new`, …,
`state.rs:899-921`); **stale-generation suppression + fresh-ref re-anchor**
(`state.rs:85-87,601-691,403-450` — a late report from a previous agent generation is
suppressed until a genuinely new session ref re-anchors the guard); and **process-exit
suppression** (`state.rs:262-287` — scraper-observed exit clears hook authority
unconditionally). Confidence is **four booleans, not a score** (`AgentDetection`,
`detect/mod.rs:22-39`): `visible_idle`/`visible_blocker`/`visible_working` mark
chrome-backed evidence, and `skip_state_update` neutralizes agent-owned viewer screens
(transcript scrollback must not read as live idle) — manifest validation *forces* such
rules to `state = "unknown"` with no visible flags (`manifest.rs:908-921`).

**The retreat, documented in their own tree**: the claude pack is at integration version
7, wiring **only** `SessionStart` and actively stripping the
`PostToolUse`/`PermissionRequest`/`Stop`/`SessionEnd` state hooks earlier versions
installed (`integration/targets.rs:140-156`); `mod.rs` keeps the removed event tables
purely for uninstall cleanup (`*_REMOVED_LIFECYCLE_HOOK_EVENTS`, `mod.rs:88-140`); the
script drops all subagent payloads and `SubagentStop` with the why in a comment
(`assets/claude/herdr-agent-state.sh:52-59`). Seven of fourteen packs now report session
identity only.

**Gap in jido_radclaw** (verified 2026-07-06): our richest per-agent surface,
`AgentView.derive_status/4`, is single-source (a 5s poll over traces + handoff/worker
info, `agent_view.ex:28-31,529+`) with no authority model, no sequence fences — and
**completed collapses to `:idle`** (see HD1-3). `SwarmView` is lifecycle-only
(`:running | :done | :error`, `agent_tracker.ex:93`). No damping or confirmation logic
exists anywhere in our status pipelines (seams pass §3: the `front_door.ex`
classification thrash-guard and LiveView render debounces are the only debounce-shaped
code, and neither is state damping).

**Why it matters**: muxara gave the enum, emdash the fold, CCC the feed — nobody gave the
**composition rule for multiple reporters of one agent's state**, and argus will have ≥3
reporters per thread on day one (event projections, gate/case state, Forge phase; slice 6
adds adapter-relayed CLI signals — exactly the noisy-proxy class herdr retreated from).
The retreat lesson is also the corpus observation-3 validation from the strongest
possible source: the field's best scraper tried hook-borne state for Claude and moved
authority *back to the screen*, keeping hooks only for what they're authoritative about
(session identity). Our structured events don't have that problem — but our future CLI
adapters will, and this entry is the pre-written answer: tier the sources explicitly,
fence staleness mechanically, and let engine-observed facts (process exit; our law-2
posture generalized) outrank relayed claims.

**Adoption sketch**: when slice 1 builds the per-agent status read-model — authority as
data, not scattered conditionals: each source declares
`authority: :authoritative | :identity_only | :advisory` per state facet; a per-source
monotonic cursor (we already have durable event seq — reuse it, don't mint wall-clock
seqs); engine-observed facts (process/session terminal events) clear any advisory
authority unconditionally; replay/viewer contexts (transcript re-render, catch-up
delivery) are marked so they can never publish as live state. Keep the enum closed and
the tiering table in one module the way `recompute_effective_state` is one function.

### HD1-2. The damping rubric: damp only the clear, re-verify at delivery

**Recommendation**: BORROW-RUBRIC — the concrete numbers for MX1-1's
"raise-fast/clear-slow", plus two delivery rules the FLOW §12 merged set lacks.

**Where in herdr**: all damping is one small state machine
(`pane/agent_detection.rs:5-13`, constants verbatim):

```rust
const AGENT_PENDING_IDLE_RECHECK: Duration = Duration::from_millis(100);
const AGENT_PENDING_IDLE_CONFIRMATIONS: u8 = 3;
const AGENT_PENDING_IDLE_CAP: Duration = Duration::from_millis(700);
const STABLE_VISIBLE_SIGNAL_REFRESH: Duration = Duration::from_millis(800);
const AGENT_STARTUP_GRACE_WINDOW: Duration = Duration::from_secs(3);
```

**Exactly one transition is damped**: `Working → plain Idle` (no visible-idle chrome, no
blocker, agent unchanged, process alive) holds until 3 confirmations or 700ms
(`should_hold_working_to_idle`, `:39-77`). Everything else publishes immediately
(`:140-154`) — Blocked and Working raise instantly; screen chrome (`visible_idle`)
**bypasses** the hold (`:47-52`); a persistent blocker re-publishes every 800ms to
refresh notifications (`:156-168`); process exit forces Idle immediately (`:305-313`); a
3s startup grace absorbs launch noise. Delivery layer (`app/actions.rs`): the *request*
sound + attention toast fire on **any** transition to Blocked — even in the focused
workspace (test `waiting_sound_plays_even_in_active_workspace`, `:4391-4396`) — while the
*done* sound fires only on a background completion transition
(`is_completion_transition_parts`, `:22-54`; focus-DND at `:56-61` suppresses done,
never blocked). Notifications are **delayed then re-verified**: `ui.toast.delay_seconds`
(default 1) queues a pending notification that re-checks, at delivery time, that the pane
is still in the notified state with the same agent — else it's dropped
(`:2847-2902`); pending entries are keyed by pane, latest-wins (`:2822`). Per-agent sound
overrides exist, with the flappiest agent (droid) shipped default-off
(`config/sound.rs:173`).

**Gap in jido_radclaw** (verified 2026-07-06): no damping of any surfaced state anywhere
(seams §3); no push machinery yet (FLOW §12 is design). Our status changes propagate raw
— fine for durable run statuses, wrong for the fast-flapping live layer slice 1 adds.

**Why it matters**: (a) The asymmetry has a *reason* now, not just a slogan: blocked and
working are backed by evidence (chrome, activity) and must never be held; only inferred
quiet is ambiguous, so only the quiet-clear gets damped — and even it yields to explicit
evidence. That rule transfers verbatim to our derived states. (b) **Re-verify-at-delivery**
is the delivery rule the merged FLOW §12 set (edge-dedupe, debounce, replay suppression,
digest, storm collapse) doesn't have: after any delay, re-prove the predicate before the
phone buzzes — for us, "is the AgentCase still pending?" — killing the
notification-for-a-resolved-gate class outright. (c) The blocked-pierces-DND asymmetry is
termic TM2-5's sound-split with the polarity argued from the other side (termic: sound
only on done; herdr: sound always on blocked, done only in background). Both agree
completion is ambient and blocking is the loud one; adopt herdr's polarity — a gate the
operator is looking at still deserves the ping, because looking ≠ noticing.

**Adoption sketch**: at slice 1: damp only clear-direction transitions of the derived
per-agent state (N-confirmations-or-cap, evidence bypass); at the notifier: (1) delay
window per kind, (2) re-verify the predicate at fire time against the durable row (gate
still pending, run still failed-unacked), (3) one pending per (agent, kind), latest wins,
(4) blocked-class bypasses focus/quiet suppression, completion-class respects it.

### HD1-3. "done" = (idle, ¬seen) — the seen-fold, and the identity-bound priority sort

**Recommendation**: BORROW-PATTERN — the composition answer for MX1-1's enum × EM2-1's
seen-flag, plus the datapoint that reopens (and re-settles) the sorting question.

**Where in herdr**: the core enum has **four** states —
`Idle | Working | Blocked | Unknown` (`detect/mod.rs:9-20`); there is no `Done` variant.
"done" is a **projection**: `(Idle, seen: false) => "done"`, `(Idle, seen: true) =>
"idle"` (`ui/sidebar.rs:157-164`, `ui/status.rs:221-228`). `seen` flips false only on a
*background* completion (`app/actions.rs:2802-2807`) and true when the operator looks —
tab focus, or the host terminal regaining focus over a visible done pane
(`actions.rs:1117-1136`, `app/runtime.rs:165-166`). The public API publishes the folded
five-value enum (`agent_status: idle|working|blocked|done|unknown`) with the definition
in prose: *"done means the agent finished, but you have not looked at that finished pane
yet"* (SKILL.md). The agents panel defaults to **stable grouped-by-space order**; an
opt-in `ui.agent_panel_sort = "priority"` (`config/model.rs:91-107`) ranks
`Blocked=4 > done=3 > Working=2 > idle=1 > Unknown=0`, tie-broken by most-recent state
change (`ui/sidebar.rs:144-151,218-226`) — and the highlighted row is **computed from the
focused pane's identity each frame** (`ui/sidebar.rs:1071`), so it follows the agent
across reorders. Unknown ranks below everything and renders muted (`status.rs:196-239`).

**Gap in jido_radclaw** (verified 2026-07-06): `AgentView` collapses completed traces to
`:idle` (`agent_view.ex:28-31`) — "finished while you were away, unreviewed" is
indistinguishable from "sitting idle" on every surface we own; nothing implements EM2-1's
fold/seen yet. The corpus list-UX law (badges on stable order, one hoisted bucket,
selection binds to identity — SYNTHESIS §5.1) was sealed on muxara's *defect*; no subject
had shipped a safe sorter.

**Why it matters**: (a) The seen-fold is the cleanest composition of the stack's layers 1
and 2: the state enum stays closed and detector-owned; acknowledgement is orthogonal
UI-side state; "done" exists only at the presentation/API boundary. It also composes with
termic TM3-2's fingerprint-tied marks — our natural key is *seen-at-event-seq*, which
self-expires when the agent moves. (b) The sorter is the **existence proof the settled
question was missing**: muxara proved sorting drifts selection (MX2-1); herdr ships
sorting with selection bound to identity and *still defaults to stable grouping*. Net:
the law stands as the default, and an opt-in priority sort is now known-safe under one
condition (selection-by-identity). (c) `Unknown` ranking below `idle` is the
boring-unknown answer to muxara OQ-2, from the field's most engineered classifier —
foreign/unclassifiable panes don't get attention rank; a *known agent in an ambiguous
state* is a different thing (herdr never conflates them, because agent identity is a
separate field from state).

**Adoption sketch**: slice 1's agent list: closed per-agent enum + `seen_at_seq`;
"done" derived at the projection (run terminal status + unacked), never stored as state;
default stable order + the one hoisted blocked bucket; if a priority sort ships at all,
opt-in with selection-by-identity (we get this for free — our selection is by agent/run
id, never row index). Pre-argus, the same fold fixes today's web card: split
`AgentView`'s `:idle` into completed-unacked vs idle when EM2-1's fold is built — this
dig adds the projection shape, not a new queue item.

---

## Tier 2 — banks for a later slice, or folds into a queued build

### HD2-1. The PTY-broker architecture — the banked slice-8 reference

**Recommendation**: BORROW-REFERENCE, banked (the dig's own framing: banks, not
unblocks). Named consumer: FLOW §11's per-worktree operator terminal (slice 8,
deliberately last).

**Where in herdr**: the server auto-daemonizes on first launch (`setsid`, stdio to
`/dev/null`, 15s ready probe — `server/autodetect.rs:291-307`, `platform/mod.rs:52-63`)
and owns every PTY (portable-pty spawn, `pty/backend/unix.rs:11-40`; vendored ghostty-vt
emulation, `pane.rs:1676`). Clients are thin renderers over a length-prefixed binary
protocol (2MB frame cap; `protocol/wire.rs:811-878`). **Reattach replays nothing**: a
connecting client gets a full redraw of *current* state; scrollback stays server-side,
byte-bounded per pane (10MB default, `config/model.rs:852`). Multi-client is one shared
runtime — the foreground (most recently active) client's size wins and everyone is
force-redrawn (`server/headless.rs:849-883`); per-client backpressure is the two-lane
writer (HD3-1). Remote mode tunnels the same client protocol over ssh via a local socket
bridge and a `remote-client-bridge` subcommand on the far side, with sha256-verified
binary auto-provisioning (`remote/unix.rs:155-192,1400-1520`); auth is **entirely
delegated to SSH** — sockets are 0600, no tokens (`api/server.rs:24`). Version
negotiation is **exact-match both directions** ("please upgrade your herdr
client/server", `wire.rs:914-932`). A server restart kills every pane (they're its
children); survival is either the persistence re-spawn (fresh shells + the HD2-2 resume
argv) or the Unix-only **live handoff**: PTY master FDs passed to the replacement server
over SCM_RIGHTS, ≤64 panes, 8KB replay each (`server/handoff.rs:20-42`).

**Gap in jido_radclaw** (verified 2026-07-06): no PTY exists anywhere in our tree — every
execution path is `Port`/pipes (`os_cmd.ex:101`, `host_shell.ex:213-227`) and ghostty_ex
remains a recorded verdict, not a dependency (not in `mix.exs`); live output reaches only
the operator's own attached REPL via `Display` streaming; web/remote surfaces see
captured output and phases, never a live terminal (seams §4). FLOW §11 specs the
endpoint's guardrails (owning node, operator-only, never model-reachable, per-session
short-lived tokens) with no mechanics reference until now.

**Why it matters**: FLOW §11's guardrails are our half; herdr is the worked mechanics
half — the only server-side PTY broker in either corpus family, production-hardened in
exactly the shape argus needs (broker on the owning node, dumb clients, phone reach). The
load-bearing choices to keep: reattach-as-current-state-redraw (no byte replay — sidesteps
the catch-up problem entirely for a *live* surface; our durable feeds stay the answer for
*history*), server-side bounded scrollback, and size-follows-the-active-viewer. The
deltas to invert: auth (per-session UI-minted tokens per FLOW §11 — herdr's 0600+ssh is
the personal-machine answer, t3code TC1-2 the tailnet one) and skew (S-3 — a broker
embedded in a rolling-upgrade cluster cannot demand exact version match).

**Adoption sketch** (when slice 8 fires): PTY via a NIF/port dep — decide together with
termic OQ-2 and the parked ghostty_ex scope (its `forkpty` half was deliberately
deferred); one broker process per worktree terminal on the owning node; frames over the
authed WebSocket channel; per-subscriber single-slot latest-wins (HD3-1); bounded
scrollback; reattach = state redraw; protocol under the PD1-1 surface-version contract,
not exact-match.

### HD2-2. The 14-vendor resume argv table + session-ref plumbing (FOLD-IN → MC1-1)

**Recommendation**: FOLD-IN — a rider on the queued MC-FIRST-WAVE CLI-session-resume
build (multica MC1-1 is the primary reference; termic TM2-2 the strategy ladder).

**Where in herdr**: the widest per-vendor resume table in either corpus
(`agent_resume.rs:115-197`): `claude --resume <id>`, `codex resume <id>` (subcommand, not
a flag), `copilot --resume=<id>`, `devin/droid/hermes/qodercli --resume <id>`,
`kimi/opencode/kilo --session <id>`, `mastracode --thread <id>`, `cursor` via the
differently-named `cursor-agent` binary, and pi/omp accepting *path*-kind refs (omp has
no `--session`; commented in-code). Session refs come **from hooks only** — the scraper
never produces identity (`events.rs:70-88`); refs are validated (id ≤512 chars, no
control chars; paths absolute, ≤4096 — `agent_resume.rs:226-235`), passed as **argv data,
never shell text** (test `ids_are_data_not_shell_text`, `:567-583`), deduped so one
session never resumes into two panes (`persist/restore.rs:736-751`), and injected on
restore (default-on: `[session] resume_agents_on_restore`, `config/model.rs:249-255`) or
agent-exit respawn. The `session_start_source` vocabulary —
`startup | resume | clear | compact | new | fork` (`agent_resume.rs:72-79`) — names *why*
a session id changed, and gates whether a same-owner replacement is honored (HD1-1).

**Gap in jido_radclaw** (verified 2026-07-06 at HEAD): Forge runners re-send accumulated
prompts — `claude -p` fresh per iteration (`runners/claude_code.ex:62-73`), codex
explicitly `--ephemeral` (`runners/codex.ex:93-104`); `apply_input/3` on both writes an
inert response file no live CLI reads; the executor-seam `ForgeExecutor` is single-shot
by design (`forge_executor.ex:175-193`). MC1-1's gap statement stands verbatim.

**Why it matters**: the MC-FIRST-WAVE build needs exactly this table pre-filled — the
per-vendor flag divergences (flag vs `=` vs subcommand vs `--thread` vs path-kind vs
renamed binary) are the fiddly third of the work, and herdr maintains it across 14
vendors in one 80-line match. The `session_start_source` enum is the ready-made answer to
"why did the session id change" — needed the moment we pin CLI sessions, and absent from
multica. Keep multica's halves herdr lacks: the poisoned-session taxonomy and
clear-id-then-retry-fresh (herdr's failure story is thinner — a failed resume spawn just
skips the pane).

### HD2-3. Detection manifests as versioned, distributable data

**Recommendation**: BORROW-PATTERN, parked. **Named trigger**: the CC1-1 soft-block
rubric build (first-wave item) — or any future scrape-class detector (termic TM2-1's
interactive-harness trigger).

**Where in herdr**: the rules are **data with a schema, caps, versioning, and a
distribution channel**, not code. Schema: per-agent TOML, `deny_unknown_fields`, rules
carrying `state`, `priority`, one of 14 named screen regions (incl. parameterized
`bottom_lines(N)`), recursive `all/any/not` gates over `contains/regex/line_regex`
matchers (`detect/manifest.rs:138-198`); validation caps compiled in — 128 rules, gate
depth 8, 512 gates, 1024 matchers, 512 chars/matcher (`:263-268`); `skip_state_update`
rules are *forced* to `state="unknown"` with no visible flags (`:908-921`); every bundled
manifest is parse+validate tested. Versioning: per-manifest `version` +
`min_engine_version` (claude.toml:1-5); resolution is local-override > remote-cache >
bundled (`manifest.rs:566-663`), a 30-minute background updater fetches a catalog from
herdr.dev (256KB cap, atomic tmp+fsync+rename writes, downgrade rejected,
same-version-content-drift rejected, engine-gate enforced — `manifest_update.rs`), and
**nothing is signed** — integrity is TLS + monotonicity + validation. The authoring
doctrine lives in their AGENTS.md: *"Screen detection is evidence-based"* — capture the
exact evidence with a built-in tool (`herdr agent read <pane> --source detection`),
encode invariant vs alternative chrome as explicit AND/OR gates, never match the
user-scrollable viewport.

**Gap in jido_radclaw** (verified 2026-07-06): CC1-1's rubric is prose in an exploration
doc; our closest rules-as-data precedents (skills YAML, the verify `checks:` registry)
have no cap/version/fixture discipline for *classifier* rules.

**Why it matters**: when the soft-block rubric ships it should ship in this shape —
bounded, versioned, fixture-tested data (MX3-1's calibration corpus + herdr's capture
tool + evidence doctrine are one method) — so tuning it never means redeploying code. The
half to deliberately skip: the remote update channel. Ours ships in-repo behind
precommit, because unsigned remotely-updated *classifier rules that feed an attention
surface* are a tampering vector our threat model actually cares about — herdr accepts
that residual; we shouldn't.

### HD2-4. Worktree naming + teardown datapoints (FOLD-IN → FLOW §4 templates, SYNTHESIS §5.3 law)

**Recommendation**: FOLD-IN — three deltas and one negative onto the
traycer/emdash/orca worktree references.

**Where in herdr**: generated names are `worktree/{adjective}-{noun}-{4-hex}` from two
8-word lists (`worktree.rs:21-32` — brave/calm/clear/… × river/cloud/field/…);
branch→path sanitization lowercases alphanumerics, collapses everything else to single
dashes, trims, and falls back to `"worktree"` (`:34-54`); checkouts land under
`~/.herdr/worktrees/{repo}/{slug}` (`:154-156`). Creation **checks out an existing local
branch instead of failing** (`show-ref` probe then plain `worktree add`, `:294-306` —
their #729). Teardown: modal confirm; first attempt runs *without* `--force` and parses
git's dirty refusal into a second, explicit force confirmation (`app/worktrees.rs:948-958`);
the **branch is never deleted** (test `worktree.rs:741-758`); forced-remove leftover-dir
recovery deletes a stray checkout only after proving its `.git` gitdir points into the
repo's own worktrees admin dir (`:328-402`). All git work runs off the event loop with
the API responder moved into the deferred op, and concurrent ops on one checkout are
rejected (`app/api/worktrees/deferred.rs:14-212` — their #657/#662/#686). **No
post-create setup steps exist at all** (verified by grep — no env copy, no bootstrap, no
preservePatterns).

**Gap in jido_radclaw** (verified 2026-07-06): unchanged — no worktree code (the only
`worktree` token in `lib/` is the `git config --worktree` scope flag,
`security/shell_command/git.ex:150`); EM2-3 (gate `git worktree` mutations) remains
unshipped — no `:git_worktree` effect kind exists (`shell_command.ex:163-173`).

**Why it matters / what folds where**: (a) the generated-name shape independently
validates FLOW §4's two-template design (`{source}/{slug}` + collision counter — their
4-hex suffix is our `-{n}`), and the sanitize-then-fallback path rule is the detail our
directory template needs. (b) **Branch survives teardown** is a named middle point the
SYNTHESIS §5.3 spectrum lacked: recoverability by default without blocking removal
(between muxara's hard block and orca's delete-both). (c) The gitdir-provenance check
before deleting a leftover directory belongs in our records↔worktrees reconciliation
sweep. (d) The negative: zero provisioning — herdr contributes nothing to the setup half;
emdash/orca keep that whole. Prerequisite for all of it stays EM2-3.

### HD2-5. Managed vendor-config edits: surgical, marker-owned, user-preserving

**Recommendation**: BORROW-REFERENCE — a rider on CC2-2 (ManagedDoc for
`system_prompt.md`) and the contract for any future feature that installs our hooks into
a third-party tool's config.

**Where in herdr**: `config_edit.rs` edits four formats (JSON, TOML, YAML, raw script
files) under one ownership discipline: herdr identifies *its own* entries by **exact
command-string match across every variant it ever wrote** (current + legacy + per-OS,
`:368-392`), removes surgically (an event key is deleted only when its array empties,
`:203-243`), and **refuses rather than clobbers** when the target file isn't the expected
shape (typed error on non-object JSON, `:19-32`). TOML ownership is a delimited block
(`# >>> herdr kimi integration` … `# <<<`); YAML ownership is the plugin name; installed
scripts carry `HERDR_INTEGRATION_ID`/`_VERSION` marker lines driving
Current/Outdated/NotInstalled status (`registry.rs:371-417`). User co-tenants are
preserved and *tested* (seeded user hooks survive reinstall, `tests.rs:862-900`).
Installs are strictly opt-in (CLI/API/Settings — no auto-install). The wart, documented
in the script header itself: no checksums, so user edits to the managed *script body*
are silently overwritten — "add custom hooks beside this file instead of editing it."

**Gap in jido_radclaw** (verified 2026-07-06): CC2-2 unshipped (our `system_prompt.md`
guard is byte-equality — stricter and right for a file we wholly own, wrong for co-owned
files); we edit no third-party configs today, but the MCP `.mcp.json` story and any
future editor/CLI integration will.

**Why it matters**: this is CC2-2's managed-block idea proven across 4 formats × 14
agents, with the two rules that make co-ownership safe — exact-marker ownership and
refuse-not-clobber — plus the honest documentation-as-mitigation for the unguarded body.

---

## Tier 3 — garnish and datapoints

### HD3-1. The single-slot render lane (coalesce-to-latest per subscriber)

**Recommendation**: BORROW-PATTERN (small). Per client, two lanes: a reliable unbounded
control queue (shutdown/notify/clipboard — never dropped) and a **one-slot droppable
render lane** — "Capacity is one so slow clients cannot build lag"
(`server/client_transport.rs:45-52`); on full, the frame is dropped and the client marked
pending; when the writer drains, the server re-renders *newest* state for that client
(`headless.rs:3565-3591`, `client_transport.rs:576-601`). Control always drains before
render. One slow client loses intermediate frames, never stalls the server or peers, and
always converges to latest. For us: the shape for any hot fan-out where only the newest
state matters — the slice-8 terminal broker's per-subscriber buffer, or a
high-frequency dashboard Channel push — as against our durable feeds, where every event
matters and `afterSeq` catch-up (TC1-1) is the answer. Knowing which of the two regimes a
surface is in *is* the design decision; herdr names the live-surface half.

### HD3-2. The socket API + published agent skill — the "agents can orchestrate" posture

**Recommendation**: datapoint for the standing ACP TRACK (emdash EM1-4) + a §4.4
negative reference. herdr's answer to agents-drive-the-cockpit is not a protocol: a
70-method newline-JSON socket API (`api/schema.rs:46-205`) plus a **published skill**
(`SKILL.md`, installable via `npx skills add`) that teaches any agent the CLI — including
a self-check (`HERDR_ENV=1` or stop) and **wait-verbs** (`pane.wait_for_output`,
`events.wait`, `events.subscribe`) so agents wait on each other's state instead of
polling. Two takes: (a) skill-as-integration-surface is the near-free half of "should
third parties drive us" — we already serve MCP; publishing a skill that teaches non-MCP
agents our surface costs a markdown file (weigh at the ACP TRACK's trigger, not before).
(b) The trust posture is the negative half: 0600 socket, no tokens, no per-client or
per-plugin capability model — any local process, including every pane's agent, can call
all 70 methods (`worktree.remove` included). On a personal machine that's a coherent
stance; for argus §4.4 it joins CC2-4 as the contrast to t3code TC1-2's scoped
credentials.

---

## Skip / Already Covered

- **S-1. Edit-step-output-and-resume — verified absent (sweep subject 25).** Herdr owns
  no gate, approval, or pending-decision object (greps for approval/gate/pending machinery
  land only on detection-manifest matcher "gates" and unix file modes). Every human→agent
  channel is a pass-through PTY byte write: focused-pane keystrokes, `agent send`,
  `pane send_text|send_keys|send_input`, and plugins bottoming out in the same
  (`app/api/agents.rs:182-195`, `app/api/panes.rs:1408-1550`). The only confirmation
  modals guard herdr's own destructive ops (worktree remove, pane-group close). The argus
  §5 novelty survives the field's most terminal-native subject; cmux closed as sweep
  subject 26 the same day — decision-only Feed cards, no edit affordance
  ([cmux S-1](../cmux/FEATURES-WORTH-BORROWING.md)), completing the family sweep.
- **S-2. Terminal emulation/rendering stack** (vendored ghostty-vt, kitty graphics, OSC
  52) — SKIP here; this is ghostty_ex GX1-1's slot, and the seams pass re-confirmed that
  adoption hasn't happened (not in `mix.exs`). If GX1-1 ships, herdr is a second
  reference for render-side plumbing; nothing more.
- **S-3. Exact-match protocol versioning + forced restarts** — SKIP as negative
  reference. Any client/server version mismatch is rejected in both directions
  (`wire.rs:914-932`), backward compat "not yet supported", and persisted snapshots from
  a *newer* version are silently ignored (`persist/io.rs:128-137`). This is the
  unversioned-skew pole of the contract spectrum (traycer per-method majors ↔ emdash
  agreedMinor ↔ termic nothing ↔ herdr exact-match-or-die); argus's rolling-upgrade
  cluster takes traycer TR1-1/TR1-2 + PD1-1 as the positive shape.
- **S-4. Socket trust posture** — SKIP as §4.4 negative datapoint (detailed in HD3-2):
  filesystem perms are the entire local authz model; remote security is wholly delegated
  to SSH. Coherent for one operator on one machine; the inverse of argus's authed-surface
  requirement. (One positive nugget worth keeping: remote binary auto-provisioning
  sha256-verifies release downloads, `remote/unix.rs:1400-1520`.)
- **S-5. Prose soft-block detection — verified absent, which is the point.** Every
  blocked rule is fixed substring/regex over UI chrome; an agent that ends its turn by
  asking a free-form prose question classifies **Idle/"done"**, not Blocked (reader
  confirmed: no turn-ended-with-a-question detector). The field's most engineered
  classifier still can't see CC1-1's class of block — the strongest argument yet that the
  soft-block rubric layer is real and must sit *above* state detection, ours included.
- **S-6. JSON persistence + live-handoff FD transfer** — SKIP, contrast. The persistence
  layer is the best of the desktop set (atomic writes, schema version, opt-in history) and
  still fails static-forward (S-3); the SCM_RIGHTS live handoff (≤64 panes, Unix-only,
  `server/handoff.rs:20-42`) is genuinely impressive engineering that exists *because*
  all live state is process-held — the moat evidence reading: our runs survive restarts
  via durable state + reclaim, no FD heroics required. Their honest framing agrees:
  panes die with the server short of handoff.
- **S-7. Cockpit-native UI surface** (mouse-first TUI, themes, keybindings, copy mode,
  image paste, per-pane zoom) — SKIP: form-factor machinery for a product we aren't
  building; the agents-panel *semantics* were taken in HD1-3.

## Open questions

- **OQ-1**: In argus's per-agent status contract, is "done" a projection over
  `(state, seen_at_seq)` (herdr's shape, HD1-3) or a fifth enum value? herdr + its
  SKILL.md argue: keep the internal enum closed, publish the folded five-value view at
  the API boundary so clients never re-derive it differently. Lean projection-internally +
  folded-externally; decide when slice 1's read-model lands (same moment as EM2-1's fold
  and muxara OQ-1/OQ-2).
- **OQ-2**: If a scrape-class consumer ever exists on our side (termic TM2-1's
  interactive-harness trigger), which engine shape — herdr's manifest-data engine
  (schema'd rules, caps, fixtures, remote-updatable) or termic's fusion-ladder code
  (signals suppress heuristics)? herdr's scales to 18 agents and tunes without
  redeploying; termic's is simpler at N≤2 and captures signal-vs-heuristic precedence
  herdr expresses only as rule priorities. Record: manifest-data for breadth, ladder for
  depth; decide at the trigger, and note the engines are composable (a manifest engine
  *below* a sender-busy suppression rule).

## Cross-references and dependencies

```
argus slice 1 (attention loop)     ← HD1-1 (authority tiers + fences; the MX1-1 multi-source half)
                                   ← HD1-2 (damp-only-the-clear; re-verify-at-delivery → FLOW §12)
                                   ← HD1-3 (seen-fold "done"; identity-bound sort; muxara OQ-2 datapoint)
argus slice 8 (operator terminal)  ← HD2-1 (banked PTY-broker reference; auth/skew inverted per TC1-2/PD1-1)
queued MC-FIRST-WAVE resume build  ← HD2-2 (14-vendor argv table + session_start_source vocabulary)
CC1-1 build (first wave)           ← HD2-3 (rubric-as-versioned-data; skip the remote channel)
argus FLOW §4/§5 + EM2-3           ← HD2-4 (naming deltas; branch-survives-teardown; gitdir-provenance check)
CC2-2 (ManagedDoc)                 ← HD2-5 (marker-owned surgical config edits)
ACP TRACK (EM1-4)                  ← HD3-2 (skill-as-integration-surface; wait-verbs; negative trust half)
slice-8 / hot fan-outs             ← HD3-1 (single-slot latest-wins lane vs TC1-1 durable catch-up)
```

No new do-today items of herdr's own: the adjacent do-now work is already queued
elsewhere (CC1-2a + the Forge needs-input reply loop at CH-FIRST-WAVE item 1; EM2-3;
TM1-1), and this dig's our-side finds fold into those moments — the `AgentView`
done≡idle split lands with EM2-1's fold (HD1-3), and the seams pass's premise
refinements are recorded there (cron auto-disable *is* now visible in `/cron`, pull-only;
`Forge.apply_input/2` shipped but `:needs_input` still reaches no operator surface).
Collision notes: read HD1-1/1-2/1-3 together with MX1-1 + CC1-2 + EM2-1 at the slice-1
design moment — they are one stack, not four documents; HD2-2 must not fork from the
MC-FIRST-WAVE item (it's a rider, not a second build); TM1-1 gains a consumer datapoint —
herdr passively consumes OSC 0/2 titles and OSC 9;4 progress with **no** `TERM_PROGRAM`
claim (`pane.rs:50-59`; manifests' `osc_title`/`osc_progress` regions), so an emitting
jidoclaw REPL would be classifiable by herdr-class multiplexers as-is (per code read; not
executed).

## Bottom line

1. **The arbitration contract is the missing multi-source half of the attention stack —
   and its history is the lesson** (HD1-1): tier reporter authority explicitly, fence
   staleness mechanically (monotonic seqs, generation re-anchor, process-exit outranks
   everything), and note that the field's best scraper *retreated* from hook-borne state
   for the seven biggest CLIs because vendor hook events are noisy proxies — the
   strongest outside validation of our events-over-proxies moat, and the pre-written
   answer for slice 6's CLI adapters.
2. **MX1-1 is now buildable with numbers** (HD1-2, HD1-3): damp only the clear-to-idle
   transition (3×/700ms, evidence bypasses), re-verify predicates at notification
   delivery, blocked pierces DND, "done" is `(idle, ¬seen)` as a projection, and sorting
   is safe only when selection binds to identity — herdr supplies the existence proof
   while defaulting to the settled stable order.
3. **Two references banked for named later moments**: the PTY-broker mechanics for slice
   8's operator terminal (HD2-1 — keep reattach-as-redraw and the single-slot lane;
   invert the auth and skew choices), and the 14-vendor resume argv table riding the
   already-queued MC1-1 build (HD2-2).
4. **The sweep holds and CC1-1 gets sharper**: subject 25 verified empty (all input
   channels are pass-through keystrokes; no gate object), and the field's most engineered
   classifier still cannot see a prose soft-block (S-5) — argus §5 stays novel, CC1-1
   stays unique, and the AGPL patterns-only discipline held throughout.
