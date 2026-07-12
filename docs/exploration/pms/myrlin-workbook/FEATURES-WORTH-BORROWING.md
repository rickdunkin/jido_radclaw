# Features Worth Borrowing from myrlin-workbook

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's "ades bridge" dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md) second wave —
upgraded from pattern notes to a full dig, closing the corpus's planned reads). Source:
`~/workspace/research/pms/myrlin-workbook` (therealarthur/myrlin-workbook — "Myrlin's
Workbook: open-source workspace manager for AI coding CLIs"; a browser + TUI +
native-mobile session cockpit for Claude Code/Codex that grew a per-project kanban and
a worktree task board). Pinned: myrlin-workbook @ `7e26a80d` (2026-07-03, the v1.2.0
release commit — refreshed 2026-07-04, **zero drift from the scan pin**), jido_radclaw
@ `8699af6a`. Cites are firsthand reads of both trees, accurate to within a few lines.
Shape: ~101k LOC JS/TS — Node/Express server + **no-build vanilla-JS SPA** (one
~21k-line `app.js`) + blessed TUI + a **native Expo RN app** (`mobile/`, its own
5-tab client) + two providers (`src/providers/claude|codex`, a 13-method interface);
persistence is a single JSON file (`~/.myrlin/workspaces.json`) behind an
EventEmitter store. Maturity: 560 commits 2026-02→2026-07, solo-plus-agents
(therealarthur 416, agent alias "Marty" 48, ~10-person contributor tail via PRs), two
release lines (v0.9 stable Claude-only; v1.2 alpha.0→16 → stable 2026-07-03), 64
server test files with hermetic sandboxing vs **one** native mobile test. Nothing was
built or executed this review — all claims are code reads; one high-confidence runtime
claim (MY1-4's pairing 429) is source-logic-verified, not executed.

**License law for this doc — AGPL-3.0**: nothing here may be lifted as code, ever (the
termic/Chorus rule). Every verdict below is BORROW-PATTERN / BORROW-REFERENCE /
BORROW-RUBRIC — reimplement from the contract in our idioms; schemas and constants are
quoted as facts, not as source.

**Recency warning, two-sided.** The subsystems this dig ranks highest are 0–2 days old
at pin: the multi-account credential switcher + Mac lineage guard shipped alpha.12–15
(2026-07-02/03), the read-only mirror and git-status conflict cache alpha.16
(2026-07-03), the notification-storm delivery-rules overhaul alpha.10 (2026-07-02).
Expect MY1-1/MY1-3 mechanics to move; re-pin before citing in a build decision. The
**opposite** staleness also holds: the native Expo app was built in one orchestrated
blitz (2026-03-28→04-01, phase-numbered commits) and has not moved since, while the
server kept shipping — the drift is now visible in code (mobile task types diverge
from the store schema, a push deep-link routes to a nonexistent path, the conflict UI
renders a field the server never sends, the visible notification-level control is
device-local and gates nothing, and the pairing endpoint regression below means fresh
devices can't enroll at HEAD).

**Doc/code drift found while reading** (calibrates trust — unusually wide even for a
solo-plus-agents repo): README's Roadmap lists **task-spinoff as "Coming Soon"** while
it shipped in the 0.9.x line (the windowsHide sweep in the same file's changelog
enumerates its hooks); README's architecture section claims "~24 source files, 42
tests" (real: ~40 server files, 64 test files); `docs/WORKFLOWS.md` draws a 4-status
task lifecycle against the code's 5-column board + 7 written statuses and never
mentions spinoff, PRs, dependencies, or the scheduler; CONTRIBUTING claims default
password `myrlin` vs the code's auto-generate; `push.js`'s own header advertises a
file-conflict push whose event no code emits; `docs/PROVIDER-INTERFACE.md` (rev
2026-05-10) omits the mirror/fork-resume surface and mis-describes `costAdapter`
dispatch; the cloudflared design doc specifies mobile CF-Access headers that were
never implemented and names the wrong WS path. The 2026-07 changelog entries, by
contrast, are root-cause-level accurate — trust concentrates there.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — including a
correction that reaches [../../argus/FLOW.md](../../argus/FLOW.md) §12's `fileConflicts`
citation), [../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) §4.4/§5/§6.2 +
[../../argus/FLOW.md](../../argus/FLOW.md) §4/§5/§7/§12 (the seam map),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md)
(MC1-1 resume stack — MY adds the `--continue` shared-cwd hazard + probe-and-own
mechanics; shipped 2026-07-11 in pre-argus Wave A #2 with both myrlin hazards
honored: `--continue` is contract-pinned never-used on both runners, and
probe-from-disk was REJECTED — anchors persist fenced on the Forge Session
row, never read back from CLI dotfiles; MC2-4 env scrub — myrlin independently
scrubs `CLAUDECODE` by exact name, now a hard denylist operator config cannot
re-open),
[../symphony/FEATURES-WORTH-BORROWING.md](../symphony/FEATURES-WORTH-BORROWING.md)
(SY1-4 multi-account rotation — MY1-1 is its file-mechanics half),
[../chorus/FEATURES-WORTH-BORROWING.md](../chorus/FEATURES-WORTH-BORROWING.md) (CH2-3
per-kind toggles; CH2-6 resume-anchor ownership — myrlin is the probe-from-disk
variant), [../orca/FEATURES-WORTH-BORROWING.md](../orca/FEATURES-WORTH-BORROWING.md)
(OR1-2's warning-only overlap advisory — MY1-2's sibling; OR1-4 init hooks),
[../bosun/FEATURES-WORTH-BORROWING.md](../bosun/FEATURES-WORTH-BORROWING.md) (BO1-4
enforce-on-the-resource — myrlin's client-side caps are the counterexample),
[../pad/FEATURES-WORTH-BORROWING.md](../pad/FEATURES-WORTH-BORROWING.md) (PD1-1
advertisement-without-enforcement rot — myrlin's pairing 429 is the same lesson at the
auth layer), [../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md](../../ades/claude-command-center/FEATURES-WORTH-BORROWING.md)
(CC1-2 attention read-model — MY1-3's delivery deltas land inside it),
[../../ades/emdash/FEATURES-WORTH-BORROWING.md](../../ades/emdash/FEATURES-WORTH-BORROWING.md)
(EM1-3 two-trigger set — myrlin's *live* push set converges on exactly it), and
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-3 — MY1-1's three-state token health is the same infra-≠-verdict law applied to
credentials). Threat-model weighting as always: personal tailnet — LLM-misbehavior
containment and leakage hygiene over external-attacker hardening.

**Structure note** (multica/Chorus precedent): a **"Dig-brief dispositions"** section
follows the tiers; that plus the scan corrections justify running past the camus band.

## Determination (TL;DR)

**Nothing to adopt as a dependency — AGPL decides before architecture does, and the
architecture would decide anyway: single-host by explicit design, one JSON file behind
an EventEmitter, a shared password with in-memory tokens, state detection by scraping
the xterm buffer with regex lists, enforcement (concurrency caps, needs-input,
conflict polling) living client-side where any API caller bypasses it. On every axis
argus differentiates on — durable events, gates, leases, server-enforced invariants,
catch-up — the asymmetry runs our way. What survives verification is worth the dig:**
(1) **the credential lineage guard** (MY1-1) — the corpus's only shipped answer to
multi-machine CLI OAuth credential sharing: OAuth refresh rotation is a single lineage,
so a background refresh on machine A silently logs machine B out; myrlin ships the
lineage pin, the rotation write-back watcher, three-state token health (transient ≠
dead — C1-3's law applied to credentials), and identity-first/tokens-last atomic
apply. Argus FLOW §5 plans exactly the multi-node credential sync that hits this. (2)
**the conflict-detection reference with a correction that reaches FLOW §12** (MY1-2):
the two detectors (transcript-derived Edit/Write paths; git-status with a TTL
promise-cache) are real and borrowable — but the `fileConflicts` **push is dead code**
(the store event it listens for has no emitter; conflicts are poll-only), so the
trigger argus adopted from myrlin is one even its originator never wired. Of five
declared push preference keys, exactly **two fire** — agent-finished and
task-ready-for-review, i.e. emdash's EM1-3 set arrived at independently. (3) **the
delivery-rules deltas** (MY1-3) from a paid-for notification-storm incident:
replay-suppression on reconnect, focus-acknowledgement that consumes pending
attention, and a minimum-signal re-arm floor — three rules the corpus's EM/TM/XA
stack lacks and argus slice 1 needs. (4) **the enrollment ladder** (MY1-4) for
OVERVIEW §4.4 — password → one-time startup token → single-use QR pairing token →
90-day revocable device token — sharpened by two findings: the pair endpoint ships
**broken at HEAD** (a helper refactor missed one call site; the asserting test exists
but evidently doesn't gate), and our own side has **no key-minting path at all**
(`ApiKey.create` has zero callers, no mix task, and UserSocket won't take a bearer
key). Finally, the §5 sweep: **execution-layer edit-and-resume verified empty at
subject 23**, while the plan layer yields the field's third promote-the-edit — with
the sharpest lesson yet: myrlin promotes the operator's edited spec verbatim **into a
record nothing consumes** (the spawned agent starts blank), so argus §5.4 gains an
end-to-end acceptance criterion no other subject surfaced.

| Part of myrlin-workbook | As a dependency | What to take |
| --- | --- | --- |
| Multi-account credential switcher + Mac bridge | No — AGPL, Node, dotfile-shaped | MY1-1: lineage pinning, rotation write-back, three-state health, identity-first/tokens-last apply, projection whitelists; SSH hygiene rubric |
| Conflict detection (2 detectors + Conflict Center) | No | MY1-2: detector shapes (ours becomes a DB query), TTL promise-cache + eager invalidation, protected-pane kill UX as contrast; the dead-push correction |
| Notification/push layer | No | MY1-3: replay-suppression, focus-ack, min-signal re-arm; MY2-4: per-device pref rows, 2s batch-coalesce, ticket-based pruning; the 5-declared/2-live lesson |
| Auth + QR pairing + device registry | No | MY1-4: the four-token ladder, multi-URL QR payload, revocation semantics; the pairing-429 enforcement-rot lesson; our minting-gap is the do-now |
| Task board + spinoff + worktree PM | No | MY2-1: promote-the-edit with the severed-consumer criterion; MY2-2: status→column mapping + two-terminal-status evidence; MY2-3: collision reconciliation + init hooks; dead `blockedBy` (4th corpus datapoint) |
| Session engine (PTY, mirror, tailer, scheduler) | No | MY2-6: skip-and-record scheduler validation; MY3-1 tailer discipline; MY3-2 PTY viewport ownership; resume-probe hazards fold into MC1-1 |
| Mobile app + SSE client | No | MY2-5: events-invalidate-never-mutate + offline mutation queue; the frozen-client drift catalog as the §6.3 skew cautionary |

## Why not adopt as a dependency

1. **AGPL-3.0** — a hard no for lifting into this codebase regardless of merit.
2. **Runtime and store mismatch** — Node/Express + a single-JSON-file store versus
   OTP/Ash/Postgres; every borrow is a translation, and their hardest-won store code
   (atomic temp+rename, zero-fill detection, 3-tier backups) solves problems Postgres
   already doesn't have.
3. **Scraping versus events.** All session-state detection (working/idle/needs-input)
   is frontend xterm-buffer regex scraping (`terminal.js:1430-1626`) that never even
   reaches their own server. JidoClaw's equivalent surface is structured (`Forge`
   lifecycle events, `Conversations` rows, telemetry) — the ades corpus's "we have
   events, everyone else scrapes" asymmetry at its purest.
4. **Client-side enforcement.** Concurrency caps, needs-input badges, and conflict
   polling all live in the browser; a direct API call bypasses every one. Argus's
   posture (invariants on the resource, decisions through one chokepoint) is the
   deliberate opposite.
5. **Single-host by design** — "multi-machine workbook replication" is an explicit
   non-goal (`docs/OPERATIONS.md:102`); the one cross-machine feature is credential
   mirroring over SSH. Argus is a multi-node cluster from day one.

## How to read this document

Recommendation vocabulary per the [corpus conventions](../../README.md):
BORROW-PATTERN / BORROW-REFERENCE / BORROW-RUBRIC / FOLD-IN / TRACK / ALREADY-COVERED
/ SKIP. Initial inventory — no Status lines. IDs are `MY<tier>-<seq>`; `S-n` skips;
`OQ-n` open questions. Tiers scoped to this codebase: **Tier 1** = load-bearing for a
named argus design decision or a live gap verified today. **Tier 2** = lands with a
specific argus slice. **Tier 3** = garnish. Every Gap claim verified against
jido_radclaw @ `8699af6a` on 2026-07-04 (the one commit since the Chorus/orca digs'
`609350aa` touched agent_tracker/forge/compactor — not the gate or auth surfaces
cited here).

---

## Tier 1 — load-bearing for named argus decisions

### MY1-1. The credential lineage guard — multi-machine CLI OAuth, solved at the file layer

**Recommendation**: BORROW-PATTERN (lineage pinning, rotation write-back, three-state
health) + BORROW-REFERENCE (the apply/verify/rollback sequence, the projection
whitelist). The corpus's only shipped answer to a problem argus will create for
itself the day FLOW §5 syncs CLI credentials to a second node.

**Where in myrlin**: `src/web/credential-manager.js` (+ routes, + `mac-bridge.js`;
all shipped 2026-07-02/03, alpha.12–15). A credential is a **pair** — the token file
`~/.claude/.credentials.json` plus the `oauthAccount` identity inside `~/.claude.json`
— snapshotted per account to `<dataDir>/claude-accounts/<accountUuid>.json`, chmod
0600 (`:280`). The load-bearing mechanisms:

- **The lineage problem, named**: the OAuth server revokes the old refresh token the
  moment a new one is issued — one account = one refresh lineage. Their background
  usage poller refreshes stale inactive accounts (~12h cadence), so with one account
  active on the PC and also live on the Mac, the PC's poll would steal the Mac's
  lineage and silently log it out "within a day" (CHANGELOG alpha.15 — "exactly the
  failure that made cross-machine credential sharing flaky"). **The fix is a pin**: a
  persisted hint (`settings.credentialSwitcher.macActiveProfileId`) records which
  account is live on the other machine; the poller's gate
  (`_updateSnapshotUsageUnlocked` → `:853-877`) never refreshes that account locally —
  usage for it is fetched read-only with the stored access token, and an expired token
  triggers a *pull from the Mac* (inventory sweep + strictly-newer sync-back) rather
  than a local refresh; Mac offline ⇒ skip the round, zero token-endpoint calls,
  account never marked dead. Proven by a counting-stub test (zero refresh calls with
  the hint, one without).
- **Rotation write-back**: the CLI itself rotates tokens every few hours; a watcher
  (`startCredentialWatcher:1524-1554` — `fs.watch` on the credentials dir + 30s mtime
  poll + a 3s self-write guard) matches each rotation to the owning snapshot by
  `accountUuid` and merges it **only when `expiresAt` is strictly newer**
  (`:932-974`). Without this, saved accounts silently die in ~12h.
- **Three-state token health** (`ok / unverified / needs_login`, `:48-50`): the
  reference tool they replaced marked an account dead whenever refresh returned
  nothing — but its helper returned nothing for network errors, timeouts, 429s, and
  5xx alike. The rewrite classifies by HTTP status + body: `needs_login` only on
  definitive auth rejection (`invalid_grant`, or empty refresh token + expired access
  token); transients never mark dead (`refreshInactiveToken:700-764`); imports from
  the old tool arrive `unverified` with stale dead-flags ignored; a live login
  resurrects to `ok`. This is camus C1-3's infra-≠-verdict law applied to credentials.
- **Apply is a fenced sequence** (`_applyCredentialUnlocked:1373-1480`): arm
  self-write guard → sync current account's fresh tokens back → back up both files →
  write **identity first**, **tokens last** (both atomic temp+verify+rename with
  Windows retry, `:184-213`) → post-write **verify** live identity == target, else
  roll back both. Manual-only trigger (`POST /api/credentials/apply`) — **no
  auto-switch on quota exhaustion anywhere**, a deliberate blast-radius choice.
- **Leakage hygiene**: `getSafeList` (`:1575-1605`) is the only browser-serialized
  shape — identity/label/health/usage only, tokens never; SSH mirroring (`mac-bridge.js`)
  is argv-only `execFile` with charset-allowlisted host/user (option-injection guard),
  `BatchMode=yes` + `StrictHostKeyChecking=accept-new` (TOFU on the tailnet — never
  `=no`, so a *changed* key still fails loudly), and secrets travel exclusively as
  scp'd 0600 temp files deleted after use — never on remote command lines. Quota is
  fetched from the Anthropic OAuth usage endpoint
  (`https://api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`,
  `:655-677`), mapped through a whitelist (`_mapUsageResponse:598-644` — the raw
  per-model `scope` object is extracted to a `row.model` string, never stored).

**Gap in jido_radclaw** (verified 2026-07-04): provider credentials are one env var
per provider (`core/config.ex:13-44`, read at `:183-187`) — no multi-account concept,
no rotation (grep-clean); `check_provider/1` (`config.ex:241-252`) is an auth/
connectivity probe, not a quota probe. The Forge runners sync the **single host
account** into sandboxes (`forge/runners/claude_code.ex:10,157-160,223`;
`codex.ex:45,156-159,332` — mode-600, `:no_credentials` posture) with no
account-selection layer. Usage tracking is per-agent tokens (`agent_tracker.ex:137-140`)
plus a global singleton counter (`core/stats.ex:51-52`) — nothing per-account. The
`project_forge_oauth_file_sync` memory records our doctrine: credential files are
load-bearing OAuth plumbing, never brokered — myrlin *agrees* and shows what managing
those files across machines actually requires.

**Why it matters**: FLOW §5 commits to "per-node CLI credentials follow the Forge
OAuth file-sync approach." The moment two nodes materialize the same account, the
lineage problem is live — and it will present as flaky, delayed, hard-to-attribute
logouts (their diagnosis took a dedicated incident). SY1-4 already queued
multi-account *rotation* as a borrow; MY1-1 is its missing file-mechanics half: how
snapshots, rotation write-back, and cross-node pinning actually work against the
`~/.claude` / `~/.codex` dotfile reality. The three-state health model also upgrades
XA2-3's credential canary: a canary that marks accounts dead on transient failure is
worse than none.

**Adoption sketch** (slice 2/6, or the first second-account/second-node event —
OQ-2): (a) account snapshots as Vault-encrypted rows keyed by account uuid (not
dotfiles — our store is Postgres), each carrying the token-pair + identity +
three-state health + usage projection; (b) a per-node "active account" registration
with the lineage rule enforced at the refresh site: *only the node where an account
is active may refresh it; every other node adopts strictly-newer tokens from the
sync* — our cluster makes the pin a DB row instead of an SSH-probed hint; (c) the
rotation write-back watcher becomes part of the Forge credential-sync loop (watch the
host dotfiles the runners already read, merge strictly-newer into the Vault row);
(d) apply = identity-first/tokens-last with post-write verify, wrapped in our usual
transactional retry; (e) `check_provider/1` grows the usage-endpoint probe (auth +
quota) with C1-3-style outcome classification. Keep manual-only switching until a
rotation policy earns its way in (SY1-4's rotation strategies are the follow-on).

### MY1-2. Cross-session file-conflict detection — two detector shapes, and the dead-push correction

**Recommendation**: BORROW-REFERENCE (the detector contracts; ours becomes a DB
query) + a **scan/FLOW-citation correction** that keeps argus §12 honest.

**Where in myrlin**: two detectors, both path-level ("same file touched by ≥2
sessions"), deliberately different sources:

- **Detector A — transcript-derived** (`GET /api/conflicts`, `server.js:8250-8283`):
  for every `running`/`idle` session with a transcript id (`:8212-8214`), read the
  **last 50KB** of its provider JSONL, collect `tool_use` blocks named `Edit`/`Write`,
  take `input.file_path || input.path`, normalize (slashes; lowercase on win32)
  (`:8173-8191`); flag any path claimed by ≥2 sessions (`:8266-8273`). 30s server
  cache. Spawns nothing — this is the detector the 60s background poll uses.
- **Detector B — git-status** (`GET /api/workspaces/:id/conflicts`,
  `server.js:8294-8404`): `git status --porcelain` per running session's
  `workingDir`; skip deletions, unwrap renames; same ≥2 rule. Wrapped in a
  **15s TTL promise-cache** (`git-status-cache.js`) that shares the in-flight spawn
  among concurrent callers, caches failures on purpose (non-repo dirs stop
  re-spawning), and is **eagerly invalidated when any mutating git command flows
  through the `gitExec` chokepoint** (`invalidateIfMutating:129-133`, wired at
  `server.js:6468`; git typed in a terminal pane is covered by TTL alone — tradeoff
  documented in-module). Runs only while the Conflict Center is open (a Windows
  console-flash incident gated it; CHANGELOG alpha.13).
- **Consumption**: web Conflict Center (`app.js:20905-21005`) — per-file cards with
  session chips (click → focus that terminal), new-conflict toasts deduped by file
  key, amber per-pane badges; **"Auto-resolve" stops every conflicting session not
  currently open in an active pane** — active-pane sessions render "Protected" with a
  lock and are never killed (`:20931-20959`). Mobile polls Detector A every 30s and
  can only navigate to a session.
- **The correction**: the push named for this — `fileConflicts` — **cannot fire**.
  `push.js:353-363` listens for `store.emit('conflict:detected')`, which has **no
  emitter anywhere** (grep-clean; the listener's own comment hedges "if the event
  exists in the system"). No SSE conflict event exists either (`useSSE.ts:21-37`).
  Conflicts are **poll-only** in the product that named the trigger.

**Gap in jido_radclaw** (verified 2026-07-04): nothing compares file modifications
across concurrent agents — grep-clean (seams pass); `git status` appears only in two
single-cwd uncached tools (`tools/git_status.ex:23`, `tools/project_info.ex:56`).
FLOW §12 adopted "`fileConflicts` from merge-backs (myrlin)" as an attention trigger
and FLOW §6 gives conflicts to the parent agent — the *detector* feeding that trigger
is unbuilt and now has its reference.

**Why it matters**: three things. (1) **Our Detector A is a query, not a scrape** —
Claude tool calls are durable `Conversations.Message` rows (`role: :tool_call`), so
"which paths did ≥2 live threads touch" is a Postgres query over structured data
myrlin has to regex out of JSONL tails; the 50KB-tail recency window, the
path-normalization rule, and the ≥2 threshold are the contract worth keeping. (2)
Detector B's cache discipline — TTL + in-flight sharing + failure caching + **eager
invalidation from the mutating-command chokepoint** — is exactly the shape for any
worktree dirty/status polling argus slice 2 adds (we already route mutations through
gated tools; the invalidation hook is free). (3) The Auto-resolve-kills-sessions UX
is our **contrast**: FLOW §6 makes conflicts agent work surfaced as attention;
myrlin's "stop the other sessions, protect the focused one" is what the platform
does when there's no agent to hand the conflict to. Record, don't copy.

**Adoption sketch**: slice 2 (worktree diffs) / slice 5 (merge-back attention):
(a) an overlap-advisory read-model — `SELECT path FROM tool-call rows of live threads
GROUP BY path HAVING count(DISTINCT thread) >= 2`, windowed to recent activity,
surfaced as a FLOW §12 attention item (never a gate — OR1-2's warning-only advisory
is the sibling precedent, and OQ-1 holds the design questions); (b) worktree
git-status polling adopts the promise-cache + eager-invalidation-from-gated-git
shape; (c) FLOW §12's citation gains its asterisk (done this dig — the trigger
stands, its originator's wiring doesn't).

### MY1-3. Delivery rules from the notification-storm incident — the three the corpus stack lacks

**Recommendation**: BORROW-PATTERN. A paid-for incident (alpha.10, four compounding
root causes diagnosed with process traces) whose fixes extend the EM/TM/XA delivery
stack argus §12 already adopted.

**Where in myrlin**: the storm — "ready for input" toasts and dings on every tab
switch and output burst. The four fixes (`terminal.js` + `app.js`, all test-gated in
`test/idle-notification-gating.test.js`):

- **Edge-triggered re-arm with a minimum-signal floor**: idle-notification re-arm was
  level-triggered — any output byte (Ink border repaint, spinner tick, SIGWINCH
  redraw) re-armed it. Now a flushed chunk must contain ≥ `MIN_REARM_CHARS` (24)
  **visible characters after ANSI-strip** to count as new work (`terminal.js:1451`);
  the 2s idle debounce is unchanged.
- **Replay suppression**: the server replays up to 100KB of scrollback on every
  (re)connect; that replay used to flow through the detector and re-fire attention
  ~2s after every page load or tab-group switch. Now `ws.onopen` arms a
  `REPLAY_SUPPRESS_MS` (3s) window during which the completion detector is disarmed
  (`terminal.js:1474,681`).
- **Focus acknowledgement consumes pending state**: viewing a pane now *consumes* its
  needs-attention state (refreshes the per-session dedupe entry, marks the idle cycle
  notified, clears the amber badge); the active-surface suppression comparison is
  re-pointed on every tab-group switch so it never suppresses against a stale slot
  (`app.js` — `setActiveTerminalPane`, `switchTerminalGroup`).
- **Caps on the residue**: per-pane refire cooldown (`IDLE_REFIRE_COOLDOWN_MS` 30s),
  per-session dedupe (`SESSION_NOTIFY_DEDUPE_MS` 60s, reset by genuine activity),
  chime cooldown (5s) with one shared reused AudioContext (browsers cap concurrent
  contexts; the storm was breaking tab audio).

**Gap in jido_radclaw** (verified 2026-07-04): no attention read-model exists (CC1-2,
re-confirmed by the seams pass at HEAD — LoopGuard halts, cron failures, and Forge
`:needs_input` still reach no operator surface); the FLOW §12 delivery-rule list
(transition-edge dedupe, active-surface suppression, per-key debounce, caps) does not
yet include replay suppression, focus-ack-consumes, or a minimum-signal floor.

**Why it matters**: argus's live layer is Channels + a durable catch-up feed
(`workflowEvents(afterSeq:)`) — **reconnect replay is a designed, frequent event** on
a phone client. Without the replay-suppression rule, every reconnect re-delivers the
events the attention projector derives from, and the storm reproduces on our stack
with different nouns. Focus-ack is the other half of emdash's active-surface
suppression: suppressing delivery isn't enough if viewing doesn't *consume* the
pending state (the badge re-fires on the next transition). The min-signal floor
translates directly: attention re-arms on substantive new activity (a new tool call,
a status change), never on heartbeats/telemetry ticks.

**Adoption sketch**: fold into the slice-1 attention design as three named rules
beside the EM/TM/XA set: (a) attention derivation is suppressed for events replayed
during catch-up (the projector keys on event seq ≤ the reconnect head, or an explicit
replay flag on the channel frame); (b) marking a thread/item viewed consumes its
pending attention state atomically with the read; (c) re-arm requires a
substantive-event predicate (kind allowlist), not any-event. Cite the incident as the
justification; the counting-stub test pattern (zero re-fires across a
reconnect+replay) travels with it.

*(Connective note, 2026-07-04 pass: the corpus's final dig supplied the server-side
half — OpenHelm's storm mechanics (semantic dedup keys, touch-in-place escalation,
incident collapse, guaranteed escalation with a never-vanish fallback row —
[OH2-2](../openhelm/FEATURES-WORTH-BORROWING.md)) cite this entry as the device-side
complement, with bosun's BO1-3 immediate-vs-digest split as the aggregation layer
between them. README observation 10 assembles the three into the slice-1 stack.)*

### MY1-4. The enrollment ladder — QR pairing, device tokens, and two gaps (theirs shipped-broken, ours never-built)

**Recommendation**: BORROW-PATTERN (the token ladder + device registry semantics) for
OVERVIEW §4.4's client-enrollment story, with the pairing-429 as the enforcement-rot
cautionary and our zero-minting-flow gap as the do-now.

**Where in myrlin**: a four-rung ladder, each rung scoped and expiring tighter than
the last:

1. **Password** (shared, single) — env > `~/.myrlin/config.json` > auto-generated
   16-byte base64url (`auth.js:125-161`); login is constant-time-compared
   (`:296-300`), rate-limited 5/IP/60s, and returns a 64-hex bearer held in an
   **in-memory Set** (browser tokens die with the process; only device tokens are
   reloaded, `:540-557`).
2. **Startup token** — one-time, single-use, 60s TTL, embedded in the printed launch
   URL so the local browser auto-logs-in without the password ever transiting; the
   token is stripped from the URL bar after exchange (`auth.js:28,324-388`).
3. **Pairing token** — minted only by an already-authed session
   (`GET /api/auth/pairing-code`, requireAuth), 32-byte hex, **5-minute TTL,
   single-use** (`pairing.js:21,135-140`). The QR encodes a JSON blob, verbatim:
   `{url, urls: {local, lan, tailscale, tunnel, custom}, primaryUrl, pairingToken,
   serverName, version}` (`:150-157`) — **every candidate server URL rides the QR**
   (LAN detection skips Tailscale CGNAT 100.x; a separate detector targets it), so
   the phone can pick the reachable one.
4. **Device token** — pair consumes the pairing token (reuse → 403) and mints a
   90-day bearer bound to a device row: `deviceId`, name, platform, `pairedAt`,
   `lastSeenAt` (debounced ≤1/60s), `expiresAt`, `pushToken`, `pushPreferences`,
   plus a `capabilities` object in the response (`pairing.js:228-273`). Devices are
   listed with online status (live SSE connection), renamable, and **revocable** —
   revoke removes the token from the active set, force-closes matching SSE
   connections, and deletes the row (`device-manager.js:251-281`); `POST
   /api/auth/refresh` rotates the token keeping the deviceId (`auth.js:459-474`).

**The cautionary, read-verified (not executed)**: `POST /api/auth/pair` — the public
rung — **always returns 429 at HEAD**. A refactor made `isRateLimited` return a
structured object (`{limited, retryAfter}`, `auth.js:45-61`); the three auth call
sites were updated to read `.limited` (`auth.js:274,328,429`), but `pairing.js:173`
still treats the always-truthy object as the boolean. `test/pairing.test.js:215`
asserts a valid pair returns 200 — the test exists and would fail, so it evidently
doesn't gate releases. Fresh devices cannot enroll at v1.2.0. This is pad PD1-1's
advertisement-rot lesson at the auth layer: a contract asserted but not mechanically
enforced on the release path is a contract that drifts.

Two more cautionaries for our channel design: SSE and the terminal WS authenticate
via **query-param tokens** (`server.js:5963-5973`, `pty-server.js:64-70`) because
EventSource/WebSocket can't set headers — and the request logger writes
`req.originalUrl` including the query, so bearer tokens land in `server.log`. And
auth is **per-route** (`requireAuth` appears 141×; there is no blanket `/api` gate) —
an endpoint that forgets the middleware is public by default. Our Phoenix pipelines
are the blanket-gate shape already; keep it that way.

**Gap in jido_radclaw** (verified 2026-07-04, seams pass): `ApiKeyAuth` validates
Bearer/x-api-key per-user (`web/plugs/api_key_auth.ex:41-58`) and `ApiKey` is a real
hashed resource with revoke and optional expiry (`accounts/api_key.ex:24-64`) — but
**`ApiKey.create` has zero callers in `lib/`, there are no auth/key mix tasks, and no
setup-wizard or UI path mints one**: creating a key today means calling the code
interface from IEx. `UserSocket` accepts only session-cookie auth
(`user_socket.ex:13-18`) — a headless client cannot open the WS with a key (OVERVIEW
§4.4 already plans extending it). No pairing/short-lived-token/QR concept exists
(grep-clean).

**Why it matters**: OVERVIEW §4.4 settled on a single API key gated by the tailnet —
fine — but the *issuance* story is empty on our side, and myrlin's ladder is the
right shape for it: mint-from-an-authed-surface, short single-use handoff artifact,
long-lived per-device credential with a visible revocable registry. The multi-URL QR
payload is directly reusable thinking for a tailnet: MagicDNS + LAN + tunnel
candidates in one enrollment artifact. Per-device keys (vs one shared user key) also
give revocation a blast radius that matches the threat model (a lost phone ≠ rotate
everything).

**Adoption sketch**: (a) **do-now, argus-independent**: a `mix jidoclaw.api_key`
task (create/list/revoke against `Accounts.ApiKey`) — closes the zero-minting gap for
the surfaces that already exist; trivially testable. (b) Slice 1: per-device ApiKey
rows (name/platform/last_used_at already fit the resource's shape; add a
`device_name`), minted through a pairing flow — authed surface generates a
single-use, minutes-TTL pairing artifact (QR with MagicDNS + fallback URLs +
pairing token); the client exchanges it for its device key; registry + revoke in the
argus UI. (c) Keep tokens out of URLs: Phoenix Channels take params in the join
payload — use that; if any SSE-ish surface ever needs a query token, scrub it from
request logging first. (d) Pin the pair path with an end-to-end test that runs in CI
— the 429 lesson.

---

## Tier 2 — lands with a specific argus slice

### MY2-1. Spinoff's promote-the-edit — the field's third, and the severed-consumer lesson

**Recommendation**: BORROW-REFERENCE (as §5.4 acceptance criteria). Corrects pms
observation 1(b) a **third** time, and sharpens it in a way Chorus and orca didn't.

**Where in myrlin**: "Spinoff Tasks" on a session → `POST
/api/sessions/:id/extract-tasks` reads the transcript tail (~150KB), condenses it
(first 3 user messages + last 15, <8KB), and runs a **`claude --print` one-shot**
(90s timeout) prompting for 1–6 independent tasks as JSON — `title, description,
relevantFiles, acceptanceCriteria, branch` — parsed, capped, sanitized
(`server.js:4679-4794`). The review modal renders per-task cards: **title and
description are editable; branch, files, and criteria are static**; per-task include
checkboxes (`app.js:7674-7758`). Edits write into the client array verbatim; submit
sends the edited specs to `spinoff-batch`, which creates worktree tasks — **the model
is never re-invoked** (`app.js:7773-7820`, `server.js:4945-5065`). Plan-layer
promote-the-edit, shipped.

**The lesson**: the promoted spec **has no consumer**. `spinoff-batch` flattens
title/description/criteria into the task record's `description` (`server.js:4966`)
and creates the session **without an `initialPrompt`** (`:5015-5021`) — the spawned
agent starts blank; the operator's edited spec is display data on a kanban card. The
manual New-Task path *does* wire `initialPrompt` through to first launch
(`server.js:6840-6848` → `pty-manager.js:864-866`), so the wiring exists one path
over — and the rich context-handoff endpoint the README's roadmap describes
(`/spinoff-context`, a full markdown package with file snippets + git history,
`server.js:4805-4936`) is **never called by the UI**. The killer feature's promotion
is severed from execution.

**Gap in jido_radclaw** (verified 2026-07-04; gate files untouched by the one commit
since the Chorus dig's same-day verification): gates remain approve/reject/abandon
with verbatim re-emission — `GateResume` seeds only the decision atom
(`gate_resume.ex:278-284`), the plan gate re-emits the original from its ref
(`reactors/plan_gate.ex:53-79`). OVERVIEW §5.4 designs the edit path; CH1-1 supplied
approve-idempotency + revision-history acceptance criteria.

**Why it matters**: argus §5's promote-the-edit is only novel *because* the promoted
revision is what the next step consumes. Myrlin demonstrates the failure mode where
promotion succeeds and consumption silently doesn't exist — invisible in the editor
UX, only visible end-to-end. Add to CH1-1's §5.4 acceptance criteria: **an
end-to-end test asserting the resumed step's actual input equals the head revision's
bytes** (not merely that the revision row was written). Their editable-vs-static
field split (title/description editable; branch/files/criteria locked) is also a
reasonable per-field-editability precedent for typed editors (§5.3).

### MY2-2. Task schema + board mapping — FLOW §7 datapoints, mostly negative space

**Recommendation**: BORROW-REFERENCE (the mapping layer + two-terminal-status
evidence) + four recorded negatives for slice 3's schema review.

**Where in myrlin**: the worktree task (`store.js:1664-1690`): `wt_` + 8-hex id,
`workspaceId`, `sessionId` (null in backlog), `branch`, `worktreePath` (null in
backlog), `baseBranch` ('main'), `description` (flat string — spinoff's structured
fields are flattened into it), `model` (per-task), `tags[]`, `status` (**default
`running`** — tasks are born executing unless `startNow:false`), `blockedBy[]`,
`history[{status,at}]`, `createdAt/completedAt`. **Statuses map to columns through a
layer** (`app.js:6801-6816`): five columns (Backlog/Planning/Running/Review/Done)
over seven written statuses — Done folds `merged` + `completed` + `rejected` (badge
distinguishes), and read-aliases (`active→running`, `pending→backlog`,
`exploring→planning`) absorb legacy values; drag-drop writes canonical statuses back
1:1 (`:7070`). Card movers: human drag (free-form), session-stop → `review`
(`server.js:1526-1532`), merge → `merged` (`:6944`), reject → `rejected` (`:6992`),
PR-refresh-detects-MERGED → `completed` (`:7161-7164`) — **the last only on a manual
"Refresh PR Status" click; no poll, no webhook**.

**The negatives, all verified**: (1) `blockedBy` is **inert** — rendered as badges
and editable via context menu, consulted by nothing; the only gate on entering
Running is the concurrency cap; the server never reads it. The corpus's **fourth**
dead-dependency-links subject (multica's `issue_dependency`, pad's `blocks`, and the
feature-board lineage before it). (2) The concurrency cap (default 4, range 1–8) is
**client-side only** — three UI checks (`app.js:7078-7088,7410-7418,7792-7802`),
refuse-not-queue, direct API bypasses it entirely. (3) **No provenance** — no
creator/actor field anywhere; spinoff origin is inferable only from a tag. (4) The
whole subsystem ships **off by default** (`WORKFLOWS.md:283`), and the frozen mobile
client's types diverge from the store (invents `done`, omits `merged/rejected`,
renames `blockedBy`→`blockers` with a different meaning — `mobile/types/api.ts:452-493`).

**Gap in jido_radclaw** (verified 2026-07-04): no task resource (seams §4, expected);
FLOW §7 designed statuses/lanes/kinds, computed-blocked, provenance-in-the-row, and
server-side automation budgets.

**Why it matters**: every myrlin negative is a FLOW §7 decision validated from the
failure side — statuses-over-display-groups is their mapping layer grown ad hoc
(ours is designed); `merged` vs `completed` from two landing paths is direct evidence
that **multiple done-kind statuses are real** (quick-merge vs PR-merge — FLOW §10's
two paths will produce exactly this pair; the kind layer absorbs it where their
column-fold + badge patches over it); computed-blocked beats stored-inert;
provenance must be in the row (their spinoff-tag inference is the counterexample);
caps and dependency gates belong on the resource (BO1-4's rule, their client-only
cap the counterexample); and merge-detection needs the webhook (our §10 design)
rather than a human-clicked refresh.

**Adoption sketch**: slice 3 schema review checklist additions — born-status is an
explicit argument never a hardcoded `running`; every terminal disposition maps to a
done-or-canceled kind; caps/dependency release enforced in Ash actions (changes +
policies), UI merely mirrors.

### MY2-3. Worktree mechanics — sibling-dir template, reuse-don't-fail collisions, init hooks

**Recommendation**: BORROW-REFERENCE for FLOW §4 (templates) / §5 (provisioning +
teardown), one genuinely different collision posture worth recording.

**Where in myrlin**: creation (`server.js:6751-6801`): worktree path =
`<dirname(repoRoot)>/<repoName>-wt/<branch with '/'→'-'>` — a **sibling directory
per repo**, keeping checkouts out of the repo; branch = `feat/` + 40-char slug
(`app.js:7382-7386`) or the spinoff AI's kebab suggestion re-prefixed. **Collisions
reconcile instead of failing**: parse `git worktree list --porcelain`; exact path
already registered → reuse it; branch checked out in a *different* worktree →
redirect the task to that existing checkout and skip the add (`:6764-6801`). (The
spinoff path lacks this reconciliation and can fail on collision — same-repo drift,
the single-source lesson.) Provisioning: **init hooks** — `copy_files` (relative
paths copied root→worktree) + `init_script` (shell, worktree cwd, 30s timeout,
non-fatal) (`:6803-6834`), operator-configured, default empty. Teardown: merge
(requires `review`; squash or `--no-ff`; optional push; **non-force** worktree
remove; branch `-D`/`-d`) vs reject (**`--force` remove + `-D`**) vs record-delete
(**touches no git — strands the worktree and branch**, `:7004-7009`); no
reconciliation between task records and `git worktree list` exists.

**Gap in jido_radclaw** (verified 2026-07-04): no worktree code at all (OVERVIEW
A.2); FLOW §4 designed branch+directory templates with a `-{n}` collision counter;
FLOW §5 designed phased, dirty-checked deletion and idempotent provisioning steps.

**Why it matters**: the collision posture is a real fork in the road — FLOW §4's
`-{n}` counter *allocates a new identity* on collision; myrlin *reconciles to the
existing one* (attach to the checkout that already has the branch). For
operator-initiated "continue this branch" flows, reconcile-first is arguably the
better UX (it's FLOW §5's attach-existing arriving through the creation path);
for automation, fresh identities are safer. Worth an explicit line in the slice-2
design rather than inheriting whichever we build first. Init hooks confirm the
EM1-1/OR1-4 provisioning shape (copy-files + script, per-project, non-fatal) at a
third subject; record-delete-strands joins orca's force-delete as the corpus's
teardown anti-references — two opposite failure modes (destroy unmerged work vs
leak checkouts forever) that FLOW §5's phased+dirty-checked deletion is the answer
to.

### MY2-4. Push delivery mechanics — and the 5-declared/2-live taxonomy gap

**Recommendation**: BORROW-REFERENCE (the mechanics that work) + the corpus's
sharpest declared-vs-wired cautionary for §6.2's wiring slice.

**Where in myrlin**: the declared taxonomy is five per-device preference booleans
(`sessionComplete, sessionNeedsInput, fileConflicts, taskReview, serverOnline` —
minted at pairing, `pairing.js:241-247`). The live truth (`push.js:281-364`, verified
producer-by-producer): `session:complete` fires on the store's running→stopped
transition; `task:review` fires when a task enters review; **`sessionNeedsInput` is
wired but unsatisfiable** (it greps the last session log line for "needs input"/
"waiting for" — no code writes those strings; the real needs-input detector lives in
the browser and never posts to the server); **`fileConflicts` listens for an event
with no emitter** (MY1-2); **`serverOnline` has no listener at all**. Two of five
fire — and they are exactly emdash EM1-3's two triggers (finished + waiting-on-your
-review), independently re-derived. Mechanics worth keeping: per-device Expo tokens
with **ticket-based `DeviceNotRegistered` pruning** (clear token + unregister,
`push.js:414-426`; no receipts phase — honest gap), 3-attempt exponential-backoff
send, a **2s per-device batch window** that coalesces bursts into one "N updates"
summary (`:97-99,536-597`), iOS badge = running-session count, `data.route` deep
links on every payload. The negatives: no severity, no quiet hours/daily caps, no
foreground suppression (banner *and* toast), the mobile tap handler ignores
`data.route` and switches on `data.type` with one route typo'd (`usePush.ts:136-160`
— `/data/tasks`), and **no UI writes the preference booleans** (the visible
All/ErrorsOnly/None control is device-local MMKV that gates nothing) — every device
runs pairing defaults forever.

**Gap in jido_radclaw** (verified 2026-07-04): zero push infrastructure of any kind
(seams §1, grep-clean); OVERVIEW §6.2 holds the designed trigger set; CH2-3 queued
per-kind preference toggles.

**Why it matters**: for slice 1's Web Push build, the transferable mechanics are the
per-device subscription row + prefs (CH2-3's shape confirmed a second time),
batch-coalescing bursts into a summary push (bosun BO1-3's digest, at the
transport layer), and prune-on-provider-rejection. The taxonomy gap is the lesson
with teeth: **a trigger taxonomy is only as real as its producers** — myrlin declared
five, shipped two, and nothing (UI, tests, docs) surfaces the difference. Argus's §12
set is richer than anything scanned; wire each trigger to a named producer with a
test, or don't declare it.

### MY2-5. Client catch-up discipline — events invalidate, refetch pulls truth; offline mutation queue

**Recommendation**: BORROW-PATTERN (client-side rules for the argus SPA/mobile,
slice 1).

**Where in myrlin**: the SSE protocol itself has **no catch-up** — no event ids, no
`Last-Event-ID`, no replay buffer; missed events are simply lost
(`server.js:5963-6129`). The mobile client compensates with a rule stated in code:
**"SSE events NEVER mutate state directly; they only mark queries stale"**
(`useSSE.ts:21-37,66-79` — every event type maps to TanStack Query invalidations;
the refetch pulls current truth), which makes lost events harmless staleness instead
of divergence. Writes get the mirror-image rule: on network failure, mutations queue
to MMKV and return `{queued:true}`; the queue replays on reconnect and drops an
entry after 3 failed retries (`api-client.ts:111-119`, `offline.ts`). Bursty
per-session streams (the mirror) are **scoped to the requesting device's SSE
connection**, never broadcast (`server.js:6057-6074`).

**Gap in jido_radclaw** (design-stage): argus §4.2 already chose minimal channel
payloads + GraphQL refetch and a durable `workflowEvents(afterSeq:)` feed — stronger
than myrlin's transport on every axis. What §4.2 doesn't yet state are the **client**
rules: never apply channel payloads directly to the cache (invalidate + refetch
keyed by id), queue-and-replay offline mutations with a bounded retry, scope
high-volume per-entity streams to their subscriber.

**Why it matters**: our durable feed prevents *loss*; the invalidate-don't-mutate
rule prevents *divergence* (a client that half-applies deltas after a missed window
shows fiction). It also composes with MY1-3's replay suppression: refetch-on-
invalidate is idempotent by construction, so replayed events can't double-apply.
Cheap to adopt as written rules in the slice-1 client design; expensive to retrofit
after a cache-consistency bug.

### MY2-6. Scheduler skip-and-record — FLOW §8's overlap policy, shipped small

**Recommendation**: FOLD-IN (evidence line for FLOW §8; one detail worth keeping).

**Where in myrlin**: the per-session scheduler (fires shell text into an existing
PTY) records every non-fire as a **history row with a reason** — session not running
⇒ `status:'skipped', skipReason:'session-not-running'`; boot recovery marks missed
one-shots `'missed-while-down'` and advances recurring schedules to `now+delay`
**without catch-up**; consecutive skips collapse into one counted row; history caps
at 50/session; schedules purge when their session is deleted
(`scheduler.js:194-346`). Recurring re-arms *after* the fire completes, so a
schedule can't overlap itself.

**Gap in jido_radclaw** (verified 2026-07-04): our cron failure path is
log-and-auto-disable with no operator surface (`cron/worker.ex:42,236-247` — part of
CC1-2's gap); FLOW §8 designed skip-the-tick-and-record-visibly with a breaker.

**Why it matters**: third independent confirmation of skip-and-record (multica's
visible-skip, symphony's reconcile loop, now myrlin at the small end), and the
**consecutive-skip collapse** is a detail FLOW §8 should keep — a paused session's
recurring schedule generates one collapsing row, not an unbounded skip log; our
attention feed wants the same compression (N skips since <t>, one item).

---

## Tier 3 — garnish

### MY3-1. JSONL tailer + mirror discipline
Byte-offset incremental tailing with the parent-**directory** watched (file handles
die on Windows delete/recreate) + 2s fstat poll fallback; 4MB positioned reads; a
**NUL-framed oversized-line sentinel** (a >2MB line is dropped and marked, never
buffered); UTF-8-safe carry (only decode up to the last newline); truncation ⇒ reset
offset to `size-2MB` + re-seed; refcounted watchers keyed `provider:sessionId` with
caps (10 watchers, 60s idle grace, vanished-subscriber sweep); liveness = artifact
mtime < 2min, **labeled honestly in the UI as an mtime heuristic** ("transcript
recently written", not process-alive) (`jsonl-tailer.js`, `mirror-service.js`,
CHANGELOG alpha.16). Reference-grade if the slice-6 CLI adapter ever tails on-disk
transcripts (our Forge pipes stdout, so likely contrast); the honest-liveness-label
rubric travels regardless.

### MY3-2. PTY viewport ownership
One PTY shared by N clients: geometry has an **owner** — claimed by typing or an
explicit `activate`, never by a bare resize; non-owner resizes are stored, not
applied; owner-disconnect promotes the most recent active client and restores its
stored viewport; `{type:'reset'}` precedes every scrollback replay so clients
converge (`pty-manager.js:262-297`; CHANGELOG alpha.10 — the "desktop terminal stuck
in mobile mode after a phone viewed it" fix). The reference for FLOW §11's operator
terminal once it's viewable from two devices (slice 8).

### MY3-3. Danger-keyword asymmetry in auto-trust
The frontend auto-trust that auto-answers "safe" CLI prompts has a floor: a prompt
containing `delete|remove|credential|secret|password|key|token|destroy|format|drop|
wipe|overwrite` is **never** auto-answered regardless of the setting
(`terminal.js:1586-1601`); enabling the dangerous bypass flag requires a confirm
modal while disabling it is one click (CHANGELOG alpha.4). Both halves are rubric
material for XA OQ-1's standing-grants design: hard-block lists override
convenience, and friction is asymmetric (dangerous-enable expensive,
dangerous-disable free).

### MY3-4. Cost/usage honesty rubric
Unsupported provider ⇒ "—" with "Cost not tracked", **never $0.00**; aggregates
disclose "(Claude only)"; the usage meter labels Opus/Sonnet bars **weekly** because
the endpoint has no per-model hourly window — "never presented as hourly"
(CHANGELOG alpha.0/alpha.14). The display-side sibling of camus C1-4's honest
terminal statuses; adopt as review rubric for any argus cost/usage surface.

### MY3-5. Crash-loop hard-stop
After 5 sub-1500ms crashes the supervisor writes `logs/needs-manual-review.lock` and
**refuses to restart until a human deletes it** — a scar from an incident where a
crash-looping process's startup path was evicting the clean backups recovery needed
(`supervisor.js:126-141,187-210`). OTP gives us `max_restarts` natively
(ALREADY-COVERED for supervision), but the *lesson* is distinct: when a restart loop
can consume the recovery material itself, the breaker must be a persistent latch a
human clears, not a counter that resets. Worth one line in any future
Forge-recovery/backup design.

### MY3-6. Grep-gate CI fences
Three shipped source-scan tests: zero provider string literals outside
`src/providers/` (with explicit `// gsd:provider-literal-allowed` markers), every
server-side `child_process` call site carries `windowsHide` (with a pattern-rot
floor), every consumed CSS custom property is defined (with an audited allow-list).
The same mechanical-enforcement family as PD1-1 and our reach/ExSlop gates —
recorded as precedent that seam boundaries (a provider abstraction, a spawn-option
invariant) can be cheaply CI-fenced by grep when types can't express them.

---

## Skip / Already Covered

- **S-1. The product as a control plane** — SKIP. AGPL aside: single-host by design,
  JSON-file store, shared-password auth, client-side enforcement; argus's server
  substrate (events, gates, leases, tenancy) is the opposite bet, kept.
- **S-2. Frontend state-scraping (idle/needs-input detection)** — SKIP as mechanism
  (regex lists over a 200-char ANSI-stripped tail vs our structured Forge
  `:needs_input`/lifecycle events); MY3-3's danger floor is the one rubric
  extracted. The purest confirmation yet of the ades-corpus asymmetry argus is built
  on.
- **S-3. Refocus (auto-distill → `/clear` → fixed reinject prompt)** —
  ALREADY-COVERED by `Reasoning.Compactor` (native, per-agent-keyed, durable
  snapshots, request-transformer trim); theirs is the PTY-shaped approximation.
  Notably it is *automated* distillation — the human never edits the distilled
  context, so it's not a §5 hit.
- **S-4. Read-only session mirror as a product need** — ALREADY-PLANNED differently:
  argus renders transcripts from the Recorder's durable rows + the planned channel
  bridge (OVERVIEW §4.2/A.3); myrlin mirrors *foreign* sessions it doesn't own —
  a problem argus doesn't have (every session is ours). Tailer mechanics preserved
  as MY3-1.
- **S-5. Mac bridge as a multi-machine story** — SKIP: it mirrors credential files,
  not work; our fabric is Erlang dist + shared Postgres. Its credential content is
  MY1-1; its SSH hygiene rubric rides along there.
- **S-6. JSON-file store disciplines** (PID-unique temp+rename, zero-fill detection,
  3-tier backup retention, shape-drift save guard) — SKIP as machinery (Postgres);
  the shape-drift guard ("refuse to save a state that 10×'d or filled with
  test-shaped names") is a cute test-pollution fence our Ecto sandbox makes moot.
- **S-7. The TUI, 13 themes, icon pickers, pane-view system, PWA shell** — SKIP
  (product surface; their PWA ships a 3-line no-op service worker and no web push —
  the "PWA" scan credit was installability only).
- **S-8. td integration** — SKIP (an external per-repo task CLI bridged read-mostly
  into the sidebar); one line worth keeping: td's pitch includes "implementer can't
  approve own work" — session-isolation for review, the camus C1-2 verifier-
  authority instinct appearing in a CLI task tool.
- **S-9. Supervisor/watchdog belt-and-suspenders** — ALREADY-COVERED by OTP
  supervision + BO1-2's off-process sentinel pattern; kept detail: their watchdog's
  false-death fix (require 3 consecutive missed HTTP probes AND a raw TCP
  port-probe, because the kernel completes handshakes for a live-but-blocked event
  loop) is a nice liveness-probe subtlety, and MY3-5 carries the hard-stop lesson.
- **S-10. Two-tier agent orchestration doctrine** (CLAUDE.md: orchestrator/worker
  only, "NO middle management", phase gates, contract-first) — ALREADY-COVERED in
  enforcement terms: our spawn-depth cap defaults to exactly this
  (`spawn_agent_max_depth: 1`, `tools/spawn_agent.ex:310-334`) and the composer owns
  phase sequencing; noted as independent convergence, their version being prose
  discipline where ours is a runtime invariant.

---

## Dig-brief dispositions (the standing questions, answered)

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) (second-wave myrlin paragraph + the
cross-cutting six) — disposition ∈ answered / contradicted / absent.

**Myrlin-specific:**

1. **Per-event push-subscription taxonomy, especially `fileConflicts`** — ANSWERED,
   with the dig's headline correction: the five-key per-device preference taxonomy
   exists exactly as scanned (`pairing.js:241-247`), but **only two events fire**
   (`session:complete`, `task:review`); `fileConflicts` listens for a store event
   with no emitter, `sessionNeedsInput`'s producer condition is unsatisfiable (the
   browser-side detector never reaches the server), `serverOnline` has no listener.
   The conflict-detection *mechanics* the brief wanted are real and referenced
   (MY1-2: transcript-derived + git-status detectors, both path-level ≥2-sessions,
   poll-only). FLOW §12's myrlin citation corrected this dig (trigger kept, sourced
   honestly).
2. **Task-spinoff's editable spec forms** — ANSWERED + sharpened (MY2-1): shipped
   (README's "Coming Soon" is stale), promote-the-edit confirmed (edits go verbatim
   into the created tasks, model never re-invoked — plan-layer promote #3 after
   Chorus/orca), and the sharpest finding: **the promoted spec never reaches the
   spawned agent** (no initialPrompt on the spinoff path; the rich handoff endpoint
   is UI-dead). Agent-created-tasks provenance: none stored (a `spinoff` tag only).
3. **QR-pair device enrollment + Bearer tokens** — ANSWERED (MY1-4): the four-rung
   ladder verified end-to-end in source, device registry with revocation + refresh
   rotation confirmed — and CONTRADICTED at the last rung: the public pair endpoint
   always 429s at HEAD (missed call site in a helper refactor; the asserting test
   exists but evidently doesn't gate). Read-verified, not executed.
4. **Worktree-task board column semantics + concurrency caps** — ANSWERED + corrected
   (MY2-2): five columns over seven statuses through an explicit mapping layer (scan's
   "columns ARE worktree states" was approximately right, imprecise — Done folds three
   terminal statuses; three read-aliases absorb legacy values); caps confirmed 1–8
   default 4 but **client-side only**, refuse-not-queue, API-bypassable; the whole
   board ships off by default.

**Cross-cutting (every dig):**

1. **§5 edit-and-resume sweep** — ABSENT at the execution layer, verified across all
   four readers (mirror read-only; resume replays scrollback + live stdin only;
   `initialPrompt` first-launch-only; merge/reject approve finished branches; the
   auto-generated refocus doc is never human-edited). **Twenty-third subject verified
   empty.** Plan layer PRESENT (MY2-1) with the severed-consumer nuance.
2. **Provisioning lifecycles** — ANSWERED, thin (MY2-3): worktree init hooks
   (`copy_files` + `init_script`, 30s, non-fatal, operator-configured, default
   empty); no setup-state tracking, no toolchain detection (orca keeps that crown),
   no secrets materialization; tasks with `startNow:false` defer all provisioning
   until started.
3. **Branch/directory naming** — ANSWERED (MY2-3): branch `feat/<40-char-slug>` (or
   AI-suggested kebab re-prefixed); directory `<parent>/<repo>-wt/<branch-sanitized>`
   sibling tree; collisions **reconcile** (reuse path / redirect to the checkout
   already holding the branch) rather than allocate `-{n}` — the recorded contrast
   with FLOW §4's counter.
4. **Status/attention taxonomies** — ANSWERED (MY2-2, MY2-4, MY1-3): status→column
   display mapping with dead read-aliases; two terminal statuses from two landing
   paths; push taxonomy flat (no severity, no caps, no quiet hours), five declared /
   two live; the genuinely valuable attention material is the storm-fix delivery
   rules (replay suppression, focus-ack, min-signal floor).
5. **Teardown + stranded-work detection** — ANSWERED, weak end (MY2-3): merge does
   the full cleanup (non-force remove + branch delete), reject force-deletes, but
   record-delete strands git state and **no reconciliation exists** between task
   records and `git worktree list`; orphan detection covers PTYs only. Joins orca as
   the corpus's second teardown anti-reference (opposite failure mode: leak vs
   destroy).
6. **Placement & multi-machine addressing** — ABSENT for compute, by explicit
   non-goal ("multi-machine workbook replication" — `OPERATIONS.md:102`); the only
   cross-machine features are credential mirroring over SSH (MY1-1) and the mobile
   app's client-side multi-*server* list. No worker concept, no routing, no
   failover. Argus's cluster remains undisputed in this corpus's category 5.

---

## Open questions

- **OQ-1 — Where does the overlap-advisory detector live, and does it ever gate?**
  MY1-2's Detector-A-as-query is cheap for us (structured tool-call rows), and OR1-2
  + myrlin agree the output is warning-only attention, never a gate. Open: scope
  (per-project? per-worktree-parent for fan-out siblings, per FLOW §6?), window
  (recent-activity horizon vs since-fork), and whether the merge-back flow consults
  it pre-merge as advisory context for the parent agent. Decide in slice 5's
  merge-back design; slice 2 can ship the read-model without answering.
- **OQ-2 — Multi-account CLI credentials: when, and where do snapshots live?**
  MY1-1's mechanics + SY1-4's rotation policies are ready references; nothing today
  demands them (one account, one node). Trigger: a second paid account, or the first
  second-node credential sync (slice 2/6). Decide then: Vault-encrypted account rows
  (lean) vs managed dotfile snapshots; and whether the lineage pin is per-account
  (`active_node`) on the row — the cluster makes this a column where myrlin needed
  an SSH-probed hint.
- **OQ-3 — API-key issuance UX: mix task now, pairing flow at slice 1?** The
  seams pass found zero minting paths. Lean: ship `mix jidoclaw.api_key` now
  (do-now, MY1-4a), then decide at slice 1 whether argus clients get per-device keys
  via a QR pairing flow (myrlin's ladder) or a single per-user key provisioned
  manually (OVERVIEW §4.4's current text). Per-device + revocation registry is the
  lean if the phone app is real.

---

## Cross-references and dependencies

```
MY1-1 (credential lineage) ──composes──▶ SY1-4 (rotation policies), XA2-3 (canary upgrade)
      └─doctrine──▶ memory: forge-oauth-file-sync (files stay load-bearing)
MY1-2 (conflict detectors) ──feeds──▶ FLOW §12 fileConflicts (citation corrected) + §6 merge-back
      └─sibling──▶ OR1-2 (warning-only advisory); OQ-1
MY1-3 (delivery rules) ──lands inside──▶ CC1-2 read-model + EM1-3/TM2-5/XA1-2 stack (slice 1)
MY1-4 (enrollment ladder) ──feeds──▶ OVERVIEW §4.4 (slice 1); do-now: mix api_key task
      └─cautionary kin──▶ PD1-1 (advertised-not-enforced rot)
MY2-1 (severed promote) ──adds criterion to──▶ CH1-1 → OVERVIEW §5.4 build (slice 4)
MY2-2 (task negatives) ──joins──▶ BO1-4 + PD1-3 + MC1-2 as slice-3 schema checklist
MY2-3 (worktree mechanics) ──feeds──▶ FLOW §4 templates + §5 provisioning/teardown (slice 2)
MY2-4 (push mechanics) ──feeds──▶ OVERVIEW §6.2 wiring (slice 1); CH2-3 confirmed
MY2-5 (client rules) ──feeds──▶ argus §4.2 client design (slice 1)
MY2-6 (skip-and-record) ──folds into──▶ FLOW §8 (with MC2-5, SY1-2)
MY3-2 (viewport ownership) ──parks until──▶ slice 8 (operator terminal)
```

**Suggested first wave** (argus-independent): exactly one item — **MY1-4a, the
`mix jidoclaw.api_key` task** (create/list/revoke over the existing
`Accounts.ApiKey`; closes a verified zero-callers gap that predates argus, since the
`/v1/chat/completions` surface already requires a key nobody can mint outside IEx).
Small enough not to warrant a first-wave file. Everything else is correctly
slice-bound: MY1-3/MY2-4/MY2-5 land inside slice 1's attention/client build (with
CC1-2/CH2-3), MY1-4's pairing flow with slice 1's client, MY1-2/MY2-3 with slice 2,
MY2-2's checklist with slice 3, MY2-1's criterion with slice 4, MY1-1 on OQ-2's
trigger.

**Collision notes**: nothing collides with the unadopted-next-ten queue (composer
judgment work). MY1-1 must be sequenced with (not beside) the Forge OAuth file-sync
posture — it *extends* the files-are-load-bearing doctrine to multi-node, never
replaces it with brokering. MY1-3 lands inside the CC1-2 attention design, not
beside it (same rule the Chorus dig set for CH2-3). MY2-1's criterion amends CH1-1's
§5.4 acceptance list rather than opening a new item.

## Bottom line

1. **The lineage guard is the find** (MY1-1): FLOW §5's multi-node CLI credential
   sync has a failure mode only this subject has hit and fixed — refresh-token
   lineage theft between machines — plus the file mechanics (rotation write-back,
   identity-first/tokens-last, three-state health) to build ours from. Composes
   with SY1-4; upgrade XA2-3's canary with the transient-never-kills rule.
2. **FLOW §12's `fileConflicts` citation is now honest** (MY1-2): the trigger stands,
   the detectors are referenced (ours is a query over structured tool calls, not a
   transcript scrape), and the source's own push wiring is dead — of five declared
   push events myrlin fires two, which are exactly emdash's set. Wire every declared
   trigger to a named, tested producer or don't declare it (MY2-4).
3. **Slice 1's attention build gains three delivery rules the corpus stack lacked**
   (MY1-3): replay suppression on reconnect, focus-acknowledgement that consumes
   pending state, and a minimum-signal re-arm floor — storm-tested, directly
   applicable to our channel catch-up design, alongside the client-side
   invalidate-don't-mutate + offline-queue rules (MY2-5).
4. **§5 stays empty at subject 23, and the novelty claim gains its sharpest
   acceptance criterion** (MY2-1): the field's third plan-layer promote-the-edit
   promotes into a record nothing consumes — argus §5.4 must prove end-to-end that
   the resumed step's input *is* the head revision, not merely that the revision was
   stored. And the do-now is ours, not theirs: mint-an-API-key has no path in our
   tree today (MY1-4a).
