# Features Worth Borrowing from t3code

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-06** (the
ades corpus's category-5 targeted dig, queued 2026-07-06 and fired the same day). Source:
`~/workspace/research/t3code` (pingdotgg/t3code, "T3 Code" by T3 Tools Inc.).
Self-description: *"a minimal web GUI for coding agents"* — one Node.js server owning
orchestration/providers/terminals/git/fs, with decoupled web, desktop, and mobile clients
sharing one model. Pinned commits: t3code @ `32e7844837` (2026-07-05), jido_radclaw @
`85cbe9f2` (2026-07-06). Cites are firsthand reads of both trees this session (five
parallel subject readers + one seams pass over ours), accurate to within a few lines.
**Read, not executed** — nothing was built or run; runtime claims are per-source.

Shape: TypeScript Effect-TS pnpm monorepo (Vite+ toolchain), 1,792 TS/TSX files /
~473k lines (generated protocol schemas inflate this), split `apps/{server,web,desktop,
mobile,marketing}` + `packages/{contracts,client-runtime,shared,effect-acp,
effect-codex-app-server,ssh,tailscale}` + an in-repo Cloudflare Worker relay
(`infra/relay/`). SQLite persistence. Maturity: 1,902 commits / 160 contributors but
heavily core-authored (Julius Marminge 1,397 = 73%; Theo Browne 80; three bots in the
top twelve — agent-authored commits are routine here), HEAD 2026-07-05, very active
(nightly channel builds every three hours), npm `t3` v0.0.28, product literally titled
"T3 Code (Alpha)", README: "very very early… Expect bugs", contributions closed. License
**MIT** — the first subject in the ades corpus whose *code*, not just patterns, is
liftable. One structural caution against lifting anyway: the entire transport rides
Effect's **pre-release** RPC layer (`effect/unstable/rpc`, the "effect-smol" v4 line,
vendored at `.repos/effect-smol/`) — the wire format is vendor-internal and unstable.

**Targeted dig, by design** (the session-UX quadrant was already mined four subjects
deep): the five areas read are the client/transport/push stack, the client runtime and
three clients, provider driving (codex app-server + ACP), orchestration persistence /
checkpoints / HITL, and remote/tailscale/auth/relay. The web UI component surface and
marketing app were not read. Companion docs: [../README.md](../README.md) (category 5 +
comparison table), [../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) /
[FLOW](../../argus/FLOW.md) / [SYNTHESIS](../../argus/SYNTHESIS.md) (nearly every entry
lands in an argus seam), [../../pms/symphony](../../pms/symphony/FEATURES-WORTH-BORROWING.md)
(SY1-1, the first codex app-server client),
[../../pms/multica](../../pms/multica/FEATURES-WORTH-BORROWING.md) (MC1-1 resume stack),
[../../pms/bosun](../../pms/bosun/FEATURES-WORTH-BORROWING.md) (BO2-4 — corrected by this
dig), [../emdash/FEATURES-WORTH-BORROWING.md](../emdash/FEATURES-WORTH-BORROWING.md)
(EM1-4 ACP TRACK), [../../pms/myrlin-workbook](../../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)
(MY1-4 enrollment). Threat-model weighting as usual: personal tailnet — LLM-misbehavior
containment and leakage hygiene over external-attacker hardening.

## Determination (TL;DR)

**The corpus's first whole-product architectural peer delivers — but not where the scan
pointed.** The scan flagged the push-contract stack as the haul; the dig found that
stack is mostly *vendor plumbing* (Effect pre-release RPC — no t3-authored envelope, no
per-connection sequence, no `ServerPushBus`), while the real hauls sit one layer up and
one layer down. Up: t3code is the **only other event-sourced subject in either corpus**
— commands → pure decider → append-only SQLite event log as source of truth →
projections → PubSub — independently converging on our WorkflowEvent architecture,
including persist-then-publish and a **durable global-sequence catch-up contract**
(`afterSequence` resubscribe) that is a working field reference for exactly what argus
§4.2 planned. Down: the field's **first positive local-auth reference** (scoped
credentials on every HTTP request and WS upgrade — no localhost-trust path at all), and
a five-driver provider layer speaking **four different vendor protocols** behind one
adapter contract, with native codex `thread/resume` — the reference stack for argus
slice 6 and the executor seam's PR-2. The sweep closes at **subject 27: no
edit-and-resume at any layer** — t3code sits *below* the field's three plan-layer
promote-the-edit precedents (its plan card is read-only). Doc/code drift is the worst
in the corpus: both flagship architecture docs describe a codebase that doesn't exist
by those names.

| Part of t3code | As a dependency? | What to take |
| --- | --- | --- |
| Transport (`effect/unstable/rpc` envelopes, streams) | No — pre-release vendor plumbing, wrong runtime | Almost nothing; the *subscription contract* above it (TC1-1), not the frames |
| Orchestration core (decider/event log/projections, SQLite) | No — ours is a superset (Postgres, leases, durable gates, replay) | Convergence evidence + the `afterSequence` catch-up contract + the client sync loop (TC1-1) |
| Auth layer (scopes, pairing, WS tickets, DPoP) | No | The whole contract shape, near-verbatim (TC1-2) — argus §4.4's upgrade path |
| `effect-codex-app-server` + five-driver adapter layer | No — generated, Effect-bound | The protocol surface, resume/approval/steer frames as the slice-6 / executor-PR-2 spec (TC1-3) |
| `effect-acp` | No | ACP TRACK datapoint: production client transport for 2 of 5 providers (TC2-7) |
| CheckpointReactor + checkpoint store | No | The paired tree+conversation rewind mechanism (TC2-1) |
| Remote/tailscale/relay | No | The layered remote model + control-plane-not-data-path relay shape (TC2-6); doctrine quotes |
| Client runtime (supervisor, atoms, outbox) | No — Effect Atom | The state-machine spec + degraded-mode UX rubric (TC2-5); mobile outbox semantics (TC2-6) |
| Terminals (node-pty, thread-scoped, scoped auth) | No | An MIT reference impl for FLOW §11's operator terminal (TC2-3) |

