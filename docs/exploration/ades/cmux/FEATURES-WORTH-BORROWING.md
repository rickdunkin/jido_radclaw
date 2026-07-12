# Features Worth Borrowing from cmux

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-06**, the
[ades scan](../README.md)'s category-4 / early-read item 8 **targeted dig** (queued
2026-07-06, fired the same day on operator request — both flagged halves at once).
Source: `~/workspace/research/multiplexers/cmux` (manaflow-ai/cmux, Manaflow, Inc.).
Self-description: *"A Ghostty-based macOS terminal with vertical tabs and notifications
for AI coding agents."* Pinned commits: cmux @ `48e69cbb05` (2026-07-06, unmoved since
the quick scan), jido_radclaw @ `85cbe9f2` (2026-07-06; the working tree additionally
carries the same-day herdr/t3code corpus updates, not yet committed — our-side refs are
working-tree-accurate). Cites are firsthand reads of both trees this session (four
parallel subject readers + one seams pass), accurate to within a few lines. **Read, not
executed** — nothing was built or run; runtime claims are per-source.

Shape: the largest codebase in either corpus family — 3,916 Swift files (excluding
vendored ghostty), one 1.5MB hand-parsed CLI file, plus a Go remote daemon
(`daemon/remote/`, cmuxd-remote), a Go transcript-sync CLI (`vault/`), a **separate
experimental Rust TUI multiplexer** (`mux/`, its own product at v0.1.0), TS webviews /
Cloudflare workers, and a 64MB `web/` site. Maturity: 5,749 commits / 131 non-merge
authors but heavily core-concentrated (Lawrence Chen ≈48%, top three people ≈80%),
CHANGELOG v0.64.17 (2026-06-23) with daily commits at HEAD (2026-07-06), 2,080 test
files, ~21 in-repo Claude-Code-format skills, and a `reports.md` showing 20-agent
workflow-driven flaky-test audits — development here is heavily agent-driven. License:
**GPL-3.0-or-later + commercial dual** (history pinned: AGPL adopted 2026-02-14 → dual
AGPL+commercial 2026-03-23 → relicensed to GPL 2026-03-30, #2364). The termic/herdr
discipline applies: **patterns only, never lift code**.

**Targeted dig, by design** (~3.9k Swift files; the GUI-cockpit quadrant was already
mined four subjects deep): the four areas read are (1) `cmux claude-teams` (the scan's
first flagged target), (2) the `ios/` companion (the second), (3) the agent state /
notification engine (the observation-3 rider), and (4) the control surfaces + the
standing sweep (subject 26). NOT read: the AppKit/rendering mass, webviews/workers
internals, the Rust `mux` beyond its spec, the web app. Companion docs:
[../README.md](../README.md) (category 4);
[../herdr/FEATURES-WORTH-BORROWING.md](../herdr/FEATURES-WORTH-BORROWING.md) (HD1-1
arbitration — this dig supplies its opposite pole; HD2-2 resume table; HD2-5 managed
config edits; HD3-2 skill-surface); [../t3code/FEATURES-WORTH-BORROWING.md](../t3code/FEATURES-WORTH-BORROWING.md)
(TC1-2 positive auth; TC1-3 app-server stack; TC2-6 mobile evidence — the same trigger
this dig's iOS half banks against); [../muxara/FEATURES-WORTH-BORROWING.md](../muxara/FEATURES-WORTH-BORROWING.md)
(MX1-1); [../claude-command-center/FEATURES-WORTH-BORROWING.md](../claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-1/CC1-2); [../emdash/FEATURES-WORTH-BORROWING.md](../emdash/FEATURES-WORTH-BORROWING.md)
(EM1-3/EM2-1); [../termic/FEATURES-WORTH-BORROWING.md](../termic/FEATURES-WORTH-BORROWING.md)
(TM1-1 — the OSC emit/claim trick claude-teams inverts at the multiplexer level);
[../../pms/multica/FEATURES-WORTH-BORROWING.md](../../pms/multica/FEATURES-WORTH-BORROWING.md)
(MC1-1); [argus OVERVIEW](../../argus/OVERVIEW.md) / [FLOW](../../argus/FLOW.md) /
[SYNTHESIS](../../argus/SYNTHESIS.md) (the consumers — §2.6 client form factor, §4.4
auth, FLOW §12 attention, SYNTHESIS §5.1/§5.6). Threat model as usual (personal,
tailnet-only): LLM-misbehavior containment and leakage hygiene over external-attacker
hardening.

## Determination (TL;DR)

**Both flagged targets deliver — and both resolve *against* building what cmux built,
which is exactly the evidence the dig was fired to collect.** (1) The field's only
Claude Code teammate-mode driving reference turns out to be a **tmux impersonation**:
cmux fabricates `TMUX`/`TMUX_PANE`/`TERM`, sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
installs a fake `tmux` shim first on PATH (`exec cmux __tmux-compat "$@"`), and
translates Claude's own tmux vocabulary into native splits over its socket API — termic
TM1-1's claim-a-capability trick, one level up. It works, and it rests on **nine
enumerated load-bearing assumptions about Anthropic internals**; that assumption ledger
(plus the trust-gate opt-in mechanics and the restore-argv sanitizer around it) is the
borrow — the reference that prices vendor-internal driving for argus slice 6 (CM1-1,
CM2-3). (2) The iOS companion demolishes the scan's "real if thin" framing: the 26-file
shell is a veneer over **~60k LOC of iOS-specific Swift in 15 packages + ~16k shared,
four cloud services (Stack Auth ×2 projects, the cmux.com registry/APNs API, a
Cloudflare presence worker, APNs), Tailscale as the mandatory data plane, a Mac-side
mint subsystem, and its own release pipeline** — the decisive native-vs-PWA datapoint,
banked for the OVERVIEW §2.6 revisit and strongly vindicating the PWA choice (CM2-1);
what transfers regardless of form factor are two delivery rules the FLOW §12 merged set
lacked (presence-gated cross-device forwarding; cross-device ack-sync with an absolute
self-healing badge — CM1-4) and the no-secret, never-expiring pairing-QR posture
(CM2-2). (3) The riders over-delivered: the state engine resolves observation 3's cmux
clause with the corpus's cleanest symmetry — **cmux made hooks the state authority and
deleted its screen-scraping heuristics; herdr made the screen the authority and
stripped its state hooks** — same staleness disease, opposite cures, both converging on
mechanical fences, which are the transferable layer (CM1-2); and the Feed is the
field's most complete *decision-only* approval surface: a typed `(source, event)`
classifier registry (never string-matched), three actionable kinds, and a
soft-wait-with-timeout-fall-through polarity our slice-6 vendor bridges should study
(CM1-3). (4) The standing sweep closes at **subject 26 — the family's last open slot:
execution-layer edit-and-resume verified absent**. Decisions are mode/option picks; the
plan card is read-only; the two free-text paths are an ExitPlan feedback string riding
a mode decision (annotate-then-continue, below the field's three plan-layer
promote-the-edit precedents) and a reply composer that is keystroke injection (S-1).
Argus §5's novelty survives the whole 27-subject sweep.

| Part of cmux | As a dependency? | What to take |
| --- | --- | --- |
| claude-teams driving (tmux shim + compat table + sanitizer) | No — GPL, macOS binary | The driving contract + the 9-assumption brittleness ledger (CM1-1); restore sanitizer (CM2-3) |
| Agent state engine (hooks + fences, 17-agent catalog) | No | The hook-authority pole + staleness fences for HD1-1's contract (CM1-2); install discipline (CM2-4) |
| Feed / approval cards + classifier | No | The typed classifier registry, three actionable kinds, soft-wait semantics (CM1-3) |
| Notification store + phone push | No | Presence-gated forwarding, cross-device ack sync, absolute badge (CM1-4) |
| iOS companion + pairing + transport | No | The cost bill as §2.6 evidence (CM2-1); the no-secret QR / route-auth posture (CM2-2) |
| Remote daemon + relay + `cmux remotes` | No | Three trust nuggets (sha256 provisioning, HMAC relay, lease-gated WS) as garnish (CM3-3) |
| Socket API + 21 shipped skills | No | ACP-TRACK datapoint: skill-as-integration-surface at product scale (CM3-1); trust posture is a negative reference (S-3) |
| `events.stream` after-seq feed | No | Convergence datapoint for TC1-1 (CM3-2) |
| Scriptable in-app browser, vault(s), Rust `mux`, ghostty stack | No | Nothing — skips with named reasons (S-2, S-5, S-6, S-7) |

## Why not adopt cmux as a dependency

1. **GPL-3.0-or-later decides first** (dual-commercial aside) — the termic/herdr
   discipline: nothing here may be lifted as code, ever. Every verdict below is
   pattern/reference/rubric.
2. **It's a native macOS product, not a library**: an AppKit app + a 1.5MB single-file
   CLI, socket-coupled to the running GUI. There is no seam to embed and no headless
   mode; even its own remote story uploads a companion binary and relays back to the
   Mac app.
3. **Wrong substrate on every orchestration axis we own**: no durable events (an
   in-memory 2000-item ring + JSONL audit mirror), no durable gate (the Feed's pending
   decisions are semaphores that expire when the agent's PID dies — S-1), no leases, no
   multi-node story, no auth beyond filesystem perms by default (S-3). Its excellence —
   live per-agent state over a real terminal, a polished attention surface, a phone
   mirror — is concentrated exactly where argus is greenfield, which is why this is a
   reference dig, not an adoption question.

## How to read this document

Standard corpus vocabulary (BORROW-PATTERN / BORROW-REFERENCE / BORROW-RUBRIC /
FOLD-IN / TRACK / ALREADY-COVERED / SKIP; no new axes needed). Initial inventory — no
Status lines. IDs are `CM<tier>-<seq>`; `S-n` skips; `OQ-n` open questions. Tiers
scoped to this doc's consumers: **Tier 1** = lands in an active argus seam (slice 6's
CLI-adapter reading list — the dig's own named trigger — slice 1's attention build,
FLOW §12); **Tier 2** = banks against a named trigger or folds into an already-queued
build (the §2.6 client revisit, §4.4, MC1-1); **Tier 3** = datapoints and garnish.
Per-entry fields as usual: Where in cmux / What / Gap in jido_radclaw (verified
2026-07-06) / Why it matters / Adoption sketch.

---

## Tier 1 — lands in an active argus seam

### CM1-1. The claude-teams driving contract: tmux impersonation + the nine-assumption ledger

**Recommendation**: BORROW-REFERENCE — joins SYNTHESIS §5.6's slice-6 CLI-adapter
reading list as the field's only Claude Code **teammate-mode** driving reference, and
as the corpus's worked example of what driving a vendor's *undocumented internals*
actually costs.

**Where in cmux**: dispatch `CLI/cmux.swift:3350-3357` → `runClaudeTeams`
(`:19175-19240`). The mechanism, end to end: (a) resolve the **real** `claude` —
skipping cmux's own wrapper (marker-string sniff of the first 512 bytes,
`CLI/CMUXCLI+ExecutableResolution.swift:25-30`), command shims (`:32-68`), and bundled
copies, with a PATH+well-known-dirs fallback (`:248-284`); (b) fabricate a tmux world:
`TMUX=/tmp/cmux-claude-teams/<ws>,<win>,<pane>`, `TMUX_PANE=%<n>`,
`TERM=screen-256color`, `TERM_PROGRAM` unset (`configureTmuxCompatEnvironment`,
`CLI/cmux.swift:18978-19039`); (c) write an idempotent shim
`~/.cmuxterm/claude-teams-bin/tmux` — verbatim
`exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"` — first on PATH
(`:19146-19156`, atomic re-write only on content change `:20790-20823`); (d) set
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, prepend `--teammate-mode auto`, and inject an
`--append-system-prompt` nudge telling the lead to spawn **named** teammates (only
named teammates get panes; a nameless Task is an in-process subagent —
`CLI/CMUXCLI+ExecutableResolution.swift:191-215`); (e) `execv` the real claude. Every
`tmux …` call Claude makes re-enters cmux as `__tmux-compat` and is translated to v2
socket RPC: `split-window`→`surface.split`, `select-layout main-vertical`→equalize +
stack-down state, `send-keys`→`surface.send_text`, `respawn-pane`→`surface.respawn`
wrapped in `/bin/sh -c` (Ghostty's `exec -l` can't exec a `cd …` compound —
`CLI/CMUXCLI+TmuxCompatSupport.swift:68-99`), `tmux -V`→`"tmux 3.4"`; unknown commands
**throw** (`CLI/cmux.swift:22180`; full table `:21579-22181`). The Python contract
tests pin the exact sequence real Claude emits
(`tests/test_cli_claude_teams_tmux_sequence.py`, `…_main_vertical.py` — 8 tests total).
**Trust-gate opt-in**: `CLAUDE_CODE_SANDBOXED=1` (short-circuits Claude's "trust this
folder?" prompt, which deadlocks unattended teammates) is granted only when *this*
invocation carries a real `--dangerously-skip-permissions` option (parsed
positionally, not substring-matched — `AgentLaunchSanitizer.swift:238-260`), is
re-supplied to teammate respawns from an env marker rather than re-derived from command
text, is **unset** when not opted in so it never leaks across launches, and is
deliberately **not persisted** into restore — a restored teammate falls back to the
trust prompt (`CLI/CMUXCLI+TmuxCompatSupport.swift:121-153`). The **remote variant**
(Go daemon, `daemon/remote/cmd/cmuxd-remote/agent_launch.go:24-68`) is a reduced
reimplementation: no system-prompt nudge, no wrapper skipping, and **no trust-gate
handling at all** — the exact deadlock class the Swift path fixes, live over SSH.

**The nine load-bearing assumptions** (each a break point if Anthropic moves):
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` enables teams; `--teammate-mode auto` parses;
teams detects tmux via `TMUX`/`TMUX_PANE` and shells to a PATH `tmux`; the teammate
tmux vocabulary is exactly the pinned command set; the 2.1.183 respawn shape
(`split-window -- cat` then `respawn-pane -k -- "cd … && env … claude …"`);
`CLAUDE_CODE_SANDBOXED` short-circuits the trust gate; `--tmux <text>` carries the
initial prompt (restore correctness depends on it); `--append-system-prompt` exists and
the Task tool panes only named teammates; `tmux -V` probing accepts `3.4`. No runtime
version check guards any of these.

**Gap in jido_radclaw** (verified 2026-07-06): our claude runner is cold
`claude -p … --output-format stream-json` per iteration with no session, no resume, no
teams flag (`lib/jido_claw/forge/runners/claude_code.ex:62-73`); codex is
`codex exec --ephemeral` (`lib/jido_claw/forge/runners/codex.ex:112-134`); the executor
seam refuses `{:forge, :codex | :claude_code}` at dispatch until PR-2
(`lib/jido_claw/skills/steps/agent_runner.ex:123-136`); no teams/teammate concept
exists anywhere in `lib/` (grep-clean). SYNTHESIS §5.6's reading list (SY1-1, MC1-1,
TC1-3, HD2-2 + the orca gotchas) has no teams entry until this one.

**Why it matters**: two readings, both load-bearing. Narrow: if slice 6 (or a
post-PR-2 executor) ever drives Claude Code teams, this is the only field reference —
the mechanism, the trust-gate shape, and the contract tests to imitate. Broad: it
prices the **vendor-internal driving strategy** against the structured-surface strategy
TC1-3 documented (app-server JSON-RPC, agent SDK, ACP). cmux pays nine unguarded
assumptions plus a permanently-behind Go reimplementation to drive a feature with no
API; t3code pays a pinned protocol spec. When our CLI adapters face a vendor feature
with no structured surface, this entry is the honest cost sheet — and the shim trick
itself (claim the capability the CLI probes for; receive its native protocol) is
termic TM1-1's listening trick inverted into *driving*, worth remembering as a shape.

**Adoption sketch**: none today — this banks. At slice 6 / executor PR-2+: prefer
structured surfaces (TC1-3) wherever one exists; if teams-driving is wanted, write the
assumption ledger into the adapter doc first, pin the vendor interaction with
cmux-style contract tests (their Python mock-socket suite is the method to copy), gate
any trust-bypass on an explicit per-launch operator opt-in that never persists into
restore (their exact polarity), and expect to re-verify the ledger on every vendor
release.

### CM1-2. Hook-authority state + mechanical staleness fences — the opposite pole of herdr's retreat

**Recommendation**: BORROW-PATTERN (the fences) + the field lesson — read together with
herdr HD1-1 at slice 1's read-model design and again at slice 6's adapter design; the
two digs now supply both poles of the same contract.

**Where in cmux**: three state subsystems share one authority rule — **hooks own
state**. The iOS-registry authority (`ChatAgentState`
{`idle`,`working(since)`,`needsInput(since)`,`ended`},
`Packages/Shared/CmuxAgentChat/.../ChatAgentState.swift:8-24`) transitions on hook
events only (`AgentChatSessionRegistry+Lifecycle.swift:70-99`; the spec's rule: "State
transitions come from exactly one channel: agent hook events",
`docs/agent-session-tracking-spec.md:174-187`) — and the redesign **deleted** the
title/mtime scraping layer outright ("Never from terminal-title string matching. Never
from newest-file-by-mtime scans", `:19-21`). Non-hook sources are constitutionally
weaker: process observation "only ADDS presence and bindings; it never downgrades
hook-derived state" (`AgentChatSessionRegistry.swift:106-107`, entering at `.idle`);
transcript corroboration may only *correct* a stuck `working`→`idle`, never invent a
state (`:319-320`); scraper-observed **process exit** is the one thing that outranks
hooks (→`.ended`), and even it is **pid-generation fenced** — a predecessor pid's exit
can't kill a resumed session, and a dead launcher re-binds to the surviving real agent
instead of ending it (`:183-212`, watcher re-arm `:73-97`). The fences that make hook
authority survivable: per-surface **session+turn generation gating** (every visible
mutation checks `isCurrent(sessionId, workspaceId, surfaceId, turnId)`; stale hooks are
dropped with breadcrumbs — `CLI/cmux.swift:23942-23986`, `:1275-1327`); **refcounted
attention overlays** that clear themselves only if still holding their own value ("a
real running/idle/needs-input update from the agent always wins",
`FeedCoordinator.swift:425-461`); **turn-boundary vs session-end** typing per vendor
(agents that re-emit `SessionEnd` every turn get `sessionEndIsTurnBoundary` so restore
records survive — `CMUXCLI+AgentHookDefinitions.swift:25-41`); **nested-agent
suppression** (an agent spawned inside another agent's tree can't flip the pane state,
`CLI/cmux.swift:26426-26475`); and misroute-refusal (a Claude hook that can't uniquely
resolve its workspace **no-ops** rather than stamping the focused tab —
`CLI/CMUXCLI+ClaudeHookWorkspaceRouting.swift:12-44`). Notably **no damping**: state
raises instantly in every direction; the only time-shaping is UI render coalescing
(50ms) and push suppression. Needs-input detection is likewise hook-borne: an async
`PreToolUse` hook flags `AskUserQuestion`/`ExitPlanMode`, the *only* signal under
`--dangerously-skip-permissions` where Claude fires neither PermissionRequest nor
Notification (`CLI/cmux.swift:23692-23788`). Zero-config floor: process-table watching
plus **open-FD anchoring** (codex session identity read from the process's open
rollout-JSONL fd via libproc — pid-anchored, never newest-file-by-mtime;
`AgentChatSessionRegistry+ObserveScan.swift:455-484`); a hook-less agent is *present*
but the Mac sidebar shows nothing for it.

**What — the symmetry with herdr** (the dig's calibration question, answered): herdr,
holding the field's best scraper, **retreated from hook-borne state** to
session-identity-only for the seven biggest CLIs (HD1-1); cmux, holding the field's
widest hook catalog (17 agents + Claude/codex wrappers), **retreated from scraping**
and reinforced hooks with fences. Same disease — stale reporters lying about live state
(cmux's changelog scars: "stale Claude notification sidebar status" #6473/#6609, stop
teardown races #1954, stale status from missing hooks #1306) — opposite cures, and the
overlap is the transferable layer: **both ended up with per-reporter monotonic/
generation fencing, engine-observed process exit outranking every report, and
viewer/replay contexts barred from publishing live state.**

**Gap in jido_radclaw** (verified 2026-07-06, via the herdr seams pass at the same
tree): `AgentView.derive_status/4` is single-source with no authority model and no
fences, and collapses completed to `:idle` (`lib/jido_claw/web/live/agent_view.ex:28-31`);
no damping or generation logic exists in any status pipeline. Slice 1 will fold ≥3
reporters per agent; slice 6 adds hook-class relayed signals — exactly the two poles
these digs cover.

**Why it matters**: HD1-1 alone reads as "hooks lose"; cmux proves the other
engineering direction closes the same defects — so the real contract for slice 1/6 is
not "which source wins" but **fence mechanics as invariants**: per-source generations,
engine-observed facts outrank relays, correct-only corroboration, replay contexts can't
publish. Our substrate already has the durable half (event seqs, terminal statuses);
the fences are what our CLI adapters must add around vendor hook noise. cmux's
pid-generation exit fencing and turn-vs-session boundary typing are the two details
herdr's contract lacked.

**Adoption sketch**: fold into HD1-1's slice-1 sketch (authority as data, per-source
cursors, engine-facts clear advisory state): add cmux's two details — (a) fence
*turn*-scoped relays by `(session_generation, turn_id)`, not sequence alone, when
slice 6 relays vendor hook events; (b) type each vendor's session-end as
turn-boundary vs terminal in the adapter table (the `sessionEndIsTurnBoundary` bit) —
plus the misroute-refusal rule: an event that can't uniquely resolve its run/agent
no-ops loudly, never lands on the focused/most-recent one.

### CM1-3. The Feed: a typed hook-classifier registry + three actionable kinds + soft-wait semantics

**Recommendation**: BORROW-REFERENCE — for slice 6's "ask-rule bridges" (FLOW §13) and
the executor PR-2 approval bridge; the classifier's vendor-quirk table is the priced
version of what our adapters will need. One polarity decision recorded as OQ-1.

**Where in cmux**: hook events from every agent flow through **one classifier**
(`CLI/FeedEventClassifier.swift`, compiled into both CLI and tests): a **typed registry
keyed `(source, event)` — never raw string pattern-matching** (their #4985 scar: a
tool-*start* misclassified as an approval; `:14-19`). Semantic cases verbatim:
`approvalRequest, toolStart, toolStartMaybeApproval, toolEnd, preCompact, postCompact,
promptSubmit, subagentStart, response, subagentResponse, sessionStart, sessionEnd,
statusNotification, unknown` (`:47-84`); unknown events default to non-actionable
telemetry that never notifies (`:153-156`). Vendors with a dedicated approval event
(claude/codex/hermes) get their pre-tool events forced to telemetry; vendors with only
a pre-tool signal escalate to `PermissionRequest` **only for side-effecting tools**
(explicit tool-name set, source-scoped aliases — `:275-341`); codex approvals are
deliberately non-blocking in hook mode because codex's *own* auto-reviewer runs
downstream and a blocking card would pre-empt it (`docs/feed.md:132`) — codex's real
approvals arrive instead via the app-server bridge (`CLI/CodexTeamsApprovalBridge.swift`:
`item/commandExecution|fileChange|permissions/requestApproval` → feed card → human
decision → typed JSON-RPC reply `accept/acceptForSession/acceptWithExecpolicyAmendment/
applyNetworkPolicyAmendment/decline/cancel` with turn/session scope). **Three actionable
kinds** (`docs/feed.md:5-8`): PermissionRequest (Once/Always/All/Bypass/Deny),
ExitPlanMode (Ultraplan/Manual/Auto/Deny + optional feedback), AskUserQuestion
(option selection) — distinct notification categories, one collapsed `needsInput` at
the pane-state layer (exactly MX1-1's sub-type-at-the-feed, fold-at-the-state
composition). **Soft-wait semantics**: an actionable card parks the hook on a semaphore
for ≤120s; timeout returns `{}` and the agent **falls through to its own in-TUI
prompt** ("advisory, not blocking" — `docs/feed.md:136-140`,
`FeedCoordinator.swift:166-188`); a kqueue PID watcher expires cards the instant the
agent dies (`:72-90`); pending state is an in-memory 2000-ring with an append-only
JSONL audit — **not durable** (S-1).

**Gap in jido_radclaw** (verified 2026-07-06): our tool-approval gate is strictly
stronger on durability (run-less `AgentCase`, FOR-UPDATE fence, single-use `:consume` —
`lib/jido_claw/security/tool_approval.ex` + `orchestration/tool_approvals.ex`) but has
none of this classification layer: no per-vendor event semantics, no
side-effecting-only escalation, no sub-typed actionable kinds on the operator surfaces
(`/gates`, `/approvals` render one undifferentiated pending list). The slice-6 bridge
sketched at t3code TC1-3(b) — vendor `requestApproval` frames → `ToolApprovals.request/3`
→ `Cases.decide/4` — needs exactly this classifier knowledge to decide *what becomes a
case at all*.

**Why it matters**: (a) The typed-registry rule is our own doctrine (LoopGuard's
typed-classification-never-string-sniffing) independently re-derived at the hook
boundary, with the scar to prove it — adopt it as a review-checklist line for every
adapter. (b) The vendor-quirk table (dedicated-approval vendors vs escalate-only
vendors vs auto-reviewer conflicts) is exactly the fiddly third of slice 6's bridge
work, pre-priced across 18 vendors. (c) The soft-wait polarity is genuinely new to the
gate-defect ledger (pms observation 9): for an *interception* layered over a vendor's
own interactive loop, timeout-falls-through-to-the-native-prompt is graceful
degradation, not a hole — the operator's terminal still shows the vendor's ask.
Contrast bosun's timeout-means-proceed (wrong: silent grant) and our native gates
(fail-closed, right for gates with no fallback surface). Which polarity our slice-6
bridges take is OQ-1.

**Adoption sketch**: at the slice-6 bridge: (1) adapter events land in a typed
per-vendor `(source, event) → semantic` table (data, not conditionals — HD2-3's
manifest discipline applies); (2) only side-effecting semantics mint an `AgentCase`;
telemetry semantics ride the event feed; (3) sub-type the case kind
(permission/plan/question) end-to-end so `/approvals` and push notifications
differentiate — the MX1-1 composition, now twice-validated; (4) decide OQ-1 per
surface: intercepted vendor prompts may fall through to the vendor TUI on timeout,
native gates never do.

### CM1-4. Two cross-device delivery rules: presence-gated forwarding + ack-sync with an absolute badge

**Recommendation**: FOLD-IN → argus FLOW §12's merged delivery-rule set (with BO1-3,
OH2-2, MY1-3, CH2-3, HD1-2). Small, shipped, and absent from the merged set.

**Where in cmux**: (a) **Presence-gated forwarding**: phone push fires *only while the
operator is away from the Mac* — the Mac side monitors its own presence
(`Sources/MacPresenceMonitor.swift`) and `PhonePushClient` forwards notifications to
APNs only then (ios/CHANGELOG 1.0.3 #5912: "Notifications forward to the phone only
while you are away from the Mac"). (b) **Cross-device ack sync**: dismissing on either
device clears the other — phone→Mac over the attach channel, Mac→phone via silent
`content-available` pushes; dismissals survive relaunches via a **512-entry persisted
tombstone ring** (`TerminalNotificationStore.swift:276-306`); and the badge is set to
an **absolute unread count** pushed from the store ("no ±1 arithmetic, self-heals
drift", `:244-419`). Foreground suppression when already viewing that terminal
(`MobilePushCoordinator.swift:194-209`) and deep-links that park until the workspace
loads (`:218-293`) round it out.

**Gap in jido_radclaw** (verified 2026-07-06): no push machinery exists at all — zero
APNs/web-push/VAPID/service-worker hits in `lib/`/`assets`/`mix.exs`; the only
phone-reaching path is opt-in Discord via Discord's own push
(`lib/jido_claw/platform/channel/discord.ex`, gated on `DISCORD_BOT_TOKEN` in
`application.ex:86-90`). FLOW §12 is the design that will consume these rules.

**Why it matters**: the §12 merged set has same-device rules (active-surface
suppression, focus-ack-consumes, re-verify-at-delivery) but nothing *cross-device*:
where to deliver when the operator has two surfaces, and how acks propagate between
them. cmux ships both answers: route on **operator presence, not device existence**
(the generalization for us: suppress push while any authenticated operator surface is
active — the LiveView dashboard is our "Mac"), and make read-state a **synced absolute
projection, never per-device arithmetic** (for us: unread/badge derives from the
durable feed's ack watermark, so every surface self-heals — the same shape as our
event-seq watermarks).

**Adoption sketch**: two lines into the FLOW §12 rule list at slice 1, with this doc
cited: "push only when no operator surface is active (presence-gated, not
device-gated)"; "badge/unread is an absolute projection of the durable ack watermark;
dismissals are synced facts, not per-device state." Both fall out nearly free from
`WorkflowEvent`/`AgentCase` watermarks.

---

## Tier 2 — banks against a named trigger, or folds into a queued build

### CM2-1. The native-companion cost bill — the OVERVIEW §2.6 evidence, banked

**Recommendation**: TRACK — trigger: revisiting OVERVIEW §2.6's PWA-for-speed choice
(the scan's own framing for this half of the dig; same trigger as t3code TC2-6's
mobile evidence). No build; this entry exists to make that revisit *informed*.

**Where in cmux**: the scan called `ios/` "a real if thin mobile terminal client (~26
Swift files)" — **corrected**: the 26 files are a 418-LOC composition root +
1.2k-LOC feature veneer. The product is **~58.7k LOC of iOS-only Swift across 15 SPM
packages** (terminal 8.8k, shell 15.7k, UI 13.6k, RPC/transport/model/…) **+ ~16.1k
shared** (CMUXMobileCore, auth runtime, agent chat), linking **GhosttyKit.xcframework**
(real libghostty on the phone — the render engine, not a text dump), plus **four cloud
services**: Stack Auth (two per-channel projects with baked-in keys), the cmux.com
API (device registry, APNs token store, server-side APNs send), a Cloudflare
Durable-Objects presence worker (15s heartbeats, WebSocket subscribe), and APNs — with
**Tailscale as the mandatory data plane** (the shipped byte transport is plain TCP with
no TLS over the tailnet, `CmxNetworkByteTransport.swift:160-167`; WireGuard is the
crypto layer — our own §2.1 posture, stated from outside). Plus a Mac-side mint/host
subsystem and a separate TestFlight release pipeline. What that buys over a PWA: a
full-fidelity terminal **mirror** with capability-negotiated fidelity
(`terminal.render_grid.v1` styled-grid stream, raw-PTY-bytes fallback into local
libghostty — `MobileShellComposite.swift:42-71`), reliable APNs (CM1-4), on-device
dictation and photo attachments, and an agent-chat surface. The iroh p2p transport that
would remove the Tailscale prerequisite is **aspiration**: design committed, Rust spike
in `experiments/`, only inert enum/policy seams in shipped code.

**Gap in jido_radclaw / why it matters** (verified 2026-07-06): OVERVIEW §2.6 chose
PWA with APNs parked ("wrap in Tauri or Capacitor rather than rebuilding",
OVERVIEW.md:74) — and the seams pass corrected this dig's premise: the choice was
*cost-led but merit-checked* (iOS 16.4+ Web Push for installed PWAs is cited as the
merit basis), not "speed over merit" as the scan phrased it. This entry is the other
pan of the scale: the native route costs ~75k LOC + four cloud services + a second
release pipeline, and cmux still needed a cloud identity graph (per-Stack-project ids,
issue #7145) that is the antithesis of our tailnet-only, no-third-party posture. The
two things native bought that a PWA genuinely cannot: on-device terminal-grade
rendering of a live mirror, and APNs-class background delivery (Web Push on iOS is
real but weaker). If argus's phone client ever feels insufficient, the revisit
weighs exactly these two against this bill — with t3code's TC2-6 (native APNs via
relay, no PWA at all) as the second datapoint.

### CM2-2. Pairing posture: the no-secret, never-expiring QR + route-class auth policy

**Recommendation**: BORROW-RUBRIC (two fragments) — a §4.4 datapoint alongside t3code
TC1-2 (the positive scoped-credential reference) and myrlin MY1-4 (the enrollment
ladder); a different, instructive split of the same problem.

**Where in cmux**: the pairing QR
(`cmux-ios://attach?v=2&ub=<user>&pc=…&av=…&ab=…&r=<host:port>…`,
`CmxPairingQRCode.swift:6-92`) **deliberately carries no auth token, no expiry, no
device id** — in-file rationale: "The owner's Stack access token is the host's sole
authorization gate"; "Ticket age authorizes nothing." It is pure **addressing +
account binding**: `ub` is the opaque Stack user id the phone must match before
dialing (preflight `MobilePairingAccountPreflight.swift:38-62` — mismatch refuses
client-side; unknown identity stays silent and lets the host reject), routes are
Tailscale-only with loopback rejected at decode (`:189-190`) *and* at registration
(`CMUXCLI+Remotes.swift:128-214`), and the QR never expires by design ("must keep
working however long it sat on screen") because authorization is always the live
account token presented at attach. Complementing it: `MobileShellRouteAuthPolicy`
sends bearer tokens **only over route classes deemed encrypted** (Tailscale tunnel,
future iroh QUIC, dev loopback) — auth material is classified by transport class, not
sprayed.

**Gap in jido_radclaw** (verified 2026-07-06): argus §4.4 is single-shared-key +
tailnet ACLs with MY1-4a's `mix jidoclaw.api_key` mint do-now still open
(`Accounts.ApiKey` has no working mint path — OVERVIEW.md:371); no enrollment surface
exists yet.

**Why it matters**: TC1-2 answered "what should a credential *be*" (scoped,
short-lived, per-RPC-enforced). cmux answers the orthogonal question "what may the
*enrollment artifact* carry": nothing that authorizes — addressing and an
account-binding check only, with authorization always live and revocable at the
account. That decomposition (QR = where + who-check; token = may) is the fragment to
keep for argus's pairing story, because it makes the QR safe to screenshot, print, or
leave on screen — a real property for a personal-infra tool. The route-class token
policy is the second fragment: our channel tokens should likewise be classified by
transport (tailnet/https only), stated as policy rather than assumed. The
anti-borrow half: binding enrollment to a third-party cloud identity (Stack) is what
makes cmux's version work and is exactly what we refuse — our `ub` equivalent is the
tailnet identity + our own API key, per §4.4's existing posture.

### CM2-3. The restore-argv sanitizer + the resume-session registry (FOLD-IN → MC1-1, with HD2-2)

**Recommendation**: FOLD-IN — a second rider on the queued MC-FIRST-WAVE CLI-resume
build. herdr HD2-2 contributed the 14-vendor *resume argv table*; cmux contributes the
**restore-side sanitization contract** — what a stored launch may and may not replay.

**Where in cmux**: sessions persist as `RestorableAgentHookSessionRecord`
({sessionId, workspaceId, surfaceId, cwd, transcriptPath, pid, launchCommand,
isRestorable, agentLifecycle}, `~/.cmuxterm/<agent>-hook-sessions.json`); on relaunch
cmux replays the agent's **native resume command** with the saved session id
(`docs/agent-hooks.md:46-49`), gated by **durable-resume evidence** (a codex record
whose env lacks `CODEX_HOME`-class anchors is refused —
`CLI/CMUXCLI+AgentHookRestoreEvidence.swift:104-108`). The sanitizer
(`AgentLaunchSanitizerClaudeTeamsPolicy` + the base claude policy) is the interesting
layer: **prompt boundaries** (`--tmux <text>` carries the initial user prompt; on
restore the payload is *dropped* so the prompt is never replayed into a fresh session);
a **post-boundary recovery allowlist** (`--model`/`--fallback-model` recovered;
`--permission-mode` recovered *only* with value `auto`; everything else after the
boundary dropped); resume/fork selectors stripped so a restored launch can't
double-resume (`--continue/-c`, `--resume/-r`, `--session-id`, `--fork-session`
dropped); whole launches rejected as non-restorable for `-p`/`--no-session-persistence`;
cmux's own injected `--settings` hook JSON rewritten back to the user's own
(`AgentLaunchSanitizer.swift:515-596`); and the trust bypass **never** persisted
(CM1-1). Fork is a first-class variant (`AgentForkArgv`: resume + `--fork-session`).
User-extensible: the in-app "Vault" registry accepts custom agents in `cmux.json` with
`detect` / `sessionIdSource` / `resumeCommand` / `forkCommand` templates
(`docs/vault.md:1-84`).

**Gap in jido_radclaw** (verified 2026-07-06): MC1-1's gap stands verbatim — runners
re-send accumulated prompts (`claude_code.ex:62-73`, codex `--ephemeral`); nothing
persists a vendor session ref, so nothing sanitizes one either.

**Why it matters**: the MC1-1 build was scoped around *acquiring and replaying* session
refs (multica's server-persisted id + clear-then-retry; herdr's argv table +
`session_start_source`). cmux adds the layer both miss: a resumed launch is a
**replayed argv with history**, and the field's operating product needed an explicit
policy for which tokens survive — prompts never, permission escalations never,
model/config yes, trust bypasses never. That's a security-relevant contract (a replayed
`--dangerously-skip-permissions` or a replayed prompt is a real footgun) and it slots
directly into our MC1-1 item as acceptance criteria rather than a separate build.

**Status (2026-07-11)**: FOLDED IN — pre-argus Wave A #2 (MC1-1 build).
The restore-argv sanitizer landed AS CONTRACT TESTS on both vendor runners
(the acceptance-criteria framing this entry asked for): a continuation argv
never contains the original task; permission/trust flags derive ONLY from
`state.access`, never anchor state; `--continue`/`--last` never appear;
`--session-id` only on fresh-armed claude; resume selectors only on
continuations and never combined; model/mcp/effort rebuilt fresh from config
each turn. See
[docs/system/forge-session-resume.md](../../../system/forge-session-resume.md).

### CM2-4. Hook-pack install discipline: 17-agent catalog, opt-in diff-preview writes, per-invocation injection

**Recommendation**: BORROW-REFERENCE (small) — rides herdr HD2-5 (managed vendor-config
edits) and CC2-2 (ManagedDoc); the second full-scale field implementation of the same
contract, with one addition worth keeping.

**Where in cmux**: `agentDefs` (`CLI/CMUXCLI+AgentHookCatalog.swift:6-238`) declares 17
agents' hook packs as data — config path, format (nested JSON / TOML array-table /
YAML / kiro-agent JSON), events, feed events, disable env var, hook marker — executed
by shared writers that show a **diff preview and prompt `[y/N]`** unless `--yes`,
guard every hook shell snippet with `[ -n "$CMUX_SURFACE_ID" ]` + a per-agent disable
env, and mark ownership with a hook-marker string. Claude and codex get the lighter
touch: **per-invocation injection** (a PATH wrapper adding `--settings`/`-c
hooks.<event>=…` flags per launch) instead of editing `~/.claude`/`~/.codex` global
config at all — and the spec records that guaranteeing codex hooks would mean silently
editing `~/.codex`, which they *deferred as a product decision*
(`docs/agent-session-tracking-spec.md:355-362`).