## Why not adopt t3code as a dependency

1. **It's a product, not a library.** One Node server + three clients; there is no seam
   to embed. Its packages are `private: true` and generated against pinned upstream
   specs.
2. **Runtime and stack mismatch.** Effect-TS fibers/layers over SQLite vs OTP/Ash over
   Postgres. Every borrow is a translation (the standing corpus rule) — with the one new
   wrinkle that MIT permits lifting *contract text* (schemas, method tables, prompt-ish
   strings) verbatim where translation adds nothing.
3. **The transport is someone else's pre-release.** The WS wire format is Effect
   `unstable/rpc` internals; building against it would couple us to a third party's
   unshipped v4. Phoenix Channels remains our answer (argus §2.4).
4. **We hold the stronger substrate where it counts.** Their pending approvals are
   in-memory `Deferred`s that die on restart ("Restart the turn to continue" —
   `ProviderCommandReactor.ts:163`); default runtime mode is `full-access`
   (yolo-by-default, the Chorus posture); no leases, no multi-node story, no
   edit-and-resume. Our durable `AgentCase` + checkpoint resume + lease fencing is
   strictly stronger — the moat holds against the closest peer yet (see S-3).

## How to read this document

Standard corpus vocabulary (BORROW-PATTERN / BORROW-REFERENCE / BORROW-RUBRIC / FOLD-IN
/ TRACK / ALREADY-COVERED / SKIP; no new axes needed). Initial inventory — no Status
lines. Tiers scoped to this codebase: **Tier 1** = lands in an argus slice that is the
active frame (slice 1 client, slice 6 CLI engine, §4.4 auth) with clear our-side gaps
verified 2026-07-06; **Tier 2** = real reference value, needs a design decision or a
named trigger; **Tier 3** = garnish. Per-entry fields as usual; IDs `TC<tier>-<seq>`,
`S-n` skips, `OQ-n` open questions.

One recurring translation note: t3code and jido_radclaw independently converged on
event-sourcing (commands → events-as-truth → projections → fan-out), so most Tier-1
entries are *contract references* over machinery we already own, not new machinery —
the cheapest kind of borrow, and the reason this targeted dig was worth firing before
argus slice 1.

---

## Tier 1 — High impact, lands in an active argus seam

### TC1-1. The durable-sequence catch-up contract + client sync loop

**Recommendation**: BORROW-REFERENCE — the argus slice-1 client's working field
reference, on both ends of the wire. This is what the dig fired early for.

**Where in t3code**: `apps/server/src/persistence/Migrations/001_OrchestrationEvents.ts:8-43`
(append-only `orchestration_events`: global `sequence INTEGER PRIMARY KEY AUTOINCREMENT`
+ per-stream `stream_version` with a unique `(aggregate_kind, stream_id, stream_version)`
index); `OrchestrationEventStore.ts:160-261` (`readFromSequence`: `WHERE sequence > ?
ORDER BY sequence ASC`, paged 500); `OrchestrationEngine.ts:169-217, 303-331` (append +
project in a transaction, **then** publish to in-memory PubSub — persist-then-publish);
`packages/contracts/src/orchestration.ts:454-484` (`subscribeThread`/`subscribeShell`
take `afterSequence?`; snapshots carry `snapshotSequence`); `apps/server/src/ws.ts:1064-1240`
(the load-bearing ordering trick: fork the **live** PubSub into a buffer *before*
draining the durable catch-up read, then concatenate — nothing published mid-replay is
lost); client side `packages/client-runtime/src/state/threads.ts:200-242` (base = warm
persisted cache, else one cold HTTP snapshot; subscribe with `afterSequence =
base.snapshotSequence`; events deduped by `sequence <= last` at `:156-184`);
`rpc/client.ts:150-237` (auto-resubscribe on every new session via
`SubscriptionRef.changes(session) |> Stream.switchMap`). Their two paid-for defects,
equally citable: the resubscribe input is **pinned at mount**, so every reconnect
re-replays the full since-mount span (client dedupes; O(events-since-mount) redundant
bytes), and the sophisticated gap-detection recovery coordinator
(`apps/web/src/orchestrationRecovery.ts`) plus the `replayEvents` RPC (`ws.ts:1041-1063`)
have **zero production callers** — tests only.

**What**: A reconnecting client resumes a thread's state from a durable, globally
monotonic event sequence: warm cache or one snapshot establishes a base cursor; the
subscription replays persisted events after the cursor, then streams live; overlap is
deduped client-side by sequence; connection "generation" invalidates unary-query caches
on each reconnect. Pure reducers over contract event types apply pushes to client state.

**Gap in jido_radclaw** (verified 2026-07-06): the server half **exists** — the
`WorkflowEvent` log with FOR-UPDATE `max+1` per-run seq
(`orchestration/workflow_event/changes/allocate.ex:174-195`) and the byte-paginated
`after_seq` feed (`tools/workflow_events.ex:53-57`) — but is MCP-only; no channel
proxies it, per-step transitions are durable-log-only (nothing broadcasts them —
`reactor_middleware.ex:262-296` funnels to `WorkflowLog.append`, no `RunPubSub` call),
`Conversations.Recorder` writes messages with **no PubSub fan-out** (`recorder.ex`),
and no client-facing durable feed for conversation messages exists at all (only
internal watermark reads; `message.ex:202-298`). The client half is greenfield (FLOW
§13: "the client is the second product"). Argus §4.2 sketched exactly t3code's shape —
`workflowEvents(afterSeq:)` for reconnect catch-up — as a design; t3code is the shipped
proof plus the defect list.

**Why it matters**: This was the one argus surface with *no* field reference in 24 prior
subjects (the scan even recorded t3code's sequence as "per-connection… a contrast, not a
borrow" — the dig inverts that: it's durable, global, and convergent with ours). Getting
slice 1's sync loop right is the difference between a phone client that trusts its
screen and one that silently drops events.

**Adoption sketch**: (a) Channel layer per OVERVIEW §4.2, but adopt their **carry-events,
not just notify** posture for run/thread topics: the channel delivers `WorkflowEvent`
rows (we already redact at the durable sink), snapshot carries its seq, join accepts
`after_seq`. (b) Lift the ordering trick verbatim: subscribe the live topic *before*
draining the durable read, then merge — trivial with Phoenix PubSub + our
`WorkflowView.event_feed/3`. (c) Their defects become our acceptance criteria: the
client cursor **advances across reconnects** (not pinned at mount); the catch-up read is
**bounded** (our feed is already byte-paginated; theirs reads to MAX_SAFE_INTEGER); gap
detection either ships wired or not at all (their dead coordinator is pms observation
13's wiring-mortality law, live in the peer). (d) The client sync loop
(base-snapshot → cursor → dedupe → pure reducer → store) is the React-side spec;
translate to Apollo cache + Channel handler, keep the reducer purity. (e) Sequence
namespace decision recorded in OQ-1 (their global cursor vs our per-run seq).

---

### TC1-2. Scoped-credential local auth: pairing grants → sessions, WS tickets, per-RPC scopes

**Recommendation**: BORROW-PATTERN — the field's **first positive §4.4 reference**
(every prior subject was a negative reference or no-auth), and it ships the exact
shapes argus penciled in as future work.

**Where in t3code**: no unauthenticated path exists — every HTTP request and WS upgrade
resolves a scoped session (`apps/server/src/auth/EnvironmentAuth.ts:591-597`: cookie ??
bearer ?? DPoP). Eight scopes (`docs/cloud/environment-auth.md:12-27`:
`orchestration:read/operate`, `terminal:operate`, `review:write`, `access:read/write`,
`relay:read/write`); ordinary pairing links grant the four client-op scopes only.
One-time pairing tokens exchange for sessions via `POST /api/auth/browser-session`
(HttpOnly SameSite cookie; secret never touches JS — `auth/http.ts:227-244`) or RFC 8693
token exchange at `POST /oauth/token` with optional DPoP (`http.ts:255-318`). **WS
upgrade**: browsers can't set WS headers, so `POST /api/auth/websocket-ticket` mints a
short-lived single-purpose ticket consumed as `?wsTicket=` on connect
(`EnvironmentAuth.ts:501, 936-956`). **Per-RPC scope enforcement**: every method maps to
a required scope (`ws.ts:279-348`), and a method with no declared scope **throws at
handler build** (`ws.ts:458-464`) — drift-guard by construction. Desktop bootstraps its
own renderer with a random 24-byte seed passed over fd3/stdin, seeded as an
administrative grant (`PairingGrantStore.ts:300-315`). Mobile enrollment: QR
pairing shipped **working** (deep-link payload → `{host, code}`,
`apps/mobile/src/features/connection/pairing.ts:30-77`, creds in expo-secure-store).
Origin/CORS is explicitly *not* the boundary — the credential is (`http.ts:47-61`).
Migration `031` was a hard cutover that deleted all prior sessions.

**What**: Capability-scoped short-lived credentials on a localhost dev tool — the
inverse of the corpus's CCC posture ("CSRF ≠ auth") and Xantham posture (grant rides
the model's channel), shipped with the discipline argus wants: grants are minted by
non-model surfaces, scoped, expiring, and enforced per-method.

**Gap in jido_radclaw** (verified 2026-07-06): one API-key-authed route exists
(`POST /v1/chat/completions` — `router.ex:54-58`, `api_key_auth.ex:40-58`); `UserSocket`
accepts Ash session auth only (`user_socket.ex:13-31`); the `rpc:*` channel has no
scoping; `Accounts.ApiKey` has **no working mint path** (a policy-blocked create action,
a dead "Generate New Key" button — `settings_live.ex:41-45`, no mix task) — MY1-4a's
gap, still open. Argus §4.4 currently plans a *single shared key* + tailnet ACLs, and
FLOW §11 separately invents "per-session short-lived tokens minted through the UI" for
the terminal — which is precisely t3code's `wsTicket`, generalized.

**Why it matters**: our threat peer on the tailnet is an LLM agent with `curl` (CC2-4's
lesson). A single standing key that opens every surface — chat, workflow control,
future terminal — is exactly what a leaked env var or a prompt-injected tool call wants.
Scopes + tickets make the terminal's "strictest tier" (FLOW §11) an instance of a
uniform mechanism instead of a bespoke bolt-on.

**Adoption sketch**: (a) Ride MY1-4a's `mix jidoclaw.api_key` do-now: add a `scopes`
array to `Accounts.ApiKey` at mint time (default = read+operate; `terminal:operate`
never in the default set). (b) UserSocket accepts a short-lived WS ticket minted by an
authed HTTP endpoint (the browser-header limitation applies to us identically);
Channels check scope per RPC method — with the t3code build-time trick translated: a
compile-time check (or golden test, our idiom) that every channel handler declares a
scope. (c) Keep the tailnet as belt (argus §4.4's posture unchanged); scopes are the
suspenders. (d) The QR enrollment ladder now has a *working* reference (myrlin's was
shipped-broken) — reuse their deep-link-payload shape when slice 1's pairing lands.

---

### TC1-3. The codex app-server client + the five-driver adapter layer

**Recommendation**: BORROW-REFERENCE — joins (and largely supersedes the breadth of)
symphony SY1-1 on slice 6's CLI-adapter reading list, and is the concrete spec for the
executor seam's PR-2. MIT: schemas and method tables liftable verbatim.

**Where in t3code**: `packages/effect-codex-app-server/` — a generated JSON-RPC client
(newline-delimited stdio, *not* LSP framing; `protocol.ts:97-117`) against a pinned
upstream codex spec: ~90 client methods, 10 server→client requests, 68 notifications
enumerated in `src/_generated/meta.gen.ts:6-181`. The driving logic sits above it in
`apps/server/src/provider/Layers/CodexSessionRuntime.ts`: spawn `codex app-server` with
`CODEX_HOME` injected (`:695-780`), `initialize`/`initialized` handshake with
`capabilities: {experimentalApi: true}`, then `thread/start` — or **`thread/resume
{threadId}`** when a resume cursor exists, with a recoverable-error fallback to fresh
start (`:442-479`, matcher `:57-63`). Resume cursors persist per thread in SQLite
(`provider_session_runtime.resume_cursor_json`, migration `004`). **Approvals are open
JSON-RPC server-requests**: the handler mints a request id, emits a typed
`ProviderEvent{kind:"request"}` to the operator, and **blocks on a `Deferred`** until
`respondToRequest` resolves it — the RPC response *is* the grant channel
(`:952-1114`; unhandled approval kinds fail `methodNotFound`, a documented residual).
Runtime modes map to codex approval/sandbox pairs (`runtimeModeToThreadConfig`
`:265-287`). Above codex, `builtInDrivers.ts:47-53` registers **five** drivers over
**four vendor protocols**: codex (app-server), `claudeAgent`
(`@anthropic-ai/claude-agent-sdk` ^0.3.170 — `ClaudeAdapter.ts:22`), cursor + grok (ACP
via `effect-acp`), opencode (`@opencode-ai/sdk/v2`), all normalized through one
`ProviderAdapter` contract into one runtime-event stream, then queue-backed ingestion →
persisted domain events → client pushes (six hops, each a single-consumer FIFO fiber —
strict per-thread ordering end-to-end; `ProviderRuntimeIngestion.ts:1693-1709`,
`OrchestrationEngine.ts:303-331`).

**What**: The de facto standard the pms corpus predicted ("headless CLI + structured
stream + resume-by-session-id… behind a small adapter behaviour", SYNTHESIS §5.6) —
shipped at production scale across five vendors, with the codex surface enumerated and
the approval/steer/resume frames worked out.

**Gap in jido_radclaw** (verified 2026-07-06): our codex runner is `codex exec
--ephemeral` one-shot JSONL (`forge/runners/codex.ex:93-116`) and our claude runner
re-invokes `claude -p` fresh per iteration with no resume flag
(`forge/runners/claude_code.ex:62-73`) — MC1-1's re-send-accumulated-prompts gap, live.
The executor seam refuses `{:forge, :codex | :claude_code}` at dispatch until PR-2
(`skills/steps/agent_runner.ex:123-134`); the consolidator drives both CLIs but through
the same no-resume runners (`memory/consolidator/run_server.ex:369`).

**Why it matters**: PR-2 of the executor seam and FLOW §4's `:cli` engine both need
exactly this: session-per-thread with native resume (cost + context), approval frames
bridged to a human inbox (ours is `AgentCase` — where t3code blocks a Deferred that
*dies on restart*, we park a durable case; the composition is strictly better on our
substrate), and a normalized event stream (ours lands in Recorder rows + Forge events).
The codex method table also scopes what a `codex app-server`-backed Forge runner should
and shouldn't touch (e.g. `thread/rollback`, `turn/steer`, `account/*` exist; we'd use
a fraction).

**Adoption sketch**: (a) At PR-2, build the codex Forge runner on `codex app-server`
JSON-RPC (persistent session per Forge session, `thread/resume` on reconnect/iteration)
instead of `codex exec` — keep `exec --ephemeral` as the fallback for one-shots; store
the provider thread id as our resume cursor (a `resume_cursor`-equivalent column on the
Forge session or template run row). (b) Bridge `item/*/requestApproval` server-requests
to `ToolApprovals.request/3` (kind `:tool_call` or a new `:provider_request`), replying
to the open JSON-RPC request on `Cases.decide/4` — their Deferred, made durable. (c)
Lift their recoverable-resume matcher semantics (missing-thread ⇒ warn + fresh start,
never crash). (d) The claude lane's SDK choice is a datapoint for ours, not a directive
— our claude runner should first gain `--resume <session_id>` (MC1-1's cheaper half).

---

## Tier 2 — Reference value, needs a decision or a named trigger

### TC2-1. Paired turn rewind: workspace checkpoint + conversation rollback in one gesture

**Recommendation**: BORROW-REFERENCE, TRACK — trigger: argus thread-timeline UX design
(slice 2's diffs or slice 5's fan-out, whichever first grows a "rewind" affordance).

**Where in t3code**: checkpoints are **parentless commit objects at hidden refs**
(`refs/t3/checkpoints/<b64(threadId)>/turn/<n>` — `checkpointing/Utils.ts:4-10`),
captured via an isolated temp `GIT_INDEX_FILE` + `write-tree`/`commit-tree` (no `-p`),
full tree including untracked, never touching HEAD/branches/user index
(`GitVcsDriver.ts:651-730`). `thread.checkpoint.revert{turnCount}` restores the whole
tree (`git restore --source <commit> --worktree --staged` + `clean -fd`) **and calls
`providerService.rollbackConversation({numTurns})`** — codex `thread/rollback` — so
workspace and conversation rewind *together*; stale checkpoint refs are deleted and a
`thread.revert.complete` event lands (`CheckpointReactor.ts:610-738`, rollback `:697-703`).
Turn diffs persist as `checkpoint_diff_blobs` rows (migration `003`).

**What**: The turn timeline is bidirectionally navigable: every turn boundary snapshots
the tree; revert rewinds both the files *and* the agent's conversation state to that
boundary.

**Gap in jido_radclaw** (verified 2026-07-06): we hold each half separately — Reactor
compensation/undo + replay on the workflow axis, and camus C1-6's engine-observed
`sealed_head`/`:head_observed` markers for *integrity* — but nothing rewinds a
conversation-plus-workspace pair, and our runners have no conversation to rewind (no
native sessions; TC1-3). traycer's checkpoint manifests (TR dig) were files-only;
t3code is the corpus's first *paired* rewind.

**Why it matters**: less for today's composer (verify + fixer loops want forward
motion, and VERIFY_OATH forbids evidence-destroying rewrites) than for argus threads:
"undo the last two turns" is the phone-operator gesture for a runaway agent that
doesn't deserve a full kill. Their hidden-ref + orphan-commit storage is also simply a
good trick — zero interference with user branches, garbage-collectable by ref namespace.

**Adoption sketch**: when the trigger fires — a `Worktree`-scoped checkpoint service
(same ref-namespace trick, engine-run like Verify, law 1), revert = tree restore +
(post-TC1-3) provider `thread/rollback` for CLI threads / transcript-boundary marker
for native threads. Until then, no build.

### TC2-2. Steering: fold-into-live-turn shipped across four adapters — the corpus record corrected

**Recommendation**: FOLD-IN — into slice 6's CLI-adapter reading list and CH1-2's
steering record; plus one contrast to hold at design time.

**Where in t3code**: the decider deliberately does **not** block `thread.turn.start`
while a turn runs (`decider.ts:389-461`); adapters treat a concurrent send as a steer
folded into the live turn (`CursorAdapter.ts:912-916` `steeringTurnId = promptsInFlight
> 0 ? activeTurnId : undefined`, with analogous logic in the Claude/OpenCode/Grok
adapters; codex has a first-class `turn/steer` method). No server-side message queue
exists — `docs/project/todo.md` still lists "Queueing messages" as open.

**Gap/correction**: bosun BO2-4 recorded mid-turn injection as shipped "exactly once in
the field" (Claude agent-SDK streaming input). t3code mainstreams it — four adapters,
each over the vendor's native channel — so the corpus's "boundary delivery, never
mid-turn" softening softens again. Our side already queues mid-turn sends as next-turn
mailbox signals (the Chorus dig's finding); what we lack is the *fold-into-current-turn*
option, and what t3code lacks is our queue. Recorded as OQ-3, decided at slice-1/6
build time, not now.

### TC2-3. Terminal stack: server-owned PTYs, thread-scoped, scoped-credential-gated

**Recommendation**: BORROW-REFERENCE — banked for FLOW §11 / slice 8, alongside herdr's
queued PTY-broker dig. The decisive difference: herdr is AGPL (patterns only); this one
is **MIT**, in a stack adjacent to ours.

**Where in t3code**: `node-pty` server-side (`NodePtyAdapter.ts:25,142-146`),
`TerminalManager` sessions keyed `(threadId, terminalId)` with **client-chosen ids**
(`contracts/terminal.ts:32` — idempotent opens by construction); every terminal method
requires `terminal:operate` scope (`ws.ts:324-332`); PTYs survive client disconnect
(attach/unsubscribe only), scrollback persists to a per-session history file replayed
on next open (`Manager.ts:1324-1380`), thread archive closes its terminals
(`ws.ts:991`). **No agent-vs-operator split — all terminals are operator terminals**;
agents execute through provider runtimes, never through `TerminalManager`.

**Gap in jido_radclaw** (verified 2026-07-06): no web-exposed PTY exists at all (only
the `rpc:*` channel; shell sessions are CLI/agent-side — `shell/session_manager.ex`).
FLOW §11 wants exactly this shape: operator-only, never model-reachable, short-lived
per-session tokens (= TC1-2's `wsTicket` + `terminal:operate`). Deliberately last in
the slice order; bank, don't build.

### TC2-4. Provider-instance registry ergonomics

**Recommendation**: BORROW-PATTERN (small) — for whichever config surface next grows
multi-instance providers (executor PR-2/PR-3, or the MCP consumer's `mcp_servers:`).

**Where in t3code**: `ProviderDriverKind` is an **open branded slug**, explicitly not a
closed union so forks can add drivers (`contracts/providerInstance.ts:16-28,70`);
unknown drivers or config-decode failures downgrade to an "unavailable" shadow snapshot
— visible, never rejected, never crashing (`ProviderInstanceRegistryLive.ts:124-157`);
multiple instances per driver (e.g. `codex_work` + `codex_personal`) with per-instance
env whose `sensitive: true` values are server-held secrets never returned to clients;
settings changes hot-reload by tearing down only changed instances (`:211-312`).
Multi-account via `shadowHomePath` (separate `auth.json`, shared state) — the
file-mechanics cousin of SY1-4/MY1-1.

**Gap in jido_radclaw**: our provider config is single-instance per provider
(`.jido/config.yaml`), and the executor seam's `executor_config` (shipped 2026-07-05)
is per-template with no instance registry. Fine today; this entry is the shape to reach
for when PR-3's cross-vendor resolution meets "two codex accounts". The
graceful-unavailable posture also matches our MCP consumer's crash-isolated prep — a
convergence, not a gap.

### TC2-5. Degraded-mode client UX rubric

**Recommendation**: BORROW-RUBRIC — for argus slice 1's client; small, cheap,
paid-for-elsewhere decisions.

**Where in t3code**: supervisor phases `available/offline/connecting/backoff/connected/
blocked` with capped backoff `[1,2,4,8,16]s`, a 30s stability window resetting failure
count, and **blocked (auth/config) never auto-retries** (`connection/supervisor.ts:32-35,
587-668`); presentation collapses to six operator words — "Connecting…" only on a
first attempt, else "Reconnecting…" (`presentation.ts:7-77`); a connection `generation`
counter invalidates unary-query caches on each reconnect (`state/runtime.ts:447-502`);
**slow-RPC receipts**: any non-subscribe RPC unacknowledged for 15s raises a toast
(max 256 tracked — `apps/web/src/rpc/requestLatencyState.ts`) — the "server is stuck"
signal distinct from disconnection; version-skew is a dismissible per-`env:client:server`
hint (`versionSkew.ts:26-117`); manual `retryNow` affordance (`registry.ts:625-630`).
Requests while disconnected **fail fast** — no hidden outbox in the shared runtime
(`rpc/client.ts:88-124`).

**Gap in jido_radclaw**: greenfield (no decoupled client yet). Adopt the rubric lines
wholesale at slice 1: blocked-never-retries, connecting-vs-reconnecting wording,
stuck-vs-disconnected as distinct signals, fail-fast-or-explicit-outbox (never silent
buffering). Their version-skew banner is the *floor*, not the answer — argus keeps
TR1-1/PD1-1 (SYNTHESIS §5.8); notably even this architectural peer ships **no**
negotiation/goldens (verified: no version handshake, no contract snapshot tests).

### TC2-6. The remote/relay/mobile evidence set

**Recommendation**: TRACK — three datapoints banked against named triggers, no build.

**Where in t3code**: (a) **Remote model**: layered — direct `ws(s)://` + LAN + one-time
pairing; Tailscale as *endpoint discovery + optional `tailscale serve`* (a thin CLI
wrapper: `status --json`, `serve --bg`, a `/.well-known/t3/environment` reachability
probe — `packages/tailscale/src/tailscale.ts:183,296-335`); desktop-managed SSH
launch+tunnel (loopback-only forwards, `packages/ssh/tunnel.ts:893-973`); and a hosted
relay that is **control-plane only** — "intentionally not in the hot path… traffic goes
directly between that client and the selected environment" (`infra/relay/README.md:6-13`),
data riding a Cloudflare tunnel. Their doctrine, verbatim (`docs/architecture/remote.md:11-13,59`):
*"Keep the T3 server as the execution boundary"*, *"Avoid introducing a local control
plane unless product pressure proves it is necessary"*, *"remoteness is expressed at the
environment connection layer, not by splitting the T3 runtime itself"* — our argus
doctrine, stated from the outside. Notably the scan's caution inverted: `remote.md`
flags itself as target architecture, but the dig found it **understates** what ships.
(b) **Mobile**: Expo/RN sharing ~100% of the connection/state runtime; push is
**iOS-only native APNs + Live Activities via the relay** (`remoteRegistration.ts:101-197`),
Android has nothing, and **web has no PWA at all** (no manifest, no service worker) —
the strongest native-vs-PWA datapoint yet, banked for the same trigger as cmux's `ios/`
dig (revisiting OVERVIEW §2.6's PWA-for-speed choice). Their APNs egress rides the
relay control plane, never the agent path — XA1-2's rule at cloud scale. (c) **Mobile
outbox**: the one place they queue — composed messages persist to device storage and
drain FIFO-per-thread with exponential retry + `commandId` idempotency when connected
(`thread-outbox-manager.ts:40-208`) — the phone-composing-offline pattern slice 1
should copy rather than rediscover.

**Gap in jido_radclaw**: our remote story is `GatewayExposure` (PHX_HOST → 0.0.0.0 +
port-pinned `check_origin` — `web/gateway_exposure.ex:98-125`) + tailnet; argus keeps
it that way (§2.1). No relay, no APNs, no PWA — all deliberate. These datapoints exist
to make those choices *informed* when their triggers fire, not to reverse them now.

### TC2-7. ACP: production client transport for two of five providers

**Recommendation**: FOLD-IN — the strongest datapoint yet for the standing ACP TRACK
(emdash EM1-4; multica's driver datapoint), no trigger change.

**Where in t3code**: `packages/effect-acp` implements both ACP sides against schema
v0.11.3 (12 agent + 9 client methods, ndjson JSON-RPC, extension routing for vendor
`_meta` surfaces); the **client** side is the production transport for Cursor and Grok
(`AcpSessionRuntime.ts`, per-vendor extensions); the agent side runs only a mock. One
declared-but-unwired method (`session/set_mode`), one schema marked UNSTABLE
(`session/set_model`). The EM1-4 question was "should JidoClaw *speak* ACP so cockpits
can drive it" — t3code is the third shipping consumer that would benefit, and its
client-side completeness confirms the protocol is real enough to target. Trigger
unchanged: evaluate when argus's API surface gets its design pass.

---

## Tier 3 — Garnish

### TC3-1. Test-sync receipts + drainable workers

**Recommendation**: BORROW-RUBRIC. Typed milestone receipts (`checkpoint.baseline.captured`,
`turn.processing.quiesced`) published to a bus whose **production layer is a no-op**;
the integration harness installs the real bus and `waitForReceipt(predicate, timeout)`
instead of polling (`Services/RuntimeReceiptBus.ts:23-66`, harness
`OrchestrationEngineHarness.integration.ts:210-217`). Every queue-backed reactor exposes
`drain()` (`packages/shared/src/DrainableWorker.ts:40-70`) for deterministic test
settling. We have equivalents piecemeal (Recorder's `flush/2` barrier, telemetry
assertions); the *named pattern* — awaitable typed milestones, prod-inert — is worth
keeping in the eval-harness vocabulary. Caveat recorded: their own overview doc implies
production waits on receipts; it doesn't.

### TC3-2. Boot-time command gate: accept-and-queue, never reject

**Recommendation**: BORROW-PATTERN (tiny). `ServerRuntimeStartup` queues dispatched
commands behind a `Deferred` until reactors are up — clients connect and subscribe
immediately, commands issued mid-boot run when ready instead of erroring
(`serverRuntimeStartup.ts:58-131,307-469`; `ws.ts:900-906`). Our gateway returns
errors during app boot only briefly (OTP supervision starts fast), but the pattern is
the right answer if argus's channel join ever races projector warm-up.

### TC3-3. Contract-discipline garnishes

**Recommendation**: BORROW-RUBRIC, fragments: `packages/contracts` is **schema-only by
policy** (AGENTS.md forbids runtime logic in it); stream events carry `version:
Schema.Literal(1)` from day one (cheap future-proofing even without negotiation);
terminal/session ids are **client-chosen** for idempotent opens; transport decode
failures return per-request structured issues without killing sibling streams (with the
one sharp edge that an untyped handler defect *is* connection-fatal —
`RpcServer.ts:329-333` via the vendored effect source). Each maps onto a surface we
already govern with golden tests; take the fragments as review-checklist lines, not work
items.

---

## Skip / Already covered / Negative evidence

- **S-1. Effect RPC transport + envelopes** — SKIP. Pre-release vendor internals
  (`effect/unstable/rpc`); no t3-authored envelope exists to borrow. Our live transport
  remains Phoenix Channels (argus §2.4).
- **S-2. SQLite single-store persistence** — ALREADY-COVERED by Ash/Postgres + the
  event-sourced spine (`WorkflowEvent` + projections); their per-stream
  `stream_version` optimistic check is our FOR-UPDATE allocation + lease fencing.
- **S-3. Approval durability** — negative reference, moat evidence: pending approvals
  persist as projection rows but the awaited `Deferred` dies on restart/recovery
  ("Restart the turn to continue", `ProviderCommandReactor.ts:163`), and default
  runtime mode is `full-access` with `approvalPolicy: never`. Our durable
  run-bound/run-less `AgentCase` + `GateResume` + fingerprint re-derivation is strictly
  stronger — the pms observation-9 gate-defect list gains a fifth member (bosun's
  re-open, Chorus's double-approve, … t3code's dead-Deferred).
- **S-4. Worktree lifecycle** — ALREADY-COVERED by the corpus composite law (FLOW §5:
  phased + dirty-checked + PR-aware + reconciled). t3code adds two small datapoints:
  worktree provisioning happens lazily at **first turn** (`ws.ts:838-868` fetch →
  `createWorktree` → `thread.meta.update`), and project setup scripts run *in a thread
  terminal* on worktree create — observation-1 garnish only.
- **S-5. Vite+/oxlint/vendored-repos toolchain, `vouch:*` PR trust labels, marketing
  app** — N/A to us (the vendored-`.repos/` reading discipline is cute but our
  usage_rules/docs tooling covers it).
- **S-6. Version-skew handling** — verified **absent** (no negotiation, no goldens; a
  dismissible banner). Keeps traycer TR1-1/TR1-2 + pad PD1-1 as the only field
  references for OVERVIEW §6.3; recorded in TC2-5.
- **S-7. THE SWEEP — edit-and-resume verified absent (subject 27).** Execution layer:
  empty — approvals are `accept/acceptForSession/decline/cancel` decisions; user-input
  answers fill provider-defined forms; review comments are client-side prompt appends
  (`reviewCommentContext.ts:204-214` — annotate-then-reprompt, the emdash/termic
  shape); checkpoint revert is state rewind, not output edit. Plan layer: **below** the
  field's three promote-the-edit precedents — the proposed-plan card is read-only
  (Copy/Download/Save only, `ProposedPlanCard.tsx:155-205`), `thread.proposed-plan.upsert`
  is not client-dispatchable (`orchestration.ts:787-796`), and "implement" sends the
  agent's markdown **verbatim** (`buildPlanImplementationPrompt`) or the operator's
  fresh text — never an edited plan. Argus §5's execution-layer head-promotion novelty
  survives its architecturally closest test.

## Open questions

- **OQ-1 (slice 1)**: Adopt t3code's carry-the-events channel posture (TC1-1a) for
  run/thread topics, or keep OVERVIEW §4.2's minimal-payload-plus-refetch? Their model
  needs the durable feed we already have and saves a round-trip per event; §4.2's saves
  schema duplication. Lean: carry events on per-run/per-thread topics (they're already
  redacted rows), minimal payloads elsewhere. Also: per-run seq (ours) vs global cursor
  (theirs) — lean per-run, it's already allocated and shards naturally.
- **OQ-2 (rides MY1-4a)**: do scopes land on `Accounts.ApiKey` at the `mix
  jidoclaw.api_key` do-now, or with argus slice 1? Lean: schema room now (a `scopes`
  attribute with a permissive default), enforcement with the first scoped surface.
- **OQ-3 (slice 1/6)**: busy-thread sends — queue-as-next-turn (our mailbox today,
  their TODO) vs fold-into-live-turn (their shipped steer, our gap). Probably both,
  operator-chosen per send; decide with CH1-2's affordances work.

## Cross-references and dependencies

```
TC1-1 catch-up contract ──────► argus slice 1 (channel layer + client scaffold)
  │        ▲ our WorkflowEvent feed (exists, MCP-only)
TC2-5 degraded-mode rubric ───┘         TC1-2 scoped auth ──► argus §4.4 upgrade
                                          │   └─ rides MY1-4a mint do-now (OQ-2)
                                          └─► FLOW §11 terminal tokens = wsTicket
TC1-3 app-server client ──► executor seam PR-2 + slice 6 (with SY1-1, MC1-1)
  ├─ TC2-2 steering correction ──► BO2-4 / CH1-2 record (FLOW §13 note)
  └─ TC2-1 paired rewind (TRACK: thread-timeline UX)
TC2-3 terminal stack ──► FLOW §11 / slice 8 (MIT sibling of herdr's queued dig)
TC2-6 remote/mobile evidence ──► PWA-vs-native revisit (with cmux ios/)
TC2-7 ACP datapoint ──► EM1-4 TRACK (trigger unchanged)
```

**Suggested first wave**: nothing here jumps the queue — every Tier-1 item is
slice-gated by design (the dig's purpose was to have these references *in hand* when
slices 1 and 6 open). The only near-term motion: (a) OQ-2's schema-room decision rides
the already-queued MY1-4a `mix jidoclaw.api_key` session; (b) the corpus record updates
land with this doc (ades README category 5 + observations 3/5/8, the FLOW §13 steering
note, SYNTHESIS §5.6). No collision with `unadopted-next-ten` (its remaining items are
composer/judgment-layer work; this doc is argus-facing).

## Bottom line

1. **TC1-1** — the argus client's sync loop now has a shipped, defect-annotated field
   reference: durable global sequence, `afterSequence` catch-up,
   live-attached-before-replay, dedupe-by-seq — plus the two defects (mount-pinned
   cursor, dead gap-detection) that become our acceptance criteria.
2. **TC1-2** — the corpus finally has a *positive* auth reference: scoped credentials +
   WS tickets + working QR pairing; argus §4.4 upgrades from "one key" to "scoped
   short-lived grants" nearly for free on the MY1-4a path.
3. **TC1-3** — PR-2 of the executor seam and slice 6 get their protocol spec: codex
   app-server with native `thread/resume`, approvals as open JSON-RPC requests bridged
   to a durable inbox (ours), five vendors behind one adapter contract.
4. The moat holds at its hardest test yet: the one subject sharing our architecture has
   no durable gates, no leases, no cluster, no skew handling, and no edit-and-resume
   (subject 27) — while independently converging on event-sourcing, persist-then-publish,
   and tailnet-boundary doctrine. Convergence where we're right, gaps where we're
   ahead: the exploration corpus's best possible outcome.