**Gap / why**: same as HD2-5 (we edit no third-party configs today; the MCP `.mcp.json`
story and any editor integration will). The addition over herdr: **per-invocation
injection as the zero-residue alternative** — when a vendor CLI accepts config as
argv/flags, injecting per-launch beats managed file edits entirely (nothing to
uninstall, nothing to drift, trivially versioned with the launcher). Keep that as the
first option in the HD2-5 contract, file edits as the fallback.

---

## Tier 3 — datapoints and garnish

### CM3-1. Skills as the integration surface, at product scale

**Recommendation**: datapoint for the standing ACP TRACK (emdash EM1-4), joining herdr
HD3-2. cmux ships **21 Claude-Code-format skills in-repo** (`skills/` — `cmux` topology
control, `cmux-browser` automation, plus 19 dev/ops skills) teaching any agent its CLI:
short handle refs (`surface:N`), `cmux identify` caller context, wait/snapshot
workflows, a `trigger-flash` attention cue. Together with herdr's `SKILL.md`-via-`npx
skills add`, the pattern is now field-standard at both ends of the size spectrum:
**the cheap half of "should third parties drive us" is a published skill over the
existing surface, not a protocol**. Our MCP tools are already the surface; the skill is
a markdown file. Weigh at the ACP TRACK's trigger, unchanged.

### CM3-2. `events.stream`: after-seq resume at desktop scale — a TC1-1 convergence datapoint

**Recommendation**: ALREADY-COVERED (cite `WorkflowEvent` + the byte-paginated
`after_seq` feed, `tools/workflow_events.ex:53-57`) — recorded because the convergence
is evidence. cmux's socket event stream does `--after-seq` resume with an ack frame
carrying `{after_seq, oldest_seq, latest_seq, gap}`, per-client cursor files, stable
ids for dedupe, heartbeats, and slow-subscriber drop (4096-event ring + 16MiB JSONL
mirror — `CLI/CMUXCLI+Events.swift:42-191`, `docs/events.md:174-180`). A third
independent product (after t3code's SQLite feed and our WorkflowEvent log) landing on
cursor+catch-up+gap-honesty as the client contract — with the desktop-scale caveat that
a bounded ring means honest `gap` reporting matters more than replay depth. The
`--cursor-file` client idiom (resume cursor owned by the consumer, not the server) is
a nice fragment for argus CLI consumers.

### CM3-3. Remote-provisioning trust nuggets

**Recommendation**: garnish, three fragments on an otherwise fs-perms trust posture
(S-3): (a) the remote daemon binary is **sha256-manifest-verified before upload/run**
(`docs/remote-daemon-spec.md:33-34,63-66` — herdr S-4 has the same nugget); (b) the
CLI-from-inside-SSH relay requires an **HMAC-SHA256 challenge-response** before
touching the real app socket, so a remote shell never gets the socket raw
(`daemon/remote/README.md:134-160`); (c) the WebSocket daemon transport is cloud-VM
opt-in behind a **single-use, expiring lease file** — wrong/expired/replayed leases
close before a PTY spawns (`daemon/remote/README.md:71-105`). All three are the
"engine-observed, mechanically-fenced" instinct applied to remote plumbing; file with
the FLOW §11/slice-8 references (HD2-1) as the auth-shape garnish.

---

## Skip / Already covered / Negative evidence

- **S-1. THE SWEEP — edit-and-resume verified absent (subject 26, the family's last
  open slot).** cmux *does* have an out-of-band decision object — the Feed
  `WorkstreamItem` (CM1-3), decided by buttons, not keystrokes — so this is not the
  trivial empty. But: decisions are exactly `.permission(mode)`,
  `.exitPlan(mode, feedback: String?)`, `.question(selections)`
  (`FeedPanelView.swift:926-976`, `FeedCoordinator.swift:1117-1130`); the plan text,
  tool input, and diffs render **read-only**; the ExitPlan `feedback` string rides a
  mode decision (annotate-then-continue — the emdash/termic class, *below* the field's
  three plan-layer promote-the-edit precedents); the Stop-card reply composer types
  keystrokes into the PTY (`FeedCoordinator.swift:609-623`); and the pending object is
  a ≤120s semaphore that expires with the agent's PID — advisory, not durable (their
  own doc: "advisory, not blocking", `docs/feed.md:136-140`). Every other human→agent
  channel is keystroke/text injection (CLI `send`/`send-key`, socket
  `surface.send_text`, tmux-compat `send-keys`/`respawn-pane`, iOS `mobile.chat.send`
  + `mobile.terminal.input`, the HMAC'd remote relay). **No affordance anywhere edits
  an agent's output and resumes.** Argus §5's execution-layer novelty survives all 27
  swept subjects; the gate-defect ledger (pms observation 9) gains the soft-wait
  timeout row (deliberate fall-through — see OQ-1 before calling it a defect).
- **S-2. Terminal emulation/rendering stack** (libghostty, GhosttyKit, Metal surfaces,
  the render-grid exporter) — SKIP; ghostty_ex GX1-1's slot, unchanged (still not in
  `mix.exs`). The phone-mirror fidelity negotiation (`render_grid.v1` capability) is
  noted in CM2-1.
- **S-3. Local trust posture** — SKIP as a §4.4 negative datapoint, joining herdr
  HD3-2/S-4 and CCC CC2-4: the socket defaults to uid-0600 filesystem trust
  (`SocketControlMode` default `cmuxOnly`; the `cmuxOnly`-vs-`automation` distinction
  is not enforced by any peer credential; password mode opt-in; `allowAll` is 0666),
  and once connected, **browser automation is ungated** — `eval`, cookies, storage,
  screenshots on authenticated profiles, with cookie *import from 20+ browsers* as a
  feature. Any local process — including every pane's agent — can drive every other
  pane's terminal and the operator's authenticated browser. Coherent for a trusted
  personal machine; the inverse of our DestinationPolicy/egress-gated `browse_web`
  posture (`lib/jido_claw/tools/browse_web.ex:44,97-114` double-checks destination
  policy pre-start and post-redirect) and of argus's authed-surface requirement.
- **S-4. The cloud identity graph** (Stack Auth ×2 projects, cmux.com registry, baked
  publishable keys, per-project user ids) — SKIP as anti-borrow: it's what makes
  cmux's pairing work and exactly what a tailnet-only personal control plane refuses;
  issue #7145 (dev/prod builds cannot pair across Stack projects) is the coupling made
  visible. Our equivalents stay tailnet identity + our own API keys (§4.4).
- **S-5. cmux-vault** (Go transcript-sync CLI) — SKIP as a leakage-hygiene negative
  reference: it uploads coding-agent transcripts ("can contain secrets… credentials
  pasted into terminals", their own DESIGN.md:34-38) zstd-compressed to S3 via
  presigned URLs with **client-side encryption an explicit unimplemented follow-up**.
  Our posture (tenant-scoped AshCloak encryption at rest for tool outputs/artifacts,
  redaction at the root) is the opposite pole; keep it that way.
- **S-6. The Rust `mux`** — SKIP: a separate experimental TUI multiplexer (v0.1.0, own
  JSON protocol) whose *proposed* v6 spec contains the only orchestration-shaped
  primitives in the repo (`list-agents`/`report-agent`/`on-agent-blocked` hooks) —
  unshipped. pms observation 13's wiring-mortality lesson, pre-empted: specs are not
  subjects.
- **S-7. The in-app scriptable browser as a feature** — SKIP for us (argus renders
  web previews via ports/links; the agent-side browser is `browse_web`, deliberately
  one-shot and egress-gated). The ~120-method agent-browser port is impressive and is
  the reason S-3's ungated-eval surface exists; the two are a package.
- **S-8. iroh p2p transport** — nothing to track: design + Rust spike in
  `experiments/`, inert enum seams in shipped code. If it ships and argus ever wants
  VPN-less phone reach, revisit under CM2-1's trigger.
- **S-9. Sidebar metadata collectors** (listening ports via coalesced-kick lsof burst
  scans; PR badges via polled `gh auth token` GitHub calls) — SKIP; we derive run/PR
  state from durable records, not host scans. The port-scanner's kick-then-burst
  cadence (`PortScanner.swift:4-16`) is a fine polling shape if a host-facts collector
  ever exists on our side.

## Open questions

- **OQ-1 (slice 6 / executor PR-2)**: gate-timeout polarity for **vendor-intercepted**
  approvals. cmux's soft-wait (timeout `{}` → the vendor's own TUI prompt takes over)
  is graceful degradation when a native fallback surface exists; our native gates are
  fail-closed (correct — no fallback exists); bosun's timeout-means-proceed remains the
  named defect. When our slice-6 bridge intercepts codex/claude `requestApproval`
  frames into `AgentCase`s, does an undecided case time out to the vendor's own
  interactive prompt (cmux polarity, keeps unattended runs alive) or hold the frame
  open indefinitely (our durable-gate polarity, keeps the decision durable)? Lean:
  cmux polarity for interactive Forge sessions with a live PTY, durable-hold for
  headless runs where no vendor TUI exists — decide at PR-2 with TC1-3(b).
- **OQ-2 (post-PR-2)**: do we ever *want* teams-driving — Claude Code's own teammate
  orchestration running inside a Forge session — given our platform owns swarm
  orchestration natively? The honest default is no (two orchestrators fight); the
  named trigger to revisit: a vendor teams feature gains a structured surface
  (app-server-class, not tmux-probed), or an operator explicitly wants vendor-native
  teams UX inside a jidoclaw worktree. Until then CM1-1 banks as reference, not queue.
  *(Sharpened same day, operator conversation)*: the question splits on an axis the
  dig didn't price — teams-as-**subscription-durable transport** (the teammate
  mailbox as message passing to an interactive-TUI session, hedging the expected
  removal of `-p`/Agent-SDK from OAuth subscription usage) rather than
  teams-as-orchestration. The driver, the billing/coordination/display decomposition,
  the lane options, and a proposed spike sequence live in the sibling
  [CM-SUBSCRIPTION-LANE-PLAN.md](CM-SUBSCRIPTION-LANE-PLAN.md).

## Cross-references and dependencies

```
argus slice 6 / SYNTHESIS §5.6 (CLI adapters)  ← CM1-1 (teams driving + assumption ledger)
                                               ← CM1-3 (classifier + soft-wait; OQ-1)
argus slice 1 (attention read-model)           ← CM1-2 (fences; the herdr HD1-1 opposite pole)
argus FLOW §12 (delivery rules)                ← CM1-4 (presence-gated forwarding; ack-sync/absolute badge)
OVERVIEW §2.6 revisit (named trigger)          ← CM2-1 (native cost bill; with t3code TC2-6)
argus §4.4                                     ← CM2-2 (no-secret QR posture; with TC1-2, MY1-4)
                                               ← S-3, S-4 (negative datapoints)
queued MC-FIRST-WAVE resume build (MC1-1)      ← CM2-3 (restore sanitizer; with herdr HD2-2)
HD2-5 / CC2-2 (managed config edits)           ← CM2-4 (per-invocation injection first)
ACP TRACK (EM1-4)                              ← CM3-1 (skills-as-surface, with HD3-2)
TC1-1 / WorkflowEvent feed                     ← CM3-2 (third-product convergence)
FLOW §11 / slice 8 (HD2-1)                     ← CM3-3 (remote auth garnish)
```

**Suggested first wave**: nothing jumps the queue — the dig's purpose was to have
these references in hand before slices 1 and 6 open (CM1-1/CM1-3 are read-at-build
references; CM1-4 is two sentences into FLOW §12; CM2-3 is acceptance criteria on the
already-queued MC1-1 item, not a new build). Corpus updates land with this doc: ades
README category 4 + comparison row + early-read item 8 + observations 2/3/6/8;
SYNTHESIS §5.1/§5.6; OVERVIEW §2.6 evidence note; FLOW §12 rules. Collision notes:
CM2-3 must not fork from MC1-1 (rider, like HD2-2); CM1-2 is read *with* HD1-1 at
slice-1 design time — they are one contract, argued from opposite poles; no collision
with `unadopted-next-ten` (composer/judgment-layer work; this doc is argus-facing).

## Bottom line

1. **CM1-1** — slice 6's reading list gains its teams entry and its cost sheet: the
   only field reference for driving Claude Code teammate mode is a tmux impersonation
   resting on nine unguarded vendor assumptions — the strongest argument yet recorded
   for structured-surface driving (TC1-3) wherever a structured surface exists, with
   the shim trick and its contract-test method banked for when one doesn't.
2. **CM1-2 + CM1-3** — the attention/adapter stack gets its second pole and its
   classifier: cmux proves hook-authority survives *with mechanical fences*
   (generation gating, exit-outranks-everything, correct-only corroboration — the
   inverse cure to herdr's retreat, converging on the same fences), and its typed
   `(source, event)` feed classifier with three actionable kinds is the pre-priced
   vendor-quirk table our slice-6 ask-rule bridges need.
3. **The phone question is now evidence, not taste** (CM2-1, CM1-4): the "thin" native
   companion is ~75k LOC + four cloud services + a second release pipeline — OVERVIEW
   §2.6's PWA choice stands, upgraded from cost-led to evidence-based — while the two
   transferable delivery rules (presence-gated forwarding, absolute-badge ack sync)
   fold into FLOW §12 for free.
4. **Subject 26 closes the sweep**: the field's most elaborate decision surface is
   still decision-*only* — mode picks, option picks, a feedback string, keystrokes —
   never an edited output resumed. Argus §5's execution-layer head-promotion novelty
   now stands verified across all 27 subjects in both corpora, and the GPL
   patterns-only discipline held throughout.
